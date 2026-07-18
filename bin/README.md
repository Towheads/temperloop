# TemperLoop CLI

`temperloop` is the **newcomer/adoption surface** for this kernel — a single
POSIX entrypoint for someone who has never touched this project's Makefile,
board, or build pipeline. If you already have a checkout, in-checkout
operations (the board toolkit, the build/sweep pipeline, the quality gates)
stay on `make` — this CLI does not duplicate a Makefile target.

(The CLI was named `foundation` before foundation #893's rename to the
project's ratified public name, TemperLoop. `foundation <sub>` still works —
`kernel/bin/foundation` is a thin compat shim that execs `temperloop`.)

## Install

**Inspect first (recommended)** — read the installer before you run it:

```sh
curl -fsSL https://raw.githubusercontent.com/Towheads/temperloop/main/bin/bootstrap.sh -o temperloop-bootstrap.sh
less temperloop-bootstrap.sh          # read it — see exactly what it does
sh temperloop-bootstrap.sh
```

**One-line**, once you trust the source:

```sh
curl -fsSL https://raw.githubusercontent.com/Towheads/temperloop/main/bin/bootstrap.sh | sh
```

The installer does exactly three things, nothing else: shallow-clones
`temperloop` into `~/.local/share/temperloop` (or fast-forward-updates it in
place on re-run), symlinks `~/.local/bin/temperloop` (and the `foundation`
compat shim alongside it) to the entrypoints inside that checkout, and
prints a `PATH` reminder if `~/.local/bin` isn't on it already. No shell-rc
edits, no `sudo`.

**Uninstall — three separate scopes, don't conflate them:**

| Scope | What it undoes | How |
|---|---|---|
| (a) **Bootstrap footprint** | `~/.local/bin/temperloop`, `~/.local/bin/foundation` (the compat shim), `~/.local/share/temperloop` — the bootstrap's entire footprint, written *before* any manifest existed | manual: `rm -f ~/.local/bin/temperloop ~/.local/bin/foundation && rm -rf ~/.local/share/temperloop` |
| (b) **Machine-surface install manifest** | settings/config/symlinks a `temperloop install` wrote under `$HOME`, recorded in `${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/install-manifest.json` | `temperloop uninstall` |
| (c) **Target-repo side effects** | a label, required check, board, or proposal PR `temperloop init` produced in a repo you pointed it at, recorded in that repo's `.foundation/config` | `temperloop eject` (run inside the target repo) |

Scope (a) predates any manifest, so `temperloop uninstall` cannot know about
it or remove it — this is a deliberate stance, not a gap: inferring "this
looks like a temperloop path, remove it too" would be exactly the
namespace-grep behavior the manifest's own read discipline forbids (see
`workflows/scripts/install/manifest.sh`'s header). `temperloop uninstall`
prints the scope-(a) manual-removal bullet as guidance every time it runs,
so it's never a dead end — just never automatic.

`temperloop uninstall` reads **only** its manifest: it removes every path it
created and restores every preexisting path it backed up from that exact
backup, and never touches a path absent from the manifest — a hand-edited
machine conf under `$XDG_CONFIG_HOME/temperloop/`, for instance, always
survives. `--dry-run` previews with zero writes; `--yes` pre-confirms
(otherwise an interactive `y/N` prompt, or a non-interactive default-deny
that touches nothing).

## Prerequisites

`temperloop` shells out to two tools it doesn't vendor, and checks both
before doing anything:

- [Claude Code](https://docs.claude.com/en/docs/claude-code/quickstart) (`claude` on `PATH`) — drives the actual work.
- [GitHub CLI](https://cli.github.com) (`gh`), authenticated (`gh auth login`) — every subcommand that talks to GitHub needs it.

If either is missing, `temperloop` prints exactly what's missing and how to
fix it — never a bare stack trace.

## Quickstart: try → try --demo → init

Three steps, each strictly more than the last: taste it read-only, watch it
mutate something disposable, then opt your own repo in.

**Before step 1: what this costs, and what it will do on its own.**
[`../docs/cost-and-autonomy.md`](../docs/cost-and-autonomy.md) covers real
spend figures per tier (including whether a budget cap is on by default),
and exactly what an unattended run may do without asking versus what always
blocks for you — worth two minutes before you run anything below.

### 1. `temperloop try` — zero-config, zero writes

```sh
cd your-repo
temperloop try
```

Runs the read-only conventions probe, lists your repo's own open issues with
a directional cost estimate printed *before* anything else happens, then
drives a real `claude -p` shadow-triage classification pass over those
issues — invoked with `--tools ""` (every built-in tool disabled), a
structural guarantee of zero writes independent of the prompt or the model's
behavior. No `gh` mutation is ever issued. Missing `gh`/network/auth degrades
to a legible `skipped — <reason>` line per step, never a hard failure. Exit
0 either way — a graceful skip is not an error.

### 2. `temperloop try --demo` — the one mutating exception

```sh
temperloop try --demo
```

Everything above is read-only; `--demo` is the deliberate, isolated
exception — the "aha moment" tick. It clones a disposable, already-seeded
demo repo and drives ONE real safe-tier funnel tick (issue → PR) against it:
claims one open demo-seed issue, gets a real (but still `--tools ""`,
zero-tool-access) `claude -p` judgment call for the fix, and opens a PR via
the tree-only proposal-PR generator — **never a direct push, never a
merge**. A spend guard prints a directional cost estimate and a hard
mechanical cap (`--demo-cap-usd`, default \$2.00) before anything runs, and
refuses outright on a non-interactive shell with no `--yes` — a curious
stranger cannot silently burn spend. If every seeded issue is already
claimed or closed, it exits 0 with "no tick run" rather than failing.

### 3. `temperloop init` — opt in, on your own repo

```sh
temperloop init --dry-run   # preview first: tree-only, zero API writes
temperloop init              # for real, once you like the preview
```

Bootstraps `.foundation/config` in your repo and proposes any tree changes
(e.g. a `boards.conf` entry) via a reviewable PR — nothing ever lands
without review. Separately, and only with explicit per-action consent (an
interactive `y/N` or an explicit `--yes-<action>` flag; the default is
always "no"), it can apply API-state changes: a required `checks` status
check, the `fnd:`/funnel label set, and — only on the further opt-in
`--provision-board` — a new Projects-v2 board. `--dry-run` skips that
consented-apply step entirely and previews the tree-only PR with zero API
calls of any kind.

`foundation <subcommand>` runs the identical dispatch as `temperloop
<subcommand>` throughout this ladder (the compat shim — see above).

## Usage

```
temperloop help              list installed subcommands
temperloop <subcommand> ...  run one
temperloop --version         print the CLI version
```

## Subcommand reference

Subcommands are **discovered files** — anything dropped at
`bin/subcommands/<name>.sh` becomes `temperloop <name>` automatically, with
no dispatcher edit required. Run `temperloop help` (or, if you're reading
this on the generated docs site, see the live table right below this
paragraph) for the current list — both are built by scanning
`bin/subcommands/*.sh` for each file's `# description: ...` header, so
neither can drift from what's actually installed.
