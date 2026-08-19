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
#  12. links_persist_knowledge_root (F#1771): persists an env-supplied
#      ABSOLUTE root into the rung-3 machine conf and proves a bare consumer
#      reads it back, never clobbers an already-usable conf (idempotent),
#      refuses a relative root, reports the default-fallback / conf-present-
#      but-unusable provenance without failing the install, and never touches
#      the operator's REAL machine conf
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
grep -q "cache store root ready" <<<"$provision_out" || fail "7: missing store-root-ready line"
grep -q "board 1 has no cache axis yet" <<<"$provision_out" || fail "7: expected an opt-in hint for board 1 (no cache= line)"
grep -q "board.1.cache=on" <<<"$provision_out" || fail "7: opt-in hint should name the exact line to add"
if grep -q "board 2 has no cache axis" <<<"$provision_out"; then
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
grep -q "cache store root ready" <<<"$provision_out2" || fail "7: re-run should still report the store root ready"
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

grep -qE 'board\.1 +cache=off +store=absent' <<<"$doctor8_out" || \
  fail "8: board 1 (no cache= line, no store) should report cache=off store=absent (got: $doctor8_out)"
grep -qE 'board\.2 +cache=on +store=present' <<<"$doctor8_out" || \
  fail "8: board 2 (cache=on, fresh meta.json) should report cache=on store=present (got: $doctor8_out)"
grep -qE 'board\.3 +cache=on +store=stale' <<<"$doctor8_out" || \
  fail "8: board 3 (cache=on, old meta.json) should report cache=on store=stale (got: $doctor8_out)"

# SKIPPED path: board.sh/cache.sh absent entirely must not error.
FAKE_FOUND8B="${TMP}/foundation8b"
mkdir -p "${FAKE_FOUND8B}/env" "${FAKE_FOUND8B}/claude" "${FAKE_FOUND8B}/workflows/scripts/board"
doctor8b_out="$(
  FOUNDATION="$FAKE_FOUND8B" HOME="${TMP}/home8b" bash "$DOCTOR_SH" "$FAKE_FOUND8B" 2>&1
)" || true   # other managed links are absent too (non-zero exit expected)
grep -q "SKIPPED (board.sh / cache.sh not found" <<<"$doctor8b_out" || \
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
grep -qE 'board\.1 +cache=on +store=absent' <<<"$doctor9_out" || \
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
grep -q "${FAKE_HOME10}/.claude/settings.json" <<<"$output10" || \
  fail "10: non-env categories should still be enumerated when env/ is absent"

pass "10: an absent env/ directory yields zero env records (no bogus literal-glob entry), other categories unaffected"

# ---------------------------------------------------------------------------
# Test 11: links_apply_symlink is self-healing (temperloop#530) — re-running
# it over a farm of DANGLING links pointing into a deleted worktree repairs
# every one atomically, with no "ln: <target>: File exists" error and no
# broken links left behind. Also covers the OK / real-file / absent branches.
# ---------------------------------------------------------------------------
FAKE_HOME11="${TMP}/home11"
mkdir -p "${FAKE_HOME11}/.local/bin"

# The "current" source tree the links SHOULD point into.
NEW_SRC="${TMP}/src-current/workflows/scripts/board"
mkdir -p "$NEW_SRC"
for cmd in claim release worklist reconcile capture milestone pr-enqueue; do
  touch "${NEW_SRC}/${cmd}.sh"
done

# A now-DELETED worktree the old link farm points into.
OLD_SRC="${TMP}/src-deleted-worktree/workflows/scripts/board"
mkdir -p "$OLD_SRC"
for cmd in claim release worklist reconcile capture milestone pr-enqueue; do
  touch "${OLD_SRC}/${cmd}.sh"
  ln -s "${OLD_SRC}/${cmd}.sh" "${FAKE_HOME11}/.local/bin/${cmd}"
done
# Delete the old worktree — every link is now dangling.
rm -rf "${TMP}/src-deleted-worktree"
[ -L "${FAKE_HOME11}/.local/bin/claim" ] || fail "11: setup — claim should be a symlink"
[ -e "${FAKE_HOME11}/.local/bin/claim" ] && fail "11: setup — claim should be DANGLING (resolve to nothing)"

