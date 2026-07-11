#!/usr/bin/env bash
#
# Tests for workflows/scripts/install/manifest.sh — the machine-surface
# install manifest library (temperloop#261, ADR K164 D7).
#
# Covers:
#   1. manifest_backup_and_record on an ABSENT path -> state=created,
#      backup_path=null, no backup file written
#   2. manifest_backup_and_record on a PREEXISTING path -> state=preexisting,
#      explicit backup_path recorded, original content copied there verbatim
#   3. manifest_restore_from_record on a "created" entry -> path removed,
#      entry removed
#   4. manifest_restore_from_record on a "preexisting" entry -> original
#      content restored from the recorded backup_path, backup file removed,
#      entry removed
#   5. Re-install convergence: calling manifest_backup_and_record twice on
#      the same path is idempotent (no duplicate entry, no second backup,
#      no clobber of the recorded backup_path)
#   6. Read-compat: a KNOWN schema_version (1) reads cleanly; an UNKNOWN
#      schema_version (99) is refused legibly, naming the version found
#   7. A path with no manifest entry is invisible: manifest_get_path_entry
#      / manifest_has_path report absent, and manifest_restore_from_record
#      is a strict no-op (never touches the path)
#   8. Marker-stamp helper: manifest_marker_line embeds a detectable tag;
#      manifest_has_marker is true only when the tag is present
#   9. manifest_restore_from_record on a "preexisting" entry whose backup
#      file is missing refuses (non-zero) rather than deleting the path
#
# No network. Every test uses a throwaway HOME/XDG_STATE_HOME so nothing
# touches the real machine state.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MANIFEST_SH="${REPO_ROOT}/workflows/scripts/install/manifest.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-install-manifest-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# run_in_fixture <fake-home> <shell-body> — sources manifest.sh with
# HOME/XDG_STATE_HOME pointed at a throwaway dir, then evals <shell-body>.
run_in_fixture() {
  local fake_home="$1" body="$2"
  (
    export HOME="$fake_home"
    export XDG_STATE_HOME="${fake_home}/.local/state"
    # shellcheck source=/dev/null
    source "$MANIFEST_SH"
    eval "$body"
  )
}

# ---------------------------------------------------------------------------
# Test 1: backup_and_record on an ABSENT path -> created, backup_path=null
# ---------------------------------------------------------------------------
H1="${TMP}/home1"
mkdir -p "$H1"
target1="${H1}/newfile.txt"

out1="$(run_in_fixture "$H1" '
  manifest_backup_and_record "'"$target1"'"
  manifest_get_path_entry "'"$target1"'"
')"

echo "$out1" | grep -q 'recorded (created)' || fail "1: expected a created-recorded status line (got: $out1)"
entry1_state="$(echo "$out1" | tail -n1 | jq -r '.state')"
entry1_backup="$(echo "$out1" | tail -n1 | jq -r '.backup_path')"
[[ "$entry1_state" == "created" ]] || fail "1: expected state=created, got $entry1_state"
[[ "$entry1_backup" == "null" ]] || fail "1: expected backup_path=null, got $entry1_backup"

backups_dir1="${H1}/.local/state/temperloop/backups"
[[ ! -e "${backups_dir1}${target1}" ]] || fail "1: no backup file should exist for a created (not preexisting) path"

pass "1: backup_and_record on an absent path records state=created with backup_path=null and writes no backup"

# ---------------------------------------------------------------------------
# Test 2: backup_and_record on a PREEXISTING path -> preexisting, explicit
# backup_path, content copied verbatim
# ---------------------------------------------------------------------------
H2="${TMP}/home2"
mkdir -p "$H2"
target2="${H2}/.zshrc"
printf 'original content\n' >"$target2"

out2="$(run_in_fixture "$H2" '
  manifest_backup_and_record "'"$target2"'"
  manifest_get_path_entry "'"$target2"'"
')"

echo "$out2" | grep -q 'backed up to' || fail "2: expected a backed-up status line (got: $out2)"
entry2="$(echo "$out2" | tail -n1)"
entry2_state="$(echo "$entry2" | jq -r '.state')"
entry2_backup="$(echo "$entry2" | jq -r '.backup_path')"
[[ "$entry2_state" == "preexisting" ]] || fail "2: expected state=preexisting, got $entry2_state"
[[ "$entry2_backup" != "null" && -n "$entry2_backup" ]] || fail "2: expected a non-null backup_path"
[[ -f "$entry2_backup" ]] || fail "2: recorded backup_path should exist on disk: $entry2_backup"
[[ "$(cat "$entry2_backup")" == "original content" ]] || fail "2: backup content should match the original verbatim"

# Now simulate install overwriting the live path (the caller's job, not the lib's).
printf 'new managed content\n' >"$target2"
[[ "$(cat "$target2")" == "new managed content" ]] || fail "2: sanity — overwrite should have landed"

pass "2: backup_and_record on a preexisting path records state=preexisting with an explicit backup_path holding the original content"

# ---------------------------------------------------------------------------
# Test 3: restore_from_record on a "created" entry -> path removed, entry gone
# ---------------------------------------------------------------------------
H3="${TMP}/home3"
mkdir -p "$H3"
target3="${H3}/created-by-install.txt"

