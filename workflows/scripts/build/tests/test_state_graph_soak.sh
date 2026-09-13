#!/usr/bin/env bash
#
# Tests for `state-graph.sh soak` — the mechanical fourteen-day cross-check
# between the four board/PR/worktree-comparable queries and the INDEPENDENT
# `reconcile.sh --status` read ADR 0033's independence claim rests on
# (temperloop#1910; PER-CLASS scope rewrite temperloop#1978). Sibling of
# test_state_graph.sh / test_state_graph_local.sh / test_state_graph_queries
# .sh, which cover the seven `_sg_read_*` sources and the five `_sg_query_*`
# functions this file never re-covers — it feeds `_sg_soak_run` real
# (mocked) board/reconcile inputs through the SAME `_board_gh`/`_sg_git`/
# `_sg_tmux`/`_sg_reconcile` seams, plus this file's own deterministic
# `_sg_soak_day`/`_sg_now_ms` overrides. Fixtures are entirely synthetic: no
# real host names, session ids, issue numbers, or paths.
#
# Covers:
#   - a MATCHING day (status-drift class): both `query status-drift` and
#     reconcile.sh's `orphaned In-Progress` class independently flag the SAME
#     issue — classes["status-drift"].diff.agree=true, both only_in_* empty.
#   - a DIFFERING day (status-drift class): the two sides flag DIFFERENT
#     issues — diff.agree=false, each only_in_* names the issue the other
#     side missed.
#   - a dead-session claim stamp (temperloop#1978, this item's day-1
#     #1225/#1111/#1048/#1047 shape): surfaces in the stale-claims class
#     (both sides agree) and is correctly ABSENT from status-drift's own
#     drift_query_set — a claimed, in-progress issue trips neither of
#     status-drift's own open-domain finding kinds.
#   - a closed issue still wearing an fnd:status:* label (temperloop#1978,
#     this item's day-1 #158 shape): surfaces in the status-drift class on
#     BOTH sides (the board source's own closed-issue residue read vs.
#     reconcile's `residual status labels on closed issues`) — agree:true.
#   - unlinked-prs / orphan-worktrees: reconcile.sh has no matching class for
#     either, so their reconcile_set/diff always read the literal string
#     "not-covered" — never an empty-set false agreement/disagreement.
#   - "never a false agreement over unknown": a degraded board source makes
#     status-drift's drift_query_set (and diff) the literal string
#     "unknown", never an empty array that would read as false agreement; a
#     failing `_sg_reconcile` does the same to BOTH mapped classes'
#     reconcile_set/diff independently of the board source (one reconcile.sh
#     call covers both classes, so it degrades them together) — while
#     unlinked-prs/orphan-worktrees stay "not-covered" regardless, since
#     nothing about them was ever going to be compared against reconcile.
#   - `--count` counts DISTINCT `day` values across every CURRENT-SCHEMA-
#     COMPARABLE record in the log (`type:"audit"`/`type:"bench"`, or
#     `type:"run"` at `schema:2`), 0 on an empty/missing log — and correctly
#     EXCLUDES a pre-temperloop#1978 flat-schema run record (no `type` field
#     at all) from the count (acceptance criterion 4).
#   - `--audit --items <file>` appends a `{day, type:"audit",
#     audited_items}` record, extracting one issue number per line
#     (bare/`#N`/`Issue:N` all accepted); a zero-issue file is a legitimate
#     empty audit set, not a crash (the same pipefail/grep absorption the
#     reconcile-set extraction needs).
#   - the log rides lib/cache.sh's own path accessors (kind=state-graph-soak,
#     fully isolated from state-graph/state-graph-bench) and is APPEND-ONLY
#     — a second run never clobbers the first.
#   - `bench --scale N` captures one `{day, type:"bench", scale, query_ms,
#     slow_queries}` record into the SAME log, correctly naming only the
#     query whose deterministic elapsed time exceeds
#     `STATE_GRAPH_QUERY_SLOW_MS`.
#   - CLI dispatch: `soak --help` (THE class-A activation predicate, run
#     verbatim), missing --board, --audit with no --items, an unknown arg —
#     all exit/behave correctly with zero network reached.
#
# The seams are redefined mid-file per case (the library calls them
# indirectly), so shellcheck's "never invoked"/"unreachable" checks are false
# positives — disabled file-wide like the sibling state-graph test files.
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

