#!/usr/bin/env bash
#
# Fixture-replay tests for scripts/reconcile.sh. Zero network, zero real tmux:
# we SOURCE reconcile.sh (its execute-guard suppresses the auto-run when sourced)
# and then override its two seams —
#   - board reads:  board.sh's `_board_gh` (the same seam test_board_replay uses)
#   - tmux reads:   reconcile.sh's `_reconcile_tmux`
# — to inject canned board item-lists and canned @claimed_issue marker lines.
# Each case drives reconcile_main / status_reconcile_main and asserts the
# human-readable report contains (or omits) the expected drift lines. The status
# lens also reads canned `issue list` / `pr list` and records `project item-edit`
# writes through the same _board_gh seam.
#
# Covered — Lens 1 (marker drift):
#   1) marker-without-board  — local marker for an issue the board does not have
#      In Progress for this host.
#   2) board-without-marker  — board In Progress for this host, no live marker.
#   3) in sync               — every marker matches a board claim and vice versa.
# Covered — Lens 2 (status drift):
#   1) terminal-but-not-Done — closed/merged backing, flagged; --fix moves to Done.
#   2) orphaned In-Progress + unresolved — reported, never auto-fixed.
#   3) in sync               — every item's status matches its GitHub state.
#   4) stale claim (GH #85)  — same-host stamp, DEAD session → flagged, never
#      auto-fixed; a same-host LIVE claim is NOT flagged.
#   5) foreign claim         — stamped to another host → reported, never released
#      from here (no liveness call; foreign wins even if told the session is dead).
#   6) terminal beats stale  — a closed-backed In-Progress dead-stamp item is
#      classed terminal, not stale (jq branch priority).
# The session-liveness oracle (_reconcile_session_live) is the THIRD seam these
# tests override — data-driven by DEAD_SESSIONS, zero filesystem dependence.
#
# FIX is read by status_reconcile_main in the sourced reconcile.sh, not in this
# file — shellcheck can't see that cross-file use, so silence SC2034 file-wide
# (the directive must precede the first command). CI excludes tests/ anyway.
# shellcheck disable=SC2034
set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf — a consumer's committed
# cutover flip (e.g. stageFind's board.3.backend=issues) or a driver host's
# machine-level conf would silently change canned-fixture resolution.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null


HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

# Pin the host so the test is deterministic regardless of the runner's hostname.
export SUBSET_HOST_LABEL="testhost"
# Pretend we are inside tmux so reconcile reads markers (the value is unused —
# _reconcile_tmux is fully overridden below).
export TMUX="fake-socket,0,0"
# Isolated cache dir (not the real TMPDIR) so the live-pin case below (which
# plants a fake on-disk cache file) can never collide with another test/run's
# cache files.
BOARD_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reconcile-cache-test-XXXXXX")"
export BOARD_CACHE_DIR
trap 'rm -rf "$BOARD_CACHE_DIR"' EXIT

# shellcheck source=scripts/reconcile.sh
source "$SCRIPTS_DIR/reconcile.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

# board.sh sets BOARD_OWNER etc.; reconcile_main / status_reconcile_main call
# board_resolve which fans out to _board_gh for project view / field-list /
# item-list. The status lens additionally reads `issue list` / `pr list` and (on
# --fix) writes `project item-edit`. The field-list carries In Progress + Ready +
# Done options so board_set_status can resolve "Done" on the --fix path (the
# marker lens reads no options, so the extra ones are harmless to it).
FIELD_LIST_JSON='{"fields":[{"id":"PVTSSF_status","name":"Status","type":"ProjectV2SingleSelectField","options":[{"id":"opt_inprogress","name":"In Progress"},{"id":"opt_ready","name":"Ready"},{"id":"opt_done","name":"Done"}]},{"id":"PVTF_hostsession","name":"Host/Session","type":"ProjectV2Field"}]}'

