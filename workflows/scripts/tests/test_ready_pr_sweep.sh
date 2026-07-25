#!/usr/bin/env bash
#
# test_ready_pr_sweep.sh — tests for workflows/scripts/ready-pr-sweep.sh, the
# read-only complete-but-unmerged-PR sweep (temperloop#721 — the drain half of
# the orphaned-PR net; canonical caller: claude/commands/tidy.md Step 3
# § Ready-but-unmerged PRs).
#
# Hermetic: a stub `gh` on PATH replays canned JSON fixtures per repo (zero
# network); repo enumeration goes through --repos and through a stub board lib
# (READY_PR_SWEEP_BOARD_LIB) exercising the board_registered_boards/board_repo
# seam. Exercises:
#   1. classification — ready / needs-rebase (BEHIND + DIRTY) / needs-attention
#      (failing + pending + green-but-BLOCKED) / skip (draft + DO-NOT-MERGE)
#   2. --format entry — a `### … Status: open` pending-decisions block iff a
#      ready/needs-rebase/needs-attention candidate exists; NOTHING when the
#      only open PRs are skip-class (nothing-when-clean)
#   3. fail-open — an erroring repo is reported and the sweep continues (exit 0)
#   4. board-lib enumeration + dedup (two boards, one repo → swept once)
#   5. read-only guarantee — the stub gh records every invocation; nothing but
#      `pr list` is ever called (no merge/close/comment/edit subcommand)
#   6. usage errors exit 2; missing board lib + no --repos fails open (exit 0)
#
# Usage: bash workflows/scripts/tests/test_ready_pr_sweep.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/ready-pr-sweep.sh"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find: $needle" ;;
  esac
}
assert_not_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) fail_test "$name" "expected NOT to find: $needle" ;;
    *) ok "$name" ;;
  esac
}

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Stub gh: replays $GH_FIXTURE_DIR/<owner>__<repo>.json for `pr list -R …`;
#    a repo with no fixture file exits 1 (the erroring-repo case). Records
#    every argv line to $GH_CALL_LOG for the read-only assertion. ────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  repo=""
  prev=""
  for a in "$@"; do
    [ "$prev" = "-R" ] && repo="$a"
    prev="$a"
  done
  f="$GH_FIXTURE_DIR/$(printf '%s' "$repo" | tr '/' '_').json"
  [ -f "$f" ] || exit 1
  cat "$f"
  exit 0
fi
exit 1
FAKE_GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_CALL_LOG="$TMP/gh-calls.log"
export GH_FIXTURE_DIR="$TMP/fixtures"
mkdir -p "$GH_FIXTURE_DIR"
: > "$GH_CALL_LOG"

