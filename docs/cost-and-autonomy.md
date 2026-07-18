---
title: Cost & autonomy — what running temperloop costs, and what it does on its own
---

# Cost & autonomy — what running temperloop costs, and what it does on its own

This page answers the two questions a stranger should be able to answer
*before* running anything, not after: **what does this spend of my own
money**, and **what will it do without asking me first**
(temperloop#426 (cost & autonomy expectations doc)). It's linked from the
very first step of the quickstart (`README.md` § 3, `bin/README.md`) on
purpose — read the TL;DR below before `temperloop try`, not after; the
**Details** section has the full figures, derivations, and provenance for
every claim.

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
- **On a Claude subscription plan (Max and similar), tokens — not
  dollars — are your comparable unit**, since a run draws down plan usage
  rather than billing your card directly. Every dollar figure on this page
  also states its token equivalent for exactly this reason (see § On a
  subscription plan).
- **Autonomy is off by default.** The unattended tiers (`FUNNEL_DRIVE`,
  `FUNNEL_DRIVE_MERGE`) don't run until you flip them on. Once on: a safe
  tier can route/apply/clear/spike but is structurally incapable of
  merging code; a merge tier can auto-merge a clean, disjoint, low-risk
  change set after a timed window, but a structurally risky set is
  **always** a modal human approval — never a timeout.
- **Maintenance (nightly `/tidy`, daily `/check-in`, funnel ticks, board
  reconcile) vs. on-demand build work** doesn't reduce to one clean
  percentage — see § Maintenance vs. on-demand build spend for the honest,
  per-function version and why a single number would be fabricated.
- **Shared team resources** (the GitHub GraphQL budget, CI minutes) are a
  separate, non-Claude cost that a burst of activity from one collaborator
  can affect for everyone else that hour — see § Your spend vs. the team's
  shared resources.

## Details

### What running temperloop costs

Every dollar below is billed to **your own** Claude account, the same way
any Claude Code session is. temperloop has no billing of its own, collects
no payment, and runs no hosted service — it's a `claude -p` invocation (for
the automated tiers) or your own interactive Claude Code session (for
everything else), against your own API/subscription usage.

Every token figure below is derived, never invented: it converts the
dollar figure using **Claude Sonnet 5** (`claude-sonnet-5`) list price —
$3.00 per million input tokens, $15.00 per million output tokens (a lower
$2/$10 introductory rate applies through 2026-08-31; the durable sticker
price is used here so the conversion doesn't go stale in six weeks). This
repo does not pin the `try`/`try --demo`/`configure`/`tidy` calls to one
named model, so Sonnet 5 is a **stated conversion basis**, not a claim
about which model actually produced a given figure — treat every token
count on this page as directional, exactly like the dollar bands they're
derived from.

**Tier 1 — the onboarding steps (`try`, `try --demo`).** These are the only
two commands with a hardcoded, published cost band, because they're the
commands a total stranger runs before deciding whether to trust anything
else here:

- `temperloop try` — a real `claude -p` shadow-triage classification pass
  over your repo's own open issues, invoked with every tool disabled
  (`--tools ""`) so it cannot write anything. Directional band: **$0.02–
  $0.08 per open issue classified** (≈**7,000–27,000 tokens**, mostly
  input, at the list price above), hand-derived once from real operator
  usage (`bin/lib/cost-estimates.conf`), hard-capped at **$1.00** for the
  whole run regardless of issue count or how wrong the estimate turns out
  to be.
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
hard-capped at **$0.25** per invocation (≈**83,000 tokens**, mostly input,
at the list price above). That's the cheap end; a full `/build` level
driving several PRs through CI is materially more, bounded only by how much
work you asked for.

**Tier 3 — unattended (the autonomous funnel driver, nightly `/tidy`, any
`claude -p` cron invocation).** These run without you watching, so they're
the tier most worth having a real number for. One concrete data point: a
real headless `/tidy` invocation — a full nightly drain pass over a
session-stub backlog — was hand-observed at **$1.48** for that one run
(≈**0.3–0.5 million tokens**, mostly input, at the list price above — the
range reflects the same directional uncertainty as the dollar figure). This
repo doesn't yet emit a per-run dollar-cost log a reader could check
themselves (`meta/data/raw/` tracks command/issue/funnel *events*, not
spend — see `meta/data/raw/README.md`), so treat this as a real but
single, unlogged data point, not a guaranteed average — cost scales with
backlog size like any other tier. The autonomous funnel driver
adds its own per-tick spend on top of ordinary interactive use, proportional
to how many actions it was handed that tick (`docs/features/funnel-driver.md`
§ Resource impact) — the per-tick item cap (below) is the direct lever on
how large that can get.

### On a subscription plan (Claude Max and similar)

Everything above is denominated in dollars because that's what a per-token
API biller sees. If you're on a **Claude subscription plan** (Max or
similar) instead of pay-as-you-go API billing, a run doesn't charge your
card directly — it draws down your plan's usage allowance the same way any
other Claude Code session does. Dollars are still the right unit for
comparing against someone else's API spend, but **tokens are the unit that
actually matches what a plan run consumes** — which is why every figure
above states both.

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

