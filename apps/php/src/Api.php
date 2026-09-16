<?php

declare(strict_types=1);

namespace Bench;

use Firebase\JWT\JWT;
use Firebase\JWT\Key;
use PDO;
use PDOStatement;
use Pdo\Pgsql;
use Throwable;

/**
 * The PHP side of the contract, shared verbatim by both PHP candidates.
 *
 *   GET  /auth         verify the bearer token, nothing else
 *   POST /events       verify (scope events:write), insert one row
 *   GET  /events/{id}  verify (scope events:read), read one row by primary key
 *
 * What differs between the candidates is only how long this object lives:
 * php-fpm builds it for every request, the FrankenPHP worker builds it once and
 * hands it request after request. Each gets the database idiom that fits its
 * lifetime — see forRequest() and forWorker().
 */
final class Api
{
    private const ISSUER = 'https://auth.bench.local';
    private const AUDIENCE = 'events-api';

    private const INSERT = 'INSERT INTO events (subject, kind, payload) VALUES (?, ?, ?) RETURNING id';
    private const SELECT = 'SELECT id, subject, kind, payload, created_at FROM events WHERE id = ? AND subject = ?';

    private ?PDOStatement $insert = null;
    private ?PDOStatement $select = null;

    private function __construct(
        private readonly PDO $db,
        private readonly Key $key,
        private readonly array $statementOptions,
    ) {
    }

    /**
     * php-fpm: nothing survives the request except what the runtime keeps for
     * us — the persistent connection and the opcached PEM string. Statements go
     * out as a single parameterised round trip (PQexecParams); preparing a
     * named statement per request would cost a second round trip every time.
     */
    public static function forRequest(): self
    {
        $db = new PDO(self::dsn(), getenv('DB_USER') ?: 'postgres', getenv('DB_PASS') ?: 'bench', [
            PDO::ATTR_PERSISTENT => true,
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
        $key = new Key(openssl_pkey_get_public(require '/keys/public.php'), 'RS256');

        return new self($db, $key, [Pgsql::ATTR_DISABLE_PREPARES => true]);
    }

    /**
     * FrankenPHP worker: the connection, the parsed key and the server-side
     * prepared statements live as long as the worker, which is what pgx does
     * for the Go candidate with its statement cache.
     */
    public static function forWorker(): self
    {
        $db = new PDO(self::dsn(), getenv('DB_USER') ?: 'postgres', getenv('DB_PASS') ?: 'bench', [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
        $key = new Key(openssl_pkey_get_public(require '/keys/public.php'), 'RS256');

        return new self($db, $key, []);
    }

    private static function dsn(): string
    {
        return sprintf('pgsql:host=%s;port=5432;dbname=%s', getenv('DB_HOST') ?: 'db', getenv('DB_NAME') ?: 'bench');
    }

    public function respond(): void
    {
        $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
        $path = strtok($_SERVER['REQUEST_URI'] ?? '/', '?');
        $authorization = $_SERVER['HTTP_AUTHORIZATION'] ?? '';

        try {
            [$status, $body] = $this->dispatch($method, $path, $authorization);
        } catch (Throwable $e) {
            error_log($e->getMessage());
            [$status, $body] = [500, '{"error":"server_error"}'];
        }

        http_response_code($status);
        header('Content-Type: application/json');
        if ($status === 401) {
            header('WWW-Authenticate: Bearer error="invalid_token"');
        }
        echo $body;
    }

    /** @return array{int, string} */
    private function dispatch(string $method, string $path, string $authorization): array
    {
        if ($path === '/auth' && $method === 'GET') {
            $claims = $this->authorize($authorization, 'events:read');
            if ($claims === null) {
                return [401, '{"error":"invalid_token"}'];
            }

            return [200, json_encode(['sub' => $claims->sub, 'scope' => $claims->scope])];
        }

        if ($path === '/events' && $method === 'POST') {
            $claims = $this->authorize($authorization, 'events:write');
            if ($claims === null) {
                return [401, '{"error":"invalid_token"}'];
            }

            return $this->createEvent($claims->sub, file_get_contents('php://input'));
        }

        if ($method === 'GET' && str_starts_with($path, '/events/')) {
            $claims = $this->authorize($authorization, 'events:read');
            if ($claims === null) {
                return [401, '{"error":"invalid_token"}'];
            }

            return $this->getEvent($claims->sub, substr($path, 8));
        }

        return [404, '{"error":"not_found"}'];
    }

    private function authorize(string $header, string $scope): ?object
    {
        if (!str_starts_with($header, 'Bearer ')) {
            return null;
        }
        try {
            // Signature, algorithm, exp and nbf are checked by the library.
            $claims = JWT::decode(substr($header, 7), $this->key);
        } catch (Throwable) {
            return null;
        }
        if (($claims->iss ?? null) !== self::ISSUER
            || !in_array(self::AUDIENCE, (array) ($claims->aud ?? []), true)
            || !isset($claims->exp)
            || !is_string($claims->sub ?? null) || $claims->sub === ''
            || !in_array($scope, explode(' ', (string) ($claims->scope ?? '')), true)) {
            return null;
        }

        return $claims;
    }

    /** @return array{int, string} */
    private function createEvent(string $subject, string $raw): array
    {
        try {
            $in = json_decode($raw, false, 64, JSON_THROW_ON_ERROR);
        } catch (Throwable) {
            return [400, '{"error":"invalid_request"}'];
        }
        if (!is_object($in) || !is_string($in->kind ?? null) || $in->kind === '' || !is_object($in->payload ?? null)) {
            return [400, '{"error":"invalid_request"}'];
        }

        $this->insert ??= $this->db->prepare(self::INSERT, $this->statementOptions);
        $this->insert->execute([$subject, $in->kind, json_encode($in->payload)]);
        $id = (int) $this->insert->fetchColumn();
        $this->insert->closeCursor();

        return [201, '{"id":' . $id . '}'];
    }

    /** @return array{int, string} */
    private function getEvent(string $subject, string $id): array
    {
        if (!ctype_digit($id) || $id === '0' || strlen($id) > 18) {
            return [404, '{"error":"not_found"}'];
        }

        $this->select ??= $this->db->prepare(self::SELECT, $this->statementOptions);
        $this->select->execute([(int) $id, $subject]);
        $row = $this->select->fetch();
        $this->select->closeCursor();
        if ($row === false) {
            return [404, '{"error":"not_found"}'];
        }

        // The payload is already JSON; it is spliced in as-is, exactly as the Go
        // candidate passes it through as json.RawMessage.
        $createdAt = (new \DateTimeImmutable($row['created_at']))->format('Y-m-d\TH:i:s.uP');

        return [200, '{"id":' . (int) $row['id']
            . ',"subject":' . json_encode($row['subject'])
            . ',"kind":' . json_encode($row['kind'])
            . ',"payload":' . $row['payload']
            . ',"created_at":' . json_encode($createdAt) . '}'];
    }
}
