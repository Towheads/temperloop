#!/usr/bin/env bash
#
# Concurrency + failure-atomicity tests for workflows/scripts/build/worktree.sh
# (temperloop#1171). The sibling test_worktree.sh exercises the SERIAL lifecycle;
# this file exercises the path /build and /sweep actually run — N creates racing
# on ONE repo — plus the ERROR path that race produced.
#
# The defect, observed live in a /sweep run at SWEEP_FANOUT_WIDTH=3:
#   Preparing worktree (new branch 'build/<slug>')
#   error: could not lock config file .git/config: File exists
#   error: unable to write upstream branch configuration
# `git worktree add` writes .git/config (the new branch's upstream) and git takes
# that lock without waiting or retrying, so a concurrent create just loses — and
# loses AFTER creating build/<slug>, leaving an orphan branch behind.
#
# Covers:
#   1. N concurrent creates on one repo ALL succeed (no config-lock loss)
#   2. creates and removes concurrently ALL succeed (the lock is two-sided)
#   3. the lock genuinely gates: a create waiting on a held lock reports a
#      structured ERROR rather than barging in
#   4. a real config-lock loss is ATOMIC: ERROR, no orphan branch, no worktree
#   5. a naive retry after that ERROR is a clean CREATED, not "already exists"
#   6. a failed create never strands the lock (EXIT-trap release)
#   7. a lock whose owner pid is DEAD is reclaimed immediately
#   8. a lock with NO pid, aged past WORKTREE_LOCK_STALE_SECS, is reclaimed
#      (7 and 8 are the two states that decide whether a crashed worker wedges
#      the repo forever. Leg 8 sets the lock dir's mtime explicitly, so it
#      exercises wt_lock_age and goes RED on a GNU-vs-BSD `stat` dialect break
#      instead of silently never stealing on Linux.)
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/worktree.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# `touch -t` stamp for <n> seconds ago. Feature-detected rather than chained,
# for the same reason the code under test feature-detects `stat`: BSD spells it
# `date -v`, GNU spells it `date -d`, and neither fails cleanly on the other's
# flag.
past_stamp() {
  if date -v-1S '+%Y' >/dev/null 2>&1; then
    date -v-"$1"S '+%Y%m%d%H%M.%S'          # BSD/macOS
  else
    date -d "-$1 seconds" '+%Y%m%d%H%M.%S'  # GNU coreutils
  fi
}

# A pid number that is guaranteed NOT to be a live process: spawn one, reap it,
# reuse the number.
dead_pid() {
  local p
  ( exit 0 ) &
  p=$!
  wait "$p" 2>/dev/null || true
  echo "$p"
}

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git init -q --initial-branch=main "$TMP/upstream"
git -C "$TMP/upstream" commit -q --allow-empty -m init
git clone -q "$TMP/upstream" "$TMP/repo"
REPO="$(cd "$TMP/repo" && pwd -P)"
LOCK="$REPO/.git/build-worktree.lock.d"

# --- 1. N concurrent creates on one repo all succeed -------------------------
# This is the shape that fired: one repo, several items of one level standing up
# their worktrees at the same moment. Every create must report CREATED, and no
# invocation may mention the config lock at all.
N=6
pids=()
for i in $(seq 1 "$N"); do
  ( set +e; bash "$SCRIPT" create "$REPO" "race-$i" >"$TMP/out.$i" 2>"$TMP/err.$i"; echo "$?" >"$TMP/rc.$i" ) &
  pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p" || true; done

for i in $(seq 1 "$N"); do
  rc="$(cat "$TMP/rc.$i")"
  out="$(cat "$TMP/out.$i")"
  [ "$rc" = "0" ] || fail "concurrent create race-$i exited $rc (out: $out / err: $(cat "$TMP/err.$i"))"
  [ "$(jq -r .outcome <<<"$out")" = "CREATED" ] || fail "concurrent create race-$i outcome (got: $out)"
  [ -f "$REPO.wt/race-$i/.build-guard" ] || fail "concurrent create race-$i dropped no marker"
  [ "$(git -C "$REPO.wt/race-$i" rev-parse --abbrev-ref HEAD)" = "build/race-$i" ] \
    || fail "concurrent create race-$i not on build/race-$i"
