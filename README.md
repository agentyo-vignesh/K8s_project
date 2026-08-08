# AI Interview Platform

A production-shaped microservices application built as a **real-world DevOps
training project**. It manages candidates, schedules interviews, generates
interview questions with an AI service, and records results.

The application is deliberately real — authentication, RBAC, file upload, an
external dependency, a relational database — because containerisation, Kubernetes,
GitOps, IRSA, monitoring and production troubleshooting only mean something on top
of a system that actually does work.

```
React SPA  ──►  Spring Boot 3  ──►  FastAPI  ──►  PostgreSQL 16
  :3000            :8080            :8000          :5432
```

## Quickstart

```bash
git clone <repository-url>
cd ai-interview-platform
chmod +x scripts/*.sh
./scripts/dev-up.sh
```

`dev-up.sh` creates the four per-service env files, verifies they agree, builds
the images and waits for readiness.

| | |
|---|---|
| Frontend | http://localhost:3000 |
| API docs | http://localhost:8080/swagger-ui.html |
| AI service docs | http://localhost:8000/docs |
| Metrics | http://localhost:8080/actuator/prometheus |

Sign in as `admin@aiinterview.local` / `Admin@12345`. Then verify end to end:

```bash
./scripts/smoke-test.sh
```

Full instructions: [docs/SETUP.md](docs/SETUP.md).

## Stack

| Layer | Technology |
|---|---|
| Frontend | React 18, Material UI, Axios, React Router, Vite |
| Middleware | Spring Boot 3.3, Java 21, Spring Security, JWT, Spring Data JPA, Flyway, Actuator, Micrometer |
| AI service | FastAPI, Pydantic v2, SQLAlchemy 2, OpenAI SDK behind an interface |
| Database | PostgreSQL 16 |
| Infrastructure | Docker, Kubernetes, Helm, Amazon EKS, Terraform, GitHub Actions |

## Features

**Authentication** — JWT with refresh-token rotation, server-side revocation on
logout, BCrypt password hashing, three roles (Admin, Interviewer, Candidate).

**Candidates** — create, update, delete, paged case-insensitive search across
name, email, skill and company.

**Resumes** — upload with content-type and size validation, SHA-256 checksums,
metadata in PostgreSQL, bytes on local disk or S3 behind one interface.

**Interviews** — scheduling, interviewer assignment, an enforced status state
machine, AI-generated questions, and scorecards whose overall score is derived
server-side so it cannot contradict its own breakdown.

**Dashboard** — totals, per-status breakdowns, mean score, upcoming interviews.

## Running a session with it

Two scripts bracket a session. Build the whole stack from an empty account, teach
against it, then destroy it so the day costs about a dollar:

```bash
./scripts/bootstrap.sh      # empty account -> running app, about 35 minutes
./scripts/teardown.sh       # the reverse
```

Read both before running either. The ordering inside them **is** the lesson:
Kubernetes controllers create AWS resources that Terraform never sees, so
`terraform apply` alone does not finish the job and `terraform destroy` alone
cannot undo it.

## What makes it a DevOps teaching platform

**One image per service, promoted unchanged.** Every setting is an environment
variable. The frontend reads its API URL at runtime from `window.__APP_CONFIG__`,
rendered by the container entrypoint — so there is no build-per-environment.

**No AWS access keys anywhere.** Both services build AWS clients with the default
credential provider chain only. On EKS that resolves the IRSA-projected token; on
a laptop it finds your SSO profile. The `SecretService` / `SecretProvider`
abstraction means switching from environment variables to Secrets Manager is one
Helm value and zero code changes.

**Failures are designed to be instructive.**

- Liveness never touches the database, so a database blip cannot cause a restart
  storm.
- AI-service health is excluded from the middleware's readiness group, so an AI
  outage degrades question generation instead of pulling every pod from the
  Service.
- The AI call runs outside any transaction, so a slow provider cannot exhaust the
  connection pool.
- Bad configuration fails at startup, so a broken secret is a pod that never
  becomes ready rather than a service that 500s under load.

[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) includes deliberate failure
exercises for each of these.

**Correlation across services.** Every response carries `X-Request-Id`; both
services emit it as a top-level JSON log field, so one id spans both services'
logs in Loki.

## Repository layout

```
frontend/     React SPA                       + frontend/.env
middleware/   Spring Boot API (owns schema)   + middleware/.env
backend/      FastAPI AI service              + backend/.env
database/     Container bootstrap only        + database/.env
helm/         one chart per service, plus platform/ for the shared pieces
terraform/    all AWS infrastructure, applied in one command
.github/      CI, CD, security scanning, Dependabot
docs/         Architecture, API, setup, deployment, troubleshooting
scripts/      dev-up, dev-down, build, smoke-test, check-env, secrets
```

**Configuration is one env file per service** — there is no shared root `.env`.
Each service reads only its own file. The few values that must agree across files
(database credentials, the internal API key) are verified by
`./scripts/check-env.sh`, which `dev-up.sh` runs before starting anything.

Detail: [docs/FOLDER_STRUCTURE.md](docs/FOLDER_STRUCTURE.md).

## Verification status

Every component builds and its checks pass on a clean checkout:

