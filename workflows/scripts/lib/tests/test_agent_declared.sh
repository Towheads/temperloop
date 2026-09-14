#!/usr/bin/env bash
#
# Tests for agent_declared.sh — the SUBAGENT capability probe
# (temperloop#1462), sibling of test_command_declared.sh. Zero network,
# zero mutation of the real HOME or checkout.
#
# The bug under test is a FALSE NEGATIVE, so the load-bearing case is #6:
# an agent present ONLY at `$HOME/.claude/agents/` — the kernel's own
# dogfooding host's shape, with no `CLAUDE.md § Subagents` and no
# `./.claude/agents/` — must report `installed`, not `absent`. Its mirror
# image is case #1: an agent present at NO surface must still report
# `absent`, because a probe that reports everything available fabricates
# reviews that never ran.
#
# Surface 2 (the checkout's own `claude/agents/`, resolved via
# `git rev-parse --show-toplevel` from the LIB FILE'S OWN location) cannot
# be exercised against this real checkout without polluting it, so those
# cases source a COPY of the lib planted inside a throwaway git repo under
# TMP — `${BASH_SOURCE[0]}` inside a sourced function reflects the path
# passed to `source`, so sourcing the copy points checkout-root resolution
# at the throwaway repo instead of the real one.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# A name that exists under NONE of the real surfaces -- deliberately unusual
# so it can never collide with a real agent on the machine running this.
FIXTURE_NAME="zzz-agent-declared-fixture-probe"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-declared-test-XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# shellcheck source=workflows/scripts/lib/agent_declared.sh
source "$LIB_DIR/agent_declared.sh"

# The lib answers ENTIRELY from AGENT_DECLARED_OVERRIDE whenever that variable is
# merely SET, so an inherited value from the caller's environment would make every
# filesystem-surface case below vacuous — they would pass without probing anything.
# The sibling test_command_declared.sh unsets its own override for this reason;
# omitting it here was flagged by the §3e shell-reviewer.
unset AGENT_DECLARED_OVERRIDE

# A cwd with no CLAUDE.md and no .claude/, and a HOME with no .claude/ --
# the "nothing anywhere" baseline every single-surface case builds on.
mk_clean_cwd()  { local d="$TMP/$1"; mkdir -p "$d"; printf '%s' "$d"; }
mk_clean_home() { local d="$TMP/$1"; mkdir -p "$d"; printf '%s' "$d"; }

# <cwd> <home> [<name>] -> stdout: agent_declared_state's answer, run with
# the real lib but a fixture cwd/HOME.
state_in() {
  local cwd="$1" home="$2" name="${3:-$FIXTURE_NAME}"
  ( cd "$cwd" && HOME="$home" agent_declared_state "$name" )
}

# --- 0. usage: an empty name, and a path-separator name, are rejected --------
set +e
out0a="$(agent_declared_state "" 2>&1)"; rc0a=$?
out0b="$(agent_declared "../../etc/passwd" 2>&1)"; rc0b=$?
set -e
[ "$rc0a" -eq 2 ] || fail "0: an empty name should be rejected with rc 2 (got $rc0a)"
case "$out0a" in *usage*) : ;; *) fail "0: rejection should be a usage notice (got: $out0a)" ;; esac
[ "$rc0b" -eq 2 ] || fail "0: a path-separator name should be rejected with rc 2 (got $rc0b)"
case "$out0b" in *usage*) : ;; *) fail "0: rejection should be a usage notice (got: $out0b)" ;; esac
echo "PASS: 0 usage errors (empty name, path-separator name) are rejected with rc 2"

# --- 1. ABSENT: no surface carries it ---------------------------------------
# The mirror image of the bug: a probe that made everything look available
# would be exactly as wrong as the one that made everything look absent.
C_NONE="$(mk_clean_cwd cwd-none)"; H_NONE="$(mk_clean_home home-none)"
[ "$(state_in "$C_NONE" "$H_NONE")" = "absent" ] \
  || fail "1: an agent at no surface must report absent (got $(state_in "$C_NONE" "$H_NONE"))"
set +e
( cd "$C_NONE" && HOME="$H_NONE" agent_declared "$FIXTURE_NAME" ); rc1=$?
set -e
[ "$rc1" -eq 1 ] || fail "1: agent_declared must be false (rc 1) for an absent agent (got rc $rc1)"
echo "PASS: 1 an agent carried by no surface reports absent, and agent_declared is false"