# ── Fixtures (fictional org — kernel test, no real repo names) ──────────────
# exampleorg/alpha: one of every class.
cat > "$GH_FIXTURE_DIR/exampleorg_alpha.json" <<'JSON'
[
  {"number": 1, "title": "feat: ready one", "isDraft": false, "mergeStateStatus": "CLEAN", "updatedAt": "2026-07-01T00:00:00Z",
   "statusCheckRollup": [{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"}]},
  {"number": 2, "title": "feat: behind", "isDraft": false, "mergeStateStatus": "BEHIND", "updatedAt": "2026-07-01T00:00:00Z",
   "statusCheckRollup": [{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"}]},
  {"number": 3, "title": "feat: conflicted", "isDraft": false, "mergeStateStatus": "DIRTY", "updatedAt": "2026-07-01T00:00:00Z",
   "statusCheckRollup": []},
  {"number": 4, "title": "feat: red checks", "isDraft": false, "mergeStateStatus": "BLOCKED", "updatedAt": "2026-07-01T00:00:00Z",
   "statusCheckRollup": [{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE"}]},
  {"number": 5, "title": "feat: still running", "isDraft": false, "mergeStateStatus": "BLOCKED", "updatedAt": "2026-07-01T00:00:00Z",
   "statusCheckRollup": [{"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": null}]},
  {"number": 6, "title": "feat: green but blocked", "isDraft": false, "mergeStateStatus": "BLOCKED", "updatedAt": "2026-07-01T00:00:00Z",
   "statusCheckRollup": [{"__typename": "StatusContext", "state": "SUCCESS"}]},
  {"number": 7, "title": "wip thing", "isDraft": true, "mergeStateStatus": "CLEAN", "updatedAt": "2026-07-01T00:00:00Z",
   "statusCheckRollup": []},
  {"number": 8, "title": "DO NOT MERGE: spike", "isDraft": false, "mergeStateStatus": "CLEAN", "updatedAt": "2026-07-01T00:00:00Z",
   "statusCheckRollup": [{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"}]}
]
JSON
# exampleorg/quiet: skip-only (a draft) — the clean case for --format entry.
cat > "$GH_FIXTURE_DIR/exampleorg_quiet.json" <<'JSON'
[
  {"number": 9, "title": "draft only", "isDraft": true, "mergeStateStatus": "UNKNOWN", "updatedAt": "2026-07-01T00:00:00Z",
   "statusCheckRollup": []}
]
JSON
# exampleorg/empty: no open PRs at all.
echo "[]" > "$GH_FIXTURE_DIR/exampleorg_empty.json"

# ── Stub board lib: two boards mapping onto ONE repo (dedup) + a second ─────
cat > "$TMP/board-stub.sh" <<'STUB'
board_registered_boards() { printf '%s\n' 3 4 5; }
board_repo() {
  case "$1" in
    3) echo "exampleorg/alpha" ;;
    4) echo "exampleorg/alpha" ;;
    5) echo "exampleorg/quiet" ;;
    *) return 1 ;;
  esac
}
STUB

echo "1. classification (--format report, --repos)"
out="$(bash "$SCRIPT" --repos "exampleorg/alpha" --format report)"
rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || fail_test "exit 0" "got $rc"
assert_has "$out" "ready            exampleorg/alpha#1" "PR 1 classified ready"
assert_has "$out" "enqueue candidate" "ready reason names enqueue candidacy"
assert_has "$out" "needs-rebase     exampleorg/alpha#2" "BEHIND → needs-rebase"
assert_has "$out" "needs-rebase     exampleorg/alpha#3" "DIRTY → needs-rebase"
assert_has "$out" "needs-attention  exampleorg/alpha#4" "failing checks → needs-attention"
assert_has "$out" "failing checks (1)" "failing reason counts failures"
assert_has "$out" "needs-attention  exampleorg/alpha#5" "pending checks → needs-attention"
assert_has "$out" "needs-attention  exampleorg/alpha#6" "green-but-BLOCKED → needs-attention"
assert_has "$out" "mergeStateStatus BLOCKED" "blocked reason names the state"
assert_has "$out" "skip             exampleorg/alpha#7" "draft → skip"
assert_has "$out" "skip             exampleorg/alpha#8" "DO-NOT-MERGE title → skip"
assert_has "$out" "summary: ready=1 needs-rebase=2 needs-attention=3 skip=2 errors=0" "summary counts"

echo "2. --format entry with candidates"
out="$(bash "$SCRIPT" --repos "exampleorg/alpha" --format entry)"
assert_has "$out" "· tidy ready-PR sweep ·" "entry heading present"
assert_has "$out" "ready: exampleorg/alpha#1" "entry lists ready ref"
assert_has "$out" "needs-rebase: exampleorg/alpha#2, exampleorg/alpha#3" "entry lists needs-rebase refs"
assert_has "$out" "- **Default taken:** leave all (report-only" "entry carries report-only default"
assert_has "$out" "- **Status:** open" "entry carries Status: open"
assert_not_has "$out" "#7" "skip-class PR not surfaced in entry"

echo "3. --format entry nothing-when-clean (skip-only / zero PRs)"
out="$(bash "$SCRIPT" --repos "exampleorg/quiet exampleorg/empty" --format entry)"
rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 when clean" || fail_test "exit 0 when clean" "got $rc"
[ -z "$out" ] && ok "no entry emitted when clean" || fail_test "no entry emitted when clean" "got: $out"

echo "4. fail-open — an erroring repo doesn't abort the sweep"
out="$(bash "$SCRIPT" --repos "exampleorg/nofixture exampleorg/alpha" --format report)"
rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 despite repo error" || fail_test "exit 0 despite repo error" "got $rc"
assert_has "$out" "ERROR listing PRs for exampleorg/nofixture" "error reported"
assert_has "$out" "exampleorg/alpha#1" "other repo still swept"
assert_has "$out" "errors=1" "summary counts the error"

echo "5. board-lib enumeration + dedup"
: > "$GH_CALL_LOG"
out="$(READY_PR_SWEEP_BOARD_LIB="$TMP/board-stub.sh" bash "$SCRIPT" --format report)"
assert_has "$out" "exampleorg/alpha#1" "board-lib path sweeps alpha"
assert_has "$out" "draft" "board-lib path sweeps quiet"
n_alpha="$(grep -c -- "-R exampleorg/alpha" "$GH_CALL_LOG" || true)"
[ "$n_alpha" -eq 1 ] && ok "alpha swept once despite two boards (dedup)" \
  || fail_test "alpha swept once despite two boards (dedup)" "swept $n_alpha times"

echo "6. read-only — stub gh saw only 'pr list' calls"
bad="$(grep -v '^pr list ' "$GH_CALL_LOG" || true)"
[ -z "$bad" ] && ok "no mutating gh subcommand invoked" \
  || fail_test "no mutating gh subcommand invoked" "saw: $bad"

echo "7. usage + fail-open preflight"
bash "$SCRIPT" --format bogus >/dev/null 2>&1
[ $? -eq 2 ] && ok "bad --format exits 2" || fail_test "bad --format exits 2" "got $?"
bash "$SCRIPT" --no-such-flag >/dev/null 2>&1
[ $? -eq 2 ] && ok "unknown flag exits 2" || fail_test "unknown flag exits 2" "got $?"
out="$(READY_PR_SWEEP_BOARD_LIB="$TMP/does-not-exist.sh" bash "$SCRIPT" --format report)"
rc=$?
[ "$rc" -eq 0 ] && ok "missing board lib + no --repos fails open (exit 0)" \
  || fail_test "missing board lib + no --repos fails open (exit 0)" "got $rc"
assert_has "$out" "skipping (fail-open)" "missing-lib notice printed"

echo
echo "test_ready_pr_sweep: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
