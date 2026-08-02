#!/usr/bin/env bash
#
# test_score_redundancy.sh — tests for workflows/scripts/score-redundancy.sh
# and its scorer (temperloop#855, half (b) of the P9 semantic-redundancy
# probe).
#
# Covers:
#   1. FIXTURE SELF-TEST — the two acceptance bullets that are mechanically
#      checkable: every #854 known-POSITIVE paraphrase pair is flagged
#      (paraphrase, not just copy-paste — these pairs share no 10-word
#      shingle by construction, mechanically enforced by
#      check-redundancy-fixtures.sh), and every known-NEGATIVE pair is not
#      (the deliberate pointer is suppressed by name; the hard topical
#      near-miss falls below the floor).
#   2. FIXTURE REGRESSION DETECTION — a floor pushed above the lowest
#      positive makes the self-test FAIL and exit non-zero, proving the
#      self-test can actually fail rather than always printing OK.
#   3. REAL-TREE happy path — the report runs end to end off half (a)'s own
#      chunker, ranks by duplicated-byte weight (monotonically
#      non-increasing), and always exits 0 (report-only; never a gate).
#   4. THE DOCUMENTED SEAM — the scorer reads a chunk stream from a FILE and
#      from STDIN, reads only fields chunk-redundancy-surface.md documents,
#      and rejects a record missing one rather than silently scoring it.
#   5. PRECISION + GO/NO-GO ARITHMETIC — synthetic label sets drive the
#      verdict: a below-threshold sample records NO-GO, an at-threshold
#      sample records GO, a too-small sample records NO-GO by insufficient
#      evidence, and a label for a pair outside the top-N is reported STALE
#      and excluded rather than silently counted.
#   6. VERBATIM-IDENTICAL detection and pointer suppression on a synthetic
#      stream.
#
# Usage: bash workflows/scripts/tests/test_score_redundancy.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/score-redundancy.sh"
FIXTURES="$REPO/workflows/scripts/config/redundancy-fixtures.json"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

assert_rc() {
  local got="$1" want="$2" name="$3"
  if [ "$got" -eq "$want" ]; then ok "$name"; else fail_test "$name" "expected exit $want, got $got"; fi
}
assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find: $needle" ;;
  esac
}
assert_lacks() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) fail_test "$name" "did NOT expect to find: $needle" ;;
    *) ok "$name" ;;
  esac
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-score-redundancy.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# An empty labels file, so cases that are not about labelling never pick up
# the real committed sample.
: >"$TMP/empty-labels.tsv"

# ── 1. fixture self-test ─────────────────────────────────────────────────────
echo "--- 1. fixture self-test (the acceptance's paraphrase + pointer bullets) ---"
out="$(bash "$SCRIPT" --mode fixtures 2>&1)"; rc=$?
assert_rc "$rc" 0 "fixture self-test exits 0 at the committed floor"
assert_lacks "$out" "FAIL" "no fixture is misclassified"

pos_flagged="$(printf '%s\n' "$out" | grep -c '^PASS positive .*-> flagged')"
if [ "$pos_flagged" -eq 2 ]; then
  ok "both known-POSITIVE paraphrase pairs are flagged (paraphrase, not copy-paste)"
else
  fail_test "both positives flagged" "expected 2 flagged positives, got $pos_flagged"
fi

assert_has "$out" "suppressed as a deliberate pointer" \
  "the deliberate-pointer negative is suppressed BY NAME, not merely below the floor"
assert_has "$out" "verbatim5=0.000" \
  "no fixture pair is carried by verbatim overlap (all shingle scores are zero)"

neg_flagged="$(printf '%s\n' "$out" | grep -c '^....negative .*-> flagged')"
if [ "$neg_flagged" -eq 0 ]; then
  ok "no known-NEGATIVE pair is flagged"
else
  fail_test "no negative flagged" "expected 0 flagged negatives, got $neg_flagged"
