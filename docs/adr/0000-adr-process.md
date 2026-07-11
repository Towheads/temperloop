---
title: 0000: The ADR process (MADR-lite)
---

## Status

Accepted

## Context

Kernel-public architectural decisions — the "why" behind the board adapter,
the build/sweep pipeline, install/doctor, quality gates, the docs generator,
and similar kernel machinery — have so far only been captured in the
operator's private Obsidian vault (`Decisions/`, per `claude/CLAUDE.md`
§ Decision capture). That works for the operator, but a stranger who clones
only this kernel repo (the audience `claude/CLAUDE.kernel.md` § Kernel vs
overlay routing rule calls "the stranger test") has no way to read that
vault — code comments and commit messages that reference a
`[[Decisions/...]]` wikilink dangle for them. temperloop#145 introduces an
in-repo Architecture Decision Record (ADR) corpus, rendered on the generated
docs site, so kernel-public rationale is readable by every reader of this
repo, not just the operator. This ADR is 0000: it defines the process the
rest of the corpus (starting with
[ADR-0001](0001-documentation-system.md)) follows.

The format below is a deliberately reduced subset of
[MADR](https://adr.github.io/madr/) (Markdown Architecture Decision
Records) — "MADR-lite": the four sections MADR treats as closest to
mandatory, none of MADR's optional scaffolding (a dedicated "Considered
Options" table, "Pros and cons of the options" subsections, decision-driver
lists) required as its own heading. An ADR is free to discuss alternatives
and trade-offs in prose inside `Context` or `Decision` — it just isn't
required to structure them as separate headings.

## Decision

**Format.** Every ADR file has exactly four top-level (`##`) sections, in
this order, and no other required top-level section:

1. `## Status` — one of `Proposed`, `Accepted`, `Superseded by ADR-NNNN`,
   `Deprecated`.
2. `## Context` — the forces at play: what problem this decision addresses,
   what prompted it, what a reader needs to know to evaluate it.
3. `## Decision` — what was decided, stated plainly enough that a reader can
   act on it without re-deriving it.
4. `## Consequences` — what follows: benefits, costs, follow-on work, and
   anything the decision knowingly leaves unresolved.

**Numbering.** ADRs are numbered with a four-digit, zero-padded, strictly
increasing integer starting at `0000`, one number per ADR, never reused —
even if the ADR is later superseded or judged wrong in hindsight. The
filename is `docs/adr/NNNN-kebab-case-title.md`; `NNNN` is assigned at
PR-creation time as the next unused integer. This document is `0000`
because it is the first ADR in the corpus and defines the process every
later `NNNN` follows.

**Supersession.** When a later decision replaces an earlier one:

- The **old** ADR's `## Status` is edited to `Superseded by ADR-NNNN`
  (a plain markdown link to the new file, e.g.
  `Superseded by [ADR-0004](0004-....md)`).
- The **new** ADR's `## Context` names what it supersedes, linking back to
  the old file.
- The old file is **never deleted or renumbered** — it stays in place as a
  historical record of what was decided and why, even after superseded.

**Routing rule: which decisions get an ADR, and which stay in the vault.**
This applies the same stranger test `claude/CLAUDE.kernel.md` § Kernel vs
overlay routing rule already applies to standing rules, to decision records
themselves:

- **Kernel-public** — a decision a stranger's fresh clone of this kernel
  repo needs the rationale for, to understand why the kernel machinery
  (board adapter, build/sweep pipeline, install/doctor, quality gates, the
  docs generator itself) is shaped the way it is — gets an **in-repo ADR**
  under `docs/adr/`.
- **Personal / overlay** — a decision tied to the operator's machine,
  personal Obsidian vault structure, org-specific process, or a downstream
  repo not vendored into this one — stays in the operator's **private
  vault** under `Decisions/`, exactly as before this ADR corpus existed.
- When genuinely ambiguous, default to an in-repo ADR: the cost of an ADR a
  downstream adopter never reads is low; the cost of kernel-public rationale
  trapped in a vault a stranger can't open is a dangling reference.

**Rendering.** ADRs render on the generated docs site automatically, with no
generator change required to add one: `docs/adr/*.md` is a pinned glob
(`ADR_GLOB` in `workflows/scripts/docs/sources/features.py`,
`_build_adr_pages()`), rendered under the nav group **"ADRs"**. Page title
comes from the file's frontmatter `title:` field (as this file and
[ADR-0001](0001-documentation-system.md) both set); if a file omits it, the
generator falls back to the filename stem, title-cased. Drop a new
`docs/adr/NNNN-....md` file and it appears in the ADRs nav group on the next
`make docs` run.

**Manifest registration.** Because `docs/adr/*` is documentation product
(not a single feature's code) and stranger-facing (kernel, not overlay), it
must be claimed in both governance manifests before or in the same PR that
adds a file under the directory:

- `workflows/scripts/kernel/kernel-manifest.txt` — `kernel docs/adr/*`
- `docs/features/feature-manifest.txt` — `none docs/adr/*`

Both entries were pre-claimed by temperloop#147's sibling-PR pre-claim
(inert until a tracked path exists under the glob) ahead of this ADR corpus
landing, so this PR needed no manifest edit — verified in
[ADR-0001](0001-documentation-system.md) § Decision.

## Consequences

- Kernel-public decisions get a rendered, versioned, in-repo record that
  ships with the code it explains, covered by the same `make docs` build as
  every other generated page — no dangling `[[wikilink]]` into a vault a
  stranger can't read.
- There are now two decision-recording surfaces (in-repo ADR vs. operator
  vault) instead of one; the routing rule above is the bright line that
  keeps that from being a source of confusion, mirroring the existing
  kernel/overlay routing rule for standing rules.
- [ADR-0001](0001-documentation-system.md) is the first ADR written under
  this process, and documents the documentation system — including this ADR
  corpus itself — that temperloop#145 adds.
