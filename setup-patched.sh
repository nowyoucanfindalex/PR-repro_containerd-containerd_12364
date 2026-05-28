#!/usr/bin/env bash
# Builds containerd-shim-runc-v2 from the fix branch (PR #13378) and
# injects it into a kind cluster that is otherwise identical to the one
# created by setup.sh (same v2.1.6 daemon).  Running repro.sh against
# this cluster should produce RESULT: NOT REPRODUCED.
#
# Requires: docker, curl
# kind and kubectl are downloaded automatically if not present.
set -euo pipefail

CLUSTER=shim-wedge-patched
CONTAINERD_DAEMON_VERSION=2.1.6   # same daemon as the buggy cluster
KIND_IMAGE=kindest/node:v1.34.0
KUBECONFIG_OUT=/tmp/shim-wedge-patched-kubeconfig.yaml

# Fix branch: PR #13378 in nowyoucanfindalex/containerd
FIX_REPO=https://github.com/nowyoucanfindalex/containerd.git
FIX_BRANCH=runc-shim/decouple-stdio-drain
GO_IMAGE=golang:1.26-bookworm   # used only for building the shim

info() { echo "==> $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 not found — $2"; exit 1; }; }

_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
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

KIND=$(command -v kind 2>/dev/null || true)
if [ -z "$KIND" ]; then
  info "Downloading kind (${_OS}/${_ARCH})..."
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/latest/kind-${_OS}-${_ARCH}"
  chmod +x /tmp/kind
  KIND=/tmp/kind
fi

KUBECTL=$(command -v kubectl 2>/dev/null || true)
if [ -z "$KUBECTL" ]; then
  info "Downloading kubectl (${_OS}/${_ARCH})..."
  KVER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/${_OS}/${_ARCH}/kubectl"
  chmod +x /tmp/kubectl
  KUBECTL=/tmp/kubectl
fi

# ── 2. cgroupv2 note ─────────────────────────────────────────────────────────
if [ "$_OS" = "linux" ] && ! [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  echo ""
  echo "  NOTE: cgroup v1 detected. K8s 1.34 allows cgroupv1 (with deprecation warnings)."
  echo "  Proceeding — if cluster creation fails, consider enabling cgroup v2."
  echo ""
fi

# ── 3. cgroupv2 + Docker cgroup setup ────────────────────────────────────────
if [ -f /sys/fs/cgroup/cgroup.controllers ] && command -v systemctl >/dev/null 2>&1; then
  DAEMON_JSON=/etc/docker/daemon.json
  DELEGATE_CONF=/etc/systemd/system/docker.service.d/delegate.conf
  NEED_RESTART=false

  _DI=$(docker info 2>/dev/null)
  if echo "$_DI" | grep -q 'Cgroup Driver: cgroupfs'; then
    info "Switching Docker cgroup driver to systemd (cgroupv2 host)..."
    if command -v python3 >/dev/null 2>&1 && [ -s "$DAEMON_JSON" ]; then
      sudo python3 - "$DAEMON_JSON" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:    d = json.load(open(path))
except: d = {}
opts = [o for o in d.get('exec-opts', []) if 'cgroupdriver' not in o]
opts.append('native.cgroupdriver=systemd')
d['exec-opts'] = opts
open(path, 'w').write(json.dumps(d, indent=2) + '\n')
PYEOF
    else
      printf '{"exec-opts":["native.cgroupdriver=systemd"]}\n' | sudo tee "$DAEMON_JSON" >/dev/null
    fi
    NEED_RESTART=true
  fi

  if ! grep -q '"default-cgroupns-mode".*"host"' "$DAEMON_JSON" 2>/dev/null; then
    info "Setting Docker cgroupns mode to host..."
    if command -v python3 >/dev/null 2>&1 && [ -s "$DAEMON_JSON" ]; then
      sudo python3 - "$DAEMON_JSON" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:    d = json.load(open(path))
except: d = {}
d['default-cgroupns-mode'] = 'host'
open(path, 'w').write(json.dumps(d, indent=2) + '\n')
PYEOF
    else
      printf '{"exec-opts":["native.cgroupdriver=systemd"],"default-cgroupns-mode":"host"}\n' \
        | sudo tee "$DAEMON_JSON" >/dev/null
    fi
    NEED_RESTART=true
  fi

  if ! grep -q 'Delegate=yes' "$DELEGATE_CONF" 2>/dev/null; then
    info "Enabling Docker cgroup delegation (one-time)..."
    sudo mkdir -p "$(dirname "$DELEGATE_CONF")"
    printf '[Service]\nDelegate=yes\n' | sudo tee "$DELEGATE_CONF" >/dev/null
    NEED_RESTART=true
  fi

  if [ "$NEED_RESTART" = "true" ]; then
    sudo systemctl daemon-reload && sudo systemctl restart docker
    echo "    done — Docker restarted."
  fi
fi

# ── 4. Create kind cluster ────────────────────────────────────────────────────
info "Creating kind cluster '$CLUSTER' (image: $KIND_IMAGE)..."
if $KIND get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "    Cluster already exists — skipping"
else
  KIND_CFG=/tmp/kind-cfg-shim-patched.yaml
  if [ "$_OS" = "linux" ] && [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    _CGROUP_DRIVER=systemd
    _SYSTEMD_CGROUP=true
  else
    _CGROUP_DRIVER=cgroupfs
    _SYSTEMD_CGROUP=false
  fi
  cat > "$KIND_CFG" <<KINDCFG
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    apiVersion: kubelet.config.k8s.io/v1beta1
    cgroupDriver: ${_CGROUP_DRIVER}
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = ${_SYSTEMD_CGROUP}
KINDCFG
  if ! $KIND create cluster --name "$CLUSTER" --image "$KIND_IMAGE" --config "$KIND_CFG" --wait 90s --retain; then
    echo ""
    echo "==> Cluster creation failed — kubelet logs from inside the node:"
    docker exec "${CLUSTER}-control-plane" \
      journalctl -xeu kubelet --no-pager 2>/dev/null | tail -60 \
      || docker logs "${CLUSTER}-control-plane" 2>&1 | tail -60 \
      || echo "    (could not retrieve logs)"
    "$KIND" delete cluster --name "$CLUSTER" 2>/dev/null || true
    rm -f "$KIND_CFG"
    exit 1
  fi
  rm -f "$KIND_CFG"
fi

$KIND get kubeconfig --name "$CLUSTER" > "$KUBECONFIG_OUT"

# ── 5. Upgrade containerd daemon to v2.1.6 (buggy daemon, identical to setup.sh) ─
# The bug requires the daemon to propagate handleEventTimeout context to the
# shim.  We keep the same daemon version as the buggy cluster so the only
# variable is the shim binary.
NODE="${CLUSTER}-control-plane"
NODE_ARCH=$(docker exec "$NODE" uname -m 2>/dev/null | tr '[:upper:]' '[:lower:]')
case "$NODE_ARCH" in amd64|x86_64) NODE_ARCH=amd64;; arm64|aarch64) NODE_ARCH=arm64;; *) echo "ERROR: could not detect node arch (got: '${NODE_ARCH}')"; exit 1;; esac