# Set per-case before run_case (marker lens) / run_status (status lens).
ITEM_LIST_JSON=""
MARKER_LINES=""
ISSUE_LIST_JSON="[]"   # status lens: [{"number":N,"state":"OPEN|CLOSED"}]
PR_LIST_JSON="[]"      # status lens: [{"number":N,"state":"OPEN|CLOSED|MERGED"}]
EDITS="/dev/null"      # status lens: run_status repoints this to a temp file
# Stubbed session-liveness oracle (GH #85): treat every session as LIVE except
# those listed here (space-separated session ids). Default empty → all live, so
# the pre-existing scases (whose stamped items are all "ok/live") pass unchanged;
# a stale-claim case sets it to mark a specific session dead. This fully replaces
# the real _reconcile_session_live (no filesystem / transcript dependence).
DEAD_SESSIONS=""

# Override the board seam: replay canned JSON for every read, and RECORD each
# item-edit's --id (the only write, issued by the --fix path) to $EDITS.
_board_gh() {
  case "$1 $2" in
    "project view")       echo '{"id":"PVT_TESTPROJECT"}' ;;
    "project field-list") printf '%s' "$FIELD_LIST_JSON" ;;
    "project item-list")  printf '%s' "$ITEM_LIST_JSON" ;;
    "issue list")         printf '%s' "$ISSUE_LIST_JSON" ;;
    "pr list")            printf '%s' "$PR_LIST_JSON" ;;
    "project item-edit")
      local a want=0
      for a in "$@"; do
        if [ "$want" = 1 ]; then printf '%s\n' "$a" >>"$EDITS"; want=0; continue; fi
        [ "$a" = "--id" ] && want=1
      done
      return 0 ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}

# Override the tmux seam: emit canned `@claimed_issue` values, one per line, the
# way `tmux list-windows -a -F '#{@claimed_issue}'` would (empty lines for
# windows with no marker are included to mirror reality).
_reconcile_tmux() {
  printf '%s' "$MARKER_LINES"
}

# Run reconcile_main with the current ITEM_LIST_JSON / MARKER_LINES and capture
# its stdout into $OUT.
run_case() {
  OUT="$(reconcile_main)"
}

# --- case 1: marker-without-board ---------------------------------------------
# Board: #500 In Progress on a DIFFERENT host; #501 only Ready. Local marker for
# #500 → stale (wrong host); local marker for #777 → stale (not on board at all).
ITEM_LIST_JSON='{"items":[
  {"id":"i500","content":{"number":500,"title":"Claimed elsewhere"},"status":"In Progress","host/Session":"otherhost:dead1234"},
  {"id":"i501","content":{"number":501,"title":"Just ready"},"status":"Ready"}
]}'
MARKER_LINES='#500 Claimed elsewhere
#777 phantom local claim
'
run_case
printf '%s' "$OUT" | grep -q "marker-without-board" \
  || fail "case1: expected a marker-without-board section\n$OUT"
printf '%s' "$OUT" | grep -q "#500 — In Progress on the board but stamped to 'otherhost'" \
  || fail "case1: expected #500 wrong-host drift line\n$OUT"
printf '%s' "$OUT" | grep -q "#777 — marker set locally, but #777 is NOT In Progress" \
  || fail "case1: expected #777 not-on-board drift line\n$OUT"
printf '%s' "$OUT" | grep -q "In sync" \
  && fail "case1: must NOT report in-sync when drift exists\n$OUT"
# Nothing on this host claimed → no board-without-marker section.
printf '%s' "$OUT" | grep -q "board-without-marker" \
  && fail "case1: unexpected board-without-marker section\n$OUT"
echo "PASS: case 1 marker-without-board (wrong host + not-on-board) reported"

# --- case 2: board-without-marker ---------------------------------------------
# Board: #600 In Progress stamped to THIS host (testhost), but NO live marker.
ITEM_LIST_JSON='{"items":[
  {"id":"i600","content":{"number":600,"title":"Claimed here, parked"},"status":"In Progress","host/Session":"testhost:abcd1234"}
]}'
MARKER_LINES=''   # no live markers at all (e.g. after release.sh)
run_case
printf '%s' "$OUT" | grep -q "board-without-marker" \
  || fail "case2: expected a board-without-marker section\n$OUT"
