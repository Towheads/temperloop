#!/usr/bin/env bash
#
# validate-command-run-emit.sh — presence-lint for the /sweep + /triage
# per-run telemetry emit (foundation #729, epic #724).
#
# /sweep and /triage have no plan-note footer, so nothing else signals that a
# run happened at all. emit-command-run.sh is the fix — but a prose "final
# step" in a skill doc can silently rot (the June silent-failure class: an
# LLM-executed markdown step gets skipped or paraphrased away and nobody
# notices, because the failure mode is an ABSENT record, not an error). This
# script is the mechanical owner that makes that rot loud: it FAILS CI (exit 1)
# if either half of the wiring goes missing —
#
#   1. the script itself (workflows/scripts/emit-command-run.sh) is absent or
#      not executable, or
#   2. its invocation is removed from claude/commands/sweep.md or
#      claude/commands/triage.md — i.e. the skill doc no longer contains a
#      call to `emit-command-run.sh` with `--command sweep` / `--command
#      triage` respectively.
#
# This mirrors the validate-live-drain.sh shape (same script style, same
# hard-fail-on-half-present contract, wired into scripts/quality-gates.sh
# the same way) — see workflows/scripts/validate-live-drain.sh for the sibling
# pattern this one is modeled on.
#
# Usage: workflows/scripts/validate-command-run-emit.sh   (resolves the repo itself)

set -euo pipefail

SCRIPTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$SCRIPTS_DIR/../.." && pwd)"
EMIT_SCRIPT="$SCRIPTS_DIR/emit-command-run.sh"
SWEEP_MD="$REPO/claude/commands/sweep.md"
TRIAGE_MD="$REPO/claude/commands/triage.md"

fail=0

# --- 1. the emit script itself must exist and be executable -----------------
if [ ! -f "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-command-run.sh is missing (expected at $EMIT_SCRIPT)"
  fail=1
elif [ ! -x "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-command-run.sh exists but is not executable ($EMIT_SCRIPT)"
  fail=1
else
  echo "ok    emit-command-run.sh present and executable"
fi

# --- 2. each command doc must still invoke it with its own --command value --
check_wiring() {  # $1=label $2=path $3=expected --command value
  local label="$1" file="$2" cmdval="$3"
  if [ ! -f "$file" ]; then
    echo "FAIL  $label doc missing entirely ($file)"
    fail=1
    return
  fi
  if ! grep -Fq 'emit-command-run.sh' "$file"; then
    echo "FAIL  $label ($file) no longer invokes emit-command-run.sh — the run-telemetry emit was removed from the executable path"
    fail=1
    return
  fi
  # The invocation spans a few lines (a `\`-continued bash block), so scan a
  # window of lines AFTER the emit-command-run.sh match for the --command
  # flag rather than requiring it on the same line.
  if ! grep -A4 -F 'emit-command-run.sh' "$file" | grep -Eq -- "--command[[:space:]]+${cmdval}\b"; then
    echo "FAIL  $label ($file) invokes emit-command-run.sh but not with --command ${cmdval} — wiring drifted"
    fail=1
    return
  fi
  echo "ok    $label wires emit-command-run.sh --command $cmdval"
}

check_wiring "sweep.md"  "$SWEEP_MD"  "sweep"
check_wiring "triage.md" "$TRIAGE_MD" "triage"

echo "---"
if [ "$fail" -ne 0 ]; then
  echo "validate-command-run-emit: FAIL"
  exit 1
fi
echo "validate-command-run-emit: OK"
