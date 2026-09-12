# Contributing to LumeFS

Thank you for improving LumeFS. Storage tools can create false confidence or
cause damage when provenance and system boundaries are vague, so contributions
must remain small, reviewable, and evidence-backed.

## Development setup

Requirements:

- macOS 14 or newer;
- Xcode with a macOS 14 SDK or newer;
- XcodeGen only when changing `project.yml` or regenerating the project.

Run the repository check before opening a pull request:

```bash
./scripts/check.sh
```

The check performs one build and one test run with finite timeouts. Do not rerun
an unchanged deterministic failure until its cause is understood.

## Change discipline

- Keep changes focused; avoid unrelated generated-project churn.
- Prefer native APIs over subprocesses.
- Never introduce shell command construction from strings.
- Do not add deletion, mount mutation, benchmark writes, or service changes to
  the monitoring path.
- Do not add telemetry or network transmission without a documented privacy and
  consent review.
- Treat paths, usernames, quota text, hostnames, and mount sources as private.
- Add tests for parsers, arithmetic, counter resets, unavailable states, and any
  new alert rule.

## Provenance requirements

Every sample shown to a user must retain its origin:

- `LIVE` only for current local collection;
- `BENCHMARK` only for a bounded synthetic benchmark;
- `REPLAY` only for a recorded fixture;
- `UNAVAILABLE` when no supported value exists.

Do not turn a fixture into a live claim by changing a label in a view. A new
producer must propagate provenance through the model, alert, and UI layers.

## Command-runner changes

The current executable allowlist contains only `diskutil`, `nfsstat`, and
`quota`, with executable-specific argument schemas, a five-second timeout, and a
one-MiB stdout/stderr limit. A new executable or argument shape requires:

1. a written need that cannot be met through a native API;
2. an absolute executable path;
3. an update to the typed per-command argument schema;
4. explicit timeout and output-size behavior;
5. tests using hostile strings, leading options, control characters, and long
   output;
6. documentation in `docs/ARCHITECTURE.md` and `docs/METRICS.md`.

## Tests and evidence

Pull requests should state:

- commands actually run;
- pass, failure, and not-run status separately;
- whether data was live, benchmark, replay, or unavailable;
- the macOS and Xcode versions for live-collector changes;
- whether an NFS test used a real mount or only parser fixtures.

A passing parser test is not proof that a live NFS server, pNFS path, SMART
device, quota, or UI flow was exercised.

Before a public release, follow the finite gate and evidence requirements in
[`docs/VERIFICATION.md`](../docs/VERIFICATION.md). Development checks alone are
not publication approval.

## Generated project

`project.yml` is the editable project specification. When it changes:

```bash
xcodegen generate
git diff -- LumeFS.xcodeproj
./scripts/check.sh
```

Commit the specification and corresponding generated project together. Do not
regenerate the project for documentation-only changes.

## Commit and pull-request checklist

- [ ] Scope is narrow and the working tree contains no unrelated changes.
- [ ] `./scripts/check.sh` was run once on the final change.
- [ ] New metrics have an exact source, unit, scope, cadence, and provenance.
- [ ] Error/unavailable behavior is visible and tested.
- [ ] No secret, personal path, hostname, or private command output is included.
- [ ] Documentation describes limitations without overstating live validation.
- [ ] System-level lab changes were cleaned up.
