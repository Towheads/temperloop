# foundation CLI

`foundation` is the **newcomer/adoption surface** for this kernel — a single
POSIX entrypoint for someone who has never touched this project's Makefile,
board, or build pipeline. If you already have a checkout, in-checkout
operations (the board toolkit, the build/sweep pipeline, the quality gates)
stay on `make` — this CLI does not duplicate a Makefile target.

## Install

**Inspect first (recommended)** — read the installer before you run it:

```sh
curl -fsSL https://raw.githubusercontent.com/Towheads/foundation-kernel/main/bin/bootstrap.sh -o foundation-bootstrap.sh
less foundation-bootstrap.sh          # read it — see exactly what it does
sh foundation-bootstrap.sh
```

**One-line**, once you trust the source:

```sh
curl -fsSL https://raw.githubusercontent.com/Towheads/foundation-kernel/main/bin/bootstrap.sh | sh
```

The installer does exactly three things, nothing else: shallow-clones
`foundation-kernel` into `~/.local/share/foundation-kernel` (or
fast-forward-updates it in place on re-run), symlinks
`~/.local/bin/foundation` to the entrypoint inside that checkout, and prints
a `PATH` reminder if `~/.local/bin` isn't on it already. No shell-rc edits,
no `sudo`.

**Uninstall**: remove `~/.local/bin/foundation` and
`~/.local/share/foundation-kernel` — the bootstrap's entire footprint. (A
`foundation eject` subcommand, once installed, additionally documents
removal of anything the CLI itself wrote to a *target* repo you pointed it
at — a separate concern from uninstalling the CLI tool itself.)

## Prerequisites

`foundation` shells out to two tools it doesn't vendor, and checks both
before doing anything:

- [Claude Code](https://docs.claude.com/en/docs/claude-code/quickstart) (`claude` on `PATH`) — drives the actual work.
- [GitHub CLI](https://cli.github.com) (`gh`), authenticated (`gh auth login`) — every subcommand that talks to GitHub needs it.

If either is missing, `foundation` prints exactly what's missing and how to
fix it — never a bare stack trace.

## Usage

```
foundation help              list installed subcommands
foundation <subcommand> ...  run one
foundation --version         print the CLI version
```

## Subcommand reference

Subcommands are **discovered files** — anything dropped at
`bin/subcommands/<name>.sh` becomes `foundation <name>` automatically, with
no dispatcher edit required. This item ships the dispatcher only; the table
below fills in as later items (`foundation try`, `foundation init`,
`foundation eject`, ...) land their own subcommand file.
