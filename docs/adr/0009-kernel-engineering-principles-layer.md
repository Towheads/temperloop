---
title: "0009: A kernel-level engineering-principles criteria layer, resolved point-of-use"
---

## Status

Accepted

## Context

epic: temperloop#599 (found by the K#598 embedded-opinions audit); umbrella
temperloop#419 (beta milestone)

A stranger's fresh install runs the `/assess`/`/build` review gates with
zero engineering criteria declared: a project's own principles section
(`Projects/<project>/Priorities.md` § Principles, falling back to the legacy
`Priorities/<project>.md`) starts empty, so a review agent has nothing
language-neutral to judge a diff against beyond "does it look reasonable,"
and a `/build` worker has no declared standard to write toward. The pipeline
advertises opinionated, review-gated development; without a shipped
criteria set, that opinion is decorative until an adopter writes their own —
which most never do, because authoring a principles document from scratch
is exactly the upfront cost a fresh install is trying to avoid.

Three alternatives were weighed:

1. **Docs-only** — write the seven principles into a stranger-facing doc
   page with no consumption seam into review or generation. Rejected: this
   reproduces the previously-recorded failure that declared principles are
   decorative without a consumption seam (a project's own principles once
   suffered exactly this before being wired into `/assess`/`/build`); a doc
   nobody's workflow reads is no better than no doc.
2. **Wait for beta-stranger evidence** before shipping anything. Declined:
   the gap is already structural and demonstrated by the K#598 audit — there
   is nothing more to learn from waiting that the audit didn't already show.
3. **Activate the existing per-language reviewer catalog instead**
   (`claude/agents/reviewers/*`, ADR-0007/0008) rather than add a new
   criteria file. Rejected as a substitute, though kept as a complementary
   layer: the catalog carries per-language review *procedure* — how a
   reviewer checks one language's idioms — not the cross-language
   *criteria* a reviewer judges any language's code against. Activating it
   alone would still leave zero criteria in force; the two layers answer
   different questions and neither redefines the other.

## Decision

Ship `claude/engineering-principles.md` as a **kernel-level criteria file**:
seven genericized, language-neutral engineering principles, each phrased as
a flaggable review criterion with a one-line rationale, resolved into the
effective review/authoring bar **at the point of use** rather than baked
into any one call site.

- **Kernel placement, stranger test.** The file ships in the kernel because
  every stranger's install benefits from having *some* declared criteria
  from day one, at zero configuration cost — the same reasoning that placed
  the language-reviewer catalog in the kernel (ADR-0007) rather than
  downstream.
- **Four-way surfaces relationship, stated once.** The file's own header
  states how it relates to three siblings so no two of the four talk past
  each other: `docs/principles.md` (the toolkit's own design charter — why
  the pipeline is built the way it is, not what adopter code should look
  like); this file (cross-language review/authoring criteria); a project's
  own `§ Principles` section (per-project extension or override); and the
  per-language reviewer catalog (procedure, consuming these criteria,
  never redefining them).
- **Both-active, single merge-semantics site.** The kernel set and a
  project's own `§ Principles` set are both in force — the effective
  criteria is their union, resolved fresh at each point of use, never
  cached across runs. The file's header is the **one place** this merge
  rule is stated: extend by default; `mode: replace` to swap the project's
  own set in wholesale; named exclusions to drop specific kernel
  principles; `none` to opt out entirely. Every call site that performs
  this merge implements the rule rather than restating it.
- **Advisory, not mechanical.** Every principle is a citable criterion, not
  a gate wired into `scripts/quality-gates.sh` or any other required
  `checks` entry. Turning a principle into an actual mechanical check is
  the adopter's own decision and cost to carry.
- **Content sourced from operator-validated project practice, genericized.**
  The seven principles were extracted from a real project's own quality
  bars, testing baseline, and AI-collaboration patterns, then stripped of
  project-specific and personal context to be language- and project-neutral
  — validated practice, not invented-from-nothing aspiration.

## Consequences

- The kernel now carries one more prose-only contract-surface file
  (registered in `VERSIONING.md`'s contract-surface table, additive —
  removing a shipped principle later would be breaking); it costs nothing
  at runtime beyond reading a small, static Markdown file per invocation.
- The generation/review consumption seams (`/assess` Step 3's principles
  load, `/build` 3e's reviewer feed, `/build` 3c's worker-prompt feed) are
  separate, independently-tracked plan items that implement — not
  re-derive — the merge semantics this ADR and the file's header establish.
- The per-language reviewer catalog (ADR-0007/0008) is unaffected and
  unchanged: it continues to own procedure, this file continues to own
  criteria, and neither has to be modified for the other to exist.
- Content fidelity to the source project practice is an operator sign-off
  item at the merge gate for the PR that lands this file, not a mechanically
  checkable property — a genericization pass is a judgment call the kernel
  cannot verify automatically.