run_in_fixture "$H3" '
  manifest_backup_and_record "'"$target3"'"
' >/dev/null
printf 'installed content\n' >"$target3"   # caller writes the actual file after recording

out3="$(run_in_fixture "$H3" '
  manifest_restore_from_record "'"$target3"'"
  echo "---"
  manifest_has_path "'"$target3"'" && echo "STILL-RECORDED" || echo "NOT-RECORDED"
')"

echo "$out3" | grep -q 'removed (was created by install)' || fail "3: expected a removed status line (got: $out3)"
[[ ! -e "$target3" ]] || fail "3: path should be removed after restoring a created entry"
echo "$out3" | grep -q 'NOT-RECORDED' || fail "3: entry should be removed from the manifest after restore"

pass "3: restore_from_record on a created entry removes the path and its manifest entry"

# ---------------------------------------------------------------------------
# Test 4: restore_from_record on a "preexisting" entry -> original restored,
# backup file removed, entry gone
# ---------------------------------------------------------------------------
H4="${TMP}/home4"
mkdir -p "$H4"
target4="${H4}/.gitconfig"
printf 'operator original\n' >"$target4"

run_in_fixture "$H4" '
  manifest_backup_and_record "'"$target4"'"
' >/dev/null
printf 'installed replacement\n' >"$target4"

backup4="$(run_in_fixture "$H4" 'manifest_get_path_entry "'"$target4"'" | jq -r ".backup_path"')"
[[ -f "$backup4" ]] || fail "4: sanity — backup file should exist before restore"

out4="$(run_in_fixture "$H4" '
  manifest_restore_from_record "'"$target4"'"
  echo "---"
  manifest_has_path "'"$target4"'" && echo "STILL-RECORDED" || echo "NOT-RECORDED"
')"

echo "$out4" | grep -q 'restored from backup' || fail "4: expected a restored status line (got: $out4)"
[[ "$(cat "$target4")" == "operator original" ]] || fail "4: original content should be restored"
[[ ! -e "$backup4" ]] || fail "4: backup file should be removed after a successful restore"
echo "$out4" | grep -q 'NOT-RECORDED' || fail "4: entry should be removed from the manifest after restore"

pass "4: restore_from_record on a preexisting entry restores the original content, removes the backup file, and un-records the entry"

# ---------------------------------------------------------------------------
# Test 5: re-install convergence — calling backup_and_record twice is
# idempotent: no duplicate entry, no second backup, backup_path unchanged
# ---------------------------------------------------------------------------
H5="${TMP}/home5"
mkdir -p "$H5"
target5="${H5}/.bashrc"
printf 'first original\n' >"$target5"

run_in_fixture "$H5" 'manifest_backup_and_record "'"$target5"'"' >/dev/null
backup5_first="$(run_in_fixture "$H5" 'manifest_get_path_entry "'"$target5"'" | jq -r ".backup_path"')"

# Simulate install writing managed content, then a SECOND install run
# re-recording the same path (the convergence case).
printf 'managed content v1\n' >"$target5"
out5b="$(run_in_fixture "$H5" 'manifest_backup_and_record "'"$target5"'"')"
echo "$out5b" | grep -q 'already recorded' || fail "5: second record should report already-recorded (got: $out5b)"

backup5_second="$(run_in_fixture "$H5" 'manifest_get_path_entry "'"$target5"'" | jq -r ".backup_path"')"
[[ "$backup5_first" == "$backup5_second" ]] || fail "5: backup_path must not change on a re-record"
[[ "$(cat "$backup5_first")" == "first original" ]] || fail "5: the ORIGINAL preexisting backup must not be clobbered by the second run's managed content"

