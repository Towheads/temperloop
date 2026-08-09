#!/usr/bin/env bash
#
# test_comparison_report.sh — fixture suite for the COMPARISON REPORT producer
# (temperloop#1261, epic #1225 "model comparison harness"):
# workflows/scripts/report-producers/model-comparison.
#
# ── WHAT THIS SUITE IS DEFENDING ───────────────────────────────────────────
# The producer is the surface a human reads to make a model-routing decision,
# so the failure mode that matters is not "a wrong number" but "a number that
# looks trustworthy and is not". Four guarantees carry that weight, and each
# one here is proved by BREAKING it and watching the suite go red, not merely
# by observing it hold:
#
#   1. Below the configured sample floor the report says `inconclusive` and
#      names NO winner. Proved twice over: remove the producer's own winner
#      gate and a winner appears; and, separately, remove the floor inside
#      stats.py itself and a winner appears through the unmodified producer —
#      so the producer is shown to ride the library's floor rather than a
#      private re-implementation of it.
#   2. The four honesty disclosures — emit-coverage %, corpus window, gate
#      versions, cost basis — appear on a FLATTERING run, not only a degraded
#      one. Each is deleted from a passing report in turn and the assertion
#      that guards it must go red.
#   3. A degraded run emits NO fabricated figure: no `winner` key and no cost
#      figure anywhere, while still exiting 0 with a single `skipped -- ` line.
#      Proved by rewriting the producer's own degradation path to emit a
#      fabricated object and watching the assertion catch it.
#   4. Every statistic is CONSUMED from stats.sh, never recomputed here. The
#      published CI and MDE must be byte-identical to an independent stats.sh
#      call over the producer's own published delta array; a mutation that
#      nudges the published bound by 5% must go red.
#
# ── HERMETIC BY CONSTRUCTION ───────────────────────────────────────────────
# Zero network, zero model calls, zero writes outside $TMPDIR. Section L is a
# suite-wide canary: `claude`, `gh`, `curl` and `wget` stand-ins are prepended
# to PATH for the whole run and must never be invoked by anything under test.
# Section L2 proves the canary can actually fire, so L1 is a measurement
# rather than a tautology.
#
# ── MUTATION MECHANISM ─────────────────────────────────────────────────────
# `mkmirror` builds a throwaway tree whose layout satisfies the producer's own
# sibling-relative resolution ($0/../model-comparison, ../build, ../config),
# with the model-comparison module and the pricing config COPIED (so they can
# be mutated) and build/lib SYMLINKED (so nothing under test resolves against
# a stale duplicate of the real config). Nothing in the real tree is ever
# written.
#
# Usage: bash workflows/scripts/model-comparison/tests/test_comparison_report.sh
#
# shellcheck disable=SC2016
#
# Blanket shellcheck exemptions, each with its reason:
#   SC2016  jq filters are single-quoted on purpose; $foo inside one is a jq
#           variable, never a shell one.
#   SC2030/SC2031  several tests deliberately export a setting inside a ( … )
#           subshell so the override applies to exactly one producer run and
#           cannot leak into the next assertion. The "change might be lost"
#           warning is the intended behaviour here, not a bug.
#   SC2089/SC2090  the fabrication mutation in section E carries literal
#           backslash-escaped quotes because its value IS shell source text
#           being injected into a mirrored script; an array would defeat the
#           point.
# shellcheck disable=SC2030,SC2031,SC2089,SC2090

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd "$HERE/.." && pwd)"
SCRIPTS_DIR="$(cd "$MC_DIR/.." && pwd)"
PRODUCER="$SCRIPTS_DIR/report-producers/model-comparison"
STATS="$MC_DIR/stats.sh"

# shellcheck source=../../lib/portable-timeout.sh
. "$SCRIPTS_DIR/lib/portable-timeout.sh"

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-comparison-report-XXXXXX")"
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# ═══════════════════════════════════════════════════════════════════════════
# THE CANARIES — network/model entry points no test may ever reach.
# ═══════════════════════════════════════════════════════════════════════════
CANARY="$WORK/CANARY"
mkdir -p "$WORK/bin"
for tool in claude gh curl wget; do
  cat >"$WORK/bin/$tool" <<EOF
#!/usr/bin/env bash
printf 'INVOKED %s %s\n' "$tool" "\$*" >>"$CANARY"
exit 0
EOF
  chmod +x "$WORK/bin/$tool"
done
PATH="$WORK/bin:$PATH"
export PATH

# ═══════════════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════════════

# mkrepo <dir> — a stand-in "target repo": the cwd shape report.sh hands a
# producer, carrying the records dir and an empty attribution raw lake.
mkrepo() {
  rm -rf "$1"
  mkdir -p "$1/.temperloop/model-comparison" "$1/meta/data/raw"
}

# record <pr> <arm-model> <input-tokens> <output-tokens> <verdict> <gate-passed>
#        <judge-outcome> <quality-score> <prepared-day> <outcome> [judge-notice]
# Emits ONE replay-record-v1-shaped line. This is INPUT DATA only — no figure
# the producer computes is recomputed here.
record() {
  local pr="$1" model="$2" inp="$3" outp="$4" verdict="$5" gate="$6" \
        jout="$7" qs="$8" day="$9" outcome="${10}" jnotice="${11:-}"
  local tokens='null' scoreobj judgeobj interr='null'
  if [ "$outcome" = "scored" ]; then
    tokens="$(jq -cn --argjson i "$inp" --argjson o "$outp" \
      '{input:$i, output:$o, cache_read:2000, cache_creation:100}')"
    scoreobj="$(jq -cn --arg v "$verdict" --argjson g "$gate" \
      '{outcome:"SCORED", scored:true, verdict:$v, not_scored_reason:null,
        base:"base0001", truth_head:"head0001", diff:null,
        gate_result:{outcome:"GATES", ran:true, gate_script:"scripts/quality-gates.sh",
                     exit_code:(if $g then 0 else 1 end), passed:$g,
                     timed_out:false, duration_ms:1000, timeout_secs:1800},
        acceptance_results:[], components:null, contamination_flags:[]}')"
  else
    scoreobj='{"outcome":"NOT_SCORED","scored":false,"verdict":null,"not_scored_reason":"integration-error","base":null,"truth_head":null,"diff":null,"gate_result":null,"acceptance_results":null,"components":null,"contamination_flags":[]}'
    interr='{"stage":"candidate-timeout","detail":"the candidate run exceeded its wall-clock bound"}'
  fi
  case "$jout" in
    none) judgeobj='null' ;;
    JUDGED) judgeobj="$(jq -cn --argjson q "$qs" '{outcome:"JUDGED", scored:true, quality_score:$q, dimensions:{}, rationale:"r", concerns:[], judge_provider:"anthropic", judge_model:"claude-opus-4-8", tokens:null, duration_ms:10, disclosed:false, prompt_sha256:"bb", guard:{enforced:true}, evaluated_at:"2026-08-20T00:00:00Z"}')" ;;
    *) judgeobj="$(jq -cn --arg o "$jout" --arg n "$jnotice" '{outcome:$o, scored:false, quality_score:null, dimensions:null, rationale:null, concerns:[], judge_provider:"anthropic", judge_model:"claude-opus-4-8", degradation_notice:$n, tokens:null, duration_ms:0, disclosed:false, prompt_sha256:"bb", guard:{enforced:true}, evaluated_at:"2026-08-20T00:00:00Z"}')" ;;
  esac
  jq -cn --argjson pr "$pr" --arg model "$model" --argjson tokens "$tokens" \
    --argjson score "$scoreobj" --argjson judge "$judgeobj" \
    --argjson interr "$interr" --arg outcome "$outcome" \
    --argjson dur "$((60000 + inp))" --arg day "$day" '
    {pr:$pr, issue:($pr - 100), merge_commit:"mc0001", base:"base0001", head:"head0001",
     title:"item \($pr)", scope:null, acceptance:["does a thing"], notes:"",
     status:"eligible", reject_reason:"", flags:[],
     buckets:{N:["a.sh"], T:["tests/t.sh"], X:[], R:[]},
     template_sha:"tpl0000", file_count:2,
     worktree:{path:"/tmp/wt", branch:"replay/\($pr)", prepared_at:($day + "T10:00:00Z")},
     candidate:{provider:"anthropic", model:$model, diff_ref:"cafe",
                tokens:$tokens, duration_ms:$dur, outcome:$outcome,
                integration_error:$interr, disclosed:false, prompt_sha256:"aa"},
     score:$score}
    | if $judge == null then . else . + {judge:$judge} end'
}

