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
#   - resolves each checkout's ROLE via env-reconcile.sh's role registry
#     (temperloop#1828, CLAUDE.kernel.md § Environment hygiene): only a
#     CRON/KERNEL-role checkout — structurally nobody's interactive home — is
#     auto-healed by the steps below. An OPERATOR/CONSUMER-role checkout (or one
#     in neither registry) gets its drift REPORTED on a printed line and is
#     never mutated: no HEAD switch, no ff-merge, no branch delete, no worktree
#     prune;
#   - only fast-forwards (cron-role) checkouts that are on `main` AND clean — a
#     dirty or feature-branch checkout (an active session's work) is SKIPPED,
#     never touched;
#   - sweeps merged LOCAL branches in each clean-on-main checkout (F#653) so the
#     local accumulation a build machine leaves behind is cleared automatically,
#     not when a human remembers `make prune-branches` (remote heads auto-delete via
#     the repo setting; this is local-only, `git branch -d`, worktree-bound skipped);
#   - sweeps merged/orphaned `<checkout>.wt/*` worktrees in each clean-on-main
#     checkout (#168), via worktree.sh's hardened merged-detection (squash/rebase
#     merges included, not just plain-ancestor) — a dirty or genuinely-unmerged
#     worktree is left in place;
#   - refreshes the PATH board symlinks (make install-board);
#   - busts the board STRUCTURE cache when a pulled adapter actually changed, so a
#     board renumber/migration can't leave stale project/field ids that break WRITES
#     (the cache is board-id-keyed with a 24h TTL — reads stay live, but a
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
# DEPLOY_MINI_SKIP_INSTALL=1. Role membership honors env-reconcile.sh's own
# ENV_RECONCILE_CRON_CHECKOUTS / ENV_RECONCILE_OPERATOR_CHECKOUTS overrides
# (the registry is sourced from that script, not duplicated here).
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

# --- checkout roles (temperloop#1828) ----------------------------------------
# CLAUDE.kernel.md § Environment hygiene: auto-fix is permitted only in
# checkouts that are structurally nobody's interactive home — the cron/kernel
# role. An operator/consumer checkout may be another session's active lane, so
# its drift is REPORTED, never auto-corrected. Roles resolve through
# env-reconcile.sh's role registry (the kernel's detection substrate), sourced
# in a subshell so its CRON_CHECKOUTS / OPERATOR_CHECKOUTS arrays — and their
# ENV_RECONCILE_* overrides — stay the single source of truth rather than a
# second list here. Operator rows are emitted first so a path somehow present
# in BOTH registries resolves to the safe (report-only) arm. A checkout in
# NEITHER registry also defaults to operator: an unknown role cannot be
# established as safe to mutate. Fail-safe: if env-reconcile.sh is missing or
# unsourceable the table is empty and everything reports only.
ENV_RECONCILE="$FOUNDATION/workflows/scripts/build/env-reconcile.sh"
ROLE_TABLE=""
if [ -f "$ENV_RECONCILE" ]; then
  ROLE_TABLE="$(_ENV_RECONCILE_PATH="$ENV_RECONCILE" bash -c '
    set --                        # sourced arg-parse loop must see an empty $@
    source "$_ENV_RECONCILE_PATH" >/dev/null 2>&1 || exit 0
    _i=0
    while [ "$_i" -lt "${#OPERATOR_CHECKOUTS[@]}" ]; do
      printf "operator\t%s\n" "${OPERATOR_CHECKOUTS[$_i]}"; _i=$((_i + 1))
    done
    _i=0
    while [ "$_i" -lt "${#CRON_CHECKOUTS[@]}" ]; do
      printf "cron\t%s\n" "${CRON_CHECKOUTS[$_i]}"; _i=$((_i + 1))
    done
  ' 2>/dev/null || true)"
fi

# canon <path> — physical path for comparison (symlink-stable, e.g. /tmp vs /private/tmp).
canon() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

# role_of <checkout> — "cron" or "operator" (first table match wins; default operator).
role_of() {
  local co_canon role path
  co_canon="$(canon "$1")"
  while IFS=$'\t' read -r role path; do
    [ -n "$path" ] || continue
    if [ "$(canon "$path")" = "$co_canon" ]; then printf '%s' "$role"; return 0; fi
  done <<<"$ROLE_TABLE"
  printf 'operator'
}

# report_operator_drift <checkout> <label> — the report-only arm. Inspects and
# prints; runs NO mutating operation (no `git switch`, no `git merge`, no
# branch prune, no worktree prune). The one remote touch is `git fetch`, which
# updates remote-tracking refs only — never the working tree, HEAD, or a local
# branch — so behind-ness is measured against a current origin/main; a failed
# fetch degrades to the on-disk remote-tracking ref (env-reconcile's posture).
report_operator_drift() {
  local co="$1" label="$2" drift="" branch behind
  branch="$(git -C "$co" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$branch" != "main" ]; then drift="on '$branch', not main"; fi
  if [ -n "$(git -C "$co" status --porcelain 2>/dev/null)" ]; then
    drift="${drift:+$drift; }dirty tree"
  fi
  git -C "$co" fetch --quiet origin 2>/dev/null || true
  if git -C "$co" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    behind="$(git -C "$co" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
    if [ "${behind:-0}" -gt 0 ] 2>/dev/null; then
      drift="${drift:+$drift; }behind origin/main by $behind"
    fi
  fi
  if [ -n "$drift" ]; then
    printf '  %-26s DRIFT (operator role — report-only): %s\n' "$label" "$drift"
  else
    printf '  %-26s current (operator role — report-only)\n' "$label"
  fi
}

