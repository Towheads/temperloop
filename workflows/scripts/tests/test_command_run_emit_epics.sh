#!/usr/bin/env bash
#
# test_command_run_emit_epics.sh — tests for the epics_reviewed /
# epics_closed / epics_left_open schema extension on
# workflows/scripts/emit-command-run.sh (temperloop item
# "epic-closing-gate", epic #1847).
#
# THE CENTRAL TESTS mirror test_command_run_emit.sh's shape for the sibling
# --resolved/--reported-no-op extension:
#
#   A. the three fields are purely additive — a caller that never passes
#      --epics-reviewed gets a record identical to before this change (no
#      epics_* keys at all), and the existing items_processed arithmetic is
#      completely untouched by their presence or absence.
#   B. --epics-reviewed activates the extension: all three fields appear
#      (even a legitimate all-zero record), and a SEPARATE accounting check
#      enforces epics_closed + epics_left_open == epics_reviewed — failing
#      loudly (non-zero exit, arithmetic named) on a mismatch while STILL
#      appending the record, exactly like the items_processed check.
#   C. the two accounting checks are independent: a record can fail one,
#      the other, both, or neither, and each failure names the arithmetic
#      that actually broke.
#
# Synthetic lake under a throwaway tmpdir (CMD_RUN_RAW_DIR). Zero network;
# never writes outside the tmpdir.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../../.." && pwd)"
EMIT="$REPO/workflows/scripts/emit-command-run.sh"
SWEEP_MD="$REPO/claude/commands/sweep.md"
TIDY_MD="$REPO/claude/commands/tidy.md"