info "Upgrading containerd daemon to v${CONTAINERD_DAEMON_VERSION} (${NODE_ARCH})..."
_URL="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_DAEMON_VERSION}/containerd-${CONTAINERD_DAEMON_VERSION}-linux-${NODE_ARCH}.tar.gz"
curl -fsSL "$_URL" | tar xz -C /tmp --strip-components=1 bin/containerd
docker exec "$NODE" systemctl stop containerd
docker cp /tmp/containerd "${NODE}:/usr/local/bin/containerd"
docker exec "$NODE" chmod +x /usr/local/bin/containerd
rm -f /tmp/containerd

# ── 6. Build containerd-shim-runc-v2 from the fix branch (PR #13378) ─────────
# The fix runs stdio drain in a background goroutine so runtime.Delete and
# UnmountRecursive always get the full outer-ctx budget.  Delete returns in
# ~0.4s regardless of whether drain is blocked.
info "Building patched shim from PR #13378 branch (this takes ~3–5 min)..."
mkdir -p /tmp/shim-fix-build
docker run --rm \
  -v /tmp/shim-fix-build:/output \
  -e GOARCH="$NODE_ARCH" \
  -e GOOS=linux \
  -e CGO_ENABLED=0 \
  "$GO_IMAGE" \
  bash -c "
    set -euo pipefail
    git clone --depth=1 --branch '${FIX_BRANCH}' '${FIX_REPO}' /src
    cd /src
    make bin/containerd-shim-runc-v2
    cp bin/containerd-shim-runc-v2 /output/containerd-shim-runc-v2
    echo \"    built: \$(./bin/containerd-shim-runc-v2 -v 2>&1 | head -1)\"
  "

# ── 7. Inject patched shim + restart containerd ───────────────────────────────
info "Injecting patched shim..."
docker cp /tmp/shim-fix-build/containerd-shim-runc-v2 "${NODE}:/usr/local/bin/containerd-shim-runc-v2"
docker exec "$NODE" chmod +x /usr/local/bin/containerd-shim-runc-v2
docker exec "$NODE" systemctl start containerd

echo "    Waiting for control-plane to recover (up to 90s)..."
_OK=false
for _i in $(seq 18); do
  sleep 5
  $KUBECTL --kubeconfig "$KUBECONFIG_OUT" get nodes >/dev/null 2>&1 && { _OK=true; break; }
done
[ "$_OK" = true ] || { echo "ERROR: API server did not recover after containerd restart"; exit 1; }
$KUBECTL --kubeconfig "$KUBECONFIG_OUT" wait node --all --for=condition=Ready --timeout=30s >/dev/null 2>&1 || true

# ── 8. Verify ─────────────────────────────────────────────────────────────────
CT_VER=$(docker exec "$NODE" containerd --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
SHIM_VER=$(docker exec "$NODE" /usr/local/bin/containerd-shim-runc-v2 -v 2>&1 | grep -i version | head -1 || echo "unknown")
echo "    containerd daemon : ${CT_VER} (buggy range — same as setup.sh)"
echo "    containerd shim   : ${SHIM_VER} (patched build from PR #13378)"
echo "    kubeconfig        : $KUBECONFIG_OUT"

echo ""
echo "Setup complete. Run the reproducer against the PATCHED shim:"
echo ""
echo "  KUBECONFIG=$KUBECONFIG_OUT bash repro.sh"
echo ""
echo "Expected: RESULT: NOT REPRODUCED (delete completes in <4s)"
echo ""
echo "When done:"
echo "  bash cleanup-patched.sh"
