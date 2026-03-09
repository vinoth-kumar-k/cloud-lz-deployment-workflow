#!/usr/bin/env bash
# -----------------------------------------------------------
# validate-prereqs.sh
#
# Checks that all required tools and configuration are present
# in the CI environment before running any deployment.
# Runs in GitHub Actions workflows to validate runner readiness.
#
# Usage:
#   ./scripts/validate-prereqs.sh
#
# Exit code 0 = all checks passed.
# Exit code 1 = one or more checks failed.
# -----------------------------------------------------------
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass()  { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++));  }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++));    }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; ((WARN++)); }
header(){ echo -e "\n── $1 ──────────────────────────────────────────────────"; }

# ── Required tool versions ──────────────────────────────────
MIN_TERRAFORM="1.9"
MIN_ALIYUN_CLI="3.0"

check_command() {
  local cmd=$1 label=${2:-$1}
  if command -v "$cmd" &>/dev/null; then
    pass "$label found at $(command -v "$cmd")"
    return 0
  else
    fail "$label not found in PATH"
    return 1
  fi
}

check_min_version() {
  local label=$1 actual=$2 minimum=$3
  if printf '%s\n%s\n' "$minimum" "$actual" | sort -V -C; then
    pass "$label version $actual >= $minimum"
  else
    fail "$label version $actual is below minimum $minimum"
  fi
}

# ── 1. Core Tools ────────────────────────────────────────────
header "Core Tools"

check_command "terraform" "Terraform"
if command -v terraform &>/dev/null; then
  TF_VER=$(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 || terraform version | head -1 | grep -oP '\d+\.\d+\.\d+')
  check_min_version "Terraform" "$TF_VER" "$MIN_TERRAFORM"
fi

check_command "aliyun" "Alibaba Cloud CLI (aliyun)"
if command -v aliyun &>/dev/null; then
  ALIYUN_VER=$(aliyun version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "unknown")
  if [[ "$ALIYUN_VER" != "unknown" ]]; then
    check_min_version "Alibaba Cloud CLI" "$ALIYUN_VER" "$MIN_ALIYUN_CLI"
  else
    warn "Could not determine Alibaba Cloud CLI version"
  fi
fi

check_command "curl"  "curl"
check_command "jq"    "jq"
check_command "git"   "git"
check_command "tar"   "tar"

# ── 2. GitHub Actions Runner ─────────────────────────────────
header "GitHub Actions Runner"

if [[ -n "${RUNNER_NAME:-}" ]]; then
  pass "Running inside GitHub Actions runner: $RUNNER_NAME"
  echo "   Labels : ${RUNNER_LABELS:-unknown}"
  echo "   OS     : ${RUNNER_OS:-unknown}"
else
  warn "Not running inside a GitHub Actions runner environment"
fi

# ── 3. Environment Variables ─────────────────────────────────
header "Required Environment Variables (CI context)"

REQUIRED_VARS=(
  "ALICLOUD_REGION"
)

OIDC_VARS=(
  "ALICLOUD_OIDC_PROVIDER_ARN"
  "ALICLOUD_ROLE_ARN"
)

for var in "${REQUIRED_VARS[@]}"; do
  if [[ -n "${!var:-}" ]]; then
    pass "$var is set"
  else
    warn "$var is not set (expected to be set via GitHub Actions vars)"
  fi
done

for var in "${OIDC_VARS[@]}"; do
  if [[ -n "${!var:-}" ]]; then
    pass "$var is set"
  else
    warn "$var is not set (expected in OIDC-authenticated workflow steps)"
  fi
done

# ── 4. GitHub Actions OIDC (when inside a workflow) ──────────
header "GitHub Actions OIDC Token"

if [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  OIDC_TOKEN=$(curl -sS -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.aliyuncs.com" | jq -r '.value // empty')
  if [[ -n "$OIDC_TOKEN" ]]; then
    pass "Successfully fetched GitHub OIDC token (audience: sts.aliyuncs.com)"
    # Decode the payload (middle part) to show claims
    PAYLOAD=$(echo "$OIDC_TOKEN" | cut -d'.' -f2 | base64 --decode 2>/dev/null || true)
    if [[ -n "$PAYLOAD" ]]; then
      echo "   sub: $(echo "$PAYLOAD" | jq -r '.sub // "?"')"
      echo "   iss: $(echo "$PAYLOAD" | jq -r '.iss // "?"')"
      echo "   aud: $(echo "$PAYLOAD" | jq -r '.aud // "?"')"
    fi
  else
    fail "Failed to fetch GitHub OIDC token"
  fi
else
  warn "Not running in a GitHub Actions OIDC-enabled context (id-token: write permission required)"
fi

# ── Summary ──────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Results: ${GREEN}${PASS} passed${NC}  |  ${YELLOW}${WARN} warnings${NC}  |  ${RED}${FAIL} failed${NC}"
echo "═══════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
  echo -e "${RED}Prerequisites not met. Fix the failures above before proceeding.${NC}"
  exit 1
else
  echo -e "${GREEN}All required prerequisites met.${NC}"
  exit 0
fi
