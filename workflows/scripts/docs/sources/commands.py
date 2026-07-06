"""sources/commands.py - command reference, rendered from claude/commands/*.md.

Kernel-manifest filtered: only commands the manifest classifies "kernel"
(assess, build, tidy, check-in, init, next, sweep, triage, funnel-drive,
funnel-drive-merge, as of this writing) render. Travis's personal rituals
(standup, telemetry, signal-intake) are "overlay" in
kernel-manifest.txt and are skipped with zero special-casing here — the
filter is the manifest, not a hardcoded list in this file.
"""
from __future__ import annotations

from pathlib import Path

from lib.kernel_manifest import is_kernel
from lib.markdown_lite import split_frontmatter, render, render_inline
from lib.page import Page


def build_pages(repo_root: Path, manifest_entries: list[tuple[str, str]]) -> list[Page]:
    commands_dir = repo_root / "claude" / "commands"
    if not commands_dir.is_dir():
        return []

    sections: list[str] = []
    for md_path in sorted(commands_dir.glob("*.md")):
        rel_path = md_path.relative_to(repo_root).as_posix()
        if not is_kernel(manifest_entries, rel_path):
            continue
        text = md_path.read_text(encoding="utf-8")
        doc = split_frontmatter(text)
        name = md_path.stem
        description = doc.fields.get("description", "")
        argument_hint = doc.fields.get("argument-hint", "")
        body_html = render(doc.body)

        sections.append(f'<section id="{name}">')
        sections.append(f"<h2>/{name}</h2>")
        if argument_hint:
            hint = render_inline(f"/{name} {argument_hint.strip(chr(34))}")
            sections.append(f"<p><code>{hint}</code></p>")
        if description:
            sections.append(f"<p>{render_inline(description)}</p>")
        sections.append(body_html)
        sections.append("</section><hr>")

    if not sections:
        return []

    body = "\n".join(sections)
    return [Page(slug="commands/reference", title="Command reference", body_html=body, nav_group="Reference")]
