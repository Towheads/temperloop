---
title: Branch hygiene
slug: branch-hygiene
---

# Branch hygiene

Branch cleanup for the protected-`main` / merge-queue workflow this repo's
build and sweep pipeline runs on: the remote-side half is a repo setting
honored by the merge queue itself, and the local-side half is
`scripts/prune-merged-branches.sh`, invoked either by hand or automatically
at session start on a managed checkout.

## Problem

The build/sweep pipeline creates one branch per work item and merges it
through a protected-`main` merge queue. Left unmanaged, this accumulates
branches in two places: remote head branches that were merged and are now
dead weight on the remote, and local branches on every dev machine that
checked one out (`git checkout -b`) and merged it through the queue. A
long-lived checkout that never prunes either class slowly fills `git
branch` / `git branch -r` output with noise that makes the genuinely active
branches harder to find, and — before the remote-side repo setting existed
— left a real backlog of stale pre-setting remote heads with no mechanism
to clear them at all.

## How it works

**Remote-side: `delete_branch_on_merge`.** The repo setting is enabled and
is honored by the merge queue specifically, not just an ordinary direct
merge — a head branch is deleted automatically the moment its PR merges
through the queue. This is the reason step 5 of the branch/PR flow omits
`--delete-branch` from `gh pr merge`: the queue rejects that flag outright,
because deletion is already the queue's own job once the merge lands. This
mechanism covers new merges going forward; it does nothing for branches
that already existed before the setting was turned on, and it never
touches any *local* checkout's branches at all — a repo setting has no way
to reach into a developer's machine.

**Local-side: `scripts/prune-merged-branches.sh`.** A repo-agnostic script
that reads whatever repo the current working directory belongs to and its
`origin/main` (or `--base <ref>`), so one script file serves every
checkout with no per-repo copy to keep in sync. It runs in three modes:

- **Dry-run (default, no flags).** Fetches `origin` with `--prune`, lists
  every local branch that qualifies as merged, and deletes nothing. Safe to
  run at any time to see what a real pass would do.
- **`--apply`.** Actually deletes the local branches the dry-run would have
  listed. Deletion defaults to `git branch -d`, which refuses to delete
  anything Git doesn't independently confirm is fully merged — the safety
  floor. `git branch -D` (force) is used only as a narrow fallback, for a
  branch the script's own merge-queue-aware detection has independently
  confirmed merged even though its tip is not a plain ancestor of `main`
  (the squash-merge and rebase-merge topologies a plain `git merge-base
  --is-ancestor` check misses) — never as a blanket override for an
  ordinary `-d` failure such as a branch still checked out in another
  worktree.
- **`--remote`.** Adds merged *remote* head branches to both the dry-run
  listing and (combined with `--apply`) the deletion pass — the mechanism
  that cleared the historical pre-setting backlog `delete_branch_on_merge`
  itself could never reach, since that setting only fires on merges that
  happen after it was enabled.

A branch qualifies as a merge candidate under either of two independent
checks: it's a plain ancestor of the base ref (no network call needed
beyond the initial fetch), or a separate merge-queue-safe helper confirms
its PR merged by checking PR state directly (falling back to a
cherry-pick-equivalence heuristic) even though the branch tip never became
an ancestor — the case a plain ancestor check misses for a squash- or
rebase-merged PR that went through the queue.

**Session-start sweep.** On a machine set up to run the pipeline
unattended, a session-start hook script brings every managed checkout
current: for each checkout that is on its default branch and clean (never
a checkout mid-work on a feature branch — that is skipped untouched), it
fast-forwards the branch, then runs `prune-merged-branches.sh --apply`
against that checkout, local-only (no `--remote` — remote heads are already
handled by the repo setting). This is what makes local pruning something
that happens automatically on a build machine rather than only when a
human remembers to run it by hand.

## Integration

`scripts/prune-merged-branches.sh` sources
`workflows/scripts/build/lib/merged-detect.sh` for the merge-queue-aware
detection helper, so the squash/rebase-safe check used here is the same
one the build worktree-cleanup path uses when deciding whether a
work-item worktree is safe to remove — one detection implementation, two
callers. `bash scripts/prune-merged-branches.sh` at the repo root is the
on-demand entry point for a human running the sweep manually (dry-run by
default; `--apply` to delete); the session-start hook is the equivalent
automatic trigger on a machine configured to run it, so
`scripts/prune-merged-branches.sh` run by hand is the off-machine or
on-demand lever, not the only way the sweep runs.

## Resource impact

Purely local Git housekeeping: `git branch -d`/`-D` on branches already
merged, and a `git fetch origin --prune` at the start of each invocation.
No GraphQL or REST budget is spent by the local-branch path; the
merge-queue-safe detection helper's PR-state check does call `gh pr view`,
which draws on GitHub's REST rate limit (a separate, much larger bucket
than the Projects-v2 GraphQL budget the board adapter shares), and only for
branches the plain-ancestor check didn't already resolve for free.

## Telemetry

None. The script's own stdout/stderr output (the dry-run listing, or the
`==> git fetch origin --prune` / deletion lines under `--apply`) is the
only observable surface — there is no separate metric stream. A regression
would show up as local branch counts creeping upward on a managed checkout
between session starts, or as a `--apply` run reporting an unexpected
failure to delete a branch it believes is merged.
