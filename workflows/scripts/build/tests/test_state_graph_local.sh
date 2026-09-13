#!/usr/bin/env bash
#
# Tests for the four HOST-LOCAL sources state-graph-build-local
# (temperloop#1918, epic #1910; transcripts added by temperloop#1980 round 3)
# added to workflows/scripts/build/state-graph.sh's reader table —
# plan_notes, journal, tmux, transcripts — alongside the four core sources
# test_state_graph.sh already covers (board / board_edges / pr_list /
# worktrees, untouched by this item). Same fixture discipline as that file:
# this test `source`s state-graph.sh (whose source-guard skips the CLI
# dispatch) and overrides each new source's own seam — no network, no real
# tmux server, no real knowledge store / transcript root / Claude Code
# projects directory on the host running the test. Fixtures are entirely
# synthetic: no real host names, session ids, or paths.
#
# Sixteen cases (ok/absent/error/stale, one per state, per source):
#   - plan_notes: ok (an approved note's PlanItem nodes + depends_on/after
#     edges + pr:/pushed_sha: fields, from the knowledge store), absent (no
#     store, and separately no note whose status is approved/executing),
#     error (a checkbox sentinel not in the ontology registry's
#     state:plan-sentinel alphabet), stale
#   - journal: ok (a Session node + step-outcome from an `agent-*.jsonl`
#     transcript under $SPEND_TRANSCRIPT_ROOT), absent (a missing
#     transcript root, and separately a root with no matching files), error
#     (a malformed JSON line), stale
#   - tmux: ok (a `@claimed_issue`-marked window's Marker node + marked_by
#     edge, AND separately a reachable server with zero claims — this must
#     read `ok`, never `absent`), absent (no tmux binary or no server),
#     error (list-windows fails after list-sessions succeeded), stale
#   - transcripts: ok (a fresh `$CLAUDE_PROJECTS_DIR/*/<sess>*.jsonl`
#     transcript emits a Transcript node, AND separately a reachable
#     directory with zero/only-stale sessions — this must read `ok`, never
#     `absent`), absent (no transcript directory at all), error (directory
#     exists but is not readable — permission denied), stale
#
# The deliberately-INVALID plan-sentinel fixture (the error case) is built
# via `printf '...[%s]...' 'q'` rather than a literal `- [q] ` markdown
# line in this file's own source: workflows/scripts/config/check-ontology-
# registry.sh scans every git-tracked file (this one included) for the
# `- [<c>] ` / `` `[<c>]` `` sentinel grammar and would flag a literal
# unregistered bracket-char sequence as UNLISTED-SENTINEL. The runtime-
# assembled fixture file itself lives only under a mktemp dir, never
# git-tracked, so it is never scanned — only THIS FILE'S OWN byte content
# must avoid the literal grammar, which the printf template does (`[%s]`
# is two characters between the brackets, not one, so it never matches).
# shellcheck disable=SC2317,SC2329
set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=workflows/scripts/build/state-graph.sh
source "$HERE/../state-graph.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# `touch -t` stamp for <n> seconds ago, for the transcripts source's mtime
# fixtures below — mirrors test_worktree_concurrency.sh's own `past_stamp`
# exactly (BSD `date -v-Ns` vs. GNU `date -d "-N seconds"`, feature-detected
# rather than chained, for the same reason the code under test feature-
# detects `stat`).
past_stamp() {
  if date -v-1S '+%Y' >/dev/null 2>&1; then
    date -v-"$1"S '+%Y%m%d%H%M.%S'          # BSD/macOS
  else
    date -d "-$1 seconds" '+%Y%m%d%H%M.%S'  # GNU coreutils
  fi
}

# Never touch the real knowledge-store read-log from a fixture run (mirrors
# workflows/scripts/lib/tests/test_knowledge_store.sh's own isolation).
export KNOWLEDGE_READ_LOG="$TMP/knowledge-reads.log"

BOARD=4          # Towheads/foundation, per board.sh's built-in map

# =============================================================================
# source: plan_notes (PlanItem nodes, depends_on/after edges, pr/pushed_sha)
# =============================================================================

