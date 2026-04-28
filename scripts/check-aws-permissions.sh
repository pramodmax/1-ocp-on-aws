#!/usr/bin/env bash
# Checks whether the active AWS credentials have sufficient IAM permissions
# to install an OpenShift IPI cluster. Uses aws iam simulate-principal-policy
# so no real resources are created.
#
# Usage:
#   ./scripts/check-aws-permissions.sh
#   ./scripts/check-aws-permissions.sh --profile my-aws-profile
#   ./scripts/check-aws-permissions.sh --verbose

set -eo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Args ─────────────────────────────────────────────────────────────────────

PROFILE=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# _aws: wraps every aws call so --profile is injected when provided.
# Avoids the "unbound variable" error that bash 3.2 (macOS default) throws
# when expanding an empty array under set -u.
_aws() {
  if [[ -n "$PROFILE" ]]; then
    aws --profile "$PROFILE" "$@"
  else
    aws "$@"
  fi
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

FAILED_GROUPS=()
FAILED_ACTIONS=()
PASSED_GROUPS=0
TOTAL_GROUPS=0

pass_group() { echo -e "  ${GREEN}✔${NC}  $1"; ((PASSED_GROUPS++)); ((TOTAL_GROUPS++)); }
fail_group() { echo -e "  ${RED}✘${NC}  $1"; FAILED_GROUPS+=("$1"); ((TOTAL_GROUPS++)); }
warn()       { echo -e "  ${YELLOW}⚠${NC}  $1"; }
info()       { echo -e "  ${CYAN}ℹ${NC}  $1"; }

# Simulate a batch of IAM actions against *.
# Prints per-action result in verbose mode. Returns 1 if any are denied.
check_permissions() {
  local group_name="$1"
  shift
  local actions=("$@")
  local denied=()

  local result
  result=$(_aws iam simulate-principal-policy \
    --policy-source-arn "$PRINCIPAL_ARN" \
    --action-names "${actions[@]}" \
    --resource-arns "*" \
    --output json 2>/dev/null)

  while IFS= read -r line; do
    local action decision
    action=$(echo "$line"   | jq -r '.EvalActionName')
    decision=$(echo "$line" | jq -r '.EvalDecision')
    if [[ "$decision" != "allowed" ]]; then
      denied+=("$action ($decision)")
      FAILED_ACTIONS+=("$action")
    else
      $VERBOSE && echo -e "        ${GREEN}✔${NC} $action"
    fi
  done < <(echo "$result" | jq -c '.EvaluationResults[]')

  if [[ ${#denied[@]} -eq 0 ]]; then
    pass_group "$group_name"
  else
    fail_group "$group_name"
    for d in "${denied[@]}"; do
      echo -e "        ${RED}✘${NC} $d"
    done
  fi
}

# ─── Header ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║        AWS IAM Permission Check — OpenShift IPI              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─── Prerequisites ────────────────────────────────────────────────────────────

echo -e "${BOLD}  Tools${NC}"

for tool in aws jq; do
  if ! command -v "$tool" &>/dev/null; then
    echo -e "  ${RED}✘${NC}  $tool not found — install it before continuing."
    exit 1
  fi
done
echo -e "  ${GREEN}✔${NC}  aws CLI and jq found"
echo ""

# ─── Caller Identity ──────────────────────────────────────────────────────────

echo -e "${BOLD}  Identity${NC}"

IDENTITY=$(_aws sts get-caller-identity --output json 2>/dev/null) || {
  echo -e "  ${RED}✘${NC}  Could not get caller identity. Check your credentials."
  echo ""
  echo "  Hints:"
  echo "    export AWS_ACCESS_KEY_ID=AKIA..."
  echo "    export AWS_SECRET_ACCESS_KEY=..."
  echo "    aws configure --profile <name>  then pass --profile <name> to this script"
  exit 1
}

ACCOUNT=$(echo "$IDENTITY"       | jq -r '.Account')
PRINCIPAL_ARN=$(echo "$IDENTITY" | jq -r '.Arn')
USER_ID=$(echo "$IDENTITY"       | jq -r '.UserId')

echo -e "  ${GREEN}✔${NC}  Authenticated"
printf "     Account  : %s\n" "$ACCOUNT"
printf "     Principal: %s\n" "$PRINCIPAL_ARN"
printf "     UserId   : %s\n" "$USER_ID"
echo ""

# ─── Check simulate-principal-policy access ───────────────────────────────────

echo -e "${BOLD}  Checking IAM simulation access${NC}"

SIMULATE_AVAILABLE=false
SIMULATE_TEST=$(_aws iam simulate-principal-policy \
  --policy-source-arn "$PRINCIPAL_ARN" \
  --action-names "sts:GetCallerIdentity" \
  --resource-arns "*" \
  --output json 2>&1) || true

if echo "$SIMULATE_TEST" | jq -e '.EvaluationResults' &>/dev/null; then
  echo -e "  ${GREEN}✔${NC}  iam:SimulatePrincipalPolicy available — using policy simulation"
  SIMULATE_AVAILABLE=true
else
  warn "iam:SimulatePrincipalPolicy is not allowed for this principal."
  warn "Falling back to live describe/list calls (read-only)."
fi

echo ""

# ─── Permission Checks ────────────────────────────────────────────────────────

if $SIMULATE_AVAILABLE; then

  echo -e "${BOLD}  EC2 — Networking${NC}"
  check_permissions "EC2 VPC & Networking" \
    ec2:CreateVpc ec2:DeleteVpc ec2:DescribeVpcs ec2:ModifyVpcAttribute \
    ec2:CreateSubnet ec2:DeleteSubnet ec2:DescribeSubnets ec2:ModifySubnetAttribute \
    ec2:CreateInternetGateway ec2:DeleteInternetGateway ec2:AttachInternetGateway \
    ec2:DescribeInternetGateways \
    ec2:CreateRouteTable ec2:DeleteRouteTable ec2:AssociateRouteTable \
    ec2:DisassociateRouteTable ec2:ReplaceRouteTableAssociation ec2:DescribeRouteTables \
    ec2:CreateRoute ec2:DeleteRoute \
    ec2:CreateNatGateway ec2:DeleteNatGateway ec2:DescribeNatGateways \
    ec2:AllocateAddress ec2:ReleaseAddress ec2:AssociateAddress ec2:DisassociateAddress \
    ec2:DescribeAddresses ec2:CreateDhcpOptions ec2:DeleteDhcpOptions \
    ec2:AssociateDhcpOptions ec2:DescribeDhcpOptions \
    ec2:CreateVpcEndpoint ec2:DeleteVpcEndpoints ec2:DescribeVpcEndpoints \
    ec2:DescribeAvailabilityZones ec2:DescribeRegions ec2:DescribeAccountAttributes

  echo -e "${BOLD}  EC2 — Compute & Security${NC}"
  check_permissions "EC2 Instances & Security Groups" \
    ec2:RunInstances ec2:TerminateInstances ec2:DescribeInstances \
    ec2:DescribeInstanceTypes ec2:DescribeInstanceAttribute \
    ec2:ModifyInstanceAttribute ec2:GetEbsDefaultKmsKeyId \
    ec2:CreateSecurityGroup ec2:DeleteSecurityGroup ec2:DescribeSecurityGroups \
    ec2:AuthorizeSecurityGroupIngress ec2:AuthorizeSecurityGroupEgress \
    ec2:RevokeSecurityGroupIngress ec2:RevokeSecurityGroupEgress \
    ec2:DescribeNetworkInterfaces ec2:CreateNetworkInterface ec2:DeleteNetworkInterface \
    ec2:ModifyNetworkInterfaceAttribute \
    ec2:CreateTags ec2:DeleteTags ec2:DescribeTags \
    ec2:DescribeImages ec2:CopyImage ec2:DeregisterImage ec2:DeleteSnapshot \
    ec2:DescribeKeyPairs ec2:DescribeNetworkAcls \
    ec2:DescribeVpcAttribute ec2:DescribeVpcClassicLink \
    ec2:DescribeVpcClassicLinkDnsSupport

  echo -e "${BOLD}  Elastic Load Balancing${NC}"
  check_permissions "ELB / ELBv2" \
    elasticloadbalancing:CreateLoadBalancer elasticloadbalancing:DeleteLoadBalancer \
    elasticloadbalancing:DescribeLoadBalancers elasticloadbalancing:DescribeLoadBalancerAttributes \
    elasticloadbalancing:ModifyLoadBalancerAttributes \
    elasticloadbalancing:CreateListener elasticloadbalancing:DescribeListeners \
    elasticloadbalancing:CreateTargetGroup elasticloadbalancing:DeleteTargetGroup \
    elasticloadbalancing:DescribeTargetGroups elasticloadbalancing:DescribeTargetGroupAttributes \
    elasticloadbalancing:ModifyTargetGroup elasticloadbalancing:ModifyTargetGroupAttributes \
    elasticloadbalancing:RegisterTargets elasticloadbalancing:DeregisterTargets \
    elasticloadbalancing:DescribeTargetHealth \
    elasticloadbalancing:AddTags elasticloadbalancing:DescribeTags \
    elasticloadbalancing:ApplySecurityGroupsToLoadBalancer \
    elasticloadbalancing:AttachLoadBalancerToSubnets \
    elasticloadbalancing:ConfigureHealthCheck \
    elasticloadbalancing:CreateLoadBalancerListeners \
    elasticloadbalancing:CreateLoadBalancerPolicy \
    elasticloadbalancing:DeregisterInstancesFromLoadBalancer \
    elasticloadbalancing:DescribeInstanceHealth \
    elasticloadbalancing:RegisterInstancesWithLoadBalancer \
    elasticloadbalancing:SetLoadBalancerPoliciesOfListener

  echo -e "${BOLD}  IAM${NC}"
  check_permissions "IAM Roles & Policies" \
    iam:CreateRole iam:DeleteRole iam:GetRole iam:ListRoles iam:TagRole iam:UntagRole \
    iam:PutRolePolicy iam:DeleteRolePolicy iam:GetRolePolicy \
    iam:CreateInstanceProfile iam:DeleteInstanceProfile iam:GetInstanceProfile \
    iam:AddRoleToInstanceProfile iam:RemoveRoleFromInstanceProfile \
    iam:ListInstanceProfilesForRole \
    iam:PassRole iam:GetUser iam:ListUsers \
    iam:SimulatePrincipalPolicy

  echo -e "${BOLD}  Route53${NC}"
  check_permissions "Route53 DNS" \
    route53:CreateHostedZone route53:DeleteHostedZone \
    route53:GetHostedZone route53:ListHostedZones route53:ListHostedZonesByName \
    route53:ChangeResourceRecordSets route53:ListResourceRecordSets \
    route53:GetChange route53:UpdateHostedZoneComment \
    route53:ChangeTagsForResource route53:ListTagsForResource

  echo -e "${BOLD}  S3${NC}"
  check_permissions "S3 Bucket & Objects" \
    s3:CreateBucket s3:DeleteBucket s3:HeadBucket \
    s3:GetBucketLocation s3:GetBucketAcl s3:PutBucketAcl \
    s3:GetBucketTagging s3:PutBucketTagging \
    s3:GetBucketVersioning s3:PutBucketVersioning \
    s3:GetEncryptionConfiguration s3:PutEncryptionConfiguration \
    s3:GetPublicAccessBlock s3:PutLifecycleConfiguration s3:GetLifecycleConfiguration \
    s3:ListBucket s3:ListBucketVersions s3:ListBucketMultipartUploads \
    s3:GetObject s3:PutObject s3:DeleteObject \
    s3:GetObjectAcl s3:PutObjectAcl \
    s3:GetObjectTagging s3:PutObjectTagging s3:GetObjectVersion \
    s3:GetAccelerateConfiguration s3:GetBucketCors \
    s3:GetBucketLogging s3:GetBucketObjectLockConfiguration \
    s3:GetBucketReplication s3:GetBucketRequestPayment s3:GetBucketWebsite

  echo -e "${BOLD}  STS & Service Quotas${NC}"
  check_permissions "STS & Service Quotas" \
    sts:GetCallerIdentity sts:AssumeRole \
    servicequotas:ListAWSDefaultServiceQuotas

else

  # ─── Fallback: live read-only describe calls ───────────────────────────────

  echo -e "${BOLD}  Fallback: Live Describe Calls (read-only)${NC}"
  echo ""

  run_check() {
    local label="$1"; shift
    if "$@" &>/dev/null 2>&1; then
      pass_group "$label"
    else
      fail_group "$label"
    fi
  }

  run_check "EC2 DescribeVpcs"           _aws ec2 describe-vpcs --max-items 1
  run_check "EC2 DescribeSubnets"        _aws ec2 describe-subnets --max-items 1
  run_check "EC2 DescribeSecurityGroups" _aws ec2 describe-security-groups --max-items 1
  run_check "EC2 DescribeImages"         _aws ec2 describe-images --owners self --max-items 1
  run_check "EC2 DescribeInstanceTypes"  _aws ec2 describe-instance-types --max-items 1
  run_check "ELB DescribeLoadBalancers"  _aws elbv2 describe-load-balancers
  run_check "IAM ListRoles"              _aws iam list-roles --max-items 1
  run_check "IAM ListInstanceProfiles"   _aws iam list-instance-profiles --max-items 1
  run_check "Route53 ListHostedZones"    _aws route53 list-hosted-zones
  run_check "S3 ListBuckets"             _aws s3api list-buckets
  run_check "STS GetCallerIdentity"      _aws sts get-caller-identity
  run_check "ServiceQuotas ListQuotas"   _aws service-quotas list-aws-default-service-quotas \
                                           --service-code ec2 --max-items 1

  warn "Fallback checks only verify read access. Write permissions (CreateVpc, RunInstances, etc.) cannot be verified without simulation."

fi

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                        Summary                              ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
printf "${BOLD}║  Passed: %-2s / %-2s groups%-38s║${NC}\n" "$PASSED_GROUPS" "$TOTAL_GROUPS" ""

if [[ ${#FAILED_GROUPS[@]} -gt 0 ]]; then
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}║  Failed groups:                                              ║${NC}"
  for g in "${FAILED_GROUPS[@]}"; do
    printf "║    ${RED}✘${NC} %-57s║\n" "$g"
  done

  if [[ ${#FAILED_ACTIONS[@]} -gt 0 ]]; then
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║  Denied actions:                                             ║${NC}"
    for a in "${FAILED_ACTIONS[@]}"; do
      printf "║    ${RED}✘${NC} %-57s║\n" "$a"
    done
  fi

  echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}║  ${RED}RESULT: Insufficient permissions — do not proceed.${NC}${BOLD}           ║${NC}"
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}║  Reference: docs.openshift.com/container-platform/latest/   ║${NC}"
  echo -e "${BOLD}║    installing/installing_aws/installing-aws-account.html     ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  exit 1
else
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}║  ${GREEN}RESULT: All checks passed — credentials are sufficient.${NC}${BOLD}      ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  exit 0
fi
