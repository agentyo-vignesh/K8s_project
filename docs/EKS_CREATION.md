# Creating an EKS Cluster

Start to finish, by hand. Every error in the Troubleshooting section is one that
actually happened while writing this — including the one that hid for 25 minutes
behind an empty `health.issues: []`.

**Time** 20–25 minutes. **Cost** ~$3.74/day for the control plane and NAT gateway
before a single node exists. Read [Cost](#9-cost) before you start, and
[Teardown](#10-teardown) before you walk away.

```
Contents
  1  Run it from a VM, not your laptop
  2  Credentials: an instance role, never access keys
  3  Choosing the Kubernetes version
  4  What EKS requires from the network
  5  Choosing the instance type
  6  Create the cluster
  7  Verify — six checks
  8  Troubleshooting
  9  Cost
 10  Teardown
```

---

## 1. Run it from a VM, not your laptop

Not a rule about neatness. Three concrete reasons:

**Credentials.** A VM carries an IAM role. `aws sts get-caller-identity` works with
no `~/.aws/credentials` file at all. That is the same mechanism — the AWS SDK
default credential provider chain — that IRSA later uses for pods. Set it up on
the bastion and the pod-level version stops being abstract.

**Linux.** Everything below is bash and assumes `openssl`, `jq` and
`${VAR//,/ }`. On Windows about half of it fails in ways that look like AWS
problems.

**One environment.** In a group session, half the room in `ap-south-1` and half in
`us-east-1` is the single biggest time-waster, and it surfaces twenty minutes
later as "my cluster doesn't exist".

A `t3.micro` is enough to *drive* the cluster. It is not enough to build container
images on — see [5](#5-choosing-the-instance-type).

### Tools

```bash
# kubectl — pin to your cluster's Kubernetes version
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.36.2/2026-07-05/bin/linux/amd64/kubectl
chmod +x kubectl && sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# eksctl — always the latest, see below
ARCH=amd64; PLATFORM=$(uname -s)_$ARCH
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz
sudo install -o root -g root -m 0755 /tmp/eksctl /usr/local/bin/eksctl

sudo dnf install -y git jq tmux
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**kubectl must match your cluster version; eksctl must not.** This trips people up
constantly:

| Tool | Version rule |
|---|---|
| `kubectl` | within **±1 minor** of the cluster. v1.36 client works with 1.35, 1.36, 1.37 servers |
| `eksctl` | **always latest.** One binary handles every supported EKS version. The Kubernetes version is chosen by `--version` on the command line, not by which eksctl you installed |

Installing an old eksctl to "match" an old cluster is the wrong instinct and will
simply fail to support newer `--version` values.

```bash
aws --version        # 2.34+
eksctl version       # 0.229+
kubectl version --client
```

---

## 2. Credentials: an instance role, never access keys

Create the role in the **IAM console**, not the CLI — the console creates the
instance profile for you, the CLI does not.

```
IAM → Roles → Create role
  Trusted entity type : AWS service        ← not "AWS account"
  Use case            : EC2                ← this is the part people get wrong
  Permissions         : AdministratorAccess
```

Pick "AWS account" or "Custom trust policy" and the role is created but **never
appears in the instance's role dropdown**. The trust policy has to name
`ec2.amazonaws.com` as the principal before EC2 can assume it.

Attach it: `EC2 → your instance → Actions → Security → Modify IAM role`. It takes
effect immediately; no reboot.

> `AdministratorAccess` is deliberate here and would be wrong in production. This
> session creates EKS clusters, RDS instances, ECR repositories, Secrets Manager
> secrets and IRSA IAM roles. A narrower policy blocks you halfway through with an
> `AccessDenied` that costs more time to diagnose than the session has. Delete the
> role at teardown.

**Verify — this matters more than it looks:**

```bash
ls ~/.aws/credentials 2>/dev/null && echo "ACCESS KEY PRESENT — delete it"
aws sts get-caller-identity --query Arn --output text
```

Correct:
```
arn:aws:sts::<account>:assumed-role/<RoleName>/i-0abc123...
```

Wrong — a static access key is winning over the instance role:
```
arn:aws:iam::<account>:user/SomeName
```

Fix it with `rm ~/.aws/credentials`. **Never run `aws configure` on this box.**

### Set the region once

```bash
aws configure set region ap-south-1
```

Skip this and you get the most confusing failure mode in the whole document:
every command succeeds and returns **nothing**, because it is looking in the wrong
region. See [8.6](#86-every-describe-returns-empty).

---

## 3. Choosing the Kubernetes version

Never guess. Ask AWS:

```bash
aws eks describe-cluster-versions --region ap-south-1 \
  --query 'clusterVersions[].{Version:clusterVersion,Default:defaultVersion,EndStandard:endOfStandardSupportDate}' \
  --output table
```

```
Default  EndStandard   Version
True     2027-08-02    1.36     ← AWS default
False    2027-03-27    1.35
False    2026-12-02    1.34
False    2026-07-29    1.33     ← standard support already over
False    2025-11-26    1.31     ← long over
```

**A version past `EndStandard` still creates a cluster.** It does not warn you. It
moves to *extended support*, and the control plane price goes from **$0.10/hr to
$0.60/hr** — six times, silently, for the life of the cluster.

Pick a version that is still in standard support **and** within one minor of your
kubectl. Taking the AWS default satisfies both.

---

## 4. What EKS requires from the network

Five hard requirements. Miss any one and the failure message will not mention the
network.

### 4.1 Two subnets in two Availability Zones

EKS rejects a single-AZ cluster at creation. Non-negotiable.

### 4.2 eksctl wants **two** of whichever type you pass

This is eksctl's own validation, stricter than EKS's:

```
Error: insufficient number of subnets, at least 2x public and/or 2x private
subnets are required
```

Two private subnets in two AZs plus **one** public subnet fails. Either pass two
of each, or pass only the two private subnets and omit `--vpc-public-subnets`
entirely.

Pass two public subnets. Subnets cost nothing, and you need the second one later
anyway — the AWS Load Balancer Controller will not create an internet-facing ALB
without two public subnets in two AZs, and its error (`unable to discover
subnets`) reads like a permissions problem.

### 4.3 DNS attributes on the VPC

```bash
aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsHostnames \
  --query 'EnableDnsHostnames.Value'
aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsSupport \
  --query 'EnableDnsSupport.Value'
```

Both must be `true`. If they are not, nodes fail to join and **the error does not
mention DNS**.

### 4.4 Subnet discovery tags

| Subnet | Tag | Value |
|---|---|---|
| public | `kubernetes.io/role/elb` | `1` |
| private | `kubernetes.io/role/internal-elb` | `1` |
| all | `kubernetes.io/cluster/<cluster-name>` | `shared` |

Not decorative. The AWS Load Balancer Controller finds subnets by these tags and
by nothing else.

### 4.5 A NAT gateway, if nodes are private

With `--node-private-networking` nodes have no public IP. They reach the EKS API
endpoint, ECR and every AWS API **through the NAT gateway**. Delete the NAT to
save money mid-session and nodes stop pulling images — which presents as
`ImagePullBackOff` or nodes that never reach `Ready`, with nothing pointing at the
route table.

The NAT costs ~$0.056/hr in `ap-south-1`. It has to stay up for the whole session.
Delete it at teardown, not before.

### Verify the whole network in one command

```bash
export VPC_ID=<your-vpc-id>

aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'sort_by(Subnets,&CidrBlock)[].{Name:Tags[?Key==`Name`]|[0].Value,Id:SubnetId,
           Cidr:CidrBlock,AZ:AvailabilityZone,elb:Tags[?Key==`kubernetes.io/role/elb`]|[0].Value,
           internal:Tags[?Key==`kubernetes.io/role/internal-elb`]|[0].Value}' --output table
```

What a working layout looks like:

```
Name           Id                        Cidr          AZ            elb   internal
App-Subnet     subnet-0b379191c35b4dd1f  10.0.1.0/24   ap-south-1a   1     None
DB-Subnet-1    subnet-0fb113138dac38713  10.0.2.0/24   ap-south-1a   None  1
DB-Subnet-2    subnet-07539cb99f483dc93  10.0.3.0/24   ap-south-1b   None  1
App-Subnet-2   subnet-04c9c6c9279617a01  10.0.4.0/24   ap-south-1b   1     None
```

Two public, two private, both spanning **1a and 1b**.

Then export them. Do not skip this — see [8.1](#81-the-subnet-id--does-not-exist):

```bash
export PUB1=subnet-0b379191c35b4dd1f
export PUB2=subnet-04c9c6c9279617a01
export PVT1=subnet-0fb113138dac38713
export PVT2=subnet-07539cb99f483dc93

# prove they are all set and all real
aws ec2 describe-subnets --subnet-ids $PUB1 $PUB2 $PVT1 $PVT2 \
  --query 'length(Subnets)'      # must print 4
```

---

## 5. Choosing the instance type

Three separate limits decide this, and only one of them produces a useful error.

### 5.1 Is the type allowed in your account at all?

Accounts on the AWS **Free Plan** may only launch free-tier-eligible instance
types. Ask which ones:

```bash
aws ec2 describe-instance-types --region ap-south-1 \
  --filters "Name=free-tier-eligible,Values=true" \
  --query 'sort_by(InstanceTypes,&MemoryInfo.SizeInMiB)[].{Type:InstanceType,
           vCPU:VCpuInfo.DefaultVCpus,MemMiB:MemoryInfo.SizeInMiB}' --output table
```

```
Type              vCPU  MemMiB
t3.micro          2     1024
t4g.micro         2     1024      (arm64)
t3.small          2     2048
t4g.small         2     2048      (arm64)
c7i-flex.large    2     4096
m7i-flex.large    2     8192
```

Pick anything outside that list and the nodegroup hangs for 25 minutes. The real
error is buried — see [8.5](#85-nodegroup-stuck-in-creating-the-important-one).

Run the check **before** creating the cluster.

### 5.2 Do you have the vCPU quota?

```bash
aws service-quotas get-service-quota --region ap-south-1 \
  --service-code ec2 --quota-code L-1216C47A \
  --query '{Name:Quota.QuotaName,Value:Quota.Value}'
```

The default on a new account is often **8**. Your bastion consumes some of it:

```
bastion t3.micro         2 vCPU
2 × t3.small             4 vCPU  →  6 of 8  ✅
3 × t3.small             6 vCPU  →  8 of 8  ✅ exactly at the ceiling
4 × t3.small             8 vCPU  → 10 of 8  ❌
```

Set `--nodes-max` so the *ceiling* fits, not just the starting count. A
`--nodes-max` you cannot actually reach turns into the same silent scaling failure
the first time an HPA tries to use it.

Need more? Request an increase on `L-1216C47A`. Approval is not instant, so do it
days before a session.

### 5.3 How many pods fit?

The VPC CNI gives every pod a real VPC IP address, so pod density is bounded by
network interfaces, not RAM:

```
max-pods = ENIs × (IPv4 per ENI − 1) + 2
```

```bash
aws ec2 describe-instance-types --region ap-south-1 \
  --instance-types t3.micro t3.small c7i-flex.large \
  --query 'InstanceTypes[].{Type:InstanceType,ENIs:NetworkInfo.MaximumNetworkInterfaces,
           IPs:NetworkInfo.Ipv4AddressesPerInterface}' --output table
