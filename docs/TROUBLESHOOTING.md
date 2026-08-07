# Troubleshooting guide

Failure modes this platform actually has, and how to diagnose them. Several are
deliberately reachable, because reproducing a failure on purpose is the only way
to learn to recognise it.

## First moves

```bash
NS=ai-interview-prod

kubectl -n $NS get pods -o wide
kubectl -n $NS describe pod <pod>          # Events at the bottom are usually the answer
kubectl -n $NS logs <pod> --tail=100
kubectl -n $NS logs <pod> --previous       # the crashed container, not the new one
kubectl -n $NS get events --sort-by=.lastTimestamp | tail -30
```

Every response carries `X-Request-Id`, and both services emit it as a top-level
JSON log field. Given a user's request id:

```bash
kubectl -n $NS logs -l app.kubernetes.io/part-of=ai-interview-platform --tail=-1 \
  | jq -c 'select(.requestId == "9f1c2d3e-...")'
```

That is the fastest path from "a user saw an error" to the stack trace, across
both services.

---

## The cluster has no nodes

`kubectl get nodes` returns `No resources found` and the nodegroup sits in
`CREATING`. **Nothing in Kubernetes or EKS will tell you why.** A managed nodegroup
delegates capacity to an Auto Scaling group, and the ASG keeps its failures in its
own activity log:

```
kubectl get nodes                            →  No resources found
aws eks describe-nodegroup ... .health        →  issues: []          ← "no opinion", not "fine"
aws cloudformation describe-stack-events      →  CREATE_IN_PROGRESS  ← says nothing
aws autoscaling describe-scaling-activities   →  the actual error    ← only here
```

Go straight to the bottom rung. Note the ASG name is `eks-<nodegroup>-<uuid>` and
does **not** contain the cluster name, so filtering on the cluster name finds
nothing:

```bash
ASG=$(aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(Tags[?Key=='eks:cluster-name'].Value,'$CLUSTER')].AutoScalingGroupName | [0]" \
  --output text)

aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" \
  --max-items 5 --query 'Activities[].{Status:StatusCode,Why:StatusMessage}' --output table
```

`Desired: 2, Have: 0` plus a `Failed` activity is the whole diagnosis.

| `StatusMessage` contains | Cause |
|---|---|
| `not eligible for Free Tier` | Account restricted to free-tier instance types |
| `VcpuLimitExceeded` | EC2 vCPU quota (`L-1216C47A`); count the bastion too |
| `InsufficientInstanceCapacity` | That AZ is out of that type |
| `does not have enough free addresses` | Subnet CIDR exhausted |

`StatusMessage` is the only place the real reason appears. `health.issues: []` on
the node group stays empty while the failure is still in the ASG.

**Nodes `Ready` but every pod is `ImagePullBackOff`** is the neighbouring failure.
Private nodes reach ECR through the NAT gateway; if the NAT was deleted or
recreated after the route table was written, the route points at a gateway id that
no longer exists. Check that the private route table's `0.0.0.0/0` target matches
the current NAT:

```bash
aws ec2 describe-nat-gateways --region ap-south-1 \
  --query 'NatGateways[?State==`available`].NatGatewayId'
aws ec2 describe-route-tables --region ap-south-1 \
  --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId'
```

---

## Pod never becomes ready

### CrashLoopBackOff on the middleware

```bash
kubectl -n $NS logs deploy/ai-interview-middleware --previous | head -50
```

| Log message | Cause | Fix |
|---|---|---|
| `JWT_SIGNING_KEY must be at least 32 bytes` | Short signing key | Generate a real one: `./scripts/generate-secrets.sh` |
| `Failed to read secret ... from Secrets Manager` | IRSA misconfigured | See below |
| `Validate failed: Migration checksum mismatch` | An applied migration was edited | Fix forward with a new `V<n>` |
| `Connection refused` to the database | Security group or wrong host | Check the RDS SG allows the node SG |
| `app.storage.s3.bucket is required` | `storage.type=s3` with no bucket | Set `middleware.storage.s3.bucket` |

These are **deliberate startup failures**. A misconfigured pod that never becomes
ready is far better than one that accepts traffic and then 500s on every request.

### IRSA not working

The single most common EKS failure. Symptom: `AccessDenied` or
`Unable to load credentials from any of the providers`.

