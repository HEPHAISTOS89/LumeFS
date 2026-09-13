#!/usr/bin/env bash
# Cloud Agent (Linux) environment bootstrap for LumeFS.
#
# LumeFS is a native macOS SwiftUI application. Its build and test path
# (xcodebuild -destination 'platform=macOS', SwiftUI/AppKit/IOKit/CoreServices)
# can ONLY run on macOS with Xcode, which Cloud Agents (Linux) do not provide.
#
# This script installs the tooling for the subset of scripts/check.sh that is
# platform independent: repository documentation checks, markdown link
# validation, zsh shell-syntax checks, and gitleaks secret scanning.
set -euo pipefail

GITLEAKS_VERSION="8.30.1"

echo "==> Installing Linux-runnable check tooling (zsh, shellcheck, gitleaks)"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq zsh shellcheck

if ! command -v gitleaks >/dev/null 2>&1 || [ "$(gitleaks version 2>/dev/null || true)" != "${GITLEAKS_VERSION}" ]; then
    tmp="$(mktemp -d)"
    curl -fsSL \
        "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
        -o "${tmp}/gitleaks.tar.gz"
    tar -xzf "${tmp}/gitleaks.tar.gz" -C "${tmp}" gitleaks
    sudo install "${tmp}/gitleaks" /usr/local/bin/gitleaks
    rm -rf "${tmp}"
fi

echo "==> Installed versions"
zsh --version
shellcheck --version | grep '^version:' || true
gitleaks version
python3 --version

echo "==> Environment bootstrap complete"
echo "NOTE: Building/running the LumeFS app requires macOS + Xcode and cannot be done on Linux."
