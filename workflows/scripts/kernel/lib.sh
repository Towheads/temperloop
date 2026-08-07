#!/usr/bin/env bash
#
# lib.sh — shared manifest parse/classify helpers for the kernel-manifest
# tooling (foundation #798, follow-on to #781's check-kernel-manifest.sh).
# Sourced by check-kernel-manifest.sh and list-kernel-set.sh so the
# parse + longest-pattern-wins matching logic lives in exactly ONE place
# instead of being copy-pasted per consumer.
#
# Sourced, not executed:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# kernel_lib_load_manifest <manifest_file>
#   Parses <manifest_file> into the globals KERNEL_LIB_PATTERNS[] /
#   KERNEL_LIB_CLASSES[] (parallel arrays). Blank lines and #-comments
#   (to end of line) are skipped. Exits non-zero on a malformed line or an
#   unknown class, matching check-kernel-manifest.sh's original behavior.
KERNEL_LIB_PATTERNS=()
KERNEL_LIB_CLASSES=()
kernel_lib_load_manifest() {
  local manifest_file="$1"
  local lineno=0 raw line cls pat
  KERNEL_LIB_PATTERNS=()
  KERNEL_LIB_CLASSES=()
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    cls="${line%% *}"
    pat="${line#* }"
    if [[ "$cls" == "$line" ]]; then
      echo "kernel_lib_load_manifest: malformed line $lineno (no glob after class): $raw" >&2
      return 1
    fi
    case "$cls" in
      kernel | overlay | split) ;;
      *)
        echo "kernel_lib_load_manifest: bad class '$cls' at line $lineno: $raw" >&2
        return 1
        ;;
    esac
    KERNEL_LIB_PATTERNS+=("$pat")
    KERNEL_LIB_CLASSES+=("$cls")
  done < "$manifest_file"

  if [[ ${#KERNEL_LIB_PATTERNS[@]} -eq 0 ]]; then
    echo "kernel_lib_load_manifest: manifest has zero entries — nothing to check" >&2
    return 1
  fi
  return 0
}

# kernel_lib_classify <path>
#   Echoes the class ("kernel"/"overlay"/"split") of the longest matching
#   pattern already loaded via kernel_lib_load_manifest, or nothing (rc 1)
#   if no pattern matches. "Longest pattern wins" — most-specific override.
kernel_lib_classify() {
  local f="$1" i pat plen best_len=-1 best_class=""
  for i in "${!KERNEL_LIB_PATTERNS[@]}"; do
    pat="${KERNEL_LIB_PATTERNS[$i]}"
    # shellcheck disable=SC2053  # intentional unquoted glob match
    if [[ "$f" == $pat ]]; then
      plen=${#pat}
      if (( plen > best_len )); then
        best_len=$plen
        best_class="${KERNEL_LIB_CLASSES[$i]}"
      fi
    fi
  done
  [[ -n "$best_class" ]] || return 1
  printf '%s' "$best_class"
}

# kernel_lib_resolve_for_classify <repo_root> <files_path>
#   Map a plan item's repo-relative `files:` path to the KERNEL-MANIFEST-RELATIVE
#   path that kernel_lib_classify expects, resolving the symlinked-vendored-kernel
#   case the manifest is otherwise blind to (foundation#1050).
#
#   The manifest patterns are authored relative to the KERNEL repo root
#   (`claude/agents/*`, never `kernel/claude/agents/*`). A consumer vendors the
#   kernel as a subtree (`<repo>/kernel/…`) surfaced via directory symlinks
#   (`<repo>/claude/agents -> ../kernel/claude/agents`), so a `files:` path that
#   points at kernel content arrives in a form the manifest can't match — either
#   the git-real vendored form `kernel/claude/agents/foo.md` (unmatched → falls
#   through to overlay/local, the #1050 mis-scope) or the surface symlink form
#   `claude/agents/foo.md` (a symlink whose REAL location is under `kernel/`).
#   check-kernel-manifest.sh dodges this by `cd`-ing into the subtree root before
#   `git ls-files` (temperloop#680), but /assess classifies AUTHORED paths and
#   can't cd — so it needs this explicit mapping instead.
#
#   Mapping (layout-agnostic, subtree detected by CLAUDE.kernel.md presence, per
#   the #1050 decision — no hardcoded `kernel/` prefix):
#     1. Resolve <repo_root>/<files_path> through symlinks (the DIRECTORY, via
#        `cd … && pwd -P` — the foundation case is a DIR symlink; this is
#        portable, no BSD `readlink -f`).
#     2. Walk UP from the resolved directory to the NEAREST ancestor holding
#        `claude/CLAUDE.kernel.md` — the kernel root that OWNS this file, be it a
#        vendored subtree (`<repo>/kernel`) or the repo root itself (the kernel
#        repo, where this is a no-op that returns the path unchanged).
#     3. Print the resolved path RELATIVE to that kernel root — already
#        manifest-relative, ready for kernel_lib_classify.
#   Falls back to the literal <files_path> when the path can't be resolved (file
#   or dir absent) or no kernel-root ancestor is found — so a genuine overlay
#   file, or a not-yet-created path, classifies exactly as before. Best-effort
#   and never fails: the worst case is the pre-#1050 literal-path behavior.
#     kernel_lib_resolve_for_classify <repo_root> <files_path>  ->  path to classify
kernel_lib_resolve_for_classify() {
  local repo_root="${1:-}" files_path="${2:-}" abs dir real probe kroot
  [[ -n "$repo_root" && -n "$files_path" ]] || { printf '%s' "$files_path"; return 0; }
  abs="$repo_root/$files_path"
  # Resolve symlinks in the DIRECTORY path (covers the vendored-dir-symlink case)
  # and re-attach the basename; fall back to the literal path if the dir is gone.
  # `CDPATH=` neutralizes a CDPATH inherited from the caller's env: with a
  # RELATIVE repo_root, a bare `cd <relpath>` consults CDPATH and, on a hit,
  # ECHOES the resolved dir to stdout — which would land inside this command
  # substitution and corrupt $dir (defeating the best-effort contract).
  dir="$(CDPATH='' cd "$(dirname "$abs")" 2>/dev/null && pwd -P)" || { printf '%s' "$files_path"; return 0; }
  real="$dir/$(basename "$abs")"
  # Walk up to the nearest ancestor that IS a kernel root (holds CLAUDE.kernel.md).
  kroot=""
  probe="$dir"
  while [[ -n "$probe" && "$probe" != "/" ]]; do
    if [[ -f "$probe/claude/CLAUDE.kernel.md" ]]; then kroot="$probe"; break; fi
    probe="$(dirname "$probe")"
  done
  if [[ -n "$kroot" ]]; then
    # kroot is an ancestor of dir (found by walking dirname up from it), so real
    # always begins with "$kroot"/; the case is defensive, not a live branch.
    case "$real" in
      "$kroot"/*) printf '%s' "${real#"$kroot"/}"; return 0 ;;
    esac
  fi
  printf '%s' "$files_path"
}
