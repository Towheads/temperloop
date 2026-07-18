---
title: Cost & autonomy — what running temperloop costs, and what it does on its own
---

# Cost & autonomy — what running temperloop costs, and what it does on its own

This page answers the two questions a stranger should be able to answer
*before* running anything, not after: **what does this spend of my own
money**, and **what will it do without asking me first**
(temperloop#426 (cost & autonomy expectations doc)). It's linked from the
very first step of the quickstart ([`README.md` § 3](../README.md),
[`bin/README.md`](../bin/README.md)) on purpose — read the TL;DR below
before `temperloop try`, not after; the **Details** section has the full
figures, derivations, and provenance for every claim.

## TL;DR

- **Onboarding (`try` / `try --demo`) is capped, always.** `try` is capped
  at **$1.00**/run (directional band **$0.02–$0.08 per issue**, ≈7,000–
  27,000 tokens); `try --demo` is capped at **$2.00**/tick (directional band
  **$0.05–$0.40**, ≈9,000–74,000 tokens). Both caps are enforced by the tool
  itself, not just printed advice.
- **Past onboarding, there is no dollar ceiling by default.** Ordinary
  interactive work (`/triage`, `/assess`, `/build`, `/sweep`) and the
  unattended funnel driver have no fixed cost or cap — your own Claude Code
  usage view is the source of truth. The only built-in throttle is a
  **usage-quota** gate (pauses when your plan's 5-hour rolling window runs
  low), not a **dollar** one.
- **See the numbers at a glance** in the § Cost at a glance table below —
  every activity, its token band, and its dollar cost at both **Sonnet 5**
  and **Opus 4.8** list price.
- **On a Claude subscription plan (Max and similar), tokens — not
  dollars — are your comparable unit**, since a run draws down plan usage
  rather than billing your card directly. Tokens are also **model-
  independent**, which is why this page leads with them (see § On a
  subscription plan).
- **The overhead pays for itself in avoided rework.** The planning, gating,
  and decision-capture that temperloop adds are *designed* to make the
  expensive mistakes cheaper — see § Why the overhead is supposed to save
  money for the cost/benefit argument.
- **Autonomy is off by default.** The unattended tiers (`FUNNEL_DRIVE`,
  `FUNNEL_DRIVE_MERGE`) don't run until you flip them on. Once on: a safe
  tier can route/apply/clear/spike but is structurally incapable of
  merging code; a merge tier can auto-merge a clean, disjoint, low-risk
  change set after a timed window, but a structurally risky set is
  **always** a modal human approval — never a timeout.
- **Maintenance is a small, roughly fixed floor — on the order of ~0.5M
  tokens/day.** Nightly `/tidy`, daily `/check-in`, and the funnel ticks
  (which cost **≈$0 of Claude when they drive nothing**) are the recurring
  "keep-the-lights-on" spend; on-demand `/build`/`/sweep` work scales with
  what you actually ask for — see § Maintenance vs. on-demand build spend.

## Details

### Cost at a glance

Every figure here is **directional**, not a quote — hand-derived once from
real usage (see the per-tier notes below for provenance). Read it as an
order-of-magnitude guide, not a bill.

Tokens are the model-independent column: the same workload is roughly the
same token count on either model (Opus 4.8 and Sonnet 5 share a tokenizer
family). Dollars scale by a flat **~1.67×** from Sonnet to Opus — Opus 4.8
lists at $5/$25 per million input/output tokens versus Sonnet 5's $3/$15,
the same 5/3 ratio on both. **If you're running Opus (the Claude Code
default), the middle dollar column is not your cost — the right-hand one
is.**

