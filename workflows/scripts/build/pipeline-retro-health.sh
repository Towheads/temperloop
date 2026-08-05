#!/usr/bin/env bash
#
# pipeline-retro-health.sh — READ-ONLY detector for the retro-judge seam
# (temperloop#1150). Answers the one question the mint-then-judge loop could
# not previously answer about itself: **has the judge ever actually run, and if
# not, why not?**
#
# ── WHY THIS EXISTS ────────────────────────────────────────────────────────
# The retrospection loop (ADR 0007) has three moving parts: the kernel MINTS a
# `retro-pending` tracker at epic close, the funnel tick TRIGGERS a judge when
# one is due, and the overlay `/retro` judge JUDGES it and appends a row to the
# `retro-runs` stream. Two of the three worked from day one. The judge never ran
# once — and nothing said so. The nightly rollup printed `retro-runs stream
# empty or absent — wrote zero-row retro-leading and retro-lagging rollups`
# every single night, which is *exactly* what a healthy install with no retros
# due also prints. A zero-row rollup was therefore a STEADY STATE, and the dead
# loop hid inside it for months.
#
# That ambiguity is what this script removes. A zero-row stream means one of
# four structurally different things, and they are not interchangeable:
#
#   no-signal — the trigger never fired in the window. Nothing was due. This is
#               the genuine steady state, and the ONLY one that is fine.
#   refused   — the trigger declined, legibly, and said why (`skip-retro-judge`
#               with a `reason`). Nothing ran BY DESIGN. Actionable when the
#               reason is `headless-unsupported`; expected when it is
#               `not-declared` (a kernel-only checkout has no judge).
#   healthy   — the trigger fired AND the run stream grew. The loop is closed.
#   defect    — the trigger fired and the run stream did NOT grow. Something
#               downstream of the emit is broken (the 2026-08-05 failure: a
#               nested `claude -p "/retro --pending"` that ran 13 minutes, spent
#               ~$7.60, exited `subtype: success` / `is_error: false`, and
#               produced zero judgments and zero rows).
#
# `defect` carries a `defect_kind` distinguishing the two shapes the issue
# asked to be told apart:
#   never-had-a-row — the stream is absent, or has never carried a single row
#                     in its whole recorded history. The loop has NEVER closed.
#   stalled         — rows exist historically but none landed in the window
#                     while the trigger fired. The loop closed once and broke.
#
# ── WHAT IT READS (nothing is written, ever) ───────────────────────────────
#   pipeline-<YYYY-MM>.jsonl (+ the permanent legacy funnel-<YYYY-MM>.jsonl
#     read, see meta/data/raw/README.md § `pipeline`) — the wake records
#     pipeline-cron.sh emits. `.plans[].actions[]` carries this tick's
#     retro-judge / skip-retro-judge decisions.
#   retro-runs-<YYYY-MM>.jsonl — the OVERLAY judge's own run stream. A bare
#     kernel checkout has no judge and therefore no such file; that is not a
#     defect on its own, which is why `defect` requires a FIRED TRIGGER as
#     well as an empty stream.
#
# ── CONTRACT ───────────────────────────────────────────────────────────────
# Read-only and FAIL-OPEN: it never mutates the lake, never calls the network,
# and ALWAYS exits 0 — the verdict is the `status` field, not the exit code, so
# a caller (/tidy's Retro mint backstop, an operator, a future CI probe) can
# never be broken by this script's own failure. An unreadable/absent lake is
# reported as `no-lake`, never guessed past.
#
# Usage:
#   workflows/scripts/build/pipeline-retro-health.sh [--days N] [--format json|report]
#
#   --days N        window in days (default 30). The window bounds the TRIGGER
#                   and IN-WINDOW ROW counts; `rows_ever` is deliberately
#                   whole-history, because "this stream has never had a row" is
#                   a different and stronger claim than "it had none this month".
#   --format json   one JSON object on stdout (default; the machine surface)
#   --format report one human line per fact plus a verdict line
#
# Env overrides (reader-side, mirroring telemetry-brief.sh's per-stream shape —
# the emitter's own override wins so reader and writer cannot diverge):
#   TELEMETRY_RAW_DIR     shared kernel lake fallback
#   PIPELINE_RAW_DIR      the pipeline stream's own dir (pipeline-cron.sh owns it)
#   RETRO_RUNS_RAW_DIR    the overlay retro-runs stream's dir
#
# Kept bash-3.2 / BSD-date portable, matching the rest of workflows/scripts/.

set -uo pipefail

