#!/usr/bin/env bash
#
# Tests for workflows/scripts/install/links.sh (enumeration) and
# workflows/scripts/install/doctor.sh (classification).
#
# Covers:
#   1. links_enumerate emits at least one record per category
#      (env dotfile, claude entry, board command, gh-shim)
#   2. links_enumerate output is tab-delimited with exactly 3 fields per line
#   3. settings.json is emitted as kind=real (the #292 exception)
#   4. All 6 board commands are enumerated
#   5. doctor classifies MISSING, DRIFT, SHADOWED, DANGLING correctly
#      against a controlled fixture HOME, then exits non-zero
#   6. doctor exits 0 when every entry is OK
#
# No network, no real HOME mutations — every classify test uses a throwaway
# tmpdir as a fake HOME + fake FOUNDATION.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
LINKS_SH="${REPO_ROOT}/workflows/scripts/install/links.sh"
DOCTOR_SH="${REPO_ROOT}/workflows/scripts/install/doctor.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-install-links-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# ---------------------------------------------------------------------------
# Build a minimal fake FOUNDATION tree so links_enumerate produces predictable
# output without touching the real HOME.
# ---------------------------------------------------------------------------
FAKE_FOUND="${TMP}/foundation"
mkdir -p \
  "${FAKE_FOUND}/env" \
  "${FAKE_FOUND}/claude" \
  "${FAKE_FOUND}/workflows/scripts/board"

# env/ dotfiles (3 fake ones)
touch "${FAKE_FOUND}/env/.bashrc"
touch "${FAKE_FOUND}/env/.zshrc"
touch "${FAKE_FOUND}/env/.gitconfig"

# claude/ entries: settings.json (real-file kind) + 4 dir/file entries +
# CLAUDE.kernel.md/CLAUDE.overlay.md (compose sources for the generated
# CLAUDE.md, kind=claude-md — see links.sh § 2b)
touch "${FAKE_FOUND}/claude/settings.json"
mkdir -p \
  "${FAKE_FOUND}/claude/commands" \
  "${FAKE_FOUND}/claude/hooks" \
  "${FAKE_FOUND}/claude/workflows" \
  "${FAKE_FOUND}/claude/agents"
touch "${FAKE_FOUND}/claude/CLAUDE.kernel.md"
touch "${FAKE_FOUND}/claude/CLAUDE.overlay.md"

# board commands: create stub scripts
for cmd in claim release worklist reconcile capture milestone; do
  touch "${FAKE_FOUND}/workflows/scripts/board/${cmd}.sh"
done

# ---------------------------------------------------------------------------
# Helper: enumerate with fake HOME injected into the expected paths so we can
# compare purely on structure (not real paths).
# ---------------------------------------------------------------------------
enumerate_with_fake() {
  local fake_home="$1"
  FOUNDATION="$FAKE_FOUND" HOME="$fake_home" bash -c '
    source "$FOUNDATION/../../../../../../'"${LINKS_SH}"'"
    # override HOME so target paths use fake home
    HOME="'"$fake_home"'"
    FOUNDATION="'"$FAKE_FOUND"'"
    links_enumerate
  ' 2>&1
}

# More reliable: source and call directly in a subshell.
run_enumerate() {
  local fake_home="$1"
  (
    export FOUNDATION="$FAKE_FOUND"
    export HOME="$fake_home"
    # shellcheck source=/dev/null
    source "$LINKS_SH"
    links_enumerate
  )
}

# ---------------------------------------------------------------------------
# Test 1: at least one record per category
# ---------------------------------------------------------------------------
FAKE_HOME="${TMP}/home1"
mkdir -p "$FAKE_HOME"
output="$(run_enumerate "$FAKE_HOME")"

# env dotfile
grep -q "${FAKE_HOME}/.bashrc" <<<"$output" || \
  fail "1: env dotfile .bashrc not enumerated"

# claude entry (a symlink kind)
grep -q "${FAKE_HOME}/.claude/commands" <<<"$output" || \
  fail "1: claude/commands not enumerated"

# settings.json as real kind
grep -q "real" <<<"$(grep 'settings.json' <<<"$output")" || \
  fail "1: settings.json not emitted as kind=real"

# composed CLAUDE.md as claude-md kind, empty expected_source, emitted once
claude_md_lines="$(grep -c "^${FAKE_HOME}/.claude/CLAUDE.md	" <<<"$output" || true)"
[[ "$claude_md_lines" -eq 1 ]] || \
  fail "1: expected exactly 1 CLAUDE.md record, got ${claude_md_lines}"
grep -q "^${FAKE_HOME}/.claude/CLAUDE.md	claude-md	\$" <<<"$output" || \
  fail "1: CLAUDE.md not emitted as kind=claude-md with empty expected_source"

# CLAUDE.kernel.md / CLAUDE.overlay.md are compose SOURCES, not deployed
# under their own names
if grep -q "CLAUDE.kernel.md" <<<"$output"; then
  fail "1: CLAUDE.kernel.md should not be separately enumerated as a deploy target"
