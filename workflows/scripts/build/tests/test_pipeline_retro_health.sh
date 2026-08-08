#!/usr/bin/env bash
#
# Tests for pipeline-retro-health.sh — the retro-judge seam detector
# (temperloop#1150). Zero network, zero real lake: every case builds a
# synthetic raw lake under TMP and points PIPELINE_RAW_DIR / RETRO_RUNS_RAW_DIR
# at it.
#
# The property under test is the one the seam lacked: a zero-row retro-runs
# stream must NOT collapse to a single steady state. "No retros were due"
# (no-signal), "the trigger refused and said why" (refused), and "the trigger
# fired and produced nothing" (defect) are three different verdicts, and the
# third is the failure that hid for months.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../pipeline-retro-health.sh"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/retro-health-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

NOW_MONTH="$(date -u +%Y-%m)"
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Deliberately outside any sane window, to prove `rows_ever` is whole-history
# while `rows_in_window` is not.
OLD_TS="2019-01-01T00:00:00Z"

# $1 = lake dir; seeds an empty lake with a pipeline month-file present.
new_lake() { mkdir -p "$1"; : > "$1/pipeline-$NOW_MONTH.jsonl"; }

# $1=lake $2=action $3=reason(optional) — append one wake record carrying one action.
wake() {
  local lake="$1" action="$2" reason="${3:-}"
  jq -nc --arg ts "$NOW_TS" --arg a "$action" --arg r "$reason" \
    '{event:"ran",ts:$ts,plans:[{board:"3",actions:[
        (if $r == "" then {phase:"retro",action:$a} else {phase:"retro",action:$a,reason:$r} end)]}]}' \
    >> "$lake/pipeline-$NOW_MONTH.jsonl"
}

run() {  # $1=lake  [$2=retro-runs dir]
  PIPELINE_RAW_DIR="$1" RETRO_RUNS_RAW_DIR="${2:-$1}" bash "$SCRIPT" --days 30
}

echo "--- test 1: an absent lake is UNKNOWN (no-lake), never a clean bill of health ---"
OUT="$(PIPELINE_RAW_DIR="$TMP/nope" RETRO_RUNS_RAW_DIR="$TMP/nope" bash "$SCRIPT" --days 30)"
[ "$(jq -r '.status' <<<"$OUT")" = "no-lake" ] \
  && ok "status=no-lake when there is no pipeline stream to read" || bad "t1.status" "$OUT"
jq -e '.detail | test("UNKNOWN")' <<<"$OUT" >/dev/null \
  && ok "the detail says UNKNOWN rather than implying health" || bad "t1.detail" "$OUT"

echo "--- test 2: lake present, no retro action at all -> no-signal (the genuine steady state) ---"
L="$TMP/l2"; new_lake "$L"
jq -nc --arg ts "$NOW_TS" '{event:"ran",ts:$ts,plans:[{board:"3",actions:[{action:"no-op"}]}]}' \
  >> "$L/pipeline-$NOW_MONTH.jsonl"
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "no-signal" ] \
  && ok "status=no-signal — nothing was due" || bad "t2.status" "$OUT"
jq -e '.detail | test("no retros were due")' <<<"$OUT" >/dev/null \
  && ok "the detail states the 'no retros were due' reading explicitly" || bad "t2.detail" "$OUT"

echo "--- test 3: a refusal is REFUSED, not a defect, and names its reason ---"
L="$TMP/l3"; new_lake "$L"
wake "$L" skip-retro-judge not-declared
wake "$L" skip-retro-judge not-declared
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "refused" ] \
  && ok "status=refused for a legibly-declining trigger" || bad "t3.status" "$OUT"
[ "$(jq -r '.skips["not-declared"]' <<<"$OUT")" = "2" ] \
  && ok "the refusal reasons are counted by reason" || bad "t3.skips" "$OUT"

