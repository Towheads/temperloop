#!/usr/bin/env bash
# Tests for ks-agent-read-log.sh — the agent-plane knowledge-store
# read-telemetry hook (temperloop#236, Epic #226 "Vault IA v2 kernel
# machinery" capture point 2: "agent-plane read telemetry").
#
# Zero network, zero real-state mutation: every case exports KNOWLEDGE_READ_LOG
# and XDG_STATE_HOME to throwaway tmpdir paths and runs the hook against its
# REAL location in this checkout (workflows/scripts/lib/knowledge_store.sh
# already sits at the correct relative offset — no fixture repo needed for the
# happy-path cases; the "no reachable knowledge_store.sh" case builds its own
# minimal fixture, see #12).
#
# Covers:
#   - matched MCP tool calls append the SAME-format read-log line as the
#     script-plane emitter (PR #249's ks__read_log_emit), with plane=agent,
#     for each op bucket this hook derives: read, search, append, write, list
#   - a matched-but-unmapped tool name logs op=other (generic, not dropped)
#   - a non-matching tool_name (outside KNOWLEDGE_READ_LOG_AGENT_MATCHERS) is
#     silent — no read-log line at all
#   - the matcher-seam config change: overriding
#     KNOWLEDGE_READ_LOG_AGENT_MATCHERS to add `mcp__basic-memory__*` makes a
#     previously-unmatched tool call start logging, with ZERO hook edit
#   - EVAL_RUN=1 suppresses the hook entirely
#   - fail-open: malformed input, missing jq, and no reachable
#     knowledge_store.sh at all (a kernel-hooks-only vendor / stranger
#     checkout) — the hook must be inert, never guessing the log format
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../ks-agent-read-log.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }
# Claude Code runs the hook COMMAND PATH directly, so the file MUST be
# executable — a 0644 hook is silently inert (installed but never runs).
[ -x "$HOOK" ] || { echo "FATAL: hook is not executable (needs chmod +x) — Claude Code runs the command path directly" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-ks-agent-read-log-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
LOG="$TMP/knowledge-reads.log"

# run_hook <tool_name> <tool_input-json> [env NAME=VAL...]
run_hook() {
  local tool="$1" input="$2"; shift 2
  local json
  json=$(jq -cn --arg t "$tool" --argjson i "$input" '{tool_name:$t, tool_input:$i}')
  printf '%s' "$json" | env XDG_STATE_HOME="$TMP/xdg-state" KNOWLEDGE_READ_LOG="$LOG" "$@" bash "$HOOK"
}

lines_count() { [ -f "$LOG" ] && wc -l <"$LOG" | tr -d ' ' || echo 0; }

check_line() { # <desc> <expected-substring-of-last-line>
  local desc="$1" want="$2" line
  line="$(tail -n1 "$LOG" 2>/dev/null || true)"
  case "$line" in
    *"$want"*) pass=$((pass + 1)); printf '  \xe2\x9c\x93 %s\n' "$desc" ;;
    *) fail=$((fail + 1)); printf '  \xe2\x9c\x97 %s (want substring: %s; got line: %s)\n' "$desc" "$want" "$line" ;;
  esac
}

check_count() { # <desc> <expected> <actual>
  local desc="$1" want="$2" got="$3"
  if [ "$got" -eq "$want" ]; then
    pass=$((pass + 1)); printf '  \xe2\x9c\x93 %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  \xe2\x9c\x97 %s (want %s, got %s)\n' "$desc" "$want" "$got"
  fi
}

# --- 1. matched read tool -----------------------------------------------
run_hook "mcp__obsidian-builtin__vault_read" '{"path":"Decisions/foo.md"}' >/dev/null
check_line "vault_read -> op=read, doc=path" "· agent · read · Decisions/foo.md"

# --- 2. matched search tool (the OTHER obsidian namespace) --------------
run_hook "mcp__obsidian__search_vault_smart" '{"query":"widget install guide"}' >/dev/null
check_line "search_vault_smart -> op=search, doc=query" "· agent · search · widget install guide"

# --- 3. matched append tool ----------------------------------------------
run_hook "mcp__obsidian-builtin__vault_append" '{"path":"Scratch/log.md","content":"x"}' >/dev/null
check_line "vault_append -> op=append" "· agent · append · Scratch/log.md"

# --- 4. matched write-ish tool (patch) ------------------------------------
run_hook "mcp__obsidian-builtin__vault_patch" '{"path":"Decisions/foo.md","content":"x"}' >/dev/null
check_line "vault_patch -> op=write" "· agent · write · Decisions/foo.md"

# --- 5. matched list tool --------------------------------------------------
run_hook "mcp__obsidian-builtin__vault_list" '{"directory":"Decisions"}' >/dev/null
check_line "vault_list -> op=list" "· agent · list · Decisions"

# --- 6. matched-but-unmapped tool -> generic "other" op, not dropped -----
run_hook "mcp__obsidian-builtin__command_execute" '{"commandId":"app:go-back"}' >/dev/null
check_line "command_execute (unmapped) -> op=other, not silently dropped" "· agent · other · -"

n6="$(lines_count)"
check_count "6 matched calls -> 6 read-log lines" 6 "$n6"

