# Measurement proxies for communication quality

Falsifiability contract for the communication-style model (temperloop#94, epic
[[Plans/2026-07-06 temperloop - communication style model]]). Before any
`claude/message-schema.md` template lands, this file pins **what "highly readable"
cashes out to** — named, checkable proxies, each tied to a data source (or an
explicitly named gap) and a baseline capture method, so a post-template change is
comparable against a pre-template number instead of against vibes.

## Independence from the template layer

**These proxies measure the system. They do not gate template authoring.** This
file has no dependency edge on `claude/message-schema.md` (no `depends-on:` /
`after:` in the epic's plan) and `message-schema.md`'s authors are not blocked on
any proxy reaching a target value here — a proxy with no baseline yet, or a proxy
whose data source is a named gap, is not a reason to hold the template work. The
relationship runs the other way: once templates ship, these are the numbers you
pull to ask "did the change help, hurt, or do nothing" — after the fact, not as a
merge gate.

## Proxies, not proofs

None of what follows is a validated efficacy metric. A proxy here is a cheap,
directionally-informative signal that correlates with communication quality by
plausible mechanism (fewer clarifying round-trips plausibly means the first
message answered more of what the reader needed) — not a causally-proven measure
of it. Read every number as "this moved, worth a look," never as "this proves the
template worked." Where a proxy's own mechanism is contested or untested, that
caveat is stated inline rather than smoothed over — see in particular Proxy 4,
which rests on a **structural** research finding (deferral to breakpoints has a
real cost) but an **untested** application (whether that cost predicts operator
satisfaction with *this* kernel's digests).

## The seven interaction modes (recap)

Canonical in temperloop#94; restated here only so each proxy's mode-mapping is
self-contained:

1. **CLI terminal output** — `try`/`init`, board commands, `gate.sh`
2. **Live conversational narration** — slash commands mid-session
3. **Blocking questions** — `AskUserQuestion` / `decision_sink_ask(...)`
4. **Return-cold summaries** — completion summary, resume recap, parking notes
5. **Unattended/deferred surfaces** — pending-decisions, digests, funnel-tick reports
6. **Durable review artifacts** — PR bodies, issue/epic contracts, plan notes, decision notes
7. **Newcomer/docs surface** — README, `bin/README`, generated docs site

## Proxy 1 — Clarification round-trips per item

**What it measures.** How often the operator has to answer a clarifying question
before an item's work proceeds — a high count suggests the initiating message
(a question block, a PR/issue body, a digest entry) didn't carry enough of the
right context the first time.

**Data source.** `claude/decision-queue-contract.md` is the kernel-native seam
this rides:

- **Async backend (operator-absent runs).** Every `decision_sink_ask(...)` call
  routed to the async backend creates or reuses a `decision`-labeled GitHub
  issue and flips the assignee baton (assign-to-operator = park, unassign =
  answered — contract § 1). A round-trip is countable directly from issue
  history: `gh issue list --label decision --state all --json number,assignees,timelineItems`
  gives assign/unassign timestamp pairs per item; the **parse-miss rule**
  (contract § 3) additionally makes a *failed* round-trip explicit — a
  "Couldn't parse your reply" re-assignment is a distinguishable, countable
  event, not silently absorbed. This is a genuinely existing, machine-readable
  source; no new instrumentation is needed to pull it.
- **Modal backend (operator-present sessions).** `decision_sink_ask(...)`'s
  modal path is a live `AskUserQuestion` call inside the conversation — a bare
  kernel checkout persists no record of it. **Named gap:** counting modal
  round-trips requires either (a) new instrumentation (an emit site logging
  each `decision_sink_ask` invocation + severity + resolution to
  `meta/data/raw/`, following the existing `command-run`/`issue-touches` stream
  convention in `meta/data/raw/README.md`) or (b) reading session transcripts,
  which is an **overlay-only** capability (the personal session-log hook and
  archive — not present in a stranger's kernel-only install). Until (a) exists,
  the modal half of this proxy is manual-sample-only.

**Baseline capture method.** Before `message-schema.md` lands: pull the last
N (suggest N≥20) `decision`-labeled issues closed in the async backend, compute
the assign→unassign count per originating plan item (a `[ ]`-parked-then-answered
`## Questions` entry, or a `blocking-now` gate) and the parse-miss rate as a
fraction of total round-trips. Record median round-trips/item and parse-miss %
as the pre-template baseline. For the modal path, manually sample N recent
`/build`/`/assess` sessions (via the overlay session archive, where available)
and hand-count `AskUserQuestion` occurrences per item as a rougher baseline,
noting it is not automated.

**Modes measured.** Mode 3 (blocking questions) directly; Mode 5 (unattended/
deferred surfaces) for the async decision-queue instantiation specifically.

## Proxy 2 — Friction-ledger re-read / search-thrash entries

**What it measures.** How often a session re-checks state it already had,
re-verifies a diagnosis it already confirmed, or thrashes searching for context
it should have had on hand — proxies for "the prior message/summary/artifact
didn't leave the reader with enough confirmed state," across whichever of the
six tracked categories applies: `redundant-status-check`,
`reverification-backtrack`, `probe-after-not-before`, `stale-context-rework`,
`tool-misuse`, `search-thrash`.

**Data source.** `Context/Session friction ledger.md` in the Obsidian vault —
**explicitly an overlay/personal-vault-backed source, not a kernel-native one.**
The six category slugs and the append convention are documented in the
*composed* (kernel + overlay) `CLAUDE.md` § "Tooling friction capture," but the
ledger file itself lives at `~/dev/mind/Context/Session friction ledger.md`,
which a stranger's bare kernel checkout does not have and this repo does not
ship. **Named gap for the kernel-only case:** a stranger install has no
equivalent log and no obligation to build one — this proxy is only available to
an install that has adopted the overlay's vault convention. Where it *is*
available, it is a real, already-being-written log — no new capture mechanism
is needed, only a read.

**Baseline capture method.** Where the ledger exists: count entries by category
dated in a fixed pre-template window (suggest: the 30 days before
`message-schema.md` merges), producing a per-category count. After templates
ship, count the same categories over an equal-length post-template window and
compare. `redundant-status-check` and `stale-context-rework` are the categories
most directly load-bearing for template quality (they fire when a completion
summary or resume recap didn't leave enough state behind); `search-thrash` and
`tool-misuse` are more diagnostic of tooling friction than communication
quality and should be read as weaker signal for this specific question.

**Modes measured.** Mixed, by category: `stale-context-rework` and
`redundant-status-check` → Mode 4 (return-cold summaries) and Mode 2 (live
narration); `probe-after-not-before` → Mode 5 (unattended surfaces not trusted
before acting) and Mode 6 (durable artifacts not consulted before re-asking);
`search-thrash` and `tool-misuse` are largely orthogonal to communication style
and are included here for completeness, not as strong evidence either way.

## Proxy 3 — Re-ask rate after summaries

**What it measures.** How often a reader (operator or a fresh session resuming
cold) re-asks something a completion summary, resume recap, or parking note
already answered — the most direct falsification of "highly readable": if the
reader has to ask again, the summary didn't communicate.

**Data source: named gap, no automated source exists today, kernel or
overlay.** No emit site logs "operator's next turn restated a question the
prior summary already answered" — detecting this requires semantic comparison
between a summary's content and the reader's next utterance, which nothing in
the pipeline currently does. The nearest **existing partial proxy** is the
friction ledger's `stale-context-rework` category (Proxy 2) — an operator
re-asking because a summary didn't stick is one concrete instance of that
category, but the category is broader (it also covers a session re-deriving
context with no summary involved at all), so it over- and under-counts this
specific behavior.

**Baseline capture method (manual, stated honestly as such).** Sample N
completion summaries / resume recaps from the session archive (`meta/sessions/
archive/` in a repo that has adopted that convention, or raw transcripts where
available) and read the immediately-following operator turn(s). Count how many
of the N summaries are followed by a question whose answer the summary already
gave. Record the fraction as the pre-template baseline. This is
labor-intensive and not something to run at high frequency — a coarse,
periodic spot-check (e.g. at each retro pass) is the intended cadence, not a
per-session metric.

**Modes measured.** Mode 4 (return-cold summaries) primarily; Mode 2 (live
narration) secondarily, when a status narrated moments earlier gets re-asked
in the same session.

## Proxy 4 — Decision-queue resolution latency (deferral-cost proxy)

*Justified by the L0 Tier-2 verdict 2(b) (Iqbal & Bailey, confirmed): deferring
non-urgent interruptions to natural breakpoints has a real, measured
acceptable-delay cost (~90s / 88.6s mean), which is the anchor
`message-schema.md`'s Mode-4/5 digest-cadence design will lock. This proxy is
the closest kernel-native analog available to check that design decision
against reality once it ships.*

**What it measures.** How long a park-to-operator decision (Mode 5: pending
decision, digest entry, funnel-tick report) sits before the operator disposes
of it — a proxy for whether the digest/summary cadence is landing at a natural
breakpoint (fast, low-friction resolution) versus interrupting badly (slow,
or requiring the parse-miss retry loop in Proxy 1).

**Data source.** The same `decision`-labeled issue trail as Proxy 1: assign
(park) → unassign (answered) timestamps, pulled via
`gh issue list --label decision --state all --json number,assignees,timelineItems`.
This is kernel-native (owned by `claude/decision-queue-contract.md`) and
requires no overlay dependency, unlike Proxies 2 and 3.

**Baseline capture method.** Before `message-schema.md`'s digest-entry template
exists, pull the resolution-latency distribution (median, p90) for the last N
resolved decision-queue issues. Record it as the pre-template baseline. After
the digest template ships, pull the same distribution over an equal window and
compare medians. **Caveat, stated plainly:** a shift in this number is
*consistent with* better or worse digest cadence but is confounded by operator
availability, issue urgency mix, and unrelated schedule changes — it is not a
controlled measurement of the Endsley/Iqbal-Bailey research being applied
correctly, only a directional check that resolution isn't getting slower.

**Modes measured.** Mode 5 (unattended/deferred surfaces) primarily; Mode 4
(return-cold summaries) secondarily, since a parked decision is itself a
return-cold artifact the operator eventually reads.

## What this proxy set does not cover

Modes 1 (CLI terminal output) and 7 (newcomer/docs surface) have **no proxy
above** — naming that gap rather than stretching an existing proxy to cover it.
Neither mode currently has a data source in this repo (no telemetry on CLI
output legibility; no reader-comprehension signal on docs). A future addition
here — e.g. an issue-tracker signal on "filed a bug that was actually a docs
gap" for Mode 7, or a shell/exit-code parse-failure count for Mode 1 — would
need its own data source named before it belongs in this file; it is not
retrofitted speculatively.

## Cross-references

- Epic: temperloop#94 ("Communication style model: interaction-mode
  presentation layer")
- Peer contract this file deliberately has no dependency edge on:
  `claude/message-schema.md` (not yet authored at the time of writing)
- Decision-queue mechanics (Proxies 1 and 4): `claude/decision-queue-contract.md`
- Raw telemetry stream conventions (the pattern a future modal-path emit site
  would follow): `meta/data/raw/README.md`
- Friction-ledger categories and capture convention (Proxy 2): composed
  `CLAUDE.md` § "Tooling friction capture" (overlay-backed; see the named gap
  in Proxy 2 for the bare-kernel case)
- L0 verification verdicts justifying Proxy 4:
  `Context/temperloop - communication-style Tier-2 verification verdicts.md`
  (vault note, cluster 2(b))
