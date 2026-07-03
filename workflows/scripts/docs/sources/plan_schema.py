"""sources/plan_schema.py - the plan-note contract, rendered from
claude/plan-schema.md. Unconditionally kernel (see kernel-manifest.txt) so
no manifest filtering is needed here — the whole file renders as one page.
"""
from __future__ import annotations

from pathlib import Path

from lib.markdown_lite import render
from lib.page import Page

SOURCE_REL_PATH = "claude/plan-schema.md"


def build_pages(repo_root: Path, manifest_entries: list[tuple[str, str]]) -> list[Page]:
    del manifest_entries  # unused: this source is unconditionally kernel
    source = repo_root / SOURCE_REL_PATH
    if not source.is_file():
        return []
    text = source.read_text(encoding="utf-8")
    body_html = render(text)
    return [Page(slug="plan-schema", title="Plan-note contract", body_html=body_html, nav_group="Reference")]
