#!/usr/bin/env bash
#
# Tests for issue-marker-probe.sh — the corpus-first, gh-search-fallback
# exact body-marker probe (plan item "cache-search-routing", sibling of
# "cache-search-corpus" — issue-corpus.sh, tested by test_issue_corpus.sh).
# Zero network: overrides cache.sh's `_cache_gh` seam (mirroring
# test_cache_store.sh / test_issue_corpus.sh) to replay a canned REST
# fixture set, and overrides issue-marker-probe.sh's own
# `_issue_marker_probe_gh_cmd` seam to replay the live-fallback path without
# ever touching a real `gh`. Every store lives under a throwaway tmpdir —
# CACHE_STORE_ROOT and KNOWLEDGE_STORE_ROOT are both sandboxed.
#
# Coverage (mirrors the item's acceptance bullets 1-2):
#   1. Parity: the SAME marker query, on the SAME underlying fixture data,
#      returns byte-identical JSON whether served from the corpus (case 4)
#      or via the live gh-search fallback (case 3) -- proving "returns
#      matches identical to gh search" on a replay fixture set. The fixture
#      set includes a title-containing-"#N" trap issue (#2, whose TITLE is
#      literally the marker text) and a comment-containing-marker issue (#3,
#      whose only marker occurrence is in a COMMENT, not the body) -- both
#      must be structurally absent from the result on EITHER path, proving
#      the in:title reference-parsing trap and comment-leakage are avoided
#      by construction (this file never searches title or comments, on
#      either the corpus or the fallback code path).
#   2. Degradation: falls back to the live gh path cleanly (and identically)
#      when the corpus is absent (case 3, before any render exists) or
#      stale-beyond-limit (case 7, corpus files present but cache_dirty'd
#      stale) -- and propagates a live-fallback failure as rc 1 with no
#      fabricated output (case 8).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"
BOARD_LIB_DIR="$(cd "$LIB_DIR/../board/lib" && pwd)"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

REPO="Acme/marker-probe-test"
MARKER="Retro-for-epic: #7"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/issue-marker-probe-test-XXXXXX")"
CACHE_STORE_ROOT="$TMP/cache"
KNOWLEDGE_STORE_ROOT="$TMP/store"
FAKE_GH_LOG="$TMP/gh-calls.log"
mkdir -p "$CACHE_STORE_ROOT" "$KNOWLEDGE_STORE_ROOT"
export CACHE_STORE_ROOT KNOWLEDGE_STORE_ROOT

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# shellcheck source=scripts/board/lib/cache.sh
source "$BOARD_LIB_DIR/cache.sh"
# shellcheck source=scripts/lib/knowledge_store.sh
source "$LIB_DIR/knowledge_store.sh"
# shellcheck source=scripts/lib/issue-corpus.sh
source "$LIB_DIR/issue-corpus.sh"
# shellcheck source=scripts/lib/issue-marker-probe.sh
source "$LIB_DIR/issue-marker-probe.sh"

# ── fixture data: 4 issues on the fake REST snapshot ───────────────────────
# #1 the real marker-carrying issue (body match -- the one true positive).
# #2 the title-containing-"#N" trap: its TITLE is the marker text verbatim,
#    its body is not -- must NOT match on either code path.
# #3 the comment-leakage trap: a COMMENT carries the marker, its body does
#    not -- must NOT match on either code path.
# #4 a plain control with no marker anywhere.
PAGE='[
  {"number":1,"title":"Fix login bug","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"Fixes the flow.\n\nRetro-for-epic: #7\n","labels":[]},
  {"number":2,"title":"Retro-for-epic: #7","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"Unrelated body text, no marker.","labels":[]},
  {"number":3,"title":"Some issue","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"Nothing here.","labels":[]},
  {"number":4,"title":"Other","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"plain, no marker","labels":[]}
]'
# The one true positive, derived from the same fixture (never hand-duplicated)
# so the "ground truth" can never drift from the data both code paths read.
EXPECTED_MATCH="$(printf '%s' "$PAGE" | jq -c '[.[] | select(.number==1) | {number,title,body}]')"

_cache_gh() {
  case "$*" in
    *"issues?state=all"*"--paginate"*) printf '%s' "$PAGE"; return 0 ;;
    *"/comments")
      case "$*" in
        *"issues/3/comments") echo '[{"id":1,"user":{"login":"bob"},"created_at":"2026-07-01T01:00:00Z","body":"Retro-for-epic: #7"}]' ;;
        *) echo '[]' ;;
      esac
      return 0
      ;;
    *) return 1 ;;
  esac
}
# shellcheck disable=SC2317,SC2329

# Fake live-fallback seam: replays EXPECTED_MATCH for the real marker search,
# fails for anything else. Overridden AFTER sourcing issue-marker-probe.sh
# (source order matters for a function-redefinition seam, same as _cache_gh).
GH_FAIL=0
_issue_marker_probe_gh_cmd() {
  printf 'CALL: %s\n' "$*" >> "$FAKE_GH_LOG"
  if [ "$GH_FAIL" -eq 1 ]; then
    return 1
  fi
  case "$*" in
    *"--search"*"in:body"*) printf '%s' "$EXPECTED_MATCH"; return 0 ;;
    *) return 1 ;;
  esac
}
# shellcheck disable=SC2317,SC2329

