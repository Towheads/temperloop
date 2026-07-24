#!/usr/bin/env bash
#
# Tests for workflows/scripts/lib/knowledge_search.sh — the knowledge_search
# concept-level retrieval surface (foundation #776, Epic A #762) and its
# basic-memory backend. Zero network, zero real embeddings: every case drives
# a FAKE `uvx` binary on PATH (the pattern board/tests/test_capture.sh uses
# for `gh`), never the real basic-memory CLI. All state lives under a
# throwaway tmpdir; never touches a real vault, XDG dir, or Travis's HOME.
#
# Covers: dispatch to an unregistered backend (exit 2), empty-query usage
# error (exit 2), posture assembly (config.json carries every no-mutation
# key from the spike verdict, BEFORE the first index; the belt-and-suspenders
# env var reaches the subprocess), corpus-root binding (project registration
# always uses ks_root, no independent path knob), a successful hybrid-search
# round-trip reshaped into JSONL, the backend-error path (subprocess exits
# non-zero / emits unparseable output -> exit 4), the reindex entry point,
# and the legible-degradation path (no `uvx` on PATH -> exit 3, "skipped —"
# on stderr, nothing on stdout, never a silent empty result).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"
STORE_LIB="$LIB_DIR/knowledge_store.sh"
SEARCH_LIB="$LIB_DIR/knowledge_search.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ks-search-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ROOT="$TMP/store"          # the knowledge_store corpus (ks_root)
BM_HOME="$TMP/bm-home"     # isolated basic-memory HOME (point 6)
BIN="$TMP/bin"             # fake-uvx PATH dir
FAKE_UVX_LOG="$TMP/uvx-calls.log"
mkdir -p "$ROOT" "$BIN"

# ── the fake `uvx` fixture ───────────────────────────────────────────────
# Mimics `uvx --from basic-memory==<ver> basic-memory <subcmd> ...` closely
# enough to drive knowledge_search.sh's dispatch/posture/parsing logic
# without ever touching the network or a real embedding model. Logs every
# invocation's argv + the HOME/BASIC_MEMORY_DISABLE_PERMALINKS env it saw,
# so the test can assert posture (points 1 and 6) after the fact.
# FAKE_UVX_MODE selects canned behavior for `tool search-notes`:
#   ok (default) -> canned 2-result hybrid JSON on stdout
#   search_fail  -> exit 1, message on stderr (subprocess-error path)
#   bad_json     -> exit 0, non-JSON on stdout (parse-error path)
cat > "$BIN/uvx" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_UVX_LOG:?}"
{
  printf 'ARGS: %s\n' "$*"
  printf 'HOME=%s\n' "${HOME:-<unset>}"
  printf 'BASIC_MEMORY_DISABLE_PERMALINKS=%s\n' "${BASIC_MEMORY_DISABLE_PERMALINKS:-<unset>}"
} >> "$FAKE_UVX_LOG"