# --- plan_notes: ok -----------------------------------------------------
# Three items in one approved note: alpha (no edges), beta (depends-on
# alpha, pr:/pushed_sha:), gamma (after beta) — exercises both edge types
# and the orchestrator-written fields in one fixture.
export KNOWLEDGE_STORE_ROOT="$TMP/ks-ok"
mkdir -p "$KNOWLEDGE_STORE_ROOT/Plans"
cat > "$KNOWLEDGE_STORE_ROOT/Plans/2026-01-01 test - foo.md" <<'EOF'
---
tags: [plan, project/test]
date: 2026-01-01
status: approved
---

# Test plan

## Items

- [x] **Alpha** `slug: alpha` — first
  - branch: `feat/alpha`
  - size: S
  - acceptance:
    - does a thing

- [~] **Beta** `slug: beta` — second
  - branch: `feat/beta`
  - size: S
  - depends-on: alpha
  - pr: 42
  - pushed_sha: deadbeef1
  - acceptance:
    - does another thing

- [ ] **Gamma** `slug: gamma` — third
  - branch: `feat/gamma`
  - size: S
  - after: beta
  - acceptance:
    - does a third thing
EOF
out="$(_sg_read_plan_notes "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "plan_notes ok status (got: $out)"
[ "$(jq '[.nodes[] | select(.type=="PlanItem")] | length' <<<"$out")" -eq 3 ] \
  || fail "plan_notes ok did not emit three PlanItem nodes (got: $out)"
[ "$(jq -r '.nodes[] | select(.slug=="alpha") | .state' <<<"$out")" = "[x]" ] \
  || fail "plan_notes ok alpha sentinel state (got: $out)"
[ "$(jq -r '.nodes[] | select(.slug=="beta") | .pr' <<<"$out")" = "42" ] \
  || fail "plan_notes ok beta pr: field (got: $out)"
[ "$(jq -r '.nodes[] | select(.slug=="beta") | .pushed_sha' <<<"$out")" = "deadbeef1" ] \
  || fail "plan_notes ok beta pushed_sha: field (got: $out)"
[ "$(jq -c '[.edges[] | select(.type=="depends_on")] | length' <<<"$out")" = "1" ] \
  || fail "plan_notes ok missing depends_on edge (got: $out)"
case "$(jq -r '.edges[] | select(.type=="depends_on") | .to' <<<"$out")" in
  *:alpha) ;;
  *) fail "plan_notes ok depends_on edge does not target alpha (got: $out)" ;;
esac
[ "$(jq -c '[.edges[] | select(.type=="after")] | length' <<<"$out")" = "1" ] \
  || fail "plan_notes ok missing after edge (got: $out)"
echo "PASS: plan_notes source ok — PlanItem nodes, depends_on/after edges, pr/pushed_sha fields"

# --- plan_notes: absent (no store) ---------------------------------------
export KNOWLEDGE_STORE_ROOT="$TMP/ks-no-such-store"
out="$(_sg_read_plan_notes "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "plan_notes absent (missing store) status (got: $out)"
echo "PASS: plan_notes source absent — the knowledge store does not exist"

# --- plan_notes: absent (store exists, no note is approved/executing) ---
export KNOWLEDGE_STORE_ROOT="$TMP/ks-draft-only"
mkdir -p "$KNOWLEDGE_STORE_ROOT/Plans"
cat > "$KNOWLEDGE_STORE_ROOT/Plans/2026-01-02 test - draft.md" <<'EOF'
---
status: draft
---

## Items

- [ ] **X** `slug: x` — not live work yet
EOF
out="$(_sg_read_plan_notes "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "plan_notes absent (no matching note) status (got: $out)"
echo "PASS: plan_notes source absent — no note's status is approved/executing"

# --- plan_notes: error (checkbox sentinel not in the ontology registry) -
export KNOWLEDGE_STORE_ROOT="$TMP/ks-bad-sentinel"
mkdir -p "$KNOWLEDGE_STORE_ROOT/Plans"
{
  printf -- '---\nstatus: approved\n---\n\n## Items\n\n'
  # Built via printf, not a literal line — see the file header comment.
  printf -- '- [%s] **Bad** `slug: bogus` — an unregistered sentinel\n' 'q'
  printf -- '  - branch: `fix/bogus`\n  - size: S\n'
} > "$KNOWLEDGE_STORE_ROOT/Plans/2026-01-03 test - bad.md"
out="$(_sg_read_plan_notes "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "plan_notes error status (got: $out)"
echo "PASS: plan_notes source error — checkbox sentinel not a state:plan-sentinel row"

