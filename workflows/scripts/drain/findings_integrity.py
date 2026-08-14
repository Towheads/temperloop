#!/usr/bin/env python3
"""findings_integrity.py — corroborate a drain run's self-reported findings
emission against what actually landed in the append-only findings stream.

The problem this exists to catch (foundation#1576): `/tidy`'s drain step
self-reports a "Findings records: N emitted (X accepted, Y rejected)" tally
in its Step 6 summary, but that tally is only ever *asserted* — nothing
mechanically confirms the records were actually appended. One observed drain
summary claimed "16 emitted (8 accepted, 8 rejected)" while zero rows dated
that day existed in the stream. This script is the mechanical corroboration:
it reads the append-only `findings-<YYYY-MM>.jsonl` files directly and
compares actual per-session accepted/rejected row counts against what the
caller (the drain step) claims it emitted.

**This is the single findings-integrity checker.** A follow-up item
(foundation#1584, SUBJECT_MODEL_MISSING) extends this same file with an
additional check rather than adding a parallel mechanism — keep new checks
here, cohesive, rather than spawning sibling scripts.

Self-report shape (one entry per transcript/session processed this run):

    {
      "<session_id>": {"accepted": <int>, "rejected": <int>},
      ...
    }

A session with genuinely nothing to extract (no lexicon match, no
model-skim hit) is legitimately reported as `{"accepted": 0, "rejected": 0}`
— the check only flags a divergence between what was self-reported and what
actually landed, so an honest all-zero report for an all-zero actual outcome
passes cleanly. This is what makes "zero rows because there was nothing to
find" distinguishable from "zero rows because the append silently failed"
(the stream records rejections too, via `accepted: false`, so a *processed*
transcript that found ≥1 candidate can never legitimately land zero rows).

Exit codes:
    0  every self-reported session matches its actual landed rows exactly.
       Prints `FINDINGS_INTEGRITY_OK` plus the aggregate totals.
    1  at least one session diverges. Prints the literal token
       `FINDINGS_EMITTED_MISMATCH`, one detail line per divergent session.
    2  usage / input error (bad JSON, missing root, etc.) — a distinct code
       so a caller can tell "the corroboration failed" apart from
       "the corroboration couldn't even run".

Usage (CLI):
    python3 workflows/scripts/drain/findings_integrity.py <root> \\
        --self-report '{"abc123": {"accepted": 2, "rejected": 1}}'
    python3 workflows/scripts/drain/findings_integrity.py <root> \\
        --self-report-file /path/to/report.json

<root> is the repo root containing meta/data/raw/ (same convention as
tally_recent_findings.py in this directory) — every findings-*.jsonl under
it is scanned (no month/date filtering: a session_id is a UUID scoped to one
drain run, so matching on it alone is unambiguous).

Schema SSOT: workflows/scripts/drain/findings-schema.md
Stdlib only; zero model tokens; no network.

--- SUBJECT_MODEL_MISSING check (foundation#1584) --------------------------

A second, independent corroboration lives in this same file: a findings
record's `subject_model` is legitimately `null` when the session stub it was
extracted from carried no `model:` frontmatter line at all (measured: 38% of
archived stubs, 312 of 814) — but it is a genuine attribution defect when the
stub *did* carry a `model:` line and the record still landed with
`subject_model: null` (measured: 73 of 1073 rows, 6.8%, in the foundation.cron
checkout). Only the second case is flagged, via `--check-subject-model`:

    python3 workflows/scripts/drain/findings_integrity.py <root> \\
        --check-subject-model

It scans every `findings-*.jsonl` record under `<root>/meta/data/raw/` with
`subject_model: null`, resolves the record's `session_id` to its archived
stub under `<root>/meta/sessions/archive/` (matched on the leading-8-char
`id8` the archiver's own filename convention uses — see
`claude/hooks/session-end-log.sh`; both a bare `.md` and a retention-gzipped
`.md.gz` are checked), and reads that stub's frontmatter `model:` field. A
record is flagged with the literal token `SUBJECT_MODEL_MISSING` only when
the stub was found AND its frontmatter carried a non-empty `model:` value —
a stub with no `model:` line, or no archived stub at all (can't corroborate
either way), is never flagged. This mode is independent of the emitted-count
check above: it needs no self-report and scans the whole stream, since the
gap it looks for can be introduced at any point in a session's history, not
only in the run that just self-reported.

Exit codes (--check-subject-model mode):
    0  no record is flagged. Prints `SUBJECT_MODEL_OK`.
    1  at least one record is flagged. Prints one `SUBJECT_MODEL_MISSING`
       line per flagged record.
    2  usage / input error (e.g. the archive dir path is unreadable in a way
       other than "missing", which is treated as zero stubs found).
"""
from __future__ import annotations

