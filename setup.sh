#!/usr/bin/env bash
# Sets up a kind cluster pinned to containerd 2.1.6 (the buggy daemon+shim).
# After this runs, follow the printed instructions to run repro.sh.
#
# Requires: docker, curl
# kind and kubectl are downloaded automatically if not present.
set -euo pipefail

CLUSTER=shim-wedge-repro
CONTAINERD_VERSION=2.1.6
# K8s 1.34 ships containerd 2.1.3; we upgrade the daemon to 2.1.6 in-place.
# K8s 1.34 still accepts cgroup v1 (deprecated, removed in 1.35), so this
# works on both cgroupv1 and cgroupv2 Linux hosts and on macOS.
KIND_IMAGE=kindest/node:v1.34.0
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

# WSL2 without systemd: surfaces the root cause rather than a silent 4m timeout.
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

# ── 2. cgroupv2 note ─────────────────────────────────────────────────────────
# K8s 1.34 still accepts cgroupv1 (deprecated; hard-refused in 1.35).
# If the host is cgroupv1 we note it; cluster creation should still succeed.
if [ "$_OS" = "linux" ] && ! [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  echo ""
  echo "  NOTE: cgroup v1 detected. K8s 1.34 allows cgroupv1 (with deprecation warnings)."
  echo "  Proceeding — if cluster creation fails, consider enabling cgroup v2:"
  if command -v grubby >/dev/null 2>&1; then
    echo "    sudo grubby --update-kernel=ALL \\"
    echo "      --remove-args='systemd.unified_cgroup_hierarchy=0 systemd.legacy_systemd_cgroup_controller=yes' \\"
    echo "      --args='systemd.unified_cgroup_hierarchy=1' && sudo reboot"
  else
    echo "    Add 'systemd.unified_cgroup_hierarchy=1' to GRUB_CMDLINE_LINUX, then reboot."
  fi
  echo ""
fi

# ── 3. cgroupv2 + Docker cgroup setup ────────────────────────────────────────
# On cgroupv2/systemd Linux hosts Docker needs:
#   A) systemd cgroup driver so containers see cgroupv2 (not a cgroupv1 overlay)
#   B) Delegate=yes so kubelet can create pod sub-cgroups inside the node
# Both changes are one-time and persist across reboots.
if [ -f /sys/fs/cgroup/cgroup.controllers ] && command -v systemctl >/dev/null 2>&1; then
  DAEMON_JSON=/etc/docker/daemon.json
  DELEGATE_CONF=/etc/systemd/system/docker.service.d/delegate.conf
  NEED_RESTART=false

  _DI=$(docker info 2>/dev/null)
  echo "    Docker cgroup driver  : $(echo "$_DI" | grep 'Cgroup Driver' || echo '(unknown)')"
  echo "    Docker cgroup version : $(echo "$_DI" | grep 'Cgroup Version' || echo '(unknown)')"
  echo "    Host cgroup fstype    : $(findmnt -n -o FSTYPE /sys/fs/cgroup 2>/dev/null || echo '(unknown)')"

  # A) systemd cgroup driver
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

  # B) host cgroupns mode — avoids cgroupv1 view on hybrid-cgroup hosts
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

  # C) Delegate=yes — lets kubelet create pod sub-cgroups inside the node
  if ! grep -q 'Delegate=yes' "$DELEGATE_CONF" 2>/dev/null; then
    info "Enabling Docker cgroup delegation (one-time)..."
    sudo mkdir -p "$(dirname "$DELEGATE_CONF")"
    printf '[Service]\nDelegate=yes\n' | sudo tee "$DELEGATE_CONF" >/dev/null
    NEED_RESTART=true
  fi

  if [ "$NEED_RESTART" = "true" ]; then
    sudo systemctl daemon-reload && sudo systemctl restart docker
    echo "    done — Docker restarted."
    echo "    Docker cgroup driver  : $(docker info 2>/dev/null | grep 'Cgroup Driver' || echo '(unknown)')"
    echo "    Docker cgroup version : $(docker info 2>/dev/null | grep 'Cgroup Version' || echo '(unknown)')"
  fi
fi

# ── 4. Create kind cluster ────────────────────────────────────────────────────
info "Creating kind cluster '$CLUSTER' (image: $KIND_IMAGE)..."
if $KIND get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "    Cluster already exists — skipping"
else
  # Use systemd cgroup driver on cgroupv2 Linux; cgroupfs everywhere else
  # (cgroupv1 Linux, macOS Docker Desktop).  Both drivers must agree between
  # kubelet and containerd.
  KIND_CFG=/tmp/kind-cfg-shim-repro.yaml
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

# Export kubeconfig now so kubectl is available during recovery wait below.
$KIND get kubeconfig --name "$CLUSTER" > "$KUBECONFIG_OUT"

# ── 5. Upgrade containerd daemon+shim to v2.1.6 ──────────────────────────────
# The bug requires the daemon to propagate the handleEventTimeout context to
# the shim over ttrpc — behaviour introduced in PR #12364 (v2.1.5+).
# The kind image ships 2.1.3; we patch-upgrade to 2.1.6 in-place.
# Same minor version → compatible config and CRI API.
NODE="${CLUSTER}-control-plane"
NODE_ARCH=$(docker exec "$NODE" uname -m 2>/dev/null | tr '[:upper:]' '[:lower:]')
case "$NODE_ARCH" in amd64|x86_64) NODE_ARCH=amd64;; arm64|aarch64) NODE_ARCH=arm64;; *) echo "ERROR: could not detect node arch (got: '${NODE_ARCH}')"; exit 1;; esac

