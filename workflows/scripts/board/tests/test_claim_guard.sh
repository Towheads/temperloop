#!/usr/bin/env bash
#
# Fixture-replay tests for scripts/claim-guard.sh — the claim-aware cull guard
# (temperloop#1220). Zero network: we SOURCE claim-guard.sh (its execute-guard
# suppresses the auto-run when sourced), override `board_resolve` to inject a
# SYNTHETIC POOL WITH PLANTED CLAIM LABELS, and override the board.sh `_board_gh`
# seam to RECORD every call — so "the guard issues no writes" is an assertion,
# not a claim.
#
# The property under test is the one the 2026-08-08 incident broke: a cull path
# that reads past a foreign `fnd:host/session:*` stamp closes an issue another
# session is building, orphaning the in-flight PR's `Closes #N`. The guard must:
#
#   1) SKIP a LIVE foreign claim (In Progress + foreign stamp) — the incident's
#      exact shape (K#1199) — and NAME it in the report.
#   2) SKIP a STALE/PARKED foreign claim (open, not In Progress, still stamped —
#      the K#1613 shape) WITHOUT blocking: it still returns, still exits 0, and
#      still emits its SUMMARY. Disposal stays /tidy's job.
#   3) CULL an issue stamped by THIS session (claim=self) and an unstamped one
#      (claim=none) — the guard refuses foreign claims, not all claims.
#   4) Issue ZERO board writes on every path — in particular it never strips a
#      foreign session's claim stamp.
#   5) FAIL SAFE, not open: an unresolvable board reports every candidate
#      `class=unreadable` (never CULL) and still exits 0.
#   6) Partition the pool exactly: cullable + skipped == candidates, in input
#      order, with every skipped issue named by number.
#
# The board_resolve override sets BOARD_* globals that board.sh accessors read in
# OTHER functions — shellcheck can't see that cross-function use, so silence
# SC2034 file-wide (cf. tests/test_claim.sh; the directive must precede the first
# command to apply to the whole file).
# shellcheck disable=SC2034
set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

# Pin BOTH halves of this session's own stamp so `claim=self` is deterministic:
# the host half via the adapter's own override seam, the session half via the
# harness variable board_own_stamp truncates to 8 chars.
export SUBSET_HOST_LABEL="testhost"
export CLAUDE_CODE_SESSION_ID="deadbeef-1111-2222-3333-444444444444"
OWN_STAMP="testhost:deadbeef"
# Keep cache busts off the real cache dir.
BOARD_CACHE_DIR="$(mktemp -d)"; export BOARD_CACHE_DIR

# shellcheck source=scripts/claim-guard.sh
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/claim-guard.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

POOL=""            # per-case: the synthetic pool's items JSON array body
RESOLVE_RC=0       # per-case: 1 makes board_resolve fail (offline/auth case)
GH_CALLS=""        # per-case: temp file recording every _board_gh call

# Inject the synthetic pool — claim_guard_main calls this instead of the real
# whole-board read. Sets the same globals the real board_resolve does, including
# the vestigial-but-still-set BOARD_PROJECT_ID / BOARD_FIELDS_JSON.
board_resolve() {
  [ "$RESOLVE_RC" = 0 ] || return 1
  BOARD_PROJECT_ID=""
  BOARD_FIELDS_JSON='{"fields":[]}'
  BOARD_ITEMS_JSON="{\"items\":[${POOL}]}"
  BOARD_CURRENT="$1"
}

# Record EVERY board call. The guard is a pure reader: any call at all is a
# regression, so this both records and hard-fails the case.
_board_gh() {
  printf '%s\n' "gh $*" >>"$GH_CALLS"
  return 0
}

# One synthetic pool item. Planting a claim = a non-empty <stamp>, exactly what
# the issues-only reshape derives from an `fnd:host/session:<stamp>` label.
#   item <issue#> <status> <stamp>
item() {
  printf '{"id":"ISSUE_%s","content":{"number":%s,"title":"synthetic #%s"},"status":"%s","host/Session":"%s"}' \
    "$1" "$1" "$1" "$2" "$3"
}

# Drive the guard over the current pool. Captures stdout; never lets a failure
# abort the test file.
run_guard() {
  GH_CALLS="$(mktemp)"
  CLAIM_GUARD_ISSUES=("$@")
  PROJECT_NUMBER=7
  set +e
  OUT="$(claim_guard_main 2>/dev/null)"
  RC=$?
  set -e
}

