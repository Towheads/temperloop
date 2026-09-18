#!/usr/bin/env bash
#
# test_tagging_arms_trailer.sh — fixture suite for the dual-build
# `Model-comparison-arms:` PR trailer (temperloop#2065/#2078, ADR 0040):
# `workflows/scripts/model-comparison/tagging.sh`'s `stamp-arms` (writer)
# and `parse-arms` (its owned inverse).
#
# Covers this item's acceptance bullets:
#   - a fixture body carries both `Model-comparison-arms:` and an unchanged
#     `Model-provenance:` line; the anchored `^Model-provenance: ...$`
#     disclosure check still matches on the two-line body (tests 1-3)
#   - the parse helper round-trips the trailer's fields (baseline,
#     candidate, pick, reason) (tests 4-8)
#   - ADR 0040: this is a SECOND, additive trailer, never a reshape of
#     `Model-provenance:` — `stamp-arms` has no side effects (no window
#     record, no telemetry tag) unlike `tag` (test 9)
#   - fail-closed shape consistent with the rest of this module: absent vs.
#     present-but-malformed are distinct, and every usage error is a bounded
#     exit 2, never a hang or a silent guess (tests 10-24)
#   - a trailing operand-taking flag with no value fails fast and bounded,
#     never hangs (test 25, fleet-wide #1342)
#
# Hermetic: no network, no live model call, no jq/emit-model-usage.sh side
# effects (kernel principle 3) — stamp-arms/parse-arms touch no file this
# repo doesn't explicitly hand them.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays).

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd -P "$HERE/.." && pwd)"
SUT="$MC_DIR/tagging.sh"

[ -f "$SUT" ] || { echo "FATAL: tagging.sh not found at $SUT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

REPO_ROOT="$(cd -P "$MC_DIR/../../.." && pwd)"
PORTABLE_TIMEOUT="$REPO_ROOT/workflows/scripts/lib/portable-timeout.sh"
[ -f "$PORTABLE_TIMEOUT" ] || { echo "FATAL: portable-timeout.sh not found at $PORTABLE_TIMEOUT" >&2; exit 1; }
# shellcheck source=../../lib/portable-timeout.sh
. "$PORTABLE_TIMEOUT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-tagging-arms-XXXXXX")"
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

run_stamp() {
  OUT="$(bash "$SUT" stamp-arms "$@" 2>"$TMP/.err")"; RC=$?
  ERR="$(cat "$TMP/.err")"
}
run_parse() {
  OUT="$(bash "$SUT" parse-arms "$@" 2>"$TMP/.err")"; RC=$?
  ERR="$(cat "$TMP/.err")"
}

echo "═══ 1-3: the trailer rides ALONGSIDE an unchanged Model-provenance line (ADR 0040) ═══"

# 1. stamp-arms emits the exact documented grammar.
run_stamp --baseline claude-sonnet-4-5 --candidate claude-haiku-4-5 --pick candidate --reason "gate-pass + judge preference 0.7"
check_rc "1a: stamp-arms exits 0 on a valid invocation" "0" "$RC"
check_eq "1b: stamp-arms emits the exact documented grammar" \
  'Model-comparison-arms: baseline=claude-sonnet-4-5 candidate=claude-haiku-4-5 pick=candidate reason="gate-pass + judge preference 0.7"' \
  "$OUT"
ARMS_LINE="$OUT"

# 2. A fixture PR body carries BOTH lines. The pre-existing, anchored
#    Model-provenance disclosure regex (tagging.sh's own crosscheck uses
#    this exact pattern) must still match on the two-line body — proving
#    the new trailer is additive, not a reshape.
BODY="$TMP/body.md"
printf '## Summary\n\nSome PR prose.\n\nModel-provenance: model=claude-haiku-4-5 provider=anthropic run=pr:2078\n%s\n' "$ARMS_LINE" > "$BODY"
count
if grep -Eq '^Model-provenance: model=[^[:space:]]+ provider=[^[:space:]]+ run=[^[:space:]]+$' "$BODY"; then
  ok "2: the anchored Model-provenance disclosure check still matches on the two-line body"
else
  bad "2: Model-provenance disclosure regex failed to match the two-line body"; exit 1
fi

# 3. DISCRIMINATION: the SAME regex must NOT match if the two lines were
#    concatenated/merged into one (proving test 2 actually discriminates a
#    genuinely separate line from a corrupted merge, not a regex that would
#    match anything).
BAD_MERGE="$TMP/merged.md"
printf 'Model-provenance: model=claude-haiku-4-5 provider=anthropic run=pr:2078 %s\n' "$ARMS_LINE" > "$BAD_MERGE"
count
if grep -Eq '^Model-provenance: model=[^[:space:]]+ provider=[^[:space:]]+ run=[^[:space:]]+$' "$BAD_MERGE"; then
  bad "3: disclosure regex wrongly matched a corrupted single-line merge — test 2 would never have caught this"; exit 1
