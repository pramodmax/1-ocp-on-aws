#!/usr/bin/env bash
# Validates that terraform.tfvars exists and all required fields are filled in.
# Run manually before terraform apply, or automatically via main.tf.
set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

FAILED=()

pass() { echo -e "  ${GREEN}✔${NC}  $1"; }
fail() { echo -e "  ${RED}✘${NC}  $1"; FAILED+=("$1"); }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }

# ─── Locate terraform.tfvars ──────────────────────────────────────────────────

TFVARS_FILE="${TFVARS_PATH:-terraform.tfvars}"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              terraform.tfvars Validation                     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ ! -f "$TFVARS_FILE" ]]; then
  echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${RED}║   ✘  terraform.tfvars not found                              ║${NC}"
  echo -e "${BOLD}${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${RED}║  Create it from the example file before running Terraform.  ║${NC}"
  echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "  Run:"
  echo "    cp terraform.tfvars.example terraform.tfvars"
  echo "    \$EDITOR terraform.tfvars"
  echo ""
  echo "  Then fill in at minimum:"
  echo "    cluster_name   — a short lowercase name for your cluster"
  echo "    base_domain    — your Route53 public hosted zone domain"
  echo "    pull_secret    — paste from https://console.redhat.com/openshift/install/pull-secret"
  echo "    ssh_public_key — contents of ~/.ssh/id_rsa.pub (or your preferred key)"
  echo ""
  exit 1
fi

pass "terraform.tfvars found"
echo ""

# ─── Parser ───────────────────────────────────────────────────────────────────

# Extracts a single-line HCL string value: var_name = "value"
get_var() {
  local key="$1"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS_FILE" 2>/dev/null \
    | head -1 \
    | sed "s/^[^=]*=[[:space:]]*//" \
    | sed 's/^"//; s/"[[:space:]]*$//' \
    | sed 's/[[:space:]]*#.*//' \
    | tr -d '\r'
}

# ─── Required fields ──────────────────────────────────────────────────────────

echo -e "${BOLD}  Required Fields${NC}"
echo ""

# cluster_name
CLUSTER_NAME=$(get_var "cluster_name")
if [[ -z "$CLUSTER_NAME" ]]; then
  fail "cluster_name is empty"
elif [[ "$CLUSTER_NAME" == "my-ocp-cluster" ]]; then
  fail "cluster_name is still the placeholder value 'my-ocp-cluster' — choose a unique name"
elif ! echo "$CLUSTER_NAME" | grep -qE '^[a-z][a-z0-9-]{1,26}[a-z0-9]$'; then
  fail "cluster_name '${CLUSTER_NAME}' is invalid — must be 3-28 chars, lowercase letters, digits, hyphens only"
else
  pass "cluster_name = ${CLUSTER_NAME}"
fi

# base_domain
BASE_DOMAIN=$(get_var "base_domain")
if [[ -z "$BASE_DOMAIN" ]]; then
  fail "base_domain is empty"
elif [[ "$BASE_DOMAIN" == "example.com" ]]; then
  fail "base_domain is still the placeholder 'example.com' — set your Route53 public hosted zone domain"
else
  pass "base_domain = ${BASE_DOMAIN}"
fi

# pull_secret
PULL_SECRET_LINE=$(grep -E "^[[:space:]]*pull_secret[[:space:]]*=" "$TFVARS_FILE" 2>/dev/null | head -1 || true)
PULL_SECRET_VAL=$(echo "$PULL_SECRET_LINE" | sed "s/^[^=]*=[[:space:]]*//" | sed 's/^"//; s/"[[:space:]]*$//' | tr -d '\r')
if [[ -z "$PULL_SECRET_VAL" ]]; then
  fail "pull_secret is empty — paste your Red Hat pull secret"
elif [[ "$PULL_SECRET_VAL" == '{"auths":{}' ]] || [[ "$PULL_SECRET_VAL" == "{}" ]]; then
  fail "pull_secret appears to be empty or a stub — paste the full JSON from console.redhat.com"
elif command -v jq &>/dev/null; then
  if echo "$PULL_SECRET_VAL" | jq -e '.auths' &>/dev/null; then
    pass "pull_secret — valid JSON with auths block"
  else
    fail "pull_secret is not valid pull secret JSON (missing 'auths' key)"
  fi
else
  pass "pull_secret — set (jq not available, skipping JSON validation)"
fi

# ssh_public_key
SSH_KEY=$(get_var "ssh_public_key")
if [[ -z "$SSH_KEY" ]]; then
  fail "ssh_public_key is empty — add the contents of your ~/.ssh/id_rsa.pub"
elif ! echo "$SSH_KEY" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com) '; then
  fail "ssh_public_key does not look like a valid SSH public key (expected ssh-rsa, ssh-ed25519, or ecdsa-* prefix)"
else
  KEY_TYPE=$(echo "$SSH_KEY" | awk '{print $1}')
  KEY_COMMENT=$(echo "$SSH_KEY" | awk '{print $3}')
  pass "ssh_public_key — ${KEY_TYPE}${KEY_COMMENT:+ (${KEY_COMMENT})}"
