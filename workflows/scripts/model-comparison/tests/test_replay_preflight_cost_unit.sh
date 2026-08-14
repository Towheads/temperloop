#!/usr/bin/env bash
#
# test_replay_preflight_cost_unit.sh — the COST-UNIT suite for the replay
# spend gate (temperloop#1380, epic #1225 "model comparison harness"). The
# third suite over `replay.sh preflight`, and — like its two siblings — a
# separate file because it defends a different failure surface:
#
#   * test_replay_preflight.sh       the PLUMBING (settings read, ceiling
#                                    stops, quota gate consulted, unreadable
#                                    input fails closed)
#   * test_replay_preflight_two_arm.sh  the COUNT units (corpus records vs
#                                    executed replays vs paired outcomes)
#   * THIS FILE                      the COST unit (what a "token" IS, and
#                                    whether the spend gate and the report
#                                    mean the same thing by it)
#
# ── THE DEFECT THIS PINS ───────────────────────────────────────────────────
# Both earlier suites stayed fully green while the gate was unusable, because
# each number was internally consistent — in a unit nobody else spoke:
#
#   * `preflight` emitted `cost_basis: "token_count"` and treated
#     REPLAY_PREFLIGHT_TOKENS_PER_REPLAY as a RAW token sum.
#   * workflows/scripts/report-producers/model-comparison emitted
#     `cost_basis.unit: "token-counts"` over the SPEND_WEIGHT_* multiply-add,
#     i.e. COST-WEIGHTED units.
#
# Two non-comparable units under the same word "token". On the one observed
# live replay (temperloop#1380's measurement) they differ by 5.4x — raw
# 2,506,371 vs cost-weighted 466,530 — so the batch cost an operator
# authorized at the gate could not be reconciled against the cost the report
# handed back, and the per-replay constant (150,000) was 16.7x low against
# raw and 3.1x low against weighted at the same time.
#
# The fix converges BOTH surfaces on the cost-weighted unit — the one that
# tracks spend (the dominant term in a real replay is cache_read, which the
# default weights price at a tenth) and the one the report an operator
# reconciles against already used.
#
# ── WHAT IS ASSERTED, AND HOW ──────────────────────────────────────────────
# Everything below is asserted on REAL EMITTED JSON from BOTH surfaces —
# `replay.sh preflight`'s stdout and exit code, and the report producer's own
# stdout after a real run over a fixture repo — never on internal shell state
# and never on a grep of either file's source. The agreement assertion is
# genuinely a cross-surface measurement: it runs the two programs and
# compares what they printed.
#
# Sections:
#   1-2  AGREEMENT — the two surfaces emit the SAME cost_basis string, and it
#        names a cost-WEIGHTED unit (not merely "tokens"), + MUTATION PROOF
#   3-5  THE CONSTANT — the shipped per-replay default is in the weighted
#        unit and grounded in the recorded n=1 measurement (not the old
#        placeholder, and not the raw total pasted in by mistake); the
#        estimate scales over executed replays in that same unit; the emitted
#        weights are the SPEND_WEIGHT_* actually in force
#   6-7  THE CEILING — re-examined for the new unit: a floor-sized comparison
#        and a default-cap batch both clear the shipped ceiling, while the
#        PRE-FIX ceiling literal stops the floor-sized one (so a half-fix
#        that raised the constant and left the ceiling alone is caught)
#   8    PROVENANCE — the per-replay figure publishes its n=1 estimate
#        provenance on every run, never presenting itself as measured here
#   9    FAIL CLOSED on an undefined unit (the temperloop#1365 class): the
#        SPEND_WEIGHT_* settings define the unit the estimate and the ceiling
#        are denominated in, so unresolvable weights are CANNOT_EVALUATE and
#        non-zero — never an estimate in a unit that has no definition, +
#        MUTATION PROOF
#
# Hermetic: no `gh` call, no network, no live model call, no replay executed.
# preflight reads a plain corpus JSONL fixture; the producer reads two plain
# record JSONL fixtures under a throwaway repo; quota-gate.sh is pointed at a
# nonexistent cache so it reports "unavailable" (fail open) and can never be
# the reason anything below stops. No mapfile / associative arrays / GNU-only
# flags (bash 3.2).
#
# NOTE FOR THE GATE POOL: sections 2 and 9 mutate a $WORK-local COPY of
# workflows/scripts/model-comparison/replay.sh (temperloop#1421 — never the
# live tree file, which stays untouched throughout this suite), so nothing
# below requires the SERIAL lane its three replay siblings sit in for other
# reasons in scripts/quality-gates.sh.
#
# Usage: bash workflows/scripts/model-comparison/tests/test_replay_preflight_cost_unit.sh
#
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd "$HERE/.." && pwd)"
SCRIPTS_DIR="$(cd "$MC_DIR/.." && pwd)"
SUT="$MC_DIR/replay.sh"
PRODUCER="$SCRIPTS_DIR/report-producers/model-comparison"

