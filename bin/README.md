# TemperLoop CLI

`temperloop` is the **newcomer/adoption surface** for this kernel — a single
POSIX entrypoint for someone who has never touched this project's Makefile,
board, or build pipeline. If you already have a checkout, in-checkout
operations (the board toolkit, the build/sweep pipeline, the quality gates)
stay on `make` — this CLI does not duplicate a Makefile target.

(The CLI was named `foundation` before foundation #893's rename to the
project's ratified public name, TemperLoop. `foundation <sub>` still works
through the rename window — `kernel/bin/foundation` is a thin compat shim
that prints a one-line deprecation notice and execs `temperloop` — and is
**removed in v0.19.0** along with the other legacy `foundation` names; see
the v0.15.0 CHANGELOG `BREAKING` entry for the full migration note.)

## Prerequisites

`temperloop` shells out to two tools it doesn't vendor, and checks both
before doing anything:

- [Claude Code](https://docs.claude.com/en/docs/claude-code/quickstart) (`claude` on `PATH`) — drives the actual work.
- [GitHub CLI](https://cli.github.com) (`gh`), authenticated (`gh auth login`) — every subcommand that talks to GitHub needs it.

If either is missing, `temperloop` prints exactly what's missing and how to
fix it — never a bare stack trace.

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

The installer does exactly three things, nothing else, and the details
differ between a fresh install and a re-run (ADR 0002, "Managed-clone state
ownership"):

- **Fresh install**: clones `temperloop` into `~/.local/share/temperloop`
  with enough history for tags to resolve, then **lands the clone on the
  latest release tag** (highest `vX.Y.Z` by version sort) — you get a
  released version, never `main`'s unreleased tip. If the remote genuinely
  has no release tags yet, it stays on the default branch with an explicit
  warning printed to stderr.
- **Re-run** (an install already exists): the bootstrap script never pulls
  or fast-forwards the existing clone in place — it **delegates to
  `temperloop update`**, which surfaces the CHANGELOG delta (including any
  `BREAKING` sections) and asks for consent before moving anything. An
  install that predates the `update` subcommand fails with a stated
  recovery (reinstall fresh, or move the clone to a tag by hand) rather than
  a silent pull or a dead end.

Either way it also symlinks `~/.local/bin/temperloop` (and the `foundation`
compat shim alongside it) to the entrypoints inside that checkout, and
prints a `PATH` reminder if `~/.local/bin` isn't on it already. No shell-rc
edits, no `sudo`.

Uninstalling is layered across **four separate scopes** — most people only
ever need `temperloop uninstall` (the machine-surface install) or
`temperloop eject` (undoing `init` in a target repo); see § Uninstall below
for the full breakdown and the other two.

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
demo repo and drives ONE real safe-tier pipeline tick (issue → PR) against it:
claims one open demo-seed issue, gets a real (but still `--tools ""`,
zero-tool-access) `claude -p` judgment call for the fix, and opens a PR via
the tree-only proposal-PR generator — **never a direct push, never a
merge**. A spend guard prints a directional cost estimate and a hard
mechanical cap (`--demo-cap-usd`, default \$2.00, ≈370,000 tokens at Claude
Sonnet 5 list price — see `docs/cost-and-autonomy.md` for the conversion
basis) before anything runs, and refuses outright on a non-interactive
shell with no `--yes` — a curious stranger cannot silently burn spend. If
every seeded issue is already claimed or closed, it exits 0 with "no tick
run" rather than failing.

### 3. `temperloop init` — opt in, on your own repo

```sh
temperloop init --dry-run   # preview first: tree-only, zero API writes
temperloop init              # for real, once you like the preview
```

Bootstraps `.temperloop/config` in your repo and proposes any tree changes
(e.g. a `boards.conf` entry) via a reviewable PR — nothing ever lands
without review. Then it offers you the kernel-shipped **first epic** ("Set
up `<project>` with temperloop"), prints a `next step:` handoff line, and
stops. `--dry-run` previews the tree-only PR with zero API calls of any
kind.

**The handoff needs step 4 below.** `/assess` and `/build` are Claude Code
slash commands, and they reach your machine only through `temperloop
install`, which symlinks them into `~/.claude/`. Steps 1 and 2 genuinely
need no machine-wide setup; **step 3's handoff does** — so if you have not
run `temperloop install` yet, run it before acting on the `next step:` line.
`init` itself detects this and prints a `prerequisite:` line when the
command isn't installed, so you won't be left pointing at something that
doesn't exist.

`init` applies **no API state itself**. Branch protection, head-branch
auto-delete, the merge-queue disposition, the required `checks` status
check, CI, and your review principles are that first epic's work, applied
later with per-write consent by driving it through the real pipeline
(`/assess --epic N` → `/build`) — and note that what the epic applies is
**not** undone by `temperloop eject` (§ Uninstall scope (e), below).

The flags that used to gate `init`'s own applies still parse and still exit
0; each now prints one line naming where its step went, plus the release it
is removed in, and is then ignored. Nothing that passes them breaks. Where
each one went:

| Flag | Where its step went | Removed in |
|---|---|---|
| `--yes/--no-required-check` | the first epic — which, unlike `init`, refuses to require a `checks` status no workflow will post | v0.20.0 (the pre-scope-down compat window) |
| `--yes/--no-labels` | nowhere — **retired as redundant**. The `fnd:`/pipeline labels are created lazily at point of use by the issues-only tracker backend, so there was never anything to pre-create | v0.20.0 (same) |
| `--yes/--no-board` | nowhere — board provisioning was dropped outright | v0.20.0 (same) |
| `--provision-board` | dropped outright; provision a Projects-v2 board by hand instead | the ADR-0004 Projects-arm removal release |
| `--tracker-mode projects` | coerced to `issues`, the sole tracker mode `init` writes | the ADR-0004 Projects-arm removal release |

For the by-hand Projects-v2 board, see § "Manual Projects-v2 recipe" in [the
install-cli feature doc](../docs/features/install-cli.md).

`foundation <subcommand>` runs the identical dispatch as `temperloop
<subcommand>` throughout this ladder (the compat shim — see above).

### Verify: `temperloop install` + `doctor.sh`

Steps 1 and 2 above work against a target repo and need no machine-wide
setup. Step 3 is the exception worth calling out: `init` itself needs none
either, but the `/assess --epic N` → `/build` handoff it ends on is Claude
Code slash commands that only exist once you have run the install below —
so treat this step as part of the adoption path, not an optional extra.
`temperloop install` wires up the **machine surface** —
the machine-wide `~/.claude/CLAUDE.md` / `settings.json`, the `gh`
call-logger shim (§ Details below), and the other managed paths — and every
run ends by printing the exact command to check what actually landed:

```sh
temperloop install            # --dry-run to preview, --yes to skip the prompt
# ⇒ ends with: Verify with: bash <clone>/workflows/scripts/install/doctor.sh
```

Run that printed command any time to re-check link state on its own — `OK`
per managed path, or `MISSING` / `DRIFT` / `SHADOWED` / `DANGLING` when
something's drifted. There is no `temperloop doctor` subcommand; `doctor.sh`
is invoked directly, at the path `temperloop install` prints for you. See
`docs/features/install-cli.md` for exactly what it checks.

### `temperloop feedback` vs. `temperloop report` — sending vs. rendering

These two subcommands are easy to conflate by name association, so the
split is stated explicitly here: `temperloop report` never leaves your
machine — it only renders your own local `.temperloop/baseline.jsonl`
before/after metrics to your terminal. `temperloop feedback` is the
opposite: it **sends** a message to the kernel maintainers, as a GitHub
issue on `Towheads/temperloop`. Nothing is ever sent without you seeing the
exact composed payload first, it always gets scanned for personal/org
tokens before you see it, and it refuses outright in any non-interactive or
CI context — a timeout or a flag is never consent for an external write.
See `bin/subcommands/feedback.sh`'s own header comment for the full
compose → leak-scan → preview → consent → transmit contract.

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

## Details

Background you don't need for the quickstart above, but will if you're
uninstalling, auditing what `gh` calls get logged, or running this CLI
across more than one client/engagement.

### Uninstall — five separate scopes, don't conflate them

| Scope | What it undoes | How |
|---|---|---|
| (a) **Bootstrap footprint** | `~/.local/bin/temperloop`, `~/.local/bin/foundation` (the compat shim), `~/.local/share/temperloop` — the bootstrap's entire footprint, written *before* any manifest existed | manual: `rm -f ~/.local/bin/temperloop ~/.local/bin/foundation && rm -rf ~/.local/share/temperloop` |
| (b) **Machine-surface install manifest** | settings/config/symlinks a `temperloop install` wrote under `$HOME`, recorded in `${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/install-manifest.json` | `temperloop uninstall` |
| (c) **Target-repo side effects** | the proposal PR `temperloop init` produced in a repo you pointed it at — plus the label, required check, and board a **pre-scope-down** `init` recorded before it stopped applying API state — as recorded in that repo's `.temperloop/config` (pre-v0.15.0 inits wrote `.foundation/config` — read through the rename window, removed in v0.19.0) | `temperloop eject` (run inside the target repo; cleans either dir) |
| (d) **Issue-cache store root** | `${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop}` — created by `temperloop install`, grown by ongoing board cache reads/refreshes; deliberately **not** tracked by the manifest (it's regenerable cache, not install state, so "restore its original content" is the wrong verb for it) | manual, optional: `rm -rf "${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop}"` |
| (e) **First-epic substrate** | default-branch protection, head-branch auto-delete, the merge-queue disposition, any scaffolded CI workflow, and the recorded `§ Principles` disposition — applied by the **first epic** via `/assess --epic N` → `/build`, never by `init`, so none of it is in scope (c)'s manifest and **`temperloop eject` does not revert it** | manual: repo **Settings → Branches** (and delete the generated workflow file); step-by-step in [`docs/features/engineering-principles.md` § Uninstall / removal](../docs/features/engineering-principles.md) |

Scope (e) is the one to read twice, because it is the only scope with no
command behind it. Since the `init` scope-down, `init` itself writes no API
state — everything that actually configures your repo is applied later, by
the first epic, through ordinary consented PRs. That state is **your repo's
own settings and content** from the moment it lands, exactly like any other
change your PRs make, which is why no kernel manifest tracks it and why
reverting those PRs does not undo it either: a protected branch stays
protected and an armed queue stays armed until you turn them off. Each write
is disclosed with its undo path at the moment you consent to it (see
`claude/templates/first-epic-setup.md` § A2/A3), so this is a documented
trade rather than a surprise — but a clean `temperloop eject` genuinely does
not mean "back to how you found it."

Scope (a) predates any manifest, so `temperloop uninstall` cannot know about
it or remove it — this is a deliberate stance, not a gap: inferring "this
looks like a temperloop path, remove it too" would be exactly the
namespace-grep behavior the manifest's own read discipline forbids (see
`workflows/scripts/install/manifest.sh`'s header). `temperloop uninstall`
prints the scope-(a) manual-removal bullet as guidance every time it runs,
so it's never a dead end — just never automatic. It prints the same kind of
guidance for scope (d) (the cache store root) and a reminder to run
`temperloop eject` for scope (c) in any target repo you ran `init` against.

`temperloop uninstall` reads **only** its manifest: it removes every path it
created and restores every preexisting path it backed up from that exact
backup, and never touches a path absent from the manifest — a hand-edited
machine conf under `$XDG_CONFIG_HOME/temperloop/`, for instance, always
survives. `--dry-run` previews with zero writes; `--yes` pre-confirms
(otherwise an interactive `y/N` prompt, or a non-interactive default-deny
that touches nothing).

### The `gh` call-logger shim (disclosure)

`temperloop install` (scope (b) above) unconditionally installs
`workflows/scripts/gh-call-logger.sh` as `~/.local/bin/gh` — a transparent
wrapper around **every** `gh` invocation on the machine (and, installed
under the same mechanism as `git-bug`, every `git-bug` call too). This is
part of the machine-surface install manifest, so it shows up in
`temperloop uninstall`'s removal list like any other managed path; it is not
a hidden side effect.

**What it does.** It runs the real `gh`/`git-bug` binary as a child process,
times the call, and appends one record of the call (start time, duration,
exit code, the outermost command/op that made it if set, cwd, and the
arguments) to two local, append-only sinks — never sending anything over the
network itself. It never blocks, alters, or fails a call: logging is
best-effort, and a logging failure can never change the wrapped tool's exit
code.

**Where it logs.**

- A self-truncating TSV at `${GH_CALL_LOG_FILE:-$HOME/.cache/gh-calls-v2.tsv}`
  (rotates to `<file>.1` past a 16&nbsp;MiB cap).
- A monthly JSONL lake file at
  `${GH_CALLS_RAW_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/gh-calls}/gh-calls-<YYYY-MM>.jsonl`.
  The default is XDG-scoped and never assumes a particular downstream repo
  checkout exists on disk; a real `foundation` checkout that wants this
  stream unioned into its own `meta/data/raw/` sets `GH_CALLS_RAW_DIR`
  explicitly (see `meta/data/raw/README.md` for the record shape).

**How to opt out.** Set `GH_CALL_LOG=0` (per-call or exported machine-wide)
for a zero-overhead passthrough — the real tool still runs, but no timing,
no log row, no lake record. To remove the shim entirely, run `temperloop
uninstall` (or `rm -f ~/.local/bin/gh`, restoring your shell's own `gh`
resolution from `PATH`).

### Running across multiple repos or clients

Working across more than one GitHub identity (e.g. a personal account plus a
client's org)? `gh` resolves whichever identity is currently active —
`gh auth switch` swaps it before you run a `temperloop` subcommand against a
different repo/org, same as it would for a bare `gh` call.

`temperloop install` (scope (b) of the Uninstall table above) is a **single
global, per-machine** install — the machine-wide `~/.claude/CLAUDE.md`,
`settings.json`, and the rest are shared by every repo you point this CLI
at, not duplicated per repo. What *is* per-repo is `.temperloop/config`
(pre-v0.15.0: `.foundation/config`, read through the rename window),
written inside the target repo's own working tree by `temperloop init` (and
reverted by `temperloop eject`, scope (c)) — board wiring and proposal PRs
live there, scoped to that one repo, never in the global install. A repo
initialised before the `init` scope-down may also carry recorded labels and
required checks in that manifest; those entries are carried forward
untouched on every re-run and `eject` still reverts them, even though `init`
no longer creates any.

If you want an isolated instance per engagement instead of the one shared
global install — the case for, say, a consultant running this across
several unrelated client codebases — `bin/bootstrap.sh` honors two
environment-variable overrides read *before* it clones anything:
`TEMPERLOOP_HOME` (default `~/.local/share/temperloop`, where the checkout
lives) and `TEMPERLOOP_BIN_DIR` (default `~/.local/bin`, where the
`temperloop`/`foundation` entrypoints get symlinked). Set both to a
client-specific path before running the bootstrap script to keep each
engagement's install fully separate. (The pre-rename `FOUNDATION_HOME` /
`FOUNDATION_BIN_DIR` / `FOUNDATION_KERNEL_REPO` names are still read as
fallbacks through the rename window — with a one-line deprecation notice —
and are removed in v0.19.0.)
