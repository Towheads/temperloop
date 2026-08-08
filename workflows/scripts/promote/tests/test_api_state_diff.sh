#!/usr/bin/env bash
#
# Tests for workflows/scripts/promote/api-state-diff.sh — the DIFF + RECORD +
# HANDOFF half of /promote's API-state story (temperloop#1236, epic #1117
# Produces 6b).
#
# THIS SUITE IS THE POINT OF THE SPLIT, same rationale as
# test_push_testbed_branch.sh: a test cannot assert against a prose step in
# claude/commands/promote.md, but it CAN assert against this script's shape.
# Three things are asserted structurally, one per acceptance behaviour:
#
#   Part A  diff-shown-before-action: `diff` is READ-ONLY (zero mutating gh
#           calls — logged and asserted, not just "should be"), and shows a
#           current-vs-proposed breakdown before anything else runs.
#   Part B  record-left-after-action: `record` is the ONLY subcommand that
#           writes, and it writes to exactly one place (an issue/PR comment,
#           or a new issue) in the TARGET repository, naming the source
#           testbed and stamping "temperloop evaluation" so a reader with no
#           context can tell where it came from.
#   Part C  the three-part report shape: migrated / re-applied / left-to-you
#           are each required, and the forbidden uniform "migration
#           complete"-shaped claim is refused structurally, not just avoided
#           by convention.
#   Part D  argument refusals (targets are never inferred; exactly one record
#           destination).
#
# Zero network throughout: a fake `gh` on PATH answers every `gh api` read
# from canned per-path output (mirroring real `gh --jq` behaviour: raw scalar
# strings, compact JSON for arrays) and logs every invocation so Part A's
# zero-write claim and Part B's single-write claim are read back from the log
# rather than trusted from the source.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$HERE/.." && pwd)/api-state-diff.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/api-state-diff-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
mkdir -p "$BIN"

# --- fake gh -----------------------------------------------------------------
# Answers `gh api <path> [--jq ...] [--paginate]` from a canned table, in the
# same shape real `gh --jq` returns (raw for a scalar, compact JSON for an
# array/object — verified against a live `gh api ... --jq` call while writing
# this suite). Also answers `gh issue comment|create` and `gh pr comment`,
# each logging its full argv (one token per line, `--END--` between calls) so
# Part B can assert exactly what was sent, and logging every invocation's
# first two tokens to a plain call log so Part A can assert NOTHING mutating
# was ever called.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ -n "${GH_CALL_LOG:-}" ]; then printf '%s\n' "$*" >> "$GH_CALL_LOG"; fi
if [ -n "${GH_ARGV_LOG:-}" ]; then
  for a in "$@"; do printf '%s\n' "$a" >> "$GH_ARGV_LOG"; done
  printf '%s\n' '--END--' >> "$GH_ARGV_LOG"
fi
case "$1" in
  api)
    path="$2"
    case "$path" in
      repos/acme/target) echo "main" ;;
      repos/acme/testbed) echo "main" ;;
      repos/acme/target/labels) echo '["bug","docs"]' ;;
      repos/acme/testbed/labels) echo '["bug","needs-triage"]' ;;
      repos/acme/target/branches/main/protection/required_status_checks/contexts) echo '["checks"]' ;;
      repos/acme/testbed/branches/main/protection/required_status_checks/contexts) echo '["checks","lint"]' ;;
      *) echo "gh: unhandled fixture path: $path" >&2; exit 1 ;;
    esac
    exit 0 ;;
  issue)
    case "$2" in
      comment) echo "https://github.com/acme/target/issues/5#issuecomment-1"; exit 0 ;;
      create) echo "https://github.com/acme/target/issues/9"; exit 0 ;;
    esac
    exit 1 ;;
  pr)
    case "$2" in
      comment) echo "https://github.com/acme/target/pull/3#issuecomment-2"; exit 0 ;;
    esac
    exit 1 ;;
esac
echo "gh: unhandled fixture invocation: $*" >&2
exit 1
GH
chmod +x "$BIN/gh"

OUT=""; RC=0
run() {  # run <script args...>
  set +e
  OUT="$(PATH="$BIN:$PATH" bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
  set -e
}

# =============================================================================
# Part D -- argument refusals. Targets and destinations are never inferred.
# =============================================================================
run diff --from acme/testbed
[ "$RC" -ne 0 ] || fail "D1: diff with no --to should refuse"
case "$OUT" in *"never inferred"*) ;; *) fail "D1: refusal should say the target is never inferred (got: $OUT)" ;; esac
echo "PASS: D1 diff refuses without --to (never inferred)"

run diff --to acme/target
[ "$RC" -ne 0 ] || fail "D2: diff with no --from should refuse"
case "$OUT" in *"proposed side is never inferred"*) ;; *) fail "D2: refusal should name --from (got: $OUT)" ;; esac
echo "PASS: D2 diff refuses without --from (never inferred)"

