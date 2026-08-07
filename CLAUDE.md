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
- **`docs/DEVOPS_PHASES.md` and `docs/DEPLOYMENT.md` describe an earlier design** - manual `eksctl`, one
  umbrella chart, ArgoCD. None of that is how this repository works now. Trust `terraform/`, `helm/` and
  `.github/workflows/` over those two documents.

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
| `frontend/` | `npm run test -- --run` (20 Vitest) | `npm run lint` (`--max-warnings 0`) | `npx vitest run src/<path>.test.jsx` |

Requires JDK 21 and Maven on PATH — there is no Maven wrapper.

### Before opening a PR

```bash
cd middleware && mvn verify
cd backend   && ruff check . && mypy app && pytest
cd frontend  && npm run lint && npm run test -- --run && npm run build
```

### Helm

```bash
REG=000000000000.dkr.ecr.ap-south-1.amazonaws.com
ROLE=arn:aws:iam::000000000000:role/ci

helm lint ./helm/frontend   --set imageRegistry=$REG --set imageTag=ci
helm lint ./helm/middleware --set imageRegistry=$REG --set imageTag=ci --set aws.roleArn=$ROLE
helm lint ./helm/ai-service --set imageRegistry=$REG --set imageTag=ci --set aws.roleArn=$ROLE
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

`apiBaseUrl: ""` means same-origin, served by the ALB Ingress in `helm/platform`. Remove that Ingress and
the failure is confusing rather than obvious: `nginx.conf` has no `/api` location, so a same-origin call
falls through to the SPA rewrite and returns `index.html` with HTTP 200. The Axios interceptor rejects an
HTML body for exactly that reason - see `frontend/src/api/client.js`.

## Things that will bite you

### Adding a config value touches four places

Skipping any one produces a value that works locally and is missing in production:

1. `AppProperties` (typed `@ConfigurationProperties` record)
2. `application.yml` — `${ENV_VAR:default}`
3. `helm/<service>/templates/configmap.yaml`
4. `helm/<service>/values.yaml` - there are no dev/prod overlays; the deploy workflow supplies what differs

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

## Infrastructure

Terraform applies the whole stack in one `terraform apply`. The numbers are for humans; Terraform derives
the real order from the dependency graph.

```
terraform/
├── 1.vpc.tf       VPC 10.0.0.0/16, 2 public + 2 private subnets, IGW, NAT
├── 2.eks.tf       cluster, node group, OIDC provider, 4 addons, EBS CSI IRSA role
├── 3.rds.tf       PostgreSQL 16.14, private subnets, SG referencing the cluster SG
├── 4.ecr.tf       three repositories
├── 5.secrets.tf   two Secrets Manager secrets, in the exact shape the apps parse
├── 6.iam.tf       one IRSA role per service
├── 7.github.tf    GitHub OIDC provider + the role Actions assumes, with an EKS access entry
└── parked/        an older full-stack module version, commented out
```

Cluster `ai-interview` in `ap-south-1`. The `kubernetes.io/role/elb` and `kubernetes.io/cluster/ai-interview`
subnet tags in `1.vpc.tf` are what let the load balancer controller find the public subnets; they must
match the cluster name.

**The load balancer controller is not in Terraform.** Its IAM role was created by
`eksctl create iamserviceaccount`, which builds a CloudFormation stack, and the controller itself by
`helm install` into `kube-system`. So `terraform destroy` leaves both behind - see the teardown note in
`terraform/README.md`.

### Secrets never become a Kubernetes Secret

Each pod reads Secrets Manager itself over IRSA — `APP_SECRETS_PROVIDER=aws` for the middleware,
`SECRETS_PROVIDER=aws` for the AI service. There is no Secret object in the namespace, so no amount of
RBAC exposes the database password.

The field names in `5.secrets.tf` are fixed by `AwsSecretsManagerSecretService.java` and
`backend/app/core/secrets.py`, and match what RDS managed rotation writes. Note **`dbname`**, not `dbName`.

**The Java SDK needs the `sts` module for IRSA.** Without it the default credential chain skips the
projected token entirely and the pod dies with "Unable to load credentials from any of the providers in
the chain". See the comment beside that dependency in `middleware/pom.xml`.

### Deploying

One chart per service plus `platform` for the default StorageClass. Install `platform` first.

```bash
helm upgrade --install middleware ./helm/middleware -n ai-interview   --set imageRegistry=<account>.dkr.ecr.ap-south-1.amazonaws.com   --set imageTag=<commit sha>   --set aws.roleArn=$(terraform output -raw middleware_role_arn)
```

`imageTag` and `aws.roleArn` have **no defaults** and the template refuses to render without them. Both
were previously defaulted, and both failed silently: a stale `v1` tag deployed the image built before the
`sts` fix, and an empty role ARN produced a ServiceAccount whose annotation injected no token.

The middleware rollout is `Recreate` — its volume is ReadWriteOnce, so the old pod must terminate first.
That is why each service has its own deploy workflow: an AI-service change must not cost the middleware
40 seconds of downtime.

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
