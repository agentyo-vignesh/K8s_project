#!/usr/bin/env bash
# Destroys everything, in the only order that works.
#
# Kubernetes controllers create AWS resources that Terraform never sees - the
# ALB from the Ingress, the EBS volume from the PVC. Terraform will not delete
# them, and it cannot delete the subnets they sit in either, so a bare
# `terraform destroy` fails halfway with DependencyViolation and leaves the
# stack in a state that is tedious to unpick. Kubernetes first, Terraform last.
#
# Usage: ./scripts/teardown.sh [--yes]
set -euo pipefail

CLUSTER=ai-interview
REGION=ap-south-1
NAMESPACE=ai-interview
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

say() { echo; echo "== $*"; }

# ---------------------------------------------------------------- confirmation
if [ "${1:-}" != "--yes" ]; then
  echo "This destroys the whole '$CLUSTER' stack in $REGION:"
  echo "  EKS cluster, node group, RDS database, ECR images, secrets, VPC,"
  echo "  the load balancer, and every uploaded resume."
  echo
  printf "Type the cluster name to continue: "
  read -r reply
  [ "$reply" = "$CLUSTER" ] || { echo "Aborted."; exit 1; }
fi

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/AWSLoadBalancerControllerIAMPolicy"

count_albs() {
  aws elbv2 describe-load-balancers --region "$REGION" \
    --query "length(LoadBalancers[?starts_with(LoadBalancerName, 'k8s-aiinterv')])" \
    --output text 2>/dev/null || echo 0
}

count_volumes() {
  aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=resume-storage" \
    --query "length(Volumes[?State!='deleted'])" --output text 2>/dev/null || echo 0
}

# Polls until the counter reaches zero. Deleting the Kubernetes object only asks
# for the AWS resource to go; it is gone when AWS says so, not when kubectl returns.
wait_for_zero() {
  local label="$1" counter="$2" i n
  for i in $(seq 1 60); do
    n=$("$counter")
    if [ "$n" = "0" ]; then echo "   $label: gone"; return 0; fi
    echo "   $label: $n left, waiting..."
    sleep 10
  done
  echo
  echo "ERROR: $label still present after 10 minutes."
  echo "Terraform would now fail with DependencyViolation. Investigate before retrying."
  exit 1
}

if kubectl cluster-info >/dev/null 2>&1; then
  CLUSTER_REACHABLE=yes
else
  CLUSTER_REACHABLE=no
  say "Cluster not reachable - skipping the Kubernetes steps"
fi

# ------------------------------------------------- 1. the ALB, held by the Ingress
if [ "$CLUSTER_REACHABLE" = yes ]; then
  say "1/6 Ingress - releases the ALB and the security groups it created"
  kubectl delete ingress "$CLUSTER" -n "$NAMESPACE" --ignore-not-found
  wait_for_zero "load balancer" count_albs
fi

# ------------------------------------------- 2. the EBS volume, held by the PVC
if [ "$CLUSTER_REACHABLE" = yes ]; then
  say "2/6 middleware release - deletes the PVC, and the gp3 StorageClass"
  echo "    reclaims the volume because its policy is Delete"
  helm uninstall middleware -n "$NAMESPACE" 2>/dev/null || echo "   not installed"
  wait_for_zero "EBS volume" count_volumes
fi

# --------------------------------------- 3. the controller and its eksctl IAM role
if [ "$CLUSTER_REACHABLE" = yes ]; then
  say "3/6 load balancer controller - the role lives in a CloudFormation stack,"
  echo "    so eksctl has to remove it while the cluster still exists"
  helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || echo "   not installed"
  eksctl delete iamserviceaccount \
    --cluster="$CLUSTER" --region="$REGION" \
    --namespace=kube-system --name=aws-load-balancer-controller 2>/dev/null \
    || echo "   no iamserviceaccount to delete"
fi

# The observability namespace deliberately needs no step of its own. Prometheus,
# Grafana, Loki and Alloy own nothing outside the cluster: persistence is off in
# every one of them and Grafana is a ClusterIP, so there is no EBS volume and no
# second load balancer to release. They disappear with the cluster.

# ------------------------------------------------------------ 4. everything else
say "4/6 terraform destroy - roughly 20 minutes"
terraform -chdir="$TF_DIR" destroy -auto-approve

# ------------------------------------------------- 5-6. what Terraform never owned
say "5/6 IAM policy created by hand"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  aws iam delete-policy --policy-arn "$POLICY_ARN" && echo "   deleted"
else
  echo "   already gone"
fi

say "6/6 CloudWatch log group - EKS creates it, so Terraform does not delete it"
LOG_GROUP="/aws/eks/${CLUSTER}/cluster"
# MSYS_NO_PATHCONV: in Git Bash an argument starting with / is rewritten into a
# Windows path, and the API rejects the mangled name. Harmless everywhere else.
if MSYS_NO_PATHCONV=1 aws logs describe-log-groups --region "$REGION" \
     --log-group-name-prefix "$LOG_GROUP" --query 'logGroups[0]' --output text \
     2>/dev/null | grep -q .; then
  MSYS_NO_PATHCONV=1 aws logs delete-log-group --region "$REGION" \
    --log-group-name "$LOG_GROUP" && echo "   deleted"
else
  echo "   already gone"
fi

# --------------------------------------------------------------- final accounting
say "Anything left behind"
echo "load balancers : $(count_albs)"
echo "EBS volumes    : $(count_volumes)"
echo "eksctl stacks  : $(aws cloudformation describe-stacks --region "$REGION" \
  --query "length(Stacks[?contains(StackName, 'eksctl')])" --output text 2>/dev/null || echo 0)"
# By CIDR, not by "non-default": this account holds another unrelated VPC on
# 172.0.0.0/16, and it is named VPC-A too. Counting non-default VPCs would
# report one left over after a perfectly clean teardown.
echo "our VPC (10.0.0.0/16) : $(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=cidr,Values=10.0.0.0/16" \
  --query "length(Vpcs)" --output text 2>/dev/null || echo 0)"
echo
echo "All zero means this stack is gone."