fi

# ── 2. the self-test can actually fail ───────────────────────────────────────
echo "--- 2. fixture self-test detects a regression ---"
out="$(REDUNDANCY_SCORE_FLOOR_PCT=95 bash "$SCRIPT" --mode fixtures 2>&1)"; rc=$?
assert_rc "$rc" 1 "an absurd floor makes the self-test exit 1"
assert_has "$out" "fixture(s) misclassified" "the failure names how many fixtures broke"

# ── 3. real-tree report ──────────────────────────────────────────────────────
echo "--- 3. real-tree report ---"
out="$(REDUNDANCY_LABELS_TSV="$TMP/empty-labels.tsv" bash "$SCRIPT" 2>/dev/null)"; rc=$?
assert_rc "$rc" 0 "report exits 0 (report-only — findings can never fail a build)"
assert_has "$out" "RANKED CANDIDATES" "the report ships ranked findings, not only a method"
assert_has "$out" "PRE-REGISTERED THRESHOLD" "the report states the pre-registered threshold"
assert_has "$out" "SUPPRESSED AS DELIBERATE POINTERS" \
  "pointer-suppressed pairs are reported, never silently dropped"

# Ranking is monotonically non-increasing in duplicated bytes.
bytes="$(printf '%s\n' "$out" | sed -n 's/^ *[0-9][0-9]*\. ~\([0-9][0-9]*\) B duplicated.*/\1/p')"
prev=""
monotone=1
for b in $bytes; do
  if [ -n "$prev" ] && [ "$b" -gt "$prev" ]; then monotone=0; fi
  prev="$b"
done
n_ranked="$(printf '%s\n' "$bytes" | grep -c .)"
if [ "$monotone" -eq 1 ] && [ "$n_ranked" -gt 0 ]; then
  ok "candidates are ranked by duplicated-byte weight, non-increasing ($n_ranked rows)"
else
  fail_test "ranked by duplicated-byte weight" "monotone=$monotone over $n_ranked rows"
fi

# ── 4. the documented seam ───────────────────────────────────────────────────
echo "--- 4. consumes half (a)'s stream through its documented interface ---"
"$REPO/workflows/scripts/chunk-redundancy-surface.sh" >"$TMP/chunks.jsonl" 2>/dev/null
from_file="$(REDUNDANCY_LABELS_TSV="$TMP/empty-labels.tsv" bash "$SCRIPT" --stream "$TMP/chunks.jsonl" 2>/dev/null)"
from_stdin="$(REDUNDANCY_LABELS_TSV="$TMP/empty-labels.tsv" bash "$SCRIPT" --stream - <"$TMP/chunks.jsonl" 2>/dev/null)"
if [ "$from_file" = "$from_stdin" ] && [ -n "$from_file" ]; then
  ok "a stream read from a file and from stdin produce identical reports"
else
  fail_test "file/stdin parity" "the two reports differ"
fi
if [ "$from_file" = "$out" ]; then
  ok "piping the chunker directly matches feeding it the same stream by hand"
else
  fail_test "chunker-pipe parity" "the piped report differs from the --stream report"
fi

printf '%s\n' '{"id":"a#1","path":"a","text":"hello","byte_count":5}' >"$TMP/bad.jsonl"
bad="$(REDUNDANCY_LABELS_TSV="$TMP/empty-labels.tsv" bash "$SCRIPT" --stream "$TMP/bad.jsonl" 2>&1)"; rc=$?
assert_rc "$rc" 1 "a record missing a documented field is rejected, not silently scored"
assert_has "$bad" "sha256" "the rejection names the missing field"

missing="$(bash "$SCRIPT" --stream "$TMP/nope.jsonl" 2>&1)"; rc=$?
assert_rc "$rc" 1 "an absent --stream path is a clean error"
assert_has "$missing" "chunk stream not found" "the absent-stream error is legible"

