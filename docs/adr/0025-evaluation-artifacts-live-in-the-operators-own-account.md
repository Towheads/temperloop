---
title: "0025: evaluation artifacts are materialized into the operator's own account from in-tree seeds; this project owns no external artifact"
---

## Status

Proposed

## Context

epic: Towheads/temperloop#1117

Evaluating this toolkit means watching the pipeline do real work — claim,
worktree, pull request, CI, merge gate — because no preview of a single stage
represents it. That requires a repository with real code and real issues in it,
and some readers will not point the toolkit at their own code the first time.

The retired `try --demo` served those readers by cloning a demo repository this
project owned and maintained, seeded by a generator kept in the tree. That shape
is the obvious one, and it has two defects that only appear later:

- **It is unreclaimable.** The repository lives outside the tree. No manifest,
  validator, or `git rm` retires it. Removing the feature leaves a live
  repository nothing in this codebase will ever notice again — the slow leak that
  the uninstallability discipline exists to prevent, arriving through a door that
  discipline does not watch.
- **It decays invisibly.** A shared, project-owned demo drifts from what the
  pipeline actually does, and the only thing that would notice is a human
  remembering to look.

A `docs/who-its-for.md` reader — one person, no platform team — has no
institutional memory to carry either liability.

The reflex when the leak was pointed out was to keep the owned repository and
*mitigate*: name it in one constant, write "archive this repo" into the feature
doc as a manual step. That is mitigation of a structural problem, and the design
was better served by removing the problem.

## Decision

**Any artifact this toolkit creates for evaluation purposes is materialized into
the operator's own account, from content tracked in this repository. This project
owns no repository, account, or remote artifact that an operator's own teardown
cannot reclaim.**

For the prepared-project case that motivated this: the seed is a fixture project
plus a set of issue definitions, tracked here as ordinary files. Selecting it
creates a private repository *in the operator's account*, populated from that
seed, torn down by the same teardown that removes any other evaluation
repository. The selection is a source option, not a second path.

Two obligations follow, and both are load-bearing rather than decorative:

- **Everything downstream of source selection is shared and proven shared.** The
  two sources differ only in how content and issues are produced; a test asserts
  an identical call sequence from that seam onward. Without it, "same path" is an
  intention, and a divergent second path is exactly how the retired demo became a
  dead end.
- **The guarantee is identical mechanism, explicitly not identical value.** The
  two sources differ in content, in what can be promoted afterwards, and in
  privacy exposure. Claiming more would be false, and a false invariant is worse
  than a precise one.

## Consequences

**The uninstall story becomes true rather than managed.** Removing the feature is
`git rm` plus the existing manifest validators. There is no external state, so
there is no manual step to remember and no artifact to strand.

**Seed content is fixture maintenance, and it will still rot.** A fixture that
teaches something today teaches less as the pipeline evolves, and no gate detects
that. This is not solved — it is *relocated* from an unreclaimable external
liability to an in-tree one that is at least reviewable in a diff and deletable
in a commit.

**CI inherits the rule, and did not automatically obey it.** The live round-trip
workflow that exercises the newcomer path against a project-owned repository is
now the remaining place where this project owns external state — each run must
create and delete a real repository in an account this project controls. The rule
applies there too: that workflow needs the deletion scope and an explicit
teardown leg, backed by the same created-artifact record, or the leak simply
moved from the design into CI. Naming this is the point — the rule is only worth
having if it is enforced where it is inconvenient.

**It constrains future capabilities.** Any later feature wanting a shared,
project-hosted resource for demonstration purposes is refused by this ADR unless
it can be materialized into the operator's account instead, or supersedes this
decision explicitly.
