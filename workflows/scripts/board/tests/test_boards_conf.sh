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

# --- 6: board 7 = the temperloop tracker (F#808), conf-absent -------------
# Board 7 is registered directly in board_repo()/board_backend()'s BUILT-IN
# maps (not a committed boards.conf — see ISSUES-ONLY-BACKEND.md § "The
# temperloop tracker" for why: a real org-qualified repo value is
# exactly the class of literal this checkout's personal-token-denylist
# forbids inside the kernel-vendored tree outside board_repo()'s own
# sanctioned case map). So this mirrors § 1's conf-absent fallback proof,
# just for board 7 specifically — the "boards.conf kernel entry present and
# adapter-resolvable" acceptance proof (F#808).
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf-3"
export BOARDS_CONF_REPO_LOCAL="$WORK/no-such-repo-local-conf-3"

[ "$(board_repo 7)" = "Towheads/temperloop" ] \
  || fail "board_repo 7 should resolve the built-in kernel-tracker default, got: $(board_repo 7)"
[ "$(board_backend 7)" = "issues" ] \
  || fail "board_backend 7 should resolve 'issues' from the built-in map, got: $(board_backend 7)"
_board_is_issues_only 7 || fail "_board_is_issues_only 7 should be true (built-in map)"

# Boards 3-6 are unaffected by board 7's new built-in entries.
[ "$(board_repo 3)" = "Towheads/stageFind" ]  || fail "board_repo 3 should still resolve its own built-in default"
[ "$(board_backend 4)" = "projects" ]         || fail "board_backend 4 should still default to 'projects'"
echo "PASS: board 7 (kernel tracker) resolves from board_repo/board_backend's built-in maps, conf-absent (F#808)"

# --- 7: a boards.conf CAN still override board 7, exactly like any board ---
cat > "$WORK/board7-override.conf" <<'EOF'
board.7.repo=Acme/kernel-fork
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/board7-override.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf-4"

[ "$(board_repo 7)" = "Acme/kernel-fork" ] \
  || fail "board_repo 7 should be overridable via boards.conf like any other board, got: $(board_repo 7)"
# backend isn't in this override conf -> still falls through to the built-in
# map's board-7 case (issues), NOT the general "projects" default.
[ "$(board_backend 7)" = "issues" ] \
  || fail "board_backend 7 (repo overridden, backend not) should still resolve 'issues' from the built-in map, got: $(board_backend 7)"
echo "PASS: a boards.conf entry overrides board 7's repo exactly like any other board; backend still falls back to the built-in kernel default"

# --- 8: board_registered_boards() — single source of truth for probes ------
# The accessor every command-spec repo->board reverse-lookup probe iterates
# (temperloop#352), replacing the hardcoded `3 4 5 6` literal. Conf-absent it is
# exactly the built-in set INCLUDING board 7 (the exact #352 gap); a boards.conf
# that registers a NEW board number unions it in, so a probe picks up an
# onboarded board with no command-spec edit (drift-proof).
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf-8"
export BOARDS_CONF_REPO_LOCAL="$WORK/no-such-repo-local-conf-8"
[ "$(board_registered_boards | tr '\n' ' ')" = "3 4 5 6 7 " ] \
  || fail "board_registered_boards (conf-absent) should be the built-in set '3 4 5 6 7', got: $(board_registered_boards | tr '\n' ' ')"
board_registered_boards | grep -qx 7 \
  || fail "board_registered_boards must include board 7 (temperloop#352: probes dropped it)"

cat > "$WORK/board8.conf" <<'EOF'
board.8.repo=Acme/eighth
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/board8.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf-8b"
[ "$(board_registered_boards | tr '\n' ' ')" = "3 4 5 6 7 8 " ] \
  || fail "board_registered_boards should union a conf-registered board 8, got: $(board_registered_boards | tr '\n' ' ')"
echo "PASS: board_registered_boards is the built-in set (incl. board 7) unioned with conf-registered boards (temperloop#352)"

# --- 9: backend axis per-key fallthrough (boards.conf per-axis backend
# fallthrough) — a machine-level conf that EXISTS but is silent on this
# board's backend key must fall through to a repo-local `backend=` entry,
# NOT shadow it whole-file and jump straight to the built-in default. This is
# the fleet-cutover case: a committed repo-local backend flip (e.g.
# board.9.backend=issues) must survive an unrelated machine-level conf
# present on the host for OTHER boards. Deliberately does NOT change the
# repo/owner/project axes' whole-file contract pinned in section 3 above.
cat > "$WORK/repo-local-9.conf" <<'EOF'
board.9.repo=Acme/ninth
board.9.backend=issues
EOF
cat > "$WORK/machine-9-silent.conf" <<'EOF'
# a machine-level conf that exists, but says nothing about board 9's backend
# (e.g. it only configures unrelated boards)
board.42.repo=Acme/unrelated
EOF
export BOARDS_CONF_MACHINE="$WORK/machine-9-silent.conf"
export BOARDS_CONF_REPO_LOCAL="$WORK/repo-local-9.conf"

[ "$(board_backend 9)" = "issues" ] \
  || fail "board_backend 9 should fall through the silent machine-level conf to the repo-local backend=issues entry, got: $(board_backend 9)"

# ...but an EXPLICIT machine-level backend= line still wins outright over the
# repo-local one (discovery order preserved; only the absent-key case falls
# through).
cat > "$WORK/machine-9-explicit.conf" <<'EOF'
board.9.backend=projects
EOF
export BOARDS_CONF_MACHINE="$WORK/machine-9-explicit.conf"
# BOARDS_CONF_REPO_LOCAL still points at repo-local-9.conf (backend=issues)

[ "$(board_backend 9)" = "projects" ] \
  || fail "an explicit machine-level backend= line should still win over repo-local, got: $(board_backend 9)"

# A board mentioned in NEITHER file for the backend key still defaults to
# "projects" (unaffected by the fallthrough change).
[ "$(board_backend 4)" = "projects" ] \
  || fail "board_backend 4 (backend key absent from both conf files) should still default to 'projects'"

echo "PASS: the backend axis falls through a silent machine-level conf to repo-local, while an explicit machine-level value still wins"

echo "ALL PASS: test_boards_conf.sh"
