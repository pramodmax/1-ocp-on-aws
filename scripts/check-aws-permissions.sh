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

echo -e "${BOLD}  Step 1 of 3 — Prerequisites${NC}"
echo ""

PREREQ_FAILURES=()
AWS_VERSION_RAW=""

# jq
if ! command -v jq &>/dev/null; then
  echo -e "  ${RED}✘${NC}  jq not found"
  PREREQ_FAILURES+=("jq_missing")
else
  echo -e "  ${GREEN}✔${NC}  jq $(jq --version)"
fi

# aws CLI presence
if ! command -v aws &>/dev/null; then
  echo -e "  ${RED}✘${NC}  AWS CLI not found"
  PREREQ_FAILURES+=("aws_missing")
else
  AWS_VERSION_RAW=$(aws --version 2>&1 | awk '{print $1}' | cut -d'/' -f2)
  AWS_MAJOR=$(echo "$AWS_VERSION_RAW" | cut -d'.' -f1)
  if [[ "$AWS_MAJOR" -lt 2 ]]; then
    echo -e "  ${RED}✘${NC}  AWS CLI v${AWS_VERSION_RAW} is below the required v2.x"
    PREREQ_FAILURES+=("aws_old:${AWS_VERSION_RAW}")
  else
    echo -e "  ${GREEN}✔${NC}  AWS CLI v${AWS_VERSION_RAW}"
  fi
fi

# AWS credentials
if [[ "${#PREREQ_FAILURES[@]}" -eq 0 ]]; then
  IDENTITY=$(_aws sts get-caller-identity --output json 2>/dev/null) || IDENTITY=""
  if [[ -z "$IDENTITY" ]]; then
    echo -e "  ${RED}✘${NC}  AWS credentials not found or invalid"
    PREREQ_FAILURES+=("aws_creds")
  else
    ACCOUNT=$(echo "$IDENTITY"       | jq -r '.Account')
    PRINCIPAL_ARN=$(echo "$IDENTITY" | jq -r '.Arn')
    USER_ID=$(echo "$IDENTITY"       | jq -r '.UserId')
    echo -e "  ${GREEN}✔${NC}  AWS credentials valid"
    printf "     Account  : %s\n" "$ACCOUNT"
    printf "     Principal: %s\n" "$PRINCIPAL_ARN"
    printf "     UserId   : %s\n" "$USER_ID"
  fi
fi

# ── Prerequisites result ───────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ "${#PREREQ_FAILURES[@]}" -gt 0 ]]; then
  echo ""
  echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${RED}║   ✘  Prerequisites check failed — cannot continue            ║${NC}"
  echo -e "${BOLD}${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${RED}║  Fix the issues below and re-run this script.                ║${NC}"
  echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  for failure in "${PREREQ_FAILURES[@]}"; do
    case "$failure" in
      jq_missing)
        echo -e "  ${RED}✘${NC}  ${BOLD}jq is not installed${NC}"
        echo "     jq is required to parse AWS API responses."
        echo ""
        echo "     macOS : brew install jq"
        echo "     Linux : sudo apt install jq  /  sudo yum install jq"
        echo "     Guide : https://jqlang.github.io/jq/download/"
        echo ""
        ;;
      aws_missing)
        echo -e "  ${RED}✘${NC}  ${BOLD}AWS CLI is not installed${NC}"
        echo "     macOS:"
        echo "       curl -sL https://awscli.amazonaws.com/AWSCLIV2.pkg -o /tmp/AWSCLIV2.pkg"
        echo "       sudo installer -pkg /tmp/AWSCLIV2.pkg -target /"
        echo ""
        echo "     Linux:"
        echo "       curl -sL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip"
        echo "       unzip /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install"
        echo ""
        echo "     Guide: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        echo ""
        ;;
      aws_old:*)
        OLD_VER="${failure#aws_old:}"
        echo -e "  ${RED}✘${NC}  ${BOLD}AWS CLI v${OLD_VER} is too old (minimum: v2.x)${NC}"
        echo "     OpenShift IPI requires AWS CLI v2 for SSO support, newer API"
        echo "     calls, and output format compatibility."
        echo ""
        echo "     macOS:"
        echo "       curl -sL https://awscli.amazonaws.com/AWSCLIV2.pkg -o /tmp/AWSCLIV2.pkg"
        echo "       sudo installer -pkg /tmp/AWSCLIV2.pkg -target /"
        echo ""
        echo "     Linux:"
        echo "       curl -sL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip"
        echo "       unzip /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install --update"
        echo ""
        echo "     Verify: aws --version"
        echo "     Guide : https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        echo ""
        ;;
      aws_creds)
        echo -e "  ${RED}✘${NC}  ${BOLD}AWS credentials not configured or invalid${NC}"
        echo "     Option 1 — Environment variables (export before running this script):"
        echo "       export AWS_ACCESS_KEY_ID=AKIA..."
        echo "       export AWS_SECRET_ACCESS_KEY=..."
        echo "       export AWS_SESSION_TOKEN=...   # only if using temporary credentials"
        echo ""
        echo "     Option 2 — Named profile:"
        echo "       aws configure --profile ocp-installer"
        echo "       ./scripts/check-aws-permissions.sh --profile ocp-installer"
        echo ""
        echo "     Verify: aws sts get-caller-identity"
        echo ""
        ;;
    esac
  done

  echo -e "  ${BOLD}Once fixed, re-run:${NC}  ./scripts/check-aws-permissions.sh"
  echo ""
  exit 1
