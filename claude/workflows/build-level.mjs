// build-level.mjs — foundation's FIRST saved Workflow.
// =============================================================================
// The per-level driver for /build. It re-homes build.md's 3a–3h
// per-item loop out of the conversational orchestrator and into a bounded
// Workflow process, so the orchestrator's context stays pinned to ONE small
// {parked, escalations} object per dependency level — regardless of how many
// items or spine calls the level contains. The orchestrator invokes this once
// per level (via the Workflow tool), the workflow drives every item's spine +
// worker, and returns only what to write back. The orchestrator still owns the
// MERGE GATE (Step 4) — this workflow never merges and never writes the plan
// note.
//
// -----------------------------------------------------------------------------
// DESIGN NOTES (read before editing — these three decisions are load-bearing)
// -----------------------------------------------------------------------------
//
// 1. THE runSpine BRIDGE (spike #421 verdict §1).
//    The deterministic bash spine (worktree.sh / pr.sh / ci-poll.sh /
//    quality-gates.sh / board claim.sh) is the source of truth for every
//    mechanical step. But the Workflow runtime has NO filesystem, NO Node, NO
//    shell in the script body — so there is no `sh()` primitive. The bridge:
//    every spine call becomes ONE `agent({schema})` whose entire job is "run
//    exactly this one command, return its single closed-outcome JSON line as a
//    validated object." The runtime's agent() hook gives a subagent the normal
//    Bash tool and (with a schema) returns a validated object, not free text —
//    so an agent that runs one command IS the missing sh(). The branching logic
//    (if SCAN_BLOCKED → escalate, if PUSH_REJECTED → escalate) stays in legible
//    .mjs here, not buried in an opaque agent prompt. The cost — ~6 trivial
//    executor spawns + 1 worker per item — lands entirely in THIS discardable
//    workflow process, never the orchestrator's context. That is the whole
//    point: orchestrator growth is bounded to one summary object per level.
//
//    CRITICAL (from the live probe in the spike): shell-quote every argument.
//    A spaced path (e.g. a vault plan path "Plans/2026-06-13 foo - bar.md")
//    MUST be single-quoted in the command string or the one-shot executor runs
//    the wrong command. Every command this file builds goes through `sq()` for
//    each interpolated value.
//
// 2. THE CI-POLL LOOP (spike #421 verdict §1 "ci-poll caveat").
//    ci-poll.sh can poll up to 1h, but an agent()'s foreground Bash has a
//    ~10-min cap — so we must NOT runSpine a single long poll (it would die
//    mid-poll). Instead we loop runSpine over SHORT-timeout polls
//    (CI_POLL_SLICE_SECS, default 240s) until the outcome resolves to CI_GREEN
//    or CI_FAILED, bounded by a total wall budget (CI_POLL_TOTAL_SECS). The
//    short poll returns TIMEOUT when the slice elapses with checks still
//    pending — that is the signal to poll again, NOT a failure. On CI_FAILED
//    within a small retry budget we re-spawn the worker, force-push, and
//    re-poll PINNED to the new SHA (the #254 false-green guard — never let the
//    poll re-resolve the head from the PR API after a force-push). Past the
//    budget without resolution → escalate `ci-failed` so a human drives it.
//
// 3. DROP isolation:'worktree' (spike #421 verdict §5).
//    The worker agent() runs WITHOUT isolation:'worktree'. build has its
//    own worktree mechanism (worktree.sh create), and three contracts assume
//    IT, not the runtime's opaque isolation: (a) the deterministic path
//    <repoRoot>.wt/<slug> that pr.sh / quality-gates / the verification-surface
//    file all reference; (b) the .build-guard write-jail marker that arms
//    the PreToolUse guard per-worktree; (c) push-by-SHA on the plan's branch.
//    So we runSpine('worktree.sh create …') first, then tell the worker (in its
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
//                  `<repoRoot>.wt/<slug>` and spine scripts at
//                  `<repoRoot>/workflows/scripts/build/`.
//     planLink   — the plan note's vault link (passed to pr.sh --plan-link).
//     board      — logical board number (3/4) or null/false when board is OFF.
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
    "Drive ONE build dependency level's items (3a-3h) through the bash spine + worker, returning {parked, escalations}. Never merges, never writes the plan note.",
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
// every spine script's closed set) plus passthrough fields. The .mjs branches
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
      // The union of the spine's closed outcome sets (worktree / pr / ci-poll /
      // gate) plus the gate-pass/fail and claim markers we synthesize below.
      enum: [
        'CREATED', 'REMOVED', 'NOT_FOUND', 'PRUNED', 'SKIPPED_DIRTY', 'SKIPPED_UNMERGED',
        'SCAN_CLEAN', 'SCAN_BLOCKED',
        'BASE_CURRENT', 'BASE_STALE',
        'REBASED', 'REBASE_CONFLICT',
        'PUSHED', 'PUSH_REJECTED',
        'PR_OPENED', 'EXISTS',
        'CI_GREEN', 'CI_FAILED', 'TIMEOUT',
        'GATE_PASS', 'GATE_FAIL', 'GATE_ABSENT',
        'CLAIMED', 'CLAIM_CONFLICT',
        'ERROR',
      ],
    },
    // Common passthrough fields the spine emits (any subset, depending on cmd).
    path: { type: 'string' },
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
// (== the Bash tool's 600_000ms max). Threaded to the gate runSpine call only.
const GATE_BASH_TIMEOUT_MS = 480_000;

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