printf '%s' "$OUT" | grep -q "#600 — In Progress on the board (this host) but NO live tmux marker — Claimed here, parked" \
  || fail "case2: expected #600 board-without-marker line with title\n$OUT"
printf '%s' "$OUT" | grep -q "marker-without-board" \
  && fail "case2: unexpected marker-without-board section\n$OUT"
printf '%s' "$OUT" | grep -q "In sync" \
  && fail "case2: must NOT report in-sync when drift exists\n$OUT"
echo "PASS: case 2 board-without-marker (claimed here, no live marker) reported"

# --- case 3: fully in sync ----------------------------------------------------
# Board: #700 In Progress on THIS host; a live marker for #700 holds it. Also an
# item on another host (#701) with no local marker — correctly NOT flagged since
# it is not this host's claim. Result: no drift in either direction.
ITEM_LIST_JSON='{"items":[
  {"id":"i700","content":{"number":700,"title":"Working it now"},"status":"In Progress","host/Session":"testhost:beef5678"},
  {"id":"i701","content":{"number":701,"title":"Someone else"},"status":"In Progress","host/Session":"otherhost:cafe9999"}
]}'
MARKER_LINES='#700 Working it now
'
run_case
printf '%s' "$OUT" | grep -q "In sync" \
  || fail "case3: expected an in-sync all-clear\n$OUT"
printf '%s' "$OUT" | grep -q "marker-without-board" \
  && fail "case3: unexpected marker-without-board section\n$OUT"
printf '%s' "$OUT" | grep -q "board-without-marker" \
  && fail "case3: unexpected board-without-marker section\n$OUT"
echo "PASS: case 3 fully in-sync all-clear (other host's claim not mis-flagged)"

echo
echo "=== Lens 2: status drift (status_reconcile_main) ==="

# Status reconcile resolves the board, bulk-reads issue+PR state, and (with --fix)
# writes Done — all through the shared _board_gh seam above. run_status repoints
# $EDITS at a fresh temp file so each case can assert which items were edited.
run_status() { EDITS="$(mktemp)"; OUT="$(status_reconcile_main)"; }

# Override the liveness seam: deterministic, data-driven by DEAD_SESSIONS. A
# session id in that list is DEAD (return 1); everything else is LIVE (return 0).
# Mirrors how _reconcile_tmux is overridden for the marker lens.
_reconcile_session_live() {
  case " $DEAD_SESSIONS " in
    *" $1 "*) return 1 ;;
    *)        return 0 ;;
  esac
}

# Pin "now" so the foreign-claim age cases (GH #152) are hermetic regardless of the
# wall clock — AND independent of the parser. FAKE_NOW is a LITERAL true-UTC epoch
# (2026-06-07T00:00:00Z = 1780790400), NOT _reconcile_epoch_of's output: deriving it
# from the same parser would let any timezone skew in the parser cancel itself and
# escape detection. With a literal here, a parser that mis-handles the trailing 'Z'
# as local time (the BSD `date -j -f` footgun) shifts upd_epoch but not now, so the
# age math — and scase7's exact-day assertion — catches the regression.
FAKE_NOW=1780790400
_reconcile_now() { echo "$FAKE_NOW"; }

# Directly assert the portable parser yields TRUE UTC (not host-local): the same
# instant must round-trip to FAKE_NOW regardless of the runner's $TZ.
[ "$(_reconcile_epoch_of 2026-06-07T00:00:00Z)" = "$FAKE_NOW" ] \
  || fail "setup: _reconcile_epoch_of must parse ISO-Z as UTC (got $(_reconcile_epoch_of 2026-06-07T00:00:00Z), want $FAKE_NOW) — timezone skew?"