import argparse
import glob
import gzip
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional

MISMATCH_TOKEN = "FINDINGS_EMITTED_MISMATCH"
OK_TOKEN = "FINDINGS_INTEGRITY_OK"
SUBJECT_MODEL_MISSING_TOKEN = "SUBJECT_MODEL_MISSING"
SUBJECT_MODEL_OK_TOKEN = "SUBJECT_MODEL_OK"


class SelfReportError(ValueError):
    """Raised when the self-report input is malformed."""


def _validate_self_report(self_report: Any) -> Dict[str, Dict[str, int]]:
    if not isinstance(self_report, dict):
        raise SelfReportError("self-report must be a JSON object keyed by session_id")
    out: Dict[str, Dict[str, int]] = {}
    for sid, counts in self_report.items():
        if not isinstance(sid, str) or not sid:
            raise SelfReportError(f"session_id key must be a non-empty string, got {sid!r}")
        if not isinstance(counts, dict):
            raise SelfReportError(f"self-report[{sid!r}] must be an object")
        for k in ("accepted", "rejected"):
            if k not in counts:
                raise SelfReportError(f"self-report[{sid!r}] missing required key {k!r}")
            v = counts[k]
            if not isinstance(v, int) or isinstance(v, bool) or v < 0:
                raise SelfReportError(
                    f"self-report[{sid!r}][{k!r}] must be a non-negative int, got {v!r}"
                )
        out[sid] = {"accepted": counts["accepted"], "rejected": counts["rejected"]}
    return out


def read_actual_counts(root: str, session_ids: set) -> Dict[str, Dict[str, int]]:
    """Scan every findings-*.jsonl under <root>/meta/data/raw/ and return
    {session_id: {"accepted": n, "rejected": n}} for each session_id in
    ``session_ids``. Session ids not present in the stream at all are
    simply absent from the returned dict (equivalent to zero rows).

    Malformed JSON lines are skipped (mirrors tally_recent_findings.py's
    tolerance — a corrupt line elsewhere in the stream must never make this
    check unable to corroborate an unrelated session).
    """
    counts: Dict[str, Dict[str, int]] = {}
    pattern = os.path.join(root, "meta", "data", "raw", "findings-*.jsonl")
    for path in sorted(glob.glob(pattern)):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict):
                    continue
                sid = record.get("session_id")
                if sid not in session_ids:
                    continue
                bucket = counts.setdefault(sid, {"accepted": 0, "rejected": 0})
                if record.get("accepted") is True:
                    bucket["accepted"] += 1
                else:
                    # Any record present in the append-only stream that
                    # isn't accepted==true is a landed rejection row
                    # (accepted: false) — count it, never drop it.
                    bucket["rejected"] += 1
    return counts


