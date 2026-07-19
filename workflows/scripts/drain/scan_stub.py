#!/usr/bin/env python3
"""
scan_stub.py — deterministic pre-scan scanner for session stub files.

Emits a JSON scan report consumed by tidy's extraction phase.
Zero model tokens: pure Python 3 stdlib + jq/grep-equivalent logic.

Usage:
    python3 workflows/scripts/drain/scan_stub.py <stub.md> [--jsonl <path>]
    python3 workflows/scripts/drain/scan_stub.py <stub.md> --json   # compact JSON (no indent)

Exit codes:
    0  scan completed (report written to stdout)
    1  fatal error (missing file, bad frontmatter, etc.)

Schema: see scan-report-schema.md in this directory.
"""

import argparse
import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# Lexicon loading
# ---------------------------------------------------------------------------

def _lexicon_path():
    """Return the absolute path to lexicon.tsv relative to this script."""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "lexicon.tsv")


def _assistant_lexicon_path():
    """Return the absolute path to lexicon-assistant.tsv relative to this script.

    The assistant-turn tell set is deliberately separate from lexicon.tsv: the
    main lexicon is scanned against user turns only (assistant turns carry
    CLAUDE.md-injected friction slugs — the self-match trap), so a narrow,
    high-precision set of self-worked-around-defect phrases is scanned against
    assistant turns instead (foundation #444).
    """
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "lexicon-assistant.tsv")


def load_lexicon(path=None):
    """Load lexicon.tsv and return a list of (pattern, category, match_type) tuples."""
    if path is None:
        path = _lexicon_path()
    rows = []
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            # Skip blank + comment lines.
            stripped = line.lstrip()
            if not stripped or stripped.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 3:
                # Malformed row — skip with warning to stderr.
                print(f"WARNING: lexicon line {lineno}: expected 3 tab-separated fields, got {len(parts)} — skipping", file=sys.stderr)
                continue
            pattern, category, match_type = parts
            if match_type not in ("literal", "regex"):
                print(f"WARNING: lexicon line {lineno}: unknown match_type '{match_type}' — skipping", file=sys.stderr)
                continue
            rows.append((pattern, category, match_type))
    return rows


# ---------------------------------------------------------------------------
# Stub parsing
# ---------------------------------------------------------------------------

def parse_frontmatter(text):
    """
    Parse YAML frontmatter delimited by leading '---\\n' ... '---\\n'.
    Returns (metadata_dict, body_str).
    We do a minimal hand-parse (no PyYAML dependency) sufficient for the
    scalar fields the stub format uses.
    """
    if not text.startswith("---\n"):
        return {}, text
    rest = text[4:]  # skip opening '---\n'
    end = rest.find("\n---\n")
    if end == -1:
        return {}, text
    yaml_block = rest[:end]
    body = rest[end + 5:]  # skip '\n---\n'

    meta = {}
    for line in yaml_block.splitlines():
        m = re.match(r'^(\w[\w_-]*):\s*(.*)', line)
        if m:
            key = m.group(1)
            val = m.group(2).strip().strip('"')
            meta[key] = val
    return meta, body


# ---------------------------------------------------------------------------
# Command-expansion exclusion
# ---------------------------------------------------------------------------

# Patterns that identify a "### User" turn as a command-expansion turn —
# turns that embed CLAUDE.md / slash-command prose and MUST NOT be lexicon-
# grepped (the false-positive trap the spec names).
#
# A turn is excluded when its text (after stripping the "### User\n\n" header)
# contains any of these tag patterns.
_CMD_EXPANSION_PATTERNS = [
    re.compile(r'<command-name>', re.IGNORECASE),
    re.compile(r'<command-message>', re.IGNORECASE),
    re.compile(r'<local-command-stdout>', re.IGNORECASE),
    re.compile(r'<local-command-caveat>', re.IGNORECASE),
    re.compile(r'<local-command-stdin>', re.IGNORECASE),
    # The system-prompt injection block used in build worker turns:
    # e.g. <system-reminder> blocks that may carry CLAUDE.md text verbatim.
    re.compile(r'<system-reminder>', re.IGNORECASE),
    # Tool invocation context blocks.
    re.compile(r'<tool_use\b', re.IGNORECASE),
]


