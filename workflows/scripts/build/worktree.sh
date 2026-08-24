#!/usr/bin/env bash
#
# build worktree lifecycle — the deterministic-machinery script that owns the
# per-item worktree create / remove / prune steps of /build (3b / 3h / 0.5).
# Epic #253 (spike #245): these steps are pure functions of observable git
# state with a closed outcome set, so they move from prose in build.md to
# code here. The LLM orchestrator invokes this script; it never hand-rolls
# `git worktree` for build items.
#
#   worktree.sh create <repo-root> <slug>        # add worktree + drop guard marker
#   worktree.sh restore <repo-root> <slug> [--ref <ref>]
#                                                # fresh worktree + re-apply a
#                                                # #1699 preservation ref
#   worktree.sh remove <repo-root> <slug>        # remove worktree + branch + marker
#   worktree.sh prune  <repo-root> [--force]     # sweep merged <repo>.wt/* worktrees
#                                                # + dispose #1699 preservation refs
#   worktree.sh deps-merged <repo-root> <shas>   # gate: all comma-sep SHAs merged?
#
# Deterministic layout (pure function of the slug — never reported back by a
# worker): path `<repo-root>.wt/<slug>`, branch `build/<slug>`, based on
# `origin/<default>`.
#
# Guard marker (#171/#212): `create` drops a `.build-guard` marker file in
# the new worktree root. The PreToolUse write-jail hook
# (claude/hooks/build-worktree-guard.sh) arms itself by reading that marker
# — per-worktree state, so N concurrent sessions on one host arm independently
# (the env-var arming this replaces was never settable per-Agent-spawn and a
# host-wide value would mis-target across sessions). `remove` and `prune`
# clean the marker up with the worktree.
#
# Review agents (#1005): `.claude/agents/` is gitignored (ADR 0007) and so is
# absent from every fresh worktree, which made the capability probe read every
# review lens as unavailable worker-side. `create` therefore materializes the
# flat `claude/agents/*.md` catalog into the worktree's own `.claude/agents/`
# as relative symlinks — see § Review-agent propagation below.
#
# Arming self-test (foundation#1352): dropping the marker only ARMS a hook that
# is actually REACHED, so `create` immediately PROVES the jail rather than
# assuming it — see § Write-jail arming self-test below. The verdict rides the
# CREATED line as `guard`/`guard_detail`; anything but ARMED also prints a loud
# stderr banner. The probe never blocks a create.
#
# Concurrency (temperloop#1171): `git worktree add` WRITES `.git/config`, and
# git takes that lock without waiting or retrying — so two concurrent creates on
# one repo (a /build level, a /sweep chunk at width > 1) collided outright, and
# the loser was left with an orphan `build/<slug>` branch. Every config/ref-
# mutating region of create/remove/prune now runs under one per-repo directory
# lock, and a failed `worktree add` is rolled back, so an ERROR outcome leaves
# no durable state and a naive retry is a clean create. See § Repo-wide mutation
# lock and § Atomic create failure below.
#
# Output contract — CLOSED outcome set, one structured JSON line per outcome,
# no prose (the orchestrator branches on `.outcome`, never parses prose):
#   create →  {"outcome":"CREATED","path":…,"branch":…,"base":…,
#              "guard":"ARMED"|"UNARMED"|"UNKNOWN","guard_detail":…,
#              "preserved":bool,"preserved_ref":…,"preserved_detail":…,
#              "sidelined":bool,"sidelined_path":…,"sidelined_branch":…}
#   restore → {"outcome":"RESTORED","path":…,"branch":…,"base":…,"ref":…,"sha":…,
#              "strategy":"fast-forward"|"merge","guard":…,"guard_detail":…} |
#             {"outcome":"RESTORE_CONFLICT","path":…,"branch":…,"base":…,"ref":…,
#              "sha":…,"conflicts":[…],"aborted":true,"error":…} |
#             {"outcome":"RESTORE_NOT_FOUND","slug":…,"ref":…}
#   remove →  {"outcome":"REMOVED"|"NOT_FOUND","path":…,"branch":…,
#              "preserved":bool,"preserved_ref":…,"preserved_detail":…} |
#             {"outcome":"REMOVE_REFUSED","path":…,"branch":…,
#              "preserved":false,"preserved_ref":…,"preserved_detail":…}
#              + non-zero exit  (§ Never destroy what preservation missed)
#   prune  →  one line per <repo>.wt/* worktree:
#             {"outcome":"PRUNED"|"SKIPPED_FRESH"|"SKIPPED_DIRTY"|"SKIPPED_UNMERGED","path":…,"branch":…}
#             …one line per SIDELINED worktree (a `.unpreserved-<sha8>` path):
#             {"outcome":"SIDELINED_WT_REAPED"|"SIDELINED_WT","path":…,"branch":…,
#              "slug":…,"issue":…,"issue_state":…,"landed":bool,"reason":…}
#             …then one line per preservation ref (§ Unlanded-work preservation):
#             {"outcome":"PARKED_REF_REAPED"|"PARKED_REF","ref":…,"sha":…,"slug":…,
#              "issue":…,"issue_state":…,"landed":bool,"reason":…}
#   deps-merged → {"outcome":"DEPS_MERGED"} | {"outcome":"DEPS_UNMERGED","unmerged":[…]}
#   error  →  {"outcome":"ERROR","error":…} + non-zero exit
#
# NOTE on the CREATED/REMOVED `preserved*` fields (temperloop#1699): the
# unlanded-work verdict rides those lines as FIELDS, never as a new `outcome`
# string, and `create` never refuses — see § Unlanded-work preservation below.
# The same holds for `create`'s SIDELINE verdict (`sidelined*`, temperloop#1730):
# fields on the existing CREATED line, never a new `outcome`.
# `restore`'s own outcomes are NOT in build-level.mjs's SPINE_OUTCOME_SCHEMA
# because the build spine never invokes `restore`; the specs that do (`/fix`,
# `/sweep`) call it directly.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

# merged_detect_is_merged (#171/#173) — merge-queue-safe merged-detection
# (gh pr view state, falling back to a squash-safe cherry heuristic) used by
# prune_one below to reclaim a squash/rebase-merged branch whose tip is NOT an
# ancestor of origin/<default> even though it landed. Sourced by repo-relative
# path from this script's own location so it resolves regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/merged-detect.sh
source "$SCRIPT_DIR/lib/merged-detect.sh"

# fd 3 = the script's real stdout. Helpers like resolve_repo run inside
# command substitutions, where a die()'s ERROR line would be captured by the
# caller instead of reaching the orchestrator — emitting via fd 3 keeps the
# structured error on the real stdout regardless of call context.
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: worktree.sh create <repo-root> <slug> | restore <repo-root> <slug> [--ref <ref>] | remove <repo-root> <slug> | prune <repo-root> [--force] | deps-merged <repo-root> <sha,sha,...>"
}

# Physical-path resolve for an EXISTING dir (portable — no GNU readlink -f).
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# Resolve + validate the repo root: must exist, be a git work tree, and BE the
# toplevel (not a subdir) — the deterministic `<repo-root>.wt/<slug>` path is
# derived from it, so a subdir would silently scatter worktrees.
resolve_repo() {
  local arg="$1" repo top
  repo="$(abs_dir "$arg")" || die "repo-root '$arg' does not exist"
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || die "repo-root '$arg' is not inside a git work tree"
  top="$(abs_dir "$top")"
  [ "$repo" = "$top" ] || die "repo-root '$arg' is not a git toplevel (toplevel is '$top')"
  printf '%s\n' "$repo"
}

# Validate the slug (plan-schema shape). It feeds rm -rf'able paths and branch
# names, so reject anything outside the closed character set.
validate_slug() {
  local slug="$1"
  case "$slug" in
    *[!a-z0-9-]*|"") die "slug '$slug' invalid — must match [a-z0-9-]+" ;;
  esac
}

# The repo's default branch, from origin's HEAD (falling back to main/master).
default_branch() {
  local repo="$1" ref b
  if ref="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for b in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$b"; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  return 1
}

