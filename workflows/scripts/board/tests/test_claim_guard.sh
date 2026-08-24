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
#   7) Distinguish ABSENT-from-the-pool from PRESENT-and-unstamped (case 10),
#      survive an UNPARSEABLE pool without aborting mid-partition (case 11), and
#      answer an EMPTY candidate set with a SUMMARY (case 12) — the three ways
#      the guard could stop being safe without any verdict looking wrong.
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

# ONE scratch root for every temp artifact this file creates (the cache dir plus
# the per-case gh-call logs), reaped by a `trap … EXIT` like every sibling suite
# (test_claim_marker.sh:38, test_capture.sh, test_boards_conf.sh). The trap — not
# a tidy-up at the bottom of the file — is the point: `fail()` exits from
# mid-file, and that early-exit path is exactly the one that leaks. `make
# test-board` runs on every `checks` invocation, and bare BSD `mktemp` on macOS
# ignores $TMPDIR (it uses the Darwin per-user temp dir), so a TMPDIR-scoped CI
# sandbox would not sweep these for us either.
SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
# Keep cache busts off the real cache dir.
BOARD_CACHE_DIR="$SCRATCH/board-cache"; mkdir -p "$BOARD_CACHE_DIR"; export BOARD_CACHE_DIR

# shellcheck source=scripts/claim-guard.sh
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/claim-guard.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

POOL=""            # per-case: the synthetic pool's items JSON array body
RAW_ITEMS=""       # per-case: when set, used VERBATIM as BOARD_ITEMS_JSON
RESOLVE_RC=0       # per-case: 1 makes board_resolve fail (offline/auth case)
GH_CALLS=""        # per-case: temp file recording every _board_gh call

