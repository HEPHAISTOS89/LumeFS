<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="LumeFS app icon">
</p>

<h1 align="center">LumeFS</h1>

<p align="center"><strong>Native macOS storage evidence for local AI workloads.</strong></p>

<p align="center">
  <a href="https://github.com/HEPHAISTOS89/LumeFS/actions/workflows/ci.yml"><img src="https://github.com/HEPHAISTOS89/LumeFS/actions/workflows/ci.yml/badge.svg" alt="macOS build and test"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14 or newer">
  <img src="https://img.shields.io/badge/SwiftUI-native-0A84FF" alt="Native SwiftUI">
  <img src="https://img.shields.io/badge/license-MIT-34C759" alt="MIT License">
</p>

LumeFS is a native macOS storage monitor for local AI workloads. It brings
capacity, whole-device I/O, APFS metadata, NFS client counters, quota output,
and evidence-backed alerts into one SwiftUI application.

LumeFS is an observability tool. It does not repair disks, change mounts,
delete user files, or tune NFS. Its manual benchmark creates and removes one
app-owned temporary file. Alert recommendations are guidance, not automated
actions.

## The problem

Model training, checkpoints, datasets, and caches can consume local or shared
storage quickly. macOS exposes the relevant signals through several unrelated
interfaces, which makes it difficult to answer simple operational questions:

- Which visible volume is closest to full?
- Is the machine reading or writing heavily right now?
- Did the NFS client begin retrying or timing out?
- Is a displayed number live, unavailable, or from a controlled demonstration?

LumeFS collects those signals locally and presents the evidence next to the
alert that used it.

## What is implemented

- Overview of `/`, volumes mounted below `/Volumes`, and NFS mounts.
- APFS mount capacity plus SMART status, reserve, and quota metadata when
  `diskutil` provides those fields.
- Whole-device read/write rates and error counters from IOKit.
- System-wide NFS client RPC and NFSv4.1 layout counters from `nfsstat`.
- Current-user quota rows parsed into byte limits when recognized, with raw
  evidence fallback and an explicit unavailable state.
- A 128 MiB bounded temporary-file benchmark with explicit `BENCHMARK`
  provenance and cleanup status.
- A workload-placement estimate with a 20% capacity margin.
- Opt-in FSEvents monitoring that reports aggregate operations under a selected
  root label without displaying event paths or reading file contents.
- A bundled pNFS JSON replay, visibly labeled `REPLAY`, for deterministic parser
  evidence when live pNFS counters are absent.
- Capacity, storage-error, NFS-timeout, and NFS-retry alerts with evidence and a
  recommended next step.
- Native SwiftUI views for Overview, Volumes, I/O Performance, Activity, and
  Alerts, plus a Settings window.

See [Metrics](docs/METRICS.md) for exact definitions and caveats.

## Data provenance

The model defines five provenance labels:

| Label | Meaning in the current code |
| --- | --- |
| `LIVE` | Collected on this Mac from a native API or an allowlisted system command. |
| `UNAVAILABLE` | Collection failed or the operating system did not provide the metric. |
| `BENCHMARK` | Produced by the app's bounded temporary-file benchmark. |
| `ESTIMATE` | Deterministic calculation from a chosen workload size and observed free capacity. |
| `REPLAY` | Decoded from the bundled pNFS JSON fixture, never presented as live. |

Throughput views derive provenance from the latest device sample and show
`UNAVAILABLE` when no sample exists. A `LIVE` sample still proves only that the
IOKit collector observed a whole device, not that a particular workload or pNFS
data path caused the activity.

## Architecture and sources

LumeFS uses no third-party runtime dependencies.

| Signal | Source | Scope |
| --- | --- | --- |
| Mounted volumes and capacity | `getfsstat(2)` | Visible APFS/NFS mounts |
| APFS metadata | `/usr/sbin/diskutil info -plist` | One discovered APFS mount at a time |
| Block I/O | IOKit `IOMedia` statistics | Whole devices, not individual processes or files |
| NFS client metrics | `/usr/bin/nfsstat -f JSON -c` | System-wide cumulative client counters |
| Quota status | `/usr/bin/quota -uv` | Current user; recognized local/remote rows plus raw fallback |

