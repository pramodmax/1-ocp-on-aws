#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CLUSTER_NAME="${1:-}"

if [ -z "$CLUSTER_NAME" ]; then
  echo "Usage: $0 <cluster-name>"
  exit 1
fi

INSTALL_DIR="${ROOT_DIR}/clusters/${CLUSTER_NAME}"

if [ ! -d "$INSTALL_DIR" ]; then
  echo "Cluster directory not found: $INSTALL_DIR"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              Destroying OpenShift Cluster                   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Cluster : %-50s ║\n" "$CLUSTER_NAME"
printf "║  Dir     : %-50s ║\n" "$INSTALL_DIR"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  WARNING: This will permanently destroy the cluster and all its resources."
echo ""
read -r -p "  Type the cluster name to confirm: " CONFIRM

if [ "$CONFIRM" != "$CLUSTER_NAME" ]; then
  echo "Confirmation does not match. Aborting."
  exit 1
fi

echo ""
echo "  Destroying cluster via openshift-install..."
echo ""

openshift-install destroy cluster \
  --dir="$INSTALL_DIR" \
  --log-level=info

echo ""
echo "  Cluster destroyed. Removing local install directory..."
rm -rf "$INSTALL_DIR"

echo ""
echo "  Run terraform state rm to clean up Terraform state:"
echo "    cd $ROOT_DIR"
echo "    terraform state list | xargs terraform state rm"
echo ""
