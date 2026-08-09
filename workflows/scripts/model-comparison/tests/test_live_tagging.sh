#!/usr/bin/env bash
#
# test_live_tagging.sh — fixture suite for
# workflows/scripts/model-comparison/tagging.sh (temperloop#1257, epic
# #1225 "model comparison harness"): live candidate tagging provenance — a
# bounded window record, the PR provenance stamp, the telemetry tag (riding
# emit-model-usage.sh's existing raw lake, temperloop#1253/#1255), and the
# mechanical cross-check between all three.
#
# Covers every acceptance bullet on temperloop#1257:
#   - NO NEW SELECTION MECHANISM: the model is ALWAYS SWEEP_WORKER_MODEL —
#     resolve-model reflects it exactly, `tag` has no --model flag at all
#     (tests 1-4)
#   - live-tagging designation is governed by the SAME committed provider
#     allowlist file the rest of the module reads (tests 5-7, plus a
#     personal-narrowing-override fixture proving it is the SAME check, not
#     a re-derived one)
#   - the three artifacts `tag` produces: the window record, the telemetry
#     tag (a real emit-model-usage.sh raw-lake record), and the PR
#     provenance stamp naming model+provider only (tests 8-11)
#   - the mechanical three-way cross-check (stamp / window record /
#     telemetry-lake record) and — the single most important guarantee here —
#     that it FAILS when the PR stamp and the recorded provenance disagree,
#     in every direction a disagreement can occur (tests 12-20)
#   - FAIL-CLOSED: absent / unreadable / malformed / ambiguous input on
#     every side (PR body, window file, usage file, run id) is a distinct
#     CANNOT EVALUATE, never a silent pass and never a partial verdict
#     (tests 21-30)
#   - a trailing operand-taking flag with no value fails fast and bounded,
#     never hangs (test 31, fleet-wide #1342)
#
# Hermetic: no network, no live model call (kernel principle 3). Every path
# is an explicit env-var override (LIVE_TAG_WINDOW_LOG / MODEL_USAGE_RAW_DIR
# / the allowlist's own PROVIDER_ALLOWLIST_TEST_SEAM path seams) pointed at a
# throwaway $TMPDIR — never this repo's real state.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays).

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd -P "$HERE/.." && pwd)"
REPO_ROOT="$(cd -P "$MC_DIR/../../.." && pwd)"
SUT="$MC_DIR/tagging.sh"
EMIT="$REPO_ROOT/workflows/scripts/emit-model-usage.sh"

[ -f "$SUT" ] || { echo "FATAL: tagging.sh not found at $SUT" >&2; exit 1; }
[ -f "$EMIT" ] || { echo "FATAL: emit-model-usage.sh not found at $EMIT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

PORTABLE_TIMEOUT="$REPO_ROOT/workflows/scripts/lib/portable-timeout.sh"
[ -f "$PORTABLE_TIMEOUT" ] || { echo "FATAL: portable-timeout.sh not found at $PORTABLE_TIMEOUT" >&2; exit 1; }
# shellcheck source=../../lib/portable-timeout.sh
. "$PORTABLE_TIMEOUT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-live-tagging-XXXXXX")"
TMP="$(cd -P "$TMP" && pwd)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0; total=0
ok()  { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1" >&2; }
count() { total=$((total + 1)); }
check_eq() { # <desc> <want> <got>
  count
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$2], got [$3])"; exit 1; fi
}
check_rc() { # <desc> <want-rc> <got-rc>
  count
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want rc=$2, got rc=$3)"; exit 1; fi
}
check_contains() { # <desc> <haystack> <needle>
  count
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1 (expected to contain: $3 | got: $2)"; exit 1 ;;
  esac
}
check_not_contains() { # <desc> <haystack> <needle>
  count
  case "$2" in
    *"$3"*) bad "$1 (expected to NOT contain: $3 | got: $2)"; exit 1 ;;
    *) ok "$1" ;;
  esac
}

# A per-test scratch env: an isolated window log + raw lake, a fresh
# SWEEP_WORKER_MODEL/session id. Each test gets its OWN subdir so records
# from one test can never bleed into another's crosscheck.
n=0
fresh_env() {  # sets ENVDIR / WIN / RAWDIR — call BARE (not via $()), it sets globals
  n=$((n + 1))
  ENVDIR="$TMP/env$n"
  mkdir -p "$ENVDIR/raw"
  WIN="$ENVDIR/win.jsonl"
  RAWDIR="$ENVDIR/raw"
}