apply_farm() {
  # shellcheck source=/dev/null
  source "$LINKS_SH"
  for cmd in claim release worklist reconcile capture milestone pr-enqueue; do
    links_apply_symlink "${FAKE_HOME11}/.local/bin/${cmd}" "${NEW_SRC}/${cmd}.sh"
  done
}

apply_out="$( ( apply_farm ) 2>&1 )" && apply_exit=0 || apply_exit=$?
[[ "$apply_exit" -eq 0 ]] || fail "11: apply over dangling farm exited non-zero (${apply_exit}); output: ${apply_out}"

# No "File exists" error anywhere.
if grep -qi "File exists" <<<"$apply_out"; then
  fail "11: healing a dangling link farm must not emit 'ln: File exists' (got: ${apply_out})"
fi

# Every link is now VALID and points at the new source; none dangling.
for cmd in claim release worklist reconcile capture milestone pr-enqueue; do
  link="${FAKE_HOME11}/.local/bin/${cmd}"
  [ -L "$link" ] || fail "11: ${cmd} should still be a symlink after heal"
  [ -e "$link" ] || fail "11: ${cmd} is still DANGLING after heal (should resolve)"
  [ "$(readlink "$link")" = "${NEW_SRC}/${cmd}.sh" ] || \
    fail "11: ${cmd} should point at the new source, got '$(readlink "$link")'"
done

# It reported the heal (relinked), not a spurious "already linked".
grep -q "relinked claim" <<<"$apply_out" || \
  fail "11: expected a 'relinked' notice for a healed dangling link (got: ${apply_out})"

# Idempotent second run: everything is already correct now → no re-linking.
apply_out2="$( ( apply_farm ) 2>&1 )"
grep -q "already linked" <<<"$apply_out2" || \
  fail "11: a correctly-linked farm should report 'already linked' on re-run (got: ${apply_out2})"
if grep -q "relinked" <<<"$apply_out2"; then
  fail "11: an already-correct link must NOT be re-linked (got: ${apply_out2})"
fi

# A real (non-symlink) file at the target is preserved, not clobbered.
echo "user real file" >"${FAKE_HOME11}/.local/bin/realfile"
apply_real_out="$(
  ( # shellcheck source=/dev/null
    source "$LINKS_SH"
    links_apply_symlink "${FAKE_HOME11}/.local/bin/realfile" "${NEW_SRC}/claim.sh" ) 2>&1
)"
grep -q "is not a symlink — skipping" <<<"$apply_real_out" || \
  fail "11: a real file must be skipped, not clobbered (got: ${apply_real_out})"
{ [ -f "${FAKE_HOME11}/.local/bin/realfile" ] && [ ! -L "${FAKE_HOME11}/.local/bin/realfile" ]; } || \
  fail "11: the real file should be left untouched (still a plain file)"
[ "$(cat "${FAKE_HOME11}/.local/bin/realfile")" = "user real file" ] || \
  fail "11: the real file's contents must be preserved"

# An absent target is created fresh.
apply_absent_out="$(
  ( # shellcheck source=/dev/null
    source "$LINKS_SH"
    links_apply_symlink "${FAKE_HOME11}/.local/bin/fresh" "${NEW_SRC}/claim.sh" ) 2>&1
)"
grep -q "linked fresh" <<<"$apply_absent_out" || \
  fail "11: an absent target should be freshly linked (got: ${apply_absent_out})"
[ "$(readlink "${FAKE_HOME11}/.local/bin/fresh")" = "${NEW_SRC}/claim.sh" ] || \
  fail "11: freshly-created link should point at the source"

pass "11: links_apply_symlink heals a dangling link farm atomically, is idempotent, preserves real files, and creates absent links"

# ---------------------------------------------------------------------------
# Test 12: links_persist_knowledge_root (F#1771) — the INSTALL half of the
# knowledge-store-root single-point-of-failure closure whose DETECTION half
# (doctor.sh's check_knowledge_root provenance arm) shipped in F#1340.
#
# HERMETIC BY CONSTRUCTION. Every invocation runs under `env -i` with a
# fixture HOME / XDG_CONFIG_HOME / XDG_DATA_HOME, so the operator's REAL
# rung-3 machine conf and REAL store are unreachable from this test — that
# conf is the very file #1771 exists to protect, and writing to it from a
# test run would be the regression, not a flake. The real conf's checksum is
# captured before this block and re-asserted after it, so hermeticity is a
# checked property rather than a claim about the fixture wiring.
# ---------------------------------------------------------------------------
KS_LIB_SRC="${REPO_ROOT}/workflows/scripts/lib/knowledge_store.sh"
[ -f "$KS_LIB_SRC" ] || fail "12: knowledge_store.sh not found at ${KS_LIB_SRC}"

