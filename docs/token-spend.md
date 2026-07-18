---
title: Managing token spend — how temperloop reduces and tracks what it costs
---

# Managing token spend — how temperloop reduces and tracks what it costs

[`cost-and-autonomy.md`](cost-and-autonomy.md) answers *what* a run costs and
*what* it does on its own. This page is the operator/contributor companion:
the concrete ways temperloop is **efficient** with model spend — getting more
useful output per token — and what it **tracks** so you can see where the
tokens go, including the honest gaps in that tracking.

Two framing facts carry over from the cost page:

- **Tokens are the model-independent unit.** The same workload is roughly the
  same token count on either model; dollars scale ~1.67× from Sonnet 5 to
  Opus 4.8. So "efficient" almost always means *do the same work with fewer
  tokens*, or *route those tokens to a cheaper model* — the levers below.
- **Every knob named here has its value in
  [`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh),
  not in this prose.** Defaults are quoted as a directional aid; the config
  file is the source of truth.

> **Efficiency vs. spend ceilings — a deliberate distinction.** Bounding
> *exposure* — the onboarding USD caps (`try`/`try --demo`/`configure`), the
> per-tick item caps, the 5-hour usage-quota gate — is a different thing from
> being *efficient*. A cap stops runaway spend; it doesn't make the work
> cheaper. Those ceilings are documented on the cost page
> ([§ Is a budget cap on by default?](cost-and-autonomy.md#is-a-budget-cap-on-by-default)),
> not here. This page is only about doing the work with fewer tokens.

## How temperloop keeps token spend efficient

Five families of lever. The first four make *building* a given change cheaper —
**shape** the work small, **route** each piece to the cheapest model that fits,
**challenge** it before building, and keep each run's **context** lean. The
fifth makes *every future* change cheaper: capture intent durably so
**maintenance** recalls it instead of re-deriving it — and since maintenance is
most of a codebase's lifetime, that's where temperloop's token cost drops most.

### 1. Break work into small, contract-scoped chunks

The most fundamental lever. Epic-sized work is decomposed up front — via
`/assess` (or `/workshop` for invented work) — into contract-scoped
sub-issues grouped into dependency levels, *before* anything is built
([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Task workflow,
"Decompose epic-sized work up front" and "Decompose to the seam"). A sub-issue
fixes its **contract** — what it *produces*, what it *consumes*, and its
*acceptance check* — and says nothing about *how*. That single discipline pays
off three ways, each of which is a token saving:

- **Less context overhead per unit.** A chunk scoped to its own contract only
  needs *that* contract and its declared dependencies in context — not the
  whole epic. The working set per unit stays small, so the per-unit input-token
  cost stays small. It compounds at the orchestrator too: under `/build`'s
  workflow path, orchestrator context stays pinned to one small object per
  dependency level regardless of how many items the level holds, instead of
  a context that grows with every item ([`claude/commands/build.md`](../claude/commands/build.md)).
- **Better alignment, so less rework.** A fixed contract is a cheap checkpoint:
  a misread requirement is caught at the seam — where the fix is a contract
  edit — instead of after a big-bang implementation is built, reviewed, and
  merged, where the fix is the whole build spent twice. Deciding the seam up
  front, before implementation, is exactly what the plan-first and design-first
  defaults buy (§ Principles below). Shipping the *wrong* thing and paying to
  rebuild it is the single most expensive failure mode; small contracts make
  it rare by forcing agreement on *what* before spending tokens on *how*.
- **Less duplicate work; completed work is reusable.** Contracts are
  **stale-resistant** — an implementation learning changes the *how*, not the
  contract — and **parallelizable** — once the seam is fixed there's no
  coordination between units. So a finished unit is a reusable building block
  the rest of the epic consumes rather than re-derives, and a mid-course
  discovery reworks one unit, not the level. Two concrete reinforcements: a
  worker builds only once every dependency SHA is **merged** (the `dependsOn`
  precondition — no wasted build on a stale base), and decisions captured to
  the knowledge store are recalled later instead of re-derived at input-token
  cost.

### 2. Route each chunk to the cheapest model that fits

Once work is scoped, spend judgment-tier compute only where the judgment is
needed. Mechanical, high-volume, low-reasoning work goes to a cheaper model;
genuinely hard decisions (a merge, a design fork) get the strong one. The
failure this prevents is a fan-out that silently launches every agent on the
top tier for work that never needed it.

- **The funnel splits its driver model by judgment level:**
  `FUNNEL_DRIVE_MODEL` (default `claude-sonnet-5`) drives mechanical actions;
  `FUNNEL_DRIVE_MERGE_MODEL` (default `claude-opus-4-8`) is reserved for the
  high-judgment code/merge tier.
  ([`build.config.sh`](../workflows/scripts/build/build.config.sh)).
- **`/build`'s one-shot executors are pinned to Haiku** — the agents that just
  run a spine command or a read-only merge-state query do no reasoning, so
  they're the cheapest tier; the worker that *does* the build inherits the
  session model (`model: item.model`).
  ([`claude/workflows/build-level.mjs`](../claude/workflows/build-level.mjs)).
- **The standing rule** that each fan-out set its worker's tier *explicitly*
  to the cheapest that fits — rather than defaulting all agents to the
  driver's tier — is [`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md)
  § Subagent usage ("Cost-tier routing"). The two funnel knobs are its worked
  example; review seats are routed the same way (advisory reviewers →
  `sonnet`, locate-and-report fan-outs → `haiku`).

