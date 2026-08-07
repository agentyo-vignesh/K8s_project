# Folder structure

```
ai-interview-platform/
├── frontend/          React SPA            + .env.example
├── middleware/        Spring Boot API      + .env.example   (owns the DB schema)
├── backend/           FastAPI AI service   + .env.example
├── database/          Container bootstrap  + .env.example   (DDL lives in middleware/)
├── helm/              Helm chart
├── terraform/         all AWS infrastructure, 7 numbered files
├── .github/           CI/CD, Dependabot, PR template
├── docs/              This documentation
├── scripts/           Development and operational scripts
├── docker-compose.yml Local stack
├── .gitleaks.toml     Secret-scanning config
└── sonar-project.properties
```

**There is no root `.env`.** Configuration is one file per service, sitting beside
the code it configures. Each service's `env_file` in `docker-compose.yml` points at
its own file only, so a component cannot read a value that belongs to another.

The trade-off: the database credentials appear in three files and the internal API
key in two, because two services share a database and one authenticates to the
other. Nothing in Docker checks they agree, so `scripts/check-env.sh` does — and
`dev-up.sh` refuses to start on a mismatch.

`backend/` is the AI service, not "the backend" in the usual sense — the naming
comes from the project layout requirement. `middleware/` is the primary API.

---

## `frontend/`

```
frontend/
├── Dockerfile              Multi-stage: node build → nginx runtime
├── nginx.conf              SPA history fallback, /healthz, security headers
├── docker-entrypoint.sh    Renders runtime-config.js from env at container start
├── vite.config.js          Dev proxy, manual chunks, vitest config
├── public/
│   └── runtime-config.js   Dev placeholder; overwritten in the container
└── src/
    ├── main.jsx            Entry point
    ├── App.jsx             Routes
    ├── config.js           Reads window.__APP_CONFIG__
    ├── theme.js            MUI theme
    ├── api/
    │   ├── client.js       Axios instance, auth header, 401 refresh handling
    │   └── endpoints.js    One function per endpoint
    ├── auth/
    │   ├── AuthContext.jsx Token storage, login/logout
    │   └── ProtectedRoute.jsx  Route guard by role
    ├── components/         Layout, dialogs, notifications, state views
    ├── hooks/              useApiResource, useDebouncedValue
    ├── pages/              One per route
    ├── utils/              Date formatting
    └── test/               Vitest suites
```

**The API base URL is not baked into the bundle.** `docker-entrypoint.sh` writes
`runtime-config.js` from `API_BASE_URL` at container start and the app reads
`window.__APP_CONFIG__`. That is what lets one image be promoted from dev to prod
unchanged — the alternative is an image per environment, which defeats the point
of promoting a tested artifact.

---

## `middleware/`

```
middleware/src/main/
├── java/ai/interview/middleware/
│   ├── MiddlewareApplication.java
│   ├── config/          AppProperties, SecurityConfig, DataSourceConfig,
│   │                    AwsClientConfig, RestClientConfig, OpenApiConfig
│   ├── common/          PageResponse, ErrorResponse, ErrorCode
│   ├── domain/
│   │   ├── entity/      JPA entities
│   │   └── enums/       Role, InterviewStatus, …
│   ├── repository/
│   │   ├── spec/        JPA Specifications for search
│   │   └── projection/  GROUP BY projections
│   ├── dto/             Request/response records by feature
│   ├── mapper/          Entity ↔ DTO, hand-written
│   ├── security/        JwtService, filters, principal, error writers
│   ├── service/
│   │   ├── secret/      SecretService + env/AWS implementations
│   │   ├── storage/     FileStorageService + local/S3 implementations
│   │   └── ai/          AI client behind an interface
│   └── web/
│       ├── controller/  REST controllers
│       ├── health/      AiServiceHealthIndicator
│       └── GlobalExceptionHandler.java
└── resources/
    ├── application.yml           Base — every value an env var
    ├── application-{dev,test,prod}.yml
    ├── logback-spring.xml        Plain in dev, JSON elsewhere
    └── db/migration/             Flyway — authoritative schema
```