# fill <file> <model> <n> <base-input> <jitter> — n scored+passing+judged
# records with a deterministic, VARYING cost profile (a constant profile has
# zero variance, which is a genuinely different statistical case and is
# covered separately in section E).
fill() {
  local file="$1" model="$2" n="$3" base="$4" jit="$5" i=0 inp day
  : >"$file"
  while [ "$i" -lt "$n" ]; do
    inp=$(( base + i * 7 + (i % 7) * jit ))
    day="$(printf '2026-08-%02d' $(( (i % 20) + 1 )))"
    record $(( 1000 + i )) "$model" "$inp" $(( 100 + (i % 5) * 3 )) pass true \
      JUDGED $(( 70 + (i % 11) )) "$day" scored >>"$file"
    i=$(( i + 1 ))
  done
}

# lake <repo> <seat>... — write an attribution raw-lake month file naming the
# given seats.
lake() {
  local repo="$1"; shift
  local f="$repo/meta/data/raw/model-usage-2026-08.jsonl"
  : >"$f"
  local s
  for s in "$@"; do
    jq -cn --arg s "$s" '{schema_version:"1", ts:"2026-08-05T00:00:00Z", session_id:"s1",
      repo:"o/r", seat:$s, model:"claude-haiku-4-5", provider:"anthropic",
      usage_source:"cli-envelope", tokens:{input:1,output:1,cache_read:0,cache_creation:0},
      weighted_units:6, duration_ms:10, outcome_ref:"issue:1"}' >>"$f"
  done
}

# run <repo> [producer] — run the producer with cwd = <repo>. Stdout lands in
# $RUN_OUT, exit status in $RUN_RC. Bounded, so a hang fails rather than
# stalls the suite.
RUN_OUT=""; RUN_RC=0
run() {
  local repo="$1" prod="${2:-$PRODUCER}"
  RUN_OUT="$WORK/run.out"
  ( cd "$repo" && run_with_timeout 120 bash "$prod" ) >"$RUN_OUT" 2>"$WORK/run.err"
  RUN_RC=$?
}

# mkmirror <dest> — a mutable copy of the producer plus the sibling layout its
# own $0-relative resolution needs.
mkmirror() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest/workflows/scripts/report-producers" "$dest/workflows/scripts/config"
  cp "$PRODUCER" "$dest/workflows/scripts/report-producers/model-comparison"
  chmod +x "$dest/workflows/scripts/report-producers/model-comparison"
  cp -R "$MC_DIR" "$dest/workflows/scripts/model-comparison"
  cp "$SCRIPTS_DIR/config/default-pricing.json" "$dest/workflows/scripts/config/default-pricing.json"
  ln -s "$SCRIPTS_DIR/build" "$dest/workflows/scripts/build"
  ln -s "$SCRIPTS_DIR/lib" "$dest/workflows/scripts/lib"
  printf '%s\n' "$dest/workflows/scripts/report-producers/model-comparison"
}

# jqf <file> <filter> — read one raw value out of a JSON file.
jqf() { jq -r "$2" "$1" 2>/dev/null; }

# ═══════════════════════════════════════════════════════════════════════════
# THE FLATTERING RUN — the baseline every honesty assertion is checked against
# ═══════════════════════════════════════════════════════════════════════════
# Deliberately the run that looks GOOD: every record scored, every gate green,
# every row judged, a clean statistically-significant win for the candidate.
# If a disclosure can be dropped anywhere, this is the run where nobody would
# notice.
FLAT="$WORK/flattering"
mkrepo "$FLAT"
fill "$FLAT/.temperloop/model-comparison/baseline.jsonl"  claude-opus-4-8  24 5000 0
fill "$FLAT/.temperloop/model-comparison/candidate.jsonl" claude-sonnet-5  24 4200 90
lake "$FLAT" pipeline-drive-safe retro-judge

run "$FLAT"
FLAT_OUT="$WORK/flattering.json"
cp "$RUN_OUT" "$FLAT_OUT"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION A — the .temperloop/report.d/ drop-in contract
# ═══════════════════════════════════════════════════════════════════════════

count
[ "$RUN_RC" -eq 0 ] || fail "A1: the producer must exit 0 on a good run, got $RUN_RC"
ok "A1 exit 0 on a good run"

count
jq -e 'type == "object"' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "A2: stdout must parse as a single JSON object"
[ "$(jq -s 'length' "$FLAT_OUT" 2>/dev/null)" = "1" ] \
  || fail "A2: stdout must be EXACTLY ONE JSON document, not several"
ok "A2 stdout is exactly one JSON object"

count
# The kernel reserves `notice` globally and scopes tokens_spent/by_model to the
# producer literally named `tokens` (report.contract.md § Reserved top-level
# keys). This producer must carry the first and never the second pair, or it
# could hijack the headline spend figure ADR 0020 owns.
jq -e '(.notice | type) == "string"' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "A3: the report must carry a string notice field — its only human channel"
[ "$(jqf "$FLAT_OUT" '.notice | contains("\n")')" = "false" ] \
  || fail "A3: the notice field must be a SINGLE-LINE string (report.contract.md leaves an embedded newline undefined)"
jq -e 'has("tokens_spent") or has("by_model") | not' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "A3: this producer must NOT emit tokens_spent/by_model — those are scoped to the producer named 'tokens' and drive the headline spend figure"
ok "A3 uses the reserved single-line notice channel and never the tokens-scoped headline keys"

count
# Additive by construction: the tokens producer's own slot format is untouched
# because this producer writes a DIFFERENT file under a DIFFERENT name, and the
# kernel ships no .temperloop/report.d/ shim for it (ADR 0027, inert by design).
[ -f "$SCRIPTS_DIR/report-producers/tokens" ] \
  || fail "A4: the tokens producer must still exist"
[ ! -e "$SCRIPTS_DIR/../../.temperloop/report.d/model-comparison" ] \
  || fail "A4: the kernel must ship NO .temperloop/report.d/model-comparison shim — arming it in every install is exactly the standing cost ADR 0027 forbids"
ok "A4 additive only: the tokens producer is untouched and this producer ships un-armed"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B — the metrics the acceptance names
# ═══════════════════════════════════════════════════════════════════════════

count
for k in cost judge_quality gate_outcomes intervention_rework duration quality compatibility; do
  jq -e --arg k "$k" '.arms.baseline | has($k)' "$FLAT_OUT" >/dev/null 2>&1 \
    || fail "B1: the baseline arm is missing the '$k' block"
  jq -e --arg k "$k" '.arms.candidate | has($k)' "$FLAT_OUT" >/dev/null 2>&1 \
    || fail "B1: the candidate arm is missing the '$k' block"
done
ok "B1 both arms carry cost, judge quality, gate outcomes, intervention/rework, duration, and score.sh's quality/compatibility split"

count
[ "$(jqf "$FLAT_OUT" '.arms.candidate.cost.cost_per_merged_outcome | type')" = "number" ] \
  || fail "B2: a fully-scored arm must report a whole-job cost per merged outcome"
[ "$(jqf "$FLAT_OUT" '.arms.candidate.cost.merged_outcomes_n')" = "24" ] \
  || fail "B2: merged_outcomes_n should count the 24 passing records"
ok "B2 whole-job cost per merged outcome is reported on a fully-scored arm"

