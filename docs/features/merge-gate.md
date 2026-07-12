---
title: The merge gate — native and managed backends, ejection, and landed-merge confirmation
slug: merge-gate
---

## Problem

A build pipeline that opens pull requests automatically also has to land
them safely, and "safely" has two separate failure classes to avoid.

First, GitHub's native merge queue — the platform feature that lets a batch
of pull requests be queued for merge and re-validated against each other
automatically — is only provisionable on an organization-owned repository
on a paid plan. A personal account, or a free organization, can turn on
branch protection and required status checks, but cannot arm a merge queue.
A pipeline that assumes a native queue is always available simply doesn't
work on a free personal repository at all.

Second, whichever backend lands a merge, a merge *call* returning success
only means the merge was **initiated**, not that the code has actually
landed. Treating "merge requested" as "merge complete" — closing a tracking
issue, or moving a board card to done, on the strength of the API call alone
— can close out work against code that was never merged at all: the call
can be rejected, the PR can go stale and get closed without merging, or the
queue can simply take a while.

## How it works

`workflows/scripts/build/gate.sh` is the deterministic-spine script that
owns the level-boundary merge-gate steps of `/build`: reading a PR's live
mergeability, detecting whether the repo's default branch is under a
*strict* status-check requirement, computing a mechanical risk verdict over
a batch of PRs, queuing a merge, nudging a stale branch, and polling until a
merge is actually confirmed. It never decides *whether* to merge — the
go/no-go stays a human or orchestrator seat; `gate.sh` only executes the
mechanics once consent is given.

**The backend seam.** `gate.sh backend <owner>/<repo>` answers exactly one
question — does this repository have a native merge queue available —
without merging anything itself:

- `BUILD_MERGE_BACKEND` (default `auto`, in `build.config.sh`) can force
  `native` or `managed` outright, skipping the probe entirely.
- Under `auto`, the script probes the repository's branch ruleset for a
  `merge_queue` rule on the default branch. Finding one resolves to
  `NATIVE`; not finding one, or the probe itself failing (a `gh` error, a
  404, an empty response), resolves to `MANAGED`. This direction is
  deliberate: defaulting to `NATIVE` on an unreadable probe risks queuing a
  native `--auto` merge on a repo that turns out to have no queue armed at
  all (branch protection simply rejects it, loudly); defaulting to
  `MANAGED` on a queue-armed repo the probe merely failed to *see* is safe,
  because `MANAGED` never silently arms an auto-merge nobody chose — it
  just does a little more work by hand than strictly necessary. A
  `probe_failed: true` flag on the `MANAGED` outcome lets the caller tell
  "confirmed no queue" apart from "couldn't tell."

**Managed-merge mechanics and EJECTED semantics.** When the backend is
`MANAGED`, `gate.sh managed-merge <owner>/<repo> <pr>` replicates the native
queue's re-validate-then-land behavior per PR, in `--strict` mode by
default:

1. Fold the current default branch into the PR's head (`gh pr
   update-branch`) — the same re-test-against-current-tip a native queue
   performs before landing.
2. Resolve the **updated** head SHA — never poll a stale one, since the
   pre-update SHA's checks may already read green for code that is about to
   be superseded.
3. Poll that SHA's check-runs (again over REST, not the GraphQL-backed
   watch helper) until every run completes or the deadline passes.
4. **Green** → merge directly (not queued — mergeability was already
   established by the re-poll) and confirm. **Red** → the PR is `EJECTED`
   (a distinct outcome, exit code 5): no merge is attempted, and no
   plan-note sentinel or label is written, because consent and writeback
   both stay orchestrator-side. Ejection does not stop the rest of the
   batch — the caller moves on to the next PR and can return to the ejected
   one once its head is fixed. `--non-strict` skips the update-branch and
   re-poll entirely and merges directly, trading the extra CI run for a
   cheaper, less-revalidated merge.

**Landed-merge confirmation.** Both the native path (`gate.sh queue`, which
enqueues via the platform's own `--auto` merge, followed by `gate.sh poll`)
and the managed path's post-merge step confirm a merge the same way: poll
`gh pr view` until `state == "MERGED"` **and** a non-null `mergedAt` — the
sole success check. A `CONFLICTING` mergeable state or a `DIRTY`
merge-state status is treated as terminal-bad rather than retried
indefinitely; running out the poll's deadline is a distinct `TIMEOUT`
outcome. Because `MERGED` is checked directly rather than inferred from
"closed" or "checks green," a PR that gets closed without merging can never
be mistaken for landed work — closing a tracking issue or moving a board
card only happens after this confirmation, never on the strength of the
merge call alone.

## Integration

`/build`'s batch merge gate (`claude/commands/build.md`, the level-boundary
steps) is the sole caller: it reads each candidate PR's state with `gate.sh
read`, checks strictness with `gate.sh strict`, computes the batch's risk
verdict with `gate.sh risk` before asking for consent, and — once consent is
given — either queues a native merge (`gate.sh queue` + `gate.sh poll`) or
walks the batch through `gate.sh managed-merge` on the managed backend. The
sweep pipeline reuses the same script for its own per-fix merges. Poll
tunables (`GATE_CI_POLL_INTERVAL` / `GATE_CI_POLL_TIMEOUT`,
`GATE_MERGE_POLL_INTERVAL` / `GATE_MERGE_POLL_TIMEOUT`) live in
`build.config.sh` alongside every other build knob, so a slower or faster
poll cadence is a single config edit rather than a script change.

## Resource impact

Every read, poll, and merge call is a `gh` invocation against GitHub's REST
API — the same rate-limit bucket `ci-poll.sh` uses, kept deliberately
separate from the metered GraphQL budget shared with project-board
operations. A managed-backend merge costs one extra CI run per PR (the
SHA-pinned re-poll after the branch update) compared to a native-queue
merge, which is the price of replicating the queue's re-validation without
platform support for it. Polling wall-clock time is bounded by each
command's own timeout, so a stalled merge parks the run rather than
spinning forever.

## Telemetry

None as a dedicated stream — every `gate.sh` invocation emits one
structured JSON outcome line on completion, and that outcome *is* the
observable signal: an `EJECTED` result names the failed check-run IDs, a
`MERGE_REJECTED` result carries the platform's own rejection message, and a
`TIMEOUT` reports how long the poll waited. A merge that never confirms
`MERGED` shows up as a PR left open with no plan-note `[x]` sentinel, which
is the durable, at-a-glance signal that something needs attention.
