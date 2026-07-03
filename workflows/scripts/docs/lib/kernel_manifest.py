"""kernel_manifest.py - read workflows/scripts/kernel/kernel-manifest.txt and
classify repo-relative paths as kernel / overlay / split.

This is the docs generator's INCLUDE FILTER (foundation #764, Epic C "docs
generated from source in CI"): a source scanner (e.g. sources/commands.py
walking claude/commands/*.md) calls classify() per candidate file and skips
anything that isn't "kernel" — so an overlay-classified command (Travis's
personal plan-morning/plan-evening/telemetry/signal-intake rituals) never
renders into the built site, with zero per-source-module special-casing. As
the manifest evolves (a command reclassified, a new kernel path added), the
generator's output follows automatically.

Deliberately a SEPARATE, minimal re-implementation of the match algorithm in
workflows/scripts/kernel/check-kernel-manifest.sh rather than shelling out to
it: the checker's job is coverage validation (fail on anything unmatched) and
prints to stdout/exits non-zero; this module's job is classification (return
a class or None) for use inline in a Python loop. Both read the SAME manifest
file and implement the SAME "longest matching pattern wins" rule, so the two
stay behaviorally identical by construction as long as this docstring's
contract holds — see check-kernel-manifest.sh's own header for the rule.
"""
from __future__ import annotations

import fnmatch
from pathlib import Path

VALID_CLASSES = ("kernel", "overlay", "split")


def load_manifest(manifest_path: Path) -> list[tuple[str, str]]:
    """Parse a kernel-manifest.txt into a list of (pattern, class) pairs, in
    file order. Blank lines and `#`-to-end-of-line comments are skipped, same
    as check-kernel-manifest.sh."""
    entries: list[tuple[str, str]] = []
    text = manifest_path.read_text(encoding="utf-8")
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            raise ValueError(
                f"kernel-manifest: malformed line {lineno} (no glob after class): {raw!r}"
            )
        cls, pat = parts
        if cls not in VALID_CLASSES:
            raise ValueError(f"kernel-manifest: bad class {cls!r} at line {lineno}: {raw!r}")
        entries.append((pat, cls))
    return entries


def classify(entries: list[tuple[str, str]], rel_path: str) -> str | None:
    """Classify rel_path (POSIX-style, repo-root-relative, no leading `/`)
    against manifest entries. Longest-matching-pattern wins, same tie-break
    as check-kernel-manifest.sh. Returns None if nothing matches."""
    best_len = -1
    best_class: str | None = None
    for pat, cls in entries:
        if fnmatch.fnmatchcase(rel_path, pat) and len(pat) > best_len:
            best_len = len(pat)
            best_class = cls
    return best_class


def is_kernel(entries: list[tuple[str, str]], rel_path: str) -> bool:
    return classify(entries, rel_path) == "kernel"