# --- status case 1: terminal-but-not-Done, with --fix -------------------------
# #200 merged PR at (none) status, #201 closed issue still Ready → both terminal.
# #202 merged PR already Done (ok). #203 open issue claimed (ok). --fix moves the
# two terminal items to Done; the ok items are untouched.
ITEM_LIST_JSON='{"items":[
  {"id":"PVTI_it200","content":{"number":200,"title":"Merged PR, no status"}},
  {"id":"PVTI_it201","content":{"number":201,"title":"Closed issue still Ready"},"status":"Ready"},
  {"id":"PVTI_it202","content":{"number":202,"title":"Merged PR already Done"},"status":"Done"},
  {"id":"PVTI_it203","content":{"number":203,"title":"Open, claimed"},"status":"In Progress","host/Session":"testhost:abcd1234"}
]}'
ISSUE_LIST_JSON='[{"number":201,"state":"CLOSED"},{"number":203,"state":"OPEN"}]'
PR_LIST_JSON='[{"number":200,"state":"MERGED"},{"number":202,"state":"MERGED"}]'
FIX=1
run_status
printf '%s' "$OUT" | grep -q "terminal-but-not-Done" || fail "scase1: expected terminal section\n$OUT"
# Exact field alignment: #200 has NO board status, so its row has an empty middle
# field — assert the backing state and the '(none)' status land in the right slots
# (guards the IFS=tab empty-field-collapse bug).
printf '%s' "$OUT" | grep -q "#200 — backing MERGED but board status '(none)'" \
  || fail "scase1: #200 fields misaligned (empty-status collapse?)\n$OUT"
printf '%s' "$OUT" | grep -q "#201 — backing CLOSED but board status 'Ready'" \
  || fail "scase1: #201 (closed Ready) should be flagged with aligned fields\n$OUT"
printf '%s' "$OUT" | grep -q "✓ #200 → Done" || fail "scase1: --fix should move #200 to Done\n$OUT"
printf '%s' "$OUT" | grep -q "✓ #201 → Done" || fail "scase1: --fix should move #201 to Done\n$OUT"
grep -qx "PVTI_it202" "$EDITS" && fail "scase1: #202 already Done must not be edited\n$(cat "$EDITS")"
grep -qx "PVTI_it203" "$EDITS" && fail "scase1: #203 open/ok must not be edited\n$(cat "$EDITS")"
printf '%s' "$OUT" | grep -q "In sync" && fail "scase1: must not report in-sync with drift\n$OUT"
FIX=0
echo "PASS: status case 1 terminal-but-not-Done flagged + --fix moves them to Done"

# --- status case 2: orphaned In-Progress + unresolved (report-only) -----------
# #300 In Progress with empty Host/Session → orphan (NOT auto-fixed). #301 claimed
# to this host with a LIVE session (DEAD_SESSIONS empty) → ok, not flagged. #302
# Ready but in neither list → unresolved.
ITEM_LIST_JSON='{"items":[
  {"id":"PVTI_it300","content":{"number":300,"title":"Orphaned claim"},"status":"In Progress","host/Session":""},
  {"id":"PVTI_it301","content":{"number":301,"title":"Properly claimed"},"status":"In Progress","host/Session":"testhost:dead1234"},
  {"id":"PVTI_it302","content":{"number":302,"title":"Unknown to GH"},"status":"Ready"}
]}'
ISSUE_LIST_JSON='[{"number":300,"state":"OPEN"},{"number":301,"state":"OPEN"}]'
PR_LIST_JSON='[]'
FIX=1   # even with --fix, orphan and unknown are report-only
run_status
printf '%s' "$OUT" | grep -q "orphaned In-Progress" || fail "scase2: expected orphan section\n$OUT"
printf '%s' "$OUT" | grep -q "#300" || fail "scase2: #300 orphan should be flagged\n$OUT"
printf '%s' "$OUT" | grep -q "#301" && fail "scase2: #301 (live stamped) must not be flagged\n$OUT"
printf '%s' "$OUT" | grep -q "^stale claims" && fail "scase2: a live same-host claim must not be classed stale\n$OUT"
printf '%s' "$OUT" | grep -q "unresolved" || fail "scase2: expected unresolved section\n$OUT"
printf '%s' "$OUT" | grep -q "#302" || fail "scase2: #302 unknown should be flagged\n$OUT"
grep -qx "PVTI_it300" "$EDITS" && fail "scase2: orphan #300 must NEVER be auto-edited\n$(cat "$EDITS")"
[ ! -s "$EDITS" ] || fail "scase2: no item-edit should fire (no terminal items)\n$(cat "$EDITS")"
FIX=0
echo "PASS: status case 2 orphan + unresolved reported, never auto-fixed"

