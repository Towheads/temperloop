#!/usr/bin/env bash
#
# Tests for the knowledge store's OPTIONAL sync capability (temperloop#430,
# ADR 0003): ks_sync / ks_sync_available on the plain-files backend
# (git-backed, manual-only), plus the exit-3 legible degradation on a
# backend that does not implement sync (obsidian). Zero network — the
# "remote" is a local bare git repo under a throwaway tmpdir; the
# two-environment story runs against two sandbox HOMEs with two independent
# store roots sharing that one bare remote. Never touches the machine's
# real HOME, XDG dirs, or git config (HOME is overridden per environment
# and GIT_CONFIG_NOSYSTEM is set, so the operator-identity FALLBACK path is
# what's exercised deterministically on every host, dev or CI).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"
LIB="$LIB_DIR/knowledge_store.sh"
OBSIDIAN_LIB="$LIB_DIR/knowledge_store_obsidian.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ks-sync-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Deterministic git environment: no real per-user/system config is ever
# read (so the identity-fallback path is the one exercised everywhere),
# and no env identity is inherited from the invoking shell.
export GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL 2>/dev/null || true
export HOME="$TMP/home-neutral"
mkdir -p "$HOME"

# Isolate the read-log (temperloop#229) — ks_sync dispatches through
# ks__dispatch, which emits a read-log line per call.
export KNOWLEDGE_READ_LOG="$TMP/knowledge-reads.log"

# --- 1. availability probe: plain-files implements sync -> exit 0, silent ---
(
  export KNOWLEDGE_STORE_ROOT="$TMP/probe-store"
  # shellcheck source=/dev/null
  source "$LIB"
  out="$(ks_sync_available 2>&1)" || fail "1: ks_sync_available should exit 0 on plain-files (got $?, output: $out)"
  [ -z "$out" ] || fail "1: ks_sync_available should print nothing when available (got: $out)"
  echo "PASS: 1 ks_sync_available exits 0 (silent) on the plain-files backend"
)

# --- 2. obsidian backend -> exit 3 + the exact skip line, nothing on stdout --
(
  export KNOWLEDGE_STORE_ROOT="$TMP/probe-store"
  # shellcheck source=/dev/null
  source "$LIB"
  # Genuinely register the backend (its four universal ops), then select it —
  # sync stays unimplemented there by design (it never consults ks_root).
  # shellcheck source=/dev/null
  source "$OBSIDIAN_LIB"
  export KNOWLEDGE_STORE_BACKEND=obsidian

  set +e
  probe_out="$(ks_sync_available 2>/dev/null)"
  probe_rc=$?
  probe_err="$(ks_sync_available 2>&1 >/dev/null)"
  set -e
  [ "$probe_rc" -eq 3 ] || fail "2: ks_sync_available under obsidian should exit 3 (got $probe_rc)"
  [ -z "$probe_out" ] || fail "2: probe must print nothing to stdout (got: $probe_out)"
  [ "$probe_err" = "skipped — sync unavailable for backend obsidian" ] \
    || fail "2: probe stderr must be the exact skip line (got: $probe_err)"

  # The full op degrades identically — and never reaches git/ks_root.
  set +e
  op_out="$(ks_sync push 2>/dev/null)"
  op_rc=$?
  op_err="$(ks_sync push 2>&1 >/dev/null)"
  set -e
  [ "$op_rc" -eq 3 ] || fail "2b: ks_sync push under obsidian should exit 3 (got $op_rc)"
  [ -z "$op_out" ] || fail "2b: skipped ks_sync must print nothing to stdout (got: $op_out)"
  [ "$op_err" = "skipped — sync unavailable for backend obsidian" ] \
    || fail "2b: ks_sync stderr must be the exact skip line (got: $op_err)"
  [ ! -d "$KNOWLEDGE_STORE_ROOT/.git" ] \
    || fail "2c: a skipped sync must never have touched KNOWLEDGE_STORE_ROOT"
  echo "PASS: 2 obsidian backend degrades to exit 3 with the exact 'skipped — sync unavailable for backend obsidian' notice"
)

# From here on: plain-files, one shared fixture remote.
REMOTE="$TMP/remote.git"
git init --bare -q "$REMOTE"