count
# The quality/compatibility split is score.sh's, embedded verbatim — asserted
# by comparing against an independent score.sh aggregate call, so a future
# re-derivation here would diverge and fail.
indep_q="$(bash "$MC_DIR/score.sh" aggregate --records-file "$FLAT/.temperloop/model-comparison/candidate.jsonl" 2>/dev/null | jq -c '.quality')"
mine_q="$(jq -c '.arms.candidate.quality' "$FLAT_OUT")"
[ -n "$indep_q" ] && [ "$indep_q" = "$mine_q" ] \
  || fail "B3: the arm's quality block must be score.sh aggregate's own, byte-identical (independent: $indep_q; reported: $mine_q)"
ok "B3 the scored-only quality split is score.sh's own output, not re-derived here"

count
# The weights are CONSUMED from the SPEND_WEIGHT_* settings, not hardcoded.
# Non-default weights are exported and the expected total is hand-computed:
# one record with input=5000, output=100, cache_read=2000, cache_creation=100
# under weights 2 / 0.5 / 2 / 10 is 5000*2 + 2000*0.5 + 100*2 + 100*10
# = 10000 + 1000 + 200 + 1000 = 12200.
WREPO="$WORK/weights"
mkrepo "$WREPO"
record 1001 claude-sonnet-5 5000 100 pass true JUDGED 80 2026-08-01 scored \
  >"$WREPO/.temperloop/model-comparison/candidate.jsonl"
record 1001 claude-opus-4-8 5000 100 pass true JUDGED 80 2026-08-01 scored \
  >"$WREPO/.temperloop/model-comparison/baseline.jsonl"
(
  export SPEND_WEIGHT_INPUT=2 SPEND_WEIGHT_CACHE_READ=0.5 \
         SPEND_WEIGHT_CACHE_CREATE=2 SPEND_WEIGHT_OUTPUT=10
  run "$WREPO"
  cp "$RUN_OUT" "$WORK/weights.json"
)
[ "$(jqf "$WORK/weights.json" '.arms.candidate.cost.total_weighted_units')" = "12200" ] \
  || fail "B4: expected the hand-computed 12200 cost-weighted units under the exported non-default weights, got $(jqf "$WORK/weights.json" '.arms.candidate.cost.total_weighted_units')"
[ "$(jqf "$WORK/weights.json" '.cost_basis.weights.output')" = "10" ] \
  || fail "B4: the report must state the weights it actually used"
ok "B4 cost weighting consumes the configured SPEND_WEIGHT_* values (hand-computed 12200 under non-default weights)"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION C — THE HONESTY DISCLOSURES, ON A FLATTERING RUN
# ═══════════════════════════════════════════════════════════════════════════
# assert_disclosures <json-file> — the four disclosures the acceptance names.
# Returns non-zero (quietly) when any is absent, so it can be pointed at a
# deliberately-mutilated report to prove it actually notices.
assert_disclosures() {
  local f="$1"
  # 1. emit-coverage percentage, with its feasible-seat denominator.
  jq -e '(.emit_coverage.coverage_pct | type) == "number"' "$f" >/dev/null 2>&1 || return 1
  jq -e '(.emit_coverage.feasible_seats | type) == "number"' "$f" >/dev/null 2>&1 || return 1
  jq -e '(.emit_coverage.excluded_seats | type) == "array" and (.emit_coverage.excluded_seats | length) > 0' "$f" >/dev/null 2>&1 || return 1
  # 2. corpus window.
  jq -e '(.corpus_window | type) == "object"' "$f" >/dev/null 2>&1 || return 1
  jq -e '(.corpus_window.replayed_from_utc | type) == "string"' "$f" >/dev/null 2>&1 || return 1
  jq -e '(.corpus_window.records_n | type) == "number"' "$f" >/dev/null 2>&1 || return 1
  # 3. gate versions.
  jq -e '(.gate_versions | type) == "object"' "$f" >/dev/null 2>&1 || return 1
  jq -e '(.gate_versions.distinct_n | type) == "number"' "$f" >/dev/null 2>&1 || return 1
  jq -e '(.gate_versions.pairs | type) == "array"' "$f" >/dev/null 2>&1 || return 1
  # 4. cost basis — named as one of the three units, not merely present.
  jq -e '(.cost_basis.unit | type) == "string"' "$f" >/dev/null 2>&1 || return 1
  jq -e '.cost_basis.statement | test("METERED DOLLARS")' "$f" >/dev/null 2>&1 || return 1
  jq -e '.cost_basis.statement | test("SUBSCRIPTION-USAGE SHARE")' "$f" >/dev/null 2>&1 || return 1
  jq -e '.cost_basis.statement | test("TOKEN COUNTS")' "$f" >/dev/null 2>&1 || return 1
  return 0
}

count
assert_disclosures "$FLAT_OUT" \
  || fail "C1: the four honesty disclosures must all be present on a FLATTERING run"
ok "C1 coverage %, corpus window, gate versions and cost basis all appear on a flattering run"

count
# MUTATION PROOF — delete each disclosure in turn from the passing report and
# require the assertion to notice. Renaming would prove less; these are real
# deletions of the published key.
for key in emit_coverage corpus_window gate_versions cost_basis; do
  jq --arg k "$key" 'del(.[$k])' "$FLAT_OUT" >"$WORK/mutilated.json"
  if assert_disclosures "$WORK/mutilated.json"; then
    fail "C2: deleting .$key from the report left the disclosure assertion GREEN — the assertion is not load-bearing"
  fi
done
ok "C2 mutation proof: deleting each of the four disclosures in turn turns the assertion RED"

count
# The cost basis must name WHICH unit, and must not claim to be the two units
# it is not. A report that showed a dollar figure without saying it is a list-
# price estimate would let a reader compare it to an invoice.
[ "$(jqf "$FLAT_OUT" '.cost_basis.unit')" = "token-counts" ] \
  || fail "C3: the cost basis must name token-counts as the unit in play"
jq -e '.cost_basis.list_price_overlay.note | test("never metered dollars")' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "C3: the optional dollar overlay must disclaim being metered dollars"
ok "C3 the cost basis names its unit and disclaims the two units it is not"

count
# The coverage figure must be the STATS.SH one against the CONFIGURED
# denominator, not a locally-divided pair of numbers. Two observed seats
# against an exported NON-default denominator of 2 must read 100%; the same
# two seats against the shipped denominator must not.
COVREPO="$WORK/coverage"
mkrepo "$COVREPO"
fill "$COVREPO/.temperloop/model-comparison/baseline.jsonl"  claude-opus-4-8 4 5000 0
fill "$COVREPO/.temperloop/model-comparison/candidate.jsonl" claude-sonnet-5 4 4200 90
lake "$COVREPO" pipeline-drive-safe retro-judge
( export MODEL_COMPARISON_EMIT_FEASIBLE_SEATS=2; run "$COVREPO"; cp "$RUN_OUT" "$WORK/cov2.json" )
run "$COVREPO"; cp "$RUN_OUT" "$WORK/covdefault.json"
[ "$(jqf "$WORK/cov2.json" '.emit_coverage.coverage_pct')" = "100" ] \
  || fail "C4: two observed seats against an exported denominator of 2 must read 100%, got $(jqf "$WORK/cov2.json" '.emit_coverage.coverage_pct')"
[ "$(jqf "$WORK/cov2.json" '.emit_coverage.feasible_seats')" = "2" ] \
  || fail "C4: the report must state the denominator it actually used"
[ "$(jqf "$WORK/covdefault.json" '.emit_coverage.coverage_pct')" != "100" ] \
  || fail "C4: the same two seats against the shipped denominator must NOT read 100% — the figure is not tracking the configured denominator"
ok "C4 emit coverage is stats.sh's figure against the configured emit-feasible denominator, not a local division"

