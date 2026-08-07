---
title: "0002: Managed-clone state ownership — bootstrap installs once, update is the sole HEAD mover"
---

# 0002: Managed-clone state ownership — bootstrap installs once, update is the sole HEAD mover

## Status

Proposed

## Context

Two mechanisms mutate the same piece of machine state — the managed clone at
the CLI home (`~/.local/share/temperloop` by default). `bootstrap.sh` today
does a shallow (`--depth 1`) clone of `main` and, on re-run, a
`git pull --ff-only`. The beta upgrade story (epic: temperloop#419)
adds `temperloop update`, which pins the clone to release tags. Left
uncoordinated, the two models are incompatible: a shallow clone doesn't carry
tags, and a bootstrap re-run against a tag-pinned clone fails `--ff-only` on a
detached HEAD — a dead end for exactly the stranger the curl one-liner serves.
A second force: the bootstrap script is fetched from `main`'s raw URL, so its
behavior is permanently unversioned relative to the code it installs.

## Decision

The managed clone has exactly one owner per phase of its life:

- **bootstrap owns first-install only.** It clones with enough history for
  tags to resolve and lands the clone on the latest release tag (falling back
  to `main`, with an explicit warning, only when no tag exists). It never
  performs an in-place upgrade: a bootstrap re-run against an existing install
  delegates to `temperloop update` rather than pulling.
- **`temperloop update` is the sole post-install HEAD mover.** It fetches
  tags, surfaces the CHANGELOG delta (including `BREAKING` sections) before a
  consent-gated checkout, re-runs the idempotent manifest-backed install, and
  finishes with the doctor check. Across an install-manifest/config schema
  bump it migrates or halts legibly *before* moving HEAD.
- **Neither mechanism ever writes a repo-tracked path in any target repo.**
  A repo-tracked change a new version requires ships as a normal branch/PR
  through the standard flow, never as a side effect of a personal update.
- **bootstrap-on-`main` carries a standing compatibility obligation**: it must
  work against every invitable tag (or re-exec the checked-out tag's own copy
  of itself after clone).

## Consequences

Benefits: the stranger's re-run path has no dead end; upgrades become
consent-gated and observable (BREAKING surfaced before checkout, doctor
after); one member of a team updating their personal install cannot change
what teammates' CI runs. Costs: cutting release tags becomes a standing
operator obligation (bootstrap-to-tag is meaningless without tags), and the
bootstrap script inherits a permanent backward-compatibility constraint.
Follow-on work: the tag-to-tag sandbox test (including a schema-crossing
jump once one exists), and lifting `breaking_sections()` out of
`scripts/update-kernel.sh` into a shared lib so `bin/` does not back-channel
into `scripts/`.