# --- 1. fast-forward each clean-on-main CRON/KERNEL-role checkout ------------
# (operator/consumer-role checkouts branch off to the report-only arm — #1828)
echo "==> deploy-mini"
for co in "${CHECKOUTS[@]}"; do
  label="$(tilde "$co")"
  if ! git -C "$co" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '  %-26s SKIP (absent / not a git repo)\n' "$label"; continue
  fi
  # Role gate (temperloop#1828): everything below this line can mutate the
  # checkout (HEAD switch, ff-merge, branch prune, worktree prune) — only a
  # cron/kernel-role checkout may proceed. Anything else is report-only.
  if [ "$(role_of "$co")" != cron ]; then
    report_operator_drift "$co" "$label"
    continue
  fi
  branch="$(git -C "$co" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$branch" != "main" ]; then
    # F#1098: a checkout stranded on an ALREADY-MERGED feature branch (its PR merged,
    # nothing unmerged) used to be SKIPPED here forever — silently blocking the pipeline's
    # clean-on-main merge tier for days (pipeline-drive.sh refuses to merge from a non-main
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

  # Sweep merged/orphaned "$co".wt/* worktrees left over from /build sessions
  # (#168). worktree.sh already carries the merge-queue-safe merged-detection
  # (L1 worktree-prune-merge-robust: an ancestor test first, falling back to the
  # squash/rebase-safe helper) so a worktree whose PR merged via squash/rebase is
  # reclaimed too, not just a plain-ancestor merge. Runs only here, on the loop
  # that already only reaches clean-on-main checkouts (dirty/non-main checkouts
  # `continue`d above) — worktree.sh's own gates additionally leave a dirty or
  # genuinely-unmerged worktree untouched regardless. Fail-open, mirroring the
  # branch-prune above: a prune error is logged but must never abort deploy-mini
  # (explicit if, not `A && B || C` — SC2015 on the CI runner).
  wtsh="$FOUNDATION/workflows/scripts/build/worktree.sh"
  if [ -x "$wtsh" ]; then
    if wt_out="$(bash "$wtsh" prune "$co" 2>&1)"; then
      wt_pruned="$(printf '%s\n' "$wt_out" | grep -c '"outcome":"PRUNED"')"
      if [ -z "$wt_pruned" ]; then wt_pruned=0; fi
      if [ "$wt_pruned" -gt 0 ]; then
        printf '  %-26s %s\n' "$label" "worktree prune: $wt_pruned pruned"
      fi
    else
      printf '  %-26s %s\n' "$label" "worktree prune: FAILED (non-fatal) — ${wt_out:0:160}"
    fi
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

# --- 2.5 (retired) board structure-cache bust ------------------------------
# This step used to bust board.sh's Projects-v2 STRUCTURE cache (project id +
# field/option ids, 24h TTL) whenever a pull changed a board.sh, so a board
# renumber/migration self-healed instead of failing every WRITE with "item does
# not exist in the project" until the TTL lapsed (#341). Both the cache and
# `board_bust_structure` were removed with the Projects-v2 arm (ADR 0004, epic
# temperloop#524): the issues-only path resolves a board's repo from
# `boards.conf`/the built-in map on every call and holds no cached project
# identity, so there is nothing left to go stale and nothing to bust.
#
# The `adapter_changed` probe that gated this step went with it — it had no
# other consumer, so keeping it would have left a dead diff-scan on every pull.
# Step 3 below still verifies the guard in every pulled board.sh unconditionally,
# which is the check that actually matters after an adapter change.

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
    # temperloop#616: enumerate this checkout's boards.conf layers through the
    # checkout's OWN board.sh resolver (_board_conf_files) rather than
    # reimplementing machine/repo-local discovery inline. _board_conf_files is
    # the single BOARDS_CONF_*-honoring discovery seam every other consumer
    # already routes through — it applies BOARDS_CONF_MACHINE + the temperloop#165
    # XDG rename (temperloop/ only; the legacy foundation/ fallback was
    # removed in v0.19.0) to the MACHINE layer, adds the #494 composed-tree
    # consumer-root conf, and honors BOARDS_CONF_REPO_LOCAL (else the
    # $bsh-relative repo-local) — so a single BOARDS_CONF_* override now
    # hermeticizes deploy-mini exactly as it does board.sh / board-mirror /
    # pipeline-tick, closing the per-consumer divergence that made the #592/#614
    # test-hermeticity leaks possible (temperloop#591 fixed only deploy-mini's
    # BOARDS_CONF_MACHINE handling — this routes the whole discovery through the
    # shared seam so nothing is reimplemented here at all). Sourced from the
    # PER-CHECKOUT $bsh so the consumer-root + repo-local layers resolve relative
    # to THIS checkout (each checkout carries its own conf; the machine layer is
    # machine-wide). Union of `cache=on` across all layers is the right set
    # semantic: a board is cache-enabled if ANY layer says so (informational
    # only — this block never affects the step's pass/fail).
    cache_store_root="${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop}"
    while IFS= read -r cn; do
      [ -n "$cn" ] || continue
      repo="$(bash -c '. "'"$bsh"'" 2>/dev/null; board_repo "'"$cn"'" 2>/dev/null')"
      store_state="absent"
      if [ -n "$repo" ] && [ -f "${cache_store_root}/issues/$(printf '%s' "$repo" | tr '/' '-')/meta.json" ]; then
        store_state="present"
      fi
      printf '  %-26s cache enabled: board %s (store %s)\n' "$(tilde "$co")" "$cn" "$store_state"
    done < <(bash -c '. "'"$bsh"'" 2>/dev/null; _board_conf_files 2>/dev/null' |
               while IFS= read -r _conf; do
                 [ -f "$_conf" ] && grep -oE '^board\.[0-9]+\.cache=on$' "$_conf" 2>/dev/null
               done | cut -d. -f2 | sort -un)
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
