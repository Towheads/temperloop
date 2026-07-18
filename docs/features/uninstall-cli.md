---
title: uninstall-cli
slug: uninstall-cli
---

## Problem

Once a `temperloop install` writes machine-level state (settings, config,
symlinks under `$HOME`), a newcomer who wants to back out needs a way to
undo exactly what was written — and only what was written. Without a
recorded, reversible undo, "uninstall" degrades into either a manual
`rm -rf` guess (risking a preexisting file the CLI happened to replace) or
a namespace grep (risking an unrelated file that merely looks like it
belongs to temperloop). Two other undo surfaces already exist and are
deliberately **not** this one: `bin/bootstrap.sh`'s own footprint
(`~/.local/bin/temperloop`, the `foundation` compat shim,
`~/.local/share/temperloop`) predates any manifest — nothing recorded it —
and `temperloop eject` undoes a *target repo's* `.temperloop/config` side
effects (labels, required checks, boards), a wholly different manifest for
a wholly different class of side effect. This item is the third, missing
piece: reversing the *machine-surface* manifest a `temperloop install`
records.

## How it works

`bin/subcommands/uninstall.sh` (`temperloop uninstall`) reads **only**
`workflows/scripts/install/manifest.sh`'s machine-surface manifest
(`${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/install-manifest.json`)
— never a namespace grep, never an inferred path. It loads the manifest via
`manifest_load` (which refuses legibly, naming the schema version found, on
an unreadable or future-schema manifest — no partial deletion is ever
attempted against a manifest this build couldn't parse), lists every
recorded path, and for each one calls `manifest_restore_from_record`: a
`state=created` entry has its path removed; a `state=preexisting` entry has
its path restored from the exact backup recorded at install time, and the
backup file removed. A path with no manifest entry — a hand-edited
`$XDG_CONFIG_HOME/temperloop/` conf file, an unrelated decoy sitting next
to a managed path — is invisible to every step and is never touched.

Consent mirrors `eject.sh`'s existing pattern: `--yes` pre-confirms,
otherwise an interactive TTY gets a `y/N` prompt, and a non-interactive run
with neither aborts with nothing touched (the same "nothing lands without
explicit consent" default used for the also-mutating direction). `--dry-run`
prints the plan and performs zero writes — the manifest and every recorded
path are left byte-identical. A partial failure (e.g. a `preexisting`
entry whose backup file went missing) is left recorded by
`manifest_restore_from_record`'s own contract, so a re-run retries only the
unresolved subset; `uninstall.sh` needs no extra bookkeeping of its own for
that convergence, and exits 1 to signal the incomplete run.

`temperloop uninstall` explicitly does **not** remove the bootstrap
footprint (`~/.local/bin/temperloop`, the `foundation` compat shim,
`~/.local/share/temperloop`) — that footprint predates any manifest, so
this manifest has no record of it and cannot know it's safe to remove.
This is a deliberate stance, not a gap: inferring "this looks like a
temperloop path, remove it too" would be exactly the namespace-grep
behavior the manifest's own read discipline forbids. Instead,
`uninstall.sh` prints a `print_bootstrap_footprint_bullet()` guidance
block naming the manual `rm` commands on every run (success or no-op) so
the gap is never silent.

## Integration

Three separate removal scopes now exist, and neither doc nor code
conflates them — `bin/README.md`'s Uninstall section and `eject.sh`'s own
`print_uninstall_bullet()` both state the same table:

- **(a) Bootstrap footprint** — manual `rm`, documented but not automated
  (see "How it works" above for why).
- **(b) This subcommand** — the machine-surface install manifest a
  `temperloop install` (a sibling item in this epic, not yet landed as of
  this item) records.
- **(c) `temperloop eject`** — a target repo's `.temperloop/config`
  side effects. A wholly separate manifest (repo-tree-scoped, sole-writer
  `init.sh`/reader `eject.sh`) from the machine-scoped manifest this item
  reverses — see `manifest.sh`'s own header for why the two are never
  merged or cross-read.

`temperloop uninstall` is dispatched exactly like every other subcommand —
a discovered file at `bin/subcommands/uninstall.sh`, no dispatcher edit
required (`bin/temperloop`'s DISPATCH MODEL). Per-subcommand prereq scoping
(temperloop#412) means the dispatcher checks a subcommand only against what
its own `# prereqs: ...` header declares (see `bin/lib/common.sh`:
`foundation_check_prereqs`); this subcommand declares none, matching that it
never calls `claude` or `gh` itself, so `temperloop uninstall` runs with
zero dispatcher-level claude/gh checks in front of it.

## Resource impact

None. Pure local filesystem I/O (`jq`, `cp`/`rm` via `manifest.sh`) against
a per-machine XDG state directory — no network calls, no GitHub API usage,
no CI resource growth beyond the one new test suite
(`bin/subcommands/tests/test_uninstall.sh`), auto-discovered by the
existing `make test-try` glob loop (`bin/subcommands/tests/test_*.sh`) with
no Makefile edit needed.

## Telemetry

None. A CLI subcommand with no runtime call sites beyond an operator's own
invocation — there is nothing for a dashboard to observe. (Its sibling
`temperloop init`/`try` already print an operator-facing summary of their
own actions; this subcommand follows the same convention via its own
status lines, but nothing here feeds `meta/data/raw/`.)