// spineBin — resolve a build-SPINE script (worktree.sh / pr.sh / ci-poll.sh),
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
// temperloop#406; the legacy FOUNDATION_HOME name is read as a fallback
// through the rename window, removed in v0.16.0). If none resolve, the
// emitted path points at the missing
// repo-local dir and the spine script's own "not found" (exit 127) surfaces
// loudly. NOTE:
// only spine scripts route through here; the project's OWN vendored gate
// (scripts/quality-gates.sh) stays repo-local and is resolved directly.
function spineBin(repoRoot, name) {
  // De-obfuscated fast path (temperloop#72). When the orchestrator has already
  // resolved the build-spine directory in its OWN shell (build.md Step 0) and
  // passed it as input.spineBinDir, emit a PLAIN quoted absolute path. The
  // executed spine command line then carries NO nested `$(readlink …)`
  // command-substitution — the very construct the auto-mode safety classifier
  // read (together with the runSpine "run exactly" instruction) as an
  // obfuscated-command bypass, denying every push/worktree spine step on
  // --unattended/funnel runs. A literal path reads as an ordinary script call.
  if (typeof input.spineBinDir === 'string' && input.spineBinDir.length > 0) {
    return sq(input.spineBinDir + '/' + name);
  }
  // Fallback (no pre-resolved dir — older invocations, or a consuming repo that
  // does not yet pass spineBinDir): resolve in BASH, exactly as before (#560).
  const local = sq(repoRoot + '/workflows/scripts/build');
  return '"$(d=' + local + '; ' +
    'if [ ! -d "$d" ]; then for c in ' +
    '"${FOUNDATION:-}/workflows/scripts/build" ' +
    '"$(dirname "$(readlink -f "$HOME/.claude/workflows/build-level.mjs" 2>/dev/null)" 2>/dev/null)/../../workflows/scripts/build" ' +
    '"${TEMPERLOOP_HOME:-${FOUNDATION_HOME:-$HOME/.local/share/temperloop}}/workflows/scripts/build"; ' +
    'do [ -d "$c" ] && { d="$c"; break; }; done; fi; ' +
    "printf '%s' \"$d/" + name + '")"';
}

// Repo "owner/repo" — the orchestrator passes it in input.ownerRepo (the
// workflow has no shell to derive it). ci-poll.sh / gate ops take owner/repo;
// push/scan take the worktree path. WITHOUT input.ownerRepo every ci-poll gets
// '' → ERROR, so the orchestrator MUST pass it (Step 0 probe). See the I/O note.

