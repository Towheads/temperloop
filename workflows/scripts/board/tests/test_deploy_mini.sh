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

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf — a consumer's committed
# cutover flip (e.g. stageFind's board.3.backend=issues) or a driver host's
# machine-level conf would silently change canned-fixture resolution.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null


HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$HERE/../deploy-mini.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy-mini-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
GIT() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# setup_repo <name> <guard:yes|no> — bare origin + a checkout clone (on main, at c1).
setup_repo() {
  local guard="$2" org="$WORK/$1.git" seed="$WORK/$1.seed" co="$WORK/$1"
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
behind() { git -C "$1" rev-list --count "HEAD..@{u}" 2>/dev/null || echo "?"; }

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

# --- 3. UNMERGED feature branch (real in-flight work) → SKIP, untouched ------
# F#1098: the recovery below auto-resets ONLY a merged/contained branch. A branch
# carrying a local commit NOT in origin/main is genuine work — it must stay put.
setup_repo featskip yes; advance featskip
GIT -C "$WORK/featskip" checkout -q -b feature/x
echo "# local unmerged work" >>"$WORK/featskip/scripts/lib/board.sh"
GIT -C "$WORK/featskip" add -A; GIT -C "$WORK/featskip" commit -qm "unmerged local"
before="$(GIT -C "$WORK/featskip" rev-parse HEAD)"
out="$(run "$WORK/featskip")" || true
[ "$(GIT -C "$WORK/featskip" rev-parse HEAD)" = "$before" ] || fail "unmerged feature-branch checkout must NOT be touched"
[ "$(GIT -C "$WORK/featskip" branch --show-current)" = "feature/x" ] || fail "unmerged feature branch must stay checked out (not reset to main)"
echo "$out" | grep -q "not main" || fail "unmerged feature branch should report SKIP (not main)"

# --- 3b. MERGED/contained feature branch → RECOVERED to main + ff (F#1098) ----
# The failure this fixes: a checkout stranded on an already-merged branch (its tip
# fully contained in origin/main) used to be skipped forever, silently blocking the
# funnel's clean-on-main merge tier. It must now be switched back to main and pulled.
setup_repo featrecover yes; advance featrecover
GIT -C "$WORK/featrecover" checkout -q -b feature/merged   # at c1, an ancestor of origin/main (c2)
out="$(run "$WORK/featrecover")" || fail "merged-branch recovery run should exit 0"
[ "$(GIT -C "$WORK/featrecover" branch --show-current)" = "main" ] || fail "merged feature branch must be recovered to main"
[ "$(behind "$WORK/featrecover")" -eq 0 ] || fail "recovered checkout must be ff-pulled to current"
echo "$out" | grep -q "RECOVERED" || fail "merged feature branch should report RECOVERED (got: $out)"

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

# --- 14. #168: a merged/orphaned <checkout>.wt/* worktree is swept -----------
# per clean-on-main checkout, deploy-mini also runs worktree.sh prune. A
# worktree whose branch is a plain ancestor of origin/main (trivially "merged" —
# zero commits ahead) and clean must be removed; the dir + branch both go away
# and deploy-mini reports it.
WTSH="$HERE/../../build/worktree.sh"
setup_repo wtsweep yes
bash "$WTSH" create "$WORK/wtsweep" mergedwt >/dev/null \
  || fail "test setup: worktree.sh create failed"
[ -d "$WORK/wtsweep.wt/mergedwt" ] || fail "test setup: worktree not created"
out="$(run "$WORK/wtsweep")" || fail "wtsweep run should exit 0"
[ ! -e "$WORK/wtsweep.wt/mergedwt" ] || fail "merged worktree must be pruned by deploy-mini"
GIT -C "$WORK/wtsweep" show-ref --verify --quiet refs/heads/build/mergedwt \
  && fail "branch build/mergedwt must be removed with the pruned worktree"
echo "$out" | grep -q "worktree prune: 1 pruned" || fail "should report 'worktree prune: 1 pruned' (got: $out)"
echo "PASS: #168 a merged/orphaned <checkout>.wt/* worktree is swept by deploy-mini's per-checkout worktree.sh prune"

# --- 15. #168: a dirty or genuinely-unmerged worktree is left intact ---------
setup_repo wtkeep yes
bash "$WTSH" create "$WORK/wtkeep" unmergedwt >/dev/null \
  || fail "test setup: worktree.sh create (unmerged) failed"
GIT -C "$WORK/wtkeep.wt/unmergedwt" commit -q --allow-empty -m "unlanded work"
bash "$WTSH" create "$WORK/wtkeep" dirtywt >/dev/null \
  || fail "test setup: worktree.sh create (dirty) failed"
echo scratch >"$WORK/wtkeep.wt/dirtywt/junk.txt"
out="$(run "$WORK/wtkeep")" || fail "wtkeep run should exit 0"
[ -e "$WORK/wtkeep.wt/unmergedwt" ] || fail "genuinely-unmerged worktree must NOT be pruned"
[ -e "$WORK/wtkeep.wt/dirtywt" ] || fail "dirty worktree must NOT be pruned (no --force)"
echo "$out" | grep -q "worktree prune: 1 pruned" && fail "no worktree here should have been pruned (got: $out)"
echo "PASS: #168 a dirty or genuinely-unmerged worktree is left intact by deploy-mini's worktree sweep"

# --- 16. #168: fail-open — a worktree.sh prune failure never aborts deploy-mini
# Point $FOUNDATION's worktree.sh lookup at a stub that always fails; deploy-mini
# must still exit 0 (via the guard-verify step's own outcome) and log the
# failure rather than abort. Simulated by temporarily shadowing jq (worktree.sh's
# own hard dependency) off PATH for the run — worktree.sh then emits its ERROR
# outcome and exits non-zero, which deploy-mini must swallow.
setup_repo wtfail yes
bash "$WTSH" create "$WORK/wtfail" somewt >/dev/null \
  || fail "test setup: worktree.sh create (wtfail) failed"
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
for tool in git grep sed cat printf mktemp basename dirname cut sort uniq tr rm mkdir; do
  real="$(command -v "$tool" 2>/dev/null)" && ln -sf "$real" "$FAKEBIN/$tool"
done
cat >"$FAKEBIN/jq" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
chmod +x "$FAKEBIN/jq"
out="$(PATH="$FAKEBIN:$PATH" run "$WORK/wtfail")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "a worktree-prune failure must not abort deploy-mini (rc=$rc, got: $out)"
echo "$out" | grep -q "worktree prune: FAILED (non-fatal)" || fail "should report the swallowed failure (got: $out)"
echo "PASS: #168 a worktree.sh prune failure is fail-open — logged, deploy-mini still exits 0"

echo "PASS: deploy-mini ff-pulls clean-on-main checkouts, recovers a checkout stranded on a merged/contained branch back to main (F#1098), skips dirty/UNMERGED-feature/absent/diverged, prunes merged local branches (F#653, keeps unmerged), sweeps merged/orphaned <checkout>.wt/* worktrees fail-open while leaving dirty/unmerged ones intact (#168), verifies the guard (exit non-zero on miss), is idempotent, busts the structure cache only on an adapter-changed pull (#341), single-instances via a PID-owned lock (live held, dead stolen), and reports cache-enabled boards + store presence (F#988/#1026)"
