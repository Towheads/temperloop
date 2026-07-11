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
mkdir -p "$TMP/store" "$TMP/raw" "$TMP/state"

# Point the backend at a definitely-closed port so the warm path fails FAST
# (connection refused) into the fail-open branch — no daemon required.
export KNOWLEDGE_STORE_ROOT="$TMP/store"
# Isolate the read-log (temperloop#229) under the throwaway tmpdir too — any
# ks_search call below goes through ks__read_log_emit; without this override
# it would default to the real machine's $XDG_STATE_HOME/foundation/
# knowledge-reads.log.
export KNOWLEDGE_READ_LOG="$TMP/knowledge-reads.log"
export KNOWLEDGE_SEARCH_BM_MCP_URL="http://127.0.0.1:1/mcp"
export KNOWLEDGE_SEARCH_BM_MCP_CONNECT_TIMEOUT="1"
export KNOWLEDGE_SEARCH_BM_PROJECT="test-project"
# Keep the fallback telemetry + de-dup marker HERMETIC (temperloop#54): land the
# raw-lake record and the session marker inside TMP, never the real repo tree /
# system TMPDIR.
export KS_SEARCH_FALLBACK_RAW_DIR="$TMP/raw"
export KS_SEARCH_FALLBACK_STATE_DIR="$TMP/state"

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

# 3d. DURABLE SIGNAL: the fallback emitted exactly one raw-lake telemetry record
# — the surface that survives a swallowed stderr (temperloop#54).
month="$(date -u +%Y-%m)"
tfile="$TMP/raw/knowledge-search-fallback-${month}.jsonl"
[ -f "$tfile" ] || fail "no fallback telemetry record written to $tfile"
n="$(wc -l < "$tfile" | tr -d ' ')"
[ "$n" = "1" ] || fail "expected exactly 1 fallback telemetry record, got $n"
jq -e '.schema_version=="1" and .backend=="basic-memory-mcp" and .reason=="unreachable"' \
  < "$tfile" >/dev/null || fail "telemetry record shape/reason invalid: $(cat "$tfile")"
echo "PASS: 3d fallback emits one raw-lake telemetry record (reason=unreachable, schema_version=1)"

# 3e. DE-DUPED one-time-per-session: a SECOND fallback in the same session emits
# NEITHER a second 'degraded —' stderr line NOR a second telemetry record — but
# still fails open to the cold path.
err2="$(_ks_search_backend_basic_memory_mcp_search "another query" --limit 3 2>"$TMP/err2.txt")"
notice2="$(cat "$TMP/err2.txt")"
case "$notice2" in *"degraded —"*) fail "second fallback re-emitted the stderr notice (not de-duped): [$notice2]" ;; esac
case "$err2" in *"COLD_SEARCH_MARKER limit=3"*) : ;; *) fail "second fallback did not still delegate to cold path: [$err2]" ;; esac
n2="$(wc -l < "$tfile" | tr -d ' ')"
[ "$n2" = "1" ] || fail "second fallback wrote another telemetry record (expected still 1, got $n2)"
echo "PASS: 3e fallback signal de-duped one-time-per-session (no notice/telemetry spam; still fails open)"

# 3b. available: unreachable daemon returns the cold backend's verdict (7).
rc=0; _ks_search_backend_basic_memory_mcp_available || rc=$?
[ "$rc" = "7" ] || fail "available did not delegate to cold backend (expected rc=7, got $rc)"
echo "PASS: 3b available fail-open: delegates to cold availability verdict"

# 3c. reindex: delegates to cold reindex, passing args through.
out="$(_ks_search_backend_basic_memory_mcp_reindex --full)"
case "$out" in *"COLD_REINDEX_MARKER args=--full"*) : ;; *) fail "reindex did not delegate with args, got: [$out]" ;; esac
echo "PASS: 3c reindex delegates to cold reindex (args passed through)"

echo "ALL PASS: knowledge_search_mcp.sh (registration + selection + fail-open, hermetic)"