### Maintenance vs. on-demand build spend — how much is upkeep?

A natural follow-up: of everything above, how much is **maintenance** — the
recurring background/ritual commands (nightly `/tidy`, daily `/check-in`,
funnel ticks, board reconcile-type sweeps) — as opposed to **on-demand
build work** that scales with what you actually ask `/build`/`/sweep` to
do?

**What's actually measurable, checked directly for this page:** this
repo's own telemetry (`meta/data/raw/`) does not log dollar spend for any
command. On a fresh checkout, the `command-runs` and `funnel` streams have
no files at all yet (nothing has emitted them on this host); `issue-touches`
has records, but they carry counts and timestamps, not cost. There is no
logged data here — or, by construction, on any bare checkout — that could
support computing a real percentage split. What follows is a directional
read built from the few grounded per-run figures that do exist, not a
measured ratio:

- **Nightly `/tidy`** is the one grounded recurring figure: **≈$1.48/night**
  (≈0.3–0.5M tokens, same hand-observed single data point as Tier 3 above).
  This recurs every night regardless of whether anything got built that day.
- **Funnel ticks** (rungs 5b/5c) have no logged per-tick dollar figure.
  What's structurally known instead: each tick is capped at
  `FUNNEL_DRIVE_CAP` (default 1) safe-tier item plus `FUNNEL_DRIVE_MERGE_CAP`
  (default 1) merge-tier item, so blast radius per tick is bounded
  regardless of backlog size. The `try` per-issue classification band
  above is **not** a valid stand-in for a funnel tick's cost — driving an
  item (judging and applying a change) is a heavier task than classifying
  one, and borrowing that band would misattribute cost rather than ground
  it. Funnel-tick spend is capped, not quantified.
- **Daily `/check-in`** is an ordinary interactive Tier-2 session — same
  "no fixed number, check your own usage view" status as `/triage`/
  `/assess`/`/build`/`/sweep` above.
- **Board reconcile-type sweeps** are plain `gh`/GraphQL calls with no LLM
  invocation at all — effectively **zero** marginal Claude spend, bounded
  instead by the shared GraphQL budget (§ below), not by anything in this
  section.

**The honest version of the ratio:** with one grounded recurring dollar
figure (~$1.48/night) and no logged total build spend to use as the other
side of the fraction, this page cannot state "maintenance is X% of spend"
without fabricating the denominator. What's true qualitatively instead:
nightly `/tidy` is a small, roughly fixed cost that recurs whether or not
you build anything that day; on-demand `/build`/`/sweep` spend scales with
how much you actually ask for. A week with several PRs through CI will have
maintenance as a small sliver of total spend; an idle week with no build
activity will have that night's `/tidy` run as close to 100% of the week's
Claude spend, simply because there's nothing else to spend on.

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
  (`BUILD_QUOTA_PAUSE_PCT` in `workflows/scripts/build/build.config.sh`,
  see `docs/features/build-spine.md`) — it pauses a run when your Claude
  plan's own rolling 5-hour usage window is running low, and auto-resumes
  after it resets. That's a **usage-quota** protection, not a **dollar**
  one — it stops you from getting cut off mid-run, not from spending money.
  If you want an actual USD ceiling on ongoing or unattended usage, set one
  yourself (your Anthropic Console spend limit, or your own wrapper around
  `claude`) — it's opt-in, not something this repo turns on for you.