fi

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   ✔  Prerequisites check passed                              ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║  Tools are installed and AWS credentials are valid.          ║${NC}"
echo -e "${BOLD}${GREEN}║  Proceeding to IAM permission checks...                     ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─── Check simulate-principal-policy access ───────────────────────────────────

echo -e "${BOLD}  Step 2 of 3 — IAM Simulation Method${NC}"
echo ""

SIMULATE_AVAILABLE=false
SIMULATE_TEST=$(_aws iam simulate-principal-policy \
  --policy-source-arn "$PRINCIPAL_ARN" \
  --action-names "sts:GetCallerIdentity" \
  --resource-arns "*" \
  --output json 2>&1) || true

if echo "$SIMULATE_TEST" | jq -e '.EvaluationResults' &>/dev/null; then
  echo -e "  ${GREEN}✔${NC}  iam:SimulatePrincipalPolicy available — using full policy simulation"
  SIMULATE_AVAILABLE=true
else
  warn "iam:SimulatePrincipalPolicy is not available for this principal."
  warn "Falling back to live read-only describe calls."
  warn "Note: write permissions (CreateVpc, RunInstances etc.) cannot be verified in fallback mode."
fi

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BOLD}  Step 3 of 3 — Permission Checks${NC}"
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
printf "${BOLD}║  Passed : %-2s / %-2s groups%-37s║${NC}\n" "$PASSED_GROUPS" "$TOTAL_GROUPS" ""
printf "${BOLD}║  Failed : %-2s / %-2s groups%-37s║${NC}\n" "${#FAILED_GROUPS[@]}" "$TOTAL_GROUPS" ""
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"

# ─── All Passed ───────────────────────────────────────────────────────────────