def _is_command_expansion_turn(turn_text):
    """Return True if this turn text looks like a command-expansion turn."""
    for pat in _CMD_EXPANSION_PATTERNS:
        if pat.search(turn_text):
            return True
    return False


# ---------------------------------------------------------------------------
# Stub body → user turns extraction
# ---------------------------------------------------------------------------

def extract_user_turns(body):
    """
    Parse the '## Transcript' section and return a list of dicts:
        { 'role': 'user'|'assistant', 'text': str, 'excluded': bool }

    'excluded' is True for command-expansion turns that must not be grepped.
    """
    # Find the ## Transcript section.
    transcript_match = re.search(r'^## Transcript\s*\n', body, re.MULTILINE)
    if not transcript_match:
        return []

    transcript_text = body[transcript_match.end():]

    # Split into ### User / ### Assistant turns.
    # Each turn starts with "### User" or "### Assistant" on its own line.
    turn_pattern = re.compile(r'^### (User|Assistant)\s*\n', re.MULTILINE)
    splits = list(turn_pattern.finditer(transcript_text))

    turns = []
    for i, m in enumerate(splits):
        role = m.group(1).lower()
        start = m.end()
        end = splits[i + 1].start() if i + 1 < len(splits) else len(transcript_text)
        text = transcript_text[start:end].strip()
        excluded = _is_command_expansion_turn(text)
        turns.append({"role": role, "text": text, "excluded": excluded})

    return turns


# ---------------------------------------------------------------------------
# Lexicon matching
# ---------------------------------------------------------------------------

def _match_literal(pattern, text):
    """Case-insensitive substring match."""
    return pattern.lower() in text.lower()


def _match_regex(pattern, text):
    """Case-insensitive extended regex match (ERE, like grep -Ei)."""
    try:
        return bool(re.search(pattern, text, re.IGNORECASE))
    except re.error:
        return False


def apply_lexicon(turns, lexicon, roles=("user",)):
    """
    Run lexicon against non-excluded turns whose role is in `roles`.

    `roles` defaults to ("user",) — the main lexicon.tsv tells are user-authored
    insight signals (assistant turns carry friction-slug terms injected from
    CLAUDE.md references, the self-match trap, so scoping to user turns keeps
    recall focused). The assistant-turn tell set (lexicon-assistant.tsv,
    foundation #444) is run with roles=("assistant",) — a narrow, high-precision
    set of self-worked-around-defect phrases that do NOT appear in injected prose.

    Returns a list of match dicts:
        {
          "tell":     str,        # the pattern from lexicon
          "category": str,
          "match_type": str,      # "literal" | "regex"
          "turn_index": int,      # 0-based index into turns
          "role":     str,        # "user" | "assistant"
          "line":     str,        # the matching line
          "context":  str,        # ±1 surrounding lines joined by \n
          "location": str,        # e.g. "turn 3 (user) line 2"
        }
    """
    matches = []
    for turn_idx, turn in enumerate(turns):
        if turn["excluded"]:
            continue
        if turn["role"] not in roles:
            continue
        lines = turn["text"].splitlines()
        for line_idx, line in enumerate(lines):
            for pattern, category, match_type in lexicon:
                matched = (
                    _match_literal(pattern, line)
                    if match_type == "literal"
                    else _match_regex(pattern, line)
                )
                if not matched:
                    continue
                # Build ±1 context.
                ctx_lines = []
                if line_idx > 0:
                    ctx_lines.append(lines[line_idx - 1])
                ctx_lines.append(line)
                if line_idx + 1 < len(lines):
                    ctx_lines.append(lines[line_idx + 1])
                matches.append({
                    "tell": pattern,
                    "category": category,
                    "match_type": match_type,
                    "turn_index": turn_idx,
                    "role": turn["role"],
                    "line": line,
                    "context": "\n".join(ctx_lines),
                    "location": f"turn {turn_idx} ({turn['role']}) line {line_idx + 1}",
                })
    return matches


# ---------------------------------------------------------------------------
# User-turn digest
# ---------------------------------------------------------------------------

