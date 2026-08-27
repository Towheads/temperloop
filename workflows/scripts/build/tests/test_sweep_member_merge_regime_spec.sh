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

# --- round-2 escalation checks (three additional findings) -----------------

check_error_never_permissive() {  # ERROR/non-zero-exit/malformed-JSON named alongside RISKY, not ignored
  grep -Fq 'an error is never the permissive branch' "$1" \
    && grep -Fq 'ERROR` (any `gh pr view` failure inside the gate)' "$1"
}

check_error_branch_held() {  # the never-auto-merge branch explicitly covers ERROR/non-zero-exit/malformed JSON, not just RISKY
  grep -Fq 'a non-zero exit, or unparseable/malformed JSON' "$1" \
    && grep -Fq 'held conservatively' "$1"
}

check_recovery_paths_honest() {  # honest recovery language present; the unreachable "future re-offer" claim is gone
  grep -Fq 'there is no automatic re-offer' "$1" \
    && ! grep -Fq 'future attended `/sweep` run re-offers it' "$1" \
    && ! grep -Fq 're-run /sweep attended to approve' "$1"
}

check_option_cap() {  # AskUserQuestion respects the ≤4-option cap, with a Merge-all/Hold-all/Abort fallback above it
  grep -Fq '≤4 options total, Step 2' "$1" \
    && grep -Fq 'exceed the 4-option cap' "$1"
}

run_all() {  # $1=file path -> prints which checks passed/failed, returns count of failures
  local f="$1" failures=0
  check_member_trigger "$f"        || { echo "  x member-trigger";        failures=$((failures+1)); }
  check_gate_risk_invoked "$f"     || { echo "  x gate.sh-risk-invoked";  failures=$((failures+1)); }
  check_singleton_unaffected "$f"  || { echo "  x singleton-unaffected";  failures=$((failures+1)); }
  check_risky_never_timed_modal "$f" || { echo "  x risky-never-timed-modal"; failures=$((failures+1)); }
  check_kernel_contract_named "$f" || { echo "  x kernel-contract-named"; failures=$((failures+1)); }
  check_error_never_permissive "$f" || { echo "  x error-never-permissive"; failures=$((failures+1)); }
  check_error_branch_held "$f"     || { echo "  x error-branch-held";     failures=$((failures+1)); }
  check_recovery_paths_honest "$f" || { echo "  x recovery-paths-honest"; failures=$((failures+1)); }
  check_option_cap "$f"            || { echo "  x option-cap";            failures=$((failures+1)); }
  return "$failures"
}

# --- 1. every check PASSES against the real, shipped sweep.md ---------------
echo "== real sweep.md =="
run_all "$SWEEP_MD"
real_failures=$?
[ "$real_failures" -eq 0 ] || fail "$real_failures check(s) failed against the REAL sweep.md — the member-merge-regime feature is not (fully) present"
echo "PASS: all 9 checks pass against the real sweep.md"

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

mutate_and_expect_fail "error-never-permissive (naming clause)" \
  'an error is never the permissive branch' \
  check_error_never_permissive

mutate_and_expect_fail "error-branch-held (conservative-hold clause)" \
  'held conservatively' \
  check_error_branch_held

mutate_and_expect_fail "recovery-paths-honest (no-re-offer clause)" \
  'there is no automatic re-offer' \
  check_recovery_paths_honest

mutate_and_expect_fail "option-cap (fallback clause)" \
  'exceed the 4-option cap' \
  check_option_cap

# --- 2b. recovery-paths-honest must ALSO go RED if the stale, unreachable
#         "future attended /sweep run re-offers it" claim (round-2 escalation
#         finding #2) is reintroduced — this is the negative half of that
#         check (absence, not presence), so prove it discriminates by ADDING
#         the stale sentence back rather than stripping one -----------------
reoffer_mutant="$tmp/reoffer_mutant.md"
{
  cat "$SWEEP_MD"
  echo 'a future attended `/sweep` run re-offers it, or re-run /sweep attended to approve'
} > "$reoffer_mutant"
if check_recovery_paths_honest "$reoffer_mutant"; then
  fail "recovery-paths-honest: check still PASSED after reintroducing the stale re-offer claim — not discriminating"
fi
echo "PASS: recovery-paths-honest goes RED when the stale re-offer claim is reintroduced"

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