assert_line() {
  printf '%s\n' "$OUT" | grep -Fx -- "$1" >/dev/null ||
    fail "$2\n  expected line: $1\n  got:\n$(printf '%s\n' "$OUT" | sed 's/^/    /')"
}

assert_no_writes() {
  [ -s "$GH_CALLS" ] &&
    fail "$1 — the guard issued board calls, but it must be a pure reader:\n$(sed 's/^/    /' "$GH_CALLS")"
  return 0
}

# ── Case 1+2+3 — the mixed pool: live claim, stale claim, self, unclaimed ─────
# 1199: In Progress + FOREIGN stamp   → the incident's shape (live)
# 1613: Ready       + FOREIGN stamp   → a dead session's stranded stamp (parked)
#   55: In Progress + OUR OWN stamp   → ours to close
#   42: Backlog     + no stamp        → plainly cullable
POOL="$(item 1199 'In Progress' 'mini:f53bac70'),$(item 1613 'Ready' 'mini:6700a71d'),$(item 55 'In Progress' "$OWN_STAMP"),$(item 42 'Backlog' '')"
run_guard 1199 1613 55 42

[ "$RC" = 0 ] || fail "case 1: a pool containing claimed issues must still exit 0 (a non-zero code would abort a set -e caller mid-cull); got rc=$RC"
assert_line "SKIP 1199 claim=mini:f53bac70 class=live" "case 1: a LIVE foreign claim must be skipped and named"
assert_line "SKIP 1613 claim=mini:6700a71d class=parked" "case 2: a STALE/parked foreign claim must report-and-skip, not block"
assert_line "CULL 55 claim=self" "case 3: this session's OWN claim must not refuse the cull"
assert_line "CULL 42 claim=none" "case 3: an unstamped issue must remain cullable"
assert_line "SUMMARY cullable=2 skipped=2" "case 1-3: the summary must partition the candidate pool"
assert_no_writes "case 1-3"

# The named-in-the-report property, stated as the report reader sees it: every
# skipped issue's NUMBER is present on a SKIP line, so a run report built from
# this output cannot omit it.
printf '%s\n' "$OUT" | grep '^SKIP 1199 ' >/dev/null || fail "case 1: #1199 not named as skipped"
printf '%s\n' "$OUT" | grep '^SKIP 1613 ' >/dev/null || fail "case 2: #1613 not named as skipped"

# Input order is preserved — a report that reorders its own pool is harder to
# reconcile against the cull list it came from.
GOT_ORDER="$(printf '%s\n' "$OUT" | grep -E '^(CULL|SKIP) ' | awk '{print $2}' | tr '\n' ' ')"
[ "$GOT_ORDER" = "1199 1613 55 42 " ] || fail "case 1-3: input order not preserved; got: $GOT_ORDER"

# ── Case 4 — the stamp is never stripped ─────────────────────────────────────
# assert_no_writes above already proves no call was made at all. Pin the
# specific regression too: no `--remove-label fnd:host/session:*` may appear.
grep -q 'fnd:host/session' "$GH_CALLS" 2>/dev/null &&
  fail "case 4: the guard touched a foreign session's claim stamp"

# ── Case 5 — a claimed issue is skipped even when it is the ONLY candidate ───
# The degenerate pool: nothing survives the guard. It must still return (an
# empty cull set is a normal outcome, never a wait).
POOL="$(item 1199 'In Progress' 'mini:f53bac70')"
run_guard 1199
[ "$RC" = 0 ] || fail "case 5: an all-claimed pool must still exit 0; got rc=$RC"
assert_line "SUMMARY cullable=0 skipped=1" "case 5: an all-claimed pool must report zero cullable"
assert_no_writes "case 5"

# ── Case 6 — fail SAFE, not open: an unreadable board culls NOTHING ──────────
RESOLVE_RC=1
POOL=""
run_guard 1199 42
RESOLVE_RC=0
[ "$RC" = 0 ] || fail "case 6: an unresolvable board must not abort the caller; got rc=$RC"
assert_line "SKIP 1199 claim=unknown class=unreadable" "case 6: an unreadable board must not cull blind"
assert_line "SKIP 42 claim=unknown class=unreadable" "case 6: an unreadable board must not cull blind"
assert_line "SUMMARY cullable=0 skipped=2" "case 6: an unreadable board yields zero cullable"
printf '%s\n' "$OUT" | grep '^CULL ' >/dev/null &&
  fail "case 6: the guard failed OPEN — it emitted a CULL verdict with no readable claim state"
