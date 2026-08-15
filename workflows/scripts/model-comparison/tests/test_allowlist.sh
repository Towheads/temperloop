#!/usr/bin/env bash
#
# test_allowlist.sh — fixture suite for allowlist.sh (the committed
# provider allowlist + personal narrowing override + append-only,
# hash-chained, watermark-anchored disclosure log) and its pairing
# validator, workflows/scripts/validate-provider-disclosure.sh
# (temperloop#1250, epic #1225, ADR 0028). Plain mktemp-fixture style,
# mirroring workflows/scripts/config/tests/test_check_setting_registry.sh —
# no sandbox.sh needed here since every path this module reads is already an
# explicit env-var override (PROVIDER_ALLOWLIST_COMMITTED_FILE / _LOCAL_FILE
# / PROVIDER_DISCLOSURE_LOG_FILE), not a $HOME/XDG-derived one. Those three
# are a FIXTURE-TEST SEAM: allowlist.sh reads them only alongside
# PROVIDER_ALLOWLIST_TEST_SEAM=1, which every helper below sets.
#
# Covers every acceptance bullet on temperloop#1250:
#   - the committed file is git-tracked, repo-scoped, defaults to
#     Anthropic-only (tests 1-2), and the validator itself enforces each of
#     those properties (tests 18-21) rather than the test re-implementing them
#   - narrow succeeds (tests 3-4), widen is REJECTED by both the library and
#     the validator (tests 5-6)
#   - the disclosure log is append-only: a clean chain verifies (test 7);
#     rewriting an entry in place, or removing one, is DETECTED by both
#     pa_verify_log_chain and the validator (tests 8-9), with BROKEN-CHAIN
#     and SEQ-GAP each pinned by their own isolating fixture (14-15) so
#     neither check can be deleted behind the other's coverage
#   - the allowlist/disclosure-log pairing: pa_disclose refuses to log a
#     non-allowed provider (test 10); the validator flags a log entry for a
#     provider the current allowlist doesn't allow (test 11)
#
# And every hardening the security review of the first cut required:
#   22  arithmetic injection through a log-supplied `seq` (code execution
#       inside the CI gate) is refused as MALFORMED-SEQ, with a side-effect
#       probe proving nothing ran
#   23  a MULTI-LINE or EMPTY provider name is DENIED, not admitted by a
#       line-oriented `grep -Fx` membership test
#   24  an unreadable log or ceiling is CANNOT EVALUATE (non-zero), never a
#       silent OK
#   25  tail truncation / whole-log deletion / a full re-forge / a deleted
#       anchor are all caught by the watermark
#   26  N concurrent discloses produce one clean chain, not a permanently
#       broken one
#   27  the library is safe to source into a `set -euo pipefail` caller
#   28  the committed ceiling cannot be repointed by an env var
#   29  the hash preimage is injective across the provider/item_ref boundary
#   30  `seq` comes from the tail entry, not from a line count
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
# An in-repo scratch dir, needed by the two fixtures whose property is about
# the path being INSIDE the repo (git-tracked-ness, and the .temperloop/
# location ban). Lives under the already-gitignored .temperloop/model-comparison/
# so it can never be swept into a commit.
REPO_SCRATCH="$REPO_ROOT/.temperloop/model-comparison/test-fixture-$$"
# chmod back up before rm: a fixture that deliberately chmod 000s a file must
# never leave an unreadable path behind, even when the suite exits on a
# failing assertion mid-fixture.
cleanup() {
  chmod -R u+rwX "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
  chmod -R u+rwX "$REPO_SCRATCH" 2>/dev/null || true
  rm -rf "$REPO_SCRATCH"
}
trap cleanup EXIT

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }

# fixture_paths <n> — prints the three seam paths for a per-test scratch dir.
fixture_paths() {
  local n="$1"
  mkdir -p "$WORK/$n"
  echo "$WORK/$n/committed.txt" "$WORK/$n/local.txt" "$WORK/$n/log.jsonl"
}

# wm_path <logfile> — the sibling watermark anchor allowlist.sh maintains.
wm_path() { printf '%s\n' "${1%.jsonl}.watermark"; }

# run_lib_at / run_validator_at — explicit-path forms, used by the fixtures
# that need a path outside $WORK (an in-repo committed file, a missing file).
run_lib_at() {
  local committed="$1" local_f="$2" log="$3" body="$4"
  env \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 \
    PROVIDER_ALLOWLIST_COMMITTED_FILE="$committed" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$local_f" \
    PROVIDER_DISCLOSURE_LOG_FILE="$log" \
    bash -c "source '$ALLOWLIST_SH'; $body"
}

run_validator_at() {
  local committed="$1" local_f="$2" log="$3"
  env \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 \
    PROVIDER_ALLOWLIST_COMMITTED_FILE="$committed" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$local_f" \
    PROVIDER_DISCLOSURE_LOG_FILE="$log" \
    bash "$VALIDATOR"
}

# run_lib <n> <bash -c body> — sources allowlist.sh with fixture <n>'s env
# vars set, then evaluates body (which may call any pa_* function).
run_lib() {
  local n="$1" body="$2" committed local_f log
  read -r committed local_f log <<<"$(fixture_paths "$n")"
  run_lib_at "$committed" "$local_f" "$log" "$body"
}

run_validator() {
  local n="$1" committed local_f log
  read -r committed local_f log <<<"$(fixture_paths "$n")"
  run_validator_at "$committed" "$local_f" "$log"
}