# --- status case 3: fully in sync ---------------------------------------------
# #400 merged PR already Done; #401 open issue Ready; #402 open issue claimed. No
# drift in any class.
ITEM_LIST_JSON='{"items":[
  {"id":"PVTI_it400","content":{"number":400,"title":"Done merged PR"},"status":"Done"},
  {"id":"PVTI_it401","content":{"number":401,"title":"Open, ready"},"status":"Ready"},
  {"id":"PVTI_it402","content":{"number":402,"title":"Open, claimed"},"status":"In Progress","host/Session":"testhost:beef5678"}
]}'
ISSUE_LIST_JSON='[{"number":401,"state":"OPEN"},{"number":402,"state":"OPEN"}]'
PR_LIST_JSON='[{"number":400,"state":"MERGED"}]'
FIX=0
run_status
printf '%s' "$OUT" | grep -q "In sync" || fail "scase3: expected in-sync all-clear\n$OUT"
printf '%s' "$OUT" | grep -q "terminal-but-not-Done" && fail "scase3: unexpected terminal section\n$OUT"
printf '%s' "$OUT" | grep -q "orphaned In-Progress" && fail "scase3: unexpected orphan section\n$OUT"
printf '%s' "$OUT" | grep -q "^stale claims" && fail "scase3: unexpected stale section\n$OUT"
echo "PASS: status case 3 fully in-sync all-clear"

# --- status case 4: stale claim — same-host stamp, DEAD session (GH #85) -------
# #800 In Progress stamped to THIS host but its session is dead → stale claim,
# report-only (never auto-edited, even with --fix). #801 same host but LIVE → ok.
ITEM_LIST_JSON='{"items":[
  {"id":"PVTI_it800","content":{"number":800,"title":"Stranded by a dead run"},"status":"In Progress","host/Session":"testhost:dead0001"},
  {"id":"PVTI_it801","content":{"number":801,"title":"Actively worked"},"status":"In Progress","host/Session":"testhost:live0001"}
]}'
ISSUE_LIST_JSON='[{"number":800,"state":"OPEN"},{"number":801,"state":"OPEN"}]'
PR_LIST_JSON='[]'
DEAD_SESSIONS="dead0001"
FIX=1
run_status
printf '%s' "$OUT" | grep -q "^stale claims" || fail "scase4: expected stale section\n$OUT"
printf '%s' "$OUT" | grep -q "#800 — stamped 'testhost:dead0001'" \
  || fail "scase4: #800 stale should be flagged with its stamp\n$OUT"
printf '%s' "$OUT" | grep -q "#801" && fail "scase4: #801 (live same-host) must not be flagged\n$OUT"
[ ! -s "$EDITS" ] || fail "scase4: stale claim must NEVER be auto-edited\n$(cat "$EDITS")"
DEAD_SESSIONS=""; FIX=0
echo "PASS: status case 4 stale same-host claim flagged (live one not), never auto-fixed"

# --- status case 5: foreign claim — stamped to ANOTHER host (report-only) ------
# #900 In Progress stamped to a different host → liveness unverifiable here, so it
# is reported under foreign and NEVER released from this machine — even though the
# local oracle is told its session id is dead (foreign wins, no liveness call).
ITEM_LIST_JSON='{"items":[
  {"id":"PVTI_it900","content":{"number":900,"title":"Owned by another host"},"status":"In Progress","host/Session":"otherhost:abcd0001"}
]}'
ISSUE_LIST_JSON='[{"number":900,"state":"OPEN"}]'
PR_LIST_JSON='[]'
DEAD_SESSIONS="abcd0001"
FIX=1
run_status
printf '%s' "$OUT" | grep -q "^foreign claims" || fail "scase5: expected foreign section\n$OUT"
printf '%s' "$OUT" | grep -q "#900 — stamped 'otherhost:abcd0001' (host 'otherhost'" \
  || fail "scase5: #900 foreign should name the owning host\n$OUT"