> temperloop routes by **model tier**, not by a separate effort setting —
> there is no effort-tier (`low`/`high`/`xhigh`) knob in the pipeline config
> today. Model-tier selection is how the cost/quality tradeoff is expressed
> here.

### 3. Challenge the work before building it (adversarial review)

Cheap, read-only adversarial passes exist to catch a wrong assumption or an
over-scoped design *before* expensive build tokens are spent on it. A skeptic
that refutes a bad premise costs a fraction of the build that premise would
have produced — and the reviewers themselves run on cheaper tiers, so the
challenge is cheap by construction.

- **Design work faces an adversarial panel.** `/workshop`'s coverage walk runs
  a capability-probed **adversarial lens panel** (`architecture-reviewer`,
  `requirements-auditor`) over the design brief, and folds the findings back
  in, before the epic is materialized ([`claude/commands/workshop.md`](../claude/commands/workshop.md)
  § 3.3). This is where an over-broad scope or an untestable seam gets pulled
  back — while it's still just a brief, not built code.
- **Decomposition premises are verified against reality, not assumed.**
  `/assess`'s Step-3 sanity-check subagents (`requirements-auditor`, plus
  `architecture-reviewer` on boundary changes) judge every decomposition
  premise against **freshly-fetched `origin/main`** — does this file/symbol
  exist, is this already fixed — so a wrong premise doesn't become a wrong
  sub-issue contract that a worker then builds and rebuilds
  ([`claude/commands/assess.md`](../claude/commands/assess.md)). The auditor's
  recurring catch is precisely "referenced a thing that didn't exist yet."
- **Implementation faces per-change reviewers and a verify gate.** `/build`
  Step 3e runs the reviewer matching the change kind (`python-reviewer`,
  `architecture-reviewer`, `docs-reviewer`, `workflow-reviewer`) as a
  read-only pass; blocking findings loop straight back with the feedback as
  context, so a defect is fixed against a small, fresh diff rather than
  discovered later against a large, stale one. The `/verify` gate drives the
  change end-to-end to confirm it actually does what it claims
  ([`claude/commands/build.md`](../claude/commands/build.md)).
- **Every PR ships its own verification surface** so the reviewer confirms
  correctness without re-running anything — verification is part of the
  deliverable, not a later re-investigation
  ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § PR verification
  surface). When a review gate can't run, it degrades **legibly** (a one-line
  `skipped — <agent> unavailable`), so a gate never looks passed when it
  didn't run (§ Legible agent-gate degradation).

### 4. Keep each run's working context small

Within a single run, input tokens dominate and grow with context. These keep
the window from ballooning:

- **Delegate context-polluting work to a subagent.** A broad grep sweep, a
  log trawl, a many-file read runs in a subagent; only the *findings* come
  back to the parent, not the file dumps
  ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Subagent usage).
