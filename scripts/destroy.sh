#!/usr/bin/env bash
# Full OpenShift cluster teardown.
#
# Phase 1 — openshift-install destroy cluster  (handles the bulk of cleanup)
# Phase 2 — AWS resource audit & orphan removal (catches anything the installer missed)
# Phase 3 — Local directory and Terraform state cleanup
#
# Usage:
#   ./scripts/destroy.sh <cluster-name>
#   ./scripts/destroy.sh <cluster-name> --profile my-aws-profile
#   ./scripts/destroy.sh <cluster-name> --region us-west-2
#   ./scripts/destroy.sh <cluster-name> --skip-installer   # jump straight to orphan cleanup

set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
fail() { echo -e "  ${RED}✘${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }
step() { echo -e "\n${BOLD}  $1${NC}"; }

# ─── Args ─────────────────────────────────────────────────────────────────────

CLUSTER_NAME="${1:-}"
PROFILE=""
REGION=""
SKIP_INSTALLER=false

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "Usage: $0 <cluster-name> [--profile <aws-profile>] [--region <aws-region>] [--skip-installer]"
  exit 1
fi
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)        PROFILE="$2";      shift 2 ;;
    --region)         REGION="$2";       shift 2 ;;
    --skip-installer) SKIP_INSTALLER=true; shift  ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_DIR="${ROOT_DIR}/clusters/${CLUSTER_NAME}"

AWS_ARGS=()
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")
[[ -n "$REGION"  ]] && AWS_ARGS+=(--region  "$REGION")

# Auto-detect region from install metadata if not provided
if [[ -z "$REGION" ]] && [[ -f "${INSTALL_DIR}/metadata.json" ]]; then
  REGION=$(jq -r '.aws.region // empty' "${INSTALL_DIR}/metadata.json" 2>/dev/null || true)
  [[ -n "$REGION" ]] && AWS_ARGS+=(--region "$REGION")
fi

# OCP tags resources with this key
CLUSTER_TAG_KEY="kubernetes.io/cluster/${CLUSTER_NAME}"

# ─── Header ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║            OpenShift Cluster Teardown                       ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
printf "${BOLD}║  Cluster : %-50s ║${NC}\n" "$CLUSTER_NAME"
printf "${BOLD}║  Dir     : %-50s ║${NC}\n" "$INSTALL_DIR"
[[ -n "$REGION"  ]] && printf "${BOLD}║  Region  : %-50s ║${NC}\n" "$REGION"
[[ -n "$PROFILE" ]] && printf "${BOLD}║  Profile : %-50s ║${NC}\n" "$PROFILE"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${RED}WARNING: This will permanently destroy the cluster and ALL its AWS resources.${NC}"
echo "  This action cannot be undone."
echo ""
read -r -p "  Type the cluster name to confirm: " CONFIRM
echo ""

if [[ "$CONFIRM" != "$CLUSTER_NAME" ]]; then
  echo "  Confirmation does not match. Aborting."
  exit 1
fi

TEARDOWN_START=$(date +%s)
RESOURCES_REMOVED=0
RESOURCES_FAILED=0

# ─── Helper: tag filter for aws CLI ───────────────────────────────────────────

tag_filter() {
  echo "Name=tag:${CLUSTER_TAG_KEY},Values=owned"
}

# ─── Helper: remove a resource with error handling ────────────────────────────

remove_resource() {
  local label="$1"; shift
  if "$@" &>/dev/null 2>&1; then
    ok "$label removed"
    ((RESOURCES_REMOVED++))
  else
    warn "$label — could not remove (may already be deleted)"
    ((RESOURCES_FAILED++))
  fi
}

# ─── PHASE 1: openshift-install destroy cluster ───────────────────────────────

if $SKIP_INSTALLER; then
  warn "Skipping openshift-install (--skip-installer flag set). Going straight to orphan cleanup."
elif [[ ! -d "$INSTALL_DIR" ]]; then
  warn "Install directory not found: $INSTALL_DIR"
  warn "Skipping openshift-install destroy — will proceed with AWS orphan cleanup."
else
  step "Phase 1 of 3 — openshift-install destroy cluster"
  echo ""
  info "This handles the bulk of resource cleanup (EC2, LBs, VPC, Route53, S3, IAM)."
  info "Log: ${INSTALL_DIR}/.openshift_install.log"
  echo ""

  if openshift-install destroy cluster \
    --dir="$INSTALL_DIR" \
    --log-level=info; then
    ok "openshift-install destroy completed"
  else
    warn "openshift-install destroy exited with errors. Proceeding to orphan cleanup."
  fi
