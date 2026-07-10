"""sources/features.py - curated feature docs AND architecture decision
records (ADRs), rendered from two pinned globs. temperloop #133 ("Docs-site
rendering for feature docs and ADRs"), a `chapters.py` clone for two new
curated doc classes rather than one.

PINNED GLOB CONVENTION, mirroring sources/chapters.py and
sources/adapter_contracts.py:

  - `docs/features/*.md` (repo-root-relative) -> nav group "Features".
  - `docs/adr/*.md` (repo-root-relative) -> nav group "ADRs".

Any Markdown file dropped in either directory renders as one page, sorted by
filename within its own group. Neither directory exists yet in this repo —
that's expected and NOT an error: glob() on a missing directory returns an
empty list, so a kernel-only checkout with no feature docs or ADRs authored
yet builds a docs site with zero pages from this module, no conditionals —
the same degrade-for-free shape as chapters.py. Once a later item starts
writing files under docs/features/ or docs/adr/, they show up in the next
`make docs` run with no generator change required.

ONE MODULE, TWO GLOBS (in-issue decision — #133 left "own module or folded
into a shared curated-docs source" open): feature docs and ADRs are both
small, curated, frontmatter-titled Markdown collections with no rendering
logic beyond "one file -> one page, sorted by filename" — identical shape,
just a different pinned directory and nav-group label. Folding them into one
module avoids two near-duplicate ~15-line files; each gets its own glob
constant and its own loop below so the two stay independently readable and
independently extensible (e.g. if ADRs later need decision-status parsing,
that grows inside `_build_adr_pages` without touching feature-doc
rendering).

Registry `.txt` files that a later item may write alongside the feature docs
under `docs/features/` (e.g. a feature-flag registry) are ignored for free —
`FEATURES_GLOB` is `*.md`, not `*`, exactly like chapters.py's own glob.
"""
from __future__ import annotations

from pathlib import Path

from lib.markdown_lite import render, split_frontmatter
from lib.page import Page

FEATURES_GLOB = "docs/features/*.md"
ADR_GLOB = "docs/adr/*.md"


def _build_feature_pages(repo_root: Path) -> list[Page]:
    pages: list[Page] = []
    for md_path in sorted(repo_root.glob(FEATURES_GLOB)):
        text = md_path.read_text(encoding="utf-8")
        doc = split_frontmatter(text)
        title = doc.fields.get("title") or md_path.stem.replace("-", " ").title()
        body_html = render(doc.body)
        pages.append(
            Page(slug=f"features/{md_path.stem}", title=title, body_html=body_html, nav_group="Features")
        )
    return pages


def _build_adr_pages(repo_root: Path) -> list[Page]:
    pages: list[Page] = []
    for md_path in sorted(repo_root.glob(ADR_GLOB)):
        text = md_path.read_text(encoding="utf-8")
        doc = split_frontmatter(text)
        title = doc.fields.get("title") or md_path.stem.replace("-", " ").title()
        body_html = render(doc.body)
        pages.append(Page(slug=f"adr/{md_path.stem}", title=title, body_html=body_html, nav_group="ADRs"))
    return pages


def build_pages(repo_root: Path, manifest_entries: list[tuple[str, str]]) -> list[Page]:
    del manifest_entries  # unused: both classes are curated straight into their pinned dirs, not manifest-filtered
    return _build_feature_pages(repo_root) + _build_adr_pages(repo_root)
