"""Tests for lib/kernel_manifest.py — the docs generator's include filter."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from lib.kernel_manifest import classify, is_kernel, load_manifest

FIXTURE = """
# comment line, ignored
kernel claude/commands/*.md
overlay claude/commands/standup.md
kernel claude/commands/very-specific-override.md
split CLAUDE.md
"""


class TestLoadManifest(unittest.TestCase):
    def test_parses_entries_skipping_comments_and_blanks(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            manifest_path = Path(tmp) / "kernel-manifest.txt"
            manifest_path.write_text(FIXTURE, encoding="utf-8")
            entries = load_manifest(manifest_path)
        self.assertEqual(
            entries,
            [
                ("claude/commands/*.md", "kernel"),
                ("claude/commands/standup.md", "overlay"),
                ("claude/commands/very-specific-override.md", "kernel"),
                ("CLAUDE.md", "split"),
            ],
        )

    def test_malformed_line_raises(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            manifest_path = Path(tmp) / "kernel-manifest.txt"
            manifest_path.write_text("kernel\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                load_manifest(manifest_path)

    def test_bad_class_raises(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            manifest_path = Path(tmp) / "kernel-manifest.txt"
            manifest_path.write_text("bogus some/path\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                load_manifest(manifest_path)


class TestClassify(unittest.TestCase):
    def setUp(self) -> None:
        self.entries = load_manifest_from_text(FIXTURE)

    def test_directory_glob_matches_kernel(self) -> None:
        self.assertEqual(classify(self.entries, "claude/commands/assess.md"), "kernel")
        self.assertTrue(is_kernel(self.entries, "claude/commands/assess.md"))

    def test_specific_override_beats_broader_overlay(self) -> None:
        # "standup.md" is caught by both the broad kernel glob and the
        # more specific overlay single-file entry; longest pattern wins.
        self.assertEqual(classify(self.entries, "claude/commands/standup.md"), "overlay")
        self.assertFalse(is_kernel(self.entries, "claude/commands/standup.md"))

    def test_unmatched_path_returns_none(self) -> None:
        self.assertIsNone(classify(self.entries, "some/unrelated/path.txt"))

    def test_longest_match_wins_regardless_of_order(self) -> None:
        # very-specific-override.md is listed AFTER the broad glob but must
        # still win — order-independence is the documented contract.
        self.assertEqual(
            classify(self.entries, "claude/commands/very-specific-override.md"), "kernel"
        )


def load_manifest_from_text(text: str) -> list[tuple[str, str]]:
    with tempfile.TemporaryDirectory() as tmp:
        manifest_path = Path(tmp) / "kernel-manifest.txt"
        manifest_path.write_text(text, encoding="utf-8")
        return load_manifest(manifest_path)


if __name__ == "__main__":
    unittest.main()