# --- 0. never sources board.sh (static boundary check) -----------------------
grep -qE '^\s*(source|\.)\s+.*board\.sh' "$LIB_DIR/issue-marker-probe.sh" && fail "0: issue-marker-probe.sh must never source board.sh"
echo "PASS: 0 issue-marker-probe.sh never sources board.sh (static check)"

# --- 1. bare board number is rejected (no board.sh dependency) ---------------
set +e
out="$(issue_marker_probe "4" "$MARKER" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "1: a bare board number should be rejected with rc 2 (got $rc)"
case "$out" in
  *"owner/repo"*) : ;;
  *) fail "1: rejection message should explain the owner/repo requirement (got: $out)" ;;
esac
echo "PASS: 1 issue_marker_probe rejects a bare board number (this file never sources board.sh)"

# --- 2. empty marker is rejected (usage) -------------------------------------
set +e
out="$(issue_marker_probe "$REPO" "" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "2: an empty marker should be rejected with rc 2 (got $rc)"
case "$out" in
  *"usage"*) : ;;
  *) fail "2: rejection message should be a usage notice (got: $out)" ;;
esac
echo "PASS: 2 issue_marker_probe rejects an empty marker string"

# --- 3. no cache/corpus yet -> falls back to gh, output is the ground truth --
: > "$FAKE_GH_LOG"
out3="$(issue_marker_probe "$REPO" "$MARKER")"
[ -s "$FAKE_GH_LOG" ] || fail "3: expected the live gh fallback to be invoked with no corpus yet"
diff <(printf '%s' "$out3" | jq -Sc '.') <(printf '%s' "$EXPECTED_MATCH" | jq -Sc '.') >/dev/null \
  || fail "3: fallback output should equal the ground truth match (got: $out3)"
echo "PASS: 3 absent corpus falls back to gh cleanly, returning the expected match"

# --- 4. build the corpus, then re-probe: corpus path used, IDENTICAL output --
cache_refresh "$REPO" >/dev/null 2>&1
issue_corpus_render "$REPO" >/dev/null 2>&1
: > "$FAKE_GH_LOG"
out4="$(issue_marker_probe "$REPO" "$MARKER")"
[ ! -s "$FAKE_GH_LOG" ] || fail "4: a fresh/available corpus should answer the probe without any gh call (log: $(cat "$FAKE_GH_LOG"))"
diff <(printf '%s' "$out4" | jq -Sc '.') <(printf '%s' "$EXPECTED_MATCH" | jq -Sc '.') >/dev/null \
  || fail "4: corpus-path output should equal the ground truth match (got: $out4)"
diff <(printf '%s' "$out4" | jq -Sc '.') <(printf '%s' "$out3" | jq -Sc '.') >/dev/null \
  || fail "4: corpus-path output should be IDENTICAL to the gh-fallback output from case 3"
echo "PASS: 4 an available corpus answers the probe with zero gh calls, byte-identical to the gh-fallback result"

# --- 5. title-containing-"#N" trap: issue #2 never matches -------------------
printf '%s' "$out4" | jq -e '[.[] | select(.number==2)] | length == 0' >/dev/null \
  || fail "5: issue #2 (title literally the marker) must not match -- title is never searched"
echo "PASS: 5 the in:title reference-parsing trap is avoided by construction (title never searched)"

# --- 6. comment-leakage trap: issue #3 never matches -------------------------
printf '%s' "$out4" | jq -e '[.[] | select(.number==3)] | length == 0' >/dev/null \
  || fail "6: issue #3 (marker only in a comment) must not match -- comments are never searched"
echo "PASS: 6 a marker present only in a comment does not leak into a body-marker match"

# --- 7. stale-beyond-limit corpus (files present) still falls back to gh -----
cache_dirty "$REPO"
: > "$FAKE_GH_LOG"
out7="$(issue_marker_probe "$REPO" "$MARKER")"
[ -s "$FAKE_GH_LOG" ] || fail "7: a stale-beyond-limit corpus (cache_dirty'd) should still fall back to gh"
diff <(printf '%s' "$out7" | jq -Sc '.') <(printf '%s' "$EXPECTED_MATCH" | jq -Sc '.') >/dev/null \
  || fail "7: stale-corpus fallback output should equal the ground truth match (got: $out7)"
echo "PASS: 7 a stale-beyond-limit corpus (present but dirty) falls back to gh, not a partial/local answer"

# --- 8. live gh fallback failure propagates rc 1, no fabricated output -------
GH_FAIL=1
ERR_FILE="$TMP/case8.err"
set +e
out8="$(issue_marker_probe "$REPO" "$MARKER" 2>"$ERR_FILE")"
rc=$?
err8="$(cat "$ERR_FILE" 2>/dev/null)"
set -e
GH_FAIL=0
[ "$rc" -eq 1 ] || fail "8: a failed live gh fallback should return rc 1 (got $rc)"
[ -z "$out8" ] || fail "8: a failed live gh fallback must produce no stdout (got: $out8)"
case "$err8" in
  *"gh search failed"*) : ;;
  *) fail "8: expected a 'gh search failed' stderr notice (got: $err8)" ;;
esac
echo "PASS: 8 a failed live gh fallback (corpus stale/absent) returns rc 1 with no fabricated output"

echo "All issue-marker-probe.sh tests passed."