# Append the build tooling markers to the shared info/exclude (idempotent)
# so they never show up as untracked files in any worktree's `git status` — a
# worker's `git add -A` must not be able to commit them. Covers the write-jail
# marker (`.build-guard`, #171/#212) and the verification-surface artifact
# (`.build-verification.md`, #418 — the worker writes its PR verification
# surface there and returns only the path; pr.sh reads it directly).
exclude_marker() {
  local repo="$1" common f
  common="$(git -C "$repo" rev-parse --git-common-dir)"
  case "$common" in /*) ;; *) common="$repo/$common" ;; esac
  mkdir -p "$common/info"
  for f in .build-guard .build-verification.md; do
    grep -qxF "$f" "$common/info/exclude" 2>/dev/null \
      || echo "$f" >> "$common/info/exclude"
  done
}

# --- Repo-wide mutation lock (temperloop#1171) -------------------------------
#
# THE RACE, observed live. `git worktree add -b <branch>` WRITES `.git/config`
# (it records the new branch's upstream), and git takes that write lock the
# same way it takes every config lock: `.git/config.lock` created O_EXCL, with
# NO retry and NO wait. Two concurrent `create`s on one repo — the ordinary
# shape of a /build level or a /sweep chunk at SWEEP_FANOUT_WIDTH>1 — therefore
# collide outright:
#
#   Preparing worktree (new branch 'build/<slug>')
#   error: could not lock config file .git/config: File exists
#   error: unable to write upstream branch configuration
#
# and the loser's `worktree add` exits non-zero having ALREADY created the
# branch (see § Atomic create failure below). git will not serialize this for
# us, so worktree.sh does: every config/ref-mutating region of create, remove
# and prune runs under one per-repo lock, so the losers WAIT instead of failing.
#
# WHY A DIRECTORY LOCK, not flock. `mkdir` is atomic on every POSIX filesystem
# and needs no binary; stock macOS ships NO `flock` (the same reason
# board/deploy-mini.sh and pipeline-tick.sh's degradation path exist), so an
# flock-based lock would silently no-op on the exact host this defect fires on.
# A directory also carries the owner's pid as a file inside it, which is what
# makes stale-lock stealing safe.
#
# SCOPE. The lock is keyed on the repo's shared git common dir, so concurrent
# creates in DIFFERENT repos never block each other, and a worktree's own
# `git commit` (which touches no shared config) is never serialized. It is held
# only across the mutating git calls — never across the guard probe, never
# across a `gh` call.
#
# NEVER DEADLOCKS. Re-entrant (a depth counter, so a locked region nested in a
# locked region is a no-op rather than a self-deadlock); released by an EXIT
# trap so a `die` mid-region cannot strand it; bounded by a wait budget after
# which `create` reports a structured ERROR rather than hanging a build; and it
# steals a lock whose owner pid is provably gone (or which has no pid and has
# aged out), so a killed worker cannot wedge every later run.
WT_LOCK_DIR=""
WT_LOCK_DEPTH=0
# Wait budget in 0.1s ticks. Sized for the worst in-lock region (a `git fetch`
# over the network, several deep in a fanout), not for the common case.
WT_LOCK_WAIT_TICKS="${WORKTREE_LOCK_WAIT_TICKS:-1200}"
# A lock with no pid file yet (the mkdir/pid-write window) is respected until
# this age, then treated as debris.
WT_LOCK_STALE_SECS="${WORKTREE_LOCK_STALE_SECS:-900}"

wt_lock_age() {
  local now; now="$(date +%s)"
  echo "$(( now - $(stat -f %m "$WT_LOCK_DIR" 2>/dev/null || stat -c %Y "$WT_LOCK_DIR" 2>/dev/null || echo "$now") ))"
}

# wt_lock_acquire <repo> — block until this process owns the repo's mutation
# lock. Returns non-zero only when the wait budget is exhausted.
wt_lock_acquire() {
  local repo="$1" common ticks=0 owner
  if [ "$WT_LOCK_DEPTH" -gt 0 ]; then
    WT_LOCK_DEPTH=$((WT_LOCK_DEPTH + 1))
    return 0
  fi
  common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in /*) ;; *) common="$repo/$common" ;; esac
  WT_LOCK_DIR="$common/build-worktree.lock.d"
  while :; do
    if mkdir "$WT_LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$WT_LOCK_DIR/pid" 2>/dev/null || true
      WT_LOCK_DEPTH=1
      return 0
    fi
    owner="$(cat "$WT_LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$WT_LOCK_DIR" 2>/dev/null || true   # owner is gone — debris
      continue
    fi
    if [ -z "$owner" ] && [ "$(wt_lock_age)" -ge "$WT_LOCK_STALE_SECS" ]; then
      rm -rf "$WT_LOCK_DIR" 2>/dev/null || true   # never claimed — debris
      continue
    fi
    ticks=$((ticks + 1))
    # Budget exhausted. WT_LOCK_DIR is deliberately left SET (the caller's die
    # message names it) — safe because release is depth-gated, so a failed
    # acquire can never remove the lock the winner still holds.
    if [ "$ticks" -ge "$WT_LOCK_WAIT_TICKS" ]; then
      return 1
    fi
    sleep 0.1
  done
}

# Release only what WE own — a finishing process must never free another's lock.
wt_lock_release() {
  [ "$WT_LOCK_DEPTH" -gt 0 ] || return 0
  WT_LOCK_DEPTH=$((WT_LOCK_DEPTH - 1))
  [ "$WT_LOCK_DEPTH" -eq 0 ] || return 0
  if [ -n "$WT_LOCK_DIR" ] && [ "$(cat "$WT_LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$WT_LOCK_DIR" 2>/dev/null || true
  fi
  WT_LOCK_DIR=""
}

# The strandproofing half: a `die` (or any exit) inside a locked region unwinds
# the lock, so one failed create can never wedge the next one.
wt_lock_release_all() {
  if [ "$WT_LOCK_DEPTH" -gt 0 ]; then
    WT_LOCK_DEPTH=1
    wt_lock_release
  fi
}
trap wt_lock_release_all EXIT

# --- Review-agent propagation into the worktree (#1005) ----------------------
#
# THE GAP. The capability-probe predicate (docs/features/review-agents.md
# § "The capability probe") resolves a review agent iff the project declares it
# in `CLAUDE.md § Subagents` OR a file exists at `.claude/agents/<name>.md`.
# But `.claude/agents/` is GITIGNORED by construction (ADR 0007 — a teammate's
# opt-in is never imposed by a `git add -A`), so it is ABSENT from every fresh
# worktree `create` hands a worker. Result: every worker-side review pass
# degraded to `skipped — <agent> unavailable`, including the review that
# build.md 3e marks MANDATORY for a `claude/commands/*.md` diff (#1007).
#
# THE FIX. Materialize the flat catalog into the worktree's own
# `.claude/agents/` as RELATIVE symlinks back to the worktree's OWN tracked
# `claude/agents/<name>.md` — the same link shape
# workflows/scripts/install/project-agents.sh deploys in-tree, so the charter a
# worker reads is the one at the commit its branch is based on, never the
# parent checkout's.
#
# WHY NOT declare `## Subagents` in the tracked CLAUDE.md instead (the other
# candidate #1005 lists): a declaration is a CLAIM about availability, a
# symlink IS availability. Declaring flips the predicate TRUE everywhere —
# including a fresh clone where nothing has ever deployed `.claude/agents/`, so
# `Task(subagent_type: workflow-reviewer)` would fail hard instead of taking
# the legible `skipped — … available as source; run
# workflows/scripts/install/project-agents.sh to enable` path #290 built. It
# would also change `CLAUDE.md`'s session-start byte count, which
# workflows/scripts/config/check-contributor-manifest.sh tracks.
#
# Deliberately conservative:
#   - FLAT `claude/agents/*.md` only. `claude/agents/reviewers/` stays inert by
#     default (ADR 0007) — a per-language reviewer is opt-in via
#     reviewer-activate.sh, never bulk-deployed here.
#   - NEVER clobbers. Anything already at a target is left alone, so a repo
#     that tracks its own `.claude/agents/` always wins.
#   - No `.gitignore` write (project-agents.sh may append one; dirtying the
#     worktree would leak an unrelated hunk into the worker's PR). The
#     exclusion rides the shared info/exclude instead, which is untracked by
#     construction. That exclusion is load-bearing, not cosmetic: an
#     un-ignored `.claude/` would read as untracked in `git status`, which
#     makes every live worktree SKIPPED_DIRTY at prune time.
#   - FAIL-OPEN. Any failure degrades to a stderr note; `create` still emits
#     its CREATED line. Review coverage is advisory and must never block a
#     build.
materialize_agents() {
  local wt="$1" src_dir dest common src name target linked=0 failed=0

  src_dir="$wt/claude/agents"
  [ -d "$src_dir" ] || return 0

  # Keep `.claude/agents/` out of `git status` first — before anything is
  # written there. Skipped when the repo's own .gitignore already covers it
  # (the kernel case), so this never appends a redundant line.
  if ! git -C "$wt" check-ignore -q -- ".claude/agents/.probe" 2>/dev/null; then
    common="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)" || common=""
    if [ -n "$common" ]; then
      case "$common" in /*) ;; *) common="$wt/$common" ;; esac
      mkdir -p "$common/info" 2>/dev/null || true
      grep -qxF '.claude/agents/' "$common/info/exclude" 2>/dev/null \
        || echo '.claude/agents/' >> "$common/info/exclude" 2>/dev/null || true
    fi
  fi

  dest="$wt/.claude/agents"
  if ! mkdir -p "$dest" 2>/dev/null; then
    printf '!! worktree.sh: could not create %s — review agents will read as UNAVAILABLE in this worktree (#1005)\n' \
      "$dest" >&2
    return 0
  fi

  for src in "$src_dir"/*.md; do
    [ -f "$src" ] || continue          # no-match glob, or a stray non-file
    name="$(basename "$src")"
    target="$dest/$name"
    if [ -e "$target" ] || [ -L "$target" ]; then
      continue                          # pre-existing / already linked — never clobber
    fi
    if ln -s "../../claude/agents/$name" "$target" 2>/dev/null; then
      linked=$((linked + 1))
    else
      failed=$((failed + 1))
    fi
  done

  if [ "$failed" -gt 0 ]; then
    printf '!! worktree.sh: %d review-agent link(s) failed under %s (%d linked) — those lenses will read as UNAVAILABLE (#1005)\n' \
      "$failed" "$dest" "$linked" >&2
  fi
  return 0
}

# --- Unlanded-work preservation (temperloop#1699) ----------------------------
#
# THE LOSS. `clear_path` below force-removes the worktree AND `git branch -D`s
# `build/<slug>`, so COMMITTING IS NOT PROTECTION: an escalated attempt that
# committed clean work is destroyed just as completely as an uncommitted one.
# Every caller that re-drives an item (`/fix` Step 4a's inline-answer branch,
# `/sweep`'s park finale, `build-level.mjs`'s 3b pre-create) reaches this
# primitive, and the loss was previously mitigated — where it was mitigated at
# all — by PROSE in one spec. Prose can be silently skipped by a worker; that is
# how the class was found (temperloop#1699, driving foundation#1791).
#
# THE SEAM. The guard lives INSIDE the destroying primitive, not at the two
# spec call sites, so every caller inherits it — including callers nobody has
# written yet. `prune_one` already refuses to reap unlanded work through three
# gates (SKIPPED_UNMERGED / SKIPPED_FRESH / SKIPPED_DIRTY); `clear_path` had
# none.
#
# TRANSPORT: a LOCAL-ONLY ref outside `refs/heads/`, never pushed.
#   * outside `refs/heads/` because `<type>/<slug>` and `build/<slug>` COLLIDE
#     whenever an item's own branch type is `build` (merged examples in this
#     repo: `build/reviewer-coverage-all-routed-1446`, #1702). A slug-derived
#     `refs/heads/*` preservation ref would then meet the re-drive's own push as
#     a non-fast-forward, whose documented recovery is `--force` — destroying
#     the preserved commits while reporting PUSHED.
#   * never pushed because this repo is public and `/sweep`'s park is
#     UNATTENDED: a push transport would auto-publish worker output that never
#     passed the acceptance gate. `git push` moves `refs/heads` and tags only,
#     so `refs/parked/*` is local by construction, not by discipline.
#
# NEVER A FALSE `preserved`, mirroring the arming probe's posture above: an
# unclassifiable tree or a failed capture resolves AWAY from claiming
# preservation and says WHY in `preserved_detail`. The verdict rides the CREATED
# line as fields (`preserved` / `preserved_ref` / `preserved_detail`), following
# the `guard` / `guard_detail` precedent — deliberately NOT a new `outcome`
# string, because build-level.mjs's SPINE_OUTCOME_SCHEMA is a closed enum whose
# own DEPS_MERGED comment records that an unlisted outcome is schema-invalid.
# For the same reason `create` NEVER refuses: a `create` that can decline would
# turn /build's prelude batch from "created" into "escalated".
PARKED_REF_NS="refs/parked"
PRESERVED="false"
PRESERVED_REF=""
PRESERVED_DETAIL="not-run"

# parked_ref_slug <ref> — the slug a preservation ref was minted for, i.e. the
# ref basename with its `-<sha8>` (and any `-<n>` collision suffix) stripped.
parked_ref_slug() {
  local name="${1##*/}"
  local re='^(.+)-[0-9a-f]{8}(-[0-9]+)?$'
  if [[ "$name" =~ $re ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$name"
  fi
}

# sidelined_wt_slug <path> — the slug a sidelined worktree was moved aside FROM,
# i.e. its basename with the `.unpreserved-<sha8>` (and any `-<n>` collision
# suffix) stripped. Mirrors parked_ref_slug so both disposal owners read the
# originating issue number off the same slug shape.
sidelined_wt_slug() {
  local name="${1##*/}"
  printf '%s\n' "${name%%.unpreserved-*}"
}

# parked_ref_issue <slug> — the ORIGINATING issue number, when the slug carries
# one as its trailing `-<digits>` field (the kernel's `<slug>-<issue#>` branch
# convention). Prints nothing when the slug carries no issue number — an
# unevaluable disposition gate, which reap_parked_ref treats as FALSE.
parked_ref_issue() {
  local slug="$1"
  local re='-([0-9]+)$'
  if [[ "$slug" =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; fi
}

# preserve_capture <wt_path> — print the sha of ONE commit object capturing the
# worktree's full state: its commits (reachable via the parent) AND whatever is
# uncommitted on disk. Prints nothing / returns non-zero on any failure.
#
# NO SEMANTIC COMMIT IS AUTHORED. The snapshot is built in a THROWAWAY index and
# sealed with `commit-tree` — a detached WIP object. The branch pointer, the
# real index and the working tree are never touched, so this cannot fail
# halfway and leave the worker's tree in a state it did not choose. (The failure
# this shape avoids: a failed preservation `git commit` makes the subsequent
# push a no-op that still reports PUSHED — a false positive.)
#
# A CLEAN tree short-circuits to the branch tip itself, so the ordinary
# committed-and-clean case mints no object at all.
#
# The exclusion pathspec is recover-probe's OWN (pr.sh cmd_recover_probe) plus
# the #418 surface artifact: `.build-guard` and `.build-verification.md` are
# orchestrator machinery, never worker work, and must never be re-committed.
#
# preserve_set_ident fills PRESERVE_IDENT with the `-c` args every
# object-writing git call here uses. `commit-tree` and `merge` REQUIRE an
# identity and a bare CI runner or fresh container has none configured — without
# this the capture would fail on machine config rather than on anything about
# the work. The repo's own identity (local/global/system) always wins; the
# machinery identity is only the floor. Deliberately `-c` config rather than
# `GIT_AUTHOR_*` / `GIT_COMMITTER_*` assignments: those read as operator-settable
# seams to check-setting-registry.sh, and they are not — they are git's own
# ident protocol.
PRESERVE_IDENT=()
preserve_set_ident() {
  local at="$1" n e
  n="$(git -C "$at" config user.name 2>/dev/null || true)"
  e="$(git -C "$at" config user.email 2>/dev/null || true)"
  [ -n "$n" ] || n="worktree.sh"
  [ -n "$e" ] || e="worktree@localhost"
  PRESERVE_IDENT=(-c "user.name=$n" -c "user.email=$e")
}

preserve_capture() {
  local wt="$1" head idx tree sha head_tree
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || return 1
  [ -n "$head" ] || return 1
  idx="$(mktemp "${TMPDIR:-/tmp}/wt-parked-idx.XXXXXX")" || return 1
  rm -f "$idx"
  if ! GIT_INDEX_FILE="$idx" git -C "$wt" read-tree "$head" 2>/dev/null; then
    rm -f "$idx"
    return 1
  fi
  GIT_INDEX_FILE="$idx" git -C "$wt" add -A -- \
    ':(exclude).build-guard' ':(exclude).build-verification.md' 2>/dev/null || true
  tree="$(GIT_INDEX_FILE="$idx" git -C "$wt" write-tree 2>/dev/null)" || tree=""
  rm -f "$idx"
  [ -n "$tree" ] || return 1

  head_tree="$(git -C "$wt" rev-parse "${head}^{tree}" 2>/dev/null)" || head_tree=""
  if [ -n "$head_tree" ] && [ "$tree" = "$head_tree" ]; then
    printf '%s\n' "$head"
    return 0
  fi
  preserve_set_ident "$wt"
  sha="$(git -C "$wt" "${PRESERVE_IDENT[@]}" commit-tree "$tree" -p "$head" \
           -m 'parked: WIP snapshot preserved before clear_path (#1699)' 2>/dev/null)" || sha=""
  [ -n "$sha" ] || return 1
  printf '%s\n' "$sha"
}

# preserve_mint_ref <repo> <slug> <sha> — point a local-only preservation ref at
# <sha> and print its name. Idempotent when the ref already names the SAME sha;
# a ref that already names a DIFFERENT one (an 8-hex prefix collision, or a
# hand-created ref) is never clobbered — the mint disambiguates with a `-<n>`
# suffix instead. Returns non-zero (printing nothing) when no usable name can be
# claimed, which resolves the caller AWAY from claiming preservation.
preserve_mint_ref() {
  local repo="$1" slug="$2" sha="$3" base ref existing n=1
  base="$PARKED_REF_NS/${slug}-${sha:0:8}"
  ref="$base"
  while : ; do
    git check-ref-format "$ref" >/dev/null 2>&1 || return 1
    existing="$(git -C "$repo" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)" || existing=""
    if [ -z "$existing" ] || [ "$existing" = "$sha" ]; then break; fi
    n=$((n + 1))
    [ "$n" -le 20 ] || return 1
    ref="${base}-${n}"
  done
  git -C "$repo" update-ref "$ref" "$sha" 2>/dev/null || return 1
  printf '%s\n' "$ref"
}

# preserve_unlanded <repo> <wt_path> <branch> — sets PRESERVED / PRESERVED_REF /
# PRESERVED_DETAIL.
#
# RETURN VALUE IS THE DESTRUCTION GATE (temperloop#1730). Until this item the
# helper always returned 0 and both destroying callers ran `|| true`, so a
# capture FAILURE was indistinguishable from a capture that was never needed —
# and the work was destroyed with nothing captured. The return now separates
# exactly those two:
#   0  — the loss window is CLOSED. Either nothing could be lost
#        (`no-occupant` / `nothing-to-preserve` / `not-needed:*`) or the work was
#        captured (`preserved:*`). Destroying is safe.
#   1  — preservation was NEEDED and FAILED (`capture-failed:snapshot`,
#        `capture-failed:no-commit`, `capture-failed:ref-mint`,
#        `unclassifiable:no-default-branch`). NOTHING was captured, so the
#        caller must NOT destroy. PRESERVED_DETAIL says which.
# It still never aborts the caller by itself: both call sites branch on the
# return with `if !`, which is exempt from `set -e`.
#
# COMPOSES, never re-derives. The loss window is classified by `pr.sh
# recover-probe`'s existing ladder — RECOVER_DIRTY / RECOVER_COMMITTED ARE the
# window; RECOVER_PUSHED / RECOVER_PR_OPEN need nothing because the work already
# exists off this machine — and the "already landed" test is
# `merged_detect_is_merged`, the same merge-queue-safe helper prune_one uses (a
# squash/rebase merge leaves the tip a non-ancestor even though it landed).
#
# recover-probe's failure arrives as a VALID `{"outcome":"ERROR",...}` line —
# `pr.sh` dups its real stdout onto fd 3, so a `die` reaches an external capture
# like any other outcome — so ERROR is branched on EXPLICITLY here rather than
# falling through the default arm and being read as a RECOVER_NONE-shaped
# success. Both it and an absent probe are treated as UNCLASSIFIABLE, which
# means "assume the loss window and try to capture", never "assume safe".
preserve_unlanded() {
  local repo="$1" wt_path="$2" branch="$3"
  local slug default have_wt=0 have_branch=0 probe="" outcome="" sha ref
  local dirty=0 merged="false" tip=""
  PRESERVED="false"
  PRESERVED_REF=""
  PRESERVED_DETAIL="nothing-to-preserve"

  if [ -d "$wt_path" ]; then have_wt=1; fi
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then have_branch=1; fi
  if [ "$have_wt" -eq 0 ] && [ "$have_branch" -eq 0 ]; then
    PRESERVED_DETAIL="no-occupant"
    return 0
  fi

  slug="${branch#*/}"
  case "$slug" in
    ""|*/*) slug="$(printf '%s' "$branch" | tr '/' '-')" ;;
  esac

  default="$(default_branch "$repo")" || default=""
  if [ -z "$default" ]; then
    # An occupant exists (checked above) and we cannot even classify it — so we
    # cannot claim the loss window is closed. Gate the destruction shut.
    PRESERVED_DETAIL="unclassifiable:no-default-branch"
    return 1
  fi

  if [ "$have_wt" -eq 1 ] && [ -f "$SCRIPT_DIR/pr.sh" ]; then
    probe="$(bash "$SCRIPT_DIR/pr.sh" recover-probe "$wt_path" "$branch" 2>/dev/null || true)"
    if [ -n "$probe" ]; then
      outcome="$(jq -r '.outcome // ""' <<<"$probe" 2>/dev/null || true)"
    fi
  fi

  case "$outcome" in
    RECOVER_PUSHED)  PRESERVED_DETAIL="not-needed:pushed";  return 0 ;;
    RECOVER_PR_OPEN) PRESERVED_DETAIL="not-needed:pr-open"; return 0 ;;
    RECOVER_NONE)    PRESERVED_DETAIL="nothing-to-preserve"; return 0 ;;
    RECOVER_DIRTY|RECOVER_COMMITTED) : ;;   # the loss window — fall through and capture
    ERROR)           outcome="unclassifiable-probe-error" ;;
    *)               outcome="unclassifiable-probe-absent" ;;
  esac

  # Dirtiness comes from the probe when it ran (it reports `dirty` on EVERY
  # outcome); the local fallback exists only for the unclassifiable arms.
  if [ -n "$probe" ]; then
    case "$(jq -r '.dirty // false' <<<"$probe" 2>/dev/null || true)" in
      true) dirty=1 ;;
    esac
  elif [ "$have_wt" -eq 1 ]; then
    if [ -n "$(git -C "$wt_path" status --porcelain \
                 -- ':(exclude).build-guard' ':(exclude).build-verification.md' 2>/dev/null)" ]; then
      dirty=1
    fi
  fi

  # `^{commit}` deliberately, not the bare ref: a ref that does not resolve to a
  # COMMIT cannot be preserved as one, and reading the bare object id here would
  # hand `preserve_mint_ref` a non-commit that `update-ref` then rejects — a
  # ref-mint failure standing in for what is really "there is no commit here".
  if [ "$have_branch" -eq 1 ]; then
    tip="$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null)" || tip=""
  elif [ "$have_wt" -eq 1 ]; then
    tip="$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)" || tip=""
  fi

  # Already in the merged tip => nothing can be lost. Cheap ancestor test first
  # (the ordinary case), falling through to the merge-queue-safe helper only
  # when the tip is NOT an ancestor — the squash/rebase shape.
  if [ "$dirty" -eq 0 ] && [ -n "$tip" ]; then
    if git -C "$repo" merge-base --is-ancestor "$tip" "origin/$default" 2>/dev/null; then
      merged="true"
    else
      merged="$(merged_detect_is_merged "$repo" "$branch" "$default")" || merged="false"
    fi
    if [ "$merged" = "true" ]; then
      PRESERVED_DETAIL="not-needed:merged"
      return 0
    fi
  fi

  sha=""
  if [ "$have_wt" -eq 1 ]; then
    # The worktree is the authority when it exists: its capture covers the
    # branch's commits AND the uncommitted tree. NO silent fallback to the tip —
    # that would drop the dirty half while still reporting `preserved`.
    sha="$(preserve_capture "$wt_path" 2>/dev/null)" || sha=""
    if [ -z "$sha" ]; then
      PRESERVED_DETAIL="capture-failed:snapshot outcome=$outcome"
      return 1
    fi
  else
    sha="$tip"
  fi
  if [ -z "$sha" ]; then
    PRESERVED_DETAIL="capture-failed:no-commit outcome=$outcome"
    return 1
  fi

  ref="$(preserve_mint_ref "$repo" "$slug" "$sha" 2>/dev/null)" || ref=""
  if [ -z "$ref" ]; then
    PRESERVED_DETAIL="capture-failed:ref-mint outcome=$outcome sha=$sha"
    return 1
  fi

  PRESERVED="true"
  PRESERVED_REF="$ref"
  PRESERVED_DETAIL="preserved:$outcome sha=$sha dirty=$dirty"
  printf 'worktree.sh: preserved unlanded work for %s at %s (%s)\n' \
    "$branch" "$ref" "$PRESERVED_DETAIL" >&2
  return 0
}

# --- Never destroy what preservation missed (temperloop#1730) ----------------
#
# #1699 minted the preservation ref but both destroying callers still ran
# `preserve_unlanded … || true` and then destroyed UNCONDITIONALLY, so the guard
# covered the happy path only: on `capture-failed:*` / `unclassifiable:*` the
# work went to `git worktree remove --force` + `git branch -D` with nothing
# captured. The `|| true` is gone from both call sites; each branches on the
# return, and the two DIVERGE because their constraints differ:
#
#   * `remove` (the /sweep unattended park finale) REFUSES — a leaked worktree
#     is recoverable by hand, a force-deleted branch is not. It reports
#     REMOVE_REFUSED with the verbatim `preserved_detail` plus the STILL-STANDING
#     path, and exits non-zero.
#   * `create` must NEVER refuse (a refusing create turns /build's prelude batch
#     from "created" into "escalated"), so it SIDELINES instead: the occupant is
#     MOVED ASIDE to `<path>.unpreserved-<sha8>` on branch
#     `<branch>.unpreserved-<sha8>`, which frees the deterministic path, so the
#     work survives AND create still CREATES.
SIDELINED="false"
SIDELINED_PATH=""
SIDELINED_BRANCH=""

# sideline_unpreserved <repo> <wt_path> <branch> — move the un-preservable
# occupant aside, sets SIDELINED / SIDELINED_PATH / SIDELINED_BRANCH.
#
# MOVES, never copies and never removes: `git worktree move` keeps the worktree
# REGISTERED at its new path (so `prune` still sees it — § Sidelined-worktree
# disposal), with a plain `mv` + `git worktree repair` fallback for an occupant
# git declines to move (an unregistered stale dir from a crashed run). The
# branch rename is what actually frees `refs/heads/<branch>` for the fresh
# create; without it `worktree add -b` would still collide.
#
# Returns non-zero WITHOUT having destroyed anything when it cannot claim a free
# name or the move fails. That is the ONE case create's caller cannot paper
# over, and it resolves to ERROR rather than to destruction on purpose: the only
# other way to satisfy "create never refuses" there is to delete work that
# nothing captured, which is the exact failure this whole guard exists to close.
sideline_unpreserved() {
  local repo="$1" wt_path="$2" branch="$3"
  local tok base_path new_path new_branch n=1 moved=0
  SIDELINED="false"
  SIDELINED_PATH=""
  SIDELINED_BRANCH=""

  tok="$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null)" || tok=""
  if [ -z "$tok" ] && [ -d "$wt_path" ]; then
    tok="$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)" || tok=""
  fi
  if [ -n "$tok" ]; then
    tok="${tok:0:8}"
  else
    tok="$(date -u '+%Y%m%d%H%M%S')"
  fi

  base_path="${wt_path}.unpreserved-${tok}"
  new_path="$base_path"
  new_branch="${branch}.unpreserved-${tok}"
  while [ -e "$new_path" ] || git -C "$repo" show-ref --verify --quiet "refs/heads/$new_branch"; do
    n=$((n + 1))
    [ "$n" -le 20 ] || return 1
    new_path="${base_path}-${n}"
    new_branch="${branch}.unpreserved-${tok}-${n}"
  done
  git check-ref-format "$new_branch" >/dev/null 2>&1 || return 1

  if [ -e "$wt_path" ]; then
    if git -C "$repo" worktree move "$wt_path" "$new_path" 2>/dev/null; then
      moved=1
    elif mv "$wt_path" "$new_path" 2>/dev/null; then
      git -C "$repo" worktree repair "$new_path" >/dev/null 2>&1 || true
      moved=1
    fi
    [ "$moved" -eq 1 ] || return 1
  fi

  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo" branch -m "$branch" "$new_branch" >/dev/null 2>&1 || return 1
  else
    new_branch=""
  fi

  SIDELINED="true"
  SIDELINED_PATH="$new_path"
  SIDELINED_BRANCH="$new_branch"
  printf 'worktree.sh: preservation FAILED (%s) — sidelined %s to %s instead of destroying it\n' \
    "$PRESERVED_DETAIL" "$wt_path" "$new_path" >&2
  return 0
}

# Tear down whatever occupies the deterministic path (registered worktree,
# stale dir, stale registration, stale branch) so create can always re-add.
#
# PRESERVE BEFORE DESTROY (#1699), AND NEVER DESTROY WHAT PRESERVATION MISSED
# (#1730). The preserve call below is the guard's REACHABILITY surface — the
# guarantee is that it sits inside this function's own body, not merely that the
# helper exists somewhere in the file. It carries NO `|| true`: swallowing the
# return is precisely what let the destruction below run on a failed capture.
# `if !` is the shape that keeps the caller safe under `set -e` (the test of an
# `if` is exempt) WITHOUT discarding the verdict.
clear_path() {
  local repo="$1" wt_path="$2" branch="$3"
  SIDELINED="false"
  SIDELINED_PATH=""
  SIDELINED_BRANCH=""
  if ! preserve_unlanded "$repo" "$wt_path" "$branch"; then
    sideline_unpreserved "$repo" "$wt_path" "$branch" \
      || die "preservation failed ($PRESERVED_DETAIL) and '$wt_path' could not be sidelined — refusing to destroy uncaptured work"
    # The occupant is gone from the deterministic path/branch by MOVE, so the
    # destroying block below is a no-op on this arm. Falling through rather than
    # returning keeps `worktree prune` + the stale-registration cleanup on one path.
  fi
  if [ -e "$wt_path" ]; then
    git -C "$repo" worktree remove --force "$wt_path" 2>/dev/null \
      || rm -rf "$wt_path"
  fi
  git -C "$repo" worktree prune 2>/dev/null || true
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo" branch -D "$branch" >/dev/null 2>&1 \
      || die "could not delete stale branch '$branch' (checked out elsewhere?)"
  fi
}

# --- Write-jail arming self-test (foundation#1352; the F#932 incident) -------
#
# `create` drops the `.build-guard` marker — but a marker only arms a hook that
# is actually REACHED. Every real failure of this jail has been a REACHABILITY
# failure, not a logic failure: a stale vendored hook body, a settings.json
# matcher still reading `Edit|Write|MultiEdit` (which runs the file-tool jail
# but leaves worker Bash UN-jailed — the exact F#932 shape, where a worker's
# `rm -rf "$(dirname "$(pwd)")"` resolved to ~/dev and wiped every checkout and
# the local knowledge store), a consuming repo that never registered the hook,
# a non-executable hook file, a missing `jq` on the hook's PATH. Every one of
# those exits 0 SILENTLY and is individually invisible. One probe, at the one
# moment it matters — right after arming, right before a worker is handed this
# worktree — collapses them all into a single per-run signal.
#
# Two halves, because either alone is insufficient:
#   1. REGISTRATION — a PreToolUse entry whose matcher covers `Bash` must point
#      at an EXISTING, runnable build-worktree-guard hook file. A perfectly
#      correct hook can still be unwired, and the matcher half is precisely the
#      F#932 gap.
#   2. BEHAVIOR — a synthetic deny-shaped payload is piped at THE REGISTERED
#      HOOK FILE (never at this repo's own source copy — the point is to test
#      the file the harness would actually reach, which may be a stale vendored
#      one) and the verdict asserted to be `permissionDecision:"deny"`. One
#      payload per arm.
#
# NEVER a false ARMED. Asserting safety that isn't there is strictly worse than
# reporting UNKNOWN, so every ambiguity resolves AWAY from ARMED: an
# unresolvable hook path, a hook that hangs, and a registration this probe
# cannot prove the worker actually loads (see `parent-only` below) all report
# UNKNOWN. Only an observed deny from a registration on an unambiguously-loaded
# surface earns ARMED.
#
# NOT an arbitrary-command runner. The probe extracts the HOOK FILE PATH out of
# the registration string and runs that file directly; it never `sh -c`s the
# registration text. `worktree.sh create` must not become a way for repo-tracked
# settings content to execute in the orchestrator's process, outside the very
# jail it is testing. The cost is small: a `bash <hook>` vs bare-path
# registration difference is instead checked explicitly (`hook-not-executable`).
#
# FAIL-OPEN, ALWAYS. The probe never blocks a create, and this is enforced
# rather than emergent: the call site is `|| true`, every arm is bounded by a
# wall-clock tick budget, and the bounded child is launched in its OWN PROCESS
# GROUP with fd 3 CLOSED. Both of those matter — worktree.sh holds the script's
# real stdout on fd 3 (see `exec 3>&1` above), and the orchestrator reads the
# CREATED line by capturing stdout, so a hung hook inheriting fd 3 would hold
# that capture pipe open and wedge `create` for the hook's full duration no
# matter what this tick budget said. A probe that can wedge a build is worse
# than the gap it closes (the same posture the guard family itself takes).
GUARD_STATUS="UNKNOWN"
GUARD_DETAIL="probe-not-run"

# The two synthetic payload targets. Both are only ever READ by the hook —
# never executed, never created:
#   * the Bash target is the verbatim F#932 command. Its operand is NON-LITERAL,
#     which an armed hook denies before it resolves anything — so this probe is
#     immune to the hook's /tmp//$TMPDIR allow-list and gives the same verdict
#     for a worktree in a tmpdir fixture as for one under $HOME.
#   * the Write target is a nonexistent root-level sentinel: outside every
#     worktree AND outside that allow-list, for the same reason.
# shellcheck disable=SC2016  # the $(…) is the literal incident text, not an expansion
GUARD_PROBE_BASH_CMD='rm -rf "$(dirname "$(pwd)")"'
GUARD_PROBE_WRITE_PATH='/build-worktree-guard-probe/never-written'
# Per-arm wall-clock bound, in 0.1s ticks. An internal robustness bound, not an
# operator knob: it exists only so a wedged hook cannot wedge a build. Sized
# well above the real hook's cost (which shells out to git/jq/awk per call, and
# measures ~0.2s) so a loaded runner does not produce a crying-wolf UNKNOWN —
# a banner operators learn to scroll past converts straight back into the
# silent un-armed state F#932 shipped in.
GUARD_PROBE_TICKS=100

# guard_matcher_covers_bash <matcher> — does a settings.json PreToolUse matcher
# select the Bash tool? Deliberately CONSERVATIVE, and deliberately not a
# re-implementation of the harness's regex engine: the wildcards below, or an
# exact `Bash` alternative in a `|`-separated list. A cleverer matcher that this
# says no to costs a spurious UNARMED banner; one it wrongly says yes to costs a
# false ARMED, which is the outcome this whole probe exists to prevent.
guard_matcher_covers_bash() {
  local m="$1" alt rest
  case "$m" in
    ""|"*"|".*"|"^.*$") return 0 ;;
  esac
  rest="$m"
  while [ -n "$rest" ]; do
    alt="${rest%%|*}"
    if [ "$alt" = "Bash" ]; then
      return 0
    fi
    case "$rest" in
      *"|"*) rest="${rest#*|}" ;;
      *) rest="" ;;
    esac
  done
  return 1
}

# guard_hook_file <registration-command> <wt> — pull the hook FILE out of a
# registration string and print "<bare>\t<abs-path>", where <bare> is 1 when the
# hook is invoked directly (so its exec bit is load-bearing) and 0 when it runs
# under an interpreter (`bash <hook>`). Prints nothing when no hook token can be
# resolved. Expands only the variables Claude Code itself substitutes into a
# hook command; anything still carrying a `$` is unresolvable by design.
guard_hook_file() {
  local cmd="$1" wt="$2" i=0 t
  local -a toks=()
  IFS=' ' read -r -a toks <<<"$cmd"
  while [ "$i" -lt "${#toks[@]}" ]; do
    t="${toks[$i]}"
    t="${t#[\"\']}"; t="${t%[\"\']}"   # a quoted path compares as a bare one
    case "$t" in
      *build-worktree-guard*.sh)
        t="${t//\$\{CLAUDE_PROJECT_DIR\}/$wt}"
        t="${t//\$CLAUDE_PROJECT_DIR/$wt}"
        t="${t//\$\{HOME\}/$HOME}"
        t="${t//\$HOME/$HOME}"
        # shellcheck disable=SC2088  # matching a literal ~ in the registration TEXT, not expanding one
        case "$t" in "~/"*) t="$HOME/${t#\~/}" ;; esac
        case "$t" in *'$'*|*'`'*) return 0 ;; esac   # unresolvable → no verdict
        case "$t" in /*) ;; *) t="$wt/$t" ;; esac
        if [ "$i" -eq 0 ]; then printf '1\t%s' "$t"; else printf '0\t%s' "$t"; fi
        return 0
        ;;
    esac
    i=$((i + 1))
  done
}

# guard_run_hook <hook-file> <payload> <wt> — run the REGISTERED hook file the
# way Claude Code would (cwd = the worktree, CLAUDE_PROJECT_DIR exported) and
# print its stdout. Bounded; on timeout it prints the timeout sentinel instead.
guard_run_hook() {
  local hook="$1" payload="$2" wt="$3" out pid ticks=0 timedout=0
  out="$(mktemp "${TMPDIR:-/tmp}/wt-guard-probe.XXXXXX")" || return 0
  # `set -m` puts the child in its own process group so the whole tree can be
  # signalled below; `3>&-` closes the inherited real-stdout fd so an abandoned
  # hook can never hold the caller's stdout-capture pipe open.
  set -m
  (
    cd "$wt" 2>/dev/null || exit 0
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$wt" bash "$hook" 2>/dev/null
  ) 3>&- >"$out" 2>/dev/null &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$GUARD_PROBE_TICKS" ]; then
      # Signal the GROUP, not just the subshell: the hook itself is a
      # grandchild and would otherwise be orphaned, still running. TERM first
      # so it can flush, then KILL.
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      timedout=1
      break
    fi
    ticks=$((ticks + 1))
    sleep 0.1 || true
  done
  wait "$pid" 2>/dev/null || true
  if [ "$timedout" -eq 1 ]; then
    printf '__GUARD_PROBE_TIMEOUT__' || true
  else
    cat "$out" 2>/dev/null || true
  fi
  rm -f "$out" || true
}

# guard_probe_arm <hook-file> <payload> <wt> — prints deny | allow | timeout.
# NOTE that "no output at all" is `allow`, not an error: a hook that exits 0
# silently IS the dominant silent-pass failure (missing jq, stale inert body,
# wrong file) this probe exists to catch.
guard_probe_arm() {
  local out
  out="$(guard_run_hook "$1" "$2" "$3")"
  case "$out" in
    *'__GUARD_PROBE_TIMEOUT__'*) printf 'timeout' ;;
    *'"permissionDecision":"deny"'*) printf 'deny' ;;
    *) printf 'allow' ;;
  esac
}

# guard_probe <wt_path> <repo> — sets GUARD_STATUS + GUARD_DETAIL. Never fails.
guard_probe() {
  local wt="$1" repo="$2" f matcher cmd bash_payload write_payload hookinfo
  local reg_cmd="" reg_src="" reg_matcher="" saw_any=0 saw_matcher="none"
  local bash_arm="n/a" write_arm="n/a" hook_file="" hook_bare=0 ambiguous=0
  GUARD_STATUS="UNKNOWN"
  GUARD_DETAIL="probe-error"

  # Both registration surfaces (#72), plus their .local siblings: Claude Code
  # MERGES hook entries across settings files rather than overriding, so every
  # file is scanned and the FIRST Bash-covering registration wins. The order is
  # load-bearing — unambiguously-loaded surfaces first, so the parent-checkout
  # fallback below is only ever reached when nothing better armed the jail.
  for f in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" \
           "$wt/.claude/settings.json" "$wt/.claude/settings.local.json" \
           "$repo/.claude/settings.json" "$repo/.claude/settings.local.json"; do
    [ -f "$f" ] || continue
    while IFS=$'\t' read -r matcher cmd; do
      [ -n "$cmd" ] || continue
      case "$cmd" in *build-worktree-guard*) ;; *) continue ;; esac
      matcher="${matcher#M}"   # jq prefixes every matcher so "" survives the read
      saw_any=1
      if [ "$saw_matcher" = "none" ]; then saw_matcher="${matcher:-<empty>}"; fi
      if guard_matcher_covers_bash "$matcher"; then
        if [ -z "$reg_cmd" ]; then
          reg_cmd="$cmd"; reg_src="$f"; reg_matcher="${matcher:-<empty>}"
        fi
      fi
    done < <(jq -r '
      (.hooks.PreToolUse // [])[]
      | ("M" + (.matcher // "")) as $m
      | (.hooks // [])[]
      | select((.type // "command") == "command")
      | [$m, (.command // "")] | @tsv' "$f" 2>/dev/null || true)
  done

  if [ -z "$reg_cmd" ]; then
    GUARD_STATUS="UNARMED"
    if [ "$saw_any" -eq 1 ]; then
      # The F#932 shape: the file-tool jail runs, worker Bash does not.
      GUARD_DETAIL="registration=matcher-lacks-bash matcher=$saw_matcher bash_arm=n/a write_arm=n/a"
    else
      GUARD_DETAIL="registration=missing matcher=n/a bash_arm=n/a write_arm=n/a"
    fi
    return 0
  fi

  # A project-level registration found ONLY in the parent checkout is not proof.
  # `.claude/settings.local.json` is gitignored and `.claude/settings.json` may
  # be untracked, so either can exist in the parent and be ABSENT from a fresh
  # worktree — and which project dir a spawned worker resolves settings against
  # is not something this script can observe. Probe it anyway (the hook body is
  # still worth testing) but cap the verdict at UNKNOWN rather than claim ARMED.
  case "$reg_src" in
    "$repo/.claude/"*)
      if [ ! -f "$wt/.claude/${reg_src##*/}" ]; then ambiguous=1; fi
      ;;
  esac

  hookinfo="$(guard_hook_file "$reg_cmd" "$wt")"
  IFS=$'\t' read -r hook_bare hook_file <<<"$hookinfo" || true
  if [ -z "$hookinfo" ] || [ -z "$hook_file" ]; then
    GUARD_STATUS="UNKNOWN"
    GUARD_DETAIL="registration=hook-path-unresolvable source=$reg_src matcher=$reg_matcher bash_arm=n/a write_arm=n/a"
    return 0
  fi
  if [ ! -f "$hook_file" ]; then
    GUARD_STATUS="UNARMED"
    GUARD_DETAIL="registration=hook-file-missing source=$reg_src hook=$hook_file bash_arm=n/a write_arm=n/a"
    return 0
  fi
  # A bare-path registration is exec'd by the harness, so a 100644 hook file
  # simply never runs — one of the named silent-failure modes.
  if [ "$hook_bare" = "1" ] && [ ! -x "$hook_file" ]; then
    GUARD_STATUS="UNARMED"
    GUARD_DETAIL="registration=hook-not-executable source=$reg_src hook=$hook_file bash_arm=n/a write_arm=n/a"
    return 0
  fi

  bash_payload="$(jq -cn --arg cwd "$wt" --arg c "$GUARD_PROBE_BASH_CMD" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$cwd}')" || return 0
  write_payload="$(jq -cn --arg cwd "$wt" --arg p "$GUARD_PROBE_WRITE_PATH" \
    '{tool_name:"Write", tool_input:{file_path:$p}, cwd:$cwd}')" || return 0

  bash_arm="$(guard_probe_arm "$hook_file" "$bash_payload" "$wt")"
  write_arm="$(guard_probe_arm "$hook_file" "$write_payload" "$wt")"

  if [ "$bash_arm" = "timeout" ] || [ "$write_arm" = "timeout" ]; then
    GUARD_STATUS="UNKNOWN"
  elif [ "$bash_arm" = "deny" ] && [ "$write_arm" = "deny" ]; then
    if [ "$ambiguous" -eq 1 ]; then GUARD_STATUS="UNKNOWN"; else GUARD_STATUS="ARMED"; fi
  else
    GUARD_STATUS="UNARMED"
  fi
  if [ "$ambiguous" -eq 1 ]; then
    GUARD_DETAIL="registration=parent-only source=$reg_src matcher=$reg_matcher bash_arm=$bash_arm write_arm=$write_arm"
  else
    GUARD_DETAIL="registration=ok source=$reg_src matcher=$reg_matcher bash_arm=$bash_arm write_arm=$write_arm"
  fi
}

# guard_report <wt_path> <repo> — surface the verdict in the run output. ARMED
# is one quiet line; anything else is a LOUD banner, because a silently
# un-armed jail is exactly the state F#932 shipped in.
guard_report() {
  local wt="$1" repo="$2"
  if [ "$GUARD_STATUS" = "ARMED" ]; then
    printf 'build-worktree-guard: ARMED for %s (%s)\n' "$wt" "$GUARD_DETAIL" >&2
    return 0
  fi
  {
    printf '\n'
    printf '!! ==========================================================================\n'
    printf '!! WRITE-JAIL %s — %s\n' "$GUARD_STATUS" "$wt"
    printf '!! probe: %s\n' "$GUARD_DETAIL"
    printf '!!\n'
    printf '!! A worker handed this worktree may NOT be structurally prevented from\n'
    printf '!! writing or DELETING outside it. This is the F#932 state: a worker ran\n'
    printf '!!   %s\n' "$GUARD_PROBE_BASH_CMD"
    printf '!! which resolved to a parent directory and wiped every checkout under it.\n'
    printf '!!\n'
    printf '!! The build CONTINUES (this probe fails open). To arm the jail, register\n'
    printf '!! claude/hooks/build-worktree-guard.sh as a PreToolUse hook in either:\n'
    printf '!!   user-global    %s\n' "$HOME/.claude/settings.json"
    printf '!!   consuming repo %s\n' "$repo/.claude/settings.json"
    printf '!! and make sure its matcher includes Bash — an Edit|Write|MultiEdit matcher\n'
    printf '!! runs the file-tool jail but leaves worker Bash un-jailed.\n'
    case "$GUARD_DETAIL" in
      *registration=parent-only*)
        printf '!!\n'
        printf '!! parent-only: the registration was found ONLY in the parent checkout,\n'
        printf '!! in a file this worktree does not carry (untracked or gitignored), so\n'
        printf '!! it cannot be proven to apply to a worker running here. TRACK\n'
        printf '!! .claude/settings.json in the repo, or register it user-global.\n'
        ;;
    esac
    printf '!! ==========================================================================\n'
    printf '\n'
  } >&2
}

# create_rollback <repo> <wt-path> <branch> <base> — undo a FAILED
# `git worktree add` (#1171), so the ERROR outcome leaves no durable state.
#
# `worktree add` is not atomic: on the observed config-lock loss it has already
# created `build/<slug>` when it fails, leaving an orphan branch that a later
# run (or an operator) has to `git branch -D` by hand.
#
# Conservative by construction, in the same posture as § Never destroy what
# preservation missed: the branch is deleted ONLY when its tip is still exactly
# the base we asked for — i.e. it provably carries no commits. Anything else is
# left standing and reported, because this helper runs microseconds after the
# branch was minted and a diverged tip would mean something we do not
# understand happened. Returns non-zero when it could not fully roll back.
create_rollback() {
  local repo="$1" wt_path="$2" branch="$3" base="$4" tip base_tip
  if [ -e "$wt_path" ]; then
    git -C "$repo" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"
  fi
  git -C "$repo" worktree prune 2>/dev/null || true
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || return 0
  tip="$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)" || tip=""
  base_tip="$(git -C "$repo" rev-parse --verify --quiet "$base" 2>/dev/null)" || base_tip=""
  if [ -z "$tip" ] || [ -z "$base_tip" ] || [ "$tip" != "$base_tip" ]; then
    return 1
  fi
  git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || return 1
  return 0
}

# create_core <repo-root> <slug> — everything `create` does EXCEPT emit its
# outcome line, so `restore` can stand a fresh worktree up on the same
# deterministic path/branch/base without a second CREATED line on stdout
# (the orchestrator branches on one JSON line per invocation). Sets
# CREATE_PATH / CREATE_BRANCH / CREATE_BASE for whichever command emits.
CREATE_PATH=""
CREATE_BRANCH=""
CREATE_BASE=""
create_core() {
  local repo slug wt_path branch default out
  repo="$(resolve_repo "$1")"
  slug="$2"
  validate_slug "$slug"
  wt_path="${repo}.wt/${slug}"
  branch="build/${slug}"
  default="$(default_branch "$repo")" || die "cannot resolve origin's default branch in '$repo'"
  CREATE_PATH="$wt_path"
  CREATE_BRANCH="$branch"
  CREATE_BASE="origin/$default"

  # Everything from here to the CREATED-side bookkeeping below mutates SHARED
  # repo state — `.git/config` (the branch-delete in clear_path, the upstream
  # write inside `worktree add`), the ref store, and info/exclude — so it runs
  # under the repo's mutation lock (§ Repo-wide mutation lock). Concurrent
  # creates in one /build level now QUEUE here instead of colliding on
  # `.git/config.lock` (#1171).
  wt_lock_acquire "$repo" \
    || die "timed out waiting for the repo mutation lock (another worktree.sh is holding '$WT_LOCK_DIR'); see WORKTREE_LOCK_WAIT_TICKS"

  # The path is a pure function of the slug — anything already there is debris
  # from an aborted run; force-remove and re-add.
  clear_path "$repo" "$wt_path" "$branch"

  # Freshen the base before branching off it. `worktree add` bases the new branch
  # on the LOCAL origin/<default> ref, which goes stale between runs — branching
  # off a stale base silently builds the item on an old main (two stale-base
  # incidents in the workflow-evals run, #337). Best-effort, mirroring cmd_prune:
  # offline (tests/planes) is fine — the local ref is then the conservative basis.
  git -C "$repo" fetch --quiet origin "$default" 2>/dev/null || true

  mkdir -p "${repo}.wt"
  # § Atomic create failure (#1171). A failed `worktree add` is NOT a no-op: the
  # observed config-lock loss creates `build/<slug>` and THEN fails, so a bare
  # `die` here leaves an orphan branch behind — durable state from an ERROR
  # outcome, which the closed-outcome contract above does not admit. Roll the
  # branch (and any half-registered path) back before reporting, so ERROR means
  # "nothing happened" and a naive retry is a clean create rather than a
  # `branch already exists`. The lock makes the retry-worthy case rare; a
  # FOREIGN config writer (an operator's `git config`, another tool) is outside
  # our lock, so a bounded in-process retry rides along for that case.
  local attempt=1 rollback_note=""
  while :; do
    if out="$(git -C "$repo" worktree add -b "$branch" "$wt_path" "origin/$default" 2>&1)"; then
      break
    fi
    rollback_note=""
    create_rollback "$repo" "$wt_path" "$branch" "origin/$default" \
      || rollback_note=" (rollback incomplete: branch '$branch' left in place — it carries commits)"
    case "$out" in
      *"could not lock config file"*)
        if [ "$attempt" -lt "${WORKTREE_ADD_ATTEMPTS:-3}" ]; then
          attempt=$((attempt + 1))
          sleep 0.2
          continue
        fi
        ;;
    esac
    wt_lock_release
    die "git worktree add failed: $out$rollback_note"
  done

  # Drop the guard marker — this is what arms the PreToolUse write-jail for
  # any worker running in this worktree (per-worktree, concurrency-safe).
  jq -cn --arg slug "$slug" --arg branch "$branch" --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{slug:$slug, branch:$branch, created:$created}' > "$wt_path/.build-guard"
  exclude_marker "$repo"

  # End of the shared-state region. Everything below touches only THIS
  # worktree, so it must not hold the lock — the guard probe alone can burn the
  # better part of a second, and serializing it across a fanout buys nothing.
  wt_lock_release

  # Make the review lenses resolvable to the worker that will run here (#1005).
  # `|| true` for the same reason guard_probe carries one: a future edit that
  # leaves this returning non-zero must never abort cmd_create under `set -e`
  # and suppress the CREATED line.
  materialize_agents "$wt_path" || true

  # PROVE the jail is armed before this worktree is handed to a worker — the
  # marker is now in place, so the hook (if it is reached at all) must deny.
  # `|| true` is load-bearing, not decorative: without it a future edit that
  # leaves guard_probe returning non-zero would abort cmd_create mid-flight
  # under `set -e` and suppress the CREATED line entirely — a broken output
  # contract rather than a degraded verdict. Fail-open, enforced not emergent.
  guard_probe "$wt_path" "$repo" || true
  guard_report "$wt_path" "$repo" || true

  # Self-heal (#529): the verification-surface artifact must stay a dev-local,
  # uncommitted file — exclude_marker handles that for UNtracked files, but
  # info/exclude is powerless against a file that was committed before the exclude
  # existed. In consuming repos where `.build-verification.md` is tracked, every
  # item re-commits its own copy, so a multi-item level's serial-merge hits a
  # content conflict on it. Untrack it here as its OWN commit (keeps the worker's
  # feature diff clean); all branches at a level make the identical removal, which
  # merges delete-vs-delete cleanly, and once the repo's main is clean this is a
  # no-op. Targets only the surface artifact — .build-guard is never committed
  # (jq-written above + excluded). The guard hook gates the worker's Edit/Write,
  # not machinery git ops, so it does not interfere.
  git -C "$wt_path" rm -q --cached --ignore-unmatch .build-verification.md 2>/dev/null || true
  if ! git -C "$wt_path" diff --cached --quiet; then
    git -C "$wt_path" commit -q \
      -m "chore: untrack dev-local build-verification artifact (#529)" \
      -m "info/exclude can't untrack an already-committed file; do it once here so /build serial-merge stops conflicting on it." \
      || die "self-heal untrack-commit failed in '$wt_path'"
  fi

}

