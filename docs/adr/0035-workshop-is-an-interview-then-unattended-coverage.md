---
title: "0035: /workshop is an interview, then unattended coverage, then one delta approval"
---

## Status

Proposed

## Context

`/workshop` walked a design through the schema's 17 dimensions one stop at a
time: the facilitator drafted each dimension, persisted it, composed a
decision presentation, and asked the operator to accept it. On the
2026-09-11 graph-of-record brief that was 26 modal stops, 10 of 11 walk
stops accepted unchanged, ~1 minute of dead time each, and approvals over a
gist while the text sat in a separate note. The operator's purpose for the
command — "an efficient mechanism to provide context to Claude for the
creation of new features/changes" — was inverted: Claude drafted, the
operator audited. The review panel, by contrast, folded ≈25 real findings
on the same brief.

epic: Towheads/temperloop#1938 — ratified brief
`Designs/temperloop - workshop two-phase interview` (private knowledge store)

## Decision

`/workshop` becomes two phases with two operator gates.

**Phase 1** is a standalone `/interview` skill, executed inline by
`/workshop`: the design is a decision tree; each round asks the whole
*frontier* (every decision whose prerequisites are settled) via
`AskUserQuestion` calls of at most four questions, recommended option
first, in the same turn as the previous answer. Facts are fetched by
read-only subagents at `INTERVIEW_PROBE_MODEL`, never asked. The premise
gate is the first question of round 1; the Contract confirm is the last
question. The phase ends with an understanding check that also carries the
review-tier choice.

**Phase 2** runs unattended in the foreground: expand every dimension
(flagging any the interview never touched `facilitator-drafted, not from
interview`), validate the brief, run the ported panel and congruence pass,
fold findings, and — when more than half the dimensions are
facilitator-drafted — one targeted interview round on the highest-value
undiscussed decisions. It ends with a chunked **delta report**: full text
and before/after per changed dimension, the Δ carried inside each cluster
question's block, one operator verdict per dimension, a soft cost
checkpoint on a third re-presentation. Then ratify and the unchanged
materialize step.

The walk, its tier-split stop, its three-round bound and its walkthrough
pass are removed in one release (BREAKING-marked). Acceptance is not a
call-count cap: zero acknowledgement-only calls, no dead time, and a
reported tally.

## Consequences

- A stranger with an idea answers a few rounds of batched decisions and
  approves once with everything on screen; the coverage machinery that
  demonstrably pays (the panel) is kept, the part that did not (the walk)
  is gone.
- `claude/commands/interview.md` is a new command; `workshop.md` is
  rewritten and drops documented steps, so the release is BREAKING with a
  migration line; `claude/design-schema.md`, the brief validator,
  `message-schema.md` § Decision presentation, the feature doc and a
  17-file cross-reference sweep move with it (ADR 0036 covers the record
  grammar).
- The interview cannot guarantee coverage; the facilitator-drafted flag
  and the >50 % ratio gate are the honest answer, and the first prototype
  run sat at 12 of 17.
- Risk R1 fired on the first run (the delta-report questions carried no
  context inside the block) and is folded as a rule; two more such
  operator answers fall the design back to draft-then-clarify.
