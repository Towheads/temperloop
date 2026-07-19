---
title: Slash-command availability probe
slug: command-declared
---

## Problem

The kernel already had a capability-probe predicate — but only for
subagents (`Decisions/foundation - Project capability probes`: a review gate
trusts a named subagent iff the project declares it in `CLAUDE.md § Subagents`
or `.claude/agents/`). No equivalent existed for **slash commands**. So a
kernel surface that needed to ask "is `/retro` installed here?" before
citing it had to improvise its own file check — and the naive check resolves
**falsely** on a composed install: overlay commands like `/retro` live at
`~/.claude/commands/` after `make install-claude`, not under the kernel
checkout's own `claude/commands/`, so a probe that only looks at the checkout
sees a command that is really available as absent. ADR 0008 closes that gap
with one shared helper every command-availability caller cites instead of
re-inventing the check.

## How it works

`command_declared <name>` is a sourced shell helper (not an executable) that
returns true (rc 0) the moment slash command `<name>` is found on any of the
three surfaces a headless `claude -p` invocation's supporting tooling reads
or writes, checked **in order**:

1. `$PWD/.claude/commands/<name>.md` — a project-local command.
2. `<checkout>/claude/commands/<name>.md` — the kernel's source of truth,
   where `<checkout>` is resolved from the lib's own location via
   `git rev-parse --show-toplevel`, never `$PWD` (which may be a different
   repo or a subdirectory).
3. `$HOME/.claude/commands/<name>.md` — the composed-install deployment
   target (`make install-claude`'s output).

It returns false (rc 1) when none carries a `<name>.md`. A
`COMMAND_DECLARED_OVERRIDE` env var, when set (including set-but-empty),
short-circuits the filesystem probe entirely and answers from its
space-separated command-name list — letting a fixture force both a
deterministic true and a deterministic false for the same name.

The semantics are **"source-or-installed present", not
"runtime-resolvable"**: surface 2 is the compose *input* `make
install-claude` reads from, not a path `claude -p` resolves slash commands
from at runtime. So on an **uninstalled** checkout the predicate can read
true for a kernel-source command that a real `claude -p` cannot yet invoke —
a latent false-positive, by design (checking "installed" would require
shelling out to inspect a live harness rather than answering from static file
state). This is **inert for every current caller**: they all probe the
overlay-only `/retro`, which has no file under the kernel checkout, so
surface 2 never fires for them. A future caller that probes a *kernel-source*
command name would be the first to observe it, and should treat a
surface-2-only true as "declared in source, not necessarily installed."

## Integration

Cited by the `/retro`-gating surfaces of the unified-retrospection epic
(temperloop#528): the retrospection mint's state-label choice
(`claude/commands/build.md`'s 4d-retro step), the funnel retro-judge trigger,
and `/check-in`'s retro gating. Each sources this lib and calls
`command_declared retro` rather than improvising a file check. It is a
**distinct** predicate from the subagent capability-probe
(`Decisions/foundation - Project capability probes`): that probe asks whether
a *capability is declared* for a project; this one asks whether a *command
file exists* across three mixed source-and-runtime surfaces. The two must not
be conflated or used to answer each other's question. Depends on `git` for
surface-2 resolution only, and degrades gracefully (skips surface 2) when git
is absent or the lib is not inside a git checkout.

## Resource impact

A few filesystem `stat`/`-f` checks per call (at most one per surface, and it
short-circuits on the first hit), plus a single `git rev-parse
--show-toplevel` when surface 2 is reached. No network, no API budget, and no
process spawn beyond that one `git` invocation. Cost is constant per call and
does not scale with corpus, board, or command-set size.

## Telemetry

None. The helper emits no telemetry record — it is a pure predicate that
returns a shell exit code and writes nothing to the raw lake. Its callers'
own gating decisions are observed through their own surfaces, not this one.