cmd_create() {
  create_core "$1" "$2"
  jq -cn --arg path "$CREATE_PATH" --arg branch "$CREATE_BRANCH" --arg base "$CREATE_BASE" \
         --arg guard "$GUARD_STATUS" --arg guard_detail "$GUARD_DETAIL" \
         --argjson preserved "$PRESERVED" --arg preserved_ref "$PRESERVED_REF" \
         --arg preserved_detail "$PRESERVED_DETAIL" \
         --argjson sidelined "$SIDELINED" --arg sidelined_path "$SIDELINED_PATH" \
         --arg sidelined_branch "$SIDELINED_BRANCH" \
    '{outcome:"CREATED", path:$path, branch:$branch, base:$base,
      guard:$guard, guard_detail:$guard_detail,
      preserved:$preserved, preserved_ref:$preserved_ref,
      preserved_detail:$preserved_detail,
      sidelined:$sidelined, sidelined_path:$sidelined_path,
      sidelined_branch:$sidelined_branch}'
}

# --- restore: re-apply a preservation ref into a fresh worktree (#1699) -------
#
# NEVER ASSUMES A FAST-FORWARD. The escalation window is exactly the window in
# which `origin/<default>` advances (an operator answers a question, a sibling
# item merges), so by the time the re-drive stands a fresh worktree up on the
# NEW base, the preserved commit's base is an ancestor of neither. The prose
# this replaces asserted the fast-forward "always applies"; measured inside
# #1699's own development it was FALSE (`origin/main` f0c14fd vs. the preserved
# commit's base 30f7143), and the work survived only because an agent silently
# deviated from the instruction and happened to deviate correctly. A diverged
# base is therefore a SUPPORTED, TESTED case here, not an edge.
#
# A CONFLICT IS A NAMED RESULT, never a silent partial merge: the merge is
# aborted so the worktree is left clean on the fresh base, the conflicted paths
# are reported, and the preservation ref is left INTACT so nothing is lost and
# the operator can resolve by hand against a ref that still exists.
cmd_restore() {
  local repo slug ref="" wt_path branch sha strategy out conflicts conflicts_json
  repo="$(resolve_repo "$1")"; shift
  slug="$1"; shift
  validate_slug "$slug"
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref)
        [ $# -ge 2 ] || die "--ref requires a ref name"
        ref="$2"
        shift
        shift
        ;;
      *) usage ;;
    esac
  done

  if [ -z "$ref" ]; then
    # Newest first — a slug may carry several snapshots across re-drives.
    ref="$(git -C "$repo" for-each-ref --sort=-committerdate --count=1 \
             --format='%(refname)' "$PARKED_REF_NS/${slug}-*" 2>/dev/null || true)"
  else
    case "$ref" in
      "$PARKED_REF_NS/"*) ;;
      *) die "--ref '$ref' is not under $PARKED_REF_NS (a preservation ref is local-only and never a branch)" ;;
    esac
  fi
  sha=""
  if [ -n "$ref" ]; then
    sha="$(git -C "$repo" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)" || sha=""
  fi
  if [ -z "$sha" ]; then
    jq -cn --arg slug "$slug" --arg ref "$ref" \
      '{outcome:"RESTORE_NOT_FOUND", slug:$slug, ref:$ref}'
    return 0
  fi

  create_core "$repo" "$slug"
  wt_path="$CREATE_PATH"
  branch="$CREATE_BRANCH"

  if git -C "$wt_path" merge-base --is-ancestor HEAD "$sha" 2>/dev/null; then
    if ! out="$(git -C "$wt_path" merge --ff-only "$sha" 2>&1)"; then
      die "restore fast-forward onto '$branch' failed: $out"
    fi
    strategy="fast-forward"
  else
    preserve_set_ident "$wt_path"
    if out="$(git -C "$wt_path" "${PRESERVE_IDENT[@]}" merge --no-ff --no-edit \
                -m "restore: re-apply preserved work from $ref (#1699)" "$sha" 2>&1)"; then
      strategy="merge"
    else
      conflicts="$(git -C "$wt_path" diff --name-only --diff-filter=U 2>/dev/null || true)"
      git -C "$wt_path" merge --abort 2>/dev/null || git -C "$wt_path" reset -q --hard 2>/dev/null || true
      conflicts_json='[]'
      if [ -n "$conflicts" ]; then
        conflicts_json="$(printf '%s\n' "$conflicts" | jq -R . | jq -cs .)"
      fi
      jq -cn --arg path "$wt_path" --arg branch "$branch" --arg base "$CREATE_BASE" \
             --arg ref "$ref" --arg sha "$sha" --argjson conflicts "$conflicts_json" \
             --arg error "$out" \
        '{outcome:"RESTORE_CONFLICT", path:$path, branch:$branch, base:$base,
          ref:$ref, sha:$sha, conflicts:$conflicts, aborted:true, error:$error}'
      return 0
    fi
  fi

  jq -cn --arg path "$wt_path" --arg branch "$branch" --arg base "$CREATE_BASE" \
         --arg ref "$ref" --arg sha "$sha" --arg strategy "$strategy" \
         --arg guard "$GUARD_STATUS" --arg guard_detail "$GUARD_DETAIL" \
    '{outcome:"RESTORED", path:$path, branch:$branch, base:$base,
      ref:$ref, sha:$sha, strategy:$strategy,
      guard:$guard, guard_detail:$guard_detail}'
}