# =============================================================================
# source: journal (Session nodes, step outcomes)
# =============================================================================

# --- journal: ok ----------------------------------------------------------
export SPEND_TRANSCRIPT_ROOT="$TMP/tr-ok"
mkdir -p "$SPEND_TRANSCRIPT_ROOT/proj1/11111111-1111-1111-1111-111111111111/subagents"
cat > "$SPEND_TRANSCRIPT_ROOT/proj1/11111111-1111-1111-1111-111111111111/subagents/agent-w1.jsonl" <<'JSONL'
{"type":"assistant","sessionId":"11111111-1111-1111-1111-111111111111"}
{"sessionId":"11111111-1111-1111-1111-111111111111","step":"pr-open","outcome":"PR_OPENED"}
JSONL
out="$(_sg_read_journal "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "journal ok status (got: $out)"
[ "$(jq -r '.nodes[0].id' <<<"$out")" = "Session:11111111-1111-1111-1111-111111111111" ] \
  || fail "journal ok Session node id (got: $out)"
[ "$(jq -c '.nodes[0].steps' <<<"$out")" = '[{"step":"pr-open","outcome":"PR_OPENED"}]' ] \
  || fail "journal ok step-outcome not recorded (got: $out)"
echo "PASS: journal source ok — Session node + step outcome from an agent-*.jsonl transcript"

# --- journal: absent (missing transcript root) -----------------------------
export SPEND_TRANSCRIPT_ROOT="$TMP/tr-no-such-root"
out="$(_sg_read_journal "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "journal absent (missing root) status (got: $out)"
echo "PASS: journal source absent — a missing transcript directory"

# --- journal: absent (root exists, no matching files) ----------------------
export SPEND_TRANSCRIPT_ROOT="$TMP/tr-empty"
mkdir -p "$SPEND_TRANSCRIPT_ROOT"
out="$(_sg_read_journal "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "journal absent (no files) status (got: $out)"
echo "PASS: journal source absent — transcript root exists but holds no agent-*.jsonl files"

# --- journal: error (malformed JSON line) ----------------------------------
export SPEND_TRANSCRIPT_ROOT="$TMP/tr-bad"
mkdir -p "$SPEND_TRANSCRIPT_ROOT/proj1/22222222-2222-2222-2222-222222222222/subagents"
printf 'not json at all\n' > "$SPEND_TRANSCRIPT_ROOT/proj1/22222222-2222-2222-2222-222222222222/subagents/agent-w2.jsonl"
out="$(_sg_read_journal "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "journal error status (got: $out)"
echo "PASS: journal source error — a malformed (non-JSON) journal line"

# =============================================================================
# source: tmux (Marker nodes, marked_by edges)
# =============================================================================

# --- tmux: absent (no tmux binary or no server) ----------------------------
_sg_tmux() { return 1; }
out="$(_sg_read_tmux "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "tmux absent status (got: $out)"
echo "PASS: tmux source absent — no tmux binary or no server (never 'no claims held')"

# --- tmux: ok (reachable server, zero claims — must NOT read absent) ------
_sg_tmux() {
  case "$1" in
    list-sessions) return 0 ;;
    list-windows) printf '%s\t%s\n' '@1' '' ;;
    *) return 3 ;;
  esac
}
out="$(_sg_read_tmux "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "tmux ok (zero claims) status (got: $out)"
[ "$(jq '.nodes | length' <<<"$out")" -eq 0 ] || fail "tmux ok (zero claims) unexpectedly emitted a node (got: $out)"
echo "PASS: tmux source ok — a reachable server with zero claims held is ok, not absent"

