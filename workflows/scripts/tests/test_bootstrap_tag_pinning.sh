#!/usr/bin/env bash
#
# test_bootstrap_tag_pinning.sh — hermetic, deterministic, no-network
# end-to-end fixture test for bin/bootstrap.sh's tag-pinning + delegate-to-
# update behavior (temperloop#434, ADR 0002 "Managed-clone state
# ownership").
#
# Builds TWO synthetic "upstream" fixture clones of this repo's own
# committed tree (never the real public kernel remote — see the SAFETY note
# below):
#
#   FIXTURE_TAGGED   a --no-tags clone with a baseline commit tagged
#                     v9.1.0, a follow-on commit tagged v9.2.0, and a final
#                     UNTAGGED mainline commit on top — so the default
#                     branch tip is deliberately AHEAD of the latest tag,
#                     the realistic shape a fresh clone actually has
#                     (proves bootstrap lands on the TAG, not the tip).
#   FIXTURE_NOTAGS   a --no-tags clone with no tags at all — proves the
#                     "no release tags -> stay on the default branch, with
#                     an explicit warning" fallback.
#
# Four legs, each against its own isolated TEMPERLOOP_HOME/TEMPERLOOP_BIN_DIR
# under the one sandbox (same "distinct sub-paths, one sandbox_up" idiom as
# test_rename_compat.sh):
#
#   A. Fresh bootstrap against FIXTURE_TAGGED -> lands on v9.2.0 (acceptance
#      criterion 1, tag branch).
#   B. Fresh bootstrap against FIXTURE_NOTAGS -> stays on the default
#      branch tip, with an explicit WARNING naming it (acceptance criterion
#      1, no-tag fallback branch).
#   C. A re-run of bootstrap against A's install, non-interactively with no
#      consent available, after a NEWER tag (v9.3.0) lands upstream ->
#      delegates to 'temperloop update', which REFUSES (no timeout-as-
#      consent) and leaves HEAD untouched at v9.2.0 — never a pull
#      (acceptance criterion 2, delegate-and-refuse branch). A second re-run
#      with a simulated interactive "y" consent -> update actually moves
#      HEAD to v9.3.0, proving this is a real delegation, not a permanent
#      no-op.
#   D. A re-run of bootstrap against an install whose
#      bin/subcommands/update.sh has been removed (simulating a clone that
#      predates temperloop#429) -> fails legibly with a stated two-option
#      recovery, HEAD untouched (acceptance criterion 2, pre-update-era
#      branch).
#
# SAFETY: every TEMPERLOOP_HOME/TEMPERLOOP_BIN_DIR used below lives under
# the sandbox root; bootstrap.sh and update.sh are only ever invoked against
# those throwaway paths, never against $REPO_ROOT itself. The tripwire in
# the final section asserts $REPO_ROOT's own HEAD/branch/status are
# byte-identical before and after the whole run, as a mechanical guard
# against that mistake (same convention as test_update_subcommand.sh /
# test_rename_compat.sh).
#
# No network (every fixture "upstream" is a local file:// clone). No real
# HOME/XDG mutation (workflows/scripts/tests/lib/sandbox.sh).
#
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

# ===========================================================================
# 0. Tripwire on $REPO_ROOT's own git state (see the SAFETY note above) —
#    snapshotted BEFORE any fixture setup, checked at the very end.
# ===========================================================================
repo_root_head_before="$(git -C "$REPO_ROOT" rev-parse HEAD)"
repo_root_branch_before="$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD || echo DETACHED)"
repo_root_status_before="$(git -C "$REPO_ROOT" status --porcelain)"

sandbox_up test-bootstrap-tag-pinning

BOOTSTRAP_SH="$REPO_ROOT/bin/bootstrap.sh"
[ -f "$BOOTSTRAP_SH" ] || fail "0: $BOOTSTRAP_SH not found"

# ===========================================================================
# 1. FIXTURE_TAGGED: v9.1.0 -> v9.2.0 -> one untagged mainline commit.
# ===========================================================================
FIXTURE_TAGGED="$SANDBOX_ROOT/fixture-tagged"
git clone -q --no-tags "$REPO_ROOT" "$FIXTURE_TAGGED" \
  || fail "1: could not clone $REPO_ROOT (--no-tags) to build FIXTURE_TAGGED"

