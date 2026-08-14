#!/usr/bin/env bash
#
# test_validate_provider_disclosure.sh — dedicated degenerate-input fixture
# suite for workflows/scripts/validate-provider-disclosure.sh
# (temperloop#1476, epic #1409 "a check that could not run reports success").
#
# WHY A DEDICATED FILE. validate-provider-disclosure.sh is already
# incidentally exercised inside workflows/scripts/model-comparison/tests/
# test_allowlist.sh (that suite's own tests 18/24/25 happen to cover similar
# shapes) — but that file's job is allowlist.sh, the LIBRARY, not this
# validator, and its name breaks the `test_validate_*` naming convention
# every OTHER validate-*.sh / test_validate_*.sh pair in this repo follows
# (test_validate_feature_docs.sh, test_validate_template_refs.sh, ...). This
# item (#1476) is the one that builds check-surface-registry.tsv's
# SURFACE -> TEST_FILE mapping (see that file's own header: "one validator's
# tests live under a name that breaks the pattern") — and gives this
# validator its own dedicated home so the mapping is unambiguous, matching
# the sibling convention, rather than pointing the registry at another
# module's fixture suite.
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

fail() { echo "FAIL: $1" >&2; exit 1; }

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
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }

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

# ---------------------------------------------------------------------------
# A. ABSENT: no committed provider allowlist at all -> COMMITTED-MISSING,
#    non-zero, never a silent pass.
# ---------------------------------------------------------------------------
count
A_DIR="$WORK/a"
mkdir -p "$A_DIR"
A_COMMITTED="$A_DIR/committed.txt"
A_LOCAL="$A_DIR/local.txt"
A_LOG="$A_DIR/log.jsonl"
[[ ! -f "$A_COMMITTED" ]] || fail "A: fixture setup: committed file should not exist"
arc=0
aout="$(run_validator "$A_COMMITTED" "$A_LOCAL" "$A_LOG" 2>&1)" || arc=$?
if [[ "$arc" -eq 0 ]]; then
  fail "A: expected a non-zero exit on an absent committed allowlist, got rc=0:
$aout"
fi
case "$aout" in
  *COMMITTED-MISSING*) ;;
  *) fail "A: expected a COMMITTED-MISSING line, got:
$aout" ;;
esac
# NOTE: this ok() string is THE ANCHOR check-surface-registry.tsv's [absent]
# row for this surface names — it must appear ONLY here (never inside a
# fail() message above), so deleting this line is what the gate's own
# discrimination proof exercises. Keep it unique in this file.
ok "an absent committed allowlist: exit 1 (COMMITTED-MISSING), not 0"

# ---------------------------------------------------------------------------
# B. UNREADABLE: a well-formed committed allowlist, but the disclosure log
#    cannot be read -> CANNOT EVALUATE, non-zero, never a silent pass. This
#    is epic #1409's motivating instance 1, reproduced directly.
# ---------------------------------------------------------------------------
count
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
if [[ "$brc" -eq 0 ]]; then
  fail "B: expected a non-zero exit on an unreadable disclosure log, got rc=0:
$bout"
fi
case "$bout" in
  *"CANNOT EVALUATE"*) ;;
  *) fail "B: expected a CANNOT EVALUATE line, got:
$bout" ;;
esac
case "$bout" in
  *"validate-provider-disclosure: OK"*)
    fail "B: validator printed OK on an unreadable log:
$bout"
    ;;
esac
# See the note on case A's ok() line above — this string is the [unreadable]
# anchor and must stay unique to this line.
ok "an unreadable disclosure log: exit 1 (CANNOT EVALUATE), not 0"

# ---------------------------------------------------------------------------
# C. EMPTY: real entries were disclosed (so the sibling watermark anchor
#    records them), then the log is emptied IN PLACE -> TRUNCATED, non-zero,
#    never a silent "nothing here" pass. Mirrors test_allowlist.sh's test
#    25c, using the real pa_disclose call so the watermark's seq/hash format
#    is guaranteed valid rather than hand-forged.
# ---------------------------------------------------------------------------
count
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
if [[ "$crc" -eq 0 ]]; then
  fail "C: expected a non-zero exit on an emptied-in-place disclosure log, got rc=0:
$cout"
fi
case "$cout" in
  *TRUNCATED*) ;;
  *) fail "C: expected a TRUNCATED line, got:
$cout" ;;
esac
# See the note on case A's ok() line above — this string is the [empty]
# anchor and must stay unique to this line.
ok "an empty disclosure log with a non-empty watermark: exit 1 (TRUNCATED), not 0"

echo
echo "$pass/$total tests passed"
[[ "$pass" -eq "$total" ]] || exit 1
