---
title: Kernel engineering principles
slug: engineering-principles
---

# Kernel engineering principles

## Problem

Without a declared engineering bar, a review pass has nothing language-neutral
to judge a diff against beyond "does it look reasonable," and a `/build`
worker has no standard to write toward beyond "make it work." That gap is
worst for a stranger's fresh install: the pipeline advertises opinionated,
review-gated development, but the review runs with zero criteria until the
adopter writes their own — and most adopters never do, because writing a
principles doc from scratch is exactly the kind of upfront cost a fresh
install is trying to avoid. `claude/engineering-principles.md` closes that
gap by shipping a genericized, language-neutral set of engineering criteria
that applies with zero configuration and stays cheap to extend or override
per project.

## How it works

The file states seven criteria, each phrased as something a reviewer can
**flag** in a diff, paired with a one-line rationale: every meaningful
behavior tested for every state (no coverage-percentage gate); quality bars
strict from day one; deterministic tests over recorded fixtures, never
live-network; verify at the human-AI seam; counter AI failure modes
structurally; limit blast radius through boundaries; advisory over enforced
discipline. None of the seven is language-specific — each applies whether
the code under review is Python, Shell, Rust, or anything else.

The file's own header states, once, how it relates to three sibling
surfaces so none of the four talks past the others: `docs/principles.md` is
the toolkit's own design charter (why the pipeline is built the way it is,
not what the adopter's code should look like); this file is the
cross-language review/authoring criteria; a project's own `§ Principles`
section (in its priorities note) is a per-project extension or override of
the kernel set; and the per-language reviewer catalog
(`claude/agents/reviewers/*`) is procedure — *how* a reviewer checks a
language's own idioms — that consumes these criteria and never redefines
them.

**Both-active, one merge rule.** The kernel set here and a project's own
`§ Principles` set are both in force — the effective criteria a reviewer
judges against is their union, resolved fresh at the point of use, not
cached. This file is the single site that states how the two combine: a
project extends the kernel set by default, may declare `mode: replace` to
swap its own set in wholesale, may name specific kernel principles to
exclude, or may declare `none` to opt out of principles entirely. Any call
site that performs this merge implements the rule stated here rather than
restating it.

**Advisory, not mechanical.** Every principle is a criterion a reviewer can
cite, never a gate wired into `scripts/quality-gates.sh` or any other
required `checks` entry on its own account. Turning a principle into an
actual mechanical check (a linter rule, a CI gate, a pre-commit hook) is the
adopter's own decision and cost to carry — the kernel ships the bar, not the
enforcement.

## Integration

This file has no runtime code of its own — it is prose read by a call site
that resolves the merge described above and hands the resulting criteria to
a review agent or a `/build` worker as additional evaluation context. The
call sites that do this (a project's `§ Principles` resolution in
`/assess`'s planning pass and `/build`'s pre-push review and generation-time
worker prompt) are separate, independently-tracked plan items — this feature
doc covers the criteria file itself: its content, its header contract, its
registrations, and the first-epic flow that offers it to a fresh install
alongside the rest of the onboarding substrate.

### Reviewer-catalog cross-reference — WHAT vs. HOW

This file and the per-language reviewer catalog
(`claude/agents/reviewers/*`, documented in full in
`docs/features/review-agents.md`) are a deliberate split, not two
overlapping surfaces:

- **This file is WHAT.** The seven criteria above are cross-language: they
  state what a reviewer should flag in *any* diff, independent of the
  language it's written in. A review finding that cites principle 3
  ("deterministic tests over recorded fixtures") applies exactly the same
  way to a Python test suite, a Shell script's test harness, or a Rust
  crate's integration tests.
- **The catalog is HOW.** Each per-language rubric —
  `python-reviewer`, `shell-reviewer`, `typescript-reviewer`, `go-reviewer`,
  `rust-reviewer`, `java-reviewer`, `swift-reviewer` — is procedure: the
  concrete idioms and pitfalls to check *for that language specifically*
  (a Python mutable default argument, a shell quoting trap under `set -e`, a
  Rust borrow-checker smell). A catalog rubric **consumes** the criteria
  named here; it never states a competing cross-language principle of its
  own.

Keeping the split explicit is what stops the two surfaces from drifting into
each other over time — a language rubric that starts asserting its own
cross-language opinion, or a criterion here that starts prescribing a
single language's idiom, is the smell that the split has broken down. The
catalog is opt-in and inert-by-default (`docs/features/review-agents.md`
covers activation); this file's criteria apply regardless of which, if any,
catalog reviewers are active — the WHAT/HOW split holds even when the HOW
half isn't installed.

### The first-epic flow — principles as one of three onboarding concerns

A fresh install's `temperloop init` offers a pre-designed **first epic** —
"Set up `<project>` with temperloop"
(`claude/templates/first-epic-setup.md`, [ADR
0010](../adr/0010-onboarding-as-first-executed-epic.md)) — that drives real
work through the actual pipeline (`/assess --epic N` → `/build`) to
configure three onboarding concerns at once: this file's criteria, a
working GitHub branch/PR/merge substrate, and CI. Recording this project's
own `§ Principles` disposition is one of those three concerns, so its
consent posture is documented here as part of the criteria file's own
integration surface.

