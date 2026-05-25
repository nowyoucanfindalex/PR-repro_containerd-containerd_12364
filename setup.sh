#!/usr/bin/env bash
# Sets up a kind cluster with containerd-shim-runc-v2 v2.1.6 (the buggy version).
# After this runs, follow the printed instructions to run repro.sh.
#
# Requires: docker, curl
# kind and kubectl are downloaded automatically if not present.
set -euo pipefail

CLUSTER=shim-wedge-repro
SHIM_VERSION=2.1.6
KIND_IMAGE=kindest/node:v1.35.0
KUBECONFIG_OUT=/tmp/shim-wedge-kubeconfig.yaml

info() { echo "==> $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 not found — $2"; exit 1; }; }

# Detect OS and arch early — used in prerequisite checks and downloads
_OS=$(uname -s | tr '[:upper:]' '[:lower:]')   # linux | darwin
_ARCH=$(uname -m)
case "$_ARCH" in x86_64) _ARCH=amd64;; aarch64|arm64) _ARCH=arm64;; *) echo "Unsupported arch: $_ARCH"; exit 1;; esac

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
info "Checking prerequisites..."
need curl "install curl"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found."
  if [ "$_OS" = "darwin" ]; then
    echo "  Install Docker Desktop: https://docs.docker.com/desktop/install/mac-install/"
    echo "  Or colima:              brew install colima && colima start"
  else
    echo "  Install Docker:         https://docs.docker.com/engine/install/"
  fi
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker daemon is not running."
  if [ "$_OS" = "darwin" ]; then
    echo "  Start Docker Desktop from the menu bar, or run: colima start"
  else
    echo "  Run: sudo systemctl start docker"
  fi
  exit 1
fi

# WSL2 without systemd: kind defaults to the systemd cgroup driver, which
# requires systemd to be PID1 inside the node container.  Without it kubelet
# never becomes healthy (4-minute silent timeout in kubeadm).
# The cgroupfs kind config below is the real fix; this block just surfaces
# the root cause immediately instead of making you wait.
if grep -qsi microsoft /proc/version 2>/dev/null; then
  if ! systemctl is-active --quiet systemd 2>/dev/null; then
    echo ""
    echo "  NOTE: WSL2 detected without systemd."
    echo "  Attempting cgroupfs fallback (usually works)."
    echo "  If cluster creation still fails, enable systemd:"
    echo "    sudo sh -c 'printf \"[boot]\\nsystemd=true\\n\" >> /etc/wsl.conf'"
    echo "    # then from PowerShell: wsl --shutdown && wsl"
    echo ""
  fi
fi

# kind — download to /tmp if missing
KIND=$(command -v kind 2>/dev/null || true)
if [ -z "$KIND" ]; then
  info "Downloading kind (${_OS}/${_ARCH})..."
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/latest/kind-${_OS}-${_ARCH}"
  chmod +x /tmp/kind
  KIND=/tmp/kind
fi

# kubectl — download to /tmp if missing
KUBECTL=$(command -v kubectl 2>/dev/null || true)
if [ -z "$KUBECTL" ]; then
  info "Downloading kubectl (${_OS}/${_ARCH})..."
  KVER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/${_OS}/${_ARCH}/kubectl"
  chmod +x /tmp/kubectl
  KUBECTL=/tmp/kubectl
fi

# ── 2. cgroupv2 — Docker cgroup delegation ────────────────────────────────────
# On cgroupv2 systems (CBL-Mariner, Ubuntu 22+, Fedora 31+) Docker containers
# do not inherit cgroup controller access (memory, cpu, …) unless the Docker
# systemd unit has Delegate=yes.  Without it kubelet can't create pod cgroups
# and never starts, regardless of whether cgroupfs or systemd driver is used.
# This is a one-time change; it persists across reboots.
if [ -f /sys/fs/cgroup/cgroup.controllers ] && command -v systemctl >/dev/null 2>&1; then
  DELEGATE_CONF=/etc/systemd/system/docker.service.d/delegate.conf
  if ! grep -q 'Delegate=yes' "$DELEGATE_CONF" 2>/dev/null; then
    info "Enabling Docker cgroup delegation (cgroupv2 host — one-time, requires sudo)..."
    sudo mkdir -p /etc/systemd/system/docker.service.d
    printf '[Service]\nDelegate=yes\n' | sudo tee "$DELEGATE_CONF" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    echo "    done"
  fi
fi

