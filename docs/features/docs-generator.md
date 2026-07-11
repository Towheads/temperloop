---
title: Docs-site generator
slug: docs-generator
---

## Problem

Hand-maintained documentation drifts from the code or config it describes
the moment either one changes without a human remembering to update the
other — a page can go on claiming a command exists, or a gate runs, long
after either was removed. Without a generator, keeping a docs site honest
requires that manual synchronization step to happen every time, which is
exactly the kind of thing that silently stops happening.

## How it works

`generate.py` renders a self-contained static site straight from structured
sources already checked into the repo — there is no hand-maintained docs
source to fall out of sync:

- Command reference from `claude/commands/*.md`, filtered through the
  parsed `kernel-manifest.txt` so only `kernel`-classified commands render
  (an `overlay`-classified command like `standup`/`telemetry`/
  `signal-intake` is excluded automatically, with no per-command list to
  keep in sync by hand).
- The plan-note contract from `claude/plan-schema.md`.
- The quality-gate list from the live output of `scripts/quality-gates.sh
  --list`.
- Adapter contracts from the pinned glob `workflows/scripts/lib/
  *.contract.md` — one page per file found.
- Curated feature docs (`docs/features/*.md`) and ADRs (`docs/adr/*.md`),
  each a pinned glob rendered one-file-one-page into its own nav group.
  Neither directory needing to exist yet is not an error: `glob()` on a
  missing directory returns empty, so a checkout with none of either
  authored yet still builds cleanly with zero pages from that source.
- Curated failure-mode chapters from `docs/failure-modes/*.md`, same
  pinned-glob shape.

**Determinism.** The generator is stdlib-Python, zero-network,
zero-install: `lib/markdown_lite.py` is a hand-rolled Markdown-subset
renderer rather than a pip dependency, precisely so `make docs` can run as
a `checks` gate on a stock CI runner with no install step. It covers YAML
frontmatter, ATX headings, fenced code, block quotes, lists, horizontal
rules, paragraphs, and common inline spans — deliberately not a full
CommonMark implementation. The one subprocess call in the whole pipeline
(`sources/gates.py`, running `scripts/quality-gates.sh --list`) executes a
script already checked into the repo — no network fetch, no package
install. Output is **byte-deterministic**: the same source tree produces
the same rendered bytes, with one static file (`llms.txt`) copied verbatim
rather than passed through the render pipeline, since the
[llms.txt spec](https://llmstxt.org) requires it be served as its own
plain-text file at the site root. The rendered site is never committed —
`_site/` is gitignored, with only `_site/.gitkeep` tracked so the directory
exists in a fresh clone.

**Overlay drop-ins.** A downstream overlay adds pages with zero changes to
this generator by dropping modules into `workflows/scripts/docs.d/*.py` (a
sibling directory of `workflows/scripts/docs/`, the same shape as
`scripts/quality-gates.d/`). Each module must define `build_pages(repo_root)
-> list[Page]`; `generate.py` globs the directory in sorted order, imports
every module found, and unions every page returned onto the kernel site's
own pages and nav. A module present but missing `build_pages` is a hard
error — a broken drop-in fails loudly, it does not silently render nothing.
An absent `docs.d/` directory (the normal state of this still-unsplit
kernel checkout) yields exactly the kernel's own pages, no conditionals
required. The one instance of this convention today —
`workflows/scripts/docs.d/metrics.py`, rendering telemetry metric
docstrings — is itself overlay-only, since the rollup producers it reads
are themselves classified `overlay` in `kernel-manifest.txt`.

## Integration

Consumes: `claude/commands/*.md` + `kernel-manifest.txt`,
`claude/plan-schema.md`, `scripts/quality-gates.sh --list`,
`workflows/scripts/lib/*.contract.md`, `docs/features/*.md`,
`docs/adr/*.md`, `docs/failure-modes/*.md`, `llms.txt`, and any
`workflows/scripts/docs.d/*.py` overlay module present. Produces:
`workflows/scripts/docs/_site/` — a static directory tree servable by any
plain HTTP file server (root-relative links assume a server root; opening
`_site/index.html` directly via `file://` is not supported). Wired into
`scripts/quality-gates.sh` as the `make docs` `checks` gate entry — an
exception raised inside any `build_pages()` call fails that gate.

## Resource impact

Runtime: a stdlib walk and string-render over a handful of markdown/text
sources plus one `quality-gates.sh --list` subprocess call — sub-second on
this repo's current size, with no caching layer needed. Storage: the
rendered site is regenerated into `_site/` each run and gitignored, so it
never adds to repo size, only transient local disk. API/network budget:
zero — the generator makes no network call of any kind.

## Telemetry

None dedicated. Observable via `make docs`'s own exit code (non-zero on any
renderer exception) and the `test-docs-generator` unit-test suite; a stale
or missing page is caught by re-running `make docs` and diffing the
rendered output, not by a runtime metric.