run_tag() {  # env vars must already be exported by the caller
  OUT="$(bash "$SUT" tag "$@" 2>"$TMP/.err")"; RC=$?
  ERR="$(cat "$TMP/.err")"
}
run_crosscheck() {
  OUT="$(bash "$SUT" crosscheck "$@" 2>"$TMP/.err")"; RC=$?
  ERR="$(cat "$TMP/.err")"
}
run_resolve() {
  OUT="$(bash "$SUT" resolve-model 2>"$TMP/.err")"; RC=$?
  ERR="$(cat "$TMP/.err")"
}

echo "═══ 1-4: NO NEW SELECTION MECHANISM — SWEEP_WORKER_MODEL is the ONE lever ═══"

# 1. resolve-model prints exactly SWEEP_WORKER_MODEL, empty when unset.
SWEEP_WORKER_MODEL="" run_resolve
check_eq "1: resolve-model prints empty when SWEEP_WORKER_MODEL is unset/empty" "" "$OUT"

# 2. resolve-model reflects SWEEP_WORKER_MODEL exactly, whatever it's set to.
SWEEP_WORKER_MODEL="claude-opus-4-8" run_resolve
check_eq "2: resolve-model reflects SWEEP_WORKER_MODEL verbatim" "claude-opus-4-8" "$OUT"

# 3. `tag` has NO --model flag: passing one is a usage error (exit 2), and
#    it must NOT silently override the model that gets recorded.
fresh_env
SWEEP_WORKER_MODEL="claude-opus-4-8" LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" \
  run_tag --provider anthropic --run-id pr:1 --model claude-haiku-4-5
check_rc "3: tag --model is a usage error (exit 2)" "2" "$RC"
check_contains "3b: the usage error explains there is no second selector" "$ERR" "no second selector"
[ ! -s "$WIN" ]; count; if [ ! -s "$WIN" ]; then ok "3c: no window record written on a rejected --model usage error"; else bad "3c: window record written despite rejected --model"; exit 1; fi

# 4. mechanical proof: the ONLY setting name this file resolves the model
#    from is SWEEP_WORKER_MODEL — grep the source for every `_MODEL`-shaped
#    settings seam it reads (a supplementary, not substitute, check —
#    behavioral tests 1-3 above are the load-bearing proof).
count
model_seams="$(grep -oE '\$\{[A-Z_]*_MODEL:?=?[^}]*\}' "$SUT" | grep -oE '^\$\{[A-Z_]*_MODEL' | sed 's/^\${//' | sort -u)"
if [ "$model_seams" = "SWEEP_WORKER_MODEL" ]; then
  ok "4: tagging.sh's source resolves the model from exactly one setting (SWEEP_WORKER_MODEL)"
else
  bad "4: expected exactly one _MODEL-shaped setting seam (SWEEP_WORKER_MODEL), found: $model_seams"; exit 1
fi

echo "═══ 5-7: allowlist governance — the SAME committed file, reused not re-derived ═══"

# 5. An unlisted provider is refused; no window record, no telemetry tag.
fresh_env
SWEEP_WORKER_MODEL="claude-opus-4-8" LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" \
  run_tag --provider openai --run-id pr:1
check_rc "5: an unlisted provider is refused (exit 1)" "1" "$RC"
check_contains "5b: names the committed allowlist file" "$ERR" "provider-allowlist.txt"
count; if [ ! -s "$WIN" ]; then ok "5c: no window record on a refused provider"; else bad "5c: window record written despite refused provider"; exit 1; fi
count; if [ -z "$(find "$RAWDIR" -name '*.jsonl' 2>/dev/null)" ]; then ok "5d: no telemetry tag on a refused provider"; else bad "5d: telemetry tag written despite refused provider"; exit 1; fi

# 6. The committed allowlist (anthropic-only by default) DOES allow anthropic.
fresh_env
SWEEP_WORKER_MODEL="claude-opus-4-8" LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" \
  run_tag --provider anthropic --run-id pr:2
check_rc "6: the default committed provider (anthropic) is allowed" "0" "$RC"

# 7. Governed by the SAME file — a personal narrowing override (the
#    allowlist module's own documented test seam) that narrows to nothing
#    ALSO refuses tagging.sh, proving it calls the real pa_is_allowed rather
#    than a parallel/re-derived check.
fresh_env
LOCAL_FILE="$ENVDIR/allowlist.local.txt"
DISCLOSURE_LOG="$ENVDIR/disclosure-log.jsonl"
: > "$LOCAL_FILE"   # exists, empty => narrows the effective set to NOTHING
SWEEP_WORKER_MODEL="claude-opus-4-8" LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" \
  PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_LOCAL_FILE="$LOCAL_FILE" PROVIDER_DISCLOSURE_LOG_FILE="$DISCLOSURE_LOG" \
  run_tag --provider anthropic --run-id pr:3
