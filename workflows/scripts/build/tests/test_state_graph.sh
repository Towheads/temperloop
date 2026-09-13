#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/state-graph.sh — the derived state
# graph's core builder (temperloop#1910, ADR 0033). ONE fixture system: this
# test `source`s state-graph.sh (whose source-guard skips the CLI dispatch),
# which in turn sources board.sh — and overrides the SAME `_board_gh` seam
# the board replay tests use (no second mock layer, no PATH shim, zero
# network), plus this file's own `_sg_git` seam for `git worktree list`.
# Fixtures are entirely synthetic: no real host names, session ids, or paths.
#
# Covers (sixteen ok/absent/error/stale cases, four per source):
#   - board:        ok (valid fnd:status:* + a claimed_by edge, session id
#                    normalized via jk_session8), absent (zero open issues),
#                    error (a status not in the ontology registry), stale
#   - board_edges:  ok (sub_issue_of + blocked_by from board_sub_issues /
#                    board_blocked_by_open), absent (no edges found), error
#                    (cascades from an upstream board error — board.sh's own
#                    accessors are fail-open by design, see state-graph.sh's
#                    comment), stale
#   - pr_list:      ok (a PR node + a closes edge parsed from a bare
#                    `Closes #N` line — a backticked / mid-sentence / same-
#                    line-trailer mention is excluded), absent (no open PRs),
#                    error (gh pr list fails), stale
#   - worktrees:    ok (a linked `<repo>.wt/<slug>` worktree), absent (no
#                    linked worktrees), error (git itself fails), stale
# Plus: the snapshot goes through lib/cache.sh (repo-keyed dir, meta.json,
# atomic write); `clean --board N` removes only that one repo's snapshot;
# `bench --scale N` reports an N-scaled synthetic node/edge count and a
# build_ms; the reader table is structurally extensible (state-graph-build-
# local appends three more sources without editing the assembly loop).
#
# The seams are redefined mid-file per case (the library calls them
# indirectly), so shellcheck's "never invoked"/"unreachable" checks are false
# positives — disabled file-wide like the sibling board replay tests.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the script under test. Its source-guard ([ BASH_SOURCE = $0 ]) skips
# the CLI dispatch, exposing cmd_*/_sg_* and the shared _board_gh seam.
# shellcheck source=workflows/scripts/build/state-graph.sh
source "$HERE/../state-graph.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Host-local sources (state-graph-build-local, temperloop#1918: plan_notes /
# journal / tmux) must never read this RUNNER's real knowledge store,
# transcript root, or tmux server — this file's own four-source suite (and
# its exact node/edge counts, e.g. the bench assertions below) stays
# deterministic regardless of what plan notes, journals, or tmux windows
# happen to exist on the host actually running the test. Isolated exactly
# like the BOARDS_CONF_* hermetic-env pair above; test_state_graph_local.sh
# is the dedicated suite for these three sources' own behavior.
export KNOWLEDGE_STORE_ROOT="$TMP/no-such-knowledge-store"
export SPEND_TRANSCRIPT_ROOT="$TMP/no-such-transcripts"
_sg_tmux() { return 1; }

# Every test gets its own cache root so cases never see each other's state.
fresh_cache() { export CACHE_STORE_ROOT="$TMP/cache-$1"; }

BOARD=4          # Towheads/foundation, per board.sh's built-in map
REPO="Towheads/foundation"

# Confirm the shared fixture system is live.
declare -F _board_gh >/dev/null || fail "board.sh not sourced — shared fixture system missing"
echo "PASS: state-graph.sh sources board.sh — one shared fixture system (_board_gh in scope)"

# =============================================================================
# source: board (Issue nodes, fnd:status:* state, claimed_by edges)
# =============================================================================