# Host-local sources must never read this RUNNER's real knowledge store,
# transcript root, or tmux server — mirrors test_state_graph.sh's own
# hermetic-env pair exactly.
export KNOWLEDGE_STORE_ROOT="$TMP/no-such-knowledge-store"
export SPEND_TRANSCRIPT_ROOT="$TMP/no-such-transcripts"
_sg_tmux() { return 1; }
_sg_git() { echo "worktree /home/x/dev/batch/foundation"; }

# Every test gets its own cache root so cases never see each other's state.
fresh_cache() { export CACHE_STORE_ROOT="$TMP/cache-$1"; }

BOARD=4          # Towheads/foundation, per board.sh's built-in map
REPO="Towheads/foundation"

declare -F _sg_reconcile >/dev/null || fail "_sg_reconcile seam missing — soak has no independent reconcile.sh invocation point"
echo "PASS: state-graph.sh defines the _sg_reconcile seam (mirrors _sg_git/_sg_tmux)"

# A small accessor: read one class's field out of a soak run record.
class_field() { jq -c --arg c "$1" --arg f "$2" '.classes[$c][$f]' <<<"$3"; }

# =============================================================================
# a MATCHING day (status-drift class) — both sides independently flag #10
# =============================================================================
fresh_cache matching
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[{"number":10,"title":"x","labels":[{"name":"fnd:status:in-progress"}]}]' ;;
    "api repos/$REPO/issues/10/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/10/dependencies/blocked_by") echo '[]' ;;
    "pr list") echo '[]' ;;
    "api repos/$REPO/issues") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
