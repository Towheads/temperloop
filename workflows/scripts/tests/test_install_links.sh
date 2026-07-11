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
#   4. All board-toolkit + co-deployed commands are enumerated
#   5. doctor classifies MISSING, DRIFT, SHADOWED, DANGLING correctly
#      against a controlled fixture HOME, then exits non-zero
#   6. doctor exits 0 when every entry is OK
#   7. links_provision_cache_stores (F#988/#1026): creates the cache store
#      root idempotently, never writes/edits boards.conf, and prints an
#      opt-in hint only for a board missing a `cache=` line
#   8. doctor's check_cache_state reports absent/present/stale per board and
#      skips cleanly when board.sh/cache.sh are absent
#   9. an absent/unwarmed cache store never flips doctor's own exit code
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
for cmd in claim release worklist reconcile capture milestone pr-enqueue; do
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
# Test 4: all board-toolkit + co-deployed commands enumerated
# ---------------------------------------------------------------------------
for cmd in claim release worklist reconcile capture milestone pr-enqueue; do
  grep -q "${FAKE_HOME}/.local/bin/${cmd}" <<<"$output" || \
    fail "4: board command '${cmd}' not enumerated"
done

pass "4: all board-toolkit + co-deployed commands enumerated"

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
for cmd in claim release worklist reconcile capture milestone pr-enqueue; do
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
# co-deployed 'pr-enqueue' → OK
ln -s "${FAKE_FOUND5}/workflows/scripts/board/pr-enqueue.sh" \
  "${FAKE_HOME5}/.local/bin/pr-enqueue"

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
for cmd in claim release worklist reconcile capture milestone pr-enqueue; do
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
# Test 7: links_provision_cache_stores (F#988/#1026)
# ---------------------------------------------------------------------------
FAKE_HOME7="${TMP}/home7"
mkdir -p "$FAKE_HOME7"
FAKE_FOUND7="${TMP}/foundation7"
mkdir -p "${FAKE_FOUND7}/workflows/scripts/board"

cat > "${FAKE_FOUND7}/workflows/scripts/board/boards.conf" <<'EOF'
board.1.repo=acme/widget-app
board.2.repo=acme/internal-tools
board.2.cache=on
EOF
conf_before="$(cat "${FAKE_FOUND7}/workflows/scripts/board/boards.conf")"

provision_out="$(
  HOME="$FAKE_HOME7" XDG_CACHE_HOME="${FAKE_HOME7}/.cache" XDG_CONFIG_HOME="${FAKE_HOME7}/.config" \
    bash -c '
      # shellcheck source=/dev/null
      source "'"$LINKS_SH"'"
      links_provision_cache_stores "'"$FAKE_FOUND7"'"
    '
)"

[[ -d "${FAKE_HOME7}/.cache/temperloop" ]] || fail "7: store root not created"
echo "$provision_out" | grep -q "cache store root ready" || fail "7: missing store-root-ready line"
echo "$provision_out" | grep -q "board 1 has no cache axis yet" || fail "7: expected an opt-in hint for board 1 (no cache= line)"
echo "$provision_out" | grep -q "board.1.cache=on" || fail "7: opt-in hint should name the exact line to add"
if echo "$provision_out" | grep -q "board 2 has no cache axis"; then
  fail "7: board 2 already has a cache= line — must NOT be suggested"
fi

conf_after="$(cat "${FAKE_FOUND7}/workflows/scripts/board/boards.conf")"
[[ "$conf_before" == "$conf_after" ]] || fail "7: boards.conf must never be written/edited by provisioning"

# Idempotent re-run: same store root, same output shape, still no conf write.
provision_out2="$(
  HOME="$FAKE_HOME7" XDG_CACHE_HOME="${FAKE_HOME7}/.cache" XDG_CONFIG_HOME="${FAKE_HOME7}/.config" \
    bash -c '
      # shellcheck source=/dev/null
      source "'"$LINKS_SH"'"
      links_provision_cache_stores "'"$FAKE_FOUND7"'"
    '
)"
echo "$provision_out2" | grep -q "cache store root ready" || fail "7: re-run should still report the store root ready"
[[ "$(cat "${FAKE_FOUND7}/workflows/scripts/board/boards.conf")" == "$conf_before" ]] || \
  fail "7: boards.conf must still be untouched after a second (idempotent) run"

pass "7: links_provision_cache_stores creates the store root idempotently, suggests only the un-opted-in board, never writes boards.conf"

