---
title: Cost & autonomy — what running temperloop costs, and what it does on its own
---

# Cost & autonomy — what running temperloop costs, and what it does on its own

temperloop#426. Two questions a stranger should be able to answer before
running anything, not after: **what does this spend of my own money**, and
**what will it do without asking me first**. This page answers both, with
real figures where a real figure exists, and an honest "no fixed number"
where one doesn't. It's linked from the very first step of the quickstart
(`README.md` § 3, `bin/README.md`) on purpose — read this before `temperloop
try`, not after.

## What running temperloop costs

Every dollar below is billed to **your own** Claude account, the same way
any Claude Code session is. temperloop has no billing of its own, collects
no payment, and runs no hosted service — it's a `claude -p` invocation (for
the automated tiers) or your own interactive Claude Code session (for
everything else), against your own API/subscription usage.

**Tier 1 — the onboarding steps (`try`, `try --demo`).** These are the only
two commands with a hardcoded, published cost band, because they're the
commands a total stranger runs before deciding whether to trust anything
else here:

- `temperloop try` — a real `claude -p` shadow-triage classification pass
  over your repo's own open issues, invoked with every tool disabled
  (`--tools ""`) so it cannot write anything. Directional band: **$0.02–
  $0.08 per open issue classified**, hand-derived once from real operator
  usage (`bin/lib/cost-estimates.conf`), hard-capped at **$1.00** for the
  whole run regardless of issue count or how wrong the estimate turns out
  to be.
- `temperloop try --demo` — the one mutating exception: one real issue → PR
  tick against a disposable, throwaway demo repo. Directional band:
  **$0.05–$0.40 per tick**, same provenance, hard-capped at **$2.00**
  (`--demo-cap-usd`, adjustable via flag).

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
hard-capped at **$0.25** per invocation. That's the cheap end; a full
`/build` level driving several PRs through CI is materially more, bounded
only by how much work you asked for.

**Tier 3 — unattended (the autonomous funnel driver, nightly `/tidy`, any
`claude -p` cron invocation).** These run without you watching, so they're
the tier most worth having a real number for. One concrete observed data
point: a real headless `/tidy` invocation — a full nightly drain pass over
a session-stub backlog — cost **$1.48** in one logged run. That's a single
data point, not a guaranteed average (cost scales with backlog size, same
as any other tier), but it's real, not modeled. The autonomous funnel driver
adds its own per-tick spend on top of ordinary interactive use, proportional
to how many actions it was handed that tick (`docs/features/funnel-driver.md`
§ Resource impact) — the per-tick item cap (below) is the direct lever on
how large that can get.

## Is a budget cap on by default?

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

## Autonomy: what it may do without asking, and what always blocks

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
  explicit consent and a preview step; nothing repo-derived transmits
  silently, unattended or not.
- **The knobs that govern all of this** (name them symbolically — check
  `workflows/scripts/build/build.config.sh` for current defaults, never
  trust a hardcoded number in prose): `FUNNEL_DRIVE` (safe tier on/off),
  `FUNNEL_DRIVE_MERGE` (merge tier on/off, rides on top of the safe tier),
  `FUNNEL_DRIVE_CAP` / `FUNNEL_DRIVE_MERGE_CAP` (max items driven per tick —
  the direct lever on blast radius, independent of backlog size),
  `BUILD_MERGE_GATE_WINDOW` (the timed auto-merge window for a clean set;
  `0` forces every merge modal, no auto tier at all), and the 5-hour quota
  gate knobs above.

## Your spend vs. the team's shared resources

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

## Where to read more

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