# --- tmux: ok (a marked window) --------------------------------------------
_sg_tmux() {
  case "$1" in
    list-sessions) return 0 ;;
    list-windows) printf '%s\t%s\n' '@3' '#42 fix thing' ;;
    *) return 3 ;;
  esac
}
out="$(_sg_read_tmux "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "tmux ok (marked window) status (got: $out)"
[ "$(jq -r '.nodes[0].id' <<<"$out")" = "Marker:@3" ] || fail "tmux ok Marker node id (got: $out)"
[ "$(jq -r '.edges[0].type' <<<"$out")" = "marked_by" ] || fail "tmux ok marked_by edge type (got: $out)"
[ "$(jq -r '.edges[0].from' <<<"$out")" = "Issue:42" ] || fail "tmux ok marked_by edge source (got: $out)"
[ "$(jq -r '.edges[0].to' <<<"$out")" = "Marker:@3" ] || fail "tmux ok marked_by edge target (got: $out)"
echo "PASS: tmux source ok — Marker node + marked_by edge from a @claimed_issue window"

# --- tmux: error (list-windows fails after list-sessions succeeded) -------
_sg_tmux() {
  case "$1" in
    list-sessions) return 0 ;;
    list-windows) return 9 ;;
    *) return 3 ;;
  esac
}
out="$(_sg_read_tmux "$BOARD")"
[ "$(jq -r .status <<<"$out")" = "error" ] || fail "tmux error status (got: $out)"
echo "PASS: tmux source error — list-windows failed on a reachable server"

# =============================================================================
# source: transcripts (Transcript nodes — stale-claims's liveness oracle,
# temperloop#1980 round 3). No seam like tmux's `_sg_tmux`: mirrors journal's
# own precedent (real files under an env-var-named directory, no command to
# shim) — see _sg_read_transcripts's own header comment.
# =============================================================================

# --- transcripts: ok (a fresh per-session transcript) -----------------------
export CLAUDE_PROJECTS_DIR="$TMP/cp-ok"
mkdir -p "$CLAUDE_PROJECTS_DIR/proj1"
: > "$CLAUDE_PROJECTS_DIR/proj1/33333333-3333-3333-3333-333333333333.jsonl"
out="$(_sg_read_transcripts)"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "transcripts ok status (got: $out)"
[ "$(jq -r '.nodes[0].id' <<<"$out")" = "Transcript:33333333" ] || fail "transcripts ok Transcript node id (got: $out)"
[ "$(jq -r '.nodes[0].sess8' <<<"$out")" = "33333333" ] || fail "transcripts ok sess8 field (got: $out)"
echo "PASS: transcripts source ok — a fresh per-session transcript emits a Transcript node keyed by its 8-char session id"

# --- transcripts: ok (directory exists, zero sessions — must NOT read absent) -
export CLAUDE_PROJECTS_DIR="$TMP/cp-empty"
mkdir -p "$CLAUDE_PROJECTS_DIR"
out="$(_sg_read_transcripts)"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "transcripts ok (zero sessions) status (got: $out)"
[ "$(jq '.nodes | length' <<<"$out")" -eq 0 ] || fail "transcripts ok (zero sessions) unexpectedly emitted a node (got: $out)"
echo "PASS: transcripts source ok — a reachable directory with zero sessions is ok, not absent"

# --- transcripts: ok (a transcript past the cutoff emits NO node — "dead" is
# the ordinary empty case, mirroring _reconcile_session_live's own "no
# transcript -> dead" reading, never `absent`) ------------------------------
export CLAUDE_PROJECTS_DIR="$TMP/cp-stale-file"
mkdir -p "$CLAUDE_PROJECTS_DIR/proj1"
: > "$CLAUDE_PROJECTS_DIR/proj1/44444444-4444-4444-4444-444444444444.jsonl"
touch -t "$(past_stamp 7200)" "$CLAUDE_PROJECTS_DIR/proj1/44444444-4444-4444-4444-444444444444.jsonl"
out="$(RECONCILE_STALE_AFTER_SECS=3600 _sg_read_transcripts)"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "transcripts ok (stale file) status (got: $out)"
[ "$(jq '.nodes | length' <<<"$out")" -eq 0 ] || fail "transcripts: a transcript past RECONCILE_STALE_AFTER_SECS must emit no node (got: $out)"
echo "PASS: transcripts source — a transcript older than RECONCILE_STALE_AFTER_SECS emits no node (dead, not absent)"