# Inject the synthetic pool — claim_guard_main calls this instead of the real
# whole-board read. Sets the same globals the real board_resolve does, including
# the vestigial-but-still-set BOARD_PROJECT_ID / BOARD_FIELDS_JSON.
#
# $RAW_ITEMS is the escape hatch for the malformed-pool case: a resolve that
# SUCCEEDS while handing back a body jq cannot parse is a different failure from
# a resolve that fails, and only the raw form can express it.
board_resolve() {
  [ "$RESOLVE_RC" = 0 ] || return 1
  BOARD_PROJECT_ID=""
  BOARD_FIELDS_JSON='{"fields":[]}'
  if [ -n "$RAW_ITEMS" ]; then
    BOARD_ITEMS_JSON="$RAW_ITEMS"
  else
    BOARD_ITEMS_JSON="{\"items\":[${POOL}]}"
  fi
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
  GH_CALLS="$(mktemp "$SCRATCH/gh-calls.XXXXXX")"
  CLAIM_GUARD_ISSUES=("$@")
  PROJECT_NUMBER=7
  set +e
  # Drive the guard inside a subshell with `set -euo pipefail` RESTORED — the
  # shell state it actually runs under in production (its own file sets it at
  # line 1). The surrounding `set +e` exists only so a failing case reports
  # through fail() instead of aborting this file; leaving it in force for the
  # CALL would mask precisely the defect class case 11 tests for — a bare command
  # substitution whose non-zero status `set -e` propagates, killing the partition
  # mid-loop with no verdict lines and no SUMMARY. A test that relaxes the
  # production shell options cannot see that at all.
  OUT="$(set -euo pipefail; claim_guard_main 2>/dev/null)"
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


# ── Case 10 — ABSENT from the pool is NOT `claim=none` ───────────────────────
# The fail-open hole: `select(.content.number==$n)` yields empty output for two
# states — "in the pool, unstamped" (cullable) and "not in the pool at all"
# (claim state NEVER READ, not cullable). The pool is
# `gh issue list --state open --limit "${BOARD_ITEM_LIMIT:-500}"`, so a candidate
# is absent on the most ordinary board condition there is: more than
# BOARD_ITEM_LIMIT open issues. Conflating the two culls blind.
POOL="$(item 1 'Backlog' '')"
run_guard 999
[ "$RC" = 0 ] || fail "case 10: a candidate missing from the pool must not abort the caller; got rc=$RC"
assert_line "SKIP 999 claim=unknown class=unreadable" "case 10: an issue ABSENT from the resolved pool must report unreadable, never claim=none"
printf '%s\n' "$OUT" | grep '^CULL 999 ' >/dev/null &&
  fail "case 10: the guard failed OPEN — it emitted a CULL verdict for an issue that was never in the pool:\n$OUT"
assert_line "SUMMARY cullable=0 skipped=1" "case 10: an unreadable candidate counts as skipped, not cullable"
assert_no_writes "case 10"

# The discriminating half: the SAME empty stamp on an issue that IS in the pool
# stays cullable. Without this pair, "skip everything" would also pass case 10.
POOL="$(item 999 'Backlog' '')"
run_guard 999
assert_line "CULL 999 claim=none" "case 10: a MATCHED item with an empty stamp is still cullable — absence and no-stamp are distinct"

# ── Case 11 — an UNPARSEABLE pool degrades, it does not abort mid-partition ──
# `existing="$(claim_guard_read_of "$n")"` is a printf|jq pipeline under
# `set -euo pipefail`; a bare assignment propagates its status and `set -e` kills
# the function mid-loop, emitting NO verdict lines and NO SUMMARY and exiting 5
# (or 127 with no jq). The § Exit status contract defines only 0 and 2, and
# /triage Step 4.8a has no branch for a third outcome — it would see an empty
# cull set with no diagnosis at all.
RAW_ITEMS='not json'
run_guard 1199 55 42
RAW_ITEMS=""
[ "$RC" = 0 ] || fail "case 11: an unparseable pool must still exit 0 (the contract defines only 0 and 2); got rc=$RC"
assert_line "SKIP 1199 claim=unknown class=unreadable" "case 11: every candidate must get a verdict line even when the pool will not parse"
assert_line "SKIP 55 claim=unknown class=unreadable" "case 11: the partition must not abort after the FIRST failed read"
assert_line "SKIP 42 claim=unknown class=unreadable" "case 11: the partition must reach the last candidate"
assert_line "SUMMARY cullable=0 skipped=3" "case 11: the SUMMARY must still be emitted — its absence is what leaves the caller undiagnosed"
printf '%s\n' "$OUT" | grep '^CULL ' >/dev/null &&
  fail "case 11: the guard failed OPEN — it emitted a CULL verdict from an unparseable pool"
assert_no_writes "case 11"

# ── Case 12 — an EMPTY candidate set returns a SUMMARY, not an abort ─────────
# The sourced entry point (which this file itself uses) has no usage check in
# front of it, and on bash 3.2 — macOS /bin/bash, which this suite is run under —
# `"${empty[@]}"` under `set -u` is an unbound-variable abort, not an empty
# expansion.
POOL="$(item 42 'Backlog' '')"
run_guard
[ "$RC" = 0 ] || fail "case 12: an empty candidate set must return cleanly, not abort under set -u; got rc=$RC"
assert_line "SUMMARY cullable=0 skipped=0" "case 12: an empty candidate set must still emit its SUMMARY"
assert_no_writes "case 12"

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
  # These greps search for LITERAL spec text; `$CULL_GUARD` / `$repo` are the
  # spec's own prose, not this shell's variables — single quotes are required.
  # shellcheck disable=SC2016
  grep -F '"$CULL_GUARD" --board' "$SPEC" >/dev/null ||
    fail "case 9: claude/commands/triage.md carries no claim-guard.sh invocation — the cull path is unguarded again"
  # shellcheck disable=SC2016
  guard_ln="$(grep -nF '"$CULL_GUARD" --board' "$SPEC" | head -1 | cut -d: -f1)"
  # The cull write itself — the FIRST reason-comment in the spec, which is the
  # one inside Step 4.8b. (Other `gh issue comment` calls in this spec belong to
  # unrelated steps, so anchor on the cull reason body, not the bare command.)
  # shellcheck disable=SC2016
  write_ln="$(grep -nF 'gh issue comment <n> -R "$repo" --body "<reason>"' "$SPEC" | head -1 | cut -d: -f1)"
  [ -n "$write_ln" ] ||
    fail "case 9: could not locate the cull write in $SPEC — the ordering assertion has nothing to anchor on"
  [ "$guard_ln" -lt "$write_ln" ] ||
    fail "case 9: the claim guard is invoked at line $guard_ln, AFTER the cull write at line $write_ln — it must filter the set BEFORE any close"
  grep -F 'Skipped (claimed by another session)' "$SPEC" >/dev/null ||
    fail "case 9: the run report no longer names skipped-because-claimed candidates — a refusal nobody can see is the silence temperloop#1220 exists to end"
  # The absent-guard degradation the same step promises in prose must be the
  # MECHANICAL one. An unguarded invocation surfaces as an opaque 127 in a
  # vendoring checkout carrying neither copy of the script — the shape an
  # AI-executed spec reads past on its way to culling unfiltered.
  # shellcheck disable=SC2016
  if ! grep -F 'if [ -x "$CULL_GUARD" ]; then' "$SPEC" >/dev/null ||
     ! grep -F 'cull skipped — claim-guard.sh unavailable' "$SPEC" >/dev/null; then
    fail "case 9: Step 4.8a invokes the guard without branch-guarding on its presence — the documented 'cull skipped — claim-guard.sh unavailable' degradation has no mechanical form"
  fi
  echo "PASS: test_claim_guard.sh (spec conformance)"
else
  echo "SKIP: case 9 spec conformance — claude/commands/triage.md not present in this checkout"
fi

echo "PASS: test_claim_guard.sh (CLI)"
