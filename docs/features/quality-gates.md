---
title: Quality gates — one script both CI and a local run execute
slug: quality-gates
---

## Problem

A repository's continuous-integration job and a contributor's local
pre-merge check are, in principle, supposed to run the exact same tests
before anything lands on the default branch. In practice, that guarantee
tends to erode the moment the gate list is typed out more than once — once
in a CI workflow file, once in a project's own dev-workflow instructions,
maybe a third time in an automated build tool's own acceptance step. Each
copy drifts independently: a gate added to CI but not to the local list
means a contributor's "it passes locally" is not actually predictive of
what CI will do, and a gate added locally but never wired into CI means it
silently stops mattering. The failure is invisible until the day CI catches
something a local run swore was clean, and by then nobody can say which
copy was stale.

## How it works

`scripts/quality-gates.sh` is the single source of truth for the repository's
static, zero-network, repo-wide gate set. There is exactly one place the
list of gates is typed — every consumer runs *this script*, never a
hand-copied list of its contents, so "local gates mirror CI" is true by
construction rather than by three copies kept in sync through discipline.
Each entry is one full command line (almost always a `make` target); the
script runs every gate unconditionally — never stopping at the first
failure — and only exits non-zero at the end if anything failed, which
surfaces every broken gate in one run instead of one per CI restart.

**The kernel/overlay layering.** The gate set is two arrays unioned at run
time:

- `KERNEL_GATES` is typed directly in the script and covers exactly the
  suites a stranger's kernel-only install would have: board, build,
  install, hooks, PR-hygiene, and tidy mechanical-owner suites, none of
  which reference anything specific to a downstream fork's own private
  subject matter.
- `OVERLAY_GATES` starts empty and is populated only by sourcing every
  `scripts/quality-gates.d/*.sh` file present, in glob order. Each drop-in's
  only job is to **append** its own entries onto the array — never replace
  or reorder a sibling drop-in's entries — so more than one downstream
  contributor can extend the gate set without fighting over one shared
  file. An absent or empty `quality-gates.d/` directory (a genuine
  kernel-only checkout with no overlay) degrades to zero overlay gates with
  no conditional logic required anywhere in the script.

Gates run in `KERNEL_GATES` order followed by `OVERLAY_GATES` order, from
the repository root regardless of the caller's own working directory (a
build worker running from a throwaway worktree still resolves every `make`
target correctly). `--list` prints every gate's full command line prefixed
`[kernel]` or `[overlay]`, without running anything — useful for auditing
exactly what a run will execute before it executes it.

## Integration

The CI workflow's `checks` job (`.github/workflows/ci.yml`) runs one step:
`bash scripts/quality-gates.sh`. A contributor's local pre-merge check runs
the identical invocation. The automated build pipeline's own parent-side
acceptance step, before it will consider a plan item's changes ready to
merge, also shells out to this same script rather than re-implementing any
part of the gate list. Adding, removing, or changing a gate is a one-line
edit to this file (or to an overlay drop-in) and every one of those three
callers picks it up on their very next invocation, with nothing else to
update.

## Resource impact

Every gate is a fast, zero-network, repo-local check — test suites, static
lints, and validator scripts that read only the working tree, never call
out to a remote API, and never require a package install beyond what the
repository already vendors. Total runtime scales linearly with the number
of gates (today several dozen), each one independently isolated with no
shared fixture or generated artifact a later gate depends on, so gates can
be reordered or run in any order without changing which ones pass.
Overlay drop-ins add to this linearly as well — an overlay carrying no
drop-ins costs nothing beyond the one directory-existence check.

## Telemetry

None as a dedicated stream. The script's own stdout is the observable
surface: each gate prints a `=== <command> ===` banner as it runs, and a
failing run ends with an explicit `FAILED N/M quality gate(s)` summary
naming every gate that failed (not just the first) — that summary, and CI's
own red `checks` status derived from the script's non-zero exit, are how a
broken gate is noticed.