# issue #10 is fnd:status:in-progress with NO claimed_by edge -> status-drift
# flags it (in_progress_no_claim). reconcile.sh's own orphaned-In-Progress
# bucket independently names the SAME issue by number — a real matching day,
# not a vacuous both-empty one.
_sg_reconcile() {
  cat <<'EOT'
orphaned In-Progress (report-only — park by hand: release.sh / re-claim):
  #10 — In Progress with no Host/Session owner (orphaned claim) — some title
EOT
}
_sg_soak_day() { echo "2026-01-01"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(jq -r '.type' <<<"$record")" = "run" ] || fail "matching-day record missing type:run (got: $record)"
[ "$(jq -r '.schema' <<<"$record")" = "2" ] || fail "matching-day record missing schema:2 (got: $record)"
[ "$(class_field status-drift drift_query_set "$record")" = '[10]' ] || fail "matching-day status-drift drift_query_set (got: $record)"
[ "$(class_field status-drift reconcile_set "$record")" = '[10]' ] || fail "matching-day status-drift reconcile_set (got: $record)"
[ "$(jq -r '.classes["status-drift"].diff.agree' <<<"$record")" = "true" ] || fail "matching-day status-drift diff.agree should be true (got: $record)"
[ "$(jq -c '.classes["status-drift"].diff.only_in_drift_query' <<<"$record")" = '[]' ] || fail "matching-day only_in_drift_query should be empty (got: $record)"
[ "$(jq -c '.classes["status-drift"].diff.only_in_reconcile' <<<"$record")" = '[]' ] || fail "matching-day only_in_reconcile should be empty (got: $record)"
[ "$(jq -r '.day' <<<"$record")" = "2026-01-01" ] || fail "matching-day record day mismatch (got: $record)"
# unlinked-prs / orphan-worktrees: reconcile.sh has no matching class for
# either — reconcile_set/diff always read "not-covered", never an empty-set
# false agreement.
[ "$(class_field unlinked-prs reconcile_set "$record")" = '"not-covered"' ] || fail "unlinked-prs reconcile_set should be 'not-covered' (got: $record)"
[ "$(class_field unlinked-prs diff "$record")" = '"not-covered"' ] || fail "unlinked-prs diff should be 'not-covered' (got: $record)"
[ "$(class_field orphan-worktrees reconcile_set "$record")" = '"not-covered"' ] || fail "orphan-worktrees reconcile_set should be 'not-covered' (got: $record)"
[ "$(class_field orphan-worktrees diff "$record")" = '"not-covered"' ] || fail "orphan-worktrees diff should be 'not-covered' (got: $record)"
echo "PASS: soak — a matching day (status-drift class, both sides flag the same issue) records agree:true; unlinked-prs/orphan-worktrees read not-covered"

# =============================================================================
# a DIFFERING day (status-drift class) — the two sides flag DIFFERENT issues
# =============================================================================
_sg_reconcile() {
  cat <<'EOT'
terminal-but-not-Done (work complete, board not):
  #99 — backing CLOSED but board status 'In Progress' — should be Done: some title
EOT
}
_sg_soak_day() { echo "2026-01-02"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field status-drift drift_query_set "$record")" = '[10]' ] || fail "differing-day status-drift drift_query_set (got: $record)"
[ "$(class_field status-drift reconcile_set "$record")" = '[99]' ] || fail "differing-day status-drift reconcile_set (got: $record)"
[ "$(jq -r '.classes["status-drift"].diff.agree' <<<"$record")" = "false" ] || fail "differing-day status-drift diff.agree should be false (got: $record)"
[ "$(jq -c '.classes["status-drift"].diff.only_in_drift_query' <<<"$record")" = '[10]' ] || fail "differing-day only_in_drift_query (got: $record)"
[ "$(jq -c '.classes["status-drift"].diff.only_in_reconcile' <<<"$record")" = '[99]' ] || fail "differing-day only_in_reconcile (got: $record)"
echo "PASS: soak — a differing day (status-drift class, each side flags a distinct issue) records agree:false with per-side diffs"

# =============================================================================
# a matching day whose reconcile.sh report embeds `#N` inside a flagged
# line's TITLE (and a `#M` inside a stderr warning) — neither may inflate
# the status-drift reconcile_set into a phantom disagreement (over-broad
# #[0-9]+ extraction over merged stdout+stderr).
# =============================================================================
_sg_reconcile() {
  echo "warning: #50 could not be labeled Backlog" >&2
  cat <<'EOT'
orphaned In-Progress (report-only — park by hand: release.sh / re-claim):
  #10 — In Progress with no Host/Session owner (orphaned claim) — fix flaky test (temperloop#1910)
EOT
}
_sg_soak_day() { echo "2026-01-05"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field status-drift reconcile_set "$record")" = '[10]' ] || fail "a #N inside a title or stderr warning must never inflate status-drift reconcile_set (got: $record)"
[ "$(jq -r '.classes["status-drift"].diff.agree' <<<"$record")" = "true" ] || fail "a #N inside a title or stderr warning must never manufacture a false disagreement (got: $record)"
echo "PASS: soak — a #N embedded in a flagged line's TITLE or a stderr warning is never mistaken for a flagged item ref"

# =============================================================================
# a dead-session claim stamp (temperloop#1978, this item's day-1
# #1225/#1111/#1048/#1047 shape): surfaces in stale-claims on BOTH sides and
# is correctly ABSENT from status-drift's own drift_query_set — a claimed,
# in-progress issue trips neither of status-drift's own open-domain finding
# kinds (it is neither unclaimed-in-progress nor claimed-but-not-in-progress).
# =============================================================================
_board_gh() {
  case "$1 $2" in
    "issue list")
      echo '[{"number":20,"title":"x","labels":[{"name":"fnd:status:in-progress"},{"name":"fnd:host/session:mini-1:deadbeef"}]}]'
      ;;
    "api repos/$REPO/issues/20/sub_issues") echo '[]' ;;
    "api repos/$REPO/issues/20/dependencies/blocked_by") echo '[]' ;;
    "pr list") echo '[]' ;;
    "api repos/$REPO/issues") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
