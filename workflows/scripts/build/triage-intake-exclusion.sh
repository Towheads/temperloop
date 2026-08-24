#!/usr/bin/env bash
#
# triage-intake-exclusion.sh — the deterministic half of `/triage` Step 1
# Adapter A's THIRD naturally-excluded bucket: the process-record label
# filter (temperloop#1614, item retro-tracker-intake-exclusion).
#
# ── What problem this closes ────────────────────────────────────────────────
# `/build` 4d-retro MINTS a durable process-retro tracker at epic close
# (`claude/commands/build.md`) and labels it `retro-pending` (an overlay
# `/retro` judge exists to pick it up) or `retro-info` (terminal — no judge
# installed). Either way the tracker is a build-health RECORD, not build work,
# and it sits OPEN in `Backlog` until something consumes it BY LABEL.
#
# `/triage` Adapter A had no exclusion for that shape, so every sweep intook
# all of them and spent judgment on candidates that have NO CORRECT TRIAGE
# OUTCOME: promoting one to `Ready` drops it into `/sweep`'s Ready-singleton
# drain pool, where a fix worker would try to *fix a build-health record*;
# culling one closes a record the judge still consumes. Neither a routing rule
# nor a default disposition can be right when both dispositions are wrong —
# an EXCLUSION is the only shape that fits, which is why this is a third
# naturally-excluded bucket alongside the inactive-milestone filter
# (foundation #208) and the open-`blocked_by` skip (foundation #137), and not
# a fourth branch of the Step-2 decision tree.
#
# ── Why a SEAM, not a hardcoded `retro-pending` special case ────────────────
# The exclusion is a generic label predicate driven by
# `TRIAGE_INTAKE_EXCLUDE_LABELS` (`workflows/scripts/build/build.config.sh`,
# per the kernel's § Named-setting convention: prose names the setting, this
# script and that config own the value). The DEFAULT names kernel-minted
# labels only — a bare kernel checkout with no overlay mints `retro-info`
# trackers itself, so it needs this exclusion exactly as much as an
# overlay-carrying one, and the stranger test passes without importing any
# overlay vocabulary. An operator whose checkout carries other non-work record
# labels adds them to the setting; nothing here is retro-specific by
# construction.
#
# ── Why extracted into a script at all ──────────────────────────────────────
# `/triage` is AI-executed prose, so a rule that lives only in that prose can
# be verified only by a human re-reading the diff. The exclusion's whole
# content is mechanical — a set intersection over labels already carried by
# the resolved board item-list — so it is extracted here, exactly as
# `/sweep`'s comment-anchored exclusion was extracted into
# sweep-answered-exclusion.sh, and is covered by synthetic fixtures with no
# live `gh` and no live board (workflows/scripts/build/tests/
# test_triage_intake_exclusion.sh).
#
# ── Cost: this is the CHEAPEST of Adapter A's three exclusions ──────────────
# The board item form carries `.labels` already (board.sh's `issue_item`
# reshape), so this filter costs ZERO extra REST calls against the resolved
# `BOARD_ITEMS_JSON`. Its two siblings each cost one live REST call PER
# candidate (`board_item_milestone`, `board_blocked_by_open`). It therefore
# runs FIRST in Adapter A's filter order — a tracker excluded here is one
# fewer item those two ever fetch — and, because it runs first, an excluded
# tracker is reported on THIS bucket's summary line rather than being
# miscounted on the inactive-milestone `deferred[]` line.
#
# Usage:
#   triage-intake-exclusion.sh <items-json-file> [--labels "<l1 l2 ...>"]
#   cat items.json | triage-intake-exclusion.sh - [--labels "<l1 l2 ...>"]
#
# Input JSON shape — the resolved board item-list, i.e. `BOARD_ITEMS_JSON`
# / `board_item_list <board#>` verbatim, no projection needed:
#   { "items": [ { "id": "ISSUE_851",
#                  "content": { "number": 851, "title": "..." },
#                  "labels": ["Operational", "retro-pending", ...],
#                  "status": "Backlog" }, ... ] }
# Items whose `.status` is not `Backlog` are OUT OF SCOPE entirely — Adapter
# A's slice is the Backlog set, and an already-triaged (`Ready`+) item is
# excluded by that slice, never by this filter. Such an item appears in
# NEITHER output list.
#
# Output JSON on stdout:
#   {
#     "exclude_labels": ["retro-pending", "retro-info"],
#     "backlog_total": 12,
#     "intake":   [ <issue#>, ... ],                 # sorted ascending
#     "excluded": [ { "issue": 851,
#                     "labels": ["retro-pending"] }, ... ],   # sorted ascending
#     "summary_line": "Excluded at intake (Step 1 — process-record label filter): ..."
#   }
#
# `intake` and `excluded` PARTITION `backlog_total` by construction — same
# discipline `/triage` Step 4.9's own telemetry arithmetic demands.
#
# `summary_line` is the mandatory Step-5 report line, rendered here rather
# than hand-typed downstream: the #164 silent-skip mitigation requires this
# bucket to be reported EVERY run, including the zero case, so the line is
# produced by the same code that decides the exclusion and cannot drift from
# it.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: triage-intake-exclusion.sh <items-json-file> [--labels "<l1 l2 ...>"]
       cat items.json | triage-intake-exclusion.sh - [--labels "<l1 l2 ...>"]

