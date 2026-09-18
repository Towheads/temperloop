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
# Resolution (unchanged from the proven claim.sh/capture.sh form, hoisted
# verbatim): the git toplevel of THIS LIBRARY's own resolved directory, plus
# `/meta/data/raw`. Resolving from the library rather than from each caller is
# what makes the answer caller-independent — every script that sources this
# file gets the lake of the checkout the file itself lives in, at whatever
# depth that caller happens to be vendored. `git rev-parse --show-toplevel` is
# used rather than a fixed parent hop for that same reason. The absolute
# `$HOME/dev/foundation` literal survives ONLY as the last-resort fallback for
# a copy living outside any git checkout — the same fallback literal
# telemetry-brief.sh's own reader-side raw_root uses, so writer and reader
# still converge there too.
#
# Callers keep their own `<STREAM>_RAW_DIR` override env var and their own
# module constant (capture.sh's ISSUE_TOUCHES_RAW_DIR_DEFAULT, claim.sh's
# CLAIMS_RAW_DIR_DEFAULT); this library owns only the DEFAULT's value, never
# the per-stream override seam those settings register
# (workflows/scripts/config/setting-registry.tsv).
#
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention). Per-stream record shapes are documented at each writer.
#
# Sourced, not executed:
#   source "$SCRIPT_DIR/lib/raw_lake.sh"
#   dir="${MY_STREAM_RAW_DIR:-$(raw_lake_dir)}"
#
# Kept bash-3.2-friendly (macOS dev shell + Linux CI), and NEVER fails: an
# unresolvable checkout falls back rather than returning non-zero, so a
# `set -e` caller computing a module constant from it cannot be killed by a
# telemetry path lookup.

# Print the absolute raw-lake directory for the checkout this library lives in.
raw_lake_dir() {
  local lib_dir root
  lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="$(git -C "$lib_dir" rev-parse --show-toplevel 2>/dev/null || echo "$HOME/dev/foundation")"
  printf '%s\n' "$root/meta/data/raw"
}