fi

# ─── PHASE 2: Orphan resource cleanup ─────────────────────────────────────────

step "Phase 2 of 3 — Scanning for orphaned AWS resources"
echo ""
info "Tag filter: ${CLUSTER_TAG_KEY}=owned"
echo ""

# Verify AWS access
if ! aws sts get-caller-identity "${AWS_ARGS[@]}" &>/dev/null; then
  fail "Cannot reach AWS. Check credentials and region."
  exit 1
fi

# ── EC2 Instances ─────────────────────────────────────────────────────────────

step "  EC2 Instances"
INSTANCE_IDS=$(aws ec2 describe-instances "${AWS_ARGS[@]}" \
  --filters "$(tag_filter)" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text 2>/dev/null || true)

if [[ -n "$INSTANCE_IDS" ]]; then
  for ID in $INSTANCE_IDS; do
    remove_resource "EC2 instance $ID" \
      aws ec2 terminate-instances "${AWS_ARGS[@]}" --instance-ids "$ID"
  done
  info "Waiting for instances to terminate..."
  aws ec2 wait instance-terminated "${AWS_ARGS[@]}" \
    --instance-ids $INSTANCE_IDS 2>/dev/null || true
else
  ok "No orphaned EC2 instances found"
fi

# ── Load Balancers (ALB / NLB) ────────────────────────────────────────────────

step "  Load Balancers"
LB_ARNS=$(aws elbv2 describe-load-balancers "${AWS_ARGS[@]}" \
  --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true)

FOUND_LBS=0
for ARN in $LB_ARNS; do
  TAGS=$(aws elbv2 describe-tags "${AWS_ARGS[@]}" --resource-arns "$ARN" \
    --query "TagDescriptions[].Tags[?Key=='${CLUSTER_TAG_KEY}'].Value" \
    --output text 2>/dev/null || true)
  if [[ "$TAGS" == "owned" ]]; then
    remove_resource "Load balancer ${ARN##*/}" \
      aws elbv2 delete-load-balancer "${AWS_ARGS[@]}" --load-balancer-arn "$ARN"
    ((FOUND_LBS++))
  fi
done
[[ $FOUND_LBS -eq 0 ]] && ok "No orphaned load balancers found"

# ── Target Groups ─────────────────────────────────────────────────────────────

step "  Target Groups"
TG_ARNS=$(aws elbv2 describe-target-groups "${AWS_ARGS[@]}" \
  --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null || true)

FOUND_TGS=0
for ARN in $TG_ARNS; do
  TAGS=$(aws elbv2 describe-tags "${AWS_ARGS[@]}" --resource-arns "$ARN" \
    --query "TagDescriptions[].Tags[?Key=='${CLUSTER_TAG_KEY}'].Value" \
    --output text 2>/dev/null || true)
  if [[ "$TAGS" == "owned" ]]; then
    remove_resource "Target group ${ARN##*/}" \
      aws elbv2 delete-target-group "${AWS_ARGS[@]}" --target-group-arn "$ARN"
    ((FOUND_TGS++))
  fi
done
[[ $FOUND_TGS -eq 0 ]] && ok "No orphaned target groups found"

# ── Classic Load Balancers ────────────────────────────────────────────────────

step "  Classic Load Balancers"
CLASSIC_LBS=$(aws elb describe-load-balancers "${AWS_ARGS[@]}" \
  --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null || true)

FOUND_CLASSIC=0
for LB in $CLASSIC_LBS; do
  TAGS=$(aws elb describe-tags "${AWS_ARGS[@]}" --load-balancer-names "$LB" \
    --query "TagDescriptions[].Tags[?Key=='${CLUSTER_TAG_KEY}'].Value" \
    --output text 2>/dev/null || true)
  if [[ "$TAGS" == "owned" ]]; then
    remove_resource "Classic ELB $LB" \
      aws elb delete-load-balancer "${AWS_ARGS[@]}" --load-balancer-name "$LB"
    ((FOUND_CLASSIC++))
  fi
done
[[ $FOUND_CLASSIC -eq 0 ]] && ok "No orphaned classic load balancers found"

# ── S3 Buckets ────────────────────────────────────────────────────────────────

step "  S3 Buckets"
ALL_BUCKETS=$(aws s3api list-buckets "${AWS_ARGS[@]}" \
  --query 'Buckets[].Name' --output text 2>/dev/null || true)