REAL_CONF="${KNOWLEDGE_STORE_MACHINE_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/build.config.sh}"
if [ -f "$REAL_CONF" ]; then
  real_conf_before="$(cksum <"$REAL_CONF")"
else
  real_conf_before="ABSENT"
fi

FAKE_FOUND12="${TMP}/foundation12"
mkdir -p "${FAKE_FOUND12}/workflows/scripts/lib"
cp "$KS_LIB_SRC" "${FAKE_FOUND12}/workflows/scripts/lib/knowledge_store.sh"

# persist_run <fixture-home> [<KNOWLEDGE_STORE_ROOT>] — one hermetic call.
# An absent/empty second arg means "no KNOWLEDGE_STORE_ROOT in the environment
# at all"; `env -i` guarantees nothing else leaks in either (notably not
# KNOWLEDGE_STORE_MACHINE_CONF, which would otherwise repoint the conf read).
persist_run() {
  local fake_home="$1" env_root="${2:-}"
  local -a envargs
  envargs=(
    HOME="$fake_home"
    PATH="$PATH"
    XDG_CONFIG_HOME="${fake_home}/.config"
    XDG_DATA_HOME="${fake_home}/.local/share"
  )
  if [ -n "$env_root" ]; then
    envargs+=(KNOWLEDGE_STORE_ROOT="$env_root")
  fi
  env -i "${envargs[@]}" bash -c '
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$1"
    links_persist_knowledge_root "$2"
  ' _ "$LINKS_SH" "$FAKE_FOUND12" 2>&1
}

# resolve_root <fixture-home> — what a BARE consumer (a hook, a launchd agent:
# knowledge_store.sh alone, no env, no build.config.sh) resolves under that
# fixture. This is the round-trip assertion that discriminates "a line was
# appended" from "the root is actually persisted": only a conf line
# _ks_machine_conf_root can read back moves this value.
resolve_root() {
  local fake_home="$1"
  env -i \
    HOME="$fake_home" \
    PATH="$PATH" \
    XDG_CONFIG_HOME="${fake_home}/.config" \
    XDG_DATA_HOME="${fake_home}/.local/share" \
    bash -c '
      set -uo pipefail
      # shellcheck source=/dev/null
      source "$1"
      ks_root
    ' _ "${FAKE_FOUND12}/workflows/scripts/lib/knowledge_store.sh" 2>/dev/null
}

# ---- 12a. PERSIST: env set, no conf yet -> written, and READ BACK ----------
FAKE_HOME12A="${TMP}/home12a"
mkdir -p "$FAKE_HOME12A"
CONF12A="${FAKE_HOME12A}/.config/temperloop/build.config.sh"
STORE12A="${TMP}/store12a"

# Baseline BEFORE the persist: a bare consumer falls through to the XDG
# default, NOT to the store. If this ever equals $STORE12A the rest of 12a
# proves nothing.
pre_root="$(resolve_root "$FAKE_HOME12A")"
[[ "$pre_root" != "$STORE12A" ]] || \
  fail "12a: fixture is not discriminating — the bare-env root already equals the store before any persist"

out12a="$(persist_run "$FAKE_HOME12A" "$STORE12A")"
[ -f "$CONF12A" ] || fail "12a: the machine conf should have been created at ${CONF12A}; output: ${out12a}"
grep -q "persisted knowledge-store root" <<<"$out12a" || \
  fail "12a: expected a 'persisted' line; got: ${out12a}"
grep -Fq ': "${KNOWLEDGE_STORE_ROOT:='"${STORE12A}"'}"' "$CONF12A" || \
  fail "12a: the conf must carry the assign-if-unset line for the store root; conf: $(cat "$CONF12A")"