count
# A seat outside the emit-FEASIBLE roster must not inflate the numerator. The
# module's own replay seats emit too, and counting them would push observed
# past feasible and turn the percentage into nonsense.
lake "$COVREPO" pipeline-drive-safe retro-judge replay-candidate replay-judge pipeline-drive-merge
run "$COVREPO"
[ "$(jqf "$RUN_OUT" '.emit_coverage.observed_seats')" = "3" ] \
  || fail "C5: five emitted seats, three of them emit-feasible, must count as 3 observed — got $(jqf "$RUN_OUT" '.emit_coverage.observed_seats')"
[ "$(jqf "$RUN_OUT" '.emit_coverage.coverage_pct')" = "100" ] \
  || fail "C5: all three emit-feasible seats observed should read 100%"
ok "C5 only emit-feasible seats count toward the coverage numerator"

count
# The exclusion list must be stated alongside the figure (the L0 spike's own
# directive for this item), naming the un-emittable seats rather than dropping
# them silently — otherwise a 100% reading implies a claim the system does not
# make.
for seat in A1 A2 B1 B2 C1; do
  jq -e --arg s "$seat" '[.emit_coverage.excluded_seats[].seats[]] | index($s) != null' "$FLAT_OUT" >/dev/null 2>&1 \
    || fail "C6: the excluded-seat list must name $seat"
done
jq -e '.emit_coverage.below_100_does_not_mean | test("spend visibility")' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "C6: the report must say what a sub-100% figure does NOT mean"
ok "C6 the named exclusion list and the does-not-mean caveat ride alongside the coverage figure"

count
# MUTATION PROOF for the end-to-end path (not only the assertion): rename the
# published emit_coverage key in a mirrored producer and require C1 to go red.
MIRROR1="$(mkmirror "$WORK/m1")"
perl -pi -e 's/^(\s+)emit_coverage: \{$/$1emit_coverage_GONE: {/' "$MIRROR1"
run "$FLAT" "$MIRROR1"
if assert_disclosures "$RUN_OUT"; then
  fail "C7: a producer that no longer publishes emit_coverage still passed the disclosure assertion"
fi
ok "C7 mutation proof: a producer that stops publishing emit_coverage turns C1 RED"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D — THE INCONCLUSIVE FLOOR, AND THE WINNER GATE
# ═══════════════════════════════════════════════════════════════════════════
# The floor is exported to a NON-default value throughout, so these tests
# prove the producer honours the CONFIGURED floor rather than agreeing with a
# shipped constant by accident.
FLOOR=12
SMALL="$WORK/small"
mkrepo "$SMALL"
fill "$SMALL/.temperloop/model-comparison/baseline.jsonl"  claude-opus-4-8  3 5000 0
fill "$SMALL/.temperloop/model-comparison/candidate.jsonl" claude-sonnet-5  3 4200 90
lake "$SMALL" pipeline-drive-safe

count
( export MODEL_COMPARISON_MIN_SAMPLE_N=$FLOOR; run "$SMALL"; cp "$RUN_OUT" "$WORK/small.json" )
[ "$(jqf "$WORK/small.json" '.comparison.verdict')" = "inconclusive" ] \
  || fail "D1: 3 paired outcomes under a floor of $FLOOR must report inconclusive, got $(jqf "$WORK/small.json" '.comparison.verdict')"
[ "$(jqf "$WORK/small.json" '.comparison | has("winner")')" = "false" ] \
  || fail "D1: an inconclusive run must not carry a winner key at all"
[ "$(jqf "$WORK/small.json" '.comparison.below_min_sample')" = "true" ] \
  || fail "D1: the run must say it is below the floor"
[ "$(jqf "$WORK/small.json" '.comparison.confidence_interval.lower')" = "null" ] \
  || fail "D1: below the floor the bootstrap bounds must be withheld"
ok "D1 below the configured floor the report says inconclusive, withholds the bounds, and names no winner"

count
# The MDE disclosure is required on EVERY run — most of all the under-powered
# one, where "at this N only deltas of at least X are detectable" is the whole
# point. It must be a real number here, not a shrug.
[ "$(jqf "$WORK/small.json" '.comparison.minimum_detectable_effect.mde | type')" = "number" ] \
  || fail "D2: a below-floor run must still disclose a minimum detectable effect"
jq -e '.comparison.minimum_detectable_effect.disclosure | test("at N=3")' "$WORK/small.json" >/dev/null 2>&1 \
  || fail "D2: the MDE disclosure must name the N it was computed at"
ok "D2 the minimum-detectable-effect disclosure is present even below the floor"

count
# MUTATION PROOF 1 — REMOVE THE FLOOR from the producer's own verdict call
# (the realistic bug: reaching for the unfloored form, exactly the shape the
# dispersion probe uses). The same 3 records must then yield a winner, which
# is what makes D1 a refusal the floor is causing rather than a coincidence
# of this fixture. The 3 deltas are all negative, so an unfloored bootstrap
# lands wholly below zero and reads as a confident candidate win.
MIRROR2="$(mkmirror "$WORK/m2")"
perl -pi -e 's/^(\s*)vj="\$\(bash "\$STATS_SH" verdict --deltas "\$deltas" 2>\/dev\/null\)"$/$1vj="\$(bash "\$STATS_SH" verdict --deltas "\$deltas" --min-sample 1 2>\/dev\/null)"/' "$MIRROR2"
grep -F 'vj="$(bash "$STATS_SH" verdict --deltas "$deltas" --min-sample 1' "$MIRROR2" >/dev/null \
  || fail "D3: the floor-removal mutation did not apply — the proof would be vacuous"
( export MODEL_COMPARISON_MIN_SAMPLE_N=$FLOOR; run "$SMALL" "$MIRROR2"; cp "$RUN_OUT" "$WORK/small-mut.json" )
[ "$(jqf "$WORK/small-mut.json" '.comparison | has("winner")')" = "true" ] \
  || fail "D3: with the floor removed from the producer's verdict call a winner should have appeared on 3 records — the floor was not what was suppressing it"
[ "$(jqf "$WORK/small-mut.json" '.comparison.winner')" = "candidate" ] \
  || fail "D3: the unfloored mutant should have named the candidate on these 3 all-negative deltas"
ok "D3 mutation proof: removing the floor from the producer's verdict call makes a winner appear on 3 records"

count
# MUTATION PROOF 2 — leave the producer untouched and remove the floor inside
# stats.py. A winner must appear, proving the producer genuinely rides the
# library's floor rather than a private copy of it.
MIRROR3="$(mkmirror "$WORK/m3")"
perl -pi -e 's/^(\s+)if n < args\.min_sample:$/$1if False:/' "$WORK/m3/workflows/scripts/model-comparison/stats.py"
grep -F 'if False:' "$WORK/m3/workflows/scripts/model-comparison/stats.py" >/dev/null \
  || fail "D4: the stats.py floor mutation did not apply — the proof would be vacuous"
( export MODEL_COMPARISON_MIN_SAMPLE_N=$FLOOR; run "$SMALL" "$MIRROR3"; cp "$RUN_OUT" "$WORK/small-mut2.json" )
[ "$(jqf "$WORK/small-mut2.json" '.comparison | has("winner")')" = "true" ] \
  || fail "D4: with stats.py's floor removed the UNMODIFIED producer should have named a winner on 3 records — it is not riding the library floor"
ok "D4 mutation proof: removing stats.py's own floor makes the unmodified producer name a winner on 3 records"

count
# Above the floor, a real difference IS named — otherwise D1 could be passing
# because the producer never names a winner at all.
[ "$(jqf "$FLAT_OUT" '.comparison.verdict')" = "candidate_better" ] \
  || fail "D5: the flattering run should reach a candidate_better verdict, got $(jqf "$FLAT_OUT" '.comparison.verdict')"
[ "$(jqf "$FLAT_OUT" '.comparison.winner')" = "candidate" ] \
  || fail "D5: a supported verdict must name its winner"
ok "D5 above the floor a supported verdict does name a winner — D1 is a refusal, not an inability"

