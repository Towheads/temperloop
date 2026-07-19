# Measurement proxies for /workshop effectiveness

Falsifiability contract for `/workshop` (temperloop#148, epic
[[Plans/2026-07-08 temperloop - design command front door]]; this file is
plan item `design-telemetry-proxies`, temperloop#220). Sibling of
`claude/measurement-proxies.md` (the K94/K102 precedent for the
communication-style model) — same shape, different subject: before/after
`/workshop` ships value, this file pins **what "did /workshop improve outcomes?"
cashes out to** — four named, checkable proxies, each tied to an existing
data source, an explicit designed-vs-hand-authored (or, for Proxy 4,
across-briefs) comparison, and a computation cadence. The four proxies below
are carried forward verbatim from the ratified brief's own dimension 9
(`Designs/temperloop - design command design brief.md` § 9) — this file is
where that brief's promise is discharged in full.

## Independence from /workshop's own merge acceptance

**These proxies measure the system `/workshop` feeds. They do not gate any
sibling plan item's merge.** Nothing in `Plans/2026-07-08 temperloop -
design command front door.md` takes a `depends-on:`/`after:` edge on this
file, and no other `design-telemetry-proxies` sibling (`design-command-core`,
`design-review-machinery`, `design-adoption-pack`, `design-adr-emission`,
`design-persona-agents`) is blocked on a proxy reaching a target value here.
The relationship runs the other way: once epics start flowing through
`/workshop` in volume, these are the numbers a retro pass or `/check-in` pulls
to ask "did the coverage walk help, hurt, or do nothing" — after the fact,
never as a merge gate.

## Proxies, not proofs

None of what follows is a validated efficacy metric. Each proxy is a cheap,
directionally-informative signal that plausibly correlates with "the
coverage walk paid for itself" — not a causally-proven measure of it. A
falling merge-gate-failure rate on designed epics is *consistent with* the
walk catching what would otherwise surface at merge time; it is not proof
the walk caused the improvement, since epic size, author familiarity, and
unrelated gate churn all confound the comparison. Read every number as "this
moved, worth a look," matching `claude/measurement-proxies.md`'s own
epistemic stance.

## No new telemetry stream

All four proxies below derive from artifacts `/workshop`, `/assess`, or
`/build` **already produce** — satisfying this item's acceptance criterion
2 without inventing instrumentation:

- the epic body's `design-brief:` provenance marker line (`claude/commands/workshop.md`
  Step 5a) — the designed/hand-authored classifier;
- each PR's existing CI check-run history (`ci-poll.sh`'s `CI_FAILED`
  outcome, `gate.sh managed-merge`'s `EJECTED` disposition — `claude/commands/build.md`
  3g/4b);
- the epic-close retro tracker's `## Merge friction` section (`claude/commands/build.md`
  4d-retro, the mint) and the `rework`/`rework-cause:<cause>` labels
  (`workflows/scripts/board/capture.sh --rework`, F#730);
- the plan note's Contract-derived acceptance-placeholder bullets and the
  `needs-clarification` label / `## Re-triage signals` section
  (`claude/commands/assess.md` Steps 1, 2, 4);
- the `Designs/*.md` ratified brief notes' per-dimension disposition lines
  (`claude/workshop-schema.md` § Disposition grammar).

If a future proxy genuinely needs a new stream, its schema must be
documented in `meta/data/raw/README.md`'s shape **and** the extraction rule
Live/Drain paired in the same change (`claude/commands/tidy.md`'s registry +
`workflows/scripts/validate-live-drain.sh` green) — this file names no such
stream today because none of the four proxies requires one.

## Proxy 1 — Merge-gate failures on designed vs. hand-authored epics

**What it measures.** Whether a `/workshop`-materialized epic's PRs clear the
merge gate clean, versus needing a CI-failure-triggered worker re-spawn or
an `EJECTED` disposition at the batched merge gate — a proxy for whether the
coverage walk's design-time promises (each brief dimension pre-writing what
its enforcing merge-time gate will demand — `claude/workshop-schema.md`'s
"design-time promise ↔ merge-time enforcement is one loop" framing) actually
reduced surprises at merge time, versus a hand-authored epic whose `##
Contract` had no such walk behind it.

**Data source.** No new stream — two already-emitted, structured decision
points, keyed by PR:

