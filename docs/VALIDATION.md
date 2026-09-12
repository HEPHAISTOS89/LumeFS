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
| Unsigned arm64 Release build | Passed |
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
