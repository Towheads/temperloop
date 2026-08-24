#!/usr/bin/env bash
#
# build push + PR-open mechanics — the deterministic-machinery script that owns
# the 3f steps of /build (epic #253, spike #245): the closing-keyword
# pre-push scan, the speculative base-currency check, push-by-SHA, and PR-body
# assembly from the worker verdict JSON + plan fields. A step moved here iff
# its behavior is a pure function of observable machine state with a closed
# outcome set; the judgment-shaped halves (rewording an offending commit, the
# BASE_STALE rebase/conflict handling, branch-collision triage) stay
# orchestrator-driven in build.md and branch on these outcomes.
#
#   pr.sh scan <worktreePath>                  # closing-keyword pre-push scan
#   pr.sh base-check <worktreePath>            # speculative base-currency check
#   pr.sh rebase <worktreePath>                # rebase onto fresh origin/<default>
#   pr.sh push <worktreePath> <branch> [--force]   # push HEAD by SHA
#   pr.sh recover-probe <worktreePath> <branch>    # 3c lost-return side-effect probe
#   pr.sh open --verdict <file|-> [--gh-issue N] [--also-closes N,N,...]
#         [--plan-link <target>] [--source <ref>] [--verification-surface-file <path>] \
#         ( --body-only | --repo <repo-root> --branch <b> --title <t> )
#   pr.sh acceptance-extract <bodyFile|->     # inverse of the ## Acceptance recap
#
# `open` assembles the PR body from the worker's verdict JSON (summary,
# acceptance_results — the 3d return contract) plus the plan fields, then runs
# `gh pr create`. The ## Verification section's body is resolved by precedence
# (the #418 inflow-cut): --verification-surface-file <path> if given, else the
# verdict's `.verification_surface_path` (a file the worker wrote in its
# worktree and returned only the path to), else the inline `.verification_surface`
# field (back-compat), else the acceptance recap. Reading the surface from a
# file keeps that large block OUT of the orchestrator's context — it never
# round-trips through the verdict JSON. Issue linkage lives HERE and only
# here: one bare `Closes #N` line per gh_issue/also_closes entry, each on its
# own line, never combined, never backticked (GitHub silently ignores
# backticked keywords, and `Closes #1 and #2` closes only #1). Either flag
# also accepts a fully-qualified `owner/repo#N` ref (the `repo:` field's
# cross-repo case — plan-schema.md § Optional `repo:` field), emitted as
# `Closes owner/repo#N`; a bare `Closes #N` is same-repo only. Because linkage
# lives here and only here, a bare closing-keyword LINE the worker wrote into
# its own verification surface is STRIPPED from that surface before the body is
# assembled (temperloop#1023 — see strip_surface_closes below), so the assembled
# body carries exactly one linkage block. `--body-only` prints the assembled
# body verbatim and exits — the dry mode tests assert on.
#
# `acceptance-extract` is the INVERSE of `open`'s `## Acceptance` recap: it
# reads an assembled PR body back into the worker's `acceptance_results`
# entries. The recap's evidence rides its own nested line (temperloop#1267), so
# the criterion/evidence split is POSITIONAL and both survive an embedded
# ` — ` byte-exactly — the round-trip property `open`'s tests assert, and the
# reason a downstream reader (replay, a retro judge, an auditing human) has one
# owned extractor to call rather than a per-consumer parse-by-eye.
#
# Output contract — CLOSED outcome set, one structured JSON line per outcome
# (exceptions: `open --body-only` prints the raw body and `acceptance-extract`
# prints a JSON array, neither in an outcome wrapper):
#   scan       → {"outcome":"SCAN_CLEAN"} |
#                {"outcome":"SCAN_BLOCKED","matches":[…]} + non-zero exit
#   base-check → {"outcome":"BASE_CURRENT"|"BASE_STALE","merge_base":…,"tip":…}
#   rebase     → {"outcome":"REBASED","base":…,"tip":…,"sha":…,"rebase_needed":bool} |
#                {"outcome":"REBASE_CONFLICT","base":…,"tip":…,"error":…} + non-zero exit |
#                {"outcome":"DIRTY_WORKTREE","base":…,"tip":…,"rebase_needed":bool,
#                 "dirty_files":N,"dirty_paths":[…]} + non-zero exit
#                (DIRTY_WORKTREE = git REFUSED to start the rebase because the
#                 tree carries uncommitted TRACKED-file edits — a distinct state
#                 from a content conflict, which REBASE_CONFLICT now means and
#                 only means; rebase_needed=false says base == tip, i.e. no
#                 rebase was required at all — temperloop#735)
#   push       → {"outcome":"PUSHED","sha":…,"branch":…,"forced":bool} |
#                {"outcome":"PUSH_REJECTED","sha":…,"branch":…,"error":…} + non-zero exit
#                (forced=true only when a genuine rewrite needed --force; a
#                 requested --force that is a pure fast-forward downgrades to a
#                 plain push, forced=false — #335)
#   open       → {"outcome":"PR_OPENED","pr_number":…,"url":…,
#                 "surface_closes_stripped":N} |
#                {"outcome":"EXISTS","pr_number":…,"url":…,
#                 "surface_closes_stripped":N}
#                (EXISTS when gh reports a PR for that branch already exists — adopt it;
#                 surface_closes_stripped = how many duplicate bare closing-keyword
#                 lines were removed from the worker's verification surface, normally 0)
#   recover-probe → {"outcome":"RECOVER_NONE"|"RECOVER_DIRTY"|"RECOVER_COMMITTED"
#                    |"RECOVER_PUSHED"|"RECOVER_PR_OPEN","sha":…,"branch":…,
#                    "commits_ahead":N,"pushed":bool,"remote_sha":…,
#                    "dirty":bool,"dirty_files":N,
#                    "verification_surface_present":bool[,"pr_number":N,"url":…]}
#   acceptance-extract → [{"passed":bool,"criterion":…,"evidence":…|null,
#                          "deferred_host_config":…|null,
#                          "discrimination_evidence":…|null}, …]
#   error      → {"outcome":"ERROR","error":…} + non-zero exit
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

