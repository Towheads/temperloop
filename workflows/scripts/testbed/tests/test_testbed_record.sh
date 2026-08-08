#!/usr/bin/env bash
#
# Tests for workflows/scripts/testbed/record.sh — the machine-scoped testbed
# artifact record (temperloop#1117 Produces 4, temperloop#1227).
#
# Covers:
#   1. testbed_record_add on a fresh key -> artifacts.repo_created=true,
#      mirror_pushed=false, issues_copied=false; source-provenance fields
#      round-trip; entry is keyed under the TESTBED's own owner/name
#   2. testbed_record_mark_step flips mirror_pushed / issues_copied true,
#      independently, without disturbing the other flags
#   3. testbed_record_mark_step is idempotent (re-marking an already-true
#      step succeeds and leaves exactly one entry unchanged otherwise)
#   4. A second testbed_record_add at the SAME key appends a second LIST
#      entry rather than clobbering the first — the first entry's id, and
#      its artifact state, survive untouched (the "second testbed from the
#      same checkout does not orphan the first one's teardown reference"
#      acceptance criterion)
#   5. testbed_record_remove deletes exactly the matching id and leaves
#      siblings at the same key intact; removing the last entry at a key
#      drops the key itself; removing an absent id is a harmless no-op
#   6. Read-compat: a KNOWN schema_version (1) reads cleanly; an UNKNOWN
#      schema_version (99) is refused legibly, naming the version found —
#      exactly manifest.sh:196-224's contract
#   7. testbed_record_get / testbed_record_list report absent/empty for an
#      unrecorded key or id, never inferred or namespace-matched
#   8. materialize-from-seed round trip: source_repo recorded as JSON null,
#      promotable recorded false
#   9. Validation: malformed owner/name, unknown source_kind, and unknown
#      step are all rejected (non-zero, no entry written)
#  10. This is a SEPARATE file from install-manifest.json — writing a
#      testbed record does not create or touch install-manifest.json
#
# No network. Every test uses a throwaway HOME/XDG_STATE_HOME so nothing
# touches the real machine state.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
RECORD_SH="${REPO_ROOT}/workflows/scripts/testbed/record.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-testbed-record-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# run_in_fixture <fake-home> <shell-body> — sources record.sh with
# HOME/XDG_STATE_HOME pointed at a throwaway dir, then evals <shell-body>.
run_in_fixture() {
  local fake_home="$1" body="$2"
  (
    export HOME="$fake_home"
    export XDG_STATE_HOME="${fake_home}/.local/state"
    # shellcheck source=/dev/null
    source "$RECORD_SH"
    eval "$body"
  )
}

# ---------------------------------------------------------------------------
# Test 1: add on a fresh key -> repo_created=true, others false, provenance
# fields round-trip, keyed under the testbed's OWN owner/name
# ---------------------------------------------------------------------------
H1="${TMP}/home1"
mkdir -p "$H1"

id1="$(run_in_fixture "$H1" '
  testbed_record_add "me/my-testbed" "mirror-from-repo" "me/my-real-repo" true
')"
[[ -n "$id1" ]] || fail "1: testbed_record_add should print a non-empty id"

entry1="$(run_in_fixture "$H1" 'testbed_record_get "me/my-testbed" "'"$id1"'"')"
[[ "$(jq -r '.testbed_repo' <<<"$entry1")" == "me/my-testbed" ]] || fail "1: testbed_repo should round-trip"
[[ "$(jq -r '.source_kind' <<<"$entry1")" == "mirror-from-repo" ]] || fail "1: source_kind should round-trip"
[[ "$(jq -r '.source_repo' <<<"$entry1")" == "me/my-real-repo" ]] || fail "1: source_repo should round-trip"
[[ "$(jq -r '.promotable' <<<"$entry1")" == "true" ]] || fail "1: promotable should round-trip"
[[ "$(jq -r '.artifacts.repo_created' <<<"$entry1")" == "true" ]] || fail "1: repo_created should be true at creation"
[[ "$(jq -r '.artifacts.mirror_pushed' <<<"$entry1")" == "false" ]] || fail "1: mirror_pushed should start false"
[[ "$(jq -r '.artifacts.issues_copied' <<<"$entry1")" == "false" ]] || fail "1: issues_copied should start false"
[[ -n "$(jq -r '.created_at' <<<"$entry1")" ]] || fail "1: created_at should be set"

list1="$(run_in_fixture "$H1" 'testbed_record_list "me/my-testbed"')"
[[ "$(jq 'length' <<<"$list1")" == "1" ]] || fail "1: list should contain exactly 1 entry"

