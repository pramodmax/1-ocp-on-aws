#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Find the most recently created cluster directory
CLUSTERS_DIR="${ROOT_DIR}/clusters"

if [ ! -d "$CLUSTERS_DIR" ]; then
  echo "No clusters directory found. Has the cluster been installed?"
  exit 1
fi

# Allow passing cluster name as argument, or auto-detect
if [ -n "${1:-}" ]; then
  CLUSTER_DIR="${CLUSTERS_DIR}/$1"
else
  CLUSTER_DIR=$(ls -dt "${CLUSTERS_DIR}"/*/  2>/dev/null | head -1)
  CLUSTER_DIR="${CLUSTER_DIR%/}"
fi

if [ ! -d "$CLUSTER_DIR" ]; then
  echo "Cluster directory not found: $CLUSTER_DIR"
  exit 1
fi

AUTH_DIR="${CLUSTER_DIR}/auth"

if [ ! -f "${AUTH_DIR}/kubeadmin-password" ]; then
  echo "Credentials not found. Installation may not be complete."
  exit 1
fi

CLUSTER_NAME=$(basename "$CLUSTER_DIR")
KUBEADMIN_PASSWORD=$(cat "${AUTH_DIR}/kubeadmin-password")
KUBECONFIG_PATH="${AUTH_DIR}/kubeconfig"

# Extract API and Console URLs from kubeconfig
API_URL=$(grep "server:" "$KUBECONFIG_PATH" | awk '{print $2}' | head -1)

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              OpenShift Cluster Credentials                  ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Cluster   : %-48s ║\n" "$CLUSTER_NAME"
printf "║  API URL   : %-48s ║\n" "$API_URL"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Username  : %-48s ║\n" "kubeadmin"
printf "║  Password  : %-48s ║\n" "$KUBEADMIN_PASSWORD"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  kubeconfig: %-48s ║\n" "$KUBECONFIG_PATH"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Quick login:"
echo ""
echo "    export KUBECONFIG=${KUBECONFIG_PATH}"
echo "    oc get nodes"
echo ""
echo "  Or login with password:"
echo ""
echo "    oc login ${API_URL} -u kubeadmin -p ${KUBEADMIN_PASSWORD}"
echo ""
