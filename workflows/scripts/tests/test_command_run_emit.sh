#!/usr/bin/env bash
#
# test_command_run_emit.sh — tests for workflows/scripts/emit-command-run.sh
# and workflows/scripts/validate-command-run-emit.sh, covering both the
# `--resolved` disposition count (temperloop#1084, "sweep telemetry schema
# cannot represent a verdict-resolved item") and the `--reported-no-op`
# disposition count (temperloop#1103, "a /fix no-op run is guaranteed to fail
# the emitter's own reconcile check" — before it, `/fix`'s already-done /
# claimed-elsewhere routes had no fourth field to express "nothing happened,
# on purpose" and so skipped the emit call entirely, leaving NO telemetry
# record for the run).
#
# THE CENTRAL TESTS are the two halves of each fix:
#
#   A. the record can EXPRESS the new disposition (`--resolved` → a `resolved`
#      field; `--reported-no-op` → a `reported_no_op` field), and
#   B. a run whose dispositions do NOT partition items_processed FAILS LOUDLY
#      (non-zero exit, arithmetic named) instead of silently under-reporting —
#      while STILL appending the record, because a dropped record reopens the
#      absent-stream ambiguity this whole emitter exists to close.
#
# Also asserted, because each is an explicit acceptance bar of the item:
#   - `resolved` / `reported_no_op` are emitted on EVERY record from now on
#     (so their ABSENCE is a reliable pre-#1084 / pre-#1103 marker, and absent
#     can be read as UNKNOWN, never 0)
#   - a caller that only passes the original three flags (merged/resolved/
#     parked) still reconciles — `--reported-no-op` defaults to an EXPLICIT 0,
#     never an under-count (the regression that would turn a one-command bug
#     into a fleet-wide one)
#   - infrastructure-class failure still warns + exits 0 (the `|| true`-safe
#     contract): a malformed count never blocks the calling command
#   - the canonical sink spec (meta/data/raw/README.md) documents both fields,
#     the four-way invariant, and the absent-means-unknown caveat
#   - the presence-lint catches a caller that can produce a verdict-resolved
#     or reported-no-op item but omits the matching flag
#
# Synthetic lake under a throwaway tmpdir (CMD_RUN_RAW_DIR). Zero network;
# never writes outside the tmpdir.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../../.." && pwd)"
EMIT="$REPO/workflows/scripts/emit-command-run.sh"
LINT="$REPO/workflows/scripts/validate-command-run-emit.sh"
README="$REPO/meta/data/raw/README.md"
SWEEP_MD="$REPO/claude/commands/sweep.md"
FIX_MD="$REPO/claude/commands/fix.md"
TRIAGE_MD="$REPO/claude/commands/triage.md"

