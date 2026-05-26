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

# ── 2. cgroupv2 requirement ──────────────────────────────────────────────────
# K8s 1.35+ (the minimum version that ships containerd 2.1.x) hard-refuses to
# start on cgroup v1.  Fail fast here rather than burning 4 minutes on a
# cluster that will always die with "kubelet is configured to not run on a
# host using cgroup v1".
if [ "$_OS" = "linux" ] && ! [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  echo ""
  echo "ERROR: cgroup v2 (unified hierarchy) is not active on this host."
  echo "  K8s 1.35+ kubelet refuses to start on cgroup v1."
  echo ""
  if grep -q 'unified_cgroup_hierarchy=0' /proc/cmdline 2>/dev/null; then
    echo "  Your kernel cmdline explicitly disables cgroup v2."
    echo ""
    if command -v grubby >/dev/null 2>&1; then
      echo "  Fix (CBL-Mariner / Azure Linux):"
      echo "    sudo grubby --update-kernel=ALL \\"
      echo "      --remove-args='systemd.unified_cgroup_hierarchy=0 systemd.legacy_systemd_cgroup_controller=yes' \\"
      echo "      --args='systemd.unified_cgroup_hierarchy=1'"
    else
      echo "  Fix: remove 'systemd.unified_cgroup_hierarchy=0' from your kernel cmdline"
      echo "       and add 'systemd.unified_cgroup_hierarchy=1', then sudo update-grub"
    fi
  else
    echo "  Fix: add 'systemd.unified_cgroup_hierarchy=1' to your kernel cmdline and reboot."
    echo "  (Ubuntu 22+ and Fedora 31+ have cgroup v2 by default — likely no change needed)"
  fi
  echo ""
  echo "  Then reboot and re-run: bash setup.sh"
  exit 1
fi

# ── 3. cgroupv2 + Docker cgroup setup ────────────────────────────────────────
# Two requirements on cgroupv2/systemd hosts (CBL-Mariner, Ubuntu 22+, etc.):
#
# A) Docker must use the 'systemd' cgroup driver (not cgroupfs).
#    With cgroupfs, Docker mounts cgroup v1 hierarchies into containers.
#    K8s 1.35+ kubelet hard-refuses to start on cgroup v1 with:
#      "kubelet is configured to not run on a host using cgroup v1"
#
# B) Docker's systemd unit needs Delegate=yes so that kubelet can create
#    pod sub-cgroups inside the node container.
#
# Both changes are one-time and persist across reboots.
if [ -f /sys/fs/cgroup/cgroup.controllers ] && command -v systemctl >/dev/null 2>&1; then
  DAEMON_JSON=/etc/docker/daemon.json
  DELEGATE_CONF=/etc/systemd/system/docker.service.d/delegate.conf
  NEED_RESTART=false

  # Print current Docker cgroup state for diagnostics
  _DI=$(docker info 2>/dev/null)
  echo "    Docker cgroup driver  : $(echo "$_DI" | grep 'Cgroup Driver' || echo '(unknown)')"
  echo "    Docker cgroup version : $(echo "$_DI" | grep 'Cgroup Version' || echo '(unknown)')"
  echo "    Host cgroup version   : $(findmnt -n -o FSTYPE /sys/fs/cgroup 2>/dev/null || echo '(unknown)')"

  # A) systemd cgroup driver — required so containers see cgroupv2 not v1
  if echo "$_DI" | grep -q 'Cgroup Driver: cgroupfs'; then
    info "Switching Docker cgroup driver to systemd (cgroupv2 host, K8s 1.35+ requirement)..."
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

  # B) host cgroupns mode — Docker 20.10+ defaults to private cgroupns which
  #    can expose a cgroupv1 view to containers on hybrid-cgroup hosts.
  #    Setting host mode makes the node container share the host cgroup
  #    namespace, giving kubelet an unambiguous cgroupv2 view.
  if ! grep -q 'cgroupns' "$DAEMON_JSON" 2>/dev/null || \
     ! grep -q '"default-cgroupns-mode".*"host"' "$DAEMON_JSON" 2>/dev/null; then
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
  # Explicitly set systemd cgroup driver on both sides so kubelet and
  # containerd agree.  Matches the Docker daemon driver set in step 2.
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
    cgroupDriver: systemd
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = true
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

# ── 5. Verify containerd daemon version ──────────────────────────────────────
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

# ── 6. Inject containerd-shim-runc-v2 v2.1.6 ─────────────────────────────────
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

# ── 7. Export kubeconfig ──────────────────────────────────────────────────────
$KIND get kubeconfig --name "$CLUSTER" > "$KUBECONFIG_OUT"
echo "    kubeconfig: $KUBECONFIG_OUT"

echo ""
echo "Setup complete. Run the reproducer:"
echo ""
echo "  KUBECONFIG=$KUBECONFIG_OUT bash repro.sh"
echo ""
echo "When done:"
echo "  bash cleanup.sh"