```

| Type | ENIs | IPs/ENI | max-pods | Allocatable RAM |
|---|---|---|---|---|
| `t3.micro` | 2 | 2 | **4** | ~625 Mi |
| `t3.small` | 3 | 4 | 11 | ~1.53 Gi |
| `c7i-flex.large` | 3 | 10 | 29 | ~3.34 Gi |
| `m7i-flex.large` | 3 | 10 | 29 | ~7.34 Gi |

Allocatable RAM is not the instance RAM. EKS reserves
`255Mi + 11Mi × max-pods` for the kubelet, plus a 100Mi eviction threshold.

**`t3.micro` cannot run a real workload.** Four pod slots per node, and `aws-node`
plus `kube-proxy` take two of them. Two slots left, before CoreDNS. Fine as a
bastion, useless as a node.

### 5.4 Sizing for this platform

The Helm chart requests, at `replicaCount: 2` for each service:

| | CPU | Memory |
|---|---|---|
| middleware ×2 | 500m | 1024 Mi |
| ai-service ×2 | 200m | 512 Mi |
| frontend ×2 | 50m | 128 Mi |
| CoreDNS + metrics-server | ~300m | ~340 Mi |
| **Total** | **~1050m** | **~2.0 Gi** |

| Option | Allocatable | App | + ArgoCD | + Prometheus/Grafana/Loki | Node cost/day |
|---|---|---|---|---|---|
| **2 × t3.small** | 3.1 Gi | ✅ | tight | ❌ | **$1.08** |
| 3 × t3.small | 4.6 Gi | ✅ | ✅ | tight | $1.61 |
| 2 × c7i-flex.large | 6.7 Gi | ✅ | ✅ | ✅ | $4.07 |
| 2 × m7i-flex.large | 14.7 Gi | ✅ | ✅ | ✅ | $4.84 |

Two `t3.small` is the smallest configuration that runs the platform. When the
monitoring stack goes in, either free up room or add a node:

```bash
helm upgrade ... --set middleware.replicaCount=1 --set aiService.replicaCount=1
# or
eksctl scale nodegroup --cluster ai-interview --region ap-south-1 --name default --nodes 3
```

> **A nodegroup's instance type cannot be changed in place.** To resize you create
> a second nodegroup, `kubectl drain` the old one, and delete it. That is not a
> setback — cordon, drain, PodDisruptionBudgets and rescheduling all become visible
> at once. Starting small and migrating later is a better lesson than starting big.

---

## 6. Create the cluster

**Start `tmux` first.** Creation takes 20 minutes; an SSH or SSM session that drops
in the middle leaves you unable to tell success from failure, and re-running is
what causes [8.3](#83-alreadyexistsexception).

```bash
tmux new -s eks
# detach: Ctrl-B then D        reattach: tmux attach -t eks
```

```bash
eksctl create cluster \
  --name ai-interview \
  --region ap-south-1 \
  --version 1.36 \
  --vpc-private-subnets=$PVT1,$PVT2 \
  --vpc-public-subnets=$PUB1,$PUB2 \
  --nodegroup-name default \
  --node-type t3.small \
  --nodes 2 --nodes-min 2 --nodes-max 3 \
  --node-private-networking \
  --managed \
  --with-oidc