# ── 3. Create kind cluster ────────────────────────────────────────────────────
info "Creating kind cluster '$CLUSTER' (image: $KIND_IMAGE)..."
if $KIND get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "    Cluster already exists — skipping"
else
  # Use cgroupfs for both containerd and kubelet so that kind works on hosts
  # where systemd is not PID1 inside the node container (WSL2 without systemd,
  # LXC, some CI runners).  The two settings must match: if containerd uses
  # SystemdCgroup=true but kubelet uses cgroupfs (or vice-versa) pods will
  # not start.  cgroupfs works everywhere; systemd only works with systemd.
  KIND_CFG=/tmp/kind-cfg-shim-repro.yaml
  cat > "$KIND_CFG" <<'KINDCFG'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    apiVersion: kubelet.config.k8s.io/v1beta1
    cgroupDriver: cgroupfs
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = false
KINDCFG
  # --retain keeps the node alive on failure so we can capture kubelet logs.
  if ! $KIND create cluster --name "$CLUSTER" --image "$KIND_IMAGE" --config "$KIND_CFG" --wait 90s --retain; then
    echo ""
    echo "==> Cluster creation failed — kubelet logs from inside the node:"
    docker exec "${CLUSTER}-control-plane" \
      journalctl -xeu kubelet --no-pager 2>/dev/null | tail -60 \
      || docker logs "${CLUSTER}-control-plane" 2>&1 | tail -60 \
      || echo "    (could not retrieve logs)"
    echo ""
    echo "==> Cleaning up failed cluster..."
    "$KIND" delete cluster --name "$CLUSTER" 2>/dev/null || true
    rm -f "$KIND_CFG"
    exit 1
  fi
  rm -f "$KIND_CFG"
fi

# ── 4. Verify containerd daemon version ──────────────────────────────────────
# The bug (PR #12364) lives in the shim but only fires when the containerd
# daemon passes a context with the handleEventTimeout deadline — behaviour
# present in 2.1.x, not in 2.0.x.  Fail fast here rather than silently
# producing a test that always returns NOT REPRODUCED.
NODE="${CLUSTER}-control-plane"
CT_VER=$(docker exec "$NODE" containerd --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+' | head -1 || echo "unknown")
if ! echo "$CT_VER" | grep -qE '^v2\.[1-9]'; then
  echo ""
  echo "ERROR: containerd ${CT_VER} in node — need v2.1.x or later."
  echo "  The bug was introduced in v2.1.5; earlier daemons won't trigger it."
  echo "  Delete this cluster and retry with a newer image:"
  echo "    $KIND delete cluster --name $CLUSTER"
  echo "    KIND_IMAGE=kindest/node:v1.36.0 bash setup.sh"
  echo "  Check available images: https://github.com/kubernetes-sigs/kind/releases"
  exit 1
fi
echo "    containerd daemon: ${CT_VER} ✓"

# ── 5. Inject containerd-shim-runc-v2 v2.1.6 ─────────────────────────────────
#
# Replace the shim binary so the reproducer fires on the exact buggy version
# regardless of what patch the image ships.
#
NODE_ARCH=$(docker inspect "$NODE" --format '{{.Architecture}}' 2>/dev/null | tr '[:upper:]' '[:lower:]')
case "$NODE_ARCH" in amd64|x86_64) NODE_ARCH=amd64;; arm64|aarch64) NODE_ARCH=arm64;; *) echo "ERROR: unknown arch '$NODE_ARCH'"; exit 1;; esac

info "Injecting containerd-shim-runc-v2 v${SHIM_VERSION} (${NODE_ARCH})..."
URL="https://github.com/containerd/containerd/releases/download/v${SHIM_VERSION}/containerd-${SHIM_VERSION}-linux-${NODE_ARCH}.tar.gz"
curl -fsSL "$URL" | tar xz -C /tmp --strip-components=1 bin/containerd-shim-runc-v2
docker cp /tmp/containerd-shim-runc-v2 "${NODE}:/usr/local/bin/containerd-shim-runc-v2"
docker exec "$NODE" chmod +x /usr/local/bin/containerd-shim-runc-v2
rm -f /tmp/containerd-shim-runc-v2

echo "    $(docker exec "$NODE" /usr/local/bin/containerd-shim-runc-v2 -version 2>&1 | head -1)"

# ── 5. Export kubeconfig ──────────────────────────────────────────────────────
$KIND get kubeconfig --name "$CLUSTER" > "$KUBECONFIG_OUT"
echo "    kubeconfig: $KUBECONFIG_OUT"

echo ""
echo "Setup complete. Run the reproducer:"
echo ""
echo "  KUBECONFIG=$KUBECONFIG_OUT bash repro.sh"
echo ""
echo "When done:"
echo "  bash cleanup.sh"
