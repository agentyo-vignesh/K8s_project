# Deployment guide

Docker Compose → Amazon EKS, with the cluster and its AWS components created
**manually**.

> **Terraform is parked for this session.** Every `.tf` file is commented out; see
> [`../terraform/README.md`](../terraform/README.md). Creating the infrastructure by
> hand is deliberate here — you see the OIDC provider, the IAM trust policy and the
> ServiceAccount annotation as three separate things you have to connect, which
> `terraform apply` hides behind one command. Once that clicks, codifying it is the
> natural follow-up.

The application code is identical in every environment. Everything that differs is
a Helm value or a secret.

## Deployment models

| Target | Database | Secrets | Storage |
|---|---|---|---|
| Docker Compose | Container | Per-service `.env` files | Local volume |
| EKS + `values-dev.yaml` | In-cluster StatefulSet | Kubernetes Secret | PVC |
| EKS + `values-prod.yaml` | RDS | **Secrets Manager via IRSA** | S3 |

---

## 1. Create the cluster

`eksctl` is the shortest manual path and prints exactly what it creates.

```bash
export AWS_REGION=ap-south-1
export CLUSTER=ai-interview
export NAMESPACE=ai-interview

eksctl create cluster \
  --name "$CLUSTER" \
  --region "$AWS_REGION" \
  --version 1.36 \
  --nodegroup-name default \
  --node-type t3.small \
  --nodes 2 --nodes-min 2 --nodes-max 3 \
  --managed \
  --with-oidc \
  --alb-ingress-access
```

`--with-oidc` is not optional. It registers the cluster's OIDC issuer as an IAM
identity provider, and **without it every IRSA annotation is silently inert** —
pods fall back to the node role and fail with `AccessDenied`.

Verify:

```bash
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER"
kubectl get nodes
aws eks describe-cluster --name "$CLUSTER" --query cluster.identity.oidc.issuer --output text
```

Keep that issuer URL — the trust policies below need it.

### Cluster add-ons

```bash
# metrics-server — the HPA reports <unknown>/70% and never scales without it
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# AWS Load Balancer Controller — required for the ALB Ingress
eksctl create iamserviceaccount \
  --cluster "$CLUSTER" --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess \
  --approve --role-only --role-name AmazonEKSLoadBalancerControllerRole

helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName="$CLUSTER" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller

# Optional: monitoring, for the ServiceMonitors and PrometheusRule
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
```

---

## 2. Create the AWS resources

### ECR repositories

```bash
for repo in middleware ai-service frontend; do
  aws ecr create-repository \
    --repository-name "ai-interview/$repo" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability IMMUTABLE \
    --region "$AWS_REGION"
done

export ECR_REGISTRY="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION}.amazonaws.com"
echo "$ECR_REGISTRY"
```

### RDS (skip if using the in-cluster StatefulSet)

```bash
DB_PASSWORD="$(openssl rand -hex 20)"

aws rds create-db-instance \
  --db-instance-identifier ai-interview-postgres \
  --db-instance-class db.t4g.micro \
  --engine postgres --engine-version 16.14 \
  --allocated-storage 20 --storage-type gp3 --storage-encrypted \
  --master-username ai_interview_app \
  --master-user-password "$DB_PASSWORD" \
  --db-name ai_interview \
  --no-publicly-accessible \
  --backup-retention-period 7 \
  --region "$AWS_REGION"
```

Then allow the cluster's nodes in. Use a **security-group reference**, not a CIDR:
node IPs change as the group scales.

```bash
NODE_SG=$(aws eks describe-cluster --name "$CLUSTER" \
  --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)
RDS_SG=$(aws rds describe-db-instances --db-instance-identifier ai-interview-postgres \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG" --protocol tcp --port 5432 --source-group "$NODE_SG"
```

### S3 bucket for resumes

```bash
export BUCKET="ai-interview-resumes-$(openssl rand -hex 4)"

aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

# Candidate CVs are personal data. All four are required, not optional hardening.
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
```

### Secrets Manager

Two secrets. The database one uses the field names RDS-managed rotation writes,
so switching to managed rotation later needs no application change.

```bash
RDS_HOST=$(aws rds describe-db-instances --db-instance-identifier ai-interview-postgres \
  --query 'DBInstances[0].Endpoint.Address' --output text)

aws secretsmanager create-secret \
  --name ai-interview/prod/database \
  --secret-string "$(jq -nc \
    --arg h "$RDS_HOST" --arg p "$DB_PASSWORD" \
    '{engine:"postgres", host:$h, port:5432, dbname:"ai_interview",
      username:"ai_interview_app", password:$p}')"

aws secretsmanager create-secret \
  --name ai-interview/prod/application \
  --secret-string "$(jq -nc \
    --arg j "$(openssl rand -base64 48)" --arg a "$(openssl rand -hex 24)" \
    '{jwtSigningKey:$j, aiServiceApiKey:$a, openaiApiKey:""}')"
```