cmd_remove() {
  local repo slug wt_path branch existed=0 out
  repo="$(resolve_repo "$1")"
  slug="$2"
  validate_slug "$slug"
  wt_path="${repo}.wt/${slug}"
  branch="build/${slug}"

  # `remove` is the OTHER destroying path — the one `/sweep`'s unattended
  # PARK-AND-CONTINUE finale reaches (temperloop#1725, absorbed into #1699). It
  # does not route through clear_path, so it takes the same guard directly;
  # a /sweep-originated preservation ref is minted HERE.
  #
  # AND, unlike `create`, it REFUSES when that guard came back empty-handed
  # (#1730). No `|| true`: on a `capture-failed:*` / `unclassifiable:*` verdict
  # nothing was captured, and `remove`'s asymmetry is the whole reason the two
  # callers diverge — a worktree this leaves standing is recoverable by hand
  # (its own `prune` reclaims it once the work lands or the issue closes), while
  # the `git branch -D` below is not. Refuse loudly, destroy nothing, and let
  # the caller see a non-zero exit rather than a silent false REMOVED.
  if ! preserve_unlanded "$repo" "$wt_path" "$branch"; then
    jq -cn --arg path "$wt_path" --arg branch "$branch" \
           --argjson preserved "$PRESERVED" --arg preserved_ref "$PRESERVED_REF" \
           --arg preserved_detail "$PRESERVED_DETAIL" \
      '{outcome:"REMOVE_REFUSED", path:$path, branch:$branch,
        preserved:$preserved, preserved_ref:$preserved_ref,
        preserved_detail:$preserved_detail}'
    printf 'worktree.sh: REFUSING to remove %s — preservation failed (%s); worktree and branch %s left INTACT\n' \
      "$wt_path" "$PRESERVED_DETAIL" "$branch" >&2
    exit 1
  fi

  # Same shared-state region as create's (#1171): `git branch -D` rewrites
  # `.git/config`, so a remove concurrent with a create would hit the identical
  # `could not lock config file` loss. A lock only one side takes is not a lock.
  wt_lock_acquire "$repo" \
    || die "timed out waiting for the repo mutation lock (another worktree.sh is holding '$WT_LOCK_DIR'); see WORKTREE_LOCK_WAIT_TICKS"
  if [ -e "$wt_path" ]; then
    existed=1
    rm -f "$wt_path/.build-guard"
    git -C "$repo" worktree remove --force "$wt_path" 2>/dev/null \
      || rm -rf "$wt_path"
  fi
  git -C "$repo" worktree prune 2>/dev/null || true
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    existed=1
    if ! out="$(git -C "$repo" branch -D "$branch" 2>&1)"; then
      die "git branch -D $branch failed: $out"
    fi
  fi
  wt_lock_release

  local oc="NOT_FOUND"
  if [ "$existed" -eq 1 ]; then oc="REMOVED"; fi
  jq -cn --arg outcome "$oc" --arg path "$wt_path" --arg branch "$branch" \
         --argjson preserved "$PRESERVED" --arg preserved_ref "$PRESERVED_REF" \
         --arg preserved_detail "$PRESERVED_DETAIL" \
    '{outcome:$outcome, path:$path, branch:$branch,
      preserved:$preserved, preserved_ref:$preserved_ref,
      preserved_detail:$preserved_detail}'
}

