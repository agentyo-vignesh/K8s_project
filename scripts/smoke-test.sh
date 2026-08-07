#!/usr/bin/env bash
# =============================================================================
# End-to-end smoke test against a running stack.
#
# Exercises the full request path the architecture describes:
#   browser -> Spring Boot -> FastAPI -> PostgreSQL
#
# Every assertion is on an observable HTTP response, so this passes or fails for
# the same reasons a user would succeed or fail. Intended for local verification
# and as a post-deploy check against a port-forwarded cluster.
#
#   ./scripts/smoke-test.sh
#   API_URL=http://localhost:18080 ./scripts/smoke-test.sh
# =============================================================================
set -euo pipefail

readonly API_URL="${API_URL:-http://localhost:8080}"
readonly ADMIN_EMAIL="${ADMIN_EMAIL:-admin@aiinterview.local}"
readonly ADMIN_PASSWORD="${ADMIN_PASSWORD:-Admin@12345}"

PASSED=0
FAILED=0

pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }
step() { printf '\n\033[0;34m==>\033[0m %s\n' "$*"; }

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "Required tool not found: $1" >&2; exit 1; }
}
require curl
require jq

# Asserts the HTTP status of a request, printing the body when it does not match.
expect_status() {
    local description="$1" expected="$2" actual="$3" body="${4:-}"
    if [ "${actual}" = "${expected}" ]; then
        pass "${description} (${actual})"
    else
        fail "${description}: expected ${expected}, got ${actual}"
        [ -n "${body}" ] && printf '       %s\n' "$(echo "${body}" | head -c 300)"
    fi
}

# -----------------------------------------------------------------------------
step "Health"
# -----------------------------------------------------------------------------
status=$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}/actuator/health/readiness")
expect_status "middleware readiness" 200 "${status}"

status=$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}/actuator/prometheus")
expect_status "prometheus metrics exposed" 200 "${status}"

# The AI service is reported as a component of aggregate health but deliberately
# excluded from readiness, so this is informational rather than an assertion.
ai_status=$(curl -s "${API_URL}/actuator/health" | jq -r '.components.aiService.status // "UNKNOWN"' 2>/dev/null || echo UNKNOWN)
printf '       AI service health: %s\n' "${ai_status}"

# -----------------------------------------------------------------------------
step "Authentication"
# -----------------------------------------------------------------------------
login_response=$(curl -s -w '\n%{http_code}' -X POST "${API_URL}/api/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\"}")
login_body=$(echo "${login_response}" | sed '$d')
login_status=$(echo "${login_response}" | tail -n1)
expect_status "login with seed admin" 200 "${login_status}" "${login_body}"

TOKEN=$(echo "${login_body}" | jq -r '.accessToken // empty')
REFRESH=$(echo "${login_body}" | jq -r '.refreshToken // empty')
if [ -z "${TOKEN}" ]; then
    fail "no access token returned; cannot continue"
    exit 1
fi
pass "access token issued"

auth=(-H "Authorization: Bearer ${TOKEN}")

# Authorization is not optional: an unauthenticated call must be refused.
status=$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}/api/v1/candidates")
expect_status "unauthenticated request rejected" 401 "${status}"

status=$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" "${API_URL}/api/v1/auth/me")
expect_status "authenticated /auth/me" 200 "${status}"

# -----------------------------------------------------------------------------
step "Dashboard"
# -----------------------------------------------------------------------------
dashboard=$(curl -s "${auth[@]}" "${API_URL}/api/v1/dashboard/summary")
total_candidates=$(echo "${dashboard}" | jq -r '.totalCandidates // -1')
if [ "${total_candidates}" -ge 0 ] 2>/dev/null; then
    pass "dashboard summary (candidates=${total_candidates}, interviews=$(echo "${dashboard}" | jq -r '.totalInterviews'))"
else
    fail "dashboard summary did not return counts"
fi

# -----------------------------------------------------------------------------
step "Candidate lifecycle"
# -----------------------------------------------------------------------------
unique="smoke-$(date +%s)-$$"
create_response=$(curl -s -w '\n%{http_code}' -X POST "${API_URL}/api/v1/candidates" \
    "${auth[@]}" -H 'Content-Type: application/json' \
    -d "{
        \"firstName\": \"Smoke\",
        \"lastName\": \"Test\",
        \"email\": \"${unique}@example.com\",
        \"yearsOfExperience\": 5.0,
        \"primarySkill\": \"Kubernetes\"
    }")
create_body=$(echo "${create_response}" | sed '$d')
create_status=$(echo "${create_response}" | tail -n1)
expect_status "create candidate" 201 "${create_status}" "${create_body}"

CANDIDATE_ID=$(echo "${create_body}" | jq -r '.id // empty')

