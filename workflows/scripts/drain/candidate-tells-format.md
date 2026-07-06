# Candidate-Tells File — Format and Path

## Purpose

When `/tidy` Step 3 finds an extraction via **model-skim** (`method:
"drain-model-skim"`) — i.e., the model spotted signal in `report.user_turns[]`
that no lexicon tell covered — that finding is a measured miss. Accumulated
misses reveal which phrase patterns the lexicon should add next.

The **candidate-tells file** collects those missed phrases, one entry per
model-skim extraction, so the lexicon can grow from its own gaps. `check-in`
reviews the file at each daily check-in; the operator promotes promising candidates into
`workflows/scripts/drain/lexicon.tsv` or discards them.

---

## Path

```
~/dev/mind/Context/pipeline - candidate tells.md
```

This is a **vault note** (not a git-tracked file) so it persists across machines
via Obsidian Sync and is reviewable in the vault alongside other `Context/` notes.

---

## Format

The file is a flat Markdown list. Each entry is one line:

```
- <YYYY-MM-DD> · <project> · <finding_type> · `<missed phrase>` — <proposed tell>
```

| Part             | Meaning |
|------------------|---------|
| `<YYYY-MM-DD>`   | Date of the drain run that caught the miss. |
| `<project>`      | Project name from `report.stub.project`. |
| `<finding_type>` | The `finding_type` of the extraction (e.g. `decision`, `defect`). |
| `<missed phrase>` | A short (≤10 words), greppable verbatim or near-verbatim phrase from the user turn that the model used to identify the extraction. Keep it literal and tight — the goal is a lexicon pattern. |
| `<proposed tell>` | A one-line description of the pattern: what it signals and how a lexicon regex/literal would match it (e.g. `literal: "going with option" → decision`). |

Example entry:

```
- 2026-06-12 · foundation · decision · `going with option B` — literal: "going with option" → decision commit
```

---

## Append protocol

`/tidy` Step 3 appends candidate entries via
`mcp__obsidian-builtin__vault_append` (path: `Context/pipeline - candidate
tells.md`). If the file does not yet exist, create it with a header line before
the first entry:

```markdown
# Candidate Tells

Accumulated model-skim misses — phrases the model caught that the lexicon did not.
Review at check-in; promote promising ones into lexicon.tsv or discard.

```

Each new entry is appended as a single `- ...` line (no trailing blank lines
needed — vault_append handles newline separation).

---

## Review at check-in

`check-in` reads this file and presents any entries added since the last
review to the operator. Operator actions per entry:

- **Promote** — add the proposed tell to `lexicon.tsv` as a new row (literal or
  regex pattern, appropriate category, weight). Mark the entry `[promoted]`.
- **Discard** — the phrase was noise or too narrow. Mark the entry `[discarded]`.
- **Defer** — not sure yet. Leave the entry unmarked; it re-appears next check-in.

After review, entries older than 30 days and already marked `[promoted]` or
`[discarded]` may be archived (move to a `## Archive` section at the bottom of
the file) to keep the active list readable.
