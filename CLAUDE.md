# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A four-service application (React SPA → Spring Boot 3 → FastAPI → PostgreSQL 16) built as a **DevOps
training platform**. The application is deliberately real — JWT auth with refresh rotation, RBAC, file
upload, an external AI dependency — because the infrastructure lessons only mean something on top of a
system that does work.

Two consequences that shape everything:

- **Failure modes are designed, not accidental.** Liveness never touches the database. AI-service health
  is excluded from the middleware's readiness group. The AI call runs outside any transaction. Bad config
  fails at startup. If a change makes one of these "cleaner", it breaks the teaching value — check
  `docs/TROUBLESHOOTING.md` before altering health, transactions or startup validation.
- **`docs/DEVOPS_PHASES.md` is the session runbook**, not reference material. It is the source of truth
  for what has been created and in what order.

## Commands

### Local stack (preferred entry point)

```bash
./scripts/dev-up.sh          # creates 4 env files, verifies they agree, builds, waits for readiness
./scripts/smoke-test.sh      # 20 assertions across the real chain; run after any cross-service change
./scripts/dev-down.sh --volumes   # reset, including the database
```

`dev-up.sh` runs `check-env.sh` first and refuses to start if the per-service env files disagree.

### Per component

| | Build / test | Lint | Single test |
|---|---|---|---|
| `middleware/` | `mvn -B verify` (70 tests + JaCoCo) | — | `mvn test -Dtest=JwtServiceTest#refreshTokenRejectedAsAccessToken` |
| `backend/` | `pytest` (75 tests, SQLite) | `ruff check . && mypy app` | `pytest tests/test_schema_parity.py::TestSchemaParity` |
| `frontend/` | `npm run test -- --run` (19 Vitest) | `npm run lint` (`--max-warnings 0`) | `npx vitest run src/<path>.test.jsx` |

Requires JDK 21 and Maven on PATH — there is no Maven wrapper.

### Before opening a PR

```bash
cd middleware && mvn verify
cd backend   && ruff check . && mypy app && pytest
cd frontend  && npm run lint && npm run test -- --run && npm run build
```

### Helm

```bash
helm lint helm/ai-interview-platform
helm template ai-interview helm/ai-interview-platform -f helm/ai-interview-platform/values-prod.yaml
```

## Architecture

### Service boundaries

```
React SPA :3000  ──JWT──►  Spring Boot :8080  ──INTERNAL_API_KEY──►  FastAPI :8000
                                  │                                       │
                                  └──────────► PostgreSQL :5432 ◄──────────┘
                              (owns the schema)                    (ai_* tables only)
```

**The middleware owns the entire schema.** Flyway migrations live in
`middleware/src/main/resources/db/migration/` and create both the core tables *and* the `ai_*` tables the
FastAPI service reads. The AI service never migrates anything.

The middleware calls the AI service through `service/ai/AiQuestionClient` (interface) /
`HttpAiQuestionClient` (impl). `RetryableAiServiceException` exists so a slow provider degrades question
generation rather than failing the request — the call is deliberately outside any transaction so it cannot
exhaust the JPA connection pool.

### Middleware layering — enforced in review

```
web/controller  →  service  →  repository  →  domain/entity
       ↓              ↓
     dto           mapper
```

Java package root is **`ai.interview.middleware`** (not `com.aiinterview.*`).

- A controller validates, delegates, maps to a DTO. No business logic.
- **An entity never leaves the service layer.** This is what stops `passwordHash` reaching JSON.
- A repository is never injected into a controller.
- **Data-dependent authorization lives in the service**, inside the query — `InterviewService.search`
  scopes `CANDIDATE` callers in the `Specification` so no endpoint can leak another candidate's rows by
  forgetting a check.

### Pluggable backends — three parallel abstractions

All three follow the same shape, so changing one changes nothing else:

| Concern | Interface | Selected by |
|---|---|---|
| Secrets | `service/secret/SecretService` (`Environment*` / `AwsSecretsManager*` impls) | `APP_SECRETS_PROVIDER` = `env` \| `aws` |
| File storage | `service/storage/FileStorageService` | `@ConditionalOnProperty` on `app.storage.type` = `local` \| `s3` |
| AI provider | `backend/app/providers/` + `factory.py` | `AI_PROVIDER` |

`ResumeService` does not know which storage backend it has. Adding an AI provider also requires adding the
value to the `ck_ai_question_sets_provider` check constraint in a new migration.

### AWS access — no keys, anywhere

Both services build AWS clients with the **default credential provider chain only**. On EKS that resolves
the IRSA-projected token; locally it finds your SSO profile. Never add `AWS_ACCESS_KEY_ID` handling.

### Frontend config is resolved at runtime, not build time

`frontend/docker-entrypoint.sh` writes `runtime-config.js` (`window.__APP_CONFIG__`) from `API_BASE_URL`
on every container start. One image is promoted dev → prod unchanged. Do not bake API URLs into the bundle.

`apiBaseUrl: ""` means same-origin — the Ingress routes `/api` to the middleware on the same host, which
is why there is no CORS configuration in production.

## Things that will bite you

### Adding a config value touches four places

Skipping any one produces a value that works locally and is missing in production:

