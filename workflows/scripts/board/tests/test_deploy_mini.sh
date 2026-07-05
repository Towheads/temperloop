#!/usr/bin/env bash
#
# Tests for deploy-mini.sh (foundation #149) — the board-toolkit auto-deploy engine.
# It must keep consumers current SAFELY: only fast-forward clean-on-main checkouts,
# never touch a dirty or feature-branch checkout (an active session's work), refresh
# nothing it shouldn't, and verify the #128 guard is present in every board.sh.
#
# Uses throwaway local git repos (a bare "origin" + a clone per checkout) — CI-safe,
# no network. DEPLOY_MINI_SKIP_INSTALL=1 keeps it off the real ~/.local/bin symlinks;
# DEPLOY_MINI_CHECKOUTS / DEPLOY_MINI_LOCK isolate it from the real machine.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$HERE/../deploy-mini.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy-mini-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
GIT() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# setup_repo <name> <guard:yes|no> — bare origin + a checkout clone (on main, at c1).
setup_repo() {
  local name="$1" guard="$2" org="$WORK/$1.git" seed="$WORK/$1.seed" co="$WORK/$1"
  GIT init -q --bare -b main "$org"
  GIT clone -q "$org" "$seed" 2>/dev/null
  mkdir -p "$seed/scripts/lib"
  if [ "$guard" = yes ]; then echo '_board_assert_item_id() { :; }' >"$seed/scripts/lib/board.sh"
  else                        echo '# no guard here'              >"$seed/scripts/lib/board.sh"; fi
  GIT -C "$seed" add -A; GIT -C "$seed" commit -qm c1; GIT -C "$seed" push -q origin main
  GIT clone -q "$org" "$co" 2>/dev/null
}
# advance <name> — push a new commit to origin so the checkout falls behind.
advance() {
  local seed="$WORK/$1.seed"
  echo "# c2" >>"$seed/scripts/lib/board.sh"
  GIT -C "$seed" add -A; GIT -C "$seed" commit -qm c2; GIT -C "$seed" push -q origin main
}
# run <checkout-paths...> — invoke deploy-mini isolated; prints output, returns its rc.
# BOARD_CACHE_DIR is pinned into $WORK so the #341 structure-cache bust never touches
# the real machine's cache (and test 10 can assert against it).
run() {
  DEPLOY_MINI_CHECKOUTS="$*" DEPLOY_MINI_SKIP_INSTALL=1 DEPLOY_MINI_LOCK="$WORK/run.lock.d" \
    BOARD_CACHE_DIR="$WORK/cache" bash "$DEPLOY"
}
behind() { git -C "$1" rev-list --count HEAD..@{u} 2>/dev/null || echo "?"; }

# --- 1. clean-on-main, behind → fast-forwarded to current --------------------
setup_repo cleanpull yes; advance cleanpull
[ "$(behind "$WORK/cleanpull")" != 0 ] || { GIT -C "$WORK/cleanpull" fetch -q; [ "$(behind "$WORK/cleanpull")" = 1 ] || fail "setup: cleanpull should be behind"; }
before="$(GIT -C "$WORK/cleanpull" rev-parse HEAD)"
out="$(run "$WORK/cleanpull")" || fail "clean-main run should exit 0"
[ "$(GIT -C "$WORK/cleanpull" rev-parse HEAD)" != "$before" ] || fail "clean-main behind must be ff-pulled"
[ "$(behind "$WORK/cleanpull")" -eq 0 ] || fail "checkout must be current after pull"
echo "$out" | grep -q "pulled →" || fail "should report 'pulled →' (got: $out)"

# --- 2. dirty checkout → SKIP, working tree untouched ------------------------
setup_repo dirtyskip yes; advance dirtyskip
echo "UNCOMMITTED" >>"$WORK/dirtyskip/scripts/lib/board.sh"
before="$(GIT -C "$WORK/dirtyskip" rev-parse HEAD)"
out="$(run "$WORK/dirtyskip")" || true
[ "$(GIT -C "$WORK/dirtyskip" rev-parse HEAD)" = "$before" ] || fail "dirty checkout must NOT be pulled"
grep -q UNCOMMITTED "$WORK/dirtyskip/scripts/lib/board.sh" || fail "dirty working tree was clobbered"
echo "$out" | grep -q "SKIP (dirty" || fail "dirty should report SKIP (dirty)"