else
  ok "3: disclosure regex correctly rejects a corrupted single-line merge (test 2 discriminates)"
fi

echo "═══ 4-8: parse-arms round-trips baseline/candidate/pick/reason ═══"

# 4. Round-trip the fixture from test 1 through parse-arms.
run_parse --pr-body "$BODY"
check_rc "4a: parse-arms exits 0 on a well-formed trailer" "0" "$RC"
check_eq "4b: parse-arms reports present:true"  "true"                "$(printf '%s' "$OUT" | jq -r '.present')"
check_eq "4c: parse-arms round-trips baseline"  "claude-sonnet-4-5"   "$(printf '%s' "$OUT" | jq -r '.baseline')"
check_eq "4d: parse-arms round-trips candidate" "claude-haiku-4-5"    "$(printf '%s' "$OUT" | jq -r '.candidate')"
check_eq "4e: parse-arms round-trips pick"      "candidate"           "$(printf '%s' "$OUT" | jq -r '.pick')"
check_eq "4f: parse-arms round-trips reason"    "gate-pass + judge preference 0.7" "$(printf '%s' "$OUT" | jq -r '.reason')"

# 5. pick=baseline round-trips too (both arm names, not just one).
run_stamp --baseline claude-opus-4-8 --candidate claude-sonnet-4-5 --pick baseline --reason "override: reviewer preferred baseline's style"
check_rc "5a: stamp-arms accepts pick=baseline" "0" "$RC"
BODY2="$TMP/body2.md"
printf '%s\n' "$OUT" > "$BODY2"
run_parse --pr-body "$BODY2"
check_eq "5b: parse-arms round-trips pick=baseline" "baseline" "$(printf '%s' "$OUT" | jq -r '.pick')"
check_eq "5c: parse-arms round-trips a reason containing an apostrophe" \
  "override: reviewer preferred baseline's style" "$(printf '%s' "$OUT" | jq -r '.reason')"

# 6. --pr-body - (stdin) works identically to a file.
run_parse --pr-body - < "$BODY2"
check_eq "6: parse-arms reads --pr-body - from stdin" "baseline" "$(printf '%s' "$OUT" | jq -r '.pick')"

# 7. Absent trailer: a body with no Model-comparison-arms line at all reads
#    present:false, exit 0 — never a failure, never confused with malformed.
BODY_ABSENT="$TMP/absent.md"
printf '## Summary\n\nNothing to disclose here.\n' > "$BODY_ABSENT"
run_parse --pr-body "$BODY_ABSENT"
check_rc "7a: parse-arms exits 0 on an absent trailer" "0" "$RC"
check_eq "7b: parse-arms reports present:false when absent" "{\"present\":false}" "$OUT"

# 8. DISCRIMINATION for 4-7: a hand-corrupted trailer (one field dropped)
#    must NOT round-trip and must NOT read as merely absent either — it is
#    a THIRD, distinct outcome (present-but-malformed, tested in 12-13
#    below). This proves tests 4-7's happy-path assertions are not
#    vacuously true for any input.
BODY_TRUNC="$TMP/trunc.md"
printf 'Model-comparison-arms: baseline=a candidate=b pick=candidate\n' > "$BODY_TRUNC"
run_parse --pr-body "$BODY_TRUNC"
check_rc "8: a truncated (no reason=) trailer does NOT round-trip (non-zero, not silently accepted)" "2" "$RC"

echo "═══ 9: stamp-arms has NO side effects (ADR 0040 — a pure formatter, unlike tag) ═══"
count
BEFORE_FILES="$(find "$TMP" -type f | sort)"
bash "$SUT" stamp-arms --baseline x --candidate y --pick baseline --reason z >/dev/null 2>&1
AFTER_FILES="$(find "$TMP" -type f | sort)"
if [ "$BEFORE_FILES" = "$AFTER_FILES" ]; then
  ok "9: stamp-arms writes no window record, no telemetry tag, no file at all"
else
  bad "9: stamp-arms unexpectedly touched the filesystem"; exit 1
fi

echo "═══ 10-13: present-but-malformed is a DISTINCT outcome from absent ═══"

# 10. A line that starts with the trailer's own key but is missing a field
#     entirely is refused, not silently treated as absent.
BODY_MISSING_PICK="$TMP/missing-pick.md"
printf 'Model-comparison-arms: baseline=a candidate=b reason="x"\n' > "$BODY_MISSING_PICK"
run_parse --pr-body "$BODY_MISSING_PICK"
check_rc "10a: a trailer missing pick= is malformed (exit 2), not absent" "2" "$RC"
check_contains "10b: the malformed message says so" "$ERR" "does not match stamp-arms's exact grammar"

