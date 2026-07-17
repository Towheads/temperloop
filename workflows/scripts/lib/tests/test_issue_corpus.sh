#!/usr/bin/env bash
#
# Tests for issue-corpus.sh — the cache-store -> knowledge-store corpus
# renderer + ks_search reindex chain (plan item "cache-search-corpus").
# Zero network: overrides cache.sh's `_cache_gh` seam (mirroring
# board/tests/test_cache_store.sh) to replay canned REST payloads, and
# drives a FAKE `uvx` on PATH (mirroring test_knowledge_search.sh) so
# ks_search_reindex/ks_search never touch the real basic-memory CLI. Every
# store lives under a throwaway tmpdir -- CACHE_STORE_ROOT and
# KNOWLEDGE_STORE_ROOT are both sandboxed; this test never touches a real
# ~/.cache or knowledge store.
#
# Coverage (mirrors the item's acceptance bullets 1-3):
#   1. Render + staleness: a fresh render writes one doc per issue, carrying
#      title/labels/state/body/comments; a no-op re-render touches NO
#      files (mtime unchanged); bumping one issue's updated_at re-renders
#      only that issue's doc (mtime advances) and leaves the other issue's
#      doc untouched (mtime unchanged).
#   2. Reindex chain: issue_corpus_sync drives cache_refresh -> render ->
#      ks_search_reindex, and the fake-uvx log proves reindex was invoked
#      against the project bound to ks_root (the mechanical assertion this
#      item's acceptance calls for). A smoke ks_search query (against the
#      same mocked backend the rest of this repo's knowledge_search tests
#      use -- see test_knowledge_search.sh, which never hits a real model
#      either) proves the end-to-end return path: a seeded issue's rendered
#      doc_id comes back from ks_search. A LIVE semantic-relevance check
#      against the real basic-memory embedding model is a deploy-time
#      check, not something this offline suite can prove -- this test
#      proves the plumbing (render -> reindex -> search round-trip), not
#      real hybrid-search relevance.
#   3. Store-layout boundary: schema_version mismatch is refused loudly
#      (rc 2, no render) rather than guessed at; a bare board number is
#      rejected (this file never sources board.sh); every rendered doc
#      lands under ks_root (split-brain guard, proven by using ks_read to
#      fetch it back through the SAME seam ks_search binds to).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"
BOARD_LIB_DIR="$(cd "$LIB_DIR/../board/lib" && pwd)"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Fictitious owner/repo (never the real org -- mirrors test_cache_store.sh's
# "Acme/kernel-cache-test" convention).
REPO="Acme/issue-corpus-test"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/issue-corpus-test-XXXXXX")"
CACHE_STORE_ROOT="$TMP/cache"
KNOWLEDGE_STORE_ROOT="$TMP/store"
KNOWLEDGE_SEARCH_BM_HOME="$TMP/bm-home"
# Isolate the read-log (temperloop#229) under the throwaway tmpdir too — the
# ks_read/ks_search calls below go through ks__read_log_emit; without this
# override it would default to the real machine's $XDG_STATE_HOME/foundation/
# knowledge-reads.log.
KNOWLEDGE_READ_LOG="$TMP/knowledge-reads.log"
BIN="$TMP/bin"
FAKE_UVX_LOG="$TMP/uvx-calls.log"
mkdir -p "$CACHE_STORE_ROOT" "$KNOWLEDGE_STORE_ROOT" "$BIN"
export CACHE_STORE_ROOT KNOWLEDGE_STORE_ROOT KNOWLEDGE_SEARCH_BM_HOME KNOWLEDGE_READ_LOG FAKE_UVX_LOG
export KNOWLEDGE_SEARCH_BM_PROJECT="issue-corpus-test-project"

cleanup() {
  chmod -R u+w "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# ── fake `uvx` fixture (mirrors test_knowledge_search.sh's) ────────────────
cat > "$BIN/uvx" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_UVX_LOG:?}"
printf 'ARGS: %s\n' "$*" >> "$FAKE_UVX_LOG"
# Consume `[uvx flags...] basic-memory` — robust to new uvx flags (--python,
# --from); `basic-memory==<ver>` is a distinct string, never matched.
while [ $# -gt 0 ] && [ "$1" != "basic-memory" ]; do shift; done
shift || true
sub="${1:-}"; shift || true
case "$sub" in
  project)
    action="${1:-}"; shift || true
    if [ "$action" = "add" ]; then
      name="${1:-}"; proj_path="${2:-}"
      printf 'PROJECT_ADD name=%s path=%s\n' "$name" "$proj_path" >> "$FAKE_UVX_LOG"
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
      cat <<'JSON'
{"results":[{"title":"Hello World","type":"entity","score":1.5,"content":"body one","matched_chunk":"body one snippet","file_path":"issues/Acme-issue-corpus-test/1-hello-world.md","metadata":{},"entity_id":1}],"current_page":1,"page_size":10,"total":1,"has_more":false}
JSON
      exit 0
    fi
    ;;
esac
echo "fake-uvx: unhandled invocation: $*" >&2
exit 9
FAKE
chmod +x "$BIN/uvx"

# shellcheck source=scripts/board/lib/cache.sh
source "$BOARD_LIB_DIR/cache.sh"
# shellcheck source=scripts/lib/knowledge_store.sh
source "$LIB_DIR/knowledge_store.sh"
# shellcheck source=scripts/lib/knowledge_search.sh
source "$LIB_DIR/knowledge_search.sh"
# shellcheck source=scripts/lib/issue-corpus.sh
source "$LIB_DIR/issue-corpus.sh"

# ── fake `_cache_gh` fixture (mirrors test_cache_store.sh's) ───────────────
# MUST be defined AFTER sourcing cache.sh above -- cache.sh's own
# `_cache_gh() { gh "$@"; }` definition would otherwise clobber this
# override (source order matters for a function-redefinition seam).
PAGE='[
  {"number":1,"title":"Hello World","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"body one","labels":[{"name":"bug"}]},
  {"number":2,"title":"Second issue","state":"closed","updated_at":"2026-06-01T00:00:00Z","body":"body two","labels":[]}
]'
_cache_gh() {
  case "$*" in
    *"issues?state=all"*"--paginate"*) printf '%s' "$PAGE"; return 0 ;;
    *"/comments")
      case "$*" in
        *"issues/1/comments") echo '[{"id":1,"user":{"login":"alice"},"created_at":"2026-07-01T01:00:00Z","body":"a comment"}]' ;;
        *) echo '[]' ;;
      esac
      return 0
      ;;
    *) return 1 ;;
  esac
}
# shellcheck disable=SC2317,SC2329