post_root="$(resolve_root "$FAKE_HOME12A")"
[[ "$post_root" == "$STORE12A" ]] || \
  fail "12a: a bare consumer must now resolve the persisted root (want ${STORE12A}, got ${post_root})"

pass "12a: persists an env-supplied absolute root into the machine conf, and a bare consumer reads it back"

# ---- 12b. NEVER CLOBBER + IDEMPOTENT --------------------------------------
conf12a_after_first="$(cat "$CONF12A")"

out12b_same="$(persist_run "$FAKE_HOME12A" "$STORE12A")"
grep -q "already persisted" <<<"$out12b_same" || \
  fail "12b: a second run with the same env root should report 'already persisted'; got: ${out12b_same}"
[[ "$(cat "$CONF12A")" == "$conf12a_after_first" ]] || \
  fail "12b: a second run must leave the conf byte-identical"

out12b_none="$(persist_run "$FAKE_HOME12A")"
grep -q "already persisted" <<<"$out12b_none" || \
  fail "12b: a run with no env root over a usable conf should report 'already persisted'; got: ${out12b_none}"
[[ "$(cat "$CONF12A")" == "$conf12a_after_first" ]] || \
  fail "12b: a no-env run must leave the conf byte-identical"

out12b_diff="$(persist_run "$FAKE_HOME12A" "${TMP}/store12a-other")"
[[ "$(cat "$CONF12A")" == "$conf12a_after_first" ]] || \
  fail "12b: a DIFFERENT env root must NOT rewrite an already-usable conf (never clobber)"
grep -q "DIFFERS" <<<"$out12b_diff" || \
  fail "12b: a divergent env root should be surfaced, not silently ignored; got: ${out12b_diff}"

pass "12b: never clobbers an already-usable conf — same, absent, and divergent env roots all leave it byte-identical"

# ---- 12c. RELATIVE ROOTS ARE REFUSED --------------------------------------
FAKE_HOME12C="${TMP}/home12c"
mkdir -p "$FAKE_HOME12C"
CONF12C="${FAKE_HOME12C}/.config/temperloop/build.config.sh"

out12c="$(persist_run "$FAKE_HOME12C" "relative/store")" && rc12c=0 || rc12c=$?
[ "$rc12c" -eq 0 ] || fail "12c: a relative root must not fail the install (exit=${rc12c}); output: ${out12c}"
[ ! -f "$CONF12C" ] || \
  fail "12c: a relative root must NOT be persisted — conf was created: $(cat "$CONF12C")"
grep -q "RELATIVE" <<<"$out12c" || \
  fail "12c: expected the refusal to name the value as relative; got: ${out12c}"

pass "12c: refuses a relative KNOWLEDGE_STORE_ROOT (ks_root's machine-conf rung would reject it), without failing the install"

# ---- 12c2. SHELL-METACHARACTER ROOTS ARE REFUSED --------------------------
# The persisted line is `: "${KNOWLEDGE_STORE_ROOT:=<root>}"` — the value sits
# inside DOUBLE quotes, so a `$`, backtick or backslash in the path EXPANDS
# when the conf is re-sourced rather than being carried as data. Persisting
# one yields a conf that READS correct while every consumer silently resolves
# a different directory: the exact silent-wrong-root class F#1771 exists to
# close, reintroduced by the fix for it. Measured before this guard existed —
# `/tmp/store$HOME-literal` round-tripped as `/tmp/store/Users/.../home-literal`.
for meta_root in '/tmp/store$HOME-x' '/tmp/store`id`-x' '/tmp/store\x'; do
  FAKE_HOME12C2="${TMP}/home12c2"
  rm -rf "$FAKE_HOME12C2"; mkdir -p "$FAKE_HOME12C2"
  CONF12C2="${FAKE_HOME12C2}/.config/temperloop/build.config.sh"

  out12c2="$(persist_run "$FAKE_HOME12C2" "$meta_root")" && rc12c2=0 || rc12c2=$?
  [ "$rc12c2" -eq 0 ] ||     fail "12c2: a metacharacter root must not fail the install (root=${meta_root} exit=${rc12c2}); output: ${out12c2}"
  [ ! -f "$CONF12C2" ] ||     fail "12c2: a metacharacter root must NOT be persisted (root=${meta_root}) — conf was created: $(cat "$CONF12C2")"
  grep -q "not safe to embed in a sourced conf line" <<<"$out12c2" ||     fail "12c2: expected the refusal to say why the character is unsafe (root=${meta_root}); got: ${out12c2}"