done
if grep -l 'could not lock config file' "$TMP"/err.* >/dev/null 2>&1; then
  fail "a concurrent create hit the .git/config lock race (#1171): $(cat "$TMP"/err.*)"
fi
echo "PASS: $N concurrent creates on one repo all return CREATED — no .git/config lock loss (#1171)"

# --- 2. creates racing removes also survive ----------------------------------
# `git branch -D` rewrites .git/config too, so a remove concurrent with a create
# is the same collision. A lock only one side takes is not a lock.
pids=()
for i in 1 2 3; do
  ( set +e; bash "$SCRIPT" remove "$REPO" "race-$i" >"$TMP/rmout.$i" 2>"$TMP/rmerr.$i"; echo "$?" >"$TMP/rmrc.$i" ) &
  pids+=("$!")
  ( set +e; bash "$SCRIPT" create "$REPO" "mixed-$i" >"$TMP/mkout.$i" 2>"$TMP/mkerr.$i"; echo "$?" >"$TMP/mkrc.$i" ) &
  pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p" || true; done
for i in 1 2 3; do
  [ "$(cat "$TMP/rmrc.$i")" = "0" ] || fail "concurrent remove race-$i exited non-zero ($(cat "$TMP/rmout.$i"))"
  [ "$(jq -r .outcome <"$TMP/rmout.$i")" = "REMOVED" ] || fail "concurrent remove race-$i (got: $(cat "$TMP/rmout.$i"))"
  [ "$(cat "$TMP/mkrc.$i")" = "0" ] || fail "concurrent create mixed-$i exited non-zero ($(cat "$TMP/mkout.$i"))"
  [ "$(jq -r .outcome <"$TMP/mkout.$i")" = "CREATED" ] || fail "concurrent create mixed-$i (got: $(cat "$TMP/mkout.$i"))"
done
if grep -l 'could not lock config file' "$TMP"/rmerr.* "$TMP"/mkerr.* >/dev/null 2>&1; then
  fail "a create/remove pair hit the .git/config lock race (#1171)"
fi
echo "PASS: concurrent create+remove on one repo all succeed — the lock covers both destroyers (#1171)"

# --- 3. the lock actually gates the mutating region --------------------------
# Hold the lock with a LIVE owner pid and give create a 0.3s budget: it must
# report a structured ERROR naming the lock, not proceed anyway. (Remove the
# lock acquisition from create and this leg goes red — it is the discriminator
# for "a lock exists at all", which a timing-dependent race test cannot be.)
mkdir -p "$LOCK"
echo "$$" > "$LOCK/pid"
set +e
out="$(WORKTREE_LOCK_WAIT_TICKS=3 bash "$SCRIPT" create "$REPO" gated 2>"$TMP/gated.err")"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "create ignored a held lock and exited 0 (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] || fail "held-lock create outcome (got: $out)"
case "$(jq -r .error <<<"$out")" in
  *"mutation lock"*) ;;
  *) fail "held-lock ERROR does not name the lock (got: $out)" ;;
esac
[ ! -e "$REPO.wt/gated" ] || fail "held-lock create left a worktree behind"
if git -C "$REPO" show-ref --verify --quiet refs/heads/build/gated; then
  fail "held-lock create left an orphan build/gated branch"
fi
rm -rf "$LOCK"
out="$(bash "$SCRIPT" create "$REPO" gated)"
[ "$(jq -r .outcome <<<"$out")" = "CREATED" ] || fail "create after lock release (got: $out)"
echo "PASS: a create blocked by a held lock reports ERROR and leaves nothing behind; it succeeds once released (#1171)"