echo "--- test 4: a headless-unsupported refusal is called out as ACTIONABLE ---"
L="$TMP/l4"; new_lake "$L"
wake "$L" skip-retro-judge headless-unsupported
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "refused" ] \
  && ok "status=refused (the seam declined; it did not silently succeed)" || bad "t4.status" "$OUT"
jq -e '.detail | test("headless-unattended") and test("ACTIONABLE")' <<<"$OUT" >/dev/null \
  && ok "the detail names the actionable gap and its remedy" || bad "t4.detail" "$OUT"

echo "--- test 5: THE 2026-08-05 FAILURE — trigger fired, stream never had a row -> defect ---"
L="$TMP/l5"; new_lake "$L"
wake "$L" retro-judge
wake "$L" retro-judge
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "defect" ] \
  && ok "status=defect — a fired trigger with no rows is NOT a steady state" || bad "t5.status" "$OUT"
[ "$(jq -r '.defect_kind' <<<"$OUT")" = "never-had-a-row" ] \
  && ok "defect_kind=never-had-a-row (the loop has never closed)" || bad "t5.kind" "$OUT"
[ "$(jq -r '.judge_actions' <<<"$OUT")" = "2" ] \
  && ok "the trigger count is reported (2)" || bad "t5.count" "$OUT"
[ "$(jq -r '.retro_runs.stream_present' <<<"$OUT")" = "false" ] \
  && ok "an absent retro-runs stream is reported as absent, not assumed empty-but-fine" || bad "t5.present" "$OUT"

echo "--- test 6: a present-but-empty retro-runs file is still never-had-a-row ---"
L="$TMP/l6"; new_lake "$L"; : > "$L/retro-runs-$NOW_MONTH.jsonl"
wake "$L" retro-judge
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "defect" ] && [ "$(jq -r '.defect_kind' <<<"$OUT")" = "never-had-a-row" ] \
  && ok "an existing but row-less stream is the same defect (presence != rows)" || bad "t6.status" "$OUT"
[ "$(jq -r '.retro_runs.stream_present' <<<"$OUT")" = "true" ] \
  && ok "stream_present distinguishes 'file exists' from 'file has rows'" || bad "t6.present" "$OUT"

echo "--- test 7: rows exist historically but none in the window -> defect(stalled) ---"
L="$TMP/l7"; new_lake "$L"
jq -nc --arg ts "$OLD_TS" '{ts:$ts,event:"retro-run"}' > "$L/retro-runs-2019-01.jsonl"
wake "$L" retro-judge
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "defect" ] && [ "$(jq -r '.defect_kind' <<<"$OUT")" = "stalled" ] \
  && ok "defect_kind=stalled — distinguished from never-had-a-row" || bad "t7.kind" "$OUT"
[ "$(jq -r '.retro_runs.rows_ever' <<<"$OUT")" = "1" ] && [ "$(jq -r '.retro_runs.rows_in_window' <<<"$OUT")" = "0" ] \
  && ok "rows_ever is whole-history while rows_in_window respects the window" || bad "t7.rows" "$OUT"

echo "--- test 8: trigger fired AND a row landed -> healthy ---"
L="$TMP/l8"; new_lake "$L"
jq -nc --arg ts "$NOW_TS" '{ts:$ts,event:"retro-run",judged:2}' > "$L/retro-runs-$NOW_MONTH.jsonl"
wake "$L" retro-judge
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "healthy" ] \
  && ok "status=healthy when the loop actually closed" || bad "t8.status" "$OUT"

echo "--- test 9: a separate RETRO_RUNS_RAW_DIR is honored ---"
L="$TMP/l9"; new_lake "$L"; R="$TMP/l9-retro"; mkdir -p "$R"
jq -nc --arg ts "$NOW_TS" '{ts:$ts,event:"retro-run"}' > "$R/retro-runs-$NOW_MONTH.jsonl"
wake "$L" retro-judge
OUT="$(run "$L" "$R")"
[ "$(jq -r '.status' <<<"$OUT")" = "healthy" ] \
  && ok "the retro-runs stream can live in its own dir" || bad "t9.status" "$OUT"

