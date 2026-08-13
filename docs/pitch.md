---
title: TemperLoop, in one page — what it does, who it's for, how to try it
---

# TemperLoop, in one page

The page to share with someone who has never seen this repo.

## What it does

TemperLoop makes Claude Code work the way a good engineering team works:
agents pull tracked issues, build in isolated branches, and land every
change as a reviewed, CI-gated pull request — safe to run in parallel, even
unattended.

Concretely, it's three things working together: a **board adapter** that
turns plain GitHub Issues into a cross-session work queue and lock, a set
of **Claude Code slash commands** that carry an issue from triage to a
merged PR, and the **install and quality-gate tooling** to get both running
in a repo you already have. It is a toolkit — scripts, a CLI, slash
commands, and contract files you read — not a hosted service: nothing runs
on someone else's servers, and there's no dashboard or account beyond
GitHub itself.

## Who it's for

A developer or small team who drives most changes through Claude Code and
wants that work to be as disciplined as a change a human typed by hand —
protected `main`, tracked work, everything reviewable — without a platform
team to build that scaffolding. Concretely, this reader wants parallel
agents to be safe to run (isolated worktrees, a claim/lock mechanism), is
on GitHub including the free plan, and wants every change to land as a
reviewed PR gated by required CI checks.

Not a fit: a chat-first, no-process workflow (prompt in, diff out, no
branch, no PR, no review trail); a team that wants a hosted service rather
than readable scripts they run themselves; a non-GitHub tracker (Jira,
Linear, GitLab); or anyone unwilling to adopt branch/PR discipline —
protected `main` is load-bearing here, not optional. Full detail, including
why each of these is a near-miss rather than a straightforward exclusion:
[`docs/who-its-for.md`](who-its-for.md).

## How to try it

Before anything below: [`docs/cost-and-autonomy.md`](cost-and-autonomy.md)
covers what each step spends of your own Claude budget and exactly what an
unattended run may do without asking — worth two minutes first.

**You evaluate it on your own code, in a repo you can throw away — then
keep what it built.** Install the CLI (see [`bin/README.md`](../bin/README.md)
§ Install), then run one command from a checkout of the repo you want to
evaluate on:

```sh
temperloop testbed --dry-run   # preview: zero writes of any kind
temperloop testbed             # creates a private duplicate, mirrors the
                               # history, carries your open issues across
```

The testbed is a detached private duplicate, deliberately not a fork — a
fork of a public repo is forcibly public, and it carries an upstream that
PR tooling will offer as a base. A duplicate has neither problem, and
nothing you do in it can reach your real repo by accident.

Then `temperloop init` inside the testbed, and run the **first epic** it
offers through `/assess` → `/build`. That epic sets up review criteria, a
protected `main`, and required CI — genuine work with real dependency
levels, so watching it run shows you the whole machine (claim → worktree →
PR → CI → merge gate) on your own code rather than a canned example.

You don't throw the result away: `/promote` lands the work worth keeping in
your real repo as a branch plus a reviewable pull request, and
`temperloop testbed --teardown` reclaims the duplicate. When you're
convinced, run `temperloop init` in the real repo; when you're not, tear
the testbed down and nothing of yours was ever touched.

Full walkthrough with exact commands: the README's Quickstart.

## One more thing before you turn on anything unattended

TemperLoop has no billing of its own and runs no hosted service — an
unattended or scheduled run spends **your own** Claude account's budget,
the same as any session you'd run yourself.
[`docs/cost-and-autonomy.md`](cost-and-autonomy.md) is the one place with
the real numbers and the autonomy contract; this page won't restate them.

---

*Written by claude-fable-5 on 2026-08-13.*
