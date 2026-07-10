#!/usr/bin/env bash
#
# deploy-mini.sh — bring this machine's board-toolkit consumers current (foundation #149).
#
# The board toolkit's source of truth is foundation/workflows/scripts/board/. A
# CONSUMING checkout (foundation itself for the PATH commands; each stageFind
# checkout for the vendored scripts/lib/board.sh that its Claude sessions source)
# only gets a toolkit change when it is pulled — there is no automation, so
# checkouts drift and a stale one runs an outdated adapter (the #128 silent-no-op).
#
# This brings every consumer current, IDEMPOTENTLY and SAFELY:
#   - only fast-forwards checkouts that are on `main` AND clean — a dirty or
#     feature-branch checkout (an active session's work) is SKIPPED, never touched;
#   - sweeps merged LOCAL branches in each clean-on-main checkout (F#653) so the
#     local accumulation a build machine leaves behind is cleared automatically,
#     not when a human remembers `make prune-branches` (remote heads auto-delete via
#     the repo setting; this is local-only, `git branch -d`, worktree-bound skipped);
#   - refreshes the PATH board symlinks (make install-board);
#   - busts the board STRUCTURE cache when a pulled adapter actually changed, so a
#     board renumber/migration can't leave stale project/field ids that break WRITES
#     (the cache is logical-board-keyed with a 24h TTL — reads stay live, but a
#     post-renumber write hits "item does not exist in the project"; foundation #341);
#   - VERIFIES the #128 guard is present in every board.sh a session could source,
#     exiting non-zero if any is missing (e.g. a sync PR that was never merged).
#
# Run manually (`make deploy-mini`) after a board-toolkit change reaches the repos,
# or automatically via the session-start-deploy-mini.sh SessionStart hook (mini only).
#
# Self-update note: foundation is itself a managed checkout, so this script pulls
# the repo it lives in. The pull is `--ff-only` and runs at session start (before
# the session does work) — the safe moment; a mid-run swap of this file is harmless
# because the operation is idempotent (the next run reconciles anything missed).
#
# Overrides (used by the test): DEPLOY_MINI_CHECKOUTS, DEPLOY_MINI_LOCK,
# DEPLOY_MINI_SKIP_INSTALL=1.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Consumers to keep current: foundation (PATH commands) + the stageFind checkouts
# whose sessions source the vendored adapter. Overridable for tests / other hosts.
DEFAULT_CHECKOUTS="$FOUNDATION $HOME/dev/stageFind $HOME/dev/batch/stageFind $HOME/dev/batch2/stageFind"
read -r -a CHECKOUTS <<<"${DEPLOY_MINI_CHECKOUTS:-$DEFAULT_CHECKOUTS}"

# --- single-instance lock (portable: macOS has no flock) ---------------------
# The lock is a directory (mkdir is atomic everywhere); the owner's PID is written
# inside it. We steal a lock ONLY when its owner is genuinely gone — a dead PID, or
# no PID yet but older than 10 min — so a slow-but-live deploy is never displaced.
# The EXIT trap removes the lock only if WE still own it, so a finishing instance
# never frees another's lock. Concurrent session starts → one runs, the rest exit.
LOCK="${DEPLOY_MINI_LOCK:-${TMPDIR:-/tmp}/deploy-mini.lock.d}"
_lock_age() { local now; now="$(date +%s)"; echo "$(( now - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo "$now") ))"; }
acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then echo "$$" >"$LOCK/pid" 2>/dev/null; return 0; fi
  local owner; owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$owner" ]; then
    kill -0 "$owner" 2>/dev/null && return 1            # owner alive — respect the lock
  elif [ "$(_lock_age)" -lt 600 ]; then
    return 1                                            # no pid yet but fresh — mid-init, respect
  fi
  rm -rf "$LOCK" 2>/dev/null || true                    # orphaned (dead owner / stale) — steal
  mkdir "$LOCK" 2>/dev/null && { echo "$$" >"$LOCK/pid" 2>/dev/null; return 0; }
  return 1
}
if ! acquire_lock; then echo "deploy-mini: another instance holds the lock — skipping"; exit 0; fi
trap 'if [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$LOCK" 2>/dev/null || true; fi' EXIT

tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

# board.sh a session could source, for this checkout (foundation layout vs vendored).
board_sh_of() {
  local co="$1"
  if   [ -f "$co/workflows/scripts/board/lib/board.sh" ]; then printf '%s' "$co/workflows/scripts/board/lib/board.sh"
  elif [ -f "$co/scripts/lib/board.sh" ];                 then printf '%s' "$co/scripts/lib/board.sh"
  fi
}

