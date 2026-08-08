#!/usr/bin/env bash
# Builds one environment from an empty account. The reverse of teardown.sh.
#
#   ./scripts/bootstrap.sh --env dev
#
# Everything downstream of Terraform reads its names from `terraform output`
# rather than restating them, so this script holds no environment or cluster
# name of its own. Change environments/<env>/main.tf and this follows.
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
# Usage: ./scripts/bootstrap.sh --env <dev|staging|prod> [--yes] [--tag <tag>]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
STARTED=$SECONDS

ENV=""
ASSUME_YES=false
TAG="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo manual)"

while [ $# -gt 0 ]; do
  case "$1" in
    --env)  ENV="$2"; shift 2 ;;
    --yes)  ASSUME_YES=true; shift ;;
    --tag)  TAG="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

say()  { echo; echo "== $*"; }
fail() { echo; echo "ERROR: $*"; exit 1; }

# --env is required and has no default. A default would let this run against
# whichever environment somebody happened to name first.
[ -n "$ENV" ] || fail "--env is required. One of: $(cd "$TF_DIR/environments" 2>/dev/null && ls -d */ | tr -d / | tr '\n' ' ')"

# An environment is a directory. Nothing else needs to know its name.
ENV_DIR="$TF_DIR/environments/$ENV"
[ -d "$ENV_DIR" ] || fail "No such environment: $ENV_DIR"

# ------------------------------------------------------------------- preflight
say "Checking tools"
for t in terraform aws kubectl helm eksctl docker git; do
  command -v "$t" >/dev/null 2>&1 || fail "$t is not on PATH"
  echo "   $t"
done
docker info >/dev/null 2>&1 || fail "Docker is not running - the image build needs it"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text) \
  || fail "No AWS credentials"