pass "1: testbed_record_add records repo_created=true and round-trips all provenance fields, keyed under the testbed's own owner/name"

# ---------------------------------------------------------------------------
# Test 2: mark_step flips mirror_pushed / issues_copied independently
# ---------------------------------------------------------------------------
H2="${TMP}/home2"
mkdir -p "$H2"
id2="$(run_in_fixture "$H2" '
  testbed_record_add "me/testbed-2" "mirror-from-repo" "me/real-2" true
')"

out2a="$(run_in_fixture "$H2" 'testbed_record_mark_step "me/testbed-2" "'"$id2"'" mirror_pushed')"
grep -q 'mirror_pushed recorded' <<<"$out2a" || fail "2: expected a mirror_pushed-recorded status line (got: $out2a)"

entry2a="$(run_in_fixture "$H2" 'testbed_record_get "me/testbed-2" "'"$id2"'"')"
[[ "$(jq -r '.artifacts.mirror_pushed' <<<"$entry2a")" == "true" ]] || fail "2: mirror_pushed should be true after marking"
[[ "$(jq -r '.artifacts.issues_copied' <<<"$entry2a")" == "false" ]] || fail "2: issues_copied should still be false"

run_in_fixture "$H2" 'testbed_record_mark_step "me/testbed-2" "'"$id2"'" issues_copied' >/dev/null
entry2b="$(run_in_fixture "$H2" 'testbed_record_get "me/testbed-2" "'"$id2"'"')"
[[ "$(jq -r '.artifacts.issues_copied' <<<"$entry2b")" == "true" ]] || fail "2: issues_copied should be true after marking"
[[ "$(jq -r '.artifacts.mirror_pushed' <<<"$entry2b")" == "true" ]] || fail "2: mirror_pushed should remain true"
[[ "$(jq -r '.artifacts.repo_created' <<<"$entry2b")" == "true" ]] || fail "2: repo_created should remain true throughout"

pass "2: testbed_record_mark_step flips mirror_pushed and issues_copied independently, atomically, without disturbing sibling flags"

# ---------------------------------------------------------------------------
# Test 3: mark_step is idempotent
# ---------------------------------------------------------------------------
H3="${TMP}/home3"
mkdir -p "$H3"
id3="$(run_in_fixture "$H3" '
  testbed_record_add "me/testbed-3" "mirror-from-repo" "me/real-3" true
')"
run_in_fixture "$H3" 'testbed_record_mark_step "me/testbed-3" "'"$id3"'" mirror_pushed' >/dev/null
out3="$(run_in_fixture "$H3" 'testbed_record_mark_step "me/testbed-3" "'"$id3"'" mirror_pushed' 2>&1)" && rc3=0 || rc3=$?
[[ "$rc3" -eq 0 ]] || fail "3: re-marking an already-true step should succeed (rc=$rc3)"

count3="$(run_in_fixture "$H3" 'testbed_record_list "me/testbed-3" | jq length')"
[[ "$count3" == "1" ]] || fail "3: re-marking must not create a duplicate entry, got count=$count3"

pass "3: testbed_record_mark_step is idempotent — re-marking an already-true step succeeds with no duplicate entry"

# ---------------------------------------------------------------------------
# Test 4: a second add at the SAME key appends, never clobbers — the first
# entry's id and artifact state survive untouched
# ---------------------------------------------------------------------------
H4="${TMP}/home4"
mkdir -p "$H4"
id4a="$(run_in_fixture "$H4" '
  testbed_record_add "me/shared-key" "mirror-from-repo" "me/real-a" true
')"
run_in_fixture "$H4" 'testbed_record_mark_step "me/shared-key" "'"$id4a"'" mirror_pushed' >/dev/null
run_in_fixture "$H4" 'testbed_record_mark_step "me/shared-key" "'"$id4a"'" issues_copied' >/dev/null

id4b="$(run_in_fixture "$H4" '
  testbed_record_add "me/shared-key" "mirror-from-repo" "me/real-b" false
')"
[[ "$id4a" != "$id4b" ]] || fail "4: two adds at the same key must produce distinct ids"

list4="$(run_in_fixture "$H4" 'testbed_record_list "me/shared-key"')"
[[ "$(jq 'length' <<<"$list4")" == "2" ]] || fail "4: list at the shared key should now contain exactly 2 entries"