# No journal Session node named "mini-1:deadbeef" -> stale-claims (board +
# journal) flags #20 as a claim naming a session absent from the journal.
_sg_reconcile() {
  cat <<'EOT'
stale claims (In Progress, stamped to a dead same-host session — park by hand):
  #20 — stamped 'mini-1:deadbeef' but that session is not live on this host 'mini-1' — some title
EOT
}
_sg_soak_day() { echo "2026-01-06"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field stale-claims drift_query_set "$record")" = '[20]' ] || fail "dead-session stale-claims drift_query_set (got: $record)"
[ "$(class_field stale-claims reconcile_set "$record")" = '[20]' ] || fail "dead-session stale-claims reconcile_set (got: $record)"
[ "$(jq -r '.classes["stale-claims"].diff.agree' <<<"$record")" = "true" ] || fail "dead-session stale-claims diff.agree should be true (got: $record)"
[ "$(class_field status-drift drift_query_set "$record")" = '[]' ] || fail "a claimed in-progress issue must NOT surface in status-drift's drift_query_set (got: $record)"
[ "$(class_field status-drift reconcile_set "$record")" = '[]' ] || fail "a dead-session claim stamp line must NOT be attributed to status-drift's reconcile_set (got: $record)"
echo "PASS: soak — a dead-session claim stamp surfaces in stale-claims (both sides agree) and is absent from status-drift on either side"

# =============================================================================
# a closed issue still wearing an fnd:status:* label (temperloop#1978, this
# item's day-1 #158 shape): surfaces in status-drift on BOTH sides — the
# board source's own closed-issue residue read vs. reconcile's own "residual
# status labels on closed issues" class.
# =============================================================================
_board_gh() {
  case "$1 $2" in
    # a real, unrelated OPEN issue alongside the closed one — the primary
    # open-issue read stays "ok" (never "absent"), the branch the closed-
    # issue residue supplement is actually wired into (_sg_read_board).
    "issue list") echo '[{"number":1,"title":"other","labels":[{"name":"fnd:status:ready"}]}]' ;;
    "pr list") echo '[]' ;;
    # per-label residue read (temperloop#1978 round 2): #158 only shows up on
    # the fnd:status:backlog label's own call, never the other two labels'.
    "api repos/$REPO/issues")
      case " $* " in
        *" labels=fnd:status:backlog "*) echo '[{"number":158,"title":"x","labels":[{"name":"fnd:status:backlog"}]}]' ;;
        *) echo '[]' ;;
      esac
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_reconcile() {
  cat <<'EOT'
residual status labels on closed issues (work complete, tracker label not stripped):
  #158 — CLOSED but still labeled 'fnd:status:backlog' (Done here is 'closed + no status label') — some title
  (repair: reconcile.sh --board 4 --labels --apply)
EOT
}
_sg_soak_day() { echo "2026-01-07"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field status-drift drift_query_set "$record")" = '[158]' ] || fail "closed-residue status-drift drift_query_set (got: $record)"
[ "$(class_field status-drift reconcile_set "$record")" = '[158]' ] || fail "closed-residue status-drift reconcile_set (got: $record)"
[ "$(jq -r '.classes["status-drift"].diff.agree' <<<"$record")" = "true" ] || fail "closed-residue status-drift diff.agree should be true (got: $record)"
[ "$(class_field stale-claims drift_query_set "$record")" = '[]' ] || fail "a closed status-label residue must NOT surface in stale-claims (got: $record)"
echo "PASS: soak — a closed issue still wearing an fnd:status:* label surfaces in status-drift on both sides (the #158 shape)"

