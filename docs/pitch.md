---
title: TemperLoop, in one page — what it does, who it's for, how to try it
---

# TemperLoop, in one page

The page to share with someone who has never seen this repo before.

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

Before anything below: `docs/cost-and-autonomy.md` covers real spend figures
per tier and exactly what an unattended run may do without asking — worth
two minutes first, especially before turning on anything that runs without
you watching.

**Evaluate it on your own code, in a repo you can delete.** Install the CLI
— see `bin/README.md`'s Install section for the exact command (an
inspect-first form and a one-line form, your choice) — then make a *private
duplicate* of a real repo of yours, copy a handful of your open issues into
it, and run the whole pipeline there:

```sh
gh repo create my-project-sandbox --private
git clone --bare git@github.com:me/my-project.git
git -C my-project.git push --mirror git@github.com:me/my-project-sandbox.git
```

A duplicate, not a fork: a fork of a public repo is forcibly public, and it
carries an upstream that PR tooling will offer as a base. A duplicate has
neither problem, and one `gh repo delete` ends it. Note that GitHub never
copies issues — to a fork or anywhere else — so bring yours across
explicitly.

Then `temperloop init` inside the sandbox, and run the **first epic** it
offers you through `/assess` → `/build`. That epic sets up review criteria,
a protected `main`, and required CI — genuine work with real dependency
levels, so watching it run shows you the whole machine (claim → worktree →
PR → CI → merge gate) on your own code rather than a canned example. When
you're convinced, run `temperloop init` in the real repo; when you're not,
delete the sandbox and nothing of yours was ever touched.

Full walkthrough with the exact commands, including the issue-copy loop and
teardown: the README's Quickstart, mirrored in `bin/README.md`.

## One more thing before you turn on anything unattended

TemperLoop has no billing of its own and runs no hosted service — an
unattended or scheduled run spends **your own** Claude account's budget,
the same as any session you'd run yourself. `docs/cost-and-autonomy.md`
(linked above) is the one place with the real numbers and the autonomy
contract; this page won't restate them.
