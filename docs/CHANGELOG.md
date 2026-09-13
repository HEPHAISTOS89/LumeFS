# Changelog

All notable project changes will be documented here.

## [Unreleased]

### Added

- Per-mount NFS information (`nfsstat -m -f JSON <mount point>`): server, export,
  addresses, negotiated version and transport, mount parameters and kernel
  status flags, shown in the volume detail and on the Performance screen.
- Alert rules `nfs.mount.dead`, `nfs.mount.not_responding` (Critical) and
  `nfs.mount.recovery` (Warning) driven only by kernel flags on `LIVE` records.
- `SMARTAssessment` classification: `Not Supported`, `Unknown` and empty SMART
  strings are absence of data, only explicit failure wording is Critical, and
  unknown wording is a Notice.
- Fixture tests for NFS mount parsing, SMART classification, IOKit
  deduplication, and the extended command allowlist.

### Changed

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