# argv shape from _ks_bm_run: [uvx flags...] basic-memory <sub> ...
# Consume everything up to and including the `basic-memory` command token so
# a new uvx flag (--python, --from) never breaks the fake. (`basic-memory==<ver>`
# is a distinct string, so the --from value never terminates the loop early.)
while [ $# -gt 0 ] && [ "$1" != "basic-memory" ]; do shift; done
shift || true
sub="${1:-}"; shift || true

case "$sub" in
  project)
    action="${1:-}"; shift || true
    if [ "$action" = "add" ]; then
      name="${1:-}"; path="${2:-}"
      printf 'PROJECT_ADD name=%s path=%s\n' "$name" "$path" >> "$FAKE_UVX_LOG"
      if [ "${FAKE_UVX_MODE:-ok}" = "project_add_fail" ]; then
        echo "Error adding project: simulated registration failure detail" >&2
        exit 1
      fi
      # register_then_ok (#996 lazy-on-miss cold path): registration drops a
      # marker so a subsequent search-notes succeeds where the pre-register one
      # failed (project-not-found → register → retry).
      [ "${FAKE_UVX_MODE:-ok}" = "register_then_ok" ] && : > "${FAKE_UVX_LOG}.registered"
      echo "Project '$name' added successfully"
      exit 0
    fi
    ;;
  reindex)
    printf 'REINDEX args=%s\n' "$*" >> "$FAKE_UVX_LOG"
    echo "Reindex complete!"
    exit 0
    ;;
  tool)
    if [ "${1:-}" = "search-notes" ]; then
      shift
      printf 'SEARCH args=%s\n' "$*" >> "$FAKE_UVX_LOG"
      case "${FAKE_UVX_MODE:-ok}" in
        search_fail|project_add_fail)
          # project_add_fail must also MISS the search: under #996's lazy-on-miss
          # flow, `project add` is only attempted after a search miss, so a
          # registration-failure test needs the search to fail first.
          echo "fake-uvx: simulated backend crash / miss" >&2
          exit 1
          ;;
        bad_json)
          echo "this is not json"
          exit 0
          ;;
        empty_results)
          # A zero-match query: basic-memory returns a non-empty {"results":[]}
          # ENVELOPE (exit 0), NOT empty stdout — the load-bearing #996 contract.
          echo '{"results":[],"current_page":1,"page_size":10,"total":0,"has_more":false}'
          exit 0
          ;;
        register_then_ok)
          # Fail until the project has been registered (marker present), then
          # return results — the #996 lazy-on-miss cold/reset path.
          if [ ! -f "${FAKE_UVX_LOG}.registered" ]; then
            echo "fake-uvx: project not registered (register_then_ok, pre-registration)" >&2
            exit 1
          fi
          cat <<'JSON'
{"results":[{"title":"Foo","type":"entity","score":1.23,"content":"c1 full text","matched_chunk":"c1 snippet","file_path":"Decisions/foo.md","metadata":{},"entity_id":1},{"title":"Bar","type":"entity","score":0.9,"content":"c2 full text","matched_chunk":"c2 snippet","file_path":"Decisions/bar.md","metadata":{},"entity_id":2}],"current_page":1,"page_size":10,"total":0,"has_more":false}
JSON
          exit 0
          ;;
        *)
          cat <<'JSON'
{"results":[{"title":"Foo","type":"entity","score":1.23,"content":"c1 full text","matched_chunk":"c1 snippet","file_path":"Decisions/foo.md","metadata":{},"entity_id":1},{"title":"Bar","type":"entity","score":0.9,"content":"c2 full text","matched_chunk":"c2 snippet","file_path":"Decisions/bar.md","metadata":{},"entity_id":2}],"current_page":1,"page_size":10,"total":0,"has_more":false}
JSON
          exit 0
          ;;
      esac
    fi
    ;;
esac
echo "fake-uvx: unhandled invocation: $*" >&2
exit 9
FAKE
chmod +x "$BIN/uvx"

# ── shared env for every case below ─────────────────────────────────────
export KNOWLEDGE_STORE_ROOT="$ROOT"
export KNOWLEDGE_SEARCH_BM_HOME="$BM_HOME"
export KNOWLEDGE_SEARCH_BM_PROJECT="test-project"
export FAKE_UVX_LOG
# Isolate the read-log (temperloop#229) under the throwaway tmpdir too — every
# ks_search call below goes through ks__read_log_emit; without this override
# it would default to the real machine's $XDG_STATE_HOME/foundation/
# knowledge-reads.log.
export KNOWLEDGE_READ_LOG="$TMP/knowledge-reads.log"

# shellcheck source=/dev/null
source "$STORE_LIB"
# shellcheck source=/dev/null
source "$SEARCH_LIB"

# --- 1. empty query -> exit 2, no subprocess call ----------------------------
rm -f "$FAKE_UVX_LOG"
set +e
out="$(PATH="$BIN:$PATH" ks_search "" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "1: empty query should exit 2 (got $rc)"
[ ! -e "$FAKE_UVX_LOG" ] || fail "1: empty query must not reach the backend subprocess"
echo "PASS: 1 ks_search with an empty query exits 2 without touching the backend"

# --- 2. unregistered backend -> dispatch error, exit 2 ------------------------
set +e
out="$(KNOWLEDGE_SEARCH_BACKEND="does-not-exist" PATH="$BIN:$PATH" ks_search "hello" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "2: unknown backend should exit 2 (got $rc)"
case "$out" in
  *does-not-exist*) : ;;
  *) fail "2: error message should name the unknown backend (got: $out)" ;;
esac
echo "PASS: 2 selecting an unimplemented search backend fails dispatch with exit 2"