```

Every flag that is doing real work:

| Flag | Why it is there |
|---|---|
| `--vpc-private-subnets` `--vpc-public-subnets` | **Without these eksctl builds its own VPC.** Your RDS instance then lives in a different VPC from the nodes, and the resulting timeout looks like a security-group problem for an hour |
| `--with-oidc` | Registers the cluster's OIDC issuer as an IAM identity provider. **Without it every IRSA annotation is silently inert** — no error, pods just fall back to the node role and secret access misbehaves later |
| `--node-private-networking` | Nodes get no public IP; they egress through the NAT gateway |
| `--managed` | Managed node group — AWS handles the AMI and the drain-on-update |
| `--nodes-max 3` | The ceiling has to fit inside the vCPU quota ([5.2](#52-do-you-have-the-vcpu-quota)) |

eksctl builds **two** CloudFormation stacks: the control plane first, then the
managed nodegroup.

**Run it exactly once.** If the terminal looks stuck, check from a second shell —
do not re-run:

```bash
aws cloudformation list-stacks --region ap-south-1 \
  --query 'StackSummaries[?contains(StackName,`eksctl`)].[StackName,StackStatus]' --output table
```

---

## 7. Verify — six checks

All six. Skipping any one of them moves the failure to a later stage where it is
harder to read.

```bash
aws eks update-kubeconfig --region ap-south-1 --name ai-interview
```

**1 — nodes**
```bash
kubectl get nodes
```
Two nodes, `Ready`. `No resources found` means kubectl is talking to the cluster
but the nodegroup has no instances — go to
[8.5](#85-nodegroup-stuck-in-creating-the-important-one).

**2 — the cluster is in *your* VPC**
```bash
aws eks describe-cluster --name ai-interview \
  --query cluster.resourcesVpcConfig.vpcId --output text
