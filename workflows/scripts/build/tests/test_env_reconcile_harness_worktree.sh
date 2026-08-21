#!/usr/bin/env bash
#
# test_env_reconcile_harness_worktree.sh — the harness-agent-worktree
# discrimination suite for env-reconcile.sh (temperloop#1405).
#
# WHY THIS SUITE EXISTS. Claude Code's own agent isolation
# (`isolation: "worktree"`) creates worktrees under
# <checkout>/.claude/worktrees/agent-<id>/ — INSIDE the checkout, untracked, on
# a machine-made `worktree-agent-<id>` branch. env-reconcile.sh only ever walked
# the <repo>.wt/<slug> layout worktree.sh uses, so these were never classified
# at all. What an operator saw instead was the PARENT checkout reporting a bare
# `DIRTY` (cron role) or `STALE_UNTRACKED:.claude/worktrees/` (operator role):
# an opaque class with no remedy pointer, which said something was there but not
# what to do about it — and MASKED any real drift sitting beside it. Observed
# live 2026-08-13 on two checkouts (4 worktrees 8 days stale, 3 worktrees 27
# days stale, plus their leftover `worktree-agent-*` branches).
#
# The contract under test is three-sided:
#
#   1. A harness worktree is classified as its OWN named class
#      (HARNESS_WORKTREE:<reason>), never as an opaque parent-level DIRTY, and
#      the finding line carries a REMEDY POINTER — the exact removal command,
#      including the leftover branch.
#   2. The new class NEVER swallows real drift. A genuinely dirty non-harness
#      worktree still reports DIRTY_WORKTREE, and a checkout that is dirty for
#      any OTHER reason still reports DIRTY even while its .claude/worktrees/ is
#      excluded.
#   3. Removability is still earned, not assumed: only a stale AND clean harness
#      worktree is offered as removable (HARNESS_WORKTREE:STALE); one carrying
#      uncommitted work is STALE_DIRTY, report-only, and one still inside the
#      staleness horizon is ACTIVE — a named line, never counted as drift,
#      because a live agent may still be working in it.
#
# FIXTURE-BASED AND HERMETIC: throwaway real-git repos in a tmpdir plus a
# stubbed `gh` on PATH. It never reads the ambient checkout's real worktrees,
# never touches the network, and asserts at the end that it mutated nothing.
#
# DISCRIMINATION IS BUILT IN, not asserted in prose. Four mutations re-run the
# identical fixtures against a deliberately-broken classifier — the harness arm
# removed, the parent-checkout exclusion removed, the exclusion made
# over-broad, and the harness test made unconditional — and REQUIRE this
# suite's own assertions to go RED in each. A green run therefore proves the
# assertions can fail, not merely that they currently pass.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env-reconcile.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Fixture: an upstream with a TRACKED .claude/ file ───────────────────────
# Load-bearing: with nothing tracked under .claude/, git collapses the whole
# directory to `?? .claude/` and the real-world entry this suite is about
# (`?? .claude/worktrees/`) never appears. A real checkout has tracked content
# there, so the fixture must too.
git init -q --initial-branch=main "$TMP/upstream"
mkdir -p "$TMP/upstream/.claude"
printf '{}\n' > "$TMP/upstream/.claude/settings.json"
git -C "$TMP/upstream" add -A
git -C "$TMP/upstream" commit -q -m init

clone_to() {  # <name> -> prints the symlink-resolved checkout root
  git clone -q "$TMP/upstream" "$TMP/$1"
  (cd "$TMP/$1" && pwd -P)
}

CRON="$(clone_to cron)"                 # only dirt is .claude/worktrees/
CRON_DIRTY="$(clone_to cron-dirty)"     # .claude/worktrees/ PLUS real dirt
OPERATOR="$(clone_to operator)"         # hosts a <repo>.wt/ worktree too
WT_ROOT="${OPERATOR}.wt"

HARNESS_SUBDIR=".claude/worktrees"
STALE_STAMP=202601010000               # ~7 months back; horizon default is 7d

# add_harness <checkout> <agent-id> — a REGISTERED harness worktree, exactly the
# shape `isolation: "worktree"` produces (branch `worktree-agent-<id>`).
add_harness() {
  local repo="$1" id="$2"
  git -C "$repo" worktree add -q -b "worktree-agent-$id" \
    "$repo/$HARNESS_SUBDIR/agent-$id" origin/main
}

# backdate <dir> — push the directory's mtime past the staleness horizon. Called
# immediately before each classification rather than once at fixture time, so a
# probe that happens to touch the directory cannot silently un-stale it.
backdate() { touch -t "$STALE_STAMP" "$1"; }

