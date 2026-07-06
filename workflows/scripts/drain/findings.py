#!/usr/bin/env python3
"""
findings.py — append-only emit helper for the findings stream.

Validates a findings record against findings-schema.md (v2) and appends it as
a newline-delimited JSON line to:

    meta/data/raw/findings-<YYYY-MM>.jsonl

Usage (CLI):
    python3 workflows/scripts/drain/findings.py --record '<json>'
    python3 workflows/scripts/drain/findings.py \
        --session-id <id> --project <name> \
        --method drain-lexicon --sub-method "Lesson:" \
        --finding-type decision \
        --finding-ref "Decisions/foundation - Foo.md" \
        --accepted

The file is created on first write (no pre-creation needed).

Designed to be called from tidy's Step 3 Findings records section —
one call per adjudicated candidate (both accepted and rejected), so the
false-positive rate is also measurable.

Schema SSOT: workflows/scripts/drain/findings-schema.md
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

# ---------------------------------------------------------------------------
# Schema constants (mirrors findings-schema.md § Schema — v2)
# ---------------------------------------------------------------------------

SCHEMA_VERSION = "2"

# Schema versions a record may legally carry. The current writer emits
# SCHEMA_VERSION; older v1 records already in the stream remain valid on read
# (the v2 model fields are simply absent / treated as unknown for them).
_VALID_SCHEMA_VERSIONS = frozenset({"1", "2"})

_VALID_METHODS = frozenset({"drain-lexicon", "drain-model-skim"})

_VALID_FINDING_TYPES = frozenset(
    {
        "decision",
        "defect",
        "pattern",
        "mistake",
        "feedback",
        "friction",
        "optimization",
        "deferral",
    }
)

_REQUIRED_FIELDS = (
    "schema_version",
    "ts",
    "session_id",
    "project",
    "method",
    "sub_method",
    "finding_type",
    "finding_ref",
    "accepted",
)

# Fields added in schema v2 (model provenance). Required on v2 records (present
# as a string or null), absent on v1 records.
_V2_MODEL_FIELDS = (
    "subject_model",
    "analyst_model",
)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


class FindingsValidationError(ValueError):
    """Raised when a record fails schema validation."""


def validate_record(record: Dict[str, Any]) -> None:
    """Validate a findings record dict against findings-schema.md (v1 or v2).

    Accepts both schema versions: v1 records (no model fields) and v2 records
    (carrying ``subject_model`` / ``analyst_model``, each a string or null).
    The current writer emits v2; v1 records already in the stream stay valid.

    Raises FindingsValidationError on the first violation found.
    """
    # Required fields present.
    for field in _REQUIRED_FIELDS:
        if field not in record:
            raise FindingsValidationError(f"missing required field: {field!r}")

    version = record["schema_version"]
    if version not in _VALID_SCHEMA_VERSIONS:
        raise FindingsValidationError(
            f"schema_version must be one of {sorted(_VALID_SCHEMA_VERSIONS)}, "
            f"got {version!r}"
        )

    # v2 model-provenance fields: required (present, string-or-null) on v2,
    # and must NOT appear on a v1 record.
    if version == "2":
        for field in _V2_MODEL_FIELDS:
            if field not in record:
                raise FindingsValidationError(
                    f"missing required v2 field: {field!r}"
                )
            value = record[field]
            if value is not None and not isinstance(value, str):
                raise FindingsValidationError(
                    f"{field} must be a string or null, "
                    f"got {type(value).__name__}"
                )
    else:  # version == "1"
        for field in _V2_MODEL_FIELDS:
            if field in record:
                raise FindingsValidationError(
                    f"{field!r} is a v2 field and must not appear on a v1 record"
                )

    # ts — must be a non-empty string (ISO-8601 enforced loosely).
    ts = record["ts"]
    if not isinstance(ts, str) or not ts:
        raise FindingsValidationError("ts must be a non-empty string")
    # Quick structural check: expect at least YYYY-MM-DD.
    if len(ts) < 10 or ts[4] != "-" or ts[7] != "-":
        raise FindingsValidationError(
            f"ts does not look like an ISO-8601 timestamp: {ts!r}"
        )

    # session_id — non-empty string.
    if not isinstance(record["session_id"], str) or not record["session_id"]:
        raise FindingsValidationError("session_id must be a non-empty string")

    # project — non-empty string.
    if not isinstance(record["project"], str) or not record["project"]:
        raise FindingsValidationError("project must be a non-empty string")

    # method — enum.
    if record["method"] not in _VALID_METHODS:
        raise FindingsValidationError(
            f"method must be one of {sorted(_VALID_METHODS)}, "
            f"got {record['method']!r}"
        )

    # sub_method — string or null; required to be null for drain-model-skim.
    if record["method"] == "drain-model-skim" and record["sub_method"] is not None:
        raise FindingsValidationError(
            "sub_method must be null when method == 'drain-model-skim'"
        )
    if record["method"] == "drain-lexicon" and not isinstance(
        record["sub_method"], str
    ):
        raise FindingsValidationError(
            "sub_method must be a string (the tell that fired) "
            "when method == 'drain-lexicon'"
        )

    # finding_type — enum.
    if record["finding_type"] not in _VALID_FINDING_TYPES:
        raise FindingsValidationError(
            f"finding_type must be one of {sorted(_VALID_FINDING_TYPES)}, "
            f"got {record['finding_type']!r}"
        )

    # finding_ref — non-empty string.
    if not isinstance(record["finding_ref"], str) or not record["finding_ref"]:
        raise FindingsValidationError("finding_ref must be a non-empty string")

    # accepted — boolean.
    if not isinstance(record["accepted"], bool):
        raise FindingsValidationError(
            f"accepted must be a boolean, got {type(record['accepted']).__name__}"
        )


# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------


def _findings_path(ts: str, raw_dir: Optional[Path] = None) -> Path:
    """Return the monthly findings file path for the given ISO-8601 timestamp."""
    month = ts[:7]  # YYYY-MM
    if raw_dir is None:
        # Default: repo-root-relative meta/data/raw/
        repo_root = Path(__file__).resolve().parents[3]
        raw_dir = repo_root / "meta" / "data" / "raw"
    return raw_dir / f"findings-{month}.jsonl"


def _fill_defaults(record: Dict[str, Any]) -> Dict[str, Any]:
    """Return a copy of ``record`` with schema_version/ts (and, for v2, the
    model-provenance fields) defaulted when absent.

    ``schema_version`` defaults to the current ``SCHEMA_VERSION`` (v2); ``ts``
    defaults to the current UTC time.  On a v2 record, ``subject_model`` /
    ``analyst_model`` default to ``None`` so the v2 contract (fields present)
    holds even when the caller did not supply a model.
    """
    out = dict(record)
    if "schema_version" not in out:
        out["schema_version"] = SCHEMA_VERSION
    if "ts" not in out or not out["ts"]:
        out["ts"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if out["schema_version"] == "2":
        for field in _V2_MODEL_FIELDS:
            out.setdefault(field, None)
    return out


def emit(
    record: Dict[str, Any],
    raw_dir: Optional[Path] = None,
    *,
    validate: bool = True,
) -> Path:
    """Validate and append one findings record to the monthly JSONL file.

    Parameters
    ----------
    record:
        A dict conforming to findings-schema.md.  ``schema_version`` is
        set to the current ``SCHEMA_VERSION`` if absent; ``ts`` is set to the
        current UTC time if absent.  When the record defaults to v2, the
        ``subject_model`` / ``analyst_model`` fields default to ``None`` if
        absent so the v2 contract (fields present) holds.
    raw_dir:
        Override for the directory that holds ``findings-*.jsonl`` files.
        Defaults to ``<repo-root>/meta/data/raw/``.
    validate:
        Run schema validation before writing.  Callers that have already
        validated may pass ``False`` to skip the redundant check.

    Returns
    -------
    Path
        The absolute path of the file that was appended to.

    Raises
    ------
    FindingsValidationError
        If ``validate=True`` and the record fails schema validation.
    """
    # Fill in defaults before validation.
    record = _fill_defaults(record)

    if validate:
        validate_record(record)

    path = _findings_path(record["ts"], raw_dir)
    path.parent.mkdir(parents=True, exist_ok=True)

    line = json.dumps(record, ensure_ascii=False, sort_keys=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")

    return path


def emit_many(
    records: list[Dict[str, Any]],
    raw_dir: Optional[Path] = None,
    *,
    validate: bool = True,
) -> list[Path]:
    """Emit multiple records, returning their target file paths.

    Groups records by month and writes each monthly batch in a single
    ``open()`` call to minimise syscall overhead on large drain runs.
    """
    # Normalise + validate all records first so we never write a partial batch.
    normalised: list[Dict[str, Any]] = []
    for r in records:
        r = _fill_defaults(r)
        if validate:
            validate_record(r)
        normalised.append(r)

    # Group by month.
    by_path: dict[Path, list[Dict[str, Any]]] = {}
    for r in normalised:
        path = _findings_path(r["ts"], raw_dir)
        by_path.setdefault(path, []).append(r)

    written: list[Path] = []
    for path, batch in by_path.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            for r in batch:
                fh.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
        written.append(path)

    return written


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Emit one findings record to meta/data/raw/findings-<YYYY-MM>.jsonl",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument(
        "--record",
        metavar="JSON",
        help="Full record as a JSON string (all fields).  Mutually exclusive "
        "with the individual-field flags below.",
    )
    # Individual-field flags (alternative to --record).
    p.add_argument("--session-id", metavar="ID")
    p.add_argument("--project", metavar="NAME")
    p.add_argument(
        "--method",
        choices=sorted(_VALID_METHODS),
        help="How the extraction was found.",
    )
    p.add_argument(
        "--sub-method",
        metavar="TELL",
        default=None,
        help="The lexicon tell that fired (drain-lexicon only); omit for drain-model-skim.",
    )
    p.add_argument(
        "--finding-type",
        choices=sorted(_VALID_FINDING_TYPES),
    )
    p.add_argument(
        "--finding-ref",
        metavar="REF",
        help="Durable artifact reference (vault path, #N, things:<title>, …).",
    )
    p.add_argument(
        "--accepted",
        action="store_true",
        default=False,
        help="Mark the record as accepted (default: false / rejected).",
    )
    p.add_argument(
        "--subject-model",
        metavar="MODEL",
        default=None,
        help="v2: the analyzed-session model (from the stub 'model:' field); "
        "omit if unknown (recorded as null).",
    )
    p.add_argument(
        "--analyst-model",
        metavar="MODEL",
        default=None,
        help="v2: the drain-runner model that produced this record; "
        "omit if unknown (recorded as null).",
    )
    p.add_argument(
        "--ts",
        metavar="ISO8601",
        default=None,
        help="Override the timestamp (default: current UTC time).",
    )
    p.add_argument(
        "--raw-dir",
        metavar="DIR",
        default=None,
        help="Override the output directory (default: <repo-root>/meta/data/raw/).",
    )
    return p


def main(argv: Optional[list[str]] = None) -> int:
    p = _build_parser()
    args = p.parse_args(argv)

    raw_dir = Path(args.raw_dir) if args.raw_dir else None

    if args.record:
        try:
            record: Dict[str, Any] = json.loads(args.record)
        except json.JSONDecodeError as exc:
            print(f"ERROR: --record is not valid JSON: {exc}", file=sys.stderr)
            return 1
    else:
        # Build from individual flags.
        missing = [
            f
            for f, v in [
                ("--session-id", args.session_id),
                ("--project", args.project),
                ("--method", args.method),
                ("--finding-type", args.finding_type),
                ("--finding-ref", args.finding_ref),
            ]
            if not v
        ]
        if missing:
            print(
                f"ERROR: when --record is not given, these flags are required: "
                f"{', '.join(missing)}",
                file=sys.stderr,
            )
            return 1
        record = {
            "session_id": args.session_id,
            "project": args.project,
            "method": args.method,
            "sub_method": args.sub_method,
            "finding_type": args.finding_type,
            "finding_ref": args.finding_ref,
            "accepted": args.accepted,
            "subject_model": args.subject_model,
            "analyst_model": args.analyst_model,
        }
        if args.ts:
            record["ts"] = args.ts

    try:
        path = emit(record, raw_dir)
    except FindingsValidationError as exc:
        print(f"ERROR: findings record failed validation: {exc}", file=sys.stderr)
        return 1

    print(f"appended to {path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
