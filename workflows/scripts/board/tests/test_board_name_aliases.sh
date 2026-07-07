#!/usr/bin/env bash
#
# Tests for board.sh's board NAME alias resolver (temperloop #95). Every --board
# switch (and every lib resolve entrypoint) now accepts a board NAME as well as
# its logical number, so a human never has to touch the private number space.
# board_resolve_name is the ONE shared resolver: it maps a name -> number at the
# boundary and passes a bare integer straight through unchanged (the number stays
# the sole internal key — nothing downstream is name-aware).
#
# Coverage (the four acceptance paths + the shared-resolver wiring):
#   1. numeric-unchanged  — a bare integer --board value passes through untouched
#                           (full backward compatibility; the sole internal key).
#   2. name-hit           — a built-in name resolves to its number, case-insens.
#   3. name-miss          — an unknown name errors to stderr WITH the known-names
#                           list, rc 2 (and never reaches gh at an entrypoint).
#   4. no-conf-fallback   — with NO boards.conf, the built-in name map answers
#                           exactly (a consuming repo with a synced board.sh and
#                           no conf behaves identically — the #770 seam contract).
#   5. boards.conf name axis — a `board.<N>.name=<slug>` line adds/overrides a
#                           name; its slug shows up in the known-names error list.
#   6. lib-entrypoint wiring — board_resolve / board_resolve_item / board_item_list
#                           all resolve a NAME argument identically to its number.
#   7. CLI-entrypoint wiring — worklist / capture / claim / milestone all route
#                           --board through the resolver (unknown name -> rc 2,
#                           known-names list, zero gh calls).
#
# NOTE ON FIXTURES: this file is NOT on the personal-token-denylist exempt list,
# so it must contain NO real org/identity tokens. Board APP names
# (stagefind/foundation/…) and logical numbers are explicitly NOT denylisted
# (they are illustrative pipeline examples — see personal-token-denylist.tsv's
# header); the boards.conf fixture uses the generic placeholder org `acme/widget`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Point the conf discovery at nonexistent files for the fallback cases; the conf
# case below overrides BOARDS_CONF_REPO_LOCAL to a real fixture.
export BOARDS_CONF_MACHINE="/no-such-machine-conf-$$"
export BOARDS_CONF_REPO_LOCAL="/no-such-repo-local-conf-$$"

# shellcheck source=scripts/lib/board.sh
source "$LIB_DIR/board.sh"

# --- 1: numeric-unchanged (backward compatibility) -------------------------
[ "$(board_resolve_name 3)" = "3" ] || fail "numeric 3 not passed through unchanged"
[ "$(board_resolve_name 4)" = "4" ] || fail "numeric 4 not passed through unchanged"
[ "$(board_resolve_name 99)" = "99" ] || fail "numeric 99 (unmapped) not passed through — number is the sole internal key"
echo "PASS: a bare integer --board value passes through the resolver unchanged"

# --- 2: name-hit (built-in map), case-insensitive --------------------------
[ "$(board_resolve_name stagefind)" = "3" ]  || fail "name 'stagefind' did not resolve to 3"
[ "$(board_resolve_name foundation)" = "4" ] || fail "name 'foundation' did not resolve to 4"
[ "$(board_resolve_name ssmobile)" = "5" ]   || fail "name 'ssmobile' did not resolve to 5"
[ "$(board_resolve_name subsetwiki)" = "6" ] || fail "name 'subsetwiki' did not resolve to 6"
[ "$(board_resolve_name kernel)" = "7" ]     || fail "name 'kernel' did not resolve to 7"
[ "$(board_resolve_name temperloop)" = "7" ] || fail "alias 'temperloop' did not resolve to 7"
[ "$(board_resolve_name Foundation)" = "4" ] || fail "name resolution is not case-insensitive (Foundation)"
[ "$(board_resolve_name FOUNDATION)" = "4" ] || fail "name resolution is not case-insensitive (FOUNDATION)"
echo "PASS: built-in board names resolve to their numbers, case-insensitively"

# The three name forms of the SAME board resolve identically to the number ---
n_num="$(board_resolve_name 4)"; n_low="$(board_resolve_name foundation)"; n_mix="$(board_resolve_name Foundation)"
[ "$n_num" = "$n_low" ] && [ "$n_low" = "$n_mix" ] \
  || fail "foundation / Foundation / 4 did not all resolve identically ($n_num/$n_low/$n_mix)"
echo "PASS: --board foundation == --board 4 (name and number resolve identically)"

# --- 3: name-miss -> rc 2 + known-names list -------------------------------
if out="$(board_resolve_name definitely-not-a-board 2>&1)"; then
  fail "unknown name should have returned non-zero (got: $out)"
fi
rc=0; board_resolve_name definitely-not-a-board >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "unknown name rc should be 2, got $rc"
grep -q "unknown board name" <<<"$out" || fail "unknown-name error missing 'unknown board name' (got: $out)"
grep -q "foundation" <<<"$out" || fail "unknown-name error missing the known-names list (got: $out)"
grep -q "stagefind" <<<"$out"  || fail "unknown-name error missing the known-names list (got: $out)"
echo "PASS: an unknown board name errors (rc 2) with the known-names list"

# empty argument -> rc 2 as well
rc=0; board_resolve_name "" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "empty --board should rc 2, got $rc"
echo "PASS: an empty board argument errors (rc 2)"