cmd_prune() {
  local repo force="$1" default prefix line wt_path branch
  repo="$(resolve_repo "$2")"
  default="$(default_branch "$repo")" || die "cannot resolve origin's default branch in '$repo'"
  # Best-effort freshen of the merge target; offline (tests, planes) is fine —
  # the local origin/<default> is then the basis, which is conservative.
  git -C "$repo" fetch --quiet origin "$default" 2>/dev/null || true
  git -C "$repo" worktree prune 2>/dev/null || true

  prefix="${repo}.wt/"
  wt_path=""
  branch=""
  # `git worktree list --porcelain` blocks: worktree <path> / HEAD … / branch …
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wt_path="${line#worktree }"
        branch=""
        ;;
      "branch refs/heads/"*)
        branch="${line#branch refs/heads/}"
        ;;
      "")
        case "$wt_path" in
          "$prefix"*)
            # A sidelined worktree is NOT ordinary debris — it holds work no
            # preservation captured, so it takes its own conservative disposal
            # owner rather than prune_one's merged/dirty/fresh gates (and, like
            # a preservation ref, `--force` deliberately does not reach it).
            case "${wt_path##*/}" in
              *.unpreserved-*) prune_sidelined_wt "$repo" "$wt_path" "$branch" "$default" ;;
              *)               prune_one "$repo" "$wt_path" "$branch" "$default" "$force" ;;
            esac
            ;;
        esac
        wt_path=""
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain; echo)

  # The named reap owner for the #1699 preservation refs. Same sweep, same
  # conservative posture as the worktree gates above.
  prune_parked_refs "$repo" "$default"
}