echo "fixture: v9.1.0 baseline" >> "$FIXTURE_TAGGED/.fixture-marker"
git -C "$FIXTURE_TAGGED" add .fixture-marker
git -C "$FIXTURE_TAGGED" commit -q -m "fixture: baseline (v9.1.0)"
git -C "$FIXTURE_TAGGED" tag -a v9.1.0 -m v9.1.0

echo "fixture: v9.2.0 follow-on" >> "$FIXTURE_TAGGED/.fixture-marker"
git -C "$FIXTURE_TAGGED" add .fixture-marker
git -C "$FIXTURE_TAGGED" commit -q -m "fixture: follow-on (v9.2.0)"
git -C "$FIXTURE_TAGGED" tag -a v9.2.0 -m v9.2.0

# An UNTAGGED mainline commit on top — the default-branch tip is
# deliberately ahead of the latest tag, mirroring a real repo's shape.
echo "fixture: untagged mainline change after v9.2.0" >> "$FIXTURE_TAGGED/.fixture-marker"
git -C "$FIXTURE_TAGGED" add .fixture-marker
git -C "$FIXTURE_TAGGED" commit -q -m "fixture: untagged mainline commit after v9.2.0"

tagged_branch="$(git -C "$FIXTURE_TAGGED" symbolic-ref --short HEAD)"
pass "1: built FIXTURE_TAGGED (v9.1.0 -> v9.2.0, tip one untagged commit further on '$tagged_branch')"

# ===========================================================================
# 2. FIXTURE_NOTAGS: same origin, zero tags.
# ===========================================================================
FIXTURE_NOTAGS="$SANDBOX_ROOT/fixture-notags"
git clone -q --no-tags "$REPO_ROOT" "$FIXTURE_NOTAGS" \
  || fail "2: could not clone $REPO_ROOT (--no-tags) to build FIXTURE_NOTAGS"
notags_branch="$(git -C "$FIXTURE_NOTAGS" symbolic-ref --short HEAD)"
[ -z "$(git -C "$FIXTURE_NOTAGS" tag -l)" ] || fail "2: FIXTURE_NOTAGS must be tagless"
pass "2: built FIXTURE_NOTAGS (tagless, on '$notags_branch')"

sandbox_env

# ===========================================================================
# 3. RUN A — fresh bootstrap against FIXTURE_TAGGED lands on v9.2.0 (the
#    latest tag), NOT the untagged tip (acceptance criterion 1).
# ===========================================================================
A_HOME="$SANDBOX_HOME/install-a/share"
A_BIN="$SANDBOX_HOME/install-a/bin"
a_out="$SANDBOX_ROOT/a.out"
env "${SANDBOX_ENV_ARGS[@]}" \
    TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_TAGGED" \
    TEMPERLOOP_HOME="$A_HOME" \
    TEMPERLOOP_BIN_DIR="$A_BIN" \
    sh "$BOOTSTRAP_SH" >"$a_out" 2>&1 \
  || fail "A: fresh bootstrap against FIXTURE_TAGGED must succeed (output: $(cat "$a_out"))"
grep -qF "pinning fresh install to latest release tag v9.2.0" "$a_out" \
  || fail "A: expected the 'pinning fresh install to latest release tag v9.2.0' line (output: $(cat "$a_out"))"
[ "$(git -C "$A_HOME" describe --tags --exact-match HEAD 2>/dev/null)" = "v9.2.0" ] \
  || fail "A: fresh install must land exactly on v9.2.0, not the untagged tip"
[ -x "$A_BIN/temperloop" ] || fail "A: temperloop must be symlinked onto TEMPERLOOP_BIN_DIR"
pass "A: a fresh bootstrap clones with tag-resolvable history and lands on the latest release tag (v9.2.0), not the untagged mainline tip"

# ===========================================================================
# 4. RUN B — fresh bootstrap against FIXTURE_NOTAGS falls back to the
#    default branch, with an explicit warning (acceptance criterion 1).
# ===========================================================================
B_HOME="$SANDBOX_HOME/install-b/share"
B_BIN="$SANDBOX_HOME/install-b/bin"
b_out="$SANDBOX_ROOT/b.out"
env "${SANDBOX_ENV_ARGS[@]}" \
    TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_NOTAGS" \
    TEMPERLOOP_HOME="$B_HOME" \
    TEMPERLOOP_BIN_DIR="$B_BIN" \
    sh "$BOOTSTRAP_SH" >"$b_out" 2>&1 \
  || fail "B: fresh bootstrap against a tagless remote must still succeed (output: $(cat "$b_out"))"