check_rc "7: a personal narrowing override that excludes anthropic ALSO refuses tagging.sh (same check, reused)" "1" "$RC"

echo "═══ 8-11: the three artifacts 'tag' produces ═══"

# 8. The window record: exactly one new line, correct fields.
fresh_env
SWEEP_WORKER_MODEL="claude-opus-4-8" LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" CLAUDE_CODE_SESSION_ID=s8 \
  run_tag --provider anthropic --run-id pr:8 --reason "manual smoke test"
check_rc "8: tag succeeds for an allowed provider + a designated model" "0" "$RC"
count
if [ "$(wc -l <"$WIN" | tr -d ' ')" = "1" ]; then ok "8b: exactly one window-record line written"; else bad "8b: expected exactly 1 line in $WIN"; exit 1; fi
check_eq "8c: window record model" "claude-opus-4-8" "$(jq -r '.model' "$WIN")"
check_eq "8d: window record provider" "anthropic" "$(jq -r '.provider' "$WIN")"
check_eq "8e: window record run_id" "pr:8" "$(jq -r '.run_id' "$WIN")"
check_eq "8f: window record seat" "sweep-live-tag" "$(jq -r '.seat' "$WIN")"
check_eq "8g: window record reason" "manual smoke test" "$(jq -r '.reason' "$WIN")"

# 9. The telemetry tag: a real emit-model-usage.sh record, attribution-only
#    (usage_source unavailable, tokens null, provider null per that
#    script's OWN pairing rule).
count
RAW_LINE="$(cat "$RAWDIR"/model-usage-*.jsonl)"
if [ -n "$RAW_LINE" ]; then ok "9: the telemetry tag landed in the real emit-model-usage.sh raw lake"; else bad "9: no raw-lake record found"; exit 1; fi
check_eq "9b: telemetry tag seat" "sweep-live-tag" "$(printf '%s' "$RAW_LINE" | jq -r '.seat')"
check_eq "9c: telemetry tag model" "claude-opus-4-8" "$(printf '%s' "$RAW_LINE" | jq -r '.model')"
check_eq "9d: telemetry tag usage_source" "unavailable" "$(printf '%s' "$RAW_LINE" | jq -r '.usage_source')"
check_eq "9e: telemetry tag outcome_ref" "pr:8" "$(printf '%s' "$RAW_LINE" | jq -r '.outcome_ref')"
check_eq "9f: telemetry tag carries no tokens (attribution-only)" "null" "$(printf '%s' "$RAW_LINE" | jq -r '.tokens')"

# 10. The PR provenance stamp: model + provider ONLY, never a key, never content.
check_eq "10: the printed stamp names model+provider+run, nothing else" \
  "Model-provenance: model=claude-opus-4-8 provider=anthropic run=pr:8" "$OUT"

# 11. --print-only: the stamp still prints, but NEITHER artifact is written.
fresh_env
SWEEP_WORKER_MODEL="claude-opus-4-8" LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" \
  run_tag --provider anthropic --run-id pr:11 --print-only
check_rc "11: --print-only succeeds" "0" "$RC"
check_eq "11b: --print-only still prints the stamp" "Model-provenance: model=claude-opus-4-8 provider=anthropic run=pr:11" "$OUT"
count; if [ ! -e "$WIN" ]; then ok "11c: --print-only writes NO window record"; else bad "11c: window record written under --print-only"; exit 1; fi
count; if [ -z "$(find "$RAWDIR" -name '*.jsonl' 2>/dev/null)" ]; then ok "11d: --print-only emits NO telemetry tag"; else bad "11d: telemetry tag emitted under --print-only"; exit 1; fi

echo "═══ 12-20: the mechanical cross-check — MUST fail on every disagreement shape ═══"

# Helper: tag a fresh run for real, then build a PR-body file from a
# (possibly doctored) stamp line.
tag_and_body() {  # $1=run-id -> sets STAMP, BODY (path)
  local run_id="$1"
  SWEEP_WORKER_MODEL="claude-opus-4-8" LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" CLAUDE_CODE_SESSION_ID=s \
    run_tag --provider anthropic --run-id "$run_id"
  STAMP="$OUT"
  BODY="$TMP/body-$run_id.txt"
}