# 11. An invalid pick value (neither baseline nor candidate) is malformed.
BODY_BAD_PICK="$TMP/bad-pick.md"
printf 'Model-comparison-arms: baseline=a candidate=b pick=neither reason="x"\n' > "$BODY_BAD_PICK"
run_parse --pr-body "$BODY_BAD_PICK"
check_rc "11: pick=neither (not baseline/candidate) is malformed (exit 2)" "2" "$RC"

# 12. A field value containing whitespace (would desync the %% * trim) is
#     malformed rather than silently mis-parsed.
BODY_WS="$TMP/ws.md"
printf 'Model-comparison-arms: baseline=a b candidate=c pick=baseline reason="x"\n' > "$BODY_WS"
run_parse --pr-body "$BODY_WS"
check_rc "12: a baseline value containing whitespace is malformed (exit 2)" "2" "$RC"

# 13. DISCRIMINATION: confirm the malformed path is reachable and distinct
#     from BOTH the happy path (test 4, rc=0 present:true) and the absent
#     path (test 7, rc=0 present:false) — all three verdicts are mutually
#     exclusive on these three fixtures.
count
if [ "$RC" != "0" ]; then
  ok "13: malformed (rc=2) is distinct from both present:true (rc=0) and absent (rc=0) — three genuinely different verdicts"
else
  bad "13: malformed input produced rc=0, collapsing into one of the other two verdicts"; exit 1
fi

echo "═══ 14-19: stamp-arms usage/validation errors (fail-closed, exit 2) ═══"

run_stamp --candidate b --pick baseline --reason r
check_rc "14: missing --baseline is a usage error" "2" "$RC"

run_stamp --baseline a --pick baseline --reason r
check_rc "15: missing --candidate is a usage error" "2" "$RC"

run_stamp --baseline a --candidate b --reason r
check_rc "16: missing --pick is a usage error" "2" "$RC"

run_stamp --baseline a --candidate b --pick baseline
check_rc "17: missing --reason is a usage error" "2" "$RC"

run_stamp --baseline a --candidate b --pick sidecar --reason r
check_rc "18: --pick outside {baseline,candidate} is a usage error" "2" "$RC"
check_contains "18b: the error names the two accepted values" "$ERR" "baseline"

run_stamp --baseline "a b" --candidate c --pick baseline --reason r
check_rc "19: --baseline containing whitespace is a usage error" "2" "$RC"

echo "═══ 20-22: reason quoting/newline constraints (keep the emitted grammar parseable) ═══"

run_stamp --baseline a --candidate b --pick baseline --reason 'a "quoted" reason'
check_rc "20: --reason containing a double-quote is a usage error" "2" "$RC"
check_contains "20b: the error explains why" "$ERR" "double-quote"

run_stamp --baseline a --candidate b --pick baseline --reason "$(printf 'line one\nline two')"
check_rc "21: --reason containing a newline is a usage error" "2" "$RC"

run_stamp --baseline a --candidate b --pick candidate --reason "unknown flag next" --bogus
check_rc "22: an unknown stamp-arms flag is a usage error" "2" "$RC"

echo "═══ 23-24: parse-arms input-handling errors ═══"

run_parse --pr-body "$TMP/does-not-exist.md"
check_rc "23: parse-arms on a nonexistent file is a usage error (exit 2)" "2" "$RC"

run_parse
check_rc "24: parse-arms with no --pr-body is a usage error" "2" "$RC"

echo "═══ 25: hard constraint — a trailing operand-taking flag never hangs (fleet-wide #1342) ═══"
count
rc=0
run_with_timeout 8 bash "$SUT" stamp-arms --baseline a --candidate b --pick baseline --reason >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 137 ]; then
  ok "25a: stamp-arms --reason (trailing, no value) fails fast, bounded"
else
  bad "25a: stamp-arms --reason (trailing, no value) rc=$rc (0=silently accepted, 137=HUNG)"; exit 1
fi
count
rc=0
run_with_timeout 8 bash "$SUT" parse-arms --pr-body >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 137 ]; then
  ok "25b: parse-arms --pr-body (trailing, no value) fails fast, bounded"
else
  bad "25b: parse-arms --pr-body (trailing, no value) rc=$rc (0=silently accepted, 137=HUNG)"; exit 1
fi

echo "---"
echo "$pass/$total tests passed"
[ "$pass" -eq "$total" ] || { bad "only $pass of $total tests passed"; exit 1; }