| What you run | Tokens (directional) | Cost @ Sonnet 5 | Cost @ Opus 4.8 | Hard USD cap |
|---|---|---|---|---|
| `try` — per open issue classified | 7K–27K | $0.02–$0.08 | $0.03–$0.13 | **$1.00/run** ✅ |
| `try --demo` — per issue→PR tick | 9K–74K | $0.05–$0.40 | $0.08–$0.67 | **$2.00/tick** ✅ (flag) |
| `configure` — per config value judged | up to ~83K † | ≤ $0.25 | ≤ $0.25 † | **$0.25/call** ✅ |
| `/tidy` — nightly drain | 0.3–0.5M | ~$1.48 | ~$2.47 | none |
| `/check-in` — daily ritual | ~0.1–0.3M ‡ | ~$0.30–$0.90 ‡ | ~$0.50–$1.50 ‡ | none |
| Funnel tick — **idle** (drives nothing) | ~0 Claude | **~$0** | **~$0** | per-tick item cap |
| Funnel tick — **driving** | scales w/ actions | proportional | ~1.67× the Sonnet cost | per-tick item cap |
| `/triage` · `/assess` · `/build` · `/sweep` | scales w/ the work | no fixed figure | no fixed figure | none by default |

✅ = a hard USD cap **enforced by the tool**, not printed advice. The cap is
in **dollars**, so it does not change with model — but at Opus rates a given
dollar cap buys ~1.67× fewer tokens of work before it binds.

† `configure` is **cap-bound**, not workload-bound: judging one config value
is a small call, and the $0.25 USD cap is the ceiling on either model. The
~83K-token figure is what $0.25 buys at Sonnet 5 list price; at Opus 4.8 the
same $0.25 cap is ≈50K tokens.

‡ `/check-in` has **no logged per-run figure** — this is a rough estimate
(a Tier-2 interactive session that reads and reviews the vault/rollup
surfaces, lighter than a full `/tidy` drain, heavier than a single
classification). Treat it as an order of magnitude, not an observation.

### What running temperloop costs

Every dollar below is billed to **your own** Claude account, the same way
any Claude Code session is. temperloop has no billing of its own, collects
no payment, and runs no hosted service — it's a `claude -p` invocation (for
the automated tiers) or your own interactive Claude Code session (for
everything else), against your own API/subscription usage.

**Why the dollar figures are stated at both Sonnet 5 and Opus 4.8.** The
source figures are directional **USD** bands, hand-derived once from real
operator usage ([`bin/lib/cost-estimates.conf`](../bin/lib/cost-estimates.conf)),
derived at list price without pinning a particular model — this repo does
not pin the `try`/`try --demo`/`configure`/`tidy` calls to one named model.
To turn a dollar band into a token band you have to divide by *some* model's
price, and the natural mid-tier reference is **Claude Sonnet 5**
(`claude-sonnet-5`) list price — $3.00 per million input tokens, $15.00 per
million output tokens (a lower $2/$10 introductory rate applies through
2026-08-31; the durable sticker price is used here so the conversion doesn't
go stale in six weeks). That is why the Sonnet-5 dollar column reproduces
the raw bands exactly.

But most people run temperloop on **Claude Opus 4.8** (`claude-opus-4-8`),
the Claude Code default, which lists at **$5.00 / $25.00** per million
input/output tokens — the same 5/3 ratio over Sonnet 5 on both. So the
model choice does **not** change the token band (the workload does the same
number of tokens either way — Opus 4.8 and Sonnet 5 share a tokenizer
family), only the dollar conversion: **a run that costs $X at the Sonnet-5
basis costs roughly ~1.67 × $X on Opus 4.8.** The § Cost at a glance table
carries both columns so you don't have to do that multiplication yourself.
Treat every token count and every dollar band on this page as directional.

**Tier 1 — the onboarding steps (`try`, `try --demo`).** These are the only
two commands with a hardcoded, published cost band, because they're the
commands a total stranger runs before deciding whether to trust anything
else here:

- `temperloop try` — a real `claude -p` shadow-triage classification pass
  over your repo's own open issues, invoked with every tool disabled
  (`--tools ""`) so it cannot write anything. Directional band: **$0.02–
  $0.08 per open issue classified** (≈**7,000–27,000 tokens**, mostly
  input, at the Sonnet-5 basis above), hand-derived once from real operator
  usage ([`bin/lib/cost-estimates.conf`](../bin/lib/cost-estimates.conf)),
  hard-capped at **$1.00** for the whole run (≈**330,000 tokens** if the
  whole cap were spent) regardless of issue count or how wrong the estimate
  turns out to be.
