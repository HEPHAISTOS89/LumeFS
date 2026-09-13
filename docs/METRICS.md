# Metric definitions

The source of truth for every number is the collector named below. Values in a
design mockup, pitch slide, or screenshot are not evidence unless captured from
the running app with the correct provenance.

## Provenance labels

| Label | Contract | Current producer |
| --- | --- | --- |
| `LIVE` | Observed on the current Mac through a native API or allowlisted executable. | IOKit, FSEvents, `nfsstat`, quota output, and live alerts |
| `UNAVAILABLE` | Collection failed or did not yield a supported value. | NFS and quota collectors |
| `BENCHMARK` | Produced by a bounded synthetic benchmark. | `DiskBenchmark` |
| `ESTIMATE` | Deterministic calculation combining a user selection with observed capacity. | Workload placement calculator |
| `REPLAY` | Decoded from a bundled deterministic fixture. | pNFS preview |

I/O views derive their badge from the first latest device sample and show
`UNAVAILABLE` when no device sample exists. `LIVE` still describes whole-device
collection, not attribution to one volume or workload.

## Volume capacity

The mount collector calculates:

```text
total bytes     = f_blocks × f_bsize
available bytes = f_bavail  × f_bsize
used bytes      = max(0, total bytes - available bytes)
used fraction   = clamp(used bytes / total bytes, 0...1)
```

If total bytes is zero, the used fraction is zero. Overflow in either
multiplication also produces zero.

`diskutil info -plist` enriches APFS metadata without replacing capacity:

| Model field | `diskutil` plist key |
| --- | --- |
| Volume name | `VolumeName` |
| SMART status | `SMARTStatus` |
| APFS volume quota | `CapacityQuota` when positive |
| APFS reserve | `CapacityReserve` when positive |

Overview “Lowest free space” is the free percentage of the discovered volume
with the lowest available fraction. It is not a predicted exhaustion date.

## Whole-device I/O

IOKit cumulative counters are sampled for whole `IOMedia` devices:

```text
rate = (current counter - previous counter) / elapsed seconds
```

Each whole media is traced up the IOKit service plane to the first
`IOBlockStorageDriver`, whose `Statistics` dictionary supplies the counters. An
APFS container (`disk3`) synthesized above a physical store (`disk0`) reaches the
same driver, so the collector keeps only one media per driver registry ID: the
shallowest one (the physical whole disk), with the BSD name as tie-breaker. Media
without an identifiable driver fall back to a recursive property search and are
treated as independent sources. Without this rule the “All devices” total would
count internal SSD traffic twice.

The result is still a whole-device figure. It is not compared automatically with
`iostat`; the maintainer validation record describes the manual trend comparison
(`iostat -d -w 1`) and its tolerance.

The app reports read bytes/s, write bytes/s, read/write operations/s, cumulative
errors, and cumulative retries. The first sample and any counter rollback yield
a zero rate.

Overview “Current I/O” sums the latest read and write rates across all returned
whole devices. It may include activity unrelated to the selected volume or AI
workload. The store creates at most one aggregated “All devices” history point
per refresh. The volume detail chart receives that same global history and is
not per-volume.

Formatting uses decimal units: 1 GB/s = 1,000,000,000 bytes/s and 1 MB/s =
1,000,000 bytes/s.

## NFS client metrics

`nfsstat -f JSON -c` supplies cumulative system-wide counters.

| Model field | Parsed source |
| --- | --- |
| Requests, retries, timeouts, invalid replies | `Client Info` → `RPC Info` |
| Read operations | NFSv3 Read + NFSv4 Read |
| Write operations | NFSv3 Write + NFSv4 Write |
| Layout gets | NFSv4.1 `Layoutget` |
| Layout commits | NFSv4.1 `Layoutcommit` |
| Layout returns | NFSv4.1 `Layoutreturn` |
| Device-info requests | NFSv4.1 `Getdevinfo` |

