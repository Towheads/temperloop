#!/usr/bin/env bash
#
# test_judge_calibrate.sh — fixture suite for the CALIBRATE MODE subcommands
# (`calibrate-sample` / `calibrate-record` / `calibrate-status`) added to
# workflows/scripts/model-comparison/dual-build-ledger.sh (temperloop#2082,
# epic #2065 "new-work dual-build harness", ADR 0041). Plain mktemp-fixture
# style, mirroring the sibling test_dual_build_ledger.sh's real-shell,
# zero-network shape. No mapfile / associative arrays / GNU-only flags
# (bash 3.2 compatible, per this directory's existing convention).
#
# Sections:
#   1-3   calibrate-sample: a judged, fully-archived slug is presented
#         BLIND (no `.judge`/`.preference`/`.margin` key anywhere in the
#         printed object) — the discrimination case removes the withholding
#         and proves the suite would catch a leak
#   4     calibrate-sample: an unjudged slug (both rows present, `.judge`
#         null on both) is never sampled
#   5     calibrate-sample: a judged slug missing one arm's archive is
#         never sampled
#   6     calibrate-record: refuses a slug with no judged row at all
#   7     calibrate-record: agreement is COMPUTED here, not caller-supplied
#         — a human preference matching the judge's is `agreement:true`, a
#         mismatched one is `agreement:false`, regardless of what the
#         caller might have hoped
#   8     calibrate-sample: a slug already recorded (calibrate-record) is
#         excluded from a later sample (dedupe)
#   9     calibrate-status: zero pairs recorded reads status
#         "NEVER CALIBRATED" (temperloop#2082's own pinned literal), n=0,
#         agreement_pct=null, bar_pct/bar_n from the two named settings
#   10    the 20-pair/15-agreement acceptance fixture: n=20, agreement_pct=
#         75, status="calibrated" (bar_pct=70, bar_n=20, the ADR 0041/D13
#         values build.config.sh already defaults)
#   11    an override-source pair is recorded `source:"override"` and
#         EXCLUDED from n/agreement_pct (ADR 0041's exclusion) — added on
#         top of the #10 fixture and re-asserting n/agreement_pct unchanged
#         is the actual discrimination: a status computation that folded
#         override rows into the denominator would move off 20/75 here
#   12    calibration.json is written at the PINNED path
#         (<ledger-dir>/calibration.json) after calibrate-record, with the
#         exact shape {n, agreement_pct, status, bar_pct, bar_n} — never a
#         subset or a superset of those five keys
#   13    calibrate-record refuses a --preference outside {baseline,
#         candidate,tie} and a --source outside {blind,override}
#   14    calibrate-sample dies loudly (never silently swallows) when
#         calibration-pairs.jsonl is corrupted — round-2 review fix for
#         temperloop#2082's [MEDIUM]: the pairs-file read had no `|| die`
#         against this file's own stated set-e-omitted invariant
#   15    calibrate-sample's dedupe still excludes an already-recorded slug
#         against a several-thousand-line calibration-pairs.jsonl — the
#         corpus-scale state temperloop#2082's [HIGH] named (a piped
#         `grep -q` SIGPIPEs its writer under `pipefail` once the labelled
#         list is large enough that grep's early exit outraces the writer;
#         a short list, as in #8 above, never reaches that pipe-buffer size)
#   16    round-3 review [HIGH]: a `die()` firing INSIDE the locked critical
#         section of `cmd_calibrate_record` (bar validation inside
#         `_cal_write_status`, triggered here via a genuinely-unconfigured
#         BUILD_CONFIG) must release `.append.lock` rather than strand it —
#         reproduces the exact leak the reviewer found and proves a
#         subsequent call against the same dir is not left wedged
#   17    round-3 review [MEDIUM]: a corrupted rows.jsonl makes
#         calibrate-record die with a "could not read" message, not the
#         misleading "no judged row found" message a swallowed jq failure
#         would produce
#   18    round-3 review [MEDIUM]: an explicit per-invocation pin of
#         DUAL_BUILD_CALIBRATION_BAR_PCT/_BAR_N overrides a hostile ambient
#         export — the discrimination for §10-12 now pinning their own
#         bar fixture instead of coinciding with whatever the environment
#         (or build.config.sh's default) happens to declare
#   19    round-3 review [LOW]: calibrate-sample's dedupe still excludes a
#         dash-leading slug already recorded — `grep -Fx --` guards against
#         the slug being parsed as a grep option
#
# Usage: bash workflows/scripts/model-comparison/tests/test_judge_calibrate.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../dual-build-ledger.sh"

