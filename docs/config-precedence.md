# Config precedence — the six-rung ladder

temperloop#164/#169. Every tunable knob in this repo's pipeline machinery
(build/sweep, the funnel driver, the board adapter) resolves through the
**same** six-rung precedence ladder, highest to lowest:

| Rung | Source | Scope | Lives at |
| --- | --- | --- | --- |
| 1 | **CLI flag** | one invocation | a script's own `--flag value` parsing |
| 2 | **env var** | one process / shell | whatever exported it (a shell profile, `.env`, an inline `VAR=… cmd`) |
| 3 | **machine conf** | one host, every checkout on it | `$XDG_CONFIG_HOME/temperloop/` |
| 4 | **untracked repo-local conf** | one checkout | a gitignored sibling file next to the tracked config |
| 5 | **tracked repo conf** | one repo, as committed | the config file itself, checked into git |
| 6 | **kernel built-in default** | any non-vendoring caller | a matching fallback hardcoded directly in an individual script |

A higher rung always wins. Rung **N** overriding rung **N+1** is the whole
point of having N+1 rungs instead of one — a CLI flag beats an env var beats
a machine-wide override beats a checkout-local override beats what's
committed beats the absolute last-resort default a standalone script falls
back to when it can't find any config file at all.

## Why this shape, and how it's implemented

Rungs 3–6 are all files (or, for rung 6, hardcoded fallback lines) read by
`source`, using the idiom:

```sh
: "${VAR:=default}"
```

`:=` assigns `default` to `VAR` **only if `VAR` is currently unset** — a
pre-existing value (from rung 2's env export, or from a higher rung sourced
earlier in the same run) is left untouched. This has a useful consequence:
**source order becomes precedence order.** If every conf-bearing file uses
`:=` (never a plain `VAR=value` assignment) and the loader sources them
highest-rung-first, the ladder falls out for free — no special-casing, no
"which value wins" logic anywhere. The one rule that makes it work: **every
rung's file must use `:=`, with no exceptions.** A single plain assignment
anywhere in the chain breaks the property for every rung below it, because a
plain assignment always wins regardless of source order (it doesn't check
whether the var is already set).

`workflows/scripts/build/build.config.sh` is the reference implementation
for rungs 3–6 in this repo:

1. It sources an optional **machine conf** at
   `$XDG_CONFIG_HOME/temperloop/build.config.sh` (default
   `~/.config/temperloop/build.config.sh`; overridable via
   `BUILD_CONFIG_MACHINE`) — rung 3. Template:
   `workflows/scripts/build/build.config.machine.sh.example`.
2. It then sources an optional **untracked repo-local conf** at
   `build.config.local.sh`, a gitignored sibling (overridable via
   `BUILD_CONFIG_LOCAL`) — rung 4. Template:
   `workflows/scripts/build/build.config.local.sh.example`.
3. It then applies its own `:=` defaults, the **tracked repo conf** — rung
   5, since this file is checked into git and IS the committed default set a
   consuming repo can vendor and edit.
4. A handful of individual spine scripts (e.g. `funnel-tick.sh`,
   `funnel-drive.sh`) additionally keep a matching `:=` fallback for the same
   variable, hardcoded directly in the script rather than read from this
   file — that is the **kernel built-in default**, rung 6, the value a
   non-vendoring caller sees if it invokes the script standalone without
   ever sourcing `build.config.sh` at all.

Rungs 1 and 2 (CLI flag, env var) aren't implemented by this file at all —
they're just "whatever was already true before this file got a chance to
run": an env var is already set in the process environment before `source`
executes, and a CLI flag is parsed by the calling script either before or
after sourcing, and simply assigns the var directly (which — same as rung
2 — makes every `:=` below it a no-op).

**Before this ladder existed**, `build.config.sh` sourced
`build.config.local.sh` *last*, using **plain assignments** in the local
file. That inverted the intended precedence: a value set in
`build.config.local.sh` could beat an exported environment variable, because
a plain assignment always wins regardless of when it runs. Fixing this
required two changes together — reordering `build.config.sh` to source
rungs 3 and 4 *before* applying its own rung-5 defaults, and converting
`build.config.local.sh` (and its `.example` template) to the `:=` idiom —
neither change alone would have restored the ladder.

## `boards.conf` is an instance of this ladder's order — not a new rung

`workflows/scripts/board/lib/board.sh`'s `boards.conf` discovery (foundation
#770) predates this ladder but already follows the same **order**: it checks
a machine-level location first, then a repo-local override, then falls back
to a built-in case map. That is rungs 3 → 4 → 6 of this same ladder, applied
to a different kind of config (board registry rows, not shell-sourced
tunables) — `boards.conf`'s **row format** (`board.<N>.<axis>=value`,
parsed with `grep`/`cut`, never sourced or eval'd) is a deliberately
different mechanism from the `:=`-sourced files above, and is **out of
scope for this document** to change. The point being documented here is
narrower: `boards.conf`'s discovery order is the same *shape* of precedence
as the ladder above, so a reader who understands one understands the other,
even though the two don't share an implementation.

