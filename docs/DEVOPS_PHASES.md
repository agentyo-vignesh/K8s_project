# Manual deployment runbook

> **This document describes an earlier design and is no longer accurate.**
>
> It was written when the cluster was created by hand with `eksctl`, the app shipped as one umbrella
> Helm chart with dev/prod overlays, and ArgoCD synced it. None of that is true now:
>
> | Then | Now |
> |---|---|
> | `eksctl create cluster`, AWS CLI for RDS/ECR/secrets | `terraform apply` - seven numbered files |
> | `helm/ai-interview-platform` + `values-{dev,prod}.yaml` | one chart per service, no overlays |
> | `argocd/` syncs from Git | GitHub Actions runs `helm upgrade` directly |
> | Secrets Manager into a Kubernetes Secret | each pod reads Secrets Manager itself over IRSA |
>
> `argocd/` and `helm/ai-interview-platform/` have been deleted, so the paths below do not exist.
> Kept because the reasoning is still worth reading. For what the repository actually does, see
> [`../README.md`](../README.md), `terraform/`, `helm/` and `.github/workflows/`.

Everything created by hand, in dependency order:

```
STAGE 1  INFRASTRUCTURE   1.1 network (terraform)   ← the only codified piece
                          1.2 EKS cluster
                          1.3 RDS
                          1.4 ECR
                          1.5 S3 + Secrets Manager
                          1.6 IRSA roles
STAGE 2  BACKEND          middleware (creates the schema) → AI service
STAGE 3  FRONTEND         deploy → Ingress
STAGE 4  AUTOMATE         CI → CD → ArgoCD          (optional, after it works)
STAGE 5  TEARDOWN         mandatory
```

Nothing is deployed before the thing it depends on exists **and has been
verified**. Every step ends with a **Checkpoint** that must pass before moving on.

> **One ordering correction up front.** "Create the DB first" is the natural
> instinct and it is wrong here. The **VPC has to exist before anything else**, and
> `eksctl` will happily create its *own* VPC if you let it. An RDS instance created
> before the network lands somewhere the nodes cannot reach, and the failure is a
> connection timeout that looks like a security-group problem for an hour.
>
> So: **network → cluster → database**, all in the same VPC. The database is still
> part of Stage 1, just not the first item in it.

Only Stage 1.1 uses Terraform. Everything else is created by hand on purpose — the
OIDC provider, the IAM trust policy and the ServiceAccount annotation are three
separate things you have to connect, and `terraform apply` hides that behind one
command.

---

## Stage 0 — Prep

```bash
docker --version && kubectl version --client && helm version
aws --version && eksctl version && jq --version
aws sts get-caller-identity          # must print your account id
```

Set the session variables once, in every shell you use:

```bash
source ./scripts/session-vars.sh
```

Agree `AWS_REGION` as a group and write it on the board. Half the room in one
region and half in another is the most common way to lose an hour.

---
---

# STAGE 1 — Infrastructure

## 1.1 — Network (VPC)

The one piece created with Terraform. Subnet CIDRs, route tables and the EKS
discovery tags are fiddly by hand and produce failures that look like something
else entirely, so the network files in [`terraform/`](../terraform/) do it. Everything
after this is manual.

```bash
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan
cd ..
```

**Builds**

```
VPC 10.0.0.0/16
├── Pub-Subnet    10.0.1.0/24   ap-south-1a  → Internet Gateway
│     └── NAT Gateway (single)
├── Pub-Subnet-2  10.0.4.0/24   ap-south-1b  → Internet Gateway
├── Pvt-Subnet-1  10.0.2.0/24   ap-south-1a  → NAT
└── Pvt-Subnet-2  10.0.3.0/24   ap-south-1b  → NAT
```

**Two of each, spanning two AZs.** Not stylistic — three separate things enforce it:

- EKS rejects a single-AZ cluster at creation.
- `eksctl` refuses a run that names only one subnet of a type: *"insufficient
  number of subnets, at least 2x public and/or 2x private subnets are required"*.
