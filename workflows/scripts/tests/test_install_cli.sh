#!/usr/bin/env bash
#
# test_install_cli.sh — `temperloop install` (temperloop#264, ADR K164 D7
# "install manifest" amendment: the CLI half of the manifest library).
#
# A REAL `temperloop install` run must ONLY EVER happen inside a
# sandbox_up environment (workflows/scripts/tests/lib/sandbox.sh) — never
# against this test-runner's own real $HOME. Every leg below bootstraps a
# real, working `temperloop` binary over file:// (same idiom as
# test_sandbox_dry_run_legs.sh) and dispatches through it, so this proves
# the actual CLI surface, not just a bare `bash install.sh` invocation.
#
# This repo (temperloop, the kernel-only checkout) has NO env/ directory
# and NO claude/settings.json / claude/CLAUDE.overlay.md — those are
# overlay-only, composed in only by a downstream overlay checkout. So
# links_enumerate() here yields ONLY kind=symlink and
# kind=gh-shim records (confirmed by direct enumeration against this repo's
# own tree) — install.sh's kind=real/kind=claude-md branches exist for a
# downstream overlay-composed checkout and are exercised by
# bin/subcommands/install.sh's own header comment reasoning, but are NOT
# reachable from this hermetic suite. That is expected, not a gap: the
# symlink + gh-shim + manifest-recording paths are the ones a kernel-only
# checkout can actually prove.
#
# Covers (mapped to temperloop#264's acceptance criteria):
#   1. Sandbox B — a target pre-seeded with UNRELATED content before
#      install ever runs is backed up (state=preexisting, explicit
#      backup_path holding the ORIGINAL content/symlink verbatim) and then
#      correctly replaced with the managed symlink.
#   2. Sandbox A test 3 — idempotent re-install: a second `install --yes`
#      run converges (manifest path count unchanged, zero new backups).
#   3. Sandbox A tests 1 + 4 — `--dry-run` performs zero writes (no
#      manifest file, no targets created); a non-interactive run with no
#      --yes also aborts with zero writes (eject.sh-style default-deny).
#   4. Sandbox A test 2 — the gh call-logger shim is marker-stamped via
#      manifest_marker_line() (MANIFEST_MARKER_TAG, "temperloop-managed"),
#      independent of doctor.sh's own 'call-logger' identity check.
#   5. Sandbox A test 5 — doctor.sh is green (Non-OK: 0, exit 0) after a
#      sandboxed install.
#
# No network. No real HOME/XDG mutations at any point.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=workflows/scripts/tests/lib/sandbox.sh
source "$HERE/lib/sandbox.sh"

# Kernel-only: bootstraps this repo's install CLI from bin/bootstrap.sh, which
# exists only when the repo root IS the kernel. (#363)
sandbox_skip_if_composed_tree "test_install_cli.sh" "$REPO_ROOT"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

# manifest_file_for <sandbox_xdg_state_home> — mirrors manifest.sh's own
# manifest_file() derivation, without sourcing the lib (this suite only
# ever reads the manifest through the real CLI, then inspects the JSON).
manifest_file_for() { printf '%s/temperloop/install-manifest.json' "$1"; }

# ===========================================================================
# Sandbox A — dry-run / consent-decline / fresh install / idempotence / doctor
# ===========================================================================
sandbox_up test-install-cli-a
sandbox_stub_gh
sandbox_stub_claude
sandbox_bootstrap_checkout "$REPO_ROOT" || fail "sandbox_bootstrap_checkout (A) failed"
[ -x "${SANDBOX_TEMPERLOOP:-}" ] || fail "A: SANDBOX_TEMPERLOOP not set/executable after bootstrap"

# Physically resolved (cd -P), NOT a bare $SANDBOX_HOME/... string: bin/
# temperloop's own dispatcher resolves its symlink chain via `cd -P` (it
# has to, to follow the real ~/.local/bin/temperloop -> .../bin/temperloop
# symlink correctly), so every path install.sh derives from BASH_SOURCE is
# already physical. On macOS, $TMPDIR sits under /var, itself a symlink to
# /private/var — comparing against a non-physical $SANDBOX_HOME/... string
# would spuriously mismatch on exactly that macOS quirk.
CHECKOUT_A="$(cd -P "$SANDBOX_HOME/.local/share/temperloop" && pwd)"
[ -d "$CHECKOUT_A" ] || fail "A: expected bootstrapped checkout at $CHECKOUT_A"