# --- 3. usage errors: missing/unknown sub-op, init without a URL -> exit 2 ---
(
  export KNOWLEDGE_STORE_ROOT="$TMP/usage-store"
  # shellcheck source=/dev/null
  source "$LIB"
  set +e
  ks_sync 2>/dev/null;            rc_none=$?
  ks_sync bogus 2>/dev/null;      rc_bogus=$?
  ks_sync init 2>/dev/null;       rc_init=$?
  ks_sync push --frob 2>/dev/null; rc_arg=$?
  set -e
  [ "$rc_none"  -eq 2 ] || fail "3: bare ks_sync should exit 2 (got $rc_none)"
  [ "$rc_bogus" -eq 2 ] || fail "3: unknown sub-op should exit 2 (got $rc_bogus)"
  [ "$rc_init"  -eq 2 ] || fail "3: init without <remote-url> should exit 2 (got $rc_init)"
  [ "$rc_arg"   -eq 2 ] || fail "3: unknown push argument should exit 2 (got $rc_arg)"
  echo "PASS: 3 usage errors exit 2 (bare call, unknown sub-op, init sans URL, unknown push arg)"
)

# --- 4. push/pull before init -> exit 4, message names init; status legible --
(
  export KNOWLEDGE_STORE_ROOT="$TMP/uninit-store"
  # shellcheck source=/dev/null
  source "$LIB"
  mkdir -p "$KNOWLEDGE_STORE_ROOT"
  set +e
  push_err="$(ks_sync push 2>&1 >/dev/null)"; rc_push=$?
  pull_err="$(ks_sync pull 2>&1 >/dev/null)"; rc_pull=$?
  status_out="$(ks_sync status)";             rc_status=$?
  set -e
  [ "$rc_push" -eq 4 ] || fail "4: push before init should exit 4 (got $rc_push)"
  [ "$rc_pull" -eq 4 ] || fail "4: pull before init should exit 4 (got $rc_pull)"
  case "$push_err" in
    *"ks_sync init"*) : ;;
    *) fail "4: push-before-init error should name 'ks_sync init' (got: $push_err)" ;;
  esac
  case "$pull_err" in
    *"ks_sync init"*) : ;;
    *) fail "4: pull-before-init error should name 'ks_sync init' (got: $pull_err)" ;;
  esac
  [ "$rc_status" -eq 0 ] || fail "4: status is a probe — exit 0 even uninitialized (got $rc_status)"
  case "$status_out" in
    *"not initialized"*) : ;;
    *) fail "4: uninitialized status should say so legibly (got: $status_out)" ;;
  esac
  echo "PASS: 4 push/pull before init fail loud (exit 4, pointing at init); status stays a legible exit-0 probe"
)

# --- 5. nested-repo guard: a store dir inside an OUTER repo, no own .git ----
(
  OUTER="$TMP/outer-repo"
  git init -q "$OUTER"
  export KNOWLEDGE_STORE_ROOT="$OUTER/notes"
  mkdir -p "$KNOWLEDGE_STORE_ROOT"
  # shellcheck source=/dev/null
  source "$LIB"
  set +e
  ks_sync push 2>/dev/null
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || fail "5: push in a not-own-repo store should exit 4 (got $rc)"
  # The outer repo must be untouched — nothing staged into it.
  staged="$(git -C "$OUTER" diff --cached --name-only)"
  [ -z "$staged" ] || fail "5: the enclosing repo must never be operated on (staged: $staged)"
  echo "PASS: 5 a store dir without its OWN .git refuses to sync (never operates on an enclosing repo)"
)

# ============================================================================
# The two-environment story (acceptance: a second environment inits the
# store from the remote and pulls the operator's real store).
# ============================================================================

# --- Environment A: the operator's machine ----------------------------------
ENV_A_HOME="$TMP/home-a"
STORE_A="$TMP/store-a"
mkdir -p "$ENV_A_HOME"