```
Must equal `$VPC_ID` exactly. Anything else means eksctl created its own VPC and
you should delete the cluster and start again with the subnet flags.

**3 — the OIDC issuer exists**
```bash
aws eks describe-cluster --name ai-interview \
  --query cluster.identity.oidc.issuer --output text
```

**4 — and is registered with IAM.** Check 3 passing does not imply check 4:
```bash
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text
```
The ARN must contain the issuer id from check 3. This is the one thing that cannot
be verified later — if it is missing, every IRSA role you create afterwards fails
without an error message.

**5 — nodes really are private**
```bash
kubectl get nodes -o wide
```
`INTERNAL-IP` in the private CIDRs (`10.0.2.x` / `10.0.3.x`), `EXTERNAL-IP` shows
`<none>`.

**6 — metrics-server**
```bash
aws eks list-addons --cluster-name ai-interview
kubectl top nodes
```
`kubectl top nodes` must return numbers. If metrics-server is missing:
```bash
aws eks create-addon --cluster-name ai-interview --addon-name metrics-server
```
Without it an HPA reports `<unknown>/70%` and never scales — and reports no error
while doing so.

---

## 8. Troubleshooting

Every one of these is real.

### 8.1 `The subnet ID '' does not exist`

```
Error: operation error EC2: DescribeSubnets, api error InvalidSubnetID.NotFound:
The subnet ID '' does not exist
```

An unset shell variable. `--vpc-private-subnets=$PVT1,$PVT2` with `$PVT1` empty
becomes `--vpc-private-subnets=,`.

Shell variables do not survive a new terminal, and `tmux` panes opened later do
not inherit them either. After any reconnect, re-export and re-check:

```bash
echo "$PUB1 $PUB2 $PVT1 $PVT2"
aws ec2 describe-subnets --subnet-ids $PUB1 $PUB2 $PVT1 $PVT2 --query 'length(Subnets)'
```

### 8.2 `insufficient number of subnets`

```
[✖] unable to use given VPC (vpc-...) and subnets (private:map[...] public:map[...])
Error: insufficient number of subnets, at least 2x public and/or 2x private
subnets are required
```

You passed one subnet of a type. eksctl wants two of whichever type you name. Add
a second public subnet — see [4.2](#42-eksctl-wants-two-of-whichever-type-you-pass).

Subnets are free, so there is never a reason to work around this rather than fix it.

### 8.3 `AlreadyExistsException`

```
[✖] creating CloudFormation stack "eksctl-ai-interview-cluster":
AlreadyExistsException: Stack [eksctl-ai-interview-cluster] already exists
Error: failed to create cluster "ai-interview"
```

A previous run got further than you thought. Almost always: the session dropped,
the run looked dead, and it was re-launched.

**Do not delete anything yet.** Check what actually exists first:

```bash
aws cloudformation list-stacks --region ap-south-1 \
  --query 'StackSummaries[?contains(StackName,`eksctl`)].[StackName,StackStatus,CreationTime]' --output table
