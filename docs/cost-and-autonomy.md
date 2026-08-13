---
title: Cost & autonomy — what running temperloop costs, and what it does on its own
---

# Cost & autonomy — what running temperloop costs, and what it does on its own

Answer these two questions *before* running anything, not after: **what does
this spend of my own money**, and **what will it do without asking me
first**. This page is linked from the first step of the quickstart on
purpose — read the TL;DR now; the Details section has the figures,
derivations, and provenance for every claim.

## TL;DR

- **⚠️ The on-ramp has no tool-enforced dollar ceiling.** The quickstart
  (testbed → first epic → promote → adopt) evaluates temperloop by running
  the **real** pipeline. `temperloop testbed` and `temperloop init` spend
  **$0** — verified: neither invokes `claude` anywhere — so the billable
  surface begins at `/assess` → `/build` on the first epic. Those run
  inside your own **interactive** Claude Code session, which gives the CLI
  nothing to attach a budget cap to. The first epic is a fixed, small,
  kernel-shipped epic — not open-ended work — but **no measured figure for
  what it costs a stranger exists yet** (a real measured run is tracked in
  temperloop#1352, measure the first epic's cost on a fresh testbed). Watch
  your own Claude Code usage view while evaluating.
- **One command carries a hard USD cap.** `temperloop configure` is capped
  at **$0.25**/call, enforced by the tool. It is the only such cap.
- **Past onboarding, there is no dollar ceiling by default.** Ordinary
  interactive work (`/triage`, `/assess`, `/build`, `/sweep`) and the
  unattended pipeline driver have no fixed cost or cap — your own Claude
  usage view is the source of truth. The only built-in throttle is a
  **usage-quota** gate (pauses when your plan's 5-hour rolling window runs
  low), not a dollar one.
- **On a Claude subscription plan (Max and similar), think in tokens, not
  dollars** — a run draws down plan usage rather than billing your card,
  and token counts don't change with model choice (see § On a subscription
  plan).
- **The overhead is designed to pay for itself in avoided rework** — the
  planning, gating, and decision capture spend cheap tokens up front to
  avoid the expensive rebuild later (§ Why the overhead is supposed to
  save money for the argument, stated as design rationale, not measured
  ROI).
- **Autonomy is off by default.** The unattended tiers don't run until you
  flip them on. Once on: the safe tier is structurally incapable of merging
  code; the merge tier can auto-merge only a clean, disjoint, low-risk
  change set after a timed window — a structurally risky set **always**
  waits for a human.
- **Maintenance is a small, roughly fixed floor** — on the order of ~0.5M
  tokens/day for nightly `/tidy` plus daily `/check-in`; pipeline ticks
  that drive nothing cost ≈$0 of Claude. On-demand `/build`/`/sweep` work
  scales with what you actually ask for.

## Details

### Cost at a glance

Every figure here is **directional**, not a quote — hand-derived once from
real usage (per-tier provenance below). Read it as an order-of-magnitude
guide, not a bill.

Tokens are the model-independent column: the same workload is roughly the
same token count on either model (Opus 4.8 and Sonnet 5 share a tokenizer
family). Dollars scale by a flat **~1.67×** from Sonnet to Opus — Opus 4.8
lists at $5/$25 per million input/output tokens versus Sonnet 5's $3/$15.
**If you're running Opus (the Claude Code default), the middle dollar
column is not your cost — the right-hand one is.**

| What you run | Tokens (directional) | Cost @ Sonnet 5 | Cost @ Opus 4.8 | Hard USD cap |
|---|---|---|---|---|
| `temperloop testbed` + `init` (duplicate, issue copy, config bootstrap, proposal PR) | 0 Claude | **$0** | **$0** | n/a (no model call) |
| First epic via `/assess` → `/build` (fixed 5-item/3-level epic ¶) | not yet measured ¶ | not yet measured ¶ | not yet measured ¶ | **none — nothing to attach one to** ⚠️ |
| `configure` — per config value judged | up to ~83K † | ≤ $0.25 | ≤ $0.25 † | **$0.25/call** ✅ |
| `/tidy` — nightly drain | 0.3–0.5M | ~$1.48 | ~$2.47 | none |
| `/check-in` — daily review | ~0.1–0.3M ‡ | ~$0.30–$0.90 ‡ | ~$0.50–$1.50 ‡ | none |
| Pipeline tick — **idle** (drives nothing) | ~0 Claude | **~$0** | **~$0** | per-tick item cap |
| Pipeline tick — **driving** | scales w/ actions | proportional | ~1.67× the Sonnet cost | per-tick item cap |
| `/triage` · `/assess` · `/build` · `/sweep` | scales w/ the work | no fixed figure | no fixed figure | none by default |