### Autonomy: what it may do without asking, and what always blocks

The unattended tiers (`FUNNEL_DRIVE`, `FUNNEL_DRIVE_MERGE` in
`workflows/scripts/build/build.config.sh`) are **both off by default** on a
fresh install — nothing runs unattended until you flip them on yourself.
Once you do:

- **What it may do on its own.** A "safe tier" (rung 5b — see
  `docs/features/funnel-driver.md`) can route a decomposed epic to its
  approval gate, apply an already-answered decision, clear an
  already-cleared clarification label, and drive a read-only spike to a
  verdict — all **structurally incapable of opening a PR or merging code**,
  enforced two independent ways (the actions it's handed never include a
  merge, and its own instructions forbid one). A separate "merge tier"
  (rung 5c, gated by `FUNNEL_DRIVE_MERGE` and only reachable when the safe
  tier is also on) drives code changes through the *same* gated build path
  a human would use — including its merge gate. A **clean, disjoint,
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
  approval for one of these (`claude/CLAUDE.kernel.md` § Merge autonomy &
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
`workflows/scripts/build/build.config.sh` for current defaults; never trust
a hardcoded number in prose, since a knob's value can change without this
page being touched.

### Your spend vs. the team's shared resources

If you're the only person touching a repo, everything above is the whole
story: it's your account, your usage, your call. On a **shared team repo**,
two more things are worth knowing, because they aren't "your" spend in the
same sense — they're a resource every collaborator using this tooling draws
from together:

- **GitHub's GraphQL budget is shared, not per-user.** Every Projects-v2
  board read (claim, status move, worklist) draws against a **5,000-points/
  hour budget shared by every process on the account** — not a per-session
  or per-user allowance (`docs/features/board-adapter.md`). The board
  adapter caches aggressively specifically because a naive implementation
  re-fetching board structure on every call has, in practice, been the
  dominant drain — over half of all GraphQL spend on some accounts before
  the cache split landed. This means a burst of uncached board activity
  from one collaborator can degrade board operations for everyone else on
  the same repo that hour, independent of anyone's individual Claude spend.
- **CI minutes are the repo's, not yours personally.** Every PR through the
  merge-gated pipeline runs the required `checks` job at least once, plus
  whatever the merge queue (native or managed) re-runs before landing — on
  a repo without a native merge queue, a managed-backend merge costs **one
  extra CI run per PR** compared to a native queue merge, the price of
  replicating queue re-validation by hand (`docs/features/merge-gate.md`).
  On GitHub's free tier this comes out of the repo's own shared Actions
  minutes allotment, not an individual contributor's.

Neither of these is Claude spend, and neither shows up in your own account's
usage view — they're the shared-infrastructure side of running this
tooling on a repo other people also use.

### Where to read more

- `docs/features/funnel-driver.md` — the full autonomy-tier mechanics
  (rungs 5a/5b/5c) and their resource impact.
- `docs/features/build-spine.md` — the 5-hour quota gate in full.
- `docs/features/board-adapter.md` — the shared GraphQL budget and the
  cache split that protects it.
- `docs/features/merge-gate.md` — the merge-gate CI-cost profile, native vs.
  managed.
- `claude/CLAUDE.kernel.md` § Merge autonomy & consent — the full consent
  contract behind the autonomy section above.
- `bin/lib/cost-estimates.conf` — the source of the `try` / `try --demo`
  cost bands, including their own provenance note.
