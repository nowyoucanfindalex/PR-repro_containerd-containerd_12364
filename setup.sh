#!/usr/bin/env bash
# Sets up a kind cluster with containerd-shim-runc-v2 v2.1.6 (the buggy version).
# After this runs, follow the printed instructions to run repro.sh.
#
# Requires: docker, curl
# kind and kubectl are downloaded automatically if not present.
set -euo pipefail

CLUSTER=shim-wedge-repro
SHIM_VERSION=2.1.6
KIND_IMAGE=kindest/node:v1.31.0
KUBECONFIG_OUT=/tmp/shim-wedge-kubeconfig.yaml

info() { echo "==> $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 not found — $2"; exit 1; }; }

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
info "Checking prerequisites..."
need docker "install Docker: https://docs.docker.com/get-docker/"
need curl   "install curl"

# kind — download to /tmp if missing
KIND=$(command -v kind 2>/dev/null || true)
if [ -z "$KIND" ]; then
  info "Downloading kind..."
  ARCH=$(uname -m); case "$ARCH" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) echo "Unsupported arch: $ARCH"; exit 1;; esac
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/latest/kind-linux-${ARCH}"
  chmod +x /tmp/kind
  KIND=/tmp/kind
fi

# kubectl — download to /tmp if missing
KUBECTL=$(command -v kubectl 2>/dev/null || true)
if [ -z "$KUBECTL" ]; then
  info "Downloading kubectl..."
  ARCH=$(uname -m); case "$ARCH" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) echo "Unsupported arch: $ARCH"; exit 1;; esac
  KVER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl"
  chmod +x /tmp/kubectl
  KUBECTL=/tmp/kubectl
fi

# ── 2. Create kind cluster ────────────────────────────────────────────────────
info "Creating kind cluster '$CLUSTER' (image: $KIND_IMAGE)..."
if $KIND get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "    Cluster already exists — skipping"
else
  $KIND create cluster --name "$CLUSTER" --image "$KIND_IMAGE" --wait 90s
fi

# ── 3. Inject containerd-shim-runc-v2 v2.1.6 ─────────────────────────────────
#
# The bug was introduced in containerd PR #12364 and exists in v2.1.5+.
# We replace the shim binary in the kind node so the reproducer fires
# regardless of what version the kind image ships with.
#
NODE="${CLUSTER}-control-plane"
NODE_ARCH=$(docker inspect "$NODE" --format '{{.Architecture}}' 2>/dev/null | tr '[:upper:]' '[:lower:]')
case "$NODE_ARCH" in amd64|x86_64) NODE_ARCH=amd64;; arm64|aarch64) NODE_ARCH=arm64;; *) echo "ERROR: unknown arch '$NODE_ARCH'"; exit 1;; esac

info "Injecting containerd-shim-runc-v2 v${SHIM_VERSION} (${NODE_ARCH})..."
URL="https://github.com/containerd/containerd/releases/download/v${SHIM_VERSION}/containerd-${SHIM_VERSION}-linux-${NODE_ARCH}.tar.gz"
curl -fsSL "$URL" | tar xz -C /tmp --strip-components=1 bin/containerd-shim-runc-v2
docker cp /tmp/containerd-shim-runc-v2 "${NODE}:/usr/local/bin/containerd-shim-runc-v2"
docker exec "$NODE" chmod +x /usr/local/bin/containerd-shim-runc-v2
rm -f /tmp/containerd-shim-runc-v2

echo "    $(docker exec "$NODE" /usr/local/bin/containerd-shim-runc-v2 -version 2>&1 | head -1)"

# ── 4. Export kubeconfig ──────────────────────────────────────────────────────
$KIND get kubeconfig --name "$CLUSTER" > "$KUBECONFIG_OUT"
echo "    kubeconfig: $KUBECONFIG_OUT"

echo ""
echo "Setup complete. Run the reproducer:"
echo ""
echo "  KUBECONFIG=$KUBECONFIG_OUT bash repro.sh"
echo ""
echo "When done:"
echo "  bash cleanup.sh"
