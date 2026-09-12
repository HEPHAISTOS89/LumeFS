# 2–3 minute demo

This script demonstrates only behavior that exists in the current application.
Use a clean macOS account or review every visible mount path and quota message
before sharing the screen.

## Before the clock

1. Run `./scripts/check.sh` once. Do not claim success if it fails.
2. Launch LumeFS and allow two refresh cycles before presenting.
3. Close unrelated applications that may expose names or generate confusing I/O.
4. Decide whether to use the optional localhost NFS lab. If so, complete
   [NFS_LAB.md](NFS_LAB.md) before the demo and keep the cleanup command ready.
5. Do not fill a disk, provoke storage errors, or create NFS failures for a demo.

Use the app's **Run benchmark** button only if a synthetic storage operation is
appropriate on the demo Mac. It writes and immediately reads one 128 MiB
app-owned temporary file, synchronizes the write, and removes the file. The read
may use the macOS cache; do not call it raw-device performance.

## Script

### 0:00–0:25 — Problem

> Local AI work spreads checkpoints, datasets, and caches across local and
> shared storage. macOS has the signals, but they live in separate low-level
> interfaces. LumeFS brings the evidence into one native view.

Show the running Overview. Point out the last-updated indicator.

### 0:25–0:55 — Provenance and overview

> LumeFS keeps live observations, synthetic benchmark results, deterministic
> replay evidence, and estimates visibly separate. One label never substitutes
> for another.

Show Current I/O, Capacity risk, NFS retries, the volume list, and recent alerts.
Change the AI workload size once and point to the `ESTIMATE` badge and fixed 20%
safety margin. Do not claim an alert exists if the view says there are none.

### 0:55–1:30 — Volume evidence

Open **Volumes** and select one non-sensitive volume.

> Capacity starts with the native mount table. APFS volumes are enriched with
> `diskutil` metadata such as SMART status, container free space, reserve, and
> quota when macOS exposes them.

Point out format, source, local/read-only flags, and unavailable fields. Explain
that displayed capacity remains the native mount-table value.

### 1:30–1:55 — Live I/O

Open **Performance**. Optionally run the built-in bounded 128 MiB benchmark.

> These are deltas from cumulative IOKit counters for whole storage devices.
> They show machine-level pressure, not which process or model caused it.

> The benchmark has its own BENCHMARK badge. The synchronized write is real, but
> the immediate read may use cache, so this is a controlled comparison—not a
> storage certification.

If no visible live-I/O change occurs, say so. Do not substitute replay or
benchmark numbers.

### 1:55–2:25 — NFS and pNFS boundary

Return to Overview and point to the NFS card.

> NFS counters are system-wide client totals from `nfsstat`. LumeFS can flag
> new retries or timeouts. A non-zero layout counter means a pNFS-related client
> operation was observed, but it does not prove that this mount or workload used
> a parallel data path.

If live layout counters are absent, select **Preview deterministic pNFS
evidence** and point out the `REPLAY` badge and “Does not replace live counters”
copy. If the local lab is mounted, identify it as a read-only localhost **NFSv3**
lab. Never present either as a live pNFS topology test.

### 2:25–2:50 — Explainable activity and close

Open **Activity** to show provenance-labeled state changes. If an alert exists,
open **Alerts** and show its rule ID, evidence, and recommended next step.
Otherwise show the honest empty state.

> LumeFS does not take destructive action. It turns low-level storage
> signals into inspectable evidence so the operator can decide what to do next.

## After the demo

If the NFS lab was used:

```bash
./scripts/nfs_lab.sh cleanup
./scripts/nfs_lab.sh status
```

The final status must report that the lab export and mount are absent. The NFS
daemon may remain running when it was already running or other exports exist.

## Honest fallback

If a collector is unavailable, demonstrate the unavailable state, the bundled
replay as `REPLAY`, the deterministic tests, and the metric contract. Do not
relabel a mockup, fixture, benchmark, replay, estimate, or old screenshot as live
output.