# _worktree_gh — the gh override seam, mirroring _merged_detect_gh / _board_gh:
# tests stand a stub on PATH rather than reaching the network, and every call is
# attributed so it stops landing in the call-logger's `unattributed` bucket.
_worktree_gh() {
  # GH_CALL_OP is a per-call attribution tag, not a static operator default.
  GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-worktree}" GH_CALL_OP="${GH_CALL_OP:-parked-ref-reap}" gh "$@"  # setting:exempt — per-call attribution tag, not a static operator default
}

# --- The preservation ref's named reap owner (temperloop#1699) ----------------
#
# A preservation ref is minted by the destroying primitives above and must not
# leak forever, so `prune` owns its disposal. TWO gates, either of which
# authorizes a reap:
#
#   1. ANCESTRY — the preserved commit is an ancestor of origin/<default>. This
#      is PROOF the work reached the merged tip: nothing can be lost by deleting
#      a ref whose content is already in the default branch.
#   2. DISPOSITION — the originating issue (the slug's trailing `-<issue#>`)
#      reached a terminal state (CLOSED).
#
# Both gates are needed, not one: a /sweep-originated ref is preserved at PARK
# and is never restored in place, so its commit never reaches the merged tip and
# the ancestry gate ALONE can never fire for it — the disposition gate is what
# eventually reaps it. Conversely a /fix restore-and-merge lands the work, so
# ancestry fires there without waiting on issue bookkeeping.
#
# An UNEVALUABLE check is FALSE — do not delete. No issue number in the slug, no
# `gh`, an unauthenticated/offline/rate-limited `gh`, an unrecognized state: all
# leave the disposition gate shut, exactly as merged-detect.sh's Method-3
# fail-open leaves the ancestry side. The consequence of a wrong FALSE is one
# extra ref reported next sweep; the consequence of a wrong TRUE is destroyed
# work. An OPEN issue is therefore never reaped on the disposition gate.
#
# READ-ONLY on failure and never fatal: a ref this cannot dispose is REPORTED
# (`PARKED_REF`), never silently dropped. The outcome strings are deliberately
# distinct from `PRUNED` — deploy-mini.sh counts `"outcome":"PRUNED"` lines, and
# a parked-ref line must never inflate that count.
prune_parked_refs() {
  local repo="$1" default="$2"
  local ref sha slug issue landed terminal issue_state state reason
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    sha="$(git -C "$repo" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)" || sha=""
    [ -n "$sha" ] || continue
    slug="$(parked_ref_slug "$ref")"
    issue="$(parked_ref_issue "$slug")"

    landed=false
    if git -C "$repo" merge-base --is-ancestor "$sha" "origin/$default" 2>/dev/null; then
      landed=true
    fi

    issue_state="unknown"
    terminal=false
    if [ -n "$issue" ] && command -v gh >/dev/null 2>&1; then
      state="$(cd "$repo" && _worktree_gh issue view "$issue" --json state --jq .state 2>/dev/null)" || state=""
      case "$state" in
        CLOSED) issue_state="closed"; terminal=true ;;
        OPEN)   issue_state="open" ;;
      esac
    fi

    reason="held:unlanded issue=${issue_state}"
    if [ "$landed" = true ] || [ "$terminal" = true ]; then
      if [ "$landed" = true ]; then reason="reaped:ancestor-of-merged-tip"; else reason="reaped:issue-terminal"; fi
      if git -C "$repo" update-ref -d "$ref" "$sha" 2>/dev/null; then
        jq -cn --arg ref "$ref" --arg sha "$sha" --arg slug "$slug" --arg issue "$issue" \
               --arg issue_state "$issue_state" --argjson landed "$landed" --arg reason "$reason" \
          '{outcome:"PARKED_REF_REAPED", ref:$ref, sha:$sha, slug:$slug, issue:$issue,
            issue_state:$issue_state, landed:$landed, reason:$reason}'
        continue
      fi
      reason="held:reap-failed"
    fi
    jq -cn --arg ref "$ref" --arg sha "$sha" --arg slug "$slug" --arg issue "$issue" \
           --arg issue_state "$issue_state" --argjson landed "$landed" --arg reason "$reason" \
      '{outcome:"PARKED_REF", ref:$ref, sha:$sha, slug:$slug, issue:$issue,
        issue_state:$issue_state, landed:$landed, reason:$reason}'
  done < <(git -C "$repo" for-each-ref --format='%(refname)' "$PARKED_REF_NS/*" 2>/dev/null || true)
}

