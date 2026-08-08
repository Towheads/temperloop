---
title: testbed
slug: testbed
---

## Problem

Evaluating temperloop means pointing it at a repo — and the repo worth
evaluating it on is the one you actually care about, which is exactly the
repo you do not want an unfamiliar tool creating branches, issues, and pull
requests in. `temperloop testbed` (temperloop#1117) closes that gap in one
command: it builds a **private, disposable evaluation copy** of a repo —
create it, mirror-push history into it, carry the open issues across — and
hands off to `temperloop init` inside the copy, so the whole rest of the
ladder runs against a throwaway. Later items in the same epic tear it down
or promote work back out of it.

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

Two pieces: the command an operator runs, and the machine-scoped record it
writes as it goes. The command is thin wiring over two landed seams — the
record library below, and the source-provider seam
(`workflows/scripts/testbed/source.sh`) — and is their only call site.

### The command — `temperloop testbed`

```sh
temperloop testbed --dry-run   # preview: zero writes of any kind
temperloop testbed             # for real, once you like the preview
```

`bin/subcommands/testbed.sh` is **registered by existing right there**:
`bin/temperloop`'s dispatch model discovers any `bin/subcommands/<name>.sh`
as `temperloop <name>` the moment the file exists, and reads its
`# description:` header line for `temperloop help` and for this site's
subcommand-reference table. There is no dispatch table to edit, and the
dispatcher contains no reference to `testbed` at all.

The driver is **fixed and provider-agnostic** — the same order every run,
for every source provider:

```
describe
  -> union of preflight_checks (all reads)
    -> consent
      -> create the testbed repository -> FLUSH
        -> produce_git                  -> FLUSH
          -> produce_issues             -> FLUSH
            -> handoff
```

Four properties carry that shape:

- **No `case` on provider kind.** The kind is only ever a string passed
  through to the four seam functions below; the per-provider branch the seam
  exists to eliminate appears nowhere in the driver, so the second provider
  (`materialize-from-seed`) lands without touching this file. An unknown
  kind is refused by the seam's own guard, naming the provider and the
  missing operation.
- **Pre-flight is a union, and it is all reads.** The driver's own checks
  (`gh` present and authenticated; a resolvable destination owner; a
  collision-free destination name, uniquified against what already exists —
  collision-safe naming is the driver's job, never a provider's) are unioned,
  deduped by function name, with whatever `preflight_checks()` yields for
  this provider. Every one is a read (`command -v`, `gh auth status`,
  `gh api user`, `gh repo view`, `git rev-parse`), so a refusal exits having
  created nothing anywhere. A driver check fails with
  `cannot proceed — <fix>`; a provider check fails with `skipped — <fix>`.
  Either way the line names the fix, and the run stops on the first failure
  rather than stacking a second, confusing error on the real one.
- **Consent is a hard gate.** `try --demo` established the guard — refuse on
  a non-tty stdin with no `--yes`, so a curious stranger cannot silently
  burn spend. This command carries it to a materially bigger blast radius (a
  real private repository, a full history mirror, your open issues), so
  silence is never consent: on a non-tty stdin with no `--yes` it refuses
  outright.
- **`--dry-run` is zero writes, structurally.** It runs describe and
  pre-flight, prints exactly what a real run would create, prints the same
  handoff block, and exits — never reaching the consent gate (there is
  nothing to consent to when nothing is created), never issuing a mutating
  `gh` or `git` call, never touching the record file. The test suite proves
  that with a fake `gh` **and** a fake `git` on PATH logging every call, plus
  a before/after file-tree diff of both the source checkout and the XDG state
  dir — not by asserting intent.

Each **FLUSH** is a `record.sh` call made the instant that step actually
completed — never batched, never anticipated. The test suite snapshots the
record file *at* the mirror push and *at* the issue copy to prove it: when
`produce_git` runs the record already carries `repo_created` and only that;
when `produce_issues` runs it carries `mirror_pushed` and not yet
`issues_copied`. A record written once at the end would pass a final-state
assertion and fail both of those.

The run ends in an unmissable final block that prints the testbed URL in
full, the literal `git clone` / `cd` / `temperloop init` commands to
copy-paste, and a stable `next step:` marker line. Nothing is printed after
it.

### Teardown — `temperloop testbed --teardown`

```sh
temperloop testbed --teardown --dry-run   # preview: zero writes
temperloop testbed --teardown             # for real
```

Teardown is a **mode on the same command**, not a second subcommand — it
branches early, before any of the create-path driver's toplevel resolution,
describe, pre-flight union, consent, or four seam calls, so it can never
perturb that fixed sequence. The target resolves from `--repo OWNER/NAME`
if given, else from `--dir`'s (default: cwd) `origin` remote — read with
`git -C`, never a `cd` — so it works from **any cwd**, including inside the
testbed's own clone, by keying straight into the machine-scoped artifact
record rather than any tree-relative path.

Every recorded entry has `artifacts.repo_created=true` by construction
(`testbed_record_add`'s own contract), so a single `gh repo delete` removes
whatever the record enumerates for that entry — the mirrored history and
any copied issues both live inside the repository being deleted — whether
or not `mirror_pushed`/`issues_copied` ever flushed true. A partial-failure
run tears down exactly like a complete one.

`gh auth login`'s default scope set does not include `delete_repo`, so
teardown checks for it first (`workflows/scripts/testbed/scope.sh`'s
`testbed_teardown_has_delete_repo_scope`, a reusable helper rather than a
check re-typed at each call site) and, when it is absent, degrades
**legibly**: prints the one-line `gh auth refresh -s delete_repo` remedy
and exits 0, leaving the record entry untouched for a re-run — never a
failed `gh repo delete` call it could never have made. When the scope is
present, teardown carries the same consent gate as creation (refuses a
non-tty stdin with no `--yes`) and the same `--dry-run` zero-write proof.

### The record — `workflows/scripts/testbed/record.sh`

`workflows/scripts/testbed/record.sh` is a sourceable bash library that
reads and writes a JSON record under
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

`bin/subcommands/testbed.sh` is the **first and only call site of both Level
0 seams**, and it adds no parallel logic of its own — the bar
`bin/subcommands/init.sh` sets for its own three seams. It sources
`record.sh` and `source.sh`, calls `testbed_record_add` the moment it creates
the testbed repository and `testbed_record_mark_step` after each further
step, and reaches the provider only through
`testbed_source_describe` / `testbed_source_preflight_checks` /
`testbed_source_produce_git` / `testbed_source_produce_issues`. It never
names a provider's own functions, never re-implements the record format, and
never re-derives the provenance line — `produce_issues` stamps
`copied from <owner>/<repo>#<N>` itself, inside the provider, so a provider
with no upstream issue to cite simply never emits one.

Downstream, `temperloop testbed --teardown` reads the record to find what to
delete and calls `testbed_record_remove` once `gh repo delete` succeeds.
`/promote`'s
`promote-spec-and-tree-push` step (a later,
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

The **record library** is pure local filesystem I/O (`jq`, `mktemp`, `mv`,
`mkdir`) against a per-machine XDG state directory — no network calls, no
GitHub API usage.

The **command** is the part that costs something, and only on a real run.
Per invocation: a handful of read-shaped GitHub API calls during pre-flight
(`gh auth status`, `gh api user`, one `gh repo view` per candidate name), one
repository creation, one `git push --mirror` carrying the source repo's full
history, and one issue creation per open issue carried across. `--dry-run`
costs the pre-flight reads and nothing else. No LLM call is made at any point
— unlike `try` and `try --demo`, this command spends no model budget. The
testbed repository itself is private and disposable; `--teardown` reclaims
it with one read (`gh auth status`, the delete_repo scope check) plus, when
that scope is present, one `gh repo delete`.

CI growth is two test suites in `scripts/quality-gates.sh`'s `KERNEL_GATES`
(`make test-testbed-record`, `make test-testbed-command`), both hermetic and
zero-network, each with its own `gate-paths.tsv` row so a scoped run selects
only what a diff can actually affect. `workflows/scripts/testbed/scope.sh`'s
own tests ship alongside it under `workflows/scripts/testbed/tests/` and are
picked up automatically by `make test-testbed-source`'s glob — no new gate
or `gate-paths.tsv` row needed for it.

## Telemetry

None yet. The command's progress is legible on stdout as it runs (a numbered
step per driver stage, and one `→ <repo> (<id>) <step> recorded` line per
flush), and the record file itself is the durable, machine-readable trace —
`testbed_record_flat` enumerates every artifact this machine has created,
including a run killed partway. No counter, event, or dashboard field is
emitted anywhere; a testbed is an evaluation-time artifact an operator runs
deliberately, not a background process anyone needs to watch.