# --- transcripts: "now" is seamed (_sg_now), pinned exactly ON the cutoff --
# boundary (temperloop#1980 round 4 MEDIUM 1). The source's whole claim is
# equivalence with reconcile.sh's `_reconcile_session_live`, whose own
# `(now - newest) <= RECONCILE_STALE_AFTER_SECS` this file's awk reduction
# mirrors — a transcript aged EXACTLY the cutoff must still emit a node
# (`<=`, not `<`). `epoch_stamp` (below) turns a FIXED epoch into a
# `touch -t` stamp so the file's mtime and `_sg_now`'s pinned return value
# are related by an exact, race-free subtraction — no reliance on real wall
# time elapsing between computing the stamp and touching the file (unlike
# `past_stamp`'s "N seconds ago from actual now", which cannot land exactly
# on a boundary). Mutating the awk comparison to `<` makes this fixture
# fail: (now - mt) == cutoff is no longer `< cutoff`.
epoch_stamp() { # <epoch-seconds> -> touch -t stamp, local time
  if date -r 0 '+%Y' >/dev/null 2>&1; then
    date -r "$1" '+%Y%m%d%H%M.%S'          # BSD/macOS
  else
    date -d "@$1" '+%Y%m%d%H%M.%S'         # GNU coreutils
  fi
}
FIXED_NOW=1700000000
CUTOFF=3600
_sg_now() { echo "$FIXED_NOW"; }
export CLAUDE_PROJECTS_DIR="$TMP/cp-cutoff-boundary"
mkdir -p "$CLAUDE_PROJECTS_DIR/proj1"
BOUNDARY_FILE="$CLAUDE_PROJECTS_DIR/proj1/55555555-5555-5555-5555-555555555555.jsonl"
: > "$BOUNDARY_FILE"
touch -t "$(epoch_stamp $((FIXED_NOW - CUTOFF)))" "$BOUNDARY_FILE"
out="$(RECONCILE_STALE_AFTER_SECS=$CUTOFF _sg_read_transcripts)"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "transcripts cutoff-boundary status (got: $out)"
[ "$(jq '.nodes | length' <<<"$out")" -eq 1 ] || fail "transcripts: a transcript aged EXACTLY RECONCILE_STALE_AFTER_SECS must still emit a node (<=, not <) (got: $out)"
[ "$(jq -r '.nodes[0].sess8' <<<"$out")" = "55555555" ] || fail "transcripts cutoff-boundary sess8 (got: $out)"
_sg_now() { date +%s; }  # restore the real seam for every test after this one
echo "PASS: transcripts source — a transcript aged EXACTLY RECONCILE_STALE_AFTER_SECS still emits a node (<=, boundary-pinned via the _sg_now seam)"

# --- transcripts: newest-mtime-per-session reduction, not last-wins --------
# (temperloop#1980 round 4 MEDIUM 2). A real session routinely has SEVERAL
# transcript files across project dirs (Claude Code starts a fresh file per
# project directory for the same session); the awk reduction must keep the
# NEWEST mtime among them all, mirroring _reconcile_session_live's own "max
# mtime among any matching file". Two files for one sess8 in two project
# dirs — one aged past the cutoff, one fresh — must still resolve to exactly
# one live Transcript node. Mutating the reduction to last-wins
# (`{ max[$1] = $2 }`, unconditional) makes this fixture non-deterministic/
# fail: whichever file the glob happens to visit LAST decides liveness, and
# the older-file-last ordering below would then read dead.
export CLAUDE_PROJECTS_DIR="$TMP/cp-multi-file-session"
mkdir -p "$CLAUDE_PROJECTS_DIR/proj-old" "$CLAUDE_PROJECTS_DIR/proj-fresh"
: > "$CLAUDE_PROJECTS_DIR/proj-old/66666666-6666-6666-6666-666666666666.jsonl"
touch -t "$(past_stamp 7200)" "$CLAUDE_PROJECTS_DIR/proj-old/66666666-6666-6666-6666-666666666666.jsonl"
: > "$CLAUDE_PROJECTS_DIR/proj-fresh/66666666-6666-6666-6666-666666666666.jsonl"
out="$(RECONCILE_STALE_AFTER_SECS=3600 _sg_read_transcripts)"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "transcripts multi-file-session status (got: $out)"
[ "$(jq '.nodes | length' <<<"$out")" -eq 1 ] || fail "transcripts: two files for one sess8 (one stale, one fresh) must reduce to exactly one Transcript node (got: $out)"
[ "$(jq -r '.nodes[0].sess8' <<<"$out")" = "66666666" ] || fail "transcripts multi-file-session sess8 (got: $out)"
echo "PASS: transcripts source — the newest mtime among several files for one session decides liveness (max reduction, not last-wins)"

