#!/usr/bin/env bash
#
# Build, codesign, install and reload a locally built yabai.
#
# Run this from anywhere; it locates the repository relative to this script.
#
# Usage:
#   scripts/deploy.sh [BIN_DIR] [SIGNING_IDENTITY]
#
# Environment overrides:
#   YABAI_BIN_DIR   target directory for the binary (default: /usr/local/bin)
#   YABAI_CERT      code-signing identity to use   (default: yabai-cert)
#
# The default signing identity ("yabai-cert") keeps a stable designated
# requirement between rebuilds, so the Accessibility grant and any
# sudoers rule survive. If it does not exist, an ad-hoc signature is used
# and the Accessibility grant has to be re-added after every rebuild.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BIN_DIR="${1:-${YABAI_BIN_DIR:-/usr/local/bin}}"
CERT="${2:-${YABAI_CERT:-yabai-cert}}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcrun >/dev/null    || die "xcrun not found; install the Xcode Command Line Tools: xcode-select --install"
command -v codesign >/dev/null || die "codesign not found"
[ -d "${BIN_DIR}" ]            || die "binary directory does not exist: ${BIN_DIR}"

say "Building yabai (${REPO_DIR})"
( cd "${REPO_DIR}" && make install )

BINARY="${REPO_DIR}/bin/yabai"
[ -x "${BINARY}" ] || die "build did not produce ${BINARY}"

if security find-identity -p codesigning 2>/dev/null | grep -qF "\"${CERT}\""; then
    say "Signing with identity '${CERT}'"
    codesign --force --sign "${CERT}" "${BINARY}"
else
    warn "no code-signing identity named '${CERT}' found; falling back to ad-hoc signing"
    warn "the Accessibility grant will need to be re-added after every rebuild"
    warn "create a self-signed '${CERT}' certificate in Keychain Access to avoid this"
    codesign --force --sign - "${BINARY}"
fi

codesign --verify "${BINARY}" >/dev/null 2>&1 || die "code signature verification failed"

TARGET="${BIN_DIR}/yabai"
if [ -w "${BIN_DIR}" ]; then
    say "Installing to ${TARGET}"
    install -m 755 "${BINARY}" "${TARGET}"
else
    say "Installing to ${TARGET} (requires sudo)"
    sudo install -m 755 "${BINARY}" "${TARGET}"
fi

if [ -f "${HOME}/Library/LaunchAgents/com.asmvik.yabai.plist" ]; then
    say "Restarting yabai service"
    "${TARGET}" --restart-service || warn "could not restart service; run '${TARGET} --restart-service' manually"
else
    say "No launchd service installed yet; start it with: ${TARGET} --start-service"
fi

if sudo -n "${TARGET}" --load-sa >/dev/null 2>&1; then
    say "Scripting-addition loaded"
else
    warn "could not load the scripting-addition without a password"
    warn "add a sudoers rule allowing: $(id -un) ALL=(root) NOPASSWD: ${TARGET} --load-sa"
    warn "then load it manually with: sudo ${TARGET} --load-sa"
fi

say "Done: ${TARGET} $("${TARGET}" --version 2>/dev/null || echo '(version unknown)')"
