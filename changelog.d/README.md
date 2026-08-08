# `changelog.d/` — one changelog entry per file

This directory holds **changelog fragments**: one file per changelog entry,
written by the PR that makes the change and folded into `CHANGELOG.md`'s
`## [Unreleased]` section at release-cut time by
[`scripts/assemble-changelog.sh`](../scripts/assemble-changelog.sh).

## Why

`VERSIONING.md` requires a `## [Unreleased]` entry for every contract-surface
change, and `workflows/scripts/check-changelog-entry.sh` enforces it — so
**25 of the last 25** commits touched `CHANGELOG.md`. Two concurrent PRs both
inserting a line at the same anchor in the same file collide *structurally*,
every time, and each collision costs a rebase or a merge-queue ejection.

Two PRs writing two **distinct new files** share no line and cannot conflict.
That is the whole idea. Direction ratified by the keystone spike
(temperloop#1311, epic #1299).

## Filename format

```
changelog.d/<slug>.<category>[.breaking].md
```

| field | meaning |
|---|---|
| `<slug>` | `[A-Za-z0-9][A-Za-z0-9_-]*` — **no dots** (`.` is the field delimiter). Convention: `<issue#>-<branch-slug>`, e.g. `1321-changelog-fragment-format`. |
| `<category>` | one of `added`, `changed`, `deprecated`, `removed`, `fixed`, `security` — Keep a Changelog's six, lowercased. |
| `.breaking` | optional. Present ⇒ the assembled sub-heading gets the ` — BREAKING` suffix. |

Examples:

```
changelog.d/1321-changelog-fragment-format.changed.md
changelog.d/1288-doctor-exit-code.fixed.md
changelog.d/1322-changelog-gate-cutover.changed.breaking.md
```

**The format is index-free, deliberately.** There is no ordering file and no
manifest in this directory — category, breakingness and sort key all derive
from the filename itself. A shared index would recreate the exact same
single-file hotspot one directory over, which is why index-freedom is a
*condition* of the ratified direction rather than a style preference.

## File contents

The body is the markdown that would have gone under `### <Category>` in
`## [Unreleased]` — usually one bullet, sometimes several paragraphs. Write
the bullet, nothing else:

```markdown
- **`doctor` now exits non-zero when the installed kit and the running
  checkout disagree** (#1288). Previously it printed the mismatch and exited
  0, so CI treated a split install as healthy.
```

Rules the assembler enforces (it fails the cut rather than dropping an entry):

- **No `#`, `##` or `###` heading in the body.** The assembler owns the
  `### <Category>` heading. `####` and deeper are fine inside an entry.
- **Not empty.** An empty fragment is a lost entry.
- **A recognised filename.** An unparseable name fails loudly; it is never
  skipped silently.

Leading and trailing blank lines are trimmed; interior blank lines are kept.

## `BREAKING`

`changelog_breaking_sections()` — the detector `update-kernel` and
`temperloop update` read to gate a downstream pull — sets its flag from
**heading lines only**; body prose never sets it. So breakingness is declared
by the `.breaking` marker in the filename, and the assembler turns that into
`### Changed — BREAKING` plus the `## [Unreleased] — BREAKING` suffix. Writing
the word "breaking" in your prose does *not* mark the release.

## Assembly

At the cut:

```sh
scripts/assemble-changelog.sh --check     # validate every fragment, write nothing
scripts/assemble-changelog.sh --dry-run   # print the resulting CHANGELOG.md
scripts/assemble-changelog.sh             # rewrite CHANGELOG.md, delete the fragments
```

Assembly order is total and derives from the filenames alone: canonical
category order (Added, Changed, Deprecated, Removed, Fixed, Security), then
`LC_ALL=C` lexicographic by filename within a category.

The assembler is **additive**: it merges into whatever `## [Unreleased]`
already holds rather than replacing it — existing sub-sections keep their
order and their content, fragments append to the end of their category's
section, and a category with no section yet gets a new one. A PR that still
writes a direct `## [Unreleased]` line instead of a fragment is therefore
harmless rather than lost.

## Status

Fragments are **available, not yet required**.
`workflows/scripts/check-changelog-entry.sh` is unchanged, and a direct
`## [Unreleased]` entry still satisfies it. temperloop#1322 cuts the gate over
to fragments; until then both paths work.

`README.md` (this file) and dotfiles such as `.gitkeep` are placeholders, never
fragments, and are ignored by every reader here.

Reference: [`docs/features/changelog-fragments.md`](../docs/features/changelog-fragments.md).