# =============================================================================
# "never a false agreement over unknown"
# =============================================================================
# board_resolve failure -> status-drift's own status is "unknown" ->
# drift_query_set/diff must read "unknown", never an empty array that would
# look like real agreement. unlinked-prs/orphan-worktrees, which never
# depend on board, stay "not-covered" regardless.
_board_gh() { return 7; }
_sg_reconcile() { echo "In sync: every board item's status matches its GitHub state; no orphaned or stale claims."; }
_sg_soak_day() { echo "2026-01-03"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field status-drift drift_query_set "$record")" = '"unknown"' ] || fail "degraded board source should make status-drift drift_query_set the literal string unknown (got: $record)"
[ "$(class_field status-drift diff "$record")" = '"unknown"' ] || fail "degraded board source should make status-drift diff the literal string unknown (got: $record)"
[ "$(class_field stale-claims drift_query_set "$record")" = '"unknown"' ] || fail "degraded board source should make stale-claims drift_query_set the literal string unknown too (got: $record)"
[ "$(class_field unlinked-prs reconcile_set "$record")" = '"not-covered"' ] || fail "unlinked-prs reconcile_set stays not-covered even when board is degraded (got: $record)"
echo "PASS: soak — a degraded board source reads each affected class's drift_query_set/diff as 'unknown', never a false empty agreement"

# A failing _sg_reconcile invocation degrades BOTH mapped classes'
# reconcile_set/diff independently of the board source (one reconcile.sh
# call covers both classes, so it degrades them together) — while
# unlinked-prs/orphan-worktrees stay "not-covered" regardless.
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    "api repos/$REPO/issues") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_reconcile() { echo "reconcile.sh: some fatal error" >&2; return 1; }
_sg_soak_day() { echo "2026-01-04"; }
record="$(_sg_soak_run "$BOARD")"
[ "$(class_field status-drift drift_query_set "$record")" = '[]' ] || fail "an ok board source should still produce a real (empty) status-drift drift_query_set (got: $record)"
[ "$(class_field status-drift reconcile_set "$record")" = '"unknown"' ] || fail "a failing _sg_reconcile invocation should make status-drift reconcile_set 'unknown' (got: $record)"
[ "$(class_field status-drift diff "$record")" = '"unknown"' ] || fail "a failing _sg_reconcile invocation should make status-drift diff 'unknown' (got: $record)"
[ "$(class_field stale-claims reconcile_set "$record")" = '"unknown"' ] || fail "a failing _sg_reconcile invocation should make stale-claims reconcile_set 'unknown' too (got: $record)"
[ "$(class_field unlinked-prs reconcile_set "$record")" = '"not-covered"' ] || fail "unlinked-prs reconcile_set stays not-covered even when reconcile.sh itself fails (got: $record)"
[ "$(class_field unlinked-prs diff "$record")" = '"not-covered"' ] || fail "unlinked-prs diff stays not-covered even when reconcile.sh itself fails (got: $record)"
echo "PASS: soak — a failing reconcile.sh invocation reads both mapped classes' reconcile_set/diff as 'unknown', independent of the board source; unlinked-prs/orphan-worktrees stay not-covered"

# =============================================================================
# --count: distinct days, log is append-only through lib/cache.sh
# =============================================================================
expect_dir="$(cache_repo_dir "$BOARD" state-graph-soak)"
expect_log="$(cache_snapshot_file "$BOARD" state-graph-soak)"
[ -d "$expect_dir" ] || fail "soak log directory was not created via cache_repo_dir(kind=state-graph-soak)"
[ -s "$expect_log" ] || fail "soak log file was not created via cache_snapshot_file(kind=state-graph-soak)"
lines_before="$(wc -l <"$expect_log" | tr -d ' ')"
[ "$lines_before" -eq 7 ] || fail "soak log should carry exactly the seven runs above (got $lines_before lines)"

count="$(cmd_soak --count --board "$BOARD")"
[ "$count" = 7 ] || fail "soak --count should report 7 distinct days (got: $count)"
echo "PASS: soak --count — distinct days recorded, log persisted append-only through lib/cache.sh"