1. `AppProperties` (typed `@ConfigurationProperties` record)
2. `application.yml` — `${ENV_VAR:default}`
3. `helm/ai-interview-platform/templates/configmap.yaml`
4. `values.yaml` **and** `values-dev.yaml` / `values-prod.yaml`

AI service equivalent: `backend/app/core/config.py` `Settings`, then the chart.

### Flyway migrations are immutable once merged

Flyway stores a checksum — editing an applied migration makes every existing environment fail validation
on next start. Additive changes only; split destructive ones across releases (add column → backfill →
switch reads → drop later).

### The AI service schema is duplicated and checked

`backend/app/db/types.py` provides `Guid`/`JsonPayload` decorators mapping to native `uuid`/`jsonb` on
PostgreSQL and `CHAR(36)`/`JSON` elsewhere — that is what lets `create_all()` build the schema in SQLite
for tests. `tests/test_schema_parity.py` compares the SQLAlchemy models against
`V2__create_ai_schema.sql` and fails on drift. **Change an `ai_*` table → change both.**

### No root `.env`

One env file per service, each read only by that service. Values that must agree across files (database
credentials, `INTERNAL_API_KEY`) are verified by `scripts/check-env.sh`.

### Metric cardinality

Label by *route template*, never a concrete URL. Labelling by raw path creates one time series per
interview id.

## Infrastructure state (current, and it contradicts the docs)

Terraform is **active**, applying in numbered order. `terraform/README.md` and the root `README.md` still
describe it as "parked / fully commented out" — that is stale.

```
terraform/
├── 1.vpc.tf     VPC 10.0.0.0/16, 2 public + 2 private subnets, IGW, NAT. Holds terraform{} + provider{}
├── 2.eks.tf     Cluster + node group + OIDC provider + 4 addons + EBS CSI IRSA (raw resources, no module)
├── 3.rds.tf     PostgreSQL 16.14, private subnets, SG referencing the cluster SG
├── 4.ecr.tf     Three repositories
└── parked/      Full-stack module version, fully commented out, plus terraform.tfvars.example
```

All four apply in **one pass** — `3.rds.tf` references `aws_eks_cluster.main` directly rather than a
`data` lookup, which is what removed the manual eksctl step between them.

Cluster `ai-interview` in `ap-south-1`. The `kubernetes.io/cluster/ai-interview` subnet tags in `1.vpc.tf`
are pre-stamped for the load balancer controller and must match the cluster name.

Runbook stages 1.1–1.4 are complete. **Stages 1.5 (S3 + Secrets Manager) and 1.6 (IRSA roles) are
optional** — the chart defaults (`APP_SECRETS_PROVIDER=env`, `storage.type=local`,
`aws.secretsManager.enabled=false`) need none of them.

### Two known-wrong things in the docs

- **`docs/DEVOPS_PHASES.md` Stage 1.4 creates the wrong ECR repository names.** It uses
  `ai-interview/<service>`; the Helm chart composes `<global.imageRegistry>/<image.repository>` where
  `values.yaml` sets `ai-interview-platform/<service>`. Following the runbook yields repositories the
  chart can never pull from, surfacing as `ImagePullBackOff`. `4.ecr.tf` uses the correct names.
- `terraform/README.md` teardown ordering assumes an RDS security group created by hand. It is now
  Terraform-managed, so `terraform destroy` handles it.

### Deploying against this infrastructure

`postgresql.enabled` defaults to **`true`**, which deploys an in-cluster Postgres StatefulSet and leaves
RDS unused. Always override:

```
--set global.imageRegistry=<account>.dkr.ecr.ap-south-1.amazonaws.com
--set postgresql.enabled=false
--set postgresql.external.host=<rds endpoint>
--set secrets.data.dbPassword=<terraform output -raw db_password>
--set secrets.data.jwtSigningKey=<48 random bytes>
```

`jwtSigningKey` must be ≥32 bytes or the middleware refuses to start — deliberately.

CD never writes to Kubernetes. It commits an image tag; **ArgoCD** syncs, so manual `helm upgrade` after
handover shows as drift.

## Conventions

**Java** — records for DTOs, classes for entities. Constructor injection only. `Optional` for return
values, never parameters or fields.

**Python** — full annotations (`disallow_untyped_defs`), `ruff` at 120 columns, Pydantic for anything
crossing the wire. Narrow with `isinstance` rather than casting.

**React** — function components only. Data fetching through `useApiResource`, not `useEffect` in a page.
MUI `sx`, no stylesheets. A helper named `useX` **is** a hook.

**Logging** — structured, never concatenated. `logger.info("...", extra={"setId": str(id)})`; the JSON
formatter promotes `extra` keys to top-level fields so they are queryable in Loki. Every response carries
`X-Request-Id`, emitted by both services, so one id spans both logs.

**Tests** — test decisions, not accessors. `InterviewStatusTest` (state machine),
`StorageKeyFactoryTest` (path traversal), `JwtServiceTest` (token type confusion, both directions) are the
model. Do not assert that a getter returns what a setter set.

## Seed accounts

`admin@aiinterview.local` / `Admin@12345`, created by Flyway `V3` and allowlisted in `.gitleaks.toml`.
Fine for training, must be removed before any real data.
