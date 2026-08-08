---
title: changelog-fragments
slug: changelog-fragments
---

## Problem

`VERSIONING.md` requires a `## [Unreleased]` entry for every contract-surface
change, and `workflows/scripts/check-changelog-entry.sh` enforces it at PR
time. That gate works — and it made `CHANGELOG.md` the repo's single worst
merge hotspot: **25 of the last 25** commits touched it. Two concurrent PRs
both inserting a bullet at the same anchor in the same file conflict
*structurally*, every time, and each conflict costs a rebase or a merge-queue
ejection. The `/build` pipeline runs a whole dependency level at once and
`/sweep` drives chunks of concurrent singletons, so "two concurrent PRs" is the
normal case, not an edge one.

Two remedies were evaluated and rejected before this one (recorded in
`Decisions/temperloop - changelog fragment direction (keystone spike verdict)`):

- **A `merge=union` driver on `CHANGELOG.md`.** It resolves the everyday case,
  but on the release-cut race — a cut PR moving the `[Unreleased]` body into a
  new `## [x.y.z]` while a sibling inserts at the same anchor — the default
  driver conflicts loudly and union auto-merges *clean*, landing the sibling's
  entry inside the shipped release section. Nothing catches it: `git
  merge-tree` honours the attribute, so the merge-gate's hunk-overlap probe
  reclassifies the pair as disjoint. `.gitattributes`' own header already
  excludes this class — union is scoped to files whose only mutation is an
  append, and a release cut is a *move*.
- **Relaxing the gate to release time.** Self-refuting from the gate's own
  header: an absent entry cannot carry a `BREAKING` marker, which is the state
  that motivated the gate (at the v0.22.0 cut, 1 of 14 merged PRs had touched
  `CHANGELOG.md`).

## How it works

Each PR writes its own new file under **`changelog.d/`** instead of editing
`CHANGELOG.md`. Two PRs writing two distinct new files share no line and cannot
conflict — the collision becomes structurally impossible rather than merely
unlikely. At the release cut, `scripts/assemble-changelog.sh` folds the
accumulated fragments back into `## [Unreleased]` and deletes them.

**The filename is the index:**

```
changelog.d/<slug>.<category>[.breaking].md
```

`<category>` is one of Keep a Changelog's six (`added`, `changed`,
`deprecated`, `removed`, `fixed`, `security`); `<slug>` is kebab-case with no
dots, conventionally `<issue#>-<branch-slug>`; the optional `.breaking` marker
drives the ` — BREAKING` heading suffix. Assembly order is total and derives
from filenames alone: canonical category order, then `LC_ALL=C` by filename.

**The format is index-free by ratified constraint, not by taste.** There is no
ordering file and no manifest inside `changelog.d/` — a shared index would
recreate the identical single-file hotspot one directory over, which would make
the whole exercise a no-op. For the same reason every registry line that
mentions the directory is a **directory glob**, never a per-fragment entry:
fragments are deleted at each cut, so per-file lines would turn those
registries into shrink-only ratchets — exactly the class `.gitattributes`
excludes from `merge=union`, because union's keep-both semantics resurrect a
deleted line.

**The assembler is additive, never replacing.** It merges into whatever
`## [Unreleased]` already holds: existing sub-sections keep their order and
their content, a fragment appends to the end of its category's section, and a
category with no section yet is *inserted* at its canonical position. This is
load-bearing rather than polish — `main`'s Unreleased section is routinely
substantial, and an assembler that assumed it was empty would silently drop
everything accumulated since the last tag. It also makes an in-flight PR
written against the old flow (a direct `[Unreleased]` line, no fragment)
harmless rather than lost.

**It fails loudly rather than dropping an entry.** An unrecognised filename, an
empty fragment, a body carrying its own `#`/`##`/`###` heading (which could
forge a `BREAKING` signal, since `changelog_breaking_sections()` reads headings
only), or a missing `## [Unreleased]` heading each abort the run with a named
cause and **write nothing**.