echo "--- test 10: read-only + always exit 0 (fail-open) ---"
L="$TMP/l10"; new_lake "$L"
wake "$L" retro-judge
BEFORE="$(find "$L" -type f | sort | xargs -I{} shasum {} | shasum | cut -c1-40)"
run "$L" >/dev/null; rc=$?
AFTER="$(find "$L" -type f | sort | xargs -I{} shasum {} | shasum | cut -c1-40)"
[ "$rc" -eq 0 ] && ok "exit 0 even on a defect verdict (the verdict is .status, never the exit code)" || bad "t10.rc" "rc=$rc"
[ "$BEFORE" = "$AFTER" ] && ok "the lake is byte-identical afterwards (read-only)" || bad "t10.readonly" "lake mutated"

echo "--- test 11: --format report renders a human verdict line ---"
OUT="$(PIPELINE_RAW_DIR="$L" RETRO_RUNS_RAW_DIR="$L" bash "$SCRIPT" --days 30 --format report)"
grep -q "VERDICT: defect (never-had-a-row)" <<<"$OUT" \
  && ok "the report format names the verdict and its kind" || bad "t11.report" "$OUT"

echo "--- test 12: a spawn-site AUTH failure is its own verdict, not 'the judge produces nothing' ---"
# temperloop#1148. The credential dies at the second hop, so the judge never
# authenticates — a HOST problem with a one-line remedy. Collapsing it into
# never-had-a-row would send the operator after the judge instead of the token.
# The signal is the stable `retro-judge-auth-failed` token the spawn wrapper
# emits and the 5b driver records into the {event:"drive"} record.
L="$TMP/l12"; new_lake "$L"
wake "$L" retro-judge
jq -nc --arg ts "$NOW_TS" \
  '{event:"drive",ts:$ts,status:"ran",driven:1,safe_executed:0,safe_failed:1,
    result:{executed:0,failed:1,refused:0,results:[
      {action:"retro-judge",board:"3",status:"failed",
       note:"retro-judge-auth-failed: the nested judge could not authenticate (credential_source=oauth-token, present=true) — no judgment ran"}]}}' \
  >> "$L/pipeline-$NOW_MONTH.jsonl"
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "defect" ] \
  && ok "status=defect" || bad "t12.status" "$OUT"
[ "$(jq -r '.defect_kind' <<<"$OUT")" = "auth" ] \
  && ok "defect_kind=auth outranks never-had-a-row (a credential problem, not a broken judge)" \
  || bad "t12.kind" "$OUT"
[ "$(jq -r '.auth_failures' <<<"$OUT")" = "1" ] \
  && ok "auth_failures counts the drive records carrying the token" || bad "t12.count" "$OUT"
jq -e '.detail | test("build.config.local.sh")' <<<"$OUT" >/dev/null \
  && ok "the detail names the remedy (the gitignored mode-600 local config)" || bad "t12.remedy" "$OUT"
jq -e '.detail | test("never in a tracked file")' <<<"$OUT" >/dev/null \
  && ok "…and restates that the token must never land in a tracked file" || bad "t12.security" "$OUT"

echo "--- test 13: a drive record WITHOUT the token leaves the verdict untouched ---"
# The disconfirming control for test 12: the auth verdict must key on the token,
# not merely on the presence of a drive record carrying a failure.
L="$TMP/l13"; new_lake "$L"
wake "$L" retro-judge
jq -nc --arg ts "$NOW_TS" \
  '{event:"drive",ts:$ts,status:"ran",driven:1,safe_failed:1,
    result:{executed:0,failed:1,refused:0,results:[
      {action:"retro-judge",board:"3",status:"failed",note:"judge exited clean with zero judgments"}]}}' \
  >> "$L/pipeline-$NOW_MONTH.jsonl"