fi
if grep -q "CLAUDE.overlay.md" <<<"$output"; then
  fail "1: CLAUDE.overlay.md should not be separately enumerated as a deploy target"
fi

# board command
grep -q "${FAKE_HOME}/.local/bin/claim" <<<"$output" || \
  fail "1: board command 'claim' not enumerated"

# gh-shim
grep -q "gh-shim" <<<"$output" || \
  fail "1: gh-shim not enumerated"

pass "1: all categories (env, claude, board, gh-shim) enumerated"

# ---------------------------------------------------------------------------
# Test 2: every line has exactly 3 tab-delimited fields
# ---------------------------------------------------------------------------
while IFS='' read -r line; do
  [[ -z "$line" ]] && continue
  nf="$(awk -F'\t' '{print NF}' <<<"$line")"
  [[ "$nf" -eq 3 ]] || fail "2: line has ${nf} fields (expected 3): ${line}"
done <<<"$output"

pass "2: all lines have exactly 3 tab-delimited fields"

# ---------------------------------------------------------------------------
# Test 3: settings.json emitted as real, no expected_source
# ---------------------------------------------------------------------------
settings_line="$(grep 'settings.json' <<<"$output")"
# Field order: target (f1)  kind (f2)  expected_source (f3, empty for real)
settings_kind="$(awk -F'\t' '{print $2}' <<<"$settings_line")"
settings_src="$(awk -F'\t' '{print $3}' <<<"$settings_line")"
[[ "$settings_kind" == "real" ]] || fail "3: settings.json kind='${settings_kind}' (expected 'real')"
[[ -z "$settings_src" ]] || fail "3: settings.json expected_source should be empty, got '${settings_src}'"

pass "3: settings.json emitted as kind=real with empty expected_source"

# ---------------------------------------------------------------------------
# Test 4: all 6 board commands enumerated
# ---------------------------------------------------------------------------
for cmd in claim release worklist reconcile capture milestone; do
  grep -q "${FAKE_HOME}/.local/bin/${cmd}" <<<"$output" || \
    fail "4: board command '${cmd}' not enumerated"
done

pass "4: all 6 board commands enumerated"

# ---------------------------------------------------------------------------
# Test 5: doctor classifies MISSING/DRIFT/SHADOWED/DANGLING correctly
#
# We build a controlled fake HOME + FOUNDATION, install specific "broken"
# conditions for chosen targets, then verify doctor reports the right status.
# ---------------------------------------------------------------------------

# --- Setup a complete fake installation first (all OK) ---
FAKE_HOME5="${TMP}/home5"
mkdir -p \
  "${FAKE_HOME5}/.claude" \
  "${FAKE_HOME5}/.local/bin"

FAKE_FOUND5="${TMP}/foundation5"
mkdir -p \
  "${FAKE_FOUND5}/env" \
  "${FAKE_FOUND5}/claude" \
  "${FAKE_FOUND5}/workflows/scripts/board"

# env dotfile: .zshrc
touch "${FAKE_FOUND5}/env/.zshrc"
# → initially MISSING: don't create the symlink

# claude entries: settings.json + CLAUDE.kernel.md/CLAUDE.overlay.md (compose
# sources for the generated CLAUDE.md, kind=claude-md) + a commands/ dir
# (kind=symlink, used below for the SHADOWED case)
touch "${FAKE_FOUND5}/claude/settings.json"
touch "${FAKE_FOUND5}/claude/CLAUDE.kernel.md"
touch "${FAKE_FOUND5}/claude/CLAUDE.overlay.md"
mkdir -p "${FAKE_FOUND5}/claude/commands"
touch "${FAKE_FOUND5}/claude/commands/build.md"

# board commands
for cmd in claim release worklist reconcile capture milestone; do
  touch "${FAKE_FOUND5}/workflows/scripts/board/${cmd}.sh"
done

# Now build OK state for everything EXCEPT the 4 test cases:

# settings.json → OK: real file present
echo '{"model":"test"}' >"${FAKE_HOME5}/.claude/settings.json"

# claude/commands → SHADOWED: a real directory where a symlink is expected
mkdir -p "${FAKE_HOME5}/.claude/commands"

# composed CLAUDE.md (kind=claude-md) → DRIFT: a real directory where the
# generated real FILE is expected (same "real"-like classification settings.json
# uses — kind=claude-md has no SHADOWED status, only OK/DRIFT/MISSING)
mkdir -p "${FAKE_HOME5}/.claude/CLAUDE.md"

# board command 'claim' → OK (correct symlink)
ln -s "${FAKE_FOUND5}/workflows/scripts/board/claim.sh" \
  "${FAKE_HOME5}/.local/bin/claim"

# board command 'release' → DRIFT (symlink to wrong target)
ln -s "/nonexistent/wrong/target" "${FAKE_HOME5}/.local/bin/release"

# board command 'worklist' → DANGLING (symlink to missing source)
ln -s "${FAKE_FOUND5}/workflows/scripts/board/worklist.sh" \
  "${FAKE_HOME5}/.local/bin/worklist"
# Remove the source to make it dangling
rm "${FAKE_FOUND5}/workflows/scripts/board/worklist.sh"

