#!/usr/bin/env bash
# Starts all EC2 instances belonging to the OCP cluster and waits for the
# cluster API and nodes to become healthy.

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
METADATA="${REPO_ROOT}/clusters/demo-ocp/metadata.json"

if [[ ! -f "${METADATA}" ]]; then
  echo "ERROR: metadata.json not found at ${METADATA}"
  echo "       Has the cluster been installed? Run terraform apply first."
  exit 1
fi

CLUSTER_NAME=$(jq -r '.clusterName'     "${METADATA}")
INFRA_ID=$(jq -r     '.infraID'         "${METADATA}")
AWS_REGION=$(jq -r   '.aws.region'      "${METADATA}")
CLUSTER_DOMAIN=$(jq -r '.aws.clusterDomain' "${METADATA}")

KUBECONFIG_PATH="${REPO_ROOT}/clusters/${CLUSTER_NAME}/auth/kubeconfig"
API_URL="https://api.${CLUSTER_DOMAIN}:6443"
CONSOLE_URL="https://console-openshift-console.apps.${CLUSTER_DOMAIN}"

CLUSTER_TAG="kubernetes.io/cluster/${INFRA_ID}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

info()    { echo "  →  $*"; }
ok()      { echo "  ✔  $*"; }
warn()    { echo "  ⚠  $*"; }
section() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  printf "║  %-60s║\n" "$*"
  echo "╚══════════════════════════════════════════════════════════════╝"
}

# ─── Banner ───────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           OpenShift Cluster Startup                         ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Cluster  : %-48s ║\n" "${CLUSTER_DOMAIN}"
printf "║  Infra ID : %-48s ║\n" "${INFRA_ID}"
printf "║  Region   : %-48s ║\n" "${AWS_REGION}"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: Verify AWS credentials ──────────────────────────────────────────

section "Step 1/4  Verifying AWS credentials"

CALLER=$(aws sts get-caller-identity --region "${AWS_REGION}" --output json 2>/dev/null) || {
  echo ""
  echo "  ERROR: AWS credentials are not configured or have expired."
  echo "  Set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, or configure an aws_profile."
  exit 1
}

ok "Authenticated as: $(echo "${CALLER}" | jq -r '.Arn')"

# ─── Step 2: Find and start stopped instances ─────────────────────────────────

section "Step 2/4  Starting EC2 instances"

ALL_INSTANCE_IDS=$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --filters \
    "Name=tag:${CLUSTER_TAG},Values=owned" \
    "Name=instance-state-name,Values=running,stopped,pending,stopping" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' \
  --output text 2>/dev/null)

if [[ -z "${ALL_INSTANCE_IDS}" ]]; then
  echo ""
  echo "  ERROR: No EC2 instances found for cluster tag ${CLUSTER_TAG}=owned"
  echo "  Make sure you are using the correct AWS region and the cluster exists."
  exit 1
fi

# Print table of all instances
echo ""
printf "  %-22s %-12s %s\n" "Instance ID" "State" "Name"
printf "  %-22s %-12s %s\n" "──────────────────────" "────────────" "────────────────────────────────────────"
STOPPED_IDS=()
RUNNING_IDS=()
while IFS=$'\t' read -r id state name; do
  printf "  %-22s %-12s %s\n" "${id}" "${state}" "${name:-<unnamed>}"
  if [[ "${state}" == "stopped" ]]; then
    STOPPED_IDS+=("${id}")
  elif [[ "${state}" == "running" ]]; then
    RUNNING_IDS+=("${id}")
  fi
done <<< "${ALL_INSTANCE_IDS}"
echo ""