aws eks list-clusters --region ap-south-1
```

If the cluster stack is `CREATE_COMPLETE`, **the cluster is fine** — the first run
succeeded and the second one collided with it. Attach to the original, or just
write the kubeconfig and carry on:

```bash
aws eks update-kubeconfig --region ap-south-1 --name ai-interview
```

If the stack is `ROLLBACK_COMPLETE` or `CREATE_FAILED`, it is a corpse and must go:

```bash
eksctl delete cluster --name ai-interview --region ap-south-1 --wait
```

Prevention: `tmux`.

### 8.4 `The connection to the server localhost:8080 was refused`

```
E0804 13:15:03 memcache.go:265 "Unhandled Error" err="couldn't get current server
API group list: Get \"http://localhost:8080/api?timeout=32s\": dial tcp
127.0.0.1:8080: connect: connection refused"
```

This is not a cluster problem and not a network problem. `localhost:8080` is
kubectl's built-in default when **there is no kubeconfig at all**. eksctl writes
the kubeconfig at the end of a successful run, so any earlier failure leaves you
without one.

```bash
aws eks update-kubeconfig --region ap-south-1 --name ai-interview
```

Once fixed, `kubectl get nodes` returning `No resources found` is a *different and
better* state: kubectl is authenticated and talking to the API server, there are
simply no nodes yet.

A stale kubeconfig — one that exists but points at a cluster that is gone — fails
differently again; see [8.9](#89-unable-to-connect-to-the-server-no-such-host).

### 8.5 Nodegroup stuck in `CREATING`: the important one

**Symptom.** The control plane is `ACTIVE`. The nodegroup sits in `CREATING` for
25 minutes. `kubectl get nodes` says `No resources found`. Nothing reports an
error.

Here is what each layer told us, in the order you would naturally look:

```
kubectl get nodes                                   →  No resources found
aws eks describe-nodegroup ... .health               →  issues: []          ← "nothing is wrong"
aws cloudformation describe-stack-events             →  CREATE_IN_PROGRESS  ← says nothing
aws ec2 describe-instances                           →  empty
aws autoscaling describe-scaling-activities          →  the actual error    ← only here
```

The Auto Scaling group had been retrying every four minutes and failing every
time:

```
Could not launch On-Demand Instances. InvalidParameterCombination - The specified
instance type is not eligible for Free Tier. For a list of Free Tier instance
types, run 'describe-instance-types' with the filter 'free-tier-eligible=true'.
Launching EC2 instance failed.
```

The account was on the AWS Free Plan and `t3.large` is not free-tier-eligible.
EKS never surfaces this: it asks the ASG for capacity, the ASG fails, and the
nodegroup simply keeps waiting.

**The diagnostic ladder. For any managed nodegroup that will not produce nodes,
go straight to the bottom rung.**

```bash
# 1. is the ASG even there? note the name is eks-<nodegroup>-<uuid>,
#    it does NOT contain the cluster name — filtering on the cluster name finds nothing
aws autoscaling describe-auto-scaling-groups --region ap-south-1 \
  --query 'AutoScalingGroups[].{Name:AutoScalingGroupName,Desired:DesiredCapacity,Have:length(Instances)}' \
  --output table