command -v jq >/dev/null 2>&1 || {
  # Fail OPEN, in the script's own output contract: a jq-less host gets a
  # legible unknown, never a crash a caller has to interpret.
  printf '{"status":"unknown","detail":"jq not found — retro-judge health cannot be computed"}\n'
  exit 0
}

here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
raw_root="$(cd -P "$here/../../.." 2>/dev/null && pwd || echo "$HOME/dev/foundation")"
: "${TELEMETRY_RAW_DIR:=$raw_root/meta/data/raw}"

pipeline_dir="${PIPELINE_RAW_DIR:-$TELEMETRY_RAW_DIR}"
retro_dir="${RETRO_RUNS_RAW_DIR:-$TELEMETRY_RAW_DIR}"

days=30
format=json
while [ $# -gt 0 ]; do
  case "$1" in
    --days) days="${2:-$days}"; shift 2 ;;
    --format) format="${2:-$format}"; shift 2 ;;
    --json) format=json; shift ;;
    -h|--help) sed -n '2,80p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) shift ;;
  esac
done
case "$days" in ''|*[!0-9]*) days=30 ;; esac
case "$format" in json|report) : ;; *) format=json ;; esac

cutoff_iso() {  # $1 = days back -> ISO-8601 Z ("" when date(1) can do neither)
  date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo ""
}
cutoff="$(cutoff_iso "$days")"

# $1=dir $2=stream-prefix -> matching month-files, one per line. Unions the
# permanent legacy `funnel-*` prefix for the pipeline stream exactly as
# telemetry-brief.sh does (the lake is append-only, so pre-rename month-files
# can never be renamed and must be read forever).
stream_files() {
  [ -d "$1" ] || return 0
  local f
  if [ "$2" = "pipeline" ]; then
    for f in "$1/funnel"-*.jsonl; do [ -e "$f" ] && printf '%s\n' "$f"; done
  fi
  for f in "$1/$2"-*.jsonl; do [ -e "$f" ] && printf '%s\n' "$f"; done
  return 0
}

# stdin = newline-separated file list -> their concatenated contents. A
# read-loop, never an unquoted `cat $files`: unquoted parameters do NOT
# word-split under zsh (AGENTS.md § Portable shell only), and a path with a
# space would break the split form under bash too.
cat_stream() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && cat "$f"
  done
  return 0
}

pipeline_files="$(stream_files "$pipeline_dir" pipeline)"
retro_files="$(stream_files "$retro_dir" retro-runs)"

emit() {  # $1 = the finished JSON object
  if [ "$format" = "json" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  printf 'retro-judge health — window: last %s days\n' "$(jq -r '.window_days' <<<"$1")"
  printf '  triggers emitted (retro-judge):      %s\n' "$(jq -r '.judge_actions' <<<"$1")"
  printf '  refusals (skip-retro-judge):         %s  %s\n' \
    "$(jq -r '[.skips[]] | add // 0' <<<"$1")" "$(jq -rc '.skips' <<<"$1")"
  printf '  retro-runs rows in window / ever:    %s / %s (stream present: %s)\n' \
    "$(jq -r '.retro_runs.rows_in_window' <<<"$1")" \
    "$(jq -r '.retro_runs.rows_ever' <<<"$1")" \
    "$(jq -r '.retro_runs.stream_present' <<<"$1")"
  printf '  VERDICT: %s%s — %s\n' \
    "$(jq -r '.status' <<<"$1")" \
    "$(jq -r 'if .defect_kind then " (" + .defect_kind + ")" else "" end' <<<"$1")" \
    "$(jq -r '.detail' <<<"$1")"
}

# ── no lake at all ───────────────────────────────────────────────────────────
# Distinct from "no retros were due": we cannot see the trigger history, so we
# say so rather than reporting a clean bill of health off zero evidence.
if [ -z "$pipeline_files" ]; then
  emit "$(jq -nc --arg d "$pipeline_dir" --argjson w "$days" \
    '{window_days:$w,judge_actions:0,skips:{},
      retro_runs:{stream_present:false,rows_in_window:0,rows_ever:0},
      status:"no-lake",
      detail:("no pipeline-*.jsonl month-files under \($d) — the trigger history is unreadable here, so retro-judge health is UNKNOWN, not healthy")}')"
  exit 0
fi

