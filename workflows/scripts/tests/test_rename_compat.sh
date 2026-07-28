#!/usr/bin/env bash
#
# test_rename_compat.sh — the foundation→temperloop rename AFTER its
# compatibility window closed (temperloop#165, gh #165 "rename stranger
# surfaces"; read-old window v0.15.0 → removed in v0.19.0). Proves, end to
# end and hermetically, that every legacy surface now fails or degrades
# LEGIBLY rather than silently — the half of the contract that outlives the
# window itself.
#
# Through the window this file proved READ-OLD-WRITE-NEW (a legacy env var
# or on-disk artifact was still adopted, with a NOTE) and simulated the
# post-window behavior behind an env seam. That seam is GONE with the window
# it simulated: what it staged is now the shipped behavior, asserted
# directly.
#
#   1. LEGACY-ENV INSTALL REFUSES: a bootstrap driven by the pre-rename
#      FOUNDATION_KERNEL_REPO / FOUNDATION_HOME / FOUNDATION_BIN_DIR vars
#      exits non-zero naming the TEMPERLOOP_* replacement + the removal
#      version, and installs NOTHING — never a silent install at a path the
#      caller did not ask for.
#   2. NEW-ENV INSTALL: the TEMPERLOOP_* names drive a clean install with
#      ZERO deprecation noise — and no `foundation` shim is put on PATH.
#   3. TWO INSTALLS AT ADJACENT TAGS AGAINST ONE REPO (fixture-based
#      simulation per test_update_subcommand.sh's conventions): `update`
#      carries the install across the tag boundary; a PRE-v0.19.0 install's
#      leftover `foundation` symlink still resolves — to a legible refusal,
#      not a dangling path — and a set legacy FOUNDATION_VERSION refuses at
#      the dispatcher.
#   4. LEGACY ON-DISK ARTIFACTS are no longer read: a pre-rename target
#      repo's .foundation/config makes init REFUSE, naming the migration; a
#      legacy $XDG_CONFIG_HOME/foundation/boards.conf is IGNORED by
#      board.sh's machine-conf probe with a NOTE naming it, and a
#      temperloop/ one is used silently when present. (The knowledge-store
#      root's identical removal is unit-tested in
#      workflows/scripts/lib/tests/test_knowledge_store.sh cases 2b–2d.)
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
# deterministic CHANGELOG and two adjacent tags (v9.1.0, v9.2.0). Leg 2
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
# 1. Legacy-env install REFUSES — legibly, and writes nothing.
# ===========================================================================
sandbox_env
LEGACY_HOME="$SANDBOX_HOME/legacy-install/share"
LEGACY_BIN="$SANDBOX_HOME/legacy-install/bin"

for var in FOUNDATION_KERNEL_REPO FOUNDATION_HOME FOUNDATION_BIN_DIR; do
  case "$var" in
    FOUNDATION_KERNEL_REPO) val="file://$FIXTURE_UPSTREAM"; new=TEMPERLOOP_KERNEL_REPO ;;
    FOUNDATION_HOME)        val="$LEGACY_HOME";             new=TEMPERLOOP_HOME ;;
    FOUNDATION_BIN_DIR)     val="$LEGACY_BIN";              new=TEMPERLOOP_BIN_DIR ;;
  esac
  # ONLY the legacy var is set: the refusal fires before bootstrap resolves
  # any default, clones anything, or touches the filesystem.
  boot_err="$SANDBOX_ROOT/boot-legacy-$var.err"
  rc=0
  env "${SANDBOX_ENV_ARGS[@]}" \
      "$var=$val" \
      sh "$FIXTURE_UPSTREAM/bin/bootstrap.sh" >/dev/null 2>"$boot_err" || rc=$?
  [ "$rc" -ne 0 ] || fail "1: bootstrap with \$$var set must exit non-zero (it is no longer read)"
  grep -q "\$$var is no longer read" "$boot_err" \
    || fail "1: the refusal must name \$$var as no longer read (stderr: $(cat "$boot_err"))"
  grep -q "$new" "$boot_err" || fail "1: the refusal must name the replacement \$$new"
  grep -q 'removed in v0.19.0' "$boot_err" || fail "1: the refusal must state the v0.19.0 removal"
  grep -q 'deprecated' "$boot_err" && fail "1: a refusal, not a deprecation NOTE (stderr: $(cat "$boot_err"))"
done
[ ! -d "$LEGACY_HOME" ] || fail "1: a refused bootstrap must install nothing"
[ ! -d "$LEGACY_BIN" ] || fail "1: a refused bootstrap must put nothing on PATH"
pass "1: each legacy FOUNDATION_* env var refuses legibly at bootstrap (names replacement + v0.19.0, installs nothing)"

