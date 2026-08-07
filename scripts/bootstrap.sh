#!/usr/bin/env bash
# Builds the whole stack from an empty account. The reverse of teardown.sh.
#
# Two orderings in here are not obvious and both cost an afternoon to discover:
#
#   - The StorageClass must exist before the middleware, because its PVC stays
#     Pending forever without a default class. EKS does not ship one marked
#     default.
#   - The Ingress must come after the Services. The load balancer controller
#     builds the ALB from the Services named in the rules, and will not create
#     one while they are missing.
#
# Those pull in opposite directions, so the platform chart is installed twice:
# StorageClass first, Ingress last.
#
# Usage: ./scripts/bootstrap.sh [--yes] [--tag <tag>]
set -euo pipefail

CLUSTER=ai-interview
REGION=ap-south-1
NAMESPACE=ai-interview
POLICY_NAME=AWSLoadBalancerControllerIAMPolicy
POLICY_URL=https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.5.0/docs/install/iam_policy.json

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
STARTED=$SECONDS

ASSUME_YES=false
TAG="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo manual)"

while [ $# -gt 0 ]; do
  case "$1" in
    --yes)  ASSUME_YES=true; shift ;;
    --tag)  TAG="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

say()  { echo; echo "== $*"; }
fail() { echo; echo "ERROR: $*"; exit 1; }

# ------------------------------------------------------------------- preflight
say "Checking tools"
for t in terraform aws kubectl helm eksctl docker git; do
  command -v "$t" >/dev/null 2>&1 || fail "$t is not on PATH"
  echo "   $t"
done
docker info >/dev/null 2>&1 || fail "Docker is not running - the image build needs it"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text) \
  || fail "No AWS credentials"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${POLICY_NAME}"

if [ "$ASSUME_YES" != true ]; then
  echo
  echo "Account $ACCOUNT, region $REGION, image tag ${TAG:0:12}"
  echo "This creates an EKS cluster, an RDS instance, a NAT gateway and an ALB."
  echo "Roughly USD 178/month while it runs. Takes about 35 minutes."
  printf "Type the cluster name to continue: "
  read -r reply
  [ "$reply" = "$CLUSTER" ] || { echo "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------- 1. terraform
say "1/8 terraform - VPC, EKS, RDS, ECR, secrets, IAM (about 20 minutes)"
terraform -chdir="$TF_DIR" init -input=false
terraform -chdir="$TF_DIR" apply -auto-approve

MIDDLEWARE_ROLE=$(terraform -chdir="$TF_DIR" output -raw middleware_role_arn)
AI_SERVICE_ROLE=$(terraform -chdir="$TF_DIR" output -raw ai_service_role_arn)

# ------------------------------------------------------------------ 2. kubectl
say "2/8 kubeconfig and namespace"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
# Nothing else creates it: no chart declares a Namespace, and the deploy
# workflows only pass --namespace. The GitHub access entry is scoped to it too.
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ------------------------------------------------- 3. load balancer controller
say "3/8 load balancer controller IAM policy"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  echo "   already exists"
else
  # A bare relative filename, resolved from the process working directory.
  # An absolute path would not survive Git Bash: /tmp there is inside the Git
  # installation, but the aws CLI is a Windows binary and looks at C:\tmp.
  (
    cd "$ROOT"
    curl -sL -o alb-iam-policy.json "$POLICY_URL"
    aws iam create-policy --policy-name "$POLICY_NAME" \
      --policy-document file://alb-iam-policy.json >/dev/null
    rm -f alb-iam-policy.json
  )
  echo "   created"
fi

say "4/8 controller service account - eksctl writes the trust policy"
# By hand this is a JSON document with the OIDC issuer interpolated in three
# places. Get one wrong and IAM still accepts it; the pod just cannot get
# credentials. eksctl derives all three from the cluster.
eksctl create iamserviceaccount \
  --cluster="$CLUSTER" --region="$REGION" \
  --namespace=kube-system --name=aws-load-balancer-controller \
  --attach-policy-arn="$POLICY_ARN" \
  --override-existing-serviceaccounts --approve

say "5/8 controller"
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo update >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER" \
  --set region="$REGION" \
  --set vpcId="$(terraform -chdir="$TF_DIR" output -raw vpc_id)" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait

# ------------------------------------- 6. StorageClass, before anything claims one
say "6/8 platform - StorageClass only, the Ingress has nothing to point at yet"
helm upgrade --install platform "$ROOT/helm/platform" -n "$NAMESPACE" \
  --set createIngress=false

# ------------------------------------------------------------------- 7. the app
say "7/8 images"
"$ROOT/scripts/build-images.sh" --registry "$REGISTRY" --tag "$TAG" --push

say "7/8 services - middleware first, it owns the schema through Flyway"
helm upgrade --install middleware "$ROOT/helm/middleware" -n "$NAMESPACE" \
  --set imageRegistry="$REGISTRY" --set imageTag="$TAG" \
  --set aws.roleArn="$MIDDLEWARE_ROLE" \
  --atomic --timeout 8m

helm upgrade --install ai-service "$ROOT/helm/ai-service" -n "$NAMESPACE" \
  --set imageRegistry="$REGISTRY" --set imageTag="$TAG" \
  --set aws.roleArn="$AI_SERVICE_ROLE" \
  --atomic --timeout 5m

helm upgrade --install frontend "$ROOT/helm/frontend" -n "$NAMESPACE" \
  --set imageRegistry="$REGISTRY" --set imageTag="$TAG" \
  --atomic --timeout 5m

# --------------------------------------------- 8. the Ingress, now it can resolve
say "8/8 Ingress"
helm upgrade --install platform "$ROOT/helm/platform" -n "$NAMESPACE" \
  --set createIngress=true

echo "   waiting for the ALB address"
ADDR=""
for _ in $(seq 1 40); do
  ADDR=$(kubectl get ingress "$CLUSTER" -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$ADDR" ] && break
  sleep 15
done
[ -n "$ADDR" ] || fail "The Ingress never got an address. Check: kubectl logs -n kube-system deploy/aws-load-balancer-controller"

# The address appears before the ALB is serving. DNS has to propagate and the
# targets have to pass their first health check, so poll rather than assume.
echo "   waiting for $ADDR to answer"
for _ in $(seq 1 40); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$ADDR/" || echo 000)
  [ "$code" = "200" ] && break
  sleep 15
done

# ---------------------------------------------------------------------- verify
say "Verifying through the ALB"
printf "frontend   : %s\n" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://$ADDR/")"

TOKEN=$(curl -s --max-time 25 -X POST "http://$ADDR/api/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@aiinterview.local","password":"Admin@12345"}' \
  | python -c 'import sys,json;print(json.load(sys.stdin).get("accessToken",""))' 2>/dev/null || true)

if [ -n "$TOKEN" ]; then
  printf "login      : 200\n"
  printf "candidates : %s\n" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer $TOKEN" "http://$ADDR/api/v1/candidates")"
else
  printf "login      : FAILED - kubectl logs -n %s deploy/middleware\n" "$NAMESPACE"
fi

say "Done in $(( (SECONDS - STARTED) / 60 )) minutes"
echo
echo "  http://$ADDR"
echo "  admin@aiinterview.local / Admin@12345"
echo
echo "Tear it down with ./scripts/teardown.sh - a bare terraform destroy will not work."