fi

# ─── Important optional fields ────────────────────────────────────────────────

echo ""
echo -e "${BOLD}  AWS Configuration${NC}"
echo ""

AWS_REGION=$(get_var "aws_region")
AWS_REGION="${AWS_REGION:-us-east-1}"
pass "aws_region = ${AWS_REGION}"

AWS_PROFILE=$(get_var "aws_profile")
if [[ -z "$AWS_PROFILE" ]]; then
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    pass "aws_profile — using environment variable credentials (AWS_ACCESS_KEY_ID is set)"
  else
    warn "aws_profile is empty — Terraform will use the default credential chain (env vars or instance role)"
  fi
else
  pass "aws_profile = ${AWS_PROFILE}"
fi

# ─── Cluster sizing ───────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}  Cluster Sizing${NC}"
echo ""

MASTER_COUNT=$(get_var "master_count")
MASTER_COUNT="${MASTER_COUNT:-3}"
MASTER_TYPE=$(get_var "master_instance_type")
MASTER_TYPE="${MASTER_TYPE:-m5.xlarge}"
pass "Control plane — ${MASTER_COUNT}x ${MASTER_TYPE}"

WORKER_COUNT=$(get_var "worker_count")
WORKER_COUNT="${WORKER_COUNT:-3}"
WORKER_TYPE=$(get_var "worker_instance_type")
WORKER_TYPE="${WORKER_TYPE:-m5.large}"
pass "Workers       — ${WORKER_COUNT}x ${WORKER_TYPE}"

OCP_VERSION=$(get_var "ocp_version")
OCP_VERSION="${OCP_VERSION:-4.16.3}"
pass "OCP version   — ${OCP_VERSION}"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ "${#FAILED[@]}" -eq 0 ]]; then

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║   ✔  terraform.tfvars is complete                            ║${NC}"
  echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${GREEN}║  All required values are present and look valid.             ║${NC}"
  echo -e "${BOLD}${GREEN}║  You are ready to run terraform plan / terraform apply.      ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""

else

  echo ""
  echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${RED}║   ✘  terraform.tfvars has missing or invalid values          ║${NC}"
  echo -e "${BOLD}${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${RED}║  Fill in the fields listed below before proceeding.          ║${NC}"
  echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}  Issues to fix:${NC}"
  echo ""

  for f in "${FAILED[@]}"; do
    case "$f" in

      *"cluster_name is empty"* | *"cluster_name is still the placeholder"* | *"cluster_name"*"invalid"*)
        echo -e "  ${RED}✘${NC}  ${BOLD}cluster_name${NC}"
        echo "     Set a unique, lowercase name for your cluster (3–28 chars):"
        echo "       cluster_name = \"my-cluster\""
        echo "     Rules: lowercase letters, digits, and hyphens only. Must start with a letter."
        echo ""
        ;;

      *"base_domain"*)
        echo -e "  ${RED}✘${NC}  ${BOLD}base_domain${NC}"
        echo "     Set the domain name of your Route53 public hosted zone:"
        echo "       base_domain = \"mycompany.com\""
        echo ""
        echo "     The hosted zone must already exist in Route53 before installing."
        echo "     Create one: aws route53 create-hosted-zone --name mycompany.com --caller-reference \$(date +%s)"
        echo "     Docs: https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/CreatingHostedZone.html"
        echo ""
        ;;

      *"pull_secret"*)
        echo -e "  ${RED}✘${NC}  ${BOLD}pull_secret${NC}"
        echo "     1. Go to: https://console.redhat.com/openshift/install/pull-secret"
        echo "     2. Log in with your Red Hat account"
        echo "     3. Click 'Copy pull secret'"
        echo "     4. Paste it as the pull_secret value in terraform.tfvars:"
        echo "          pull_secret = \"{\\\"auths\\\":{...}}\""
        echo ""
        echo "     The pull secret is a JSON object — paste it as a single-line quoted string."
        echo ""
        ;;

      *"ssh_public_key"*)
        echo -e "  ${RED}✘${NC}  ${BOLD}ssh_public_key${NC}"
        echo "     Paste the contents of your SSH public key file:"
        echo "       cat ~/.ssh/id_rsa.pub"
        echo "       # or"
        echo "       cat ~/.ssh/id_ed25519.pub"
        echo ""
        echo "     If you don't have a key, generate one first:"
        echo "       ssh-keygen -t ed25519 -C \"ocp-installer\""
        echo ""
        echo "     In terraform.tfvars:"
        echo "       ssh_public_key = \"ssh-ed25519 AAAAC3... your@email.com\""
        echo ""
        ;;

      *)
        echo -e "  ${RED}✘${NC}  ${BOLD}${f}${NC}"
        echo ""
        ;;
    esac
  done

  echo -e "  Edit ${BOLD}terraform.tfvars${NC} and re-run:"
  echo "    ./scripts/validate-tfvars.sh"
  echo ""
  exit 1

fi
