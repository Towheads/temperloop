---
title: Who this is for — the stranger this repo is built around
---

# Who this is for — the stranger this repo is built around

temperloop#136. **The stranger**: the concrete reader every doc, gate, and
persona-review agent here is written for and checked against — a checklist
of checkable traits, not marketing copy.

## Designed for

A developer or small team running Claude Code-driven development who wants
org-grade process without an org:

1. **Agent-driven, disciplined.** Drives most changes through Claude Code
   (or an equivalent agentic coding tool) and wants that work as
   disciplined as a change a human typed by hand — protected `main`,
   tracked work, reviewable everything.
2. **Small, no platform team.** One person or a handful of people, not a
   platform team with a dedicated release-engineering function — there's
   no one else to build CI/branch-protection/merge-discipline scaffolding,
   so this repo's scripts and slash commands exist to *be* it.
3. **Wants parallel agents to be safe.** Multiple workers on separate
   branches, isolated worktrees, a claim/lock mechanism — without
   hand-rolling that coordination themselves.
4. **Wants everything reviewable.** Every change lands as a PR against a
   protected `main`, gated by required CI checks — never a direct push
   nobody else (human or agent) can audit after the fact.
5. **On GitHub, including the free plan.** A personal account or free org,
   no budget for GitHub Enterprise, no native merge queue available —
   `docs/managed-merge-queue.md` exists specifically to close that gap so
   the same merge-gated ladder runs end-to-end here too.

## Explicitly not a fit

Each of these can *look* like the designed-for reader while actually
wanting something this repo doesn't provide. A doc that quietly assumes one
of these instead of the designed-for reader has drifted from its audience —
that's not a gap to patch.

- **Chat-first / prompt-only, no process.** Wants a diff with no branch, no
  PR, no gate, no review trail. There's no "light mode" that strips the
  process and keeps the tooling — the process *is* the product.
- **Wants a hosted service, not readable scripts.** Everything here is
  plain, inspectable shell/Python run locally or in your own CI — no
  managed backend, no dashboard, no account beyond GitHub itself. Looking
  to delegate to a SaaS product instead of scripts you can read and modify.
- **Non-GitHub tracker.** The board adapter, merge-gate scripts, and
  issue-linkage conventions are built directly against GitHub Issues and
  Projects (or Issues alone, on the issues-only backend) — a team on Jira,
  Linear, GitLab, or any non-GitHub host would need to replace the whole
  layer, not configure it.
- **Unwilling to adopt branch/PR discipline.** Protected `main` is
  load-bearing, not optional — the merge-gated ladder and the CI `checks`
  contract assume every change lands as a PR against it. Wanting to push
  straight to `main`, or disable branch protection "for now," removes the
  one invariant the rest of the pipeline is built on; there is no degraded
  mode, only the gate, on or missing.

## Using this as an evaluation lens

A doc, slash command, or generated page should read as written *for* the
designed-for reader above, never quietly catering to a not-a-fit one
instead (e.g. recommending a direct push to `main`, assuming a hosted
dashboard, assuming a non-GitHub tracker). A docs-reviewer agent or human
uses the two lists above as that checklist.
