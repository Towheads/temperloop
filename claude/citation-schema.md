# Citation markers for standing kernel rules

Every registered standing kernel rule in `claude/**/*.md` carries a same-line **citation marker** tracing it to the evidence that earned its place — the per-rule citation audit at temperloop#719 established the baseline set, and the marker-presence check in `workflows/scripts/validate-prose-budget.sh` (a `checks` gate via `scripts/quality-gates.sh`) keeps it from silently eroding or growing untraced. <!-- cite: CS.1 guard:workflows/scripts/validate-prose-budget.sh -->

## Grammar

A marker is an HTML comment appended to an existing line (it renders invisibly in Markdown and adds **zero lines** — the prose-budget caps are untouched by construction; same mechanism as `check-knob-prose.sh`'s `<!-- knob-prose:allow -->`):

```
<!-- cite: <row-id> <class>:<ref> -->

row-id  ::=  [A-Z]+ "." [0-9]+          e.g. K.7, B.24, AG.6
class   ::=  incident | guard | class | keep
ref     ::=  one whitespace-free token (see the classes below)
```

Exactly one `class:ref` pair per marker — the *primary* citation. A rule with several supporting citations keeps the full set in the audit artifact (temperloop#719's epic-artifact comments), which the `row-id` resolves against.

## Citation classes

- **`incident:<ref>`** — a concrete past failure: an issue/PR ref in the repo shorthand (`K#N` = temperloop#N, `F#N` = foundation#N, `S#N`/`M#N`/`W#N` per the kernel § Communication conventions), a `PR#N`, or a `commit-<sha>` token.
- **`guard:<path>`** — an existing mechanical guard (script/hook/CI path) the rule narrates or sequences; the ref is the guard's repo-relative path.
- **`class:<kebab-name>`** — a named catastrophic failure class the rule prophylactically prevents (prophylactic rules are legitimate; the name is a short kebab-case coinage, stable per row).
- **`keep:<YYYY-MM-DD>`** — kept by explicit operator disposal on an otherwise-uncited rule; the ref is the /check-in disposal date, and the row id resolves which disposal.

## The mechanical definition (what the check enforces)

**"A standing rule needing a marker" is defined as: a row in `workflows/scripts/config/citation-registry.tsv`** (`row-id <TAB> file`, seeded from the #719 audit table). The check in `validate-prose-budget.sh` enforces an exact 1:1 reconciliation, both directions:

- every registry row's marker appears **exactly once** in its registered file (missing → red; duplicated → red);
- every marker found in any tracked `claude/**/*.md` file maps to a registry row for that same file (unregistered → red);
- every `<!-- cite:` occurrence outside a fenced code block or backtick code span must parse to the grammar above (malformed → red).

Markers inside fenced code blocks or backtick code spans are ignored — a marker in code font is a quotation, never a live marker (that is how this document shows the grammar without registering it). Prose that has no registry row needs no marker — deciding whether new prose *is* a standing rule stays a judgment call; the registry row is how that judgment is recorded mechanically.

## Placement rules

- Append the marker at the end of the rule's **first prose line** (or the single line the rule occupies).
- **Never on a heading line** — heading-anchored tooling (compose seams, section detectors, patch targets) must keep matching pristine heading text.
- **Never on a machine-parsed or frozen line** (`claude/presentation-plane.md`'s index — e.g. the live-drain registry table rows in `claude/commands/tidy.md`, frozen template lines): put the marker on the adjacent owning prose instead.
- **Never inside a fenced code block** — the scanner skips those, so a marker there is silently dead.

## Maintaining the set

- **Adding a standing rule** → add its marker and its `citation-registry.tsv` row **in the same change** (the check fails half-present additions in either direction).
- **Deleting or collapsing a rule** → remove its marker and its registry row together. A rule collapsed to a pointer at its mechanism keeps one row, marking the pointer line with `guard:<the-mechanism>`.
- **Row ids are stable**: rows born in the #719 audit keep their audit ids; a new rule mints the file's existing prefix with the next unused integer (new files mint a fresh prefix). Cluster rows (e.g. AG.6/AG.7 across the persona/reviewer charter families) legitimately appear once **per registered file**.
