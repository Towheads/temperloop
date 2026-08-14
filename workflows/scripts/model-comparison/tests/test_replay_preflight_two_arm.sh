#!/usr/bin/env bash
#
# test_replay_preflight_two_arm.sh — the UNIT-CORRECTNESS suite for
# `replay.sh preflight` (temperloop#1379, epic #1225 "model comparison
# harness"). A separate suite from its sibling test_replay_preflight.sh on
# purpose: that one pins the pre-flight's PLUMBING (settings are read, the
# ceiling stops, the quota gate is consulted, every unreadable input fails
# closed) and every one of its fixtures stayed green while the two defects
# below were live. This suite pins the ARITHMETIC's UNITS, which is a
# different failure surface — the numbers were wired correctly to the wrong
# quantities.
#
# ── THE GROUND TRUTH THIS SUITE ENCODES ────────────────────────────────────
# Read off the code, not off the issue text (the issue's two defect
# paragraphs disagreed about what `eligible_n` counts, and the fix turns on
# which reading is right):
#
#   * `replay.sh preflight` counts CORPUS RECORDS. Its loop walks the corpus
#     JSONL file one line per record and increments `eligible_n` per record
#     whose `status` is eligible/flagged-eligible. One record = one merged
#     outcome (one `pr:<n>`), NOT one replay.
#   * The comparison report runs TWO ARMS. Its producer
#     (workflows/scripts/report-producers/model-comparison) takes a
#     `baseline.jsonl` and a `candidate.jsonl`, keys each arm's records by
#     `refof` ("pr:<n>"), and emits one delta per ref present in BOTH arms
#     (`pairing.paired_outcomes_n` = the intersection's size).
#   * `MODEL_COMPARISON_MIN_SAMPLE_N` is applied to THAT deltas array —
#     the producer feeds `stats.sh verdict --deltas <the paired deltas>`, and
#     stats.sh compares the array's length to the floor.
#
# So the relationship is exactly:
#
#       1 corpus record  ->  2 executed replays  ->  1 paired outcome
#
# and therefore: the token budget must be over 2 * planned records, while the
# significance floor must be checked against planned records (= planned
# pairs), never against a record count that has been silently re-read as a
# replay count. The issue's DEFECT A reading is the correct one; its DEFECT B
# aside ("35 replays split across two arms yields at most 17 pairs") describes
# a variable this code does not have — `eligible_n` was never a replay count,
# so pairs are 1:1 with records and the halving it implies would itself have
# been a second unit error.
#
# ── THE TWO DEFECTS PINNED HERE ────────────────────────────────────────────
#   A. ONE-ARM BUDGET. `est_tokens` multiplied the per-replay estimate by the
#      planned RECORD count, budgeting a single arm for a two-arm run, so
#      every batch was projected at exactly half its real cost and a batch
#      between 1x and 2x the ceiling sailed through the gate.
#   B. FLOOR IN THE WRONG UNIT. `significance_reachable` compared the whole
#      corpus's eligible RECORD pool to the floor, ignoring the batch cap
#      that bounds what this invocation will actually replay — so a capped
#      batch that can only ever produce (say) 10 paired outcomes reported the
#      significance floor as reachable because the corpus held 30 eligible
#      records it was not going to replay this run.
#
# Both are asserted on the pre-flight's REAL emitted JSON and its REAL exit
# code — never on internal shell state — and each carries a MUTATION PROOF
# that reverting the fixed line reproduces the old, wrong verdict.
#
# Hermetic: no `gh` call, no network, no live model call, no replay executed.
# preflight reads a plain corpus JSONL fixture on disk; quota-gate.sh is
# pointed at a nonexistent cache so it reports "unavailable" (fail open) and
# can never be the reason a batch stops here. No mapfile / associative arrays
# / GNU-only flags (bash 3.2).
#
# Sections:
#   1-4   DEFECT A — the two-arm budget: arms_n/planned_replays_n are emitted
#         and consistent, the estimate is over BOTH arms, a batch whose
#         two-arm cost breaches REPLAY_PREFLIGHT_CEILING_TOKENS is STOPPED
#         where its one-arm cost would not have been, + MUTATION PROOF
#   5-8   DEFECT B — the significance floor in PAIRED OUTCOMES: a capped
#         batch below the floor reports significance_reachable:false with a
#         stated reason, an uncapped batch at the floor reports true, the mde
#         disclosure is taken at the planned-pair n, + MUTATION PROOF
#   9-11  UNIT LEGIBILITY — every emitted count names its unit, and the three
#         units are internally consistent (records / executed replays /
#         paired outcomes)
#   12    FAIL CLOSED on an INDETERMINATE estimate (temperloop#1365 class): a
#         non-integer setting is CANNOT_EVALUATE, never a silently-zero
#         estimate that reads as "evaluated, and comfortably under budget"
#
# Usage: bash workflows/scripts/model-comparison/tests/test_replay_preflight_two_arm.sh
#
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd "$HERE/.." && pwd)"
SUT="$MC_DIR/replay.sh"
STATS_SUT="$MC_DIR/stats.sh"

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-replay-preflight-two-arm-XXXXXX")"
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# mutate_file <file> <old-literal-text> <new-literal-text> — exact, literal,
# single-occurrence replacement (the twin of test_replay_preflight.sh's own).
# Dies loudly if the old text is missing or not unique, so a mutation proof
# can never silently degrade into a no-op that "passes".
mutate_file() {
  local file="$1" old="$2" new="$3"
  MUT_OLD="$old" MUT_NEW="$new" perl -0777 -pi -e '
    my $o = $ENV{MUT_OLD};
    my $n = $ENV{MUT_NEW};
    my $count = () = /\Q$o\E/g;
    die "mutate_file: old text not found-or-not-unique (count=$count)\n" unless $count == 1;
    s/\Q$o\E/$n/;
  ' "$file"
}