# --- board: ok ---------------------------------------------------------------
# A valid fnd:status:* label plus a claim stamp; the claimed_by edge's session
# id must be normalized through jk_session8 (the join-key loader), never
# hand-rolled — an already-8-hex-char stamp (board_own_stamp's own truncated
# form) falls back to the loader's lowercase OUTPUT shape.
_board_gh() {
  case "$1 $2" in
    "issue list")
      cat <<'JSON'
[{"number":10,"title":"x","labels":[{"name":"fnd:status:ready"},{"name":"fnd:host/session:mini-1:ABCD1234"}]}]
JSON
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "board ok status (got: $out)"
[ "$(jq -r '.nodes[0].status' <<<"$out")" = "fnd:status:ready" ] || fail "board ok status token (got: $out)"
[ "$(jq -r '.edges[0].to' <<<"$out")" = "Session:mini-1:abcd1234" ] || fail "board ok claimed_by not lowercase-normalized (got: $out)"
echo "PASS: board source ok — valid status token + normalized claimed_by edge"

# --- board: absent -------------------------------------------------------
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "board absent status (got: $out)"
echo "PASS: board source absent — zero open issues"

# --- board: error (unknown status token) ------------------------------------
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:x-bogus"}]}]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "board error status on unknown token (got: $out)"
echo "PASS: board source error — node status not in ontology registry"

# --- board: error (board_resolve itself fails) ------------------------------
_board_gh() { return 7; }
out="$(_sg_read_board "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "board error status on board_resolve failure (got: $out)"
echo "PASS: board source error — board_resolve failure"

# --- board: closed-issue residue (temperloop#1978 round 2, acceptance
# criterion 2) --------------------------------------------------------------
# ONE `_board_gh api "repos/.../issues" --method GET -f state=closed -f
# labels=<label> ...` call PER `fnd:status:*` label (never `gh issue list` —
# that shape collides with the OPEN-issue mock arm every other case in this
# file uses; never a single unfiltered call either — GitHub's `labels`
# filter is server-side AND-only, so this must be one call per label).
# `fnd:status:backlog`'s own call returns #158 (this item's day-1 soak
# evidence); `fnd:status:ready` and `fnd:status:in-progress` return empty
# pages, mirroring the live label inventory having zero closed residue for
# those two labels today.
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues")
      case " $* " in
        *" labels=fnd:status:backlog "*) echo '[{"number":158,"title":"y","labels":[{"name":"fnd:status:backlog"}]}]' ;;
        *) echo '[]' ;;
      esac
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "board ok status with closed residue present (got: $out)"
[ "$(jq -c '[.nodes[] | select(.id=="Issue:158")] | .[0] | {status,state}' <<<"$out")" = '{"status":"fnd:status:backlog","state":"closed"}' ] \
  || fail "board closed-residue node #158 shape mismatch (got: $out)"
[ "$(jq '.nodes | length' <<<"$out")" = 2 ] || fail "board closed-residue node count (open #1 + closed #158, found via its own label's call) mismatch (got: $out)"
echo "PASS: board source — a closed issue still wearing an fnd:status:* label surfaces as its own residue Issue node, via that label's own filtered GET"

# --- board: closed-issue residue call is a GET, never a POST (temperloop#1978
# round 2, Finding 1 + required structural defense) -------------------------
# `gh api` silently switches from GET to POST the instant ANY `-f`/`-F`
# param is present, unless `--method`/`-X` names GET explicitly — this is
# exactly the round-1 regression (a live 422 against the create-an-issue
# endpoint, swallowed whole by the fail-soft arm). A mock that only replays
# a canned BODY back is structurally blind to this (dispatches on "$1 $2"
# regardless of method), so this one instead RECORDS the full argv of every
# closed-residue call — to a FILE, since `_sg_read_board` invokes `_board_gh`
# through `$(...)` command substitution, a subshell an in-memory array
# mutation would not survive — and asserts `--method GET` (or `-X GET`) is
# present on EACH recorded call: asserting on the REQUEST SHAPE, not the
# response.
_SG_TEST_CALLS_FILE="$TMP/closed-residue-calls"
: > "$_SG_TEST_CALLS_FILE"
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues")
      printf '%s\n' "$*" >> "$_SG_TEST_CALLS_FILE"
      echo '[]'
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD")"
[ -s "$_SG_TEST_CALLS_FILE" ] || fail "closed-residue read made zero _board_gh api calls (expected one per fnd:status:* label)"
while IFS= read -r call; do
  case " $call " in
    *" --method GET "*|*" -X GET "*) : ;;
    *) fail "closed-residue call regressed off an explicit GET (gh api would silently POST to the create-issue endpoint): $call" ;;
  esac
