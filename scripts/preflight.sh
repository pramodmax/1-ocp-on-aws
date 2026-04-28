#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✔${NC}  $1"; }
fail() { echo -e "  ${RED}✘${NC}  $1"; FAILED=1; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }

FAILED=0

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   Pre-flight Checks                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ─── Required Tools ───────────────────────────────────────────────────────────

echo "  Tools"
for tool in openshift-install aws oc jq; do
  if command -v "$tool" &>/dev/null; then
    VERSION=$(${tool} version 2>/dev/null | head -1 || echo "unknown")
    pass "$tool found — $VERSION"
  else
    fail "$tool not found. Install it before proceeding."
  fi
done

echo ""
echo "  AWS Credentials"

# ─── AWS Auth ─────────────────────────────────────────────────────────────────

if aws sts get-caller-identity &>/dev/null; then
  IDENTITY=$(aws sts get-caller-identity --output text --query '[Account, Arn]' 2>/dev/null)
  pass "AWS credentials valid — $IDENTITY"
else
  fail "AWS credentials not configured or invalid. Run: aws configure"
fi

# ─── Route53 Hosted Zone ──────────────────────────────────────────────────────

echo ""
echo "  DNS"

ZONE_COUNT=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='${BASE_DOMAIN}.']" --output json 2>/dev/null | jq length)
if [ "$ZONE_COUNT" -gt "0" ]; then
  pass "Route53 public hosted zone found for ${BASE_DOMAIN}"
else
  fail "No Route53 public hosted zone found for ${BASE_DOMAIN}. Create one before installing."
fi

# ─── AWS Service Quotas ───────────────────────────────────────────────────────

echo ""
echo "  AWS Region"

if aws ec2 describe-regions --region-names "${AWS_REGION}" --output json &>/dev/null; then
  pass "Region ${AWS_REGION} is accessible"
else
  fail "Region ${AWS_REGION} is not accessible."
fi

# ─── Cluster Already Installed? ───────────────────────────────────────────────

echo ""
echo "  Cluster State"

if [ -f "${INSTALL_DIR}/.install-complete" ]; then
  warn "Cluster ${CLUSTER_NAME} appears already installed. terraform apply will be a no-op."
elif [ -d "${INSTALL_DIR}/auth" ]; then
  warn "Partial installation found in ${INSTALL_DIR}. Consider running destroy first."
else
  pass "No existing installation found. Clean install."
fi

# ─── Instance Type Availability ───────────────────────────────────────────────

echo ""
echo "  Instance Types"

for TYPE in "${MASTER_TYPE}" "${WORKER_TYPE}"; do
  AVAILABLE=$(aws ec2 describe-instance-type-offerings \
    --location-type availability-zone \
    --filters Name=instance-type,Values="${TYPE}" \
    --region "${AWS_REGION}" \
    --output json 2>/dev/null | jq '.InstanceTypeOfferings | length')
  if [ "$AVAILABLE" -gt "0" ]; then
    pass "${TYPE} available in ${AWS_REGION}"
  else
    fail "${TYPE} not available in ${AWS_REGION}. Choose a different instance type."
  fi
done

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
if [ "$FAILED" -eq "1" ]; then
  echo -e "  ${RED}Pre-flight checks failed. Fix the issues above before installing.${NC}"
  echo ""
  exit 1
else
  echo -e "  ${GREEN}All pre-flight checks passed. Starting installation...${NC}"
  echo ""
fi
