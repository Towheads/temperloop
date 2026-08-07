#!/usr/bin/env bash
#
# check-kernel-manifest.sh — coverage checker for kernel-manifest.txt
# (foundation #781, epic #762 follow-on "kernel split: file-set manifest").
#
# Walks every git-tracked path in the repo and confirms it is matched by at
# least one kernel/overlay/split entry in kernel-manifest.txt. Fails
# non-zero and lists every unmatched path — this is the drift guard: a new
# file added anywhere in the tree with no manifest coverage fails CI instead
# of silently landing in neither bucket.
#
# MATCH RULE: a tracked path may match more than one glob (e.g. a directory
# catch-all plus a single-file override). The LONGEST matching pattern wins
# ("most specific wins"), so override entries can be listed anywhere in the
# manifest relative to the broader glob they narrow — no ordering fragility.
#
# Usage:
#   workflows/scripts/kernel/check-kernel-manifest.sh
#   (called by `make test-kernel-manifest`)
#
# Env overrides (used by this script's own test suite to point at a synthetic
# fixture repo/manifest instead of the real tree):
#   KERNEL_MANIFEST_ROOT  — repo root to walk (default: this repo)
#   KERNEL_MANIFEST_FILE  — manifest file to read (default: the sibling
#                           kernel-manifest.txt)
#
# SUBTREE ROOTS (temperloop#680, foundation#870): KERNEL_MANIFEST_ROOT need
# not be a git checkout's own toplevel — it may be a SUBDIRECTORY of an
# enclosing git checkout with no `.git` of its own, e.g. a downstream
# overlay's vendored kernel/ subtree. `git ls-files`, run after `cd`-ing
# into a subtree root, already returns paths relative to that subtree (git's
# own default), so they land already kernel-manifest-relative with no
# prefix-mapping step required.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

: "${KERNEL_MANIFEST_ROOT:=$REPO_ROOT}"
: "${KERNEL_MANIFEST_FILE:=$SCRIPT_DIR/kernel-manifest.txt}"

if [[ ! -f "$KERNEL_MANIFEST_FILE" ]]; then
  echo "check-kernel-manifest: manifest not found at $KERNEL_MANIFEST_FILE" >&2
  exit 1
fi

# Accept both a real repo root (its own .git dir/file) AND a subtree root —
# a subdirectory of an ENCLOSING git checkout with no .git of its own, e.g.
# a downstream overlay's vendored kernel/ subtree (temperloop#680,
# foundation#870). `git -C <dir> rev-parse --is-inside-work-tree` already
# answers exactly this ("is <dir> inside some working tree, anywhere in its
# ancestry") without walking parent dirs by hand or duplicating git's own
# discovery logic. This also means NO path-prefix mapping is needed below:
# `git ls-files`, run after `cd`-ing into a subtree root, already returns
# paths relative to that subtree (git's own default, verified — not
# repo-toplevel-relative), i.e. already kernel-manifest-relative.
if ! git -C "$KERNEL_MANIFEST_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "check-kernel-manifest: $KERNEL_MANIFEST_ROOT is not inside a git checkout" >&2
  exit 1
fi

# shellcheck source=workflows/scripts/kernel/lib.sh
source "$SCRIPT_DIR/lib.sh"

kernel_lib_load_manifest "$KERNEL_MANIFEST_FILE" || exit 1

# ---------------------------------------------------------------------------
# Walk every git-tracked path and classify by longest-matching-pattern.
# ---------------------------------------------------------------------------
cd "$KERNEL_MANIFEST_ROOT" || exit 1

unclassified=()
kernel_n=0
overlay_n=0
split_n=0
total=0

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  total=$((total + 1))
  best_class="$(kernel_lib_classify "$f")" || best_class=""
  case "$best_class" in
    kernel) kernel_n=$((kernel_n + 1)) ;;
    overlay) overlay_n=$((overlay_n + 1)) ;;
    split) split_n=$((split_n + 1)) ;;
    *) unclassified+=("$f") ;;
  esac
done < <(git ls-files)

echo "Checked $total git-tracked path(s): $kernel_n kernel, $overlay_n overlay, $split_n split"

if (( ${#unclassified[@]} > 0 )); then
  printf 'UNCLASSIFIED %d path(s) — add a kernel/overlay/split line to %s:\n' \
    "${#unclassified[@]}" "$KERNEL_MANIFEST_FILE"
  printf '  - %s\n' "${unclassified[@]}"
  exit 1
fi

echo "OK — every git-tracked path is classified (kernel/overlay/split)"