- The AWS Load Balancer Controller needs two public subnets in two AZs before it
  will create an internet-facing ALB, and its failure (`unable to discover
  subnets`) reads like a permissions problem.

An RDS subnet group also requires two. Subnets cost nothing, so there is no
version of this worth simplifying.

**Checkpoint**

```bash
cd terraform
export VPC_ID=$(terraform output -raw vpc_id)
export PUBLIC_SUBNETS=$(terraform output -json public_subnet_ids | jq -r 'join(",")')
export PRIVATE_SUBNETS=$(terraform output -json private_subnet_ids | jq -r 'join(",")')
cd ..

echo "$VPC_ID"; echo "$PUBLIC_SUBNETS"; echo "$PRIVATE_SUBNETS"
```

All three must be non-empty, and each subnet variable must hold **two**
comma-separated ids. An unset variable becomes `--vpc-private-subnets=,` and fails
with `InvalidSubnetID.NotFound: The subnet ID '' does not exist` — which reads like
a missing subnet rather than a missing variable. These are shell variables: they do
not survive a reconnect, so re-run this block after any dropped session.

> **Single NAT = single AZ.** If ap-south-1a goes down, *both* private subnets
> lose outbound internet — no image pulls, no Secrets Manager, no ECR. Correct for
> a training cluster; wrong for production, where you want one NAT per AZ.
>
> It also has to stay up for the whole session. Deleting the NAT to save ~$1.34/day
> mid-session breaks image pulls and STS for every private pod, and presents as
> `ImagePullBackOff` with nothing pointing at the route table.

