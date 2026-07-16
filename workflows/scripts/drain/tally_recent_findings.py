#!/usr/bin/env python3
"""tally_recent_findings.py — count accepted drain findings by type over a window.

Reads every `meta/data/raw/findings-*.jsonl` under the given root (all months —
the glob covers window overlap) and prints one `<finding_type>\t<count>` line per
type, counting only records that are `accepted` truthy AND whose `ts` falls within
the trailing N days (default 14).

Extracted from /tidy's "Recurrence → promotion" step (foundation #960) so
the tally is a testable script rather than an inline heredoc. Stdlib only; zero
model tokens. Prints nothing when no accepted findings fall in the window.

Usage: tally_recent_findings.py <root> [--days N]
Exit 0 always when <root> is readable (an empty tally is not an error).
"""
import argparse
import glob
import json
import os
from datetime import datetime, timezone, timedelta


def tally(root, days):
    """Return {finding_type: count} for accepted findings within the last `days`."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    counts = {}
    for path in sorted(glob.glob(os.path.join(root, "meta/data/raw/findings-*.jsonl"))):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not r.get("accepted"):
                    continue
                ts = r.get("ts", "")
                try:
                    t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                except (ValueError, AttributeError):
                    continue
                # A real record's `ts` may parse offset-naive (no tz suffix);
                # `cutoff` is offset-aware, and comparing the two raises
                # TypeError. Assume UTC for a naive ts before the compare.
                if t.tzinfo is None:
                    t = t.replace(tzinfo=timezone.utc)
                if t < cutoff:
                    continue
                ft = r.get("finding_type", "")
                counts[ft] = counts.get(ft, 0) + 1
    return counts


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("root", help="repo root containing meta/data/raw/")
    ap.add_argument("--days", type=int, default=14, help="trailing window (default 14)")
    args = ap.parse_args()
    counts = tally(args.root, args.days)
    for ft, n in sorted(counts.items()):
        print(f"{ft}\t{n}")


if __name__ == "__main__":
    main()
