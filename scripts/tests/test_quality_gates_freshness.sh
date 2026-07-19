#!/usr/bin/env bash
#
# test_quality_gates_freshness.sh — unit tests for the checkout-staleness guard
# (temperloop#591), workflows/scripts/lib/checkout-freshness.sh, which
# scripts/quality-gates.sh sources to warn (loudly, non-fatally) when it is run
# against a checkout BEHIND origin/<default> — the case where the local gate set
# + leak-guard diff base silently diverge from CI.
#
# Hermetic: every scenario runs against throwaway git repos (a bare "origin" +
# clones) under a tmpdir, all reachable over the local filesystem — no network,
# never this repo's own checkout. The lib is sourced and check_checkout_freshness
# is called directly; assertions read its CHECKOUT_BEHIND / CHECKOUT_BEHIND_REF
# globals and captured stderr.
#
# Usage: scripts/tests/test_quality_gates_freshness.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/workflows/scripts/lib/checkout-freshness.sh"

[ -f "$LIB" ] || { echo "FAIL: lib not found at $LIB" >&2; exit 1; }
# shellcheck source=workflows/scripts/lib/checkout-freshness.sh
. "$LIB"

fail_count=0
fail() { echo "FAIL: $1" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qg-freshness-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
GIT() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main -c protocol.file.allow=always "$@"; }

# make_repo <name> — bare origin + a clone on main at c1 whose branch tracks
# origin/main. Prints the clone (checkout) path.
make_repo() {
  local org="$WORK/$1.git" seed="$WORK/$1.seed" co="$WORK/$1"
  GIT init -q --bare -b main "$org"
  GIT clone -q "$org" "$seed" 2>/dev/null
  : >"$seed/f"; GIT -C "$seed" add -A; GIT -C "$seed" commit -qm c1; GIT -C "$seed" push -q origin main
  GIT clone -q "$org" "$co" 2>/dev/null
  GIT -C "$co" branch -q --set-upstream-to=origin/main main 2>/dev/null
  printf '%s' "$co"
}
# advance <name> [n] — push n (default 1) new commits to origin so a checkout of
# it (that hasn't pulled) falls behind.
advance() {
  local seed="$WORK/$1.seed" n="${2:-1}" i
  for i in $(seq 1 "$n"); do
    echo "c$i" >>"$seed/f"; GIT -C "$seed" add -A; GIT -C "$seed" commit -qm "adv$i"
  done
  GIT -C "$seed" push -q origin main
}
# run_guard <repo> — call the guard against <repo>, capture stderr to $ERRLOG.
ERRLOG="$WORK/err.log"
run_guard() { : >"$ERRLOG"; check_checkout_freshness "$1" 2>"$ERRLOG"; }

# --- 1. current checkout → 0 behind, no banner -------------------------------
co="$(make_repo current)"
run_guard "$co"
[ "$CHECKOUT_BEHIND" = 0 ] || fail "1 current: expected behind=0 (got $CHECKOUT_BEHIND)"
grep -q "STALE BASE" "$ERRLOG" && fail "1 current: banner printed for an up-to-date checkout"
[ "$fail_count" -eq 0 ] && pass "1 an up-to-date checkout reports 0 behind and prints no banner"

# --- 2. behind checkout → N behind + loud banner (best-effort fetch detects) --
# The checkout has NOT pulled origin's new commits; the guard's own timeout-
# bounded fetch is what surfaces the staleness (the never-fetched-hand-checkout
# case that spawned #591).
co="$(make_repo behind)"
advance behind 2
run_guard "$co"
[ "$CHECKOUT_BEHIND" = 2 ] || fail "2 behind: expected behind=2 (got $CHECKOUT_BEHIND)"
[ "$CHECKOUT_BEHIND_REF" = "origin/main" ] || fail "2 behind: expected ref origin/main (got $CHECKOUT_BEHIND_REF)"
grep -q "STALE BASE" "$ERRLOG" || fail "2 behind: expected the STALE BASE banner on stderr"
grep -q "2 commit(s) behind origin/main" "$ERRLOG" || fail "2 behind: banner should name the behind count + ref"

# --- 3. QUALITY_GATES_SKIP_FRESHNESS=1 → guard disabled even when behind ------
co="$(make_repo skip)"
advance skip 1
QUALITY_GATES_SKIP_FRESHNESS=1 run_guard "$co"
[ "$CHECKOUT_BEHIND" = 0 ] || fail "3 skip: expected behind=0 when disabled (got $CHECKOUT_BEHIND)"
grep -q "STALE BASE" "$ERRLOG" && fail "3 skip: banner printed despite QUALITY_GATES_SKIP_FRESHNESS=1"

# --- 4. no upstream / no remote → quiet no-op, no crash ----------------------
noup="$WORK/noup"
GIT init -q -b main "$noup"; : >"$noup/f"; GIT -C "$noup" add -A; GIT -C "$noup" commit -qm c1
run_guard "$noup"
[ "$CHECKOUT_BEHIND" = 0 ] || fail "4 no-upstream: expected behind=0 (got $CHECKOUT_BEHIND)"
[ -z "$CHECKOUT_BEHIND_REF" ] || fail "4 no-upstream: expected empty ref (got $CHECKOUT_BEHIND_REF)"
grep -q "STALE BASE" "$ERRLOG" && fail "4 no-upstream: banner printed with no tracking ref"

# --- 5. a non-git path → quiet no-op -----------------------------------------
run_guard "$WORK/does-not-exist"
[ "$CHECKOUT_BEHIND" = 0 ] || fail "5 non-git: expected behind=0 (got $CHECKOUT_BEHIND)"

if [ "$fail_count" -gt 0 ]; then
  echo "FAILED $fail_count check(s)" >&2
  exit 1
fi
echo "OK — checkout-freshness guard: current=quiet, behind=loud+counted, skip-env honored, no-upstream/non-git degrade cleanly"