# 2. why is it not launching
ASG=$(aws autoscaling describe-auto-scaling-groups --region ap-south-1 \
  --query "AutoScalingGroups[?contains(Tags[?Key=='eks:cluster-name'].Value,'ai-interview')].AutoScalingGroupName | [0]" \
  --output text)

aws autoscaling describe-scaling-activities --region ap-south-1 \
  --auto-scaling-group-name "$ASG" --max-items 5 \
  --query 'Activities[].{Time:StartTime,Status:StatusCode,Why:StatusMessage}' --output table
```

`Desired: 2, Have: 0` plus a `Failed` activity is the whole diagnosis.

Other causes that surface in exactly the same place, with the same silence
everywhere else:

| `StatusMessage` contains | Cause |
|---|---|
| `not eligible for Free Tier` | Account restricted to free-tier instance types |
| `VcpuLimitExceeded` | vCPU quota — [5.2](#52-do-you-have-the-vcpu-quota) |
| `InsufficientInstanceCapacity` | AZ is out of that type; try another type or AZ |
| `does not have enough free addresses` | Subnet CIDR exhausted |

**Fix, once you know the cause.** The cluster is fine — only replace the nodegroup:

```bash
eksctl delete nodegroup --cluster ai-interview --region ap-south-1 --name default --wait