# mk_corpus <file> <n-eligible> — n eligible corpus records, one per line,
# each a distinct merged outcome (pr:1..pr:n) exactly as `corpus` emits them.
mk_corpus() {
  local file="$1" n="$2" i=1
  : >"$file"
  while [ "$i" -le "$n" ]; do
    jq -cn --argjson pr "$i" '{pr:$pr, status:"eligible"}' >>"$file"
    i=$((i + 1))
  done
}

NOCACHE="$WORK/no-such-quota-cache.json"

# pf <env-assignments...> -- runs preflight against a corpus file with the
# quota gate deterministically "unavailable" (fail open — it can never be the
# reason anything below stops).
pf() {
  env BUILD_QUOTA_CACHE="$NOCACHE" "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION A — DEFECT A: the token budget covers BOTH arms
# ═══════════════════════════════════════════════════════════════════════════

CORPUS_5="$WORK/corpus-5.jsonl"
mk_corpus "$CORPUS_5" 5

# ---------------------------------------------------------------------------
# 1. The two-arm design is STATED, not implied: arms_n is emitted and is 2,
#    and planned_replays_n is planned_records_n * arms_n.
# ---------------------------------------------------------------------------
count
out1="$(pf env REPLAY_PREFLIGHT_BATCH_CAP=100 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=100 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_5")"
[ "$(jq -r .outcome <<<"$out1")" = "PREFLIGHT" ] || fail "1: expected PREFLIGHT, got: $out1"
[ "$(jq -r .arms_n <<<"$out1")" = "2" ] || fail "1: expected arms_n 2 (baseline + candidate), got: $out1"
[ "$(jq -r .planned_records_n <<<"$out1")" = "5" ] || fail "1: expected planned_records_n 5, got: $out1"
[ "$(jq -r .planned_replays_n <<<"$out1")" = "10" ] || fail "1: expected planned_replays_n 10 (5 records x 2 arms), got: $out1"
ok "1 arms_n=2 is emitted and planned_replays_n = planned_records_n * arms_n (5 records -> 10 replays)"

# ---------------------------------------------------------------------------
# 2. estimated_total_tokens is budgeted over EXECUTED REPLAYS (both arms) —
#    5 records * 2 arms * 100 tokens = 1000, NOT the one-arm 500.
# ---------------------------------------------------------------------------
count
[ "$(jq -r .estimated_total_tokens <<<"$out1")" = "1000" ] \
  || fail "2: expected 5 records x 2 arms x 100 = 1000 tokens (the one-arm figure would be 500), got: $out1"
[ "$(jq -r .estimated_cost <<<"$out1")" = "1000" ] || fail "2: estimated_cost should track estimated_total_tokens, got: $out1"
ok "2 estimated_total_tokens budgets BOTH arms (5x2x100=1000, not the one-arm 500)"

