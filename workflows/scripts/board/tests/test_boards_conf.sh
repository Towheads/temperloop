#!/usr/bin/env bash
#
# Tests for board.sh's boards.conf registry seam (foundation #770). board_repo /
# board_owner / board_project_number are deliberately SEPARATE per-axis
# registries (repo-owner vs project-owner vs project-number — #330 paid for
# this distinction); each now resolves through an optional external
# `boards.conf` file BEFORE falling back to the built-in case map. Discovery
# order (first hit wins): machine-level ($BOARDS_CONF_MACHINE, defaulting to
# $XDG_CONFIG_HOME/foundation/boards.conf) -> repo-local override
# ($BOARDS_CONF_REPO_LOCAL, defaulting to workflows/scripts/board/boards.conf)
# -> the built-in map.
#
# This suite exercises BOTH conf-present and conf-absent (fallback) paths:
#   1. conf-absent: every accessor returns exactly the pre-#770 built-in
#      values (byte-identical fallback — the guarantee a consuming repo with
#      no conf, e.g. stageFind's synced board.sh, relies on).
#   2. repo-local conf present: a value present in the conf overrides the
#      built-in map; a board NOT mentioned in the conf still falls through to
#      the built-in map (partial-conf coexists with fallback).
#   3. machine-level conf takes precedence over a repo-local conf when both
#      exist (discovery-order precedence).
#   4. all three axes (repo/owner/project) are independently overridable.
#
# No network, no gh call — board_repo/board_owner/board_project_number never
# call `_board_gh`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=scripts/lib/board.sh
source "$LIB_DIR/board.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/board-conf-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- 1: conf-absent -> byte-identical fallback -----------------------------
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf"
export BOARDS_CONF_REPO_LOCAL="$WORK/no-such-repo-local-conf"

[ "$(board_repo 3)" = "Towheads/stageFind" ]  || fail "board_repo 3 fallback wrong"
[ "$(board_repo 4)" = "Towheads/foundation" ] || fail "board_repo 4 fallback wrong"
[ "$(board_repo 5)" = "Towheads/ssmobile" ]   || fail "board_repo 5 fallback wrong"
[ "$(board_repo 6)" = "Towheads/subsetwiki" ] || fail "board_repo 6 fallback wrong"
if board_repo 9 >/dev/null 2>&1; then fail "board_repo 9 should fail (unmapped, no conf)"; fi

[ "$(board_owner 3)" = "Towheads" ] || fail "board_owner 3 fallback wrong"
[ "$(board_owner 4)" = "Towheads" ] || fail "board_owner 4 fallback wrong"
[ "$(board_owner 9)" = "Towheads" ] || fail "board_owner 9 fallback (BOARD_OWNER default) wrong"

[ "$(board_project_number 3)" = "4" ] || fail "board_project_number 3 fallback wrong"
[ "$(board_project_number 4)" = "3" ] || fail "board_project_number 4 fallback wrong"
[ "$(board_project_number 5)" = "5" ] || fail "board_project_number 5 fallback (identity) wrong"

echo "PASS: conf-absent fallback is byte-identical to the pre-#770 built-in map"

# --- 2: repo-local conf present, partial coverage --------------------------
cat > "$WORK/repo-local.conf" <<'EOF'
# comment lines and blanks are ignored

board.4.repo=Acme/foundation-fork
board.4.owner=Acme
board.4.project=42
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/repo-local.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf"   # still absent

[ "$(board_repo 4)" = "Acme/foundation-fork" ] || fail "board_repo 4 should resolve from repo-local conf"
[ "$(board_owner 4)" = "Acme" ]                || fail "board_owner 4 should resolve from repo-local conf"
[ "$(board_project_number 4)" = "42" ]         || fail "board_project_number 4 should resolve from repo-local conf"

# board 3 is NOT in the conf -> falls through to the built-in map unaffected.
[ "$(board_repo 3)" = "Towheads/stageFind" ] || fail "board_repo 3 should still fall back (not in conf)"
[ "$(board_owner 3)" = "Towheads" ]          || fail "board_owner 3 should still fall back (not in conf)"

echo "PASS: repo-local conf overrides its listed board; unlisted boards still fall back"

# --- 3: machine-level conf takes precedence over repo-local -----------------
cat > "$WORK/machine.conf" <<'EOF'
board.4.repo=Machine/foundation
EOF
export BOARDS_CONF_MACHINE="$WORK/machine.conf"
# BOARDS_CONF_REPO_LOCAL still points at repo-local.conf (board.4.repo=Acme/foundation-fork)

[ "$(board_repo 4)" = "Machine/foundation" ] || fail "machine-level conf should win over repo-local"
# An axis the machine conf does NOT set for board 4 (owner) is looked up in the
# SAME file that won discovery (machine.conf), which has no owner key -> falls
# back to the built-in map, NOT to repo-local.conf's owner=Acme. This pins the
# "one file wins, not a per-key merge across files" discovery contract.
[ "$(board_owner 4)" = "Towheads" ] || fail "board_owner 4 should fall back to built-in (machine.conf has no owner key, no cross-file merge)"

echo "PASS: machine-level conf takes precedence over repo-local (whole-file discovery, not per-key merge)"

# --- 4b: backend axis (foundation #799) — a FOURTH boards.conf axis, same
# discovery + fallback contract as repo/owner/project, defaulting to "projects"
# for any board with no explicit `backend=issues` line (see
# test_issues_backend.sh for the behavioral proof of the issues-only path).
cat > "$WORK/backend.conf" <<'EOF'
board.7.repo=Acme/issues-only-repo
board.7.backend=issues
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/backend.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf"

[ "$(board_backend 7)" = "issues" ]   || fail "board_backend 7 should resolve 'issues' from conf"
[ "$(board_backend 4)" = "projects" ] || fail "board_backend 4 (not in conf) should default to 'projects'"
[ "$(board_backend 3)" = "projects" ] || fail "board_backend 3 (no conf at all case covered above) should default to 'projects'"
echo "PASS: the backend axis resolves from conf and defaults to 'projects' when absent"

# --- 5: unset BOARDS_CONF_* env vars resolve the real default paths --------
# (Just confirm the default-path expressions don't error under `set -u` — we
# don't touch the real $HOME/.config or the real repo-local boards.conf here.)
unset BOARDS_CONF_MACHINE BOARDS_CONF_REPO_LOCAL
_board_conf_file >/dev/null 2>&1 || true   # rc 1 is fine (no real conf in this test env); must not error out
echo "PASS: default discovery paths (unset overrides) evaluate without error"

echo "ALL PASS: test_boards_conf.sh"