# --count SCHEMA exclusion (temperloop#1978, acceptance criterion 4): a
# hand-appended pre-temperloop#1978 flat-schema run record (no `type` field
# at all — the OLD `{day, drift_query_set, reconcile_set, diff}` shape) adds
# a line to the log but must NOT add to the day count — it is silently
# excluded as not current-schema-comparable, never misread as a per-class
# run for a day nothing per-class was ever recorded on.
printf '%s\n' '{"day":"2025-12-31","drift_query_set":[],"reconcile_set":[],"diff":{"only_in_drift_query":[],"only_in_reconcile":[],"agree":true}}' >>"$expect_log"
lines_after_legacy="$(wc -l <"$expect_log" | tr -d ' ')"
[ "$lines_after_legacy" -eq 8 ] || fail "the hand-appended legacy record should still add a line to the log (got $lines_after_legacy lines)"
count_with_legacy="$(cmd_soak --count --board "$BOARD")"
[ "$count_with_legacy" = 7 ] || fail "soak --count must exclude a pre-temperloop#1978 flat-schema run record from the day count (got: $count_with_legacy)"
echo "PASS: soak --count — a pre-temperloop#1978 flat-schema run record (no type field) is excluded from the day count"

# --count on a board with no soak log yet prints 0, never an error.
fresh_cache empty-count
count0="$(cmd_soak --count --board "$BOARD")"
[ "$count0" = 0 ] || fail "soak --count on an empty/missing log should print 0 (got: $count0)"
echo "PASS: soak --count — 0 on a board with no soak log yet"

# --count over a torn/malformed log line surfaces WHY it failed (a bare
# non-zero exit under pipefail leaves the reason silent).
fresh_cache count-malformed
malformed_dir="$(cache_repo_dir "$BOARD" state-graph-soak)"
mkdir -p "$malformed_dir"
malformed_log="$(cache_snapshot_file "$BOARD" state-graph-soak)"
printf '{not valid json\n' >"$malformed_log"
rc=0; malformed_out="$(cmd_soak --count --board "$BOARD" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "soak --count over a malformed log should exit non-zero (got: $malformed_out)"
printf '%s' "$malformed_out" | grep -F -- 'unreadable soak log' >/dev/null || fail "soak --count over a malformed log should name the unreadable log path (got: $malformed_out)"
echo "PASS: soak --count — a torn/malformed log line surfaces a diagnostic and exits non-zero"

# =============================================================================
# --audit --items <file>
# =============================================================================
fresh_cache audit
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_reconcile() { echo "In sync: every board item's status matches its GitHub state; no orphaned or stale claims."; }
_sg_soak_day() { echo "2026-01-10"; }

ITEMS_FILE="$TMP/audit-items.txt"
printf '10\n#20\nIssue:30\n#40 build fails on 2026-09\n' >"$ITEMS_FILE"
audit_record="$(cmd_soak --audit --board "$BOARD" --items "$ITEMS_FILE")"
[ "$(jq -r '.type' <<<"$audit_record")" = "audit" ] || fail "audit record missing type:audit (got: $audit_record)"
[ "$(jq -c '.audited_items' <<<"$audit_record")" = '[10,20,30,40]' ] || fail "audit record did not extract bare/#N/Issue:N item refs correctly, anchored to one ref per line (got: $audit_record)"
[ "$(jq -r '.day' <<<"$audit_record")" = "2026-01-10" ] || fail "audit record day mismatch (got: $audit_record)"
echo "PASS: soak --audit — records a hand-audited item set against today, accepting bare/#N/Issue:N refs"

# a zero-issue items file is a legitimate empty audit set, not a crash.
EMPTY_ITEMS_FILE="$TMP/empty-items.txt"
: >"$EMPTY_ITEMS_FILE"
empty_audit="$(cmd_soak --audit --board "$BOARD" --items "$EMPTY_ITEMS_FILE")"
[ "$(jq -c '.audited_items' <<<"$empty_audit")" = '[]' ] || fail "an items file naming zero issues should produce an empty audited_items array (got: $empty_audit)"
echo "PASS: soak --audit — a zero-issue items file produces an empty set, not a crash (pipefail/grep absorption)"

# missing --items file errors rather than silently no-opping.
rc=0; cmd_soak --audit --board "$BOARD" --items "$TMP/does-not-exist.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "soak --audit against a missing items file should fail, not silently succeed"
echo "PASS: soak --audit — a missing items file fails rather than silently no-opping"

