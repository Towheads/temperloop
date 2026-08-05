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

# ── command_declared_capability (temperloop#1150) ────────────────────────────
# The second predicate: PRESENCE is discovered, CAPABILITY is declared. Every
# "I can't tell" answer must be false, so a kernel surface never spawns a
# command on an assumed capability (the retro-judge seam spawned an installed
# but headless-incapable `/retro` and got a success exit with zero judgments).
CAP="headless-unattended"

# --- 8. usage: a missing capability argument is rejected ---------------------
set +e
out8="$(command_declared_capability "$FIXTURE_NAME" 2>&1)"
rc8=$?
set -e
[ "$rc8" -eq 2 ] || fail "8: a missing capability argument should be rejected with rc 2 (got $rc8)"
case "$out8" in *"usage"*) : ;; *) fail "8: rejection message should be a usage notice (got: $out8)" ;; esac
echo "PASS: 8 command_declared_capability rejects a missing capability argument with rc 2"

# --- 9. a present-but-marker-less command file is NOT capable ----------------
C_CWD="$TMP/cap-cwd"; mkdir -p "$C_CWD/.claude/commands"
C_HOME="$TMP/cap-home"; mkdir -p "$C_HOME/.claude/commands"
printf 'A command with no capability marker at all.\n' > "$C_CWD/.claude/commands/$FIXTURE_NAME.md"
set +e
( cd "$C_CWD" && HOME="$C_HOME" command_declared_capability "$FIXTURE_NAME" "$CAP" )
rc9=$?
set -e
[ "$rc9" -ne 0 ] || fail "9: a command file with no marker must NOT be reported capable (got rc $rc9)"
echo "PASS: 9 a present-but-marker-less command file is not capable (presence != capability)"

# --- 10. the marker line, alone on its line, declares the capability ---------
printf '<!-- capability: %s -->\n' "$CAP" >> "$C_CWD/.claude/commands/$FIXTURE_NAME.md"
set +e
( cd "$C_CWD" && HOME="$C_HOME" command_declared_capability "$FIXTURE_NAME" "$CAP" )
rc10=$?
set -e
[ "$rc10" -eq 0 ] || fail "10: the marker line should declare the capability (got rc $rc10)"
echo "PASS: 10 a marker line, alone on its line, declares the capability"

# --- 11. a multi-token marker declares each of its tokens -------------------
M_CWD="$TMP/cap-multi"; mkdir -p "$M_CWD/.claude/commands"
printf '   <!-- capability: %s, no-merge  -->\n' "$CAP" > "$M_CWD/.claude/commands/$FIXTURE_NAME.md"
set +e
( cd "$M_CWD" && HOME="$C_HOME" command_declared_capability "$FIXTURE_NAME" "$CAP" ); rc11a=$?
( cd "$M_CWD" && HOME="$C_HOME" command_declared_capability "$FIXTURE_NAME" "no-merge" ); rc11b=$?
( cd "$M_CWD" && HOME="$C_HOME" command_declared_capability "$FIXTURE_NAME" "merges-everything" ); rc11c=$?
set -e
[ "$rc11a" -eq 0 ] && [ "$rc11b" -eq 0 ] || fail "11: a comma/space-separated marker should declare each token (got $rc11a/$rc11b)"
[ "$rc11c" -ne 0 ] || fail "11: an undeclared token must stay false (got rc $rc11c)"
echo "PASS: 11 a multi-token marker declares each of its tokens, and only those"

# --- 12. an INLINE mention (not alone on its line) declares nothing ----------
# The line-alone anchor is what lets prose, feature docs, and command specs
# explain the grammar without accidentally declaring the capability.
I_CWD="$TMP/cap-inline"; mkdir -p "$I_CWD/.claude/commands"
printf 'Add `<!-- capability: %s -->` to your command file to declare it.\n' "$CAP" \
  > "$I_CWD/.claude/commands/$FIXTURE_NAME.md"
