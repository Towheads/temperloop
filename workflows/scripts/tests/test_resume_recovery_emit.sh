#!/usr/bin/env bash
#
# test_resume_recovery_emit.sh — tests for workflows/scripts/emit-resume-recovery.sh
# and workflows/scripts/validate-resume-recovery-emit.sh (temperloop#1908, a
# /build Step 0.5 baseline instrument for the graph-of-record work).
#
# Mirrors test_command_run_emit.sh's harness shape (synthetic lake under a
# throwaway tmpdir, a `emit()`/`check`/`check_eq` helper trio, and a
# fixture-repo section for the presence-lint's red/green behaviour) applied
# to this stream's own record shape and its own loud invariant: a
# --recovered <kind>:<ref> outside the closed enum, or a --recovered-count
# that disagrees with the number of --recovered flags given, must still
# append the record and then exit non-zero (never silently swallowed, never
# a blocked caller — the `|| true`-safe contract).
#
# Synthetic lake under a throwaway tmpdir (RESUME_RECOVERY_RAW_DIR). Zero
# network; never writes outside the tmpdir.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../../.." && pwd)"
EMIT="$REPO/workflows/scripts/emit-resume-recovery.sh"
LINT="$REPO/workflows/scripts/validate-resume-recovery-emit.sh"
README="$REPO/meta/data/raw/README.md"
BUILD_MD="$REPO/claude/commands/build.md"

[ -f "$EMIT" ] || { echo "FATAL: emit-resume-recovery.sh not found at $EMIT" >&2; exit 1; }
[ -f "$LINT" ] || { echo "FATAL: validate-resume-recovery-emit.sh not found at $LINT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/resume-recovery-emit-test.XXXXXX")"
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
  EMIT_OUT="$(RESUME_RECOVERY_RAW_DIR="$dir" CLAUDE_CODE_SESSION_ID=sess-1 \
    bash "$EMIT" "$@" 2>"$TMP/err.txt")"
  EMIT_RC=$?
  EMIT_ERR="$(cat "$TMP/err.txt")"
}
lake_lines() { cat "$TMP/$1"/resume-recovery-*.jsonl 2>/dev/null | wc -l | tr -d ' '; }

echo "── 1. a valid record with recovered items appends and reconciles ──"
emit l1 --plan "2026-05-16 stagefind - sweep follow-up" --recovered-count 2 \
  --recovered "worktree:temperloop.wt/foo-slug" --recovered "pr:1234"
check_eq "exit 0 on a reconciling record" "0" "$EMIT_RC"
check_eq "command is build" "build" "$(printf '%s' "$EMIT_OUT" | jq -r '.command')"
check_eq "plan carries the note stem verbatim" \
  "2026-05-16 stagefind - sweep follow-up" "$(printf '%s' "$EMIT_OUT" | jq -r '.plan')"
check_eq "recovered_count carries the count" "2" "$(printf '%s' "$EMIT_OUT" | jq -r '.recovered_count')"
check_eq "recovered has two elements" "2" "$(printf '%s' "$EMIT_OUT" | jq -r '.recovered | length')"
check_eq "first recovered element's kind" "worktree" "$(printf '%s' "$EMIT_OUT" | jq -r '.recovered[0].kind')"
check_eq "first recovered element's ref" "temperloop.wt/foo-slug" "$(printf '%s' "$EMIT_OUT" | jq -r '.recovered[0].ref')"
check_eq "second recovered element's kind" "pr" "$(printf '%s' "$EMIT_OUT" | jq -r '.recovered[1].kind')"
check_eq "second recovered element's ref" "1234" "$(printf '%s' "$EMIT_OUT" | jq -r '.recovered[1].ref')"
check_eq "one line appended to the lake" "1" "$(lake_lines l1)"
check_eq "session_id carries the raw, untruncated env var" "sess-1" "$(printf '%s' "$EMIT_OUT" | jq -r '.session_id')"

echo "── 2. a zero-recovered resume still reconciles (0 == 0) ──"
emit l2 --plan myplan --recovered-count 0
check_eq "exit 0" "0" "$EMIT_RC"
check_eq "recovered is an empty array, not null" "[]" "$(printf '%s' "$EMIT_OUT" | jq -c '.recovered')"
check_eq "session_id is null when unset" "null" \
  "$(env -u CLAUDE_CODE_SESSION_ID RESUME_RECOVERY_RAW_DIR="$TMP/l2b" bash "$EMIT" --plan myplan --recovered-count 0 --print-only | jq -r '.session_id')"

