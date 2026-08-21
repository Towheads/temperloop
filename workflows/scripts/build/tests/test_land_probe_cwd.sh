#!/usr/bin/env bash
#
# Tests for the LAND_ROOT-anchored repo resolution in
# workflows/scripts/lib/land-on-protected-main.sh (#873). Zero network, fully
# hermetic: real local git repos + a fake gh that records every call.
#
# The bug: `land__requires_pr` ran `gh repo view --json nameWithOwner` with no `-R`
# and no `cd`, so `gh` resolved the repo from the CALLER's cwd, not $LAND_ROOT.
# Invoked from outside a git repo (the nightly drain runs from the knowledge store)
# the probe errored, returned false, and the lib SILENTLY took the direct-push path
# — a 44h archive stall whose only symptom was "direct push to main rejected".
#
# Covers:
#   1. non-repo cwd     → probe resolves $LAND_ROOT's slug (and never calls `repo view`).
#   2. in-repo cwd      → same slug as (1): cwd does not change the answer.
#   3. foreign-repo cwd → still $LAND_ROOT's slug, NOT the cwd repo's (the old bug).
#   4. probe error      → returns false (fail-open) but PRINTS why on stderr.
#   5. unresolvable origin → returns false and prints why (never silent).
#   6. no remote        → returns false SILENTLY (structural, not a probe failure).
#   7. scp-form + ssh:// + trailing-slash origins parse to <owner>/<repo>.
#   8. every `gh pr …` call is anchored with `-R <owner>/<repo>`.
#   9. driver end-to-end: archive-plan.sh run from a non-repo cwd still lands.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$HERE/../../lib" && pwd)/land-on-protected-main.sh"
SCRIPT="$(cd "$HERE/.." && pwd)/archive-plan.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/land-probe-cwd-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

NOTAREPO="$WORK/not-a-repo"; mkdir -p "$NOTAREPO"

# A neutral placeholder host/org — shippable kernel test data carries no real org or
# repo name (see workflows/scripts/kernel/personal-token-denylist.tsv).
HOST="example.test"

# A git repo whose `origin` is <url>. Echoes its path.
mkrepo() {  # <name> [origin-url]
  local dir="$WORK/$1"
  mkdir -p "$dir"
  git -C "$dir" -c init.defaultBranch=main init -q
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  ( cd "$dir" && : > .keep && git add -A && git commit -qm seed )
  [ -n "${2:-}" ] && git -C "$dir" remote add origin "$2"
  printf '%s' "$dir"
}

# Fake gh: logs "$*" to $GHLOG; answers the ruleset probe `true` only for the slug
# example-org/example-repo, errors for any other repos/... path.
GHLOG="$WORK/gh.log"
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GHLOG"
case "\$1 \$2" in
  "api repos/example-org/example-repo/rules/branches/main") echo true ;;
  "api repos/empty-org/empty-repo/rules/branches/main")     exit 0 ;;   # 200, no verdict
  "api "*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  "pr list")   exit 0 ;;
  "pr create") echo "https://$HOST/example-org/example-repo/pull/777" ;;
  *)           exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/gh"
GH="$FAKEBIN/gh"

# shellcheck source=../../lib/land-on-protected-main.sh
. "$LIB"

export LAND_GH="$GH"
export LAND_DEFAULT_BRANCH=main
unset LAND_REQUIRES_PR || true

# Run land__requires_pr from <cwd> against <root>; sets RC/ERR, resets the log.
probe() {  # <cwd> <root>
  : > "$GHLOG"
  ERRF="$WORK/err.txt"
  LAND_ROOT="$2"
  set +e
  ( cd "$1" && land__requires_pr ) 2>"$ERRF"
  RC=$?
  set -e
  ERR="$(cat "$ERRF")"
}

HTTPS_REPO="$(mkrepo https-repo "https://$HOST/example-org/example-repo.git")"

