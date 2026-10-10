# server/

Go HTTP API for the workout-tracker. Stack: chi + pgx/v5 + slog + goose
(migrations) + Postgres.

All commands below run from the **repo root**.

## Prerequisites

- Go 1.26+ (`go version`)
- Postgres running locally from the `infra/` stack — see `infra/README.md`

## First-time setup

1. Start Postgres if it's not already up:

       docker compose -f infra/compose.yml -f infra/compose.dev.yml --env-file infra/.env up -d

2. Apply migrations:

       make -C server migrate-up

3. Run the server:

       make -C server run

   Stdout will show a structured JSON log line like
   `{"...","msg":"server starting","addr":":8080"}`.

4. Verify both endpoints from another terminal:

       curl -i http://localhost:8080/healthz
       curl -i http://localhost:8080/readyz

   Both should return HTTP 200 with a JSON body.

## Useful commands

| Command | What it does |
| ------- | ------------ |
| `make -C server help`            | List all Make targets |
| `make -C server build`           | Compile to `server/bin/server` |
| `make -C server run`             | Run the server against the local dev DB |
| `make -C server test`            | Run all Go tests (DB tests use the local dev DB) |
| `make -C server fmt`             | `go fmt ./...` |
| `make -C server vet`             | `go vet ./...` |
| `make -C server migrate-up`      | Apply all pending migrations |
| `make -C server migrate-down`    | Roll back the most recent migration |
| `make -C server migrate-status`  | Show migration status |
| `make -C server migrate-reset`   | Roll back **all** migrations (destructive) |
| `make -C server gen-jwt-key`     | Generate the RSA signing key (one-off) |
| `make -C server create-user EMAIL=.. PASSWORD=..` | Create a user |
| `make -C server lint-spec`       | Lint `api/openapi.yaml` with vacuum |

## File layout

- `cmd/server/main.go` — entry point: load config, open DB, start HTTP server with graceful shutdown.
- `internal/config/` — env-driven config loader (`DATABASE_URL`, `HTTP_ADDR`, `LOG_LEVEL`).
- `internal/db/` — `pgxpool` factory.
- `internal/api/` — chi router and HTTP handlers (`/healthz`, `/readyz`).
- `db/migrations/` — goose-managed `.sql` migrations.

## Endpoints

| Path        | Method | Behavior |
| ----------- | ------ | -------- |
| `/healthz`  | GET    | Liveness — 200 if the process is up. Does not touch the DB. |
| `/readyz`   | GET    | Readiness — 200 if `pool.Ping` succeeds within 2s, 503 otherwise. |

## Authentication

The server issues a short-lived **API access JWT** (`aud=workout-tracker-api`,
default 15m) plus a rotating **opaque refresh token** (default 30d, stored only
as a SHA-256 hash, rotated on every use, whole family revoked on reuse). It also
mints a separate short-lived **PowerSync JWT** (`aud=workout-tracker-powersync`,
default 5m) on demand. Both JWTs are RS256, signed by one RSA keypair whose
public half is published at `/.well-known/jwks.json`.

### One-time setup

1. Generate the signing key (writes `server/.secrets/jwt_private_key.pem`,
   which is gitignored):

       make -C server gen-jwt-key

2. Apply migrations (creates `users`, `exercises`, `refresh_tokens`):

       make -C server migrate-up

3. Create your user:

       make -C server create-user EMAIL=me@example.com PASSWORD=yourpassword

### Auth endpoints

| Path | Method | Auth | Behavior |
| ---- | ------ | ---- | -------- |
| `/.well-known/jwks.json` | GET | none | Public signing key (JWKS) |
| `/auth/login` | POST | none | `{email,password}` → `{access_token, token_type, expires_in, refresh_token}` |
| `/auth/refresh` | POST | none | `{refresh_token}` → rotated tokens |
| `/auth/logout` | POST | none | `{refresh_token}` → 204; revokes the family |
| `/auth/powersync-token` | POST | Bearer access token | → `{endpoint, token, expires_at}` |

### Configuration (additional env vars)

| Env var | Required | Default | Notes |
| ------- | -------- | ------- | ----- |
| `JWT_PRIVATE_KEY_PATH` | yes | — | Path to the PKCS#8 RSA private key PEM |
| `JWT_ISSUER` | no | `workout-tracker` | `iss` claim |
| `API_AUDIENCE` | no | `workout-tracker-api` | Access-token audience |
| `POWERSYNC_AUDIENCE` | no | `workout-tracker-powersync` | PowerSync-token audience |
| `POWERSYNC_URL` | no | `http://localhost:8080` | Endpoint returned to the PowerSync client (set when PowerSync joins) |
| `ACCESS_TOKEN_TTL` | no | `15m` | Access-token lifetime |
| `REFRESH_TOKEN_TTL` | no | `720h` | Refresh-token lifetime |
| `POWERSYNC_TOKEN_TTL` | no | `5m` | PowerSync-token lifetime (< 60m) |

## Configuration

| Env var         | Required | Default     | Notes |
| --------------- | -------- | ----------- | ----- |
| `DATABASE_URL`  | yes      | —           | Standard libpq-style URL (`postgres://user:pass@host:port/db?sslmode=disable`). |
| `HTTP_ADDR`     | no       | `:8080`     | Listen address. |
| `LOG_LEVEL`     | no       | `info`      | Reserved for future slog level wiring. |

## Tests

`make -C server test` runs every test under `./...`. Tests that require a
real Postgres connection (currently `internal/db`) skip when
`TEST_DATABASE_URL` is not set; the `make test` target sets it from
`infra/.env`.

## Migrations

Goose is installed as a Go tool via the `tool` directive in `go.mod`.
There is no separate binary to install — `go tool goose` resolves to the
pinned version. Migrations live in `db/migrations/` and follow goose's
`<seq>_<name>.sql` naming.

## PowerSync replication role (one-time)

Migration `00004` creates the `powersync_role` as `NOLOGIN` with no password (no
secret in git). Grant it `LOGIN` + a password out-of-band, reading the value from
`infra/.env` so it never enters version control or shell history beyond this run:

    set -a && . infra/.env && set +a
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h localhost -p 5433 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      --no-psqlrc -v ON_ERROR_STOP=1 \
      -c "ALTER ROLE powersync_role LOGIN PASSWORD '${PS_REPLICATION_PASSWORD}';"

The PowerSync service connects to the source database as this role; its password
must match `PS_REPLICATION_PASSWORD` in `infra/.env`.

## Account writer authority

The legacy upload route now checks a durable account writer gate inside its
transaction before reading the request body. Frozen/retired accounts and gate
failures return queue-preserving 503; expired authentication remains 401. Uploads
are bounded to 1 MiB and 10 seconds. The internal freeze primitive records an
immutable snapshot and receipt. Explicitly configured migration controls require
verified old JWT ownership and separate recorded consent; peer status uses pinned
mTLS. Abort Unfreeze advances the epoch without reopening a retired account.
Its OLD_ACTIVE peer proof is available only while the exact advanced current gate
is still active, allowing the Hub to authenticate abort completion.

See [the writer inventory and remaining readiness gates](docs/account-writer-fence.md).
This implementation has not been deployed or certified for a migration cutover.
