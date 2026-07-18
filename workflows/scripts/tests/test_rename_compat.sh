#!/usr/bin/env bash
#
# test_rename_compat.sh — the foundation→temperloop rename window
# (temperloop#165, gh #165 "rename stranger surfaces", v0.15.0): proves the
# READ-OLD-WRITE-NEW contract end to end, hermetically.
#
#   1. LEGACY-ENV INSTALL: a bootstrap driven entirely by the pre-rename
#      FOUNDATION_KERNEL_REPO / FOUNDATION_HOME / FOUNDATION_BIN_DIR env
#      vars still installs correctly (new > old > default precedence), and
#      each legacy var used surfaces a one-line deprecation NOTE naming its
#      TEMPERLOOP_* replacement + the v0.17.0 removal.
#   2. NEW-ENV INSTALL: the TEMPERLOOP_* names drive the same install with
#      ZERO deprecation noise.
#   3. TWO INSTALLS AT ADJACENT TAGS AGAINST ONE REPO (fixture-based
#      simulation per test_update_subcommand.sh's conventions): the
#      legacy-env install made at tag A is carried to tag B by `update`
#      invoked through the legacy `foundation` shim — the old-named install
#      keeps working across the tag boundary, deprecation still surfaced,
#      never silently broken.
#   4. LEGACY ON-DISK ARTIFACTS (read-old): a pre-rename target repo's
#      .foundation/config is read by the new init (with a NOTE, board
#      number carried forward); a legacy $XDG_CONFIG_HOME/foundation/
#      boards.conf is resolved by board.sh's machine-conf probe, and a
#      temperloop/ one wins when both exist. (The knowledge-store root's
#      identical window is unit-tested in
#      workflows/scripts/lib/tests/test_knowledge_store.sh cases 2b–2d.)
#   5. COLD INSTALL PAST WINDOW CLOSE (TEMPERLOOP_LEGACY_WINDOW_CLOSED=1,
#      the post-v0.17.0 simulation seam): every legacy surface degrades
#      LEGIBLY — bootstrap refuses with the rename + removal version and
#      installs nothing; init refuses on a legacy config naming the
#      migration; board.sh ignores the legacy machine conf with a NOTE —
#      never a silent success against stale state.
#
# Zero network: every clone/fetch is file:// against a fixture clone of
# this repo's own committed tree, HOME/XDG re-pointed by the sandbox lib
# (workflows/scripts/tests/lib/sandbox.sh).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

# shellcheck source=lib/sandbox.sh
source "$HERE/lib/sandbox.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

# Tripwire on $REPO_ROOT's own git state (same SAFETY convention as
# test_update_subcommand.sh) — snapshotted before any fixture setup.
repo_root_head_before="$(git -C "$REPO_ROOT" rev-parse HEAD)"
repo_root_status_before="$(git -C "$REPO_ROOT" status --porcelain)"

sandbox_up test-rename-compat

# ===========================================================================
# Fixture upstream: a --no-tags clone of THIS repo's committed tree with a
# deterministic CHANGELOG and two adjacent tags (v9.1.0, v9.2.0). Leg 1
# bootstraps from the v9.1.0-era tip; leg 3 updates the same install to
# v9.2.0.
# ===========================================================================
FIXTURE_UPSTREAM="$SANDBOX_ROOT/fixture-upstream"
git clone -q --no-tags "$REPO_ROOT" "$FIXTURE_UPSTREAM" \
  || fail "fixture: could not clone $REPO_ROOT"

cat > "$FIXTURE_UPSTREAM/CHANGELOG.md" <<'EOF'
# Changelog (fixture — test_rename_compat.sh)

## [Unreleased]

## [9.1.0] - 2026-01-01

### Added

- Fixture baseline release (tag A of the adjacent-tag pair).
EOF
git -C "$FIXTURE_UPSTREAM" add CHANGELOG.md
git -C "$FIXTURE_UPSTREAM" commit -q -m "fixture: baseline changelog (v9.1.0)"
git -C "$FIXTURE_UPSTREAM" tag -a v9.1.0 -m v9.1.0

# ===========================================================================
# 1. Legacy-env install: FOUNDATION_* only, window open.
# ===========================================================================
LEGACY_HOME="$SANDBOX_HOME/legacy-install/share"
LEGACY_BIN="$SANDBOX_HOME/legacy-install/bin"

