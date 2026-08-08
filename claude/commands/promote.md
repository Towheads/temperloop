---
description: Carry work out of a `temperloop testbed` and into the real repository it was built from — as a branch of the testbed's OWN commits plus a pull request, with the issue correspondence and the API-state story reported separately and honestly. Runs INSIDE the testbed checkout; the real repository is always named, never inferred.
argument-hint: "--to <owner/repo> [--branch <name>] [--ref <ref>] [--dry-run]"
---

You are running the **promote** command. Goal: take work that a temperloop
evaluation produced inside a **testbed** — a private, disposable duplicate
`temperloop testbed` built (`docs/features/testbed.md`) — and land it in the
**real repository** the testbed was mirrored from, as a reviewable pull
request that carries the pipeline's actual commits.

`/promote` is the **judgment half** of a split capability. ADR 0023 puts the
mechanism in a script and the judgment in a slash command: deciding *which
work is worth promoting* is judgment and lives here; *carrying commits from
one repository to another without touching anything else* is mechanism and
lives in **`workflows/scripts/promote/push-testbed-branch.sh`**, which has its
own test suite. You **drive** that script — you never re-implement its git.

```
temperloop testbed   ── build the disposable evaluation copy
  /triage → /assess → /build   ── let the pipeline work inside it
    /promote          ── carry the good parts back out    ◄── you are here
```

## Inputs

- `--to <owner>/<repo>` (**required**) — the real repository to promote into.
- `--branch <name>` (optional) — the branch to create there. Default: propose
  `promote/<short-slug-of-the-work>` and confirm it with the operator.
- `--ref <ref>` (optional) — which testbed ref carries the work (default:
  `HEAD`).
- `--dry-run` (optional) — run every read and print the plan; **zero writes**.

## The working-directory contract — stated, because it departs from `/init`

**`/promote` runs INSIDE the testbed checkout, and reaches the real repository
through `gh` plus a fetched remote. It never infers *either* repository from
an ambiguous cwd.** Spell this out to the operator on every run; do not let it
be implicit.

This is a deliberate departure from `/init`'s precedent. `init` resolves *the
repository it is being run against* from its own working directory, which is
right for a command with exactly one repository in play. `/promote` has
**two** — the testbed you are standing in and the original you are promoting
into — and a cwd can only ever name one of them. So:

- **The testbed** is the checkout you are running in. Its identity comes from
  that checkout's configured `origin` remote (a recorded fact), not from the
  directory's name or its path.
- **The real repository** is whatever `--to` names. It is **never** derived
  from the testbed's name, from `origin`'s spelling, or from a parent
  directory. If `--to` is absent, **ask** — the artifact record's
  `source_repo` is a good *suggestion* to offer, never a silent default.
- **Reaching it** is `gh` (authentication, permissions, and the pull request)
  plus a **fetched git remote** (the objects). Nothing is resolved by
  filesystem proximity.

If you are not inside a testbed checkout, say so and stop. `/promote` is not a
general-purpose cross-repository push.

## Step 0 — Orient, and refuse early

1. Confirm you are in a git working tree and print its `origin`.
2. `gh auth status` — must succeed.
3. Read the artifact record for this testbed
   (`workflows/scripts/testbed/record.sh`, `testbed_record_list <owner/name>`).
   **The `source_kind` field is READ, never inferred.** A
   `materialize-from-seed` testbed is **refused**: its content was
   materialized from seed content tracked in the temperloop repository into
   the operator's own account (ADR 0025), so **there is no original to promote
   to** — say exactly that, and stop. A record whose `promotable` is `false`
   is refused on the same authority.
4. If `--to` was not given, ask for it (offering the record's `source_repo` as
   the suggestion), and get an explicit answer before going further.

Steps 0.3 and the whole of Step 1 are also implemented inside
`push-testbed-branch.sh` — running it is how you perform them, not a
duplicate check to hand-roll.

## Step 1 — Pre-flight, before anything is created

```sh
workflows/scripts/promote/push-testbed-branch.sh preflight \
  --to <owner>/<repo> --branch <branch> --testbed-dir . --testbed-ref <ref>
```

This is **all reads**. It resolves the testbed's identity, applies the
source-kind refusal, resolves the target's base branch **from the target
itself**, refuses a `--branch` equal to that base branch or one that already
exists there, and — the point of doing it here — checks the **access
precondition**: that your account may create and push a branch on the target.
That check belongs in pre-flight, not at failure time; if it fails, the script
refuses with the fork fallback spelled out (`gh repo fork <target>`, re-run
`--to <your-fork>`, open the pull request from the fork).

Surface its plan block to the operator verbatim. On `--dry-run`, stop here.

## Step 2 — Decide what is worth promoting

