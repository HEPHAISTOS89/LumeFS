# Architecture

This document describes the implementation currently present in the repository.
It deliberately separates implemented behavior from planned provenance modes.

## System shape

```text
SwiftUI views
    │
    ▼
MonitoringStore (@MainActor, one-second loop, 900-sample cap)
    │
    ▼
MonitoringEngine (actor)
    ├── MountCollector ───────────── getfsstat(2)
    ├── APFSMetadataCollector ────── diskutil info -plist
    ├── BlockIOCollector (actor) ─── IOKit IOMedia statistics
    ├── ProcessIOCollector (actor) ─ sysctl KERN_PROC_ALL + proc_pid_rusage
    ├── NFSCollector ─────────────── nfsstat -f JSON -c
    ├── NFSMountCollector ────────── nfsstat -m -f JSON <mount point>
    ├── NFSActiveUserCollector ───── nfsstat -u -n net -f JSON, nfsd status
    ├── QuotaCollector ───────────── quota -uv
    └── AlertRuleEngine ──────────── deterministic rules

Opt-in/manual paths owned by MonitoringStore
    ├── AlertHistoryLedger ───────── lifecycle per alert id, 500 entries, Application Support JSON
    ├── CriticalAlertNotifier ────── UNUserNotificationCenter, opt-in, critical only
    ├── SnapshotExporter ─────────── JSON / CSV of the current snapshot via NSSavePanel
    ├── FileActivityCollector ────── FSEvents, aggregated to root labels
    ├── DiskBenchmark ────────────── app-owned temporary file
    ├── WorkloadReadinessCalculator 20% capacity-margin estimate
    └── pNFS replay ──────────────── bundled JSON fixture
```

There is no backend, account system, telemetry service, cloud database, or
third-party runtime package in the current project.

## UI and state

`LumeFSApp` creates one `MonitoringStore`. `AppShellView` exposes six
navigation sections:

- Overview
- Volumes, including an in-place volume detail pane
- Performance
- Attribution (which local processes and NFS users drive activity)
- Activity
- Alerts, with an Active / History switch, an in-place evidence pane, a
  lifecycle pane and an Acknowledge action

Settings are presented in a separate macOS Settings scene. Capacity sliders are
saved through `@AppStorage`; the engine reads them on each refresh and passes
bounded fractions to `AlertRuleEngine`. Defaults are 20% warning and 10%
critical. The UI keeps the critical value no greater than the warning value.

The store starts monitoring when the main view appears. It asks the engine for a
snapshot once per second. The store aggregates all returned whole-device samples
into one “All devices” point per successful sampling cycle and retains up to 900
points.

## Collection schedule

The engine keeps cached mount, NFS, and quota values.

| Collector | Initial refresh | Subsequent refresh |
| --- | --- | --- |
| Whole-device I/O | First cycle | Every cycle (~1 second) |
| Mounts and APFS enrichment | First cycle | Every 10th cycle |
| NFS client counters | First cycle | Every 3rd cycle |
| Current-user quota | First cycle | Every 30th cycle |

The timestamps come from the beginning of the engine refresh. Slow command
execution can therefore make a displayed sample older than its apparent age.
The command runner terminates an invocation after five seconds, so one slow
collector can still stretch a nominal one-second refresh.

## Collectors

### MountCollector

`getfsstat` enumerates mounted file systems. The collector includes `/`, any
mount under `/Volumes/`, and any file-system type whose name contains `nfs`.

Capacity is `f_blocks × f_bsize`; available capacity is `f_bavail × f_bsize`.
Multiplication overflow yields zero rather than trapping. Read-only and local
flags come from the mount record.

### APFSMetadataCollector

For every discovered APFS volume, the collector executes:

```text
/usr/sbin/diskutil info -plist <mount-point>
```

It can replace the volume name and add SMART status, `CapacityQuota`,
`CapacityReserve`, and an `APFSVolumeDetails` record (container reference, size
and free bytes, physical stores, `CapacityInUse`, `Encryption` / `FileVault` /
`Locked`, `Sealed`, `SolidState`, `Internal`, `BusProtocol`, `DeviceIdentifier`,
`VolumeUUID`). Every detail is optional and a missing key stays nil. Capacity
and available bytes remain the `getfsstat` values; the collector deliberately
does not substitute `APFSContainerFree`, which is shown separately as the
container-level shared free space. File-node counts (`f_files`, `f_ffree`) come
from `MountCollector` and survive enrichment.