count
# A no-significant-difference verdict above the floor also names no winner:
# "not distinguishable" is not "tied and therefore either".
SAME="$WORK/same"
mkrepo "$SAME"
fill "$SAME/.temperloop/model-comparison/baseline.jsonl"  claude-opus-4-8  24 5000 90
fill "$SAME/.temperloop/model-comparison/candidate.jsonl" claude-sonnet-5  24 5000 90
lake "$SAME" pipeline-drive-safe
run "$SAME"
[ "$(jqf "$RUN_OUT" '.comparison.below_min_sample')" = "false" ] \
  || fail "D6: this fixture is meant to sit above the floor"
[ "$(jqf "$RUN_OUT" '.comparison | has("winner")')" = "false" ] \
  || fail "D6: a run with no significant difference must name no winner"
ok "D6 above the floor with no significant difference, still no winner"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E — NO FABRICATED FIGURE ON A DEGRADED RUN
# ═══════════════════════════════════════════════════════════════════════════
# assert_no_fabrication <stdout-file> <rc> — the degraded-run contract:
# exit 0, one `skipped -- ` line, and nowhere in the output a winner or a cost
# figure. Returns non-zero quietly so it can be proved load-bearing.
assert_no_fabrication() {
  local f="$1" rc="$2"
  [ "$rc" -eq 0 ] || return 1
  [ "$(grep -c . "$f")" = "1" ] || return 1
  grep -q '^skipped -- model-comparison: ' "$f" || return 1
  grep -q 'winner' "$f" && return 1
  grep -qE 'cost_per_merged_outcome|weighted_units|estimate_usd' "$f" && return 1
  return 0
}

count
STARVED="$WORK/starved"
mkrepo "$STARVED"
run "$STARVED"
assert_no_fabrication "$RUN_OUT" "$RUN_RC" \
  || fail "E1: a starved run must exit 0 with one 'skipped -- ' line and no winner and no cost figure; got rc=$RUN_RC out=$(cat "$RUN_OUT")"
ok "E1 a fully starved run: exit 0, one skipped line, no winner key, no cost figure"

count
# One arm only is still not a comparison.
fill "$STARVED/.temperloop/model-comparison/baseline.jsonl" claude-opus-4-8 24 5000 0
run "$STARVED"
assert_no_fabrication "$RUN_OUT" "$RUN_RC" \
  || fail "E2: a run with only a baseline arm must degrade, not report half a comparison"
grep -q 'candidate arm' "$RUN_OUT" \
  || fail "E2: the skipped line must name what was missing"
ok "E2 one arm present is a named degradation, never half a comparison"

count
# Malformed records degrade rather than being partially rolled up.
printf 'not json at all\n' >"$STARVED/.temperloop/model-comparison/candidate.jsonl"
run "$STARVED"
assert_no_fabrication "$RUN_OUT" "$RUN_RC" \
  || fail "E3: an unparseable arm must degrade rather than report a partial roll-up"
ok "E3 an unparseable arm degrades rather than reporting a partial roll-up"

count
# MUTATION PROOF — rewrite the degradation path to emit a fabricated report
# and require the assertion to catch it. Without this, E1-E3 could be passing
# because the assertion is toothless.
MIRROR4="$(mkmirror "$WORK/m4")"
# The replacement rides an env var so neither the shell nor perl reprocesses
# its escapes on the way in.
FAB_SKIP='skip() { echo "{\"winner\":\"candidate\",\"cost_per_merged_outcome\":9999}"; exit 0; }'
export FAB_SKIP
perl -pi -e 's/^skip\(\) \{ printf.*$/$ENV{FAB_SKIP}/' "$MIRROR4"
unset FAB_SKIP
grep -F 'cost_per_merged_outcome\":9999' "$MIRROR4" >/dev/null \
  || fail "E4: the fabrication mutation did not apply — the proof would be vacuous"
STARVED2="$WORK/starved2"
mkrepo "$STARVED2"
run "$STARVED2" "$MIRROR4"
if assert_no_fabrication "$RUN_OUT" "$RUN_RC"; then
  fail "E4: a degradation path that emitted a fabricated winner+cost object still passed the no-fabrication assertion"
fi
ok "E4 mutation proof: a degradation path that fabricates a winner and a cost figure turns E1 RED"

count
# The subtler fabrication: records present, but no token counts. A whole-job
# cost figure over a partial cost corpus is a figure derived from missing
# data, so it must be withheld WITH A STATED REASON — and still no winner,
# because a delta needs both sides.
PARTIAL="$WORK/partial"
mkrepo "$PARTIAL"
{
  record 1001 claude-opus-4-8 5000 100 pass true JUDGED 80 2026-08-01 scored
  record 1002 claude-opus-4-8 5100 100 pass true JUDGED 80 2026-08-02 scored
} >"$PARTIAL/.temperloop/model-comparison/baseline.jsonl"
{
  record 1001 claude-sonnet-5 4000 100 pass true JUDGED 80 2026-08-01 scored | jq -c '.candidate.tokens = null'
  record 1002 claude-sonnet-5 4100 100 pass true JUDGED 80 2026-08-02 scored
} >"$PARTIAL/.temperloop/model-comparison/candidate.jsonl"
lake "$PARTIAL" pipeline-drive-safe
run "$PARTIAL"
[ "$RUN_RC" -eq 0 ] || fail "E5: a partial-token run must still exit 0"
[ "$(jqf "$RUN_OUT" '.arms.candidate.cost.cost_per_merged_outcome')" = "null" ] \
  || fail "E5: a whole-job cost figure must be withheld when some scored records carry no tokens"
[ "$(jqf "$RUN_OUT" '.arms.candidate.cost.cost_per_merged_outcome_unavailable_reason | type')" = "string" ] \
  || fail "E5: withholding the figure must come with a stated reason, never a silent null"
[ "$(jqf "$RUN_OUT" '.arms.candidate.cost.uncosted_n')" = "1" ] \
  || fail "E5: the record with no tokens must be counted as uncosted, never as a zero"
[ "$(jqf "$RUN_OUT" '.comparison.paired_outcomes_n')" = "1" ] \
  || fail "E5: only the outcome with tokens on BOTH sides may contribute a delta"
[ "$(jqf "$RUN_OUT" '.comparison | has("winner")')" = "false" ] \
  || fail "E5: one pair is below any floor — no winner"
ok "E5 a token-starved record is counted as uncosted, the whole-job figure is withheld with a stated reason, and no winner is named"

count
# An integration-error record must never be read as a model quality failure —
# it lands in compatibility and in the intervention proxy, and nowhere in the
# quality block.
IERR="$WORK/ierr"
mkrepo "$IERR"
fill "$IERR/.temperloop/model-comparison/baseline.jsonl" claude-opus-4-8 3 5000 0
{
  record 1000 claude-sonnet-5 4000 100 pass true JUDGED 80 2026-08-01 scored
  record 1001 claude-sonnet-5 0 0 x false none 0 2026-08-02 integration-error
  record 1002 claude-sonnet-5 4100 100 fail false JUDGED 60 2026-08-03 scored
} >"$IERR/.temperloop/model-comparison/candidate.jsonl"
lake "$IERR" pipeline-drive-safe
run "$IERR"
[ "$(jqf "$RUN_OUT" '.arms.candidate.quality.scored_n')" = "2" ] \
  || fail "E6: the integration error must be excluded from the quality denominator"
[ "$(jqf "$RUN_OUT" '.arms.candidate.compatibility.integration_error_n')" = "1" ] \
  || fail "E6: the integration error must be reported as a compatibility fact"
[ "$(jqf "$RUN_OUT" '.arms.candidate.intervention_rework.intervention_n')" = "1" ] \
  || fail "E6: the integration error must count as an intervention"
[ "$(jqf "$RUN_OUT" '.arms.candidate.intervention_rework.rework_n')" = "1" ] \
  || fail "E6: the gate-failing record must count as rework"
ok "E6 integration errors sit in compatibility and intervention, never in the quality denominator; a failed gate counts as rework"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION F — STATISTICS CONSUMED, NOT RECOMPUTED
# ═══════════════════════════════════════════════════════════════════════════