# --- 4: no-conf-fallback is byte-identical to the built-in map -------------
# (already exercised above under the nonexistent-conf env — restate the contract
# explicitly: the resolver never NEEDS a conf file for its own boards.)
[ ! -f "$BOARDS_CONF_MACHINE" ] && [ ! -f "$BOARDS_CONF_REPO_LOCAL" ] \
  || fail "test precondition broken: a conf file unexpectedly exists"
[ "$(board_resolve_name foundation)" = "4" ] || fail "no-conf fallback: foundation != 4"
echo "PASS: with NO boards.conf, the built-in name map answers (the #770 seam contract)"

# --- 5: boards.conf name axis (add + override + known-names list) ----------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/board-name-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
cat > "$WORK/boards.conf" <<'EOF'
board.9.repo=acme/widget
board.9.backend=issues
board.9.name=acme-widget
board.4.name=fnd-alias
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/boards.conf"

[ "$(board_resolve_name acme-widget)" = "9" ] || fail "conf name 'acme-widget' did not resolve to 9"
[ "$(board_resolve_name ACME-WIDGET)" = "9" ] || fail "conf name resolution is not case-insensitive"
[ "$(board_resolve_name fnd-alias)" = "4" ]   || fail "conf name 'fnd-alias' did not resolve to 4"
# built-in names still work alongside conf names
[ "$(board_resolve_name foundation)" = "4" ]  || fail "conf present broke the built-in name map"
[ "$(board_resolve_name 9)" = "9" ]           || fail "numeric passthrough broke with a conf present"
# the conf slug shows up in the unknown-name error's known-names list
miss="$(board_resolve_name still-not-a-board 2>&1 || true)"
grep -q "acme-widget" <<<"$miss" || fail "conf name not listed in known-names error (got: $miss)"
echo "PASS: a boards.conf board.<N>.name= line adds/overrides names and lists in known-names"

# reset conf env back to nonexistent for the remaining lib-wiring cases
export BOARDS_CONF_REPO_LOCAL="/no-such-repo-local-conf-$$"

# --- 6: lib resolve entrypoints resolve a NAME identically to its number ---
# Spy on the FIRST downstream call each entrypoint makes after resolving, to prove
# it forwards the resolved NUMBER (not the name). No network: the spies replace
# the issues-only path with pure echoes.
_board_is_issues_only() { return 0; }                 # force the issues path (no gh)
_board_issues_resolve_item() { printf '%s' "$1"; }    # echoes the board it received
_board_issues_item_list()    { printf '%s' "$1"; }    # echoes the board it received

[ "$(board_resolve_item foundation 5)" = "$(board_resolve_item 4 5)" ] \
  || fail "board_resolve_item foundation != board_resolve_item 4"
[ "$(board_resolve_item foundation 5)" = "4" ] \
  || fail "board_resolve_item did not forward the resolved number 4"
[ "$(board_item_list stagefind)" = "$(board_item_list 3)" ] \
  || fail "board_item_list stagefind != board_item_list 3"
[ "$(board_item_list stagefind)" = "3" ] \
  || fail "board_item_list did not forward the resolved number 3"

# board_resolve sets BOARD_CURRENT to the resolved number
board_resolve foundation >/dev/null 2>&1
[ "$BOARD_CURRENT" = "4" ] || fail "board_resolve foundation left BOARD_CURRENT=$BOARD_CURRENT (want 4)"

# an unknown name is rejected by the lib entrypoint too (rc non-zero, no state)
rc=0; board_resolve_item bogus-name 5 >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "board_resolve_item accepted an unknown board name"
echo "PASS: board_resolve / board_resolve_item / board_item_list resolve a name identically to its number"

# --- 7: CLI entrypoints route --board through the resolver ------------------
# A fake gh that records if it's ever reached; an unknown --board name must be
# rejected in the arg preamble, BEFORE any gh call, at every entrypoint.
BIN="$(mktemp -d "${TMPDIR:-/tmp}/board-name-bin-XXXXXX")"
CALLED="$BIN/gh-was-called"
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
touch "$CALLED"
echo "FAKE GH CALLED: \$*" >&2
exit 1
EOF
chmod +x "$BIN/gh"
cleanup() { rm -rf "$WORK" "$BIN"; }

cli_rejects() {  # cli_rejects <label> -- args...
  local label="$1"; shift
  rm -f "$CALLED"
  local rc=0 out
  out="$(PATH="$BIN:$PATH" BOARDS_CONF_MACHINE="/no-such-$$" BOARDS_CONF_REPO_LOCAL="/no-such-$$" \
        bash "$@" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label: expected rc 2 for unknown name, got $rc (out: $out)"
  [ ! -e "$CALLED" ] || fail "$label: reached gh on an unknown --board name (would act on the wrong board)"
  grep -q "unknown board name" <<<"$out" || fail "$label: missing 'unknown board name' (out: $out)"
}

cli_rejects "worklist"  "$SCRIPTS_DIR/worklist.sh" --board bogus
cli_rejects "capture"   "$SCRIPTS_DIR/capture.sh" "some title" --board bogus
cli_rejects "claim"     "$SCRIPTS_DIR/claim.sh" 5 --board bogus
cli_rejects "milestone" "$SCRIPTS_DIR/milestone.sh" list --board bogus
echo "PASS: worklist / capture / claim / milestone all reject an unknown --board name (rc 2) before any gh call"

echo "ALL PASS: board name aliases (temperloop #95)"