bad_mode="$(bash "$SCRIPT" --mode wat 2>&1)"; rc=$?
assert_rc "$rc" 2 "an unknown --mode exits 2"
assert_has "$bad_mode" "--mode must be" "the unknown-mode error names the valid set"

# ── 5. precision arithmetic and the go/no-go verdict ─────────────────────────
echo "--- 5. precision measurement + go/no-go ---"
# Pull the real top-N pair ids straight from --mode json, so these synthetic
# label sets stay valid as the surface changes.
"$REPO/workflows/scripts/score-redundancy.sh" --mode json 2>/dev/null >"$TMP/rank.json"
top_pairs="$(jq -r '.candidates[0:12][] | "\(.a)\t\(.b)"' "$TMP/rank.json")"
n_top="$(printf '%s\n' "$top_pairs" | grep -c .)"

# 5a. all-TP -> GO.
printf '%s\n' "$top_pairs" | awk -F'\t' '{print $1"\t"$2"\ttp\tsynthetic"}' >"$TMP/all-tp.tsv"
out="$(REDUNDANCY_LABELS_TSV="$TMP/all-tp.tsv" bash "$SCRIPT" 2>/dev/null)"
assert_has "$out" "GO/NO-GO: GO" "an all-true-positive sample records GO"
assert_has "$out" "MEASURED PRECISION: 100.0%" "an all-true-positive sample measures 100%"
assert_has "$out" "sample size n=$n_top" "the sample size is stated beside the figure"

# 5b. all-FP -> NO-GO.
printf '%s\n' "$top_pairs" | awk -F'\t' '{print $1"\t"$2"\tfp\tsynthetic"}' >"$TMP/all-fp.tsv"
out="$(REDUNDANCY_LABELS_TSV="$TMP/all-fp.tsv" bash "$SCRIPT" 2>/dev/null)"
assert_has "$out" "GO/NO-GO: NO-GO" "an all-false-positive sample records NO-GO"
assert_has "$out" "MEASURED PRECISION: 0.0%" "an all-false-positive sample measures 0%"
assert_has "$out" "re-tuned against these labels" \
  "the NO-GO states that the detector is not re-tuned and re-measured"

# 5c. a sample below the pre-registered minimum -> NO-GO by insufficient
#     evidence, even at 100% precision.
printf '%s\n' "$top_pairs" | head -3 | awk -F'\t' '{print $1"\t"$2"\ttp\tsynthetic"}' >"$TMP/tiny.tsv"
out="$(REDUNDANCY_LABELS_TSV="$TMP/tiny.tsv" bash "$SCRIPT" 2>/dev/null)"
assert_has "$out" "MEASURED PRECISION: 100.0%" "the tiny sample still reports its ratio"
assert_has "$out" "below the pre-registered minimum" \
  "a 3-pair sample at 100% is still NO-GO by insufficient evidence"
assert_has "$out" "UNLABELLED in the top" "unlabelled top-N pairs are named, never counted as TP"

# 5d. a stale label (a pair not in the top-N) is excluded, not counted.
cp "$TMP/all-tp.tsv" "$TMP/stale.tsv"
printf 'no/such/file.md#1\tno/other/file.md#9\ttp\tstale synthetic row\n' >>"$TMP/stale.tsv"
out="$(REDUNDANCY_LABELS_TSV="$TMP/stale.tsv" bash "$SCRIPT" 2>/dev/null)"
assert_has "$out" "STALE LABELS" "a label outside the top-N is reported as stale"
assert_has "$out" "no/such/file.md#1" "the stale pair is named"
assert_has "$out" "sample size n=$n_top" "the stale row does not inflate the sample size"

# 5e. no labels at all -> not measured, NO-GO.
out="$(REDUNDANCY_LABELS_TSV="$TMP/empty-labels.tsv" bash "$SCRIPT" 2>/dev/null)"
assert_has "$out" "not measured" "an empty label set reports 'not measured', never a bare 0%"
assert_has "$out" "GO/NO-GO: NO-GO" "an empty label set records NO-GO"

