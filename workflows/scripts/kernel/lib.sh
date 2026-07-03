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