count
# Byte-identical to an independent stats.sh call over the producer's OWN
# published delta array. The array is published precisely so this check needs
# no re-derivation of production logic.
DELTAS="$(jq -c '.comparison.deltas' "$FLAT_OUT")"
[ "$(jq -r 'length' <<<"$DELTAS")" = "24" ] || fail "F1: expected 24 published deltas"
indep_ci="$(bash "$STATS" bootstrap-ci --deltas "$DELTAS" | jq -c '{lower,upper,mean,iterations,seed,ci_width_pct}')"
mine_ci="$(jq -c '.comparison.confidence_interval | {lower,upper,mean,iterations,seed,ci_width_pct}' "$FLAT_OUT")"
[ "$indep_ci" = "$mine_ci" ] \
  || fail "F1: the published confidence interval diverges from an independent stats.sh call (independent: $indep_ci; reported: $mine_ci)"
ok "F1 the published confidence interval is byte-identical to an independent stats.sh bootstrap-ci call"

count
indep_sd="$(bash "$STATS" verdict --deltas "$DELTAS" --min-sample 1 | jq -r '.stddev')"
indep_mde="$(bash "$STATS" mde --n 24 --stddev "$indep_sd" | jq -c '{mde,margin_of_error,power,ci_width_pct}')"
mine_mde="$(jq -c '.comparison.minimum_detectable_effect | {mde,margin_of_error,power,ci_width_pct}' "$FLAT_OUT")"
[ "$indep_mde" = "$mine_mde" ] \
  || fail "F2: the published MDE diverges from an independent stats.sh mde call (independent: $indep_mde; reported: $mine_mde)"
ok "F2 the published MDE and margin of error are byte-identical to an independent stats.sh mde call"

count
# Above the floor, stats.sh verdict computes its own mde too. The producer's
# published figure must equal it — a second, independent way of catching a
# locally-recomputed substitute.
verdict_mde="$(bash "$STATS" verdict --deltas "$DELTAS" | jq -r '.mde')"
[ "$verdict_mde" = "$(jqf "$FLAT_OUT" '.comparison.minimum_detectable_effect.mde')" ] \
  || fail "F3: the published MDE disagrees with stats.sh verdict's own MDE over the same deltas"
ok "F3 the published MDE also matches stats.sh verdict's own MDE over the same deltas"

count
# MUTATION PROOF — nudge the published lower bound by 5% in a mirrored
# producer. F1 must go red.
MIRROR5="$(mkmirror "$WORK/m5")"
perl -pi -e 's/lower: \$ci\.lower, upper: \$ci\.upper,/lower: (\$ci.lower * 1.05), upper: \$ci.upper,/' "$MIRROR5"
grep -F '$ci.lower * 1.05' "$MIRROR5" >/dev/null \
  || fail "F4: the CI mutation did not apply — the proof would be vacuous"
run "$FLAT" "$MIRROR5"
mut_ci="$(jq -c '.comparison.confidence_interval | {lower,upper,mean,iterations,seed,ci_width_pct}' "$RUN_OUT")"
[ "$mut_ci" != "$indep_ci" ] \
  || fail "F4: a producer publishing a 5%-scaled lower bound still matched the independent stats.sh call — F1 is not load-bearing"
ok "F4 mutation proof: a 5% nudge to the published lower bound turns F1 RED"

count
# The dispersion probe must not leak: its own (floor-1) verdict and bounds are
# discarded, so a below-floor run cannot inherit a conclusive-looking result
# from it.
[ "$(jqf "$WORK/small.json" '.comparison.confidence_interval.below_min_sample')" = "true" ] \
  || fail "F5: the published interval must be the floor-respecting one, not the dispersion probe's"
[ "$(jqf "$WORK/small.json" '.comparison.confidence_interval.upper')" = "null" ] \
  || fail "F5: the dispersion probe's bounds must never reach stdout"
ok "F5 the dispersion probe contributes only a standard deviation — never its verdict or its bounds"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION G — A MID-BATCH JUDGE OUTAGE CARRIES ITS NAMED NOTICE
# ═══════════════════════════════════════════════════════════════════════════

count
JREPO="$WORK/judge"
mkrepo "$JREPO"
fill "$JREPO/.temperloop/model-comparison/baseline.jsonl" claude-opus-4-8 3 5000 0
NOTICE_TEXT="judge-transport-failed: the judge runner exited 137 mid-batch"
{
  record 1000 claude-sonnet-5 4000 100 pass true JUDGED 90 2026-08-01 scored
  record 1001 claude-sonnet-5 4100 100 pass true UNAVAILABLE 0 2026-08-02 scored "$NOTICE_TEXT"
  record 1002 claude-sonnet-5 4200 100 pass true JUDGED 70 2026-08-03 scored
} >"$JREPO/.temperloop/model-comparison/candidate.jsonl"
lake "$JREPO" pipeline-drive-safe
run "$JREPO"
[ "$(jqf "$RUN_OUT" '.arms.candidate.judge_quality.degraded_n')" = "1" ] \
  || fail "G1: the UNAVAILABLE row must be reported as degraded"
[ "$(jqf "$RUN_OUT" '.arms.candidate.judge_quality.degraded_rows[0].degradation_notice')" = "$NOTICE_TEXT" ] \
  || fail "G1: the row's own NAMED degradation notice must be carried verbatim"
[ "$(jqf "$RUN_OUT" '.arms.candidate.judge_quality.degraded_rows[0].outcome_ref')" = "pr:1001" ] \
  || fail "G1: the degraded row must name which outcome it was"
ok "G1 a mid-batch judge outage row carries its named degradation notice, tagged with its outcome"

count
# The outage row must be EXCLUDED from the mean, never folded in as a zero —
# a withheld judgment is not a judgment of zero. (90 + 70) / 2 = 80; folding a
# zero in would give 53.3.
[ "$(jqf "$RUN_OUT" '.arms.candidate.judge_quality.judged_n')" = "2" ] \
  || fail "G2: only the two JUDGED rows may enter the mean"
[ "$(jqf "$RUN_OUT" '.arms.candidate.judge_quality.mean_quality_score')" = "80" ] \
  || fail "G2: expected the mean of the two real judgments (80), got $(jqf "$RUN_OUT" '.arms.candidate.judge_quality.mean_quality_score') — a withheld judgment must not be scored as a zero"
ok "G2 an outage row is excluded from the judge-quality mean rather than counted as a zero"

count
# MUTATION PROOF — widen the JUDGED selector to swallow every judged-ish row.
# The mean must move and G2 must go red.
MIRROR6="$(mkmirror "$WORK/m6")"
perl -pi -e 's/\(\$recs \| map\(select\(\(\(\.judge \/\/ \{\}\)\.outcome \/\/ null\) == "JUDGED"\)\)\)/(\$recs | map(select((((.judge \/\/ {}).outcome \/\/ null) != null))))/' "$MIRROR6"
grep -F 'outcome // null) != null))))' "$MIRROR6" >/dev/null \
  || fail "G3: the judged-selector mutation did not apply — the proof would be vacuous"
run "$JREPO" "$MIRROR6"
[ "$(jqf "$RUN_OUT" '.arms.candidate.judge_quality.mean_quality_score')" != "80" ] \
  || fail "G3: swallowing the outage row into the mean left it unchanged — G2 is not load-bearing"
ok "G3 mutation proof: folding the outage row into the mean moves it, so G2 is load-bearing"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION H — THE PRICE TABLE: DATED LABEL, OR TOKEN COUNTS ONLY, STATED
# ═══════════════════════════════════════════════════════════════════════════

count
# The kernel default table drives a DATED staleness label carrying its own
# as_of, never a bare dollar figure.
[ "$(jqf "$FLAT_OUT" '.cost_basis.list_price_overlay.table_in_effect')" = "kernel-default" ] \
  || fail "H1: with no user table the kernel default should be in effect"