# ---------------------------------------------------------------------------
# Test 8: doctor's check_cache_state (F#988/#1026) — absent/present/stale,
# never affecting doctor's own exit code.
# ---------------------------------------------------------------------------
FAKE_HOME8="${TMP}/home8"
mkdir -p "${FAKE_HOME8}/.local/bin" "${FAKE_HOME8}/.claude"
FAKE_FOUND8="${TMP}/foundation8"
mkdir -p \
  "${FAKE_FOUND8}/env" \
  "${FAKE_FOUND8}/claude" \
  "${FAKE_FOUND8}/workflows/scripts/board/lib"

cp "${REPO_ROOT}/workflows/scripts/board/lib/board.sh" "${FAKE_FOUND8}/workflows/scripts/board/lib/board.sh"
cp "${REPO_ROOT}/workflows/scripts/board/lib/cache.sh" "${FAKE_FOUND8}/workflows/scripts/board/lib/cache.sh"

cat > "${FAKE_FOUND8}/workflows/scripts/board/boards.conf" <<'EOF'
board.1.repo=acme/absent-repo
board.2.repo=acme/warm-repo
board.2.cache=on
board.3.repo=acme/stale-repo
board.3.cache=on
EOF

mkdir -p "${FAKE_HOME8}/.cache/temperloop/issues/acme-warm-repo"
python3 -c 'import json,time;print(json.dumps({"schema_version":1,"repo":"acme/warm-repo","last_refresh":int(time.time())}))' \
  >"${FAKE_HOME8}/.cache/temperloop/issues/acme-warm-repo/meta.json"

mkdir -p "${FAKE_HOME8}/.cache/temperloop/issues/acme-stale-repo"
python3 -c 'import json;print(json.dumps({"schema_version":1,"repo":"acme/stale-repo","last_refresh":1}))' \
  >"${FAKE_HOME8}/.cache/temperloop/issues/acme-stale-repo/meta.json"

# All the OTHER managed links are deliberately left un-created (MISSING) —
# this test only cares that (a) the cache section reports the right 3
# per-board states and (b) an absent/stale cache store does NOT itself flip
# doctor's overall exit code (only the pre-existing managed-link drift does).
doctor8_out="$(
  FOUNDATION="$FAKE_FOUND8" HOME="$FAKE_HOME8" XDG_CACHE_HOME="${FAKE_HOME8}/.cache" \
    XDG_CONFIG_HOME="${FAKE_HOME8}/.config-missing" \
    bash "$DOCTOR_SH" "$FAKE_FOUND8" 2>&1
)" || true   # other managed links are deliberately left MISSING (non-zero exit expected) — the cache section's own content is what this test checks

echo "$doctor8_out" | grep -qE 'board\.1 +cache=off +store=absent' || \
  fail "8: board 1 (no cache= line, no store) should report cache=off store=absent (got: $doctor8_out)"
echo "$doctor8_out" | grep -qE 'board\.2 +cache=on +store=present' || \
  fail "8: board 2 (cache=on, fresh meta.json) should report cache=on store=present (got: $doctor8_out)"
echo "$doctor8_out" | grep -qE 'board\.3 +cache=on +store=stale' || \
  fail "8: board 3 (cache=on, old meta.json) should report cache=on store=stale (got: $doctor8_out)"

# SKIPPED path: board.sh/cache.sh absent entirely must not error.
FAKE_FOUND8B="${TMP}/foundation8b"
mkdir -p "${FAKE_FOUND8B}/env" "${FAKE_FOUND8B}/claude" "${FAKE_FOUND8B}/workflows/scripts/board"
doctor8b_out="$(
  FOUNDATION="$FAKE_FOUND8B" HOME="${TMP}/home8b" bash "$DOCTOR_SH" "$FAKE_FOUND8B" 2>&1
)" || true   # other managed links are absent too (non-zero exit expected)
echo "$doctor8b_out" | grep -q "SKIPPED (board.sh / cache.sh not found" || \
  fail "8: cache section should SKIP cleanly when board.sh/cache.sh are absent (got: $doctor8b_out)"

pass "8: doctor's check_cache_state reports absent/present/stale per board and skips cleanly when the libs are absent"

# ---------------------------------------------------------------------------
# Test 9: an absent/stale cache store must NOT flip doctor's own exit code —
# only genuine managed-link drift does. Re-use test 6's fully-OK fixture and
# layer a boards.conf (cache=on, no store on disk) on top.
# ---------------------------------------------------------------------------
FAKE_HOME9="${TMP}/home9"
mkdir -p "${FAKE_HOME9}/.claude" "${FAKE_HOME9}/.local/bin"
FAKE_FOUND9="${TMP}/foundation9"
mkdir -p \
  "${FAKE_FOUND9}/env" \
  "${FAKE_FOUND9}/claude" \
  "${FAKE_FOUND9}/workflows/scripts/board/lib"

