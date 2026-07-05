#!/usr/bin/env bash
#
# Tests for workflows/scripts/lib/knowledge_search_mcp.sh — the optional WARM
# search backend "basic-memory-mcp".
#
# Hermetic: no daemon, no network, no uvx. The happy path (a live daemon
# answering ~0.2s) is proven by an adopter's live measurement; here we lock the
# CI-checkable invariants that fail SILENTLY otherwise:
#   1. the lib registers the three backend ops via the declare -F seam,
#   2. the backend is selectable by KNOWLEDGE_SEARCH_BACKEND,
#   3. FAIL-OPEN: an unreachable daemon delegates to the cold basic-memory
#      backend (search), and available/reindex delegate too — proven by
#      stubbing the cold functions, so no real bm subprocess is needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ks-search-mcp-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/store"

# Point the backend at a definitely-closed port so the warm path fails FAST
# (connection refused) into the fail-open branch — no daemon required.
export KNOWLEDGE_STORE_ROOT="$TMP/store"
export KNOWLEDGE_SEARCH_BM_MCP_URL="http://127.0.0.1:1/mcp"
export KNOWLEDGE_SEARCH_BM_MCP_CONNECT_TIMEOUT="1"
export KNOWLEDGE_SEARCH_BM_PROJECT="test-project"

# shellcheck source=/dev/null
source "$LIB_DIR/knowledge_store.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/knowledge_search.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/knowledge_search_mcp.sh"

# ── 1. the three backend ops are registered ────────────────────────────────
for op in search available reindex; do
  declare -F "_ks_search_backend_basic_memory_mcp_$op" >/dev/null \
    || fail "backend op '$op' not registered (missing _ks_search_backend_basic_memory_mcp_$op)"
done
echo "PASS: 1 backend registers search/available/reindex via the declare -F seam"

# ── 2. selectable by KNOWLEDGE_SEARCH_BACKEND ──────────────────────────────
export KNOWLEDGE_SEARCH_BACKEND="basic-memory-mcp"
got="$(ks_search__backend_fn search)"
[ "$got" = "_ks_search_backend_basic_memory_mcp_search" ] \
  || fail "dispatch resolved to '$got', expected _ks_search_backend_basic_memory_mcp_search"
echo "PASS: 2 KNOWLEDGE_SEARCH_BACKEND=basic-memory-mcp dispatches to the warm backend"

# ── 3. FAIL-OPEN: unreachable daemon delegates to the cold backend ─────────
# Stub the cold functions the warm backend falls back to, so we assert
# delegation without a real bm subprocess.
_ks_search_backend_basic_memory_search()   { echo "COLD_SEARCH_MARKER limit=$3"; }
_ks_search_backend_basic_memory_available() { return 7; }
_ks_search_backend_basic_memory_reindex()   { echo "COLD_REINDEX_MARKER args=$*"; }

# 3a. search: prints the "degraded —" notice AND the cold marker.
err="$(_ks_search_backend_basic_memory_mcp_search "some query" --limit 5 2>"$TMP/err.txt" )"
notice="$(cat "$TMP/err.txt")"
case "$notice" in *"degraded —"*) : ;; *) fail "expected 'degraded —' fail-open notice, got: [$notice]" ;; esac
case "$err" in *"COLD_SEARCH_MARKER limit=5"*) : ;; *) fail "search did not delegate to cold backend (with --limit), got: [$err]" ;; esac
echo "PASS: 3a search fail-open: notice on stderr + delegates to cold path (limit preserved)"

# 3b. available: unreachable daemon returns the cold backend's verdict (7).
rc=0; _ks_search_backend_basic_memory_mcp_available || rc=$?
[ "$rc" = "7" ] || fail "available did not delegate to cold backend (expected rc=7, got $rc)"
echo "PASS: 3b available fail-open: delegates to cold availability verdict"

# 3c. reindex: delegates to cold reindex, passing args through.
out="$(_ks_search_backend_basic_memory_mcp_reindex --full)"
case "$out" in *"COLD_REINDEX_MARKER args=--full"*) : ;; *) fail "reindex did not delegate with args, got: [$out]" ;; esac
echo "PASS: 3c reindex delegates to cold reindex (args passed through)"

echo "ALL PASS: knowledge_search_mcp.sh (registration + selection + fail-open, hermetic)"