> **`/24` gives 251 usable IPs per subnet.** The VPC CNI assigns every pod a real
> VPC IP, so that is the pod ceiling per subnet, not a theoretical limit. Nowhere
> near binding at this size — `t3.small` caps out at 11 pods per node. The limit
> you will actually hit first is the account vCPU quota; see
> [EKS_CREATION.md §5.2](EKS_CREATION.md#52-do-you-have-the-vcpu-quota).

---

## 1.2 — EKS cluster

Created **into the VPC above**. Without `--vpc-private-subnets`, `eksctl` builds
its own VPC and the RDS instance in Stage 1.3 ends up unreachable from the nodes.

```bash
eksctl create cluster \
  --name "$CLUSTER" \
  --region "$AWS_REGION" \
  --version 1.36 \
  --vpc-private-subnets="$PRIVATE_SUBNETS" \
  --vpc-public-subnets="$PUBLIC_SUBNETS" \
  --nodegroup-name default \
  --node-type t3.small \
  --nodes 2 --nodes-min 2 --nodes-max 3 \
  --node-private-networking \
  --managed \
  --with-oidc
```

> **Full walkthrough, prerequisites and every failure mode:**
> [EKS_CREATION.md](EKS_CREATION.md). Read §3 and §5 before running this — the
> Kubernetes version and the instance type both have account-level constraints
> that fail *silently*, and `--nodes-max` has to fit inside your vCPU quota.

Or take it straight from Terraform:

```bash
terraform -chdir=terraform output -raw eksctl_command | bash
```

15–20 minutes. Use the wait to explain what is being built.

`--with-oidc` is **not optional**. It registers the cluster's OIDC issuer as an IAM
identity provider. Without it every IRSA annotation in 1.6 is silently inert and
pods fall back to the node role.

`--node-private-networking` keeps nodes off public IPs; they reach the internet
through the NAT gateway.

**Checkpoint**

```bash
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER"
kubectl get nodes                          # 2 nodes, Ready

source ./scripts/session-vars.sh           # OIDC now resolves
echo "$OIDC"                               # must not be empty
```

Confirm the cluster really landed in **our** VPC, not one eksctl invented:

```bash
aws eks describe-cluster --name "$CLUSTER" \
  --query cluster.resourcesVpcConfig.vpcId --output text
# must equal $VPC_ID
```

Capture the node security group — RDS needs it next:

```bash
export NODE_SG=$(aws eks describe-cluster --name "$CLUSTER" \
  --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)
echo "$NODE_SG"
```

Add metrics-server — the HPA needs it, and without it it reports `<unknown>/70%`
and never scales:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl top nodes
```

---

## 1.3 — Database (RDS PostgreSQL)

Created **inside the cluster's VPC**, in its private subnets, reachable only from
the nodes.

`$PRIVATE_SUBNETS` was captured from the Terraform output in 1.1:

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name ai-interview-db \
  --db-subnet-group-description "AI Interview Platform" \
  --subnet-ids ${PRIVATE_SUBNETS//,/ }
```

<details>
<summary>Looking them up without Terraform</summary>

```bash
export SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=DB-Subnet-*" \
  --query 'Subnets[].SubnetId' --output text)
echo "$SUBNETS"                            # must list 2 subnets
```

EC2 tag filters are **case-sensitive**, so the pattern has to match the Name tag
exactly as `1.vpc.tf` writes it (`DB-Subnet-1`, `DB-Subnet-2`). Check `$SUBNETS` is
non-empty before continuing — an empty `--subnet-ids` fails with a confusing
validation error.

</details>

A dedicated security group allowing PostgreSQL **from the node security group** —
a group reference, not a CIDR, because node IPs change as the group scales:

```bash
export RDS_SG=$(aws ec2 create-security-group \
  --group-name ai-interview-rds \
  --description "PostgreSQL from EKS nodes only" \
  --vpc-id "$VPC_ID" --query GroupId --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG" --protocol tcp --port 5432 --source-group "$NODE_SG"
```

Now the instance. The password is generated, never typed:

```bash
export DB_PASSWORD="$(openssl rand -hex 20)"

aws rds create-db-instance \
  --db-instance-identifier ai-interview-postgres \
  --db-instance-class db.t4g.micro \
  --engine postgres --engine-version 16.14 \
  --allocated-storage 20 --storage-type gp3 --storage-encrypted \
  --master-username ai_interview_app \
  --master-user-password "$DB_PASSWORD" \
  --db-name ai_interview \
  --db-subnet-group-name ai-interview-db \
  --vpc-security-group-ids "$RDS_SG" \
  --no-publicly-accessible \
  --backup-retention-period 7 \
  --region "$AWS_REGION"
```

5–10 minutes.

**Checkpoint**

```bash
aws rds wait db-instance-available --db-instance-identifier ai-interview-postgres

export RDS_HOST=$(aws rds describe-db-instances \
  --db-instance-identifier ai-interview-postgres \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "$RDS_HOST"
```

Prove the nodes can actually reach it — **now**, not after a failed deploy:

```bash
kubectl run pgtest --rm -it --restart=Never --image=postgres:16-alpine -- \
  sh -c "nc -zv $RDS_HOST 5432"
```

`open` means the security group is right. A hang means the SG rule or the VPC is
wrong, and finding that here is far cheaper than inside a CrashLoopBackOff.

> **No tables exist yet, and that is correct.** Flyway in the middleware creates
> the entire schema — including the `ai_*` tables the AI service maps — in Stage 2.

---

## 1.4 — Container registry (ECR)

```bash
for repo in middleware ai-service frontend; do
  aws ecr create-repository \
    --repository-name "ai-interview/$repo" \
    --image-scanning-configuration scanOnPush=true \
    --region "$AWS_REGION"
done
```

**Checkpoint**

```bash
aws ecr describe-repositories --query 'repositories[].repositoryName'
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
```

---

## 1.5 — Storage and secrets

The S3 bucket holds candidate CVs, so all four hardening calls are required, not
optional:

```bash
export BUCKET="ai-interview-resumes-$(openssl rand -hex 4)"
echo "$BUCKET" > .session-bucket           # survives a new shell

aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
```

Two secrets. The database one uses the exact field names RDS-managed rotation
writes, so switching to managed rotation later needs no application change:

```bash
aws secretsmanager create-secret --name "$DB_SECRET_ID" \
  --secret-string "$(jq -nc --arg h "$RDS_HOST" --arg p "$DB_PASSWORD" \
    '{engine:"postgres", host:$h, port:5432, dbname:"ai_interview",
      username:"ai_interview_app", password:$p}')"

aws secretsmanager create-secret --name "$APP_SECRET_ID" \
  --secret-string "$(jq -nc \
    --arg j "$(openssl rand -base64 48)" --arg a "$(openssl rand -hex 24)" \
    '{jwtSigningKey:$j, aiServiceApiKey:$a, openaiApiKey:""}')"
```

`jwtSigningKey` must be at least 32 bytes — the middleware refuses to start
otherwise, deliberately.

**Checkpoint**

```bash
aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ID" \
  --query SecretString --output text | jq 'keys'
# ["dbname","engine","host","password","port","username"]
```

---

## 1.6 — IRSA roles

The centrepiece: AWS access with **no access keys anywhere**.

Draw the chain before running anything:

```
ServiceAccount annotated with a role ARN
   ↓  EKS webhook projects a signed token into the pod
AWS_WEB_IDENTITY_TOKEN_FILE + AWS_ROLE_ARN
   ↓  AWS SDK default credential provider chain
sts:AssumeRoleWithWebIdentity
   ↓  trust policy checks  sub == system:serviceaccount:<ns>:<sa>
Temporary credentials, 1 hour
```

### Middleware role

```bash
cat > /tmp/mw-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC}:sub": "system:serviceaccount:${NAMESPACE}:ai-interview-middleware",
        "${OIDC}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

aws iam create-role --role-name ai-interview-middleware \
  --assume-role-policy-document file:///tmp/mw-trust.json

cat > /tmp/mw-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],
      "Resource": [
        "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT}:secret:${DB_SECRET_ID}-*",
        "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT}:secret:${APP_SECRET_ID}-*"
      ]},
    { "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/*" },
    { "Effect": "Allow",
      "Action": ["s3:ListBucket","s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::${BUCKET}" }
  ]
}
EOF

aws iam put-role-policy --role-name ai-interview-middleware \
  --policy-name ai-interview-middleware --policy-document file:///tmp/mw-policy.json
```

### AI service role

Same trust policy with a different `sub`, and **no S3 access** — the AI service
never touches resume files.

```bash
sed 's/ai-interview-middleware/ai-interview-ai-service/' /tmp/mw-trust.json > /tmp/ai-trust.json

aws iam create-role --role-name ai-interview-ai-service \
  --assume-role-policy-document file:///tmp/ai-trust.json

cat > /tmp/ai-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],
    "Resource": [
      "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT}:secret:${DB_SECRET_ID}-*",
      "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT}:secret:${APP_SECRET_ID}-*"
    ]
  }]
}
EOF

aws iam put-role-policy --role-name ai-interview-ai-service \
  --policy-name ai-interview-ai-service --policy-document file:///tmp/ai-policy.json
```

### Three things that must line up

This is where most people fail. All three must be identical:

| | Value |
|---|---|
| Trust policy `sub` | `system:serviceaccount:ai-interview:ai-interview-middleware` |
| Helm namespace | `-n ai-interview` |
| Rendered ServiceAccount name | must equal the `sub` above |

The chart names it `<release>-<chart>-middleware` by default, so **every Helm
command below uses `--set fullnameOverride=ai-interview`** to make it
`ai-interview-middleware`.

**Checkpoint** — verify the name before deploying anything:

```bash
helm template ai-interview ./helm/ai-interview-platform \
  --set fullnameOverride=ai-interview \
  -f ./helm/ai-interview-platform/values-prod.yaml \
  --set middleware.storage.s3.bucket="$BUCKET" \
  | grep -A2 'kind: ServiceAccount' | grep 'name:'
# name: ai-interview-middleware
# name: ai-interview-ai-service
```

### Stage 1 complete

```bash
kubectl get nodes
aws rds describe-db-instances --db-instance-identifier ai-interview-postgres \
  --query 'DBInstances[0].DBInstanceStatus' --output text      # available
aws ecr describe-repositories --query 'length(repositories)'    # 3
aws iam get-role --role-name ai-interview-middleware --query Role.Arn --output text
```

---
---

# STAGE 2 — Backend

Backend first, frontend later. The middleware runs Flyway and creates the schema,
so **it must be deployed before the AI service** — the AI service maps the `ai_*`
tables but never creates them.

## 2.1 — Build and push images

```bash
./scripts/build-images.sh --registry "$ECR_REGISTRY" --tag v1.0.0 --push
```

**Checkpoint**

```bash
aws ecr describe-images --repository-name ai-interview/middleware \
  --query 'imageDetails[].imageTags'
aws ecr describe-images --repository-name ai-interview/ai-service \
  --query 'imageDetails[].imageTags'
```

Look at the scan findings together — base images carry CVEs, which is why
Dependabot watches the Dockerfiles:

```bash
aws ecr describe-image-scan-findings --repository-name ai-interview/middleware \
  --image-id imageTag=v1.0.0 --query 'imageScanFindings.findingSeverityCounts'
```

## 2.2 — Deploy the middleware alone

Frontend and AI service switched off, so exactly one thing is being proved: the
middleware can resolve its secrets, reach RDS, and migrate the schema.

```bash
kubectl create namespace "$NAMESPACE"

helm upgrade --install ai-interview ./helm/ai-interview-platform \
  -n "$NAMESPACE" \
  --set fullnameOverride=ai-interview \
  -f ./helm/ai-interview-platform/values.yaml \
  -f ./helm/ai-interview-platform/values-prod.yaml \
  --set global.imageRegistry="$ECR_REGISTRY" \
  --set aws.region="$AWS_REGION" \
  --set aws.secretsManager.databaseSecretId="$DB_SECRET_ID" \
  --set aws.secretsManager.applicationSecretId="$APP_SECRET_ID" \
  --set middleware.image.tag=v1.0.0 \
  --set middleware.serviceAccount.roleArn="$MW_ROLE_ARN" \
  --set middleware.storage.s3.bucket="$BUCKET" \
  --set aiService.enabled=false \
  --set frontend.enabled=false \
  --set ingress.enabled=false \
  --wait --timeout 10m
```

**Checkpoint**

```bash
kubectl -n "$NAMESPACE" get pods            # middleware only, Running 1/1

# IRSA actually wired?
kubectl -n "$NAMESPACE" exec deploy/ai-interview-middleware -- env | grep AWS_
# AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE must BOTH be present

# Did Flyway create the schema?
kubectl -n "$NAMESPACE" logs deploy/ai-interview-middleware | grep -i flyway
# "Successfully applied 3 migrations"

# Nothing sensitive in the release manifest
helm -n "$NAMESPACE" get manifest ai-interview | grep -c "kind: Secret"     # 0
```

Test the API:

```bash
kubectl -n "$NAMESPACE" port-forward svc/ai-interview-middleware 8080:8080 &

curl -s localhost:8080/actuator/health/readiness
TOKEN=$(curl -s -X POST localhost:8080/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@aiinterview.local","password":"Admin@12345"}' | jq -r .accessToken)
curl -s -H "Authorization: Bearer $TOKEN" localhost:8080/api/v1/candidates | jq '.totalElements'
```

**Expected failure to observe.** Question generation returns **503** — the AI
service does not exist yet. But the middleware is still `Ready`:

```bash
curl -s localhost:8080/actuator/health/readiness              # UP
curl -s localhost:8080/actuator/health | jq '.components.aiService'   # DOWN
```

That is deliberate. `aiService` is excluded from the readiness group, so an AI
outage degrades question generation rather than pulling every middleware pod out
of the Service and taking login down with it.

## 2.3 — Deploy the AI service

```bash
helm upgrade ai-interview ./helm/ai-interview-platform \
  -n "$NAMESPACE" --reuse-values \
  --set aiService.enabled=true \
  --set aiService.image.tag=v1.0.0 \
  --set aiService.serviceAccount.roleArn="$AI_ROLE_ARN" \
  --set aiService.config.aiProvider=mock \
  --wait --timeout 5m
```

`aiProvider=mock` is deterministic, offline and free — right for a session. Switch
to `openai` only when demonstrating the real provider, and put the key in the
application secret first.

**Checkpoint**

```bash
kubectl -n "$NAMESPACE" get pods            # middleware + ai-service, all Running
kubectl -n "$NAMESPACE" exec deploy/ai-interview-ai-service -- env | grep AWS_ROLE_ARN
curl -s localhost:8080/actuator/health | jq '.components.aiService.status'   # UP
```

## 2.4 — Verify the backend end to end

```bash
API_URL=http://localhost:8080 ./scripts/smoke-test.sh
```

Must print **`passed: 20   failed: 0`**. This exercises the whole chain:

```
curl → Spring Boot → FastAPI → PostgreSQL (RDS)
```

> **Stage 2 is the deliverable.** If the session runs out of time here, you have a
> working, secured, cloud-deployed backend. Stage 3 is presentation.

---
---

# STAGE 3 — Frontend

## 3.1 — Deploy the frontend

The image was already pushed in 2.1. Just enable it:

```bash
helm upgrade ai-interview ./helm/ai-interview-platform \
  -n "$NAMESPACE" --reuse-values \
  --set frontend.enabled=true \
  --set frontend.image.tag=v1.0.0 \
  --wait --timeout 5m
```

**Checkpoint**

```bash
kubectl -n "$NAMESPACE" get pods            # all three components Running
kubectl -n "$NAMESPACE" port-forward svc/ai-interview-frontend 3000:80 &
curl -s localhost:3000/healthz
curl -s localhost:3000/runtime-config.js
```

That last file is generated **at container start** by the entrypoint — the API URL
is not compiled into the JavaScript bundle, which is why one frontend image is
promoted from dev to prod unchanged.

## 3.2 — Ingress (public access)

Install the AWS Load Balancer Controller:

```bash
eksctl create iamserviceaccount \
  --cluster "$CLUSTER" --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess \
  --approve --role-only --role-name AmazonEKSLoadBalancerControllerRole

helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName="$CLUSTER" \
  --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller
```

Then enable the Ingress:

```bash
helm upgrade ai-interview ./helm/ai-interview-platform \
  -n "$NAMESPACE" --reuse-values \
  --set ingress.enabled=true \
  --set ingress.host=ai-interview.example.com \
  --set ingress.tls.enabled=false
```

**Checkpoint**

```bash
kubectl -n "$NAMESPACE" get ingress -w      # ADDRESS appears after 2-3 min
kubectl -n "$NAMESPACE" describe ingress ai-interview
```

| Event | Cause |
|---|---|
| `unable to discover subnets` | Missing `kubernetes.io/role/elb` subnet tags |
| No events at all | Load Balancer Controller not installed |

Open the ALB address in a browser and sign in as
`admin@aiinterview.local` / `Admin@12345`.

The Ingress routes `/api` and `/actuator` to the middleware and everything else to
the frontend, on one host. Same-origin — so `frontend.apiBaseUrl` stays empty and
the browser makes no CORS preflight.

---
---

# STAGE 4 — Automate (optional)

Only after the manual path works. If you automate a deployment you have never
performed by hand, you cannot debug it.

| Step | Where | Note |
|---|---|---|
| CI | `.github/workflows/ci.yml` | Runs on push, no setup needed |
| CD role | [DEPLOYMENT.md](DEPLOYMENT.md) §4 | GitHub OIDC — **no access keys** |
| CD | `.github/workflows/cd.yml` | Pushes to ECR, commits the image tag |
| GitOps | `argocd/` | ArgoCD syncs; stop running `helm upgrade` by hand |
| Monitoring | kube-prometheus-stack | Then `--set metrics.serviceMonitor.enabled=true` |

The one line in the CD trust policy that matters:

```json
"StringLike": { "token.actions.githubusercontent.com:sub": "repo:YOUR-ORG/ai-interview-platform:*" }
```

Without it **any GitHub repository in the world** can assume the role.

---
---

# STAGE 5 — Teardown

These bill continuously whether or not anything is deployed. `ap-south-1`
on-demand rates:

| Resource | Rate | Per month |
|---|---|---|
| EKS control plane — **standard** support | $0.100/hr | ~$73 |
| EKS control plane — **extended** support | $0.600/hr | ~$438 |
| NAT Gateway | $0.056/hr | ~$41 + data |
| 2 × `t3.small` nodes | $0.0224/hr each | ~$33 |
| RDS `db.t4g.micro` | $0.021/hr | ~$15 |
| bastion `t3.micro` | $0.0112/hr | ~$8 |

Note the first two rows. A Kubernetes version whose standard support has ended
still creates a cluster, with no warning anywhere, at **six times** the control
plane price. Check before creating, not after:

```bash
aws eks describe-cluster-versions --region "$AWS_REGION" \
  --query 'clusterVersions[].{Version:clusterVersion,EndStandard:endOfStandardSupportDate}' \
  --output table
```

The control plane and NAT alone are ~$114/month — more than the nodes. Downsizing
nodes is not where the money is; deleting the cluster when you are done is.

Schedule this as a real agenda item. **Order matters** — each step below releases
something the next one cannot delete while it is still attached.

**Step 1 — Ingress first.** An ALB left behind keeps charging and blocks the VPC
from being destroyed, because its ENIs sit in your subnets:

```bash
kubectl -n "$NAMESPACE" delete ingress --all
kubectl -n "$NAMESPACE" get ingress          # empty before continuing
helm uninstall ai-interview -n "$NAMESPACE"
```

**Step 2 — the cluster.** Also removes the node group and the OIDC provider:

```bash
eksctl delete cluster --name "$CLUSTER" --region "$AWS_REGION" --wait
```

**Step 3 — data stores.** RDS must go before the VPC; its ENIs are in the private
subnets:

```bash
aws rds delete-db-instance --db-instance-identifier ai-interview-postgres --skip-final-snapshot
aws rds wait db-instance-deleted --db-instance-identifier ai-interview-postgres
aws rds delete-db-subnet-group --db-subnet-group-name ai-interview-db

aws s3 rb "s3://$BUCKET" --force
for repo in middleware ai-service frontend; do
  aws ecr delete-repository --repository-name "ai-interview/$repo" --force
done
aws secretsmanager delete-secret --secret-id "$DB_SECRET_ID" --force-delete-without-recovery
aws secretsmanager delete-secret --secret-id "$APP_SECRET_ID" --force-delete-without-recovery
```

**Step 4 — IAM roles:**

```bash
aws iam delete-role-policy --role-name ai-interview-middleware --policy-name ai-interview-middleware
aws iam delete-role --role-name ai-interview-middleware
aws iam delete-role-policy --role-name ai-interview-ai-service --policy-name ai-interview-ai-service
aws iam delete-role --role-name ai-interview-ai-service
```

**Step 5 — the network, last.** This is the one people forget, and the NAT Gateway
keeps billing:

```bash
# The RDS security group was created by hand, so Terraform does not know about it
# and its presence blocks the VPC delete.
aws ec2 delete-security-group --group-id "$RDS_SG" 2>/dev/null || true

cd terraform
terraform destroy
cd ..
```

If `terraform destroy` fails with `DependencyViolation`, something is still
attached to the subnets. Find it:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Desc:Description,Status:Status}' \
  --output table