OUT="$(run "$L")"
[ "$(jq -r '.auth_failures' <<<"$OUT")" = "0" ] \
  && ok "auth_failures=0 for a non-auth failure" || bad "t13.count" "$OUT"
[ "$(jq -r '.defect_kind' <<<"$OUT")" = "never-had-a-row" ] \
  && ok "the pre-existing #1150 verdict is unchanged" || bad "t13.kind" "$OUT"

echo "--- test 14: SYMLINK CLIMB — a checkout whose workflows/scripts/build is a symlink into kernel/ resolves the RETRO-RUNS default to the CHECKOUT ROOT, not <checkout>/kernel (temperloop#1185) ---"
# Fabricates the vendored layout the live bug report named: workflows ->
# kernel/workflows (a directory symlink), so the script's own dir climbs
# THROUGH the symlink under the old `cd -P` resolution and lands 3 levels up
# inside kernel/ instead of the checkout root. Only the RETRO-RUNS default is
# exercised here (PIPELINE_RAW_DIR is pinned explicitly, isolating this case
# to the symlink-climb defect alone) — the checkout-root lake carries the
# in-window row; the kernel stub carries none. Fails against pre-fix code,
# which reads the kernel stub (empty) and reports never-had-a-row instead.
FAKE="$TMP/symlink-checkout"
mkdir -p "$FAKE/kernel/workflows/scripts/build" "$FAKE/kernel/meta/data/raw"
mkdir -p "$FAKE/meta/data/raw"
ln -s kernel/workflows "$FAKE/workflows"
cp "$SCRIPT" "$FAKE/kernel/workflows/scripts/build/pipeline-retro-health.sh"
new_lake "$TMP/l14-pipeline"
wake "$TMP/l14-pipeline" retro-judge
jq -nc --arg ts "$NOW_TS" '{ts:$ts,event:"retro-run",judged:1}' > "$FAKE/meta/data/raw/retro-runs-$NOW_MONTH.jsonl"
OUT="$(PIPELINE_RAW_DIR="$TMP/l14-pipeline" bash "$FAKE/workflows/scripts/build/pipeline-retro-health.sh" --days 30)"
[ "$(jq -r '.status' <<<"$OUT")" = "healthy" ] \
  && ok "resolved the CHECKOUT ROOT's retro-runs stream, not the kernel/ stub — status=healthy" \
  || bad "t14.status" "$OUT"
[ "$(jq -r '.retro_runs.rows_in_window' <<<"$OUT")" = "1" ] \
  && ok "read the checkout-root row, proving the symlinked build/ dir did not divert resolution into kernel/" \
  || bad "t14.rows" "$OUT"

echo "--- test 15: PIPELINE default equals the WRITER's own absolute pin (\$HOME/dev/foundation/meta/data/raw), not a checkout-relative guess (temperloop#1185) ---"
# HOME is faked and the real pipeline_dir default is exercised (PIPELINE_RAW_DIR
# and TELEMETRY_RAW_DIR both left unset) — proving the default follows $HOME,
# which only happens if it's the literal pipeline-cron.sh pins, not $raw_root
# (this checkout's own real root, which holds no pipeline-*.jsonl and would
# report no-lake). RETRO_RUNS_RAW_DIR is pinned to an empty dir so only the
# PIPELINE-stream default is under test.
FAKE_HOME="$TMP/fakehome15"
mkdir -p "$FAKE_HOME/dev/foundation/meta/data/raw" "$TMP/l15-retro"
new_lake "$FAKE_HOME/dev/foundation/meta/data/raw"
wake "$FAKE_HOME/dev/foundation/meta/data/raw" retro-judge
OUT="$(HOME="$FAKE_HOME" RETRO_RUNS_RAW_DIR="$TMP/l15-retro" bash "$SCRIPT" --days 30)"
[ "$(jq -r '.judge_actions' <<<"$OUT")" = "1" ] \
  && ok "read the trigger from \$HOME/dev/foundation/meta/data/raw with no PIPELINE_RAW_DIR/TELEMETRY_RAW_DIR override" \
  || bad "t15.judge_actions" "$OUT"
