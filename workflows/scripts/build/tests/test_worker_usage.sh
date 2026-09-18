#!/usr/bin/env bash
#
# test_worker_usage.sh — workflows/scripts/build/worker-usage.sh, the
# per-item worker-cost-capture emitted-shell seam (temperloop#2065
# "worker-cost-capture", epic #2062 "new-work dual-build harness").
#
# WHAT THIS GATE IS FOR. worker-usage.sh is the ONLY place build-level.mjs's
# per-item worker cost (wall-clock + the model-usage envelope attribution
# write) touches real shell — a defect here is invisible to
# claude/workflows/build-level.mjs's own offline harness (test_workflow.sh),
# which never runs this script for real; it mocks the agent() call that
# would invoke it. So the load-bearing assertions here are:
#   1. `clock` and `emit` both print a well-formed, closed-outcome JSON line
#      the SPINE_OUTCOME_SCHEMA in build-level.mjs actually declares
#      (WORKER_CLOCK / WORKER_USAGE — a typo in either string is invisible
#      to bash and would silently degrade every reading to null).
#   2. `emit` genuinely calls model-usage-envelope.sh's shared
#      model_usage_emit_from_envelope — proven by an END-TO-END check against
#      a real (redirected) raw lake, not merely "the script exited 0" — with
#      the seat/model/outcome-ref it was given, never a hardcoded string.
#   3. THE HONEST DEGRADE: no envelope exists for a Workflow agent() call, so
#      `emit`'s own stdout reports input_tokens/output_tokens as null and
#      usage_source "unavailable" — never a fabricated number.
#   4. FAIL-OPEN: a missing/unreadable envelope library or a missing/
#      non-executable emit-model-usage.sh degrades to the same well-formed
#      WORKER_USAGE line, never a non-zero exit or a crash — a cost-ledger
#      entry must never be the thing that stalls a build.
#   5. Bad/missing arguments are refused (ERROR outcome, non-zero exit),
#      never silently treated as a valid reading.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
USAGE_SH="$REPO_ROOT/workflows/scripts/build/worker-usage.sh"

FAILED=0
pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1" >&2; FAILED=1; }

[ -x "$USAGE_SH" ] || { fail "worker-usage.sh missing or not executable at $USAGE_SH"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/worker-usage-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- 1. `clock` — a well-formed, plausible reading --------------------------
before="$(date +%s)"
clock_out="$("$USAGE_SH" clock)"
after="$(date +%s)"
case "$clock_out" in
  *'"outcome":"WORKER_CLOCK"'*) pass "clock prints the WORKER_CLOCK outcome build-level.mjs's schema declares" ;;
  *) fail "expected a WORKER_CLOCK line, got: $clock_out" ;;
esac
epoch="$(printf '%s' "$clock_out" | sed -E 's/.*"epoch_s":([0-9]+).*/\1/')"
case "$epoch" in
  '' | *[!0-9]*) fail "epoch_s is absent or non-numeric: $clock_out" ;;
  *)
    if [ "$epoch" -ge "$before" ] && [ "$epoch" -le "$after" ]; then
      pass "epoch_s (${epoch}) falls within the real wall-clock window this test measured [$before, $after]"
    else
      fail "epoch_s (${epoch}) is outside the measured window [$before, $after] — not a real clock read: $clock_out"
    fi
    ;;
esac

# --- 2. `emit` — well-formed, and THE HONEST DEGRADE (no envelope exists) ---
emit_out="$(MODEL_USAGE_RAW_DIR="$WORK/lake1" "$USAGE_SH" emit build-worker sonnet-5 issue:4242 owner/repo)"
case "$emit_out" in
  *'"outcome":"WORKER_USAGE"'*) pass "emit prints the WORKER_USAGE outcome build-level.mjs's schema declares" ;;
  *) fail "expected a WORKER_USAGE line, got: $emit_out" ;;
esac
case "$emit_out" in
  *'"usage_source":"unavailable"'*) pass "usage_source is honestly 'unavailable' — no captured envelope exists for a Workflow agent() call" ;;
  *) fail "expected usage_source 'unavailable' (the honest degrade), got: $emit_out" ;;
esac
case "$emit_out" in
  *'"input_tokens":null'*'"output_tokens":null'*) pass "input_tokens/output_tokens are honestly null, never a fabricated number" ;;
  *) fail "expected input_tokens/output_tokens both null, got: $emit_out" ;;
esac

# --- 3. `emit` genuinely wires model_usage_emit_from_envelope, end to end ---
# Proven against a REAL (redirected) raw lake — never a mocked function call —
# with the seat/model/outcome-ref THIS invocation was given, not a hardcoded
# string, so a call-site typo (the wrong seat name reaching
# model_usage_emit_from_envelope) would surface here.
lake_file="$(find "$WORK/lake1" -maxdepth 1 -name 'model-usage-*.jsonl' 2>/dev/null | head -1)"
if [ -z "$lake_file" ] || [ ! -f "$lake_file" ]; then
  fail "emit did not append a record to the redirected raw lake at $WORK/lake1 — model_usage_emit_from_envelope was not reached"
