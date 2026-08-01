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
//        ghIssue, alsoCloses, model, acceptance, source, scope, notes,
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
//     ownerRepo  — "owner/repo" for ci-poll.sh / gh ops. The workflow has no
//                  shell to derive it, so the orchestrator passes it in (Step 0
//                  probe: `gh repo view --json nameWithOwner -q .nameWithOwner`).
//                  WITHOUT it every CI poll gets '' → ERROR.
//     claimCmd   — absolute path to the board claim.sh entrypoint (Step 0 CLAIM
//                  probe). Used by 3a; defaults to bare 'claim.sh' if absent.
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
export const meta = {
  name: 'build-level',
  description:
    "Drive ONE build dependency level's items (3a-3h) through the bash machinery + worker, returning {parked, escalations}. Never merges, never writes the plan note.",
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
        'GATE_PASS', 'GATE_FAIL', 'GATE_ABSENT',
        'CLAIMED', 'CLAIM_CONFLICT',
        // worktree.sh deps-merged (3b-0) — its outcomes were consumed at the
        // call site (~line 595) but never listed here; an omitted outcome is
        // schema-invalid, so name them alongside the rest of the closed set.
        'DEPS_MERGED', 'DEPS_UNMERGED',
        // pr.sh recover-probe (3c lost-return recovery, temperloop#939) — the
        // staged observable-side-effect ladder: nothing / committed / pushed /
        // PR already open.
        'RECOVER_NONE', 'RECOVER_COMMITTED', 'RECOVER_PUSHED', 'RECOVER_PR_OPEN',
        'ERROR',
      ],
    },
    // Common passthrough fields the machinery emits (any subset, depending on cmd).
    // (recover-probe adds commits_ahead / pushed / remote_sha /
    // verification_surface_present; `additionalProperties: true` already admits
    // them, and the ones the .mjs branches on are declared below.)
    path: { type: 'string' },
    commits_ahead: { type: ['number', 'string'] },
    pushed: { type: 'boolean' },
    remote_sha: { type: 'string' },
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
const WORKER_VERDICT_SCHEMA = {
  type: 'object',
  required: ['status'],
  additionalProperties: true,
  properties: {
    status: { type: 'string', enum: ['done', 'blocked', 'design-fork', 'failed'] },
    summary: { type: 'string' },
    acceptance_results: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: true,
        properties: {
          criterion: { type: 'string' },
          passed: { type: 'boolean' },
          evidence: { type: 'string' },
        },
      },
    },
    commits: { type: 'array', items: { type: 'string' } },
    verification_surface_path: { type: 'string' },
    questions: { type: 'array', items: { type: 'string' } },
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
    failure_reason: { type: 'string' },
  },
};

