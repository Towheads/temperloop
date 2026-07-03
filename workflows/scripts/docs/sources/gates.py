"""sources/gates.py - the quality-gate list, rendered from
`scripts/quality-gates.sh --list` (the single source of truth for the
local-gate = CI-gate contract; see that script's own header). Runs the real
script rather than re-parsing its KERNEL_GATES/OVERLAY_GATES arrays by hand,
so the published list can never drift from what `checks` actually runs.
"""
from __future__ import annotations

import html
import subprocess
from pathlib import Path

from lib.page import Page

SOURCE_REL_PATH = "scripts/quality-gates.sh"


def build_pages(repo_root: Path, manifest_entries: list[tuple[str, str]]) -> list[Page]:
    del manifest_entries  # unused: this source is unconditionally kernel
    script = repo_root / SOURCE_REL_PATH
    if not script.is_file():
        return []

    result = subprocess.run(
        ["bash", str(script), "--list"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"gates: `{SOURCE_REL_PATH} --list` exited {result.returncode}: {result.stderr}"
        )

    rows: list[tuple[str, str]] = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # Format: "[kernel]  make test-board" / "[overlay] make foo"
        if line.startswith("[") and "]" in line:
            layer, _, command = line.partition("]")
            layer = layer.lstrip("[").strip()
            command = command.strip()
            rows.append((layer, command))

    body = ['<table>', "<thead><tr><th>Layer</th><th>Gate</th></tr></thead>", "<tbody>"]
    for layer, command in rows:
        body.append(
            f"<tr><td>{html.escape(layer)}</td><td><code>{html.escape(command)}</code></td></tr>"
        )
    body.append("</tbody></table>")
    body_html = "\n".join(body)

    return [Page(slug="quality-gates", title="Quality gates", body_html=body_html, nav_group="Reference")]