echo "── 3. --print-only computes and prints WITHOUT appending ──"
mkdir -p "$TMP/l3"
OUT="$(RESUME_RECOVERY_RAW_DIR="$TMP/l3" bash "$EMIT" --plan myplan --recovered-count 1 --recovered "claim:42" --print-only)"
RC=$?
check_eq "print-only exits 0" "0" "$RC"
check_eq "print-only still renders the record" "claim" "$(printf '%s' "$OUT" | jq -r '.recovered[0].kind')"
check_eq "print-only writes NOTHING to the lake" "0" "$(lake_lines l3)"

echo "── 4. THE LOUD FAILURE (a): an invalid kind exits non-zero, record still appended ──"
emit l4 --plan myplan --recovered-count 1 --recovered "bogus:xyz"
check_eq "exit code is non-zero (2), not a silent 0" "2" "$EMIT_RC"
check "stderr names the closed enum and the offending kind" \
  bash -c "grep -Fq 'outside the closed enum' <<<\"\$1\" && grep -Fq 'bogus' <<<\"\$1\"" _ "$EMIT_ERR"
check "stderr says the record was still appended (never swallowed)" \
  bash -c "grep -Fq 'WAS appended' <<<\"\$1\"" _ "$EMIT_ERR"
check_eq "the record IS on disk despite the failure — an inconsistent record beats no record" \
  "1" "$(lake_lines l4)"
check_eq "...and it carries the caller's bad kind verbatim, not silently dropped" \
  "bogus" "$(cat "$TMP/l4"/resume-recovery-*.jsonl | jq -r '.recovered[0].kind')"

echo "── 5. THE LOUD FAILURE (b): recovered_count disagreeing with the array length ──"
emit l5 --plan myplan --recovered-count 3 --recovered "worktree:foo"
check_eq "exit code is non-zero (2)" "2" "$EMIT_RC"
check "stderr names both counts" \
  bash -c "grep -Fq 'recovered-count (3)' <<<\"\$1\" && grep -Fq 'flags given (1)' <<<\"\$1\"" _ "$EMIT_ERR"
check_eq "the record IS on disk despite the mismatch" "1" "$(lake_lines l5)"
check_eq "...with the caller's count verbatim (3), not silently corrected to 1" \
  "3" "$(cat "$TMP/l5"/resume-recovery-*.jsonl | jq -r '.recovered_count')"
# Over-counting the other direction (more flags than the declared count).
emit l5b --plan myplan --recovered-count 1 --recovered "worktree:foo" --recovered "pr:99"
check_eq "an under-declared count (2 flags, count=1) fails the same way" "2" "$EMIT_RC"

echo "── 6. infrastructure-class failures stay warn-and-exit-0 (|| true-safe) ──"
emit l6 --plan myplan
check_eq "a missing --recovered-count warns and exits 0" "0" "$EMIT_RC"
check_eq "...and writes no record" "0" "$(lake_lines l6)"
emit l6b --recovered-count 0
check_eq "a missing --plan warns and exits 0" "0" "$EMIT_RC"
check_eq "...and writes no record" "0" "$(lake_lines l6b)"
emit l6c --plan myplan --recovered-count abc
check_eq "a non-numeric --recovered-count warns and exits 0" "0" "$EMIT_RC"
check "...naming the offending flag" \
  bash -c "grep -Fq -- '--recovered-count must be a non-negative integer' <<<\"\$1\"" _ "$EMIT_ERR"
check_eq "...and writes no record" "0" "$(lake_lines l6c)"
# Zero-padded counts must not be read as octal by $(( )) nor break jq.
emit l6d --plan myplan --recovered-count 02 --recovered "pr:1" --recovered "pr:2"
check_eq "a zero-padded count is parsed base-10, not octal" "0" "$EMIT_RC"
check_eq "...and normalises in the record" "2" "$(printf '%s' "$EMIT_OUT" | jq -r '.recovered_count')"