def user_turn_digest(turns):
    """
    Return the highest-signal slice of user turns: non-excluded user turns,
    each as a dict with index + text (truncated at 500 chars for compactness).
    """
    digest = []
    for i, turn in enumerate(turns):
        if turn["role"] != "user" or turn["excluded"]:
            continue
        digest.append({
            "turn_index": i,
            "text": turn["text"][:500] + ("…" if len(turn["text"]) > 500 else ""),
        })
    return digest


# ---------------------------------------------------------------------------
# Soft-failure detection (tool results that failed but are NOT is_error: true)
# ---------------------------------------------------------------------------

# High-precision signatures of a failed tool result whose `is_error` flag is
# False/absent — the "soft failure" class (foundation #444). A Bash command can
# emit a downstream tool's error to stdout (e.g. a `jq` parse error inside a
# board-adapter pipeline) and still exit 0, so the harness never sets
# `is_error: true`; the failure is then invisible to the is_error-only pass.
# These patterns are deliberately narrow — each is an unambiguous failure string,
# not a generic word like "error" that legitimate output carries. The drain step
# adjudicates each as an Unfiled-defect / friction / Mistakes candidate.
_ERROR_SIGNATURES = [
    re.compile(r"jq:\s*(parse\s+)?error", re.IGNORECASE),
    # "parse error" only when followed by location/colon language — bare
    # "parse error" appears in benign prose ("handle parse error gracefully").
    re.compile(r"\bparse error\b\s*(?:at|in|on|near|:)", re.IGNORECASE),
    re.compile(r"Traceback \(most recent call last\)"),
    re.compile(r"\bcommand not found\b", re.IGNORECASE),
    re.compile(r"\bNo such file or directory\b", re.IGNORECASE),
    re.compile(r"\bSyntaxError\b"),
    # git emits "fatal:" line-initial; line-anchoring rejects mid-line prose
    # like "this is not fatal: ..." that bare \bfatal: would still match.
    re.compile(r"(?m)^fatal:", re.IGNORECASE),
    re.compile(r"\bpermission denied\b", re.IGNORECASE),
    re.compile(r"\bsegmentation fault\b", re.IGNORECASE),
    re.compile(r"\bunbound variable\b", re.IGNORECASE),
    # MCP tool wrong-parameter error: a tool called with a key the schema
    # doesn't define (observed: `Key "dirpath" does not exist`, candidate-tells
    # 2026-06-27). `[^"]+` (not `\w+`) so the quoted key may carry non-identifier
    # chars — a dotted/hyphenated param name or a `::`-nested vault_patch target;
    # the `Key "…" does not exist` frame is the precision anchor. Deterministic
    # machine string → no IGNORECASE, matching the Traceback/SyntaxError
    # precedent above (promoted from candidate-tells, foundation #662).
    re.compile(r'\bKey "[^"]+" does not exist'),
    # Headless/sandbox path violation: a `claude -p` tool tried to read a file
    # outside the allowed working directories. Verbatim observed harness string
    # (candidate-tells 2026-06-27); deterministic → no IGNORECASE (foundation #662).
    re.compile(r"may only concatenate files from the allowed working directories"),
    re.compile(r"Could not resolve to a [Uu]ser or bot with the login", re.IGNORECASE),  # gh assignee/login resolution failure
    re.compile(r"maximum number of (certificates|devices|profiles)", re.IGNORECASE),  # Apple Developer vendor-quota slow outage
    # Deferred tool called before its schema was ToolSearch-loaded (Monitor /
    # TaskUpdate / MCP class; ≥5 sessions, one stalled unattended run — see
    # foundation#1201). Verbatim harness string → no IGNORECASE (K#422).
    re.compile(r"\bInputValidationError\b"),
    # Vendored-copy / toolkit-sync drift: a synced script older than its
    # caller's assumptions rejects a flag the caller passes (K#422).
    re.compile(r"\bunknown (arg|argument|option|flag)\b|\bunrecognized option\b", re.IGNORECASE),
    # capture.sh board-add race: this warning is followed by a success line on
    # the very next line, so it is invisible to both the is_error pass and a
    # human skimming — the item silently drops from Backlog-only intake (K#422).
    re.compile(r"did not resolve in time|may be unstatused", re.IGNORECASE),
]