add_harness "$CRON" active
add_harness "$CRON" stale
add_harness "$CRON" stale-dirty
printf 'unsaved agent work nobody has committed\n' \
  > "$CRON/$HARNESS_SUBDIR/agent-stale-dirty/UNSAVED.txt"

add_harness "$CRON_DIRTY" x
printf 'real untracked drift, nothing to do with the harness\n' > "$CRON_DIRTY/REAL-DIRT.txt"

# A NON-harness worktree carrying uncommitted work on a merged branch — the
# control for "the new class must not swallow real drift".
git -C "$OPERATOR" worktree add -q -b fix/merged-dirty "$WT_ROOT/merged-dirty" origin/main
printf 'uncommitted work in a merged worktree\n' > "$WT_ROOT/merged-dirty/UNSAVED.txt"
MERGED_BRANCHES="fix/merged-dirty"

# ── Stub gh on PATH (same shape as the sibling worktree-class suite's) ───────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  branch="$3"
  case " ${GH_MOCK_MERGED_BRANCHES:-} " in
    *" $branch "*) echo MERGED ;;
    *) echo OPEN ;;
  esac
  exit 0
fi
exit 1
FAKE_GH
chmod +x "$TMP/bin/gh"

# ── Harness: call one classifier directly, optionally with a MUTATION ────────
# env-reconcile.sh is safely sourceable (its own header contract) — `set --`
# first so the sourced arg-parse loop sees no positional parameters.
cat > "$TMP/call.sh" <<'HARNESS'
#!/usr/bin/env bash
set -uo pipefail
script="$1"; fn="$2"; a="$3"; b="${4:-}"; mutation="${5:-none}"
set --
# shellcheck disable=SC1090
source "$script"
case "$mutation" in
  no-harness-arm)
    # PRE-FIX behaviour: the harness layout is not recognised at all.
    _is_harness_worktree() { return 1; }
    ;;
  no-parent-exclusion)
    # PRE-FIX behaviour: .claude/worktrees/ still counts as parent-level dirt.
    _status_porcelain_sans_harness() { git -C "$1" status --porcelain 2>/dev/null; }
    ;;
  exclusion-too-broad)
    # The over-correction: the exclusion swallows EVERY dirty path.
    _status_porcelain_sans_harness() { printf ''; }
    ;;
  harness-everywhere)
    # The over-correction on the worktree side: every worktree reads as harness.
    _is_harness_worktree() { return 0; }
    ;;
esac
if [ -n "$b" ]; then "$fn" "$a" "$b"; else "$fn" "$a"; fi
printf '\n'
HARNESS
chmod +x "$TMP/call.sh"

call() {  # <fn> <arg1> [arg2] [mutation]
  PATH="$TMP/bin:$PATH" GH_MOCK_MERGED_BRANCHES="$MERGED_BRANCHES" \
    bash "$TMP/call.sh" "$SCRIPT" "$@"
}

call_with_merged() {  # <merged-set> <fn> <arg1> [arg2] [mutation]
  local merged="$1"; shift
  PATH="$TMP/bin:$PATH" GH_MOCK_MERGED_BRANCHES="$merged" \
    bash "$TMP/call.sh" "$SCRIPT" "$@"
}

classify_h() {  # <checkout> <agent-id> [mutation] -> class token
  backdate "$1/$HARNESS_SUBDIR/agent-$2"
  call classify_worktree "$1" "$1/$HARNESS_SUBDIR/agent-$2" "${3:-none}"
}

# ── 1. A harness worktree gets its OWN named class ──────────────────────────
got="$(call classify_worktree "$CRON" "$CRON/$HARNESS_SUBDIR/agent-active")"
[ "$got" = "HARNESS_WORKTREE:ACTIVE:agent-active" ] \
  || fail "a fresh harness worktree should be HARNESS_WORKTREE:ACTIVE, got '$got'"
echo "PASS: fresh harness worktree -> HARNESS_WORKTREE:ACTIVE (named, not drift)"

got="$(classify_h "$CRON" stale)"
[ "$got" = "HARNESS_WORKTREE:STALE:agent-stale" ] \
  || fail "a stale clean harness worktree should be HARNESS_WORKTREE:STALE, got '$got'"
echo "PASS: stale + clean harness worktree -> HARNESS_WORKTREE:STALE"

got="$(classify_h "$CRON" stale-dirty)"
[ "$got" = "HARNESS_WORKTREE:STALE_DIRTY:agent-stale-dirty" ] \
  || fail "a stale harness worktree carrying uncommitted work should be HARNESS_WORKTREE:STALE_DIRTY, got '$got'"
echo "PASS: stale harness worktree with unsaved work -> STALE_DIRTY (report-only)"

