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
// note.
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
//        dependsOn }],
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
//       escalations: [{ slug, kind, payload }] }
//
//   A parked record MAY additionally carry `acceptance_unverified: true` +
//   `recovered_from: <RECOVER_* stage>` (temperloop#939). That pair means the
//   worker's return channel failed and this record was RECONSTRUCTED from
//   observable side-effects: the PR and SHA are ground truth, but the acceptance
//   results are UNKNOWN — never treat them as passing. The orchestrator MUST
//   re-verify that item's acceptance itself before the Step 4 merge gate.
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
// statement of what the run DOES; the run-IDENTIFYING half (repo, items, issues)
// rides the one dynamic surface there is, the phase() title — see
// levelPhaseTitle() near the entry point. Return shape, the never-merges rule and
// the never-writes-the-plan-note rule are contract detail and live in the I/O
// CONTRACT block above; do not re-state them here.
export const meta = {
  name: 'build-level',
  description:
    'Drives one dependency level of an approved /build plan: claims each item on the board, builds it in its own isolated worktree, runs the acceptance gate, opens its PR and watches CI.',
  version: '1.0.0',
};

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
        'REBASED', 'REBASE_CONFLICT',
        'PUSHED', 'PUSH_REJECTED',
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
    error: { type: 'string' },
    matches: { type: 'array', items: { type: 'string' } },
    failed_run_ids: { type: 'array', items: { type: ['number', 'string'] } },
    // free-form detail the executor may pass through (e.g. gate output tail)
    detail: { type: 'string' },
    // 3e.5 sliced-gate fields (temperloop#1021). resumeAt — the 0-based gate
    // index the NEXT slice starts at; failed — failures seen in THIS slice (the
    // driver accumulates); elapsedSecs / budgetSecs — the margin pair that makes
    // suite growth observable on every run, not only when it blows a budget.
    resumeAt: { type: ['number', 'string'] },
    failed: { type: ['number', 'string'] },
    elapsedSecs: { type: ['number', 'string'] },
    budgetSecs: { type: ['number', 'string'] },
    // temperloop#1071 step-liveness fields, carried by STEP_TIMEOUT / STEP_SLOW.
    // `step` is the batch step's own `kind` (or 'solo'), so an escalation payload
    // names WHICH machinery call the ceiling bounded without any correlation work.
    step: { type: 'string' },
    ceiling_secs: { type: ['number', 'string'] },
    elapsed_secs: { type: ['number', 'string'] },
    slow_secs: { type: ['number', 'string'] },
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

// -----------------------------------------------------------------------------
// Command-building helpers — EVERY interpolated value goes through sq().
// -----------------------------------------------------------------------------