info "Upgrading containerd daemon+shim to v${CONTAINERD_VERSION} (${NODE_ARCH})..."
_URL="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${NODE_ARCH}.tar.gz"
curl -fsSL "$_URL" | tar xz -C /tmp --strip-components=1 bin/containerd bin/containerd-shim-runc-v2

docker exec "$NODE" systemctl stop containerd
docker cp /tmp/containerd "${NODE}:/usr/local/bin/containerd"
docker cp /tmp/containerd-shim-runc-v2 "${NODE}:/usr/local/bin/containerd-shim-runc-v2"
docker exec "$NODE" chmod +x /usr/local/bin/containerd /usr/local/bin/containerd-shim-runc-v2
rm -f /tmp/containerd /tmp/containerd-shim-runc-v2
docker exec "$NODE" systemctl start containerd

echo "    Waiting for control-plane to recover (up to 90s)..."
_OK=false
for _i in $(seq 18); do
  sleep 5
  $KUBECTL --kubeconfig "$KUBECONFIG_OUT" get nodes >/dev/null 2>&1 && { _OK=true; break; }
done
[ "$_OK" = true ] || { echo "ERROR: API server did not recover after containerd restart"; exit 1; }
$KUBECTL --kubeconfig "$KUBECONFIG_OUT" wait node --all --for=condition=Ready --timeout=30s >/dev/null 2>&1 || true

# ── 6. Verify containerd daemon version ──────────────────────────────────────
# Confirms the upgrade landed and that the bug-triggering behaviour is present.
CT_VER=$(docker exec "$NODE" containerd --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
if ! echo "$CT_VER" | grep -qE '^v2\.1\.'; then
  echo ""
  echo "ERROR: containerd ${CT_VER} in node — need v2.1.x."
  echo "  The bug was introduced in PR #12364 (v2.1.5) and fixed in v2.2.0."
  echo "  v2.0.x daemons never trigger it; v2.2.0+ have it patched."
  exit 1
fi
echo "    containerd daemon: ${CT_VER} ✓"
echo "    containerd shim:   $(docker exec "$NODE" /usr/local/bin/containerd-shim-runc-v2 -v 2>&1 | grep Version | awk '{print $2}')"

# ── 7. Export kubeconfig (final path printed for user) ───────────────────────
echo "    kubeconfig: $KUBECONFIG_OUT"

echo ""
echo "Setup complete. Run the reproducer:"
echo ""
echo "  KUBECONFIG=$KUBECONFIG_OUT bash repro.sh"
echo ""
echo "When done:"
echo "  bash cleanup.sh"
