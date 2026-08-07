# API reference

Interactive documentation is generated from the code and is always authoritative:

- Middleware — http://localhost:8080/swagger-ui.html (OpenAPI at `/v3/api-docs`)
- AI service — http://localhost:8000/docs (OpenAPI at `/openapi.json`)

This document covers the conventions that hold across every endpoint.

## Base URL and versioning

```
/api/v1
```

The version is in the path. A breaking change ships as `/api/v2` alongside `v1`
rather than mutating the existing contract.

## Authentication

All endpoints except `POST /auth/login`, `POST /auth/refresh` and the probe
endpoints require:

```
Authorization: Bearer <accessToken>
```

```bash
TOKEN=$(curl -s -X POST http://localhost:8080/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@aiinterview.local","password":"Admin@12345"}' \
  | jq -r .accessToken)

curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/api/v1/candidates
```

Access tokens last 30 minutes, refresh tokens 8 hours. **Refresh rotates**: the
presented refresh token is revoked as the new pair is issued, so each one is
usable exactly once and replay is detectable.

## Roles

| Role | Can |
|---|---|
| `ADMIN` | Everything, including deleting candidates and interviews |
| `INTERVIEWER` | Manage candidates, interviews, questions and results |
| `CANDIDATE` | Read only their own interviews; model answers are withheld |

Candidate scoping is enforced **in the query**, not the controller: a `CANDIDATE`
caller's interview searches are filtered to their own candidate record regardless
of the parameters supplied.

## Error format

Every error, from every endpoint, has one shape:

```json
{
  "timestamp": "2026-08-04T10:15:30Z",
  "status": 400,
  "error": "Bad Request",
  "code": "VALIDATION_FAILED",
  "message": "Request validation failed",
  "path": "/api/v1/candidates",
  "requestId": "9f1c2d3e-4a5b-6c7d-8e9f-0a1b2c3d4e5f",
  "fieldErrors": [
    { "field": "email", "message": "must be a well-formed email address", "rejectedValue": "nope" }
  ]
}
```

Branch on `code`, not on `message` — wording can improve without warning.

| Code | Status | Meaning |
|---|---|---|
| `VALIDATION_FAILED` | 400 | Bean validation failed; see `fieldErrors` |
| `BAD_REQUEST` | 400 | Semantically invalid (e.g. illegal status transition) |
| `MALFORMED_REQUEST` | 400 | Body is not valid JSON for this endpoint |
| `AUTHENTICATION_FAILED` | 401 | No credentials presented |
| `INVALID_TOKEN` | 401 | Token expired, revoked, malformed or of the wrong type |
| `ACCESS_DENIED` | 403 | Authenticated but not permitted |
| `RESOURCE_NOT_FOUND` | 404 | No such entity |
| `DUPLICATE_RESOURCE` | 409 | Uniqueness violation (e.g. candidate email) |
| `CONFLICT` | 409 | Concurrent modification; reload and retry |
| `PAYLOAD_TOO_LARGE` | 413 | Upload exceeds the limit |
| `AI_SERVICE_UNAVAILABLE` | 503 | AI service unreachable after retries |
| `INTERNAL_ERROR` | 500 | Unexpected; quote `requestId` when reporting |

`requestId` is echoed in the `X-Request-Id` response header and appears as a
top-level field in both services' JSON logs. Send `X-Request-Id` yourself to
correlate a trace you already started.

## Pagination

List endpoints accept `page`, `size` and `sort`:

```
GET /api/v1/candidates?page=0&size=20&sort=createdAt,desc
```

`size` is capped at 100 server-side, so `?size=100000` cannot exhaust heap.

```json
{
  "content": [],
  "page": 0,
  "size": 20,
  "totalElements": 137,
  "totalPages": 7,
  "first": true,
  "last": false,
  "numberOfElements": 20
}
```

This envelope is deliberate rather than Spring's `PageImpl`, whose JSON shape is
an implementation detail that has changed between Spring Data versions.

## Endpoints

### Authentication

| Method | Path | Role | Description |
|---|---|---|---|
| POST | `/auth/login` | — | Exchange credentials for a token pair |
| POST | `/auth/refresh` | — | Rotate a refresh token |
| POST | `/auth/logout` | any | Revoke the session (idempotent) |
| GET | `/auth/me` | any | The authenticated user |

### Candidates

| Method | Path | Role | Description |
|---|---|---|---|
| GET | `/candidates` | ADMIN, INTERVIEWER | Search; `search`, `status`, `primarySkill`, `minExperience` |
| GET | `/candidates/{id}` | ADMIN, INTERVIEWER | One candidate with resume/interview counts |
| POST | `/candidates` | ADMIN, INTERVIEWER | Create |
| PUT | `/candidates/{id}` | ADMIN, INTERVIEWER | Update (omitting `status` leaves it unchanged) |
| DELETE | `/candidates/{id}` | ADMIN | Cascades to resumes and interviews |

