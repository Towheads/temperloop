#!/usr/bin/env bash
#
# Tests for command_declared.sh — the shared "is slash command <name>
# available" predicate (ADR 0008, temperloop#537). Zero network. Covers all
# three resolution surfaces plus the env-override fixture escape hatch,
# using a fixture command name guaranteed absent from this real checkout's
# own claude/commands/ (see FIXTURE_NAME below) so the real filesystem never
# leaks a false positive into a case that expects one specific surface only.
#
# Surface 2 (the kernel checkout's claude/commands/, resolved via `git
# rev-parse --show-toplevel` from the LIB FILE'S OWN location) cannot be
# exercised against this real checkout without polluting it, so that case
# sources a COPY of the lib planted inside a throwaway git repo under TMP —
# `${BASH_SOURCE[0]}` inside a sourced function reflects the path passed to
# `source`, so sourcing the copy makes the checkout-root resolution point at
# the throwaway repo instead of the real one.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# A name that does not exist under this real checkout's claude/commands/,
# nor (presumably) under the real $HOME/.claude/commands/ -- picked
# deliberately unusual so it can never collide with a real command.
FIXTURE_NAME="zzz-command-declared-fixture-probe"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/command-declared-test-XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# shellcheck source=scripts/lib/command_declared.sh
source "$LIB_DIR/command_declared.sh"

# --- 0. usage: empty name is rejected -----------------------------------------
set +e
out0="$(command_declared "" 2>&1)"
rc0=$?
set -e
[ "$rc0" -eq 2 ] || fail "0: an empty name should be rejected with rc 2 (got $rc0)"
case "$out0" in
  *"usage"*) : ;;
  *) fail "0: rejection message should be a usage notice (got: $out0)" ;;
esac
echo "PASS: 0 command_declared rejects an empty name"

# --- 1. false when the name exists at none of the three surfaces -------------
FAKE_CWD="$TMP/cwd-none"; mkdir -p "$FAKE_CWD"
FAKE_HOME="$TMP/home-none"; mkdir -p "$FAKE_HOME"
unset COMMAND_DECLARED_OVERRIDE
set +e
( cd "$FAKE_CWD" && HOME="$FAKE_HOME" command_declared "$FIXTURE_NAME" )
rc1=$?
set -e
[ "$rc1" -ne 0 ] || fail "1: expected false (non-zero) when the name exists nowhere (got rc $rc1)"
echo "PASS: 1 command_declared is false when the name exists at none of the three surfaces"

# --- 2. true via surface 1: \$PWD/.claude/commands/<name>.md -----------------
S1_CWD="$TMP/cwd-surface1"
mkdir -p "$S1_CWD/.claude/commands"
: > "$S1_CWD/.claude/commands/$FIXTURE_NAME.md"
S1_HOME="$TMP/home-surface1"; mkdir -p "$S1_HOME"
set +e
( cd "$S1_CWD" && HOME="$S1_HOME" command_declared "$FIXTURE_NAME" )
rc2=$?
set -e
[ "$rc2" -eq 0 ] || fail "2: expected true via surface 1 (cwd .claude/commands/) (got rc $rc2)"
echo "PASS: 2 command_declared is true when <name>.md exists under \$PWD/.claude/commands/"

# --- 3. true via surface 3: \$HOME/.claude/commands/<name>.md ----------------
S3_CWD="$TMP/cwd-surface3"; mkdir -p "$S3_CWD"
S3_HOME="$TMP/home-surface3"
mkdir -p "$S3_HOME/.claude/commands"
: > "$S3_HOME/.claude/commands/$FIXTURE_NAME.md"
set +e
( cd "$S3_CWD" && HOME="$S3_HOME" command_declared "$FIXTURE_NAME" )
rc3=$?
set -e
[ "$rc3" -eq 0 ] || fail "3: expected true via surface 3 (\$HOME/.claude/commands/) (got rc $rc3)"
echo "PASS: 3 command_declared is true when <name>.md exists under \$HOME/.claude/commands/"

# --- 4. true via surface 2: <checkout>/claude/commands/<name>.md -------------
# Built against a COPY of the lib planted inside a throwaway git repo, so
# checkout-root resolution (git rev-parse --show-toplevel from the lib
# file's own location) points at the throwaway repo, not this real one.
FAKE_CHECKOUT="$TMP/fake-checkout"
mkdir -p "$FAKE_CHECKOUT/workflows/scripts/lib" "$FAKE_CHECKOUT/claude/commands"
git init -q "$FAKE_CHECKOUT"
cp "$LIB_DIR/command_declared.sh" "$FAKE_CHECKOUT/workflows/scripts/lib/command_declared.sh"
: > "$FAKE_CHECKOUT/claude/commands/$FIXTURE_NAME.md"
S4_CWD="$TMP/cwd-surface2"; mkdir -p "$S4_CWD"
S4_HOME="$TMP/home-surface2"; mkdir -p "$S4_HOME"
out4="$(
  cd "$S4_CWD" && HOME="$S4_HOME" bash -c '
    set -euo pipefail
    unset COMMAND_DECLARED_OVERRIDE
    # shellcheck source=/dev/null
    source "'"$FAKE_CHECKOUT"'/workflows/scripts/lib/command_declared.sh"
    if command_declared "'"$FIXTURE_NAME"'"; then echo TRUE; else echo FALSE; fi
  '
)"
[ "$out4" = "TRUE" ] || fail "4: expected true via surface 2 (checkout claude/commands/) (got: $out4)"
echo "PASS: 4 command_declared is true when <name>.md exists under <checkout>/claude/commands/ (resolved from the lib's own location)"

# --- 5. env override forces TRUE regardless of real filesystem state ---------
NONE_CWD="$TMP/cwd-override-true"; mkdir -p "$NONE_CWD"
NONE_HOME="$TMP/home-override-true"; mkdir -p "$NONE_HOME"
set +e
( cd "$NONE_CWD" && HOME="$NONE_HOME" COMMAND_DECLARED_OVERRIDE="$FIXTURE_NAME other-cmd" command_declared "$FIXTURE_NAME" )
rc5=$?
set -e
[ "$rc5" -eq 0 ] || fail "5: COMMAND_DECLARED_OVERRIDE listing the name should force true (got rc $rc5)"
echo "PASS: 5 COMMAND_DECLARED_OVERRIDE forces a true answer when the name is listed"

# --- 6. env override forces FALSE for a name not in the list -----------------
set +e
( cd "$S1_CWD" && HOME="$S1_HOME" COMMAND_DECLARED_OVERRIDE="some-other-cmd" command_declared "$FIXTURE_NAME" )
rc6=$?
set -e
[ "$rc6" -ne 0 ] || fail "6: COMMAND_DECLARED_OVERRIDE not listing the name should force false, even though surface 1 has a real file (got rc $rc6)"
echo "PASS: 6 COMMAND_DECLARED_OVERRIDE forces a false answer for an unlisted name, overriding a real matching file on disk"

# --- 7. env override set-but-empty forces FALSE for everything ---------------
set +e
( cd "$S1_CWD" && HOME="$S1_HOME" COMMAND_DECLARED_OVERRIDE="" command_declared "$FIXTURE_NAME" )
rc7=$?
set -e
[ "$rc7" -ne 0 ] || fail "7: a set-but-empty COMMAND_DECLARED_OVERRIDE should force false (got rc $rc7)"
echo "PASS: 7 a set-but-empty COMMAND_DECLARED_OVERRIDE forces false, overriding a real matching file on disk"

echo "All command_declared.sh tests passed."
