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

**Uninstall**: remove `~/.local/bin/temperloop`, `~/.local/bin/foundation`,
and `~/.local/share/temperloop` — the bootstrap's entire footprint. (A
`temperloop eject` subcommand, once installed, additionally documents
removal of anything the CLI itself wrote to a *target* repo you pointed it
at — a separate concern from uninstalling the CLI tool itself.)

## Prerequisites

`temperloop` shells out to two tools it doesn't vendor, and checks both
before doing anything:

- [Claude Code](https://docs.claude.com/en/docs/claude-code/quickstart) (`claude` on `PATH`) — drives the actual work.
- [GitHub CLI](https://cli.github.com) (`gh`), authenticated (`gh auth login`) — every subcommand that talks to GitHub needs it.

If either is missing, `temperloop` prints exactly what's missing and how to
fix it — never a bare stack trace.

## Usage

```
temperloop help              list installed subcommands
temperloop <subcommand> ...  run one
temperloop --version         print the CLI version
```

## Subcommand reference

Subcommands are **discovered files** — anything dropped at
`bin/subcommands/<name>.sh` becomes `temperloop <name>` automatically, with
no dispatcher edit required. This item ships the dispatcher only; the table
below fills in as later items (`foundation try`, `foundation init`,
`foundation eject`, ...) land their own subcommand file.
