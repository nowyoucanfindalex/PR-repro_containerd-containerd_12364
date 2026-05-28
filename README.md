# containerd shim stdio-drain wedge — reproducer

Reproduces the bug targeted by [containerd/containerd#13378](https://github.com/containerd/containerd/pull/13378) and verifies the fix.

## The bug

`containerd-shim-runc-v2` calls `waitTimeout(ctx, &p.wg, 10*time.Second)` to drain stdio before cleaning up a container (`process/init.go`). The `ctx` it receives has already been consuming the CRI event handler's own 10-second budget (`handleEventTimeout`, `events.go`). `context.WithTimeout(ctx, 10s)` sets the child deadline to `min(parent.Deadline(), now+10s)` — whatever fraction of the outer 10s remains, which is always less. When anything holds the pipe write-end open from outside the dying container's cgroup, the drain blocks, the budget expires, and `"failed to drain init process … io"` is logged. Two structural amplifiers then prevent recovery: the daemon skips `ShimInstance.Delete` on context error, and `service.Shutdown` refuses to exit while containers remain — leaving an orphaned shim and a pod stuck `Terminating` until SIGKILL fires at the end of the grace period.

## Trigger

`shareProcessNamespace: true` pod, two containers:

- **worker** — PID1 forks an orphan child (`sleep 30`) that inherits the shim's stdout pipe write-end, then exits after 5 seconds.
- **fd-holder** — scans `/proc` and opens the orphan's `fd/1` in **write mode** (`exec 3>/proc/<orphan_pid>/fd/1`). This gives it a write-end reference in its own cgroup, outside the reach of `cgroup.kill` on the worker's cgroup. When the worker is torn down and the orphan killed, fd-holder's `fd 3` keeps the write-end alive. The drain reads the read-end and never sees EOF.

Note: opening the FD in read mode (`cat`, `tail -f`) does **not** reproduce the bug — only a write-mode open (`O_WRONLY`) holds the write-end and blocks EOF.

## Prerequisites

You need either:

**A) An existing cluster running containerd v2.1.x** (k3s, k0s, RKE2, EKS, etc.)

Verify: `kubectl get node -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}'`

**B) Just Docker** — `setup.sh` creates a local kind cluster and injects the buggy shim automatically.

`setup.sh` and `setup-patched.sh` download `kind` and `kubectl` automatically if they are not on your PATH.

---

## Reproduce the bug

### Option A — existing cluster (containerd v2.1.x)

```sh
bash repro.sh
```

### Option B — no cluster (Docker required)

```sh
bash setup.sh                              # ~2 min: kind cluster + containerd v2.1.6 injected
KUBECONFIG=/tmp/shim-wedge-kubeconfig.yaml bash repro.sh
bash cleanup.sh                            # tear down when done
```

Expected output:

```
==> Preflight
    runtime : containerd://2.1.6

==> Applying pod...
    Waiting 8s for worker to exit and fd-holder to pin the write-end FD...

==> Deleting pod (buggy shim stalls until SIGKILL ~30s+; patched exits in <2s)...
pod "shim-wedge" deleted

RESULT: WEDGE REPRODUCED (delete took 31s — waitTimeout fired)

Look for this in your containerd journal:
  msg="failed to drain init process … io" error="context deadline exceeded"
```

---

## Verify the fix

`setup-patched.sh` builds `containerd-shim-runc-v2` from the fix branch of PR #13378 and injects it into an otherwise identical cluster (same v2.1.6 daemon). The build uses Docker + `golang:1.26-bookworm` — no local Go toolchain required.

> **Note:** PR #13378 is not yet merged or released. No published containerd version contains the fix.

```sh
bash setup-patched.sh                      # ~5 min: kind cluster + shim built from PR branch
KUBECONFIG=/tmp/shim-wedge-patched-kubeconfig.yaml bash repro.sh
bash cleanup-patched.sh                    # tear down when done
```

Expected output:

```
==> Preflight
    runtime : containerd://2.1.6

==> Applying pod...
    Waiting 8s for worker to exit and fd-holder to pin the write-end FD...

==> Deleting pod (buggy shim stalls until SIGKILL ~30s+; patched exits in <2s)...
pod "shim-wedge" deleted

RESULT: NOT REPRODUCED (delete took 1s)

If this was against setup-patched.sh: this is the EXPECTED result — fix verified.
```

The fix runs stdio drain in a background goroutine, decoupling it from the outer CRI context. `runtime.Delete` and `UnmountRecursive` always get the full outer-ctx budget and return in ~0.4s even when the pipe write-end is still held.

---

## Files

| File | Purpose |
|------|---------|
| `pod.yaml` | Two-container reproducer pod (`shareProcessNamespace: true`) |
| `repro.sh` | Apply pod → wait 8s → time the delete → print verdict |
| `setup.sh` | Create kind cluster with containerd v2.1.6 (buggy) |
| `cleanup.sh` | Delete the cluster created by `setup.sh` |
| `setup-patched.sh` | Create kind cluster, build shim from PR #13378 branch, inject it |
| `cleanup-patched.sh` | Delete the cluster created by `setup-patched.sh` |
