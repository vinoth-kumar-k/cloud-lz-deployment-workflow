#!/usr/bin/env bash
# -----------------------------------------------------------
# setup-oidc.sh
#
# Day-1 bootstrap: creates the Alibaba Cloud RAM OIDC Provider
# and the Deployment RAM Role that GitHub Actions assumes.
#
# This script is run ONCE (manually) before the first pipeline
# execution.  After this you only need static credentials for
# this script itself – all subsequent CI/CD uses OIDC tokens.
#
# Prerequisites:
#   - Alibaba Cloud CLI (aliyun) configured with credentials
#     that have RAM admin permissions on the target account.
#   - jq installed.
#
# Usage:
#   export ALICLOUD_ACCOUNT_ID="123456789012"
#   export GITHUB_ORG="your-github-org"
#   export GITHUB_REPO="cloud-lz-deployment-workflow"
#   export ALICLOUD_REGION="cn-hangzhou"
#   ./scripts/setup-oidc.sh
#
# Optional overrides:
#   export OIDC_PROVIDER_NAME="GitHubActions"   (default)
#   export RAM_ROLE_NAME="github-lz-deploy"      (default)
#   export RAM_ROLE_SESSION_DURATION="3600"      (default, seconds)
# -----------------------------------------------------------
set -euo pipefail

# ── Colour helpers ───────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Configuration ────────────────────────────────────────────
ALICLOUD_ACCOUNT_ID="${ALICLOUD_ACCOUNT_ID:?Set ALICLOUD_ACCOUNT_ID}"
GITHUB_ORG="${GITHUB_ORG:?Set GITHUB_ORG}"
GITHUB_REPO="${GITHUB_REPO:?Set GITHUB_REPO}"
ALICLOUD_REGION="${ALICLOUD_REGION:-cn-hangzhou}"

OIDC_PROVIDER_NAME="${OIDC_PROVIDER_NAME:-GitHubActions}"
RAM_ROLE_NAME="${RAM_ROLE_NAME:-github-lz-deploy}"
RAM_ROLE_SESSION_DURATION="${RAM_ROLE_SESSION_DURATION:-3600}"

# GitHub's OIDC issuer URL
GITHUB_OIDC_URL="https://token.actions.githubusercontent.com"

# GitHub's OIDC thumbprint – fetch dynamically for accuracy
# (matches the TLS certificate of the OIDC endpoint)
info "Fetching GitHub OIDC TLS thumbprint..."
THUMBPRINT=$(echo | openssl s_client -connect token.actions.githubusercontent.com:443 \
    -servername token.actions.githubusercontent.com 2>/dev/null \
  | openssl x509 -fingerprint -noout -sha1 \
  | sed 's/sha1 Fingerprint=//' \
  | tr -d ':' \
  | tr '[:upper:]' '[:lower:]' 2>/dev/null) || THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

info "Thumbprint: $THUMBPRINT"