- `temperloop try --demo` — the one mutating exception: one real issue → PR
  tick against a disposable, throwaway demo repo. Directional band:
  **$0.05–$0.40 per tick** (≈**9,000–74,000 tokens**, assuming roughly an
  80/20 input/output token split — this tick reads the whole demo repo but
  also emits a full corrected file, so output is a larger share than the
  classification tier above), same provenance, hard-capped at **$2.00**
  (`--demo-cap-usd`, adjustable via flag; ≈**370,000 tokens** if the whole
  cap were spent).

Both bands are *directional* — hand-derived once from real usage, not a
live pricing-API read, not recalculated at runtime — but they are real
observed figures, not guesses, and the hard USD cap on each is enforced by
the tool itself, not just printed as advice.

**Tier 2 — ordinary interactive use (`/triage`, `/assess`, `/build`,
`/sweep`, run with you at the keyboard).** There is no fixed number here,
and this page won't invent one — cost scales with how big the issue is, how
much context an item needs, and which model you're running. What *is* true:
every one of these is an ordinary Claude Code session, so your own Claude
Code cost tracking (or the Console's usage view) tells you exactly what it
spent, same as any other session you run. For a sense of scale on one
concrete in-repo example: the AI-guided `temperloop configure` wizard — a
single `claude -p` call with no tools, judging one config value — is
hard-capped at **$0.25** per invocation (≈**83,000 tokens** at the Sonnet-5
basis, ≈50,000 at Opus rates, mostly input). That's the cheap end; a full
`/build` level driving several PRs through CI is materially more, bounded
only by how much work you asked for.

**Tier 3 — unattended (the autonomous funnel driver, nightly `/tidy`, any
`claude -p` cron invocation).** These run without you watching, so they're
the tier most worth having a real number for. One concrete data point: a
real headless `/tidy` invocation — a full nightly drain pass over a
session-stub backlog — was hand-observed at **$1.48** for that one run
(≈**0.3–0.5 million tokens**, mostly input, at the Sonnet-5 basis — ≈$2.47
at Opus rates; the range reflects the same directional uncertainty as the
dollar figure). This repo doesn't yet emit a per-run dollar-cost log a
reader could check themselves
([`meta/data/raw/`](../meta/data/raw/README.md) tracks command/issue/funnel
*events*, not spend), so treat this as a real but single, unlogged data
point, not a guaranteed average — cost scales with backlog size like any
other tier. The autonomous funnel driver adds its own per-tick spend on top
of ordinary interactive use, proportional to how many actions it was handed
that tick ([`docs/features/funnel-driver.md`](features/funnel-driver.md)
§ Resource impact) — the per-tick item cap (below) is the direct lever on
how large that can get. A tick that drives **nothing** costs essentially
nothing in Claude spend — see § Maintenance vs. on-demand build spend.

### On a subscription plan (Claude Max and similar)

Everything above is denominated in dollars because that's what a per-token
API biller sees. If you're on a **Claude subscription plan** (Max or
similar) instead of pay-as-you-go API billing, a run doesn't charge your
card directly — it draws down your plan's usage allowance the same way any
other Claude Code session does. Dollars are still the right unit for
comparing against someone else's API spend, but **tokens are the unit that
actually matches what a plan run consumes** — and tokens don't change with
model choice, which is why this page leads with the token column and derives
dollars from it.

Two things carry over unchanged for a plan user:

- **The same directional bands apply.** A `try` run still costs roughly
  7,000–27,000 tokens' worth of usage whether that usage is billed per-token
  or drawn from a plan allowance — the workload doesn't change, only how
  it's paid for.
- **The 5-hour usage-quota gate (§ below) is the plan-side backstop.**
  `BUILD_QUOTA_PAUSE_PCT` already exists specifically to pause a run before
  it exhausts your plan's rolling 5-hour window and auto-resume after it
  resets — this is the built-in protection against a plan run cutting you
  off mid-task, and it requires no extra configuration for a plan user.