FOUND_BUCKETS=0
for BUCKET in $ALL_BUCKETS; do
  if [[ "$BUCKET" == *"${CLUSTER_NAME}"* ]]; then
    info "Emptying bucket: $BUCKET"
    aws s3 rm "s3://${BUCKET}" --recursive "${AWS_ARGS[@]}" &>/dev/null || true
    # Remove versioned objects if versioning was enabled
    aws s3api delete-objects "${AWS_ARGS[@]}" --bucket "$BUCKET" \
      --delete "$(aws s3api list-object-versions "${AWS_ARGS[@]}" --bucket "$BUCKET" \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
        --output json 2>/dev/null)" &>/dev/null || true
    remove_resource "S3 bucket $BUCKET" \
      aws s3api delete-bucket "${AWS_ARGS[@]}" --bucket "$BUCKET"
    ((FOUND_BUCKETS++))
  fi
done
[[ $FOUND_BUCKETS -eq 0 ]] && ok "No orphaned S3 buckets found"

# ── NAT Gateways ──────────────────────────────────────────────────────────────

step "  NAT Gateways"
NAT_IDS=$(aws ec2 describe-nat-gateways "${AWS_ARGS[@]}" \
  --filter "$(tag_filter)" "Name=state,Values=available,pending" \
  --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)

if [[ -n "$NAT_IDS" ]]; then
  for ID in $NAT_IDS; do
    remove_resource "NAT gateway $ID" \
      aws ec2 delete-nat-gateway "${AWS_ARGS[@]}" --nat-gateway-id "$ID"
  done
  info "Waiting for NAT gateways to delete..."
  sleep 15
else
  ok "No orphaned NAT gateways found"
fi

# ── Elastic IPs ───────────────────────────────────────────────────────────────

step "  Elastic IPs"
EIP_ALLOCS=$(aws ec2 describe-addresses "${AWS_ARGS[@]}" \
  --filters "$(tag_filter)" \
  --query 'Addresses[].AllocationId' --output text 2>/dev/null || true)

if [[ -n "$EIP_ALLOCS" ]]; then
  for ID in $EIP_ALLOCS; do
    remove_resource "Elastic IP $ID" \
      aws ec2 release-address "${AWS_ARGS[@]}" --allocation-id "$ID"
  done
else
  ok "No orphaned Elastic IPs found"
fi

# ── Security Groups ───────────────────────────────────────────────────────────

step "  Security Groups"
SG_IDS=$(aws ec2 describe-security-groups "${AWS_ARGS[@]}" \
  --filters "$(tag_filter)" \
  --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true)

if [[ -n "$SG_IDS" ]]; then
  for ID in $SG_IDS; do
    # Revoke all ingress/egress rules first (prevent dependency errors)
    INGRESS=$(aws ec2 describe-security-groups "${AWS_ARGS[@]}" --group-ids "$ID" \
      --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null || echo "[]")
    EGRESS=$(aws ec2 describe-security-groups "${AWS_ARGS[@]}" --group-ids "$ID" \
      --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null || echo "[]")
    [[ "$INGRESS" != "[]" ]] && aws ec2 revoke-security-group-ingress "${AWS_ARGS[@]}" \
      --group-id "$ID" --ip-permissions "$INGRESS" &>/dev/null || true
    [[ "$EGRESS"  != "[]" ]] && aws ec2 revoke-security-group-egress "${AWS_ARGS[@]}" \
      --group-id "$ID" --ip-permissions "$EGRESS" &>/dev/null || true
    remove_resource "Security group $ID" \
      aws ec2 delete-security-group "${AWS_ARGS[@]}" --group-id "$ID"
  done
else
  ok "No orphaned security groups found"
fi

# ── VPC Endpoints ─────────────────────────────────────────────────────────────

step "  VPC Endpoints"
ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints "${AWS_ARGS[@]}" \
  --filters "$(tag_filter)" "Name=vpc-endpoint-state,Values=available,pending" \
  --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true)

if [[ -n "$ENDPOINT_IDS" ]]; then
  remove_resource "VPC endpoints" \
    aws ec2 delete-vpc-endpoints "${AWS_ARGS[@]}" --vpc-endpoint-ids $ENDPOINT_IDS
else
  ok "No orphaned VPC endpoints found"
fi

# ── Subnets ───────────────────────────────────────────────────────────────────

step "  Subnets"
SUBNET_IDS=$(aws ec2 describe-subnets "${AWS_ARGS[@]}" \
  --filters "$(tag_filter)" \
  --query 'Subnets[].SubnetId' --output text 2>/dev/null || true)

if [[ -n "$SUBNET_IDS" ]]; then
  for ID in $SUBNET_IDS; do
    remove_resource "Subnet $ID" \
      aws ec2 delete-subnet "${AWS_ARGS[@]}" --subnet-id "$ID"
  done