done < "$_SG_TEST_CALLS_FILE"
echo "PASS: board source — every closed-residue call carries an explicit --method GET (never a bare -f call that gh would silently POST)"

# --- board: closed-issue residue read fails -> FAIL-SOFT, never errors the
# whole board source (the primary open-issue read still succeeded) ----------
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues") return 1 ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_board "$BOARD" 2>/dev/null)"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "a failing closed-residue read must not error the whole board source (got: $out)"
[ "$(jq '.nodes | length' <<<"$out")" = 1 ] || fail "a failing closed-residue read should contribute zero extra nodes (got: $out)"
echo "PASS: board source — a failing closed-residue read degrades to zero extra nodes, never a hard error on the whole source"

# =============================================================================
# source: board_edges (sub_issue_of, blocked_by)
# =============================================================================

# --- board_edges: ok ---------------------------------------------------------
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":11,"title":"x","labels":[{"name":"fnd:status:ready"}]},{"number":12,"title":"y","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues/11/sub_issues") echo '[{"number":12,"state":"open"}]' ;;
    "api repos/$REPO/issues/11/dependencies/blocked_by") echo '[]' ;;
    "api repos/$REPO/issues/12/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/12/dependencies/blocked_by") echo '[{"number":11,"state":"open"}]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
board_r="$(_sg_read_board "$BOARD")"
out="$(_sg_read_board_edges "$BOARD" "$board_r")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "board_edges ok status (got: $out)"
[ "$(jq -c '[.edges[] | .type] | sort' <<<"$out")" = '["blocked_by","sub_issue_of"]' ] || fail "board_edges ok edge types (got: $out)"
echo "PASS: board_edges source ok — sub_issue_of + blocked_by from board.sh accessors"

# --- board_edges: absent (no edges found) -----------------------------------
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":13,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues/13/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/13/dependencies/blocked_by") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
board_r="$(_sg_read_board "$BOARD")"
out="$(_sg_read_board_edges "$BOARD" "$board_r")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "board_edges absent status (got: $out)"
echo "PASS: board_edges source absent — issues exist, no sub_issue_of/blocked_by edges"

# --- board_edges: error (cascades from upstream board error) ---------------
_board_gh() { return 7; }
board_r="$(_sg_read_board "$BOARD")"
out="$(_sg_read_board_edges "$BOARD" "$board_r")"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "board_edges error status (got: $out)"
echo "PASS: board_edges source error — cascades from the upstream board source"

# --- board_edges: stale (via the read-time transform, see below) ----------
# Exercised together with the other three sources' stale case at the bottom
# of this file (_sg_read_snapshot marks EVERY source stale uniformly at
# read-time — there is no per-source stale trigger to test separately).

# =============================================================================
# source: pr_list (PR nodes, closes edges)
# =============================================================================

# --- pr_list: ok (bare Closes line only; backticked/trailing/leading excluded)
_board_gh() {
  case "$1 $2" in
    "pr list")
      jq -nc '[{number:1,title:"a",body:"intro\nCloses #10\nFixes #11\n`Closes #12`\nCloses #13 trailing\nleading Closes #14\n"}]'
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_pr_list "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "pr_list ok status (got: $out)"
[ "$(jq -c '[.edges[].to] | sort' <<<"$out")" = '["Issue:10","Issue:11"]' ] || fail "pr_list closes-line parsing (got: $out)"
echo "PASS: pr_list source ok — PR node + closes edges from bare Closes/Fixes lines only"

