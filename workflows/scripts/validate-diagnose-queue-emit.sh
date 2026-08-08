#!/usr/bin/env bash
#
# validate-diagnose-queue-emit.sh — presence-lint for the gate.sh
# diagnose-queue lake-stream emit (temperloop#1192).
#
# Unlike validate-issue-touch-emit.sh / validate-command-run-emit.sh (which
# guard a PROSE orchestrator step in a skill .md invoking a standalone emit
# script), this emit has no markdown orchestration at all — it is pure shell
# library code: `workflows/scripts/build/gate.sh`'s `cmd_diagnose_queue` is
# the ONE place a merge-queue verdict is computed, and it must route EVERY
# exit path (including its own internal `die()` error paths) through the
# sibling emit script (`workflows/scripts/emit-diagnose-queue.sh`) rather
# than printing the verdict and discarding it — the #1192 bug this stream
# fixes. This mirrors validate-knowledge-search-emit.sh's shape (library
# code, not a .md doc) adapted from "library function computes and passes
# expected fields" to "every verdict return site funnels through the emit
# wrapper, and no return site regresses to a bare, unemitted die()/jq -cn".
#
# The rot risk is the same June silent-failure class all these validators
# guard against: a future edit to cmd_diagnose_queue (a new verdict, a
# refactored return site) could silently drop the emit call on that one path
# and nothing would fail except the lake quietly under-counting one outcome.
# This script FAILS CI (exit 1) if:
#
#   1. emit-diagnose-queue.sh is missing or not executable, or
#   2. gate.sh no longer defines the emit-wrapper helpers (_dq_emit/
#      _dq_finish/_dq_die) referencing emit-diagnose-queue.sh, or
#   3. cmd_diagnose_queue's body no longer routes each of the six
#      JSON-producing verdicts (QUEUED, MERGED, MERGE_GROUP_FAILED,
#      MERGE_GROUP_INFRA, DEQUEUED, QUEUE_STALLED) through `_dq_finish`, or
#   4. cmd_diagnose_queue's body contains a BARE `die "..."` call (i.e. one
#      that bypasses `_dq_die`) — this would silently exempt that error path
#      from the ERROR verdict emit.
#
# Usage: workflows/scripts/validate-diagnose-queue-emit.sh   (resolves the repo itself)

set -euo pipefail

SCRIPTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMIT_SCRIPT="$SCRIPTS_DIR/emit-diagnose-queue.sh"
GATE_SH="$SCRIPTS_DIR/build/gate.sh"

fail=0

# --- 1. the emit script itself must exist and be executable -----------------
if [ ! -f "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-diagnose-queue.sh is missing (expected at $EMIT_SCRIPT)"
  fail=1
elif [ ! -x "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-diagnose-queue.sh exists but is not executable ($EMIT_SCRIPT)"
  fail=1
else
  echo "ok    emit-diagnose-queue.sh present and executable"
fi

if [ ! -f "$GATE_SH" ]; then
  echo "FAIL  gate.sh doc missing entirely ($GATE_SH)"
  fail=1
  echo "---"
  echo "validate-diagnose-queue-emit: FAIL"
  exit 1
fi

# --- 2. gate.sh must still define the emit-wrapper helpers, wired to the ----
#        sibling script (never a hardcoded/duplicated path). ----------------
if ! grep -Fq 'emit-diagnose-queue.sh' "$GATE_SH"; then
  echo "FAIL  gate.sh ($GATE_SH) no longer references emit-diagnose-queue.sh anywhere — the lake-stream emit was removed"
  fail=1
else
  echo "ok    gate.sh references emit-diagnose-queue.sh"
fi

for helper in _dq_emit _dq_finish _dq_die; do
  if ! grep -Eq "^${helper}\(\)" "$GATE_SH"; then
    echo "FAIL  gate.sh no longer defines $helper() — the diagnose-queue emit wrapper is incomplete"
    fail=1
  else
    echo "ok    gate.sh defines $helper()"
  fi
done

# --- 3. isolate cmd_diagnose_queue's own body for the return-site checks ----
body="$(awk '/^cmd_diagnose_queue\(\) \{/{flag=1} flag{print} /^\}/{if(flag)exit}' "$GATE_SH")"
if [ -z "$body" ]; then
  echo "FAIL  could not isolate cmd_diagnose_queue's body in gate.sh — function renamed or reshaped?"
  fail=1
else
  # Every JSON-producing verdict this function can return must route through
  # _dq_finish. Window each outcome literal with a few lines of PRECEDING
  # context (materialized via command substitution first, per the EPIPE
  # false-failure trap validate-issue-touch-emit.sh's own comment documents —
  # never a live `grep -B | grep` pipeline under `set -o pipefail`) and
  # confirm _dq_finish appears in that window.
  for outcome in QUEUED MERGED MERGE_GROUP_FAILED MERGE_GROUP_INFRA DEQUEUED QUEUE_STALLED; do
    hits="$(grep -c "outcome:\"${outcome}\"" <<<"$body" || true)"
    if [ "${hits:-0}" -eq 0 ]; then
      echo "FAIL  cmd_diagnose_queue no longer produces an outcome:\"$outcome\" verdict — the verdict set shrank"
      fail=1
      continue
    fi
    window="$(grep -B3 "outcome:\"${outcome}\"" <<<"$body" || true)"
    unwired="$(grep -c '_dq_finish' <<<"$window" || true)"
    if [ "${unwired:-0}" -eq 0 ]; then
      echo "FAIL  cmd_diagnose_queue produces outcome:\"$outcome\" but no _dq_finish call precedes it — this verdict is printed and discarded, not emitted"
      fail=1
    else
      echo "ok    cmd_diagnose_queue routes outcome:\"$outcome\" through _dq_finish"
    fi
  done

  # No bare `die "..."` may remain — every internal error path must go
  # through _dq_die (which emits ERROR, then calls the real die()). Match a
  # SPACE immediately before `die "` so `_dq_die "..."` (no space before
  # `die`) never false-positives.
  bare="$(grep -c ' die "' <<<"$body" || true)"
  if [ "${bare:-0}" -gt 0 ]; then
    echo "FAIL  cmd_diagnose_queue contains $bare bare 'die \"...\"' call(s) that bypass _dq_die — those error paths never emit an ERROR verdict record"
    fail=1
  else
    echo "ok    cmd_diagnose_queue has no bare die() calls — every internal error path routes through _dq_die"
  fi
fi

echo "---"
if [ "$fail" -ne 0 ]; then
  echo "validate-diagnose-queue-emit: FAIL"
  exit 1
fi
echo "validate-diagnose-queue-emit: OK"