MANIFEST_A="$(manifest_file_for "$SANDBOX_XDG_STATE_HOME")"
BACKUPS_A="$SANDBOX_XDG_STATE_HOME/temperloop/backups"

# ---------------------------------------------------------------------------
# Test 1: --dry-run performs ZERO writes.
# ---------------------------------------------------------------------------
dry_out="$(sandbox_run "$SANDBOX_TEMPERLOOP" install --dry-run 2>&1)"
dry_rc=$?
[ "$dry_rc" -eq 0 ] || fail "1: install --dry-run exited $dry_rc (output: $dry_out)"
echo "$dry_out" | grep -q 'would create' || fail "1: dry-run plan should describe at least one 'would create' entry (got: $dry_out)"
echo "$dry_out" | grep -q 'Dry run: nothing written' || fail "1: dry-run should state nothing was written"
[ ! -e "$MANIFEST_A" ] || fail "1: --dry-run must not write the install manifest"
[ ! -L "$SANDBOX_HOME/.claude/commands" ] && [ ! -e "$SANDBOX_HOME/.claude/commands" ] \
  || fail "1: --dry-run must not create any managed path (found $SANDBOX_HOME/.claude/commands)"
[ ! -e "$SANDBOX_HOME/.local/bin/gh" ] || fail "1: --dry-run must not create the gh shim"

pass "1: 'temperloop install --dry-run' performs zero writes (no manifest file, no managed paths created) and describes the plan"

# ---------------------------------------------------------------------------
# Test 2 (fold-in): non-interactive, no --yes -> default-deny, zero writes
# (mirrors eject.sh's own consent posture).
# ---------------------------------------------------------------------------
deny_out="$(sandbox_run "$SANDBOX_TEMPERLOOP" install </dev/null 2>&1)"
deny_rc=$?
[ "$deny_rc" -eq 0 ] || fail "2: a declined/skipped install should exit 0 (legible no-op), got $deny_rc (output: $deny_out)"
echo "$deny_out" | grep -q 'skipped — no explicit consent' || fail "2: expected a no-explicit-consent skip line (got: $deny_out)"
echo "$deny_out" | grep -q 'aborted — nothing written' || fail "2: expected an aborted/nothing-written summary line (got: $deny_out)"
[ ! -e "$MANIFEST_A" ] || fail "2: a declined install must not write the install manifest"
[ ! -e "$SANDBOX_HOME/.local/bin/gh" ] || fail "2: a declined install must not create the gh shim"

pass "2: a non-interactive 'temperloop install' with no --yes aborts with zero writes (default-deny, eject.sh-style consent)"

# ---------------------------------------------------------------------------
# Test 3: fresh --yes install -> every managed path created, manifest
# records state=created for all of them, gh shim carries BOTH the
# doctor.sh 'call-logger' identity marker and the manifest's own
# 'temperloop-managed' marker-stamp.
# ---------------------------------------------------------------------------
install_out="$(sandbox_run "$SANDBOX_TEMPERLOOP" install --yes 2>&1)"
install_rc=$?
[ "$install_rc" -eq 0 ] || fail "3: install --yes exited $install_rc (output: $install_out)"

[ -L "$SANDBOX_HOME/.claude/commands" ] || fail "3: ~/.claude/commands should be a symlink after install"
[ "$(readlink "$SANDBOX_HOME/.claude/commands")" = "$CHECKOUT_A/claude/commands" ] \
  || fail "3: ~/.claude/commands should point at the bootstrapped checkout's claude/commands"
[ -L "$SANDBOX_HOME/.local/bin/claim" ] || fail "3: ~/.local/bin/claim should be a symlink after install"
[ "$(readlink "$SANDBOX_HOME/.local/bin/claim")" = "$CHECKOUT_A/workflows/scripts/board/claim.sh" ] \
  || fail "3: ~/.local/bin/claim should point at the bootstrapped checkout's board/claim.sh"

[ -f "$SANDBOX_HOME/.local/bin/gh" ] && [ ! -L "$SANDBOX_HOME/.local/bin/gh" ] \
  || fail "3: ~/.local/bin/gh should be a real (non-symlink) file after install"
