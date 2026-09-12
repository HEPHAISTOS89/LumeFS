# Verification and release gates

LumeFS separates the evidence needed to publish the hackathon source from
the stronger evidence needed to distribute a signed production binary. A parser
fixture, replay, estimate, or benchmark is never counted as live-system proof.

## Evidence rules

For every check, record the commit, host toolchain, exact command, exit status,
and whether the evidence is `LIVE`, `BENCHMARK`, `ESTIMATE`, `REPLAY`, or
`UNAVAILABLE`. `PASS` means the check was actually run. Unknown work stays
`NOT RUN` or `BLOCKED`.

The retry budget is finite:

1. run the smallest relevant check while developing;
2. run each affected gate once when the change is stable;
3. diagnose a deterministic failure before changing code or rerunning it;
4. permit one rerun only after a relevant change;
5. treat an unexplained pass-on-retry as flaky;
6. run the complete source-publication gate once on the final clean commit.

## Gate A — hackathon source publication

This is the gate for making the GitHub repository public and tagging a source
release. It does not authorize distribution of a signed/notarized app binary.

### A1. Build and deterministic tests

```bash
LUMEFS_REQUIRE_GITLEAKS=1 \
LUMEFS_ARTIFACTS_DIR="$EVIDENCE/local-check" \
./scripts/check.sh
```

Acceptance:

- the checked-in Xcode project builds without XcodeGen;
- all committed tests pass once with no unexpected skips; the two opt-in live
  NFS checks are expected to skip when the localhost lab is absent;
- Markdown links and shell syntax pass;
- the current-tree secret scan reports no findings;
- build/test logs and the `.xcresult` bundle are retained outside the repo.

The suite covers APFS/NFS/quota parsers, command shapes, alert rules, workload
estimates, benchmark guards/cleanup, FSEvents aggregation/redaction, and metric
formatting. It is not proof of a real pNFS deployment.

### A2. Manual native UI and accessibility pass

Use the exact Debug or Release app produced from the candidate commit. At the
smallest supported 900 × 600 window and at the default size, verify:

- Overview, Volumes, Performance, Activity, Alerts, and Settings open;
- the app remains readable in light and dark appearance;
- live, unavailable, benchmark, estimate, and replay states are labeled;
- keyboard shortcuts for refresh and Settings work;
- accessible names/values exist for navigation, controls, status, charts, and
  sliders;
- the 128 MiB benchmark reports completion and leaves no workspace;
- pNFS replay is visibly `REPLAY` and does not replace live counters;
- opt-in FSEvents activity reports aggregate operations without an event path.

Record failures honestly. Manual inspection is sufficient for the hackathon
source gate; automated XCUITest and Accessibility Inspector coverage remain a
production-hardening item.

### A3. Live collector checks

Run the app for at least two refresh cycles and compare its claims with the
system sources:

| Feature | Source | Required source-release evidence |
| --- | --- | --- |
| APFS capacity | `getfsstat(2)` and `diskutil info -plist /` | root appears; capacity is non-negative; metadata failure does not replace capacity |
| Whole-device I/O | IOKit `IOMedia` statistics | samples update; first/reset samples never become negative |
| NFS client | `nfsstat -f JSON -c` | live or explicit unavailable state |
| Current-user quota | `quota -uv` | structured recognized row, raw fallback, or explicit unavailable state |
| File activity | FSEvents under a disposable folder | aggregate create/modify/rename/delete evidence with no event path in app state |

A real NFS server is not required by the challenge environment. When
administrator authorization is available, the optional localhost lab adds
NFSv3 mount-discovery evidence:

```bash
./scripts/nfs_lab.sh validate
LUMEFS_NFS_LAB_CONFIRM=YES ./scripts/nfs_lab.sh setup
./scripts/nfs_lab.sh status
./scripts/nfs_lab.sh cleanup
./scripts/nfs_lab.sh status
```

The lab must be read-only and loopback-only. Cleanup must remove the managed
mount/export and restore the prior `/etc/exports` and `nfsd` state. It never
proves pNFS. pNFS remains system-wide client counter parsing plus visibly
separate deterministic replay unless a genuine external pNFS topology is
available.

### A4. Repository and history audit

On the candidate commit:

```bash
git diff --check
git status --porcelain
git fsck --full --strict
gitleaks git . --no-banner --redact --log-opts='--all'
git submodule status
git rev-list --objects --all |
  git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)'
```

Acceptance:

- the worktree is clean and repository integrity passes;
- the full reachable history has no secret finding;
- no unexpected submodule, package dependency, binary archive, build product,
  private screenshot, or oversized object exists;
- `LICENSE` is MIT and all committed assets/fixtures are project-owned or
  otherwise compatible;
- README claims match the code and the observed evidence.

### A5. Clean-clone release build

```bash
SOURCE="$(git rev-parse --show-toplevel)"
REVISION="$(git rev-parse HEAD)"
CLONE_ROOT="$(mktemp -d)"
git clone --no-local "$SOURCE" "$CLONE_ROOT/LumeFS"
cd "$CLONE_ROOT/LumeFS"
test "$(git rev-parse HEAD)" = "$REVISION"
test -z "$(git status --porcelain)"
LUMEFS_ARTIFACTS_DIR="$CLONE_ROOT/evidence" ./scripts/check.sh
xcodebuild \
  -project LumeFS.xcodeproj \
  -scheme LumeFS \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$CLONE_ROOT/ReleaseData" \
  CODE_SIGNING_ALLOWED=NO \
  build
test -z "$(git status --porcelain)"
```

Acceptance: clone, checks, tests, and unsigned Release build all pass without
mutating the checkout.

## Gate B — signed production binary

Gate B is deliberately not implied by a public source release. Before shipping
a downloadable app binary, add and pass:

- deterministic macOS XCUITest navigation and state coverage;
- `XCUIApplication.performAccessibilityAudit()` plus keyboard/VoiceOver review;
- privacy-canary scanning of screenshots, logs, and exports;
- a Release Instruments run measuring refresh latency, CPU, memory growth, main
  thread stalls, and a single bounded benchmark;
- streaming stdout/stderr enforcement in `SystemCommandRunner`;
- canonical mount-inventory validation immediately before `diskutil` launch;
- Developer ID signing, `codesign --verify --deep --strict`, notarization,
  stapling, and Gatekeeper assessment.

Until Gate B passes, publish source only and describe local builds as ad hoc or
unsigned development builds.

## Known boundaries

- command output above one MiB is rejected after child completion rather than
  stopped while streaming;
- the `diskutil` variable path originates from the OS mount inventory but is not
  independently canonicalized inside the runner;
- mount paths, device names, quota output, usernames, and watched-root labels can
  appear in the UI and must be reviewed before screenshots are shared;
- pNFS counters are system-wide and cannot prove mount attribution or parallel
  data-server traffic;
- block I/O is whole-device, not per-process or per-volume;
- benchmark reads may be served by the macOS cache.