# ── 2. The new class does not swallow a genuinely dirty NON-harness worktree ─
got="$(call classify_worktree "$OPERATOR" "$WT_ROOT/merged-dirty")"
[ "$got" = "DIRTY_WORKTREE:MERGED:merged-dirty" ] \
  || fail "a dirty non-harness worktree must still report DIRTY_WORKTREE:MERGED, got '$got'"
echo "PASS: dirty non-harness worktree still reports DIRTY_WORKTREE (not swallowed)"

# ── 3. The parent checkout stops reporting an opaque DIRTY on their behalf ───
got="$(call classify_cron_checkout "$CRON")"
case "$got" in
  *DIRTY*) fail "a cron checkout whose ONLY dirt is $HARNESS_SUBDIR/ must not report DIRTY, got '$got'" ;;
esac
echo "PASS: cron checkout dirty ONLY from $HARNESS_SUBDIR/ no longer reports opaque DIRTY"

got="$(call classify_cron_checkout "$CRON_DIRTY")"
case "$got" in
  *DIRTY*) ;;
  *) fail "a cron checkout with real dirt beside $HARNESS_SUBDIR/ must STILL report DIRTY, got '$got'" ;;
esac
echo "PASS: real dirt beside $HARNESS_SUBDIR/ still reports DIRTY (exclusion is path-scoped)"

# ── 4. The remedy NEVER force-deletes an unconfirmed branch ─────────────────
# §3e caught this independently in BOTH the shell and workflow reviewers: the
# remedy emitted an unconditional `git branch -D`, and /tidy runs it VERBATIM,
# UNATTENDED, as auto-heal. `-D` is git's FORCE delete — it deliberately
# bypasses the not-fully-merged refusal that is the only thing between an
# automated sweep and somebody's unmerged commits.
#
# 4a: branch NOT confirmed merged -> the directory is still reclaimed, the
# branch is KEPT, and the remedy SAYS so. 4b: confirmed merged -> the branch
# is offered for deletion, and even then with `-d`, so git's own refusal stays
# as a backstop if merged-detection is ever wrong.

# 4a — unmerged (the default MERGED_BRANCHES set does not contain it)
got="$(call _harness_worktree_remedy "$CRON" "$CRON/$HARNESS_SUBDIR/agent-stale")"
case "$got" in
  *"branch -D"*) fail "4a: an UNMERGED branch must never be handed a force-delete; got '$got'" ;;
esac
case "$got" in
  *"worktree remove $CRON/$HARNESS_SUBDIR/agent-stale"*"KEPT"*) ;;
  *) fail "4a: the remedy must still reclaim the directory and SAY the branch was kept, got '$got'" ;;
esac
echo "PASS: 4a remedy for an UNMERGED branch reclaims the directory and keeps the branch, explicitly"

# 4b — confirmed merged
got="$(call_with_merged "worktree-agent-stale" _harness_worktree_remedy "$CRON" "$CRON/$HARNESS_SUBDIR/agent-stale")"
case "$got" in
  *"branch -d worktree-agent-stale"*) ;;
  *) fail "4b: a CONFIRMED-MERGED branch should be offered for safe (-d) deletion, got '$got'" ;;
esac
case "$got" in
  *"branch -D"*) fail "4b: even a merged branch must not be force-deleted; git's refusal is the backstop, got '$got'" ;;
esac
echo "PASS: 4b remedy for a CONFIRMED-MERGED branch offers -d, never -D"

# 4c — the original assertion, minus the force flag: both halves still named
got="$(call_with_merged "worktree-agent-stale" _harness_worktree_remedy "$CRON" "$CRON/$HARNESS_SUBDIR/agent-stale")"
case "$got" in
  *"worktree remove $CRON/$HARNESS_SUBDIR/agent-stale"*"branch -d worktree-agent-stale"*) ;;
  *) fail "the remedy must name both the worktree removal and its leftover branch, got '$got'" ;;
esac
echo "PASS: 4c remedy pointer still names the removal AND the leftover worktree-agent-* branch"

# ── 5. End-to-end: report + entry carry the class and the remedy ────────────
run_reconcile() {  # <format>
  PATH="$TMP/bin:$PATH" \
  GH_MOCK_MERGED_BRANCHES="$MERGED_BRANCHES" \
  ENV_RECONCILE_CRON_CHECKOUTS="$CRON" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$TMP/no-such-operator-checkout" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/no-such-launchd-dir" \
    bash "$SCRIPT" --format "$1"
}

backdate "$CRON/$HARNESS_SUBDIR/agent-stale"
backdate "$CRON/$HARNESS_SUBDIR/agent-stale-dirty"
report="$(run_reconcile report)" || fail "--format report exited non-zero; output:
$report"