The refresh loop runs once per second. Block I/O is sampled each refresh; mounts
and APFS metadata are refreshed every 10 cycles, NFS every 3 cycles, and quota
every 30 cycles after their initial collection.

Read [Architecture](docs/ARCHITECTURE.md) for the component and trust-boundary
details.

## Requirements

- macOS 14 or newer.
- Xcode with the macOS 14 SDK or newer.
- XcodeGen only when regenerating `LumeFS.xcodeproj` from `project.yml`.

No NFS server is required to build or run the app. The optional local NFS lab
requires administrator authorization because it changes `/etc/exports`, starts
the macOS NFS daemon, and creates a local mount.

## Build and test

Run the bounded repository check:

```bash
./scripts/check.sh
```

It performs documentation/shell checks, a Debug build-for-testing, and one test
run. It does not retry failures. Build products are placed in a temporary
directory unless `LUMEFS_ARTIFACTS_DIR` is set.

To build directly from the checked-in Xcode project:

```bash
xcodebuild \
  -project LumeFS.xcodeproj \
  -scheme LumeFS \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  build
```

To regenerate the project and run the app:

```bash
brew install xcodegen   # only if xcodegen is missing
make run
```

`make run` regenerates the Xcode project before building. Review the generated
project diff before committing it.

## Demo

Use the bounded [2–3 minute demo script](docs/DEMO.md). If an NFS mount is useful
for the demonstration, follow [the NFS lab procedure](docs/NFS_LAB.md) and run
its cleanup step afterward.

## Privacy and security

- Collection is local; the source tree contains no analytics or network client.
- LumeFS does not inspect file contents.
- Mount paths, device names, quota command output, and the current username can
  appear in the UI. Do not publish screenshots without reviewing them.
- The app is currently built with the App Sandbox disabled because it reads
  system storage interfaces. Hardened Runtime is enabled.
- System commands are launched with `Process.executableURL` and argument arrays,
  not through a shell. The executable set is limited to `diskutil`, `nfsstat`,
  and `quota`.
- The runner enforces a per-command argument shape, rejects control characters,
  uses a minimal system-only environment, terminates after five seconds with
  SIGTERM/SIGKILL escalation, and caps stdout/stderr at one MiB each.

See [Security policy](.github/SECURITY.md) for reporting and the current security
boundary. The finite [verification and publication plan](docs/VERIFICATION.md)
defines the evidence required before release.

## Important limitations

- **pNFS:** non-zero NFSv4.1 layout counters mean that pNFS-related operations
  were observed somewhere on the client. They do not prove that a particular
  mount or current workload used a pNFS data path. The local lab validates NFSv3,
  not pNFS.
- Block-I/O metrics are whole-device totals. They are not per-volume,
  per-process, or specific to an AI workload.
- APFS capacity remains the `getfsstat` value; `diskutil` enriches metadata but
  does not replace capacity.
- Recognized quota rows are mapped by their filesystem string; unrecognized
  output remains one raw, all-filesystems message.
- Settings thresholds are persisted and read on refresh; they are not versioned
  with historical alerts.
- Benchmark reads happen immediately after writes and may be served by the
  macOS cache; results are not raw-device performance.
- FSEvents monitoring is opt-in and aggregate, but selected root labels can still
  disclose folder names in the Activity view.
- The current test suite covers selected collectors, command shapes, benchmark
  guardrails/cleanup, FSEvents aggregation/redaction, alert thresholds,
  readiness calculations, formatting, structured quota rows, and NFS parsing.
  It is not an end-to-end proof of every live collector, pNFS environment, or UI
  flow.

## Project documents

- [Architecture](docs/ARCHITECTURE.md)
- [Metric definitions](docs/METRICS.md)
- [Demo script](docs/DEMO.md)
- [Local NFS lab and rollback](docs/NFS_LAB.md)
- [Maintainer validation record](docs/VALIDATION.md)
- [Verification and publication plan](docs/VERIFICATION.md)
- [Contributing](.github/CONTRIBUTING.md)
- [Security](.github/SECURITY.md)
- [Changelog](docs/CHANGELOG.md)

## License

LumeFS is available under the [MIT License](LICENSE).