DOC1="issues/Acme-issue-corpus-test/1-hello-world.md"
DOC2="issues/Acme-issue-corpus-test/2-second-issue.md"
doc1_path() { printf '%s/%s' "$KNOWLEDGE_STORE_ROOT" "$DOC1"; }
doc2_path() { printf '%s/%s' "$KNOWLEDGE_STORE_ROOT" "$DOC2"; }
# GNU (`-c %Y`) FIRST, BSD (`-f %m`) as the fallback — same ordering rationale
# as board.sh's _board_cached_read: on GNU stat, `-f` means --file-system, so
# `stat -f %m FILE` treats "%m" as a file operand (fails, rc 1) and prints the
# real file's multi-line FILESYSTEM-status block — whose Free block/inode
# counters drift with unrelated disk activity — and the `||` fallback then
# APPENDS the epoch to that. BSD-first therefore made every mtime equality
# comparison on Linux CI hostage to filesystem free-space churn (the
# merge-queue case-5 doc2 flake). BSD stat has no `-c`, errors without stdout
# output, and falls through cleanly, so GNU-first is safe on both.
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# --- 0. never sources board.sh (static boundary check) -----------------------
# Looks for an actual `source .../board.sh` (or `. .../board.sh`) line -- NOT
# a bare mention of "board.sh" in prose/comments, which this file's own
# header legitimately carries (explaining the boundary it maintains).
grep -qE '^\s*(source|\.)\s+.*board\.sh' "$LIB_DIR/issue-corpus.sh" && fail "0: issue-corpus.sh must never source board.sh"
echo "PASS: 0 issue-corpus.sh never sources board.sh (static check)"

# --- 1. bare board number is rejected (no board.sh dependency) ---------------
set +e
out="$(issue_corpus_render "4" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "1: a bare board number should be rejected with rc 2 (got $rc)"
case "$out" in
  *"owner/repo"*) : ;;
  *) fail "1: rejection message should explain the owner/repo requirement (got: $out)" ;;
esac
echo "PASS: 1 issue_corpus_render rejects a bare board number (this file never sources board.sh)"