done

pass "12c2: refuses a KNOWLEDGE_STORE_ROOT containing \$, backtick or backslash — persisting one would expand on re-source and silently resolve a different directory"

# ---- 12c3. A NEWLINE ROOT IS REFUSED --------------------------------------
# Separate from 12c2 because the newline arm is the one easiest to write
# wrongly: `$(printf '\n')` in a case pattern is an EMPTY string (command
# substitution strips trailing newlines), which collapses the pattern to `**`
# and refuses every path. This case pins both directions — the newline root is
# refused AND an ordinary root still persists (12a covers the latter, but a
# collapsed pattern would break it in a way that reads like an unrelated bug).
FAKE_HOME12C3="${TMP}/home12c3"
mkdir -p "$FAKE_HOME12C3"
CONF12C3="${FAKE_HOME12C3}/.config/temperloop/build.config.sh"
NL_ROOT="$(printf '/tmp/a\n: "${EVIL:=x}"')"

out12c3="$(persist_run "$FAKE_HOME12C3" "$NL_ROOT")" && rc12c3=0 || rc12c3=$?
[ "$rc12c3" -eq 0 ] || fail "12c3: a newline root must not fail the install (exit=${rc12c3}); output: ${out12c3}"
[ ! -f "$CONF12C3" ] ||   fail "12c3: a newline root must NOT be persisted — it would inject a second line into a sourced conf; got: $(cat "$CONF12C3")"
pass "12c3: refuses a KNOWLEDGE_STORE_ROOT containing a newline (it would inject an extra line into the sourced conf)"

# ---- 12c4. AN INERT APPEND IS REPORTED, NOT CLAIMED AS SUCCESS ------------
# The dead-text guard is TEXTUAL, so it cannot see a conf that parses fine but
# never reaches the appended line — an early `return`, a conditional, an
# included file. Without the post-write re-probe the function prints
# "persisted" over a root that still resolves to the default fallback: the
# same silent-success shape F#1771 exists to close, one layer up.
FAKE_HOME12C4="${TMP}/home12c4"
mkdir -p "${FAKE_HOME12C4}/.config/temperloop"
CONF12C4="${FAKE_HOME12C4}/.config/temperloop/build.config.sh"
printf '# early-exit conf\nreturn 0\n' >"$CONF12C4"

out12c4="$(persist_run "$FAKE_HOME12C4" "${TMP}/store12c4")" && rc12c4=0 || rc12c4=$?
[ "$rc12c4" -eq 0 ] || fail "12c4: an inert append must not fail the install (exit=${rc12c4}); output: ${out12c4}"
grep -q "inert" <<<"$out12c4" ||   fail "12c4: expected the inert-append report naming what a bare consumer really resolves; got: ${out12c4}"
grep -q "→ persisted" <<<"$out12c4" &&   fail "12c4: must NOT claim success when the appended line does not take effect; got: ${out12c4}"
pass "12c4: an appended line that never executes is reported as inert, never claimed as persisted"

# ---- 12c5. ks_lib ABSENT -> SKIPPED, install not failed -------------------
# The stranger-with-a-partial-tree path, and the only other rc-0 early return.
FAKE_HOME12C5="${TMP}/home12c5"
mkdir -p "$FAKE_HOME12C5" "${TMP}/found12c5"
out12c5="$(HOME="$FAKE_HOME12C5" bash -c '
  . "'"$LINKS_SH"'" >/dev/null 2>&1
  links_persist_knowledge_root "'"${TMP}/found12c5"'"' 2>&1)" && rc12c5=0 || rc12c5=$?
[ "$rc12c5" -eq 0 ] || fail "12c5: a tree with no knowledge_store.sh must not fail the install (exit=${rc12c5}); output: ${out12c5}"
grep -q "SKIPPED" <<<"$out12c5" ||   fail "12c5: expected a SKIPPED notice when knowledge_store.sh is absent; got: ${out12c5}"
pass "12c5: a tree with no knowledge_store.sh degrades to SKIPPED rather than failing the install"

