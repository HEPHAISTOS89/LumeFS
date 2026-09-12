#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly ROOT_DIR="${SCRIPT_DIR:h}"
readonly PROJECT_PATH="${ROOT_DIR}/LumeFS.xcodeproj"
readonly SCHEME="LumeFS"
readonly TIMEOUT_SECONDS="${LUMEFS_TIMEOUT_SECONDS:-900}"

if [[ ! "${TIMEOUT_SECONDS}" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "LUMEFS_TIMEOUT_SECONDS must be a positive integer."
    exit 2
fi

if [[ -n "${LUMEFS_ARTIFACTS_DIR:-}" ]]; then
    ARTIFACTS_DIR="${LUMEFS_ARTIFACTS_DIR:A}"
    mkdir -p "${ARTIFACTS_DIR}"
    CLEAN_ARTIFACTS=0
else
    ARTIFACTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lumefs-check.XXXXXX")"
    CLEAN_ARTIFACTS=1
fi
readonly ARTIFACTS_DIR CLEAN_ARTIFACTS
readonly DERIVED_DATA="${ARTIFACTS_DIR}/DerivedData"
readonly RESULT_BUNDLE="${ARTIFACTS_DIR}/LumeFSTests.xcresult"

cleanup() {
    if (( CLEAN_ARTIFACTS == 1 )); then
        rm -rf "${ARTIFACTS_DIR}"
    fi
}
trap cleanup EXIT

require_command() {
    local command_name="$1"
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        print -u2 "Missing required command: ${command_name}"
        exit 127
    fi
}

run_with_timeout() {
    local seconds="$1"
    shift

    /usr/bin/python3 - "${seconds}" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout = int(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(command, start_new_session=True)

try:
    raise SystemExit(process.wait(timeout=timeout))
except subprocess.TimeoutExpired:
    print(f"Timed out after {timeout}s: {' '.join(command)}", file=sys.stderr)
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    raise SystemExit(124)
PY
}

check_required_files() {
    local required_files=(
        README.md LICENSE project.yml LumeFS.xcodeproj/project.pbxproj
        docs/ARCHITECTURE.md docs/METRICS.md docs/DEMO.md docs/NFS_LAB.md
        docs/VALIDATION.md docs/VERIFICATION.md docs/CHANGELOG.md
        .github/CONTRIBUTING.md .github/SECURITY.md
        .github/workflows/ci.yml scripts/check.sh scripts/nfs_lab.sh
    )

    local relative_path
    for relative_path in "${required_files[@]}"; do
        if [[ ! -f "${ROOT_DIR}/${relative_path}" ]]; then
            print -u2 "Missing required file: ${relative_path}"
            return 1
        fi
    done
}

check_local_markdown_links() {
    /usr/bin/python3 - "${ROOT_DIR}" <<'PY'
from pathlib import Path
from urllib.parse import unquote
import re
import sys

root = Path(sys.argv[1]).resolve()
documents = [root / "README.md"]
documents.extend(sorted((root / "docs").glob("*.md")))
documents.extend(sorted((root / ".github").glob("*.md")))
pattern = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
failures = []

for document in documents:
    for target in pattern.findall(document.read_text(encoding="utf-8")):
        target = target.strip().split(" ", 1)[0]
        if target.startswith(("#", "http://", "https://", "mailto:")):
            continue
        resolved = (document.parent / unquote(target.split("#", 1)[0])).resolve()
        try:
            resolved.relative_to(root)
        except ValueError:
            failures.append(f"{document.relative_to(root)}: escapes repository: {target}")
            continue
        if not resolved.exists():
            failures.append(f"{document.relative_to(root)}: missing target: {target}")

if failures:
    print("\n".join(failures), file=sys.stderr)
    raise SystemExit(1)
PY
}

require_command git
require_command xcodebuild
require_command python3
cd "${ROOT_DIR}"

print "==> Environment"
sw_vers
xcodebuild -version
swift --version
print "Commit: $(git rev-parse HEAD)"

print "==> Repository documentation and script syntax"
check_required_files
check_local_markdown_links
/bin/zsh -n scripts/check.sh scripts/nfs_lab.sh

print "Shell syntax checked with zsh -n."

if command -v gitleaks >/dev/null 2>&1; then
    print "==> Secret scan of the current working tree"
    gitleaks dir "${ROOT_DIR}" --no-banner --redact
elif [[ "${LUMEFS_REQUIRE_GITLEAKS:-0}" == "1" ]]; then
    print -u2 "gitleaks is required but not installed."
    exit 127
else
    print "NOTE: gitleaks is not installed; secret scanning was not run."
fi

print "==> Build for testing (one attempt, ${TIMEOUT_SECONDS}s limit)"
run_with_timeout "${TIMEOUT_SECONDS}" \
    xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGNING_ALLOWED=NO \
    clean build-for-testing \
    | tee "${ARTIFACTS_DIR}/build.log"

print "==> Test without rebuilding (one attempt, ${TIMEOUT_SECONDS}s limit)"
run_with_timeout "${TIMEOUT_SECONDS}" \
    xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA}" \
    -resultBundlePath "${RESULT_BUNDLE}" \
    CODE_SIGNING_ALLOWED=NO \
    test-without-building \
    | tee "${ARTIFACTS_DIR}/test.log"

print "==> Check complete"
if (( CLEAN_ARTIFACTS == 0 )); then
    print "Evidence: ${ARTIFACTS_DIR}"
else
    print "Temporary evidence will now be removed. Set LUMEFS_ARTIFACTS_DIR to retain it."
fi