The collector is strictly read-only: it never runs `fsck_apfs`,
`diskutil verifyVolume`, `repairVolume` or `diskutil apfs` subcommands. The
volume detail's “Copy verify command” only places
`diskutil verifyVolume "<mount point>"` on the clipboard.

If collection or property-list parsing fails, the original mount snapshot is
retained without an explicit error field; the UI shows the APFS section as
`UNAVAILABLE`.

### BlockIOCollector

IOKit is queried for whole `IOMedia` services. The collector reads cumulative
bytes, operations, errors, and retries. Bytes and operations are converted to
rates by subtracting the prior sample and dividing by elapsed time.

- The first sample for a device reports zero rates.
- A counter decrease reports zero for that rate.
- Samples are whole-device observations and are not attributed to a mount,
  process, path, model, or dataset.

### ProcessIOCollector

Every second cycle the actor lists processes through `sysctl(KERN_PROC_ALL)`
and calls libproc's `proc_pid_rusage(RUSAGE_INFO_V4)` for each PID. libproc is
not in Swift's Darwin module map, so `proc_pid_rusage` and `proc_name` are
resolved with `dlsym(RTLD_DEFAULT)` and called through `@convention(c)` function
pointers; no bridging header is added. Counters are keyed by `pid-starttime`,
rates are non-negative deltas between consecutive observations, and the
snapshot carries readable / denied / total counts because the kernel refuses
other users' processes (`EPERM`) when LumeFS is not root. Only the executable
name and PID are read.

### NFSCollector

The collector executes `/usr/bin/nfsstat -f JSON -c`. It parses system-wide
client RPC counters, NFSv3/NFSv4 read and write operations, and selected NFSv4.1
layout counters. Parse or execution failure returns one `UNAVAILABLE` value
instead of stale live data.

The counters are cumulative at the client level. The engine compares retry and
timeout counters every NFS collection interval to create alerts. They are not
attributed to a specific server or mount.

### NFSMountCollector

For each volume whose file system is NFS, the collector executes
`/usr/bin/nfsstat -m -f JSON <mount point>` (one mount per invocation, because
Apple's JSON printer keys mounts by their source string and would collapse two
mounts of the same export). It parses the server, export, addresses, negotiated
parameters (`vers=`, transport, `rsize=`, …), general mount flags and the kernel
status flags `dead`, `not responding`, `recovery`. Failure produces one
`UNAVAILABLE` record per mount that retains the reason. Records are refreshed
with the mount table (every 10 cycles) and feed the `nfs.mount.*` alert rules and
the “NFS mount” panel of the volume detail. The JSON layout was taken from
apple-oss-distributions/NFS (`nfsstat.c`, `printer.c`); unit fixtures are derived
from that source and anonymized, and the opt-in loopback lab exercises the live
path.

### NFSActiveUserCollector

Every NFS interval (3 cycles) the collector runs `/sbin/nfsd status` to learn
whether this Mac serves NFS, then `/usr/bin/nfsstat -u -n net -f JSON`. Output
is parsed into `NFSUserActivitySnapshot` (one `NFSUserActivity` per
`export|user@address`). The engine keeps the previous `LIVE` snapshot and
derives `NFSUserActivityRate` deltas, which feed the `nfs.user.*` alert rules
and the Attribution view. The marker sentence `No NFS active user statistics
found.` is a `LIVE` empty result with a server-state-aware message; command
failure or JSON without the `NFS Active User Info` section is `UNAVAILABLE`
with the reason. The kernel call behind `-u` (`nfssvc(NFSSVC_USERSTATS)`) does
not require root; `nfsd status` is Apple's documented unprivileged subcommand.
Client addresses are kept numeric (`-n net`) and masked in the UI by default.

### QuotaCollector

The collector executes `/usr/bin/quota -uv`. It recognizes ordinary and wrapped
filesystem rows, converts usage/soft/hard KiB block counts to bytes, and emits
one `LIVE` snapshot per parsed filesystem. A selected volume receives only a
quota whose filesystem string equals its mount point. Unrecognized non-empty
output remains one `LIVE` raw message for all mounted file systems. Empty
output, command failure, or output containing “none” produces an `UNAVAILABLE`
record.