# --- 3. degradation path: no uvx on PATH -> exit 3, skipped notice, no stdout -
EMPTY_BIN="$TMP/empty-bin"
mkdir -p "$EMPTY_BIN"
set +e
out="$(PATH="$EMPTY_BIN" ks_search "hello" 2>/dev/null)"
rc=$?
err="$(PATH="$EMPTY_BIN" ks_search "hello" 2>&1 1>/dev/null)"
set -e
[ "$rc" -eq 3 ] || fail "3: missing uvx should exit 3 (got $rc)"
[ -z "$out" ] || fail "3: missing uvx must print NOTHING to stdout (got: $out)"
case "$err" in
  "skipped — knowledge_search unavailable"*) : ;;
  *) fail "3: stderr must begin with the 'skipped —' notice (got: $err)" ;;
esac
echo "PASS: 3 ks_search with no uvx on PATH degrades legibly (exit 3, skipped notice, empty stdout)"

# --- 3b. ks_search_available mirrors the same probe --------------------------
set +e
PATH="$EMPTY_BIN" ks_search_available >/dev/null 2>/dev/null
rc=$?
PATH="$BIN:$PATH" ks_search_available >/dev/null 2>/dev/null
rc_ok=$?
set -e
[ "$rc" -eq 3 ] || fail "3b: ks_search_available should exit 3 when uvx is missing (got $rc)"
[ "$rc_ok" -eq 0 ] || fail "3b: ks_search_available should exit 0 when uvx is present (got $rc_ok)"
echo "PASS: 3b ks_search_available exit-code probe matches ks_search's own gate (3 missing / 0 present)"

# --- 4. successful hybrid search -> JSONL reshape, ranked order preserved ----
rm -rf "$BM_HOME"
rm -f "$FAKE_UVX_LOG" "$FAKE_UVX_LOG.registered"
out="$(PATH="$BIN:$PATH" FAKE_UVX_MODE=ok ks_search "orchard" --limit 5)" || fail "4: ks_search should succeed"
lines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
[ "$lines" -eq 2 ] || fail "4: expected 2 JSONL result lines (got $lines): $out"
line1="$(printf '%s\n' "$out" | sed -n '1p')"
line2="$(printf '%s\n' "$out" | sed -n '2p')"
doc1="$(printf '%s' "$line1" | jq -r '.doc_id')"
score1="$(printf '%s' "$line1" | jq -r '.score')"
snippet1="$(printf '%s' "$line1" | jq -r '.snippet')"
doc2="$(printf '%s' "$line2" | jq -r '.doc_id')"
[ "$doc1" = "Decisions/foo.md" ] || fail "4: first result doc_id wrong (got $doc1)"
[ "$score1" = "1.23" ] || fail "4: first result score wrong (got $score1)"
[ "$snippet1" = "c1 snippet" ] || fail "4: first result snippet wrong (got $snippet1)"
[ "$doc2" = "Decisions/bar.md" ] || fail "4: second result doc_id wrong (got $doc2) -- ranked order not preserved"
echo "PASS: 4 ks_search reshapes basic-memory's hybrid-search JSON into ranked JSONL"

# --- 4b. warm path issues ONE subprocess: no per-query project add (#996) -----
# The warm/ok path (project already registered) must NOT call `project add` —
# the ~1.9s re-register #996 drops — and must issue exactly one search-notes.
if grep -q '^PROJECT_ADD ' "$FAKE_UVX_LOG"; then
  fail "4b: warm path must NOT call project add (#996); log:\n$(cat "$FAKE_UVX_LOG")"
fi
warm_search_calls="$(grep -c '^SEARCH ' "$FAKE_UVX_LOG" || true)"
[ "$warm_search_calls" -eq 1 ] \
  || fail "4b: warm path should issue exactly ONE search-notes (got $warm_search_calls); log:\n$(cat "$FAKE_UVX_LOG")"
echo "PASS: 4b warm path issues one subprocess — no per-query project add (#996)"

# --- 4c. warm no-match: exit 0 + empty stdout, still NO re-register (#996) -----
# The load-bearing #996 correctness contract: bm returns a non-empty
# {"results":[]} envelope for a zero-match query, so `[ -z "$raw" ]` is false →
# NOT a miss → no re-register, and the empty envelope reshapes to zero output
# lines + exit 0 (NOT a backend error). If this ever broke, a no-match would
# both slow to a needless register+retry AND wrongly report exit 4.
rm -rf "$BM_HOME"; rm -f "$FAKE_UVX_LOG" "$FAKE_UVX_LOG.registered"
out4c="$(PATH="$BIN:$PATH" FAKE_UVX_MODE=empty_results ks_search "no-such-term" --limit 5)" \
  || fail "4c: a warm no-match must exit 0 (empty {\"results\":[]} envelope is not a failure)"