# --- The sidelined worktree's named disposal owner (temperloop#1730) ---------
#
# `create`'s sideline moves an un-preservable occupant to
# `<repo>.wt/<slug>.unpreserved-<sha8>` rather than destroying it, so `prune`
# owns its eventual disposal exactly as it owns a preservation ref's. It is the
# SAME two-gate contract as prune_parked_refs — deliberately, because both hold
# the same thing (work that exists only on this machine):
#
#   1. ANCESTRY — the sidelined HEAD is an ancestor of origin/<default>, i.e.
#      the work reached the merged tip. A DIRTY sidelined tree can never pass
#      this gate: ancestry of HEAD says nothing about uncommitted changes.
#   2. DISPOSITION — the originating issue (the slug's trailing `-<issue#>`)
#      reached a terminal state (CLOSED).
#
# An UNEVALUABLE check is FALSE — no issue number in the slug, no `gh`, an
# offline/unauthenticated/rate-limited `gh`, an unrecognized state all leave the
# gate shut, and an OPEN issue is never reaped. The cost of a wrong FALSE is one
# extra reported line next sweep; the cost of a wrong TRUE is destroyed work.
# `--force` is NOT plumbed in here on purpose: it exists to override the
# dirty/fresh heuristics on ordinary debris, and this path is not heuristic.
#
# The outcome strings are distinct from `PRUNED` for the same reason the
# parked-ref ones are: deploy-mini.sh counts `"outcome":"PRUNED"` lines.
prune_sidelined_wt() {
  local repo="$1" wt_path="$2" branch="$3" default="$4"
  local slug issue head landed=false dirty=0 issue_state="unknown" terminal=false state reason
  slug="$(sidelined_wt_slug "$wt_path")"
  issue="$(parked_ref_issue "$slug")"

  head="$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)" || head=""
  if [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]; then dirty=1; fi
  if [ "$dirty" -eq 0 ] && [ -n "$head" ] \
     && git -C "$repo" merge-base --is-ancestor "$head" "origin/$default" 2>/dev/null; then
    landed=true
  fi

  if [ -n "$issue" ] && command -v gh >/dev/null 2>&1; then
    state="$(cd "$repo" && _worktree_gh issue view "$issue" --json state --jq .state 2>/dev/null)" || state=""
    case "$state" in
      CLOSED) issue_state="closed"; terminal=true ;;
      OPEN)   issue_state="open" ;;
    esac
  fi

  reason="held:unpreserved issue=${issue_state} dirty=${dirty}"
  if [ "$landed" = true ] || [ "$terminal" = true ]; then
    if [ "$landed" = true ]; then reason="reaped:ancestor-of-merged-tip"; else reason="reaped:issue-terminal"; fi
    rm -f "$wt_path/.build-guard"
    git -C "$repo" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"
    git -C "$repo" worktree prune 2>/dev/null || true
    if [ ! -e "$wt_path" ]; then
      if [ -n "$branch" ]; then
        git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
      fi
      jq -cn --arg path "$wt_path" --arg branch "$branch" --arg slug "$slug" --arg issue "$issue" \
             --arg issue_state "$issue_state" --argjson landed "$landed" --arg reason "$reason" \
        '{outcome:"SIDELINED_WT_REAPED", path:$path, branch:$branch, slug:$slug, issue:$issue,
          issue_state:$issue_state, landed:$landed, reason:$reason}'
      return 0
    fi
    reason="held:reap-failed"
  fi
  jq -cn --arg path "$wt_path" --arg branch "$branch" --arg slug "$slug" --arg issue "$issue" \
         --arg issue_state "$issue_state" --argjson landed "$landed" --arg reason "$reason" \
    '{outcome:"SIDELINED_WT", path:$path, branch:$branch, slug:$slug, issue:$issue,
      issue_state:$issue_state, landed:$landed, reason:$reason}'
}

