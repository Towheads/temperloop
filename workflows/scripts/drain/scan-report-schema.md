# Scan Report Schema — v1

`scan_stub.py` emits a JSON object with this stable shape.
Downstream consumers (e.g. `drain-mind`'s extraction phase) MUST handle
every field marked **required**; optional fields may be absent.

---

## Top-level object

| Field              | Type   | R/O      | Description |
|--------------------|--------|----------|-------------|
| `schema_version`   | string | required | Always `"1"` for this revision. |
| `stub`             | object | required | Stub metadata (see below). |
| `lexicon_matches`  | array  | required | Lexicon tell matches (may be empty). |
| `user_turns`       | array  | required | Digest of non-excluded user turns. |
| `tool_events`      | object | required | High-signal tool events from the raw `.jsonl`. |

---

## `stub`

| Field        | Type   | R/O      | Description |
|--------------|--------|----------|-------------|
| `path`       | string | required | Absolute path to the stub `.md` file. |
| `session_id` | string | required | Session UUID (from frontmatter `session_id:`). |
| `project`    | string | required | Project name (from frontmatter `project:`). |
| `date`       | string | optional | Session date `YYYY-MM-DD`. |
| `time`       | string | optional | Session time `HHMM`. |

---

## `lexicon_matches[]`

Each element is one match of a lexicon tell against extracted turn text.
Command-expansion turns (wrapped in `<command-name>`, `<command-message>`,
`<local-command-stdout>`, `<local-command-caveat>`, `<system-reminder>`, etc.)
are excluded before matching — this is the **self-match guard**.

Two tell sources feed this array (foundation #444):
- `lexicon.tsv` — scanned against **user** turns (`role: "user"`).
- `lexicon-assistant.tsv` — a narrow, high-precision set of self-worked-around-
  defect phrases scanned against **assistant** turns (`role: "assistant"`,
  `category: "worked-around-defect"`). These surface defects the assistant
  routed around mid-task and never filed.

| Field        | Type   | R/O      | Description |
|--------------|--------|----------|-------------|
| `tell`       | string | required | The lexicon pattern that matched. |
| `category`   | string | required | Lexicon category (e.g. `self-critique`, `worked-around-defect`). |
| `match_type` | string | required | `"literal"` or `"regex"`. |
| `turn_index` | int    | required | 0-based index into the full turns list. |
| `role`       | string | required | `"user"` (lexicon.tsv tells) or `"assistant"` (lexicon-assistant.tsv tells). |
| `line`       | string | required | The exact matching line. |
| `context`    | string | required | The matching line ±1 surrounding lines joined by `\n`. |
| `location`   | string | required | Human-readable location string, e.g. `"turn 3 (user) line 2"` or `"turn 5 (assistant) line 1"`. |

---

## `user_turns[]`

Digest of non-excluded user turns — the highest-signal, lowest-volume slice
a downstream consumer should inspect for new patterns.

| Field        | Type   | R/O      | Description |
|--------------|--------|----------|-------------|
| `turn_index` | int    | required | 0-based index into the full turns list. |
| `text`       | string | required | User turn text, truncated at 500 chars (ellipsis appended if truncated). |

---

## `tool_events`

High-signal events extracted from the raw `.jsonl` transcript.
All sub-arrays are empty when the `.jsonl` is absent or unreadable.

### `tool_events.ask_user_questions[]`

| Field       | Type         | R/O      | Description |
|-------------|--------------|----------|-------------|
| `questions` | string[]     | required | The question text(s) posed to the user. |
| `answer`    | string\|null | required | The user's answer, or `null` if unanswered. |
| `location`  | string       | required | `"jsonl line N"` where the `AskUserQuestion` tool_use appeared. |

### `tool_events.errors[]`

Both **hard** errors (the tool result carried `is_error: true`) and **soft**
failures (foundation #444 — `is_error` false/absent, but the content carries a
high-precision error signature such as `jq: error`, `Traceback`, `command not
found`, `fatal:`). A soft failure is the class where a Bash command emits a
downstream tool's error to stdout yet exits 0, so the harness never flags it.

| Field       | Type   | R/O      | Description |
|-------------|--------|----------|-------------|
| `tool_name` | string | required | The tool whose result failed (matched back from the `tool_use`). |
| `content`   | string | required | Error content (truncated at 300 chars). |
| `kind`      | string | required | `"hard"` (`is_error: true`) or `"soft"` (error-signature match). |
| `location`  | string | required | `"jsonl line N"`. |

### `tool_events.interrupts[]`

| Field      | Type   | R/O      | Description |
|------------|--------|----------|-------------|
| `location` | string | required | `"jsonl line N"` where the interrupt text appeared. |

### `tool_events.capture_calls[]`

| Field      | Type   | R/O      | Description |
|------------|--------|----------|-------------|
| `command`  | string | required | The `capture.sh` Bash invocation text (truncated at 400 chars). |
| `location` | string | required | `"jsonl line N"`. |

---

## Determinism guarantee

Given the same stub `.md` and `.jsonl`, `scan_stub.py` always emits byte-
identical JSON (Python's `json.dumps` is deterministic on dicts/lists of
strings and ints when the input order is stable, which it is here — events
are processed in file order).

## Self-match guard

The scanner excludes any `### User` turn whose text contains any of these
tag patterns before running lexicon matching:

- `<command-name>` — a slash-command invocation
- `<command-message>` — command message body
- `<local-command-stdout>` — CLI command output injected into context
- `<local-command-caveat>` — the local-command preamble block
- `<local-command-stdin>` — stdin injection
- `<system-reminder>` — system-prompt injection blocks (carry CLAUDE.md prose)
- `<tool_use` — tool-invocation context

This prevents lexicon patterns that appear verbatim in CLAUDE.md / skill prose
(which the session-end hook embeds into the stub via `command-message` /
`local-command-stdout`) from self-matching and producing false positives.
