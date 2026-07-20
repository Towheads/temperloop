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
doc covers the criteria file itself: its content, its header contract, and
its registrations. `docs/features/review-agents.md` documents the
per-language reviewer catalog that consumes these criteria as procedure.

**Uninstall / removal.** Deleting `claude/engineering-principles.md` removes
the kernel-side criteria entirely — a project's own `§ Principles` section
(which lives in the operator's priorities note, not in this repo) is
unaffected and continues to apply on its own. Removing the file also
requires deleting its entries in `workflows/scripts/kernel/kernel-manifest.txt`,
`docs/features/feature-manifest.txt`, and the `VERSIONING.md` contract-surface
table in the same change, so the manifest and versioning lints stay green
rather than pointing at a path that no longer exists.

## Resource impact

None beyond reading one small, static Markdown file. There is no generated
state, no cache, and no background process — a call site that resolves the
merge reads this file (and, optionally, a project's priorities note) once
per invocation.

## Telemetry

None. The file produces no append-only record of its own; its observable
effect is indirect, through whichever call site cites a principle in a
review finding or a worker's generation-time context.