Partitions the Backlog slice of a resolved board item-list (BOARD_ITEMS_JSON)
into the /triage Step 1 Adapter A intake set and the process-record label
exclusion set, and renders the mandatory Step-5 summary line. Prints one JSON
object to stdout. See this script's own header for the input/output shape.

Exclusion labels come from TRIAGE_INTAKE_EXCLUDE_LABELS (space-separated;
default in workflows/scripts/build/build.config.sh), or --labels.
EOF
}

if [ $# -eq 0 ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

INPUT=""
LABELS_OVERRIDE=""
HAVE_OVERRIDE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --labels)
      [ $# -ge 2 ] || { echo "triage-intake-exclusion.sh: --labels needs a value" >&2; exit 1; }
      LABELS_OVERRIDE="$2"; HAVE_OVERRIDE=1; shift 2 ;;
    --labels=*)
      LABELS_OVERRIDE="${1#--labels=}"; HAVE_OVERRIDE=1; shift ;;
    -)
      # The documented stdin form (`… | triage-intake-exclusion.sh -`) — and the
      # one /triage Step 1 Adapter A actually uses. It MUST be matched before
      # the `-*` unknown-flag glob below, which would otherwise swallow it and
      # exit 1 on the spec's own invocation.
      [ -z "$INPUT" ] || { echo "triage-intake-exclusion.sh: one input path only (got extra: $1)" >&2; exit 1; }
      INPUT="-"; shift ;;
    -*)
      echo "triage-intake-exclusion.sh: unknown flag: $1" >&2; exit 1 ;;
    *)
      [ -z "$INPUT" ] || { echo "triage-intake-exclusion.sh: one input path only (got extra: $1)" >&2; exit 1; }
      INPUT="$1"; shift ;;
  esac
done

[ -n "$INPUT" ] || { echo "triage-intake-exclusion.sh: no input given" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "triage-intake-exclusion.sh: jq required" >&2; exit 1; }

if [ "$INPUT" = "-" ]; then
  ITEMS_JSON="$(cat)"
else
  [ -f "$INPUT" ] || { echo "triage-intake-exclusion.sh: no such file: $INPUT" >&2; exit 1; }
  ITEMS_JSON="$(cat "$INPUT")"
fi

# Resolve the exclusion label set. Precedence: --labels > the environment
# (the normal path — /triage Step 0 sources build.config.sh, which exports
# TRIAGE_INTAKE_EXCLUDE_LABELS) > the fallback literal below. The fallback is
# BYTE-IDENTICAL to build.config.sh's own `:=` seam and is registered once,
# citing build.config.sh as the source of truth
# (workflows/scripts/config/setting-registry.tsv's own duplicate-seam rule).
# This script deliberately does NOT source build.config.sh itself: it is a
# pure, side-effect-free classifier a test can drive with a synthetic label
# set, and sourcing the whole config would drag every unrelated build setting
# into that.
#
# Turning the bucket OFF is `--labels ""` (or an empty setting value reaching
# this script as an override): an empty label set excludes nothing, and the
# summary line SAYS SO out loud rather than the bucket going silent — the
# #164 silent-skip mitigation applies to a disabled filter too.
if [ "$HAVE_OVERRIDE" -eq 1 ]; then
  EXCLUDE_LABELS="$LABELS_OVERRIDE"
else
  : "${TRIAGE_INTAKE_EXCLUDE_LABELS:=retro-pending retro-info}"  # non-vendoring-checkout fallback
  EXCLUDE_LABELS="$TRIAGE_INTAKE_EXCLUDE_LABELS"
fi

printf '%s' "$ITEMS_JSON" | jq -c --arg labels "$EXCLUDE_LABELS" '
  ($labels | split(" ") | map(select(length > 0)) | unique) as $ex
  # Adapter A intakes the Backlog slice ONLY; everything else is out of scope
  # for this filter and appears in neither output list.
  | [ .items[]? | select((.status // "") == "Backlog") ] as $backlog
  | [ $backlog[]
      | { issue: .content.number,
          hits: ((.labels // []) | map(select(. as $l | $ex | index($l))) | unique) } ] as $tagged
  | ($tagged | map(select((.hits | length) > 0))
             | sort_by(.issue)
             | map({ issue: .issue, labels: .hits })) as $excluded
  | ($tagged | map(select((.hits | length) == 0) | .issue) | sort) as $intake
  # Per-label tally for the summary line: an item carrying two excluded labels
  # counts once toward N and once under EACH label it carries, so the reader
  # can see which label is doing the excluding.
  | ([ $excluded[] | .labels[] ] | group_by(.)
       | map({ label: .[0], n: length })
       | sort_by(.label)) as $bylabel
  | ( if ($ex | length) == 0 then
        "Excluded at intake (Step 1 — process-record label filter): 0 — TRIAGE_INTAKE_EXCLUDE_LABELS is empty, no label exclusion configured"
      elif ($excluded | length) == 0 then
        "Excluded at intake (Step 1 — process-record label filter): 0 — no Backlog item carries an excluded label (" + ($ex | join(", ")) + ")"
      else
        "Excluded at intake (Step 1 — process-record label filter): "
        + ($excluded | length | tostring)
        + " carrying a non-work record label ("
        + ($bylabel | map(.label + " ×" + (.n | tostring)) | join(", "))
        + "): "
        + ($excluded | map("#" + (.issue | tostring)) | join(" "))
        + ". Remove the label to include."
      end ) as $line
  | { exclude_labels: $ex,
      backlog_total: ($backlog | length),
      intake: $intake,
      excluded: $excluded,
      summary_line: $line }
'
