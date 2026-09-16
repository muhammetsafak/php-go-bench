# php-go-bench

One HTTP API, written three times, measured under the same load:

| Candidate | Runtime | HTTP | Database | JWT |
|---|---|---|---|---|
| `go` | Go 1.27.1 | `net/http` | pgx v5.11.0 (pool, statement cache) | golang-jwt v5.3.1 |
| `fpm` | PHP 8.5.10 NTS, php-fpm | nginx (same container) | PDO pgsql, persistent, single round-trip exec | firebase/php-jwt v7.1.1 |
| `frankenphp` | PHP 8.5.10 ZTS, FrankenPHP 1.12.7 worker mode | Caddy 2.11.4 (built in) | PDO pgsql, server-side prepared, kept per worker | firebase/php-jwt v7.1.1 |

No framework on either side. The two PHP candidates run the **same**
[`apps/php/src/Api.php`](apps/php/src/Api.php); only the entry point differs
(`public/index.php` vs `public/worker.php`).

The question: **which one does the same work faster, and with fewer
resources?** The work is what an OAuth2 resource server does all day:

| Scenario | Request | What happens |
|---|---|---|
| `auth` | `GET /auth` | verify the bearer token (RS256 signature, `iss`, `aud`, `exp`, `nbf`, `scope`) — no database |
| `read` | `GET /events/{id}` | verify, then one row by primary key from a 1,000,000-row table (random id) |
| `write` | `POST /events` | verify, validate the JSON body, then one `INSERT … RETURNING id` |

## Running it

```sh
./bench/build.sh                              # images + key pair + tokens
./bench/verify.sh                             # contract check, all candidates
STAMP=$(date -u +%F) ./bench/run.sh --all     # ≈ 1 h 45 min
node bench/report.mjs $(date -u +%F)          # summary.json, summary.csv
```

`./bench/run.sh --smoke` runs a 5-second version of both phases — use it to
check the harness first. `CANDS=fpm ./bench/run.sh --smoke` limits it to one
candidate.

Keys and tokens are minted locally by `keys/gen-keys.mjs` and are not
committed; the tokens live for seven days.

## Protocol

**Budget.** The Docker VM has 12 vCPUs. They are split into three disjoint
cpusets:

| | cpus | memory |
|---|---|---|
| candidate | 0-3 | 1 GiB |
| PostgreSQL 17.11 | 4-7 | 2 GiB (512 MB shared_buffers) |
| load generator (oha 1.15.0) and sampler | 8-11 | 1 GiB |

For `fpm`, nginx lives **inside** the candidate container and shares its four
cores; Go and FrankenPHP serve HTTP themselves.

**Equal database ceiling.** Every candidate holds at most 32 connections:
pgx `MaxConns=32`, `pm.max_children=32` with one persistent PDO each, 32
FrankenPHP workers.

**Database idiom per lifetime.** Go's pgx caches prepared statements per
connection; the FrankenPHP worker prepares once and reuses the statement; a
php-fpm request cannot keep a statement, so it sends each query as one
parameterised round trip (`Pdo\Pgsql::ATTR_DISABLE_PREPARES`) instead of
prepare + execute. Each candidate uses the fastest idiom its lifetime allows.

**Key handling.** The public key is parsed once per process in Go and in the
FrankenPHP worker. php-fpm keeps the PEM in an opcached PHP file and turns it
into an OpenSSL key object on every request — that per-request cost is part
of what php-fpm is. Verification results are never cached anywhere.

**Durability.** `synchronous_commit` stays on. Every block starts from a
byte-identical copy of the seeded table (`CREATE DATABASE … TEMPLATE`),
pulled into shared buffers with `pg_prewarm`, followed by a `CHECKPOINT`.

**Phase A — fixed rate (open loop).** `oha -q <target> --latency-correction`,
256 connections, 60 s, 5 repetitions. Targets: `write` 10,000/s, `read`
50,000/s, `auth` 50,000/s. Latency is measured from the moment a request was
due, so a candidate that falls behind accumulates queueing delay instead of
hiding it (no coordinated omission). A candidate that cannot keep up is
reported at the rate it **achieved**, not as a failure; its latency figures
then describe a growing queue and only say "this target is out of reach".