`boards.conf`'s machine-level path is
**`$XDG_CONFIG_HOME/temperloop/boards.conf`** — the same `temperloop`
namespace as rung 3 above. `boards.conf` was built (foundation #770) before
this repo's public rename from `foundation` to `temperloop` and was
grandfathered under `$XDG_CONFIG_HOME/foundation/` until temperloop#165
migrated it (v0.15.0, read-old-write-new): when no file exists at the
`temperloop/` path, an **existing** legacy
`$XDG_CONFIG_HOME/foundation/boards.conf` is still read as a fallback
through the migration window, and that legacy fallback is **removed in
v0.17.0** — move the file (`mkdir -p ~/.config/temperloop && mv
~/.config/foundation/boards.conf ~/.config/temperloop/`) or set
`BOARDS_CONF_MACHINE`. Any **new** machine-conf surface added after this
ladder — including rung 3 above — uses the `temperloop` namespace from the
start; `foundation` never appears in a new one.

## Operator controls (ADR §2.3a kind 3) — not a rung either

A **control** is a third kind of config surface, alongside the six-rung
ladder above and `boards.conf`'s own row format — governed by ADR §2.3a
rather than by this ladder's rung order, because it answers a different
question. The ladder (rungs 1–6) picks **which source wins** when several
places could set the same knob; a control is instead the **one** knob whose
file content an operator flips **live, without a commit or a redeploy**, to
change autonomous-pipeline behavior at runtime. `FUNNEL_SCHEDULE_FILE`
(`workflows/scripts/build/funnel-schedule-gate.sh`,
`workflows/scripts/build/funnel-overlap.sh`) is the kernel's one control
today: the *path knob* is an ordinary rung-6 kernel default like any other
row in `knob-registry.tsv`, but the *file it points at* is a control — its
content, not its path, is what the operator edits to change behavior.

A control's contract has four load-bearing properties, all required
together:

- **Vault-resident.** The file lives in the operator's knowledge store (the
  `ks_root` seam, `workflows/scripts/lib/knowledge_store.sh`) — never in the
  repo tree. A control is content an operator maintains in their own
  notes app, not a file a developer edits alongside source.
- **Operator-flipped.** Changing behavior is a plain edit to the file's
  content (e.g. toggling `enabled: yes` → `no` in a fenced block) — no
  script invocation, no flag, no restart. The control's *reader* (a gate
  script) re-resolves the file fresh on every invocation.
- **Commit-free.** The file is never tracked in git. It has no PR, no
  review, no CI run of its own — editing it is instant and carries none of
  the repo's change-control ceremony, which is the point: an operator
  dialing autonomous spend up or down needs a lever faster than a branch
  and a merge queue.
- **Fail-closed, overriding code defaults at runtime.** A control's reader
  must treat "missing", "unreadable", and "malformed" identically to an
  explicit off — never fall back to a permissive code default. This is what
  makes a control safe to be commit-free: a sync hiccup, a typo, or a
  deleted note degrades a spend-gated control toward *less* autonomous
  action, never more (`funnel-schedule-gate.sh`'s own header documents this
  as the fail-closed/fail-open split with `funnel-overlap.sh`'s advisory
  predicate). "Overriding code defaults at runtime" means the control's
  *content* — not just its path — takes precedence over whatever a script
  would otherwise do in the control's absence; the path knob's rung-6
  fallback only decides *where to look*, never *what to do* if the control
  can't be read.

### The registry-reachability rule

Every file under `Controls/` in the knowledge store MUST be pointed at by a
`path`-typed row in `knob-registry.tsv` — i.e. a control is only real config
surface if some registered knob's default resolves to it. A file dropped
into `Controls/` with no registry row pointing at it is orphaned: no reader
is contractually promised to look for it, and the registry (the map of
every tunable this repo's pipeline machinery reads) is silently incomplete.
This is the control-specific corollary of the registry's own inclusion
rule (`knob-registry.tsv`'s header) — every operator-overridable seam gets a
row — applied to the *content* layer rather than the *path* layer: the path
knob is registered because it's an ordinary rung-6 default, and the
registry-reachability rule is what additionally guarantees the file that
path resolves to, by default, is one some script actually reads.

### The overlay move window: two paths, one control

`FUNNEL_SCHEDULE_FILE`'s default resolution is deliberately a two-path
probe, not a single path: it checks `Controls/foundation - funnel
schedule.md` under `ks_root` first, falling back to the legacy `Context/
foundation - funnel schedule.md` when `Controls/` doesn't have it. This
exists because kernel items land before the corresponding vault-side folder
move (temperloop#226's decomposition: "the overlay vault moves … are
external to this epic — kernel items must not assume the new folders
(`Controls/`, …) exist yet"). The fallback keeps the SAME control readable,
and the gate fail-closed either way, across the whole window between "the
kernel knows about `Controls/`" and "the operator's note has actually moved
there" — an explicit `FUNNEL_SCHEDULE_FILE` override (any higher rung) skips
the probe entirely and is used verbatim, exactly like every other rung-1/2
override in the ladder above.

## See also

- `workflows/scripts/build/build.config.sh` — the reference implementation
  (rungs 3–6) for the build/sweep/funnel tunables.
- `workflows/scripts/board/lib/board.sh` § boards.conf registry seam — the
  board-registry instance of this ladder's order.
- `workflows/scripts/board/boards.conf.example` — the `boards.conf` row
  format (unaffected by this document).
- `workflows/scripts/build/funnel-schedule-gate.sh` and
  `workflows/scripts/build/funnel-overlap.sh` — the kernel's one operator
  control (`FUNNEL_SCHEDULE_FILE`) and its Controls/-then-Context/ default
  resolution.
- `workflows/scripts/config/knob-registry.tsv` — the registry-reachability
  rule's enforcement point: every `Controls/`-resolving path knob is a row
  here.