printf '%s' "$OUT" | grep -q "^stale claims" && fail "scase5: foreign must not be classed stale\n$OUT"
[ ! -s "$EDITS" ] || fail "scase5: foreign claim must NEVER be auto-edited\n$(cat "$EDITS")"
DEAD_SESSIONS=""; FIX=0
echo "PASS: status case 5 foreign claim reported (host-aware), never released here"

# --- status case 6: terminal beats stale (jq branch priority) -----------------
# #1000 In Progress stamped to a DEAD same-host session, but its backing issue is
# CLOSED → must classify terminal (work is done), NOT stale.
ITEM_LIST_JSON='{"items":[
  {"id":"PVTI_it1000","content":{"number":1000,"title":"Closed but still In Progress"},"status":"In Progress","host/Session":"testhost:dead0002"}
]}'
ISSUE_LIST_JSON='[{"number":1000,"state":"CLOSED"}]'
PR_LIST_JSON='[]'
DEAD_SESSIONS="dead0002"
FIX=0
run_status
printf '%s' "$OUT" | grep -q "terminal-but-not-Done" || fail "scase6: closed-backed item should be terminal\n$OUT"
printf '%s' "$OUT" | grep -q "#1000" || fail "scase6: #1000 should be flagged terminal\n$OUT"
printf '%s' "$OUT" | grep -q "^stale claims" && fail "scase6: terminal must take priority over stale\n$OUT"
DEAD_SESSIONS=""
echo "PASS: status case 6 terminal-but-not-Done beats stale (priority)"

# --- status case 7: foreign claim STALE — old issue activity → escalated (GH #152) -
# #910 foreign (another host), backing issue last updated 37d before the pinned now
# → escalated to the louder "foreign claims (STALE …)" bucket. Report-only: never
# auto-edited even with --fix (releasing another host's claim is never automated).
ITEM_LIST_JSON='{"items":[
  {"id":"PVTI_it910","content":{"number":910,"title":"Stranded on a dead host"},"status":"In Progress","host/Session":"deadhost:abcd9100"}
]}'
ISSUE_LIST_JSON='[{"number":910,"state":"OPEN","updatedAt":"2026-05-01T00:00:00Z"}]'
PR_LIST_JSON='[]'
FIX=1
run_status
printf '%s' "$OUT" | grep -q "^foreign claims (STALE" || fail "scase7: expected STALE foreign section\n$OUT"
printf '%s' "$OUT" | grep -q "#910 — stamped 'deadhost:abcd9100' (host 'deadhost')" \
  || fail "scase7: #910 should name the owning host\n$OUT"
# Exact day count (2026-05-01 → pinned 2026-06-07 = 37d). Asserting the EXACT value,
# not a range, is what catches a parser timezone regression (local-time parse → 36d).
printf '%s' "$OUT" | grep -q "no activity for 37d" \
  || fail "scase7: #910 should report exactly 37d stale (timezone skew if off-by-one?)\n$OUT"
[ ! -s "$EDITS" ] || fail "scase7: a stale foreign claim must NEVER be auto-edited\n$(cat "$EDITS")"
FIX=0
echo "PASS: status case 7 stale foreign claim escalated, never auto-released"