### Why the overhead is supposed to save money

temperloop is not free to run — the planning passes, the gates, the
decision capture, and the verification steps all spend tokens that a
"just tell Claude to fix it" workflow wouldn't. The claim isn't that it
spends *less*; it's that it spends the *cheap* tokens up front to avoid the
*expensive* ones later. (For the concrete levers that keep spend down —
model-tier routing, per-tick caps, the quota gate — and what the pipeline
tracks, see [`token-spend.md`](token-spend.md).) The argument, lever by
lever — stated as design rationale, since this repo doesn't yet log measured
ROI:

- **Catching a wrong turn in planning is orders of magnitude cheaper than
  catching it after a merge.** The plan-first / design-first defaults
  (see [`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Plan-first
  default) spend a few thousand tokens surfacing a misread requirement or a
  bad approach *before* any code is written. The same misread, discovered
  after a `/build` level has driven several PRs through CI, costs the entire
  build — implementation, review, CI minutes, and the rework — spent twice.
  Planning tokens are the cheapest tokens in the pipeline; a re-merged epic
  is among the most expensive.
- **Contract-scoped decomposition lowers the cost of change.** Decomposing
  to the *seam* (what a sub-issue produces and consumes, not how) means an
  implementation learning changes the *how* without invalidating the
  contract — so a mid-course discovery reworks one unit, not the whole epic.
  Fixed seams are also what let a level run in parallel and merge as a batch,
  so the coordination cost that usually balloons with team size stays flat.
- **Verification and gates stop defects before they compound.** A defect
  caught by the merge gate or an adversarial review is fixed against a small,
  fresh diff. The same defect merged to `main` is fixed later against a
  larger, staler surface, after other work has been built on top of it —
  a strictly more expensive fix, and one that risks a second round of
  rework in whatever depended on it.
- **Captured decisions and memory stop you re-buying the same context.**
  Every session that has to re-derive why a thing is the way it is pays for
  that context in input tokens. Decisions written to the store once
  (see [`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Decision
  capture) are recalled, not re-derived — turning a recurring per-session
  cost into a one-time write.
- **Alignment with original intent is the whole point.** The funnel keeps a
  unit tied to its issue, its contract, and its verification surface from
  intake to merge, so what lands is what was asked for. The most expensive
  failure mode in any AI-assisted pipeline is confidently shipping the wrong
  thing and paying to build it, discover it's wrong, and build it again;
  the tracking-and-gating overhead exists specifically to make that failure
  rare.

The honest caveat: these are the *mechanisms* by which the overhead is
meant to pay off, argued from how the pipeline is built — not a measured
return. This repo doesn't yet log the rework it prevents, so treat this
section as the design's theory of its own value, in the same directional
spirit as the cost figures above.

### Maintenance vs. on-demand build spend — how much is upkeep?

A natural follow-up: of everything above, how much is **maintenance** — the
recurring background/ritual commands (nightly `/tidy`, daily `/check-in`,
funnel ticks) — as opposed to **on-demand build work** that scales with
what you actually ask `/build`/`/sweep` to do?

**What's actually measurable, checked directly for this page:** this
repo's own telemetry ([`meta/data/raw/`](../meta/data/raw/README.md)) does
not log dollar spend for any command. On a fresh checkout, the
`command-runs` and `funnel` streams have no files at all yet (nothing has
emitted them on this host); `issue-touches` has records, but they carry
counts and timestamps, not cost. There is no logged data here — or, by
construction, on any bare checkout — that could support computing a real
percentage split. What follows is a directional read built from the few
grounded per-run figures that do exist, not a measured ratio:

- **Nightly `/tidy`** is the one grounded recurring figure: **≈$1.48/night**
  at the Sonnet-5 basis (≈$2.47 at Opus rates; ≈0.3–0.5M tokens, same
  hand-observed single data point as Tier 3 above). This recurs every night
  regardless of whether anything got built that day.
- **Daily `/check-in`** is an ordinary interactive Tier-2 session. It has no
  logged per-run figure; a rough estimate is **~0.1–0.3M tokens
  (~$0.30–$0.90 Sonnet, ~$0.50–$1.50 Opus)** — lighter than a full `/tidy`
  drain because it reads and reviews the ritual surfaces rather than
  draining a whole backlog. Treat it as an order of magnitude, not an
  observation.
- **Funnel ticks (rungs 5b/5c) cost ≈$0 of Claude when they drive nothing.**
  This is the key structural fact for anyone running the driver on a
  schedule: a tick's *decision* layer is deterministic shell — the schedule
  gate makes zero network calls, and the tick plan is computed with `jq`
  over board state
  ([`workflows/scripts/build/funnel-tick.sh`](../workflows/scripts/build/funnel-tick.sh)
  emits a plan; it does not invoke `claude -p`). A headless `claude -p`
  driver is spawned **only** when the tick has drive-ready work to hand it
  ([`workflows/scripts/build/funnel-drive.sh`](../workflows/scripts/build/funnel-drive.sh)),
  and its spend is proportional to the actions handed over that tick,
  bounded by the per-tick item caps (`FUNNEL_DRIVE_CAP` /
  `FUNNEL_DRIVE_MERGE_CAP`, default 1 each). So **running the driver 12× a
  day on an idle backlog costs approximately nothing** — the model isn't
  invoked on a wake that drives nothing. (One caveat: a crash-signal intake
  phase runs on every tick, but it is config-gated — with no Sentry
  credential wired up, as on a fresh checkout, it no-ops.) The onboarding
  `try` per-issue band is **not** a valid stand-in for a tick that *does*
  drive: driving an item (judging and applying a change) is a heavier task
  than classifying one.

**The honest version of the ratio:** with one grounded recurring dollar
figure (~$1.48/night, ~$2.47 on Opus) and no logged total build spend to use
as the other side of the fraction, this page cannot state "maintenance is
X% of spend" without fabricating the denominator. What's true qualitatively
instead: the recurring maintenance floor — nightly `/tidy` plus daily
`/check-in`, since idle funnel ticks add ~$0 — lands **on the order of
~0.5M tokens/day**, a small and roughly fixed cost that recurs whether or
not you build anything that day; on-demand `/build`/`/sweep` spend scales
with how much you actually ask for. A week with several PRs through CI will
have maintenance as a small sliver of total spend; an idle week with no
build activity will have that maintenance floor as close to 100% of the
week's Claude spend, simply because there's nothing else to spend on.

### Is a budget cap on by default?

Split answer, and this is the fact to know before you run anything:

- **Yes, always, for the onboarding tier.** `try`'s $1.00 classification
  cap and `try --demo`'s $2.00 tick cap are baked into the tool itself — not
  a flag you have to discover, not something you can silently exceed. This
  is deliberate: a curious stranger's very first command should not require
  reading a budget flag to be protected.
- **No, not for anything past that, by default.** Once you're doing
  ordinary interactive pipeline work, or you opt into the unattended funnel
  driver, there is **no dollar ceiling shipped by default**. The only
  built-in throttle at that point is the **5-hour usage-quota gate**
  (`BUILD_QUOTA_PAUSE_PCT` in
  [`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh),
  see [`docs/features/build-spine.md`](features/build-spine.md)) — it pauses
  a run when your Claude plan's own rolling 5-hour usage window is running
  low, and auto-resumes after it resets. That's a **usage-quota**
  protection, not a **dollar** one — it stops you from getting cut off
  mid-run, not from spending money. If you want an actual USD ceiling on
  ongoing or unattended usage, set one yourself (your Anthropic Console
  spend limit, or your own wrapper around `claude`) — it's opt-in, not
  something this repo turns on for you.

### Autonomy: what it may do without asking, and what always blocks

The unattended tiers (`FUNNEL_DRIVE`, `FUNNEL_DRIVE_MERGE` in
[`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh))
are **both off by default** on a fresh install — nothing runs unattended
until you flip them on yourself. Once you do:

- **What it may do on its own.** A "safe tier" (rung 5b — see
  [`docs/features/funnel-driver.md`](features/funnel-driver.md)) can route a
  decomposed epic to its approval gate, apply an already-answered decision,
  clear an already-cleared clarification label, and drive a read-only spike
  to a verdict — all **structurally incapable of opening a PR or merging
  code**, enforced two independent ways (the actions it's handed never
  include a merge, and its own instructions forbid one). A separate "merge
  tier" (rung 5c, gated by `FUNNEL_DRIVE_MERGE` and only reachable when the
  safe tier is also on) drives code changes through the *same* gated build
  path a human would use — including its merge gate. A **clean, disjoint,
  low-risk change set auto-merges after a timed window**
  (`BUILD_MERGE_GATE_WINDOW`, see `build.config.sh` for the current default)
  if nobody objects — the walk-away case, where silence really does mean
  consent. Filing issues, opening PRs, and posting the driver's own status
  are all in scope for the safe/merge tiers as ordinary, expected actions.