[ "$(jq -r '.status' <<<"$OUT")" != "no-lake" ] \
  && ok "did not fall back to this checkout's own (real, empty) lake" || bad "t15.status" "$OUT"

echo "--- test 16: the PIPELINE default literal is provably equal to pipeline-cron.sh's own RAW_DIR literal ---"
CRON_SCRIPT="$HERE/../pipeline-cron.sh"
cron_literal="$(grep -oE 'RAW_DIR="\$\{PIPELINE_RAW_DIR:-[^}]*\}"' "$CRON_SCRIPT" \
  | sed -E 's/^RAW_DIR="\$\{PIPELINE_RAW_DIR:-(.*)\}"$/\1/')"
health_literal="$(grep -oE 'pipeline_dir="\$HOME/dev/foundation/meta/data/raw"' "$SCRIPT" \
  | sed -E 's/^pipeline_dir="(.*)"$/\1/')"
[ -n "$cron_literal" ] && [ -n "$health_literal" ] && [ "$cron_literal" = "$health_literal" ] \
  && ok "pipeline-cron.sh's writer default ($cron_literal) matches pipeline-retro-health.sh's reader default verbatim" \
  || bad "t16.equal" "cron=$cron_literal health=$health_literal"

echo "--- test 17: TELEMETRY_RAW_DIR still wins for BOTH streams when explicitly set (override precedence unchanged) ---"
L="$TMP/l17"; new_lake "$L"
wake "$L" retro-judge
jq -nc --arg ts "$NOW_TS" '{ts:$ts,event:"retro-run",judged:1}' > "$L/retro-runs-$NOW_MONTH.jsonl"
OUT="$(TELEMETRY_RAW_DIR="$L" bash "$SCRIPT" --days 30)"
[ "$(jq -r '.status' <<<"$OUT")" = "healthy" ] \
  && ok "a bare TELEMETRY_RAW_DIR override still supplies BOTH the pipeline and retro-runs dirs" \
  || bad "t17.status" "$OUT"

echo "--- test 18: RETRO-RUNS stream is NOT pinned to the pipeline writer's absolute root — it stays checkout-relative ---"
# The critical non-convergence guard from the item's own notes: retro-runs
# rows exist in BOTH lakes, and pinning this stream to the writer's absolute
# root would make the probe MISS rows the judge wrote under a different
# checkout. FAKE_HOME2's meta/data/raw carries a HEALTHY-looking retro-runs
# row that only a WRONGLY-converged retro_dir would ever see; this checkout's
# own (real) root carries none. Only PIPELINE_RAW_DIR is pinned, so a
# defect(never-had-a-row) verdict here proves retro_dir stayed
# checkout-relative rather than following pipeline_dir's $HOME-anchored
# default — a healthy verdict would mean the two streams wrongly converged.
FAKE_HOME2="$TMP/fakehome18"
mkdir -p "$FAKE_HOME2/dev/foundation/meta/data/raw"
jq -nc --arg ts "$NOW_TS" '{ts:$ts,event:"retro-run",judged:1}' \
  > "$FAKE_HOME2/dev/foundation/meta/data/raw/retro-runs-$NOW_MONTH.jsonl"
L="$TMP/l18"; new_lake "$L"
wake "$L" retro-judge
OUT="$(HOME="$FAKE_HOME2" PIPELINE_RAW_DIR="$L" bash "$SCRIPT" --days 30)"
[ "$(jq -r '.status' <<<"$OUT")" = "defect" ] && [ "$(jq -r '.defect_kind' <<<"$OUT")" = "never-had-a-row" ] \
  && ok "retro-runs resolved against the CHECKOUT root, independent of the pipeline stream's absolute default" \
  || bad "t18.status" "$OUT"

echo
echo "pipeline-retro-health tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