# if it refuses because the nodegroup is mid-CREATING
aws eks delete-nodegroup --cluster-name ai-interview --nodegroup-name default
aws eks wait nodegroup-deleted --cluster-name ai-interview --nodegroup-name default

eksctl create nodegroup \
  --cluster ai-interview --region ap-south-1 --name default \
  --node-type t3.small \
  --nodes 2 --nodes-min 2 --nodes-max 3 \
  --node-private-networking --managed
```

Deleting the whole cluster also works and takes three times as long.

**The transferable lesson:** `health.issues: []` means *EKS has no opinion*, not
*everything is fine*. Managed nodegroups delegate capacity to an ASG, and the ASG
keeps its failures in its own activity log. Anything about nodes that will not
appear — look there first, not last.

### 8.6 Every `describe` returns empty

No error. No output. Usually a region mismatch: the AWS CLI defaults to one region
while your resources are in another.

```bash
aws configure list          # check the region row and where it comes from
aws configure set region ap-south-1
```

The same class of bug bites EC2 tag filters, which are **case-sensitive**:
`"Name=tag:Name,Values=Private*"` matches nothing when the tag says `private`. An
empty result from a filter is not proof the resource is absent.

### 8.7 Nodes `Ready`, but pods stay `ImagePullBackOff`

Private nodes reach ECR through the NAT gateway. Check the NAT exists, is
`available`, and that the private route table actually points at it:

```bash
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" \
  --query 'NatGateways[].{Id:NatGatewayId,State:State}' --output table

aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Assoc:length(Associations),
           Default:Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId,NatGatewayId]|[0]}' \
  --output json
```

A NAT recreated after the route table was written leaves a route pointing at a
gateway that no longer exists. The route table shows an id; the id is dead.

If you delete the NAT to save money, you have broken image pulls, Secrets Manager
and STS for every private pod. Delete it at teardown, not during.

### 8.8 `Error acquiring the state lock` (Terraform)

```
Error message: Failed to read state file: ... the process cannot access the file
because another process has locked a portion of the file.
```

Another `terraform` process is running. Find out which before doing anything:

```bash
cat .terraform.tfstate.lock.info    # Operation, Who, Created
```

If it says `OperationTypeApply` and someone is genuinely applying, **wait**.
`-lock=false` and `force-unlock` on a live apply is how state gets corrupted.

### 8.9 `Unable to connect to the server: no such host`

```
Unable to connect to the server: dial tcp: lookup
44B85B8A912AA58832374DB15801219D.gr7.ap-south-1.eks.amazonaws.com
on 172.31.0.2:53: no such host
```

**Not a DNS problem and not a network problem.** That hostname belongs to a cluster
that no longer exists. When a cluster is deleted, AWS withdraws its endpoint record,
so the lookup genuinely has nothing to resolve.

You get here by deleting a cluster and creating a new one with the same name. The
kubeconfig entry is keyed on the **cluster ARN**, which is identical for both —
`arn:aws:eks:<region>:<account>:cluster/<name>` — so the old context looks
perfectly valid while pointing at a dead endpoint. The endpoint id changed; the
context name did not.

Confirm which cluster is actually live, and note the id:

```bash
aws eks list-clusters --region ap-south-1
aws eks describe-cluster --name ai-interview --query cluster.endpoint --output text
```

If the id differs from the one in the error, the kubeconfig is stale. One command
fixes it — same ARN means it overwrites in place, nothing to clean up by hand:

```bash
aws eks update-kubeconfig --region ap-south-1 --name ai-interview
```

Then re-check the OIDC provider. **A recreated cluster has a new OIDC issuer id**,
so every IRSA trust policy written against the old one is now wrong and will fail
with `AccessDenied` rather than anything mentioning OIDC:

```bash
aws eks describe-cluster --name ai-interview --query cluster.identity.oidc.issuer --output text
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text
```

Any IRSA role created before the recreate has to have its trust policy updated to
the new issuer. This is the most expensive hidden cost of recreating a cluster.

---

## 9. Cost

`ap-south-1`, on-demand, per 24 hours:

| Item | Rate | Per day |
|---|---|---|
| EKS control plane (standard support) | $0.10/hr | **$2.40** |
| EKS control plane (extended support) | $0.60/hr | $14.40 |
| NAT gateway | $0.056/hr | **$1.34** + data |
| 2 × `t3.small` | $0.0224/hr each | $1.08 |
| 2 × `c7i-flex.large` | $0.0848/hr each | $4.07 |
| bastion `t3.micro` | $0.0112/hr | $0.27 |

A minimal working cluster is about **$4.82/day**, and $3.74 of that is the control
plane and NAT — fixed, regardless of node size. Downsizing nodes below `t3.small`
saves very little against that floor, which is why chasing cheaper nodes is not
worth breaking the cluster over.

Running a version in extended support turns $4.82/day into **$16.82/day** with no
warning anywhere in the console.

---

## 10. Teardown

Order matters. Each step holds resources the next one needs to release.

```bash
# 1. Kubernetes objects that own AWS resources — LoadBalancers and PVCs.
#    Skip this and you orphan ELBs that keep billing and block the VPC delete.
kubectl delete ingress --all -A
kubectl delete svc --all-namespaces --field-selector spec.type=LoadBalancer

