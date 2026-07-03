#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash) — board adapter guard (foundation #97 follow-up).
#
# WHY: every GitHub Projects-v2 board read/write should go through the board.sh
# adapter (board_resolve / board_resolve_item / board_item_list / board_set_*),
# which caches across processes and keeps single-item ops off the expensive
# `item-list --limit 200` page. Ad-hoc raw `gh project ...` / `gh api graphql`
# Projects queries bypass that and drained the 5,000-pt/hr GraphQL budget in a
# real session. This hook makes the adapter the DEFAULT by prompting (ask, not
# deny) whenever the model issues a DIRECT Projects-v2 query — so a genuine
# bypass (a structural field/option mutation the adapter doesn't cover) is a
# conscious, approved choice rather than an accident.
#
# WHY THIS IS PRECISE: a PreToolUse Bash hook sees only the TOP-LEVEL command
# string. The adapter's own `gh project` calls run as subprocesses of
# `bash worklist.sh` / `source board.sh; board_resolve` and never appear here —
# so matching a literal `gh project` / `gh api graphql …projectV2` catches direct
# bypasses without ever tripping on legitimate adapter use.
#
# Returns permissionDecision "ask" on a match; otherwise stays silent so the
# normal permission flow proceeds. FAILS OPEN: any internal error (no jq,
# unparseable input) exits 0 and never blocks a command.
#
# EVAL_RUN behaviour: under eval the decision downgrades from *ask* to
# *deny*. An adapter bypass by the workflow under test is a scorable finding
# (the unattended runner cannot answer an interactive prompt), so instead of
# hanging the run we deny the command immediately and log the attempt to a
# durable eval-denial log at the path below.  Production sessions (EVAL_RUN
# unset) are unchanged.
set -uo pipefail

# Eval denial log path: written only when EVAL_RUN is set. Lives in the XDG
# state dir (foundation #773), not ~/.claude/hooks/ — hook logs are runtime
# state, not config.
XDG_STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/foundation"
EVAL_DENIAL_LOG="${EVAL_DENIAL_LOG:-${XDG_STATE_DIR}/eval-board-adapter-denials.log}"

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0   # fail open: no jq, no guard

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$tool" = "Bash" ] || exit 0            # matcher scopes this, but double-check

cmd=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# A gh invocation at a COMMAND position (start of line/string, or after a
# separator/pipe/subshell) — so `grep 'gh project' …` or `cat board.sh` (which
# merely CONTAIN the string as data) don't false-trip the guard.
boundary='(^|[;&|(]|&&|\|\|)[[:space:]]*'

# (1) Any `gh project …` subcommand is always a Projects-v2 board op.
# (2) `gh api graphql …` is only a board op when it references projectV2/ProjectV2
#     (plain repo/issue GraphQL and all REST `gh api repos/…` calls are exempt).
if printf '%s' "$cmd" | grep -Eq "${boundary}gh[[:space:]]+project([[:space:]]|$)" \
   || { printf '%s' "$cmd" | grep -Eq "${boundary}gh[[:space:]]+api[[:space:]]+graphql" \
        && printf '%s' "$cmd" | grep -q "rojectV2"; }; then

  if [ -n "${EVAL_RUN:-}" ]; then
    # EVAL_RUN mode: record-and-deny.  An adapter bypass by the workflow under
    # test is a scorable finding — deny immediately (no interactive prompt) and
    # append a structured log line so the eval harness can detect and score it.
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$(dirname "$EVAL_DENIAL_LOG")" 2>/dev/null || true
    printf '[%s] BOARD-ADAPTER-BYPASS DENIED cmd=%s\n' "$ts" "$cmd" \
      >> "$EVAL_DENIAL_LOG" 2>/dev/null || true
    deny_reason="EVAL_RUN: direct GitHub Projects-v2 board query detected. Board-adapter guard has downgraded from *ask* to *deny* under eval — an adapter bypass is a scored finding. Use the board.sh adapter (board_resolve_item / board_resolve / board_item_list / board_set_*). Denial recorded to $EVAL_DENIAL_LOG."
    jq -cn --arg r "$deny_reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' \
      2>/dev/null || true
  else
    # Production mode: ask (the original behaviour).
    reason="This command issues a DIRECT GitHub Projects-v2 board query, bypassing the board.sh adapter. Prefer the adapter — source lib/board.sh and use board_resolve_item <board> <issue#> (single issue, cheap) / board_resolve (whole board, cached) / board_item_list / board_set_status / board_set_milestone / board_set_component, or a board command (worklist/claim/release/reconcile/capture/milestone). The adapter caches across processes and keeps single-item ops off the expensive item-list --limit 200 page, which protects the shared 5,000-pt/hr GraphQL budget (foundation #93/#97). Approve ONLY if this is something the adapter genuinely can't do — e.g. a structural field/option/milestone mutation (gh project field-create, updateProjectV2Field)."
    jq -cn --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}' \
      2>/dev/null || true
  fi
  exit 0
fi

exit 0