[ -x "$SANDBOX_HOME/.local/bin/gh" ] || fail "3: ~/.local/bin/gh should be executable"
grep -q 'call-logger' "$SANDBOX_HOME/.local/bin/gh" \
  || fail "3: gh shim should carry doctor.sh's own 'call-logger' identity marker"
grep -q 'temperloop-managed' "$SANDBOX_HOME/.local/bin/gh" \
  || fail "3: gh shim should carry the manifest_marker_line() 'temperloop-managed' marker-stamp"
head -n1 "$SANDBOX_HOME/.local/bin/gh" | grep -q '^#!' \
  || fail "3: gh shim's first line should still be the shebang (marker line must not precede it)"

[ -f "$MANIFEST_A" ] || fail "3: install manifest should exist after a real install run"
jq -e '.schema_version == 1' "$MANIFEST_A" >/dev/null || fail "3: manifest schema_version should be 1"
n_enumerated="$(sandbox_bash 'source "'"$CHECKOUT_A"'/workflows/scripts/install/links.sh"; links_enumerate "'"$CHECKOUT_A"'" | wc -l' | tr -d ' ')"
n_recorded="$(jq '[.paths | keys[]] | length' "$MANIFEST_A")"
[ "$n_recorded" -eq "$n_enumerated" ] || fail "3: manifest should record exactly the enumerated path count (enumerated=$n_enumerated, recorded=$n_recorded)"
n_created="$(jq '[.paths[] | select(.state == "created")] | length' "$MANIFEST_A")"
[ "$n_created" -eq "$n_enumerated" ] || fail "3: every entry should be state=created on a fresh install (created=$n_created of $n_enumerated)"
[ ! -d "$BACKUPS_A" ] || [ -z "$(find "$BACKUPS_A" -type f 2>/dev/null)" ] \
  || fail "3: a fresh install should write zero backup files (nothing preexisting to back up)"

pass "3: a fresh 'temperloop install --yes' creates every managed path, records state=created for all of them in the manifest, and marker-stamps the gh shim"

# ---------------------------------------------------------------------------
# Test 4: idempotent re-install — a second --yes run converges (no
# duplicate manifest entries, no spurious re-backups).
# ---------------------------------------------------------------------------
n_recorded_before="$(jq '[.paths | keys[]] | length' "$MANIFEST_A")"
n_backups_before="$(find "$BACKUPS_A" -type f 2>/dev/null | wc -l | tr -d ' ')"

install_out2="$(sandbox_run "$SANDBOX_TEMPERLOOP" install --yes 2>&1)"
install_rc2=$?
[ "$install_rc2" -eq 0 ] || fail "4: second install --yes exited $install_rc2 (output: $install_out2)"
echo "$install_out2" | grep -q 'already linked' || fail "4: second run should report at least one already-linked entry (got: $install_out2)"
echo "$install_out2" | grep -q 'already installed' || fail "4: second run should report the gh shim as already installed (got: $install_out2)"

n_recorded_after="$(jq '[.paths | keys[]] | length' "$MANIFEST_A")"
n_backups_after="$(find "$BACKUPS_A" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$n_recorded_after" -eq "$n_recorded_before" ] || fail "4: re-install should not change the recorded path count (before=$n_recorded_before, after=$n_recorded_after)"
[ "$n_backups_after" -eq "$n_backups_before" ] || fail "4: re-install should not create any new backup files (before=$n_backups_before, after=$n_backups_after)"

pass "4: re-running 'temperloop install --yes' converges — no duplicate manifest entries, no spurious re-backups"

# ---------------------------------------------------------------------------
# Test 5: doctor.sh is green after a sandboxed install.
# ---------------------------------------------------------------------------
doctor_out="$(sandbox_run bash "$CHECKOUT_A/workflows/scripts/install/doctor.sh" "$CHECKOUT_A" 2>&1)"
doctor_rc=$?
[ "$doctor_rc" -eq 0 ] || fail "5: doctor.sh exited $doctor_rc after a sandboxed install (output: $doctor_out)"
echo "$doctor_out" | grep -q 'Non-OK: 0' || fail "5: doctor.sh should report 'Non-OK: 0' after a sandboxed install (got: $doctor_out)"

pass "5: doctor.sh is green (exit 0, Non-OK: 0) after a sandboxed 'temperloop install'"

sandbox_down