// -----------------------------------------------------------------------------
// Tunables (no Date.now()/Math.random() — those THROW in the runtime; all
// budgets are expressed as counts/seconds the executor agent enforces itself).
// -----------------------------------------------------------------------------
const CI_POLL_SLICE_SECS = 240;   // one ci-poll.sh slice; < the ~10-min agent Bash cap
const CI_POLL_TOTAL_SECS = 3600;  // total wall budget across slices before escalating
const CI_FAIL_RETRY_BUDGET = 1;   // re-spawn+force-push+re-poll attempts on CI_FAILED
// 3e.5 gate Bash-tool timeout (temperloop#115). The full quality-gates.sh suite
// runs >2min; the executor's Bash tool defaults to 120_000ms, so the suite was
// SIGTERM'd at 2:00 → a false GATE_FAIL on every drive. 480_000ms (8min) clears
// the suite with margin and stays under the executor agent's ~10-min Bash cap
// (== the Bash tool's 600_000ms max). Threaded to the gate runMachinery call only.
const GATE_BASH_TIMEOUT_MS = 480_000;

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
// runMachinery — the sh() replacement (spike §1).
// -----------------------------------------------------------------------------
// Spawns a one-shot executor agent that runs EXACTLY one machinery command via Bash
// and returns its single closed-outcome JSON line, schema-validated. No model
// override beyond haiku (cheapest tier — the executor does no reasoning); NO
// isolation:'worktree' (the machinery scripts manage their own worktrees, §5).
async function runMachinery(cmd, { label, slug, bashTimeoutMs } = {}) {
  // Wording (temperloop#72): describe the command as a KNOWN build-machinery helper
  // script that self-reports its result, rather than telling the sub-agent to
  // "run exactly / do NOT interpret" an opaque line. The old phrasing, paired
  // with the nested-readlink path resolution, read to the auto-mode safety
  // classifier as an instruction to blindly execute an obfuscated command.
  const out = await agent(
    [
      'Run this single build-machinery helper command with the Bash tool, exactly as written.',
      'It is a known project script (worktree.sh / pr.sh / ci-poll.sh / claim.sh); do not add flags, chain extra commands, or rewrite it.',
      // temperloop#115: for a legitimately long-running command (the 3e.5 gate),
      // raise the Bash TOOL's timeout parameter — NOT the command text — so the
      // executor does not kill it at the default 2 minutes.
      bashTimeoutMs
        ? `This command runs longer than usual. When you invoke the Bash tool, set its \`timeout\` parameter to ${bashTimeoutMs} (milliseconds). That is a Bash tool parameter only — do NOT alter the command text — and it prevents the default 2-minute timeout from killing the run.`
        : null,
      'It prints a SINGLE JSON line on stdout describing its own result (a closed `outcome` set).',
      'Return that JSON object verbatim as your result — the schema captures it.',
      'If the command exits non-zero it STILL prints its JSON line; return that line.',
      '',
      'Command:',
      cmd,
    ].filter(Boolean).join('\n'),
    {
      label: label ?? `machinery:${cmd.split(' ').slice(0, 2).join(' ')}`,
      phase: 'machinery',
      agentType: 'general-purpose',
      model: 'haiku',
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
  const lines = [];
  steps.forEach((s, i) => {
    const v = `__o${i}`;
    lines.push(`${v}=$( ${s.cmd} )`);
    lines.push(`printf '%s\\n' "$${v}"`);
    if (i === steps.length - 1) return; // nothing follows — no gate needed
    if (s.stopGlobs && s.stopGlobs.length > 0) {
      lines.push(`case "$${v}" in ${s.stopGlobs.map(globPat).join('|')}) exit 0 ;; esac`);
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
  const out = await agent(
    [
      'Run this build-machinery command sequence with the Bash tool, exactly as written, in ONE Bash invocation.',
      'It is a short shell script that calls known project helper scripts (worktree.sh / pr.sh / ci-poll.sh / claim.sh / gh) one after another; do not add flags, reorder or split the steps, or rewrite it.',
      `Steps: ${kinds.join(', ')}`,
      // temperloop#115 rationale, applied per batch: for a legitimately
      // long-running sequence raise the Bash TOOL's timeout parameter — NOT the
      // command text — so the executor does not kill it at the default 2 minutes.
      bashTimeoutMs
        ? `This sequence runs longer than usual. When you invoke the Bash tool, set its \`timeout\` parameter to ${bashTimeoutMs} (milliseconds). That is a Bash tool parameter only — do NOT alter the command text — and it prevents the default 2-minute timeout from killing the run.`
        : null,
      'Each helper prints a SINGLE JSON line on stdout describing its own result (a closed `outcome` set).',
      "The script deliberately STOPS EARLY when a step's result means the remaining steps must not run. FEWER JSON lines than steps is expected and correct — never an error, never something to re-run, retry, or work around.",
      'Return every JSON object it printed on stdout, in stdout order, as {"results": [ ... ]}. Copy each object VERBATIM — do not merge, summarise, reorder, add, drop, or invent entries — and ignore any non-JSON output.',
      'If a step exits non-zero it STILL prints its JSON line; include it.',
      '',
      'Command:',
      batchCommand(steps),
    ]
      .filter(Boolean)
      .join('\n'),
    {
      label: label ?? `machinery-batch:${kinds.join('+')}`,
      phase: 'machinery',
      agentType: 'general-purpose',
      model: 'haiku',
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
  return { denied: false, results: out.results, steps: kinds, out };
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
    '## Quality gate & long-running work — FOREGROUND ONLY (#1219)',
    '- Run EVERY verification command in the FOREGROUND (a blocking Bash call): the',
    '  `quality-gates.sh` acceptance gate above all, plus any eval / build / sweep.',
    '- NEVER launch one with `run_in_background: true`, and never end your turn awaiting',
    '  a Monitor / background-task notification. A subagent has NO re-invoke-on-completion',
    '  loop: a backgrounded process is reaped when you yield and the notification never',
    '  reaches you — you hang and return NO verdict. A turn that ends while awaiting a',
    '  background task is the #1219 bug, not a valid return.',
    '- If a single command would exceed the ~10-min Bash foreground cap, NARROW or split',
    '  it, or return `blocked` / `failed` and let the orchestrator run it parent-side —',
    '  never background-and-wait.',
    '',
    extraSection ?? '',
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
const FOREGROUND_CURE = [
  '## Re-spawn cure (#1219) — your previous turn returned NO verdict',
  'Your previous attempt ended without a parseable verdict. The usual cause is',
  'backgrounding the quality gate (`run_in_background: true`) or awaiting a Monitor',
  'notification a subagent never receives. Run EVERY command — the `quality-gates.sh`',
  'gate above all — in the FOREGROUND, never `run_in_background` / Monitor, and END',
  'this turn with exactly the fenced verdict JSON and nothing after it.',
].join('\n');

// Compose the retry `extraSection` = the original section (if any) + the cure.
function withCure(section) {
  return [section, FOREGROUND_CURE].filter(Boolean).join('\n\n');
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
      model: item.model, // undefined → inherit session model
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
    return { landed: false, probeOut: out };
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
        model: item.model, // undefined → inherit session model
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
      // Nothing landed → this is the ordinary stall. Retry exactly once,
      // appending FOREGROUND_CURE so the retry prompt DIFFERS from the first — a
      // byte-identical retry re-stalls identically. A 5xx is transient (the extra
      // section is harmless); a stall is cured by it.
      log(`[${item.slug}] worker returned no verdict, no side-effects — retrying once (foreground cure #1219)`);
      w = await callWorker(item, wt, withCure(verdictSection), `worker:${item.slug}#retry`);
      verdict = w.verdict;
      if (verdict == null) {
        // The retry may itself have built and lost its return — probe again.
        probe = await probeSideEffects(item, wt);
        if (probe.landed) recovery = probe;
      }
    }
    if (verdict == null) {
      if (!recovery) {
        // GENUINELY nothing observable — the unchanged escalation path.
        return escalate(item.slug, 'worker-error', {
          retryable: true,
          reason: w.error ?? 'agent returned no verdict after one retry (main worker)',
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
  const gateOut = await runMachinery(
    // If the script is missing → GATE_ABSENT (no-op). Else run it in the
    // worktree; exit 0 → GATE_PASS, non-zero → GATE_FAIL.
    //
    // `set -o pipefail` is LOAD-BEARING (temperloop#68 — see build.md §3e.5).
    // The gate verdict is derived from the subshell's exit via `&& … || …`; the
    // subshell here is redirected (`>log 2>&1`), not piped, so today the exit
    // reaches the `||` cleanly. pipefail is the durable guard: should a future
    // edit ever route the gate through a downstream filter/`tee` to capture its
    // output (e.g. `qgBin | tee log`), a bare pipe's status reflects the LAST
    // stage (tee's 0), swallowing a RED gate and degrading 3e.5 to a silent
    // no-op. With pipefail set, the gate's own non-zero exit propagates and
    // GATE_FAIL is still emitted — the runtime match for the documented rule.
    `set -o pipefail; if [ ! -x ${sq(qgBin)} ]; then echo '{"outcome":"GATE_ABSENT"}'; ` +
      `else ( cd ${sq(wt)} && unset $(bash ${sq(settingsBin)} 2>/dev/null) && ${sq(qgBin)} ) >/tmp/qg-${item.slug}.log 2>&1 ` +
      `&& echo '{"outcome":"GATE_PASS"}' || echo '{"outcome":"GATE_FAIL"}'; fi`,
    // temperloop#115: the full quality-gates.sh suite runs >2min; without an
    // explicit timeout the executor's Bash tool kills it at 120s → false
    // GATE_FAIL. GATE_BASH_TIMEOUT_MS gives the suite room to finish.
    { label: `gate:${item.slug}`, slug: item.slug, bashTimeoutMs: GATE_BASH_TIMEOUT_MS },
  );
  if (machineryDenied(gateOut)) {
    return escalate(item.slug, 'machinery-denied', { step: 'gate', out: gateOut });
  }
  if (gateOut.outcome === 'GATE_FAIL') {
    return escalate(item.slug, 'acceptance-gate-failed', { gateOut });
  }
  // GATE_PASS or GATE_ABSENT → proceed.

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
  const ghIssueFlag = item.ghIssue ? ` --gh-issue ${sq(item.ghIssue)}` : '';
  const alsoClosesFlag = item.alsoCloses?.length
    ? ` --also-closes ${sq(item.alsoCloses.join(','))}`
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

  // 3f-1 branch — the push decision, unchanged.
  const pushOut = batchStep(prb, prAt.push);
  if (pushOut.outcome === 'PUSH_REJECTED') {
    // Remote-branch collision / non-ff — orchestrator triages (force vs rename).
    return escalate(item.slug, 'push-rejected', { pushOut });
  }
  if (pushOut.outcome !== 'PUSHED') {
    return escalate(item.slug, 'push-error', { pushOut });
  }
  const pushedSha = pushOut.sha;

  // 3f-2 branch — the PR-open decision, unchanged.
  // EXISTS means the branch already had an open PR (a create-retry after a
  // succeeded first attempt). Treat it as PR_OPENED — adopt the existing PR and
  // continue to CI-poll/park-with-pr. Any other non-PR_OPENED outcome is a
  // genuine failure and escalates as pr-open-failed.
  const openOut = batchStep(prb, prAt['pr-open']);
  if (openOut.outcome !== 'PR_OPENED' && openOut.outcome !== 'EXISTS') {
    return escalate(item.slug, 'pr-open-failed', { openOut });
  }
  const pr = openOut.pr_number;

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
// Entry point — drive the level, return {parked, escalations}.
// =============================================================================
async function buildLevel() {
  const items = input.items ?? [];
  phase(`build level — ${items.length} item(s)`);
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
