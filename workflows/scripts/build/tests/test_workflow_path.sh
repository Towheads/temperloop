#!/usr/bin/env bash
#
# test_workflow_path.sh — coverage for workflow-path.sh, the pre-flight that
# resolves the orchestrator a driver invokes and REFUSES a silently stale one
# (temperloop#2027).
#
# THE ARM THAT MATTERS is §2: an installed copy that DIFFERS from the checkout
# copy must make the gate FIRE — a non-zero exit, a WORKFLOW_PATH_STALE
# verdict, and NO resolved path, so a caller reading the verdict has nothing
# to invoke. Its discriminating partner is §3: the same fixture with the two
# copies in sync must NOT fire. A gate that refuses everything, or that
# refuses nothing, is byte-identical to a working one from the exit code
# alone, so both directions are pinned.
#
# Covers:
#   1. CHECKOUT      — the checkout copy exists -> that path, exit 0, silent.
#                      This is the resolution the three driver specs now name,
#                      and it is the path the Workflow tool actually accepts
#                      (it is inside the working directory).
#   2. STALE (RED)   — installed copy differs -> the gate fires: exit 1,
#                      WORKFLOW_PATH_STALE, "path":null, and the notice says
#                      so. Plus: the `path` subcommand prints NOTHING, so
#                      `workflowPath="$(… path …)"` cannot capture a stale one.
#   3. IN SYNC       — byte-identical copies -> exit 0 and the path resolves.
#                      The gate does not fire. (Discrimination partner of §2.)
#   4. INDETERMINATE — an out-of-checkout copy whose freshness could NOT be
#                      established is its OWN outcome, never STALE and never a
#                      clean CHECKOUT. An unknown must not read as a pass.
#   5. REUSE         — the gate carries NO second drift detector of its own: it
#                      shells out to doctor.sh's check_installed_workflow_drift
#                      (temperloop#1397) and parses the verdict. A hand-rolled
#                      sha256/cmp comparison here would be the duplicate
#                      mechanism the item forbids.
#   6. WIRING        — all three driver specs resolve through this gate and
#                      none of them still names the uninvocable installed
#                      literal. A mechanism reaching one driver is the
#                      partial-wiring failure, not a fix.
#
# Hermetic: every case runs against throwaway fixture checkouts under an
# isolated fake HOME, never the operator's real ~/.claude. Same posture as
# test_doctor_installed_workflow_drift.sh.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../workflow-path.sh"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
COMMANDS="$REPO_ROOT/claude/commands"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

[ -f "$GATE" ] || { echo "test_workflow_path: missing $GATE" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-workflow-path-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

# ---------------------------------------------------------------------------
# _fixture NAME  — a throwaway checkout + fake HOME pair. Prints "<repo>|<home>".
# ---------------------------------------------------------------------------
_fixture() {
  local repo="$TMP/$1/repo" home="$TMP/$1/home"
  mkdir -p "$repo/claude/workflows" "$home/.claude/workflows"
  printf '%s|%s' "$repo" "$home"
}

# _run HOME REPO ARGS... — sets OUT (stdout), ERR (stderr), RC.
OUT=""; ERR=""; RC=0
_run() {
  local home="$1" repo="$2"; shift 2
  local o="$TMP/out" e="$TMP/err"
  HOME="$home" bash "$GATE" "$@" "$repo" >"$o" 2>"$e"
  RC=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"
}

# _run_cand HOME REPO CMD CANDIDATE
_run_cand() {
  local home="$1" repo="$2" cmd="$3" cand="$4"
  local o="$TMP/out" e="$TMP/err"
  HOME="$home" bash "$GATE" "$cmd" "$repo" "$cand" >"$o" 2>"$e"
  RC=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"
}

echo "== 1. CHECKOUT: the checkout copy is what resolves =="
IFS='|' read -r R1 H1 <<<"$(_fixture c1)"
printf 'const a = 1;\n' >"$R1/claude/workflows/build-level.mjs"
_run "$H1" "$R1" resolve
if [ "$RC" -eq 0 ]; then ok 1a "a checkout copy resolves cleanly (exit 0)"
else bad 1a "expected exit 0, got $RC ($OUT)"; fi
case "$OUT" in
  *'"outcome":"WORKFLOW_PATH_CHECKOUT"'*) ok 1b "verdict is WORKFLOW_PATH_CHECKOUT" ;;
  *) bad 1b "expected WORKFLOW_PATH_CHECKOUT, got: $OUT" ;;