`jwtSigningKey` must be at least 32 bytes — the middleware refuses to start
otherwise, deliberately.

---

## 3. Create the IRSA roles

This is the part worth doing slowly. It is the whole "no AWS access keys" design,
and it is the single most common thing to get subtly wrong.

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
OIDC=$(aws eks describe-cluster --name "$CLUSTER" \
  --query cluster.identity.oidc.issuer --output text | sed 's|https://||')
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
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
      "Resource": [
        "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT}:secret:ai-interview/prod/database-*",
        "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT}:secret:ai-interview/prod/application-*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::${BUCKET}"
    }
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
    "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
    "Resource": [
      "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT}:secret:ai-interview/prod/database-*",
      "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT}:secret:ai-interview/prod/application-*"
    ]
  }]
}
EOF

aws iam put-role-policy --role-name ai-interview-ai-service \
  --policy-name ai-interview-ai-service --policy-document file:///tmp/ai-policy.json
```

### Three things that must line up

The `sub` condition is what stops *any* pod in the cluster assuming the role. All
three of these must match exactly:

| | Value |
|---|---|
| Trust policy `sub` | `system:serviceaccount:ai-interview:ai-interview-middleware` |
| Helm namespace | `-n ai-interview` |
| Rendered ServiceAccount name | `<release>-<chart>-middleware` |

The chart names the ServiceAccount `<release>-ai-interview-platform-middleware` by
default. Installing with `--set fullnameOverride=ai-interview` makes it
`ai-interview-middleware`, matching the policies above. Check before deploying:

```bash
helm template ai-interview ./helm/ai-interview-platform \
  --set fullnameOverride=ai-interview \
  -f ./helm/ai-interview-platform/values-prod.yaml \
  --set middleware.storage.s3.bucket="$BUCKET" \
  | grep -A2 'kind: ServiceAccount'
```

---

## 4. GitHub Actions deployment role (OIDC)

No `AWS_ACCESS_KEY_ID` is stored in GitHub. GitHub presents a signed token and AWS
exchanges it for short-lived credentials.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

cat > /tmp/gha-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:YOUR-ORG/ai-interview-platform:*" }
    }
  }]
}
EOF

aws iam create-role --role-name ai-interview-github-actions \
  --assume-role-policy-document file:///tmp/gha-trust.json
aws iam attach-role-policy --role-name ai-interview-github-actions \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
```

The `StringLike` on `sub` restricts this to one repository. **Omitting it lets any
GitHub repository in the world assume the role.**

Store the ARN as the `AWS_DEPLOY_ROLE_ARN` repository secret:

```bash
aws iam get-role --role-name ai-interview-github-actions --query Role.Arn --output text
```

---

## 5. Build and push images

```bash
./scripts/build-images.sh --registry "$ECR_REGISTRY" --tag v1.0.0 --push
```

In CI this is [`.github/workflows/cd.yml`](../.github/workflows/cd.yml), which
authenticates via the OIDC role above.

---

## 6. Deploy

```bash
kubectl create namespace "$NAMESPACE"

helm upgrade --install ai-interview ./helm/ai-interview-platform \
  -n "$NAMESPACE" \
  --set fullnameOverride=ai-interview \
  -f ./helm/ai-interview-platform/values.yaml \
  -f ./helm/ai-interview-platform/values-prod.yaml \
  --set global.imageRegistry="$ECR_REGISTRY" \
  --set aws.region="$AWS_REGION" \
  --set middleware.serviceAccount.roleArn="arn:aws:iam::${ACCOUNT}:role/ai-interview-middleware" \
  --set aiService.serviceAccount.roleArn="arn:aws:iam::${ACCOUNT}:role/ai-interview-ai-service" \
  --set middleware.storage.s3.bucket="$BUCKET" \
  --set ingress.host=ai-interview.example.com \
  --set ingress.certificateArn="arn:aws:acm:...:certificate/..." \
  --wait --timeout 10m
```

Verify before declaring success:

```bash
kubectl -n "$NAMESPACE" get pods,svc,ingress,hpa

# IRSA actually wired?
kubectl -n "$NAMESPACE" exec deploy/ai-interview-middleware -- env | grep AWS_
# expect AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE

API_URL=https://ai-interview.example.com ./scripts/smoke-test.sh
```

---

## 7. Hand over to ArgoCD

```bash
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/application-prod.yaml
argocd app get ai-interview-prod
```