// sq — POSIX single-quote a value for safe shell interpolation. A spaced path
// MUST be quoted or the one-shot executor runs the wrong command (the live-probe
// finding). Wraps in single quotes and escapes any embedded single quote via the
// '\'' idiom. Numbers are coerced to string.
function sq(value) {
  const s = String(value);
  return `'${s.split("'").join(`'\\''`)}'`;
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
  // resolved the build-machinery directory in its OWN shell (build.md Step 0) and
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
// runMachinery — the sh() replacement (spike §1).
// -----------------------------------------------------------------------------
// Spawns a one-shot executor agent that runs EXACTLY one machinery command via Bash
// and returns its single closed-outcome JSON line, schema-validated. No model
// override beyond haiku (cheapest tier — the executor does no reasoning); NO
// isolation:'worktree' (the machinery scripts manage their own worktrees, §5).
async function runMachinery(cmd, { label, slug, bashTimeoutMs, timeoutOutcome } = {}) {
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
      phase: 'machinery',
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
  return out == null ? { outcome: 'SPINE_DENIED', denied: true } : out;
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
async function runMachineryBatch(steps, { label, slug, bashTimeoutMs } = {}) {
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
      phase: 'machinery',
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
  const notices = out.results.filter((r) => r && r.outcome === 'STEP_SLOW');
  const results = out.results.filter((r) => !(r && r.outcome === 'STEP_SLOW'));
  // …and LOG them. This is the observable-progress half of the bound: a step
  // that outran its expected duration but has NOT hit the ceiling is not lost
  // and is not disposed — it is simply made visible, which is the one thing the
  // 9h49m stall never was.
  for (const n of notices) {
    log(
      `[${slug ?? label ?? 'level'}] machinery step '${n.step ?? '?'}' took ${n.elapsed_secs ?? '?'}s ` +
      `— over the ${n.slow_secs ?? STEP_SLOW_SECS}s expected-duration mark, still under the ` +
      `${n.ceiling_secs ?? STEP_CEILING_SECS}s liveness ceiling (temperloop#1071). Not lost, not retried — ` +
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
    '',
    '## Acceptance (self-verify each before returning done)',
    accBullets || '  - (none specified)',
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
    // re-READ (0.1) on the next call. The bare repo-wide run stays parent-side at
    // 3e.5 (unchanged, still the authority — the PR #309 silent-red lesson). The two
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
    '  The orchestrator runs the bare, repo-wide suite parent-side (build.md §3e.5) and',
    '  THAT run is the authority; a red there comes back to you as a re-spawn. So when',
    '  an acceptance criterion names the bare repo-wide suite, do NOT run it: report it',
    '  `passed: true` only if your targeted subset is green, and state plainly in its',
    '  `evidence` that the bare repo-wide run was DEFERRED to the parent-side 3e.5 gate.',
    '  Never report `passed: false` for a merely DEFERRED criterion — that reads as',
    '  blocked and stalls the whole level on a check you were never meant to run.',
    '- If a single command would exceed the ~10-min Bash foreground cap — or the tighter',
    '  ~5-min cache-TTL budget above — NARROW or split it, or return `blocked` / `failed`',
    '  and let the orchestrator run it parent-side — never background-and-wait.',
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
  'that run is the orchestrator\'s, parent-side at build.md 3e.5, and it is the',
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

// Compose the retry `extraSection` = the original section (if any) + the cure,
// plus the dirty-resume note when the probe saw uncommitted work (#993).
function withCure(section, dirtyFiles) {
  const dirty = Number(dirtyFiles) > 0 ? dirtyResumeCure(Number(dirtyFiles)) : null;
  return [section, FOREGROUND_CURE, dirty].filter(Boolean).join('\n\n');
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

// callWorker — spawn the implementation worker so a lost return channel can
// never escape as a throw. agent({schema}) THROWS on a StructuredOutput-absent
// / retry-cap-exceeded subagent and returns null on a skip / terminal API error;
// both are the same thing to the caller ("no verdict"), and neither is evidence
// about the work. Normalize both into { verdict, error } so driveItem decides
// what they MEAN only after the side-effect probe has run.
async function callWorker(item, wt, extraSection, label) {
  try {
    const v = await agent(workerPrompt(item, wt, extraSection), {
      label,
      phase: 'worker',
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
    return { verdict: v ?? null, error: v == null ? 'agent returned null' : null };
  } catch (err) {
    return { verdict: null, error: String((err && err.message) || err) };
  }
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
    { label: `recover-probe:${item.slug}`, slug: item.slug },
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
    `[${item.slug}] ${where} step '${to.step ?? '?'}' exceeded the ${to.ceiling_secs ?? STEP_CEILING_SECS}s ` +
    `liveness ceiling after ${to.elapsed_secs ?? '?'}s and was killed (temperloop#1071). Treating it as LOST — ` +
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
        `the '${to.step ?? '?'}' machinery step outlived the ${to.ceiling_secs ?? STEP_CEILING_SECS}s workflow ` +
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
      resumeSteps.push({ kind: 'push', cmd: `${prBin} push ${sq(wt)} ${sq(item.branch)}`, continueOutcomes: ['PUSHED'] });
    }
    resumeSteps.push({ kind: 'pr-open', cmd: openCmd });
    const resumeAt = {};
    resumeSteps.forEach((s, i) => { resumeAt[s.kind] = i; });
    const rb = await runMachineryBatch(resumeSteps, {
      label: `pr-batch-resume:${item.slug}`,
      slug: item.slug,
      bashTimeoutMs: BATCH_BASH_TIMEOUT_MS,
    });
    if (rb.denied) {
      return {
        kind: 'escalate',
        escKind: 'machinery-denied',
        payload: { step: batchDeniedStep(rb, 'pr-batch-resume'), steps: rb.steps, out: rb.out },
      };
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
function park(slug, pr, pushedSha, acceptanceResults, noCi, recovery) {
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

async function driveItem(item) {
  const { repoRoot, board, planLink } = input;
  const ownerRepo = input.ownerRepo; // "owner/repo" — passed by the orchestrator
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
  if (board && item.ghIssue && !isContinuation) {
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
  if (item.kind !== 'spike' && !isContinuation) {
    const wtBin = machineryBin(repoRoot, 'worktree.sh');
    addPrelude('worktree', `${wtBin} create ${sq(repoRoot)} ${sq(item.slug)}`, ['CREATED']);
  }

  const prelude = await runMachineryBatch(preludeSteps, {
    label: `prelude:${item.slug}`,
    slug: item.slug,
    bashTimeoutMs: BATCH_BASH_TIMEOUT_MS,
  });
  if (prelude.denied) {
    return escalate(item.slug, 'machinery-denied', {
      step: batchDeniedStep(prelude, 'prelude'),
      steps: prelude.steps,
      out: prelude.out,
    });
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
    const verdict = await agent(
      workerPrompt(
        item,
        worktreePath,
        '## Spike (read-only)\nProduce a verdict note + routed follow-up issue. ' +
          'No commits, no push, no PR. Return status=done with the note path/issue ' +
          'in `summary` and `verification_surface_path` pointing at your verdict note.',
      ),
      {
        label: `worker:${item.slug}`,
        phase: 'worker',
        // temperloop#982: item.model || undefined — see callWorker()'s
        // identical comment above; an empty-string item.model must collapse
        // to the inherit-session sentinel, not ride through as a literal "".
        model: item.model || undefined, // "" or undefined → inherit session model
        schema: WORKER_VERDICT_SCHEMA,
      },
    );
    if (verdict == null) {
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
  if (preludeAt.worktree !== undefined) {
    const wtOut = batchStep(prelude, preludeAt.worktree);
    if (wtOut.outcome !== 'CREATED') {
      return escalate(item.slug, 'worktree-failed', { wtOut });
    }
    // worktree.sh's CREATED.path is the authoritative deterministic path; it
    // equals worktreePath by construction, but trust the script's value.
    wt = wtOut.path ?? worktreePath;
  }

  // --- 3c. Spawn the worker (NO isolation:'worktree' — DESIGN NOTE 3) ------
  // On a continuation, inject the captured human verdict (## Design verdict /
  // ## User answers) as the worker's extra section so it sees the decision
  // instead of re-forking forever (MAJOR fix). On a fresh drive verdictSection
  // is undefined → workerPrompt emits no extra section, unchanged behavior.
  let recovery = null; // temperloop#939 — set only on a lost-return recovery
  let w = await callWorker(item, wt, verdictSection, `worker:${item.slug}`);
  let verdict = w.verdict;
  if (verdict == null) {
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
      w = await callWorker(item, wt, withCure(verdictSection, probe.dirtyFiles), `worker:${item.slug}#retry`);
      verdict = w.verdict;
      if (verdict == null) {
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
  const anyFailed = (verdict.acceptance_results ?? []).some((r) => r.passed === false);
  if (anyFailed) {
    return escalate(item.slug, 'acceptance-incomplete', { verdict });
  }

  // --- 3e.5. Parent-side acceptance gate (quality-gates.sh) ----------------
  // Run the project's static gate SSOT against the worker's work. ABSENT (the
  // script doesn't exist, e.g. foundation itself) → skip. FAIL → escalate
  // (do NOT push a known-red branch). The executor synthesizes GATE_PASS /
  // GATE_FAIL / GATE_ABSENT so the .mjs branches on a closed outcome.
  //
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
  const qgBin = `${wt}/scripts/quality-gates.sh`;
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
  // The gate verdict is derived from the subshell's own exit status; the
  // subshell here is redirected (`>log 2>&1`), not piped, so today the exit
  // reaches `$?` cleanly. pipefail is the durable guard: should a future
  // edit ever route the gate through a downstream filter/`tee` to capture its
  // output (e.g. `qgBin | tee log`), a bare pipe's status reflects the LAST
  // stage (tee's 0), swallowing a RED gate and degrading 3e.5 to a silent
  // no-op. With pipefail set, the gate's own non-zero exit propagates and
  // GATE_FAIL is still emitted — the runtime match for the documented rule.
  //
  // The log is truncated on the first slice and APPENDED to thereafter, so
  // /tmp/qg-<slug>.log stays the single artifact an operator reads, carrying the
  // union of every slice exactly as an unsliced run's log did.
  const gateLog = `/tmp/qg-${item.slug}.log`;
  const gateCmd = (startAt) =>
    `set -o pipefail; if [ ! -x ${sq(qgBin)} ]; then echo '{"outcome":"GATE_ABSENT"}'; ` +
    `else ( cd ${sq(wt)} && unset $(bash ${sq(settingsBin)} 2>/dev/null) && ` +
    `QUALITY_GATES_START_AT=${startAt} QUALITY_GATES_BUDGET_SECS=${GATE_SLICE_SECS} ${sq(qgBin)} ) ` +
    `${startAt === 0 ? '>' : '>>'}${gateLog} 2>&1; __rc=$?; ` +
    `__el=$(sed -n 's/.*passed in \\([0-9]*\\)s.*/\\1/p;s/.*of [0-9]* in \\([0-9]*\\)s.*/\\1/p' ${gateLog} | tail -1); ` +
    `__f=$(sed -n 's/^QUALITY_GATES_FAILED=//p' ${gateLog} | tail -1); ` +
    `__r=$(sed -n 's/^QUALITY_GATES_RESUME_AT=//p' ${gateLog} | tail -1); ` +
    `if [ "$__rc" = 75 ] && [ -n "$__r" ]; then ` +
    `printf '{"outcome":"GATE_SLICE","resumeAt":%s,"failed":%s,"elapsedSecs":%s,"budgetSecs":${GATE_SLICE_SECS}}\\n' "$__r" "\${__f:-0}" "\${__el:-0}"; ` +
    `elif [ "$__rc" = 0 ]; then ` +
    `printf '{"outcome":"GATE_PASS","failed":0,"elapsedSecs":%s,"budgetSecs":${GATE_SLICE_SECS}}\\n' "\${__el:-0}"; ` +
    `else printf '{"outcome":"GATE_FAIL","failed":%s,"elapsedSecs":%s,"budgetSecs":${GATE_SLICE_SECS}}\\n' "\${__f:-1}" "\${__el:-0}"; fi; fi`;

  // Drive slices until the suite finishes. GATE_SLICE is the ONLY outcome that
  // continues the loop; everything else is terminal on the first pass, so a
  // repo whose suite fits in one slice (or whose vendored gate predates the
  // seam) behaves exactly as it did before — one call, one outcome.
  let gateOut = null;
  let gateStartAt = 0;
  let gateElapsed = 0;
  let gateFailed = 0;
  let gateSlices = 0;
  for (; gateSlices < GATE_MAX_SLICES; gateSlices++) {
    gateOut = await runMachinery(gateCmd(gateStartAt), {
      label: `gate:${item.slug}`,
      slug: item.slug,
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
      return escalate(item.slug, 'machinery-denied', { step: 'gate', out: gateOut });
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
    gateElapsed += Number(gateOut.elapsedSecs) || 0;
    gateFailed += Number(gateOut.failed) || 0;
    if (gateOut.outcome !== 'GATE_SLICE') break;
    gateStartAt = Number(gateOut.resumeAt) || 0;
    log(`[${item.slug}] 3e.5 gate slice ${gateSlices + 1}/${GATE_MAX_SLICES} spent its ${GATE_SLICE_SECS}s budget — resuming at gate ${gateStartAt}`);
  }

  // A TIMEOUT is NOT a gate failure — its own escalation kind, so an operator
  // (or the pipeline's escalation router) can tell "the budget ran out" from
  // "this branch is broken" without reading a log. Same for exhausting the
  // slice cap: the suite did not finish, which says nothing about the tree.
  if (gateOut.outcome === 'GATE_TIMEOUT' || gateOut.outcome === 'GATE_SLICE') {
    return escalate(item.slug, 'acceptance-gate-timeout', {
      gateOut,
      reason: gateOut.outcome === 'GATE_TIMEOUT'
        ? `the quality-gates slice was killed by the executor's ${GATE_BASH_TIMEOUT_MS}ms Bash-tool timeout before it could report — a BUDGET exhaustion, NOT a gate failure; the suite's verdict is unknown`
        : `the suite did not finish within ${GATE_MAX_SLICES} slices of ${GATE_SLICE_SECS}s (~${Math.round(GATE_MAX_SLICES * GATE_SLICE_SECS / 60)} min of gate wall time) — a BUDGET exhaustion, NOT a gate failure`,
      slices: gateSlices + 1,
      elapsedSecs: gateElapsed,
      sliceBudgetSecs: GATE_SLICE_SECS,
      remedy: 'raise BUILD_GATE_SLICE_SECS (bounded by the agent Bash cap) or split the gate list; re-run the gate to get a real verdict',
      log: gateLog,
    });
  }
  // A genuinely RED suite still escalates exactly as before — unchanged. Note
  // gateFailed is accumulated ACROSS slices, so a failure found in slice 1 is
  // not lost when slice 2 finishes green.
  if (gateOut.outcome === 'GATE_FAIL' || gateFailed > 0) {
    return escalate(item.slug, 'acceptance-gate-failed', { gateOut, failedGates: gateFailed, log: gateLog });
  }
  // GATE_PASS or GATE_ABSENT → proceed. Report the MARGIN, not just the verdict:
  // this is the decay signal that #115's bare number never had. A run that ate
  // most of its slice budget, or needed several slices, says so on a GREEN run —
  // before it becomes the next false failure.
  if (gateOut.outcome === 'GATE_PASS') {
    const marginNote = gateSlices > 0 || gateElapsed >= GATE_SLICE_SECS * GATE_MARGIN_WARN_RATIO
      ? ` — NOTE: approaching the per-slice budget; raise BUILD_GATE_SLICE_SECS or split the gate list before it costs a re-slice`
      : '';
    log(`[${item.slug}] 3e.5 gate PASS — ${gateSlices + 1} slice(s), ${gateElapsed}s of gate wall time (slice budget ${GATE_SLICE_SECS}s, cap ${GATE_MAX_SLICES} slices)${marginNote}`);
  }

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
  addPrStep('push', `${prBin} push ${sq(wt)} ${sq(item.branch)}`, ['PUSHED']);

  // 3f-2. Open the PR. The verification surface is read from the deterministic
  // file path (--verification-surface-file) so its body never enters context.
  // The worker's verdict JSON is needed by pr.sh open (--verdict); we hand the
  // executor a heredoc-built temp file so the (possibly large) verdict stays in
  // the executor's process, not this workflow's. We pass only the fields pr.sh
  // reads from the verdict — summary + acceptance_results — assembled compactly.
  const verdictJson = JSON.stringify({
    status: 'done',
    summary: verdict.summary ?? '',
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

  const prb = await runMachineryBatch(prSteps, {
    label: `pr-batch:${item.slug}`,
    slug: item.slug,
    bashTimeoutMs: BATCH_BASH_TIMEOUT_MS,
  });
  if (prb.denied) {
    return escalate(item.slug, 'machinery-denied', {
      step: batchDeniedStep(prb, 'pr-batch'),
      steps: prb.steps,
      out: prb.out,
    });
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
      const openOut = batchStep(prb, prAt['pr-open']);
      if (openOut.outcome !== 'PR_OPENED' && openOut.outcome !== 'EXISTS') {
        const rec = isLostReturn(openOut) ? await recoverLostReturn(item, wt, openCmd) : { kind: 'none' };
        if (rec.kind === 'adopted') {
          pr = rec.pr;
          pushedSha = rec.pushedSha ?? pushedSha;
        } else if (rec.kind === 'escalate') {
          return escalate(item.slug, rec.escKind, rec.payload);
        } else {
          return escalate(item.slug, 'pr-open-failed', { openOut });
        }
      } else {
        pr = openOut.pr_number;
      }
    }
  }

  // --- 3g. CI poll (the bounded short-slice loop — DESIGN NOTE 2) ----------
  const ciResult = await ciPollLoop(item, ownerRepo, pr, pushedSha, wt);
  if (ciResult.escalation) {
    return escalate(item.slug, ciResult.escalation, { ...ciResult.payload, pr });
  }

  // --- 3h. Park as [m] (the workflow returns the record; orchestrator writes)
  // A NO_CI resolution (temperloop#605/#618) parks the same, but the returned
  // record carries `no_ci: true` so the orchestrator stamps the sentinel.
  log(`[${item.slug}] parked — PR #${pr} ${ciResult.noCi ? 'no CI configured (skipped)' : 'CI green'}${recovery ? ' (RECOVERED — acceptance unverified)' : ''}`);
  return park(item.slug, pr, ciResult.finalSha ?? pushedSha, verdict.acceptance_results, ciResult.noCi === true, recovery);
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
      });
      if (batch.denied) {
        return {
          escalation: 'machinery-denied',
          payload: { step: 'ci-batch', steps: batch.steps, out: batch.out, sha },
        };
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
      return { ok: true, finalSha: sha };
    }

    if (out.outcome === 'NO_CI') {
      // temperloop#605/#618: ci-poll.sh's bounded grace window elapsed with
      // ZERO check-runs ever configured on the head SHA — a repo with no CI,
      // NOT a hang and NOT a failure. Mirror build.md 3g's legible skip: resolve
      // as success carrying a `noCi` marker so 3h parks `[m]` with the
      // `no_ci: true` sentinel, instead of falling through to the catch-all
      // below and escalating `ci-failed` (the exact mis-escalation this fixes).
      log(`[${item.slug}] PR #${pr}: no CI configured on this SHA — skipping the CI gate (slice ${slice + 1})`);
      return { ok: true, finalSha: sha, noCi: true };
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
      // Re-spawn the worker against the SAME worktree to fix CI, then
      // force-push and re-poll PINNED to the new SHA (#254 guard).
      log(`[${item.slug}] CI failed — re-spawning worker (retries left ${retriesLeft})`);
      const fixVerdict = await agent(
        workerPrompt(
          item,
          wt,
          '## CI failed\nThe pushed branch failed CI. First run ' +
            '`git fetch origin ' + item.branch + ' && git reset --hard FETCH_HEAD`, ' +
            'then fix the failure and commit (do NOT push). ' +
            'Failed run ids: ' + JSON.stringify(out.failed_run_ids ?? []) + '.',
        ),
        {
          label: `worker-cifix:${item.slug}`,
          phase: 'worker',
          // Escalate-on-retry: a CI-failure re-spawn runs top tier (omit model).
          schema: WORKER_VERDICT_SCHEMA,
        },
      );
      if (fixVerdict == null) {
        // agent() returned null — user skip or terminal API error in the CI-fix
        // worker. Already inside a CI-failure retry context; escalate cleanly.
        return { escalation: 'ci-failed', payload: { reason: 'ci-fix agent returned null', retryable: true, sha } };
      }
      if (fixVerdict.status !== 'done') {
        return { escalation: 'ci-failed', payload: { fixVerdict, sha } };
      }
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
        { label: `push-retry:${item.slug}`, slug: item.slug },
      );
      if (machineryDenied(fpush)) {
        return { escalation: 'machinery-denied', payload: { step: 'push-retry', out: fpush, sha } };
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
    return { escalation: 'ci-failed', payload: { ciOut: out, sha } };
  }

  // Total budget exhausted without CI_GREEN/CI_FAILED resolution.
  return { escalation: 'ci-failed', payload: { reason: 'ci-poll budget exhausted', sha } };
}

// =============================================================================
// levelPhaseTitle — the run-identifying progress-row heading (temperloop#903).
// =============================================================================
// The Workflow progress UI renders one row per workflow (labelled from the PURE
// LITERAL `meta.description`, which by runtime constraint is byte-identical on
// every run) plus a group heading per phase(). phase() is therefore the ONLY
// surface that can carry run context — and it used to read `build level — N
// item(s)`, which identifies nothing: not the repo, not the items, not the
// issues. Two concurrent spine runs (routine: one /fix session drives several
// back to back) rendered indistinguishable rows.
//
// The heading now names, from context already in scope at the call site:
//   <ownerRepo> · <N> item(s) · <slug> (#<ghIssue>), …
// e.g.  build level — Towheads/foundation · 1 item · spine-progress-row-903 (#903)
//
// BOUNDED BY CONSTRUCTION: a level can hold many items, so at most
// PHASE_TITLE_MAX_ITEMS slugs are named and the rest collapse to `+K more` — a
// 20-item level can never emit a 20-slug heading that swamps the progress row.
// Every field is optional-safe (a missing ownerRepo / ghIssue simply drops its
// segment) because this is a cosmetic display string: it must never be the thing
// that throws and takes a level down.
const PHASE_TITLE_MAX_ITEMS = 3;

// itemTag — `<slug> (#<issue>)`, or the bare slug when the item has no issue
// (kind:spike items and board-OFF runs legitimately carry no ghIssue).
function itemTag(item) {
  const slug = (item && item.slug) || '(unnamed)';
  const issue = item && item.ghIssue;
  return issue ? `${slug} (#${issue})` : slug;
}

function levelPhaseTitle(list) {
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
  return `build level — ${parts.join(' · ')}`;
}

// =============================================================================
// Entry point — drive the level, return {parked, escalations}.
// =============================================================================
async function buildLevel() {
  const items = input.items ?? [];
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
  phase(levelPhaseTitle(activeItems));

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
  const results = await parallel(
    activeItems.map((item) => () =>
      driveItem(item).catch((err) =>
        escalate(item.slug, 'worker-error', { error: String((err && err.stack) || err) }),
      ),
    ),
  );

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

  log(`level done — parked=${parked.length} escalations=${escalations.length}`);
  return { parked, escalations };
}

// Top-level entry (#437): the Workflow runtime wraps this script body in an async
// context and does NOT call a default export — it runs the top-level body. So we
// invoke the driver and return its value here, at top level. (This file is
// therefore a Workflow-runtime script, NOT a standalone ESM — top-level `return`
// means it cannot be `node --check`'d or `import()`'d; the test harness simulates
// the runtime wrap instead.)
return await buildLevel();