`search` matches first name, last name, email, primary skill and current company,
case-insensitively.

### Resumes

| Method | Path | Role | Description |
|---|---|---|---|
| POST | `/candidates/{id}/resumes` | ADMIN, INTERVIEWER | Multipart upload, part name `file` |
| GET | `/candidates/{id}/resumes` | ADMIN, INTERVIEWER | List, newest first |
| GET | `/resumes/{id}` | ADMIN, INTERVIEWER | Metadata |
| GET | `/resumes/{id}/download` | ADMIN, INTERVIEWER | The file |
| DELETE | `/resumes/{id}` | ADMIN, INTERVIEWER | Delete metadata and stored bytes |

PDF, DOC, DOCX and plain text up to 10 MB. `storageKey` is never returned: it is
an internal locator.

```bash
curl -X POST http://localhost:8080/api/v1/candidates/$ID/resumes \
  -H "Authorization: Bearer $TOKEN" -F "file=@resume.pdf"
```

### Interviews

| Method | Path | Role | Description |
|---|---|---|---|
| GET | `/interviews` | any | Search; candidates see only their own |
| GET | `/interviews/{id}` | any | Detail with questions |
| POST | `/interviews` | ADMIN, INTERVIEWER | Schedule |
| PUT | `/interviews/{id}` | ADMIN, INTERVIEWER | Update |
| PATCH | `/interviews/{id}/interviewer` | ADMIN, INTERVIEWER | Assign or reassign |
| PATCH | `/interviews/{id}/status` | ADMIN, INTERVIEWER | Transition status |
| DELETE | `/interviews/{id}` | ADMIN | Cascades to questions and result |
| GET | `/interviews/{id}/questions` | any | Questions in sequence order |
| POST | `/interviews/{id}/questions/generate` | ADMIN, INTERVIEWER | Generate via the AI service |
| GET | `/interviews/{id}/result` | any | The scorecard |
| POST | `/interviews/{id}/result` | ADMIN, INTERVIEWER | Submit or replace |

Legal status transitions:

```
SCHEDULED ──> IN_PROGRESS ──> COMPLETED
    │              │
    └──────────────┴────────> CANCELLED

COMPLETED and CANCELLED are terminal.
```

Anything else is a 400 rather than being silently applied.

**Question generation.** An empty body is valid — the interview's own role, level
and focus skills are used:

```bash
curl -X POST http://localhost:8080/api/v1/interviews/$ID/questions/generate \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"questionCount": 5}'
```

Previously AI-generated questions are replaced by default; questions an
interviewer typed by hand always survive. Returns 503 if the AI service is
unavailable after its retries.

**Results.** There is no `overallScore` field in the request: it is derived
server-side as the mean of the three dimension scores, so the headline number can
never contradict its own breakdown. Submitting a result moves the interview to
`COMPLETED`.

### Dashboard

| Method | Path | Role |
|---|---|---|
| GET | `/dashboard/summary` | ADMIN, INTERVIEWER |

Totals, per-status breakdowns, mean score and the next few interviews.
`averageOverallScore` is absent (not zero) until at least one result exists.

### Users

| Method | Path | Role | Description |
|---|---|---|---|
| GET | `/users?role=INTERVIEWER` | ADMIN, INTERVIEWER | Enabled users by role |

Read-only by design: account provisioning is an administrative task, not a
self-service API.

## Operational endpoints

Unauthenticated — a kubelet probe and a Prometheus scrape cannot present a secret.

| Path | Purpose |
|---|---|
| `/actuator/health/liveness` | Process check; never touches the database |
| `/actuator/health/readiness` | Includes the database |
| `/actuator/health` | Aggregate, including AI service reachability |
| `/actuator/prometheus` | Metrics |
| `/actuator/info` | Build information |

## AI service (internal)

Not exposed through the Ingress. Requires `X-Internal-Api-Key`.

| Method | Path | Description |
|---|---|---|
| POST | `/api/v1/questions/generate` | Generate a question set |
| GET | `/api/v1/questions/sets/{id}` | Fetch a set |
| GET | `/api/v1/questions/interview/{id}` | Sets for an interview |
| POST | `/api/v1/evaluations` | Score submitted answers |
| GET | `/api/v1/evaluations/interview/{id}` | Latest evaluation |
| GET | `/api/v1/info` | Effective non-secret configuration |
| GET | `/health/liveness`, `/health/readiness`, `/metrics` | Operational |

Request and response bodies are camelCase on the wire, matching the middleware's
Jackson defaults, so neither side needs a naming-strategy override.
