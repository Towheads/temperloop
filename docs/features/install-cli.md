---
title: TemperLoop CLI install ladder
slug: install-cli
---

## Problem

Without a CLI entrypoint, a stranger evaluating this kernel would have to
hand-clone the repo, wire up symlinks, and run raw scripts before seeing any
real behavior — with no natural on-ramp from "look, read-only" to "opt my own
repo in." That is a large trust ask to make of someone still deciding
whether the tool is worth adopting, and a partial or wrong-flag install can
leave a repo half-configured with no easy way to check what actually landed.

## How it works

**Install.** A short bootstrap script (`bin/bootstrap.sh`, fetched over
`curl` or inspected first) shallow-clones this repo into
`~/.local/share/temperloop` (fast-forwarding it in place on re-run) and
symlinks `~/.local/bin/temperloop` — plus a `foundation` compat shim, since
the CLI was named `foundation` before its rename — to the entrypoints inside
that checkout. No shell-rc edits, no `sudo`. Uninstalling means removing
those three paths; that is the installer's entire footprint.

**Update.** `temperloop update` (ADR 0002 "Managed-clone state ownership") is
the sole sanctioned way to move that managed clone's `HEAD` forward once it
exists. It fetches release tags (auto-converting a tagless `--depth 1` clone
via `git fetch --unshallow` on first run), prints the full CHANGELOG delta
for the jump — any `BREAKING`-marked section called out — BEFORE asking for
consent (an explicit `--yes`, an interactive `y/N`, or a legible refusal on a
non-interactive run; there is no timeout-as-consent), checks the on-disk
install manifest's schema against the target tag's own `manifest.sh` before
touching `HEAD` at all, then checks out the tag and re-runs `install` +
`doctor`. It takes no `--dir`/`--repo` argument — its entire write surface is
the managed clone's own git state plus the machine surface `install.sh`
already owns, never a repo-tracked path in any other repo.

**The adoption ladder: `try` -> `try --demo` -> `init`.** Each step does
strictly more than the last:

1. `temperloop try` is zero-config and zero-writes. It runs a read-only
   conventions probe, lists the current repo's open issues with a
   directional cost estimate printed before anything else happens, then
   drives a real `claude -p` shadow-triage classification pass over those
   issues — invoked with `--tools ""` (every built-in tool disabled), a
   *structural* zero-write guarantee independent of the model's own
   behavior. No `gh` mutation is ever issued. A missing `gh`/network/auth
   degrades to a legible `skipped — <reason>` line per step rather than a
   hard failure, and the command exits 0 either way.
2. `temperloop try --demo` is the one deliberate, isolated mutating
   exception. It clones a disposable, already-seeded demo repo and drives
   one real safe-tier funnel tick (issue -> PR) against it: claims one open
   demo-seed issue, gets a real (still `--tools ""`) judgment call for the
   fix, and opens a PR via the tree-only proposal-PR generator — never a
   direct push, never a merge. If every seeded issue is already claimed or
   closed, it exits 0 with "no tick run" instead of failing.
3. `temperloop init` opts a real repo in. `init --dry-run` previews the
   tree-only proposal PR with zero API writes of any kind. `init` for real
   bootstraps `.foundation/config` and proposes tree changes (e.g. a
   `boards.conf` entry) via a reviewable PR — nothing ever lands without
   review. Only with explicit per-action consent (an interactive `y/N`, or
   an explicit `--yes-<action>` flag — the default is always "no") does it
   additionally apply API-state changes: a required `checks` status check,
   the `fnd:`/funnel label set, and, only on the further opt-in
   `--provision-board`, a new Projects-v2 board.

**The safety contract.** The mutating step in the ladder is exactly one
(`try --demo`), and it is bounded three separate ways: a spend guard prints
a directional cost estimate and a hard mechanical cap (`--demo-cap-usd`,
default `$2.00`) before anything runs; a non-interactive shell with no
`--yes` is refused outright, so a curious stranger cannot silently burn API
spend; and the tick itself touches only the disposable demo repo, never the
caller's own. `init`'s API-state changes carry the same "explicit consent,
default no" shape, and `--dry-run` sidesteps the consented-apply step
entirely.

**`doctor.sh` link states.** Every managed install path
(symlinks under `~/.claude/`, the composed `CLAUDE.md`, the `gh` logger
shim) is classified into one of five states: `OK` (symlink present and
correct, or the managed real file/shim is present), `MISSING` (target does
not exist), `DRIFT` (symlink present but points somewhere else, or a real
file exists where the wrong kind of thing is expected), `SHADOWED` (a real
file/directory sits where a symlink should be), or `DANGLING` (symlink
present but its target does not exist on disk). `bash
workflows/scripts/install/doctor.sh` exits 0 only
when every entry is `OK`, 1 otherwise (`temperloop install` also prints this
exact command at the end of its own run — see § Verify in `bin/README.md`).
It separately reports a
knowledge-store root check (does the agent-plane Obsidian MCP vault agree
with the script-plane `KNOWLEDGE_STORE_ROOT`?) and, when a `boards.conf` is
present, the per-board issue-cache store state — both read-only, both
`SKIPPED`-not-`FAIL` when the underlying pieces simply aren't configured
yet.

**Kernel/overlay compose.** `workflows/scripts/install-claude-md.sh`
composes the installed `~/.claude/CLAUDE.md` from three pieces, in order: a
generated-file banner, the kernel doc (`claude/CLAUDE.kernel.md`, with any
`{{KNOB_NAME}}` placeholder tokens substituted from config), a rendered
"Knowledge store routing" section, and the personal overlay doc
(`claude/CLAUDE.overlay.md`) verbatim. It is idempotent — composing the same
sources twice on the same machine reproduces the target byte-for-byte — and
alongside the composed file it writes a T0 inventory of every
knowledge-store note the composed rules actually reference.

## Integration

Consumes: `gh` (authenticated) and `claude` on `PATH` — both are checked
before any subcommand does anything, and a missing tool prints exactly
what's missing and how to fix it rather than a stack trace. `doctor.sh`
consumes `workflows/scripts/install/links.sh`'s managed-path enumeration and
`workflows/scripts/build/build.config.sh` / `workflows/scripts/lib/
knowledge_store.sh` / `knowledge_store_obsidian.sh` for the vault-agreement
check. `try --demo` consumes the tree-only proposal-PR generator under
`workflows/scripts/proposal/`. `install-claude-md.sh` is invoked by
`temperloop install` (its `claude-md`-kind managed path) and is itself
verified by `doctor.sh`'s `claude-md` classification.

## Resource impact

Storage: a shallow clone into `~/.local/share/temperloop` (typically tens of
MB) plus a handful of negligible symlinks in `~/.local/bin`. API budget:
`try` issues zero `gh` mutations and one bounded `claude -p` call with tools
disabled; `try --demo` is hard-capped at `--demo-cap-usd` (default `$2.00`),
enforced before any spend, and mechanically bounded to a single funnel tick.
Runtime: `doctor.sh` is pure shell and sub-second; `try` and `try --demo`
each drive one `claude -p` invocation, so their wall time tracks that call.

## Telemetry

None dedicated. Each subcommand's own printed output is the observable
surface: `try`'s classification summary, `doctor`'s per-entry
`OK`/`MISSING`/`DRIFT`/`SHADOWED`/`DANGLING` table and its exit code, and
`init --dry-run`'s preview diff. A failure surfaces as a non-zero exit code
plus an explicit `skipped — <reason>` or `FAIL —` line, never a silent
no-op.
