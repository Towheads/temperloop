---
title: 0003: Fleet cutover rides committed repo-local boards.conf entries, not the built-in map
---

## Status

Proposed

## Context

epic: Towheads/temperloop#460

Flipping a board's backend can happen at two seams: the kernel's built-in
case map inside the vendored `board.sh` (reaching every checkout only on
each one's own vendor-sync/pull cadence), or a `boards.conf` entry, which
the adapter's discovery order resolves ahead of the built-in map and which
can be committed to the consuming repo itself.

An in-code default flip has a fleet-atomicity problem: between the flip
landing upstream and each vendored copy syncing, an unsynced checkout (a
cron host, a lagging operator machine) keeps reading and writing the old
Projects board while synced checkouts write labels — split-brain state
accumulating precisely during the soak window that is supposed to be the
safety net. It would also silently invert a documented, test-pinned
contract: ISSUES-ONLY-BACKEND.md declares the built-in map additive-only,
with board 7 (the kernel tracker) its sole in-code issues-only exception.

## Decision

Each migrating board flips via a **committed `boards.conf` entry in its own
consuming repo**. The cutover unit is one repo, atomic on that repo's own
pull: sync the adapter, freeze board writes for a short announced window,
run the migration with parity verification, commit the conf flip — one
change. The kernel's built-in case map is untouched by the migration epic;
the additive-only rule and its config-selection test pin survive intact and
are superseded only by the follow-on removal epic, which retires the
Projects defaults explicitly. During soak, the frozen Projects boards are
monitored for post-flip writes — any write there is the tell of a lagging,
unsynced checkout still driving the dead arm.

## Consequences

- Per-repo atomicity: a checkout is on exactly one backend the moment it
  pulls its own repo, regardless of kernel vendor-sync lag.
- The migration epic stays additive/minor (no built-in default changes, no
  broken contract); the breaking change concentrates entirely in the
  later removal epic, per VERSIONING.md's marker machinery.
- The supersession of the "board 7 is the sole permanent exception"
  language is deliberate and documented at removal time, not shipped
  silently mid-migration.
- Reverting a repo's cutover during soak is one conf-line deletion — the
  Projects board state is untouched until retirement, which is ordered
  last.
- `boards.conf` remains per-checkout/per-repo configuration and is never
  vendored into a downstream or client repo; an operator working across
  many orgs keeps one conf per client for isolation.