def _matches_error_signature(text):
    """Return True if `text` carries a high-precision soft-failure signature."""
    if not text:
        return False
    for pat in _ERROR_SIGNATURES:
        if pat.search(text):
            return True
    return False


# ---------------------------------------------------------------------------
# Structural detectors (temperloop #421)
# ---------------------------------------------------------------------------
#
# Four detectors that are structurally unreachable by the turn-scanning /
# error-signature passes above — each keys off a shape in the raw tool stream
# (an AskUserQuestion answer, a repeated Bash export prefix, a JSON-RPC error
# code, a mutating-MCP tool identity) rather than a line of prose.

# (1a) AUQ answer expressing confusion — a top-signal feedback moment: the
# operator did not answer the question, they signalled they couldn't. Narrow,
# high-precision phrases (not a bare "confused" that benign prose carries).
_AUQ_CONFUSION_RE = re.compile(
    r"\b("
    r"i (?:do not|don't) understand"
    r"|i(?:'m| am) (?:confused|lost)"
    r"|(?:need|want) more context"
    r"|not sure what you(?:'re| are) asking"
    r"|(?:this )?makes no sense"
    r"|no idea what"
    r")\b",
    re.IGNORECASE,
)

# (1b) AUQ answer that is itself a question, or opens with a counter-proposal
# stem — the tell that the presented option set omitted the right answer, so the
# operator had to type past it. Applied to the *selected answer value*, not the
# wrapper string (see _scan_auq_answer).
_AUQ_OMITTED_START_RE = re.compile(
    r"^\s*(?:why\b|what about\b|couldn['’]?t\b|can['’]?t\b|how about\b)",
    re.IGNORECASE,
)

# The AskUserQuestion tool_result wraps the selection as
#   Your questions have been answered: "<question>"="<answer>"
# so the *answer value* the operator actually gave is the RHS of each `="..."`.
# Extract those so (1b)'s prefix/suffix tests see the answer, not the wrapper.
_AUQ_ANSWER_VALUE_RE = re.compile(r'="((?:[^"\\]|\\.)*)"')


def _auq_answer_values(answer):
    """Return the selected answer value(s) from an AUQ result string.

    Falls back to the whole (stripped) string when the `="..."` wrapper is
    absent — a free-text / non-standard answer shape.
    """
    if not answer:
        return []
    vals = _AUQ_ANSWER_VALUE_RE.findall(answer)
    if vals:
        return [v.strip() for v in vals if v.strip()]
    stripped = answer.strip()
    return [stripped] if stripped else []


def _scan_auq_answer(answer):
    """Scan an AUQ answer string; return a sorted list of signal strings.

    Signals: "confusion" (1a) and/or "omitted-option" (1b).
    """
    signals = set()
    values = _auq_answer_values(answer)
    for val in values:
        if _AUQ_CONFUSION_RE.search(val):
            signals.add("confusion")
        if val.endswith("?") or _AUQ_OMITTED_START_RE.search(val):
            signals.add("omitted-option")
    # Confusion phrasing can also appear when the wrapper wasn't parseable into
    # values but the whole answer still carries it — belt-and-suspenders for 1a
    # (1b's positional tests deliberately stay on the extracted value only).
    if answer and _AUQ_CONFUSION_RE.search(answer):
        signals.add("confusion")
    return sorted(signals)


# (2) Repeated inline env-var workaround — a leading `export VAR=value` that the
# session re-types verbatim ahead of many separate Bash calls, instead of
# fixing the default (F#1141). Capture the *leading* export assignment only;
# quoted values (spaces) and bare values both supported.
_EXPORT_PREFIX_RE = re.compile(
    r'^\s*(export\s+[A-Za-z_][A-Za-z0-9_]*='
    r'''(?:"[^"]*"|'[^']*'|\S*))'''
)

# Minimum distinct Bash calls carrying the same verbatim export prefix before it
# is flagged as a workaround (the "3+ separate Bash calls" acceptance bar).
_ENV_PREFIX_MIN_CALLS = 3


def _extract_export_prefix(command):
    """Return the leading `export VAR=value` prefix of a Bash command, or None."""
    if not command:
        return None
    m = _EXPORT_PREFIX_RE.match(command)
    if not m:
        return None
    return m.group(1).strip()