```bash
# 1. Is the annotation present?
kubectl -n $NS get sa ai-interview-middleware -o jsonpath='{.metadata.annotations}'
# expect eks.amazonaws.com/role-arn

# 2. Did the webhook inject the environment?
kubectl -n $NS exec deploy/ai-interview-middleware -- env | grep AWS_
# expect AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE

# 3. Does the trust policy match this exact ServiceAccount?
aws iam get-role --role-name ai-interview-prod-middleware \
  --query 'Role.AssumeRolePolicyDocument' | jq
```

Almost always one of:

- **Namespace mismatch.** The trust policy pins
  `system:serviceaccount:<namespace>:<name>`. Deploying to a different namespace
  than `kubernetes_namespace` in `terraform.tfvars` breaks it. Update the variable
  and re-apply.
- **ServiceAccount name mismatch.** The chart names it `<release>-<chart>-middleware`;
  the trust policy must use the same name.
- **Pod predates the annotation.** The webhook only injects at creation.
  `kubectl rollout restart`.
- **No OIDC provider.** `aws eks describe-cluster --name <cluster> --query cluster.identity.oidc`.

### Readiness fails but liveness passes

Working as designed: the pod is alive but cannot serve traffic, so it is removed
from the Service without being restarted.

```bash
kubectl -n $NS exec deploy/ai-interview-middleware -- \
  curl -s localhost:8080/actuator/health/readiness | jq
```

Usually the database. Confirm from inside the pod:

```bash
kubectl -n $NS exec -it deploy/ai-interview-middleware -- \
  sh -c 'nc -zv $DB_HOST 5432'
```

---

## AI question generation fails

### 503 `AI_SERVICE_UNAVAILABLE`

```bash
kubectl -n $NS exec deploy/ai-interview-middleware -- \
  curl -s localhost:8080/actuator/health | jq '.components.aiService'
```

Note that **the middleware stays ready** when the AI service is down. That is
deliberate: `aiService` is excluded from the readiness group, so an AI outage
degrades question generation instead of pulling every middleware pod from the
Service and taking login and candidate CRUD down with it.

Checks, in order:

```bash
kubectl -n $NS get pods -l app.kubernetes.io/component=ai-service
kubectl -n $NS logs -l app.kubernetes.io/component=ai-service --tail=50

# Reachable from the middleware?
kubectl -n $NS exec deploy/ai-interview-middleware -- \
  curl -sv http://ai-interview-ai-service:8000/health/liveness
```

### 401 from the AI service

The internal API key differs between the two. Both read `aiServiceApiKey` from the
same secret, so this means one of them has a stale copy:

```bash
kubectl -n $NS rollout restart deploy -l app.kubernetes.io/part-of=ai-interview-platform
```

### OpenAI provider failing

```bash
kubectl -n $NS exec deploy/ai-interview-ai-service -- \
  curl -s -H "X-Internal-Api-Key: $KEY" localhost:8000/api/v1/info | jq
```

Check `aiProvider` and `model`. A missing or invalid `openaiApiKey` in the
application secret surfaces as a 502 `AI_PROVIDER_ERROR`. Switch to
`aiProvider: mock` to confirm the rest of the path works.

---

## Database

### Flyway checksum mismatch

```
Validate failed: Migration checksum mismatch for migration version 3
```

An applied migration was edited. Never edit an applied migration.

- Development: `./scripts/dev-down.sh --volumes`
- Deployed: restore the original file and add a new `V4__` with the intended
  change. `flyway repair` only rewrites the checksum — it does not apply the edit,
  so environments silently diverge.

### Connection pool exhausted

```
HikariPool-1 - Connection is not available, request timed out after 10000ms
```

```bash
kubectl -n $NS exec deploy/ai-interview-middleware -- \
  curl -s localhost:8080/actuator/metrics/hikaricp.connections.active | jq
```

Causes, most likely first: a slow query holding connections (check
`pg_stat_activity`); `dbPoolMaxSize` too small for the replica count; or a leak,
which the pool's leak-detection threshold logs with the borrowing stack trace.

Note that `maxPoolSize × replicaCount` must stay below the RDS `max_connections`,
or scaling up the Deployment starves the database.

