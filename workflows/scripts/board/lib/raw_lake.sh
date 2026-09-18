#!/usr/bin/env bash
#
# raw_lake.sh — the SINGLE OWNER of the raw-lake directory resolution
# (temperloop#1902).
#
# Why this exists: the append-only raw lake at `<checkout>/meta/data/raw/` has
# several writers, and the issue-touches stream alone had TWO that each
# re-derived the directory independently — board/capture.sh (git-toplevel of
# its own SCRIPT_DIR) and ../../emit-issue-touch.sh (a fixed `../..` hop).
# Two derivations of one path is one path that can TEAR: the `../..` form is
# wrong for any consumer that vendors a writer at a different depth, and a
# later fix to one writer silently leaves the other behind — exactly how the
# absolute `$HOME/dev/foundation` pin survived in half the writers through
# temperloop#1822. One owner, both writers consuming it, is the fix.
#
# Resolution (the proven claim.sh/capture.sh form, hoisted): the git toplevel
# of THIS LIBRARY's own resolved directory, plus `/meta/data/raw`. Resolving
# from the library rather than from each caller is what makes the answer
# caller-independent — every script that sources this file gets the lake of the
# checkout the file itself lives in, at whatever depth that caller happens to
# be vendored. `git rev-parse --show-toplevel` is used rather than a fixed
# parent hop for that same reason. The absolute `$HOME/dev/foundation` literal
# survives ONLY as the last-resort fallback for a copy living outside any git
# checkout — the same fallback literal telemetry-brief.sh's own reader-side
# raw_root uses, so writer and reader still converge there too.
#
# SELF-SYMLINK RESOLUTION: the function resolves ITS OWN symlink chain before
# taking the dirname, with the same portable loop claim.sh/capture.sh use (no
# GNU `readlink -f`). `cd -P "$(dirname …)"` alone resolves the DIRECTORY
# components but not the file, so a raw_lake.sh reached through a symlink would
# otherwise report the git toplevel of the LINK's checkout rather than the
# source's — the exact caller-independence this library exists to provide. The
# loop is BOUNDED (a -> b -> a symlink cycle keeps `[ -L ]` true forever, and a
# spin here would defeat the never-fail contract below); on hitting the bound
# it simply stops resolving and answers from wherever it got to.
#
# Callers keep their own `<STREAM>_RAW_DIR` override env var and their own
# module constant (capture.sh's ISSUE_TOUCHES_RAW_DIR_DEFAULT, claim.sh's
# CLAIMS_RAW_DIR_DEFAULT); this library owns only the DEFAULT's value, never
# the per-stream override seam those settings register
# (workflows/scripts/config/setting-registry.tsv). A caller must therefore
# consult its override FIRST and reach for this library only on the default
# path — an override that is set needs no resolution at all, so requiring this
# library to be present in order to honor one would put the shared owner in
# front of a seam it does not own.
#
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention). Per-stream record shapes are documented at each writer.
#
# Sourced, not executed:
#   source "$SCRIPT_DIR/lib/raw_lake.sh"
#   dir="${MY_STREAM_RAW_DIR:-$(raw_lake_dir)}"
#
# Kept bash-3.2-friendly (macOS dev shell + Linux CI), and NEVER fails: EVERY
# step that can fail is guarded with an explicit fallback and every variable it
# reads is `:-`-defaulted, so an unresolvable checkout, an unreadable directory,
# or an unset $HOME under the caller's inherited `set -u` falls back to a whole,
# usable path rather than returning non-zero OR silently truncating one.
#
# Both halves of that matter, because both callers evaluate this at MODULE
# scope under `set -euo pipefail` — `CLAIMS_RAW_DIR_DEFAULT="$(raw_lake_dir)"`
# in claim.sh, the cross-session board lock. A non-zero return risks killing the
# whole board command at startup over a telemetry path lookup; and the quieter
# half, measured rather than assumed, is what the earlier bare `$HOME` actually
# did — `set -u` aborted the `|| echo "$HOME/…"` fallback subshell MID-EXPANSION,
# so `root` came back EMPTY and the function cheerfully returned the truncated
# "/meta/data/raw" (a root-relative path, on stderr noise nobody reads). A
# wrong sink is worse than a loud failure here, since the stream's own failure
# mode is an absent record. test_telemetry_brief.sh asserts the exact fallback
# string, not just its suffix, for that reason.

# Print the absolute raw-lake directory for the checkout this library lives in.
raw_lake_dir() {
  local src link_dir lib_dir root hops
  src="${BASH_SOURCE[0]:-.}"
  hops=0
  # Bounded symlink resolution (see SELF-SYMLINK RESOLUTION above).
  while [ -L "$src" ] && [ "$hops" -lt 40 ]; do
    link_dir="$(cd -P "$(dirname "$src")" 2>/dev/null && pwd)" || link_dir=""
    src="$(readlink "$src" 2>/dev/null)" || src=""
    case "$src" in
      /*) ;;
      *) src="${link_dir:-.}/$src" ;;
    esac
    hops=$((hops + 1))
  done
  lib_dir="$(cd -P "$(dirname "$src")" 2>/dev/null && pwd)" || lib_dir=""
  [ -n "$lib_dir" ] || lib_dir="."
  root="$(git -C "$lib_dir" rev-parse --show-toplevel 2>/dev/null || echo "${HOME:-}/dev/foundation")"
  [ -n "$root" ] || root="${HOME:-}/dev/foundation"
  printf '%s\n' "$root/meta/data/raw"
}
