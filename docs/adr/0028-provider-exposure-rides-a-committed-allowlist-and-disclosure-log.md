---
title: "0028: provider exposure is governed by a committed allowlist and a disclosure log"
---

## Status

Proposed

## Context

epic: Towheads/temperloop#1225

A replay or live-tagged run under a non-Anthropic candidate model sends real
repository code, issue text, and prompt content to that vendor's hosted API —
for some vendors that means training-on-inputs by default and a
foreign-jurisdiction data-governance surface. The consent question is sharper
than it first looks, because the content being sent is usually not only the
operator's own: a shared repo's history carries teammates' code, and a
consultant's replay corpus carries a client's. A personal config file cannot
carry consent for content it doesn't own, and operator-scoped state (`$HOME`
config, env vars) is a cross-engagement bleed vector by construction — a flag
flipped for one repo's session silently carrying into the next.

Consent and audit are also different artifacts: an allowlist says what *may*
be sent; contractual data-governance obligations require being able to show,
after the fact, what *was* sent, where, and when.

## Decision

Three coupled rules, all repo-scoped:

1. **The provider allowlist is a committed, repo-scoped, team-visible file,
   default Anthropic-only.** It lives in the adopting repo and changes only
   through review, like any other change. On a multi-person repo the committed
   file is the ceiling: an individual's personal configuration may narrow it,
   never widen it. A fresh install can never send content to a third-party
   vendor by accident.
2. **Every send to a non-default provider appends one entry to a repo-local,
   append-only disclosure log** — provider, item ref, timestamp, never
   content. The log is paired mechanically with the allowlist (a
   non-default-provider send without a log entry is a validator failure), and
   it is the artifact an operator can hand a teammate or a client's reviewer.
3. **The judge runs on the trusted default provider by default; the optional
   judge-rotation mode is the one named exception**, and it goes through the
   same allowlist and disclosure log as a candidate replay — never a silent
   carve-out.

Harness artifacts (telemetry records, scored results, reports, disclosure
logs) live under the repo's untracked runtime dir, never the tracked tree and
never a personal knowledge store, and records carry seat role names rather
than any cross-repo operator identifier.

### Amendment (temperloop#1316): the disclosure log's ANCHOR is committed

One named, deliberately narrow exception to "never the tracked tree" above.
The disclosure log is hash-chained and anchored by a sibling watermark file
holding two values — how many entries the log is meant to have, and its tail
hash. That anchor originally sat in the same untracked runtime dir as the log,
so whoever could rewrite the log could rewrite its anchor in the same motion:
a full re-forge verified clean, and the audit artifact decision 2 promises
could be silently rebuilt.

The **anchor** — and only the anchor — therefore moves into version control at
`workflows/scripts/model-comparison/disclosure-log.watermark`, beside the
committed allowlist. The **log itself stays untracked**, so no provider
history and no content enters the repo; the anchor carries neither. The
validator now additionally checks the live log against the anchor *as
committed in git*, so a re-forge must also rewrite git history to stay
hidden — which leaves its own trace.

The threat this closes is a careless or self-serving **local process** (an
agent or script regenerating state, an operator tidying a log before review),
not an external attacker: local write access makes everything local theirs
anyway. Signing entries and shipping to an external append-only sink were both
considered and rejected as overbuilt for that threat — key management this
repo has no story for, and a second home for provider history.

## Consequences

- Consent has the right grain: the committed file carries shared-content
  consent that personal config structurally cannot, and repo-scoping kills the
  cross-engagement carryover vector.
- Auditability is mechanical, not remembered: the allowlist/disclosure-log
  pairing is validator-checked, so the audit trail cannot silently lag the
  consent surface.
- The friction of adding a provider (a reviewed commit plus a key) is a design
  choice, deliberately placed exactly where content would first leave the
  trust boundary.
- Untracked, role-named records mean removal is a local cleanup, and records
  from two repos cannot be correlated into a client-relationship inference.
- The committed anchor (amendment above) costs one reviewed line whenever the
  log grows, and buys the property the log's own hash chain structurally
  cannot have: a re-forge that leaves no trace now requires rewriting git
  history, which does.
