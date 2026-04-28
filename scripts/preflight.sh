#!/usr/bin/env bash
set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

FAILED_CHECKS=()

pass() { echo -e "  ${GREEN}✔${NC}  $1"; }
fail() { echo -e "  ${RED}✘${NC}  $1"; FAILED_CHECKS+=("$1"); }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                   Pre-flight Checks                         ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
printf "${BOLD}║  Cluster : %-50s ║${NC}\n" "${CLUSTER_NAME}"
printf "${BOLD}║  Domain  : %-50s ║${NC}\n" "${BASE_DOMAIN}"
printf "${BOLD}║  Region  : %-50s ║${NC}\n" "${AWS_REGION}"
printf "${BOLD}║  Masters : %-2s x %-45s ║${NC}\n" "${MASTER_COUNT}" "${MASTER_TYPE}"
printf "${BOLD}║  Workers : %-2s x %-45s ║${NC}\n" "${WORKER_COUNT}" "${WORKER_TYPE}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─── Required Tools ───────────────────────────────────────────────────────────

echo -e "${BOLD}  1. Required Tools${NC}"

for tool in openshift-install aws oc jq; do
  if command -v "$tool" &>/dev/null; then
    VERSION=$($tool version 2>/dev/null | head -1 || echo "unknown version")
    pass "$tool — $VERSION"
  else
    fail "$tool not found"
  fi
done

# AWS CLI version check — must be v2.x
if command -v aws &>/dev/null; then
  AWS_VERSION_RAW=$(aws --version 2>&1 | awk '{print $1}' | cut -d'/' -f2)
  AWS_MAJOR=$(echo "$AWS_VERSION_RAW" | cut -d'.' -f1)
  if [[ "$AWS_MAJOR" -lt 2 ]]; then
    fail "AWS CLI v${AWS_VERSION_RAW} is below the required v2.x"
  fi
fi

# ─── AWS Credentials ──────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}  2. AWS Credentials${NC}"

if aws sts get-caller-identity &>/dev/null; then
  IDENTITY=$(aws sts get-caller-identity --output text --query '[Account, Arn]' 2>/dev/null)
  pass "Credentials valid — $IDENTITY"
else
  fail "AWS credentials not configured or invalid"
fi

# ─── Route53 Hosted Zone ──────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}  3. DNS — Route53 Public Hosted Zone${NC}"

ZONE_COUNT=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${BASE_DOMAIN}.']" \
  --output json 2>/dev/null | jq length)

if [ "$ZONE_COUNT" -gt "0" ]; then
  pass "Public hosted zone found for ${BASE_DOMAIN}"
else
  fail "No public hosted zone found for ${BASE_DOMAIN}"
fi

# ─── Region Access ────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}  4. AWS Region${NC}"

if aws ec2 describe-regions --region-names "${AWS_REGION}" --output json &>/dev/null; then
  pass "Region ${AWS_REGION} is accessible"
else
  fail "Region ${AWS_REGION} is not accessible"
fi

# ─── Instance Type Availability ───────────────────────────────────────────────

echo ""
echo -e "${BOLD}  5. Instance Type Availability${NC}"

for TYPE in "${MASTER_TYPE}" "${WORKER_TYPE}"; do
  AVAILABLE=$(aws ec2 describe-instance-type-offerings \
    --location-type availability-zone \
    --filters Name=instance-type,Values="${TYPE}" \
    --region "${AWS_REGION}" \
    --output json 2>/dev/null | jq '.InstanceTypeOfferings | length')
  if [ "$AVAILABLE" -gt "0" ]; then
    pass "${TYPE} available in ${AWS_REGION}"
  else
    fail "${TYPE} not available in ${AWS_REGION}"
  fi
done

# ─── Cluster State ────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}  6. Cluster State${NC}"

if [ -f "${INSTALL_DIR}/.install-complete" ]; then
  warn "Cluster ${CLUSTER_NAME} is already installed — terraform apply will be a no-op"
elif [ -d "${INSTALL_DIR}/auth" ]; then
  warn "Partial installation found in ${INSTALL_DIR} — consider running destroy first"
else
  pass "No existing installation found — clean install"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ "${#FAILED_CHECKS[@]}" -eq 0 ]; then

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║        ✔  All pre-flight checks passed!                      ║${NC}"
  echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${GREEN}║  Everything required to create the cluster is in place.      ║${NC}"
  echo -e "${BOLD}${GREEN}║  Proceeding with cluster installation...                     ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""