# Read straight out of the environment file so the script cannot disagree with
# Terraform about which project or region this is.
PROJECT=$(grep -E '^\s*project\s*=' "$ENV_DIR/main.tf" | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')
REGION=$(grep -E '^\s*region\s*=' "$ENV_DIR/main.tf" | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')
[ -n "$PROJECT" ] && [ -n "$REGION" ] || fail "$ENV_DIR/main.tf must set both project and region"

STATE_BUCKET="${PROJECT}-tfstate-${ACCOUNT}"
STATE_KEY="${PROJECT}/${ENV}/terraform.tfstate"

if [ "$ASSUME_YES" != true ]; then
  echo
  echo "  project      $PROJECT"
  echo "  environment  $ENV"
  echo "  region       $REGION      account $ACCOUNT"
  echo "  state        s3://$STATE_BUCKET/$STATE_KEY"
  echo "  image tag    ${TAG:0:12}"
  echo
  echo "This creates an EKS cluster, an RDS instance, a NAT gateway and an ALB,"
  echo "plus Prometheus and Grafana inside the cluster."
  echo "Roughly USD 0.25/hour while it runs. Takes about 35 minutes."
  printf "Type the environment name to continue: "
  read -r reply
  [ "$reply" = "$ENV" ] || { echo "Aborted."; exit 1; }
fi

# ------------------------------------------------------------- 0. remote state
# The bucket cannot be created by Terraform: init has to read the state that
# would describe it. Versioning is the one backup that matters here - state is
# the only file whose loss cannot be fixed by re-running something.
say "0/10 state bucket"
if aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "   s3://$STATE_BUCKET already exists"
else
  aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --region "$REGION" \
    --versioning-configuration Status=Enabled
  aws s3api put-public-access-block --bucket "$STATE_BUCKET" --region "$REGION" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" --region "$REGION" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  echo "   created s3://$STATE_BUCKET - versioned, private, encrypted"
fi

# ---------------------------------------------------------------- 1. terraform
say "1/10 terraform - VPC, EKS, RDS, ECR, secrets, IAM (about 20 minutes)"
# The account-wide GitHub OIDC provider, applied once and shared. Every
# environment looks it up; none can create it, because AWS permits one per URL.
if ! aws iam list-open-id-connect-providers \
       --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')]" \
       --output text | grep -q .; then
  echo "   applying terraform/global first - the GitHub OIDC provider does not exist"
  terraform -chdir="$TF_DIR/global" init -input=false
  terraform -chdir="$TF_DIR/global" apply -auto-approve
fi

# No -backend-config and no -var-file. Both are written out inside
# environments/$ENV/main.tf, which is what makes it impossible to initialise
# against one environment's state and apply another environment's values - the
# mistake the previous flat layout allowed and nothing in Terraform could catch.
terraform -chdir="$ENV_DIR" init -input=false

# -auto-approve only for the environment that is rebuilt constantly. Anywhere
# else somebody reads the plan first, which is the whole reason a plan exists.
if [ "$ENV" = "dev" ]; then
  terraform -chdir="$ENV_DIR" apply -auto-approve
else
  terraform -chdir="$ENV_DIR" plan -input=false -out=tfplan
  echo
  echo "Read the plan above. It applies to $PROJECT/$ENV."
  printf "Type 'apply' to continue: "
  read -r confirm
  [ "$confirm" = "apply" ] || { rm -f "$ENV_DIR/tfplan"; fail "Aborted."; }
  # The saved plan, not a fresh one: applying a re-planned change is applying
  # something nobody reviewed.
  terraform -chdir="$ENV_DIR" apply "tfplan"
  rm -f "$ENV_DIR/tfplan"
fi

tf() { terraform -chdir="$ENV_DIR" output -raw "$1"; }

CLUSTER=$(tf cluster_name)
NAMESPACE=$(tf namespace)
REGISTRY=$(tf image_registry)
MIDDLEWARE_ROLE=$(tf middleware_role_arn)
AI_SERVICE_ROLE=$(tf ai_service_role_arn)
DB_SECRET=$(tf database_secret_id)
APP_SECRET=$(tf application_secret_id)
ECR_PREFIX=$(tf ecr_prefix)

POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${POLICY_NAME}"
POLICY_URL="https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.5.0/docs/install/iam_policy.json"

# ------------------------------------------------------------------ 2. kubectl
say "2/10 kubeconfig and namespace - $NAMESPACE"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
# Nothing else creates it: no chart declares a Namespace, and the deploy
# workflows only pass --namespace. The GitHub access entry is scoped to it too.
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ------------------------------------------------- 3. load balancer controller
# The policy is account-global and identical for every cluster, so every
# environment shares one. Only the ROLE is per-environment.
say "3/10 load balancer controller IAM policy"
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

say "4/10 controller service account - eksctl writes the trust policy"
# By hand this is a JSON document with the OIDC issuer interpolated in three
# places. Get one wrong and IAM still accepts it; the pod just cannot get
# credentials. eksctl derives all three from the cluster.
#
# Guarded on the CloudFormation stack so a re-run after a later stage failed does
# not stop here. eksctl creates the role as a stack, and asking for one that
# already exists is an error rather than a no-op.
ESA_STACK="eksctl-${CLUSTER}-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
if aws cloudformation describe-stacks --region "$REGION" \
     --stack-name "$ESA_STACK" >/dev/null 2>&1; then
  echo "   already exists"
else
  eksctl create iamserviceaccount \
    --cluster="$CLUSTER" --region="$REGION" \
    --namespace=kube-system --name=aws-load-balancer-controller \
    --attach-policy-arn="$POLICY_ARN" \
    --override-existing-serviceaccounts --approve
fi

say "5/10 controller"
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo update >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER" \
  --set region="$REGION" \
  --set vpcId="$(tf vpc_id)" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait

# ------------------------------------- 6. StorageClass, before anything claims one
say "6/10 platform - StorageClass only, the Ingress has nothing to point at yet"
helm upgrade --install platform "$ROOT/helm/platform" -n "$NAMESPACE" \
  --set createIngress=false

# ------------------------------------------------------------------- 7. the app
say "7/10 images - $ECR_PREFIX"
"$ROOT/scripts/build-images.sh" --registry "$REGISTRY" --namespace "$ECR_PREFIX" \
  --tag "$TAG" --push

say "8/10 services - middleware first, it owns the schema through Flyway"
helm upgrade --install middleware "$ROOT/helm/middleware" -n "$NAMESPACE" \
  --set imageRegistry="$REGISTRY" --set imageRepository="$ECR_PREFIX" --set imageTag="$TAG" \
  --set aws.roleArn="$MIDDLEWARE_ROLE" --set aws.region="$REGION" \
  --set aws.databaseSecretId="$DB_SECRET" --set aws.applicationSecretId="$APP_SECRET" \
  --atomic --timeout 8m

helm upgrade --install ai-service "$ROOT/helm/ai-service" -n "$NAMESPACE" \
  --set imageRegistry="$REGISTRY" --set imageRepository="$ECR_PREFIX" --set imageTag="$TAG" \
  --set aws.roleArn="$AI_SERVICE_ROLE" --set aws.region="$REGION" \
  --set aws.databaseSecretId="$DB_SECRET" --set aws.applicationSecretId="$APP_SECRET" \
  --atomic --timeout 5m

helm upgrade --install frontend "$ROOT/helm/frontend" -n "$NAMESPACE" \
  --set imageRegistry="$REGISTRY" --set imageRepository="$ECR_PREFIX" --set imageTag="$TAG" \
  --atomic --timeout 5m

# --------------------------------------------- 9. the Ingress, now it can resolve
say "9/10 Ingress"
helm upgrade --install platform "$ROOT/helm/platform" -n "$NAMESPACE" \
  --set createIngress=true --set ingressName="$CLUSTER"

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

# ------------------------------------------------------- 10. metrics, dashboards, logs
say "10/10 observability - Prometheus, Grafana, kube-state-metrics"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

# Chart versions are pinned. An unpinned chart means a class where the values
# file silently stops matching the chart it is written for.
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 88.2.0 -n observability \
  -f "$ROOT/helm/observability/upstream/kube-prometheus-stack.yaml" \
  --wait --timeout 10m


# Ours, and last. It creates ServiceMonitors, and that kind does not exist until
# the Prometheus Operator has installed the CRD - so run before this and helm
# fails with `no matches for kind "ServiceMonitor"`.
#
# In the application namespace, not observability: a ServiceMonitor's selector
# matches Services in its own namespace by default.
helm upgrade --install observability "$ROOT/helm/observability" -n "$NAMESPACE"

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

say "$PROJECT/$ENV done in $(( (SECONDS - STARTED) / 60 )) minutes"
echo
echo "  App       http://$ADDR"
echo "            admin@aiinterview.local / Admin@12345"
echo
echo "  Grafana   kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80"
echo "            http://localhost:3000  user: admin"
echo "            kubectl get secret -n observability kube-prometheus-stack-grafana \\"
echo "              -o jsonpath='{.data.admin-password}' | base64 -d"
echo
echo "  Targets   kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090"
echo "            http://localhost:9090/targets  - middleware and ai-service should both be UP"
echo
echo "  Metrics   kubectl top pods -n $NAMESPACE"
echo "  HPA       kubectl get hpa -n $NAMESPACE -w"
echo
echo "  Deploy    set AWS_DEPLOY_ROLE_ARN for this environment to:"
echo "            $(tf github_deploy_role_arn)"
echo
echo "Tear it down with ./scripts/teardown.sh --env $ENV"
