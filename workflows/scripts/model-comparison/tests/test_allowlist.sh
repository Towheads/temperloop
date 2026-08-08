#!/usr/bin/env bash
#
# test_allowlist.sh — fixture suite for allowlist.sh (the committed
# provider allowlist + personal narrowing override + append-only,
# hash-chained disclosure log) and its pairing validator,
# workflows/scripts/validate-provider-disclosure.sh (temperloop#1250, epic
# #1225, ADR 0028). Plain mktemp-fixture style, mirroring
# workflows/scripts/config/tests/test_check_setting_registry.sh — no
# sandbox.sh needed here since every path this module reads is already an
# explicit env-var override (PROVIDER_ALLOWLIST_COMMITTED_FILE / _LOCAL_FILE
# / PROVIDER_DISCLOSURE_LOG_FILE), not a $HOME/XDG-derived one.
#
# Covers every acceptance bullet on temperloop#1250:
#   - the committed file is git-tracked, repo-scoped, defaults to
#     Anthropic-only (test 1)
#   - narrow succeeds (tests 2-3), widen is REJECTED by both the library and
#     the validator (tests 4-5)
#   - the disclosure log is append-only: a clean chain verifies (test 6);
#     rewriting an entry in place, or removing one, is DETECTED by both
#     pa_verify_log_chain and the validator (tests 7-8)
#   - the allowlist/disclosure-log pairing: pa_disclose refuses to log a
#     non-allowed provider (test 9); the validator flags a log entry for a
#     provider the current allowlist doesn't allow (test 10)
#   - the validator's good-log / bad-log output shape (folded into 6-8)
#
# No network. Deterministic. Kept POSIX-bash-3.2-friendly.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$MC_DIR/../../.." && pwd)"
ALLOWLIST_SH="$MC_DIR/allowlist.sh"
VALIDATOR="$REPO_ROOT/workflows/scripts/validate-provider-disclosure.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-allowlist-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }

# fixture_env <n> — prints an `export ...;` prefix wiring the three seam
# vars at scratch paths under $WORK/<n>/, isolated per test.
fixture_paths() {
  local n="$1"
  mkdir -p "$WORK/$n"
  echo "$WORK/$n/committed.txt" "$WORK/$n/local.txt" "$WORK/$n/log.jsonl"
}

# run_lib <n> <bash -c body> — sources allowlist.sh with the fixture's env
# vars set, then evaluates body (which may call any pa_* function).
run_lib() {
  local n="$1" body="$2" committed local_f log
  read -r committed local_f log <<<"$(fixture_paths "$n")"
  env \
    PROVIDER_ALLOWLIST_COMMITTED_FILE="$committed" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$local_f" \
    PROVIDER_DISCLOSURE_LOG_FILE="$log" \
    bash -c "source '$ALLOWLIST_SH'; $body"
}

run_validator() {
  local n="$1" committed local_f log
  read -r committed local_f log <<<"$(fixture_paths "$n")"
  env \
    PROVIDER_ALLOWLIST_COMMITTED_FILE="$committed" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$local_f" \
    PROVIDER_DISCLOSURE_LOG_FILE="$log" \
    bash "$VALIDATOR"
}

# ---------------------------------------------------------------------------
# 1. Committed-only: defaults to (a copy of) Anthropic-only; anthropic is
#    allowed, an un-listed provider is not.
# ---------------------------------------------------------------------------
read -r c1 l1 g1 <<<"$(fixture_paths 1)"
printf 'anthropic\n' >"$c1"

out="$(run_lib 1 'pa_is_allowed anthropic && echo YES || echo NO')"
[[ "$out" == "YES" ]] || fail "1: anthropic should be allowed by the committed-only default:
$out"
out="$(run_lib 1 'pa_is_allowed openai && echo YES || echo NO')"
[[ "$out" == "NO" ]] || fail "1: openai should NOT be allowed (not in the Anthropic-only default):
$out"
ok "1 committed-only default: anthropic allowed, openai denied"