“pNFS observed” means at least one selected NFSv4.1 layout/device counter is
non-zero. It does **not** establish which mount generated the operation, whether
the current workload used pNFS, whether data traffic used multiple data servers,
or the server's pNFS configuration or health.

Missing optional JSON dictionaries or counters become zero. Invalid JSON or a
failed command makes the full NFS value `UNAVAILABLE`.

The bundled preview parses fixed JSON with `REPLAY` provenance. Replay counters
demonstrate parsing and presentation only and never replace the live counter
block.

## NFS mount information

`nfsstat -m -f JSON <mount point>` is run once per discovered NFS mount, at the
mount-table cadence (every 10 cycles). Apple's `nfsstat` nests one dictionary per
mount under the mount source (`server:/export`); LumeFS reads the entry whose
`Mount Point` matches the queried path.

| Model field | Parsed source |
| --- | --- |
| Server, export, addresses | `Current mount parameters` (fallback `Original mount options`) → `File system locations[0]` → `Server`, `Export`, `Locations` |
| NFS version | `NFS parameters` entry `vers=…` (for example `3`, `4.1`) |
| Transport | First `NFS parameters` entry among `tcp`, `udp`, `tcp4`, `tcp6`, `udp4`, `udp6`, `ticlts`, `ticotsord` |
| Parameters, mount flags | `NFS parameters`, `General mount flags` → `Flags` |
| Status flags | `Status flags` → `Flags`: `dead`, `not responding`, `recovery` (kernel `NFS_MIFLAG_*`) |

A record is `LIVE` only when `nfsstat` exited 0 and returned a mount dictionary.
Command failure, empty output (`{}`), or a parse error produces one
`UNAVAILABLE` record per mount that keeps the mount point and the error text;
an `UNAVAILABLE` record never reads as “Responding”.

These are the client's negotiated parameters and kernel state, not per-mount
throughput. macOS does not expose per-mount byte or operation counters; the
client-wide counters above remain the only NFS traffic figures.

## Process disk I/O

Every second cycle the engine lists processes with `sysctl(KERN_PROC_ALL)` and
reads `proc_pid_rusage(pid, RUSAGE_INFO_V4)` for each one. `ri_diskio_bytesread`
and `ri_diskio_byteswritten` are the kernel's cumulative physical disk bytes
attributed to the process that issued them.

| Model field | Source |
| --- | --- |
| Name | `proc_name` (full executable name), fallback `p_comm` (16 bytes) |
| PID, uid, start time | `kinfo_proc` (`p_pid`, `e_ucred.cr_uid`, `p_starttime`) |
| User | `getpwuid_r` on the uid, fallback `uid N` |
| Read / write rate | Non-negative delta of the disk byte counters divided by the interval between the two observations (nominally 2 s) |
| Written total | Cumulative `ri_diskio_byteswritten` |
| Hint | `WorkloadHint.token(forProcessName:)`: name match against `exo`, `openclaw`, `ollama`, `llama`, `mlx`, `python`, `jupyter`, `lmstudio`, `vllm`, `torch`, `whisper`, `comfy`, `diffusion`, `koboldcpp`, `mistral` |

Identity is `pid-starttime`, so a recycled PID never inherits another process's
counters. A first observation has no rate; only processes with a non-zero delta
appear in the list, capped at 40 entries ordered by combined rate.

Coverage is reported, not hidden: XNU's `proc_pid_rusage` applies
`CHECK_SAME_USER` (`bsd/kern/proc_info.c`), so without root LumeFS can read the
counters of the current user's processes only. Other users' processes are
counted as “not permitted” (`EPERM`). The panel shows readable / total /
denied counts. Page-cache hits and network file-system traffic are not part of
these counters; the hint is a name heuristic, never a classification of what the
process does. Arguments, environment, open files and paths are never read.

## NFS users (server side)