as_of="$(jq -r '.as_of' "$SCRIPTS_DIR/config/default-pricing.json")"
jq -e --arg d "$as_of" '.cost_basis.list_price_overlay.staleness | test("dated " + $d)' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "H1: the staleness label must carry the table's own as_of date"
jq -e '.cost_basis.list_price_overlay.staleness | test("STALE BY CONSTRUCTION")' "$FLAT_OUT" >/dev/null 2>&1 \
  || fail "H1: the staleness label must say the table is a committed snapshot, not a live rate"
[ "$(jqf "$FLAT_OUT" '.cost_basis.list_price_overlay.estimate_usd | type')" = "number" ] \
  || fail "H1: a resolving price table should produce a directional estimate"
ok "H1 the default price table renders a dated staleness label beside its directional estimate"

count
# A user table overrides outright and is NEVER merged per-key: a model the
# user table omits is excluded BY NAME, not back-filled from the kernel table.
UREPO="$WORK/userprice"
mkrepo "$UREPO"
fill "$UREPO/.temperloop/model-comparison/baseline.jsonl"  claude-opus-4-8 3 5000 0
fill "$UREPO/.temperloop/model-comparison/candidate.jsonl" claude-sonnet-5 3 4200 90
lake "$UREPO" pipeline-drive-safe
printf '{"claude-sonnet-5": 4.00}\n' >"$UREPO/.temperloop/pricing.json"
run "$UREPO"
[ "$(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.table_in_effect')" = "user" ] \
  || fail "H2: a present user table must win outright"
jq -e '[.cost_basis.list_price_overlay.excluded_models[]] | index("claude-opus-4-8") != null' "$RUN_OUT" >/dev/null 2>&1 \
  || fail "H2: a model absent from the user table must be excluded BY NAME, never back-filled from the kernel default"
jq -e '[.cost_basis.list_price_overlay.priced_models[]] | index("claude-sonnet-5") != null' "$RUN_OUT" >/dev/null 2>&1 \
  || fail "H2: the model the user priced must be priced"
ok "H2 a user price table overrides outright; an omitted model is excluded by name, never back-filled"

count
# A malformed user table degrades to token counts only, STATED.
printf '[1,2,3]\n' >"$UREPO/.temperloop/pricing.json"
run "$UREPO"
[ "$(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.table_in_effect')" = "user-malformed" ] \
  || fail "H3: a non-object user table must be named as malformed"
[ "$(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.estimate_usd')" = "null" ] \
  || fail "H3: a malformed table must produce no dollar figure"
jq -e '.cost_basis.list_price_overlay.staleness | test("TOKEN COUNTS ONLY")' "$RUN_OUT" >/dev/null 2>&1 \
  || fail "H3: the degradation must be STATED as token counts only, never silently omitted"
ok "H3 a malformed user price table degrades to a stated token-counts-only basis"

count
# An absent/broken kernel default table does the same rather than vanishing.
rm -f "$UREPO/.temperloop/pricing.json"
MIRROR7="$(mkmirror "$WORK/m7")"
printf '{"oops": true}\n' >"$WORK/m7/workflows/scripts/config/default-pricing.json"
run "$UREPO" "$MIRROR7"
[ "$(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.table_in_effect')" = "kernel-default-malformed" ] \
  || fail "H4: a broken kernel default table must be named, got $(jqf "$RUN_OUT" '.cost_basis.list_price_overlay.table_in_effect')"
jq -e '.cost_basis.list_price_overlay.staleness | test("TOKEN COUNTS ONLY")' "$RUN_OUT" >/dev/null 2>&1 \
  || fail "H4: a broken default table must state the token-counts-only degradation"
[ "$(jqf "$RUN_OUT" '.arms.candidate.cost.total_weighted_units | type')" = "number" ] \
  || fail "H4: the token counts themselves must survive a missing price table"
ok "H4 a broken kernel default price table degrades to a stated token-counts-only basis, token figures intact"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION I — CORPUS WINDOW AND GATE VERSIONS ARE READ, NOT ASSUMED
# ═══════════════════════════════════════════════════════════════════════════

count
[ "$(jqf "$FLAT_OUT" '.corpus_window.replayed_from_utc')" = "2026-08-01T10:00:00Z" ] \
  || fail "I1: the corpus window must report the earliest prepared_at it actually saw"
[ "$(jqf "$FLAT_OUT" '.corpus_window.replayed_to_utc')" = "2026-08-20T10:00:00Z" ] \
  || fail "I1: the corpus window must report the latest prepared_at it actually saw"
[ "$(jqf "$FLAT_OUT" '.corpus_window.pr_lowest')" = "1000" ] \
  || fail "I1: the corpus window must report the PR range replayed"
ok "I1 the corpus window is read off the records, not assumed"

count
# Human-facing local rendering must differ from the stored UTC instant under a
# non-UTC display zone, and must NOT differ under UTC — proving the conversion
# is real and honours the configured zone rather than echoing the UTC string.
utc_from="$(jqf "$FLAT_OUT" '.corpus_window.replayed_from_utc')"
la_local="$(jqf "$FLAT_OUT" '.corpus_window.replayed_from_local')"
[ "$la_local" = "2026-08-01 03:00:00" ] \
  || fail "I2: 2026-08-01T10:00:00Z should render as 03:00:00 in America/Los_Angeles (summer, -07:00), got '$la_local'"
( export DISPLAY_TZ=UTC; run "$FLAT"; cp "$RUN_OUT" "$WORK/utc.json" )
[ "$(jqf "$WORK/utc.json" '.corpus_window.replayed_from_local')" = "2026-08-01 10:00:00" ] \
  || fail "I2: under DISPLAY_TZ=UTC the local rendering must match the stored instant"
[ "$(jqf "$WORK/utc.json" '.corpus_window.replayed_from_utc')" = "$utc_from" ] \
  || fail "I2: the STORED timestamp must stay UTC regardless of the display zone"
[ "$(jqf "$WORK/utc.json" '.display_timezone')" = "UTC" ] \
  || fail "I2: the report must name the display zone it rendered in"
ok "I2 human-facing timestamps render in the configured display zone while stored ones stay UTC"

count
# Gate versions are the (script, base) pairs actually run — several bases mean
# several gate versions, stated rather than collapsed into one.
GREPO="$WORK/gates"
mkrepo "$GREPO"
fill "$GREPO/.temperloop/model-comparison/baseline.jsonl" claude-opus-4-8 2 5000 0
{
  record 1000 claude-sonnet-5 4000 100 pass true JUDGED 80 2026-08-01 scored
  record 1001 claude-sonnet-5 4100 100 pass true JUDGED 80 2026-08-02 scored | jq -c '.score.base = "base0002"'
} >"$GREPO/.temperloop/model-comparison/candidate.jsonl"
lake "$GREPO" pipeline-drive-safe
run "$GREPO"
[ "$(jqf "$RUN_OUT" '.gate_versions.distinct_n')" = "2" ] \
  || fail "I3: two distinct bases must be reported as two gate versions, got $(jqf "$RUN_OUT" '.gate_versions.distinct_n')"
ok "I3 a comparison spanning two bases reports two gate versions rather than collapsing them"

count
# A comparison with no gate that ever ran says so rather than reporting an
# empty list as if it meant "clean".
NGREPO="$WORK/nogate"
mkrepo "$NGREPO"
record 1000 claude-opus-4-8 5000 100 pass true JUDGED 80 2026-08-01 scored | jq -c '.score.gate_result = null' \
  >"$NGREPO/.temperloop/model-comparison/baseline.jsonl"
record 1000 claude-sonnet-5 4000 100 pass true JUDGED 80 2026-08-01 scored | jq -c '.score.gate_result = null' \
  >"$NGREPO/.temperloop/model-comparison/candidate.jsonl"
run "$NGREPO"
[ "$(jqf "$RUN_OUT" '.gate_versions.versions_unavailable_reason | type')" = "string" ] \
  || fail "I4: a comparison where no gate ran must state that, not present an empty list as a clean bill"
