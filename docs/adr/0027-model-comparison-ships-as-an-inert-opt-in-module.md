---
title: "0027: model-comparison machinery ships as an inert, opt-in kernel module"
---

## Status

Proposed

## Context

epic: Towheads/temperloop#1225

The model-comparison harness has two halves with different stranger-test
standing. Per-seat attribution telemetry (ADR 0026) is uncontroversially
kernel: every adopter deciding model routing needs the evidence base, and it
costs nothing to carry. The comparison half — the replay runner that re-runs
closed issues under a candidate model, the judge pass, the comparison report —
is where the stranger test bites: a stranger with one default model and no
vendor ambitions arguably never needs head-to-head comparison machinery, which
suggests leaving it overlay-side. But overlay-side placement forces every
adopter who *does* need it to rebuild it, and splits one design across two
repos with a hoist step in between.

The kernel already has a shape for exactly this tension: the language-reviewer
catalog ships in every kernel install as inert source — present, documented,
zero standing cost — and does nothing until a repo opts in.

## Decision

The comparison half (replay runner, judge pass, comparison report) ships
kernel-side as an inert, opt-in module, the same shape as the language-reviewer
catalog: present as source in every kernel install, invoked only deliberately,
never on any default path. `/sweep`, `/build`, and `/fix` behave identically
until an operator points a candidate model at something. Replay batches are
operator-initiated only — the module adds no autonomous or cron arm. Which
candidate models and vendors an operator tests, and their keys, remain
overlay/operator configuration.

## Consequences

- One epic, one home: the design lands upstream in the kernel without a
  two-repo split or a later hoist.
- The stranger pays zero standing cost for the module existing; the adopter
  who needs comparison doesn't rebuild it.
- The replay runner is a new kernel component taking lineage — spawn/score/emit
  and rubric patterns — from foundation's `workflow-eval.sh`/`judge.py`, not a
  flag bolted onto them: those files are overlay assets absent from a
  kernel-only install, and the eval harness's shim-based isolation regime is
  deliberately incompatible with replay's real-remote reads.
- Uninstallability stays file-shaped: removal is deletion plus paired-registry
  cleanup, with no cron jobs or bin entry points to unregister, and — with the
  one scoped exception amended below — no hooks either.

## Amendment (2026-09-17, temperloop#2077): one marker-armed hook

The new-work dual-build harness (epic #2065) adds the module's **only** hook,
`claude/hooks/arm-read-guard.sh`, as a deliberate, scoped exception to the
"no hooks" consequence above. It is recorded here rather than left as a silent
divergence: that consequence was a commitment about what an adopter has to
unregister, and the exception belongs where the commitment is read.

**Why the exception is necessary, not merely convenient.** A dual-build level
builds one item twice, under two models, to compare them. If the candidate arm
reads the baseline arm's worktree or branch, every number downstream — judge
preference, item win, level pick — measures contamination instead of
capability, and nothing about it is visible after the fact: two independent
diffs and one copied diff are indistinguishable in the ledger. Isolation that
rests on a worker model's discretion is therefore unmeasurable, and the
`PreToolUse` seam is the only place a read can be refused before it happens.

**Why it does not reopen what this decision closed.** The standing cost this
ADR protects is the *stranger's*, and it stays zero: the hook is inert unless
the git worktree it runs in carries a `.dual-build-arm` marker, written by
`worktree.sh create --arm` for the duration of a dual build. No marker, no
effect — for every non-dual-build session in every adopting repo. It adds no
autonomous or cron arm; the module still runs only when an operator points a
candidate model at something.

**What it costs uninstallability, stated plainly.** For an adopter who
*registered* the hook, removal is deletion plus paired-registry cleanup plus
removing one matcher entry from the Claude Code settings file. Registration is
operator-side — this repo ships no tracked `settings.json` — so an adopter who
never registered it removes nothing extra, and one who did removes exactly the
line they added.
