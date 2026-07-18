#!/usr/bin/env bash
# changelog.sh — shared CHANGELOG.md parsing helpers: semver comparison and
# BREAKING-section extraction (temperloop#429, ADR 0002 follow-on "lift
# breaking_sections() out of scripts/update-kernel.sh into a shared lib").
#
# LIFTED VERBATIM from scripts/update-kernel.sh's own breaking-delta gate
# (temperloop#89), which defined `semver_major()` / `breaking_sections()` as
# private functions of that one script. Both `scripts/update-kernel.sh` (the
# adopter-repo kernel-subtree updater) and `bin/subcommands/update.sh` (the
# managed-clone updater, ADR 0002) need the exact same CHANGELOG-range
# parsing — sourcing this file from BOTH is the alternative to bin/
# back-channeling into scripts/ (or vice versa), which this repo's own
# working-tree/layer conventions forbid (bin/ is the pre-checkout CLI
# surface; scripts/ is an in-checkout dev tool; neither is the other's
# library). Function names are prefixed `changelog_` (this repo's sourced-
# library convention — see workflows/scripts/install/manifest.sh's
# `manifest_` prefix, workflows/scripts/board/lib/board.sh's `board_`
# prefix) since update-kernel.sh's own prior names (`semver_major`,
# `breaking_sections`) were unprefixed private functions, not a documented
# external contract this file needs to preserve byte-for-byte.
#
# Usage (sourced, not executed):
#
#   source "$(dirname "$0")/../workflows/scripts/lib/changelog.sh"   # or
#   source "$SCRIPT_DIR/../workflows/scripts/lib/changelog.sh"       # script-relative
#   changelog_breaking_sections v0.1.0 v0.3.0 CHANGELOG.md
#
# Public functions:
#   changelog_semver_major <vX.Y.Z>
#     Echoes the numeric major field (leading v stripped), 0 when
#     absent/non-numeric so a malformed tag never trips arithmetic.
#
#   changelog_sections_in_range <cur-tag> <target-tag> <changelog-file>
#     Prints the FULL text (heading + body) of every CHANGELOG section whose
#     version is in the range (cur, target] — the whole delta, breaking or
#     not. <cur-tag> may be the empty string ("" — no prior tag / not yet on
#     a release), in which case every section up to and including <target-
#     tag> is printed (semver_num("") == 0, so the whole history qualifies).
#     Empty output means no section in range (e.g. cur == target).
#
#   changelog_breaking_sections <cur-tag> <target-tag> <changelog-file>
#     Same range as changelog_sections_in_range, but prints ONLY the
#     sections whose heading (or body) carries a `BREAKING` marker — the
#     pre-1.0 migration-note subset (VERSIONING.md's bump-rules table).
#     Empty output means no BREAKING-marked section in range.
#
# Dependencies: bash (3.2+), awk, POSIX-portable (no GNU-only awk/sed
# extensions — runs identically on macOS/BSD and Linux CI, per AGENTS.md §
# Safety rails "Portable shell only").
#
# shellcheck shell=bash

# Guard against double-sourcing (same idiom as manifest.sh / links.sh).
if [[ "${_TEMPERLOOP_CHANGELOG_SH_LOADED:-}" == "1" ]]; then
  return 0
fi
_TEMPERLOOP_CHANGELOG_SH_LOADED=1

# ---------------------------------------------------------------------------
# changelog_semver_major <vX.Y.Z> — echo the numeric major field (leading v
# stripped), 0 when absent/non-numeric so a malformed tag never trips the
# arithmetic.
# ---------------------------------------------------------------------------
changelog_semver_major() {
  local v="${1#v}"
  v="${v%%.*}"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s\n' "$v" || printf '0\n'
}

# ---------------------------------------------------------------------------
# changelog_sections_in_range <cur> <tgt> <changelog>
#
# Prints the full text of every CHANGELOG section whose version is in the
# range (cur, tgt] — the whole delta, unconditional on any BREAKING marker.
# ---------------------------------------------------------------------------
changelog_sections_in_range() {
  local cur="$1" tgt="$2" changelog="$3"
  [[ -f "$changelog" ]] || return 0
  awk -v cur="$cur" -v tgt="$tgt" '
    function semver_num(v,   a, n) {
      sub(/^v/, "", v)
      n = split(v, a, ".")
      return (a[1] + 0) * 1000000 + (a[2] + 0) * 1000 + (a[3] + 0)
    }
    function flush() {
      if (in_range) printf "%s", buf
      buf = ""; in_range = 0
    }
    BEGIN { cur_n = semver_num(cur); tgt_n = semver_num(tgt) }
    /^## \[/ {
      flush()
      ver = $0; sub(/^## \[/, "", ver); sub(/\].*/, "", ver)
      if (ver ~ /^v?[0-9]/) {
        sn = semver_num(ver)
        if (sn > cur_n && sn <= tgt_n) in_range = 1
      }
      buf = $0 "\n"
      next
    }
    { buf = buf $0 "\n" }
    END { flush() }
  ' "$changelog"
}

# ---------------------------------------------------------------------------
# changelog_breaking_sections <cur> <tgt> <changelog>
#
# Prints the full text of every CHANGELOG section whose version is in the
# range (cur, tgt] AND whose heading (or body) carries a `BREAKING` marker —
# the pre-1.0 migration notes. Empty output ⇒ no breaking-marked section in
# range. (Verbatim behavior of scripts/update-kernel.sh's former private
# breaking_sections() — only the name changed.)
# ---------------------------------------------------------------------------
changelog_breaking_sections() {
  local cur="$1" tgt="$2" changelog="$3"
  [[ -f "$changelog" ]] || return 0
  awk -v cur="$cur" -v tgt="$tgt" '
    function semver_num(v,   a, n) {
      sub(/^v/, "", v)
      n = split(v, a, ".")
      return (a[1] + 0) * 1000000 + (a[2] + 0) * 1000 + (a[3] + 0)
    }
    function flush() {
      if (in_range && brk) printf "%s", buf
      buf = ""; in_range = 0; brk = 0
    }
    BEGIN { cur_n = semver_num(cur); tgt_n = semver_num(tgt) }
    /^## \[/ {
      flush()
      ver = $0; sub(/^## \[/, "", ver); sub(/\].*/, "", ver)
      if (ver ~ /^v?[0-9]/) {
        sn = semver_num(ver)
        if (sn > cur_n && sn <= tgt_n) in_range = 1
      }
      buf = $0 "\n"
      if ($0 ~ /BREAKING/) brk = 1
      next
    }
    { buf = buf $0 "\n" }
    /^#+ .*BREAKING/ { brk = 1 }
    END { flush() }
  ' "$changelog"
}