| Component | Command | Result |
|---|---|---|
| Middleware | `mvn -B verify` | 70 tests pass, jar built |
| AI service | `pytest` / `ruff` / `mypy` | 75 tests pass, lint and types clean |
| Frontend | `npm run lint` / `test` / `build` | 19 tests pass, lint clean, bundle built |
| Helm | `helm lint` + `helm template` | Clean for default, dev and prod values |
| Compose | `docker compose up` + `scripts/smoke-test.sh` | 4/4 containers healthy, **20/20 smoke tests pass** |

The smoke test exercises the real chain — login → candidate CRUD → interview →
**Spring Boot → FastAPI → PostgreSQL** question generation → result → logout — and
asserts a revoked token is actually rejected.

## CI/CD

Two pairs of workflows, one pair per side of the app. Each only runs when its own
files change.

| Workflow | Trigger | Does |
|---|---|---|
| `ci-frontend.yml` | `frontend/**`, `helm/frontend/**` | lint, test, build; lint + render the chart |
| `ci-middleware.yml` | `middleware/**`, `helm/middleware/**` | `mvn verify`; chart checks |
| `ci-ai-service.yml` | `backend/**`, `helm/ai-service/**` | ruff, mypy, pytest; chart checks |
| `deploy-*.yml` | push to `main` | build image → push to ECR → `helm upgrade` |
| `security.yml` | PR, nightly | GitLeaks, Trivy, CodeQL |

One CI and one deploy per service, so a change to one never rebuilds another.
That matters most for the middleware: its rollout is `Recreate`, so an
unnecessary redeploy costs about 40 seconds of API downtime.

**These pipelines deploy application code, not infrastructure.** Terraform is
run by hand - see [terraform/README.md](terraform/README.md). A CI job could
run `fmt -check` and `validate`, but without AWS credentials it cannot run
`plan`, so it would never answer the question that matters: what does this
change destroy? `terraform plan` answers that, locally, before you apply.

**CI never touches AWS.** It only answers "is the code good?" — no credentials,
no cluster access. The deploy workflows are the only ones that authenticate, and
they do it with GitHub OIDC, so there is no AWS key stored in the repository.

The deploy workflows need `AWS_DEPLOY_ROLE_ARN` as a repository secret, and that
role needs an EKS access entry or `helm upgrade` fails with
`You must be logged in to the server`.

## Deploying to EKS

```bash
./scripts/bootstrap.sh
```

That is the whole thing, and it is worth reading rather than just running,
because four orderings in it are not obvious:

**Terraform is not the whole story.** It applies 52 resources per environment —
VPC, EKS, RDS, ECR, Secrets Manager, the IRSA roles — plus one account-level
resource from `terraform/global`. It does **not** install the AWS Load Balancer
Controller, whose IAM role comes from `eksctl create iamserviceaccount` as a
CloudFormation stack.

**The StorageClass must precede the middleware**, whose PVC would otherwise stay
Pending forever — EKS ships no default StorageClass. **The Ingress must follow the
Services**, because the controller builds the ALB from the Services its rules
name. Those pull in opposite directions, so `helm/platform` is installed twice.

**`middleware` before `ai-service`.** Flyway creates the `ai_*` tables the AI
service reads.

**No password is passed to Helm, ever.** There is no Kubernetes Secret in the
namespace. Each pod reads Secrets Manager itself over IRSA, so `imageTag` and
`aws.roleArn` are the only values a deploy supplies — and neither has a default,
because both once had one and both failed silently.

Details: [terraform/README.md](terraform/README.md) and [CLAUDE.md](CLAUDE.md).

## Documentation

| Document | Covers |
|---|---|
| **[CLAUDE.md](CLAUDE.md)** | **Infrastructure, deployment, and the rules that are enforced in review** |
| **[RBAC_VS_IRSA.md](docs/RBAC_VS_IRSA.md)** | **The two directions of cluster authorisation, verified against a live cluster** |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Diagrams, request flows, design decisions, known simplifications |
| [SETUP.md](docs/SETUP.md) | Local development, running services natively |
| [API.md](docs/API.md) | Endpoints, error format, pagination, roles |
| [DEVELOPER_GUIDE.md](docs/DEVELOPER_GUIDE.md) | Layering rules, testing, conventions |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Failure modes and deliberate exercises |
| [FOLDER_STRUCTURE.md](docs/FOLDER_STRUCTURE.md) | Every directory and why |
| [terraform/README.md](terraform/README.md) | The three roots, and exactly what an environment creates |

## Security notes

The seed accounts above are created by Flyway migration `V3`, are documented in
this README, and are allowlisted in `.gitleaks.toml`. **Delete or rotate them
before deploying anywhere holding real data.**

**No Kubernetes Secret exists in the namespace.** Each pod reads Secrets Manager
directly over IRSA, and its role's trust policy names one ServiceAccount, so no
other pod can assume it. Nothing sensitive is rendered into a manifest, passed to
Helm, or committed.

**The ALB is HTTP only.** There is no domain, so there is no certificate. A JWT
crosses the internet in clear text. That is acceptable for a training cluster and
for nothing else.

## Licence

Apache-2.0.