# --- 3. feature branch → SKIP ------------------------------------------------
setup_repo featskip yes; advance featskip
GIT -C "$WORK/featskip" checkout -q -b feature/x
before="$(GIT -C "$WORK/featskip" rev-parse HEAD)"
out="$(run "$WORK/featskip")" || true
[ "$(GIT -C "$WORK/featskip" rev-parse HEAD)" = "$before" ] || fail "feature-branch checkout must NOT be pulled"
echo "$out" | grep -q "not main" || fail "feature branch should report SKIP (not main)"

# --- 4. absent path → SKIP, no error ----------------------------------------
out="$(run "$WORK/does-not-exist")" || true
echo "$out" | grep -q "SKIP (absent" || fail "absent path should report SKIP (absent)"

# --- 5. verify gate: guard present → exit 0; missing → exit non-zero ---------
setup_repo guarded yes
run "$WORK/guarded" >/dev/null || fail "guard present must exit 0"
setup_repo noguard no
out="$(run "$WORK/noguard")" && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a board.sh missing the guard must exit non-zero"
echo "$out" | grep -q "guard MISSING" || fail "should report guard MISSING (got: $out)"

# --- 6. idempotent: a current checkout re-runs as 'already current' ----------
setup_repo idem yes
run "$WORK/idem" >/dev/null || fail "idem first run should exit 0"
out="$(run "$WORK/idem")" || fail "idem second run should exit 0"
echo "$out" | grep -q "already current" || fail "idempotent re-run should be 'already current' (got: $out)"

# --- 7. lock: a lock held by a LIVE owner makes a concurrent invocation no-op -
mkdir "$WORK/held.lock.d"; echo "$$" >"$WORK/held.lock.d/pid"   # $$ = this test, alive
out="$(DEPLOY_MINI_CHECKOUTS="$WORK/idem" DEPLOY_MINI_SKIP_INSTALL=1 DEPLOY_MINI_LOCK="$WORK/held.lock.d" bash "$DEPLOY")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "a live-held lock must exit 0 (skip)"
echo "$out" | grep -q "holds the lock" || fail "a live-held lock should report skipping (got: $out)"

# --- 8. lock: a lock owned by a DEAD PID is stolen and the deploy runs -------
mkdir "$WORK/dead.lock.d"; echo 999999 >"$WORK/dead.lock.d/pid"   # 999999 > PID_MAX → never alive
out="$(DEPLOY_MINI_CHECKOUTS="$WORK/idem" DEPLOY_MINI_SKIP_INSTALL=1 DEPLOY_MINI_LOCK="$WORK/dead.lock.d" bash "$DEPLOY")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "a dead-owner lock should be stolen and run (exit 0)"
echo "$out" | grep -q "holds the lock" && fail "a dead-owner lock must NOT be treated as held"
echo "$out" | grep -q "already current" || fail "after stealing a dead lock, deploy should run (got: $out)"

# --- 9. diverged: a checkout with a local commit can't ff-merge → SKIP, no clobber -
setup_repo diverge yes
echo "# local-only commit" >>"$WORK/diverge/scripts/lib/board.sh"
GIT -C "$WORK/diverge" add -A; GIT -C "$WORK/diverge" commit -qm local
advance diverge                                    # origin advances on a different line
before="$(GIT -C "$WORK/diverge" rev-parse HEAD)"
out="$(run "$WORK/diverge")" || true
[ "$(GIT -C "$WORK/diverge" rev-parse HEAD)" = "$before" ] || fail "diverged checkout HEAD must NOT move (no clobber)"
echo "$out" | grep -q "cannot ff-merge" || fail "diverged should report SKIP (cannot ff-merge) (got: $out)"

# --- 10. #341: an adapter-changed pull busts the structure cache ------------
# A pull whose diff touches a board.sh must flush the structure cache (stale
# project/field ids after a renumber break WRITES). The structure cache file is
# keyed on the RESOLVED owner+project# (#341 option b), so derive the real paths
# from the same board.sh the bust subshell sources — don't hardcode the migrated
# number. Pre-seed a stale board-4 structure entry; after a pull that changed
# board.sh it must be gone + announced.
mkdir -p "$WORK/cache"
PROJ_CACHE="$(BOARD_CACHE_DIR="$WORK/cache" bash -c '. "'"$HERE"'/../lib/board.sh"; _board_cache_file 4 project')"
FIELDS_CACHE="$(BOARD_CACHE_DIR="$WORK/cache" bash -c '. "'"$HERE"'/../lib/board.sh"; _board_cache_file 4 fields')"
: >"$PROJ_CACHE"
: >"$FIELDS_CACHE"
setup_repo bustpull yes; advance bustpull            # advance() appends to scripts/lib/board.sh
out="$(run "$WORK/bustpull")" || fail "bust run should exit 0"
echo "$out" | grep -q "structure cache busted" || fail "an adapter-changed pull should bust the structure cache (got: $out)"
[ ! -f "$PROJ_CACHE" ] || fail "#341: stale board-4 structure cache must be removed"
[ ! -f "$FIELDS_CACHE" ]  || fail "#341: stale board-4 fields cache must be removed"