```

Usually a leftover ALB or an RDS instance that has not finished deleting.

**Checkpoint — all four must be empty**

```bash
eksctl get cluster --region "$AWS_REGION"
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-nat-gateways --filter "Name=state,Values=available" \
  --query 'NatGateways[].NatGatewayId'
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=ai-interview-vpc" \
  --query 'Vpcs[].VpcId'
```

---
---

# Troubleshooting

| Symptom | Most likely cause | Check |
|---|---|---|
| `CrashLoopBackOff`, `AccessDenied` | IRSA `sub` mismatch | `kubectl exec ... env \| grep AWS_` |
| Pod never Ready, DB timeout | RDS security group | `kubectl run pgtest ... nc -zv $RDS_HOST 5432` |
| `Migration checksum mismatch` | An applied migration was edited | Never edit one; add `V4__` |
| Question generation 503 | AI service down — **by design** | `curl .../actuator/health \| jq .components.aiService` |
| AI service 401 | Internal API key mismatch | Both read `aiServiceApiKey` from one secret; restart both |
| Ingress has no address | LB Controller or subnet tags | `kubectl describe ingress` |
| HPA `<unknown>/70%` | metrics-server missing | `kubectl top nodes` |

Correlating a failure across both services — every response carries
`X-Request-Id`, and both log it as a top-level JSON field:

```bash
kubectl -n "$NAMESPACE" logs -l app.kubernetes.io/part-of=ai-interview-platform --tail=-1 \
  | jq -c 'select(.requestId == "<id from the failing response>")'
