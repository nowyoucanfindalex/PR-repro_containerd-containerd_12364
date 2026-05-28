#!/usr/bin/env bash
# Reproducer for containerd/containerd#13378 — shim stdio-drain wedge.
# Usage: bash repro.sh
set -euo pipefail

POD=shim-wedge
NS=${NAMESPACE:-default}

# ── 1. Preflight ──────────────────────────────────────────────────────────────
echo "==> Preflight"
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }
kubectl cluster-info >/dev/null 2>&1  || { echo "ERROR: no cluster reachable (check KUBECONFIG)"; exit 1; }

RUNTIME=$(kubectl get node -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || echo "unknown")
echo "    runtime : $RUNTIME"
echo "$RUNTIME" | grep -q "containerd://2\." \
  || echo "    WARNING: expected containerd://2.x — wedge may not fire on other versions (got: $RUNTIME)"

# ── 2. Clean slate ────────────────────────────────────────────────────────────
kubectl delete pod "$POD" -n "$NS" \
  --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true

# ── 3. Apply pod ──────────────────────────────────────────────────────────────
echo ""
echo "==> Applying pod..."
kubectl apply -f "$(dirname "$0")/pod.yaml" -n "$NS"

echo "    Waiting 8s for worker to exit and fd-holder to pin the write-end FD..."
sleep 8

# ── 4. Time the delete ────────────────────────────────────────────────────────
echo ""
echo "==> Deleting pod (buggy shim stalls until SIGKILL ~30s+; patched exits in <2s)..."
START=$SECONDS
kubectl delete pod "$POD" -n "$NS" --grace-period=30 --timeout=90s
ELAPSED=$((SECONDS - START))

# ── 5. Verdict ────────────────────────────────────────────────────────────────
echo ""
if [ "$ELAPSED" -ge 9 ]; then
  echo "RESULT: WEDGE REPRODUCED (delete took ${ELAPSED}s — waitTimeout fired)"
  echo ""
  echo "Look for this in your containerd journal:"
  echo '  msg="failed to drain init process … io" error="context deadline exceeded"'
  echo ""
  echo "Hint: journalctl -u containerd --since '5 minutes ago' | grep 'failed to drain'"
  exit 0
else
  echo "RESULT: NOT REPRODUCED (delete took ${ELAPSED}s)"
  echo ""
  echo "If this was against setup-patched.sh: this is the EXPECTED result — fix verified."
  echo ""
  echo "If this was against setup.sh (buggy cluster), possible reasons:"
  echo "  - containerd version is not 2.1.x (got: $RUNTIME)"
  echo "  - fd-holder did not pin the FD in time — try running again"
  exit 1
fi
