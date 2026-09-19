// build-level.mjs — foundation's FIRST saved Workflow.
// =============================================================================
// The per-level driver for /build. It re-homes build.md's 3a–3h
// per-item loop out of the conversational orchestrator and into a bounded
// Workflow process, so the orchestrator's context stays pinned to ONE small
// {parked, escalations} object per dependency level — regardless of how many
// items or machinery calls the level contains. The orchestrator invokes this once
// per level (via the Workflow tool), the workflow drives every item's machinery +
// worker, and returns only what to write back. The orchestrator still owns the
// MERGE GATE (Step 4) — this workflow never merges and never writes the plan
// note. Corollary (temperloop#1452): build.md §3h.5's as-you-go merge, which
// needs BOTH of those seats, is scoped to /build's `--no-workflow`
// conversational path and has no implementation here by design — a
// Workflow-path level batches every item to the Step-4 gate.
//
// -----------------------------------------------------------------------------
// DESIGN NOTES (read before editing — these three decisions are load-bearing)
// -----------------------------------------------------------------------------
//
// 1. THE runMachinery BRIDGE (spike #421 verdict §1; BATCHED per temperloop#942).
//    The deterministic bash machinery (worktree.sh / pr.sh / ci-poll.sh /
//    quality-gates.sh / board claim.sh) is the source of truth for every
//    mechanical step. But the Workflow runtime has NO filesystem, NO Node, NO
//    shell in the script body — so there is no `sh()` primitive. The bridge:
//    a machinery call becomes an `agent({schema})` whose entire job is "run
//    exactly this command text, return each step's closed-outcome JSON line as a
//    validated object." The runtime's agent() hook gives a subagent the normal
//    Bash tool and (with a schema) returns a validated object, not free text —
//    so an agent that runs a command IS the missing sh().
//
//    WHAT THE BRIDGE'S INVARIANT ACTUALLY IS: the BRANCHING LOGIC (if
//    SCAN_BLOCKED → escalate, if PUSH_REJECTED → escalate) stays in legible .mjs
//    here, never buried in an opaque agent prompt that returns a single verdict.
//    It is NOT "one agent per command" — that was only the cheapest way to keep
//    each step's outcome individually visible. temperloop#942 measured the cost
//    of taking it literally: an L0 level of 3 items spawned 40 agents (3 real
//    workers + 37 haiku micro-agents), each paying ~160K cache-read tokens and 4
//    API round-trips to execute one shell one-liner.
//
//    So mechanically-adjacent steps are now BATCHED into one executor agent via
//    `runMachineryBatch()`: one Bash invocation runs the steps in sequence and
//    prints ONE JSON line per step, and the agent returns them as
//    `{results:[…]}` — so the driver still sees EVERY step's own closed-outcome
//    object and branches on each of them, one `if` at a time, right here in .mjs.
//    The bash wrapper's only added logic is a `case` short-circuit that stops the
//    sequence when a step's outcome means the remaining steps must not run (a
//    stop-early mirror, never the decision: the .mjs re-reads the same JSON and
//    makes the authoritative call, and a truncated results array simply means the
//    .mjs already escalated on the earlier step). Three batch sites:
//      • `prelude:<slug>`  — 3a claim + 3b-0 deps-merged + 3b worktree create
//      • `pr-batch:<slug>` — 3f-0a rebase + 3f-0 scan + 3f-1 push + 3f-2 pr open
//      • `ci-batch:<slug>#n` — the interleaved merge-state probe + CI poll slices
//    The 3e.5 quality gate stays a SOLO call on purpose — it is the one machinery
//    step whose own runtime is minutes-scale (measured 6:05 for this repo's
//    suite), so folding it into a batch would put a single Bash invocation within
//    reach of the agent's ~10-min cap. See DESIGN NOTE 2.
//
//    The cost — ~4 executor spawns + 1 worker per item — lands entirely in THIS
//    discardable workflow process, never the orchestrator's context. That is the
//    whole point: orchestrator growth is bounded to one summary object per level.
//
//    CRITICAL (from the live probe in the spike): shell-quote every argument.
//    A spaced path (e.g. a vault plan path "Plans/2026-06-13 foo - bar.md")
//    MUST be single-quoted in the command string or the one-shot executor runs
//    the wrong command. Every command this file builds goes through `sq()` for
//    each interpolated value — and batching does NOT relax that: a batch is
//    literally the same per-step command strings joined by fixed shell syntax,
//    so every argument is still sq()-quoted exactly as before.
//
// 2. THE CI-POLL LOOP (spike #421 verdict §1 "ci-poll caveat").
//    ci-poll.sh can poll up to 1h, but an agent()'s foreground Bash has a
//    ~10-min cap — so we must NOT runMachinery a single long poll (it would die
//    mid-poll). Instead we drive SHORT-timeout polls (CI_POLL_SLICE_SECS,
//    default 240s) until the outcome resolves to CI_GREEN or CI_FAILED, bounded
//    by a total wall budget (CI_POLL_TOTAL_SECS). The short poll returns TIMEOUT
//    when the slice elapses with checks still pending — that is the signal to
//    poll again, NOT a failure. On CI_FAILED within a small retry budget we
//    re-spawn the worker, force-push, and re-poll PINNED to the new SHA (the #254
//    false-green guard — never let the poll re-resolve the head from the PR API
//    after a force-push). Past the budget without resolution → escalate
//    `ci-failed` so a human drives it.
//
//    temperloop#942 stopped spawning a FRESH agent per poll cycle (the measured
//    L0 run burned 7 ci-poll spawns + 8 `gh pr view` spawns at one level) — but
//    the ~10-min cap is unchanged and is now enforced ARITHMETICALLY rather than
//    by comment. One `ci-batch` agent runs CI_POLL_SLICES_PER_BATCH slices in one
//    Bash invocation, and that count is DERIVED: it is
//    floor(CI_POLL_MAX_BATCH_WALL_MS / CI_POLL_SLICE_SECS), so the poll wall a
//    single Bash invocation may occupy can never exceed CI_POLL_MAX_BATCH_WALL_MS
//    (< the AGENT_BASH_CAP_MS ceiling) no matter how the slice length is retuned.
//    Each individual ci-poll.sh invocation still carries its own
//    CI_POLL_SLICE_SECS `--timeout`; the batch never asks for one long poll.
//    The batch also short-circuits the moment a slice resolves, so a green PR
//    does not sit through the remaining slices.
//
// 3. DROP isolation:'worktree' (spike #421 verdict §5).
//    The worker agent() runs WITHOUT isolation:'worktree'. build has its
//    own worktree mechanism (worktree.sh create), and three contracts assume
//    IT, not the runtime's opaque isolation: (a) the deterministic path
//    <repoRoot>.wt/<slug> that pr.sh / quality-gates / the verification-surface
//    file all reference; (b) the .build-guard write-jail marker that arms
//    the PreToolUse guard per-worktree; (c) push-by-SHA on the plan's branch.
//    So we runMachinery('worktree.sh create …') first, then tell the worker (in its
//    prompt) that its cwd IS that deterministic path. The worker's writes are
//    confined by the .build-guard hook — the intended jail.
//
// -----------------------------------------------------------------------------
// I/O CONTRACT
// -----------------------------------------------------------------------------
//   Input  (via global `args`):
//     { repoRoot, planLink, board, items:[{ slug, branch, title, kind,
//        ghIssue, alsoCloses, repo, model, acceptance, source, scope, notes,
//        dependsOn, activation }],
//       ownerRepo, claimCmd, verdicts, onlySlugs }
//
//     repoRoot   — the parent checkout's top-level path; worktrees live at
//                  `<repoRoot>.wt/<slug>` and machinery scripts at
//                  `<repoRoot>/workflows/scripts/build/`.
//     planLink   — the plan note's vault link (passed to pr.sh --plan-link).
//     board      — board id (3/4) or null/false when board is OFF.
//     items      — this level's FULL item array (the onlySlugs filter, below,
//                  selects the active subset on a continuation). Per item,
//                  `dependsOn` is an array of { slug, sha } — the merged head
//                  SHA of each `depends-on` target (from that dep's plan-note
//                  `pushed_sha:`). It gates worktree creation (3b-0, #108): the
//                  worktree is created only once every dep SHA is an ancestor of
//                  origin/<default> (i.e. the depended-on PR has MERGED), so the
//                  worker builds and self-verifies against merged dependency
//                  code, not a pre-merge base. Absent/empty for level-0 items or
//                  items whose only cross-item edges are `after:` (no merge dep).
//                  `repo` is the item's plan-schema `repo:` field (owner/repo,
//                  absent for the common same-repo case) — the ONLY thing it
//                  drives today is the 3f cross-repo `Closes` qualification
//                  below (temperloop#852); it does NOT yet retarget worktree
//                  creation/`repoRoot` or CI polling per item, a separate,
//                  larger gap this fix does not attempt.
//                  `activation` is the item's plan-schema `activation:` block
//                  straight through — `{ class, proof, locus }`, absent on an
//                  item that declares none (temperloop#1219). ONLY `class: A`
//                  does anything here: §3e.6 runs its `proof:` predicate against
//                  the worktree between 3e.5 and 3f. Absent, or `class: B`/`C`
//                  (ledger-discharged at 4d-epic step 2a, orchestrator-side),
//                  is a no-op on this path. WITHOUT this field the §3e.6 gate
//                  cannot run at all — the defect temperloop#1219 filed.
//     ownerRepo  — "owner/repo" for ci-poll.sh / gh ops. The workflow has no
//                  shell to derive it, so the orchestrator passes it in (Step 0
//                  probe: `gh repo view --json nameWithOwner -q .nameWithOwner`).
//                  WITHOUT it every CI poll gets '' → ERROR. This is also the
//                  qualifier used for a cross-repo item's `Closes` line (3f,
//                  temperloop#852): `gh_issue:`/`also_closes:` numbers are
//                  tracked wherever the item was triaged — the plan's HOME repo
//                  (this value), not necessarily `item.repo` — so when
//                  `item.repo` is set and differs from `ownerRepo`, the issue
//                  ref is qualified as `<ownerRepo>#<N>` rather than emitted
//                  bare (build.md 3f "Cross-repo `repo:` honor point").
//     claimCmd   — absolute path to the board claim.sh entrypoint (Step 0 CLAIM
//                  probe). Used by 3a; defaults to bare 'claim.sh' if absent.
//     machineryAgentType
//                — optional override for the executor agent type. Absent (the
//                  norm) means 'machinery-executor', with an automatic one-time
//                  fallback to 'general-purpose' in a checkout that has not
//                  deployed the agent definition. Pass 'general-purpose' to pin
//                  the pre-#1014 behavior. See machineryAgent() below.
//     reviewBlockingMaxRounds
//                — the §3e convergence bound (temperloop#1970), resolved from
//                  $BUILD_REVIEW_BLOCKING_MAX_ROUNDS at build.md / sweep.md /
//                  fix.md Step 0 and handed in on the SAME seam, for the same
//                  structural reason, as gateSliceSecs (the Workflow runtime has
//                  no shell to source build.config.sh — DESIGN NOTE 1). Caps how
//                  many review ROUNDS one item's worktree may spend before a
//                  HIGH finding is carried into the PR body instead of
//                  escalating `review-blocking` again. Absent / empty /
//                  non-positive → the in-file default; never unbounded.
//     reviewAgentCeilingSecs / reviewAgentSlowSecs
//                — the §3e review-agent LIVENESS bound and its progress-notice
//                  threshold (temperloop#2003), resolved from
//                  $BUILD_REVIEW_AGENT_CEILING_SECS / $BUILD_REVIEW_AGENT_SLOW_SECS
//                  at build.md / sweep.md / fix.md Step 0 and handed in on the
//                  SAME seam as reviewBlockingMaxRounds above. The ceiling bounds
//                  the WHOLE §3e fanout's wall clock so a reviewer that never
//                  returns cannot stall the level; the slow threshold makes a
//                  long-but-alive review visible first. Both are clamped in this
//                  file (the ceiling floored at one CI-poll/gate slice) so no
//                  operator value can manufacture a false timeout on healthy
//                  work. Absent / empty / non-positive → the in-file defaults.
//     verdicts   — escalation-continuation map. Empty/absent on a fresh level;
//                  on a 3d-esc continuation, keyed by slug:
//                    { [slug]: { kind, verdict_section } }
//                  where `kind` is the escalation kind (design-fork/blocked/
//                  failed) and `verdict_section` is the FULL markdown block the
//                  orchestrator appended to the plan note (a `## Design verdict
//                  — <slug>` or `## User answers — <slug>` section, heading +
//                  body). driveItem injects it verbatim into the re-spawned
//                  worker's prompt (3c) so the worker sees the human's decision
//                  instead of re-forking. Read ONLY for slugs in onlySlugs.
//     onlySlugs  — optional continuation filter. Absent/empty on a fresh level
//                  (drive everything). On a continuation it is the array of
//                  still-unresolved slugs to re-drive; their siblings are
//                  already parked and are left untouched. A slug in onlySlugs is
//                  driven in CONTINUATION mode: claim (3a) and worktree create
//                  (3b) are SKIPPED (issue already claimed, worktree intact —
//                  re-creating it would discard the escalated build), and the
//                  captured verdict is injected at 3c.
//   Output (returned):
//     { parked:      [{ slug, pr, pushed_sha, acceptance_results }],
//       escalations: [{ slug, kind, payload }],
//       sidelined?:  [{ slug, path, branch, recovery }] }
//
//   `sidelined` (temperloop#2006) is present ONLY when `worktree.sh create`
//   shelved a resumable build for at least one item on this level. `create`
//   must never refuse (worktree.sh:783-787), so when the deterministic path
//   already holds committed work preservation could not capture, it MOVES that
//   occupant to `<path>.unpreserved-<sha8>` on `<branch>.unpreserved-<sha8>`
//   and creates over the freed path — reporting exactly that as the CREATED
//   line's `sidelined` / `sidelined_path` / `sidelined_branch` fields. This
//   driver reads them at 3b and surfaces the fact three ways: a named
//   `SIDELINED BUILD` log line at the moment of discovery, the same
//   `{ path, branch, recovery }` object stamped onto that item's OWN record
//   (`parked.sidelined`, or `escalation.payload.sidelined` — whichever the item
//   produced), and this level-wide rollup. `recovery` is the concrete reclaim
//   command, not a description of the event.
//
//   The reading lives HERE rather than in a driver's prose deliberately. It is
//   the same commit-ahead-of-base fact /fix's Step 4a worktree state table
//   reasons about, and /build and /sweep reach `worktree.sh create` through
//   this file's prelude with no table of their own — so all three inherit the
//   check from one place instead of each restating it (the per-instance-fix
//   smell: hoist the mechanism rather than patch the instance). A sideline is
//   NOT a failure and never stalls the level: the item is being rebuilt from
//   scratch and the shelved build stands until `worktree.sh prune`'s own
//   two-gate disposal owner reaps it. It is a notice a human should act on
//   before that happens.
//
//   A parked record MAY additionally carry `acceptance_unverified: true` +
//   `recovered_from: <RECOVER_* stage>` (temperloop#939). That pair means the
//   worker's return channel failed and this record was RECONSTRUCTED from
//   observable side-effects: the PR and SHA are ground truth, but the acceptance
//   results are UNKNOWN — never treat them as passing. The orchestrator MUST
//   re-verify that item's acceptance itself before the Step 4 merge gate.
//
//   A parked record MAY additionally carry `discrimination_gaps: [<criterion>,
//   ...]` (temperloop#1319) — present ONLY when this run armed
//   requireDiscriminationEvidence AND the done verdict had at least one
//   passed:true acceptance_results[] entry with an empty/absent
//   discrimination_evidence. Non-fatal (kernel principle 7 — advisory, never a
//   new blocking gate): already logged as a named warning at 3h; the
//   orchestrator rolls the list into the Step 6 summary tally (build.md §3f
//   step 2's sibling verification_surface degraded-case pattern).
//
//   A parked record MAY additionally carry `host_config_deferrals:
//   [{ criterion, host_config }, ...]` (temperloop#1182) — one entry per
//   acceptance criterion the worker reported DEFERRED because it turns on a
//   gitignored, host-local file (a credential file, an operator-placed
//   secret, an env var sourced from one). A worktree is populated from the
//   git INDEX, so such a file is NEVER carried into it: the worker's reading
//   is uninformative on every host, always — which is why a deferral is
//   neither a pass nor a failure here (it does not stall the level, and it
//   never reads as confirmed). These criteria are UNVERIFIED, exactly like
//   `acceptance_unverified` above: the orchestrator MUST verify each one
//   ITSELF, in the real checkout where the file actually exists, before that
//   item's merge gate — and MUST NOT resolve one by copying the named file
//   into the worktree, which is the secret-in-worktree exposure the
//   host-config seam (/assess A.8) exists to prevent.
//
//   Because this driver is SHARED, that obligation has THREE consumer seats,
//   one per invoking spec — keep all three in lockstep with the (deliberately
//   ungated) prompt section `hostConfigDeferralSection()` below:
//     /build -> claude/commands/build.md §4a, the level merge gate. §3h.5's
//               as-you-go fast path is explicitly INELIGIBLE for an item
//               carrying this field, precisely because it never reaches §4a.
//     /sweep -> claude/commands/sweep.md, the per-chunk merge pass: verify
//               before `gh pr merge --auto`; not-confirmed / cannot-establish
//               parks the issue instead of merging it.
//     /fix   -> claude/commands/fix.md Step 5, the ONE modal merge gate: the
//               deferral rides that same single ask as a named state caveat.
//   An ungated prompt section on a path with NO seat would let a deferral
//   auto-merge with nobody having verified it — the exact silent loss this
//   field exists to make impossible.
//
//   A parked record also carries
//   `review: { ran, skipped, mandatory_ok, routed_not_run }`
//   (temperloop#1450/#1984) — the §3e reviewer tally across every round this
//   item's build ran (the original 3e pass plus any CI-fix re-review), the
//   source for the Step 6 "reviewer outcome" summary build.md §3e promises.
//   `routed_not_run` names every routed-but-unrun reviewer, mandatory or not,
//   so the tally cannot read fully clean while a tsv-routed reviewer was
//   skipped. Absent only for a spike (kind:spike skips 3b-3h, never reviews).
//
//   That `review` object ALSO carries `residual_blocking: [{ round, max_rounds,
//   findings }]` (temperloop#1970) — present ONLY when a review round hit the
//   §3e convergence bound: HIGH findings that were CARRIED into the PR body's
//   `## Review notes` instead of escalating `review-blocking` for yet another
//   build-review round-trip. It is the bound's per-run execution signal, and it
//   marks an item a human should read the review notes on before merging; it is
//   NOT a failure (the gates, the activation gate and CI all still passed) and
//   it never stalls the level. Omitted entirely when no round hit the bound.
//
//   The workflow NEVER writes the plan note (race-safety: the orchestrator
//   serializes all plan-note writeback at the level boundary). It only RETURNS
//   what to write. Escalations leave the worktree INTACT (the orchestrator
//   re-drives them); parked items' worktree removal is the orchestrator's job
//   at the boundary too. The workflow removes no worktrees.
// =============================================================================

// `meta` MUST be a PURE literal — no vars, calls, or spreads (runtime constraint).
// Consequence (temperloop#903): `description` can NEVER carry run context — it is
// the same bytes on every run. So it is written for the operator as a plain
// statement of what the run DOES, deliberately WITHOUT asserting a scope (a
// "level") or a single caller: this script is invoked by THREE commands —
// /build (a full dependency level), /fix (a 1-item level), and /sweep (a
// chunk of singleton issues) — and a description that named only one of them,
// or asserted a single dependency-level scope, would misdescribe the other
// two invocations byte-for-byte identically (temperloop#1941 — the /fix and
// /sweep launch/completion lines used to inherit build's level-scoped wording
// on runs that drove neither a level nor a dependency edge). The
// run-IDENTIFYING half (caller, repo, items, issues, round) rides two
// dynamic surfaces instead:
// the phase() title — see levelPhaseTitle() near the entry point, emitted
// ONCE PER STAGE (temperloop#1294) — and, pushed unconditionally rather than
// left to the opt-in `/workflows` surface, the orchestrator's own Workflow
// launch/return line printed immediately around every invocation of this
// script (`claude/message-schema.md` §§ Workflow launch line / Workflow
// return line; `claude/commands/build.md` Step 3 + 3d-esc, `fix.md` Step 4a,
// `sweep.md` Phase 2). The optional `phases` key is deliberately ABSENT from
// this literal: meta.phases entries are matched against phase() titles
// EXACTLY, and every title this workflow emits is dynamic, so a static entry
// could only ever render an empty duplicate group. See the levelPhaseTitle
// block for the full reasoning. Return shape, the never-merges rule and
// the never-writes-the-plan-note rule are contract detail and live in the I/O
// CONTRACT block above; do not re-state them here.
export const meta = {
  name: 'build-level',
  description:
    'Drives one invocation\'s worth of items — a /build dependency level, a /fix single-item level, or a /sweep chunk — through claim, isolated-worktree build, the acceptance gate, PR open, and CI watch.',
  version: '1.0.0',
};

// -----------------------------------------------------------------------------
// THE HAND-OFF CAPABILITY DECLARATION (temperloop#2018)
// -----------------------------------------------------------------------------
//
// Every key below is a top-level `input.*` key THIS COPY of the engine reads.
// The orchestrator->engine hand-off is deliberately ADDITIVE — an absent key
// falls back to an in-file default, so a new key can never regress an
// un-migrated caller (see the `machineryBinDir`, `principlesSummaries` and
// `reviewerRoutingTsv` comments below, which each say so in their own words).
// That property is correct and is NOT changed here. Its cost is that the
// converse is silent too: a STALE installed engine simply ignores a key a
// current orchestrator passes, and neither side says anything. Live case:
// an installed copy 18 days behind had zero `reviewerRoutingTsv` support, so
// following the driver spec literally dropped the key and fell back to the
// very agent relay the run was fixing.
//
// This list is what makes that DETECTABLE. It is read TEXTUALLY — never by
// importing this module, which cannot be imported at all outside the Workflow
// runtime (the `args` reference below throws ReferenceError) — by
// `workflows/scripts/build/handoff-capability.sh`, which a driver runs at
// Step 0 against the engine path it is about to invoke. That is why the
// sentinel comments are load-bearing and why the list is a flat array of
// single-quoted literals: the probe must work against ANY copy of this file,
// including a consuming repo's older VENDORED one, with no repo checkout to
// diff against and no Node available.
//
// KEEPING IT HONEST. A declaration that drifts from what the code actually
// reads would be a second list to maintain, so it is not maintained by hand:
// `workflows/scripts/build/tests/test_handoff_capability.sh` asserts SET
// EQUALITY between this block and every `input.<key>` occurrence in this file
// — add a key read without declaring it (or declare one nothing reads) and
// `make test-build` goes red.
//
// KNOWN BOUNDARY, stated rather than implied: this declares TOP-LEVEL keys
// only. Nested per-item fields (`items[].activation`, `items[].dependsOn`)
// are a real hand-off surface with the same drop-silently property — the
// `activation` block's own absence was temperloop#1219 — and are NOT covered
// by this declaration. The probe reports what it covers; it never implies
// more.
//
// CONVERGENCE WITH temperloop#2024 (the hand-off key REGISTRY + author-side
// lint): the same key set seen from the other side — #2024 asks "did the
// author wire this new key into all three drivers", this block answers "does
// THIS engine understand this key". This block is the per-ENGINE half and
// must stay in the file (a vendored copy travels alone); #2024's registry is
// the per-REPO half and adds the authoring columns (which drivers wire a key,
// since-version, owner). They converge by DERIVATION, not duplication: the
// registry's lint reads this declaration via `handoff-capability.sh declared`
// and asserts the two agree, exactly as the test above already does for the
// code. Do not create a second hand-maintained list.
//
// NOT `export`ed, deliberately. Nothing imports this — the probe reads it as
// TEXT — and `export const meta` is the ONE export the offline harness
// (workflows/scripts/build/tests/test_workflow.sh) strips before wrapping this
// file's body in an AsyncFunction, so a second top-level `export` is a
// SyntaxError there. A plain `const` runs identically in the Workflow runtime
// and in the harness.
//
// HANDOFF-CAPABILITIES-BEGIN (machine-parsed — workflows/scripts/build/handoff-capability.sh)
const inputCapabilities = [
  'board',
  'claimCmd',
  // temperloop#2080 — the dual-build descriptor { tier, baseline, candidate,
  // inScope: [slug…] }. ADDITIVE like every key here: absent means the
  // single-arm path, unchanged. Its staleness cost is the sharpest on this
  // list, which is exactly why it is declared: an engine without it ignores
  // the key and builds the level ONCE while the orchestrator reports a
  // two-model comparison that never happened.
  'dualBuild',
  'gateSliceSecs',
  'items',
  'machineryAgentType',
  'machineryBatchModel',
  'machineryBinDir',
  'machinerySoloModel',
  'machineryStepCeilingSecs',
  'machineryStepSlowSecs',
  'onlySlugs',
  'ownerRepo',
  'planLink',
  'principlesDefaultRepo',
  'principlesSummaries',
  'repoRoot',
  'requireDiscriminationEvidence',
  'reviewAgentCeilingSecs',
  'reviewAgentSlowSecs',
  'reviewBlockingMaxRounds',
  'reviewerRoutingTsv',
  'verdicts',
  'workerEvidenceMaxWords',
  'workerSummaryMaxWords',
];
// HANDOFF-CAPABILITIES-END

// `args` arrives from the Workflow tool as a JSON STRING, not a parsed object
// (established by live probe, #437). Parse it once into `input` and read input.*
// throughout. Helpers below close over `input`; it is assigned before any of
// them is called (the top-level invocation at the end runs last).
const input = typeof args === 'string' ? JSON.parse(args) : (args ?? {});

// -----------------------------------------------------------------------------
// Schemas
// -----------------------------------------------------------------------------

// SPINE_OUTCOME_SCHEMA — one permissive object keyed on `outcome` (the union of
// every machinery script's closed set) plus passthrough fields. The .mjs branches
// on `.outcome` exactly as each script's header documents. Permissive on the
// passthrough so one schema covers worktree.sh / pr.sh / ci-poll.sh /
// quality-gates / claim outcomes without a per-script schema.
const SPINE_OUTCOME_SCHEMA = {
  type: 'object',
  required: ['outcome'],
  additionalProperties: true,
  properties: {
    outcome: {
      type: 'string',
      // The union of the machinery's closed outcome sets (worktree / pr / ci-poll /
      // gate) plus the gate-pass/fail and claim markers we synthesize below.
      enum: [
        'CREATED', 'REMOVED', 'NOT_FOUND', 'PRUNED', 'SKIPPED_FRESH', 'SKIPPED_DIRTY', 'SKIPPED_UNMERGED',
        'SCAN_CLEAN', 'SCAN_BLOCKED',
        'BASE_CURRENT', 'BASE_STALE',
        'REBASED', 'REBASE_CONFLICT', 'DIRTY_WORKTREE',
        // PUSHED_UNWATCHED (temperloop#1688): the push LANDED, but on a ref no
        // open PR references while a sibling PR for the same slug sits on a
        // DIFFERENT head ref. NOT a push failure — a report about WHERE it
        // landed, so a caller must never re-push believing nothing happened,
        // and never route it through the lost-return probe (the result line was
        // not lost; it says something specific).
        'PUSHED', 'PUSHED_UNWATCHED', 'PUSH_REJECTED',
        'PR_OPENED', 'EXISTS',
        'CI_GREEN', 'CI_FAILED', 'NO_CI', 'TIMEOUT',
        // The 3e.5 acceptance gate. GATE_SLICE / GATE_TIMEOUT are temperloop#1021:
        // a budget-exhausted run is its OWN outcome and must never collapse into
        // GATE_FAIL — GATE_SLICE says "budget spent, gates remain, resume at
        // resumeAt"; GATE_TIMEOUT says "the executor's Bash tool killed the run
        // before it could report", which is a BUDGET fact, not evidence about the
        // tree. Collapsing either into GATE_FAIL is what made an escalation
        // payload indistinguishable from real breakage.
        'GATE_PASS', 'GATE_FAIL', 'GATE_ABSENT', 'GATE_SLICE', 'GATE_TIMEOUT',
        // The §3e.5 PRE-gate freshness/rebase step (temperloop#1937): brings
        // the worktree up to current origin/main before the gate runs, so an
        // origin/main-ratcheted validator never false-fails on rows main
        // gained after this worktree's base was cut. NO_GATE (round 3, HIGH)
        // means the worktree carries no `scripts/quality-gates.sh` at all —
        // the same presence check gateCmd's own GATE_ABSENT arm makes — so
        // there is nothing for this step to protect and it takes the
        // byte-identical pre-change path with no fetch/rebase attempted.
        // CURRENT/REBASED are the two non-blocking outcomes (proceed to the
        // gate); DIRTY (round 2, HIGH) means git refused to even start the
        // rebase over uncommitted tracked-file edits, probed BEFORE the
        // rebase and escalated as `dirty-worktree`, never misread as a
        // conflict; CONFLICT means the rebase hit a real clash and was
        // aborted (worktree left intact, escalates `stale-worktree` — the
        // gate never runs); REBASE_ERROR (round 3, MEDIUM) is a rebase
        // failure with NO conflicted files (a pre-rebase hook, a missing
        // identity, a leftover in-progress rebase) — never misreported as
        // CONFLICT's empty-list false positive, its own not-a-conflict
        // outcome carrying git's own output tail; ERROR is a fail-open
        // (fetch/resolve itself could not run; proceed on the tree as-is,
        // exactly the pre-#1937 behavior); TIMEOUT (round 2, MEDIUM) is the
        // OUTER Bash-tool kill mid-fetch/rebase — never fail-open, always
        // routed through a follow-up abort-and-probe before escalating
        // `stale-worktree`. TIMEOUT_PROBE(_ERROR) are that follow-up probe's
        // own closed outcomes.
        'FRESHNESS_NO_GATE', 'FRESHNESS_CURRENT', 'FRESHNESS_REBASED', 'FRESHNESS_DIRTY',
        'FRESHNESS_CONFLICT', 'FRESHNESS_REBASE_ERROR',
        'FRESHNESS_ERROR', 'FRESHNESS_TIMEOUT', 'FRESHNESS_TIMEOUT_PROBE', 'FRESHNESS_TIMEOUT_PROBE_ERROR',
        // The 3e.6 class-A activation gate (temperloop#1219). ACTIVATION_PASS /
        // ACTIVATION_FAIL are the `proof:` predicate's own exit status against
        // the worker's worktree. The three CONTROL outcomes are the
        // temperloop#944 merge-base control pass, run FIRST for an absence-
        // asserting predicate: DISCRIMINATES (fails at the merge base — good,
        // proceed to the worktree run), VACUOUS (passes at the merge base, so it
        // would pass on an untouched tree and proves nothing), ERROR (the control
        // could not be ESTABLISHED — an UNKNOWN, never laundered into either
        // verdict, the same #1021 discipline GATE_TIMEOUT encodes).
        // ACTIVATION_TIMEOUT is that same discipline for the Bash-tool timeout.
        'ACTIVATION_PASS', 'ACTIVATION_FAIL', 'ACTIVATION_TIMEOUT',
        'ACTIVATION_CONTROL_DISCRIMINATES', 'ACTIVATION_CONTROL_VACUOUS', 'ACTIVATION_CONTROL_ERROR',
        // The 3e pre-push review's diff/routing-data fetch (temperloop#1430).
        // ONE outcome carrying both the changed-file list and the
        // reviewer-routing.tsv text — the .mjs does the routing DECISION
        // itself (DESIGN NOTE 1: branching logic stays in legible .mjs), this
        // step only reads the two raw inputs off the worktree.
        'REVIEW_DIFF',
        'CLAIMED', 'CLAIM_CONFLICT',
        // worktree.sh deps-merged (3b-0) — its outcomes were consumed at the
        // call site (~line 595) but never listed here; an omitted outcome is
        // schema-invalid, so name them alongside the rest of the closed set.
        'DEPS_MERGED', 'DEPS_UNMERGED',
        // pr.sh recover-probe (3c lost-return recovery, temperloop#939) — the
        // staged observable-side-effect ladder: nothing / uncommitted work on
        // disk / committed / pushed / PR already open. RECOVER_DIRTY
        // (temperloop#993) splits the old stage-0 bucket: it is NOT a landed
        // stage (nothing is committed), it is the backgrounded-gate stall whose
        // cure is a foreground re-spawn on the SAME worktree.
        'RECOVER_NONE', 'RECOVER_DIRTY', 'RECOVER_COMMITTED', 'RECOVER_PUSHED', 'RECOVER_PR_OPEN',
        // The WORKFLOW-LEVEL step liveness bound (temperloop#1071). Neither of
        // these comes from a machinery script — both are emitted by the shell
        // watchdog THIS file wraps every machinery step in (see
        // stepBoundPreamble()). STEP_TIMEOUT: the step outlived
        // STEP_CEILING_SECS and was killed, so its result is LOST (never
        // "failed" — the ceiling says nothing about the work, exactly as
        // GATE_TIMEOUT says nothing about the tree). STEP_SLOW: an ADVISORY
        // notice riding alongside a step's real result, never a result itself —
        // runMachineryBatch partitions it out and logs it.
        'STEP_TIMEOUT', 'STEP_SLOW',
        // temperloop#2020 — the post-commit work-preservation push that runs
        // at the ONE escalation choke point (preserveOnEscalation). Three
        // outcomes, deliberately distinct so a payload never has to infer
        // which: WORK_PRESERVED (the branch is on origin), WORK_PRESERVE_SKIP
        // (there was PROVABLY nothing to preserve — no worktree, or a RESOLVED
        // default branch with no commit ahead of it; an unresolvable base is
        // never a skip, it pushes), WORK_PRESERVE_FAILED (there WAS unlanded work
        // and the push did not land it — the one shape that must stay visible,
        // because a later `worktree.sh remove` is then the last copy's last
        // chance).
        'WORK_PRESERVED', 'WORK_PRESERVE_SKIP', 'WORK_PRESERVE_FAILED',
        // The §3e REVIEW-AGENT liveness bound's timer (temperloop#2003), whose
        // executor runs workflows/scripts/build/review-wait.sh to give this
        // runtime the wall-clock tick it otherwise has none of (`Date.now()`
        // THROWS here — DESIGN NOTE 1). FOUR closed outcomes, each a pure
        // OBSERVATION the executor can make without inventing anything — the
        // distinction temperloop#2049 turned on, plus the fourth
        // temperloop#2064 had to split out of it:
        //   REVIEW_WAIT_ELAPSED       the script printed its line. It carries
        //                             `realized_secs`, the script's OWN measure
        //                             of the wait, which reviewWaitAgent()
        //                             checks against the interval it asked for.
        //   REVIEW_WAIT_TOOL_TIMEOUT  the Bash tool's own timeout killed the
        //                             command. That budget is secs+60s, so this
        //                             can only fire AFTER the interval — the
        //                             same fact, reported honestly.
        //   REVIEW_WAIT_BLOCKED       a harness PERMISSION CONTROL refused the
        //                             command outright ("<tool_use_error>Blocked:
        //                             …"). NO time passed. This is SPLIT OUT of
        //                             REVIEW_WAIT_UNAVAILABLE by temperloop#2064
        //                             because a block and a TOOL_TIMEOUT are the
        //                             same observation to the executor — "no JSON
        //                             line" — while only ONE of them (the tool
        //                             timeout) is the PERMISSIVE arm. Naming the
        //                             block is what lets reviewWaitAgent() refuse
        //                             to let a refusal land on that arm.
        //   REVIEW_WAIT_UNAVAILABLE   the command never ran to completion for any
        //                             OTHER reason (it errored; the helper was
        //                             missing). NO time passed either, so the
        //                             caller FAILS OPEN on both.
        // None of them says anything whatsoever about the review being bounded.
        'REVIEW_WAIT_ELAPSED', 'REVIEW_WAIT_TOOL_TIMEOUT', 'REVIEW_WAIT_BLOCKED',
        'REVIEW_WAIT_UNAVAILABLE',
        // temperloop#2065 "worker-cost-capture" — the per-item WORKER COST
        // seam. Neither comes from a machinery script proper; both are
        // workflows/scripts/build/worker-usage.sh, the SAME emitted-shell
        // pattern review-wait.sh established for giving this runtime a
        // wall-clock tick it otherwise has none of. WORKER_CLOCK is a bare
        // `date` read (no side effect); WORKER_USAGE is that same reading
        // PLUS the durable per-seat attribution write (model-usage-
        // envelope.sh's model_usage_emit_from_envelope, seat "build-worker" —
        // see that file's own header). See workerClockNow()/workerUsageEmit().
        'WORKER_CLOCK', 'WORKER_USAGE',
        'ERROR',
      ],
    },
    // Common passthrough fields the machinery emits (any subset, depending on cmd).
    // (recover-probe adds commits_ahead / pushed / remote_sha / dirty /
    // dirty_files / verification_surface_present; `additionalProperties: true`
    // already admits them, and the ones the .mjs branches on are declared below.)
    path: { type: 'string' },
    commits_ahead: { type: ['number', 'string'] },
    pushed: { type: 'boolean' },
    remote_sha: { type: 'string' },
    // temperloop#993 — uncommitted work on disk at the probe (the stall shape).
    dirty: { type: 'boolean' },
    dirty_files: { type: ['number', 'string'] },
    verification_surface_present: { type: 'boolean' },
    branch: { type: 'string' },
    base: { type: 'string' },
    sha: { type: 'string' },
    pr_number: { type: ['number', 'string'] },
    url: { type: 'string' },
    pr: { type: ['number', 'string'] },
    merge_base: { type: 'string' },
    tip: { type: 'string' },
    waited: { type: ['number', 'string'] },
    // temperloop#2049 — the §3e timer's own MEASURED wait, emitted by
    // review-wait.sh after the interval genuinely elapsed. Declared here (not
    // left to `additionalProperties`) because reviewWaitAgent() BRANCHES on it:
    // a REVIEW_WAIT_ELAPSED without a realized_secs that reaches the interval
    // is not honoured as elapsed. `secs` rides alongside it as the echo of what
    // was asked, so the two can be compared.
    secs: { type: ['number', 'string'] },
    realized_secs: { type: ['number', 'string'] },
    // temperloop#2064 — the harness's OWN words when it REFUSED the timer
    // command, relayed verbatim (first line). Declared rather than left to
    // `additionalProperties` because reviewWaitAgent() CLASSIFIES on it: a
    // refusal is recognised from this text before the executor's own outcome
    // label is consulted, so a block mislabelled as a tool timeout can never
    // reach the permissive arm.
    refusal_text: { type: 'string' },
    // temperloop#2065 — worker-usage.sh's WORKER_CLOCK/WORKER_USAGE fields.
    // Declared (not left to `additionalProperties`) because
    // workerClockNow()/workerUsageEmit() BRANCH on them: a non-numeric
    // epoch_s or a non-numeric token count degrades to null rather than
    // being coerced, exactly like every other machinery passthrough here.
    epoch_s: { type: ['number', 'string'] },
    usage_source: { type: 'string' },
    input_tokens: { type: ['number', 'null'] },
    output_tokens: { type: ['number', 'null'] },
    error: { type: 'string' },
    matches: { type: 'array', items: { type: 'string' } },
    failed_run_ids: { type: 'array', items: { type: ['number', 'string'] } },
    // free-form detail the executor may pass through (e.g. gate output tail)
    detail: { type: 'string' },
    // temperloop#1937 pre-gate freshness passthrough — the two SHAs a
    // FRESHNESS_CURRENT/FRESHNESS_REBASED line names, and the conflict
    // files + disposition a FRESHNESS_CONFLICT line names.
    worktree_base: { type: 'string' },
    main: { type: 'string' },
    conflict_files: { type: 'array', items: { type: 'string' } },
    disposition: { type: 'string' },
    // round 2 (temperloop#1937): FRESHNESS_DIRTY's own file list (distinct
    // field from `dirty_files`, which elsewhere in this schema is a COUNT —
    // see recover-probe's passthrough above), and the timeout-probe's two
    // booleans.
    dirty_paths: { type: 'array', items: { type: 'string' } },
    rebase_in_progress: { type: 'boolean' },
    aborted: { type: 'boolean' },
    // 3e.6 activation-gate passthrough (temperloop#1219): the `proof:`
    // predicate's own exit status, carried into the escalation payload so an
    // operator sees WHY it failed without opening a log.
    exitCode: { type: ['number', 'string'] },
    // REVIEW_DIFF passthrough (temperloop#1430) — the changed-file list (repo-
    // relative paths, from `git diff --name-only` in the worktree) and the
    // reviewer-routing table's data rows (an empty array when the worktree
    // ships no tsv — never an omitted key).
    files: { type: 'array', items: { type: 'string' } },
    // temperloop#2020: the routing table's DATA ROWS as an array of strings —
    // the shape reviewDiffCmd emits today, chosen because this exact jq
    // array-of-strings idiom (`files` above) survived every relay mangling
    // that dropped, paraphrased or double-encoded the `tsv` scalar. See
    // reviewDiffCmd's own comment for the evidence and reviewDiffTsvText for
    // the reader.
    tsv_lines: { type: 'array', items: { type: 'string' } },
    // LEGACY (pre-#2020), still accepted so an un-migrated caller or a
    // replayed older payload keeps routing: the raw reviewer-routing.tsv text
    // (empty string when the worktree ships none). No longer emitted.
    tsv: { type: 'string' },
    // temperloop#1976: the tsv's own non-comment row count, computed by
    // reviewDiffCmd off the worktree file itself — the guard runReviewers()
    // uses to detect the relay dropping/truncating `tsv`. Row-count only: it
    // catches a dropped or truncated table, not a same-length garble.
    tsv_rows: { type: ['number', 'string'] },
    // temperloop#1982: the tsv's own content checksum (tsvChecksum() below,
    // computed by reviewDiffCmd off the worktree file itself), independently
    // recomputable client-side from the RECEIVED `tsv` string with no hashing
    // primitive — closes exactly the same-length-garble gap tsv_rows alone
    // cannot (see reviewDiffTsvGap's comment for the observed case this
    // catches, temperloop#1978 round 4).
    tsv_checksum: { type: ['number', 'string'] },
    // temperloop#1970: how many §3e review rounds this worktree has ALREADY
    // run, read (and then bumped) by reviewDiffCmd from a marker in the
    // worktree's own git dir. The REVIEW_BLOCKING convergence bound reads it;
    // absent/unparseable means 0 (an older machinery relay, or a worktree
    // predating the marker) — i.e. exactly today's unbounded first round.
    review_rounds: { type: ['number', 'string'] },
    // 3e.5 sliced-gate fields (temperloop#1021). resumeAt — the 0-based gate
    // index the NEXT slice starts at; failed — failures seen in THIS slice (the
    // driver accumulates); elapsedSecs / budgetSecs — the margin pair that makes
    // suite growth observable on every run, not only when it blows a budget.
    resumeAt: { type: ['number', 'string'] },
    failed: { type: ['number', 'string'] },
    // `'null'` IS LOAD-BEARING HERE, not defensive padding (temperloop#1698,
    // review round 2). The gate emitter below deliberately prints a bareword
    // `null` when the elapsed figure is unreadable — that IS the fix: an
    // unknown duration must degrade to "I don't know", never to a plausible
    // `0`. This object is what `agent({schema})` validates the executor's
    // returned line against, so leaving `null` out of the type array would
    // reject (or silently coerce) the ONE shape the fix exists to produce —
    // reintroducing the same degrade-to-a-believable-value defect one layer
    // up, on the path that only fires when the figure is already unknown.
    // Same precedent as `input_tokens` / `output_tokens` above, declared
    // `['number', 'null']` for exactly this reason. Kept honest by the K1698
    // producer↔schema case in test_workflow.sh, which runs the REAL emitted
    // shell fragment and validates the REAL line it prints against THIS object
    // rather than against an injected outcome object.
    elapsedSecs: { type: ['number', 'string', 'null'] },
    budgetSecs: { type: ['number', 'string'] },
    // temperloop#2094: the gate slice's own exit status. It is a FACT the
    // ledger carries, never the classifier's input — a slice that printed a
    // resume-point trailer is a PARTIAL slice whatever code it exited with
    // (see gateCmd's own comment), and this field is what makes an anomalous
    // code visible in the escalation instead of silently re-labelling the
    // slice.
    rc: { type: ['number', 'string'] },
    // temperloop#1071 step-liveness fields, carried by STEP_TIMEOUT / STEP_SLOW.
    // `step` is the batch step's own `kind` (or 'solo'), so an escalation payload
    // names WHICH machinery call the ceiling bounded without any correlation work.
    step: { type: 'string' },
    // temperloop#1698 — these three are the NON-canonical (wire) spelling: the
    // emitted `__lb` shell prints them, so the schema must keep admitting them
    // or the bound's own STEP_TIMEOUT would fail validation. They are
    // canonicalized to `ceilingSecs` / `elapsedSecs` / `slowSecs` by
    // canonicalizeOutcome() at the transport boundary, and NO consumer in this
    // file reads a snake_case duration key any more. The camelCase twins are
    // declared alongside so an emitter that already speaks canonical (the 3e.5
    // gate does, for `elapsedSecs`/`budgetSecs` above) validates unchanged.
    ceiling_secs: { type: ['number', 'string'] },
    elapsed_secs: { type: ['number', 'string'] },
    slow_secs: { type: ['number', 'string'] },
    ceilingSecs: { type: ['number', 'string'] },
    slowSecs: { type: ['number', 'string'] },
    // temperloop#865 — the WORKER's own scoped-gate sentinel, classified by the
    // 3e.5 gate command inside the worktree it is about: 'finished' | 'running'
    // | 'absent' | 'unknown'. Parent-side evidence that the worker's gate
    // reached a RESULT rather than being backgrounded and abandoned.
    workerGate: { type: 'string' },
  },
};

// STEP_OUTCOME_SCHEMA — one element of a BATCH's results array (temperloop#942).
// Same permissive shape as SPINE_OUTCOME_SCHEMA (whose `properties` it reuses
// verbatim — #543's "do NOT touch SPINE_OUTCOME_SCHEMA" still holds; this derives
// from it, it does not mutate it) with two differences:
//   - `outcome` is NOT required, because one batched step is the read-only
//     merge-state probe (`gh pr view --json mergeable,mergeStateStatus`), whose
//     object carries no `outcome` key at all. When `outcome` IS present the
//     closed enum still applies.
//   - the merge-state fields are declared so the .mjs can branch on them.
const STEP_OUTCOME_SCHEMA = {
  type: 'object',
  required: [],
  additionalProperties: true,
  properties: {
    ...SPINE_OUTCOME_SCHEMA.properties,
    mergeable: { type: 'string' },
    mergeStateStatus: { type: 'string' },
  },
};

// SPINE_BATCH_SCHEMA — the batched executor's return: the ordered array of the
// JSON lines the batched command printed, ONE PER STEP THAT RAN. Shorter than
// the step list whenever the bash short-circuit stopped the sequence early (the
// normal, expected case — see DESIGN NOTE 1).
const SPINE_BATCH_SCHEMA = {
  type: 'object',
  required: ['results'],
  additionalProperties: true,
  properties: {
    results: { type: 'array', items: STEP_OUTCOME_SCHEMA },
  },
};

// WORKER_VERDICT_SCHEMA — matches build.md §3c's return contract. The
// worker owns only these fields (never branch/pr/pushed_sha — orchestrator-
// owned). `status` is a closed enum, 1:1 with the 3d handling branches.
//
// Output shape (temperloop#1080): the `description` on each free-prose field
// states what that field is FOR, so the shape rule reaches the worker on the
// schema surface too, not only in the prompt. Deliberately NO word numbers
// here — a JSON schema cannot enforce a string length, so the numeric bounds
// live in exactly one place (the WORKER_*_MAX_WORDS constants, interpolated
// into the prompt's `## Output shape` section) rather than being restated in a
// second surface that could drift. The two surfaces are complementary: the
// schema fixes the SHAPE (machine-validated), the prompt fixes the SIZE.
const WORKER_VERDICT_SCHEMA = {
  type: 'object',
  required: ['status'],
  additionalProperties: true,
  properties: {
    status: { type: 'string', enum: ['done', 'blocked', 'design-fork', 'failed'] },
    summary: {
      type: 'string',
      description:
        'What changed and why it satisfies the item. Outcome only — never a narration of how you got there (what you read, what you ruled out, what you tried first). Word-bounded; see the prompt\'s "Output shape" section. Detail belongs in the verification-surface FILE, not here.',
    },
    acceptance_results: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: true,
        properties: {
          criterion: {
            type: 'string',
            description: 'The acceptance bullet, verbatim — quoted, never re-worded or summarized.',
          },
          passed: { type: 'boolean' },
          evidence: {
            type: 'string',
            description:
              'A POINTER to where the criterion is verifiable: file:line, test name, or command + its verdict. Not the argument for it — that belongs in the verification-surface FILE. Word-bounded; see the prompt\'s "Output shape" section.',
          },
          discrimination_evidence: {
            type: 'string',
            description:
              'Proof this criterion\'s own check can actually FAIL, not just that it currently passes: which mechanism you removed or broke, that the suite went RED without it, and that restoring it went GREEN. Required whenever the run\'s prompt carries the "Discrimination evidence" section (temperloop#1319; today: /build only — see REQUIRE_DISCRIMINATION_EVIDENCE); omit only when this criterion genuinely has no test to discriminate. Word-bounded; see the prompt\'s "Output shape" section.',
          },
          deferred_host_config: {
            type: 'string',
            description:
              'DEFERRAL MARKER (temperloop#1182): set this ONLY when the criterion turns on a gitignored, host-local file a worktree structurally never contains (a credential file, an operator-placed secret, an env var sourced from one), and name that file/env var here. Pair it with `passed: false` — you did not confirm it. The driver then treats the criterion as DEFERRED: neither a pass nor a failure, so it does not stall the level, and the orchestrating session verifies it parent-side in the real checkout. Never set it to route around a criterion you simply could not meet, and never copy the named file into the worktree.',
          },
        },
      },
    },
    commits: { type: 'array', items: { type: 'string' } },
    verification_surface_path: { type: 'string' },
    questions: {
      type: 'array',
      items: { type: 'string' },
      description: 'One self-contained question per entry — the missing FACT you need, stated as a question. No preamble, no recap of what you already did.',
    },
    design_fork: {
      type: 'object',
      additionalProperties: true,
      properties: {
        decision: { type: 'string' },
        options: {
          type: 'array',
          items: {
            type: 'object',
            additionalProperties: true,
            properties: { label: { type: 'string' }, tradeoff: { type: 'string' } },
          },
        },
        recommendation: { type: 'string' },
        evidence: { type: 'string' },
      },
    },
    failure_reason: {
      type: 'string',
      description: 'Why the item cannot be completed AS SPECIFIED — the blocking fact, not a transcript of the attempt. Word-bounded; see the prompt\'s "Output shape" section.',
    },
  },
};

// -----------------------------------------------------------------------------
// RETRY-LOOP INVENTORY (temperloop#976)
// -----------------------------------------------------------------------------
// Every loop in this file that can RE-ATTEMPT something, with its hard cap and
// its transient-vs-deterministic disposition. Repeating a deterministically-
// failing operation cannot change its outcome, so a loop either classifies
// before retrying or states why classification does not apply. The audit is
// kept HERE, beside the budgets, so a new loop cannot be added without a
// reviewer seeing the shape it has to satisfy.
//
//   1. ciPollLoop slice loop — CAP: maxSlices = ceil(CI_POLL_TOTAL_SECS /
//      CI_POLL_SLICE_SECS). NOT A RETRY: each slice waits on external state
//      (pending check-runs) that genuinely changes between polls, and every
//      terminal verdict (CI_GREEN / CI_FAILED / NO_CI) exits the loop on the
//      spot. The deterministic cases it MUST not spin on are already short-
//      circuited by name, not by budget: CONFLICTING/DIRTY escalates
//      merge-conflict immediately (#543), a NO_CI SHA resolves through
//      ci-poll.sh's bounded grace window (temperloop#605), and any ERROR
//      escalates rather than re-polls. No classification step applies.
//   2. CI_FAILED worker re-spawn — CAP: CI_FAIL_RETRY_BUDGET (below), past
//      which the item escalates `ci-failed` for a human. NOT A RETRY EITHER, in
//      the sense that matters here: the re-attempt does not re-issue the failed
//      operation, it spawns a worker to FIX the failure and pushes a NEW SHA, so
//      the input to the next CI run differs by construction. That is what makes
//      a classify-before-retry step inapplicable — and the budget is already at
//      its floor of one, so a deterministic repeat cannot cost a second one.
//   3. null-verdict main-worker re-spawn (driveItem, ~1145) — CAP: exactly one,
//      and CLASSIFIED BEFORE IT FIRES on both axes: the recover-probe runs FIRST
//      and adopts any work that already landed (so a lost return is never re-
//      built), and the retry prompt is deliberately DIFFERENT from the first
//      (FOREGROUND_CURE appended) because a byte-identical retry re-stalls
//      identically. The read-only spike worker's null escalates with NO retry.
//   4. pr.sh `EXISTS` adoption (3f) — not a loop: a create-retry whose first
//      attempt in fact succeeded is ADOPTED as PR_OPENED rather than re-issued.
//   5. STEP_TIMEOUT disposal (temperloop#1071) — NOT A RETRY AT ALL, and named
//      here so a future edit cannot quietly make it one. A machinery step killed
//      by the workflow liveness ceiling is CLASSIFIED FIRST (pr.sh recover-probe,
//      the same ladder rule 3 uses) and then either ADOPTED (rule 4's shape: an
//      already-opened PR is taken, never re-opened) or ESCALATED. There is no arm
//      that re-issues the bounded step — push and pr-create are not idempotent,
//      and the ceiling firing is precisely the case where you cannot know whether
//      the first attempt landed.
//
// The two loops this file DELEGATES to carry their own caps + classification
// and are documented in their own scripts, not restated here: ci-poll.sh's
// gh_retry (CI_POLL_API_MAX_ATTEMPTS / _RETRY_BACKOFF / _DETERMINISTIC_PATTERN)
// and quality-gates.sh's per-gate retry via workflows/scripts/lib/gate-retry.sh
// (GATE_MAX_ATTEMPTS / GATE_RETRY_BACKOFF / GATE_DETERMINISTIC_PATTERN). The
// 3e.5 acceptance gate itself does NOT retry: a GATE_FAIL escalates
// `acceptance-gate-failed` on the first failure.
//
// -----------------------------------------------------------------------------
// Tunables (no Date.now()/Math.random() — those THROW in the runtime; all
// budgets are expressed as counts/seconds the executor agent enforces itself).
// The Workflow runtime has no shell, so these stay named constants here rather
// than build.config.sh settings — the same structural constraint that forces
// machinerySoloModel/machineryBatchModel through build.md's Step-0 hand-off.
// A tunable that genuinely needs to be operator-configurable rides that SAME
// Step-0 hand-off (an `input.*` key with an in-file default), never a config
// read from inside this file: GATE_SLICE_SECS below is the worked example.
// -----------------------------------------------------------------------------
const CI_POLL_SLICE_SECS = 240;   // one ci-poll.sh slice; < the ~10-min agent Bash cap
const CI_POLL_TOTAL_SECS = 3600;  // total wall budget across slices before escalating
const CI_FAIL_RETRY_BUDGET = 1;   // re-spawn+force-push+re-poll attempts on CI_FAILED

// --- Batched-machinery budgets (temperloop#942) ------------------------------
// AGENT_BASH_CAP_MS — the executor agent's foreground Bash ceiling (== the Bash
// tool's own 600_000ms maximum). NOTHING this file emits may ask a single Bash
// invocation to run longer; every batch timeout below is clamped to it.
const AGENT_BASH_CAP_MS = 600_000;
// BATCH_BASH_TIMEOUT_MS — the FAST batches (prelude, pr-batch). Every step there
// is a seconds-scale git/gh call, so 5 minutes is generous and far inside the
// cap. (Each of these commands previously ran alone under the Bash tool's 120s
// DEFAULT; batching several into one invocation would otherwise creep up on it,
// so the timeout is made explicit rather than inherited.)
const BATCH_BASH_TIMEOUT_MS = 300_000;
// CI_POLL_MAX_BATCH_WALL_MS / CI_POLL_SLICES_PER_BATCH — DESIGN NOTE 2's cap
// invariant, expressed as arithmetic instead of a comment. A ci-batch may occupy
// at most CI_POLL_MAX_BATCH_WALL_MS of POLLING in one Bash invocation; the number
// of CI_POLL_SLICE_SECS slices it runs is derived from that, so retuning the
// slice length can never produce a batch that outlives the agent's Bash cap
// (a 600s slice would simply yield 1 slice per batch).
const CI_POLL_MAX_BATCH_WALL_MS = 480_000;
const CI_POLL_SLICES_PER_BATCH = Math.max(
  1,
  Math.floor(CI_POLL_MAX_BATCH_WALL_MS / (CI_POLL_SLICE_SECS * 1000)),
);
// The ci-batch's Bash-tool timeout: its poll wall plus headroom for the
// interleaved `gh pr view` probes and process startup, clamped to the cap.
const CI_BATCH_BASH_TIMEOUT_MS = Math.min(
  AGENT_BASH_CAP_MS,
  CI_POLL_SLICES_PER_BATCH * CI_POLL_SLICE_SECS * 1000 + 90_000,
);

// --- 3e.5 acceptance-gate budget (temperloop#1021) ---------------------------
// HISTORY, because the shape of this block IS the fix. The gate used to carry a
// single flat Bash-tool timeout for the WHOLE quality-gates.sh suite:
// temperloop#115 raised it 120_000 -> 480_000ms when a 2-minute suite was
// SIGTERM'd mid-run and reported as GATE_FAIL on a green tree; temperloop#1021
// is the identical failure again, because the suite outgrew 480s too. A third
// raise is not available: AGENT_BASH_CAP_MS is a HARD ceiling this file cannot
// exceed, and the suite is already near it — so "raise the number" is the patch
// that is already known to decay, twice.
//
// So the budget stops being a deadline for the suite and becomes the length of
// ONE SLICE, exactly as CI_POLL_SLICE_SECS is for the CI poll (DESIGN NOTE 2).
// quality-gates.sh runs gates until its own soft budget is spent, stops CLEANLY
// BETWEEN GATES, and reports where to resume; 3e.5 loops slices until the suite
// finishes. TOTAL suite runtime is therefore unbounded by the agent's Bash cap,
// and gate-list growth can no longer manufacture a false GATE_FAIL — the decay
// path is closed structurally rather than deferred to the next raise.
//
// GATE_SLICE_SECS is a NAMED SETTING (BUILD_GATE_SLICE_SECS), handed in by the
// orchestrator at Step 0 exactly like machinerySoloModel/machineryBatchModel —
// the Workflow runtime has no shell or filesystem, so it cannot source
// build.config.sh itself (DESIGN NOTE 1). `||`, not `??`, for the same
// empty-string-safety reason documented at the model settings: an orchestrator
// that resolves an unset setting to "" must land on the in-file default, not
// pass a literal empty string through.
const GATE_SLICE_SECS_DEFAULT = 300;
// GATE_SLICE_OVERRUN_MS — the budget is checked only BETWEEN gates, so a slice's
// real wall time is its budget PLUS however long the gate that crossed it takes
// to finish, plus process startup. This is the headroom for that tail; it is what
// keeps the emitted Bash-tool timeout an outer BACKSTOP rather than the thing
// that routinely fires.
const GATE_SLICE_OVERRUN_MS = 240_000;
// Clamp: a slice budget large enough that budget+overrun would exceed the agent's
// Bash cap is silently reduced, so no operator setting can reintroduce the
// hard-kill failure this item removes.
const GATE_SLICE_SECS_MAX = Math.floor((AGENT_BASH_CAP_MS - GATE_SLICE_OVERRUN_MS) / 1000);
const GATE_SLICE_SECS = Math.max(
  30,
  Math.min(
    GATE_SLICE_SECS_MAX,
    Number(input.gateSliceSecs) > 0 ? Math.floor(Number(input.gateSliceSecs)) : GATE_SLICE_SECS_DEFAULT,
  ),
);
// --- §3e review-blocking convergence bound (temperloop#1970) -----------------
// THE FAILURE THIS BOUNDS. §3e is a cold, one-shot advisory pass, and a HIGH
// finding escalates `review-blocking` → the orchestrator loops the item back to
// 3c → the worker fixes it → a FRESH reviewer reads the now-LARGER diff. Nothing
// bounded that loop. Measured on one live item (temperloop#1938 L1, item
// `interview-command-spec`/#1962): FIVE consecutive §3e passes, four DISTINCT
// HIGHs, ZERO repeats, ~2h45m and ~1.05M subagent tokens before convergence —
// and pass 4's HIGH was CAUSED by pass 3's directed fix, while the reviewed spec
// grew 447 → 635 lines across the rounds. So the loop is partly SELF-FEEDING,
// not merely serial discovery: each round enlarges the surface the next one
// reads, and the orchestrator had to invent a stopping rule by hand at pass 5.
//
// THE OTHER HALF IS THE REVIEWER SEAT, NOT THIS BOUND. claude/agents/
// workflow-reviewer.md now instructs the seat to enumerate EVERY HIGH it can
// identify in ONE pass before it ranks or narrows; this constant is the backstop
// for when that still does not converge. Deliberately NOT a model-tier change:
// that seat is pinned `model: sonnet` by its own frontmatter, on purpose.
//
// WHAT IT DOES, PRECISELY. `REVIEW_BLOCKING_MAX_ROUNDS` caps the number of
// review ROUNDS one item's worktree may spend. On the round that reaches the
// cap, a blocking finding no longer escalates: the item continues to 3e.5/3f
// with the findings carried in the return value — into the PR body's
// `## Review notes` (the same reviewBodySuffix() render every round uses) and
// into the parked record's `review.residual_blocking` tally — so the human at
// the merge gate reads exactly what the reviewer said. ADVISORY, NEVER A
// SUPPRESSION: what stops is the automatic build-review-build loop, not the
// findings. An item that converges in fewer rounds is byte-identical to
// pre-#1970 behaviour, which is why the default preserves today's path for
// everything under the bound.
//
// ROUND COUNTING IS DURABLE, because the loop spans PROCESSES: each
// review-blocking escalation returns to the orchestrator, which re-invokes this
// workflow. The Workflow runtime has no filesystem (DESIGN NOTE 1), so the
// counter lives in the worktree's own GIT DIR (never the working tree — it must
// not show up in `git status`, in a `--scoped` gate's untracked-path resolution,
// or in a coverage manifest) and is read+bumped by reviewDiffCmd in the SAME
// machinery call §3e already makes: zero extra agent spawns. A continuation
// re-uses the worktree (3b is skipped), so the count survives exactly the loop
// it bounds; a fresh item gets a fresh worktree and therefore a fresh count.
// The CI-fix re-review (§3g) shares the counter deliberately — it is the same
// item's review budget, and counting it is the conservative direction.
//
// REVIEW_BLOCKING_MAX_ROUNDS is a NAMED SETTING (BUILD_REVIEW_BLOCKING_MAX_ROUNDS),
// handed in by the orchestrator at Step 0 exactly like GATE_SLICE_SECS above —
// the Workflow runtime cannot source build.config.sh itself. A non-positive or
// unparseable value falls back to the in-file default rather than disabling the
// bound, and the floor of 1 means no caller can configure the loop back to
// unbounded.
const REVIEW_BLOCKING_MAX_ROUNDS_DEFAULT = 3;
const REVIEW_BLOCKING_MAX_ROUNDS = Math.max(
  1,
  Number(input.reviewBlockingMaxRounds) > 0
    ? Math.floor(Number(input.reviewBlockingMaxRounds))
    : REVIEW_BLOCKING_MAX_ROUNDS_DEFAULT,
);
// --- §3e review-agent LIVENESS BOUND (temperloop#2003) -----------------------
// THE FAILURE THIS BOUNDS — the sibling of temperloop#1071 one layer up. Run
// `wf_f3b9c160-6ca` routed four §3e reviewers. Two returned. `shell-reviewer`
// was spawned and never returned: its own agent transcript ends mid-sentence at
// "Now compiling the final review output", the workflow stopped writing its
// journal, and ~41 minutes of silence followed until a human ran `TaskStop`.
// `workflow-reviewer` — MANDATORY for that item's `claude/commands/*.md` diff —
// never launched at all, because the §3e pass awaited each reviewer in turn and
// the second one never resolved.
//
// WHY THAT IS WORSE THAN A PLAIN HANG. The mandatory-reviewer contract
// (foundation#1007) guarantees `workflow-reviewer` RUNS, and `review.
// mandatory_ok` reports whether it did. A hang UPSTREAM of it in the same pass
// means neither the guarantee nor the tally is ever EVALUATED: the gate does not
// fail, it never resolves. An operator watching the tally sees nothing wrong,
// because there is no tally yet — which is exactly why the incident stayed
// invisible for 41 minutes. So the bound's job is not only to stop waiting; it
// is to make the pass ALWAYS produce a disposition.
//
// WHY THE BOUND CANNOT BE A TIMER. Same two runtime facts temperloop#1071 hit:
// `Date.now()` THROWS here and there is no timer primitive, so a deadline is not
// directly expressible. But `Promise.race` IS — what #1071 lacked was something
// that resolves ON A CLOCK to race against, and this file already owns one: a
// machinery executor running a WAIT. reviewWaitAgent() is that tick.
//
// TEMPERLOOP#2049 — WHERE THAT TICK HAS TO LIVE. The wait was first written as
// a bare inline `sleep N; printf '<json>'` Bash command. A harness permission
// control REFUSES that command shape in the machinery executor's seat, and the
// executor's prompt then told it to report the interval elapsed anyway: the
// nominal 1200s ceiling realized in ~30s, abandoning reviewers that were
// finishing normally at 177-257s. The wait now runs inside the named helper
// workflows/scripts/build/review-wait.sh (the shape ci-poll.sh already uses,
// observably honoured in the same seat for a 280s single call), and an elapse
// is honoured only when it carries the script's OWN `realized_secs`. See
// reviewWaitAgent() for the measurements and both halves of the fix.
// A reviewer is an `agent({agentType})` call, NOT a shell command, so #1071's
// emitted-shell watchdog cannot reach it; the race is the only seam that can.
//
// THE SHAPE, mirroring #1071's ceiling+observability pair exactly:
//   • REVIEW_AGENT_CEILING_SECS — the wall-clock ceiling on the WHOLE §3e pass,
//     measured from fanout start. Every routed reviewer is spawned CONCURRENTLY
//     (they are independent read-only passes; nothing ordered them), so one
//     hung agent can no longer keep a later one from launching — the observed
//     failure — and the pass costs max(reviewer) rather than sum(reviewer).
//     A reviewer still unsettled at the ceiling is ABANDONED, not killed: this
//     runtime cannot cancel an agent, and the promise is simply never awaited
//     again. Its disposition then respects mandatory-vs-advisory (runReviewers).
//   • REVIEW_AGENT_SLOW_SECS — the observability half: a pass still running at
//     this threshold emits a log() progress notice naming who is outstanding, so
//     a long review is VISIBLE well before it is given up on. 0 disables it.
// Both are NAMED SETTINGS (BUILD_REVIEW_AGENT_CEILING_SECS /
// BUILD_REVIEW_AGENT_SLOW_SECS), handed in by the orchestrator at Step 0 on the
// SAME seam as GATE_SLICE_SECS / the #1071 pair above, for the same structural
// reason (this runtime has no shell to source build.config.sh).
const REVIEW_AGENT_CEILING_SECS_DEFAULT = 1200;
const REVIEW_AGENT_SLOW_SECS_DEFAULT = 300;
// FLOOR — a ceiling below the longest LEGITIMATE wait would manufacture false
// timeouts on healthy work, which is strictly worse than the stall it bounds.
// The reference length for "one legitimate long-running unit of this pipeline"
// is one CI-poll slice or one 3e.5 gate slice, so the floor is the larger of the
// two and no operator value can go under it. Derived, never typed twice —
// retuning either slice length carries here automatically.
const REVIEW_AGENT_CEILING_FLOOR_SECS = Math.max(CI_POLL_SLICE_SECS, GATE_SLICE_SECS);
const REVIEW_AGENT_CEILING_SECS = Math.max(
  REVIEW_AGENT_CEILING_FLOOR_SECS,
  Number(input.reviewAgentCeilingSecs) > 0
    ? Math.floor(Number(input.reviewAgentCeilingSecs))
    : REVIEW_AGENT_CEILING_SECS_DEFAULT,
);
// The SLOW threshold is advisory, so it only needs to be sane: non-negative (0
// disables the notice) and never at/above the ceiling, where it could never
// fire. The explicit blank check is NOT redundant with the `> 0` form used
// above: 0 is a MEANINGFUL value here (disable), and `Number('')` is 0 — so an
// orchestrator that resolves an unset setting to "" would otherwise silently
// disable the notice instead of landing on the in-file default. Same
// empty-vs-absent hazard STEP_SLOW_SECS spells out, for the same reason.
const reviewSlowInput = input.reviewAgentSlowSecs;
const reviewSlowGiven =
  reviewSlowInput !== undefined && reviewSlowInput !== null && String(reviewSlowInput).trim() !== '';
const REVIEW_AGENT_SLOW_SECS = Math.min(
  REVIEW_AGENT_CEILING_SECS - 1,
  reviewSlowGiven && Number(reviewSlowInput) >= 0
    ? Math.floor(Number(reviewSlowInput))
    : REVIEW_AGENT_SLOW_SECS_DEFAULT,
);
// The longest single `sleep` one timer executor may hold: the Bash tool's own
// hard cap less headroom for process startup and the executor's own turn. A
// longer wait is SLICED across several timer spawns rather than asking one Bash
// invocation to outlive the cap — the same arithmetic-not-comment discipline
// CI_POLL_SLICES_PER_BATCH uses. It also stays under STEP_CEILING_FLOOR_SECS, so
// the #1071 watchdog wrapped around every machinery command never kills a timer
// that is doing exactly what it was asked to do.
const REVIEW_WAIT_SLICE_MAX_SECS = Math.floor((AGENT_BASH_CAP_MS - 60_000) / 1000);
// REVIEW_WAIT_REFUSAL_RE — the harness's OWN words for "I refused this command"
// (temperloop#2064). Matched against whatever text the timer executor relays
// (`refusal_text`, `error`, `detail`) BEFORE its own outcome label is read.
//
// WHY TEXT RATHER THAN THE EXECUTOR'S LABEL. A permission BLOCK and a Bash-tool
// TIMEOUT kill are the SAME observation to the executor — no JSON line came
// back — and exactly one of the two arms is PERMISSIVE: a tool timeout is
// honoured as elapsed, because its budget is secs+60s and can only fire AFTER
// the interval. So the executor is being asked to tell apart two states it
// cannot see, with a coin flip that lands, half the time, on "the ceiling
// expired". temperloop#2064 measured that: three slices asking 300s/540s/360s
// returned in 11s/11s/17s, a 1200s ceiling realized in ~41s, and a
// docs-reviewer that finished normally at 98s was discarded and reported as
// "unavailable". A refusal, unlike an elapse, leaves EVIDENCE the executor can
// only relay and never invent — the harness's own refusal text — so that is
// what the classification reads (kernel principle 5: counter a known AI failure
// mode STRUCTURALLY, not with a sharper instruction).
//
// FAIL-CLOSED DIRECTION. A match means "no usable timer", which makes the
// caller fail OPEN on the fanout (wait unbounded, the pre-#2003 behaviour) and
// say so. So a FALSE positive costs latency on a pathological hang; a false
// NEGATIVE discards finished reviews and reports a gate that never ran. The
// regex is therefore deliberately generous.
const REVIEW_WAIT_REFUSAL_RE =
  /<tool_use_error>|\bblocked\b|\bpermission (?:control|rule|denied)|\brefused\b|\bdenied\b|\bnot permitted\b/i;
// reviewWaitRefusalText — the first line of the refusal a timer result carries,
// or null when it carries none. Bounded in length because it lands in a log line
// and in the `timer-*` string the caller reports.
function reviewWaitRefusalText(out) {
  for (const field of ['refusal_text', 'error', 'detail']) {
    const v = out && out[field];
    if (typeof v !== 'string' || v.trim() === '') continue;
    if (!REVIEW_WAIT_REFUSAL_RE.test(v)) continue;
    return v.split('\n')[0].trim().slice(0, 160);
  }
  return null;
}
// reviewWaitSlices() — the wait, expressed as the sequence of sleeps that reach
// first the SLOW mark and then the CEILING. Deriving it from the two marks (not
// from a fixed slice length) is what keeps the timer CHEAP: a healthy pass that
// finishes inside the slow threshold pays for exactly ONE timer spawn, and a
// genuinely hung one pays a handful — never one spawn per poll interval, the
// micro-agent cost temperloop#942 exists to prevent.
function reviewWaitSlices() {
  const marks = [];
  if (REVIEW_AGENT_SLOW_SECS > 0 && REVIEW_AGENT_SLOW_SECS < REVIEW_AGENT_CEILING_SECS) {
    marks.push(REVIEW_AGENT_SLOW_SECS);
  }
  marks.push(REVIEW_AGENT_CEILING_SECS);
  const slices = [];
  let at = 0;
  for (const mark of marks) {
    let left = mark - at;
    while (left > 0) {
      const slice = Math.min(left, REVIEW_WAIT_SLICE_MAX_SECS);
      slices.push(slice);
      left -= slice;
    }
    at = mark;
  }
  return slices;
}
// The gate executor's Bash-tool timeout — derived, never typed twice. Kept under
// this name because it is still exactly that: the tool-level timeout threaded to
// the gate runMachinery call (and only that call).
const GATE_BASH_TIMEOUT_MS = Math.min(
  AGENT_BASH_CAP_MS,
  GATE_SLICE_SECS * 1000 + GATE_SLICE_OVERRUN_MS,
);
// --- Machinery-step LIVENESS BOUND (temperloop#1071) -------------------------
// THE FAILURE THIS BOUNDS. A `pr-batch` machinery agent ran 35,362,333ms — 9h49m
// — on TWO tool calls and 45k tokens. Not a retry loop, not a runaway: ONE Bash
// invocation blocked and then completed successfully (all four steps green, the
// PR opened). Every bound that should have made that unreachable failed: the
// Bash tool's `timeout` parameter is capped at AGENT_BASH_CAP_MS and the prompt
// above asks for less than that, so a 9.8h call is not supposed to exist — and
// NOTHING ELSE bounded it. The root cause is NOT established (candidates exist;
// none is acted on here without a disconfirming probe), so this is deliberately
// a ROOT-CAUSE-AGNOSTIC seam: a bound that holds regardless of WHICH hypothesis
// is true.
//
// WHY IT LIVES IN THE EMITTED SHELL, NOT IN THIS FILE'S CONTROL FLOW. Two hard
// runtime facts. (a) `Date.now()` THROWS in the Workflow runtime (see the
// tunables header above), so this file cannot measure elapsed time at all — a
// `Promise.race` deadline is not expressible here, there is no timer primitive
// to race against. (b) The thing that failed to fire IS the harness's own
// tool-timeout layer, so putting the new bound in that same layer would inherit
// the failure. So the ceiling is compiled INTO the command text every machinery
// step already runs through: a bash + `sleep` + `kill` watchdog, modelled on
// `workflows/scripts/lib/portable-timeout.sh`'s dependency-free fallback tier
// (its pipe-leak redirect included, verbatim in spirit — see stepBoundPreamble).
// It is still a WORKFLOW-LEVEL bound: this file decides it, this file emits it,
// this file branches on the STEP_TIMEOUT it produces, and it applies to every
// machinery executor (`prelude` / `pr-batch` / `ci-batch` / solo `gate`) rather
// than to any one script.
//
// WHY NOT run_with_timeout(1) ITSELF. `portable-timeout.sh`'s preferred backends
// are `timeout`/`gtimeout`, which `exec` a BINARY — they cannot run a shell
// FUNCTION, and a batched step body is exactly that (a multi-command shell
// snippet with `&&`, `;`, redirections and command substitutions). Re-wrapping
// each body as `bash -c '<quoted script>'` to reach those backends would also
// re-introduce the nested-quoting shape temperloop#72 found the auto-mode safety
// classifier reads as an obfuscated command — the class of failure that denied
// every push/worktree step on unattended runs. So the fallback tier is
// reproduced inline, with its provenance named here.
//
// The two settings are NAMED SETTINGS (BUILD_MACHINERY_STEP_CEILING_SECS /
// BUILD_MACHINERY_STEP_SLOW_SECS), handed in by the orchestrator at Step 0 on
// the SAME seam as gateSliceSecs above, and for the same structural reason. `||`
// vs `??`: same empty-string safety documented at the model settings.
const STEP_CEILING_SECS_DEFAULT = 900;
const STEP_SLOW_SECS_DEFAULT = 300;
// FLOOR — a ceiling below the longest LEGITIMATE single step would manufacture
// false timeouts on healthy work, which is strictly worse than the stall it
// bounds. The longest legitimate step is one CI poll slice or one gate slice, so
// the floor is the larger of the two plus headroom; no operator value can go
// under it. (Derived, never typed twice — retuning either slice length carries.)
const STEP_CEILING_FLOOR_SECS = Math.max(CI_POLL_SLICE_SECS, GATE_SLICE_SECS) + 300;
const STEP_CEILING_SECS = Math.max(
  STEP_CEILING_FLOOR_SECS,
  Number(input.machineryStepCeilingSecs) > 0
    ? Math.floor(Number(input.machineryStepCeilingSecs))
    : STEP_CEILING_SECS_DEFAULT,
);
// The SLOW threshold is advisory, so it only needs to be sane: non-negative (0
// disables the notice) and never at/above the ceiling, where it could never fire.
// The explicit blank check is NOT redundant with the `> 0` form used above: 0 is
// a MEANINGFUL value here (disable), and `Number('')` is 0 — so an orchestrator
// that resolves an unset setting to "" would otherwise silently disable the
// notice instead of landing on the in-file default. Same empty-vs-absent hazard
// the model settings' `||` guards, spelled out because `>= 0` cannot collapse it.
const stepSlowInput = input.machineryStepSlowSecs;
const stepSlowGiven =
  stepSlowInput !== undefined && stepSlowInput !== null && String(stepSlowInput).trim() !== '';
const STEP_SLOW_SECS = Math.min(
  STEP_CEILING_SECS - 1,
  stepSlowGiven && Number(stepSlowInput) >= 0
    ? Math.floor(Number(stepSlowInput))
    : STEP_SLOW_SECS_DEFAULT,
);

// GATE_MAX_SLICES — a bound, not a target: a suite that cannot finish in this
// many slices is escalated as a TIMEOUT (honestly named) rather than looped on
// forever. At the default slice budget this is ~40 minutes of gate wall time,
// several times today's suite.
const GATE_MAX_SLICES = 8;
// Warn when a completed run used at least this fraction of the slice budget —
// the DECAY SIGNAL. Growth becomes visible as a margin warning on green runs,
// long before it becomes a blown budget (the thing #115 had no way to see).
const GATE_MARGIN_WARN_RATIO = 0.75;

// --- 3c worker return-value output-shape bounds (temperloop#1080) ------------
// The verdict's SHAPE is already machine-enforced (WORKER_VERDICT_SCHEMA below,
// passed to every worker agent({schema}) call) — but a JSON schema can constrain
// a field's TYPE and never its LENGTH, so the two free-prose slots were bounded
// by nothing but the worker's judgment. Measured across 83 real /build worker
// verdicts recovered from subagent transcripts: `summary` ran to a median 119
// words (mean 145, max 557) against a spec asking for "1-3 sentences", and each
// `acceptance_results[].evidence` to a median 33 words (max 244) against a spec
// asking for "<file:line or test name>". Every one of those words is an OUTPUT
// token — the weight-5 class, the most expensive token this pipeline emits — and
// the orchestrator then ingests all of them.
//
// The bound is NOT information loss, and that is the whole reason it is safe:
// the worker already writes its full argument to `.build-verification.md`, a
// FILE whose path (not content) rides the verdict, and pr.sh splices that file
// into the PR body's `## Verification` section by path (`--verification-surface-
// file`) so it reaches the human reviewer WITHOUT ever entering orchestrator
// context. Bounding the verdict moves prose off the expensive path; it does not
// delete it. What must NOT survive anywhere is process narration — the worker's
// route to the answer ("first I read X, then ruled out Y") is not a finding.
//
// NAMED SETTINGS (BUILD_WORKER_SUMMARY_MAX_WORDS / BUILD_WORKER_EVIDENCE_MAX_
// WORDS), handed in by the orchestrator at Step 0 exactly like GATE_SLICE_SECS
// above — the Workflow runtime has no shell to source build.config.sh itself
// (DESIGN NOTE 1). `||`, not `??`, for the documented empty-string reason. A
// caller that omits the keys (sweep.md / fix.md today) still emits a BOUNDED
// prompt: the shape is inherited by every caller of the shared workerPrompt(),
// only the tuning is build.md's.
const WORKER_SUMMARY_MAX_WORDS_DEFAULT = 60;
const WORKER_EVIDENCE_MAX_WORDS_DEFAULT = 30;
const WORKER_SUMMARY_MAX_WORDS = Math.max(
  20,
  Number(input.workerSummaryMaxWords) > 0
    ? Math.floor(Number(input.workerSummaryMaxWords))
    : WORKER_SUMMARY_MAX_WORDS_DEFAULT,
);
const WORKER_EVIDENCE_MAX_WORDS = Math.max(
  10,
  Number(input.workerEvidenceMaxWords) > 0
    ? Math.floor(Number(input.workerEvidenceMaxWords))
    : WORKER_EVIDENCE_MAX_WORDS_DEFAULT,
);

// --- §3c test-discrimination evidence requirement (temperloop#1319) ---------
// A worker reporting `passed: true` on its own say-so is exactly the class of
// self-report this pipeline has repeatedly had to distrust — a check that
// PASSES because it can never FAIL (a mistargeted assertion, a fixture that
// never exercises the changed path) looks identical, from the returned
// verdict alone, to a check that genuinely discriminates. The fix is not more
// prose asking the worker to "verify carefully" — it is asking for the
// specific artifact that PROVES discrimination happened: which mechanism was
// removed, that the suite went red without it, that restoring it went green.
//
// Gated on a per-run input flag (`requireDiscriminationEvidence`, boolean —
// `=== true`, not `||`/`??`, since an accidentally-truthy non-boolean must
// never silently arm a requirement the caller didn't intend) rather than
// baked unconditionally into the shared workerPrompt(), on the SAME Step-0
// hand-off seam as gateSliceSecs/principlesSummaries above. workerPrompt()
// is shared by THREE callers: `/build`, `/sweep`, and `/fix`.
//
// CORRECTION (the mechanical scoping below is accurate; an earlier version of
// this comment additionally claimed /sweep and /fix structurally CANNOT carry
// real per-criterion bullets — that claim was FALSE and has been removed).
// `sweep.md`/`fix.md` both define `acceptance:` as "checkable bullets from the
// issue body", falling back to the bare-string placeholder
// `"(self-verify the issue is resolved)"` ONLY when the issue body carries
// none — and `acceptanceList()` (below) already handles the array case for
// any caller. So a real, multi-bullet acceptance array from /sweep or /fix
// DOES have exactly the per-criterion shape this requirement targets; nothing
// here makes widening to them structurally impossible.
//
// The actual reason `/build` passes `requireDiscriminationEvidence: true`
// (claude/commands/build.md Step 3 args) while `/sweep` and `/fix` omit the
// key is an OPERATIONAL SCOPE DECISION, not a structural one: temperloop#1319
// scopes this requirement to `/build` only. `/sweep` and `/fix` inherit the
// OFF default — the same caller-scoped widening `principlesSummaries`
// already establishes for a different §3c requirement — until a future item
// makes the case for extending it to them.
const REQUIRE_DISCRIMINATION_EVIDENCE = input.requireDiscriminationEvidence === true;

// --- §3c effective engineering principles (temperloop#1432) ------------------
// build.md §3c requires embedding the EFFECTIVE (kernel ∪ project) engineering
// principle set in the worker's prompt, in summary form, so the worker weighs
// its own choices against it. This file cannot resolve that itself: resolving
// it needs `claude/engineering-principles.md` (a repo FILE) merged with a
// project's `Projects/<project>/Priorities.md` § Principles (a VAULT read via
// MCP) — and the Workflow runtime has neither a filesystem nor tool access
// (DESIGN NOTE 1, same structural wall GATE_SLICE_SECS/model-tier settings hit
// above). So this rides the SAME Step-0-hand-off seam: the orchestrator
// resolves the merge ONCE PER RUN, per distinct (repo, project) pair
// (`claude/commands/build.md` § Step 1.8), and hands the RENDERED text
// straight through as `input.principlesSummaries` — a map keyed by each
// pair's `repo` string (the plan's `ownerRepo` for the default/primary pair,
// an item's own `repo:` for a cross-repo pair) — plus `input.principlesDefaultRepo`
// (== `ownerRepo`) for the items that carry no `repo:` of their own.
const PRINCIPLES_SUMMARIES =
  input.principlesSummaries && typeof input.principlesSummaries === 'object'
    ? input.principlesSummaries
    : {};
const PRINCIPLES_DEFAULT_REPO = input.principlesDefaultRepo || '';

// REVIEWER_ROUTING_TSV — temperloop#1982, the STRUCTURAL close on the relay
// defect temperloop#1976/#1995 only mitigated. `workflows/scripts/config/
// reviewer-routing.tsv` is a STATIC repo file: its content is identical on
// every run and depends on nothing the worktree computes, so routing it
// through the machinery-executor agent's verbatim-echo contract was never
// necessary — only the CHANGED-FILE list genuinely has to come from the
// worktree. Relaying it anyway put a multi-line tab-delimited table in front
// of an LLM asked to reproduce it byte-for-byte, and it was mangled in three
// distinct ways across eight observed occurrences: silently omitted; replaced
// by an English sentence *describing* the table; and (2026-09-13) returned
// DOUBLE-JSON-ENCODED — surrounding quotes plus literal two-character \t/\n
// sequences instead of real tabs and newlines, which parses as one row rather
// than eleven. Note what survived every one of those: `tsv_rows` and
// `tsv_checksum`, both small integers, were correct in all three shapes. The
// string field is the unreliable part, not the step.
//
// So this rides the SAME Step-0-hand-off seam as principlesSummaries above
// (DESIGN NOTE 1 — the Workflow runtime has no filesystem access, the
// orchestrator does): the orchestrator reads the file ONCE and hands the text
// through as `input.reviewerRoutingTsv`. When present it is authoritative and
// the agent's copy is never consulted, removing the agent from this data's
// path entirely rather than adding a fourth guard behind it. Absent (an older
// orchestrator, or a consuming-repo caller that has not wired the hand-off)
// the previous relay + retry + row/checksum-gap path stands unchanged, so
// this is additive and cannot regress an un-migrated caller.
const REVIEWER_ROUTING_TSV =
  typeof input.reviewerRoutingTsv === 'string' && input.reviewerRoutingTsv.trim()
    ? input.reviewerRoutingTsv
    : '';

// PRINCIPLES_KERNEL_FALLBACK — last-resort degradation, used ONLY when the
// orchestrator supplied no `principlesSummaries` at all this run (an older
// orchestrator, or a consuming-repo caller that has not wired the hand-off —
// all three first-party callers of this file's shared `workerPrompt()`,
// build.md/sweep.md/fix.md, resolve and pass it; #1432 wired /build,
// temperloop#1460 wired the other two). A static snapshot of `claude/engineering-principles.md`'s
// kernel-only principle NAMES — this runtime cannot read that file itself to
// stay current, so a worker on the fallback path gets a legible floor (never
// a silently empty set, which from the outside would look identical to
// "principles applied") plus an explicit notice that the project extension
// was NOT applied. See principlesSection() below for the notice text.
const PRINCIPLES_KERNEL_FALLBACK = [
  '1. Every meaningful behavior tested for every state — no coverage-percentage gate [kernel]',
  '2. Quality bars strict from day one [kernel]',
  '3. Deterministic tests over recorded fixtures, never live-network [kernel]',
  '4. Verify at the human-AI seam [kernel]',
  '5. Counter AI failure modes structurally [kernel]',
  '6. Limit blast radius through boundaries [kernel]',
  '7. Advisory over enforced discipline [kernel]',
].join('\n');

// resolvePrinciplesSummary — per-item lookup: this item's own `repo:` first
// (a cross-repo item's pair), else the default pair, else the static
// fallback. Returns { text, degraded } so the caller can append the
// degradation notice only when the fallback actually fired.
function resolvePrinciplesSummary(item) {
  const key = (item && item.repo) || PRINCIPLES_DEFAULT_REPO;
  if (key && Object.prototype.hasOwnProperty.call(PRINCIPLES_SUMMARIES, key)) {
    return { text: PRINCIPLES_SUMMARIES[key], degraded: false };
  }
  if (
    PRINCIPLES_DEFAULT_REPO &&
    Object.prototype.hasOwnProperty.call(PRINCIPLES_SUMMARIES, PRINCIPLES_DEFAULT_REPO)
  ) {
    return { text: PRINCIPLES_SUMMARIES[PRINCIPLES_DEFAULT_REPO], degraded: false };
  }
  return { text: PRINCIPLES_KERNEL_FALLBACK, degraded: true };
}

// -----------------------------------------------------------------------------
// Command-building helpers — EVERY interpolated value goes through sq().
// -----------------------------------------------------------------------------

// sq — POSIX-quote a value for safe shell interpolation. A spaced path MUST be
// quoted or the one-shot executor runs the wrong command (the live-probe
// finding). Numbers are coerced to string.
//
// TWO FORMS, CHOSEN BY CONTENT (temperloop#1806). The classic single-quote form
// escapes an embedded `'` via the `'\''` idiom, which is correct POSIX — and is
// exactly what killed a live item. The command text this file builds is not
// executed by this process: it is handed to an executor AGENT, whose Bash tool
// parses it first. A payload carrying escaped single quotes nests `'\''` inside
// a shell function inside a batch script, and that parser refused the whole
// command at PARSE time, before touching git:
//
//   {"outcome":"ERROR","step":"parse","error":"Shell parsing failed due to
//    deeply nested quotes. … multiple instances of '\'' embedded within a bash
//    function, creating an unresolvable quotation context …"}
//
// It is deterministic for a given item — a re-drive can never clear it, because
// the trigger is the item's own text — and it fires most readily on re-driven
// items whose notes quote reviewer findings or shell snippets, i.e. the items
// that have already cost the most work. sq() is the ONE definition behind all
// ~86 call sites, so the fix belongs here and nowhere else.
//
// So: a value with NO single quote keeps the single-quoted form, byte-identical
// to before (the overwhelming majority of call sites — paths, slugs, outcome
// globs). A value that DOES contain one is emitted DOUBLE-quoted instead, with
// the four characters that stay special inside double quotes (`"`, `\`, `$`,
// backtick) backslash-escaped. A double-quoted string may contain `'` verbatim,
// so no nesting is produced at any depth, and the round-trip is exact:
// everything else — newlines, `!` (history expansion is interactive-only),
// glob punctuation — is literal inside double quotes exactly as it is inside
// single ones. The two forms are interchangeable at every call site: each is a
// single self-contained shell word, including inside a `case` pattern (both
// quoting forms suppress glob expansion) and inside a `"$( … )"` substitution
// (which opens a fresh quoting context).
function sq(value) {
  const s = String(value);
  if (!s.includes("'")) return `'${s}'`;
  return `"${s.replace(/(["\\$`])/g, '\\$1')}"`;
}

// -----------------------------------------------------------------------------
// The step LIVENESS BOUND, compiled into the command text (temperloop#1071).
// -----------------------------------------------------------------------------
// See the STEP_CEILING_SECS block above for WHY the bound lives in the emitted
// shell rather than in this file's control flow (no Date.now(), no timer, and
// the layer that failed to fire IS the tool-timeout layer). These three helpers
// are the HOW.
//
// stepBoundPreamble(slowSecs) — the prologue every bounded command carries: the
// two budgets as plain shell variables, then `__lb`, which runs ONE step body
// under them. `__lb` is the dependency-free fallback tier of
// `workflows/scripts/lib/portable-timeout.sh`, reproduced here (that library's
// preferred `timeout`/`gtimeout` backends `exec` a BINARY and cannot run a shell
// FUNCTION, which is what a step body is). Two details are load-bearing and both
// come straight from that file's header:
//   • the watchdog subshell is redirected AT THE SUBSHELL BOUNDARY
//     (`) </dev/null >/dev/null 2>&1 &`). Without it, its `sleep` grandchild
//     inherits the caller's `$( … )` pipe write-end and every FAST, successful
//     step stalls for the full ceiling waiting on EOF (foundation #861).
//   • the watchdog is killed AND reaped on the fast path, so a completed step
//     leaves nothing behind.
// The kill is best-effort DEEP: direct children first (`pkill -P`, so the helper
// script dies before the subshell that owns it), then the subshell itself. A
// deeper grandchild (a `gh` inside a `pr.sh`) can still outlive the bound — which
// is exactly why a timed-out step is disposed through the recover-probe rather
// than blind-retried: the workflow stops WAITING on it without ever assuming it
// did nothing.
//
// The step body's own stdout is untouched — it flows to wherever the caller put
// it (a `$( … )` capture in a batch, the script's stdout for a solo call), so the
// machinery's "one JSON line per step" contract is preserved byte for byte on
// every healthy run. `__lb` only ADDS a line, and only in the two abnormal cases:
// STEP_TIMEOUT (replacing a result the kill destroyed) and STEP_SLOW (an advisory
// riding alongside a real result — hence `slowSecs` is 0 on the SOLO path, whose
// schema admits exactly one object).
function stepBoundPreamble(slowSecs) {
  return [
    `__lb_ceil=${STEP_CEILING_SECS}; __lb_slow=${slowSecs}`,
    '__lb() {',
    '  __lbk=$1; shift',
    '  __lbt=$(date +%s)',
    '  "$@" &',
    '  __lbp=$!',
    // Kill ORDER is load-bearing, and the obvious order is wrong. Killing the
    // step's children FIRST unblocks the step body — which then races ahead and
    // runs its NEXT command (printing a result the workflow must not believe)
    // before the kill of the body itself lands. Measured, not theorised: with
    // children-first, a `sleep 30; printf …` step still printed its `printf`.
    // So: SNAPSHOT the direct children, kill the body, THEN kill the snapshot
    // (once the body dies its children reparent, and `pgrep -P` can no longer
    // find them — hence the snapshot rather than a second lookup).
    '  ( sleep "$__lb_ceil" 2>/dev/null; __lbc=$(pgrep -P "$__lbp" 2>/dev/null); kill -9 "$__lbp" 2>/dev/null; [ -n "$__lbc" ] && kill -9 $__lbc 2>/dev/null ) </dev/null >/dev/null 2>&1 &',
    '  __lbw=$!',
    '  wait "$__lbp" 2>/dev/null; __lbr=$?',
    '  kill "$__lbw" 2>/dev/null; wait "$__lbw" 2>/dev/null',
    '  __lbe=$(( $(date +%s) - __lbt ))',
    // Timed out iff BOTH the step died by SIGNAL and the wall clock actually
    // reached the ceiling. The second test is what keeps a step that legitimately
    // exits on a signal of its own from being mislabelled LOST.
    '  if [ "$__lbr" -ge 128 ] && [ "$__lbe" -ge "$__lb_ceil" ]; then',
    `    printf '{"outcome":"STEP_TIMEOUT","step":"%s","ceiling_secs":%s,"elapsed_secs":%s}\\n' "$__lbk" "$__lb_ceil" "$__lbe"`,
    '    return 137',
    '  fi',
    '  if [ "$__lb_slow" -gt 0 ] && [ "$__lbe" -ge "$__lb_slow" ]; then',
    `    printf '{"outcome":"STEP_SLOW","step":"%s","elapsed_secs":%s,"slow_secs":%s,"ceiling_secs":%s}\\n' "$__lbk" "$__lbe" "$__lb_slow" "$__lb_ceil"`,
    '  fi',
    '  return "$__lbr"',
    '}',
  ].join('\n');
}

// stepFnDef — wrap a step's command text VERBATIM in a shell function, so `__lb`
// can background it as one unit. The body is placed on its own line (never
// `{ <cmd>; }`) precisely so a command that already ends in `;` or `fi` stays
// valid, and so not one byte of the sq()-quoted command text is rewritten.
function stepFnDef(name, cmd) {
  return `${name}() {\n${cmd}\n}`;
}

// stepBoundInvoke — the call itself. `kind` is the batch step's own name (or the
// solo call's phase), and it rides through to the STEP_TIMEOUT payload so an
// escalation names WHICH step the ceiling bounded.
function stepBoundInvoke(name, kind) {
  return `__lb ${sq(kind)} ${name}`;
}

// machineryBin — resolve a build-SPINE script (worktree.sh / pr.sh / ci-poll.sh),
// which lives in the FOUNDATION repo (workflows/scripts/build/). A consuming repo
// (stageFind) normally reaches it via a dev-local `workflows/` symlink into
// foundation — but that symlink is NOT guaranteed in every checkout (#560: a
// stageFind checkout lacking it escalated at pr.sh with `push-error: script path
// does not exist`). We run in the Workflow sandbox (no fs / Node API), so the
// fallback is done in BASH, emitted as a quoted command-substitution: prefer
// <repoRoot>/workflows/scripts/build; if that dir is absent, locate the
// foundation checkout via $FOUNDATION, the deployed workflow symlink
// ($HOME/.claude/workflows/build-level.mjs → foundation, best-effort — a BSD
// readlink without -f just fails that candidate), or the TEMPERLOOP_HOME
// bootstrap-clone convention (bin/bootstrap.sh's own default,
// $HOME/.local/share/temperloop — never a hardcoded personal dev path,
// temperloop#406; the legacy FOUNDATION_HOME fallback was removed in
// v0.19.0 with the rest of the temperloop#165 window). If none resolve, the
// emitted path points at the missing
// repo-local dir and the machinery script's own "not found" (exit 127) surfaces
// loudly. NOTE:
// only machinery scripts route through here; the project's OWN vendored gate
// (scripts/quality-gates.sh) is repo-local and is resolved directly against
// the WORKTREE checkout (see 3e.5, temperloop#626), never via this fallback.
function machineryBin(repoRoot, name) {
  // De-obfuscated fast path (temperloop#72). When the orchestrator has already
  // resolved the build-machinery directory in its OWN shell (build.md Step 0, and
  // sweep.md/fix.md Step 0 as of temperloop#1460 — all three callers pass it) and
  // passed it as input.machineryBinDir, emit a PLAIN quoted absolute path. The
  // executed machinery command line then carries NO nested `$(readlink …)`
  // command-substitution — the very construct the auto-mode safety classifier
  // read (together with the runMachinery "run exactly" instruction) as an
  // obfuscated-command bypass, denying every push/worktree machinery step on
  // --unattended/pipeline runs. A literal path reads as an ordinary script call.
  if (typeof input.machineryBinDir === 'string' && input.machineryBinDir.length > 0) {
    return sq(input.machineryBinDir + '/' + name);
  }
  // Fallback (no pre-resolved dir — older invocations, or a consuming repo that
  // does not yet pass machineryBinDir): resolve in BASH, exactly as before (#560).
  const local = sq(repoRoot + '/workflows/scripts/build');
  return '"$(d=' + local + '; ' +
    'if [ ! -d "$d" ]; then for c in ' +
    '"${FOUNDATION:-}/workflows/scripts/build" ' +
    '"$(dirname "$(readlink -f "$HOME/.claude/workflows/build-level.mjs" 2>/dev/null)" 2>/dev/null)/../../workflows/scripts/build" ' +
    '"${TEMPERLOOP_HOME:-$HOME/.local/share/temperloop}/workflows/scripts/build"; ' +
    'do [ -d "$c" ] && { d="$c"; break; }; done; fi; ' +
    "printf '%s' \"$d/" + name + '")"';
}

// Repo "owner/repo" — the orchestrator passes it in input.ownerRepo (the
// workflow has no shell to derive it). ci-poll.sh / gate ops take owner/repo;
// push/scan take the worktree path. WITHOUT input.ownerRepo every ci-poll gets
// '' → ERROR, so the orchestrator MUST pass it (Step 0 probe). See the I/O note.

// -----------------------------------------------------------------------------
// THE EXECUTOR AGENT TYPE — context size is the machinery agents' cost (#1014).
// -----------------------------------------------------------------------------
// A machinery executor's whole job is one Bash call, but a `general-purpose`
// agent carries the FULL harness surface to make it: every tool schema, the
// skill listing, the deferred-tool listing. That is dead weight on every spawn
// and it is charged TWICE for the two executors that exceed the ~300s
// prompt-cache TTL by construction — the CI poll (waiting IS its job) and the
// minutes-scale 3e.5 gate. Their post-wait call is a total cache miss: the whole
// context is re-WRITTEN at weight 1.25 instead of re-READ at 0.1, so the excess
// is proportional to CONTEXT SIZE, not to the length of the wait (#1014).
//
// So machinery executors run as `machinery-executor` (claude/agents/), whose
// tool surface is Bash alone (+ the runtime's own StructuredOutput, appended
// automatically when a schema is passed) and whose system prompt carries the
// standing "run it verbatim, return each step's JSON line" contract that every
// per-call prompt used to restate. Measured on this harness, same prompts, same
// machine (temperloop#1014): ci-batch 37,428 -> 30,856 first-call
// cache_creation tokens, 3e.5 gate 37,201 -> 30,734 (-17.5%). The residual is
// almost entirely the installed CLAUDE.md (measured at 25,714 tokens, identical
// under both agent types) — which the harness injects into every non-built-in
// agent and NO agent definition can decline, so it is out of this file's reach.
// Of the context this file CAN reach, the lean type removes 56%.
//
// FALLBACK, NOT A DEPENDENCY. A checkout that has not deployed the agent
// definition (`workflows/scripts/install/project-agents.sh`) must still build.
// agent() rejects an unresolvable (or permission-denied) agentType at RESOLUTION
// time — before any subagent is spawned, so nothing has run and re-issuing the
// call is safe — with a message naming `agent({agentType})` and the type it could
// not resolve. machineryAgent() catches exactly that shape once, pins the type to
// 'general-purpose' for the rest of the run, and re-issues with the full prompt.
// Any OTHER failure propagates untouched: a blind retry of a machinery command is
// NEVER safe (push / pr-create are not idempotent), so the match is deliberately
// narrow — two independent markers of a resolution failure, never a catch-all.
// An explicit input.machineryAgentType (orchestrator-supplied) overrides the
// default and disables the probe.
const MACHINERY_RESOLUTION_ERR = /agent\(\{agentType\}\)|agent type '[^']*' (?:not found|is denied)/;
const MACHINERY_AGENT_TYPE_DEFAULT = 'machinery-executor';
let machineryAgentType =
  typeof input.machineryAgentType === 'string' && input.machineryAgentType.length > 0
    ? input.machineryAgentType
    : MACHINERY_AGENT_TYPE_DEFAULT;

// machineryAgent — spawn a machinery executor. `promptFor(lean)` builds the
// prompt for the resolved agent type: `lean` is true when the executor's own
// definition already carries the standing contract, false for the
// general-purpose fallback, which needs it spelled out per call as before.
async function machineryAgent(promptFor, opts) {
  const wanted = machineryAgentType;
  try {
    return await agent(promptFor(wanted !== 'general-purpose'), { ...opts, agentType: wanted });
  } catch (err) {
    const msg = String((err && err.message) || err);
    if (wanted === 'general-purpose' || !MACHINERY_RESOLUTION_ERR.test(msg)) throw err;
    log(`machinery executor '${wanted}' unavailable — using general-purpose (${msg})`);
    machineryAgentType = 'general-purpose';
    return await agent(promptFor(false), { ...opts, agentType: 'general-purpose' });
  }
}

// -----------------------------------------------------------------------------
// ONE MEANING, ONE NAME — the machinery-outcome key canonicalizer (temperloop#1698).
// -----------------------------------------------------------------------------
// The closed outcome set carries TWO names for one concept. The step-liveness
// bound (temperloop#1071) emits `elapsed_secs` / `ceiling_secs` / `slow_secs`;
// the 3e.5 gate emits `elapsedSecs` / `budgetSecs`; and the permissive
// passthrough schema admits BOTH on ANY outcome. An executor that normalizes a
// GATE_PASS toward the sibling spelling therefore produces a structurally VALID
// object that the consumer — `Number(gateOut.elapsedSecs) || 0` — reads as
// `Number(undefined) || 0` → **0**. Observed live (run wf_9ce4bd0c-58b): a gate
// whose own log said "passed in 215s" was reported as "0s of gate wall time".
//
// That figure is the DECAY SIGNAL — the instrument whose whole job is to make
// suite growth visible on GREEN runs, before it blows a budget (the failure
// #1021 and #1663 both exist because of). An instrument that reads zero when it
// does not know is worse than one that reads nothing.
//
// The fix is a single normalization at the TRANSPORT boundary rather than a
// `??` chain at each read site (which re-opens the defect for the next field):
// CANONICAL = camelCase, everywhere downstream of here. The snake_case key is
// left in place on the object — it is what the emitted shell actually prints and
// what escalation payloads echo verbatim — but no CONSUMER in this file reads it
// any more, so the two spellings can no longer disagree about one value.
const OUTCOME_KEY_ALIASES = {
  elapsed_secs: 'elapsedSecs',
  ceiling_secs: 'ceilingSecs',
  slow_secs: 'slowSecs',
  budget_secs: 'budgetSecs',
};
function canonicalizeOutcome(o) {
  if (o == null || typeof o !== 'object') return o;
  for (const snake of Object.keys(OUTCOME_KEY_ALIASES)) {
    const camel = OUTCOME_KEY_ALIASES[snake];
    if (o[camel] === undefined && o[snake] !== undefined) o[camel] = o[snake];
  }
  return o;
}

// The STRICT numeric read this canonicalization needs — "the value, or null when
// it is absent, empty or unparseable" — already exists as numOrNull() (defined
// with the cost-ledger helpers below, hoisted, and written for exactly this
// class of defect: "a machinery field that is genuinely absent must degrade to
// null, never a false zero"). #1698's gate read below calls it rather than
// declaring a second one, so the two can never drift apart.

// -----------------------------------------------------------------------------
// runMachinery — the sh() replacement (spike §1).
// -----------------------------------------------------------------------------
// Spawns a one-shot executor agent that runs EXACTLY one machinery command via Bash
// and returns its single closed-outcome JSON line, schema-validated. No model
// override beyond haiku (cheapest tier — the executor does no reasoning); NO
// isolation:'worktree' (the machinery scripts manage their own worktrees, §5).
// `phase` (temperloop#1294) is the caller's STAGE group name — the string
// enterStage()/stagePhase() returned. It is passed EXPLICITLY rather than read
// off the global phase() cursor, which races under parallel(). The `?? 'machinery'`
// fallback keeps a caller that omits it on the pre-#1294 flat group rather than
// on whatever stage happens to be current.
async function runMachinery(cmd, { label, slug, bashTimeoutMs, timeoutOutcome, phase: phaseName } = {}) {
  // temperloop#1071: the command runs under the workflow's own wall-clock
  // ceiling. `slowSecs` is 0 on this path — a solo executor returns exactly ONE
  // object by schema, so an advisory second line has nowhere to go. The step
  // `kind` is the label's phase ('gate' / 'recover-probe' / 'push-retry'), which
  // is what a STEP_TIMEOUT payload then names.
  const soloKind = String(label ?? '').split(':')[0] || 'solo';
  const boundedCmd = [
    stepBoundPreamble(0),
    stepFnDef('__s0', cmd),
    stepBoundInvoke('__s0', soloKind),
  ].join('\n');
  // Wording (temperloop#72): describe the command as a KNOWN build-machinery helper
  // script that self-reports its result, rather than telling the sub-agent to
  // "run exactly / do NOT interpret" an opaque line. The old phrasing, paired
  // with the nested-readlink path resolution, read to the auto-mode safety
  // classifier as an instruction to blindly execute an obfuscated command.
  // BOTH framing lines stay in the LEAN prompt too: the auto-mode classifier
  // sees the prompt (and the agent type), never the agent's system prompt, so
  // the #72 framing is not something the executor definition can absorb.
  const promptFor = (lean) =>
    [
      'Run this single build-machinery helper command with the Bash tool, exactly as written.',
      'It is a known project script (worktree.sh / pr.sh / ci-poll.sh / claim.sh); do not add flags, chain extra commands, or rewrite it.',
      // temperloop#1071: the emitted text now opens with a few lines of inline
      // `sleep`/`kill` watchdog before the helper call. Name it, so the executor
      // reads the wrapper as part of the command rather than as noise to strip
      // (the same #72 lesson that made the two framing lines above explicit).
      'It opens with a small inline wall-clock watchdog (a `sleep`/`kill` guard) that bounds how long the helper may run; that guard is PART of the command — run the whole thing, do not strip or shorten it.',
      // temperloop#115: for a legitimately long-running command (the 3e.5 gate),
      // raise the Bash TOOL's timeout parameter — NOT the command text — so the
      // executor does not kill it at the default 2 minutes.
      bashTimeoutMs
        ? lean
          ? `Set the Bash tool \`timeout\` parameter to ${bashTimeoutMs}.`
          : `This command runs longer than usual. When you invoke the Bash tool, set its \`timeout\` parameter to ${bashTimeoutMs} (milliseconds). That is a Bash tool parameter only — do NOT alter the command text — and it prevents the default 2-minute timeout from killing the run.`
        : null,
      // The three lines below are the executor's STANDING contract, identical on
      // every call — claude/agents/machinery-executor.md carries them, so the
      // lean prompt omits them (#1014).
      lean ? null : 'It prints a SINGLE JSON line on stdout describing its own result (a closed `outcome` set).',
      lean ? null : 'Return that JSON object verbatim as your result — the schema captures it.',
      lean ? null : 'If the command exits non-zero it STILL prints its JSON line; return that line.',
      // temperloop#1021: name the TIMEOUT case explicitly. NOT lean-guarded, and
      // deliberately so: unlike the three standing lines above, this one is
      // per-call (it fires only when a caller passes `timeoutOutcome`) and it
      // interpolates a dynamic outcome name, so it cannot live in the static
      // machinery-executor.md agent definition the lean prompt relies on.
      // Without this line the executor, having been killed by the Bash tool
      // before any JSON line was
      // printed, picks the closest failure-shaped enum member it knows — which
      // for the gate is GATE_FAIL. That silently reported a GREEN suite as
      // BROKEN and made a budget-exhaustion escalation indistinguishable from a
      // real gate failure. The timeout is a fact about the BUDGET, never about
      // the tree, so it gets its own outcome and the executor is told to use it
      // rather than guess.
      timeoutOutcome
        ? `If the Bash tool's own timeout kills the command BEFORE it prints any JSON line, do NOT guess a failure outcome and do NOT re-run it: return exactly {"outcome":"${timeoutOutcome}"}. A timeout means the time budget ran out — it is NOT evidence that anything failed, and reporting it as a failure is a known defect (temperloop#1021).`
        : null,
      '',
      'Command:',
      boundedCmd,
    ].filter(Boolean).join('\n');
  const out = await machineryAgent(
    promptFor,
    {
      label: label ?? `machinery:${cmd.split(' ').slice(0, 2).join(' ')}`,
      phase: phaseName ?? 'machinery',
      // temperloop#982: orchestrator-supplied workflow input, NOT a config-file
      // read (this runtime has no shell — DESIGN NOTE 1). `||`, NOT `??` —
      // `??` only falls through on null/undefined, and a caller (or an
      // omitted-vs-empty prose mistake upstream) can easily hand this an
      // empty string, which `??` would pass straight through as a literal
      // "" model and silently defeat the fallback. `||` collapses BOTH the
      // absent-input case (build.md didn't resolve BUILD_MACHINERY_SOLO_MODEL,
      // or the key was omitted) AND an empty-string input to the same
      // 'haiku' default — UNCHANGED from before this setting existed, the
      // byte-identical-when-unset contract this item ships under. This is the
      // load-bearing invariant; it lives here (the consumer), not in the
      // orchestrator prose (the producer), so it holds regardless of how
      // build.md/sweep.md/fix.md construct the input.
      model: input.machinerySoloModel || 'haiku',
      schema: SPINE_OUTCOME_SCHEMA,
      // NB: deliberately NO isolation:'worktree' — see DESIGN NOTE 3.
    },
  );
  // Null-guard (temperloop#72): agent() returns null when the run is DENIED by
  // the auto-mode safety classifier (or a user skip / transient API error).
  // Every consumer below dereferences `.outcome`, so a raw null crashed the
  // whole level with `null is not an object`. Normalize it to a closed
  // SPINE_DENIED sentinel — a well-formed outcome object every call site can
  // detect (via machineryDenied()) and turn into a parkable `machinery-denied`
  // escalation instead of a TypeError.
  // temperloop#1698 — canonicalize the duration keys ONCE, here at the
  // transport boundary, so every consumer below reads exactly one spelling.
  return out == null ? { outcome: 'SPINE_DENIED', denied: true } : canonicalizeOutcome(out);
}

// -----------------------------------------------------------------------------
// runMachineryBatch — the BATCHED sh() replacement (temperloop#942).
// -----------------------------------------------------------------------------
// Runs SEVERAL machinery commands inside ONE executor agent (one Bash
// invocation), returning each step's own closed-outcome JSON object so the
// driver keeps branching per-step in .mjs. See DESIGN NOTE 1 for why this does
// not weaken the bridge's invariant.
//
// A step is { kind, cmd, continueOutcomes?, stopGlobs? }:
//   kind             — a short name; it appears in the prompt's `Steps:` manifest
//                      and in a denial payload, and is what the .mjs indexes by.
//   cmd              — the fully sq()-quoted command text, byte-identical to what
//                      the un-batched runMachinery call used to send.
//   continueOutcomes — the outcome(s) that permit the NEXT step to run. Anything
//                      else stops the sequence (the .mjs then branches on this
//                      step's object and escalates, exactly as before).
//   stopGlobs        — the inverse form, for a step with no `outcome` key (the
//                      merge-state probe): raw substrings that, if present, stop
//                      the sequence.
// The last step needs neither — nothing follows it.
//
// The bash short-circuit is a STOP-EARLY MIRROR, not the decision: it only
// avoids running steps whose result the .mjs is about to discard anyway. The
// authoritative branch is always the `if` in .mjs reading the same JSON.

// globPat — a `case` pattern matching any line CONTAINING `sub`. The literal is
// single-quoted (via sq) so the shell never glob-expands the JSON punctuation.
function globPat(sub) {
  return `*${sq(sub)}*`;
}

// batchCommand — join the steps into ONE shell script: run, echo, gate, repeat.
// Each command's stdout is captured with `$( … )` (stderr flows through to the
// executor's transcript untouched, as before) and echoed verbatim, so the
// machinery's own "single JSON line" contract is preserved per step.
function batchCommand(steps) {
  // temperloop#1071: every step runs under the workflow's wall-clock ceiling, and
  // the batch path DOES carry the STEP_SLOW advisory (its schema is an ARRAY of
  // objects, so an extra notice line has somewhere to go — runMachineryBatch
  // partitions it back out before the driver ever indexes a step).
  const lines = [stepBoundPreamble(STEP_SLOW_SECS)];
  steps.forEach((s, i) => {
    const v = `__o${i}`;
    const fn = `__s${i}`;
    lines.push(stepFnDef(fn, s.cmd));
    lines.push(`${v}=$( ${stepBoundInvoke(fn, s.kind)} )`);
    lines.push(`printf '%s\\n' "$${v}"`);
    if (i === steps.length - 1) return; // nothing follows — no gate needed
    if (s.stopGlobs && s.stopGlobs.length > 0) {
      // A timed-out step stops the sequence on BOTH gate forms. The
      // continueOutcomes form gets it for free (STEP_TIMEOUT is not a continue
      // outcome); the stopGlobs form is a stop-LIST, so the bound's own outcome
      // has to be named in it or a bounded merge-state probe would let the poll
      // slice behind it run against a step whose result was destroyed.
      const stops = [...s.stopGlobs.map(globPat), globPat('"outcome":"STEP_TIMEOUT"')];
      lines.push(`case "$${v}" in ${stops.join('|')}) exit 0 ;; esac`);
    } else if (s.continueOutcomes && s.continueOutcomes.length > 0) {
      const pats = s.continueOutcomes.map((o) => globPat(`"outcome":"${o}"`)).join('|');
      lines.push(`case "$${v}" in ${pats}) ;; *) exit 0 ;; esac`);
    }
  });
  return lines.join('\n');
}

// runMachineryBatch — returns { denied, results, steps, out }. `results[i]` is
// step i's object; the array is SHORTER than `steps` whenever the sequence
// short-circuited (expected). `denied:true` is the batched twin of
// machineryDenied() — agent() returned null (auto-mode classifier DENIED the
// command / user skip / terminal API error) or gave back no usable array.
// `phase` (temperloop#1294): the caller's STAGE group name — see runMachinery().
async function runMachineryBatch(steps, { label, slug, bashTimeoutMs, phase: phaseName } = {}) {
  if (!steps || steps.length === 0) {
    return { denied: false, results: [], steps: [] };
  }
  const kinds = steps.map((s) => s.kind);
  // Lean vs full prompt: see machineryAgent() above (#1014). The two #72 framing
  // lines and the `Steps:` manifest stay on BOTH paths — the classifier reads
  // the prompt, and the manifest is per-call, not standing contract.
  const promptFor = (lean) =>
    [
      'Run this build-machinery command sequence with the Bash tool, exactly as written, in ONE Bash invocation.',
      'It is a short shell script that calls known project helper scripts (worktree.sh / pr.sh / ci-poll.sh / claim.sh / gh) one after another; do not add flags, reorder or split the steps, or rewrite it.',
      `Steps: ${kinds.join(', ')}`,
      // temperloop#115 rationale, applied per batch: for a legitimately
      // long-running sequence raise the Bash TOOL's timeout parameter — NOT the
      // command text — so the executor does not kill it at the default 2 minutes.
      bashTimeoutMs
        ? lean
          ? `Set the Bash tool \`timeout\` parameter to ${bashTimeoutMs}.`
          : `This sequence runs longer than usual. When you invoke the Bash tool, set its \`timeout\` parameter to ${bashTimeoutMs} (milliseconds). That is a Bash tool parameter only — do NOT alter the command text — and it prevents the default 2-minute timeout from killing the run.`
        : null,
      // Standing contract — carried by claude/agents/machinery-executor.md on
      // the lean path, restated per call on the general-purpose fallback.
      lean ? null : 'Each helper prints a SINGLE JSON line on stdout describing its own result (a closed `outcome` set).',
      lean ? null : "The script deliberately STOPS EARLY when a step's result means the remaining steps must not run. FEWER JSON lines than steps is expected and correct — never an error, never something to re-run, retry, or work around.",
      lean ? null : 'Return every JSON object it printed on stdout, in stdout order, as {"results": [ ... ]}. Copy each object VERBATIM — do not merge, summarise, reorder, add, drop, or invent entries — and ignore any non-JSON output.',
      lean ? null : 'If a step exits non-zero it STILL prints its JSON line; include it.',
      '',
      'Command:',
      batchCommand(steps),
    ]
      .filter(Boolean)
      .join('\n');
  const out = await machineryAgent(
    promptFor,
    {
      label: label ?? `machinery-batch:${kinds.join('+')}`,
      phase: phaseName ?? 'machinery',
      // temperloop#982: orchestrator-supplied workflow input, NOT a config-file
      // read (this runtime has no shell — DESIGN NOTE 1). `||`, NOT `??` — see
      // the twin runMachinery() comment above for why: `??` lets an
      // empty-string input sail through as a literal "" model, silently
      // defeating the fallback; `||` collapses both absent AND empty-string
      // input to 'haiku', UNCHANGED from before this setting existed. The
      // invariant lives here (the consumer), not in orchestrator prose.
      model: input.machineryBatchModel || 'haiku',
      schema: SPINE_BATCH_SCHEMA,
      // NB: deliberately NO isolation:'worktree' — see DESIGN NOTE 3.
    },
  );
  if (out == null || !Array.isArray(out.results)) {
    return {
      denied: true,
      results: [],
      steps: kinds,
      out: out ?? { outcome: 'SPINE_DENIED', denied: true },
    };
  }
  // temperloop#1071 — PARTITION the advisory notices out of the results array
  // BEFORE anyone indexes it. A STEP_SLOW line is emitted alongside a real
  // result, not in place of one, so leaving it in would shift every later step's
  // index by one and silently mis-branch the whole batch. Filtering here (once,
  // at the transport) is what lets every `batchStep(batch, i)` call site below
  // stay exactly as it was.
  // temperloop#1698 — canonicalize every step's duration keys at this same
  // transport boundary (the batch twin of runMachinery's call above), BEFORE
  // the partition below and before any `batchStep(batch, i)` consumer.
  out.results.forEach(canonicalizeOutcome);
  const notices = out.results.filter((r) => r && r.outcome === 'STEP_SLOW');
  const results = out.results.filter((r) => !(r && r.outcome === 'STEP_SLOW'));
  // …and LOG them. This is the observable-progress half of the bound: a step
  // that outran its expected duration but has NOT hit the ceiling is not lost
  // and is not disposed — it is simply made visible, which is the one thing the
  // 9h49m stall never was.
  for (const n of notices) {
    log(
      // temperloop#1698: canonical camelCase reads, fed by canonicalizeOutcome
      // above — the `?? '?'` fallback is now the ONLY zero-free way an unknown
      // figure can render here, never a silent 0.
      `[${slug ?? label ?? 'level'}] machinery step '${n.step ?? '?'}' took ${n.elapsedSecs ?? '?'}s ` +
      `— over the ${n.slowSecs ?? STEP_SLOW_SECS}s expected-duration mark, still under the ` +
      `${n.ceilingSecs ?? STEP_CEILING_SECS}s liveness ceiling (temperloop#1071). Not lost, not retried — ` +
      `raise BUILD_MACHINERY_STEP_SLOW_SECS if this step is legitimately this slow.`,
    );
  }
  return { denied: false, results, steps: kinds, out };
}

// batchStep — step i's outcome object, or a closed ERROR sentinel when the batch
// returned nothing for it. A missing entry normally means the .mjs has ALREADY
// escalated on an earlier step (the short-circuit); the sentinel exists so a
// malformed executor return degrades into the step's own error branch rather
// than a TypeError on `.outcome`.
function batchStep(batch, i) {
  const r = batch.results[i];
  return r == null
    ? { outcome: 'ERROR', error: `machinery step '${batch.steps[i] ?? i}' produced no result` }
    : r;
}

// batchDeniedStep — what to name in a `machinery-denied` payload. A one-step
// batch names its only step (so a solo worktree/gate denial reads exactly as it
// did before batching); a multi-step batch names the batch itself and carries
// the full step list alongside.
function batchDeniedStep(batch, batchName) {
  return batch.steps.length === 1 ? batch.steps[0] : batchName;
}

// -----------------------------------------------------------------------------
// Worker prompt assembly (3c).
// -----------------------------------------------------------------------------
// acceptanceList — `acceptance` may be an array of bullets (the /build plan
// path) OR a single string (/sweep passes one string) — normalize to an array
// (#437). Shared by workerPrompt and the #939 recovery record, so the criteria
// a recovered record marks UNVERIFIED are exactly the ones the worker was given.
function acceptanceList(item) {
  return Array.isArray(item.acceptance)
    ? item.acceptance
    : item.acceptance
      ? [item.acceptance]
      : [];
}

// principlesSection — the §3c "effective engineering principles" block
// (temperloop#1432), a SELF-CONTAINED section appended once into
// workerPrompt()'s array (below) rather than threaded through existing
// lines, so a sibling edit to workerPrompt() (e.g. #1319) rebases cleanly on
// this one. Embeds the orchestrator-resolved (or, on the degraded path,
// static-fallback) summary verbatim — this file never re-derives the merge
// itself (see the PRINCIPLES_* block above for why it can't).
function principlesSection(item) {
  const resolved = resolvePrinciplesSummary(item);
  const lines = [
    '## Effective engineering principles — weigh your choices against these',
    'This is the SAME merged (kernel ∪ project) principle set build.md § Step 1.8',
    'resolves once for this run and § 3e hands the pre-push reviewer for this',
    "item's (repo, project) pair — reused here, not re-derived. Weigh your own",
    'choices against it, and if your own summary cites a principle-shaped',
    'concern, name the principle and its origin (`kernel` or `project`).',
    '',
    resolved.text,
  ];
  if (resolved.degraded) {
    lines.push(
      '',
      'DEGRADED — no orchestrator-resolved principle set reached this worker this run',
      '(`principlesSummaries` was absent — an older orchestrator, or a consuming-repo',
      "caller that has not wired build.md's Step 1.8 hand-off; /build, /sweep and /fix",
      'all resolve and pass it). The list above is a STATIC KERNEL-ONLY',
      'snapshot — this runtime has no filesystem to read',
      '`claude/engineering-principles.md` itself — with NO project `## Principles`',
      'extension applied. Treat it as a floor, never as confirmation the project slot',
      'is empty.',
    );
  }
  return lines;
}

// discriminationEvidenceSection — the §3c "test-discrimination evidence"
// requirement (temperloop#1319), a SELF-CONTAINED section appended once into
// workerPrompt()'s array, mirroring principlesSection()'s shape so a sibling
// edit to workerPrompt() rebases cleanly. Gated on REQUIRE_DISCRIMINATION_
// EVIDENCE (see that constant's own comment above for the full rationale,
// including the correction on why /sweep and /fix are excluded — an
// operational scope decision, not a structural one) — returns an EMPTY
// array, not a degraded/notice variant, when the caller didn't ask for it:
// unlike principlesSummaries' "never silence" rule, an unrequired discipline
// staying silent is correct here, since REQUIRE_DISCRIMINATION_EVIDENCE is
// false for any caller that never armed the requirement in the first place.
function discriminationEvidenceSection() {
  if (!REQUIRE_DISCRIMINATION_EVIDENCE) return [];
  return [
    '',
    '## Discrimination evidence — prove each check can actually FAIL (temperloop#1319)',
    'A self-report that a check "passed" is worthless if the check could never have',
    'failed. For EVERY acceptance criterion above, report — in that criterion\'s',
    '`acceptance_results[].discrimination_evidence` field — the evidence that your',
    'verification actually DISCRIMINATES pass from fail, at minimum:',
    '- **Which mechanism you removed or broke** to exercise the negative case (the',
    '  specific call, guard, assertion, or behavior the criterion depends on).',
    '- **That the suite went RED without it** — the failing run, command + verdict.',
    '- **That restoring it went GREEN** — the passing run, command + verdict.',
    'A criterion you never watched fail is unverified, no matter how confidently you',
    'report it `passed: true` — a vacuously-passing check is indistinguishable from a',
    'real one in the returned verdict alone, which is exactly the failure this field',
    'exists to close. If a criterion genuinely has no test to discriminate (a docs-only',
    'change, a config value with no behavior to break), say so explicitly in that field',
    'rather than leaving it empty. **Two DISTINCT exemptions, worded differently — do not',
    'conflate them:** (1) too coarse to discriminate (above) — say so in your own words;',
    '(2) a criterion naming the BARE repo-wide gate, which you never run (#997) and',
    'therefore never watched red or green — for that one write EXACTLY',
    '`deferred to §3e.5; discrimination not established worker-side` in the field, never',
    'left empty and never fabricated. Like `evidence`, keep it to a compact pointer — at',
    `most ${WORKER_EVIDENCE_MAX_WORDS} words — never a narrative.`,
  ];
}

// hostConfigDeferralSection — the §3c host-config/secret deferral contract
// (temperloop#1182), a SELF-CONTAINED section appended once into
// workerPrompt()'s array, mirroring discriminationEvidenceSection()'s shape.
//
// WHY IT IS UNGATED. Unlike discrimination evidence, this is not a discipline
// a caller opts into — it is a STRUCTURAL fact about every worktree on every
// path (/build, /sweep, /fix all route through this same prompt): `git
// worktree add` populates from the git INDEX, so a gitignored host-local file
// is never present, on any host, ever. foundation#1556 is the measured
// instance: an item whose acceptance was "`pipeline-retro-judge-spawn.sh
// --dry-run` reports credential_present" read `false` in the worktree and
// `true` in BOTH real checkouts moments later. The worker did the right thing
// (reported rather than went looking), but nothing structural stopped it from
// "helpfully" copying the token into a non-gitignored path — which is the
// exposure /assess A.8 exists to prevent, and a strictly worse failure than
// the unverified criterion.
//
// The bar is NOT relaxed (A.8 still demands confirmed-set, not location-named):
// what this changes is WHO confirms, not WHETHER. The worker defers; the
// orchestrating session, which runs in the real checkout, verifies parent-side
// after hand-back, fed by park()'s host_config_deferrals field.
//
// UNGATED IS ONLY SOUND BECAUSE ALL THREE PATHS HAVE A SEAT. Each invoking
// spec owns a parent-side verification step for the deferral this section
// produces — build.md §4a, sweep.md's per-chunk merge pass, fix.md Step 5's
// modal gate (and build.md §3h.5's as-you-go tier explicitly EXCLUDES an item
// carrying the field, since that path bypasses §4a). See the seat list in the
// I/O CONTRACT above. If a future path starts invoking this driver, it either
// grows its own seat or this section stops being ungated — shipping the
// instruction to a path with no seat is how a deferral auto-merges unverified.
function hostConfigDeferralSection() {
  return [
    '',
    '## Host-config / gitignored-file criteria — DEFER, never confirm (temperloop#1182)',
    'Your worktree is populated from the git INDEX, so a gitignored host-local file — a',
    'credential file such as `workflows/scripts/build/build.config.local.sh`, an',
    'operator-placed secret, an env var sourced from one — is NEVER present here. Any',
    'acceptance criterion that turns on such a file is structurally unverifiable from this',
    'worktree: an absent/`false` reading is UNINFORMATIVE, not a failure, and it reads',
    'identically on a host where the file IS correctly configured.',
    '- **Do NOT carry, copy, recreate, or hunt elsewhere for the named file.** Landing a',
    '  credential anywhere inside this worktree is the secret-in-worktree exposure the',
    '  host-config seam exists to prevent — a worse failure than the unverified criterion.',
    '- **Report the criterion as DEFERRED, never as passed.** Set `passed: false` (you did',
    '  not confirm it) AND set `deferred_host_config` to the file or env var it turns on',
    '  (e.g. `workflows/scripts/build/build.config.local.sh (SENTRY_AUTH_TOKEN)`). That',
    '  PAIR is the deferral marker: the driver reads it as neither a pass nor a failure, so',
    '  it does not stall the level, and the orchestrating session — which runs in the real',
    '  checkout and CAN see the file — verifies it parent-side after you hand back.',
    '- **`passed: false` WITHOUT `deferred_host_config` still means blocked.** Never claim a',
    '  pass you structurally cannot make, and never set the marker to route around a',
    '  criterion you merely failed to meet — it defers WHO verifies, never WHETHER.',
    '- If this run also asks for `discrimination_evidence`, a deferred criterion\'s reads',
    '  exactly `deferred to parent-side host-config verification` — never fabricated.',
  ];
}

// changelogFragmentSection — the §3c "add your own changelog.d/ fragment"
// instruction (temperloop#1530), a SELF-CONTAINED section appended once into
// workerPrompt()'s array, mirroring principlesSection()'s /
// discriminationEvidenceSection()'s shape so a sibling edit to workerPrompt()
// rebases cleanly. WHY THE WORKER, NOT A PARENT-SIDE CHECK: the issue's own
// prose names two options (tell the worker vs. run check-changelog-entry.sh
// parent-side before pr.sh open) — this instructs the worker because that is
// PREVENTION (the fragment lands in the same commit, no round trip) rather
// than DETECTION (a parent-side check still costs a re-spawn once it fires,
// just earlier than CI); it does not restate the fragment's filename grammar
// or body rules here — those live in ONE place, changelog.d/README.md — so
// this section and that file can't drift out of sync with each other. The
// escape hatch it names is the ONE opt-out channel that works before a PR
// exists (a commit-message trailer — check-changelog-entry.sh's own header),
// so a worker that judges its change non-shipping RECORDS that choice rather
// than silently omitting the fragment.
function changelogFragmentSection(item) {
  return [
    '',
    '## Changelog fragment — contract-surface changes need one (temperloop#1530)',
    'If this item touches contract surface (a public interface, schema, CLI flag,',
    'or gate behavior — see `VERSIONING.md` § The contract surface for the exact',
    'set), add your OWN changelog fragment as part of this change, in the same',
    'commit as the change or a follow-up commit on this branch — the same way you',
    'are told to run the gates. Read `changelog.d/README.md` for the filename',
    'grammar and body rules; this prompt does not restate them, so follow that',
    'file, not a guess. Name the file',
    `\`changelog.d/${item.slug}.<category>.md\` (prefix the item's own issue number`,
    "when you know it from the item block above, per the README's `<issue#>-<slug>`",
    "convention — the slug alone is still a valid filename if you don't).",
    '',
    'If this change genuinely ships nothing changelog-worthy, do not just omit the',
    'fragment — RECORD that choice: add a `Changelog: none — <reason>` line as a',
    'commit-message trailer (the one opt-out channel that works before a PR',
    'exists; see `changelog.d/README.md` § Status). An omitted fragment with no',
    'recorded reason reads as an oversight, not a decision — CI will fail on it',
    'exactly once (check-changelog-entry.sh), costing a re-spawn round trip this',
    'section exists to avoid.',
  ];
}

// gateRegistrationChecklistSection — the §3c "new gate script? register it"
// checklist (temperloop#1931), a SELF-CONTAINED section appended once into
// workerPrompt()'s array, mirroring discriminationEvidenceSection()'s shape.
// UNGATED, like hostConfigDeferralSection() — every /build, /sweep and /fix
// worker can add a new check-*.sh/validate-*.sh/test_*.sh, so every worker
// needs the checklist, not just an opted-in caller.
//
// WHY THIS EXISTS: #1931's observed instance — three of five workers in one
// /build level shipped a new validator/test that went RED on
// validate-check-surface-degenerate-coverage.sh (and its test), and two also
// missed gate-paths.tsv/setting-registry.tsv rows, because the worker's own
// `--scoped` run (temperloop#957) selects gates by DIFF PATH: a brand-new
// script's path matched no row in gate-paths.tsv until the worker itself
// registered one, so the very gates that would have caught the omission
// never ran worker-side — each miss cost a full parent-side sliced
// acceptance-gate round trip (about 10-20 minutes). gate-paths.tsv now also
// carries generic new-surface globs closing the SELECTION half of that gap
// (see its own header, temperloop#1931) — this section is the PREVENTION
// half: naming the registries up front so the worker registers before its
// own scoped run ever needs to catch the omission after the fact.
function gateRegistrationChecklistSection() {
  return [
    '',
    '## New gate script? Register it before running the scoped gate (temperloop#1931)',
    'If this change adds or RENAMES a gate, validator, checker, test, or setting,',
    'register it FIRST — before your own `--scoped` run above — so that run can',
    'actually catch a mistake in the registration itself, not just in the script:',
    '- A new/renamed `check-*.sh` / `validate-*.sh` script (a "check surface") →',
    '  `workflows/scripts/config/check-surface-registry.tsv` (not yet shipping its',
    '  degenerate-input coverage? a `pending`/`excluded` row in',
    '  `workflows/scripts/config/check-surface-discovery.tsv` naming why, or a',
    '  documented row on `workflows/scripts/config/check-surface-degenerate-allowlist.tsv`).',
    '- Any new gate `scripts/quality-gates.sh` invokes → a row in',
    '  `workflows/scripts/config/gate-paths.tsv` (validated by `check-gate-paths.sh`).',
    '- A script meant to be run directly (the `workflows/scripts/validate-*.sh` /',
    '  `check-*.sh` family) → `workflows/scripts/config/exec-bit-registry.tsv`.',
    '- Any new tracked path at all → BOTH coverage manifests,',
    '  `workflows/scripts/kernel/kernel-manifest.txt` AND',
    '  `docs/features/feature-manifest.txt` (two independent, both-mandatory gates',
    '  over the same tree — a claim in only one leaves the other red).',
    '- A new `: "${SETTING_NAME:=default}"` this change introduces →',
    '  `workflows/scripts/config/setting-registry.tsv`.',
    'Registering after a parent-side red costs a full sliced acceptance-gate round',
    'trip (about 10-20 minutes) this checklist exists to avoid.',
  ];
}

// activationProofSection — the temperloop#1934 "show the worker its own
// class-A activation predicate" section, a SELF-CONTAINED section appended
// once into workerPrompt()'s array, mirroring gateRegistrationChecklistSection()'s
// shape so a sibling edit to workerPrompt() rebases cleanly. Gated on
// activationClass(item) === 'A' (defined below — hoisted, so the forward
// reference from here is fine): an absent `activation` block, or a class
// B/C block, renders NOTHING, so this section changes zero bytes of the
// prompt for those items (the acceptance's byte-identical requirement).
//
// WHY THIS EXISTS: the live instance (epic #1910, item join-key-registry) —
// the worker built and wired `join-keys-lib.sh`, but the plan's `proof:`
// predicate grepped for the producer-chosen literal `join_keys`, a name the
// worker never saw and had no reason to preserve. The worker's own
// acceptance bullets all passed; §3e.6 then failed the whole item on a name
// mismatch the worker was never shown, costing a full re-drive round trip.
// Rendering the `proof:` command VERBATIM — not a paraphrase of what it
// checks — lets the worker see the exact reachability surface the
// orchestrator will run and either name its own artifacts to match, or, if
// the predicate genuinely conflicts with the acceptance bullets, say so
// (`blocked`) instead of guessing a silent rename that may or may not agree
// with what §3e.6 actually runs.
function activationProofSection(item) {
  if (activationClass(item) !== 'A') return [];
  const proof = typeof item.activation.proof === 'string' ? item.activation.proof.trim() : '';
  if (!proof) return [];
  return [
    '',
    '## Class-A activation gate — the reachability predicate you are gated on (temperloop#1934)',
    "This item's plan carries a class-A `activation:` block. Before your PR can be pushed,",
    'the orchestrator runs the EXACT command below — the reachability predicate — against',
    'this worktree (build.md §3e.6), strictly after your own acceptance self-check and gate',
    'run and before push. It reads false until your built code is genuinely reachable on the',
    'running path, not merely present:',
    '',
    '```',
    proof,
    '```',
    '',
    'Name and wire your artifacts so this predicate PASSES — treat the surface it names (a',
    'function/symbol name, a file path, a config key) as fixed, not a suggestion open to your',
    'own naming choice. If the predicate names a surface that genuinely CONTRADICTS the',
    'acceptance bullets above (the two disagree on what the consumer-facing name or shape',
    'should be), do NOT silently rename your own artifact to match and do NOT weaken or',
    'reinterpret the predicate — return `blocked` with a question naming the conflict so a',
    'human resolves it before any further work.',
  ];
}

// parentSummarySection — the epic #1847 Produces #7 companion: injects the
// parent epic's own "group summary" into an admitted epic member's worker
// prompt, a SELF-CONTAINED section appended once into workerPrompt()'s
// array, mirroring changelogFragmentSection()'s shape so a sibling edit to
// workerPrompt() rebases cleanly. Gated on `item.parentSummary` — set ONLY
// by /sweep's Step 3 items[] construction for a member it admitted via Step
// 1 item 6 (Operational-epic member admission); a plain singleton, and every
// /build plan item, never carries the field, so this returns an empty array
// and the section is silently absent. Unlike principlesSection()'s DEGRADED
// notice, there is no "missing" case to flag here: an item with no parent
// epic genuinely has no group summary to inject, so silence is correct, not
// a degradation.
function parentSummarySection(item) {
  if (!item.parentSummary) return [];
  const epicRef = item.parentEpic ? `#${item.parentEpic}` : 'the parent epic';
  return [
    '',
    '## Parent epic context',
    `This item is one member of a larger epic (${epicRef}) that drives its members`,
    "through /sweep's Operational-epic member admission path (temperloop#1847) —",
    'the epic itself carries no plan-note ceremony, so this is the only place its',
    "framing reaches you. It is context for WHY this item exists; it does not",
    "change or extend this item's own Acceptance bullets above.",
    '',
    String(item.parentSummary).trim(),
  ];
}

// -----------------------------------------------------------------------------
// THE WORKER GATE SENTINEL — a RESULT artifact, not a process (temperloop#865).
// -----------------------------------------------------------------------------
// Both Level-1 workers of epic #810 backgrounded `scripts/quality-gates.sh`,
// then polled for a PID to exit instead of reading the run's result, and ended
// their turn with no verdict. 2/2 — AGAINST A PROMPT THAT NAMED THE EXACT
// FAILURE AND PRESCRIBED THE FIX, and one of them re-stalled after being told in
// so many words to go read the output file. The issue's own acceptance forbids
// the obvious response: "demonstrated by whatever mechanism is chosen, not by a
// re-worded warning". A third wording is not a fix; this is kernel principle 5
// (counter AI failure modes STRUCTURALLY) applied to the engine's own seam.
//
// So THREE structural changes replace the warning:
//
//  1. THE WORKER NO LONGER COMPOSES ITS OWN GATE INVOCATION. workerGateCmd()
//     below is built by the orchestrator and handed over verbatim, so the shape
//     of the run is not a choice the worker makes turn by turn.
//  2. THAT INVOCATION ALWAYS LEAVES A RESULT. It writes `{"state":"running"}`
//     before the suite starts and overwrites it with
//     `{"state":"finished","rc":N,"elapsedSecs":S}` when the suite ends, then
//     prints the sentinel as its final line. A worker that loses the tool output
//     — backgrounded, reaped, timed out — polls the FILE and gets a verdict. A
//     PID poll cannot ever succeed (the exit status is gone with the process,
//     and a subagent receives no background-task notification at all); an
//     ARTIFACT poll can. That is the issue's candidate 2, and candidate 1's
//     "hand the worker an invocation" half.
//  3. THE RESIDUAL FAILURE IS LOUD. The parent-side 3e.5 gate command classifies
//     this same file from the same worktree and reports `workerGate` on its own
//     outcome, so the driver logs a NAMED notice when the sentinel still reads
//     `running`. Today "waiting for the gate" is indistinguishable from a
//     healthy long gate until the budget is gone; after this, a stalled worker
//     reads differently from a slow one in the run log and in the gate payload.
//
// NOT IN SCOPE (recorded, deliberately not implemented): the issue's candidate 3
// — move the gate out of the worker entirely. It is an architectural subtraction
// touching every worker on every run and must not ride a five-defect PR.
//
// WHY /tmp, NOT THE WORKTREE. It mirrors the 3e.5 gate's own `/tmp/qg-<slug>.log`
// convention, and it keeps a machine-written file out of the tree `pr.sh rebase`
// and the leak guard inspect — an untracked artifact inside the worktree would
// need a matching `info/exclude` entry in worktree.sh, which is outside this
// item's scope and would make the fix a cross-script change.
function workerGateSentinel(slug) {
  return `/tmp/qg-${slug}.worker-gate.json`;
}

// workerGateLog — where the handed invocation tees the suite's own output, so a
// worker that must explain a red gate has the text as well as the exit code.
function workerGateLog(slug) {
  return `/tmp/qg-${slug}.worker-gate.log`;
}

// workerGateState — the sentinel classification the 3e.5 gate reported, or
// 'absent'. An older vendored path, a spike, or a worker that legitimately ran
// no gate all read 'absent', which is deliberately NOT a warning: the prompt
// itself permits "if you cannot cheaply tell which gates apply, run none and
// say so". Only `running` (started, never finished) and `unknown` (a sentinel
// with no state) mean something went wrong.
const WORKER_GATE_STATES = ['finished', 'running', 'absent', 'unknown'];
function workerGateState(out) {
  const s = out && typeof out.workerGate === 'string' ? out.workerGate : '';
  return WORKER_GATE_STATES.includes(s) ? s : 'absent';
}

// workerGateCmd — the ONE invocation the worker is handed. Foreground by
// construction (it ends by printing its own result), always-sentinel-writing by
// construction (both the `running` and the `finished` writes are unconditional
// steps of the same command line), and it exits with the gate's own status so a
// worker that only reads the exit code still gets the truth.
//
// `set -o pipefail` is load-bearing for the same reason it is in gateCmd
// (temperloop#68): the suite is piped through `tee`, and without it `$?` would
// be tee's 0 and a RED gate would write `"rc":0` into the sentinel — a silent
// green, which is the single worst thing this artifact could do. The exit status
// is read as a bare `$?`, never PIPESTATUS[0], which expands empty under the zsh
// this harness's Bash tool actually runs (temperloop#801).
//
// EVERY PROLOGUE STEP HARD-REFUSES; NONE OF THEM IS `&&`-CHAINED INTO THE RUN
// (review round 2, the HIGH). `A && B && C; D` is NOT a guard: it skips `B..C`
// on `A`'s failure and then runs `D` anyway. That shape — which this function
// shipped in its first cut — meant a failed `cd` (worktree pruned, moved, or an
// unresolvable path) skipped both the `running` sentinel AND `set -o pipefail`
// and then ran `./scripts/quality-gates.sh` in whatever directory the worker's
// shell happened to start in, recording a RED suite in the WRONG repo as
// `{"state":"finished","rc":0}` with a nonsense `elapsedSecs` (`__t0` unset, so
// the arithmetic read it as 0). That is precisely the silent green the comment
// above calls the worst thing this artifact could do, reintroduced by the fix
// for it. So each prologue step is now its own statement ending in an explicit
// `|| exit`, and `set -o pipefail` comes FIRST — before anything it protects —
// rather than being `&&`-chained after work that has already happened:
//
//   - `set -o pipefail || exit 1` — a shell without pipefail refuses here. A
//     POSIX special builtin's failure exits a non-interactive shell outright
//     (dash), and the `|| exit 1` catches the lenient shells that merely return
//     non-zero. Either way nothing downstream runs unprotected.
//   - `[ -x ./scripts/quality-gates.sh ] || exit 127` — "this repo has no gate"
//     refuses BEFORE any sentinel is written, so `absent` (never `finished`)
//     is what both the worker and §3e.5 see. Before this, a missing script ran
//     as an ENOENT through the pipe and the NEXT statement wrote
//     `{"state":"finished","rc":127}` unconditionally — which the handed prompt
//     then told the worker to report as "a real FAIL", turning a repo with no
//     gate into a gate failure (review round 2, the MEDIUM).
//   - `cd … || exit 1` and the `running` write's own `|| exit 1` — the suite
//     can never run outside the worktree, and can never run with no artifact to
//     poll.
//
// The invariant to preserve on any future edit: a `finished` sentinel is
// reachable ONLY after the suite actually ran, in the worktree, under pipefail.
function workerGateCmd(slug, worktreePath) {
  const sent = sq(workerGateSentinel(slug));
  const glog = sq(workerGateLog(slug));
  return (
    `set -o pipefail || exit 1; ` +
    `cd ${sq(worktreePath)} || exit 1; ` +
    `[ -x ./scripts/quality-gates.sh ] || { echo 'no executable ./scripts/quality-gates.sh in this repo — no gate to run' >&2; exit 127; }; ` +
    `__t0=$(date +%s) || exit 1; ` +
    `printf '{"state":"running","startedAt":%s}\\n' "$__t0" > ${sent} || exit 1; ` +
    `./scripts/quality-gates.sh --scoped 2>&1 | tee ${glog}; __rc=$?; ` +
    `printf '{"state":"finished","rc":%s,"elapsedSecs":%s}\\n' "$__rc" "$(( $(date +%s) - __t0 ))" > ${sent}; ` +
    `cat ${sent}; exit $__rc`
  );
}

// workerGateSection — the prompt half, a SELF-CONTAINED section spliced into
// workerPrompt()'s array (the same shape principlesSection() /
// changelogFragmentSection() use) so a sibling edit to workerPrompt rebases
// cleanly on this one. It does not re-warn: it hands over the command and names
// the artifact to poll.
function workerGateSection(slug, worktreePath) {
  const sent = workerGateSentinel(slug);
  return [
    '',
    '## Your scoped gate — run THIS EXACT command (temperloop#865)',
    'Do NOT compose your own gate invocation. Run this one, verbatim, in the',
    'FOREGROUND (one blocking Bash call, with the tool `timeout` parameter raised):',
    '',
    '```sh',
    workerGateCmd(slug, worktreePath),
    '```',
    '',
    `Once the suite actually STARTS it always writes a RESULT SENTINEL to \`${sent}\` —`,
    '`{"state":"running",…}` first, then `{"state":"finished","rc":<exit>,"elapsedSecs":<n>}`',
    'when it ends — and prints that sentinel as its last line. It refuses outright rather than',
    'starting the suite in the wrong place or without `pipefail` (the exit-code table below), and',
    'a refusal writes NO sentinel at all, so the sentinel never describes a run that did not happen.',
    '- **Poll the RESULT FILE, never a PID.** Waiting on a process id, a `kill -0`, or a',
    '  background-task notification is the stall this replaces: the exit status dies with',
    '  the process, and a subagent receives no background-task notification at all, so that',
    '  poll can never succeed. Reading the sentinel always can.',
    `- If your Bash call came back without the sentinel line, \`cat ${sent}\`.`,
    '  `state:"finished"` + `rc:0` is a PASS; `state:"finished"` + non-zero `rc` is a real',
    '  FAIL you can report; `state:"running"` means it is still going; no file at all means',
    '  it never started.',
    '- NEVER report a gate pass without a `state:"finished"` sentinel. If you cannot get one,',
    '  return `blocked` and quote the sentinel (or its absence). The orchestrator reads this',
    '  SAME file at §3e.5 and reports what it finds either way, so an unfinished gate is',
    '  visible whether you mention it or not.',
    '- **A missing sentinel is a REFUSAL, never a pass.** The command hard-refuses instead of',
    '  guessing, and every refusal happens BEFORE any sentinel is written, so `no file at all`',
    '  + a non-zero exit always means the suite never ran. The three refusals, by exit code:',
    `    - **127** — this repo has no executable \`scripts/quality-gates.sh\`. It prints`,
    '      `no executable ./scripts/quality-gates.sh` on stderr and leaves NO sentinel. Say so',
    '      and move on: that is not a gate failure, and it is the one case where a missing',
    '      sentinel is expected rather than a stall.',
    `    - **1, with a \`cd\` error on stderr** — the worktree moved or was pruned. The suite is`,
    '      NOT run somewhere else and passed off as this item\'s gate. Report it as blocked.',
    `    - **1–2, with a \`pipefail\` error on stderr** — it needs **bash** (it opens with`,
    '      `set -o pipefail`, which POSIX `sh` does not have). The Bash tool gives you one; if',
    '      some wrapper hands it to a plain `sh`, it aborts on that first line. Report it as',
    '      blocked.',
    '  In all three, never infer a green gate from the missing sentinel.',
  ];
}

function workerPrompt(item, worktreePath, extraSection) {
  const accList = acceptanceList(item);
  const accBullets = accList
    .map((a) => `  - ${typeof a === 'string' ? a : JSON.stringify(a)}`)
    .join('\n');
  return [
    `You are a /build implementation worker for item \`${item.slug}\`.`,
    '',
    '## Workspace — STRICT isolation',
    `- Your Bash cwd and ALL edits MUST be under: ${worktreePath}`,
    '- Make every Edit/Write path relative to that cwd, or absolute UNDER it.',
    `  NEVER write to the parent checkout — a PreToolUse guard (.build-guard`,
    '  marker) structurally rejects out-of-worktree writes.',
    '- Commit on the current branch. Do NOT push. Do NOT open a PR.',
    '- No issue-closing keywords (Closes/Fixes/Resolves + #N) in commit messages —',
    '  GitHub auto-closes on default-branch merge from commit messages too.',
    '',
    // #1072 — the near-miss this institutionalizes: a build worker (temperloop#635)
    // spawned a context-inheriting fork for a narrow read-only sub-task; the fork
    // INHERITED the "drive to done and commit" mission, fabricated a completion
    // report, and committed to the shared worktree (self-recovered — see
    // Mistakes/foundation - research fork inherits drive-to-done context and
    // commits to shared worktree). Embedded here, structurally, rather than left
    // to a vault note someone has to remember to re-paste — mirrors how the
    // foreground-only contract below is embedded rather than left to prose alone.
    '## No context-inheriting research forks',
    '- BANNED: spawning a context-inheriting `fork` for a narrow READ-ONLY sub-task',
    '  (e.g. gathering conventions, reading code). A fork inherits this ENTIRE prompt,',
    '  including "implement the item, drive to done, and commit" — so a fork spawned',
    '  for research still carries that mission and may edit, commit, or fabricate a',
    '  completion report instead of returning findings (observed: temperloop#635).',
    '- SANCTIONED: a FRESH, explicitly-scoped read-only subagent (`Explore` /',
    '  `general-purpose`) with a read-only, return-findings-ONLY prompt and no',
    '  write/commit instructions — it does not inherit the drive-to-done mission.',
    '  A `fork` is also fine if its OWN prompt explicitly OVERRIDES the inherited',
    '  mission ("read-only; return findings ONLY; make no edits and no commits").',
    '- This does NOT ban build.md\'s "Seat scoping — nested review delegation" (a',
    '  focused REVIEW nested agent for context control) — that is the sanctioned',
    '  pattern above, not the banned one.',
    '- Treat any nested-agent report as UNTRUSTED until you independently re-verify',
    '  it against ground truth.',
    '',
    '## Item',
    `- title: ${item.title}`,
    `- scope: ${item.scope ?? '(see source)'}`,
    `- source: ${item.source ?? '(none)'}`,
    item.notes ? `- notes: ${item.notes}` : null,
    ...parentSummarySection(item),
    '',
    '## Acceptance (self-verify each before returning done)',
    accBullets || '  - (none specified)',
    ...activationProofSection(item),
    ...discriminationEvidenceSection(),
    '',
    '## Verification surface — write to a FILE, return only the path',
    `Write your verification-surface markdown block to ${worktreePath}/.build-verification.md`,
    'and return its path as `verification_surface_path`. Do NOT inline it in the JSON.',
    '',
    // §3c "No long-running background work" (#1219). Embedded in the generated
    // prompt — NOT left to prose the caller may forget — so every worker (main
    // AND spike, both route through workerPrompt) is told up front to foreground
    // the gate. Without this the worker backgrounds quality-gates.sh, yields, and
    // returns no verdict (build.md §3c/§3d must stay in lockstep with this block).
    //
    // temperloop#997 adds the SCOPE half of the same contract: the worker must not
    // run the BARE, repo-wide suite in its own context at all. That run is minutes-
    // scale, and one blocking turn that long blows the ~5-min prompt-cache TTL — the
    // worker's whole ~213K-token context is then re-WRITTEN (weight 1.25) instead of
    // re-READ (0.1) on the next call. The ACCEPTANCE run stays parent-side at 3e.5
    // (unchanged, still the authority — the PR #309 silent-red lesson; since
    // temperloop#1663 that run is itself diff-scoped through the same map, which
    // changes WHICH gates it runs but not WHO decides acceptance). The two
    // halves live in ONE section on purpose: foreground-only governs HOW the worker
    // runs its checks, #997 governs WHICH checks it runs, and dropping either one
    // re-opens a measured defect. build.md §3c carries both in lockstep.
    '## Quality gate & long-running work — FOREGROUND ONLY (#1219)',
    '- Run EVERY verification command you DO run in the FOREGROUND (a blocking Bash',
    '  call): the changed-file-scoped gate run below, plus any eval / build / sweep.',
    '- NEVER launch one with `run_in_background: true`, and never end your turn awaiting',
    '  a Monitor / background-task notification. A subagent has NO re-invoke-on-completion',
    '  loop: a backgrounded process is reaped when you yield and the notification never',
    '  reaches you — you hang and return NO verdict. A turn that ends while awaiting a',
    '  background task is the #1219 bug, not a valid return.',
    '- Do NOT run the BARE, repo-wide `scripts/quality-gates.sh` (or a whole-suite `make`',
    '  equivalent) in your own context (#997). That suite is minutes-scale, and one',
    '  blocking turn that long blows the ~5-minute prompt-cache TTL: your ENTIRE',
    '  accumulated context is then re-written instead of re-read on the very next call,',
    '  a 12.5x token penalty. Run the CHANGED-FILE-SCOPED mode instead (#957):',
    '  `scripts/quality-gates.sh --scoped` selects the gates your own working-tree',
    '  changes reach (committed, staged, unstaged AND untracked), always runs the',
    '  enumerated global-by-nature floor, NAMES every gate it skipped, and stamps its',
    '  verdict `[SCOPED SUBSET — NOT a full-suite pass]`; anything it cannot resolve',
    '  widens to the full set. If the repo\'s gate script has no `--scoped` flag, fall',
    '  back to picking by hand: `scripts/quality-gates.sh --list` prints every gate as',
    '  `[layer] <make target>`; run only the few targets that cover the files you',
    '  touched. Keep EACH call to seconds. If you cannot cheaply tell which gates',
    '  apply, run none and say so.',
    '- That subset is FAST LOCAL FEEDBACK ONLY — it is NOT the acceptance authority.',
    '  The orchestrator runs the acceptance gate parent-side (build.md §3e.5) and THAT',
    '  run is the authority; a red there comes back to you as a re-spawn. So when an',
    '  acceptance criterion names the bare repo-wide suite, do NOT run it: report it',
    '  `passed: true` only if your targeted subset is green, and state plainly in its',
    '  `evidence` that the repo-wide check was DEFERRED to the parent-side 3e.5 gate',
    '  (itself diff-scoped since #1663 — the deferral is to a different ACTOR, the',
    '  orchestrator running against your commit, not to a wider PATH scope).',
    '  Never report `passed: false` for a merely DEFERRED criterion — that reads as',
    '  blocked and stalls the whole level on a check you were never meant to run.',
    '- If a single command would exceed the ~10-min Bash foreground cap — or the tighter',
    '  ~5-min cache-TTL budget above — NARROW or split it, or return `blocked` / `failed`',
    '  and let the orchestrator run it parent-side — never background-and-wait.',
    // temperloop#865 — the STRUCTURAL half of the same contract. The block above
    // is the warning that failed 2/2; this hands over a pre-composed invocation
    // and a result ARTIFACT to poll, so the failure it names is no longer the
    // worker's to make. See workerGateSection()'s own header.
    ...workerGateSection(item.slug, worktreePath),
    // temperloop#1182 — the OTHER thing a worker structurally cannot verify.
    // Deliberately its own section, not a bullet inside the block above: that
    // block is about the COST of a check (minutes-scale, cache-TTL); this one
    // is about a check that cannot produce a meaningful reading here at all,
    // and whose "helpful" resolution leaks a secret. Ungated — see the
    // function's own comment. build.md §3c carries the prose half in lockstep.
    ...hostConfigDeferralSection(),
    '',
    // temperloop#1931 — placed right after the FOREGROUND-ONLY block's own
    // `--scoped` instructions (a few lines up) and its hostConfig sibling, so
    // the worker reads "register first" while "then run --scoped" is still
    // fresh. build.md §3c carries the prose half in lockstep.
    ...gateRegistrationChecklistSection(),
    '',
    ...changelogFragmentSection(item),
    ...principlesSection(item),
    '',
    extraSection ?? '',
    '',
    // ## Output shape (temperloop#1080) — the SIZE half of the return contract.
    // The schema below fixes the shape; nothing fixed the length, and measured
    // across 83 real worker verdicts the two prose slots ran 2-4x past what the
    // spec asked for. Stated as an explicit bound here — the one surface the
    // worker actually reads — with the routing rule that makes the bound safe:
    // detail goes to the verification-surface FILE, which reaches the PR body
    // without entering orchestrator context. build.md §3c carries the same
    // contract; the two must stay in lockstep (static guard in test_workflow.sh).
    '## Output shape — your return value is a REPORT, not a transcript',
    'Everything you return is an output token the orchestrator then ingests, so the',
    'verdict stays small on purpose. It is not a place to show your work — you already',
    'have one, and it is free: the verification-surface FILE above never enters the',
    'orchestrator\'s context and is spliced verbatim into the PR body for a human. So:',
    '- **No process narration anywhere in the return value.** What you read, what you',
    '  ruled out, which approach you tried first, how long something took — none of it',
    '  belongs in the JSON. Report the OUTCOME and where it is checkable. If you feel a',
    '  step deserves recording, record it in the verification-surface file.',
    `- **\`summary\`: at most ${WORKER_SUMMARY_MAX_WORDS} words.** What changed and why it satisfies the item.`,
    '  Prose is unavoidable here, so the bound is the shape. Anything longer is detail —',
    '  put it in the verification-surface file, where the reviewer will actually read it.',
    `- **\`acceptance_results[].evidence\`: at most ${WORKER_EVIDENCE_MAX_WORDS} words EACH, and a POINTER, not an argument.**`,
    '  `file:line`, a test name, or a command plus its verdict. The reasoning that makes',
    '  the pointer convincing goes in the verification-surface file. `criterion` is the',
    '  acceptance bullet VERBATIM — quote it, never re-word or summarize it.',
    `- **\`failure_reason\` / \`design_fork\` free-text slots: at most ${WORKER_EVIDENCE_MAX_WORDS} words each**, and`,
    '  `questions[]`: one self-contained question per entry, no preamble and no recap.',
    '- **Never pad a slot to reach its bound.** These are ceilings, not targets — a',
    '  one-line `summary` and a bare `file:line` evidence pointer are ideal returns.',
    '',
    '## Return contract — your FINAL message must be EXACTLY this JSON and nothing after:',
    'Return the smallest object your status requires (status ALWAYS; the rest per status).',
    'status ∈ { done, blocked, design-fork, failed }.',
    '- done: summary, acceptance_results[], commits[], verification_surface_path',
    '- blocked: questions[]',
    '- design-fork: design_fork{decision,options[],recommendation,evidence}',
    '- failed: failure_reason',
  ]
    .filter((l) => l !== null)
    .join('\n');
}

// FOREGROUND_CURE (#1219) — appended to the ONE null-verdict re-spawn so the
// retry prompt DIFFERS from the first attempt (a byte-identical retry re-stalls
// identically). Names the failure explicitly; the workerPrompt foreground block
// above is prevention, this is the backstop cure. build.md §3d must stay in
// lockstep. Kept as its own section so the test can assert its presence.
// Carries the #997 scope half too: the cure must not re-issue the very directive
// (a bare repo-wide gate run) the prevention block just removed.
const FOREGROUND_CURE = [
  '## Re-spawn cure (#1219) — your previous turn returned NO verdict',
  'Your previous attempt ended without a parseable verdict. The usual cause is',
  'backgrounding the quality gate (`run_in_background: true`) or awaiting a Monitor',
  'notification a subagent never receives. Run EVERY command you DO run — the',
  'scoped gate run (`scripts/quality-gates.sh --scoped`) above all — in the FOREGROUND, never `run_in_background` /',
  'Monitor, and END this turn with exactly the fenced verdict JSON and nothing after',
  'it. Do NOT run the bare, repo-wide `scripts/quality-gates.sh` here either (#997) —',
  'acceptance is the orchestrator\'s, parent-side at build.md 3e.5, and THAT is the',
  'acceptance authority; a minutes-long blocking turn is what blows the prompt-cache',
  'TTL. A stall is never cured by running MORE gate.',
].join('\n');

// DIRTY_RESUME_CURE (temperloop#993) — appended ON TOP of FOREGROUND_CURE when
// the recover-probe confirmed the stall shape: zero commits, no PR, but real work
// left on disk. The re-spawn is a FRESH agent (the harness has no resume-this-
// agent seam), so its only inheritance is the worktree — and without being told,
// it re-derives the change from scratch, discarding or duplicating what is
// already there. Naming the state explicitly is what makes the re-spawn a
// continuation rather than a restart. Rendered as a function because the file
// count is run state, not a constant.
function dirtyResumeCure(dirtyFiles) {
  return [
    '## Resume — your previous attempt left UNCOMMITTED work in this worktree (#993)',
    `The worktree already holds ${dirtyFiles} uncommitted path(s) from your previous`,
    'attempt (`git status --porcelain`), and ZERO commits. That is the signature of a',
    'turn that ended while a backgrounded gate was still running. The work is still',
    'there: START by reading `git status` and `git diff` in your worktree, KEEP what',
    'is already correct rather than rebuilding it, then finish, verify in the',
    'FOREGROUND, COMMIT, and return the verdict JSON.',
  ].join('\n');
}

// GATE_SENTINEL_CURE (temperloop#865) — the re-spawn's RECOVERY half, and the
// reason the cure is no longer prose alone. The #865 incident's second worker
// re-stalled after being told, in words, to go read the output file; there was
// no machine-readable file to read. Now there is, at a known path, so the cure
// hands over the path and the three states rather than repeating the
// instruction. If the previous attempt's gate in fact FINISHED, the re-spawn
// reads its verdict off the sentinel instead of paying for the suite twice.
function gateSentinelCure(slug) {
  const sent = workerGateSentinel(slug);
  return [
    '## Your previous gate run may already have a RESULT (temperloop#865)',
    `Before re-running anything, \`cat ${sent}\`.`,
    '- `{"state":"finished","rc":0,…}` — your previous gate PASSED. Do not re-run it;',
    '  report it and quote the sentinel.',
    '- `{"state":"finished","rc":<non-zero>,…}` — it FAILED for real. Read',
    `  \`${workerGateLog(slug)}\` for the output, fix, then re-run the handed command.`,
    '- `{"state":"running",…}` — the previous turn ended while the gate was still going.',
    '  That is the stall. Re-run the handed command in the FOREGROUND and wait for it.',
    '- No such file — it never started. Run the handed command.',
  ].join('\n');
}

// Compose the retry `extraSection` = the original section (if any) + the cure,
// plus the dirty-resume note when the probe saw uncommitted work (#993), plus
// the #865 sentinel-recovery note when a slug is known.
function withCure(section, dirtyFiles, slug) {
  const dirty = Number(dirtyFiles) > 0 ? dirtyResumeCure(Number(dirtyFiles)) : null;
  const sentinel = slug ? gateSentinelCure(slug) : null;
  return [section, FOREGROUND_CURE, sentinel, dirty].filter(Boolean).join('\n\n');
}

// -----------------------------------------------------------------------------
// Lost-return recovery (temperloop#939).
// -----------------------------------------------------------------------------
// The 3c worker can die in TWO different ways that look identical from here:
//   (a) it genuinely failed — nothing was built, and escalating is correct;
//   (b) it did the whole job and only the RETURN CHANNEL failed — the subagent
//       completed without calling StructuredOutput, or blew the StructuredOutput
//       retry cap, so `agent({schema})` THROWS (it does not return null).
// Case (b) is not hypothetical: in the #939 run it hit 2 of 5 workers. One had
// committed, pushed, opened PR #936 and gone green; the other had committed but
// not pushed. Both were reported as `worker-error` — a `ask-now` halt over work
// that had already landed, with a live risk of re-spawning a worker onto a
// worktree that already held the finished commit (a second PR, a stacked commit).
//
// The fix is to STOP GUESSING from the exception and go LOOK: probe the
// observable side-effects (commit / push / PR) before classifying. What we can
// never recover is the worker's own self-verification — so a recovered record is
// honest about that and marks its acceptance results UNVERIFIED rather than
// letting them read as passing.

const RECOVERY_UNVERIFIED =
  'UNVERIFIED — the worker completed without returning a verdict (temperloop#939); ' +
  'this criterion was NOT self-verified and must be re-verified before merge.';

// The recover-probe outcomes that mean "work landed" (anything but RECOVER_NONE).
const RECOVER_STAGES = ['RECOVER_COMMITTED', 'RECOVER_PUSHED', 'RECOVER_PR_OPEN'];

// -----------------------------------------------------------------------------
// Worker cost capture (temperloop#2065, epic #2062's dual-build ledger).
// -----------------------------------------------------------------------------
// The worker `agent()` spawn is the Workflow runtime's own subagent primitive:
// it returns no usage envelope, and the runtime has no timer (`Date.now()`
// throws — see the STEP CEILING block, DESIGN NOTE 1's sibling). Both gaps
// are closed the SAME way every other shell-only fact this file needs is:
// an emitted-shell machinery call (DESIGN NOTE 1's runMachinery bridge).
// workflows/scripts/build/worker-usage.sh is that bridge — the SAME pattern
// review-wait.sh established for giving this runtime a wall-clock tick it
// otherwise has none of (temperloop#2049).
//
//   workerClockNow()  — a bare `date` read, no side effect. Returns epoch
//                       SECONDS (a plain number — safe to subtract, since
//                       only Date.now()/Math.random() throw here, never
//                       arithmetic on a value already in hand) or null on
//                       anything but a clean numeric reading.
//   workerUsageEmit() — the SAME reading PLUS the durable per-seat
//                       attribution write: model-usage-envelope.sh's shared
//                       model_usage_emit_from_envelope, seat "build-worker" —
//                       the SAME helper pipeline-drive.sh's A7/A8 and
//                       pipeline-retro-judge-spawn.sh's A9 already call, so
//                       the build worker joins their attribution stream as a
//                       FOURTH emitting seat (ADR 0026) — the coverage
//                       denominator in report-producers/model-comparison
//                       names it. No `claude -p --output-format json`
//                       envelope exists for a Workflow agent() call, so this
//                       degrades to usage_source:"unavailable" (no tokens) on
//                       every REAL call today — worker-usage.sh's own header
//                       carries that honesty disclosure; the fields still
//                       flow through byte-for-byte the day a real envelope
//                       becomes available, and the offline test harness
//                       exercises exactly that path.
//
// Both are FAIL-OPEN and never escalate: a cost-ledger entry must never be
// the thing that stalls a build. A malformed/absent reading degrades to
// null, never a thrown error or a denial.
function workerUsageBin() {
  return machineryBin(input.repoRoot, 'worker-usage.sh');
}

// numOrNull — coerce to a finite number, or null. Guards the JS `Number(null)
// === 0` / `Number(undefined) === NaN` quirks explicitly rather than relying
// on Number.isFinite() to catch the first one (it would not: 0 IS finite) —
// a machinery field that is genuinely absent (usage_source:"unavailable"'s
// null input_tokens/output_tokens) must degrade to null, never a false zero.
function numOrNull(v) {
  if (v === null || v === undefined) return null;
  // temperloop#2065 review round 1 [LOW]: Number('') === 0 and
  // Number('   ') === 0 are both finite, so an empty/whitespace string would
  // otherwise manufacture a false zero instead of degrading to null — the
  // exact failure mode this function exists to prevent (epoch_s is
  // schema-typed as string|number; a future envelope wiring could emit one).
  if (typeof v === 'string' && v.trim() === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

async function workerClockNow(item, tag, phaseName) {
  const out = await runMachinery(`${workerUsageBin()} clock`, {
    label: `worker-clock:${item.slug}#${tag}`,
    slug: item.slug,
    phase: phaseName ?? 'worker',
  });
  return out && out.outcome === 'WORKER_CLOCK' ? numOrNull(out.epoch_s) : null;
}

// workerOutcomeRef — ADR 0026's outcome-ref vocabulary, "(issue|pr):<ref>".
// The item's own tracking issue is the one stable ref known at worker-spawn
// time (a PR may not exist yet); an issue-less item (boardless work) falls
// back to its slug rather than emitting an empty ref.
function workerOutcomeRef(item) {
  return item.ghIssue ? `issue:${item.ghIssue}` : `issue:${item.slug}`;
}

async function workerUsageEmit(item, tag, seat, phaseName) {
  const model = item.model || 'inherit';
  const repo = input.ownerRepo || '';
  const out = await runMachinery(
    `${workerUsageBin()} emit ${sq(seat)} ${sq(model)} ${sq(workerOutcomeRef(item))} ${sq(repo)}`,
    { label: `worker-usage:${item.slug}#${tag}`, slug: item.slug, phase: phaseName ?? 'worker' },
  );
  const ok = out && out.outcome === 'WORKER_USAGE';
  return {
    epochS: ok ? numOrNull(out.epoch_s) : null,
    tokensIn: ok ? numOrNull(out.input_tokens) : null,
    tokensOut: ok ? numOrNull(out.output_tokens) : null,
  };
}

// USAGE_UNAVAILABLE — the degraded reading every workerUsageEmit() CALL SITE
// falls back to when the call itself throws (see the guards below). Distinct
// from workerUsageEmit()'s own internal "malformed response" null-collapse
// (numOrNull()) — this is the "the machinery invocation never completed at
// all" arm.
const USAGE_UNAVAILABLE = Object.freeze({ epochS: null, tokensIn: null, tokensOut: null });

// temperloop#2065 review round 2 [HIGH]: workerClockNow()/workerUsageEmit()
// both bottom out in runMachinery() -> machineryAgent(), which explicitly
// re-throws (does not degrade) an unresolvable-agentType / StructuredOutput-
// absent / retry-cap-exceeded executor spawn — the exact throw shape
// callWorker()'s own agent({schema}) call is documented as capable of, two
// blocks below. The block comment above these two functions promises they
// are FAIL-OPEN and "never a thrown error" — that promise covers only a
// malformed VALUE in a successful response (numOrNull()'s job); it does not
// cover the underlying machinery spawn itself throwing. These two guards are
// what backs the promise with code: every call site below goes through one
// of these instead of calling workerClockNow()/workerUsageEmit() bare, so a
// cost-ledger bookkeeping failure can never abort the item build it is only
// supposed to be measuring.
async function safeWorkerClockNow(item, tag, phaseName) {
  try {
    return await workerClockNow(item, tag, phaseName);
  } catch {
    return null;
  }
}

async function safeWorkerUsageEmit(item, tag, seat, phaseName) {
  try {
    return await workerUsageEmit(item, tag, seat, phaseName);
  } catch {
    return USAGE_UNAVAILABLE;
  }
}

// elapsedMs — plain integer arithmetic on two already-resolved epoch-SECONDS
// readings (never Date.now() — see above). null when either edge is
// unavailable, so a partial reading never manufactures a false zero.
function elapsedMs(startS, endS) {
  return typeof startS === 'number' && typeof endS === 'number'
    ? Math.max(0, Math.round((endS - startS) * 1000))
    : null;
}

// mergeWorkerCost — accumulate a SECOND callWorker() reading onto the first
// (the temperloop#993/#1219 no-verdict foreground-cure retry re-spawns the
// SAME worker for the SAME item, so its cost is additive, not a replacement).
// A field stays null only when BOTH readings are null — one real reading
// plus one degraded (null) reading reports the real one, never manufacturing
// a false total by treating a missing edge as zero.
function mergeWorkerCost(acc, add) {
  if (!add) return acc;
  const sum = (a, b) => (a == null && b == null ? null : (a ?? 0) + (b ?? 0));
  return {
    wallClockMs: sum(acc.wallClockMs, add.wallClockMs),
    tokensIn: sum(acc.tokensIn, add.tokensIn),
    tokensOut: sum(acc.tokensOut, add.tokensOut),
  };
}

// callWorker — spawn the implementation worker so a lost return channel can
// never escape as a throw. agent({schema}) THROWS on a StructuredOutput-absent
// / retry-cap-exceeded subagent and returns null on a skip / terminal API error;
// both are the same thing to the caller ("no verdict"), and neither is evidence
// about the work. Normalize both into { verdict, error } so driveItem decides
// what they MEAN only after the side-effect probe has run.
// `phaseName` (temperloop#1294) — the STAGE group this worker belongs to,
// passed explicitly (the global phase() cursor races under parallel()).
//
// temperloop#2065 — every call also brackets the worker in the clock/usage
// seam above and returns its reading as { wallClockMs, tokensIn, tokensOut },
// on BOTH the return and the throw arm: a re-spawned worker that itself
// blows its return channel still spent real tokens, and the ledger records
// that spend rather than silently dropping it.
async function callWorker(item, wt, extraSection, label, phaseName) {
  const startS = await safeWorkerClockNow(item, label, phaseName);
  try {
    const v = await agent(workerPrompt(item, wt, extraSection), {
      label,
      phase: phaseName ?? 'worker',
      // temperloop#982: item.model || undefined, NOT bare item.model — an
      // empty-string item.model (e.g. an orchestrator that resolved
      // SWEEP_WORKER_MODEL/FIX_WORKER_MODEL to "" and passed it through
      // unfiltered) must collapse to undefined here, the sentinel the agent()
      // hook reads as "inherit session model" — a bare "" would instead be
      // sent as a literal (invalid) model name. undefined/absent item.model
      // already coerces to undefined via `||`, so this is a strict
      // widening (covers "" too), never a behavior change for the existing
      // undefined case.
      model: item.model || undefined, // "" or undefined → inherit session model
      schema: WORKER_VERDICT_SCHEMA,
    });
    const usage = await safeWorkerUsageEmit(item, label, 'build-worker', phaseName);
    // `nullReturn` (temperloop#1819): true only for the bare-null shape, where
    // NO error text exists — the caller's quota classification then falls back
    // to the agent-liveness canary instead of text matching.
    return {
      verdict: v ?? null,
      error: v == null ? 'agent returned null' : null,
      nullReturn: v == null,
      wallClockMs: elapsedMs(startS, usage.epochS),
      tokensIn: usage.tokensIn,
      tokensOut: usage.tokensOut,
    };
  } catch (err) {
    const usage = await safeWorkerUsageEmit(item, label, 'build-worker', phaseName);
    return {
      verdict: null,
      error: String((err && err.message) || err),
      nullReturn: false,
      wallClockMs: elapsedMs(startS, usage.epochS),
      tokensIn: usage.tokensIn,
      tokensOut: usage.tokensOut,
    };
  }
}

// workerQuotaDeath — the worker-path quota classifier (temperloop#1819): the
// thrown-text shape matches directly; the bare-null shape asks the canary.
async function workerQuotaDeath(w) {
  if (quotaDeath(w.error)) return true;
  return w.nullReturn === true && !(await harnessCanSpawnAgents());
}

// probeSideEffects — run the staged pr.sh recover-probe (its own header owns the
// ladder) and normalize it. Returns { landed, stage, sha, pushed, pr,
// surfacePresent, probeOut }. `landed:false` covers BOTH the genuine-failure
// case (RECOVER_NONE) and an unusable probe (denied / ERROR): either way the
// caller falls through to the unchanged `worker-error` escalation, so a broken
// probe can never manufacture a recovery.
async function probeSideEffects(item, wt) {
  const prBin = machineryBin(input.repoRoot, 'pr.sh');
  const out = await runMachinery(
    `${prBin} recover-probe ${sq(wt)} ${sq(item.branch)}`,
    // STAGE_RECOVER (temperloop#1294): an off-path diagnostic that can fire from
    // any stage, so it gets its own group and never moves the global cursor.
    { label: `recover-probe:${item.slug}`, slug: item.slug, phase: stagePhase(STAGE_RECOVER) },
  );
  if (machineryDenied(out) || !RECOVER_STAGES.includes(out.outcome)) {
    // Not landed — but temperloop#993 splits this bucket. RECOVER_DIRTY means the
    // worker left uncommitted work behind (the backgrounded-gate stall); the
    // caller resumes it on this worktree with the dirty-resume cure instead of
    // treating it like a worker that touched nothing. A denied/ERROR probe
    // reports neither flag and falls through to the unchanged escalation.
    const dirtyFiles = machineryDenied(out) ? 0 : Number(out.dirty_files ?? 0) || 0;
    return {
      landed: false,
      stage: machineryDenied(out) ? null : out.outcome,
      stalled: !machineryDenied(out) && out.outcome === 'RECOVER_DIRTY',
      dirtyFiles,
      probeOut: out,
    };
  }
  return {
    landed: true,
    stage: out.outcome,
    sha: out.sha,
    // A PR implies a push even if ls-remote was somehow unhelpful.
    pushed: out.pushed === true || out.outcome === 'RECOVER_PR_OPEN',
    pr: out.pr_number ?? null,
    surfacePresent: out.verification_surface_present === true,
    probeOut: out,
  };
}

// -----------------------------------------------------------------------------
// Step-liveness disposal (temperloop#1071).
// -----------------------------------------------------------------------------
// timedOutStep — the first STEP_TIMEOUT in a batch's results, or null. A batch
// stops at the timed-out step (both `case` gate forms treat STEP_TIMEOUT as a
// stop), so there is at most one.
function timedOutStep(results) {
  return (results ?? []).find((r) => r && r.outcome === 'STEP_TIMEOUT') ?? null;
}

// disposeStepTimeout — what happens when the ceiling fires.
//
// THE RULE: a bounded-out step is LOST, never FAILED and never RE-ISSUED. The
// ceiling proves the workflow stopped waiting; it proves nothing about what the
// step did or did not do before it was killed — a `push` may have completed on
// the remote, a `pr-open` may have created the PR (the #1071 incident's own
// 9h49m step in fact finished ALL FOUR steps green and opened PR #1070). So the
// disposal is the same side-effect probe the lost-return path already owns:
// `pr.sh recover-probe` (temperloop#939's staged ladder, and the seam
// temperloop#1067 covers for the adjacent lost-return case — deliberately ONE
// disposal path, not a second one invented here).
//
// Two dispositions, no third:
//   • the probe finds an OPEN PR → ADOPT it (`adopt`), exactly as 3f-2 adopts
//     pr.sh's own `EXISTS`. This is the case that must never be re-run: blindly
//     re-issuing the batch would double-push or double-open.
//   • anything else → a legible `machinery-step-timeout` escalation carrying the
//     probe's verdict, for a human/orchestrator to drive. Still no retry.
// `adoptable:false` (the CI-poll path) keeps the probe — its stage is real
// evidence for the payload — while refusing the adopt arm, because "a PR exists"
// is not, and must never become, evidence that CI passed.
async function disposeStepTimeout(item, wt, to, where, { adoptable = true } = {}) {
  log(
    `[${item.slug}] ${where} step '${to.step ?? '?'}' exceeded the ${to.ceilingSecs ?? STEP_CEILING_SECS}s ` +
    `liveness ceiling after ${to.elapsedSecs ?? '?'}s and was killed (temperloop#1071). Treating it as LOST — ` +
    `probing for side effects before disposing; it is NEVER blind-retried.`,
  );
  const payload = { step: to.step ?? null, where, timeoutOut: to, adoptable };
  if (!wt) {
    // No worktree exists yet (a prelude step timed out before/at worktree
    // creation), so there is nothing for recover-probe to read. Say so in the
    // payload rather than running a probe whose answer is structurally 'ERROR'.
    return {
      escalation: escalate(item.slug, 'machinery-step-timeout', {
        ...payload,
        probed: false,
        reason: 'the step outlived the workflow liveness ceiling before a worktree existed — nothing to recover, nothing re-issued',
        remedy: 'inspect the host for a stuck process, then re-drive the item; raise BUILD_MACHINERY_STEP_CEILING_SECS only if the step is legitimately this long',
      }),
    };
  }
  const probe = await probeSideEffects(item, wt);
  const probed = {
    ...payload,
    probed: true,
    probeStage: probe.stage ?? null,
    pushed: probe.pushed === true,
    sha: probe.sha ?? null,
    pr: probe.pr ?? null,
  };
  // `probe.sha` is REQUIRED for the adopt arm, not optional: the CI poll that
  // follows is PINNED to a SHA (#254's false-green guard), so adopting a PR whose
  // head we could not read would poll an unpinned ref. No SHA → escalate instead.
  if (adoptable && probe.stage === 'RECOVER_PR_OPEN' && probe.pr && probe.sha) {
    log(
      `[${item.slug}] recover-probe found PR #${probe.pr} already opened by the timed-out '${to.step ?? '?'}' step — ` +
      `ADOPTING it (no re-push, no re-open) and continuing.`,
    );
    return { adopt: { pr: probe.pr, sha: probe.sha ?? null, probe } };
  }
  return {
    escalation: escalate(item.slug, 'machinery-step-timeout', {
      ...probed,
      reason:
        `the '${to.step ?? '?'}' machinery step outlived the ${to.ceilingSecs ?? STEP_CEILING_SECS}s workflow ` +
        `liveness ceiling and was killed. Its result is UNKNOWN, not failed — recover-probe reports ` +
        `${probe.stage ?? 'no usable answer'}. Nothing was re-issued, so no double-push/double-open is possible.`,
      remedy:
        'read the probe stage above to see what actually landed, then re-drive or finish by hand; ' +
        'raise BUILD_MACHINERY_STEP_CEILING_SECS only if the step is legitimately this long',
    }),
  };
}

// -----------------------------------------------------------------------------
// pr-batch lost-return recovery (temperloop#1067).
// -----------------------------------------------------------------------------
// isLostReturn — true iff a batch step's outcome is the SYNTHESIZED sentinel
// batchStep() (line ~1158) mints for a missing `batch.results[i]` entry, never a
// genuine failure the machinery script itself reported. This is the fidelity
// signal that distinguishes "the step failed" from "the step's return value was
// lost pr-batch return" — a real `pr.sh` failure calls its own `die()` and
// carries a DIFFERENT `error` string, so this check can never mistake a genuine
// non-zero exit for a lost line. That distinction is what keeps the negative
// case (a real failure) escalating immediately, unprobed, exactly as before.
function isLostReturn(stepOut) {
  return Boolean(
    stepOut &&
      stepOut.outcome === 'ERROR' &&
      typeof stepOut.error === 'string' &&
      stepOut.error.includes('produced no result'),
  );
}

// isVerdictUnparseable — the pr-open outcome temperloop#1805 is about: pr.sh's
// own `die` when the verdict file it was handed is not usable JSON. It is
// deliberately NARROW — three literal messages pr.sh emits about the VERDICT
// (`open`'s `jq -e .` guard, and assemble_body's two field checks) — because the
// tolerance path below re-issues the PR-open command, and a blind re-issue of a
// non-idempotent machinery step on any broader class is exactly the double-open
// hazard the rest of this file is built to avoid. Anything else — a `gh` failure,
// a push race, a missing surface file — keeps the unchanged escalation.
const VERDICT_UNPARSEABLE_ERR = /verdict (?:is not valid JSON|JSON missing|JSON has malformed)/i;
function isVerdictUnparseable(stepOut) {
  return Boolean(
    stepOut &&
      stepOut.outcome === 'ERROR' &&
      typeof stepOut.error === 'string' &&
      VERDICT_UNPARSEABLE_ERR.test(stepOut.error),
  );
}

// recoverLostReturn — the 3f push/pr-open twin of disposeStepTimeout's probe,
// for the NON-timeout case: a pr-batch step's own JSON line was dropped (lost
// pr-batch return) with every step before it in the SAME batch already
// confirmed successful (the caller only reaches this after its own
// rebase/scan/push branches above already passed) — temperloop#1067, distinct
// from #1071's liveness-kill. Reuses the EXISTING probeSideEffects/RECOVER_*
// ladder — no second probe, no new machinery. Returns one of:
//   { kind: 'adopted', pr, pushedSha }   — landed; caller skips re-push/re-open
//   { kind: 'escalate', escKind, payload } — a resume attempt itself failed
//   { kind: 'none' }                      — RECOVER_NONE/RECOVER_DIRTY/unusable
//                                            probe; caller does its UNCHANGED
//                                            escalation exactly as before this
//                                            wiring existed.
async function recoverLostReturn(item, wt, openCmd) {
  const probe = await probeSideEffects(item, wt);
  if (probe.landed && probe.stage === 'RECOVER_PR_OPEN' && probe.pr && probe.sha) {
    log(
      `[${item.slug}] lost pr-batch return (temperloop#1067) — recover-probe found PR #${probe.pr} ` +
      'already open; ADOPTING it (no re-push, no re-open).',
    );
    return { kind: 'adopted', pr: probe.pr, pushedSha: probe.sha };
  }
  if (probe.landed && (probe.stage === 'RECOVER_PUSHED' || probe.stage === 'RECOVER_COMMITTED')) {
    const resumeFromPush = probe.stage === 'RECOVER_COMMITTED';
    log(
      `[${item.slug}] lost pr-batch return (temperloop#1067) — recover-probe reports ${probe.stage}; ` +
      `resuming at ${resumeFromPush ? 'push' : 'pr-open'} (no re-run of already-confirmed steps).`,
    );
    const resumeSteps = [];
    if (resumeFromPush) {
      const prBin = machineryBin(input.repoRoot, 'pr.sh');
      // `--allow-rewrite` for the same reason 3f-1 carries it (temperloop#2103):
      // the lost batch already ran 3f-0a's rebase, so this resumed push may be
      // of a rewritten history over a branch an earlier round put on origin.
      // pr.sh downgrades it to a plain push unless the rewrite is genuine, and
      // leases it against a value it read when it is.
      resumeSteps.push({ kind: 'push', cmd: `${prBin} push ${sq(wt)} ${sq(item.branch)} --allow-rewrite`, continueOutcomes: ['PUSHED'] });
    }
    resumeSteps.push({ kind: 'pr-open', cmd: openCmd });
    const resumeAt = {};
    resumeSteps.forEach((s, i) => { resumeAt[s.kind] = i; });
    const rb = await runMachineryBatch(resumeSteps, {
      label: `pr-batch-resume:${item.slug}`,
      slug: item.slug,
      bashTimeoutMs: BATCH_BASH_TIMEOUT_MS,
      phase: stagePhase(STAGE_RECOVER), // off-path recovery — own group, cursor untouched
    });
    if (rb.denied) {
      // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
      const esc = await deniedOrQuota(item.slug, {
        step: batchDeniedStep(rb, 'pr-batch-resume'),
        steps: rb.steps,
        out: rb.out,
      }, wt);
      return { kind: 'escalate', escKind: esc.escalation.kind, payload: esc.escalation.payload };
    }
    const resumeTimeout = timedOutStep(rb.results);
    if (resumeTimeout) {
      const disp = await disposeStepTimeout(item, wt, resumeTimeout, 'pr-batch-resume');
      if (disp.escalation) {
        return { kind: 'escalate', escKind: disp.escalation.escalation.kind, payload: disp.escalation.escalation.payload };
      }
      return { kind: 'adopted', pr: disp.adopt.pr, pushedSha: disp.adopt.sha };
    }
    // `resumedSha` starts at the probe's own reading (correct for the
    // RECOVER_PUSHED case, which resumes at pr-open only — nothing pushes
    // again) and is overwritten by the RESUMED push's own sha when
    // RECOVER_COMMITTED actually re-runs push — the freshest ground truth, not
    // the pre-resume probe reading.
    let resumedSha = probe.sha ?? null;
    if (resumeAt.push !== undefined) {
      const pushOut = batchStep(rb, resumeAt.push);
      if (pushOut.outcome === 'PUSH_REJECTED') {
        return { kind: 'escalate', escKind: 'push-rejected', payload: { pushOut } };
      }
      if (pushOut.outcome === 'PUSHED_UNWATCHED') {
        // temperloop#1688 — the push landed on a ref no open PR watches. Its own
        // escalation kind, never 'push-error': the push did not fail, and the
        // disposition (re-push onto the PR's head ref, named in the payload) is
        // specific to this state.
        return { kind: 'escalate', escKind: 'push-unwatched-branch', payload: { pushOut } };
      }
      if (pushOut.outcome !== 'PUSHED') {
        return { kind: 'escalate', escKind: 'push-error', payload: { pushOut } };
      }
      resumedSha = pushOut.sha ?? resumedSha;
    }
    const openOut = batchStep(rb, resumeAt['pr-open']);
    if (openOut.outcome !== 'PR_OPENED' && openOut.outcome !== 'EXISTS') {
      return { kind: 'escalate', escKind: 'pr-open-failed', payload: { openOut } };
    }
    return { kind: 'adopted', pr: openOut.pr_number, pushedSha: resumedSha };
  }
  // RECOVER_NONE / RECOVER_DIRTY / denied / unusable probe — genuinely nothing
  // landed (or the probe itself gave no usable answer); the caller falls
  // through to its own UNCHANGED escalation, exactly as before this wiring.
  return { kind: 'none' };
}

// recoveredVerdict — reconstruct the verdict object the worker never returned,
// from ground truth plus an explicit UNVERIFIED marker on every acceptance
// criterion. Deliberately carries NO `passed` key: pr.sh renders each result as
// `- [ ]` (unchecked) and driveItem's `passed === false` check does not trip, so
// the item flows on WITHOUT ever being reported as passing. The synthesized
// `verification_surface` is the fallback for a worker that died before writing
// `.build-verification.md` (pr.sh's `open` prefers the real file when one exists).
function recoveredVerdict(item, probe, reason) {
  const criteria = acceptanceList(item);
  const results = (criteria.length ? criteria : ['(no acceptance criteria carried on this plan item)']).map(
    (c) => ({
      criterion: typeof c === 'string' ? c : JSON.stringify(c),
      evidence: RECOVERY_UNVERIFIED,
    }),
  );
  const summary =
    `**Recovered record (temperloop#939) — acceptance NOT self-verified.** The worker for ` +
    `\`${item.slug}\` completed without returning a verdict (${reason ?? 'no verdict'}), so this ` +
    `PR was reconstructed from observable side-effects (probe stage: ${probe.stage}, ` +
    `HEAD ${probe.sha ?? 'unknown'}). The work itself is real and present on this branch; what was ` +
    `lost is the worker's own acceptance self-check. Re-verify every criterion below before merging.`;
  return {
    status: 'done',
    recovered: true,
    summary,
    acceptance_results: results,
    verification_surface: [
      '### Recovered — verification NOT performed by the worker',
      '',
      `The implementation worker for \`${item.slug}\` finished its run but never returned a`,
      'verdict (temperloop#939 — the StructuredOutput return channel failed). The branch content',
      'below is ground truth read back from the worktree and the remote; the acceptance results',
      'are **unknown**, not passing.',
      '',
      `- probe stage: \`${probe.stage}\``,
      `- worktree HEAD: \`${probe.sha ?? 'unknown'}\``,
      `- branch on origin: ${probe.pushed ? 'yes' : 'no (pushed by the recovery path)'}`,
      `- open PR at probe time: ${probe.pr ? `#${probe.pr}` : 'none (opened by the recovery path)'}`,
      `- worker verification surface written: ${probe.surfacePresent ? 'yes' : 'no'}`,
      '',
      '**Reviewer action required:** verify each acceptance criterion above directly — do not',
      'read the unchecked boxes as failures, and do not read this PR as self-verified.',
    ].join('\n'),
  };
}

// -----------------------------------------------------------------------------
// Per-item driver (3a–3h for ONE item). Returns either a `parked` record or an
// `escalation` record — NEVER both. The pipeline collects these.
// -----------------------------------------------------------------------------

// A small helper to build an escalation result (worktree stays intact).
function escalate(slug, kind, payload) {
  return { _kind: 'escalation', slug, escalation: { slug, kind, payload } };
}

// -----------------------------------------------------------------------------
// The SIDELINE notice — the consumer half of worktree.sh's CREATED verdict
// (temperloop#2006).
// -----------------------------------------------------------------------------
// `worktree.sh create` must NEVER refuse (its own contract at worktree.sh:783-787
// — a refusing create turns /build's prelude batch from CREATED into escalated),
// so when the deterministic path is already occupied by committed work that
// preservation could not capture, it SIDELINES: the occupant is MOVED — never
// copied, never removed — to `<path>.unpreserved-<sha8>` on branch
// `<branch>.unpreserved-<sha8>`, which frees the path so create still CREATES.
// It already REPORTS that, as fields on the CREATED line it was always going to
// print: `sidelined` / `sidelined_path` / `sidelined_branch`.
//
// This driver used to DROP all three. That is the whole of the defect #2006
// names: an intact, committed, reviewed build gets shelved while a fresh worker
// rebuilds the same item from scratch, and nothing reports it — not because the
// information is missing, but because nobody read it. The cost is a wasted
// re-drive plus an orphaned worktree nobody knows to reclaim, and it silently
// defeats the point of temperloop#1988's preserve-the-build fix.
//
// WHY THE CONSUMER LIVES HERE, below the drivers. The "is there a commit ahead
// of base at the deterministic path?" reading is the same fact /fix's Step 4a
// worktree state table reasons about in prose. /build and /sweep have no such
// table: they invoke this file on its normal `fresh` route (no onlySlugs, no
// verdicts) and reach `worktree.sh create` through the prelude batch below. A
// guard that lives in one driver's prose holds only for that driver — the
// per-instance-fix smell the kernel names ("hoist the mechanism rather than
// patch the instance, or you re-patch every sibling in turn"). Putting the
// consumer in the ONE file all three drivers route through is what lets /build
// and /sweep inherit what /fix has without any of them restating the rule.
//
// NOTHING here touches worktree.sh. `create` still never refuses, still
// sidelines rather than destroys, and still emits the identical CREATED line;
// this is purely the reading half that was missing.
//
// Keyed by slug rather than threaded through driveItem's ~30 return points:
// the notice is discovered at 3b and must ride whichever record the item
// eventually produces (parked OR escalation), which is exactly the shape
// preserveOnEscalation already solved with one choke point at the fan-out.
const SIDELINE_NOTICES = new Map(); // slug → { path, branch, recovery }

// sidelineRecoveryCmd — NAME THE RECOVERY, not merely the event. A sidelined
// worktree is still a REGISTERED git worktree holding real commits (worktree.sh
// moves it with `git worktree move`, falling back to `mv` + `worktree repair`),
// so the concrete reclaim is: read what is in it, then get its branch somewhere
// durable before `worktree.sh prune`'s two-gate disposal owner ever reaches it.
// A sideline that could not carry the branch across reports an empty
// `sidelined_branch`; say so rather than emitting a command with an empty ref.
function sidelineRecoveryCmd(path, branch) {
  const at = path || '(path not reported)';
  const inspect = `git -C ${sq(at)} log --oneline --stat origin/HEAD..HEAD`;
  return branch
    ? `${inspect}   # then keep it: git -C ${sq(at)} push -u origin ${sq(branch)}`
    : `${inspect}   # no branch survived the sideline — those commits are reachable only from this worktree's HEAD`;
}

// noteSideline — read the CREATED outcome's sideline verdict, and when it fired
// emit the NAMED notice and record it for the choke-point stamp below. A clean
// create over an empty path reports `sidelined: false` (or omits the field on an
// older worktree.sh), and this is a total no-op on that arm.
function noteSideline(slug, wtOut) {
  if (!wtOut || wtOut.sidelined !== true) return;
  const path = wtOut.sidelined_path ? String(wtOut.sidelined_path) : '';
  const branch = wtOut.sidelined_branch ? String(wtOut.sidelined_branch) : '';
  const recovery = sidelineRecoveryCmd(path, branch);
  SIDELINE_NOTICES.set(slug, { path, branch, recovery });
  log(
    `[${slug}] SIDELINED BUILD — worktree.sh create found committed work it could not preserve at the ` +
      `deterministic path and MOVED it aside instead of destroying it (temperloop#1730). ` +
      `The shelved build is at ${path || '(path not reported)'}` +
      (branch ? ` on branch ${branch}` : ' with no surviving branch') +
      `. This run is REBUILDING the item from scratch; the shelved build is not lost, and ` +
      `worktree.sh prune leaves it standing while its issue is open. Reclaim it with: ${recovery}`,
  );
}

// stampSideline — the ONE choke point where the notice is attached to whatever
// record this item produced, parked or escalation, so it survives the return to
// the orchestrator and reaches the merge gate rather than living only in a
// transient log line. Same placement (and same rationale) as
// preserveOnEscalation: one seam beats N call sites.
function stampSideline(item, r) {
  const notice = SIDELINE_NOTICES.get(item.slug);
  if (!notice || !r) return r;
  if (r._kind === 'parked' && r.parked) {
    r.parked.sidelined = notice;
  } else if (r._kind === 'escalation' && r.escalation) {
    r.escalation.payload = { ...(r.escalation.payload ?? {}), sidelined: notice };
  }
  return r;
}

// -----------------------------------------------------------------------------
// preserveCommittedWorkCmd / preserveOnEscalation — temperloop#2020.
// -----------------------------------------------------------------------------
// THE DATA-LOSS SEAM. An escalation leaves the worktree intact, and every
// downstream spec says so — but "intact" is a promise about a LOCAL directory
// and a LOCAL `build/<slug>` branch, and the specs that dispose an escalated
// item are AI-executed prose. On Towheads/foundation (kernel v0.39.0, run
// wf_967c2878-0a7 driving foundation#1869) a §3e `review-diff-error` fired
// with the worker's work committed but un-pushed and un-PR'd; /fix's 4a
// escalation-park path then ran `worktree.sh remove`, taking the directory and
// the only branch pointing at those commits with it. 515 verified lines were
// hand-rescued from the parent session's transcript. fix.md's prose guard for
// exactly this hazard (its `FX.8 class:escalated-work-destruction` cite, and a
// worktree state table that permits removal on one row only) was already in
// place and did not hold — which is the whole argument for fixing it HERE:
// kernel principle 5, counter a known AI failure mode STRUCTURALLY rather than
// with more prose the next agent may also misread.
//
// So: before an escalation LEAVES this driver, any commit the worker made that
// is not yet on origin is PUSHED. After that, every destructive disposition a
// caller can take — `worktree.sh remove`, its `git branch -D`, a force-clearing
// `worktree.sh create` on a later run — destroys only a local copy of work that
// already exists on the remote. This protects callers whose escalation paths
// this file cannot see, which a fix in any one caller's prose cannot.
//
// Fail-soft in every direction, and deliberately so — this runs on a path that
// is ALREADY failing, and must never convert an escalation into a worse one:
// no worktree, no commits, a rejected push, a denied executor, a thrown
// machinery call — each returns the original escalation unchanged, annotated
// with what happened. The annotation is the point on the failing arm:
// WORK_PRESERVE_FAILED tells the operator disposing this escalation that the
// worktree IS the only copy.
//
// NOT a substitute for 3f: this pushes the BRANCH only — no PR, no CI, no
// rebase, no closing-keyword scan. A pushed branch with no PR merges into
// nothing; it is a durable copy, not a landing.
//
// `branch` is the PLAN's `item.branch` (`<type>/<slug>`), NOT the worktree's
// throwaway local `build/<slug>` HEAD (worktree.sh's own header). It has to be:
// 3f pushes via `pr.sh push <wt> <item.branch>`, which sends
// `$sha:refs/heads/$branch` — so preserving `HEAD` under its LOCAL name would
// mint a SECOND remote ref (`build/<slug>`) on every post-3f escalation
// (ci-failed, gate-fail, review-blocking), one that no PR watches and that
// neither `delete_branch_on_merge` nor prune-merged-branches.sh can ever
// reclaim. That is precisely the two-ref split pr.sh's PUSHED_UNWATCHED logic
// (temperloop#1688) exists to make visible. Pushing the ref 3f already owns
// makes the idempotency claim below TRUE of what the code does, and leaves the
// rescue copy on a ref a human already has a handle for.
function preserveCommittedWorkCmd(wt, branch) {
  return [
    // No worktree (an escalation from before 3b, e.g. claim-conflict) — there
    // is nothing to preserve and that is a normal, expected arm.
    `if [ ! -d ${sq(wt)} ]; then printf '{"outcome":"WORK_PRESERVE_SKIP","detail":"no worktree"}\\n'; exit 0; fi`,
    `cd ${sq(wt)} || { printf '{"outcome":"WORK_PRESERVE_SKIP","detail":"worktree unreadable"}\\n'; exit 0; }`,
    // Same default_branch() fallback chain reviewDiffCmd uses, for the same
    // reason: this must not depend on pr.sh having run first.
    `default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"`,
    `if [ -z "$default" ]; then`,
    `  for b in main master; do`,
    `    if git show-ref --verify --quiet "refs/remotes/origin/$b"; then default="$b"; break; fi`,
    `  done`,
    `fi`,
    // NO `|| default=main` guess. worktree.sh's own default_branch() (its
    // "The repo's default branch" helper) `return 1`s rather than inventing a
    // base, and this path must do the same, because the guess does not fail
    // LOUDLY here — it fails into a rev-list that errors, `ahead` that reads 0
    // and a WORK_PRESERVE_SKIP "no unlanded commits". Verified against a
    // throwaway fixture (bare origin defaulting to `trunk`, origin/HEAD
    // deleted, one real unpushed commit): the old chain emitted
    // `{"outcome":"WORK_PRESERVE_SKIP","commits_ahead":0}` over real work. And
    // because preserveOnEscalation logs its "the worktree may be the ONLY
    // copy" warning on every outcome EXCEPT the skip, that false negative
    // silenced the one warning this whole seam exists to raise.
    //
    // So: `base_resolved` splits "genuinely zero commits ahead" from "could
    // not compute". Only the FIRST may skip. The second PUSHES ANYWAY —
    // pushing is the fail-safe direction on a preservation path: the cost of a
    // needless push is one ref on the branch 3f already owns, while the cost
    // of a needless skip is the destroyed-work incident this file documents.
    // `ahead` is normalized before it is ever read as a number, so nothing
    // non-numeric can reach the unquoted `"commits_ahead":%s` position and
    // make the line unparseable (the pr.sh `case` idiom, e.g. its cmd_push
    // ahead-count normalization).
    `base_resolved=false`,
    `ahead=0`,
    `if [ -n "$default" ] && count="$(git rev-list --count "origin/$default..HEAD" 2>/dev/null)"; then`,
    `  case "$count" in ''|*[!0-9]*) : ;; *) base_resolved=true; ahead="$count" ;; esac`,
    `fi`,
    `branch=${sq(branch)}`,
    // `$branch` goes into the hand-built JSON below through a bare printf
    // `%s`, deliberately NOT through the `jq -R -s -c .` idiom reviewDiffCmd
    // uses for tsv_lines/files. The reason it is safe here: this is the PLAN's
    // `branch:` field, which plan-schema pins to `<type>/<slug>` with type in
    // a closed set {feat,fix,chore,refactor,docs,test} and slug kebab-case
    // ([a-z0-9-]+), validated at Step 1 — so it carries neither a double quote
    // nor a backslash. Note what is NOT an argument: `git check-ref-format`
    // bans a backslash in a ref name but ACCEPTS a double quote
    // (`git check-ref-format 'refs/heads/build/a"b'` exits 0), and a double
    // quote alone terminates a JSON string. The ref grammar is therefore not a
    // JSON-safety guarantee; the plan schema is. Adding jq would also put a new
    // binary dependency on the one path whose entire job is to work when things
    // are already failing — the opposite of fail-soft.
    // Nothing committed beyond a RESOLVED base — 3f never ran and never needed
    // to. Pushing here would mint an empty remote branch for no benefit.
    `if [ "$base_resolved" = true ] && [ "$ahead" = 0 ]; then`,
    `  printf '{"outcome":"WORK_PRESERVE_SKIP","branch":"%s","base_resolved":true,"commits_ahead":0,"detail":"no unlanded commits"}\\n' "$branch"`,
    `  exit 0`,
    `fi`,
    // The count rides along only when it is real; on the unresolved arm the
    // detail says so instead, so `commits_ahead` is never a fabricated figure
    // and never a non-number in a JSON number position.
    `if [ "$base_resolved" = true ]; then`,
    `  extra=",\\"commits_ahead\\":$ahead"`,
    `else`,
    `  extra=",\\"detail\\":\\"base unresolved — pushed unconditionally\\""`,
    `fi`,
    // temperloop#2103 — THE REBASED-BRANCH-ALREADY-ON-ORIGIN ARM.
    //
    // The plain push below is right on the ordinary path and CANNOT work on the
    // one that produced this issue three times in a single session: a
    // continuation round whose branch an EARLIER round already pushed, which
    // 3f-0a then rebased onto a newer origin/<default>. The rewritten history
    // does not contain the remote tip, so a plain push is a non-fast-forward by
    // construction — not a transient — and the seam whose entire job is to make
    // the work durable reported WORK_PRESERVE_FAILED over four commits that
    // existed nowhere else.
    //
    // Three properties the arm below holds to, in this order:
    //
    //   1. READ THE REMOTE VALUE FIRST. Nothing here ever issues a bare
    //      `--force`. The retry is `--force-with-lease=refs/heads/$branch:$sha`
    //      against the value `git ls-remote` just returned, so a concurrent
    //      writer that moved the ref in between gets a REJECTION, not a silent
    //      overwrite. An unreadable remote means no force at all.
    //   2. ONLY OVER WORK THE LOCAL HISTORY SUPERSEDES. This path runs
    //      unattended on an already-failing item and nobody ASKED it to rewrite
    //      anything (unlike 3f, which force-requests the rebase it just
    //      performed). So the force is gated on the operator's own manual
    //      recovery criterion from the issue — "after confirming the local
    //      history superseded the remote tip": every commit reachable from the
    //      remote tip but not from HEAD must have a patch-equivalent in HEAD
    //      (`rev-list --cherry-pick --right-only`, `git cherry`'s own test).
    //      Zero such commits ⇒ the remote holds a stale pre-rebase copy of
    //      exactly this work ⇒ overwriting it destroys nothing. Otherwise the
    //      remote carries commits this worktree does not, and the arm REFUSES
    //      and says so — a loud WORK_PRESERVE_FAILED naming the remote sha is
    //      recoverable; destroying someone else's commits is not.
    //   3. `preserved` IS READ BACK FROM ORIGIN, NEVER INFERRED FROM AN EXIT
    //      CODE. The third occurrence recorded the exact reason: a push from
    //      the same run HAD landed a pre-rebase state on origin while the field
    //      read false, so "the branch exists on origin" overstated and
    //      `preserved:false` understated. The final `ls-remote` below decides
    //      the outcome by comparing the remote value to this worktree's HEAD,
    //      and BOTH shas ride the record, so neither signal has to be trusted
    //      alone.
    //
    // Idempotent, and TRULY so: this pushes the same `refs/heads/$branch` 3f
    // pushes, so when 3f already pushed this sha git reports "Everything
    // up-to-date" and exits 0 — a post-3f escalation (a CI failure, say) costs
    // one no-op push and reports WORK_PRESERVED truthfully, minting no second
    // ref. No `-u`: this is a one-shot rescue push and has no business writing
    // branch.<name>.remote/.merge into the worktree's config.
    //
    // Still no jq (the fail-soft argument above): every value interpolated into
    // the JSON below is either the plan's validated `branch:`, a literal, or a
    // 40-hex sha normalized through the `case` guard before it is read.
    `head_sha="$(git rev-parse HEAD 2>/dev/null || true)"`,
    `case "$head_sha" in *[!0-9a-f]*) head_sha="" ;; esac`,
    `remote_sha="$(git ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')"`,
    `case "$remote_sha" in ''|*[!0-9a-f]*) remote_sha="" ;; esac`,
    `pushed=false`,
    `forced=false`,
    `refused=false`,
    `probe_failed=false`,
    `if git push origin "HEAD:refs/heads/$branch" >/dev/null 2>&1; then`,
    `  pushed=true`,
    `elif [ -n "$remote_sha" ] && [ -n "$head_sha" ] && [ "$remote_sha" != "$head_sha" ]; then`,
    // Bring the remote tip's objects local so the supersede test can run at
    // all; a fetch failure leaves `unique` unset and the arm refuses.
    //
    // `--no-merges` is a DELIBERATE, acknowledged narrowing, not an oversight:
    // an ordinary merge commit's underlying unique commits are still counted
    // (so a normal merge is not a blind spot), but an "evil merge" — one whose
    // own conflict-resolution edits exist nowhere else — carries content this
    // count cannot see. Accepted because a `/build` worker branch does not
    // normally carry merge commits at all, and because dropping the flag would
    // count every merge's whole second parent as remote-only work and refuse
    // essentially every rescue. The narrowing is bounded by property 1: the
    // push is still leased, so it can only ever land on the exact sha read here.
    //
    // THREE outcomes, not two (temperloop#2103 review round 1). A refusal on an
    // UNANSWERABLE probe is right, but it must not be reported as a refusal on
    // an ESTABLISHED conflict: `stale_remote_not_superseded` is what the log
    // turns into the flat assertion "origin carries commits this worktree does
    // NOT", and a human disposes the escalation against that sentence. When the
    // fetch simply failed (the network dropped between the `ls-remote` above
    // and this fetch), that sentence is unproven. So `unique` empty ⇒
    // `supersede_probe_failed`, `unique > 0` ⇒ `stale_remote_not_superseded`.
    // Both refuse identically — only the claim made about why differs.
    `  unique=""`,
    `  if git fetch --quiet origin "refs/heads/$branch" >/dev/null 2>&1; then`,
    `    unique="$(git rev-list --count --cherry-pick --right-only --no-merges "HEAD...$remote_sha" 2>/dev/null || true)"`,
    `  fi`,
    `  case "$unique" in ''|*[!0-9]*) unique="" ;; esac`,
    `  if [ "$unique" = 0 ]; then`,
    `    if git push --force-with-lease="refs/heads/$branch:$remote_sha" origin "HEAD:refs/heads/$branch" >/dev/null 2>&1; then`,
    `      pushed=true; forced=true`,
    `    fi`,
    `  elif [ -n "$unique" ]; then`,
    `    refused=true`,
    `  else`,
    `    probe_failed=true`,
    `  fi`,
    `fi`,
    // The outcome is the REMOTE's answer, not the push's. Re-read the ref: the
    // work is preserved iff origin now carries this worktree's exact HEAD.
    `final_sha="$(git ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')"`,
    `case "$final_sha" in ''|*[!0-9a-f]*) final_sha="" ;; esac`,
    `if [ -n "$head_sha" ] && [ "$final_sha" = "$head_sha" ]; then outcome=WORK_PRESERVED; else outcome=WORK_PRESERVE_FAILED; fi`,
    // `if` rather than `[ … ] && …`: a trailing AND-list that evaluates false
    // is the whole command's status, which `set -e` (wherever this text is
    // sourced) would take as a failure of the preservation step itself.
    `facts=""`,
    `if [ -n "$head_sha" ]; then facts="$facts,\\"head_sha\\":\\"$head_sha\\""; fi`,
    `if [ -n "$final_sha" ]; then facts="$facts,\\"remote_sha\\":\\"$final_sha\\""; fi`,
    `if [ "$forced" = true ]; then facts="$facts,\\"forced_with_lease\\":true,\\"rewrote_remote\\":\\"$remote_sha\\""; fi`,
    `if [ "$refused" = true ]; then facts="$facts,\\"stale_remote_not_superseded\\":true"; fi`,
    `if [ "$probe_failed" = true ]; then facts="$facts,\\"supersede_probe_failed\\":true"; fi`,
    `printf '{"outcome":"%s","branch":"%s","base_resolved":%s,"pushed":%s%s%s}\\n' "$outcome" "$branch" "$base_resolved" "$pushed" "$extra" "$facts"`,
  ].join('\n');
}

// preserveOnEscalation(item, result) — the ONE choke point. Applied at the
// `parallel()` call site over driveItem's settled result, so it covers EVERY
// escalation kind this driver can return, including ones added later: there is
// no per-call-site list to keep in sync, which is exactly the maintenance
// failure a 30-site sprinkle would re-introduce. A `parked` result passes
// through untouched (3f already pushed it and opened its PR).
async function preserveOnEscalation(item, result) {
  if (!result || result._kind !== 'escalation') return result;
  const wt = `${input.repoRoot}.wt/${item.slug}`;
  // The plan's branch — the ref 3f pushes — not the worktree's local
  // `build/<slug>` HEAD; see preserveCommittedWorkCmd's header for why. The
  // fallback is the worktree's own name only for a malformed item that somehow
  // reached here without the schema-required `branch:`.
  const preserveBranch = item?.branch || `build/${item.slug}`;
  let out;
  try {
    out = await runMachinery(preserveCommittedWorkCmd(wt, preserveBranch), {
      label: `preserve-push:${item.slug}`,
      slug: item.slug,
    });
  } catch (err) {
    out = { outcome: 'ERROR', error: String((err && err.message) || err) };
  }
  const outcome = String(out?.outcome ?? 'ERROR');
  // `committed_work` is a FACT the escalation carries, never a verdict: it
  // says what is (or is not) on origin, so the human or agent disposing this
  // escalation decides about removal against evidence instead of an assumption
  // that "the worktree stays intact" means the work is safe.
  //
  // temperloop#2103 — `head_sha`/`remote_sha` ride the record because NEITHER
  // `preserved` nor "the branch exists on origin" is sufficient alone: the live
  // third occurrence had a stale pre-rebase sha sitting on the remote while the
  // flag read false, so one signal overstated and the other understated. With
  // both shas present a caller can settle it by comparison instead of guessing.
  const record = {
    outcome,
    branch: out?.branch ?? preserveBranch,
    preserved: outcome === 'WORK_PRESERVED',
    ...(out?.commits_ahead === undefined ? {} : { commits_ahead: out.commits_ahead }),
    ...(out?.head_sha ? { head_sha: out.head_sha } : {}),
    ...(out?.remote_sha ? { remote_sha: out.remote_sha } : {}),
    ...(out?.forced_with_lease ? { forced_with_lease: true, rewrote_remote: out.rewrote_remote } : {}),
    ...(out?.stale_remote_not_superseded ? { stale_remote_not_superseded: true } : {}),
    ...(out?.supersede_probe_failed ? { supersede_probe_failed: true } : {}),
    ...(out?.detail ? { detail: out.detail } : {}),
  };
  if (outcome === 'WORK_PRESERVED') {
    log(
      `[${item.slug}] escalating — pushed ${record.branch} to origin first (temperloop#2020): ` +
        `committed work is durable regardless of what disposes this escalation` +
        (record.forced_with_lease
          ? ` — the branch was already on origin at ${String(record.rewrote_remote).slice(0, 8)} ` +
            `(a pre-rebase copy of this same work), so the push was a LEASED force over it (temperloop#2103)`
          : ''),
    );
  } else if (outcome !== 'WORK_PRESERVE_SKIP') {
    log(
      `[${item.slug}] escalating — could NOT preserve committed work (${outcome}): ` +
        `the worktree may be the ONLY copy — do not remove it` +
        (record.stale_remote_not_superseded
          ? ` — origin's ${record.branch} is at ${String(record.remote_sha).slice(0, 8)} and carries commits this ` +
            `worktree does NOT, so the rescue push was REFUSED rather than overwrite them. Reconcile by hand ` +
            `(merge or confirm supersession), then: git push --force-with-lease=refs/heads/${record.branch}:${record.remote_sha} origin HEAD:refs/heads/${record.branch}`
          : '') +
        // NOT the sentence above. The refusal was the same, the reason is not:
        // nothing was established about the remote, so claiming it "carries
        // commits this worktree does NOT" would be a fabricated fact — and it
        // is the sentence a human disposes the escalation against.
        (record.supersede_probe_failed
          ? ` — origin's ${record.branch} is at ${String(record.remote_sha).slice(0, 8)}, which differs from this ` +
            `worktree's HEAD, but whether this worktree's history supersedes it could NOT be established (the ` +
            `check could not reach origin). The rescue push was REFUSED on that uncertainty — no conflict is ` +
            `claimed here. Re-run the check by hand first (git fetch origin ${record.branch}), and only then ` +
            `decide whether to merge or to force over it`
          : ''),
    );
  }
  result.escalation.payload = { ...(result.escalation.payload ?? {}), committed_work: record };
  return result;
}

// --- 3e.5 gate verdict reconciliation (temperloop#1587) ----------------------
// The defect this pair of helpers closes: the slice loop maintained TWO
// independent failure counters — an accumulated `gateFailed` and the terminal
// slice's own `gateOut.failed` — and shipped BOTH in one escalation payload
// (`{gateOut:{outcome:'GATE_PASS',failed:0,…}, failedGates:1}`). A consumer
// that trusted either field acted on a fiction: the kind said the gate failed,
// the embedded object said it passed. Two counters that CAN disagree is the
// defect, not merely the run on which they did — so there is now exactly ONE
// record of failure (the per-slice ledger the loop appends to) and every
// figure reported anywhere — `failedGates`, the verdict, the escalation kind,
// the reason prose — is DERIVED from it by gateVerdict() below. No second
// counter is maintained, and the raw terminal `gateOut` (whose `failed` was
// the contradicting field) is no longer embedded in the payload: its content
// survives as the ledger's last entry, which cannot disagree with the sum of
// the ledger it is part of.

// gateSliceFailed(out) — the failure count ONE slice actually ESTABLISHED.
// This is the only place a slice's failure count is read, so the ledger's
// entries are normalized on the way in rather than clamped at each reader:
//   GATE_SLICE — the count the suite's own `QUALITY_GATES_FAILED=` trailer
//                reported for that slice (exit 75 always prints it).
//   GATE_FAIL  — a RED suite by construction, so the floor is 1: an unparseable
//                or stale trailer must never produce a "failed, 0 failures"
//                ledger entry (the mirror image of #1587's contradiction).
//   everything else (GATE_PASS / GATE_ABSENT / GATE_TIMEOUT) — 0. A pass is
//                zero by construction; a TIMEOUT establishes NOTHING (the slice
//                was killed before it could report), and unknown-ness is carried
//                by the verdict, never smuggled into a count.
function gateSliceFailed(out) {
  if (!out) return 0;
  if (out.outcome === 'GATE_FAIL') return Math.max(1, Number(out.failed) || 0);
  if (out.outcome === 'GATE_SLICE') return Math.max(0, Number(out.failed) || 0);
  return 0;
}

// gateSliceResumeAt(out) — the 0-based gate index ONE slice said the suite
// still has to reach, or undefined when it reported none (temperloop#2094).
//
// Read off the outcome REGARDLESS of its kind, deliberately. `suiteFinished`
// is a claim about whether every gate ran, and the only evidence anyone has
// for that is the suite's own `QUALITY_GATES_RESUME_AT=` trailer; deriving it
// from the terminal outcome's NAME instead is what let a run that stopped at
// gate 152 of 200 ship `suiteFinished: true`. A resume point is that claim's
// direct counter-evidence whether the slice carrying it was classified
// GATE_SLICE or (as in the #2094 incident) something else.
//
// `0` is not a resume point: the trailer is only ever printed with gates
// REMAINING, so a 0 here is an unparsed/absent field, not "resume at gate 0".
function gateSliceResumeAt(out) {
  if (!out) return undefined;
  const n = Number(out.resumeAt);
  return Number.isFinite(n) && n > 0 ? n : undefined;
}

// gateVerdict(terminalOutcome, ledger) — the ONE reconciliation point between
// the slice loop's terminal outcome and its failure ledger. Every arm's kind,
// counts and reason are computed HERE, from one input, so no arm can ship a
// payload that contradicts its own verdict.
//
// `verdict` is the single field a consumer may trust:
//   RED     — at least one gate FAILED. The branch is known-broken.
//   UNKNOWN — nothing failed and the suite never finished (Bash-tool timeout or
//             slice-cap exhaustion). It says NOTHING about the tree — the whole
//             point of temperloop#1021, preserved exactly: this and only this
//             verdict escalates `acceptance-gate-timeout`.
//   GREEN   — the suite finished and every gate that ran passed.
//
// Precedence: an OBSERVED failure dominates an UNFINISHED remainder. A run that
// failed in slice 1 and then timed out in slice 3 is RED — the failures are
// real evidence, the missing verdict for the un-run gates cannot un-fail them —
// and the reason says both halves. This is the same precedence the pre-#1587
// code already applied to a GATE_PASS terminal after a failing slice, now
// applied to the TIMEOUT arm too, so "timeout" never launders a known failure
// into an unknown. A timeout with NO observed failure is untouched.
function gateVerdict(terminalOutcome, ledger) {
  const failedGates = ledger.reduce((n, s) => n + (Number(s.failed) || 0), 0);
  const failedInSlices = ledger.filter((s) => (Number(s.failed) || 0) > 0).map((s) => s.slice);
  // A resume point in the LAST ledger entry is direct evidence that gates
  // remained when the run stopped, and it OVERRIDES the terminal outcome's own
  // name (temperloop#2094). The incident: the final slice came back with an
  // unexpected exit code and was classified GATE_FAIL, whose name put it in
  // the `finished` set below — so an escalation for a run that stopped at gate
  // 152 of 200 reported `suiteFinished: true`, and the next reader had no way
  // to tell a whole-suite verdict from a 76%-of-the-way-through one. The
  // trailer is the only first-hand evidence about coverage that exists; a
  // classification derived downstream of it can never outrank it.
  const lastSliceResumeAt = ledger.length > 0
    ? gateSliceResumeAt(ledger[ledger.length - 1])
    : undefined;
  const finished = lastSliceResumeAt === undefined
    && (terminalOutcome === 'GATE_PASS'
      || terminalOutcome === 'GATE_FAIL'
      || terminalOutcome === 'GATE_ABSENT');
  let unfinished;
  if (terminalOutcome === 'GATE_TIMEOUT') {
    unfinished = `the quality-gates slice was killed by the executor's ${GATE_BASH_TIMEOUT_MS}ms Bash-tool timeout before it could report — a BUDGET exhaustion, NOT a gate failure`;
  } else if (terminalOutcome === 'GATE_SLICE') {
    unfinished = `the suite did not finish within ${GATE_MAX_SLICES} slices of ${GATE_SLICE_SECS}s (~${Math.round(GATE_MAX_SLICES * GATE_SLICE_SECS / 60)} min of gate wall time) — a BUDGET exhaustion, NOT a gate failure`;
  } else if (lastSliceResumeAt !== undefined) {
    // temperloop#2094: a terminal outcome whose NAME says "done" over a final
    // slice that printed a resume point. Say which one is being believed, and
    // why, rather than letting the name win silently.
    unfinished = `the final slice reported a resume point (gate ${lastSliceResumeAt}) — gates REMAINED when the run stopped, so the suite did NOT finish, whatever its terminal outcome '${terminalOutcome}' is named`;
  } else {
    // Neither a finished verdict nor a recognized budget outcome: the executor
    // returned something outside the gate's own closed set. Pre-#1587 this fell
    // through to the GATE_PASS/GATE_ABSENT arm and PUSHED a branch whose gate
    // never returned a verdict — the permissive-default hole this epic exists
    // to close. It is UNKNOWN, and the reason names the outcome verbatim rather
    // than dressing it up as a budget fact.
    unfinished = `the gate returned an unrecognized outcome '${terminalOutcome}' — no verdict was established (this is NOT a pass, and NOT a known budget exhaustion)`;
  }
  const found = `${failedGates} gate failure(s) recorded in slice(s) ${failedInSlices.join(', ')}`;

  if (failedGates > 0) {
    let reason;
    if (finished && terminalOutcome === 'GATE_FAIL') {
      reason = `the suite exited RED — ${found}`;
    } else if (finished) {
      // The temperloop#1587 shape: the FINAL slice passed, so the log's last
      // line reads "OK — gates N..M passed (final slice)". Say plainly that the
      // green line covers only the gates that slice ran, or the next reader
      // repeats #1587's mis-read and calls the escalation a false positive.
      reason = `${found}; the FINAL slice reported ${terminalOutcome}, but its green line covers ONLY the gates that slice ran — the suite as a whole is RED`;
    } else {
      reason = `${found} BEFORE the run stopped early — ${unfinished}. The gates that never ran have no verdict, but the recorded failures are real, so the branch is known-RED, not unknown`;
    }
    return { verdict: 'RED', finished, failedGates, failedInSlices, reason };
  }
  if (!finished) {
    return {
      verdict: 'UNKNOWN',
      finished,
      failedGates: 0,
      failedInSlices,
      reason: `${unfinished}; no gate failed in the slices that DID run, and the suite's overall verdict is unknown`,
    };
  }
  return {
    verdict: 'GREEN',
    finished,
    failedGates: 0,
    failedInSlices,
    reason: `the suite finished and every gate passed (terminal outcome ${terminalOutcome})`,
  };
}

// discriminationGaps — the temperloop#1319 DEGRADED CASE. WORKER_VERDICT_SCHEMA
// does not (and per the "advisory, never a new blocking gate" ask, must not)
// mark `discrimination_evidence` required, §3d branches solely on `.status`,
// and §3e.5 never looks at it — so a worker that simply OMITS the field on an
// otherwise-`passed: true` entry produces a `done` verdict that sails through
// the whole pipeline and renders a PR body indistinguishable from "not
// applicable" or a pre-#1319 PR. THIS is the load-bearing half criterion 2
// actually requires: a missing field must be a NAMED, VISIBLE degradation, not
// a silent one. Mirrors the pre-existing `verification_surface` degraded-case
// pattern (build.md §3f step 2, "Surface the degraded case") exactly — a
// legible warning, never a hard failure (kernel principle 7, advisory over
// enforced discipline): a `passed: false`/`blocked`/`failed` entry is
// untouched (only a CLAIMED pass with no proof is suspect).
//
// Gated on REQUIRE_DISCRIMINATION_EVIDENCE — an unarmed run (today: /sweep,
// /fix) never required the field in the first place, so it has nothing to
// degrade FROM and this returns empty unconditionally, exactly like
// discriminationEvidenceSection() above.
function discriminationGaps(verdict) {
  if (!REQUIRE_DISCRIMINATION_EVIDENCE) return [];
  return (verdict.acceptance_results ?? [])
    .filter((r) => r && r.passed === true && !(r.discrimination_evidence && String(r.discrimination_evidence).trim()))
    .map((r) => (r.criterion ? String(r.criterion) : '(unlabeled criterion)'));
}

// isHostConfigDeferral / hostConfigDeferrals — the temperloop#1182 DEFERRAL,
// the THIRD disposition an acceptance criterion can carry. `passed` is a
// boolean and a worktree can never observe a gitignored host-local file, so
// without a third state a host-config criterion has only two bad answers: a
// claimed pass the worker structurally could not make, or a `passed: false`
// §3d reads as blocked and stalls the whole level on a check that was never
// runnable here (foundation#1556 — the worker escalated
// `acceptance-incomplete` over a `credential_present: false` that read `true`
// in both real checkouts moments later).
//
// The marker is the PAIR (`passed: false` + a non-empty `deferred_host_config`)
// so neither half alone changes anything: a bare `passed: false` still blocks
// exactly as before, and the marker on its own never manufactures a pass. It
// is deliberately NOT gated on a run-level flag — the worktree-vs-index fact
// it encodes is true on every path that spawns a worker.
function isHostConfigDeferral(r) {
  return !!(r && typeof r.deferred_host_config === 'string' && r.deferred_host_config.trim());
}

// The parked-record tally: [{ criterion, host_config }]. `host_config` carries
// the file/env var the worker named, because that is precisely what the
// orchestrator needs to run the parent-side check (build.md §4a) — a bare
// criterion list would make the parent re-derive it from prose.
function hostConfigDeferrals(acceptanceResults) {
  return (acceptanceResults ?? []).filter(isHostConfigDeferral).map((r) => ({
    criterion: r.criterion ? String(r.criterion) : '(unlabeled criterion)',
    host_config: String(r.deferred_host_config).trim(),
  }));
}

// park()'s trailing three arguments (discriminationGapList, review, cost) are
// INDEPENDENT tallies (temperloop#1319, temperloop#1450, temperloop#2065)
// that happened to land on the same function in the same window — none
// supersedes another; each is optional and independently omitted when
// empty/absent, exactly like `no_ci` above.
function park(slug, pr, pushedSha, acceptanceResults, noCi, recovery, discriminationGapList, review, cost) {
  const parked = { slug, pr, pushed_sha: pushedSha, acceptance_results: acceptanceResults ?? [] };
  // temperloop#939: a record reconstructed from observable side-effects after a
  // lost worker return carries its provenance EXPLICITLY. `acceptance_unverified`
  // is the load-bearing half — the acceptance results in this record are
  // UNKNOWN, not passing, and the orchestrator must verify them itself before
  // the merge gate rather than assuming the 3d self-check ran.
  if (recovery) {
    parked.acceptance_unverified = true;
    parked.recovered_from = recovery.stage;
  }
  // temperloop#605/#618: a NO_CI-outcome item parks identically to a green one,
  // but carries a durable `no_ci` marker so the orchestrator stamps the
  // `  - no_ci: true` sub-line (build.md 3h) and renders `CI —  (no CI
  // configured)` rather than `CI ✓` in the 4a summary — never letting an
  // untested-by-CI PR look confirmed-green.
  if (noCi === true) parked.no_ci = true;
  // temperloop#1319: the degraded-case tally, same durable-marker shape as
  // `no_ci` above — carried on the parked record so the orchestrator can
  // stamp it on the plan item and roll it into the Step 6 summary (build.md
  // §3f step 2's sibling "Surface the degraded case" pattern). Omitted
  // entirely when empty, exactly like `no_ci` is omitted when false, so an
  // unarmed run's parked records are byte-identical to before this item.
  if (discriminationGapList && discriminationGapList.length > 0) {
    parked.discrimination_gaps = discriminationGapList;
  }
  // temperloop#1450 — the §3e Step 6 tally build.md §3e promises needs
  // SOMEWHERE to read from. `review` is reviewTally()'d { ran, skipped,
  // mandatory_ok, routed_not_run } across every review round this item's
  // build actually ran (the 3e pass plus any CI-fix re-review) — absent for a
  // spike (skips 3b-3h, never reviews) or omitted by an older call site.
  // `mandatory_ok` is false iff a mandatory (foundation#1007) route was ever
  // genuinely skipped, not merely "an optional reviewer wasn't available";
  // `routed_not_run` (temperloop#1984) names every reviewer the routing
  // resolved that did not run, mandatory or not, so the tally cannot read
  // fully clean while a tsv-routed reviewer was skipped. See reviewTally().
  if (review) parked.review = review;
  // temperloop#2065 "worker-cost-capture" (epic #2062's dual-build ledger) —
  // per-item worker cost: tokens, wall-clock, retry cost and a `recovery`
  // flag, captured at callWorker()/ciPollLoop()'s emitted-shell seam (see
  // workerClockNow()/workerUsageEmit() above) and reconciled against the
  // model-usage envelope (workflows/scripts/build/worker-usage.sh →
  // model-usage-envelope.sh's model_usage_emit_from_envelope, seat
  // "build-worker"). `cost.recovery` is this record's OWN plain-boolean
  // projection of the `recovery` PARAMETER above (a probe object, or null) —
  // a DIFFERENT thing from `recovered_from`/`acceptance_unverified`, which
  // name WHICH stage the temperloop#939 probe landed at; `recovery` here only
  // says whether the cost figures above are trustworthy (a recovered record
  // never observed the worker's own return, so its tokens/wall-clock are
  // whatever the LOST call still managed to report through the fail-open
  // seam, never fabricated). Present iff the caller passed `cost` — the
  // spike call site (4 args) omits it, so a spike's parked record stays
  // byte-identical to before this item; the 3h main path always passes it,
  // so EVERY non-spike parked record carries all six keys, present even at
  // their null/zero baseline (never conditionally omitted like `no_ci`
  // above — a cost ledger with silently-missing rows is worse than one with
  // honest nulls).
  if (cost) {
    parked.tokens_in = cost.tokens_in ?? null;
    parked.tokens_out = cost.tokens_out ?? null;
    parked.wall_clock_ms = cost.wall_clock_ms ?? null;
    parked.retry_tokens = cost.retry_tokens ?? null;
    parked.retry_count = cost.retry_count ?? 0;
    parked.recovery = !!cost.recovery;
  }
  // temperloop#1182: derived from `acceptanceResults` rather than threaded in
  // as a 9th positional argument, so BOTH park() call sites (the 3h main path
  // and the spike path at 3b, which passes only four arguments) surface the
  // deferrals without a signature change. Same durable-marker shape as
  // `no_ci`/`discrimination_gaps` — omitted entirely when empty, so a run with
  // no host-config criterion produces byte-identical parked records to before.
  // NOT advisory, unlike discrimination_gaps: these criteria are UNVERIFIED
  // (the `acceptance_unverified` family), and the invoking spec's parent-side
  // seat must verify each one before the item is eligible to merge — build.md
  // §4a, sweep.md's per-chunk merge pass, or fix.md Step 5 (the seat list in
  // the I/O CONTRACT header). build.md §3h.5's as-you-go tier is INELIGIBLE
  // for an item carrying this field: that path never reaches §4a.
  const hostDeferrals = hostConfigDeferrals(acceptanceResults);
  if (hostDeferrals.length > 0) parked.host_config_deferrals = hostDeferrals;
  return {
    _kind: 'parked',
    slug,
    parked,
  };
}

// machineryDenied — a machinery step returned no usable outcome. runMachinery already
// normalizes agent()'s null (auto-mode classifier DENIED the command / user
// skip / terminal API error) to a SPINE_DENIED sentinel; this recognizes both
// that sentinel and a bare null. Either means "the mechanical step did not run"
// — so the caller escalates `machinery-denied` (a clean, parkable escalation the
// orchestrator can drive to a human) instead of dereferencing `.outcome` on a
// null/absent result and crashing the level (temperloop#72).
function machineryDenied(out) {
  return out == null || out.outcome === 'SPINE_DENIED';
}

// -----------------------------------------------------------------------------
// Session-quota death classification (temperloop#1819).
// -----------------------------------------------------------------------------
// A step or worker that dies because the SESSION hit its usage limit ("You've
// hit your session limit · resets 5:30pm") used to collapse into the two
// pre-existing kinds — `machinery-denied`/SPINE_DENIED (whose documented cure
// is rewriting the command for the auto-mode classifier) and `worker-error`
// "agent returned null" (whose cure is re-driving with sharper instructions).
// BOTH cures are wrong for a quota death: the command was never the problem
// and the work is usually INTACT in the worktree (the #1819 incident's item
// held three clean commits and a finished verification surface — re-driving
// would have discarded a finished item). So a quota death gets its OWN kind,
// `quota-exhausted`, whose disposition is wait-for-reset then RESUME.
//
// The death reaches this script through TWO shapes, classified differently:
//   • agent() THREW and the error text carries the harness's limit message —
//     quotaDeath(text) matches it directly and extracts the reset time.
//   • agent() returned a bare NULL (the #1819 incident's shape) — no text
//     reaches this script at all (the truth lives only in the harness's own
//     <failures> block, a channel the orchestrator reads, not this script).
//     The one in-process discriminator left is BEHAVIORAL: a classifier
//     denial is per-command (an innocuous probe still spawns), while a quota
//     death kills EVERY spawn. harnessCanSpawnAgents() runs that probe — a
//     cheap canary agent, re-run per bare-null with only its DEAD verdict
//     memoized (see its own comment) — and a failed canary reclassifies the
//     null as quota-exhausted. A canary that spawns fine leaves the pre-#1819
//     kinds untouched, so genuine denials/skips keep their meanings.
const QUOTA_KIND = 'quota-exhausted';
const QUOTA_DEATH_RE =
  /\b(?:hit|reached|exceeded)\s+(?:your|the)\s+(?:session|usage|weekly|monthly|5-?hour|rate)\s+limit\b/i;

// quotaDeath — null when `text` is not the harness's quota-death message;
// otherwise { reset: <string|null> } with the reset time when the message
// carries one ("… · resets 5:30pm" → "5:30pm").
function quotaDeath(text) {
  const s = String(text ?? '');
  if (!QUOTA_DEATH_RE.test(s)) return null;
  const m = s.match(/\bresets?\b[\s·:,–—-]*([^\n]+)/i);
  return { reset: m ? m[1].trim() : null };
}

// harnessCanSpawnAgents — the null-shape discriminator above. Memoization is
// deliberately ASYMMETRIC (temperloop#1819 attempt-2 review finding 1): only a
// DEAD verdict is sticky. The quota is monotone within one exhaustion window —
// once every spawn dies, they keep dying — so one dead probe answers for the
// whole level's burst of deaths. (A window that resets mid-level could make the
// cached "dead" stale for a later item; that item still escalates with its work
// intact — exactly what the wait-then-resume disposition handles — so the dead
// cache stays.) An ALIVE verdict is NOT cached: "alive at probe time" says
// nothing about a spawn that dies LATER in the same level, and a memoized alive
// would misroute that later quota death back into machinery-denied/worker-error
// — the destructive mis-cure this whole classifier exists to prevent. So every
// bare-null re-probes; concurrent callers still share one in-flight probe (the
// promise is the cache entry until it resolves alive). Fails OPEN: an
// inconclusive canary (a non-quota throw) reads as "alive" so the pre-#1819
// kinds stand rather than inventing a quota verdict from a probe that merely
// misbehaved.
let agentLivenessCheck = null;
function harnessCanSpawnAgents() {
  if (!agentLivenessCheck) {
    agentLivenessCheck = (async () => {
      try {
        const out = await agent(
          'Liveness probe: do nothing except return the JSON object {"ok": true} via StructuredOutput.',
          {
            label: 'canary:quota-probe',
            // Off-path diagnostic (temperloop#1294) — own group, cursor untouched.
            phase: stagePhase(STAGE_RECOVER),
            model: input.machinerySoloModel || 'haiku',
            schema: { type: 'object', properties: { ok: { type: 'boolean' } }, required: ['ok'] },
          },
        );
        return out != null;
      } catch (err) {
        return !quotaDeath(String((err && err.message) || err));
      }
    })().then((alive) => {
      // Alive → drop the cache so the NEXT bare-null probes afresh; dead →
      // leave the resolved promise in place (the sticky verdict).
      if (alive) agentLivenessCheck = null;
      return alive;
    });
  }
  return agentLivenessCheck;
}

// quotaEscalation — the quota-exhausted escalation record. `worktree_left_intact`
// is load-bearing (issue #1819 acceptance): it is what tells the disposer this
// is a recover-vs-re-drive decision — the escalation cleaned up NOTHING, so
// whatever the item had built is still in the worktree.
function quotaEscalation(slug, where, { errorText = null, worktree = null, extra = null } = {}) {
  const qd = errorText ? quotaDeath(errorText) : null;
  return escalate(slug, QUOTA_KIND, {
    where,
    classified_by: errorText ? 'error-text' : 'agent-liveness-canary',
    reset_time: qd ? qd.reset : null,
    error: errorText,
    worktree,
    worktree_left_intact: true,
    retryable: true,
    reason:
      'the harness session-usage quota ran out mid-run (temperloop#1819) — an ENVIRONMENTAL death, ' +
      'not a classifier refusal (machinery-denied) and not a content failure (worker-error): ' +
      'nothing was cleaned up, so any work the item had produced is still in the worktree' +
      (qd && qd.reset
        ? `; the quota resets ${qd.reset}`
        : '; no reset time was reported — check quota-gate.sh / ~/.claude/rate-limits.json') +
      '. Wait for the reset, then inspect the worktree (pr.sh recover-probe) and RESUME what landed ' +
      'rather than re-driving from scratch.',
    ...(extra ?? {}),
  });
}

// deniedOrQuota — every site that mints a `machinery-denied` escalation routes
// through this instead: a SPINE_DENIED whose real cause is the quota death
// (the canary cannot spawn either) becomes quota-exhausted; a genuine denial
// keeps the byte-identical machinery-denied escalation it always produced.
async function deniedOrQuota(slug, payload, worktree) {
  if (!(await harnessCanSpawnAgents())) {
    const step = typeof payload.step === 'string' ? payload.step : 'batch';
    return quotaEscalation(slug, `machinery:${step}`, {
      worktree,
      extra: { denied_out: payload.out ?? null, ...(payload.sha !== undefined ? { sha: payload.sha } : {}) },
    });
  }
  return escalate(slug, 'machinery-denied', payload);
}

// -----------------------------------------------------------------------------
// §3e — the mandatory/routed pre-push review (temperloop#1430).
// -----------------------------------------------------------------------------
// build.md §3e's routing rules, run for REAL inside this driver — see that
// section's own "why this runs inside the workflow" paragraph for the
// orchestrator↔workflow-boundary rationale. Before this item the review lived
// only as worker-discretion prose: the 3c worker CANNOT spawn a nested
// `agent({agentType})` (the "No context-inheriting research forks" contract in
// workerPrompt() forbids exactly that shape), so the mandatory
// `claude/commands/*.md` → `workflow-reviewer` rule (foundation#1007) could
// never actually run on the default Workflow path — every command-doc PR
// reported a STRUCTURALLY GUARANTEED "skipped — unavailable", which read as a
// legible degradation but was in fact a permanent no-op. This driver spawns
// the reviewer itself, so the same skip notice now fires only when the
// reviewer genuinely fails to resolve.

// reviewDiffCmd — ONE solo runMachinery call that reads the two raw inputs the
// routing DECISION needs off the worktree: the changed-file list (relative to
// the fresh origin/<default>, three-dot so only THIS branch's own commits
// count) and the raw reviewer-routing.tsv text (empty string when the
// worktree ships none — a consuming repo that has not vendored it). Mirrors
// pr.sh's own `default_branch()` fallback chain (origin/HEAD, else
// main/master) so this never depends on pr.sh being invoked first.
//
// temperloop#1976: alongside `tsv` this also emits `tsv_rows` (count of
// non-blank, non-`#` lines — the SAME first-stage filter parseTsvRows()
// applies before its column check), computed HERE off the worktree's own
// file, independently of whatever the machinery-executor relay hands back
// for `tsv` itself. That independence is the whole point: the relay is a
// separate agent copying this step's JSON line, and it has been observed
// dropping the (large) `tsv` field entirely while leaving `files` intact
// (evidence: wf_cbc556f5-7be). `tsv_rows` gives runReviewers() a cheap
// row-count check that the `tsv` it received is the SAME one this command
// actually read, without re-reading the file itself — a ROW-COUNT check
// only: it catches a dropped or truncated table (a row-count mismatch), not
// a same-length garble (content corrupted without changing the row count).
//
// temperloop#1982: this also emits `tsv_checksum` — a content checksum, not
// a row count. A prior attempt at a content check (`tsv_sha256`, temperloop
// #1976 round 1) was reverted as dead code: it hashed the SOURCE file but
// nothing could ever recompute a comparable hash from the RECEIVED `tsv`
// string, because SHA-256 needs a matching implementation on the JS side and
// none existed — "no hashing primitive" meant no SHA-256, not that no check
// is possible. `tsvChecksum()` below closes that gap with a checksum needing
// no primitive at all: a POSITION-WEIGHTED sum of character codes over the
// SAME row-count-filtered lines (temperloop#1982 round 2 — see tsvChecksum's
// own comment for why position-sensitivity, not just a sum, is the point),
// expressible in pure arithmetic on both sides — this bash pipeline (byte
// values via `od`, weighted and summed in awk) and tsvChecksum() (JS char
// codes, weighted and summed in a loop) are independent implementations of
// the identical algorithm, verified (by an automated test that executes
// THIS bash pipeline for real — test_workflow.sh, "bash/JS parity") to agree
// against this repo's own reviewer-routing.tsv (including its non-ASCII
// comment-header punctuation, which is excluded from the sum by the same
// comment/blank filter tsv_rows already applies). The two sides agree only
// while every DATA row stays pure ASCII (byte value == UTF-16 code unit) —
// see reviewer-routing.tsv's own header for that constraint, which governs
// data rows only; the comment header's non-ASCII punctuation is filtered out
// before either side sums, so it never touches this. A worktree that
// genuinely ships no tsv
// emits `tsv:""`, `tsv_rows:0`, `tsv_checksum:0` — never an omitted `tsv`
// key — so "missing" stays a signal of the relay dropping the field, not of
// a legitimate no-tsv worktree.
//
// temperloop#1970: it ALSO reads — and, on a bumping call, increments — the
// per-worktree §3e ROUND COUNTER the REVIEW_BLOCKING convergence bound reads.
// `review_rounds` is the PRE-increment value: how many review rounds this
// worktree had already run before this one. Three properties are load-bearing:
//   - it lives in the worktree's GIT DIR (`git rev-parse --git-dir`, which for a
//     linked worktree is that worktree's own `…/.git/worktrees/<name>`), NEVER
//     in the working tree — a stray untracked file there would surface in
//     `git status`, in the 3e.5 gate's `--scoped` untracked-path resolution, and
//     in the tracked-path coverage manifests. It is removed with the worktree.
//   - it rides THIS call, which §3e already makes — zero extra agent spawns, and
//     the counter survives the escalate → orchestrator → re-invoke loop it
//     bounds (a continuation skips 3b, so the worktree and its git dir persist).
//   - `bump` is false on the #1976 tsv-gap RE-FETCH, so one driver round bumps
//     the counter exactly once no matter how many times the command runs.
// Every step fails SOFT (a missing/unwritable marker reads 0, and a
// corrupted-but-present one degrades to 0 rather than aborting the step), so a
// worktree whose git dir cannot be resolved simply behaves as it did before
// this item.
function reviewDiffCmd(wt, bump = true) {
  const tsvPath = `${wt}/workflows/scripts/config/reviewer-routing.tsv`;
  // The row-filter awk program (blank/`#` lines stripped) is reused for BOTH
  // tsv_rows (count) and tsv_checksum (position-weighted byte-sum via `od`)
  // — one filter definition, two consumers, so the two can never disagree
  // on WHICH lines count.
  const rowFilterAwk =
    `BEGIN{c=0} { l=$0; sub(/\\r$/,"",l); t=l; gsub(/^[ \\t]+|[ \\t]+$/,"",t); if (t != "" && substr(t,1,1) != "#") print l }`;
  return [
    `cd ${sq(wt)} || exit 1`,
    `rounds_file=""`,
    `gd="$(git rev-parse --git-dir 2>/dev/null)"`,
    `[ -n "$gd" ] && rounds_file="$gd/build-review-rounds"`,
    `review_rounds=0`,
    // DECIMAL, NEVER OCTAL (temperloop#1970, typescript-reviewer round 1). The
    // `tr` filter strips non-digits but NOT leading zeros, and POSIX `$(( ))`
    // reads a leading-`0` numeral as OCTAL — so a marker file someone
    // hand-edited, or restored from a stale snapshot, holding `08`/`09` is not
    // a wrong count but a HARD shell error that aborts the whole step and
    // surfaces as exactly the `review-diff-error` escalation §3e is least able
    // to act on. This code path cannot write such a value itself, but the file
    // is an ordinary file in the worktree's git dir and the surrounding
    // contract is explicit that every marker step fails SOFT — a
    // corrupted-but-present marker was the one case that story did not cover.
    // `sed -E 's/^0+//'` normalises to a bare decimal (an all-zeros value
    // collapses to the empty string, which the `[ -n … ]` fallback below then
    // reads as 0), so a corrupted marker degrades to "first round" exactly as a
    // missing one does. `sed -E` over `\\?`-style BRE: the same portable dialect
    // the `origin/` strip below already relies on.
    `if [ -n "$rounds_file" ] && [ -f "$rounds_file" ]; then`,
    `  review_rounds="$(tr -cd '0-9' < "$rounds_file" | sed -E 's/^0+//')"`,
    `fi`,
    `[ -n "$review_rounds" ] || review_rounds=0`,
    ...(bump
      ? [
          `if [ -n "$rounds_file" ]; then`,
          `  printf '%s\\n' "$((review_rounds + 1))" > "$rounds_file" 2>/dev/null || true`,
          `fi`,
        ]
      : []),
    `default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"`,
    `if [ -z "$default" ]; then`,
    `  for b in main master; do`,
    `    if git show-ref --verify --quiet "refs/remotes/origin/$b"; then default="$b"; break; fi`,
    `  done`,
    `fi`,
    `[ -n "$default" ] || default=main`,
    `files_json="$(git diff --name-only "origin/$default...HEAD" 2>/dev/null | jq -R -s -c 'split("\\n") | map(select(length>0))')"`,
    `[ -n "$files_json" ] || files_json='[]'`,
    `if [ -f ${sq(tsvPath)} ]; then`,
    // RELAY ONLY THE DATA ROWS (temperloop#1982 round 3). The field crosses a
    // machinery-executor agent, which is specified to return the command's JSON
    // line verbatim and has instead been observed omitting this one field
    // outright, and once replacing it with an English sentence describing the
    // table ("The reviewer-routing.tsv file contains 11 data rows routing files
    // to review subagents…"). Rounds 1 and 2 added receiving-end checks — a row
    // count, then a position-weighted checksum — which detect the substitution
    // but cannot prevent it: no check on this side stops a model on the other
    // side from paraphrasing. What CAN be reduced is the bait. The raw file is
    // 3,834 bytes of which 699 are data (11 rows); the other 82% is comment
    // prose, i.e. the executor was being handed ~4KB of mostly-English text and
    // asked to echo it. Sending `rowFilterAwk`'s output instead ships only the
    // rows the routing decision actually reads.
    //
    // Invariant-neutral by construction, which is why this needs no JS or test
    // change: BOTH receiving-end readers already apply this same filter before
    // they compute anything — parseTsvRows() drops blank/`#` lines, and
    // tsvChecksum() canonicalises with the identical trimmed-emptiness rule —
    // so filtering here is idempotent and every gap check yields the same value
    // it did on the unfiltered text. The filter itself is `rowFilterAwk`, the
    // SAME expression the checksum below already uses, so this adds no second
    // implementation of the row rule to drift against.
    //
    // MITIGATION, NOT A PROOF: a model can still paraphrase 699 bytes. The
    // structural fix — keeping the table out of the relay entirely, or emitting
    // parsed rows the executor has no prose reading of — stayed open on #1982
    // and is closed HERE (temperloop#2020, second half): the field is no longer
    // a `tsv` SCALAR holding a multi-line table, it is `tsv_lines`, a JSON
    // ARRAY OF ROW STRINGS built by the SAME
    // `jq -R -s -c 'split("\n") | map(select(length>0))'` idiom `files_json`
    // above already uses. The shape is chosen on evidence, not taste: across
    // every observed mangling (#1976 wf_cbc556f5-7be; #1982's three shapes;
    // #2020's own foundation#1869 reproduction, where BOTH retry agents
    // dropped it identically) `files` — a jq array of strings produced by this
    // exact idiom — arrived INTACT in the same JSON line whose `tsv` blob was
    // dropped, paraphrased, or double-encoded. An array of short opaque row
    // strings offers no English reading to paraphrase into and no "quote the
    // table" framing to re-encode; a ~700-byte tab-delimited blob offers both.
    //
    // Invariant-neutral for the SECOND time by construction: the array's rows
    // joined on `\n` are byte-identical to the string this used to emit (see
    // reviewDiffTsvText), so `tsv_rows`, `tsv_checksum`, parseTsvRows() and
    // tsvChecksum() all yield exactly the values they did before — the
    // #1976/#1982 gap checks are untouched DETECTORS, not weakened ones.
    // `tsv` itself is no longer emitted; the reader still ACCEPTS it
    // (reviewDiffTsvText) so a relay or caller that yields the legacy scalar
    // keeps routing rather than degrading.
    `  tsv_json="$(awk ${sq(rowFilterAwk)} ${sq(tsvPath)} | jq -R -s -c 'split("\\n") | map(select(length>0))')"`,
    `  tsv_rows="$(awk 'BEGIN{c=0} { l=$0; sub(/\\r$/,"",l); t=l; gsub(/^[ \\t]+|[ \\t]+$/,"",t); if (t != "" && substr(t,1,1) != "#") c++ } END{print c+0}' ${sq(tsvPath)})"`,
    // POSITION-WEIGHTED (temperloop#1982 round 2): `n` is a running counter
    // over EVERY byte of the row-filtered stream, NOT reset between od's own
    // output lines — so each byte's contribution depends on where it sits,
    // not just what it is. A bare sum (the round-1 shape) is commutative and
    // therefore blind to two same-length rows trading places; weighting by
    // position closes that — see tsvChecksum()'s own comment for the exact
    // corruption shape this defeats.
    `  tsv_checksum="$(awk ${sq(rowFilterAwk)} ${sq(tsvPath)} | od -An -v -tu1 | awk '{for(i=1;i<=NF;i++){n++; s+=$i*n}} END{print s+0}')"`,
    `else`,
    // The no-tsv worktree emits an EMPTY ARRAY, the `tsv_lines` analogue of the
    // `tsv:""` it used to emit — still never an OMITTED key, so "missing" keeps
    // meaning "the relay dropped it", never "this worktree ships no table".
    `  tsv_json='[]'`,
    `  tsv_rows=0`,
    `  tsv_checksum=0`,
    `fi`,
    `printf '{"outcome":"REVIEW_DIFF","files":%s,"tsv_lines":%s,"tsv_rows":%s,"tsv_checksum":%s,"review_rounds":%s}\\n' "$files_json" "$tsv_json" "$tsv_rows" "$tsv_checksum" "$review_rounds"`,
  ].join('\n');
}

// parseTsvRows / reviewGlobMatch — the SAME extension/glob axis
// reviewer-routing.tsv declares (ADR 0008), read fresh off the worktree's own
// copy each run so this never drifts from the tracked source of truth (never
// a hardcoded restatement — the exact drift check-reviewer-routing.sh guards
// against in build.md prose applies here too, just enforced by reading the
// file instead of a lint).
function parseTsvRows(tsvText) {
  return String(tsvText ?? '')
    .split('\n')
    .map((l) => l.replace(/\r$/, ''))
    .filter((l) => l && !l.trim().startsWith('#'))
    .map((l) => l.split('\t'))
    .filter((cols) => cols.length >= 2 && cols[0] && cols[1])
    .map(([key, reviewer]) => ({ key: key.trim(), reviewer: reviewer.trim() }));
}

// tsvChecksum — temperloop#1982, made POSITION-SENSITIVE in round 2: a
// pure-arithmetic content checksum over the SAME row-count-filtered lines
// parseTsvRows()'s first stage keeps (blank and `#`-comment lines stripped),
// so a corrupted comment header (which carries this repo's own non-ASCII
// punctuation, e.g. em dashes) never enters the sum and cannot desync the
// two independent implementations of this algorithm — this one, and
// reviewDiffCmd's bash pipeline (`od`-computed byte values, weighted and
// summed in awk).
//
// WHY POSITION-WEIGHTED, NOT A BARE SUM (round 1's shape): a bare sum of
// character codes is COMMUTATIVE — invariant under any rearrangement of the
// same characters. The round-2 reviewer reproduced this against this repo's
// OWN tracked reviewer-routing.tsv: swapping the reviewer+path columns
// between the `.sh` row and the `docs/**` row (same row count, same overall
// character multiset — a plausible hand-copy slip, and the exact shape of
// the temperloop#1978 round-4 incident: a .sh diff silently routed to
// docs-reviewer) left the bare-sum checksum byte-IDENTICAL. Multiplying each
// character's code by its 1-based position in the canonicalized stream
// before summing breaks that: the SAME characters at DIFFERENT offsets sum
// to a different total (verified against this repo's live tsv — see
// test_workflow.sh's "K1982 position-sensitive: transposed columns" case).
// This is still an INTEGRITY check against relay noise, not a cryptographic
// one — collisions are not the concern, only whether the `tsv` string
// runReviewers() received is the same content, in the same arrangement,
// reviewDiffCmd actually read off the worktree.
//
// Needs no hashing primitive: canonicalize (kept lines, each with its own
// trailing newline — matching awk's `print`, ORS appended after every line,
// none added at the very end beyond that, so a run over zero lines sums to
// 0), then `sum += code * (i + 1)` over that string. Verified — by an
// automated test that executes reviewDiffCmd's REAL bash pipeline, not a
// restated comment — to agree with the bash side against this repo's own
// reviewer-routing.tsv (test_workflow.sh's "bash/JS parity" case). That
// agreement holds only while every DATA row (not the comment header, which
// is filtered out before either side sums) is pure ASCII — reviewer-routing
// .tsv's own header names that constraint for whoever next edits a data row.
function tsvChecksum(tsvText) {
  // Trimmed-emptiness filter (`l.trim()`, not bare `l`) — matches
  // reviewDiffCmd's bash `t != ""` check (`t` is the TRIMMED line) exactly,
  // so a whitespace-only line is filtered identically on both sides. This
  // deliberately does NOT reuse parseTsvRows's own first-stage filter (bare
  // `l`), which answers a different question (is this a candidate data row
  // for the routing decision) — tsvChecksum answers "did the bash side count
  // this line," and those two must agree bit-for-bit or the checksum could
  // disagree with a perfectly faithful relay.
  const canon = String(tsvText ?? '')
    .split('\n')
    .map((l) => l.replace(/\r$/, ''))
    .filter((l) => l.trim() && !l.trim().startsWith('#'))
    .map((l) => `${l}\n`)
    .join('');
  let sum = 0;
  for (let i = 0; i < canon.length; i++) sum += canon.charCodeAt(i) * (i + 1);
  return sum;
}
function reviewGlobMatch(key, file) {
  // BASENAME form, e.g. '**/Makefile' (temperloop#1705) — the tsv key shape
  // for an extensionless, path-independent file neither other form can key
  // on. Match the basename EXACTLY, never as a bare suffix: leaning on the
  // extension arm's `file.endsWith('Makefile')` would also claim
  // `NotAMakefile`, routing an unrelated file to a reviewer chosen for this
  // one. Checked FIRST — a '**/x' key never ends in '/**', so the two glob
  // shapes stay disjoint.
  if (key.startsWith('**/')) {
    const base = key.slice(3);
    return file === base || file.endsWith(`/${base}`);
  }
  if (key.endsWith('/**')) return file.startsWith(key.slice(0, -2));
  return file.endsWith(key); // extension form, e.g. '.py'
}

const REVIEW_COMMANDS_DOC_RE = /^claude\/commands\/.*\.md$/;
const REVIEW_PROSE_MD_RE = /\.md$/;

// determineReviewers — build.md §3e's full routing rule set, applied to this
// item's changed-file set. Every matching axis is included (build.md: "A
// change matching more than one axis ... runs each matching reviewer").
// Returns [{ reviewer, mandatory, reasons[] }, ...], reviewer names deduped.
//
// temperloop#2020 — `opts.tableAvailable: false` runs the TABLE-INDEPENDENT
// axes ONLY. The rule set splits cleanly in two: the `review:` override, the
// `kind: architectural` axis and the MANDATORY command-doc rule
// (foundation#1007) are computed purely from `item`/`files` and never consult
// reviewer-routing.tsv at all; the extension axis and the prose-`*.md`
// fallback are the only ones that do. When the table does not survive the
// machinery relay, only that second half is unknowable — so asking for
// `tableAvailable: false` drops exactly those and keeps the rest, and a
// degraded relay can never silently swallow a route that never needed the
// table. The prose-`*.md` fallback is deliberately on the DROPPED side: it
// fires precisely when no row matched, and with a broken table "no row
// matched" is not a fact, it is an absence of evidence.
function determineReviewers(item, files, tsvText, opts = {}) {
  const tableAvailable = opts.tableAvailable !== false;
  const rows = tableAvailable ? parseTsvRows(tsvText) : [];
  const matched = new Map(); // reviewer -> Set(reasons)
  const add = (reviewer, reason) => {
    if (!reviewer) return;
    if (!matched.has(reviewer)) matched.set(reviewer, new Set());
    matched.get(reviewer).add(reason);
  };

  if (item.review) add(item.review, 'review: override');
  if (item.kind === 'architectural') add('architecture-reviewer', 'kind: architectural');

  let anyCommandsDoc = false;
  for (const f of files) {
    if (REVIEW_COMMANDS_DOC_RE.test(f)) {
      anyCommandsDoc = true;
      continue; // the mandatory rule below claims this file, never the tsv/prose fallback
    }
    // Both remaining axes read `rows`; with no trustworthy table there is
    // nothing to decide for this file, and guessing is the #1976/#1982
    // silent-misroute. The command-doc rule above has already been recorded.
    if (!tableAvailable) continue;
    let tsvHit = false;
    for (const row of rows) {
      if (reviewGlobMatch(row.key, f)) {
        add(row.reviewer, `${row.key} -> ${row.reviewer}`);
        tsvHit = true;
      }
    }
    if (!tsvHit && REVIEW_PROSE_MD_RE.test(f)) {
      add('docs-reviewer', 'prose *.md fallback (no tsv row)');
    }
  }
  // Mandatory command-doc rule (foundation#1007) — always wins for a
  // claude/commands/*.md diff, regardless of any tsv row or the prose
  // fallback; never omitted, never worker-discretion.
  if (anyCommandsDoc) add('workflow-reviewer', 'claude/commands/*.md (foundation#1007 — mandatory)');

  return Array.from(matched.entries()).map(([reviewer, reasons]) => ({
    reviewer,
    mandatory: reviewer === 'workflow-reviewer' && anyCommandsDoc,
    reasons: Array.from(reasons),
  }));
}

// reviewPrompt — a read-only pass over THIS item's diff, carrying the same
// effective (kernel ∪ project) principle set §3c hands the worker (build.md
// §3e: "Reuse that resolution; do not re-resolve it here") as additional
// evaluation criteria. The reviewer's own agent definition (claude/agents/…)
// owns its checklist/output-format contract; this prompt only scopes it.
function reviewPrompt(item, wt, route, files) {
  return [
    `You are running build.md's §3e mandatory/routed pre-push review for /build`,
    `item \`${item.slug}\` (route: ${route.reasons.join('; ')}).`,
    '',
    '## Scope — READ-ONLY, advisory',
    `Review the changes on this branch relative to origin/<default>, in the worktree`,
    `at ${wt}. Run \`git diff\` / \`git log\` yourself there — the file list below is a`,
    'pointer, not the diff. Make no edits, no commits.',
    '',
    `Changed files (${files.length}):`,
    files.length ? files.map((f) => `  - ${f}`).join('\n') : '  (none reported)',
    '',
    ...principlesSection(item),
    '',
    "Follow your own agent definition's checklist and output format exactly.",
  ].join('\n');
}

// reviewHasBlockingFinding — this repo's reviewer catalog (workflow-reviewer,
// docs-reviewer, architecture-reviewer, the per-language reviewers) all share
// one output contract: `### [HIGH | MEDIUM | LOW] <name> in <file>`. A HIGH
// finding is the blocking bar — build.md §3e: "Blocking issues loop back to
// 3c with the review feedback as context."
function reviewHasBlockingFinding(text) {
  return /^\s*###\s*\[\s*HIGH\b/im.test(String(text ?? ''));
}

// reviewDiffTsvGap — temperloop#1976 (row-count), extended by temperloop#1982
// (content). The routing-table field (`tsv_lines` since temperloop#2020, the
// legacy `tsv` scalar before it — reviewDiffTsvText normalizes both) is
// hand-copied by the machinery-executor agent from the diff-fetch command's
// own JSON line, a SEPARATE step from the one that computed
// `tsv_rows`/`tsv_checksum` off the same worktree file — so any of the three
// can disagree only if the relay dropped, truncated, or otherwise garbled the
// (potentially large) table field on the way through.
//
// Both detectors below are UNCHANGED by #2020 — that item moved only the
// DISPOSITION after detection (runReviewers now degrades legibly rather than
// escalating `review-diff-error` on a persistent gap), never how much is
// detected.
//
// PATH A (missing/truncated — temperloop#1976, evidence: wf_cbc556f5-7be):
// neither table shape is present, or the received table's own non-comment row
// count disagrees with the relayed `tsv_rows` — a row-count mismatch.
//
// PATH B (content-preserving garble — temperloop#1982, evidence:
// temperloop#1978 round 4): `tsv` IS a string, and its row count DOES match
// `tsv_rows` (the guard above sees nothing wrong), yet its content differs
// from what reviewDiffCmd actually read off the worktree — the relay
// reproduced a plausible-LOOKING table (right length) that was not the real
// one, and determineReviewers() silently routed off it (that run's diff
// touched four `.sh` files with a `reviewer-routing.tsv` `.sh` row, yet only
// docs-reviewer ran). A row-count check structurally cannot see this: the
// row count survives the garble unchanged. Caught here by comparing
// `tsv_checksum` (relayed off the source file, a short scalar exactly like
// `tsv_rows`, and observed — same as `tsv_rows` — to survive the relay even
// when `tsv` itself does not) against `tsvChecksum(diffOut.tsv)` (recomputed
// HERE from the received string, no hashing primitive needed — see
// tsvChecksum()'s own comment for why the prior sha256 attempt, temperloop
// #1976 round 1, couldn't close this gap and this can).
//
// Returns null when the table is trustworthy, else the payload naming what's
// wrong, always carrying `files` (the changed-file list) so the degradation
// notice names what would have been routed: `{ missing: 'tsv', files }` when
// neither shape is present (the key stays `'tsv'` — it names the ROUTING
// TABLE, not one wire field, and is a stable payload key across both
// shapes); `{ mismatch: { expected, got }, files }` on a row-count
// disagreement (`got` is `?? null` since `tsv_rows` can itself be absent, and
// JSON.stringify silently drops an `undefined` key); `{ content_mismatch: {
// expected, got }, files }` when the row count agrees but the checksum
// doesn't (`got` is likewise `?? null` for an absent `tsv_checksum`). Only
// checked when `files` is non-empty: an empty diff never needs a routing
// table, so this never fires on the legitimate no-tsv-worktree case
// (`tsv_lines: []`, `tsv_rows:0`, `tsv_checksum:0`) either, regardless of
// `files` — a genuinely empty tsv is complete by construction (0 === 0 and
// tsvChecksum('') === 0).

// reviewDiffTsvText(diffOut) — temperloop#2020. The ONE place that turns a
// REVIEW_DIFF result's routing-table field into the text parseTsvRows() and
// tsvChecksum() consume, so the gap check and the routing decision can never
// read two different renderings of the same payload.
//
// Accepts BOTH wire shapes, in this precedence:
//   `tsv_lines` — the current shape (an array of data-row strings, #2020).
//                 Joined on `\n`, which is byte-identical to the string the
//                 previous `tsv` scalar carried: reviewDiffCmd's awk `print`
//                 emitted one kept line per row, and both consumers re-append
//                 their own trailing newline per kept line, so a joined array
//                 and the old blob canonicalize to the same bytes and hence
//                 the same row count and the same checksum.
//   `tsv`       — the legacy scalar, still ACCEPTED (never emitted). An
//                 un-migrated caller, a replayed older payload, or a relay
//                 that reconstructed the old field keeps routing normally
//                 instead of degrading.
// Returns null when NEITHER shape is present in a usable form — the caller
// distinguishes "dropped" from "legitimately empty" (`tsv_lines: []` is an
// empty ARRAY, a real zero-row table, not a missing field).
function reviewDiffTsvText(diffOut) {
  if (Array.isArray(diffOut?.tsv_lines)) {
    return diffOut.tsv_lines.map((l) => String(l)).join('\n');
  }
  if (typeof diffOut?.tsv === 'string') return diffOut.tsv;
  return null;
}

function reviewDiffTsvGap(diffOut, files) {
  if (!files.length) return null;
  const tsvText = reviewDiffTsvText(diffOut);
  if (tsvText === null) return { missing: 'tsv', files };
  const expected = parseTsvRows(tsvText).length;
  const got = Number(diffOut.tsv_rows);
  if (expected !== got) return { mismatch: { expected, got: diffOut.tsv_rows ?? null }, files };
  const expectedChecksum = tsvChecksum(tsvText);
  const gotChecksum = Number(diffOut.tsv_checksum);
  if (expectedChecksum !== gotChecksum) {
    return { content_mismatch: { expected: expectedChecksum, got: diffOut.tsv_checksum ?? null }, files };
  }
  return null;
}

// runReviewers — the §3e driver. Fetches the routing inputs (one machinery
// call), resolves the matching reviewer set, and spawns EACH directly via
// `agent({agentType})` — never delegated to the 3c worker. Every routed reviewer
// is spawned CONCURRENTLY and the whole fanout waits under one wall-clock
// ceiling (temperloop#2003, awaitReviewFanout), so one agent that never returns
// can neither block a later one from launching nor stall the level. Returns:
//   { escalation }                                   — the diff fetch itself failed
//   { summary, notes, blocking: [], ran, skipped }   — normal return (blocking may be non-empty)
// A THIRD shape (temperloop#2020) is a normal return, not a third branch: when
// the routing table does not survive the relay even after the one-shot retry,
// this returns the normal shape with one extra `skipped` degradation notice
// and `routing_degraded` carrying the gap payload — the drive continues to
// 3e.5/3f with the skip notice on the PR body. A post-commit advisory pass
// that cannot route is a DEGRADATION, never a halt. The degradation is
// PARTIAL: only the table-dependent axes are withdrawn, so the mandatory
// command-doc route (foundation#1007), the `review:` override and the
// `kind: architectural` axis — all computed from `item`/`files`, never from
// the table — still route and still run, and `ran` is therefore NOT
// necessarily empty in this shape.
//   { …the normal return, plus `escalation` }        — a MANDATORY reviewer hit
//     the ceiling (temperloop#2003): the tally is still computed and returned,
//     AND the item escalates `review-agent-timeout` rather than reading as if the
//     mandatory gate had passed. Callers check `.escalation` first either way.
// `summary` is a short tally line for the PR body (criterion: the PR must
// carry real evidence of a real pass, never a guaranteed-skip default).
// `notes` (temperloop#1450) is the FULL findings text for every reviewer that
// ran, one `### <reviewer>` block each — a non-blocking (MEDIUM/LOW-only)
// review is still advisory OUTPUT, not silently discarded after the HIGH
// check. Empty string when nothing ran. Callers splice `notes` into a durable
// surface (the PR body, at the 3f call site) rather than letting it evaporate
// once the blocking check has read it.
//
// `round` (temperloop#1970) is this pass's 1-based round number for THIS item's
// worktree, durable across the escalate→re-invoke loop (see reviewDiffCmd). The
// two blocking call sites compare it against REVIEW_BLOCKING_MAX_ROUNDS.
async function runReviewers(item, wt) {
  const fetchReviewDiff = (phaseTitle, bump) =>
    runMachinery(reviewDiffCmd(wt, bump), { label: `review-diff:${item.slug}`, slug: item.slug, phase: phaseTitle });

  let diffOut = await fetchReviewDiff(enterStage(STAGE_REVIEW), true);
  if (machineryDenied(diffOut)) {
    // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
    return { escalation: await deniedOrQuota(item.slug, { step: 'review-diff', out: diffOut }, wt) };
  }
  if (diffOut.outcome !== 'REVIEW_DIFF') {
    return { escalation: escalate(item.slug, 'review-diff-error', { diffOut }) };
  }
  // temperloop#1970 — read the round counter from the BUMPING fetch only. A
  // relay that drops/garbles the field reads 0, i.e. "first round", which is
  // exactly the pre-#1970 behaviour: a DROPPED or GARBLED field can only ever
  // be MORE permissive, never a bound that fires early on a healthy item.
  //
  // That covers the relay, and ONLY the relay (temperloop#2046). The failure
  // shape it does NOT cover is an INFLATED counter: the marker is corrupted
  // UPSTREAM of the relay, by something other than this driver writing the
  // worktree's `build-review-rounds` file, so the field arrives as a
  // perfectly valid finite number and every check here accepts it. The bound
  // then fires EARLY on a healthy item — the exact case this comment once
  // claimed could not happen, observed live three times when two test cases
  // in test_workflow.sh ran the real review-diff pipeline against the repo
  // root with the bumping default and drove a fresh worktree's counter to 8
  // and 16 against a max of 3. Nothing here can distinguish an inflated count
  // from a genuine one, so the invariant is enforced at the WRITE side
  // instead: that suite now carries a structural + behavioural guard
  // (its "#2046" checks) that no test run may write this marker at all.
  const priorRounds = Number.isFinite(Number(diffOut.review_rounds))
    ? Math.max(0, Math.floor(Number(diffOut.review_rounds)))
    : 0;
  const round = priorRounds + 1;
  let files = Array.isArray(diffOut.files) ? diffOut.files : [];
  // temperloop#2020 — set (not returned from) the gap arm below, so a degraded
  // relay falls THROUGH to the routing decision with only the table-dependent
  // axes withdrawn. See the arm's own comment for why an early return here was
  // wrong.
  let routingDegraded = null;
  let degradedSkip = null;
  // temperloop#1976: a dropped/truncated tsv relay is nondeterministic per
  // copy (the same command, re-run, has been observed to carry it intact) —
  // re-run the SAME diff-fetch command once before treating it as a genuine
  // failure, so determineReviewers() is never called with an empty table for
  // a worktree that actually ships a real one. The re-fetch is NON-BUMPING
  // (temperloop#1970): one driver round must advance the round counter once.
  if (!REVIEWER_ROUTING_TSV && reviewDiffTsvGap(diffOut, files)) {
    diffOut = await fetchReviewDiff(stagePhase(STAGE_REVIEW), false);
    if (machineryDenied(diffOut)) {
      return { escalation: await deniedOrQuota(item.slug, { step: 'review-diff', out: diffOut }, wt) };
    }
    if (diffOut.outcome !== 'REVIEW_DIFF') {
      return { escalation: escalate(item.slug, 'review-diff-error', { diffOut }) };
    }
    files = Array.isArray(diffOut.files) ? diffOut.files : [];
    const gap = reviewDiffTsvGap(diffOut, files);
    if (gap) {
      // temperloop#2020 — DEGRADE, never halt. Before this item a persistent
      // gap escalated `review-diff-error`, and that disposition was the
      // reported harm, not the drop: by the time §3e runs the worker has
      // ALREADY COMMITTED (3c) and passed acceptance (3d), so escalating here
      // stops a drive whose work is complete, for the sake of an ADVISORY pass
      // that is explicitly never a `checks` gate (build.md §3e). On
      // Towheads/foundation at kernel v0.39.0 (run wf_967c2878-0a7, driving
      // foundation#1869) that cost 515 verified lines: the item escalated
      // committed-but-un-PR'd, and /fix's escalation-park path removed the
      // worktree and its local `build/` branch.
      //
      // The DETECTORS are untouched — the row/checksum gap check and the
      // one-shot retry above both still run, and this arm is reached only
      // after both have fired. What changed is what happens next: the
      // TABLE-DEPENDENT part of the routing decision cannot be made (routing
      // off a missing/partial table is the #1976/#1982 silent-misroute this
      // whole mechanism exists to prevent), so the extension axis and the
      // prose-`*.md` fallback are withdrawn and that is said out loud — never
      // implied by silence. The notice is a mode-2 `skipped — …` line per
      // `claude/message-schema.md` § Degradation notice, carried into the PR
      // body by reviewBodySuffix() exactly like every other skip notice, so a
      // cold reader of the PR sees which part of §3e did not route rather than
      // reading a thin review section as a clean pass.
      //
      // NOT a return (temperloop#2020 round 2). Returning here conflated "the
      // extension-axis table is broken" with "no route can be determined" and
      // silently dropped the one route that never needed the table: the
      // MANDATORY command-doc rule (foundation#1007) is computed purely from
      // `files`, the field that relays reliably, and fires regardless of any
      // tsv row. A `claude/commands/*.md` diff whose relay dropped would then
      // have reported `mandatory_ok: true` with workflow-reviewer never run —
      // byte-identical to a clean pass, i.e. the K.49/foundation#164 silent-skip
      // class reintroduced through this very fallback. So the arm now falls
      // THROUGH with `tableAvailable: false`: every table-independent route
      // still runs, and `mandatory_ok` is computed from real routes again.
      //
      // Deliberately NOT the remedy-bearing variant: that one clause is
      // sanctioned only for a subagent that ships as source under
      // claude/agents/ and is merely uninstalled. This is a relay fault with
      // no in-the-moment operator fix, so it takes the bare default shape.
      const note =
        'skipped — §3e extension-axis reviewer routing unavailable (reviewer-routing.tsv did not ' +
        'survive the machinery relay; only table-independent routes were resolved for this diff)';
      log(`[${item.slug}] §3e review — ${note} ${JSON.stringify(gap)}`);
      routingDegraded = gap;
      // `mandatory: false` is a statement about this ENTRY, not about the
      // item: this entry records the withdrawn TABLE-DEPENDENT axes, none of
      // which can ever be the foundation#1007 mandatory rule. The mandatory
      // rule is routed for real below and carries its own `mandatory: true`
      // into `ran`/`skipped`, so reviewTally()'s `mandatory_ok` reflects
      // whether workflow-reviewer actually ran — it is no longer a claim this
      // arm makes on its behalf.
      degradedSkip = { reviewer: '(routing)', note, mandatory: false };
    }
  }
  // The orchestrator-supplied table wins outright when present (#1982); the
  // relayed table (`tsv_lines`, or the legacy `tsv` scalar — reviewDiffTsvText
  // normalizes both) is the legacy path, kept for an un-migrated caller.
  const tsvText = REVIEWER_ROUTING_TSV || reviewDiffTsvText(diffOut) || '';
  const routes = determineReviewers(item, files, tsvText, { tableAvailable: !routingDegraded });
  if (routes.length === 0) {
    return {
      summary: degradedSkip ? degradedSkip.note : '',
      notes: '',
      sections: [],
      blocking: [],
      ran: [],
      skipped: degradedSkip ? [degradedSkip] : [],
      round,
      ...(routingDegraded ? { routing_degraded: routingDegraded } : {}),
    };
  }

  const ran = [];
  // Seeded, not appended: the degradation notice must reach the PR body and
  // the Step 6 tally whether or not any table-independent route then ran.
  const skipped = degradedSkip ? [degradedSkip] : [];
  const blocking = [];
  // sections — the STRUCTURED per-reviewer findings ({ reviewer, text }, ran
  // order), alongside the pre-joined `notes` string (temperloop#1846). The
  // structure is what lets reviewBodySuffix() relabel a CI-fix round's block
  // (`### <reviewer> (ci-fix round N)`) without regex surgery on reviewer
  // text that may itself contain `### ` lines.
  const sections = [];
  // temperloop#2003 — SPAWN EVERY ROUTED REVIEWER FIRST, then wait on the set
  // under one wall-clock ceiling. Before this the pass awaited each reviewer in
  // turn, so a single agent that never returned kept every LATER one from
  // launching at all: in the observed incident the mandatory `workflow-reviewer`
  // for a `claude/commands/*.md` diff was never spawned, because the reviewer
  // ahead of it in the loop hung. Spawning is synchronous and in route order, so
  // the call ORDER (what the journal and a resume's cached prefix key on) and
  // the per-reviewer result ORDER are both byte-identical to the old loop's.
  const slots = routes.map((route) => {
    const slot = { route, done: false, value: undefined, error: undefined };
    // No `schema` — a plain read-only advisory pass, not a machine-validated
    // verdict (build.md §3e: "docs-reviewer is advisory only ... never a
    // checks gate entry"). Deliberately no `model` override either: the
    // reviewer's OWN agent definition sets its tier (e.g.
    // claude/agents/workflow-reviewer.md declares `model: sonnet`).
    //
    // The two-arm `.then` is the settlement RECORDER, not error handling: it
    // makes each reviewer's own outcome readable WITHOUT awaiting it, which is
    // what lets the ceiling below keep every settled reviewer's findings while
    // abandoning only the unsettled ones. It also means a rejected reviewer
    // promise is always handled, so a reviewer that throws after the ceiling has
    // passed can never surface as an unhandled rejection.
    slot.promise = agent(reviewPrompt(item, wt, route, files), {
      // `#<reviewer>` (not `:<reviewer>`) matches the label grammar every
      // other multi-part label in this file already uses (e.g.
      // `ci-batch:<slug>#<n>`) — the slug is always the run of characters up
      // to the first `#`, never a second `:`-delimited segment.
      label: `review:${item.slug}#${route.reviewer}`,
      phase: stagePhase(STAGE_REVIEW),
      agentType: route.reviewer,
    }).then(
      (v) => { slot.done = true; slot.value = v; },
      (e) => { slot.done = true; slot.error = e; },
    );
    return slot;
  });
  const waitedSecs = await awaitReviewFanout(item, slots);
  // temperloop#2032 — THE LAST-CHANCE READ, and the reason the disposition
  // below is three passes rather than one loop. `slot.done` is set by the
  // settlement recorder attached at the spawn above, which runs as a MICROTASK
  // on the reviewer's own promise — so the ceiling's race can return with a
  // reviewer whose result has ALREADY arrived but whose recorder has not run
  // yet. The pre-#2032 loop read `!slot.done` exactly once, immediately after
  // that await, and never again: such a reviewer was reported
  // `skipped — exceeded the §3e review ceiling` while its full review sat in
  // hand, unread. That is not a hang — the result ARRIVES and is thrown away
  // (run wf_c71d1576-e9d discarded two complete reviews that way, one of which
  // had already found the defect a hand-routed reviewer re-found later and
  // PR #2039 then fixed).
  //
  // The ceiling is NOT at fault and is untouched: it still bounds how long the
  // pass WAITS, and this changes only what happens to a result that arrives
  // anyway. Every read below is therefore as late as it can HONESTLY be —
  // bounded settlement drains only (no wall clock, no timer spawn, and never a
  // re-spawn of a reviewer whose result is already in hand), never a second
  // wait: re-introducing one would be exactly the unbounded stall
  // temperloop#2003 removed.
  await drainReviewSettlements(slots);

  // Pass 1 — consume every reviewer that has settled. disposeReviewSlot() is
  // PURE: it returns a descriptor and writes nothing, so a straggler can be
  // re-read afterwards without the tally having been half-written out of route
  // order in the meantime.
  const dispositions = slots.map((slot) => (slot.done ? disposeReviewSlot(slot) : null));
  // Pass 2 — the stragglers get the settlement turns pass 1 just spent.
  if (dispositions.some((d) => d === null)) {
    await drainReviewSettlements(slots);
    for (let i = 0; i < slots.length; i++) {
      if (dispositions[i] === null && slots[i].done) dispositions[i] = disposeReviewSlot(slots[i]);
    }
  }

  // Pass 3 — apply the dispositions in ROUTE order, so `ran`/`skipped`/
  // `sections` and the log lines keep the ordering the single loop produced. A
  // straggler is read ONE final time here, at the instant its skip would be
  // written: that read, not the one after the await, is what decides a timeout.
  // Exactly one disposition is written per slot, which is what keeps `ran` and
  // `skipped` disjoint by construction — a recovered reviewer can never also
  // appear as `timed_out`, and `mandatory_ok` (derived from `skipped`) reports
  // what actually happened rather than what the ceiling guessed.
  for (let i = 0; i < slots.length; i++) {
    const slot = slots[i];
    const route = slot.route;
    const disposition = dispositions[i] ?? (slot.done ? disposeReviewSlot(slot) : null);
    if (disposition === null) {
      // temperloop#2003 — the CEILING BREACH. This reviewer is abandoned, never
      // killed: the runtime offers no cancellation, so the promise is simply
      // never awaited again and the pass proceeds. The note names the cause, so
      // an operator reading the PR body sees a bounded outcome rather than the
      // silence the incident actually produced. Disposition splits
      // mandatory-vs-advisory below: this is the ADVISORY half (a degraded
      // notice + a `mandatory_ok`-preserving tally entry); a MANDATORY route
      // additionally ESCALATES after the loop.
      //
      // TEMPERLOOP#2064 — WHY THIS LINE NO LONGER SAYS "unavailable". It used to,
      // to match the documented `skipped — <agent> unavailable` shape
      // (CLAUDE.kernel.md § Subagent usage, legible agent-gate degradation) —
      // but in that rule `unavailable` is the CAPABILITY-PROBE verdict: the
      // agent is not declared in `CLAUDE.md § Subagents` or `.claude/agents/`,
      // so it could not be spawned at all. A ceiling breach is the OPPOSITE
      // fact: the agent IS installed and WAS spawned, and did not return in
      // time. Conflating them sent the #2064 investigator at the agent roster
      // while the defect sat one layer below, in the timer — and cost a live
      // session ~1200s of apparent hang. disposeReviewSlot() still emits the
      // true capability-probe form for the real thing (an agent-resolution
      // failure), so the two senses now carry two distinct wordings, which is
      // what makes either of them diagnostic. The duration reported is the tick
      // this pass actually HONOURED, never the nominal ceiling: when those two
      // numbers disagree, that gap IS the bug (#2064 measured 41s against 1200s).
      const note =
        `skipped — ${route.reviewer} timed out after ${waitedSecs}s ` +
        `(the §3e review ceiling of ${REVIEW_AGENT_CEILING_SECS}s — temperloop#2003; the agent is ` +
        `installed and was spawned, it did not return in time)`;
      log(`[${item.slug}] §3e review — ${note}`);
      // `timed_out` distinguishes this from the other three skip reasons for a
      // reader of the parked tally; `mandatory` is what drives mandatory_ok, so
      // the tally reflects reality here exactly as it does on every other skip.
      skipped.push({ reviewer: route.reviewer, note, mandatory: route.mandatory, timed_out: true });
      continue;
    }
    if (disposition.kind === 'skip') {
      log(`[${item.slug}] §3e review — ${disposition.note}`);
      skipped.push({ reviewer: route.reviewer, note: disposition.note, mandatory: route.mandatory });
      continue;
    }
    // EXHAUSTIVE on purpose. `disposeReviewSlot()` returns exactly two shapes
    // today, and falling through on anything else would launder a future third
    // kind into `ran` with an `undefined` .text — a reviewer reported as having
    // run, carrying no findings, which is the same reads-like-a-clean-pass
    // failure this whole item exists to end. Fail loudly instead.
    if (disposition.kind !== 'ran') {
      throw new Error(
        `§3e disposition for ${route.reviewer} has unknown kind ${JSON.stringify(disposition.kind)} — ` +
          'disposeReviewSlot() grew a shape this loop does not handle',
      );
    }
    const textStr = disposition.text;
    ran.push({ reviewer: route.reviewer, mandatory: route.mandatory });
    log(`[${item.slug}] §3e review — ${route.reviewer} ran (${route.reasons.join('; ')})`);
    // temperloop#1450 — keep the FULL text, not just the name: a MEDIUM/LOW-only
    // review is still real advisory output and must not evaporate once the HIGH
    // check below has read it.
    sections.push({ reviewer: route.reviewer, text: textStr });
    if (reviewHasBlockingFinding(textStr)) {
      blocking.push({ reviewer: route.reviewer, findings: textStr });
    }
  }

  const parts = [];
  if (ran.length) parts.push(`§3e review — ran: ${ran.map((r) => r.reviewer).join(', ')}`);
  if (skipped.length) parts.push(skipped.map((s) => s.note).join('; '));
  const result = {
    summary: parts.join(' · '),
    notes: sections.map((s) => `### ${s.reviewer}\n${s.text}`).join('\n\n'),
    sections,
    blocking,
    ran,
    skipped,
    round,
    ...(routingDegraded ? { routing_degraded: routingDegraded } : {}),
  };
  // temperloop#2003 — the MANDATORY half of the timeout disposition. An advisory
  // reviewer that timed out has already degraded to a legible skip notice above
  // and the item carries on; a MANDATORY route (foundation#1007's command-doc
  // rule) must never read as if its gate passed, so it escalates instead. The
  // payload carries the FULL tally — `mandatory_ok` computed, not left
  // unevaluated — which is precisely what the incident lacked: the pass never
  // resolved, so nothing ever reported that the mandatory reviewer had not run.
  const timedOut = skipped.filter((s) => s.timed_out);
  const mandatoryTimedOut = timedOut.filter((s) => s.mandatory);
  if (mandatoryTimedOut.length > 0) {
    log(
      `[${item.slug}] §3e review — MANDATORY reviewer(s) ` +
        `${mandatoryTimedOut.map((s) => s.reviewer).join(', ')} timed out after ${waitedSecs}s ` +
        `(the ${REVIEW_AGENT_CEILING_SECS}s review ceiling) — escalating (temperloop#2003)`,
    );
    result.escalation = escalate(item.slug, 'review-agent-timeout', {
      ceiling_secs: REVIEW_AGENT_CEILING_SECS,
      // temperloop#2064 — the tick actually honoured. A `waited_secs` far below
      // `ceiling_secs` in an escalation payload IS the timer defect, reported
      // without anyone having to correlate agent transcripts by hand.
      waited_secs: waitedSecs,
      slow_secs: REVIEW_AGENT_SLOW_SECS,
      mandatory: mandatoryTimedOut.map((s) => s.reviewer),
      timed_out: timedOut.map((s) => s.reviewer),
      review: reviewTally(result),
      round,
      remedy:
        'the mandatory §3e reviewer did not return within the ceiling — re-drive the item, ' +
        'or raise BUILD_REVIEW_AGENT_CEILING_SECS only if this review is legitimately this slow',
    });
  }
  return result;
}

// disposeReviewSlot — the verdict for ONE SETTLED reviewer slot, as a pure
// descriptor: `{ kind: 'ran', text }` or `{ kind: 'skip', note }`. Purity is the
// point (temperloop#2032): runReviewers reads its slots in more than one pass so
// a reviewer that settles late is still consumed, and a disposition step that
// pushed straight into `ran`/`skipped`/`sections` would emit those in
// settlement order instead of route order. The caller writes exactly one
// disposition per slot, in route order, which is what keeps `ran` and `skipped`
// disjoint. Never call it on an unsettled slot — `slot.done` is the caller's
// precondition, and the caller re-reads it as late as it possibly can.
function disposeReviewSlot(slot) {
  const route = slot.route;
  if (slot.error) {
    const err = slot.error;
    const msg = String((err && err.message) || err);
    // Reuse machineryAgent's own resolution-failure detection (temperloop#1014)
    // as the precedent — the SAME two markers of "agent() could not resolve
    // this agentType at all", never a broader catch. This is what makes the
    // skip notice fire on GENUINE unavailability only, never as a guaranteed
    // default.
    if (MACHINERY_RESOLUTION_ERR.test(msg)) {
      // Every reviewer this repo names (the tsv's own agent-catalog-path
      // column; workflow-reviewer/docs-reviewer/architecture-reviewer/
      // requirements-auditor) ships as source under claude/agents/ — so the
      // remedy-bearing form (message-schema.md § Degradation notice's one
      // sanctioned mode-2 variant) always applies here, never the bare form.
      return {
        kind: 'skip',
        note: `skipped — ${route.reviewer} available as source; run workflows/scripts/install/project-agents.sh to enable`,
      };
    }
    // A genuine (non-resolution) error is not evidence the capability is
    // unavailable, but review is advisory (never a `checks` gate) — degrade
    // rather than take the whole item down over an LLM-judgment pass.
    return { kind: 'skip', note: `skipped — ${route.reviewer} errored (${msg})` };
  }
  if (slot.value == null) {
    return { kind: 'skip', note: `skipped — ${route.reviewer} returned no verdict (skip/transient)` };
  }
  return { kind: 'ran', text: String(slot.value) };
}

// REVIEW_SETTLE_DRAIN_TICKS — how many settlement turns a drain yields before
// giving up. A tick is one microtask (`await null`), never a wall-clock wait:
// under-draining can only cost one extra timer spawn (before the ceiling) or
// one reviewer left unrecovered (after it), never a wrong verdict, and
// over-draining costs nothing but empty turns.
const REVIEW_SETTLE_DRAIN_TICKS = 16;

// drainReviewSettlements — give every reviewer whose promise has already
// resolved the chance to RECORD that fact, then return. `slot.done` is set in a
// `.then` recorder, so a reviewer can be resolved-but-unrecorded for a few
// microtasks; this is the only honest way to read the fanout later than the
// instant an await hands back, and it is bounded by construction (no clock, no
// spawn, no wait). Used twice: before the ceiling's first timer spawn (a pure
// cost optimisation — a reviewer that already returned need not be paid for),
// and again by the disposition passes (temperloop#2032 — a reviewer that
// settled after the ceiling must not be reported as a timeout).
async function drainReviewSettlements(slots) {
  for (let i = 0; i < REVIEW_SETTLE_DRAIN_TICKS; i++) {
    if (slots.every((s) => s.done)) return;
    await null;
  }
}

// awaitReviewFanout — temperloop#2003's ceiling, applied to the whole §3e
// fanout. Returns once every reviewer has settled OR the ceiling elapses,
// whichever comes first; it never rejects and never throws, and the caller reads
// each slot's own `done` flag to decide the per-reviewer disposition.
//
// RETURNS the seconds of wall clock this pass ACTUALLY waited — the sum of the
// slices whose ticks were honoured, never the nominal ceiling (temperloop#2064).
// That number is the `<actual>` the ceiling-breach notice reports, so a reader
// of the notice is told what was measured rather than what was budgeted: the
// #2064 incident is precisely a run whose two numbers differed by ~30x while
// only the budgeted one was ever printed.
//
// HOW IT MEASURES TIME WITHOUT A CLOCK. `Date.now()` throws in this runtime and
// there is no timer primitive, so the wait is raced against something that
// resolves ON a clock: reviewWaitAgent(), a machinery executor whose entire job
// is one `sleep`. Each slice is a separate spawn, so the elapsed total is the
// sum of the slices that have RETURNED — an accounting this file can do with
// integers alone.
//
// FAIL-OPEN, DELIBERATELY. If the timer itself cannot run (the auto-mode safety
// classifier denies it, the executor returns something else), the bound is
// simply unavailable and we fall back to the pre-#2003 behaviour — await the
// fanout — with a legible notice. A timer that resolved without actually
// sleeping would otherwise manufacture an INSTANT false ceiling breach on
// perfectly healthy reviews, which is far worse than the stall it bounds
// (kernel principle 7: advisory over enforced discipline).
async function awaitReviewFanout(item, slots) {
  const allSettled = Promise.all(slots.map((s) => s.promise));
  const pending = () => slots.filter((s) => !s.done);
  // Drain already-resolved reviewer promises before paying for a timer spawn: a
  // reviewer that has ALREADY returned is only pending as a MICROTASK here
  // (spawning is synchronous). Pure cost optimisation — under-draining can only
  // cost one extra timer spawn, never a wrong verdict, because the race below
  // resolves immediately on a settled fanout either way. Shares the one drain
  // helper with the post-ceiling disposition read (temperloop#2032), so the two
  // reads of the same slot state cannot drift apart.
  await drainReviewSettlements(slots);

  let waited = 0;
  let slowLogged = false;
  for (const slice of reviewWaitSlices()) {
    if (pending().length === 0) return waited;
    const tick = await Promise.race([
      allSettled.then(() => 'SETTLED'),
      reviewWaitAgent(item, slice, waited + slice),
    ]);
    if (tick === 'SETTLED' || pending().length === 0) return waited;
    if (tick !== 'REVIEW_WAIT_ELAPSED') {
      // temperloop#2064 — name the REFUSAL case explicitly. "The timer is
      // unavailable" is true of every unusable tick, but a permission control
      // refusing the wait command is the one shape an operator can actually act
      // on, and the one that silently collapsed the ceiling before this split.
      const blocked = /^timer-blocked/.test(String(tick));
      log(
        `[${item.slug}] §3e review — the wall-clock timer is unavailable (${tick}); ` +
          (blocked
            ? 'a harness permission control REFUSED the wait command, so NO time was waited and ' +
              'the ceiling is not applied (temperloop#2064); '
            : '') +
          `waiting on the fanout unbounded, as before temperloop#2003`,
      );
      await allSettled;
      return waited;
    }
    waited += slice;
    if (pending().length === 0) return waited;
    if (!slowLogged && REVIEW_AGENT_SLOW_SECS > 0 && waited >= REVIEW_AGENT_SLOW_SECS) {
      slowLogged = true;
      // The OBSERVABILITY half (mirrors #1071's STEP_SLOW notice): a long review
      // becomes visible here, well before the ceiling gives up on it.
      log(
        `[${item.slug}] §3e review — still running after ${waited}s: ` +
          `${pending().map((s) => s.route.reviewer).join(', ')} ` +
          `(ceiling ${REVIEW_AGENT_CEILING_SECS}s). Raise BUILD_REVIEW_AGENT_CEILING_SECS ` +
          `if this review is legitimately this slow.`,
      );
    }
  }
  log(
    `[${item.slug}] §3e review — wall-clock ceiling of ${REVIEW_AGENT_CEILING_SECS}s reached with ` +
      `${pending().map((s) => s.route.reviewer).join(', ')} still outstanding ` +
      `(${waited}s of tick actually honoured — temperloop#2003, temperloop#2064)`,
  );
  return waited;
}

// reviewWaitAgent — the wall-clock TICK this runtime does not otherwise have.
// One machinery executor, one `review-wait.sh <secs>` call, one closed outcome.
// Resolves to 'REVIEW_WAIT_ELAPSED' ONLY when the interval genuinely elapsed,
// and to a `timer-*` string otherwise — which the caller reads as "no usable
// timer" and fails open on.
//
// TEMPERLOOP#2049 — WHY THE COMMAND IS A SCRIPT AND WHY THE RETURN IS CHECKED.
// This was an inline `sleep <secs>; printf '<json>'` Bash command, and the
// prompt told the executor to report the interval elapsed if the command never
// printed. In the machinery executor's seat that command shape is REFUSED by a
// harness permission control ("Blocked: sleep 300 followed by: printf …") in a
// millisecond — so the executor took that sanctioned escape and reported an
// elapse that had not happened. Measured in run wf_ebd4b5e0-3a8's own agent
// transcripts: three slices asking 300s/540s/360s returned in 8s/9s/9s, so the
// nominal 1200s ceiling realized in ~30s of wall clock, while the two reviewers
// it was bounding completed normally at 177s and 257s. Nothing was slow — the
// CEILING was ~40x fast, which is why three consecutive items reported
// `ran: []` with every routed reviewer "timed out".
//
// Two changes, and BOTH are load-bearing:
//   1. THE WAIT IS REAL. The command is now the named project helper
//      workflows/scripts/build/review-wait.sh, whose deadline loop runs inside
//      a script — the same shape ci-poll.sh already uses and which the same
//      machinery seat observably honours (that run's ci-batch executor held one
//      Bash call open for 280 real seconds).
//   2. THE RETURN IS NOT TAKEN ON TRUST. An elapse is honoured only when it
//      carries `realized_secs` — the script's OWN measurement, printed only
//      after the wait — and that value reaches the interval asked for. The
//      prompt no longer sanctions reporting an elapse the command did not
//      produce; a refused or errored command is REVIEW_WAIT_UNAVAILABLE, a
//      pure observation, and the caller fails open on it loudly. Without (2),
//      any future permission-control change silently re-breaks the ceiling in
//      exactly this way and nothing reports it (kernel principle 5 — counter a
//      known AI failure mode STRUCTURALLY, not with "be careful").
// A tool timeout stays honoured as elapsed: its budget is secs+60s, so it can
// only fire AFTER the interval. That is an observation too, and gets its own
// outcome rather than being folded into a guess.
//
// TEMPERLOOP#2064 — THE THIRD CHANGE: A BLOCK IS NOT A TIMEOUT. (2) above still
// left one coin flip standing. A permission BLOCK and a Bash-tool TIMEOUT kill
// are the same observation to the executor — no JSON line — and the tool-timeout
// arm is PERMISSIVE. Asked to label a state it cannot see, the executor picked
// the permissive one: measured in run wf_1b4c373b-8c1, slices asking
// 300s/540s/360s returned in 11s/11s/17s, a 1200s ceiling realized in ~41s, and
// a docs-reviewer that returned a full clean review at 98s was discarded — the
// item then reported `skipped — docs-reviewer unavailable`, sending the next
// investigator at the AGENT ROSTER rather than at the timer. So: REVIEW_WAIT_
// BLOCKED is its own outcome, the refusal is classified from the harness's OWN
// text before any label is read (REVIEW_WAIT_REFUSAL_RE), and the ceiling-breach
// notice says `timed out after <actual>s` — reserving `unavailable` for the
// kernel's capability-probe sense (CLAUDE.kernel.md § Subagent usage).
//
// Deliberately NOT runMachinery(): that path batches its steps and wraps them
// in the #1071 watchdog, whose own ceiling would then race this one. A timer
// needs neither.
async function reviewWaitAgent(item, secs, mark) {
  const waitBin = machineryBin(input.repoRoot, 'review-wait.sh');
  const cmd = `${waitBin} ${sq(secs)}`;
  const promptFor = (lean) =>
    [
      'Run ONE project helper script that waits for a fixed interval, and report what it printed.',
      'This is a TIMER, not a build step: it inspects nothing and changes nothing.',
      'Run this single command with the Bash tool, exactly as written — do not add flags, chain',
      'extra commands, substitute a `sleep`, or shorten the interval.',
      `Set the Bash tool \`timeout\` parameter to ${Math.min(AGENT_BASH_CAP_MS, secs * 1000 + 60_000)}.`,
      lean ? null : 'The command prints a SINGLE JSON line on stdout once the interval has elapsed;'
        + ' return that object verbatim as your result.',
      '`realized_secs` is the script\'s OWN measurement of how long it waited. Report only the'
        + ' number the command actually printed — NEVER a number you inferred, and never the'
        + ' interval that was requested.',
      'If a permission control REFUSED or BLOCKED the command — a `<tool_use_error>Blocked: …`'
        + ' result, or any other refusal — do NOT guess, do NOT re-run it, do NOT substitute a'
        + ' different wait, and do NOT report the interval as elapsed. Return'
        + ' {"outcome":"REVIEW_WAIT_BLOCKED","refusal_text":"<the FIRST LINE of the refusal,'
        + ' copied VERBATIM>"}. No time passed. A block is NOT a timeout: reporting one as the'
        + ' other makes a review ceiling fire ~30x early and throw away finished reviews'
        + ' (temperloop#2049, temperloop#2064).',
      'If the command failed for any OTHER reason — it errored, the helper was missing — return'
        + ' {"outcome":"REVIEW_WAIT_UNAVAILABLE","error":"<the FIRST LINE of the error, VERBATIM>"}.'
        + ' No time passed here either.',
      'If instead the Bash tool\'s OWN timeout killed the command WHILE IT WAS RUNNING, return'
        + ' exactly {"outcome":"REVIEW_WAIT_TOOL_TIMEOUT"} — that budget is longer than the interval,'
        + ' so the interval did elapse. Use this ONLY for a command that actually ran and was then'
        + ' killed: never for one that was refused before it started. If you cannot tell the two'
        + ' apart, you were BLOCKED — say so and quote the text.',
      '',
      'Command:',
      cmd,
    ].filter(Boolean).join('\n');
  let out;
  try {
    out = await machineryAgent(promptFor, {
      label: `review-wait:${item.slug}#${mark}`,
      phase: stagePhase(STAGE_REVIEW),
      model: input.machinerySoloModel || 'haiku',
      schema: SPINE_OUTCOME_SCHEMA,
    });
  } catch (err) {
    return `timer-error: ${String((err && err.message) || err)}`;
  }
  if (machineryDenied(out)) return 'timer-denied';
  // THE #2064 CHECK, and it runs FIRST — before any outcome label is read. A
  // refusal is recognised from the harness's own words (REVIEW_WAIT_REFUSAL_RE),
  // so a block the executor mislabelled REVIEW_WAIT_TOOL_TIMEOUT — the
  // permissive arm, and the label #2064 actually observed it choosing — cannot
  // reach that arm. Fails CLOSED: "no usable timer", never "the interval
  // elapsed". Ordering is the whole mechanism; moving this below the label
  // branches restores the defect exactly.
  const refusal = reviewWaitRefusalText(out);
  if (refusal) return `timer-blocked: ${refusal}`;
  if (out.outcome === 'REVIEW_WAIT_BLOCKED') {
    return 'timer-blocked: a harness permission control refused the wait command';
  }
  // The tool-timeout arm: an observation, honoured as elapsed (budget > interval).
  // Reachable ONLY past the refusal check above — that is what keeps it honest.
  if (out.outcome === 'REVIEW_WAIT_TOOL_TIMEOUT') return 'REVIEW_WAIT_ELAPSED';
  if (out.outcome !== 'REVIEW_WAIT_ELAPSED') return `timer-outcome:${out.outcome}`;
  // THE #2049 CHECK. An elapse is a claim about wall clock, and this runtime has
  // no clock to audit it with — so the audit is the script's own measurement,
  // which only a completed run can produce. `Number('')`/`Number(undefined)` are
  // 0/NaN and both fail the comparison, so an absent field fails CLOSED (to
  // "no usable timer" → fail open on the fanout), never open into a false breach.
  const realized = Number(out.realized_secs);
  if (!(realized >= secs)) return `timer-unrealized:${out.realized_secs ?? 'absent'}`;
  return 'REVIEW_WAIT_ELAPSED';
}

// reviewBoundReached(review) — the §3e convergence bound's ONE predicate
// (temperloop#1970), so both blocking call sites (the 3e pass and §3g's CI-fix
// re-review) ask the identical question and cannot drift apart. True when this
// round has blocking findings AND the item has spent its budget of review
// rounds: past that, the findings are CARRIED (PR body + parked tally) instead
// of escalating for another build-review round-trip. `review.round` is absent
// only on a return shape older than this item; `?? 1` then reads "first round",
// which can never trip the bound early.
function reviewBoundReached(review) {
  return review.blocking.length > 0 && (review.round ?? 1) >= REVIEW_BLOCKING_MAX_ROUNDS;
}

// REVIEW_BLOCK_MARK — the EXPLICIT, machine-readable boundary of one reviewer's
// block inside `## Review notes` (temperloop#2009 review round 2).
//
// The `### <reviewer>` heading below is for a HUMAN. It is not a parseable
// boundary and never was: reviewBodySuffix splices `sec.text` VERBATIM, and a
// reviewer's own findings text carries `### ` headings of its own (ADR 0007's
// `### [HIGH] <name> in <file>`) plus free prose headings — a single-word
// `### Notes` is indistinguishable from `### docs-reviewer` by shape alone, and
// a fenced code block can contain literally anything. pr.sh's PR-body cap has to
// know where one round's prose ends to drop the OLDEST rounds first, and two
// successive passes at inferring that from Markdown were both spoofable by
// ordinary reviewer prose (the second dropped the NEWEST round's residual HIGH
// findings — precisely what temperloop#1970 routes into this section for the
// human at the merge gate).
//
// So the PRODUCER marks its own blocks. An HTML comment renders as nothing on
// GitHub, is anchored at line start, and carries the two facts the consumer
// needs (which reviewer, which round) as attributes rather than as prose to be
// re-derived. `sec.text` is neutralized before splicing, so a reviewer QUOTING
// this very design — entirely likely, since one already did — cannot inject a
// boundary. Consumer: review_notes() in workflows/scripts/build/pr.sh, which
// matches this token exactly, at line start, and never guesses from a heading.
// The two literals are kept in lockstep by a static guard in test_pr.sh.
const REVIEW_BLOCK_MARK = '3e-review-block';
// Matches an opening comment whose first token is the mark and that has not
// already been neutralized, so re-neutralizing is idempotent rather than
// accreting `-quoted` suffixes.
const REVIEW_BLOCK_MARK_RE = new RegExp(`<!--(\\s*)${REVIEW_BLOCK_MARK}(?!-quoted)`, 'g');

// One block's opening delimiter. The reviewer name is reduced to the block
// grammar's own character set so it can never close the comment early or break
// the attribute quoting; `round` is 0 for the original 3f pass and N for
// ciPollLoop's Nth CI-fix re-review, matching the `(ci-fix round N)` label.
function reviewBlockMarker(reviewer, round) {
  const name = String(reviewer ?? '').replace(/[^A-Za-z0-9_.-]/g, '-') || 'unknown';
  const n = Number.isFinite(Number(round)) ? Math.max(0, Math.trunc(Number(round))) : 0;
  return `<!-- ${REVIEW_BLOCK_MARK} reviewer="${name}" round="${n}" -->`;
}

// Strip the block delimiter's power out of text that is about to be spliced
// verbatim. The mark is kept legible (a human reading the PR still sees what the
// reviewer wrote) but can no longer match the consumer's token.
function neutralizeReviewBlockMark(text) {
  return String(text ?? '').replace(REVIEW_BLOCK_MARK_RE, `<!--$1${REVIEW_BLOCK_MARK}-quoted`);
}

// reviewBodySuffix — the ONE renderer of §3e evidence into the PR body
// (temperloop#1846), across EVERY round handed to it: rounds[0] is the
// original 3f pass, rounds[1..] are ciPollLoop's CI-fix re-reviews. Before
// this, the body suffix was built from rounds[0] alone while park()'s tally
// merged every round — so a reviewer that ran only in a CI-fix round (its
// diff includes the fix commit, which can touch file classes the original
// diff never did) had its findings affirmatively OMITTED from the body's
// "ran:" line and ## Review notes, the exact #1846 failure (body said
// "ran: docs-reviewer" while review.ran carried shell-reviewer and its three
// findings). Rendering rules:
//   - the "ran:" line names every DISTINCT reviewer across all rounds — a
//     name-set union, so it can never be a subset of the tally's review.ran;
//   - every round's findings section is spliced, none de-duped away: a
//     CI-fix round's block is relabeled `### <reviewer> (ci-fix round N)` so
//     a reviewer that ran in two rounds keeps BOTH blocks, distinguishable;
//   - skip notices are de-duped by their full note text only (byte-identical
//     notices from re-running the same degraded route add no information);
//   - each block opens with a REVIEW_BLOCK_MARK delimiter line (above) that
//     names its reviewer and round, so the PR-body cap can find block edges
//     without parsing Markdown out of reviewer prose.
// For a single round this renders the pre-#1846 shape plus those delimiters.
function reviewBodySuffix(rounds) {
  const ranNames = [];
  const skippedNotes = [];
  const sectionParts = [];
  rounds.filter(Boolean).forEach((r, i) => {
    for (const e of r.ran ?? []) {
      if (!ranNames.includes(e.reviewer)) ranNames.push(e.reviewer);
    }
    for (const s of r.skipped ?? []) {
      if (!skippedNotes.includes(s.note)) skippedNotes.push(s.note);
    }
    for (const sec of r.sections ?? []) {
      const heading = i === 0 ? sec.reviewer : `${sec.reviewer} (ci-fix round ${i})`;
      sectionParts.push(
        `${reviewBlockMarker(sec.reviewer, i)}\n### ${heading}\n${neutralizeReviewBlockMark(sec.text)}`,
      );
    }
  });
  const parts = [];
  if (ranNames.length) parts.push(`§3e review — ran: ${ranNames.join(', ')}`);
  if (skippedNotes.length) parts.push(skippedNotes.join('; '));
  const line = parts.join(' · ');
  return (
    (line ? `\n\n${line}` : '') +
    (sectionParts.length ? `\n\n## Review notes\n${sectionParts.join('\n\n')}` : '')
  );
}

// reviewTally — merge one or more runReviewers() rounds (the original 3e pass
// plus any CI-fix re-review, temperloop#1450) into the ONE summary object
// park() threads through to the orchestrator's Step 6 tally. `mandatory_ok`
// is false iff any SKIPPED entry across every round carried `mandatory: true`
// — i.e. the foundation#1007 command-doc rule was genuinely degraded at least
// once, never merely "some optional reviewer wasn't available".
//
// temperloop#1984 — `routed_not_run`, the WEAKER companion field.
// `mandatory: true` is set by determineReviewers() for `workflow-reviewer` on a
// command-doc diff and for nothing else, so EVERY extension-axis route
// (shell-reviewer for `.sh`, typescript-reviewer for `.mjs`, …) could be
// skipped with `mandatory_ok` still reading `true` — a tally that reads fully
// clean while the shell diff went unreviewed (observed live: six unrun §3e
// shell reviews across three items, every one caught by a human reading the
// roster, never by this tally). `routed_not_run` is the distinct set of
// reviewer names the routing RESOLVED but that did not run in the round they
// were routed for — deliberately a VISIBILITY field, not a second gate (ADR
// 0037; kernel principle 7: a hard block here deadlocks legitimate work in a
// consuming checkout where a reviewer agent is genuinely absent, which is the
// ordinary case, not the pathological one). Invariant that closes the hole:
// `routed_not_run` is non-empty exactly when `skipped` is, so the tally can
// never read fully clean while any routed reviewer was skipped. A reviewer
// skipped in one round and run in another stays listed — the skip was real,
// and which round covered which diff is exactly what a reader needs to see.
//
// temperloop#1970 adds `residual_blocking` — the convergence bound's PER-RUN
// EXECUTION SIGNAL (§ Mandatory-step birth rule): one entry per round that hit
// the bound, carrying the round number and the findings that were CARRIED into
// the PR body rather than re-escalated. So an operator reading the Step 6
// summary can see the bound firing, on which items, with what still outstanding
// — never a prose-only declaration that it exists. OMITTED ENTIRELY when no
// round hit the bound, so an ordinary item's parked record stays byte-identical.
function reviewTally(...rounds) {
  const ran = [];
  const skipped = [];
  const residual = [];
  // temperloop#2020 — the gap payload behind a routing degradation, carried
  // into the parked record so the Step 6 tally (and a human reading it) can
  // tell "no reviewer matched this diff" (a legitimate empty roster) from
  // "the routing table never arrived" (a degraded one). The skip notice says
  // it in prose; this says it in a field, with the expected/got figures the
  // #1976/#1982 detectors actually computed.
  let routingDegraded = null;
  for (const r of rounds) {
    if (!r) continue;
    ran.push(...(r.ran ?? []));
    skipped.push(...(r.skipped ?? []));
    if (r.routing_degraded && !routingDegraded) routingDegraded = r.routing_degraded;
    if (r.residualBlocking) {
      residual.push({
        round: r.round ?? null,
        max_rounds: REVIEW_BLOCKING_MAX_ROUNDS,
        findings: r.blocking ?? [],
      });
    }
  }
  return {
    ran,
    skipped,
    mandatory_ok: !skipped.some((s) => s.mandatory),
    routed_not_run: Array.from(new Set(skipped.map((s) => s.reviewer))),
    ...(residual.length > 0 ? { residual_blocking: residual } : {}),
    ...(routingDegraded ? { routing_degraded: routingDegraded } : {}),
  };
}

// --- 3e.6. Class-A activation gate (temperloop#1219) -------------------------
// build.md §3e.6 specifies a synchronous, in-repo ACTIVATION check: an item
// carrying `activation: class: A` has its `proof:` predicate run against the
// worker's worktree BEFORE 3f pushes anything, and a Fail loops back to 3c.
// This driver — the DEFAULT Step-3 path since temperloop#998 — implemented none
// of it, and `activation` was not even in the items[] args contract, so the
// block never crossed the orchestrator→workflow boundary at all. Every gate
// plan.sh rule 14 forces onto a product-source item was therefore inert here:
// an item could merge green with its feature dormant (a runner never
// registered, a flag never flipped, a rule nothing greps for) — exactly the
// failure `Decisions/temperloop - Activation-completeness contract` exists to
// catch. THE PREDICATE IS THE GATE: there is no fallback actor and no skip arm
// (temperloop#1451), so an arriving class-A block with no `proof:` escalates
// rather than degrading to a no-op.
//
// WHY IN driveItem, BETWEEN 3e.5 AND 3f (the issue's candidate 1, chosen):
// running it parent-side after the workflow returns would put it AFTER push and
// PR-open, so a Fail would cost a re-push on an already-open PR instead of a
// loop-back to 3c. The gate's whole value is that it fires before the branch
// leaves the worktree.
//
// BYTE-IDENTICAL FOR EVERYONE ELSE: activationClass() returns '' for an item
// with no `activation` block and 'B'/'C' for a ledger-discharged one, and
// runActivationGate() returns null on the first line in those cases — zero
// agent spawns, zero log lines, zero stage transitions. B/C stay
// ledger-recorded at 4d-epic step 2a (orchestrator-side, off this path).

// activationClass(item) — the item's declared activation class, normalized and
// upper-cased ('' when the item declares no block). Read off the plan-schema
// `activation:` block the orchestrator now passes through (build.md Step 3).
function activationClass(item) {
  const a = item && item.activation;
  if (!a || typeof a !== 'object') return '';
  return String(a.class ?? '').trim().toUpperCase();
}

// isAbsenceProof(proof) — does the predicate ASSERT AN ABSENCE (temperloop#944)?
// build.md §3e.6 / plan-schema § activation define this by shape: the predicate
// "negates its check (opens with `!`)". An absence proof passes trivially
// against a tree where the thing never existed, so it — and only it — needs the
// merge-base control pass below. A PRESENCE proof is false on an untouched tree
// by construction and has nothing to vacuously pass.
function isAbsenceProof(proof) {
  return /^\s*!/.test(String(proof ?? ''));
}

// jsonSafeDetail — shell fragment that reduces "$__out" to a string safe to
// interpolate into a JSON string literal: newlines/tabs to spaces, quotes and
// backslashes deleted, non-printables dropped, tail-truncated. Deliberately no
// jq dependency (the predicate runs in a bare worktree, on any host).
const ACTIVATION_DETAIL_FILTER =
  `__d="$(printf '%s' "$__out" | tr '\\n\\r\\t' '   ' | tr -d '\\\\"' | tr -cd '[:print:]' | tail -c 300)"`;

// activationProofCmd — run the class-A `proof:` predicate from <dir>'s root and
// report Pass/Fail as the predicate's OWN exit code.
//
// THE VERDICT IS READ UN-PIPED, WHICH IS §3e.5'S *PREFERRED* SHAPE, NOT A
// WEAKER ONE (temperloop#68/#801). The predicate runs inside a command
// substitution — not a pipe — so `$?` is already the predicate's own status
// under both bash and zsh, with no PIPESTATUS/pipestatus read to get
// dialect-wrong and no `tee` to swallow it. build.md §3e.5 names exactly this:
// "prefer running the gate un-piped and branching on its exit directly".
//
// DO NOT ADD `set -o pipefail` HERE. It looks like belt-and-suspenders and is
// the opposite: it silently rewrites the meaning of the AUTHOR'S OWN predicate,
// in the one direction that makes this gate theater. `pipefail` reports the
// rightmost NON-ZERO status, and a predicate whose tail exits early on a match
// (`grep -q`, `head`) SIGPIPEs its upstream writer, which dies 141. For the
// wrap-immune ABSENCE idiom plan-schema.md documents
// (`! tr '\n' ' ' < f | tr -s ' ' | grep -q '<phrase>'`) that inverts the
// verdict on the case that matters:
//   phrase PRESENT (must FAIL):  pipefail -> 141 -> `!` -> 0  == false PASS
//                                no pipefail -> 0 -> `!` -> 1 == correct FAIL
// Reproduced deterministically, and asserted by the "pipefail" case in
// test_workflow.sh. `scripts/lint-pipe-grep-q.sh` (temperloop#1050) is the
// tree-wide guard for the same footgun. A false PASS on an absence proof is
// precisely what the temperloop#944 control pass exists to stop, so
// reintroducing it here would defeat the control one layer up.
function activationProofCmd(dir, proof, passOutcome, failOutcome) {
  return [
    `cd ${sq(dir)} || { printf '{"outcome":"%s","detail":"cannot cd to the checkout root"}\\n' ${sq(failOutcome)}; exit 0; }`,
    `__out="$( { ${proof} ; } 2>&1 )"; __rc=$?`,
    ACTIVATION_DETAIL_FILTER,
    `if [ "$__rc" = 0 ]; then printf '{"outcome":"%s","exitCode":0,"detail":"%s"}\\n' ${sq(passOutcome)} "$__d";`,
    `else printf '{"outcome":"%s","exitCode":%s,"detail":"%s"}\\n' ${sq(failOutcome)} "$__rc" "$__d"; fi`,
  ].join('\n');
}

// activationControlCmd — the temperloop#944 MERGE-BASE CONTROL PASS.
// Materializes the item's merge-base as a throwaway detached worktree, runs the
// IDENTICAL predicate there, and reports which way it went:
//   ACTIVATION_CONTROL_DISCRIMINATES — the proof FAILS at the merge base, i.e.
//       it genuinely discriminates this item's work from an untouched tree.
//   ACTIVATION_CONTROL_VACUOUS      — the proof PASSES at the merge base, so it
//       would read Pass with no work done at all and proves nothing.
//   ACTIVATION_CONTROL_ERROR        — the control could not be ESTABLISHED
//       (no merge-base, worktree add failed). Never collapsed into either
//       verdict: an unestablished control is an UNKNOWN, and the #1021 lesson
//       is that an unknown must never wear a pass or a fail.
// Mirrors pr.sh's own default_branch() fallback chain (origin/HEAD, else
// main/master), the same way reviewDiffCmd does, so it never depends on pr.sh
// having run first. The temp worktree is removed plainly FIRST — git's own
// refusal is the last belt (kernel § Environment hygiene) — with --force and
// then rm -rf only as fallbacks, so a throwaway can never leak either way.
function activationControlCmd(wt, proof) {
  const err = (msg) =>
    `{ printf '{"outcome":"ACTIVATION_CONTROL_ERROR","detail":"%s"}\\n' ${sq(msg)}; exit 0; }`;
  // No `set -o pipefail` here either, and for the same reason as
  // activationProofCmd above — the control MUST evaluate the identical
  // predicate under identical semantics, or it is not a control at all.
  return [
    `cd ${sq(wt)} || ${err('cannot cd to the worktree')}`,
    `default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"`,
    `if [ -z "$default" ]; then`,
    `  for b in main master; do`,
    `    if git show-ref --verify --quiet "refs/remotes/origin/$b"; then default="$b"; break; fi`,
    `  done`,
    `fi`,
    `[ -n "$default" ] || default=main`,
    `__base="$(git merge-base HEAD "origin/$default" 2>/dev/null)"`,
    `[ -n "$__base" ] || ${err('cannot resolve the merge-base against origin/<default>')}`,
    `__tmp="$(mktemp -d)"`,
    `git worktree add --detach "$__tmp" "$__base" >/dev/null 2>&1 || { rm -rf "$__tmp"; ${err('cannot materialize the merge-base worktree')} }`,
    `__out="$( cd "$__tmp" && { ${proof} ; } 2>&1 )"; __rc=$?`,
    `git worktree remove "$__tmp" >/dev/null 2>&1 || git worktree remove --force "$__tmp" >/dev/null 2>&1 || rm -rf "$__tmp"`,
    `git worktree prune >/dev/null 2>&1 || true`,
    ACTIVATION_DETAIL_FILTER,
    `if [ "$__rc" = 0 ]; then printf '{"outcome":"ACTIVATION_CONTROL_VACUOUS","base":"%s","exitCode":0,"detail":"%s"}\\n' "$__base" "$__d";`,
    `else printf '{"outcome":"ACTIVATION_CONTROL_DISCRIMINATES","base":"%s","exitCode":%s,"detail":"%s"}\\n' "$__base" "$__rc" "$__d"; fi`,
  ].join('\n');
}

// -----------------------------------------------------------------------------
// gateFreshnessCmd — the §3e.5 pre-gate freshness step (temperloop#1937).
// -----------------------------------------------------------------------------
// build.md §3e.5 runs `scripts/quality-gates.sh` against the worktree, and a
// handful of its gates (validate-check-surface-degenerate-coverage.sh,
// validate-exec-bit-registry.sh, validate-mandatory-step-signal.sh) RATCHET
// against the CURRENT `origin/main` — they diff the worktree's registry rows
// against main's own, and flag any row main gained that the worktree never
// touched as REGRESSED. A worktree branched from main hours or days earlier
// (a long worker run, or a slow level) can be behind by the time the gate
// runs, so those rows are false positives: real work that landed on main
// AFTER this branch was cut, misread as this item's own regression. The live
// incident: the temperloop#1934 fix (a sibling item on this same level) merged
// while this worktree was mid-build and cost it a full gate round.
//
// Fetch origin and bring the worktree up to `origin/main` HERE, strictly
// before the gate runs, so the gate always measures against a tree that is
// least as current as main — never behind it. ONE combined shell script
// (fetch, ancestor-check, conditional rebase): this is always exactly ONE
// runMachinery call, never a separate check-then-rebase pair, so handling the
// stale case costs no additional machinery step beyond the check itself.
//
// `origin/main` is hardcoded rather than resolved through the
// default_branch()-style fallback chain reviewDiffCmd/activationControlCmd
// use (origin/HEAD, else main/master): this step exists specifically to match
// the exact ratchet target the named §3e.5 validators use — `origin/main`,
// by their own construction — not a generic default branch. A repo whose
// protected branch is genuinely not `main` needs a different fix than this
// one, not a guessed fallback here.
//
// Eight outcomes:
//   FRESHNESS_NO_GATE  — round 3 (temperloop#1937 HIGH, workflow): the
//     worktree carries no `scripts/quality-gates.sh` at all — the SAME
//     `[ -x … ]` presence test gateCmd's own GATE_ABSENT arm makes, checked
//     HERE first, before the fetch. There is nothing for this step to
//     protect on a gate-absent project, so it takes the byte-identical
//     pre-change path: no fetch, no rebase, no follow-on machinery.
//   FRESHNESS_CURRENT  — `git merge-base --is-ancestor origin/main HEAD`
//     already true (the worktree is at or ahead of main). No rebase is
//     attempted — the JSON line still names both SHAs for the record.
//   FRESHNESS_REBASED  — origin/main was ahead; `git rebase origin/main`
//     replayed the worker's commits onto it cleanly. The JSON line names both
//     SHAs (`worktree_base` = the worktree's HEAD after the rebase,
//     `main` = the origin/main tip it was rebased onto).
//   FRESHNESS_DIRTY    — round 2 (temperloop#1937 HIGH): origin/main was
//     ahead, but the worktree carries uncommitted TRACKED-file edits, so git
//     would refuse to even START the rebase ("cannot rebase: You have
//     unstaged changes") — a non-zero exit exactly like a real content
//     clash. Probed via `git status --porcelain --untracked-files=no`
//     immediately BEFORE the rebase is attempted (never after), mirroring
//     `pr.sh cmd_rebase`'s DIRTY_WORKTREE vs REBASE_CONFLICT split
//     (temperloop#735) — untracked files are deliberately not dirt here
//     (the worktree always carries at least the untracked `.build-guard`).
//     The rebase is NEVER attempted on this path, so it can never be
//     misread as FRESHNESS_CONFLICT (which would report an empty
//     `conflict_files` and a false "rebase aborted" disposition).
//   FRESHNESS_CONFLICT — the rebase hit a real content clash: `git diff
//     --name-only --diff-filter=U` (read BEFORE the abort — the merge
//     markers vanish once it runs) names at least one conflicted path. Then
//     `git rebase --abort` runs so the worktree is left intact on its
//     PRE-rebase commit — never a half-applied rebase, never a silent
//     revert, and NEVER pushed as a known-stale branch. The JSON line's
//     `detail` (round 3, MEDIUM) carries the tail of the rebase's own
//     stdout+stderr, and `disposition` names exactly what was done, so a
//     human resolving `stale-worktree` by hand knows the worktree was not
//     touched.
//   FRESHNESS_REBASE_ERROR — round 3 (temperloop#1937 MEDIUM): the rebase
//     failed (non-zero exit) but `--diff-filter=U` found NO conflicted
//     files — a pre-rebase hook, a missing commit identity, or a leftover
//     in-progress rebase, none of which are a content clash. Reported as its
//     OWN outcome (never collapsed into FRESHNESS_CONFLICT's shape, which
//     would report an empty `conflict_files` and falsely claim a clash was
//     aborted) with the same abort + `detail` tail treatment.
//   FRESHNESS_ERROR    — the fetch/resolve step itself could not run (no
//     network, no `origin/main`, or `git fetch` itself failed after one
//     retry). This step's job is to PREVENT a false gate failure, never to
//     manufacture one of its own — runGateFreshness() below treats this as
//     fail-OPEN (log and proceed to the gate on the tree as it stands),
//     exactly the pre-#1937 behavior. `detail` carries the fetch's own
//     stderr (round 3, MEDIUM) so a genuine outage is diagnosable rather than
//     a bare constant string.
//   FRESHNESS_TIMEOUT  — round 2 (temperloop#1937 MEDIUM): the OUTER Bash-tool
//     timeout killed this whole script before it printed any JSON line —
//     possibly mid-`git rebase`, leaving a rebase in progress on disk. Unlike
//     FRESHNESS_ERROR (nothing ran), the tree may now be mid-rebase, so
//     fail-open would run the gate against a half-rebased tree — worse than
//     the pre-#1937 behavior. runGateFreshness() below gives this its OWN
//     arm: a follow-up probe checks for an in-progress rebase and aborts it,
//     then ALWAYS escalates `stale-worktree` — never the fail-open
//     FRESHNESS_ERROR path.
//
// `git fetch origin main`'s stderr is captured rather than discarded (round 3,
// MEDIUM): under `parallel()` sibling worktrees fetch concurrently, and a
// transient `cannot lock ref` race is retried ONCE (short sleep) before it is
// reported as FRESHNESS_ERROR — a race is not evidence the network or
// `origin/main` itself is unreachable, and silently swallowing it would fail
// open back to the pre-#1937 behavior for no real reason.
//
// Every JSON line below is built with `jq -cn --arg …`, never a raw `printf`
// substitution (round 3, LOW) — the same discipline `pr.sh cmd_rebase` uses —
// so no interpolated value (a path, a git-output tail) can break the line's
// JSON shape. All payload field names are snake_case throughout (round 3, LOW).
function gateFreshnessCmd(wt, qgBin) {
  return [
    `cd ${sq(wt)} || { jq -cn '{outcome:"FRESHNESS_ERROR",detail:"cannot cd to the worktree"}'; exit 0; }`,
    // round 3 (HIGH, workflow, temperloop#1937): the SAME presence check
    // gateCmd() makes below (`[ ! -x <qgBin> ]` → GATE_ABSENT) — a project
    // with no vendored gate script has nothing for this step to protect.
    `[ -x ${sq(qgBin)} ] || { jq -cn '{outcome:"FRESHNESS_NO_GATE"}'; exit 0; }`,
    // round 3 (MEDIUM, shell): capture fetch stderr and retry once on a
    // concurrent-fetch lock race before reporting FRESHNESS_ERROR.
    `__ferr="$(git fetch origin main 2>&1 >/dev/null)"; __frc=$?`,
    `if [ "$__frc" -ne 0 ] && printf '%s' "$__ferr" | grep -q 'cannot lock ref'; then`,
    `  sleep 1`,
    `  __ferr="$(git fetch origin main 2>&1 >/dev/null)"; __frc=$?`,
    `fi`,
    `if [ "$__frc" -ne 0 ]; then`,
    `  jq -cn --arg detail "$__ferr" '{outcome:"FRESHNESS_ERROR",detail:("git fetch origin main failed: " + $detail)}'`,
    `  exit 0`,
    `fi`,
    `__main="$(git rev-parse origin/main 2>/dev/null)"`,
    `[ -n "$__main" ] || { jq -cn '{outcome:"FRESHNESS_ERROR",detail:"cannot resolve origin/main"}'; exit 0; }`,
    `if git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then`,
    `  __base="$(git rev-parse HEAD 2>/dev/null)"`,
    `  jq -cn --arg base "$__base" --arg main "$__main" '{outcome:"FRESHNESS_CURRENT",worktree_base:$base,main:$main}'`,
    `  exit 0`,
    `fi`,
    // round 2 (HIGH, temperloop#1937): probe dirtiness BEFORE attempting the
    // rebase — git's own refusal-to-start is a non-zero exit indistinguishable
    // from a content conflict, so the split has to happen here, from git's
    // state, rather than from the rebase's exit code or its (reworded-between-
    // releases) stderr prose.
    `__dirty="$(git status --porcelain --untracked-files=no 2>/dev/null)"`,
    `if [ -n "$__dirty" ]; then`,
    `  jq -cn --arg main "$__main" --arg paths "$__dirty" '{outcome:"FRESHNESS_DIRTY",main:$main,dirty_paths:($paths|split("\\n")|map(select(length>0)))}'`,
    `  exit 0`,
    `fi`,
    `if __out="$(git rebase origin/main 2>&1)"; then`,
    `  __base="$(git rev-parse HEAD 2>/dev/null)"`,
    `  jq -cn --arg base "$__base" --arg main "$__main" '{outcome:"FRESHNESS_REBASED",worktree_base:$base,main:$main}'`,
    `else`,
    // round 3 (MEDIUM, shell): rename the captured var (was the unused `out`)
    // and keep it for a `detail` tail on EITHER failure shape below.
    `  __conflicts_raw="$(git diff --name-only --diff-filter=U 2>/dev/null)"`,
    `  __tail="$(printf '%s' "$__out" | tail -n 8)"`,
    `  git rebase --abort >/dev/null 2>&1 || true`,
    `  if [ -n "$__conflicts_raw" ]; then`,
    `    jq -cn --arg main "$__main" --arg files "$__conflicts_raw" --arg detail "$__tail" --arg disposition "rebase aborted; worktree left intact on its pre-rebase commit" '{outcome:"FRESHNESS_CONFLICT",main:$main,conflict_files:($files|split("\\n")|map(select(length>0))),detail:$detail,disposition:$disposition}'`,
    `  else`,
    // round 3 (MEDIUM, shell): no conflicted files — NOT a content clash, so
    // this is its own not-a-conflict outcome, never FRESHNESS_CONFLICT's
    // shape (which would report an empty `conflict_files` and a false
    // "conflict" disposition for, say, a pre-rebase hook failure).
    `    jq -cn --arg main "$__main" --arg detail "$__tail" --arg disposition "rebase failed for a reason other than a content conflict; rebase aborted, worktree left intact on its pre-rebase commit" '{outcome:"FRESHNESS_REBASE_ERROR",main:$main,detail:$detail,disposition:$disposition}'`,
    `  fi`,
    `fi`,
  ].join('\n');
}

// gateFreshnessTimeoutProbeCmd — round 2 (temperloop#1937 MEDIUM): what to run
// when the OUTER Bash-tool timeout (FRESHNESS_TIMEOUT) kills gateFreshnessCmd()
// mid-flight, possibly mid-`git rebase`. A second, cheap machinery call —
// mirroring the shape of disposeStepTimeout()'s own follow-up probe for the
// inner STEP_TIMEOUT path, not that function itself (its probeSideEffects()
// ladder is push/PR-open specific and has nothing to say about a rebase). If a
// rebase is left in progress it is aborted, restoring the worktree to its
// pre-rebase commit exactly like gateFreshnessCmd's own FRESHNESS_CONFLICT
// arm; either way the caller escalates rather than proceeding blind.
//
// round 3 (HIGH, shell, temperloop#1937): every /build worktree is a LINKED
// worktree (`git worktree add`), whose `.git` is a pointer FILE, not a
// directory — `[ -d .git/rebase-merge ]` is therefore ALWAYS false here; the
// real state lives under `git rev-parse --git-dir` (…/.git/worktrees/<slug>/
// rebase-merge). Rather than resolve and test that path by hand, run
// `git rebase --abort` UNCONDITIONALLY and read ITS OWN exit status as the
// in-progress verdict: exit 0 means a rebase WAS in progress and is now
// aborted; a non-zero "no rebase in progress" exit means there was none to
// abort, which is not itself an error worth surfacing.
function gateFreshnessTimeoutProbeCmd(wt) {
  return [
    `cd ${sq(wt)} || { jq -cn '{outcome:"FRESHNESS_ERROR",detail:"cannot cd to the worktree for the timeout probe"}'; exit 0; }`,
    `if git rebase --abort >/dev/null 2>&1; then`,
    `  jq -cn '{outcome:"FRESHNESS_TIMEOUT_PROBE",rebase_in_progress:true,aborted:true}'`,
    `else`,
    `  jq -cn '{outcome:"FRESHNESS_TIMEOUT_PROBE",rebase_in_progress:false,aborted:false}'`,
    `fi`,
  ].join('\n');
}

// runGateFreshness(item, wt, qgBin) — drives gateFreshnessCmd() as ONE solo
// machinery call and returns an ESCALATION object to return straight out of
// driveItem, or null to proceed to §3e.5 unchanged. Mirrors runActivationGate()'s
// own shape (denied/timeout handled identically) — deliberately the SAME
// pattern, not a new one. `qgBin` is the caller's already-resolved
// `<wt>/scripts/quality-gates.sh` path (temperloop#1937 round 3) — passed
// through rather than re-derived, so this function's own presence check can
// never drift from gateCmd's.
async function runGateFreshness(item, wt, qgBin) {
  const out = await runMachinery(gateFreshnessCmd(wt, qgBin), {
    label: `gate-freshness:${item.slug}`,
    slug: item.slug,
    phase: enterStage(STAGE_GATE),
    timeoutOutcome: 'FRESHNESS_TIMEOUT',
  });
  if (machineryDenied(out)) {
    // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
    return await deniedOrQuota(item.slug, { step: 'gate-freshness', out }, wt);
  }
  if (out.outcome === 'STEP_TIMEOUT') {
    return (await disposeStepTimeout(item, wt, out, 'gate-freshness', { adoptable: false })).escalation;
  }
  if (out.outcome === 'FRESHNESS_NO_GATE') {
    // round 3 (HIGH, workflow): no vendored gate script — byte-identical to
    // the pre-#1937 path. §3e.5's own gateCmd() will independently make the
    // identical presence check and report GATE_ABSENT; nothing to do here.
    log(`[${item.slug}] pre-gate freshness — no vendored scripts/quality-gates.sh; skipping fetch/rebase (byte-identical pre-#1937 path)`);
    return null;
  }
  if (out.outcome === 'FRESHNESS_DIRTY') {
    // round 2 (HIGH, temperloop#1937): git refused to even START the rebase
    // because the worktree carries uncommitted tracked-file edits — probed
    // BEFORE the rebase was attempted, so this is never a content conflict
    // (gateFreshnessCmd's own header). Route into the EXISTING dirty-worktree
    // kind (never stale-worktree with an empty conflict list): the fix is
    // committing/discarding the edits, not resolving a rebase.
    return escalate(item.slug, 'dirty-worktree', {
      step: 'gate-freshness',
      main: out.main ?? null,
      dirty_paths: out.dirty_paths ?? [],
    });
  }
  if (out.outcome === 'FRESHNESS_CONFLICT') {
    // Never `acceptance-gate-failed` — the gate never ran, so a Fail verdict
    // would be a lie. This is its own kind: the worktree's BASE is stale, not
    // its work broken. The worktree is intact (see gateFreshnessCmd's own
    // header) on its pre-rebase commit; the fix is always resolving the
    // rebase by hand (or re-driving once main settles), never re-reading the
    // conflict as a code defect.
    return escalate(item.slug, 'stale-worktree', {
      main: out.main ?? null,
      conflict_files: out.conflict_files ?? [],
      detail: out.detail ?? null,
      disposition: out.disposition ?? 'rebase aborted; worktree left intact on its pre-rebase commit',
    });
  }
  if (out.outcome === 'FRESHNESS_REBASE_ERROR') {
    // round 3 (MEDIUM, shell): a rebase failure with NO conflicted files —
    // still `stale-worktree` (the worktree's base is still what's wrong, and
    // it is still intact on its pre-rebase commit), but a DISTINCT reason so
    // a human resolving it by hand knows this was not a content clash.
    return escalate(item.slug, 'stale-worktree', {
      reason: 'rebase-failed',
      main: out.main ?? null,
      conflict_files: [],
      detail: out.detail ?? null,
      disposition: out.disposition ?? 'rebase failed for a reason other than a content conflict; rebase aborted, worktree left intact on its pre-rebase commit',
    });
  }
  if (out.outcome === 'FRESHNESS_TIMEOUT') {
    // round 2 (MEDIUM, temperloop#1937): the outer Bash-tool timeout can kill
    // gateFreshnessCmd() mid-`git rebase`, leaving a rebase in progress on
    // disk. FRESHNESS_ERROR's fail-open is sound only when the fetch/resolve
    // step never ran at all; here the tree may be mid-rebase, so proceeding
    // blind is exactly the false-signal risk #1937 exists to prevent. Run the
    // follow-up probe, abort any in-progress rebase it finds, and ALWAYS
    // escalate `stale-worktree` — regardless of what the probe itself
    // reports — never falling into the fail-open FRESHNESS_ERROR path.
    const probe = await runMachinery(gateFreshnessTimeoutProbeCmd(wt), {
      label: `gate-freshness:${item.slug}`,
      slug: item.slug,
      phase: enterStage(STAGE_GATE),
      timeoutOutcome: 'FRESHNESS_TIMEOUT_PROBE_ERROR',
    });
    if (machineryDenied(probe)) {
      // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
      return await deniedOrQuota(item.slug, { step: 'gate-freshness-timeout-probe', out: probe }, wt);
    }
    // round 3 (MEDIUM, workflow): trust `rebase_in_progress`/`aborted` ONLY
    // when the probe itself actually resolved (FRESHNESS_TIMEOUT_PROBE) —
    // otherwise (FRESHNESS_TIMEOUT_PROBE_ERROR, or the probe's own inner
    // STEP_TIMEOUT watchdog) those fields are simply absent, and reading
    // `undefined === true` as `false` would confidently — and wrongly —
    // assert nothing was in progress. Report the unknown state as its own
    // disposition instead of guessing.
    const probeResolved = probe.outcome === 'FRESHNESS_TIMEOUT_PROBE';
    const rebaseInProgress = probeResolved ? probe.rebase_in_progress === true : null;
    const aborted = probeResolved ? probe.aborted === true : null;
    const disposition = !probeResolved
      ? 'probe timed out — rebase state unknown, check `git rev-parse --git-path rebase-merge` by hand before re-driving'
      : rebaseInProgress
        ? 'the fetch/rebase step outlived its time budget mid-rebase; the in-progress rebase was aborted and the worktree left on its pre-rebase commit'
        : 'the fetch/rebase step outlived its time budget; no rebase was left in progress on the worktree';
    log(`[${item.slug}] pre-gate freshness — outer timeout during fetch/rebase; timeout-probe outcome=${probe.outcome ?? 'none'} rebase_in_progress=${String(rebaseInProgress)} (aborted=${String(aborted)}); escalating stale-worktree`);
    return escalate(item.slug, 'stale-worktree', {
      reason: 'timeout',
      rebase_in_progress: rebaseInProgress,
      aborted,
      probe_outcome: probe.outcome ?? null,
      disposition,
    });
  }
  if (out.outcome === 'FRESHNESS_REBASED') {
    log(`[${item.slug}] pre-gate freshness — rebased onto origin/main (worktree_base ${String(out.worktree_base ?? '').slice(0, 12)}, main ${String(out.main ?? '').slice(0, 12)}) before running §3e.5`);
  } else if (out.outcome === 'FRESHNESS_CURRENT') {
    log(`[${item.slug}] pre-gate freshness — worktree already at or ahead of origin/main (${String(out.main ?? '').slice(0, 12)}); no rebase needed`);
  } else {
    // FRESHNESS_ERROR or any unrecognized outcome: fail OPEN. Not evidence
    // the tree is stale or broken — proceed to the gate on the tree as it
    // stands, exactly as every run did before this step existed.
    log(`[${item.slug}] pre-gate freshness — unresolved (${out.outcome ?? 'no outcome'}); proceeding to §3e.5 on the worktree as-is`);
  }
  return null;
}

// runActivationGate(item, wt) — the §3e.6 gate. Returns an ESCALATION object to
// return straight out of driveItem, or null to proceed to 3f.
//
// Ordering is the contract, not an implementation detail: for an absence-
// asserting predicate the control pass runs FIRST and a VACUOUS verdict
// escalates WITHOUT EVER RUNNING THE WORKTREE COPY (build.md §3e.6: "escalate
// … and loop back to 3c exactly like a Fail, without even checking the worktree
// copy"). That is why the control is its own machinery call rather than a
// branch inside one combined shell command — the ordering is then observable,
// and a test can assert the worktree run never happened.
async function runActivationGate(item, wt) {
  if (activationClass(item) !== 'A') return null; // no block, or class B/C — byte-identical path

  const proof = typeof item.activation.proof === 'string' ? item.activation.proof.trim() : '';
  if (!proof) {
    // temperloop#1451: plan.sh rule 13 fails a class-A block with no `proof:` at
    // Step 1, so this is only reachable via a hand-edited/mutated plan note. No
    // fallback actor exists, so it escalates rather than skipping.
    return escalate(item.slug, 'activation-proof-missing', {
      class: 'A',
      locus: item.activation.locus ?? null,
      reason: 'a class: A activation block reached §3e.6 with no proof: predicate; the predicate IS the gate (temperloop#1451) — author it, do not weaken or remove the block',
    });
  }

  const absence = isAbsenceProof(proof);
  const base = { class: 'A', proof, absenceAsserting: absence, locus: item.activation.locus ?? null };

  if (absence) {
    const ctl = await runMachinery(activationControlCmd(wt, proof), {
      label: `activation-control:${item.slug}`,
      slug: item.slug,
      phase: enterStage(STAGE_GATE),
      timeoutOutcome: 'ACTIVATION_TIMEOUT',
    });
    if (machineryDenied(ctl)) {
      // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
      return await deniedOrQuota(item.slug, { step: 'activation-control', out: ctl }, wt);
    }
    if (ctl.outcome === 'STEP_TIMEOUT') {
      return (await disposeStepTimeout(item, wt, ctl, 'activation-control', { adoptable: false })).escalation;
    }
    if (ctl.outcome === 'ACTIVATION_CONTROL_VACUOUS') {
      // The proof reads Pass on a tree where this item's work never happened, so
      // running it on the worker's copy would tell us nothing. Same disposition
      // as a Fail: loop back to 3c and fix the PREDICATE, never the gate.
      return escalate(item.slug, 'absence-proof-vacuous-at-merge-base', {
        ...base,
        mergeBase: ctl.base ?? null,
        detail: ctl.detail ?? '',
        reason: 'the absence-asserting proof: ALSO passes at the merge base, so it proves nothing about this item\'s work (temperloop#944). Re-author it in the wrap-immune form plan-schema.md § activation documents; do NOT relax the gate.',
      });
    }
    if (ctl.outcome !== 'ACTIVATION_CONTROL_DISCRIMINATES') {
      // ACTIVATION_CONTROL_ERROR / ACTIVATION_TIMEOUT / anything unexpected: the
      // control was never ESTABLISHED. Not a Fail (it says nothing about the
      // tree) and emphatically not a Pass — proceeding would let a possibly
      // vacuous proof wave the item through, which is the whole defect. Halt.
      return escalate(item.slug, 'activation-control-unavailable', {
        ...base,
        outcome: ctl.outcome,
        detail: ctl.detail ?? '',
        reason: 'the merge-base control pass could not be established, so an absence-asserting proof cannot be trusted either way; re-run once the merge-base worktree can be materialized',
      });
    }
    log(`[${item.slug}] 3e.6 activation control PASS — the absence proof FAILS at merge base ${String(ctl.base ?? '').slice(0, 12)}, so it discriminates`);
  }

  const out = await runMachinery(activationProofCmd(wt, proof, 'ACTIVATION_PASS', 'ACTIVATION_FAIL'), {
    label: `activation:${item.slug}`,
    slug: item.slug,
    phase: enterStage(STAGE_GATE),
    timeoutOutcome: 'ACTIVATION_TIMEOUT',
  });
  if (machineryDenied(out)) {
    // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
    return await deniedOrQuota(item.slug, { step: 'activation', out }, wt);
  }
  if (out.outcome === 'STEP_TIMEOUT') {
    return (await disposeStepTimeout(item, wt, out, 'activation', { adoptable: false })).escalation;
  }
  if (out.outcome !== 'ACTIVATION_PASS') {
    // Fail (or an unknown/timeout outcome, which is equally not a Pass) → loop
    // back to 3c with the activation output as context. Do NOT push a branch
    // whose feature is dormant. The worker's fix is the missing WIRING
    // (register / flip / render), never a weaker predicate.
    return escalate(item.slug, 'activation-failed', {
      ...base,
      outcome: out.outcome,
      exitCode: out.exitCode ?? null,
      detail: out.detail ?? '',
      reason: 'the class: A activation proof did not pass against the worker\'s worktree — the built thing is not reachable on the running path. Add the missing wiring; do NOT weaken the predicate.',
    });
  }
  log(`[${item.slug}] 3e.6 activation gate PASS — class A${absence ? ' (absence-asserting, control-verified at merge base)' : ''}`);
  return null;
}

// =============================================================================
// THE DUAL-BUILD HARNESS (temperloop#2080, epic #2065) — arms + level barrier
// =============================================================================
// WHAT THIS ITEM DOES, AND DELIBERATELY DOES NOT DO. Given a `dualBuild`
// workflow input, every IN-SCOPE item of the level is built TWICE — once per
// arm, each arm on its own model, in its own `@<arm>`-suffixed worktree and
// branch — locally gated per arm, then pairwise-judged. It records one ledger
// row per item per arm and STOPS: the level pick, the winner's route to PR, the
// two operator levers and the losing arm's archive/delete are
// `level-pick-and-operator-levers` (temperloop#2083). The barrier is exactly
// that stopping point, and it is the whole reason driveItem was split above:
// ADR 0038 fixes the unit of JUDGEMENT at the item and the unit of CHOICE at
// the level, so no PR may open for an in-scope item until every in-scope arm in
// the level has a gate result and every in-scope item has a judge disposition.
//
// A NOT-IN-SCOPE item of the same level is untouched by all of this: one build,
// the ordinary single-arm driveItem (PR, CI, park), plus one ledger row marking
// it out of scope so the level's ledger accounts for every item rather than
// only the compared ones.
//
// NOTHING BELOW RUNS WITHOUT `input.dualBuild`. dualBuildInput() returns null
// for every ordinary invocation, buildLevel() takes its pre-#2080 fan-out, and
// the only trace this code leaves on a flag-less run is the residue guard
// folded into the existing worktree-create step (which prints nothing of its
// own on a clean tree — see its comment at 3b).
// =============================================================================

// The two arm names, in START ORDER. `baseline` is arm A / `--record-a` for the
// pairwise judge and `candidate` is arm B / `--record-b`, fixed here once so the
// ledger's `start_order`, the judge's A/B mapping and the worktree suffixes
// cannot drift apart across the three sites that read them.
const DUAL_BUILD_ARMS = ['baseline', 'candidate'];

// The marker the arm-read-isolation guard (temperloop#2077) appends a line to
// on every DENIED cross-arm read, beside the `.dual-build-arm` marker in the
// arm's own worktree. Its mere presence is the ledger's `cross_read_attempted`.
const DUAL_BUILD_ATTEMPTS_FILE = '.dual-build-cross-read-attempts.jsonl';

// dualBuildInput — normalize and VALIDATE `input.dualBuild`.
// Returns null (no dual build — every existing invocation), a normalized
// descriptor, or `{ invalid: <reason> }`. There is deliberately no third,
// silent arm: a `dualBuild` key that is present but unusable REFUSES the level
// rather than degrading to a single-arm build, because a level that was asked
// to compare two models and quietly compared none is exactly the result nobody
// can tell from a successful one after the fact.
function dualBuildInput() {
  const d = input.dualBuild;
  if (d == null) return null;
  if (typeof d !== 'object' || Array.isArray(d)) {
    return { invalid: 'dualBuild must be an object { tier, baseline, candidate, inScope: [slug…] }' };
  }
  const str = (v) => (typeof v === 'string' && v.trim() ? v.trim() : '');
  const tier = str(d.tier);
  const baseline = str(d.baseline);
  const candidate = str(d.candidate);
  const inScope = Array.isArray(d.inScope) ? d.inScope.map(str).filter(Boolean) : null;
  const missing = [];
  if (!tier) missing.push('tier');
  if (!baseline) missing.push('baseline');
  if (!candidate) missing.push('candidate');
  // An EMPTY inScope is as unusable as an absent one, and `![]` is false, so a
  // truthiness check alone lets it through (temperloop#2080 review round 3). A
  // present-but-empty array reaches here two ways: the caller passed `inScope: []`,
  // or every entry was blank/non-string and `.map(str).filter(Boolean)` scrubbed it.
  // Either way `dual.inScope` becomes an empty Set, EVERY item then misses
  // `inScope.has(slug)` and takes the single-arm path, and the level reports a
  // dualBuild summary having compared nothing — precisely the outcome this function
  // refuses rather than degrades into.
  if (!inScope || inScope.length === 0) missing.push('inScope');
  if (missing.length > 0) {
    return { invalid: `dualBuild is missing or empty: ${missing.join(', ')}` };
  }
  if (baseline === candidate) {
    // Not refused — an A/A instrument check (both arms the same model, the
    // epic's own first-live-run shape) is a legitimate and deliberate use. It
    // is LOGGED so a reader never mistakes it for a real comparison.
    log(
      `dual-build: baseline and candidate are the SAME model (${baseline}) — this is an A/A instrument ` +
        'check, not a candidate-vs-baseline comparison. No arm difference it reports is a model difference.',
    );
  }
  return { tier, baseline, candidate, inScope: new Set(inScope), inScopeList: inScope };
}

// dualBuildResidueGuard — wrap the worktree-create command in the flag-less
// resume refusal (see the 3b comment for WHY it lives inside this step rather
// than in a probe of its own). On a clean tree the emitted script runs the
// create command verbatim and prints its CREATED line and nothing else, so a
// flag-less run's output is byte-identical to the pre-#2080 one.
function dualBuildResidueGuard(repoRoot, slug, createCmd) {
  const armGlobPrefix = sq(`${repoRoot}.wt/${slug}@`);
  return [
    // The matched paths are interpolated into a JSON string field below, so the
    // two characters that would make that object unparseable are deleted first
    // (temperloop#2080 round-2 review [LOW], the same filter
    // ACTIVATION_DETAIL_FILTER applies for the identical reason). The `-n` test
    // is unaffected: a path is never made empty by dropping a quote.
    `__dbres=$(ls -d ${armGlobPrefix}* 2>/dev/null | tr '\\n' ' ' | tr -d '\\\\"')`,
    'if [ -n "$__dbres" ]; then',
    `printf '{"outcome":"DUAL_BUILD_RESIDUE","arms":"%s"}\\n' "$__dbres"`,
    'else',
    createCmd,
    'fi',
  ].join('\n');
}

// armItem — the per-arm view of a plan item. Three fields move and nothing else
// does, which is what lets the ENTIRE phase-1 body run unmodified for an arm:
//   slug   → `<slug>@<arm>`  … every label, every /tmp/qg-<…> path and every
//            deterministic worktree path in phase 1 is derived from item.slug,
//            so suffixing it here is what stops two arms of one item colliding
//            on a gate log, a selection pin or a worktree — without threading an
//            "arm key" parameter through forty call sites.
//   branch → `build/<slug>@<arm>` … matches what `worktree.sh create --arm`
//            actually creates, so the recover-probe and any later push address
//            the arm's own ref rather than the item's shared one.
//   model  → that arm's model … and because callWorker() reads item.model on
//            BOTH the first spawn and the #1219 foreground-cure retry, the
//            retry stays on the arm's own model by construction. There is no
//            tier-escalation path here to opt out of: nothing in this driver
//            ever substitutes a stronger model for a failed worker.
function armItem(item, armName, model) {
  return {
    ...item,
    slug: `${item.slug}@${armName}`,
    branch: `build/${item.slug}@${armName}`,
    model,
  };
}

// dualBuildSplitModel — "<provider>/<model>" → { provider, model }; a bare model
// id means the host's default provider (candidate-session.sh's own
// `_CS_DEFAULT_PROVIDER`), which is also what an omitted `--provider` means to
// that script.
function dualBuildSplitModel(spec) {
  const i = String(spec).indexOf('/');
  return i > 0
    ? { provider: String(spec).slice(0, i), model: String(spec).slice(i + 1) }
    : { provider: '', model: String(spec) };
}

// -----------------------------------------------------------------------------
// candidateArmGate — the candidate arm's host-supply + containment seam.
// -----------------------------------------------------------------------------
// Every candidate arm passes through `candidate-session.sh` BEFORE it builds:
// `resolve` proves the containment overlay is present, readable and well-formed
// (the same fail-closed check judge.sh's own pairwise mode runs), and
// `preflight` proves the candidate provider's credential is actually SET rather
// than merely named. A refusal is an INFRA loss for that arm, recorded as such —
// never a silent single-arm level.
//
// WHY THE WORKER ITSELF IS NOT SPAWNED BY `candidate-session.sh spawn`, AND WHY
// A NON-DEFAULT PROVIDER IS THEREFORE REFUSED HERE. `spawn` runs a `claude` CLI
// child inside whatever shell invokes it. In this driver the only shell is an
// executor agent's Bash tool, hard-capped at AGENT_BASH_CAP_MS (~10 minutes) —
// DESIGN NOTE 1/2. A build worker is an hour-scale process, so routing it
// through `spawn` would not produce a contained candidate session; it would
// produce a worker killed mid-build on every non-trivial item. The reachable
// spawn seam with no such cap is the runtime's own `agent({ model })`, which
// addresses the host session's provider only.
//
// So the seam is honest about its edge rather than silently exceeding it: a
// candidate naming the DEFAULT provider builds through `agent({ model })` (the
// A/A instrument check and every same-provider tier comparison — the epic's own
// first live run), and a candidate naming a NON-DEFAULT provider is REFUSED by
// name with an `infra` row. It is never spawned uncontained, which is the one
// outcome that would defeat candidate-session.sh's whole purpose. Lifting that
// edge needs an uncapped spawn seam, which is its own piece of work, not a
// silent widening here.
async function candidateArmGate(ai, dual) {
  const { provider } = dualBuildSplitModel(dual.candidate);
  const csBin = sq(`${input.repoRoot}/workflows/scripts/model-comparison/candidate-session.sh`);
  const providerFlag = provider ? ` --provider ${sq(provider)}` : '';
  const cmd = [
    `__cs=${csBin}`,
    'if [ ! -f "$__cs" ]; then',
    `printf '{"outcome":"CANDIDATE_REFUSED","reason":"seam-absent","detail":"candidate-session.sh not found at %s"}\\n' "$__cs"`,
    'elif ! bash "$__cs" resolve Read >/dev/null 2>&1; then',
    `printf '{"outcome":"CANDIDATE_REFUSED","reason":"containment-unusable","detail":"candidate-session.sh resolve refused: the containment overlay is absent, unreadable or malformed"}\\n'`,
    `elif ! bash "$__cs" preflight${providerFlag} --execution live >/dev/null 2>&1; then`,
    `printf '{"outcome":"CANDIDATE_REFUSED","reason":"preflight-failed","detail":"candidate-session.sh preflight refused provider %s — its credential is unset or the provider is unregistered"}\\n' ${sq(provider || '(default)')}`,
    provider ? 'elif [ -n "x" ]; then' : 'else',
    ...(provider
      ? [
          `printf '{"outcome":"CANDIDATE_REFUSED","reason":"non-default-provider-unspawnable","detail":"candidate provider %s needs candidate-session.sh spawn, which cannot host an hour-scale build worker under the executor Bash cap — refusing rather than spawning it uncontained"}\\n' ${sq(provider)}`,
          'else',
          `printf '{"outcome":"CANDIDATE_READY"}\\n'`,
        ]
      : [`printf '{"outcome":"CANDIDATE_READY"}\\n'`]),
    'fi',
  ].join('\n');
  const out = await runMachinery(cmd, {
    label: `candidate-session:${ai.slug}`,
    slug: ai.slug,
    phase: enterStage(STAGE_CLAIM),
  });
  if (machineryDenied(out) || out.outcome !== 'CANDIDATE_READY') {
    return {
      ok: false,
      reason: (out && out.reason) || 'seam-unreachable',
      detail: (out && out.detail) || `candidate-session.sh gate returned ${JSON.stringify(out && out.outcome)}`,
    };
  }
  return { ok: true };
}

// -----------------------------------------------------------------------------
// dualBuildLossReason — the ONE mapping from a phase-1 terminal record to the
// ledger's closed `loss_reason` vocabulary (gate | judge | infra | incomplete).
// -----------------------------------------------------------------------------
// Kept as one function rather than inline at the two call sites so the ledger's
// vocabulary has a single author: a row that says `infra` when the branch was
// actually red is a comparison result nobody can trust afterwards.
//   gate        — the acceptance gate itself reported RED, or could not finish
//                 (a timeout is not evidence about the tree, but it IS the gate
//                 failing to produce a verdict for this arm, which is a loss).
//   incomplete  — the WORKER did not reach a gate-passing state: it escalated a
//                 verdict (blocked / design-fork / failed), left acceptance
//                 bullets failing, or its review round never converged. The arm
//                 built something; it just is not finishable without a human.
//   infra       — everything else: machinery, claim, worktree, quota, denial,
//                 dependency ordering, a lost return. Nothing was learned about
//                 the model from these, which is precisely why they are named
//                 apart from the two above.
const DUAL_BUILD_GATE_KINDS = new Set(['acceptance-gate-failed', 'acceptance-gate-timeout']);
const DUAL_BUILD_INCOMPLETE_KINDS = new Set([
  'blocked', 'design-fork', 'failed', 'acceptance-incomplete', 'review-blocking',
]);
function dualBuildLossReason(kind) {
  if (DUAL_BUILD_GATE_KINDS.has(kind)) return 'gate';
  if (DUAL_BUILD_INCOMPLETE_KINDS.has(kind)) return 'incomplete';
  return 'infra';
}

// driveArm — build ONE arm of ONE in-scope item through phase 1 only.
// Returns a normalized arm result; it NEVER returns a parked/escalation record
// to the level, because a per-arm failure is not an item failure (the epic's
// sequencing note: "No per-arm failure ever escalates across the driveItem
// boundary — it degrades to a ledger row with a loss_reason instead").
async function driveArm(item, dual, armName, order) {
  const model = armName === 'baseline' ? dual.baseline : dual.candidate;
  const sibling = armName === 'baseline' ? 'candidate' : 'baseline';
  const ai = armItem(item, armName, model);
  const base = {
    arm: armName,
    order,
    model,
    key: ai.slug,
    wt: `${input.repoRoot}.wt/${ai.slug}`,
    branch: ai.branch,
    wtBase: '',
    guardArmed: 'UNKNOWN',
    ctx: null,
    cost: null,
    acceptanceResults: [],
  };

  if (armName === 'candidate') {
    const gate = await candidateArmGate(ai, dual);
    if (!gate.ok) {
      log(`[${ai.slug}] dual-build candidate arm REFUSED at the candidate-session seam (${gate.reason}): ${gate.detail}`);
      return { ...base, gate: 'fail', lossReason: 'infra', failure: { kind: `candidate-session:${gate.reason}`, detail: gate.detail } };
    }
  }

  const built = await driveItemBuild(ai, { name: armName, sibling, slug: item.slug, order });
  // temperloop#2080 round-1 review [MEDIUM]. driveItemBuildPhase returns a
  // TERMINAL record on two paths that mean OPPOSITE things: escalate() (a real
  // failure) and — for kind:spike alone — park() (the read-only verdict marker,
  // that item's NORMAL completion, and the only park() the build phase returns
  // at all). Folding "any terminal record" into the loss path recorded a
  // successful spike arm as `gate:'fail' loss_reason:'infra'`, corrupting
  // exactly the ledger this feature exists to produce and making judgeArms
  // report `one-arm-only` for a pair where BOTH arms finished. A spike creates
  // no worktree and runs no gate, so this arm honestly carries no
  // base_sha/guard/cost — but it completed, so it is a passing arm.
  if (built.result && built.result._kind === 'parked') {
    log(`[${ai.slug}] dual-build arm completed as a read-only spike verdict (no worktree, no gate) — a passing arm, not a loss`);
    return {
      ...base,
      gate: 'pass',
      lossReason: null,
      spike: true,
      acceptanceResults: built.result.parked?.acceptance_results ?? [],
    };
  }
  if (built.result) {
    const kind = built.result.escalation.kind;
    const lossReason = dualBuildLossReason(kind);
    log(`[${ai.slug}] dual-build arm did not reach a gate-passing branch (${kind}) — recorded as a ${lossReason} loss`);
    return {
      ...base,
      gate: 'fail',
      lossReason,
      failure: { kind, payload: built.result.escalation.payload },
    };
  }
  const ctx = built.ctx;
  return {
    ...base,
    gate: 'pass',
    lossReason: null,
    ctx,
    wtBase: ctx.wtBase || '',
    guardArmed: ctx.wtGuard || 'UNKNOWN',
    acceptanceResults: ctx.verdict?.acceptance_results ?? [],
    cost: {
      tokens_in: ctx.mainCost?.tokensIn ?? null,
      tokens_out: ctx.mainCost?.tokensOut ?? null,
      wall_clock_ms: ctx.mainCost?.wallClockMs ?? null,
      retry_tokens: null,
      retry_count: 0,
      recovery: !!ctx.recovery,
    },
  };
}

// dualBuildCost — a row's cost object, always all six keys, honest nulls for an
// arm that never returned a worker verdict (same posture park()'s own cost
// block takes: a ledger with silently-missing rows is worse than one with
// honest nulls).
function dualBuildCost(armResult) {
  return armResult.cost ?? {
    tokens_in: null, tokens_out: null, wall_clock_ms: null,
    retry_tokens: null, retry_count: 0, recovery: false,
  };
}

// -----------------------------------------------------------------------------
// judgeArms — the pairwise judge call, run AT the barrier (temperloop#2073).
// -----------------------------------------------------------------------------
// One `judge.sh pairwise` per in-scope item whose TWO arms both gate-passed:
// record-a is the baseline arm, record-b is the candidate arm, and the script
// sends the same prompt twice in both position orders and reports
// { preference, margin, order_agreement }. The two record files are assembled
// in the executor's own shell from this driver's item metadata plus each arm's
// diff against its recorded base, because that diff exists only on disk.
//
// A judged item ALWAYS gets a DISPOSITION, never silence: a real verdict, or a
// named reason there is none (one arm never gated, the seam is absent, the
// judge refused or was unavailable). That is what makes "every in-scope item has
// a judge result" checkable at the barrier rather than a hope.
async function judgeArms(item, dual, arms) {
  const a = arms.find((x) => x.arm === 'baseline');
  const b = arms.find((x) => x.arm === 'candidate');
  if (!a || !b || a.gate !== 'pass' || b.gate !== 'pass') {
    const lost = [a, b].filter((x) => x && x.gate !== 'pass').map((x) => x.arm);
    return {
      judged: false,
      reason: 'one-arm-only',
      detail: `no pairwise comparison is possible: ${lost.join(' and ')} produced no gate-passing branch`,
      judge: null,
    };
  }
  // temperloop#2080 round-1 review [MEDIUM], the companion to driveArm's
  // spike-park branch: a spike arm produces a VERDICT NOTE, not a diff, and its
  // worktree does not exist — so `judge.sh pairwise`, which compares the two
  // arms' diffs against their recorded bases, would compare two empty excerpts
  // and return a verdict about nothing. That is a named DISPOSITION (this
  // function's own contract: never silence), not a judgement.
  if (a.spike || b.spike) {
    return {
      judged: false,
      reason: 'spike-arm',
      detail: `${item.slug} is a read-only spike: its arms produce a verdict note rather than a diff, so a pairwise code judge has nothing to compare`,
      judge: null,
    };
  }
  const mcDir = `${input.repoRoot}/workflows/scripts/model-comparison`;
  // The item half of both records, identical by construction — judge.sh's own
  // same-item precondition refuses two records that disagree on
  // issue/title/scope/acceptance, so building both from ONE literal here is
  // what makes that precondition pass for a legitimate pair.
  const itemBlock = {
    issue: item.ghIssue ? Number(item.ghIssue) : null,
    title: item.title ?? item.slug,
    scope: item.scope ?? '',
    acceptance: acceptanceList(item),
  };
  const recordFor = (arm) => JSON.stringify({
    ...itemBlock,
    candidate: { provider: dualBuildSplitModel(arm.model).provider || 'anthropic', model: dualBuildSplitModel(arm.model).model },
    score: { diff: { text_excerpt: '' } },
  });
  const diffCmd = (arm) =>
    `git -C ${sq(arm.wt)} diff ${sq(arm.wtBase || 'HEAD')}..HEAD 2>/dev/null | head -c 200000`;
  const cmd = [
    `__mc=${sq(mcDir)}`,
    'if [ ! -f "$__mc/judge.sh" ]; then',
    `printf '{"outcome":"JUDGE_UNAVAILABLE","reason":"seam-absent"}\\n'`,
    'else',
    '__jd=$(mktemp -d) || __jd=""',
    'if [ -z "$__jd" ]; then',
    `printf '{"outcome":"JUDGE_UNAVAILABLE","reason":"scratch-dir-failed"}\\n'`,
    'else',
    `printf %s ${sq(recordFor(a))} | jq -c --arg d "$(${diffCmd(a)})" '.score.diff.text_excerpt=$d' > "$__jd/a.json"`,
    `printf %s ${sq(recordFor(b))} | jq -c --arg d "$(${diffCmd(b)})" '.score.diff.text_excerpt=$d' > "$__jd/b.json"`,
    // THE VERDICT IS READ UN-PIPED (temperloop#2080 round-2 review [HIGH]), the
    // same shape activationProofCmd uses and for the same reason: `$?` after a
    // pipeline is the LAST command's status, so `… | tail -1; __jr=$?` reads
    // tail's status — effectively always 0 — and judge.sh's own exit never
    // reaches the branch below. That mis-reads BOTH ways: a judge.sh that dies
    // AFTER writing a line would have its garbage recorded as a real pairwise
    // verdict, and the refusal's `rc` field — whose whole job is to report that
    // status — would be structurally 0. So: capture whole, read `$?`, THEN trim
    // to the last line in a separate step. Deliberately no PIPESTATUS (zsh
    // spells it `$pipestatus` and 1-indexes it) and no `set -o pipefail` (see
    // activationProofCmd's comment for why that is worse, not safer).
    `__jo=$(bash "$__mc/judge.sh" pairwise --record-a "$__jd/a.json" --record-b "$__jd/b.json" --live --repo ${sq(input.ownerRepo ?? '')} 2>/dev/null); __jr=$?`,
    `__jo=$(printf '%s\\n' "$__jo" | tail -1)`,
    'rm -rf "$__jd"',
    // A non-JSON last line is a NAMED refusal, never interpolated: this printf
    // splices "$__jo" raw into a JSON object the driver parses as one line, so
    // an unparseable line would turn a legible refusal into malformed
    // machinery output the caller reports as a bare parse failure.
    'if [ "$__jr" -eq 0 ] && [ -n "$__jo" ] && printf %s "$__jo" | jq -e . >/dev/null 2>&1; then',
    `printf '{"outcome":"JUDGED","judge":%s}\\n' "$__jo"`,
    'elif [ "$__jr" -eq 0 ] && [ -n "$__jo" ]; then',
    `printf '{"outcome":"JUDGE_UNAVAILABLE","reason":"judge-unparseable","rc":0}\\n'`,
    'else',
    `printf '{"outcome":"JUDGE_UNAVAILABLE","reason":"judge-refused","rc":%s}\\n' "$__jr"`,
    'fi',
    'fi',
    'fi',
  ].join('\n');
  const out = await runMachinery(cmd, {
    label: `judge:${item.slug}`,
    slug: item.slug,
    phase: enterStage(STAGE_GATE),
  });
  if (machineryDenied(out) || out.outcome !== 'JUDGED' || !out.judge || typeof out.judge !== 'object') {
    return {
      judged: false,
      reason: (out && out.reason) || 'judge-unavailable',
      detail: `judge.sh pairwise produced no verdict for ${item.slug} (${JSON.stringify(out && out.outcome)})`,
      judge: null,
    };
  }
  // preference "A" is the BASELINE arm and "B" the CANDIDATE arm — the
  // record-a/record-b binding above, restated here once so the mapping lives
  // beside the call that creates it rather than at the row writer.
  const pref = String(out.judge.preference ?? '');
  const prefersArm = pref === 'A' ? 'baseline' : pref === 'B' ? 'candidate' : null;
  return {
    judged: true,
    reason: null,
    judge: {
      preference: out.judge.preference ?? null,
      margin: out.judge.margin ?? null,
      order_agreement: out.judge.order_agreement ?? null,
    },
    prefersArm,
  };
}

// -----------------------------------------------------------------------------
// appendDualBuildRows — the ledger write (temperloop#2072).
// -----------------------------------------------------------------------------
// One `dual-build-ledger.sh append` per row, batched into ONE executor for the
// item (two rows in scope, one row out of scope). Three of the row's fields
// cannot be known in this runtime and are filled by the executor's own shell
// from the arm's worktree:
//   cross_read_attempted — whether the arm-read guard recorded a DENIED
//                          cross-arm read beside the `.dual-build-arm` marker;
//   head_sha             — the arm branch's tip, which exists only on disk;
//   machinery_version    — the checkout's VERSION, the join key K#1924's own
//                          per-step resume ledger uses.
// Everything else is composed here, in legible .mjs, and handed over as a JSON
// literal — the same division of labour every other machinery call in this file
// uses (DESIGN NOTE 1: the branching stays here, the shell only executes).
async function appendDualBuildRows(item, dual, rows) {
  if (rows.length === 0) return { appended: 0, rejected: 0, unavailable: false };
  const ledgerBin = sq(`${input.repoRoot}/workflows/scripts/model-comparison/dual-build-ledger.sh`);
  const versionFile = sq(`${input.repoRoot}/VERSION`);
  const steps = rows.map(({ row, wt, arm }) => ({
    kind: `row-${arm}`,
    cmd: [
      `__led=${ledgerBin}`,
      'if [ ! -f "$__led" ]; then',
      `printf '{"outcome":"ROW_UNAVAILABLE","arm":"%s","reason":"dual-build-ledger.sh not found"}\\n' ${sq(arm)}`,
      'else',
      `__ca=false; [ -s ${sq(`${wt}/${DUAL_BUILD_ATTEMPTS_FILE}`)} ] && __ca=true`,
      `__hs=$(git -C ${sq(wt)} rev-parse HEAD 2>/dev/null); [ -n "$__hs" ] || __hs=unknown`,
      `__mv=$(head -1 ${versionFile} 2>/dev/null | tr -d '[:space:]'); [ -n "$__mv" ] || __mv=unknown`,
      `__row=$(printf %s ${sq(row)} | jq -c --argjson ca "$__ca" --arg hs "$__hs" --arg mv "$__mv" '.cross_read_attempted=$ca | .head_sha=$hs | .machinery_version=$mv')`,
      'if [ -z "$__row" ]; then',
      `printf '{"outcome":"ROW_REJECTED","arm":"%s","reason":"row could not be assembled"}\\n' ${sq(arm)}`,
      'elif bash "$__led" append --row "$__row" >/dev/null 2>&1; then',
      `printf '{"outcome":"ROW_APPENDED","arm":"%s"}\\n' ${sq(arm)}`,
      'else',
      `printf '{"outcome":"ROW_REJECTED","arm":"%s","reason":"dual-build-ledger.sh append refused the row"}\\n' ${sq(arm)}`,
      'fi',
      'fi',
    ].join('\n'),
  }));
  const batch = await runMachineryBatch(steps, {
    label: `dual-build-rows:${item.slug}`,
    slug: item.slug,
    bashTimeoutMs: BATCH_BASH_TIMEOUT_MS,
    phase: enterStage(STAGE_GATE),
  });
  if (batch.denied) {
    log(`[${item.slug}] dual-build ledger write DENIED — no rows recorded for this item; the arms' builds stand, the comparison record does not`);
    return { appended: 0, rejected: 0, unavailable: true };
  }
  let appended = 0;
  let rejected = 0;
  batch.results.forEach((r) => {
    if (r && r.outcome === 'ROW_APPENDED') appended += 1;
    else rejected += 1;
  });
  if (rejected > 0) {
    log(
      `[${item.slug}] dual-build ledger: ${appended} row(s) appended, ${rejected} NOT recorded ` +
        `(${batch.results.filter((r) => r && r.outcome !== 'ROW_APPENDED').map((r) => `${r.arm ?? '?'}: ${r.reason ?? r.outcome}`).join('; ')}) ` +
        '— the comparison is incomplete for this item and the level pick must not treat it as judged',
    );
  }
  return { appended, rejected, unavailable: false };
}

// dualBuildRow — compose ONE ledger row. `cross_read_attempted`, `head_sha` and
// `machinery_version` are placeholders here; the executor overwrites all three
// (see appendDualBuildRows). Every other field is authored here.
function dualBuildRow(item, dual, armResult, judgeOutcome, extra) {
  return JSON.stringify({
    tier: dual.tier,
    model: armResult.model,
    slug: item.slug,
    arm: armResult.arm,
    base_sha: armResult.wtBase || 'unknown',
    head_sha: 'unknown',
    start_order: armResult.order,
    gate: armResult.gate,
    cost: dualBuildCost(armResult),
    judge: judgeOutcome && judgeOutcome.judged ? judgeOutcome.judge : null,
    // The LEVEL pick is `level-pick-and-operator-levers` (temperloop#2083), by
    // construction of the barrier: this row is written before any pick exists,
    // so it says so rather than guessing one.
    pick: null,
    override: { applied: false },
    loss_reason: armResult.lossReason ?? null,
    cross_read_attempted: false,
    guard_armed: armResult.guardArmed,
    machinery_version: 'unknown',
    ...(extra ?? {}),
  });
}

// -----------------------------------------------------------------------------
// driveInScopeItem — one in-scope item: two arms, the barrier's local half.
// -----------------------------------------------------------------------------
// Returns the arm results; the judge, the rows and the item's record are the
// caller's post-barrier job, because a judge that ran here would judge one item
// while a sibling item's arms were still building — which is a per-item barrier,
// not the level barrier ADR 0038 requires.
async function driveInScopeItem(item, dual, boardWrites) {
  // The BUFFERED board write (see 3a's own comment). Recorded once per ITEM,
  // never per arm, and carrying the exact command the pick will run.
  if (input.board && item.ghIssue) {
    const claimBin = input.claimCmd ?? 'claim.sh';
    boardWrites.push({
      slug: item.slug,
      issue: item.ghIssue,
      board: input.board,
      cmd: `${claimBin} ${item.ghIssue} --board ${input.board}`,
      buffered_until: 'level-pick',
      reason:
        'an in-scope item is built under two arms; the claim is a statement about the ITEM and the ' +
        'Done/close cascade must follow the arm that WON, so the board write is held until the pick',
    });
  }
  // START ORDER. parallel() invokes its thunks in array order, synchronously up
  // to each one's first await, so the counter below assigns baseline=1 and
  // candidate=2 deterministically — a recorded fact about which arm started
  // first, not a guess re-derived later from timestamps that this runtime
  // cannot read anyway.
  let order = 0;
  const arms = await parallel(
    DUAL_BUILD_ARMS.map((name) => () => {
      order += 1;
      return driveArm(item, dual, name, order).catch((err) => ({
        arm: name,
        order,
        model: name === 'baseline' ? dual.baseline : dual.candidate,
        key: `${item.slug}@${name}`,
        wt: `${input.repoRoot}.wt/${item.slug}@${name}`,
        branch: `build/${item.slug}@${name}`,
        wtBase: '',
        guardArmed: 'UNKNOWN',
        ctx: null,
        cost: null,
        acceptanceResults: [],
        gate: 'fail',
        lossReason: 'infra',
        failure: { kind: 'arm-throw', detail: String((err && err.stack) || err) },
      }));
    }),
  );
  return { item, inScope: true, arms };
}

// dualBuildArmSummary — the per-arm shape that rides the item's returned record
// (and, through it, the orchestrator's Step 6 summary and the eventual pick).
// Deliberately NOT the raw arm result: `ctx` holds the whole phase-1 context
// including the worker verdict, and shipping that back would put every arm's
// full acceptance prose into the orchestrator's context — the one cost this
// whole workflow exists to bound.
function dualBuildArmSummary(a) {
  return {
    arm: a.arm,
    model: a.model,
    start_order: a.order,
    worktree: a.wt,
    branch: a.branch,
    base_sha: a.wtBase || null,
    guard_armed: a.guardArmed,
    gate: a.gate,
    loss_reason: a.lossReason ?? null,
    acceptance_results: a.acceptanceResults ?? [],
    cost: dualBuildCost(a),
    ...(a.failure ? { failure: a.failure } : {}),
    ...(SIDELINE_NOTICES.get(a.key) ? { sidelined: SIDELINE_NOTICES.get(a.key) } : {}),
  };
}

// -----------------------------------------------------------------------------
// dualBuildGuarded — the #437 silent-loss guard, applied BY CONSTRUCTION.
// -----------------------------------------------------------------------------
// `parallel()` is not `Promise.all`: a REJECTED thunk is dropped to `null`
// rather than failing the batch, and buildLevel's consuming loop
// (`for (const r of results) { if (!r) continue; }`) then skips that slot in
// silence — leaving the item in NEITHER `parked` NOR `escalations`. That is
// temperloop#437 exactly (a real run hit `item.acceptance.map` on a string and
// the item vanished), and the single-arm fan-out was hardened against it with a
// per-item `.catch()`.
//
// temperloop#2080 round-1 review [HIGH]: that guard is a CONVENTION every
// fan-out site has to remember, and the dual-build fan-outs remembered it for
// the not-in-scope branch only — so an in-scope item whose drive threw was
// silently lost again. Wrapping the thunk here makes the guard structural
// instead: every dual-build fan-out builds its thunks through this, so a future
// edit that adds an un-caught `await` inside one cannot reintroduce the drop.
// The returned thunk is `async` deliberately — that converts a SYNCHRONOUS
// throw in `fn`'s body (not just a rejected promise) into a rejection this
// function itself catches, which a bare `fn().catch()` would let escape.
function dualBuildGuarded(fn, onError) {
  return async () => {
    try {
      return await fn();
    } catch (err) {
      return await onError(err);
    }
  };
}

// -----------------------------------------------------------------------------
// driveLevelDualBuild — the level driver, and the BARRIER itself.
// -----------------------------------------------------------------------------
// Three phases, in this order, and the order IS the contract:
//   1. BUILD. Every item in parallel. An in-scope item fans out two arms and
//      stops at the end of phase 1; a not-in-scope item takes the ordinary
//      single-arm driveItem, PR and all.
//   2. THE BARRIER. The `await` on phase 1 is the barrier — past it, EVERY
//      in-scope arm in the level has a gate result. Only now does any judging
//      happen, and no PR has opened for any in-scope item.
//   3. JUDGE + RECORD. Per item: the pairwise judge, then the ledger rows, then
//      the item's own record. Still no PR for an in-scope item — routing the
//      winner to PR is `level-pick-and-operator-levers`.
async function driveLevelDualBuild(activeItems, dual) {
  const boardWrites = [];
  log(
    `dual-build: tier=${dual.tier} baseline=${dual.baseline} candidate=${dual.candidate} ` +
      `in-scope=${activeItems.filter((it) => dual.inScope.has(it.slug)).length}/${activeItems.length} ` +
      '— building in-scope items under two arms; NO PR opens for an in-scope item until the level barrier clears',
  );

  // --- Phase 1 + the barrier ----------------------------------------------
  const runs = await parallel(
    activeItems.map((item) =>
      dualBuildGuarded(
        () => {
          if (!dual.inScope.has(item.slug)) {
            // Not in scope: the unchanged single-arm drive, including its PR.
            return driveItem(item)
              .catch((err) => escalate(item.slug, 'worker-error', { error: String((err && err.stack) || err) }))
              .then((r) => preserveOnEscalation(item, r))
              .then((r) => stampSideline(item, r))
              .then((record) => ({ item, inScope: false, record }));
          }
          return driveInScopeItem(item, dual, boardWrites);
        },
        // The IN-SCOPE throw (the not-in-scope branch carries its own catch
        // above, so this is what it adds). `escaped` marks a run that produced
        // NO arms: phase 3 hands its record straight to the level's disposition
        // rather than judging arms that do not exist or inventing a
        // not-in-scope ledger row for an item that IS in scope. No
        // preserveOnEscalation here on purpose — an in-scope item's commits
        // live in `<slug>@baseline` / `<slug>@candidate`, not the `<slug>`
        // worktree that helper pushes from, so calling it would push the wrong
        // (or an absent) tree.
        (err) => ({
          item,
          inScope: false,
          escaped: true,
          record: escalate(item.slug, 'worker-error', {
            error: String((err && err.stack) || err),
            phase: 'dual-build build phase',
          }),
        }),
      ),
    ),
  );
  log(
    `dual-build: LEVEL BARRIER reached — every in-scope arm has a gate result ` +
      `(${runs.filter((r) => r.inScope).reduce((n, r) => n + r.arms.filter((a) => a.gate === 'pass').length, 0)} passing arm(s) ` +
      `of ${runs.filter((r) => r.inScope).length * DUAL_BUILD_ARMS.length}). Judging before any PR opens.`,
  );

  // --- Phase 3: judge, record, dispose -------------------------------------
  const ledger = { appended: 0, rejected: 0, unavailable: 0 };
  const disposed = await parallel(
    runs.map((run) =>
      dualBuildGuarded(async () => {
      if (run.escaped) {
        // Phase 1's guard already converted this item's throw into an
        // escalation and it produced no arms — nothing to judge, no row to
        // write. Straight to the level's disposition.
        return run.record;
      }
      if (!run.inScope) {
        // One row for the item that was built ONCE, so the level's ledger
        // accounts for every item rather than only the compared ones. `arm` is
        // a closed two-value field in the ledger schema, so an uncompared build
        // is recorded on the BASELINE arm with an explicit `in_scope:false` —
        // never a third arm value the reader's schema does not know.
        const single = {
          arm: 'baseline',
          order: 1,
          model: run.item.model ?? dual.baseline,
          wt: `${input.repoRoot}.wt/${run.item.slug}`,
          wtBase: '',
          guardArmed: 'UNKNOWN',
          gate: run.record && run.record._kind === 'parked' ? 'pass' : 'fail',
          lossReason: run.record && run.record._kind === 'parked' ? null : 'infra',
          cost: null,
        };
        const r = await appendDualBuildRows(run.item, dual, [{
          row: dualBuildRow(run.item, dual, single, null, {
            in_scope: false,
            not_in_scope_reason: 'this item is not in the dual-build tier for this run — built once, on its own model',
          }),
          wt: single.wt,
          arm: 'not-in-scope',
        }]);
        ledger.appended += r.appended;
        ledger.rejected += r.rejected;
        if (r.unavailable) ledger.unavailable += 1;
        return run.record;
      }

      const judgeOutcome = await judgeArms(run.item, dual, run.arms);
      if (judgeOutcome.judged) {
        log(
          `[${run.item.slug}] dual-build judge: preference=${judgeOutcome.judge.preference} ` +
            `margin=${judgeOutcome.judge.margin} order_agreement=${judgeOutcome.judge.order_agreement}` +
            (judgeOutcome.prefersArm ? ` (prefers the ${judgeOutcome.prefersArm} arm)` : ' (tie — counts for neither arm)'),
        );
      } else {
        log(`[${run.item.slug}] dual-build judge: NO verdict (${judgeOutcome.reason}) — ${judgeOutcome.detail}`);
      }
      // A judged preference is a per-ITEM loss for the arm it did not prefer.
      // The LEVEL pick tallies these; it is not made here.
      const armRows = run.arms.map((a) => {
        const lossReason = a.lossReason
          ?? (judgeOutcome.judged && judgeOutcome.prefersArm && judgeOutcome.prefersArm !== a.arm ? 'judge' : null);
        const withLoss = { ...a, lossReason };
        return { row: dualBuildRow(run.item, dual, withLoss, judgeOutcome, {}), wt: a.wt, arm: a.arm };
      });
      const r = await appendDualBuildRows(run.item, dual, armRows);
      ledger.appended += r.appended;
      ledger.rejected += r.rejected;
      if (r.unavailable) ledger.unavailable += 1;

      const armSummaries = run.arms.map(dualBuildArmSummary);
      const passing = run.arms.filter((a) => a.gate === 'pass');
      const dualBuildRecord = {
        tier: dual.tier,
        baseline: dual.baseline,
        candidate: dual.candidate,
        arms: armSummaries,
        judge: judgeOutcome.judged ? judgeOutcome.judge : null,
        judge_unavailable_reason: judgeOutcome.judged ? null : judgeOutcome.reason,
        prefers_arm: judgeOutcome.prefersArm ?? null,
        barrier: 'held',
        awaiting: 'level-pick',
        rows_appended: r.appended,
        rows_rejected: r.rejected,
      };
      if (passing.length === 0) {
        // Nothing to pick from for this item. This ESCALATES rather than parks:
        // a level pick over an item with no gate-passing arm is not a choice,
        // and the two builds' worktrees are intact for a human to read.
        return escalate(run.item.slug, 'dual-build-arms-failed', {
          reason:
            `both arms of ${run.item.slug} failed to reach a gate-passing branch ` +
            `(${run.arms.map((a) => `${a.arm}: ${a.lossReason}`).join(', ')}) — there is nothing for the level pick to choose between`,
          dual_build: dualBuildRecord,
        });
      }
      // PARKED WITH NO PR. This is the barrier's visible form on the return
      // object: the item is disposed of (so the zero-disposition guard is
      // satisfied — it was, and the guard is right that a level disposing of
      // NOTHING is a contradiction), it carries every arm's result, and it
      // carries `pr: null` because opening one is precisely what the barrier
      // forbids until the pick. `acceptance_results` is EMPTY on purpose: the
      // arms' results are per-arm and live in `dual_build.arms[]`, and hoisting
      // one arm's to the top level would read as a pick nobody made.
      const record = park(run.item.slug, null, null, []);
      record.parked.dual_build = dualBuildRecord;
      record.parked.awaiting_pick = true;
      return record;
      },
      // A throw in the JUDGE/LEDGER/RECORD phase is the same silent-loss risk
      // as one in the build phase — the item would be dropped to `null` after
      // its arms had already been built. Surface it instead.
      (err) => escalate(run.item.slug, 'worker-error', {
        error: String((err && err.stack) || err),
        phase: 'dual-build judge/record phase',
      })),
    ),
  );

  return {
    results: disposed,
    summary: {
      tier: dual.tier,
      baseline: dual.baseline,
      candidate: dual.candidate,
      in_scope: activeItems.filter((it) => dual.inScope.has(it.slug)).map((it) => it.slug),
      not_in_scope: activeItems.filter((it) => !dual.inScope.has(it.slug)).map((it) => it.slug),
      barrier: 'held',
      awaiting: 'level-pick',
      rows_appended: ledger.appended,
      rows_rejected: ledger.rejected,
      ledger_unavailable_items: ledger.unavailable,
      board_writes: boardWrites,
    },
  };
}

// =============================================================================
// THE TWO PHASES OF driveItem (temperloop#2080, epic #2065 "dual-build")
// =============================================================================
// driveItem used to be ONE function that interleaved build → local gate → PR →
// CI per item. The dual-build harness cannot: ADR 0038 fixes the PICK at the
// LEVEL, so every in-scope item's build, local gate and pairwise judge must be
// known BEFORE any PR opens for the level (the "level barrier"). That is a
// phase split, not a flag — so the split is made STRUCTURAL here rather than
// left as an `if (dualBuild)` branch threaded through 700 lines:
//
//   driveItemBuildPhase()  3a claim → 3b worktree → 3c worker → 3d verdict →
//                          3e review → 3e.5 gate → 3e.6 activation gate.
//                          Returns a TERMINAL record (parked/escalation), or
//                          null having filled `box.ctx` with everything the
//                          second phase needs. NOTHING here pushes, opens a
//                          PR, or merges — that property is what makes the
//                          barrier expressible at all.
//   driveItemPr()          3f push+PR → 3g CI → 3g.5 re-render → 3h park.
//
// THE SINGLE-ARM PATH IS UNCHANGED BY CONSTRUCTION: driveItem() below calls
// both phases back to back, in the same order, with nothing between them — so
// the stage transcript, the agent-spawn sequence and the machinery step
// ordering a flag-less run produces are byte-for-byte what they were before
// the split (workflows/scripts/build/tests/test_workflow.sh pins the ORDERING
// explicitly, not merely the return object).
//
// WHY A `box` RATHER THAN A RETURNED CONTEXT. The build phase has ~25 early
// `return escalate(...)` / `return park(...)` sites. Rewriting every one of
// them into `{ result: … }` would be 25 chances to typo a control-flow edge
// that only one specific failure fixture exercises. Instead the phase function
// keeps EVERY existing return statement byte-identical (a terminal record, or
// null on the fall-through) and hands its context out through the one
// out-parameter — so the diff touches the fall-through alone.
// =============================================================================
async function driveItem(item) {
  const built = await driveItemBuild(item, null);
  if (built.result) return built.result;
  return await driveItemPr(built.ctx);
}

// driveItemBuild — the phase-1 wrapper. `arm` is null on the single-arm path
// (every /build, /fix and /sweep invocation that passes no `dualBuild` input)
// and a `{ name, sibling, slug, order }` descriptor on a dual-build arm, where
// `item` has ALREADY been arm-shaped by armItem() below (slug → `<slug>@<arm>`,
// branch → `build/<slug>@<arm>`, model → that arm's own model). Returns exactly
// one of `{ result }` (terminal) or `{ ctx }` (ready for phase 2).
async function driveItemBuild(item, arm) {
  const box = {};
  const terminal = await driveItemBuildPhase(item, arm ?? null, box);
  return terminal ? { result: terminal } : { ctx: box.ctx };
}

async function driveItemBuildPhase(item, arm, box) {
  const { repoRoot, board } = input;
  const worktreePath = `${repoRoot}.wt/${item.slug}`;

  // --- Continuation detection (escalation-resume loop, 3d-esc) --------------
  // On a 3d-esc continuation the orchestrator re-invokes this workflow with
  // input.onlySlugs = [<this slug>, ...] and input.verdicts[<slug>] carrying the
  // human's captured decision. A continued item's worktree + .build-guard
  // marker are ALREADY in place (the escalation left them intact) and its
  // board issue is ALREADY claimed — so we MUST NOT re-run 3a (claim) or 3b
  // (worktree.sh create force-recreates the path, discarding the escalated
  // build, MINOR fix). We resume at 3c, injecting the captured verdict so the
  // re-spawned worker sees the human's decision instead of re-forking forever
  // (MAJOR fix). verdicts map shape: { [slug]: { kind, verdict_section } }.
  const isContinuation =
    Array.isArray(input.onlySlugs) && input.onlySlugs.includes(item.slug);
  const verdictSection = isContinuation
    ? input.verdicts?.[item.slug]?.verdict_section
    : undefined;

  // --- PRELUDE (3a claim + 3b-0 deps-merged + 3b worktree create) ------------
  // ONE batched executor agent for the whole per-item mechanical prelude
  // (temperloop#942) instead of one agent spawn per command. Ordering, skip
  // conditions and every branch below are unchanged — only the transport is.
  // The batch's own bash short-circuit refuses to run a later step once an
  // earlier one's outcome means it must not (a failed claim never reaches
  // worktree create; an unmerged dep never creates a worktree), so the results
  // array is simply shorter and the .mjs escalates on the step that stopped it.
  const preludeSteps = [];
  const preludeAt = {}; // kind → index into preludeSteps / batch.results
  const addPrelude = (kind, cmd, continueOutcomes) => {
    preludeAt[kind] = preludeSteps.length;
    preludeSteps.push({ kind, cmd, continueOutcomes });
  };

  // 3a. Claim (claim-first), board ON only.
  // Claim-first applies to EVERY kind, spike included (build.md L312: "For a
  // spike: run 3a (claim, mark `[~]`), then spawn a read-only worker"). It is
  // therefore the FIRST step of the prelude and is branched on BEFORE the
  // kind:spike verdict-park below, so a spike-labeled item takes the
  // cross-session board lock before any investigation begins — without it, two
  // concurrent drivers could each pull and investigate the same spike with no
  // lock (temperloop#650).
  // Skipped on a continuation: the issue is already claimed by this run (the
  // escalation never released it), and a re-claim is at best a self-owned
  // no-op (spec 3d-esc step 4: "does NOT re-run 3a").
  //
  // ALSO skipped for a dual-build ARM (temperloop#2080). An in-scope item is
  // built TWICE, and a board write is a statement about the ITEM, not about one
  // arm of it: claiming per arm would write the same issue twice (the second
  // claim reading as a self-conflict), and the Done/close cascade must reflect
  // the arm that WON, which is not known until the level pick. So every board
  // write for an in-scope item is BUFFERED — bufferBoardWrite() below records
  // one entry per item, returned on the level's `dualBuild.board_writes` for
  // the pick to flush. The cross-session lock this costs is real and is the
  // declared trade of the barrier: the level's claims land in one batch after
  // the pick rather than at first touch.
  if (board && item.ghIssue && !isContinuation && !arm) {
    // The CLAIM entrypoint + --board are resolved by the orchestrator's Step 0
    // probe and passed in input.claimCmd (an absolute path to claim.sh).
    const claimBin = input.claimCmd ?? 'claim.sh';
    addPrelude(
      'claim',
      // claim.sh exits 0 on success; we wrap a contention/no-op check into the
      // executor by asking it to emit a CLAIMED/CLAIM_CONFLICT line. The
      // orchestrator's claim.sh itself sets In Progress + stamps Host/Session.
      `${sq(claimBin)} ${sq(item.ghIssue)} --board ${sq(board)} && ` +
        `echo '{"outcome":"CLAIMED"}' || echo '{"outcome":"CLAIM_CONFLICT"}'`,
      ['CLAIMED'],
    );
  }

  // 3b-0 / 3b are prelude steps only for a NON-spike item: a spike is read-only
  // and skips 3b–3h entirely, so it must never create a worktree. Its prelude is
  // the claim alone (or nothing at all when the board is OFF).
  //
  // 3b-0. Dep-merge precondition gate (#108).
  // A `depends-on` edge REQUIRES its target be [x] MERGED before this item's
  // worker starts — the worker must build and self-verify against the merged
  // dependency code, NOT a pre-merge base. The orchestrator's level ordering
  // (it runs level k's merge gate before invoking build-level for level k+1) is
  // the primary guarantee; this is the mechanical backstop that refuses to
  // create the worktree until every depended-on PR has actually landed in
  // origin/<default> (guarding a resume race, a partial merge, an ordering bug).
  // Without it, worktree.sh create bases the branch on an origin/<default> that
  // LACKS the dep, the worker self-verifies against stale code, and the 3f
  // unconditional rebase (#525) only repairs the branch TEXTUALLY at push —
  // too late for the worker's own build/verify. item.dependsOn is [{slug,sha}]
  // (each dep's merged head SHA, from the plan note's pushed_sha:); an
  // absent/empty list (level-0 or after:-only deps) is a no-op. Skipped on a
  // continuation — the worktree already exists and its base was gated at first
  // create; re-gating would need SHAs the continuation input does not carry.
  const depShas = isContinuation
    ? []
    : (item.dependsOn ?? []).map((d) => d && d.sha).filter(Boolean);
  if (item.kind !== 'spike' && depShas.length > 0) {
    const wtGateBin = machineryBin(repoRoot, 'worktree.sh');
    addPrelude(
      'deps-merged',
      `${wtGateBin} deps-merged ${sq(repoRoot)} ${sq(depShas.join(','))}`,
      ['DEPS_MERGED'],
    );
  }

  // 3b. Pre-create the deterministic worktree (worktree.sh create).
  // On a continuation we REUSE the existing worktree (MINOR fix): the escalated
  // item's worktree + its committed build + the .build-guard marker are all
  // intact, and worktree.sh create force-removes-and-re-adds (worktree.sh:113),
  // which would DISCARD the escalated build. So skip create entirely and resume
  // against the deterministic path. The injected verdict (3c) makes resuming on
  // the existing worktree correct — the worker builds on its own prior work
  // plus the human's decision, exactly the escalation-resume contract.
  //
  // temperloop#2080 adds TWO things to this one step, both of which leave a
  // flag-less, residue-free run's OUTPUT byte-identical:
  //
  //  (a) THE ARM FLAG. A dual-build arm creates `<repoRoot>.wt/<slug>@<arm>` on
  //      `build/<slug>@<arm>` via `create --arm <name>[:<sibling>]`
  //      (temperloop#2076). `item.slug` is already the ARM KEY here, so the
  //      command is built from `arm.slug` — the real plan slug — and the
  //      deterministic path worktree.sh returns equals `worktreePath` above by
  //      construction, exactly as it does on the arm-less path.
  //
  //  (b) THE FLAG-LESS-RESUME REFUSAL (ADR 0038's "Consequences"). A `/build`
  //      re-run over a level a dual build left half-finished must refuse
  //      LEGIBLY — never silently complete it single-arm, and never pick a side
  //      by accident. The signal is the arm worktrees themselves:
  //      `<repoRoot>.wt/<slug>@*` exists only while an arm of THIS slug is
  //      mid-flight (the pick deletes the losing arm's tree and `worktree.sh
  //      prune` reaps the rest), so it is precisely "partially dual-built" and
  //      nothing else. The ledger is deliberately NOT consulted: its rows
  //      outlive the run by `DUAL_BUILD_ARCHIVE_RETENTION_DAYS`, so a slug
  //      dual-built last week would refuse every ordinary build since.
  //
  //      The check is emitted INSIDE this step's own command rather than as a
  //      new probe step, and that is the load-bearing choice: a level-wide
  //      probe agent would add a spawn to every flag-less run, changing the
  //      very transcript this item's acceptance pins as unchanged. Here the
  //      clean path runs `worktree.sh create` and prints its CREATED line with
  //      nothing added — same step count, same agent count, same JSON.
  if (item.kind !== 'spike' && !isContinuation) {
    const wtBin = machineryBin(repoRoot, 'worktree.sh');
    const realSlug = arm ? arm.slug : item.slug;
    const armFlag = arm
      ? ` --arm ${sq(arm.sibling ? `${arm.name}:${arm.sibling}` : arm.name)}`
      : '';
    const createCmd = `${wtBin} create ${sq(repoRoot)} ${sq(realSlug)}${armFlag}`;
    addPrelude(
      'worktree',
      arm ? createCmd : dualBuildResidueGuard(repoRoot, item.slug, createCmd),
      ['CREATED'],
    );
  }

  const prelude = await runMachineryBatch(preludeSteps, {
    label: `prelude:${item.slug}`,
    slug: item.slug,
    bashTimeoutMs: BATCH_BASH_TIMEOUT_MS,
    phase: enterStage(STAGE_CLAIM), // 3a claim + 3b-0 deps-merged + 3b worktree
  });
  if (prelude.denied) {
    // temperloop#1819: deniedOrQuota — a quota death (canary cannot spawn) is
    // its own kind; a genuine denial keeps machinery-denied unchanged. The
    // worktree may not exist yet (the prelude is what creates it) — the
    // deterministic path is still named so the disposer knows where to look.
    return await deniedOrQuota(item.slug, {
      step: batchDeniedStep(prelude, 'prelude'),
      steps: prelude.steps,
      out: prelude.out,
    }, worktreePath);
  }
  // temperloop#1071 — a prelude step that outlived the liveness ceiling. Probed
  // with NO worktree path on purpose: the prelude is what CREATES the worktree,
  // so at this point there is nothing for recover-probe to read (and no push or
  // PR could exist yet). Escalates rather than re-running claim/worktree, either
  // of which would be a blind retry of a non-idempotent step.
  const preludeTimeout = timedOutStep(prelude.results);
  if (preludeTimeout) {
    return (await disposeStepTimeout(item, null, preludeTimeout, 'prelude')).escalation;
  }

  // 3a branch — unchanged decisions, read off the batch's first result.
  if (preludeAt.claim !== undefined) {
    const claimOut = batchStep(prelude, preludeAt.claim);
    if (claimOut.outcome === 'CLAIM_CONFLICT' || claimOut.outcome === 'ERROR') {
      return escalate(item.slug, 'claim-conflict', { claimOut });
    }
  }

  // --- kind: spike — read-only fork, NO push/PR (skip 3b–3h) ---------------
  // Runs AFTER 3a (claim-first) above so the spike is claimed before its
  // read-only verdict fork begins — matching build.md L312 and the kernel
  // claim-first contract (temperloop#650).
  if (item.kind === 'spike') {
    log(`[${item.slug}] spike — read-only verdict fork (no PR)`);
    let verdict;
    try {
      verdict = await agent(
        workerPrompt(
        item,
        worktreePath,
        '## Spike (read-only)\nProduce a verdict note + routed follow-up issue. ' +
          'No commits, no push, no PR. Return status=done with the note path/issue ' +
          'in `summary` and `verification_surface_path` pointing at your verdict note.',
      ),
      {
        label: `worker:${item.slug}`,
        phase: enterStage(STAGE_BUILD),
        // temperloop#982: item.model || undefined — see callWorker()'s
        // identical comment above; an empty-string item.model must collapse
        // to the inherit-session sentinel, not ride through as a literal "".
        model: item.model || undefined, // "" or undefined → inherit session model
        schema: WORKER_VERDICT_SCHEMA,
      },
      );
    } catch (err) {
      // temperloop#1819 — a thrown quota-death message classifies directly;
      // any other throw keeps its pre-#1819 path (the parallel() catch-all
      // converts it to a worker-error escalation, unchanged).
      const msg = String((err && err.message) || err);
      if (quotaDeath(msg)) {
        return quotaEscalation(item.slug, 'worker (spike)', { errorText: msg, worktree: null });
      }
      throw err;
    }
    if (verdict == null) {
      // temperloop#1819 — the bare-null shape carries no text; ask the canary
      // whether the harness can spawn agents at all before calling this a
      // content failure. A spike has no worktree (read-only), so `worktree: null`.
      if (!(await harnessCanSpawnAgents())) {
        return quotaEscalation(item.slug, 'worker (spike)', { worktree: null });
      }
      // agent() returned null — user skip or terminal API error. Spikes are
      // read-only so no retry applies; escalate immediately.
      return escalate(item.slug, 'worker-error', { retryable: true, reason: 'agent returned null (spike worker)' });
    }
    if (verdict.status !== 'done') {
      return escalate(item.slug, verdict.status, { verdict });
    }
    // Spike parks as a verdict marker (no pr/pushed_sha). The orchestrator
    // turns this into a [v] sentinel + Done/close at the boundary.
    return park(item.slug, null, null, verdict.acceptance_results);
  }

  // --- 3b-0 branch. Dep-merge precondition gate (#108) ---------------------
  // The gate itself ran as prelude step `deps-merged` above; the DECISION is
  // here, in .mjs, reading that step's own DEPS_MERGED/DEPS_UNMERGED object.
  if (preludeAt['deps-merged'] !== undefined) {
    const depOut = batchStep(prelude, preludeAt['deps-merged']);
    if (depOut.outcome !== 'DEPS_MERGED') {
      // A depended-on PR has NOT merged to origin/<default>. Do NOT create the
      // worktree and do NOT spawn a worker — surface it so the orchestrator/human
      // resolves the ordering. Nothing is built against a stale base. (The batch's
      // own short-circuit already refused to run the worktree-create step, so
      // nothing was built against the pre-merge base either.)
      return escalate(item.slug, 'dep-not-merged', { depOut });
    }
  }

  // --- 3b branch. The deterministic worktree (worktree.sh create) ----------
  let wt = worktreePath;
  // temperloop#2080 — the two fields a dual-build ledger row reads off the
  // CREATED line: the base the arm branched from, and worktree.sh's OWN
  // write-jail arming verdict (ARMED/UNARMED/UNKNOWN, its § Write-jail arming
  // self-test). Captured here because this is the only place they exist;
  // defaulted so a continuation (which skips create) still produces a
  // well-formed row rather than one the ledger validator rejects.
  let wtBase = '';
  let wtGuard = 'UNKNOWN';
  if (preludeAt.worktree !== undefined) {
    const wtOut = batchStep(prelude, preludeAt.worktree);
    if (wtOut.outcome === 'DUAL_BUILD_RESIDUE') {
      // The flag-less-resume refusal (see the guard's own comment at 3b). This
      // is NOT a worktree failure: nothing was attempted, nothing was
      // destroyed, and the arm worktrees still hold their builds. It refuses
      // under its own kind so the disposition is "re-run with --dual-build, or
      // finish the pick", never "retry the create".
      return escalate(item.slug, 'dual-build-residue', {
        slug: item.slug,
        arms: wtOut.arms ?? null,
        reason:
          `REFUSING to build ${item.slug} single-arm: this level was left PARTIALLY DUAL-BUILT — ` +
          `arm worktree(s) for this slug still stand at ${repoRoot}.wt/${item.slug}@*. A flag-less /build ` +
          'would either rebuild the item a third time on the session model or silently adopt one arm, ' +
          'and neither is a level pick (ADR 0038). Re-run /build with --dual-build to finish the pick, or ' +
          'dispose the arms deliberately first.',
        remedy:
          `ls -d ${repoRoot}.wt/${item.slug}@*   # then either: /build --dual-build <tier>=<candidate> ` +
          `(resume the comparison), or: worktree.sh remove ${repoRoot} '${item.slug}@<arm>' for each arm ` +
          'once you have archived what you want to keep',
      });
    }
    if (wtOut.outcome !== 'CREATED') {
      return escalate(item.slug, 'worktree-failed', { wtOut });
    }
    wtBase = typeof wtOut.base === 'string' ? wtOut.base : '';
    wtGuard = wtOut.guard === 'ARMED' || wtOut.guard === 'UNARMED' ? wtOut.guard : 'UNKNOWN';
    // worktree.sh's CREATED.path is the authoritative deterministic path; it
    // equals worktreePath by construction, but trust the script's value.
    wt = wtOut.path ?? worktreePath;
    // temperloop#2006 — READ the sideline verdict the CREATED line already
    // carries. `create` never refuses, so an occupied path yields CREATED
    // either way; the only thing that distinguishes "created over nothing"
    // from "shelved a resumable build and created over the freed path" is
    // this field, and dropping it is what made the shelf invisible.
    noteSideline(item.slug, wtOut);
  }

  // --- 3c. Spawn the worker (NO isolation:'worktree' — DESIGN NOTE 3) ------
  // On a continuation, inject the captured human verdict (## Design verdict /
  // ## User answers) as the worker's extra section so it sees the decision
  // instead of re-forking forever (MAJOR fix). On a fresh drive verdictSection
  // is undefined → workerPrompt emits no extra section, unchanged behavior.
  let recovery = null; // temperloop#939 — set only on a lost-return recovery
  // temperloop#2065 — the main worker's cost, accumulated across BOTH this
  // call and the #993/#1219 foreground-cure retry below (see
  // mergeWorkerCost()). Distinct from the CI-fix retry's own retryTokens/
  // retryCount (ciPollLoop) — this accumulator is "worker tokens", the
  // ledger's OTHER figure.
  let mainCost = { wallClockMs: null, tokensIn: null, tokensOut: null };
  let w = await callWorker(item, wt, verdictSection, `worker:${item.slug}`, enterStage(STAGE_BUILD));
  mainCost = mergeWorkerCost(mainCost, w);
  let verdict = w.verdict;
  if (verdict == null) {
    // temperloop#1819 — classify a session-quota death FIRST, before the probe
    // and the retry: under an exhausted quota every further spawn (the probe,
    // the retry, its probe) dies the same death, and the work already in the
    // worktree is exactly what the quota-exhausted disposition preserves.
    if (await workerQuotaDeath(w)) {
      return quotaEscalation(item.slug, 'worker', {
        errorText: w.nullReturn ? null : w.error,
        worktree: wt,
      });
    }
    // No verdict — either agent() returned null (user skip, transient 5xx, or the
    // #1219 background-stall) or it THREW (StructuredOutput absent / retry cap
    // blown). Neither tells us anything about the WORK, so before doing anything
    // else, LOOK (temperloop#939): probe the observable side-effects. This runs
    // BEFORE the retry deliberately — re-spawning a worker onto a worktree that
    // already holds the finished commit is the duplicate-PR / stacked-commit
    // hazard #939 names, and it costs a full worker run to discover.
    let probe = await probeSideEffects(item, wt);
    if (probe.landed) {
      recovery = probe;
    } else {
      // Nothing COMMITTED → this is the ordinary stall. Retry exactly once,
      // appending FOREGROUND_CURE so the retry prompt DIFFERS from the first — a
      // byte-identical retry re-stalls identically. A 5xx is transient (the extra
      // section is harmless); a stall is cured by it.
      //
      // temperloop#993 — MECHANICAL detection of the incomplete-return shape:
      // no verdict AND the worktree dirty with zero commits is the backgrounded-
      // gate stall specifically (not a worker that never started). The probe
      // reports it as RECOVER_DIRTY, and the auto-resume carries the dirty-resume
      // note on top of the cure so the re-spawn CONTINUES on the work already in
      // the worktree instead of rebuilding it. Detection is mechanical here so the
      // prose clause in the worker prompt (prevention) is not the only guard —
      // build.md §3c/§3d stay in lockstep with this block.
      if (probe.stalled) {
        log(`[${item.slug}] worker returned no verdict; ${probe.dirtyFiles} uncommitted path(s), 0 commits — the #993 backgrounded-gate stall: auto-resuming on the same worktree (foreground cure)`);
      } else {
        log(`[${item.slug}] worker returned no verdict, no side-effects — retrying once (foreground cure #1219)`);
      }
      w = await callWorker(item, wt, withCure(verdictSection, probe.dirtyFiles, item.slug), `worker:${item.slug}#retry`, enterStage(STAGE_BUILD));
      mainCost = mergeWorkerCost(mainCost, w);
      verdict = w.verdict;
      if (verdict == null) {
        // temperloop#1819 — the RETRY can be the spawn that crosses the quota
        // boundary; classify it before spending another probe on a dead harness.
        if (await workerQuotaDeath(w)) {
          return quotaEscalation(item.slug, 'worker (retry)', {
            errorText: w.nullReturn ? null : w.error,
            worktree: wt,
          });
        }
        // The retry may itself have built and lost its return — probe again.
        probe = await probeSideEffects(item, wt);
        if (probe.landed) recovery = probe;
      }
    }
    if (verdict == null) {
      if (!recovery) {
        // GENUINELY nothing committed — the unchanged escalation path. When the
        // probe still sees a dirty worktree (temperloop#993), say so in the
        // payload: the auto-resume did not cure it, and whoever disposes this
        // escalation must know there is UNCOMMITTED WORK in the worktree before
        // choosing "skip" (which prunes the worktree and destroys it).
        return escalate(item.slug, 'worker-error', {
          retryable: true,
          reason: probe.stalled
            ? `worker returned no verdict after a foreground-instructed re-spawn; ${probe.dirtyFiles} uncommitted path(s) and 0 commits remain in the worktree (temperloop#993) — inspect the worktree before skipping (skip prunes it)`
            : (w.error ?? 'agent returned no verdict after one retry (main worker)'),
          ...(probe.stalled ? { shape: 'foreground-stall', dirty_files: probe.dirtyFiles, worktree: wt } : {}),
        });
      }
      log(`[${item.slug}] worker return lost (${w.error}) — recovered from side-effects at ${recovery.stage}; acceptance UNVERIFIED`);
      verdict = recoveredVerdict(item, recovery, w.error);
    }
  }

  // --- 3d. Branch on the verdict -------------------------------------------
  // Only `done` with all acceptance bullets passing continues. blocked /
  // design-fork / failed escalate (the orchestrator drives the human round-trip
  // and re-drives the item; we leave the worktree intact). A `done` with any
  // passed:false is treated as blocked.
  if (verdict.status !== 'done') {
    return escalate(item.slug, verdict.status, { verdict });
  }
  // temperloop#1182: a host-config DEFERRAL (`passed: false` + a non-empty
  // `deferred_host_config`) is excluded here — it is not a failure, it is a
  // criterion this worker structurally could not observe, re-homed to the
  // orchestrator's parent-side check at build.md §4a. Escalating it would
  // stall the level on a reading that is `false` in every worktree on every
  // host regardless of the truth (foundation#1556). A bare `passed: false`
  // with no marker escalates exactly as before — the exclusion is the pair,
  // never the boolean alone, so this cannot silently swallow a real failure.
  const anyFailed = (verdict.acceptance_results ?? []).some(
    (r) => r.passed === false && !isHostConfigDeferral(r),
  );
  if (anyFailed) {
    return escalate(item.slug, 'acceptance-incomplete', { verdict });
  }
  // temperloop#1319 degraded case: computed once here (empty when
  // REQUIRE_DISCRIMINATION_EVIDENCE is unarmed), logged as a named warning at
  // 3h below once `pr` is known, and threaded to park() for the Step 6 tally.
  const discGaps = discriminationGaps(verdict);

  // --- 3e. Mandatory/routed pre-push review (temperloop#1430) --------------
  // Runs HERE — between 3d and 3e.5, inside this driver — spawning the routed
  // reviewer(s) itself via `agent({agentType})`. See build.md §3e's own "why
  // this runs inside the workflow, not the orchestrator" paragraph: by the
  // time this driver RETURNS to the orchestrator, the item is already pushed
  // with its PR open (irreversible), and the orchestrator's post-return
  // partition removes the parked item's worktree — the tree a review would
  // need to inspect. A loop-back to 3c is only reachable from INSIDE
  // driveItem, never after. (This driver does NOT merge: build.md §3h.5's
  // as-you-go merge is conversational-path-only — temperloop#1452.)
  const review = await runReviewers(item, wt);
  if (review.escalation) return review.escalation;
  if (review.blocking.length > 0) {
    // temperloop#1970 — the convergence bound. Under it, a HIGH escalates
    // exactly as before (byte-identical for every item that converges within
    // its round budget). AT it, the loop stops: the item proceeds to 3e.5/3f
    // and the residual findings ride the PR body's `## Review notes` (via
    // reviewBodySuffix below, which already renders review.sections in full)
    // plus the parked record's `review.residual_blocking` tally, so the human
    // at the merge gate reads them. Findings are carried, never suppressed.
    if (!reviewBoundReached(review)) {
      return escalate(item.slug, 'review-blocking', {
        findings: review.blocking,
        round: review.round,
        max_rounds: REVIEW_BLOCKING_MAX_ROUNDS,
      });
    }
    review.residualBlocking = true;
    log(
      `[${item.slug}] §3e review round ${review.round}/${REVIEW_BLOCKING_MAX_ROUNDS} still has ` +
        `${review.blocking.length} BLOCKING finding(s) — convergence bound reached (temperloop#1970): ` +
        `opening the PR with them carried in ## Review notes instead of escalating again ` +
        `(${review.blocking.map((b) => b.reviewer).join(', ')})`,
    );
  }
  // Carried into the PR body at 3f below (verdictJson.summary) — the PR must
  // carry REAL evidence a review ran (or a legible, non-guaranteed skip
  // notice), never silently read as if the gate had passed by default.
  // `notes` (temperloop#1450) is the reviewer's FULL findings text, rendered
  // as its own `## Review notes` section so a non-blocking (MEDIUM/LOW-only)
  // pass is still visible to the human reviewer — not computed, checked for
  // HIGH, and thrown away. Rendered via reviewBodySuffix (temperloop#1846) —
  // the SAME renderer 3g.5's post-CI-fix re-render uses, so the two surfaces
  // can never drift; with the single round it renders the pre-#1846 shape
  // byte-identically.
  const reviewSummarySuffix = reviewBodySuffix([review]);

  // Resolve the gate script from the WORKTREE, not repoRoot (temperloop#626).
  // The point of 3e.5 is to validate the worker's CHANGES, and the `cd ${wt}`
  // below intends exactly that — but quality-gates.sh's first act is
  // `cd "$REPO_ROOT"` where REPO_ROOT is derived from the SCRIPT's own path
  // (BASH_SOURCE/..). If we ran repoRoot's copy, that cd would jump straight
  // back to the main checkout and the gate would validate main's tree, not the
  // worktree — silently defeating the cd. Running the worktree's own copy makes
  // REPO_ROOT resolve to the worktree, so every gate (make targets, the
  // diff-scoped leak guard that diffs the branch's additions, the freshness
  // check) runs against the worker's tree — matching what CI sees on the PR's
  // merge. The worktree is a full checkout of the branch, so this copy always
  // exists whenever repoRoot's would (GATE_ABSENT still fires for a repo with
  // no vendored gate). Only build-SPINE scripts (worktree.sh / pr.sh / …) route
  // through machineryBin's foundation fallback; the repo-local gate resolves
  // directly against the worktree.
  //
  // Resolved BEFORE the freshness step below (round 3, HIGH, temperloop#1937)
  // so runGateFreshness() can gate itself behind the identical presence check
  // gateCmd's own GATE_ABSENT arm makes — a project with no vendored gate
  // script has nothing for the freshness step to protect.
  const qgBin = `${wt}/scripts/quality-gates.sh`;

  // --- 3e.5-pre. Gate-freshness rebase (temperloop#1937) --------------------
  // Bring the worktree up to current origin/main BEFORE the acceptance gate
  // below runs — see runGateFreshness()'s own header for the full rationale
  // (origin/main-ratcheted validators false-failing on a worktree that went
  // stale mid-build; the live temperloop#1934 incident this item fixes).
  // Strictly between §3e review and §3e.5: a conflicting rebase must escalate
  // BEFORE quality-gates.sh ever runs, never after a wasted gate slice.
  const freshness = await runGateFreshness(item, wt, qgBin);
  if (freshness) return freshness;

  // --- 3e.5. Parent-side acceptance gate (quality-gates.sh) ----------------
  // Run the project's static gate SSOT against the worker's work. ABSENT (the
  // script doesn't exist, e.g. foundation itself) → skip. FAIL → escalate
  // (do NOT push a known-red branch). The executor synthesizes GATE_PASS /
  // GATE_FAIL / GATE_ABSENT so the .mjs branches on a closed outcome.
  // temperloop#1241: SCRUB the pipeline's own build.config.sh settings from the
  // gate's environment before running the suite. Under pipeline-drive the session
  // exports ~40 build.config.sh settings; the config-precedence tests the gate runs
  // (test_config.sh / test_stranger_config.sh / test_pipeline_cron.sh) assert layer
  // precedence (env > machine-conf > repo-local > tracked-default), so an
  // inherited setting wins the env layer and false-FAILs a change CI's `checks`
  // passes green. `build-config-settings.sh` prints the (SSOT-derived) setting names;
  // unsetting them makes the gate hermetic — tracked defaults, matching CI. A
  // missing/older helper prints nothing → `unset` no-op → prior behavior.
  const settingsBin = `${wt}/workflows/scripts/build/build-config-settings.sh`;
  // gateCmd(startAt) — one SLICE of the suite (temperloop#1021).
  //
  // The budget is handed to quality-gates.sh as ENV VARS, deliberately not
  // flags: a consuming repo vendoring an OLDER quality-gates.sh ignores an
  // unknown env var and runs the whole suite in one go (today's exact behavior,
  // and still correct), whereas an unknown FLAG would exit 2 "usage" and read
  // back here as a gate failure. So this is compatible with every vendored copy
  // in the fleet with no probing.
  //
  // Exit-code protocol: 0 = finished green, 75 = budget spent with gates
  // remaining (the script printed QUALITY_GATES_RESUME_AT= / QUALITY_GATES_FAILED=),
  // anything else = red. Note the 75 arm is only ever taken by a slice-aware
  // script, so an older copy can only ever produce GATE_PASS / GATE_FAIL.
  //
  // `set -o pipefail` is LOAD-BEARING (temperloop#68 — see build.md §3e.5).
  // The gate verdict is derived from the subshell's own exit status, and since
  // temperloop#2094 that subshell IS piped — through `tee`, so one slice's
  // output can be isolated for trailer parsing while still STREAMING into the
  // cumulative operator log (see gateSliceLog below for why both are required).
  // A bare pipe's status reflects the LAST stage (tee's 0), which would swallow
  // a RED gate and degrade 3e.5 to a silent no-op; with pipefail set, the gate's
  // own non-zero exit propagates to `$?` and GATE_FAIL is still emitted. This is
  // the exact case build.md §3e.5 permits ("if the gate must be piped, `set -o
  // pipefail` first"), and the exit is read as a bare `$?` — NOT through
  // PIPESTATUS[0], a bash array that expands empty under the zsh this harness's
  // Bash tool actually runs, which is temperloop#801's misread.
  //
  // The log is truncated on the first slice and APPENDED to thereafter, so
  // /tmp/qg-<slug>.log stays the single artifact an operator reads, carrying the
  // union of every slice exactly as an unsliced run's log did.
  const gateLog = `/tmp/qg-${item.slug}.log`;
  // ONE SLICE'S OWN OUTPUT, kept separate from the cumulative log above
  // (temperloop#2094). The trailers below (`QUALITY_GATES_FAILED=`,
  // `QUALITY_GATES_RESUME_AT=`, `QUALITY_GATES_SELECTION=`) are read with
  // `tail -1`, so reading them out of the APPENDED log silently answers a
  // question about THIS slice with the previous slice's numbers whenever this
  // slice printed none of its own — a slice killed before it could report, or
  // one whose `cd`/`unset` prelude failed, inherits a resume point and a
  // failure count it never established. The trailers are therefore parsed from
  // HERE, never from the cumulative log: a trailer present in this file was
  // printed by the slice just run, which is what makes the classifier below
  // able to trust it.
  //
  // IT IS A TEE, NOT A REDIRECT-THEN-COPY (review round 1). Writing the slice
  // to this file and `cat`-ing it into ${gateLog} afterwards bought the
  // isolation above at the cost of the guarantee that matters most on the one
  // path that has no other diagnostic: the executor KILLS this whole command at
  // GATE_BASH_TIMEOUT_MS, and a copy step scheduled after the gate never runs.
  // The killed slice's partial output — the only evidence a timeout produces —
  // would never reach /tmp/qg-<slug>.log, the single artifact the escalation
  // payload hands the operator; and with the first-slice truncation moved into
  // that same copy, a timed-out first slice would leave the PREVIOUS run's log
  // in place and the escalation would point at stale content presented as
  // current. So ${gateLog} is truncated UP FRONT on slice 0 and the gate streams
  // into both files through `tee` — per-slice isolation and live, kill-proof
  // streaming at once. `set -o pipefail` is at the head of the command, so the
  // pipeline's `$?` is still the gate's own status (`tee` exits 0); the bare
  // `$?` read is deliberate and dialect-safe — PIPESTATUS[0] is a bash
  // array that expands EMPTY under the zsh this harness's Bash tool runs
  // (temperloop#801), which is the misread that swallows a red gate.
  const gateSliceLog = `${gateLog}.slice`;
  // temperloop#1663: run the acceptance gate DIFF-SCOPED — only the gates this
  // item's own changed paths can reach, resolved through gate-paths.tsv.
  //
  // WHY. The full per-item suite could not survive within-level parallelism, and
  // the ceiling it hit is not tunable. Measured on a 3-item level: 55 minutes,
  // 21 agents, 1.24M subagent tokens, ZERO items landed — all three escalated
  // `acceptance-gate-timeout` with every worker finished and committed and only
  // the verdict missing. Three concurrent full suites is 3x QUALITY_GATES_JOBS
  // workers on one machine; contention inflated the gate tail 200-300% (gates
  // that take seconds took 121s), while GATE_SLICE_SECS_MAX sits only 20% above
  // the budget that failed and CANNOT be raised past AGENT_BASH_CAP_MS. So the
  // suite has to get SHORTER, not the budget longer — and the map that knows
  // which gates a diff can reach already exists and was already trusted.
  //
  // WHY IT IS SAFE. This puts §3e.5 on exactly the same footing as the
  // `pull_request` run of CI's `checks` job, which has been scoped through this
  // same map since #1024 — so scoping here adds no failure mode that the PR
  // check does not already carry. What actually gates `main` is the UNSCOPED
  // merge_group run, and that is untouched. Every resolution failure in the
  // selector widens to the full set (gate-selection.sh's four silent-green
  // defenses), and a scoped run names every gate it skipped, twice.
  //
  // THE SEAM IS AN ENV VAR, NOT THE `--scoped` FLAG, for the same reason the
  // slice budget below is: a consuming repo vendoring an OLDER quality-gates.sh
  // ignores an unknown env var and runs the whole suite (the pre-#1663 behavior,
  // still correct), whereas an unknown FLAG exits 2 "usage" and reads back here
  // as a GATE FAILURE.
  //
  // BUILD_GATE_SCOPED is read HERE, in the emitted shell, rather than plumbed in
  // as an orchestrator `input.*` key like gateSliceSecs. That is deliberate and
  // is the narrower seam, not a shortcut: gateSliceSecs must reach the .mjs's
  // OWN control flow (it derives GATE_BASH_TIMEOUT_MS and bounds the slice
  // loop), and the Workflow runtime has no shell to source build.config.sh with
  // — DESIGN NOTE 1. This value is needed ONLY inside the command string, which
  // is bash, and it is read from the WORKTREE'S config, i.e. the version of the
  // setting the change under test actually ships. The read is a subshell so the
  // #1241 scrub below still governs the gate's own environment; an absent or
  // older config file leaves `${BUILD_GATE_SCOPED:-1}` at the default.
  const configBin = `${wt}/workflows/scripts/build/build.config.sh`;
  const gateScopeEnv =
    `QUALITY_GATES_SCOPED=$(. ${sq(configBin)} >/dev/null 2>&1; echo "\${BUILD_GATE_SCOPED:-1}")`;
  // SLICE-STABLE SELECTION (temperloop#1663). `QUALITY_GATES_START_AT` is an
  // ORDINAL into the gate list, and now that the list can be a SCOPED subset
  // re-derived from a live working-tree probe, two slices of one suite could
  // resolve DIFFERENT lists — leaving the ordinal pointing at a different gate,
  // silently skipping one, and still exiting 0. Before scoping, §3e.5 always
  // resolved the static full array, so the ordinal was stable by construction.
  //
  // The pin file is the prevention half: slice 0 writes the resolved changed set
  // there and every later slice reads it instead of re-probing, so the selection's
  // INPUT cannot move mid-suite. It is removed on slice 0 for the same reason the
  // log is truncated there — a re-drive must not inherit a previous attempt's
  // state.
  //
  // The fingerprint is the detection half behind it: each slice reports the
  // identity of the list its resume index was measured in, and the next slice is
  // handed it back. On a mismatch the gate restarts from 0 on the FULL set and
  // says so, rather than resuming an index that no longer means anything.
  const gatePin = `/tmp/qg-${item.slug}.selection-pin`;
  const gateCmd = (startAt, expectSelection) =>
    `set -o pipefail; if [ ! -x ${sq(qgBin)} ]; then echo '{"outcome":"GATE_ABSENT"}'; ` +
    `else ${startAt === 0 ? `rm -f ${sq(gatePin)} ${sq(gateSliceLog)}; : >${sq(gateLog)}; ` : ''}` +
    `( cd ${sq(wt)} && unset $(bash ${sq(settingsBin)} 2>/dev/null) && ` +
    `${gateScopeEnv} QUALITY_GATES_SELECTION_PIN=${sq(gatePin)} ` +
    `${expectSelection ? `QUALITY_GATES_EXPECT_SELECTION=${sq(expectSelection)} ` : ''}` +
    `QUALITY_GATES_START_AT=${startAt} QUALITY_GATES_BUDGET_SECS=${GATE_SLICE_SECS} ${sq(qgBin)} ) ` +
    `2>&1 | tee ${sq(gateSliceLog)} >>${sq(gateLog)}; __rc=$?; ` +
    `__el=$(sed -n 's/.*passed in \\([0-9]*\\)s.*/\\1/p;s/.*of [0-9]* in \\([0-9]*\\)s.*/\\1/p' ${sq(gateSliceLog)} | tail -1); ` +
    `__f=$(sed -n 's/^QUALITY_GATES_FAILED=//p' ${sq(gateSliceLog)} | tail -1); ` +
    `__r=$(sed -n 's/^QUALITY_GATES_RESUME_AT=//p' ${sq(gateSliceLog)} | tail -1); ` +
    // THE RESUME POINT IS LOAD-BEARING, SO ITS SHAPE IS CHECKED (review round 1).
    // Dropping the old `[ "$__rc" = 75 ]` co-condition removed the only
    // cross-check on a value that is matched against the whole slice log, gate
    // output included, and then interpolated RAW into JSON by `%s` below. A
    // non-numeric or half-written trailer would emit a syntactically invalid
    // line, which lands in the executor's "outside the closed set" path instead
    // of being classified. Anchoring to digits here is the whole defense: a
    // reading that is not a plain integer is treated as ABSENT, exactly as a
    // missing trailer already is. (`0` is not a resume point either — the
    // trailer is only ever printed with gates REMAINING — and gateSliceResumeAt()
    // already drops it downstream.)
    `case "$__r" in ''|*[!0-9]*) __r='' ;; esac; ` +
    `__s=$(sed -n 's/^QUALITY_GATES_SELECTION=//p' ${sq(gateSliceLog)} | tail -1); ` +
    // AN UNKNOWN ELAPSED IS `null`, NEVER `0` (temperloop#1698). `__el` is a
    // best-effort sed over the slice log: a vendored gate whose summary line
    // this pattern does not match, or a slice killed before printing one,
    // leaves it EMPTY. The old `${__el:-0}` turned that straight into a
    // confident `"elapsedSecs":0` — a plausible-looking number in place of an
    // admission that the figure is unknown, on the one instrument built to make
    // suite growth visible. Emitting JSON `null` instead makes the consumer's
    // strict read (numOrNull) return null and render `?`.
    `case "$__el" in ''|*[!0-9]*) __elj=null ;; *) __elj=$__el ;; esac; ` +
    // temperloop#865 — CLASSIFY THE WORKER'S OWN GATE SENTINEL, parent-side.
    // The worker is handed a gate invocation that always writes a result
    // sentinel (workerGateCmd below); this reads that artifact from the very
    // worktree the acceptance gate is about and reports one of four words. It
    // is how a worker that BACKGROUNDED its gate and abandoned it becomes
    // distinguishable, in the driver's own log and in the gate payload, from a
    // worker whose gate was merely slow — the #865 acceptance criterion that a
    // re-worded warning cannot meet. Read-only, fail-open: a repo whose workers
    // predate the sentinel reports 'absent' and nothing changes.
    `__wg=absent; if [ -f ${sq(workerGateSentinel(item.slug))} ]; then ` +
    `case "$(cat ${sq(workerGateSentinel(item.slug))} 2>/dev/null)" in ` +
    `*'"state":"finished"'*) __wg=finished ;; *'"state":"running"'*) __wg=running ;; *) __wg=unknown ;; esac; fi; ` +
    // A RESUME POINT THIS SLICE PRINTED IS THE VERDICT (temperloop#2094).
    // quality-gates.sh emits `QUALITY_GATES_RESUME_AT=` on exactly one path:
    // it spent its budget, stopped CLEANLY BETWEEN GATES, and is telling the
    // caller where the remaining gates start. That is a PARTIAL slice by
    // construction, and its own `QUALITY_GATES_FAILED=` line is the count it
    // established. Keying the branch on the exit code INSTEAD made that fact
    // conditional on a number the script prints the trailer before producing:
    // one unexpected code — a SIGTERM after the trailer, a wrapper that
    // remapped the status — and a clean partial was relabelled GATE_FAIL,
    // where gateSliceFailed()'s "RED by construction" floor manufactured the
    // one failure the slice had just reported as zero. Observed live: three
    // slices, `QUALITY_GATES_FAILED=0` in every one, stopped at gate 152 of
    // 200, reported `verdict: RED, failedGates: 1, suiteFinished: true`.
    // So the resume point is checked FIRST and on its own; `$__rc` rides along
    // as `rc` for the record (75 is the protocol code, anything else is an
    // anomaly worth seeing in the ledger, neither changes the classification).
    // Safe against a stale trailer because ${gateSliceLog} holds THIS slice's
    // output alone — see its declaration above.
    `if [ -n "$__r" ]; then ` +
    `printf '{"outcome":"GATE_SLICE","resumeAt":%s,"failed":%s,"elapsedSecs":%s,"selection":"%s","rc":%s,"workerGate":"%s","budgetSecs":${GATE_SLICE_SECS}}\\n' "$__r" "\${__f:-0}" "$__elj" "$__s" "$__rc" "$__wg"; ` +
    `elif [ "$__rc" = 0 ]; then ` +
    `printf '{"outcome":"GATE_PASS","failed":0,"elapsedSecs":%s,"workerGate":"%s","budgetSecs":${GATE_SLICE_SECS}}\\n' "$__elj" "$__wg"; ` +
    `else printf '{"outcome":"GATE_FAIL","failed":%s,"elapsedSecs":%s,"rc":%s,"workerGate":"%s","budgetSecs":${GATE_SLICE_SECS}}\\n' "\${__f:-1}" "$__elj" "$__rc" "$__wg"; fi; fi`;

  // Drive slices until the suite finishes. GATE_SLICE is the ONLY outcome that
  // continues the loop; everything else is terminal on the first pass, so a
  // repo whose suite fits in one slice (or whose vendored gate predates the
  // seam) behaves exactly as it did before — one call, one outcome.
  let gateOut = null;
  let gateStartAt = 0;
  let gateElapsed = 0;
  // temperloop#1698 — sticky once ANY slice reported no usable elapsed figure.
  // The total is then UNKNOWN, not a partial sum presented as the whole: a run
  // that summed 140s of three slices because the other two reported nothing is
  // the same confident-wrong-number defect one level up.
  let gateElapsedUnknown = false;
  let gateSlices = 0;
  // The selection fingerprint the PREVIOUS slice reported (temperloop#1663).
  // Empty on the first slice — there is nothing to compare a fresh start against,
  // and an older vendored quality-gates.sh reports none at all, in which case this
  // stays empty forever and the gate behaves exactly as it did before.
  let gateSelection = '';
  // gateSliceLedger — the AUTHORITATIVE record of what this gate run found
  // (temperloop#1587): one entry per slice that actually ran, carrying that
  // slice's own outcome and normalized failure count (gateSliceFailed()).
  // Every failure figure reported below — the payload's `failedGates`, the
  // verdict, the escalation kind — is DERIVED from this array by
  // gateVerdict(); no independent running counter is maintained alongside it,
  // because two counters that can disagree is exactly the defect #1587 filed.
  const gateSliceLedger = [];
  for (; gateSlices < GATE_MAX_SLICES; gateSlices++) {
    gateOut = await runMachinery(gateCmd(gateStartAt, gateSelection), {
      label: `gate:${item.slug}`,
      slug: item.slug,
      phase: enterStage(STAGE_GATE),
      // temperloop#115/#1021: without an explicit timeout the executor's Bash
      // tool kills the suite at its 120s default. GATE_BASH_TIMEOUT_MS is now
      // DERIVED from the slice budget (see the tunables block) and is an outer
      // BACKSTOP — the slice's own soft budget is what normally ends a slice.
      bashTimeoutMs: GATE_BASH_TIMEOUT_MS,
      // …and if that backstop DOES fire, the executor reports GATE_TIMEOUT, not
      // a guessed GATE_FAIL. This is the acceptance criterion of #1021: a
      // budget-exhausted run must be distinguishable from real breakage.
      timeoutOutcome: 'GATE_TIMEOUT',
    });
    if (machineryDenied(gateOut)) {
      // temperloop#1819: the #1819 incident's own machinery shape — a gate
      // step killed by the session limit read as SPINE_DENIED. deniedOrQuota
      // re-classifies it via the canary; a genuine denial is unchanged.
      return await deniedOrQuota(item.slug, { step: 'gate', out: gateOut }, wt);
    }
    // temperloop#1071 — the gate slice outlived the workflow liveness ceiling.
    // Distinct from GATE_TIMEOUT (the Bash tool's own timeout, which #1021 gave
    // its own outcome): this is the backstop BEHIND that one, for the case where
    // the tool timeout does not fire at all. Disposed through the same probe as
    // every other bounded step, and NOT re-sliced — re-running a gate slice whose
    // process may still be alive is exactly the blind retry the rule forbids.
    if (gateOut.outcome === 'STEP_TIMEOUT') {
      return (await disposeStepTimeout(item, wt, gateOut, 'gate', { adoptable: false })).escalation;
    }
    // temperloop#1698 — STRICT read of the canonical key. `Number(x) || 0` was
    // the defect: against a slice that reported the sibling snake_case spelling
    // (or none at all) it produced `0`, and a gate whose own log said "passed in
    // 215s" was logged as "0s of gate wall time". canonicalizeOutcome() has
    // already folded `elapsed_secs` into `elapsedSecs` at the transport
    // boundary, so an unreadable figure here is genuinely unknown — and is
    // carried as `null` through the ledger and payload, never as a zero.
    const sliceElapsed = numOrNull(gateOut.elapsedSecs);
    if (sliceElapsed === null) {
      gateElapsedUnknown = true;
      log(
        `[${item.slug}] 3e.5 gate slice ${gateSlices + 1} reported NO usable elapsedSecs — the gate DECAY SIGNAL ` +
        `is blind for this slice and the run's wall time renders '?', never 0 (temperloop#1698). The verdict itself ` +
        `is unaffected; the authoritative elapsed figure is in ${gateLog}.`,
      );
    } else {
      gateElapsed += sliceElapsed;
    }
    gateSliceLedger.push({
      slice: gateSlices + 1,
      startAt: gateStartAt,
      outcome: gateOut.outcome,
      failed: gateSliceFailed(gateOut),
      elapsedSecs: sliceElapsed,
      // The RESUME POINT this slice reported, carried into the ledger
      // (temperloop#2094) so gateVerdict() can read "the suite stopped with
      // gates left" off the ledger itself rather than inferring it from the
      // terminal outcome alone. Absent (undefined) when the slice reported
      // none — which is what "the suite ran to the end" looks like.
      ...(gateSliceResumeAt(gateOut) === undefined ? {} : { resumeAt: gateSliceResumeAt(gateOut) }),
      // The slice's own exit status, when the executor reported one. 75 is the
      // budget-spent protocol code; anything else beside a resume point is an
      // anomaly a reader should see rather than have silently normalized away.
      ...(gateOut.rc === undefined ? {} : { rc: Number(gateOut.rc) }),
    });
    if (gateOut.outcome !== 'GATE_SLICE') break;
    gateStartAt = Number(gateOut.resumeAt) || 0;
    // Carry the list identity forward with the index it belongs to. A slice that
    // reports no fingerprint (an older vendored gate script) leaves this empty,
    // which disarms the check rather than tripping it.
    gateSelection = typeof gateOut.selection === 'string' ? gateOut.selection : '';
    log(`[${item.slug}] 3e.5 gate slice ${gateSlices + 1}/${GATE_MAX_SLICES} spent its ${GATE_SLICE_SECS}s budget — resuming at gate ${gateStartAt}`);
  }

  // ONE verdict, derived once from the ledger (temperloop#1587), and ONE
  // payload shape shared by both escalation arms — so the kind an operator (or
  // the escalation router) reads and the numbers underneath it are computed
  // from the same input and cannot disagree.
  const gateReport = gateVerdict(gateOut.outcome, gateSliceLedger);
  const gatePayload = {
    // `verdict` is the field to trust: RED / UNKNOWN / GREEN. `outcome` is the
    // TERMINAL slice's own outcome — a per-slice fact, never the suite's
    // verdict (a GATE_PASS terminal on a run whose slice 1 failed is exactly
    // #1587's trap). `failedGates` is the sum of `sliceLedger[].failed`, the
    // only failure record kept.
    verdict: gateReport.verdict,
    outcome: gateOut.outcome,
    suiteFinished: gateReport.finished,
    failedGates: gateReport.failedGates,
    failedInSlices: gateReport.failedInSlices,
    reason: gateReport.reason,
    // Also derived from the ledger, not from the loop counter: on slice-cap
    // exhaustion the loop index has already advanced past the last slice, so
    // `gateSlices + 1` reported one MORE slice than the payload's own ledger
    // contained — a second, smaller field-vs-field contradiction in the same
    // payload (temperloop#1587).
    slices: gateSliceLedger.length,
    // temperloop#1698 — `null`, not a partial sum, when any slice's figure was
    // unreadable. A payload that reports a multi-minute run as having taken no
    // time is the exact shape this item removes.
    elapsedSecs: gateElapsedUnknown ? null : gateElapsed,
    sliceBudgetSecs: GATE_SLICE_SECS,
    sliceLedger: gateSliceLedger,
    log: gateLog,
    // temperloop#865 — what the WORKER's own scoped gate left behind in this
    // worktree: 'finished' | 'running' | 'absent' | 'unknown'.
    workerGate: workerGateState(gateOut),
  };
  // temperloop#865 — THE LOUD HALF. A worker that backgrounded its gate and
  // yielded leaves a sentinel still reading `running` (or, if it never issued
  // the handed invocation at all, none). Today "waiting for the gate" is
  // indistinguishable from a healthy long gate until the budget is gone; this
  // is the one place in the run that can tell them apart, because it reads the
  // artifact from the same worktree the acceptance gate just ran in. It is a
  // NOTICE, never a block: 3e.5 is the acceptance authority and its verdict
  // stands on its own, so a stale sentinel must not fail an otherwise-green
  // item — it must be impossible to miss.
  const wgState = gatePayload.workerGate;
  if (wgState === 'running') {
    log(
      `[${item.slug}] WORKER GATE NEVER FINISHED (temperloop#865) — the worker's own scoped-gate sentinel at ` +
      `${workerGateSentinel(item.slug)} still reads state:"running", so the worker most likely BACKGROUNDED ` +
      `\`scripts/quality-gates.sh --scoped\` and yielded rather than reading its result. Its self-check is ` +
      `UNVERIFIED; the parent-side 3e.5 verdict above is the authority. A stalled worker now reads differently ` +
      `from a slow one — that distinction is this signal's whole job.`,
    );
  } else if (wgState === 'unknown') {
    log(
      `[${item.slug}] worker gate sentinel UNREADABLE (temperloop#865) — ${workerGateSentinel(item.slug)} exists but ` +
      `carries no state; treat the worker's own gate self-check as unverified.`,
    );
  }
  // A TIMEOUT is NOT a gate failure — its own escalation kind, so an operator
  // (or the pipeline's escalation router) can tell "the budget ran out" from
  // "this branch is broken" without reading a log. Same for exhausting the
  // slice cap: the suite did not finish, which says nothing about the tree.
  // temperloop#1021 is preserved exactly — and sharpened: this arm is now taken
  // only when NOTHING failed in the slices that did run, so "the budget ran
  // out" can never be the label on a run that already observed a real failure.
  if (gateReport.verdict === 'UNKNOWN') {
    return escalate(item.slug, 'acceptance-gate-timeout', {
      ...gatePayload,
      remedy: 'raise BUILD_GATE_SLICE_SECS (bounded by the agent Bash cap) or split the gate list; re-run the gate to get a real verdict',
    });
  }
  // A genuinely RED suite still escalates exactly as before — including the
  // case where a failure found in slice 1 is followed by green (or unfinished)
  // later slices: the ledger keeps it, so it is never lost.
  if (gateReport.verdict === 'RED') {
    return escalate(item.slug, 'acceptance-gate-failed', gatePayload);
  }
  // GATE_PASS or GATE_ABSENT → proceed. Report the MARGIN, not just the verdict:
  // this is the decay signal that #115's bare number never had. A run that ate
  // most of its slice budget, or needed several slices, says so on a GREEN run —
  // before it becomes the next false failure.
  if (gateOut.outcome === 'GATE_PASS') {
    // temperloop#1698 — render an unknown total as `?`, never as a number. The
    // margin warning is likewise suppressed on an unknown figure: a warning
    // computed from a number nobody measured is the same confident-wrong
    // instrument in the other direction.
    const marginNote = gateSlices > 0 || (!gateElapsedUnknown && gateElapsed >= GATE_SLICE_SECS * GATE_MARGIN_WARN_RATIO)
      ? ` — NOTE: approaching the per-slice budget; raise BUILD_GATE_SLICE_SECS or split the gate list before it costs a re-slice`
      : '';
    const elapsedNote = gateElapsedUnknown ? '?' : String(gateElapsed);
    log(`[${item.slug}] 3e.5 gate PASS — ${gateSlices + 1} slice(s), ${elapsedNote}s of gate wall time (slice budget ${GATE_SLICE_SECS}s, cap ${GATE_MAX_SLICES} slices)${marginNote}`);
  }

  // --- 3e.6. Class-A activation gate (temperloop#1219) ----------------------
  // Runs HERE — strictly between 3e.5 and 3f, before anything is pushed — so a
  // Fail costs a loop-back to 3c rather than a re-push onto an open PR. The
  // whole gate lives in runActivationGate() above (with its rationale); this is
  // the ONE line the ordering contract is about. A non-class-A item returns null
  // from its first line: no agent spawn, no log, path unchanged.
  const activationEscalation = await runActivationGate(item, wt);
  if (activationEscalation) return activationEscalation;

  // ===== END OF PHASE 1 (temperloop#2080) ==================================
  // Everything above is build + local verification; NOTHING above pushes,
  // opens a PR or merges. The context handed to phase 2 is assembled here and
  // the function returns null — the fall-through that says "no terminal record,
  // proceed". On the single-arm path driveItem() calls phase 2 immediately, so
  // the two halves are indistinguishable from the pre-split one. On a
  // dual-build arm the caller STOPS here and holds the level barrier.
  box.ctx = {
    item,
    arm,
    wt,
    verdict,
    recovery,
    review,
    reviewSummarySuffix,
    discGaps,
    mainCost,
    // Read by the dual-build ledger row only; the PR phase ignores them.
    wtBase,
    wtGuard,
    gateReport,
    gateElapsedSecs: gateElapsedUnknown ? null : gateElapsed,
  };
  return null;
}

// =============================================================================
// driveItemPr — PHASE 2 (temperloop#2080): 3f push + PR → 3g CI → 3g.5 →  3h.
// =============================================================================
// The callable boundary ADR 0038's level barrier needs. Takes the context
// phase 1 produced and returns the item's terminal record. Every line below is
// the pre-split 3f–3h body, re-homed verbatim; the only edit is the
// destructuring header that replaces the closure it used to read from.
//
// On a dual-build level this is NOT called for an in-scope item's arms — that
// is the barrier. It is called (by driveItem, unchanged) for a not-in-scope
// item, and it is what `level-pick-and-operator-levers` will call for the
// winning arm once the pick is made.
async function driveItemPr(ctx) {
  const {
    item, wt, verdict, recovery, review, reviewSummarySuffix, discGaps, mainCost,
  } = ctx;
  const { repoRoot, planLink } = input;
  const ownerRepo = input.ownerRepo; // "owner/repo" — passed by the orchestrator

  // --- 3f. Push and open the PR (ONE batched executor — temperloop#942) -----
  // rebase → scan → push → pr-open are four adjacent, seconds-scale machinery
  // calls that used to cost four agent spawns. They now ride ONE
  // `pr-batch:<slug>` executor: the shell runs them in order and prints each
  // script's own JSON line, and every branch below still reads that step's own
  // object here in .mjs. The batch's `case` gates mirror those branches so a
  // REBASE_CONFLICT / SCAN_BLOCKED / PUSH_REJECTED never lets a later step run.
  const prBin = machineryBin(repoRoot, 'pr.sh');
  const prSteps = [];
  const prAt = {};
  const addPrStep = (kind, cmd, continueOutcomes) => {
    prAt[kind] = prSteps.length;
    prSteps.push({ kind, cmd, continueOutcomes });
  };

  // 3f-0a. Rebase onto fresh origin/<default> — the unconditional stale-base
  // guard (#525). EVERY worker (not just speculative ones) branched off the
  // default at the start of its run; on a fast-moving default a long run lets
  // the default advance mid-build, so by here the worker's base may be stale
  // and a straight push would land a PR whose cumulative diff REVERTS whatever
  // merged in between (W49/W52). pr.sh rebase fetches the default fresh and
  // replays the worker's commits onto its tip (a no-op when already current).
  // On REBASE_CONFLICT it has already `git rebase --abort`ed (worktree left
  // clean, NEVER a silent revert) → escalate as a rebase conflict for a human.
  //
  // SKIPPED on a recovery whose branch is ALREADY on origin (temperloop#939).
  // The rebase rewrites the worker's commits, so the plain (non-force) push
  // below would then be a non-fast-forward and come back PUSH_REJECTED —
  // converting a clean recovery of already-landed work into a spurious
  // escalation, which is the exact class of failure #939 is about. The
  // RECOVER_COMMITTED stage has pushed nothing yet, so it still rebases
  // normally; so does every non-recovery drive.
  if (!(recovery && recovery.pushed)) {
    addPrStep('rebase', `${prBin} rebase ${sq(wt)}`, ['REBASED']);
  } else {
    log(`[${item.slug}] recovery (${recovery.stage}) — skipping 3f-0a rebase (branch already on origin)`);
  }

  // 3f-0. Closing-keyword pre-push scan.
  addPrStep('scan', `${prBin} scan ${sq(wt)}`, ['SCAN_CLEAN']);

  // 3f-1. Push-by-SHA on the plan's branch.
  //
  // `--allow-rewrite` (temperloop#2103): 3f-0a above has just REWRITTEN this
  // branch's history onto a fresh origin/<default>, and on a continuation round
  // an earlier round has already pushed the pre-rebase history to origin. A
  // plain push of a rewritten, already-pushed branch can NEVER fast-forward, so
  // it came back PUSH_REJECTED every time — observed three times in one session,
  // each recovered by hand with a lease-force push. The `recovery && pushed`
  // skip above only covers the temperloop#939 lost-return path; an ordinary
  // continuation round is not a `recovery` and never took it.
  //
  // This is a REQUEST, not a force: pr.sh downgrades to a plain push on any
  // provable fast-forward (#335), issues nothing at all when the ref is absent
  // or unreadable, and when it does rewrite it uses
  // `--force-with-lease=<ref>:<sha>` over a value it read first — so a
  // concurrent writer is rejected rather than overwritten. The flag is spelled
  // `--allow-rewrite` rather than `--force` so the command line the orchestrator
  // executes carries no classifier-visible force token (#437).
  //
  // AND NOT ON THE LEASE ALONE (temperloop#2103 round 3). Because this call site
  // requests a rewrite on EVERY item — not only on a rescue — it is the busiest
  // force path in the pipeline, and a lease protects only against a writer who
  // moves the ref BETWEEN pr.sh's read and its push, never against content that
  // was already there. So pr.sh gates the force on the SAME supersede check
  // preserveCommittedWorkCmd (below) applies on the rescue path: a branch name
  // colliding with unrelated work — a leftover manual branch, a reused slug, a
  // planning bug — comes back PUSH_REJECTED with `refused_reason` rather than
  // being overwritten and reported as an ordinary PUSHED straight into pr-open.
  // The two force paths this file drives are symmetric; the asymmetry between
  // them was the round-2 finding.
  addPrStep('push', `${prBin} push ${sq(wt)} ${sq(item.branch)} --allow-rewrite`, ['PUSHED']);

  // 3f-2. Open the PR. The verification surface is read from the deterministic
  // file path (--verification-surface-file) so its body never enters context.
  // The worker's verdict JSON is needed by pr.sh open (--verdict); we hand the
  // executor a heredoc-built temp file so the (possibly large) verdict stays in
  // the executor's process, not this workflow's. We pass only the fields pr.sh
  // reads from the verdict — summary + acceptance_results — assembled compactly.
  const verdictJson = JSON.stringify({
    status: 'done',
    // temperloop#1430: the §3e review outcome rides the PR body via `summary`
    // (the one verdict field pr.sh always renders) — this is what lets a real
    // review pass (or a genuine, non-guaranteed skip) be OBSERVED on the PR
    // itself, rather than living only in this run's transcript.
    // The worker's own prose is neutralized for the same reason reviewer prose
    // is (see REVIEW_BLOCK_MARK): it is spliced verbatim ABOVE `## Review
    // notes`, so an un-neutralized delimiter there would open a phantom first
    // block whose span swallowed the `§3e review — ran:` line the cap must
    // never cut.
    summary: neutralizeReviewBlockMark(verdict.summary ?? '') + reviewSummarySuffix,
    acceptance_results: verdict.acceptance_results ?? [],
    // temperloop#939: a recovered verdict carries a synthesized inline surface.
    // pr.sh resolves the surface by precedence (file flag → path key → inline),
    // so this is used ONLY when no real `.build-verification.md` exists.
    ...(verdict.verification_surface ? { verification_surface: verdict.verification_surface } : {}),
  });
  // Cross-repo `Closes` qualification (temperloop#852, build.md 3f "Cross-repo
  // `repo:` honor point"). `item.repo` (plan-schema.md § Optional `repo:`
  // field) names the repo THIS item's PR opens against; it is absent for the
  // common same-repo case. `gh_issue:`/`also_closes:` numbers are tracked
  // wherever the item was triaged — the plan's HOME repo, i.e. `ownerRepo` —
  // NOT necessarily `item.repo` (the kernel-classified-item case is the
  // mirror image of the `repo:` case: the PR lands in the kernel repo but the
  // issue was triaged, and stays tracked, in the plan's home repo). So a
  // cross-repo item (`item.repo` set AND different from `ownerRepo`) must
  // emit the fully-qualified `owner/repo#N` form — a bare `Closes #N` is
  // same-repo only and would resolve against the wrong repo (or nothing) once
  // pushed. pr.sh's `closes_line()`/`validate_issue()` already accept either
  // shape verbatim (do not change pr.sh) — the qualification decision belongs
  // here, at the one call site that knows both repos. A same-repo item (no
  // `repo:`, or `repo:` equal to `ownerRepo`) is unaffected: bare `Closes #N`
  // exactly as before.
  const crossRepo = Boolean(item.repo && ownerRepo && item.repo !== ownerRepo);
  const qualifyIssueRef = (n) => (crossRepo ? `${ownerRepo}#${n}` : `${n}`);
  const ghIssueFlag = item.ghIssue ? ` --gh-issue ${sq(qualifyIssueRef(item.ghIssue))}` : '';
  const alsoClosesFlag = item.alsoCloses?.length
    ? ` --also-closes ${sq(item.alsoCloses.map(qualifyIssueRef).join(','))}`
    : '';
  // The surface-file flag is DROPPED on a recovery whose probe saw no
  // `.build-verification.md` (temperloop#939): pr.sh treats a given-but-missing
  // surface file as a hard ERROR by contract, so passing it for a worker that
  // died before writing one would turn the recovery into a pr-open-failed
  // escalation. Without the flag pr.sh falls back to the synthesized inline
  // surface above. Every non-recovery drive passes the flag exactly as before.
  const surfaceFlag =
    recovery && !recovery.surfacePresent
      ? ''
      : ` --verification-surface-file ${sq(`${wt}/.build-verification.md`)}`;
  const openCmd =
    `vf=$(mktemp) && printf %s ${sq(verdictJson)} > "$vf" && ` +
    `${prBin} open --repo ${sq(repoRoot)} --branch ${sq(item.branch)} ` +
    `--title ${sq(item.title)} --verdict "$vf"${ghIssueFlag}${alsoClosesFlag}${surfaceFlag} ` +
    `--plan-link ${sq(planLink)} --source ${sq(item.source ?? '')}; ` +
    `rc=$?; rm -f "$vf"; exit $rc`;
  addPrStep('pr-open', openCmd); // terminal step — nothing gates after it

  // --- 3f-2 FALLBACK: a PR-ready tree must not be stranded by a bad verdict --
  // temperloop#1805, disposition (a). `pr.sh open` REQUIRES a parseable
  // `--verdict` and dies `verdict is not valid JSON` when it does not get one.
  // That is a REPORTING-layer failure, and it was terminal for the item:
  //
  //   {"slug":"disclosure-watermark-tracked-1316","kind":"pr-open-failed",
  //    "payload":{"openOut":{"step":"pr-open","outcome":"ERROR",
  //                          "error":"verdict is not valid JSON"}}}
  //
  // …against ONE clean commit, a zero-dirty tree, a full `.build-verification.md`
  // and that item's own suite green 39/39. The orchestrator recovered it BY HAND
  // — push, `gh pr create`, verification file as the body — and it became PR
  // #1803. Every piece of information the PR needed was already on disk; only
  // the hand-off failed. The preservation machinery means the commit survives,
  // so this is not data loss — it is PROGRESS loss: the item parks, re-enters
  // the next run, and a fresh worker redoes finished, correct work.
  //
  // So the fallback re-issues `open` with a MINIMAL, structurally-safe verdict:
  // the title is the item's own (what `--title` already carried) and the body
  // comes from `.build-verification.md` via the surface flag — exactly the shape
  // the manual recovery used. Everything variable about the rich verdict —
  // `acceptance_results`, the worker's own prose — is dropped, because that is
  // precisely the content that failed to survive the hand-off; the §3e review
  // evidence line is kept, since it is assembled by this file and must stay
  // visible on the PR (temperloop#1430).
  //
  // A body-less fallback would be worse than the escalation, so it is attempted
  // ONLY when there is a real surface to fall back ON — either the worktree file
  // or the synthesized inline surface.
  const fallbackVerdictJson = JSON.stringify({
    status: 'done',
    summary:
      'The worker completed this item, but its verdict JSON did not survive the hand-off to `pr.sh open` ' +
      '(temperloop#1805). This body was assembled from the commit on the branch and the verification ' +
      'surface the worker wrote to disk; the per-criterion acceptance table is NOT reproduced here — ' +
      'read the verification surface below.' + reviewSummarySuffix,
    acceptance_results: [],
    ...(verdict.verification_surface ? { verification_surface: verdict.verification_surface } : {}),
  });
  const fallbackOpenCmd =
    `vf=$(mktemp) && printf %s ${sq(fallbackVerdictJson)} > "$vf" && ` +
    `${prBin} open --repo ${sq(repoRoot)} --branch ${sq(item.branch)} ` +
    `--title ${sq(item.title)} --verdict "$vf"${ghIssueFlag}${alsoClosesFlag}${surfaceFlag} ` +
    `--plan-link ${sq(planLink)} --source ${sq(item.source ?? '')}; ` +
    `rc=$?; rm -f "$vf"; exit $rc`;
  const fallbackHasSurface = Boolean(surfaceFlag) || Boolean(verdict.verification_surface);

  const prb = await runMachineryBatch(prSteps, {
    label: `pr-batch:${item.slug}`,
    slug: item.slug,
    bashTimeoutMs: BATCH_BASH_TIMEOUT_MS,
    phase: enterStage(STAGE_PR), // 3f rebase + scan + push + pr-open
  });
  if (prb.denied) {
    // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
    return await deniedOrQuota(item.slug, {
      step: batchDeniedStep(prb, 'pr-batch'),
      steps: prb.steps,
      out: prb.out,
    }, wt);
  }

  // temperloop#1071 — a pr-batch step that outlived the liveness ceiling. THIS is
  // the incident's own shape: the 9h49m call was a `pr-batch` whose steps all in
  // fact completed (PR #1070 opened) while the workflow sat waiting. So the
  // disposal probes for exactly that — an already-opened PR is ADOPTED and the
  // item flows straight on to CI, never re-pushed and never re-opened. Any other
  // probe stage escalates. Either way, the rebase/scan/push/pr-open branches
  // below are SKIPPED: their step objects were destroyed by the kill, and
  // re-deriving them from a truncated batch is how a double-push happens.
  const prTimeout = timedOutStep(prb.results);
  let adopted = null;
  if (prTimeout) {
    const disp = await disposeStepTimeout(item, wt, prTimeout, 'pr-batch');
    if (disp.escalation) return disp.escalation;
    adopted = disp.adopt;
  }

  let pr;
  let pushedSha;
  if (adopted) {
    pr = adopted.pr;
    pushedSha = adopted.sha ?? null;
  } else {
    // 3f-0a branch — the rebase decision, unchanged, read off the batch.
    if (prAt.rebase !== undefined) {
      const rebaseOut = batchStep(prb, prAt.rebase);
      // DIRTY_WORKTREE is NOT a conflict (temperloop#735): git refused to start
      // the rebase because the worker left tracked-file edits uncommitted —
      // often with base == tip, i.e. no rebase was needed at all. It escalates
      // under its OWN kind so the disposition is "commit the edits and re-drive"
      // rather than the rebase-conflict path, whose discard-and-respawn arm
      // would throw a FINISHED worker's work away. Checked before
      // REBASE_CONFLICT so the two can never collapse back into one.
      if (rebaseOut.outcome === 'DIRTY_WORKTREE') {
        return escalate(item.slug, 'dirty-worktree', { rebaseOut });
      }
      if (rebaseOut.outcome === 'REBASE_CONFLICT') {
        return escalate(item.slug, 'rebase-conflict', { rebaseOut });
      }
      if (rebaseOut.outcome !== 'REBASED') {
        return escalate(item.slug, 'rebase-error', { rebaseOut });
      }
    }

    // 3f-0 branch — the closing-keyword scan decision, unchanged.
    const scanOut = batchStep(prb, prAt.scan);
    if (scanOut.outcome === 'SCAN_BLOCKED') {
      // A worker commit carries a closing keyword (the ec8d5fd class). Don't push
      // it as-is — escalate so the orchestrator re-words and re-drives.
      return escalate(item.slug, 'closing-keyword', { scanOut });
    }
    if (scanOut.outcome !== 'SCAN_CLEAN') {
      return escalate(item.slug, 'scan-error', { scanOut });
    }

    // 3f-1 branch — the push decision. Before escalating a non-PUSHED,
    // non-PUSH_REJECTED outcome, probe for a LOST pr-batch return
    // (temperloop#1067): batchStep synthesizes the same 'ERROR'/'produced no
    // result' sentinel for both a genuine short-circuit and a dropped last JSON
    // line, and by this point rebase+scan are ALREADY confirmed successful (the
    // branches above), so a sentinel here specifically means push's own result
    // line was lost, not that push never ran. A genuine PUSH_REJECTED (or any
    // other real failure) is unaffected — it never reaches isLostReturn().
    const pushOut = batchStep(prb, prAt.push);
    if (pushOut.outcome === 'PUSH_REJECTED') {
      // Remote-branch collision / non-ff — orchestrator triages (force vs rename).
      return escalate(item.slug, 'push-rejected', { pushOut });
    }
    if (pushOut.outcome === 'PUSHED_UNWATCHED') {
      // temperloop#1688 — the push LANDED, on a ref no open PR references while
      // an open PR for the same slug sits on a different head ref. Its own
      // escalation kind, checked BEFORE the lost-return probe: the result line
      // was not lost (it says something specific), and 'push-error' would bury
      // the one fact the operator needs — which ref the PR actually tracks,
      // carried on the payload's pr_head_ref. Opening/CI-polling past this is
      // exactly the false-green route #254 arrives by here.
      return escalate(item.slug, 'push-unwatched-branch', { pushOut });
    }
    if (pushOut.outcome !== 'PUSHED') {
      const rec = isLostReturn(pushOut) ? await recoverLostReturn(item, wt, openCmd) : { kind: 'none' };
      if (rec.kind === 'adopted') {
        pr = rec.pr;
        pushedSha = rec.pushedSha;
      } else if (rec.kind === 'escalate') {
        return escalate(item.slug, rec.escKind, rec.payload);
      } else {
        return escalate(item.slug, 'push-error', { pushOut });
      }
    } else {
      pushedSha = pushOut.sha;
    }

    // 3f-2 branch — the PR-open decision. Skipped entirely when the push-branch
    // recovery above already adopted or opened a PR (`pr` is already set) —
    // re-running open against a branch that already has one is exactly the
    // duplicate-PR hazard this wiring must never cause.
    // EXISTS means the branch already had an open PR (a create-retry after a
    // succeeded first attempt). Treat it as PR_OPENED — adopt the existing PR and
    // continue to CI-poll/park-with-pr. Any other non-PR_OPENED outcome is
    // probed for the same lost-return sentinel (temperloop#1067) before it
    // escalates as a genuine pr-open-failed.
    if (pr == null) {
      let openOut = batchStep(prb, prAt['pr-open']);
      // temperloop#1805 — TOLERATE an unparseable verdict over a PR-ready tree.
      // Checked BEFORE the lost-return probe: this outcome says something
      // specific (pr.sh's own `die`), so it is not a dropped result line, and
      // `recoverLostReturn` would re-issue the SAME command with the SAME bad
      // verdict and fail identically. Re-issue with the minimal verdict instead.
      let verdictFallback = null;
      if (isVerdictUnparseable(openOut)) {
        if (!fallbackHasSurface) {
          log(
            `[${item.slug}] pr-open rejected the verdict (${openOut.error ?? '?'}) and there is NO verification ` +
            `surface to fall back on — escalating rather than opening a PR with an empty body (temperloop#1805).`,
          );
        } else {
          log(
            `[${item.slug}] pr-open rejected the verdict (${openOut.error ?? '?'}) — the tree is PR-READY, so this ` +
            `is a REPORTING failure, not a failed item (temperloop#1805). Re-opening with the commit's own title ` +
            `and .build-verification.md as the body, exactly as the manual recovery of #1803 did.`,
          );
          verdictFallback = await runMachinery(fallbackOpenCmd, {
            label: `pr-open-verdict-fallback:${item.slug}`,
            slug: item.slug,
            phase: stagePhase(STAGE_RECOVER),
          });
          if (verdictFallback.outcome === 'PR_OPENED' || verdictFallback.outcome === 'EXISTS') {
            log(
              `[${item.slug}] PR #${verdictFallback.pr_number} opened from the fallback body — the acceptance ` +
              `table is not reproduced on it (the verdict that carried it did not survive); the verification ` +
              `surface is (temperloop#1805).`,
            );
            openOut = verdictFallback;
          }
        }
      }
      if (openOut.outcome !== 'PR_OPENED' && openOut.outcome !== 'EXISTS') {
        const rec = isLostReturn(openOut) ? await recoverLostReturn(item, wt, openCmd) : { kind: 'none' };
        if (rec.kind === 'adopted') {
          pr = rec.pr;
          pushedSha = rec.pushedSha ?? pushedSha;
        } else if (rec.kind === 'escalate') {
          return escalate(item.slug, rec.escKind, rec.payload);
        } else if (isVerdictUnparseable(openOut)) {
          // temperloop#1805, the OBSERVABLE half. Even when the fallback cannot
          // land the PR, the escalation must let its reader tell "no work" from
          // "work done, reporting broke". A payload naming only the parse error
          // is what made a finished item look terminal — and on an unattended run
          // with no operator reading it, that is how landed-quality work gets
          // parked, pruned and redone. The three facts that settle it come from
          // the recover-probe, the same staged ladder every other disposal uses.
          const probe = await probeSideEffects(item, wt);
          return escalate(item.slug, 'verdict-unparseable', {
            openOut,
            fallbackOut: verdictFallback,
            committed_sha: pushedSha ?? probe.sha ?? null,
            dirty: probe.stage === 'RECOVER_DIRTY' || (probe.dirtyFiles ?? 0) > 0,
            verification_present: probe.surfacePresent === true || Boolean(surfaceFlag),
            probeStage: probe.stage ?? null,
            pushed: probe.pushed === true,
            reason:
              'the work is COMMITTED and the branch is pushed; only the worker verdict failed to parse, so ' +
              'pr.sh open refused to assemble a body. This is a reporting-layer failure, NOT a failed item — ' +
              'read committed_sha / dirty / verification_present before disposing of it.',
            remedy:
              'open the PR by hand from the committed branch with .build-verification.md as the body (the ' +
              'temperloop#1803 recovery), or re-drive ONLY the verdict — never rebuild the work.',
          });
        } else {
          return escalate(item.slug, 'pr-open-failed', {
            openOut,
            // The same three facts, best-effort and free (no extra probe): every
            // pr-open failure deserves to be readable as "work done, reporting
            // broke" rather than as "nothing landed".
            committed_sha: pushedSha ?? null,
            verification_present: Boolean(surfaceFlag) || Boolean(verdict.verification_surface),
          });
        }
      } else {
        pr = openOut.pr_number;
      }
    }
  }

  // --- 3f→3g SHA hand-off guard (temperloop#2014) --------------------------
  // The ONE choke point every arm above converges on. FOUR paths can set
  // `pushedSha` and all four are covered here rather than four times over:
  //   1. the timeout-ADOPT arm       — `adopted.sha ?? null` (probe.sha; the
  //      `?? null` makes a probe that landed a PR but resolved no SHA reach
  //      this guard as an explicit null rather than an `undefined`);
  //   2. the push lost-return RECOVERY arm      — `rec.pushedSha`;
  //   3. the pr-open lost-return RECOVERY arm   — `rec.pushedSha ?? pushedSha`;
  //   4. the plain PUSHED arm        — `pushOut.sha`, unguarded until now: the
  //      push outcome is transported through an executor agent's structured
  //      return, so a `sha` key that never makes it back leaves this
  //      `undefined` while the step still reports success — the temperloop#2014
  //      reproduction's own path.
  // A guard at each assignment would have to be written (and kept) four times
  // and would still miss a fifth arm added later; one guard on the value the
  // poll actually receives cannot be bypassed by a new arm. The CI-fix re-push
  // inside ciPollLoop re-pins `sha` after this point and carries its own copy.
  if (hexSha(pushedSha) === null) {
    return escalate(
      item.slug,
      'ci-poll-bad-argument',
      badShaEscalation(
        pr,
        pushedSha,
        'push-to-poll-handoff',
        'push + PR-open reported success but produced no usable head SHA to pin the CI poll to',
      ),
    );
  }

  // --- 3g. CI poll (the bounded short-slice loop — DESIGN NOTE 2) ----------
  const ciResult = await ciPollLoop(item, ownerRepo, pr, pushedSha, wt);
  if (ciResult.escalation) {
    return escalate(item.slug, ciResult.escalation, { ...ciResult.payload, pr });
  }

  // --- 3g.5. Re-render §3e evidence after any CI-fix re-review (#1846) ------
  // The PR body was assembled at 3f from the ORIGINAL review round only, while
  // park()'s Step-6 tally merges every round — so a reviewer that ran only in
  // a CI-fix round (its diff includes the fix commit, which can touch file
  // classes the original diff never did) had real findings that reached ONLY
  // the tally: the body's "ran:" line affirmatively named a reviewer set that
  // omitted it, and its findings were invisible at the merge gate (issue
  // #1846 — body said "ran: docs-reviewer"; review.ran carried shell-reviewer
  // and its three findings). Rebuild the FULL body through pr.sh's own
  // assemble_body path (`open --update-pr` — never regex surgery on the live
  // body) with the suffix merged across every round. Skipped when the merged
  // suffix equals 3f's (no fix round, or fix rounds that routed no reviewer)
  // — the common path costs nothing. A failed update DEGRADES with a loud log
  // line rather than taking down a CI-green item: review is advisory (never a
  // `checks` gate), and the findings still ride the Step-6 tally below.
  const fixRounds = ciResult.fixReviewRounds ?? [];
  const mergedReviewSuffix = reviewBodySuffix([review, ...fixRounds]);
  if (mergedReviewSuffix !== reviewSummarySuffix) {
    const mergedVerdictJson = JSON.stringify({
      status: 'done',
      summary: neutralizeReviewBlockMark(verdict.summary ?? '') + mergedReviewSuffix,
      acceptance_results: verdict.acceptance_results ?? [],
      ...(verdict.verification_surface ? { verification_surface: verdict.verification_surface } : {}),
    });
    const updateCmd =
      `vf=$(mktemp) && printf %s ${sq(mergedVerdictJson)} > "$vf" && ` +
      `${prBin} open --repo ${sq(repoRoot)} --update-pr ${sq(String(pr))} --verdict "$vf"${ghIssueFlag}${alsoClosesFlag}${surfaceFlag} ` +
      `--plan-link ${sq(planLink)} --source ${sq(item.source ?? '')}; ` +
      `rc=$?; rm -f "$vf"; exit $rc`;
    const upd = await runMachinery(updateCmd, {
      label: `pr-body-update:${item.slug}`,
      slug: item.slug,
      phase: enterStage(STAGE_CI),
    });
    if (upd && upd.outcome === 'BODY_UPDATED') {
      log(`[${item.slug}] PR #${pr}: §3e evidence re-rendered across ${1 + fixRounds.length} review round(s) (temperloop#1846)`);
    } else {
      log(
        `[${item.slug}] PR #${pr}: §3e body re-render FAILED — the body's review line may omit CI-fix round ` +
          `reviewer(s)/findings; they still ride the Step-6 review tally (temperloop#1846): ${JSON.stringify(upd?.outcome ?? upd)}`,
      );
    }
  }

  // --- 3h. Park as [m] (the workflow returns the record; orchestrator writes)
  // A NO_CI resolution (temperloop#605/#618) parks the same, but the returned
  // record carries `no_ci: true` so the orchestrator stamps the sentinel.
  log(`[${item.slug}] parked — PR #${pr} ${ciResult.noCi ? 'no CI configured (skipped)' : 'CI green'}${recovery ? ' (RECOVERED — acceptance unverified)' : ''}`);
  // temperloop#1319: the named warning — mirrors the verification_surface
  // degraded-case wording (build.md §3f step 2) exactly, one line naming the
  // PR and every gap criterion, so it is visible in the run log AND (via the
  // parked.discrimination_gaps field above) tallied in the Step 6 summary —
  // never silently dropped.
  if (discGaps.length > 0) {
    log(
      `[${item.slug}] PR #${pr}: ${discGaps.length} acceptance criterion(s) passed with no discrimination evidence — ` +
      `the worker never proved these checks can fail (temperloop#1319): ${discGaps.map((c) => `"${c}"`).join(', ')}`,
    );
  }
  // temperloop#1182: the deferral warning — named and visible in the run log,
  // and (via the parked.host_config_deferrals field) carried to the merge gate
  // where the orchestrator MUST verify each one in the real checkout. Louder
  // wording than the #1319 line above on purpose: that one is advisory, this
  // one names work the orchestrator still owes before the item can merge.
  const hostDeferrals = hostConfigDeferrals(verdict.acceptance_results);
  if (hostDeferrals.length > 0) {
    log(
      `[${item.slug}] PR #${pr}: ${hostDeferrals.length} acceptance criterion(s) DEFERRED — host-config not visible ` +
      `from a worktree (temperloop#1182); VERIFY PARENT-SIDE before merge: ` +
      `${hostDeferrals.map((d) => `"${d.criterion}" (${d.host_config})`).join(', ')}`,
    );
  }
  // temperloop#1450 — merge the ORIGINAL 3e pass with any CI-fix re-review
  // round(s) (ciResult.fixReviewRounds) into the ONE tally park() carries, so
  // the Step 6 summary can render whether §3e actually discharged, across
  // every review this item's build ran, not just the first. Two INDEPENDENT
  // degraded-case tallies ride this one park() call now (discGaps from
  // #1319, reviewSummary from #1450) — see park()'s own signature comment.
  const reviewSummary = reviewTally(review, ...(ciResult.fixReviewRounds ?? []));
  // temperloop#2065 — assemble the per-item cost ledger park() carries. Wall
  // clock is ONE total across the main worker AND every CI-fix retry
  // (mergeWorkerCost's same null-only-if-both-null rule, applied by hand here
  // since ciResult's retryWallClockMs is a bare number|null, not a cost
  // object); tokens stay split (worker) vs combined (retry) per the epic's
  // own ledger vocabulary (item 5/11) — see park()'s own comment.
  const cost = {
    tokens_in: mainCost.tokensIn,
    tokens_out: mainCost.tokensOut,
    wall_clock_ms:
      mainCost.wallClockMs == null && ciResult.retryWallClockMs == null
        ? null
        : (mainCost.wallClockMs ?? 0) + (ciResult.retryWallClockMs ?? 0),
    retry_tokens: ciResult.retryTokens ?? null,
    retry_count: ciResult.retryCount ?? 0,
    recovery: !!recovery,
  };
  return park(item.slug, pr, ciResult.finalSha ?? pushedSha, verdict.acceptance_results, ciResult.noCi === true, recovery, discGaps, reviewSummary, cost);
}

// -----------------------------------------------------------------------------
// ciPollLoop — bounded short-slice CI poll (DESIGN NOTE 2).
// -----------------------------------------------------------------------------
// Drives CI_POLL_SLICE_SECS-timeout ci-poll.sh calls until the outcome resolves.
// TIMEOUT on a slice = "still pending, poll again" (NOT a failure) — we keep
// looping while the total budget remains. On CI_FAILED, within
// CI_FAIL_RETRY_BUDGET, we re-spawn the worker + force-push + re-poll PINNED to
// the new SHA (#254 false-green guard).
//
// temperloop#942: the slices no longer cost an agent spawn EACH. One
// `ci-batch:<slug>#n` executor runs CI_POLL_SLICES_PER_BATCH
// (merge-state probe → poll slice) PAIRS in a single Bash invocation and returns
// all their JSON lines; this loop then consumes them one slice at a time from a
// buffer and branches on each exactly as it did when each came from its own
// agent. Interleaving is preserved: the merge-state probe still runs immediately
// before EVERY poll slice (#543), not once per batch. The buffer is FLUSHED
// whenever the head SHA changes (a CI-fix re-push), because buffered results are
// pinned to the OLD sha — keeping the #254 false-green guard intact. And the
// batch never runs one long poll: see DESIGN NOTE 2 for the derived slice count.
// Returns:
//   { ok:true, finalSha }                         — CI green
//   { ok:true, finalSha, noCi:true }              — NO_CI (temperloop#605/#618):
//        no CI configured on this repo/SHA — a legible skip mirroring build.md
//        3g, NOT a failure; 3h parks [m] with the no_ci sentinel stamped
//   { escalation:'ci-failed', payload:{...} }      — budget exhausted / hard fail
//   { escalation:'merge-conflict', payload:{...} } — PR is CONFLICTING/DIRTY

// MERGE_CONFLICT_GLOBS — the substrings that make the batched merge-state probe
// stop the sequence early. This is the STOP-EARLY MIRROR of the .mjs branch
// below (`mergeable === 'CONFLICTING' || mergeStateStatus === 'DIRTY'`), NOT the
// decision: it only spares a CONFLICTING PR the 4-minute poll slice that would
// otherwise run before the .mjs read the same object and escalated. The
// authoritative branch is, as always, the `if` in .mjs.
const MERGE_CONFLICT_GLOBS = ['"mergeable":"CONFLICTING"', '"mergeStateStatus":"DIRTY"'];

function mergeStateCmd(ownerRepo, pr) {
  // gh pr view returns JSON; if it fails (e.g. auth error) the executor catches
  // non-zero exit and returns whatever gh printed — the caller handles missing fields.
  //
  // `tr -d ' \n'` COMPACTS the object onto one line (temperloop#942). gh may
  // pretty-print `--json` output, and a batched step's result must be a single
  // JSON line for both the executor's line-per-step contract and the `case`
  // stop-early glob above (which would miss `"mergeable": "CONFLICTING"` with a
  // space). Only `mergeable`/`mergeStateStatus` are requested and both are
  // space-free enum values, so stripping spaces cannot corrupt a value.
  return `gh pr view ${sq(pr)} --repo ${sq(ownerRepo)} --json mergeable,mergeStateStatus | tr -d ' \\n'`;
}

// -----------------------------------------------------------------------------
// The pushed-SHA hand-off guard (temperloop#2014).
// -----------------------------------------------------------------------------
// ciPollCmd pins `--sha` to the SHA the push reported — the #254 false-green
// guard, and the one argument of the poll that this file, not the machinery,
// is responsible for. sq() stringifies whatever it is handed, so an ABSENT
// value does not crash: it renders as the literal `undefined` (or `null`),
// ci-poll.sh's own argument validation refuses to run on it, and the driver
// read that refusal back through the catch-all ERROR arm as `ci-failed` — i.e.
// reported a PR whose CI was still running (temperloop#2014: PR #2013 was OPEN
// with checks IN_PROGRESS) as a red one. Two halves close it:
//   • hexSha() is the PRE-FLIGHT. Every value that can become the poll's
//     `--sha` passes through it before a poll is spawned, so the driver never
//     spends a slice on an argument ci-poll.sh is certain to reject.
//   • a bad argument that reaches ci-poll.sh anyway (a vendored older copy, a
//     validation this file does not model) comes back as its OWN escalation
//     kind, `ci-poll-bad-argument`, never `ci-failed` — see isBadArgumentError
//     and the ERROR arm at the bottom of ciPollLoop.
// The predicate is hex-only, matching ci-poll.sh's own `*[!0-9a-fA-F]*`
// rejection exactly. It must never be LOOSER than the check it protects, or
// the pre-flight passes something the poll then refuses — which is the whole
// failure being fixed, one layer down.
function hexSha(value) {
  return typeof value === 'string' && value !== '' && /^[0-9a-fA-F]+$/.test(value)
    ? value
    : null;
}

// badShaEscalation — the payload shared by both pre-flight sites (the 3f→3g
// hand-off and the CI-fix re-push). `sha_seen` is the value STRINGIFIED exactly
// as sq() would have rendered it, so the payload shows the literal
// `undefined`/`null` the poll would have been handed rather than dropping the
// key entirely (JSON.stringify eats an `undefined` value).
function badShaEscalation(pr, seen, stage, detail) {
  return {
    pr,
    sha_seen: String(seen),
    stage,
    reason: detail,
    disposition:
      'NOT a CI verdict — the poll never ran. The PR itself is untouched and its checks ' +
      'may well be green: inspect it, and re-drive (or finish by hand) once the head SHA is known.',
  };
}

// isBadArgumentError — true iff a ci-poll.sh ERROR is the script REFUSING TO
// RUN on its own arguments, rather than a poll that ran and went wrong. The
// primary signal is the structured `usage_error:true` field ci-poll.sh stamps
// on every argument-validation die (its own header documents it alongside
// transient_retries_exhausted / deterministic_failure). The error-text fallback
// covers a vendored or older ci-poll.sh predating that stamp: every one of its
// argument dies renders as `<name> '<value>' invalid — must be …`, or the
// `usage: ci-poll.sh …` line — phrasings no API/transport error shares. Narrow
// on purpose: a genuine CI failure must never be laundered out of `ci-failed`.
function isBadArgumentError(out) {
  if (!out || out.outcome !== 'ERROR') return false;
  if (out.usage_error === true) return true;
  if (typeof out.error !== 'string') return false;
  return / invalid — must be /.test(out.error) || /^usage: ci-poll\.sh /.test(out.error);
}

function ciPollCmd(ownerRepo, pr, sha) {
  const ciBin = machineryBin(input.repoRoot, 'ci-poll.sh');
  // --sha pins the head (REQUIRED on a re-poll after a force-push; harmless on
  // the first poll where it equals the pushed head). --timeout is the SLICE.
  return (
    `${ciBin} ${sq(ownerRepo)} ${sq(pr)} --sha ${sq(sha)} ` +
    `--timeout ${sq(CI_POLL_SLICE_SECS)}`
  );
}

async function ciPollLoop(item, ownerRepo, pr, initialSha, wt) {
  let sha = initialSha;
  let retriesLeft = CI_FAIL_RETRY_BUDGET;
  // The runtime forbids Date.now(); we bound by SLICE COUNT instead of wall
  // clock (slices * slice-secs ≈ total budget). Integer ceil.
  const maxSlices = Math.ceil(CI_POLL_TOTAL_SECS / CI_POLL_SLICE_SECS);

  // Buffered slices from the current ci-batch: one { mergeState, out } pair per
  // slice the batch actually ran. Refilled whenever it empties; FLUSHED whenever
  // `sha` changes (buffered results are pinned to the previous head — #254).
  let buffer = [];
  let batchIdx = 0;
  // temperloop#1450 — one runReviewers() result per CI-fix commit re-reviewed
  // below (the CI_FAILED arm), so a green resolution can hand them back to
  // driveItem for the Step 6 tally (park()'s `review` argument via
  // reviewTally()). A CI-fix commit can touch anything — including the very
  // command doc whose edit tripped the ORIGINAL lint failure — and without
  // this it would ship unreviewed under a PR body that only describes the
  // FIRST push.
  const fixReviewRounds = [];
  // temperloop#2065 — the CI_FAIL_RETRY_BUDGET loop's OWN cost tally, kept
  // separate from the main worker's `mainCost` (driveItem): the ledger's
  // "worker tokens" and "retry tokens" are two DIFFERENT figures (epic
  // #2062's item 5/11). retryTokens stays null until a retry actually fires
  // — "never attempted" and "attempted, zero tokens observed" are different
  // facts, and only the latter earns a 0.
  let retryCount = 0;
  let retryTokens = null;
  let retryWallClockMs = null;

  for (let slice = 0; slice < maxSlices; slice++) {
    if (buffer.length === 0) {
      // One executor agent, CI_POLL_SLICES_PER_BATCH (merge-state, ci-poll)
      // pairs, one Bash invocation. Never more slices than the budget has left.
      const nSlices = Math.min(CI_POLL_SLICES_PER_BATCH, maxSlices - slice);
      const steps = [];
      for (let k = 0; k < nSlices; k++) {
        steps.push({
          kind: 'merge-state',
          cmd: mergeStateCmd(ownerRepo, pr),
          stopGlobs: MERGE_CONFLICT_GLOBS,
        });
        steps.push({
          kind: 'ci-poll',
          cmd: ciPollCmd(ownerRepo, pr, sha),
          continueOutcomes: ['TIMEOUT'], // only a still-pending slice polls again
        });
      }
      const batch = await runMachineryBatch(steps, {
        label: `ci-batch:${item.slug}#${batchIdx++}`,
        slug: item.slug,
        bashTimeoutMs: CI_BATCH_BASH_TIMEOUT_MS,
        phase: enterStage(STAGE_CI), // 3g merge-state probe + CI poll slices
      });
      if (batch.denied) {
        // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
        const esc = await deniedOrQuota(item.slug, {
          step: 'ci-batch',
          steps: batch.steps,
          out: batch.out,
          sha,
        }, wt);
        return { escalation: esc.escalation.kind, payload: esc.escalation.payload };
      }
      // temperloop#1071 — a ci-batch step that outlived the liveness ceiling.
      // `adoptable:false` is load-bearing here: the probe still runs (its stage is
      // real evidence for the payload), but "an open PR exists" is NOT and must
      // never become evidence that CI passed, so there is no adopt arm on this
      // path — a bounded-out poll always escalates rather than resolving green.
      const ciTimeout = timedOutStep(batch.results);
      if (ciTimeout) {
        const disp = await disposeStepTimeout(item, wt, ciTimeout, 'ci-batch', { adoptable: false });
        return {
          escalation: 'machinery-step-timeout',
          payload: { ...disp.escalation.escalation.payload, sha },
        };
      }
      for (let k = 0; k < nSlices; k++) {
        const ms = batch.results[2 * k];
        const po = batch.results[2 * k + 1];
        if (ms === undefined && po === undefined) break; // short-circuited here
        buffer.push({ mergeState: ms ?? null, out: po });
      }
      if (buffer.length === 0) {
        // The executor came back with an empty results array — it ran nothing we
        // can read. Escalate rather than spin the remaining budget on a batch
        // that produces nothing.
        return { escalation: 'ci-failed', payload: { reason: 'ci poll batch returned no results', sha } };
      }
    }

    const bufferedSlice = buffer.shift();
    const mergeState = bufferedSlice.mergeState;

    // --- CONFLICTING/DIRTY early-exit (#543) ---------------------------------
    // GitHub never creates a CI check-suite for a PR whose merge ref can't be
    // computed (CONFLICTING/DIRTY), so ci-poll.sh returns TIMEOUT indefinitely.
    // The merge state is probed BEFORE each poll slice (it is the batched step
    // immediately preceding this slice's poll); if CONFLICTING/DIRTY, escalate
    // immediately rather than spinning the full CI_POLL_TOTAL_SECS budget.
    if (
      mergeState != null &&
      (mergeState.mergeable === 'CONFLICTING' || mergeState.mergeStateStatus === 'DIRTY')
    ) {
      log(`[${item.slug}] PR #${pr} is CONFLICTING/DIRTY — escalating merge-conflict (slice ${slice})`);
      return {
        escalation: 'merge-conflict',
        payload: { pr, mergeable: mergeState.mergeable, mergeStateStatus: mergeState.mergeStateStatus },
      };
    }

    // This slice's own ci-poll.sh object. Absent only if the batch truncated
    // without the merge-state gate firing (a malformed executor return) — the
    // ERROR sentinel then falls into the catch-all escalation at the bottom of
    // the loop rather than being silently skipped.
    const out =
      bufferedSlice.out ??
      { outcome: 'ERROR', error: 'ci-poll step produced no result in its batch' };

    if (out.outcome === 'CI_GREEN') {
      return { ok: true, finalSha: sha, fixReviewRounds, retryCount, retryTokens, retryWallClockMs };
    }

    if (out.outcome === 'NO_CI') {
      // temperloop#605/#618: ci-poll.sh's bounded grace window elapsed with
      // ZERO check-runs ever configured on the head SHA — a repo with no CI,
      // NOT a hang and NOT a failure. Mirror build.md 3g's legible skip: resolve
      // as success carrying a `noCi` marker so 3h parks `[m]` with the
      // `no_ci: true` sentinel, instead of falling through to the catch-all
      // below and escalating `ci-failed` (the exact mis-escalation this fixes).
      log(`[${item.slug}] PR #${pr}: no CI configured on this SHA — skipping the CI gate (slice ${slice + 1})`);
      return { ok: true, finalSha: sha, noCi: true, fixReviewRounds, retryCount, retryTokens, retryWallClockMs };
    }

    if (out.outcome === 'TIMEOUT') {
      // Slice elapsed with checks still pending → poll the next slice. This is
      // the normal "CI takes longer than one slice" path, NOT a failure.
      log(`[${item.slug}] CI still pending after slice ${slice + 1}/${maxSlices}`);
      continue;
    }

    if (out.outcome === 'CI_FAILED') {
      if (retriesLeft <= 0) {
        return { escalation: 'ci-failed', payload: { ciOut: out, sha } };
      }
      retriesLeft--;
      retryCount++; // temperloop#2065 — counted at ATTEMPT time, not at success
      // Re-spawn the worker against the SAME worktree to fix CI, then
      // force-push and re-poll PINNED to the new SHA (#254 guard).
      log(`[${item.slug}] CI failed — re-spawning worker (retries left ${retriesLeft})`);
      const cifixLabel = `worker-cifix:${item.slug}`;
      const cifixStartS = await safeWorkerClockNow(item, cifixLabel, enterStage(STAGE_CI));
      // temperloop#2065 review round 1 [HIGH]: agent({schema}) THROWS on a
      // StructuredOutput-absent / retry-cap-exceeded subagent — the SAME
      // primitive callWorker() wraps in try/catch for exactly this reason
      // (see that function's own comment). This call used to be bare: an
      // uncaught throw here skipped the workerUsageEmit() block below
      // entirely (never reaching it) AND propagated past this function
      // uncaught, converting to a generic top-level `worker-error`
      // escalation whose payload carries no cost field — silently dropping
      // not just the retry's own tokens but the item's WHOLE ledger (the
      // main worker's already-successful tokens/wall-clock too), since
      // driveItem never reaches park(). Catch it here and normalize into the
      // SAME "no verdict" shape the null-return arm below already handles,
      // so the emit call is never skippable and this always resolves to a
      // clean, in-band escalation instead of an uncaught throw.
      let fixVerdict = null;
      let fixThrew = null;
      try {
        fixVerdict = await agent(
          workerPrompt(
            item,
            wt,
            '## CI failed\nThe pushed branch failed CI. First run ' +
              '`git fetch origin ' + item.branch + ' && git reset --hard FETCH_HEAD`, ' +
              'then fix the failure and commit (do NOT push). ' +
              'Failed run ids: ' + JSON.stringify(out.failed_run_ids ?? []) + '.',
          ),
          {
            label: cifixLabel,
            // A WORKER agent, but it belongs to the CI stage (temperloop#1294) —
            // grouping it there is what makes the CI box read as "CI is being fixed"
            // rather than dropping it back into a build box the level already left.
            phase: enterStage(STAGE_CI),
            // Escalate-on-retry: a CI-failure re-spawn runs top tier (omit model).
            schema: WORKER_VERDICT_SCHEMA,
          },
        );
      } catch (err) {
        fixThrew = String((err && err.message) || err);
      }
      // temperloop#2065 — the retry's own cost, regardless of what fixVerdict
      // turns out to be below (or whether agent() threw above instead): the
      // tokens were spent (and the wall-clock burned) the moment agent()
      // returned OR threw, and a fix that FAILS — or never returns a verdict
      // at all — still cost real money. Tokens roll up into ONE combined
      // `retryTokens` figure (the epic's ledger names "retry tokens" as a
      // single number, unlike the main worker's split tokens_in/tokens_out —
      // see park()); wall-clock rolls into the SAME total `wall_clock_ms` the
      // main worker contributes to (driveItem sums it into mainCost at the
      // ciPollLoop call site) — there is one wall-clock figure for the whole
      // item, not a per-phase one.
      {
        const cifixUsage = await safeWorkerUsageEmit(item, cifixLabel, 'build-worker', enterStage(STAGE_CI));
        const inT = cifixUsage.tokensIn ?? 0;
        const outT = cifixUsage.tokensOut ?? 0;
        retryTokens = (retryTokens ?? 0) + inT + outT;
        retryWallClockMs = (retryWallClockMs ?? 0) + (elapsedMs(cifixStartS, cifixUsage.epochS) ?? 0);
      }
      if (fixThrew != null) {
        // agent() threw — the same "no verdict" outcome as the bare-null
        // return handled just below, only reached via the throw arm instead.
        // Escalate in-band rather than letting the throw propagate past this
        // function uncaught (which would land as a generic worker-error).
        return { escalation: 'ci-failed', payload: { reason: `ci-fix agent threw: ${fixThrew}`, retryable: true, sha } };
      }
      if (fixVerdict == null) {
        // agent() returned null — user skip or terminal API error in the CI-fix
        // worker. Already inside a CI-failure retry context; escalate cleanly.
        return { escalation: 'ci-failed', payload: { reason: 'ci-fix agent returned null', retryable: true, sha } };
      }
      if (fixVerdict.status !== 'done') {
        return { escalation: 'ci-failed', payload: { fixVerdict, sha } };
      }
      // temperloop#1450 — re-run §3e against the CI-fix DIFF before pushing it.
      // The fix worker can touch anything (including the very command doc
      // whose edit tripped the original lint failure): without this, a
      // CI-fix commit ships to the open PR with NO second pass through the
      // mandatory claude/commands/*.md -> workflow-reviewer rule
      // (foundation#1007) — the exact structurally-guaranteed-skip class this
      // item exists to close, just relocated one stage later than 3f. Reuses
      // the SAME runReviewers() the original 3e pass used; its own diff fetch
      // re-reads the worktree, whose HEAD now includes the fix commit, so the
      // diff naturally covers the fix on top of the original push.
      const fixReview = await runReviewers(item, wt);
      if (fixReview.escalation) {
        const esc = fixReview.escalation.escalation;
        return { escalation: esc.kind, payload: { ...esc.payload, sha } };
      }
      if (fixReview.blocking.length > 0) {
        // temperloop#1970 — the SAME convergence bound the 3e pass applies, via
        // the SAME predicate, over the SAME per-worktree round counter: this is
        // one item's review budget, not a second independent one. Under the
        // bound this escalates byte-identically to pre-#1970. At it, the fix is
        // pushed and the residual findings ride 3g.5's merged body re-render
        // (fixReviewRounds below feeds reviewBodySuffix) plus the parked tally.
        if (!reviewBoundReached(fixReview)) {
          log(`[${item.slug}] §3e review on the CI-fix commit found a BLOCKING finding — escalating before push`);
          return {
            escalation: 'review-blocking',
            payload: {
              findings: fixReview.blocking,
              stage: 'ci-fix',
              sha,
              round: fixReview.round,
              max_rounds: REVIEW_BLOCKING_MAX_ROUNDS,
            },
          };
        }
        fixReview.residualBlocking = true;
        log(
          `[${item.slug}] §3e review on the CI-fix commit: round ${fixReview.round}/${REVIEW_BLOCKING_MAX_ROUNDS} ` +
            `still has ${fixReview.blocking.length} BLOCKING finding(s) — convergence bound reached ` +
            `(temperloop#1970): pushing the fix with them carried in ## Review notes instead of escalating again`,
        );
      }
      fixReviewRounds.push(fixReview);
      // Push the fixed SHA and pin the re-poll to it. This is a plain push — no
      // --force — because the CI-fix worker's head is a fast-forward descendant
      // by construction: it resets to the remote tip (`git reset --hard
      // FETCH_HEAD`) and commits on top, so the local head strictly descends
      // from the current remote tip. A plain push therefore always succeeds on
      // the intended path. We deliberately do NOT pass a classifier-visible
      // --force here: pr.sh's internal downgrade cannot prevent the git-
      // destructive safety classifier from pre-emptively denying the command
      // as SPINE_DENIED (#437), which would mask a routine retry as an opaque
      // pre-execution denial. If the head is somehow a genuine non-fast-forward,
      // the plain push surfaces as a visible PUSH_REJECTED outcome (triaged
      // below), not an opaque SPINE_DENIED. (pr.sh's --force→plain downgrade is
      // retained for other callers that legitimately rewrite history — #335.)
      const prBin = machineryBin(input.repoRoot, 'pr.sh');
      const fpush = await runMachinery(
        `${prBin} push ${sq(wt)} ${sq(item.branch)}`,
        { label: `push-retry:${item.slug}`, slug: item.slug, phase: enterStage(STAGE_CI) },
      );
      if (machineryDenied(fpush)) {
        // temperloop#1819: quota death vs genuine denial — see deniedOrQuota.
        const esc = await deniedOrQuota(item.slug, { step: 'push-retry', out: fpush, sha }, wt);
        return { escalation: esc.escalation.kind, payload: esc.escalation.payload };
      }
      // temperloop#1071 — the force-push outlived the liveness ceiling. It is the
      // single most dangerous step to guess about (a re-issue could push a second
      // time over work the first push may already have landed), so it takes the
      // probe-then-escalate disposal and never the retry the `ci-failed` arm
      // below would otherwise imply. `adoptable:false`: this loop is polling a PR
      // it already has — there is nothing to adopt, only a SHA to establish.
      if (fpush.outcome === 'STEP_TIMEOUT') {
        const disp = await disposeStepTimeout(item, wt, fpush, 'push-retry', { adoptable: false });
        return {
          escalation: 'machinery-step-timeout',
          payload: { ...disp.escalation.escalation.payload, sha },
        };
      }
      if (fpush.outcome !== 'PUSHED') {
        return { escalation: 'ci-failed', payload: { fpush, sha } };
      }
      // temperloop#2014 — the FIFTH `--sha` assignment, and the one the issue's
      // own audit list does not name: the re-push's reported SHA arrives
      // through the same executor transport as the 3f push, so it can go
      // missing the same way. Guarded BEFORE it is adopted, so the previous
      // (still valid, but now stale) `sha` is never silently re-polled either —
      // re-polling the pre-fix head is the #254 false-green this pin exists to
      // prevent.
      if (hexSha(fpush.sha) === null) {
        return {
          escalation: 'ci-poll-bad-argument',
          payload: badShaEscalation(
            pr,
            fpush.sha,
            'ci-fix-push',
            'the CI-fix re-push reported PUSHED but produced no usable head SHA to re-pin the poll to',
          ),
        };
      }
      sha = fpush.sha; // authoritative — pin the next poll to it (NOT the PR API)
      // FLUSH any slices still buffered from the pre-fix batch: they were polled
      // against the OLD head and reading them now would re-resolve CI on a stale
      // SHA — exactly the #254 false-green the --sha pin exists to prevent. The
      // next iteration refills the buffer with polls pinned to the new sha.
      buffer = [];
      continue;
    }

    // ERROR or any unexpected outcome (e.g. ci-poll.sh itself errored) →
    // escalate rather than spin.
    //
    // temperloop#2014 — but NOT as `ci-failed` when ci-poll.sh refused to run on
    // its own arguments. `ci-failed` means "this PR's CI is red", and a run
    // disposing on it parks or re-drives a healthy PR; a bad argument means the
    // poll never observed CI at all, so it is its own kind with its own
    // disposition. The pre-flight above makes this unreachable from the
    // driver's own hand-off — this arm catches the argument errors the driver
    // does not own (a stale vendored ci-poll.sh, an owner/repo or PR number
    // this file passed through from its input).
    if (isBadArgumentError(out)) {
      return {
        escalation: 'ci-poll-bad-argument',
        payload: { ...badShaEscalation(pr, sha, 'ci-poll', 'ci-poll.sh rejected its own arguments'), ciOut: out },
      };
    }
    return { escalation: 'ci-failed', payload: { ciOut: out, sha } };
  }

  // Total budget exhausted without CI_GREEN/CI_FAILED resolution.
  return { escalation: 'ci-failed', payload: { reason: 'ci-poll budget exhausted', sha } };
}

// =============================================================================
// levelPhaseTitle — the run-identifying progress-row heading (temperloop#903),
// now emitted ONCE PER STAGE rather than once per level (temperloop#1294).
// =============================================================================
// The Workflow progress UI renders one row per workflow (labelled from the PURE
// LITERAL `meta.description`, which by runtime constraint is byte-identical on
// every run) plus a group heading per phase(). phase() is therefore the ONLY
// surface that can carry run context — and it used to read `build level — N
// item(s)`, which identifies nothing: not the repo, not the items, not the
// issues. Two concurrent spine runs (routine: one /fix session drives several
// back to back) rendered indistinguishable rows.
//
// The heading names, from context already in scope at the call site:
//   build level · <stage> — <ownerRepo> · <N> item(s) · <slug> (#<ghIssue>), …
// e.g.  build level · gate — Towheads/foundation · 1 item · row-per-stage (#1294)
//
// temperloop#1294 added the `· <stage>` segment and made the level emit ONE
// phase() PER STAGE (claim → build → gate → PR → CI) instead of a single static
// heading for the whole level. Two independent effects, both wanted:
//   • the ACTIVE phase now ADVANCES as the level progresses, so a collapsed view
//     that renders it moves instead of sitting on one heading all run;
//   • the expanded progress tree groups agents by stage instead of dumping every
//     executor into one 'machinery' box.
// The #903 run context rides EVERY stage heading — dropping it from the later
// stages would re-open exactly the complaint #903 closed.
//
// TWO SURFACES, ONE STRING. `phase(t)` moves the GLOBAL cursor (what a collapsed
// view shows); `agent(…, {phase: t})` assigns one agent to the group named `t`.
// The Workflow docs are explicit that the global cursor RACES inside
// parallel()/pipeline() stages — this level fans its items out with parallel(),
// so item A can be at CI while item B is still at build. Every agent spawn below
// therefore passes opts.phase EXPLICITLY (same string → same group box) and never
// relies on whatever the global cursor happens to be. enterStage() returns that
// string and, as a side effect, advances the global cursor MONOTONICALLY (a stage
// already passed never re-fires), so the collapsed row tracks the level's
// furthest-reached stage and can never appear to run backwards when a straggler
// item is still on an earlier one.
//
// meta.phases: DELIBERATELY ABSENT. `meta` is a pure literal by runtime
// constraint, and meta.phases entries are matched against phase() titles
// EXACTLY. Every title here is dynamic by construction (#903 requires the repo,
// the item count and the item/issue list in it), so no static entry could ever
// match one — declaring the five stages statically would render five permanently
// EMPTY groups alongside the five real ones. Per the runtime's own contract a
// phase() call with no matching meta entry simply gets its own progress group,
// which is the correct outcome here; this is a noted, accepted consequence of
// #903's dynamic-title requirement, not an oversight to work around.
//
// BOUNDED BY CONSTRUCTION: a level can hold many items, so at most
// PHASE_TITLE_MAX_ITEMS slugs are named and the rest collapse to `+K more` — a
// 20-item level can never emit a 20-slug heading that swamps the progress row.
// Every field is optional-safe (a missing ownerRepo / ghIssue simply drops its
// segment) because this is a cosmetic display string: it must never be the thing
// that throws and takes a level down.
const PHASE_TITLE_MAX_ITEMS = 3;

// The level's stages, in the order an item passes through them. STAGE_RECOVER is
// deliberately NOT in STAGE_ORDER: the recovery probes (pr.sh recover-probe, the
// lost-return resume batch) are off-path diagnostics that can fire from any
// stage, so they get their own progress group but must never move the global
// cursor — otherwise a single item's recovery would drag the whole level's
// collapsed row backwards.
const STAGE_CLAIM = 'claim';
const STAGE_BUILD = 'build';
const STAGE_REVIEW = 'review';
const STAGE_GATE = 'gate';
const STAGE_PR = 'PR';
const STAGE_CI = 'CI';
const STAGE_RECOVER = 'recover';
const STAGE_ORDER = [STAGE_CLAIM, STAGE_BUILD, STAGE_REVIEW, STAGE_GATE, STAGE_PR, STAGE_CI];

// The items whose slugs/issues every stage heading names — the ACTIVE subset
// (post-onlySlugs filter), assigned by buildLevel() before any fan-out. Empty
// until then, which is safe: nothing spawns an agent before it is set.
let phaseItems = [];
// Index into STAGE_ORDER of the furthest stage any item has reached this run.
let stageReached = -1;

// itemTag — `<slug> (#<issue>)`, or the bare slug when the item has no issue
// (kind:spike items and board-OFF runs legitimately carry no ghIssue).
function itemTag(item) {
  const slug = (item && item.slug) || '(unnamed)';
  const issue = item && item.ghIssue;
  return issue ? `${slug} (#${issue})` : slug;
}

// levelPhaseTitle(list, stage) — the heading itself. `stage` is optional; absent
// it reproduces the pre-#1294 level-wide form byte-for-byte.
function levelPhaseTitle(list, stage) {
  const items = Array.isArray(list) ? list : [];
  const parts = [];
  if (typeof input.ownerRepo === 'string' && input.ownerRepo.length > 0) {
    parts.push(input.ownerRepo);
  }
  parts.push(`${items.length} item${items.length === 1 ? '' : 's'}`);
  const named = items.slice(0, PHASE_TITLE_MAX_ITEMS).map(itemTag);
  if (named.length > 0) {
    const rest = items.length - named.length;
    parts.push(named.join(', ') + (rest > 0 ? ` +${rest} more` : ''));
  }
  const head = stage ? `build level · ${stage}` : 'build level';
  return `${head} — ${parts.join(' · ')}`;
}

// stagePhase(stage) — the group name for `stage`, WITHOUT touching the global
// cursor. Used by the off-path recovery spawns.
function stagePhase(stage) {
  return levelPhaseTitle(phaseItems, stage);
}

// enterStage(stage) — returns the group name for `stage` (hand it straight to
// opts.phase) and advances the global phase cursor to it the first time the
// level reaches that stage. Monotonic: a later item re-entering an earlier stage
// is a no-op on the cursor, and STAGE_RECOVER (not in STAGE_ORDER) never moves
// it at all. Cosmetic by construction — it must never throw.
function enterStage(stage) {
  const title = stagePhase(stage);
  const i = STAGE_ORDER.indexOf(stage);
  if (i > stageReached) {
    stageReached = i;
    phase(title);
  }
  return title;
}

// =============================================================================
// The ZERO-DISPOSITION guard (temperloop#2004).
//
// /build Step 3, /fix Step 4a and /sweep Phase 2 all branch on the returned
// {parked, escalations}: each handles `parked` non-empty and `escalations`
// non-empty, and NONE had an arm for both being empty. A {parked:[],
// escalations:[]} return therefore matched no branch and fell through as "the
// level completed with nothing to report" — so an item that was asked for and
// disposed of nowhere vanished with no PR, no park, no escalation and no
// signal. (Observed 2026-09-13, run wf_f3b9c160-6ca: a stopped-and-resumed run
// returned an empty object in ~13 ms having re-run nothing, while the tracked
// issue was still in-progress with a live claim stamp.)
//
// The guard lives HERE, below the three drivers, so all three inherit it once
// rather than each restating it — the same hoist shape temperloop#2006 used
// for the sideline notice. It returns a NAMED, branchable value (never a bare
// throw): the drivers re-probe real state on it instead of concluding
// anything.
//
// The two CONTROLS are what make it discriminating rather than noisy — a guard
// that flags every legitimately empty level is worse than none:
//   1. nothing was asked to drive (empty `items`, or an onlySlugs filter that
//      matched no item) → disposing of nothing is a tautology, not a
//      contradiction. Silent, and the returned object is byte-identical to
//      before this item.
//   2. something WAS disposed → any parked record or any escalation means the
//      drive reported on the set. This is also what clears the kind:spike
//      path: a spike opens no PR and pushes no SHA, but it still `park()`s a
//      verdict marker (`park(slug, null, null, …)`), so a spike-only level
//      lands in control 2 and is never flagged.
// Returns null when either control holds; otherwise the named outcome.
// =============================================================================
function zeroDispositionContradiction(activeItems, parked, escalations) {
  if (activeItems.length === 0) return null;                    // control 1
  if (parked.length > 0 || escalations.length > 0) return null; // control 2

  const ownerRepo = typeof input.ownerRepo === 'string' && input.ownerRepo.length > 0
    ? input.ownerRepo
    : null;
  const items = activeItems.map((it) => {
    const worktree = `${input.repoRoot}.wt/${it.slug}`;
    const headRef = it.branch ?? `build/${it.slug}`;
    const probes = [];
    if (ownerRepo && it.ghIssue) {
      probes.push(`gh issue view ${it.ghIssue} -R ${ownerRepo} --json state,labels,title`);
    }
    if (ownerRepo) {
      probes.push(`gh pr list -R ${ownerRepo} --head ${headRef} --state all --json number,state,headRefOid`);
    }
    probes.push(`git -C ${worktree} status --short --branch`);
    return {
      slug: it.slug,
      issue: it.ghIssue ?? null,
      branch: it.branch ?? null,
      worktree,
      // The caller acts on THIS: exactly what to look at before concluding
      // anything about this slug.
      reprobe: probes.join(' ; '),
    };
  });

  return {
    // Which slugs were asked for and disposed of none — the whole point.
    slugs: items.map((i) => i.slug),
    items,
    requested: activeItems.length,
    parked: 0,
    escalations: 0,
    // True when this was a continuation run (onlySlugs scoped the set) — the
    // shape the observed replay took; false on a fresh level.
    continuation: Array.isArray(input.onlySlugs) && input.onlySlugs.length > 0,
    reason:
      `the level was asked to drive ${activeItems.length} item(s) and disposed of NONE — ` +
      'zero parked and zero escalations. This is a contradiction, not a completed level: ' +
      'nothing may be concluded from this return. Re-probe issue status, open PRs and the ' +
      'worktree for each slug below before deciding anything.',
  };
}

// =============================================================================
// ITEM-KEY NORMALIZATION AT THE ORCHESTRATOR→WORKFLOW SEAM (temperloop#1700).
// =============================================================================
// This file reads the item's issue number as `item.ghIssue`. `claude/plan-schema.md`
// DOCUMENTS the field as `gh_issue:`, and `also_closes:` / `depends-on:` likewise.
// A caller that constructs items from the documented schema — a legitimate
// calling pattern, since the schema is what documents it — therefore gets:
//
//   no `--gh-issue` flag on `pr.sh open` → no `Closes #N` in the body →
//   a PR that merges green and leaves its issue OPEN → and no warning anywhere.
//
// Observed on PR #1697 (`closingIssuesReferences` empty); three PRs from one
// level merged closing nothing. The SILENCE is the defect: "this item has no
// tracked issue" is a legal state (`gh_issue:` is optional), so an unread key is
// indistinguishable from an absent one, and the merged-with-no-linkage PR leaves
// a stranded `fnd:status:in-progress` item wearing a live claim stamp.
//
// Same family as #1698 above — one meaning wearing two names across a seam, with
// the consumer's absent-key path producing a plausible-looking result instead of
// an error. Both halves the issue asks for are implemented, because each catches
// what the other cannot:
//   (1) ACCEPT the documented spelling, normalizing once here. Fixes the three
//       aliases we know about.
//   (2) WARN on a key nothing reads. Catches the NEXT one — the class, not the
//       instance.
const ITEM_KEY_ALIASES = {
  gh_issue: 'ghIssue',
  also_closes: 'alsoCloses',
  'depends-on': 'dependsOn',
  depends_on: 'dependsOn',
  parent_epic: 'parentEpic',
  parent_summary: 'parentSummary',
};
// Every key this file actually READS off an item. This list is not a
// hand-maintained copy that drifts: the K1700 lockstep guard in
// test_workflow.sh greps THIS file for `item.<key>` dereferences and
// reconciles the resulting set against this array in BOTH directions — a read
// missing from the list, or a listed key nothing reads any more, fails the
// suite. (Round 2: the comment used to claim that guard before it existed,
// which is the same "a backstop that is only asserted in prose" defect this PR
// removes elsewhere. The guard is real now.)
const ITEM_KEYS_READ = [
  'slug', 'branch', 'title', 'kind', 'ghIssue', 'alsoCloses', 'repo', 'model',
  'acceptance', 'source', 'scope', 'notes', 'dependsOn', 'activation',
  'parentEpic', 'parentSummary', 'review',
];
// Documented plan-schema (and orchestrator bookkeeping) fields this file
// deliberately does NOT read — the plan note carries them for its own use, and
// warning on them would drown the signal the warning exists to carry.
const ITEM_KEYS_IGNORED = [
  'after', 'epic', 'gate_check', 'gateCheck', 'size', 'files', 'seq',
  'status', 'pr', 'pushed_sha', 'pushedSha', 'no_ci', 'noCi', 'arm', 'id',
];
function normalizeItem(raw) {
  if (raw == null || typeof raw !== 'object') return raw;
  const item = { ...raw };
  const known = new Set([...ITEM_KEYS_READ, ...ITEM_KEYS_IGNORED, ...Object.keys(ITEM_KEY_ALIASES)]);
  const unknown = [];
  for (const key of Object.keys(raw)) {
    const canonical = ITEM_KEY_ALIASES[key];
    if (canonical) {
      // The camelCase spelling WINS when both are present — it is what this file
      // has always read, so a caller passing both cannot be silently retargeted.
      if (item[canonical] === undefined) {
        item[canonical] = raw[key];
        log(
          `[${raw.slug ?? '?'}] item key '${key}' accepted as '${canonical}' (temperloop#1700) — ` +
          `the documented plan-schema spelling; it used to be read by nothing and dropped in silence.`,
        );
      } else if (JSON.stringify(item[canonical]) !== JSON.stringify(raw[key])) {
        log(
          `[${raw.slug ?? '?'}] item carries BOTH '${key}' and '${canonical}' with DIFFERENT values ` +
          `(temperloop#1700) — using '${canonical}'; drop one in the caller.`,
        );
      }
      continue;
    }
    if (!known.has(key)) unknown.push(key);
  }
  if (unknown.length > 0) {
    // The generalization of the fix: a key nothing reads is named, once, rather
    // than absorbed. An item with NEITHER spelling of a known field stays legal
    // and silent — a genuinely untracked item is a normal state, not a warning.
    log(
      `[${raw.slug ?? '?'}] item carries key(s) this workflow does not read: ${unknown.join(', ')} ` +
      `(temperloop#1700). If one of them is meant to drive behaviour, it is being IGNORED.`,
    );
  }
  return item;
}

// =============================================================================
// Entry point — drive the level, return {parked, escalations}.
// =============================================================================
async function buildLevel() {
  // temperloop#1700 — normalize the DOCUMENTED plan-schema spellings into the
  // camelCase keys this file reads, ONCE, at the single point items enter. Every
  // later `item.ghIssue` / `item.alsoCloses` / `item.dependsOn` read — including
  // the 3f `--gh-issue` / `--also-closes` flags whose absence merged three PRs
  // closing nothing — is fed from here.
  const items = (input.items ?? []).map(normalizeItem);
  log(`repoRoot=${input.repoRoot} board=${input.board ?? 'OFF'} plan=${input.planLink}`);

  // onlySlugs — optional continuation filter (escalation-resume loop).
  // When the orchestrator re-invokes this workflow after capturing a human
  // verdict for one or more escalated items, it passes input.onlySlugs as an
  // array of slugs to re-drive. Only those items enter the pipeline; their
  // sibling items are already parked ([m] with pr: on the plan note) and must
  // not be re-driven. An absent or empty onlySlugs means "drive everything."
  const slugFilter = Array.isArray(input.onlySlugs) && input.onlySlugs.length > 0
    ? new Set(input.onlySlugs)
    : null;
  const activeItems = slugFilter
    ? items.filter((item) => slugFilter.has(item.slug))
    : items;
  if (slugFilter) {
    log(`continuation mode — onlySlugs=[${[...slugFilter].join(',')}] active=${activeItems.length}/${items.length}`);
  }

  // Name the run in the progress row (temperloop#903). Set AFTER the onlySlugs
  // filter on purpose: on a continuation the heading must name the slugs actually
  // being re-driven, not the level's full membership (whose siblings are already
  // parked and untouched). Nothing above this point awaits, so the row is never
  // observed unlabelled.
  //
  // temperloop#1294: `phaseItems` is the ONE assignment that binds every later
  // stage heading to this run's active items — it must land before any agent
  // spawns. enterStage() then opens the first stage (claim) and each later stage
  // advances the cursor from its own spawn site inside driveItem().
  phaseItems = activeItems;
  stageReached = -1;
  enterStage(STAGE_CLAIM);

  // Drive every active item through 3a–3h. The items in one level are
  // independent by construction (no merge edge between them), so we fan them
  // out with parallel() — the substrate caps concurrency (~cores-2). This
  // matches build.md's "express each item's pipeline as a parallel() over
  // the level's items" (within-level execution). parallel() returns the array
  // of per-item results in item order; a blocked/failed item escalates rather
  // than halting its siblings (the orchestrator batches escalations at the
  // boundary). On a continuation run only the named slugs enter parallel(); the
  // rest are already parked and are left untouched.
  // A thrown exception in driveItem must NOT vanish: parallel() drops a rejected
  // thunk to null, which would leave the item in NEITHER parked NOR escalations —
  // silently lost, violating the no-silent-stall invariant. Convert any throw into
  // a generic `worker-error` escalation so it always surfaces. (#437: a real run
  // hit item.acceptance.map on a string and the item was silently dropped.)
  // temperloop#2020: `.then(preserveOnEscalation)` is applied to the SETTLED
  // result — after the #437/#1819 catch above, so a THROWN item's synthesized
  // escalation gets the same work-preservation push a returned one does. This
  // is the single choke point for "an escalation is about to leave this
  // driver"; see preserveOnEscalation's own comment for why it lives here and
  // not at the ~30 individual escalate() call sites.
  //
  // temperloop#2080 — the DUAL-BUILD fan-out is an alternative to this one, not
  // a flag inside it. A `dualBuild` input restructures the level into build →
  // barrier → judge → record (driveLevelDualBuild), which is a different
  // control flow, not a different parameter; keeping the two apart is what
  // makes "no dualBuild input → this exact fan-out, unchanged" true by reading
  // the code rather than by tracing a branch through it.
  let dualSummary = null;
  let results;
  const dual = dualBuildInput();
  if (dual && dual.invalid) {
    // REFUSE, never degrade. A level asked to compare two models that quietly
    // compared none is indistinguishable, after the fact, from one that did.
    log(`dual-build INPUT INVALID — refusing the level: ${dual.invalid}`);
    results = activeItems.map((item) =>
      escalate(item.slug, 'dual-build-input-invalid', {
        reason: dual.invalid,
        received: input.dualBuild,
        remedy: 'pass dualBuild as { tier, baseline, candidate, inScope: [slug…] } (build.md Step 0/1 builds it from --dual-build via dual-build-preflight.sh), or drop the input entirely to build single-arm',
      }),
    );
  } else if (dual) {
    const driven = await driveLevelDualBuild(activeItems, dual);
    results = driven.results;
    dualSummary = driven.summary;
  } else {
  results = await parallel(
    activeItems.map((item) => () =>
      driveItem(item).catch((err) => {
        // temperloop#1819: a throw whose message carries the harness's
        // session-limit text is a quota death, not a content failure — it gets
        // its own kind here too, so no thrown shape can collapse back into
        // worker-error. Anything else keeps the #437 conversion unchanged.
        const msg = String((err && err.message) || err);
        if (quotaDeath(msg)) {
          return quotaEscalation(item.slug, 'mid-item throw', {
            errorText: msg,
            worktree: `${input.repoRoot}.wt/${item.slug}`,
          });
        }
        return escalate(item.slug, 'worker-error', { error: String((err && err.stack) || err) });
      }).then((r) => preserveOnEscalation(item, r)).then((r) => stampSideline(item, r)),
    ),
  );
  }

  // Partition the per-item results into the small return object. NEVER write
  // the plan note here — only RETURN what to write (orchestrator serializes
  // writeback at the level boundary).
  const parked = [];
  const escalations = [];
  for (const r of results) {
    if (!r) continue;
    if (r._kind === 'parked') parked.push(r.parked);
    else if (r._kind === 'escalation') escalations.push(r.escalation);
  }

  // temperloop#2006 — the LEVEL-SUMMARY half of the sideline notice. Each
  // per-item record already carries its own `sidelined` object (stampSideline
  // at the fan-out above); this rolls the level's set up onto the returned
  // object so the orchestrator's Step 6 summary and the merge gate see it
  // without re-walking two arrays. Omitted entirely when nothing sidelined, so
  // an ordinary level's return is byte-identical to before this item.
  //
  // temperloop#2080 — the map is keyed by the RECORD key, which for a
  // dual-build arm is `<slug>@<arm>` (that is what phase 1 sees as item.slug).
  // Walking `activeItems` alone would therefore find NEITHER arm's notice and
  // the level would report zero sideline notices while two builds sat shelved.
  // So the rollup walks the map's own keys and splits the arm back out: a
  // two-arm item that sidelined both arms produces TWO entries, one per arm,
  // and a single-arm level produces exactly the pre-#2080 list (same entries,
  // same order, no `arm` key) because the arm lookups simply miss. The walk
  // stays over `activeItems` rather than over the map's own insertion order so
  // the list is deterministic — insertion order is parallel-completion order,
  // which would reshuffle the rollup run to run.
  const sidelined = [];
  for (const it of activeItems) {
    const plain = SIDELINE_NOTICES.get(it.slug);
    if (plain) sidelined.push({ slug: it.slug, ...plain });
    for (const armName of DUAL_BUILD_ARMS) {
      const armNotice = SIDELINE_NOTICES.get(`${it.slug}@${armName}`);
      if (armNotice) sidelined.push({ slug: it.slug, arm: armName, ...armNotice });
    }
  }
  if (sidelined.length > 0) {
    log(
      `level SIDELINED BUILD summary — ${sidelined.length} resumable build(s) shelved by worktree.sh create: ` +
        sidelined.map((s) => `${s.slug} → ${s.path}${s.branch ? ` (${s.branch})` : ''}`).join('; '),
    );
  }

  // temperloop#2004 — the ZERO-DISPOSITION guard, evaluated on the SETTLED
  // partition (after the loop above, so it sees what actually came back) and
  // on `activeItems` (the post-onlySlugs set this run was actually asked to
  // drive, which is the only set the contradiction is defined over).
  const zeroDisposition = zeroDispositionContradiction(activeItems, parked, escalations);
  if (zeroDisposition) {
    log(
      `level ZERO-DISPOSITION contradiction — ${zeroDisposition.requested} item(s) driven, ` +
        `0 parked, 0 escalations: ${zeroDisposition.slugs.join(', ')}. ` +
        'NOT a completed level — re-probe before concluding anything. ' +
        zeroDisposition.items.map((i) => `${i.slug} → ${i.reprobe}`).join(' || '),
    );
  }

  log(
    `level done — parked=${parked.length} escalations=${escalations.length}` +
      (sidelined.length > 0 ? ` sidelined=${sidelined.length}` : '') +
      (zeroDisposition ? ' ZERO-DISPOSITION (contradiction — see notice above)' : ''),
  );
  // Both extra keys are OMITTED when their condition does not hold, so an
  // ordinary level's return stays byte-identical to before #2006/#2004.
  const ret = { parked, escalations };
  if (sidelined.length > 0) ret.sidelined = sidelined;
  if (zeroDisposition) ret.zeroDisposition = zeroDisposition;
  // temperloop#2080 — the level's dual-build summary: which items were compared,
  // where the barrier stands, how many ledger rows landed, and the board writes
  // held back for the pick. Present ONLY on a dual-build run (same
  // omitted-unless-it-holds shape as `sidelined`/`zeroDisposition` above), so a
  // flag-less level's returned object is byte-identical to before this item.
  if (dualSummary) ret.dualBuild = dualSummary;
  return ret;
}

// Top-level entry (#437): the Workflow runtime wraps this script body in an async
// context and does NOT call a default export — it runs the top-level body. So we
// invoke the driver and return its value here, at top level. (This file is
// therefore a Workflow-runtime script, NOT a standalone ESM — top-level `return`
// means it cannot be `node --check`'d or `import()`'d; the test harness simulates
// the runtime wrap instead.)
return await buildLevel();
