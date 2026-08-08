# Database

PostgreSQL 16. One database, `ai_interview`, shared by two services.

## Who owns what

| Concern | Owner | Location |
|---|---|---|
| Container bootstrap (roles, grants, database settings) | postgres image entrypoint | [`init/01-init-database.sql`](init/01-init-database.sql) |
| All DDL and seed data | **Flyway, run by the middleware** | [`../middleware/src/main/resources/db/migration/`](../middleware/src/main/resources/db/migration/) |
| `users`, `candidates`, `resumes`, `interviews`, `interview_questions`, `interview_results`, `revoked_tokens` | middleware (JPA) | `V1`, `V3` |
| `ai_question_sets`, `ai_generated_questions`, `ai_evaluations` | AI service (SQLAlchemy) | `V2` |

Two services read and write one database, but only **one of them owns the schema**.
Flyway creates every table, including the three the Python service maps to. The AI
service never runs `create_all()` outside its own test suite, where it targets an
in-memory SQLite database.

The alternative — each service migrating its own tables — needs two migration
histories against one database and a deployment ordering contract between them.
For a platform this size that costs more than it buys. `tests/test_schema_parity.py`
in the AI service compares its models against `V2` and fails if they drift, which is
the guard that makes the shared-ownership arrangement safe.

## Migrations

Flyway runs automatically when the middleware starts (`spring.flyway.enabled=true`).

```
V1__create_core_schema.sql     tables, indexes, foreign keys, check constraints
V2__create_ai_schema.sql       AI service tables
V3__seed_reference_data.sql    demo users, candidates, interviews, results
```

Rules:

- **Migrations are immutable once merged.** Flyway records a checksum; editing an
  applied migration makes every existing environment fail validation on next start.
  Fix forward with `V4__...`.
- **Additive changes only** where possible. A column drop or rename must be split
  across releases (add, backfill, switch reads, drop) so a rollback does not lose data.
- Filenames are `V<n>__snake_case_description.sql`. The double underscore is required.

### Seed data in production

`V3` inserts demo accounts with known passwords. It is fine for dev and for a
training cluster; it is not fine for anything holding real data. To skip it, set
`FLYWAY_ENABLED=false` on the middleware and apply `V1`/`V2` yourself before the
first deploy.

## Schema shape

```
users ──────┬──< candidates ──┬──< resumes
            │                 └──< interviews ──┬──< interview_questions
            ├──< interviews (interviewer_id)    ├──── interview_results (1:1)
            └──< revoked_tokens                 ├──< ai_question_sets ──< ai_generated_questions
                                                └──< ai_evaluations
```

Conventions:

- Primary keys are **application-generated UUIDs**, not `gen_random_uuid()`. That
  keeps the runtime database user free of any extension-creation privilege on RDS,
  and lets a service build a full object graph before its first flush.
- All timestamps are `timestamptz`, written in UTC.
- Enumerations are `varchar` + `CHECK`, not native enum types: readable in `psql`,
  and adding a value is an ordinary migration rather than an `ALTER TYPE`.
- `version bigint` backs JPA optimistic locking on mutable tables.

## Connecting

```bash
# Docker Compose
docker compose exec postgres psql -U ai_interview_app -d ai_interview

# Applied migrations
docker compose exec postgres psql -U ai_interview_app -d ai_interview \
  -c "SELECT version, description, success, installed_on FROM flyway_schema_history ORDER BY installed_rank;"
```

Credentials come from `.env` locally and, on EKS, from AWS Secrets Manager read by
the pod itself over IRSA — see [`../CLAUDE.md`](../CLAUDE.md). There is no
connection string in any configuration file in this repository, and no Kubernetes
Secret in the namespace.
