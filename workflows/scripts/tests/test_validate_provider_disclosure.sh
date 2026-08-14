#!/usr/bin/env bash
#
# test_validate_provider_disclosure.sh — dedicated degenerate-input fixture
# suite for workflows/scripts/validate-provider-disclosure.sh
# (temperloop#1476, epic #1409 "a check that could not run reports
# success").
#
# WHY A DEDICATED FILE. validate-provider-disclosure.sh is already
# incidentally exercised inside workflows/scripts/model-comparison/tests/
# test_allowlist.sh (that suite's own tests 18/24/25 happen to cover similar
# shapes) — but that file's job is allowlist.sh, the LIBRARY, not this
# validator, and its name breaks the `test_validate_*` naming convention
# every OTHER validate-*.sh / test_validate_*.sh pair in this repo follows
# (test_validate_feature_docs.sh, test_validate_template_refs.sh, ...). This
# item (#1476) is the one that builds check-surface-registry.tsv's
# SURFACE -> TEST_FILE mapping — and gives this validator its own dedicated
# home so the mapping is unambiguous, matching the sibling convention.
#
# Three cases, one per degenerate-input shape epic #1409 names (absent,
# unreadable, empty), each against the REAL artifact whose degenerate state
# is a genuine documented FAILURE for this validator — not every artifact
# this validator reads has a meaningful failure for every shape (an absent OR
# empty disclosure log is documented LEGAL — "a checkout that never ran a
# comparison"), so this suite targets the artifact where each shape really is
# a failure:
#   A  absent      the committed provider allowlist itself is missing
#                  -> COMMITTED-MISSING, the check that gives this validator
#                  its own reason to exist
#   B  unreadable  the disclosure log exists but cannot be read
#                  -> CANNOT EVALUATE — precisely epic #1409's motivating
#                  instance 1 ("printed OK / exit 0 when it could not read
#                  its log"), reproduced directly
#   C  empty       the disclosure log is emptied IN PLACE after real entries
#                  were disclosed, so its sibling watermark anchor still
#                  records them -> TRUNCATED, never a silent "nothing here"
#                  pass (mirrors test_allowlist.sh's test 25c, using the real
#                  pa_disclose library call rather than a hand-fabricated
#                  watermark, so the seq/hash format is guaranteed valid)
#
# ANCHOR DISCIPLINE (temperloop#1476 review round 2, HIGH 2). Each case's
# check-surface-registry.tsv anchor is the LABEL ARGUMENT OF THE ASSERTION
# ITSELF (a `check` call), never a separate `ok(...)` line that runs after
# the real assertions and can survive them being deleted — that decoupling
# is exactly the false negative an earlier cut of this file shipped: a
# reviewer deleted every outcome assertion and the three `ok()` lines still
# printed PASS. Mirrors the two sibling registered files' own shape:
#   - test_model_usage_emit.sh:745 — the label argument of a check_eq call
#     IS the assertion's own description.
#   - test_replay_isolation.sh:281 — `[ "$rc" -ne 0 ] || fail "<anchor>"` —
#     the anchor is ON the assertion line.
# Here each case is ONE `check` call whose description is the anchor and
# whose command verifies BOTH the exit code AND the expected diagnostic
# substring (and, for case B, the ABSENCE of a false "OK" line) — so deleting
# THAT ONE LINE removes the entire verification, anchor included.
#
# Hermetic: every fixture lives under a throwaway mktemp dir OUTSIDE this
# repo, so PROVIDER_ALLOWLIST_TEST_SEAM's "a path outside the repo skips the
# git-tracked check" behavior applies cleanly (see validate-provider-
# disclosure.sh's own header) and nothing here touches the real
# .temperloop/model-comparison/ state. No network.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays), matching
# every sibling workflows/scripts/tests/test_validate_*.sh suite.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
VALIDATOR="$REPO_ROOT/workflows/scripts/validate-provider-disclosure.sh"
ALLOWLIST_SH="$REPO_ROOT/workflows/scripts/model-comparison/allowlist.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-validate-provider-disclosure-XXXXXX")" || exit 1
# chmod back up before rm: a fixture that deliberately chmod 000s a file must
# never leave an unreadable path behind, even when the suite exits on a
# failing assertion mid-fixture (same convention as test_allowlist.sh).
cleanup() {
  chmod -R u+rwX "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0
total=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s: %s\n' "$1" "$2"; }
check() { # <desc-and-anchor> <cmd...>
  local d="$1"
  shift
  total=$((total + 1))
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d" "command failed: $*"; fi
}

# run_validator <committed> <local> <log> — invokes the real validator with
# the fixture-test seam armed, exactly like test_allowlist.sh's run_validator_at.
run_validator() {
  env \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 \
    PROVIDER_ALLOWLIST_COMMITTED_FILE="$1" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$2" \
    PROVIDER_DISCLOSURE_LOG_FILE="$3" \
    bash "$VALIDATOR"
}

# wm_path <logfile> — the sibling watermark anchor allowlist.sh maintains.
wm_path() { printf '%s\n' "${1%.jsonl}.watermark"; }

# _verdict <want_rc> <must_contain> <must_not_contain_or_empty> <rc> <out>
# — the compound predicate every case's single anchored `check` call drives.
# Generic infrastructure ONLY: it must never itself carry any of the three
# anchor strings, or the uniqueness check (MEDIUM 5, count==1 in the target
# file) would trip on this helper's own body.
_verdict() {
  local want_rc="$1" must="$2" must_not="$3" rc="$4" out="$5"
  [ "$rc" -eq "$want_rc" ] || return 1
  case "$out" in *"$must"*) ;; *) return 1 ;; esac
  if [ -n "$must_not" ]; then
    case "$out" in *"$must_not"*) return 1 ;; esac
  fi
  return 0
}