# =============================================================================
# bench --scale N captures one {day, type:"bench", ...} record into the SAME
# soak log, correctly naming only the query whose deterministic elapsed time
# exceeds STATE_GRAPH_QUERY_SLOW_MS (temperloop#1910, acceptance criterion 2)
# =============================================================================
fresh_cache bench-soak
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_soak_day() { echo "2026-01-20"; }
export STATE_GRAPH_QUERY_SLOW_MS=50

# _sg_now_ms is called via command substitution ($(_sg_now_ms)), each call a
# SUBSHELL — an in-memory index would reset every call (the same subshell
# caveat test_state_graph_queries.sh's own gh-call-count comment documents),
# so this counter lives on DISK instead, surviving the subshell boundary.
# Sequence: build start/end (10ms, ignored), then per query in
# _SG_SOURCES-independent, fixed order (status-drift, stale-claims,
# unlinked-prs, orphan-worktrees, resume): 10ms each except resume's 100ms —
# the one query that must land in slow_queries.
NOW_SEQ_FILE="$TMP/now-seq.txt"
printf '0\n10\n10\n20\n20\n30\n30\n40\n40\n50\n50\n150\n' >"$NOW_SEQ_FILE"
NOW_IDX_FILE="$TMP/now-idx.txt"
echo 0 >"$NOW_IDX_FILE"
_sg_now_ms() {
  local idx v
  idx="$(cat "$NOW_IDX_FILE")"
  v="$(sed -n "$((idx + 1))p" "$NOW_SEQ_FILE")"
  echo $((idx + 1)) >"$NOW_IDX_FILE"
  echo "$v"
}
bench_stdout="$(cmd_bench --scale 1 --board "$BOARD")"
echo "$bench_stdout" | grep -E 'build_ms=[0-9]+' >/dev/null || fail "bench stdout format regressed (got: $bench_stdout)"

bench_logf="$(cache_snapshot_file "$BOARD" state-graph-soak)"
[ -s "$bench_logf" ] || fail "bench did not append to the soak log"
bench_record="$(tail -1 "$bench_logf")"
[ "$(jq -r '.type' <<<"$bench_record")" = "bench" ] || fail "bench soak-log record missing type:bench (got: $bench_record)"
[ "$(jq -r '.scale' <<<"$bench_record")" = "1" ] || fail "bench soak-log record scale mismatch (got: $bench_record)"
[ "$(jq -r '.query_ms.resume' <<<"$bench_record")" = "100" ] || fail "bench soak-log record resume timing mismatch (got: $bench_record)"
[ "$(jq -r '.query_ms."status-drift"' <<<"$bench_record")" = "10" ] || fail "bench soak-log record status-drift timing mismatch (got: $bench_record)"
[ "$(jq -c '.slow_queries' <<<"$bench_record")" = '["resume"]' ] || fail "bench should name only resume as the slow query at this scale (got: $bench_record)"
echo "PASS: bench --scale N — captures one {day, type:bench, query_ms, slow_queries} record naming the first query to exceed STATE_GRAPH_QUERY_SLOW_MS"