if [[ ${#RUNNING_IDS[@]} -gt 0 && ${#STOPPED_IDS[@]} -eq 0 ]]; then
  ok "All instances are already running — skipping start."
else
  if [[ ${#STOPPED_IDS[@]} -eq 0 ]]; then
    warn "No stopped instances to start (some may be in pending/stopping state)."
  else
    info "Starting ${#STOPPED_IDS[@]} stopped instance(s): ${STOPPED_IDS[*]}"
    aws ec2 start-instances \
      --region "${AWS_REGION}" \
      --instance-ids "${STOPPED_IDS[@]}" \
      --output text > /dev/null
    ok "Start command sent."
  fi
fi

# ─── Step 3: Wait for all instances to be running ────────────────────────────

section "Step 3/4  Waiting for instances to reach 'running' state"

ALL_IDS=$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --filters \
    "Name=tag:${CLUSTER_TAG},Values=owned" \
    "Name=instance-state-name,Values=running,stopped,pending,stopping" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text)

info "Waiting for: ${ALL_IDS}"
echo ""

MAX_WAIT=600   # 10 minutes
INTERVAL=15
ELAPSED=0

while true; do
  NOT_RUNNING=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids ${ALL_IDS} \
    --query 'Reservations[].Instances[?State.Name!=`running`].[InstanceId,State.Name]' \
    --output text 2>/dev/null)

  if [[ -z "${NOT_RUNNING}" ]]; then
    ok "All instances are running."
    break
  fi

  if [[ ${ELAPSED} -ge ${MAX_WAIT} ]]; then
    echo ""
    echo "  ERROR: Timed out after ${MAX_WAIT}s waiting for instances to start."
    echo "  Still not running:"
    echo "${NOT_RUNNING}" | sed 's/^/    /'
    exit 1
  fi

  printf "  [%3ds] Waiting — not yet running:\n" "${ELAPSED}"
  echo "${NOT_RUNNING}" | sed 's/^/         /'
  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done

# Give the OS and kubelet a moment to fully initialize after the EC2 start
info "Pausing 30s for OS/kubelet initialization..."
sleep 30

# ─── Step 4: Wait for the OCP API and nodes ──────────────────────────────────

section "Step 4/4  Waiting for OpenShift cluster to become healthy"

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  warn "kubeconfig not found at ${KUBECONFIG_PATH}"
  warn "Falling back to raw HTTPS API check only."
  KUBECONFIG_PATH=""
fi

MAX_API_WAIT=600
ELAPSED=0

info "Probing API: ${API_URL}/readyz"
echo ""

while true; do
  HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    "${API_URL}/readyz" 2>/dev/null || echo "000")

  if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "401" || "${HTTP_CODE}" == "403" ]]; then
    ok "API is responding (HTTP ${HTTP_CODE})."
    break
  fi

  if [[ ${ELAPSED} -ge ${MAX_API_WAIT} ]]; then
    echo ""
    echo "  ERROR: Timed out after ${MAX_API_WAIT}s waiting for API to respond."
    echo "  Last HTTP code: ${HTTP_CODE}"
    echo ""
    echo "  Troubleshooting:"
    echo "    • Check Route53 has a record for api.${CLUSTER_DOMAIN}"
    echo "    • Verify the master nodes are fully started"
    echo "    • Check security groups allow :6443 inbound"
    exit 1
  fi

  printf "  [%3ds] API not ready yet (HTTP %s) — retrying in %ds...\n" \
    "${ELAPSED}" "${HTTP_CODE}" "${INTERVAL}"
  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done

# ─── Node health check ────────────────────────────────────────────────────────

if [[ -n "${KUBECONFIG_PATH}" ]]; then
  info "Checking node status..."
  echo ""

  MAX_NODE_WAIT=300
  ELAPSED=0

  while true; do
    NOT_READY=$(KUBECONFIG="${KUBECONFIG_PATH}" oc get nodes \
      --no-headers 2>/dev/null | grep -v " Ready" | grep -v "^$" || true)

    if [[ -z "${NOT_READY}" ]]; then
      ok "All nodes are Ready."
      break
    fi

    if [[ ${ELAPSED} -ge ${MAX_NODE_WAIT} ]]; then
      warn "Some nodes are not yet Ready (may still be recovering):"
      echo "${NOT_READY}" | sed 's/^/    /'
      break
    fi

    printf "  [%3ds] Waiting for nodes to become Ready...\n" "${ELAPSED}"
    sleep ${INTERVAL}
    ELAPSED=$((ELAPSED + INTERVAL))
  done

  echo ""
  info "Current node status:"
  KUBECONFIG="${KUBECONFIG_PATH}" oc get nodes 2>/dev/null | sed 's/^/  /'
fi

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                  Cluster is UP                              ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  API       : %-48s ║\n" "${API_URL}"
printf "║  Console   : %-48s ║\n" "${CONSOLE_URL}"
echo "╠══════════════════════════════════════════════════════════════╣"
KUBEADMIN_PW=$(cat "${REPO_ROOT}/clusters/${CLUSTER_NAME}/auth/kubeadmin-password" 2>/dev/null || echo "see clusters/${CLUSTER_NAME}/auth/kubeadmin-password")
printf "║  Username  : %-48s ║\n" "kubeadmin"
printf "║  Password  : %-48s ║\n" "${KUBEADMIN_PW}"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  kubeconfig: %-48s ║\n" "${KUBECONFIG_PATH:-not found}"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Run: export KUBECONFIG=${KUBECONFIG_PATH}"
echo "  Run: oc get nodes"
echo ""
