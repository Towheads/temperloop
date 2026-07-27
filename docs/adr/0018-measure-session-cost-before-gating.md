---
title: "0018: measure realized session cost before gating it"
---

## Status

Proposed

## Context

epic: Towheads/temperloop#810

ADR 0015 introduced a two-tier CI budget gate on the kernel prose plane, capping
line counts. Its stated motivation was that "a fresh clone must absorb the whole
composed surface before its first session". Two facts have since been measured
that the ADR could not have had at the time.

**The unit does not track the cost.** `CLAUDE.kernel.md` averages ~189 bytes per
line, so its "lines" are paragraphs and a line cap constrains paragraph count
rather than size. This is not theoretical: the citation-marker commit added
~2,260 bytes to that file while its line count stayed at 336. The gate then
satisfied its own `after < before` acceptance criterion — tier-1 cap 340 to 335,
a five-line reduction — over a window in which the document it governs grew from
61,314 to 63,817 bytes.

**The stated motivation is false for the case it cites.** A real install from a
kernel-only clone, executed against a scratch `HOME`, wrote 24 managed paths and
no composed `CLAUDE.md` at all: the compose target is emitted only when both the
kernel doc and an overlay doc are present, and a kernel-only checkout has no
overlay by construction. A fresh clone's auto-loaded footprint is roughly 14 KB —
a project-level pointer file plus agent and command descriptions in the two
listings — not the composed surface the ADR assumed.

Two subsequent design attempts to correct this each failed the same way. The
first proposed conditional composition — omitting sections whose capability is
absent — which cannot work as a general lever, because the composed file is
written once per machine while capabilities such as board-enablement are per-repo
properties; omitting a section for one repo strips it for every repo on that
host. The second proposed relocating per-repo-conditional prose out of the
always-loaded document, measured against session-start context. That measurement
is taken before the agent reads any file, so relocation improves it by
construction whether or not the agent then reads the relocated content later in
the same session — which, in a repo where the content applies, it will.

The recurring shape across all three: the metric was easier to move than the
thing it stood for.

## Decision

Establish measurement before enforcement, as two phases with only the first
committed.

Phase A ships measurement and no enforcement: per-contributor measurement of the
session-start surface; a probe measuring **realized context across a session**
rather than only the session-start prefix; a pre-registered baseline published
before any reduction work begins; a timeboxed, pre-registered proxy for whether
instruction volume affects rule adherence; and a backtest replaying real historical
pull requests against draft gate logic. It ships no cap, no target and no CI gate,
and nothing in it can fail a contributor's build.

Phase B — a budget gate and the prose reductions to meet it — is scoped in the
design brief but **not committed**. Whether it proceeds is decided by Phase A's
backtest, whose interpretation is pre-registered before the run: few historical
regressions of the bytes-without-lines shape means a gate is not warranted; many
means it is.

Correspondingly, session-start context is **retained as a component measure but
rejected as the sole outcome measure**. Any future budget must be validated
against realized session context.

ADR 0015 is not superseded — its citation-marker convention, deletion surface and
pointer-collapse discipline stand. Its motivating premise is corrected by Phase A,
and its tier-1 gate is the subject Phase B would replace if warranted.

## Consequences

**Accepted cost.** Phase A enforces nothing, so accretion continues while it runs.
The measured rate is roughly +8.8k tokens per session-start per week. This is a
real, quantified cost of waiting, accepted because three prior enforcement
attempts each moved a number without moving the cost, and a fourth built on an
unvalidated metric would most likely repeat that.

**Benefits.** A target becomes derivable from evidence rather than asserted before
it. The question of whether a gate is warranted at all is settled by data rather
than by an acceptance criterion the work grades itself against — the previous two
attempts both produced criteria that could not fail in a way that would have
falsified their own necessity. Phase A also delivers value independent of Phase B:
a discovery leak that places seven language-reviewer agents into every session
despite being specified as inert until opted in, and this ADR's correction of ADR
0015's premise.

**Follow-on work.** If Phase B proceeds, several constraints are already recorded
in the design brief and must be honored: a consuming repo cannot fork a
kernel-registered setting, so a consumer cap must ride the setting-registry
overlay-extension mechanism; byte counting of the composed document is
host-dependent and must not break the existing determinism contract; and the
guarantee that kernel checks never fail on adopter-owned content needs a mirror —
a kernel addition within its own cap must not be able to fail a consumer's gate.

**Risk this decision does not close.** Phase A's proxy for instruction dilution
may find no workable measurement. That outcome is defined as a legitimate result
which triggers a re-scope, rather than as a blocker or a gap to paper over.
