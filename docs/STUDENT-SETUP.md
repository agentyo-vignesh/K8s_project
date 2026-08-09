# Run this on your own AWS account

Fork it, change five lines, run two scripts. About 40 minutes.

Read the whole page before you start. Two of the traps below cost half an hour
each if you meet them without warning.

## What you need

| | |
|---|---|
| AWS account | your own. Admin access |
| Tools | `terraform` (1.10+), `aws`, `kubectl`, `helm`, `eksctl`, `docker`, `git`, `gh` |
| Docker | **running** - the build stage needs it |
| Cost | about **USD 0.25/hour**. Destroy it when you stop for the day |

```bash
aws sts get-caller-identity     # must return your account
gh auth status                  # must be logged in
docker info                     # must not error
```

---

## 1. Fork and clone

Fork on github.com, then:

```bash
git clone https://github.com/<your-name>/K8s_project
cd K8s_project
```

On your fork: **Actions tab → "I understand my workflows, enable them"**.
Workflows do not run on a fresh fork until you click that.

## 2. Get your three values

```bash
aws sts get-caller-identity --query Account --output text
gh api repos/<your-name>/K8s_project --jq '{owner:.owner.id, repo:.id}'
```

## 3. Change five lines

**`terraform/global/main.tf`** — line 20

```hcl
bucket = "ai-interview-tfstate-<YOUR_ACCOUNT_ID>"
```

**`terraform/environments/dev/main.tf`** — lines 20, 101, 102, 103

```hcl
bucket = "ai-interview-tfstate-<YOUR_ACCOUNT_ID>"

github_repo     = "<your-name>/K8s_project"
github_owner_id = "<owner id from step 2>"
github_repo_id  = "<repo id from step 2>"
```

That is all. The account id appears nowhere else — every ARN is built at apply
time from `aws_caller_identity`.

Confirm you missed nothing:

```bash
grep -rn "043083733056\|agentyo-vignesh" terraform/ --include="*.tf"
```

Anything it prints is a line you have not changed yet.

## 4. Build it

```bash
./scripts/bootstrap.sh --env dev
```

Type `dev` when it asks. Then leave it alone for about 40 minutes.

By hand instead, if you want to watch each piece:

```bash
cd terraform/global            && terraform init && terraform apply
cd ../../terraform/environments/dev && terraform init && terraform apply
```

That gives you 52 AWS resources and an empty cluster. `bootstrap.sh` does that
plus the nine stages after it — the load balancer controller, the images, the
three services, the Ingress and Prometheus.

## 5. One GitHub secret

```bash
cd terraform/environments/dev
gh secret set AWS_DEPLOY_ROLE_ARN --body "$(terraform output -raw github_deploy_role_arn)"
```

Without it every deploy workflow fails at the AWS login step with `AccessDenied`.
`bootstrap.sh` prints the ARN at the end; this command avoids copying it by hand.

## 6. Open it

`bootstrap.sh` prints the ALB address. If the browser says the site cannot be
reached, see the DNS trap below before assuming anything is broken.

Sign in as `admin@aiinterview.local` / `Admin@12345`.

## 7. Destroy it

```bash
./scripts/teardown.sh --env dev
```

**Not `terraform destroy` on its own.** Kubernetes controllers created AWS
resources Terraform never saw — the load balancer from the Ingress, the disk from
the PVC — and the load balancer holds network interfaces in the subnets Terraform
is trying to delete. A bare destroy stops halfway on `DependencyViolation` with
your database already gone.

The NAT gateway is USD 32/month on its own. Destroy it every day.

---

# The traps

These are not hypothetical. Every one of them happened while building this.

## Free Tier instance types

Your account is probably Free Tier restricted. If it is, and you change the node
type, the node group sits in `CREATING` for **half an hour** and then fails.

What you will see, and why it is so hard to read:

```
nodegroup status         CREATING        for 29 minutes
nodegroup health.issues  []              empty
EC2 instances            none launched
```

The reason is only in the Auto Scaling group's activity:

```bash
ASG=$(aws autoscaling describe-auto-scaling-groups --region ap-south-1 \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName,'default')].AutoScalingGroupName" \
  --output text)
aws autoscaling describe-scaling-activities --region ap-south-1 \
  --auto-scaling-group-name "$ASG" --max-items 2 --query 'Activities[].StatusMessage'
```

```
The specified instance type is not eligible for Free Tier.
```

Which types you may launch:

```bash
aws ec2 describe-instance-types --region ap-south-1 \
  --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].{Type:InstanceType,MiB:MemoryInfo.SizeInMiB}' --output table
```

`dev` uses `t3.small`, which is eligible. **Leave it alone** unless you have
checked the list.

To recover: delete the stuck node group, then apply again.

```bash
aws eks delete-nodegroup --region ap-south-1 \
  --cluster-name ai-interview-dev --nodegroup-name default
```

## DNS says the site does not exist

The load balancer's DNS record is new. If you asked for it before it existed,
your resolver cached "no such domain" and will keep saying so.

```bash
nslookup <alb-address> 8.8.8.8     # public DNS: does the record exist?
```

If Google resolves it and you cannot, it is your resolver:

```powershell
ipconfig /flushdns
```

Still failing? Set your adapter's DNS to `8.8.8.8`, or wait ten minutes. The
cluster is fine — this is entirely local.

## Do not interrupt bootstrap.sh

`Ctrl+C` during a `helm --wait` leaves that release marked `failed` even though
its pods came up. Re-run the same script — every stage is safe to repeat — or
finish the one release by hand.

If a re-run stops at the `eksctl` stage, the CloudFormation stack already exists
and the guard in the script should skip it. If it does not, delete the stack and
re-run.

## The deploy role ARN changed

If you rebuild the cluster, the role is recreated and the secret you set in step
5 points at a role that no longer exists. Re-run step 5 after every rebuild.

---

# Sharing one AWS account

Only if you have to. Also change `project`:

```hcl
project = "<your-name>"        # instead of ai-interview
```

Every name derives from `${project}-${environment}`, so you get `<your-name>-dev`
— your own cluster, VPC, database, ECR repositories, IAM roles and secrets.
Nothing collides.

Two things still collide, because they are account-global:

| | |
|---|---|
| The IAM OIDC provider for GitHub | `terraform/global` — **exactly one person applies it** |
| `AWSLoadBalancerControllerIAMPolicy` | created once; everyone else gets `EntityAlreadyExists`, which is fine |

On your own account neither is an issue — you apply `global` yourself.

---

# What you should be able to do afterwards

```bash
kubectl get pods -n ai-interview-dev          # three, Running
kubectl get secrets -n ai-interview-dev       # empty. The password is in AWS
kubectl top pods -n ai-interview-dev          # metrics-server works
kubectl get hpa -n ai-interview-dev           # a real percentage, not <unknown>

# Prometheus is scraping both services
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
# then http://localhost:9090/targets

# Grafana
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
kubectl get secret -n observability kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

Then change one line in `frontend/src/pages/LoginPage.jsx`, push, and watch your
own pipeline build it and deploy it to your own cluster.

More detail: [TERRAFORM.md](TERRAFORM.md) for what gets created,
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) for failures, and
[RBAC_VS_IRSA.md](RBAC_VS_IRSA.md) for why no AWS key exists anywhere.
