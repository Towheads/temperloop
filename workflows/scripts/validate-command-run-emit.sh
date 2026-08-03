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
#      triage` respectively, or
#   3. (temperloop#1084) a command doc that defines a **`resolved (verdict)`**
#      terminal disposition invokes the emit WITHOUT `--resolved`. That is the
#      exact defect #1084 was filed for: /sweep can terminate an item on a
#      spike verdict, but its emit could only say merged/parked, so the
#      verdict-resolved items vanished and the counts stopped reconciling
#      against items_processed. The check is CONTENT-DERIVED, not a hardcoded
#      doc list: any command doc whose prose declares the `resolved (verdict)`
#      disposition must pass `--resolved`, so a doc that GAINS that disposition
#      later is caught without editing this script. A doc with no such
#      disposition may legitimately omit the flag (it defaults to 0) — but it
#      still has to satisfy the emitter's own
#      `merged + resolved + parked == items_processed` assertion at run time.
#
# This mirrors the validate-capture-backstop.sh shape (same script style, same
# hard-fail-on-half-present contract, wired into scripts/quality-gates.sh
# the same way) — see workflows/scripts/validate-capture-backstop.sh for the sibling
# pattern this one is modeled on.
#
# Usage: workflows/scripts/validate-command-run-emit.sh   (resolves the repo itself)

set -euo pipefail

SCRIPTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$SCRIPTS_DIR/../.." && pwd)"
EMIT_SCRIPT="$SCRIPTS_DIR/emit-command-run.sh"
SWEEP_MD="$REPO/claude/commands/sweep.md"
TRIAGE_MD="$REPO/claude/commands/triage.md"
FIX_MD="$REPO/claude/commands/fix.md"

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
  # 1b. and it must still accept --resolved + still assert the sum (#1084).
  #     Without these the wiring below is cosmetic: the callers would pass a
  #     flag the script silently drops (the `WARN unknown argument` arm).
  if ! grep -Eq -- '--resolved\)' "$EMIT_SCRIPT"; then
    echo "FAIL  emit-command-run.sh no longer parses --resolved — the verdict-resolved disposition (temperloop#1084) lost its telemetry field"
    fail=1
  elif ! grep -Fq 'disposition_total' "$EMIT_SCRIPT"; then
    echo "FAIL  emit-command-run.sh parses --resolved but no longer asserts merged + resolved + parked == items_processed — a disposition added without a field would under-report silently again (temperloop#1084)"
    fail=1
  else
    echo "ok    emit-command-run.sh parses --resolved and asserts the disposition sum"
  fi
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

# --- 3. a doc that can terminate an item on a VERDICT must pass --resolved ---
# Content-derived (see the header): the trigger is the doc declaring the
# `resolved (verdict)` disposition, not this script knowing which docs do.
check_resolved() {  # $1=label $2=path
  local label="$1" file="$2"
  [ -f "$file" ] || return 0   # missing-doc case already reported by check_wiring
  if ! grep -Fqi 'resolved (verdict)' "$file"; then
    echo "ok    $label declares no 'resolved (verdict)' disposition — --resolved not required"
    return
  fi
  # The invocation is a `\`-continued block; scan a window after the match.
  if ! grep -A8 -F 'emit-command-run.sh' "$file" | grep -Eq -- '--resolved[[:space:]]'; then
    echo "FAIL  $label ($file) declares a 'resolved (verdict)' terminal disposition but its emit-command-run.sh call omits --resolved — verdict-resolved items would be invisible and the counts would not reconcile against items_processed (temperloop#1084)"
    fail=1
    return
  fi
  echo "ok    $label declares 'resolved (verdict)' and passes --resolved"
}

check_wiring "sweep.md"  "$SWEEP_MD"  "sweep"
check_wiring "triage.md" "$TRIAGE_MD" "triage"
check_wiring "fix.md"    "$FIX_MD"    "fix"

check_resolved "sweep.md"  "$SWEEP_MD"
check_resolved "triage.md" "$TRIAGE_MD"
check_resolved "fix.md"    "$FIX_MD"

echo "---"
if [ "$fail" -ne 0 ]; then
  echo "validate-command-run-emit: FAIL"
  exit 1
fi
echo "validate-command-run-emit: OK"
