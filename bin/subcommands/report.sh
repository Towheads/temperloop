#!/usr/bin/env bash
# description: before/after value report -- kernel-tier deltas from .temperloop/baseline.jsonl + overlay-tier repo drop-ins
#
# report.sh -- `temperloop report`: the 'AFTER' picture of Epic E's
# before/after value loop (foundation #766, epic #765-adjacent "Epic E"
# value-proof work, item report-renderer). Reads every line of
# .temperloop/baseline.jsonl (written by baseline-snapshot.sh -- see
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
# TARGET repo's own baseline JSONL plus its own .temperloop/report.d/
# drop-ins.
#
# DISPATCH MODEL: a discovered subcommand, same as every sibling in this
# directory (see kernel/bin/foundation's header comment + baseline-
# snapshot.sh's identical note) -- this file's mere presence at
# kernel/bin/subcommands/report.sh IS `temperloop report`.
#
# TWO TIERS:
#   KERNEL-TIER (always renders, .temperloop/baseline.jsonl only, zero
#     network by default): merged items/day, median time-to-merge, review
#     latency, issue backlog age -- each a first-record-vs-latest-record
#     delta. The population definition behind every one of these numbers is
#     fixed by baseline-snapshot.sh and printed in every report (see
#     kernel/workflows/scripts/lib/report.contract.md, which restates it
#     verbatim from baseline_snapshot.contract.md's "Re-appendable by
#     design" section -- one source, kept in sync by hand, never re-derived
#     independently).
#   OVERLAY-TIER (the drop-in seam): every executable file directly inside
#     the target repo's .temperloop/report.d/ (a TRACKED dir -- meant to be
#     committed, unlike the gitignored baseline.jsonl) is run with no args,
#     cwd = the target repo, under a watchdog; the contract is exit 0 + a
#     self-contained stdout block, rendered verbatim under its own
#     "-- report.d/<name> --" heading. An absent .temperloop/report.d/, a
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
# delta. That fallback is NOT silent (temperloop#988): a `tokens` producer
# that ran and exited 0 but whose stdout failed the parse renders one
# explicit "skipped -- tokens: stdout did not parse ..." line in the same
# per-producer skipped-line channel, under its own heading -- unless its
# stdout already opens with `skipped -- ` (the kernel shim's own
# unresolvable/disabled line), in which case the second line is suppressed
# as redundant. The fallback itself is unchanged and still never an error.
#   DOLLAR FRAMING (foundation#882): the `tokens` producer may additionally
#   emit a `by_model` object ({model: tokens}); if the target repo also
#   carries a user-supplied .temperloop/pricing.json ({model: USD-per-Mtok}),
#   the headline gains a directional dollar line (attributed tokens x list
#   price, unpriced models named and excluded). Absent/malformed pricing or
#   an absent by_model degrades to one legible line, never an error -- no
#   precise cost accounting, no network (a local jq file read).
#   DEFAULT PRICE TABLE (temperloop#1251): when `by_model` is present but the
#   repo carries NO .temperloop/pricing.json, report.sh now falls back to a
#   kernel-shipped, dated snapshot at workflows/scripts/config/
#   default-pricing.json instead of only nudging the adopter to write one --
#   the dollar figure is never gated behind hand-authored config. A dollar
#   line rendered from that table is unmissably labeled with its `as_of` date
#   and a staleness/DEFAULT-TABLE marker, alongside the existing DIRECTIONAL
#   label. A user-supplied pricing.json, when present, OVERRIDES the default
#   table outright -- it is never merged with it. Every other degradation
#   (malformed pricing.json, zero name overlap, an absent/malformed default
#   table) is still one legible line, never an error.
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
#   1  fatal: no .temperloop/baseline.jsonl (or legacy .foundation/
#      baseline.jsonl) found (run `temperloop baseline-snapshot` or
#      `temperloop report --refresh` first), --dir
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
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
KERNEL_ROOT="$(cd "$BIN_DIR/.." && pwd)"
BASELINE_SNAPSHOT="$SUBCOMMAND_DIR/baseline-snapshot.sh"
# Kernel-shipped default price table (temperloop#1251) -- see "Default price
# table fallback" below, near the dollar-framing block. Overridable via
# $TEMPERLOOP_DEFAULT_PRICING_FILE (an ordinary layer-2 env override, same
# idiom as SPEND_TRANSCRIPT_ROOT) purely so test_report.sh can point at a
# fixture with fixed prices/as_of instead of coupling assertions to
# whatever the real, hand-edited table currently contains.
DEFAULT_PRICING_FILE="${TEMPERLOOP_DEFAULT_PRICING_FILE:-$KERNEL_ROOT/workflows/scripts/config/default-pricing.json}"  # setting:exempt — test/fixture root override, mirrors COUNT_PROSE_ROOT/REDUNDANCY_CHUNK_ROOT

abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }
target_dir="$(abs_dir "$report_dir")" || { echo "report.sh: --dir '$report_dir' does not exist" >&2; exit 1; }
repo_root="$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null)" || repo_root="$target_dir"

echo "== temperloop report =="
echo

if [ "$do_refresh" -eq 1 ]; then
  if [ ! -f "$BASELINE_SNAPSHOT" ]; then
    echo "report.sh: --refresh requires baseline-snapshot.sh at $BASELINE_SNAPSHOT (broken kernel checkout)" >&2
    exit 1
  fi
  echo "-- Refreshing baseline (temperloop baseline-snapshot) --"
  if ! (cd "$repo_root" && bash "$BASELINE_SNAPSHOT"); then
    echo "report.sh: baseline-snapshot refresh reported a failure -- rendering from whatever is already on disk" >&2
  fi
  echo
fi

# temperloop#165 rename dir: .temperloop/ preferred, an existing legacy
# .foundation/baseline.jsonl read as fallback.
#
# THIS READ DELIBERATELY SURVIVES THE v0.19.0 WINDOW CLOSE — do NOT delete it
# as window leftover. The window governed which dir the CLI RESOLVES CONFIG
# FROM AND WRITES TO, and those paths now refuse legibly (`init`,
# `baseline-snapshot`). `report` is read-only and reports on history it did
# not create, so refusing here would blind an un-migrated repo to its own
# past for no safety gain — the same reasoning that keeps `eject`/`uninstall`
# cleaning legacy residue. Migrating is still the right move
# (`mkdir -p .temperloop && mv .foundation/baseline.jsonl .temperloop/`).
# Canonical statement: kernel/workflows/scripts/lib/report.contract.md
# § Overlay drop-in contract.
baseline_file="$repo_root/.temperloop/baseline.jsonl"
[ -f "$baseline_file" ] || baseline_file="$repo_root/.foundation/baseline.jsonl"
if [ ! -f "$baseline_file" ]; then
  echo "report.sh: no .temperloop/baseline.jsonl (or legacy .foundation/baseline.jsonl) found in $repo_root" >&2
  echo "  Run 'temperloop baseline-snapshot' (or 'temperloop report --refresh') first." >&2
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
  echo "  will appear once a later 'temperloop baseline-snapshot' run appends a"
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
  # LC_ALL=C: fv/lv are jq-emitted period-decimal numbers; keep the delta's
  # own decimal point locale-independent so it never mismatches the
  # period-formatted fv/lv it sits beside (see the dollar-total LC_ALL=C
  # comments below for the same class of locale bug).
  delta="$(LC_ALL=C awk -v a="$fv" -v b="$lv" 'BEGIN{printf "%+.2f", b-a}')"
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
# Overlay tier -- the drop-in seam (.temperloop/report.d/). See this file's
# header comment + kernel/workflows/scripts/lib/report.contract.md's
# "Overlay drop-in contract" section for the full rule.
# temperloop#165 rename dir: .temperloop/report.d/ preferred; an existing
# legacy .foundation/report.d/ (a TRACKED dir in adopter repos) is used as
# fallback when the new one is absent. Never unioned: one dir wins, so a
# producer is never run twice.
#
# THIS READ DELIBERATELY SURVIVES THE v0.19.0 WINDOW CLOSE — do NOT delete it
# as window leftover. Same reasoning as the baseline read above: `report` is
# read-only and reports on drop-ins it did not create, so refusing here would
# blind an un-migrated repo to its own producers for no safety gain.
# Migrating is still the right move (`git mv .foundation/report.d
# .temperloop/report.d` -- the dir is tracked). Canonical statement:
# kernel/workflows/scripts/lib/report.contract.md § Overlay drop-in contract.
#
# CWD CONTRACT (temperloop#983 review, BLOCKING finding 2): report.contract.md
# states a drop-in is invoked with "cwd = the target repo", but until this
# fix that was documentation only -- the loop below never actually `cd`'d,
# so a producer ran with WHATEVER cwd this process inherited, not $repo_root.
# That silently broke `temperloop report --dir /some/other/repo` run from a
# THIRD location: a producer deriving anything from its own cwd (the
# `tokens` producer's repo-scoping, temperloop#983, is exactly such a
# consumer) would scope itself to the CALLER's cwd instead of the repo being
# reported on -- a fresh instance of the very "wrong corpus" bug that item
# exists to kill, just one level up. Fixed below by `cd`-ing to $repo_root
# INSIDE the same command-substitution subshell that already isolates each
# producer invocation, so this process's own cwd is never touched.
# ---------------------------------------------------------------------------
echo "-- Overlay-tier: repo drop-ins (.temperloop/report.d/) --"
report_d="$repo_root/.temperloop/report.d"
if [ ! -d "$report_d" ] && [ -d "$repo_root/.foundation/report.d" ]; then
  report_d="$repo_root/.foundation/report.d"
