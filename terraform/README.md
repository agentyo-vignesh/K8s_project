# Terraform

Everything is created in one `terraform apply`. Files are numbered in the order
they are applied.

```
1.vpc.tf       network - VPC, 2 public + 2 private subnets, NAT gateway
2.eks.tf       EKS cluster, nodes, addons, OIDC provider
3.rds.tf       PostgreSQL, in the private subnets
4.ecr.tf       three container registries
5.secrets.tf   Secrets Manager + the IAM role External Secrets Operator uses
parked/        an older full-stack version, commented out. Ignore it.
```

The numbers are for humans. Terraform works out the real order from the
dependencies between resources.

## Use it

```bash
cd terraform
terraform init
terraform apply

terraform output -raw rds_endpoint
terraform output -raw eso_role_arn
terraform output -raw docker_login
```

## What it costs

Roughly **$160/month** while it is running:

| | |
|---|---|
| EKS control plane | $73 |
| 2 x t3.small nodes | $32 |
| NAT gateway + Elastic IP | $41 |
| RDS db.t4g.micro | $15 |

The NAT gateway bills whether or not anything uses it. Do not delete it to save
money mid-session - private pods lose internet and every image pull fails.

## Teardown

```bash
terraform destroy
```

Two things Terraform does not clean up, because it did not create them:

```bash
# CloudWatch log group - EKS creates it, and it never expires
aws logs delete-log-group --log-group-name /aws/eks/ai-interview/cluster --region ap-south-1

# leftover disks from PersistentVolumeClaims
aws ec2 describe-volumes --region ap-south-1 --filters "Name=status,Values=available"
```

`DependencyViolation` on destroy means something is still attached - usually a
load balancer or an RDS instance that has not finished deleting.

## Two things worth knowing

**The database password is in `terraform.tfstate` in plain text.** That is how
Terraform works: every value a resource returns is recorded so the next plan can
compare against it. `.gitignore` covers `*.tfstate`, but anyone who can read the
file can read the password. The real fix is an encrypted S3 backend.

**Two subnets of each type, in two zones, is not optional.** EKS refuses a
single-zone cluster, and an RDS subnet group needs two as well. Subnets are
free.