## Provenance contract

`DataProvenance` defines `LIVE`, `BENCHMARK`, `ESTIMATE`, `REPLAY`, and
`UNAVAILABLE`.

- Native collectors emit `LIVE` and `UNAVAILABLE`.
- `DiskBenchmark` returns `BENCHMARK` results.
- Workload placement is labeled `ESTIMATE`.
- The bundled pNFS fixture is parsed as `REPLAY` and displayed separately from
  the live counters.
- Throughput views derive provenance from the first latest device sample and
  show `UNAVAILABLE` when no device sample exists.
- Volume snapshots do not have a provenance field.

Any additional producer requires end-to-end provenance propagation. Changing a
badge without changing the source is not sufficient.

## Manual and opt-in paths

### Workload placement estimate

The Overview picker offers 8, 16, 32, 64, or 128 GiB. The calculator converts
the selection to bytes and adds a fixed 20% safety margin. “Ready” means the
current volume's available bytes are at least that estimated requirement. It is
not a prediction of model growth or future free space.

### Controlled benchmark

The Performance view runs a 128, 256, 512 or 1,024 MiB benchmark (default
128). `DiskBenchmark` permits 1–1,024 MiB internally, requires at least twice
the requested size in reported free space, creates a previously absent
UUID-named workspace directly below `FileManager.temporaryDirectory`, and
writes deterministic bytes only to `sample.bin` through POSIX descriptors. The
write uses `F_NOCACHE` and `F_FULLFSYNC` (falling back to `fsync`), the
uncached read uses `F_NOCACHE` with read-ahead disabled on never-resident pages,
and the cached read is the second of two normal passes. The store owns the
benchmark `Task`; Cancel cancels it and `Task.checkCancellation()` between 4 MiB
chunks stops the pass. A deferred workspace removal covers thrown errors and
cancellation. There is still no explicit wall-clock timeout, so the size
bound—and the user's Cancel—limit the operation. The passes block one
cooperative-pool thread while they run.

### pNFS replay

The Performance view can parse `Resources/Fixtures/pnfs-client-sample.json` as
`REPLAY`. It is deterministic parser/UI evidence and is displayed separately
from current `LIVE` or `UNAVAILABLE` counters. It is not a live pNFS test.

### File activity

The user can choose one folder from the Activity view. `FileActivityCollector`
uses an FSEvents stream from “now,” aggregates item flags by the chosen root, and
emits operation counts and rescan reasons. Raw event paths are used transiently
to identify the matching root but are not emitted in `FileActivityBatch`; the UI
receives only the root label. Monitoring ends when stopped or the process exits.

## Alert rules

The alert engine is deterministic and sorts first by severity, then by creation
time. See [Metrics](METRICS.md) for the exact rules.

Alerts are recomputed on every refresh. Their lifecycle is kept separately by
`AlertHistoryLedger`, a pure value type the store reconciles after each applied
snapshot: an alert id that appears opens an entry (`active`), an id that is
still present refreshes the entry's payload and `lastSeenAt`, an id that
disappears closes the entry (`cleared`, timestamped with that refresh), and the
user can mark an open entry `acknowledged` without changing whether the rule
fires. The ledger holds at most 500 entries; trimming drops the oldest closed
entries first, so open alerts are never evicted.

`AlertHistoryPersistence` writes the ledger as pretty-printed ISO-8601 JSON to
`~/Library/Application Support/LumeFS/alert-history.json` (atomic write) when
an entry is raised, cleared, acknowledged or removed, and when monitoring is
paused. A file that cannot be decoded or has a foreign schema version is moved
to `alert-history.unreadable.json`, never deleted, and monitoring continues with
an empty ledger. An alert still open when the app quits is closed at the first
refresh of the next launch, so its clear time is then the relaunch time rather
than the moment the condition ended. Tests inject a temporary-directory
persistence; a store built without one keeps the history in memory.

### Notifications