# --- pr_list: absent (no open PRs) ------------------------------------------
_board_gh() {
  case "$1 $2" in
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_pr_list "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "pr_list absent status (got: $out)"
echo "PASS: pr_list source absent — no open PRs"

# --- pr_list: error (gh pr list fails) --------------------------------------
_board_gh() {
  case "$1 $2" in
    "pr list") return 5 ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
out="$(_sg_read_pr_list "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "pr_list error status (got: $out)"
echo "PASS: pr_list source error — gh pr list failure"

# =============================================================================
# source: worktrees (Worktree nodes)
# =============================================================================

# --- worktrees: ok (a linked <repo>.wt/<slug> worktree) ---------------------
_sg_git() {
  cat <<'EOT'
worktree /home/x/dev/batch/foundation
HEAD abc
branch main

worktree /home/x/dev/batch/foundation.wt/slug1
HEAD def
branch feat/slug1
EOT
}
out="$(_sg_read_worktrees "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "worktrees ok status (got: $out)"
[ "$(jq -r '.nodes[0].path' <<<"$out")" = "/home/x/dev/batch/foundation.wt/slug1" ] || fail "worktrees ok node (got: $out)"
echo "PASS: worktrees source ok — a linked <repo>.wt/<slug> worktree"

# --- worktrees: absent (main checkout only, no linked worktrees) -----------
_sg_git() { echo "worktree /home/x/dev/batch/foundation"; }
out="$(_sg_read_worktrees "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "worktrees absent status (got: $out)"
echo "PASS: worktrees source absent — no linked worktrees"

# --- worktrees: error (git itself fails) ------------------------------------
_sg_git() { return 9; }
out="$(_sg_read_worktrees "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "worktrees error status (got: $out)"
echo "PASS: worktrees source error — git worktree list failure"

# =============================================================================
# stale: a read-time transform marks EVERY source stale (ADR 0033)
# =============================================================================
fresh_cache stale
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":20,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues/20/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/20/dependencies/blocked_by") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_git() { echo "worktree /home/x/dev/batch/foundation"; }

fresh="$(_sg_build_snapshot "$BOARD")"
_sg_persist_snapshot "$BOARD" "$fresh" "state-graph" || fail "persist for stale test failed"
# A just-built snapshot is fresh: none of the four sources report stale.
read_now="$(_sg_read_snapshot "$BOARD" state-graph)"
[ "$(jq -r '[.sources[].status] | index("stale")' <<<"$read_now")" = "null" ] \
  || fail "a fresh snapshot must not read stale (got: $read_now)"
echo "PASS: a fresh snapshot's read carries each source's real build-time status"

# Age the meta.json past STATE_GRAPH_MAX_AGE_S and re-read.
meta="$(cache_meta_file "$BOARD" state-graph)"
old_ts=$(( $(date +%s) - STATE_GRAPH_MAX_AGE_S - 10 ))
jq -c --argjson ts "$old_ts" '.last_refresh=$ts' "$meta" >"$meta.tmp" && mv "$meta.tmp" "$meta"
stale_read="$(_sg_read_snapshot "$BOARD" state-graph)"
for src in board board_edges pr_list worktrees; do
  [ "$(jq -r --arg s "$src" '.sources[$s].status' <<<"$stale_read")" = "stale" ] \
    || fail "source $src did not read stale past STATE_GRAPH_MAX_AGE_S (got: $stale_read)"
done
echo "PASS: board source stale — a read past STATE_GRAPH_MAX_AGE_S"
echo "PASS: board_edges source stale — a read past STATE_GRAPH_MAX_AGE_S"
echo "PASS: pr_list source stale — a read past STATE_GRAPH_MAX_AGE_S"
echo "PASS: worktrees source stale — a read past STATE_GRAPH_MAX_AGE_S"

