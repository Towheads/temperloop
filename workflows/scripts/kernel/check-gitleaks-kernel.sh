#!/usr/bin/env bash
#
# check-gitleaks-kernel.sh — run gitleaks over the kernel file set (foundation
# #798, epic #762 kernel extraction). Complements
# check-personal-token-denylist.sh: that script catches PERSONAL TOKENS (org
# names, handles, paths, emails — not secrets by gitleaks' own detectors);
# this one catches actual SECRETS (API keys, tokens, private keys) using
# gitleaks' standard detector rules, so the two together cover "no
# personal/org tokens" AND "no credentials" in what ships to the public
# kernel repo.
#
# gitleaks scans a plain directory (`--no-git`), not an arbitrary file list,
# so this copies the kernel-set files (per list-kernel-set.sh) into a throwaway
# tmpdir preserving relative paths, then points gitleaks at that copy. This
# also means gitleaks' git-history scanning never runs here — intentional:
# the manifest classifies the CURRENT tree, not history, and a history scan
# would need the whole repo (defeating the point of scoping to the kernel
# set) — see foundation #798's build verification doc for the scoping call.
#
# Usage:
#   check-gitleaks-kernel.sh [--root DIR]
#   (called by `make test-kernel-gitleaks`)
#
# Env overrides:
#   KERNEL_MANIFEST_ROOT, KERNEL_MANIFEST_FILE (fixture-driven tests)
#   GITLEAKS_BIN   use this binary verbatim instead of resolving one

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

: "${KERNEL_MANIFEST_ROOT:=$REPO_ROOT}"

gitleaks_bin="$("$SCRIPT_DIR/install-gitleaks.sh")" || exit 1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

n=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  src="$KERNEL_MANIFEST_ROOT/$f"
  [[ -f "$src" ]] || continue
  dest="$tmp/$f"
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  n=$((n + 1))
done < <("$SCRIPT_DIR/list-kernel-set.sh" --root "$KERNEL_MANIFEST_ROOT")

echo "check-gitleaks-kernel: scanning $n kernel file(s) with $gitleaks_bin"

set +e
"$gitleaks_bin" detect --no-git --source "$tmp" --no-banner --exit-code 1
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
  echo "OK — gitleaks found 0 leaks across $n kernel file(s)"
  exit 0
fi

echo "FAIL: gitleaks found leak(s) in the kernel file set (see above)" >&2
exit 1