```sql
SELECT pid, state, wait_event_type, now() - query_start AS duration, left(query, 120)
FROM pg_stat_activity
WHERE state <> 'idle' AND datname = 'ai_interview'
ORDER BY duration DESC LIMIT 20;
```

### AI service cannot find its tables

It started before the middleware ran migrations. Flyway owns the `ai_*` tables.

```bash
kubectl -n $NS rollout restart deploy/ai-interview-ai-service
```

---

## Networking

### Ingress has no address

```bash
kubectl -n $NS describe ingress ai-interview
```

| Event | Cause |
|---|---|
| `unable to discover subnets` | Missing `kubernetes.io/role/elb` subnet tags |
| `no certificate found` | Wrong or missing `certificateArn` |
| Nothing at all | AWS Load Balancer Controller not installed |

An ALB takes 2–3 minutes to become active after the Ingress is admitted.

### 404 on a frontend route refresh

`/candidates/123` works via in-app navigation but 404s on reload. The SPA needs a
history fallback; `frontend/nginx.conf` handles it with `try_files ... /index.html`.
If a custom Ingress bypasses that, restore the fallback.

### CORS errors in the browser

Should not happen in a correct deployment: the Ingress serves the UI and `/api`
from one host, so requests are same-origin and `frontend.apiBaseUrl` is empty. A
CORS error means `apiBaseUrl` was set to a different origin. Either clear it, or
add that origin to `middleware.config.corsAllowedOrigins`.

---

## Performance

### High p99 latency with a normal p50

The tail is the signal. Separate "one bad replica" from "all replicas":

```promql
histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket[5m])) by (le, pod))
```

If one pod is slow: GC pressure or a saturated connection pool on that instance.
If all are: a downstream dependency, usually the database or the AI provider.

```promql
histogram_quantile(0.99, sum(rate(ai_question_generation_seconds_bucket[5m])) by (le))
```

### HPA shows `<unknown>/70%`

metrics-server is not installed, or the container has no CPU **request** (a
utilisation target is a percentage *of the request*, so without one there is
nothing to compute).

```bash
kubectl top pods -n $NS      # fails if metrics-server is missing
```

### OOMKilled

```bash
kubectl -n $NS describe pod <pod> | grep -A5 'Last State'
```

The middleware sets `-XX:MaxRAMPercentage=75.0`, so the heap is a fraction of the
container limit — raising `resources.limits.memory` raises the heap with it. Also
`-XX:+ExitOnOutOfMemoryError`, so a heap exhaustion kills the process cleanly
rather than leaving a pod alive and thrashing.

---

## Deliberate failure exercises

Useful for training. Each reproduces a real-world incident.

**1. AI outage → graceful degradation, not cascade**

```bash
kubectl -n $NS scale deploy/ai-interview-ai-service --replicas=0
```

Login and candidate CRUD keep working; only generation returns 503. Middleware
pods stay Ready. This is the readiness-group decision paying off.

**2. Liveness misconfiguration → restart storm**

Point liveness at `/actuator/health/readiness` instead of `/liveness`, then stop
the database. Every pod restarts repeatedly and the outage gets worse instead of
recovering. Revert and observe the difference.

**3. Broken IRSA**

```bash
kubectl -n $NS annotate sa ai-interview-middleware eks.amazonaws.com/role-arn- --overwrite
kubectl -n $NS rollout restart deploy/ai-interview-middleware
```

Pods fail their startup probe with a credential error — not a runtime 500.

**4. Pool exhaustion**

Set `middleware.config.dbPoolMaxSize=1` and drive concurrent load. Watch requests
queue and time out while CPU stays low.

**5. Rollback**

```bash
helm rollback ai-interview -n $NS
```

---

## Escalation

Collect before asking for help:

```bash
kubectl -n $NS get all,ingress,hpa,pdb -o wide          > diag-resources.txt
kubectl -n $NS describe pods                            > diag-pods.txt
kubectl -n $NS logs -l app.kubernetes.io/part-of=ai-interview-platform \
  --tail=500 --all-containers                           > diag-logs.txt
kubectl -n $NS get events --sort-by=.lastTimestamp      > diag-events.txt
helm -n $NS get values ai-interview                     > diag-values.txt
```

Plus the `requestId` from the failing request — it is the fastest route to the
relevant log lines in both services.