# --- 1. fast-forward each clean-on-main checkout -----------------------------
echo "==> deploy-mini"
adapter_changed=0   # set when a pull's diff touches a board.sh (gates the #341 bust)
for co in "${CHECKOUTS[@]}"; do
  label="$(tilde "$co")"
  if ! git -C "$co" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '  %-26s SKIP (absent / not a git repo)\n' "$label"; continue
  fi
  branch="$(git -C "$co" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$branch" != "main" ]; then
    # F#1098: a checkout stranded on an ALREADY-MERGED feature branch (its PR merged,
    # nothing unmerged) used to be SKIPPED here forever — silently blocking the funnel's
    # clean-on-main merge tier for days (funnel-drive.sh refuses to merge from a non-main
    # tree, and nothing ever reset the checkout — F#687). Auto-recover ONLY the provably
    # safe case: a clean tree whose HEAD is fully contained in origin/main
    # (`--is-ancestor` = every commit already merged) → switch to main and fall through to
    # the ff-merge below. An UNMERGED feature branch (real in-flight work) or a dirty tree
    # is still skipped, never reset — no risk to an active session. `--is-ancestor`
    # detects the MERGE-commit method every build repo uses; a squash/rebase-merged branch
    # would not read as an ancestor (no build repo squash-merges).
    if [ -z "$(git -C "$co" status --porcelain 2>/dev/null)" ] \
       && git -C "$co" fetch --quiet origin 2>/dev/null \
       && git -C "$co" merge-base --is-ancestor HEAD origin/main 2>/dev/null \
       && git -C "$co" switch --quiet main 2>/dev/null; then
      printf '  %-26s RECOVERED (was on merged '\''%s'\'' → main; F#1098)\n' "$label" "$branch"
      branch=main   # fall through to the ff-merge below
    else
      printf '  %-26s SKIP (on '\''%s'\'', not main)\n' "$label" "$branch"; continue
    fi
  fi
  if [ -n "$(git -C "$co" status --porcelain 2>/dev/null)" ]; then
    printf '  %-26s SKIP (dirty — active work)\n' "$label"; continue
  fi
  if ! git -C "$co" fetch --quiet origin 2>/dev/null; then
    printf '  %-26s SKIP (fetch failed)\n' "$label"; continue
  fi
  before="$(git -C "$co" rev-parse --short HEAD 2>/dev/null)"
  if git -C "$co" merge --ff-only --quiet '@{u}' 2>/dev/null; then
    after="$(git -C "$co" rev-parse --short HEAD 2>/dev/null)"
    if [ "$before" = "$after" ]; then printf '  %-26s already current (%s)\n' "$label" "$after"
    else
      printf '  %-26s pulled → %s\n' "$label" "$after"
      # Did the pulled range touch the board adapter (either layout)? Only then is
      # a structure-cache bust warranted (#341) — keeps the 24h cache otherwise warm.
      if git -C "$co" diff --name-only "$before" "$after" 2>/dev/null \
           | grep -qE '(^|/)(workflows/scripts/board/lib|scripts/lib)/board\.sh$'; then
        adapter_changed=1
      fi
    fi
  else
    printf '  %-26s SKIP (cannot ff-merge — diverged)\n' "$label"
  fi

  # Sweep merged LOCAL branches in this clean-on-main checkout (F#653). The repo's
  # delete_branch_on_merge clears new REMOTE heads, but nothing clears the local
  # accumulation a dev/build machine leaves behind — so do it here, on the loop that
  # already visits each checkout, instead of relying on a human running
  # `make prune-branches`. LOCAL ONLY (no --remote): safe by construction — this
  # runs only on a checkout already verified clean-on-main, `git branch -d` refuses
  # any unmerged branch, worktree-bound branches are skipped (F#650), and main / the
  # current branch are never candidates. Best-effort (foundation's copy is repo-
  # agnostic, run against $co's repo); its exit code is log-only — a prune hiccup
  # must never fail the deploy.
  if [ -x "$FOUNDATION/scripts/prune-merged-branches.sh" ]; then
    prune_out="$( (cd "$co" && bash "$FOUNDATION/scripts/prune-merged-branches.sh" --apply) 2>&1 )"
    prune_sum="$(printf '%s\n' "$prune_out" | grep -E '^Done\.' || true)"
    [ -n "$prune_sum" ] && printf '  %-26s %s\n' "$label" "prune: ${prune_sum#Done. }"
  fi