sandbox_env
boot_err="$SANDBOX_ROOT/boot-legacy.err"
env "${SANDBOX_ENV_ARGS[@]}" \
    FOUNDATION_KERNEL_REPO="file://$FIXTURE_UPSTREAM" \
    FOUNDATION_HOME="$LEGACY_HOME" \
    FOUNDATION_BIN_DIR="$LEGACY_BIN" \
    sh "$FIXTURE_UPSTREAM/bin/bootstrap.sh" >"$SANDBOX_ROOT/boot-legacy.out" 2>"$boot_err" \
  || fail "1: legacy-env bootstrap must succeed through the window (stderr: $(cat "$boot_err"))"

[ -x "$LEGACY_BIN/temperloop" ] || fail "1: temperloop must be symlinked into the legacy-named FOUNDATION_BIN_DIR"
[ -x "$LEGACY_BIN/foundation" ] || fail "1: the foundation compat shim must be symlinked too"
[ -d "$LEGACY_HOME/.git" ] || fail "1: the checkout must land at the legacy-named FOUNDATION_HOME"
for var in FOUNDATION_KERNEL_REPO FOUNDATION_HOME FOUNDATION_BIN_DIR; do
  grep -q "NOTE — \$$var is deprecated" "$boot_err" \
    || fail "1: bootstrap must print a deprecation NOTE for $var (stderr: $(cat "$boot_err"))"
done
grep -q 'removed in v0.17.0' "$boot_err" || fail "1: the NOTEs must state the v0.17.0 removal"
pass "1: legacy FOUNDATION_* env install works, with per-var deprecation NOTEs naming the window"

# The shim dispatches, and says it is deprecated.
shim_err="$SANDBOX_ROOT/shim.err"
out="$(env "${SANDBOX_ENV_ARGS[@]}" "$LEGACY_BIN/foundation" --version 2>"$shim_err")" \
  || fail "1b: 'foundation --version' via the shim must still work"
case "$out" in temperloop*) ;; *) fail "1b: shim must dispatch to temperloop (got: $out)" ;; esac
grep -q "deprecated alias for 'temperloop'" "$shim_err" || fail "1b: shim must print its deprecation NOTE"
pass "1b: 'foundation' shim dispatches to temperloop and surfaces its deprecation"

# ===========================================================================
# 2. New-env install: TEMPERLOOP_* only — zero deprecation noise.
# ===========================================================================
NEW_HOME="$SANDBOX_HOME/new-install/share"
NEW_BIN="$SANDBOX_HOME/new-install/bin"
boot2_err="$SANDBOX_ROOT/boot-new.err"
env "${SANDBOX_ENV_ARGS[@]}" \
    TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_UPSTREAM" \
    TEMPERLOOP_HOME="$NEW_HOME" \
    TEMPERLOOP_BIN_DIR="$NEW_BIN" \
    sh "$FIXTURE_UPSTREAM/bin/bootstrap.sh" >/dev/null 2>"$boot2_err" \
  || fail "2: TEMPERLOOP_* bootstrap must succeed (stderr: $(cat "$boot2_err"))"
[ -x "$NEW_BIN/temperloop" ] || fail "2: temperloop must land at TEMPERLOOP_BIN_DIR"
grep -q 'deprecated' "$boot2_err" && fail "2: a TEMPERLOOP_*-driven install must print no deprecation NOTE (stderr: $(cat "$boot2_err"))"
pass "2: TEMPERLOOP_* env install works with zero deprecation noise"

# ===========================================================================
# 3. Adjacent tags, one repo: cut v9.2.0 upstream, then update the LEGACY
#    install to it through the legacy shim. The old-named install must keep
#    working at the new tag.
# ===========================================================================
cat > "$FIXTURE_UPSTREAM/CHANGELOG.md" <<'EOF'
# Changelog (fixture — test_rename_compat.sh)

## [Unreleased]

## [9.2.0] - 2026-01-02

### Added

- Fixture follow-on release (tag B of the adjacent-tag pair). Additive —
  no BREAKING marker, so the update's unattended path stays open.

## [9.1.0] - 2026-01-01

### Added