**Phase B — ceiling (closed loop).** 16, 64, 128 and 256 connections,
15 s, 3 repetitions. Capacity is the best repetition: the host is a laptop
that cannot be quiesced, and interference only ever subtracts.

**Every block** (one candidate, one repetition): fresh database → reference
probe → fresh candidate container → 5 s warm-up per scenario → the three
scenarios in the order `auth`, `read`, `write` (write last: it is the only
one that changes the table). Candidate order is reshuffled per repetition.

**Reference probe.** Before each block an nginx that runs no application code
is put on the candidate's four cores and driven at 50,000/s. If the generator
cannot hit the target against it, no candidate could, and the block would be
invalid. Every request has a 10 s timeout; requests still open at the end of
the window are waited for (`oha -w`).

**Resources.** `bench/sampler.sh` reads the cgroup v2 counters of the
candidate and the database once a second (`cpu.stat usage_usec`,
`memory.current`, `memory.stat anon`). CPU time is taken from the counter, so
CPU-per-request is exact regardless of the sampling interval.

## Reading the output

`results/<stamp>/`:

| File | Content |
|---|---|
| `meta.json` | host, versions, the configuration the run used |
| `raw/rate_*.json`, `raw/ceil_*.json` | oha output, verbatim |
| `raw/*.res.jsonl` | cgroup samples for the run of the same name |
| `raw/probe-*.json` | reference probe, per block |
| `raw/app_*.log` | candidate stderr, when it wrote any |
| `anomalies.jsonl` | every run with a non-2xx answer or a transport error |
| `summary.json`, `summary.csv` | derived by `bench/report.mjs` |
| `run.log` | the orchestrator's own log |

Derived figures (`bench/report.mjs`):

- `achieved`: 2xx answers ÷ the nominal window, counted rather than taken
  from oha's `requestsPerSec`.
- `cpuMsPerReq`: candidate CPU time ÷ requests answered. This is the "same
  work, fewer resources" figure.
- `avgCores`: candidate CPU seconds ÷ window.
- `rssPeakMiB`: peak anonymous memory.
- Phase A figures are the **median** of the repetitions; phase B figures come
  from the **best** repetition.

## Run of 2026-09-16

`results/2026-09-16/` is the run the published report uses. It deviated from
the protocol above in three ways:

- **One block re-measured.** The host slept during the ceiling block of
  `frankenphp`, repetition 3; that block was measured again. See
  [`results/2026-09-16/EXCLUDED.md`](results/2026-09-16/EXCLUDED.md). The raw
  files of the interrupted block were lost, and that file says how.
- **Seven flat-out probes are empty** (`raw/probe-ceil_*`, 0 bytes). In
  10 s, the no-code nginx answers 5 to 7 million requests, and oha keeps every
  result in memory; the most likely cause is the load container's 1 GiB limit.
  The at-rate probes, which are what the validity gate uses, are complete for
  all 24 blocks: the lowest is 49,980/s.
- **The write ceiling is noisy.** Go's write ceiling ranges from 9,649 to
  43,942 requests/s across repetitions. In those runs neither the candidate
  (≈ 3.2 of 4 cores) nor the database (≈ 2 of 4 cores) is CPU-saturated, so the
  limit is most likely I/O — WAL flushing on the VM disk — which this run does
  not measure directly. Report it with its range.

## Limits

- One machine: Apple M4 Pro, Docker Desktop, aarch64. The 12 vCPUs are not
  pinned to performance or efficiency cores; the host scheduler decides.
- Load generator, database and candidate share one VM and one kernel;
  networking is the Docker bridge, not a wire.
- The database disk is the Docker Desktop VM disk. Whether its `fsync` reaches
  the physical SSD with the same guarantees as bare metal is not verified here,
  so absolute write throughput is optimistic; the comparison between
  candidates is not affected, because all three hit the same database.
- One token is replayed for every request. The candidates do not cache
  verification, but a real resource server sees many different tokens.
- JIT is off for both PHP candidates.

## Licence

Code and data: MIT (see `LICENSE`).