**Shape: interview-first → compose → disclose → apply.** Every question is
asked, and every write's consequence named, *before* any external write
happens; the answers across all three concerns compose into **one**
change-set confirmed **once**, as a whole; only then does the epic's own
items apply it across real dependency levels (`/assess`'s epic-decomposition
mode turns the template's `## Contract` directly into plan items, with zero
reshaping).

- **Interview.** The principles question (`first-epic-setup.md` § A1) asks
  whether the adopter has existing conventions (a CLAUDE.md, a style guide)
  to merge with the kernel set. An answer of "yes" is followed by the same
  three-way choice this file's own merge semantics define: **extend**
  (default — add the kernel set to theirs), **replace** (`mode: replace` —
  drop the kernel set, use only theirs), or **exclude** specific named
  kernel principles while keeping the rest. An answer of "no existing
  conventions" offers a plain adopt-as-is. The GitHub-integration and
  CI-integration questions (branch protection, auto-delete, merge queue,
  `checks` workflow) are separate concerns asked in the same interview, each
  priced by an upfront probe (admin rights, `gate.sh backend`'s queue
  verdict) so a question is never asked as if it were free when it isn't.
- **Compose and disclose.** All three concerns' answers merge into one
  change-set shown back to the adopter in full before anything applies. The
  principles half never needs the structural-congruence rules the GitHub/CI
  half does (there is no "required status with no producer" failure mode
  for a `§ Principles` write), so this concern rides the composed
  confirmation for consistency of experience, not because it shares that
  failure mode.
- **Apply.** Once confirmed, `/build` drives the epic's items across real
  dependency levels. The principles disposition lands at **L0** — the
  earliest level, since it touches only the adopter's own repo files and
  runs regardless of what the GitHub/CI answers were.
- **Decline floors.** Declining the whole epic still runs the inline
  principles interview alone (the same A1 question, asked directly by
  `temperloop init` rather than through the epic) and records whichever
  disposition the adopter picks into `Projects/<project>/Priorities.md`'s
  `§ Principles` section — or, if that too is declined, writes nothing at
  all. Either way, the kernel default in this file still applies at the
  review call sites' point of use: declining costs the adopter only the
  *recorded* choice, never the criteria themselves. This is the
  **non-admin-safe** floor — unlike the GitHub-integration concern (which
  degrades to an admin packet when the adopter lacks repo-admin rights),
  the principles concern needs no elevated rights at all, so it never
  degrades and always completes in full, admin or not.

### Uninstall / removal — kernel-side and adopter-side, separately

Two different pieces of state exist here, and they are removed by two
different, independent paths:

- **Kernel-side: this file itself.** Deleting
  `claude/engineering-principles.md` removes the kernel-side criteria
  entirely — a project's own `§ Principles` section (which lives in the
  operator's priorities note, not in this repo) is unaffected and continues
  to apply on its own. Removing the file also requires deleting its entries
  in `workflows/scripts/kernel/kernel-manifest.txt`,
  `docs/features/feature-manifest.txt`, and the `VERSIONING.md`
  contract-surface table in the same change, so the manifest and versioning
  lints stay green rather than pointing at a path that no longer exists.
- **Adopter-side: the first-epic flow's own writes.** Everything the first
  epic (or its decline path) writes belongs to the adopter's own repo, not
  to this one, and each has its own undo path — none of it is silently
  irreversible:
  - **The recorded `§ Principles` disposition** — delete or edit the
    `## Principles` section in `Projects/<project>/Priorities.md` (or the
    legacy `Priorities/<project>.md`) directly; the point-of-use kernel
    default in this file still applies once that section is gone or empty.
  - **Branch protection** — unprotect the default branch (repo Settings →
    Branches → remove or edit the protection rule) to allow direct pushes
    again.
  - **The scaffolded CI workflow** — delete the generated GitHub Actions
    workflow file (and un-require its `checks` status from the branch
    protection rule in the same change, so a required status is never left
    with no producer).
  - **The merge-queue disposition** — disable the native merge queue from
    repo Settings, or flip `BUILD_MERGE_BACKEND` back off `managed` to stop
    treating the managed-merge fallback (`docs/managed-merge-queue.md`) as
    the active backend.

  None of this state is tracked by any kernel-repo manifest — it is the
  adopter's own repo content from the moment it's written, exactly like any
  other change their own PRs make, so undoing it is an ordinary settings
  change or file edit in their own repo, not a kernel operation.

## Resource impact

None beyond reading one small, static Markdown file. There is no generated
state, no cache, and no background process — a call site that resolves the
merge reads this file (and, optionally, a project's priorities note) once
per invocation. The first-epic flow's principles interview adds no ongoing
cost either: it is a one-time, adopter-elected read of this file plus a
single append or write to the project's own priorities note, never a
background process or a per-invocation cost on top of the merge above.

## Telemetry

None. The file produces no append-only record of its own; its observable
effect is indirect, through whichever call site cites a principle in a
review finding or a worker's generation-time context. The first-epic flow
likewise emits no dedicated telemetry stream for the principles concern —
its only durable trace is the `§ Principles` section it writes (or doesn't,
on decline) into the project's own priorities note.
