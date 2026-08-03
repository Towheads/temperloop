#!/usr/bin/env bash
#
# Tests for gate-selection.sh — the diff-scoped gate selector
# scripts/quality-gates.sh uses on `pull_request` runs (temperloop#1024).
#
# The whole value of this suite is that it proves the DEGRADATIONS, which are
# the only thing standing between diff-scoping and the silent-green failure
# class. Every case below asserts one of two things: either the selector
# narrowed correctly, or it refused to narrow and said why.
#
# Coverage:
#   1. Not a pull_request event -> FULL set (the merge_group / push:main /
#      local / worker path, i.e. everything that gates `main`).
#   2. QUALITY_GATES_SCOPE=full -> FULL set even on a pull_request.
#   3. An unrecognised QUALITY_GATES_SCOPE -> FULL set (fail toward coverage).
#   4. Happy path: changed paths select exactly their mapped gates, plus every
#      ALWAYS gate, in the caller's run order.
#   5. UNMAPPED PATH -> FULL set. The headline safety property.
#   6. ALL escalation glob -> FULL set.
#   7. `none` row: a recognised path that maps to no gate does NOT escalate,
#      and does NOT drag in unrelated gates.
#   8. An ALWAYS row is not a path recogniser — otherwise its implicit
#      whole-tree scope would match every path and case 5 could never fire.
#   9. UNMAPPED GATE still runs (over-run, never under-run).
#  10. Malformed map -> FULL set, with a stderr complaint.
#  11. Missing map file -> FULL set.
#  12. Unresolvable base -> FULL set (real git, real repo).
#  13. Empty diff -> FULL set.
#  14. End-to-end against a REAL git repo: a two-commit repo, a real
#      `git diff base...HEAD`, and a real narrowing decision.
#  15. Globs are never pathname-expanded against the working directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# shellcheck source=../gate-selection.sh
source "$LIB_DIR/gate-selection.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MAP="$TMP/gate-paths.tsv"
cat >"$MAP" <<'EOF'
# fixture map
ALL	Makefile scripts/quality-gates.sh
none	LICENSE
make test-always	ALWAYS
make test-docs	docs/**
make test-lib	src/lib/** src/shared.sh
make test-cli	src/cli/**
EOF

ALL_GATES='make test-always
make test-docs
make test-lib
make test-cli
make test-unmapped'

reset_env() {
  unset QUALITY_GATES_SCOPE GITHUB_EVENT_NAME GATE_SELECTION_CHANGED
  GATE_SELECTION_ROOT="$TMP"
  GATE_SELECTION_MAP_FILE="$MAP"
  GATE_SELECTION_ALL_GATES="$ALL_GATES"
  GATE_SELECTION_BASE=""
}

# --- 1. not a pull_request event ---------------------------------------------
reset_env
GITHUB_EVENT_NAME=merge_group
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "1: merge_group must run the FULL set (got $GATE_SELECTION_MODE)"
case "$GATE_SELECTION_REASON" in *"is not pull_request"*) : ;; *) fail "1: reason should name the event (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 1 a non-pull_request event runs the full set"

# --- 2. QUALITY_GATES_SCOPE=full ---------------------------------------------
reset_env
GITHUB_EVENT_NAME=pull_request
QUALITY_GATES_SCOPE=full
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "2: SCOPE=full must disable scoping"
echo "PASS: 2 QUALITY_GATES_SCOPE=full disables scoping"

# --- 3. unrecognised scope ---------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=sideways
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "3: an unrecognised scope must fail toward the full set"
case "$GATE_SELECTION_REASON" in *unrecognised*) : ;; *) fail "3: reason should say unrecognised (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 3 an unrecognised QUALITY_GATES_SCOPE falls back to the full set"

# --- 4. happy path -----------------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/a.md
src/lib/thing.sh'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "4: expected a diff-scoped run (got $GATE_SELECTION_MODE / $GATE_SELECTION_REASON)"
expected='make test-always
make test-docs
make test-lib
make test-unmapped'
[ "$GATE_SELECTION_SELECTED" = "$expected" ] || fail "4: wrong selection:
got:
$GATE_SELECTION_SELECTED
want:
$expected"
echo "PASS: 4 mapped paths select their gates (plus ALWAYS + unmapped), in run order"

# --- 5. an unmapped path escalates to the full set ---------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/a.md
somewhere/nobody/mapped.txt'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "5: an unmapped path MUST escalate to the full set (got $GATE_SELECTION_MODE)"
case "$GATE_SELECTION_REASON" in *"somewhere/nobody/mapped.txt"*) : ;; *) fail "5: reason must NAME the unmapped path (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 5 an unmapped changed path escalates to the full set, naming the path"

# --- 6. ALL escalation -------------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/a.md
Makefile'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "6: an ALL glob must escalate to the full set"
case "$GATE_SELECTION_REASON" in *"ALL escalation"*) : ;; *) fail "6: reason should name the ALL escalation (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 6 a path matching an ALL glob escalates to the full set"

# --- 7. `none` row -----------------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='LICENSE'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "7: a `none`-mapped path must not escalate (got $GATE_SELECTION_REASON)"
expected='make test-always
make test-unmapped'
[ "$GATE_SELECTION_SELECTED" = "$expected" ] || fail "7: a none-mapped path should select nothing beyond ALWAYS/unmapped, got:
$GATE_SELECTION_SELECTED"
echo "PASS: 7 a 'none'-mapped path is recognised but selects no gate"

# --- 8. an ALWAYS row is not a recogniser ------------------------------------
# `make test-always` carries no globs. If ALWAYS rows counted as recognisers
# (e.g. by being treated as `**`), the unmapped-path escalation in case 5 could
# never fire. Prove the recogniser set really excludes them.
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='totally/unmapped'
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "8: an ALWAYS row must not recognise arbitrary paths"
echo "PASS: 8 an ALWAYS row contributes nothing to path recognition"

# --- 9. an unmapped GATE always runs ----------------------------------------
# (asserted by cases 4 and 7 above, which both keep `make test-unmapped`.)
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='src/cli/main.sh'
gate_selection_resolve
case "$GATE_SELECTION_SELECTED" in *"make test-unmapped"*) : ;; *) fail "9: a gate with no map row must still run" ;; esac
case "$GATE_SELECTION_SELECTED" in *"make test-docs"*) fail "9: test-docs should not have been selected by a src/cli path" ;; esac
echo "PASS: 9 a gate with no row in the map still runs (over-run, never under-run)"

# --- 10. malformed map -------------------------------------------------------
BADMAP="$TMP/bad.tsv"
printf 'no-tab-here\n' >"$BADMAP"
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_MAP_FILE="$BADMAP"
GATE_SELECTION_CHANGED='docs/a.md'
# NB: stderr is redirected to a FILE, not captured by `$(...)` — a command
# substitution runs in a subshell, and the whole point of this call is the
# globals it sets in THIS shell.
gate_selection_resolve 2>"$TMP/err10"
err="$(cat "$TMP/err10")"
[ "$GATE_SELECTION_MODE" = "full" ] || fail "10: a malformed map must fall back to the full set"
case "$err" in *malformed*) : ;; *) fail "10: the malformed row should be announced on stderr (got: $err)" ;; esac
echo "PASS: 10 a malformed map falls back to the full set and says so"

# --- 11. missing map ---------------------------------------------------------
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_MAP_FILE="$TMP/does-not-exist.tsv"
GATE_SELECTION_CHANGED='docs/a.md'
gate_selection_resolve 2>"$TMP/err11"
err="$(cat "$TMP/err11")"
[ "$GATE_SELECTION_MODE" = "full" ] || fail "11: a missing map must fall back to the full set"
case "$err" in *"not found"*) : ;; *) fail "11: the missing map should be announced (got: $err)" ;; esac
echo "PASS: 11 a missing map falls back to the full set and says so"

# --- 12/13/14. real git repo -------------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO/docs" "$REPO/src/lib"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
echo base >"$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
BASE="$(git -C "$REPO" rev-parse HEAD)"

# 12. unresolvable base
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_ROOT="$REPO"
GATE_SELECTION_BASE="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "12: an unresolvable base must fall back to the full set"
case "$GATE_SELECTION_REASON" in *"no resolvable diff base"*) : ;; *) fail "12: reason should name the base problem (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 12 an unresolvable diff base falls back to the full set"

# 13. empty diff (base == HEAD)
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_ROOT="$REPO"
GATE_SELECTION_BASE="$BASE"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "full" ] || fail "13: an empty diff must fall back to the full set"
case "$GATE_SELECTION_REASON" in *"zero changed paths"*) : ;; *) fail "13: reason should name the empty diff (got: $GATE_SELECTION_REASON)" ;; esac
echo "PASS: 13 a diff with zero changed paths falls back to the full set"

# 14. a real narrowing decision over a real diff
echo hi >"$REPO/docs/guide.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm docs
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_ROOT="$REPO"
GATE_SELECTION_BASE="$BASE"
gate_selection_resolve
[ "$GATE_SELECTION_MODE" = "diff" ] || fail "14: a real docs-only diff should narrow (got $GATE_SELECTION_REASON)"
expected='make test-always
make test-docs
make test-unmapped'
[ "$GATE_SELECTION_SELECTED" = "$expected" ] || fail "14: wrong real-git selection:
$GATE_SELECTION_SELECTED"
echo "PASS: 14 a real git diff narrows the run to the docs-affected gates"

# --- 15. globs are never pathname-expanded -----------------------------------
# A bare `for glob in $globs` would expand `docs/**` against the CWD, silently
# replacing the author's pattern with whatever happens to exist on disk. Run
# from a directory that HAS a `docs/` and prove the pattern still behaves as a
# pattern (matching a path that does NOT exist on disk).
reset_env
QUALITY_GATES_SCOPE=diff
GATE_SELECTION_CHANGED='docs/never/created/on/disk.md'
( cd "$REPO" && gate_selection_resolve && [ "$GATE_SELECTION_MODE" = "diff" ] ) \
  || fail "15: a glob must be matched as a pattern, not pathname-expanded against the CWD"
echo "PASS: 15 globs are matched as patterns, never expanded against the working directory"

echo "OK — gate-selection.sh: all cases passed"