# 12. Genuine agreement: OK.
fresh_env
tag_and_body "pr:12"
printf '## Summary\n\n%s\n' "$STAMP" > "$BODY"
LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" run_crosscheck --pr-body "$BODY" --run-id pr:12
check_rc "12: matching stamp+window+telemetry -> OK (exit 0)" "0" "$RC"
check_contains "12b: says OK" "$OUT" "OK"

# 13. THE MANDATORY PROOF: doctor the stamp's MODEL so it disagrees with the
#     real window/telemetry records -> crosscheck FAILS.
fresh_env
tag_and_body "pr:13"
printf '## Summary\n\nModel-provenance: model=claude-haiku-4-5 provider=anthropic run=pr:13\n' > "$BODY"
LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" run_crosscheck --pr-body "$BODY" --run-id pr:13
check_rc "13: MODEL DISAGREEMENT (stamp vs recorded provenance) -> FAIL (exit 1)" "1" "$RC"
check_contains "13b: says FAIL, not CANNOT EVALUATE" "$OUT" "FAIL"
check_not_contains "13c: is not mis-reported as CANNOT EVALUATE" "$OUT" "CANNOT EVALUATE"
check_contains "13d: names both disagreeing models" "$OUT" "claude-haiku-4-5"

# 14. Same proof, PROVIDER dimension: doctor the stamp's provider.
fresh_env
tag_and_body "pr:14"
printf 'Model-provenance: model=claude-opus-4-8 provider=openai run=pr:14\n' > "$BODY"
LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" run_crosscheck --pr-body "$BODY" --run-id pr:14
check_rc "14: PROVIDER DISAGREEMENT (stamp vs window record) -> FAIL (exit 1)" "1" "$RC"
check_contains "14b: says FAIL" "$OUT" "FAIL"

# 15. Stamp present, but NO window/telemetry record for that run id at all
#     (nobody ever called `tag`) -> unverifiable -> FAIL.
fresh_env
printf 'Model-provenance: model=claude-opus-4-8 provider=anthropic run=pr:15\n' > "$TMP/body-15.txt"
LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" run_crosscheck --pr-body "$TMP/body-15.txt" --run-id pr:15
check_rc "15: stamp with no matching window record -> FAIL (unverifiable)" "1" "$RC"
check_contains "15b: says unverifiable" "$OUT" "unverifiable"

# 16. Reverse: a window+telemetry record exists (tagged for real), but the
#     PR body carries NO stamp -> undisclosed candidate authorship -> FAIL.
fresh_env
tag_and_body "pr:16"
printf '## Summary\nordinary PR body, no stamp\n' > "$BODY"
LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" run_crosscheck --pr-body "$BODY" --run-id pr:16
check_rc "16: a live-tagged run with NO PR stamp -> FAIL (undisclosed)" "1" "$RC"
check_contains "16b: says undisclosed" "$OUT" "undisclosed"

# 17. Neither present: legitimately not tagged -> OK.
fresh_env
printf '## Summary\nan ordinary, never-tagged PR\n' > "$TMP/body-17.txt"
LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" run_crosscheck --pr-body "$TMP/body-17.txt" --run-id pr:17
check_rc "17: no stamp, no record -> OK (not live-tagged)" "0" "$RC"

# 18. The stamp's OWN run token disagrees with the requested --run-id -> FAIL.
fresh_env
tag_and_body "pr:18"
printf 'Model-provenance: model=claude-opus-4-8 provider=anthropic run=pr:999\n' > "$BODY"
LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" run_crosscheck --pr-body "$BODY" --run-id pr:18
check_rc "18: stamp's own run token mismatches --run-id -> FAIL" "1" "$RC"

# 19. Window record present + stamp agrees, but the telemetry-lake side is
#     MISSING (simulates emit-model-usage.sh failing/being skipped) -> FAIL.
fresh_env
SWEEP_WORKER_MODEL="claude-opus-4-8" LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" CLAUDE_CODE_SESSION_ID=s \
  run_tag --provider anthropic --run-id pr:19
STAMP="$OUT"
printf '%s\n' "$STAMP" > "$TMP/body-19.txt"
rm -f "$RAWDIR"/model-usage-*.jsonl   # simulate a dropped/failed telemetry emit
LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" run_crosscheck --pr-body "$TMP/body-19.txt" --run-id pr:19
check_rc "19: window+stamp agree but the telemetry tag is MISSING -> FAIL" "1" "$RC"
check_contains "19b: names the missing telemetry-lake record" "$OUT" "telemetry"

