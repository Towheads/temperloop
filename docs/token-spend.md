---
title: Managing token spend — how temperloop reduces and tracks what it costs
---

# Managing token spend — how temperloop reduces and tracks what it costs

[`cost-and-autonomy.md`](cost-and-autonomy.md) answers *what* a run costs and
*what* it does on its own. This page is the operator/contributor companion:
the concrete levers temperloop uses to **reduce** model spend, and what it
**tracks** so you can see where the tokens go — including the honest gaps in
that tracking.

Two framing facts carry over from the cost page:

- **Tokens are the model-independent unit.** The same workload is roughly
  the same token count on either model; dollars scale ~1.67× from Sonnet 5
  to Opus 4.8. So "reduce spend" almost always means *reduce tokens* or
  *route those tokens to a cheaper model* — the two levers this page is
  about.
- **Every knob named below has its value in
  [`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh),
  not in this prose.** Defaults are quoted here as a directional aid, but the
  config file is the source of truth — a knob's value can change without this
  page being touched, so never trust a number here over the config.

## How temperloop reduces token spend

### 1. Model-tier routing — the cheapest model that fits the stage

The headline lever, and the one most worth understanding: **spend
judgment-tier compute only where the judgment is needed.** Mechanical,
high-volume, low-reasoning work is routed to a cheaper model; genuinely
hard decisions (a merge, a design fork) get the strong one. The failure this
prevents is a fan-out that silently launches every agent on the top tier for
work that never needed it.

- **The autonomous funnel splits its driver model by judgment level.**
  Mechanical safe-tier drives run on a cheaper model; the high-judgment
  code/merge tier gets the strong one.
  - `FUNNEL_DRIVE_MODEL` (default `claude-sonnet-5`) — the headless driver
    for mechanical actions.
  - `FUNNEL_DRIVE_MERGE_MODEL` (default `claude-opus-4-8`) — the merge
    driver, because code drives are high-judgment.
  - File: [`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh).
- **`/build`'s one-shot executors are pinned to the cheapest tier.** The
  agents that just run a spine command or a read-only merge-state query do no
  reasoning, so they're hardcoded to Haiku; the actual worker that *does* the
  build inherits the session model instead (`model: item.model`, undefined →
  inherit). File: [`claude/workflows/build-level.mjs`](../claude/workflows/build-level.mjs)
  (`model: 'haiku'` for the executor; worker inherits).
- **The standing principle.** The rule that a fan-out site must set its
  worker's tier *explicitly* to the cheapest tier that fits — rather than
  defaulting every agent to the driver's tier — lives in
  [`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Subagent usage
  ("Cost-tier routing"). Each new fan-out names its own model knob the same
  way; the two funnel knobs above are the worked example.

> temperloop routes by **model tier**, not by a separate effort setting —
> there is no effort-tier (`low`/`high`/`xhigh`) knob in the pipeline config
> today. The harness's per-agent effort control exists but isn't wired into
> temperloop's own routing; model-tier selection is how the cost/quality
> tradeoff is expressed here.

### 2. Bounded context — stop the expensive tokens from accumulating

Input tokens dominate most pipeline spend, and they grow with context. These
mechanisms keep a long run's context from ballooning:

- **Delegate noisy investigation to a subagent.** A broad grep sweep, a log
  trawl, a many-file read runs in a subagent; only the *findings* come back
  to the parent, not the file dumps. [`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md)
  § Subagent usage.
- **Workers return a compact verdict, not a transcript.** Each `/build`
  worker's final message is a small fenced JSON verdict; the orchestrator
  drives all state from that object instead of ingesting the worker's prose,
  which "bounds orchestrator-context growth across a long run." Under the
  `--workflow` path, the orchestrator's context stays pinned to one small
  `{parked, escalations}` object per dependency level regardless of how many
  items the level holds. [`claude/commands/build.md`](../claude/commands/build.md).
- **`/tidy` pre-compresses transcripts before reasoning over them.** The tidy
  scanner turns each session stub into a ~2–3k-token JSON report rather than
  loading the ~18k-token raw transcript. [`claude/commands/tidy.md`](../claude/commands/tidy.md).
