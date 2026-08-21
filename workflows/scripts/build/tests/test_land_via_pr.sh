#!/usr/bin/env bash
#
# Tests for the THREE-TIER PR resolve in workflows/scripts/lib/land-on-protected-main.sh
# (`land__via_pr`, #27). Zero network, fully hermetic: a local bare repo stands in for
# origin and a fake gh drives each tier. Exercised through archive-plan.sh, the real
# caller of the shared protected-main kernel.
#
# The bug: `$LAND_BRANCH` is a reused, orchestrator-owned ref, so a PRIOR run's open PR
# is the common case. The old adopt-or-open step dead-ended as
# "could not open or find the PR for branch" because
#   - `pr list --head` is SEARCH-INDEX backed and lags the just-completed force-push, so
#     an empty result is not proof no PR exists; and
#   - `pr create` refuses a duplicate, exits non-zero, and prints the existing PR's URL
#     to STDERR — which `2>/dev/null` discarded, throwing away the recoverable number.
#
# Covers:
#   1. tier 2 adopt: list empty + create refuses on stderr → adopt the existing PR.
#   2. tier 2 precision: a trailing number AFTER the URL must not be misread as the PR
#      (the old bare `[0-9]+$` would have grabbed it).
#   3. tier 3 adopt: list empty + create yields no URL → `pr view <branch>` adopts.
#   4. tier 1/open-new: create succeeds → that PR, without consulting `pr view`.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/archive-plan.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/land-via-pr-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

PLAN_SRC="$WORK/2026-07-25 temperloop - land via pr.md"
printf -- '---\nstatus: done\nepic: 27\n---\n# Test plan\n\n- [x] item one\n' > "$PLAN_SRC"

# A neutral placeholder host/org — this is shippable kernel test data, so it carries no
# real org or repo name (see workflows/scripts/kernel/personal-token-denylist.tsv).
ORIGIN_URL="https://example.test/example-org/example-repo"

# Build a fresh protected-main repo + a fake gh with the given case body.
# Sets REPO/BARE/GHLOG in the caller's scope.
setup_case() {  # <case-name> <gh-case-body>
  local name="$1" body="$2"
  BARE="$WORK/$name-origin.git"
  REPO="$WORK/$name-repo"
  GHLOG="$WORK/$name-gh.log"
  local fakebin="$WORK/$name-bin"

  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GHLOG"
$body
EOF
  chmod +x "$fakebin/gh"
  GH="$fakebin/gh"

  git init -q --bare "$BARE"
  git -C "$BARE" symbolic-ref HEAD refs/heads/main
  mkdir -p "$REPO/Plans-archive"
  git -C "$REPO" -c init.defaultBranch=main init -q
  git -C "$REPO" config user.email t@t.t
  git -C "$REPO" config user.name t
  ( cd "$REPO" && : > .keep && git add -A && git commit -qm seed )
  git -C "$REPO" remote add origin "$BARE"
  git -C "$REPO" push -q -u origin main
}

run_case() {
  PLAN_ARCHIVE_REQUIRES_PR=1 PLAN_ARCHIVE_GH="$GH" \
    bash "$SCRIPT" "$PLAN_SRC" 27 "$REPO"
}

# --- 1. tier 2 adopt: create refuses a duplicate, URL only on stderr ----------
# The old code did `2>/dev/null | grep -oE '[0-9]+$'` and lost this entirely.
setup_case adopt-stderr '
case "$1 $2" in
  "pr list")   exit 0 ;;                                  # index lag: looks like no PR
  "pr create") echo "a pull request for branch \"chore/plan-archive\" into branch \"main\" already exists: '"$ORIGIN_URL"'/pull/25" >&2; exit 1 ;;
  "pr view")   echo "99" ;;                               # must NOT be reached
  *)           exit 0 ;;
esac
'
out="$(run_case)"
[[ "$out" == *"plan-archive-pending: 25"* ]] \
  || fail "tier 2: expected adopt of existing PR 25 (got: $out)"
grep -q "pr merge 25 --auto" "$GHLOG" || fail "tier 2: 'pr merge 25 --auto' not recorded"
grep -q "pr view" "$GHLOG" && fail "tier 2: tier 3 consulted even though create recovered the number"
pass "tier 2 adopt: existing-PR URL recovered from stderr (was discarded by 2>/dev/null)"

# --- 2. tier 2 precision: a trailing number after the URL is not the PR -------
# The old bare `[0-9]+$ | tail -1` would have resolved 30 here instead of 25.
setup_case adopt-trailing '
case "$1 $2" in
  "pr list")   exit 0 ;;
  "pr create") printf "already exists: %s/pull/25\nplease retry in 30\n" "'"$ORIGIN_URL"'" >&2; exit 1 ;;
  *)           exit 0 ;;
esac
'
out="$(run_case)"
[[ "$out" == *"plan-archive-pending: 25"* ]] \
  || fail "tier 2 precision: expected 25 from the /pull/<n> URL, not a trailing digit (got: $out)"
grep -q "pr merge 25 --auto" "$GHLOG" || fail "tier 2 precision: merged the wrong PR number"
pass "tier 2 precision: /pull/<n> matched, trailing 'retry in 30' not misread as the PR"

# --- 3. tier 3 adopt: create yields no URL, pr view resolves by head ref ------
setup_case adopt-prview '
case "$1 $2" in
  "pr list")   exit 0 ;;
  "pr create") echo "GraphQL: something transient went wrong" >&2; exit 1 ;;
  "pr view")   echo "42" ;;                               # authoritative head-ref lookup
  *)           exit 0 ;;
esac
'
out="$(run_case)"
[[ "$out" == *"plan-archive-pending: 42"* ]] \
  || fail "tier 3: expected pr view to adopt PR 42 (got: $out)"
grep -q "pr merge 42 --auto" "$GHLOG" || fail "tier 3: 'pr merge 42 --auto' not recorded"
pass "tier 3 adopt: pr view <branch> resolved the PR the search index had not surfaced"

# --- 4. tier 1/open-new: create succeeds, no pr view needed -------------------
setup_case open-new '
case "$1 $2" in
  "pr list")   exit 0 ;;
  "pr create") echo "'"$ORIGIN_URL"'/pull/777" ;;
  "pr view")   echo "99" ;;                               # must NOT be reached
  *)           exit 0 ;;
esac
'
out="$(run_case)"
[[ "$out" == *"plan-archive-pending: 777"* ]] \
  || fail "open-new: expected the freshly created PR 777 (got: $out)"
grep -q "pr merge 777 --auto" "$GHLOG" || fail "open-new: 'pr merge 777 --auto' not recorded"
grep -q "pr view" "$GHLOG" && fail "open-new: pr view consulted despite a successful create"
pass "open-new: a successful create resolves without falling through to pr view"

echo "ALL PASS: land__via_pr three-tier PR resolve (#27)"
