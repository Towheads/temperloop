---
title: Operational drain
slug: operational-drain
---

# Operational drain (epic-as-metadata for operational work)

## Problem

Epic membership used to be an execution router: any issue with a parent
epic took the assess → plan → build ceremony path, so triage's
group-by-meaning step rerouted related *operational* fixes onto plan
ceremony that bought them nothing — the evidence and full rationale live
in docs/adr/0030. This page covers what that ADR does not: the mechanics
of how an Operational epic's members drain and what the epic parent
becomes.

## How it works

The sweep/assess partition keys on the **work-class label**, not on epic
membership (docs/adr/0030). An `Operational` epic's members stay in
`/sweep`'s fix pool; the epic parent survives as a **metadata artifact** —
group context (its summary is injected into each admitted member's worker
prompt), progress narrative, and completion signal via an end-of-run
closing gate — never an execution router. The pieces:

- **Pool admission** (`workflows/scripts/build/sweep-epic-admission.sh`):
  with the opt-in setting on, a Ready sub-issue whose parent epic carries
  the `Operational` label and no `Foundational` label anywhere in the
  group joins sweep's pool alongside singletons. A `Foundational` label
  anywhere in the group — parent or any member, evaluated live at every
  pool build — keeps the whole epic on the ceremony path; a genuinely
  mixed-class group is reported, never silently resolved. Admission also
  requires triage's `edges-considered` marker (an empty edge read alone
  never proves order-freedom) and refuses any epic with a live
  (non-superseded) plan note. A failed read refuses the epic — an error is
  never the permissive branch.
- **Mutual-exclusion guard, both sides**
  (`workflows/scripts/build/assess-operational-refusal.sh`): `/assess`
  refuses to decompose an Operational epic while the setting is on
  (pipeline-drive-invoked runs are carved out until the router cutover —
  #1848 "pipeline-drive sweep-cutover rewiring"; an explicit operator
  override is always logged), and `/sweep`
  excludes plan-note-owned epics. **Claim-first is the last belt** closing
  the check-then-act window between the two probes.
- **Durable logical order**: `/triage` stamps genuine meaning-level
  precedence between an Operational group's members as native
  `blocked_by` edges (docs/adr/0031), behind a script-backed cycle check
  (`workflows/scripts/board/cycle-check.sh`). Sweep defers a member until
  its blocker is closed AND merged to the default branch; a `parked`
  blocker never releases its dependents.
- **Ported scrutiny and merge regimes**: admitted members get the
  secret-seam check `/assess` applies (a fix needing a credential with no
  confirmed supply seam parks, never merges), and a member-bearing chunk's
  merge pass runs `gate.sh` regime selection — a correlated/risky set is
  offered modally, never auto-merged on a timer.
- **Epic-closing gate**
  (`workflows/scripts/build/sweep-epic-closing-gate.sh`,
  `sweep-epic-review-population.sh`): each run ends by reviewing the
  run's Operational-epic population; a fully-drained parent is offered
  for close (attended) or recorded once to the pending-decisions surface
  (unattended); `keep-open`-marked epics are reported, never offered.

**Rollout (single-board adopter): flip the setting, do one supervised
sweep run.** The capability ships default-off behind the per-checkout
setting `SWEEP_ADMIT_OPERATIONAL_EPICS`
(`workflows/scripts/build/build.config.sh`; per-checkout because the
config file has no board axis). To adopt: set
`: "${SWEEP_ADMIT_OPERATIONAL_EPICS:=1}"` in the gitignored,
sync-preserved `build.config.local.sh` sibling, then run one attended
`/sweep` and watch the pool report — it names every admitted member and
its acceptance text, so the first run is informed named-set consent, not
faith. Rollback is config-only: flip it back off and pool selection is
byte-identical to the pre-feature behavior.

**Sync survival and the re-flip note.** A routine vendored config sync
overwrites the tracked `build.config.sh` back to its default-off line, so
a flip made by editing that tracked line directly does NOT survive a sync
— you would have to re-flip after every sync. Put the flip in
`build.config.local.sh` instead and no re-flip is ever needed: every
reader uses the belt-and-suspenders `${SWEEP_ADMIT_OPERATIONAL_EPICS:-0}`
form, so a sync that rewrites the tracked default can never silently turn
an operator's opt-in off mid-checkout
(`workflows/scripts/build/tests/test_sweep_admit_operational_epics_sync.sh`
is the acceptance proof).

## Integration

- `claude/commands/sweep.md` — pool admission, blocked-member deferral,
  the closing gate, and the setting-off discoverability advisory.
- `claude/commands/assess.md` — the operational-refusal guard (its
  refusal message links this page) and `--override-operational-refusal`.
- `claude/commands/triage.md` — `blocked_by` edge stamping, the
  `edges-considered` marker, and the per-epic routing note at
  materialization.
- `claude/work-class-policy.md` — the label taxonomy this partition keys
  on; its policy table's Operational path is `triage → sweep` (the
  BREAKING label-scope widening carried by this epic's changelog entry).
- `workflows/scripts/build/build.config.sh` /
  `build.config.local.sh` — the admission setting and its local
  override layer.
- `workflows/scripts/build/sweep-epic-admission.sh`,
  `assess-operational-refusal.sh`, `sweep-epic-closing-gate.sh`,
  `sweep-epic-review-population.sh`,
  `workflows/scripts/board/cycle-check.sh` — the script-backed halves,
  with their fixture tests beside them.
- `docs/adr/0030-work-class-routes-operational-epics-through-sweep.md`
  and `docs/adr/0031-durable-logical-order-lives-on-the-board-as-blocked-by.md`
  — the architectural record.
- Deferred, deliberately not cut over by this feature: the autonomous
  pipeline tiers still route Operational epics through the ceremony path
  (temperloop#1848), and retro's acceptance read for sweep-driven members
  is temperloop#1849 (retro reads sweep-driven member acceptance).

## Resource impact

Per sweep pool build with the setting on: one label read for each
candidate epic parent plus each of its members, a plan-note probe, and an
`edges-considered` marker check — bounded by the board's open Operational
epics and their member counts, all through the board adapter's cached
resolve. The closing-gate review adds one end-of-run pass over the run's
epic population. No new daemons, no new polling, no new storage. With the
setting off (the default), the admission predicate short-circuits and
sweep's pool build is behavior-identical — and cost-identical — to the
pre-feature path.

## Telemetry

The closing gate's per-run tally — `epics_reviewed` / `epics_closed` /
`epics_left_open` — rides the existing `emit-command-run.sh` record on
the `command-runs` stream as a purely additive schema extension (the
code-emitted execution signal for the gate; the report line is only the
human surface). `workflows/scripts/telemetry-brief.sh` § 2b reads epic
funnel health class-conditionally: a Foundational epic's healthy path is
epic → plan → built (from the `item-efficiency` rollup), an Operational
epic's is epic → members-drained-via-sweep (from the closing-gate tally),
so plan-note absence on an Operational epic can no longer read as
stalled-unassessed. No new telemetry stream — both reads consume records
already in the lake.