# ===========================================================================
# 1b. SET-BUT-EMPTY boundary — the guards test NON-EMPTINESS, not set-ness,
#     mirroring bootstrap.sh's own `${VAR:-default}` resolution.
#
#     Case A (the serious one): TEMPERLOOP_HOME='' + FOUNDATION_HOME=<path>.
#     An empty new-name value resolves to the built-in default, so it is NOT
#     a value the caller asked for. Under a set-ness guard (`${VAR+x}`) the
#     refusal does NOT fire, bootstrap falls through to
#     $HOME/.local/share/temperloop, and the path the operator deliberately
#     set is SILENTLY DISCARDED — verbatim the failure bin/bootstrap.sh's
#     legacy-env comment says the detection exists to prevent. Must refuse.
#
#     Case B (the mirror): FOUNDATION_HOME='' + TEMPERLOOP_HOME unset. A
#     set-but-empty LEGACY var carries no value to discard, so a hard exit 1
#     would be wrong — and would disagree with bin/lib/common.sh's
#     temperloop_env_compat(), whose `legacy_val` check requires the legacy
#     var be non-empty. Must NOT refuse on the legacy var.
# ===========================================================================
caseA_err="$SANDBOX_ROOT/boot-caseA.err"
CASEA_HOME="$SANDBOX_HOME/caseA-asked-for"
rc=0
env "${SANDBOX_ENV_ARGS[@]}" \
    TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_UPSTREAM" \
    TEMPERLOOP_HOME= \
    FOUNDATION_HOME="$CASEA_HOME" \
    sh "$FIXTURE_UPSTREAM/bin/bootstrap.sh" >/dev/null 2>"$caseA_err" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "1b/A: TEMPERLOOP_HOME='' with FOUNDATION_HOME set must REFUSE — a set-ness guard falls through to the default and silently discards the path the caller asked for (stderr: $(cat "$caseA_err"))"
grep -q 'FOUNDATION_HOME is no longer read' "$caseA_err" \
  || fail "1b/A: the refusal must name \$FOUNDATION_HOME (stderr: $(cat "$caseA_err"))"
grep -q 'TEMPERLOOP_HOME' "$caseA_err" \
  || fail "1b/A: the refusal must name the replacement \$TEMPERLOOP_HOME"
[ ! -d "$CASEA_HOME" ] \
  || fail "1b/A: a refused bootstrap must install nothing at the legacy path"
[ ! -d "$SANDBOX_HOME/.local/share/temperloop" ] \
  || fail "1b/A: bootstrap must NOT have fallen through to the built-in default — that is the silent-discard failure this leg pins"
pass "1b/A: TEMPERLOOP_HOME='' + FOUNDATION_HOME=<path> refuses instead of silently discarding the asked-for path"

caseB_err="$SANDBOX_ROOT/boot-caseB.err"
CASEB_HOME="$SANDBOX_HOME/caseB-install/share"
CASEB_BIN="$SANDBOX_HOME/caseB-install/bin"
rc=0
env "${SANDBOX_ENV_ARGS[@]}" \
    TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_UPSTREAM" \
    TEMPERLOOP_HOME="$CASEB_HOME" \
    TEMPERLOOP_BIN_DIR="$CASEB_BIN" \
    FOUNDATION_HOME= \
    sh "$FIXTURE_UPSTREAM/bin/bootstrap.sh" >/dev/null 2>"$caseB_err" || rc=$?
[ "$rc" -eq 0 ] \
  || fail "1b/B: a set-but-EMPTY \$FOUNDATION_HOME carries no value to discard and must NOT hard-exit (bin/lib/common.sh's legacy_val check agrees) — rc=$rc, stderr: $(cat "$caseB_err")"
grep -q 'FOUNDATION_HOME is no longer read' "$caseB_err" \
  && fail "1b/B: an empty legacy var must not trigger the refusal (stderr: $(cat "$caseB_err"))"
pass "1b/B: a set-but-empty \$FOUNDATION_HOME does not refuse (agrees with bin/temperloop's temperloop_env_compat)"