[ "$(jqf "$RUN_OUT" '.arms.candidate.gate_outcomes.no_gate_result_n')" = "1" ] \
  || fail "I4: a scored record with no gate result must be counted as such"
ok "I4 a comparison where no gate ever ran says so rather than showing an empty list"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION J — ARG HYGIENE AND PORTABILITY
# ═══════════════════════════════════════════════════════════════════════════

count
# The report.d contract invokes a producer with NO arguments. A trailing flag
# must degrade promptly — never spin. The bounded runner is what makes this a
# hang test and not just an output test.
( cd "$FLAT" && run_with_timeout 20 bash "$PRODUCER" --records-dir ) >"$WORK/argflag.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "J1: a trailing flag must degrade at exit 0 (and must not hang); got rc=$rc"
grep -q '^skipped -- model-comparison: ' "$WORK/argflag.out" \
  || fail "J1: an argument-bearing invocation must render the skipped line"
ok "J1 a trailing flag degrades promptly at exit 0 rather than spinning"

count
rc=0
( cd "$FLAT" && run_with_timeout 20 bash "$PRODUCER" --bogus value extra ) >"$WORK/argbogus.out" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "J2: unknown arguments must still exit 0 — a producer may never break temperloop report"
grep -q '^skipped -- model-comparison: ' "$WORK/argbogus.out" \
  || fail "J2: unknown arguments must render the skipped line"
ok "J2 unknown arguments degrade at exit 0"

count
# Stock macOS /bin/bash 3.2 is a first-class target, so the whole flattering
# run is re-executed under it and must produce byte-identical output apart
# from its own generation timestamp.
if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | grep 'version 3\.2' >/dev/null; then
  rc=0
  ( cd "$FLAT" && run_with_timeout 120 /bin/bash "$PRODUCER" ) >"$WORK/bash32.json" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "J3: the producer must run clean under /bin/bash 3.2"
  a="$(jq -cS 'del(.generated_at_utc, .generated_at_local)' "$FLAT_OUT")"
  b="$(jq -cS 'del(.generated_at_utc, .generated_at_local)' "$WORK/bash32.json")"
  [ "$a" = "$b" ] || fail "J3: the bash 3.2 run produced different output from the default-bash run"
  ok "J3 identical output under stock /bin/bash 3.2"
else
  ok "J3 skipped -- no /bin/bash 3.2 on this host (the suite still runs under whichever bash invoked it)"
fi

count
# The producer must not care about the ambient numeric locale — a
# comma-decimal locale is where a dollar figure silently loses its cents. The
# locale's presence is CHECKED rather than assumed, so a host without it
# reports a skip instead of a vacuous green.
COMMA_LOCALE=""
for cand in de_DE.UTF-8 fr_FR.UTF-8 de_DE.utf8 fr_FR.utf8; do
  if locale -a 2>/dev/null | grep -x "$cand" >/dev/null; then COMMA_LOCALE="$cand"; break; fi
done
if [ -n "$COMMA_LOCALE" ]; then
  ( cd "$FLAT" && LC_ALL="$COMMA_LOCALE" LC_NUMERIC="$COMMA_LOCALE" run_with_timeout 120 bash "$PRODUCER" ) >"$WORK/locale.json" 2>/dev/null
  a="$(jq -cS 'del(.generated_at_utc, .generated_at_local)' "$FLAT_OUT")"
  b="$(jq -cS 'del(.generated_at_utc, .generated_at_local)' "$WORK/locale.json")"
  [ "$a" = "$b" ] \
    || fail "J4: the comma-decimal locale $COMMA_LOCALE changed the report's numbers"
  ok "J4 a comma-decimal ambient locale ($COMMA_LOCALE) changes nothing"
else
  ok "J4 skipped -- no comma-decimal locale installed on this host to exercise the guard with"
fi

count
# No writes outside $TMPDIR: the target repo must be left exactly as found.
before="$(cd "$FLAT" && find . -type f | sort | while IFS= read -r p; do printf '%s ' "$p"; done)"
run "$FLAT"
after="$(cd "$FLAT" && find . -type f | sort | while IFS= read -r p; do printf '%s ' "$p"; done)"
[ "$before" = "$after" ] || fail "J5: the producer wrote into the target repo"
ok "J5 the producer writes nothing into the target repo"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION K — THE PRODUCER'S OWN DEGRADATION WHEN ITS DEPENDENCIES ARE GONE
# ═══════════════════════════════════════════════════════════════════════════

count
# stats.sh missing: the report must NOT fall back to a locally computed
# interval. It degrades instead — the whole point of consuming the library.
MIRROR8="$(mkmirror "$WORK/m8")"
rm -f "$WORK/m8/workflows/scripts/model-comparison/stats.sh"
run "$FLAT" "$MIRROR8"
[ "$RUN_RC" -eq 0 ] || fail "K1: a missing stats library must still exit 0"
grep -q '^skipped -- model-comparison: ' "$RUN_OUT" \
  || fail "K1: a missing stats library must render the skipped line"
grep -q 'winner' "$RUN_OUT" \
  && fail "K1: a missing stats library must never produce a winner"
ok "K1 a missing statistics library degrades rather than being locally substituted"

count
# stats.py broken (the library present, its numeric core unusable): the report
# still renders its per-arm facts, but withholds the interval, the MDE and any
# winner, with the reason stated.
MIRROR9="$(mkmirror "$WORK/m9")"
printf 'import sys\nsys.exit(3)\n' >"$WORK/m9/workflows/scripts/model-comparison/stats.py"
run "$FLAT" "$MIRROR9"
[ "$RUN_RC" -eq 0 ] || fail "K2: a broken numeric core must still exit 0"
[ "$(jqf "$RUN_OUT" '.comparison.confidence_interval')" = "null" ] \
  || fail "K2: with the numeric core broken there must be no confidence interval"
[ "$(jqf "$RUN_OUT" '.comparison | has("winner")')" = "false" ] \
  || fail "K2: with the numeric core broken there must be no winner"
[ "$(jqf "$RUN_OUT" '.comparison.statistics_unavailable_reason | type')" = "string" ] \
  || fail "K2: the missing statistics must be explained, not silently absent"
[ "$(jqf "$RUN_OUT" '.emit_coverage.coverage_pct')" = "null" ] \
  || fail "K2: coverage rides the same library and must be withheld too"
[ "$(jqf "$RUN_OUT" '.emit_coverage.unavailable_reason | type')" = "string" ] \
  || fail "K2: a withheld coverage figure must state why"
ok "K2 a broken numeric core withholds every statistic WITH a stated reason, and names no winner"

count
# score.sh missing: refuse rather than re-derive its scored-only split here.
MIRROR10="$(mkmirror "$WORK/m10")"
rm -f "$WORK/m10/workflows/scripts/model-comparison/score.sh"
run "$FLAT" "$MIRROR10"
[ "$RUN_RC" -eq 0 ] || fail "K3: a missing scorer must still exit 0"
grep -q '^skipped -- model-comparison: ' "$RUN_OUT" \
  || fail "K3: a missing scorer must render the skipped line"
ok "K3 a missing scorer degrades rather than having its split re-derived here"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION L — THE SUITE-WIDE NO-EGRESS VERDICT
# ═══════════════════════════════════════════════════════════════════════════

count
if [ -e "$CANARY" ]; then
  fail "L1: a network or model entry point was invoked during this suite: $(cat "$CANARY")"
fi
ok "L1 NO NETWORK, NO MODEL CALL: the claude/gh/curl/wget canaries on PATH were never invoked"

count
"$WORK/bin/curl" --self-test >/dev/null 2>&1
[ -e "$CANARY" ] || fail "L2: the canary itself does not work, so L1 proves nothing"
rm -f "$CANARY"
ok "L2 the canary is functional — L1 is a measurement, not a tautology"

echo
echo "test_comparison_report.sh: $pass/$total checks passed"
[ "$pass" -eq "$total" ] || exit 1
