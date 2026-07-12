#!/usr/bin/env bash
# description: before/after value report -- kernel-tier deltas from .foundation/baseline.jsonl + overlay-tier repo drop-ins
#
# report.sh -- `foundation report`: the 'AFTER' picture of Epic E's
# before/after value loop (foundation #766, epic #765-adjacent "Epic E"
# value-proof work, item report-renderer). Reads every line of
# .foundation/baseline.jsonl (written by baseline-snapshot.sh -- see
# kernel/workflows/scripts/lib/baseline_snapshot.contract.md) and renders
# first-record-vs-latest-record deltas across four kernel-tier metrics. This
# script NEVER calls `gh` itself except when --refresh is passed, in which
# case it shells out to the sibling baseline-snapshot.sh FIRST (to append one
# fresh record) and then renders -- baseline-snapshot.sh remains the ONLY
# place in the whole value loop that talks to the GitHub API.
#
# SCOPE (read before touching this file): `report` is the TARGET REPO's
# adoption/value surface -- a stranger's OWN checkout, after they've `init`'d
# and used the CLI for a while, sees their own before/after numbers here.
# This is a DIFFERENT rule from kernel/bin/foundation's dispatcher-level
# scope note ("not a second front door onto foundation's own make targets" --
# that rule is about THIS repo's day-to-day `make` targets staying on
# `make`, never duplicated into a dispatcher verb); `report` never wraps a
# Makefile target at all, kernel or otherwise -- it only ever renders the
# TARGET repo's own baseline JSONL plus its own .foundation/report.d/
# drop-ins.
#
# DISPATCH MODEL: a discovered subcommand, same as every sibling in this
# directory (see kernel/bin/foundation's header comment + baseline-
# snapshot.sh's identical note) -- this file's mere presence at
# kernel/bin/subcommands/report.sh IS `foundation report`.
#
# TWO TIERS:
#   KERNEL-TIER (always renders, .foundation/baseline.jsonl only, zero
#     network by default): merged items/day, median time-to-merge, review
#     latency, issue backlog age -- each a first-record-vs-latest-record
#     delta. The population definition behind every one of these numbers is
#     fixed by baseline-snapshot.sh and printed in every report (see
#     kernel/workflows/scripts/lib/report.contract.md, which restates it
#     verbatim from baseline_snapshot.contract.md's "Re-appendable by
#     design" section -- one source, kept in sync by hand, never re-derived
#     independently).
#   OVERLAY-TIER (the drop-in seam): every executable file directly inside
#     the target repo's .foundation/report.d/ (a TRACKED dir -- meant to be
#     committed, unlike the gitignored baseline.jsonl) is run with no args,
#     cwd = the target repo, under a watchdog; the contract is exit 0 + a
#     self-contained stdout block, rendered verbatim under its own
#     "-- report.d/<name> --" heading. An absent .foundation/report.d/, a
#     non-executable file, a non-zero exit, or a timeout all degrade to one
#     line -- "skipped -- <name>: producer unavailable" -- NEVER a hard
#     error; see kernel/workflows/scripts/lib/report.contract.md's "Overlay
#     drop-in contract" section for the one-paragraph version of this same
#     rule, plus the one additional, stricter rule for a producer named
#     exactly `tokens` (used for the headline economics below).
#
# HEADLINE ECONOMICS: if a `tokens` drop-in is present, executable, exits 0,
# and its stdout parses as a JSON object with a numeric `tokens_spent`
# field, the headline is "tokens spent vs items merged" (always labeled
# directional -- see the contract file). Otherwise the headline falls back
# to the kernel-tier numbers alone: merged-items/day delta + time-to-merge
# delta.
#
# Usage:
#   report.sh [--dir DIR] [--refresh] [--timeout SECS]
#
#   --dir DIR      Git checkout to report on. Default: current directory.
#   --refresh      Shell out to the sibling baseline-snapshot.sh FIRST
#                  (appends one fresh record -- real gh calls, real
#                  network), then render. Omit this flag and the run is
#                  zero-network, rendering strictly from whatever is
#                  already on disk.
#   --timeout SECS Per-drop-in watchdog, seconds. Default: 15.
#
# Exit codes:
#   0  rendered a report (even a heavily degraded one -- a missing
#      report.d/ dir, an unavailable metrics record, or a failed drop-in
#      are all legible skip reasons, not failures).
#   1  fatal: no .foundation/baseline.jsonl found (run `foundation
#      baseline-snapshot` or `foundation report --refresh` first), --dir
#      doesn't exist, or (with --refresh) the sibling baseline-snapshot.sh
#      file is missing (broken kernel checkout).
#   2  invalid CLI usage.
#
# Dependencies: bash (3.2+), jq (hard requirements). `gh` is never called
# directly by this script -- --refresh's `gh` usage is entirely
# baseline-snapshot.sh's own concern (including its optional-gh degrade
# path). No egress beyond that single delegated call.
#
# shellcheck shell=bash

