---
title: promote
slug: promote
---

## Problem

`temperloop testbed` builds a **private, disposable duplicate** of a repository
so an evaluation never creates branches, issues, or pull requests in the repo
you actually care about (`docs/features/testbed.md`). That solves the risk of
evaluating — and creates the next problem immediately: the pipeline's work is
now in a throwaway. If the only way to get a good fix out of the testbed is to
copy files by hand into the real repository, the evaluation produced a demo,
not work.

Getting it out is harder than it looks, in three separate ways that a single
"migrate" verb would quietly conflate:

- **Commits are transferable, and easy to lose.** A testbed *shares history*
  with the original, so the honest move is to carry the real commits across.
  The repo already has a tree-proposal generator
  (`workflows/scripts/proposal/proposal-pr.sh`) that looks like it fits — and
  does not: it rebuilds the branch off the base tip from a JSON files manifest
  (`:284`, guarded at `:265-266`), which would collapse the pipeline's commits
  and authorship into one synthetic commit attributed to whoever ran the
  promotion.
- **API state is not transferable at all.** Branch protection, required
  checks, labels, and board configuration cannot ride a pull request.
- **Issue correspondence is a lookup, and inviting to guess at.** A copied
  issue's link back to its original is a stamped provenance line, not a
  resemblance.

And one testbed must be refused outright: a `materialize-from-seed` testbed was
materialized from seed content tracked in this repository into the operator's
own account (ADR 0025), so there is **no original to promote to**.

## How it works

Two halves, split at the seam ADR 0023 draws: the CLI owns pre-checkout state
changes, and in-checkout, judgment-bearing work is a slash command.

### The judgment half — `/promote`

`claude/commands/promote.md` decides *which work is worth promoting*, reports
the three operations above as three different things, and refuses legibly. Its
working-directory contract is stated explicitly because it **departs from
`init`'s precedent**: `/promote` runs **inside the testbed checkout** and
reaches the real repository through `gh` plus a fetched remote. Two
repositories are in play, and a cwd can name only one, so the real repository
is always named by `--to <owner>/<repo>` and never inferred — from the
testbed's name, from `origin`'s spelling, or from a parent directory.

The spec carries two deliberately **bounded, non-adjacent** placeholder
sections — `## Issue correspondence` and `## API state`, each delimited by
`BEGIN:`/`END:` markers naming its owning issue and separated by a section of
real content. Two same-level sibling items each edit exactly one of them, so
their pull requests touch disjoint ranges of the same file.

### The mechanical half — `push-testbed-branch.sh`

`workflows/scripts/promote/push-testbed-branch.sh` is what makes the split
worth its interface: a script can be asserted against structurally, and a
prose step in a markdown spec cannot.

```sh
push-testbed-branch.sh preflight --to acme/proj --branch promote/the-fix   # all reads
push-testbed-branch.sh push      --to acme/proj --branch promote/the-fix --open-pr
```

Pre-flight is **all reads** and runs before anything is created: it resolves
the testbed's own owner/name from its configured `origin`, **reads** the
`source_kind` field out of the testbed artifact record
(`workflows/scripts/testbed/record.sh`) and refuses a `materialize-from-seed`
(or recorded `promotable: false`) testbed on the record's authority rather than
by inference, resolves the target's base branch **from the target itself**
(`git ls-remote --symref`), refuses a branch equal to that base or one that
already exists there, and checks the **access precondition** — that the account
may create and push a branch on the target — with the fork fallback spelled out
in the refusal rather than discovered when a push is rejected.

The push then runs in a **throwaway bare repository** under `$TMPDIR`: the
testbed is added as a remote *there* and fetched, so neither the testbed
checkout nor any checkout of the real repository has its remotes or `HEAD`
touched. A fetch transfers objects verbatim, so commit messages, parents, and
authorship survive — which is the whole reason promotion transfers objects
instead of replaying a files manifest.

**The refs guarantee is this script's own.** There is exactly one push in the
file and its refspec is always the literal
`refs/promote/source:refs/heads/<branch>` — never `--mirror`, `--all`,
`--tags`, a force push, or a bare `git push`. Its own suite
(`workflows/scripts/promote/tests/test_push_testbed_branch.sh`) asserts that by
logging every `git` invocation the script makes and reading the refspecs back
out of the log, plus the observable proof on a real local target repository:
the default branch's SHA is unchanged and the target ends with exactly its
default branch plus the promoted branch. That guarantee is proven here, not
inherited from `proposal-pr.sh`, because the two scripts use different
mechanisms.

Every pull request the script opens carries a **one-line provenance note**
appended to the body by the script itself — a caller-supplied `--pr-body` never
suppresses it — so a reviewer with no context on the process can tell from the
pull request alone where the change came from.

## Integration

- **Consumes** `workflows/scripts/testbed/record.sh` (the `source_kind` /
  `promotable` refusal) and the provenance line
  `workflows/scripts/testbed/source.sh` stamps into copied issues.
- **Does not consume** `workflows/scripts/proposal/proposal-pr.sh` — see
  above; the mechanisms differ, so the guarantees cannot be shared either.
- **Hands off to** `temperloop init` in the real repository for API state,
  as its own separately consented step.
- **Registries:** `claude/commands/promote.md` and
  `workflows/scripts/promote/**` are claimed here in
  `docs/features/feature-manifest.txt`, classified `kernel` in
  `workflows/scripts/kernel/kernel-manifest.txt`, and the command carries its
  `contributor-manifest.tsv` row. `/promote` is listed in README § 5's command
  map. CI growth is one suite — `make test-promote-push`, a `KERNEL_GATES`
  entry with its own `gate-paths.tsv` row.

## Resource impact

Zero background cost — `/promote` is an operator-initiated command that runs
only when invoked. A run costs a handful of `gh` reads (auth, repository
permissions), two `git ls-remote` probes of the target, one fetch of the
testbed's objects into a temp bare repository, one branch push, and optionally
one `gh pr create`. The temp workspace is removed on exit. No LLM call is made
by the script itself; the judgment half spends whatever the session spends
reading the testbed's work. CI growth is one hermetic, zero-network suite.

## Telemetry

None. `/promote` emits no counter, event, or dashboard field. Its durable trace
is the artifact it creates in the real repository — a branch and a pull request
whose body carries the provenance note — which is deliberately a **team-visible**
record rather than a private metric. The terminal output (the pre-flight plan
block, the pushed refspec, the pull-request URL) is the run's own legible
report.
