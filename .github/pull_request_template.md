## What changed

<!-- One or two sentences. What does this do that the codebase did not do before? -->

## Why

<!-- The problem being solved. Link the issue or ticket. -->

Closes #

## How to verify

<!-- The exact commands a reviewer runs, or the steps to reproduce the behaviour. -->

```bash
```

## Checklist

- [ ] Tests cover the new behaviour, including at least one failure path
- [ ] `mvn -B verify` / `pytest` / `npm run test` pass locally for the components touched
- [ ] No credential, token or connection string is committed (CI runs GitLeaks, but check first)
- [ ] Configuration is read from an environment variable, not hardcoded
- [ ] New endpoints are documented with OpenAPI annotations and enforce a role

### Database

- [ ] No migration in this PR
- [ ] New migration added as a **new** `V<n>__` file (never edit an applied migration — Flyway
      validates checksums and an edit breaks every existing environment)
- [ ] Change is additive, or split across releases so a rollback does not lose data
- [ ] SQLAlchemy models in `backend/app/db/models.py` updated if `V2` tables changed

### Deployment

- [ ] No Helm change in this PR
- [ ] New configuration is exposed as a Helm value in the chart for that service
      (`helm/frontend`, `helm/middleware`, `helm/ai-service`) and, if it is not secret, in the
      chart's `configmap.yaml`
- [ ] `helm lint` and `helm template` pass with the values CI uses - the chart defaults leave
      `imageTag` and `aws.roleArn` empty on purpose
- [ ] Change is backward-compatible with the currently deployed version, or the incompatibility
      and its rollout order are described below

## Risk and rollback

<!--
What breaks if this is wrong, and how is it undone? "Revert the commit" is only true when
there is no migration and no config change. Say so explicitly if it is not.
-->