# 20. A telemetry-lake record for the SAME outcome_ref but a DIFFERENT seat
#     (some other pipeline seat happens to reuse "pr:20") must be ignored —
#     crosscheck scopes strictly to seat=sweep-live-tag.
fresh_env
SWEEP_WORKER_MODEL="claude-opus-4-8" LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" CLAUDE_CODE_SESSION_ID=s \
  run_tag --provider anthropic --run-id pr:20
STAMP="$OUT"
printf '%s\n' "$STAMP" > "$TMP/body-20.txt"
MODEL_USAGE_RAW_DIR="$RAWDIR" "$EMIT" --seat pipeline-drive-safe --model claude-sonnet-5 --usage-source unavailable --outcome-ref pr:20 >/dev/null
LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" run_crosscheck --pr-body "$TMP/body-20.txt" --run-id pr:20
check_rc "20: a same-outcome_ref record from a DIFFERENT seat is ignored -> still OK" "0" "$RC"

echo "═══ 21-30: FAIL-CLOSED — absent / unreadable / malformed / ambiguous, never a silent pass ═══"

# 21. Absent PR body file.
fresh_env
LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" run_crosscheck --pr-body "$TMP/nope-$n.txt" --run-id pr:21
check_rc "21: absent PR body -> CANNOT EVALUATE (exit 1)" "1" "$RC"
check_contains "21b: says CANNOT EVALUATE" "$OUT$ERR" "CANNOT EVALUATE"

# 22. Unreadable PR body file (chmod 000).
fresh_env
UNREADABLE="$TMP/unreadable-$n.txt"
echo "x" > "$UNREADABLE"
chmod 000 "$UNREADABLE"
LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" run_crosscheck --pr-body "$UNREADABLE" --run-id pr:22
check_rc "22: unreadable PR body -> CANNOT EVALUATE (exit 1)" "1" "$RC"
check_contains "22b: says CANNOT EVALUATE" "$OUT$ERR" "CANNOT EVALUATE"
chmod 700 "$UNREADABLE"

# 23. Malformed --run-id (no issue:/pr: prefix) -> CANNOT EVALUATE.
fresh_env
echo "x" > "$TMP/body23.txt"
LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" run_crosscheck --pr-body "$TMP/body23.txt" --run-id "not-a-run-id"
check_rc "23: malformed --run-id -> CANNOT EVALUATE (exit 1)" "1" "$RC"
check_contains "23b: says CANNOT EVALUATE" "$OUT$ERR" "CANNOT EVALUATE"

# 24. An EXPLICITLY-named --usage-file that does not exist -> CANNOT EVALUATE
#     (distinct from the DEFAULT scan dir being absent, which is legal — see 17).
fresh_env
echo "x" > "$TMP/body24.txt"
run_crosscheck --pr-body "$TMP/body24.txt" --run-id pr:24 --usage-file "$TMP/absent-lake.jsonl"
check_rc "24: explicit --usage-file absent -> CANNOT EVALUATE (exit 1)" "1" "$RC"
check_contains "24b: says CANNOT EVALUATE" "$OUT$ERR" "CANNOT EVALUATE"

# 25. --usage-file exists but is unreadable.
fresh_env
echo "x" > "$TMP/body25.txt"
UNREADABLE_LAKE="$TMP/unreadable-lake-$n.jsonl"
echo '{}' > "$UNREADABLE_LAKE"
chmod 000 "$UNREADABLE_LAKE"
run_crosscheck --pr-body "$TMP/body25.txt" --run-id pr:25 --usage-file "$UNREADABLE_LAKE"
check_rc "25: unreadable --usage-file -> CANNOT EVALUATE (exit 1)" "1" "$RC"
chmod 700 "$UNREADABLE_LAKE"

# 26. --usage-file with a malformed (non-JSON) line -> CANNOT EVALUATE, never
#     a partial verdict computed from the lines it COULD parse.
fresh_env
echo "x" > "$TMP/body26.txt"
MALFORMED_LAKE="$TMP/malformed-$n.jsonl"
printf '{"schema_version":"1","outcome_ref":"pr:99","model":"claude-opus-4-8","provider":null,"seat":"sweep-live-tag"}\nthis is not json\n' > "$MALFORMED_LAKE"
run_crosscheck --pr-body "$TMP/body26.txt" --run-id pr:26 --usage-file "$MALFORMED_LAKE"
check_rc "26: a malformed line ANYWHERE in the scanned file -> CANNOT EVALUATE (exit 1)" "1" "$RC"
check_contains "26b: says CANNOT EVALUATE" "$OUT$ERR" "CANNOT EVALUATE"