entry4a="$(run_in_fixture "$H4" 'testbed_record_get "me/shared-key" "'"$id4a"'"')"
[[ "$(jq -r '.source_repo' <<<"$entry4a")" == "me/real-a" ]] || fail "4: the FIRST entry's fields must survive the second add untouched"
[[ "$(jq -r '.artifacts.mirror_pushed' <<<"$entry4a")" == "true" ]] || fail "4: the first entry's mirror_pushed flag must survive the second add"
[[ "$(jq -r '.artifacts.issues_copied' <<<"$entry4a")" == "true" ]] || fail "4: the first entry's issues_copied flag must survive the second add"

entry4b="$(run_in_fixture "$H4" 'testbed_record_get "me/shared-key" "'"$id4b"'"')"
[[ "$(jq -r '.source_repo' <<<"$entry4b")" == "me/real-b" ]] || fail "4: the second entry should carry its own distinct fields"
[[ "$(jq -r '.promotable' <<<"$entry4b")" == "false" ]] || fail "4: the second entry's promotable should round-trip false"

pass "4: a second testbed_record_add at the same key appends a second list entry — the first entry's id and artifact state are never orphaned or clobbered"

# ---------------------------------------------------------------------------
# Test 5: remove deletes exactly the matching id; last-removal drops the
# key; removing an absent id is a no-op
# ---------------------------------------------------------------------------
H5="${TMP}/home5"
mkdir -p "$H5"
id5a="$(run_in_fixture "$H5" 'testbed_record_add "me/rm-key" "mirror-from-repo" "me/real" true')"
id5b="$(run_in_fixture "$H5" 'testbed_record_add "me/rm-key" "mirror-from-repo" "me/real" true')"

run_in_fixture "$H5" 'testbed_record_remove "me/rm-key" "'"$id5a"'"' >/dev/null
list5a="$(run_in_fixture "$H5" 'testbed_record_list "me/rm-key"')"
[[ "$(jq 'length' <<<"$list5a")" == "1" ]] || fail "5: removing one entry should leave exactly 1 sibling"
[[ "$(jq -r '.[0].id' <<<"$list5a")" == "$id5b" ]] || fail "5: the surviving entry should be the one NOT removed"

run_in_fixture "$H5" 'testbed_record_remove "me/rm-key" "'"$id5b"'"' >/dev/null
list5b="$(run_in_fixture "$H5" 'testbed_record_all')"
jq -e '.["me/rm-key"] == null' <<<"$list5b" >/dev/null || fail "5: removing the last entry at a key should drop the key entirely"

out5c="$(run_in_fixture "$H5" 'testbed_record_remove "me/rm-key" "nonexistent-id"' 2>&1)" && rc5c=0 || rc5c=$?
[[ "$rc5c" -eq 0 ]] || fail "5: removing an absent id should be a harmless no-op (rc=$rc5c)"

pass "5: testbed_record_remove deletes exactly the matching entry, drops an emptied key, and no-ops on an absent id"

# ---------------------------------------------------------------------------
# Test 6: read-compat — a known schema_version reads; an unknown one refuses
# legibly, naming the version found
# ---------------------------------------------------------------------------
H6="${TMP}/home6"
mkdir -p "${H6}/.local/state/temperloop"
record6="${H6}/.local/state/temperloop/testbed-record.json"

printf '{"schema_version":1,"testbeds":{}}' >"$record6"
out6a="$(run_in_fixture "$H6" 'testbed_record_load' 2>&1)" && rc6a=0 || rc6a=$?
[[ "$rc6a" -eq 0 ]] || fail "6: a known schema_version (1) should read successfully (rc=$rc6a, out=$out6a)"
echo "$out6a" | jq -e '.schema_version == 1' >/dev/null || fail "6: schema_version should round-trip as 1"

printf '{"schema_version":99,"testbeds":{}}' >"$record6"
out6b="$(run_in_fixture "$H6" 'testbed_record_load' 2>&1)" && rc6b=0 || rc6b=$?
[[ "$rc6b" -ne 0 ]] || fail "6: an unknown schema_version (99) must be refused (nonzero rc)"
grep -q 'schema_version=99' <<<"$out6b" || fail "6: refusal must name the exact version found (got: $out6b)"
grep -q 'readable' <<<"$out6b" || fail "6: refusal must name what this build CAN read (got: $out6b)"

pass "6: testbed_record_load reads a known schema_version and refuses an unknown one, naming the version found"