# --- transcripts: absent (no such directory) --------------------------------
export CLAUDE_PROJECTS_DIR="$TMP/cp-no-such-dir"
out="$(_sg_read_transcripts)"
[ "$(jq -r .status <<<"$out")" = "absent" ] || fail "transcripts absent status (got: $out)"
echo "PASS: transcripts source absent — no transcript directory at all (liveness cannot be checked)"

# --- transcripts: error (directory exists but is not readable) -------------
if [ "$(id -u)" -ne 0 ]; then
  export CLAUDE_PROJECTS_DIR="$TMP/cp-unreadable"
  mkdir -p "$CLAUDE_PROJECTS_DIR"
  chmod 000 "$CLAUDE_PROJECTS_DIR"
  out="$(_sg_read_transcripts)"
  chmod 755 "$CLAUDE_PROJECTS_DIR"   # restore before the EXIT trap's rm -rf
  [ "$(jq -r .status <<<"$out")" = "error" ] || fail "transcripts error status (got: $out)"
  echo "PASS: transcripts source error — directory exists but is not readable (permission denied)"
else
  echo "SKIP: transcripts source error (permission-denied case) — running as root, chmod 000 is not enforced"
fi

# =============================================================================
# stale: the shared read-time transform (ADR 0033) also covers all four new
# sources — _sg_read_snapshot overrides EVERY source's status uniformly, so
# one full-snapshot build+age exercises plan_notes/journal/tmux/transcripts
# the same way test_state_graph.sh already does for the original four.
# =============================================================================
export CACHE_STORE_ROOT="$TMP/cache-stale"
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_git() { echo "worktree /home/x/dev/batch/foundation"; }
export KNOWLEDGE_STORE_ROOT="$TMP/ks-ok"   # the plan_notes "ok" fixture above
export SPEND_TRANSCRIPT_ROOT="$TMP/tr-ok"  # the journal "ok" fixture above
export CLAUDE_PROJECTS_DIR="$TMP/cp-ok"    # the transcripts "ok" fixture above
_sg_tmux() {
  case "$1" in
    list-sessions) return 0 ;;
    list-windows) printf '%s\t%s\n' '@3' '#42 fix thing' ;;
    *) return 3 ;;
  esac
}

fresh="$(_sg_build_snapshot "$BOARD")"
_sg_persist_snapshot "$BOARD" "$fresh" "state-graph" || fail "persist for stale test failed"
for src in plan_notes journal tmux transcripts; do
  [ "$(jq -r --arg s "$src" '.sources[$s].status' <<<"$fresh")" = "ok" ] \
    || fail "setup: $src expected ok at build time (got: $fresh)"
done

meta="$(cache_meta_file "$BOARD" state-graph)"
old_ts=$(( $(date +%s) - STATE_GRAPH_MAX_AGE_S - 10 ))
jq -c --argjson ts "$old_ts" '.last_refresh=$ts' "$meta" >"$meta.tmp" && mv "$meta.tmp" "$meta"
stale_read="$(_sg_read_snapshot "$BOARD" state-graph)"
for src in plan_notes journal tmux transcripts; do
  [ "$(jq -r --arg s "$src" '.sources[$s].status' <<<"$stale_read")" = "stale" ] \
    || fail "source $src did not read stale past STATE_GRAPH_MAX_AGE_S (got: $stale_read)"
done
echo "PASS: plan_notes source stale — a read past STATE_GRAPH_MAX_AGE_S"
echo "PASS: journal source stale — a read past STATE_GRAPH_MAX_AGE_S"
echo "PASS: tmux source stale — a read past STATE_GRAPH_MAX_AGE_S"
echo "PASS: transcripts source stale — a read past STATE_GRAPH_MAX_AGE_S"

echo "ALL PASS: test_state_graph_local.sh"