grep -qF "WARNING — no release tags" "$b_out" \
  || fail "B: expected the no-release-tags WARNING (output: $(cat "$b_out"))"
grep -qF "staying on '$notags_branch'" "$b_out" \
  || fail "B: expected the warning to name the branch it fell back to ('$notags_branch') (output: $(cat "$b_out"))"
if git -C "$B_HOME" describe --tags --exact-match HEAD >/dev/null 2>&1; then
  fail "B: a tagless remote must NOT leave the clone sitting on any tag"
fi
[ "$(git -C "$B_HOME" symbolic-ref --short -q HEAD)" = "$notags_branch" ] \
  || fail "B: the clone must stay on the default branch tip ('$notags_branch') when no tag exists"
pass "B: a tagless remote falls back to the default branch tip, with an explicit WARNING naming it"

# ===========================================================================
# 5. RUN C — a re-run of bootstrap against A's install delegates to
#    'temperloop update' (never pulls). Cut a newer tag (v9.3.0) upstream
#    first so there is something to (decline to) move to.
# ===========================================================================
echo "fixture: v9.3.0 follow-on" >> "$FIXTURE_TAGGED/.fixture-marker"
git -C "$FIXTURE_TAGGED" add .fixture-marker
git -C "$FIXTURE_TAGGED" commit -q -m "fixture: follow-on (v9.3.0)"
git -C "$FIXTURE_TAGGED" tag -a v9.3.0 -m v9.3.0

# 5a. Non-interactive, no consent available: update REFUSES, HEAD untouched
#     — bootstrap itself must still exit 0 (a declined update is a legible
#     no-op, not a bootstrap failure), and must never have pulled.
c1_out="$SANDBOX_ROOT/c1.out"
env "${SANDBOX_ENV_ARGS[@]}" \
    TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_TAGGED" \
    TEMPERLOOP_HOME="$A_HOME" \
    TEMPERLOOP_BIN_DIR="$A_BIN" \
    sh "$BOOTSTRAP_SH" </dev/null >"$c1_out" 2>&1 \
  || fail "C1: a re-run whose delegated update is refused must still exit 0 from bootstrap's own perspective (output: $(cat "$c1_out"))"
grep -qF "delegating to 'temperloop update'" "$c1_out" \
  || fail "C1: expected the delegation line (output: $(cat "$c1_out"))"
grep -qF "REFUSED — non-interactive with no --yes" "$c1_out" \
  || fail "C1: expected update's own non-interactive refusal (output: $(cat "$c1_out"))"
grep -qF "aborted — HEAD not moved, nothing written" "$c1_out" \
  || fail "C1: expected update's own 'aborted — HEAD not moved' line (output: $(cat "$c1_out"))"
if grep -qiF "pull" "$c1_out"; then
  fail "C1: bootstrap must never mention pulling on a re-run (output: $(cat "$c1_out"))"
fi
[ "$(git -C "$A_HOME" describe --tags --exact-match HEAD 2>/dev/null)" = "v9.2.0" ] \
  || fail "C1: HEAD must remain at v9.2.0 after a declined delegated update"
pass "C1: a non-interactive re-run delegates to 'temperloop update', which REFUSES (no timeout-as-consent) and leaves HEAD untouched — never a pull"

# 5b. Simulated interactive consent ("y"): the SAME delegation actually
#     moves HEAD to v9.3.0 — proving this is a real delegation, not a
#     permanent no-op.
c2_out="$SANDBOX_ROOT/c2.out"
printf 'y\n' | env "${SANDBOX_ENV_ARGS[@]}" \
    UPDATE_ASSUME_TTY=1 \
    TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_TAGGED" \
    TEMPERLOOP_HOME="$A_HOME" \
    TEMPERLOOP_BIN_DIR="$A_BIN" \
    sh "$BOOTSTRAP_SH" >"$c2_out" 2>&1 \
  || fail "C2: a re-run with simulated interactive consent must succeed (output: $(cat "$c2_out"))"
grep -qF "delegating to 'temperloop update'" "$c2_out" \
  || fail "C2: expected the delegation line (output: $(cat "$c2_out"))"
