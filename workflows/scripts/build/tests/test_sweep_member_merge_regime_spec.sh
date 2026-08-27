#!/usr/bin/env bash
#
# test_sweep_member_merge_regime_spec.sh — presence-lint + discrimination
# proof for /sweep's member-bearing-chunk merge-regime selection
# (temperloop#1847 follow-on, item member-merge-regimes).
#
# /sweep's per-chunk merge pass is executed by an LLM reading
# claude/commands/sweep.md, not by a script this suite can invoke directly —
# so, exactly like validate-command-run-emit.sh does for the run-telemetry
# emit, the mechanically checkable surface is the SPEC TEXT itself: does the
# doc still say what the acceptance criteria require, in a form specific
# enough that removing the feature (or reverting to the old unconditional
# immediate-merge behavior) would make this check fail.
#
# THE ACCEPTANCE BAR (verbatim from the item):
#   - the per-chunk merge pass runs regime selection (the gate.sh risk
#     partition) whenever the chunk contains epic members; a correlated/
#     risky set is offered modally, never auto-merged on a timer
#     (member-bearing chunk triggers regime selection; singleton-only chunk
#     keeps today's posture)
#   - the spec text names this as preserving the kernel merge-autonomy
#     contract (only a clean, disjoint set is timed)
#
# DISCRIMINATION. Each check below is run twice: once against the real
# claude/commands/sweep.md (must PASS — proves the feature is actually
# shipped), and once against a MUTATED copy with the exact sentence that
# check depends on stripped out (must FAIL — proves the check can actually
# go red, not just vacuously pass on any file). A check that never fails on
# ANY input is not discriminating; this suite would not have caught the
# feature's absence before this item landed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
SWEEP_MD="$REPO/claude/commands/sweep.md"
[ -f "$SWEEP_MD" ] || { echo "FAIL: sweep.md not found at $SWEEP_MD" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- the five checks, each operating over a FILE PATH so they can run
#     against the real doc and a mutated copy identically -------------------

check_member_trigger() {  # member-bearing chunk triggers the gate
  grep -Fq 'A chunk with at least one epic-admitted member runs the risk partition first' "$1"
}

check_gate_risk_invoked() {  # the actual gate.sh risk mechanism, not a re-implementation
  grep -Fq 'workflows/scripts/build/gate.sh risk "$ownerRepo"' "$1"
}

check_singleton_unaffected() {  # singleton-only chunk keeps today's posture
  grep -Fq 'A chunk with zero epic-admitted members (the common case) skips this gate entirely' "$1"
}

check_risky_never_timed_modal() {  # RISKY -> modal, never a timed auto-merge
  grep -Fq 'never auto-merge this set on a timer' "$1" \
    && grep -Fq 'AskUserQuestion' "$1"
}

check_kernel_contract_named() {  # spec text names the kernel merge-autonomy contract
  grep -Fq 'claude/CLAUDE.md § Merge autonomy & consent' "$1" \
    && grep -Fq 'only a clean, disjoint set is timed; a risky set is always modal' "$1"
}

run_all() {  # $1=file path -> prints which checks passed/failed, returns count of failures
  local f="$1" failures=0
  check_member_trigger "$f"        || { echo "  x member-trigger";        failures=$((failures+1)); }
  check_gate_risk_invoked "$f"     || { echo "  x gate.sh-risk-invoked";  failures=$((failures+1)); }
  check_singleton_unaffected "$f"  || { echo "  x singleton-unaffected";  failures=$((failures+1)); }
  check_risky_never_timed_modal "$f" || { echo "  x risky-never-timed-modal"; failures=$((failures+1)); }
  check_kernel_contract_named "$f" || { echo "  x kernel-contract-named"; failures=$((failures+1)); }
  return "$failures"
}

# --- 1. every check PASSES against the real, shipped sweep.md ---------------
echo "== real sweep.md =="
run_all "$SWEEP_MD"
real_failures=$?
[ "$real_failures" -eq 0 ] || fail "$real_failures check(s) failed against the REAL sweep.md — the member-merge-regime feature is not (fully) present"
echo "PASS: all 5 checks pass against the real sweep.md"

# --- 2. DISCRIMINATION — each check independently goes RED when its own
#        sentence is stripped, proving none of them vacuously pass -----------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mutate_and_expect_fail() {  # $1=label $2=needle-to-strip $3=check-fn
  local label="$1" needle="$2" fn="$3" mutant="$tmp/mutant.md"
  grep -Fv "$needle" "$SWEEP_MD" > "$mutant"
  if "$fn" "$mutant"; then
    fail "$label: check still PASSED after stripping its own required sentence — not discriminating"
  fi
  echo "PASS: $label goes RED when its required sentence is removed"
}

mutate_and_expect_fail "member-trigger" \
  'A chunk with at least one epic-admitted member runs the risk partition first' \
  check_member_trigger

mutate_and_expect_fail "gate.sh-risk-invoked" \
  'workflows/scripts/build/gate.sh risk "$ownerRepo"' \
  check_gate_risk_invoked

mutate_and_expect_fail "singleton-unaffected" \
  'A chunk with zero epic-admitted members (the common case) skips this gate entirely' \
  check_singleton_unaffected

mutate_and_expect_fail "risky-never-timed-modal (timer clause)" \
  'never auto-merge this set on a timer' \
  check_risky_never_timed_modal

mutate_and_expect_fail "kernel-contract-named (invariant quote)" \
  'only a clean, disjoint set is timed; a risky set is always modal' \
  check_kernel_contract_named

# --- 3. a mutant that strips ONLY the singleton-unaffected sentence must
#        still show the OTHER four checks green — proves the checks are
#        independent, not one giant grep that fails/passes as a block -------
mutant2="$tmp/mutant2.md"
grep -Fv 'A chunk with zero epic-admitted members (the common case) skips this gate entirely' "$SWEEP_MD" > "$mutant2"
check_member_trigger "$mutant2"        || fail "independence check: member-trigger unexpectedly failed on an unrelated mutation"
check_gate_risk_invoked "$mutant2"     || fail "independence check: gate.sh-risk-invoked unexpectedly failed on an unrelated mutation"
check_risky_never_timed_modal "$mutant2" || fail "independence check: risky-never-timed-modal unexpectedly failed on an unrelated mutation"
check_kernel_contract_named "$mutant2" || fail "independence check: kernel-contract-named unexpectedly failed on an unrelated mutation"
check_singleton_unaffected "$mutant2"  && fail "independence check: singleton-unaffected unexpectedly PASSED on the mutant that removed its own sentence"
echo "PASS: checks are independent (a targeted mutation fails only its own check)"

echo "---"
echo "test_sweep_member_merge_regime_spec: OK"