- Fixture baseline release (tag A of the adjacent-tag pair).
EOF
git -C "$FIXTURE_UPSTREAM" add CHANGELOG.md
git -C "$FIXTURE_UPSTREAM" commit -q -m "fixture: v9.2.0 changelog"
git -C "$FIXTURE_UPSTREAM" tag -a v9.2.0 -m v9.2.0

update_out="$SANDBOX_ROOT/update.out"
if ! env "${SANDBOX_ENV_ARGS[@]}" "$LEGACY_BIN/foundation" update --yes --to v9.2.0 \
    >"$update_out" 2>&1; then
  fail "3: 'foundation update --yes --to v9.2.0' must succeed (output: $(tail -5 "$update_out"))"
fi
tag_now="$(git -C "$LEGACY_HOME" describe --tags --exact-match 2>/dev/null || true)"
[ "$tag_now" = "v9.2.0" ] || fail "3: the managed clone must sit at v9.2.0 after update (got: ${tag_now:-none})"

# Post-update, the legacy entrypoint + legacy env vars still work — and the
# deprecation is STILL surfaced (the window is open, not silently absorbed).
post_err="$SANDBOX_ROOT/post-update.err"
out="$(env "${SANDBOX_ENV_ARGS[@]}" FOUNDATION_VERSION=9.2.0-fixture "$LEGACY_BIN/foundation" --version 2>"$post_err")" \
  || fail "3b: shim dispatch must still work at the new tag"
[ "$out" = "temperloop 9.2.0-fixture" ] || fail "3b: a legacy FOUNDATION_VERSION env var must still be honored (got: $out)"
grep -q 'FOUNDATION_VERSION is deprecated' "$post_err" || fail "3b: the legacy env var must still surface its deprecation NOTE"
pass "3: legacy-env install updates across adjacent tags via the shim and keeps working, deprecation still surfaced"

# ===========================================================================
# 4. Legacy on-disk artifacts are READ by new code (window open).
# ===========================================================================
# 4a. A pre-rename target repo's .foundation/config: init --dry-run reads
#     it (NOTE + board carried forward) and would write .temperloop/config.
TARGET="$SANDBOX_ROOT/target-repo"
mkdir -p "$TARGET"
git -C "$TARGET" init -q -b main
(cd "$TARGET" && git commit -q --allow-empty -m init)
mkdir -p "$TARGET/.foundation"
jq -n '{schema:1, generated_at:"2026-01-01T00:00:00Z", installs:[], tracker:{board:42}}' \
  > "$TARGET/.foundation/config"

init_out="$SANDBOX_ROOT/init-legacy.out"
env "${SANDBOX_ENV_ARGS[@]}" bash "$LEGACY_HOME/bin/subcommands/init.sh" \
    --dir "$TARGET" --dry-run --no-network >"$init_out" 2>&1 \
  || fail "4a: init --dry-run over a legacy .foundation/config must succeed (output: $(tail -5 "$init_out"))"
grep -q 'reading legacy .foundation/config' "$init_out" || fail "4a: init must NOTE it is reading the legacy config"
grep -q 'Found existing .foundation/config' "$init_out" || fail "4a: init must merge the legacy install manifest"
grep -q 'board\.42\.' "$init_out" || fail "4a: the legacy config's board number must carry forward"
[ ! -e "$TARGET/.temperloop" ] || fail "4a: --dry-run must not create .temperloop/"
pass "4a: init reads a pre-rename .foundation/config with a NOTE; board number carries forward; writes go new-name"

# 4b. board.sh's machine-conf probe: legacy-only -> legacy; both -> new.
BOARD_SH="$LEGACY_HOME/workflows/scripts/board/lib/board.sh"
XDGC="$SANDBOX_XDG_CONFIG_HOME"
mkdir -p "$XDGC/foundation"
printf 'board.42.repo=acme/legacy\n' > "$XDGC/foundation/boards.conf"
got="$(env "${SANDBOX_ENV_ARGS[@]}" bash -c "source '$BOARD_SH' >/dev/null 2>&1; _board_machine_conf_default")" \
  || fail "4b: sourcing board.sh for the probe failed"
[ "$got" = "$XDGC/foundation/boards.conf" ] \
  || fail "4b: with only a legacy machine conf, the probe must return it (got: $got)"