# ---------------------------------------------------------------------------
# 3. THE DEFECT, END TO END: a batch whose ONE-arm cost sits comfortably
#    under REPLAY_PREFLIGHT_CEILING_TOKENS but whose real TWO-arm cost
#    breaches it is STOPPED — stop:true, ceiling_exceeded:true, non-zero
#    exit. Ceiling 700: one arm = 500 (would have proceeded), two arms =
#    1000 (must stop). This is the assertion the unfixed code fails.
# ---------------------------------------------------------------------------
count
rc=0
out3="$(pf env REPLAY_PREFLIGHT_BATCH_CAP=100 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=100 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=700 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_5")" || rc=$?
[ "$rc" -ne 0 ] || fail "3: expected a NON-ZERO exit — the two-arm cost (1000) exceeds the 700 ceiling: $out3"
[ "$(jq -r .outcome <<<"$out3")" = "PREFLIGHT" ] || fail "3: outcome should still be PREFLIGHT (fully reported, not swallowed), got: $out3"
[ "$(jq -r .estimated_total_tokens <<<"$out3")" = "1000" ] || fail "3: expected the two-arm estimate 1000, got: $out3"
[ "$(jq -r .ceiling_exceeded <<<"$out3")" = "true" ] || fail "3: expected ceiling_exceeded true, got: $out3"
[ "$(jq -r .stop <<<"$out3")" = "true" ] || fail "3: expected stop true, got: $out3"
[ "$(jq -r .stop_reason <<<"$out3")" = "ceiling_exceeded" ] || fail "3: expected stop_reason ceiling_exceeded, got: $out3"
ok "3 DEFECT A: a batch under the ceiling on ONE arm but over it on TWO is STOPPED (stop:true, non-zero exit)"

# --- 4. MUTATION PROOF: revert the estimate to one arm ---------------------
#     Reverting exactly the fixed multiplication reproduces the old behavior
#     — the same over-budget batch proceeds, stop:false, exit 0 — so test 3
#     is a measurement of that line and not a tautology.
count
cp "$SUT" "$WORK/replay.sh.orig-4"
mutate_file "$SUT" \
  'local est_tokens=$(( planned_replays * REPLAY_PREFLIGHT_TOKENS_PER_REPLAY ))' \
  'local est_tokens=$(( planned_records * REPLAY_PREFLIGHT_TOKENS_PER_REPLAY ))' \
  || fail "4m: mutation apply failed"
mut_rc=0
mut_out="$(pf env REPLAY_PREFLIGHT_BATCH_CAP=100 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=100 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=700 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_5")" || mut_rc=$?
cp "$WORK/replay.sh.orig-4" "$SUT"
[ "$mut_rc" -eq 0 ] || fail "4m: expected the one-arm (mutated) script to exit 0 on the over-budget batch, got rc=$mut_rc: $mut_out"
[ "$(jq -r .estimated_total_tokens <<<"$mut_out")" = "500" ] || fail "4m: expected the one-arm estimate 500 under mutation, got: $mut_out"
[ "$(jq -r .stop <<<"$mut_out")" = "false" ] || fail "4m: expected the one-arm script NOT to stop the (really) over-budget batch: $mut_out"
ok "4m MUTATION PROOF: budgeting ONE arm lets a genuinely over-budget batch proceed uncaught — restored, test 3 above is green again"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B — DEFECT B: the significance floor is in PAIRED OUTCOMES
# ═══════════════════════════════════════════════════════════════════════════

CORPUS_30="$WORK/corpus-30.jsonl"
mk_corpus "$CORPUS_30" 30
CORPUS_20="$WORK/corpus-20.jsonl"
mk_corpus "$CORPUS_20" 20

# ---------------------------------------------------------------------------
# 5. THE DEFECT, END TO END: 30 eligible records, but the batch cap bounds
#    this invocation to 10 records = 10 paired outcomes, below a floor of
#    20. significance_reachable must be FALSE with a stated reason. The
#    unfixed code compared the 30-record POOL to the floor and reported
#    true — a run that cannot reach a conclusive verdict, cleared to spend.
# ---------------------------------------------------------------------------
count
rc=0
out5="$(pf env REPLAY_PREFLIGHT_BATCH_CAP=10 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=1 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS=500 \
  MODEL_COMPARISON_MIN_SAMPLE_N=20 \
  bash "$SUT" preflight --corpus-file "$CORPUS_30")" || rc=$?
