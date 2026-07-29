#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/combined-tree-precheck.sh — the Step-4
# level-merge-gate UNION check of /build (temperloop#865).
#
# Unlike test_gate.sh (which mocks the GitHub API seam and never touches real
# git — gate.sh is network-pure per temperloop#242), this check IS local-git by
# nature: it builds a throwaway worktree and merges real branches. So this test
# is a REAL-GIT integration test — it constructs a scratch repository with
# fixture branches in a temp dir, invokes the script as a subprocess, and
# asserts on the structured JSON + exit code. The gate suite is injected via the
# COMBINED_TREE_SUITE_CMD seam as a SELF-CONTAINED synthetic gate: it fails iff
# BOTH a `GATE` marker file (from the "adds a gate" branch) AND a `SCANNED` file
# (from the "adds files it scans" branch) are present in the merged tree — the
# exact green-alone / red-combined shape the retro's collisions took (F#847).
#
# Covers:
#   - SKIP: fewer than two branches → no union check (single-PR levels, #3)
#   - CLEAN: two disjoint branches that don't co-trigger the gate → CLEAN (exit 0)
#   - GATE_FAILED: the synthetic collision (gate branch + scanned branch merge
#     clean textually but fail the suite together) → GATE_FAILED (exit 4),
#     caught LOCALLY, pre-queue (acceptance #2)
#   - CONFLICT: two branches that edit the same line → CONFLICT (exit 3),
#     naming the offending branch, suite never run
#   - ERROR: a non-existent branch ref → clean ERROR (exit 1), no half-built tree
#   - GATE_FAILED reason surfacing (temperloop#880): against a suite whose output
#     has quality-gates.sh's SHAPE (per-gate `=== <gate> ===` sections inline,
#     the `FAILED n/N` roll-up last) with the failing gate's `FAIL:` line far
#     (>40 lines) from the end of the stream, the JSON carries that gate's own
#     section — the reason a blind `tail -40` used to discard — plus the
#     retained full-log path, which SURVIVES the worktree teardown
#   - GATE_FAILED fallback: a suite with no recognizable roll-up degrades to the
#     old tail behaviour rather than an empty reason
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../combined-tree-precheck.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Self-contained synthetic gate: red iff the merged tree has BOTH marker files.
# Runs with cwd == the merged worktree (the script's contract).
SUITE_CMD='bash -c '"'"'if [ -f GATE ] && [ -f SCANNED ]; then echo "COLLISION: gate + scanned file both present"; exit 1; fi; exit 0'"'"''

# Per-run override of the suite seam (empty = use SUITE_CMD above).
SUITE_CMD_OVERRIDE=""

# --- scratch repo with fixture branches --------------------------------------
REPO="$(mktemp -d "${TMPDIR:-/tmp}/ctp-repo.XXXXXX")"
# Home for the synthetic suite scripts the #880 cases below inject.
FIXDIR="$(mktemp -d "${TMPDIR:-/tmp}/ctp-fix.XXXXXX")"
# Every GATE_FAILED run retains a full suite log outside the throwaway worktree
# (that is the point — it must survive the script's teardown); this test owns
# the ones it caused, and removes them at exit.
LOGS=()
cleanup() {
  rm -rf "$REPO" "$FIXDIR"
  [ "${#LOGS[@]}" -eq 0 ] || rm -f "${LOGS[@]}"
}
trap cleanup EXIT

git -c init.defaultBranch=main init --quiet "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name  "Test"
# Base commit on main: a shared file every branch descends from.
printf 'base\n' > "$REPO/README.md"
printf 'line1\nline2\nline3\n' > "$REPO/shared.txt"
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "base"

# add-gate: drops a GATE marker (models "a branch adds a new gate").
git -C "$REPO" checkout --quiet -b add-gate
printf 'gate\n' > "$REPO/GATE"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "add gate"

# add-scanned: drops a SCANNED file the gate would flag (disjoint path).
git -C "$REPO" checkout --quiet main
git -C "$REPO" checkout --quiet -b add-scanned
printf 'scanned\n' > "$REPO/SCANNED"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "add scanned file"

# add-foo / add-bar: two genuinely disjoint, non-colliding branches.
git -C "$REPO" checkout --quiet main
git -C "$REPO" checkout --quiet -b add-foo
printf 'foo\n' > "$REPO/foo.txt"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "add foo"

git -C "$REPO" checkout --quiet main
git -C "$REPO" checkout --quiet -b add-bar
printf 'bar\n' > "$REPO/bar.txt"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "add bar"

# conflict-a / conflict-b: both rewrite the SAME line of shared.txt.
git -C "$REPO" checkout --quiet main
git -C "$REPO" checkout --quiet -b conflict-a
printf 'line1\nAAA\nline3\n' > "$REPO/shared.txt"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "conflict a"