[ -f "$EMIT" ] || { echo "FATAL: emit-command-run.sh not found at $EMIT" >&2; exit 1; }
[ -f "$LINT" ] || { echo "FATAL: validate-command-run-emit.sh not found at $LINT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/command-run-emit-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
check_eq() { # <desc> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi
}
check() { # <desc> <cmd...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d" "command failed: $*"; fi
}

# emit <lake-subdir> <args...> → sets EMIT_OUT / EMIT_ERR / EMIT_RC
emit() {
  local sub="$1"; shift
  local dir="$TMP/$sub"
  mkdir -p "$dir"
  EMIT_OUT="$(CMD_RUN_RAW_DIR="$dir" CLAUDE_CODE_SESSION_ID=sess-1 \
    bash "$EMIT" "$@" 2>"$TMP/err.txt")"
  EMIT_RC=$?
  EMIT_ERR="$(cat "$TMP/err.txt")"
}
lake_lines() { cat "$TMP/$1"/command-runs-*.jsonl 2>/dev/null | wc -l | tr -d ' '; }

echo "── 1. --resolved is accepted and lands in the record ──"
emit l1 --command sweep --board 7 --items-processed 30 --merged 27 --resolved 2 --parked 1
check_eq "exit 0 on a reconciling record" "0" "$EMIT_RC"
check_eq "resolved field carries the count" "2" "$(printf '%s' "$EMIT_OUT" | jq -r '.resolved')"
check_eq "merged is no longer inflated by the verdict-resolved items" "27" "$(printf '%s' "$EMIT_OUT" | jq -r '.merged')"
check_eq "parked unchanged" "1" "$(printf '%s' "$EMIT_OUT" | jq -r '.parked')"
check_eq "one line appended to the lake" "1" "$(lake_lines l1)"
# This is the exact record #1084 was filed over, now expressible end to end.
check "the #1084 sweep now reconciles: 27 + 2 + 1 == 30" \
  bash -c "printf '%s' '$EMIT_OUT' | jq -e '.merged + .resolved + .parked == .items_processed' >/dev/null"

echo "── 2. resolved / reported_no_op are ALWAYS present, so absence stays a reliable marker ──"
emit l2 --command triage --board 4 --items-processed 2 --merged 2
check_eq "exit 0" "0" "$EMIT_RC"
check_eq "omitted --resolved defaults to an EXPLICIT 0, not an absent field" \
  "true" "$(printf '%s' "$EMIT_OUT" | jq -r 'has("resolved")')"
check_eq "...and that default is 0" "0" "$(printf '%s' "$EMIT_OUT" | jq -r '.resolved')"
check_eq "omitted --reported-no-op likewise defaults to an EXPLICIT 0, not an absent field" \
  "true" "$(printf '%s' "$EMIT_OUT" | jq -r 'has("reported_no_op")')"
check_eq "...and that default is 0 too" "0" "$(printf '%s' "$EMIT_OUT" | jq -r '.reported_no_op')"
emit l2b --command sweep
check_eq "the no-counter caller (0/0/0/0/0) still reconciles and exits 0" "0" "$EMIT_RC"
check_eq "...and still carries resolved" "0" "$(printf '%s' "$EMIT_OUT" | jq -r '.resolved')"
check_eq "...and still carries reported_no_op" "0" "$(printf '%s' "$EMIT_OUT" | jq -r '.reported_no_op')"

echo "── 3. THE LOUD FAILURE: dispositions that do not partition the total ──"
# Verbatim the pre-#1084 counts: 30 items, 27 merged, 1 parked, 2 unaccounted.
emit l3 --command sweep --board 7 --items-processed 30 --merged 27 --parked 1
check_eq "exit code is non-zero (2), not a silent 0" "2" "$EMIT_RC"
check "stderr names the arithmetic that failed" \
  bash -c "grep -Fq 'merged(27) + resolved(0) + parked(1) + reported_no_op(0) = 28, but --items-processed is 30' <<<\"\$1\"" _ "$EMIT_ERR"
check "stderr says the record was still appended (never swallowed)" \
  bash -c "grep -Fq 'WAS appended' <<<\"\$1\"" _ "$EMIT_ERR"
check_eq "the record IS on disk despite the failure — an inconsistent record beats no record" \
  "1" "$(lake_lines l3)"
check_eq "...and it is the caller's counts verbatim, not silently 'corrected'" \
  "27" "$(cat "$TMP/l3"/command-runs-*.jsonl | jq -r '.merged')"
# Over-counting is caught too, not just under-counting.
emit l3b --command fix --items-processed 1 --merged 1 --resolved 1
check_eq "an over-count (1+1+0+0 > 1) fails the same way" "2" "$EMIT_RC"
# The #1103 case: a genuine mismatch that only involves the NEW field still
# fails loudly — reported-no-op is not exempt from the accounting check.
emit l3c --command fix --items-processed 1 --reported-no-op 1 --merged 1
check_eq "an over-count via reported_no_op (1+0+0+1 > 1) fails the same way" "2" "$EMIT_RC"

echo "── 3b. THE #1103 CASE: a /fix no-op run now reconciles ──"
emit l3d --command fix --board 7 --items-processed 1 --reported-no-op 1
check_eq "exit 0 on a reconciling no-op record" "0" "$EMIT_RC"
check_eq "reported_no_op field carries the count" "1" "$(printf '%s' "$EMIT_OUT" | jq -r '.reported_no_op')"
check "the #1103 /fix already-done run now reconciles: 0 + 0 + 0 + 1 == 1" \
  bash -c "printf '%s' '$EMIT_OUT' | jq -e '.merged + .resolved + .parked + .reported_no_op == .items_processed' >/dev/null"

echo "── 3c. a THREE-FLAG caller (pre-#1103 shape) still reconciles ──"
# sweep/triage (and any pre-#1103 /fix call site) omit --reported-no-op
# entirely; it must default to an EXPLICIT 0 and contribute +0, never an
# under-count that trips the loud failure above.
emit l3e --command sweep --board 3 --items-processed 4 --merged 3 --resolved 0 --parked 1
check_eq "a three-flag caller (no --reported-no-op) still exits 0" "0" "$EMIT_RC"
check_eq "...reported_no_op defaults to 0 in the record" \
  "0" "$(printf '%s' "$EMIT_OUT" | jq -r '.reported_no_op')"
check "...and the four-way sum still reconciles" \
  bash -c "printf '%s' '$EMIT_OUT' | jq -e '.merged + .resolved + .parked + .reported_no_op == .items_processed' >/dev/null"

echo "── 4. infrastructure-class failure stays warn-and-exit-0 (|| true-safe) ──"
emit l4 --command sweep --items-processed 3 --merged two --parked 1
check_eq "a malformed count warns and exits 0 — a telemetry emit never blocks its caller" "0" "$EMIT_RC"
check "...naming the offending flag" \
  bash -c "grep -Fq -- '--merged must be a non-negative integer' <<<\"\$1\"" _ "$EMIT_ERR"
check_eq "...and writes no record rather than a garbage one" "0" "$(lake_lines l4)"
emit l4b --command ""
check_eq "a missing --command still warns and exits 0" "0" "$EMIT_RC"
# Zero-padded counts must not be read as octal by $(( )) nor break jq.
emit l4c --command sweep --items-processed 08 --merged 08 --resolved 0 --parked 0
check_eq "a zero-padded count is parsed base-10, not octal" "0" "$EMIT_RC"
check_eq "...and normalises in the record" "8" "$(printf '%s' "$EMIT_OUT" | jq -r '.merged')"

echo "── 5. the presence-lint catches a caller that drops --resolved ──"
check "validate-command-run-emit.sh passes on the real tree" bash "$LINT"
# Copy the tree's docs into a fixture repo and strip --resolved from sweep.md;
# the lint must go red. (Fixture, not a mutation of the real checkout.)
FIXR="$TMP/fixture"
mkdir -p "$FIXR/workflows/scripts" "$FIXR/claude/commands"
cp "$EMIT" "$FIXR/workflows/scripts/emit-command-run.sh"
cp "$LINT" "$FIXR/workflows/scripts/validate-command-run-emit.sh"
chmod +x "$FIXR/workflows/scripts/"*.sh
cp "$SWEEP_MD" "$FIXR/claude/commands/sweep.md"
cp "$FIX_MD"   "$FIXR/claude/commands/fix.md"
cp "$TRIAGE_MD" "$FIXR/claude/commands/triage.md"
check "the fixture copy is green before tampering" bash "$FIXR/workflows/scripts/validate-command-run-emit.sh"
grep -v '^  --resolved ' "$SWEEP_MD" > "$FIXR/claude/commands/sweep.md.tmp" \
  && mv "$FIXR/claude/commands/sweep.md.tmp" "$FIXR/claude/commands/sweep.md"
if bash "$FIXR/workflows/scripts/validate-command-run-emit.sh" >"$TMP/lint.out" 2>&1; then
  bad "lint fails when sweep.md drops --resolved" "lint passed on a tampered doc"
else
  ok "lint fails when sweep.md drops --resolved"
fi
check "...and names the verdict-resolved defect in its message" \
  grep -Fq 'omits --resolved' "$TMP/lint.out"
# Restore sweep.md, then break the emitter instead: the lint must also catch
# the script losing --resolved or losing the sum assertion.
cp "$SWEEP_MD" "$FIXR/claude/commands/sweep.md"
sed -e 's/--resolved) resolved=/--RESOLVEDGONE) resolved=/' "$EMIT" > "$FIXR/workflows/scripts/emit-command-run.sh"
chmod +x "$FIXR/workflows/scripts/emit-command-run.sh"
if bash "$FIXR/workflows/scripts/validate-command-run-emit.sh" >"$TMP/lint2.out" 2>&1; then
  bad "lint fails when the emitter stops parsing --resolved" "lint passed"
else
  ok "lint fails when the emitter stops parsing --resolved"
fi
sed -e 's/disposition_total/dtotal_renamed/g' "$EMIT" > "$FIXR/workflows/scripts/emit-command-run.sh"
chmod +x "$FIXR/workflows/scripts/emit-command-run.sh"
if bash "$FIXR/workflows/scripts/validate-command-run-emit.sh" >"$TMP/lint3.out" 2>&1; then
  bad "lint fails when the emitter drops the sum assertion" "lint passed"
else
  ok "lint fails when the emitter drops the sum assertion"
fi
# Restore the emitter, then tamper the same way with --reported-no-op (#1103).
cp "$EMIT" "$FIXR/workflows/scripts/emit-command-run.sh"
chmod +x "$FIXR/workflows/scripts/emit-command-run.sh"

echo "── 5b. the presence-lint catches a caller that drops --reported-no-op (#1103) ──"
# fix.md is the only doc that declares 'reported-no-op' today; strip just the
# code-block flag line (5-space-indented) and confirm the lint goes red.
grep -v -- '^     --reported-no-op ' "$FIX_MD" > "$FIXR/claude/commands/fix.md.tmp" \
  && mv "$FIXR/claude/commands/fix.md.tmp" "$FIXR/claude/commands/fix.md"
if bash "$FIXR/workflows/scripts/validate-command-run-emit.sh" >"$TMP/lint4.out" 2>&1; then
  bad "lint fails when fix.md drops --reported-no-op" "lint passed on a tampered doc"
else
  ok "lint fails when fix.md drops --reported-no-op"
fi
check "...and names the reported-no-op defect in its message" \
  grep -Fq 'omits --reported-no-op' "$TMP/lint4.out"
# Restore fix.md, then break the emitter's --reported-no-op parsing instead.
cp "$FIX_MD" "$FIXR/claude/commands/fix.md"
sed -e 's/--reported-no-op) reported_no_op=/--REPORTEDNOOPGONE) reported_no_op=/' "$EMIT" > "$FIXR/workflows/scripts/emit-command-run.sh"
chmod +x "$FIXR/workflows/scripts/emit-command-run.sh"
if bash "$FIXR/workflows/scripts/validate-command-run-emit.sh" >"$TMP/lint5.out" 2>&1; then
  bad "lint fails when the emitter stops parsing --reported-no-op" "lint passed"
else
  ok "lint fails when the emitter stops parsing --reported-no-op"
fi
cp "$EMIT" "$FIXR/workflows/scripts/emit-command-run.sh"
chmod +x "$FIXR/workflows/scripts/emit-command-run.sh"

echo "── 6. the canonical sink spec documents the field and its caveat ──"
check "README documents the resolved field" grep -Eq '\| .resolved. \| integer' "$README"
check "README documents the reported_no_op field" \
  grep -Eq '\| .reported_no_op. \| integer' "$README"
check "README states the four-way partition invariant" \
  grep -Fq 'merged + resolved + parked + reported_no_op == items_processed' "$README"
check "README states absent-means-UNKNOWN-never-zero for pre-existing records" \
  grep -Fq 'means UNKNOWN — never' "$README"
check "README shows a pre-#1084 example record with no resolved key" \
  grep -Fq 'Example pre-#1084 record' "$README"
check "README's record-shape line lists resolved and reported_no_op" \
  grep -Fq 'items_processed, merged, resolved, parked, reported_no_op' "$README"
check "README dispositions pre-existing non-reconciling rows (never backfilled, accepted as legacy)" \
  grep -Fq 'accepted **as legacy' "$README"
check "emit-command-run.sh header still points at the canonical sink spec" \
  grep -Fq 'meta/data/raw/README.md' "$EMIT"

echo "── 7. callers pass the flag ──"
check "sweep.md passes --resolved"  grep -Fq -- '--resolved' "$SWEEP_MD"
check "fix.md passes --resolved"    grep -Fq -- '--resolved' "$FIX_MD"
check "triage.md passes --resolved (its culled + decision-routed bucket)" \
  grep -Fq -- '--resolved' "$TRIAGE_MD"
check "fix.md passes --reported-no-op (its already-done / claimed-elsewhere routes)" \
  grep -Fq -- '--reported-no-op' "$FIX_MD"
check "sweep.md no longer folds verdict-resolved items into --merged" \
  bash -c "! grep -Fq -- '--merged <count of \"merged\" + \"resolved (verdict)\" terminal dispositions>' '$SWEEP_MD'"
check "emit-command-run.sh usage line names fix as a --command caller" \
  grep -Fq -- 'sweep|triage|fix' "$EMIT"

echo "── 8. Step 1's pool excludes epic parents, not just epic legs (temperloop#1038) ──"
check "sweep.md Step 1 gates the pool on board_sub_issues (epic-parent exclusion)" \
  grep -Fq 'board_sub_issues' "$SWEEP_MD"
check "sweep.md's seam prose names epic parents, not just sub-issues" \
  grep -Fq 'neither a sub-issue of an epic nor an epic parent' "$SWEEP_MD"

echo "── 9. an answered issue is excluded, not re-flagged underspecified (temperloop#1193) ──"
check "sweep.md states the answered-exclusion rule verbatim" \
  grep -Fq 'answered, not underspecified' "$SWEEP_MD"
check "sweep.md's Step 1 fetch now pulls comments" \
  grep -Fq -- '--json title,body,labels,comments,url' "$SWEEP_MD"
check "sweep.md's detection-fanout input is stated as title/body/labels and comments" \
  grep -Fq 'title/body/labels **and comments**' "$SWEEP_MD"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_command_run_emit: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_command_run_emit: OK — all %d checks passed\n' "$pass"
