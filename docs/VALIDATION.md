# Maintainer validation record

This record summarizes checks actually run on the source-release candidate on
2026-09-12. It is evidence for a hackathon source release, not certification of
a signed production binary.

## Environment

- Apple Silicon MacBook Pro
- macOS 26.6.2 (25G83)
- Xcode 26.6 (17F113)
- Apple Swift 6.3.3
- XcodeGen 2.46
- gitleaks 8.30

## Results

| Check | Observed result |
| --- | --- |
| Debug build-for-testing | Passed |
| Full suite without an active NFS lab | 32 executed, 30 passed, 2 expected live-NFS skips, 0 failures |
| Live APFS root integration | 1 passed, 0 skipped, 0 failures |
| Live localhost NFSv3 integration | 2 passed, 0 skipped, 0 failures |
| Working-tree secret scan | No findings |
| Full reachable Git history secret scan | 2 commits scanned, no findings |
| Repository integrity and dependency audit | `git fsck --full --strict` passed; no submodules or external packages |
| Unsigned arm64 Release build | Passed |
| Remote clean-clone check and unsigned Release build | Passed with a clean checkout before and after |
| GitHub Actions macOS build-and-test job | Passed on the source candidate |
| Release idle/runtime smoke observation | 32 seconds, no fatal/crash pattern, no benchmark workspace left behind |
| Native UI/AX smoke pass | LumeFS Overview rendered with live metrics and an accessible chart summary |

During the bounded runtime observation, sampled CPU varied from 1.1% to 8.5%
and resident memory rose from roughly 108 MiB to 122 MiB before remaining near
that level for the last samples. This short smoke observation is not a long-run
performance or leak proof.

## Real NFS evidence

The optional lab was exercised against macOS's loopback NFSv3 server:

- the mount collector discovered the mount as NFS and non-local;
- reading the fixture succeeded;
- the read-only server rejected a write probe;
- live `nfsstat` client requests and NFSv3 reads were non-zero;
- retry and timeout counters were zero during the check;
- NFSv4.1 layout counters remained zero, so this did not prove pNFS;
- cleanup removed the mount, managed export, temporary backup, and lab root;
- `/etc/exports` returned to its initially absent state, `nfsd` returned to
  stopped, and `/etc/nfs.conf` retained its pre-test hash.

The repository fixture demonstrates pNFS parser behavior only and is always
labeled `REPLAY`. A genuine external metadata/data-server topology remains
outside this validation record.

## Evidence boundaries

- `LIVE` NFS counters are system-wide client totals, not mount attribution.
- The I/O charts use whole-device counters, not per-process measurements.
- The benchmark is a bounded application-level check and may read from cache.
- Automated XCUITest, a long Instruments run, Developer ID signing, notarizing,
  and Gatekeeper assessment belong to the separate production-binary gate in
  [Verification and release gates](VERIFICATION.md).


## Local follow-up candidate — native design and quota integration

This section supersedes earlier counts for the updated local candidate, not the original source release:

- Final functional suite before publication: 55 tests, 53 passed, two expected NFS skips, zero failures.
- Separately, the read-only localhost NFSv3 lab was mounted and both live NFS tests passed with no skips. Cleanup was checked: managed export, mount and lab directory absent; nfsd stopped, its preexisting enabled state unchanged.
- Real APFS free capacity agreed with the app's rounded display and configured capacity alert.
- Real FSEvents create/modify/rename/remove operations were observed under an owned disposable folder; watching stopped and probe removed.
- Monitoring pause froze retained samples; resume produced new samples. Chart gaps remain visible rather than fabricated.
- System/light/dark themes and preference persistence were inspected. Vector assets are attributed in ICONOGRAPHY.md.
- Quota limits now influence placement and alerts. Regression tests cover filesystem names containing `none`, unrelated quotas and replay exclusion. No enforced remote quota was available for live validation.
- Current macOS nfs(5) says native-client pNFS is unsupported. Layout-counter parsing or a fixture does not override this limitation.
- Keyboard sidebar navigation and Settings/refresh shortcuts were exercised. Exhaustive focus traversal is not certified.
- VoiceOver was activated through its first-run dialog and stopped afterward. Automated retrieval of spoken phrases failed; no claim of complete VoiceOver validation is made.

No signed/notarized production binary is certified by these checks.

## 2026-09-13 — portable build and correctness batch

