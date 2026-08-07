# Kubernetes RBAC vs IRSA

Two systems that both use the word **Role**, control completely different things, and share exactly one
object. Confusing them is the most common reason an IRSA setup "looks correct" and still fails.

## The one-sentence answer

| | Question it answers |
|---|---|
| **Kubernetes RBAC** | Can this subject call the **Kubernetes API**, and do what to which K8s objects? |
| **IRSA** | Can this pod call the **AWS API**, and do what to which AWS resources? |

RBAC is enforced by the Kubernetes API server. IRSA is enforced by AWS STS and IAM. Neither knows the
other exists.

---

## The only thing they share: ServiceAccount

```
                    ServiceAccount: ai-interview-middleware
                    ┌──────────────┴──────────────┐
                    │                             │
        ┌───────────▼──────────┐      ┌───────────▼───────────┐
        │  RBAC side           │      │  IRSA side            │
        │                      │      │                       │
        │  RoleBinding         │      │  annotation:          │
        │    → Role            │      │    eks.amazonaws.com/ │
        │      → rules         │      │    role-arn: ...      │
        │                      │      │      → IAM Role       │
        │                      │      │        → trust policy │
        │  "what can it do     │      │                       │
        │   to K8s objects?"   │      │  "what can it do      │
        │                      │      │   in AWS?"            │
        └──────────────────────┘      └───────────────────────┘
```

The two sides are **independent**. Delete the annotation and AWS access stops while cluster access
continues. Delete the RoleBinding and the reverse happens.

A useful analogy: the ServiceAccount is an employee ID card. RBAC decides which **rooms in the office** it
opens. IRSA decides which **bank locker** it opens. Same card, two institutions, two permission lists —
and the bank has no idea what the office allows.

---

## Kubernetes RBAC

### Objects

| Object | Purpose |
|---|---|
| `Role` / `ClusterRole` | The rules — verbs × resources |
| `RoleBinding` / `ClusterRoleBinding` | Connects a subject to a Role |
| `ServiceAccount` | The subject, when the caller is a pod |

### What a rule looks like

```yaml
kind: Role
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
```

Subjects are **User, Group, or ServiceAccount** — never a Pod, Deployment or Service.

### What RBAC does NOT control

This is where most misunderstanding lives. RBAC governs **calls to the Kubernetes API server only**:

```
kubectl ──────────────►  ┌──────────────────────┐
                         │  Kubernetes API      │  ← RBAC checked HERE, only here
pod using a K8s SDK ───► └──────────────────────┘

middleware pod ──HTTP──► ai-service pod            ← RBAC NOT involved
middleware pod ──TCP───► RDS :5432                 ← RBAC NOT involved
middleware pod ──SDK───► AWS Secrets Manager       ← RBAC NOT involved
```

In this project the middleware calls the AI service over plain HTTP on `:8000`. **No Role, no RoleBinding,
and it works.** Restricting that traffic requires a `NetworkPolicy`, not RBAC.

---

## IRSA (IAM Roles for Service Accounts)

### Objects

| Object | Lives in | Purpose |
|---|---|---|
| IAM OIDC provider | AWS IAM | Registers the cluster as a trusted token issuer |
| IAM Role + trust policy | AWS IAM | The permissions, and *who* may assume them |
| ServiceAccount annotation | Kubernetes | Tells the pod which role ARN to assume |

### There is no RoleBinding

A `RoleBinding` does two things at once: names the subject, and names the Role. IRSA splits that across
two places that must agree:

| What a RoleBinding does | IRSA equivalent |
|---|---|
| "this subject" | the trust policy's `sub` condition |
| "gets this Role" | the ServiceAccount's `role-arn` annotation |

```
IAM Role: ai-interview-middleware
  │
  ├─ trust policy: sub == "system:serviceaccount:ai-interview:ai-interview-middleware"
  │                                        ↕  these two strings must match exactly
ServiceAccount annotation: role-arn ───────┘
```

The reference is **bidirectional**. Setting one side only fails — see the failure table below.

`kubectl get rolebinding` will never show anything IRSA-related. That is expected, not a missing object.

### The `sub` condition is the actual security control

```json
"Condition": {
  "StringEquals": {
    "oidc.eks.ap-south-1.amazonaws.com/id/<OIDC_ID>:sub":
      "system:serviceaccount:ai-interview:ai-interview-middleware",
    "oidc.eks.ap-south-1.amazonaws.com/id/<OIDC_ID>:aud": "sts.amazonaws.com"
  }
}
```

Remove `sub` and **every pod in the cluster** can assume the role. A trust policy without it is effectively
cluster-wide AWS credentials. `aud` prevents the token being replayed against a different service.

`<OIDC_ID>` is unique per cluster and **changes every time the cluster is recreated** — a rebuilt
`ai-interview` gets a new issuer, so every hand-written trust policy goes stale at once. Terraform
regenerates them from `aws_iam_openid_connect_provider.oidc`; anything created by hand must be updated.
Get the current value with:

```bash
aws eks describe-cluster --name ai-interview --query cluster.identity.oidc.issuer --output text
```