Three directories carry most of the design weight:

- **`service/secret/`** — the abstraction that makes IRSA work with no code change.
  `DataSourceConfig` builds the connection pool from it, so there is no JDBC URL or
  password in any config file.
- **`service/storage/`** — local disk or S3 behind one interface, selected by a
  property. `ResumeService` does not know which it has.
- **`repository/spec/`** — Specifications rather than JPQL with `:param IS NULL`
  guards, so the generated SQL contains only the filters the caller supplied and
  PostgreSQL can use the indexes.

---

## `backend/`

```
backend/
├── Dockerfile           Multi-stage: wheels → slim runtime, non-root
├── pyproject.toml       ruff, mypy, pytest, coverage
├── requirements.txt     Runtime, pinned exactly
├── requirements-dev.txt Test and lint tooling
├── app/
│   ├── main.py          App factory, lifespan, exception handlers
│   ├── core/
│   │   ├── config.py        Pydantic Settings
│   │   ├── secrets.py       SecretProvider + env/AWS implementations
│   │   ├── security.py      Internal API key dependency
│   │   ├── logging_config.py  JSON formatter, request-id ContextVar
│   │   ├── metrics.py       Prometheus registry
│   │   └── errors.py        Error types + handlers
│   ├── db/
│   │   ├── models.py    SQLAlchemy models for the ai_* tables
│   │   ├── types.py     Guid/JsonPayload — portable across PG and SQLite
│   │   └── session.py   Engine built from SecretProvider
│   ├── providers/
│   │   ├── base.py           QuestionGenerator / AnswerEvaluator protocols
│   │   ├── mock_provider.py  Deterministic, offline, free
│   │   ├── openai_provider.py
│   │   └── factory.py
│   ├── schemas/         Pydantic wire models
│   ├── services/        Business logic + persistence
│   └── api/
│       ├── routers/     health, info, questions, evaluations
│       ├── dependencies.py
│       └── middleware.py    Request id, metrics, access logging
└── tests/
```

**`db/types.py` is why the tests need no database.** `Guid` and `JsonPayload` map
to native `uuid`/`jsonb` on PostgreSQL and to `CHAR(36)`/`JSON` elsewhere, so
`create_all()` builds a working schema in SQLite while production uses the
Flyway-managed one.

**`providers/` is a protocol with two implementations.** The mock is the default:
deterministic, offline, no spend — which is what CI and demos need. Swapping to
OpenAI is one environment variable.

---

## `database/`

```
database/
├── init/01-init-database.sql   Roles, grants, database settings
└── README.md                   Ownership, conventions, connecting
```

Deliberately thin. It creates **no application tables** — Flyway in the middleware
owns all DDL so there is one schema authority and one migration history, even
though two services share the database.

---

## `helm/ai-interview-platform/`

```
├── Chart.yaml
├── values.yaml         Defaults (dev-shaped)
├── values-dev.yaml      In-cluster DB, 1 replica, mock AI, Swagger on
├── values-prod.yaml     RDS, IRSA, S3, HPA, ServiceMonitors, Swagger off
└── templates/
    ├── _helpers.tpl              Naming, labels, image refs, DB resolution
    ├── configmap.yaml            Non-secret config for both services
    ├── secret.yaml               Dev only; not rendered in prod
    ├── serviceaccount.yaml       IRSA annotations
    ├── {frontend,middleware,ai-service}-deployment.yaml
    ├── services.yaml
    ├── postgresql.yaml           Dev-only StatefulSet
    ├── pvc.yaml                  Local storage backend only
    ├── hpa.yaml, pdb.yaml, ingress.yaml
    ├── networkpolicy.yaml        Default-deny + explicit allows
    ├── servicemonitor.yaml       ServiceMonitor + PrometheusRule
    └── NOTES.txt                 Post-install output with config warnings
```

Verified with `helm lint` and `helm template` against all three value sets. Prod
renders 20 objects and **no Secret** — credentials come from Secrets Manager at
runtime, so nothing sensitive appears in a manifest or in ArgoCD.

