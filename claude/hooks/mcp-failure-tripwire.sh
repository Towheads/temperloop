#!/usr/bin/env bash
# PostToolUse hook (matcher: mcp__obsidian.*) — fail-loud tripwire.
#
# If an Obsidian MCP tool call returns a transport/availability failure
# (timeout, connection refused, Smart Connections unavailable, MCP error),
# block with a directive so Claude HALTS vault-dependent analysis and tells the
# user, instead of silently falling back to grep / Read / keyword search.
#
# Conservative by design: matches only narrow transport-level signatures (not
# bare "404"/"timeout"/"503" — those appear in normal vault content and would
# false-trip). Content-bearing read/search tools (whose body legitimately echoes
# vault prose containing failure-words) are scanned by the structured is_error
# flag ONLY, never the free-text regex (#84). Fails OPEN: a successful call (or
# any parse issue) passes through.
# See "Decisions/foundation - Fail-loud halt when Obsidian MCP degrades.md" in
# the operator's knowledge store (workflows/scripts/lib/knowledge_store.contract.md).
set -uo pipefail

# Hook logs live in the XDG state dir (foundation #773), not ~/.claude/hooks/ —
# runtime state, not config.
XDG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/foundation"
mkdir -p "$XDG_STATE_DIR" 2>/dev/null || true
LOG="$XDG_STATE_DIR/mcp-failure-tripwire.log"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$tool" in
  mcp__obsidian*) ;;
  *) exit 0 ;;   # matcher should scope this, but double-check
esac

# Extract the tool result (field name varies across versions: tool_response /
# tool_result). Only inspect the RESULT, never tool_input (which holds the
# user's query and could contain failure-like words).
resp=$(printf '%s' "$INPUT" | jq -r '(.tool_response // .tool_result // empty) | tostring' 2>/dev/null)
[ -n "$resp" ] || exit 0

# Opportunistic explicit-error flag (present in some versions).
is_error=$(printf '%s' "$INPUT" | jq -r '((.tool_response // .tool_result) | objects | (.isError // .is_error)) // empty' 2>/dev/null)

# Content-bearing read/search tools legitimately return vault PROSE that can
# contain transport-failure words — a Mistakes/ note about timeouts, the friction
# ledger (which logs "halted on a transient MCP error"), a session transcript. A
# free-text scan of those bodies false-trips on a perfectly healthy read (#84), so
# for these tools trust ONLY the structured is_error flag. Mutation tools
# (create/patch/append/delete/move/write) return short status bodies, not vault
# content — keep the regex scan there as a fallback for versions lacking is_error.
content_bearing=0
case "$tool" in
  *get_vault_file|*get_active_file|*vault_read \
  |*search*|*list*|*document_map|*fetch \
  |*active_file_get_path|*periodic_note_get_path|*get_server_info)
    content_bearing=1 ;;   # *list* also covers *tag_list
esac

shopt -s nocasematch
fail=0
[ "$is_error" = "true" ] && fail=1
if [ "$content_bearing" -ne 1 ] && [[ "$resp" =~ (ECONNREFUSED|ETIMEDOUT|ECONNRESET|EAI_AGAIN|fetch[\ _]failed|socket\ hang\ up|connection\ refused|request\ timed\ out|timed\ out\ after|Smart\ Connections\ plugin\ is\ not\ available|MCP\ error|tool\ execution\ failed|request\ failed\ with\ status|could\ not\ connect|unable\ to\ connect) ]]; then
  fail=1
fi
shopt -u nocasematch

[ "$fail" -ne 1 ] && exit 0

log "TRIPPED on $tool :: $(printf '%s' "$resp" | head -c 220 | tr '\n' ' ')"

reason=$(printf '%s' "⚠️ Obsidian MCP call ($tool) failed — likely a degraded server (timeout / unreachable / Smart Connections unavailable). Per [[Decisions/foundation - Fail-loud halt when Obsidian MCP degrades]]: HALT vault-dependent analysis NOW. Do NOT silently fall back to grep / Read / keyword search — vault-grounded analysis is unreliable without the MCP. Tell the user the Obsidian MCP is degraded and let them decide whether to proceed or retry once it recovers. Non-vault work is unaffected.")

jq -cn --arg r "$reason" '{decision:"block", reason:$r}' 2>/dev/null || true
exit 0