fi
tokens_ok=0
tokens_spent=""
# by_model breakdown (foundation#882): {model: tokens}, optionally emitted by
# the tokens producer alongside tokens_spent; drives the directional dollar
# line in the headline below. "{}" means none supplied.
tokens_by_model="{}"

if [ ! -d "$report_d" ]; then
  echo "skipped -- no .temperloop/report.d/ (or legacy .foundation/report.d/) directory (no overlay drop-ins registered for this repo)"
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
    out="$(cd "$repo_root" && run_with_timeout "$timeout_secs" "$f" 2>/dev/null)"
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
    # notice channel (temperloop#981): ANY producer's stdout MAY additionally
    # parse as a JSON object carrying a string `notice` field -- when it
    # does, render it as its own line here, alongside (not instead of) the
    # verbatim stdout block above. This is the one documented channel for a
    # drop-in to address a human directly -- report.sh discards stderr
    # entirely (see report.contract.md "Overlay drop-in contract"), so a
    # notice written to stderr would be silently lost. Non-JSON, non-object,
    # or notice-less stdout is not an error -- it just means no notice line.
    notice="$(jq -e -r 'if (.notice | type) == "string" then .notice else empty end' <<<"$out" 2>/dev/null)"
    notice_rc=$?
    if [ "$notice_rc" -eq 0 ] && [ -n "$notice" ]; then
      echo "notice: $notice"
    fi
    if [ "$name" = "tokens" ]; then
      # jq's exit status MUST be checked (temperloop#981), not just
      # `[ -n "$parsed" ]`: on multi-document/trailing-garbage stdout jq can
      # emit output for an earlier valid document and still exit non-zero
      # once it hits the invalid tail -- trusting `$parsed` alone let that
      # partial output "accidentally" drive the headline while a
      # leading-garbage variant of the same malformed shape silently fell
      # back with no such accident. Requiring rc==0 makes both forms degrade
      # the same, deterministic way.
      parsed="$(jq -e -r 'if (.tokens_spent | type) == "number" then .tokens_spent else empty end' <<<"$out" 2>/dev/null)"
      parsed_rc=$?
      if [ "$parsed_rc" -eq 0 ] && [ -n "$parsed" ]; then
        tokens_spent="$parsed"
        tokens_ok=1
        # Optional per-model breakdown (foundation#882). An object of
        # {model: tokens}; anything else (absent, non-object) stays "{}".
        by_model="$(jq -c 'if (.by_model | type) == "object" then .by_model else {} end' <<<"$out" 2>/dev/null)"
        [ -n "$by_model" ] && tokens_by_model="$by_model"
      else
        # PARSE-FAILURE NOTICE (temperloop#988). Until this, a `tokens`
        # producer that was present, executable, and exited 0 but whose
        # stdout failed the single-JSON-object/numeric-tokens_spent parse
        # dropped straight through to the kernel-tier headline with NO line
        # saying so -- the exact asymmetry temperloop#981 created when it
        # added a `notice` channel "for messages that must not be silently
        # dropped" while leaving this degradation mute (and enlarged, since
        # checking jq's exit status pulled trailing-garbage stdout into the
        # falling-back population). It reuses the SAME per-producer
        # skipped-line channel as the not-executable / non-zero-exit /
        # timeout cases above, rendered inside this producer's own block so
        # a reader sees the cause next to the stdout that caused it. The
        # kernel-tier fallback itself is unchanged and still not an error.
        #
        # ONE EXCEPTION -- a producer that already self-declared. The
        # kernel's own `tokens` shim prints exactly `skipped -- tokens:
        # producer unavailable` (and exits 0) when it cannot resolve a
        # kernel or when a person has locally disabled it; that bare line is
        # not JSON, so it lands here. Adding a second skip line under the
        # same heading would be redundant noise on the most common degrade
        # path, so stdout whose first line already opens the skip channel
        # suppresses this one. Documented in report.contract.md.
        case "$out" in
          "skipped -- "*) : ;;
          *) echo "skipped -- $name: stdout did not parse as a single JSON object with a numeric tokens_spent field (headline fell back to the kernel tier -- not an error; see report.contract.md)" ;;
        esac
      fi
    fi
    echo
  done
  if [ "$found_any" -eq 0 ]; then
    echo "skipped -- ${report_d#"$repo_root"/} exists but is empty (no producers registered)"
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
  # -- Directional dollar framing (foundation#882) ---------------------------
  # Iff the tokens producer emitted a per-model breakdown AND the target repo
  # carries a user-supplied pricing table (.temperloop/pricing.json, a JSON
  # map {model: USD-per-Mtok}), multiply each model's attributed tokens by its
  # list price and render a directional dollar estimate under the same
  # DIRECTIONAL label. Every missing/malformed piece degrades to one legible
  # line, never a hard error -- report.sh stays a pure renderer and adds no
  # precise cost accounting (see report.contract.md "Non-goals"). No network:
  # a local file read via jq, covered by the producer-egress lint.
  if [ "$tokens_by_model" != "{}" ]; then
    pricing_file="$repo_root/.temperloop/pricing.json"
    if [ ! -f "$pricing_file" ]; then
      # -- Default price table fallback (temperloop#1251) --------------------
      # No user-supplied override: rather than only nudge the adopter to
      # write one, fall back to the kernel-shipped, dated snapshot at
      # $DEFAULT_PRICING_FILE ({as_of: "YYYY-MM-DD", prices: {model: $/Mtok}})
      # so the dollar figure is never gated behind hand-authored config. A
      # LATER user pricing.json still overrides this outright (see the `elif`/
      # `else` arms below) -- this arm only fires when no override exists.
      if [ -f "$DEFAULT_PRICING_FILE" ] \
         && jq -e '(.prices | type) == "object" and (.as_of | type) == "string"' >/dev/null 2>&1 <"$DEFAULT_PRICING_FILE"; then
        default_as_of="$(jq -r '.as_of' <"$DEFAULT_PRICING_FILE")"
        dollar_json="$(jq -n --argjson bm "$tokens_by_model" --slurpfile pr "$DEFAULT_PRICING_FILE" '
          ($pr[0].prices // {}) as $prices
          | reduce ($bm | to_entries[]) as $e
              ({priced: 0, total: 0, unpriced: []};
               if ($e.value | type) == "number" then
                 (if (($prices[$e.key] | type) == "number" and $prices[$e.key] > 0)
                  then .priced += 1 | .total += ($e.value * $prices[$e.key] / 1000000)
                  else .unpriced += [$e.key] end)
               else . end)' 2>/dev/null || true)"
        d_priced="$(jq -r '.priced // 0' <<<"$dollar_json" 2>/dev/null || echo 0)"
        if [ -n "$d_priced" ] && [ "$d_priced" -gt 0 ] 2>/dev/null; then
          # LC_ALL=C: jq always emits a period-decimal number; awk's field
          # split parses it via the ambient locale's strtod, which silently
          # truncates at the decimal point in a comma-decimal locale (e.g.
          # de_DE) instead of reformatting -- $20.75 becomes 20, not 20,75.
          # Force the C locale for this parse only.
          d_total_fmt="$(jq -r '.total' <<<"$dollar_json" | LC_ALL=C awk '{printf "%.2f", $1}')"
          d_unpriced="$(jq -r 'if (.unpriced | length) > 0 then (.unpriced | join(", ")) else "" end' <<<"$dollar_json")"
          echo "  ~\$$d_total_fmt directional -- DEFAULT PRICE TABLE dated $default_as_of,"
          echo "    STALENESS: a committed snapshot, not your own prices -- add"
          echo "    .temperloop/pricing.json to override with current numbers;"
          if [ -n "$d_unpriced" ]; then
            echo "    $d_priced model(s) priced; unpriced tokens excluded: $d_unpriced."
          else
            echo "    $d_priced model(s) priced; all attributed tokens covered."
          fi
        else
          echo "  (no dollar estimate: no model in the default price table (dated"
          echo "    $default_as_of) matched the tokens producer's by_model"
          echo "    breakdown; add .temperloop/pricing.json to supply your own.)"
        fi
      else
        # Broken/missing kernel checkout -- degrade to the pre-#1251 nudge
        # rather than crash or silently drop the whole dollar section.
        echo "  (add .temperloop/pricing.json -- a {model: \$/Mtok} map -- for a"
        echo "    directional dollar estimate; default price table unavailable;"
        echo "    see report.contract.md.)"
      fi
    elif ! jq -e 'type == "object"' >/dev/null 2>&1 <"$pricing_file"; then
      # Require an OBJECT, not merely valid JSON: an array/number/string/null
      # parses but would throw on `$prices[$e.key]` below, and misreports as a
      # name-mismatch. One legible line covers malformed JSON and wrong-shape
      # alike (a stranger who wrote an array is steered to the object shape).
      echo "  (no dollar estimate: .temperloop/pricing.json is not a"
      echo "    {model: \$/Mtok} object.)"
    else
      dollar_json="$(jq -n --argjson bm "$tokens_by_model" --slurpfile pr "$pricing_file" '
        ($pr[0] // {}) as $prices
        | reduce ($bm | to_entries[]) as $e
            ({priced: 0, total: 0, unpriced: []};
             if ($e.value | type) == "number" then
               (if (($prices[$e.key] | type) == "number" and $prices[$e.key] > 0)
                then .priced += 1 | .total += ($e.value * $prices[$e.key] / 1000000)
                else .unpriced += [$e.key] end)
             else . end)' 2>/dev/null || true)"
      d_priced="$(jq -r '.priced // 0' <<<"$dollar_json" 2>/dev/null || echo 0)"
      if [ -n "$d_priced" ] && [ "$d_priced" -gt 0 ] 2>/dev/null; then
        # LC_ALL=C -- see the matching comment in the default-table arm above.
        d_total_fmt="$(jq -r '.total' <<<"$dollar_json" | LC_ALL=C awk '{printf "%.2f", $1}')"
        d_unpriced="$(jq -r 'if (.unpriced | length) > 0 then (.unpriced | join(", ")) else "" end' <<<"$dollar_json")"
        echo "  ~\$$d_total_fmt directional (priced from .temperloop/pricing.json;"
        if [ -n "$d_unpriced" ]; then
          echo "    $d_priced model(s) priced; unpriced tokens excluded: $d_unpriced)."
        else
          echo "    $d_priced model(s) priced; all attributed tokens covered)."
        fi
      else
        echo "  (no dollar estimate: no model in .temperloop/pricing.json matched"
        echo "    the tokens producer's by_model breakdown.)"
      fi
    fi
  fi
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

echo "temperloop report: done"
exit 0