### How a pod gets credentials

1. Pod starts with an annotated ServiceAccount
2. The EKS Pod Identity Webhook injects `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` (a projected JWT
   signed by the cluster)
3. The AWS SDK's default credential provider chain detects those and calls `sts:AssumeRoleWithWebIdentity`
4. STS reads the token's `iss`, finds the matching IAM OIDC provider, fetches the cluster's public key from
   its JWKS endpoint, and verifies the signature — **this is the OIDC provider's only job**
5. STS evaluates the trust policy: does `sub` match? does `aud` match?
6. STS returns temporary credentials, valid one hour

Steps 4–5 are the split worth teaching: **step 4 is authentication** (who are you), **step 5 is
authorization** (what may you do). The OIDC provider does not grant any permission.

---

## Side by side

| | Kubernetes RBAC | IRSA |
|---|---|---|
| "Role" means | `kind: Role` — a K8s object | an **AWS IAM Role** |
| Controls access to | the Kubernetes API | the AWS API |
| Enforced by | kube-apiserver | AWS STS + IAM |
| Binding object | `RoleBinding` | **none** — annotation + `sub` condition |
| Subject | User, Group, ServiceAccount | ServiceAccount only |
| Stored in | etcd | AWS IAM |
| Inspect with | `kubectl get role,rolebinding` | `aws iam get-role` |
| Credential lifetime | n/a — every call is re-authorized | 1 hour, then refreshed |
| Failure looks like | `403 Forbidden: User "..." cannot get resource` | `AccessDenied` or `Unable to locate credentials` |

---

## Four mechanisms, four jobs

RBAC and IRSA are two of four. They do not substitute for each other:

| Access path | Controlled by |
|---|---|
| Pod → AWS API (S3, Secrets Manager, EBS) | **IRSA** |
| Pod or user → Kubernetes API | **RBAC** |
| Pod → Pod (network traffic) | **NetworkPolicy** |
| Pod → RDS on :5432 | **Security group** |

In this project all four are live:

| # | Path | Mechanism | State |
|---|---|---|---|
| 1 | EBS CSI pod → AWS EBS API | IRSA — `ai-interview-ebs-csi` + SA annotation | ✅ working |
| 2 | EBS CSI pod → K8s API (PVC/PV) | RBAC — ClusterRole + ClusterRoleBinding | ✅ working |
| 3 | middleware pod → ai-service pod | NetworkPolicy | ⚠️ none — all pods can talk |
| 4 | middleware pod → RDS | Security group in `terraform/3.rds.tf` | ✅ cluster SG only |

Rows 1 and 2 are the same pod and the same ServiceAccount governed by two unrelated systems. That pair is
the clearest demonstration available in this repository.

---

## Failure modes

Because the reference is bidirectional, a half-configured IRSA setup fails in two distinct ways. The error
messages do not name the missing piece, which is why this table is worth keeping:

| Symptom | Cause |
|---|---|
| `Unable to locate credentials` | ServiceAccount has no `role-arn` annotation, so the webhook injected nothing |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Annotation present, but the trust policy `sub` does not match the namespace/SA |
| `InvalidIdentityToken: No OpenIDConnect provider found` | The cluster's OIDC issuer was never registered in IAM |
| `AccessDenied` on `GetSecretValue` | Role assumed successfully, but the permission policy is wrong — commonly a missing `-*` suffix on a Secrets Manager ARN, since AWS appends six random characters to every secret name |
| `403 Forbidden: cannot get resource "secrets"` | This is **RBAC**, not IRSA. Different system entirely |

The last row matters: a `403` from the Kubernetes API and an `AccessDenied` from AWS are unrelated problems
with unrelated fixes.

Three strings must be identical for IRSA to work, and nothing validates them for you:

| Where | Value |
|---|---|
| Trust policy `sub` | `system:serviceaccount:ai-interview:ai-interview-middleware` |
| Actual namespace + SA name | namespace `ai-interview`, SA `ai-interview-middleware` |
| Helm `serviceAccount.name` | `ai-interview-middleware` |

---

## Verifying both, on this cluster

### RBAC side

```bash
kubectl get clusterrolebinding | grep ebs-csi
kubectl auth can-i create persistentvolumes \
  --as=system:serviceaccount:kube-system:ebs-csi-controller-sa
```

`kubectl auth can-i --as=...` is the fastest RBAC check there is — it asks the API server directly.

### IRSA side

```bash
# 1. the cluster's OIDC issuer — the start of the chain
aws eks describe-cluster --name ai-interview --query cluster.identity.oidc.issuer --output text

# 2. it is registered in IAM
aws iam list-open-id-connect-providers

# 3. the ServiceAccount carries the role ARN
kubectl get sa ebs-csi-controller-sa -n kube-system -o jsonpath='{.metadata.annotations}'

# 4. what the webhook injected into the pod
kubectl describe pod -n kube-system -l app=ebs-csi-controller \
  | grep -E 'AWS_ROLE_ARN|AWS_WEB_IDENTITY_TOKEN_FILE'

# 5. the trust policy, with its sub condition
aws iam get-role --role-name ai-interview-ebs-csi --query Role.AssumeRolePolicyDocument
```