# board command 'reconcile' → MISSING (don't create anything)
# board command 'capture' → OK
ln -s "${FAKE_FOUND5}/workflows/scripts/board/capture.sh" \
  "${FAKE_HOME5}/.local/bin/capture"
# board command 'milestone' → OK
ln -s "${FAKE_FOUND5}/workflows/scripts/board/milestone.sh" \
  "${FAKE_HOME5}/.local/bin/milestone"

# gh shim → MISSING (don't create)
# .zshrc → MISSING (no symlink created above)

# Run doctor against this fake environment and capture output + exit code
doctor_out="$(
  FOUNDATION="$FAKE_FOUND5" HOME="$FAKE_HOME5" \
    bash "$DOCTOR_SH" "$FAKE_FOUND5" 2>&1
)" && doctor_exit=0 || doctor_exit=$?

# Verify non-zero exit (at least one non-OK entry)
[[ "$doctor_exit" -ne 0 ]] || fail "5: doctor should exit non-zero with non-OK entries"

# Verify status classifications
grep -q "MISSING.*zshrc" <<<"$doctor_out" || \
  fail "5: .zshrc should be classified MISSING"

grep -q "SHADOWED.*commands" <<<"$doctor_out" || \
  fail "5: claude/commands should be classified SHADOWED"

grep -q "DRIFT.*CLAUDE.md" <<<"$doctor_out" || \
  fail "5: composed CLAUDE.md (kind=claude-md) should be classified DRIFT when a directory sits at the target"

grep -q "DRIFT.*release" <<<"$doctor_out" || \
  fail "5: release should be classified DRIFT (wrong symlink target)"

grep -q "DANGLING.*worklist" <<<"$doctor_out" || \
  fail "5: worklist should be classified DANGLING (broken symlink)"

grep -q "MISSING.*reconcile" <<<"$doctor_out" || \
  fail "5: reconcile should be classified MISSING"

# OK entries should show OK
grep -q "OK.*claim" <<<"$doctor_out" || \
  fail "5: claim should be classified OK"
grep -q "OK.*settings.json" <<<"$doctor_out" || \
  fail "5: settings.json should be classified OK"

pass "5: doctor correctly classifies MISSING, DRIFT, SHADOWED, DANGLING and exits non-zero"

# ---------------------------------------------------------------------------
# Test 6: doctor exits 0 when all entries are OK
# ---------------------------------------------------------------------------
FAKE_HOME6="${TMP}/home6"
mkdir -p \
  "${FAKE_HOME6}/.claude" \
  "${FAKE_HOME6}/.local/bin"

FAKE_FOUND6="${TMP}/foundation6"
mkdir -p \
  "${FAKE_FOUND6}/env" \
  "${FAKE_FOUND6}/claude" \
  "${FAKE_FOUND6}/workflows/scripts/board"

# env: .zshrc
touch "${FAKE_FOUND6}/env/.zshrc"
ln -s "${FAKE_FOUND6}/env/.zshrc" "${FAKE_HOME6}/.zshrc"

# claude: settings.json (real) + CLAUDE.kernel.md/CLAUDE.overlay.md (compose
# sources) + the composed CLAUDE.md itself (kind=claude-md, a real file — OK
# iff present and not a symlink, same as settings.json)
touch "${FAKE_FOUND6}/claude/settings.json"
echo '{"model":"test"}' >"${FAKE_HOME6}/.claude/settings.json"
touch "${FAKE_FOUND6}/claude/CLAUDE.kernel.md"
touch "${FAKE_FOUND6}/claude/CLAUDE.overlay.md"
echo '# composed' >"${FAKE_HOME6}/.claude/CLAUDE.md"

# board commands (all OK symlinks)
for cmd in claim release worklist reconcile capture milestone; do
  touch "${FAKE_FOUND6}/workflows/scripts/board/${cmd}.sh"
  ln -s "${FAKE_FOUND6}/workflows/scripts/board/${cmd}.sh" \
    "${FAKE_HOME6}/.local/bin/${cmd}"
done

# gh shim: real file with call-logger marker
printf '#!/usr/bin/env bash\n# call-logger shim\nexec gh "$@"\n' \
  >"${FAKE_HOME6}/.local/bin/gh"
chmod +x "${FAKE_HOME6}/.local/bin/gh"

doctor_all_ok_out="$(
  FOUNDATION="$FAKE_FOUND6" HOME="$FAKE_HOME6" \
    bash "$DOCTOR_SH" "$FAKE_FOUND6" 2>&1
)" && doctor_ok_exit=0 || doctor_ok_exit=$?

[[ "$doctor_ok_exit" -eq 0 ]] || \
  fail "6: doctor should exit 0 when all entries are OK (exit=${doctor_ok_exit}); output: ${doctor_all_ok_out}"

grep -q "Non-OK: 0" <<<"$doctor_all_ok_out" || \
  fail "6: expected 'Non-OK: 0' in doctor output"

pass "6: doctor exits 0 when all entries are OK"

# ---------------------------------------------------------------------------
echo
echo "PASS: all install-links tests passed"