mkdir -p "$XDGC/temperloop"
printf 'board.42.repo=acme/new\n' > "$XDGC/temperloop/boards.conf"
got="$(env "${SANDBOX_ENV_ARGS[@]}" bash -c "source '$BOARD_SH' >/dev/null 2>&1; _board_machine_conf_default")"
[ "$got" = "$XDGC/temperloop/boards.conf" ] \
  || fail "4b: with both machine confs, the temperloop/ one must win (got: $got)"
pass "4b: board.sh machine-conf probe reads the legacy foundation/ subdir, and temperloop/ wins when both exist"

# ===========================================================================
# 5. Cold install past window close (TEMPERLOOP_LEGACY_WINDOW_CLOSED=1):
#    legible degradation, never silent breakage.
# ===========================================================================
# 5a. Bootstrap with a legacy env var refuses, names the replacement +
#     version, and installs nothing.
CLOSED_HOME="$SANDBOX_HOME/closed-install/share"
closed_err="$SANDBOX_ROOT/boot-closed.err"
rc=0
env "${SANDBOX_ENV_ARGS[@]}" \
    TEMPERLOOP_LEGACY_WINDOW_CLOSED=1 \
    FOUNDATION_KERNEL_REPO="file://$FIXTURE_UPSTREAM" \
    FOUNDATION_HOME="$CLOSED_HOME" \
    sh "$FIXTURE_UPSTREAM/bin/bootstrap.sh" >/dev/null 2>"$closed_err" || rc=$?
[ "$rc" -ne 0 ] || fail "5a: window-closed bootstrap with a legacy env var must exit non-zero"
grep -q 'no longer read' "$closed_err" || fail "5a: the refusal must say the legacy var is no longer read"
grep -q 'TEMPERLOOP_KERNEL_REPO' "$closed_err" || fail "5a: the refusal must name the replacement var"
grep -q 'removed in v0.17.0' "$closed_err" || fail "5a: the refusal must name the removal version"
[ ! -d "$CLOSED_HOME" ] || fail "5a: a refused bootstrap must install nothing"
pass "5a: window-closed bootstrap refuses legibly (names replacement + v0.17.0, installs nothing)"

# 5b. init over a legacy config refuses legibly.
rc=0
init_closed="$SANDBOX_ROOT/init-closed.out"
env "${SANDBOX_ENV_ARGS[@]}" TEMPERLOOP_LEGACY_WINDOW_CLOSED=1 \
    bash "$LEGACY_HOME/bin/subcommands/init.sh" --dir "$TARGET" --dry-run --no-network \
    >"$init_closed" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "5b: window-closed init over a legacy .foundation/config must refuse"
grep -q 'removed in v0.17.0' "$init_closed" || fail "5b: init's refusal must name the removal version"
grep -q 'git mv .foundation .temperloop' "$init_closed" || fail "5b: init's refusal must name the migration step"
pass "5b: window-closed init refuses legibly on a legacy config, naming the migration"

# 5c. board.sh ignores the legacy machine conf with a NOTE (never silently).
rm -f "$XDGC/temperloop/boards.conf"
probe_err="$SANDBOX_ROOT/board-closed.err"
got="$(env "${SANDBOX_ENV_ARGS[@]}" TEMPERLOOP_LEGACY_WINDOW_CLOSED=1 \
  bash -c "source '$BOARD_SH' >/dev/null 2>&1; _board_machine_conf_default" 2>"$probe_err")"
[ "$got" = "$XDGC/temperloop/boards.conf" ] \
  || fail "5c: window-closed probe must resolve the new path (got: $got)"
grep -q 'no longer read' "$probe_err" || fail "5c: the ignored legacy conf must be named on stderr"
grep -q 'v0.17.0' "$probe_err" || fail "5c: the NOTE must name the removal version"
pass "5c: window-closed board.sh names the ignored legacy machine conf (never a silent miss)"

# ===========================================================================
# Tripwire re-check: this repo's own git state is untouched.
# ===========================================================================
[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$repo_root_head_before" ] \
  || fail "tripwire: \$REPO_ROOT HEAD moved during the test"
[ "$(git -C "$REPO_ROOT" status --porcelain)" = "$repo_root_status_before" ] \
  || fail "tripwire: \$REPO_ROOT working tree changed during the test"

sandbox_down
echo "ALL PASS: test_rename_compat.sh"