git -C "$REPO" checkout --quiet main
git -C "$REPO" checkout --quiet -b conflict-b
printf 'line1\nBBB\nline3\n' > "$REPO/shared.txt"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "conflict b"

git -C "$REPO" checkout --quiet main

# Runner: invoke the script, capturing JSON + exit code (never abort on non-zero).
run() {
  local rc lg
  set +e
  OUT="$(COMBINED_TREE_SUITE_CMD="${SUITE_CMD_OVERRIDE:-$SUITE_CMD}" bash "$SCRIPT" "$REPO" "$@" --base main 2>&1)"
  rc=$?
  set -e
  RC=$rc
  lg="$(jq -r '.suite_log // empty' <<<"$OUT" 2>/dev/null || true)"
  if [ -n "$lg" ]; then LOGS+=("$lg"); fi
}

# --- SKIP: single branch -----------------------------------------------------
run add-gate
[ "$RC" -eq 0 ] || fail "SKIP should exit 0 (rc=$RC, out=$OUT)"
[ "$(jq -r .outcome <<<"$OUT")" = "SKIP" ] || fail "single branch → SKIP (got: $OUT)"
echo "PASS: fewer than two branches → SKIP (exit 0) — single-PR levels need no union check"

# --- CLEAN: two disjoint, non-colliding branches -----------------------------
run add-foo add-bar
[ "$RC" -eq 0 ] || fail "CLEAN should exit 0 (rc=$RC, out=$OUT)"
[ "$(jq -r .outcome <<<"$OUT")" = "CLEAN" ] || fail "disjoint set → CLEAN (got: $OUT)"
[ "$(jq -r '.branches | length' <<<"$OUT")" = "2" ] || fail "CLEAN branches echoed (got: $OUT)"
echo "PASS: two disjoint branches that merge clean and pass the suite → CLEAN (exit 0)"

# --- GATE_FAILED: the synthetic semantic collision ---------------------------
run add-gate add-scanned
[ "$RC" -eq 4 ] || fail "GATE_FAILED should exit 4 (rc=$RC, out=$OUT)"
[ "$(jq -r .outcome <<<"$OUT")" = "GATE_FAILED" ] || fail "collision → GATE_FAILED (got: $OUT)"
jq -e '.output | test("COLLISION")' <<<"$OUT" >/dev/null \
  || fail "GATE_FAILED surfaces the failing gate's output (got: $OUT)"
[ "$(jq -r .exit_code <<<"$OUT")" = "1" ] || fail "GATE_FAILED carries the suite exit code (got: $OUT)"
echo "PASS: a green-alone/red-combined pair (gate branch + scanned branch) → GATE_FAILED (exit 4), caught locally pre-queue"

# --- GATE_FAILED surfaces the FAILING GATE'S OWN reason (temperloop#880) -----
# A synthetic suite with quality-gates.sh's OUTPUT SHAPE: each gate's output
# printed INLINE under a `=== <gate> ===` banner as it runs, the
# `FAILED n/N quality gate(s):` roll-up LAST. The failing gate runs FIRST and a
# noisy passing gate runs after it, so its `FAIL:` line sits far more than 40
# lines from the end of the stream — exactly the real shape in which the old
# blind `tail -40` captured the roll-up (the gate's NAME) and threw the reason
# away.
cat > "$FIXDIR/noisy-suite.sh" <<'NOISY'
#!/usr/bin/env bash
printf '\n=== make test-alpha ===\n'
echo 'FAIL: alpha exploded - the reason that must survive'
printf '\n=== make test-beta ===\n'
i=0
while [ "$i" -lt 200 ]; do echo "beta chatter line $i"; i=$((i + 1)); done
echo
printf 'FAILED 1/2 quality gate(s):\n'
printf '  - make test-alpha\n'
exit 1
NOISY

SUITE_CMD_OVERRIDE="bash $FIXDIR/noisy-suite.sh"
run add-foo add-bar
SUITE_CMD_OVERRIDE=""

[ "$RC" -eq 4 ] || fail "noisy suite should still exit 4 (rc=$RC, out=$OUT)"
[ "$(jq -r .outcome <<<"$OUT")" = "GATE_FAILED" ] || fail "noisy suite → GATE_FAILED (got: $OUT)"
jq -e '.output | test("FAIL: alpha exploded")' <<<"$OUT" >/dev/null \
  || fail "output must carry the FAILING GATE'S OWN FAIL: line (got: $OUT)"
jq -e '.output | test("=== make test-alpha ===")' <<<"$OUT" >/dev/null \
  || fail "output must be the failing gate's own section, banner included (got: $OUT)"
