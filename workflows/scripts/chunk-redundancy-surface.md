# Chunk-stream format — the seam between #854 and #855

`workflows/scripts/chunk-redundancy-surface.sh` (temperloop#854) prints one
JSON object per line (NDJSON / JSON-Lines, UTF-8) to stdout. This document is
the authoritative, field-by-field reference for that stream — the interface
half (b) (temperloop#855, scoring + precision measurement) consumes. Half (b)
can change its scoring approach (embedding similarity, an LLM-judge pass, a
hybrid, or something else entirely) without this document or the producer
script changing, as long as it keeps reading this shape.

Nothing in this document, or in the script it describes, computes a
similarity score, a redundancy verdict, or any cross-chunk comparison. This
is a segmentation contract only — see `chunk-redundancy-surface.sh`'s own
header comment for the full rule-sized-unit boundary rationale.

## Stream shape

- One compact JSON object per line, `\n`-terminated, no blank lines, no
  trailing commentary.
- Rows appear in `workflows/scripts/config/contributor-manifest.tsv` order;
  within a row, chunks appear in document order (ascending `start_line`).
- Object keys are alphabetically sorted (`jq -S`) — a consumer should key
  off field NAMES, never positional order.
- Diagnostics (a one-line run summary, any warning) go to **stderr only**.
  stdout is a pure, directly `jq`/`json.loads`-parseable stream.
- Deterministic: the same tracked-tree input produces byte-identical stdout
  on macOS and Linux CI (see the script's own header for the mechanism).

## Record fields

| Field | Type | Meaning |
|---|---|---|
| `id` | string | `<path>#<chunk_index>` — stable across runs on an unchanged tree. Not guaranteed stable across a tree EDIT to the same file (an inserted paragraph shifts every later chunk's index) — a consumer that needs cross-run chunk identity should key on `sha256` instead, or accept that IDs are a within-run/within-tree-snapshot convenience only. |
| `path` | string | Repo-relative path, verbatim from the manifest row. |
| `unit` | string | `full` \| `frontmatter:description` — the manifest row's own extraction unit (see `contributor-manifest.tsv`'s header for the closed set). |
| `label` | string | The manifest row's contributor-category label (e.g. `kernel-pointer`, `command-listing`, `agent-listing`) — free text, for grouping. |
| `load` | string | The manifest row's load class (`harness-auto` \| `pointer-turn1` \| `none` \| `n/a`) — carried through so a consumer can weight or filter by how a chunk's source content actually reaches a session. |
| `chunk_index` | integer | 1-based position of this chunk within its row (document order). |
| `chunk_count` | integer | Total chunks emitted for this row — lets a consumer tell "is this the only chunk from this file" without a second pass. |
| `section` | string \| null | The nearest enclosing markdown heading path, `" > "`-joined from the outermost heading in, each segment carrying its own `#`-prefix (e.g. `"# Top doc > ## Section A"`). `null` when no heading applies (content before the first heading, or a `frontmatter:description` row, which has no heading context at all). |
| `start_line` | integer | 1-based line number (in the source file) where this chunk begins. |
| `end_line` | integer | 1-based line number (inclusive) where this chunk ends. |
| `byte_count` | integer | Exact byte length of `text` (UTF-8 bytes, matching `wc -c`). |
| `word_count` | integer | Whitespace-delimited word count of `text` (matching `wc -w`), same proxy convention `count-prose.sh` uses in place of a tokenizer dependency. |
| `sha256` | string | Lowercase hex SHA-256 digest of `text`'s exact bytes — a cheap exact-duplicate check a consumer can run before ever invoking a similarity/LLM pass (two chunks with equal `sha256` are verbatim-identical, not merely similar). |
| `text` | string | The chunk's exact content: its source lines joined by `\n`, **no trailing newline**. This is the field half (b) actually compares for redundancy. |

## What "a chunk" is

See `chunk-redundancy-surface.sh`'s header for the full rule (blank lines,
ATX headings, top-level list markers, and fenced code blocks as the four
boundary/opacity signals). In one line: a chunk is one paragraph, or one
top-level list item (bullet or numbered — with any indented sub-content
swept in as part of that same item), or one opaque fenced code block. A
`frontmatter:description` row's single extracted scalar is always exactly
one chunk.

## Non-goals (repeated from the producer script, because this is the seam
a reader is likeliest to skim before the script itself)

- No similarity scoring, no shingle overlap, no embedding, no LLM-judge call
  — anywhere in this stream's production.
- No cap, no threshold, no pass/fail verdict on any chunk or file. This
  script's own exit code reflects only "did segmentation complete", never a
  judgment about the prose.
- No claim that two chunks with different `sha256` values are unrelated —
  that judgment, paraphrase-aware or otherwise, is entirely half (b)'s job.

## Labelled fixture corpus (a separate deliverable, same issue)

`workflows/scripts/config/redundancy-fixtures.json` — hand-authored pairs of
chunk-shaped text with a `positive`/`negative` label and a one-line
rationale, for half (b) to measure its own detector's precision against.
It is a fixture corpus, not an example of this script's real output: entries
are illustrative synthetic text, not chunks extracted from a live file, so
they carry no `path`/`start_line`/etc. provenance fields. See that file's own
header and `workflows/scripts/config/check-redundancy-fixtures.sh` for its
schema and the mechanically-enforced "no shared 10-word shingle" property on
every `positive` pair.