[ "$rc" -eq 0 ] || fail "5: an unreachable floor is a DISCLOSURE, not a stop — expected exit 0, got rc=$rc: $out5"
[ "$(jq -r .eligible_n <<<"$out5")" = "30" ] || fail "5: expected eligible_n 30, got: $out5"
[ "$(jq -r .planned_pairs_n <<<"$out5")" = "10" ] || fail "5: expected planned_pairs_n 10 (batch cap binds), got: $out5"
[ "$(jq -r .significance_reachable <<<"$out5")" = "false" ] \
  || fail "5: expected significance_reachable FALSE — 10 planned pairs < a floor of 20, whatever the 30-record pool says: $out5"
case "$(jq -r .reachable_reason <<<"$out5")" in
  *pair*) : ;;
  *) fail "5: the stated reason must name the PAIRED-OUTCOME unit it was decided in, got: $out5" ;;
esac
ok "5 DEFECT B: a capped batch yielding 10 pairs against a floor of 20 reports significance_reachable:false (pool of 30 records notwithstanding)"

# ---------------------------------------------------------------------------
# 6. The positive control, in the same unit: 20 eligible records, an
#    unbinding cap, floor 20 -> 20 planned pairs -> reachable:true. Proves
#    test 5 is not simply "always false".
# ---------------------------------------------------------------------------
count
out6="$(pf env REPLAY_PREFLIGHT_BATCH_CAP=100 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=1 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS=500 \
  MODEL_COMPARISON_MIN_SAMPLE_N=20 \
  bash "$SUT" preflight --corpus-file "$CORPUS_20")"
[ "$(jq -r .planned_pairs_n <<<"$out6")" = "20" ] || fail "6: expected planned_pairs_n 20, got: $out6"
[ "$(jq -r .significance_reachable <<<"$out6")" = "true" ] || fail "6: expected significance_reachable true (20 pairs >= floor 20), got: $out6"
ok "6 20 planned pairs against a floor of 20 reports significance_reachable:true (the positive control)"

# ---------------------------------------------------------------------------
# 7. The MDE disclosure is taken at the PLANNED-PAIR n — byte-identical to a
#    direct stats.sh call at that n. Disclosing it at the larger record-pool
#    n would advertise a smaller detectable effect than the run can deliver.
# ---------------------------------------------------------------------------
count
[ "$(jq -r .mde_n <<<"$out5")" = "10" ] || fail "7: expected mde_n 10 (the planned pairs), got: $out5"
direct_mde="$(jq -c . <<<"$(bash "$STATS_SUT" mde --n 10 --stddev 500)")"
[ "$(jq -c .mde <<<"$out5")" = "$direct_mde" ] \
  || fail "7: preflight's mde is not byte-identical to a direct stats.sh mde --n 10 --stddev 500 call: $out5"
ok "7 the MDE disclosure is computed at the planned-PAIR n (10), byte-identical to a direct stats.sh call"

# --- 8. MUTATION PROOF: revert the floor comparison to the record pool -----
count
cp "$SUT" "$WORK/replay.sh.orig-8"
mutate_file "$SUT" \
  '  elif [ "$planned_pairs" -ge "$MODEL_COMPARISON_MIN_SAMPLE_N" ]; then' \
  '  elif [ "$eligible_n" -ge "$MODEL_COMPARISON_MIN_SAMPLE_N" ]; then' \
  || fail "8m: mutation apply failed"
mut_out="$(pf env REPLAY_PREFLIGHT_BATCH_CAP=10 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=1 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS=500 \
  MODEL_COMPARISON_MIN_SAMPLE_N=20 \
  bash "$SUT" preflight --corpus-file "$CORPUS_30")"
cp "$WORK/replay.sh.orig-8" "$SUT"
[ "$(jq -r .significance_reachable <<<"$mut_out")" = "true" ] \
  || fail "8m: expected the pool-comparing (mutated) script to report the floor REACHABLE for a batch that cannot reach it: $mut_out"
ok "8m MUTATION PROOF: comparing the eligible-RECORD pool instead of the planned PAIRS reports an unreachable floor as reachable — restored, test 5 above is green again"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION C — UNIT LEGIBILITY: a reader can tell which unit each number is in
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# 9. Every count field that could be read in more than one unit declares its
#    unit in the emitted `units` map — no reader has to infer it.
# ---------------------------------------------------------------------------
count
for f in eligible_n planned_n planned_records_n planned_replays_n planned_pairs_n \
         eligible_pairs_n estimated_total_tokens min_sample_n; do
  u="$(jq -r --arg f "$f" '.units[$f] // empty' <<<"$out5")"
  [ -n "$u" ] || fail "9: field $f carries no declared unit in the emitted units map: $out5"