[ -z "$out4c" ] || fail "4c: a warm no-match must print nothing to stdout (got: $out4c)"
if grep -q '^PROJECT_ADD ' "$FAKE_UVX_LOG"; then
  fail "4c: a warm no-match must NOT re-register (#996); log:\n$(cat "$FAKE_UVX_LOG")"
fi
nomatch_search="$(grep -c '^SEARCH ' "$FAKE_UVX_LOG" || true)"
[ "$nomatch_search" -eq 1 ] \
  || fail "4c: warm no-match should issue exactly ONE search (got $nomatch_search); log:\n$(cat "$FAKE_UVX_LOG")"
echo "PASS: 4c warm no-match → exit 0, empty stdout, no re-register (#996 empty-envelope contract)"

# --- 5. cold/reset path: lazy register-on-miss, bound to ks_root, then retry --
# When the first search misses (project not registered on first use, or a
# `basic-memory reset` dropped the DB while config still lists it), ks_search
# registers (bound to ks_root — the corpus-root binding still holds, now on the
# cold path) and retries the search ONCE.
rm -rf "$BM_HOME"
rm -f "$FAKE_UVX_LOG" "$FAKE_UVX_LOG.registered"
out5="$(PATH="$BIN:$PATH" FAKE_UVX_MODE=register_then_ok ks_search "orchard" --limit 5)" \
  || fail "5: cold-path ks_search should recover via register+retry"
[ "$(printf '%s\n' "$out5" | wc -l | tr -d ' ')" -eq 2 ] \
  || fail "5: cold-path search should return 2 results after register+retry; got: $out5"
grep -q "PROJECT_ADD name=test-project path=$ROOT\$" "$FAKE_UVX_LOG" \
  || fail "5: cold-path register must bind project to ROOT ($ROOT); log:\n$(cat "$FAKE_UVX_LOG")"
cold_add_calls="$(grep -c '^PROJECT_ADD ' "$FAKE_UVX_LOG" || true)"
cold_search_calls="$(grep -c '^SEARCH ' "$FAKE_UVX_LOG" || true)"
[ "$cold_add_calls" -eq 1 ] \
  || fail "5: cold path should register exactly once (got $cold_add_calls); log:\n$(cat "$FAKE_UVX_LOG")"
[ "$cold_search_calls" -eq 2 ] \
  || fail "5: cold path should search twice — miss then retry (got $cold_search_calls); log:\n$(cat "$FAKE_UVX_LOG")"
echo "PASS: 5 cold/reset path lazily registers (bound to ks_root) and retries the search once (#996)"