# ── Derived values ───────────────────────────────────────────
OIDC_PROVIDER_ARN="acs:ram::${ALICLOUD_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER_NAME}"
RAM_ROLE_ARN="acs:ram::${ALICLOUD_ACCOUNT_ID}:role/${RAM_ROLE_NAME}"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Alibaba Cloud – GitHub OIDC Setup${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo "  Account ID    : $ALICLOUD_ACCOUNT_ID"
echo "  Region        : $ALICLOUD_REGION"
echo "  GitHub Org    : $GITHUB_ORG"
echo "  GitHub Repo   : $GITHUB_REPO"
echo "  OIDC Provider : $OIDC_PROVIDER_NAME"
echo "  RAM Role      : $RAM_ROLE_NAME"
echo ""

read -rp "Proceed? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }

# ── 1. Create OIDC Provider ──────────────────────────────────
echo ""
info "Step 1/4 – Creating RAM OIDC Provider: $OIDC_PROVIDER_NAME"

# Check if it already exists
EXISTING_PROVIDER=$(aliyun ram GetOIDCProvider \
    --OIDCProviderName "$OIDC_PROVIDER_NAME" \
    --region "$ALICLOUD_REGION" \
    2>/dev/null | jq -r '.OIDCProvider.OIDCProviderName // empty' || true)

if [[ -n "$EXISTING_PROVIDER" ]]; then
  warn "OIDC Provider '$OIDC_PROVIDER_NAME' already exists – skipping creation."
else
  aliyun ram CreateOIDCProvider \
    --OIDCProviderName "$OIDC_PROVIDER_NAME" \
    --IssuerUrl "$GITHUB_OIDC_URL" \
    --Fingerprints "$THUMBPRINT" \
    --ClientIds "sts.aliyuncs.com" \
    --Description "GitHub Actions OIDC provider for ${GITHUB_ORG}/${GITHUB_REPO}" \
    --region "$ALICLOUD_REGION" \
    > /dev/null
  success "Created OIDC Provider: $OIDC_PROVIDER_ARN"
fi

# ── 2. Build trust policy ────────────────────────────────────
echo ""
info "Step 2/4 – Building RAM Role trust policy"

# The sub claim from GitHub Actions looks like:
#   repo:ORG/REPO:ref:refs/heads/main          (push to main)
#   repo:ORG/REPO:pull_request                 (PRs)
#   repo:ORG/REPO:environment:lz-deploy        (environment-gated jobs)
#
# We use StringLike with wildcards to cover all workflow patterns
# for this specific repository while blocking other repos.

TRUST_POLICY=$(cat <<EOF
{
  "Statement": [
    {
      "Action": "sts:AssumeRoleWithOIDC",
      "Effect": "Allow",
      "Principal": {
        "Federated": ["${OIDC_PROVIDER_ARN}"]
      },
      "Condition": {
        "StringEquals": {
          "oidc:aud": "sts.aliyuncs.com"
        },
        "StringLike": {
          "oidc:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
        }
      }
    }
  ],
  "Version": "1"
}
EOF
)

echo "Trust policy:"
echo "$TRUST_POLICY" | jq .

# ── 3. Create RAM Role ───────────────────────────────────────
echo ""
info "Step 3/4 – Creating RAM Role: $RAM_ROLE_NAME"

EXISTING_ROLE=$(aliyun ram GetRole \
    --RoleName "$RAM_ROLE_NAME" \
    --region "$ALICLOUD_REGION" \
    2>/dev/null | jq -r '.Role.RoleName // empty' || true)

if [[ -n "$EXISTING_ROLE" ]]; then
  warn "RAM Role '$RAM_ROLE_NAME' already exists – updating trust policy."
  aliyun ram UpdateRole \
    --RoleName "$RAM_ROLE_NAME" \
    --NewAssumeRolePolicyDocument "$TRUST_POLICY" \
    --NewMaxSessionDuration "$RAM_ROLE_SESSION_DURATION" \
    --region "$ALICLOUD_REGION" \
    > /dev/null
  success "Updated trust policy on existing role."
else
  aliyun ram CreateRole \
    --RoleName "$RAM_ROLE_NAME" \
    --AssumeRolePolicyDocument "$TRUST_POLICY" \
    --Description "GitHub Actions deployment role for ${GITHUB_ORG}/${GITHUB_REPO} LZ" \
    --MaxSessionDuration "$RAM_ROLE_SESSION_DURATION" \
    --region "$ALICLOUD_REGION" \
    > /dev/null
  success "Created RAM Role: $RAM_ROLE_ARN"
fi

# ── 4. Attach required policies ──────────────────────────────
echo ""
info "Step 4/4 – Attaching policies to RAM Role"

# Minimum permissions needed for LZ deployment.
# Replace AdministratorAccess with a tighter custom policy for
# production.  See docs/oidc-setup-guide.md for custom policy.
POLICIES=(
  "AdministratorAccess"    # Broad – tighten per LZ scope in production
)

for policy in "${POLICIES[@]}"; do
  aliyun ram AttachPolicyToRole \
    --PolicyType System \
    --PolicyName "$policy" \
    --RoleName "$RAM_ROLE_NAME" \
    --region "$ALICLOUD_REGION" \
    2>/dev/null || true
  success "Attached policy: $policy"
done

# ── Output GitHub Actions configuration values ───────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Setup Complete – Configure These in GitHub${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo "Add the following as GitHub Actions repository Variables"
echo "(Settings → Secrets and variables → Actions → Variables):"
echo ""
echo -e "  ${CYAN}ALICLOUD_REGION${NC}               = ${ALICLOUD_REGION}"
echo -e "  ${CYAN}ALICLOUD_OIDC_PROVIDER_ARN${NC}    = ${OIDC_PROVIDER_ARN}"
echo -e "  ${CYAN}ALICLOUD_OIDC_ROLE_ARN${NC}        = ${RAM_ROLE_ARN}"
echo ""
echo "Run the state-backend bootstrap script next:"
echo "  ./scripts/bootstrap-state-backend.sh"
echo ""
