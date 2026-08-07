# Developer guide

Conventions, workflows and the reasoning behind them. Read
[ARCHITECTURE.md](ARCHITECTURE.md) first for the shape of the system.

## Workflow

```bash
git checkout -b feat/candidate-tags
# change, test
cd middleware && mvn verify
git commit -m "feat(candidate): add skill tags"
git push -u origin feat/candidate-tags
```

CI runs per component with path filters, so a frontend change does not rebuild
Java. `ci-passed` is the single required status check — it treats *skipped* as
acceptable so a docs-only PR is not blocked, but fails on any real failure.

### Commit messages

Conventional Commits: `type(scope): summary`.

```
feat(interview): add round-robin interviewer assignment
fix(auth): reject refresh tokens presented as access tokens
chore(deps): bump spring-boot to 3.3.6
```

Dependabot and the CD workflow both produce commits in this format.

## Layering

The middleware follows a strict layered architecture. Dependencies point one way:

```
Controller  →  Service  →  Repository  →  Entity
     ↓            ↓
    DTO        Mapper
```

Rules that are enforced in review:

- **A controller contains no business logic.** It validates, delegates, and maps
  the result to a response.
- **An entity never leaves the service layer.** Controllers return DTOs. This is
  what stops `passwordHash` reaching a JSON response by accident.
- **A repository is never injected into a controller.**
- **Authorization that depends on data lives in the service**, not the controller.
  `InterviewService.search` scopes `CANDIDATE` callers inside the query, so no
  endpoint can leak another candidate's data by forgetting a check.

### Adding an endpoint

1. Request/response records in `dto/`, with Jakarta validation and `@Schema`
2. Business logic in the relevant `service/` class
3. Controller method with `@PreAuthorize`, `@Operation` and `@ApiResponse`
4. A test for the success path **and** at least one failure path

```java
@PostMapping("/{id}/archive")
@PreAuthorize("hasAnyRole('ADMIN', 'INTERVIEWER')")
@Operation(summary = "Archive a candidate")
@ApiResponse(responseCode = "200", description = "Archived")
@ApiResponse(responseCode = "404", description = "No such candidate")
public ResponseEntity<CandidateResponse> archive(@PathVariable UUID id) {
    return ResponseEntity.ok(candidateService.archive(id));
}
```

## Configuration

**Never hardcode anything environment-specific.** Every value is an environment
variable with a development default, bound to a typed `@ConfigurationProperties`
record so binding fails at startup rather than at first use.

Adding a setting means touching four places, and skipping any of them produces a
value that works locally and is missing in production:

1. `AppProperties` — the typed field
2. `application.yml` — `${ENV_VAR:default}`
3. `helm/.../configmap.yaml` — the ConfigMap entry
4. `values.yaml` **and** `values-dev.yaml`/`values-prod.yaml`

Same for the AI service: `Settings` in `app/core/config.py`, then the chart.

### Secrets

Never a plain config value. Add it to `SecretService` / `SecretProvider` so both
the environment and AWS implementations supply it, and it is resolved the same way
everywhere. Nothing secret is ever logged — the credential records override
`toString`/`__repr__` to guarantee it.

## Testing

| Component | Command | What it runs |
|---|---|---|
| Middleware | `mvn verify` | 70 JUnit 5 + Mockito tests, JaCoCo coverage |
| AI service | `pytest` | 75 tests against in-memory SQLite |
| Frontend | `npm run test -- --run` | Vitest |

### What to test

Test decisions, not accessors. The existing suites are a guide:

- `InterviewStatusTest` — the state machine exhaustively, because a wrong
  transition table silently corrupts the dashboard's completed/pending counts
- `StorageKeyFactoryTest` — path traversal and hidden-file cases, because that
  method turns an attacker-controlled filename into a filesystem path
- `JwtServiceTest` — that a refresh token is rejected where an access token is
  required, in both directions
- `InterviewResultTest` — rounding behaviour, which would otherwise drift unnoticed

Do not write a test that asserts a getter returns what a setter set.

### The AI service tests need no database

`app/db/types.py` provides `Guid` and `JsonPayload` type decorators that map to
native `uuid`/`jsonb` on PostgreSQL and to `CHAR(36)`/`JSON` elsewhere. That is
what lets `create_all()` build the schema in SQLite for tests while production
uses the Flyway-managed PostgreSQL schema.

`tests/test_schema_parity.py` compares the models against `V2__create_ai_schema.sql`
and fails if they drift. **If you change an `ai_*` table, change both.**

## Database changes

Flyway owns every table. Migrations are immutable once merged.

```bash
# new file, next number
middleware/src/main/resources/db/migration/V4__add_candidate_tags.sql
```

- **Never edit an applied migration.** Flyway stores a checksum; an edit makes
  every existing environment fail validation on next start.
- **Additive changes only**, or split across releases: add column → backfill →
  switch reads → drop in a later release. A rollback must not lose data.
- Update the JPA entity to match, and the SQLAlchemy model if it is an `ai_*` table.

Test locally against a clean database:

```bash
./scripts/dev-down.sh --volumes && ./scripts/dev-up.sh
```

## Code style

### Java

- Records for DTOs; classes for entities
- Constructor injection, no field injection — it makes dependencies visible and
  the class testable without a container
- `Optional` for return values that may be absent, never for parameters or fields
- Comments explain *why*. The code already says what.

### Python

- Full type annotations; `mypy` runs in CI with `disallow_untyped_defs`
- `ruff` with a 120-column limit
- Pydantic models for anything crossing the wire; dataclasses for internal values
- Narrow types with `isinstance` rather than casting — see
  `EvaluationService._score_from_row`, which turns a corrupt JSONB row into a
  clear 503 instead of an opaque `TypeError`

### React

- Function components and hooks only
- Data fetching through `useApiResource`, not `useEffect` in a page
- MUI's `sx` prop; no separate stylesheet
- A helper named `useX` **is** a hook. Naming a plain callback `useFoo` breaks the
  rules-of-hooks lint, correctly.

## Observability

Add a metric when you add something that can be slow or can fail:

```java
Timer.builder("ai.question.generation")
     .publishPercentileHistogram()
     .register(meterRegistry);
```

Watch cardinality. Label by *route template*, never by a concrete URL — labelling
by raw path creates one time series per interview id and will eventually take
Prometheus down.

Log with structure, not string concatenation:

```python
logger.info("Generated question set", extra={"setId": str(set_id), "provider": provider})
```

The JSON formatter promotes `extra` keys to top-level fields, so they are queryable
in Loki rather than buried in a message string.

## Common tasks

**Add a role** — extend `Role`, update the `ck_users_role` constraint in a new
migration, add it to the `@PreAuthorize` expressions that should accept it.

**Add an AI provider** — implement `QuestionGenerator` in `app/providers/`,
register it in `factory.py`, add the value to the `AI_PROVIDER` enum and to the
`ck_ai_question_sets_provider` constraint.

**Change the storage backend** — implement `FileStorageService`, annotate with
`@ConditionalOnProperty(name = "app.storage.type", havingValue = "...")`. Nothing
else changes: `ResumeService` does not know which backend it has.

## Before opening a PR

```bash
cd middleware && mvn verify
cd backend && ruff check . && mypy app && pytest
cd frontend && npm run lint && npm run test -- --run && npm run build
helm lint ./helm/frontend --set imageRegistry=x --set imageTag=ci
terraform -chdir=terraform fmt -check -recursive
```

The PR template's checklist covers the rest — particularly the database and
deployment sections, which are where an otherwise-correct change causes an outage.