# 2. the cluster (nodegroup, addons, control plane, OIDC provider)
eksctl delete cluster --name ai-interview --region ap-south-1 --wait

# 3. RDS, if you created it
aws rds delete-db-instance --db-instance-identifier ai-interview-postgres \
  --skip-final-snapshot --delete-automated-backups
aws rds wait db-instance-deleted --db-instance-identifier ai-interview-postgres

# 4. the network — LAST. This is where the NAT gateway charge stops.
cd terraform && terraform destroy

# 5. the bastion and its IAM role
```

`eksctl delete cluster` does **not** delete a VPC it did not create. Confirm the
network survived if you intend to reuse it:

```bash
aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].State' --output text
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'length(Subnets)'
```

`DependencyViolation` on step 4 means something is still attached:

```bash
aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Desc:Description}' --output table
```

Usually a load balancer from step 1 that was missed, or an RDS instance that has
not finished deleting.

**Verify nothing is left billing:**

```bash
aws ec2 describe-nat-gateways --query 'NatGateways[?State==`available`].NatGatewayId'
aws ec2 describe-addresses --query 'Addresses[].PublicIp'
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId'
```

All four should be empty. An unattached Elastic IP bills too.

---

## Checklist

Before creating:

- [ ] `aws sts get-caller-identity` shows `assumed-role`, not `user`
- [ ] `~/.aws/credentials` does not exist
- [ ] Region set, and it matches where the VPC is
- [ ] kubectl within ±1 minor of the target version; eksctl is latest
- [ ] Chosen version is still in **standard** support
- [ ] ≥2 public and ≥2 private subnets, spanning ≥2 AZs
- [ ] `enableDnsHostnames` and `enableDnsSupport` both `true`
- [ ] Subnet discovery tags present
- [ ] NAT gateway `available`, private route table points at it
- [ ] Instance type appears in `free-tier-eligible` (if on the Free Plan)
- [ ] `--nodes-max × vCPU` + bastion fits inside the vCPU quota
- [ ] Subnet variables exported and `length(Subnets)` returns the right count
- [ ] Running inside `tmux`

After creating:

- [ ] 2 nodes `Ready`
- [ ] `resourcesVpcConfig.vpcId` equals your VPC
- [ ] OIDC issuer exists **and** appears in `list-open-id-connect-providers`
- [ ] Nodes have no `EXTERNAL-IP`
- [ ] `kubectl top nodes` returns numbers