# --- 4/5/6. a real config-lock loss is atomic and retryable ------------------
# Reproduce the LIVE failure exactly rather than simulating it: git's own config
# lock is a plain O_EXCL file, so holding .git/config.lock makes `git worktree
# add` fail with the reported error deterministically — and (pre-fix) leave
# build/<slug> behind.
touch "$REPO/.git/config.lock"
set +e
out="$(WORKTREE_ADD_ATTEMPTS=1 bash "$SCRIPT" create "$REPO" atomic 2>"$TMP/atomic.err")"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "create over a held config lock exited 0 (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] || fail "config-lock create outcome (got: $out)"
case "$(jq -r .error <<<"$out")" in
  *"could not lock config file"*) ;;
  *) fail "config-lock ERROR does not carry git's own message (got: $out)" ;;
esac
# The atomicity claim: the ERROR outcome left NO durable state.
# Assertions are written as `if <cmd>; then fail; fi`, never `<cmd> && fail`
# over a PIPELINE: this file runs `set -euo pipefail`, and `git … | grep -q X`
# exits grep on the first match, which can SIGPIPE git and make the pipeline
# non-zero even though grep MATCHED — so the `&& fail` would never fire and the
# assertion would pass vacuously. Feed the text in with a here-string instead:
# no pipeline, no SIGPIPE, no silent disarm.
if git -C "$REPO" show-ref --verify --quiet refs/heads/build/atomic; then
  fail "#1171: failed create left an orphan build/atomic branch (needs a manual git branch -D)"
fi
[ ! -e "$REPO.wt/atomic" ] || fail "failed create left a worktree directory behind"
wt_list="$(git -C "$REPO" worktree list --porcelain)"
if grep -q "$REPO.wt/atomic" <<<"$wt_list"; then
  fail "failed create left a worktree registration behind"
fi
[ ! -e "$LOCK" ] || fail "failed create stranded the mutation lock"
echo "PASS: a config-lock create failure is ERROR + full rollback — no orphan branch, no stranded lock (#1171)"

rm -f "$REPO/.git/config.lock"
out="$(bash "$SCRIPT" create "$REPO" atomic)"
[ "$(jq -r .outcome <<<"$out")" = "CREATED" ] || fail "naive retry after ERROR (got: $out)"
[ "$(git -C "$REPO.wt/atomic" rev-parse --abbrev-ref HEAD)" = "build/atomic" ] \
  || fail "retried worktree not on build/atomic"
echo "PASS: a naive retry after the ERROR is a clean CREATED, not 'branch already exists' (#1171)"

# --- 7. a lock whose owner pid is DEAD is reclaimed immediately --------------
# The crashed-worker state. Without the reclaim, a killed `worktree.sh` wedges
# EVERY later create/remove/prune on the repo until a human `rm -rf`s the dir.
# The 0.3s budget is the discriminator: a create that merely waits it out
# reports ERROR, so only an actual steal can turn this green.
mkdir -p "$LOCK"
dead_pid > "$LOCK/pid"
# rc is captured explicitly rather than left to `set -e`: an aborting create
# would otherwise kill this file with NO diagnostic, which is the same
# "swallowed test error" shape that hid the dialect break in the first place.
set +e
out="$(WORKTREE_LOCK_WAIT_TICKS=3 bash "$SCRIPT" create "$REPO" reclaim-dead 2>"$TMP/dead.err")"
rc=$?
set -e
[ "$rc" -eq 0 ] && [ "$(jq -r .outcome <<<"$out")" = "CREATED" ] \
  || fail "a lock held by a DEAD pid was not reclaimed (rc=$rc out: $out / err: $(cat "$TMP/dead.err"))"
[ ! -e "$LOCK" ] || fail "reclaim-dead create did not release the lock it stole"
if compgen -G "$LOCK.dead.*" >/dev/null; then
  fail "the rename-claim left .dead.* debris behind: $(echo "$LOCK".dead.*)"
fi
echo "PASS: a lock whose owner pid is dead is reclaimed by rename, not waited out (#1171)"