else
  ok "No orphaned subnets found"
fi

# ── Route Tables ──────────────────────────────────────────────────────────────

step "  Route Tables"
RT_IDS=$(aws ec2 describe-route-tables "${AWS_ARGS[@]}" \
  --filters "$(tag_filter)" \
  --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
  --output text 2>/dev/null || true)

if [[ -n "$RT_IDS" ]]; then
  for ID in $RT_IDS; do
    # Disassociate first
    ASSOC_IDS=$(aws ec2 describe-route-tables "${AWS_ARGS[@]}" --route-table-ids "$ID" \
      --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' \
      --output text 2>/dev/null || true)
    for ASSOC in $ASSOC_IDS; do
      aws ec2 disassociate-route-table "${AWS_ARGS[@]}" --association-id "$ASSOC" &>/dev/null || true
    done
    remove_resource "Route table $ID" \
      aws ec2 delete-route-table "${AWS_ARGS[@]}" --route-table-id "$ID"
  done
else
  ok "No orphaned route tables found"
fi

# ── Internet Gateways ─────────────────────────────────────────────────────────

step "  Internet Gateways"
IGW_IDS=$(aws ec2 describe-internet-gateways "${AWS_ARGS[@]}" \
  --filters "$(tag_filter)" \
  --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || true)

if [[ -n "$IGW_IDS" ]]; then
  for ID in $IGW_IDS; do
    VPC_ID=$(aws ec2 describe-internet-gateways "${AWS_ARGS[@]}" --internet-gateway-ids "$ID" \
      --query 'InternetGateways[0].Attachments[0].VpcId' --output text 2>/dev/null || true)
    [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] && \
      aws ec2 detach-internet-gateway "${AWS_ARGS[@]}" --internet-gateway-id "$ID" --vpc-id "$VPC_ID" &>/dev/null || true
    remove_resource "Internet gateway $ID" \
      aws ec2 delete-internet-gateway "${AWS_ARGS[@]}" --internet-gateway-id "$ID"
  done
else
  ok "No orphaned internet gateways found"
fi

# ── VPCs ──────────────────────────────────────────────────────────────────────

step "  VPCs"
VPC_IDS=$(aws ec2 describe-vpcs "${AWS_ARGS[@]}" \
  --filters "$(tag_filter)" \
  --query 'Vpcs[].VpcId' --output text 2>/dev/null || true)

if [[ -n "$VPC_IDS" ]]; then
  for ID in $VPC_IDS; do
    remove_resource "VPC $ID" \
      aws ec2 delete-vpc "${AWS_ARGS[@]}" --vpc-id "$ID"
  done
else
  ok "No orphaned VPCs found"
fi

# ── EBS Volumes ───────────────────────────────────────────────────────────────

step "  EBS Volumes"
VOL_IDS=$(aws ec2 describe-volumes "${AWS_ARGS[@]}" \
  --filters "$(tag_filter)" "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)

if [[ -n "$VOL_IDS" ]]; then
  for ID in $VOL_IDS; do
    remove_resource "EBS volume $ID" \
      aws ec2 delete-volume "${AWS_ARGS[@]}" --volume-id "$ID"
  done
else
  ok "No orphaned EBS volumes found"
fi

# ── IAM Roles & Instance Profiles ─────────────────────────────────────────────

step "  IAM Roles & Instance Profiles"
ALL_ROLES=$(aws iam list-roles "${AWS_ARGS[@]}" \
  --query "Roles[?contains(RoleName, '${CLUSTER_NAME}')].RoleName" \
  --output text 2>/dev/null || true)

FOUND_ROLES=0
for ROLE in $ALL_ROLES; do
  # Detach managed policies
  POLICIES=$(aws iam list-attached-role-policies "${AWS_ARGS[@]}" --role-name "$ROLE" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)
  for POLICY_ARN in $POLICIES; do
    aws iam detach-role-policy "${AWS_ARGS[@]}" --role-name "$ROLE" --policy-arn "$POLICY_ARN" &>/dev/null || true
  done
  # Delete inline policies
  INLINE=$(aws iam list-role-policies "${AWS_ARGS[@]}" --role-name "$ROLE" \
    --query 'PolicyNames[]' --output text 2>/dev/null || true)
  for POLICY in $INLINE; do
    aws iam delete-role-policy "${AWS_ARGS[@]}" --role-name "$ROLE" --policy-name "$POLICY" &>/dev/null || true
  done
  # Remove from instance profiles
  PROFILES=$(aws iam list-instance-profiles-for-role "${AWS_ARGS[@]}" --role-name "$ROLE" \
    --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null || true)
  for PROFILE_NAME in $PROFILES; do
    aws iam remove-role-from-instance-profile "${AWS_ARGS[@]}" \
      --role-name "$ROLE" --instance-profile-name "$PROFILE_NAME" &>/dev/null || true
    aws iam delete-instance-profile "${AWS_ARGS[@]}" \
      --instance-profile-name "$PROFILE_NAME" &>/dev/null || true
  done
  remove_resource "IAM role $ROLE" \
    aws iam delete-role "${AWS_ARGS[@]}" --role-name "$ROLE"
  ((FOUND_ROLES++))
done
[[ $FOUND_ROLES -eq 0 ]] && ok "No orphaned IAM roles found"

# ── Route53 Private Hosted Zones ──────────────────────────────────────────────

step "  Route53 Private Hosted Zones"
ZONES=$(aws route53 list-hosted-zones "${AWS_ARGS[@]}" \
  --query "HostedZones[?contains(Name, '${CLUSTER_NAME}') && Config.PrivateZone==\`true\`].Id" \
  --output text 2>/dev/null || true)

FOUND_ZONES=0
for ZONE_ID in $ZONES; do
  ZONE_ID="${ZONE_ID##*/}"  # strip /hostedzone/ prefix
  # Delete all non-SOA/NS records first
  RECORDS=$(aws route53 list-resource-record-sets "${AWS_ARGS[@]}" --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Type!='SOA' && Type!='NS']" --output json 2>/dev/null || echo "[]")
  if [[ "$RECORDS" != "[]" && "$RECORDS" != "null" ]]; then
    CHANGES=$(echo "$RECORDS" | jq '[.[] | {Action: "DELETE", ResourceRecordSet: .}]')
    aws route53 change-resource-record-sets "${AWS_ARGS[@]}" \
      --hosted-zone-id "$ZONE_ID" \
      --change-batch "{\"Changes\": $CHANGES}" &>/dev/null || true
  fi
  remove_resource "Route53 private zone $ZONE_ID" \
    aws route53 delete-hosted-zone "${AWS_ARGS[@]}" --id "$ZONE_ID"
  ((FOUND_ZONES++))
done
[[ $FOUND_ZONES -eq 0 ]] && ok "No orphaned Route53 private zones found"

# ─── PHASE 3: Local cleanup ───────────────────────────────────────────────────

step "Phase 3 of 3 — Local cleanup"
echo ""

if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
  ok "Removed install directory: $INSTALL_DIR"
else
  ok "Install directory already removed"
fi

# Terraform state cleanup
if [[ -f "${ROOT_DIR}/terraform.tfstate" ]] || [[ -d "${ROOT_DIR}/.terraform" ]]; then
  echo ""
  info "Cleaning up Terraform state..."
  cd "$ROOT_DIR"
  STALE_RESOURCES=$(terraform state list 2>/dev/null || true)
  if [[ -n "$STALE_RESOURCES" ]]; then
    echo "$STALE_RESOURCES" | xargs -I{} terraform state rm "{}" &>/dev/null || true
    ok "Terraform state cleared"
  else
    ok "Terraform state already clean"
  fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────────

TEARDOWN_END=$(date +%s)
ELAPSED=$(( TEARDOWN_END - TEARDOWN_START ))
MINUTES=$(( ELAPSED / 60 ))
SECONDS=$(( ELAPSED % 60 ))

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    Teardown Summary                         ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
printf "${BOLD}║  Cluster         : %-42s ║${NC}\n" "$CLUSTER_NAME"
printf "${BOLD}║  Duration        : %dm %ds%-37s ║${NC}\n" "$MINUTES" "$SECONDS" ""
printf "${BOLD}║  Resources freed : %-42s ║${NC}\n" "$RESOURCES_REMOVED"
if [[ $RESOURCES_FAILED -gt 0 ]]; then
  printf "${BOLD}║  ${YELLOW}Warnings         : %-42s${NC}${BOLD} ║${NC}\n" "$RESOURCES_FAILED could not be removed"
fi
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"

if [[ $RESOURCES_FAILED -gt 0 ]]; then
  echo -e "${BOLD}║  ${YELLOW}⚠  Some resources may require manual cleanup in AWS console.${NC}${BOLD}  ║${NC}"
  echo -e "${BOLD}║     Filter by tag: ${CLUSTER_TAG_KEY}         ║${NC}"
else
  echo -e "${BOLD}║  ${GREEN}✔  Cluster fully destroyed. All resources released.${NC}${BOLD}           ║${NC}"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