# The 3f step-0 closing-keyword pattern (the ec8d5fd class): any GitHub
# closing keyword followed by an issue reference, case-insensitive.
CLOSING_RE='\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b[[:space:]]*#[0-9]+'

# fd 3 = the script's real stdout. Helpers run inside command substitutions,
# where a die()'s ERROR line would be captured by the caller instead of
# reaching the orchestrator — emitting via fd 3 keeps the structured error on
# the real stdout regardless of call context.
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: pr.sh scan <worktreePath> | base-check <worktreePath> | rebase <worktreePath> | push <worktreePath> <branch> [--force] | recover-probe <worktreePath> <branch> | open --verdict <file|-> [--gh-issue N] [--also-closes N,N,...] [--plan-link <target>] [--source <ref>] [--verification-surface-file <path>] (--body-only | --repo <repo-root> --branch <branch> --title <title>) | acceptance-extract <bodyFile|->"
}

# Physical-path resolve for an EXISTING dir (portable — no GNU readlink -f).
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# Resolve + validate a worktree path: must exist and be a git work-tree
# toplevel (a linked worktree is its own toplevel, so the orchestrator's
# deterministic `<repo>.wt/<slug>` path passes; a subdir does not).
resolve_worktree() {
  local arg="$1" wt top
  wt="$(abs_dir "$arg")" || die "worktree path '$arg' does not exist"
  top="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" || die "worktree path '$arg' is not inside a git work tree"
  top="$(abs_dir "$top")"
  [ "$wt" = "$top" ] || die "worktree path '$arg' is not a git toplevel (toplevel is '$top')"
  printf '%s\n' "$wt"
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

# Branch names feed a refspec; reject anything git itself would reject rather
# than letting the push error surface as a confusing rejection.
validate_branch() {
  local branch="$1"
  [ -n "$branch" ] || die "branch name is empty"
  git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 \
    || die "branch '$branch' is not a valid git branch name"
}

# Issue refs feed `Closes` lines: either plain digits (bare same-repo
# `Closes #N`) or a fully-qualified `owner/repo#N` cross-repo ref (the
# `repo:` field case — plan-schema.md § Optional `repo:` field). A bare
# `Closes #N` is same-repo only (CLAUDE.md § Issue linkage), so a cross-repo
# close must carry the owner/repo# qualifier — see closes_line() below.
_ISSUE_QUALIFIED_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$'
validate_issue() {
  [[ "$1" =~ ^[0-9]+$ ]] && return 0
  [[ "$1" =~ $_ISSUE_QUALIFIED_RE ]] && return 0
  die "issue ref '$1' invalid — must be digits, or owner/repo#N for a cross-repo close"
}

# Format one issue ref as a bare `Closes` line (no trailing newline — the
# caller appends $'\n' itself, since a $(...) capture would strip it): a
# qualified owner/repo#N ref is emitted as-is (Closes owner/repo#N); a plain
# number gets the leading # (Closes #N).
closes_line() {
  case "$1" in
    *'#'*) printf 'Closes %s' "$1" ;;
    *)     printf 'Closes #%s' "$1" ;;
  esac
}

# --- scan: 3f step 0 — closing-keyword pre-push scan --------------------------
# Pure function of the worker's unpushed commit messages: grep every commit
# body in origin/<default>..HEAD for closing keywords. A match is the ec8d5fd
# failure mode (GitHub scans default-branch commit messages, not just the PR
# body, so a stray `Closes #N` auto-closes on merge); linkage belongs in the
# PR body alone, so a hit BLOCKS the push.
cmd_scan() {
  local wt default log matches
  wt="$(resolve_worktree "$1")"
  default="$(default_branch "$wt")" || die "cannot resolve origin's default branch in '$wt'"
  log="$(git -C "$wt" log "origin/$default..HEAD" --format=%B 2>&1)" \
    || die "git log origin/$default..HEAD failed in '$wt': $log"
  matches="$(grep -iE "$CLOSING_RE" <<<"$log" || true)"
  if [ -z "$matches" ]; then
    jq -cn '{outcome:"SCAN_CLEAN"}'
  else
    jq -cn --arg m "$matches" '{outcome:"SCAN_BLOCKED", matches:($m|split("\n"))}'
    exit 1
  fi
}

# --- base-check: 3f step 0.5 — speculative base-currency check ----------------
# Fetch the default branch, then compare merge-base(HEAD, origin/<default>)
# against the origin/<default> tip: equal → the worker's base is current
# (BASE_CURRENT, safe to push); behind → BASE_STALE (pushing would silently
# drop the merged level-k changes in overlapping regions — the orchestrator
# runs the rebase-then-reverify / discard-and-respawn flow, not this script).
cmd_base_check() {
  local wt default mb tip outcome out
  wt="$(resolve_worktree "$1")"
  default="$(default_branch "$wt")" || die "cannot resolve origin's default branch in '$wt'"
  out="$(git -C "$wt" fetch origin "$default" 2>&1)" \
    || die "git fetch origin $default failed in '$wt': $out"
  tip="$(git -C "$wt" rev-parse "origin/$default")" || die "cannot resolve origin/$default tip"
  mb="$(git -C "$wt" merge-base HEAD "origin/$default" 2>/dev/null)" \
    || die "no merge base between HEAD and origin/$default in '$wt'"
  if [ "$mb" = "$tip" ]; then outcome="BASE_CURRENT"; else outcome="BASE_STALE"; fi
  jq -cn --arg outcome "$outcome" --arg mb "$mb" --arg tip "$tip" \
    '{outcome:$outcome, merge_base:$mb, tip:$tip}'
}