# --- 8. a lock with NO pid, aged past the stale window, is reclaimed ---------
# The other reclaim state: a process killed inside the mkdir/pid-write window
# leaves an OWNERLESS lock dir, which nothing can attribute and nothing will
# ever release. It is stealable on age alone.
#
# The mtime is set EXPLICITLY with `touch -t` so this leg exercises wt_lock_age
# for real. That is the point of the leg: with the old
# `stat -f %m || stat -c %Y` fallback chain, wt_lock_age emits garbage on GNU
# coreutils, `[ "$(wt_lock_age)" -ge … ]` errors "integer expected" and
# evaluates FALSE, and this steal silently never fires on Linux while staying
# green on macOS. Here that break costs the whole budget and lands as ERROR.
mkdir -p "$LOCK"
if [ -e "$LOCK/pid" ]; then fail "leg 8 setup is wrong — the lock must have NO pid file"; fi
touch -t "$(past_stamp 1200)" "$LOCK"
set +e
out="$(WORKTREE_LOCK_WAIT_TICKS=3 WORKTREE_LOCK_STALE_SECS=900 \
       bash "$SCRIPT" create "$REPO" reclaim-stale 2>"$TMP/stale.err")"
rc=$?
set -e
[ "$rc" -eq 0 ] && [ "$(jq -r .outcome <<<"$out")" = "CREATED" ] \
  || fail "an OWNERLESS lock aged past WORKTREE_LOCK_STALE_SECS was not reclaimed — check wt_lock_age's stat dialect (rc=$rc out: $out / err: $(cat "$TMP/stale.err"))"
[ ! -e "$LOCK" ] || fail "reclaim-stale create did not release the lock it stole"

# The converse, so leg 8 proves the AGE gate and not just "ownerless => steal":
# the same ownerless lock, still INSIDE the stale window, is respected.
mkdir -p "$LOCK"
touch -t "$(past_stamp 60)" "$LOCK"
set +e
out="$(WORKTREE_LOCK_WAIT_TICKS=3 WORKTREE_LOCK_STALE_SECS=900 \
       bash "$SCRIPT" create "$REPO" reclaim-young 2>"$TMP/young.err")"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a FRESH ownerless lock was stolen anyway (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] || fail "fresh-ownerless-lock outcome (got: $out)"
rm -rf "$LOCK"
echo "PASS: an ownerless lock is stolen once aged out and respected before that — wt_lock_age is live (#1171)"

# --- 9. the network work happens OUTSIDE the lock ---------------------------
# § Repo-wide mutation lock § SCOPE says the lock is never held across a network
# round-trip, because the wait budget is shared: one hanging `gh`/`fetch` under
# it times the REST of a /build level out into ERRORs. `create_core` keeps that
# true by acquiring BELOW clear_path_probe (gh-backed) and BELOW `git fetch`.
#
# Made mechanical rather than left to prose: hold the lock with a live owner and
# give create a 0.3s budget. It must still have FETCHED — origin/main must have
# advanced to the upstream's new tip — before reporting the lock timeout. Move
# the acquire back above the fetch and this leg goes red.
git -C "$TMP/upstream" commit -q --allow-empty -m "advance-the-base"
UPSTREAM_TIP="$(git -C "$TMP/upstream" rev-parse HEAD)"
[ "$(git -C "$REPO" rev-parse origin/main)" != "$UPSTREAM_TIP" ] \
  || fail "leg 9 setup is wrong — origin/main already carries the new tip"
mkdir -p "$LOCK"
echo "$$" > "$LOCK/pid"
set +e
out="$(WORKTREE_LOCK_WAIT_TICKS=3 bash "$SCRIPT" create "$REPO" outside-lock 2>"$TMP/outside.err")"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "leg 9 setup is wrong — create should have timed out on the held lock (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] || fail "leg 9 outcome (got: $out)"
[ "$(git -C "$REPO" rev-parse origin/main)" = "$UPSTREAM_TIP" ] \
  || fail "create did NOT fetch before taking the lock — the network call is back inside the locked region (#1171)"
rm -rf "$LOCK"
echo "PASS: create's fetch (and its gh-backed occupant probe) run OUTSIDE the mutation lock (#1171)"