# --- 2. no cache store yet -> rc 0, nothing rendered -------------------------
out="$(issue_corpus_render "$REPO" 2>&1)"
case "$out" in
  *"nothing to render"*) : ;;
  *) fail "2: expected a 'nothing to render' notice with no cache store yet (got: $out)" ;;
esac
[ ! -e "$(doc1_path)" ] || fail "2: no document should exist before any cache_refresh"
echo "PASS: 2 issue_corpus_render with no cache store yet is a rc-0 no-op"

# --- 3. fresh render: one doc per issue, frontmatter + body + comments -------
cache_refresh "$REPO" >/dev/null 2>&1
out="$(issue_corpus_render "$REPO" 2>&1)"
case "$out" in
  *"rendered 2, skipped 0"*) : ;;
  *) fail "3: expected 'rendered 2, skipped 0' (got: $out)" ;;
esac
[ -f "$(doc1_path)" ] || fail "3: doc for issue #1 not rendered"
[ -f "$(doc2_path)" ] || fail "3: doc for issue #2 not rendered"

content1="$(cat "$(doc1_path)")"
echo "$content1" | grep -q '^number: 1$' || fail "3: doc1 missing number field"
echo "$content1" | grep -q '^title: "Hello World"$' || fail "3: doc1 missing/wrong title field"
echo "$content1" | grep -q '^state: "open"$' || fail "3: doc1 missing/wrong state field"
echo "$content1" | grep -q '^labels: \["bug"\]$' || fail "3: doc1 missing/wrong labels field"
echo "$content1" | grep -q '^updated_at: "2026-07-01T00:00:00Z"$' || fail "3: doc1 missing/wrong updated_at field"
echo "$content1" | grep -q '^source: "Acme/issue-corpus-test#1"$' || fail "3: doc1 missing/wrong source field"
echo "$content1" | grep -q '^body one$' || fail "3: doc1 missing rendered body"
echo "$content1" | grep -q '## Comments' || fail "3: doc1 missing Comments section"
echo "$content1" | grep -q 'alice' || fail "3: doc1 comments missing commenter"
echo "$content1" | grep -q 'a comment' || fail "3: doc1 comments missing comment body"

content2="$(cat "$(doc2_path)")"
echo "$content2" | grep -q '^state: "closed"$' || fail "3: doc2 missing/wrong state field (closed issue)"
echo "$content2" | grep -qF '## Comments' && fail "3: doc2 should carry no Comments section (zero comments)"
echo "PASS: 3 fresh render writes one doc per issue carrying title/labels/state/body/comments"

# --- 4. mtime test: unchanged snapshot -> re-render touches NO files --------
m1_before="$(mtime_of "$(doc1_path)")"
m2_before="$(mtime_of "$(doc2_path)")"
sleep 1
out="$(issue_corpus_render "$REPO" 2>&1)"
case "$out" in
  *"rendered 0, skipped 2"*) : ;;
  *) fail "4: expected 'rendered 0, skipped 2' on an unchanged re-render (got: $out)" ;;
esac
m1_after="$(mtime_of "$(doc1_path)")"
m2_after="$(mtime_of "$(doc2_path)")"
[ "$m1_before" = "$m1_after" ] || fail "4: doc1 mtime changed on a no-op re-render"
[ "$m2_before" = "$m2_after" ] || fail "4: doc2 mtime changed on a no-op re-render"
echo "PASS: 4 an unchanged cache snapshot re-render touches zero files (mtime-stable)"

# --- 5. mtime test: bump ONE issue's updated_at -> only that doc re-renders --
PAGE='[
  {"number":1,"title":"Hello World","state":"open","updated_at":"2026-07-02T00:00:00Z","body":"body one UPDATED","labels":[{"name":"bug"}]},
  {"number":2,"title":"Second issue","state":"closed","updated_at":"2026-06-01T00:00:00Z","body":"body two","labels":[]}
]'
cache_dirty "$REPO"
cache_refresh "$REPO" >/dev/null 2>&1
sleep 1
out="$(issue_corpus_render "$REPO" 2>&1)"
case "$out" in
  *"rendered 1, skipped 1"*) : ;;
  *) fail "5: expected 'rendered 1, skipped 1' after bumping only issue #1 (got: $out)" ;;
