#!/usr/bin/env bash
# =============================================================================
# Build (and optionally push) all three images with a shared tag.
#
# A single tag across the three components is what makes "which build is
# running?" answerable and a rollback a one-value change.
#
#   ./scripts/build-images.sh
#   ./scripts/build-images.sh --tag v1.2.3
#   ./scripts/build-images.sh --registry 123456789012.dkr.ecr.ap-south-1.amazonaws.com --push
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

REGISTRY=""
NAMESPACE="ai-interview-platform"
PUSH=false
# Default tag is traceable rather than `latest`: a mutable tag makes it
# impossible to say what is deployed.
TAG="$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"

info()  { printf '\033[0;34m[+]\033[0m %s\n' "$*"; }
error() { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--tag)      TAG="$2"; shift 2 ;;
        -r|--registry) REGISTRY="${2%/}"; shift 2 ;;
        -p|--push)     PUSH=true; shift ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "${PUSH}" = true ] && [ -z "${REGISTRY}" ]; then
    error "--push requires --registry"
    exit 1
fi

# component:context
COMPONENTS=(
    "middleware:middleware"
    "ai-service:backend"
    "frontend:frontend"
)

image_name() {
    local component="$1"
    if [ -n "${REGISTRY}" ]; then
        printf '%s/%s/%s' "${REGISTRY}" "${NAMESPACE}" "${component}"
    else
        printf '%s/%s' "${NAMESPACE}" "${component}"
    fi
}

info "Tag: ${TAG}"
[ -n "${REGISTRY}" ] && info "Registry: ${REGISTRY}"

for entry in "${COMPONENTS[@]}"; do
    component="${entry%%:*}"
    context="${entry##*:}"
    image="$(image_name "${component}")"

    info "Building ${component} from ./${context}"
    docker build \
        --tag "${image}:${TAG}" \
        --tag "${image}:latest" \
        --label "org.opencontainers.image.revision=$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
        --label "org.opencontainers.image.version=${TAG}" \
        --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "./${context}"
done

if [ "${PUSH}" = true ]; then
    # ECR requires a login before push. This uses the ambient credential chain
    # (SSO profile or assumed role); no access key is involved.
    if echo "${REGISTRY}" | grep -q 'dkr\.ecr\.'; then
        region="$(echo "${REGISTRY}" | sed -n 's/.*dkr\.ecr\.\([a-z0-9-]*\)\.amazonaws\.com.*/\1/p')"
        info "Authenticating to ECR in ${region}"
        aws ecr get-login-password --region "${region}" \
            | docker login --username AWS --password-stdin "${REGISTRY}"
    fi

    for entry in "${COMPONENTS[@]}"; do
        component="${entry%%:*}"
        image="$(image_name "${component}")"
        info "Pushing ${image}:${TAG}"
        docker push "${image}:${TAG}"
    done
fi

info "Done."
printf '\nDeploy this build:\n\n'
printf '  # one chart per service. aws.roleArn comes from:
'
printf '  #   terraform output -raw middleware_role_arn | ai_service_role_arn

'
for svc in frontend middleware ai-service; do
    printf '  helm upgrade --install %s ./helm/%s -n ai-interview \
' "${svc}" "${svc}"
    [ -n "${REGISTRY}" ] && printf '    --set imageRegistry=%s \
' "${REGISTRY}"
    printf '    --set imageTag=%s
' "${TAG}"
done
printf '
'
