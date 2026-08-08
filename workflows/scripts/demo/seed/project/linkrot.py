"""linkrot - find Markdown links that point at files which are not there.

The idea is small on purpose: walk a directory for `.md` files, pull the
inline links out of each one, and report the ones whose target does not
resolve to a file that exists.

    python3 linkrot.py .

Prints one `broken: <file> -> <target>` line per finding.
"""

import os
import re
import sys

# Inline Markdown link: [label](target)
LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")


def find_links(text):
    """Return every inline Markdown link in `text` as (label, target) pairs."""
    return [(m.group(1), m.group(2)) for m in LINK_RE.finditer(text)]


def is_local(target):
    """True when `target` names a file that lives in this repository.

    A link target is only checkable if it is a path. Anchors ("#usage") point
    inside the same document and external URLs ("https://example.com/") point
    off the repository entirely, so neither one can rot the way a file path
    can.
    """
    return True


def check_file(path):
    """Return the link targets in `path` that do not resolve to a file."""
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()

    broken = []
    for _label, target in find_links(text):
        if not is_local(target):
            continue
        if not os.path.exists(target):
            broken.append(target)
    return broken


def markdown_files(root):
    """Return every `.md` file under `root`, sorted, skipping `.git/`."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in filenames:
            if name.endswith(".md"):
                found.append(os.path.join(dirpath, name))
    return sorted(found)


def scan(paths):
    """Return {path: [broken targets]} for every path with a broken link."""
    report = {}
    for path in paths:
        broken = check_file(path)
        if broken:
            report[path] = broken
    return report


def format_report(report):
    """Return the report as a list of human-readable lines."""
    lines = []
    for path in sorted(report):
        for target in report[path]:
            lines.append("broken: {0} -> {1}".format(path, target))
    return lines


def main(argv=None):
    """Scan a directory (default `.`) and print every broken link found."""
    argv = list(sys.argv[1:] if argv is None else argv)
    root = argv[0] if argv else "."

    report = scan(markdown_files(root))
    for line in format_report(report):
        print(line)

    return 0


if __name__ == "__main__":
    sys.exit(main())
