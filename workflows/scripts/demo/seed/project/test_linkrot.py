"""Tests for linkrot.

Run them with:

    python3 -m unittest discover -s . -p 'test_*.py'
"""

import os
import tempfile
import unittest

import linkrot


class TempTree(unittest.TestCase):
    """Base class: a throwaway directory that is also the working directory."""

    def setUp(self):
        self._previous_cwd = os.getcwd()
        self._tmp = tempfile.mkdtemp(prefix="linkrot-test-")
        os.chdir(self._tmp)

    def tearDown(self):
        os.chdir(self._previous_cwd)

    def write(self, relpath, text):
        full = os.path.join(self._tmp, relpath)
        parent = os.path.dirname(full)
        if parent and not os.path.isdir(parent):
            os.makedirs(parent)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(text)
        return full


class FindLinksTest(unittest.TestCase):
    def test_extracts_label_and_target(self):
        links = linkrot.find_links("see [the guide](docs/guide.md) for more")
        self.assertEqual(links, [("the guide", "docs/guide.md")])

    def test_extracts_every_link_on_a_line(self):
        links = linkrot.find_links("[a](one.md) and [b](two.md)")
        self.assertEqual(links, [("a", "one.md"), ("b", "two.md")])

    def test_returns_empty_for_text_with_no_links(self):
        self.assertEqual(linkrot.find_links("plain prose, no links here"), [])


class CheckFileTest(TempTree):
    def test_reports_a_target_that_does_not_exist(self):
        self.write("README.md", "see [the guide](guide.md)\n")
        self.assertEqual(linkrot.check_file("README.md"), ["guide.md"])

    def test_stays_quiet_when_the_target_exists(self):
        self.write("guide.md", "# Guide\n")
        self.write("README.md", "see [the guide](guide.md)\n")
        self.assertEqual(linkrot.check_file("README.md"), [])


class MarkdownFilesTest(TempTree):
    def test_walks_recursively_and_sorts(self):
        self.write("README.md", "")
        self.write("docs/guide.md", "")
        self.assertEqual(
            linkrot.markdown_files("."),
            ["./README.md", "./docs/guide.md"],
        )

    def test_skips_the_git_directory(self):
        self.write("README.md", "")
        self.write(".git/COMMIT_EDITMSG.md", "")
        self.assertEqual(linkrot.markdown_files("."), ["./README.md"])

    def test_ignores_files_that_are_not_markdown(self):
        self.write("notes.txt", "")
        self.assertEqual(linkrot.markdown_files("."), [])


class FormatReportTest(unittest.TestCase):
    def test_one_line_per_broken_target(self):
        lines = linkrot.format_report({"README.md": ["a.md", "b.md"]})
        self.assertEqual(
            lines,
            ["broken: README.md -> a.md", "broken: README.md -> b.md"],
        )

    def test_empty_report_formats_to_no_lines(self):
        self.assertEqual(linkrot.format_report({}), [])


if __name__ == "__main__":
    unittest.main()
