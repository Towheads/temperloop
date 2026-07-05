#!/usr/bin/env bash
#
# knowledge_search_mcp.sh — an optional WARM search backend for the
# knowledge_search adapter: "basic-memory-mcp".
#
# Talks to a persistent, externally-supervised `basic-memory mcp`
# streamable-http daemon (launchd / systemd / any process supervisor — this
# library never launches it) instead of spawning a fresh `uvx basic-memory`
# CLI per query. A warm daemon pays basic-memory's ~2s app/DB/embedding-model
# startup ONCE at load; each search is then a plain HTTP round-trip to an
# in-process handler — measured ~0.2s per fresh call (full initialize + search
# cycle) vs several seconds for the cold CLI path. The cold "basic-memory"
# backend (knowledge_search.sh) remains the zero-infrastructure default; this
# file is only useful where an adopter has stood up the daemon.
#
# ── Registration (extends via the dispatch seam — no core edit) ────────────
# knowledge_search.sh dispatches backends by `declare -F` on
# `_ks_search_backend_<name>_<op>`. This file registers a NEW backend named
# "basic-memory-mcp" purely by DEFINING those functions, so it extends the
# adapter without modifying knowledge_search.sh. It MUST be sourced AFTER
# knowledge_search.sh: it reuses that file's cold
# `_ks_search_backend_basic_memory_*` functions for fail-open fallback, its
# JSONL reshape contract, and ks_root (from knowledge_store.sh). Select it
# with `export KNOWLEDGE_SEARCH_BACKEND=basic-memory-mcp`.
#
# ── Fail-open ─────────────────────────────────────────────────────────────
# If the daemon is unreachable / errors / returns an unparseable body, this
# backend DELEGATES to the cold "basic-memory" backend (a fresh uvx CLI
# subprocess) after printing a one-line "degraded —" notice to stderr. A slow
# answer, never a silent empty result — the adapter's legible-degradation
# posture (knowledge_search.sh exit-code contract) is preserved.
#
# ── AGPL boundary ─────────────────────────────────────────────────────────
# basic-memory (AGPL-3.0) is reached ONLY as a separate process over the MCP
# protocol (HTTP + JSON-RPC) — never imported or vendored, exactly as the cold
# backend reaches it via `uvx`. This file itself NEVER runs `basic-memory mcp`
# (it is an HTTP *client* of an already-running daemon); starting the daemon is
# the supervisor's job, out of this repo's tree. So the adapter stays
# CLI-only-plus-HTTP-client and test_knowledge_search_agpl_boundary.sh's "no
# tracked shell script invokes basic-memory mcp" invariant holds unchanged.
#
# This file is SOURCED — it sets no shell options (the caller owns set -euo).
# Depends on: knowledge_search.sh (source FIRST), curl, jq.

# ── Config knobs ──────────────────────────────────────────────────────────
#   KNOWLEDGE_SEARCH_BM_MCP_URL    daemon endpoint. Default is a loopback-only
#                                  streamable-http address; override to match
#                                  the supervised daemon's host/port/path.
#   KNOWLEDGE_SEARCH_BM_MCP_PROTO  MCP protocol version sent in the handshake.
#   *_CONNECT_TIMEOUT / *_MAX_TIME curl timeouts (seconds). CONNECT is kept
#                                  short so an unreachable daemon fails FAST to
#                                  the cold fallback instead of hanging a caller.
: "${KNOWLEDGE_SEARCH_BM_MCP_URL:=http://127.0.0.1:8766/mcp}"
: "${KNOWLEDGE_SEARCH_BM_MCP_PROTO:=2025-03-26}"
: "${KNOWLEDGE_SEARCH_BM_MCP_CONNECT_TIMEOUT:=2}"
: "${KNOWLEDGE_SEARCH_BM_MCP_MAX_TIME:=30}"

# ── low-level MCP-over-HTTP helpers ───────────────────────────────────────
# streamable-http responses are SSE ("event: message\n data: {json}\n\n"); the
# single JSON-RPC reply for a request rides one `data:` line, extracted here.
#
# Opens a session: POST initialize, echo the Mcp-Session-Id response header
# (empty string + return 1 if the daemon is unreachable or gives no session).
_ks_bm_mcp_open_session() {
  local init hdrs sid
  init="$(jq -cn --arg p "$KNOWLEDGE_SEARCH_BM_MCP_PROTO" \
    '{jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:$p,capabilities:{},clientInfo:{name:"knowledge_search_mcp",version:"1"}}}')"
  hdrs="$(curl -s -o /dev/null -D - \
      --connect-timeout "$KNOWLEDGE_SEARCH_BM_MCP_CONNECT_TIMEOUT" \
      --max-time "$KNOWLEDGE_SEARCH_BM_MCP_MAX_TIME" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -X POST --data "$init" "$KNOWLEDGE_SEARCH_BM_MCP_URL" 2>/dev/null)" || return 1
  sid="$(printf '%s' "$hdrs" | tr -d '\r' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}')"
  [ -n "$sid" ] || return 1
  # Required by the MCP lifecycle before further requests (fire-and-forget).
  curl -s -o /dev/null \
    --connect-timeout "$KNOWLEDGE_SEARCH_BM_MCP_CONNECT_TIMEOUT" \
    --max-time "$KNOWLEDGE_SEARCH_BM_MCP_MAX_TIME" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: $sid" -H "MCP-Protocol-Version: $KNOWLEDGE_SEARCH_BM_MCP_PROTO" \
    -X POST --data '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    "$KNOWLEDGE_SEARCH_BM_MCP_URL" 2>/dev/null || true
  printf '%s' "$sid"
}