- **Poll cadences are tuned to the prompt-cache window.** `/assess`'s
  approval poll fires its first wake *inside* the prompt-cache window so the
  check is cheap, and deliberately avoids landing on the 300s boundary ("a
  cache miss for no latency benefit"). Knobs: `ASSESS_POLL_FIRST_WAKE`,
  `ASSESS_POLL_CADENCE`, `ASSESS_POLL_BUDGET`
  ([`claude/commands/assess.md`](../claude/commands/assess.md);
  [`build.config.sh`](../workflows/scripts/build/build.config.sh)).

### 3. Caps that bound blast radius per run

Even when the driver *is* invoked, the amount it can spend in one wake is
capped:

- **Per-tick item caps.** A funnel tick drives at most `FUNNEL_DRIVE_CAP`
  (default 1) safe-tier items plus `FUNNEL_DRIVE_MERGE_CAP` (default 1)
  merge-tier items, so per-tick spend is bounded regardless of how large the
  ready backlog is. One vault `cap:` field feeds both.
- **Drive concurrency.** `FUNNEL_DRIVE_CONCURRENCY` (default 3) bounds how
  many autonomous drives run at once per tick.
- **Autonomy is off by default.** `FUNNEL_DRIVE` and `FUNNEL_DRIVE_MERGE`
  both default to `0` (emit-only / leave-merge-for-operator), so the
  auto-driven spend tiers don't run at all until you turn them on.
- All four: [`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh).

### 4. Hard USD caps on the onboarding tier

The commands a stranger runs first carry a real, tool-enforced dollar
ceiling — not printed advice — handed to the live `claude -p` call via
`--max-budget-usd`, so even a wrong estimate can't overspend:

- `temperloop try` — `TRY_CLAUDE_MAX_BUDGET_USD` (default `$1.00`/run),
  [`bin/lib/cost-estimates.conf`](../bin/lib/cost-estimates.conf).
- `temperloop try --demo` — `--demo-cap-usd` (default `$2.00`/tick).
- `temperloop configure` — `CONFIGURE_CLAUDE_MAX_BUDGET_USD` (`$0.25`/call),
  `bin/subcommands/configure.sh`.
- Before spending, `try` also prints a **directional estimate** (band ×
  open-issue count from `cost-estimates.conf`) and requires an interactive
  confirmation — pre-spend visibility on top of the hard cap.

These caps and their token equivalents are tabulated on the cost page's
[§ Cost at a glance](cost-and-autonomy.md#cost-at-a-glance).

### 5. The 5-hour usage-quota gate

After each level or fix, a run checks how much of your Claude plan's rolling
5-hour usage window is left and **pauses, then auto-resumes** when it's too
low — so a run doesn't get cut off mid-task or burn quota it doesn't have.
Knobs: `BUILD_QUOTA_PAUSE_PCT` (default 10), `BUILD_QUOTA_WAIT_BUFFER`,
`BUILD_QUOTA_MAX_AGE`, `BUILD_QUOTA_CACHE`
([`build.config.sh`](../workflows/scripts/build/build.config.sh);
[`docs/features/build-spine.md`](features/build-spine.md)).

This is a **usage-quota** protection, not a **dollar** cap — it manages
*when* you spend against a rolling window, not *how much*. See the cost page's
[§ Is a budget cap on by default?](cost-and-autonomy.md#is-a-budget-cap-on-by-default)
for the dollar-ceiling story (there is none shipped by default past
onboarding).

### 6. Batching and not re-buying context

- **One merge gate per dependency level, not per item.** `/build` runs a
  whole level to CI-green and fires a single batched merge gate, so a
  decomposed epic is batch-resolved without a human gate (and its per-gate
  overhead) on every item. [`claude/commands/build.md`](../claude/commands/build.md).
- **Deferred questions batch at the gate.** A non-blocking in-run decision
  appends to the plan note's `## Questions` section and proceeds on its
  default, surfaced as one batch at the level merge gate rather than
  interrupting (and re-spending) mid-level. [`claude/plan-schema.md`](../claude/plan-schema.md).
- **Decision capture stops re-derivation.** Rationale is written once to the
  knowledge store; a later session recalls it instead of paying input tokens
  to re-derive the same context. [`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md)
  § Decision capture.
- **`dependsOn` merged-SHA precondition.** A worker builds only once every
  dependency SHA is merged, so it verifies against merged code and doesn't
  waste a build on a stale base. [`claude/commands/build.md`](../claude/commands/build.md).

## How temperloop tracks spend — and where the gaps are

The honest headline, confirmed by reading the telemetry directly: **this
repo does not log dollar spend, and does not log token counts, per command.**
What it captures is *work events* — counts, timestamps, and wall-time — not
cost. Knowing that is the point: it tells you what you can and can't answer
from the built-in data.

### What's captured natively (kernel)

- **Raw-lake event streams** under [`meta/data/raw/`](../meta/data/raw/README.md)
  (see [`docs/features/telemetry.md`](features/telemetry.md) for the full
  field reference): `command-run` (items processed/merged/parked per
  `/sweep`·`/triage`), `issue-touches`, `claims`, `funnel` (each wake's
  event type + `duration_ms` + action counts), `gh-calls` (per-call
  wall-time `dur_ms` + exit code), `findings` (extraction records — they log
  the model's *identity*, useful for attribution, but not its token count),
  and `gh-perf` (per-op latency percentiles). Every one records events, time,
  or counts — **none records tokens or dollars.**
- **The `/check-in` "Spend" digest.**
  [`workflows/scripts/telemetry-brief.sh`](../workflows/scripts/telemetry-brief.sh)
  renders a `## 3. Spend — kernel-observable cost` section from the gh-call
  wall-time and knowledge-store op volume. It explicitly disclaims token
  tracking: *"token-cost spend (cost-per-epic) requires the overlay rollup
  pipeline — not available kernel-side."* So the kernel's notion of "spend"
  is **wall-time and op volume**, a proxy, not model cost.
- **Directional cost estimates.**
  [`bin/lib/cost-estimates.conf`](../bin/lib/cost-estimates.conf) holds
  hand-derived USD bands that drive the `try` pre-spend estimate and the hard
  caps above. These are *inputs to a spend guard*, not a *log of actual
  spend* — provenance and caveats are in the file's own header.
- **Usage-quota headroom.** `claude/status-line.sh` persists Claude Code's
  live rate-limit state to `~/.claude/rate-limits.json` at zero token cost,
  feeding the 5-hour quota gate. This tracks rolling-window *headroom*, again
  not dollars.

### The honest gap — and the two empty slots left for it

Per-command **token counts** and **dollar spend**, and **cost-per-epic**,
are not captured kernel-side. They exist only as (a) the hardcoded
directional constants above and (b) an **overlay** rollup pipeline
(`meta/data/rollups/*` + `workflows/scripts/build_telemetry_brief.py`) that
is *not present in a bare kernel checkout* — `/check-in` guards it with an
`if [ -f … ]` and simply notes it's unavailable when absent
([`claude/commands/check-in.md`](../claude/commands/check-in.md)).

The kernel deliberately ships **two empty slots** where real spend data would
plug in, rather than pretending to have it:

- A `tokens` drop-in producer for `temperloop report` at
  `.temperloop/report.d/tokens` — if it emits `{"tokens_spent": <n>}`, the
  report headline becomes `tokens_spent / merged_count`. No such producer
  ships; the design non-goal is stated as "no precise cost accounting."
  [`workflows/scripts/lib/report.contract.md`](../workflows/scripts/lib/report.contract.md).
- The overlay `build_telemetry_brief.py` guard in `/check-in`, which would
  add the cost-per-epic / token-cost digest the kernel streams can't derive.

**What would have to be added** to close the gap: a per-run token/dollar
emitter (the `claude -p` calls could write their `usage` totals to a new
raw-lake stream), which the `report.d/tokens` slot and the overlay brief are
already shaped to consume. Until then, your own Claude Code usage view
remains the source of truth for actual spend — the same conclusion the cost
page reaches.

## Related

- [`cost-and-autonomy.md`](cost-and-autonomy.md) — what a run costs and what
  it does unattended (the stranger-facing companion to this page).
- [`docs/features/funnel-driver.md`](features/funnel-driver.md) — the
  autonomy tiers whose model split and per-tick caps this page describes.
- [`docs/features/telemetry.md`](features/telemetry.md) — the raw-lake stream
  reference behind the tracking section.
- [`docs/features/build-spine.md`](features/build-spine.md) — the quota gate
  in full.
- [`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh)
  — the single source of truth for every knob value named above.