This batch was prepared by a cloud agent on a Linux host **without Xcode**. The
only compiler and test runner available to it was the GitHub Actions
`macos-15` (Xcode 16) job on pull request #2. Every claim below is either a CI
result with a run ID or explicitly `NOT RUN`.

| Check | Result | Evidence |
| --- | --- | --- |
| `main` before the batch (`a974413`) on `macos-15` | **FAILED** to compile: `ToolbarSpacer` / `sharedBackgroundVisibility` need the macOS 26 SDK | run 34730395087 |
| Batch 1 — compiler guard for macOS 26 symbols | Passed, 55 tests, 2 expected NFS skips | run 34731726706 |
| Batch 2 — SMART classification | Passed, 60 tests, 2 expected NFS skips | run 34731795277 |
| Batch 3 — IOKit deduplication (`36e7a69`) | Passed, 64 tests, 2 expected NFS skips | run 34731915138 |
| Batch 4 — documentation alignment (`f409144`) | Passed, 64 tests, 2 expected NFS skips | run 34732061946 |
| P1-5 — per-mount NFS (`nfsstat -m -f JSON`) (`69d51d9`) | Passed, 78 tests, 3 skips (NFS lab absent) | run 34732511600 |
| P1-6 — per-user NFS (`nfsstat -u`) (`2acc25d`) | Passed, 91 tests, 4 skips | run 34732995272 |
| P1-7 — process I/O attribution (`dfb0330`) | Passed, 97 tests, 4 skips | run 34733254509 |
| P1-8 — alert history, export, notifications (`663b624`) | Passed, 116 tests, 4 skips | run 34734065939 |
| P1-12 — benchmark uncached/cached passes (`bead331`) | Passed, 118 tests, 4 skips, no source warnings | run 34734354330 |
| P1-10 — APFS enrichment (`a8c52a0`) | Passed, 121 tests, 4 skips | run 34734589894 |
| P1-9 — quota administrator path (`7dd95b7`) | Passed, 123 tests, 4 skips | run 34734697640 |
| P1-11 — placement plan and additive copy, first push (`637f125`) | **FAILED**: 2 of 15 new tests — `FileManager.copyItem` on a dangling symbolic link threw “doesn't exist”; plan, `copyfile(3)` copy, cancellation and journal tests passed | run 34735589219 |
| P1-11 — `destinationOfSymbolicLink` + `createSymbolicLink` (`c525f3c`) | **FAILED** with the same message on the dangling link | run 34735873767 |
| P1-11 — links recreated with `readlink(2)` / `symlink(2)`, dangling link added to the fixture, labeled step errors (`c5baa7d`) | **FAILED**, but now with the real cause: “model.bin: outside the source tree” — `resolvingSymlinksInPath()` strips `/private` from the plan path while the URL enumerator yields `/private/var/...`, so prefix-based relative paths were wrong | run 34736169473 |
| P1-11 — copy walk switched to `enumerator(atPath:)` (relative paths) + `attributesOfItem` (lstat) | see the row appended below once the run completes | PR #2 |
| Placement copy on a real second volume / NAS | `NOT RUN` — tests use a temporary tree on one APFS volume (clone path); cross-volume `copyfile` data path and progress callbacks are exercised only by inspection | — |
| Live SMART `Failing` device | `NOT RUN` — no failing device available; the rule is covered by unit tests only | — |
| I/O trend comparison with `iostat` | `NOT RUN` in this environment; procedure below | — |
| Notification delivery, save panel export, `NSOpenPanel` flows | `NOT RUN` — need an interactive macOS session; the planners/exporters behind them are unit-tested | — |
| App launch, window sizes, Light/Dark, VoiceOver, ⌘1–⌘7 | `NOT RUN` — no macOS desktop in the agent environment | — |

The skips are the live NFS integration tests, which skip themselves when no
NFS mount is present on the runner. No test was disabled or weakened in this
batch.

### Manual I/O trend comparison (to run on a Mac)

The deduplicated “All devices” figure should follow the same trend as `iostat`
for the internal disk. Exact equality is not expected: `iostat` samples on its
own clock and reports KB/t and tps, while LumeFS reports bytes per second from
`IOBlockStorageDriver` counters.

```bash
iostat -d -w 1 disk0
```

While a large file copies, compare `MB/s` from `iostat` with the LumeFS
Performance view. Record the two series for ~30 s. Acceptance: the LumeFS total
is within roughly ±20% of `iostat` and, above all, is **not** about twice the
`iostat` figure, which was the symptom of the previous double counting. If a
second whole device appears in `iostat -d` (external disk), add it to the
comparison.