assert_no_writes "case 6"

# ── Case 7 — a foreign stamp on ANY status is refused ────────────────────────
# The guard must not key on In-Progress alone: board status and the claim stamp
# are independently writable, and the stamp is the lock.
for st in 'Backlog' 'Ready' 'In Progress' 'Done'; do
  POOL="$(item 900 "$st" 'other:abcd1234')"
  run_guard 900
  printf '%s\n' "$OUT" | grep '^SKIP 900 claim=other:abcd1234 ' >/dev/null ||
    fail "case 7: a foreign stamp on status '$st' was not refused:\n$OUT"
  assert_no_writes "case 7 ($st)"
done



# ── Case 8 — CLI arg validation, driven as a REAL subprocess ─────────────────
# The cases above drive claim_guard_main directly (sourced). This one exercises
# the execute-guard's own arg loop end-to-end; every assertion here exits BEFORE
# any board read, so it stays hermetic.
cli() { set +e; CLI_OUT="$(bash "$SCRIPTS_DIR/claim-guard.sh" "$@" 2>&1)"; CLI_RC=$?; set -e; }

cli
[ "$CLI_RC" = 2 ] || fail "case 8: no issues must be a usage error (rc 2), got rc=$CLI_RC"
printf '%s\n' "$CLI_OUT" | grep '^usage: claim-guard.sh ' >/dev/null ||
  fail "case 8: the no-issue error must print usage; got: $CLI_OUT"

cli --board 7 abc
[ "$CLI_RC" = 2 ] || fail "case 8: a non-numeric issue must be a usage error (rc 2), got rc=$CLI_RC"
printf '%s\n' "$CLI_OUT" | grep 'issue must be a number' >/dev/null ||
  fail "case 8: a non-numeric issue must say so; got: $CLI_OUT"

cli --board 7 --nope 1199
[ "$CLI_RC" = 2 ] || fail "case 8: an unknown flag must be a usage error (rc 2), got rc=$CLI_RC"

# ── Case 9 — SPEC CONFORMANCE: the cull path must actually INVOKE the guard ──
# The execution signal for /triage Step 4.8a's mandatory declaration
# (claude/CLAUDE.kernel.md § Mandatory-step birth rule, registered in
# workflows/scripts/config/mandatory-step-registry.tsv). A guard that exists but
# is never called is exactly the shape the birth rule exists to catch, so the
# assertion below is deliberately about the SPEC, not this script:
#   claude/commands/triage.md Step 4.8a must invoke claim-guard.sh before the cull write
# Delete the invocation from the spec, or move it below the first `gh issue
# comment` cull write, and this case goes red.
#
# Skipped (not failed) where the spec is absent: a consuming repo vendors the
# board scripts without claude/commands/, and this suite ships with them.
SPEC="$(cd "$SCRIPTS_DIR/../../.." && pwd)/claude/commands/triage.md"
if [ -f "$SPEC" ]; then
  grep -F '"$CULL_GUARD" --board' "$SPEC" >/dev/null ||
    fail "case 9: claude/commands/triage.md carries no claim-guard.sh invocation — the cull path is unguarded again"
  guard_ln="$(grep -nF '"$CULL_GUARD" --board' "$SPEC" | head -1 | cut -d: -f1)"
  # The cull write itself — the FIRST reason-comment in the spec, which is the
  # one inside Step 4.8b. (Other `gh issue comment` calls in this spec belong to
  # unrelated steps, so anchor on the cull reason body, not the bare command.)
  write_ln="$(grep -nF 'gh issue comment <n> -R "$repo" --body "<reason>"' "$SPEC" | head -1 | cut -d: -f1)"
  [ -n "$write_ln" ] ||
    fail "case 9: could not locate the cull write in $SPEC — the ordering assertion has nothing to anchor on"
  [ "$guard_ln" -lt "$write_ln" ] ||
    fail "case 9: the claim guard is invoked at line $guard_ln, AFTER the cull write at line $write_ln — it must filter the set BEFORE any close"
  grep -F 'Skipped (claimed by another session)' "$SPEC" >/dev/null ||
    fail "case 9: the run report no longer names skipped-because-claimed candidates — a refusal nobody can see is the silence temperloop#1220 exists to end"
  echo "PASS: test_claim_guard.sh (spec conformance)"
else
  echo "SKIP: case 9 spec conformance — claude/commands/triage.md not present in this checkout"
fi

echo "PASS: test_claim_guard.sh (CLI)"
