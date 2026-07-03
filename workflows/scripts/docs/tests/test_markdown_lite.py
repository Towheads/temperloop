"""Tests for lib/markdown_lite.py — the dependency-free Markdown subset
renderer the docs generator uses on all three sources."""
from __future__ import annotations

import unittest

from lib.markdown_lite import render, render_inline, split_frontmatter


class TestSplitFrontmatter(unittest.TestCase):
    def test_extracts_fields_and_body(self) -> None:
        text = (
            "---\n"
            "description: does a **thing**\n"
            'argument-hint: "--epic <N>"\n'
            "---\n"
            "\n"
            "# Body heading\n"
        )
        doc = split_frontmatter(text)
        self.assertEqual(doc.fields["description"], "does a **thing**")
        self.assertEqual(doc.fields["argument-hint"], '"--epic <N>"')
        self.assertIn("# Body heading", doc.body)

    def test_no_frontmatter_returns_whole_text_as_body(self) -> None:
        doc = split_frontmatter("# just a heading\n")
        self.assertIsNone(doc.frontmatter)
        self.assertEqual(doc.fields, {})
        self.assertIn("# just a heading", doc.body)

    def test_unclosed_frontmatter_falls_back_to_whole_body(self) -> None:
        text = "---\ndescription: oops no closing delimiter\n"
        doc = split_frontmatter(text)
        self.assertIsNone(doc.frontmatter)
        self.assertEqual(doc.body, text)


class TestRenderInline(unittest.TestCase):
    def test_escapes_angle_brackets(self) -> None:
        self.assertEqual(render_inline("a <N> b"), "a &lt;N&gt; b")

    def test_bold_and_italic(self) -> None:
        self.assertEqual(render_inline("**bold** and *italic*"), "<strong>bold</strong> and <em>italic</em>")

    def test_inline_code(self) -> None:
        self.assertEqual(render_inline("run `make docs`"), "run <code>make docs</code>")

    def test_link(self) -> None:
        self.assertEqual(
            render_inline("see [the docs](https://example.com)"),
            'see <a href="https://example.com">the docs</a>',
        )

    def test_wikilink_renders_as_literal_text_not_broken_html(self) -> None:
        # [[Wikilink]] isn't a link-target this renderer resolves (vault-only
        # syntax); it must pass through as harmless literal text, not choke
        # the [text](url) link regex or leave unescaped brackets.
        self.assertEqual(render_inline("see [[Decisions/foo]]"), "see [[Decisions/foo]]")


class TestRenderBlock(unittest.TestCase):
    def test_headings(self) -> None:
        html = render("# H1\n## H2\n")
        self.assertIn("<h1>H1</h1>", html)
        self.assertIn("<h2>H2</h2>", html)

    def test_fenced_code_block_not_inline_processed(self) -> None:
        html = render("```yaml\nkey: **not bold**\n```\n")
        self.assertIn('<pre><code class="language-yaml">', html)
        # literal content preserved, not turned into <strong>
        self.assertIn("key: **not bold**", html)
        self.assertNotIn("<strong>", html)

    def test_unordered_list(self) -> None:
        html = render("- one\n- two\n")
        self.assertEqual(html, "<ul>\n<li>one</li>\n<li>two</li>\n</ul>")

    def test_ordered_list(self) -> None:
        html = render("1. one\n2. two\n")
        self.assertEqual(html, "<ol>\n<li>one</li>\n<li>two</li>\n</ol>")

    def test_blockquote(self) -> None:
        html = render("> quoted text\n")
        self.assertEqual(html, "<blockquote>quoted text</blockquote>")

    def test_horizontal_rule(self) -> None:
        html = render("above\n\n---\n\nbelow\n")
        self.assertIn("<hr>", html)

    def test_paragraph_join(self) -> None:
        html = render("line one\nline two\n\nnew paragraph\n")
        self.assertEqual(html, "<p>line one line two</p>\n<p>new paragraph</p>")


if __name__ == "__main__":
    unittest.main()