run diff --to not-a-slug --from acme/testbed
[ "$RC" -ne 0 ] || fail "D3: a malformed --to should be refused"
echo "PASS: D3 diff refuses a --to that is not owner/name"

run record --to acme/target --testbed-repo acme/testbed --migrated a --reapplied b --left c \
  --issue 1 --pr 2
[ "$RC" -ne 0 ] || fail "D4: record with two destinations should refuse"
case "$OUT" in *"exactly one of"*) ;; *) fail "D4: refusal should name the exactly-one rule (got: $OUT)" ;; esac
echo "PASS: D4 record refuses when more than one destination is given"

run record --to acme/target --testbed-repo acme/testbed --migrated a --reapplied b --left c
[ "$RC" -ne 0 ] || fail "D5: record with zero destinations should refuse"
case "$OUT" in *"exactly one of"*) ;; *) fail "D5: refusal should name the exactly-one rule (got: $OUT)" ;; esac
echo "PASS: D5 record refuses when no destination is given"

run record --to acme/target --testbed-repo acme/testbed --migrated a --reapplied b --left c --create-issue
[ "$RC" -ne 0 ] || fail "D6: --create-issue with no --title should refuse"
case "$OUT" in *"--title"*) ;; *) fail "D6: refusal should name --title (got: $OUT)" ;; esac
echo "PASS: D6 record refuses --create-issue without --title"

# =============================================================================
# Part A -- diff-shown-before-action: READ-ONLY, current-vs-proposed, before
# anything else in the promotion flow acts.
# =============================================================================
CALL_LOG="$TMP/gh-calls.log"
: > "$CALL_LOG"
set +e
OUT="$(PATH="$BIN:$PATH" GH_CALL_LOG="$CALL_LOG" bash "$SCRIPT" diff --to acme/target --from acme/testbed 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "A1: diff should succeed (got rc=$RC: $OUT)"

case "$OUT" in *"DIFF ONLY, nothing has been changed"*) ;; *) fail "A1: diff must say plainly that nothing was applied (got: $OUT)" ;; esac
case "$OUT" in *"current"*"acme/target"*) ;; *) fail "A1: diff must show the CURRENT (target) side (got: $OUT)" ;; esac
case "$OUT" in *"proposed"*"acme/testbed"*) ;; *) fail "A1: diff must show the PROPOSED (testbed) side (got: $OUT)" ;; esac
case "$OUT" in *"+ added:"*"needs-triage"*) ;; *) fail "A1: diff must call out an added label (got: $OUT)" ;; esac
case "$OUT" in *"- removed:"*"docs"*) ;; *) fail "A1: diff must call out a removed label (got: $OUT)" ;; esac
case "$OUT" in *"override a deliberate prior choice"*) ;; *) fail "A1: diff must warn the operator they may be overriding a deliberate prior choice (got: $OUT)" ;; esac
case "$OUT" in *"adopt path"*"temperloop init"*) ;; *) fail "A1: diff must name the adopt path as where re-applying actually happens (got: $OUT)" ;; esac
echo "PASS: A1 diff shows a current-vs-proposed breakdown and names the adopt path as the only place state is re-applied"

# The structural proof: zero mutating calls anywhere in the log.
if grep -Eq '(^| )(-X|--method)( |$)' "$CALL_LOG"; then
  fail "A2: diff issued a call carrying -X/--method (i.e. not a plain GET): $(cat "$CALL_LOG")"
fi
if grep -Eq '^(issue|pr) ' "$CALL_LOG"; then
  fail "A2: diff issued an issue/pr call (i.e. a write): $(cat "$CALL_LOG")"
fi
echo "PASS: A2 diff makes ZERO mutating gh calls (every logged call is a plain 'gh api' read)"

# =============================================================================
# Part B -- record-left-after-action: the ONLY write, and it lands IN the
# target repository, naming the source testbed as a temperloop evaluation.
# =============================================================================
ARGV="$TMP/argv-issue.log"
: > "$ARGV"
set +e
OUT="$(PATH="$BIN:$PATH" GH_ARGV_LOG="$ARGV" bash "$SCRIPT" record \
  --to acme/target --testbed-repo acme/target-testbed \
  --migrated "3 commits carried in PR #42" \
  --reapplied "branch protection + 2 labels (via temperloop init)" \
  --left "board column mapping" \
  --issue 5 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "B1: record --issue should succeed (got rc=$RC: $OUT)"
case "$OUT" in *"record is IN acme/target"*) ;; *) fail "B1: success output must say the record is IN the target repo (got: $OUT)" ;; esac
echo "PASS: B1 record --issue succeeds and states the record is IN the target repository"

grep -Fxq 'comment' "$ARGV" || fail "B2: gh was not invoked with 'issue comment'"
grep -Fxq '5' "$ARGV" || fail "B2: gh issue comment did not carry the target issue number"
grep -Fxq 'acme/target' "$ARGV" || fail "B2: gh issue comment did not carry --repo acme/target"
echo "PASS: B2 record --issue calls 'gh issue comment' on the named issue in the target repo"