`nfsstat -u -n net -f JSON` reads the kernel's active-user list through
`nfssvc(NFSSVC_USERSTATS)`. XNU grants that call without superuser (only
`NFSSVC_NFSD` and `NFSSVC_ADDSOCK` require it), so no privilege prompt is
involved. The list exists only on a Mac that runs `nfsd`; on a pure client the
command prints `No NFS active user statistics found.` and an empty JSON
document. `-n net` keeps addresses numeric, so collection performs no DNS
lookup. `/sbin/nfsd status` (documented by Apple as an unprivileged command;
exit 0 when running, 1 otherwise) tells the UI whether “no user” means “idle
server” or “this Mac is not a server”.

| Model field | Parsed source |
| --- | --- |
| Export | Key under `NFS Active User Info` |
| User, uid | `User` (resolved name) or `Uuid` (numeric uid shown as `uid N`) |
| Address | Text after the last `@` of the record key (IPv4 or IPv6 literal) |
| Requests, read bytes, write bytes | `Requests`, `Read Bytes`, `Write Bytes` (cumulative per record) |
| Idle | `Idle` as `h:mm:ss` converted to seconds |

Rates are deltas between two consecutive `LIVE` snapshots three seconds apart
(the NFS collection interval), divided by the measured interval. A counter that
decreased (nfsd reclaimed the idle record and a new one started at zero) counts
as zero, never negative. Users seen for the first time have no rate yet.

Provenance: `LIVE` when `nfsstat` exited 0 and either returned the marker
sentence (zero users) or an `NFS Active User Info` section; `UNAVAILABLE` when
the command failed (for example `nfssvc failed: Operation not permitted` under
a MAC policy) or returned JSON without that section. `UNAVAILABLE` is displayed
as such with the reason and is never rendered as zero activity.

Privacy: the Attribution view masks addresses to their network prefix
(`192.0.·.·`, `2001:db8:…`) unless “Show full client addresses” is enabled;
alert text always uses the masked form. Retries are **not** reported per user
by macOS (`nfsstat -u` exposes requests, bytes and idle time only); retry
pressure remains a client-wide figure (`nfs.rpc.retries`).

## Quota

`quota -uv` is run for the current user. Recognized filesystem rows use the first
three numeric fields as usage, soft limit, and hard limit in KiB blocks and
multiply them by 1,024. Zero soft/hard limits become absent. Both one-line and
wrapped remote filesystem rows are supported.

A volume detail view uses a quota only when the parsed filesystem string equals
the volume mount point and displays the parsed used, soft-limit, and hard-limit
bytes. Unrecognized non-empty output is retained as one raw `LIVE` “All mounted
file systems” message; it is not treated as a structured per-volume metric.

Quota output may include usernames, mount names, paths, or server identifiers.
Review it before publishing screenshots.

## Alerts

| Rule ID | Trigger | Severity |
| --- | --- | --- |
| `device.smart.unhealthy` | SMART text contains explicit failure wording (`fail`, `fault`, `error`, `critical`, `degrad`, `warn`, `bad`, `predict`) | Critical |
| `device.smart.unrecognized` | SMART text is present, is not `Verified`, is not a known “no data” value (`Not Supported`, `Unknown`, empty) and contains no failure wording | Notice |
| `volume.capacity.warning` | Free fraction is below the configured warning level but not the critical level | Warning |
| `volume.capacity.critical` | Free fraction is below the configured critical level | Critical |
| `device.io.errors` | Read errors + write errors is greater than zero | Critical |
| `nfs.rpc.retries` | Cumulative NFS retries increased since the prior live NFS sample | Warning |
| `nfs.rpc.timeout` | Cumulative NFS timeouts increased since the prior live NFS sample | Critical |
| `nfs.mount.dead` | A `LIVE` mount record carries the kernel flag `dead` | Critical |
| `nfs.mount.not_responding` | A `LIVE` mount record carries `not responding` (and not `dead`) | Critical |
| `nfs.mount.recovery` | A `LIVE` mount record carries `recovery` only | Warning |
| `nfs.user.write_burst` | One NFS user's write rate over the last interval is ≥ the write-burst threshold (default 100 MB/s; Settings 10–1,000 MB/s) | Warning |
| `nfs.user.request_burst` | One NFS user's request rate over the last interval is ≥ the request-burst threshold (default 1,000 requests/s; Settings 100–10,000) | Warning |