jq -e '.output | test("beta chatter") | not' <<<"$OUT" >/dev/null \
  || fail "output must be the FAILING gate's section only, not the whole stream (got: $OUT)"
[ "$(jq -r '.failed_gates | join(",")' <<<"$OUT")" = "make test-alpha" ] \
  || fail "failed_gates must name the roll-up's gate (got: $OUT)"
# Existing fields + exit code are untouched — callers (/build 4a.5, gate.sh) keep working.
[ "$(jq -r .exit_code <<<"$OUT")" = "1" ] || fail "exit_code retained (got: $OUT)"
[ "$(jq -r '.branches | length' <<<"$OUT")" = "2" ] || fail "branches retained (got: $OUT)"
echo "PASS: GATE_FAILED output carries the failing gate's own inline section, not a blind tail of the stream"

# The full log is retained OUTSIDE the throwaway worktree, so it is still there
# after the script's EXIT trap tore that worktree down.
LOG="$(jq -r .suite_log <<<"$OUT")"
[ -n "$LOG" ] || fail "GATE_FAILED must carry a suite_log path (got: $OUT)"
[ -f "$LOG" ] || fail "suite_log must survive the worktree teardown (missing: $LOG)"
case "$LOG" in
  *combined-tree.*) fail "suite_log must NOT live inside the throwaway worktree ($LOG)" ;;
esac
grep -q "beta chatter line 199" "$LOG" || fail "suite_log must hold the FULL log (got: $LOG)"
# ... and the reason genuinely was out of a blind tail's reach: this is the
# regression this whole item exists for.
if tail -40 "$LOG" | grep -q "FAIL: alpha exploded"; then
  fail "fixture is not exercising the defect — the FAIL: line is within tail -40 of the log"
fi
echo "PASS: the full suite log is retained outside the worktree and survives teardown (the FAIL: line is >40 lines from the stream's end)"

# --- GATE_FAILED graceful fallback: unrecognizable suite output --------------
# No `FAILED n/N` roll-up at all (a suite that isn't quality-gates.sh, or a
# future output-shape change) → the old tail behaviour, never an empty reason.
cat > "$FIXDIR/shapeless-suite.sh" <<'SHAPELESS'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 100 ]; do echo "shapeless line $i"; i=$((i + 1)); done
exit 1
SHAPELESS

SUITE_CMD_OVERRIDE="bash $FIXDIR/shapeless-suite.sh"
run add-foo add-bar
SUITE_CMD_OVERRIDE=""

[ "$RC" -eq 4 ] || fail "shapeless suite should exit 4 (rc=$RC, out=$OUT)"
jq -e '.output | test("shapeless line 99")' <<<"$OUT" >/dev/null \
  || fail "no roll-up → fall back to the tail, not an empty reason (got: $OUT)"
[ "$(jq -r '.output | length > 0' <<<"$OUT")" = "true" ] || fail "fallback output must be non-empty (got: $OUT)"
[ "$(jq -r '.failed_gates | length' <<<"$OUT")" = "0" ] || fail "no roll-up → no named gates (got: $OUT)"
echo "PASS: an unrecognizable suite-output shape falls back to the old tail rather than an empty reason"

# --- CONFLICT: same-line edits, suite never reached --------------------------
run conflict-a conflict-b
[ "$RC" -eq 3 ] || fail "CONFLICT should exit 3 (rc=$RC, out=$OUT)"
[ "$(jq -r .outcome <<<"$OUT")" = "CONFLICT" ] || fail "same-line edits → CONFLICT (got: $OUT)"
[ "$(jq -r .branch <<<"$OUT")" = "conflict-b" ] || fail "CONFLICT names the offending (second) branch (got: $OUT)"
echo "PASS: two branches editing the same line → CONFLICT (exit 3), naming the offending branch"

# --- ERROR: a non-existent branch ref ----------------------------------------
run add-foo no-such-branch
[ "$RC" -eq 1 ] || fail "bad ref should exit 1 (rc=$RC, out=$OUT)"
[ "$(jq -r .outcome <<<"$OUT")" = "ERROR" ] || fail "bad ref → ERROR (got: $OUT)"
jq -e '.error | test("not found")' <<<"$OUT" >/dev/null \
  || fail "ERROR names the missing ref (got: $OUT)"
echo "PASS: a non-existent branch ref → ERROR (exit 1), no half-built worktree"

# --- no leaked worktrees: the throwaway tree is always torn down -------------
leaked="$(git -C "$REPO" worktree list --porcelain | grep -c 'combined-tree' || true)"
[ "$leaked" -eq 0 ] || fail "throwaway worktree leaked ($leaked still registered)"
echo "PASS: no throwaway worktree leaked after all outcomes (clean/conflict/gate-fail/error)"

echo "ALL COMBINED-TREE-PRECHECK TESTS PASSED"
