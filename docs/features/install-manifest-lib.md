---
title: install-manifest-lib
slug: install-manifest-lib
---

## Problem

`temperloop install` (and its future `uninstall` counterpart, ADR K164 D7)
needs a record of what a past install run actually DID to a machine, not
just what it should currently look like. `links_enumerate()`
(`workflows/scripts/install/links.sh`) already answers "what belongs at
each managed path" — desired state, recomputed fresh every run — but it
has no memory: it cannot tell "this path was created by install" from
"this path already existed and install replaced it," and a generated real
file like `settings.json` or the composed `CLAUDE.md` carries no on-disk
ownership marker at all. Without that did-state record, uninstall has no
safe way to know which paths it may remove, and no way to recover what an
install run overwrote — it would have to guess, and a guess that deletes
or restores the wrong file is exactly the kind of destructive mistake an
install/uninstall pair must never make.

## How it works

`workflows/scripts/install/manifest.sh` is a sourceable bash library (no
CLI in this item — that lands in a later `temperloop install`/`uninstall`
subcommand item) that reads and writes a JSON manifest under
`${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/install-manifest.json`:

```json
{
  "schema_version": 1,
  "paths": {
    "/home/x/.zshrc": { "state": "preexisting", "backup_path": "/home/x/.local/state/temperloop/backups/home/x/.zshrc" },
    "/home/x/.local/bin/claim": { "state": "created", "backup_path": null }
  }
}
```

Two public entry points carry the install/uninstall contract:

- `manifest_backup_and_record <path>` — the install-side helper. Called
  immediately before install writes/replaces `<path>`. If `<path>` already
  has a manifest entry, it is a no-op (idempotent re-install convergence —
  no duplicate entry, no second backup that would clobber the ORIGINAL
  preexisting backup with the now-managed file's content). Otherwise: if
  something already exists at `<path>`, it is copied verbatim to an
  explicit backup location under the manifest's `backups/` root and the
  entry records `state=preexisting` + that exact `backup_path`; if nothing
  exists yet, the entry records `state=created` + `backup_path=null`. The
  `backup_path` is always the value RECORDED at write time — a reader
  never re-derives it from the source path, so a future change to the
  backup-naming scheme can never break restoring an older manifest's
  entries.
- `manifest_restore_from_record <path>` — the uninstall-side helper. Looks
  up `<path>`'s entry: `state=created` removes the path and the entry;
  `state=preexisting` copies the recorded backup back over the live path,
  deletes the backup file, and removes the entry; a missing/corrupt backup
  causes a REFUSAL (non-zero return) rather than a destructive guess. A
  path with **no** manifest entry is untouched and unreported as an
  error — it is invisible, exactly like `eject.sh`'s "nothing is inferred
  by namespace grep" discipline for `.foundation/config`.

Read-compatibility is explicit: `manifest_load` checks the on-disk
`schema_version` against `MANIFEST_READABLE_SCHEMA_VERSIONS` (currently
just `"1"`). A recognised version is returned; an unrecognised one — newer
than this build, or missing/malformed — causes `manifest_load` to refuse,
printing the exact version it found and the set it can read, rather than
guessing. This is what lets a later `temperloop` build read a manifest an
older build wrote (D7: "the manifest outlives the code that wrote it").

`manifest_marker_line [<comment-prefix>]` / `manifest_has_marker <file>`
are a secondary, defense-in-depth check: a composer can embed the printed
marker line inside a generated real file (a `settings.json`-shaped file
has no symlink to inspect the way `readlink` inspects a managed symlink),
and a later doctor-style check or a human can recognise "this file is
temperloop-managed" by grepping for the tag — independent of whether the
manifest itself is intact.

## Integration

Consumed by the not-yet-built `temperloop install` / `temperloop
uninstall` subcommands (ADR K164 D7, this epic's remaining items): install
calls `manifest_backup_and_record` for every path it writes; uninstall
calls `manifest_restore_from_record` for every path it wants to undo.
Deliberately a SEPARATE file and format from `.foundation/config`
(`bin/subcommands/init.sh` / `bin/subcommands/eject.sh`) — that manifest is
repo-tree-scoped with a sole-writer contract (init.sh writes, eject.sh
reads) for API-state side effects (labels, required-checks, boards); this
manifest is machine-scoped (XDG state, outside any git tree) for
filesystem side effects (files/symlinks under `$HOME` and
`~/.local/bin`). The two are never merged or cross-read. Also
deliberately separate from `links_enumerate()`
(`workflows/scripts/install/links.sh`), which continues to own DESIRED
state (what should exist) with no change in this item — this manifest owns
DID state (what a past run actually touched, and how to undo it).

## Resource impact

None. Pure local filesystem I/O (`jq`, `cp`, `mv`, `mkdir`) against a
per-machine XDG state directory — no network calls, no GitHub API usage,
no CI resource growth beyond the one new test suite this item adds to
`scripts/quality-gates.sh`'s `KERNEL_GATES`.

## Telemetry

None. A library with no CLI surface and no runtime call sites yet — there
is nothing for an operator or a dashboard to observe until the
`temperloop install`/`uninstall` subcommands (a later item in this epic)
actually invoke it.