# ===========================================================================
# Sandbox B — a path pre-seeded with UNRELATED content BEFORE install ever
# runs is backed up (state=preexisting, explicit backup_path holding the
# ORIGINAL content/symlink verbatim), then correctly replaced.
# ===========================================================================
sandbox_up test-install-cli-b
sandbox_stub_gh
sandbox_stub_claude
sandbox_bootstrap_checkout "$REPO_ROOT" || fail "sandbox_bootstrap_checkout (B) failed"
[ -x "${SANDBOX_TEMPERLOOP:-}" ] || fail "B: SANDBOX_TEMPERLOOP not set/executable after bootstrap"

CHECKOUT_B="$(cd -P "$SANDBOX_HOME/.local/share/temperloop" && pwd)"
MANIFEST_B="$(manifest_file_for "$SANDBOX_XDG_STATE_HOME")"

# A real file where a managed SYMLINK is expected (a plain operator file, not
# a symlink) — proves the real-content backup path.
mkdir -p "$SANDBOX_HOME/.claude"
printf 'BOGUS PRIOR CONTENT — not managed by install yet\n' >"$SANDBOX_HOME/.claude/measurement-proxies.md"

# A WRONG symlink where a managed one is expected — proves cp -pPR backs up
# the symlink itself (not its dangling target).
mkdir -p "$SANDBOX_HOME/.local/bin"
ln -s "/nonexistent/wrong-target" "$SANDBOX_HOME/.local/bin/claim"

install_out_b="$(sandbox_run "$SANDBOX_TEMPERLOOP" install --yes 2>&1)"
install_rc_b=$?
[ "$install_rc_b" -eq 0 ] || fail "6: install --yes (B) exited $install_rc_b (output: $install_out_b)"

# --- real-file case: measurement-proxies.md -------------------------------
mp_target="$SANDBOX_HOME/.claude/measurement-proxies.md"
mp_entry="$(jq -c --arg p "$mp_target" '.paths[$p]' "$MANIFEST_B")"
[ "$(jq -r '.state' <<<"$mp_entry")" = "preexisting" ] \
  || fail "6: measurement-proxies.md should be recorded state=preexisting (entry: $mp_entry)"
mp_backup="$(jq -r '.backup_path' <<<"$mp_entry")"
[ -n "$mp_backup" ] && [ "$mp_backup" != "null" ] || fail "6: measurement-proxies.md should have a non-null backup_path"
[ -f "$mp_backup" ] || fail "6: recorded backup_path should exist on disk: $mp_backup"
[ "$(cat "$mp_backup")" = "BOGUS PRIOR CONTENT — not managed by install yet" ] \
  || fail "6: backup should hold the ORIGINAL content verbatim (got: $(cat "$mp_backup"))"
[ -L "$mp_target" ] || fail "6: measurement-proxies.md should now be a symlink (replaced after backup)"
[ "$(readlink "$mp_target")" = "$CHECKOUT_B/claude/measurement-proxies.md" ] \
  || fail "6: measurement-proxies.md symlink should point at the checkout's own copy"

# --- wrong-symlink case: claim ---------------------------------------------
claim_target="$SANDBOX_HOME/.local/bin/claim"
claim_entry="$(jq -c --arg p "$claim_target" '.paths[$p]' "$MANIFEST_B")"
[ "$(jq -r '.state' <<<"$claim_entry")" = "preexisting" ] \
  || fail "6: claim should be recorded state=preexisting (entry: $claim_entry)"
claim_backup="$(jq -r '.backup_path' <<<"$claim_entry")"
[ -L "$claim_backup" ] || fail "6: claim's backup_path should itself be a symlink (cp -pPR preserves it): $claim_backup"
[ "$(readlink "$claim_backup")" = "/nonexistent/wrong-target" ] \
  || fail "6: claim's backup should preserve the ORIGINAL (wrong) symlink target verbatim"
[ -L "$claim_target" ] || fail "6: claim should now be a symlink (replaced after backup)"
[ "$(readlink "$claim_target")" = "$CHECKOUT_B/workflows/scripts/board/claim.sh" ] \
  || fail "6: claim symlink should now point at the checkout's own board/claim.sh"

pass "6: a path pre-seeded with unrelated content/wrong-symlink BEFORE install is backed up verbatim (state=preexisting, explicit backup_path) and then correctly replaced"

sandbox_down

echo
echo "ALL PASS: test_install_cli.sh"