- **Workers return a compact verdict, not a transcript.** Each `/build`
  worker's final message is a small fenced JSON object; the orchestrator
  reasons over that instead of ingesting the worker's prose
  ([`claude/commands/build.md`](../claude/commands/build.md)).
- **`/tidy` pre-compresses transcripts** to a ~2–3k-token JSON report rather
  than loading the ~18k-token raw transcript
  ([`claude/commands/tidy.md`](../claude/commands/tidy.md)).
- **Poll cadences are tuned to the prompt-cache window** so a wake-up check is
  a cache read, not a cache miss (`ASSESS_POLL_FIRST_WAKE` et al.,
  [`claude/commands/assess.md`](../claude/commands/assess.md)).

### 5. Make the record durable, so maintenance stays cheap

Most of a codebase's lifetime is *maintenance*, not the initial build — and
maintenance is where re-establishing **intent** is normally the expensive part.
A session that has to reconstruct why a feature exists, what its later changes
were reasoning about, and which tradeoffs were deliberately accepted pays for
all of that in input tokens (re-reading code, diffing history) — and risks
getting it wrong, which is rework. temperloop front-loads that capture so a
maintenance session **recalls** the context cheaply instead of reconstructing
it:

- **Feature docs are problem-first.** Each page under
  [`docs/features/`](features/) opens with a `## Problem` section stating *why*
  the feature exists, not just what it does — so the intent behind a subsystem
  is a cheap read, not a code-archaeology exercise. ([`README.md`](../README.md)
  indexes them, "one page per shipped feature.")
- **ADRs capture the architectural calls and their tradeoffs.** Decisions with
  lasting consequences land as immutable records under
  [`docs/adr/`](adr/) (process in [`docs/adr/0000-adr-process.md`](adr/0000-adr-process.md));
  `/workshop` emits a draft ADR for each architectural decision at materialize
  time ([`claude/commands/workshop.md`](../claude/commands/workshop.md) § 5c).
  A maintainer reads the tradeoff that was accepted instead of re-deriving —
  or accidentally re-litigating — it.
- **The epic `## Contract` records the seam durably** on the issue itself —
  what each unit produces, consumes, and accepts — so a later change reasons
  against a stated contract rather than reverse-engineering one from the code.
- **PR verification surfaces stay in the PR body** (§ PR verification surface),
  so *how a change was proven correct* is recoverable from history without
  re-deriving it.
- **Decision and context notes** captured to the knowledge store
  ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Task workflow,
  "Capture at source") record a decided-but-unbuilt direction or a deferred
  design seam, so a later session doesn't re-open a settled question.

The through-line is the same "capture once, recall — don't re-derive"
discipline as the other levers, but it's the one whose payoff *compounds over
the whole life of the code*: every future maintenance touch that would
otherwise re-establish the same context becomes a cheap recall instead.

### Principles behind the levers