# --- 11. #341: a no-op deploy (nothing pulled) does NOT bust the cache -------
# Busting every run would defeat the 24h structure TTL — only an adapter change does.
: >"$PROJ_CACHE"                                       # re-seed; an already-current run must leave it
out="$(run "$WORK/bustpull")" || fail "no-op bust run should exit 0"
echo "$out" | grep -q "structure cache busted" && fail "#341: an already-current (no-pull) deploy must NOT bust the cache"
[ -f "$PROJ_CACHE" ] || fail "#341: a no-op deploy must leave the structure cache intact"

# --- 12. F#653: a clean-on-main checkout has its merged LOCAL branches pruned ---
# mergedlocal points at origin/main (the post-merge/ff shape — its work is fully in
# origin/main) → deletable; unmergedlocal carries a commit not in origin/main → kept
# (git branch -d refuses it). The checkout stays on main + clean so deploy processes it.
setup_repo prunelocal yes
GIT -C "$WORK/prunelocal" branch mergedlocal                      # tip == origin/main → merged
GIT -C "$WORK/prunelocal" checkout -q -b unmergedlocal
GIT -C "$WORK/prunelocal" commit -q --allow-empty -m unmerged
GIT -C "$WORK/prunelocal" checkout -q main                        # back on main, clean
out="$(run "$WORK/prunelocal")" || fail "prunelocal run should exit 0"
GIT -C "$WORK/prunelocal" rev-parse --verify -q mergedlocal >/dev/null \
  && fail "merged local branch must be pruned"
GIT -C "$WORK/prunelocal" rev-parse --verify -q unmergedlocal >/dev/null \
  || fail "unmerged local branch must be kept"
echo "$out" | grep -q "prune: deleted 1 local" || fail "should report 'prune: deleted 1 local' (got: $out)"

# --- 13. F#988/#1026: cache-enabled boards are reported (store present vs absent) ---
# A dedicated minimal board.sh (guard string + a board_repo() stub) rather than the
# real one — this test targets deploy-mini's OWN reporting logic, not board.sh's conf
# discovery (that's covered by test_boards_conf.sh / test_cache_store.sh).
setup_repo cacherep yes
cat >"$WORK/cacherep/scripts/lib/board.sh" <<'BOARDEOF'
_board_assert_item_id() { :; }
board_repo() {
  case "$1" in
    9) echo "acme/cached-thing" ;;
    10) echo "acme/uncached-thing" ;;
  esac
}
BOARDEOF
cp "$HERE/../lib/cache.sh" "$WORK/cacherep/scripts/lib/cache.sh"
cat >"$WORK/cacherep/scripts/boards.conf" <<'EOF'
board.9.repo=acme/cached-thing
board.9.cache=on
board.10.repo=acme/uncached-thing
EOF
CACHE_ROOT="$WORK/cache-store-root"
mkdir -p "$CACHE_ROOT/issues/acme-cached-thing"
echo '{"schema_version":1,"repo":"acme/cached-thing","last_refresh":1}' \
  >"$CACHE_ROOT/issues/acme-cached-thing/meta.json"
out="$(CACHE_STORE_ROOT="$CACHE_ROOT" run "$WORK/cacherep")" || fail "cache-report run should exit 0"
echo "$out" | grep -q "board 9 (store present)" || \
  fail "board 9 (cache=on, store on disk) should report store present (got: $out)"
echo "$out" | grep -q "board 10" && \
  fail "board 10 (no cache=on line) must not be reported (got: $out)"

# Same checkout, no store on disk yet for board 9 → reports "store absent".
rm -rf "$CACHE_ROOT"
out="$(CACHE_STORE_ROOT="$CACHE_ROOT" run "$WORK/cacherep")" || fail "cache-report (absent) run should exit 0"
echo "$out" | grep -q "board 9 (store absent)" || \
  fail "board 9 with no store on disk should report store absent (got: $out)"

echo "PASS: deploy-mini ff-pulls clean-on-main checkouts, skips dirty/feature/absent/diverged, prunes merged local branches (F#653, keeps unmerged), verifies the guard (exit non-zero on miss), is idempotent, busts the structure cache only on an adapter-changed pull (#341), single-instances via a PID-owned lock (live held, dead stolen), and reports cache-enabled boards + store presence (F#988/#1026)"