# ---------------------------------------------------------------------------
# 1. Committed-only: defaults to (a copy of) Anthropic-only; anthropic is
#    allowed, an un-listed provider is not.
# ---------------------------------------------------------------------------
count
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
#    fixture stand-in. (The VALIDATOR's own enforcement of each of these
#    properties is pinned separately by tests 19-21, so deleting a check
#    from the validator cannot hide behind this test.)
# ---------------------------------------------------------------------------
count
REAL_COMMITTED="$MC_DIR/provider-allowlist.txt"
[[ -f "$REAL_COMMITTED" ]] || fail "2: $REAL_COMMITTED does not exist"
git -C "$REPO_ROOT" ls-files --error-unmatch -- "$REAL_COMMITTED" >/dev/null 2>&1 \
  || fail "2: $REAL_COMMITTED is not git-tracked"
case "$REAL_COMMITTED" in
  */.temperloop/*) fail "2: committed allowlist must not live under .temperloop/" ;;
esac
real_list="$(run_lib_at "$REAL_COMMITTED" "$WORK/nope" "$WORK/nope.jsonl" 'pa_committed_list')"
[[ "$real_list" == "anthropic" ]] || fail "2: real committed allowlist should be exactly 'anthropic' by default, got:
$real_list"
ok "2 the shipped committed allowlist is git-tracked, repo-scoped, and Anthropic-only"

# ---------------------------------------------------------------------------
# 3. Narrow succeeds: committed lists two providers, personal override
#    narrows to one — the narrowed-out provider is denied even though the
#    committed ceiling allows it.
# ---------------------------------------------------------------------------
count
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
count
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
count
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
count
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
# 7. Clean disclosure log: three entries, chain verifies, watermark anchor
#    written, validator OK.
# ---------------------------------------------------------------------------
count
read -r c7 l7 g7 <<<"$(fixture_paths 7)"
printf 'anthropic\nopenai\n' >"$c7"
run_lib 7 'pa_disclose openai "issue#1" >/dev/null'
run_lib 7 'pa_disclose anthropic "issue#2" >/dev/null'
run_lib 7 'pa_disclose openai "pr#3" >/dev/null'

[[ -f "$g7" ]] || fail "7: pa_disclose should have created the log file"
n="$(grep -c . "$g7")"
[[ "$n" -eq 3 ]] || fail "7: expected 3 log lines, got $n"
[[ -f "$(wm_path "$g7")" ]] || fail "7: pa_disclose should have written the watermark anchor $(wm_path "$g7")"
wm_seen="$(cat "$(wm_path "$g7")")"
[[ "${wm_seen%% *}" == "3" ]] || fail "7: watermark should record max_seq 3, got '$wm_seen'"

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
ok "7 clean disclosure log: chain verifies, watermark written, validator OK, no content field ever logged"

# ---------------------------------------------------------------------------
# 8. Append-only violation: rewriting an entry IN PLACE is detected
#    (INVALID-HASH) by both pa_verify_log_chain and the validator.
# ---------------------------------------------------------------------------
count
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
# 9. Append-only violation: REMOVING an interior entry breaks the chain for
#    every entry after it — BOTH SEQ-GAP and BROKEN-CHAIN, asserted
#    individually (never an alternation: an `A|B` expectation lets either
#    check be deleted while the other keeps the test green).
# ---------------------------------------------------------------------------
count
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
case "$out" in *SEQ-GAP*) ;; *) fail "9: expected a SEQ-GAP line, got:
$out" ;; esac
case "$out" in *BROKEN-CHAIN*) ;; *) fail "9: expected a BROKEN-CHAIN line, got:
$out" ;; esac

vout=""
vrc=0
vout="$(run_validator 9 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "9: validator should FAIL on a removed entry:
$vout"
ok "9 append-only violation (interior removal) detected: SEQ-GAP and BROKEN-CHAIN both fire, both layers fail"

# ---------------------------------------------------------------------------
# 10. pa_disclose REFUSES to write an entry for a provider not currently
#     allowed — the allowlist/log pairing is enforced at write time too,
#     not just by the validator after the fact.
# ---------------------------------------------------------------------------
count
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
count
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
count
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
# 13. Absent log file AND absent watermark is legal — a fresh checkout that
#     never ran a comparison must not fail the gate. (Contrast test 25b: an
#     absent log with a watermark that records entries is TRUNCATED, not
#     clean — "nothing here" is only innocent when nothing was ever here.)
# ---------------------------------------------------------------------------
count
read -r c13 l13 g13 <<<"$(fixture_paths 13)"
printf 'anthropic\n' >"$c13"
[[ ! -f "$g13" ]] || fail "13: fixture setup: log should not exist yet"
[[ ! -f "$(wm_path "$g13")" ]] || fail "13: fixture setup: watermark should not exist yet"

vout=""
vrc=0
vout="$(run_validator 13 2>&1)" || vrc=$?
[[ "$vrc" -eq 0 ]] || fail "13: validator should PASS with no disclosure log at all:
$vout"
ok "13 absent disclosure log (and no watermark) is legal (nothing sent yet)"

# ---------------------------------------------------------------------------
# 14. BROKEN-CHAIN in ISOLATION. Entry 2's prev_hash is repointed at a
#     different (well-formed) digest and its own hash recomputed, and the
#     watermark is rebuilt to match — so seq is continuous, every hash
#     matches its own fields, and the anchor agrees. The ONLY thing wrong is
#     the link. Deleting the prev_hash comparison must fail this test and
#     nothing else can mask it.
# ---------------------------------------------------------------------------
count
read -r c14 l14 g14 <<<"$(fixture_paths 14)"
printf 'anthropic\nopenai\n' >"$c14"
run_lib 14 'pa_disclose openai "issue#1" >/dev/null'
run_lib 14 'pa_disclose openai "issue#2" >/dev/null'

fake_prev="$(printf 'not-the-previous-entry' | (command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256) | awk '{print $1}')"
l2="$(sed -n '2p' "$g14")"
rebuilt="$(run_lib 14 "
  line='$l2'
  sv=\"\$(printf '%s' \"\$line\" | jq -r '.schema_version')\"
  ts=\"\$(printf '%s' \"\$line\" | jq -r '.ts')\"
  pv=\"\$(printf '%s' \"\$line\" | jq -r '.provider')\"
  ir=\"\$(printf '%s' \"\$line\" | jq -r '.item_ref')\"
  sq=\"\$(printf '%s' \"\$line\" | jq -r '.seq')\"
  ph='$fake_prev'
  h=\"\$(_pa_sha256 \"\$(_pa_canonical_entry \"\$sv\" \"\$ts\" \"\$pv\" \"\$ir\" \"\$sq\" \"\$ph\")\")\"
  printf '%s' \"\$line\" | jq -c --arg ph \"\$ph\" --arg h \"\$h\" '.prev_hash=\$ph | .hash=\$h'
")"
{ sed -n '1p' "$g14"; printf '%s\n' "$rebuilt"; } >"$g14.tmp" && mv "$g14.tmp" "$g14"
# Rebuild the anchor to match the tampered tail — an attacker with write
# access to the log has write access to the sibling anchor too (see
# allowlist.sh's header), and pinning it here isolates BROKEN-CHAIN.
printf '2 %s\n' "$(printf '%s' "$rebuilt" | jq -r '.hash')" >"$(wm_path "$g14")"

rc=0
out="$(run_lib 14 "pa_verify_log_chain '$g14'" 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "14: expected chain violations (rc 1), got rc=$rc:
$out"
case "$out" in *BROKEN-CHAIN*) ;; *) fail "14: expected a BROKEN-CHAIN line, got:
$out" ;; esac
case "$out" in *SEQ-GAP*) fail "14: fixture is not isolating — SEQ-GAP also fired:
$out" ;; esac
case "$out" in *INVALID-HASH*) fail "14: fixture is not isolating — INVALID-HASH also fired:
$out" ;; esac
case "$out" in *TRUNCATED*|*REFORGED*|*WATERMARK*) fail "14: fixture is not isolating — a watermark violation also fired:
$out" ;; esac
ok "14 BROKEN-CHAIN fires on its own (seq, hashes and anchor all intact)"

# ---------------------------------------------------------------------------
# 15. SEQ-GAP in ISOLATION. A single-entry log whose seq is 5 instead of 1,
#     with its own hash and the anchor recomputed to match: prev_hash is
#     still "genesis" so the link is fine, the hash matches its own fields so
#     INVALID-HASH is quiet, and the anchor agrees. Only the sequence is
#     wrong.
# ---------------------------------------------------------------------------
count
read -r c15 l15 g15 <<<"$(fixture_paths 15)"
printf 'anthropic\nopenai\n' >"$c15"
run_lib 15 'pa_disclose openai "issue#1" >/dev/null'
l1="$(sed -n '1p' "$g15")"
rebuilt15="$(run_lib 15 "
  line='$l1'
  sv=\"\$(printf '%s' \"\$line\" | jq -r '.schema_version')\"
  ts=\"\$(printf '%s' \"\$line\" | jq -r '.ts')\"
  pv=\"\$(printf '%s' \"\$line\" | jq -r '.provider')\"
  ir=\"\$(printf '%s' \"\$line\" | jq -r '.item_ref')\"
  ph=\"\$(printf '%s' \"\$line\" | jq -r '.prev_hash')\"
  h=\"\$(_pa_sha256 \"\$(_pa_canonical_entry \"\$sv\" \"\$ts\" \"\$pv\" \"\$ir\" 5 \"\$ph\")\")\"
  printf '%s' \"\$line\" | jq -c --arg h \"\$h\" '.seq=5 | .hash=\$h'
")"
printf '%s\n' "$rebuilt15" >"$g15"
printf '5 %s\n' "$(printf '%s' "$rebuilt15" | jq -r '.hash')" >"$(wm_path "$g15")"

rc=0
out="$(run_lib 15 "pa_verify_log_chain '$g15'" 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "15: expected chain violations (rc 1), got rc=$rc:
$out"
case "$out" in *SEQ-GAP*) ;; *) fail "15: expected a SEQ-GAP line, got:
$out" ;; esac
case "$out" in *BROKEN-CHAIN*) fail "15: fixture is not isolating — BROKEN-CHAIN also fired:
$out" ;; esac
case "$out" in *INVALID-HASH*) fail "15: fixture is not isolating — INVALID-HASH also fired:
$out" ;; esac
ok "15 SEQ-GAP fires on its own (link, hash and anchor all intact)"

# ---------------------------------------------------------------------------
# 16. FIELD-SET: an entry that grew an extra field is refused — this is the
#     mechanical form of "the log NEVER carries content".
# ---------------------------------------------------------------------------
count
read -r c16 l16 g16 <<<"$(fixture_paths 16)"
printf 'anthropic\nopenai\n' >"$c16"
run_lib 16 'pa_disclose openai "issue#1" >/dev/null'
sed -n '1p' "$g16" | jq -c '. + {content: "the actual prompt text"}' >"$g16.tmp" && mv "$g16.tmp" "$g16"

rc=0
out="$(run_lib 16 "pa_verify_log_chain '$g16'" 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "16: expected chain violations (rc 1) on an entry carrying content, got rc=$rc:
$out"
case "$out" in *FIELD-SET*) ;; *) fail "16: expected a FIELD-SET line, got:
$out" ;; esac
vrc=0
vout="$(run_validator 16 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "16: validator should FAIL on an entry carrying a content field:
$vout"
case "$vout" in *FIELD-SET*) ;; *) fail "16: validator output should include FIELD-SET, got:
$vout" ;; esac
ok "16 FIELD-SET: an entry that grew a content field is refused by both layers"

# ---------------------------------------------------------------------------
# 17. The built-in fail-CLOSED default. A committed file that parses to zero
#     providers (comment-only) must resolve to the hardcoded Anthropic-only
#     default, never to "nothing" and never to "everything".
# ---------------------------------------------------------------------------
count
read -r c17 l17 g17 <<<"$(fixture_paths 17)"
printf '# every line here is a comment\n#\n\n' >"$c17"

out="$(run_lib 17 'pa_committed_list' 2>/dev/null)"
[[ "$out" == "anthropic" ]] || fail "17: an empty committed file must fall back to the built-in default 'anthropic', got:
$out"
out="$(run_lib 17 'pa_is_allowed anthropic && echo YES || echo NO' 2>/dev/null)"
[[ "$out" == "YES" ]] || fail "17: the built-in default must still allow anthropic, got:
$out"
out="$(run_lib 17 'pa_is_allowed openai && echo YES || echo NO' 2>/dev/null)"
[[ "$out" == "NO" ]] || fail "17: the built-in default must not allow openai, got:
$out"
ok "17 built-in default: an empty committed ceiling falls back CLOSED to anthropic"

# ---------------------------------------------------------------------------
# 18. Validator: COMMITTED-MISSING when there is no committed ceiling at all.
# ---------------------------------------------------------------------------
count
read -r c18 l18 g18 <<<"$(fixture_paths 18)"
[[ ! -f "$c18" ]] || fail "18: fixture setup: committed file should not exist"
vrc=0
vout="$(run_validator 18 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "18: validator should FAIL when the committed ceiling is absent:
$vout"
case "$vout" in *COMMITTED-MISSING*) ;; *) fail "18: expected a COMMITTED-MISSING line, got:
$vout" ;; esac
ok "18 validator: an absent committed ceiling is COMMITTED-MISSING"

# ---------------------------------------------------------------------------
# 19. Validator: COMMITTED-NOT-TRACKED for an in-repo ceiling that exists on
#     disk but carries no commit history. This is the VALIDATOR asserting the
#     property, not the suite re-running `git ls-files` itself.
# ---------------------------------------------------------------------------
count
mkdir -p "$REPO_SCRATCH"
c19="$REPO_SCRATCH/untracked-allowlist.txt"
printf 'anthropic\n' >"$c19"
vrc=0
vout="$(run_validator_at "$c19" "$WORK/19-local.txt" "$WORK/19-log.jsonl" 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "19: validator should FAIL on an in-repo but untracked ceiling:
$vout"
case "$vout" in *COMMITTED-NOT-TRACKED*) ;; *) fail "19: expected a COMMITTED-NOT-TRACKED line, got:
$vout" ;; esac
ok "19 validator: an untracked in-repo ceiling is COMMITTED-NOT-TRACKED"

# ---------------------------------------------------------------------------
# 20. Validator: COMMITTED-LOCATION for a ceiling under the gitignored
#     .temperloop/ runtime dir (ADR 0028 decision 1 — the ceiling is never
#     runtime state).
# ---------------------------------------------------------------------------
count
case "$c19" in
  */.temperloop/*) ;;
  *) fail "20: fixture setup: $c19 was expected to sit under .temperloop/" ;;
esac
case "$vout" in *COMMITTED-LOCATION*) ;; *) fail "20: expected a COMMITTED-LOCATION line for a ceiling under .temperloop/, got:
$vout" ;; esac
ok "20 validator: a ceiling under .temperloop/ is COMMITTED-LOCATION"

# ---------------------------------------------------------------------------
# 21. Validator: ANTHROPIC-MISSING when the committed ceiling no longer names
#     the trusted default provider (ADR 0028 decision 3).
# ---------------------------------------------------------------------------
count
read -r c21 l21 g21 <<<"$(fixture_paths 21)"
printf 'openai\n' >"$c21"
vrc=0
vout="$(run_validator 21 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "21: validator should FAIL when the ceiling drops the trusted default provider:
$vout"
case "$vout" in *ANTHROPIC-MISSING*) ;; *) fail "21: expected an ANTHROPIC-MISSING line, got:
$vout" ;; esac
ok "21 validator: a ceiling without the trusted default is ANTHROPIC-MISSING"

# ---------------------------------------------------------------------------
# 22. ARITHMETIC INJECTION. A log-supplied `seq` carrying an array-subscript
#     command substitution used to reach `expect_seq=$((seq + 1))` and
#     EXECUTE inside the CI gate. Assert two things: the entry is reported as
#     MALFORMED-SEQ, and the payload's side-effect file does not exist.
# ---------------------------------------------------------------------------
count
read -r c22 l22 g22 <<<"$(fixture_paths 22)"
printf 'anthropic\n' >"$c22"
PROBE="$WORK/22/PWNED-via-ci-gate"
jq -nc --arg seq "violations[\$(touch $PROBE)]" \
  '{schema_version:"1",ts:"2026-01-01T00:00:00Z",provider:"anthropic",item_ref:"x",seq:$seq,prev_hash:"genesis",hash:"deadbeef"}' >"$g22"

rc=0
out="$(run_lib 22 "pa_verify_log_chain '$g22'" 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "22: expected chain violations (rc 1) on an injection payload, got rc=$rc:
$out"
case "$out" in *MALFORMED-SEQ*) ;; *) fail "22: expected a MALFORMED-SEQ line, got:
$out" ;; esac
[[ ! -e "$PROBE" ]] || fail "22: CODE EXECUTION — the log-supplied seq payload created $PROBE"

vrc=0
vout="$(run_validator 22 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "22: validator should FAIL on an injection payload:
$vout"
case "$vout" in *MALFORMED-SEQ*) ;; *) fail "22: validator output should include MALFORMED-SEQ, got:
$vout" ;; esac
[[ ! -e "$PROBE" ]] || fail "22: CODE EXECUTION through the validator — the payload created $PROBE"
ok "22 arithmetic injection: a non-integer seq is MALFORMED-SEQ and never evaluated"

# ---------------------------------------------------------------------------
# 23. MEMBERSHIP BYPASS. A multi-line provider name is several patterns to a
#     line-oriented matcher (matching if ANY line is allowed), and an empty
#     name matches the empty line an empty set prints. Both must DENY, at
#     both pa_is_allowed and pa_disclose.
# ---------------------------------------------------------------------------
count
read -r c23 l23 g23 <<<"$(fixture_paths 23)"
printf 'anthropic\n' >"$c23"

out="$(run_lib 23 'pa_is_allowed $'"'"'openai\nanthropic'"'"' && echo YES || echo NO' 2>/dev/null)"
[[ "$out" == "NO" ]] || fail "23: a multi-line provider name must be DENIED, got: $out"
rc=0
run_lib 23 'pa_disclose $'"'"'openai\nanthropic'"'"' "issue#1"' >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] || fail "23: pa_disclose must refuse a multi-line provider name"
[[ ! -f "$g23" ]] || fail "23: pa_disclose must not write a log entry for a multi-line provider name"

# The strictest possible config — an existing-but-empty override — used to
# say ALLOWED for the empty name.
read -r c23b l23b g23b <<<"$(fixture_paths 23b)"
printf 'anthropic\n' >"$c23b"
: >"$l23b"
out="$(run_lib 23b 'pa_is_allowed "" && echo YES || echo NO' 2>/dev/null)"
[[ "$out" == "NO" ]] || fail "23: an EMPTY provider name must be DENIED under an empty override, got: $out"
out="$(run_lib 23 'pa_is_allowed "" && echo YES || echo NO' 2>/dev/null)"
[[ "$out" == "NO" ]] || fail "23: an EMPTY provider name must be DENIED, got: $out"
ok "23 membership bypass: multi-line and empty provider names are both DENIED"

# ---------------------------------------------------------------------------
# 24. FAIL-CLOSED ON UNREADABLE INPUT. An unreadable log (with tampered
#     entries) and an unreadable ceiling must both be CANNOT EVALUATE with a
#     non-zero exit — never a silent OK. Permissions are restored inline AND
#     by the EXIT trap, so a failing assertion can't leave one behind.
# ---------------------------------------------------------------------------
count
read -r c24 l24 g24 <<<"$(fixture_paths 24)"
printf 'anthropic\nopenai\n' >"$c24"
run_lib 24 'pa_disclose openai "issue#1" >/dev/null'
run_lib 24 'pa_disclose openai "issue#2" >/dev/null'
sed -n '1p' "$g24" | jq -c '.item_ref = "TAMPERED"' >"$g24.tmp"
sed -n '2p' "$g24" >>"$g24.tmp"
mv "$g24.tmp" "$g24"

chmod 000 "$g24"
vrc=0
vout="$(run_validator 24 2>&1)" || vrc=$?
chmod 644 "$g24"
[[ "$vrc" -ne 0 ]] || fail "24: validator reported success on an UNREADABLE log — fail-open:
$vout"
case "$vout" in *CANNOT\ EVALUATE*) ;; *) fail "24: expected a CANNOT EVALUATE message for an unreadable log, got:
$vout" ;; esac
case "$vout" in *validate-provider-disclosure:\ OK*) fail "24: validator printed OK on an unreadable log:
$vout" ;; esac

chmod 000 "$c24"
vrc=0
vout="$(run_validator 24 2>&1)" || vrc=$?
chmod 644 "$c24"
[[ "$vrc" -ne 0 ]] || fail "24: validator reported success on an UNREADABLE committed ceiling — fail-open:
$vout"
case "$vout" in *CANNOT\ EVALUATE*) ;; *) fail "24: expected a CANNOT EVALUATE message for an unreadable ceiling, got:
$vout" ;; esac

# And the library half: pa_verify_log_chain must return CANNOT-EVALUATE (2),
# never rc 1 with an empty violation list (indistinguishable from clean).
chmod 000 "$g24"
rc=0
out="$(run_lib 24 "pa_verify_log_chain '$g24'" 2>/dev/null)" || rc=$?
chmod 644 "$g24"
[[ "$rc" -eq 2 ]] || fail "24: pa_verify_log_chain should return rc 2 (CANNOT EVALUATE) on an unreadable log, got rc=$rc"
[[ -z "$out" ]] || fail "24: pa_verify_log_chain should print no violations when it cannot evaluate, got:
$out"
ok "24 unreadable log and unreadable ceiling are both CANNOT EVALUATE, non-zero, never OK"

# ---------------------------------------------------------------------------
# 25. THE WATERMARK ANCHOR. Tail truncation, whole-log deletion, an emptied
#     file, a full re-forge, and a deleted anchor are each caught. (The
#     anchor is a local untracked file and does not stop an attacker who
#     rewrites both — see allowlist.sh's header. It closes the "one command"
#     cases.)
# ---------------------------------------------------------------------------
count
read -r c25 l25 g25 <<<"$(fixture_paths 25)"
printf 'anthropic\nopenai\n' >"$c25"
run_lib 25 'pa_disclose openai "issue#1" >/dev/null'
run_lib 25 'pa_disclose openai "issue#2" >/dev/null'
run_lib 25 'pa_disclose openai "issue#3" >/dev/null'
cp "$g25" "$WORK/25/orig.jsonl"
cp "$(wm_path "$g25")" "$WORK/25/orig.watermark"

# 25a — tail truncation (`head -2`): the chain alone cannot see it.
head -2 "$WORK/25/orig.jsonl" >"$g25"
vrc=0; vout="$(run_validator 25 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "25a: tail truncation (head -2) passed the validator:
$vout"
case "$vout" in *TRUNCATED*) ;; *) fail "25a: expected a TRUNCATED line, got:
$vout" ;; esac

# 25b — the whole log deleted.
rm -f "$g25"
vrc=0; vout="$(run_validator 25 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "25b: whole-log deletion passed the validator:
$vout"
case "$vout" in *TRUNCATED*) ;; *) fail "25b: expected a TRUNCATED line, got:
$vout" ;; esac

# 25c — the log emptied in place.
: >"$g25"
vrc=0; vout="$(run_validator 25 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "25c: emptying the log passed the validator:
$vout"
case "$vout" in *TRUNCATED*) ;; *) fail "25c: expected a TRUNCATED line, got:
$vout" ;; esac

# 25d — a full re-forge: a brand-new, internally perfect 3-entry chain
# replacing the original, with the original anchor still in place.
rm -f "$g25" "$(wm_path "$g25")"
run_lib 25 'pa_disclose openai "FORGED#1" >/dev/null'
run_lib 25 'pa_disclose openai "FORGED#2" >/dev/null'
run_lib 25 'pa_disclose openai "FORGED#3" >/dev/null'
rc=0; run_lib 25 "pa_verify_log_chain '$g25'" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail "25d: fixture setup — the forged chain should be internally clean, got rc=$rc"
cp "$WORK/25/orig.watermark" "$(wm_path "$g25")"
vrc=0; vout="$(run_validator 25 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "25d: a full re-forge passed the validator:
$vout"
case "$vout" in *REFORGED*) ;; *) fail "25d: expected a REFORGED line, got:
$vout" ;; esac

# 25e — the anchor itself deleted, log intact: detected, so removing the
# anchor is not a free way back to a truncatable log.
cp "$WORK/25/orig.jsonl" "$g25"
rm -f "$(wm_path "$g25")"
vrc=0; vout="$(run_validator 25 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "25e: a non-empty log with no watermark anchor passed the validator:
$vout"
case "$vout" in *WATERMARK-MISSING*) ;; *) fail "25e: expected a WATERMARK-MISSING line, got:
$vout" ;; esac
ok "25 watermark anchor: truncation, deletion, emptying, re-forge and a deleted anchor all fail"

# ---------------------------------------------------------------------------
# 26. CONCURRENCY. Eight simultaneous discloses — the expected shape of a
#     model-comparison fan-out — must produce ONE clean chain. Without a lock
#     all eight read the same tail and write seq=1/prev_hash=genesis, and the
#     chain is broken permanently with no repair path.
# ---------------------------------------------------------------------------
count
read -r c26 l26 g26 <<<"$(fixture_paths 26)"
printf 'anthropic\nopenai\n' >"$c26"
for i in 1 2 3 4 5 6 7 8; do
  run_lib 26 "pa_disclose openai 'issue#$i' >/dev/null" &
done
wait

n="$(grep -c . "$g26")"
[[ "$n" -eq 8 ]] || fail "26: expected 8 log lines after 8 concurrent discloses, got $n"
seqs="$(jq -r '.seq' "$g26" | tr '\n' ' ')"
[[ "$seqs" == "1 2 3 4 5 6 7 8 " ]] || fail "26: expected a contiguous seq run 1..8, got: $seqs"
rc=0
out="$(run_lib 26 "pa_verify_log_chain '$g26'" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "26: the chain must verify clean after concurrent discloses, got rc=$rc:
$out"
vrc=0
vout="$(run_validator 26 2>&1)" || vrc=$?
[[ "$vrc" -eq 0 ]] || fail "26: validator must pass after concurrent discloses:
$vout"
ok "26 concurrency: 8 parallel discloses serialize into one clean 1..8 chain"

# ---------------------------------------------------------------------------
# 27. SOURCEABLE INTO `set -euo pipefail`. The header advertises that
#     sourcing never mutates the caller's shell; the corollary is that the
#     library must survive the caller's options. Two sites used to break: a
#     comment-only committed file (the `| grep -v '^$'` filter matched
#     nothing -> rc 1 -> pipefail -> errexit killed the CALLER outright), and
#     a widen attempt (an inner rc 1 pre-empted the documented rc 2).
# ---------------------------------------------------------------------------
count
read -r c27 l27 g27 <<<"$(fixture_paths 27)"
printf '# comments only\n\n' >"$c27"
rc=0
out="$(run_lib_at "$c27" "$l27" "$g27" 'set -euo pipefail
c="$(pa_committed_list)"
printf "committed=%s\n" "$c"
if pa_is_allowed anthropic; then echo ALLOWED; else echo DENIED; fi
echo REACHED-END' 2>/dev/null)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "27: sourcing into a set -euo pipefail caller killed it (rc=$rc):
$out"
case "$out" in *REACHED-END*) ;; *) fail "27: the caller did not reach the end:
$out" ;; esac
case "$out" in *committed=anthropic*) ;; *) fail "27: expected the built-in fallback under set -e, got:
$out" ;; esac
case "$out" in *ALLOWED*) ;; *) fail "27: anthropic should be allowed under the built-in fallback, got:
$out" ;; esac

read -r c27b l27b g27b <<<"$(fixture_paths 27b)"
printf 'anthropic\n' >"$c27b"
printf 'anthropic\nopenai\n' >"$l27b"
rc=0
err="$(run_lib_at "$c27b" "$l27b" "$g27b" 'set -euo pipefail
pa_effective_list
echo SHOULD-NOT-REACH' 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -eq 2 ]] || fail "27: a widen attempt under set -e should surface the documented rc 2 (PA_RC_WIDEN_REJECTED), got rc=$rc:
$err"
case "$err" in *REJECTED*) ;; *) fail "27: a widen attempt under set -e should still print the REJECTED diagnosis, got:
$err" ;; esac
ok "27 safe to source into a set -euo pipefail caller; widen still returns rc 2 with its REJECTED message"

# ---------------------------------------------------------------------------
# 28. THE CEILING IS NOT AN ENV VAR. Pointing
#     PROVIDER_ALLOWLIST_COMMITTED_FILE at a widened file without the
#     fixture-test seam must NOT widen the effective allowlist, and the
#     validator must hard-fail rather than validate the substituted ceiling.
# ---------------------------------------------------------------------------
count
widened="$WORK/28-widened.txt"
printf 'anthropic\ncohere\n' >"$widened"

out="$(env PROVIDER_ALLOWLIST_COMMITTED_FILE="$widened" bash -c "source '$ALLOWLIST_SH'; pa_is_allowed cohere && echo YES || echo NO" 2>/dev/null)"
[[ "$out" == "NO" ]] || fail "28: an env var repointed the committed ceiling and cohere became allowed: $out"

vrc=0
vout="$(env PROVIDER_ALLOWLIST_COMMITTED_FILE="$widened" bash "$VALIDATOR" 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "28: validator accepted an env-substituted ceiling:
$vout"
case "$vout" in *CANNOT\ EVALUATE*PROVIDER_ALLOWLIST_TEST_SEAM*) ;; *) fail "28: expected a CANNOT EVALUATE naming the test seam, got:
$vout" ;; esac
ok "28 the committed ceiling cannot be repointed by an env var (library denies, validator hard-fails)"

# ---------------------------------------------------------------------------
# 29. HASH PREIMAGE IS INJECTIVE. `item_ref` is caller-controlled, so a
#     plain `|`-joined preimage let a delimiter in item_ref forge a
#     different (provider, item_ref) pair with the SAME digest — and
#     INVALID-HASH cannot distinguish two entries whose hashes agree.
# ---------------------------------------------------------------------------
count
h_pair="$(run_lib 1 '_pa_sha256 "$(_pa_canonical_entry 1 ts anthropic "a|b" 1 genesis)"')"
h_shift="$(run_lib 1 '_pa_sha256 "$(_pa_canonical_entry 1 ts "anthropic|a" b 1 genesis)"')"
[[ -n "$h_pair" && -n "$h_shift" ]] || fail "29: fixture setup: empty digest(s)"
[[ "$h_pair" != "$h_shift" ]] || fail "29: HASH COLLISION — provider='anthropic' item_ref='a|b' and provider='anthropic|a' item_ref='b' hash identically ($h_pair)"
ok "29 hash preimage is injective across the provider/item_ref boundary"

# ---------------------------------------------------------------------------
# 30. `seq` COMES FROM THE TAIL ENTRY, NOT A LINE COUNT. A line count
#     desynchronizes from the chain on any blank line or comment, and
#     `grep -c` exits 1 while printing 0, which turned the old
#     `$(( $(grep -c .) + 1 ))` into a bogus arithmetic-syntax-error
#     diagnostic on a blank-line-only log.
# ---------------------------------------------------------------------------
count
read -r c30 l30 g30 <<<"$(fixture_paths 30)"
printf 'anthropic\nopenai\n' >"$c30"
printf '\n' >"$g30"   # a log containing only a blank line
rc=0
err="$(run_lib 30 'pa_disclose openai "issue#1"' 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "30: pa_disclose should refuse to extend a log whose last line is unreadable"
case "$err" in *"arithmetic syntax error"*) fail "30: pa_disclose emitted a bogus arithmetic-syntax-error diagnostic:
$err" ;; esac
case "$err" in *"unreadable last line"*) ;; *) fail "30: expected an 'unreadable last line' refusal, got:
$err" ;; esac

# A log with a TRAILING blank line still continues the chain from the tail
# entry's own seq — nothing here depends on counting lines.
read -r c30b l30b g30b <<<"$(fixture_paths 30b)"
printf 'anthropic\nopenai\n' >"$c30b"
run_lib 30b 'pa_disclose openai "issue#1" >/dev/null'
run_lib 30b 'pa_disclose openai "issue#2" >/dev/null'
last_seq="$(jq -r '.seq' "$g30b" | tail -n 1)"
[[ "$last_seq" -eq 2 ]] || fail "30: expected the second entry to carry seq=2, got $last_seq"
ok "30 seq is derived from the tail entry's own seq, with a clean refusal on an unreadable tail"

# ---------------------------------------------------------------------------
# 31. SYMLINK PREFIX (temperloop#1333): the validator's repo-root vs.
#     committed-file prefix match must not silently skip the git-tracked
#     check when a symlinked ancestor separates the two. Fabricates its own
#     symlink (rather than relying on macOS's ambient /tmp -> /private/tmp,
#     which is what makes case 19 above fail there but stay green on Linux
#     CI, per the issue's own root-cause note) so this reproduces the bug
#     deterministically on ANY platform: a real repo lives at 31-real/,
#     reached ALSO via a sibling symlink 31-link -> 31-real, and the
#     committed-file path is built THROUGH the symlink (LOGICAL) while the
#     validator — invoked from inside the symlinked tree — resolves its own
#     script/repo root PHYSICALLY (`cd -P`), landing on 31-real. Pre-fix,
#     that prefix mismatch skips the git-tracked check entirely (no
#     COMMITTED-NOT-TRACKED emitted even though the file is genuinely
#     untracked); post-fix it fires, exactly like case 19.
#
#     The fixture ceiling deliberately sits at
#     workflows/scripts/model-comparison/untracked-allowlist.txt — inside
#     the repo tree, NOT under .temperloop/ — so the unrelated
#     COMMITTED-LOCATION check (validator's check 1, "must never live under
#     the gitignored .temperloop/ runtime dir") stays silent and
#     COMMITTED-NOT-TRACKED is the sole discriminator both assertions below
#     key on. A ceiling under .temperloop/ would make `vrc -ne 0` pass on
#     BOTH the fixed and unfixed validator (COMMITTED-LOCATION alone is
#     enough), silently defeating the first assertion.
# ---------------------------------------------------------------------------
count
SYM_REAL="$WORK/31-real"
mkdir -p "$SYM_REAL/workflows/scripts/model-comparison"
cp "$ALLOWLIST_SH" "$SYM_REAL/workflows/scripts/model-comparison/allowlist.sh"
cp "$VALIDATOR" "$SYM_REAL/workflows/scripts/validate-provider-disclosure.sh"
# `git init` + `git add` only, deliberately no `git commit` here: the
# assertion below reads `git ls-files` (the INDEX), which `add` alone
# already populates, so a commit contributes nothing to what this fixture
# checks. Committing would also require neutralizing every possible
# inherited git config (author identity, GPG signing, hooks, …) rather
# than just the two `-c user.*` flags this used to pass — a global
# `commit.gpgsign=true` reproducibly aborts a bare `git commit` with no
# `FAIL:` message, killing the whole `set -euo pipefail` suite at case 31.
# Every other non-bare fixture repo in this suite already stops at
# `git add -A` (see test_validate_feature_docs.sh, test_validate_design_brief.sh).
( cd "$SYM_REAL" && git init -q && git add workflows ) \
  || fail "31: fixture setup: could not scaffold the symlinked git repo"
ln -s 31-real "$WORK/31-link"
c31="$WORK/31-link/workflows/scripts/model-comparison/untracked-allowlist.txt"
printf 'anthropic\n' >"$c31"
vrc=0
vout="$(env PROVIDER_ALLOWLIST_TEST_SEAM=1 \
  PROVIDER_ALLOWLIST_COMMITTED_FILE="$c31" \
  PROVIDER_ALLOWLIST_LOCAL_FILE="$WORK/31-local.txt" \
  PROVIDER_DISCLOSURE_LOG_FILE="$WORK/31-log.jsonl" \
  bash "$WORK/31-link/workflows/scripts/validate-provider-disclosure.sh" 2>&1)" || vrc=$?
[[ "$vrc" -ne 0 ]] || fail "31: validator should FAIL on an in-repo but untracked ceiling reached through a symlinked ancestor:
$vout"
case "$vout" in *COMMITTED-NOT-TRACKED*) ;; *) fail "31: expected a COMMITTED-NOT-TRACKED line through a symlinked repo-root ancestor, got:
$vout" ;; esac
ok "31 validator: a symlinked ancestor between the script and its repo root does not skip the git-tracked check"

echo "---"
echo "$pass/$total tests passed"
[[ "$pass" -eq "$total" ]] || fail "only $pass of $total tests passed"
