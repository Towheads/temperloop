#!/usr/bin/env bash
#
# test_async_workflow_health.sh — tests for
# workflows/scripts/async-workflow-health.sh, the red-asynchronous-workflow
# alarm (temperloop#1297).
#
# DETERMINISTIC, RECORDED FIXTURES ONLY — never a live GitHub API call
# (kernel principle 3). Every case builds a synthetic .github/workflows tree,
# a synthetic disposition registry, and a directory of recorded
# `gh run list --json` output, then runs the detector as a real subprocess
# with a POISONED `gh` on PATH: the stub writes a marker file and fails, so a
# test that accidentally reaches the network is caught rather than merely
# being slow.
#
# Cases:
#   1. ALREADY-RED — a workflow red for 7 consecutive scheduled runs (the
#      exact shape of both real instances: discovered while already red, not
#      at the transition) renders a RED line naming the streak.
#   2. GREEN — newest asynchronous run succeeded -> an `ok` line, no alarm.
#   3. UNREGISTERED — an asynchronous workflow with no registry row is
#      reported as UNREGISTERED (FAIL CLOSED: adding a third asynchronous
#      workflow and forgetting the registry is visible, not silent).
#   4. EMPTY / ABSENT RUN HISTORY — `[]` and a missing fixture file both
#      render UNKNOWN, never a fabricated "green".
#   5. SYNCHRONOUS workflows (pull_request / merge_group / branch push) are
#      out of scope and never reported.
#   6. TAG push is asynchronous; BRANCH push is not.
#   7. HYBRID (pull_request + schedule) — a failed pull_request run must NOT
#      make it red; only the asynchronous events are judged.
#   8. UNPARSEABLE `on:` — treated as asynchronous (fail closed).
#   9. ABSENT / EMPTY REGISTRY — every asynchronous workflow reports
#      UNREGISTERED and the line says nothing is being watched.
#  10. STALE-ROW — a registry row naming a workflow file that no longer
#      exists is reported (the registry drifting from the tree).
#  11. EXEMPT — a registered-exempt workflow's red state is reported but
#      raises no alarm, so the exemption cannot rot into silence.
#  12. Exit code is ALWAYS 0 — a status readout must never fail its reader.
#  13. The real repo tree classifies correctly: exactly nightly-macos.yml and
#      install-tier2.yml are asynchronous, both registered.
#  14. telemetry-brief.sh actually invokes the detector (the wiring check).
#
# Usage: bash workflows/scripts/tests/test_async_workflow_health.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/async-workflow-health.sh"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find: $needle
--- got ---
$haystack" ;;
  esac
}
assert_not_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) fail_test "$name" "expected NOT to find: $needle
--- got ---
$haystack" ;;
    *) ok "$name" ;;
  esac
}
assert_rc0() { if [ "$1" -eq 0 ]; then ok "$2"; else fail_test "$2" "exit $1"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "test_async_workflow_health: jq not found — cannot run (the detector's own jq-less degradation is asserted separately below only when jq exists)" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/async-workflow-health-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── a poisoned `gh`: any live call fails AND leaves evidence ────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "live-gh-invoked" >> "${GH_STUB_MARKER:-/dev/null}"  # setting:exempt — test-local marker path for this poisoned gh stub, not an operator-tunable setting
exit 1
STUB
chmod 755 "$TMP/bin/gh"
GH_STUB_MARKER="$TMP/gh-called"
export GH_STUB_MARKER

run_detector() {  # $1=workflow dir $2=registry $3=runs dir; rest = args
  local wfdir="$1" reg="$2" runs="$3"
  shift 3
  PATH="$TMP/bin:$PATH" \
  ASYNC_WORKFLOW_DIR="$wfdir" \
  ASYNC_WORKFLOW_REGISTRY="$reg" \
  ASYNC_WORKFLOW_RUNS_DIR="$runs" \
    bash "$SCRIPT" "$@"
}

# ── fixture builders ────────────────────────────────────────────────────────
mk_wf() {  # $1=dir $2=filename $3=on-block body (already indented)
  mkdir -p "$1"
  {
    printf 'name: %s\n\n' "${2%.yml}"
    printf 'on:\n%s\n' "$3"
    printf '\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n'
  } > "$1/$2"
}

# runs_fixture <dir> <workflow-file> <conclusion:event:date> ...
# Emits the exact `gh run list --json event,status,conclusion,createdAt,url`
# array shape, newest first.
runs_fixture() {
  local dir="$1" wf="$2"
  shift 2
  mkdir -p "$dir"
  local out="[" first=1 spec conc ev day
  for spec in "$@"; do
    conc="${spec%%:*}"; spec="${spec#*:}"
    ev="${spec%%:*}"; day="${spec#*:}"
    [ "$first" -eq 1 ] || out="$out,"
    first=0
    out="$out{\"conclusion\":\"$conc\",\"event\":\"$ev\",\"status\":\"completed\",\"createdAt\":\"${day}T09:50:00Z\",\"url\":\"https://example.invalid/run/$day\"}"
  done
  out="$out]"
  printf '%s\n' "$out" > "$dir/$wf.json"
}

TAB="$(printf '\t')"
reg_row() { printf '%s%s%s%s%s\n' "$1" "$TAB" "$2" "$TAB" "$3"; }

# ═══ Case 1-2, 4-7: one tree exercising the classifier + verdict matrix ═════
echo "classifier + verdict matrix:"
WF="$TMP/wf1"; RUNS="$TMP/runs1"; REG="$TMP/reg1.tsv"

mk_wf "$WF" "nightly.yml"    '  schedule:
    - cron: "17 9 * * *"
  workflow_dispatch: {}'
mk_wf "$WF" "tagged.yml"     '  push:
    tags:
      - "v*.*.0"
  workflow_dispatch: {}'
mk_wf "$WF" "prgate.yml"     '  pull_request:
  merge_group:
  push:
    branches: [main]'
mk_wf "$WF" "pages.yml"      '  push:
    branches: [main]'
mk_wf "$WF" "hybrid.yml"     '  pull_request:
  schedule:
    - cron: "0 3 * * *"'
mk_wf "$WF" "quiet.yml"      '  schedule:
    - cron: "0 4 * * *"'
mk_wf "$WF" "neverrun.yml"   '  workflow_dispatch: {}'

{
  printf '# WORKFLOW\tDISPOSITION\tNOTE\n'
  reg_row "nightly.yml"  "alarm"  "the nightly BSD-dialect gate"
  reg_row "tagged.yml"   "alarm"  "the release round-trip gate"
  reg_row "hybrid.yml"   "alarm"  "has a PR leg and a scheduled leg"
  reg_row "quiet.yml"    "alarm"  "empty run history on purpose"
  reg_row "neverrun.yml" "alarm"  "no fixture file at all on purpose"
} > "$REG"

# nightly: red for 7 consecutive scheduled runs, green before that — the
# ALREADY-RED shape (nightly-macos.yml, 2026-08-14..08-20).
runs_fixture "$RUNS" "nightly.yml" \
  failure:schedule:2026-08-20 failure:schedule:2026-08-19 \
  failure:schedule:2026-08-18 failure:schedule:2026-08-17 \
  failure:schedule:2026-08-16 failure:schedule:2026-08-15 \
  failure:schedule:2026-08-14 success:schedule:2026-08-13 \
  success:schedule:2026-08-12
# tagged: green
runs_fixture "$RUNS" "tagged.yml" success:push:2026-08-20 failure:push:2026-08-01
# hybrid: newest run is a FAILED pull_request run; its scheduled leg is green
runs_fixture "$RUNS" "hybrid.yml" \
  failure:pull_request:2026-08-20 success:schedule:2026-08-19
# quiet: present but empty history
runs_fixture "$RUNS" "quiet.yml"
# neverrun: deliberately NO fixture file

out="$(run_detector "$WF" "$REG" "$RUNS" --format brief)"; rc=$?
assert_rc0 "$rc" "exit 0 on the mixed tree"
assert_has "$out" "RED nightly.yml — 7 consecutive failed schedule run(s), newest 2026-08-20" "already-red workflow renders its consecutive-red streak"
assert_has "$out" "ok tagged.yml — newest push run succeeded 2026-08-20" "green workflow renders ok, no alarm"
assert_not_has "$out" "prgate.yml" "pull_request/merge_group workflow is out of scope"
assert_not_has "$out" "pages.yml" "branch-push workflow is out of scope"
assert_has "$out" "ok hybrid.yml" "hybrid workflow judged on its asynchronous leg only"
assert_not_has "$out" "RED hybrid.yml" "a failed pull_request run does not make a hybrid workflow red"
assert_has "$out" "UNKNOWN quiet.yml — no completed asynchronous run" "empty run history renders UNKNOWN, never a fabricated green"
assert_has "$out" "UNKNOWN neverrun.yml — no completed asynchronous run" "absent run history renders UNKNOWN, never a fabricated green"
assert_has "$out" "NEEDS ATTENTION — 1 red" "headline counts the red workflow"
assert_not_has "$(cat "$GH_STUB_MARKER" 2>/dev/null || true)" "live-gh-invoked" "no live gh call is made when recorded fixtures are supplied"

# ═══ Case 3, 8: fail-closed on an unregistered / unparseable workflow ═══════
echo "fail-closed (unregistered + unparseable):"
WF2="$TMP/wf2"; RUNS2="$TMP/runs2"; REG2="$TMP/reg2.tsv"
mk_wf "$WF2" "nightly.yml" '  schedule:
    - cron: "17 9 * * *"'
mk_wf "$WF2" "forgotten.yml" '  schedule:
    - cron: "0 5 * * *"'
mkdir -p "$WF2"
# An `on:` block this classifier cannot read at all.
printf 'name: weird\n"on": {schedule: [{cron: "0 6 * * *"}]}\njobs: {}\n' > "$WF2/weird.yml"
{
  printf '# WORKFLOW\tDISPOSITION\tNOTE\n'
  reg_row "nightly.yml" "alarm" "registered"
} > "$REG2"
runs_fixture "$RUNS2" "nightly.yml" success:schedule:2026-08-20

out="$(run_detector "$WF2" "$REG2" "$RUNS2")"; rc=$?
assert_rc0 "$rc" "exit 0 with unregistered workflows present"
assert_has "$out" "UNREGISTERED forgotten.yml" "an unregistered asynchronous workflow fails closed"
assert_has "$out" "no row in" "the unregistered line names the registry to fix"
assert_has "$out" "UNREGISTERED weird.yml" "an unparseable on: block is treated as asynchronous (fail closed)"
assert_has "$out" "NEEDS ATTENTION" "unregistered workflows raise the headline alarm"

# ═══ Case 9: absent / empty registry ═══════════════════════════════════════
echo "degenerate registry:"
out="$(run_detector "$WF2" "$TMP/does-not-exist.tsv" "$RUNS2")"; rc=$?
assert_rc0 "$rc" "exit 0 with an absent registry"
assert_has "$out" "UNREGISTERED nightly.yml" "an absent registry leaves every asynchronous workflow unregistered"
assert_has "$out" "NOTHING here is being watched" "the absent-registry line says outright that nothing is watched"

printf '# only comments\n\n' > "$TMP/reg-empty.tsv"
out="$(run_detector "$WF2" "$TMP/reg-empty.tsv" "$RUNS2")"
assert_has "$out" "NOTHING here is being watched" "a comments-only registry is treated as empty, not as a pass"

# ═══ Case 10: stale registry row ═══════════════════════════════════════════
echo "stale registry row:"
REG3="$TMP/reg3.tsv"
{
  printf '# WORKFLOW\tDISPOSITION\tNOTE\n'
  reg_row "nightly.yml" "alarm" "registered"
  reg_row "forgotten.yml" "alarm" "registered"
  reg_row "weird.yml" "alarm" "registered"
  reg_row "deleted-long-ago.yml" "alarm" "no longer in the tree"
} > "$REG3"
out="$(run_detector "$WF2" "$REG3" "$RUNS2")"
assert_has "$out" "STALE-ROW deleted-long-ago.yml" "a registry row with no workflow file is reported"

# ═══ Case 11: exempt disposition ═══════════════════════════════════════════
echo "exempt disposition:"
REG4="$TMP/reg4.tsv"
{
  printf '# WORKFLOW\tDISPOSITION\tNOTE\n'
  reg_row "nightly.yml" "exempt" "deliberately unwatched for now"
  reg_row "tagged.yml"  "alarm"  "watched"
  reg_row "hybrid.yml"  "alarm"  "watched"
  reg_row "quiet.yml"   "alarm"  "watched"
  reg_row "neverrun.yml" "alarm" "watched"
} > "$REG4"
out="$(run_detector "$WF" "$REG4" "$RUNS")"
assert_has "$out" "exempt nightly.yml — RED (7 consecutive failed schedule run(s)" "an exempt workflow's red state is still reported"
assert_not_has "$out" "RED nightly.yml —" "an exempt workflow raises no RED alarm line"

# ═══ Case 13: the REAL tree classifies as expected ═════════════════════════
echo "real repo tree:"
out="$(PATH="$TMP/bin:$PATH" ASYNC_WORKFLOW_RUNS_DIR="$TMP/no-runs" bash "$SCRIPT" --format report)"; rc=$?
assert_rc0 "$rc" "exit 0 against the real .github/workflows tree"
assert_has "$out" "nightly-macos.yml" "nightly-macos.yml classifies as asynchronous"
assert_has "$out" "install-tier2.yml" "install-tier2.yml classifies as asynchronous"
assert_not_has "$out" "ci.yml" "ci.yml is synchronous and out of scope"
assert_not_has "$out" "docs-pages.yml" "docs-pages.yml is synchronous and out of scope"
assert_not_has "$out" "UNREGISTERED" "every asynchronous workflow in this repo is registered"
assert_not_has "$out" "STALE-ROW" "the committed registry names no missing workflow file"

# ═══ Case 14: the wiring into the read surface ═════════════════════════════
echo "read-surface wiring:"
if grep -q 'async-workflow-health.sh' "$REPO/workflows/scripts/telemetry-brief.sh"; then
  ok "telemetry-brief.sh invokes the detector (the /check-in + /telemetry read surface)"
else
  fail_test "telemetry-brief wiring" "workflows/scripts/telemetry-brief.sh does not invoke async-workflow-health.sh"
fi

echo
echo "async-workflow-health: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