✅ = a hard USD cap **enforced by the tool**, not printed advice. The cap
is in dollars, so it doesn't change with model — but at Opus rates a given
dollar cap buys ~1.67× fewer tokens of work before it binds.

† `configure` is **cap-bound**, not workload-bound: judging one config
value is a small call, and the $0.25 cap is the ceiling on either model.
The ~83K-token figure is what $0.25 buys at Sonnet 5 list price; at
Opus 4.8 the same cap is ≈50K tokens.

‡ `/check-in` has **no logged per-run figure** — this is a rough estimate
(an interactive session that reads and reviews the check-in surfaces,
lighter than a full `/tidy` drain). An order of magnitude, not an
observation.

¶ The first epic is **not** open-ended work — it's a fixed, kernel-shipped
5-item / 3-level epic (`claude/templates/first-epic-setup.md`, ADR 0010),
four of whose five items are verdict-only spikes with no code worker and no
PR. Despite that fixed shape, no source in this repo's telemetry yet
measures what running it costs a stranger on a fresh testbed — every
candidate source was checked and each was either too thin or measured the
wrong population (an operator's own established checkout, never a fresh
testbed run). Rather than publish an extrapolated number that would read as
a measurement, this page states that finding plainly: **there is currently
no data to support a band**; a real measured run is tracked in
temperloop#1352. There is also no *tool-enforced* dollar ceiling on this
step, and structurally can't be yet: `--max-budget-usd` only caps a
**headless** `claude -p` call (the mechanism behind the capped `configure`
row), and `/assess`/`/build` run inside your own interactive session.

### What running temperloop costs

Every dollar below is billed to **your own** Claude account, the same way
any Claude Code session is. temperloop has no billing of its own, collects
no payment, and runs no hosted service — it's a `claude -p` invocation (for
the automated tiers) or your own interactive Claude Code session (for
everything else), against your own API or subscription usage.