# (3) MCP JSON-RPC -32602 "Invalid arguments" — always the caller's bug, and
# invisible when folded into the generic errors[] list. Counted as its own
# bucket. DOTALL so the `.*` between the code and "Invalid arguments" spans
# newlines in a multi-line error body.
_MCP_INVALID_ARGS_RE = re.compile(
    r"MCP error -32602.*Invalid arguments", re.IGNORECASE | re.DOTALL
)

# (4) Mutating-MCP timeout — a vault_write / vault_move / vault_delete result
# that timed out leaves the store in UNKNOWN state (applied? partial? not at
# all?), materially unlike a read timeout. Distinct bucket. Matched by the
# mutating tool's identity (substring of the fully-qualified MCP tool name) plus
# a /timed out/i result body.
_MUTATING_MCP_TOOL_SUBSTRINGS = ("vault_write", "vault_move", "vault_delete")
_TIMED_OUT_RE = re.compile(r"timed out", re.IGNORECASE)


def _is_mutating_mcp_tool(tool_name):
    """Return True if `tool_name` is a mutating vault MCP op."""
    if not tool_name:
        return False
    return any(sub in tool_name for sub in _MUTATING_MCP_TOOL_SUBSTRINGS)


# ---------------------------------------------------------------------------
# Tool-event parsing from raw .jsonl
# ---------------------------------------------------------------------------