pass=0; total=0
ok()    { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
count() { total=$((total + 1)); }
fail()  { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-judge-calibrate.XXXXXX")" || exit 1
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

sut() { bash "$SUT" "$@"; }

# sut_cal_pinned — same as sut(), but with the calibration bars PINNED for
# this one invocation rather than left to fall through to whatever
# build.config.sh (or a hostile ambient export) happens to declare. §10-12
# assert the literals 70/20/75/"calibrated" on the bar values themselves,
# so those sections must supply their own fixture bar rather than
# coincide with the current config default — same shape as the sibling
# test_dual_build_ledger.sh's `DUAL_BUILD_ARCHIVE_RETENTION_DAYS=30 sut
# prune …` pin (round-3 review [MEDIUM]).
sut_cal_pinned() { DUAL_BUILD_CALIBRATION_BAR_PCT=70 DUAL_BUILD_CALIBRATION_BAR_N=20 bash "$SUT" "$@"; }

# row <slug> <arm> <judge-json|null> — a minimal, fully-valid ledger row,
# same shape as the sibling test_dual_build_ledger.sh's own `row()` helper.
row() {
  local slug="$1" arm="$2" judge="$3"
  jq -c --arg slug "$slug" --arg arm "$arm" --argjson judge "$judge" \
    '{tier:"sonnet", model:"claude-sonnet-5", slug:$slug, arm:$arm,
      base_sha:"basexxxxx", head_sha:"headxxxxx", start_order:1, gate:"pass",
      cost:{tokens_in:10,tokens_out:20,wall_clock_ms:1000,retry_tokens:0,
            retry_count:0,recovery:false},
      judge:$judge, pick:null,
      override:{applied:false,scope:null,reason:null},
      loss_reason:null, cross_read_attempted:false, guard_armed:"ARMED",
      machinery_version:"v1"}' <<<'{}'
}

# seed_pair <dir> <slug> <judge-preference> — appends both arm rows (with a
# real pairwise judge object on the candidate row) and drops both archive
# patches, i.e. builds one fully-eligible "archived pair" for calibrate-*.
seed_pair() {
  local dir="$1" slug="$2" jpref="$3"
  mkdir -p "$dir/archives"
  sut append --dir "$dir" --row "$(row "$slug" baseline null)" >/dev/null
  sut append --dir "$dir" --row "$(row "$slug" candidate "$(jq -cn --arg p "$jpref" '{preference:$p, margin:5, order_agreement:true}')")" >/dev/null
  echo "diff-baseline-$slug" >"$dir/archives/${slug}@baseline.patch"
  echo "diff-candidate-$slug" >"$dir/archives/${slug}@candidate.patch"
}

# ── 1-3. calibrate-sample presents BLIND ────────────────────────────────────
count
D1="$WORK/d1"
seed_pair "$D1" blindme baseline
out="$(sut calibrate-sample --dir "$D1" --count 5)" || fail "1: calibrate-sample failed"
[ "$(jq 'length' <<<"$out")" = "1" ] || fail "1: expected exactly 1 sampled pair (got: $out)"
[ "$(jq -r '.[0].slug' <<<"$out")" = "blindme" ] || fail "1: wrong slug sampled (got: $out)"
[ "$(jq -r '.[0].baseline_diff' <<<"$out")" = "diff-baseline-blindme" ] || fail "1: baseline_diff did not carry the archived patch text (got: $out)"
[ "$(jq -r '.[0].candidate_diff' <<<"$out")" = "diff-candidate-blindme" ] || fail "1: candidate_diff did not carry the archived patch text (got: $out)"
ok "1 calibrate-sample presents a judged, fully-archived pair with both diffs"

count
# DISCRIMINATION: the printed object must carry NEITHER a top-level `judge`
# key NOR any of the judge's own `preference`/`margin` values anywhere.
[ "$(jq 'has("judge")' <<<"$(jq '.[0]' <<<"$out")")" = "false" ] || fail "2: sampled object carries a judge key — blind property violated"
[[ "$out" != *'"preference"'* ]] || fail "2: sampled output leaked a preference field — blind property violated"
[[ "$out" != *'"margin"'* ]] || fail "2: sampled output leaked a margin field — blind property violated"
ok "2 calibrate-sample withholds the judge's own preference/margin (the blind property)"

count
# The actual discrimination proof: this is not vacuously true because the
# fields never existed anywhere upstream — seed_pair's own candidate row
# genuinely carries them (proven directly against the ledger), so a
# regression that stopped stripping them before printing WOULD be caught.
raw_row="$(sut read --dir "$D1" | jq -c '.[] | select(.slug=="blindme" and .arm=="candidate")')"
[[ "$raw_row" == *'"preference":"baseline"'* ]] || fail "3: the underlying row must genuinely carry a judge preference for #2's negative check to mean anything"
ok "3 the withheld preference genuinely exists upstream (proves #2 is a real discrimination, not a vacuous one)"

# ── 4. an unjudged slug is never sampled ────────────────────────────────────
count
D4="$WORK/d4"
mkdir -p "$D4/archives"
sut append --dir "$D4" --row "$(row nojudge baseline null)" >/dev/null
sut append --dir "$D4" --row "$(row nojudge candidate null)" >/dev/null
echo b >"$D4/archives/nojudge@baseline.patch"
echo c >"$D4/archives/nojudge@candidate.patch"
out="$(sut calibrate-sample --dir "$D4" --count 5)" || fail "4: calibrate-sample failed"
[ "$(jq 'length' <<<"$out")" = "0" ] || fail "4: an unjudged slug was sampled (got: $out)"
ok "4 calibrate-sample never samples a slug with no judge verdict on either arm row"

# ── 5. a slug missing one arm's archive is never sampled ───────────────────
count
D5="$WORK/d5"
mkdir -p "$D5/archives"
sut append --dir "$D5" --row "$(row halfarch baseline null)" >/dev/null
sut append --dir "$D5" --row "$(row halfarch candidate "$(jq -cn '{preference:"tie", margin:0, order_agreement:true}')")" >/dev/null
echo b >"$D5/archives/halfarch@baseline.patch"
# candidate archive deliberately absent
out="$(sut calibrate-sample --dir "$D5" --count 5)" || fail "5: calibrate-sample failed"
[ "$(jq 'length' <<<"$out")" = "0" ] || fail "5: a slug missing one arm's archive was sampled (got: $out)"
ok "5 calibrate-sample never samples a slug missing either arm's patch archive"

# ── 6. calibrate-record refuses an unjudged slug ────────────────────────────
count
out="$(sut calibrate-record --dir "$D4" --slug nojudge --preference tie --source blind 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "6: calibrate-record accepted an unjudged slug"
[[ "$out" == *"no judged row found"* ]] || fail "6: wrong/no error for an unjudged slug (got: $out)"
ok "6 calibrate-record refuses to record a pair against a slug with no judge verdict"

# ── 7. agreement is COMPUTED, not caller-supplied ───────────────────────────
count
D7="$WORK/d7"
seed_pair "$D7" agreecase baseline
seed_pair "$D7" disagreecase baseline
r_agree="$(sut calibrate-record --dir "$D7" --slug agreecase --preference baseline --source blind)" || fail "7a: calibrate-record failed"
[ "$(jq -r .agreement <<<"$r_agree")" = "true" ] || fail "7a: a human preference matching the judge's must compute agreement:true (got: $r_agree)"
r_dis="$(sut calibrate-record --dir "$D7" --slug disagreecase --preference candidate --source blind)" || fail "7b: calibrate-record failed"
[ "$(jq -r .agreement <<<"$r_dis")" = "false" ] || fail "7b: a mismatched human preference must compute agreement:false (got: $r_dis)"
[ "$(jq -r .judge_preference <<<"$r_dis")" = "baseline" ] || fail "7b: judge_preference must reflect the ACTUAL judge verdict, not the human's answer (got: $r_dis)"
ok "7 calibrate-record computes agreement itself from the real judge verdict, never from the caller's say-so"

# ── 8. an already-recorded slug is excluded from a later sample ────────────
count
out="$(sut calibrate-sample --dir "$D7" --count 5)" || fail "8: calibrate-sample failed"
[ "$(jq 'length' <<<"$out")" = "0" ] || fail "8: an already-recorded slug was re-sampled (got: $out)"
ok "8 calibrate-sample dedupes — a slug already recorded via calibrate-record is never sampled again"

# ── 9. zero pairs recorded -> NEVER CALIBRATED ──────────────────────────────
count
D9="$WORK/d9"
out="$(sut calibrate-status --dir "$D9")" || fail "9: calibrate-status failed on a never-touched dir"
[ "$(jq -r .n <<<"$out")" = "0" ] || fail "9: n must be 0 with no calibration-pairs.jsonl (got: $out)"
[ "$(jq -r .status <<<"$out")" = "NEVER CALIBRATED" ] || fail "9: status must be the pinned literal 'NEVER CALIBRATED' (got: $out)"
[ "$(jq -r .agreement_pct <<<"$out")" = "null" ] || fail "9: agreement_pct must be null when n=0 (got: $out)"
[ -f "$D9/calibration.json" ] || fail "9: calibrate-status must still write calibration.json at the pinned path even with zero pairs"
[ "$(cat "$D9/calibration.json")" = "$out" ] || fail "9: the written calibration.json must match calibrate-status's own stdout"
ok "9 zero recorded pairs reads status NEVER CALIBRATED, and calibration.json is still written at the pinned path"

# ── 10. the 20-pair/15-agreement acceptance fixture (75%, calibrated) ──────
count
D10="$WORK/d10"
i=1
while [ "$i" -le 20 ]; do
  slug="pair$i"
  seed_pair "$D10" "$slug" baseline
  if [ "$i" -le 15 ]; then pref=baseline; else pref=candidate; fi
  sut_cal_pinned calibrate-record --dir "$D10" --slug "$slug" --preference "$pref" --source blind >/dev/null || fail "10: calibrate-record failed on $slug"
  i=$((i + 1))
done
out="$(cat "$D10/calibration.json")"
[ "$(jq -r .n <<<"$out")" = "20" ] || fail "10: n must be 20 (got: $out)"
[ "$(jq -r .agreement_pct <<<"$out")" = "75" ] || fail "10: 15/20 agreements must read agreement_pct=75 (got: $out)"
[ "$(jq -r .status <<<"$out")" = "calibrated" ] || fail "10: 75% over 20 pairs must clear the (70%,20) bar and read status=calibrated (got: $out)"
[ "$(jq -r .bar_pct <<<"$out")" = "70" ] && [ "$(jq -r .bar_n <<<"$out")" = "20" ] || fail "10: bar_pct/bar_n must be sourced from DUAL_BUILD_CALIBRATION_BAR_PCT/_BAR_N (got: $out)"
ok "10 a 20-pair fixture with 15 agreements reads n=20, agreement_pct=75, status=calibrated"

# ── 11. an override-source pair is excluded from n/agreement_pct ──────────
count
seed_pair "$D10" overriddenitem candidate
before="$out"
sut_cal_pinned calibrate-record --dir "$D10" --slug overriddenitem --preference baseline --source override --reason "operator override" >/dev/null || fail "11: calibrate-record (override) failed"
after="$(cat "$D10/calibration.json")"
[ "$(jq -r .n <<<"$after")" = "20" ] || fail "11: an override pair must NOT be counted in n (got: $after)"
[ "$(jq -r .agreement_pct <<<"$after")" = "75" ] || fail "11: an override pair must NOT move agreement_pct (got: $after, was: $before)"
recorded="$(grep -F '"overriddenitem"' "$D10/calibration-pairs.jsonl" | tail -n1)"
[ "$(jq -r .source <<<"$recorded")" = "override" ] || fail "11: the override pair must be recorded with source:\"override\" (got: $recorded)"
[ "$(jq -r .agreement <<<"$recorded")" = "false" ] || fail "11: this override was a genuine disagreement (candidate judge vs baseline human) and must record agreement:false"
ok "11 override-derived pairs are recorded source:override and excluded from the blind agreement statistic"

# ── 12. calibration.json's exact shape ──────────────────────────────────────
count
keys="$(jq -cS 'keys' <<<"$after")"
[ "$keys" = '["agreement_pct","bar_n","bar_pct","n","status"]' ] || fail "12: calibration.json must carry exactly {n,agreement_pct,status,bar_pct,bar_n} (got keys: $keys)"
ok "12 calibration.json carries exactly the pinned shape {n, agreement_pct, status, bar_pct, bar_n}"

# ── 13. calibrate-record argument validation ────────────────────────────────
count
out="$(sut calibrate-record --dir "$D10" --slug pair1 --preference nonsense --source blind 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *"--preference must be"* ]] || fail "13a: an invalid --preference must be refused (got rc=$rc: $out)"
out="$(sut calibrate-record --dir "$D10" --slug pair1 --preference tie --source nonsense 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [[ "$out" == *"--source must be"* ]] || fail "13b: an invalid --source must be refused (got rc=$rc: $out)"
ok "13 calibrate-record refuses a --preference/--source outside its closed enum"

# ── 14. a corrupted pairs file makes calibrate-sample die, not swallow ─────
count
D14="$WORK/d14"
seed_pair "$D14" corruptcase baseline
printf '%s\n' '{"slug":"other"}' 'not-json-at-all' >"$D14/calibration-pairs.jsonl"
out="$(sut calibrate-sample --dir "$D14" --count 5 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "14: calibrate-sample must fail loudly on a corrupted calibration-pairs.jsonl (got rc=0: $out)"
[[ "$out" == *"could not read"* ]] || fail "14: expected a 'could not read' die message (got: $out)"
ok "14 a corrupted calibration-pairs.jsonl makes calibrate-sample die loudly rather than silently treating it as an empty dedupe set"

# ── 15. dedupe holds against a large calibration-pairs.jsonl ───────────────
count
D15="$WORK/d15"
seed_pair "$D15" bulkdup baseline
sut calibrate-record --dir "$D15" --slug bulkdup --preference baseline --source blind >/dev/null || fail "15: setup calibrate-record failed"
i=1
while [ "$i" -le 3000 ]; do
  printf '{"slug":"filler-%d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}\n' "$i" >>"$D15/calibration-pairs.jsonl"
  i=$((i + 1))
done
out="$(sut calibrate-sample --dir "$D15" --count 5)" || fail "15: calibrate-sample failed against a large calibration-pairs.jsonl"
[ "$(jq 'length' <<<"$out")" = "0" ] || fail "15: an already-recorded slug must stay excluded even against a several-thousand-line labelled corpus (got: $out)"
ok "15 calibrate-sample's dedupe still excludes an already-recorded slug against a several-thousand-line calibration-pairs.jsonl"

# ── 16. a die() inside the locked critical section releases the lock ──────
count
D16="$WORK/d16"
seed_pair "$D16" lockleak baseline
out="$(BUILD_CONFIG="$WORK/no-such-build-config.sh" sut calibrate-record --dir "$D16" --slug lockleak --preference baseline --source blind 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "16a: calibrate-record must fail when the calibration bars are genuinely unconfigured (got rc=0: $out)"
[ ! -d "$D16/.append.lock" ] || fail "16b: a die() firing inside the locked critical section must not strand .append.lock (round-3 review [HIGH] regression)"
out2="$(sut calibrate-record --dir "$D16" --slug lockleak --preference baseline --source blind)" || fail "16c: a subsequent calibrate-record against the same dir must succeed once the lock is genuinely released (got: $out2)"
ok "16 a die() firing while cmd_calibrate_record holds the lock releases .append.lock instead of stranding it (round-3 review [HIGH])"

# ── 17. a corrupted rows.jsonl makes calibrate-record die, not misdiagnose ─
count
D17="$WORK/d17"
seed_pair "$D17" corruptrows baseline
printf '%s\n' 'not-json-at-all' >>"$D17/rows.jsonl"
out="$(sut calibrate-record --dir "$D17" --slug corruptrows --preference baseline --source blind 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "17a: calibrate-record must fail loudly on a corrupted rows.jsonl (got rc=0: $out)"
[[ "$out" == *"could not read"* ]] || fail "17b: expected a 'could not read' die message, not a misdiagnosed 'no judged row found' (got: $out)"
ok "17 a corrupted rows.jsonl makes calibrate-record die with a read error rather than the misleading 'no judged row found' message (round-3 review [MEDIUM])"

# ── 18. an explicit bar pin overrides a hostile ambient export ────────────
count
D18="$WORK/d18"
export DUAL_BUILD_CALIBRATION_BAR_PCT=1
export DUAL_BUILD_CALIBRATION_BAR_N=1
i=1
while [ "$i" -le 20 ]; do
  slug="bar$i"
  seed_pair "$D18" "$slug" baseline
  if [ "$i" -le 15 ]; then pref=baseline; else pref=candidate; fi
  sut_cal_pinned calibrate-record --dir "$D18" --slug "$slug" --preference "$pref" --source blind >/dev/null || fail "18: calibrate-record failed on $slug"
  i=$((i + 1))
done
unset DUAL_BUILD_CALIBRATION_BAR_PCT DUAL_BUILD_CALIBRATION_BAR_N
out="$(cat "$D18/calibration.json")"
[ "$(jq -r .bar_pct <<<"$out")" = "70" ] && [ "$(jq -r .bar_n <<<"$out")" = "20" ] || fail "18: an explicit per-invocation pin must win over a hostile ambient export of 1/1 (got: $out)"
ok "18 an explicit per-invocation DUAL_BUILD_CALIBRATION_BAR_PCT/_BAR_N pin overrides a hostile ambient export (round-3 review [MEDIUM], the discrimination for §10-12's own pin)"

# ── 19. dedupe survives a dash-leading slug ────────────────────────────────
count
D19="$WORK/d19"
seed_pair "$D19" -dashslug baseline
sut calibrate-record --dir "$D19" --slug -dashslug --preference baseline --source blind >/dev/null || fail "19: setup calibrate-record failed for a dash-leading slug"
out="$(sut calibrate-sample --dir "$D19" --count 5)" || fail "19: calibrate-sample failed"
[ "$(jq 'length' <<<"$out")" = "0" ] || fail "19: a dash-leading slug already recorded must still be excluded from a later sample (got: $out)"
ok "19 calibrate-sample's dedupe correctly excludes a dash-leading slug (grep -Fx -- guards against option-parsing, round-3 review [LOW])"

printf '\ntest_judge_calibrate.sh: %d/%d checks passed\n' "$pass" "$total"
[ "$pass" -eq "$total" ] || exit 1
