#!/usr/bin/env bash
#
# install-gitleaks.sh — resolve a `gitleaks` binary for check-gitleaks-kernel.sh
# (foundation #798), installing a pinned release if one isn't already on PATH.
#
# Prints the resolved binary's path on stdout; installs nothing and prints
# nothing else. Cached under $XDG_CACHE_HOME (default ~/.cache) so a repeat
# run (or a repeat CI job on a warm cache) never re-downloads.
#
# This is a DELIBERATE, DOCUMENTED exception to "checks runs zero-network,
# dependency-free" (CLAUDE.md § CI & branch policy, ci.yml's own banner
# comment) — a real secret-scanner binary is not a shell/make/jq/python
# primitive a stock runner ships, and there's no way to get one without a
# fetch (a Docker-action pull is equally a network op). GitHub-hosted runners
# do have outbound internet despite that banner's "zero-network" framing (it
# describes what the OTHER gates need, not a hard sandbox); this is the one
# gate that spends it, and it's confined to gitleaks itself — everything else
# in scripts/quality-gates.sh stays exactly as dependency-free as before.
#
# Usage:
#   install-gitleaks.sh              print the resolved binary path
#
# Env overrides:
#   GITLEAKS_VERSION   pinned release version (default below)
#   GITLEAKS_BIN       skip resolution entirely; use this path verbatim if set
#                       and executable (test seam)

set -euo pipefail

: "${GITLEAKS_VERSION:=8.30.1}"

if [[ -n "${GITLEAKS_BIN:-}" && -x "${GITLEAKS_BIN}" ]]; then
  printf '%s\n' "$GITLEAKS_BIN"
  exit 0
fi

if command -v gitleaks >/dev/null 2>&1; then
  command -v gitleaks
  exit 0
fi

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/foundation/gitleaks/$GITLEAKS_VERSION"
BIN="$CACHE_DIR/gitleaks"

if [[ -x "$BIN" ]]; then
  printf '%s\n' "$BIN"
  exit 0
fi

os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux) plat="linux" ;;
  Darwin) plat="darwin" ;;
  *)
    echo "install-gitleaks: unsupported OS '$os' — install gitleaks manually and set GITLEAKS_BIN" >&2
    exit 1
    ;;
esac
case "$arch" in
  x86_64 | amd64) parch="x64" ;;
  arm64 | aarch64) parch="arm64" ;;
  *)
    echo "install-gitleaks: unsupported arch '$arch' — install gitleaks manually and set GITLEAKS_BIN" >&2
    exit 1
    ;;
esac

tarball="gitleaks_${GITLEAKS_VERSION}_${plat}_${parch}.tar.gz"
url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${tarball}"

mkdir -p "$CACHE_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if ! curl -fsSL "$url" -o "$tmp/$tarball"; then
  echo "install-gitleaks: failed to download $url" >&2
  echo "install-gitleaks: install gitleaks yourself (e.g. 'brew install gitleaks') and re-run, or set GITLEAKS_BIN" >&2
  exit 1
fi

tar -xzf "$tmp/$tarball" -C "$tmp" gitleaks
mv "$tmp/gitleaks" "$BIN"
chmod +x "$BIN"

printf '%s\n' "$BIN"