Step 4 prints the role ARN and the projected-token path — proof the webhook fired.

> **Do not use `kubectl exec ... -- env` on the EBS CSI pods.** The `ebs-plugin` container is a distroless
> image with no `env` binary, so the command fails with
> `exec: "env": executable file not found in $PATH`. If you pipe that to `grep AWS_ACCESS_KEY` you get an
> empty result and conclude "no access key" — a false positive from a command that never ran. Use
> `kubectl describe` as above, or the purpose-built test pod below.

### The two-gate demo — run this one in front of people

This sequence is the most instructive thing in this document, because it separates the two gates that
people assume are one. Use an image that *has* a shell, under a ServiceAccount you control.

**Setup.** Annotate a brand-new ServiceAccount in `default` with the EBS CSI role — deliberately the *wrong*
ServiceAccount for that role:

```bash
kubectl create serviceaccount irsa-demo
kubectl annotate serviceaccount irsa-demo \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT_ID>:role/ai-interview-ebs-csi
```

**Gate 1 — the webhook. It fires, and it does not check anything.**

```bash
kubectl run irsa-ok --rm --attach --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"irsa-demo"}}' \
  --image=amazon/aws-cli:latest --command -- env
```

Actual output:

```
AWS_ROLE_ARN=arn:aws:iam::<ACCOUNT_ID>:role/ai-interview-ebs-csi
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

`AWS_ACCESS_KEY_ID` is absent. Note what just happened: the webhook injected the role ARN for a
ServiceAccount that has **no right to that role**. The webhook performs no authorization whatsoever — it
copies an annotation into the pod. Anyone can annotate a ServiceAccount with any role ARN.

**Gate 2 — STS. This is where authorization happens.**

```bash
kubectl run irsa-ok2 --rm --attach --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"irsa-demo"}}' \
  --image=amazon/aws-cli:latest -- sts get-caller-identity
```

Actual output:

```
aws: [ERROR]: An error occurred (AccessDenied) when calling the AssumeRoleWithWebIdentity operation:
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

**Rejected** — because the token's `sub` is `system:serviceaccount:default:irsa-demo`, and the role's trust
policy demands `system:serviceaccount:kube-system:ebs-csi-controller-sa`.

That is the lesson: **annotating a ServiceAccount grants nothing.** The trust policy is the only thing
standing between a pod and a role, and it lives in AWS where cluster users cannot edit it. Compare with
RBAC, where creating a RoleBinding *does* grant access immediately — a meaningful difference in blast radius
if someone has `create` on ServiceAccounts.

**Third case — no annotation at all.** A different error, worth showing so people learn to tell them apart:

```bash
kubectl run irsa-fail --rm --attach --restart=Never \
  --image=amazon/aws-cli:latest -- sts get-caller-identity
# Unable to locate credentials
```

`Unable to locate credentials` means the webhook injected nothing. `AccessDenied ... AssumeRoleWithWebIdentity`
means it injected fine and the trust policy said no. Two different fixes.

Clean up: `kubectl delete sa irsa-demo`.

> One nuance worth knowing before someone in the room spots it: the EBS CSI addon's own pod spec *does*
> declare `AWS_ACCESS_KEY_ID`, as an `optional: true` reference to a Secret named `aws-secret` that does not
> exist. An optional reference to a missing Secret means the variable is never set at runtime. It is a
> legacy escape hatch for non-IRSA installs, not a credential.

### Decoding the token

```bash
kubectl run irsa-token --rm --attach --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"irsa-demo"}}' \
  --image=amazon/aws-cli:latest --command -- \
  cat /var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

Decode the payload and the `sub` claim reads `system:serviceaccount:default:irsa-demo` — exactly the string
the trust policy compared against and rejected. The whole chain, visible end to end.

> The token is a live credential valid for one hour. Show it, do not publish it.

---

## Common misconceptions

| Claim | Reality |
|---|---|
| "IRSA needs a RoleBinding" | No. The annotation plus the trust policy `sub` do that job |
| "RBAC controls pod-to-pod traffic" | No. That is NetworkPolicy. RBAC only guards the Kubernetes API |
| "The OIDC provider grants permissions" | No. It only verifies the token's signature. The trust policy grants |
| "One role per cluster is fine" | Only if you omit `sub`, which makes it cluster-wide AWS credentials |
| "IRSA means the pod stores AWS credentials" | It receives temporary ones, refreshed automatically, valid one hour |
| "A `403` and an `AccessDenied` are the same problem" | Different systems. `403` is Kubernetes, `AccessDenied` is AWS |

---

## Related

- [`../terraform/2.eks.tf`](../terraform/2.eks.tf) — the OIDC provider and the EBS CSI IRSA role, working
- [`../terraform/parked/iam.tf`](../terraform/parked/iam.tf) — the application IRSA roles, documenting the
  exact trust-policy shape to reproduce
- [`DEVOPS_PHASES.md`](DEVOPS_PHASES.md) Stage 1.6 — creating those roles by hand