set +e
( cd "$I_CWD" && HOME="$C_HOME" command_declared_capability "$FIXTURE_NAME" "$CAP" )
rc12=$?
set -e
[ "$rc12" -ne 0 ] || fail "12: an inline mention inside a sentence must not declare the capability (got rc $rc12)"
echo "PASS: 12 an inline/backticked mention of the marker declares nothing (line-alone anchor holds)"

# --- 13. an absent command file is not capable ------------------------------
A_CWD="$TMP/cap-absent"; mkdir -p "$A_CWD"
A_HOME="$TMP/cap-absent-home"; mkdir -p "$A_HOME"
set +e
( cd "$A_CWD" && HOME="$A_HOME" command_declared_capability "$FIXTURE_NAME" "$CAP" )
rc13=$?
set -e
[ "$rc13" -ne 0 ] || fail "13: an absent command file must not be reported capable (got rc $rc13)"
echo "PASS: 13 an absent command file is not capable (fail-closed)"

# --- 14. FIRST-RESOLVED FILE WINS -------------------------------------------
# The surface-1 file is what a runtime resolution lands on, so a capable copy
# on a LATER surface must not rescue a marker-less earlier one.
printf '<!-- capability: %s -->\n' "$CAP" > "$C_HOME/.claude/commands/$FIXTURE_NAME.md"
F_CWD="$TMP/cap-firstwins"; mkdir -p "$F_CWD/.claude/commands"
printf 'no marker here\n' > "$F_CWD/.claude/commands/$FIXTURE_NAME.md"
set +e
( cd "$F_CWD" && HOME="$C_HOME" command_declared_capability "$FIXTURE_NAME" "$CAP" )
rc14=$?
set -e
[ "$rc14" -ne 0 ] || fail "14: the first-resolved (surface 1) file must be authoritative (got rc $rc14)"
echo "PASS: 14 first-resolved file wins — a capable copy on a later surface does not rescue a marker-less earlier one"

# --- 15. COMMAND_CAPABILITY_OVERRIDE answers entirely from the env -----------
set +e
( cd "$F_CWD" && HOME="$C_HOME" COMMAND_CAPABILITY_OVERRIDE="$FIXTURE_NAME:$CAP" \
    command_declared_capability "$FIXTURE_NAME" "$CAP" ); rc15a=$?
( cd "$C_CWD" && HOME="$C_HOME" COMMAND_CAPABILITY_OVERRIDE="other:$CAP" \
    command_declared_capability "$FIXTURE_NAME" "$CAP" ); rc15b=$?
( cd "$C_CWD" && HOME="$C_HOME" COMMAND_CAPABILITY_OVERRIDE="" \
    command_declared_capability "$FIXTURE_NAME" "$CAP" ); rc15c=$?
set -e
[ "$rc15a" -eq 0 ] || fail "15: a listed <name>:<capability> pair should force true (got rc $rc15a)"
[ "$rc15b" -ne 0 ] || fail "15: an unlisted pair should force false despite a real marker on disk (got rc $rc15b)"
[ "$rc15c" -ne 0 ] || fail "15: a set-but-empty override should force false (got rc $rc15c)"
echo "PASS: 15 COMMAND_CAPABILITY_OVERRIDE answers entirely from the env (true, false, and set-but-empty)"

# --- 16. a presence override alone forces capability FALSE, hermetically -----
# A fixture that took control of the presence answer must not have the
# capability answer decided by whatever real files exist on the test host.
set +e
( cd "$C_CWD" && HOME="$C_HOME" COMMAND_DECLARED_OVERRIDE="$FIXTURE_NAME" \
    command_declared_capability "$FIXTURE_NAME" "$CAP" )
rc16=$?
set -e
[ "$rc16" -ne 0 ] || fail "16: COMMAND_DECLARED_OVERRIDE without a capability override should force false (got rc $rc16)"
echo "PASS: 16 a presence override with no capability override answers false without touching the filesystem"

echo "All command_declared.sh tests passed."