esac
case "$OUT" in
  *"$R1/claude/workflows/build-level.mjs"*) ok 1c "the resolved path is the CHECKOUT copy, not \$HOME/.claude" ;;
  *) bad 1c "expected the checkout path in the verdict, got: $OUT" ;;
esac
if [ -z "$ERR" ]; then ok 1d "the steady state is silent — no notice on a clean resolution"
else bad 1d "expected no stderr on the clean arm, got: $ERR"; fi

echo "== 2. STALE (the drift-refusal arm): the gate FIRES =="
IFS='|' read -r R2 H2 <<<"$(_fixture c2)"
printf 'const a = 1;\n// current\n' >"$R2/claude/workflows/build-level.mjs"
printf 'const a = 1;\n' >"$H2/.claude/workflows/build-level.mjs"   # STALE: differs
_run_cand "$H2" "$R2" resolve "$H2/.claude/workflows/build-level.mjs"
if [ "$RC" -ne 0 ]; then ok 2a "a drifted installed copy REFUSES (non-zero exit: $RC)"
else bad 2a "the gate did not fire: exit $RC, out: $OUT"; fi
case "$OUT" in
  *'"outcome":"WORKFLOW_PATH_STALE"'*) ok 2b "verdict is WORKFLOW_PATH_STALE" ;;
  *) bad 2b "expected WORKFLOW_PATH_STALE, got: $OUT" ;;
esac
case "$OUT" in
  *'"path":null'*) ok 2c "NO path is handed back — a caller has nothing stale to invoke" ;;
  *) bad 2c "expected \"path\":null on a refusal, got: $OUT" ;;
esac
case "$ERR" in
  *REFUSED*STALE*) ok 2d "the refusal notice names it as refused AND stale" ;;
  *) bad 2d "expected a REFUSED/STALE notice on stderr, got: $ERR" ;;
esac
# The convenience accessor must not leak the stale path either.
_run_cand "$H2" "$R2" path "$H2/.claude/workflows/build-level.mjs"
if [ "$RC" -ne 0 ] && [ -z "$OUT" ]; then
  ok 2e "\`path\` prints NOTHING and exits non-zero on a refusal"
else
  bad 2e "expected empty stdout + non-zero on the path accessor, got rc=$RC out=$OUT"
fi

echo "== 3. IN SYNC (the discriminating partner): the gate does NOT fire =="
IFS='|' read -r R3 H3 <<<"$(_fixture c3)"
printf 'const a = 1;\n// current\n' >"$R3/claude/workflows/build-level.mjs"
cp "$R3/claude/workflows/build-level.mjs" "$H3/.claude/workflows/build-level.mjs"
_run_cand "$H3" "$R3" resolve "$H3/.claude/workflows/build-level.mjs"
if [ "$RC" -eq 0 ]; then ok 3a "byte-identical copies do NOT refuse (exit 0)"
else bad 3a "the gate fired on in-sync copies: exit $RC, out: $OUT"; fi
case "$OUT" in
  *'"outcome":"WORKFLOW_PATH_INSTALLED_IN_SYNC"'*) ok 3b "verdict is WORKFLOW_PATH_INSTALLED_IN_SYNC" ;;
  *) bad 3b "expected WORKFLOW_PATH_INSTALLED_IN_SYNC, got: $OUT" ;;
esac
case "$OUT" in
  *'"path":null'*) bad 3c "an in-sync engine must still resolve a path, got: $OUT" ;;
  *"$H3/.claude/workflows/build-level.mjs"*) ok 3c "the in-sync installed path IS resolved" ;;
  *) bad 3c "expected the installed path in the verdict, got: $OUT" ;;
