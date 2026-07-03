#!/usr/bin/env bash
# eval-guard.sh — shared sourced helper for EVAL_RUN isolation.
#
# PURPOSE: hooks source this file to enforce a uniform early-exit when the
# EVAL_RUN environment variable is set (truthy, i.e. non-empty).  An eval run
# must not bleed into production pipelines — no SessionEnd stubs, no vault
# drain, no AskUserQuestion telemetry, no OTel records.  Board-adapter guard
# separately downgrades from *ask* to *record-and-deny* (see board-adapter-guard.sh).
#
# USAGE (in a hook, near the top, BEFORE any side-effectful code):
#   # shellcheck source=eval-guard.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/eval-guard.sh"
#   eval_guard_exit_if_eval    # exits 0 immediately if EVAL_RUN is set
#
# DESIGN NOTES:
#   - The check is intentionally cheap: a single [ -n "$EVAL_RUN" ] test.
#   - Sourcing rather than subshelling keeps the helper zero-overhead on
#     production runs (no fork, no pipe).
#   - The function exits the *calling* shell (the hook process), not just the
#     subshell, because it is sourced — `exit 0` propagates correctly.
#   - Default behavior when EVAL_RUN is unset is byte-equivalent in effect to
#     having no guard: the function is a no-op and the hook continues normally.

# eval_guard_exit_if_eval — call near the top of any hook that owns a
# production write channel.  Exits the hook process with code 0 (success,
# no decision output) when EVAL_RUN is set.
eval_guard_exit_if_eval() {
  [ -n "${EVAL_RUN:-}" ] || return 0
  exit 0
}