# --- 1. non-repo cwd: the probe resolves LAND_ROOT's repo, not the cwd --------
probe "$NOTAREPO" "$HTTPS_REPO"
[ "$RC" -eq 0 ] || fail "1: probe from a non-repo cwd should see main as protected (rc=$RC, err=$ERR)"
grep -q "api repos/example-org/example-repo/rules/branches/main" "$GHLOG" \
  || fail "1: probe did not query LAND_ROOT's slug (log: $(cat "$GHLOG"))"
grep -q "repo view" "$GHLOG" \
  && fail "1: still calling 'gh repo view' — that is the cwd-dependent call #873 removed"
[ -z "$ERR" ] || fail "1: a successful probe should print nothing on stderr (got: $ERR)"
pass "non-repo cwd: probe resolves owner/repo from LAND_ROOT, no cwd-dependent 'repo view'"
FIRST_LOG="$(cat "$GHLOG")"

# --- 2. in-repo cwd: identical resolution ------------------------------------
probe "$HTTPS_REPO" "$HTTPS_REPO"
[ "$RC" -eq 0 ] || fail "2: probe from inside the repo should see main as protected (rc=$RC)"
[ "$(cat "$GHLOG")" = "$FIRST_LOG" ] \
  || fail "2: in-repo cwd resolved differently than a non-repo cwd ($(cat "$GHLOG") vs $FIRST_LOG)"
pass "in-repo cwd: same repo resolved, byte-identical gh call"

# --- 3. foreign-repo cwd: LAND_ROOT wins, not the cwd repo -------------------
OTHER_REPO="$(mkrepo other-repo "https://$HOST/other-org/other-repo.git")"
probe "$OTHER_REPO" "$HTTPS_REPO"
[ "$RC" -eq 0 ] || fail "3: probe from a foreign repo cwd should still see main as protected (rc=$RC)"
grep -q "other-org/other-repo" "$GHLOG" \
  && fail "3: probe resolved the CWD repo instead of LAND_ROOT (log: $(cat "$GHLOG"))"
[ "$(cat "$GHLOG")" = "$FIRST_LOG" ] || fail "3: foreign cwd changed the resolved repo"
pass "foreign-repo cwd: LAND_ROOT's repo wins over the caller's repo"

# --- 4. probe error is fail-open but LOUD ------------------------------------
MISSING_REPO="$(mkrepo missing-repo "https://$HOST/missing-org/missing-repo.git")"
probe "$NOTAREPO" "$MISSING_REPO"
[ "$RC" -ne 0 ] || fail "4: a failed probe must not claim the branch is protected"
case "$ERR" in
  *"protection probe"*"missing-org/missing-repo"*"DIRECT"*) ;;
  *) fail "4: a probe failure must name itself, the repo, and the fallback path (got: $ERR)" ;;
esac
pass "probe error: fails open to the direct path but says so on stderr (naming repo + fallback)"

# --- 4b. a verdict-less answer (exit 0, empty body) is a couldn't-tell, also loud --
EMPTY_REPO="$(mkrepo empty-repo "https://$HOST/empty-org/empty-repo.git")"
probe "$NOTAREPO" "$EMPTY_REPO"
[ "$RC" -ne 0 ] || fail "4b: an empty probe answer must not claim the branch is protected"
case "$ERR" in
  *"unreadable answer"*"empty-org/empty-repo"*) ;;
  *) fail "4b: an empty/unexpected probe answer must be reported, not read as 'unprotected' (got: $ERR)" ;;
esac
pass "verdict-less probe answer: reported as couldn't-tell rather than silently 'unprotected'"

# --- 5. unresolvable origin is also loud -------------------------------------
LOCAL_REPO="$(mkrepo local-origin-repo "$WORK/some-origin.git")"
probe "$NOTAREPO" "$LOCAL_REPO"
[ "$RC" -ne 0 ] || fail "5: a local-path origin cannot be probed as protected"
case "$ERR" in
  *"cannot resolve owner/repo"*) ;;
  *) fail "5: an unresolvable origin must say so on stderr (got: $ERR)" ;;