# --- rebase: 3f step 0.5 — rebase onto fresh origin/<default> ------------------
# The unconditional stale-base guard (#525): a worker branches off
# origin/<default> at the start of its run, but on a fast-moving default a long
# run lets the default advance mid-build — so by push/PR-open time the worker's
# base is stale and the PR's cumulative diff REVERTS whatever merged in between
# (W49 PR#82 / W52 PR#83). Fetch the default fresh, then rebase the worktree's
# HEAD onto its tip so the PR diff carries ONLY the worker's own changes:
#   - DIRTY worktree  → git would REFUSE to rebase at all ("cannot rebase: You
#                       have unstaged changes") → DIRTY_WORKTREE + non-zero exit
#                       (see below — never attempted, so never a conflict)
#   - already current (merge-base == tip) → nothing to replay; the rebase is
#                       SKIPPED entirely → REBASED, rebase_needed:false
#   - behind          → replay the worker's commits onto the new tip, REBASED
#   - CONFLICT        → `git rebase --abort` (leave the worktree clean, NEVER a
#                       half-rebased tree and NEVER a silent revert) → REBASE_CONFLICT
#                       + non-zero exit. The orchestrator escalates this as a
#                       rebase conflict for a human to resolve.
#
# DIRTY_WORKTREE vs REBASE_CONFLICT — two states, two outcomes (temperloop#735).
# git refuses to START a rebase while tracked files carry uncommitted edits, and
# that refusal is a NON-ZERO exit exactly like a content conflict. Branching on
# the exit code alone collapsed the two: a worker that FINISHED (commit made,
# gates green) but left one tracked file unstaged was reported
# {"outcome":"REBASE_CONFLICT","base":X,"tip":X} — base == tip, so no rebase was
# even needed and no conflict existed anywhere — and the orchestrator's
# rebase-conflict escalation would have discarded that finished work.
# The two cases are separable from git's OWN state rather than from its exit
# code or its (localised, reworded-between-releases) stderr prose: `git status
# --porcelain --untracked-files=no` is non-empty iff the tree carries the
# tracked-file edits that make git refuse. So the dirtiness is probed FIRST and
# reported as its own outcome, the rebase is never attempted (nothing to abort,
# and the worker's uncommitted edits are left exactly where they are), and
# REBASE_CONFLICT is left meaning only what it says: a rebase was attempted and
# its replay failed. `rebase_needed` (base != tip) rides both outcomes so the
# orchestrator can see that a DIRTY_WORKTREE with rebase_needed:false is a
# finished worker needing its edits COMMITTED — never a discard.
# Untracked files are deliberately not dirt here: git rebases straight past
# them, and the worktree always carries at least the untracked `.build-guard`.
cmd_rebase() {
  local wt default base tip out sha dirty dirty_files rebase_needed
  wt="$(resolve_worktree "$1")"
  default="$(default_branch "$wt")" || die "cannot resolve origin's default branch in '$wt'"
  out="$(git -C "$wt" fetch origin "$default" 2>&1)" \
    || die "git fetch origin $default failed in '$wt': $out"
  tip="$(git -C "$wt" rev-parse "origin/$default")" || die "cannot resolve origin/$default tip"
  base="$(git -C "$wt" merge-base HEAD "origin/$default" 2>/dev/null)" \
    || die "no merge base between HEAD and origin/$default in '$wt'"
  if [ "$base" = "$tip" ]; then rebase_needed=false; else rebase_needed=true; fi

  # The dirty-vs-conflict split, probed before anything is attempted.
  # stdout ONLY (stderr discarded rather than folded in): a git warning on
  # stderr must never be counted as one of the dirty paths.
  dirty="$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null)" \
    || die "git status --porcelain failed in '$wt'"
  if [ -n "$dirty" ]; then
    dirty_files="$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')"
    case "$dirty_files" in ''|*[!0-9]*) dirty_files=0 ;; esac
    jq -cn --arg base "$base" --arg tip "$tip" --argjson rebase_needed "$rebase_needed" \
      --argjson dirty_files "$dirty_files" --arg paths "$dirty" \
      '{outcome:"DIRTY_WORKTREE", base:$base, tip:$tip,
        rebase_needed:$rebase_needed, dirty_files:$dirty_files,
        dirty_paths:($paths|split("\n"))}'
    exit 1
  fi

  # Base already current: there is nothing to replay, so skip the rebase.
  if [ "$rebase_needed" = false ]; then
    sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || die "cannot resolve HEAD in '$wt'"
    jq -cn --arg base "$base" --arg tip "$tip" --arg sha "$sha" \
      '{outcome:"REBASED", base:$base, tip:$tip, sha:$sha, rebase_needed:false}'
    return 0
  fi

  if out="$(git -C "$wt" rebase "origin/$default" 2>&1)"; then
    sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || die "cannot resolve HEAD after rebase in '$wt'"
    jq -cn --arg base "$base" --arg tip "$tip" --arg sha "$sha" \
      '{outcome:"REBASED", base:$base, tip:$tip, sha:$sha, rebase_needed:true}'
  else
    # Conflict (or any rebase failure): abort so the worktree is left clean and
    # the worker's commits are intact — NEVER leave a half-applied rebase, and
    # NEVER silently propose a revert. Escalate as a rebase conflict.
    git -C "$wt" rebase --abort >/dev/null 2>&1 || true
    jq -cn --arg base "$base" --arg tip "$tip" --arg error "$out" \
      '{outcome:"REBASE_CONFLICT", base:$base, tip:$tip, error:$error}'
    exit 1
  fi
}