if [ -n "${CANDIDATE_ID}" ]; then
    # The unique index must reject the duplicate, and the service must translate
    # that into a 409 rather than leaking a constraint violation as a 500.
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${API_URL}/api/v1/candidates" \
        "${auth[@]}" -H 'Content-Type: application/json' \
        -d "{\"firstName\":\"Dup\",\"lastName\":\"Test\",\"email\":\"${unique}@example.com\",\"yearsOfExperience\":1.0,\"primarySkill\":\"Java\"}")
    expect_status "duplicate email rejected" 409 "${status}"

    # Validation must produce 400, not 500.
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${API_URL}/api/v1/candidates" \
        "${auth[@]}" -H 'Content-Type: application/json' \
        -d '{"firstName":"","lastName":"","email":"not-an-email","yearsOfExperience":-5,"primarySkill":""}')
    expect_status "invalid payload rejected" 400 "${status}"

    status=$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" "${API_URL}/api/v1/candidates/${CANDIDATE_ID}")
    expect_status "fetch candidate by id" 200 "${status}"

    found=$(curl -s "${auth[@]}" "${API_URL}/api/v1/candidates?search=${unique}" | jq -r '.totalElements // 0')
    if [ "${found}" -ge 1 ] 2>/dev/null; then
        pass "search finds the new candidate"
    else
        fail "search did not find the new candidate"
    fi
fi

# -----------------------------------------------------------------------------
step "Interview and AI question generation"
# -----------------------------------------------------------------------------
if [ -n "${CANDIDATE_ID}" ]; then
    scheduled_at=$(date -u -d '+2 days' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -v+2d '+%Y-%m-%dT%H:%M:%SZ')

    interview_response=$(curl -s -w '\n%{http_code}' -X POST "${API_URL}/api/v1/interviews" \
        "${auth[@]}" -H 'Content-Type: application/json' \
        -d "{
            \"candidateId\": \"${CANDIDATE_ID}\",
            \"title\": \"Smoke Test Interview\",
            \"roleTitle\": \"Senior DevOps Engineer\",
            \"experienceLevel\": \"SENIOR\",
            \"scheduledAt\": \"${scheduled_at}\",
            \"focusSkills\": [\"Kubernetes\", \"Helm\"]
        }")
    interview_body=$(echo "${interview_response}" | sed '$d')
    interview_status=$(echo "${interview_response}" | tail -n1)
    expect_status "create interview" 201 "${interview_status}" "${interview_body}"

    INTERVIEW_ID=$(echo "${interview_body}" | jq -r '.id // empty')

    if [ -n "${INTERVIEW_ID}" ]; then
        # This is the call that proves the whole chain: Spring Boot reaches
        # FastAPI, which persists to PostgreSQL and returns questions.
        gen_response=$(curl -s -w '\n%{http_code}' -X POST \
            "${API_URL}/api/v1/interviews/${INTERVIEW_ID}/questions/generate" \
            "${auth[@]}" -H 'Content-Type: application/json' \
            -d '{"questionCount": 3}')
        gen_body=$(echo "${gen_response}" | sed '$d')
        gen_status=$(echo "${gen_response}" | tail -n1)
        expect_status "generate questions via the AI service" 200 "${gen_status}" "${gen_body}"

        # `jq length` on an object counts its keys, so an error body would score as a
        # pass. Assert the payload is an array before counting it.
        count=$(echo "${gen_body}" | jq 'if type == "array" then length else -1 end' 2>/dev/null || echo -1)
        if [ "${count}" -ge 1 ] 2>/dev/null; then
            pass "AI returned ${count} question(s)"
        else
            fail "AI returned no usable question array"
        fi

        # Submitting a result must also close the interview.
        result_status=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
            "${API_URL}/api/v1/interviews/${INTERVIEW_ID}/result" \
            "${auth[@]}" -H 'Content-Type: application/json' \
            -d '{
                "technicalScore": 8.0,
                "communicationScore": 7.0,
                "problemSolvingScore": 9.0,
                "recommendation": "HIRE",
                "feedback": "Automated smoke test submission covering the result path."
            }')
        expect_status "submit interview result" 200 "${result_status}"

        state=$(curl -s "${auth[@]}" "${API_URL}/api/v1/interviews/${INTERVIEW_ID}" | jq -r '.status')
        if [ "${state}" = "COMPLETED" ]; then
            pass "submitting a result moved the interview to COMPLETED"
        else
            fail "interview status is ${state}, expected COMPLETED"
        fi
    fi
fi

# -----------------------------------------------------------------------------
step "Session teardown"
# -----------------------------------------------------------------------------
if [ -n "${CANDIDATE_ID}" ]; then
    status=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
        "${auth[@]}" "${API_URL}/api/v1/candidates/${CANDIDATE_ID}")
    expect_status "delete the smoke-test candidate" 204 "${status}"
fi

status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${API_URL}/api/v1/auth/logout" \
    "${auth[@]}" -H 'Content-Type: application/json' \
    -d "{\"refreshToken\":\"${REFRESH}\"}")
expect_status "logout" 204 "${status}"

# Revocation must take effect immediately, not at token expiry.
status=$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" "${API_URL}/api/v1/auth/me")
expect_status "revoked token is rejected" 401 "${status}"

# -----------------------------------------------------------------------------
printf '\n============================================\n'
printf '  passed: %d   failed: %d\n' "${PASSED}" "${FAILED}"
printf '============================================\n'

[ "${FAILED}" -eq 0 ] || exit 1
