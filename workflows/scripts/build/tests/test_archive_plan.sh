#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/archive-plan.sh — the build 4d-archive
# plan-snapshot lander (#408). Zero network, fully hermetic: a local bare repo
# stands in for origin and a fake gh records every call + emits a PR number.
# Exercises the SHARED protected-main kernel (../lib/land-on-protected-main.sh).
#
# Covers:
#   1. protected main → branch chore/plan-archive + PR + queue; target main left
#      pristine; status plan-archive-pr-queued; `pr merge <pr> --auto` recorded;
#      nothing committed directly to main.
#   2. self-heal: once the snapshot is on origin/main, report plan-archived
#      (already on origin) with no new PR.
#   3. unprotected / no-remote → direct in-place commit, plan-archived.
#   4. idempotent re-run (no-remote, identical content) → already current.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/archive-plan.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/archive-plan-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# A done plan note to archive (its basename is what lands in Plans-archive/).
PLAN_SRC="$WORK/2026-06-13 foundation - test epic.md"
printf -- '---\nstatus: done\nepic: 999\n---\n# Test plan\n\n- [x] item one\n' > "$PLAN_SRC"
PLAN_BASE="$(basename "$PLAN_SRC")"

# Fake gh: records every invocation; emits a PR URL on `pr create`, nothing on `pr list`.
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
GHLOG="$WORK/gh.log"
cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GHLOG"
case "\$1 \$2" in
  "pr list")   exit 0 ;;                          # no open PR -> create one
  "pr create") echo "https://example.test/Towheads/foundation/pull/777" ;;
  *)           exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/gh"

# --- 1. protected main: branch + PR + queue, target main left pristine --------
BARE="$WORK/origin.git"
REPO="$WORK/repo"
git init -q --bare "$BARE"
git -C "$BARE" symbolic-ref HEAD refs/heads/main
mkdir -p "$REPO/Plans-archive"
git -C "$REPO" -c init.defaultBranch=main init -q
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
# Seed a pre-existing archived snapshot so the additive (never-drop) copy is exercised.
prior="$REPO/Plans-archive/2026-06-01 foundation - prior.md"
printf -- '# prior snapshot\n' > "$prior"
git -C "$REPO" add -A && git -C "$REPO" commit -qm seed
git -C "$REPO" remote add origin "$BARE"
git -C "$REPO" push -q -u origin main

out="$( PLAN_ARCHIVE_REQUIRES_PR=1 PLAN_ARCHIVE_GH="$FAKEBIN/gh" \
        bash "$SCRIPT" "$PLAN_SRC" 999 "$REPO" )"
[[ "$out" == *"plan-archive-pr-queued: 777"* ]] || fail "expected plan-archive-pr-queued: 777 (got: $out)"
# the snapshot branch was pushed to origin, carrying BOTH the new and the prior note
git -C "$BARE" rev-parse --verify -q chore/plan-archive >/dev/null || fail "plan-archive branch not pushed to origin"
git -C "$BARE" cat-file -e "chore/plan-archive:Plans-archive/$PLAN_BASE" 2>/dev/null \
  || fail "new plan snapshot missing from the archive branch"
git -C "$BARE" cat-file -e "chore/plan-archive:Plans-archive/$(basename "$prior")" 2>/dev/null \
  || fail "additive copy dropped the prior archived snapshot"
# caller's main untouched (still at origin/main) and the working tree is clean
[ "$(git -C "$REPO" rev-parse main)" = "$(git -C "$REPO" rev-parse origin/main)" ] \
  || fail "local main diverged from origin after the PR path"
[ -z "$(git -C "$REPO" status --porcelain)" ] || fail "working tree left dirty after the PR path"
# queue incantation used; nothing committed directly to main
grep -q "pr merge 777 --auto" "$GHLOG" || fail "fake gh did not record 'pr merge 777 --auto'"
[[ "$(git -C "$REPO" log main --oneline)" == *"archive(plan)"* ]] && fail "snapshot wrongly committed directly to main"

# --- 2. self-heal: snapshot already on origin -> plan-archived (already on origin) --
git -C "$BARE" update-ref refs/heads/main refs/heads/chore/plan-archive  # PR "merged"
git -C "$REPO" fetch -q origin main
out="$( PLAN_ARCHIVE_REQUIRES_PR=1 PLAN_ARCHIVE_GH="$FAKEBIN/gh" \
        bash "$SCRIPT" "$PLAN_SRC" 999 "$REPO" )"
[[ "$out" == *"plan-archived:"* && "$out" == *"already on origin"* ]] \
  || fail "expected 'plan-archived: ... (already on origin)' once merged (got: $out)"

# --- 3. unprotected / no-remote: direct in-place commit ----------------------
REPO2="$WORK/repo2"
mkdir -p "$REPO2"
git -C "$REPO2" -c init.defaultBranch=main init -q
git -C "$REPO2" config user.email t@t.t; git -C "$REPO2" config user.name t
( cd "$REPO2" && : > .keep && git add -A && git commit -qm seed )
out="$( bash "$SCRIPT" "$PLAN_SRC" 999 "$REPO2" )"
[[ "$out" == *"plan-archived:"* ]] || fail "expected plan-archived on no-remote repo (got: $out)"
git -C "$REPO2" cat-file -e "main:Plans-archive/$PLAN_BASE" 2>/dev/null \
  || fail "snapshot not committed to main on the no-remote path"
[[ "$(git -C "$REPO2" log main --oneline)" == *"archive(plan)"* ]] || fail "no archive(plan) commit landed on main"

# --- 4. idempotent: identical re-run -> already current ----------------------
out="$( bash "$SCRIPT" "$PLAN_SRC" 999 "$REPO2" )"
[[ "$out" == *"already current"* ]] || fail "expected 'already current' on identical re-run (got: $out)"

echo "PASS: test_archive_plan.sh"
