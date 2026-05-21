#!/usr/bin/env bash
# Tears down the kind cluster created by setup.sh.
set -euo pipefail

CLUSTER=shim-wedge-repro
KIND=$(command -v kind 2>/dev/null || echo /tmp/kind)

echo "==> Deleting kind cluster '$CLUSTER'..."
"$KIND" delete cluster --name "$CLUSTER" 2>/dev/null && echo "    done" || echo "    (not found)"

rm -f /tmp/shim-wedge-kubeconfig.yaml
echo "==> kubeconfig removed"