**Why figures are stated at both Sonnet 5 and Opus 4.8.** The source
figures are directional USD bands, hand-derived once from real operator
usage without pinning a model. Converting a dollar band to tokens requires
dividing by *some* model's price; the mid-tier reference used here is
**Claude Sonnet 5** list price ($3.00/$15.00 per million input/output
tokens — a lower introductory rate applies through 2026-08-31; the durable
sticker price is used so the conversion doesn't go stale). Most people run
**Claude Opus 4.8** (the Claude Code default) at $5.00/$25.00 — so a run
that costs $X at the Sonnet-5 basis costs roughly **~1.67 × $X** on
Opus 4.8. The model choice does not change the token band, only the dollar
conversion; the table carries both columns so you don't do the
multiplication yourself.

**Tier 1 — the capped command.** The AI-guided `configure` wizard is
hard-capped at **$0.25** per call — capped precisely because a stranger may
run it before deciding whether to trust anything here. (Two earlier
commands in this tier, `try` and `try --demo`, were retired along with
their caps when the testbed on-ramp replaced them.)

That leaves a gap worth stating plainly rather than papering over: the
current evaluation path — the testbed, then the first epic through
`/assess` → `/build` — is **Tier 2 work with no tool-enforced dollar
ceiling**, and structurally can't have one yet, because it's interactive
rather than a capped headless call (see the TL;DR and table footnote ¶).

**Tier 2 — ordinary interactive use** (`/triage`, `/assess`, `/build`,
`/sweep`, run with you at the keyboard). No fixed number, and this page
won't invent one — cost scales with how big the issue is, how much context
an item needs, and which model you run. Every one of these is an ordinary
Claude Code session, so your own usage view tells you exactly what it
spent. For a sense of scale: the capped `configure` call (≈83K tokens at
the Sonnet basis) is the cheap end; a full `/build` level driving several
PRs through CI is materially more, bounded only by how much work you asked
for.

**Tier 3 — unattended** (the autonomous pipeline driver, nightly `/tidy`,
any `claude -p` cron invocation). These run without you watching, so
they're the tier most worth a real number. One concrete data point: a real
headless `/tidy` nightly drain was hand-observed at **$1.48** for that one
run (≈0.3–0.5M tokens, mostly input, at the Sonnet basis; ≈$2.47 at Opus
rates). This repo doesn't yet emit a per-run dollar log a reader could
check (the telemetry tracks *events*, not spend), so treat it as a real
but single data point, not a guaranteed average. The pipeline driver adds
per-tick spend proportional to the actions handed over that tick, bounded
by the per-tick item caps — and a tick that drives nothing costs
essentially nothing (§ Maintenance vs. on-demand below).

### On a subscription plan (Claude Max and similar)

If you're on a subscription plan instead of pay-as-you-go API billing, a
run doesn't charge your card — it draws down your plan's usage allowance
like any other Claude Code session. Tokens are then the unit that matches
what a run actually consumes, and they don't change with model choice.

Two things carry over unchanged for a plan user:

- **The same directional bands apply** — the workload doesn't change, only
  how it's paid for.
- **The 5-hour usage-quota gate is the plan-side backstop.**
  `BUILD_QUOTA_PAUSE_PCT` exists specifically to pause a run before it
  exhausts your plan's rolling 5-hour window and auto-resume after it
  resets — built-in protection against a run cutting you off mid-task, no
  extra configuration needed.

### Why the overhead is supposed to save money

temperloop is not free to run — the planning passes, gates, decision
capture, and verification all spend tokens a "just tell Claude to fix it"
workflow wouldn't. The claim isn't that it spends *less*; it's that it
spends *cheap* tokens up front to avoid the *expensive* ones later. (For
the concrete levers that keep spend down, see
[`token-spend.md`](token-spend.md).) The argument, lever by lever — stated
as design rationale, since this repo doesn't yet log measured ROI:

- **Catching a wrong turn in planning is orders of magnitude cheaper than
  catching it after a merge.** The plan-first defaults spend a few thousand
  tokens surfacing a misread requirement *before* code is written. The same
  misread discovered after a `/build` level has driven several PRs through
  CI costs the entire build — implementation, review, CI minutes — spent
  twice.
- **Contract-scoped decomposition lowers the cost of change.** Fixing the
  *seam* (what a sub-issue produces and consumes, not how) means a
  mid-course discovery reworks one unit, not the whole epic — and fixed
  seams are what let a level run in parallel and merge as a batch.
- **Verification and gates stop defects before they compound.** A defect
  caught at the merge gate is fixed against a small, fresh diff; the same
  defect merged to `main` is fixed later against a larger, staler surface,
  after other work has been built on top of it.
- **Captured decisions stop you re-buying the same context.** Every session
  that re-derives why a thing is the way it is pays for that in input
  tokens. Decisions written down once are recalled, not re-derived.
- **Alignment with original intent is the whole point.** The most expensive
  failure mode in any AI-assisted pipeline is confidently shipping the
  wrong thing — paying to build it, discover it's wrong, and build it
  again. The tracking-and-gating overhead exists to make that failure rare.

The honest caveat: these are the *mechanisms* by which the overhead is
meant to pay off, argued from how the pipeline is built — not a measured
return. This repo doesn't yet log the rework it prevents.

### Maintenance vs. on-demand build spend — how much is upkeep?

Of everything above, how much is **maintenance** — the recurring background
commands — versus **on-demand build work** that scales with what you ask
for?

What's actually measurable, checked directly for this page: this repo's own
telemetry does not log dollar spend for any command, so no real percentage
split can be computed. The directional read from the grounded per-run
figures that do exist:

- **Nightly `/tidy`** is the one grounded recurring figure: ≈$1.48/night at
  the Sonnet basis (≈$2.47 at Opus; ≈0.3–0.5M tokens). It recurs every
  night whether or not anything got built that day.
- **Daily `/check-in`** has no logged figure; a rough estimate is ~0.1–0.3M
  tokens (~$0.30–$0.90 Sonnet, ~$0.50–$1.50 Opus).
- **Pipeline ticks cost ≈$0 of Claude when they drive nothing.** A tick's
  decision layer is deterministic shell — the schedule gate makes zero
  network calls, and the tick plan is computed with `jq` over board state.
  A headless `claude -p` driver is spawned **only** when the tick has
  drive-ready work, and its spend is bounded by the per-tick item caps
  (`PIPELINE_DRIVE_CAP` / `PIPELINE_DRIVE_MERGE_CAP`, default 1 each). So
  running the driver 12× a day on an idle backlog costs approximately
  nothing.

The honest version of the ratio: with one grounded recurring figure and no
logged total build spend as the other side of the fraction, this page can't
state "maintenance is X% of spend" without fabricating the denominator.
Qualitatively: the maintenance floor lands on the order of **~0.5M
tokens/day** and is roughly fixed; on-demand `/build`/`/sweep` spend scales
with what you ask for. A week with several PRs through CI has maintenance
as a small sliver; an idle week has it as nearly all of that week's spend,
simply because there's nothing else.

### Is a budget cap on by default?

Split answer, and this is the fact to know before you run anything:

- **Yes, for `temperloop configure`.** Its $0.25 per-call cap is baked into
  the tool — not a flag you have to discover, not something you can
  silently exceed. Deliberate: a curious stranger's first commands
  shouldn't require reading a budget flag to be protected.
- **No, for everything else, by default.** Ordinary interactive pipeline
  work and the unattended driver ship **no dollar ceiling**. The only
  built-in throttle is the **5-hour usage-quota gate**
  (`BUILD_QUOTA_PAUSE_PCT` in
  [`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh)) —
  it pauses a run when your Claude plan's rolling usage window runs low and
  auto-resumes after reset. That's a usage protection, not a dollar one: it
  stops you from getting cut off mid-run, not from spending money. If you
  want an actual USD ceiling on ongoing or unattended usage, set one
  yourself (your Anthropic Console spend limit, or your own wrapper around
  `claude`).

### Autonomy: what it may do without asking, and what always blocks

The unattended tiers (`PIPELINE_DRIVE`, `PIPELINE_DRIVE_MERGE` in
[`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh))
are **both off by default** on a fresh install — nothing runs unattended
until you flip them on yourself. Once you do:

- **What it may do on its own.** The safe tier can route a decomposed epic
  to its approval gate, apply an already-answered decision, clear an
  already-cleared clarification label, and drive a read-only spike to a
  verdict — all **structurally incapable of opening a PR or merging code**,
  enforced two independent ways (the actions it's handed never include a
  merge, and its own instructions forbid one). The merge tier (a separate
  opt-in, only reachable when the safe tier is also on) drives code changes
  through the *same* gated build path a human would use. A **clean,
  disjoint, low-risk change set auto-merges after a timed window**
  (`BUILD_MERGE_GATE_WINDOW`) if nobody objects — the walk-away case, where
  silence really does mean consent. Filing issues, opening PRs, and posting
  the driver's own status are ordinary, expected actions for these tiers.
- **What always blocks for a human.** A **structurally risky** merge set —
  anything that isn't cleanly disjoint and low-risk — is **always modal**
  and never auto-merged on a timeout, no matter how long the window is
  open. A design fork, a claim conflict, or any decision with no safe
  default parks and waits; an absent or timed-out operator is *not*
  approval. And any write to an external system beyond this repo's own
  tracker — most concretely, a feedback/report submission that would leave
  your machine — requires explicit consent and a preview step; nothing
  repo-derived transmits silently, unattended or not.

The settings above are named symbolically on purpose — check
[`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh)
for current defaults; never trust a hardcoded number in prose, since a
setting's value can change without this page being touched.

### The merge gate is free on any repo — and its CI cost

The full merge-gated pipeline runs on **any** repo — free org or personal
account included — with no paid GitHub plan. GitHub's *native* merge queue
is a paid, organization-only feature, but temperloop doesn't require it: it
ships a **managed merge queue** that replicates the native queue's
re-validate-then-land semantics with existing primitives
([`docs/managed-merge-queue.md`](managed-merge-queue.md)).

The one price of that universality is **CI minutes**. Every PR through the
gate runs the required `checks` job at least once; on a repo without the
native queue, the managed backend re-tests each PR against current tip,
which is one extra CI run per PR compared to a native-queue merge. On a
shared repo those minutes come out of the repo's own GitHub Actions
allotment. (A `temperloop testbed` duplicate lives under your own account,
so its CI runs draw from your account's Actions quota, not the original
repo's.) This is not Claude spend and doesn't show up in your usage view.

### Where to read more

- [`token-spend.md`](token-spend.md) — every lever temperloop uses to
  reduce model spend, and how to see where tokens went.
- [`docs/features/pipeline-driver.md`](features/pipeline-driver.md) — the
  full autonomy-tier mechanics and their resource impact.
- [`docs/features/merge-gate.md`](features/merge-gate.md) — the merge-gate
  CI-cost profile, native vs. managed.
- [`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Merge autonomy
  & consent — the full consent contract behind the autonomy section.

---

*Written by claude-fable-5 on 2026-08-13.*
