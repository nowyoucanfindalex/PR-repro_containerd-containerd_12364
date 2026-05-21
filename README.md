# containerd shim stdio-drain wedge — reproducer

Reproduces the bug targeted by [containerd/containerd#13378](https://github.com/containerd/containerd/pull/13378).

## The bug

`containerd-shim-runc-v2` calls `waitTimeout(ctx, &p.wg, 10*time.Second)` to drain stdio before cleaning up a container (`process/init.go`). The `ctx` it receives has already been consuming the CRI event handler's own 10-second budget (`handleEventTimeout`, `events.go`). `context.WithTimeout(ctx, 10s)` sets the child deadline to `min(parent.Deadline(), now+10s)` — whatever fraction of the outer 10s remains, which is always less. When anything holds the pipe write-end open from outside the dying container's cgroup, the drain blocks, the budget expires, and `"failed to drain init process … io"` is logged. Two structural amplifiers then prevent recovery: the daemon skips `ShimInstance.Delete` on context error, and `service.Shutdown` refuses to exit while containers remain — leaving an orphaned shim and a pod stuck `Terminating`.

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

## Run

### Option A — existing cluster

```sh
bash repro.sh
```

### Option B — no cluster (Docker required)

```sh
bash setup.sh                              # creates kind cluster, injects shim v2.1.6
KUBECONFIG=/tmp/shim-wedge-kubeconfig.yaml bash repro.sh
bash cleanup.sh                            # tears down the cluster when done
```

`setup.sh` downloads `kind` and `kubectl` automatically if they are not on your PATH.

## Expected output

**Stock containerd v2.1.x:**

```
==> Preflight
    runtime : containerd://2.1.6
==> Applying pod...
    Waiting 8s for worker to exit and fd-holder to pin the write-end FD...
==> Deleting pod (stock shim stalls ~10-25s; patched exits in <4s)...

RESULT: WEDGE REPRODUCED (delete took 25s — waitTimeout fired)

Look for this in your containerd journal:
  msg="failed to drain init process … io" error="context deadline exceeded"
```

**Patched shim (PR #13378):**

```
==> Deleting pod (stock shim stalls ~10-25s; patched exits in <4s)...

RESULT: NOT REPRODUCED (delete took 3s)
```

The patch decouples the drain timer from the caller context:
`context.WithTimeout(context.Background(), timeout)` — giving the drain a full
independent 10-second budget regardless of how much of the CRI event context remains.

## Files

| File | Purpose |
|------|---------|
| `pod.yaml` | Two-container reproducer pod |
| `repro.sh` | Apply → wait → time-delete → verdict |
