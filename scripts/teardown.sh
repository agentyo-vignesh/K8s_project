#!/usr/bin/env bash
# Destroys one environment, in the only order that works.
#
# Kubernetes controllers create AWS resources Terraform never sees - the ALB from
# the Ingress, the EBS volume from the PVC - and the ALB holds network interfaces
# in the subnets Terraform is trying to delete. A bare `terraform destroy` stops
# halfway on DependencyViolation with the database already gone.
#
# Kubernetes first, Terraform last.
#
# Usage: ./scripts/teardown.sh --env <dev|staging|prod> [--yes]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"

ENV=""
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV="$2"; shift 2 ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

say()  { echo; echo "== $*"; }
fail() { echo; echo "ERROR: $*"; exit 1; }

[ -n "$ENV" ] || fail "--env is required. One of: $(cd "$TF_DIR/environments" 2>/dev/null && ls -d */ | tr -d / | tr '\n' ' ')"
ENV_DIR="$TF_DIR/environments/$ENV"
[ -d "$ENV_DIR" ] || fail "No such environment: $ENV_DIR"

PROJECT=$(grep -E '^\s*project\s*=' "$ENV_DIR/main.tf" | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')
REGION=$(grep -E '^\s*region\s*=' "$ENV_DIR/main.tf" | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')
VPC_CIDR=$(grep -E '^\s*vpc_cidr\s*=' "$ENV_DIR/main.tf" | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')
CLUSTER="${PROJECT}-${ENV}"
NAMESPACE="$CLUSTER"

if [ "$ASSUME_YES" != true ]; then
  echo "This destroys $PROJECT/$ENV in $REGION:"
  echo "  cluster $CLUSTER, its RDS database, its ECR images, its secrets, its VPC,"
  echo "  the load balancer, and every uploaded resume."
  echo
  printf "Type the environment name to continue: "
  read -r reply
  [ "$reply" = "$ENV" ] || { echo "Aborted."; exit 1; }
fi

# Captured before the destroy - afterwards there is no state left to read it from.
VPC_ID=$(terraform -chdir="$ENV_DIR" output -raw vpc_id 2>/dev/null || echo "")

# Scoped to this environment's VPC. Filtering by name prefix would also match the
# other environment's load balancer, and this script must never touch it.
count_albs() {
  [ -n "$VPC_ID" ] || { echo 0; return; }
  aws elbv2 describe-load-balancers --region "$REGION" \
    --query "length(LoadBalancers[?VpcId=='$VPC_ID'])" --output text 2>/dev/null || echo 0
}

# Scoped by namespace, which carries the environment.
count_volumes() {
  aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=$NAMESPACE" \
    --query "length(Volumes[?State!='deleted'])" --output text 2>/dev/null || echo 0
}

# Deleting the Kubernetes object only asks for the AWS resource to go; it is gone
# when AWS says so, not when kubectl returns.
wait_for_zero() {
  local label="$1" counter="$2" i n
  for i in $(seq 1 60); do
    n=$("$counter")
    if [ "$n" = "0" ]; then echo "   $label: gone"; return 0; fi
    echo "   $label: $n left, waiting..."
    sleep 10
  done
  fail "$label still present after 10 minutes. Terraform would fail with DependencyViolation."
}

# Point kubectl at THIS environment. Without it the steps below could run against
# whichever cluster the kubeconfig happens to be on.
if aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
  CLUSTER_REACHABLE=yes
else
  CLUSTER_REACHABLE=no
  say "Cluster $CLUSTER does not exist - skipping the Kubernetes steps"
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
  say "3/6 load balancer controller - its role is a CloudFormation stack, so"
  echo "    eksctl has to remove it while the cluster still exists"
  helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || echo "   not installed"
  eksctl delete iamserviceaccount \
    --cluster="$CLUSTER" --region="$REGION" \
    --namespace=kube-system --name=aws-load-balancer-controller 2>/dev/null \
    || echo "   no iamserviceaccount to delete"
fi

# The observability namespace needs no step of its own: Prometheus has no volume
# and Grafana is a ClusterIP, so nothing outside the cluster was created. It goes
# with the cluster.

# ------------------------------------------------------------ 4. everything else
say "4/6 terraform destroy - roughly 20 minutes"
terraform -chdir="$ENV_DIR" init -input=false >/dev/null
terraform -chdir="$ENV_DIR" destroy -auto-approve

# ------------------------------------------------- 5-6. what Terraform never owned
say "5/6 load balancer controller IAM policy"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/AWSLoadBalancerControllerIAMPolicy"
# Account-global and shared by every environment. Deleting it while another
# environment still uses it would break that environment's controller, so this
# only removes it once nothing has it attached.
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  ATTACHED=$(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" \
    --query 'length(PolicyRoles)' --output text 2>/dev/null || echo 1)
  if [ "$ATTACHED" = "0" ]; then
    aws iam delete-policy --policy-arn "$POLICY_ARN" && echo "   deleted"
  else
    echo "   kept - still attached to $ATTACHED role(s) in another environment"
  fi
else
  echo "   already gone"
fi

say "6/6 CloudWatch log group - EKS creates it, so Terraform does not delete it"
LOG_GROUP="/aws/eks/${CLUSTER}/cluster"
# MSYS_NO_PATHCONV: in Git Bash an argument starting with / is rewritten into a
# Windows path and the API rejects the mangled name. Harmless everywhere else.
if MSYS_NO_PATHCONV=1 aws logs describe-log-groups --region "$REGION" \
     --log-group-name-prefix "$LOG_GROUP" --query 'logGroups[0]' --output text \
     2>/dev/null | grep -q .; then
  MSYS_NO_PATHCONV=1 aws logs delete-log-group --region "$REGION" \
    --log-group-name "$LOG_GROUP" && echo "   deleted"
else
  echo "   already gone"
fi

# --------------------------------------------------------------- final accounting
say "Anything left of $PROJECT/$ENV"
echo "load balancers : $(count_albs)"
echo "EBS volumes    : $(count_volumes)"
echo "eksctl stacks  : $(aws cloudformation describe-stacks --region "$REGION" \
  --query "length(Stacks[?contains(StackName, 'eksctl-${CLUSTER}-')])" --output text 2>/dev/null || echo 0)"
# By this environment's CIDR. The account holds other VPCs, including the other
# environment's, and counting non-default VPCs would report them as leftovers.
echo "VPC $VPC_CIDR : $(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=cidr,Values=$VPC_CIDR" --query "length(Vpcs)" --output text 2>/dev/null || echo 0)"
echo
echo "All zero means $ENV is gone."
echo
echo "terraform/global is left alone - the GitHub OIDC provider is account-wide"
echo "and any other environment still needs it."