# ---------------------------------------------------------------------------
# 2. The REAL committed file this PR ships is git-tracked and defaults to
#    Anthropic-only — the actual acceptance-bullet-1 artifact, not a
#    fixture stand-in.
# ---------------------------------------------------------------------------
REAL_COMMITTED="$MC_DIR/provider-allowlist.txt"
[[ -f "$REAL_COMMITTED" ]] || fail "2: $REAL_COMMITTED does not exist"
git -C "$REPO_ROOT" ls-files --error-unmatch -- "$REAL_COMMITTED" >/dev/null 2>&1 \
  || fail "2: $REAL_COMMITTED is not git-tracked"
case "$REAL_COMMITTED" in
  */.temperloop/*) fail "2: committed allowlist must not live under .temperloop/" ;;
esac
real_list="$(env PROVIDER_ALLOWLIST_COMMITTED_FILE="$REAL_COMMITTED" PROVIDER_ALLOWLIST_LOCAL_FILE="$WORK/nope" PROVIDER_DISCLOSURE_LOG_FILE="$WORK/nope.jsonl" bash -c "source '$ALLOWLIST_SH'; pa_committed_list")"
[[ "$real_list" == "anthropic" ]] || fail "2: real committed allowlist should be exactly 'anthropic' by default, got:
$real_list"
ok "2 the shipped committed allowlist is git-tracked, repo-scoped, and Anthropic-only"

# ---------------------------------------------------------------------------
# 3. Narrow succeeds: committed lists two providers, personal override
#    narrows to one — the narrowed-out provider is denied even though the
#    committed ceiling allows it.
# ---------------------------------------------------------------------------
read -r c3 l3 g3 <<<"$(fixture_paths 3)"
printf 'anthropic\nopenai\n' >"$c3"
printf 'anthropic\n' >"$l3"

out="$(run_lib 3 'pa_is_allowed anthropic && echo YES || echo NO')"
[[ "$out" == "YES" ]] || fail "3: anthropic should still be allowed after narrowing:
$out"
out="$(run_lib 3 'pa_is_allowed openai && echo YES || echo NO')"
[[ "$out" == "NO" ]] || fail "3: openai should be DENIED — narrowed out by the personal override even though the committed ceiling allows it:
$out"
ok "3 narrow-succeeds: personal override removes a committed-allowed provider"

# ---------------------------------------------------------------------------
# 4. Narrow to empty: an existing-but-empty override denies everything,
#    including what the committed file allows.
# ---------------------------------------------------------------------------
read -r c4 l4 g4 <<<"$(fixture_paths 4)"
printf 'anthropic\n' >"$c4"
: >"$l4"

out="$(run_lib 4 'pa_is_allowed anthropic && echo YES || echo NO')"
[[ "$out" == "NO" ]] || fail "4: an empty personal override should narrow to nothing allowed:
$out"
ok "4 narrow-to-empty: an existing empty override denies everything"

# ---------------------------------------------------------------------------
# 5. Widen REJECTED at the library level: personal override names a
#    provider the committed file doesn't list. pa_effective_list refuses to
#    resolve (fail closed) and even the committed-allowed provider is then
#    denied.
# ---------------------------------------------------------------------------
read -r c5 l5 g5 <<<"$(fixture_paths 5)"
printf 'anthropic\n' >"$c5"
printf 'anthropic\nopenai\n' >"$l5"

out=""
out="$(run_lib 5 'pa_narrowing_violations')" || true
[[ "$out" == "openai" ]] || fail "5: pa_narrowing_violations should report exactly 'openai', got:
$out"
rc=0
run_lib 5 'pa_effective_list' >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "5: pa_effective_list should fail with rc 2 (PA_RC_WIDEN_REJECTED) on a widen attempt, got rc=$rc"
out="$(run_lib 5 'pa_is_allowed anthropic && echo YES || echo NO')"
[[ "$out" == "NO" ]] || fail "5: a widen attempt should fail CLOSED — even anthropic (which both files agree on) must be denied while the config is invalid:
$out"
ok "5 widen-rejected at the library level: fail closed, denies everything"

# ---------------------------------------------------------------------------
# 6. Widen REJECTED by the validator (the mechanically-checked gate, not
#    just the library) — acceptance bullet 2's fixture.
# ---------------------------------------------------------------------------
vout=""
vrc=0
vout="$(run_validator 5 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "6: validator should FAIL on a widen attempt, exited 0:
$vout"
case "$vout" in
  *WIDEN-REJECTED*openai*) ;;
  *) fail "6: expected a WIDEN-REJECTED line naming openai, got:
$vout" ;;
esac
ok "6 widen-rejected by the validator (WIDEN-REJECTED, exit non-zero)"

# ---------------------------------------------------------------------------
# 7. Clean disclosure log: three entries, chain verifies, validator OK.
# ---------------------------------------------------------------------------
read -r c7 l7 g7 <<<"$(fixture_paths 7)"
printf 'anthropic\nopenai\n' >"$c7"
run_lib 7 'pa_disclose openai "issue#1" >/dev/null'
run_lib 7 'pa_disclose anthropic "issue#2" >/dev/null'
run_lib 7 'pa_disclose openai "pr#3" >/dev/null'

[[ -f "$g7" ]] || fail "7: pa_disclose should have created the log file"
n="$(grep -c . "$g7")"
[[ "$n" -eq 3 ]] || fail "7: expected 3 log lines, got $n"

rc=0
run_lib 7 "pa_verify_log_chain '$g7'" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail "7: pa_verify_log_chain should report a clean chain (rc 0), got rc=$rc"

vout=""
vrc=0
vout="$(run_validator 7 2>&1)" || vrc=$?
[[ "$vrc" -eq 0 ]] || fail "7: validator should pass on a clean 3-entry log:
$vout"
case "$vout" in
  *validate-provider-disclosure:\ OK*) ;;
  *) fail "7: expected a trailing OK line, got:
$vout" ;;
esac
# Every entry never carries a content-like field.
while IFS= read -r line; do
  keys="$(printf '%s' "$line" | jq -r 'keys | sort | join(" ")')"
  [[ "$keys" == "hash item_ref prev_hash provider schema_version seq ts" ]] \
    || fail "7: unexpected field set on a log entry: $keys"
  printf '%s' "$line" | jq -e 'has("content") | not' >/dev/null \
    || fail "7: a log entry must never carry a content field"
done <"$g7"
ok "7 clean disclosure log: chain verifies, validator OK, no content field ever logged"

# ---------------------------------------------------------------------------
# 8. Append-only violation: rewriting an entry IN PLACE is detected
#    (INVALID-HASH) by both pa_verify_log_chain and the validator.
# ---------------------------------------------------------------------------
read -r c8 l8 g8 <<<"$(fixture_paths 8)"
printf 'anthropic\nopenai\n' >"$c8"
run_lib 8 'pa_disclose openai "issue#1" >/dev/null'
run_lib 8 'pa_disclose anthropic "issue#2" >/dev/null'

# Tamper: rewrite line 1's item_ref in place via jq, leaving its `hash`
# field as it was — exactly the "rewritten in place" fixture the
# acceptance bullet asks for. Cross-platform (no `sed -i ''` BSD/GNU
# divergence): rebuild through a temp file with jq, which allowlist.sh
# already depends on.
tampered_line1="$(sed -n '1p' "$g8" | jq -c '.item_ref = "issue#TAMPERED"')"
{ printf '%s\n' "$tampered_line1"; sed -n '2,$p' "$g8"; } >"$g8.tmp" && mv "$g8.tmp" "$g8"

rc=0
out="$(run_lib 8 "pa_verify_log_chain '$g8'" 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "8: pa_verify_log_chain should report chain violations (rc 1) on a rewritten entry, got rc=$rc:
$out"
case "$out" in
  *INVALID-HASH*) ;;
  *) fail "8: expected an INVALID-HASH line, got:
$out" ;;
esac

vout=""
vrc=0
vout="$(run_validator 8 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "8: validator should FAIL on a rewritten entry:
$vout"
case "$vout" in
  *INVALID-HASH*) ;;
  *) fail "8: validator output should include INVALID-HASH, got:
$vout" ;;
esac
ok "8 append-only violation (rewrite in place) detected: INVALID-HASH, both layers fail"

# ---------------------------------------------------------------------------
# 9. Append-only violation: REMOVING an entry breaks the chain for every
#    entry after it (BROKEN-CHAIN / SEQ-GAP) — detected by both layers.
# ---------------------------------------------------------------------------
read -r c9 l9 g9 <<<"$(fixture_paths 9)"
printf 'anthropic\nopenai\n' >"$c9"
run_lib 9 'pa_disclose openai "issue#1" >/dev/null'
run_lib 9 'pa_disclose anthropic "issue#2" >/dev/null'
run_lib 9 'pa_disclose openai "issue#3" >/dev/null'

# Remove the middle entry (line 2) in place.
sed -n '1p;3p' "$g9" >"$g9.tmp" && mv "$g9.tmp" "$g9"
n="$(grep -c . "$g9")"
[[ "$n" -eq 2 ]] || fail "9: fixture setup: expected 2 lines after removal, got $n"

rc=0
out="$(run_lib 9 "pa_verify_log_chain '$g9'" 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "9: pa_verify_log_chain should report chain violations (rc 1) on a removed entry, got rc=$rc:
$out"
case "$out" in
  *SEQ-GAP*|*BROKEN-CHAIN*) ;;
  *) fail "9: expected a SEQ-GAP or BROKEN-CHAIN line, got:
$out" ;;
esac

vout=""
vrc=0
vout="$(run_validator 9 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "9: validator should FAIL on a removed entry:
$vout"
ok "9 append-only violation (removal) detected: chain breaks, both layers fail"

# ---------------------------------------------------------------------------
# 10. pa_disclose REFUSES to write an entry for a provider not currently
#     allowed — the allowlist/log pairing is enforced at write time too,
#     not just by the validator after the fact.
# ---------------------------------------------------------------------------
read -r c10 l10 g10 <<<"$(fixture_paths 10)"
printf 'anthropic\n' >"$c10"   # openai NOT in the committed ceiling

rc=0
run_lib 10 'pa_disclose openai "issue#1"' >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] || fail "10: pa_disclose should refuse to log a disallowed provider"
[[ ! -f "$g10" ]] || fail "10: pa_disclose must not create a log file when it refuses to write"
ok "10 pa_disclose refuses to log a non-allowed provider; no file written"

# ---------------------------------------------------------------------------
# 11. Validator membership check: a log entry names a provider that is
#     valid JSON/chain-wise but is NOT in the current effective allowlist
#     (simulating drift — e.g. the committed file was later narrowed by a
#     reviewed commit after the entry was logged).
# ---------------------------------------------------------------------------
read -r c11 l11 g11 <<<"$(fixture_paths 11)"
printf 'anthropic\nopenai\n' >"$c11"
run_lib 11 'pa_disclose openai "issue#1" >/dev/null'
# Now narrow the committed ceiling itself (simulating a later reviewed
# commit that drops openai) — the existing log entry is now a membership
# violation against the CURRENT allowlist.
printf 'anthropic\n' >"$c11"

vout=""
vrc=0
vout="$(run_validator 11 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "11: validator should FAIL when a log entry's provider is no longer in the effective allowlist:
$vout"
case "$vout" in
  *ALLOWLIST-VIOLATION*openai*) ;;
  *) fail "11: expected an ALLOWLIST-VIOLATION line naming openai, got:
$vout" ;;
esac
ok "11 validator allowlist-membership check: a log entry outside the current allowlist fails"

# ---------------------------------------------------------------------------
# 12. Malformed committed provider name fails the validator.
# ---------------------------------------------------------------------------
read -r c12 l12 g12 <<<"$(fixture_paths 12)"
printf 'Anthropic!\n' >"$c12"

vout=""
vrc=0
vout="$(run_validator 12 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "12: validator should FAIL on a malformed provider name:
$vout"
case "$vout" in
  *MALFORMED-PROVIDER*) ;;
  *) fail "12: expected a MALFORMED-PROVIDER line, got:
$vout" ;;
esac
ok "12 malformed committed provider name fails the validator"

# ---------------------------------------------------------------------------
# 13. Absent log file is legal — a fresh checkout that never ran a
#     comparison must not fail the gate.
# ---------------------------------------------------------------------------
read -r c13 l13 g13 <<<"$(fixture_paths 13)"
printf 'anthropic\n' >"$c13"
[[ ! -f "$g13" ]] || fail "13: fixture setup: log should not exist yet"

vout=""
vrc=0
vout="$(run_validator 13 2>&1)" || vrc=$?
[[ "$vrc" -eq 0 ]] || fail "13: validator should PASS with no disclosure log at all:
$vout"
ok "13 absent disclosure log is legal (nothing sent yet)"

echo "---"
echo "$pass/13 tests passed"
