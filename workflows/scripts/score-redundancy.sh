#!/usr/bin/env bash
#
# score-redundancy.sh — semantic-redundancy scoring, precision measurement,
# and the pre-registered go/no-go over the always-loaded prose surface
# (temperloop#855, half (b) of the P9 semantic-redundancy probe split from
# #830; epic #810, contract amendment P9 — Phase A: measurement only, no cap,
# no CI gate).
#
# ── What this is ────────────────────────────────────────────────────────────
# Half (a) (temperloop#854) segments the always-loaded surface into rule-sized
# chunks and emits them as a JSON-Lines stream; it deliberately computes no
# similarity, no verdict, no cross-chunk comparison. This script is half (b):
# it scores those chunk pairs for semantic redundancy, ranks the candidates by
# the BYTE WEIGHT of the duplication, measures its own precision against a
# hand-labelled sample of its own top-ranked output, and prints the go/no-go
# against a threshold that was PRE-REGISTERED before any of that was measured.
#
# The full method, the pre-registration, and the recorded findings live in the
# companion doc workflows/scripts/score-redundancy.md. Read that first — this
# header covers the mechanics only.
#
# ── CONSUMES HALF (a) THROUGH ITS DOCUMENTED INTERFACE ─────────────────────
# The input is exactly the JSON-Lines stream specified field-by-field in
# workflows/scripts/chunk-redundancy-surface.md — read from this script's own
# invocation of chunk-redundancy-surface.sh (stdout only; its diagnostics go
# to stderr and are passed through untouched), or from a file/stdin via
# --stream. Nothing here re-implements chunking, reads
# contributor-manifest.tsv, or depends on any chunker internal: adding a
# contributor is still a manifest row, and half (a) may change its boundary
# rule without this script changing, exactly as that contract promises.
#
# ── NEVER A GATE ────────────────────────────────────────────────────────────
# This script is NOT wired into scripts/quality-gates.sh and adds nothing to
# CI. Its findings can never fail a contributor's build — Phase A ships no cap
# (ADR 0018), and the whole point of the measurement below is to decide
# whether a Phase-B gate is warranted AT ALL. `--mode report` exits 0 whatever
# it finds. The one non-zero path is `--mode fixtures`, which is a self-test
# of the DETECTOR against #854's labelled corpus — a regression in this
# script's own behaviour, never a judgment about anyone's prose.
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   workflows/scripts/score-redundancy.sh                  # ranked report + go/no-go
#   workflows/scripts/score-redundancy.sh --mode fixtures  # detector self-test
#   workflows/scripts/score-redundancy.sh --mode json      # machine-readable ranking
#   workflows/scripts/score-redundancy.sh --stream chunks.jsonl
#   workflows/scripts/score-redundancy.sh --stream -       # read the stream from stdin
#
# ── Settings (registered in workflows/scripts/config/setting-registry.tsv;
#    named here, never re-valued in prose — the literals below ARE those rows'
#    owning-script seams) ─────────────────────────────────────────────────
#   REDUNDANCY_PRECISION_THRESHOLD_PCT  the PRE-REGISTERED precision bar at
#                                       which a Phase-B redundancy gate is
#                                       judged warranted.
#   REDUNDANCY_PRECISION_MIN_SAMPLE     minimum hand-labelled sample; below
#                                       it the verdict is NO-GO by
#                                       insufficient evidence, whatever the
#                                       ratio reads.
#   REDUNDANCY_LABEL_SAMPLE_N           how many top-ranked candidates are
#                                       drawn for hand labelling.
#   REDUNDANCY_SCORE_FLOOR_PCT          candidate floor, calibrated on #854's
#                                       labelled fixture corpus ALONE and
#                                       never on the surface being measured
#                                       (score-redundancy.md PR-4).
#
# Env overrides (fixture-driven tests only — same test/fixture-path class as
# chunk-redundancy-surface.sh's own REDUNDANCY_CHUNK_ROOT, not operator-facing
# config-precedence defaults):
#   REDUNDANCY_FIXTURES_JSON       path to #854's labelled fixture corpus
#   REDUNDANCY_LABELS_TSV          path to the hand-labelled precision sample
#   REDUNDANCY_CHUNKER             path to half (a)'s chunker
#
# Dependencies: python3 (stdlib only — already a tracked dependency of this
# repo's docs generator and drain scripts, see the `make docs` target) and,
# transitively, jq via the chunker. No embedding model, no network call, no
# LLM judge: see score-redundancy.md § Method for what that buys and costs.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${REDUNDANCY_FIXTURES_JSON:=$SCRIPT_DIR/config/redundancy-fixtures.json}"  # setting:exempt — fixture-corpus path override, same class as chunk-redundancy-surface.sh's REDUNDANCY_CHUNK_MANIFEST_TSV
: "${REDUNDANCY_LABELS_TSV:=$SCRIPT_DIR/config/redundancy-precision-labels.tsv}"  # setting:exempt — labelled-sample path override, same fixture-path class as REDUNDANCY_FIXTURES_JSON
: "${REDUNDANCY_CHUNKER:=$SCRIPT_DIR/chunk-redundancy-surface.sh}"  # setting:exempt — half (a) entry-point path override, test seam only