else
  record="$(tail -1 "$lake_file")"
  case "$record" in
    *'"seat":"build-worker"'*) pass "the durable attribution record carries the seat THIS call passed (build-worker), not a hardcoded one" ;;
    *) fail "expected seat build-worker in the durable record, got: $record" ;;
  esac
  case "$record" in
    *'"model":"sonnet-5"'*) pass "the durable record carries the model THIS call passed" ;;
    *) fail "expected model sonnet-5 in the durable record, got: $record" ;;
  esac
  case "$record" in
    *'"outcome_ref":"issue:4242"'*) pass "the durable record carries the outcome-ref THIS call passed" ;;
    *) fail "expected outcome_ref issue:4242 in the durable record, got: $record" ;;
  esac
  case "$record" in
    *'"usage_source":"unavailable"'*) pass "the durable record is ALSO attribution-only — matching this script's own stdout, never disagreeing with it" ;;
    *) fail "expected the durable record's usage_source to also be 'unavailable', got: $record" ;;
  esac
fi

# --- 4. DISCRIMINATION CONTROL: a DIFFERENT seat/outcome-ref on a SECOND call
# lands as its OWN, DIFFERENT record — proves #3 is not a fixture the script
# always prints regardless of its arguments.
emit_out2="$(MODEL_USAGE_RAW_DIR="$WORK/lake1" "$USAGE_SH" emit a-different-seat haiku pr:9 owner/repo)"
lake_file2="$(find "$WORK/lake1" -maxdepth 1 -name 'model-usage-*.jsonl' 2>/dev/null | head -1)"
# temperloop#2065 review round 1 [LOW]: guard emptiness the same way $lake_file
# is guarded above (line 87) — an unguarded `wc -l < ""` / `tail -1 ""` below
# would emit a raw shell redirection error if section 3 already failed (no
# lake file), reporting the WRONG problem instead of this section's own.
if [ -z "$lake_file2" ] || [ ! -f "$lake_file2" ]; then
  fail "no redirected raw lake file found at $WORK/lake1 after 2 emit calls — model_usage_emit_from_envelope was not reached"
else
  n_records="$(wc -l < "$lake_file2" | tr -d ' ')"
  if [ "$n_records" != "2" ]; then
    fail "expected exactly 2 durable records after 2 emit calls, got $n_records"
  else
    pass "a second emit call with DIFFERENT arguments appends a SECOND, distinct record (discrimination control)"
  fi
  last_record="$(tail -1 "$lake_file2")"
  case "$last_record" in
    *'"seat":"a-different-seat"'*'"outcome_ref":"pr:9"'*) pass "the second record carries ITS OWN seat/outcome-ref, not the first call's" ;;
    *) fail "the second record did not carry its own arguments — records may be getting confused/overwritten: $last_record" ;;
  esac
fi

# --- 5. FAIL-OPEN: a missing envelope library never breaks emit's own output
# temperloop#2065 review round 1 [MEDIUM]: the inner `bash -c` body used to
# open with its own `set -e`, so a non-zero exit from the worker-usage.sh
# call on line 136 would terminate that shell IMMEDIATELY — the `rc=$?` /
# `rm -rf "$tmp"` / `exit "$rc"` below it never ran, silently leaking `$tmp`
# into `$TMPDIR` on exactly the RED path this section exists to catch (the
# `rc=$?` on the outer line 141 still read the subshell's real exit status
# correctly either way — only the cleanup was dead). Fixed by putting the
# scratch tree under $WORK (mkdir, not mktemp) instead, so this suite's own
# top-of-file `trap 'rm -rf "$WORK"' EXIT` (line 44) owns cleanup regardless
# of how the inner shell exits — no separate rc/rm/exit dance needed inside it.
tmp5="$WORK/missing-lib"
mkdir -p "$tmp5/build"
cp "$USAGE_SH" "$tmp5/build/worker-usage.sh"
missing_lib_out="$(env MODEL_USAGE_RAW_DIR="$WORK/lake2" bash -c '
  set -euo pipefail
  "'"$tmp5"'/build/worker-usage.sh" emit build-worker sonnet-5 issue:1 owner/repo
')"
rc=$?
if [ "$rc" -eq 0 ]; then
  case "$missing_lib_out" in
    *'"outcome":"WORKER_USAGE"'*) pass "a missing model-usage-envelope.sh degrades to a clean WORKER_USAGE line (fail-open), never a crash" ;;
    *) fail "a missing envelope library produced an unexpected line: $missing_lib_out" ;;
  esac
else
  fail "a missing model-usage-envelope.sh made worker-usage.sh exit non-zero (rc=$rc) — a cost-ledger read must never fail the build: $missing_lib_out"
fi

# --- 6. bad/missing arguments are REFUSED, never a silent valid-looking read
if bad_out="$("$USAGE_SH" emit 2>&1)"; then
  fail "emit with no seat/outcome-ref was accepted: $bad_out"
else
  case "$bad_out" in
    *'"outcome":"ERROR"'*) pass "emit with missing required arguments is refused with an ERROR outcome, never silently accepted" ;;
    *) fail "expected an ERROR outcome on missing arguments, got: $bad_out" ;;
  esac
fi
if bad_cmd_out="$("$USAGE_SH" bogus-subcommand 2>&1)"; then
  fail "an unknown subcommand was accepted: $bad_cmd_out"
else
  pass "an unknown subcommand is refused (non-zero exit)"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "PASS: worker-usage.sh — clock/emit are well-formed, emit genuinely wires model_usage_emit_from_envelope end-to-end, degrades honestly with no envelope, fails open, and refuses bad input (temperloop#2065)"
  exit 0
fi
echo "FAIL: worker-usage.sh gate" >&2
exit 1