Parsing lives in `workflows/scripts/lib/changelog.sh`, beside the range helpers
it must stay consistent with. That placement is forced by ADR-0002's layering
rule, stated in that file's own header: `check-changelog-entry.sh` lives under
`workflows/scripts/` and already sources the lib, and a parser under `scripts/`
sourced from `workflows/scripts/` is the forbidden direction. The executable
assembler sits in `scripts/` and sources the lib in the sanctioned direction,
beside `update-kernel.sh` — a release cut runs inside an established checkout
by a maintainer, so per ADR-0023 it is not `bin/temperloop` surface, and it is
mechanical rather than judgment-bearing, so it is not a slash command either.

```sh
scripts/assemble-changelog.sh --check     # validate every fragment, write nothing
scripts/assemble-changelog.sh --dry-run   # print the resulting CHANGELOG.md
scripts/assemble-changelog.sh             # rewrite CHANGELOG.md, delete the fragments
```

## Integration

- **`workflows/scripts/lib/changelog.sh`** gains the fragment vocabulary
  (`changelog_fragment_parse`, `_names`, `_body`, `_invalid`, `_empty`,
  `_body_offenders`, `_has_breaking`) and `changelog_assemble_unreleased_body`.
  Its four pre-existing helpers are unchanged.
- **`scripts/assemble-changelog.sh`** is the release-cut executable. It has no
  environment seams — every tunable is a flag — so it adds no row to
  `workflows/scripts/config/setting-registry.tsv`.
- **`scripts/quality-gates.sh`** runs `scripts/tests/test_assemble_changelog.sh`
  as a `KERNEL_GATES` entry, so the additive property is part of the required
  `checks` status.
- **`workflows/scripts/config/gate-paths.tsv`** recognises `changelog.d/**` on
  the `none` row. Without it, every PR carrying a fragment would escalate its
  scoped run to the full gate set — a cost regression, not a correctness one,
  since `gate-selection.sh` defaults to *full* on an unmapped path. An `ALWAYS`
  row cannot serve here: ALWAYS rows are deliberately non-recognising.
- **`workflows/scripts/kernel/kernel-manifest.txt`** and
  **`docs/features/feature-manifest.txt`** each claim the directory with one
  glob; **`workflows/scripts/kernel/terminology-leak-exempt-files.txt`**
  exempts it as `record`, the twin of `CHANGELOG.md`'s own entry.
- **`workflows/scripts/check-changelog-entry.sh` is deliberately UNCHANGED.**
  This change is additive: nothing yet *requires* a fragment, and a direct
  `## [Unreleased]` entry still satisfies the gate. temperloop#1322 cuts the
  gate over to fragments, rewrites `VERSIONING.md` § Cutting a release, and
  ships the legible-degradation arm for a consumer tree that has no
  `changelog.d/` yet — a **BREAKING** release, because a vendoring overlay must
  create the directory to keep the completeness property it has today.

## Resource impact

Negligible. Fragment parsing is a directory listing plus a filename parse per
file; assembly is one two-file `awk` pass over a body of a few dozen lines, run
once per release cut by a human. No network, no GitHub API, no git operations.
The new gate is a fast fixture suite (sub-second) in the already-required
`checks` job.

CI wall-clock moves the *right* way on balance: the `gate-paths.tsv` recogniser
keeps fragment-only diffs scoped instead of escalating them to the full
~110-gate set, which is what an unmapped new top-level directory would have
done to nearly every PR.

## Telemetry

None dedicated. The health of this feature is asserted mechanically rather than
observed at runtime: `test_assemble_changelog.sh` proves the byte-identity and
additive properties against the repo's own `CHANGELOG.md` on every `checks`
run, and `test_changelog.sh` covers the parser. The merge-conflict rate this
exists to drive to zero is visible in the existing `/build` and `/sweep`
rebase-respawn counters, not in a counter of its own.
