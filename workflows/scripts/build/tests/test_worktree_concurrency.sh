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
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/worktree.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

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
git -C "$REPO" show-ref --verify --quiet refs/heads/build/gated \
  && fail "held-lock create left an orphan build/gated branch"
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
git -C "$REPO" show-ref --verify --quiet refs/heads/build/atomic \
  && fail "#1171: failed create left an orphan build/atomic branch (needs a manual git branch -D)"
[ ! -e "$REPO.wt/atomic" ] || fail "failed create left a worktree directory behind"
git -C "$REPO" worktree list --porcelain | grep -q "$REPO.wt/atomic" \
  && fail "failed create left a worktree registration behind"
[ ! -e "$LOCK" ] || fail "failed create stranded the mutation lock"
echo "PASS: a config-lock create failure is ERROR + full rollback — no orphan branch, no stranded lock (#1171)"

rm -f "$REPO/.git/config.lock"
out="$(bash "$SCRIPT" create "$REPO" atomic)"
[ "$(jq -r .outcome <<<"$out")" = "CREATED" ] || fail "naive retry after ERROR (got: $out)"
[ "$(git -C "$REPO.wt/atomic" rev-parse --abbrev-ref HEAD)" = "build/atomic" ] \
  || fail "retried worktree not on build/atomic"
echo "PASS: a naive retry after the ERROR is a clean CREATED, not 'branch already exists' (#1171)"