# ---------------------------------------------------------------------------
# A. ABSENT: no committed provider allowlist at all -> COMMITTED-MISSING,
#    non-zero, never a silent pass.
# ---------------------------------------------------------------------------
A_DIR="$WORK/a"
mkdir -p "$A_DIR"
A_COMMITTED="$A_DIR/committed.txt"
A_LOCAL="$A_DIR/local.txt"
A_LOG="$A_DIR/log.jsonl"
[[ ! -f "$A_COMMITTED" ]] || fail "A: fixture setup: committed file should not exist"
arc=0
aout="$(run_validator "$A_COMMITTED" "$A_LOCAL" "$A_LOG" 2>&1)" || arc=$?
check "an absent committed allowlist: exit 1 (COMMITTED-MISSING), not 0" \
  _verdict 1 "COMMITTED-MISSING" "" "$arc" "$aout"

# ---------------------------------------------------------------------------
# B. UNREADABLE: a well-formed committed allowlist, but the disclosure log
#    cannot be read -> CANNOT EVALUATE, non-zero, never a silent pass. This
#    is epic #1409's motivating instance 1, reproduced directly.
# ---------------------------------------------------------------------------
B_DIR="$WORK/b"
mkdir -p "$B_DIR"
B_COMMITTED="$B_DIR/committed.txt"
B_LOCAL="$B_DIR/local.txt"
B_LOG="$B_DIR/log.jsonl"
printf 'anthropic\n' >"$B_COMMITTED"
env PROVIDER_ALLOWLIST_TEST_SEAM=1 \
  PROVIDER_ALLOWLIST_COMMITTED_FILE="$B_COMMITTED" \
  PROVIDER_ALLOWLIST_LOCAL_FILE="$B_LOCAL" \
  PROVIDER_DISCLOSURE_LOG_FILE="$B_LOG" \
  bash -c "source '$ALLOWLIST_SH'; pa_disclose anthropic 'issue#1' >/dev/null" \
  || fail "B: fixture setup: pa_disclose failed"
[[ -s "$B_LOG" ]] || fail "B: fixture setup: log should be non-empty after a real disclose"
chmod 000 "$B_LOG"
brc=0
bout="$(run_validator "$B_COMMITTED" "$B_LOCAL" "$B_LOG" 2>&1)" || brc=$?
chmod 644 "$B_LOG" # inline restore — the EXIT trap above is the belt-and-suspenders backstop
check "an unreadable disclosure log: exit 1 (CANNOT EVALUATE), not 0" \
  _verdict 1 "CANNOT EVALUATE" "validate-provider-disclosure: OK" "$brc" "$bout"

# ---------------------------------------------------------------------------
# C. EMPTY: real entries were disclosed (so the sibling watermark anchor
#    records them), then the log is emptied IN PLACE -> TRUNCATED, non-zero,
#    never a silent "nothing here" pass. Mirrors test_allowlist.sh's test
#    25c, using the real pa_disclose call so the watermark's seq/hash format
#    is guaranteed valid rather than hand-forged.
# ---------------------------------------------------------------------------
C_DIR="$WORK/c"
mkdir -p "$C_DIR"
C_COMMITTED="$C_DIR/committed.txt"
C_LOCAL="$C_DIR/local.txt"
C_LOG="$C_DIR/log.jsonl"
printf 'anthropic\n' >"$C_COMMITTED"
env PROVIDER_ALLOWLIST_TEST_SEAM=1 \
  PROVIDER_ALLOWLIST_COMMITTED_FILE="$C_COMMITTED" \
  PROVIDER_ALLOWLIST_LOCAL_FILE="$C_LOCAL" \
  PROVIDER_DISCLOSURE_LOG_FILE="$C_LOG" \
  bash -c "source '$ALLOWLIST_SH'; pa_disclose anthropic 'issue#1' >/dev/null" \
  || fail "C: fixture setup: pa_disclose failed"
[[ -f "$(wm_path "$C_LOG")" ]] || fail "C: fixture setup: watermark should exist after a real disclose"
: >"$C_LOG" # empty the log IN PLACE — the watermark still records 1 entry
[[ ! -s "$C_LOG" ]] || fail "C: fixture setup: log should be empty"
crc=0
cout="$(run_validator "$C_COMMITTED" "$C_LOCAL" "$C_LOG" 2>&1)" || crc=$?
check "an empty disclosure log with a non-empty watermark: exit 1 (TRUNCATED), not 0" \
  _verdict 1 "TRUNCATED" "" "$crc" "$cout"

echo
if [ "$pass" -ne "$total" ]; then
  printf 'test_validate_provider_disclosure: FAILED %d of %d\n' "$((total - pass))" "$total"
  exit 1
fi
printf 'test_validate_provider_disclosure: OK — all %d checks passed\n' "$pass"
