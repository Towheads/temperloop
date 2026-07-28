#!/usr/bin/env bash
#
# check-redundancy-fixtures.sh — structural + property lint for
# workflows/scripts/config/redundancy-fixtures.json (temperloop#854, half
# (a) of the P9 semantic-redundancy probe).
#
# redundancy-fixtures.json is the labelled corpus half (b) (temperloop#855)
# measures its own detector's precision against. This lint keeps the corpus
# honest as it grows:
#
#   1. Structural: the file parses as JSON and has a non-empty `fixtures`
#      array; every entry has a non-empty `id`/`label`/`kind`/`rationale`
#      string plus non-empty `chunk_a.text`/`chunk_b.text` strings; `label`
#      is one of the closed set (`positive`, `negative`); no `id` is reused.
#   2. THE ACCEPTANCE PROPERTY (temperloop#854's own acceptance bullet,
#      mechanically enforced rather than merely asserted in a comment):
#      every `label=positive` entry's chunk_a and chunk_b share NO common
#      run of 10 consecutive words, case-folded and punctuation-stripped —
#      "shares no 10-word shingle yet states the same rule" is exactly what
#      a positive fixture is FOR (a verbatim-only detector must fail to
#      find anything here); a positive pair that DOES share a 10-word run
#      is not exercising the paraphrase case it claims to and fails this
#      lint. `label=negative` entries are NOT checked for this property —
#      a negative pair's whole point is that it may or may not share
#      surface language; what matters for a negative is the RATIONALE, not
#      a shingle count.
#
# Usage:
#   workflows/scripts/config/check-redundancy-fixtures.sh
#
# Env overrides (fixture-driven tests):
#   REDUNDANCY_FIXTURES_JSON   path to the corpus (default: sibling
#                              redundancy-fixtures.json)
#
# Dependency: jq (see chunk-redundancy-surface.sh's own header for why this
# is an accepted, pervasive dependency in this repo already).
#
# Kept bash-3.2-portable (no associative arrays, no mapfile) — same
# discipline as every other workflows/scripts/config/*.sh checker.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${REDUNDANCY_FIXTURES_JSON:=$SCRIPT_DIR/redundancy-fixtures.json}"  # setting:exempt — test/fixture path override, same class as CONTRIBUTOR_MANIFEST_TSV

self="$(basename "$0")"

if ! command -v jq >/dev/null 2>&1; then
  echo "$self: jq not found on PATH — required to parse the corpus" >&2
  exit 1
fi

if [ ! -f "$REDUNDANCY_FIXTURES_JSON" ]; then
  echo "$self: corpus not found: $REDUNDANCY_FIXTURES_JSON" >&2
  exit 1
fi

if ! jq -e . "$REDUNDANCY_FIXTURES_JSON" >/dev/null 2>/tmp/check-redundancy-fixtures.jq.err 2>&1; then
  echo "$self: $REDUNDANCY_FIXTURES_JSON is not valid JSON" >&2
  exit 1
fi

violations=0

fixture_count="$(jq '(.fixtures // []) | length' "$REDUNDANCY_FIXTURES_JSON")"
if [ "$fixture_count" -eq 0 ]; then
  echo "$self: zero entries in .fixtures — the corpus must be non-empty" >&2
  exit 1
fi

# --- 1. structural: required fields, label closed set, id uniqueness ------
ids_seen_file="$(mktemp "${TMPDIR:-/tmp}/crf-ids.XXXXXX")"
trap 'rm -f "$ids_seen_file"' EXIT

i=0
while [ "$i" -lt "$fixture_count" ]; do
  entry="$(jq -c ".fixtures[$i]" "$REDUNDANCY_FIXTURES_JSON")"

  fid="$(printf '%s' "$entry" | jq -r '.id // empty')"
  label="$(printf '%s' "$entry" | jq -r '.label // empty')"
  kind="$(printf '%s' "$entry" | jq -r '.kind // empty')"
  rationale="$(printf '%s' "$entry" | jq -r '.rationale // empty')"
  text_a="$(printf '%s' "$entry" | jq -r '.chunk_a.text // empty')"
  text_b="$(printf '%s' "$entry" | jq -r '.chunk_b.text // empty')"

  label_ident="${fid:-"index $i"}"

  [ -n "$fid" ] || { printf 'MISSING FIELD: fixtures[%d] has no id\n' "$i"; violations=$((violations + 1)); }
  [ -n "$kind" ] || { printf 'MISSING FIELD: %s has no kind\n' "$label_ident"; violations=$((violations + 1)); }
  [ -n "$rationale" ] || { printf 'MISSING FIELD: %s has no rationale\n' "$label_ident"; violations=$((violations + 1)); }
  [ -n "$text_a" ] || { printf 'MISSING FIELD: %s has no chunk_a.text\n' "$label_ident"; violations=$((violations + 1)); }
  [ -n "$text_b" ] || { printf 'MISSING FIELD: %s has no chunk_b.text\n' "$label_ident"; violations=$((violations + 1)); }

  case "$label" in
    positive | negative) ;;
    *)
      printf 'UNKNOWN LABEL: %s has label "%s" (must be "positive" or "negative")\n' "$label_ident" "$label"
      violations=$((violations + 1))
      ;;
  esac

  if [ -n "$fid" ]; then
    if grep -Fxq "$fid" "$ids_seen_file" 2>/dev/null; then
      printf 'DUPLICATE ID: %s is claimed by more than one entry\n' "$fid"
      violations=$((violations + 1))
    else
      printf '%s\n' "$fid" >> "$ids_seen_file"
    fi
  fi

  # --- 2. the acceptance property: positive pairs share no 10-word run ----
  if [ "$label" = "positive" ] && [ -n "$text_a" ] && [ -n "$text_b" ]; then
    shingles_a="$(printf '%s' "$text_a" \
      | tr '[:upper:]' '[:lower:]' \
      | tr -c 'a-z0-9' ' ' \
      | tr -s ' ' '\n' \
      | sed '/^$/d' \
      | awk '{w[NR]=$0} END{for(i=1;i<=NR-9;i++){s=w[i];for(j=1;j<10;j++)s=s" "w[i+j];print s}}')"
    shingles_b="$(printf '%s' "$text_b" \
      | tr '[:upper:]' '[:lower:]' \
      | tr -c 'a-z0-9' ' ' \
      | tr -s ' ' '\n' \
      | sed '/^$/d' \
      | awk '{w[NR]=$0} END{for(i=1;i<=NR-9;i++){s=w[i];for(j=1;j<10;j++)s=s" "w[i+j];print s}}')"

    if [ -n "$shingles_a" ] && [ -n "$shingles_b" ]; then
      shared="$(comm -12 <(printf '%s\n' "$shingles_a" | LC_ALL=C sort) <(printf '%s\n' "$shingles_b" | LC_ALL=C sort))"
      if [ -n "$shared" ]; then
        example="$(printf '%s\n' "$shared" | head -1)"
        printf 'SHARED 10-WORD SHINGLE: %s (label=positive) shares "%s" between chunk_a and chunk_b — a positive fixture must have NO verbatim overlap this long\n' "$label_ident" "$example"
        violations=$((violations + 1))
      fi
    fi
  fi

  i=$((i + 1))
done

echo
if [ "$violations" -gt 0 ]; then
  echo "FAIL: $violations redundancy-fixtures violation(s)" >&2
  exit 1
fi
echo "OK — redundancy-fixtures.json ($fixture_count entr$([ "$fixture_count" -eq 1 ] && echo y || echo ies)): every field present, every label valid, every id unique, every positive pair shingle-free"
