---
title: Managing token spend — how temperloop reduces and tracks what it costs
---

# Managing token spend — how temperloop reduces and tracks what it costs

[`cost-and-autonomy.md`](cost-and-autonomy.md) answers *what* a run costs
and *what* it does on its own. This page is the companion for someone
already running it: the concrete ways temperloop is **efficient** with
model spend — more useful output per token — and what it **tracks** so you
can see where the tokens go, including the honest gaps in that tracking.

Two framing facts carry over from the cost page:

- **Tokens are the model-independent unit.** The same workload is roughly
  the same token count on either model; dollars scale ~1.67× from Sonnet 5
  to Opus 4.8. So "efficient" almost always means *do the same work with
  fewer tokens*, or *route those tokens to a cheaper model* — the levers
  below.
- **Every setting named here has its value in
  [`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh),
  not in this prose.** The config file is the source of truth.

> **Efficiency vs. spend ceilings — a deliberate distinction.** A cap (the
> `configure` USD cap, the per-tick item caps, the 5-hour usage-quota gate)
> stops runaway spend; it doesn't make the work cheaper. Ceilings are
> documented on the cost page. This page is only about doing the work with
> fewer tokens.

## How temperloop keeps token spend efficient

Five families of lever. The first four make *building* a given change
cheaper — **shape** the work small, **route** each piece to the cheapest
model that fits, **challenge** it before building, and keep each run's
**context** lean. The fifth makes *every future* change cheaper: capture
intent durably so **maintenance** recalls it instead of re-deriving it —
and since maintenance is most of a codebase's lifetime, that's where the
cost drops most.

### 1. Break work into small, contract-scoped chunks

The most fundamental lever. Epic-sized work is decomposed up front — via
`/assess` (or `/workshop` for invented work) — into contract-scoped
sub-issues grouped into dependency levels, *before* anything is built. A
sub-issue fixes its **contract** — what it *produces*, what it *consumes*,
and its *acceptance check* — and says nothing about *how*. That pays off
three ways, each a token saving:

- **Less context per unit.** A chunk scoped to its own contract needs only
  that contract and its declared dependencies in context — not the whole
  epic. The orchestrator benefits too: under `/build`, orchestrator context
  stays pinned to one small object per dependency level regardless of how
  many items the level holds.
- **Better alignment, so less rework.** A fixed contract is a cheap
  checkpoint: a misread requirement is caught at the seam — where the fix
  is a contract edit — instead of after a big-bang implementation is built,
  reviewed, and merged. Shipping the *wrong* thing and rebuilding it is the
  single most expensive failure mode; small contracts make it rare by
  forcing agreement on *what* before spending tokens on *how*.
- **Less duplicate work.** Contracts are stale-resistant (an implementation
  learning changes the *how*, not the contract) and parallelizable (no
  coordination once the seam is fixed), so a finished unit is a reusable
  building block and a mid-course discovery reworks one unit, not the
  level. A worker also builds only once every dependency is **merged** —
  no wasted build on a stale base.

### 2. Route each chunk to the cheapest model that fits

Once work is scoped, spend judgment-tier compute only where the judgment is
needed. Mechanical, high-volume work goes to a cheaper model; genuinely
hard decisions (a merge, a design fork) get the strong one. The failure
this prevents is a fan-out that silently launches every agent on the top
tier for work that never needed it.

- **The pipeline splits its driver model by judgment level:**
  `PIPELINE_DRIVE_MODEL` drives mechanical actions on a mid-tier model;
  `PIPELINE_DRIVE_MERGE_MODEL` reserves the strong tier for the
  high-judgment code/merge tier.
- **`/build`'s machinery executors are pinned to the cheapest tier, and
  batched.** The agents that just run machinery commands do no reasoning,
  so they run on the cheapest model, and mechanically-adjacent steps share
  one executor spawn instead of one per shell command — a change measured
  to cut a 3-item level from 40 agent spawns to 15, each spawn having paid
  ~160K cache-read tokens to run a single one-liner.
- **Executors also carry a deliberately lean context**, because context
  size is what a cache miss costs: the executors that wait longer than the
  prompt-cache TTL by construction (the CI poll, the acceptance gate) run
  as a minimal Bash-only agent definition rather than a general-purpose
  one — measured at −17.5% first-call cache-creation tokens.
- **The standing rule** — each fan-out sets its worker's tier *explicitly*
  to the cheapest that fits, never defaulting to the driver's tier — is
  [`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Subagent usage
  ("Cost-tier routing"). Review seats route the same way (advisory
  reviewers → mid-tier, locate-and-report fan-outs → cheapest).

### 3. Challenge the work before building it

Cheap, read-only adversarial passes catch a wrong assumption or an
over-scoped design *before* expensive build tokens are spent on it. A
skeptic that refutes a bad premise costs a fraction of the build that
premise would have produced — and the reviewers themselves run on cheaper
tiers, so the challenge is cheap by construction.

- **Design work faces an adversarial panel.** `/workshop` runs read-only
  review lenses (`architecture-reviewer`, `requirements-auditor`) over the
  design brief and folds findings back in before the epic is materialized —
  where an over-broad scope gets pulled back while it's still a brief, not
  built code.
- **Decomposition premises are verified against reality.** `/assess`'s
  sanity-check agents judge every decomposition premise against
  freshly-fetched `origin/main` — does this file exist, is this already
  fixed — so a wrong premise doesn't become a wrong contract a worker
  builds and rebuilds. The recurring catch is precisely "referenced a thing
  that didn't exist."
- **Implementation faces per-change reviewers.** `/build` runs the reviewer
  matching the change kind (`python-reviewer`, `docs-reviewer`, …) as a
  read-only pass; blocking findings loop straight back, so a defect is
  fixed against a small, fresh diff rather than discovered later against a
  large, stale one.
- **Every PR ships its own verification surface**, so the reviewer confirms
  correctness without re-running anything. When a review gate can't run, it
  degrades legibly (`skipped — <agent> unavailable`) rather than looking
  passed.

### 4. Keep each run's working context small

Within a single run, input tokens dominate and grow with context:

- **Context-polluting work goes to a subagent** — a broad grep sweep, a log
  trawl, a many-file read; only the *findings* come back to the parent.
- **Workers return a compact verdict, not a transcript** — each `/build`
  worker's final message is a small fenced JSON object the orchestrator
  reasons over.
- **`/tidy` pre-compresses transcripts** to a ~2–3K-token report rather
  than loading the ~18K-token raw transcript.
- **Poll cadences are tuned to the prompt-cache window**, so a wake-up
  check is a cache read, not a cache miss.

### 5. Make the record durable, so maintenance stays cheap

Most of a codebase's lifetime is maintenance, and maintenance is where
re-establishing **intent** is normally the expensive part. A session that
reconstructs why a feature exists pays for it in input tokens — and risks
getting it wrong, which is rework. temperloop front-loads the capture so a
maintenance session **recalls** context cheaply instead of reconstructing
it:

- **Feature docs are problem-first.** Each page under
  [`docs/features/`](features/) opens with the *why*, so the intent behind
  a subsystem is a cheap read, not code archaeology.
- **ADRs capture architectural calls and their tradeoffs** under
  [`docs/adr/`](adr/) — a maintainer reads the tradeoff that was accepted
  instead of re-deriving (or accidentally re-litigating) it.
- **The epic contract records the seam durably** on the issue itself, so a
  later change reasons against a stated contract rather than
  reverse-engineering one from code.
- **PR verification surfaces stay in the PR body**, so how a change was
  proven correct is recoverable from history.
- **Decision notes in the knowledge store** record a decided-but-unbuilt
  direction, so a later session doesn't re-open a settled question.

## How temperloop tracks spend — and where the gaps are

The honest headline, confirmed by reading the telemetry directly: **this
repo's own telemetry does not log dollar spend or per-command token
counts.** It captures *work events* — counts, timestamps, wall-time — not
cost. Knowing that tells you what you can and can't answer from the
built-in data.

But temperloop isn't the only thing keeping records. **Claude Code itself
persists per-agent token usage** in transcripts on disk, and reading those
answers the token question retroactively, over all of history — no emitter
needed.

### What's captured natively

- **Raw-lake event streams** under `meta/data/raw/` (field reference in
  [`docs/features/telemetry.md`](features/telemetry.md)): command runs,
  issue touches, claims, pipeline wakes, drain findings, `gh`-call
  latencies. Every one records events, time, or counts — none records
  tokens or dollars.
- **The `/check-in` spend digest** renders kernel-observable cost (gh-call
  wall-time, knowledge-store op volume) and explicitly disclaims token
  tracking — a proxy, not model cost.
- **Usage-quota headroom** — the live rate-limit state feeding the 5-hour
  quota gate. Rolling-window headroom, again not dollars.

### Reading token spend out of the harness's own transcripts

[`workflows/scripts/pipeline-spend-report.sh`](../workflows/scripts/pipeline-spend-report.sh)
walks the workflow-agent transcripts Claude Code already writes and reports
cost-weighted spend. Local files only — no network, no API, no `gh`.

```sh
workflows/scripts/pipeline-spend-report.sh                       # whole corpus
workflows/scripts/pipeline-spend-report.sh --since 2026-07-20    # a date window
workflows/scripts/pipeline-spend-report.sh --run wf_423b8a39-a02 # one workflow run
workflows/scripts/pipeline-spend-report.sh --format json         # machine-readable
```

It reports the corpus (runs, agents, deduped API calls), raw tokens per
class, total cost-weighted units, the **machinery vs. item-worker** split,
and per-model attribution. The machinery/worker split is what makes
lever 2's claims checkable: `--since` before and after a batching change is
a two-command before/after rather than a projection nobody measured.

Two things to know before trusting a number from it:

- **Units are cost-weighted, not raw tokens.** The four class weights live
  in `build.config.sh`, never in the script. This matters: cache-creation
  bills ~12.5× cache-read, so ranking by *raw* tokens put the machinery
  agents at ~10% of spend when cost-weighted they are ~32%.
- **One API response spans several transcript lines**, so the tool dedupes
  by request id — summing per line inflated the measured corpus 2.16×. The
  report prints the undeduped figure beside the real one so the correction
  is visible, and the property is pinned by a fixture test.

An opt-in `--by-agent-type` flag additionally attributes spend to named
agent seats (the review and persona agents); it requires `--root` naming a
single Claude Code project directory, and its wider-corpus totals are a
side channel, never a breakdown of the headline figure — the script's own
header documents both caveats in full.

There's also a `tokens` producer for `temperloop report`
(`.temperloop/report.d/tokens`): it derives `tokens_spent` per merged item
from the same transcripts, and — given a hand-written
`.temperloop/pricing.json` — a directional dollar line beside it. The
number is directional cost-weighted units, never a billed amount.

Your Claude Code usage view remains the source of truth for actual
**dollars**; these tools answer *where the tokens went*, which is the
question the levers on this page are trying to move.

## Related

- [`cost-and-autonomy.md`](cost-and-autonomy.md) — what a run costs and
  what it does unattended, plus the spend ceilings this page deliberately
  leaves out.
- [`docs/features/pipeline-driver.md`](features/pipeline-driver.md) — the
  autonomy tiers whose model split this page describes.
- [`docs/features/telemetry.md`](features/telemetry.md) — the raw-lake
  stream reference behind the tracking section.
- [`workflows/scripts/build/build.config.sh`](../workflows/scripts/build/build.config.sh)
  — the single source of truth for every setting named above.

---

*Written by claude-fable-5 on 2026-08-13.*
