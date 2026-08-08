#!/usr/bin/env bash
#
# validate-knowledge-search-emit.sh — presence-lint for the ks_search
# per-query read-log OUTCOME-field emit (foundation#1449, epic
# foundation#1443 "obs-outcome-emit").
#
# Unlike validate-issue-touch-emit.sh / validate-command-run-emit.sh (which
# guard a PROSE orchestrator step in a skill .md invoking a standalone emit
# script), this emit has no markdown orchestration at all — it is pure shell
# library code: knowledge_search.sh's `ks_search` is the ONE entrypoint
# shared by both the cold `basic-memory` backend and the warm
# `basic-memory-mcp` daemon backend (knowledge_search_mcp.sh delegates
# through the same dispatch seam, so it needs no separate call site here).
# The rot risk is the same June silent-failure class all the same — a future
# refactor of `ks_search` could silently drop the outcome-field computation
# or the extra args on the `ks__read_log_emit` call, and nothing would fail
# except an inspection of the read-log's line shape. This script is the
# mechanical owner that makes that rot loud: it FAILS CI (exit 1) if either
# half of the wiring goes missing —
#
#   1. knowledge_store.sh's `ks__read_log_emit` no longer accepts additive
#      trailing fields (the `for outcome_field in "$@"` loop that appends
#      them after the 5-field prefix), or
#   2. knowledge_search.sh's `ks_search` no longer computes AND passes all
#      six outcome fields (result_count, top_score, abstained, rg_fallback,
#      mode, wall_ms) to `ks__read_log_emit`.
#
# This mirrors the validate-issue-touch-emit.sh / validate-command-run-emit.sh
# shape (same script style, same hard-fail-on-half-present contract, wired
# into scripts/quality-gates.sh the same way) — see
# workflows/scripts/validate-issue-touch-emit.sh for the sibling pattern this
# one is modeled on, adapted from "markdown step invokes a script" to
# "library function computes and passes the expected fields".
#
# Usage: workflows/scripts/validate-knowledge-search-emit.sh   (resolves the repo itself)

set -euo pipefail

SCRIPTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORE_LIB="$SCRIPTS_DIR/lib/knowledge_store.sh"
SEARCH_LIB="$SCRIPTS_DIR/lib/knowledge_search.sh"
MCP_LIB="$SCRIPTS_DIR/lib/knowledge_search_mcp.sh"

fail=0

# grep helper: the target strings are literal SOURCE TEXT being searched for
# (e.g. `"$query"` as it appears verbatim in knowledge_search.sh), never
# shell expansions — isolated in a function so the `shellcheck disable`
# directive can precede a plain statement (a directive can't precede an
# `elif` branch).
_search_lib_has_emit_call() {
  # shellcheck disable=SC2016
  grep -Fq 'ks__read_log_emit script search "$query"' "$SEARCH_LIB"
}

# --- 1. knowledge_store.sh: ks__read_log_emit still accepts additive fields --
if [ ! -f "$STORE_LIB" ]; then
  echo "FAIL  knowledge_store.sh is missing (expected at $STORE_LIB)"
  fail=1
elif ! grep -Fq 'ks__read_log_emit()' "$STORE_LIB"; then
  echo "FAIL  knowledge_store.sh ($STORE_LIB) no longer defines ks__read_log_emit — the read-log seam was removed"
  fail=1
elif ! grep -A30 -F 'ks__read_log_emit()' "$STORE_LIB" | grep -E 'for[[:space:]]+outcome_field[[:space:]]+in[[:space:]]+"\$@"' >/dev/null; then
  echo "FAIL  knowledge_store.sh's ks__read_log_emit no longer appends additive outcome fields (the 'for outcome_field in \"\$@\"' loop is missing) — wiring drifted"
  fail=1
else
  echo "ok    knowledge_store.sh's ks__read_log_emit still appends additive outcome fields"
fi

# --- 2. knowledge_search.sh: ks_search still computes + passes all six fields -
if [ ! -f "$SEARCH_LIB" ]; then
  echo "FAIL  knowledge_search.sh is missing (expected at $SEARCH_LIB)"
  fail=1
elif ! _search_lib_has_emit_call; then
  echo "FAIL  knowledge_search.sh ($SEARCH_LIB) no longer calls ks__read_log_emit for op=search — the outcome-field emit was removed from ks_search"
  fail=1
else
  # The call spans a couple of lines (a `\`-continued block), so scan a
  # window of lines AFTER the match for each of the six outcome-field
  # variables rather than requiring them on the same line.
  # shellcheck disable=SC2016  # the $query below is literal source text being grepped for, not an expansion
  block="$(grep -A3 -F 'ks__read_log_emit script search "$query"' "$SEARCH_LIB" || true)"
  missing=""
  for var in result_count top_score rg_fired mode wall_ms; do
    grep -Fq "\$$var" <<<"$block" || missing="$missing $var"
  done
  if [ -n "$missing" ]; then
    echo "FAIL  knowledge_search.sh's ks_search calls ks__read_log_emit but is missing outcome field(s):$missing — wiring drifted"
    fail=1
  else
    echo "ok    knowledge_search.sh's ks_search passes all six outcome fields (result_count, top_score, abstained, rg_fallback, mode, wall_ms) to ks__read_log_emit"
  fi
fi

# --- 3. knowledge_search_mcp.sh: the warm backend still shares ks_search's --
#        single call site (never a duplicate/parallel read-log emit) ---------
if [ -f "$MCP_LIB" ] && grep -Fq 'ks__read_log_emit' "$MCP_LIB"; then
  echo "FAIL  knowledge_search_mcp.sh ($MCP_LIB) defines its own ks__read_log_emit call — outcome fields must have ONE owner (knowledge_search.sh's ks_search); a second call site can drift out of sync"
  fail=1
else
  echo "ok    knowledge_search_mcp.sh has no separate read-log emit call (both backends share ks_search's single call site)"
fi

echo "---"
if [ "$fail" -ne 0 ]; then
  echo "validate-knowledge-search-emit: FAIL"
  exit 1
fi
echo "validate-knowledge-search-emit: OK"