esac
pass "unresolvable origin: diagnostic names the origin URL instead of branching silently"

# --- 6. no remote at all: quiet (structural, not a failure) ------------------
NOREMOTE_REPO="$(mkrepo no-remote-repo)"
probe "$NOTAREPO" "$NOREMOTE_REPO"
[ "$RC" -ne 0 ] || fail "6: a repo with no remote has no protected branch"
[ -z "$ERR" ] || fail "6: the no-remote case is structural and must stay silent (got: $ERR)"
[ -s "$GHLOG" ] && fail "6: no-remote must not spend a gh call (log: $(cat "$GHLOG"))"
pass "no remote: direct path taken with no gh call and no noise"

# --- 7. origin URL shapes ----------------------------------------------------
check_slug() {  # <label> <origin-url> <expected>
  local dir got
  dir="$(mkrepo "slug-$1" "$2")"
  LAND_ROOT="$dir"
  got="$(cd "$NOTAREPO" && land__nwo)"
  [ "$got" = "$3" ] || fail "7/$1: '$2' resolved to '$got', expected '$3'"
}
check_slug scp    "git@$HOST:example-org/example-repo.git"   "example-org/example-repo"
check_slug ssh    "ssh://git@$HOST/example-org/example-repo" "example-org/example-repo"
check_slug slash  "https://$HOST/example-org/example-repo/"  "example-org/example-repo"
check_slug local  "$WORK/some-origin.git"                    ""
pass "origin URL shapes: scp, ssh://, trailing slash resolve; a local path resolves to ''"

# --- 8. gh pr calls are anchored with -R -------------------------------------
: > "$GHLOG"
LAND_ROOT="$HTTPS_REPO"
land__gh_pr pr list --head chore/x --state open >/dev/null 2>&1 || true
grep -q -- "-R example-org/example-repo" "$GHLOG" \
  || fail "8: 'gh pr list' not anchored to LAND_ROOT's repo (log: $(cat "$GHLOG"))"
: > "$GHLOG"
LAND_ROOT="$LOCAL_REPO"
land__gh_pr pr list --head chore/x >/dev/null 2>&1 || true
grep -q -- "-R" "$GHLOG" \
  && fail "8: an unresolvable slug must not produce a bare '-R' (log: $(cat "$GHLOG"))"
pass "gh pr calls: -R <owner>/<repo> from LAND_ROOT, omitted when no slug exists"

# --- 9. driver end-to-end from a non-repo cwd --------------------------------
# archive-plan.sh is one of the two drivers of this lib (the other, foundation's
# archive-session.sh, sources the same file); run it with cwd OUTSIDE any repo.
BARE="$WORK/e2e-origin.git"
git init -q --bare "$BARE"
git -C "$BARE" symbolic-ref HEAD refs/heads/main
E2E="$(mkrepo e2e-repo "$BARE")"
mkdir -p "$E2E/Plans-archive"
git -C "$E2E" push -q -u origin main
PLAN_SRC="$WORK/2026-07-28 temperloop - probe cwd.md"
printf -- '---\nstatus: done\nepic: 873\n---\n# Test plan\n\n- [x] item one\n' > "$PLAN_SRC"
: > "$GHLOG"
out="$( cd "$NOTAREPO" && PLAN_ARCHIVE_REQUIRES_PR=1 PLAN_ARCHIVE_GH="$GH" \
        bash "$SCRIPT" "$PLAN_SRC" 873 "$E2E" )"
[[ "$out" == *"plan-archive-pending: 777"* ]] \
  || fail "9: archive-plan.sh from a non-repo cwd did not land (got: $out)"
git -C "$BARE" cat-file -e "chore/plan-archive:Plans-archive/$(basename "$PLAN_SRC")" 2>/dev/null \
  || fail "9: snapshot missing from the archive branch after a non-repo-cwd run"
pass "driver end-to-end: archive-plan.sh lands from a cwd outside the target repo"

echo "ALL PASS: LAND_ROOT-anchored repo resolution (#873)"
