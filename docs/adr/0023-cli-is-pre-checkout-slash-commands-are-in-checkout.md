---
title: "0023: the CLI owns pre-checkout state changes; slash commands own in-checkout judgment"
---

## Status

Proposed

## Context

epic: Towheads/temperloop#1117

The toolkit presents two command surfaces to an operator. `bin/temperloop` is a
POSIX shell entrypoint whose subcommands are *discovered* — a file's presence at
`bin/subcommands/<name>.sh` with a `# description:` line is its registration.
Slash commands are prose specifications under `claude/commands/*.md` that a model
executes inside a Claude Code session.

Which surface a new capability belongs on has been decided case by case, and the
reasoning has not been written down. That is affordable while the two surfaces
have obviously different jobs, and stops being affordable the moment a capability
could plausibly sit on either — as happened when the on-ramp rebuild needed a way
to move work from an evaluation duplicate back to an operator's real repository.
That capability is shell-shaped in its mechanics (git remotes, fetches, branch
pushes) and model-shaped in its judgment (deciding which work is worth moving,
and which copied issue corresponds to which original).

Deciding such cases by argument each time produces a surface split a stranger
cannot predict, which is the real cost: a newcomer who cannot guess where a
capability lives has to search for it, and the CLI's value is that it is the one
thing they can reach before understanding anything else.

`bin/temperloop`'s own header already states the intended boundary — the CLI is
"the surface a STRANGER meets before they have a working checkout … NOT a second
front door onto an existing checkout's day-to-day work." That sentence has been
governing by accident. This ADR promotes it to a rule.

## Decision

**A capability belongs on the CLI if and only if it changes state a stranger
needs before they have a working checkout. Everything that operates inside an
established checkout, or that requires judgment rather than mechanism, is a slash
command.**

Two consequences fall out directly:

- **Pre-checkout, mechanical → shell subcommand.** Creating an evaluation
  duplicate, bootstrapping configuration, installing or removing the machine
  surface, ejecting. These run before there is a session to run a slash command
  in, and their correctness is checkable by a test rather than by reading output.
- **In-checkout, judgment-bearing → slash command.** Decomposing an epic,
  executing a plan, deciding which of an evaluation's results are worth
  promoting. These presuppose an adopted repository and produce results whose
  quality is a matter of judgment, not exit codes.

The rule is stated as a biconditional deliberately. A capability that is
pre-checkout but judgment-bearing, or in-checkout but purely mechanical, is a
signal the capability is drawn at the wrong seam and should be split, not a
licence to place it by taste.

## Consequences

**A stranger can predict the split.** "Shell before you have a checkout, slash
commands after" is one sentence, and it is the same sentence whether they are
looking for an existing capability or proposing a new one. This is worth more
than the marginal convenience of putting any individual capability on the surface
that happened to be easier to build it on.

**Some capabilities become two things.** A capability with a mechanical half and
a judgment half is now expected to split at that seam rather than picking a
surface for the whole. This costs an interface between the halves, and buys a
mechanical half that can be tested structurally instead of being entangled with
judgment that cannot be.

**The CLI stops absorbing scope.** The failure this prevents is gradual: each
individually reasonable addition of an in-checkout capability to the CLI makes it
marginally less true that the CLI is the newcomer surface, until it is a general
tool and a newcomer no longer knows where to start. The rule gives that drift a
name and a place to be refused.

**It does not settle where a capability's *documentation* lives**, only its
implementation surface. A slash command that a newcomer will eventually need may
still be named in the CLI's handoff output; naming a next step is not the same as
hosting it.