def parse_tool_events(jsonl_path):
    """
    Parse the raw Claude Code .jsonl transcript for high-signal tool events:

    - AskUserQuestion: Q + A pairs
    - tool_result failures: tool name + error content, both HARD (is_error: true)
      and SOFT (is_error false/absent but content carries an error signature —
      foundation #444; each error record carries kind: "hard" | "soft")
    - [Request interrupted by user for tool use] text events
    - capture.sh Bash invocations: the command body (defect-at-source signals)

    Returns a dict with keys:
        ask_user_questions:    list of {id, question, answer, location}
        errors:                list of {tool_name, content, kind, location}
        interrupts:            list of {location}
        capture_calls:         list of {command, location}
        auq_answer_flags:      list of {signal, question, answer, location} (#421-1)
        repeated_env_prefixes: list of {prefix, count, locations} (#421-2)
        mcp_invalid_args:      list of {tool_name, content, location} (#421-3)
        mutating_mcp_timeouts: list of {tool_name, content, location} (#421-4)
    """
    result = {
        "ask_user_questions": [],
        "errors": [],
        "interrupts": [],
        "capture_calls": [],
        "auq_answer_flags": [],
        "repeated_env_prefixes": [],
        "mcp_invalid_args": [],
        "mutating_mcp_timeouts": [],
    }

    if not jsonl_path or not os.path.isfile(jsonl_path):
        return result

    # (#421-2) Collect every Bash export-prefix as (prefix, location) so a
    # post-pass can flag any prefix repeated verbatim across 3+ separate calls.
    export_prefix_hits = []  # list of (prefix, location) in file order

    # First pass: collect tool_use events so we can match them to tool_results.
    tool_use_by_id = {}  # id → {name, input, event_index}
    events = []

    try:
        with open(jsonl_path, encoding="utf-8", errors="replace") as fh:
            for lineno, raw in enumerate(fh, 1):
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    obj = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                events.append((lineno, obj))
    except OSError:
        return result

    for event_idx, (lineno, obj) in enumerate(events):
        etype = obj.get("type")
        msg = obj.get("message")
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            # Check for interrupt in plain-text content.
            if isinstance(content, str) and "[Request interrupted by user for tool use]" in content:
                result["interrupts"].append({"location": f"jsonl line {lineno}"})
            continue

        for item in content:
            if not isinstance(item, dict):
                continue
            itype = item.get("type")

            # ── tool_use ──────────────────────────────────────────────────
            if itype == "tool_use":
                tid = item.get("id", "")
                tname = item.get("name", "")
                tinput = item.get("input", {})
                tool_use_by_id[tid] = {
                    "name": tname,
                    "input": tinput,
                    "location": f"jsonl line {lineno}",
                }

                # AskUserQuestion: record question(s) now; answer matched on tool_result.
                if tname == "AskUserQuestion":
                    questions_list = []
                    if isinstance(tinput, dict):
                        for q in tinput.get("questions", []):
                            if isinstance(q, dict):
                                questions_list.append(q.get("question", ""))
                    result["ask_user_questions"].append({
                        "id": tid,
                        "questions": questions_list,
                        "answer": None,
                        "location": f"jsonl line {lineno}",
                    })

                # capture.sh Bash invocation: look for capture in cmd text.
                if tname == "Bash" and isinstance(tinput, dict):
                    cmd = tinput.get("command", "")
                    if "capture" in cmd and "--board" in cmd:
                        result["capture_calls"].append({
                            "command": cmd[:400],
                            "location": f"jsonl line {lineno}",
                        })
                    # (#421-2) Record any leading `export VAR=value` prefix for
                    # the repeated-workaround post-pass below.
                    prefix = _extract_export_prefix(cmd)
                    if prefix:
                        export_prefix_hits.append((prefix, f"jsonl line {lineno}"))

            # ── tool_result ───────────────────────────────────────────────
            elif itype == "tool_result":
                tid = item.get("tool_use_id", "")
                is_error = item.get("is_error", False)
                rcontent = item.get("content")

                # Match back to the tool_use to get the name.
                tu = tool_use_by_id.get(tid, {})
                tname = tu.get("name", "")

                # Flatten the result content to text once (used for both the
                # hard/soft error check and the AskUserQuestion answer below).
                result_text = ""
                if isinstance(rcontent, list):
                    result_text = " ".join(
                        c.get("text", "") for c in rcontent if isinstance(c, dict)
                    )
                elif isinstance(rcontent, str):
                    result_text = rcontent

                # Hard error (is_error: true) OR soft failure (not flagged, but
                # the content carries an unambiguous error signature — #444).
                soft = (not is_error) and _matches_error_signature(result_text)
                if is_error or soft:
                    result["errors"].append({
                        "tool_name": tname,
                        "content": result_text[:300],
                        "kind": "hard" if is_error else "soft",
                        "location": f"jsonl line {lineno}",
                    })

                # (#421-3) MCP -32602 "Invalid arguments" — its own counted
                # bucket (always the caller's bug; invisible among errors[]).
                if _MCP_INVALID_ARGS_RE.search(result_text):
                    result["mcp_invalid_args"].append({
                        "tool_name": tname,
                        "content": result_text[:300],
                        "location": f"jsonl line {lineno}",
                    })

                # (#421-4) Mutating-MCP timeout — vault_write/move/delete that
                # timed out leaves the store in UNKNOWN state; its own bucket.
                if _is_mutating_mcp_tool(tname) and _TIMED_OUT_RE.search(result_text):
                    result["mutating_mcp_timeouts"].append({
                        "tool_name": tname,
                        "content": result_text[:300],
                        "location": f"jsonl line {lineno}",
                    })

                # AskUserQuestion answer: match by tool_use_id.
                if tname == "AskUserQuestion":
                    # Find the corresponding question record and fill in answer.
                    for aq in result["ask_user_questions"]:
                        if aq["id"] == tid:
                            aq["answer"] = result_text[:500]
                            break

            # ── text ──────────────────────────────────────────────────────
            elif itype == "text":
                text_val = item.get("text", "")
                if "[Request interrupted by user for tool use]" in text_val:
                    result["interrupts"].append({"location": f"jsonl line {lineno}"})

    # (#421-1) AUQ answer-field scan: flag confusion answers (1a) and
    # answers that are themselves questions / counter-proposals (1b — the
    # option set omitted the right answer). Runs after answers are populated.
    for aq in result["ask_user_questions"]:
        answer = aq.get("answer")
        if not answer:
            continue
        questions = aq.get("questions", [])
        question = questions[0] if questions else ""
        for signal in _scan_auq_answer(answer):
            result["auq_answer_flags"].append({
                "signal": signal,
                "question": question,
                "answer": answer[:500],
                "location": aq.get("location", ""),
            })

    # (#421-2) Repeated inline env-var workaround: flag any export prefix that
    # appeared verbatim ahead of _ENV_PREFIX_MIN_CALLS (3+) separate Bash calls.
    prefix_locations = {}  # prefix → [locations] in file order
    for prefix, loc in export_prefix_hits:
        prefix_locations.setdefault(prefix, []).append(loc)
    for prefix, locs in prefix_locations.items():
        if len(locs) >= _ENV_PREFIX_MIN_CALLS:
            result["repeated_env_prefixes"].append({
                "prefix": prefix,
                "count": len(locs),
                "locations": locs,
            })

    # Clean up: remove internal 'id' from AskUserQuestion records (not part of public schema).
    for aq in result["ask_user_questions"]:
        aq.pop("id", None)

    return result


