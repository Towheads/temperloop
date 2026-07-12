---
title: ADR-0001 — Documentation system: source-rendered site + coverage ratchet
---

# ADR-0001 — Documentation system

- **Status:** Accepted
- **Date:** 2026-07-11
- **Deciders:** kernel maintainers (temperloop#145, under epic temperloop#131)

This ADR follows the process defined in
[ADR-0000](0000-adr-process.md) — MADR-lite format, kernel-public routing.

## Context

The kernel ships as an open-source repo a stranger clones and runs. Its docs
therefore have to satisfy a reader who has none of the maintainer's context.
Two failure modes had to be designed out:

- **Hand-maintained docs drift.** A docs site edited by hand diverges from the
  code it describes the moment either changes independently. For a repo whose
  whole value proposition is *mechanically-enforced correctness*, hand-kept
  prose that silently lies is the wrong foundation.
- **Undocumented features accumulate silently.** Nothing stops a new feature
  from merging with no docs at all, and "we'll write the docs later" is how
  "later" never arrives. Coverage has to be *enforced*, and enforced in a way
  that lets an existing gap be paid down incrementally rather than blocking all
  work until every legacy feature is documented at once.

## Decision

The documentation system is **generated from source and gated in CI**, with a
**shrink-only ratchet** carrying the repo from its current partial coverage to
documentation-first, where every feature ships its doc with its code.

### Source-rendered, never hand-maintained

The docs site is built by a stdlib-only, zero-network, zero-install Python
generator at `workflows/scripts/docs/generate.py` (`make docs`). It renders a
fixed set of **source** classes into pages:

- the **command reference** from `claude/commands/*.md`,
- the **plan-note contract** from `claude/plan-schema.md`,
- the **quality-gate list** from `scripts/quality-gates.sh --list`,
- **adapter contracts** from `workflows/scripts/lib/*.contract.md`,
- **failure-mode chapters** from `docs/failure-modes/*.md`,
- curated **feature docs** from `docs/features/*.md` (nav group "Features"),
- **ADRs** from `docs/adr/*.md` (nav group "ADRs") — the class this file
  belongs to.

Each source is a pinned glob rendered one-file-one-page; a class whose
directory is empty degrades to zero pages with no conditional, so a
kernel-only checkout always builds. Rendering uses an in-repo `markdown_lite`
converter (headings, lists, fences, block quotes, inline spans — **no
tables**), so the generator pulls in no Markdown library and stays
install-free on a stock CI runner.

Publishing is a **separate** workflow, `.github/workflows/docs-pages.yml`,
which runs `make docs` on every push to `main` and deploys to GitHub Pages. It
is deliberately *not* the required `checks` status: a publish failure is
visible in the Actions tab but structurally cannot block a PR merge. (It is
gated behind the `DOCS_PAGES_ENABLED` repo variable until the repo goes public
and Pages is enabled.)

### The gates that block builds

Documentation *coverage* is enforced by
`workflows/scripts/validate-feature-docs.sh`, wired as a `KERNEL_GATES` entry
in `scripts/quality-gates.sh` (so it runs inside the required `checks` job).
It reads three registries under `docs/features/`:

- **`feature-manifest.txt`** — the full-coverage **path-claims** registry:
  `<slug> <glob>` lines under which **every git-tracked path must be claimed**
  by some feature slug (or the reserved pseudo-slug `none` for repo meta). The
  **longest matching glob wins** ("most specific wins"), so an override entry
  narrows a broader glob with no ordering fragility, and a glob that matches no
  tracked path yet is legal and inert — that is how a sibling PR pre-claims a
  path it will create later.
- **`<slug>.md`** — one feature doc per manifest slug, each carrying the five
  required, **non-empty** sections (below).
- **`backfill-exempt.txt`** — the **shrink-only ratchet**: slugs whose doc has
  not been backfilled yet.

The validator fails CI (collect-all-failures, one run surfaces everything) on:

- `UNCLAIMED` — a tracked path no manifest glob claims (**new unclaimed code**;
  this guarantee is live from day one and is never exempted),
- `MISSING-DOC` — a non-exempt slug with no `docs/features/<slug>.md`,
- `MISSING-SECTION` / `EMPTY-SECTION` — a required section absent, or present
  but empty,
- `ORPHAN-DOC` — a `docs/features/*.md` whose stem is no manifest slug,
- `SLUG-MISMATCH` — frontmatter `slug:` ≠ filename stem (or absent),
- `STALE-EXEMPT` — an exemption for a slug the manifest no longer names,
- `EXEMPT-BUT-DOCUMENTED` — an exemption line kept after the doc landed.

### Required feature-doc schema

Every `docs/features/<slug>.md` carries single-line `title:` / `slug:`
frontmatter (`slug:` must equal the filename stem) and these five sections,
each present and **non-empty** — an intentionally-absent value is stated as
`None.`, never implied by omission:

- `## Problem` — what this feature exists to solve.
- `## How it works` — the mechanism.
- `## Integration` — how it wires into the rest of the pipeline.
- `## Resource impact` — cost (GraphQL budget, CI time, disk, tokens).
- `## Telemetry` — what it emits, or `None.`

### Migration plan to documentation-first

The ratchet is how the repo crosses from partial to full coverage without a
big-bang docs sprint:

1. **Seed full.** `backfill-exempt.txt` is seeded with *every* currently
   doc-less slug, grouped by planned backfill sub-issue with comment
   separators so each backfill PR deletes only its own contiguous block (fewer
   cross-PR merge conflicts).
2. **Backfill drains it.** Each backfill PR writes a slug's doc **and deletes
   its exemption line in the same PR** — `EXEMPT-BUT-DOCUMENTED` fails
   otherwise, so the list can only shrink.
3. **The list reaches zero.** A missing/empty `backfill-exempt.txt` is the
   fully-burned-down end state, not an error.
4. **The gate is then unconditional.** With no exemptions left, every manifest
   slug must have its doc — coverage is total.
5. **New features are gated from day one.** The path-claims check is never
   exempted, so new code that claims no feature fails immediately; and a new
   slug ships its doc with its code (never a fresh exemption line — the ratchet
   only shrinks).

## Consequences

- **Docs cannot silently drift** from the sources they render, and no new
  feature merges without either its doc or (during migration) an explicit,
  shrinking exemption. The "docs later" gap is mechanically closed.
- **Legacy coverage is paid down incrementally.** The ratchet lets the repo
  adopt the gate today with real gaps outstanding, rather than blocking all
  work until everything is documented — while guaranteeing the gaps only ever
  decrease.
- **The doc format is constrained.** Feature docs and ADRs render through
  `markdown_lite`, so authors give up Markdown tables and full CommonMark in
  exchange for a zero-install, zero-network generator. For source-generated
  docs that trade is deliberate.
- **Publishing is decoupled from correctness.** Because the Pages deploy is not
  the `checks` gate, a broken publish never blocks a merge — but it also means
  a green PR does not prove the site published; that is watched in the Actions
  tab, by design.
- **Two registries to keep honest.** The manifest and the exempt list must
  track reality; the validator's `STALE-EXEMPT` / `ORPHAN-DOC` /
  `EXEMPT-BUT-DOCUMENTED` checks exist precisely because these registries would
  otherwise rot.

## Source

Describes the mechanism landed in temperloop#132 (coverage gate) and #133
(docs-site rendering of feature docs and ADRs), under the documentation-system
epic temperloop#131.