# --- push: 3f step 1 — push-by-SHA ---------------------------------------------
# Push the worktree's HEAD to the plan branch by SHA, honoring the plan's
# `branch:` name regardless of the worktree's throwaway build/<slug> local
# branch. --force is *requested* by the rebase re-push (0.5) and CI-fix re-push
# (3g) paths, but is only actually *used* when the push is a genuine history
# rewrite — see the fast-forward downgrade below (#335). A rejection is a
# structured outcome — stale-branch-vs-collision triage is the orchestrator's
# call.
#
# #335 — prefer a plain fast-forward push over --force. A CI-retry commit is a
# fast-forward descendant of the already-pushed head (the CI-fix worker resets
# to the remote tip, then commits on top), so it needs no history rewrite; yet
# the requesting caller always passes --force. An unconditional --force on a
# feature branch trips the git-destructive safety classifier in auto mode
# non-deterministically, which silently parks/dead-ends an autonomous /sweep,
# /build --unattended, or pipeline-drive-merge run. So when --force is requested
# we DOWNGRADE to a plain push whenever we can positively prove the local head
# descends from the current remote tip (a pure fast-forward), and reserve the
# real --force for a genuine rewrite (local head does NOT descend the tip) or an
# indeterminate remote state (fetch failed) — never weakening main's safety.
# `forced` in the PUSHED payload records what was actually used.
cmd_push() {
  local wt branch force="$1" sha out effective_force
  wt="$(resolve_worktree "$2")"
  branch="$3"
  validate_branch "$branch"
  sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || die "cannot resolve HEAD in '$wt'"
  effective_force="$force"
  if [ -n "$force" ]; then
    # Fetch the current remote tip (FETCH_HEAD). If it is an ancestor of the
    # local head, the push is a pure fast-forward — no --force needed. Only a
    # POSITIVE proof downgrades; a fetch failure or a non-ancestor tip keeps the
    # requested --force, so behavior is unchanged whenever a rewrite may be real.
    if git -C "$wt" fetch --quiet origin "$branch" 2>/dev/null \
       && git -C "$wt" merge-base --is-ancestor FETCH_HEAD HEAD 2>/dev/null; then
      effective_force=""
    fi
  fi
  if out="$(git -C "$wt" push ${effective_force:+--force} origin "$sha:refs/heads/$branch" 2>&1)"; then
    jq -cn --arg sha "$sha" --arg branch "$branch" --argjson forced "$([ -n "$effective_force" ] && echo true || echo false)" \
      '{outcome:"PUSHED", sha:$sha, branch:$branch, forced:$forced}'
  else
    jq -cn --arg sha "$sha" --arg branch "$branch" --arg error "$out" \
      '{outcome:"PUSH_REJECTED", sha:$sha, branch:$branch, error:$error}'
    exit 1
  fi
}

