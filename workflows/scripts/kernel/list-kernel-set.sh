#!/usr/bin/env bash
#
# list-kernel-set.sh — print the git-tracked paths classified by
# kernel-manifest.txt as a given class (default: kernel). This is the
# canonical "what is the kernel set" query, consumed by the scrub checks
# (check-personal-token-denylist.sh, check-gitleaks-kernel.sh — foundation
# #798) so both agree on the same file list the coverage checker
# (check-kernel-manifest.sh, #781) already classifies.
#
# `split` paths (a file not yet content-split into kernel/overlay — e.g. the
# repo-root CLAUDE.md, Makefile, claude/settings.json per kernel-manifest.txt's
# header) are DELIBERATELY EXCLUDED from the default `kernel` class: none of
# them has identified kernel-only content yet (that's the sibling item's job),
# so there is nothing in them to hold to the kernel scrub bar today. Pass
# `--class split` explicitly if you need that set.
#
# Usage:
#   list-kernel-set.sh [--class kernel|overlay|split] [--root DIR] [--manifest FILE]
#
# Env overrides (mirroring check-kernel-manifest.sh, for fixture-driven tests):
#   KERNEL_MANIFEST_ROOT, KERNEL_MANIFEST_FILE

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

: "${KERNEL_MANIFEST_ROOT:=$REPO_ROOT}"
: "${KERNEL_MANIFEST_FILE:=$SCRIPT_DIR/kernel-manifest.txt}"

class="kernel"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --class)
      class="${2:-}"
      shift 2
      ;;
    --root)
      KERNEL_MANIFEST_ROOT="${2:-}"
      shift 2
      ;;
    --manifest)
      KERNEL_MANIFEST_FILE="${2:-}"
      shift 2
      ;;
    *)
      echo "usage: $(basename "$0") [--class kernel|overlay|split] [--root DIR] [--manifest FILE]" >&2
      exit 2
      ;;
  esac
done

case "$class" in
  kernel | overlay | split) ;;
  *)
    echo "list-kernel-set: bad --class '$class' (want kernel|overlay|split)" >&2
    exit 2
    ;;
esac

if [[ ! -f "$KERNEL_MANIFEST_FILE" ]]; then
  echo "list-kernel-set: manifest not found at $KERNEL_MANIFEST_FILE" >&2
  exit 1
fi

# shellcheck source=workflows/scripts/kernel/lib.sh
source "$SCRIPT_DIR/lib.sh"

kernel_lib_load_manifest "$KERNEL_MANIFEST_FILE" || exit 1

cd "$KERNEL_MANIFEST_ROOT" || exit 1

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  best_class="$(kernel_lib_classify "$f")" || continue
  [[ "$best_class" == "$class" ]] && printf '%s\n' "$f"
done < <(git ls-files)