`CriticalAlertNotifier` is the only code that touches `UNUserNotificationCenter`.
It exists only in the app's store (`MonitoringStore.forApplication()`); tests
construct stores without it. Nothing is requested from macOS until the user
turns on “Notify me about critical alerts” in Settings, which calls
`requestAuthorization([.alert, .sound])` once. `CriticalAlertNotificationPlanner`
(pure, tested) decides what to post: only `critical` severities, one
notification per refresh however many alerts it raised (up to three titles in
the body, then “and N more”), and a 10-minute per-alert-id cooldown so a
flapping mount or oscillating capacity cannot repeat. The notification carries
the alert title only; evidence, paths, device names and user names stay in the
app. Without a delegate, macOS does not show banners while LumeFS is frontmost.

### Snapshot export

`SnapshotExporter` serializes `MonitoringExport`: everything the UI currently
shows (volumes, device samples, NFS client counters, mount information, NFS
users, process I/O, quotas, active alerts, alert history) with the provenance
of every record and the app version. Nothing is re-collected at export time.
JSON is the full model with ISO-8601 dates; CSV is a long table
(`captured_at,category,identifier,metric,value,unit,provenance`) with RFC 4180
quoting and CRLF rows. NFS client addresses are masked to their network prefix
unless the user opted into full addresses in Settings, and the export records
which choice applied (`addressesMasked`). The destination comes only from
`NSSavePanel` (`SnapshotExportCoordinator`); the store never chooses a path.
File › Export Snapshot as JSON… (⇧⌘E) / as CSV… (⌥⇧⌘E) and the toolbar Export
menu use the same path.

## Process and trust boundaries

`SystemCommandRunner` uses Foundation `Process` with an absolute executable URL
and a separate argument array. It does not invoke a shell. The executable enum
contains only `/usr/sbin/diskutil`, `/usr/bin/nfsstat`, `/sbin/nfsd` (the
unprivileged `status` subcommand only), and `/usr/bin/quota`.

Current arguments are constructed by collectors. The runner rejects empty,
control-character, and over-4,096-byte arguments; enforces exact argument shapes
for each executable; supplies only `HOME`, a system-only `PATH`, and C locale
variables; terminates a command after five seconds with SIGTERM followed by
SIGKILL after 200 ms if needed; and rejects stdout or stderr larger than one MiB.
Mount points discovered from the operating system are the only variable
arguments: they reach `diskutil info -plist <path>` and
`nfsstat -m -f JSON <path>` and must begin with `/`. Every other argument list is
matched exactly (`nfsstat -f JSON -c`, `nfsstat -u -n net -f JSON`,
`nfsd status`, `quota -uv`).

The runner does not canonicalize that absolute mount path. Output-size
enforcement occurs after process exit. Those remaining gaps matter if future UI,
files, or network data can influence command arguments.

## Privacy boundary

Collection stays on the Mac. Capacity/I/O collectors do not open user files.
Opt-in FSEvents monitoring observes metadata events under a selected root but
emits only an aggregate root label and operation counts. The UI can display
mount paths, mount sources, device names, SMART text, quota output, the current
username, and the chosen folder's basename. Treat screenshots and recordings as
potentially identifying. The same fields leave the Mac only when the user
exports a snapshot to a location they choose; the alert-history file in
Application Support stores alert titles, messages and evidence strings, which
can name volumes, mounts, devices and NFS users. Notifications carry alert
titles only.

The App Sandbox is disabled in `project.yml`; Hardened Runtime is enabled. Any
distribution decision should review this boundary and the generated app's
entitlements rather than assuming sandbox protection.

## Failure model

Collectors favor a usable snapshot over propagating most errors:

- APFS failures retain unenriched mount data.
- NFS failures become `UNAVAILABLE`.
- Quota failures become an unavailable record containing the localized error.
- IOKit and mount-enumeration failures return empty arrays.

The UI does not currently expose a structured per-collector error ledger. A
quiet empty state can therefore mean “nothing observed” or “collection failed,”
depending on the collector.

Activity is session-only and capped at 200 newest events. When client layout
counters first become non-zero, the timeline records that NFSv4.1 layout
operations were observed as pNFS evidence; it does not claim mount attribution.

Alert history persists across launches; a failed write surfaces as a message in
the History pane and monitoring continues with the in-memory ledger. A failed
export leaves the previous successful export location unchanged, records no
Activity event, and is reported in a standard alert sheet on the main window.
