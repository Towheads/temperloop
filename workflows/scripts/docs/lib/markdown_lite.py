"""markdown_lite.py - a minimal, dependency-free Markdown-to-HTML converter.

The docs generator is stdlib-python, zero-network, zero-install (per its
acceptance bar) so it cannot pull in a real Markdown library (e.g. Python-
Markdown, mistune) via pip on a stock CI runner with no install step. This
covers the subset the three structured sources actually use: YAML
frontmatter, ATX headings, fenced code blocks, block quotes, unordered /
ordered lists, horizontal rules, paragraphs, and common inline spans (bold,
italic, inline code, links). It is intentionally NOT a general-purpose
CommonMark implementation — good enough for source-generated docs, not for
arbitrary user Markdown.
"""
from __future__ import annotations

import html
import re
from dataclasses import dataclass, field

_FENCE_RE = re.compile(r"^```\s*(\S*)\s*$")
_ATX_RE = re.compile(r"^(#{1,6})\s+(.*)$")
_UL_RE = re.compile(r"^[-*]\s+(.*)$")
_OL_RE = re.compile(r"^\d+\.\s+(.*)$")
_BLOCKQUOTE_RE = re.compile(r"^>\s?(.*)$")
_HR_RE = re.compile(r"^(-{3,}|\*{3,}|_{3,})$")

_INLINE_CODE_RE = re.compile(r"`([^`]+)`")
_BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")
_ITALIC_RE = re.compile(r"(?<!\*)\*([^*]+)\*(?!\*)")
_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")


@dataclass
class ParsedDocument:
    """A Markdown source split into optional YAML-ish frontmatter (raw text,
    NOT parsed as YAML — stdlib has no yaml module) and the body."""

    frontmatter: str | None
    body: str
    fields: dict[str, str] = field(default_factory=dict)


def split_frontmatter(text: str) -> ParsedDocument:
    """Split a leading `---`-delimited frontmatter block off the body. Does a
    light single-line `key: value` scan (good enough for `description:` /
    `argument-hint:` in claude/commands/*.md) rather than real YAML parsing —
    no stdlib YAML, and folded/multi-line YAML values are rare in these
    sources; a field that doesn't parse is simply omitted from `fields`."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return ParsedDocument(frontmatter=None, body=text)
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            fm_lines = lines[1:i]
            body = "\n".join(lines[i + 1 :])
            fields: dict[str, str] = {}
            for fm_line in fm_lines:
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", fm_line)
                if m:
                    fields[m.group(1)] = m.group(2).strip()
            return ParsedDocument(frontmatter="\n".join(fm_lines), body=body, fields=fields)
    # No closing delimiter found — treat the whole thing as body.
    return ParsedDocument(frontmatter=None, body=text)


def render_inline(text: str) -> str:
    escaped = html.escape(text, quote=False)

    # Protect inline code spans from further inline substitution by rendering
    # them last-in-first-out isn't needed here since code/link/bold/italic
    # patterns don't overlap meaningfully for this source corpus; simple
    # sequential substitution is sufficient for the "lite" bar.
    def _code(m: re.Match) -> str:
        return f"<code>{m.group(1)}</code>"

    escaped = _INLINE_CODE_RE.sub(_code, escaped)
    escaped = _LINK_RE.sub(lambda m: f'<a href="{m.group(2)}">{m.group(1)}</a>', escaped)
    escaped = _BOLD_RE.sub(lambda m: f"<strong>{m.group(1)}</strong>", escaped)
    escaped = _ITALIC_RE.sub(lambda m: f"<em>{m.group(1)}</em>", escaped)
    return escaped


def render(body: str) -> str:
    """Render a Markdown body (frontmatter already stripped) to an HTML
    fragment."""
    lines = body.splitlines()
    out: list[str] = []
    i = 0
    paragraph: list[str] = []
    list_stack: list[str] = []  # currently open list tag(s), e.g. ["ul"]

    def flush_paragraph() -> None:
        if paragraph:
            out.append("<p>" + " ".join(render_inline(p) for p in paragraph) + "</p>")
            paragraph.clear()

    def close_lists() -> None:
        while list_stack:
            out.append(f"</{list_stack.pop()}>")

    n = len(lines)
    while i < n:
        line = lines[i]

        fence_m = _FENCE_RE.match(line)
        if fence_m:
            flush_paragraph()
            close_lists()
            lang = fence_m.group(1)
            code_lines: list[str] = []
            i += 1
            while i < n and not _FENCE_RE.match(lines[i]):
                code_lines.append(lines[i])
                i += 1
            i += 1  # skip closing fence
            code = html.escape("\n".join(code_lines), quote=False)
            cls = f' class="language-{html.escape(lang)}"' if lang else ""
            out.append(f"<pre><code{cls}>{code}</code></pre>")
            continue

        if not line.strip():
            flush_paragraph()
            close_lists()
            i += 1
            continue

        atx_m = _ATX_RE.match(line)
        if atx_m:
            flush_paragraph()
            close_lists()
            level = len(atx_m.group(1))
            out.append(f"<h{level}>{render_inline(atx_m.group(2).strip())}</h{level}>")
            i += 1
            continue

        if _HR_RE.match(line.strip()):
            flush_paragraph()
            close_lists()
            out.append("<hr>")
            i += 1
            continue

        ul_m = _UL_RE.match(line)
        if ul_m:
            flush_paragraph()
            if not list_stack or list_stack[-1] != "ul":
                close_lists()
                list_stack.append("ul")
                out.append("<ul>")
            out.append(f"<li>{render_inline(ul_m.group(1))}</li>")
            i += 1
            continue

        ol_m = _OL_RE.match(line)
        if ol_m:
            flush_paragraph()
            if not list_stack or list_stack[-1] != "ol":
                close_lists()
                list_stack.append("ol")
                out.append("<ol>")
            out.append(f"<li>{render_inline(ol_m.group(1))}</li>")
            i += 1
            continue

        bq_m = _BLOCKQUOTE_RE.match(line)
        if bq_m:
            flush_paragraph()
            close_lists()
            out.append(f"<blockquote>{render_inline(bq_m.group(1))}</blockquote>")
            i += 1
            continue

        # Plain paragraph text.
        close_lists()
        paragraph.append(line.strip())
        i += 1

    flush_paragraph()
    close_lists()
    return "\n".join(out)


def render_markdown_file(text: str) -> tuple[ParsedDocument, str]:
    """Convenience: split frontmatter, render the body, return both the
    parsed frontmatter and the rendered HTML fragment."""
    doc = split_frontmatter(text)
    return doc, render(doc.body)
