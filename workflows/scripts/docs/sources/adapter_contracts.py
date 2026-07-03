"""sources/adapter_contracts.py - adapter-contract reference pages, rendered
from `workflows/scripts/lib/*.contract.md` (F#764 follow-on,
docs-adapter-metric-renderers item).

PINNED GLOB CONVENTION, mirroring sources/chapters.py: `workflows/scripts/
lib/*.contract.md` (repo-root-relative). Any interface-contract file dropped
there with that suffix renders as one page, sorted by filename — no
per-file registration needed here. Today that glob matches exactly one file,
`knowledge_store.contract.md` (the knowledge_store/knowledge_search
document-I/O + retrieval seam) - so this item renders exactly one adapter-
contract page. It deliberately does NOT render a tracker-contract page: no
stub, no hand-written prose substituting for the real interface file. The
tracker adapter contract is foundation #814, separate scope; once that item
lands a `workflows/scripts/lib/tracker.contract.md` (or similarly-suffixed)
file, this same glob picks it up on the next `make docs` run with zero
change to this module - the identical "pin the glob, let a later item fill
it" shape sources/chapters.py already established for the failure-mode
chapters.

Unconditionally kernel (see kernel-manifest.txt: `workflows/scripts/lib/*`
is kernel) so, like sources/plan_schema.py, no manifest filtering is
needed - every matched file renders as-is.
"""
from __future__ import annotations

from pathlib import Path

from lib.markdown_lite import render, split_frontmatter
from lib.page import Page

CONTRACTS_GLOB = "workflows/scripts/lib/*.contract.md"


def build_pages(repo_root: Path, manifest_entries: list[tuple[str, str]]) -> list[Page]:
    del manifest_entries  # unused: this source is unconditionally kernel
    pages: list[Page] = []
    for md_path in sorted(repo_root.glob(CONTRACTS_GLOB)):
        text = md_path.read_text(encoding="utf-8")
        doc = split_frontmatter(text)
        # Title from the file stem (e.g. "knowledge_store.contract" ->
        # "knowledge_store"), not the frontmatter (these interface files
        # carry none) - matches the seam's own name, not a hand-picked label.
        stem = md_path.name
        if stem.endswith(".contract.md"):
            stem = stem[: -len(".contract.md")]
        title = f"{stem} adapter contract"
        body_html = render(doc.body)
        pages.append(
            Page(
                slug=f"adapter-contracts/{stem}",
                title=title,
                body_html=body_html,
                nav_group="Adapter contracts",
            )
        )
    return pages