# ── public backend interface (dispatched by knowledge_search.sh) ──────────

# available: warm daemon reachable OR the cold backend's tooling is present.
# Never worse than the cold backend — a down daemon still reports available
# when uvx is on PATH, because search will fail open to the cold path.
_ks_search_backend_basic_memory_mcp_available() {
  if _ks_bm_mcp_open_session >/dev/null 2>&1; then
    return 0
  fi
  _ks_search_backend_basic_memory_available
}

# search <query> [--limit N] -> JSONL on stdout, SAME shape as the cold
# backend: one {doc_id,title,score,snippet} object per line.
_ks_search_backend_basic_memory_mcp_search() {
  local query="$1"; shift
  local limit=10
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) limit="${2:?knowledge_search: --limit requires a value}"; shift 2 ;;
      *) shift ;;
    esac
  done

  local sid call raw results
  if sid="$(_ks_bm_mcp_open_session)" && [ -n "$sid" ]; then
    # Daemon reachable. search_type:"hybrid" is passed EXPLICITLY to match the
    # cold path's `--hybrid`: bm's default is only a *dynamic* hybrid (and only
    # when the daemon's config has semantic search enabled), so pinning it keeps
    # warm and cold from silently diverging to text-only on a differently-
    # configured daemon — the fail-open safety argument is latency-only, not a
    # change in search mode.
    call="$(jq -cn --arg q "$query" --argjson lim "$limit" --arg proj "$KNOWLEDGE_SEARCH_BM_PROJECT" \
      '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"search_notes",arguments:{query:$q,output_format:"json",search_type:"hybrid",page_size:$lim,project:$proj}}}')"
    raw="$(curl -s \
        --connect-timeout "$KNOWLEDGE_SEARCH_BM_MCP_CONNECT_TIMEOUT" \
        --max-time "$KNOWLEDGE_SEARCH_BM_MCP_MAX_TIME" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "Mcp-Session-Id: $sid" -H "MCP-Protocol-Version: $KNOWLEDGE_SEARCH_BM_MCP_PROTO" \
        -X POST --data "$call" "$KNOWLEDGE_SEARCH_BM_MCP_URL" 2>/dev/null)"
    # Extract the SSE data line, verify a non-error tool result, then reshape via
    # the shared _ks_bm_reshape_results (one owner of the JSONL contract, so warm
    # and cold can't drift apart).
    results="$(printf '%s' "$raw" | sed -n 's/^data: //p' \
      | jq -e 'if (.result.isError == true) then error("tool error")
               else (.result.content[0].text | fromjson) end' 2>/dev/null)"
    if [ -n "$results" ]; then
      printf '%s' "$results" | _ks_bm_reshape_results
      return 0
    fi
    # Reachable but the tool returned an error / empty / unparseable body. The
    # most common cause is a PROJECT MISMATCH — the daemon serves a single
    # launch-time --project, but this client sent KNOWLEDGE_SEARCH_BM_PROJECT.
    # Name it so a misconfig is visible, never misread as "daemon down".
    echo "degraded — bm mcp daemon reached but returned no usable result (check its --project matches KNOWLEDGE_SEARCH_BM_PROJECT='$KNOWLEDGE_SEARCH_BM_PROJECT'), falling back to cold CLI path" >&2
  else
    echo "degraded — bm mcp daemon unreachable at $KNOWLEDGE_SEARCH_BM_MCP_URL, falling back to cold CLI path" >&2
  fi
  _ks_search_backend_basic_memory_search "$query" --limit "$limit"
}

# reindex [--full] -> the daemon serves the same on-disk corpus; reindexing is
# an explicit maintenance op (not latency-sensitive), so delegate to the cold
# CLI reindex rather than duplicate it over MCP.
_ks_search_backend_basic_memory_mcp_reindex() {
  _ks_search_backend_basic_memory_reindex "$@"
}