def diff_report(
    self_report: Dict[str, Dict[str, int]],
    actual: Dict[str, Dict[str, int]],
) -> list:
    """Return a list of human-readable mismatch lines (empty = fully matched).

    A session with a non-zero self-reported total but zero actual rows is
    reported with an explicit "processed transcript, zero rows landed" tag
    so the output distinguishes a silent-emit failure from an ordinary
    count drift.
    """
    problems = []
    for sid, expected in sorted(self_report.items()):
        got = actual.get(sid, {"accepted": 0, "rejected": 0})
        if got["accepted"] == expected["accepted"] and got["rejected"] == expected["rejected"]:
            continue
        expected_total = expected["accepted"] + expected["rejected"]
        got_total = got["accepted"] + got["rejected"]
        tag = ""
        if expected_total > 0 and got_total == 0:
            tag = " [processed transcript, zero rows landed]"
        problems.append(
            f"{MISMATCH_TOKEN}: session {sid} self-reported "
            f"accepted={expected['accepted']} rejected={expected['rejected']}; "
            f"actual landed accepted={got['accepted']} rejected={got['rejected']}{tag}"
        )
    return problems


def check(root: str, self_report_raw: Any) -> "tuple[bool, list, Dict[str, int]]":
    """Run the full corroboration. Returns (matched, problem_lines, totals).

    ``totals`` carries the CORROBORATED (actual, not self-reported) aggregate
    counts — the figures a caller should quote in a report, since the whole
    point of this check is that the self-reported figure is not trustworthy
    on its own.
    """
    self_report = _validate_self_report(self_report_raw)
    actual = read_actual_counts(root, set(self_report.keys()))
    problems = diff_report(self_report, actual)
    totals = {"accepted": 0, "rejected": 0}
    for sid in self_report:
        got = actual.get(sid, {"accepted": 0, "rejected": 0})
        totals["accepted"] += got["accepted"]
        totals["rejected"] += got["rejected"]
    return (len(problems) == 0, problems, totals)


# ---------------------------------------------------------------------------
# SUBJECT_MODEL_MISSING check (foundation#1584)
# ---------------------------------------------------------------------------

_FRONTMATTER_SCALAR = re.compile(r'^(\w[\w_-]*):\s*(.*)')


def _parse_stub_frontmatter(text: str) -> Dict[str, str]:
    """Minimal frontmatter scalar parser, mirroring scan_stub.py's
    parse_frontmatter but scoped to what this check needs (no PyYAML dep).
    Returns {} if the text has no leading '---\\n' ... '\\n---\\n' block.
    """
    if not text.startswith("---\n"):
        return {}
    rest = text[4:]
    end = rest.find("\n---\n")
    if end == -1:
        return {}
    yaml_block = rest[:end]
    meta: Dict[str, str] = {}
    for line in yaml_block.splitlines():
        m = _FRONTMATTER_SCALAR.match(line)
        if m:
            meta[m.group(1)] = m.group(2).strip().strip('"')
    return meta


def resolve_stub_model(root: str, session_id: str) -> Optional[str]:
    """Resolve `session_id` to its archived session stub and return the
    stub's frontmatter `model:` value.

    Returns None (never flagged as a defect) when:
      - `session_id` is empty/too short to form an id8,
      - no archived stub matches (can't corroborate either way),
      - a matching stub exists but its frontmatter has no `model:` line
        (or an empty one) — the legitimate "stub genuinely carried no
        model" case findings-schema.md documents.

    Archive filenames follow `<date>-<time>-<project>-<id8>.md`, optionally
    gzipped to `.md.gz` once cold (foundation CLAUDE.md § Structure). id8 is
    the leading 8 characters of the full session_id — the same convention
    `claude/hooks/session-end-log.sh` uses to name the stub in the first
    place (`cut -c1-8`).
    """
    if not session_id or len(session_id) < 8:
        return None
    id8 = session_id[:8]
    archive_dir = os.path.join(root, "meta", "sessions", "archive")
    candidates = sorted(glob.glob(os.path.join(archive_dir, f"*-{id8}.md")))
    candidates += sorted(glob.glob(os.path.join(archive_dir, f"*-{id8}.md.gz")))
    for path in candidates:
        try:
            if path.endswith(".gz"):
                with gzip.open(path, "rt", encoding="utf-8") as fh:
                    text = fh.read()
            else:
                with open(path, encoding="utf-8") as fh:
                    text = fh.read()
        except OSError:
            continue
        meta = _parse_stub_frontmatter(text)
        model = meta.get("model")
        return model or None
    return None


