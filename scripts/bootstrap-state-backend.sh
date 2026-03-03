#!/usr/bin/env bash
# -----------------------------------------------------------
# bootstrap-state-backend.sh
#
# Creates the Alibaba Cloud OSS bucket and TableStore instance
# used as the Terraform remote state backend.
#
# Run this ONCE before the first pipeline execution.
# Requires the Alibaba Cloud CLI configured with credentials
# that have OSS and TableStore permissions.
#
# Usage:
#   export ALICLOUD_ACCOUNT_ID="123456789012"
#   export ALICLOUD_REGION="cn-hangzhou"
#   export STATE_BUCKET_NAME="acme-lz-tfstate"
#   export TABLESTORE_INSTANCE="acme-lz-tflock"
#   export TABLESTORE_TABLE="terraform-lock"
#   ./scripts/bootstrap-state-backend.sh
# -----------------------------------------------------------
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Configuration ────────────────────────────────────────────
ALICLOUD_ACCOUNT_ID="${ALICLOUD_ACCOUNT_ID:?Set ALICLOUD_ACCOUNT_ID}"
ALICLOUD_REGION="${ALICLOUD_REGION:-cn-hangzhou}"
STATE_BUCKET_NAME="${STATE_BUCKET_NAME:-acme-lz-tfstate}"
TABLESTORE_INSTANCE="${TABLESTORE_INSTANCE:-acme-lz-tflock}"
TABLESTORE_TABLE="${TABLESTORE_TABLE:-terraform-lock}"

OSS_ENDPOINT="oss-${ALICLOUD_REGION}.aliyuncs.com"
TABLESTORE_ENDPOINT="https://${TABLESTORE_INSTANCE}.${ALICLOUD_REGION}.ots.aliyuncs.com"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Terraform State Backend Bootstrap${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo "  Region              : $ALICLOUD_REGION"
echo "  OSS Bucket          : $STATE_BUCKET_NAME"
echo "  TableStore Instance : $TABLESTORE_INSTANCE"
echo "  TableStore Table    : $TABLESTORE_TABLE"
echo ""
warn "This script will create billable resources in your Alibaba Cloud account."
read -rp "Proceed? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }

# ── 1. Create OSS Bucket ─────────────────────────────────────
echo ""
info "Step 1/4 – Creating OSS state bucket: $STATE_BUCKET_NAME"

# Check if bucket exists
BUCKET_EXISTS=$(aliyun oss ls 2>/dev/null | grep -c "oss://${STATE_BUCKET_NAME}" || true)

if [[ "$BUCKET_EXISTS" -gt 0 ]]; then
  warn "OSS bucket '$STATE_BUCKET_NAME' already exists – skipping creation."
else
  aliyun oss mb "oss://${STATE_BUCKET_NAME}" \
    --region "$ALICLOUD_REGION" \
    --acl private
  success "Created OSS bucket: oss://${STATE_BUCKET_NAME}"
fi

# ── 2. Enable OSS bucket versioning ─────────────────────────
echo ""
info "Step 2/4 – Enabling versioning on state bucket (allows state recovery)"

aliyun oss bucket-versioning \
  --method put "oss://${STATE_BUCKET_NAME}" \
  --status Enabled 2>/dev/null || \
  warn "Could not enable versioning – check permissions or enable manually."

# Enable server-side encryption (AES256)
aliyun oss bucket-encryption \
  --method put "oss://${STATE_BUCKET_NAME}" \
  --sse-algorithm AES256 2>/dev/null || \
  warn "Could not set encryption – check permissions or enable manually."

success "Versioning and encryption configured."

# ── 3. Create TableStore instance for state locking ──────────
echo ""
info "Step 3/4 – Creating TableStore instance: $TABLESTORE_INSTANCE"

INSTANCE_EXISTS=$(aliyun ots ListInstance \
    --region "$ALICLOUD_REGION" \
    2>/dev/null | jq -r '.InstanceInfos.InstanceInfo[]?.InstanceName // empty' | grep -c "^${TABLESTORE_INSTANCE}$" || true)

if [[ "$INSTANCE_EXISTS" -gt 0 ]]; then
  warn "TableStore instance '$TABLESTORE_INSTANCE' already exists – skipping."
else
  aliyun ots InsertInstance \
    --InstanceName "$TABLESTORE_INSTANCE" \
    --Description "Terraform state lock for LZ deployment" \
    --region "$ALICLOUD_REGION" \
    > /dev/null
  success "Created TableStore instance: $TABLESTORE_INSTANCE"
  info "Waiting 30 seconds for instance to become active..."
  sleep 30
fi

# ── 4. Create lock table in TableStore ───────────────────────
echo ""
info "Step 4/4 – Creating lock table: $TABLESTORE_TABLE"

TABLE_EXISTS=$(aliyun ots ListTable \
    --InstanceName "$TABLESTORE_INSTANCE" \
    --endpoint "$TABLESTORE_ENDPOINT" \
    2>/dev/null | jq -r '.TableNames.TableName[] // empty' | grep -c "^${TABLESTORE_TABLE}$" || true)

if [[ "$TABLE_EXISTS" -gt 0 ]]; then
  warn "Table '$TABLESTORE_TABLE' already exists – skipping."
else
  # The table schema Terraform expects for OTS locking:
  # Primary key: LockID (string)
  aliyun ots CreateTable \
    --InstanceName "$TABLESTORE_INSTANCE" \
    --endpoint "$TABLESTORE_ENDPOINT" \
    --TableMeta.TableName "$TABLESTORE_TABLE" \
    --TableMeta.SchemaEntry.1.Name LockID \
    --TableMeta.SchemaEntry.1.Type STRING \
    --TableMeta.SchemaEntry.1.Option PRIMARY_KEY \
    --TableOptions.MaxVersions 1 \
    --TableOptions.TimeToLive -1 \
    > /dev/null
  success "Created TableStore table: $TABLESTORE_TABLE"
fi

# ── Output GitHub Actions configuration values ───────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Bootstrap Complete – Configure These in GitHub${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo "Add the following as GitHub Actions repository Variables"
echo "(Settings → Secrets and variables → Actions → Variables):"
echo ""
echo -e "  ${CYAN}TF_STATE_BUCKET${NC}                = ${STATE_BUCKET_NAME}"
echo -e "  ${CYAN}TF_LOCK_TABLESTORE_ENDPOINT${NC}    = ${TABLESTORE_ENDPOINT}"
echo -e "  ${CYAN}TF_LOCK_TABLE${NC}                  = ${TABLESTORE_TABLE}"
echo ""
echo "Next step: trigger the deploy workflow from GitHub Actions."
echo "  gh workflow run lz-deploy.yml --field environment=landing-zone"
echo ""