[ -f "$EMIT" ] || { echo "FATAL: emit-command-run.sh not found at $EMIT" >&2; exit 1; }
[ -f "$SWEEP_MD" ] || { echo "FATAL: sweep.md not found at $SWEEP_MD" >&2; exit 1; }
[ -f "$TIDY_MD" ] || { echo "FATAL: tidy.md not found at $TIDY_MD" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/command-run-emit-epics-test.XXXXXX")"
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

echo "── 1. purely additive: a caller that never passes --epics-reviewed gets no epics_* keys ──"
emit l1 --command sweep --board 3 --items-processed 3 --merged 2 --parked 1
check_eq "exit 0 (unaffected by the extension existing)" "0" "$EMIT_RC"
check_eq "no epics_reviewed key" "false" "$(printf '%s' "$EMIT_OUT" | jq -r 'has("epics_reviewed")')"
check_eq "no epics_closed key" "false" "$(printf '%s' "$EMIT_OUT" | jq -r 'has("epics_closed")')"
check_eq "no epics_left_open key" "false" "$(printf '%s' "$EMIT_OUT" | jq -r 'has("epics_left_open")')"
check "the existing items_processed arithmetic is untouched (2+0+1+0==3)" \
  bash -c "printf '%s' '$EMIT_OUT' | jq -e '.merged + .resolved + .parked + .reported_no_op == .items_processed' >/dev/null"

echo "── 2. --epics-reviewed activates the extension, in the SAME call (never a second emit) ──"
emit l2 --command sweep --board 3 --items-processed 3 --merged 2 --parked 1 \
  --epics-reviewed 2 --epics-closed 1 --epics-left-open 1
check_eq "exit 0 on a doubly-reconciling record" "0" "$EMIT_RC"
check_eq "epics_reviewed lands" "2" "$(printf '%s' "$EMIT_OUT" | jq -r '.epics_reviewed')"
check_eq "epics_closed lands" "1" "$(printf '%s' "$EMIT_OUT" | jq -r '.epics_closed')"
check_eq "epics_left_open lands" "1" "$(printf '%s' "$EMIT_OUT" | jq -r '.epics_left_open')"
check_eq "exactly one lake line (one emit call, never two)" "1" "$(lake_lines l2)"
check_eq "items_processed disposition fields are unaffected by the epics_* fields being present" \
  "2" "$(printf '%s' "$EMIT_OUT" | jq -r '.merged')"

echo "── 3. a legitimate all-zero epics record reconciles (the gate ran, admitted nothing) ──"
emit l3 --command sweep --board 3 --items-processed 0 --epics-reviewed 0 --epics-closed 0 --epics-left-open 0
check_eq "exit 0 on 0/0/0" "0" "$EMIT_RC"
check_eq "epics_reviewed=0 still present (a real zero, not omitted)" \
  "true" "$(printf '%s' "$EMIT_OUT" | jq -r 'has("epics_reviewed")')"

echo "── 4. THE LOUD FAILURE: epics_closed + epics_left_open != epics_reviewed ──"
emit l4 --command sweep --board 3 --items-processed 3 --merged 2 --parked 1 \
  --epics-reviewed 2 --epics-closed 1 --epics-left-open 2
check_eq "exit code is non-zero (2)" "2" "$EMIT_RC"
check "stderr names the epics arithmetic that failed" \
  bash -c "grep -Fq 'epics_closed(1) + epics_left_open(2) = 3, but --epics-reviewed is 2' <<<\"\$1\"" _ "$EMIT_ERR"
check "stderr says the record was still appended (never swallowed)" \
  bash -c "grep -Fq 'WAS appended' <<<\"\$1\"" _ "$EMIT_ERR"
check_eq "the record IS on disk despite the failure" "1" "$(lake_lines l4)"
check_eq "...caller's counts verbatim, not silently corrected" \
  "2" "$(cat "$TMP/l4"/command-runs-*.jsonl | jq -r '.epics_left_open')"
# Over-counting is caught too.
emit l4b --command sweep --items-processed 0 --epics-reviewed 1 --epics-closed 1 --epics-left-open 1
check_eq "an over-count (1+1 > 1) fails the same way" "2" "$EMIT_RC"

echo "── 5. the two accounting checks are INDEPENDENT ──"
# items_processed breaks, epics_reviewed reconciles.
emit l5a --command sweep --items-processed 5 --merged 1 --epics-reviewed 1 --epics-closed 1 --epics-left-open 0
check_eq "items-side breaks, epics-side clean -> still exit 2 overall" "2" "$EMIT_RC"
check "...stderr names the items_processed break" \
  bash -c "grep -Fq 'disposition counts do not reconcile' <<<\"\$1\"" _ "$EMIT_ERR"
check "...stderr does NOT claim an epics mismatch (the epics side actually reconciled)" \
  bash -c "! grep -Fq 'epics_closed + epics_left_open' <<<\"\$1\"" _ "$EMIT_ERR"
# items_processed reconciles, epics_reviewed breaks.
emit l5b --command sweep --items-processed 1 --merged 1 --epics-reviewed 2 --epics-closed 0 --epics-left-open 0
check_eq "items-side clean, epics-side breaks -> exit 2" "2" "$EMIT_RC"
check "...stderr names the epics break" \
  bash -c "grep -Fq 'epics_closed + epics_left_open' <<<\"\$1\"" _ "$EMIT_ERR"
check "...stderr does NOT claim an items_processed break (that side actually reconciled)" \
  bash -c "! grep -Fq 'disposition counts do not reconcile' <<<\"\$1\"" _ "$EMIT_ERR"
# Both break at once — both messages present.
emit l5c --command sweep --items-processed 5 --merged 1 --epics-reviewed 2 --epics-closed 0 --epics-left-open 0
check_eq "both sides broken -> exit 2" "2" "$EMIT_RC"
check "...both FAIL lines present" \
  bash -c "grep -Fq 'disposition counts do not reconcile' <<<\"\$1\" && grep -Fq 'epics_closed + epics_left_open' <<<\"\$1\"" _ "$EMIT_ERR"

echo "── 6. infrastructure-class failure on an epics_* flag still warns + exits 0 (the || true-safe contract) ──"
emit l6 --command sweep --items-processed 1 --merged 1 --epics-reviewed notanumber --epics-closed 0 --epics-left-open 0
check_eq "a malformed --epics-reviewed warns and exits 0, never blocks the caller" "0" "$EMIT_RC"
check "...stderr names the offending flag" \
  bash -c "grep -Fq -- '--epics-reviewed must be a non-negative integer' <<<\"\$1\"" _ "$EMIT_ERR"
check_eq "...and no record was emitted at all (a malformed count is an infra error, not an accounting one)" \
  "0" "$(lake_lines l6)"

echo "── 7. round-6 escalation HIGH: a failed close write must not render as 'Offered, declined' ──"
check "sweep.md names the close-write-failed outcome, distinct from declined" \
  grep -Fq 'close-write-failed' "$SWEEP_MD"
check "sweep.md's report carries the seventh row shape for a failed close write" \
  grep -Fq 'close approved but write failed this run' "$SWEEP_MD"
check "sweep.md states the misattribution rationale (recurring write breakage != operator declining)" \
  grep -Fq 'never misattributed as the operator repeatedly declining' "$SWEEP_MD"
check "sweep.md keeps the tally arithmetic-only (write-failed still tallies under epics_left_open)" \
  grep -Fq 'the tally is arithmetic-only and does not distinguish the two' "$SWEEP_MD"

echo "── 8. round-6 escalation LOW: epic_open's data source is named explicitly ──"
check "sweep.md names board_item_list as the open-only slice epic_open relies on" \
  grep -Fq "board's ACTIVE (open) slice" "$SWEEP_MD"
check "sweep.md states epic_open is true for every candidate arm (b)'s query returns" \
  grep -Fq '`epic_open` is true for every candidate this query returns' "$SWEEP_MD"

echo "── 9. round-7 escalation HIGH: no unbacked retry claim; the closing comment post is idempotent ──"
check "sweep.md no longer claims the write is 'retried, not re-asked' (no such mechanism exists)" \
  bash -c '! grep -Fq "write retried, not re-asked" "$1"' _ "$SWEEP_MD"
check "sweep.md instead states a write-failed epic is simply RE-OFFERED next run" \
  grep -Fq 'RE-OFFERED next run' "$SWEEP_MD"
check "sweep.md probes for an already-posted closing comment before posting (idempotency)" \
  grep -Fq 'probe for an already-posted closing comment before posting' "$SWEEP_MD"
check "sweep.md reuses item 2's already-read comments rather than an extra call" \
  grep -Fq 'reuse the `comments` array item 2 above already read' "$SWEEP_MD"

echo "── 10. round-7 escalation LOW: the comment-post failure disposition is named ──"
check "sweep.md names the comment-post failure warn-and-skip-the-write disposition" \
  grep -Fq 'If that comment post itself fails' "$SWEEP_MD"
check "sweep.md skips the write (never closes unexplained) on a comment-post failure" \
  grep -Fq 'skip the write this run' "$SWEEP_MD"
check "sweep.md reports a comment-post failure via the write-failed row (re-offered next run)" \
  grep -Fq 'record the outcome as `close-write-failed` so it is re-offered next run via the write-failed report row' "$SWEEP_MD"

echo "── 11. round-7 escalation MEDIUM: tidy.md's pending-decisions backstop dedup matches the capture's epic-keyed match ──"
check "tidy.md special-cases the epic-closing-gate site's dedup key" \
  grep -Fq 'except when the decision names an epic number' "$TIDY_MD"
check "tidy.md matches an epic-keyed decision on the epic number anywhere in the surface's WHOLE history" \
  grep -Fq "anywhere in this surface's WHOLE history" "$TIDY_MD"
check "tidy.md states a site+date-scoped match would violate the one-per-epic-ever invariant" \
  grep -Fq 'violating the one-per-epic-ever invariant' "$TIDY_MD"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_command_run_emit_epics: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_command_run_emit_epics: OK — all %d checks passed\n' "$pass"