done

# --- 2. refresh PATH board symlinks (idempotent) -----------------------------
if [ "${DEPLOY_MINI_SKIP_INSTALL:-0}" != 1 ]; then
  if make -C "$FOUNDATION" install-board >/dev/null 2>&1; then
    echo "  ✓ PATH symlinks current"
  else
    echo "  ! install-board reported an issue (see: make -C $(tilde "$FOUNDATION") install-board)"
  fi
fi

# --- 2.5 bust the board structure cache IF a pulled adapter changed (#341) ----
# The structure cache (project id + field/option ids) is keyed on the LOGICAL board
# number under a 24h TTL, so after a board renumber/migration a freshly-pulled
# adapter keeps serving the OLD project's ids until the TTL lapses — reads pass
# (item-list is always live) but WRITES fail with "item does not exist in the
# project". Busting here, ONLY when a pull actually changed a board.sh, makes a
# renumber self-heal on the next session without flushing the cache every run.
# Sourced in a subshell so board.sh's constants/`set` never leak into this script;
# board_bust_structure honours BOARD_CACHE_DIR, so tests stay hermetic.
if [ "$adapter_changed" = 1 ]; then
  if busted="$(
        # shellcheck source=/dev/null
        . "$FOUNDATION/workflows/scripts/board/lib/board.sh" || exit 1
        out=""
        for b in 3 4 5 6 7 8 9; do
          board_repo "$b" >/dev/null 2>&1 && { board_bust_structure "$b"; out="$out $b"; }
        done
        printf '%s' "$out"
      )"; then
    echo "  ✓ structure cache busted (adapter changed) — boards:${busted:- none}"
  else
    echo "  ! could not source board.sh to bust structure cache"
  fi
fi

# --- 3. verify the guard is present in every board.sh a session could source -
# Also reports (informationally only — never affects this step's pass/fail
# below) which boards each checkout has opted into the issue-cache store
# (F#988/#1026, `board.<N>.cache=on`) and whether that board's on-disk store
# directory exists yet. A checkout with no boards.conf, or a board.sh stub
# with no adjacent cache.sh (e.g. this script's own test fixtures), simply
# reports nothing for this checkout rather than erroring.
n=0; pass=0; missing=""
for co in "${CHECKOUTS[@]}"; do
  bsh="$(board_sh_of "$co")"; [ -n "$bsh" ] || continue
  n=$((n + 1))
  if grep -q '_board_assert_item_id' "$bsh" 2>/dev/null; then
    pass=$((pass + 1))
  else
    missing="$missing $(tilde "$bsh")"
  fi

  cache_lib="$(dirname "$bsh")/cache.sh"
  if [ -f "$cache_lib" ]; then
    machine_conf="${XDG_CONFIG_HOME:-$HOME/.config}/foundation/boards.conf"
    repo_conf="$(dirname "$bsh")/../boards.conf"
    conf=""
    if [ -f "$machine_conf" ]; then conf="$machine_conf"
    elif [ -f "$repo_conf" ]; then conf="$repo_conf"
    fi
    if [ -n "$conf" ]; then
      cache_store_root="${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop}"
      while IFS= read -r cn; do
        [ -n "$cn" ] || continue
        repo="$(BOARD_CACHE_DIR="${BOARD_CACHE_DIR:-}" bash -c '. "'"$bsh"'" 2>/dev/null; board_repo "'"$cn"'" 2>/dev/null')"
        store_state="absent"
        if [ -n "$repo" ] && [ -f "${cache_store_root}/issues/$(printf '%s' "$repo" | tr '/' '-')/meta.json" ]; then
          store_state="present"
        fi
        printf '  %-26s cache enabled: board %s (store %s)\n' "$(tilde "$co")" "$cn" "$store_state"
      done < <(grep -oE '^board\.[0-9]+\.cache=on$' "$conf" 2>/dev/null | cut -d. -f2 | sort -un)
    fi
  fi
done
if [ "$n" -eq 0 ]; then
  echo "  (no board.sh found to verify)"
  exit 0
fi
if [ "$pass" -eq "$n" ]; then
  echo "  ✓ guard present in $pass/$n board.sh"
  exit 0
fi
echo "  ✗ guard MISSING in $((n - pass))/$n board.sh:$missing"
echo "    (a current checkout missing the guard means its sync PR was never merged;"
echo "     a skipped checkout above is dirty/feature-branch — resolve it and re-run)"
exit 1