// -----------------------------------------------------------------------------
// runSpine — the sh() replacement (spike §1).
// -----------------------------------------------------------------------------
// Spawns a one-shot executor agent that runs EXACTLY one spine command via Bash
// and returns its single closed-outcome JSON line, schema-validated. No model
// override beyond haiku (cheapest tier — the executor does no reasoning); NO
// isolation:'worktree' (the spine scripts manage their own worktrees, §5).
async function runSpine(cmd, { label, slug, bashTimeoutMs } = {}) {
  // Wording (temperloop#72): describe the command as a KNOWN build-spine helper
  // script that self-reports its result, rather than telling the sub-agent to
  // "run exactly / do NOT interpret" an opaque line. The old phrasing, paired
  // with the nested-readlink path resolution, read to the auto-mode safety
  // classifier as an instruction to blindly execute an obfuscated command.
  const out = await agent(
    [
      'Run this single build-spine helper command with the Bash tool, exactly as written.',
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
      label: label ?? `spine:${cmd.split(' ').slice(0, 2).join(' ')}`,
      phase: 'spine',
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
  // detect (via spineDenied()) and turn into a parkable `spine-denied`
  // escalation instead of a TypeError.
  return out == null ? { outcome: 'SPINE_DENIED', denied: true } : out;
}

// -----------------------------------------------------------------------------
// Worker prompt assembly (3c).
// -----------------------------------------------------------------------------
function workerPrompt(item, worktreePath, extraSection) {
  // `acceptance` may be an array of bullets (the /build plan path) OR a single
  // string (/sweep passes one string) — normalize to an array (#437).
  const accList = Array.isArray(item.acceptance)
    ? item.acceptance
    : item.acceptance
      ? [item.acceptance]
      : [];
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

// -----------------------------------------------------------------------------
// Per-item driver (3a–3h for ONE item). Returns either a `parked` record or an
// `escalation` record — NEVER both. The pipeline collects these.
// -----------------------------------------------------------------------------

// A small helper to build an escalation result (worktree stays intact).
function escalate(slug, kind, payload) {
  return { _kind: 'escalation', slug, escalation: { slug, kind, payload } };
}
function park(slug, pr, pushedSha, acceptanceResults) {
  return {
    _kind: 'parked',
    slug,
    parked: { slug, pr, pushed_sha: pushedSha, acceptance_results: acceptanceResults ?? [] },
  };
}

// spineDenied — a spine step returned no usable outcome. runSpine already
// normalizes agent()'s null (auto-mode classifier DENIED the command / user
// skip / terminal API error) to a SPINE_DENIED sentinel; this recognizes both
// that sentinel and a bare null. Either means "the mechanical step did not run"
// — so the caller escalates `spine-denied` (a clean, parkable escalation the
// orchestrator can drive to a human) instead of dereferencing `.outcome` on a
// null/absent result and crashing the level (temperloop#72).
function spineDenied(out) {
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

  // --- kind: spike — read-only fork, NO push/PR (skip 3b–3h) ---------------
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

  // --- 3a. Claim (claim-first), board ON only ------------------------------
  // Skipped on a continuation: the issue is already claimed by this run (the
  // escalation never released it), and a re-claim is at best a self-owned
  // no-op (spec 3d-esc step 4: "does NOT re-run 3a").
  if (board && item.ghIssue && !isContinuation) {
    // The CLAIM entrypoint + --board are resolved by the orchestrator's Step 0
    // probe and passed in input.claimCmd (an absolute path to claim.sh).
    const claimBin = input.claimCmd ?? 'claim.sh';
    const claimOut = await runSpine(
      // claim.sh exits 0 on success; we wrap a contention/no-op check into the
      // executor by asking it to emit a CLAIMED/CLAIM_CONFLICT line. The
      // orchestrator's claim.sh itself sets In Progress + stamps Host/Session.
      `${sq(claimBin)} ${sq(item.ghIssue)} --board ${sq(board)} && ` +
        `echo '{"outcome":"CLAIMED"}' || echo '{"outcome":"CLAIM_CONFLICT"}'`,
      { label: `claim:${item.slug}`, slug: item.slug },
    );
    if (spineDenied(claimOut)) {
      return escalate(item.slug, 'spine-denied', { step: 'claim', out: claimOut });
    }
    if (claimOut.outcome === 'CLAIM_CONFLICT' || claimOut.outcome === 'ERROR') {
      return escalate(item.slug, 'claim-conflict', { claimOut });
    }
  }

  // --- 3b-0. Dep-merge precondition gate (#108) ----------------------------
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
  if (depShas.length > 0) {
    const wtGateBin = spineBin(repoRoot, 'worktree.sh');
    const depOut = await runSpine(
      `${wtGateBin} deps-merged ${sq(repoRoot)} ${sq(depShas.join(','))}`,
      { label: `depcheck:${item.slug}`, slug: item.slug },
    );
    if (spineDenied(depOut)) {
      return escalate(item.slug, 'spine-denied', { step: 'deps-merged', out: depOut });
    }
    if (depOut.outcome !== 'DEPS_MERGED') {
      // A depended-on PR has NOT merged to origin/<default>. Do NOT create the
      // worktree and do NOT spawn a worker — surface it so the orchestrator/human
      // resolves the ordering. Nothing is built against a stale base.
      return escalate(item.slug, 'dep-not-merged', { depOut });
    }
  }

  // --- 3b. Pre-create the deterministic worktree (worktree.sh create) ------
  // On a continuation we REUSE the existing worktree (MINOR fix): the escalated
  // item's worktree + its committed build + the .build-guard marker are all
  // intact, and worktree.sh create force-removes-and-re-adds (worktree.sh:113),
  // which would DISCARD the escalated build. So skip create entirely and resume
  // against the deterministic path. The injected verdict (3c) makes resuming on
  // the existing worktree correct — the worker builds on its own prior work
  // plus the human's decision, exactly the escalation-resume contract.
  let wt = worktreePath;
  if (!isContinuation) {
    const wtBin = spineBin(repoRoot, 'worktree.sh');
    const wtOut = await runSpine(
      `${wtBin} create ${sq(repoRoot)} ${sq(item.slug)}`,
      { label: `worktree:${item.slug}`, slug: item.slug },
    );
    if (spineDenied(wtOut)) {
      return escalate(item.slug, 'spine-denied', { step: 'worktree', out: wtOut });
    }
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
  let verdict = await agent(workerPrompt(item, wt, verdictSection), {
    label: `worker:${item.slug}`,
    phase: 'worker',
    model: item.model, // undefined → inherit session model
    schema: WORKER_VERDICT_SCHEMA,
  });
  if (verdict == null) {
    // agent() returned null — user skip or transient API error (e.g. 5xx).
    // Auto-retry exactly once; a 5xx is typically transient and one retry clears it.
    log(`[${item.slug}] worker returned null — retrying once`);
    verdict = await agent(workerPrompt(item, wt, verdictSection), {
      label: `worker:${item.slug}#retry`,
      phase: 'worker',
      model: item.model,
      schema: WORKER_VERDICT_SCHEMA,
    });
    if (verdict == null) {
      // Still null after one retry — escalate cleanly rather than throw.
      return escalate(item.slug, 'worker-error', { retryable: true, reason: 'agent returned null after one retry (main worker)' });
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
  const qgBin = `${repoRoot}/scripts/quality-gates.sh`;
  const gateOut = await runSpine(
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
      `else ( cd ${sq(wt)} && ${sq(qgBin)} ) >/tmp/qg-${item.slug}.log 2>&1 ` +
      `&& echo '{"outcome":"GATE_PASS"}' || echo '{"outcome":"GATE_FAIL"}'; fi`,
    // temperloop#115: the full quality-gates.sh suite runs >2min; without an
    // explicit timeout the executor's Bash tool kills it at 120s → false
    // GATE_FAIL. GATE_BASH_TIMEOUT_MS gives the suite room to finish.
    { label: `gate:${item.slug}`, slug: item.slug, bashTimeoutMs: GATE_BASH_TIMEOUT_MS },
  );
  if (spineDenied(gateOut)) {
    return escalate(item.slug, 'spine-denied', { step: 'gate', out: gateOut });
  }
  if (gateOut.outcome === 'GATE_FAIL') {
    return escalate(item.slug, 'acceptance-gate-failed', { gateOut });
  }
  // GATE_PASS or GATE_ABSENT → proceed.

  // --- 3f. Push and open the PR --------------------------------------------
  const prBin = spineBin(repoRoot, 'pr.sh');

  // 3f-0a. Rebase onto fresh origin/<default> — the unconditional stale-base
  // guard (#525). EVERY worker (not just speculative ones) branched off the
  // default at the start of its run; on a fast-moving default a long run lets
  // the default advance mid-build, so by here the worker's base may be stale
  // and a straight push would land a PR whose cumulative diff REVERTS whatever
  // merged in between (W49/W52). pr.sh rebase fetches the default fresh and
  // replays the worker's commits onto its tip (a no-op when already current).
  // On REBASE_CONFLICT it has already `git rebase --abort`ed (worktree left
  // clean, NEVER a silent revert) → escalate as a rebase conflict for a human.
  const rebaseOut = await runSpine(`${prBin} rebase ${sq(wt)}`, {
    label: `rebase:${item.slug}`,
    slug: item.slug,
  });
  if (spineDenied(rebaseOut)) {
    return escalate(item.slug, 'spine-denied', { step: 'rebase', out: rebaseOut });
  }
  if (rebaseOut.outcome === 'REBASE_CONFLICT') {
    return escalate(item.slug, 'rebase-conflict', { rebaseOut });
  }
  if (rebaseOut.outcome !== 'REBASED') {
    return escalate(item.slug, 'rebase-error', { rebaseOut });
  }

  // 3f-0. Closing-keyword pre-push scan.
  const scanOut = await runSpine(`${prBin} scan ${sq(wt)}`, {
    label: `scan:${item.slug}`,
    slug: item.slug,
  });
  if (spineDenied(scanOut)) {
    return escalate(item.slug, 'spine-denied', { step: 'scan', out: scanOut });
  }
  if (scanOut.outcome === 'SCAN_BLOCKED') {
    // A worker commit carries a closing keyword (the ec8d5fd class). Don't push
    // it as-is — escalate so the orchestrator re-words and re-drives.
    return escalate(item.slug, 'closing-keyword', { scanOut });
  }
  if (scanOut.outcome !== 'SCAN_CLEAN') {
    return escalate(item.slug, 'scan-error', { scanOut });
  }

  // 3f-1. Push-by-SHA on the plan's branch.
  const pushOut = await runSpine(
    `${prBin} push ${sq(wt)} ${sq(item.branch)}`,
    { label: `push:${item.slug}`, slug: item.slug },
  );
  if (spineDenied(pushOut)) {
    return escalate(item.slug, 'spine-denied', { step: 'push', out: pushOut });
  }
  if (pushOut.outcome === 'PUSH_REJECTED') {
    // Remote-branch collision / non-ff — orchestrator triages (force vs rename).
    return escalate(item.slug, 'push-rejected', { pushOut });
  }
  if (pushOut.outcome !== 'PUSHED') {
    return escalate(item.slug, 'push-error', { pushOut });
  }
  const pushedSha = pushOut.sha;

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
  });
  const ghIssueFlag = item.ghIssue ? ` --gh-issue ${sq(item.ghIssue)}` : '';
  const alsoClosesFlag = item.alsoCloses?.length
    ? ` --also-closes ${sq(item.alsoCloses.join(','))}`
    : '';
  const openCmd =
    `vf=$(mktemp) && printf %s ${sq(verdictJson)} > "$vf" && ` +
    `${prBin} open --repo ${sq(repoRoot)} --branch ${sq(item.branch)} ` +
    `--title ${sq(item.title)} --verdict "$vf"${ghIssueFlag}${alsoClosesFlag} ` +
    `--verification-surface-file ${sq(`${wt}/.build-verification.md`)} ` +
    `--plan-link ${sq(planLink)} --source ${sq(item.source ?? '')}; ` +
    `rc=$?; rm -f "$vf"; exit $rc`;
  const openOut = await runSpine(openCmd, { label: `pr-open:${item.slug}`, slug: item.slug });
  // EXISTS means the branch already had an open PR (a create-retry after a
  // succeeded first attempt). Treat it as PR_OPENED — adopt the existing PR and
  // continue to CI-poll/park-with-pr. Any other non-PR_OPENED outcome is a
  // genuine failure and escalates as pr-open-failed.
  if (spineDenied(openOut)) {
    return escalate(item.slug, 'spine-denied', { step: 'pr-open', out: openOut });
  }
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
  log(`[${item.slug}] parked — PR #${pr} CI green`);
  return park(item.slug, pr, ciResult.finalSha ?? pushedSha, verdict.acceptance_results);
}

// -----------------------------------------------------------------------------
// ciPollLoop — bounded short-slice CI poll (DESIGN NOTE 2).
// -----------------------------------------------------------------------------
// Loops runSpine over CI_POLL_SLICE_SECS-timeout ci-poll.sh calls until the
// outcome resolves. TIMEOUT on a slice = "still pending, poll again" (NOT a
// failure) — we keep looping while the total budget remains. On CI_FAILED,
// within CI_FAIL_RETRY_BUDGET, we re-spawn the worker + force-push + re-poll
// PINNED to the new SHA (#254 false-green guard). Returns:
//   { ok:true, finalSha }                         — CI green
//   { escalation:'ci-failed', payload:{...} }      — budget exhausted / hard fail
//   { escalation:'merge-conflict', payload:{...} } — PR is CONFLICTING/DIRTY

// MERGE_STATE_SCHEMA — minimal schema for the gh pr view merge-state check.
// A separate schema (not SPINE_OUTCOME_SCHEMA) so we do NOT alter the closed
// spine outcome enum (#543: "Do NOT touch SPINE_OUTCOME_SCHEMA").
const MERGE_STATE_SCHEMA = {
  type: 'object',
  required: [],
  additionalProperties: true,
  properties: {
    mergeable:       { type: 'string' },
    mergeStateStatus: { type: 'string' },
    error:           { type: 'string' },
  },
};

function mergeStateCmd(ownerRepo, pr) {
  // gh pr view returns JSON; if it fails (e.g. auth error) the executor catches
  // non-zero exit and returns whatever gh printed — the caller handles missing fields.
  return `gh pr view ${sq(pr)} --repo ${sq(ownerRepo)} --json mergeable,mergeStateStatus`;
}

function ciPollCmd(ownerRepo, pr, sha) {
  const ciBin = spineBin(input.repoRoot, 'ci-poll.sh');
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

  for (let slice = 0; slice < maxSlices; slice++) {
    // --- CONFLICTING/DIRTY early-exit (#543) ---------------------------------
    // GitHub never creates a CI check-suite for a PR whose merge ref can't be
    // computed (CONFLICTING/DIRTY), so ci-poll.sh returns TIMEOUT indefinitely.
    // Check merge state BEFORE each poll slice; if CONFLICTING/DIRTY, escalate
    // immediately rather than spinning the full CI_POLL_TOTAL_SECS budget.
    const mergeState = await agent(
      [
        'Run this single read-only status command with the Bash tool, exactly as written — do not add flags or extra commands.',
        'It queries the PR merge state (a `gh pr view`) and prints a JSON object; return it verbatim as your result.',
        'If the command exits non-zero, return { "error": "<stderr>" }.',
        '',
        'Command:',
        mergeStateCmd(ownerRepo, pr),
      ].join('\n'),
      {
        label: `merge-check:${item.slug}#${slice}`,
        phase: 'merge-check',
        agentType: 'general-purpose',
        model: 'haiku',
        schema: MERGE_STATE_SCHEMA,
      },
    );
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

    const out = await runSpine(ciPollCmd(ownerRepo, pr, sha), {
      label: `ci-poll:${item.slug}#${slice}`,
      slug: item.slug,
    });

    if (spineDenied(out)) {
      return { escalation: 'spine-denied', payload: { step: 'ci-poll', out, sha } };
    }

    if (out.outcome === 'CI_GREEN') {
      return { ok: true, finalSha: sha };
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
      // Push the fixed SHA and pin the re-poll to it. We *request* --force, but
      // pr.sh downgrades it to a plain fast-forward push when the fixed head
      // descends from the remote tip (the common CI-retry case: reset-to-tip +
      // commit), which is a fast-forward — this keeps the git-destructive safety
      // classifier from denying a routine retry in auto mode (#335). --force is
      // still used (correctly) if the CI-fix worker rewrote history.
      const prBin = spineBin(input.repoRoot, 'pr.sh');
      const fpush = await runSpine(
        `${prBin} push ${sq(wt)} ${sq(item.branch)} --force`,
        { label: `push-force:${item.slug}`, slug: item.slug },
      );
      if (spineDenied(fpush)) {
        return { escalation: 'spine-denied', payload: { step: 'push-force', out: fpush, sha } };
      }
      if (fpush.outcome !== 'PUSHED') {
        return { escalation: 'ci-failed', payload: { fpush, sha } };
      }
      sha = fpush.sha; // authoritative — pin the next poll to it (NOT the PR API)
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
