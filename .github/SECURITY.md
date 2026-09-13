# Security policy

## Supported version

Security fixes are evaluated against the latest `1.x` source release and the
latest revision of the default branch.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting/security-advisory interface for
this repository when available. If it is unavailable, contact the repository
owner privately through their GitHub profile. Do not include secrets, private
mount paths, quota output, usernames, hostnames, or exploit data in a public
issue.

Include the affected commit and macOS version, entry point, required privileges,
exact observed behavior, a minimal synthetic reproduction, and the crossed
trust boundary. No response-time or disclosure deadline is promised while the
project remains a hackathon prototype.

## Current security boundary

- The application is local and contains no network client or telemetry path.
- The App Sandbox is disabled; Hardened Runtime is enabled.
- Storage metadata is collected through `getfsstat`, IOKit, `diskutil`,
  `nfsstat`, `nfsd status`, and `quota`.
- `diskutil`, `nfsstat`, `nfsd`, and `quota` are the only executable paths
  represented by the command-runner enum. For `nfsd` the runner accepts exactly
  `status`, which Apple's `nfsd` source treats as an unprivileged, read-only
  command; `start`, `stop`, `enable`, `disable`, `update` and `checkexports` are
  rejected.
- Per-process attribution reads only `kinfo_proc` identity fields,
  `proc_name` and `proc_pid_rusage` disk counters; it never reads arguments,
  environment, open files or paths, and it does not request the privileges
  needed to inspect other users' processes.
- NFS client addresses from `nfsstat -u` are collected numerically (no DNS
  lookup), masked to their network prefix in the UI by default, and always
  masked in alert text.
- Foundation `Process` receives an executable URL and argument array; no shell is
  invoked.
- Command arguments must match an executable-specific schema, commands are
  terminated after five seconds with SIGTERM/SIGKILL escalation, stdout/stderr
  are limited to one MiB each, and the child receives a minimal system-only
  environment.
- The automatic monitoring path does not request administrator privileges or
  modify mounts/files. The separately triggered benchmark writes one temporary
  file as described below.
- Manual benchmarking creates a fresh UUID-named workspace directly below the
  system temporary directory, writes only `sample.bin`, enforces a 256 MiB
  internal ceiling and two-times-free-space check, synchronizes the write, and
  removes the file and workspace. The UI requests 128 MiB.
- Opt-in FSEvents monitoring reports aggregate operations under a root label;
  emitted activity records do not contain individual event paths or contents.
- Alert history is written to
  `~/Library/Application Support/LumeFS/alert-history.json` (500 entries
  maximum, atomic writes). It contains alert titles, messages and evidence
  strings, which can include mount paths, device names, quota output and NFS
  user names with masked addresses. An unreadable file is set aside as
  `alert-history.unreadable.json`, never deleted.
- Snapshot export writes only to a location chosen in the standard save panel.
  The JSON/CSV contains the same fields the UI shows, including mount paths,
  device names, process names, the current username and quota output; NFS
  client addresses are masked unless the user enabled full addresses, and the
  file records which applied. Review an export before sharing it.
- macOS notifications are off by default; enabling them triggers the single
  system permission prompt. Only critical alerts are posted, the body is the
  alert title, and the same alert id is announced at most once per 10 minutes.
  No notification carries evidence, paths, addresses or user names.
- `scripts/nfs_lab.sh` is separate developer tooling. Its setup/cleanup actions
  require explicit confirmation and administrator authorization.

## Known hardening gaps

The current prototype should not be treated as security-hardened:

- the variable `diskutil` mount path is required to be absolute but is not
  canonicalized against the current mount inventory inside the runner;
- command output limits are checked after child-process completion;
- mount paths and quota output can be displayed, persisted in the alert
  history and exported without redaction;
- a watched folder's basename appears in the Activity view;
- quota command errors can surface localized stderr text in the UI;
- automated UI, accessibility, privacy-canary, and comprehensive live-collector
  tests are not present.

Do not widen the existing command shapes or route untrusted UI, file, or network
input into them without additional validation and tests.

## Local NFS lab

The lab intentionally changes `/etc/exports`, starts `nfsd`, and creates a local
mount. It is restricted to loopback and read-only export access, but it still
changes host configuration. Run `./scripts/nfs_lab.sh cleanup` immediately after
use. The lab does not establish pNFS support.

## Out of scope claims

LumeFS is not a malware scanner, data-loss-prevention system, disk repair
tool, SMART diagnostic replacement, access-control boundary, or guarantee of
storage availability. Alert recommendations require operator judgment.