set -uo pipefail

# run_with_timeout SECS cmd... — portable bounded-subprocess watchdog, the
# ONE shared shim every such call site sources rather than re-deriving
# (temperloop#256). Path resolved via pure bash parameter expansion
# (${x%/*}), never `dirname` — see baseline-snapshot.sh's identical
# resolution for why (a sibling script's PATH-minimal degrade test).
_pt_here="${BASH_SOURCE[0]%/*}"; [ "$_pt_here" = "${BASH_SOURCE[0]}" ] && _pt_here="."
# shellcheck source=../../workflows/scripts/lib/portable-timeout.sh
source "$(cd "$_pt_here/../.." && pwd)/workflows/scripts/lib/portable-timeout.sh"
unset _pt_here

usage() {
  cat <<'EOF'
usage: report.sh [--dir DIR] [--refresh] [--timeout SECS]
EOF
}

report_dir="."
do_refresh=0
timeout_secs=15

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) report_dir="${2:?--dir needs a value}"; shift 2 ;;
    --refresh) do_refresh=1; shift ;;
    --timeout) timeout_secs="${2:?--timeout needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "report.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "report.sh: jq not found on PATH" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Locate sibling kernel content -- same pinned-physical-path idiom as
# baseline-snapshot.sh / try.sh / eject.sh's own header comments.
# ---------------------------------------------------------------------------
SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE_SNAPSHOT="$SUBCOMMAND_DIR/baseline-snapshot.sh"

abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }
target_dir="$(abs_dir "$report_dir")" || { echo "report.sh: --dir '$report_dir' does not exist" >&2; exit 1; }
repo_root="$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null)" || repo_root="$target_dir"

echo "== foundation report =="
echo

if [ "$do_refresh" -eq 1 ]; then
  if [ ! -f "$BASELINE_SNAPSHOT" ]; then
    echo "report.sh: --refresh requires baseline-snapshot.sh at $BASELINE_SNAPSHOT (broken kernel checkout)" >&2
    exit 1
  fi
  echo "-- Refreshing baseline (foundation baseline-snapshot) --"
  if ! (cd "$repo_root" && bash "$BASELINE_SNAPSHOT"); then
    echo "report.sh: baseline-snapshot refresh reported a failure -- rendering from whatever is already on disk" >&2
  fi
  echo
fi

baseline_file="$repo_root/.foundation/baseline.jsonl"
if [ ! -f "$baseline_file" ]; then
  echo "report.sh: no .foundation/baseline.jsonl found in $repo_root" >&2
  echo "  Run 'foundation baseline-snapshot' (or 'foundation report --refresh') first." >&2
  exit 1
fi

record_count="$(grep -c . "$baseline_file" 2>/dev/null || true)"
record_count="${record_count:-0}"
if [ "$record_count" -lt 1 ]; then
  echo "report.sh: $baseline_file is empty -- nothing to report" >&2
  exit 1
fi

first_record="$(head -n1 "$baseline_file")"
latest_record="$(tail -n1 "$baseline_file")"

if ! jq -e . >/dev/null 2>&1 <<<"$first_record"; then
  echo "report.sh: first line of $baseline_file is not valid JSON" >&2
  exit 1
fi
if ! jq -e . >/dev/null 2>&1 <<<"$latest_record"; then
  echo "report.sh: last line of $baseline_file is not valid JSON" >&2
  exit 1
fi

gh_repo="$(jq -r '.repo.gh_repo // "(unresolved)"' <<<"$latest_record")"
first_gen="$(jq -r '.generated_at // "?"' <<<"$first_record")"
latest_gen="$(jq -r '.generated_at // "?"' <<<"$latest_record")"

first_avail="$(jq -r '.metrics.available' <<<"$first_record")"
latest_avail="$(jq -r '.metrics.available' <<<"$latest_record")"
first_reason="$(jq -r '.metrics.reason // "unknown"' <<<"$first_record")"
latest_reason="$(jq -r '.metrics.reason // "unknown"' <<<"$latest_record")"
first_lb="$(jq -r '.lookback_days // 90' <<<"$first_record")"
latest_lb="$(jq -r '.lookback_days // 90' <<<"$latest_record")"
first_mc="$(jq -r '.metrics.pr_throughput.merged_count // "null"' <<<"$first_record")"
latest_mc="$(jq -r '.metrics.pr_throughput.merged_count // "null"' <<<"$latest_record")"