# --- 2. SURFACE 0: the project's own CLAUDE.md § Subagents declaration -------
C_MD="$(mk_clean_cwd cwd-claude-md)"; H_MD="$(mk_clean_home home-claude-md)"
cat > "$C_MD/CLAUDE.md" <<EOF
# Project

## Subagents

- \`$FIXTURE_NAME\` — a declared reviewer.

## Something else

- $FIXTURE_NAME-not-in-section
EOF
[ "$(state_in "$C_MD" "$H_MD")" = "installed" ] \
  || fail "2: a CLAUDE.md § Subagents declaration must report installed (got $(state_in "$C_MD" "$H_MD"))"
echo "PASS: 2 a CLAUDE.md § Subagents declaration reports installed (surface 0)"

# --- 2b. the § Subagents section is CLOSED by the next same-level heading ----
C_MD2="$(mk_clean_cwd cwd-claude-md-scope)"; H_MD2="$(mk_clean_home home-claude-md-scope)"
cat > "$C_MD2/CLAUDE.md" <<EOF
## Subagents

- some-other-agent

## Not subagents

- $FIXTURE_NAME
EOF
[ "$(state_in "$C_MD2" "$H_MD2")" = "absent" ] \
  || fail "2b: a name AFTER the § Subagents section must not be declared (got $(state_in "$C_MD2" "$H_MD2"))"
echo "PASS: 2b a name outside the § Subagents section does not declare it (section scoping holds)"

# --- 2c. the name must match as a WHOLE TOKEN -------------------------------
C_MD3="$(mk_clean_cwd cwd-claude-md-token)"; H_MD3="$(mk_clean_home home-claude-md-token)"
printf '## Subagents\n\n- %s-v2\n' "$FIXTURE_NAME" > "$C_MD3/CLAUDE.md"
[ "$(state_in "$C_MD3" "$H_MD3")" = "absent" ] \
  || fail "2c: a longer name containing this one must not declare it (got $(state_in "$C_MD3" "$H_MD3"))"
echo "PASS: 2c a substring match (<name>-v2) does not declare <name> (whole-token matching holds)"

# --- 3. SURFACE 1: \$PWD/.claude/agents/<name>.md ----------------------------
C_S1="$TMP/cwd-surface1"; mkdir -p "$C_S1/.claude/agents"
: > "$C_S1/.claude/agents/$FIXTURE_NAME.md"
H_S1="$(mk_clean_home home-surface1)"
[ "$(state_in "$C_S1" "$H_S1")" = "installed" ] \
  || fail "3: a file under \$PWD/.claude/agents/ must report installed (got $(state_in "$C_S1" "$H_S1"))"
echo "PASS: 3 <name>.md under \$PWD/.claude/agents/ reports installed (surface 1)"

# --- 3b. SURFACE 1's reviewers/ catalog subdir (temperloop#2026) -------------
# The project-scoped half of the #2026 fix: surface 1 is a LIVE agent dir, so
# the ADR-0007 catalog subdir under it is live too -- a `.claude/agents`
# symlinked at a kernel `claude/agents`, or a wholesale-copied tree, carries
# `reviewers/` exactly as the machine dir does. Flat-only here would re-open
# the same false negative one surface over.
C_S1R="$TMP/cwd-surface1-reviewers"; mkdir -p "$C_S1R/.claude/agents/reviewers"
: > "$C_S1R/.claude/agents/reviewers/$FIXTURE_NAME.md"
H_S1R="$(mk_clean_home home-surface1-reviewers)"
[ "$(state_in "$C_S1R" "$H_S1R")" = "installed" ] \
  || fail "3b: a file under \$PWD/.claude/agents/reviewers/ must report installed (got $(state_in "$C_S1R" "$H_S1R"))"
echo "PASS: 3b <name>.md under \$PWD/.claude/agents/reviewers/ reports installed (surface 1, catalog subdir)"

# --- 4. SURFACE 2: <checkout>/claude/agents/<name>.md -> source-only ---------
# Built against a COPY of the lib planted inside a throwaway git repo, so
# checkout-root resolution points at the throwaway repo, not this real one.
FAKE_CHECKOUT="$TMP/fake-checkout"
mkdir -p "$FAKE_CHECKOUT/workflows/scripts/lib" \
         "$FAKE_CHECKOUT/claude/agents/reviewers"
git init -q "$FAKE_CHECKOUT"
cp "$LIB_DIR/agent_declared.sh" "$FAKE_CHECKOUT/workflows/scripts/lib/agent_declared.sh"
: > "$FAKE_CHECKOUT/claude/agents/$FIXTURE_NAME.md"

# <cwd> <home> [<name>] -> stdout: the state as answered by the COPY of the
# lib inside the throwaway checkout (so surface 2 points there).
state_in_fake_checkout() {
  local cwd="$1" home="$2" name="${3:-$FIXTURE_NAME}"
  ( cd "$cwd" && HOME="$home" bash -c '
      set -euo pipefail
      unset AGENT_DECLARED_OVERRIDE
      # shellcheck source=/dev/null
      source "'"$FAKE_CHECKOUT"'/workflows/scripts/lib/agent_declared.sh"
      agent_declared_state "'"$name"'"
    ' )
}

C_S2="$(mk_clean_cwd cwd-surface2)"; H_S2="$(mk_clean_home home-surface2)"
out4="$(state_in_fake_checkout "$C_S2" "$H_S2")"
[ "$out4" = "source-only" ] \
  || fail "4: a file under <checkout>/claude/agents/ must report source-only (got $out4)"
echo "PASS: 4 <name>.md under <checkout>/claude/agents/ reports source-only (surface 2)"

# --- 4b. the reviewers/ catalog subdir is the SAME surface -------------------
CAT_NAME="$FIXTURE_NAME-catalog"
: > "$FAKE_CHECKOUT/claude/agents/reviewers/$CAT_NAME.md"
out4b="$(state_in_fake_checkout "$C_S2" "$H_S2" "$CAT_NAME")"
[ "$out4b" = "source-only" ] \
  || fail "4b: a file under <checkout>/claude/agents/reviewers/ must report source-only (got $out4b)"
echo "PASS: 4b <name>.md under <checkout>/claude/agents/reviewers/ reports source-only (same surface)"

# --- 4c. source-only is DECLARED (agent_declared true) but NOT spawnable ----
# The ADR-0008 contract, restated for agents: agent_declared answers
# "source-or-installed present", so it is true here -- which is exactly why
# it must never gate a spawn on its own.
set +e
( cd "$C_S2" && HOME="$H_S2" bash -c '
    set -euo pipefail
    unset AGENT_DECLARED_OVERRIDE
    source "'"$FAKE_CHECKOUT"'/workflows/scripts/lib/agent_declared.sh"
    agent_declared "'"$FIXTURE_NAME"'"
  ' )
rc4c=$?
set -e
[ "$rc4c" -eq 0 ] || fail "4c: agent_declared must be TRUE for a source-only agent (got rc $rc4c)"
echo "PASS: 4c agent_declared is true for a source-only agent (present != spawnable)"

# --- 5. SURFACE 3: \$HOME/.claude/agents/<name>.md ---------------------------
C_S3="$(mk_clean_cwd cwd-surface3)"
H_S3="$TMP/home-surface3"; mkdir -p "$H_S3/.claude/agents"
: > "$H_S3/.claude/agents/$FIXTURE_NAME.md"
[ "$(state_in "$C_S3" "$H_S3")" = "installed" ] \
  || fail "5: a file under \$HOME/.claude/agents/ must report installed (got $(state_in "$C_S3" "$H_S3"))"
echo "PASS: 5 <name>.md under \$HOME/.claude/agents/ reports installed (surface 3)"

# --- 5b. THE #2026 REGRESSION CASE ------------------------------------------
# A catalog reviewer installed under `$HOME/.claude/agents/reviewers/` -- the
# live shape on the kernel's dogfooding host, where `$HOME/.claude/agents` IS
# a checkout's `claude/agents`, ADR-0007 catalog subdir and all. Surface 3's
# flat-only check missed it, so the probe fell through to the provisional
# surface-2 arm and answered `source-only` for a seat that was live and
# spawnable. Since `installed` is the SPAWN gate, a caller obeying the
# contract skipped a review that would have run -- #1462's false negative,
# one catalog directory down.
C_2026="$(mk_clean_cwd cwd-2026)"
H_2026="$TMP/home-2026"; mkdir -p "$H_2026/.claude/agents/reviewers"
: > "$H_2026/.claude/agents/reviewers/$FIXTURE_NAME.md"
got5b="$(state_in "$C_2026" "$H_2026")"
[ "$got5b" = "installed" ] \
  || fail "5b: the #2026 shape (catalog reviewer installed under \$HOME/.claude/agents/reviewers/) must report installed (got $got5b)"
echo "PASS: 5b #2026 regression — a catalog reviewer at \$HOME/.claude/agents/reviewers/ reports installed, never source-only"

# --- 6. THE #1462 REGRESSION CASE -------------------------------------------
# The kernel's own dogfooding checkout: no `CLAUDE.md § Subagents`, no
# `./.claude/agents/` (gitignored, never deployed in a fresh clone) -- but
# every agent installed and spawnable at `$HOME/.claude/agents/`. The
# literal two-surface predicate reported EVERY reviewer unavailable here, so
# build.md §3e's mandatory workflow-reviewer pass and /workshop §3.3's panel
# emitted all-skip lines for agents that would have spawned fine.
C_1462="$(mk_clean_cwd cwd-1462)"
printf '# Kernel\n\nNo Subagents heading anywhere in this file.\n' > "$C_1462/CLAUDE.md"
[ ! -e "$C_1462/.claude" ] || fail "6: fixture invariant broken -- cwd must have no .claude/"
H_1462="$TMP/home-1462"; mkdir -p "$H_1462/.claude/agents"
: > "$H_1462/.claude/agents/$FIXTURE_NAME.md"
got6="$(state_in "$C_1462" "$H_1462")"
[ "$got6" = "installed" ] \
  || fail "6: the #1462 shape (HOME-installed only) must report installed, never a skip (got $got6)"
echo "PASS: 6 #1462 regression — a HOME-only install, with no CLAUDE.md § Subagents and no ./.claude/, reports installed"

# --- 7. a LIVE surface outranks a provisional source-only hit ---------------
# An agent that both SHIPS in the checkout and IS installed on the host is
# installed. Reporting source-only here would re-introduce a skip line for a
# spawnable agent -- this very bug, one layer in.
C_BOTH="$(mk_clean_cwd cwd-both)"
H_BOTH="$TMP/home-both"; mkdir -p "$H_BOTH/.claude/agents"
: > "$H_BOTH/.claude/agents/$FIXTURE_NAME.md"
out7="$(state_in_fake_checkout "$C_BOTH" "$H_BOTH")"
[ "$out7" = "installed" ] \
  || fail "7: shipped AND installed must report installed, not source-only (got $out7)"
echo "PASS: 7 a live surface-3 install outranks the provisional surface-2 source hit"

# --- 7b. precedence holds for the CATALOG subdir too (temperloop#2026) -------
# The #2026 fix must not disturb the ordering contract: a catalog reviewer
# that BOTH ships at <checkout>/claude/agents/reviewers/ (case 4b planted it)
# and is installed at $HOME/.claude/agents/reviewers/ is INSTALLED. This is
# the ordering the bug actually broke -- the shipped hit was winning over a
# live one the probe could not see.
C_BOTH_CAT="$(mk_clean_cwd cwd-both-catalog)"
H_BOTH_CAT="$TMP/home-both-catalog"; mkdir -p "$H_BOTH_CAT/.claude/agents/reviewers"
: > "$H_BOTH_CAT/.claude/agents/reviewers/$CAT_NAME.md"
out7b="$(state_in_fake_checkout "$C_BOTH_CAT" "$H_BOTH_CAT" "$CAT_NAME")"
[ "$out7b" = "installed" ] \
  || fail "7b: a catalog reviewer both shipped and installed must report installed, not source-only (got $out7b)"
echo "PASS: 7b a catalog reviewer shipped under reviewers/ AND installed under reviewers/ reports installed (precedence unchanged)"

# --- 8. AGENT_DECLARED_OVERRIDE answers entirely from the env ---------------
set +e
o8a="$( cd "$C_NONE" && HOME="$H_NONE" AGENT_DECLARED_OVERRIDE="$FIXTURE_NAME other" agent_declared_state "$FIXTURE_NAME" )"
o8b="$( cd "$C_NONE" && HOME="$H_NONE" AGENT_DECLARED_OVERRIDE="$FIXTURE_NAME:source-only" agent_declared_state "$FIXTURE_NAME" )"
o8c="$( cd "$C_S1"   && HOME="$H_S1"   AGENT_DECLARED_OVERRIDE="some-other-agent" agent_declared_state "$FIXTURE_NAME" )"
o8d="$( cd "$C_S1"   && HOME="$H_S1"   AGENT_DECLARED_OVERRIDE="" agent_declared_state "$FIXTURE_NAME" )"
set -e
[ "$o8a" = "installed" ]   || fail "8: a bare override token should force installed (got $o8a)"
[ "$o8b" = "source-only" ] || fail "8: a :source-only override token should force source-only (got $o8b)"
[ "$o8c" = "absent" ]      || fail "8: an unlisted name should force absent despite a real file on disk (got $o8c)"
[ "$o8d" = "absent" ]      || fail "8: a set-but-empty override should force absent despite a real file on disk (got $o8d)"
echo "PASS: 8 AGENT_DECLARED_OVERRIDE answers entirely from the env (installed, source-only, unlisted, set-but-empty)"

# --- 9. an override token with an unknown state warns and fails CLOSED ------
set +e
err9="$( cd "$C_S1" && HOME="$H_S1" AGENT_DECLARED_OVERRIDE="$FIXTURE_NAME:spawnable" agent_declared_state "$FIXTURE_NAME" 2>&1 >/dev/null )"
o9="$( cd "$C_S1" && HOME="$H_S1" AGENT_DECLARED_OVERRIDE="$FIXTURE_NAME:spawnable" agent_declared_state "$FIXTURE_NAME" 2>/dev/null )"
set -e
[ "$o9" = "absent" ] || fail "9: an unknown state suffix must fail closed to absent (got $o9)"
case "$err9" in *"unknown state"*) : ;; *) fail "9: an unknown state suffix should warn on stderr (got: $err9)" ;; esac
echo "PASS: 9 an override token with an unknown state warns on stderr and fails closed to absent"

# --- 10. agent_declared's rc mapping across all three states ----------------
set +e
( cd "$C_NONE" && HOME="$H_NONE" AGENT_DECLARED_OVERRIDE="$FIXTURE_NAME:installed"   agent_declared "$FIXTURE_NAME" ); rc10a=$?
( cd "$C_NONE" && HOME="$H_NONE" AGENT_DECLARED_OVERRIDE="$FIXTURE_NAME:source-only" agent_declared "$FIXTURE_NAME" ); rc10b=$?
( cd "$C_NONE" && HOME="$H_NONE" AGENT_DECLARED_OVERRIDE=""                          agent_declared "$FIXTURE_NAME" ); rc10c=$?
set -e
[ "$rc10a" -eq 0 ] || fail "10: agent_declared must be true for installed (got rc $rc10a)"
[ "$rc10b" -eq 0 ] || fail "10: agent_declared must be true for source-only (got rc $rc10b)"
[ "$rc10c" -eq 1 ] || fail "10: agent_declared must be false for absent (got rc $rc10c)"
echo "PASS: 10 agent_declared maps installed/source-only -> rc 0 and absent -> rc 1"

# --- 11. the REAL kernel checkout resolves its own shipped agents -----------
# Not a fixture: proves the helper answers correctly against this repo's own
# tracked claude/agents/ tree, whatever this host's install state is. Both
# answers are acceptable (source-only on a bare clone, installed on a host
# that deployed them) -- what must NEVER happen is `absent` for an agent
# this checkout demonstrably ships, which is the #1462 report verbatim.
for real_agent in workflow-reviewer architecture-reviewer requirements-auditor docs-reviewer; do
  [ -f "$LIB_DIR/../../../claude/agents/$real_agent.md" ] || continue
  got11="$(agent_declared_state "$real_agent")"
  case "$got11" in
    installed|source-only) : ;;
    *) fail "11: $real_agent ships under claude/agents/ but reports '$got11'" ;;
  esac
done
echo "PASS: 11 every reviewer this checkout ships resolves as installed or source-only, never absent"

# --- 11b. the real ADR-0007 CATALOG resolves too (temperloop#2026) -----------
# Same non-fixture assertion, one directory down, over the catalog this repo
# actually ships. Plus the strict arm: on a host that has a catalog reviewer
# INSTALLED (the dogfooding shape -- $HOME/.claude/agents pointed at a
# checkout's claude/agents, reviewers/ and all), the answer must be
# `installed`, because that is the SPAWN gate and the seat is spawnable.
# The strict arm is skipped, not failed, on a host with no such install.
catalog_dir="$LIB_DIR/../../../claude/agents/reviewers"
if [ -d "$catalog_dir" ]; then
  for cat_agent_md in "$catalog_dir"/*.md; do
    [ -f "$cat_agent_md" ] || continue
    cat_agent="$(basename "$cat_agent_md" .md)"
    got11b="$(agent_declared_state "$cat_agent")"
    case "$got11b" in
      installed|source-only) : ;;
      *) fail "11b: $cat_agent ships under claude/agents/reviewers/ but reports '$got11b'" ;;
    esac
    if [ -f "$HOME/.claude/agents/reviewers/$cat_agent.md" ]; then
      [ "$got11b" = "installed" ] \
        || fail "11b: $cat_agent is installed at \$HOME/.claude/agents/reviewers/ but reports '$got11b' (#2026)"
    fi
  done
fi
echo "PASS: 11b every catalog reviewer under claude/agents/reviewers/ resolves, and a HOME-installed one reports installed"

echo "All agent_declared.sh tests passed."