Edit `argocd/application-*.yaml` first: `repoURL`, the namespace, and the
`parameters` block (registry, role ARNs, bucket, host).

After this, **stop running `helm upgrade` by hand.** The CD pipeline commits the
new image tag to `values-prod.yaml`; ArgoCD notices and syncs. A manual change
shows as drift, which is the point.

Deliberate differences between the two Applications:

| | dev | prod |
|---|---|---|
| `targetRevision` | `develop` branch | `v*` tag |
| `selfHeal` | on | **off** |
| Prune propagation | default | `foreground` |

`selfHeal` is off in production so an operator can scale or patch a workload
during an incident without ArgoCD reverting the mitigation mid-flight.

Both ignore `/spec/replicas` — otherwise every HPA scale event reads as drift, and
with self-heal on ArgoCD would fight the autoscaler.

---

## Secrets in production

`values-prod.yaml` sets `secrets.create: false` and
`aws.secretsManager.enabled: true`. Nothing sensitive is rendered into a manifest,
committed to Git, or visible to `helm get manifest`.

Rotation:

```bash
./scripts/generate-secrets.sh --aws ai-interview/prod/application
kubectl -n "$NAMESPACE" rollout restart deploy \
  -l app.kubernetes.io/part-of=ai-interview-platform
```

Rotating `jwtSigningKey` invalidates every issued token and signs out every user —
intended behaviour after a suspected compromise.

Database password rotation needs no restart: the secret is cached for
`app.secrets.aws.cache-ttl` (10 minutes) and re-read after that.

---

## Database migrations

Flyway runs on middleware startup. The startup probe budget (150s) covers it, and
readiness is not reported until it completes.

For a large migration, decouple it:

```bash
helm upgrade ... --set middleware.config.flywayEnabled=false

kubectl -n "$NAMESPACE" run flyway-migrate --rm -it --restart=Never \
  --image="$ECR_REGISTRY/ai-interview/middleware:v1.0.0" \
  --overrides='{"spec":{"serviceAccountName":"ai-interview-middleware"}}' \
  --env="SPRING_PROFILES_ACTIVE=prod" --command -- \
  java -Dspring.flyway.enabled=true -jar /app/middleware.jar
```

Rules that matter:

- **Never edit an applied migration.** Flyway stores a checksum; an edit makes
  every existing environment fail validation on next start. Fix forward.
- **Additive changes only**, or split across releases (add, backfill, switch
  reads, drop) so a rollback does not lose data.

### Skipping seed data

`V3` inserts demo accounts with published passwords — fine for a training cluster,
not for real data. Omit it with `flywayEnabled=false` and apply only `V1`/`V2` via
the Job above.

---

## Rollback

```bash
argocd app rollback ai-interview-prod    # or: helm rollback ai-interview -n "$NAMESPACE"
```

With a schema change, roll the image back to the last version compatible with the
**current** schema. This is why additive migrations matter: a purely additive
change leaves the previous image working.

---

## Teardown

The EKS control plane bills whether or not anything is deployed. For a session
cluster, destroy it when done:

```bash
helm uninstall ai-interview -n "$NAMESPACE"
kubectl delete ingress --all -n "$NAMESPACE"   # releases the ALB first
eksctl delete cluster --name "$CLUSTER" --region "$AWS_REGION"

aws rds delete-db-instance --db-instance-identifier ai-interview-postgres --skip-final-snapshot
aws s3 rb "s3://$BUCKET" --force
for repo in middleware ai-service frontend; do
  aws ecr delete-repository --repository-name "ai-interview/$repo" --force
done
aws secretsmanager delete-secret --secret-id ai-interview/prod/database --force-delete-without-recovery
aws secretsmanager delete-secret --secret-id ai-interview/prod/application --force-delete-without-recovery
```

Delete the Ingress **before** the cluster — otherwise the ALB is orphaned and
keeps billing.

---

## Production checklist

- [ ] `postgresql.enabled: false` — the in-cluster StatefulSet has no replication or backups
- [ ] `aws.secretsManager.enabled: true` and `secrets.create: false`
- [ ] `middleware.storage.type: s3` — a ReadWriteOnce PVC caps you at one replica
- [ ] RDS multi-AZ and deletion protection on
- [ ] Cluster API endpoint restricted from `0.0.0.0/0`
- [ ] Seed accounts from `V3` deleted or rotated
- [ ] `swaggerUiEnabled: false`
- [ ] TLS with a real ACM certificate
- [ ] ServiceMonitors and PrometheusRule enabled, alerts routed to a human
- [ ] Infrastructure codified — restore [`../terraform/`](../terraform/README.md)
