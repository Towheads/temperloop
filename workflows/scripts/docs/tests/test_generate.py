"""Tests for generate.py — the docs-site orchestrator.

Exercises the two pinned conventions this item's acceptance bar names
directly: the kernel-manifest include filter (an overlay-classified command
never renders) and the overlay renderer drop-in (absent -> zero extra
pages; present -> its pages are unioned in). Also covers the chapters glob
(absent dir -> zero chapter pages, no error), the feature-docs/ADR globs
(temperloop #133 — same absent-dir zero-page shape, plus fixture rendering
under their own nav groups), and idempotent re-run.

Builds a small synthetic fixture repo per test rather than depending on this
checkout's real claude/commands/ contents, so these tests don't churn every
time a command file changes.
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from generate import _write_site, build_site
from lib.page import Page


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _make_fixture_repo(tmp: Path) -> Path:
    repo = tmp / "repo"

    _write(
        repo / "claude" / "commands" / "kernel-cmd.md",
        "---\ndescription: a kernel command\n---\n\n# kernel-cmd\n\nBody text.\n",
    )
    _write(
        repo / "claude" / "commands" / "overlay-cmd.md",
        "---\ndescription: a private ritual\n---\n\n# overlay-cmd\n\nBody text.\n",
    )
    _write(
        repo / "claude" / "plan-schema.md",
        "# Plan-note schema\n\nSome contract text.\n",
    )
    _write(
        repo / "scripts" / "quality-gates.sh",
        "#!/usr/bin/env bash\n"
        'if [[ "${1:-}" == "--list" ]]; then\n'
        '  echo "[kernel]  make fake-gate"\n'
        "  exit 0\n"
        "fi\n"
        "exit 0\n",
    )
    (repo / "scripts" / "quality-gates.sh").chmod(0o755)

    _write(
        repo / "workflows" / "scripts" / "lib" / "knowledge_store.contract.md",
        "# knowledge_store interface contract\n\nSome contract text.\n",
    )

    return repo


def _make_manifest(tmp: Path) -> Path:
    manifest_path = tmp / "kernel-manifest.txt"
    manifest_path.write_text(
        "kernel claude/commands/*.md\n"
        "overlay claude/commands/overlay-cmd.md\n"
        "kernel claude/plan-schema.md\n"
        "kernel scripts/quality-gates.sh\n",
        encoding="utf-8",
    )
    return manifest_path


class TestBuildSite(unittest.TestCase):
    def test_kernel_manifest_filter_excludes_overlay_command(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp = Path(tmp_str)
            repo = _make_fixture_repo(tmp)
            manifest_path = _make_manifest(tmp)
            empty_dropin = tmp / "no-dropin-here"

            pages = build_site(repo, manifest_path=manifest_path, dropin_dir=empty_dropin)

        reference_page = next(p for p in pages if p.slug == "commands/reference")
        self.assertIn("kernel-cmd", reference_page.body_html)
        self.assertNotIn("overlay-cmd", reference_page.body_html)

    def test_four_sources_all_render(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp = Path(tmp_str)
            repo = _make_fixture_repo(tmp)
            manifest_path = _make_manifest(tmp)
            empty_dropin = tmp / "no-dropin-here"

            pages = build_site(repo, manifest_path=manifest_path, dropin_dir=empty_dropin)

        slugs = {p.slug for p in pages}
        self.assertIn("commands/reference", slugs)
        self.assertIn("plan-schema", slugs)
        self.assertIn("quality-gates", slugs)
        self.assertIn("adapter-contracts/knowledge_store", slugs)

    def test_adapter_contracts_glob_renders_no_tracker_stub(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp = Path(tmp_str)
            repo = _make_fixture_repo(tmp)
            manifest_path = _make_manifest(tmp)
            empty_dropin = tmp / "no-dropin-here"

            # No tracker.contract.md written anywhere under repo.
            pages = build_site(repo, manifest_path=manifest_path, dropin_dir=empty_dropin)

        contract_pages = [p for p in pages if p.slug.startswith("adapter-contracts/")]
        self.assertEqual(len(contract_pages), 1)
        self.assertEqual(contract_pages[0].slug, "adapter-contracts/knowledge_store")
        self.assertIn("contract text", contract_pages[0].body_html)
        self.assertFalse(any("tracker" in p.slug for p in contract_pages))

    def test_chapters_glob_absent_dir_yields_zero_pages_no_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp = Path(tmp_str)
            repo = _make_fixture_repo(tmp)
            manifest_path = _make_manifest(tmp)
            empty_dropin = tmp / "no-dropin-here"

            # No docs/failure-modes/ dir created anywhere under repo.
            pages = build_site(repo, manifest_path=manifest_path, dropin_dir=empty_dropin)

        self.assertFalse(any(p.slug.startswith("failure-modes/") for p in pages))

    def test_features_and_adr_globs_absent_dirs_yield_zero_pages_no_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp = Path(tmp_str)
            repo = _make_fixture_repo(tmp)
            manifest_path = _make_manifest(tmp)
            empty_dropin = tmp / "no-dropin-here"

            # No docs/features/ or docs/adr/ dir created anywhere under repo.
            pages = build_site(repo, manifest_path=manifest_path, dropin_dir=empty_dropin)

        self.assertFalse(any(p.slug.startswith("features/") for p in pages))
        self.assertFalse(any(p.slug.startswith("adr/") for p in pages))

    def test_features_source_renders_fixture_feature_doc_and_adr(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp = Path(tmp_str)
            repo = _make_fixture_repo(tmp)
            _write(
                repo / "docs" / "features" / "widget-export.md",
                "---\ntitle: Widget export\n---\n\nExport widgets to CSV.\n",
            )
            _write(
                repo / "docs" / "adr" / "0001-use-sqlite.md",
                "---\ntitle: Use SQLite for local storage\n---\n\nDecision body text.\n",
            )
            manifest_path = _make_manifest(tmp)
            empty_dropin = tmp / "no-dropin-here"

            pages = build_site(repo, manifest_path=manifest_path, dropin_dir=empty_dropin)

        feature_page = next(p for p in pages if p.slug == "features/widget-export")
        self.assertEqual(feature_page.title, "Widget export")
        self.assertEqual(feature_page.nav_group, "Features")
        self.assertIn("Export widgets to CSV", feature_page.body_html)

        adr_page = next(p for p in pages if p.slug == "adr/0001-use-sqlite")
        self.assertEqual(adr_page.title, "Use SQLite for local storage")
        self.assertEqual(adr_page.nav_group, "ADRs")
        self.assertIn("Decision body text", adr_page.body_html)

    def test_features_glob_ignores_registry_txt_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp = Path(tmp_str)
            repo = _make_fixture_repo(tmp)
            _write(
                repo / "docs" / "features" / "widget-export.md",
                "---\ntitle: Widget export\n---\n\nExport widgets to CSV.\n",
            )
            _write(repo / "docs" / "features" / "registry.txt", "widget-export\tenabled\n")
            manifest_path = _make_manifest(tmp)
            empty_dropin = tmp / "no-dropin-here"

            pages = build_site(repo, manifest_path=manifest_path, dropin_dir=empty_dropin)

        feature_slugs = [p.slug for p in pages if p.slug.startswith("features/")]
        self.assertEqual(feature_slugs, ["features/widget-export"])

    def test_cli_source_absent_readme_yields_zero_pages(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp = Path(tmp_str)
            repo = _make_fixture_repo(tmp)  # no bin/README.md written
            manifest_path = _make_manifest(tmp)
            empty_dropin = tmp / "no-dropin-here"

            pages = build_site(repo, manifest_path=manifest_path, dropin_dir=empty_dropin)

        self.assertNotIn("cli/getting-started", {p.slug for p in pages})

    def test_cli_source_renders_bootstrap_and_subcommand_table(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp = Path(tmp_str)
            repo = _make_fixture_repo(tmp)
            _write(repo / "bin" / "README.md", "# foundation CLI\n\nBootstrap docs here.\n")
            _write(
                repo / "bin" / "subcommands" / "try.sh",
                "#!/usr/bin/env bash\n# description: zero-config taste, zero writes\necho try\n",
            )
            manifest_path = _make_manifest(tmp)
            empty_dropin = tmp / "no-dropin-here"

            pages = build_site(repo, manifest_path=manifest_path, dropin_dir=empty_dropin)

        cli_page = next(p for p in pages if p.slug == "cli/getting-started")
        self.assertIn("Bootstrap docs here", cli_page.body_html)
        self.assertIn("try", cli_page.body_html)
        self.assertIn("zero-config taste, zero writes", cli_page.body_html)

    def test_overlay_dropin_absent_directory_adds_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp = Path(tmp_str)
            repo = _make_fixture_repo(tmp)
            manifest_path = _make_manifest(tmp)
            absent_dropin = tmp / "does-not-exist"
            self.assertFalse(absent_dropin.exists())

            pages_without = build_site(repo, manifest_path=manifest_path, dropin_dir=absent_dropin)

        self.assertEqual(len(pages_without), 4)  # commands + plan-schema + gates + adapter-contract, no overlay extras

    def test_overlay_dropin_present_directory_adds_its_pages(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp = Path(tmp_str)
            repo = _make_fixture_repo(tmp)
            manifest_path = _make_manifest(tmp)
            dropin_dir = tmp / "docs.d"
            dropin_dir.mkdir()
            _write(
                dropin_dir / "extra.py",
                "from lib.page import Page\n"
                "def build_pages(repo_root):\n"
                "    return [Page(slug='overlay/extra', title='Overlay extra', body_html='<p>hi</p>')]\n",
            )

            pages = build_site(repo, manifest_path=manifest_path, dropin_dir=dropin_dir)

        self.assertTrue(any(p.slug == "overlay/extra" for p in pages))
        self.assertEqual(len(pages), 5)

    def test_overlay_dropin_module_without_build_pages_raises(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_str:
            tmp = Path(tmp_str)
            repo = _make_fixture_repo(tmp)
            manifest_path = _make_manifest(tmp)
            dropin_dir = tmp / "docs.d"
            dropin_dir.mkdir()
            _write(dropin_dir / "broken.py", "X = 1\n")

            with self.assertRaises(RuntimeError):
                build_site(repo, manifest_path=manifest_path, dropin_dir=dropin_dir)


class TestWriteSiteIdempotent(unittest.TestCase):
    def test_rerun_on_unchanged_pages_is_byte_identical(self) -> None:
        pages = [
            Page(slug="a", title="A", body_html="<p>alpha</p>", nav_group="G"),
            Page(slug="nested/b", title="B", body_html="<p>beta</p>", nav_group="G"),
        ]
        with tempfile.TemporaryDirectory() as tmp_str:
            out_dir = Path(tmp_str) / "_site"
            _write_site(pages, out_dir)
            first = {p: p.read_bytes() for p in sorted(out_dir.rglob("*")) if p.is_file()}

            _write_site(pages, out_dir)
            second = {p: p.read_bytes() for p in sorted(out_dir.rglob("*")) if p.is_file()}

        self.assertEqual(first, second)

    def test_stale_page_removed_on_rerun(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_str:
            out_dir = Path(tmp_str) / "_site"
            _write_site([Page(slug="stale", title="Stale", body_html="<p>x</p>")], out_dir)
            self.assertTrue((out_dir / "stale.html").exists())

            _write_site([Page(slug="fresh", title="Fresh", body_html="<p>y</p>")], out_dir)
            self.assertFalse((out_dir / "stale.html").exists())
            self.assertTrue((out_dir / "fresh.html").exists())


if __name__ == "__main__":
    unittest.main()