One mount raises at most one mount-state alert per refresh (`dead` outranks `not
responding`, which outranks `recovery`). `UNAVAILABLE` mount records raise
nothing. Mount-state alerts carry `relatedVolumeID` of the volume with the same
mount point.

User-burst comparisons are `>=` and apply per `export|user@address` record; a
single user can raise both burst alerts in the same refresh. The alert text
names the user, export and masked address. The thresholds are heuristics for
“look at this now”, not proof of abuse; LumeFS never throttles or disconnects a
client.

`Not Supported`, `Unknown` and empty SMART values raise no alert: they mean the
device or bridge exposes no SMART data, not that the device is failing. A SMART
alert and a capacity alert can coexist for the same volume.

Threshold comparisons are strict. Defaults are 20% warning and 10% critical;
Settings can change them. The model clamps warning to 1–95%, critical to 1%–the
warning level, while the UI exposes narrower 10–40% and 2–20% ranges.

Device-error counters are cumulative. A non-zero historical counter can keep an
alert active even when no new error occurred during the latest interval.

### Alert lifecycle and history

Rules produce the current alert set; the history records occurrences of it.

| State | Meaning | Set by |
| --- | --- | --- |
| `active` | The alert id is present in the latest snapshot | First refresh that reports the id (`raisedAt`) |
| `acknowledged` | Still present, and someone pressed Acknowledge | The user (`acknowledgedAt`); the rule keeps firing |
| `cleared` | The id is absent from a later snapshot | The refresh that no longer reports it (`clearedAt`) |

- An entry is keyed by alert id plus raise time, so an id that clears and comes
  back is a new entry; the earlier one stays `cleared`.
- While an entry is open its payload (severity, message, evidence) is replaced
  by the latest snapshot's version and `lastSeenAt` advances; `raisedAt` never
  changes.
- Cleared beats acknowledged: an acknowledged alert that stops firing is shown
  as `cleared` with both timestamps kept.
- The ledger keeps at most 500 entries. When full, the oldest `cleared`
  entries are dropped first; open entries are never dropped.
- The file is `~/Library/Application Support/LumeFS/alert-history.json`
  (ISO-8601 dates, second precision). It is written on raise, clear,
  acknowledge, “Clear Closed” and pause, not every second, so `lastSeenAt` on
  disk can lag the UI until one of those events. An alert still open at quit is
  cleared at the first refresh after relaunch, with that later time.
- Clear times are refresh times, at most one collection cycle after the
  condition ended. There is no acknowledgement expiry or snooze.

### Notifications

Off by default. When enabled in Settings, LumeFS posts a macOS notification
for newly raised `critical` entries only, with these anti-spam rules: one
notification per refresh (several titles are joined, three at most, then “and
N more”), and a given alert id is announced at most once per 10 minutes even if
it clears and is raised again. Warnings and notices never notify. The
notification body is the alert title; it never includes evidence, paths,
device names, quota output or user names. macOS suppresses banners while
LumeFS is the active app.

### Snapshot export

File › Export Snapshot as JSON… (⇧⌘E) or as CSV… (⌥⇧⌘E) writes the latest
applied snapshot with `exportedAt`, `appVersion`, `addressesMasked`, and every
record's own `capturedAt` and provenance. JSON is the full model. CSV has one
row per measurement: `captured_at,category,identifier,metric,value,unit,provenance`
with categories `export`, `volume`, `device`, `nfs_client`, `nfs_mount`,
`nfs_user`, `process`, `quota`, `alert` and `alert_history`. Byte values are
integers, rates keep three decimals, non-finite numbers export as empty
fields, and `.distantPast` timestamps (uncollected records) appear as year 0001.
NFS client addresses are masked to their network prefix unless “Show full NFS
client addresses” is on; alert text is always masked. Exporting re-collects
nothing: the file is exactly what the UI showed.