done
[ "$(jq -r '.units.planned_records_n' <<<"$out5")" = "corpus_records" ] || fail "9: planned_records_n should declare corpus_records, got: $out5"
[ "$(jq -r '.units.planned_replays_n' <<<"$out5")" = "executed_replays" ] || fail "9: planned_replays_n should declare executed_replays, got: $out5"
[ "$(jq -r '.units.planned_pairs_n' <<<"$out5")" = "paired_outcomes" ] || fail "9: planned_pairs_n should declare paired_outcomes, got: $out5"
[ "$(jq -r '.units.min_sample_n' <<<"$out5")" = "paired_outcomes" ] || fail "9: min_sample_n should declare paired_outcomes — the unit the report producer applies it in, got: $out5"
ok "9 every ambiguous count declares its unit (corpus_records / executed_replays / paired_outcomes / tokens)"

# ---------------------------------------------------------------------------
# 10. The three units are internally consistent on a real run:
#     replays = records * arms, pairs = records, eligible_pairs = eligible_n.
# ---------------------------------------------------------------------------
count
jq -e '
  .planned_replays_n == (.planned_records_n * .arms_n)
  and .planned_pairs_n == .planned_records_n
  and .eligible_pairs_n == .eligible_n
  and .planned_n == .planned_records_n
' >/dev/null <<<"$out5" || fail "10: the emitted unit relationships are not internally consistent: $out5"
ok "10 records/replays/pairs are internally consistent (replays = records x arms, pairs = records)"

# ---------------------------------------------------------------------------
# 11. cost_basis is stated, and the per-replay estimate stays a
#     per-EXECUTED-REPLAY figure this suite's two-arm arithmetic multiplies.
#     The UNIT that cost_basis names was temperloop#1380's seam and has since
#     moved from the raw "token_count" to the report producer's own
#     "cost-weighted-token-units"; the preflight/report AGREEMENT is pinned
#     in test_replay_preflight_cost_unit.sh, not here. This assertion is
#     unchanged in substance — it still pins that a basis is stated and that
#     the per-replay figure is echoed, not hardcoded.
# ---------------------------------------------------------------------------
count
[ "$(jq -r .cost_basis <<<"$out5")" = "cost-weighted-token-units" ] || fail "11: cost_basis must be the shared cost-weighted-token-units, got: $out5"
[ "$(jq -r .tokens_per_replay_estimate <<<"$out5")" = "1" ] || fail "11: tokens_per_replay_estimate must echo the configured per-replay figure unchanged, got: $out5"
ok "11 cost_basis is stated (cost-weighted-token-units) and tokens_per_replay_estimate stays a per-EXECUTED-REPLAY figure"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D — FAIL CLOSED on an INDETERMINATE estimate (temperloop#1365)
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# 12. A non-integer setting makes the batch estimate impossible to EVALUATE.
#     It must surface as CANNOT_EVALUATE + non-zero — never as a silently
#     zero/garbage estimate that renders as "evaluated, and comfortably
#     under the ceiling".
# ---------------------------------------------------------------------------
count
rc=0
out12="$(pf env REPLAY_PREFLIGHT_BATCH_CAP=100 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=150k \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_5" 2>"$WORK/pf-stderr.txt")" || rc=$?
[ "$rc" -ne 0 ] || fail "12: expected non-zero exit for a non-integer REPLAY_PREFLIGHT_TOKENS_PER_REPLAY, got: $out12"
[ "$(jq -r .outcome <<<"$out12" 2>/dev/null)" = "CANNOT_EVALUATE" ] || fail "12: expected CANNOT_EVALUATE, got: $out12"
case "$out12" in *'"estimated_total_tokens"'*) fail "12: FAIL-OPEN — an estimate leaked out for arithmetic that could not be evaluated: $out12" ;; esac
case "$(cat "$WORK/pf-stderr.txt")" in
  *"CANNOT EVALUATE"*) ;;
  *) fail "12: expected a distinct 'CANNOT EVALUATE' line on stderr, got: $(cat "$WORK/pf-stderr.txt")" ;;
esac
ok "12 FAIL CLOSED: a non-integer cost setting -> CANNOT_EVALUATE, non-zero, no estimate leaks out"

echo "---"
echo "$pass/$total tests passed"
[ "$pass" -eq "$total" ] || exit 1