prune_one() {
  local repo="$1" wt_path="$2" branch="$3" default="$4" force="$5" head merged
  local base_tip head_is_base="false"
  head="$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)" || head=""

  # Conservative gate 1: only a branch whose PR actually merged is removable —
  # an unmerged worktree holds unlanded work, --force or not. Try the cheap,
  # network-free ancestor test first (covers the ordinary case); only fall
  # through to the merge-queue-safe helper (#171) when the tip is NOT an
  # ancestor — the squash/rebase-merge case the ancestor-only test misreads as
  # unmerged. Never weakens the floor: a genuinely-unmerged branch still fails
  # both checks and reports SKIPPED_UNMERGED.
  if [ -z "$head" ]; then
    merged="false"
  elif git -C "$repo" merge-base --is-ancestor "$head" "origin/$default" 2>/dev/null; then
    merged="true"
    # …but ZERO COMMITS AHEAD is evidence of NO WORK YET, not of a merge
    # (#891). `create` bases the new branch on origin/<default>, so from
    # `create` until the worker's first commit a LIVE build worktree is
    # ancestor-identical to a finished, merged one — and a concurrent prune
    # from another session (prune is host-wide, not scoped to its caller's own
    # worktrees) force-removed the directory and deleted build/<slug> out from
    # under a running worker. A genuinely merged branch has commits of its own
    # that are ancestors of origin/<default>, so its tip is NOT equal to it;
    # `head == origin/<default>` cleanly separates "did work, then merged" from
    # "has not started". Stateless — no marker file or timestamp heuristic
    # (.build-guard is present in a live AND an abandoned worktree, so it does
    # not discriminate; the commit test does).
    base_tip="$(git -C "$repo" rev-parse "origin/$default" 2>/dev/null)" || base_tip=""
    if [ -n "$base_tip" ] && [ "$head" = "$base_tip" ]; then
      head_is_base="true"
    fi
  else
    # `|| merged="false"` guards the caller-misuse return (2, e.g. an empty
    # branch name for a detached-HEAD worktree) from tripping `set -e` — the
    # safe default either way is NOT merged, never an abort mid-sweep.
    merged="$(merged_detect_is_merged "$repo" "$branch" "$default")" || merged="false"
  fi
  if [ "$merged" != "true" ]; then
    jq -cn --arg path "$wt_path" --arg branch "$branch" '{outcome:"SKIPPED_UNMERGED", path:$path, branch:$branch}'
    return 0
  fi
  # Conservative gate 1b (#891): a zero-commit worktree is spared on the
  # DEFAULT path only. --force bypasses it exactly as it bypasses the dirty
  # gate below, because an aborted `worktree.sh create` leaves a legitimate
  # zero-commit worktree that must stay reapable — the guard protects the
  # default path without making stale fresh worktrees immortal.
  if [ "$head_is_base" = "true" ] && [ -z "$force" ]; then
    jq -cn --arg path "$wt_path" --arg branch "$branch" '{outcome:"SKIPPED_FRESH", path:$path, branch:$branch}'
    return 0
  fi
  # Conservative gate 2: never touch uncommitted changes unless --force (the
  # guard marker is excluded via info/exclude, so it never reads as dirt).
  if [ -z "$force" ] && [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]; then
    jq -cn --arg path "$wt_path" --arg branch "$branch" '{outcome:"SKIPPED_DIRTY", path:$path, branch:$branch}'
    return 0
  fi

  # The destroying block only — never the gh-backed merged-detection above it
  # (#1171: hold the repo mutation lock across the config-writing branch delete,
  # not across a network call).
  wt_lock_acquire "$repo" \
    || die "timed out waiting for the repo mutation lock (another worktree.sh is holding '$WT_LOCK_DIR'); see WORKTREE_LOCK_WAIT_TICKS"
  rm -f "$wt_path/.build-guard"
  git -C "$repo" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"
  git -C "$repo" worktree prune 2>/dev/null || true
  case "$branch" in
    build/*)
      git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
      ;;
  esac
  wt_lock_release
  jq -cn --arg path "$wt_path" --arg branch "$branch" '{outcome:"PRUNED", path:$path, branch:$branch}'
}

# deps-merged — the dep-merge precondition gate for /build's 3b-0 (#108). Given a
# comma-separated list of commit SHAs (each the merged head of a `depends-on`
# target), report whether EVERY one is already an ancestor of origin/<default> —
# i.e. the depended-on PR has landed in the default branch. worktree.sh create
# bases a new item's branch on origin/<default>; gating create on this means the
# worker builds and self-verifies against MERGED dependency code, not a pre-merge
# base. An unknown/unfetched SHA (git errors) counts as UNMERGED (conservative).
cmd_deps_merged() {
  local repo default shas_csv sha
  repo="$(resolve_repo "$1")"
  shas_csv="$2"
  [ -n "$shas_csv" ] || die "deps-merged requires a non-empty comma-separated SHA list"
  default="$(default_branch "$repo")" || die "cannot resolve origin's default branch in '$repo'"
  # Freshen the merge target before the ancestry test — mirrors cmd_create /
  # cmd_prune. Offline (tests/planes) is fine: the local origin/<default> is then
  # the conservative basis (a not-yet-fetched merge simply reads as unmerged).
  git -C "$repo" fetch --quiet origin "$default" 2>/dev/null || true

  local unmerged=()
  local IFS=','
  for sha in $shas_csv; do
    [ -n "$sha" ] || continue
    if ! git -C "$repo" merge-base --is-ancestor "$sha" "origin/$default" 2>/dev/null; then
      unmerged+=("$sha")
    fi
  done

  if [ "${#unmerged[@]}" -eq 0 ]; then
    jq -cn '{outcome:"DEPS_MERGED"}'
  else
    printf '%s\n' "${unmerged[@]}" | jq -R . | jq -cs '{outcome:"DEPS_UNMERGED", unmerged:.}'
  fi
}

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  create)
    [ $# -eq 2 ] || usage
    cmd_create "$1" "$2"
    ;;
  restore)
    [ $# -ge 2 ] || usage
    cmd_restore "$@"
    ;;
  remove)
    [ $# -eq 2 ] || usage
    cmd_remove "$1" "$2"
    ;;
  deps-merged)
    [ $# -eq 2 ] || usage
    cmd_deps_merged "$1" "$2"
    ;;
  prune)
    [ $# -ge 1 ] || usage
    repo_arg="$1"; shift
    force=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) force=1 ;;
        *) usage ;;
      esac
      shift
    done
    cmd_prune "$force" "$repo_arg"
    ;;
  *) usage ;;
esac