- **What always blocks for a human.** A **structurally risky** merge set —
  anything that isn't cleanly disjoint and low-risk — is **always modal**
  and is never auto-merged on a timeout, no matter how long the window is
  open. A design-fork, a claim conflict, or any decision with no safe
  default parks and waits; an absent or timed-out operator is *not*
  approval for one of these
  ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Merge autonomy &
  consent — read that section for the full contract). Any write to an
  external system beyond this repo's own tracker — most concretely, a
  feedback/report submission that would leave your machine — requires
  explicit consent and a preview step (landing with this release,
  temperloop#428 (consent-gated feedback submit)); nothing repo-derived
  transmits silently, unattended or not.

The knobs above are named symbolically on purpose (`FUNNEL_DRIVE`,
`FUNNEL_DRIVE_MERGE`, `BUILD_MERGE_GATE_WINDOW`, plus the per-tick item caps,
`FUNNEL_DRIVE_CAP` / `FUNNEL_DRIVE_MERGE_CAP`, which bound blast radius
independent of how large the ready backlog is) — check
[`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh)
for current defaults; never trust a hardcoded number in prose, since a
knob's value can change without this page being touched.

### The merge gate is free on any repo — and its CI cost

The full merge-gated pipeline runs on **any** repo — a free organization or a
personal-account repo included — at no extra charge and with no paid GitHub
plan. GitHub's *native* merge queue is a paid, organization-only feature, but
temperloop **does not require it**: it ships a **managed merge queue** that
replicates the native queue's re-validate-then-land semantics with existing
primitives, so the same gate works everywhere
([`docs/managed-merge-queue.md`](managed-merge-queue.md),
[`docs/features/merge-gate.md`](features/merge-gate.md)). The managed queue is
part of the toolkit, not an add-on you pay for.

The one price of that universality is **CI minutes**. Every PR through the gate
runs the required `checks` job at least once; on a repo without the native
queue, the managed backend re-tests each PR against current tip by hand, which
is **one extra CI run per PR** compared to a native-queue merge. On a **shared
repo** those minutes come out of the repo's own GitHub Actions allotment, not
any one contributor's — the shared-infrastructure side of running this on a
repo other people also use. It is not Claude spend and doesn't show up in your
own account's usage view.

### Where to read more

- [`token-spend.md`](token-spend.md) — the operator/contributor companion:
  every lever temperloop uses to reduce model spend (model-tier routing,
  caps, quota gates) and what it tracks, with the exact knobs and files.
- [`docs/features/funnel-driver.md`](features/funnel-driver.md) — the full
  autonomy-tier mechanics (rungs 5a/5b/5c) and their resource impact.
- [`docs/features/build-spine.md`](features/build-spine.md) — the 5-hour
  quota gate in full.
- [`docs/features/merge-gate.md`](features/merge-gate.md) — the merge-gate
  CI-cost profile, native vs. managed.
- [`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Merge autonomy &
  consent — the full consent contract behind the autonomy section above.
- [`bin/lib/cost-estimates.conf`](../bin/lib/cost-estimates.conf) — the
  source of the `try` / `try --demo` cost bands, including their own
  provenance note.
