// Go candidate: net/http, pgx, golang-jwt. No framework.
//
// The contract is shared with the PHP candidates line for line:
//
//	GET  /auth        verify the bearer token, nothing else
//	POST /events      verify (scope events:write), insert one row
//	GET  /events/{id} verify (scope events:read), read one row by primary key
//
// The public key is parsed once at start-up; verification itself is never
// cached. The pool holds at most DB_MAX_CONNS connections — the same ceiling
// the PHP candidates get through their worker count.
package main

import (
	"context"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	issuer   = "https://auth.bench.local"
	audience = "events-api"
)

type claims struct {
	Scope string `json:"scope"`
	jwt.RegisteredClaims
}

type event struct {
	ID        int64           `json:"id"`
	Subject   string          `json:"subject"`
	Kind      string          `json:"kind"`
	Payload   json.RawMessage `json:"payload"`
	CreatedAt time.Time       `json:"created_at"`
}

type newEvent struct {
	Kind    string          `json:"kind"`
	Payload json.RawMessage `json:"payload"`
}

type server struct {
	pool   *pgxpool.Pool
	key    *rsa.PublicKey
	parser *jwt.Parser
}

func (s *server) authorize(r *http.Request, scope string) (*claims, bool) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return nil, false
	}
	c := &claims{}
	if _, err := s.parser.ParseWithClaims(token, c, func(*jwt.Token) (any, error) { return s.key, nil }); err != nil {
		return nil, false
	}
	if c.Subject == "" || !hasScope(c.Scope, scope) {
		return nil, false
	}
	return c, true
}

func hasScope(granted, want string) bool {
	for _, s := range strings.Fields(granted) {
		if s == want {
			return true
		}
	}
	return false
}

func writeJSON(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	w.Write(body)
}

func unauthorized(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", `Bearer error="invalid_token"`)
	writeJSON(w, http.StatusUnauthorized, []byte(`{"error":"invalid_token"}`))
}

func (s *server) auth(w http.ResponseWriter, r *http.Request) {
	c, ok := s.authorize(r, "events:read")
	if !ok {
		unauthorized(w)
		return
	}
	body, _ := json.Marshal(map[string]string{"sub": c.Subject, "scope": c.Scope})
	writeJSON(w, http.StatusOK, body)
}

func (s *server) createEvent(w http.ResponseWriter, r *http.Request) {
	c, ok := s.authorize(r, "events:write")
	if !ok {
		unauthorized(w)
		return
	}
	var in newEvent
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&in); err != nil ||
		in.Kind == "" || !json.Valid(in.Payload) || in.Payload[0] != '{' {
		writeJSON(w, http.StatusBadRequest, []byte(`{"error":"invalid_request"}`))
		return
	}
	var id int64
	err := s.pool.QueryRow(r.Context(),
		`INSERT INTO events (subject, kind, payload) VALUES ($1, $2, $3) RETURNING id`,
		c.Subject, in.Kind, string(in.Payload)).Scan(&id)
	if err != nil {
		log.Printf("insert: %v", err)
		writeJSON(w, http.StatusInternalServerError, []byte(`{"error":"server_error"}`))
		return
	}
	writeJSON(w, http.StatusCreated, fmt.Appendf(nil, `{"id":%d}`, id))
}

func (s *server) getEvent(w http.ResponseWriter, r *http.Request) {
	c, ok := s.authorize(r, "events:read")
	if !ok {
		unauthorized(w)
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id < 1 {
		writeJSON(w, http.StatusNotFound, []byte(`{"error":"not_found"}`))
		return
	}
	var e event
	err = s.pool.QueryRow(r.Context(),
		`SELECT id, subject, kind, payload, created_at FROM events WHERE id = $1 AND subject = $2`,
		id, c.Subject).Scan(&e.ID, &e.Subject, &e.Kind, &e.Payload, &e.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		writeJSON(w, http.StatusNotFound, []byte(`{"error":"not_found"}`))
		return
	}
	if err != nil {
		log.Printf("select: %v", err)
		writeJSON(w, http.StatusInternalServerError, []byte(`{"error":"server_error"}`))
		return
	}
	body, _ := json.Marshal(e)
	writeJSON(w, http.StatusOK, body)
}

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func main() {
	pem, err := os.ReadFile(env("JWT_PUBLIC_KEY", "/keys/public.pem"))
	if err != nil {
		log.Fatal(err)
	}
	key, err := jwt.ParseRSAPublicKeyFromPEM(pem)
	if err != nil {
		log.Fatal(err)
	}

	maxConns, err := strconv.Atoi(env("DB_MAX_CONNS", "32"))
	if err != nil {
		log.Fatal(err)
	}
	cfg, err := pgxpool.ParseConfig(fmt.Sprintf("postgres://%s:%s@%s:5432/%s?sslmode=disable",
		env("DB_USER", "postgres"), env("DB_PASS", "bench"), env("DB_HOST", "db"), env("DB_NAME", "bench")))
	if err != nil {
		log.Fatal(err)
	}
	cfg.MaxConns = int32(maxConns)
	cfg.MinConns = int32(maxConns)
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		log.Fatal(err)
	}

	s := &server{
		pool: pool,
		key:  key,
		parser: jwt.NewParser(
			jwt.WithValidMethods([]string{"RS256"}),
			jwt.WithIssuer(issuer),
			jwt.WithAudience(audience),
			jwt.WithExpirationRequired(),
		),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /auth", s.auth)
	mux.HandleFunc("POST /events", s.createEvent)
	mux.HandleFunc("GET /events/{id}", s.getEvent)

	srv := &http.Server{
		Addr:              ":80",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       75 * time.Second,
	}
	log.Printf("listening on :80 (db pool %d)", maxConns)
	log.Fatal(srv.ListenAndServe())
}