def check_subject_model(root: str) -> "tuple[bool, List[str]]":
    """Scan every findings-*.jsonl record with subject_model: null and flag
    the ones whose archived session stub carried a model: line (the
    attribution-collapse defect, foundation#1584). Returns (ok, problem_lines).

    A malformed JSON line is skipped, not fatal — same tolerance as
    read_actual_counts above.
    """
    problems: List[str] = []
    pattern = os.path.join(root, "meta", "data", "raw", "findings-*.jsonl")
    for path in sorted(glob.glob(pattern)):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict):
                    continue
                if record.get("subject_model") is not None:
                    continue
                sid = record.get("session_id")
                if not isinstance(sid, str) or not sid:
                    continue
                stub_model = resolve_stub_model(root, sid)
                if not stub_model:
                    continue
                problems.append(
                    f"{SUBJECT_MODEL_MISSING_TOKEN}: session {sid} "
                    f"finding_ref={record.get('finding_ref')!r} has "
                    f"subject_model=null but its archived stub carried "
                    f"model={stub_model!r} ({path})"
                )
    return (len(problems) == 0, problems)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=(
            "Corroborate a drain run's self-reported findings-record emission "
            "against the rows actually present in meta/data/raw/findings-*.jsonl."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("root", help="repo root containing meta/data/raw/")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument(
        "--self-report",
        metavar="JSON",
        help='Self-report as a JSON object: {"<session_id>": {"accepted": N, "rejected": M}, ...}',
    )
    g.add_argument(
        "--self-report-file",
        metavar="PATH",
        help="Path to a file containing the self-report JSON (same shape as --self-report).",
    )
    g.add_argument(
        "--check-subject-model",
        action="store_true",
        help=(
            "Run the SUBJECT_MODEL_MISSING corroboration instead: scan every "
            "findings-*.jsonl record with subject_model=null and flag any whose "
            "archived session stub (meta/sessions/archive/) carried a model: "
            "line. Needs no self-report; scans the whole stream."
        ),
    )
    return p


def main(argv: Optional[list] = None) -> int:
    p = _build_parser()
    args = p.parse_args(argv)

    if args.check_subject_model:
        matched, problems = check_subject_model(args.root)
        if matched:
            print(f"{SUBJECT_MODEL_OK_TOKEN}: no subject_model attribution gaps found")
            return 0
        for line in problems:
            print(line)
        print(
            f"{SUBJECT_MODEL_MISSING_TOKEN}: {len(problems)} record(s) landed "
            f"subject_model=null despite an archived stub with a model: line"
        )
        return 1

    if args.self_report_file:
        try:
            with open(args.self_report_file, encoding="utf-8") as fh:
                raw_text = fh.read()
        except OSError as exc:
            print(f"ERROR: could not read --self-report-file: {exc}", file=sys.stderr)
            return 2
    else:
        raw_text = args.self_report

    try:
        self_report_raw = json.loads(raw_text)
    except json.JSONDecodeError as exc:
        print(f"ERROR: self-report is not valid JSON: {exc}", file=sys.stderr)
        return 2

    try:
        matched, problems, totals = check(args.root, self_report_raw)
    except SelfReportError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if matched:
        total = totals["accepted"] + totals["rejected"]
        print(
            f"{OK_TOKEN}: {total} emitted "
            f"({totals['accepted']} accepted, {totals['rejected']} rejected) — corroborated"
        )
        return 0

    for line in problems:
        print(line)
    total = totals["accepted"] + totals["rejected"]
    print(
        f"{MISMATCH_TOKEN}: corroborated total {total} landed "
        f"({totals['accepted']} accepted, {totals['rejected']} rejected) — "
        f"{len(problems)} session(s) diverged from self-report"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