# 5f. a malformed label row is a loud error, not a silent skip.
printf 'only-one-field\n' >"$TMP/broken.tsv"
out="$(REDUNDANCY_LABELS_TSV="$TMP/broken.tsv" bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 1 "a malformed label row fails loudly"
assert_has "$out" "tab-separated" "the malformed-row error names the expected shape"

printf 'a#1\tb#1\tmaybe\twhat\n' >"$TMP/badverdict.tsv"
out="$(REDUNDANCY_LABELS_TSV="$TMP/badverdict.tsv" bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 1 "a label outside {tp,fp} fails loudly"

# ── 6. synthetic stream: verbatim-identical + pointer suppression ────────────
echo "--- 6. synthetic stream behaviours ---"
mk() { # mk <id> <text>
  jq -n -c --arg id "$1" --arg text "$2" \
    '{id:$id, path:($id|split("#")[0]), unit:"full", label:"synthetic", load:"harness-auto",
      chunk_index:1, chunk_count:1, section:null, start_line:1, end_line:1,
      byte_count:($text|utf8bytelength), word_count:($text|split(" ")|length),
      sha256:($text|@base64), text:$text}'
}
{
  mk "twin-a.md#1" "Every board read and write goes through the board.sh adapter, never a raw gh project call, because the adapter caches and protects the shared GraphQL budget."
  mk "twin-b.md#1" "Every board read and write goes through the board.sh adapter, never a raw gh project call, because the adapter caches and protects the shared GraphQL budget."
  mk "ptr.md#1" "Board access matches the canonical adapter rule described in the shared kernel doc — that part is not repeated here. What is specific to this repository: the adapter lives under scripts/lib."
} >"$TMP/synth.jsonl"

# A 3-document corpus makes every shared term near-zero-IDF, so the pointer
# pair scores far below the committed floor on its own. The floor is not what
# is under test here — the SUPPRESSION MECHANISM is — so these two cases run
# at a floor low enough that every pair is a candidate, and assert which of
# them the pointer rule then removes from the ranking.
out="$(REDUNDANCY_LABELS_TSV="$TMP/empty-labels.tsv" REDUNDANCY_SCORE_FLOOR_PCT=1 \
  bash "$SCRIPT" --stream "$TMP/synth.jsonl" 2>/dev/null)"
assert_has "$out" "[VERBATIM-IDENTICAL]" "two byte-identical chunks are marked verbatim-identical"
assert_has "$out" "twin-a.md#1" "the identical pair is ranked as a candidate"
suppressed_block="$(printf '%s\n' "$out" | sed -n '/SUPPRESSED AS DELIBERATE POINTERS/,/^$/p')"
assert_has "$suppressed_block" "ptr.md#1" "the deferring chunk's pairs are pointer-suppressed"
assert_lacks "$suppressed_block" "twin-a.md#1 <-> twin-b.md#1" \
  "the identical pair is NOT suppressed (neither member defers)"

json="$(REDUNDANCY_LABELS_TSV="$TMP/empty-labels.tsv" REDUNDANCY_SCORE_FLOOR_PCT=1 \
  bash "$SCRIPT" --mode json --stream "$TMP/synth.jsonl" 2>/dev/null)"
if printf '%s' "$json" | jq -e '.candidates[0].identical == true' >/dev/null; then
  ok "--mode json marks the identical pair"
else
  fail_test "--mode json identical flag" "expected candidates[0].identical == true"
fi
if printf '%s' "$json" | jq -e '.pointer_suppressed | length >= 1' >/dev/null; then
  ok "--mode json carries the pointer-suppressed bucket"
else
  fail_test "--mode json suppressed bucket" "expected at least one suppressed pair"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ] || exit 1
echo "OK — score-redundancy.sh"
