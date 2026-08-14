#!/usr/bin/env bash
#
# cannot-evaluate.sh — a SOURCED library providing ONE fail-closed emission
# path for the "cannot evaluate" idiom (temperloop#1475, epic #1409), reused
# by every model-comparison script that refuses to score/judge/replay an
# input it could not read rather than silently treating it as passing.
#
# WHY THIS EXISTS: workflows/scripts/model-comparison/batch.sh, judge.sh,
# score.sh, and replay.sh (both its `preflight` and `execute` commands) each
# independently reinvented the same two-line idiom — a `bd_cannot_evaluate`,
# `_je_cannot_evaluate`, `cannot_evaluate`, `preflight_cannot_evaluate`, and
# `execute_cannot_evaluate`, four of them byte-identical modulo a script-name
# prefix. Worse: EVERY ONE OF THEM RETURNED 0 — the function's body was a
# `jq` print followed by a `printf` to stderr, with no explicit `return`, so
# the function's own exit status was whatever `printf` happened to return
# (success). Every existing call site happens to follow the call with its
# own explicit `return 1` (or `return 2` for an arg-parse error), which is
# why this was never observed misbehaving — but a FUTURE caller that forgets
# to branch (`cannot_evaluate "x" && something_that_should_not_run`) falls
# straight through to the OK path. That is this repo's own #1409 defect
# shape, reinvented inside the very idiom meant to prevent it.
#
# THE FIX: one shared helper, sourced everywhere, whose OWN return status is
# the reserved non-zero code — so a caller that forgets to branch fails
# CLOSED (the shell's own `set -e`, or a `||`/`&&` the caller DID write
# correctly, sees a non-zero status) instead of falling through silently.
#
# THE RESERVED CODE CONVERGES ON 2, matching the THREE sibling
# already-existing "cannot evaluate" conventions this repo carries —
# KERNEL_LIB_RC_CANNOT_EVALUATE (workflows/scripts/kernel/lib.sh),
# PA_RC_CANNOT_EVALUATE (workflows/scripts/model-comparison/allowlist.sh),
# and FD_RC_CANNOT_EVALUATE (workflows/scripts/validate-feature-docs.sh) —
# rather than inventing a fourth value. This file's RC_CANNOT_EVALUATE is
# the canonical constant for the five call sites it replaces; it does not
# rename or absorb those three siblings' own constants, which remain their
# own scripts' local names for the identical value.
#
# THE TWO OUTPUT SHAPES, unchanged from every prior local implementation
# (byte-identical to what batch.sh/judge.sh/score.sh/replay.sh execute
# already printed, and — the one correction this hoist makes — restored for
# replay.sh's preflight, which alone among the five previously emitted the
# JSON shape but no stderr line, temperloop#1475 finding 3):
#   stdout   a single JSON object, `{outcome:"CANNOT_EVALUATE",error:<msg>}`
#            — the MACHINE verdict, consumed by e.g. batch.sh's own
#            `.outcome == "CANNOT_EVALUATE"` check on replay.sh preflight's
#            output.
#   stderr   `<prefix>: CANNOT EVALUATE — <msg>` — the distinct HUMAN
#            diagnostic line every model-comparison test fixture's
#            `expect_cannot_evaluate` helper asserts for.
# Both shapes, and the reserved code, are registered as a machine-parsed
# surface in claude/presentation-plane.md — read that file before reformatting
# either.
#
# Usage (sourced, never executed directly — this file has no CLI of its own):
#   . workflows/scripts/lib/cannot-evaluate.sh
#   cannot_evaluate_emit "score.sh" "corpus record is malformed: $f"
#   return $?   # or: cannot_evaluate_emit "..." "..."; return 1  — either
#               # way the idiom now fails closed even if the explicit
#               # `return` after it is someday dropped by mistake.
#
# Kept bash-3.2-portable (no associative arrays / mapfile), matching the rest
# of workflows/scripts/lib/.

# RC_CANNOT_EVALUATE — the reserved non-zero exit status cannot_evaluate_emit
# returns. See the file header for why this converges on 2 rather than
# minting a new value.
RC_CANNOT_EVALUATE=2

# cannot_evaluate_emit <prefix> <message>
# Prints the machine verdict on stdout and the distinct human diagnostic on
# stderr, THEN returns RC_CANNOT_EVALUATE — never 0. <prefix> is the calling
# script's own name/subcommand label (e.g. "score.sh", "replay.sh execute"),
# reproduced verbatim in the stderr line so a mixed log still reads which
# command refused.
cannot_evaluate_emit() {
  local prefix="$1" msg="$2"
  jq -cn --arg e "$msg" '{outcome:"CANNOT_EVALUATE",error:$e}'
  printf '%s: CANNOT EVALUATE — %s\n' "$prefix" "$msg" >&2
  return "$RC_CANNOT_EVALUATE"
}