esac
m1_after2="$(mtime_of "$(doc1_path)")"
m2_after2="$(mtime_of "$(doc2_path)")"
[ "$m1_after2" != "$m1_after" ] || fail "5: doc1 mtime should have advanced after its updated_at changed"
[ "$m2_after2" = "$m2_after" ] || fail "5: doc2 mtime should NOT have changed (its updated_at is unchanged)"
grep -q '^body one UPDATED$' "$(doc1_path)" || fail "5: doc1 content should reflect the updated body"
echo "PASS: 5 only the issue whose updated_at advanced re-renders; the other issue's doc is left untouched"

# --- 6. schema_version mismatch is refused, not guessed at -------------------
meta="$(cache_meta_file "$REPO")"
cp "$meta" "$meta.bak"
jq '.schema_version = 99' "$meta" > "$meta.tmp" && mv "$meta.tmp" "$meta"
set +e
out="$(issue_corpus_render "$REPO" 2>&1)"
rc=$?
set -e
mv "$meta.bak" "$meta"
[ "$rc" -eq 2 ] || fail "6: schema_version mismatch should return rc 2 (got $rc)"
case "$out" in
  *"schema_version mismatch"*) : ;;
  *) fail "6: expected a schema_version mismatch message (got: $out)" ;;
esac
echo "PASS: 6 an on-disk schema_version mismatch is refused loudly (rc 2), never guessed at"

# --- 7. split-brain guard: rendered docs live under ks_root, readable via ks_read
via_ks_read="$(ks_read "$DOC1")"
[ -n "$via_ks_read" ] || fail "7: ks_read could not read the rendered doc back"
echo "$via_ks_read" | grep -q '^number: 1$' || fail "7: ks_read content did not match the rendered doc"
echo "PASS: 7 rendered docs are readable back through ks_read (corpus lives inside ks_root, no side-channel path)"

# --- 8. reindex chain: issue_corpus_sync drives refresh -> render -> reindex -
rm -f "$FAKE_UVX_LOG"
PATH="$BIN:$PATH" issue_corpus_sync "$REPO" >/dev/null 2>&1
[ -f "$FAKE_UVX_LOG" ] || fail "8: issue_corpus_sync never invoked the (fake) uvx subprocess"
grep -q "PROJECT_ADD name=$KNOWLEDGE_SEARCH_BM_PROJECT path=$KNOWLEDGE_STORE_ROOT\$" "$FAKE_UVX_LOG" \
  || fail "8: reindex chain's project registration was not bound to ks_root (KNOWLEDGE_STORE_ROOT); log:\n$(cat "$FAKE_UVX_LOG")"
grep -q '^REINDEX args=--project '"$KNOWLEDGE_SEARCH_BM_PROJECT"'$' "$FAKE_UVX_LOG" \
  || fail "8: expected an incremental (no --full) reindex call bound to the project; log:\n$(cat "$FAKE_UVX_LOG")"
echo "PASS: 8 issue_corpus_sync chains cache_refresh -> issue_corpus_render -> ks_search_reindex, bound to ks_root"

# --- 8b. --full is forwarded to ks_search_reindex ----------------------------
rm -f "$FAKE_UVX_LOG"
PATH="$BIN:$PATH" issue_corpus_sync "$REPO" --full >/dev/null 2>&1
grep -q '^REINDEX args=--full --project '"$KNOWLEDGE_SEARCH_BM_PROJECT"'$' "$FAKE_UVX_LOG" \
  || fail "8b: --full should be forwarded to ks_search_reindex; log:\n$(cat "$FAKE_UVX_LOG")"
echo "PASS: 8b issue_corpus_sync --full forwards --full to ks_search_reindex"

# --- 9. offline smoke: a seeded issue is returned by a ks_search query -------
# This drives the SAME mocked-uvx harness every other knowledge_search test in
# this repo uses (see test_knowledge_search.sh) -- it proves the mechanical
# round-trip (render -> reindex -> search returns the rendered doc_id), not
# real embedding-based relevance. A live semantic-relevance smoke against the
# real basic-memory model is a deploy-time check outside this offline suite's
# reach (no network/model access in CI).
out="$(PATH="$BIN:$PATH" ks_search "hello world")"
doc_id="$(printf '%s' "$out" | jq -r '.doc_id')"
[ "$doc_id" = "$DOC1" ] || fail "9: ks_search should return the seeded issue's rendered doc_id (got: $doc_id)"
echo "PASS: 9 a seeded issue's rendered corpus doc is returned by a ks_search query (offline mechanical smoke)"

echo "ALL PASS: test_issue_corpus.sh (render + staleness + reindex chain + store-layout boundary)"
