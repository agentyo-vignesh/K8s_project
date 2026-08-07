#!/usr/bin/env bash
# =============================================================================
# Session environment variables.
#
#   source ./scripts/session-vars.sh
#
# Every phase in docs/DEVOPS_PHASES.md assumes these are set. Sourcing one file
# instead of exporting by hand removes the single biggest time-waster in a group
# session: half the room in ap-south-1 and half in us-east-1, discovering it
# twenty minutes later when a cluster lookup returns nothing.
#
# Sourced, not executed — it has to modify your current shell. Running it with
# `./scripts/session-vars.sh` sets variables in a subshell that then exits, which
# looks like it worked and does nothing.
# =============================================================================

# Guard against being executed rather than sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "This script must be SOURCED, not executed:" >&2
    echo "    source ./scripts/session-vars.sh" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Agree these three as a group before anyone runs anything.
# -----------------------------------------------------------------------------
export AWS_REGION="${AWS_REGION:-ap-south-1}"
export CLUSTER="${CLUSTER:-ai-interview}"
export NAMESPACE="${NAMESPACE:-ai-interview}"

# -----------------------------------------------------------------------------
# Derived. Nothing below needs editing.
# -----------------------------------------------------------------------------
export ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"

if [ -z "${ACCOUNT}" ]; then
    printf '\033[0;31m[x]\033[0m Could not reach AWS. Fix credentials before continuing:\n' >&2
    printf '    aws sts get-caller-identity\n' >&2
else
    export ECR_REGISTRY="${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    export MW_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/ai-interview-middleware"
    export AI_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/ai-interview-ai-service"
    export DB_SECRET_ID="ai-interview/prod/database"
    export APP_SECRET_ID="ai-interview/prod/application"
fi

# The OIDC issuer only exists once the cluster does, so this stays empty until
# after Phase 8 and is re-resolved every time the file is sourced.
export OIDC="$(aws eks describe-cluster --name "${CLUSTER}" --region "${AWS_REGION}" \
    --query cluster.identity.oidc.issuer --output text 2>/dev/null | sed 's|https://||')"

# S3 bucket names are globally unique, so this cannot be derived — it is written
# down at creation time in Phase 10 and read back here on later sourcing.
BUCKET_FILE=".session-bucket"
if [ -f "${BUCKET_FILE}" ]; then
    export BUCKET="$(cat "${BUCKET_FILE}")"
fi

# -----------------------------------------------------------------------------
printf '\033[0;34mSession variables\033[0m\n'
printf '  AWS_REGION    %s\n' "${AWS_REGION}"
printf '  CLUSTER       %s\n' "${CLUSTER}"
printf '  NAMESPACE     %s\n' "${NAMESPACE}"
printf '  ACCOUNT       %s\n' "${ACCOUNT:-<not resolved>}"
printf '  ECR_REGISTRY  %s\n' "${ECR_REGISTRY:-<not resolved>}"
printf '  OIDC          %s\n' "${OIDC:-<cluster does not exist yet — normal before Phase 8>}"
printf '  BUCKET        %s\n' "${BUCKET:-<not created yet — set in Phase 10>}"
printf '\n'
printf 'After creating the S3 bucket, record it so it survives a new shell:\n'
printf '  echo "$BUCKET" > %s\n' "${BUCKET_FILE}"