echo "── 7. an item with no colon becomes {kind: <item>, ref: \"\"} rather than dropped ──"
emit l7 --plan myplan --recovered-count 1 --recovered "board-drift"
check_eq "'board-drift' alone (no ref) is still a VALID kind, so this reconciles at exit 0" "0" "$EMIT_RC"
check_eq "kind is preserved" "board-drift" "$(printf '%s' "$EMIT_OUT" | jq -r '.recovered[0].kind')"
check_eq "ref defaults to empty string, not null or dropped" "" "$(printf '%s' "$EMIT_OUT" | jq -r '.recovered[0].ref')"

echo "── 8. the canonical sink spec documents this stream ──"
check "README documents the resume-recovery stream" grep -Fq 'resume-recovery' "$README"
check "README's record-shape line lists ts/session_id/command/plan/recovered/recovered_count" \
  grep -Fq 'ts, session_id, command, plan, recovered, recovered_count' "$README"
check "README documents the closed kind enum" \
  grep -Fq 'worktree' "$README"
check "README shows an example record" \
  grep -Fq '"command":"build"' "$README"

echo "── 9. build.md's Step 0.5 item 5 invokes the emitter ──"
check "build.md invokes emit-resume-recovery.sh" grep -Fq 'emit-resume-recovery.sh' "$BUILD_MD"
# shellcheck disable=SC2016  # literal Markdown backticks, not command substitution
check "build.md names all five kind enum values" \
  grep -Fq 'worktree`|`pr`|`claim`|`sentinel-journal`|`board-drift' "$BUILD_MD"
check "the call is || true-isolated (telemetry never blocks a resume)" \
  grep -Fq 'emit-resume-recovery.sh --plan' "$BUILD_MD"

echo "── 10. the presence-lint passes on the real tree, fails on a tampered fixture ──"
check "validate-resume-recovery-emit.sh passes on the real tree" bash "$LINT"
FIXR="$TMP/fixture"
mkdir -p "$FIXR/workflows/scripts" "$FIXR/claude/commands"
cp "$EMIT" "$FIXR/workflows/scripts/emit-resume-recovery.sh"
cp "$LINT" "$FIXR/workflows/scripts/validate-resume-recovery-emit.sh"
chmod +x "$FIXR/workflows/scripts/"*.sh
cp "$BUILD_MD" "$FIXR/claude/commands/build.md"
check "the fixture copy is green before tampering" bash "$FIXR/workflows/scripts/validate-resume-recovery-emit.sh"
grep -v 'emit-resume-recovery.sh' "$BUILD_MD" > "$FIXR/claude/commands/build.md.tmp" \
  && mv "$FIXR/claude/commands/build.md.tmp" "$FIXR/claude/commands/build.md"
if bash "$FIXR/workflows/scripts/validate-resume-recovery-emit.sh" >"$TMP/lint.out" 2>&1; then
  bad "lint fails when build.md drops the emit-resume-recovery.sh call" "lint passed on a tampered doc"
else
  ok "lint fails when build.md drops the emit-resume-recovery.sh call"
fi
check "...and names the removed wiring" grep -Fq 'no longer invokes emit-resume-recovery.sh' "$TMP/lint.out"
# Restore build.md, then remove the emit script itself instead.
cp "$BUILD_MD" "$FIXR/claude/commands/build.md"
rm -f "$FIXR/workflows/scripts/emit-resume-recovery.sh"
if bash "$FIXR/workflows/scripts/validate-resume-recovery-emit.sh" >"$TMP/lint2.out" 2>&1; then
  bad "lint fails when the emit script is missing" "lint passed"
else
  ok "lint fails when the emit script is missing"
fi
check "...and names the missing script" grep -Fq 'is missing' "$TMP/lint2.out"
# Restore, then drop the executable bit instead.
cp "$EMIT" "$FIXR/workflows/scripts/emit-resume-recovery.sh"
chmod -x "$FIXR/workflows/scripts/emit-resume-recovery.sh"
if bash "$FIXR/workflows/scripts/validate-resume-recovery-emit.sh" >"$TMP/lint3.out" 2>&1; then
  bad "lint fails when the emit script lost its executable bit" "lint passed"
else
  ok "lint fails when the emit script lost its executable bit"
fi
check "...and names the non-executable script" grep -Fq 'not executable' "$TMP/lint3.out"

echo
echo "resume-recovery-emit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