---

## `terraform/`

Only the network and the database are codified. Everything else is created
manually per [DEPLOYMENT.md](DEPLOYMENT.md). Nothing was deleted — the rest sits
in `terraform/parked/`, documented in
[`../terraform/README.md`](../terraform/README.md).

```
terraform/
├── 1.vpc.tf        network — VPC, subnets, NAT. Carries terraform{} and provider{}
├── 2.eks.tf        cluster, nodes, addons, OIDC provider
├── 3.rds.tf        PostgreSQL in the private subnets
├── 4.ecr.tf        three container registries
├── 5.secrets.tf    Secrets Manager — the values the pods read
├── 6.iam.tf        IRSA roles, one per service
├── 7.github.tf     the role GitHub Actions assumes to deploy
└── parked/         an older full-stack version — not loaded by Terraform
```

Everything applies in one `terraform apply`. The numbers are for humans;
Terraform works out the real order from the dependencies between resources.

Terraform only loads `.tf` files in the working directory, not subdirectories, so
`parked/` is inert without commenting anything out.

| `parked/` file | Contents (when restored) |
|---|---|
| `versions.tf` | Providers, pinned versions, S3 backend |
| `variables.tf` | Inputs, validated |
| `main.tf` | VPC, subnets, NAT, flow logs, VPC endpoints, EKS, node group |
| `ecr.tf` | Three repositories + lifecycle; the resume S3 bucket |
| `iam.tf` | IRSA roles, trust policies, GitHub OIDC deployment role |
| `outputs.tf` | Values for Helm, including a ready-made values snippet |
| `rds-production.tf.parked` | The production-shaped RDS config, verbatim |
| `terraform.tfvars.example` | Sample inputs for `variables.tf` |

`parked/iam.tf` is worth reading even while parked: it documents the exact
trust-policy shape the manual setup has to reproduce. The `sub` condition is what
stops any pod in the cluster from assuming an application role.

---

## `.github/`

```
.github/
├── workflows/
│   ├── ci-frontend.yml        test + build, lint the chart
│   ├── ci-middleware.yml      mvn verify, lint the chart
│   ├── ci-ai-service.yml      ruff + mypy + pytest, lint the chart
│   ├── deploy-frontend.yml    build → ECR → helm upgrade
│   ├── deploy-middleware.yml  one per service, so one never redeploys another
│   ├── deploy-ai-service.yml
│   └── security.yml           Trivy (filesystem), CodeQL
├── dependabot.yml      Patch and security updates only, monthly
└── pull_request_template.md
```

Each service has one CI and one deploy, and the deploy starts from
`workflow_run` on its own CI - so nothing ships that CI did not pass.

The two scans that must gate a deploy do not live in `security.yml`, because
that workflow runs on pull requests and nightly and so cannot gate a push
straight to `main`. GitLeaks runs as the `secrets` job in each CI, and the Trivy
image scan runs inside each deploy between `docker build` and `docker push`, so
a vulnerable image never reaches ECR.

---

## `scripts/`

| Script | Purpose |
|---|---|
| `dev-up.sh` | Build, start, **and wait for readiness** |
| `dev-down.sh` | Stop; `--volumes` also wipes data |
| `build-images.sh` | Build/push all three with one shared tag |
| `smoke-test.sh` | End-to-end assertions against a running stack |
| `generate-secrets.sh` | Strong secrets; `--env`, `--helm`, `--aws` output |

---

## Where to change what

| Task | Files |
|---|---|
| New API endpoint | `middleware/.../dto/`, `service/`, `web/controller/` |
| New config value | `AppProperties` → `application.yml` → `configmap.yaml` → both values files |
| Schema change | New `V<n>__` migration + JPA entity (+ SQLAlchemy model for `ai_*`) |
| New AI provider | `backend/app/providers/` + `factory.py` + DB check constraint |
| Resource limits | `helm/.../values-*.yaml` |
| New AWS permission | `terraform/parked/iam.tf` |
| Pipeline change | `.github/workflows/` |