## Workload placement estimate

The user chooses 8, 16, 32, 64, or 128 GiB. The calculator uses binary GiB:

```text
workload bytes = selected GiB × 1,073,741,824
required bytes = workload bytes + 20%
fits           = available bytes >= required bytes
```

The badge is `ESTIMATE`. The calculation does not predict checkpoint growth,
temporary training files, other writers, quotas, or future availability.

## Controlled benchmark

The UI offers 128 (default), 256, 512 and 1,024 MiB. The guard accepts
1–1,024 MiB and requires at least twice the requested bytes in reported free
space. The ceiling was raised from 256 MiB because at several GB/s a 128 MiB
pass lasts tens of milliseconds, too short for a stable rate; 1 GiB keeps a fast
SSD busy for a few hundred milliseconds while the 2× rule still bounds the
footprint (2 GiB free for the largest size). The benchmark creates a previously
absent UUID-named workspace directly below the macOS temporary directory and
writes only `sample.bin` (created with `O_EXCL`, mode 0600).

Three passes, each in 4 MiB page-aligned chunks:

| Pass | How | Label in the UI |
| --- | --- | --- |
| Write | `F_NOCACHE` on the descriptor so pages do not stay resident, then `F_FULLFSYNC` (drive write cache flushed); `fsync(2)` only if the file system refuses, and the result says so | Write |
| Uncached read | New descriptor with `F_NOCACHE` and `F_RDAHEAD` off, on pages that were never resident: bytes come from the device | Uncached read |
| Cached read | Two consecutive normal reads; the second is reported and is served by the unified buffer cache | Cached read |

Results report decimal bytes per second per pass, total elapsed time (all four
reads/writes including the unreported warm-up pass), `writeWasSynchronized`,
`writeUsedFullSync`, `writeBypassedCache` and cleanup status with `BENCHMARK`
provenance. “Uncached” means the macOS buffer cache was bypassed; the drive's
own DRAM/SLC cache, APFS compression and thermal state still influence the
number, so it is a device-path figure, not raw media performance. Cancellation is
checked between chunks; a cancelled run reports no rates and removes the
workspace. No percentile, repeated-run, device-isolation or wall-clock-timeout
statistic is produced.

## File activity

Opt-in FSEvents monitoring starts at selection time for one chosen directory.
Events are aggregated into a root label, operation set, count, and any rescan
reason. Raw event paths are not emitted from the collector. Delivery latency is
clamped to 0.05–2 seconds; the UI uses 0.5 seconds. The Activity timeline retains
at most 200 session events.

The label is the selected folder's basename, so it can still be identifying.
FSEvents can report dropped events or a changed root; those conditions are shown
as requiring a rescan rather than treated as complete history.

## Freshness and retention

- Store refresh request: approximately every second.
- Mount/APFS cache: up to approximately 10 cycles old.
- NFS cache: up to approximately 3 cycles old.
- Quota cache: up to approximately 30 cycles old.
- I/O history: at most 900 aggregated samples.
- Activity history: at most 200 in-memory session events.
- Alert history: at most 500 entries, persisted in Application Support across
  launches; open entries are never trimmed.

These are scheduling intentions, not real-time deadlines. System commands have a
five-second limit, and snapshot timestamps are captured before collection
finishes.

## What is not measured

LumeFS does not measure file contents, directory sizes, per-process I/O,
model-level I/O, queue depth, NFS server health, per-mount NFS RPCs, pNFS
data-server distribution, or predicted time to full. File activity does not emit
individual event paths.