[ "$(git -C "$A_HOME" describe --tags --exact-match HEAD 2>/dev/null)" = "v9.3.0" ] \
  || fail "C2: a consented delegated update must move HEAD to v9.3.0"
pass "C2: with consent given to the delegated 'temperloop update', HEAD actually moves (v9.2.0 -> v9.3.0) — confirms this is a real delegation"

# ===========================================================================
# 6. RUN D — a re-run against an install that predates the 'update'
#    subcommand fails legibly with a stated recovery, never a dead end
#    (acceptance criterion 2).
# ===========================================================================
D_HOME="$SANDBOX_HOME/install-d/share"
D_BIN="$SANDBOX_HOME/install-d/bin"
env "${SANDBOX_ENV_ARGS[@]}" \
    TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_TAGGED" \
    TEMPERLOOP_HOME="$D_HOME" \
    TEMPERLOOP_BIN_DIR="$D_BIN" \
    sh "$BOOTSTRAP_SH" >/dev/null 2>&1 \
  || fail "D: setup — a fresh bootstrap for the pre-update-era simulation must succeed"
[ -f "$D_HOME/bin/subcommands/update.sh" ] \
  || fail "D: setup — expected bin/subcommands/update.sh to exist before simulating its absence"
rm -f "$D_HOME/bin/subcommands/update.sh"
d_head_before="$(git -C "$D_HOME" rev-parse HEAD)"

d_out="$SANDBOX_ROOT/d.out"
d_rc=0
env "${SANDBOX_ENV_ARGS[@]}" \
    TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_TAGGED" \
    TEMPERLOOP_HOME="$D_HOME" \
    TEMPERLOOP_BIN_DIR="$D_BIN" \
    sh "$BOOTSTRAP_SH" >"$d_out" 2>&1 || d_rc=$?
[ "$d_rc" -eq 1 ] || fail "D: a re-run against a pre-update-era install must fail (exit 1), got $d_rc (output: $(cat "$d_out"))"
grep -qF "predates the 'temperloop update' subcommand" "$d_out" \
  || fail "D: expected the predates-update-subcommand message (output: $(cat "$d_out"))"
grep -qF "Recovery" "$d_out" \
  || fail "D: expected a stated Recovery section (output: $(cat "$d_out"))"
grep -qF "rm -rf $D_HOME" "$d_out" \
  || fail "D: expected the reinstall-fresh recovery option naming \$TEMPERLOOP_HOME (output: $(cat "$d_out"))"
grep -qF "git -C $D_HOME fetch --tags" "$d_out" \
  || fail "D: expected the manual fetch/checkout recovery option (output: $(cat "$d_out"))"
[ "$(git -C "$D_HOME" rev-parse HEAD)" = "$d_head_before" ] \
  || fail "D: HEAD must be untouched by a re-run that fails before delegating"
pass "D: a re-run against an install predating 'temperloop update' fails legibly (exit 1) with a stated two-option recovery — never a dead end"

# ===========================================================================
# 7. Tripwire: $REPO_ROOT's own git state (HEAD, branch, working-tree
#    status) is byte-identical before and after the whole run — see the
#    SAFETY note in this file's header.
# ===========================================================================
repo_root_head_after="$(git -C "$REPO_ROOT" rev-parse HEAD)"
repo_root_branch_after="$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD || echo DETACHED)"
repo_root_status_after="$(git -C "$REPO_ROOT" status --porcelain)"
[ "$repo_root_head_before" = "$repo_root_head_after" ] \
  || fail "7: \$REPO_ROOT's own HEAD commit changed during this suite — see the header's SAFETY note"
[ "$repo_root_branch_before" = "$repo_root_branch_after" ] \
  || fail "7: \$REPO_ROOT's own branch changed during this suite (before: $repo_root_branch_before, after: $repo_root_branch_after) — see the header's SAFETY note"
[ "$repo_root_status_before" = "$repo_root_status_after" ] \
  || fail "7: \$REPO_ROOT's own working-tree status changed during this suite — see the header's SAFETY note"
pass "7: \$REPO_ROOT's own HEAD/branch/working-tree status are byte-identical before and after this suite"

sandbox_root_snapshot="$SANDBOX_ROOT"
sandbox_down
[ ! -e "$sandbox_root_snapshot" ] || fail "sandbox_down did not remove the throwaway root ($sandbox_root_snapshot still exists)"

echo
echo "ALL PASS: test_bootstrap_tag_pinning.sh"
