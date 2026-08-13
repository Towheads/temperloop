---
title: Using the pipeline — the day-to-day operating guide
---

# Using the pipeline — the day-to-day operating guide

You've adopted temperloop (`temperloop init` has run in your repo, the
first epic has merged). This page is what running it day to day actually
looks like: which command to reach for, where the pipeline stops for your
approval, and what runs without you.

## Orient: "what do I do now?"

```
/next
```

`/next` reads the board and plan notes and recommends the single next
command — it never mutates anything. When in doubt, start here.

## The work loop

Work enters through two front doors and converges on the same machinery:

- **Discovered work** (issues already in your backlog): run `/triage`. It
  sweeps the backlog, culls what isn't worth doing, collapses duplicates to
  their root cause, groups related issues into **epics**, and leaves the
  rest as ready singletons. Nothing downstream re-decides what survives.
- **Invented work** (an idea born in conversation — "we should build X"):
  run `/workshop`. It walks the idea through a structured design
  conversation, you ratify the result, and it materializes the same epic
  shape `/triage` produces.

Then, for an epic:

```
/assess --epic <N>   # decompose into a dependency-ordered plan
/build               # execute the approved plan
```

`/assess` turns the epic into a plan of contract-scoped items grouped into
dependency levels, and shows you the structure before writing it. The plan
starts as a **draft** — `/build` refuses to run a draft, so nothing is
built until you approve the plan. That approval is the first of the two
places the pipeline always stops for you.

`/build` then runs a level at a time: each item gets its own isolated git
worktree, worker, branch, PR, and CI run. Items that are clean and disjoint
merge as they go green; anything risky or overlapping parks for a single
batched **merge gate** at the end of the level — the second standing stop.
You approve the set, not each PR.

For work that doesn't need an epic:

- `/sweep` drains the ready singletons `/triage` left ungrouped — it asks
  all its clarifying questions up front, then fixes each issue through the
  same per-item machinery.
- `/fix <issue-or-description>` drives exactly one named target to merged
  and closed. It's the right tool when you'd otherwise just start typing —
  the fix still gets a branch, a PR, CI, and issue linkage. It can also
  adopt an open PR that's stalled.

## The board is the shared memory

Every piece of work lives on the issue tracker, and the tracker doubles as
a cross-session lock. The bare commands (source in
`workflows/scripts/board/`):

```sh
worklist                  # what's In Progress, and which session owns it
claim 123                 # take an issue (the lock) — first action, always
release 123               # park it back out of In Progress
capture "Title of thing"  # file a new issue the moment you notice it
reconcile                 # fix board drift (closed issues still marked active)
```

Two habits make the whole thing trustworthy: **claim before you
investigate** (investigation is exactly the duplicate work the lock
prevents), and **capture, don't ask** (file a noticed defect immediately —
an end-of-turn "want me to file this?" dies with the session).

## The daily rhythm

- **Overnight, `/tidy`** (if you've scheduled it) drains the day's session
  learnings into durable notes and parks anything needing human judgment.
  It never blocks on a question.
- **In the morning, `/check-in`** shows the telemetry brief and everything
  the overnight machinery parked — decisions auto-taken with their
  defaults, flagged items, drift — and you dispose of the batch in one
  sitting, then set priorities that `/next` will honor.

## What runs without you

Nothing, by default. Two opt-in tiers (settings in
`workflows/scripts/build/build.config.sh`) run the pipeline on a timer once
you enable them: a safe tier that is structurally incapable of merging
code, and a merge tier that drives changes through the same gated `/build`
path you'd use yourself — where a clean, disjoint set can auto-merge after
a timed window, and anything risky always waits for you.
[`docs/cost-and-autonomy.md`](cost-and-autonomy.md) is the full contract;
read it before enabling either.

## The checkout commands

Day-to-day mechanics stay on `make`:

```sh
make quality-gates   # the exact static gate set CI's required job runs
make test-board      # board adapter test suite (no network)
make test-build      # build machinery test suite (no network)
make help            # everything else, one line each
```

Green locally means green in CI — both run the same
`scripts/quality-gates.sh`.

## On a shared repo: what your teammates inherit

Adopting temperloop is mostly personal — your install, your Claude budget,
your slash commands. Three things are *not* personal, and deserve a
conversation before you run `temperloop init` on a repo other people work
in:

- **Branch protection is a repo-wide setting.** The first epic sets up a
  protected `main` with required checks; that changes what *every*
  committer can do (no more direct pushes for anyone) and requires admin
  access to enable — and to undo. `temperloop eject` reverts `init`'s
  repo-tree changes but does **not** revert branch protection; that's a
  GitHub settings change you make yourself.
- **CI minutes come out of the shared allotment.** Every PR through the
  gate runs the required `checks` job at least once, and the managed merge
  queue's re-test adds one more run per PR — billed to the repo's own
  GitHub Actions quota, not to any one person.
- **Teammates who don't adopt it keep working normally.** A manual PR
  merges through the same branch protection as always — the managed queue
  only sequences the pipeline's own merges while a gate is running, and the
  board's namespaced labels appear only on issues the board commands touch.
  Nothing forces a teammate through the slash commands.

## Where to go deeper

- [`docs/features/`](features/) — one reference page per feature (triage,
  build machinery, merge gate, hooks, …), each opening with the problem it
  exists to solve.
- [`docs/architecture.md`](architecture.md) — the full map: pipeline flow,
  guard hooks, telemetry.
- [`docs/managed-merge-queue.md`](managed-merge-queue.md) — how merges work
  on a repo with no native merge queue.
- [`docs/token-spend.md`](token-spend.md) — keeping model spend down, and
  seeing where tokens went.

---

*Written by claude-fable-5 on 2026-08-13.*
