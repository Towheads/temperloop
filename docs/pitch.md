---
title: TemperLoop, in one page — what it does, who it's for, how to try it
---

# TemperLoop, in one page

This is temperloop in one page — what it does, who it's for, and how to try
it — for someone who has never seen this repo before.

## What it does

TemperLoop is a dev-process kernel for Claude Code–driven development: it
turns a GitHub issue tracker into a cross-session work queue, drives an
issue from triage through to a reviewed pull request using a small set of
Claude Code slash commands, and ships the install and quality-gate tooling
to get both running in a repo you already have. It is a toolkit — scripts, a
CLI, slash commands, and contract files you read — not a hosted service:
nothing here runs on someone else's servers, and there's no dashboard or
account beyond GitHub itself.

## Who it's for

Designed for a developer or small team who drives most changes through
Claude Code (or an equivalent agentic coding tool) and wants that work to be
as disciplined as a change a human typed by hand — protected `main`, tracked
work, everything reviewable — without a platform team on hand to build that
scaffolding. Concretely, this reader wants parallel agents to be safe to run
(isolated worktrees, a claim/lock mechanism), is on GitHub including the
free plan, and wants every change to land as a reviewed PR against a
protected branch, gated by required CI checks.

Not a fit: a chat-first, no-process workflow (prompt in, diff out, no
branch, no PR, no review trail); a team that wants a hosted service to
delegate this to rather than readable scripts they run themselves; a
non-GitHub tracker (Jira, Linear, GitLab); or anyone unwilling to adopt
branch/PR discipline — protected `main` is load-bearing here, not optional,
and there is no degraded mode that drops the process and keeps the tooling.
Full detail, including why each of these is a near-miss rather than a
straightforward exclusion: `docs/who-its-for.md`.

## How to try it

The zero-write path: install the CLI — see `bin/README.md`'s Install section
for the exact command (an inspect-first form and a one-line form, your
choice) — then, from inside any repo, run:

```sh
temperloop try
```

This runs a read-only conventions probe and a real classification pass over
your repo's own open issues, invoked with every tool disabled so it cannot
write anything — no `gh` mutation, no commit, no PR, either way. The next
step, `temperloop try --demo`, is the one mutating exception: a single real
issue-to-PR tick against a disposable, throwaway demo repo, never your own.
Full walkthrough, including what comes after (`temperloop init`, opting your
own repo in): `bin/README.md`'s Quickstart section.

## Before you run anything: what it costs

Unattended usage — the autonomous funnel driver, nightly `/tidy`, any
cron-style `claude -p` invocation — spends **your own** Claude account's
budget. TemperLoop has no billing of its own and runs no hosted service, so
an unattended run draws down your usage or API spend while you aren't
watching. Read `docs/cost-and-autonomy.md` before turning on anything
unattended: it has real cost bands per tier, states plainly whether a dollar
cap is on by default (yes for the onboarding tier, no beyond it), and spells
out exactly what an autonomous tier may do without asking versus what always
blocks for a human.