The levers above are applications of a handful of standing rules in
[`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md). Each one, read as an
efficiency rule, says "don't spend tokens you don't have to":

- **Decompose to the seam, not the implementation** (§ Task workflow) — fix
  the contract, leave the *how* open; this is what makes chunks small,
  aligned, and reusable (lever 1).
- **Cheapest tier that fits the stage** (§ Subagent usage) — set each agent's
  model explicitly; never default a fan-out to the top tier (lever 2).
- **Plan-first / design-first** (§ Plan-first default, § Design-first default)
  — surface a misread in planning, where the fix is a few thousand tokens, not
  after a merged build.
- **Adversarially verify findings** (§ Subagent usage) — a skeptic refuting a
  plausible-but-wrong finding is cheaper than building on it (lever 3).
- **Trust confirmed state** (§ Trust confirmed state) — don't re-check what
  you already confirmed (no `git status` after your own push, no re-poll of a
  green CI, no re-read of a file you just wrote); every redundant round-trip is
  tokens for nothing.
- **Fetch ground truth before building** (§ Fetch ground truth before
  building) — probe current state before you mutate or build on it; stale
  assumptions cause the most expensive rework.
- **Capture intent once, recall it forever** (§ Task workflow "Capture at
  source"; the ADR and feature-doc records) — write the rationale, the
  tradeoff, and the contract down when they're cheap to state, so every later
  session (especially maintenance) recalls them instead of re-deriving them
  (lever 5).

## How temperloop tracks spend — and where the gaps are

The honest headline, confirmed by reading the telemetry directly: **this repo
does not log dollar spend, and does not log token counts, per command.** What
it captures is *work events* — counts, timestamps, and wall-time — not cost.
Knowing that is the point: it tells you what you can and can't answer from the
built-in data.

### What's captured natively (kernel)

- **Raw-lake event streams** under [`meta/data/raw/`](../meta/data/raw/README.md)
  (field reference in [`docs/features/telemetry.md`](features/telemetry.md)):
  `command-run` (items processed/merged/parked), `issue-touches`, `claims`,
  `funnel` (each wake's event type + `duration_ms` + action counts), `gh-calls`
  (per-call wall-time `dur_ms` + exit code), `findings` (records the model's
  *identity*, useful for attribution, not its token count), and `gh-perf`
  (per-op latency percentiles). Every one records events, time, or counts —
  **none records tokens or dollars.**
- **The `/check-in` "Spend" digest.**
  [`workflows/scripts/telemetry-brief.sh`](../workflows/scripts/telemetry-brief.sh)
  renders `## 3. Spend — kernel-observable cost` from gh-call wall-time and
  knowledge-store op volume, and explicitly disclaims token tracking:
  *"token-cost spend (cost-per-epic) requires the overlay rollup pipeline —
  not available kernel-side."* So the kernel's "spend" is wall-time and op
  volume, a proxy, not model cost.
- **Directional cost estimates.**
  [`bin/lib/cost-estimates.conf`](../bin/lib/cost-estimates.conf) holds
  hand-derived USD bands that drive the `try` pre-spend estimate and the
  onboarding hard caps — *inputs to a spend guard*, not a *log of actual spend*.
- **Usage-quota headroom.** `claude/status-line.sh` persists Claude Code's live
  rate-limit state to `~/.claude/rate-limits.json` at zero token cost, feeding
  the 5-hour quota gate — rolling-window *headroom*, again not dollars.

### The honest gap — and the two empty slots left for it

Per-command **token counts** and **dollar spend**, and **cost-per-epic**, are
not captured kernel-side. They exist only as (a) the hardcoded directional
constants above and (b) an **overlay** rollup pipeline
(`meta/data/rollups/*` + `workflows/scripts/build_telemetry_brief.py`) that is
*not present in a bare kernel checkout* — `/check-in` guards it with an
`if [ -f … ]` and notes it's unavailable when absent
([`claude/commands/check-in.md`](../claude/commands/check-in.md)).

The kernel deliberately ships **two empty slots** where real spend data would
plug in, rather than pretending to have it:

- A `tokens` drop-in producer for `temperloop report` at
  `.temperloop/report.d/tokens` — if it emits `{"tokens_spent": <n>}`, the
  report headline becomes `tokens_spent / merged_count`. No such producer
  ships; the design non-goal is stated as "no precise cost accounting."
  ([`workflows/scripts/lib/report.contract.md`](../workflows/scripts/lib/report.contract.md)).
- The overlay `build_telemetry_brief.py` guard in `/check-in`, which would add
  the cost-per-epic / token-cost digest the kernel streams can't derive.

**What would close the gap:** a per-run token/dollar emitter (the `claude -p`
calls could write their `usage` totals to a new raw-lake stream), which both
empty slots are already shaped to consume. Until then, your own Claude Code
usage view remains the source of truth for actual spend — the same conclusion
the cost page reaches.

## Related

- [`cost-and-autonomy.md`](cost-and-autonomy.md) — what a run costs and what it
  does unattended, plus the spend *ceilings* (caps, quota gate) this page
  deliberately leaves out.
- [`docs/features/funnel-driver.md`](features/funnel-driver.md) — the autonomy
  tiers whose model split this page describes.
- [`docs/features/telemetry.md`](features/telemetry.md) — the raw-lake stream
  reference behind the tracking section.
- [`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh)
  — the single source of truth for every knob value named above.