else

  echo ""
  echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${RED}║        ✘  Pre-flight checks failed — cannot proceed           ║${NC}"
  echo -e "${BOLD}${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${RED}║  Resolve each issue below before running terraform apply.    ║${NC}"
  echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}  Failed checks:${NC}"
  for c in "${FAILED_CHECKS[@]}"; do
    echo -e "    ${RED}✘${NC}  $c"
  done

  echo ""
  echo -e "${BOLD}  What to do:${NC}"
  echo ""

  for check in "${FAILED_CHECKS[@]}"; do
    case "$check" in

      *"openshift-install"*)
        echo -e "  ${RED}✘${NC}  ${BOLD}openshift-install not found${NC}"
        echo "     Download the binary matching your target OCP version:"
        echo "       https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
        echo "     Then move it to a directory on your PATH:"
        echo "       sudo mv openshift-install /usr/local/bin/"
        echo "       chmod +x /usr/local/bin/openshift-install"
        echo ""
        ;;

      *"oc not found"*)
        echo -e "  ${RED}✘${NC}  ${BOLD}oc (OpenShift CLI) not found${NC}"
        echo "     Download from:"
        echo "       https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
        echo "     Then:"
        echo "       sudo mv oc /usr/local/bin/ && chmod +x /usr/local/bin/oc"
        echo ""
        ;;

      *"aws not found"*)
        echo -e "  ${RED}✘${NC}  ${BOLD}AWS CLI not found${NC}"
        echo "     Install AWS CLI v2:"
        echo "     macOS:  https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        echo "     Linux:"
        echo "       curl -sL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip"
        echo "       unzip /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install"
        echo ""
        ;;

      *"AWS CLI"*"below"*)
        echo -e "  ${RED}✘${NC}  ${BOLD}AWS CLI version too old${NC}"
        echo "     Upgrade to v2.x:"
        echo "     macOS:"
        echo "       curl -sL https://awscli.amazonaws.com/AWSCLIV2.pkg -o /tmp/AWSCLIV2.pkg"
        echo "       sudo installer -pkg /tmp/AWSCLIV2.pkg -target /"
        echo "     Linux:"
        echo "       curl -sL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip"
        echo "       unzip /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install --update"
        echo "     Verify: aws --version"
        echo ""
        ;;

      *"jq not found"*)
        echo -e "  ${RED}✘${NC}  ${BOLD}jq not found${NC}"
        echo "     macOS:  brew install jq"
        echo "     Linux:  sudo apt install jq  /  sudo yum install jq"
        echo "     Guide:  https://jqlang.github.io/jq/download/"
        echo ""
        ;;

      *"credentials"*)
        echo -e "  ${RED}✘${NC}  ${BOLD}AWS credentials not configured or invalid${NC}"
        echo "     Option 1 — Environment variables:"
        echo "       export AWS_ACCESS_KEY_ID=AKIA..."
        echo "       export AWS_SECRET_ACCESS_KEY=..."
        echo ""
        echo "     Option 2 — AWS CLI profile:"
        echo "       aws configure --profile ocp-installer"
        echo "       export AWS_PROFILE=ocp-installer"
        echo ""
        echo "     Verify: aws sts get-caller-identity"
        echo ""
        ;;

      *"hosted zone"*)
        echo -e "  ${RED}✘${NC}  ${BOLD}Route53 public hosted zone missing for ${BASE_DOMAIN}${NC}"
        echo "     OpenShift requires a Route53 public hosted zone to create DNS records"
        echo "     for the API server and ingress router."
        echo ""
        echo "     Create one:"
        echo "       aws route53 create-hosted-zone \\"
        echo "         --name ${BASE_DOMAIN} \\"
        echo "         --caller-reference \$(date +%s)"
        echo ""
        echo "     Then update your domain registrar's NS records with the values"
        echo "     returned by the command above."
        echo ""
        echo "     AWS Docs:"
        echo "       https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/CreatingHostedZone.html"
        echo ""
        ;;

      *"Region"*"not accessible"*)
        echo -e "  ${RED}✘${NC}  ${BOLD}AWS region ${AWS_REGION} not accessible${NC}"
        echo "     Check that:"
        echo "       1. The region name is correct (e.g. us-east-1, ap-southeast-2)"
        echo "       2. Your IAM user/role has access to this region"
        echo "       3. The region is enabled in your account:"
        echo "          https://docs.aws.amazon.com/general/latest/gr/rande-manage.html"
        echo ""
        echo "     List available regions: aws ec2 describe-regions --output table"
        echo ""
        ;;

      *"not available in"*)
        INST_TYPE=$(echo "$check" | awk '{print $1}')
        echo -e "  ${RED}✘${NC}  ${BOLD}Instance type ${INST_TYPE} not available in ${AWS_REGION}${NC}"
        echo "     Not all instance types are available in every region."
        echo "     Check availability:"
        echo "       aws ec2 describe-instance-type-offerings \\"
        echo "         --location-type availability-zone \\"
        echo "         --filters Name=instance-type,Values=${INST_TYPE} \\"
        echo "         --region ${AWS_REGION}"
        echo ""
        echo "     Then update master_instance_type or worker_instance_type in"
        echo "     terraform.tfvars to a type available in ${AWS_REGION}."
        echo ""
        echo "     AWS instance type reference:"
        echo "       https://aws.amazon.com/ec2/instance-types/"
        echo ""
        ;;

      *)
        echo -e "  ${RED}✘${NC}  ${BOLD}${check}${NC}"
        echo "     Refer to the Red Hat OpenShift installation prerequisites:"
        echo "       https://docs.openshift.com/container-platform/latest/installing/"
        echo "       installing_aws/installing-aws-account.html"
        echo ""
        ;;
    esac
  done

  echo -e "${BOLD}  Once all issues are resolved, re-run:${NC}"
  echo "    terraform apply"
  echo ""
  exit 1

fi