# ── count triggers + refusals in the window ─────────────────────────────────
# A wake record is {event:"ran", ts, plans:[{actions:[…]}]}. A record with no
# parseable ts is counted IN (a missing clock must not silently hide a firing
# trigger); `cutoff` empty (date(1) unusable) likewise degrades to counting all.
counts="$(printf '%s\n' "$pipeline_files" | cat_stream \
  | jq -s --arg c "$cutoff" '
      [ .[] | select(($c == "") or ((.ts // "9999") >= $c)) | .plans[]?.actions[]? ]
      | { judge_actions: ([ .[] | select(.action == "retro-judge") ] | length),
          skips: ( [ .[] | select(.action == "skip-retro-judge") | (.reason // "unspecified") ]
                   | group_by(.) | map({key: .[0], value: length}) | from_entries ) }' 2>/dev/null)"
[ -n "$counts" ] || counts='{"judge_actions":0,"skips":{}}'

# ── count retro-runs rows (in-window AND whole-history) ─────────────────────
rows_ever=0
rows_window=0
stream_present=false
if [ -n "$retro_files" ]; then
  stream_present=true
  rows_ever="$(printf '%s\n' "$retro_files" | cat_stream | jq -s 'length' 2>/dev/null || echo 0)"
  rows_window="$(printf '%s\n' "$retro_files" | cat_stream \
    | jq -s --arg c "$cutoff" '[ .[] | select(($c == "") or ((.ts // "9999") >= $c)) ] | length' 2>/dev/null || echo 0)"
fi
case "$rows_ever" in ''|*[!0-9]*) rows_ever=0 ;; esac
case "$rows_window" in ''|*[!0-9]*) rows_window=0 ;; esac

# ── verdict ─────────────────────────────────────────────────────────────────
report="$(jq -nc --argjson c "$counts" --argjson w "$days" \
  --argjson present "$stream_present" --argjson ever "$rows_ever" --argjson win "$rows_window" \
  '{window_days:$w, judge_actions:$c.judge_actions, skips:$c.skips,
    retro_runs:{stream_present:$present, rows_in_window:$win, rows_ever:$ever}}')"

judge_actions="$(jq -r '.judge_actions' <<<"$report")"
skip_total="$(jq -r '[.skips[]] | add // 0' <<<"$report")"
headless_skips="$(jq -r '.skips["headless-unsupported"] // 0' <<<"$report")"

if [ "$judge_actions" -gt 0 ] && [ "$rows_window" -gt 0 ]; then
  report="$(jq -c --arg d "the trigger fired $judge_actions time(s) and the retro-runs stream grew by $rows_window row(s) in the window — the mint→trigger→judge loop is closed" \
    '. + {status:"healthy", detail:$d}' <<<"$report")"
elif [ "$judge_actions" -gt 0 ] && [ "$rows_ever" -eq 0 ]; then
  report="$(jq -c --arg d "DEFECT: the trigger fired $judge_actions time(s) and the retro-runs stream has NEVER carried a row (stream present: $stream_present). A judge is being spawned and is producing nothing — this is the temperloop#1150 failure shape (a nested headless run that exits success having judged nothing), not a steady state. Check the judge's own headless contract before trusting any retro rollup" \
    '. + {status:"defect", defect_kind:"never-had-a-row", detail:$d}' <<<"$report")"
elif [ "$judge_actions" -gt 0 ]; then
  report="$(jq -c --arg d "DEFECT: the trigger fired $judge_actions time(s) but no retro-runs row landed in the window, though the stream has $rows_ever row(s) historically — the loop closed once and has since stopped closing" \
    '. + {status:"defect", defect_kind:"stalled", detail:$d}' <<<"$report")"
elif [ "$skip_total" -gt 0 ]; then
  if [ "$headless_skips" -gt 0 ]; then
    report="$(jq -c --arg d "the trigger REFUSED $skip_total time(s); $headless_skips of those because the installed /retro judge does not declare the headless-unattended capability. Nothing ran, and the seam said so — an ACTIONABLE gap (the judge cannot be driven unattended), not a silent failure. Remedy: give /retro a headless --pending mode that completes unattended, then declare it with the capability marker line the skip's own detail names" \
      '. + {status:"refused", detail:$d}' <<<"$report")"
  else
    report="$(jq -c --arg d "the trigger REFUSED $skip_total time(s), none for a headless-capability reason (see .skips) — nothing ran, by design, and the seam said so" \
      '. + {status:"refused", detail:$d}' <<<"$report")"
  fi
else
  report="$(jq -c --arg d "no retro-judge trigger and no refusal in the window — nothing was due. A zero-row retro-runs stream here means 'no retros were due', which is the genuine steady state (contrast: status=defect, where a trigger fired and produced nothing)" \
    '. + {status:"no-signal", detail:$d}' <<<"$report")"
fi

emit "$report"
exit 0