grep -q "HARNESS_WORKTREE:STALE:agent-stale" <<<"$report" \
  || fail "report should surface the stale harness worktree by class; output:
$report"
grep -qE "HARNESS +.*agent-active +\[HARNESS_WORKTREE:ACTIVE" <<<"$report" \
  || fail "report should surface the ACTIVE harness worktree on its own non-drift line; output:
$report"
grep -qE "DRIFT +$CRON +\[.*DIRTY" <<<"$report" \
  && fail "the cron checkout should no longer report DIRTY on the harness worktrees' behalf; output:
$report"
echo "PASS: report names the harness class and drops the parent's opaque DIRTY"

entry="$(run_reconcile entry)" || fail "--format entry exited non-zero; output:
$entry"
grep -qF "remedy — remove it and its leftover branch:" <<<"$entry" \
  || fail "the entry block must carry a remedy pointer for the stale harness worktree; output:
$entry"
grep -qF "REPORT ONLY, never remove: $CRON/$HARNESS_SUBDIR/agent-stale-dirty" <<<"$entry" \
  || fail "the STALE_DIRTY finding must tell the consumer not to remove it; output:
$entry"
grep -q "agent-active" <<<"$entry" \
  && fail "an ACTIVE harness worktree must not appear as a drift finding; output:
$entry"
echo "PASS: entry block carries the remedy, the report-only disposition, and no ACTIVE noise"

# ── 6. READ-ONLY: every fixture worktree and every unsaved byte survives ────
for d in active stale stale-dirty; do
  [ -d "$CRON/$HARNESS_SUBDIR/agent-$d" ] \
    || fail "env-reconcile.sh removed agent-$d (it must be READ-ONLY)"
done
grep -q 'unsaved agent work nobody has committed' \
  "$CRON/$HARNESS_SUBDIR/agent-stale-dirty/UNSAVED.txt" \
  || fail "uncommitted work in agent-stale-dirty was altered (env-reconcile.sh must be READ-ONLY)"
[ -f "$CRON_DIRTY/REAL-DIRT.txt" ] || fail "env-reconcile.sh removed the real-dirt fixture file"
echo "PASS: read-only -- every harness worktree and every uncommitted byte survived"

# ── 7. DISCRIMINATION A: remove the harness arm ─────────────────────────────
# Every harness assertion in section 1 must go RED — that IS the #1405 defect.
for id in active stale stale-dirty; do
  got="$(classify_h "$CRON" "$id" no-harness-arm)"
  case "$got" in
    HARNESS_WORKTREE:*) fail "discrimination A: with the harness arm removed, agent-$id must NOT be classified HARNESS_WORKTREE (got '$got') — the suite would not have caught #1405" ;;
  esac
done
echo "PASS: discrimination A -- removing the harness arm turns every HARNESS_WORKTREE assertion RED"

# ── 8. DISCRIMINATION B: remove the parent-checkout exclusion ───────────────
# The section-3 "no longer opaque DIRTY" assertion must go RED.
got="$(call classify_cron_checkout "$CRON" "" no-parent-exclusion)"
case "$got" in
  *DIRTY*) ;;
  *) fail "discrimination B: without the exclusion the cron checkout should report the pre-fix opaque DIRTY (got '$got') — the suite would not have caught the masking" ;;
esac
echo "PASS: discrimination B -- removing the exclusion restores the pre-fix opaque DIRTY"

# ── 9. DISCRIMINATION C: over-broad exclusion swallows real dirt ────────────
# The section-3 "real dirt still reports DIRTY" assertion must go RED. This is
# the half that proves the new class cannot quietly hide drift.
got="$(call classify_cron_checkout "$CRON_DIRTY" "" exclusion-too-broad)"
case "$got" in
  *DIRTY*) fail "discrimination C: an over-broad exclusion should have swallowed the real dirt (got '$got') — the not-swallowed assertion cannot fail and proves nothing" ;;
esac
echo "PASS: discrimination C -- an over-broad exclusion turns the real-dirt assertion RED"

# ── 10. DISCRIMINATION D: harness test made unconditional ───────────────────
# The section-2 "dirty non-harness worktree still reports DIRTY_WORKTREE"
# assertion must go RED.
got="$(call classify_worktree "$OPERATOR" "$WT_ROOT/merged-dirty" harness-everywhere)"
case "$got" in
  HARNESS_WORKTREE:*) ;;
  *) fail "discrimination D: with the harness test unconditional the dirty non-harness worktree should be misclassified as HARNESS_WORKTREE (got '$got') — the not-swallowed assertion cannot fail" ;;
esac
echo "PASS: discrimination D -- an unconditional harness test turns the non-harness DIRTY assertion RED"

echo "ALL PASS: test_env_reconcile_harness_worktree.sh"