# --- recover-probe: 3c lost-return side-effect probe (temperloop#939) ----------
# When the 3c worker completes WITHOUT returning a verdict (the subagent never
# called StructuredOutput, or blew the StructuredOutput retry cap), the return
# CHANNEL failed — which says nothing about whether the WORK failed. In the #939
# incident the worker had committed, pushed, opened PR #936 and gone green, yet
# the level reported `worker-error`; a second worker in the same run had
# committed but not pushed. So the side-effect state at death is NOT uniform and
# a single boolean ("did it get far enough?") mis-handles one of the two shapes.
#
# This is the STAGED probe build-level.mjs runs before it classifies that death.
# It reads only observable ground truth — never the worker's word — and reports
# the furthest stage the work actually reached:
#   1. commits ahead of origin/<default> in the worktree? → work exists at all
#   2. the branch present on origin (`git ls-remote`)?    → it was pushed
#   3. an OPEN PR for that branch (`gh pr list`)?         → the PR exists
# RECOVER_NONE (stage 0, and no open PR) is the genuine-failure case the caller
# still escalates unchanged. Anything else is recoverable: the caller
# reconstructs the parked record from these fields instead of escalating, and
# resumes the machinery at the right stage rather than re-spawning the worker.
#
# RECOVER_DIRTY (temperloop#993) splits stage 0 in two. A worker that backgrounds
# the quality gate and yields is reaped mid-flight: it has REAL WORK ON DISK and
# ZERO commits (observed twice in one run — #982 with 8 modified files, #983 with
# 3), which is a materially different state from a worker that died having touched
# nothing. Both were RECOVER_NONE before, so the caller could not tell "resume the
# same worktree, the work is still there" from "nothing happened". `dirty` /
# `dirty_files` (a `git status --porcelain` line count, tracked edits AND untracked
# files) are reported on EVERY outcome; the RECOVER_DIRTY outcome fires only where
# it changes the answer — nothing committed, no PR, but the tree is dirty. It is
# NOT a "landed" stage: nothing is committed, so there is nothing to push or open a
# PR from — the caller's recovery ladder must keep treating it as not-landed and
# resume the WORKER (build-level.mjs's foreground-cure re-spawn), never
# reconstruct a parked record from it.
#
# `verification_surface_present` reports whether the worker got as far as writing
# `.build-verification.md`, so the caller knows whether it may pass
# --verification-surface-file to `open` (a given-but-missing surface file is a
# hard ERROR by contract) or must fall back to a synthesized surface.
#
# Read-only and FAIL-SOFT by construction: it fetches nothing and writes nothing,
# and a missing/erroring `gh` degrades to "no PR observed" (a caller that then
# re-runs `open` gets EXISTS and adopts the PR anyway) rather than failing the
# whole recovery. Only an unusable worktree/branch argument is a structured ERROR.
cmd_recover_probe() {
  local wt branch default ahead sha remote_sha pr_number url outcome surface out
  local dirty_files dirty
  wt="$(resolve_worktree "$1")"
  branch="$2"
  validate_branch "$branch"
  default="$(default_branch "$wt")" || die "cannot resolve origin's default branch in '$wt'"
  sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || die "cannot resolve HEAD in '$wt'"
  # No fetch: the worktree was created from the local origin/<default> ref, and a
  # probe must never mutate refs or depend on the network to answer.
  ahead="$(git -C "$wt" rev-list --count "origin/$default..HEAD" 2>/dev/null || echo 0)"
  case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac

  remote_sha=""
  out="$(git -C "$wt" ls-remote --heads origin "$branch" 2>/dev/null || true)"
  if [ -n "$out" ]; then
    remote_sha="$(printf '%s\n' "$out" | head -1 | awk '{print $1}')"
  fi

  pr_number=""; url=""
  if command -v gh >/dev/null 2>&1; then
    out="$(cd "$wt" && gh pr list --head "$branch" --state open --json number,url --limit 1 2>/dev/null || true)"
    if [ -n "$out" ] && jq -e . >/dev/null 2>&1 <<<"$out"; then
      pr_number="$(jq -r '(.[0].number // "") | tostring | select(. != "null")' <<<"$out" 2>/dev/null || true)"
      url="$(jq -r '.[0].url // ""' <<<"$out" 2>/dev/null || true)"
    fi
  fi
  case "$pr_number" in ''|*[!0-9]*) pr_number="" ;; esac

  surface=false
  if [ -f "$wt/.build-verification.md" ]; then surface=true; fi

  # Uncommitted work on disk (tracked edits + untracked files). Reported on every
  # outcome; only stage 0 branches on it (temperloop#993). `.build-guard` is
  # EXCLUDED by pathspec: worktree.sh's `create` drops that marker itself, so it
  # is orchestrator machinery, never worker work — counting it would make every
  # freshly-created worktree read dirty and collapse RECOVER_NONE into
  # RECOVER_DIRTY wherever a consuming repo has not gitignored it (this repo has;
  # the exclusion is what makes the rung correct where it hasn't).
  dirty_files="$(git -C "$wt" status --porcelain -- ':(exclude).build-guard' 2>/dev/null | wc -l | tr -d ' ')"
  case "$dirty_files" in ''|*[!0-9]*) dirty_files=0 ;; esac
  dirty=false
  if [ "$dirty_files" -gt 0 ]; then dirty=true; fi

  if [ -n "$pr_number" ]; then
    outcome="RECOVER_PR_OPEN"
  elif [ "$ahead" -eq 0 ] && [ "$dirty_files" -gt 0 ]; then
    # Nothing committed, no PR — but the worker left real work on disk. The
    # #993 backgrounded-gate stall: resume the worker on THIS worktree.
    outcome="RECOVER_DIRTY"
  elif [ "$ahead" -eq 0 ]; then
    # Nothing committed and no PR — the worker died with no observable trace.
    outcome="RECOVER_NONE"
  elif [ -n "$remote_sha" ]; then
    outcome="RECOVER_PUSHED"
  else
    outcome="RECOVER_COMMITTED"
  fi

  jq -cn --arg outcome "$outcome" --arg sha "$sha" --arg branch "$branch" \
     --argjson ahead "$ahead" --arg remote_sha "$remote_sha" \
     --arg pr "$pr_number" --arg url "$url" --argjson surface "$surface" \
     --argjson dirty "$dirty" --argjson dirty_files "$dirty_files" \
     '{outcome:$outcome, sha:$sha, branch:$branch, commits_ahead:$ahead,
       pushed:($remote_sha != ""), remote_sha:$remote_sha,
       dirty:$dirty, dirty_files:$dirty_files,
       verification_surface_present:$surface}
      + (if $pr == "" then {} else {pr_number:($pr|tonumber), url:$url} end)'
}

# --- open: 3f step 2 — PR-body assembly + gh pr create -------------------------

# Resolve the ## Verification surface body by precedence (the #418 inflow-cut),
# so the large block need never round-trip through the orchestrator's context:
#   1. --verification-surface-file <path>      (explicit; the orchestrator
#      passes the deterministic worktree path)      → read the file
#   2. verdict's `.verification_surface_path`       (the worker wrote a file in
#      its worktree and returned only the path)      → read the file
#   3. verdict's inline `.verification_surface`      (back-compat)
#   4. empty → the caller falls back to the acceptance recap
# A path that is given but unreadable is a contract violation → die (a structured
# ERROR the orchestrator branches on, rather than silently degrading to recap).
resolve_surface() {
  local surface_file="$1" verdict="$2" spath
  if [ -n "$surface_file" ]; then
    [ -f "$surface_file" ] || die "--verification-surface-file '$surface_file' does not exist"
    cat "$surface_file"
    return 0
  fi
  spath="$(jq -r '.verification_surface_path // ""' <<<"$verdict")"
  if [ -n "$spath" ]; then
    [ -f "$spath" ] || die "verdict .verification_surface_path '$spath' does not exist"
    cat "$spath"
    return 0
  fi
  jq -r '.verification_surface // ""' <<<"$verdict"
}

