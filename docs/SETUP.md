# Setup guide

Getting the platform running locally.

## Prerequisites

| Tool | Version | Needed for |
|---|---|---|
| Docker + Compose v2 | 24+ | The whole stack |
| Java (Temurin) | 21 | Running the middleware outside Docker |
| Maven | 3.9+ | Building the middleware |
| Node.js | 20+ | Frontend |
| Python | 3.11+ | AI service |
| `curl`, `jq` | any | `scripts/smoke-test.sh` |

Only Docker is required for the quickstart. The rest are for working on a single
service natively.

## Quickstart

```bash
git clone <repository-url>
cd ai-interview-platform

# Only needed if the scripts were committed from Windows, where Git does not
# record the executable bit.
chmod +x scripts/*.sh

./scripts/dev-up.sh
```

`dev-up.sh` creates the four per-service env files from their examples and checks
they agree before starting anything.

On Windows, run the scripts through Git Bash (`bash scripts/dev-up.sh`) or use the
`docker compose` commands directly.

`dev-up.sh` builds the images, starts everything, and **waits for the readiness
endpoints** before returning — `docker compose up -d` alone returns long before
the middleware has finished its Flyway migrations.

First build takes 5–10 minutes (Maven and pip download their worlds). Subsequent
builds are cached.

| Service | URL |
|---|---|
| Frontend | http://localhost:3000 |
| Swagger UI | http://localhost:8080/swagger-ui.html |
| AI service docs | http://localhost:8000/docs |
| Metrics | http://localhost:8080/actuator/prometheus |
| PostgreSQL | `localhost:5432` |

### Seed accounts

Created by Flyway migration `V3__seed_reference_data.sql`:

| Email | Password | Role |
|---|---|---|
| `admin@aiinterview.local` | `Admin@12345` | ADMIN |
| `priya.sharma@aiinterview.local` | `Interviewer@12345` | INTERVIEWER |
| `arjun.mehta@aiinterview.local` | `Interviewer@12345` | INTERVIEWER |
| `neha.gupta@example.com` | `Candidate@12345` | CANDIDATE |

These are published in this repository and in the GitLeaks allowlist. **Delete or
rotate them before any deployment holding real data.**

### Verify

```bash
./scripts/smoke-test.sh
```

Exercises the full path — login, candidate CRUD, interview creation, AI question
generation through FastAPI to PostgreSQL, result submission, logout, and that a
revoked token is actually rejected.

## Stopping

```bash
./scripts/dev-down.sh              # keeps the database
./scripts/dev-down.sh --volumes    # wipes it; Flyway re-runs from scratch
```

## Configuration

Everything is an environment variable, and there is **one env file per service** —
no shared root `.env`:

```
database/.env      from database/.env.example
middleware/.env    from middleware/.env.example
backend/.env       from backend/.env.example
frontend/.env      from frontend/.env.example
```

Each service reads only its own file, so it is impossible to accidentally depend
on a value belonging to another component. The `.env.example` files are committed;
the real `.env` files are git-ignored.

### The values that must match across files

Two services connect to the same database, and the middleware authenticates to the
AI service, so a few values legitimately appear more than once:

| Value | `database/.env` | `middleware/.env` | `backend/.env` |
|---|---|---|---|
| Database name | `POSTGRES_DB` | `DB_NAME` | `DB_NAME` |
| Database user | `POSTGRES_USER` | `DB_USERNAME` | `DB_USERNAME` |
| Database password | `POSTGRES_PASSWORD` | `DB_PASSWORD` | `DB_PASSWORD` |
| Internal API key | — | `AI_SERVICE_API_KEY` | `INTERNAL_API_KEY` |

Nothing in Docker checks these agree. When they drift you get
`password authentication failed` from a service whose own file looks perfectly
correct. Run the checker after editing any of them:

```bash
./scripts/check-env.sh
```

`dev-up.sh` runs it automatically and refuses to start on a mismatch.

### Values worth knowing

