---
title: testbed
slug: testbed
---

## Problem

`temperloop testbed` (temperloop#1117, not yet built — this item ships its
foundation) will build a private, disposable evaluation copy of a repo in
one command: create it, mirror-push history into it, carry a bounded number
of open issues across, and later tear it down or promote work out of it.
That workflow spans several mutating steps against GitHub (repo creation,
mirror push, issue copy) that can fail or be interrupted partway through,
and two separate later consumers — teardown and `/promote` — need to find
what a given run actually produced without re-deriving or guessing it: an
enumerable, removable record of every artifact created, plus the
source-provenance facts (which provider created it, from what source, and
whether it can ever be promoted) that promotion reads two levels downstream
of creation. Without that record, a killed-partway run leaves an orphaned
private repository nobody can find to delete, and promotion has no reliable
way to refuse against a testbed that was never meant to be promoted.

## How it works

`workflows/scripts/testbed/record.sh` is a sourceable bash library (no CLI
yet — `temperloop testbed`, its teardown leg, and `/promote` are later items
in the same epic) that reads and writes a JSON record under
`${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/testbed-record.json`:

```json
{
  "schema_version": 1,
  "testbeds": {
    "me/my-eval-testbed": [
      {
        "id": "20260808T120000Z-4821-1a2b",
        "created_at": "2026-08-08T12:00:00Z",
        "testbed_repo": "me/my-eval-testbed",
        "source_kind": "mirror-from-repo",
        "source_repo": "me/my-real-repo",
        "promotable": true,
        "artifacts": {
          "repo_created": true,
          "mirror_pushed": true,
          "issues_copied": true
        }
      }
    ]
  }
}
```

The record is keyed by the **created testbed's own** `owner/name` — not the
source's — exactly as `git remote get-url origin` resolves inside that
testbed checkout, so a later consumer running inside the testbed (teardown,
`/promote`) can find its own entry with zero filesystem scan: read its own
origin, key straight in. Each key's value is a **list**, never a single
slot, so a second `temperloop testbed` run from the same original checkout
never orphans an already-recorded entry's teardown reference.

Three public entry points carry the append-only, per-step-flush contract:

- `testbed_record_add <owner/name> <source_kind> <source_repo-or-empty>
  <promotable>` — called the instant the testbed repository itself exists.
  Appends a new list entry with `artifacts.repo_created` already `true`
  (creating the record IS the repo-created step — there is never a moment
  where an entry exists with no artifact yet true), records the
  source-provenance fields (`source_kind` is `mirror-from-repo` or
  `materialize-from-seed`; `source_repo` is `null` for the seed provider,
  which owns no repository at any point; `promotable` is `false` for the
  seed provider since there is no original to promote to), flushes
  atomically, and prints the new entry's id.
- `testbed_record_mark_step <owner/name> <id> <step>` — called immediately
  after each further mutating step actually completes (`mirror_pushed`,
  then `issues_copied`), flipping exactly that one boolean and flushing
  atomically. A run killed between steps leaves an entry whose `artifacts`
  map shows precisely how far it got.
- `testbed_record_remove <owner/name> <id>` — teardown's call once it has
  actually deleted the corresponding GitHub repository: removes that one
  list entry, dropping the key entirely once its list is empty.

Read helpers (`testbed_record_list`, `testbed_record_get`,
`testbed_record_all`, `testbed_record_flat`) never infer or namespace-match
— a key or id with no entry is reported absent, exactly like
`manifest_get_path_entry`'s discipline. Read-compatibility is explicit:
`testbed_record_load` checks the on-disk `schema_version` against
`TESTBED_RECORD_READABLE_SCHEMA_VERSIONS` (currently just `"1"`) and refuses
legibly — naming the version found and the set it can read — on anything
else, mirroring `workflows/scripts/install/manifest.sh:196-224` exactly.

## Integration

Consumed by the not-yet-built `temperloop testbed` subcommand and its
teardown leg (this epic's next items): the subcommand calls
`testbed_record_add` the moment it creates the testbed repository and
`testbed_record_mark_step` after each further step; teardown reads the
record to find what to delete and calls `testbed_record_remove` once
deletion succeeds. `/promote`'s `promote-spec-and-tree-push` step (a later,
separate item) reads `source_kind` / `source_repo` / `promotable` off the
matching entry to resolve where a promoted branch pushes to and to refuse
promotion against a `materialize-from-seed` testbed.

Deliberately a **separate file and schema** from
`${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/install-manifest.json`
(`workflows/scripts/install/manifest.sh`, feature `install-manifest-lib`):
that manifest is a backup/restore record of install's own filesystem side
effects under `$HOME`; this record is an append-only creation/teardown log
of artifacts a testbed run creates outside this machine entirely (a GitHub
repository, a mirror push, copied issues). The two are never merged or
cross-read. Also deliberately **not** `.temperloop/testbed.json`
(repo-tree-scoped): `bin/subcommands/eject.sh` deletes the whole
`.temperloop/` directory on a clean exit, and the CI round trip that
exercises this path runs `eject` between a testbed's creation and its
teardown — a repo-tree-scoped record would be destroyed by eject before
teardown ever read it. Machine-scoped XDG state is the only location
eject's blast radius does not reach.

## Resource impact

None. Pure local filesystem I/O (`jq`, `mktemp`, `mv`, `mkdir`) against a
per-machine XDG state directory — no network calls, no GitHub API usage, no
CI resource growth beyond the one new test suite (`make test-testbed-record`)
this item adds to `scripts/quality-gates.sh`'s `KERNEL_GATES`.

## Telemetry

None. A library with no CLI surface and no runtime call sites yet — there
is nothing for an operator or a dashboard to observe until the
`temperloop testbed` subcommand and teardown (later items in this epic)
actually invoke it.