# =============================================================================
# bench --scale N with a non-integer STATE_GRAPH_QUERY_SLOW_MS override warns
# and falls back to the config default (500) instead of dying mid-run after
# the summary line has already printed. Own deterministic _sg_now_ms (a
# constant — this fixture only cares that the run COMPLETES and records, not
# about specific query timings) rather than reusing the exhausted disk-backed
# sequence above, since `_sg_now_ms` has no per-test reset otherwise.
# =============================================================================
fresh_cache bench-bad-slow-ms
_board_gh() {
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_soak_day() { echo "2026-01-21"; }
_sg_now_ms() { echo 0; }
export STATE_GRAPH_QUERY_SLOW_MS=500ms
rc=0; bad_slow_out="$(cmd_bench --scale 1 --board "$BOARD" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "bench with a non-integer STATE_GRAPH_QUERY_SLOW_MS should still complete (rc=$rc, out: $bad_slow_out)"
printf '%s' "$bad_slow_out" | grep -F -- 'STATE_GRAPH_QUERY_SLOW_MS' >/dev/null || fail "bench with a non-integer STATE_GRAPH_QUERY_SLOW_MS should warn on stderr (got: $bad_slow_out)"
printf '%s' "$bad_slow_out" | grep -E 'build_ms=[0-9]+' >/dev/null || fail "bench should still print its summary line (got: $bad_slow_out)"
bad_slow_logf="$(cache_snapshot_file "$BOARD" state-graph-soak)"
bad_slow_record="$(tail -1 "$bad_slow_logf")"
[ "$(jq -r '.type' <<<"$bad_slow_record")" = "bench" ] || fail "bench with a bad slow-ms override should still append a soak-log record (got: $bad_slow_record)"
[ "$(jq -r '.slow_ms' <<<"$bad_slow_record")" = "500" ] || fail "bench should fall back to the default slow_ms=500 on a bad override (got: $bad_slow_record)"
unset -f _sg_now_ms
unset STATE_GRAPH_QUERY_SLOW_MS
echo "PASS: bench — a non-integer STATE_GRAPH_QUERY_SLOW_MS warns and falls back to the default instead of dying mid-run"

# =============================================================================
# CLI dispatch — invoked as a real subprocess, zero network reached
# (mirrors test_state_graph_queries.sh's cmd_query CLI section exactly)
# =============================================================================
STATE_GRAPH_BIN="$HERE/../state-graph.sh"
CLI_TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$CLI_TMP"' EXIT

NETWORK_CANARY="$CLI_TMP/network-canary.log"
SHIM_BIN="$CLI_TMP/shim-bin"
mkdir -p "$SHIM_BIN"
for _shim_cmd in gh git tmux; do
  cat >"$SHIM_BIN/$_shim_cmd" <<SHIMEOF
#!/usr/bin/env bash
echo "CANARY: $_shim_cmd \$*" >>"$NETWORK_CANARY"
exit 1
SHIMEOF
  chmod +x "$SHIM_BIN/$_shim_cmd"
done
SHIM_PATH="$SHIM_BIN:$PATH"

echo "── soak CLI: --help prints usage naming --count (THE class-A activation predicate, run verbatim) ──"
PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" soak --help 2>/dev/null | grep -- '--count' >/dev/null \
  || fail "the exact activation-gate predicate (soak --help | grep -q -- '--count') failed"
echo "PASS: soak CLI — --help satisfies the class-A activation predicate verbatim"

echo "── soak CLI: --help exits 0 ──"
rc=0; PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" soak --help >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "soak --help should exit 0 (got rc=$rc)"
echo "PASS: soak CLI — --help exits 0"

echo "── soak CLI: missing --board exits 2 ──"
rc=0; out="$(PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" soak 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "missing --board did not exit 2 (got rc=$rc, out: $out)"
echo "PASS: soak CLI — missing --board exits 2"

echo "── soak CLI: --audit with no --items exits 2 ──"
rc=0; out="$(PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" soak --audit --board 4 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "soak --audit with no --items did not exit 2 (got rc=$rc, out: $out)"
printf '%s' "$out" | grep -F -- '--items' >/dev/null || fail "soak --audit error did not name the missing --items flag (got: $out)"
echo "PASS: soak CLI — --audit with no --items exits 2"

echo "── soak CLI: an unknown arg exits 2 ──"
rc=0; out="$(PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" soak --board 4 --bogus 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "an unknown soak arg did not exit 2 (got rc=$rc, out: $out)"
echo "PASS: soak CLI — an unknown arg exits 2"

if [ -s "$NETWORK_CANARY" ]; then
  fail "a soak CLI subprocess reached a real gh/git/tmux binary instead of exiting on validation (canary: $(cat "$NETWORK_CANARY"))"
fi
echo "PASS: soak CLI — zero network reached across every subprocess case (shim canary empty)"

echo "ALL PASS: test_state_graph_soak.sh"
