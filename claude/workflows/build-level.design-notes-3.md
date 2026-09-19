# build-level.mjs — design notes

Extracted from `claude/workflows/build-level.mjs` (temperloop#2126). The module
is invoked by the Workflow tool via `scriptPath`, which refuses a file over
524288 bytes; PR #2125 pushed it to 554776 and the pipeline stopped loading. The
notes below were moved out verbatim to reclaim headroom. **Nothing here is
decoration** — each one records why a mechanism exists, and several were cited
directly by review agents. Each extraction site in the module carries a one-line
summary plus a pointer to its anchor here.

Keep a note with its code: when you change the mechanism, change its note.

**Never extract a MACHINE-PARSED comment block.** Two blocks in the module are
read by tooling, not by people: the `HANDOFF-CAPABILITIES-BEGIN`/`-END` sentinel
pair that `workflows/scripts/build/handoff-capability.sh` parses, and the
`hostConfigDeferralSection()` rationale that `test_workflow.sh` pins by string.
Both were moved here during the first extraction and both had to be put back —
the first silently turned every `/fix`, `/sweep` and `/build` Step 0 capability
probe into `CAPABILITIES_INDETERMINATE`. A comment is not automatically prose.

> **Part 1 of 3.** Split to stay under the repo's per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes-2.md`](build-level.design-notes-2.md), [`build-level.design-notes-3.md`](build-level.design-notes-3.md).

> **Part 3 of 4.** Split to stay under the repo's per-file prose cap
> (`PROSE_BUDGET_TIER2_FILE_CAP`). Other parts: [`build-level.design-notes.md`](build-level.design-notes.md), [`build-level.design-notes-2.md`](build-level.design-notes-2.md), [`build-level.design-notes-4.md`](build-level.design-notes-4.md).

## gateCmd(startAt) — one SLICE of the suite (temperloop#1021).
<a id="gatecmd-startat-one-slice-of-the-suite-temperloop-1021"></a>

```text
 gateCmd(startAt) — one SLICE of the suite (temperloop#1021).

 The budget is handed to quality-gates.sh as ENV VARS, deliberately not
 flags: a consuming repo vendoring an OLDER quality-gates.sh ignores an
 unknown env var and runs the whole suite in one go (today's exact behavior,
 and still correct), whereas an unknown FLAG would exit 2 "usage" and read
 back here as a gate failure. So this is compatible with every vendored copy
 in the fleet with no probing.

 Exit-code protocol: 0 = finished green, 75 = budget spent with gates
 remaining (the script printed QUALITY_GATES_RESUME_AT= / QUALITY_GATES_FAILED=),
 anything else = red. Note the 75 arm is only ever taken by a slice-aware
 script, so an older copy can only ever produce GATE_PASS / GATE_FAIL.

 `set -o pipefail` is LOAD-BEARING (temperloop#68 — see build.md §3e.5).
 The gate verdict is derived from the subshell's own exit status, and since
 temperloop#2094 that subshell IS piped — through `tee`, so one slice's
 output can be isolated for trailer parsing while still STREAMING into the
 cumulative operator log (see gateSliceLog below for why both are required).
 A bare pipe's status reflects the LAST stage (tee's 0), which would swallow
 a RED gate and degrade 3e.5 to a silent no-op; with pipefail set, the gate's
 own non-zero exit propagates to `$?` and GATE_FAIL is still emitted. This is
 the exact case build.md §3e.5 permits ("if the gate must be piped, `set -o
 pipefail` first"), and the exit is read as a bare `$?` — NOT through
 PIPESTATUS[0], a bash array that expands empty under the zsh this harness's
 Bash tool actually runs, which is temperloop#801's misread.

 The log is truncated on the first slice and APPENDED to thereafter, so
 /tmp/qg-<slug>.log stays the single artifact an operator reads, carrying the
 union of every slice exactly as an unsliced run's log did.
```

## ONE SLICE'S OWN OUTPUT, kept separate from the cumulative log above
<a id="one-slice-s-own-output-kept-separate-from-the-cumulative-log"></a>

```text
 ONE SLICE'S OWN OUTPUT, kept separate from the cumulative log above
 (temperloop#2094). The trailers below (`QUALITY_GATES_FAILED=`,
 `QUALITY_GATES_RESUME_AT=`, `QUALITY_GATES_SELECTION=`) are read with
 `tail -1`, so reading them out of the APPENDED log silently answers a
 question about THIS slice with the previous slice's numbers whenever this
 slice printed none of its own — a slice killed before it could report, or
 one whose `cd`/`unset` prelude failed, inherits a resume point and a
 failure count it never established. The trailers are therefore parsed from
 HERE, never from the cumulative log: a trailer present in this file was
 printed by the slice just run, which is what makes the classifier below
 able to trust it.

 IT IS A TEE, NOT A REDIRECT-THEN-COPY (review round 1). Writing the slice
 to this file and `cat`-ing it into ${gateLog} afterwards bought the
 isolation above at the cost of the guarantee that matters most on the one
 path that has no other diagnostic: the executor KILLS this whole command at
 GATE_BASH_TIMEOUT_MS, and a copy step scheduled after the gate never runs.
 The killed slice's partial output — the only evidence a timeout produces —
 would never reach /tmp/qg-<slug>.log, the single artifact the escalation
 payload hands the operator; and with the first-slice truncation moved into
 that same copy, a timed-out first slice would leave the PREVIOUS run's log
 in place and the escalation would point at stale content presented as
 current. So ${gateLog} is truncated UP FRONT on slice 0 and the gate streams
 into both files through `tee` — per-slice isolation and live, kill-proof
 streaming at once. `set -o pipefail` is at the head of the command, so the
 pipeline's `$?` is still the gate's own status (`tee` exits 0); the bare
 `$?` read is deliberate and dialect-safe — PIPESTATUS[0] is a bash
 array that expands EMPTY under the zsh this harness's Bash tool runs
 (temperloop#801), which is the misread that swallows a red gate.
```

## temperloop#1663: run the acceptance gate DIFF-SCOPED — only the gates 
<a id="temperloop-1663-run-the-acceptance-gate-diff-scoped-only-the"></a>

```text
 temperloop#1663: run the acceptance gate DIFF-SCOPED — only the gates this
 item's own changed paths can reach, resolved through gate-paths.tsv.

 WHY. The full per-item suite could not survive within-level parallelism, and
 the ceiling it hit is not tunable. Measured on a 3-item level: 55 minutes,
 21 agents, 1.24M subagent tokens, ZERO items landed — all three escalated
 `acceptance-gate-timeout` with every worker finished and committed and only
 the verdict missing. Three concurrent full suites is 3x QUALITY_GATES_JOBS
 workers on one machine; contention inflated the gate tail 200-300% (gates
 that take seconds took 121s), while GATE_SLICE_SECS_MAX sits only 20% above
 the budget that failed and CANNOT be raised past AGENT_BASH_CAP_MS. So the
 suite has to get SHORTER, not the budget longer — and the map that knows
 which gates a diff can reach already exists and was already trusted.

 WHY IT IS SAFE. This puts §3e.5 on exactly the same footing as the
 `pull_request` run of CI's `checks` job, which has been scoped through this
 same map since #1024 — so scoping here adds no failure mode that the PR
 check does not already carry. What actually gates `main` is the UNSCOPED
 merge_group run, and that is untouched. Every resolution failure in the
 selector widens to the full set (gate-selection.sh's four silent-green
 defenses), and a scoped run names every gate it skipped, twice.

 THE SEAM IS AN ENV VAR, NOT THE `--scoped` FLAG, for the same reason the
 slice budget below is: a consuming repo vendoring an OLDER quality-gates.sh
 ignores an unknown env var and runs the whole suite (the pre-#1663 behavior,
 still correct), whereas an unknown FLAG exits 2 "usage" and reads back here
 as a GATE FAILURE.

 BUILD_GATE_SCOPED is read HERE, in the emitted shell, rather than plumbed in
 as an orchestrator `input.*` key like gateSliceSecs. That is deliberate and
 is the narrower seam, not a shortcut: gateSliceSecs must reach the .mjs's
 OWN control flow (it derives GATE_BASH_TIMEOUT_MS and bounds the slice
 loop), and the Workflow runtime has no shell to source build.config.sh with
 — DESIGN NOTE 1. This value is needed ONLY inside the command string, which
 is bash, and it is read from the WORKTREE'S config, i.e. the version of the
 setting the change under test actually ships. The read is a subshell so the
 #1241 scrub below still governs the gate's own environment; an absent or
 older config file leaves `${BUILD_GATE_SCOPED:-1}` at the default.
```

## 3f-1. Push-by-SHA on the plan's branch.
<a id="3f-1-push-by-sha-on-the-plan-s-branch"></a>

```text
 3f-1. Push-by-SHA on the plan's branch.

 `--allow-rewrite` (temperloop#2103): 3f-0a above has just REWRITTEN this
 branch's history onto a fresh origin/<default>, and on a continuation round
 an earlier round has already pushed the pre-rebase history to origin. A
 plain push of a rewritten, already-pushed branch can NEVER fast-forward, so
 it came back PUSH_REJECTED every time — observed three times in one session,
 each recovered by hand with a lease-force push. The `recovery && pushed`
 skip above only covers the temperloop#939 lost-return path; an ordinary
 continuation round is not a `recovery` and never took it.

 This is a REQUEST, not a force: pr.sh downgrades to a plain push on any
 provable fast-forward (#335), issues nothing at all when the ref is absent
 or unreadable, and when it does rewrite it uses
 `--force-with-lease=<ref>:<sha>` over a value it read first — so a
 concurrent writer is rejected rather than overwritten. The flag is spelled
 `--allow-rewrite` rather than `--force` so the command line the orchestrator
 executes carries no classifier-visible force token (#437).

 AND NOT ON THE LEASE ALONE (temperloop#2103 round 3). Because this call site
 requests a rewrite on EVERY item — not only on a rescue — it is the busiest
 force path in the pipeline, and a lease protects only against a writer who
 moves the ref BETWEEN pr.sh's read and its push, never against content that
 was already there. So pr.sh gates the force on the SAME supersede check
 preserveCommittedWorkCmd (below) applies on the rescue path: a branch name
 colliding with unrelated work — a leftover manual branch, a reused slug, a
 planning bug — comes back PUSH_REJECTED with `refused_reason` rather than
 being overwritten and reported as an ordinary PUSHED straight into pr-open.
 The two force paths this file drives are symmetric; the asymmetry between
 them was the round-2 finding.
```

## 3f-2 FALLBACK: a PR-ready tree must not be stranded by a bad verdict
<a id="3f-2-fallback-a-pr-ready-tree-must-not-be-stranded-by-a-bad-"></a>

```text
 --- 3f-2 FALLBACK: a PR-ready tree must not be stranded by a bad verdict --
 temperloop#1805, disposition (a). `pr.sh open` REQUIRES a parseable
 `--verdict` and dies `verdict is not valid JSON` when it does not get one.
 That is a REPORTING-layer failure, and it was terminal for the item:

   {"slug":"disclosure-watermark-tracked-1316","kind":"pr-open-failed",
    "payload":{"openOut":{"step":"pr-open","outcome":"ERROR",
                          "error":"verdict is not valid JSON"}}}

 …against ONE clean commit, a zero-dirty tree, a full `.build-verification.md`
 and that item's own suite green 39/39. The orchestrator recovered it BY HAND
 — push, `gh pr create`, verification file as the body — and it became PR
 #1803. Every piece of information the PR needed was already on disk; only
 the hand-off failed. The preservation machinery means the commit survives,
 so this is not data loss — it is PROGRESS loss: the item parks, re-enters
 the next run, and a fresh worker redoes finished, correct work.

 So the fallback re-issues `open` with a MINIMAL, structurally-safe verdict:
 the title is the item's own (what `--title` already carried) and the body
 comes from `.build-verification.md` via the surface flag — exactly the shape
 the manual recovery used. Everything variable about the rich verdict —
 `acceptance_results`, the worker's own prose — is dropped, because that is
 precisely the content that failed to survive the hand-off; the §3e review
 evidence line is kept, since it is assembled by this file and must stay
 visible on the PR (temperloop#1430).

 A body-less fallback would be worse than the escalation, so it is attempted
 ONLY when there is a real surface to fall back ON — either the worktree file
 or the synthesized inline surface.
```

## ======================================================================
<a id="note-2"></a>

```text
 =============================================================================
 levelPhaseTitle — the run-identifying progress-row heading (temperloop#903),
 now emitted ONCE PER STAGE rather than once per level (temperloop#1294).
 =============================================================================
 The Workflow progress UI renders one row per workflow (labelled from the PURE
 LITERAL `meta.description`, which by runtime constraint is byte-identical on
 every run) plus a group heading per phase(). phase() is therefore the ONLY
 surface that can carry run context — and it used to read `build level — N
 item(s)`, which identifies nothing: not the repo, not the items, not the
 issues. Two concurrent spine runs (routine: one /fix session drives several
 back to back) rendered indistinguishable rows.

 The heading names, from context already in scope at the call site:
   build level · <stage> — <ownerRepo> · <N> item(s) · <slug> (#<ghIssue>), …
 e.g.  build level · gate — Towheads/foundation · 1 item · row-per-stage (#1294)

 temperloop#1294 added the `· <stage>` segment and made the level emit ONE
 phase() PER STAGE (claim → build → gate → PR → CI) instead of a single static
 heading for the whole level. Two independent effects, both wanted:
   • the ACTIVE phase now ADVANCES as the level progresses, so a collapsed view
     that renders it moves instead of sitting on one heading all run;
   • the expanded progress tree groups agents by stage instead of dumping every
     executor into one 'machinery' box.
 The #903 run context rides EVERY stage heading — dropping it from the later
 stages would re-open exactly the complaint #903 closed.

 TWO SURFACES, ONE STRING. `phase(t)` moves the GLOBAL cursor (what a collapsed
 view shows); `agent(…, {phase: t})` assigns one agent to the group named `t`.
 The Workflow docs are explicit that the global cursor RACES inside
 parallel()/pipeline() stages — this level fans its items out with parallel(),
 so item A can be at CI while item B is still at build. Every agent spawn below
 therefore passes opts.phase EXPLICITLY (same string → same group box) and never
 relies on whatever the global cursor happens to be. enterStage() returns that
 string and, as a side effect, advances the global cursor MONOTONICALLY (a stage
 already passed never re-fires), so the collapsed row tracks the level's
 furthest-reached stage and can never appear to run backwards when a straggler
 item is still on an earlier one.

 meta.phases: DELIBERATELY ABSENT. `meta` is a pure literal by runtime
 constraint, and meta.phases entries are matched against phase() titles
 EXACTLY. Every title here is dynamic by construction (#903 requires the repo,
 the item count and the item/issue list in it), so no static entry could ever
 match one — declaring the five stages statically would render five permanently
 EMPTY groups alongside the five real ones. Per the runtime's own contract a
 phase() call with no matching meta entry simply gets its own progress group,
 which is the correct outcome here; this is a noted, accepted consequence of
 #903's dynamic-title requirement, not an oversight to work around.

 BOUNDED BY CONSTRUCTION: a level can hold many items, so at most
 PHASE_TITLE_MAX_ITEMS slugs are named and the rest collapse to `+K more` — a
 20-item level can never emit a 20-slug heading that swamps the progress row.
 Every field is optional-safe (a missing ownerRepo / ghIssue simply drops its
 segment) because this is a cosmetic display string: it must never be the thing
 that throws and takes a level down.
```

## `$branch` goes into the hand-built JSON below through a bare printf
<a id="branch-goes-into-the-hand-built-json-below-through-a-bare-pr"></a>

```text
 `$branch` goes into the hand-built JSON below through a bare printf
 `%s`, deliberately NOT through the `jq -R -s -c .` idiom reviewDiffCmd
 uses for tsv_lines/files. The reason it is safe here: this is the PLAN's
 `branch:` field, which plan-schema pins to `<type>/<slug>` with type in
 a closed set {feat,fix,chore,refactor,docs,test} and slug kebab-case
 ([a-z0-9-]+), validated at Step 1 — so it carries neither a double quote
 nor a backslash. Note what is NOT an argument: `git check-ref-format`
 bans a backslash in a ref name but ACCEPTS a double quote
 (`git check-ref-format 'refs/heads/build/a"b'` exits 0), and a double
 quote alone terminates a JSON string. The ref grammar is therefore not a
 JSON-safety guarantee; the plan schema is. Adding jq would also put a new
 binary dependency on the one path whose entire job is to work when things
 are already failing — the opposite of fail-soft.
 Nothing committed beyond a RESOLVED base — 3f never ran and never needed
 to. Pushing here would mint an empty remote branch for no benefit.
```

## 3e.5 gate verdict reconciliation (temperloop#1587)
<a id="3e-5-gate-verdict-reconciliation-temperloop-1587"></a>

```text
 --- 3e.5 gate verdict reconciliation (temperloop#1587) ----------------------
 The defect this pair of helpers closes: the slice loop maintained TWO
 independent failure counters — an accumulated `gateFailed` and the terminal
 slice's own `gateOut.failed` — and shipped BOTH in one escalation payload
 (`{gateOut:{outcome:'GATE_PASS',failed:0,…}, failedGates:1}`). A consumer
 that trusted either field acted on a fiction: the kind said the gate failed,
 the embedded object said it passed. Two counters that CAN disagree is the
 defect, not merely the run on which they did — so there is now exactly ONE
 record of failure (the per-slice ledger the loop appends to) and every
 figure reported anywhere — `failedGates`, the verdict, the escalation kind,
 the reason prose — is DERIVED from it by gateVerdict() below. No second
 counter is maintained, and the raw terminal `gateOut` (whose `failed` was
 the contradicting field) is no longer embedded in the payload: its content
 survives as the ledger's last entry, which cannot disagree with the sum of
 the ledger it is part of.
```

## gateSliceFailed(out) — the failure count ONE slice actually ESTABLISHE
<a id="gateslicefailed-out-the-failure-count-one-slice-actually-est"></a>

```text
 gateSliceFailed(out) — the failure count ONE slice actually ESTABLISHED.
 This is the only place a slice's failure count is read, so the ledger's
 entries are normalized on the way in rather than clamped at each reader:
   GATE_SLICE — the count the suite's own `QUALITY_GATES_FAILED=` trailer
                reported for that slice (exit 75 always prints it).
   GATE_FAIL  — a RED suite by construction, so the floor is 1: an unparseable
                or stale trailer must never produce a "failed, 0 failures"
                ledger entry (the mirror image of #1587's contradiction).
   everything else (GATE_PASS / GATE_ABSENT / GATE_TIMEOUT) — 0. A pass is
                zero by construction; a TIMEOUT establishes NOTHING (the slice
                was killed before it could report), and unknown-ness is carried
                by the verdict, never smuggled into a count.
```

## gateSliceResumeAt(out) — the 0-based gate index ONE slice said the sui
<a id="gatesliceresumeat-out-the-0-based-gate-index-one-slice-said-"></a>

```text
 gateSliceResumeAt(out) — the 0-based gate index ONE slice said the suite
 still has to reach, or undefined when it reported none (temperloop#2094).

 Read off the outcome REGARDLESS of its kind, deliberately. `suiteFinished`
 is a claim about whether every gate ran, and the only evidence anyone has
 for that is the suite's own `QUALITY_GATES_RESUME_AT=` trailer; deriving it
 from the terminal outcome's NAME instead is what let a run that stopped at
 gate 152 of 200 ship `suiteFinished: true`. A resume point is that claim's
 direct counter-evidence whether the slice carrying it was classified
 GATE_SLICE or (as in the #2094 incident) something else.

 `0` is not a resume point: the trailer is only ever printed with gates
 REMAINING, so a 0 here is an unparsed/absent field, not "resume at gate 0".
```

## A resume point in the LAST ledger entry is direct evidence that gates
<a id="a-resume-point-in-the-last-ledger-entry-is-direct-evidence-t"></a>

```text
 A resume point in the LAST ledger entry is direct evidence that gates
 remained when the run stopped, and it OVERRIDES the terminal outcome's own
 name (temperloop#2094). The incident: the final slice came back with an
 unexpected exit code and was classified GATE_FAIL, whose name put it in
 the `finished` set below — so an escalation for a run that stopped at gate
 152 of 200 reported `suiteFinished: true`, and the next reader had no way
 to tell a whole-suite verdict from a 76%-of-the-way-through one. The
 trailer is the only first-hand evidence about coverage that exists; a
 classification derived downstream of it can never outrank it.
```

## harnessCanSpawnAgents — the null-shape discriminator above. Memoizatio
<a id="harnesscanspawnagents-the-null-shape-discriminator-above-mem"></a>

```text
 harnessCanSpawnAgents — the null-shape discriminator above. Memoization is
 deliberately ASYMMETRIC (temperloop#1819 attempt-2 review finding 1): only a
 DEAD verdict is sticky. The quota is monotone within one exhaustion window —
 once every spawn dies, they keep dying — so one dead probe answers for the
 whole level's burst of deaths. (A window that resets mid-level could make the
 cached "dead" stale for a later item; that item still escalates with its work
 intact — exactly what the wait-then-resume disposition handles — so the dead
 cache stays.) An ALIVE verdict is NOT cached: "alive at probe time" says
 nothing about a spawn that dies LATER in the same level, and a memoized alive
 would misroute that later quota death back into machinery-denied/worker-error
 — the destructive mis-cure this whole classifier exists to prevent. So every
 bare-null re-probes; concurrent callers still share one in-flight probe (the
 promise is the cache entry until it resolves alive). Fails OPEN: an
 inconclusive canary (a non-quota throw) reads as "alive" so the pre-#1819
 kinds stand rather than inventing a quota verdict from a probe that merely
 misbehaved.
```

## DECIMAL, NEVER OCTAL (temperloop#1970, typescript-reviewer round 1). T
<a id="decimal-never-octal-temperloop-1970-typescript-reviewer-roun"></a>

```text
 DECIMAL, NEVER OCTAL (temperloop#1970, typescript-reviewer round 1). The
 `tr` filter strips non-digits but NOT leading zeros, and POSIX `$(( ))`
 reads a leading-`0` numeral as OCTAL — so a marker file someone
 hand-edited, or restored from a stale snapshot, holding `08`/`09` is not
 a wrong count but a HARD shell error that aborts the whole step and
 surfaces as exactly the `review-diff-error` escalation §3e is least able
 to act on. This code path cannot write such a value itself, but the file
 is an ordinary file in the worktree's git dir and the surrounding
 contract is explicit that every marker step fails SOFT — a
 corrupted-but-present marker was the one case that story did not cover.
 `sed -E 's/^0+//'` normalises to a bare decimal (an all-zeros value
 collapses to the empty string, which the `[ -n … ]` fallback below then
 reads as 0), so a corrupted marker degrades to "first round" exactly as a
 missing one does. `sed -E` over `\\?`-style BRE: the same portable dialect
 the `origin/` strip below already relies on.
```

## Trimmed-emptiness filter (`l.trim()`, not bare `l`) — matches
<a id="trimmed-emptiness-filter-l-trim-not-bare-l-matches"></a>

```text
 Trimmed-emptiness filter (`l.trim()`, not bare `l`) — matches
 reviewDiffCmd's bash `t != ""` check (`t` is the TRIMMED line) exactly,
 so a whitespace-only line is filtered identically on both sides. This
 deliberately does NOT reuse parseTsvRows's own first-stage filter (bare
 `l`), which answers a different question (is this a candidate data row
 for the routing decision) — tsvChecksum answers "did the bash side count
 this line," and those two must agree bit-for-bit or the checksum could
 disagree with a perfectly faithful relay.
```

## temperloop#2003 — SPAWN EVERY ROUTED REVIEWER FIRST, then wait on the 
<a id="temperloop-2003-spawn-every-routed-reviewer-first-then-wait-"></a>

```text
 temperloop#2003 — SPAWN EVERY ROUTED REVIEWER FIRST, then wait on the set
 under one wall-clock ceiling. Before this the pass awaited each reviewer in
 turn, so a single agent that never returned kept every LATER one from
 launching at all: in the observed incident the mandatory `workflow-reviewer`
 for a `claude/commands/*.md` diff was never spawned, because the reviewer
 ahead of it in the loop hung. Spawning is synchronous and in route order, so
 the call ORDER (what the journal and a resume's cached prefix key on) and
 the per-reviewer result ORDER are both byte-identical to the old loop's.
```

## No `schema` — a plain read-only advisory pass, not a machine-validated
<a id="no-schema-a-plain-read-only-advisory-pass-not-a-machine-vali"></a>

```text
 No `schema` — a plain read-only advisory pass, not a machine-validated
 verdict (build.md §3e: "docs-reviewer is advisory only ... never a
 checks gate entry"). Deliberately no `model` override either: the
 reviewer's OWN agent definition sets its tier (e.g.
 claude/agents/workflow-reviewer.md declares `model: sonnet`).

 The two-arm `.then` is the settlement RECORDER, not error handling: it
 makes each reviewer's own outcome readable WITHOUT awaiting it, which is
 what lets the ceiling below keep every settled reviewer's findings while
 abandoning only the unsettled ones. It also means a rejected reviewer
 promise is always handled, so a reviewer that throws after the ceiling has
 passed can never surface as an unhandled rejection.
```

## Pass 3 — apply the dispositions in ROUTE order, so `ran`/`skipped`/
<a id="pass-3-apply-the-dispositions-in-route-order-so-ran-skipped"></a>

```text
 Pass 3 — apply the dispositions in ROUTE order, so `ran`/`skipped`/
 `sections` and the log lines keep the ordering the single loop produced. A
 straggler is read ONE final time here, at the instant its skip would be
 written: that read, not the one after the await, is what decides a timeout.
 Exactly one disposition is written per slot, which is what keeps `ran` and
 `skipped` disjoint by construction — a recovered reviewer can never also
 appear as `timed_out`, and `mandatory_ok` (derived from `skipped`) reports
 what actually happened rather than what the ceiling guessed.
```

## disposeReviewSlot — the verdict for ONE SETTLED reviewer slot, as a pu
<a id="disposereviewslot-the-verdict-for-one-settled-reviewer-slot-"></a>

```text
 disposeReviewSlot — the verdict for ONE SETTLED reviewer slot, as a pure
 descriptor: `{ kind: 'ran', text }` or `{ kind: 'skip', note }`. Purity is the
 point (temperloop#2032): runReviewers reads its slots in more than one pass so
 a reviewer that settles late is still consumed, and a disposition step that
 pushed straight into `ran`/`skipped`/`sections` would emit those in
 settlement order instead of route order. The caller writes exactly one
 disposition per slot, in route order, which is what keeps `ran` and `skipped`
 disjoint. Never call it on an unsettled slot — `slot.done` is the caller's
 precondition, and the caller re-reads it as late as it possibly can.
```

## drainReviewSettlements — give every reviewer whose promise has already
<a id="drainreviewsettlements-give-every-reviewer-whose-promise-has"></a>

```text
 drainReviewSettlements — give every reviewer whose promise has already
 resolved the chance to RECORD that fact, then return. `slot.done` is set in a
 `.then` recorder, so a reviewer can be resolved-but-unrecorded for a few
 microtasks; this is the only honest way to read the fanout later than the
 instant an await hands back, and it is bounded by construction (no clock, no
 spawn, no wait). Used twice: before the ceiling's first timer spawn (a pure
 cost optimisation — a reviewer that already returned need not be paid for),
 and again by the disposition passes (temperloop#2032 — a reviewer that
 settled after the ceiling must not be reported as a timeout).
```

## reviewBoundReached(review) — the §3e convergence bound's ONE predicate
<a id="reviewboundreached-review-the-3e-convergence-bound-s-one-pre"></a>

```text
 reviewBoundReached(review) — the §3e convergence bound's ONE predicate
 (temperloop#1970), so both blocking call sites (the 3e pass and §3g's CI-fix
 re-review) ask the identical question and cannot drift apart. True when this
 round has blocking findings AND the item has spent its budget of review
 rounds: past that, the findings are CARRIED (PR body + parked tally) instead
 of escalating for another build-review round-trip. `review.round` is absent
 only on a return shape older than this item; `?? 1` then reads "first round",
 which can never trip the bound early.
```

## round 2 (MEDIUM, temperloop#1937): the outer Bash-tool timeout can kil
<a id="round-2-medium-temperloop-1937-the-outer-bash-tool-timeout-c"></a>

```text
 round 2 (MEDIUM, temperloop#1937): the outer Bash-tool timeout can kill
 gateFreshnessCmd() mid-`git rebase`, leaving a rebase in progress on
 disk. FRESHNESS_ERROR's fail-open is sound only when the fetch/resolve
 step never ran at all; here the tree may be mid-rebase, so proceeding
 blind is exactly the false-signal risk #1937 exists to prevent. Run the
 follow-up probe, abort any in-progress rebase it finds, and ALWAYS
 escalate `stale-worktree` — regardless of what the probe itself
 reports — never falling into the fail-open FRESHNESS_ERROR path.
```

## temperloop#2080 round-1 review [MEDIUM]. driveItemBuildPhase returns a
<a id="temperloop-2080-round-1-review-medium-driveitembuildphase-re"></a>

```text
 temperloop#2080 round-1 review [MEDIUM]. driveItemBuildPhase returns a
 TERMINAL record on two paths that mean OPPOSITE things: escalate() (a real
 failure) and — for kind:spike alone — park() (the read-only verdict marker,
 that item's NORMAL completion, and the only park() the build phase returns
 at all). Folding "any terminal record" into the loss path recorded a
 successful spike arm as `gate:'fail' loss_reason:'infra'`, corrupting
 exactly the ledger this feature exists to produce and making judgeArms
 report `one-arm-only` for a pair where BOTH arms finished. A spike creates
 no worktree and runs no gate, so this arm honestly carries no
 base_sha/guard/cost — but it completed, so it is a passing arm.
```

## judgeArms — the pairwise judge call, run AT the barrier (temperloop#20
<a id="judgearms-the-pairwise-judge-call-run-at-the-barrier-temperl"></a>

```text
 -----------------------------------------------------------------------------
 judgeArms — the pairwise judge call, run AT the barrier (temperloop#2073).
 -----------------------------------------------------------------------------
 One `judge.sh pairwise` per in-scope item whose TWO arms both gate-passed:
 record-a is the baseline arm, record-b is the candidate arm, and the script
 sends the same prompt twice in both position orders and reports
 { preference, margin, order_agreement }. The two record files are assembled
 in the executor's own shell from this driver's item metadata plus each arm's
 diff against its recorded base, because that diff exists only on disk.

 A judged item ALWAYS gets a DISPOSITION, never silence: a real verdict, or a
 named reason there is none (one arm never gated, the seam is absent, the
 judge refused or was unavailable). That is what makes "every in-scope item has
 a judge result" checkable at the barrier rather than a hope.
```

## THE VERDICT IS READ UN-PIPED (temperloop#2080 round-2 review [HIGH]), 
<a id="the-verdict-is-read-un-piped-temperloop-2080-round-2-review-"></a>

```text
 THE VERDICT IS READ UN-PIPED (temperloop#2080 round-2 review [HIGH]), the
 same shape activationProofCmd uses and for the same reason: `$?` after a
 pipeline is the LAST command's status, so `… | tail -1; __jr=$?` reads
 tail's status — effectively always 0 — and judge.sh's own exit never
 reaches the branch below. That mis-reads BOTH ways: a judge.sh that dies
 AFTER writing a line would have its garbage recorded as a real pairwise
 verdict, and the refusal's `rc` field — whose whole job is to report that
 status — would be structurally 0. So: capture whole, read `$?`, THEN trim
 to the last line in a separate step. Deliberately no PIPESTATUS (zsh
 spells it `$pipestatus` and 1-indexes it) and no `set -o pipefail` (see
 activationProofCmd's comment for why that is worse, not safer).
```

## appendDualBuildRows — the ledger write (temperloop#2072).
<a id="appenddualbuildrows-the-ledger-write-temperloop-2072"></a>

```text
 -----------------------------------------------------------------------------
 appendDualBuildRows — the ledger write (temperloop#2072).
 -----------------------------------------------------------------------------
 One `dual-build-ledger.sh append` per row, batched into ONE executor for the
 item (two rows in scope, one row out of scope). Three of the row's fields
 cannot be known in this runtime and are filled by the executor's own shell
 from the arm's worktree:
   cross_read_attempted — whether the arm-read guard recorded a DENIED
                          cross-arm read beside the `.dual-build-arm` marker;
   head_sha             — the arm branch's tip, which exists only on disk;
   machinery_version    — the checkout's VERSION, the join key K#1924's own
                          per-step resume ledger uses.
 Everything else is composed here, in legible .mjs, and handed over as a JSON
 literal — the same division of labour every other machinery call in this file
 uses (DESIGN NOTE 1: the branching stays here, the shell only executes).
```

## driveLevelDualBuild — the level driver, and the BARRIER itself.
<a id="driveleveldualbuild-the-level-driver-and-the-barrier-itself"></a>

```text
 -----------------------------------------------------------------------------
 driveLevelDualBuild — the level driver, and the BARRIER itself.
 -----------------------------------------------------------------------------
 Three phases, in this order, and the order IS the contract:
   1. BUILD. Every item in parallel. An in-scope item fans out two arms and
      stops at the end of phase 1; a not-in-scope item takes the ordinary
      single-arm driveItem, PR and all.
   2. THE BARRIER. The `await` on phase 1 is the barrier — past it, EVERY
      in-scope arm in the level has a gate result. Only now does any judging
      happen, and no PR has opened for any in-scope item.
   3. JUDGE + RECORD. Per item: the pairwise judge, then the ledger rows, then
      the item's own record. Still no PR for an in-scope item — routing the
      winner to PR is `level-pick-and-operator-levers`.
```

## The IN-SCOPE throw (the not-in-scope branch carries its own catch
<a id="the-in-scope-throw-the-not-in-scope-branch-carries-its-own-c"></a>

```text
 The IN-SCOPE throw (the not-in-scope branch carries its own catch
 above, so this is what it adds). `escaped` marks a run that produced
 NO arms: phase 3 hands its record straight to the level's disposition
 rather than judging arms that do not exist or inventing a
 not-in-scope ledger row for an item that IS in scope. No
 preserveOnEscalation here on purpose — an in-scope item's commits
 live in `<slug>@baseline` / `<slug>@candidate`, not the `<slug>`
 worktree that helper pushes from, so calling it would push the wrong
 (or an absent) tree.
```

## Continuation detection (escalation-resume loop, 3d-esc)
<a id="continuation-detection-escalation-resume-loop-3d-esc"></a>

```text
 --- Continuation detection (escalation-resume loop, 3d-esc) --------------
 On a 3d-esc continuation the orchestrator re-invokes this workflow with
 input.onlySlugs = [<this slug>, ...] and input.verdicts[<slug>] carrying the
 human's captured decision. A continued item's worktree + .build-guard
 marker are ALREADY in place (the escalation left them intact) and its
 board issue is ALREADY claimed — so we MUST NOT re-run 3a (claim) or 3b
 (worktree.sh create force-recreates the path, discarding the escalated
 build, MINOR fix). We resume at 3c, injecting the captured verdict so the
 re-spawned worker sees the human's decision instead of re-forking forever
 (MAJOR fix). verdicts map shape: { [slug]: { kind, verdict_section } }.
```

## PRELUDE (3a claim + 3b-0 deps-merged + 3b worktree create)
<a id="prelude-3a-claim-3b-0-deps-merged-3b-worktree-create"></a>

```text
 --- PRELUDE (3a claim + 3b-0 deps-merged + 3b worktree create) ------------
 ONE batched executor agent for the whole per-item mechanical prelude
 (temperloop#942) instead of one agent spawn per command. Ordering, skip
 conditions and every branch below are unchanged — only the transport is.
 The batch's own bash short-circuit refuses to run a later step once an
 earlier one's outcome means it must not (a failed claim never reaches
 worktree create; an unmerged dep never creates a worktree), so the results
 array is simply shorter and the .mjs escalates on the step that stopped it.
```

## Nothing COMMITTED → this is the ordinary stall. Retry exactly once,
<a id="nothing-committed-this-is-the-ordinary-stall-retry-exactly-o"></a>

```text
 Nothing COMMITTED → this is the ordinary stall. Retry exactly once,
 appending FOREGROUND_CURE so the retry prompt DIFFERS from the first — a
 byte-identical retry re-stalls identically. A 5xx is transient (the extra
 section is harmless); a stall is cured by it.

 temperloop#993 — MECHANICAL detection of the incomplete-return shape:
 no verdict AND the worktree dirty with zero commits is the backgrounded-
 gate stall specifically (not a worker that never started). The probe
 reports it as RECOVER_DIRTY, and the auto-resume carries the dirty-resume
 note on top of the cure so the re-spawn CONTINUES on the work already in
 the worktree instead of rebuilding it. Detection is mechanical here so the
 prose clause in the worker prompt (prevention) is not the only guard —
 build.md §3c/§3d stay in lockstep with this block.
```

## ======================================================================
<a id="note-3"></a>

```text
 =============================================================================
 The ZERO-DISPOSITION guard (temperloop#2004).

 /build Step 3, /fix Step 4a and /sweep Phase 2 all branch on the returned
 {parked, escalations}: each handles `parked` non-empty and `escalations`
 non-empty, and NONE had an arm for both being empty. A {parked:[],
 escalations:[]} return therefore matched no branch and fell through as "the
 level completed with nothing to report" — so an item that was asked for and
 disposed of nowhere vanished with no PR, no park, no escalation and no
 signal. (Observed 2026-09-13, run wf_f3b9c160-6ca: a stopped-and-resumed run
 returned an empty object in ~13 ms having re-run nothing, while the tracked
 issue was still in-progress with a live claim stamp.)

 The guard lives HERE, below the three drivers, so all three inherit it once
 rather than each restating it — the same hoist shape temperloop#2006 used
 for the sideline notice. It returns a NAMED, branchable value (never a bare
 throw): the drivers re-probe real state on it instead of concluding
 anything.

 The two CONTROLS are what make it discriminating rather than noisy — a guard
 that flags every legitimately empty level is worse than none:
   1. nothing was asked to drive (empty `items`, or an onlySlugs filter that
      matched no item) → disposing of nothing is a tautology, not a
      contradiction. Silent, and the returned object is byte-identical to
      before this item.
   2. something WAS disposed → any parked record or any escalation means the
      drive reported on the set. This is also what clears the kind:spike
      path: a spike opens no PR and pushes no SHA, but it still `park()`s a
      verdict marker (`park(slug, null, null, …)`), so a spike-only level
      lands in control 2 and is never flagged.
 Returns null when either control holds; otherwise the named outcome.
 =============================================================================
```

## Drive every active item through 3a–3h. The items in one level are
<a id="drive-every-active-item-through-3a-3h-the-items-in-one-level"></a>

```text
 Drive every active item through 3a–3h. The items in one level are
 independent by construction (no merge edge between them), so we fan them
 out with parallel() — the substrate caps concurrency (~cores-2). This
 matches build.md's "express each item's pipeline as a parallel() over
 the level's items" (within-level execution). parallel() returns the array
 of per-item results in item order; a blocked/failed item escalates rather
 than halting its siblings (the orchestrator batches escalations at the
 boundary). On a continuation run only the named slugs enter parallel(); the
 rest are already parked and are left untouched.
 A thrown exception in driveItem must NOT vanish: parallel() drops a rejected
 thunk to null, which would leave the item in NEITHER parked NOR escalations —
 silently lost, violating the no-silent-stall invariant. Convert any throw into
 a generic `worker-error` escalation so it always surfaces. (#437: a real run
 hit item.acceptance.map on a string and the item was silently dropped.)
 temperloop#2020: `.then(preserveOnEscalation)` is applied to the SETTLED
 result — after the #437/#1819 catch above, so a THROWN item's synthesized
 escalation gets the same work-preservation push a returned one does. This
 is the single choke point for "an escalation is about to leave this
 driver"; see preserveOnEscalation's own comment for why it lives here and
 not at the ~30 individual escalate() call sites.

 temperloop#2080 — the DUAL-BUILD fan-out is an alternative to this one, not
 a flag inside it. A `dualBuild` input restructures the level into build →
 barrier → judge → record (driveLevelDualBuild), which is a different
 control flow, not a different parameter; keeping the two apart is what
 makes "no dualBuild input → this exact fan-out, unchanged" true by reading
 the code rather than by tracing a branch through it.
```

## machineryBin — resolve a build-SPINE script (worktree.sh / pr.sh / ci-
<a id="machinerybin-resolve-a-build-spine-script-worktree-sh-pr-sh-"></a>

```text
 machineryBin — resolve a build-SPINE script (worktree.sh / pr.sh / ci-poll.sh),
 which lives in the FOUNDATION repo (workflows/scripts/build/). A consuming repo
 (stageFind) normally reaches it via a dev-local `workflows/` symlink into
 foundation — but that symlink is NOT guaranteed in every checkout (#560: a
 stageFind checkout lacking it escalated at pr.sh with `push-error: script path
 does not exist`). We run in the Workflow sandbox (no fs / Node API), so the
 fallback is done in BASH, emitted as a quoted command-substitution: prefer
 <repoRoot>/workflows/scripts/build; if that dir is absent, locate the
 foundation checkout via $FOUNDATION, the deployed workflow symlink
 ($HOME/.claude/workflows/build-level.mjs → foundation, best-effort — a BSD
 readlink without -f just fails that candidate), or the TEMPERLOOP_HOME
 bootstrap-clone convention (bin/bootstrap.sh's own default,
 $HOME/.local/share/temperloop — never a hardcoded personal dev path,
 temperloop#406; the legacy FOUNDATION_HOME fallback was removed in
 v0.19.0 with the rest of the temperloop#165 window). If none resolve, the
 emitted path points at the missing
 repo-local dir and the machinery script's own "not found" (exit 127) surfaces
 loudly. NOTE:
 only machinery scripts route through here; the project's OWN vendored gate
 (scripts/quality-gates.sh) is repo-local and is resolved directly against
 the WORKTREE checkout (see 3e.5, temperloop#626), never via this fallback.
```

## ONE MEANING, ONE NAME — the machinery-outcome key canonicalizer (tempe
<a id="one-meaning-one-name-the-machinery-outcome-key-canonicalizer"></a>

```text
 -----------------------------------------------------------------------------
 ONE MEANING, ONE NAME — the machinery-outcome key canonicalizer (temperloop#1698).
 -----------------------------------------------------------------------------
 The closed outcome set carries TWO names for one concept. The step-liveness
 bound (temperloop#1071) emits `elapsed_secs` / `ceiling_secs` / `slow_secs`;
 the 3e.5 gate emits `elapsedSecs` / `budgetSecs`; and the permissive
 passthrough schema admits BOTH on ANY outcome. An executor that normalizes a
 GATE_PASS toward the sibling spelling therefore produces a structurally VALID
 object that the consumer — `Number(gateOut.elapsedSecs) || 0` — reads as
 `Number(undefined) || 0` → **0**. Observed live (run wf_9ce4bd0c-58b): a gate
 whose own log said "passed in 215s" was reported as "0s of gate wall time".

 That figure is the DECAY SIGNAL — the instrument whose whole job is to make
 suite growth visible on GREEN runs, before it blows a budget (the failure
 #1021 and #1663 both exist because of). An instrument that reads zero when it
 does not know is worse than one that reads nothing.

 The fix is a single normalization at the TRANSPORT boundary rather than a
 `??` chain at each read site (which re-opens the defect for the next field):
 CANONICAL = camelCase, everywhere downstream of here. The snake_case key is
 left in place on the object — it is what the emitted shell actually prints and
 what escalation payloads echo verbatim — but no CONSUMER in this file reads it
 any more, so the two spellings can no longer disagree about one value.
```

## runMachineryBatch — the BATCHED sh() replacement (temperloop#942).
<a id="runmachinerybatch-the-batched-sh-replacement-temperloop-942"></a>

```text
 -----------------------------------------------------------------------------
 runMachineryBatch — the BATCHED sh() replacement (temperloop#942).
 -----------------------------------------------------------------------------
 Runs SEVERAL machinery commands inside ONE executor agent (one Bash
 invocation), returning each step's own closed-outcome JSON object so the
 driver keeps branching per-step in .mjs. See DESIGN NOTE 1 for why this does
 not weaken the bridge's invariant.

 A step is { kind, cmd, continueOutcomes?, stopGlobs? }:
   kind             — a short name; it appears in the prompt's `Steps:` manifest
                      and in a denial payload, and is what the .mjs indexes by.
   cmd              — the fully sq()-quoted command text, byte-identical to what
                      the un-batched runMachinery call used to send.
   continueOutcomes — the outcome(s) that permit the NEXT step to run. Anything
                      else stops the sequence (the .mjs then branches on this
                      step's object and escalates, exactly as before).
   stopGlobs        — the inverse form, for a step with no `outcome` key (the
                      merge-state probe): raw substrings that, if present, stop
                      the sequence.
 The last step needs neither — nothing follows it.

 The bash short-circuit is a STOP-EARLY MIRROR, not the decision: it only
 avoids running steps whose result the .mjs is about to discard anyway. The
 authoritative branch is always the `if` in .mjs reading the same JSON.
```

## gateRegistrationChecklistSection — the §3c "new gate script? register 
<a id="gateregistrationchecklistsection-the-3c-new-gate-script-regi"></a>

```text
 gateRegistrationChecklistSection — the §3c "new gate script? register it"
 checklist (temperloop#1931), a SELF-CONTAINED section appended once into
 workerPrompt()'s array, mirroring discriminationEvidenceSection()'s shape.
 UNGATED, like hostConfigDeferralSection() — every /build, /sweep and /fix
 worker can add a new check-*.sh/validate-*.sh/test_*.sh, so every worker
 needs the checklist, not just an opted-in caller.

 WHY THIS EXISTS: #1931's observed instance — three of five workers in one
 /build level shipped a new validator/test that went RED on
 validate-check-surface-degenerate-coverage.sh (and its test), and two also
 missed gate-paths.tsv/setting-registry.tsv rows, because the worker's own
 `--scoped` run (temperloop#957) selects gates by DIFF PATH: a brand-new
 script's path matched no row in gate-paths.tsv until the worker itself
 registered one, so the very gates that would have caught the omission
 never ran worker-side — each miss cost a full parent-side sliced
 acceptance-gate round trip (about 10-20 minutes). gate-paths.tsv now also
 carries generic new-surface globs closing the SELECTION half of that gap
 (see its own header, temperloop#1931) — this section is the PREVENTION
 half: naming the registries up front so the worker registers before its
 own scoped run ever needs to catch the omission after the fact.
```

## activationProofSection — the temperloop#1934 "show the worker its own
<a id="activationproofsection-the-temperloop-1934-show-the-worker-i"></a>

```text
 activationProofSection — the temperloop#1934 "show the worker its own
 class-A activation predicate" section, a SELF-CONTAINED section appended
 once into workerPrompt()'s array, mirroring gateRegistrationChecklistSection()'s
 shape so a sibling edit to workerPrompt() rebases cleanly. Gated on
 activationClass(item) === 'A' (defined below — hoisted, so the forward
 reference from here is fine): an absent `activation` block, or a class
 B/C block, renders NOTHING, so this section changes zero bytes of the
 prompt for those items (the acceptance's byte-identical requirement).

 WHY THIS EXISTS: the live instance (epic #1910, item join-key-registry) —
 the worker built and wired `join-keys-lib.sh`, but the plan's `proof:`
 predicate grepped for the producer-chosen literal `join_keys`, a name the
 worker never saw and had no reason to preserve. The worker's own
 acceptance bullets all passed; §3e.6 then failed the whole item on a name
 mismatch the worker was never shown, costing a full re-drive round trip.
 Rendering the `proof:` command VERBATIM — not a paraphrase of what it
 checks — lets the worker see the exact reachability surface the
 orchestrator will run and either name its own artifacts to match, or, if
 the predicate genuinely conflicts with the acceptance bullets, say so
 (`blocked`) instead of guessing a silent rename that may or may not agree
 with what §3e.6 actually runs.
```

## §3c "No long-running background work" (#1219). Embedded in the generat
<a id="3c-no-long-running-background-work-1219-embedded-in-the-gene"></a>

```text
 §3c "No long-running background work" (#1219). Embedded in the generated
 prompt — NOT left to prose the caller may forget — so every worker (main
 AND spike, both route through workerPrompt) is told up front to foreground
 the gate. Without this the worker backgrounds quality-gates.sh, yields, and
 returns no verdict (build.md §3c/§3d must stay in lockstep with this block).

 temperloop#997 adds the SCOPE half of the same contract: the worker must not
 run the BARE, repo-wide suite in its own context at all. That run is minutes-
 scale, and one blocking turn that long blows the ~5-min prompt-cache TTL — the
 worker's whole ~213K-token context is then re-WRITTEN (weight 1.25) instead of
 re-READ (0.1) on the next call. The ACCEPTANCE run stays parent-side at 3e.5
 (unchanged, still the authority — the PR #309 silent-red lesson; since
 temperloop#1663 that run is itself diff-scoped through the same map, which
 changes WHICH gates it runs but not WHO decides acceptance). The two
 halves live in ONE section on purpose: foreground-only governs HOW the worker
 runs its checks, #997 governs WHICH checks it runs, and dropping either one
 re-opens a measured defect. build.md §3c carries both in lockstep.
```

## Lost-return recovery (temperloop#939).
<a id="lost-return-recovery-temperloop-939"></a>

```text
 -----------------------------------------------------------------------------
 Lost-return recovery (temperloop#939).
 -----------------------------------------------------------------------------
 The 3c worker can die in TWO different ways that look identical from here:
   (a) it genuinely failed — nothing was built, and escalating is correct;
   (b) it did the whole job and only the RETURN CHANNEL failed — the subagent
       completed without calling StructuredOutput, or blew the StructuredOutput
       retry cap, so `agent({schema})` THROWS (it does not return null).
 Case (b) is not hypothetical: in the #939 run it hit 2 of 5 workers. One had
 committed, pushed, opened PR #936 and gone green; the other had committed but
 not pushed. Both were reported as `worker-error` — a `ask-now` halt over work
 that had already landed, with a live risk of re-spawning a worker onto a
 worktree that already held the finished commit (a second PR, a stacked commit).

 The fix is to STOP GUESSING from the exception and go LOOK: probe the
 observable side-effects (commit / push / PR) before classifying. What we can
 never recover is the worker's own self-verification — so a recovered record is
 honest about that and marks its acceptance results UNVERIFIED rather than
 letting them read as passing.
```