echo "Repo: $gh_repo"
if [ "$record_count" -eq 1 ]; then
  echo "Baseline records: 1 (only one snapshot so far -- first == latest; deltas"
  echo "  will appear once a later 'foundation baseline-snapshot' run appends a"
  echo "  second record). Recorded: $first_gen"
else
  echo "Baseline records: $record_count  (first: $first_gen  latest: $latest_gen)"
fi
echo
if [ "$first_lb" = "$latest_lb" ]; then
  lb_note="a trailing ${latest_lb}-day window"
else
  lb_note="a trailing lookback window (first record: ${first_lb}d, latest: ${latest_lb}d)"
fi
echo "Population definition (identical query shape for every record; see"
echo "  kernel/workflows/scripts/lib/report.contract.md and"
echo "  kernel/workflows/scripts/lib/baseline_snapshot.contract.md): merged pull"
echo "  requests whose mergedAt falls in $lb_note ending at each snapshot's own"
echo "  generated_at; currently open issues, unfiltered by age. Same query shape"
echo "  every run, so records are directly comparable across time."
echo

# ---------------------------------------------------------------------------
# _kernel_row LABEL JQFIELD UNIT -- renders one first-vs-latest delta row for
# a plain numeric .metrics.* field, degrading to each record's own
# unavailable-reason when metrics.available is false on either side.
# ---------------------------------------------------------------------------
_kernel_row() {
  local label="$1" field="$2" unit="$3" fv lv delta

  if [ "$first_avail" != "true" ] && [ "$latest_avail" != "true" ]; then
    printf '  %-22s unavailable (first: %s; latest: %s)\n' "$label:" "$first_reason" "$latest_reason"
    return
  fi
  if [ "$first_avail" != "true" ]; then
    lv="$(jq -r "$field // \"null\"" <<<"$latest_record")"
    printf '  %-22s unavailable for first record (%s) -- latest: %s%s\n' "$label:" "$first_reason" "$lv" "$unit"
    return
  fi
  if [ "$latest_avail" != "true" ]; then
    fv="$(jq -r "$field // \"null\"" <<<"$first_record")"
    printf '  %-22s first: %s%s -- unavailable for latest record (%s)\n' "$label:" "$fv" "$unit" "$latest_reason"
    return
  fi

  fv="$(jq -r "$field // \"null\"" <<<"$first_record")"
  lv="$(jq -r "$field // \"null\"" <<<"$latest_record")"
  if [ "$fv" = "null" ] || [ "$lv" = "null" ]; then
    printf '  %-22s first: %s%s -> latest: %s%s (no sample in one or both windows)\n' "$label:" "$fv" "$unit" "$lv" "$unit"
    return
  fi
  delta="$(awk -v a="$fv" -v b="$lv" 'BEGIN{printf "%+.2f", b-a}')"
  printf '  %-22s %s%s -> %s%s  (delta %s%s)\n' "$label:" "$fv" "$unit" "$lv" "$unit" "$delta" "$unit"
}

# --- merged items/day -- derived (merged_count / lookback_days), not a
# plain field, so it gets its own block rather than _kernel_row. ------------
_merged_items_per_day() {
  local rec="$1" avail mc lb
  avail="$(jq -r '.metrics.available' <<<"$rec")"
  [ "$avail" = "true" ] || { echo ""; return; }
  mc="$(jq -r '.metrics.pr_throughput.merged_count // "null"' <<<"$rec")"
  lb="$(jq -r '.lookback_days // "null"' <<<"$rec")"
  case "$mc" in ''|null|*[!0-9]*) echo ""; return ;; esac
  case "$lb" in ''|null|*[!0-9]*|0) echo ""; return ;; esac
  awk -v m="$mc" -v l="$lb" 'BEGIN{printf "%.4f", m/l}'
}

first_ipd="$(_merged_items_per_day "$first_record")"
latest_ipd="$(_merged_items_per_day "$latest_record")"

echo "-- Kernel-tier: before/after (baseline JSONL only) --"
if [ -z "$first_ipd" ] && [ -z "$latest_ipd" ]; then
  printf '  %-22s unavailable (first: %s; latest: %s)\n' "Merged items/day:" "$first_reason" "$latest_reason"
elif [ -z "$first_ipd" ]; then
  printf '  %-22s unavailable for first record -- latest: %s/day (%s merged / %sd)\n' "Merged items/day:" "$latest_ipd" "$latest_mc" "$latest_lb"
elif [ -z "$latest_ipd" ]; then
  printf '  %-22s first: %s/day (%s merged / %sd) -- unavailable for latest record\n' "Merged items/day:" "$first_ipd" "$first_mc" "$first_lb"
