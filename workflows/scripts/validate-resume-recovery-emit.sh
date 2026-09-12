#!/usr/bin/env bash
#
# validate-resume-recovery-emit.sh — presence-lint for the build.md Step 0.5
# resume-recovery emit (temperloop#1908).
#
# build.md's Step 0.5 item 5 (the reconciliation report) is the only place a
# `/build` resume records what it recovered or flagged.
# emit-resume-recovery.sh is the concrete emit — but a prose orchestrator
# step in a skill doc can silently rot (the June silent-failure class: an
# LLM-executed markdown step gets skipped or paraphrased away and nobody
# notices, because the failure mode is an ABSENT record, not an error). This
# script is the mechanical owner that makes that rot loud: it FAILS CI (exit
# 1) if either half of the wiring goes missing —
#
#   1. the script itself (workflows/scripts/emit-resume-recovery.sh) is
#      absent or not executable, or
#   2. its invocation is removed from claude/commands/build.md's Step 0.5
#      item 5.
#
# Same shape as validate-issue-touch-emit.sh / validate-command-run-emit.sh:
# same hard-fail-on-half-present contract, wired into
# scripts/quality-gates.sh the same way.
#
# Usage: workflows/scripts/validate-resume-recovery-emit.sh   (resolves the repo itself)

set -euo pipefail

SCRIPTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$SCRIPTS_DIR/../.." && pwd)"
EMIT_SCRIPT="$SCRIPTS_DIR/emit-resume-recovery.sh"
BUILD_MD="$REPO/claude/commands/build.md"

fail=0

# --- 1. the emit script itself must exist and be executable -----------------
if [ ! -f "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-resume-recovery.sh is missing (expected at $EMIT_SCRIPT)"
  fail=1
elif [ ! -x "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-resume-recovery.sh exists but is not executable ($EMIT_SCRIPT)"
  fail=1
else
  echo "ok    emit-resume-recovery.sh present and executable"
fi

# --- 2. build.md's Step 0.5 item 5 must still invoke it ---------------------
if [ ! -f "$BUILD_MD" ]; then
  echo "FAIL  build.md doc missing entirely ($BUILD_MD)"
  fail=1
elif ! grep -Fq 'emit-resume-recovery.sh' "$BUILD_MD"; then
  echo "FAIL  build.md ($BUILD_MD) no longer invokes emit-resume-recovery.sh anywhere — the resume-recovery emit was removed from the executable path"
  fail=1
else
  echo "ok    build.md wires emit-resume-recovery.sh (Step 0.5 item 5)"
fi

echo "---"
if [ "$fail" -ne 0 ]; then
  echo "validate-resume-recovery-emit: FAIL"
  exit 1
fi
echo "validate-resume-recovery-emit: OK"