paths_count5="$(run_in_fixture "$H5" 'manifest_load | jq "[.paths | keys[]] | map(select(. == \"'"$target5"'\")) | length"')"
[[ "$paths_count5" == "1" ]] || fail "5: expected exactly 1 entry for the re-recorded path, got $paths_count5"

pass "5: re-recording an already-recorded path converges (no duplicate entry, no spurious re-backup, backup_path preserved)"

# ---------------------------------------------------------------------------
# Test 6: read-compat — a known schema_version reads; an unknown one refuses
# legibly, naming the version found
# ---------------------------------------------------------------------------
H6="${TMP}/home6"
mkdir -p "${H6}/.local/state/temperloop"
manifest6="${H6}/.local/state/temperloop/install-manifest.json"

# Known version (1): reads cleanly.
printf '{"schema_version":1,"paths":{}}' >"$manifest6"
out6a="$(run_in_fixture "$H6" 'manifest_load' 2>&1)" && rc6a=0 || rc6a=$?
[[ "$rc6a" -eq 0 ]] || fail "6: a known schema_version (1) should read successfully (rc=$rc6a, out=$out6a)"
echo "$out6a" | jq -e '.schema_version == 1' >/dev/null || fail "6: schema_version should round-trip as 1"

# Unknown/future version (99): refuses legibly, naming the version found.
printf '{"schema_version":99,"paths":{}}' >"$manifest6"
out6b="$(run_in_fixture "$H6" 'manifest_load' 2>&1)" && rc6b=0 || rc6b=$?
[[ "$rc6b" -ne 0 ]] || fail "6: an unknown schema_version (99) must be refused (nonzero rc)"
echo "$out6b" | grep -q 'schema_version=99' || fail "6: refusal must name the exact version found (got: $out6b)"
echo "$out6b" | grep -q 'readable' || fail "6: refusal must name what this build CAN read (got: $out6b)"

pass "6: manifest_load reads a known schema_version and refuses an unknown one, naming the version found"

# ---------------------------------------------------------------------------
# Test 7: paths absent from the manifest are invisible to every reader
# ---------------------------------------------------------------------------
H7="${TMP}/home7"
mkdir -p "$H7"
unknown7="${H7}/never-touched-by-install.txt"
printf 'operator file, never recorded\n' >"$unknown7"

out7="$(run_in_fixture "$H7" '
  manifest_has_path "'"$unknown7"'" && echo "HAS" || echo "ABSENT"
  manifest_get_path_entry "'"$unknown7"'" >/dev/null 2>&1 && echo "ENTRY-FOUND" || echo "ENTRY-NOT-FOUND"
  manifest_restore_from_record "'"$unknown7"'"
')"

echo "$out7" | grep -q '^ABSENT$' || fail "7: manifest_has_path should report ABSENT for an unrecorded path"
echo "$out7" | grep -q '^ENTRY-NOT-FOUND$' || fail "7: manifest_get_path_entry should find nothing for an unrecorded path"
echo "$out7" | grep -q 'no manifest record' || fail "7: restore_from_record should report a no-op for an unrecorded path"
[[ -f "$unknown7" ]] || fail "7: an unrecorded path must NEVER be touched by restore_from_record"
[[ "$(cat "$unknown7")" == "operator file, never recorded" ]] || fail "7: an unrecorded path's content must be untouched"

pass "7: a path with no manifest entry is invisible to has_path/get_path_entry and is never touched by restore_from_record"

# ---------------------------------------------------------------------------
# Test 8: marker-stamp helper
# ---------------------------------------------------------------------------
H8="${TMP}/home8"
mkdir -p "$H8"
marked8="${H8}/generated-settings.json"
unmarked8="${H8}/plain-file.json"

run_in_fixture "$H8" '
  { manifest_marker_line; echo "{\"a\":1}"; } > "'"$marked8"'"
  echo "{\"a\":1}" > "'"$unmarked8"'"
'
marker_line="$(run_in_fixture "$H8" 'manifest_marker_line')"
echo "$marker_line" | grep -q 'temperloop-managed' || fail "8: marker_line should contain the marker tag"

out8="$(run_in_fixture "$H8" '
  manifest_has_marker "'"$marked8"'" && echo "MARKED" || echo "NOT-MARKED"
  manifest_has_marker "'"$unmarked8"'" && echo "MARKED" || echo "NOT-MARKED"
')"
[[ "$(echo "$out8" | sed -n 1p)" == "MARKED" ]] || fail "8: a file with the marker line should report MARKED"
[[ "$(echo "$out8" | sed -n 2p)" == "NOT-MARKED" ]] || fail "8: a file without the marker line should report NOT-MARKED"

# Alternate comment prefix.
alt_marker="$(run_in_fixture "$H8" 'manifest_marker_line "//"')"
echo "$alt_marker" | grep -q '^// temperloop-managed' || fail "8: an alternate comment prefix should be honored"

pass "8: manifest_marker_line embeds a detectable tag and manifest_has_marker correctly distinguishes marked/unmarked files"

# ---------------------------------------------------------------------------
# Test 9: restore_from_record refuses (non-zero) when a "preexisting"
# entry's backup file is missing, rather than deleting the live path
# ---------------------------------------------------------------------------
H9="${TMP}/home9"
mkdir -p "$H9"
target9="${H9}/.tool-config"
printf 'original\n' >"$target9"

run_in_fixture "$H9" 'manifest_backup_and_record "'"$target9"'"' >/dev/null
backup9="$(run_in_fixture "$H9" 'manifest_get_path_entry "'"$target9"'" | jq -r ".backup_path"')"
rm -f "$backup9"   # simulate a corrupted/lost backup

printf 'still-live-content\n' >"$target9"
out9="$(run_in_fixture "$H9" 'manifest_restore_from_record "'"$target9"'"' 2>&1)" && rc9=0 || rc9=$?

[[ "$rc9" -ne 0 ]] || fail "9: restore should fail when the recorded backup is missing"
echo "$out9" | grep -q 'refusing to touch' || fail "9: failure message should explain the refusal (got: $out9)"
[[ -f "$target9" ]] || fail "9: the live path must be left untouched when the backup is missing"
[[ "$(cat "$target9")" == "still-live-content" ]] || fail "9: the live path's content must be untouched"

pass "9: restore_from_record refuses to delete a live path when its recorded backup is missing, instead of proceeding destructively"

# ---------------------------------------------------------------------------
echo
echo "PASS: all install-manifest tests passed"