touch "${FAKE_FOUND9}/env/.zshrc"
ln -s "${FAKE_FOUND9}/env/.zshrc" "${FAKE_HOME9}/.zshrc"
touch "${FAKE_FOUND9}/claude/settings.json"
echo '{"model":"test"}' >"${FAKE_HOME9}/.claude/settings.json"
touch "${FAKE_FOUND9}/claude/CLAUDE.kernel.md" "${FAKE_FOUND9}/claude/CLAUDE.overlay.md"
echo '# composed' >"${FAKE_HOME9}/.claude/CLAUDE.md"
for cmd in claim release worklist reconcile capture milestone pr-enqueue; do
  touch "${FAKE_FOUND9}/workflows/scripts/board/${cmd}.sh"
  ln -s "${FAKE_FOUND9}/workflows/scripts/board/${cmd}.sh" "${FAKE_HOME9}/.local/bin/${cmd}"
done
printf '#!/usr/bin/env bash\n# call-logger shim\nexec gh "$@"\n' >"${FAKE_HOME9}/.local/bin/gh"
chmod +x "${FAKE_HOME9}/.local/bin/gh"

cp "${REPO_ROOT}/workflows/scripts/board/lib/board.sh" "${FAKE_FOUND9}/workflows/scripts/board/lib/board.sh"
cp "${REPO_ROOT}/workflows/scripts/board/lib/cache.sh" "${FAKE_FOUND9}/workflows/scripts/board/lib/cache.sh"
cat > "${FAKE_FOUND9}/workflows/scripts/board/boards.conf" <<'EOF'
board.1.repo=acme/never-warmed-repo
board.1.cache=on
EOF

doctor9_out="$(
  FOUNDATION="$FAKE_FOUND9" HOME="$FAKE_HOME9" XDG_CACHE_HOME="${FAKE_HOME9}/.cache" \
    XDG_CONFIG_HOME="${FAKE_HOME9}/.config-missing" \
    bash "$DOCTOR_SH" "$FAKE_FOUND9" 2>&1
)" && doctor9_exit=0 || doctor9_exit=$?

[[ "$doctor9_exit" -eq 0 ]] || \
  fail "9: an absent cache store must not fail doctor (exit=${doctor9_exit}); output: ${doctor9_out}"
echo "$doctor9_out" | grep -qE 'board\.1 +cache=on +store=absent' || \
  fail "9: board 1 should report cache=on store=absent (got: $doctor9_out)"

pass "9: an unwarmed (absent) cache store never fails doctor's overall gate"

# ---------------------------------------------------------------------------
# Test 10: an ABSENT env/ directory (a kernel-only checkout, e.g. this repo
# itself) yields ZERO env records — not a bogus literal-glob entry
# (temperloop#264, the bug `temperloop install`/doctor.sh going green on a
# kernel-only checkout caught: bash's default non-nullglob behavior leaves
# `env/.*` unexpanded when env/ doesn't exist, so the loop iterated once
# with the literal pattern string and emitted `${home}/.*`).
# ---------------------------------------------------------------------------
FAKE_HOME10="${TMP}/home10"
mkdir -p "$FAKE_HOME10"
FAKE_FOUND10="${TMP}/foundation10"
mkdir -p \
  "${FAKE_FOUND10}/claude" \
  "${FAKE_FOUND10}/workflows/scripts/board"
# Deliberately NO ${FAKE_FOUND10}/env directory.
touch "${FAKE_FOUND10}/claude/settings.json"
for cmd in claim release worklist reconcile capture milestone pr-enqueue; do
  touch "${FAKE_FOUND10}/workflows/scripts/board/${cmd}.sh"
done

output10="$(
  FOUNDATION="$FAKE_FOUND10" HOME="$FAKE_HOME10" bash -c '
    # shellcheck source=/dev/null
    source "'"$LINKS_SH"'"
    links_enumerate
  '
)"

if grep -q '\.\*' <<<"$output10"; then
  fail "10: an absent env/ directory should yield zero env records, not a literal '.*' entry (got: $(grep '\.\*' <<<"$output10"))"
fi
echo "$output10" | grep -q "${FAKE_HOME10}/.claude/settings.json" || \
  fail "10: non-env categories should still be enumerated when env/ is absent"

pass "10: an absent env/ directory yields zero env records (no bogus literal-glob entry), other categories unaffected"

# ---------------------------------------------------------------------------
echo
echo "PASS: all install-links tests passed"