# THE MEASUREMENT, transcribed from temperloop#1380 (one completed live
# replay of the temperloop#1262 harness validation run). Both figures are
# needed: the weighted one is what the constant must be near, and the RAW one
# is what it must NOT be near — a "fix" that pasted the raw total in would
# leave the same unit collision pointing the other way.
MEASURED_WEIGHTED=466530
MEASURED_RAW=2506371
# The pre-fix literals, kept here so the assertions below can say "not this"
# by value rather than by adjective.
OLD_TOKENS_PER_REPLAY=150000
OLD_CEILING=8000000

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-replay-preflight-cost-unit-XXXXXX")"
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# mutate_file <file> <old-literal-text> <new-literal-text> — exact, literal,
# single-occurrence replacement (the twin of the two sibling suites'). Dies
# loudly if the old text is missing or not unique, so a mutation proof can
# never silently degrade into a no-op that "passes".
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

# mk_mirror <dest> — a throwaway, symlink-backed mirror of workflows/scripts
# under <dest> (same helper as test_replay_score.sh's own, temperloop#1421),
# so a mutation proof can edit ONE real copy of replay.sh without ever
# writing into the checkout — in a vendoring overlay $SUT is a composed-tree
# SYMLINK into kernel/, and an in-place mutation (write-temp-then-rename-
# over-path) would replace the symlink with a forked regular file.
# Relative resolution (HERE/../build, HERE/stats.sh, etc.) all still work
# because the DIRECTORIES are real and only the leaves are links.
mk_mirror() {
  local d="$1" f b
  mkdir -p "$d/workflows/scripts/model-comparison"
  for f in "$SCRIPTS_DIR"/*; do
    b="$(basename "$f")"
    [ "$b" = "model-comparison" ] && continue
    ln -s "$f" "$d/workflows/scripts/$b"
  done
  for f in "$MC_DIR"/*; do
    ln -s "$f" "$d/workflows/scripts/model-comparison/$(basename "$f")"
  done
}

# unlink_and_copy <mirror-path> — swap one mirrored symlink for a real,
# editable copy of its target (same helper as test_replay_score.sh's own).
unlink_and_copy() {
  local p="$1" target
  target="$(cd -P "$(dirname "$p")" && pwd)/$(basename "$p")"
  local real; real="$(readlink "$target")"
  rm -f "$target"
  cp "$real" "$target"
  chmod u+w "$target"
}

# mk_corpus <file> <n-eligible> — n eligible corpus records, one per line,
# each a distinct merged outcome, exactly as `corpus` emits them.
mk_corpus() {
  local file="$1" n="$2" i=1
  : >"$file"
  while [ "$i" -le "$n" ]; do
    jq -cn --argjson pr "$i" '{pr:$pr, status:"eligible"}' >>"$file"
    i=$((i + 1))
  done
}

NOCACHE="$WORK/no-such-quota-cache.json"

# pf <env-assignments...> — preflight with the quota gate deterministically
# "unavailable" (fail open: it can never be the reason anything here stops).
pf() {
  env BUILD_QUOTA_CACHE="$NOCACHE" "$@"
}

# ── the report producer's fixture repo ─────────────────────────────────────
# Two arms of real replay records; the producer's cwd is the target repo by
# contract, and a relative records dir resolves against it.
REPO="$WORK/repo"
mkdir -p "$REPO/.temperloop/model-comparison" "$REPO/meta/data/raw"
mk_record() {
  jq -cn --argjson pr "$1" --arg model "$2" '
    {pr:$pr, issue:($pr - 100), merge_commit:"mc0001", base:"base0001", head:"head0001",
     title:"item \($pr)", scope:null, acceptance:["does a thing"], notes:"",
     status:"eligible", reject_reason:"", flags:[],
     buckets:{N:["a.sh"], T:["tests/t.sh"], X:[], R:[]},
     template_sha:"tpl0000", file_count:2,
     worktree:{path:"/tmp/wt", branch:"replay/\($pr)", prepared_at:"2026-08-01T10:00:00Z"},
     candidate:{provider:"anthropic", model:$model, diff_ref:"cafe",
                tokens:{input:100, output:200, cache_read:5000, cache_creation:300},
                duration_ms:1000, outcome:"scored", integration_error:null,
                disclosed:false, prompt_sha256:"aa"},
     score:{outcome:"SCORED", scored:true, verdict:"pass", not_scored_reason:null,
            base:"base0001", truth_head:"head0001", diff:null,
            gate_result:{outcome:"GATES", ran:true, gate_script:"scripts/quality-gates.sh",
                         exit_code:0, passed:true, timed_out:false, duration_ms:10,
                         timeout_secs:1800},
            acceptance_results:[], components:null, contamination_flags:[]}}'
}
i=1
while [ "$i" -le 3 ]; do
  mk_record "$i" baseline-model >>"$REPO/.temperloop/model-comparison/baseline.jsonl"
  mk_record "$i" candidate-model >>"$REPO/.temperloop/model-comparison/candidate.jsonl"
  i=$((i + 1))
done

# report_unit — run the REAL producer and print the cost_basis unit it
# actually emitted. Never a grep of its source: the assertion has to be over
# what the program prints, since that is what an operator reads.
report_unit() {
  ( cd "$REPO" && bash "$PRODUCER" ) 2>/dev/null | jq -r '.cost_basis.unit // "<<absent>>"'
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION A — AGREEMENT: ONE unit, named identically on both surfaces
# ═══════════════════════════════════════════════════════════════════════════

CORPUS_20="$WORK/corpus-20.jsonl"
mk_corpus "$CORPUS_20" 20
CORPUS_60="$WORK/corpus-60.jsonl"
mk_corpus "$CORPUS_60" 60

# ---------------------------------------------------------------------------
# 1. THE DEFECT, END TO END: the spend gate's emitted `cost_basis` and the
#    report producer's emitted `cost_basis.unit` are the SAME STRING. Both
#    read off real runs of both programs. This is the assertion the unfixed
#    code fails ("token_count" vs "token-counts").
# ---------------------------------------------------------------------------
count
pf_out="$(pf bash "$SUT" preflight --corpus-file "$CORPUS_20")"
[ "$(jq -r .outcome <<<"$pf_out")" = "PREFLIGHT" ] || fail "1: expected a PREFLIGHT result at shipped defaults, got: $pf_out"
pf_unit="$(jq -r '.cost_basis // "<<absent>>"' <<<"$pf_out")"
rep_unit="$(report_unit)"
[ "$rep_unit" != "<<absent>>" ] || fail "1: the report producer emitted no cost_basis.unit — the fixture run degraded"
[ "$pf_unit" = "$rep_unit" ] \
  || fail "1: THE UNIT COLLISION IS OPEN — pre-flight authorizes a batch in '$pf_unit' while the report reports in '$rep_unit'; an operator cannot reconcile the two"
ok "1 pre-flight and the report producer emit the SAME cost_basis string ('$pf_unit'), read off real runs of both"

# ---------------------------------------------------------------------------
# 2. The agreed unit names a COST-WEIGHTED unit, not merely "tokens". Two
#    surfaces agreeing on an ambiguous word would re-open the same defect the
#    moment one of them changed what it meant by it.
# ---------------------------------------------------------------------------
count
case "$pf_unit" in
  *cost-weighted*) : ;;
  *) fail "2: the agreed unit must SAY it is cost-weighted (SPEND_WEIGHT_* multiply-add), got: '$pf_unit'" ;;
esac
jq -e '.cost_basis_statement | test("SPEND_WEIGHT")' >/dev/null <<<"$pf_out" \
  || fail "2: the pre-flight must state which weighting defines its unit, got: $pf_out"
ok "2 the agreed unit explicitly names cost-weighting ('$pf_unit'), never a bare 'token'"

# --- 2m. MUTATION PROOF for 1 ---------------------------------------------
#     Revert the gate's unit constant to the pre-fix raw name and the
#     agreement assertion must go RED — proving test 1 measures the two
#     programs' actual agreement and is not a tautology over one constant.
count
MIRROR_2M="$WORK/mirror-2m"
mk_mirror "$MIRROR_2M"
SUT_2M="$MIRROR_2M/workflows/scripts/model-comparison/replay.sh"
unlink_and_copy "$SUT_2M"
mutate_file "$SUT_2M" \
  'REPLAY_COST_BASIS_UNIT="cost-weighted-token-units"' \
  'REPLAY_COST_BASIS_UNIT="token_count"' \
  || fail "2m: mutation apply failed"
mut_out="$(pf bash "$SUT_2M" preflight --corpus-file "$CORPUS_20")"
mut_unit="$(jq -r '.cost_basis // "<<absent>>"' <<<"$mut_out")"
rm -rf "$MIRROR_2M"
[ "$mut_unit" = "token_count" ] || fail "2m: the mutation did not take effect (got '$mut_unit')"
[ "$mut_unit" != "$rep_unit" ] \
  || fail "2m: reverting the gate to the pre-fix raw unit still agreed with the report — test 1 is not load-bearing"
# and the real, untouched $SUT still agrees (it was never written to)
[ "$(jq -r .cost_basis <<<"$(pf bash "$SUT" preflight --corpus-file "$CORPUS_20")")" = "$rep_unit" ] \
  || fail "2m: the real \$SUT no longer agrees with the report — mutation leaked outside its \$WORK mirror copy"
ok "2m MUTATION PROOF: reverting the gate's unit to the pre-fix 'token_count' breaks agreement with the report (mutation isolated to a \$WORK mirror copy, test 1 green again against the real \$SUT)"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B — THE CONSTANT: in the pinned unit, grounded in the measurement
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# 3. The SHIPPED per-replay default is the measured COST-WEIGHTED figure, not
#    the old placeholder and not the measured RAW total. Bounded on both
#    sides deliberately: a raw-unit constant for the same replay would be
#    ~5.4x larger, so "somewhere between the weighted measurement and the raw
#    one" is exactly the interval that distinguishes the two units.
#    Asserted on the emitted JSON (the gate echoes the figure it used), never
#    by reading build.config.sh.
# ---------------------------------------------------------------------------
count
tpr="$(jq -r .tokens_per_replay_estimate <<<"$pf_out")"
case "$tpr" in ''|*[!0-9]*) fail "3: tokens_per_replay_estimate is not an integer: $pf_out" ;; esac
[ "$tpr" != "$OLD_TOKENS_PER_REPLAY" ] \
  || fail "3: the per-replay figure is still the pre-measurement placeholder $OLD_TOKENS_PER_REPLAY — 3.1x low in the weighted unit, 16.7x low against raw"
[ "$tpr" -ge "$MEASURED_WEIGHTED" ] \
  || fail "3: the per-replay figure ($tpr) is BELOW the one measured cost-weighted replay ($MEASURED_WEIGHTED) — the gate would under-project every batch"
[ "$tpr" -lt "$MEASURED_RAW" ] \
  || fail "3: the per-replay figure ($tpr) is at or above the measured RAW total ($MEASURED_RAW) — that is the raw unit, not the cost-weighted one the report speaks"
ok "3 the shipped per-replay default ($tpr) is the measured COST-WEIGHTED figure, not the old placeholder and not the raw total"

# ---------------------------------------------------------------------------
# 4. The estimate is that constant scaled over EXECUTED REPLAYS, and every
#    cost-bearing field declares the ONE unit. The #1379 two-arm relationship
#    is untouched: records x arms, never records alone.
# ---------------------------------------------------------------------------
count
jq -e --arg u "$pf_unit" '
    .estimated_total_tokens == (.planned_records_n * .arms_n * .tokens_per_replay_estimate)
    and .planned_replays_n == (.planned_records_n * .arms_n)
    and .units.estimated_total_tokens == $u
    and .units.ceiling_tokens == $u
    and .units.assumed_stddev_tokens == $u
    and (.units.tokens_per_replay_estimate | startswith($u))
  ' >/dev/null <<<"$pf_out" \
  || fail "4: the estimate does not scale over executed replays in the declared unit, or a cost field fails to declare it: $pf_out"
ok "4 the estimate is per-replay x records x arms, and estimate/ceiling/stddev all declare the one unit"

# ---------------------------------------------------------------------------
# 5. The weights that DEFINE the unit are published, and are the
#    SPEND_WEIGHT_* actually in force — a weighted figure whose weights are
#    not stated cannot be reconciled against a report from a different
#    weight-retune epoch. Proved by moving a weight and watching the emitted
#    block move with it.
# ---------------------------------------------------------------------------
count
jq -e '(.cost_weights | type) == "object"
       and ((.cost_weights.input | type) == "number")
       and ((.cost_weights.cache_read | type) == "number")
       and ((.cost_weights.cache_creation | type) == "number")
       and ((.cost_weights.output | type) == "number")' >/dev/null <<<"$pf_out" \
  || fail "5: the pre-flight must publish the four SPEND_WEIGHT_* values its unit is defined by: $pf_out"
w_out="$(pf env SPEND_WEIGHT_INPUT=2 SPEND_WEIGHT_CACHE_READ=0.4 \
  SPEND_WEIGHT_CACHE_CREATE=3 SPEND_WEIGHT_OUTPUT=9 \
  bash "$SUT" preflight --corpus-file "$CORPUS_20")"
jq -e '.cost_weights == {input:2, cache_read:0.4, cache_creation:3, output:9}' >/dev/null <<<"$w_out" \
  || fail "5: the published weights are hardcoded, not the SPEND_WEIGHT_* in force: $w_out"
ok "5 the SPEND_WEIGHT_* values defining the unit are published, and track the settings actually in force"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION C — THE CEILING, re-examined for the new unit
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# 6. At shipped defaults the ceiling is a GATE, not a WALL: the smallest
#    statistically meaningful comparison (MODEL_COMPARISON_MIN_SAMPLE_N
#    paired outcomes) clears it, and so does a batch-cap-sized one. A ceiling
#    left at its old raw-unit value would stop both.
# ---------------------------------------------------------------------------
count
[ "$(jq -r .stop <<<"$pf_out")" = "false" ] \
  || fail "6: a floor-sized comparison is stopped at shipped defaults — the ceiling was not re-expressed in the new unit: $pf_out"
[ "$(jq -r .significance_reachable <<<"$pf_out")" = "true" ] \
  || fail "6: a floor-sized batch should reach significance (the #1379 pairs check), got: $pf_out"
cap_out="$(pf bash "$SUT" preflight --corpus-file "$CORPUS_60")"
[ "$(jq -r .batch_cap_applied <<<"$cap_out")" = "true" ] || fail "6: expected the batch cap to bind on a 60-record corpus: $cap_out"
[ "$(jq -r .stop <<<"$cap_out")" = "false" ] \
  || fail "6: a DEFAULT-BATCH-CAP-sized batch is stopped at shipped defaults — the ceiling no longer sits above the batch its own cap admits: $cap_out"
ok "6 at shipped defaults both a floor-sized and a cap-sized batch clear the ceiling (a gate, not a wall)"

# ---------------------------------------------------------------------------
# 7. THE CEILING CHANGE IS LOAD-BEARING — no file mutation needed, the
#    pre-fix literal is the mutation: with the OLD ceiling and the NEW
#    per-replay constant, the same floor-sized batch STOPS. So a half-fix
#    that grounded the constant in the measurement and left the ceiling at a
#    value chosen under the raw unit is caught here.
# ---------------------------------------------------------------------------
count
old_rc=0
old_out="$(pf env REPLAY_PREFLIGHT_CEILING_TOKENS="$OLD_CEILING" \
  bash "$SUT" preflight --corpus-file "$CORPUS_20")" || old_rc=$?
[ "$old_rc" -ne 0 ] || fail "7: expected a non-zero exit under the pre-fix ceiling: $old_out"
[ "$(jq -r .stop <<<"$old_out")" = "true" ] || fail "7: expected stop:true under the pre-fix ceiling, got: $old_out"
[ "$(jq -r .stop_reason <<<"$old_out")" = "ceiling_exceeded" ] || fail "7: expected ceiling_exceeded, got: $old_out"
ok "7 the pre-fix ceiling literal STOPS a floor-sized batch under the measured constant — the ceiling re-derivation is load-bearing"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D — PROVENANCE: how much confidence the number deserves, on the run
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# 8. The per-replay figure publishes its own provenance every run: an
#    ESTIMATE, n=1, and NOT derived from any observed record here. A number
#    this load-bearing must not read as measured-on-your-data when it is one
#    transcribed observation.
# ---------------------------------------------------------------------------
count
jq -e '(.tokens_per_replay_basis | type) == "string"
       and (.tokens_per_replay_basis | test("(?i)estimate"))
       and (.tokens_per_replay_basis | test("n=1"))
       and (.tokens_per_replay_basis | test("NOT derived"))' >/dev/null <<<"$pf_out" \
  || fail "8: the per-replay figure must publish its n=1 / estimate / not-derived-here provenance: $pf_out"
ok "8 the per-replay figure publishes its provenance (estimate, n=1, not derived from observed records) on every run"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E — FAIL CLOSED on an UNDEFINED unit (temperloop#1365 class)
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# 9. The SPEND_WEIGHT_* settings DEFINE the unit the estimate and the ceiling
#    are denominated in. If they cannot be resolved, the projected cost has
#    no defined unit and cannot be reconciled against the report — so this is
#    CANNOT_EVALUATE and non-zero, with NO estimate emitted. The report
#    producer refuses on exactly the same input, for the same reason; the two
#    surfaces must fail together or one would publish a unit the other could
#    not.
# ---------------------------------------------------------------------------
#    Both shapes of unresolvable are refused: a value that is not a number at
#    all, and a NEGATIVE one — the same two the report producer's identical
#    predicate rejects. The negative case is the interesting one and is what
#    the mutation proof below uses, because `-1` is perfectly valid JSON: it
#    would sail past a naive "did jq accept it" check and be silently applied
#    as a weight, so only the real guard can catch it.
# ---------------------------------------------------------------------------
count
for bad_w in "zero-point-one" "-1"; do
  bad_rc=0
  bad_out="$(pf env SPEND_WEIGHT_CACHE_READ="$bad_w" \
    bash "$SUT" preflight --corpus-file "$CORPUS_20")" || bad_rc=$?
  [ "$bad_rc" -ne 0 ] || fail "9: expected a NON-ZERO exit on an unresolvable cost weight ('$bad_w'), got: $bad_out"
  [ "$(jq -r .outcome <<<"$bad_out")" = "CANNOT_EVALUATE" ] || fail "9: expected CANNOT_EVALUATE for weight '$bad_w', got: $bad_out"
  jq -e 'has("estimated_total_tokens") or has("stop") | not' >/dev/null <<<"$bad_out" \
    || fail "9: a CANNOT_EVALUATE must carry NO estimate and NO stop verdict — it must never read as 'evaluated, and fine': $bad_out"
done
ok "9 FAIL CLOSED: an unresolvable SPEND_WEIGHT_* (non-numeric OR negative) -> CANNOT_EVALUATE, non-zero, no estimate in an undefined unit"

# --- 9m. MUTATION PROOF for 9 ---------------------------------------------
#     Break the weights guard's own match arm and the negative weight must
#     sail through as a normal PREFLIGHT, silently applied — proving test 9
#     measures that guard rather than the JSON parse that follows it.
count
MIRROR_9M="$WORK/mirror-9m"
mk_mirror "$MIRROR_9M"
SUT_9M="$MIRROR_9M/workflows/scripts/model-comparison/replay.sh"
unlink_and_copy "$SUT_9M"
mutate_file "$SUT_9M" \
  "      ''|*[!0-9.]*|*.*.*)" \
  "      __this_pattern_can_never_match__)" \
  || fail "9m: mutation apply failed"
# The exit code is deliberately not asserted here: the POINT of this mutation
# is that the run stops failing closed at all, which the outcome below states.
mut9_out="$(pf env SPEND_WEIGHT_CACHE_READ="-1" \
  bash "$SUT_9M" preflight --corpus-file "$CORPUS_20")" || true
rm -rf "$MIRROR_9M"
[ "$(jq -r .outcome <<<"$mut9_out")" = "PREFLIGHT" ] \
  || fail "9m: disabling the weights guard did not reproduce the fail-OPEN behavior — test 9 is not load-bearing (got: $mut9_out)"
[ "$(jq -r .cost_weights.cache_read <<<"$mut9_out")" = "-1" ] \
  || fail "9m: expected the unguarded run to publish the nonsense weight it accepted, got: $mut9_out"
# the real, untouched $SUT still guards (it was never written to)
rest_rc=0
rest_out="$(pf env SPEND_WEIGHT_CACHE_READ="-1" \
  bash "$SUT" preflight --corpus-file "$CORPUS_20")" || rest_rc=$?
[ "$rest_rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$rest_out")" = "CANNOT_EVALUATE" ] \
  || fail "9m: the real \$SUT no longer guards — mutation leaked outside its \$WORK copy (got: $rest_out)"
ok "9m MUTATION PROOF: disabling the weights guard makes a negative weight fail OPEN and be applied silently (mutation isolated to a \$WORK copy, test 9 green again against the real \$SUT)"

echo
echo "test_replay_preflight_cost_unit.sh: $pass/$total checks passed"
[ "$pass" -eq "$total" ] || exit 1