(
  export HOME="$ENV_A_HOME"
  export KNOWLEDGE_STORE_ROOT="$STORE_A"
  # shellcheck source=/dev/null
  source "$LIB"

  # 6. init: repo + remote wired, idempotent, set-url on re-init.
  ks_sync init "$REMOTE" >/dev/null || fail "6: init should succeed"
  [ -d "$STORE_A/.git" ] || fail "6: init should create the store's own .git"
  got_url="$(git -C "$STORE_A" remote get-url origin)"
  [ "$got_url" = "$REMOTE" ] || fail "6: origin should point at the fixture remote (got: $got_url)"
  got_branch="$(git -C "$STORE_A" symbolic-ref --short HEAD)"
  [ "$got_branch" = "main" ] || fail "6: init should pin branch main regardless of host init.defaultBranch (got: $got_branch)"
  ks_sync init "$REMOTE" >/dev/null || fail "6: re-init should be idempotent (exit 0)"
  ks_sync init "$REMOTE.elsewhere" >/dev/null || fail "6: re-init with a new URL should succeed"
  [ "$(git -C "$STORE_A" remote get-url origin)" = "$REMOTE.elsewhere" ] \
    || fail "6: re-init should update the remote URL (set-url)"
  ks_sync init "$REMOTE" >/dev/null   # restore for the rest of the run
  echo "PASS: 6 init creates the repo (branch main), wires origin, is idempotent, and set-urls on re-init"

  # 7. write through the seam, push to the remote.
  printf 'the real store note\n' | ks_write "Decisions/real-note" \
    || fail "7: ks_write into the sync-initialized store should succeed"
  ks_sync push >/dev/null || fail "7: push should succeed"
  n_commits="$(git -C "$REMOTE" rev-list --count refs/heads/main)"
  [ "$n_commits" -eq 1 ] || fail "7: remote should hold exactly 1 commit after first push (got $n_commits)"
  echo "PASS: 7 environment A pushes the store to the (local bare) private-remote stand-in"

  # 8. push with nothing new: no new commit, still exit 0.
  ks_sync push >/dev/null || fail "8: no-change push should still exit 0"
  n_commits2="$(git -C "$REMOTE" rev-list --count refs/heads/main)"
  [ "$n_commits2" -eq 1 ] || fail "8: a no-change push must not manufacture a commit (got $n_commits2)"
  echo "PASS: 8 a no-change push is a clean no-op (no empty commit)"
)

# --- Environment B: a second, fresh environment -----------------------------
ENV_B_HOME="$TMP/home-b"
STORE_B="$TMP/store-b"
mkdir -p "$ENV_B_HOME"

(
  export HOME="$ENV_B_HOME"
  export KNOWLEDGE_STORE_ROOT="$STORE_B"
  # shellcheck source=/dev/null
  source "$LIB"

  # 9. init from the operator's remote + pull the real store.
  ks_sync init "$REMOTE" >/dev/null || fail "9: second-environment init should succeed"
  ks_sync pull >/dev/null || fail "9: second-environment pull should succeed"
  got="$(ks_read "Decisions/real-note")" || fail "9: the pulled note should be readable through the seam"
  [ "$got" = "the real store note" ] || fail "9: pulled note content mismatch (got: $got)"
  echo "PASS: 9 a second environment inits from the remote and pulls the operator's real store"
)

# --- 10. round-trip: A pushes an update, B pulls it --------------------------
(
  export HOME="$ENV_A_HOME"
  export KNOWLEDGE_STORE_ROOT="$STORE_A"
  # shellcheck source=/dev/null
  source "$LIB"
  printf 'second note\n' | ks_write "Patterns/second" || fail "10: A's second write should succeed"
  ks_sync push -m "second note" >/dev/null || fail "10: A's second push should succeed"
)
(
  export HOME="$ENV_B_HOME"
  export KNOWLEDGE_STORE_ROOT="$STORE_B"
  # shellcheck source=/dev/null
  source "$LIB"
  ks_sync pull >/dev/null || fail "10: B's pull of the update should succeed"
  got="$(ks_read "Patterns/second")" || fail "10: B should read the updated note"
  [ "$got" = "second note" ] || fail "10: round-trip content mismatch (got: $got)"
  want_list="$(printf 'Decisions/real-note.md\nPatterns/second.md')"
  got_list="$(ks_list)"
  [ "$got_list" = "$want_list" ] || fail "10: B's store listing should match A's pushed corpus (got: $got_list)"
  echo "PASS: 10 update round-trip — A pushes (custom -m), B pulls, corpus converges"
)

# --- 11. sync ops ride the ks_ dispatch: read-log telemetry emitted ----------
grep -q ' · script · sync · ' "$KNOWLEDGE_READ_LOG" \
  || fail "11: sync dispatches should emit read-log telemetry lines (op=sync)"
echo "PASS: 11 sync ops route through ks__dispatch (op=sync read-log lines present)"

# --- 12. status after init/push: reports store, remote, branch ---------------
(
  export HOME="$ENV_A_HOME"
  export KNOWLEDGE_STORE_ROOT="$STORE_A"
  # shellcheck source=/dev/null
  source "$LIB"
  out="$(ks_sync status)" || fail "12: status should exit 0"
  case "$out" in
    *"$STORE_A"*) : ;;
    *) fail "12: status should name the store root (got: $out)" ;;
  esac
  case "$out" in
    *"$REMOTE"*) : ;;
    *) fail "12: status should name the remote (got: $out)" ;;
  esac
  case "$out" in
    *"branch: main"*) : ;;
    *) fail "12: status should name the branch (got: $out)" ;;
  esac
  echo "PASS: 12 status reports store, remote, and branch after a real sync"
)

echo "ALL PASS: knowledge_store sync capability (plain-files git-backed + exit-3 degradation)"