```

Full reference: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Deliberate failure exercises

Run after Stage 3, once everything works. Each reproduces a real incident.

**1. Break IRSA**

```bash
kubectl -n "$NAMESPACE" annotate sa ai-interview-middleware eks.amazonaws.com/role-arn- --overwrite
kubectl -n "$NAMESPACE" rollout restart deploy/ai-interview-middleware
```

The pod fails its **startup probe** — it never becomes ready, rather than serving
traffic and 500ing. Re-annotate and restart.

**2. AI outage stays contained**

```bash
kubectl -n "$NAMESPACE" scale deploy/ai-interview-ai-service --replicas=0
```

Login and candidate CRUD keep working; only generation 503s. Middleware pods stay
Ready.

**3. Liveness misconfiguration → restart storm**

Point liveness at `/actuator/health/readiness`, then make the database
unreachable. Every pod enters CrashLoopBackOff and a recoverable blip becomes an
outage. Revert and compare.

**4. Pool exhaustion**

```bash
helm upgrade ai-interview ./helm/ai-interview-platform -n "$NAMESPACE" \
  --reuse-values --set middleware.config.dbPoolMaxSize=1
```

Drive load; requests queue and time out while CPU stays low. Not every bottleneck
is CPU.

---

## If time runs short

| Priority | Stage | Why |
|---|---|---|
| 1 | Stage 1 + 2 | A secured, cloud-deployed backend is the real deliverable |
| 2 | Failure exercise 1 (IRSA) | Hardest thing to learn from documentation alone |
| 3 | Failure exercise 3 (probes) | Most transferable idea in the session |
| 4 | Stage 3 | Presentation, not architecture |
| 5 | Stage 4 | A second session |

**Stage 5 is never optional.**

---

## Local dry run first

Before touching AWS, run the whole application locally so everyone knows what
"working" looks like:

```bash
./scripts/dev-up.sh          # creates per-service env files, waits for readiness
./scripts/smoke-test.sh      # passed: 20  failed: 0
```

Then http://localhost:3000, sign in, create a candidate, generate questions. That
one click is the same chain Stage 2 deploys to EKS.
