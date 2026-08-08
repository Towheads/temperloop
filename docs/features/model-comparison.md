---
title: model-comparison
slug: model-comparison
---

# Model comparison

An inert, opt-in module that measures how a candidate model performs against
this repo's own real, closed-out work — before anyone re-routes a seat's
model in production. It ships in two halves with different standing: an
always-on **attribution telemetry stream** that every kernel-spawned seat
writes to (kernel, uncontroversial, costs nothing), and a **comparison
half** — replay runner, judge pass, comparison report — that does nothing
until an operator deliberately invokes it ([ADR
0027](../adr/0027-model-comparison-ships-as-an-inert-opt-in-module.md)).
Provider exposure (sending real repo content to a non-Anthropic vendor) is
governed separately by a committed allowlist and an append-only disclosure
log ([ADR
0028](../adr/0028-provider-exposure-rides-a-committed-allowlist-and-disclosure-log.md)).

## Problem

Deciding whether a cheaper model tier, or a non-Anthropic vendor model, is
good enough for a given pipeline seat is currently a guess: nobody re-runs
the same real work under two models and compares cost and quality
side-by-side, so a routing change either never happens (leaving spend on the
table) or happens on anecdote (risking quality nobody measured). Provider
routing itself — actually pointing a seat at a different vendor by default —
is a separate, later design decision; this module exists to give that later
decision an evidence base, on this repo's own history, rather than on a
synthetic benchmark that may not resemble what this pipeline's seats
actually do.

A second, sharper problem is honesty about what such a comparison can and
can't prove. A typical repo closes a modest number of issues in any given
window, a replay corpus never recovers 100% of that history cleanly (see
"Replay corpus and ground truth" below), and a small-N comparison invites
exactly the failure mode this module is built to avoid: a confident-sounding
verdict from statistically indistinguishable numbers. Every report this
module produces is required to say plainly when it can't tell winner from
noise, rather than pick one anyway.

## How it works

The module has five moving parts: an always-on attribution stream, a
replay runner, a live-tagging provenance layer, a judge pass, and a
comparison report that turns the first four into a number an operator can
act on. Each is described below, in the order a comparison actually flows.

### Per-seat attribution telemetry

Every kernel-spawned seat (a `/sweep` fix worker, a `/build` item worker, a
`/fix` worker, a drive-tier machinery call, and so on) writes one record per
spawn to a dedicated attribution stream: seat name, model, provider, input
and output token counts, duration, and an outcome reference (the issue or PR
the spawn was working on). This is a **second, narrower producer alongside**
the existing transcript-based cost measurement documented in
[`telemetry.md`](telemetry.md) — that producer keeps sole ownership of the
report's headline dollar/spend figure; the attribution stream exists only to
answer a question transcripts structurally cannot: *which seat, working on
which outcome, spent this?* ([ADR
0026](../adr/0026-attribution-telemetry-coexists-with-transcript-cost.md)).
Records are validated at content level (model/provider enums, field shapes),
not merely checked for presence, and the stream is schema-versioned from day
one.

