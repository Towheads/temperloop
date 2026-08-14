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
# Three further legs cover the $TEMPERLOOP_KERNEL_REF ref pin
# (temperloop#1474 — the knob .github/workflows/install-tier2.yml sets on a
# `workflow_dispatch` run so its documented pre-tag dry run tests the ref it
# was dispatched against instead of the last release):
#
#   E. A fresh bootstrap with TEMPERLOOP_KERNEL_REF set lands on THAT ref and
#      not the newest tag — twice over, once with a raw commit SHA (the
#      untagged mainline commit between v9.2.0 and v9.3.0, so landing there
#      is only possible via the pin) and once with a symbolic ref that is a
#      DELIBERATELY OLDER tag (v9.1.0), proving the pin beats version sort
#      rather than merely agreeing with it.
#   F. TEMPERLOOP_KERNEL_REF set-but-EMPTY is indistinguishable from unset:
#      the newest `v*` tag, same message, byte-for-byte the leg-A behavior
#      (the `${VAR:+x}` guard's whole point).
#   G. TEMPERLOOP_KERNEL_REF naming a ref that does not resolve FAILS LOUDLY
#      (exit 1, message naming the ref) and never silently falls back to the
#      newest tag — the fallback would recreate exactly the "claims to test
#      one thing, tests another" bug the knob exists to fix.
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
# Force a KNOWN, deterministic branch name right after cloning — never rely
# on $REPO_ROOT's own currently-checked-out branch (which may itself be
# detached, e.g. a CI checkout with no refs/remotes/origin/HEAD symref; a
# local clone of a detached source can land ALSO detached, with no
# refs/heads/* at all). `checkout -B` creates-or-resets the named branch to
# HEAD's current commit and checks it out unconditionally, regardless of
# whether the clone landed on a branch, a differently-named branch, or
# nothing at all — the same determinism test_sandbox_dry_run_legs.sh /
# test_update_subcommand.sh / test_init.sh get from `git init
# --initial-branch=main`, applied post-clone since this fixture needs
# $REPO_ROOT's actual committed content, not a from-scratch init.
git -C "$FIXTURE_TAGGED" checkout -q -B main \
  || fail "1: could not force FIXTURE_TAGGED onto a deterministic 'main' branch"

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

# -q -s so a failure here degrades to "DETACHED" rather than a hard `fatal:
# ref HEAD is not a symbolic ref` — belt-and-suspenders: the forced
# `checkout -B main` above should make this always resolve to "main", but
# this read stays tolerant regardless (same idiom as this file's own
# REPO_ROOT tripwire reads below).
tagged_branch="$(git -C "$FIXTURE_TAGGED" symbolic-ref --short -q HEAD || echo DETACHED)"
[ "$tagged_branch" = "main" ] || fail "1: FIXTURE_TAGGED must be deterministically on 'main' after checkout -B (got: $tagged_branch)"
pass "1: built FIXTURE_TAGGED (v9.1.0 -> v9.2.0, tip one untagged commit further on '$tagged_branch')"

# ===========================================================================
# 2. FIXTURE_NOTAGS: same origin, zero tags.
# ===========================================================================
FIXTURE_NOTAGS="$SANDBOX_ROOT/fixture-notags"
git clone -q --no-tags "$REPO_ROOT" "$FIXTURE_NOTAGS" \
  || fail "2: could not clone $REPO_ROOT (--no-tags) to build FIXTURE_NOTAGS"
# Same deterministic-branch forcing as FIXTURE_TAGGED above.
git -C "$FIXTURE_NOTAGS" checkout -q -B main \
  || fail "2: could not force FIXTURE_NOTAGS onto a deterministic 'main' branch"