This is the judgment the split exists for, and it is yours, not the script's.
Read the testbed's merged work and separate it:

- work that is genuinely a fix or improvement to the **real** repository;
- work that is an artifact of the evaluation itself (temperloop's own config,
  a `.temperloop/` directory, board scaffolding) and should **not** cross over;
- work that is neither, and should simply be left in the testbed to be thrown
  away with it.

Present that split to the operator and get agreement on the set before
pushing anything. Promote in one branch per coherent change, not one branch
for "everything the testbed did".

## Step 3 — Carry the commits

```sh
workflows/scripts/promote/push-testbed-branch.sh push \
  --to <owner>/<repo> --branch <branch> --testbed-dir . --testbed-ref <ref> \
  --open-pr --pr-title "<title>" --pr-body "<what this is and why>"
```

Two properties this step owns, both structural rather than prose:

- **Real commits, not a rebuilt diff.** The testbed shares history with the
  original, so promotion adds the testbed as a remote, **fetches** its
  objects, and pushes them. Commit messages, parents, and **authorship**
  survive verbatim. It deliberately does **not** use
  `workflows/scripts/proposal/proposal-pr.sh`, which rebuilds a branch off the
  base tip from a JSON files manifest — correct for proposing a synthesized
  diff, and exactly wrong here, because it would squash away what the pipeline
  actually did into one commit authored by whoever ran the promotion.
- **Only the branch you named.** There is exactly one push, its refspec is
  always the explicit `refs/heads/<branch>` form, and the target's default
  branch is never a destination. That is asserted by the script's **own**
  test suite (`workflows/scripts/promote/tests/test_push_testbed_branch.sh`),
  not inherited from another script's guarantee.

Every pull request opened this way carries a **one-line provenance note** in
its body, appended by the script so it cannot be forgotten: a reviewer with no
context on this process can tell from the pull request alone that the commits
came out of a temperloop evaluation testbed. If you open a pull request by
hand instead, you carry that same line yourself.

## Issue correspondence

<!-- BEGIN: issue-correspondence — OWNED BY temperloop#1235 (promote-issue-correspondence).
     Edit only between these two markers; a sibling item owns the API-state
     section further down and the two must stay disjoint. -->

Placeholder. Copied issues carry a machine-readable
`copied from <owner>/<repo>#<N>` line stamped at copy time
(`workflows/scripts/testbed/source.sh`), and correspondence is resolved by
**exact lookup** on that line — never by title matching, ordering, or any
other inference — refusing or flagging rather than guessing when the line is
absent, malformed, or the body was edited. The mechanical half of that lookup
lands with its own script and its own tests in a later item; until then, do
not guess a correspondence: report the copied issue and the original by number
and let the operator confirm.

<!-- END: issue-correspondence -->

## Report the three operations as three different things

Promotion covers three operations that are **not** the same, and a uniform
"migration complete" claim is forbidden. Always report them separately:

| Operation | What actually happens |
| --- | --- |
| Tree changes and code fixes | **Carried.** Real commits, pushed as a branch, proposed as a pull request. |
| Issue correspondence | **Resolved by lookup**, or explicitly flagged as unresolved. Never inferred. |
| API state (protection, checks, labels, board) | **Not migratable.** See below. |

End every run by naming what was **migrated**, what must be **re-applied**,
and what is **left to you** — three lists, never one claim.

## API state

<!-- BEGIN: api-state — OWNED BY temperloop#1236 (promote-api-state).
     Edit only between these two markers; the issue-correspondence section
     above belongs to a sibling item and the two must stay disjoint. -->

Placeholder. Branch protection, required checks, labels, and board
configuration are GitHub API **state**, not tree state: they cannot ride a
pull request, so they are never "migrated". They are re-applied by running the
adopt path (`temperloop init`) in the real repository as its **own separately
consented step** — owning that apply here would bend ADR 0023's biconditional.
Diffing current-versus-proposed settings before anything acts, and leaving a
durable team-visible record in the repository afterwards, land with their own
script and tests in a later item. Until then, state plainly that API state was
**not** promoted and name the adopt path.

<!-- END: api-state -->

## Refusals, in one place

`/promote` refuses — legibly, naming the reason — when:

- the testbed's recorded `source_kind` is `materialize-from-seed`, or its
  record says `promotable: false` (there is no original to promote to);
- no artifact record for this testbed exists on this machine, so the
  source-kind check cannot run (`--allow-unrecorded` is the explicit, loud
  opt-out);
- `--to` is absent (the target is never inferred);
- the requested branch is the target's base branch, or already exists there;
- your account cannot create a branch on the target (the fork fallback is
  named in the refusal).

A refusal is a finished, useful outcome. Never route around one by pushing by
hand.
