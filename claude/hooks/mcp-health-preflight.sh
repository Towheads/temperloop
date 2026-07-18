#!/usr/bin/env bash
# SessionStart hook — fail-loud preflight for the Obsidian MCP servers.
#
# Probes (a) the built-in REST server (GET /) and (b) the semantic-search path
# (POST /search/smart, backed by Smart Connections via the mcp-tools plugin).
# If either is degraded, injects a loud banner instructing Claude to HALT
# vault-dependent analysis and tell the user, instead of silently falling back
# to grep / Read / keyword search (which significantly degrades analysis).
#
# Healthy semantic = HTTP 200 or 400: the handler's Smart-Connections-availability
# check returns 503 BEFORE body validation, so a 400 (bad probe body) still proves
# SC is loaded and the route is alive. DEGRADED = timeout / connection failure
# (Obsidian hung or down) or 503 (Smart Connections unavailable).
#
# Fails OPEN: any error in the hook itself must never block session start.
# See vault note [[Decisions/foundation - Fail-loud halt when Obsidian MCP degrades]]
#
# EVAL_RUN suppression: when EVAL_RUN is set (non-empty), skip the preflight.
# Eval sessions do not depend on Obsidian vault access; injecting a degradation
# banner into an eval context would corrupt the model's context and skew scores.
# shellcheck source=eval-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/eval-guard.sh"
eval_guard_exit_if_eval

set -uo pipefail

# Config default resolution routes through the knowledge_store seam's obsidian
# backend (foundation #777, Epic A #762 "kernel split") — its own defaults
# already resolve to today's vault path/URL in that ONE file, not duplicated
# here.
#
# KS_LIB_DIR resolution order (temperloop#406 — no shipped hook may default
# to a hardcoded personal checkout path):
#   1. KS_LIB_DIR env override — highest precedence, always wins.
#   2. BASH_SOURCE-relative: claude/hooks/<this file> -> ../../workflows/scripts/lib.
#      Works for both a plain checkout and the production whole-directory
#      symlink install (workflows/scripts/install/links.sh symlinks the
#      entire claude/hooks/ directory, not per-file — the OS resolves that
#      symlinked directory before applying "..", so the relative climb still
#      lands in the real checkout). Same convention as
#      session-end-read-summary.sh's own KS_LIB_DIR resolution in this
#      directory.
# No hardcoded personal-path default: on a checkout where neither resolves
# (a stripped-down tree with no workflows/scripts/lib/), KS_LIB_DIR stays
# empty and the sourcing below simply no-ops — the preflight then fails open
# at the "can't read the API key" check further down, same as today.
KS_LIB_DIR="${KS_LIB_DIR:-}"
if [ -z "$KS_LIB_DIR" ]; then
  KS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../workflows/scripts/lib" 2>/dev/null && pwd)"
fi
if [ -n "$KS_LIB_DIR" ] && [ -f "$KS_LIB_DIR/knowledge_store.sh" ]; then
  # shellcheck source=/dev/null
  . "$KS_LIB_DIR/knowledge_store.sh"
fi
if [ -n "$KS_LIB_DIR" ] && [ -f "$KS_LIB_DIR/knowledge_store_obsidian.sh" ]; then
  # shellcheck source=/dev/null
  . "$KS_LIB_DIR/knowledge_store_obsidian.sh"
fi

API_KEY_FILE="${KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE:-}"
API_BASE="${MCP_HEALTH_API_BASE:-${KNOWLEDGE_STORE_OBSIDIAN_API_BASE:-https://127.0.0.1:27124}}"
# Hook logs live in the XDG state dir (foundation #773), not ~/.claude/hooks/ —
# runtime state, not config.
XDG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/foundation"
mkdir -p "$XDG_STATE_DIR" 2>/dev/null || true
LOG="$XDG_STATE_DIR/mcp-health-preflight.log"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }

# Consume stdin (SessionStart payload; unused here).
cat >/dev/null 2>&1 || true

# Fail open if we can't read the API key.
[ -f "$API_KEY_FILE" ] || exit 0
KEY=$(jq -r '.apiKey // empty' "$API_KEY_FILE" 2>/dev/null) || exit 0
[ -n "$KEY" ] || exit 0

problems=()

# 1) Built-in REST server: GET / should be 200.
rest_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 \
  "$API_BASE/" -H "Authorization: Bearer $KEY" 2>/dev/null)
rest_curl=$?
if [ "$rest_curl" -ne 0 ]; then
  problems+=("built-in REST server ($API_BASE) unreachable — curl exit $rest_curl (Obsidian down or hung)")
elif [ "$rest_code" != "200" ]; then
  problems+=("built-in REST server returned HTTP $rest_code (expected 200)")
fi

# 2) Semantic search (Smart Connections via /search/smart).
smart_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 12 \
  -X POST "$API_BASE/search/smart" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"query":"mcp health preflight"}' 2>/dev/null)
smart_curl=$?
if [ "$smart_curl" -ne 0 ]; then
  problems+=("semantic search (/search/smart) unreachable — curl exit $smart_curl (Obsidian hung or down)")
elif [ "$smart_code" = "503" ]; then
  problems+=("semantic search DOWN — Smart Connections plugin unavailable (HTTP 503)")
elif [ "$smart_code" != "200" ] && [ "$smart_code" != "400" ]; then
  problems+=("semantic search returned unexpected HTTP $smart_code")
fi

if [ "${#problems[@]}" -eq 0 ]; then
  log "healthy: REST=$rest_code smart=$smart_code"
  exit 0
fi

list=$(printf '  - %s\n' "${problems[@]}")
log "DEGRADED: REST=${rest_code:-?}/curl${rest_curl} smart=${smart_code:-?}/curl${smart_curl}"

banner=$(printf '%s\n%s\n%s' \
"⚠️ OBSIDIAN MCP DEGRADED — semantic vault search and/or REST ops are unavailable:" \
"$list" \
"Per [[Decisions/foundation - Fail-loud halt when Obsidian MCP degrades]]: DO NOT perform vault-dependent analysis and DO NOT silently fall back to grep / Read / keyword search — vault-grounded analysis is significantly degraded without semantic search. HALT and tell the user the Obsidian MCP is degraded, then let them decide whether to proceed. Non-vault work (code, evals, git) is unaffected.")

jq -cn --arg c "$banner" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' 2>/dev/null || true
exit 0