esac
if [ -n "$ERR" ]; then ok 3d "an in-sync installed copy still warns — nothing owns it"
else bad 3d "expected a warning on the un-owned installed copy"; fi

echo "== 4. INDETERMINATE is its own outcome, never STALE and never CHECKOUT =="
IFS='|' read -r R4 H4 <<<"$(_fixture c4)"
printf 'const a = 1;\n' >"$R4/claude/workflows/build-level.mjs"
_run_cand "$H4" "$R4" resolve "$TMP/somewhere-else/build-level.mjs"
case "$OUT" in
  *'"outcome":"WORKFLOW_PATH_INDETERMINATE"'*) ok 4a "an out-of-scope engine is INDETERMINATE" ;;
  *) bad 4a "expected WORKFLOW_PATH_INDETERMINATE, got: $OUT" ;;
esac
case "$OUT" in
  *'"outcome":"WORKFLOW_PATH_CHECKOUT"'*) bad 4b "an unknown must never read as a clean checkout resolution" ;;
  *) ok 4b "an unknown never collapses into the clean verdict" ;;
esac
case "$OUT" in
  *'"reason":null'*|*'"reason":""'*) bad 4c "INDETERMINATE must carry a non-empty reason, got: $OUT" ;;
  *'"reason":"'*) ok 4c "INDETERMINATE carries a non-empty reason" ;;
  *) bad 4c "expected a reason field, got: $OUT" ;;
esac
# An installed copy that is simply absent is also not drift.
IFS='|' read -r R5 H5 <<<"$(_fixture c5)"
printf 'const a = 1;\n' >"$R5/claude/workflows/build-level.mjs"
_run_cand "$H5" "$R5" resolve "$H5/.claude/workflows/build-level.mjs"
case "$OUT" in
  *'"outcome":"WORKFLOW_PATH_STALE"'*) bad 4d "an ABSENT installed copy is not drift" ;;
  *'"outcome":"WORKFLOW_PATH_INDETERMINATE"'*) ok 4d "an absent installed copy is INDETERMINATE, not drift" ;;
  *) bad 4d "expected INDETERMINATE for an absent installed copy, got: $OUT" ;;
esac

echo "== 5. REUSE: one detector, not two =="
if grep -q -- '--only=installed-workflow-drift' "$GATE"; then
  ok 5a "the gate delegates to doctor.sh's existing drift detector"
else
  bad 5a "the gate must reuse doctor.sh --only=installed-workflow-drift"
fi
if grep -qE '(sha256sum|shasum|openssl dgst|[^_a-z]cmp )' "$GATE"; then
  bad 5b "the gate hand-rolls its own content comparison — reuse the detector"
else
  ok 5b "the gate carries NO second content comparison of its own"
fi
if grep -q 'DOCTOR_ONLY' "$REPO_ROOT/workflows/scripts/install/doctor.sh"; then
  ok 5c "doctor.sh exposes the focused entrypoint the gate calls"
else
  bad 5c "doctor.sh is missing the --only focus selector the gate depends on"
fi

echo "== 6. WIRING: all three driver specs resolve through the gate =="
for spec in build.md sweep.md fix.md; do
  f="$COMMANDS/$spec"
  if [ ! -f "$f" ]; then bad "6-$spec" "missing $f"; continue; fi
  if grep -q 'workflows/scripts/build/workflow-path.sh' "$f"; then
    ok "6-$spec" "$spec resolves workflowPath through the gate"
  else
    bad "6-$spec" "$spec does not reference workflow-path.sh"
  fi
  if grep -q 'HOME}/.claude/workflows/build-level.mjs\|\$HOME/.claude/workflows/build-level.mjs' "$f"; then
    bad "6-$spec-literal" "$spec still names the uninvocable \$HOME/.claude engine literal"
  else
    ok "6-$spec-literal" "$spec no longer names the uninvocable \$HOME/.claude literal"
  fi
done

echo
echo "test_workflow_path: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