# =============================================================================
# the snapshot goes through lib/cache.sh (repo-keyed dir, meta.json, atomic)
# =============================================================================
fresh_cache cache-integration
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_git() { echo "worktree /home/x/dev/batch/foundation"; }
built="$(cmd_build --board "$BOARD")"

expect_dir="$(cache_repo_dir "$BOARD" state-graph)"
expect_snap="$(cache_snapshot_file "$BOARD" state-graph)"
expect_meta="$(cache_meta_file "$BOARD" state-graph)"
[ -d "$expect_dir" ] || fail "cache.sh's own cache_repo_dir path was not created"
[ -s "$expect_snap" ] || fail "cache.sh's own cache_snapshot_file path was not written"
[ -s "$expect_meta" ] || fail "cache.sh's own cache_meta_file path was not written"
[ "$(cat "$expect_snap")" = "$built" ] || fail "on-disk snapshot does not match cmd_build's stdout"
[ "$(jq -r '.schema_version' "$expect_meta")" = "1" ] || fail "meta.json missing schema_version"
[ "$(jq -r '.repo' "$expect_meta")" = "$REPO" ] || fail "meta.json repo mismatch"
# cache_dirty (kind=state-graph) must invalidate ONLY this kind's freshness,
# never touch the sibling "issues" kind cache.sh already owns.
cache_dirty "$BOARD" state-graph
[ "$(jq -r '.last_refresh' "$expect_meta")" = "0" ] || fail "cache_dirty did not zero last_refresh"
echo "PASS: the snapshot is written and invalidated through lib/cache.sh (kind=state-graph)"

# =============================================================================
# clean --board N removes ONE repo's snapshot only
# =============================================================================
fresh_cache clean
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_git() { echo "worktree /home/x/dev/batch/foundation"; }
cmd_build --board 4 >/dev/null
cmd_build --board 3 >/dev/null
dir4="$(cache_repo_dir 4 state-graph)"
dir3="$(cache_repo_dir 3 state-graph)"
[ -d "$dir4" ] && [ -d "$dir3" ] || fail "setup: both boards' snapshots should exist before clean"
cmd_clean --board 4
[ ! -d "$dir4" ] || fail "clean --board 4 left board 4's snapshot behind"
[ -d "$dir3" ] || fail "clean --board 4 removed board 3's snapshot too"
echo "PASS: clean --board N removes only that one repo's snapshot"

# =============================================================================
# bench --scale N: a synthetic N-scaled snapshot, timed
# =============================================================================
fresh_cache bench
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":1,"title":"x","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "api repos/$REPO/issues/1/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/1/dependencies/blocked_by") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_git() { echo "worktree /home/x/dev/batch/foundation"; }
bench_out="$(cmd_bench --scale 5 --board "$BOARD")"
echo "$bench_out" | grep 'scale=5' >/dev/null || fail "bench did not report the requested scale (got: $bench_out)"
echo "$bench_out" | grep -E 'nodes=5( |$)' >/dev/null || fail "bench did not scale node count 5x the 1-node base (got: $bench_out)"
echo "$bench_out" | grep -E 'build_ms=[0-9]+' >/dev/null || fail "bench did not print a build_ms figure (got: $bench_out)"
echo "PASS: bench --scale N generates a synthetic N-scaled snapshot and prints build time"

# =============================================================================
# the reader table is extensible (state-graph-build-local, temperloop#1918,
# added plan_notes/journal/tmux without touching these four core sources —
# see test_state_graph_local.sh for their own ok/absent/error/stale coverage)
# =============================================================================
[ "$_SG_SOURCES" = "board board_edges pr_list worktrees plan_notes journal tmux" ] \
  || fail "reader table drifted from the seven known sources (got: $_SG_SOURCES)"
echo "PASS: the reader table names exactly the seven known sources and nothing else"

echo "ALL PASS: test_state_graph.sh"
