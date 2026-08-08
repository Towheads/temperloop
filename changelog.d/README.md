# `changelog.d/` — one changelog entry per file

This directory holds **changelog fragments**: one file per changelog entry,
written by the PR that makes the change and folded into `CHANGELOG.md`'s
`## [Unreleased]` section at release-cut time by
[`scripts/assemble-changelog.sh`](../scripts/assemble-changelog.sh).

## Why

Every PR needs a changelog entry, so every PR edited the same file at the same
anchor — and two concurrent ones collided every time. Two PRs writing two
**distinct new files** share no line and cannot conflict. That is the whole
idea. Direction ratified by the keystone spike (temperloop#1311, epic #1299);
the measured motivation is in
[`docs/features/changelog-fragments.md`](../docs/features/changelog-fragments.md).

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
- **A plain file, directly in this directory.** A fragment in a subdirectory,
  or a symlink pointing at nothing, cannot be read and is reported rather than
  skipped — otherwise it would sit here looking pending while the release
  shipped without it.

Leading and trailing blank lines are trimmed; interior blank lines are kept.

## `BREAKING`

Breakingness is declared by the `.breaking` marker in the filename, and the
assembler turns that into `### Changed — BREAKING` plus the
`## [Unreleased] — BREAKING` suffix. The detector reads **heading lines only**,
so writing the word "breaking" in your prose does *not* mark the release — and
neither does omitting it un-mark one.

**What the marker actually does to a downstream repo.** `update-kernel` and
`temperloop update` scan the CHANGELOG range they are about to pull for a
`BREAKING` heading. If they find one they **refuse to pull unattended**: the
person updating has to acknowledge it explicitly — `KERNEL_ALLOW_BREAKING=1`,
or confirming at an interactive prompt — and the marked sections are printed to
them as migration notes first. An unmarked delta pulls without stopping. So
adding `.breaking` deliberately interrupts every overlay that vendors this
kernel; leaving it off when the change *is* breaking lets them pull it
silently. See `VERSIONING.md` § Signal to the machinery.

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

Fragments are deleted only after the rewrite has actually landed. If anything
goes wrong the files stay here, so an entry is never lost from both places at
once.

Then, on the commit about to be tagged:

```sh
scripts/assemble-changelog.sh --assert-empty HEAD
```

That is the cut-time assertion. A sibling PR can add a fragment *after* the cut
PR assembled; the two touch disjoint files so git merges them clean, and the
sibling's entry goes missing from the shipped section with nothing anywhere to
flag it. The leftover file at the tagged commit is the only evidence, so the
cut checks for it. See `VERSIONING.md` § Cutting a release.

## Status

Fragments are **required** (temperloop#1322).
`workflows/scripts/check-changelog-entry.sh` fails a PR that changes contract
surface without adding one, and a direct `## [Unreleased]` line no longer
satisfies it. The escape hatch is unchanged — `Changelog: none — <reason>` as a
PR label, a PR-body line, or a commit trailer.

A tree that has not migrated degrades in one of two directions: a vendoring
consumer (one carrying `.kernel-pin`) with no `changelog.d/` gets an actionable
skip and keeps building green; a checkout with neither the directory nor a pin
is the kernel itself having lost the directory, and the gate fails loudly
rather than silently enforcing nothing.

`README.md` (this file) and dotfiles such as `.gitkeep` are placeholders, never
fragments, and are ignored by every reader here.

Reference: [`docs/features/changelog-fragments.md`](../docs/features/changelog-fragments.md).
