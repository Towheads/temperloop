#!/usr/bin/env python3
"""join_keys.py -- the PYTHON loader for the join-key registry
(workflows/scripts/config/join-keys.tsv, temperloop#1910). This module and
its shell sibling join-keys-lib.sh are the ONLY two places a session id (or
any other join key the registry declares) is normalized -- a caller imports
this module and calls one of its normalize functions, never re-derives a
substring length, a regex, or a case-fold at the call site. See
join-keys.tsv's own header for the "why a registry, not five resolvers"
rationale.

Status convention (mirrors join-keys-lib.sh's rc 0/1/2 exactly, and the
registry's own ABSENT_SEMANTICS column -- the temperloop#1084 "absent is
never zero" discipline, generalized to every join key):

  - a normalized value is returned directly on success.
  - `Absent` (a distinct sentinel type, never `None` alone, and never
    conflated with a falsy value like `0`/`""`) is returned when the input
    was empty, unset, or the literal string "null"/"NULL".
  - `JoinKeyInvalid` is raised when the input was non-empty but malformed
    (a non-UUID-shaped session id, a non-numeric run id, ...).

No third-party dependencies -- stdlib only, so this module has zero install
footprint beyond the Python 3 every kernel checkout already requires for its
other workflows/scripts/*.py tools.

Usable as a library (`from join_keys import session_full, ABSENT`) or, for
the cross-language agreement test (tests/test_join_keys.sh), as a CLI:

    python3 join_keys.py apply <fn> [args...]

prints "STATUS\tVALUE" (STATUS in {ok, absent, invalid}) exactly like
join-keys-lib.sh's `jk_apply` dispatcher, so the fixture-driven agreement
test can compare both loaders' output line for line.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Optional


class _AbsentType:
    """Sentinel distinct from None/0/"" -- see module docstring."""

    def __repr__(self) -> str:  # pragma: no cover - cosmetic only
        return "ABSENT"

    def __bool__(self) -> bool:
        return False


ABSENT = _AbsentType()


class JoinKeyInvalid(ValueError):
    """Raised when a join-key input is non-empty but malformed."""


def _is_absent_literal(raw: Optional[str]) -> bool:
    return raw is None or raw == "" or raw in ("null", "NULL")


_SESSION_UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)


def session_full(raw: Optional[str]):
    """Normalized (lowercased) full session UUID, or ABSENT."""
    if _is_absent_literal(raw):
        return ABSENT
    lowered = raw.lower()
    if not _SESSION_UUID_RE.match(lowered):
        raise JoinKeyInvalid(f"not a UUID-shaped session id: {raw!r}")
    return lowered


def session8(raw: Optional[str]):
    """First 8 characters of session_full's normalized output, or ABSENT."""
    full = session_full(raw)
    if full is ABSENT:
        return ABSENT
    return full[:8]


def host_session_stamp(host: Optional[str], raw: Optional[str]):
    """"<host>:<sess8>", or ABSENT if either half is absent."""
    if _is_absent_literal(host):
        return ABSENT
    sess8 = session8(raw)
    if sess8 is ABSENT:
        return ABSENT
    return f"{host}:{sess8}"


def _normalize_int(raw: Optional[str], label: str):
    if _is_absent_literal(raw):
        return ABSENT
    if raw == "0":
        return "0"
    if not raw.isdigit() or raw[0] == "0":
        raise JoinKeyInvalid(f"{label}: not a plain integer: {raw!r}")
    return raw


def run_id(raw: Optional[str]):
    """Normalized GitHub Actions run id. "0" is a legal value, never
    conflated with absent (temperloop#1084 discipline)."""
    return _normalize_int(raw, "run_id")


def pr_number(raw: Optional[str]):
    """Normalized GitHub PR number. Same "0 is a value" discipline as
    run_id."""
    return _normalize_int(raw, "pr_number")


def message_id(raw: Optional[str]):
    """The id trimmed of leading/trailing whitespace, otherwise verbatim."""
    if _is_absent_literal(raw):
        return ABSENT
    trimmed = raw.strip()
    if trimmed == "":
        return ABSENT
    return trimmed


def plan_stem(raw: Optional[str]):
    """The filename component with a trailing .md extension and any leading
    directory path stripped."""
    if _is_absent_literal(raw):
        return ABSENT
    stem = Path(raw).name
    if stem.endswith(".md"):
        stem = stem[: -len(".md")]
    if stem == "":
        return ABSENT
    return stem


def closes_pattern(issue: Optional[str]) -> str:
    """The case-insensitive ERE pr-linkage.sh tests a PR body against for a
    bare Closes #<n> / Fixes #<n> / Resolves #<n> reference. THE single home
    for this pattern."""
    if not issue:
        raise JoinKeyInvalid("closes_pattern: issue number required")
    return r"(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#" + issue + r"\b"


_FUNCTIONS = {
    "session_full": session_full,
    "session8": session8,
    "host_session_stamp": host_session_stamp,
    "run_id": run_id,
    "pr_number": pr_number,
    "message_id": message_id,
    "plan_stem": plan_stem,
    "closes_pattern": closes_pattern,
}


def apply(fn: str, args: list):
    """Dispatch to the named function; returns (status, value) where status
    is one of "ok" / "absent" / "invalid" -- mirrors join-keys-lib.sh's
    jk_apply."""
    handler = _FUNCTIONS.get(fn)
    if handler is None:
        raise JoinKeyInvalid(f"apply: unknown function: {fn}")
    try:
        result = handler(*args)
    except JoinKeyInvalid:
        return ("invalid", "")
    if result is ABSENT:
        return ("absent", "")
    return ("ok", result)


def _main(argv: list) -> int:
    if len(argv) < 2 or argv[0] != "apply":
        print("usage: join_keys.py apply <fn> [args...]", file=sys.stderr)
        return 2
    fn = argv[1]
    args = argv[2:]
    status, value = apply(fn, args)
    print(f"{status}\t{value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