notags_branch="$(git -C "$FIXTURE_NOTAGS" symbolic-ref --short -q HEAD || echo DETACHED)"
[ "$notags_branch" = "main" ] || fail "2: FIXTURE_NOTAGS must be deterministically on 'main' after checkout -B (got: $notags_branch)"
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
# 6. RUNS E/F/G — the $TEMPERLOOP_KERNEL_REF pin (temperloop#1474).
#
# FIXTURE_TAGGED's default-branch tip is deliberately one UNTAGGED commit
# ahead of v9.2.0, which is exactly the real shape these legs care about: a
# `workflow_dispatch` against `main` when `main` is ahead of the newest
# release tag. Pinning to that tip and landing on it — rather than on
# v9.2.0 — IS the bug temperloop#1474 reports, inverted into an assertion.
# ===========================================================================
# RUN C2 tags v9.3.0 on this shared fixture to give `temperloop update`
# somewhere to move to, so neither the newest tag nor the tip is what it was
# at build time. Re-establish the shape these legs need explicitly rather
# than hardcoding a tag name that an earlier leg can invalidate: one fresh
# UNTAGGED commit on top, and the newest tag read back at this moment.
echo "fixture: untagged commit for the ref-pin legs" >> "$FIXTURE_TAGGED/.fixture-marker"
git -C "$FIXTURE_TAGGED" add .fixture-marker
git -C "$FIXTURE_TAGGED" commit -q -m "fixture: untagged commit for the ref-pin legs" \
  || fail "E: could not add the untagged tip commit the ref-pin legs need"
tagged_tip="$(git -C "$FIXTURE_TAGGED" rev-parse HEAD)"
latest_now="$(git -C "$FIXTURE_TAGGED" tag -l 'v*' --sort=-v:refname | head -n1)"
[ -n "$latest_now" ] || fail "E: fixture precondition broken — expected at least one v* tag"
[ "$(git -C "$FIXTURE_TAGGED" rev-parse "$latest_now^{commit}")" != "$tagged_tip" ] \
  || fail "E: fixture precondition broken — the tip must be AHEAD of the newest tag ($latest_now), or these legs prove nothing"

# --- E: a set ref pins to THAT ref, not the newest tag ----------------------
E_HOME="$SANDBOX_HOME/install-e/share"
E_BIN="$SANDBOX_HOME/install-e/bin"
e_out="$SANDBOX_ROOT/e.out"
env "${SANDBOX_ENV_ARGS[@]}" \
    TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_TAGGED" \
    TEMPERLOOP_KERNEL_REF="$tagged_tip" \
    TEMPERLOOP_HOME="$E_HOME" \
    TEMPERLOOP_BIN_DIR="$E_BIN" \
    sh "$BOOTSTRAP_SH" >"$e_out" 2>&1 \
  || fail "E: a fresh bootstrap with TEMPERLOOP_KERNEL_REF set must succeed (output: $(cat "$e_out"))"
[ "$(git -C "$E_HOME" rev-parse HEAD)" = "$tagged_tip" ] \
  || fail "E: the install must land on the requested ref ($tagged_tip), got $(git -C "$E_HOME" rev-parse HEAD)"
if [ "$(git -C "$E_HOME" rev-parse HEAD)" = "$(git -C "$FIXTURE_TAGGED" rev-parse "$latest_now^{commit}")" ]; then
  fail "E: the install landed on the newest tag ($latest_now) — the ref pin was ignored (the temperloop#1474 bug)"
fi
grep -qF "pinning fresh install to requested ref" "$e_out" \
  || fail "E: expected the requested-ref pin line naming \$TEMPERLOOP_KERNEL_REF (output: $(cat "$e_out"))"
[ -x "$E_BIN/temperloop" ] || fail "E1: temperloop must still be symlinked onto TEMPERLOOP_BIN_DIR"
pass "E1: TEMPERLOOP_KERNEL_REF pins a fresh install to a raw commit SHA (the untagged tip), NOT the newest release tag"

# --- E2: a SYMBOLIC ref that is an OLDER tag — the pin beats version sort ---
# E1 lands on a commit the tag sort could never have chosen, which proves the
# pin is consulted. E2 is the sharper case: v9.1.0 IS a tag, and it sorts
# BELOW the newest one, so landing there is only possible if the pin
# overrides version sort rather than coinciding with it.
E2_HOME="$SANDBOX_HOME/install-e2/share"
E2_BIN="$SANDBOX_HOME/install-e2/bin"
e2_out="$SANDBOX_ROOT/e2.out"
[ "$latest_now" != "v9.1.0" ] \
  || fail "E2: fixture precondition broken — v9.1.0 must NOT be the newest tag, or this leg proves nothing"
