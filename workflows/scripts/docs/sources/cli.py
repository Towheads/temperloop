"""sources/cli.py - renders the CLI getting-started page: the curl|sh
bootstrap doc (+ inspect-first path) from bin/README.md, followed by a live
subcommand-reference table built by scanning bin/subcommands/*.sh for each
file's `# description: ...` header. (foundation #765 Epic D "newcomer
experience", item cli-entrypoint-bootstrap / #849.)

Unconditionally kernel (see kernel-manifest.txt's `kernel bin/*` entries) —
no manifest filtering needed, same treatment as plan_schema.py/gates.py.

Zero coupling to which subcommand items have landed: bin/subcommands/
starts empty (this item ships the dispatcher only) and the table below
renders "(none installed yet)" until a later item (foundation-try,
foundation-init, foundation-eject, ...) drops its own <name>.sh file there
— no generator change required, mirroring the chapters.py / commands.py
glob-and-render pattern (see generate.py's module docstring).

The `# description: ` header convention parsed here is the SAME one
kernel/bin/foundation's own `_foundation_subcommand_description()` reads for
`foundation help` — one convention, two independent readers (a shell one at
runtime, this Python one at docs-build time), so a subcommand author writes
it once and both surfaces pick it up.
"""
from __future__ import annotations

import html
import re
from pathlib import Path

from lib.markdown_lite import render
from lib.page import Page

README_REL_PATH = "bin/README.md"
SUBCOMMANDS_GLOB = "bin/subcommands/*.sh"

_DESCRIPTION_RE = re.compile(r"^# description: (.*)$")


def _subcommand_description(sh_path: Path) -> str:
    for line in sh_path.read_text(encoding="utf-8").splitlines():
        m = _DESCRIPTION_RE.match(line)
        if m:
            return m.group(1).strip()
    return "(no description)"


def _subcommand_table(repo_root: Path) -> str:
    rows = []
    for sh_path in sorted(repo_root.glob(SUBCOMMANDS_GLOB)):
        name = sh_path.stem
        description = _subcommand_description(sh_path)
        rows.append(
            f"<tr><td><code>{html.escape(name)}</code></td><td>{html.escape(description)}</td></tr>"
        )

    if not rows:
        return "<p><em>(none installed yet — this table updates automatically as subcommands land)</em></p>"

    return (
        "<table><thead><tr><th>Subcommand</th><th>Description</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table>"
    )


def build_pages(repo_root: Path, manifest_entries: list[tuple[str, str]]) -> list[Page]:
    del manifest_entries  # unused: bin/* is unconditionally kernel
    readme = repo_root / README_REL_PATH
    if not readme.is_file():
        return []

    # README.md already ends with a "## Subcommand reference" heading + intro
    # prose (see that file) — the table below is its continuation, not a new
    # section, so no extra heading is added here.
    body_html = render(readme.read_text(encoding="utf-8")) + "\n" + _subcommand_table(repo_root)

    return [
        Page(
            slug="cli/getting-started",
            title="CLI getting started",
            body_html=body_html,
            nav_group="Getting started",
        )
    ]
