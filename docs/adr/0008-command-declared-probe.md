---
title: 0008: command_declared — a kernel-owned command-availability probe
---

## Status

Proposed

## Context

epic: temperloop#528 · design brief:
`Designs/temperloop - unified retrospection`

The kernel's capability-probe predicate ([[Decisions/foundation - Project
capability probes]]) covers **subagents** only: an agent is available iff
declared in `CLAUDE.md § Subagents` or `.claude/agents/`. No equivalent
exists for slash commands — yet the retrospection design (ADR 0007), and
`/check-in` before it, need to ask "is the `/retro` command installed
here?" A naive checkout-scoped check (`claude/commands/retro.md` exists in
this repo) resolves **falsely on the primary deployment**: a composed
install places overlay commands at `~/.claude/commands/`, not in the
kernel checkout — so the trigger would legibly skip forever on the exact
host it was built for, and fixture tests for probe-gated behavior could
not be written at all without a mechanical predicate.

## Decision

The kernel owns a shared helper, `command_declared <name>`, that answers
command availability by checking the surfaces a headless `claude -p`
invocation actually resolves, in order: the working directory's
`.claude/commands/`, the checkout's `claude/commands/` (the kernel's
source of truth), and `~/.claude/commands/` (the composed-install
deployment target) — with an environment override so fixtures can force
either answer. Kernel surfaces that reference an optional command (the
funnel retro trigger, `/check-in`'s retro sections, the mint's state-label
choice) cite this helper rather than improvising a file check. The
subagent probe decision explicitly does not cover commands; this ADR
closes that gap for them.

## Consequences

Benefits: probe-gated command references become mechanically testable
(the helper has its own unit test and an override for fixtures), the
kernel/overlay boundary for commands is enforced by one shared predicate
instead of per-site improvisation, and the false-negative-on-composed-
install failure mode is designed out. Costs: one more kernel helper to
maintain, and its resolution order becomes a small contract surface —
adding a new command-deployment location later means updating the helper,
not the call sites. Follow-on: existing unconditional command references
in kernel specs (temperloop#521's `/check-in` case) migrate to the helper
as they are touched.