- `claude/commands/build.md` 3g's `ci-poll.sh` `CI_FAILED` outcome (which
  triggers an escalate-on-retry re-spawn per the 3c operating principle) and
  4b's managed-merge gate `EJECTED` disposition (exit 5 — CI red after
  `update-branch`) are approximated after the fact from each PR's check-run
  history: `gh api repos/<owner>/<repo>/commits/<sha>/check-runs` per SHA the
  PR carried (a PR that needed a force-push re-run left more than one
  distinct head SHA, each independently queryable). **Any pre-merge red
  check-run approximates these events from history** — the raw check-run
  record cannot distinguish an orchestrator-observed `CI_FAILED` from an
  `EJECTED` from a red run no poll ever observed, so the proxy counts
  "PR carried ≥1 red pre-merge check-run," a slight over-approximation of
  the orchestrator-witnessed event set, applied identically to both sides
  of the comparison.
- Epic classification rides the `design-brief: [[Designs/<note>]]` marker
  line `claude/commands/workshop.md` Step 5a writes into a materialized epic's
  body — its presence/absence is exactly what already distinguishes a
  `/workshop`-born epic from a hand-authored one. Confirmed directly: neither
  temperloop#94 nor temperloop#131's issue body contains a `design-brief:`
  line (both pre-date `/workshop`), which is precisely why the epic's own
  acceptance criterion names them as the hand-authored baseline.

**Designed-vs-baseline comparison.** For a closed epic, compute
merge-gate-failure rate = (# of its PRs with ≥1 `CI_FAILED`/`EJECTED` event
before final merge) / (total PRs closing its sub-issues). Compare the
distribution across `design-brief:`-marked epics against the K94/K131
hand-authored baseline.

**How/when computed.** Pulled on demand (a retro pass, `/check-in`, or a
periodic parity check) by walking a closed epic's sub-issues → their closing
PRs (`Closes #N` linkage in the PR body, or the issue's closing-event
timeline) → each PR's SHA/check-run history. Not continuously emitted; cheap
enough to compute retrospectively from existing `gh` data with no dedicated
stream.

**Named gap, stated honestly.** This repo has zero fully `/workshop`-materialized-**and**-built
epics to sample yet — K148 (the `/workshop` epic itself) is mid-build, and its
own children (including this one) are the first designed-epic sample once
K148 closes. The hand-authored baseline (K94, K131) is available now; the
designed side fills in as K148 and its successors complete.

## Proxy 2 — Mid-build rework rate

**What it measures.** How much of a designed epic's build work had to be
redone, or a contract/edge actually changed, after building started — the
sign that dimension 4 (Contract seams)'s design-time promise didn't hold,
forcing mid-build replanning the coverage walk should have caught.

**Data source.** No new stream — two existing artifacts, with a relocation
this proxy must account for (the mint-then-judge redesign, temperloop#533):

- **Primary:** the epic-close retro tracker's `## Merge friction` section
  (`claude/commands/build.md` 4d-retro — the mint, filed at epic close; not
  4d-epic, which only closes the epic issue) buckets every PR conflict
  encountered as `trivial-inline` (resolved in place) / `rebase-respawn`
  (needed an update-branch/rebase round-trip) / `real-rework` (a contract or
  edge actually had to change) — `real-rework` is defined, verbatim, as
  mid-build rework. This bucket data is a **"what happened" signal only**:
  as of #533 the mint deliberately carries no judgment (`build.md` 4d-retro's
  own framing — "the tracker is a mint, not a questionnaire"), so it no
  longer feeds any named KPI trend inside the kernel itself.