| Variable | File | Default | Notes |
|---|---|---|---|
| `APP_SECRETS_PROVIDER` | middleware | `env` | `env` or `aws`. Switching needs no code change. |
| `SECRETS_PROVIDER` | backend | `env` | Same, for the AI service. |
| `JWT_SIGNING_KEY` | middleware | dev placeholder | **Must be ≥ 32 bytes.** Startup fails otherwise. |
| `AI_PROVIDER` | backend | `mock` | `mock` is deterministic, offline and free. |
| `APP_STORAGE_TYPE` | middleware | `local` | `local` or `s3`. |
| `API_BASE_URL` | frontend | `http://localhost:8080` | Used by the **browser**, so never a compose hostname. |

Generate real secrets with:

```bash
./scripts/generate-secrets.sh --env
```

### Ports

Port mappings are not in the env files — they are a Compose concern. The defaults
apply automatically, and a clash can be overridden for one run:

```bash
MIDDLEWARE_PORT=18080 FRONTEND_PORT=13000 docker compose up -d
```

### Using the real OpenAI provider

```bash
# in backend/.env
AI_PROVIDER=openai
OPENAI_API_KEY=sk-...
OPENAI_MODEL=gpt-4o-mini
```

```bash
docker compose up -d --force-recreate ai-service
```

The mock provider is the default deliberately: it produces deterministic,
plausible DevOps questions with no network call and no spend, which is what you
want for CI and for demonstrating the platform.

## Running a single service natively

Useful when iterating on one component with the rest of the stack in Docker.

### Middleware

```bash
docker compose up -d postgres ai-service

cd middleware
export DB_HOST=localhost DB_PORT=5432 DB_NAME=ai_interview \
       DB_USERNAME=ai_interview_app DB_PASSWORD=change-me-locally \
       JWT_SIGNING_KEY="$(openssl rand -base64 48)" \
       AI_SERVICE_API_KEY=local-dev-internal-api-key \
       AI_SERVICE_BASE_URL=http://localhost:8000

mvn spring-boot:run -Dspring-boot.run.profiles=dev
```

### AI service

```bash
docker compose up -d postgres middleware   # middleware runs the migrations first

cd backend
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt

export DB_HOST=localhost DB_PASSWORD=change-me-locally \
       INTERNAL_API_KEY=local-dev-internal-api-key APP_ENV=dev
uvicorn app.main:app --reload --port 8000
```

The middleware must start at least once before the AI service, because Flyway
creates the `ai_*` tables the Python models map to.

### Frontend

```bash
docker compose up -d postgres ai-service middleware

cd frontend
npm ci
npm run dev     # http://localhost:5173
```

Vite proxies `/api` to `localhost:8080`, so there is no CORS configuration and no
hardcoded host. Override with `VITE_DEV_API_TARGET`.

## Running the tests

```bash
cd middleware && mvn verify                       # 70 tests
cd backend && pytest && ruff check . && mypy app  # 75 tests
cd frontend && npm run lint && npm run test -- --run && npm run build
```

## Troubleshooting setup

**Port already allocated** — override for the run:
`MIDDLEWARE_PORT=18080 docker compose up -d`. The same applies to
`FRONTEND_PORT`, `AI_SERVICE_PORT` and `POSTGRES_PORT`.

**`password authentication failed for user`** — the database credentials have
drifted between `database/.env`, `middleware/.env` and `backend/.env`. Run
`./scripts/check-env.sh`; it names the exact files and values that disagree.

**AI service returns 401 to the middleware** — `middleware/.env`
`AI_SERVICE_API_KEY` and `backend/.env` `INTERNAL_API_KEY` differ.
`./scripts/check-env.sh` catches this too.

**Middleware exits immediately** — almost always `JWT_SIGNING_KEY` shorter than 32
bytes. `docker compose logs middleware` names the exact problem; the failure is
deliberate, since HS256 with a short key is a real weakness.

**AI service cannot find its tables** — it started before the middleware ran
migrations. `docker compose restart ai-service`.

**Flyway checksum mismatch** — an applied migration was edited. In development:
`./scripts/dev-down.sh --volumes`. Never edit an applied migration; add a new one.

More failure modes in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
