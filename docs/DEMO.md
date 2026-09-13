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
appropriate on the demo Mac. It writes one app-owned temporary file (128 MiB by
default) with the cache bypassed and `F_FULLFSYNC`, reads it once uncached
(`F_NOCACHE`) and once from the macOS cache, labels the three figures
separately, and removes the file. Say “device path, not raw media” for the
uncached read; the drive's own cache still applies.

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

Show Current I/O, Lowest free space, NFS retries, the volume list, and the priority alert.
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

> The benchmark has its own BENCHMARK badge. The write is flushed to the drive,
> the uncached read bypasses the macOS cache, and the cached read shows what the
> cache adds—a controlled comparison, not a storage certification.

If no visible live-I/O change occurs, say so. Do not substitute replay or
benchmark numbers.

### 1:55–2:25 — NFS and pNFS boundary

Stay in Performance and scroll to the NFS section.

> NFS counters are system-wide client totals from `nfsstat`. LumeFS can flag
> new retries or timeouts. A non-zero layout counter means a pNFS-related client
> operation was observed, but it does not prove that this mount or workload used
> a parallel data path.

If live layout counters are absent, select **Show example** and point out the `REPLAY` badge and “Does not replace live counters”
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

## Reproducible 2–3 minute recording plan

No demo video is committed to this repository. Record it locally on a Mac with
the following sequence; each step names the exact evidence the frame must show
so the recording can be checked against the running app.

| Time | Action | Evidence that must be visible |
| --- | --- | --- |
| 0:00 | Launch the app built from the demo commit; wait two refresh cycles | Toolbar status “Monitoring”, Overview with volume count and “No active alerts” or the real alert |
| 0:20 | Settings → lower **Warning** slider until it is above the free % of one real volume | Overview attention card switches to a `LIVE` capacity warning without touching any file |
| 0:40 | Alerts → select the alert | Rule ID `volume.capacity.warning`, evidence line “xx% free; threshold: yy%”, recommendation, `LIVE` badge |
| 1:00 | Volumes → select the root volume → File-system details | Format, source, SMART label as interpreted (“Verified” or “Not reported by this device”), APFS quota/reserve or “Not reported” |
| 1:20 | Performance while copying a large file in Finder (`cp` of a 2–4 GiB model file to another folder) | Read/Write lines move; badge `LIVE`; footer “Counters are sampled from IOKit” |
| 1:45 | Run the benchmark | `BENCHMARK` badge, duration, and the caption stating the immediate read may use the cache |
| 2:05 | If the loopback NFS lab is mounted: Volumes shows the NFS mount as non-local; Performance → NFS shows live requests increasing after `cat` of the lab fixture | `LIVE` NFS counters; otherwise the explicit “NFS counters unavailable” state |
| 2:25 | Performance → **Show example** | `REPLAY` badge, “never replaces live measurements” caption; say aloud that macOS's native client does not implement pNFS |
| 2:45 | Activity | Timeline entries with provenance badges for every state change above |

Optional 30-second extension when a second writable volume is mounted:

| Time | Action | Evidence that must be visible |
| --- | --- | --- |
| 2:50 | Placement (⌘6) → **Choose Source…** on a small model folder → pick the second volume → **Plan Copy (Dry Run)** | Plan card with file count, data, “Required (data + 20% margin)”, “Available … purgeable space not counted”, `ESTIMATE` badge; nothing created yet |
| 3:00 | **Copy…** → read the dialog aloud → **Copy** | Confirmation names both paths and says the original is never deleted; progress bar advances; **Cancel** visible |
| 3:15 | Result card, then Finder | “Copy completed”, size-verified count, “The original is untouched”; both trees exist; the journal lists `Planned`, `Started`, `Completed` |

Restore the Warning slider to 20% after recording. Do not include volumes,
mount sources, quota lines or placement paths that reveal private names.

## Honest fallback

If a collector is unavailable, demonstrate the unavailable state, the bundled
replay as `REPLAY`, the deterministic tests, and the metric contract. Do not
relabel a mockup, fixture, benchmark, replay, estimate, or old screenshot as live
output.

## Future work (challenge bonus)

The ordered list lives in the README under [Future work](../README.md#future-work)
so judges find it without opening the demo script.