# 27. EMPTY --usage-file (0 bytes, legal — "genuinely nothing recorded"),
#     combined with a REAL stamp -> the empty/no-op file still leaves the
#     stamp unverifiable -> a genuine, non-zero FAIL (not CANNOT EVALUATE).
fresh_env
tag_and_body "pr:27"
printf '## Summary\n\n%s\n' "$STAMP" > "$BODY"
EMPTY_LAKE="$TMP/empty-lake-$n.jsonl"
: > "$EMPTY_LAKE"
LIVE_TAG_WINDOW_LOG="$WIN" run_crosscheck --pr-body "$BODY" --run-id pr:27 --usage-file "$EMPTY_LAKE"
check_rc "27: empty --usage-file + a real stamp -> FAIL (unverifiable), non-zero" "1" "$RC"
check_contains "27b: a genuine FAIL, not CANNOT EVALUATE" "$OUT" "FAIL"

# 28. Closed stdin for --pr-body - -> CANNOT EVALUATE, never a silent pass.
fresh_env
CLOSED_RC=0
bash "$SUT" crosscheck --pr-body - --run-id pr:28 <&- >"$TMP/.out28" 2>"$TMP/.err28" || CLOSED_RC=$?
check_rc "28: closed stdin (--pr-body -) -> CANNOT EVALUATE (exit 1)" "1" "$CLOSED_RC"
check_contains "28b: says CANNOT EVALUATE" "$(cat "$TMP/.out28" "$TMP/.err28")" "CANNOT EVALUATE"

# 29. jq missing -> CANNOT EVALUATE (simulate via an empty PATH containing no jq).
fresh_env
echo "x" > "$TMP/body29.txt"
NOJQ_DIR="$TMP/nojq-bin"
mkdir -p "$NOJQ_DIR"
for tool in bash grep sed cat printf date mkdir head tr dirname awk basename; do
  p="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$NOJQ_DIR/$tool" 2>/dev/null
done
NOJQ_RC=0
PATH="$NOJQ_DIR" bash "$SUT" crosscheck --pr-body "$TMP/body29.txt" --run-id pr:29 >"$TMP/.out29" 2>"$TMP/.err29" || NOJQ_RC=$?
check_rc "29: jq unavailable -> CANNOT EVALUATE (exit 1)" "1" "$NOJQ_RC"
check_contains "29b: names jq" "$(cat "$TMP/.out29" "$TMP/.err29")" "jq"

# 30. Ambiguous window records: two DIFFERENT models recorded for the same
#     run id (a hand-edited/corrupted window log) -> CANNOT EVALUATE, never
#     a silent pick-one.
fresh_env
tag_and_body "pr:30"
printf '## Summary\n\n%s\n' "$STAMP" > "$BODY"
printf '{"schema_version":"1","ts":"2020-01-01T00:00:00Z","provider":"anthropic","model":"claude-haiku-4-5","run_id":"pr:30","seat":"sweep-live-tag","reason":null}\n' >> "$WIN"
LIVE_TAG_WINDOW_LOG="$WIN" MODEL_USAGE_RAW_DIR="$RAWDIR" run_crosscheck --pr-body "$BODY" --run-id pr:30
check_rc "30: ambiguous (disagreeing) window records for one run -> CANNOT EVALUATE" "1" "$RC"
check_contains "30b: says CANNOT EVALUATE" "$OUT$ERR" "CANNOT EVALUATE"

echo "═══ 31: hard constraint — a trailing operand-taking flag never hangs (fleet-wide #1342) ═══"
count
rc=0
run_with_timeout 8 bash "$SUT" tag --provider >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 137 ]; then
  ok "31a: tag --provider (trailing, no value) fails fast, bounded"
else
  bad "31a: tag --provider (trailing, no value) rc=$rc (0=silently accepted, 137=HUNG)"; exit 1
fi
count
rc=0
run_with_timeout 8 bash "$SUT" crosscheck --pr-body >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 137 ]; then
  ok "31b: crosscheck --pr-body (trailing, no value) fails fast, bounded"
else
  bad "31b: crosscheck --pr-body (trailing, no value) rc=$rc (0=silently accepted, 137=HUNG)"; exit 1
fi

echo "---"
echo "$pass/$total tests passed"
[ "$pass" -eq "$total" ] || { bad "only $pass of $total tests passed"; exit 1; }