else
  ipd_delta="$(awk -v a="$first_ipd" -v b="$latest_ipd" 'BEGIN{printf "%+.4f", b-a}')"
  printf '  %-22s %s/day -> %s/day  (delta %s/day; first=%s merged/%sd, latest=%s merged/%sd)\n' \
    "Merged items/day:" "$first_ipd" "$latest_ipd" "$ipd_delta" "$first_mc" "$first_lb" "$latest_mc" "$latest_lb"
fi
_kernel_row "Median time-to-merge" ".metrics.time_to_merge_hours.median" "h"
_kernel_row "Review latency" ".metrics.review_latency_hours.median" "h"
_kernel_row "Issue backlog age" ".metrics.issue_backlog.median_age_days" "d"
echo

# ---------------------------------------------------------------------------
# Overlay tier -- the drop-in seam (.foundation/report.d/). See this file's
# header comment + kernel/workflows/scripts/lib/report.contract.md's
# "Overlay drop-in contract" section for the full rule.
# ---------------------------------------------------------------------------
echo "-- Overlay-tier: repo drop-ins (.foundation/report.d/) --"
report_d="$repo_root/.foundation/report.d"
tokens_ok=0
tokens_spent=""

if [ ! -d "$report_d" ]; then
  echo "skipped -- no .foundation/report.d/ directory (no overlay drop-ins registered for this repo)"
else
  found_any=0
  for f in "$report_d"/*; do
    [ -e "$f" ] || continue
    [ -f "$f" ] || continue
    found_any=1
    name="$(basename "$f")"
    if [ ! -x "$f" ]; then
      echo "skipped -- $name: producer unavailable (not executable -- chmod +x to enable)"
      echo
      continue
    fi
    out="$(run_with_timeout "$timeout_secs" "$f" 2>/dev/null)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 137 ]; then
        echo "skipped -- $name: producer unavailable (timed out after ${timeout_secs}s)"
      else
        echo "skipped -- $name: producer unavailable (exit $rc)"
      fi
      echo
      continue
    fi
    echo "-- report.d/$name --"
    echo "$out"
    echo
    if [ "$name" = "tokens" ]; then
      parsed="$(jq -e -r 'if (.tokens_spent | type) == "number" then .tokens_spent else empty end' <<<"$out" 2>/dev/null)"
      if [ -n "$parsed" ]; then
        tokens_spent="$parsed"
        tokens_ok=1
      fi
    fi
  done
  if [ "$found_any" -eq 0 ]; then
    echo "skipped -- .foundation/report.d/ exists but is empty (no producers registered)"
  fi
fi
echo

# ---------------------------------------------------------------------------
# Headline -- tokens-based iff the tokens drop-in parsed cleanly AND the
# latest record has a usable (positive-integer) merged_count; else the
# kernel-tier fallback (merged-items/day delta + time-to-merge delta).
# ---------------------------------------------------------------------------
latest_mc_usable=0
case "$latest_mc" in ''|null|*[!0-9]*) latest_mc_usable=0 ;; 0) latest_mc_usable=0 ;; *) latest_mc_usable=1 ;; esac

echo "-- Headline --"
if [ "$tokens_ok" -eq 1 ] && [ "$latest_mc_usable" -eq 1 ]; then
  ratio="$(awk -v t="$tokens_spent" -v m="$latest_mc" 'BEGIN{printf "%.1f", t/m}')"
  echo "Tokens spent vs items merged (DIRECTIONAL -- see report.contract.md):"
  echo "  $tokens_spent tokens / $latest_mc merged item(s) in the latest ${latest_lb}-day"
  echo "  window = $ratio tokens/item."
else
  echo "Kernel-tier headline (no usable tokens drop-in -- see report.contract.md):"
  if [ -n "$first_ipd" ] && [ -n "$latest_ipd" ]; then
    echo "  Merged items/day: $first_ipd -> $latest_ipd/day"
  else
    echo "  Merged items/day: unavailable"
  fi
  if [ "$first_avail" = "true" ] && [ "$latest_avail" = "true" ]; then
    ttm_first="$(jq -r '.metrics.time_to_merge_hours.median // "null"' <<<"$first_record")"
    ttm_latest="$(jq -r '.metrics.time_to_merge_hours.median // "null"' <<<"$latest_record")"
    if [ "$ttm_first" != "null" ] && [ "$ttm_latest" != "null" ]; then
      echo "  Median time-to-merge: ${ttm_first}h -> ${ttm_latest}h"
    else
      echo "  Median time-to-merge: unavailable (no sample in one or both windows)"
    fi
  else
    echo "  Median time-to-merge: unavailable"
  fi
fi
echo

echo "foundation report: done"
exit 0