# ---------------------------------------------------------------------------
# Top-level scan
# ---------------------------------------------------------------------------

def scan_stub(stub_path, lexicon_path=None, jsonl_override=None, assistant_lexicon_path=None):
    """
    Scan a session stub and return the scan report as a dict.

    stub_path               — path to the session stub .md file
    lexicon_path            — override path for lexicon.tsv (default: sibling file)
    jsonl_override          — override path for the raw .jsonl (default: from stub frontmatter)
    assistant_lexicon_path  — override path for lexicon-assistant.tsv (default: sibling file)
    """
    with open(stub_path, encoding="utf-8") as fh:
        stub_text = fh.read()

    meta, body = parse_frontmatter(stub_text)

    session_id = meta.get("session_id", "")
    project = meta.get("project", "")
    jsonl_path = jsonl_override or meta.get("transcript", "")

    lexicon = load_lexicon(lexicon_path)
    assistant_lexicon = load_lexicon(assistant_lexicon_path or _assistant_lexicon_path())
    turns = extract_user_turns(body)
    # User-turn tells (main lexicon) + assistant-turn self-worked-around-defect
    # tells (assistant lexicon, #444), concatenated into one lexicon_matches list.
    matches = apply_lexicon(turns, lexicon, roles=("user",))
    matches += apply_lexicon(turns, assistant_lexicon, roles=("assistant",))
    # state-collision tells (stale/dirty/conflicting state) ALSO fire on
    # ASSISTANT turns. The "branched off a stale local main → DIRTY/redundant PR"
    # realization is almost always assistant-narrated, not user-typed, so the
    # user-only pass above misses it entirely (the gap that left this recurring
    # rework invisible to /tidy). We scan only the state-collision subset
    # against assistant turns — NOT the whole user lexicon: the friction-slug
    # rows echo injected CLAUDE.md prose and would self-match (#444), but the
    # state-collision tells are real-world state strings ("DIRTY", "commits
    # behind", "stale local main") that don't appear in that prose.
    state_collision = [row for row in lexicon if row[1] == "state-collision"]
    matches += apply_lexicon(turns, state_collision, roles=("assistant",))
    digest = user_turn_digest(turns)
    tool_events = parse_tool_events(jsonl_path)

    report = {
        "schema_version": "1",
        "stub": {
            "path": os.path.abspath(stub_path),
            "session_id": session_id,
            "project": project,
            "date": meta.get("date", ""),
            "time": meta.get("time", ""),
        },
        "lexicon_matches": matches,
        "user_turns": digest,
        "tool_events": tool_events,
    }
    return report


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Scan a session stub and emit a JSON scan report.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("stub", help="Path to the session stub .md file")
    parser.add_argument(
        "--jsonl",
        metavar="PATH",
        default=None,
        help="Override the .jsonl transcript path (default: from stub frontmatter)",
    )
    parser.add_argument(
        "--lexicon",
        metavar="PATH",
        default=None,
        help="Override the lexicon.tsv path (default: sibling of this script)",
    )
    parser.add_argument(
        "--json",
        dest="compact",
        action="store_true",
        help="Emit compact JSON (no indentation)",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.stub):
        print(f"ERROR: stub not found: {args.stub}", file=sys.stderr)
        sys.exit(1)

    report = scan_stub(args.stub, lexicon_path=args.lexicon, jsonl_override=args.jsonl)
    indent = None if args.compact else 2
    print(json.dumps(report, indent=indent, ensure_ascii=False))


if __name__ == "__main__":
    main()
