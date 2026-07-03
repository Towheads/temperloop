"""sources/chapters.py - the "why" differentiation chapters (Epic C contract:
"3-4 curated failure-mode chapters, harvested from kernel-candidate-tagged
Decisions/Mistakes notes, scrubbed"). Building the harvest + scrub pipeline
is a SEPARATE item — this module only pins the glob convention the harvester
must write into so the docs generator can pick chapters up with zero coupling
between the two items' build order.

PINNED GLOB CONVENTION: `docs/failure-modes/*.md` (repo-root-relative).
Any Markdown file dropped there renders as one chapter page, sorted by
filename. The directory does not exist yet in this repo — that's expected
and NOT an error: glob() on a missing directory returns an empty list, so a
kernel-only checkout with no chapters authored yet builds a docs site with
zero chapter pages, no conditionals, exactly like the docs.d/ overlay
convention (see generate.py's module docstring). Once the harvester item
lands and starts writing files under docs/failure-modes/, they show up in
the next `make docs` run with no generator change required.
"""
from __future__ import annotations

from pathlib import Path

from lib.markdown_lite import render, split_frontmatter
from lib.page import Page

CHAPTERS_GLOB = "docs/failure-modes/*.md"


def build_pages(repo_root: Path, manifest_entries: list[tuple[str, str]]) -> list[Page]:
    del manifest_entries  # unused: chapters are curated straight into the pinned dir, not manifest-filtered
    pages: list[Page] = []
    for md_path in sorted(repo_root.glob(CHAPTERS_GLOB)):
        text = md_path.read_text(encoding="utf-8")
        doc = split_frontmatter(text)
        title = doc.fields.get("title") or md_path.stem.replace("-", " ").title()
        body_html = render(doc.body)
        pages.append(
            Page(slug=f"failure-modes/{md_path.stem}", title=title, body_html=body_html, nav_group="Failure modes")
        )
    return pages