# --- status case 8: foreign RECENT + fail-safe — stay in the plain foreign bucket -
# #911 foreign, backing issue updated 2d ago → recent, plain "foreign claims" (not
# escalated). #912 foreign with NO updatedAt available → fail safe to plain foreign
# (never escalate on missing data, never crash).
ITEM_LIST_JSON='{"items":[
  {"id":"PVTI_it911","content":{"number":911,"title":"Actively worked elsewhere"},"status":"In Progress","host/Session":"otherhost:abcd9110"},
  {"id":"PVTI_it912","content":{"number":912,"title":"Foreign, no updatedAt"},"status":"In Progress","host/Session":"otherhost:abcd9120"}
]}'
ISSUE_LIST_JSON='[{"number":911,"state":"OPEN","updatedAt":"2026-06-05T00:00:00Z"},{"number":912,"state":"OPEN"}]'
PR_LIST_JSON='[]'
FIX=1
run_status
printf '%s' "$OUT" | grep -q "^foreign claims (In Progress" || fail "scase8: expected plain foreign section\n$OUT"
printf '%s' "$OUT" | grep -q "#911" || fail "scase8: #911 recent should be plain foreign\n$OUT"
printf '%s' "$OUT" | grep -q "#912" || fail "scase8: #912 (no updatedAt) should fail safe to plain foreign\n$OUT"
printf '%s' "$OUT" | grep -q "^foreign claims (STALE" \
  && fail "scase8: neither recent nor missing-updatedAt foreign should escalate\n$OUT"
[ ! -s "$EDITS" ] || fail "scase8: foreign claims must NEVER be auto-edited\n$(cat "$EDITS")"
FIX=0
echo "PASS: status case 8 recent + missing-updatedAt foreign stay plain (no escalation), never edited"

echo
echo "=== Lens 3: the live-read pin (reconcile.sh must never read through the cache) ==="

# --- live-pin case: a FRESH but WRONG on-disk items cache must be ignored -----
# reconcile.sh's own `export BOARD_CACHE_TTL=0` (see its header comment) is the
# ONE thing standing between "always live" and "drift detector fed stale data,
# self-defeating". Prove it behaviorally, not just by grepping the source: seed
# a cache file that is FRESH (age 0, well within any normal TTL) but WRONG (it
# does not have #950 In Progress at all) — if BOARD_CACHE_TTL=0 were ever
# dropped/shadowed, _board_cached_read would see this fresh file and serve it
# instead of calling _board_gh, and the report below would flip from "in sync"
# to a false marker-without-board drift.
[ "$BOARD_CACHE_TTL" = "0" ] \
  || fail "setup: reconcile.sh must pin BOARD_CACHE_TTL=0 (got '$BOARD_CACHE_TTL') — see reconcile.sh's live-read-pin comment"

STALE_CACHE_FILE="$BOARD_CACHE_DIR/subset-board-3-items.json"
printf '%s' '{"items":[]}' >"$STALE_CACHE_FILE"   # wrong: #950 missing entirely
touch "$STALE_CACHE_FILE"                          # age 0 — "fresh" by any normal TTL

# The LIVE truth (what _board_gh actually returns for `project item-list`):
# #950 In Progress on THIS host, matched by a live tmux marker → should be "in
# sync", not a marker-without-board drift.
ITEM_LIST_JSON='{"items":[
  {"id":"i950","content":{"number":950,"title":"Live truth item"},"status":"In Progress","host/Session":"testhost:live0001"}
]}'
MARKER_LINES='#950 Live truth item
'
run_case
printf '%s' "$OUT" | grep -q "In sync" \
  || fail "live-pin: expected 'in sync' from the LIVE #950 claim — got (possibly cache-served):\n$OUT"
printf '%s' "$OUT" | grep -q "marker-without-board" \
  && fail "live-pin: #950 flagged marker-without-board — the FRESH stale cache file was served instead of a live read:\n$OUT"

# The cache file must still be untouched (BOARD_CACHE_TTL=0 also means the read
# path never WRITES the cache — see _board_cached_read's `[ "$ttl" -gt 0 ]` write
# guard) — confirms this run never went through the cache in either direction.
[ "$(cat "$STALE_CACHE_FILE")" = '{"items":[]}' ] \
  || fail "live-pin: the on-disk cache file was rewritten — a live-only read must never touch it\n$(cat "$STALE_CACHE_FILE")"
echo "PASS: live-pin — a fresh-but-wrong on-disk cache file is ignored; reconcile always reads live"

echo
echo "PASS: all reconcile.sh drift-detection assertions passed"
