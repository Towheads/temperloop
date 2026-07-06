# Versioning

Canonical versioning policy for temperloop (the kernel). This is the single
source of truth for **when** a release bumps major/minor/patch and **what**
each bump signals — to a stranger vendoring the kernel, and to the machinery
that consumes it (`update-kernel`, `kernel-drift-check`, the Pages
version-switcher). The `CHANGELOG.md` preamble and
`workflows/scripts/kernel/kernel-repo-layout.md` § Release-tag convention
defer here rather than restate the rule.

## The core idea: version by contract surface, not by code

The kernel is **vendored, not installed** — an adopter pulls it as a `git
subtree` at a tag (`make update-kernel KERNEL_TAG=vX.Y.Z`), not as a package
dependency. So the thing a version has to describe is not a function
signature; it is the **contract surface an overlay couples to**. A change is
"breaking" exactly when a downstream overlay or a stranger's config must
change to keep working — nothing else.

### The contract surface

These are the seams an adopter depends on. A change to any of them is a
contract-surface change (minor-or-breaking, never a patch):

| Surface | What couples to it | Where it lives |
|---|---|---|
| **Board adapter interface** | overlay scripts calling `board_resolve_item` / `board_resolve` / `board_item_list` / `board_set_*`, the `--board N` axis, board commands (`claim`/`release`/`worklist`/`reconcile`/`capture`/`milestone`) | `workflows/scripts/board/lib/board.sh`, `boards.conf` |
| **Pipeline command contracts** | operators running the slash commands; their documented steps + `plan-schema.md` shape | `claude/commands/*.md`, `claude/plan-schema.md` |
| **Hook names + signatures** | a machine's installed hooks; anything keying off their I/O contract | `claude/hooks/*.sh` |
| **Quality-gate contract** | CI + local gate parity: the required job name `checks`, the `KERNEL_GATES` set, the Live/Drain + PR-body-lint registry formats | `scripts/quality-gates.sh`, `.github/workflows/ci.yml` |
| **CLI surface** | callers of `bin/foundation` and its subcommands (`init`, `eject`, `try`, `report`, `baseline-snapshot`) | `bin/foundation`, `bin/subcommands/*` |
| **Compose / pin seam** | the overlay's `install-claude` compose (`CLAUDE.kernel.md` + overlay), `.kernel-pin` format, the kernel-manifest classification | `workflows/scripts/install-claude-md.sh`, `.kernel-pin`, `kernel-manifest.txt` |
| **Published schemas/contracts** | anything a stranger reads to conform: `plan-schema.md`, `report.contract.md`, `knowledge_store.contract.md`, `lexicon.tsv` columns | various `*.contract.md`, `*-schema.md` |

Renaming/removing a board function, changing a hook's I/O, renaming the
`checks` job, changing `.kernel-pin`'s format, or dropping a documented
command step are **breaking**. Adding a new board command, a new hook, a new
optional `plan-schema` field, or a new gate that no existing overlay is
required to satisfy is **additive**. Fixing a bug with none of the above is a
**patch**.

## Bump rules

### Pre-1.0 (where we are today)

Strict SemVer reserves the breaking signal for a major bump — unavailable at
`0.x`, where the standard reading is "anything may break, always." That reading
gives a stranger **no** signal, which defeats the point of a version. So
pre-1.0 the kernel keeps `v0.MINOR.PATCH` **but carries the breaking signal in
the CHANGELOG entry**, not in the version number:

| Bump | Trigger | Stranger signal | CHANGELOG marking |
|---|---|---|---|
| **patch** `0.x.Y+1` | fix only; contract surface untouched | safe pull, no action | plain `### Fixed` |
| **minor, additive** `0.X+1.0` | contract surface **grows**; nothing existing changes | safe pull, new capability available | plain `### Added` / `### Changed` |
| **minor, breaking** `0.X+1.0` | contract surface **changes/shrinks**; an overlay must adapt | **touch your overlay/config before pulling** | section header tagged **`BREAKING`** + a `### Changed`/`### Removed` entry that names the migration |

The one rule that makes this work: **a breaking release MUST mark its
CHANGELOG section `BREAKING` and MUST include a migration note.** That marker
is the machine-readable breaking signal for the pre-1.0 world — it is what
`update-kernel` reads (below), and what a stranger greps for before pulling.
The version number alone stays ambiguous at `0.x`; the CHANGELOG resolves it.

### Post-1.0

Standard SemVer, no house rule: **major** = breaking (overlay must adapt),
**minor** = additive, **patch** = fix. The `BREAKING` CHANGELOG marker stays as
a courtesy but the major bump becomes the primary signal.

## Signal to the machinery

The version/CHANGELOG delta is an **actionable** signal, not a bare label:

- **`update-kernel`** — after fetching the target tag, it scans the CHANGELOG
  range `current-pin-tag..target-tag` for a `BREAKING` marker (pre-1.0) or a
  major-version increment (post-1.0). On a breaking delta it **refuses the
  unattended path** and requires an explicit acknowledgment
  (`KERNEL_ALLOW_BREAKING=1` or an interactive confirm), printing the
  migration notes from the marked sections. An additive/patch delta pulls
  without prompting. *(This behavior is the routed follow-up — see below;
  today `update-kernel` pulls any named tag blind to the delta.)*
- **`kernel-drift-check`** — unchanged. It is a byte-identity check (subtree
  tree-hash vs `.kernel-pin`), orthogonal to semver; it answers "is `kernel/`
  the pinned tag?", not "how big is the jump?"
- **Pages version-switcher** (Epic C) — keys off the tag list; no change
  needed, but benefits from the tags now carrying a defined meaning.

## The 1.0 criterion

We **adopt the semantics now** (bump rules + the `BREAKING` marker + the
`update-kernel` gate) but **defer the literal `1.0.0` tag** — the contract
surface is still moving (v0.4→v0.6 in days). The trigger to cut `1.0.0`:

> **three consecutive minor releases with zero `BREAKING` markers**, or an
> explicit operator decision that the contract surface is stable enough to
> promise compatibility.

Until then, a stranger reads `0.x` as "stable semantics, surface still
settling — read the CHANGELOG `BREAKING` markers before you pull," which is a
real, usable signal rather than SemVer's blanket pre-1.0 disclaimer.

## Summary for a stranger

- Tags are `vX.Y.Z`, annotated, on the commit that produced them.
- Pre-1.0: **read the CHANGELOG.** A `BREAKING`-marked section means touch your
  overlay first. No marker means safe to pull.
- `update-kernel` will stop you before an unacknowledged breaking pull.
- 1.0 arrives when the surface has held still for three minor releases.