# Strip the worker's own duplicate linkage from the resolved verification
# surface (temperloop#1023). Issue linkage lives in ONE place — the bare
# `Closes` block assemble_body emits from --gh-issue/--also-closes. The
# `## Verification` section, by contrast, is WORKER-AUTHORED content spliced in
# verbatim, so a worker that copied that block into its own
# `.build-verification.md` made the assembled body carry it twice (observed on
# temperloop PR #1019). GitHub dedupes closing keywords, so linkage still
# resolved — the cost is reviewer-facing: the body reads as though linkage were
# declared twice, contradicting the single-home invariant this script's header
# states. Stripping here rather than asking every worker to remember a prose
# rule keeps the invariant machine-enforced, like the `scan` pre-push check.
#
# What is removed is deliberately NARROW — only a line GitHub itself would
# honor AND that can only be a duplicate of this script's own emission: a WHOLE
# line that is nothing but `<keyword> #N` or `<keyword> owner/repo#N`. Kept:
#   - a mid-sentence mention ("…emits `Closes #976` near the top of the body")
#   - a backticked / inline-code line — GitHub ignores those, so they were never
#     a duplicate (the same lexical model lint-pr-body.sh uses)
#   - an indented line (a 4-space code block — likewise ignored by GitHub)
#   - ANY line inside a ``` / ~~~ fenced code block, so a surface that quotes an
#     assembled PR body as its evidence keeps that evidence intact
# Blank lines left behind by a removal are NOT collapsed: Markdown renders a run
# of blank lines identically, and any rewrite beyond deleting the offending line
# would risk mutating worker evidence for a cosmetic gain.
#
#   mode=count → print how many lines WOULD be stripped (0 for a clean surface)
#   mode=strip → print the surface with those lines removed
# cmd_open counts first and only re-runs in strip mode when the count is
# non-zero, so a surface carrying no such line is passed through byte-for-byte
# by construction rather than by inspection.
strip_surface_closes() {
  awk -v mode="$1" '
    function is_closes_line(l,   t) {
      t = tolower(l)
      if (t ~ /^(closes|closed|close|fixes|fixed|fix|resolves|resolved|resolve)[[:blank:]]*:?[[:blank:]]*#[0-9]+[[:blank:]]*$/) return 1
      if (t ~ /^(closes|closed|close|fixes|fixed|fix|resolves|resolved|resolve)[[:blank:]]*:?[[:blank:]]*[a-z0-9_.-]+\/[a-z0-9_.-]+#[0-9]+[[:blank:]]*$/) return 1
      return 0
    }
    BEGIN { fence = ""; n = 0 }
    {
      if (fence != "") {
        if (substr($0, 1, 3) == fence) fence = ""
        if (mode == "strip") print
        next
      }
      if (substr($0, 1, 3) == "```" || substr($0, 1, 3) == "~~~") {
        fence = substr($0, 1, 3)
        if (mode == "strip") print
        next
      }
      if (is_closes_line($0)) { n++; next }
      if (mode == "strip") print
    }
    END { if (mode == "count") print n + 0 }
  '
}

# Assemble the PR body per the 3f contract, from the verdict JSON + plan
# fields. Section order: summary; bare Closes lines (one per entry, own line,
# no backticks — combining or code-spanning them breaks GitHub's auto-close);
# acceptance recap; ## Verification (the resolved surface, see resolve_surface,
# falling back to the recap ONLY if no surface was produced); backlinks;
# Claude Code footer.
assemble_body() {
  local verdict="$1" gh_issue="$2" also_closes="$3" plan_link="$4" source_ref="$5" surface="$6"
  local summary recap body n
  summary="$(jq -er '.summary' <<<"$verdict" 2>/dev/null)" \
    || die "verdict JSON missing .summary"
  # temperloop#1319: `.discrimination_evidence` (worker-reported proof that an
  # acceptance check can actually FAIL — which mechanism it removed, that the
  # suite went red without it, that restoring it went green) is a FOURTH field
  # the worker may return alongside `.criterion`/`.passed`/`.evidence`. This jq
  # is the load-bearing consumer: reading only the original three would
  # silently DROP that evidence from the PR body a human actually reviews —
  # exactly the failure this item exists to close (see presentation-plane.md's
  # WORKER_VERDICT_SCHEMA row). Rendered on its own line under the bullet so a
  # long discrimination narrative doesn't crowd the pointer-shaped `evidence`.
  # temperloop#1182: `.deferred_host_config` is a FIFTH field — the deferral
  # marker for a criterion that turns on a gitignored host-local file a
  # worktree structurally never contains. Read here for exactly the reason
  # above: without it, a human reviewing this PR cannot tell an unchecked box
  # meaning "the worker failed this" from one meaning "nobody could check this
  # from a worktree — the orchestrator verified it in the real checkout". The
  # two render identically otherwise, which is the whole failure.
  # temperloop#1267: `.evidence` rides its OWN nested line (`\n      — …`),
  # never appended inline after a bare ` — ` delimiter. ` — ` occurs inside
  # real criteria AND inside real evidence, so an inline delimiter made the
  # recap unparseable: a first-occurrence split truncates the criterion, a
  # last-occurrence split breaks whenever the evidence carries its own
  # em-dash, and no rule decides between them. On its own line the split is
  # POSITIONAL — `acceptance-extract` below recovers both fields byte-exactly
  # with no heuristic. GitHub renders the indented continuation as part of the
  # same list paragraph, so the human reading looks unchanged.
  recap="$(jq -r '(.acceptance_results // [])[]
            | "- [" + (if .passed then "x" else " " end) + "] "
              + .criterion
              + ((.evidence // "") | if . == "" then "" else "\n      — " + . end)
              + ((.deferred_host_config // "") | if . == "" then "" else "\n      DEFERRED — host-config `" + . + "` is invisible from a worktree; verified parent-side (temperloop#1182)" end)
              + ((.discrimination_evidence // "") | if . == "" then "" else "\n      discrimination: " + . end)' \
          <<<"$verdict")" || die "verdict JSON has malformed .acceptance_results"
  # surface is resolved by the caller (cmd_open → resolve_surface) so a missing
  # surface file dies at the top level, not inside this nested command sub.

  body="$summary"$'\n'
  if [ -n "$gh_issue" ] || [ -n "$also_closes" ]; then
    body="$body"$'\n'
    [ -n "$gh_issue" ] && body="${body}$(closes_line "$gh_issue")"$'\n'
    for n in $also_closes; do
      body="${body}$(closes_line "$n")"$'\n'
    done
  fi
  if [ -n "$recap" ]; then
    body="$body"$'\n''## Acceptance'$'\n'"$recap"$'\n'
  fi
  body="$body"$'\n''## Verification'$'\n'
  if [ -n "$surface" ]; then
    body="$body$surface"$'\n'
  else
    # Fallback only when the worker produced no verification_surface — the
    # bare recap alone does not satisfy the PR-verification-surface rule, so
    # the orchestrator should treat this as degraded, not normal.
    body="$body$recap"$'\n'
  fi
  if [ -n "$plan_link" ] || [ -n "$source_ref" ]; then
    body="$body"$'\n'
    [ -n "$plan_link" ] && body="${body}Tracked in: [[${plan_link}]]"$'\n'
    [ -n "$source_ref" ] && body="${body}Derived from: ${source_ref}"$'\n'
  fi
  body="$body"$'\n''🤖 Generated with [Claude Code](https://claude.com/claude-code)'
  printf '%s\n' "$body"
}

# --- acceptance-extract: the INVERSE of assemble_body's ## Acceptance recap ----
#
# temperloop#1267. The PR body is the only durable verbatim record of the
# acceptance bullets a worker was handed (the item object is never persisted;
# the worktree and its .build-verification.md are deleted at terminal
# disposition; /sweep and /fix singletons produce no plan note). Every consumer
# that reads that record back — replay, a retro judge, a human auditing a merge
# — needs ONE owned extractor rather than a parse-by-eye per consumer, or the
# ambiguity this item closed re-enters through the reader instead of the writer.
#
# The grammar it inverts, one entry per `- [x] ` / `- [ ] ` bullet inside the
# FIRST `## Acceptance` section (a later `## ` heading ends it; a `## Acceptance`
# heading appearing inside a worker's own verification surface is therefore never
# re-entered):
#
#   - [x] <criterion, possibly spanning further un-prefixed lines>
#         — <evidence>
#         DEFERRED — host-config `<path>` is invisible from a worktree; …
#         discrimination: <discrimination_evidence>
#
# Each field ends at the next marker line, the next bullet, or a BLANK line, so
# an un-prefixed continuation line belongs to whichever field is open — that is
# what makes an embedded newline, and an embedded ` — `, survive intact. The
# split is POSITIONAL: no first-vs-last-delimiter guess anywhere. Two structural
# constraints the format asks of its inputs, both of which a bullet that renders
# as one Markdown list item already satisfies: no field's text contains a line
# beginning with one of the three marker prefixes above (six spaces + `— `,
# `DEFERRED — host-config \``, or `discrimination: `), and none contains a blank
# line (which would end the list item's paragraph in GitHub's renderer anyway —
# the recap's own trailing blank line before the next `## ` heading is exactly
# that terminator).
# shellcheck disable=SC2016  # $l / $ph are jq bindings — shell must NOT expand them
ACCEPTANCE_EXTRACT_JQ='
def flush: if .cur == null then . else .out += [.cur | del(.phase)] | .cur = null end;
split("\n")
| reduce .[] as $l (
    {sec: false, done: false, cur: null, out: []};
    if .done then .
    elif ($l == "## Acceptance") and (.sec | not) then .sec = true
    elif .sec and ($l | startswith("## ")) then flush | .sec = false | .done = true
    elif (.sec | not) then .
    elif ($l | test("^- \\[[x ]\\] ")) then
        flush
      | .cur = {passed: ($l[3:4] == "x"), criterion: $l[6:], evidence: null,
                deferred_host_config: null, discrimination_evidence: null,
                phase: "criterion"}
    elif .cur == null then .
    elif ($l == "") then .cur.phase = "closed"
    elif (.cur.phase == "closed") then .
    elif ($l | startswith("      — ")) and (.cur.phase == "criterion") then
        .cur.evidence = $l[8:] | .cur.phase = "evidence"
    elif ($l | startswith("      DEFERRED — host-config `")) then
        .cur.deferred_host_config =
          ($l | capture("^      DEFERRED — host-config `(?<p>.*)` is invisible from a worktree;") | .p)
      | .cur.phase = "deferred_host_config"
    elif ($l | startswith("      discrimination: ")) then
        .cur.discrimination_evidence = $l[22:] | .cur.phase = "discrimination_evidence"
    else
        (.cur.phase) as $ph | .cur[$ph] = (.cur[$ph] + "\n" + $l)
    end)
| flush
| .out
'

# acceptance-extract <bodyFile|-> — read an assembled PR body, print the
# recovered acceptance entries as one compact JSON array. Like `open
# --body-only`, this is an exception to the one-outcome-JSON-line contract: the
# array IS the payload, and an unreadable path is the usual structured ERROR.
cmd_acceptance_extract() {
  local src="$1" body
  if [ "$src" = "-" ]; then
    body="$(cat)"
  else
    [ -f "$src" ] || die "acceptance-extract: body file '$src' does not exist"
    body="$(cat "$src")"
  fi
  jq -Rsc "$ACCEPTANCE_EXTRACT_JQ" <<<"$body" \
    || die "acceptance-extract: could not parse the ## Acceptance recap"
}

cmd_open() {
  local verdict_src="" repo="" branch="" title="" gh_issue="" also_closes="" \
        plan_link="" source_ref="" surface_file="" surface="" body_only="" verdict body out url pr_number n raw
  local stripped=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --verdict)     [ $# -ge 2 ] || usage; verdict_src="$2"; shift ;;
      --repo)        [ $# -ge 2 ] || usage; repo="$2"; shift ;;
      --branch)      [ $# -ge 2 ] || usage; branch="$2"; shift ;;
      --title)       [ $# -ge 2 ] || usage; title="$2"; shift ;;
      --gh-issue)    [ $# -ge 2 ] || usage; gh_issue="$2"; shift ;;
      --also-closes) [ $# -ge 2 ] || usage; also_closes="$2"; shift ;;
      --plan-link)   [ $# -ge 2 ] || usage; plan_link="$2"; shift ;;
      --source)      [ $# -ge 2 ] || usage; source_ref="$2"; shift ;;
      --verification-surface-file) [ $# -ge 2 ] || usage; surface_file="$2"; shift ;;
      --body-only)   body_only=1 ;;
      *) usage ;;
    esac
    shift
  done

  [ -n "$verdict_src" ] || die "open requires --verdict <file|->"
  if [ "$verdict_src" = "-" ]; then
    verdict="$(cat)"
  else
    [ -f "$verdict_src" ] || die "verdict file '$verdict_src' does not exist"
    verdict="$(cat "$verdict_src")"
  fi
  jq -e . >/dev/null 2>&1 <<<"$verdict" || die "verdict is not valid JSON"

  [ -z "$gh_issue" ] || validate_issue "$gh_issue"
  # --also-closes accepts comma- or space-separated numbers; normalize to
  # space-separated so each emits its own bare `Closes #N` line.
  also_closes="$(printf '%s' "$also_closes" | tr ',' ' ')"
  for n in $also_closes; do validate_issue "$n"; done

  # Resolve the verification surface at the TOP level (not inside assemble_body's
  # nested command sub) so a missing surface file dies cleanly with a structured
  # ERROR. `|| exit 1` propagates resolve_surface's die (it already wrote the
  # ERROR to fd3) without emitting a second one.
  surface="$(resolve_surface "$surface_file" "$verdict")" || exit 1
  # temperloop#1023 — drop a linkage block the worker copied into its own
  # surface, so the assembled body carries exactly one (see strip_surface_closes).
  if [ -n "$surface" ]; then
    stripped="$(strip_surface_closes count <<<"$surface")"
    case "$stripped" in ''|*[!0-9]*) stripped=0 ;; esac
    if [ "$stripped" -gt 0 ]; then
      surface="$(strip_surface_closes strip <<<"$surface")"
    fi
  fi
  body="$(assemble_body "$verdict" "$gh_issue" "$also_closes" "$plan_link" "$source_ref" "$surface")"

  if [ -n "$body_only" ]; then
    printf '%s\n' "$body"
    return 0
  fi

  [ -n "$repo" ]   || die "open requires --repo <repo-root> (unless --body-only)"
  [ -n "$branch" ] || die "open requires --branch (unless --body-only)"
  [ -n "$title" ]  || die "open requires --title (unless --body-only)"
  repo="$(abs_dir "$repo")" || die "repo-root does not exist"
  validate_branch "$branch"

  if ! out="$(cd "$repo" && gh pr create --head "$branch" --title "$title" --body "$body" 2>&1)"; then
    # gh pr create fails with "a pull request for branch ... already exists: <url>"
    # when the branch already has an open PR (e.g. a create retry after the first
    # create actually succeeded). Adopt the existing PR — parse its number and URL
    # from the error message and return a structured EXISTS outcome (success) so
    # the caller routes it to the normal CI-poll/park-with-pr path.
    if printf '%s\n' "$out" | grep -iE 'a pull request for branch .* already exists' >/dev/null; then
      url="$(grep -oE 'https?://[^[:space:]]+/pull/[0-9]+' <<<"$out" | tail -1 || true)"
      raw="$(grep -oE '/pull/[0-9]+' <<<"$out" | tail -1 || true)"
      pr_number="${raw#/pull/}"
      [ -n "$pr_number" ] || die "could not parse PR number from existing-PR error: $out"
      jq -cn --arg n "$pr_number" --arg url "$url" --argjson stripped "$stripped" \
        '{outcome:"EXISTS", pr_number:($n|tonumber), url:$url, surface_closes_stripped:$stripped}'
      return 0
    fi
    die "gh pr create failed: $out"
  fi
  # gh prints the new PR URL; take the last `/pull/<n>` reference in the output.
  raw="$(grep -oE '/pull/[0-9]+' <<<"$out" | tail -1 || true)"
  pr_number="${raw#/pull/}"
  [ -n "$pr_number" ] || die "could not parse PR number from gh output: $out"
  url="$(grep -oE 'https?://[^[:space:]]+/pull/[0-9]+' <<<"$out" | tail -1 || true)"
  jq -cn --arg n "$pr_number" --arg url "$url" --argjson stripped "$stripped" \
    '{outcome:"PR_OPENED", pr_number:($n|tonumber), url:$url, surface_closes_stripped:$stripped}'
}

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  scan)
    [ $# -eq 1 ] || usage
    cmd_scan "$1"
    ;;
  base-check)
    [ $# -eq 1 ] || usage
    cmd_base_check "$1"
    ;;
  rebase)
    [ $# -eq 1 ] || usage
    cmd_rebase "$1"
    ;;
  push)
    [ $# -ge 2 ] || usage
    wt_arg="$1"; branch_arg="$2"; shift 2
    force=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) force=1 ;;
        *) usage ;;
      esac
      shift
    done
    cmd_push "$force" "$wt_arg" "$branch_arg"
    ;;
  recover-probe)
    [ $# -eq 2 ] || usage
    cmd_recover_probe "$1" "$2"
    ;;
  open)
    cmd_open "$@"
    ;;
  acceptance-extract)
    [ $# -eq 1 ] || usage
    cmd_acceptance_extract "$1"
    ;;
  *) usage ;;
esac
