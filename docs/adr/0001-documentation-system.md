---
title: 0001: The documentation system
---

## Status

Accepted

## Context

Before the docs-site epic (temperloop#131, "Docs generated from source in
CI", and its sub-issues #132 "feature-doc coverage gate" and #133 "docs-site
rendering for feature docs and ADRs"), TemperLoop had no generated
documentation site and no mechanical guarantee that a feature's
documentation existed or stayed current with its code. A handful of
standalone hand-maintained files existed (`docs/architecture.md`,
`docs/principles.md`, `docs/config-precedence.md`,
`docs/managed-merge-queue.md`), but nothing enforced that a *new* piece of
kernel machinery shipped a doc at all, and nothing generated documentation
from the structured sources (command specs, the plan-note schema, the gate
list) that already exist in the repo and are liable to drift from
hand-written prose describing them.

This ADR documents the mechanism as it landed — not as originally planned —
verified against the merged code in this checkout: the generator
(`workflows/scripts/docs/generate.py` and its `sources/*.py` modules), the
coverage gate (`workflows/scripts/validate-feature-docs.sh`), and the two
registries it enforces (`docs/features/feature-manifest.txt`,
`docs/features/backfill-exempt.txt`). Per [ADR-0000](0000-adr-process.md),
this is a kernel-public decision (the mechanism strangers rely on to trust
that this repo's docs describe reality), and this file follows ADR-0000's
own four-section MADR-lite convention.

## Decision

### 1. The generated docs site (`make docs`)

`make docs` runs `python3 workflows/scripts/docs/generate.py`
(`Makefile:169-170`), a **stdlib-only, zero-network, zero-install** Python
script — `workflows/scripts/docs/lib/markdown_lite.py` is a hand-rolled
Markdown-subset renderer specifically so the generator needs no `pip
install` step on a stock CI runner. `generate.py`'s `_SOURCE_MODULES` list
(module docstring + `generate.py:104`) fixes the nav/build order:

| Page | Source | Renderer |
|---|---|---|
| CLI bootstrap + subcommand reference | CLI entrypoint | `sources/cli.py` |
| Command reference | `claude/commands/*.md`, filtered by `kernel-manifest.txt`'s `is_kernel()` | `sources/commands.py` |
| Plan-note contract | `claude/plan-schema.md` | `sources/plan_schema.py` |
| Quality gates | `scripts/quality-gates.sh --list` | `sources/gates.py` |
| Adapter contracts | `workflows/scripts/lib/*.contract.md` | `sources/adapter_contracts.py` |
| Failure-mode chapters | `docs/failure-modes/*.md` (pinned glob) | `sources/chapters.py` |
| Feature docs | `docs/features/*.md` (pinned glob) → nav group "Features" | `sources/features.py` |
| ADRs | `docs/adr/*.md` (pinned glob) → nav group "ADRs" | `sources/features.py` |

`sources/features.py` folds both curated-doc classes into one module
(temperloop#133's in-issue call: identical one-file-one-page rendering
shape, so one module with two glob constants — `FEATURES_GLOB` and
`ADR_GLOB` — and two loops, `_build_feature_pages()` /
`_build_adr_pages()`, rather than two near-duplicate files). Each Markdown
file under either pinned directory becomes one page, sorted by filename;
page title comes from frontmatter `title:` (fallback: the filename stem,
title-cased). Neither pinned directory existing yet is not an error —
`Path.glob()` on a missing directory returns empty, so a checkout with no
feature docs or ADRs authored builds a site with zero pages from this
module and no conditional in the generator. This ADR corpus is the first
content to populate `ADR_GLOB`.

An **overlay drop-in** convention (`workflows/scripts/docs.d/*.py`, each
defining `build_pages(repo_root) -> list[Page]`) unions in extra pages;
absent directory → zero extra pages. `llms.txt` is the one page that
bypasses the `Page`/`render_page` HTML-shell pipeline entirely — it is
copied byte-for-byte via `generate.py`'s `STATIC_COPY_FILES`, because the
[llms.txt spec](https://llmstxt.org) requires it served as plain text at
the site root.

Output is written to `workflows/scripts/docs/_site/` (gitignored, only
`.gitkeep` tracked — mirrors the `dashboard/index.html` precedent),
rewritten idempotently (`_write_site()` wipes then rewrites, so a page
whose source disappeared doesn't leave a stale orphan) and is
**byte-identical on an unchanged tree** across reruns — no wall-clock
timestamp anywhere in `lib/page.py`'s `render_page()`.

### 2. The two gates that block a merge

Both ride the existing `KERNEL_GATES` array in `scripts/quality-gates.sh` —
no separate CI job, no branch-protection reconfiguration — so they are part
of the one required `checks` status the kernel's branch/PR policy already
gates on:

- **`"make docs"`** (`scripts/quality-gates.sh`, docs-build gate comment)
  — build only, no publish step. A source break (a malformed
  `kernel-manifest.txt` line, an overlay `docs.d/*.py` drop-in missing
  `build_pages()`) raises inside `generate.py` and the gate fails.
- **`"bash workflows/scripts/validate-feature-docs.sh"`** plus its fixture
  suite **`"bash workflows/scripts/tests/test_validate_feature_docs.sh"`**
  — the feature-doc coverage gate, detailed next.

### 3. The feature-doc coverage gate

`workflows/scripts/validate-feature-docs.sh` enforces three registries in
one validator (its own header comment is the source of truth this section
transcribes):

- **`docs/features/feature-manifest.txt`** — the full-coverage path-claims
  registry. Each line is `<slug> <glob>` (`#`-comments and blank lines
  ignored). Every path `git ls-files` returns must be claimed by at least
  one glob; when several match, the **longest matching pattern wins**
  ("most specific wins" — the same walk `workflows/scripts/kernel/
  check-kernel-manifest.sh` already uses), so a narrow override entry can
  live anywhere in the file with no ordering fragility. The reserved
  pseudo-slug `none` claims repo meta that belongs to no single feature. A
  glob matching zero tracked paths is **legal and inert** — this is exactly
  how `docs/adr/*` was pre-claimed (`none docs/adr/*` at
  `feature-manifest.txt:46`) ahead of this ADR corpus landing, and how
  `kernel-manifest.txt:245` (`kernel docs/adr/*`) did the same for the
  kernel-classification manifest — **neither manifest needed editing to
  land this PR**; both entries already existed
  (verify: `grep -n 'docs/adr' workflows/scripts/kernel/kernel-manifest.txt
  docs/features/feature-manifest.txt`).
- **`docs/features/<slug>.md`** — one feature doc per non-`none` manifest
  slug, with five required, **non-empty** sections: `## Problem`,
  `## How it works`, `## Integration`, `## Resource impact`,
  `## Telemetry`. "None." must be stated explicitly — a heading present
  with no content beneath it still fails.
- **`docs/features/backfill-exempt.txt`** — the **shrink-only ratchet**.
  One manifest slug per line, excusing that slug **only** from the
  doc-presence check — path claims are *never* exempted, so the
  new-unclaimed-code guarantee is live from day one regardless of any
  exemption. When a slug's doc lands, its exemption line must be deleted in
  the *same* PR (a doc that lands without the deletion fails
  `EXEMPT-BUT-DOCUMENTED`). The file's own header states the rule
  explicitly: "Never add a line for new work — a new feature ships its doc
  with its code." A missing or empty file is the fully burned-down end
  state, not an error.

The validator's exact failure-mode vocabulary (`validate-feature-docs.sh`
header, all collected and reported together in one run rather than
fail-fast — the same `collect-all-failures` style as
`workflows/scripts/validate-live-drain.sh`):

| Code | Meaning |
|---|---|
| `UNCLAIMED` | a tracked path no manifest glob claims |
| `MISSING-DOC` | a non-exempt slug has no `docs/features/<slug>.md` |
| `MISSING-SECTION` | a required section heading is absent from a doc |
| `EMPTY-SECTION` | a required section is present but has no content |
| `ORPHAN-DOC` | a `docs/features/*.md` file's stem is not a manifest slug |
| `SLUG-MISMATCH` | frontmatter `slug:` doesn't match the filename stem |
| `STALE-EXEMPT` | an exemption names a slug the manifest no longer has |
| `EXEMPT-BUT-DOCUMENTED` | an exemption line survives after its doc landed |

The script is kept POSIX-bash-3.2-compatible (no `mapfile`, no associative
arrays) so it runs identically in the macOS dev shell and Linux CI, and
exposes an env-var override seam for its fixture suite
(`FEATURE_DOCS_ROOT`, `FEATURE_MANIFEST_FILE`, `FEATURE_EXEMPT_FILE`,
`FEATURE_DOCS_DIR`) mirroring `check-kernel-manifest.sh`'s
`KERNEL_MANIFEST_ROOT`/`_FILE` seam.

### 4. Migration path: ratchet to an unconditional coverage gate

The gate did not start by requiring every feature to already have a doc —
that would have blocked the epic on writing dozens of docs up front. It
instead landed as a **ratchet**, seeded full and draining over time:

1. **Seed (landed).** `docs/features/backfill-exempt.txt` was seeded with
   every pre-existing kernel-manifest slug that lacked a doc at the time
   the coverage gate landed, grouped into contiguous blocks — one block per
   planned backfill sub-issue (temperloop#138 board+branch-hygiene, #139
   build-spine/merge-gate/quality-gates, #140 triage/assess/sweep/next,
   #141 tidy/check-in/telemetry/funnel-driver, #142
   hooks/gh-perf/review-agents, #143
   install-cli/knowledge-store/docs-generator/presentation-plane) — so each
   backfill PR touches only its own block and the six can land in any
   order without conflicting on the same file. From day one, path-claim
   coverage (`UNCLAIMED`) was unconditional; only doc-presence
   (`MISSING-DOC`) was exempted, and only for the pre-existing backlog.
2. **Backfill (in progress).** Each of the six sub-issues writes the
   missing `docs/features/<slug>.md` files for its block and deletes that
   block's exemption lines in the same PR. The `EXEMPT-BUT-DOCUMENTED`
   failure mode makes forgetting the deletion a build failure, not a
   silent gap.
3. **Unconditional (not yet reached).** Once every exemption line is
   deleted — `docs/features/backfill-exempt.txt` reaches the same
   missing-or-empty state the validator already treats as "fully burned
   down," requiring **no code change** to recognize — doc-presence
   coverage becomes unconditional for every slug, present and future,
   exactly as path-claim coverage already is today. The ratchet's own rule
   ("never add a line for new work") means no future feature can reopen an
   exemption: from the moment the list empties, every new feature ships
   its doc with its code, with no transition period to design for.

This ADR's own corpus is a preview of that end state in miniature:
`docs/adr/*` was claimed `none` in the feature manifest (documentation
product, not one feature's code) rather than routed through the
doc-presence/exemption machinery at all — ADRs were never part of the
feature-doc backlog being drained.

## Consequences

- Documentation for the pieces this generator covers (commands, the
  plan-note schema, the gate list, adapter contracts, feature docs, ADRs)
  cannot silently drift from a structured source the way hand-written prose
  can, and both the build (`make docs`) and the coverage registries
  (`validate-feature-docs.sh`) are enforced on every PR via `KERNEL_GATES`.
- The ratchet is an explicit, visible, monotonic burn-down rather than an
  all-or-nothing requirement — but until the six backfill sub-issues land,
  doc-presence coverage is knowingly incomplete for the slugs still listed
  in `docs/features/backfill-exempt.txt` (path-claim coverage is complete
  today regardless).
- Per [ADR-0000](0000-adr-process.md), if this mechanism changes materially
  (e.g. a new registry, a changed failure-mode vocabulary, the ratchet
  reaching zero and the ADR's Phase 3 becoming actual history rather than a
  forward-looking commitment), that change gets a new ADR that supersedes
  this one's `## Status`, rather than a silent edit to this file.
