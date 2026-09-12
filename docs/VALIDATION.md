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