# --- 6. posture assembly: config.json carries every no-mutation key ----------
CONFIG="$BM_HOME/.basic-memory/config.json"
[ -f "$CONFIG" ] || fail "6: expected config.json to exist at $CONFIG after a search"
got_disable_permalinks="$(jq -r '.disable_permalinks' "$CONFIG")"
got_ensure_frontmatter="$(jq -r '.ensure_frontmatter_on_sync' "$CONFIG")"
got_format_on_save="$(jq -r '.format_on_save' "$CONFIG")"
got_update_permalinks="$(jq -r '.update_permalinks_on_move' "$CONFIG")"
got_kebab="$(jq -r '.kebab_filenames' "$CONFIG")"
got_sync_changes="$(jq -r '.sync_changes' "$CONFIG")"
got_auto_update="$(jq -r '.auto_update' "$CONFIG")"
got_model="$(jq -r '.semantic_embedding_model' "$CONFIG")"
got_cache_dir="$(jq -r '.semantic_embedding_cache_dir' "$CONFIG")"
got_projects_key="$(jq -r 'has("projects")' "$CONFIG")"
[ "$got_disable_permalinks" = "true" ]  || fail "6 point1: disable_permalinks should be true (got $got_disable_permalinks)"
[ "$got_ensure_frontmatter" = "false" ] || fail "6 point2: ensure_frontmatter_on_sync should be false (got $got_ensure_frontmatter)"
[ "$got_format_on_save" = "false" ]     || fail "6 point2: format_on_save should be false (got $got_format_on_save)"
[ "$got_update_permalinks" = "false" ]  || fail "6 point2: update_permalinks_on_move should be false (got $got_update_permalinks)"
[ "$got_kebab" = "false" ]              || fail "6 point2: kebab_filenames should be false (got $got_kebab)"
[ "$got_sync_changes" = "false" ]       || fail "6 point3: sync_changes should be false (got $got_sync_changes)"
[ "$got_auto_update" = "false" ]        || fail "6 point5: auto_update should be false (got $got_auto_update)"
[ "$got_model" = "bge-small-en-v1.5" ]  || fail "6 point7: semantic_embedding_model wrong (got $got_model)"
case "$got_cache_dir" in
  "$BM_HOME"/*) : ;;
  *) fail "6 point6: semantic_embedding_cache_dir should live under the isolated BM home (got $got_cache_dir)" ;;
esac
[ "$got_projects_key" = "false" ] || fail "6 point9: config.json must not carry a hand-written 'projects' map (registration is CLI-only)"
echo "PASS: 6 config.json carries the full no-mutation posture set (points 1,2,3,5,6,7,9), written before the first index"

# --- 6b. .bmignore: upstream base set written, no store-specific extras by default (F#946 seam) ---
IGN="$BM_HOME/.basic-memory/.bmignore"
[ -f "$IGN" ] || fail "6b: expected .bmignore to exist at $IGN after a search"
grep -qxF '.obsidian'   "$IGN" || fail "6b: base set missing .obsidian"
grep -qxF 'node_modules' "$IGN" || fail "6b: base set missing node_modules"
grep -qxF 'config.json' "$IGN" || fail "6b: base set missing config.json"
grep -qxF '_inbox' "$IGN" && fail "6b: _inbox must NOT be present by default (KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES empty for a stranger install)"
echo "PASS: 6b .bmignore carries the upstream base set; overlay seam empty by default (no _inbox)"

# --- 6c. EXTRA_IGNORES seam appends store-specific bare segments (the overlay path) ---
rm -f "$IGN"
KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES="_inbox scratch" _ks_bm_ensure_ignore || fail "6c: _ks_bm_ensure_ignore failed"
grep -qxF '.obsidian' "$IGN" || fail "6c: base set still present alongside extras"
grep -qxF '_inbox'    "$IGN" || fail "6c: _inbox extra not appended"
grep -qxF 'scratch'   "$IGN" || fail "6c: scratch extra not appended"
echo "PASS: 6c KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES appends store-specific bare segments (foundation sets _inbox)"

# --- 6d. idempotent: an existing .bmignore is never clobbered (write-only-if-absent) ---
KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES="should-not-appear" _ks_bm_ensure_ignore || fail "6d: repeat call failed"
grep -qxF '_inbox' "$IGN"          || fail "6d: existing .bmignore must be preserved"
grep -qxF 'should-not-appear' "$IGN" && fail "6d: must NOT append to a pre-existing .bmignore (write-only-if-absent)"
echo "PASS: 6d .bmignore is write-only-if-absent (idempotent, never clobbers a prior run's file)"

# --- 7. env belt-and-suspenders (point 1) + isolated HOME (point 6) reach the subprocess -
grep -q "BASIC_MEMORY_DISABLE_PERMALINKS=true" "$FAKE_UVX_LOG" \
  || fail "7: subprocess never saw BASIC_MEMORY_DISABLE_PERMALINKS=true"
grep -q "HOME=$BM_HOME\$" "$FAKE_UVX_LOG" \
  || fail "7: subprocess HOME was not pinned to the isolated basic-memory home ($BM_HOME)"
echo "PASS: 7 the subprocess env carries the belt-and-suspenders disable-permalinks flag and the isolated HOME"

# --- 8. never invokes the mcp subcommand (point 4) ---------------------------
! grep -qE '^ARGS:.* mcp( |$)' "$FAKE_UVX_LOG" || fail "8: found a 'basic-memory mcp' invocation -- adapter must be CLI-only"
echo "PASS: 8 no call in this test run ever invoked 'basic-memory mcp' (sidesteps upstream #1017)"

# --- 9. version + interpreter pins reach every invocation (point 5) -----------
total_calls="$(grep -c '^ARGS:' "$FAKE_UVX_LOG")"
pinned_calls="$(grep -c "^ARGS: --python $KNOWLEDGE_SEARCH_BM_PYTHON --from basic-memory==0.22.1 basic-memory" "$FAKE_UVX_LOG")"
[ "$total_calls" -gt 0 ] || fail "9: expected at least one subprocess call in the log"
[ "$total_calls" -eq "$pinned_calls" ] || fail "9: not every call carried both pins (total=$total_calls pinned=$pinned_calls; expected --python $KNOWLEDGE_SEARCH_BM_PYTHON --from basic-memory==0.22.1)"
echo "PASS: 9 every subprocess invocation carries the version pin AND the interpreter pin (point 5 + K#368)"

# --- 10. backend error: subprocess exits non-zero -> exit 4 -------------------
set +e
out="$(PATH="$BIN:$PATH" FAKE_UVX_MODE=search_fail ks_search "anything" 2>/tmp/ks-search-test-err.$$)"
rc=$?
err="$(cat "/tmp/ks-search-test-err.$$")"
rm -f "/tmp/ks-search-test-err.$$"
set -e
[ "$rc" -eq 4 ] || fail "10: a failing subprocess should propagate exit 4 (got $rc)"
[ -z "$out" ] || fail "10: a failing subprocess must print nothing to stdout (got: $out)"
[ -n "$err" ] || fail "10: a failing subprocess should leave a message on stderr"
echo "PASS: 10 a failing basic-memory subprocess call returns exit 4 with nothing on stdout"

# --- 10b. registration failure surfaces the subprocess's own error (K#368) ----
set +e
out="$(PATH="$BIN:$PATH" FAKE_UVX_MODE=project_add_fail ks_search "anything" 2>/tmp/ks-search-test-err10b.$$)"
rc=$?
err="$(cat "/tmp/ks-search-test-err10b.$$")"
rm -f "/tmp/ks-search-test-err10b.$$"
set -e
[ "$rc" -eq 4 ] || fail "10b: a failing project registration should exit 4 (got $rc)"
[ -z "$out" ] || fail "10b: a failing registration must print nothing to stdout (got: $out)"
case "$err" in
  *"simulated registration failure detail"*) : ;;
  *) fail "10b: stderr must surface the subprocess's own error, not only the adapter's opaque message (got: $err)" ;;
esac
case "$err" in
  *"project registration failed"*) : ;;
  *) fail "10b: stderr must still carry the adapter's registration-failed message (got: $err)" ;;
esac
echo "PASS: 10b a failing project registration surfaces the subprocess's own error alongside exit 4"

# --- 11. backend error: unparseable output -> exit 4 --------------------------
set +e
out="$(PATH="$BIN:$PATH" FAKE_UVX_MODE=bad_json ks_search "anything" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "11: unparseable backend output should exit 4 (got $rc)"
[ -z "$out" ] || fail "11: unparseable backend output must print nothing to stdout (got: $out)"
echo "PASS: 11 unparseable basic-memory output returns exit 4 with nothing on stdout"

# --- 12. reindex entry point: incremental (default) and --full ----------------
rm -f "$FAKE_UVX_LOG"
PATH="$BIN:$PATH" FAKE_UVX_MODE=ok ks_search_reindex >/dev/null || fail "12: incremental reindex should succeed"
grep -q '^REINDEX args=--project test-project$' "$FAKE_UVX_LOG" \
  || fail "12: incremental reindex should call reindex WITHOUT --full (log:\n$(cat "$FAKE_UVX_LOG"))"
rm -f "$FAKE_UVX_LOG"
PATH="$BIN:$PATH" FAKE_UVX_MODE=ok ks_search_reindex --full >/dev/null || fail "12b: --full reindex should succeed"
grep -q '^REINDEX args=--full --project test-project$' "$FAKE_UVX_LOG" \
  || fail "12b: --full reindex should pass --full through (log:\n$(cat "$FAKE_UVX_LOG"))"
echo "PASS: 12 ks_search_reindex drives both incremental (default) and --full rebuilds"

# --- 13. reindex degrades the same way as search when uvx is missing ----------
set +e
out="$(PATH="$EMPTY_BIN" ks_search_reindex 2>/tmp/ks-search-test-err2.$$)"
rc=$?
err="$(cat /tmp/ks-search-test-err2.$$)"
rm -f /tmp/ks-search-test-err2.$$
set -e
[ "$rc" -eq 3 ] || fail "13: reindex with no uvx should exit 3 (got $rc)"
[ -z "$out" ] || fail "13: reindex with no uvx must print nothing to stdout (got: $out)"
case "$err" in
  "skipped — knowledge_search unavailable"*) : ;;
  *) fail "13: reindex stderr must begin with the 'skipped —' notice (got: $err)" ;;
esac
echo "PASS: 13 ks_search_reindex degrades legibly the same way ks_search does (exit 3, skipped notice)"

echo "ALL PASS: knowledge_search.sh (interface + basic-memory backend, mocked subprocess)"