# ===========================================================================
# 2. New-env install: TEMPERLOOP_* wins — zero deprecation noise, and no
#    `foundation` compat symlink on PATH any more. A legacy FOUNDATION_HOME
#    is ALSO set here on purpose: precedence is unchanged (a set TEMPERLOOP_*
#    primary wins SILENTLY), so the refusal in leg 1 fires only when the
#    caller has no new-name value at all — it never breaks a caller who has
#    already migrated but still carries a stale legacy export.
# ===========================================================================
NEW_HOME="$SANDBOX_HOME/new-install/share"
NEW_BIN="$SANDBOX_HOME/new-install/bin"
boot2_err="$SANDBOX_ROOT/boot-new.err"
env "${SANDBOX_ENV_ARGS[@]}" \
    TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_UPSTREAM" \
    TEMPERLOOP_HOME="$NEW_HOME" \
    TEMPERLOOP_BIN_DIR="$NEW_BIN" \
    FOUNDATION_HOME="$SANDBOX_HOME/should-be-ignored" \
    sh "$FIXTURE_UPSTREAM/bin/bootstrap.sh" >/dev/null 2>"$boot2_err" \
  || fail "2: TEMPERLOOP_* bootstrap must succeed even with a stale legacy export set (stderr: $(cat "$boot2_err"))"
[ ! -d "$SANDBOX_HOME/should-be-ignored" ] || fail "2: the shadowed legacy value must be ignored entirely"
[ -x "$NEW_BIN/temperloop" ] || fail "2: temperloop must land at TEMPERLOOP_BIN_DIR"
[ ! -e "$NEW_BIN/foundation" ] \
  || fail "2: a fresh install must NOT put a 'foundation' compat symlink on PATH any more"
grep -q 'deprecated' "$boot2_err" && fail "2: a TEMPERLOOP_*-driven install must print no deprecation NOTE (stderr: $(cat "$boot2_err"))"
pass "2: TEMPERLOOP_* env install works with zero deprecation noise and installs no 'foundation' shim"

# ===========================================================================
# 3. Adjacent tags, one repo: cut v9.2.0 upstream, then update the install.
#    A PRE-v0.19.0 install's leftover `foundation` symlink is simulated here
#    (bootstrap no longer makes one) and must resolve to a legible refusal —
#    the exact reason kernel/bin/foundation is kept as a tombstone rather
#    than deleted.
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

# A pre-v0.19.0 install would have left this symlink behind.
ln -sf "$NEW_HOME/bin/foundation" "$NEW_BIN/foundation"

update_out="$SANDBOX_ROOT/update.out"
if ! env "${SANDBOX_ENV_ARGS[@]}" "$NEW_BIN/temperloop" update --yes --to v9.2.0 \
    >"$update_out" 2>&1; then
  fail "3: 'temperloop update --yes --to v9.2.0' must succeed (output: $(tail -5 "$update_out"))"
fi
tag_now="$(git -C "$NEW_HOME" describe --tags --exact-match 2>/dev/null || true)"
[ "$tag_now" = "v9.2.0" ] || fail "3: the managed clone must sit at v9.2.0 after update (got: ${tag_now:-none})"

# The stale shim symlink still RESOLVES (the tombstone file is still shipped
# at the new tag) and refuses legibly — not a dangling "no such file".
shim_err="$SANDBOX_ROOT/shim.err"
rc=0
out="$(env "${SANDBOX_ENV_ARGS[@]}" "$NEW_BIN/foundation" --version 2>"$shim_err")" || rc=$?
[ "$rc" -ne 0 ] || fail "3b: a leftover 'foundation' symlink must refuse, not dispatch (got: $out)"
grep -q 'removed in v0.19.0' "$shim_err" || fail "3b: the shim refusal must state the v0.19.0 removal"
grep -q "temperloop" "$shim_err" || fail "3b: the shim refusal must name 'temperloop'"
grep -qi 'no such file' "$shim_err" && fail "3b: the shim symlink must not dangle (stderr: $(cat "$shim_err"))"
pass "3: install updates across adjacent tags; a leftover 'foundation' symlink refuses legibly instead of dangling"

# A set legacy FOUNDATION_VERSION is refused at the dispatcher, not adopted.
rc=0
ver_err="$SANDBOX_ROOT/version-legacy.err"
out="$(env "${SANDBOX_ENV_ARGS[@]}" FOUNDATION_VERSION=9.2.0-fixture "$NEW_BIN/temperloop" --version 2>"$ver_err")" || rc=$?
[ "$rc" -ne 0 ] || fail "3c: a set legacy FOUNDATION_VERSION must refuse, not be honored (got: $out)"
grep -q 'FOUNDATION_VERSION is no longer read' "$ver_err" \
  || fail "3c: the refusal must name \$FOUNDATION_VERSION as no longer read (stderr: $(cat "$ver_err"))"