# ---- 12d. DEFAULT-FALLBACK NOTICE -----------------------------------------
FAKE_HOME12D="${TMP}/home12d"
mkdir -p "$FAKE_HOME12D"
CONF12D="${FAKE_HOME12D}/.config/temperloop/build.config.sh"

out12d="$(persist_run "$FAKE_HOME12D")" && rc12d=0 || rc12d=$?
[ "$rc12d" -eq 0 ] || fail "12d: an unconfigured root must not fail the install (exit=${rc12d}); output: ${out12d}"
[ ! -f "$CONF12D" ] || fail "12d: nothing configured the root — no conf may be invented"
grep -q "default-fallback" <<<"$out12d" || \
  fail "12d: expected the check_knowledge_root provenance word 'default-fallback'; got: ${out12d}"
grep -q "NOTHING configured it" <<<"$out12d" || \
  fail "12d: expected the prominent 'nothing configured it' notice; got: ${out12d}"
grep -Fq "${FAKE_HOME12D}/.local/share/temperloop/knowledge" <<<"$out12d" || \
  fail "12d: the notice must name the fixture's own resolved fallback root (hermeticity + actionability); got: ${out12d}"

pass "12d: reports the default-fallback provenance and the root it would use, invents nothing, and never fails the install"

# ---- 12e. conf-present-but-unusable is refused, not appended to -----------
FAKE_HOME12E="${TMP}/home12e"
mkdir -p "${FAKE_HOME12E}/.config/temperloop"
CONF12E="${FAKE_HOME12E}/.config/temperloop/build.config.sh"
cat > "$CONF12E" <<'EOF'
# hand-written machine conf
: "${KNOWLEDGE_STORE_ROOT:=relative/oops}"
EOF
conf12e_before="$(cat "$CONF12E")"

out12e="$(persist_run "$FAKE_HOME12E" "${TMP}/store12e")"
[[ "$(cat "$CONF12E")" == "$conf12e_before" ]] || \
  fail "12e: a conf that already mentions KNOWLEDGE_STORE_ROOT must be left byte-identical"
grep -q "conf-present-but-unusable" <<<"$out12e" || \
  fail "12e: expected the check_knowledge_root provenance word 'conf-present-but-unusable'; got: ${out12e}"

pass "12e: refuses to append behind an existing (unusable) KNOWLEDGE_STORE_ROOT line — appending there would be dead text, rewriting it would be a clobber"

# ---- 12f. an existing conf WITHOUT the setting is appended to, not replaced ----
FAKE_HOME12F="${TMP}/home12f"
mkdir -p "${FAKE_HOME12F}/.config/temperloop"
CONF12F="${FAKE_HOME12F}/.config/temperloop/build.config.sh"
STORE12F="${TMP}/store12f"
cat > "$CONF12F" <<'EOF'
# hand-written machine conf
: "${PIPELINE_ENABLED_BOARDS:=3}"
EOF

out12f="$(persist_run "$FAKE_HOME12F" "$STORE12F")"
grep -q "persisted knowledge-store root" <<<"$out12f" || \
  fail "12f: expected a 'persisted' line for a conf with no KNOWLEDGE_STORE_ROOT yet; got: ${out12f}"
grep -Fq 'PIPELINE_ENABLED_BOARDS' "$CONF12F" || \
  fail "12f: the operator's pre-existing conf content must be preserved"
[[ "$(resolve_root "$FAKE_HOME12F")" == "$STORE12F" ]] || \
  fail "12f: the appended line must be read back by a bare consumer"

pass "12f: appends to an existing conf that sets no root, preserving its other settings"

# ---- 12g. hermeticity: the operator's REAL machine conf was never touched --
if [ -f "$REAL_CONF" ]; then
  real_conf_after="$(cksum <"$REAL_CONF")"
else
  real_conf_after="ABSENT"
fi
[[ "$real_conf_after" == "$real_conf_before" ]] || \
  fail "12g: the REAL machine conf at ${REAL_CONF} changed during this test run — that file is exactly what #1771 protects"

pass "12g: the operator's real rung-3 machine conf is byte-identical after the whole test block"

# ---------------------------------------------------------------------------
echo
echo "PASS: all install-links tests passed"
