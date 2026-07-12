---
title: ADR-0000 — Architecture Decision Records in this repo
---

# ADR-0000 — Architecture Decision Records in this repo

- **Status:** Accepted
- **Date:** 2026-07-11
- **Deciders:** kernel maintainers (temperloop#145, under epic temperloop#131)

## Context

This repo is the shippable **kernel** — the generic pipeline machinery a
stranger can clone and run with no personal overlay, no Obsidian vault, and no
org history. Historically every architectural decision was captured in the
maintainer's private vault under `Decisions/`, cross-linked with
`[[wikilink]]` references. That works for the operator, but it fails the
stranger: a kernel-public file that cites `[[Decisions/foundation - …]]`
points at a note the stranger will never have, so the rationale for a decision
that governs *their* checkout is a dangling link they cannot follow.

A public kernel needs a public, in-repo home for the decisions that govern its
own machinery — one that renders on the docs site (ADRs are a pinned source
class, `docs/adr/*.md`; see [ADR-0001](0001-documentation-system.md)) and
travels with the code that the decision constrains.

## Decision

Kernel-public architectural decisions are recorded as **ADRs** in
`docs/adr/`, in a **MADR-lite** format, under a fixed numbering and
supersession convention. A routing rule decides which decisions become ADRs
and which stay in the operator's vault.

### Format — MADR-lite

Every ADR is one Markdown file with, at minimum, these sections:

- **Status** — one of `Proposed`, `Accepted`, `Superseded`, `Deprecated`.
  A superseded ADR names its successor (see supersession below).
- **Context** — the forces at play: the problem, the constraints, and *why a
  decision is needed now*. State the situation, not the answer.
- **Decision** — what was chosen, stated in the active voice ("we record …").
  This is the durable contract a future reader is looking for.
- **Consequences** — what becomes easier and what becomes harder as a result,
  including the trade-off deliberately accepted. Honest about the cost, not
  just the benefit.

A `Deciders` line and a `Date` line sit at the top for provenance. The format
is deliberately *lite* — a short prose ADR beats a long templated one that
nobody writes. Sections beyond these four are allowed when a decision needs
them (e.g. "Alternatives considered"), never required.

Because ADRs render through the docs site's `markdown_lite` converter, they
use **headings, lists, code fences, block quotes, and inline spans only — no
Markdown tables** (the lite renderer does not support them). A single-line
`title:` frontmatter field sets the rendered page title; without it the title
falls back to the filename stem.

### Numbering & filenames

- Filename: `NNNN-kebab-case-title.md`, four-digit zero-padded sequence
  (`0000-adr-process.md`, `0001-documentation-system.md`, …).
- Numbers are **allocated in order and never reused**. A withdrawn or rejected
  proposal keeps its number and is marked `Status: Deprecated` / `Rejected`
  rather than deleted — the sequence is an append-only ledger, so a gap or a
  reused number would make the history ambiguous.
- `0000` is reserved for **this** meta-ADR: the process that governs all the
  others.

### Supersession

Decisions change. When a later ADR overturns an earlier one:

- The **new** ADR's Status reads `Accepted (supersedes ADR-NNNN)` and its
  Context links the old one.
- The **old** ADR's Status is edited to `Superseded by
  [ADR-MMMM](MMMM-…​.md)` — the old file is **kept**, not deleted, so a reader
  who followed an old link lands on a live page that forwards them to the
  current decision. Superseding is a link, never a deletion.

### Routing rule — ADR vs. vault

Not every decision belongs in an in-repo ADR. Route by the **stranger test**
(the same test that splits the kernel `CLAUDE.md` from its overlay):

- A decision a stranger's kernel-only checkout needs in order to understand or
  operate the shipped machinery — a board-adapter contract, a build/gate
  convention, a workflow seam, the documentation system itself — gets an
  **in-repo ADR** here. That is exactly the decision whose rationale a stranger
  would otherwise chase into a vault note that does not exist.
- A decision that is personal, org-specific, or tied to one machine's paths and
  credentials stays in the **operator's private vault** under `Decisions/`,
  where it always has.

When in doubt about a decision that concerns the kernel's *own* pipeline
machinery, default to an ADR — a public rationale nobody downstream reads costs
little; a dangling `[[wikilink]]` in a public file costs a stranger the "why".

## Consequences

- **Strangers can follow the "why".** A kernel-public decision now renders as a
  first-class docs-site page, no vault required. The dangling-wikilink failure
  mode for kernel-public rationale is closed at the source.
- **Two homes to keep straight.** Contributors must apply the routing rule when
  they capture a decision — an ADR for kernel-public machinery, the vault for
  personal/overlay rationale. The stranger test makes the call mechanical, but
  it is one more judgement at capture time.
- **The ledger is append-only.** Numbers are never reused and superseded ADRs
  are kept, so the corpus grows monotonically. That is the price of an
  unambiguous decision history and of never breaking an inbound link.
- **ADR-0001 follows this convention.** The first real ADR
  ([ADR-0001](0001-documentation-system.md)) is written in exactly this format
  and numbered per this rule — this meta-ADR is validated by its own first use.
