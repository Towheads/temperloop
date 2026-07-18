---
title: "0003: Knowledge-store sync is an optional backend capability, not a universal interface op"
---

# 0003: Knowledge-store sync is an optional backend capability, not a universal interface op

## Status

Proposed

## Context

The beta milestone (epic: temperloop#419) adds a git-backed sync
seam for the knowledge store, so a real store can be replicated into fresh
environments (its primary in-beta purpose is making fresh-install validation
against real data cheap and repeatable). The `knowledge_store` contract
(`workflows/scripts/lib/knowledge_store.contract.md`) defines a backend as
document I/O ops that every backend must implement. Sync is a *store-level*
operation that is only coherent for the `plain-files` backend (a git repo
under `KNOWLEDGE_STORE_ROOT`); the `obsidian` backend does not consult
`KNOWLEDGE_STORE_ROOT` at all — the vault root *is* the store root — so a
git-under-root sync has no meaning there. Adding sync as a universal op would
hand every future backend author an unimplementable obligation.

## Decision

Sync joins the `knowledge_store` interface as an **optional backend
capability**, following the availability-probe precedent `ks_search` already
established: a backend that cannot implement it degrades to the legible
exit-3 `skipped — sync unavailable for backend <name>` pattern, never a
silent no-op and never a hard failure. Behavioral contract for the
`plain-files` implementation: manual invocation only (never a scheduled or
background job); private remote by default; the store is user data —
uninstall never deletes or de-remotes it, and no sync-specific residue
(remote config, credentials) survives uninstall beyond the explicitly-kept
store directory. The store remains single-tenant per `$HOME` (one flat root);
per-project partition is tracked separately (temperloop#418) and is
out of this decision's scope.

## Consequences

Benefits: the interface stays honest (no backend inherits an op it cannot
implement); the degradation path is a pattern the codebase already tests;
Obsidian-free multi-environment replication becomes possible for the default
backend. Costs: adding the capability is an additive contract-surface change
to `knowledge_store.contract.md` (CHANGELOG-marked per `VERSIONING.md`'s
published-contracts row), and callers must branch on capability availability
rather than assuming sync exists. Follow-on work: the exact CLI surface
(subcommand vs. documented git usage) is decided at `/assess` time inside
this seam; the single-writer assumption and git-native conflict story are
documented as experimental-scope limits in stranger-facing docs.