grep -Fq 'temperloop evaluation' "$ARGV" || fail "B3: the record body omits the phrase 'temperloop evaluation'"
grep -Fq 'acme/target-testbed' "$ARGV" || fail "B3: the record body omits the source testbed name"
echo "PASS: B3 the record body names the source testbed and says it came from a temperloop evaluation"

grep -Fq '3 commits carried in PR #42' "$ARGV" || fail "B4: the record body omits the migrated text"
grep -Fq 'branch protection + 2 labels' "$ARGV" || fail "B4: the record body omits the re-applied text"
grep -Fq 'board column mapping' "$ARGV" || fail "B4: the record body omits the left-to-you text"
echo "PASS: B4 the record body carries all three of migrated / re-applied / left-to-you"

# --pr and --create-issue reach the right gh subcommand too.
: > "$ARGV"
set +e
OUT="$(PATH="$BIN:$PATH" GH_ARGV_LOG="$ARGV" bash "$SCRIPT" record \
  --to acme/target --testbed-repo acme/target-testbed \
  --migrated a --reapplied b --left c --pr 3 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "B5: record --pr should succeed (got rc=$RC: $OUT)"
grep -Fxq 'comment' "$ARGV" || fail "B5: gh was not invoked with 'pr comment'"
grep -Fxq '3' "$ARGV" || fail "B5: gh pr comment did not carry the PR number"
echo "PASS: B5 record --pr calls 'gh pr comment' on the named pull request"

: > "$ARGV"
PATH="$BIN:$PATH" GH_ARGV_LOG="$ARGV" bash "$SCRIPT" record --to acme/target --testbed-repo acme/target-testbed \
  --migrated a --reapplied b --left c --create-issue --title "API state after promotion" >/dev/null 2>&1
grep -Fxq 'create' "$ARGV" || fail "B6: gh was not invoked with 'issue create'"
grep -Fxq 'API state after promotion' "$ARGV" || fail "B6: gh issue create did not carry the --title"
echo "PASS: B6 record --create-issue calls 'gh issue create' with the given title"

# =============================================================================
# Part C -- the three-part report shape. Each part is required, and a
# uniform "migration complete"-shaped claim is refused structurally.
# =============================================================================
run report --reapplied b --left c
[ "$RC" -ne 0 ] || fail "C1: report with no --migrated should refuse"
echo "PASS: C1 report refuses a missing --migrated (no optional part)"

run report --migrated a --left c
[ "$RC" -ne 0 ] || fail "C2: report with no --reapplied should refuse"
echo "PASS: C2 report refuses a missing --reapplied (no optional part)"

run report --migrated a --reapplied b
[ "$RC" -ne 0 ] || fail "C3: report with no --left should refuse"
echo "PASS: C3 report refuses a missing --left (no optional part)"

run report --migrated "3 commits" --reapplied "labels" --left "board mapping"
[ "$RC" -eq 0 ] || fail "C4: a well-formed report should succeed (got rc=$RC: $OUT)"
case "$OUT" in *"## Migrated"*"3 commits"*) ;; *) fail "C4: missing the Migrated section (got: $OUT)" ;; esac
case "$OUT" in *"## Re-applied"*"labels"*) ;; *) fail "C4: missing the Re-applied section (got: $OUT)" ;; esac
case "$OUT" in *"## Left to you"*"board mapping"*) ;; *) fail "C4: missing the Left to you section (got: $OUT)" ;; esac
echo "PASS: C4 report renders all three distinctly-labeled sections"

# THE forbidden-claim assertion, one per slot -- a uniform "migration
# complete" claim cannot be smuggled in through ANY of the three parts.
for slot in migrated reapplied left; do
  case "$slot" in
    migrated) run report --migrated "Migration complete." --reapplied b --left c ;;
    reapplied) run report --migrated a --reapplied "Migration complete." --left c ;;
    left) run report --migrated a --reapplied b --left "Migration complete." ;;
  esac
  [ "$RC" -ne 0 ] || fail "C5 ($slot): a 'migration complete' claim in --$slot should be refused"
  case "$OUT" in *"forbidden"*) ;; *) fail "C5 ($slot): refusal must say the claim is forbidden (got: $OUT)" ;; esac
done
echo "PASS: C5 report refuses a uniform 'migration complete' claim in any of the three parts"

# Case-insensitivity: the guard is not defeated by capitalisation.
run report --migrated a --reapplied b --left "MIGRATION COMPLETE"
[ "$RC" -ne 0 ] || fail "C6: an all-caps 'MIGRATION COMPLETE' should still be refused"
echo "PASS: C6 the forbidden-claim guard is case-insensitive"

echo
echo "All api-state-diff.sh tests passed."
