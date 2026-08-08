---
title: "0026: per-seat attribution telemetry coexists with transcript-based cost measurement"
---

## Status

Proposed

## Context

epic: Towheads/temperloop#1225

ADR 0020 decided that cost measurement reads session transcripts: no new
telemetry stream is emitted and no model call site changes. That decision holds
for what it was made about — the *spend* number. But the model-comparison
harness (epic #1225) needs something transcripts structurally cannot provide:
attribution. A transcript records what a session spent by model; it cannot say
which pipeline *seat* (sweep worker, fix worker, triage, drive) spent it, nor
which *outcome* (which issue, which merged PR) the spend produced. Whole-job
cost per merged outcome — the comparison report's primary metric — requires
exactly that join.

The naive fix, replacing the transcript producer with spawn-site emission, is
the alternative ADR 0020 explicitly rejected, and re-litigating it would
reopen the counting traps that decision documents (requestId dedup, cache-class
weighting). The naive alternative in the other direction — deriving attribution
from transcripts after the fact — fails because the transcript does not carry
the seat identity or the outcome ref; only the spawn site knows both at spawn
time.

## Decision

Two producers, one owner per number. The transcript-based producer (ADR 0020)
remains the sole owner of the report's headline dollar/spend figure. A new
per-seat attribution stream — one record per spawned seat per run, carrying
seat name, model, provider, token counts, duration, and outcome ref — owns
seat and outcome attribution, and nothing else. The attribution stream
inherits ADR 0020's counting rules (requestId dedup, cache-class weighting)
rather than re-deriving them, so the two producers can never disagree about
how a token is counted; divergence between them is a defect with a declared
owner, not an ambiguity. Attribution records are schema-validated at content
level (model/provider enums, field shapes), paired with an emit-site validator
in the existing emit/validate family, and the stream is schema-versioned from
day one.

## Consequences

- Whole-job cost per merged outcome becomes computable: attribution records
  supply the seat/outcome join, the transcript producer supplies the money.
- Every current and future spawn site owes an emission; the paired validator
  turns a missing emission into a gate failure instead of a silently
  under-counted seat.
- ADR 0020's "no new telemetry stream" clause is narrowed, not overturned: no
  new stream competes for the *spend* number; the new stream exists only for
  attribution, which 0020's producer never claimed.
- The usage-capture path parses the `claude -p` CLI result, so a CLI format
  change breaks emission visibly (validator) rather than as silent zeros.
