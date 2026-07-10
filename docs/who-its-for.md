---
title: Who this is for — the stranger this repo is built around
---

# Who this is for — the stranger this repo is built around

temperloop#136. This page defines **"the stranger"** — the concrete persona
every other doc in this repo, every process gate, and the docs-reviewer
agent (a later item) are written for and evaluated against. It is not
marketing copy: every claim below is a checkable trait, and a reviewer
should be able to hold a doc up against these personas and score whether it
still reads as written *for* the fit personas and *against* the non-fit
ones.

## Designed for

**A developer or small team running Claude Code-driven development who
wants org-grade process without an org.** Concretely, this reader:

- Drives most changes through Claude Code (or an equivalent agentic
  coding tool) rather than hand-typing every diff, and wants the process
  around those agent-driven changes to be as disciplined as a change a
  human typed by hand — protected `main`, tracked work, reviewable
  everything.
- Is one person or a handful of people, not a platform team with a
  dedicated release-engineering function — there is no one else to build
  the CI/branch-protection/merge-discipline scaffolding, so this repo's
  scripts and slash commands exist to *be* that scaffolding.
- Wants **parallel agents** to be safe to run — multiple workers on
  separate branches, isolated worktrees, a claim/lock mechanism — without
  hand-rolling that coordination themselves.
- Wants **everything reviewable**: every change lands as a PR against a
  protected `main`, gated by required CI checks, not a direct push nobody
  else (human or agent) can audit after the fact.
- Is on **GitHub, including the free plan** — a personal account or a free
  org, with no budget for GitHub Enterprise and no native merge queue
  available. This is not a footnote: `docs/managed-merge-queue.md` exists
  *specifically* for this reader — its whole premise is that a native
  merge queue is "only provisionable on an organization-owned repo on a
  paid plan," and the managed-merge fallback in `gate.sh` closes that gap
  so the same merge-gated ladder (`/build`, `/sweep`, the funnel merge
  tier) runs end-to-end on a repo that could never afford the platform
  feature.

If you recognize yourself here — solo or small-team, agent-driven, on free
or low-tier GitHub, wanting the discipline of an org without having one —
this repo's docs, scripts, and slash commands are written with you as the
reader.

## Explicitly not a fit

Each of these is a real, named way a reader can *look* similar to the
designed-for persona while actually wanting something this repo does not
provide. A doc that quietly assumes one of these readers' needs instead of
the designed-for reader's is out of scope for this repo, not a gap to
patch.

- **Chat-first / prompt-only workflows that don't want process.** Someone
  who wants to prompt an assistant and get a diff, with no branch, no PR,
  no gate, no review trail — the point of this repo is exactly the
  discipline that reader is opting out of. There is no "light mode" that
  strips the process and keeps the tooling; the process *is* the product.
- **Teams wanting a hosted service rather than a toolkit of readable
  scripts.** Everything here is plain, inspectable shell/Python run
  locally or in your own CI — there is no managed backend, no dashboard
  someone else operates, no account to sign up for beyond GitHub itself.
  A reader looking for a SaaS product to delegate this to instead of
  scripts they can read and modify is looking for something else.
- **Non-GitHub trackers.** The board adapter, the merge-gate scripts, and
  the issue-linkage conventions are built directly against GitHub Issues
  and Projects (or, on the issues-only backend, GitHub Issues alone) — not
  a tracker-agnostic abstraction. A team on Jira, Linear, GitLab, or any
  non-GitHub host would need to replace that whole layer, not configure
  it.
- **Anyone unwilling to adopt branch/PR discipline.** Protected `main` is
  **load-bearing, not optional** — the merge-gated ladder, the CI
  `checks` contract, and the managed-merge fallback all assume every
  change lands as a PR against a protected branch. A reader who wants to
  push straight to `main`, or disable branch protection "for now," has
  removed the one invariant the rest of the pipeline is built on top of;
  the tooling will not degrade gracefully for them, because there is no
  degraded mode — there is only the gate, on or missing.

## Using this as an evaluation lens

A doc, a slash command, or a generated page in this repo should read as
written *for* the designed-for persona above and should not silently
assume the needs of one of the not-a-fit personas — for example, a doc
that recommends pushing directly to `main` "to save time," or that assumes
a hosted dashboard exists, or that assumes a non-GitHub tracker, has
drifted from the audience this repo is built for. A docs-reviewer agent
(or a human reviewer) can use the two lists above as a checklist: does this
page hold up if the reader is the designed-for persona, and does it avoid
quietly catering to one of the four not-a-fit personas instead?