if [[ ${#FAILED_GROUPS[@]} -eq 0 ]]; then
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║   ✔  Permission Check Complete — All Groups Passed           ║${NC}"
  echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${GREEN}║  ✔  EC2 VPC & Networking                                     ║${NC}"
  echo -e "${BOLD}${GREEN}║  ✔  EC2 Instances & Security Groups                          ║${NC}"
  echo -e "${BOLD}${GREEN}║  ✔  ELB / ELBv2 Load Balancers                               ║${NC}"
  echo -e "${BOLD}${GREEN}║  ✔  IAM Roles & Policies                                     ║${NC}"
  echo -e "${BOLD}${GREEN}║  ✔  Route53 DNS                                               ║${NC}"
  echo -e "${BOLD}${GREEN}║  ✔  S3 Bucket & Objects                                      ║${NC}"
  echo -e "${BOLD}${GREEN}║  ✔  STS & Service Quotas                                     ║${NC}"
  echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${GREEN}║                                                              ║${NC}"
  echo -e "${BOLD}${GREEN}║  All required AWS IAM permissions are in place.              ║${NC}"
  echo -e "${BOLD}${GREEN}║  Your credentials are fully authorised to create an          ║${NC}"
  echo -e "${BOLD}${GREEN}║  OpenShift cluster on AWS. You are ready to install!         ║${NC}"
  echo -e "${BOLD}${GREEN}║                                                              ║${NC}"
  echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${GREEN}║  Next steps:                                                 ║${NC}"
  echo -e "${BOLD}${GREEN}║                                                              ║${NC}"
  echo -e "${BOLD}${GREEN}║  1. Fill in your cluster variables:                          ║${NC}"
  echo -e "${BOLD}${GREEN}║       cp terraform.tfvars.example terraform.tfvars           ║${NC}"
  echo -e "${BOLD}${GREEN}║                                                              ║${NC}"
  echo -e "${BOLD}${GREEN}║  2. Initialise Terraform:                                    ║${NC}"
  echo -e "${BOLD}${GREEN}║       terraform init                                         ║${NC}"
  echo -e "${BOLD}${GREEN}║                                                              ║${NC}"
  echo -e "${BOLD}${GREEN}║  3. Preview the plan:                                        ║${NC}"
  echo -e "${BOLD}${GREEN}║       terraform plan                                         ║${NC}"
  echo -e "${BOLD}${GREEN}║                                                              ║${NC}"
  echo -e "${BOLD}${GREEN}║  4. Install the cluster (30–45 minutes):                     ║${NC}"
  echo -e "${BOLD}${GREEN}║       terraform apply                                        ║${NC}"
  echo -e "${BOLD}${GREEN}║                                                              ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  exit 0
fi

# ─── Failures — per-group remediation ─────────────────────────────────────────

echo ""
echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║   ✘  Action Required — Missing Permissions Detected          ║${NC}"
echo -e "${BOLD}${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${RED}║  Do not proceed with terraform apply until all issues below  ║${NC}"
echo -e "${BOLD}${RED}║  are resolved. The installer will fail mid-way and leave     ║${NC}"
echo -e "${BOLD}${RED}║  orphaned AWS resources that you will have to clean up.      ║${NC}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"

echo ""
echo -e "${BOLD}  Failed permission groups:${NC}"
for g in "${FAILED_GROUPS[@]}"; do
  echo -e "    ${RED}✘${NC}  $g"
done

if [[ ${#FAILED_ACTIONS[@]} -gt 0 ]]; then
  echo ""
  echo -e "${BOLD}  Denied actions:${NC}"
  for a in "${FAILED_ACTIONS[@]}"; do
    echo -e "    ${RED}✘${NC}  $a"
  done
fi

# Per-group fix instructions
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  How to fix — step-by-step remediation${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

for group in "${FAILED_GROUPS[@]}"; do
  echo ""
  case "$group" in

    "EC2 VPC & Networking"|"EC2 Instances & Security Groups")
      echo -e "  ${RED}✘${NC}  ${BOLD}$group${NC}"
      echo ""
      echo "     The IAM user/role is missing EC2 permissions required to create"
      echo "     VPCs, subnets, security groups, and launch EC2 instances."
      echo ""
      echo "     Fix — attach the following managed policy to your IAM user/role:"
      echo ""
      echo "       Policy ARN: arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo ""
      echo "       aws iam attach-user-policy \\"
      echo "         --user-name <your-iam-user> \\"
      echo "         --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess"
      echo ""
      echo "     Or for a least-privilege setup, create a custom policy using:"
      echo "       https://docs.openshift.com/container-platform/latest/installing/"
      echo "       installing_aws/installing-aws-account.html#installation-aws-permissions"
      ;;

    "ELB / ELBv2")
      echo -e "  ${RED}✘${NC}  ${BOLD}$group${NC}"
      echo ""
      echo "     The IAM user/role is missing Elastic Load Balancing permissions."
      echo "     OpenShift creates load balancers for the API server and ingress router."
      echo ""
      echo "     Fix — attach the following managed policy:"
      echo ""
      echo "       Policy ARN: arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
      echo ""
      echo "       aws iam attach-user-policy \\"
      echo "         --user-name <your-iam-user> \\"
      echo "         --policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
      echo ""
      echo "     AWS Docs:"
      echo "       https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/"
      echo "       load-balancer-getting-started.html"
      ;;

    "IAM Roles & Policies")
      echo -e "  ${RED}✘${NC}  ${BOLD}$group${NC}"
      echo ""
      echo "     The IAM user/role cannot create or manage IAM roles. OpenShift"
      echo "     creates IAM roles for EC2 instance profiles (master, worker, bootstrap)."
      echo "     iam:PassRole is also required to assign those roles to instances."
      echo ""
      echo "     Fix — attach the following managed policy:"
      echo ""
      echo "       Policy ARN: arn:aws:iam::aws:policy/IAMFullAccess"
      echo ""
      echo "       aws iam attach-user-policy \\"
      echo "         --user-name <your-iam-user> \\"
      echo "         --policy-arn arn:aws:iam::aws:policy/IAMFullAccess"
      echo ""
      echo "     For a scoped approach using a permission boundary, see:"
      echo "       https://docs.openshift.com/container-platform/latest/installing/"
      echo "       installing_aws/installing-aws-account.html#installation-aws-iam-user"
      ;;

    "Route53 DNS")
      echo -e "  ${RED}✘${NC}  ${BOLD}$group${NC}"
      echo ""
      echo "     The IAM user/role is missing Route53 permissions. OpenShift creates"
      echo "     a private hosted zone and DNS records for the API and ingress endpoints."
      echo ""
      echo "     Fix — attach the following managed policy:"
      echo ""
      echo "       Policy ARN: arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
      echo ""
      echo "       aws iam attach-user-policy \\"
      echo "         --user-name <your-iam-user> \\"
      echo "         --policy-arn arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
      echo ""
      echo "     Also ensure a Route53 PUBLIC hosted zone exists for your base domain:"
      echo ""
      echo "       aws route53 create-hosted-zone \\"
      echo "         --name <your-base-domain> \\"
      echo "         --caller-reference \$(date +%s)"
      echo ""
      echo "     AWS Docs:"
      echo "       https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/"
      echo "       CreatingHostedZone.html"
      ;;

    "S3 Bucket & Objects")
      echo -e "  ${RED}✘${NC}  ${BOLD}$group${NC}"
      echo ""
      echo "     The IAM user/role is missing S3 permissions. OpenShift uses an S3"
      echo "     bucket to host the bootstrap node's ignition configuration file."
      echo ""
      echo "     Fix — attach the following managed policy:"
      echo ""
      echo "       Policy ARN: arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo ""
      echo "       aws iam attach-user-policy \\"
      echo "         --user-name <your-iam-user> \\"
      echo "         --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess"
      echo ""
      echo "     AWS Docs:"
      echo "       https://docs.aws.amazon.com/AmazonS3/latest/userguide/"
      echo "       security-iam-awsmanpol.html"
      ;;

    "STS & Service Quotas")
      echo -e "  ${RED}✘${NC}  ${BOLD}$group${NC}"
      echo ""
      echo "     The IAM user/role cannot call STS or read service quotas."
      echo "     sts:AssumeRole is required for the installer to assume service roles."
      echo "     servicequotas is used to validate EC2 instance limits before install."
      echo ""
      echo "     Fix — add an inline policy to your IAM user/role:"
      echo ""
      echo "       aws iam put-user-policy \\"
      echo "         --user-name <your-iam-user> \\"
      echo "         --policy-name OcpStsQuotas \\"
      echo "         --policy-document '{"
      echo "           \"Version\": \"2012-10-17\","
      echo "           \"Statement\": [{"
      echo "             \"Effect\": \"Allow\","
      echo "             \"Action\": [\"sts:AssumeRole\", \"servicequotas:*\"],"
      echo "             \"Resource\": \"*\""
      echo "           }]"
      echo "         }'"
      ;;

    *)
      echo -e "  ${RED}✘${NC}  ${BOLD}$group${NC}"
      echo "     Refer to the full IAM requirements in the Red Hat documentation."
      ;;
  esac
done

# ─── General remediation footer ───────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  General remediation steps${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  1. Apply the fixes listed above for each failed group."
echo ""
echo "  2. Wait 10–15 seconds for IAM policy propagation, then re-run:"
echo "       ./scripts/check-aws-permissions.sh"
echo ""
echo "  3. For the full list of required IAM actions and a ready-to-use"
echo "     policy JSON you can copy directly into AWS:"
echo ""
echo "     https://docs.openshift.com/container-platform/latest/installing/"
echo "     installing_aws/installing-aws-account.html#installation-aws-permissions"
echo ""
echo "  4. If using an IAM role instead of a user, replace --user-name with"
echo "     --role-name in the commands above."
echo ""
echo "  5. Verify your changes took effect:"
echo "       aws iam list-attached-user-policies --user-name <your-iam-user>"
echo ""
exit 1
