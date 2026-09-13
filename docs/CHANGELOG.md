# Changelog

All notable project changes will be documented here.

## [Unreleased]

### Added

- Per-mount NFS information (`nfsstat -m -f JSON <mount point>`): server, export,
  addresses, negotiated version and transport, mount parameters and kernel
  status flags, shown in the volume detail and on the Performance screen.
- Alert rules `nfs.mount.dead`, `nfs.mount.not_responding` (Critical) and
  `nfs.mount.recovery` (Warning) driven only by kernel flags on `LIVE` records.
- Attribution section: server-side per-user NFS activity from
  `nfsstat -u -n net -f JSON` (user, export, masked client address, request and
  byte deltas over the 3 s interval, idle time) with `nfsd status` context and
  an explicit unavailable state on a pure client.
- Alert rules `nfs.user.write_burst` and `nfs.user.request_burst` (Warning) with
  Settings-adjustable thresholds (defaults 100 MB/s and 1,000 requests/s).
- Local process disk I/O attribution (`sysctl` + `proc_pid_rusage`): name, PID,
  user, 2 s read/write deltas, cumulative bytes, readable / denied coverage
  counts, and a name-based AI-runtime hint.
- `SMARTAssessment` classification: `Not Supported`, `Unknown` and empty SMART
  strings are absence of data, only explicit failure wording is Critical, and
  unknown wording is a Notice.
- Alert history: every alert occurrence is tracked as active → acknowledged →
  cleared with timestamps, kept across launches in
  `~/Library/Application Support/LumeFS/alert-history.json` (500 entries, open
  alerts never trimmed, unreadable files set aside rather than deleted). The
  Alerts screen gains an Active / History switch, a lifecycle pane, an
  Acknowledge action and “Clear Closed…” with confirmation.
- Snapshot export as JSON or CSV from the File menu (⇧⌘E / ⌥⇧⌘E) and the
  toolbar: the latest snapshot with per-record timestamps and provenance plus
  the alert history; NFS client addresses masked unless the user opted into
  full addresses.
- APFS container and device pane in the volume detail (read-only, from the
  existing `diskutil info -plist` call): container reference, size and shared
  free space with a meter, physical stores, volume in use, encryption /
  FileVault / locked, sealed, solid-state / internal / bus protocol, volume
  UUID, plus `statfs` file-node counts. A “Copy verify command” button places
  `diskutil verifyVolume "<mount point>"` on the clipboard; LumeFS never runs
  `fsck`. Exports gain `file_nodes_used`, `apfs_container`,
  `apfs_container_free_bytes` and `apfs_encryption` volume rows.
- Quota administrator path made explicit: the volume detail states the
  current-user scope, gives APFS / NFS / other guidance, and copies
  `sudo repquota -a -v` to the clipboard (never executed, no password prompt);
  exports carry a `quotaCoverage` record and CSV `quota,coverage` rows.
- Opt-in macOS notifications for critical alerts (Settings › Notifications):
  one notification per refresh, 10-minute per-alert cooldown, alert title only,
  no permission request until enabled.
- Placement section (⌘6): choose a source folder or file and a writable volume
  or folder, run a dry-run plan (inventory, containment / existence /
  read-only checks, free space with the 20% margin, `ESTIMATE`), confirm once
  in a dialog that names both paths, then copy with progress and Cancel.
  Regular files use `copyfile(3)` with exclusive create, metadata
  preservation and APFS clone; each file is size-verified. The original is
  never deleted, moved or modified and nothing existing is overwritten, on
  every outcome. Plans and outcomes are journaled in
  `~/Library/Application Support/LumeFS/migration-journal.json` (200 entries)
  and posted to the Activity feed.
- Fixture tests for NFS mount parsing, SMART classification, IOKit
  deduplication, the extended command allowlist, alert-history reconciliation
  and persistence, the notification planner, and JSON/CSV export.

### Changed

- Capacity alerts from APFS volumes in the same container are grouped into one
  incident. The alert names every affected volume and opens the writable volume
  when one is available, so the standard macOS System/Data pair no longer looks
  like two separate disks have failed.
- `make build`, `make test`, and `make run` now use the checked-in Xcode project;
  XcodeGen is required only for the explicit `make generate` maintenance step.
- Benchmark: the write now bypasses the buffer cache (`F_NOCACHE`) and is
  flushed with `F_FULLFSYNC` (fallback `fsync`, reported); the read is split
  into an uncached pass (`F_NOCACHE`, read-ahead off, never-resident pages) and
  a cached pass (second normal read), both labeled. Sizes 128 / 256 / 512 /
  1,024 MiB are selectable and the run can be cancelled; the workspace is
  removed on every path. The internal ceiling moved from 256 MiB to 1,024 MiB
  because sub-100 ms passes on fast SSDs gave unstable rates; the 2× free-space
  guard is unchanged. `BenchmarkResult.readBytesPerSecond` /
  `readMayUseSystemCache` were replaced by `uncachedReadBytesPerSecond`,
  `cachedReadBytesPerSecond`, `writeUsedFullSync` and `writeBypassedCache`.
- Whole-device IOKit counters are deduplicated by `IOBlockStorageDriver`
  registry identity so “All devices” no longer double-counts a device that
  exposes several whole `IOMedia` nodes.
- The toolbar uses macOS 26 symbols only when compiled with Swift 6.2 or newer,
  so Xcode 16 / macOS 15 runners build the project.

## [1.0.0] - 2026-09-12

### Added

- Native macOS SwiftUI shell with Overview, Volumes, Performance, Activity,
  Alerts, volume detail, and Settings views.
- Mount discovery through `getfsstat` and APFS metadata enrichment through
  `diskutil` property-list output.
- Whole-device I/O sampling through IOKit.
- NFS client JSON parsing for RPC, NFSv3/NFSv4 operations, and selected NFSv4.1
  layout counters.
- Current-user quota collection with structured local/remote row parsing, raw
  evidence fallback, and explicit unavailable output.
- Configurable capacity alert thresholds connected to the alert engine.
- AI workload placement estimates with a 20% capacity margin and `ESTIMATE`
  provenance.
- Bounded 128 MiB UI benchmark with synchronized write, cleanup evidence, and
  `BENCHMARK` provenance.
- Bundled deterministic pNFS evidence preview labeled `REPLAY`.
- Opt-in FSEvents activity aggregation that emits root labels instead of event
  paths or file contents.
- Deterministic capacity, device-error, NFS-retry, and NFS-timeout alert rules.
- Tests for selected collectors, alert rules, command shapes, benchmark guards
  and cleanup, FSEvents redaction, workload estimates, formatting, structured
  quota rows, NFS parsing, live APFS metadata, and the opt-in localhost NFS lab.
- Architecture, metric, demo, NFS lab, contribution, and security documentation.
- Bounded local verification and localhost NFS lab scripts.
- GitHub Actions macOS build-and-test workflow.
- GitHub Actions dependencies pinned to the current v7.0.1 release commits.
- A finite source-publication gate covering build, UI, accessibility, live
  collectors, repository history, secret scanning, and a clean clone.

### Known limitations

- pNFS counters are system-wide observations and are not attributed to a mount
  or workload.
- Block I/O is whole-device rather than per-volume or per-process.
- Unrecognized quota output remains a raw all-filesystems message.
- Benchmark reads may use the macOS cache and are not raw-device measurements.
