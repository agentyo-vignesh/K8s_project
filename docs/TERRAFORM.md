# Terraform

```
terraform/
├── global/                 account-level. Applied once, before any environment.
├── modules/platform/       what gets created. Applied through an environment, never directly.
└── environments/
    ├── dev/main.tf         what dev decides
    └── prod/main.tf        what prod decides
```

`cd` into an environment and you are in that environment. The backend and the
values live in the same file, so there is no `-var-file` to forget and no way to
initialise against one environment's state and apply another's values.

## Create dev

Both paths are from the repository root.

```bash
# once per account - the GitHub OIDC provider
cd terraform/global
terraform init && terraform apply

# then per environment - back to the repository root first
cd terraform/environments/dev
terraform init && terraform apply          # ~20 minutes
```

Or the whole stack, application and observability included, in one command:

```bash
./scripts/bootstrap.sh --env dev                             # ~40 minutes
```

## What `terraform apply` creates — 52 resources

**Network — 14**

```
ai-interview-dev-vpc              10.0.0.0/16
ai-interview-dev-public-1/-2      10.0.1.0/24, 10.0.4.0/24   two AZs
ai-interview-dev-private-1/-2     10.0.2.0/24, 10.0.3.0/24
ai-interview-dev-igw
ai-interview-dev-nat-eip
ai-interview-dev-nat              ~USD 32/month, the one people forget
ai-interview-dev-public-rt        + 2 associations
ai-interview-dev-private-rt       + 2 associations
```

**EKS — 9**

```
ai-interview-dev                  cluster, Kubernetes 1.36
default                           node group, t3.medium x2
ai-interview-dev-node-            launch template, IMDSv2, hop_limit 1
oidc                              cluster OIDC provider - what makes IRSA work
addons                            vpc-cni, kube-proxy, coredns, aws-ebs-csi-driver, metrics-server
```

**IAM — 16**

| Roles | For |
|---|---|
| `ai-interview-dev-cluster` | control plane |
| `ai-interview-dev-node` | nodes |
| `ai-interview-dev-ebs-csi` | CSI driver, over IRSA |
| `ai-interview-dev-middleware` | the app, over IRSA - reads secrets |
| `ai-interview-dev-ai-service` | the app, over IRSA - reads secrets |
| `ai-interview-dev-github-deploy` | CI - cannot read any secret |

Plus 5 AWS managed policy attachments, 3 inline policies (`read-secrets` x2,
`deploy`), and an EKS access entry scoped to the `ai-interview-dev` namespace.

**Database — 3**

```
ai-interview-dev-postgres    db.t4g.micro, PostgreSQL 16.14, publicly_accessible = false
ai-interview-dev-db          subnet group, private subnets only
ai-interview-dev-rds         security group - 5432 from the cluster SG only
```

**Secrets — 7**

```
ai-interview/dev/database       engine, host, port, dbname, username, password
ai-interview/dev/application    jwtSigningKey, aiServiceApiKey, openaiApiKey
random_password                 db (32), jwt (48), internal_api (32)
```

There is no Kubernetes Secret. Each pod reads Secrets Manager itself over IRSA.

**ECR — 3**

```
ai-interview-dev-platform/{middleware,ai-service,frontend}
```

Isolated per environment, so a `dev` teardown cannot reach prod's images. The
trade-off: the same commit is built twice and nothing proves the two images are
identical. Production usually shares one registry for exactly that reason.

**Not created — 6 data sources.** The GitHub OIDC provider ARN (owned by
`global/`), the cluster's OIDC thumbprint, and four IAM policy documents.

## What Terraform does *not* create

`terraform apply` leaves an empty cluster. The remaining nine stages are in
`scripts/bootstrap.sh`: the load balancer controller and its IRSA role, the
StorageClass, the three images, the three services, the Ingress, and the
observability stack.

Two of those orderings are not obvious. The StorageClass must exist **before**
the middleware, whose PVC would otherwise stay Pending forever. The Ingress must
come **after** the Services, because the controller builds the ALB from the
Services its rules name. They pull in opposite directions, so `helm/platform` is
installed twice.

## Outputs

```bash
terraform output                            # 13
terraform output -raw cluster_name          # ai-interview-dev
terraform output -raw account_id            # which account this actually hit
terraform output -json ecr_repository_urls
terraform output -raw db_password           # sensitive
```

Ten of the thirteen are the contract `scripts/bootstrap.sh` reads.

## After the first apply

The deploy role ARN now carries the environment, so the existing GitHub secret
points at a role that no longer exists and every deploy fails with AccessDenied:

```bash
gh secret set AWS_DEPLOY_ROLE_ARN --body "$(terraform output -raw github_deploy_role_arn)"
```

## Teardown

```bash
./scripts/teardown.sh --env dev
```

Not `terraform destroy` on its own. Kubernetes controllers create AWS resources
Terraform never sees - the ALB from the Ingress, the EBS volume from the PVC -
and the ALB holds network interfaces in the subnets Terraform is trying to
delete. A bare destroy stops halfway on `DependencyViolation` with the database
already gone.

## Variables

Almost none have a default. Every environment was passing an explicit value for
all of them, which made the defaults dead: change one and nothing happens,
change an environment and the default becomes a lie about what "normal" is.

The rule is now: a variable either has a default nobody overrides, or it has
none and the environment must say. Exactly two keep one — `services` and
`irsa_service_accounts`, which are shape rather than policy.

Add `environments/staging/` and miss a value, and `terraform plan` fails
immediately rather than quietly inheriting dev's.

## Costs

Roughly **USD 0.35/hour** with the observability stack running: EKS control
plane, 2 x t3.medium, NAT gateway, RDS, and the ALB once the Ingress exists.
The cluster is built and destroyed around each session rather than left up.

## `parked/`

An older full-stack version. Terraform does not load subdirectories, so it is
inert without commenting anything out.
