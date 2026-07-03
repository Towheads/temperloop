#!/usr/bin/env python3
"""generate.py - foundation docs-site generator (skeleton).

Foundation #764 (Epic C, "kernel split: docs generated from source in CI").
Renders the THREE already-structured sources this item scopes to:

  - command reference   <- claude/commands/*.md         (sources/commands.py)
  - plan-note contract  <- claude/plan-schema.md          (sources/plan_schema.py)
  - quality-gate list   <- scripts/quality-gates.sh --list  (sources/gates.py)

plus the pinned-but-currently-empty failure-mode chapters glob
(sources/chapters.py) — see that module's docstring — and the adapter-
contract page(s), rendered from workflows/scripts/lib/*.contract.md
(sources/adapter_contracts.py; F#764 follow-on, docs-adapter-metric-
renderers item). Today that glob matches exactly one file
(knowledge_store.contract.md) — there is deliberately no tracker-contract
page (that seam's own contract file is foundation #814, separate scope).

Telemetry metric-definition rendering is a separate, OVERLAY concern (the
rollup producers it reads live under the overlay classification in
kernel-manifest.txt) and is NOT a sources/*.py module here — it ships as an
overlay drop-in at workflows/scripts/docs.d/metrics.py, picked up
automatically by the OVERLAY RENDERER DROP-IN CONVENTION below. A kernel-
only checkout (this repo's docs.d/ absent) never needs to know it exists.

KERNEL-MANIFEST INCLUDE FILTER: every source module that scans a directory
of candidate files (today: sources/commands.py) is handed the parsed
kernel-manifest.txt entries and calls lib.kernel_manifest.is_kernel() per
candidate — only "kernel"-classified paths render. This means an
overlay-classified command (plan-morning, plan-evening, telemetry,
signal-intake) is excluded automatically, with no per-command list to keep
in sync by hand. See lib/kernel_manifest.py.

OVERLAY RENDERER DROP-IN CONVENTION: analogous to scripts/quality-gates.d/
(sibling `.d` directory next to the script it extends), this generator
sources extra pages from workflows/scripts/docs.d/*.py — a sibling of this
script's own workflows/scripts/docs/ directory. Each *.py file there must
define `build_pages(repo_root: Path) -> list[Page]`; every module's returned
pages are unioned onto the kernel site's pages. The directory does not exist
in a kernel-only checkout (this repo, today) — glob() on a missing directory
is simply empty, so ABSENT DIRECTORY -> ZERO EXTRA PAGES, NO CONDITIONALS,
same degrade-for-free shape as quality-gates.d. A kernel-repo docs build
never needs to know whether an overlay repo exists.

Zero-network, zero-install: stdlib only (see lib/markdown_lite.py's
docstring for why there's a hand-rolled Markdown renderer instead of a pip
dependency). The one subprocess call (sources/gates.py, to run
quality-gates.sh --list) executes a script already checked into this repo —
no network fetch, no package install.

Output is NEVER committed (mirrors the dashboard/index.html precedent) — see
this directory's _site/.gitignore. Re-running on an unchanged tree produces
byte-identical output: no wall-clock timestamps anywhere in a rendered page
(see lib/page.py's render_page() docstring).
"""
from __future__ import annotations

import argparse
import importlib.util
import shutil
import sys
from pathlib import Path

DOCS_DIR = Path(__file__).resolve().parent
REPO_ROOT = DOCS_DIR.parent.parent.parent

# Make `lib.*` / `sources.*` importable regardless of the caller's CWD (this
# script may be invoked as `python3 workflows/scripts/docs/generate.py` from
# the repo root, or directly from within this directory).
if str(DOCS_DIR) not in sys.path:
    sys.path.insert(0, str(DOCS_DIR))

from lib.kernel_manifest import load_manifest  # noqa: E402
from lib.page import Page, render_page  # noqa: E402
from sources import adapter_contracts, chapters, commands, gates, plan_schema  # noqa: E402

KERNEL_MANIFEST_PATH = REPO_ROOT / "workflows" / "scripts" / "kernel" / "kernel-manifest.txt"
OVERLAY_DROPIN_DIR = REPO_ROOT / "workflows" / "scripts" / "docs.d"
DEFAULT_OUT_DIR = DOCS_DIR / "_site"

# Kernel source modules, in nav/build order. Each exposes
# build_pages(repo_root, manifest_entries) -> list[Page].
_SOURCE_MODULES = [commands, plan_schema, gates, adapter_contracts, chapters]


def _load_overlay_pages(repo_root: Path, dropin_dir: Path = OVERLAY_DROPIN_DIR) -> list[Page]:
    """Load every workflows/scripts/docs.d/*.py drop-in and collect the pages
    its build_pages(repo_root) returns. Mirrors quality-gates.sh's drop-in
    loop: glob in sorted order, skip a literal no-match glob, no error if the
    directory itself is absent. `dropin_dir` is overridable for tests."""
    pages: list[Page] = []
    if not dropin_dir.is_dir():
        return pages
    for py_path in sorted(dropin_dir.glob("*.py")):
        spec = importlib.util.spec_from_file_location(f"docs_overlay_{py_path.stem}", py_path)
        if spec is None or spec.loader is None:
            continue
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        build_fn = getattr(module, "build_pages", None)
        if build_fn is None:
            raise RuntimeError(
                f"docs.d overlay module {py_path} does not define build_pages(repo_root) -> list[Page]"
            )
        pages.extend(build_fn(repo_root))
    return pages


def build_site(
    repo_root: Path,
    manifest_path: Path = KERNEL_MANIFEST_PATH,
    dropin_dir: Path = OVERLAY_DROPIN_DIR,
) -> list[Page]:
    manifest_entries = load_manifest(manifest_path)

    pages: list[Page] = []
    for module in _SOURCE_MODULES:
        pages.extend(module.build_pages(repo_root, manifest_entries))
    pages.extend(_load_overlay_pages(repo_root, dropin_dir))
    return pages


def _write_site(pages: list[Page], out_dir: Path) -> None:
    # Idempotent: wipe and rewrite rather than merge, so a page removed from
    # a source (e.g. a command deleted) doesn't leave a stale orphan file.
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    # Recreate the tracked .gitkeep the wipe above just deleted (only when
    # out_dir IS this generator's own default _site/ — a caller-supplied
    # --out elsewhere has no such convention to uphold).
    if out_dir.resolve() == DEFAULT_OUT_DIR.resolve():
        (out_dir / ".gitkeep").touch()

    nav_items = [(p.nav_group, f"/{p.output_path}", p.title) for p in pages]
    nav_items.sort(key=lambda t: (t[0], t[2]))

    for page in pages:
        dest = out_dir / page.output_path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(render_page(page, nav_items), encoding="utf-8")

    index_links = "\n".join(
        f'<li><a href="/{p.output_path}">{p.title}</a></li>' for p in pages
    )
    index_page = Page(
        slug="index",
        title="Foundation docs",
        body_html=f"<ul>{index_links}</ul>",
        nav_group="",
    )
    (out_dir / "index.html").write_text(render_page(index_page, nav_items), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        type=Path,
        default=DEFAULT_OUT_DIR,
        help=f"output directory (default: {DEFAULT_OUT_DIR.relative_to(REPO_ROOT)}, gitignored)",
    )
    args = parser.parse_args(argv)

    pages = build_site(REPO_ROOT)
    if not pages:
        print("generate: zero pages produced — check the three sources exist", file=sys.stderr)
        return 1

    _write_site(pages, args.out)
    print(f"generate: wrote {len(pages)} page(s) + index to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
