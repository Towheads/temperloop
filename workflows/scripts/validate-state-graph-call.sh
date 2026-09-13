#!/usr/bin/env bash
#
# validate-state-graph-call.sh — presence-lint for the build.md Step 0.5
# state-graph cross-check call (temperloop#1910 L6).
#
# Step 0.5 runs `state-graph.sh build` then `state-graph.sh query resume`
# beside the resume authority-ordering prose (claude/commands/build.md §
# Step 0.5 item 4) so the two can be soak-compared — but a prose
# orchestrator step in a skill doc can silently rot (the same class
# validate-resume-recovery-emit.sh / validate-issue-touch-emit.sh already
# guard: an LLM-executed markdown step gets skipped or paraphrased away and
# nobody notices, because the failure mode is an ABSENT invocation, not an
# error). This script is the mechanical owner that makes that rot loud: it
# FAILS (exit 1) if any of the following goes missing —
#
#   1. the script itself (workflows/scripts/build/state-graph.sh) is absent
#      or not executable, or
#   2. build.md no longer invokes `state-graph.sh build`, or
#   3. build.md no longer invokes `state-graph.sh query resume`.
#
# This is also the exact surface the class-A activation-gate predicate for
# this item checks (temperloop#1934):
#   grep -q 'state-graph.sh' claude/commands/build.md \
#     && bash scripts/quality-gates.sh --list | grep -q validate-state-graph-call
#
# Same shape as validate-resume-recovery-emit.sh / validate-issue-touch-
# emit.sh: same hard-fail-on-half-present contract, wired into
# scripts/quality-gates.sh the same way (direct `bash` form, no Makefile
# target — matching the validate-model-usage-emit.sh / validate-diagnose-
# queue-emit.sh convention for a validator this item adds without touching
# the hand-maintained Makefile).
#
# Usage: workflows/scripts/validate-state-graph-call.sh   (resolves the repo itself)

set -euo pipefail

SCRIPTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$SCRIPTS_DIR/../.." && pwd)"
STATE_GRAPH_SCRIPT="$SCRIPTS_DIR/build/state-graph.sh"
BUILD_MD="$REPO/claude/commands/build.md"

fail=0

# --- 1. state-graph.sh itself must exist and be executable ------------------
if [ ! -f "$STATE_GRAPH_SCRIPT" ]; then
  echo "FAIL  state-graph.sh is missing (expected at $STATE_GRAPH_SCRIPT)"
  fail=1
elif [ ! -x "$STATE_GRAPH_SCRIPT" ]; then
  echo "FAIL  state-graph.sh exists but is not executable ($STATE_GRAPH_SCRIPT)"
  fail=1
else
  echo "ok    state-graph.sh present and executable"
fi

# --- 2/3. build.md's Step 0.5 must still invoke both the build and the ------
#          query resume calls
if [ ! -f "$BUILD_MD" ]; then
  echo "FAIL  build.md doc missing entirely ($BUILD_MD)"
  fail=1
else
  if ! grep -Fq 'state-graph.sh build' "$BUILD_MD"; then
    echo "FAIL  build.md ($BUILD_MD) no longer invokes 'state-graph.sh build' anywhere — the state-graph build call was removed from Step 0.5"
    fail=1
  else
    echo "ok    build.md wires 'state-graph.sh build' (Step 0.5)"
  fi
  if ! grep -Fq 'state-graph.sh query resume' "$BUILD_MD"; then
    echo "FAIL  build.md ($BUILD_MD) no longer invokes 'state-graph.sh query resume' anywhere — the resume cross-check call was removed from Step 0.5"
    fail=1
  else
    echo "ok    build.md wires 'state-graph.sh query resume' (Step 0.5)"
  fi
fi

echo "---"
if [ "$fail" -ne 0 ]; then
  echo "validate-state-graph-call: FAIL"
  exit 1
fi
echo "validate-state-graph-call: OK"