# ── PRE-REGISTERED measurement parameters. These four literals ARE the
#    setting-registry.tsv rows' owning-script seams; every one of them was
#    fixed in the commit that landed score-redundancy.md § Pre-registration,
#    BEFORE this script existed. Changing one after a precision figure is
#    known is a NEW pre-registration for a NEW measurement, not an edit. ──
: "${REDUNDANCY_PRECISION_THRESHOLD_PCT:=80}"
: "${REDUNDANCY_PRECISION_MIN_SAMPLE:=10}"
: "${REDUNDANCY_LABEL_SAMPLE_N:=12}"
: "${REDUNDANCY_SCORE_FLOOR_PCT:=16}"

self="$(basename "$0")"
SCORER="$SCRIPT_DIR/score-redundancy.py"

MODE="report"
STREAM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:?--mode needs report|fixtures|json}"; shift 2 ;;
    --stream) STREAM="${2:?--stream needs a path or -}"; shift 2 ;;
    -h|--help)
      sed -n '1,/^set -uo pipefail/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "$self: unrecognized argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$MODE" in
  report|fixtures|json) ;;
  *) echo "$self: --mode must be report, fixtures or json (got '$MODE')" >&2; exit 2 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "$self: python3 not found on PATH — required to run the scorer" >&2
  exit 1
fi
if [ ! -f "$SCORER" ]; then
  echo "$self: scorer not found: $SCORER" >&2
  exit 1
fi

common_args=(
  --floor-pct "$REDUNDANCY_SCORE_FLOOR_PCT"
  --threshold-pct "$REDUNDANCY_PRECISION_THRESHOLD_PCT"
  --min-sample "$REDUNDANCY_PRECISION_MIN_SAMPLE"
  --sample-n "$REDUNDANCY_LABEL_SAMPLE_N"
  --fixtures-json "$REDUNDANCY_FIXTURES_JSON"
  --labels-tsv "$REDUNDANCY_LABELS_TSV"
)

if [ "$MODE" = "fixtures" ]; then
  if [ ! -f "$REDUNDANCY_FIXTURES_JSON" ]; then
    echo "$self: fixture corpus not found: $REDUNDANCY_FIXTURES_JSON" >&2
    exit 1
  fi
  exec python3 "$SCORER" --mode fixtures "${common_args[@]}"
fi

# The chunk stream. Default: run half (a) and read its stdout — its own
# one-line summary/diagnostics stay on stderr and pass straight through, per
# that script's documented "stdout is a pure JSONL stream" contract.
if [ -n "$STREAM" ]; then
  if [ "$STREAM" != "-" ] && [ ! -f "$STREAM" ]; then
    echo "$self: chunk stream not found: $STREAM" >&2
    exit 1
  fi
  exec python3 "$SCORER" --mode "$MODE" --stream "$STREAM" "${common_args[@]}"
fi

if [ ! -x "$REDUNDANCY_CHUNKER" ]; then
  echo "$self: half (a)'s chunker not found or not executable: $REDUNDANCY_CHUNKER" >&2
  exit 1
fi

# A pipeline, not a temp file: the chunker's stdout IS the documented seam.
# `set -o pipefail` is in force, so a chunker failure surfaces as this
# script's own non-zero exit rather than an empty, silently-scored stream.
"$REDUNDANCY_CHUNKER" | python3 "$SCORER" --mode "$MODE" --stream - "${common_args[@]}"
exit $?