grep -q 'TEMPERLOOP_VERSION' "$ver_err" || fail "3c: the refusal must name the replacement \$TEMPERLOOP_VERSION"
pass "3c: a legacy FOUNDATION_VERSION refuses at the dispatcher (never silently ignored, never adopted)"

# ===========================================================================
# 4. Legacy on-disk artifacts are no longer READ by new code.
# ===========================================================================
# 4a. A pre-rename target repo's .foundation/config makes init REFUSE,
#     naming the migration — never a silent fresh-manifest restart on top of
#     forgotten legacy state.
TARGET="$SANDBOX_ROOT/target-repo"
mkdir -p "$TARGET"
git -C "$TARGET" init -q -b main
(cd "$TARGET" && git commit -q --allow-empty -m init)
mkdir -p "$TARGET/.foundation"
jq -n '{schema:1, generated_at:"2026-01-01T00:00:00Z", installs:[], tracker:{board:42}}' \
  > "$TARGET/.foundation/config"

rc=0
init_out="$SANDBOX_ROOT/init-legacy.out"
env "${SANDBOX_ENV_ARGS[@]}" bash "$NEW_HOME/bin/subcommands/init.sh" \
    --dir "$TARGET" --dry-run --no-network >"$init_out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "4a: init over a legacy .foundation/config must refuse (output: $(tail -5 "$init_out"))"
grep -q 'removed in v0.19.0' "$init_out" || fail "4a: init's refusal must name the removal version"
grep -q 'git mv .foundation .temperloop' "$init_out" || fail "4a: init's refusal must name the migration step"
grep -q 'reading legacy' "$init_out" && fail "4a: init must NOT read the legacy config any more (output: $(tail -5 "$init_out"))"
[ ! -e "$TARGET/.temperloop" ] || fail "4a: a refused init must not create .temperloop/"
pass "4a: init refuses on a pre-rename .foundation/config, naming the migration, and writes nothing"

# 4b. board.sh's machine-conf probe: legacy-only -> the NEW path, with the
#     stranded legacy file named on stderr; a present temperloop/ one is used
#     silently (nothing stranded, nothing to report).
BOARD_SH="$NEW_HOME/workflows/scripts/board/lib/board.sh"
XDGC="$SANDBOX_XDG_CONFIG_HOME"
mkdir -p "$XDGC/foundation"
printf 'board.42.repo=acme/legacy\n' > "$XDGC/foundation/boards.conf"
probe_err="$SANDBOX_ROOT/board-legacy.err"
got="$(env "${SANDBOX_ENV_ARGS[@]}" bash -c "source '$BOARD_SH' >/dev/null 2>&1; _board_machine_conf_default" 2>"$probe_err")" \
  || fail "4b: sourcing board.sh for the probe failed"
[ "$got" = "$XDGC/temperloop/boards.conf" ] \
  || fail "4b: a legacy-only machine conf must NOT be returned any more (got: $got)"
grep -q 'no longer read' "$probe_err" || fail "4b: the ignored legacy conf must be named on stderr"
grep -q "$XDGC/foundation/boards.conf" "$probe_err" || fail "4b: the NOTE must name the legacy file's path"
grep -q 'v0.19.0' "$probe_err" || fail "4b: the NOTE must name the removal version"

mkdir -p "$XDGC/temperloop"
printf 'board.42.repo=acme/new\n' > "$XDGC/temperloop/boards.conf"
probe2_err="$SANDBOX_ROOT/board-new.err"
got="$(env "${SANDBOX_ENV_ARGS[@]}" bash -c "source '$BOARD_SH' >/dev/null 2>&1; _board_machine_conf_default" 2>"$probe2_err")"
[ "$got" = "$XDGC/temperloop/boards.conf" ] \
  || fail "4b: with both machine confs, the temperloop/ one must win (got: $got)"
[ ! -s "$probe2_err" ] \
  || fail "4b: with the new conf present there is nothing stranded — the probe must stay silent (got: $(cat "$probe2_err"))"
pass "4b: board.sh ignores a legacy foundation/ machine conf and names it; temperloop/ wins silently when present"

# ===========================================================================
# Tripwire re-check: this repo's own git state is untouched.
# ===========================================================================
[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$repo_root_head_before" ] \
  || fail "tripwire: \$REPO_ROOT HEAD moved during the test"
[ "$(git -C "$REPO_ROOT" status --porcelain)" = "$repo_root_status_before" ] \
  || fail "tripwire: \$REPO_ROOT working tree changed during the test"

sandbox_down
echo "ALL PASS: test_rename_compat.sh"