# --- 7. non-matching tool_name -> silent, no new line ----------------------
run_hook "Bash" '{"command":"ls"}' >/dev/null
n7="$(lines_count)"
check_count "non-matching tool_name (Bash) -> silent" "$n6" "$n7"

# a plausible-but-not-yet-enabled namespace -> also silent under today's default
run_hook "mcp__basic-memory__search_notes" '{"query":"widget"}' >/dev/null
n7b="$(lines_count)"
check_count "mcp__basic-memory__* not matched by TODAY's default seam -> silent" "$n7" "$n7b"

# --- 8. matcher-seam config change: enable mcp__basic-memory__* with NO hook edit --
run_hook "mcp__basic-memory__search_notes" '{"query":"widget"}' \
  KNOWLEDGE_READ_LOG_AGENT_MATCHERS="mcp__obsidian* mcp__obsidian-builtin* mcp__basic-memory__*" >/dev/null
check_line "one-line matcher-seam override enables mcp__basic-memory__* (zero hook edit)" "· agent · search · widget"

# --- 9. EVAL_RUN=1 suppresses the hook entirely -----------------------------
n9_before="$(lines_count)"
run_hook "mcp__obsidian-builtin__vault_read" '{"path":"Decisions/eval.md"}' EVAL_RUN=1 >/dev/null
n9_after="$(lines_count)"
check_count "EVAL_RUN=1 suppresses the hook" "$n9_before" "$n9_after"

# --- 10. fail-open: malformed input -----------------------------------------
out="$(printf 'not json' | XDG_STATE_HOME="$TMP/xdg-state" KNOWLEDGE_READ_LOG="$LOG" bash "$HOOK")"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  pass=$((pass + 1)); printf '  \xe2\x9c\x93 %s\n' "malformed input fails open (exit 0, no output)"
else
  fail=$((fail + 1)); printf '  \xe2\x9c\x97 malformed input: rc=%s out=%s\n' "$rc" "$out"
fi

# --- 11. fail-open: jq missing -----------------------------------------------
# BASH_BIN is invoked by its absolute path (found via the test's own normal
# PATH) so ONLY the hook's internal `command -v jq` sees the jq-less PATH,
# mirroring test_subtree_edit_guard.sh's technique.
BASH_BIN="$(command -v bash)"
NOJQ_BIN="$TMP/nojq-bin"
mkdir -p "$NOJQ_BIN"
for b in cat git dirname basename readlink mkdir date env printf tr wc sed cut; do
  bp="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$bp" ] && ln -sf "$bp" "$NOJQ_BIN/$b"
done
json=$(jq -cn '{tool_name:"mcp__obsidian-builtin__vault_read", tool_input:{path:"Decisions/foo.md"}}')
n11_before="$(lines_count)"
out="$(printf '%s' "$json" | PATH="$NOJQ_BIN" XDG_STATE_HOME="$TMP/xdg-state" KNOWLEDGE_READ_LOG="$LOG" "$BASH_BIN" "$HOOK")"
rc=$?
n11_after="$(lines_count)"
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$n11_after" -eq "$n11_before" ]; then
  pass=$((pass + 1)); printf '  \xe2\x9c\x93 %s\n' "missing jq fails open (exit 0, no output, no log line)"
else
  fail=$((fail + 1)); printf '  \xe2\x9c\x97 jq-missing: rc=%s out=%s before=%s after=%s\n' "$rc" "$out" "$n11_before" "$n11_after"
fi

# --- 12. fail-open / inert: no reachable knowledge_store.sh -----------------
# A "kernel-hooks-only" vendor / stranger checkout: this hook + its
# eval-guard.sh sibling exist, but NOTHING else of the repo does (no
# workflows/scripts/lib/knowledge_store.sh two directories up). Proves the
# hook resolves its library path relative to ITS OWN real directory (never a
# hardcoded personal path like $HOME/dev/foundation) and, finding nothing,
# stays inert rather than guessing the log format.
FIXTURE="$TMP/hooks-only-vendor"
mkdir -p "$FIXTURE/claude/hooks"
cp "$HOOK" "$FIXTURE/claude/hooks/"
cp "$HERE/../eval-guard.sh" "$FIXTURE/claude/hooks/"
chmod +x "$FIXTURE/claude/hooks/ks-agent-read-log.sh"
FIX_LOG="$TMP/hooks-only-vendor-log/knowledge-reads.log"   # must never be created
json=$(jq -cn '{tool_name:"mcp__obsidian-builtin__vault_read", tool_input:{path:"Decisions/foo.md"}}')
out="$(printf '%s' "$json" | XDG_STATE_HOME="$TMP/xdg-state" KNOWLEDGE_READ_LOG="$FIX_LOG" bash "$FIXTURE/claude/hooks/ks-agent-read-log.sh")"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -f "$FIX_LOG" ]; then
  pass=$((pass + 1)); printf '  \xe2\x9c\x93 %s\n' "no reachable knowledge_store.sh -> inert (fail-open), no log line"
else
  fail=$((fail + 1)); printf '  \xe2\x9c\x97 hooks-only-vendor fixture: rc=%s out=%s log-exists=%s\n' \
    "$rc" "$out" "$([ -f "$FIX_LOG" ] && echo yes || echo no)"
fi

echo
echo "ks-agent-read-log.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