One correction to that ADR's original text, surfaced by the L0
usage-capture-feasibility spike (temperloop#1246): the transcript producer's
request-id dedup rule does not carry over to this stream. Dedup exists to
collapse a transcript's redundant retries into one countable call when
*scanning* a transcript after the fact; a per-seat attribution record is
instead written once, at the spawn site, so there is no duplicate record for
dedup to collapse. The rule is **inapplicable** to attribution, not silently
inherited by it — worth stating plainly because the ADR's consequences
section reads as if both counting rules transfer unchanged, and only one of
them does.

See "Emit coverage is structurally partial" under Telemetry below for the
honest state of how many seats can actually emit this record today.

### Replay runner

Given a closed issue or merged PR from this repo's own history, the replay
runner re-runs that work item headlessly under a named candidate model, in
an isolated worktree, and produces a scored result: a diff against the
merged ground truth, quality-gate outcomes, tokens, and duration. Isolation
is structural rather than trust-based: the worktree carries no configured
push remote, runs under the kernel's write-guard class, lives under a
per-repo-derived scratch path, and is torn down on both success and
failure — a post-run probe backstops that, it isn't the primary control.

Before a batch of replays runs, a pre-flight estimate prints the eligible-N
for the requested window, the estimated token/dollar cost, and whether that
N can realistically reach the module's significance threshold — so an
operator sees the tradeoff before spending anything, not after.

**Replay corpus and ground truth.** The L0 replay/ground-truth spike
(temperloop#1247) measured this end to end against real history rather than
assuming it: of the closed issues sampled, only **about 52%** yielded a
usable replay (a reconstructable prompt, a resolvable pre-merge base, and a
scoped diff) — the rest were excluded for reasons the spike catalogs, such
as squash merges bundling unrelated refactors or formatting-only churn that
would contaminate a diff-based score. Base resolution itself has more than
one defensible answer: the runner uses `git merge-base $MC^1 $MC^2` (the
fork point) as its rule, but of three plausible base-resolution strategies
the spike compared, they disagreed on **21 of 60** real merged PRs — meaning
the choice of base is not a formality, it measurably changes what "the
candidate's diff" is scored against. This is why the replay corpus is
described here as a **~52% yield**, not "the corpus," and why a comparison
report states its corpus window and gate versions rather than implying the
whole history was usable.

**Low-volume guidance.** Below roughly the module's configured sample
threshold — and given the ~52% yield above, a repo that closed 60 issues in
a window supplies on the order of 30 usable replays, not 60 — statistical
significance is very likely unreachable. Treat a report generated from a
low-N window as directional at best, or skip running the comparison until
enough history has accumulated to say something with a straight face. The
report itself enforces this rather than leaving it to the reader's
judgment: a run below the configured threshold returns an explicit
`inconclusive` verdict and never returns a winner.

### Live candidate tagging

Live tagging adds **no new model-selection mechanism**: an operator points
the existing declared setting `$SWEEP_WORKER_MODEL` at the candidate for a
bounded, recorded window, exactly as they would to change the default tier.
What this module adds is provenance — a window record, a stamp on the
resulting PR naming which model produced it, and a matching telemetry tag —
so a live-tagged singleton's outcome can be correlated back to the model
that produced it after the fact.

### Judge-scored quality assessment

Every replayed or live-tagged output is scored by a judge model, extending
the same rubric/verdict lineage `judge.py` already uses (its `JUDGE_BIN`
seam) rather than inventing a second scoring mechanism. The judge is never
the candidate being scored (`judge != candidate`, enforced on every record).
That guard is stated honestly for what it is: it prevents **self-grading**,
it does **not** neutralize model-family style bias — a judge from the same
family as the candidate can still systematically favor that family's
phrasing. For a cross-vendor comparison, an optional judge-rotation mode
scores the same output with judges from more than one family and reports
the per-judge variance, rather than presenting one judge's opinion as
ground truth. A rotated judge outside the default provider is the one named
exception to "judge stays on the trusted default provider" — it goes
through the same allowlist and disclosure log as a candidate replay, never
as a silent carve-out ([ADR 0028](../adr/0028-provider-exposure-rides-a-committed-allowlist-and-disclosure-log.md)).

The judge's rubric borrows the reviewer-agent charters' checklists as prompt
*content* (the shell/architecture/language checklists inform the rubric
text); there is no runtime reviewer-agent invocation from this module —
reviewer agents stay live-session, human-facing tools.

### Comparison report

Given baseline and candidate records, the report emits whole-job cost per
merged outcome, judge quality scores, gate outcomes, intervention/rework
counts, and duration — with the uncertainty stated up front rather than
buried: a bootstrap confidence interval, the explicit `inconclusive` verdict
below the sample threshold described above, and a **minimum-detectable-effect
disclosure** ("at this N, only deltas of at least X are detectable") so a
comparison that can never reach a verdict at its current sample size is
visible before anyone reads a number as a conclusion. It also states the
emit-coverage percentage the underlying attribution records achieved (see
Telemetry below), the corpus window and quality-gate versions the comparison
ran under, and a **stated cost basis**: whether the dollar figure it shows
is *metered dollars* (what the vendor actually billed for that call), a
*token count* (the model-independent unit, comparable across providers that
bill per token differently), or a *subscription-usage share* (quota consumed
against a flat-rate plan like Claude Max/Pro, which has no per-call dollar
figure at all). These are not interchangeable units, and a report that
didn't name which one it's using would let a reader silently compare
apples to a subscription quota.

**Capability limits, stated plainly.** At the sample sizes a real repo can
realistically supply — tens of replays per window, not thousands — this
module can detect large deltas and cannot reliably detect small ones; a
report showing "no significant difference" is evidence of *no large
difference*, not evidence of equivalence at every margin. Just as
importantly, a verdict from this repo's own replay corpus **does not
transfer** to another pipeline, another repo's issue mix, or another
prompt shape — it is a measurement of this pipeline's actual seats doing
this repo's actual work, not a general claim about either candidate model.

### Inert by design (ADR 0027)

The comparison half — replay runner, judge pass, comparison report — ships
as inert kernel source, the same shape the language-reviewer catalog
already uses: present in every kernel install, documented, zero standing
cost, and it does nothing until an operator deliberately invokes it.
`/sweep`, `/build`, and `/fix` behave identically whether or not this module
has ever been run. Replay batches are operator-initiated only; the module
adds no autonomous or cron arm of its own. Which candidate models and
vendors an operator actually tests, and their API keys, are overlay/operator
configuration, never a kernel default.

## Integration

**Consumes:**

- The existing transcript-based cost producer and its counting rules
  ([ADR 0020](../adr/0020-cost-measurement-reads-session-transcripts.md),
  via [`telemetry.md`](telemetry.md)) — the sole owner of the headline
  dollar figure this module's report reads from, never re-derives.
- The declared per-seat model settings (`$SWEEP_WORKER_MODEL` and its
  siblings) and the setting-registry convention — there is no separate
  model-selection mechanism for live tagging.
- `judge.py`'s rubric/judge lineage and foundation's `workflow-eval.sh`
  spawn/score/emit patterns — **lineage only**: those files are overlay
  assets, absent from a kernel-only install, and this module's replay
  isolation regime is deliberately incompatible with the eval harness's
  shim-based isolation (replay does real, remote reads against this repo's
  own history; the eval harness does not).
- The reviewer-agent charters, as rubric source *text* only — never a
  runtime reviewer-agent call.
- `scripts/quality-gates.sh` as the mechanical outcome scorer for a
  replayed diff.
- This repo's own closed issues and merged PRs as the replay corpus.
- The `claude -p` CLI contract at every spawn site (`CLAUDE_BIN`
  overridable), and the kernel write-guard class for replay-worktree
  isolation.

**Produces:**

- The per-seat attribution stream, joinable with the rest of the raw
  telemetry lake ([`telemetry.md`](telemetry.md)) by the same session-id
  join key every other stream uses.
- Scored replay records, comparison reports, and (for any non-default-provider
  send) an append-only disclosure log entry ([ADR
  0028](../adr/0028-provider-exposure-rides-a-committed-allowlist-and-disclosure-log.md)).
- A provider allowlist file the report and the disclosure-log validator both
  read — repo-scoped, committed, default Anthropic-only.

No existing command's default behavior changes by this module existing.
`/sweep`, `/build`, and `/fix` gain no new prompts, gates, or spend from a
bare checkout that never runs a replay or points `$SWEEP_WORKER_MODEL` at a
candidate.

## Resource impact

Running nothing costs nothing: a checkout that never invokes the comparison
half pays zero standing resource cost beyond the source files themselves
(ADR 0027). Two paths do carry real cost once an operator opts in:

- **Attribution emission** — one local file append per spawned seat per run,
  the same shape and the same negligible cost as every other stream in
  [`telemetry.md`](telemetry.md). No network call.
- **Replay and judge runs** — these make **real model API calls** under the
  candidate model (and the judge model), so they spend real tokens and real
  dollars, exactly like any other model invocation. This spend is bounded on
  two sides: the pre-flight estimate (see "Replay runner" above) shows the
  expected cost before a batch runs, and every comparison run enforces a
  config-named **per-comparison token/cost ceiling**, routed through the
  existing quota gate — a run that would exceed the ceiling stops at
  pre-flight rather than partway through.

The disclosure log and the provider allowlist are both local, append-only
files with no network cost of their own; only the model calls they gate
carry real spend.

## Telemetry

**Emit coverage is structurally partial — by design, not by omission.**
The L0 usage-capture-feasibility spike (temperloop#1246) found that today,
only **3 of the pipeline's 12 spawn seats** can emit a token-bearing
attribution record (three more become emit-feasible with a one-flag
change; the remainder cannot, as things stand). The reason is structural:
the seat's **name** and the spawn's **token counts** currently sit on
opposite sides of a boundary with no join key between them.
`build-level.mjs`, for instance, passes a per-seat label into every
`agent()` call, but the harness drops that label rather than threading it
through to the result — the run journal does carry usage figures, but the
`.mjs` caller that knows the seat name never sees them. A comparison
report's emit-coverage percentage is therefore expected to read below
100%; that is not itself a defect to chase to zero, it is an honest
denominator this module states outright rather than silently rounding up.
The full seat-by-seat inventory and mechanism is recorded in the operator's
knowledge store as `Context/temperloop - per-seat usage capture
feasibility.md` (not part of this repo's tracked tree).

**What the attribution telemetry collects, in plain terms.** This is
written to be readable by a teammate or a client's reviewer opening this
file cold, with no other context:

- **What is collected:** for each pipeline seat that spawns (a `/sweep` or
  `/fix` worker, a `/build` item worker, a machinery or drive-tier call,
  and so on), one record per run naming which seat it was, which model and
  provider ran it, how many input and output tokens it used, how long it
  took, and which issue or PR it was working on.
- **Where it lands:** a repo-local, gitignored file on the machine that ran
  the work — the same raw-lake convention every other stream in
  [`telemetry.md`](telemetry.md) uses. Nothing here is transmitted off that
  machine by this module itself. A send to a **non-default model
  provider** additionally appends one line to a separate, repo-local
  disclosure log — provider name, an item reference, and a timestamp, never
  content — so a teammate or a client's reviewer can audit which vendors
  ever saw this repo's work, without needing to trust anyone's memory of it
  ([ADR 0028](../adr/0028-provider-exposure-rides-a-committed-allowlist-and-disclosure-log.md)).
- **What it never contains:** no source code, no prompt text, no model
  output, no issue or PR body text. The record is metadata about a spend
  event (who, what model, how much, how long, which reference number) —
  never the content of the work itself.

**Correctness checks.** Attribution records are schema-validated at content
level (model/provider enums, field shapes) by a paired emit-site validator,
the same emit/validate pairing convention every other telemetry stream in
this repo follows — a spawn site missing its emission, or emitting a
malformed record, fails the gate rather than silently under-counting.
