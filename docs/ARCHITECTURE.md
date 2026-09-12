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
    ├── NFSCollector ─────────────── nfsstat -f JSON -c
    ├── QuotaCollector ───────────── quota -uv
    └── AlertRuleEngine ──────────── deterministic rules

Opt-in/manual paths owned by MonitoringStore
    ├── FileActivityCollector ────── FSEvents, aggregated to root labels
    ├── DiskBenchmark ────────────── app-owned temporary file
    ├── WorkloadReadinessCalculator 20% capacity-margin estimate
    └── pNFS replay ──────────────── bundled JSON fixture
```

There is no backend, account system, telemetry service, cloud database, or
third-party runtime package in the current project.

## UI and state

`LumeFSApp` creates one `MonitoringStore`. `AppShellView` exposes five
navigation sections:

- Overview
- Volumes, including an in-place volume detail pane
- Performance
- Activity
- Alerts, including an in-place evidence pane

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

It can replace the volume name and add SMART status, `CapacityQuota`, and
`CapacityReserve`. Capacity and available bytes remain the `getfsstat` values;
the collector deliberately does not substitute `APFSContainerFree`.

If collection or property-list parsing fails, the original mount snapshot is
retained without an explicit error field.

### BlockIOCollector

IOKit is queried for whole `IOMedia` services. The collector reads cumulative
bytes, operations, errors, and retries. Bytes and operations are converted to
rates by subtracting the prior sample and dividing by elapsed time.

- The first sample for a device reports zero rates.
- A counter decrease reports zero for that rate.
- Samples are whole-device observations and are not attributed to a mount,
  process, path, model, or dataset.

### NFSCollector

The collector executes `/usr/bin/nfsstat -f JSON -c`. It parses system-wide
client RPC counters, NFSv3/NFSv4 read and write operations, and selected NFSv4.1
layout counters. Parse or execution failure returns one `UNAVAILABLE` value
instead of stale live data.

The counters are cumulative at the client level. The engine compares retry and
timeout counters every NFS collection interval to create alerts. They are not
attributed to a specific server or mount.

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

The Performance view runs a fixed 128 MiB benchmark. `DiskBenchmark` permits
1–256 MiB internally, requires at least twice the requested size in reported
free space, creates a previously absent UUID-named workspace directly below
`FileManager.temporaryDirectory`, and writes deterministic bytes only to
`sample.bin`. It synchronizes and immediately reads the file, then removes the
file and workspace; a deferred workspace removal covers thrown errors. The
immediate read may use the macOS cache. There is no explicit wall-clock timeout,
so the size bound—not a time bound—limits the operation.

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

Alerts are recomputed on every refresh; there is no persistent acknowledgement,
history database, or notification delivery subsystem.

## Process and trust boundaries

`SystemCommandRunner` uses Foundation `Process` with an absolute executable URL
and a separate argument array. It does not invoke a shell. The executable enum
contains only `/usr/sbin/diskutil`, `/usr/bin/nfsstat`, and `/usr/bin/quota`.

Current arguments are constructed by collectors. The runner rejects empty,
control-character, and over-4,096-byte arguments; enforces exact argument shapes
for each executable; supplies only `HOME`, a system-only `PATH`, and C locale
variables; terminates a command after five seconds with SIGTERM followed by
SIGKILL after 200 ms if needed; and rejects stdout or stderr larger than one MiB.
Mount points discovered from the operating system can reach `diskutil` as the
only variable argument and must begin with `/`.

The runner does not canonicalize that absolute mount path. Output-size
enforcement occurs after process exit. Those remaining gaps matter if future UI,
files, or network data can influence command arguments.

## Privacy boundary

Collection stays on the Mac. Capacity/I/O collectors do not open user files.
Opt-in FSEvents monitoring observes metadata events under a selected root but
emits only an aggregate root label and operation counts. The UI can display
mount paths, mount sources, device names, SMART text, quota output, the current
username, and the chosen folder's basename. Treat screenshots and recordings as
potentially identifying.

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