- **Secondary, corroborating:** the `rework` / `rework-cause:<regression|spec-miss|flake>`
  GitHub labels (`workflows/scripts/board/capture.sh --rework`, F#730)
  applied when a mid-build-discovered defect is re-filed. This is broader
  than strictly "mid-*this*-build" (it covers any re-filed rework, not only
  rework surfacing while a specific epic is being built), so it corroborates
  rather than substitutes for the retro issue's own count.

**Handoff-defect KPI — relocated out of the kernel mint (#533).** Before
#533, the mint template itself asked four decomposition-retro questions and
tallied a handoff-defect taxonomy, and this doc used to cite that data as
feeding a "plan-defects-per-epic KPI" trend `build.md` named. #533 removed
both the four questions and the handoff-defect taxonomy from the kernel mint
template outright and relocated them to the overlay `/retro` judge's sixth
axis (`build.md` 4d-retro, verbatim: "The four decomposition-retro questions
and the handoff-defect taxonomy that used to live here have moved out of the
kernel into that judge's sixth axis"). The handoff-defect KPI therefore now
sources from **the judge's verdict**, not the kernel mint — and `build.md`
(and `tidy.md`) no longer name a `plan-defects-per-epic` KPI trend at all
(confirmed: the string is absent from both files at HEAD). **Named gap,
stated honestly:** on a bare kernel-only checkout with no overlay `/retro`
judge installed, this KPI has **no kernel-side source at all** — the mint's
`retro-info` state label (as opposed to `retro-pending`) is exactly the
marker for this case: nothing measures the handoff-defect count for that
tracker, by design, until a judge is installed and runs against it.

**Designed-vs-baseline comparison.** Rework rate = `real-rework`-bucketed
conflict count / total conflicts (or / total PRs) logged in the epic's own
retro issue. Compare designed epics against K94/K131.

**How/when computed.** Read at epic-close time, when the retro tracker
already exists (`claude/commands/build.md` 4d-retro — the mint — auto-files
it on the epic's open→closed transition) — no separate pull needed beyond
reading that tracker's `## Merge friction` section.

**Named gap, stated honestly.** Neither K94 nor K131 has a filed retro issue
today — confirmed via `gh issue list --search "Retro-for-epic: #94 in:body"`
and the `#131` equivalent, both returning zero results, most likely because
both epics closed before (or without triggering) `build.md`'s now-standard
auto-retro-file step. The retro-issue-based hand-authored baseline for this
proxy is therefore a **named gap**, not a ready number, until a retro issue
is backfilled for K94/K131 by hand (a manual read of their PR/commit history
for any documented mid-build reversal is the rougher fallback baseline
method in the meantime). Separately, zero `rework`-labeled issues exist
repo-wide today (confirmed via `gh issue list --label rework --state all`)
— the F#730 convention is real but unexercised so far, so the corroborating
signal has no samples yet either.

## Proxy 3 — /assess clarification round-trips on designed epics

**What it measures.** How often `/assess` (or the operator, at the approval
gate) had to supply a clarification a designed epic's `## Contract` didn't
already carry, before its items could be built — a well-formed Contract
(dimension 4) should approach zero round-trips, per the ratified brief's own
framing (§ 9: "a well-formed Contract should approach zero").

**Data source — with a structural nuance the naive read misses.** A
`/workshop`-materialized epic carries a `## Contract` with **zero sub-issues**
(`claude/commands/workshop.md` Step 5b), so `/assess` against it runs in
**epic-decomposition mode** (`claude/commands/assess.md` Step 1's "No
sub-issues found" branch, foundation #526) — every item is Contract-derived,
never sub-issue-derived. The ordinary clarification signal, the
`needs-clarification` label (`/triage`-stamped on a discovered sub-issue,
prefilled to `needs_clarification: true` in `assess.md` Step 1, routed to
`## Re-triage signals` in Step 4), **cannot fire for a Contract-derived
item** — there is no pre-existing sub-issue for `/triage` to have labeled.
The correct, already-existing analog for epic-decomposition mode is instead:
the acceptance-placeholder bullet `assess.md` Step 2 writes onto any item
whose `Produces` bullet is too vague to yield a falsifiable check —
`- (no acceptance criteria derivable from source — fill in during review)`
— which the Step 3 sanity pass and the approval gate then force the
operator to fill in before `/build` proceeds (`assess.md` Step 2's
"Don't fabricate" rule). Each such placeholder still present in the draft
plan note, and filled by hand before `status: draft → approved`, **is** the
round-trip for a designed epic.

(Should a `/workshop`-born epic ever also carry independently-`/triage`d
sub-issues in a mixed epic, the ordinary `needs-clarification` label /
`## Re-triage signals` mechanism still applies to those items unchanged —
this nuance only concerns the epic-decomposition-mode path.)

**Designed-vs-baseline comparison.** Round-trips-per-item = placeholder-bullet
count / total Contract-derived items, read directly off the plan note (`##
Items` section) at the moment its `status` flips `draft → approved` — a diff
between the `/assess`-authored draft and the approved version shows exactly
which placeholders got filled in and how. **Named gap, stated honestly:**
placeholders are filled *before* the status flip, so at flip time the count
is always zero — and the kernel's knowledge-store contract
(`workflows/scripts/lib/knowledge_store.contract.md`) does not guarantee
version history, so the draft→approved diff exists only where the store
happens to be versioned (e.g. a git-backed or Obsidian-synced store); on a
bare plain-files store this proxy is computable **forward-only, at
`/assess`-completion time** (the draft state, placeholders still present),
not retrospectively. **Caveat, stated plainly:** K94 and
K131 both arrived with real, `/triage`-authored sub-issues from the start
(not Contract-derived), so their own `/assess` pass — if run — would show
clarification via the `needs-clarification`-label/`## Re-triage signals`
count, not the acceptance-placeholder count. The two mechanisms measure the
same underlying concept ("did `/assess` have to punt a decision back to the
operator instead of deriving it") but are structurally different artifacts;
comparing designed-epic placeholder-counts against a hand-authored epic's
label-counts is not a single unified metric, and should be read side-by-side
rather than as one number moving.

**How/when computed.** Read the plan note directly whenever `/assess`
completes against a designed epic (no `gh` calls needed beyond what
producing the plan note already required) — cheapest of the four proxies to
pull, since it needs no history walk.

## Proxy 4 — Dimension-disposition distribution

**What it measures.** Across every ratified `/workshop` brief, the per-dimension
distribution of dispositions — the `disposition: filled` /
`disposition: n/a — <reason>` / `disposition: deferred → <ref>` line each
dimension carries, in the prefixed shape the brief-conformance lint
(`workflows/scripts/validate-design-brief.sh`) checks and the schema's
worked example uses — among `claude/workshop-schema.md`'s 16 kernel dimensions
(plus any overlay-added ones). A dimension disposed `n/a` on (nearly) every brief is
dead weight in the schema — a removal candidate, per the ratified brief's
own framing (§ 9: "the template earns its slots empirically").

**Data source.** No new stream — the `Designs/*.md` ratified brief notes
themselves. Each carries one disposition line as the **first non-blank
line** under each numbered dimension heading
(`claude/workshop-schema.md` § Disposition grammar's positional contract,
going forward mechanically enforced by the brief-conformance lint,
temperloop#216 / `workflows/scripts/validate-design-brief.sh`). Compute by
walking every `status: ratified` note in `Designs/` and tallying, per
dimension number, how many briefs carry `disposition: filled` vs.
`disposition: n/a — …` vs. `disposition: deferred → …` on it.

**Designed-vs-baseline comparison.** This proxy has **no** hand-authored
comparison axis — K94 and K131 pre-date the brief schema entirely and carry
no dimension-disposition data at all. It is a distribution tracked across
designed-epic briefs over time, not a designed-vs-baseline delta like
Proxies 1–3.

**How/when computed.** Cheapest to read at a retro pass, or whenever
`/workshop` materializes a new epic (read every prior `Designs/*.md` note's
disposition lines then). **Named gap, stated honestly:** exactly one
ratified brief exists today, `Designs/temperloop - design command design
brief.md` (the bootstrap brief) — and per the `design-brief-lint` plan
item's own note, that brief is **not yet retrofitted** to the schema's
disposition-line convention (it predates the lint and may still need its
divergences filed as an issue before it can serve as a lint fixture). With
n=1, and that one pre-dating the positional convention this proxy reads, a
real distribution is not computable yet. This proxy becomes meaningful once
a second and third ratified, schema-conformant brief exists — most likely
once `design-persona-agents` (K221) or a downstream feature's own design
pass lands.

## Cross-references

- Epic: temperloop#148 ("/workshop: front door for invented work"); this
  file's own plan item: `design-telemetry-proxies`, temperloop#220.
- Sibling contract this file mirrors: `claude/measurement-proxies.md`
  (temperloop#94/#102 precedent — the communication-style model's
  falsifiability contract).
- Source of the four proxies (carried forward verbatim, then expanded with
  data-source mechanics): `Designs/temperloop - design command design
  brief.md` § 9 ("Telemetry & measurement proxies (K102 precedent)").
- Disposition grammar + kernel dimension list (Proxy 4): `claude/workshop-schema.md`.
- Materialization mechanics (the `design-brief:` marker, Proxy 1's
  classifier): `claude/commands/workshop.md` Step 5a/5b.
- CI-poll / managed-merge-gate outcomes (Proxy 1): `claude/commands/build.md`
  3g, 4b.
- Epic-retro `## Merge friction` section, and the `rework`/`rework-cause:*`
  label convention (Proxy 2): `claude/commands/build.md` 4d-retro;
  `workflows/scripts/board/capture.sh` (F#730).
- The handoff-defect KPI's relocation out of the kernel mint into the
  judge's sixth axis (temperloop#533, Proxy 2): the mint,
  `claude/commands/build.md` 4d-retro; the judge, the overlay `/retro`
  command (not present in a kernel-only checkout — see Proxy 2's named gap).
- Epic-decomposition mode, the acceptance-placeholder rule, and the
  `needs-clarification` label / `## Re-triage signals` mechanism (Proxy 3):
  `claude/commands/assess.md` Steps 1, 2, 4 (foundation #526).
- Raw telemetry stream conventions (the pattern a future new proxy stream
  would follow, if one is ever found necessary): `meta/data/raw/README.md`.
- Hand-authored baseline epics named by K220's acceptance criterion:
  temperloop#94 ("Communication style model"), temperloop#131
  ("Documentation-first" epic).