# ---------------------------------------------------------------------------
# Test 7: absent key/id are invisible, never inferred
# ---------------------------------------------------------------------------
H7="${TMP}/home7"
mkdir -p "$H7"
run_in_fixture "$H7" 'testbed_record_add "me/real-key" "mirror-from-repo" "me/real" true' >/dev/null

out7="$(run_in_fixture "$H7" '
  testbed_record_list "me/never-created" | jq "length"
  testbed_record_get "me/real-key" "nonexistent-id" >/dev/null 2>&1 && echo "FOUND" || echo "NOT-FOUND"
')"
[[ "$(echo "$out7" | sed -n 1p)" == "0" ]] || fail "7: an unrecorded key should list as empty (length 0)"
[[ "$(echo "$out7" | sed -n 2p)" == "NOT-FOUND" ]] || fail "7: an absent id at a real key should not be found"

pass "7: testbed_record_list / testbed_record_get report absent/empty for an unrecorded key or id"

# ---------------------------------------------------------------------------
# Test 8: materialize-from-seed round trip — source_repo null, promotable
# false
# ---------------------------------------------------------------------------
H8="${TMP}/home8"
mkdir -p "$H8"
id8="$(run_in_fixture "$H8" '
  testbed_record_add "me/seeded-testbed" "materialize-from-seed" "" false
')"
entry8="$(run_in_fixture "$H8" 'testbed_record_get "me/seeded-testbed" "'"$id8"'"')"
[[ "$(jq -r '.source_kind' <<<"$entry8")" == "materialize-from-seed" ]] || fail "8: source_kind should round-trip"
[[ "$(jq '.source_repo' <<<"$entry8")" == "null" ]] || fail "8: source_repo should be JSON null for materialize-from-seed"
[[ "$(jq -r '.promotable' <<<"$entry8")" == "false" ]] || fail "8: promotable should round-trip false"

pass "8: a materialize-from-seed entry records source_repo=null and promotable=false"

# ---------------------------------------------------------------------------
# Test 9: validation rejects malformed input, writes nothing
# ---------------------------------------------------------------------------
H9="${TMP}/home9"
mkdir -p "$H9"

out9a="$(run_in_fixture "$H9" 'testbed_record_add "not-owner-slash-name" "mirror-from-repo" "" true' 2>&1)" && rc9a=0 || rc9a=$?
[[ "$rc9a" -ne 0 ]] || fail "9: a malformed owner/name (no slash) should be rejected"

out9b="$(run_in_fixture "$H9" 'testbed_record_add "me/ok" "not-a-real-source-kind" "" true' 2>&1)" && rc9b=0 || rc9b=$?
[[ "$rc9b" -ne 0 ]] || fail "9: an unknown source_kind should be rejected"

id9c="$(run_in_fixture "$H9" 'testbed_record_add "me/ok2" "mirror-from-repo" "me/real" true')"
out9c="$(run_in_fixture "$H9" 'testbed_record_mark_step "me/ok2" "'"$id9c"'" not_a_real_step' 2>&1)" && rc9c=0 || rc9c=$?
[[ "$rc9c" -ne 0 ]] || fail "9: an unknown step name should be rejected"

flat9="$(run_in_fixture "$H9" 'testbed_record_flat')"
[[ "$(jq 'length' <<<"$flat9")" == "1" ]] || fail "9: only the ONE valid add (id9c) should have produced a recorded entry, got: $flat9"

pass "9: testbed_record_add / testbed_record_mark_step reject malformed owner/name, unknown source_kind, and unknown step, writing nothing"

# ---------------------------------------------------------------------------
# Test 10: this is a SEPARATE file from install-manifest.json
# ---------------------------------------------------------------------------
H10="${TMP}/home10"
mkdir -p "$H10"
run_in_fixture "$H10" 'testbed_record_add "me/isolation-check" "mirror-from-repo" "me/real" true' >/dev/null

install_manifest10="${H10}/.local/state/temperloop/install-manifest.json"
[[ ! -e "$install_manifest10" ]] || fail "10: writing a testbed record must never create/touch install-manifest.json"

testbed_record10="${H10}/.local/state/temperloop/testbed-record.json"
[[ -f "$testbed_record10" ]] || fail "10: sanity — the testbed record file itself should exist"
[[ "$(basename "$testbed_record10")" == "testbed-record.json" ]] || fail "10: sanity — filename should be testbed-record.json, distinct from install-manifest.json"

pass "10: testbed-record.json is a separate file from install-manifest.json — writing one never touches the other"

# ---------------------------------------------------------------------------
echo
echo "PASS: all testbed-record tests passed"