env "${SANDBOX_ENV_ARGS[@]}" \
    TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_TAGGED" \
    TEMPERLOOP_KERNEL_REF="v9.1.0" \
    TEMPERLOOP_HOME="$E2_HOME" \
    TEMPERLOOP_BIN_DIR="$E2_BIN" \
    sh "$BOOTSTRAP_SH" >"$e2_out" 2>&1 \
  || fail "E2: a fresh bootstrap pinned to the older tag v9.1.0 must succeed (output: $(cat "$e2_out"))"
[ "$(git -C "$E2_HOME" describe --tags --exact-match HEAD 2>/dev/null)" = "v9.1.0" ] \
  || fail "E2: the install must land on v9.1.0, got $(git -C "$E2_HOME" describe --tags --always HEAD 2>/dev/null) — version sort beat the explicit pin"
pass "E2: TEMPERLOOP_KERNEL_REF pins to an OLDER tag (v9.1.0) over the newest ($latest_now) — the pin beats version sort, it does not merely agree with it"

# --- F: set-but-EMPTY is indistinguishable from unset -----------------------
# The `${VAR:+x}` guard in bootstrap.sh is what buys this. A `${VAR:-}` guard
# would treat an empty value as "set", pin to the empty string, and fail — so
# this leg is a direct regression test on that specific expansion choice.
F_HOME="$SANDBOX_HOME/install-f/share"
F_BIN="$SANDBOX_HOME/install-f/bin"
f_out="$SANDBOX_ROOT/f.out"
env "${SANDBOX_ENV_ARGS[@]}" \
    TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_TAGGED" \
    TEMPERLOOP_KERNEL_REF="" \
    TEMPERLOOP_HOME="$F_HOME" \
    TEMPERLOOP_BIN_DIR="$F_BIN" \
    sh "$BOOTSTRAP_SH" >"$f_out" 2>&1 \
  || fail "F: a fresh bootstrap with an EMPTY TEMPERLOOP_KERNEL_REF must succeed (output: $(cat "$f_out"))"
grep -qF "pinning fresh install to latest release tag $latest_now" "$f_out" \
  || fail "F: an empty ref must take the unchanged latest-tag path (output: $(cat "$f_out"))"
[ "$(git -C "$F_HOME" describe --tags --exact-match HEAD 2>/dev/null)" = "$latest_now" ] \
  || fail "F: an empty ref must land on $latest_now exactly as an unset one does"
pass "F: TEMPERLOOP_KERNEL_REF set-but-empty is indistinguishable from unset — the default latest-tag install ($latest_now)"

# --- G: an unresolvable ref fails LOUDLY, never falls back ------------------
G_HOME="$SANDBOX_HOME/install-g/share"
G_BIN="$SANDBOX_HOME/install-g/bin"
g_out="$SANDBOX_ROOT/g.out"
g_bad_ref="no-such-ref-temperloop-1474"
if env "${SANDBOX_ENV_ARGS[@]}" \
       TEMPERLOOP_KERNEL_REPO="file://$FIXTURE_TAGGED" \
       TEMPERLOOP_KERNEL_REF="$g_bad_ref" \
       TEMPERLOOP_HOME="$G_HOME" \
       TEMPERLOOP_BIN_DIR="$G_BIN" \
       sh "$BOOTSTRAP_SH" >"$g_out" 2>&1; then
  fail "G: an unresolvable TEMPERLOOP_KERNEL_REF must FAIL, not succeed (output: $(cat "$g_out"))"
fi
grep -qF "$g_bad_ref" "$g_out" \
  || fail "G: the error must name the offending ref '$g_bad_ref' (output: $(cat "$g_out"))"
grep -qF "Refusing to fall back" "$g_out" \
  || fail "G: the error must state it is refusing to fall back to the newest tag (output: $(cat "$g_out"))"
# The load-bearing half: it must not have silently landed on v9.2.0 anyway.
if [ -d "$G_HOME/.git" ] \
   && [ "$(git -C "$G_HOME" describe --tags --exact-match HEAD 2>/dev/null || true)" = "$latest_now" ]; then
  fail "G: a bad ref silently fell back to the newest tag — exactly the failure the knob exists to prevent"
fi
[ ! -x "$G_BIN/temperloop" ] \
  || fail "G: a refused install must not leave a temperloop symlink behind"
pass "G: an unresolvable TEMPERLOOP_KERNEL_REF fails loudly naming the ref — never a silent fallback to the newest tag"

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
