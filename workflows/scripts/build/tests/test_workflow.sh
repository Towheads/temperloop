#!/usr/bin/env bash
#
# Offline fixture harness for claude/workflows/build-level.mjs — the
# per-level Workflow driver for /build (foundation epic #419, item #423).
#
# Approach: The .mjs is a standard ES module with `export default async function
# buildLevel()` and ambient hooks (agent/parallel/log/phase) resolved via the
# Workflow runtime. We inject those hooks as globalThis properties BEFORE the
# dynamic import(), so the same module runs deterministically under plain Node
# (v26, zero network). No modifications to the .mjs are needed.
#
# parallel() in the runtime maps to Promise.all — items in one level run
# concurrently. The mock infrastructure therefore keys per-item machinery/worker
# response sequences by slug (extracted from opts.label), not by global
# position in a flat queue. This makes the mock deterministic regardless of
# which item's agent() calls land first.
#
# Covers:
#   - happy: 3 green items → 3 parked, empty escalations, no plan-note write
#   - design-fork: one item returns design-fork → escalations[], siblings park
#   - failed verdict: one item returns failed → escalation, sibling parks
#   - ci-failed within budget: CI_FAILED then fix-worker + force-push → CI_GREEN → parked
#   - ci-failed past budget: CI_FAILED, retries exhausted → ci-failed escalation
#   - ci-poll TIMEOUT loop: TIMEOUT slices then CI_GREEN → parked
#   - claim-conflict: CLAIM_CONFLICT → claim-conflict escalation
#   - push-rejected: PUSH_REJECTED → push-rejected escalation
#   - scan-blocked: SCAN_BLOCKED → closing-keyword escalation
#   - 2-level e2e smoke: two buildLevel() calls (stateless), each produces parked/escalations
#   - deploy-discovery: ~/.claude/workflows/build-level.mjs resolves (install-claude)
#   - spike kind: spike items skip push/PR/CI, park with null pr/pushed_sha
#   - gate-fail: GATE_FAIL → acceptance-gate-failed escalation
#   - gate verdict/payload agreement (#1587): the escalation kind, its verdict,
#     its failure count and its reason all derive from ONE slice ledger, in all
#     four gate outcomes — no payload field may contradict the kind it ships under
#   - worktree-failed: worktree.sh non-CREATED → worktree-failed escalation
#   - continuation: onlySlugs+verdicts → verdict injected into worker prompt,
#     existing worktree reused (no create/claim), only continued slug driven
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)"
MJS="$REPO_ROOT/claude/workflows/build-level.mjs"
[ -f "$MJS" ] || { echo "FAIL: build-level.mjs not found at $MJS" >&2; exit 1; }

# temperloop#1014: the machinery executors run as the `machinery-executor` agent,
# whose definition carries the standing contract the lean prompt no longer
# restates. The suite asserts against that file, so its absence is a hard fail
# (the driver would silently fall back to general-purpose and the context win
# would vanish unnoticed).
AGENT_DEF="$REPO_ROOT/claude/agents/machinery-executor.md"
[ -f "$AGENT_DEF" ] || { echo "FAIL: machinery-executor agent definition not found at $AGENT_DEF" >&2; exit 1; }

# Node preflight (#436): this harness runs build-level.mjs under Node. Without it
# the suite fails mid-case with a cryptic "node: command not found"; fail LOUDLY and
# actionably instead so a node-less dev machine is obvious, not confusing. CI runners
# ship Node, so this passes there and the suite runs normally. (Do NOT skip-and-pass
# on absence — that would falsely green `make quality-gates` while the gate never ran,
# breaking local==CI parity.)
command -v node >/dev/null 2>&1 || {
  echo "FAIL: 'node' not found — this gate executes claude/workflows/build-level.mjs under Node." >&2
  echo "      Install it: 'brew install node' (macOS). See Towheads/foundation#436." >&2
  exit 1
}

fail() { echo "FAIL: $1" >&2; exit 1; }

# Unique per-run temp root (#258): a fixed /tmp/wf-test-* path collides when
# two `quality-gates.sh` runs execute this suite concurrently in separate
# worktrees on the same host (parallel /build workers). mktemp -d gives each
# invocation its own PID/random-suffixed directory, and the EXIT trap sweeps
# it — no shared prefix for a sibling run to clobber or race against.
WF_TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/wf-test.XXXXXX")"
trap 'rm -rf "$WF_TEST_TMPDIR"' EXIT

# ---------------------------------------------------------------------------
# run_node_case <description> <node-es-module-body>
# Writes a temp .mjs, runs it with node, reads the last stdout line as a JSON
# { ok: true } / { ok: false, reason: "..." } verdict.
# ---------------------------------------------------------------------------
run_node_case() {
  local desc="$1"
  local tmpf
  tmpf="$(mktemp "$WF_TEST_TMPDIR/case-XXXXXX.mjs")"
  printf '%s\n' "$2" > "$tmpf"
  local out rc=0
  out="$(node "$tmpf" 2>&1)" || rc=$?
  rm -f "$tmpf"
  if [ $rc -ne 0 ]; then
    echo "FAIL: $desc — node exited $rc" >&2
    echo "$out" >&2
    exit 1
  fi
  local last
  last="$(printf '%s\n' "$out" | tail -1)"
  local verdict
  verdict="$(printf '%s' "$last" | node -e "
    let s='';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data',c=>s+=c);
    process.stdin.on('end',()=>{
      try {
        const r=JSON.parse(s);
        process.stdout.write(r.ok ? 'ok' : 'fail:' + JSON.stringify(r.reason||'false'));
      } catch(e) {
        process.stdout.write('parse-err:' + s.slice(0,200));
      }
    });
  " 2>/dev/null)" 2>/dev/null || verdict="parse-err"

  if [[ "$verdict" == ok ]]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc — $verdict" >&2
    echo "Full node output:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}

# ============================================================================
# Shared harness preamble injected at the start of every Node test case.
#
# Mock infrastructure design:
#   - machineryMap: Map<slug, outcome[]> — per-item ordered machinery returns
#   - workerMap: Map<slug, verdict[]> — per-item ordered worker returns
#   - agent() routes by opts.schema (machinery) vs no schema (worker), extracting
#     slug from opts.label (format: "phase:slug[#extra]")
#   - parallel() = Promise.all (matches runtime behaviour)
#   - log(), phase() = no-ops
#   - callLog: records every agent() call for plan-note-write assertions
#
# loadLevel() imports the .mjs fresh with a cache-busting query param so
# each test case gets a clean module instance.
# ============================================================================
read -r -d '' PREAMBLE << 'PREAMBLE_END' || true
import { readFileSync } from 'fs';
const MJS = process.env.MJS_PATH;

// temperloop#1014: the machinery executor's STANDING contract (run it verbatim,
// one JSON line per step, an early stop is expected) lives in the executor
// agent's own definition, so the lean per-call prompt no longer restates it. A
// test that asserts the contract reaches the executor must therefore look at
// whichever surface carries it on the path under test — this prompt for the
// general-purpose fallback, this file for the lean default.
const AGENT_DEF = readFileSync(process.env.AGENT_DEF_PATH, 'utf8');
globalThis.AGENT_DEF = AGENT_DEF;

const callLog = [];

// --- temperloop#1294: agent-KIND classifiers --------------------------------
// opts.phase is no longer the flat 'machinery'/'worker' constant — it is the
// per-STAGE progress heading (`build level · <stage> — <repo> · N items · …`),
// dynamic by construction because it carries #903's run context. So the mock can
// no longer route (and cases can no longer assert) on the phase STRING.
//
// Route on the LABEL instead: every spawn site already encodes the agent kind
// there — `worker:` / `worker-cifix:` is the implementation worker, everything
// else is a machinery executor. Deliberately NOT derived from the phase string:
// a label-based classifier keeps working if the heading format is retuned again,
// and an agent spawned with NO label matches neither, which is exactly what the
// "no third agent kind" assertion wants to catch.
globalThis.isWorkerCall = (o) => /^(worker|worker-cifix):/.test(String((o && o.label) || ''));
// temperloop#1430: a THIRD agent kind — the §3e reviewer(s), spawned directly
// by driveItem (never via the worker). Label grammar: `review:<slug>#<reviewer>`
// (the `#`-delimited extra form every other multi-part label already uses —
// see slugFromLabel below). Excluded from isMachineryCall so a review spawn
// never falls into the machinery batch/solo dispatcher (it returns free
// advisory TEXT, not a closed-outcome JSON object).
globalThis.isReviewCall = (o) => /^review:/.test(String((o && o.label) || ''));
globalThis.isMachineryCall = (o) => !!(o && o.label) && !globalThis.isWorkerCall(o) && !globalThis.isReviewCall(o);

// machineryMap: slug → [outcome, ...] — consumed in order per slug
const machineryMap = new Map();
// workerMap: slug → [verdict, ...] — consumed in order per slug
const workerMap = new Map();
// reviewMap: slug → [response, ...] — consumed in order per slug, one entry
// PER MATCHED REVIEWER (routes run in Map-insertion order — see
// determineReviewers()). A response is a review-text STRING, `null` (models
// agent() returning null — skip/transient), or `{__throw: msg}` (models
// agent() THROWING — a resolution failure when msg matches
// MACHINERY_RESOLUTION_ERR's shape, any other error otherwise). Default
// (map miss): null — "reviewer ran but returned nothing", never a crash.
const reviewMap = new Map();
// mergeCheckMap: slug → [mergeState, ...] — consumed in order per slug.
// Default (map miss): { mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN' }
// so existing tests need no changes — only CONFLICTING tests override this.
const mergeCheckMap = new Map();

function slugFromLabel(label) {
  // Labels from runMachineryBatch (temperloop#942): "prelude:slug",
  // "pr-batch:slug", "ci-batch:slug#N".
  // Labels from the remaining solo runMachinery calls: "gate:slug",
  // "recover-probe:slug", "push-retry:slug", "machinery:cmd ..."
  // Labels from worker: "worker:slug", "worker-cifix:slug"
  if (!label) return null;
  const m = label.match(/^[^:]+:([^#\s]+)/);
  return m ? m[1] : null;
}

// --- temperloop#942: batched-machinery mock ---------------------------------
// The driver now sends SEVERAL machinery commands per executor agent
// (`prelude:` / `pr-batch:` / `ci-batch:` labels) and the agent returns
// { results: [...] } — ONE object per step that actually RAN (shorter than the
// step list whenever the real bash short-circuit stopped the sequence).
//
// The mock replays the SAME flat per-slug outcome queue the solo path uses: one
// entry per step, stopping where bash would. BATCH_CONTINUE_ON is the harness's
// own INDEPENDENT restatement of each step kind's continue rule — deliberately
// not read from the .mjs, so if production's `continueOutcomes` and this table
// ever diverge a case desyncs and fails, which is the point.
const BATCH_CONTINUE_ON = {
  claim: ['CLAIMED'],
  'deps-merged': ['DEPS_MERGED'],
  worktree: null,   // terminal within the prelude
  rebase: ['REBASED'],
  scan: ['SCAN_CLEAN'],
  push: ['PUSHED'],
  'pr-open': null,  // terminal within the pr-batch
  'ci-poll': ['TIMEOUT'],
};

// machineryStepLog — every batched step the mock actually RAN, in order:
// { slug, kind }. This is the batching-era replacement for the old per-command
// label assertions (there is no longer a `worktree:`/`depcheck:`/`ci-poll:`
// agent label to filter callLog on — the step lives inside one batch).
const machineryStepLog = [];
globalThis.machineryStepLog = machineryStepLog;
globalThis.stepsRun = (slug) => machineryStepLog.filter(s => s.slug === slug).map(s => s.kind);

// The prompt's own `Steps: a, b, c` manifest identifies a batched call and names
// its steps in order.
function batchStepKinds(prompt) {
  const m = String(prompt).match(/^Steps: (.+)$/m);
  return m ? m[1].split(', ') : null;
}

function nextFromMap(map, slug, fallback) {
  const q = map.get(slug);
  if (q && q.length > 0) return q.shift();
  if (fallback !== undefined) return fallback;
  throw new Error(`No mock entry for slug="${slug}" in map; label exhausted`);
}

globalThis.callLog = callLog;
globalThis.machineryMap = machineryMap;
globalThis.workerMap = workerMap;
globalThis.mergeCheckMap = mergeCheckMap;
globalThis.reviewMap = reviewMap;

globalThis.agent = async function agent(prompt, opts = {}) {
  callLog.push({ prompt: String(prompt).slice(0, 120), promptFull: String(prompt), opts: { label: opts.label, phase: opts.phase, model: opts.model, agentType: opts.agentType } });
  const slug = slugFromLabel(opts.label);
  if (isMachineryCall(opts)) {
    const kinds = batchStepKinds(prompt);
    if (!kinds) {
      // Solo executor (gate / recover-probe / push-retry) — routed by slug.
      return nextFromMap(machineryMap, slug, { outcome: 'ERROR', error: 'unexpected machinery call for ' + slug });
    }
    // Batched executor (temperloop#942): consume one queued outcome per step and
    // stop exactly where the emitted bash `case` gate would.
    const results = [];
    for (const kind of kinds) {
      // The merge-state probe is `gh pr view`, not a machinery script — it keeps
      // its own map (default non-conflicting) so pre-batching cases that call
      // setMergeCheck() need no changes.
      const r = kind === 'merge-state'
        ? nextFromMap(mergeCheckMap, slug, { mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN' })
        : nextFromMap(machineryMap, slug, { outcome: 'ERROR', error: 'unexpected machinery step ' + kind + ' for ' + slug });
      machineryStepLog.push({ slug, kind });
      // A queued null models the auto-mode classifier DENYING the command: the
      // whole executor call comes back null, not a partial results array.
      if (r === null) return null;
      // temperloop#1067: a queued { __lostReturn: true } entry models the step
      // RUNNING (its real bash command executed — machineryStepLog already
      // recorded it above) but the executor's own JSON line for it never
      // reaching the driver (a dropped/truncated last line), NOT a short-circuit
      // stop. No entry is pushed to `results` for this step, so batchStep()
      // synthesizes its 'produced no result' sentinel — exactly the fidelity
      // drop this wiring probes for, distinct from every prior test's
      // short-circuit stop (which always includes an entry for the stopping
      // step itself).
      if (r.__lostReturn) break;
      results.push(r);
      if (kind === 'merge-state') {
        if (r.mergeable === 'CONFLICTING' || r.mergeStateStatus === 'DIRTY') break;
      } else {
        const cont = BATCH_CONTINUE_ON[kind];
        if (cont && !cont.includes(r.outcome)) break;
      }
    }
    return { results };
  }
  if (isWorkerCall(opts)) {
    // Worker call — implementation agent, routed by slug.
    // temperloop#939: a queued { __throw: '<msg>' } entry makes agent() THROW
    // instead of returning — faithfully simulating the real runtime when a
    // subagent completes without calling StructuredOutput, or blows the
    // StructuredOutput retry cap. That is an EXCEPTION, not a null return, so a
    // mock that can only return null cannot exercise the #939 path at all.
    const v = nextFromMap(workerMap, slug, { status: 'done', summary: 'default', acceptance_results: [], commits: [] });
    if (v && v.__throw) throw new Error(v.__throw);
    return v;
  }
  if (isReviewCall(opts)) {
    // §3e reviewer call (temperloop#1430) — routed by slug, ONE queued entry
    // consumed per matched reviewer (in the order determineReviewers() found
    // them). Default (map miss): null — a reviewer that ran but returned
    // nothing, never a crash. A string models a normal advisory-text return;
    // { __throw: msg } models agent() THROWING (msg matching
    // MACHINERY_RESOLUTION_ERR's shape models a genuine resolution failure —
    // the same precedent machineryAgent() uses).
    const v = nextFromMap(reviewMap, slug, null);
    if (v && v.__throw) throw new Error(v.__throw);
    return v;
  }
  // Fallback (should not happen in well-formed test cases)
  return nextFromMap(workerMap, slug, { status: 'done', summary: 'fallback', acceptance_results: [], commits: [] });
};

globalThis.log = () => {};
globalThis.phase = () => {};
globalThis.parallel = async (fns) => Promise.all(fns.map(f => f()));

// Helpers to register sequences
globalThis.setMachinery = (slug, ...outcomes) => { machineryMap.set(slug, outcomes); };
globalThis.setWorker = (slug, ...verdicts) => { workerMap.set(slug, verdicts); };
globalThis.setMergeCheck = (slug, ...states) => { mergeCheckMap.set(slug, states); };
globalThis.setReview = (slug, ...responses) => { reviewMap.set(slug, responses); };
// reviewResolutionFailure — the SAME two-marker shape machineryAgent()'s own
// MACHINERY_RESOLUTION_ERR regex matches (temperloop#1014/#1430): agent()
// rejecting an unresolvable/denied agentType BEFORE any subagent spawns.
globalThis.reviewUnavailable = (agentType) => ({ __throw: `agent type '${agentType}' not found. Available agents: general-purpose` });
// temperloop#939 mock shorthands.
// throwingWorker(msg) — the #939 return-channel failure (agent() throws).
globalThis.throwingWorker = (msg) => ({ __throw: msg || 'agent({schema}): subagent completed without calling StructuredOutput (after in-conversation nudge)' });
// noSideEffects — the recover-probe answer for a genuinely-failed worker.
globalThis.noSideEffects = () => ({ outcome: 'RECOVER_NONE', commits_ahead: 0, pushed: false, dirty: false, dirty_files: 0, verification_surface_present: false });
// temperloop#993 shorthand — dirtyStall(n): the recover-probe answer for a worker
// reaped mid-flight by a backgrounded gate: n uncommitted paths, ZERO commits.
globalThis.dirtyStall = (n) => ({ outcome: 'RECOVER_DIRTY', commits_ahead: 0, pushed: false, dirty: true, dirty_files: n ?? 8, verification_surface_present: false });
// temperloop#1067 shorthand — lostReturn(): queue this in place of a step's
// outcome to model a DROPPED JSON line (the step ran; its result never
// reached the driver) rather than a genuine failure or a short-circuit stop.
// See the __lostReturn handling in the batched-executor mock above.
globalThis.lostReturn = () => ({ __lostReturn: true });

// Canonical happy-path machinery sequence for a green item
globalThis.happyMachinery = (slug, prNum, sha) => setMachinery(slug,
  { outcome: 'CREATED', path: '/tmp/repo.wt/' + slug },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha, branch: 'build/' + slug },
  { outcome: 'PR_OPENED', pr_number: prNum },
  { outcome: 'CI_GREEN' },
);
globalThis.happyWorker = (slug, extra) => setWorker(slug,
  { status: 'done', summary: slug + ' done', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [], ...(extra||{}) }
);

let _loadCount = 0;
// Faithful runtime simulation (#437): the Workflow runtime does NOT import the
// .mjs as an ES module — it strips `export const meta`, wraps the remaining body
// in an async function (so top-level await + top-level `return` work), supplies
// agent/parallel/log/phase as ambient hooks, and delivers `args` as a JSON
// STRING. We replicate that exactly, so this harness exercises the REAL
// invocation format. A plain import() silently passes a non-runnable file — that
// was the #437 false-green (it cannot even parse a top-level `return`). Each load
// gets a fresh AsyncFunction instance.
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const MJS_SRC = readFileSync(MJS, 'utf8').replace(/^export const meta/m, 'const meta');
globalThis.loadLevel = async () => {
  _loadCount++;
  const fn = new AsyncFunction(MJS_SRC);
  return {
    default: async () => {
      const a = globalThis.args;
      globalThis.args = typeof a === 'string' ? a : JSON.stringify(a); // runtime delivers args as a JSON string
      return await fn();
    },
  };
};

const baseArgs = {
  repoRoot: '/tmp/repo',
  board: null,
  planLink: 'Plans/test.md',
  ownerRepo: 'owner/repo',
};
globalThis.baseArgs = baseArgs;
PREAMBLE_END

export MJS_PATH="$MJS"
export AGENT_DEF_PATH="$AGENT_DEF"

# ============================================================================
# TEST 1: happy — 3 green items → 3 parked, empty escalations, no plan-note write
# ============================================================================
run_node_case "happy: 3 green items → 3 parked, empty escalations, no plan-note write" "
$PREAMBLE

happyMachinery('item101', 101, 'sha1');
happyMachinery('item102', 102, 'sha2');
happyMachinery('item103', 103, 'sha3');
happyWorker('item101');
happyWorker('item102');
happyWorker('item103');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item101', branch: 'build/item101', title: 'Item 101', kind: 'impl', acceptance: ['c'] },
  { slug: 'item102', branch: 'build/item102', title: 'Item 102', kind: 'impl', acceptance: ['c'] },
  { slug: 'item103', branch: 'build/item103', title: 'Item 103', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
const escalations = result.escalations ?? [];

if (parked.length !== 3)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 3 parked, got ' + parked.length + '; ' + JSON.stringify(result) })); process.exit(0); }
if (escalations.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 escalations, got ' + JSON.stringify(escalations) })); process.exit(0); }

const p101 = parked.find(p => p.slug === 'item101');
const p102 = parked.find(p => p.slug === 'item102');
const p103 = parked.find(p => p.slug === 'item103');
if (!p101 || p101.pr !== 101 || p101.pushed_sha !== 'sha1')
  { console.log(JSON.stringify({ ok: false, reason: 'item101 mismatch: ' + JSON.stringify(p101) })); process.exit(0); }
if (!p102 || p102.pr !== 102 || p102.pushed_sha !== 'sha2')
  { console.log(JSON.stringify({ ok: false, reason: 'item102 mismatch: ' + JSON.stringify(p102) })); process.exit(0); }
if (!p103 || p103.pr !== 103 || p103.pushed_sha !== 'sha3')
  { console.log(JSON.stringify({ ok: false, reason: 'item103 mismatch: ' + JSON.stringify(p103) })); process.exit(0); }

// No plan-note write from inside the workflow (workflow only RETURNS; orchestrator writes)
const planWrites = callLog.filter(c =>
  !isMachineryCall(c.opts) && !isWorkerCall(c.opts) &&
  (String(c.prompt).toLowerCase().includes('write the plan') || String(c.prompt).toLowerCase().includes('update the plan note'))
);
if (planWrites.length > 0)
  { console.log(JSON.stringify({ ok: false, reason: 'plan-note write detected: ' + JSON.stringify(planWrites) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 2: design-fork — one item returns design-fork, siblings still park
# ============================================================================
run_node_case "design-fork: one design-fork item → escalations[], siblings park" "
$PREAMBLE

happyMachinery('item-a', 201, 'sha-a');
happyMachinery('item-b', 202, 'sha-b');
// item-fork: CREATED only (worker escalates immediately after worktree step)
setMachinery('item-fork',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-fork' }
);
happyWorker('item-a');
setWorker('item-fork',
  { status: 'design-fork', design_fork: { decision: 'need a seam', options: [{ label: 'opt1', tradeoff: 'fast' }], recommendation: 'opt1', evidence: 'ev' } }
);
happyWorker('item-b');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-a',    branch: 'build/item-a',    title: 'Item A',    kind: 'impl' },
  { slug: 'item-fork', branch: 'build/item-fork', title: 'Item Fork', kind: 'impl' },
  { slug: 'item-b',    branch: 'build/item-b',    title: 'Item B',    kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 2 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'design-fork')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if (result.escalations[0].slug !== 'item-fork')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation slug wrong: ' + result.escalations[0].slug })); process.exit(0); }

const parkedSlugs = (result.parked ?? []).map(p => p.slug).sort();
if (JSON.stringify(parkedSlugs) !== JSON.stringify(['item-a','item-b']))
  { console.log(JSON.stringify({ ok: false, reason: 'wrong slugs parked: ' + JSON.stringify(parkedSlugs) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 3: failed verdict → escalation, sibling still parks
# ============================================================================
run_node_case "failed verdict: one item returns failed → escalation, sibling parks" "
$PREAMBLE

happyMachinery('item-good', 301, 'sha-good');
setMachinery('item-bad', { outcome: 'CREATED', path: '/tmp/repo.wt/item-bad' });
happyWorker('item-good');
setWorker('item-bad', { status: 'failed', failure_reason: 'could not compile' });

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-good', branch: 'build/item-good', title: 'Good Item', kind: 'impl' },
  { slug: 'item-bad',  branch: 'build/item-bad',  title: 'Bad Item',  kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'failed')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if (result.parked[0].slug !== 'item-good')
  { console.log(JSON.stringify({ ok: false, reason: 'wrong item parked: ' + result.parked[0].slug })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 4: ci-failed within budget → re-spawn + force-push + CI_GREEN → parked
# The CI-failure re-spawn worker must run top-tier (no model specified).
# pushed_sha must be the re-pushed sha, not the initial push.
# ============================================================================
run_node_case "ci-failed within budget: re-spawn + force-push + re-poll CI_GREEN → parked" "
$PREAMBLE

setMachinery('item-cifix',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-cifix' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-v1' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-v1', branch: 'build/item-cifix' },
  { outcome: 'PR_OPENED', pr_number: 401 },
  // First CI poll: CI_FAILED
  { outcome: 'CI_FAILED', failed_run_ids: [9001] },
  // temperloop#1450: §3e re-review of the CI-fix commit, before the retry push
  { outcome: 'REVIEW_DIFF' },
  // Retry push after fix worker (plain push — ff descendant, no --force)
  { outcome: 'PUSHED', sha: 'sha-v2', branch: 'build/item-cifix' },
  // Re-poll pinned to sha-v2: CI_GREEN
  { outcome: 'CI_GREEN' },
);

let ciFixWorkerModel = undefined;
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts={}) {
  // Track model on the CI-fix worker call
  if (isWorkerCall(opts) && String(prompt).includes('CI failed')) {
    ciFixWorkerModel = opts.model;
  }
  return origAgent(prompt, opts);
};

setWorker('item-cifix',
  { status: 'done', summary: 'initial', acceptance_results: [], commits: [] },
  // Fix worker (for the 'worker-cifix:item-cifix' label):
  { status: 'done', summary: 'ci fixed', acceptance_results: [], commits: [] }
);
// worker-cifix label also routes to the same slug via slugFromLabel
workerMap.set('item-cifix', workerMap.get('item-cifix'));  // already set above

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-cifix', branch: 'build/item-cifix', title: 'CI Fix Item', kind: 'impl', model: 'haiku' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'unexpected escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.parked[0].pushed_sha !== 'sha-v2')
  { console.log(JSON.stringify({ ok: false, reason: 'pushed_sha not re-pushed sha: ' + result.parked[0].pushed_sha })); process.exit(0); }
// CI-fix worker must omit model (top tier = undefined)
if (ciFixWorkerModel !== undefined)
  { console.log(JSON.stringify({ ok: false, reason: 'ci-fix worker had model: ' + ciFixWorkerModel })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 5: ci-failed past budget → ci-failed escalation
# CI_FAIL_RETRY_BUDGET=1, so after 1 retry: second CI_FAILED → escalate
# ============================================================================
run_node_case "ci-failed past budget: retries exhausted → ci-failed escalation" "
$PREAMBLE

setMachinery('item-cibust',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-cibust' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-v1' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-v1', branch: 'build/item-cibust' },
  { outcome: 'PR_OPENED', pr_number: 501 },
  { outcome: 'CI_FAILED', failed_run_ids: [9002] },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'PUSHED', sha: 'sha-v2', branch: 'build/item-cibust' },
  // Retry budget=1 used up; second CI_FAILED → escalate
  { outcome: 'CI_FAILED', failed_run_ids: [9003] },
);
setWorker('item-cibust',
  { status: 'done', summary: 'initial', acceptance_results: [], commits: [] },
  { status: 'done', summary: 'fix attempt', acceptance_results: [], commits: [] }
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-cibust', branch: 'build/item-cibust', title: 'CI Bust Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'ci-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 6: CI_POLL TIMEOUT loop — multiple TIMEOUT slices then CI_GREEN → parked
# TIMEOUT is NOT a failure; the loop continues until budget or resolution.
# ============================================================================
run_node_case "ci-poll TIMEOUT loop: multiple TIMEOUT slices then CI_GREEN → parked" "
$PREAMBLE

setMachinery('item-timeout',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-timeout' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-t' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-t', branch: 'build/item-timeout' },
  { outcome: 'PR_OPENED', pr_number: 601 },
  { outcome: 'TIMEOUT' },
  { outcome: 'TIMEOUT' },
  { outcome: 'CI_GREEN' },
);
happyWorker('item-timeout');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-timeout', branch: 'build/item-timeout', title: 'Timeout Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked after timeout+green: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'TIMEOUT slices should not escalate: ' + JSON.stringify(result) })); process.exit(0); }
if (result.parked[0].pushed_sha !== 'sha-t')
  { console.log(JSON.stringify({ ok: false, reason: 'pushed_sha wrong: ' + result.parked[0].pushed_sha })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 6b: NO_CI outcome → parked [m] with no_ci:true, NOT ci-failed (#605/#618)
# A zero-CI repo's head SHA resolves NO_CI on the --workflow machinery path; it must
# park like a green item (legible 'no CI configured' skip mirroring build.md 3g)
# carrying the no_ci sentinel, never fall through to the escalate-ci-failed
# catch-all.
# ============================================================================
run_node_case "no-ci: NO_CI outcome → parked with no_ci:true, no escalation (#618)" "
$PREAMBLE

setMachinery('item-noci',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-noci' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-n' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-n', branch: 'build/item-noci' },
  { outcome: 'PR_OPENED', pr_number: 618 },
  { outcome: 'NO_CI', pr: 618, sha: 'sha-n', waited: 90 },
);
happyWorker('item-noci');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-noci', branch: 'build/item-noci', title: 'No-CI Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'NO_CI must NOT escalate (regression: escalate-ci-failed catch-all): ' + JSON.stringify(result) })); process.exit(0); }
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked for NO_CI: ' + JSON.stringify(result) })); process.exit(0); }
if (result.parked[0].pr !== 618)
  { console.log(JSON.stringify({ ok: false, reason: 'parked pr wrong: ' + JSON.stringify(result.parked[0]) })); process.exit(0); }
if (result.parked[0].pushed_sha !== 'sha-n')
  { console.log(JSON.stringify({ ok: false, reason: 'parked pushed_sha wrong: ' + JSON.stringify(result.parked[0]) })); process.exit(0); }
if (result.parked[0].no_ci !== true)
  { console.log(JSON.stringify({ ok: false, reason: 'NO_CI item must carry no_ci:true sentinel: ' + JSON.stringify(result.parked[0]) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 7: claim-conflict → claim-conflict escalation (board ON, ghIssue set)
# ============================================================================
run_node_case "claim-conflict: CLAIM_CONFLICT → claim-conflict escalation" "
$PREAMBLE

// Board ON + ghIssue → claim machinery fires first (before worktree.sh).
// Label: 'claim:item-conflict'
setMachinery('item-conflict',
  { outcome: 'CLAIM_CONFLICT' }
);

globalThis.args = { ...baseArgs, board: 3, claimCmd: '/fake/claim.sh', items: [
  { slug: 'item-conflict', branch: 'build/item-conflict', title: 'Conflict Item', kind: 'impl', ghIssue: 99 },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'claim-conflict')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 8: push-rejected → push-rejected escalation
# ============================================================================
run_node_case "push-rejected: PUSH_REJECTED → push-rejected escalation" "
$PREAMBLE

setMachinery('item-rejected',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-rejected' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-r' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSH_REJECTED', error: 'non-fast-forward' },
);
happyWorker('item-rejected');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-rejected', branch: 'build/item-rejected', title: 'Rejected Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'push-rejected')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 9: scan-blocked → closing-keyword escalation
# ============================================================================
run_node_case "scan-blocked: SCAN_BLOCKED → closing-keyword escalation" "
$PREAMBLE

setMachinery('item-scan',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-scan' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-scan' },
  { outcome: 'SCAN_BLOCKED', matches: ['Closes #42'] },
);
happyWorker('item-scan');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-scan', branch: 'build/item-scan', title: 'Scan Blocked Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'closing-keyword')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 9b: rebase-conflict → rebase-conflict escalation (#525)
# The 3f rebase onto fresh origin/<default> conflicts; pr.sh has already
# aborted (clean worktree). build-level escalates rebase-conflict — never a
# silent revert — and the scan/push never run (the level item escalates).
# ============================================================================
run_node_case "rebase-conflict: REBASE_CONFLICT → rebase-conflict escalation (#525)" "
$PREAMBLE

setMachinery('item-rb',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-rb' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASE_CONFLICT', base: 'b', tip: 't', error: 'CONFLICT (content): shared.txt' },
  // No SCAN/PUSH entries: if the machinery advanced past the conflict it would
  // consume an unexpected entry and desync — guarding that the escalation
  // halts the item at the rebase boundary.
);
happyWorker('item-rb');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-rb', branch: 'build/item-rb', title: 'Rebase Conflict Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'rebase-conflict')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 9c: DIRTY_WORKTREE → dirty-worktree escalation (temperloop#735)
# The finished-worker case: pr.sh reports base == tip (no rebase was needed)
# and a tracked file left uncommitted. That is NOT a conflict, so it must NOT
# escalate as rebase-conflict — whose discard-and-respawn disposition would
# throw the finished work away. It gets its own kind, and the payload keeps the
# base==tip / dirty_paths evidence so the disposition can be 'commit and
# re-drive'. The scan/push still never run.
# ============================================================================
run_node_case "dirty-worktree: DIRTY_WORKTREE → dirty-worktree escalation (temperloop#735)" "
$PREAMBLE

setMachinery('item-dw',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-dw' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'DIRTY_WORKTREE', base: 'x', tip: 'x', rebase_needed: false,
    dirty_files: 1, dirty_paths: [' M workflows/scripts/config/setting-registry.tsv'] },
  // No SCAN/PUSH entries — same desync guard as 9b: the item must halt here.
);
happyWorker('item-dw');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-dw', branch: 'build/item-dw', title: 'Dirty Worktree Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'dirty-worktree')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if (result.escalations[0].payload?.rebaseOut?.dirty_paths?.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'dirty_paths evidence not carried into the payload' })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 10: spike kind — skip push/PR/CI, park with null pr/pushed_sha
# ============================================================================
run_node_case "spike kind: spike items park with null pr/pushed_sha (no push/PR/CI)" "
$PREAMBLE

// Spike path: worker is called directly (no machinery calls).
// machineryMap for 'spike-item' is intentionally empty — any machinery call is an error.
setMachinery('spike-item' /* empty — no calls expected */);
setWorker('spike-item',
  { status: 'done', summary: 'spike verdict produced', acceptance_results: [{ criterion: 'verdict-written', passed: true, evidence: 'v.md' }], verification_surface_path: '/tmp/verdict.md' }
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'spike-item', branch: 'build/spike-item', title: 'Spike Item', kind: 'spike', acceptance: ['verdict-written'] },
]};

const initialMachinerySize = (machineryMap.get('spike-item') || []).length;

const mod = await loadLevel();
const result = await mod.default();

if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'unexpected escalation: ' + JSON.stringify(result) })); process.exit(0); }

const sp = result.parked[0];
if (sp.pr !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'spike pr should be null: ' + sp.pr })); process.exit(0); }
if (sp.pushed_sha !== null)
  { console.log(JSON.stringify({ ok: false, reason: 'spike pushed_sha should be null: ' + sp.pushed_sha })); process.exit(0); }

// Verify no machinery calls were made for the spike item
const machineryCallsForSpike = callLog.filter(c => c.opts.schema && (c.opts.label||'').includes('spike-item'));
if (machineryCallsForSpike.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'spike made machinery calls: ' + JSON.stringify(machineryCallsForSpike.map(c=>c.opts.label)) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 10b: spike claim-first (temperloop#650) — a board-ON spike claims its
# issue (3a) BEFORE the read-only verdict fork spawns its worker. Guards the
# regression where the kind:spike branch returned via park ahead of the 3a
# claim, leaving a spike un-claimed and racing two concurrent drivers.
# ============================================================================
run_node_case "spike claim-first: 3a claim precedes the spike verdict-worker (#650)" "
$PREAMBLE

// Claim machinery call for the spike returns CLAIMED (board ON, ghIssue present).
setMachinery('spike-claim', { outcome: 'CLAIMED' });
setWorker('spike-claim',
  { status: 'done', summary: 'spike verdict produced', acceptance_results: [{ criterion: 'verdict-written', passed: true, evidence: 'v.md' }], verification_surface_path: '/tmp/verdict.md' }
);

globalThis.args = { ...baseArgs, board: 3, claimCmd: '/fake/claim.sh', items: [
  { slug: 'spike-claim', branch: 'build/spike-claim', title: 'Spike Claim', kind: 'spike', ghIssue: '650', acceptance: ['verdict-written'] },
]};

const mod = await loadLevel();
const result = await mod.default();

// Parks (spike verdict), no escalation.
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'unexpected escalation: ' + JSON.stringify(result) })); process.exit(0); }

// Ordering assertion: the claim MUST run before the worker. The claim now rides
// the batched prelude executor (temperloop#942), so assert on the prelude call
// and on the step the mock actually ran inside it.
const claimIdx = callLog.findIndex(c => (c.opts.label||'') === 'prelude:spike-claim');
const workerIdx = callLog.findIndex(c => (c.opts.label||'') === 'worker:spike-claim');
if (claimIdx === -1)
  { console.log(JSON.stringify({ ok: false, reason: 'no prelude (claim) call for spike: ' + JSON.stringify(callLog.map(c=>c.opts.label)) })); process.exit(0); }
if (workerIdx === -1)
  { console.log(JSON.stringify({ ok: false, reason: 'no worker call for spike: ' + JSON.stringify(callLog.map(c=>c.opts.label)) })); process.exit(0); }
if (!(claimIdx < workerIdx))
  { console.log(JSON.stringify({ ok: false, reason: 'claim did not precede worker: claimIdx=' + claimIdx + ' workerIdx=' + workerIdx })); process.exit(0); }
// A SPIKE's prelude is the claim ALONE — it must never create a worktree.
if (JSON.stringify(stepsRun('spike-claim')) !== JSON.stringify(['claim']))
  { console.log(JSON.stringify({ ok: false, reason: 'spike prelude steps wrong (expected [claim]): ' + JSON.stringify(stepsRun('spike-claim')) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11: gate-fail → acceptance-gate-failed escalation
# ============================================================================
run_node_case "gate-fail: GATE_FAIL → acceptance-gate-failed escalation" "
$PREAMBLE

setMachinery('item-gate',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-gate' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_FAIL', detail: 'mypy found type errors' },
);
happyWorker('item-gate');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gate', branch: 'build/item-gate', title: 'Gate Fail Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'acceptance-gate-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11b: gate-timeout — 3e.5 gate executor prompt carries the long Bash-tool
#           timeout directive (temperloop#115). Without it the executor's Bash
#           tool defaults to 120s and SIGTERMs a >2min quality-gates suite →
#           false GATE_FAIL on every drive. The prompt directive is the fix; a
#           happy item must still park green (the directive doesn't disrupt flow).
# ============================================================================
run_node_case "gate-timeout: 3e.5 gate prompt carries the Bash-timeout directive (#115)" "
$PREAMBLE

happyMachinery('item-gto', 115, 'sha-gto');
happyWorker('item-gto');

// Wrap the mock agent to capture the FULL gate prompt (the shared callLog slices
// to 120 chars, which truncates before the directive; mirror the continuation
// case's full-prompt capture). Delegate every call to the original mock so machinery
// routing (GATE_PASS from happyMachinery) is unchanged.
let gatePromptSeen = null;
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts = {}) {
  if ((opts.label || '').startsWith('gate:item-gto')) gatePromptSeen = String(prompt);
  return origAgent(prompt, opts);
};

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gto', branch: 'build/item-gto', title: 'Gate Timeout Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

// Happy path: the gate passed, so the item parks with no escalation — proof the
// timeout directive is additive and does not perturb the normal gate flow.
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 escalations: ' + JSON.stringify(result) })); process.exit(0); }

// The core regression: the gate executor prompt MUST carry the long Bash-tool
// timeout (temperloop#115) — both the numeric value and the 'timeout' framing.
// The VALUE is now DERIVED from the slice budget (temperloop#1021), not typed:
// the default 300s slice + 240s single-gate overrun headroom = 540000ms, still
// under the agent's 600000ms Bash cap.
if (!gatePromptSeen)
  { console.log(JSON.stringify({ ok: false, reason: 'gate agent call never observed' })); process.exit(0); }
if (!gatePromptSeen.includes('540000'))
  { console.log(JSON.stringify({ ok: false, reason: 'gate prompt missing the derived 540000 Bash timeout: ' + gatePromptSeen })); process.exit(0); }
if (!/timeout/i.test(gatePromptSeen))
  { console.log(JSON.stringify({ ok: false, reason: 'gate prompt missing timeout directive: ' + gatePromptSeen })); process.exit(0); }
// temperloop#1021: the prompt must ALSO name GATE_TIMEOUT as the answer when the
// Bash tool's timeout fires. Without it the executor picks the nearest
// failure-shaped enum member — GATE_FAIL — and a GREEN suite escalates as
// broken. That conflation is the dangerous half of #1021, not the wasted time.
if (!gatePromptSeen.includes('GATE_TIMEOUT'))
  { console.log(JSON.stringify({ ok: false, reason: '#1021: gate prompt does not name GATE_TIMEOUT for the Bash-timeout case: ' + gatePromptSeen })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11c: gate-worktree — the 3e.5 acceptance gate must run the WORKTREE's copy
#           of quality-gates.sh, not repoRoot's (temperloop#626). quality-gates.sh
#           begins by cd'ing to its own REPO_ROOT (BASH_SOURCE/..); if the gate
#           ran repoRoot's copy, that cd would jump back to the MAIN checkout and
#           validate main's tree instead of the worker's changes — silently
#           defeating the intended `cd \$wt`. Resolving the script from the
#           worktree makes REPO_ROOT the worktree, so the gate validates the
#           worker's tree (matching CI on the PR's merge). Regression assert: the
#           gate command names the worktree's quality-gates.sh and NEVER the bare
#           repoRoot copy.
# ============================================================================
run_node_case "gate-worktree: 3e.5 gate runs the worktree's quality-gates.sh, not repoRoot's (#626)" "
$PREAMBLE

happyMachinery('item-qgwt', 626, 'sha-qgwt');
happyWorker('item-qgwt');

// Capture the FULL gate prompt (the shared callLog truncates to 120 chars,
// which cuts off the script path; mirror 11b's full-prompt capture). Delegate
// to the original mock so machinery routing (GATE_PASS from happyMachinery) is intact.
let gatePromptSeen = null;
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts = {}) {
  if ((opts.label || '').startsWith('gate:item-qgwt')) gatePromptSeen = String(prompt);
  return origAgent(prompt, opts);
};

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-qgwt', branch: 'build/item-qgwt', title: 'Gate Worktree Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

// Happy path: the gate passed, so the item parks with no escalation — the
// worktree-copy resolution must not perturb the normal gate flow.
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 escalations: ' + JSON.stringify(result) })); process.exit(0); }

if (!gatePromptSeen)
  { console.log(JSON.stringify({ ok: false, reason: 'gate agent call never observed' })); process.exit(0); }

// The mock repoRoot is '/tmp/repo'; the worktree (happyMachinery CREATED.path) is
// '/tmp/repo.wt/item-qgwt'. These two script paths are cleanly distinguishable
// (the char after '/tmp/repo' is '/' vs '.'), so the buggy repoRoot copy is not
// a substring of the correct worktree copy.
const repoRootQg = '/tmp/repo/scripts/quality-gates.sh';
const worktreeQg = '/tmp/repo.wt/item-qgwt/scripts/quality-gates.sh';

// CORE regression: the gate must invoke the worktree's copy…
if (!gatePromptSeen.includes(worktreeQg))
  { console.log(JSON.stringify({ ok: false, reason: 'gate does not run the worktree quality-gates.sh (' + worktreeQg + '): ' + gatePromptSeen })); process.exit(0); }
// …and must NEVER reference the bare repoRoot copy (whose cd \$REPO_ROOT would
// jump back to main and defeat the worktree validation).
if (gatePromptSeen.includes(repoRootQg))
  { console.log(JSON.stringify({ ok: false, reason: 'gate still references repoRoot quality-gates.sh (' + repoRootQg + '), which validates main not the worktree: ' + gatePromptSeen })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11d (temperloop#1021): a gate TIMEOUT is NOT a gate FAILURE.
#   The dangerous half of #1021: a budget-exhausted 3e.5 run and a genuinely red
#   suite both collapsed to {"outcome":"GATE_FAIL"} → `acceptance-gate-failed`,
#   so an escalation payload could not be told apart from real breakage. A
#   GATE_TIMEOUT must escalate under its OWN kind, with a payload that says the
#   suite's verdict is UNKNOWN rather than implying the tree is broken.
# ============================================================================
run_node_case "1021 timeout: GATE_TIMEOUT → acceptance-gate-timeout (NOT acceptance-gate-failed)" "
$PREAMBLE

setMachinery('item-gt1021',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-gt1021' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_TIMEOUT' },
);
happyWorker('item-gt1021');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gt1021', branch: 'build/item-gt1021', title: 'Gate Timeout', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
const esc = result.escalations[0];
if (esc.kind !== 'acceptance-gate-timeout')
  { console.log(JSON.stringify({ ok: false, reason: 'timeout escalated as \'' + esc.kind + '\', not acceptance-gate-timeout' })); process.exit(0); }
// The payload must SAY it is a budget fact, so a reader (human or router) never
// has to infer 'green suite vs broken tree' from the kind alone.
if (!/BUDGET/.test(esc.payload?.reason ?? ''))
  { console.log(JSON.stringify({ ok: false, reason: 'timeout payload does not name the budget cause: ' + JSON.stringify(esc.payload) })); process.exit(0); }
// And it must NOT push a branch on an unknown verdict.
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 0 parked: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11e (temperloop#1021): the SLICE loop — a suite too big for one budget
#   still passes the gate. GATE_SLICE resumes at the reported index and the item
#   parks green. This is what makes 'the budget decayed again' structurally
#   impossible: total suite runtime is no longer bounded by one Bash invocation.
# ============================================================================
run_node_case "1021 slice: GATE_SLICE → resume → GATE_PASS parks green" "
$PREAMBLE

setMachinery('item-gs1021',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-gs1021' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_SLICE', resumeAt: 47, failed: 0, elapsedSecs: 301 },
  { outcome: 'GATE_PASS', failed: 0, elapsedSecs: 120 },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-gs' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-gs', branch: 'build/item-gs1021' },
  { outcome: 'PR_OPENED', pr_number: 1021 },
  { outcome: 'CI_GREEN' },
);
happyWorker('item-gs1021');

const gatePrompts = [];
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts = {}) {
  if ((opts.label || '').startsWith('gate:item-gs1021')) gatePrompts.push(String(prompt));
  return origAgent(prompt, opts);
};

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gs1021', branch: 'build/item-gs1021', title: 'Gate Slice', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'unexpected escalation: ' + JSON.stringify(result) })); process.exit(0); }
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked: ' + JSON.stringify(result) })); process.exit(0); }
if (gatePrompts.length !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 2 gate slices, saw ' + gatePrompts.length })); process.exit(0); }
// Slice 1 starts at 0 and TRUNCATES the log; slice 2 resumes at the reported
// index and APPENDS, so /tmp/qg-<slug>.log carries the union of both slices.
if (!gatePrompts[0].includes('QUALITY_GATES_START_AT=0'))
  { console.log(JSON.stringify({ ok: false, reason: 'slice 1 does not start at 0: ' + gatePrompts[0] })); process.exit(0); }
if (!gatePrompts[1].includes('QUALITY_GATES_START_AT=47'))
  { console.log(JSON.stringify({ ok: false, reason: 'slice 2 does not resume at the reported index 47: ' + gatePrompts[1] })); process.exit(0); }
if (!gatePrompts[0].includes('>/tmp/qg-item-gs1021.log') || gatePrompts[0].includes('>>/tmp/qg-item-gs1021.log'))
  { console.log(JSON.stringify({ ok: false, reason: 'slice 1 must TRUNCATE the gate log: ' + gatePrompts[0] })); process.exit(0); }
if (!gatePrompts[1].includes('>>/tmp/qg-item-gs1021.log'))
  { console.log(JSON.stringify({ ok: false, reason: 'slice 2 must APPEND to the gate log: ' + gatePrompts[1] })); process.exit(0); }
// The budget must reach the script as an ENV VAR (an older vendored
// quality-gates.sh ignores an unknown env var and runs the whole suite; an
// unknown FLAG would exit 2 and read back as a gate failure).
if (!gatePrompts[0].includes('QUALITY_GATES_BUDGET_SECS=300'))
  { console.log(JSON.stringify({ ok: false, reason: 'slice does not carry the budget env var: ' + gatePrompts[0] })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11f (temperloop#1021): a failure found in slice 1 is NOT lost when a
#   later slice finishes green. Slicing must preserve quality-gates.sh's
#   collect-all-failures property — otherwise the fix would silently WEAKEN the
#   gate, which acceptance criterion 5 forbids.
# ============================================================================
run_node_case "1021 slice: a failure in an early slice still escalates acceptance-gate-failed" "
$PREAMBLE

setMachinery('item-gsf1021',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-gsf1021' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_SLICE', resumeAt: 12, failed: 1, elapsedSecs: 300 },
  { outcome: 'GATE_PASS', failed: 0, elapsedSecs: 60 },
);
happyWorker('item-gsf1021');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gsf1021', branch: 'build/item-gsf1021', title: 'Gate Slice Fail', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'acceptance-gate-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'early-slice failure escalated as \'' + result.escalations[0].kind + '\', not acceptance-gate-failed' })); process.exit(0); }
if ((result.parked ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'a red suite must never park/push: ' + JSON.stringify(result) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11g (temperloop#1021): the slice loop is BOUNDED. A suite that never
#   finishes escalates as a TIMEOUT (honestly named) rather than looping
#   forever — and still never as a gate failure.
# ============================================================================
run_node_case "1021 slice: exhausting the slice cap escalates acceptance-gate-timeout, not -failed" "
$PREAMBLE

const slices = [];
for (let i = 0; i < 30; i++) slices.push({ outcome: 'GATE_SLICE', resumeAt: i + 1, failed: 0, elapsedSecs: 300 });
setMachinery('item-gsc1021',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-gsc1021' },
  { outcome: 'REVIEW_DIFF' },
  ...slices,
);
happyWorker('item-gsc1021');

const gateCalls = [];
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts = {}) {
  if ((opts.label || '').startsWith('gate:item-gsc1021')) gateCalls.push(1);
  return origAgent(prompt, opts);
};

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-gsc1021', branch: 'build/item-gsc1021', title: 'Gate Slice Cap', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1 || result.escalations[0].kind !== 'acceptance-gate-timeout')
  { console.log(JSON.stringify({ ok: false, reason: 'expected one acceptance-gate-timeout: ' + JSON.stringify(result) })); process.exit(0); }
if (gateCalls.length !== 8)
  { console.log(JSON.stringify({ ok: false, reason: 'slice loop is not bounded at 8: ran ' + gateCalls.length })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11h (temperloop#1021): the gate budget is a NAMED SETTING handed in via
#   the Step-0 seam (input.gateSliceSecs), not a literal in this file — and it
#   is CLAMPED so no operator value can push the derived Bash-tool timeout past
#   the agent's hard 600000ms cap (which would trade a legible timeout for an
#   opaque agent death).
# ============================================================================
run_node_case "1021 setting: input.gateSliceSecs drives the budget and is clamped to the agent Bash cap" "
$PREAMBLE

async function budgetAndTimeoutFor(sliceSecs, slug) {
  happyMachinery(slug, 1, 'sha-' + slug);
  happyWorker(slug);
  let seen = null;
  const origAgent = globalThis.agent;
  globalThis.agent = async function(prompt, opts = {}) {
    if ((opts.label || '').startsWith('gate:' + slug)) seen = String(prompt);
    return origAgent(prompt, opts);
  };
  globalThis.args = { ...baseArgs, gateSliceSecs: sliceSecs, items: [
    { slug, branch: 'build/' + slug, title: 'x', kind: 'impl', acceptance: ['c'] },
  ]};
  const mod = await loadLevel();
  await mod.default();
  globalThis.agent = origAgent;
  const budget = (seen.match(/QUALITY_GATES_BUDGET_SECS=(\\d+)/) || [])[1];
  const timeout = (seen.match(/\`timeout\` parameter to (\\d+)/) || [])[1];
  return { budget: Number(budget), timeout: Number(timeout) };
}

// An explicit setting is honored end to end.
const a = await budgetAndTimeoutFor(120, 'setting-a');
if (a.budget !== 120 || a.timeout !== 120 * 1000 + 240000)
  { console.log(JSON.stringify({ ok: false, reason: 'setting not honored: ' + JSON.stringify(a) })); process.exit(0); }

// An absurdly large setting is CLAMPED — the derived Bash-tool timeout must
// never exceed AGENT_BASH_CAP_MS (600000).
const b = await budgetAndTimeoutFor(99999, 'setting-b');
if (b.timeout > 600000)
  { console.log(JSON.stringify({ ok: false, reason: 'clamp failed — derived Bash timeout ' + b.timeout + ' exceeds the 600000ms agent cap' })); process.exit(0); }

// Unset/empty falls back to the in-file default, so an un-updated caller works.
const c = await budgetAndTimeoutFor('', 'setting-c');
if (c.budget !== 300)
  { console.log(JSON.stringify({ ok: false, reason: 'empty setting did not fall back to the in-file default: ' + JSON.stringify(c) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11i (temperloop#1587): the escalation's KIND and its PAYLOAD must agree,
#   in every one of the four gate outcomes. #1587 shipped
#   {gateOut:{outcome:'GATE_PASS',failed:0,…}, failedGates:1} under
#   kind=acceptance-gate-failed: two independent counters, one saying the gate
#   passed and one saying it failed, so a consumer trusting either acted on a
#   fiction. This case drives GATE_PASS / GATE_FAIL / GATE_SLICE(cap) /
#   GATE_TIMEOUT in one level and asserts the SAME structural invariants on
#   every gate escalation it produces.
# ============================================================================
run_node_case "1587 agreement: kind and payload agree across GATE_PASS/FAIL/SLICE/TIMEOUT" "
$PREAMBLE

// GATE_PASS — the green arm: parks, no escalation at all.
happyMachinery('g1587-pass', 1587, 'sha-pass');
happyWorker('g1587-pass');

// GATE_FAIL — note failed:0 in the executor's own line (a stale/absent
// QUALITY_GATES_FAILED= trailer). A RED suite reporting ZERO failures is the
// MIRROR image of #1587's contradiction, so the payload must floor it at 1.
setMachinery('g1587-fail',
  { outcome: 'CREATED', path: '/tmp/repo.wt/g1587-fail' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_FAIL', failed: 0, elapsedSecs: 42 },
);
happyWorker('g1587-fail');

// GATE_SLICE — the cap-exhaustion arm, every slice green.
const capSlices = [];
for (let i = 0; i < 30; i++) capSlices.push({ outcome: 'GATE_SLICE', resumeAt: i + 1, failed: 0, elapsedSecs: 300 });
setMachinery('g1587-slice',
  { outcome: 'CREATED', path: '/tmp/repo.wt/g1587-slice' },
  { outcome: 'REVIEW_DIFF' },
  ...capSlices,
);
happyWorker('g1587-slice');

// GATE_TIMEOUT — the arm that fires on this repo today (temperloop#1663): the
// suite cannot finish inside the executor's Bash ceiling.
setMachinery('g1587-timeout',
  { outcome: 'CREATED', path: '/tmp/repo.wt/g1587-timeout' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_TIMEOUT' },
);
happyWorker('g1587-timeout');

globalThis.args = { ...baseArgs, items: [
  { slug: 'g1587-pass', branch: 'build/g1587-pass', title: 'Pass', kind: 'impl', acceptance: ['c'] },
  { slug: 'g1587-fail', branch: 'build/g1587-fail', title: 'Fail', kind: 'impl', acceptance: ['c'] },
  { slug: 'g1587-slice', branch: 'build/g1587-slice', title: 'Slice', kind: 'impl', acceptance: ['c'] },
  { slug: 'g1587-timeout', branch: 'build/g1587-timeout', title: 'Timeout', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
const bad = (why) => { console.log(JSON.stringify({ ok: false, reason: why })); process.exit(0); };

const escalations = result.escalations ?? [];
const parked = result.parked ?? [];
const by = {};
for (const e of escalations) by[e.slug] = e;

// GATE_PASS: green all the way through — the reconciliation must not perturb it.
if (parked.length !== 1 || parked[0].slug !== 'g1587-pass')
  bad('GATE_PASS arm did not park cleanly: ' + JSON.stringify(result));
if (by['g1587-pass']) bad('GATE_PASS escalated: ' + JSON.stringify(by['g1587-pass']));
if (escalations.length !== 3) bad('expected 3 gate escalations: ' + JSON.stringify(escalations));

// --- The structural invariants, asserted on EVERY gate escalation ----------
for (const e of escalations) {
  const p = e.payload || {};
  // (1) ONE failure counter. The embedded raw gate object — whose own
  //     'failed' was #1587's contradicting field — must be gone, and no bare
  //     top-level 'failed' peer may replace it.
  if ('gateOut' in p) bad(e.slug + ': payload still embeds the raw gateOut (its .failed is the second counter #1587 filed): ' + JSON.stringify(p));
  if ('failed' in p) bad(e.slug + ': payload carries a bare top-level failed counter beside failedGates: ' + JSON.stringify(p));
  // (2) failedGates DERIVES from the ledger — it cannot disagree with it.
  const ledger = p.sliceLedger || [];
  const sum = ledger.reduce((n, s) => n + (Number(s.failed) || 0), 0);
  if (sum !== p.failedGates) bad(e.slug + ': failedGates ' + p.failedGates + ' disagrees with its own ledger sum ' + sum);
  if (p.slices !== ledger.length) bad(e.slug + ': slices ' + p.slices + ' disagrees with the ledger it ships (' + ledger.length + ')');
  // (3) The KIND is exactly the verdict, both ways.
  if (e.kind === 'acceptance-gate-failed' && p.verdict !== 'RED')
    bad(e.slug + ': escalated FAILED with verdict ' + p.verdict);
  if (e.kind === 'acceptance-gate-timeout' && p.verdict !== 'UNKNOWN')
    bad(e.slug + ': escalated TIMEOUT with verdict ' + p.verdict);
  if (p.verdict === 'RED' && p.failedGates < 1)
    bad(e.slug + ': verdict RED with ' + p.failedGates + ' failed gates — a failure with no failures');
  if (p.verdict === 'UNKNOWN' && p.failedGates !== 0)
    bad(e.slug + ': verdict UNKNOWN while ' + p.failedGates + ' gate(s) are known to have failed');
  if (p.verdict === 'GREEN') bad(e.slug + ': escalated at all on a GREEN verdict: ' + JSON.stringify(p));
  // (4) The REASON prose agrees with the verdict it accompanies.
  const reason = String(p.reason || '');
  if (!reason) bad(e.slug + ': payload carries no reason');
  if (p.verdict === 'UNKNOWN' && !/unknown/i.test(reason))
    bad(e.slug + ': UNKNOWN verdict whose reason never says the verdict is unknown: ' + reason);
  if (p.verdict === 'RED' && /NOT a gate failure/.test(reason))
    bad(e.slug + ': RED verdict whose reason denies a gate failed: ' + reason);
}

// GATE_FAIL: RED, and floored at one failure despite the executor's failed:0.
const f = by['g1587-fail'];
if (!f || f.kind !== 'acceptance-gate-failed') bad('GATE_FAIL did not escalate acceptance-gate-failed: ' + JSON.stringify(f));
if (f.payload.failedGates !== 1) bad('GATE_FAIL with an unparseable count must floor at 1, got ' + f.payload.failedGates);

// GATE_SLICE (cap): UNKNOWN, named as a BUDGET fact, and the slice count is the
// ledger's own length — not the loop index, which ran one PAST the last slice.
const s = by['g1587-slice'];
if (!s || s.kind !== 'acceptance-gate-timeout') bad('slice-cap did not escalate acceptance-gate-timeout: ' + JSON.stringify(s));
if (!/BUDGET/.test(s.payload.reason)) bad('slice-cap reason does not name the budget cause: ' + s.payload.reason);
if (s.payload.slices !== 8) bad('slice-cap must report the 8 slices it actually ran, got ' + s.payload.slices);

// GATE_TIMEOUT: UNKNOWN, and still clearly NOT a gate failure (temperloop#1021).
const t = by['g1587-timeout'];
if (!t || t.kind !== 'acceptance-gate-timeout') bad('GATE_TIMEOUT did not escalate acceptance-gate-timeout: ' + JSON.stringify(t));
if (t.payload.verdict !== 'UNKNOWN') bad('GATE_TIMEOUT verdict is not UNKNOWN: ' + JSON.stringify(t.payload));
if (!/NOT a gate failure/.test(t.payload.reason)) bad('GATE_TIMEOUT reason no longer distinguishes itself from a real failure: ' + t.payload.reason);
if (t.payload.failedGates !== 0) bad('GATE_TIMEOUT invented a failure count: ' + JSON.stringify(t.payload));

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11j (temperloop#1587): the EXACT observed payload — a failure in an early
#   slice followed by a green FINAL slice. Pre-fix this shipped
#   failedGates:1 alongside gateOut:{outcome:'GATE_PASS',failed:0}, and the
#   operator who read the log's closing 'OK — gates 96..162 passed (final
#   slice)' line concluded the escalation was a false positive. The escalation
#   is correct; its payload has to SAY so.
# ============================================================================
run_node_case "1587 observed: an early-slice failure + green final slice ships ONE self-consistent payload" "
$PREAMBLE

setMachinery('g1587-obs',
  { outcome: 'CREATED', path: '/tmp/repo.wt/g1587-obs' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_SLICE', resumeAt: 96, failed: 1, elapsedSecs: 300 },
  { outcome: 'GATE_PASS', failed: 0, elapsedSecs: 241 },
);
happyWorker('g1587-obs');

globalThis.args = { ...baseArgs, items: [
  { slug: 'g1587-obs', branch: 'build/g1587-obs', title: 'Observed', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
const bad = (why) => { console.log(JSON.stringify({ ok: false, reason: why })); process.exit(0); };

if ((result.escalations ?? []).length !== 1) bad('expected 1 escalation: ' + JSON.stringify(result));
const e = result.escalations[0];
const p = e.payload || {};
if (e.kind !== 'acceptance-gate-failed') bad('kind wrong: ' + e.kind);
if ((result.parked ?? []).length !== 0) bad('a red suite must never park/push: ' + JSON.stringify(result));

// The contradiction itself: NO field in this payload may read as 'the gate passed'.
if ('gateOut' in p) bad('the GATE_PASS payload object is still embedded: ' + JSON.stringify(p));
if (p.verdict !== 'RED') bad('verdict is not RED: ' + JSON.stringify(p));
if (p.failedGates !== 1) bad('failedGates is not 1: ' + JSON.stringify(p));
if (JSON.stringify(p.failedInSlices) !== '[1]') bad('failedInSlices does not name slice 1: ' + JSON.stringify(p));
if (p.suiteFinished !== true) bad('the suite DID finish (final slice GATE_PASS); suiteFinished says otherwise: ' + JSON.stringify(p));

// The terminal slice's own outcome is still reported — but SCOPED as a slice
// fact under 'outcome', never as the suite's verdict.
if (p.outcome !== 'GATE_PASS') bad('the terminal slice outcome is no longer reported: ' + JSON.stringify(p));
if (!/FINAL slice/.test(String(p.reason))) bad('the reason does not explain the green final slice: ' + p.reason);
if (!/RED/.test(String(p.reason))) bad('the reason does not state the suite is RED: ' + p.reason);

// The ledger is the single record both numbers come from.
if ((p.sliceLedger || []).length !== 2) bad('ledger does not carry both slices: ' + JSON.stringify(p.sliceLedger));
if (p.sliceLedger[0].failed !== 1 || p.sliceLedger[0].outcome !== 'GATE_SLICE') bad('slice 1 ledger entry wrong: ' + JSON.stringify(p.sliceLedger));
if (p.sliceLedger[1].failed !== 0 || p.sliceLedger[1].outcome !== 'GATE_PASS') bad('slice 2 ledger entry wrong: ' + JSON.stringify(p.sliceLedger));
if (p.sliceLedger[1].startAt !== 96) bad('slice 2 did not record its resume index: ' + JSON.stringify(p.sliceLedger));

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11k (temperloop#1587 + #1021): a TIMEOUT must never LAUNDER an observed
#   failure into an unknown. A slice that failed, followed by a slice the Bash
#   ceiling killed, is a KNOWN-red branch — so it escalates as a failure, and
#   its reason still names the unfinished remainder. The mirror (a timeout with
#   nothing failed) stays acceptance-gate-timeout — asserted in 11i, and that
#   is the case #1663 hits on this repo today.
# ============================================================================
run_node_case "1587 honesty: an observed failure + a killed later slice is RED, and says both halves" "
$PREAMBLE

setMachinery('g1587-mix',
  { outcome: 'CREATED', path: '/tmp/repo.wt/g1587-mix' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_SLICE', resumeAt: 40, failed: 2, elapsedSecs: 300 },
  { outcome: 'GATE_TIMEOUT' },
);
happyWorker('g1587-mix');

globalThis.args = { ...baseArgs, items: [
  { slug: 'g1587-mix', branch: 'build/g1587-mix', title: 'Mixed', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
const bad = (why) => { console.log(JSON.stringify({ ok: false, reason: why })); process.exit(0); };

if ((result.escalations ?? []).length !== 1) bad('expected 1 escalation: ' + JSON.stringify(result));
const e = result.escalations[0];
const p = e.payload || {};
if (e.kind !== 'acceptance-gate-failed') bad('an observed failure must dominate the unfinished remainder, got kind ' + e.kind);
if (p.verdict !== 'RED') bad('verdict is not RED: ' + JSON.stringify(p));
if (p.failedGates !== 2) bad('the observed failures were lost or double-counted: ' + JSON.stringify(p));
if (p.suiteFinished !== false) bad('the suite did NOT finish; suiteFinished says otherwise: ' + JSON.stringify(p));
// Both halves, in the same sentence: the failures are real AND the rest has no verdict.
if (!/BUDGET/.test(String(p.reason))) bad('the reason drops the unfinished half: ' + p.reason);
if (!/known-RED/.test(String(p.reason))) bad('the reason drops the known-failure half: ' + p.reason);
// The killed slice establishes nothing, so it contributes NO count of its own.
if (p.sliceLedger[1].outcome !== 'GATE_TIMEOUT' || p.sliceLedger[1].failed !== 0)
  bad('a killed slice must contribute 0, not a guess: ' + JSON.stringify(p.sliceLedger));

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 12: worktree-failed — worktree.sh returns non-CREATED → worktree-failed escalation
# ============================================================================
run_node_case "worktree-failed: worktree.sh non-CREATED → worktree-failed escalation" "
$PREAMBLE

setMachinery('item-wt',
  { outcome: 'ERROR', error: 'repo root is not top-level' }
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-wt', branch: 'build/item-wt', title: 'Worktree Fail Item', kind: 'impl' },
]};

const mod = await loadLevel();
const result = await mod.default();

if ((result.escalations ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.escalations[0].kind !== 'worktree-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'escalation kind wrong: ' + result.escalations[0].kind })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 13: 2-level e2e smoke — buildLevel() is stateless; two sequential
# calls each produce independent {parked, escalations}. The second call
# picks up globalThis.args for level-2 items.
# ============================================================================
run_node_case "2-level e2e smoke: two buildLevel() calls, each independent and stateless" "
$PREAMBLE

// Level 1: 2 green items
happyMachinery('l1a', 701, 'sha-l1a');
happyMachinery('l1b', 702, 'sha-l1b');
happyWorker('l1a');
happyWorker('l1b');

// Level 2: 2 green items (different slugs)
happyMachinery('l2a', 703, 'sha-l2a');
happyMachinery('l2b', 704, 'sha-l2b');
happyWorker('l2a');
happyWorker('l2b');

const mod = await loadLevel();

// --- Level 1 ---
globalThis.args = { ...baseArgs, items: [
  { slug: 'l1a', branch: 'build/l1a', title: 'L1 A', kind: 'impl' },
  { slug: 'l1b', branch: 'build/l1b', title: 'L1 B', kind: 'impl' },
]};
const r1 = await mod.default();

if ((r1.parked ?? []).length !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'L1 expected 2 parked: ' + JSON.stringify(r1) })); process.exit(0); }
if ((r1.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'L1 unexpected escalation: ' + JSON.stringify(r1) })); process.exit(0); }

// --- Level 2 ---
globalThis.args = { ...baseArgs, items: [
  { slug: 'l2a', branch: 'build/l2a', title: 'L2 A', kind: 'impl' },
  { slug: 'l2b', branch: 'build/l2b', title: 'L2 B', kind: 'impl' },
]};
const r2 = await mod.default();

if ((r2.parked ?? []).length !== 2)
  { console.log(JSON.stringify({ ok: false, reason: 'L2 expected 2 parked: ' + JSON.stringify(r2) })); process.exit(0); }
if ((r2.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'L2 unexpected escalation: ' + JSON.stringify(r2) })); process.exit(0); }

// The two parked sets are disjoint (no slug collision)
const allSlugs = [...r1.parked, ...r2.parked].map(p => p.slug);
const uniqueSlugs = new Set(allSlugs);
if (uniqueSlugs.size !== 4)
  { console.log(JSON.stringify({ ok: false, reason: 'slug collision between levels: ' + JSON.stringify(allSlugs) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 13.5: dep-merge precondition gate (#108) — a level's worktree is created
# only after every depends-on target has MERGED to origin/<default>.
#
# Root cause of #108 is level ORDERING: a dependent item's worker must build and
# self-verify against MERGED dependency code, not a pre-merge base. driveItem's
# 3b-0 gate runs `worktree.sh deps-merged` BEFORE `worktree.sh create` whenever
# item.dependsOn carries SHAs. This test drives ONE level with two independent
# dependent items:
#   - l2ok:      deps-merged → DEPS_MERGED → worktree created, item parks [m].
#   - l2blocked: deps-merged → DEPS_UNMERGED → item escalates 'dep-not-merged'
#                with NO worktree create and NO worker spawned (nothing is built
#                against a stale/pre-merge base). Its sibling still parks.
# ============================================================================
run_node_case "dep-merge gate (#108): DEPS_UNMERGED blocks worktree create + worker; DEPS_MERGED proceeds; sibling parks" "
$PREAMBLE

// l2ok: dep gate passes, then the normal green machinery sequence.
setMachinery('l2ok',
  { outcome: 'DEPS_MERGED' },
  { outcome: 'CREATED', path: '/tmp/repo.wt/l2ok' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-l2ok' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-l2ok', branch: 'build/l2ok' },
  { outcome: 'PR_OPENED', pr_number: 811 },
  { outcome: 'CI_GREEN' },
);
happyWorker('l2ok');

// l2blocked: dep gate reports an unmerged dependency — the ONLY machinery call it
// should ever make. No CREATED registered: if the code wrongly reached
// worktree.sh create, the machinery mock would throw 'label exhausted'.
setMachinery('l2blocked', { outcome: 'DEPS_UNMERGED', unmerged: ['sha-dep-unmerged'] });

globalThis.args = { ...baseArgs, items: [
  { slug: 'l2ok',      branch: 'build/l2ok',      title: 'L2 OK',      kind: 'impl', acceptance: ['c'],
    dependsOn: [{ slug: 'l1', sha: 'sha-l1-merged' }] },
  { slug: 'l2blocked', branch: 'build/l2blocked', title: 'L2 Blocked', kind: 'impl', acceptance: ['c'],
    dependsOn: [{ slug: 'l1', sha: 'sha-l1-unmerged' }] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
const escalations = result.escalations ?? [];

// l2ok parks; l2blocked escalates.
if (parked.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
if (parked[0].slug !== 'l2ok' || parked[0].pr !== 811)
  { console.log(JSON.stringify({ ok: false, reason: 'wrong item parked: ' + JSON.stringify(parked[0]) })); process.exit(0); }
if (escalations.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].slug !== 'l2blocked' || escalations[0].kind !== 'dep-not-merged')
  { console.log(JSON.stringify({ ok: false, reason: 'wrong escalation: ' + JSON.stringify(escalations[0]) })); process.exit(0); }

// The gate is ORDERED before create and SHORT-CIRCUITS it: l2blocked must run its
// deps-merged step but NEVER the worktree-create step, and NEVER spawn a worker
// — nothing was built against the pre-merge base. Both steps now ride ONE
// prelude executor (temperloop#942), so this asserts on the steps the batch
// actually RAN rather than on per-command agent labels.
const blockedSteps = stepsRun('l2blocked');
if (JSON.stringify(blockedSteps) !== JSON.stringify(['deps-merged']))
  { console.log(JSON.stringify({ ok: false, reason: 'l2blocked must run deps-merged and STOP (no worktree create): ' + JSON.stringify(blockedSteps) })); process.exit(0); }
const blockedPrelude = callLog.filter(c => c.opts.label === 'prelude:l2blocked');
if (blockedPrelude.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected exactly 1 prelude executor for l2blocked, got ' + blockedPrelude.length })); process.exit(0); }
const blockedWorker = callLog.filter(c => c.opts.label === 'worker:l2blocked');
if (blockedWorker.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'l2blocked spawned a worker despite unmerged dep: ' + JSON.stringify(blockedWorker) })); process.exit(0); }

// And the gate runs BEFORE create for the passing item too — in ONE prelude
// executor whose steps are ordered deps-merged → worktree.
const okSteps = stepsRun('l2ok').slice(0, 2);
if (JSON.stringify(okSteps) !== JSON.stringify(['deps-merged', 'worktree']))
  { console.log(JSON.stringify({ ok: false, reason: 'gate not ordered before create for l2ok: ' + JSON.stringify(okSteps) })); process.exit(0); }
if (callLog.filter(c => c.opts.label === 'prelude:l2ok').length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'l2ok prelude must be ONE executor call, not one per command' })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 14: deploy-discovery — ~/.claude/workflows/build-level.mjs resolves
# The install-claude Makefile target symlinks claude/* into ~/.claude/.
# We verify the source file exists and the installed path resolves.
# ============================================================================
echo ""
echo "--- deploy-discovery: ~/.claude/workflows/build-level.mjs resolves ---"
INSTALL_TARGET="$HOME/.claude/workflows/build-level.mjs"
WORKFLOWS_LINK="$HOME/.claude/workflows"

if [ -f "$INSTALL_TARGET" ]; then
  echo "PASS: deploy-discovery — $INSTALL_TARGET exists and resolves"
elif [ -L "$WORKFLOWS_LINK" ] && [ -f "$WORKFLOWS_LINK/build-level.mjs" ]; then
  echo "PASS: deploy-discovery — $WORKFLOWS_LINK is a symlink dir containing build-level.mjs"
else
  # Install not yet run in this environment. Verify the source .mjs is present
  # and the Makefile's install-claude target would place it at the right path.
  # (The target symlinks claude/* → ~/.claude/*; claude/workflows/ → ~/.claude/workflows.)
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)"
  SOURCE="$REPO_ROOT/claude/workflows/build-level.mjs"
  if [ -f "$SOURCE" ]; then
    echo "PASS: deploy-discovery — source $SOURCE exists; make install-claude links claude/workflows → ~/.claude/workflows"
  else
    echo "FAIL: deploy-discovery — source .mjs not found at $SOURCE" >&2
    exit 1
  fi
fi

# ============================================================================
# TEST 15: continuation (3d-esc escalation-resume) — onlySlugs + verdicts
# Given args.onlySlugs=[slug] + args.verdicts[slug].verdict_section, the
# re-spawned worker prompt CONTAINS the injected verdict block, the existing
# worktree is REUSED (NO worktree.sh create force-recreate, NO claim re-run),
# and the item drives to parked. Siblings NOT in onlySlugs are left untouched.
# ============================================================================
run_node_case "continuation: onlySlugs+verdicts → verdict injected, worktree reused, no re-claim" "
$PREAMBLE

// The continued item resumes at 3c (worker). Its machinery sequence therefore has
// NO 'CREATED' (worktree create is skipped) and NO claim — it begins at the
// gate (3e.5). If driveItem wrongly ran worktree.sh create or claim.sh, it
// would consume an extra machinery entry here and the outcome would desync.
setMachinery('item-cont',
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-cont' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-cont', branch: 'build/item-cont' },
  { outcome: 'PR_OPENED', pr_number: 901 },
  { outcome: 'CI_GREEN' },
);
setWorker('item-cont',
  { status: 'done', summary: 'resumed with verdict', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] }
);

const VERDICT_BLOCK = '## Design verdict — item-cont\\nDecision: use option A (the seam interface).\\nRationale: keeps the contract stable.';

// Capture the worker prompt to assert the verdict block is injected, and any
// claim/worktree machinery call to assert it was skipped.
let workerPromptSeen = '';
let sawCreateOrClaim = false;
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts={}) {
  const label = opts.label || '';
  if (isWorkerCall(opts) && label.startsWith('worker:item-cont')) {
    workerPromptSeen = String(prompt);
  }
  // temperloop#942: claim + worktree create ride the batched prelude executor.
  // A continuation must emit NO prelude executor at all (both its steps are
  // skipped, so the step list is empty and runMachineryBatch spawns nothing).
  if (label.startsWith('prelude:item-cont')) {
    sawCreateOrClaim = true;
  }
  return origAgent(prompt, opts);
};

// Board ON + ghIssue would normally fire a claim; on a continuation it must be
// skipped. Full items array passed; onlySlugs selects only the continued slug.
globalThis.args = {
  ...baseArgs,
  board: 3,
  claimCmd: '/fake/claim.sh',
  items: [
    { slug: 'item-parked', branch: 'build/item-parked', title: 'Already Parked', kind: 'impl', ghIssue: 70 },
    { slug: 'item-cont',   branch: 'build/item-cont',   title: 'Continued Item', kind: 'impl', ghIssue: 71, acceptance: ['c'] },
  ],
  onlySlugs: ['item-cont'],
  verdicts: { 'item-cont': { kind: 'design-fork', verdict_section: VERDICT_BLOCK } },
};

const mod = await loadLevel();
const result = await mod.default();

// Only the continued slug is driven; the parked sibling is untouched.
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked (only continued slug): ' + JSON.stringify(result) })); process.exit(0); }
if ((result.escalations ?? []).length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'unexpected escalation: ' + JSON.stringify(result) })); process.exit(0); }
if (result.parked[0].slug !== 'item-cont')
  { console.log(JSON.stringify({ ok: false, reason: 'wrong slug driven: ' + result.parked[0].slug })); process.exit(0); }
if (result.parked[0].pushed_sha !== 'sha-cont')
  { console.log(JSON.stringify({ ok: false, reason: 'pushed_sha wrong: ' + result.parked[0].pushed_sha })); process.exit(0); }

// The verdict block must be injected into the re-spawned worker's prompt.
if (!workerPromptSeen.includes('use option A (the seam interface)'))
  { console.log(JSON.stringify({ ok: false, reason: 'verdict block NOT injected into worker prompt: ' + workerPromptSeen.slice(0,300) })); process.exit(0); }
if (!workerPromptSeen.includes('Design verdict — item-cont'))
  { console.log(JSON.stringify({ ok: false, reason: 'verdict heading missing from worker prompt' })); process.exit(0); }

// The existing worktree must be REUSED: no worktree.sh create, no claim.sh.
if (sawCreateOrClaim)
  { console.log(JSON.stringify({ ok: false, reason: 'continuation ran a prelude executor (worktree create / claim) — should reuse/skip' })); process.exit(0); }

// Belt-and-suspenders: no claim/worktree STEP ran for the continued slug — an
// empty prelude step list means runMachineryBatch spawns no executor at all.
const preludeSteps = stepsRun('item-cont').filter(k => k === 'claim' || k === 'worktree' || k === 'deps-merged');
if (preludeSteps.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'continuation ran prelude steps: ' + JSON.stringify(preludeSteps) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 16: acceptance-string — item.acceptance as a single STRING (the shape
# /sweep passes) must work, not throw on .map (#437 real-run bug).
# ============================================================================
run_node_case "acceptance-string: item.acceptance as a string → parks, no .map throw (#437)" "
$PREAMBLE
happyMachinery('strone', 201, 'shaS');
happyWorker('strone');
globalThis.args = { ...baseArgs, items: [
  { slug: 'strone', branch: 'build/strone', title: 'String acc', kind: 'impl', acceptance: '(self-verify the issue is resolved)' },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 1 || escalations.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'string acceptance: expected 1 parked / 0 esc, got ' + JSON.stringify(result) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 17: worker-throw — a THROW inside driveItem must become a worker-error
# escalation, never silently dropped to null by parallel() (#437 no-silent-stall).
# ============================================================================
run_node_case "worker-throw: a driveItem throw → worker-error escalation, not silently dropped (#437)" "
$PREAMBLE
globalThis.agent = async () => { throw new Error('boom from agent'); };
globalThis.args = { ...baseArgs, items: [
  { slug: 'boomer', branch: 'build/boomer', title: 'Throws', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'throw: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'worker-error')
  { console.log(JSON.stringify({ ok: false, reason: 'throw: expected 1 worker-error escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 18: null worker verdict — main path. agent() returns null once, auto-retry
# returns a valid done verdict → item parks successfully.
# ============================================================================
run_node_case "null-worker-retry: agent returns null once, retries, parks on second call (#542)" "
$PREAMBLE
// Machinery: normal happy path, plus the temperloop#939 recover-probe that now
// runs on the null return BEFORE the retry (RECOVER_NONE → retry exactly as before).
setMachinery('retryitem',
  { outcome: 'CREATED', path: '/tmp/repo.wt/retryitem' },
  noSideEffects(),
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-retry' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-retry', branch: 'build/retryitem' },
  { outcome: 'PR_OPENED', pr_number: 10 },
  { outcome: 'CI_GREEN' },
);
// Worker: first call null (transient API error), second call done (retry succeeds)
setWorker('retryitem',
  null,
  { status: 'done', summary: 'retry worked', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] }
);
globalThis.args = { ...baseArgs, items: [
  { slug: 'retryitem', branch: 'build/retryitem', title: 'Retry item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'null-retry: expected 1 parked, got ' + JSON.stringify({ parked, escalations }) })); process.exit(0); }
if (escalations.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'null-retry: expected 0 escalations, got ' + JSON.stringify(escalations) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 19: null worker verdict — persistent null (both calls return null) must
# escalate as worker-error, not throw a TypeError.
# Machinery must be seeded through worktree creation (3b) since that runs before 3c.
# ============================================================================
run_node_case "null-worker-persistent: agent returns null twice → worker-error escalation, no TypeError (#542)" "
$PREAMBLE
// Machinery: only worktree creation is needed; worker escalates before gate/scan/push/PR/CI
setMachinery('nullitem', { outcome: 'CREATED', path: '/tmp/repo.wt/nullitem' });
// Worker: both initial call and the one auto-retry return null
setWorker('nullitem', null, null);
globalThis.args = { ...baseArgs, items: [
  { slug: 'nullitem', branch: 'build/nullitem', title: 'Null item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'null-persistent: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'worker-error')
  { console.log(JSON.stringify({ ok: false, reason: 'null-persistent: expected 1 worker-error escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (!escalations[0].payload.retryable)
  { console.log(JSON.stringify({ ok: false, reason: 'null-persistent: expected retryable:true in payload, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 20: null spike verdict — spike worker returning null escalates as
# worker-error with retryable:true (no retry on spike path since read-only).
# ============================================================================
run_node_case "null-spike: spike agent returns null → worker-error escalation (#542)" "
$PREAMBLE
// Spike: no machinery calls (spikes skip all machinery steps); worker returns null
setWorker('spikenull', null);
globalThis.args = { ...baseArgs, items: [
  { slug: 'spikenull', branch: 'build/spikenull', title: 'Null spike', kind: 'spike', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'null-spike: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'worker-error')
  { console.log(JSON.stringify({ ok: false, reason: 'null-spike: expected 1 worker-error escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (!escalations[0].payload.retryable)
  { console.log(JSON.stringify({ ok: false, reason: 'null-spike: expected retryable:true in payload, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 21: null cifix verdict — CI-fix agent returning null escalates as
# ci-failed with retryable:true, not a TypeError.
# ============================================================================
run_node_case "null-cifix: ci-fix agent returns null → ci-failed escalation, no TypeError (#542)" "
$PREAMBLE
// Machinery: normal path up to CI_FAILED, then fix-spawn (worker) returns null
happyMachinery('cifixnull', 20, 'sha-cifix');
// Override ci-poll in machineryMap to return CI_FAILED
machineryMap.set('cifixnull', [
  { outcome: 'CREATED', path: '/tmp/repo.wt/cifixnull' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-cifix' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-cifix', branch: 'build/cifixnull' },
  { outcome: 'PR_OPENED', pr_number: 20 },
  { outcome: 'CI_FAILED', failed_run_ids: [1] },
]);
// Worker: first call (main) succeeds; second call (ci-fix re-spawn) returns null
setWorker('cifixnull',
  { status: 'done', summary: 'main done', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  null
);
// ci-fix worker label is 'worker-cifix:slug' — routes via workerMap under same slug
// but needs to handle the cifix label too; override slugFromLabel isn't possible here
// so we rely on the workerMap fallback logic (shift from same queue)
globalThis.args = { ...baseArgs, items: [
  { slug: 'cifixnull', branch: 'build/cifixnull', title: 'CI fix null', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'null-cifix: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'ci-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'null-cifix: expected 1 ci-failed escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (!escalations[0].payload.retryable)
  { console.log(JSON.stringify({ ok: false, reason: 'null-cifix: expected retryable:true in payload, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 22: CONFLICTING merge state — escalates merge-conflict on first slice,
# no full CI_POLL_TOTAL_SECS spin (#543). ci-poll.sh is never called.
# ============================================================================
run_node_case "merge-conflict: CONFLICTING PR escalates merge-conflict without spinning (#543)" "
$PREAMBLE

// Machinery through push + PR open; NO ci-poll entry (merge-check fires first, escalates)
setMachinery('item-conflict543',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-conflict543' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-cf' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-cf', branch: 'build/item-conflict543' },
  { outcome: 'PR_OPENED', pr_number: 543 },
  // No CI_GREEN/CI_FAILED/TIMEOUT entries: if ci-poll.sh fires, it consumes
  // from an exhausted machineryMap → ERROR fallback → test would see ci-failed, not
  // merge-conflict. The absence of an entry here proves ci-poll was skipped.
);
happyWorker('item-conflict543');
// Override merge-check to return CONFLICTING on the first poll slice.
setMergeCheck('item-conflict543', { mergeable: 'CONFLICTING', mergeStateStatus: 'DIRTY' });

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-conflict543', branch: 'build/item-conflict543', title: 'Conflict PR', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
const escalations = result.escalations ?? [];

if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: expected 1 escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].kind !== 'merge-conflict')
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: escalation kind wrong: ' + escalations[0].kind })); process.exit(0); }
if (escalations[0].slug !== 'item-conflict543')
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: escalation slug wrong: ' + escalations[0].slug })); process.exit(0); }
if (escalations[0].payload.mergeable !== 'CONFLICTING')
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: payload.mergeable wrong: ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
if (escalations[0].payload.pr !== 543)
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: payload.pr wrong: ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }

// Confirm ci-poll was NOT run. The merge-state probe and the poll slices share
// ONE ci-batch executor now (temperloop#942), so the assertion is on the STEPS
// the batch actually ran: the conflicting merge-state must short-circuit the
// batch before any ci-poll.sh slice burns 4 minutes.
const ciSteps = stepsRun('item-conflict543');
if (ciSteps.includes('ci-poll'))
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: ci-poll.sh ran (should be short-circuited): ' + JSON.stringify(ciSteps) })); process.exit(0); }
if (!ciSteps.includes('merge-state'))
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: merge-state probe never ran: ' + JSON.stringify(ciSteps) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 23: DIRTY merge state (MERGEABLE field absent, only mergeStateStatus=DIRTY)
# Also verifies a non-conflicting sibling parks normally (existing poll unaffected).
# ============================================================================
run_node_case "merge-conflict: mergeStateStatus=DIRTY alone escalates merge-conflict (#543)" "
$PREAMBLE

// Item that is DIRTY (mergeStateStatus only, mergeable field missing/UNKNOWN)
setMachinery('item-dirty',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-dirty' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-dirty' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-dirty', branch: 'build/item-dirty' },
  { outcome: 'PR_OPENED', pr_number: 544 },
);
happyWorker('item-dirty');
setMergeCheck('item-dirty', { mergeable: 'UNKNOWN', mergeStateStatus: 'DIRTY' });

// Clean sibling parks normally
happyMachinery('item-clean', 545, 'sha-clean');
happyWorker('item-clean');
// No setMergeCheck → default { mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN' }

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-dirty', branch: 'build/item-dirty', title: 'Dirty PR',  kind: 'impl', acceptance: ['c'] },
  { slug: 'item-clean', branch: 'build/item-clean', title: 'Clean PR', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
const escalations = result.escalations ?? [];

if (parked.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'dirty: expected 1 parked (clean sibling), got ' + JSON.stringify(parked) })); process.exit(0); }
if (parked[0].slug !== 'item-clean')
  { console.log(JSON.stringify({ ok: false, reason: 'dirty: wrong slug parked: ' + parked[0].slug })); process.exit(0); }

if (escalations.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'dirty: expected 1 escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].kind !== 'merge-conflict')
  { console.log(JSON.stringify({ ok: false, reason: 'dirty: escalation kind wrong: ' + escalations[0].kind })); process.exit(0); }
if (escalations[0].payload.mergeStateStatus !== 'DIRTY')
  { console.log(JSON.stringify({ ok: false, reason: 'dirty: payload.mergeStateStatus wrong: ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 24: EXISTS outcome — pr-open returns EXISTS → routed to CI-poll/park-with-pr
# (NOT pr-open-failed escalation). This covers the #544 "already exists" retry
# path: when gh pr create fails because a PR already exists, pr.sh returns
# {outcome:"EXISTS",pr_number,url} and build-level.mjs must adopt it.
# ============================================================================
run_node_case "pr-open EXISTS: EXISTS outcome routes to CI-poll/park-with-pr, not pr-open-failed (#544)" "
$PREAMBLE

setMachinery('item-exists',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-exists' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-exists' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-exists', branch: 'build/item-exists' },
  // EXISTS: branch already had an open PR (e.g. create retry after first create succeeded)
  { outcome: 'EXISTS', pr_number: 163, url: 'https://github.com/Towheads/foundation/pull/163' },
  { outcome: 'CI_GREEN' },
);
happyWorker('item-exists');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-exists', branch: 'build/item-exists', title: 'Existing PR Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
const escalations = result.escalations ?? [];

if (parked.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'EXISTS: expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
if (escalations.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'EXISTS: expected 0 escalations (should not pr-open-failed), got ' + JSON.stringify(escalations) })); process.exit(0); }
if (parked[0].slug !== 'item-exists')
  { console.log(JSON.stringify({ ok: false, reason: 'EXISTS: wrong slug parked: ' + parked[0].slug })); process.exit(0); }
if (parked[0].pr !== 163)
  { console.log(JSON.stringify({ ok: false, reason: 'EXISTS: pr should be 163 (from EXISTS outcome), got: ' + parked[0].pr })); process.exit(0); }
if (parked[0].pushed_sha !== 'sha-exists')
  { console.log(JSON.stringify({ ok: false, reason: 'EXISTS: pushed_sha wrong: ' + parked[0].pushed_sha })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 25: ERROR from pr-open still escalates as pr-open-failed (genuine failure)
# Ensures the EXISTS routing change does NOT swallow real ERROR outcomes.
# ============================================================================
run_node_case "pr-open ERROR: genuine pr-open failure still escalates pr-open-failed (not swallowed by #544)" "
$PREAMBLE

setMachinery('item-prfail',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-prfail' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-prfail' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-prfail', branch: 'build/item-prfail' },
  // Genuine failure (not the already-exists case) → must escalate
  { outcome: 'ERROR', error: 'authentication required' },
);
happyWorker('item-prfail');

globalThis.args = { ...baseArgs, items: [
  { slug: 'item-prfail', branch: 'build/item-prfail', title: 'PR Open Fail Item', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const parked = result.parked ?? [];
const escalations = result.escalations ?? [];

if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'pr-open-fail: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'pr-open-fail: expected 1 escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].kind !== 'pr-open-failed')
  { console.log(JSON.stringify({ ok: false, reason: 'pr-open-fail: escalation kind wrong: ' + escalations[0].kind })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 26: null machinery return at the WORKTREE step (temperloop#72). When the
# auto-mode safety classifier DENIES a machinery command, agent() returns null and
# runMachinery normalizes it to a SPINE_DENIED sentinel. driveItem must escalate a
# clean 'machinery-denied' rather than dereference wtOut.outcome and crash with
# 'null is not an object'.
# ============================================================================
run_node_case "null-machinery-worktree: worktree machinery returns null → machinery-denied escalation, no TypeError (#72)" "
$PREAMBLE
// First machinery call (worktree.sh create, board OFF) returns null (classifier denied).
setMachinery('wtdenied', null);
happyWorker('wtdenied');
globalThis.args = { ...baseArgs, items: [
  { slug: 'wtdenied', branch: 'build/wtdenied', title: 'WT denied', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-worktree: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'machinery-denied')
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-worktree: expected 1 machinery-denied escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].payload.step !== 'worktree')
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-worktree: expected payload.step=worktree, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 27: null machinery return at the PUSH step (temperloop#72). Same null-guard,
# exercised at 3f-1 push after a clean worker+gate+rebase+scan. Guards the
# second site the crash was reported at (~453/push).
#
# temperloop#942: rebase/scan/push/pr-open now ride ONE 'pr-batch' executor, and a
# classifier denial denies the WHOLE executor call — so the escalation names the
# batch plus its step list rather than a single command. The guard is the same:
# a denied machinery step must park as 'machinery-denied', never crash.
# ============================================================================
run_node_case "null-machinery-push: push machinery returns null → machinery-denied escalation, no TypeError (#72)" "
$PREAMBLE
setMachinery('pushdenied',
  { outcome: 'CREATED', path: '/tmp/repo.wt/pushdenied' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-pd' },
  { outcome: 'SCAN_CLEAN' },
  null,   // push → classifier denied
);
happyWorker('pushdenied');
globalThis.args = { ...baseArgs, items: [
  { slug: 'pushdenied', branch: 'build/pushdenied', title: 'Push denied', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-push: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'machinery-denied')
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-push: expected 1 machinery-denied escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].payload.step !== 'pr-batch')
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-push: expected payload.step=pr-batch, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
// The denial must still name WHICH steps were in flight — otherwise the operator
// cannot tell a denied push from a denied rebase.
if (!(escalations[0].payload.steps || []).includes('push'))
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-push: payload.steps must name the batched steps, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
// And the mock DID reach the push step before returning null.
if (!stepsRun('pushdenied').includes('push'))
  { console.log(JSON.stringify({ ok: false, reason: 'null-machinery-push: push step never reached: ' + JSON.stringify(stepsRun('pushdenied')) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 28: machineryBinDir de-obfuscation (temperloop#72, root cause 1). When the
# orchestrator passes a pre-resolved input.machineryBinDir, machineryBin emits a PLAIN
# absolute path — the executed worktree/push command line must carry NO nested
# \$(readlink …) command-substitution (what the classifier read as an obfuscated
# bypass). We capture the machinery prompts and assert the resolved path is present
# and no readlink substitution leaks into the executed line.
# ============================================================================
run_node_case "machineryBinDir: pre-resolved dir → plain paths, no readlink in executed machinery command (#72)" "
$PREAMBLE
happyMachinery('deobf', 260, 'sha-deobf');
happyWorker('deobf');
let machineryPrompts = [];
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts={}) {
  if (isMachineryCall(opts)) machineryPrompts.push(String(prompt));
  return origAgent(prompt, opts);
};
globalThis.args = { ...baseArgs, machineryBinDir: '/resolved/machinery/bin', items: [
  { slug: 'deobf', branch: 'build/deobf', title: 'Deobf', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'machineryBinDir: expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
// The worktree + push machinery commands must use the plain resolved dir...
const wtPrompt = machineryPrompts.find(p => p.includes('worktree.sh'));
const pushPrompt = machineryPrompts.find(p => p.includes('pr.sh') && p.includes(' push '));
if (!wtPrompt || !wtPrompt.includes('/resolved/machinery/bin/worktree.sh'))
  { console.log(JSON.stringify({ ok: false, reason: 'machineryBinDir: worktree cmd missing plain resolved path: ' + (wtPrompt||'<none>').slice(0,300) })); process.exit(0); }
if (!pushPrompt || !pushPrompt.includes('/resolved/machinery/bin/pr.sh'))
  { console.log(JSON.stringify({ ok: false, reason: 'machineryBinDir: push cmd missing plain resolved path: ' + (pushPrompt||'<none>').slice(0,300) })); process.exit(0); }
// ...and NO nested readlink command-substitution in any machinery command line.
const leaked = machineryPrompts.find(p => p.includes('readlink'));
if (leaked)
  { console.log(JSON.stringify({ ok: false, reason: 'machineryBinDir: readlink substitution leaked into executed machinery command: ' + leaked.slice(0,300) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# Root-cause-1 static guards (temperloop#72).
# (1) machineryBin must PREFER a pre-resolved input.machineryBinDir (plain-path branch),
#     so the executed pr.sh/worktree.sh line need not carry nested readlink.
# (2) The runMachinery / merge-check sub-agent instruction must no longer read as
#     'blindly execute an opaque command' — the 'Do NOT interpret it' phrasing
#     that (with the readlink substitution) tripped the auto-mode classifier is
#     gone.
grep -q 'input.machineryBinDir' "$MJS" \
  || fail "#72: machineryBin must prefer a pre-resolved input.machineryBinDir (de-obfuscated plain-path branch)"
if grep -q 'Do NOT interpret it' "$MJS"; then
  fail "#72: sub-agent instruction still reads as blind-execute ('Do NOT interpret it') — soften it"
fi
# (3) The null-guard must exist: a machineryDenied() detector + a machinery-denied escalation.
grep -q 'function machineryDenied(' "$MJS" \
  || fail "#72: machineryDenied() null/denied detector missing from build-level.mjs"
grep -q "'machinery-denied'" "$MJS" \
  || fail "#72: no 'machinery-denied' escalation emitted — a denied machinery step must park, not crash"
echo "PASS: #72 classifier-detrip + null-guard static guards — machineryBinDir plain-path branch, softened instruction, machineryDenied() + machinery-denied escalation present"

# ============================================================================
# Machinery-resolution regression guard (foundation #560).
# build-level.mjs runs in the Workflow sandbox (no fs/Node API), so the
# build-machinery scripts (worktree.sh/pr.sh/ci-poll.sh) MUST be resolved via the
# bash `machineryBin` fallback (repo-local → foundation), never the old hardcoded
# `${repoRoot}/workflows/scripts/build/<script>` template that broke in a
# stageFind checkout lacking the workflows→foundation symlink. Static-assert the
# fix stays in place. (The runtime behaviour of the emitted resolver is proven
# separately in the PR's executed 4-scenario matrix.)
grep -q '^function machineryBin(' "$MJS" \
  || fail "#560: machineryBin() resolver missing from build-level.mjs"
# The project's OWN vendored gate is resolved DIRECTLY (machineryBin is machinery-only) —
# and against the WORKTREE checkout, not repoRoot, so quality-gates.sh's own
# `cd "$REPO_ROOT"` stays in the worker's tree rather than jumping back to main
# (temperloop#626). It still never routes through machineryBin's foundation fallback.
# shellcheck disable=SC2016  # grepping for the LITERAL ${wt} token in source
grep -q 'const qgBin = `${wt}/scripts/quality-gates.sh`' "$MJS" \
  || fail "#560/#626: qgBin (repo-local quality-gates) must resolve from the worktree (\${wt}), directly — never repoRoot, never machineryBin"
# No machinery call site may regress to the hardcoded `.../workflows/scripts/build/<script>` template.
if grep -nE '\}/workflows/scripts/build/(worktree|pr|ci-poll)\.sh' "$MJS"; then
  fail "#560: a machinery script is still hardcoded to \${repoRoot}/workflows/scripts/build/ — route it through machineryBin()"
fi
# Every machinery invocation (worktree/pr×2/ci-poll) must go through machineryBin — 4 call sites + the def.
sb_refs="$(grep -c 'machineryBin(' "$MJS")"
[ "$sb_refs" -ge 5 ] \
  || fail "#560: expected >=5 machineryBin references (1 def + 4 call sites), found $sb_refs"
echo "PASS: #560 machinery-resolution guard — machineryBin() resolves all machinery scripts; no hardcoded paths; qgBin stays repo-local"

# --- temperloop#68: the 3e.5 gate command must carry `set -o pipefail` so a RED
# quality-gates run can never be swallowed by a downstream pipe/filter (the
# pipe-ate-exit-code defect). A future hand-edit that pipes the gate to capture
# its output would otherwise mask a non-zero gate exit behind the last stage's 0,
# degrading 3e.5 to a silent no-op. Guard the prefix statically. ------------
grep -q 'set -o pipefail; if \[ ! -x' "$MJS" \
  || fail "#68: 3e.5 gate command must prefix 'set -o pipefail' (pipe-ate-exit guard)"
echo "PASS: #68 gate-pipefail guard — 3e.5 gate invocation carries set -o pipefail"

# --- temperloop#115: the 3e.5 gate runMachinery call must pass an explicit Bash-tool
# timeout. The full quality-gates.sh suite runs >2min; without a raised timeout
# the executor's Bash tool SIGTERMs it at the default 120s → a false GATE_FAIL on
# every drive. Guard both the named constant and that the gate call threads it,
# so a future edit can't silently drop the timeout and re-break every drive. ----
grep -q 'const GATE_BASH_TIMEOUT_MS' "$MJS" \
  || fail "#115: GATE_BASH_TIMEOUT_MS constant missing — 3e.5 gate would SIGTERM at 120s"
grep -q 'bashTimeoutMs: GATE_BASH_TIMEOUT_MS' "$MJS" \
  || fail "#115: 3e.5 gate runMachinery call must pass bashTimeoutMs: GATE_BASH_TIMEOUT_MS"
echo "PASS: #115 gate-timeout guard — 3e.5 gate carries an explicit long Bash-tool timeout"

# --- temperloop#1021: the gate budget is a NAMED SETTING, not a bare literal, and
# EVERY caller wires it. The Workflow runtime has no shell, so the .mjs cannot
# source build.config.sh itself — the setting rides the same Step-0 hand-off as
# machinerySoloModel/machineryBatchModel, which means all THREE orchestrators must
# resolve and pass it or the seam silently reverts to the in-file default for that
# caller. Guard the consumer, the config seam, and each producer. ---------------
grep -qF 'input.gateSliceSecs' "$MJS" \
  || fail "#1021: build-level.mjs must read the gate budget from the orchestrator hand-off (input.gateSliceSecs), not a bare literal"
grep -q 'const GATE_MAX_SLICES' "$MJS" \
  || fail "#1021: the 3e.5 slice loop must be BOUNDED (GATE_MAX_SLICES) so a never-finishing suite escalates instead of looping forever"
grep -qF "escalate(item.slug, 'acceptance-gate-timeout'" "$MJS" \
  || fail "#1021: a budget-exhausted 3e.5 run must escalate its OWN kind (acceptance-gate-timeout), never collapse into acceptance-gate-failed"
grep -qF "escalate(item.slug, 'acceptance-gate-failed'" "$MJS" \
  || fail "#1021: a genuinely RED suite must STILL escalate acceptance-gate-failed — the timeout split must not weaken the gate"
_cfg="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)/workflows/scripts/build/build.config.sh"
grep -q 'BUILD_GATE_SLICE_SECS' "$_cfg" \
  || fail "#1021: BUILD_GATE_SLICE_SECS must be declared in build.config.sh (the named-setting seam)"
for _md in build fix sweep; do
  _p="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)/claude/commands/$_md.md"
  grep -q 'BUILD_GATE_SLICE_SECS' "$_p" \
    || fail "#1021: $_md.md Step 0 must resolve BUILD_GATE_SLICE_SECS (every build-level.mjs caller wires it, not /build alone)"
  grep -q 'gateSliceSecs' "$_p" \
    || fail "#1021: $_md.md must pass gateSliceSecs in its build-level.mjs args"
done
unset _md _p _cfg
echo "PASS: #1021 gate-budget guard — named setting, bounded slice loop, timeout/fail split, all three callers wired"

# --- temperloop#1460: the SAME three-caller invariant, for the two hand-offs
# build.md passed alone while sweep.md/fix.md silently omitted them. Both ride
# the identical Step-0 seam as gateSliceSecs above, and both DEGRADE SILENTLY
# when a caller drops them — which is exactly why they need a mechanical guard
# rather than review:
#   (a) machineryBinDir — omitting it makes machineryBin() fall back to the
#       nested $(dirname "$(readlink -f …)") command-substitution the auto-mode
#       classifier denied as an obfuscated-command bypass on --unattended runs
#       (temperloop#72). /sweep's DEFAULT posture is --unattended, so the
#       omission produced recurring machinery-denied bursts on every push step.
#   (b) principlesSummaries / principlesDefaultRepo — omitting them pins that
#       caller's workers on workerPrompt()'s static kernel-only DEGRADED
#       fallback permanently (PR #1439), with no project § Principles applied.
# Guard the resolution site (the plain cd+pwd form / the Step 1.8 reference)
# AND the args hand-off, per caller — a spec that names the value but never
# passes it is the half-wired shape this item found.
for _md in build fix sweep; do
  _p="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)/claude/commands/$_md.md"
  grep -q 'machineryBinDir' "$_p" \
    || fail "#1460: $_md.md must pass machineryBinDir in its build-level.mjs args (every caller wires it — omitting it re-arms the temperloop#72 classifier denial)"
  grep -qF 'cd workflows/scripts/build 2>/dev/null && pwd' "$_p" \
    || fail "#1460: $_md.md Step 0 must resolve machineryBinDir with the plain cd+pwd form (a nested readlink substitution here is the very shape #72 denied)"
  grep -q 'principlesSummaries' "$_p" \
    || fail "#1460: $_md.md must pass principlesSummaries in its build-level.mjs args (omitting it pins that caller's workers on the DEGRADED kernel-only fallback)"
  grep -q 'principlesDefaultRepo' "$_p" \
    || fail "#1460: $_md.md must pass principlesDefaultRepo alongside principlesSummaries (the lookup key workerPrompt() falls back to)"
  grep -q 'Step 1.8' "$_p" \
    || fail "#1460: $_md.md must reference build.md § Step 1.8 as the single principle-resolution implementation (pointer, never a re-derivation)"
done
unset _md _p
echo "PASS: #1460 machineryBinDir + principles hand-off guard — all three callers resolve and pass both"

# ============================================================================
# TEST (K712): worker background-gate stall — prevention + cure
#   The worker prompt MUST embed the FOREGROUND-ONLY contract (prevention), and
#   a null-verdict retry MUST append FOREGROUND_CURE so the retry prompt DIFFERS
#   from the first attempt (cure), then escalate worker-error only after TWO nulls.
# ============================================================================
run_node_case "K712 prevention: workerPrompt embeds the FOREGROUND-ONLY (#1219) contract" "
$PREAMBLE

happyMachinery('fg-item', 900, 'shaFg');
happyWorker('fg-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'fg-item', branch: 'build/fg-item', title: 'FG item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const w = callLog.find(c => (c.opts.label||'') === 'worker:fg-item');
if (!w) { console.log(JSON.stringify({ ok: false, reason: 'no worker call logged' })); process.exit(0); }
if (!w.promptFull.includes('FOREGROUND ONLY (#1219)')) { console.log(JSON.stringify({ ok: false, reason: 'worker prompt missing FOREGROUND-ONLY contract' })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "K712 cure: null verdict → retry prompt carries FOREGROUND_CURE, first does not → parked" "
$PREAMBLE

// temperloop#939: the null verdict now runs a recover-probe BEFORE the retry, so
// the machinery sequence carries a RECOVER_NONE (no side-effects → retry as before).
setMachinery('cure-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/cure-item' },
  noSideEffects(),
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'shaCure' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'shaCure', branch: 'build/cure-item' },
  { outcome: 'PR_OPENED', pr_number: 901 },
  { outcome: 'CI_GREEN' },
);
setWorker('cure-item', null, { status: 'done', summary: 'cured', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] });
globalThis.args = { ...baseArgs, items: [
  { slug: 'cure-item', branch: 'build/cure-item', title: 'Cure item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const first = callLog.find(c => (c.opts.label||'') === 'worker:cure-item');
const retry = callLog.find(c => (c.opts.label||'') === 'worker:cure-item#retry');
let reason = null;
if (!retry) reason = 'no retry call after null verdict';
else if (!retry.promptFull.includes('Re-spawn cure (#1219)')) reason = 'retry prompt missing FOREGROUND_CURE';
else if (first && first.promptFull.includes('Re-spawn cure (#1219)')) reason = 'first prompt must NOT carry the cure';
else if (parked.length !== 1) reason = 'expected 1 parked item after cured retry, got ' + parked.length;
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K712 regression: null verdict TWICE → worker-error escalation (unchanged)" "
$PREAMBLE

// Two nulls with a RECOVER_NONE probe after each (temperloop#939) — no
// observable side-effects, so the escalation path is unchanged.
setMachinery('err-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/err-item' },
  noSideEffects(),
  noSideEffects(),
);
setWorker('err-item', null, null);
globalThis.args = { ...baseArgs, items: [
  { slug: 'err-item', branch: 'build/err-item', title: 'Err item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
if (esc.length !== 1 || esc[0].kind !== 'worker-error') { console.log(JSON.stringify({ ok: false, reason: 'expected 1 worker-error escalation, got ' + JSON.stringify(esc.map(e => e.kind)) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST (K1530): workerPrompt must tell the worker to add its own
#   changelog.d/ fragment for contract-surface changes — the same way it is
#   told to run the gates (temperloop#1530). Asserts the section reaches the
#   worker's actual prompt (not just that the function exists — that's the
#   static guard below), and that it names both the README pointer (shape
#   lives in ONE place) and the commit-trailer opt-out (the channel that
#   works before a PR exists).
# ============================================================================
run_node_case "K1530 prevention: workerPrompt embeds the changelog-fragment instruction" "
$PREAMBLE

happyMachinery('cl-item', 900, 'shaCl');
happyWorker('cl-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'cl-item', branch: 'build/cl-item', title: 'CL item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const w = callLog.find(c => (c.opts.label||'') === 'worker:cl-item');
let reason = null;
if (!w) reason = 'no worker call logged';
else if (!w.promptFull.includes('Changelog fragment — contract-surface changes need one (temperloop#1530)')) reason = 'worker prompt missing the changelog-fragment section';
else if (!w.promptFull.includes('changelog.d/README.md')) reason = 'worker prompt must point at changelog.d/README.md rather than restate the fragment shape';
else if (!w.promptFull.includes('Changelog: none — <reason>')) reason = 'worker prompt must name the recorded commit-trailer opt-out';
else if (!w.promptFull.includes('changelog.d/cl-item.<category>.md')) reason = 'worker prompt must name a concrete fragment path derived from the item slug';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1530 static lockstep guards: build.md §3c and workerPrompt() must carry
# the SAME changelog-fragment instruction, so a future edit to either one
# cannot silently drop the other half — the exact defect this item fixes (a
# worker never told to add a fragment, so every contract-surface PR fails CI
# once by design). Mirrors the K1432/K1319 lockstep idiom above. -------------
grep -q 'function changelogFragmentSection' "$MJS" \
  || fail "#1530: changelogFragmentSection() missing — workerPrompt must embed the changelog-fragment instruction as its own self-contained section"
grep -q '## Changelog fragment — contract-surface changes need one (temperloop#1530)' "$MJS" \
  || fail "#1530: workerPrompt() must embed the '## Changelog fragment' section"
grep -q 'changelog.d/README.md' "$MJS" \
  || fail "#1530: workerPrompt() must point the worker at changelog.d/README.md rather than restate the fragment's filename grammar"
grep -q 'Changelog: none — <reason>' "$MJS" \
  || fail "#1530: workerPrompt() must name the recorded commit-trailer opt-out (the channel that works before a PR exists)"
grep -q '\.\.\.changelogFragmentSection(item)' "$MJS" \
  || fail "#1530: workerPrompt()'s returned array must splice in changelogFragmentSection(item) — a defined-but-unused function never reaches the worker"
K1530_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$K1530_BUILD_MD" ] \
  || fail "#1530: claude/commands/build.md is missing — the prose half of this contract pair cannot be verified"
grep -q 'temperloop#1530' "$K1530_BUILD_MD" \
  || fail "#1530: build.md §3c must name temperloop#1530 alongside the changelog-fragment instruction (lockstep with build-level.mjs)"
grep -q 'changelog.d/README.md' "$K1530_BUILD_MD" \
  || fail "#1530: build.md §3c must point the worker at changelog.d/README.md rather than restate the fragment's filename grammar"
grep -q 'Changelog: none — <reason>' "$K1530_BUILD_MD" \
  || fail "#1530: build.md §3c must name the recorded commit-trailer opt-out (lockstep with build-level.mjs)"
echo "PASS: #1530 changelog-fragment guard — workerPrompt embeds the add-a-fragment instruction (README pointer + recorded opt-out); build.md §3c in lockstep"

# ============================================================================
# TEST (K993): the backgrounded-gate stall is detected MECHANICALLY and
# auto-resumed — worker returned NO verdict AND its worktree is dirty with ZERO
# commits (the #982/#983 shape). The probe reports RECOVER_DIRTY; driveItem must
# resume the SAME worktree with the foreground cure PLUS a dirty-resume note
# naming the uncommitted count, rather than escalating "nothing happened".
# ============================================================================
run_node_case "K993 auto-resume: null verdict + RECOVER_DIRTY → resume prompt carries the dirty-resume note → parked" "
$PREAMBLE

setMachinery('stall-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/stall-item' },
  dirtyStall(8),                       // the #982 shape: 8 modified files, 0 commits
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'shaStall' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'shaStall', branch: 'build/stall-item' },
  { outcome: 'PR_OPENED', pr_number: 993 },
  { outcome: 'CI_GREEN' },
);
setWorker('stall-item', null, { status: 'done', summary: 'resumed', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] });
globalThis.args = { ...baseArgs, items: [
  { slug: 'stall-item', branch: 'build/stall-item', title: 'Stall item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const esc = result.escalations ?? [];
const first = callLog.find(c => (c.opts.label||'') === 'worker:stall-item');
const retry = callLog.find(c => (c.opts.label||'') === 'worker:stall-item#retry');
let reason = null;
if (!retry) reason = 'no auto-resume call after the RECOVER_DIRTY probe';
else if (!retry.promptFull.includes('Re-spawn cure (#1219)')) reason = 'resume prompt missing FOREGROUND_CURE';
else if (!retry.promptFull.includes('UNCOMMITTED work in this worktree (#993)')) reason = 'resume prompt missing the #993 dirty-resume note';
else if (!retry.promptFull.includes('8 uncommitted path(s)')) reason = 'dirty-resume note must name the uncommitted file count from the probe';
else if (first && first.promptFull.includes('UNCOMMITTED work in this worktree (#993)')) reason = 'first prompt must NOT carry the dirty-resume note';
else if (esc.length !== 0) reason = 'auto-resume must not escalate, got ' + JSON.stringify(esc.map(e => e.kind));
else if (parked.length !== 1) reason = 'expected 1 parked item after the auto-resume, got ' + parked.length;
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K993 split: a CLEAN RECOVER_NONE stall gets the cure but NOT the dirty-resume note" "
$PREAMBLE

setMachinery('clean-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/clean-item' },
  noSideEffects(),
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'shaClean' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'shaClean', branch: 'build/clean-item' },
  { outcome: 'PR_OPENED', pr_number: 994 },
  { outcome: 'CI_GREEN' },
);
setWorker('clean-item', null, { status: 'done', summary: 'ok', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] });
globalThis.args = { ...baseArgs, items: [
  { slug: 'clean-item', branch: 'build/clean-item', title: 'Clean item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();
const retry = callLog.find(c => (c.opts.label||'') === 'worker:clean-item#retry');
let reason = null;
if (!retry) reason = 'no retry call after the RECOVER_NONE probe';
else if (!retry.promptFull.includes('Re-spawn cure (#1219)')) reason = 'retry prompt missing FOREGROUND_CURE';
else if (retry.promptFull.includes('UNCOMMITTED work in this worktree (#993)')) reason = 'a CLEAN worktree must NOT get the dirty-resume note';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K993 escalation: resume also returns null + still dirty → worker-error names shape/dirty_files/worktree" "
$PREAMBLE

setMachinery('stuck-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/stuck-item' },
  dirtyStall(3),                       // the #983 shape: 3 modified files, 0 commits
  dirtyStall(3),
);
setWorker('stuck-item', null, null);
globalThis.args = { ...baseArgs, items: [
  { slug: 'stuck-item', branch: 'build/stuck-item', title: 'Stuck item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
let reason = null;
if (esc.length !== 1 || esc[0].kind !== 'worker-error') reason = 'expected 1 worker-error escalation, got ' + JSON.stringify(esc.map(e => e.kind));
else {
  const p = esc[0].payload ?? {};
  if (p.shape !== 'foreground-stall') reason = 'escalation payload must carry shape:foreground-stall, got ' + JSON.stringify(p.shape);
  else if (p.dirty_files !== 3) reason = 'escalation payload must carry the uncommitted count, got ' + JSON.stringify(p.dirty_files);
  else if (p.worktree !== '/tmp/repo.wt/stuck-item') reason = 'escalation payload must name the worktree holding the uncommitted work, got ' + JSON.stringify(p.worktree);
  else if (!String(p.reason || '').includes('skip prunes it')) reason = 'escalation reason must warn that skip prunes the worktree';
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K993 static lockstep guards: the mechanical half of the #993 pair. build.md
# §3c pairs the prose foreground clause with THIS detection; a future edit that
# drops the RECOVER_DIRTY rung or the dirty-resume cure leaves only the rotting
# prose behind. -------------------------------------------------------------
grep -q "'RECOVER_DIRTY'" "$MJS" \
  || fail "#993: SPINE_OUTCOME_SCHEMA must admit RECOVER_DIRTY (the probe's stall rung)"
grep -q 'function dirtyResumeCure' "$MJS" \
  || fail "#993: dirtyResumeCure() missing — the auto-resume must tell the worker its uncommitted work is still on disk"
grep -q 'withCure(verdictSection, probe.dirtyFiles)' "$MJS" \
  || fail "#993: the auto-resume must thread the probe's dirty-file count into the cure"
grep -q "shape: 'foreground-stall'" "$MJS" \
  || fail "#993: an uncured stall must escalate with shape:foreground-stall so the worktree's uncommitted work is not silently pruned"
echo "PASS: #993 detection guard — RECOVER_DIRTY rung + dirty-resume cure + stall-shaped escalation"

# --- K712 static lockstep guards (grep the MJS source directly, matching the
# tail-guard idiom above). These lock the code SHAPE build.md §3c/§3d cite, so a
# future edit cannot silently drop the prevention section or the retry cure. -----
grep -q 'FOREGROUND ONLY (#1219)' "$MJS" \
  || fail "#712: workerPrompt must embed the '## Quality gate … FOREGROUND ONLY (#1219)' contract (prevention)"
echo "PASS: #712 prevention guard — workerPrompt embeds the foreground-only gate contract"
grep -q 'const FOREGROUND_CURE' "$MJS" \
  || fail "#712: FOREGROUND_CURE constant missing — null-retry cure"
# (temperloop#993 widened the call to withCure(verdictSection, probe.dirtyFiles);
# this guard matches the prefix so it survives that added argument — the #993
# guard above pins the argument itself.)
grep -q 'withCure(verdictSection' "$MJS" \
  || fail "#712: main-worker null-retry must append the cure via withCure(verdictSection, …) so the retry prompt differs"
echo "PASS: #712 cure guard — null-verdict re-spawn appends FOREGROUND_CURE (retry prompt differs from first)"

# --- K997 static lockstep guards: the worker must NOT be told to run the bare,
# repo-wide quality-gates.sh in its own context (a minutes-long blocking turn
# blows the ~5-min prompt-cache TTL and re-writes the worker's whole context).
# Both surfaces build.md §3c names — workerPrompt()'s FOREGROUND-ONLY section and
# FOREGROUND_CURE — must carry the ban AND the non-authority caveat, so a future
# edit cannot quietly reinstate the bare run on either. Runtime shape (that the
# prompt actually reaches the worker) is already covered by the K712 prevention
# case above, which asserts the same section is present in promptFull. ---------
qg_ban_hits="$(grep -ci 'bare, repo-wide `scripts/quality-gates.sh`' "$MJS")"
[ "$qg_ban_hits" -ge 2 ] \
  || fail "#997: expected the bare-repo-wide-gate ban in BOTH workerPrompt()'s FOREGROUND-ONLY section and FOREGROUND_CURE (found $qg_ban_hits)"
grep -q 'FAST LOCAL FEEDBACK ONLY — it is NOT the acceptance authority' "$MJS" \
  || fail "#997: worker prompt must state the path-scoped subset is fast local feedback only, NOT the acceptance authority (3e.5 is)"
grep -q 'DEFERRED to the parent-side 3e.5 gate' "$MJS" \
  || fail "#997: worker prompt must tell the worker how to report a criterion naming the bare repo-wide suite (passed:true + deferred evidence, never passed:false)"
# The #997 narrowing applies to the WORKER only. 3e.5's parent-side gate remains
# the acceptance authority — and what makes it one is that it is the ORCHESTRATOR'S
# OWN run against the worker's commit, not the worker's self-report (the PR #309
# silent-red lesson turns on that, not on the gate's breadth).
#
# The invariant guarded here, unchanged since #997, is that NO PATH ARGUMENTS are
# ever appended to the invocation: the subshell must CLOSE immediately after the
# script path, so which gates run is decided by the VALIDATED map
# (gate-paths.tsv, linted by check-gate-paths.sh) and never by a hand-written
# path list at this call site. Both env-var prefixes ride in front of it and
# neither weakens that: #1021's budget/resume pair scopes the run in TIME, and
# #1663's QUALITY_GATES_SCOPED scopes it through that same validated map, whose
# every resolution failure widens to the full set.
# shellcheck disable=SC2016  # grepping for the LITERAL ${sq(qgBin)} token in source
grep -q 'QUALITY_GATES_BUDGET_SECS=${GATE_SLICE_SECS} ${sq(qgBin)} ) ' "$MJS" \
  || fail "#997/#309: the 3e.5 parent-side gate must invoke quality-gates.sh with NO path arguments — selection belongs to the validated map, not this call site"
# shellcheck disable=SC2016  # literal-token grep
grep -q 'QUALITY_GATES_START_AT=${startAt}' "$MJS" \
  || fail "#1021: the 3e.5 gate must pass its resume index as an ENV VAR (a FLAG would exit 2 'usage' on an older vendored quality-gates.sh and read back as a gate failure)"
echo "PASS: #997 worker-gate-scope guard — worker prompt + cure ban the bare repo-wide worker run; 3e.5's own invocation takes no path arguments"

# --- K1663: the 3e.5 gate is DIFF-SCOPED, and the seam is an ENV VAR ----------
# A full per-item suite could not survive within-level parallelism: a measured
# 3-item level burned 55 min / 1.24M subagent tokens and landed ZERO items, all
# three escalating acceptance-gate-timeout with every worker already finished and
# committed. Two properties have to hold at this call site, and both are the kind
# a well-meaning simplification would quietly drop:
#
#   1. The seam is $QUALITY_GATES_SCOPED, NOT the `--scoped` FLAG. A consuming
#      repo vendoring an OLDER quality-gates.sh IGNORES an unknown env var and
#      runs the whole suite (the pre-#1663 behavior, still correct), whereas an
#      unknown FLAG exits 2 "usage" and reads back here as a GATE FAILURE — it
#      would red every item in the fleet's un-updated repos at once.
#   2. The value comes from $BUILD_GATE_SCOPED with a DEFAULT, read from the
#      WORKTREE'S build.config.sh, so the escape hatch exists and an absent or
#      older config file still resolves.
# shellcheck disable=SC2016  # literal-token grep
grep -q 'QUALITY_GATES_SCOPED=\$(\. ${sq(configBin)}' "$MJS" \
  || fail "#1663: the 3e.5 gate must scope via the QUALITY_GATES_SCOPED ENV VAR resolved from the worktree's build.config.sh (a --scoped FLAG exits 2 'usage' on an older vendored quality-gates.sh and reads back as a gate failure)"
grep -q 'BUILD_GATE_SCOPED:-1' "$MJS" \
  || fail "#1663: the 3e.5 gate's scope must come from \$BUILD_GATE_SCOPED with a default, so the escape hatch exists and an absent/older build.config.sh still resolves"
# ...and pin the SPLICE, not just the DECLARATION. Both greps above match
# `gateScopeEnv`'s definition; deleting the line that interpolates it into
# `gateCmd` leaves them BOTH green while silently reverting 3e.5 to the full
# per-item suite — the exact 55-min/zero-items failure #1663 exists to fix, under
# a green guard suite. #1021's analogous guard cannot drift this way because its
# token lives inside the template itself; this branch introduced the indirection,
# so the indirection needs its own assertion. -qF: fixed-string, no BRE escaping.
grep -qF '`${gateScopeEnv} QUALITY_GATES_SELECTION_PIN=' "$MJS" \
  || fail "#1663: gateScopeEnv must be SPLICED INTO gateCmd, not merely declared — a defined-but-unused const silently restores the full per-item suite"
# The slice-stability half (temperloop#1663 HIGH): a scoped gate list is
# re-derived per slice, so QUALITY_GATES_START_AT -- an ORDINAL into that list --
# can point at a different gate on a later slice, silently skipping one while the
# suite still exits 0. Both halves must be present: the PIN that stops the input
# drifting, and the FINGERPRINT that makes a drift loud if it happens anyway.
grep -q 'QUALITY_GATES_SELECTION_PIN=' "$MJS" \
  || fail "#1663: the 3e.5 gate must pin the scoped changed set across slices — without it a resume index can silently address a different gate"
grep -q 'QUALITY_GATES_EXPECT_SELECTION=' "$MJS" \
  || fail "#1663: the 3e.5 gate must feed the previous slice's selection fingerprint back, so a drifted list restarts loudly instead of resuming a stale ordinal"
echo "PASS: #1663 scoped-acceptance-gate guard — 3e.5 scopes through QUALITY_GATES_SCOPED (env, not flag) from \$BUILD_GATE_SCOPED"

# --- K1663 superseded-premise guard: the OLD contract must not come back ------
# Before #1663, §3e.5 was documented in SEVEN live artifacts as the BARE,
# repo-wide run, and two of them stated a safety property that scoping REMOVED:
# that a repo-wide red the worker's scoped subset missed would be caught at
# §3e.5. It is not, and cannot be — §3e.5 and the worker's own `--scoped` run
# now resolve the same diff through the same map, so they select nearly the same
# gates. A red outside that set is caught by the UNSCOPED merge_group run, before
# `main` but after push.
#
# Six of the seven sites were rewritten by hand for #1663; the seventh survived
# the sweep and had to be caught in review. That is precisely the "purge the
# superseded premise from every live artifact" failure the kernel names, and a
# prose contradiction has no other test — so it gets a mechanical one here.
#
# These patterns are the FALSE CLAIMS, not the topic: prose that accurately
# describes what §3e.5 does and does not catch (including the words "repo-wide")
# is expected and must keep passing.
BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$BUILD_MD" ] || fail "#1663: claude/commands/build.md not found at $BUILD_MD"
for stale_claim in \
  'repo-wide red the subset missed is caught' \
  'bare repo-wide run was DEFERRED' \
  'bare repo-wide run was \*\*deferred'
do
  for surface in "$BUILD_MD" "$MJS"; do
    if grep -q "$stale_claim" "$surface"; then
      fail "#1663: '$(basename "$surface")' still asserts the pre-#1663 contract ('$stale_claim') — §3e.5 is diff-scoped and does NOT catch a repo-wide red outside the item's scoped set; the unscoped merge_group run does"
    fi
  done
done
# The positive half: §3e.5 must still be named as the acceptance AUTHORITY, so a
# future edit cannot "fix" the above by deleting the deferral contract wholesale
# and leaving the worker with no instruction at all.
grep -q 'DEFERRED to the parent-side 3e.5 gate' "$MJS" \
  || fail "#1663/#997: the worker prompt must still route a repo-wide acceptance criterion to §3e.5 — removing the stale WORDING must not remove the deferral CONTRACT"
echo "PASS: #1663 superseded-premise guard — no live artifact still claims §3e.5 is the bare repo-wide catch; the deferral contract survives"

# --- K1694: gateScopeEnv's emitted shell fragment is EXECUTED, not merely --
#   grepped for ------------------------------------------------------------
# The grep guards above prove the SOURCE mentions the right tokens. They
# cannot catch a dropped backslash that turns the JS template literal's
# \${BUILD_GATE_SCOPED:-1} escape into a REAL js interpolation against an
# undefined `BUILD_GATE_SCOPED` binding — a change every grep above still
# passes, while the gate silently reverts to the full per-item suite (the
# exact #1663 failure, back under a green guard suite).
#
# This test extracts sq() and the gateScopeEnv template-literal expression
# VERBATIM from build-level.mjs's own source (not a hand-copied re-encoding
# of it — a re-encoding would only test itself), evaluates that extracted
# JS against a caller-supplied `configBin`, and RUNS the resulting shell
# fragment under bash against three fixtures.
GATE_SCOPE_EXTRACT="$WF_TEST_TMPDIR/extract-gate-scope.cjs"
cat > "$GATE_SCOPE_EXTRACT" <<'NODE_EOF'
'use strict';
const fs = require('fs');
const [, , mjsPath, configBin] = process.argv;
if (!mjsPath || configBin === undefined) {
  console.error('usage: extract-gate-scope.cjs <build-level.mjs path> <configBin>');
  process.exit(2);
}
const src = fs.readFileSync(mjsPath, 'utf8');
// sq() is a top-level function declaration; its closing brace is the first
// line consisting solely of "}" after the opening line.
const sqMatch = src.match(/^function sq\(value\) \{[\s\S]*?^\}/m);
if (!sqMatch) {
  console.error('EXTRACT_FAILED: sq() function not found');
  process.exit(2);
}
// gateScopeEnv is a single-line-declared, backtick-delimited template
// literal expression. Capture just the expression (with its backticks), not
// the `const gateScopeEnv =` binding, so it can be eval'd as a bare
// expression below.
const gateMatch = src.match(/const gateScopeEnv =\s*\n\s*(`[\s\S]*?`);/);
if (!gateMatch) {
  console.error('EXTRACT_FAILED: gateScopeEnv template literal not found');
  process.exit(2);
}
let gateScopeEnv;
try {
  // new Function isolates evaluation in a fresh scope — configBin is the
  // only free variable the extracted expression needs, passed as a real
  // parameter rather than relying on any scope-leak trick. A dropped
  // backslash in the source turns \${BUILD_GATE_SCOPED:-1} into a real JS
  // interpolation; ":-1" is not valid JS in expression position, so this
  // throws a SyntaxError right here — the RED half of the discrimination.
  const factory = new Function('configBin', `${sqMatch[0]}\nreturn ${gateMatch[1]};`);
  gateScopeEnv = factory(configBin);
} catch (e) {
  console.error(`EVAL_FAILED: ${e.constructor.name}: ${e.message}`);
  process.exit(3);
}
process.stdout.write(gateScopeEnv);
NODE_EOF

# resolve_gate_scoped <mjs-path> <configBin-path>
# Extracts the fragment from <mjs-path> and actually RUNS it under bash,
# printing the resolved QUALITY_GATES_SCOPED value. Returns non-zero (with
# the extraction/eval diagnostic on stderr) if extraction or eval failed —
# the caller distinguishes "wrong value" from "couldn't even build it".
resolve_gate_scoped() {
  local mjs="$1" configBin="$2" out rc errfile
  errfile="$(mktemp "$WF_TEST_TMPDIR/gate-scope-err.XXXXXX")"
  out="$(node "$GATE_SCOPE_EXTRACT" "$mjs" "$configBin" 2>"$errfile")"
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "EXTRACTION_FAILED: $(cat "$errfile")" >&2
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"
  bash -c "$out; echo \"\${QUALITY_GATES_SCOPED}\""
}

GATE_FIX_DIR="$WF_TEST_TMPDIR/gate-scope-fixtures"
mkdir -p "$GATE_FIX_DIR"

# Fixture 1: build.config.sh does not exist at all.
GATE_FIX_MISSING="$GATE_FIX_DIR/does-not-exist/build.config.sh"

# Fixture 2: an ordinary config carrying the explicit override.
GATE_FIX_ZERO="$GATE_FIX_DIR/zero.sh"
printf 'BUILD_GATE_SCOPED=0\n' > "$GATE_FIX_ZERO"

# Fixture 3: a config that sets `set -euo pipefail` (mirroring a plausible
# future hardening of build.config.sh) and then genuinely FAILS mid-file —
# `false` is a real, unguarded failing command, not an if-condition trick.
# It runs with -e disabled (`set +e`) specifically so the failure survives
# to be sourcing's own nonzero return rather than an -e-triggered abort of
# the containing subshell (an abort would kill the fragment's inner
# `$(...)` outright and produce NO value at all under either separator —
# that failure mode can't discriminate ';' from '&&', so it's not what this
# fixture is for). BUILD_GATE_SCOPED is never assigned, so the default must
# carry the result home.
GATE_FIX_POISON="$GATE_FIX_DIR/poison.sh"
cat > "$GATE_FIX_POISON" <<'POISON_EOF'
set -euo pipefail
echo "probing" >/dev/null
set +e
false
POISON_EOF

# --- GREEN: the real, unmodified build-level.mjs ---------------------------
v="$(resolve_gate_scoped "$MJS" "$GATE_FIX_MISSING")" \
  || fail "gate-scope-exec: extraction from the real .mjs must succeed (missing-config fixture)"
[ "$v" = "1" ] || fail "gate-scope-exec: a missing build.config.sh must resolve QUALITY_GATES_SCOPED=1 (got '$v')"

v="$(resolve_gate_scoped "$MJS" "$GATE_FIX_ZERO")" \
  || fail "gate-scope-exec: extraction from the real .mjs must succeed (zero fixture)"
[ "$v" = "0" ] || fail "gate-scope-exec: a BUILD_GATE_SCOPED=0 fixture must resolve QUALITY_GATES_SCOPED=0 (got '$v')"

v="$(resolve_gate_scoped "$MJS" "$GATE_FIX_POISON")" \
  || fail "gate-scope-exec: extraction from the real .mjs must succeed (poison fixture)"
[ "$v" = "1" ] || fail "gate-scope-exec: a set -euo pipefail mid-source failure must still resolve QUALITY_GATES_SCOPED=1 (got '$v')"
echo "PASS: gate-scope-exec — the real gateScopeEnv fragment resolves correctly under bash for all three fixtures (missing/zero/poisoned)"

# The load-bearing half of fixture 3 (per the item notes): prove the ';'
# (not '&&') separator between `. configBin` and `echo` is what makes the
# poisoned fixture resolve at all. Swap the SAME extracted fragment's ';'
# for '&&' and confirm it stops resolving to the default — demonstrating
# fixture 3 actually exercises that design choice rather than passing
# vacuously regardless of it.
frag_semi="$(node "$GATE_SCOPE_EXTRACT" "$MJS" "$GATE_FIX_POISON")" \
  || fail "gate-scope-exec: extraction for the &&-vs-; check must succeed"
# Prefix/suffix split rather than ${var/pat/repl} — an unescaped '&' in a
# parameter-expansion REPLACEMENT is special (it re-inserts the matched
# text), so a naive `/; echo/ && echo/` silently corrupts the fragment.
gate_and_prefix="${frag_semi%%; echo*}"
gate_and_suffix="${frag_semi#*; echo}"
frag_and="${gate_and_prefix} && echo${gate_and_suffix}"
[ "$frag_semi" != "$frag_and" ] \
  || fail "gate-scope-exec: could not construct the '&&' variant — the fragment shape changed unexpectedly"
v_and="$(bash -c "$frag_and; echo \"\${QUALITY_GATES_SCOPED}\"")"
[ "$v_and" != "1" ] \
  || fail "gate-scope-exec: the '&&' variant must NOT also resolve to 1 — otherwise fixture 3 isn't discriminating the ';' choice at all"
echo "PASS: gate-scope-exec — fixture 3 is load-bearing: swapping ';' for '&&' changes the resolved value (got '$v_and' instead of '1')"

# --- RED: the same extraction against a MUTATED copy where the backslash
# escape is dropped — \${BUILD_GATE_SCOPED:-1} becomes ${BUILD_GATE_SCOPED:-1},
# a REAL js interpolation. ":-1" is not valid JS in expression position, so
# this must fail extraction/eval outright (not silently produce a wrong
# value) — proving this suite is RED without the escape and GREEN with it,
# demonstrated both ways rather than asserted.
GATE_MUTANT="$WF_TEST_TMPDIR/build-level.mutant.mjs"
node -e '
const fs = require("fs");
const [, mjsPath, outPath] = process.argv;
const src = fs.readFileSync(mjsPath, "utf8");
const needle = "\\${BUILD_GATE_SCOPED:-1}";
if (!src.includes(needle)) {
  console.error("mutant: escaped token not found in source");
  process.exit(2);
}
fs.writeFileSync(outPath, src.split(needle).join("${BUILD_GATE_SCOPED:-1}"));
' "$MJS" "$GATE_MUTANT" || fail "gate-scope-exec: could not construct the dropped-backslash mutant"
if resolve_gate_scoped "$GATE_MUTANT" "$GATE_FIX_MISSING" >/dev/null 2>&1; then
  fail "gate-scope-exec: the dropped-backslash mutant must NOT extract/eval cleanly — it should throw at eval time, proving this test goes RED without the escape"
fi
echo "PASS: gate-scope-exec — RED demonstrated: dropping the backslash breaks extraction/eval of gateScopeEnv where the real .mjs passes clean"

# ============================================================================
# TEST (K1080): worker return-value OUTPUT SHAPE reaches the prompt, and its
#   bounds come from the orchestrator hand-off (Step 0) — not a hardcoded
#   literal. Runtime twin of the static guards below: the static half proves the
#   source interpolates the constants, this half proves an operator-supplied
#   input.workerSummaryMaxWords / workerEvidenceMaxWords actually lands in the
#   prompt the worker reads, and that an OMITTED key still yields a bounded
#   prompt (the /sweep + /fix inheritance path).
# ============================================================================
run_node_case "K1080: output-shape bounds ride input.* into the worker prompt; omitted keys fall back to the in-file defaults" "
$PREAMBLE

happyMachinery('os-item', 900, 'shaOs');
happyWorker('os-item');
globalThis.args = { ...baseArgs, workerSummaryMaxWords: 41, workerEvidenceMaxWords: 23, items: [
  { slug: 'os-item', branch: 'build/os-item', title: 'OS item', kind: 'impl', acceptance: ['c'] },
]};
let mod = await loadLevel();
await mod.default();
let w = callLog.find(c => (c.opts.label||'') === 'worker:os-item');
let reason = null;
if (!w) reason = 'no worker call logged';
else if (!w.promptFull.includes('## Output shape')) reason = 'worker prompt missing the Output shape section';
else if (!w.promptFull.includes('No process narration anywhere in the return value')) reason = 'worker prompt missing the process-narration ban';
else if (!w.promptFull.includes('at most 41 words')) reason = 'summary bound did not come from input.workerSummaryMaxWords';
else if (!w.promptFull.includes('at most 23 words')) reason = 'evidence bound did not come from input.workerEvidenceMaxWords';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Second pass, keys OMITTED — sweep.md/fix.md today. Still bounded.
callLog.length = 0;
happyMachinery('os2-item', 901, 'shaOs2');
happyWorker('os2-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'os2-item', branch: 'build/os2-item', title: 'OS2 item', kind: 'impl', acceptance: ['c'] },
]};
mod = await loadLevel();
await mod.default();
w = callLog.find(c => (c.opts.label||'') === 'worker:os2-item');
if (!w) reason = 'no worker call logged (defaults pass)';
else if (!w.promptFull.includes('## Output shape')) reason = 'omitted-keys prompt lost the Output shape section';
else if (!/\`summary\`: at most [0-9]+ words/.test(w.promptFull)) reason = 'omitted-keys prompt carries no summary bound';
else if (!/evidence\`: at most [0-9]+ words/.test(w.promptFull)) reason = 'omitted-keys prompt carries no evidence bound';
else if (w.promptFull.includes('at most 41 words')) reason = 'omitted-keys prompt leaked the previous run\\'s override';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1080 static guards: worker return-value OUTPUT SHAPE -------------------
# The verdict's SHAPE is schema-enforced; its SIZE is not (a JSON schema cannot
# bound a string's length), so workerPrompt() must carry an explicit `## Output
# shape` section stating the two word bounds and banning process narration. The
# bounds must be INTERPOLATED from the named-setting constants, never typed as
# literals in the prompt text — a literal would drift from build.config.sh the
# first time the setting is retuned. build.md §3c carries the same contract, so
# both surfaces are pinned here (the runtime half — that the section actually
# reaches the worker — rides the K712 prevention case's promptFull assertion).
grep -q '## Output shape — your return value is a REPORT, not a transcript' "$MJS" \
  || fail "#1080: workerPrompt() must embed the '## Output shape' section (the SIZE half of the 3c return contract)"
grep -q 'No process narration anywhere in the return value' "$MJS" \
  || fail "#1080: worker prompt must ban process narration in the return value"
# shellcheck disable=SC2016  # grepping for the LITERAL ${WORKER_*_MAX_WORDS} tokens in source
grep -q '${WORKER_SUMMARY_MAX_WORDS} words' "$MJS" \
  || fail "#1080: the summary bound must be INTERPOLATED from WORKER_SUMMARY_MAX_WORDS, never a literal in the prompt text"
# shellcheck disable=SC2016  # literal-token grep
grep -q '${WORKER_EVIDENCE_MAX_WORDS} words' "$MJS" \
  || fail "#1080: the evidence bound must be INTERPOLATED from WORKER_EVIDENCE_MAX_WORDS, never a literal in the prompt text"
grep -q 'input.workerSummaryMaxWords' "$MJS" \
  || fail "#1080: WORKER_SUMMARY_MAX_WORDS must read the orchestrator-supplied input.workerSummaryMaxWords (Step-0 hand-off seam)"
grep -q 'input.workerEvidenceMaxWords' "$MJS" \
  || fail "#1080: WORKER_EVIDENCE_MAX_WORDS must read the orchestrator-supplied input.workerEvidenceMaxWords (Step-0 hand-off seam)"
K1080_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
if [ -f "$K1080_BUILD_MD" ]; then
  grep -q 'BUILD_WORKER_SUMMARY_MAX_WORDS' "$K1080_BUILD_MD" \
    || fail "#1080: build.md §3c must NAME BUILD_WORKER_SUMMARY_MAX_WORDS (prose names the setting, never its value)"
  grep -q 'BUILD_WORKER_EVIDENCE_MAX_WORDS' "$K1080_BUILD_MD" \
    || fail "#1080: build.md §3c must NAME BUILD_WORKER_EVIDENCE_MAX_WORDS (prose names the setting, never its value)"
fi
echo "PASS: #1080 output-shape guard — workerPrompt bounds summary/evidence from named settings and bans process narration; build.md §3c in lockstep"

# ============================================================================
# TEST (K939): lost-return recovery — a worker that completed WITHOUT calling
# StructuredOutput must not manufacture a `worker-error` escalation for work
# that demonstrably landed. Covers all three observable stages plus the
# genuine-failure case (which stays exactly as it was).
# ============================================================================

run_node_case "K939 L0 shape: throw + RECOVER_PR_OPEN → parked from ground truth, no escalation, no re-spawn" "
$PREAMBLE

// The #939 L0 incident: commit authored, branch pushed, PR #936 open, CI green
// — and the worker's agent() threw because it never called StructuredOutput.
setMachinery('prose-budget-headroom',
  { outcome: 'CREATED', path: '/tmp/repo.wt/prose-budget-headroom' },
  { outcome: 'RECOVER_PR_OPEN', sha: 'bca3824', commits_ahead: 1, pushed: true, remote_sha: 'bca3824', pr_number: 936, verification_surface_present: true },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  // NOTE: no REBASED entry — the branch is already on origin, so 3f-0a is skipped.
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'bca3824', branch: 'chore/prose-budget-headroom' },
  { outcome: 'EXISTS', pr_number: 936 },
  { outcome: 'CI_GREEN' },
);
setWorker('prose-budget-headroom', throwingWorker());

globalThis.args = { ...baseArgs, items: [
  { slug: 'prose-budget-headroom', branch: 'chore/prose-budget-headroom', title: 'Prose budget headroom', kind: 'impl', acceptance: ['crit one', 'crit two'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const esc = result.escalations ?? [];
let reason = null;
if (esc.length !== 0) reason = 'expected 0 escalations, got ' + JSON.stringify(esc);
else if (parked.length !== 1) reason = 'expected 1 parked, got ' + JSON.stringify(result);
else if (parked[0].pr !== 936) reason = 'pr not reconstructed from ground truth: ' + JSON.stringify(parked[0]);
else if (parked[0].pushed_sha !== 'bca3824') reason = 'pushed_sha not reconstructed: ' + JSON.stringify(parked[0]);
else if (parked[0].acceptance_unverified !== true) reason = 'parked record must flag acceptance_unverified';
else if (parked[0].recovered_from !== 'RECOVER_PR_OPEN') reason = 'recovered_from stage missing/wrong: ' + parked[0].recovered_from;
else if ((parked[0].acceptance_results || []).some(r => r.passed === true)) reason = 'recovered acceptance results must NEVER read as passing';
else if (!(parked[0].acceptance_results || []).every(r => String(r.evidence||'').includes('UNVERIFIED'))) reason = 'every recovered acceptance result must be marked UNVERIFIED';
// No re-spawn: exactly ONE worker call, and no #retry label.
else if (callLog.filter(c => isWorkerCall(c.opts)).length !== 1) reason = 'worker was re-spawned after a recovered return (must not be)';
else if (callLog.some(c => String(c.opts.label||'').includes('#retry'))) reason = 'retry worker spawned despite observable side-effects';
// No second PR: the open call went out and pr.sh answered EXISTS (adopted).
// No second PR: the pr-open step ran exactly once and pr.sh answered EXISTS.
else if (stepsRun('prose-budget-headroom').filter(k => k === 'pr-open').length !== 1) reason = 'expected exactly one pr-open step';
// An already-pushed recovery must NOT rebase (the plain push would be rejected).
else if (stepsRun('prose-budget-headroom').includes('rebase')) reason = 'an already-pushed recovery must NOT rebase';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K939 L1 shape: throw + RECOVER_COMMITTED → rebase/push/open run, parked unverified" "
$PREAMBLE

// The #939 L1 variant: work committed in the worktree, NOT pushed, no PR. The
// recovery must complete the machinery (rebase IS run here — nothing is on the
// remote yet) rather than escalating.
setMachinery('brief-record-completeness-lint',
  { outcome: 'CREATED', path: '/tmp/repo.wt/brief-record-completeness-lint' },
  { outcome: 'RECOVER_COMMITTED', sha: '140fc64', commits_ahead: 1, pushed: false, remote_sha: '', verification_surface_present: false },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: '140fc64' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: '140fc64', branch: 'feat/brief-record-completeness-lint' },
  { outcome: 'PR_OPENED', pr_number: 941 },
  { outcome: 'CI_GREEN' },
);
setWorker('brief-record-completeness-lint', throwingWorker('StructuredOutput retry cap (5) exceeded — 5 failed calls with no valid output'));

globalThis.args = { ...baseArgs, items: [
  { slug: 'brief-record-completeness-lint', branch: 'feat/brief-record-completeness-lint', title: 'Brief record completeness lint', kind: 'impl', acceptance: ['crit one'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const esc = result.escalations ?? [];
// temperloop#942: rebase/scan/push/pr-open share ONE 'pr-batch' executor, so the
// pr-open command text is inspected on that call's prompt.
const openCall = callLog.find(c => String(c.opts.label||'').startsWith('pr-batch:'));
let reason = null;
if (esc.length !== 0) reason = 'expected 0 escalations, got ' + JSON.stringify(esc);
else if (parked.length !== 1) reason = 'expected 1 parked, got ' + JSON.stringify(result);
else if (parked[0].pr !== 941) reason = 'pr not adopted from the recovery open: ' + JSON.stringify(parked[0]);
else if (parked[0].recovered_from !== 'RECOVER_COMMITTED') reason = 'recovered_from wrong: ' + parked[0].recovered_from;
else if (parked[0].acceptance_unverified !== true) reason = 'acceptance_unverified flag missing';
// The rebase step DID run for the unpushed stage.
else if (!stepsRun('brief-record-completeness-lint').includes('rebase')) reason = 'RECOVER_COMMITTED must still rebase (nothing pushed yet)';
// No surface file existed → the flag must be dropped, and an inline synthesized
// surface handed to pr.sh instead (a given-but-missing file is a hard ERROR).
else if (!openCall) reason = 'no pr-open call logged';
else if (openCall.promptFull.includes('--verification-surface-file')) reason = 'surface-file flag must be dropped when the probe saw no .build-verification.md';
else if (!openCall.promptFull.includes('verification_surface')) reason = 'recovery must hand pr.sh a synthesized inline verification_surface';
else if (!openCall.promptFull.includes('temperloop#939')) reason = 'recovered PR body must name its recovered provenance';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K939 RECOVER_PUSHED: surface file present → flag kept, rebase skipped, PR opened" "
$PREAMBLE

setMachinery('pushed-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/pushed-item' },
  { outcome: 'RECOVER_PUSHED', sha: 'shaP', commits_ahead: 2, pushed: true, remote_sha: 'shaP', verification_surface_present: true },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'shaP', branch: 'build/pushed-item' },
  { outcome: 'PR_OPENED', pr_number: 950 },
  { outcome: 'CI_GREEN' },
);
setWorker('pushed-item', throwingWorker());
globalThis.args = { ...baseArgs, items: [
  { slug: 'pushed-item', branch: 'build/pushed-item', title: 'Pushed item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const openCall = callLog.find(c => String(c.opts.label||'').startsWith('pr-batch:'));
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'expected 0 escalations, got ' + JSON.stringify(result.escalations);
else if (parked.length !== 1 || parked[0].pr !== 950) reason = 'expected 1 parked at PR 950: ' + JSON.stringify(result);
else if (parked[0].recovered_from !== 'RECOVER_PUSHED') reason = 'recovered_from wrong: ' + parked[0].recovered_from;
else if (stepsRun('pushed-item').includes('rebase')) reason = 'an already-pushed branch must NOT be rebased (the push would be rejected)';
else if (!/^Steps: scan, push, pr-open$/m.test(String(openCall && openCall.promptFull || ''))) reason = 'the pr-batch must DROP the rebase step for an already-pushed recovery: ' + String(openCall && openCall.promptFull || '').split('\n').find(l => l.startsWith('Steps:'));
else if (!openCall || !openCall.promptFull.includes('--verification-surface-file')) reason = 'surface-file flag must be kept when the probe saw .build-verification.md';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K939 genuine failure: throw + RECOVER_NONE twice → worker-error escalation (unchanged)" "
$PREAMBLE

setMachinery('dead-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/dead-item' },
  noSideEffects(),
  noSideEffects(),
);
setWorker('dead-item', throwingWorker(), throwingWorker());
globalThis.args = { ...baseArgs, items: [
  { slug: 'dead-item', branch: 'build/dead-item', title: 'Dead item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'a no-side-effect worker must not park';
else if (esc.length !== 1 || esc[0].kind !== 'worker-error') reason = 'expected 1 worker-error escalation, got ' + JSON.stringify(esc);
else if (!String(esc[0].payload && esc[0].payload.reason || '').includes('StructuredOutput')) reason = 'escalation payload must carry the real return-channel error: ' + JSON.stringify(esc[0].payload);
// The retry DID happen (nothing landed, so the #1219 cure still applies).
else if (!callLog.some(c => String(c.opts.label||'').includes('#retry'))) reason = 'with no side-effects the #1219 cure retry must still run';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K939 probe unusable (denied/ERROR) → falls back to the unchanged worker-error escalation" "
$PREAMBLE

// A broken probe must never manufacture a recovery — fail CLOSED to the old path.
setMachinery('probe-broken',
  { outcome: 'CREATED', path: '/tmp/repo.wt/probe-broken' },
  { outcome: 'ERROR', error: 'pr.sh: recover-probe not found' },
  { outcome: 'ERROR', error: 'pr.sh: recover-probe not found' },
);
setWorker('probe-broken', throwingWorker(), throwingWorker());
globalThis.args = { ...baseArgs, items: [
  { slug: 'probe-broken', branch: 'build/probe-broken', title: 'Probe broken', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const esc = result.escalations ?? [];
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'an unusable probe must not park anything';
else if (esc.length !== 1 || esc[0].kind !== 'worker-error') reason = 'expected worker-error, got ' + JSON.stringify(esc);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K939 static lockstep guards (same tail-guard idiom as the K712 block) -----
grep -q 'recover-probe' "$MJS" \
  || fail "#939: driveItem must probe observable side-effects via 'pr.sh recover-probe' before classifying a lost worker return"
echo "PASS: #939 probe guard — build-level.mjs runs the staged recover-probe"
grep -q 'acceptance_unverified' "$MJS" \
  || fail "#939: a recovered parked record must carry acceptance_unverified (its acceptance results are UNKNOWN, never 'pass')"
echo "PASS: #939 honesty guard — a recovered parked record flags acceptance_unverified"
grep -q 'async function callWorker' "$MJS" \
  || fail "#939: the worker spawn must be wrapped so a THROWN lost-return (StructuredOutput absent) is caught, not propagated as worker-error"
echo "PASS: #939 throw guard — callWorker() normalizes a thrown lost return"

# ============================================================================
# TEST (K942): batched machinery. build-level.mjs used to spawn ONE haiku
# executor agent per mechanical shell command — an L0 level of 3 items measured
# 40 agents (3 real workers + 37 micro-agents), each paying ~160K cache-read
# tokens and 4 API round-trips to run one one-liner (temperloop#942). The
# mechanically-adjacent steps are now batched into one executor each, WITHOUT
# moving any branching decision out of the .mjs.
# ============================================================================

run_node_case "K942 spawn count: an L0-shaped 3-item level spends 4 machinery executors per item, not one per command" "
$PREAMBLE

// Board ON + ghIssue → the full L0 shape: claim, worktree, gate, rebase, scan,
// push, pr-open, then a CI poll that needs two slices (TIMEOUT then CI_GREEN).
for (const [slug, pr, sha] of [['a1', 11, 'sha-a1'], ['a2', 12, 'sha-a2'], ['a3', 13, 'sha-a3']]) {
  setMachinery(slug,
    { outcome: 'CLAIMED' },
    { outcome: 'CREATED', path: '/tmp/repo.wt/' + slug },
    { outcome: 'REVIEW_DIFF' },
    { outcome: 'GATE_PASS' },
    { outcome: 'REBASED', base: 'b', tip: 't', sha },
    { outcome: 'SCAN_CLEAN' },
    { outcome: 'PUSHED', sha, branch: 'build/' + slug },
    { outcome: 'PR_OPENED', pr_number: pr },
    { outcome: 'TIMEOUT' },
    { outcome: 'CI_GREEN' },
  );
  happyWorker(slug);
}

globalThis.args = { ...baseArgs, board: 3, claimCmd: '/fake/claim.sh', items: [
  { slug: 'a1', branch: 'build/a1', title: 'A1', kind: 'impl', ghIssue: 1, acceptance: ['c'] },
  { slug: 'a2', branch: 'build/a2', title: 'A2', kind: 'impl', ghIssue: 2, acceptance: ['c'] },
  { slug: 'a3', branch: 'build/a3', title: 'A3', kind: 'impl', ghIssue: 3, acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

let reason = null;
if ((result.parked ?? []).length !== 3) reason = 'expected 3 parked, got ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 0) reason = 'expected 0 escalations, got ' + JSON.stringify(result.escalations);

const machineryCalls = callLog.filter(c => isMachineryCall(c.opts));
const workerCalls = callLog.filter(c => isWorkerCall(c.opts));

// The number of agent spawns the OLD one-agent-per-command bridge would have
// paid for exactly this run: one per batched step actually executed, plus one
// per solo (unbatched) machinery call. Derived from the run, not hardcoded.
const soloCalls = machineryCalls.filter(c => !/^Steps: /m.test(c.promptFull)).length;
const unbatched = machineryStepLog.length + soloCalls;

if (!reason && workerCalls.length !== 3) reason = 'expected 3 worker spawns, got ' + workerCalls.length;
// 5 machinery executors per item: prelude, review-diff (temperloop#1430), gate, pr-batch, ci-batch.
if (!reason && machineryCalls.length !== 15) reason = 'expected 15 machinery executors (5/item), got ' + machineryCalls.length + ': ' + JSON.stringify(machineryCalls.map(c => c.opts.label));
if (!reason && callLog.length !== 18) reason = 'expected 18 total agent spawns for the level, got ' + callLog.length;
// …and that is a real reduction against the un-batched equivalent of this run.
if (!reason && unbatched !== 36) reason = 'expected the un-batched equivalent to be 36 spawns, got ' + unbatched;
if (!reason && !(machineryCalls.length < unbatched)) reason = 'batching did not reduce machinery spawns: ' + machineryCalls.length + ' vs ' + unbatched;

// Per item, the executors are exactly these five, in this order.
for (const slug of ['a1', 'a2', 'a3']) {
  const labels = machineryCalls.filter(c => (c.opts.label||'').includes(slug)).map(c => c.opts.label);
  const want = ['prelude:' + slug, 'review-diff:' + slug, 'gate:' + slug, 'pr-batch:' + slug, 'ci-batch:' + slug + '#0'];
  if (!reason && JSON.stringify(labels) !== JSON.stringify(want))
    reason = slug + ' machinery executors wrong: ' + JSON.stringify(labels);
  // Every mechanical step still RAN — batching removed spawns, not work.
  const want2 = ['claim','worktree','rebase','scan','push','pr-open','merge-state','ci-poll','merge-state','ci-poll'];
  if (!reason && JSON.stringify(stepsRun(slug)) !== JSON.stringify(want2))
    reason = slug + ' batched steps wrong: ' + JSON.stringify(stepsRun(slug));
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K942 prelude batching: claim + deps-merged + worktree ride ONE executor, each still branched in .mjs" "
$PREAMBLE

// All three prelude steps present, all green → ONE executor, three steps.
setMachinery('pre-ok',
  { outcome: 'CLAIMED' },
  { outcome: 'DEPS_MERGED' },
  { outcome: 'CREATED', path: '/tmp/repo.wt/pre-ok' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-pre' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-pre', branch: 'build/pre-ok' },
  { outcome: 'PR_OPENED', pr_number: 942 },
  { outcome: 'CI_GREEN' },
);
happyWorker('pre-ok');

// Claim conflict inside the SAME batch: the .mjs must still make the
// claim-conflict decision, and the batch must never reach worktree create.
setMachinery('pre-claimfail', { outcome: 'CLAIM_CONFLICT' });

globalThis.args = { ...baseArgs, board: 3, claimCmd: '/fake/claim.sh', items: [
  { slug: 'pre-ok', branch: 'build/pre-ok', title: 'Pre OK', kind: 'impl', ghIssue: 10, acceptance: ['c'],
    dependsOn: [{ slug: 'dep', sha: 'sha-dep' }] },
  { slug: 'pre-claimfail', branch: 'build/pre-claimfail', title: 'Pre claim fail', kind: 'impl', ghIssue: 11, acceptance: ['c'],
    dependsOn: [{ slug: 'dep', sha: 'sha-dep' }] },
]};

const mod = await loadLevel();
const result = await mod.default();

const preludeCalls = callLog.filter(c => (c.opts.label||'').startsWith('prelude:'));
const okPrelude = preludeCalls.find(c => c.opts.label === 'prelude:pre-ok');
let reason = null;
if ((result.parked ?? []).length !== 1 || result.parked[0].slug !== 'pre-ok') reason = 'pre-ok should park: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 1 || result.escalations[0].kind !== 'claim-conflict') reason = 'expected 1 claim-conflict escalation: ' + JSON.stringify(result.escalations);
// ONE executor per item covers the whole prelude — not three.
else if (preludeCalls.length !== 2) reason = 'expected exactly 2 prelude executors (1/item), got ' + preludeCalls.length;
else if (JSON.stringify(stepsRun('pre-ok').slice(0,3)) !== JSON.stringify(['claim','deps-merged','worktree'])) reason = 'pre-ok prelude steps wrong: ' + JSON.stringify(stepsRun('pre-ok'));
// The failing claim short-circuits the batch — worktree create never runs.
else if (JSON.stringify(stepsRun('pre-claimfail')) !== JSON.stringify(['claim'])) reason = 'a CLAIM_CONFLICT must stop the prelude before deps/worktree: ' + JSON.stringify(stepsRun('pre-claimfail'));
// The executor prompt names its steps, and the executor is told an early stop is
// expected — by its own definition on the lean default (temperloop#1014), by the
// per-call prompt on the general-purpose fallback.
else if (!/^Steps: claim, deps-merged, worktree$/m.test(okPrelude.promptFull)) reason = 'prelude prompt missing the Steps manifest';
else if (okPrelude.opts.agentType !== 'machinery-executor') reason = 'prelude executor should run as machinery-executor, got ' + okPrelude.opts.agentType;
else if (!/stops early/i.test(AGENT_DEF + okPrelude.promptFull)) reason = 'the executor must be told an early stop is expected, not an error';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K942 ci-poll reuse: 5 poll slices cost 3 ci-batch executors, not 5 polls + 5 merge-checks" "
$PREAMBLE

setMachinery('slow-ci',
  { outcome: 'CREATED', path: '/tmp/repo.wt/slow-ci' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-slow' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-slow', branch: 'build/slow-ci' },
  { outcome: 'PR_OPENED', pr_number: 700 },
  { outcome: 'TIMEOUT' },
  { outcome: 'TIMEOUT' },
  { outcome: 'TIMEOUT' },
  { outcome: 'TIMEOUT' },
  { outcome: 'CI_GREEN' },
);
happyWorker('slow-ci');

globalThis.args = { ...baseArgs, items: [
  { slug: 'slow-ci', branch: 'build/slow-ci', title: 'Slow CI', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();

const ciBatches = callLog.filter(c => (c.opts.label||'').startsWith('ci-batch:'));
const polls = stepsRun('slow-ci').filter(k => k === 'ci-poll').length;
const probes = stepsRun('slow-ci').filter(k => k === 'merge-state').length;
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked after 5 slices: ' + JSON.stringify(result);
else if (polls !== 5) reason = 'expected 5 ci-poll slices to run, got ' + polls;
// #543 interleaving is PRESERVED: one merge-state probe immediately before EVERY slice.
else if (probes !== 5) reason = 'expected one merge-state probe per slice (5), got ' + probes;
// …but 5 slices + 5 probes cost only ceil(5/2)=3 executor spawns, not 10.
else if (ciBatches.length !== 3) reason = 'expected 3 ci-batch executors for 5 slices, got ' + ciBatches.length + ': ' + JSON.stringify(ciBatches.map(c=>c.opts.label));
else if (!(ciBatches.length < polls + probes)) reason = 'ci polling did not reduce spawns';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K942 cap invariant: no ci-batch may ask a single Bash invocation to outlive the ~10-min cap (DESIGN NOTE 2)" "
$PREAMBLE

happyMachinery('cap-item', 800, 'sha-cap');
happyWorker('cap-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'cap-item', branch: 'build/cap-item', title: 'Cap item', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
await mod.default();

const AGENT_BASH_CAP_MS = 600000; // the Bash tool's own maximum timeout
let reason = null;
const batches = callLog.filter(c => (c.opts.label||'').startsWith('ci-batch:'));
if (batches.length === 0) reason = 'no ci-batch executor observed';
for (const b of batches) {
  if (reason) break;
  const p = b.promptFull;
  // Only the emitted COMMAND body counts — the standing instruction lines above
  // it name ci-poll.sh too, and those are prose, not invocations.
  const body = p.slice(p.indexOf('\nCommand:\n'));
  // Every ci-poll.sh invocation in the batch carries its OWN short --timeout…
  const slices = (body.match(/ci-poll\.sh/g) || []).length;
  const timeouts = [...body.matchAll(/--timeout '(\\d+)'/g)].map(m => Number(m[1]));
  if (slices === 0) { reason = 'ci-batch runs no ci-poll.sh'; break; }
  if (timeouts.length !== slices) { reason = 'every ci-poll.sh slice must carry its own --timeout: ' + slices + ' slices, ' + timeouts.length + ' timeouts'; break; }
  const worst = timeouts.reduce((a, b2) => a + b2, 0) * 1000; // whole batch, worst case
  if (worst >= AGENT_BASH_CAP_MS) { reason = 'batched poll wall ' + worst + 'ms reaches the ' + AGENT_BASH_CAP_MS + 'ms Bash cap (slices=' + slices + ', timeouts=' + JSON.stringify(timeouts) + ')'; break; }
  // …and no single slice is itself a long poll.
  if (timeouts.some(t => t * 1000 >= AGENT_BASH_CAP_MS)) { reason = 'a single poll slice reaches the Bash cap: ' + JSON.stringify(timeouts); break; }
  // The Bash-tool timeout the executor is told to use must cover the poll wall
  // and still stay at or under the cap.
  const m = p.match(/\`timeout\` parameter to (\\d+)/);
  if (!m) { reason = 'ci-batch prompt does not set an explicit Bash-tool timeout — the default 120s would kill a 240s slice'; break; }
  const declared = Number(m[1]);
  if (declared > AGENT_BASH_CAP_MS) { reason = 'declared Bash timeout ' + declared + ' exceeds the cap'; break; }
  if (declared < worst) { reason = 'declared Bash timeout ' + declared + ' is under the batch poll wall ' + worst; break; }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K942 quoting: every interpolated value in a BATCHED command is still sq()-quoted" "
$PREAMBLE

// Spaced repo root / plan link / branch, and an apostrophe in the title — the
// live-probe shapes DESIGN NOTE 1 marks CRITICAL. Batching joins the same
// per-step command strings, so the quoting must survive verbatim.
const WT = '/tmp/re po.wt/q-item';
setMachinery('q-item',
  { outcome: 'CLAIMED' },
  { outcome: 'DEPS_MERGED' },
  { outcome: 'CREATED', path: WT },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-q' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-q', branch: 'feat/spaced branch' },
  { outcome: 'PR_OPENED', pr_number: 942 },
  { outcome: 'CI_GREEN' },
);
happyWorker('q-item');

globalThis.args = {
  ...baseArgs,
  repoRoot: '/tmp/re po',
  planLink: 'Plans/2026-08-01 kernel - batch machinery.md',
  board: 3,
  claimCmd: '/fake/cl aim.sh',
  machineryBinDir: '/mb dir',
  items: [
    { slug: 'q-item', branch: 'feat/spaced branch', title: \"It's a spaced title\", kind: 'impl', ghIssue: 942, acceptance: ['c'],
      dependsOn: [{ slug: 'dep', sha: 'sha dep' }] },
  ],
};

const mod = await loadLevel();
const result = await mod.default();

const pre = callLog.find(c => c.opts.label === 'prelude:q-item');
const prb = callLog.find(c => c.opts.label === 'pr-batch:q-item');
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
else if (!pre || !prb) reason = 'missing batched executor calls';
else {
  const need = [
    [pre, \"'/fake/cl aim.sh'\"],
    [pre, \"'/mb dir/worktree.sh'\"],
    [pre, \"'/tmp/re po'\"],
    [prb, \"'/mb dir/pr.sh'\"],
    [prb, \"'\" + WT + \"'\"],
    [prb, \"'feat/spaced branch'\"],
    [prb, \"'It'\\\\''s a spaced title'\"],
    [prb, \"'Plans/2026-08-01 kernel - batch machinery.md'\"],
  ];
  for (const [call, frag] of need) {
    if (!call.promptFull.includes(frag)) { reason = 'batched command lost the sq() quoting for: ' + frag; break; }
  }
  // Nothing may appear UNQUOTED: a bare spaced path in the command body would
  // split into two argv words and run the wrong command.
  if (!reason) {
    for (const [call, bare] of [[pre, ' /tmp/re po '], [prb, ' feat/spaced branch '], [pre, ' /mb dir/worktree.sh ']]) {
      if (call.promptFull.includes(bare)) { reason = 'an interpolated value appears UNQUOTED in a batched command: ' + JSON.stringify(bare); break; }
    }
  }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K942 static lockstep guards (same tail-guard idiom as the K712/K939 blocks).
# These lock the SHAPE the batching depends on so a future edit cannot silently
# regress to one-agent-per-command or break the cap derivation. -----------------
grep -q 'async function runMachineryBatch(' "$MJS" \
  || fail "#942: runMachineryBatch() missing — the batched executor bridge"
grep -q 'function batchStep(' "$MJS" \
  || fail "#942: batchStep() missing — the driver must read EACH step's own outcome object out of the batch, not a single collapsed verdict"
echo "PASS: #942 batch-bridge guard — runMachineryBatch() + per-step batchStep() accessor present"
# The three batch sites must exist by label.
for lbl in 'prelude:' 'pr-batch:' 'ci-batch:'; do
  grep -q "label: \`${lbl}" "$MJS" \
    || fail "#942: batch site '${lbl}' missing — a mechanical sequence regressed to one agent per command"
done
echo "PASS: #942 batch-site guard — prelude / pr-batch / ci-batch executors all present"
# The cap invariant is DERIVED, never a literal: the slices-per-batch count must
# be computed from the max batch wall, so retuning the slice length can't produce
# a batch that outlives the agent's Bash cap (DESIGN NOTE 2).
grep -q 'CI_POLL_SLICES_PER_BATCH = Math.max(' "$MJS" \
  || fail "#942/DESIGN NOTE 2: CI_POLL_SLICES_PER_BATCH must be DERIVED from CI_POLL_MAX_BATCH_WALL_MS, not a hardcoded count"
grep -q 'CI_POLL_MAX_BATCH_WALL_MS / (CI_POLL_SLICE_SECS \* 1000)' "$MJS" \
  || fail "#942/DESIGN NOTE 2: the slices-per-batch derivation must divide the max batch wall by the slice length"
grep -q 'AGENT_BASH_CAP_MS' "$MJS" \
  || fail "#942/DESIGN NOTE 2: AGENT_BASH_CAP_MS ceiling missing — batch timeouts must be clamped to the Bash tool's max"
echo "PASS: #942 cap-derivation guard — the CI batch's slice count is derived from the Bash-cap budget, not hardcoded"
# The branching must NOT have moved into the agent prompt (DESIGN NOTE 1's real
# invariant): every closed-outcome decision still appears as .mjs source.
for tok in "outcome === 'SCAN_BLOCKED'" "outcome === 'PUSH_REJECTED'" "outcome === 'REBASE_CONFLICT'" "outcome === 'CI_GREEN'" "outcome === 'CI_FAILED'" "outcome === 'NO_CI'" "outcome === 'TIMEOUT'" "outcome !== 'DEPS_MERGED'" "outcome !== 'CREATED'" "outcome === 'CLAIM_CONFLICT'" "outcome === 'GATE_FAIL'" "outcome !== 'EXISTS'"; do
  grep -qF "$tok" "$MJS" \
    || fail "#942: branching decision \"$tok\" is no longer in legible .mjs — a batch must never collapse decisions into an opaque agent verdict"
done
echo "PASS: #942 legibility guard — every machinery branch (SCAN_BLOCKED / PUSH_REJECTED / REBASE_CONFLICT / CI_* / DEPS_MERGED / CREATED / CLAIM_CONFLICT / GATE_FAIL / EXISTS) still lives in .mjs"

# ============================================================================
# TEST (temperloop#982): machinerySoloModel / machineryBatchModel model-tier
# overrides, plus the item.model worker seat. build.md/sweep.md/fix.md Step 0
# resolve BUILD_MACHINERY_SOLO_MODEL / BUILD_MACHINERY_BATCH_MODEL and pass
# them as input.machinerySoloModel / input.machineryBatchModel — NOT a
# config-file read from inside the .mjs (the Workflow runtime has no shell,
# DESIGN NOTE 1). Three things to prove, across THREE seats (gate: = solo
# runMachinery, prelude: = batched runMachineryBatch, worker: = item.model):
#   (a) when SET, the override reaches the spawned agent's opts.model at
#       each of the three seats;
#   (b) when UNSET (omitted from args — the default), all three seats spawn
#       at their pre-existing default — 'haiku' for gate:/prelude:, undefined
#       (inherit session) for worker: — byte-identical to before this item;
#   (c) when set to an EMPTY STRING (not omitted — the failure mode a
#       careless caller can trivially produce), all three seats STILL fall
#       back to their default, never spawn with a literal '' model. This is
#       the load-bearing case: build-level.mjs reads `|| 'haiku'` /
#       `|| undefined`, not `?? 'haiku'` / `item.model` bare, specifically so
#       an empty string collapses the same as an absent value — `??` alone
#       would let '' sail through as a literal (invalid) model name.
# ============================================================================
run_node_case "machinerySoloModel/machineryBatchModel/item.model SET → override reaches gate:/prelude:/worker: agent().opts.model (#982)" "
$PREAMBLE
happyMachinery('mtier', 270, 'sha-mtier');
happyWorker('mtier');
globalThis.args = { ...baseArgs, machinerySoloModel: 'opus', machineryBatchModel: 'sonnet', items: [
  { slug: 'mtier', branch: 'build/mtier', title: 'Mtier', kind: 'impl', acceptance: ['c'], model: 'haiku-worker-tier' },
]};
const mod = await loadLevel();
const result = await mod.default();
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
const gateCall = callLog.find(c => c.opts.label === 'gate:mtier');
const preludeCall = callLog.find(c => c.opts.label === 'prelude:mtier');
const workerCall = callLog.find(c => isWorkerCall(c.opts) && c.opts.label === 'worker:mtier');
if (!gateCall) { console.log(JSON.stringify({ ok: false, reason: 'no gate:mtier call recorded' })); process.exit(0); }
if (!preludeCall) { console.log(JSON.stringify({ ok: false, reason: 'no prelude:mtier call recorded' })); process.exit(0); }
if (!workerCall) { console.log(JSON.stringify({ ok: false, reason: 'no worker:mtier call recorded' })); process.exit(0); }
if (gateCall.opts.model !== 'opus')
  { console.log(JSON.stringify({ ok: false, reason: 'gate: (runMachinery/machinerySoloModel) opts.model=' + gateCall.opts.model + ', expected opus' })); process.exit(0); }
if (preludeCall.opts.model !== 'sonnet')
  { console.log(JSON.stringify({ ok: false, reason: 'prelude: (runMachineryBatch/machineryBatchModel) opts.model=' + preludeCall.opts.model + ', expected sonnet' })); process.exit(0); }
if (workerCall.opts.model !== 'haiku-worker-tier')
  { console.log(JSON.stringify({ ok: false, reason: 'worker: (item.model) opts.model=' + workerCall.opts.model + ', expected haiku-worker-tier' })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "machinerySoloModel/machineryBatchModel/item.model UNSET (omitted) → gate:/prelude: 'haiku', worker: undefined (inherit session), byte-identical (#982)" "
$PREAMBLE
happyMachinery('mtierdef', 271, 'sha-mtierdef');
happyWorker('mtierdef');
globalThis.args = { ...baseArgs, items: [
  { slug: 'mtierdef', branch: 'build/mtierdef', title: 'Mtierdef', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
const gateCall = callLog.find(c => c.opts.label === 'gate:mtierdef');
const preludeCall = callLog.find(c => c.opts.label === 'prelude:mtierdef');
const workerCall = callLog.find(c => isWorkerCall(c.opts) && c.opts.label === 'worker:mtierdef');
if (!gateCall || gateCall.opts.model !== 'haiku')
  { console.log(JSON.stringify({ ok: false, reason: 'gate: opts.model=' + (gateCall && gateCall.opts.model) + ', expected unchanged haiku default' })); process.exit(0); }
if (!preludeCall || preludeCall.opts.model !== 'haiku')
  { console.log(JSON.stringify({ ok: false, reason: 'prelude: opts.model=' + (preludeCall && preludeCall.opts.model) + ', expected unchanged haiku default' })); process.exit(0); }
if (!workerCall || workerCall.opts.model !== undefined)
  { console.log(JSON.stringify({ ok: false, reason: 'worker: opts.model=' + JSON.stringify(workerCall && workerCall.opts.model) + ', expected undefined (inherit session)' })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

run_node_case "machinerySoloModel/machineryBatchModel/item.model set to EMPTY STRING → all three seats still fall back to their default, never spawn at '' (#982 BLOCKING fix)" "
$PREAMBLE
happyMachinery('mtierempty', 272, 'sha-mtierempty');
happyWorker('mtierempty');
globalThis.args = { ...baseArgs, machinerySoloModel: '', machineryBatchModel: '', items: [
  { slug: 'mtierempty', branch: 'build/mtierempty', title: 'Mtierempty', kind: 'impl', acceptance: ['c'], model: '' },
]};
const mod = await loadLevel();
const result = await mod.default();
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
const gateCall = callLog.find(c => c.opts.label === 'gate:mtierempty');
const preludeCall = callLog.find(c => c.opts.label === 'prelude:mtierempty');
const workerCall = callLog.find(c => isWorkerCall(c.opts) && c.opts.label === 'worker:mtierempty');
console.log('EMPTY-STRING PROBE  gate.model=' + JSON.stringify(gateCall && gateCall.opts.model) + '  prelude.model=' + JSON.stringify(preludeCall && preludeCall.opts.model) + '  worker.model=' + JSON.stringify(workerCall && workerCall.opts.model));
if (!gateCall || gateCall.opts.model !== 'haiku')
  { console.log(JSON.stringify({ ok: false, reason: 'gate: opts.model=' + JSON.stringify(gateCall && gateCall.opts.model) + ', expected haiku (empty string must collapse to the default, not ride through as \"\")' })); process.exit(0); }
if (!preludeCall || preludeCall.opts.model !== 'haiku')
  { console.log(JSON.stringify({ ok: false, reason: 'prelude: opts.model=' + JSON.stringify(preludeCall && preludeCall.opts.model) + ', expected haiku (empty string must collapse to the default, not ride through as \"\")' })); process.exit(0); }
if (!workerCall || workerCall.opts.model !== undefined)
  { console.log(JSON.stringify({ ok: false, reason: 'worker: opts.model=' + JSON.stringify(workerCall && workerCall.opts.model) + ', expected undefined (empty string must collapse to inherit-session, not ride through as \"\")' })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# Static guard: the 'haiku' literal must remain at BOTH machinery-executor
# sites as the absent/empty-input default (epic Contract clause superseded —
# #982 acceptance). Matches the `||` form (NOT `??` — `??` does not close the
# empty-string hole the BLOCKING fix above exists to close, so a guard that
# still matched `?? 'haiku'` would silently stop guarding the real invariant).
haikuHits="$(grep -c "|| 'haiku'" "$MJS" || true)"
if [ "$haikuHits" -lt 2 ]; then
  fail "#982: expected 'haiku' literal to remain as the absent/empty-input default (via \`|| 'haiku'\`) at BOTH runMachinery/runMachineryBatch sites (found $haikuHits, want >=2)"
fi
if grep -qF "?? 'haiku'" "$MJS"; then
  fail "#982: found a lingering \`?? 'haiku'\` — this must be \`|| 'haiku'\` (the empty-string-safety BLOCKING fix); \`??\` lets an empty-string input defeat the fallback"
fi
echo "PASS: #982 haiku-literal-retained guard — found $haikuHits '|| '\''haiku'\''' fallback site(s), no lingering '?? '\''haiku'\'''"

# ============================================================================
# temperloop#1014 — machinery executors carry a LEAN context
# ============================================================================

run_node_case "K1014 lean default: every machinery executor runs as machinery-executor, with the standing contract dropped from the prompt but the #72 framing and the Bash timeout kept" "
$PREAMBLE
happyMachinery('lean1', 1014, 'sha-lean1');
happyWorker('lean1');
globalThis.args = { ...baseArgs, items: [
  { slug: 'lean1', branch: 'build/lean1', title: 'Lean', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const mach = callLog.filter(c => isMachineryCall(c.opts));
const gate = mach.find(c => c.opts.label === 'gate:lean1');
const ci = mach.find(c => (c.opts.label||'').startsWith('ci-batch:lean1'));
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked, got ' + JSON.stringify(result);
else if (mach.length === 0) reason = 'no machinery executors spawned';
else if (mach.some(c => c.opts.agentType !== 'machinery-executor')) reason = 'every machinery executor must run as machinery-executor, got ' + JSON.stringify(mach.map(c => c.opts.agentType));
// The two #72 classifier-facing framing lines survive on the lean path — the
// classifier reads the PROMPT, never the agent definition.
else if (!/^Run this single build-machinery helper command with the Bash tool, exactly as written\.$/m.test(gate.promptFull)) reason = 'lean solo prompt lost the #72 opening framing line';
else if (!/known project script/.test(gate.promptFull)) reason = 'lean solo prompt lost the #72 known-project-script framing line';
else if (!/^It is a short shell script that calls known project helper scripts/m.test(ci.promptFull)) reason = 'lean batch prompt lost the #72 framing line';
else if (!/^Steps: /m.test(ci.promptFull)) reason = 'lean batch prompt lost the Steps manifest';
// #115 stays enforced: the long-running gate still names an explicit Bash-tool timeout.
else if (!/Set the Bash tool \`timeout\` parameter to [0-9]+\./.test(gate.promptFull)) reason = 'lean solo prompt lost the explicit Bash-tool timeout instruction';
else if (!/Set the Bash tool \`timeout\` parameter to [0-9]+\./.test(ci.promptFull)) reason = 'lean batch prompt lost the explicit Bash-tool timeout instruction';
// The standing contract is gone from the prompt — it lives in the definition.
else if (/prints a SINGLE JSON line/.test(gate.promptFull)) reason = 'lean solo prompt still restates the standing JSON-line contract';
else if (/STOPS EARLY|Copy each object VERBATIM/.test(ci.promptFull)) reason = 'lean batch prompt still restates the standing verbatim/stop-early contract';
else if (!/JSON line/.test(AGENT_DEF) || !/verbatim/i.test(AGENT_DEF)) reason = 'the machinery-executor definition must carry the standing JSON-line/verbatim contract';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1014 fallback: an unresolvable machinery-executor re-issues ONCE as general-purpose with the FULL prompt, and the level completes unchanged" "
$PREAMBLE
happyMachinery('fb1', 1015, 'sha-fb1');
happyWorker('fb1');
// Simulate a checkout where the agent definition was never deployed: the runtime
// rejects the agentType at RESOLUTION time, before any subagent runs.
const origAgent = globalThis.agent;
let rejected = 0;
globalThis.agent = async function(prompt, opts = {}) {
  if (opts.agentType === 'machinery-executor') {
    rejected++;
    callLog.push({ prompt: String(prompt).slice(0,120), promptFull: String(prompt), opts: { label: opts.label, phase: opts.phase, model: opts.model, agentType: opts.agentType, rejected: true } });
    throw new Error(\"agent({agentType}): agent type 'machinery-executor' not found. Available agents: general-purpose\");
  }
  return origAgent(prompt, opts);
};
globalThis.args = { ...baseArgs, items: [
  { slug: 'fb1', branch: 'build/fb1', title: 'Fallback', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const served = callLog.filter(c => isMachineryCall(c.opts) && !c.opts.rejected);
const gate = served.find(c => c.opts.label === 'gate:fb1');
const ci = served.find(c => (c.opts.label||'').startsWith('ci-batch:fb1'));
let reason = null;
if ((result.parked ?? []).length !== 1 || result.parked[0].pr !== 1015) reason = 'the level must complete unchanged under fallback: ' + JSON.stringify(result);
// Sticky: exactly ONE rejected probe for the whole level, not one per call.
else if (rejected !== 1) reason = 'the unavailable agent type must be probed once and then pinned, got ' + rejected + ' rejections';
else if (served.some(c => c.opts.agentType !== 'general-purpose')) reason = 'every served machinery call must fall back to general-purpose, got ' + JSON.stringify(served.map(c => c.opts.agentType));
// The fallback prompt restates the standing contract, exactly as before #1014.
else if (!/prints a SINGLE JSON line/.test(gate.promptFull)) reason = 'fallback solo prompt must restate the standing JSON-line contract';
else if (!/STOPS EARLY/.test(ci.promptFull) || !/Copy each object VERBATIM/.test(ci.promptFull)) reason = 'fallback batch prompt must restate the standing stop-early/verbatim contract';
else if (!/This command runs longer than usual/.test(gate.promptFull)) reason = 'fallback solo prompt must restate the long-form #115 timeout instruction';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1014 narrow catch: a NON-resolution executor failure propagates — the fallback never re-runs a machinery command" "
$PREAMBLE
happyMachinery('nar1', 1017, 'sha-nar1');
happyWorker('nar1');
// A mid-agent failure (the #939 StructuredOutput-cap shape): the subagent DID
// run, so re-issuing the command under another agent type would re-execute a
// non-idempotent machinery step. It must propagate, not fall back.
const origAgent = globalThis.agent;
let attempts = 0;
globalThis.agent = async function(prompt, opts = {}) {
  if (isMachineryCall(opts)) {
    attempts++;
    callLog.push({ prompt: '', promptFull: String(prompt), opts: { label: opts.label, phase: opts.phase, agentType: opts.agentType } });
    throw new Error('agent({schema}): StructuredOutput retry cap (3) exceeded');
  }
  return origAgent(prompt, opts);
};
globalThis.args = { ...baseArgs, items: [
  { slug: 'nar1', branch: 'build/nar1', title: 'Narrow', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if (attempts !== 1) reason = 'a non-resolution failure must NOT be retried under another agent type, got ' + attempts + ' machinery attempts';
else if ((result.escalations ?? []).length !== 1 || result.escalations[0].kind !== 'worker-error') reason = 'the throw must surface as a worker-error escalation: ' + JSON.stringify(result);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1014 pin: input.machineryAgentType='general-purpose' reproduces the pre-#1014 executor prompts byte-identically, with no probe spawn" "
$PREAMBLE
happyMachinery('pin1', 1016, 'sha-pin1');
happyWorker('pin1');
globalThis.args = { ...baseArgs, machineryAgentType: 'general-purpose', items: [
  { slug: 'pin1', branch: 'build/pin1', title: 'Pin', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const mach = callLog.filter(c => isMachineryCall(c.opts));
const gate = mach.find(c => c.opts.label === 'gate:pin1');
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked, got ' + JSON.stringify(result);
else if (mach.some(c => c.opts.agentType !== 'general-purpose')) reason = 'an explicit pin must be honoured with no lean attempt, got ' + JSON.stringify(mach.map(c => c.opts.agentType));
else if (!/prints a SINGLE JSON line/.test(gate.promptFull) || !/This command runs longer than usual/.test(gate.promptFull)) reason = 'a pinned general-purpose run must send the full pre-#1014 prompt';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# Static guard: the executor agent definition must stay Bash-only — the whole
# context win is the tool surface it does NOT carry, and a widened `tools:` line
# silently gives it back (plus hands a mechanical executor the file-editing
# powers the bridge deliberately does not want it to have).
defTools="$(awk '/^---$/{n++; next} n==1 && /^tools:/' "$AGENT_DEF" | head -1)"
if [ "$defTools" != "tools: Bash" ]; then
  fail "#1014: claude/agents/machinery-executor.md must declare exactly 'tools: Bash' (found: '${defTools:-<none>}')"
fi
# Exactly ONE `agentType: 'general-purpose'` may remain — machineryAgent()'s
# fallback re-issue. A second one is an executor call site that bypassed the
# resolved type and would keep paying the full-context spawn forever.
gpHits="$(grep -c "agentType: 'general-purpose'" "$MJS" || true)"
if [ "$gpHits" -ne 1 ]; then
  fail "#1014: expected exactly 1 \`agentType: 'general-purpose'\` (machineryAgent()'s fallback re-issue), found $gpHits — every executor call site must route through machineryAgent()'s resolved type"
fi
echo "PASS: #1014 lean-executor guards — machinery-executor is Bash-only; the only general-purpose executor type is machineryAgent()'s fallback"

# ============================================================================
# TEST (temperloop#852): cross-repo `Closes` qualification. build.md 3f's
# "Cross-repo `repo:` honor point" requires a fully-qualified `owner/repo#N`
# Closes ref whenever an item's `gh_issue:`/`also_closes:` numbers are tracked
# in a DIFFERENT repo than the one the PR opens against — pr.sh itself already
# handles either shape verbatim (closes_line()/validate_issue()); the defect
# was build-level.mjs always passing the bare number to --gh-issue/
# --also-closes regardless of `item.repo`. Three items, one level:
#   - 'same-repo'  — no `repo:` field  → bare Closes #N (unchanged default)
#   - 'same-explicit' — `repo:` EQUAL to ownerRepo → still bare (exact-match,
#     not merely "repo: present")
#   - 'cross-repo' — `repo:` DIFFERENT from ownerRepo → qualified
#     `owner/repo#N` on BOTH --gh-issue and --also-closes
# ============================================================================
run_node_case "temperloop#852: item.repo != ownerRepo qualifies --gh-issue/--also-closes as owner/repo#N; same-repo (absent or equal repo:) stays bare" "
$PREAMBLE
happyMachinery('same-repo', 852, 'sha-same');
happyMachinery('same-explicit', 853, 'sha-same2');
happyMachinery('cross-repo', 854, 'sha-cross');
happyWorker('same-repo');
happyWorker('same-explicit');
happyWorker('cross-repo');

globalThis.args = { ...baseArgs, items: [
  { slug: 'same-repo', branch: 'build/same-repo', title: 'Same Repo', kind: 'impl', acceptance: ['c'],
    ghIssue: 500, alsoCloses: [501, 502] },
  { slug: 'same-explicit', branch: 'build/same-explicit', title: 'Same Explicit', kind: 'impl', acceptance: ['c'],
    repo: 'owner/repo', ghIssue: 550, alsoCloses: [551] },
  { slug: 'cross-repo', branch: 'build/cross-repo', title: 'Cross Repo', kind: 'impl', acceptance: ['c'],
    repo: 'other/repo', ghIssue: 600, alsoCloses: [601, 602] },
]};

const mod = await loadLevel();
const result = await mod.default();

let reason = null;
if ((result.parked ?? []).length !== 3) reason = 'expected 3 parked: ' + JSON.stringify(result);
if (!reason) {
  const sameCall = callLog.find(c => c.opts.label === 'pr-batch:same-repo');
  const sameExplicitCall = callLog.find(c => c.opts.label === 'pr-batch:same-explicit');
  const crossCall = callLog.find(c => c.opts.label === 'pr-batch:cross-repo');
  if (!sameCall || !sameExplicitCall || !crossCall) { reason = 'missing pr-batch executor call(s)'; }
  else {
    // The qualifier is ownerRepo (the plan's HOME repo, where the issue was
    // triaged) — NOT item.repo (the repo the PR opens against). See the #852
    // build.md 3f honor-point rationale quoted at the .mjs call site.
    const checks = [
      [sameCall, \"--gh-issue '500'\", true],
      [sameCall, \"--also-closes '501,502'\", true],
      [sameCall, \"'owner/repo#\", false],
      [sameExplicitCall, \"--gh-issue '550'\", true],
      [sameExplicitCall, \"--also-closes '551'\", true],
      [sameExplicitCall, \"'owner/repo#\", false],
      [crossCall, \"--gh-issue 'owner/repo#600'\", true],
      [crossCall, \"--also-closes 'owner/repo#601,owner/repo#602'\", true],
      [crossCall, \"--gh-issue '600'\", false],
    ];
    for (const [call, frag, want] of checks) {
      const has = call.promptFull.includes(frag);
      if (has !== want) { reason = (want ? 'missing expected ' : 'unexpectedly found ') + JSON.stringify(frag) + ' in ' + call.opts.label; break; }
    }
  }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST: temperloop#1071 — the machinery-step WALL-CLOCK LIVENESS BOUND.
#
# The incident: a `pr-batch` machinery agent ran 35,362,333ms (9h49m) on TWO
# tool calls. One Bash invocation blocked and then completed successfully (all
# four steps green, the PR opened). The Bash tool's own `timeout` is capped at
# 600,000ms, so a 9.8h call is supposed to be unreachable — it did not fire, and
# nothing else bounded the call.
#
# The seam under test is deliberately ROOT-CAUSE-AGNOSTIC (the stall's cause is
# NOT established): a per-step ceiling compiled into the emitted shell, plus a
# disposal that treats a bounded-out step as LOST and routes it through the
# EXISTING pr.sh recover-probe rather than re-issuing a non-idempotent command.
# ============================================================================

run_node_case "K1071 adopt: a timed-out pr-batch step whose PR already opened is ADOPTED, never re-opened" "
$PREAMBLE
// The #1071 shape exactly: the batch's push step outlives the ceiling and is
// killed, but the work in fact LANDED (this is what the real incident did — the
// 9h49m call opened PR #1070). recover-probe sees the open PR, so the item must
// adopt it and flow on to CI — never re-push, never re-open.
setMachinery('to-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/to-item' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-to' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'STEP_TIMEOUT', step: 'push', ceiling_secs: 900, elapsed_secs: 35362 },
  { outcome: 'RECOVER_PR_OPEN', pr_number: 1070, sha: 'sha-to', pushed: true, verification_surface_present: true },
  { outcome: 'CI_GREEN' },
);
happyWorker('to-item');
globalThis.args = { ...baseArgs, items: [{ slug: 'to-item', branch: 'b/to', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const steps = stepsRun('to-item');
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'a recoverable step timeout must NOT escalate: ' + JSON.stringify(result.escalations);
else if (parked.length !== 1) reason = 'expected the item to park on the adopted PR: ' + JSON.stringify(result);
else if (parked[0].pr !== 1070) reason = 'must park on the PR the timed-out step actually opened, got ' + parked[0].pr;
else if (steps.includes('pr-open')) reason = 'DOUBLE-OPEN: pr-open ran after the batch was bounded out at push';
else if (!callLog.some(c => c.opts.label === 'recover-probe:to-item')) reason = 'disposal must go through the EXISTING pr.sh recover-probe path';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1071 escalate: a timed-out step with NO landed side-effect escalates machinery-step-timeout, never retries" "
$PREAMBLE
setMachinery('to2',
  { outcome: 'CREATED', path: '/tmp/repo.wt/to2' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha2' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'STEP_TIMEOUT', step: 'push', ceiling_secs: 900, elapsed_secs: 901 },
  noSideEffects(),
);
happyWorker('to2');
globalThis.args = { ...baseArgs, items: [{ slug: 'to2', branch: 'b/to2', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const esc = (result.escalations ?? [])[0];
const steps = stepsRun('to2');
let reason = null;
if (!esc) reason = 'expected an escalation: ' + JSON.stringify(result);
else if (esc.kind !== 'machinery-step-timeout') reason = 'wrong escalation kind: ' + esc.kind;
else if (esc.payload.step !== 'push') reason = 'the payload must name WHICH step the ceiling bounded, got ' + JSON.stringify(esc.payload.step);
else if (esc.payload.probeStage !== 'RECOVER_NONE') reason = 'the payload must carry the recover-probe verdict, got ' + JSON.stringify(esc.payload.probeStage);
else if (steps.filter(k => k === 'push').length !== 1) reason = 'BLIND RETRY: push ran more than once';
else if (steps.includes('pr-open')) reason = 'pr-open must not run after a bounded-out push';
else if ((result.parked ?? []).length !== 0) reason = 'a bounded-out step must never park as though it succeeded';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1071 notice: a STEP_SLOW advisory is logged and PARTITIONED OUT — step indices must not shift" "
$PREAMBLE
// STEP_SLOW rides ALONGSIDE a real result, so if it were left in the results
// array every later step's index would shift by one and the driver would branch
// on the wrong object (here: 'scan' would read the notice and escalate
// scan-error). The item parking green IS the assertion.
const logged = [];
globalThis.log = (m) => logged.push(String(m));
globalThis.agent = async (prompt, opts = {}) => {
  const label = opts.label || '';
  if (isWorkerCall(opts)) return { status: 'done', summary: 's', acceptance_results: [], commits: [] };
  if (label.startsWith('prelude:')) return { results: [{ outcome: 'CREATED', path: '/tmp/repo.wt/sl' }] };
  if (label.startsWith('review-diff:')) return { outcome: 'REVIEW_DIFF', files: [] };
  if (label.startsWith('gate:')) return { outcome: 'GATE_PASS' };
  if (label.startsWith('pr-batch:')) return { results: [
    { outcome: 'REBASED', sha: 'x' },
    { outcome: 'STEP_SLOW', step: 'rebase', elapsed_secs: 420, slow_secs: 300, ceiling_secs: 900 },
    { outcome: 'SCAN_CLEAN' },
    { outcome: 'PUSHED', sha: 'x' },
    { outcome: 'PR_OPENED', pr_number: 77 },
  ] };
  if (label.startsWith('ci-batch:')) return { results: [{ mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN' }, { outcome: 'CI_GREEN' }] };
  return null;
};
globalThis.args = { ...baseArgs, items: [{ slug: 'sl', branch: 'b/sl', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'the advisory leaked into the results array and shifted the step indices: ' + JSON.stringify(result.escalations);
else if ((result.parked ?? [])[0]?.pr !== 77) reason = 'expected a clean park on PR 77: ' + JSON.stringify(result);
else if (!logged.some(m => /machinery step 'rebase' took 420s/.test(m))) reason = 'the slow step must emit an observable log() progress notice; logged: ' + JSON.stringify(logged);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1071 setting: input.machineryStepCeilingSecs drives the ceiling and is floored, never below one slice" "
$PREAMBLE
// The ceiling reaches the emitted command text (it is a SHELL variable there —
// this runtime has no Date.now() to measure with), and a too-small operator
// value is floored rather than honoured: a ceiling under one legitimate slice
// would manufacture false timeouts on healthy work, which is worse than the
// stall it bounds.
const seen = [];
globalThis.agent = async (prompt, opts = {}) => {
  seen.push({ label: opts.label, prompt: String(prompt) });
  if (isWorkerCall(opts)) return { status: 'done', summary: 's', acceptance_results: [], commits: [] };
  const l = opts.label || '';
  if (l.startsWith('prelude:')) return { results: [{ outcome: 'CREATED', path: '/tmp/repo.wt/c' }] };
  if (l.startsWith('review-diff:')) return { outcome: 'REVIEW_DIFF', files: [] };
  if (l.startsWith('gate:')) return { outcome: 'GATE_PASS' };
  if (l.startsWith('pr-batch:')) return { results: [{ outcome: 'REBASED', sha: 'x' }, { outcome: 'SCAN_CLEAN' }, { outcome: 'PUSHED', sha: 'x' }, { outcome: 'PR_OPENED', pr_number: 9 }] };
  if (l.startsWith('ci-batch:')) return { results: [{ mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN' }, { outcome: 'CI_GREEN' }] };
  return null;
};
globalThis.args = { ...baseArgs, machineryStepCeilingSecs: 4321, items: [{ slug: 'c', branch: 'b/c', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
await mod.default();
const prb = seen.find(c => (c.label || '').startsWith('pr-batch:'));
let reason = null;
if (!prb) reason = 'no pr-batch call';
else if (!/__lb_ceil=4321\b/.test(prb.prompt)) reason = 'the orchestrator-supplied ceiling did not reach the emitted command text';
else if (!/__lb\(\) \{/.test(prb.prompt)) reason = 'the emitted command carries no watchdog at all';
else {
  // Second load: a 1-second ceiling must be FLOORED, not honoured.
  seen.length = 0;
  globalThis.args = { ...baseArgs, machineryStepCeilingSecs: 1, items: [{ slug: 'c', branch: 'b/c', title: 'T', kind: 'impl', acceptance: ['c'] }] };
  const mod2 = await loadLevel();
  await mod2.default();
  const prb2 = seen.find(c => (c.label || '').startsWith('pr-batch:'));
  const m = /__lb_ceil=([0-9]+)/.exec(prb2 ? prb2.prompt : '');
  if (!m) reason = 'no ceiling in the second run';
  else if (Number(m[1]) < 300) reason = 'a 1s operator ceiling was honoured instead of floored (got ' + m[1] + 's) — that manufactures false timeouts';
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1071 EMITTED-SHELL behavioural probe -------------------------------------
# The bound is enforced by shell the .mjs GENERATES, so asserting on the .mjs
# alone would prove nothing about whether it actually bounds anything. Generate
# the real preamble from the real source and RUN it.
_lb_gen="$WF_TEST_TMPDIR/lb-gen.mjs"
cat > "$_lb_gen" <<'LBGEN'
import { readFileSync, writeFileSync } from 'fs';
globalThis.args = JSON.stringify({ repoRoot: '/tmp/repo', ownerRepo: 'o/r', items: [] });
globalThis.agent = async () => null;
globalThis.log = () => {};
globalThis.phase = () => {};
globalThis.parallel = async (fns) => Promise.all(fns.map(f => f()));
const src = readFileSync(process.env.MJS_PATH, 'utf8')
  .replace(/^export const meta/m, 'const meta')
  .replace('const GATE_MAX_SLICES = 8;',
    'const GATE_MAX_SLICES = 8;\nglobalThis.__p = { pre: stepBoundPreamble, def: stepFnDef, inv: stepBoundInvoke, batch: batchCommand };');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
await new AsyncFunction(src)();
const P = globalThis.__p;
const out = process.env.LB_OUT;
// A step that BLOCKS forever, under a 2s ceiling (the preamble's own ceiling is
// rewritten below — the point is the watchdog's behaviour, not its budget).
writeFileSync(out + '/stall.sh', [P.pre(0), P.def('__s0', "sleep 60; printf '{\"outcome\":\"PUSHED\"}\\n'"), P.inv('__s0', 'push')].join('\n'));
// A fast step: must NOT be delayed by the watchdog (the #861 pipe-leak trap).
writeFileSync(out + '/fast.sh', [P.pre(0), P.def('__s0', "printf '{\"outcome\":\"PUSHED\",\"sha\":\"abc\"}\\n'"), P.inv('__s0', 'push')].join('\n'));
// A batch whose SECOND step stalls: the third step must never run.
writeFileSync(out + '/batch.sh', P.batch([
  { kind: 'scan', cmd: "printf '{\"outcome\":\"SCAN_CLEAN\"}\\n'", continueOutcomes: ['SCAN_CLEAN'] },
  { kind: 'push', cmd: "sleep 60; printf '{\"outcome\":\"PUSHED\"}\\n'", continueOutcomes: ['PUSHED'] },
  { kind: 'pr-open', cmd: "printf '{\"outcome\":\"PR_OPENED\",\"pr_number\":7}\\n'" },
]));
LBGEN
_lb_out="$WF_TEST_TMPDIR/lb"; mkdir -p "$_lb_out"
MJS_PATH="$MJS" LB_OUT="$_lb_out" node "$_lb_gen" \
  || fail "#1071: could not generate the emitted watchdog shell from build-level.mjs"
# Ceilings are rewritten PER PROBE, and the two numbers differ on purpose
# (temperloop#1367):
#   • the two STALL probes get a 2s ceiling, which their 60s stall body outruns
#     by 30x — the stall's verdict is read off the bound's OWN payload below, so
#     the ceiling only has to be small enough to keep the probe quick.
#   • the FAST probe gets a deliberately LARGE ceiling. The #861 pipe leak's
#     signature is that a healthy step's capture stalls for the WHOLE ceiling, so
#     the ceiling IS the separation between the passing and failing cases: at 2s
#     those two were one scheduling hiccup apart on a loaded runner. 30s against
#     the 10s assertion below leaves a healthy step ~10x of headroom while a leak
#     still misses by 3x — a wider gap, not a looser bound.
for _f in stall.sh batch.sh; do
  sed 's/^__lb_ceil=[0-9]*/__lb_ceil=2/' "$_lb_out/$_f" > "$_lb_out/t-$_f"
done
sed 's/^__lb_ceil=[0-9]*/__lb_ceil=30/' "$_lb_out/fast.sh" > "$_lb_out/t-fast.sh"
for _f in stall.sh fast.sh batch.sh; do
  bash -n "$_lb_out/t-$_f" || fail "#1071: the emitted watchdog shell is not valid bash ($_f)"
done

# NB `|| true`: a bounded-out step exits 137 BY CONTRACT (the watchdog SIGKILLs
# it), and this suite runs under `set -e` — without the guard the suite itself
# would die with the very exit code the feature is supposed to produce.
#
# NB the stall probe is read from a FILE, never a `$( … )` capture, and its
# verdict is the bound's OWN payload rather than this harness's wall clock
# (temperloop#1367). What the bound promises is that the WORKFLOW stops waiting
# on a stalled step at the ceiling; it explicitly does NOT promise that every
# descendant dies with it — the kill is best-effort DEEP, and a deeper grandchild
# that outlives it is disposed through the recover-probe instead (see
# stepBoundPreamble's own header in build-level.mjs). A command substitution
# reads until EOF, so ONE surviving grandchild holding the inherited pipe
# write-end makes the harness wait out the entire 60s stall even though the step
# was killed on time — which is exactly what a loaded 4-worker CI runner produced
# (60s observed, while the bound had reported STEP_TIMEOUT at elapsed_secs=2).
# Reading `elapsed_secs` — the field the driver itself consumes — measures the
# bound; timing the capture measures a descendant's lifetime.
bash "$_lb_out/t-stall.sh" >"$_lb_out/stall.out" 2>/dev/null || true
_lb_stall="$(cat "$_lb_out/stall.out")"
case "$_lb_stall" in
  *'"outcome":"STEP_TIMEOUT"'*) : ;;
  *) fail "#1071: a bounded-out step must report STEP_TIMEOUT, got: $_lb_stall" ;;
esac
case "$_lb_stall" in
  *'"outcome":"PUSHED"'*) fail "#1071: the killed step still printed a result the driver would have believed: $_lb_stall" ;;
esac
case "$_lb_stall" in
  *'"ceiling_secs":2'*) : ;;
  *) fail "#1071: the STEP_TIMEOUT payload must name the ceiling it enforced, got: $_lb_stall" ;;
esac
_lb_bounded_at="$(printf '%s' "$_lb_stall" | sed -n 's/.*"elapsed_secs":\([0-9][0-9]*\).*/\1/p')"
[ -n "$_lb_bounded_at" ] \
  || fail "#1071: the STEP_TIMEOUT payload carries no elapsed_secs — that field IS the bound's observable: $_lb_stall"
[ "$_lb_bounded_at" -ge 2 ] \
  || fail "#1071: a STEP_TIMEOUT reporting elapsed_secs=${_lb_bounded_at} below its own 2s ceiling is not a timeout: $_lb_stall"
[ "$_lb_bounded_at" -lt 20 ] \
  || fail "#1071: a stalled step was NOT bounded at its ceiling — the watchdog let it run ${_lb_bounded_at}s against a 2s ceiling (this is the 9h49m bug)"
echo "PASS: K1071 emitted shell: a stalled step is killed at the ceiling and reports STEP_TIMEOUT, not a result"

# The fast path must be FAST: portable-timeout.sh's #861 pipe-leak (the watchdog's
# `sleep` grandchild holding the caller's `$( … )` pipe open) turns every quick,
# successful step into a full-ceiling stall. Regression-guard it directly — and
# here the `$( … )` capture IS the point, since the caller's pipe is what the leak
# holds open.
_lb_start=$(date +%s)
_lb_fast="$(bash "$_lb_out/t-fast.sh" 2>/dev/null || true)"
_lb_elapsed=$(( $(date +%s) - _lb_start ))
[ "$_lb_elapsed" -lt 10 ] \
  || fail "#1071: a FAST step took ${_lb_elapsed}s under a 30s ceiling — the watchdog is holding the pipe open (#861 pipe-leak regression)"
case "$_lb_fast" in
  '{"outcome":"PUSHED","sha":"abc"}') : ;;
  *) fail "#1071: a healthy step's output must pass through byte-identically, got: $_lb_fast" ;;
esac
echo "PASS: K1071 emitted shell: a healthy step is neither delayed nor altered by the bound"

_lb_batch="$(bash "$_lb_out/t-batch.sh" 2>/dev/null || true)"
case "$_lb_batch" in
  *'"outcome":"PR_OPENED"'*) fail "#1071: DOUBLE-OPEN — pr-open ran after the batch was bounded out at push: $_lb_batch" ;;
esac
case "$_lb_batch" in
  *'"outcome":"STEP_TIMEOUT","step":"push"'*) : ;;
  *) fail "#1071: the batch must stop at the timed-out step and name it, got: $_lb_batch" ;;
esac
echo "PASS: K1071 emitted shell: a bounded-out batch step stops the sequence — no step after it runs"

# --- K1071 static lockstep guards ---------------------------------------------
grep -q 'input.machineryStepCeilingSecs' "$MJS" \
  || fail "#1071: build-level.mjs must read the step ceiling from the orchestrator hand-off (input.machineryStepCeilingSecs), not a bare literal"
grep -q 'function stepBoundPreamble(' "$MJS" \
  || fail "#1071: the emitted-shell watchdog (stepBoundPreamble) is missing — the bound would live only in the Bash tool timeout that already failed to fire"
grep -q 'async function disposeStepTimeout(' "$MJS" \
  || fail "#1071: disposeStepTimeout() missing — a bounded-out step has no disposal"
grep -q "recover-probe \${sq(wt)}" "$MJS" \
  || fail "#1071: the timeout disposal must reuse the EXISTING pr.sh recover-probe path, not invent a second one"
_cfg1071="$REPO_ROOT/workflows/scripts/build/build.config.sh"
for _s in BUILD_MACHINERY_STEP_CEILING_SECS BUILD_MACHINERY_STEP_SLOW_SECS; do
  grep -q "$_s" "$_cfg1071" \
    || fail "#1071: $_s must be declared in build.config.sh (the named-setting seam)"
  for _md in build sweep fix; do
    grep -q "$_s" "$REPO_ROOT/claude/commands/$_md.md" \
      || fail "#1071: $_md.md Step 0 must resolve $_s (every build-level.mjs caller wires it, not /build alone)"
  done
done
for _md in build sweep fix; do
  grep -q 'machineryStepCeilingSecs' "$REPO_ROOT/claude/commands/$_md.md" \
    || fail "#1071: $_md.md must pass machineryStepCeilingSecs in its build-level.mjs args"
done
echo "PASS: #1071 liveness-bound guard — named settings, emitted watchdog, recover-probe disposal, all three callers wired"

# ============================================================================
# TEMPERLOOP#1067 — probe for a LOST pr-batch return before escalating it as a
# failure. Distinct from #1071 (a liveness-KILL): here every step in the batch
# through the one under test has ALREADY been confirmed successful, and the
# batch's own JSON line for the very next step was simply dropped
# (batchStep()'s 'produced no result' sentinel) — not timed out, not a
# short-circuit. lostReturn() (see the PREAMBLE mock) models exactly that: the
# step's machineryStepLog entry is recorded (it ran) but no results[] entry is
# pushed for it.
#
# The four-rung disposition (the EXISTING probeSideEffects/RECOVER_* ladder,
# not a new one): RECOVER_PR_OPEN → adopt; RECOVER_PUSHED → resume at pr-open;
# RECOVER_COMMITTED → resume at push; RECOVER_NONE → escalate unchanged. Rungs
# are exercised at BOTH the push-error site and the pr-open-failed site. A
# genuine (non-sentinel) failure at either site must escalate immediately with
# NO probe call — the load-bearing negative case.
# ============================================================================

run_node_case "K1067 push/RECOVER_PR_OPEN: a LOST push-batch return whose PR already opened is ADOPTED, never re-pushed/re-opened" "
$PREAMBLE
setMachinery('lost-push-adopt',
  { outcome: 'CREATED', path: '/tmp/repo.wt/lost-push-adopt' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-lp' },
  { outcome: 'SCAN_CLEAN' },
  lostReturn(),
  { outcome: 'RECOVER_PR_OPEN', pr_number: 5001, sha: 'sha-lp', pushed: true, verification_surface_present: true },
  { outcome: 'CI_GREEN' },
);
happyWorker('lost-push-adopt');
globalThis.args = { ...baseArgs, items: [{ slug: 'lost-push-adopt', branch: 'b/lp', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const steps = stepsRun('lost-push-adopt');
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'a recoverable lost push return must NOT escalate: ' + JSON.stringify(result.escalations);
else if (parked.length !== 1) reason = 'expected the item to park on the adopted PR: ' + JSON.stringify(result);
else if (parked[0].pr !== 5001) reason = 'must park on the PR recover-probe actually found, got ' + parked[0].pr;
else if (steps.includes('pr-open')) reason = 'DOUBLE-OPEN: pr-open ran even though the probe adopted an existing PR';
else if (steps.filter(s => s === 'push').length !== 1) reason = 'DOUBLE-PUSH: push must run exactly once, got ' + steps.filter(s => s === 'push').length;
else if (!callLog.some(c => c.opts.label === 'recover-probe:lost-push-adopt')) reason = 'must probe via the EXISTING pr.sh recover-probe path';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1067 push/RECOVER_PUSHED: resumes at pr-open only, no re-push" "
$PREAMBLE
setMachinery('lost-push-resume-open',
  { outcome: 'CREATED', path: '/tmp/repo.wt/lost-push-resume-open' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-rp' },
  { outcome: 'SCAN_CLEAN' },
  lostReturn(),
  { outcome: 'RECOVER_PUSHED', sha: 'sha-rp', pushed: true, remote_sha: 'sha-rp', verification_surface_present: true },
  { outcome: 'PR_OPENED', pr_number: 5002 },
  { outcome: 'CI_GREEN' },
);
happyWorker('lost-push-resume-open');
globalThis.args = { ...baseArgs, items: [{ slug: 'lost-push-resume-open', branch: 'b/rp', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const steps = stepsRun('lost-push-resume-open');
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'RECOVER_PUSHED must resume, not escalate: ' + JSON.stringify(result.escalations);
else if (parked.length !== 1) reason = 'expected the item to park on the resumed PR: ' + JSON.stringify(result);
else if (parked[0].pr !== 5002) reason = 'must park on the PR the resumed pr-open step opened, got ' + parked[0].pr;
else if (parked[0].pushed_sha !== 'sha-rp') reason = 'pushed_sha must come from the probe (already-pushed sha), got ' + parked[0].pushed_sha;
else if (steps.filter(s => s === 'push').length !== 1) reason = 'RECOVER_PUSHED must NOT re-push, got push count ' + steps.filter(s => s === 'push').length;
else if (steps.filter(s => s === 'pr-open').length !== 1) reason = 'must resume at pr-open exactly once, got ' + steps.filter(s => s === 'pr-open').length;
else if (!callLog.some(c => c.opts.label === 'recover-probe:lost-push-resume-open')) reason = 'must probe via the EXISTING pr.sh recover-probe path';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1067 push/RECOVER_COMMITTED: resumes at push then pr-open, no re-rebase" "
$PREAMBLE
setMachinery('lost-push-resume-both',
  { outcome: 'CREATED', path: '/tmp/repo.wt/lost-push-resume-both' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-rc' },
  { outcome: 'SCAN_CLEAN' },
  lostReturn(),
  { outcome: 'RECOVER_COMMITTED', sha: 'sha-rc', pushed: false, verification_surface_present: false },
  { outcome: 'PUSHED', sha: 'sha-rc2', branch: 'b/rc' },
  { outcome: 'PR_OPENED', pr_number: 5003 },
  { outcome: 'CI_GREEN' },
);
happyWorker('lost-push-resume-both');
globalThis.args = { ...baseArgs, items: [{ slug: 'lost-push-resume-both', branch: 'b/rc', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const steps = stepsRun('lost-push-resume-both');
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'RECOVER_COMMITTED must resume, not escalate: ' + JSON.stringify(result.escalations);
else if (parked.length !== 1) reason = 'expected the item to park on the resumed PR: ' + JSON.stringify(result);
else if (parked[0].pr !== 5003) reason = 'must park on the PR the resumed pr-open step opened, got ' + parked[0].pr;
else if (parked[0].pushed_sha !== 'sha-rc2') reason = 'pushed_sha must come from the RESUMED push (fresh ground truth), got ' + parked[0].pushed_sha;
else if (steps.filter(s => s === 'rebase').length !== 1) reason = 'RECOVER_COMMITTED must NOT re-rebase, got rebase count ' + steps.filter(s => s === 'rebase').length;
else if (steps.filter(s => s === 'push').length !== 2) reason = 'must resume at push (original lost attempt + one resumed push), got ' + steps.filter(s => s === 'push').length;
else if (steps.filter(s => s === 'pr-open').length !== 1) reason = 'must open exactly once via the resume batch, got ' + steps.filter(s => s === 'pr-open').length;
else if (!callLog.some(c => c.opts.label === 'recover-probe:lost-push-resume-both')) reason = 'must probe via the EXISTING pr.sh recover-probe path';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1067 push/RECOVER_NONE: a lost push return with nothing landed escalates push-error, unchanged" "
$PREAMBLE
setMachinery('lost-push-none',
  { outcome: 'CREATED', path: '/tmp/repo.wt/lost-push-none' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-ln' },
  { outcome: 'SCAN_CLEAN' },
  lostReturn(),
  noSideEffects(),
);
happyWorker('lost-push-none');
globalThis.args = { ...baseArgs, items: [{ slug: 'lost-push-none', branch: 'b/ln', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const escalations = result.escalations ?? [];
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'RECOVER_NONE must not park: ' + JSON.stringify(result.parked);
else if (escalations.length !== 1) reason = 'expected exactly 1 escalation, got ' + JSON.stringify(escalations);
else if (escalations[0].kind !== 'push-error') reason = 'wrong escalation kind: ' + escalations[0].kind;
else if (!callLog.some(c => c.opts.label === 'recover-probe:lost-push-none')) reason = 'RECOVER_NONE must still have been reached via the EXISTING recover-probe path';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1067 push negative: a GENUINE push failure (not a lost return) escalates immediately with NO probe call" "
$PREAMBLE
setMachinery('genuine-push-fail',
  { outcome: 'CREATED', path: '/tmp/repo.wt/genuine-push-fail' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-gp' },
  { outcome: 'SCAN_CLEAN' },
  // A REAL pr.sh die() — a genuine failure, NOT the batchStep sentinel.
  { outcome: 'ERROR', error: 'git push: remote end hung up unexpectedly' },
);
happyWorker('genuine-push-fail');
globalThis.args = { ...baseArgs, items: [{ slug: 'genuine-push-fail', branch: 'b/gp', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const escalations = result.escalations ?? [];
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'a genuine push failure must not park: ' + JSON.stringify(result.parked);
else if (escalations.length !== 1) reason = 'expected exactly 1 escalation, got ' + JSON.stringify(escalations);
else if (escalations[0].kind !== 'push-error') reason = 'wrong escalation kind: ' + escalations[0].kind;
else if (callLog.some(c => c.opts.label === 'recover-probe:genuine-push-fail')) reason = 'a GENUINE failure must NEVER be routed through recover-probe — this would silently convert it into a possible adoption';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1067 pr-open/RECOVER_PR_OPEN: a LOST pr-open-batch return whose PR already opened is ADOPTED, never re-opened" "
$PREAMBLE
setMachinery('lost-open-adopt',
  { outcome: 'CREATED', path: '/tmp/repo.wt/lost-open-adopt' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-lo' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-lo', branch: 'b/lo' },
  lostReturn(),
  { outcome: 'RECOVER_PR_OPEN', pr_number: 5004, sha: 'sha-lo', pushed: true, verification_surface_present: true },
  { outcome: 'CI_GREEN' },
);
happyWorker('lost-open-adopt');
globalThis.args = { ...baseArgs, items: [{ slug: 'lost-open-adopt', branch: 'b/lo', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const steps = stepsRun('lost-open-adopt');
let reason = null;
if ((result.escalations ?? []).length !== 0) reason = 'a recoverable lost pr-open return must NOT escalate: ' + JSON.stringify(result.escalations);
else if (parked.length !== 1) reason = 'expected the item to park on the adopted PR: ' + JSON.stringify(result);
else if (parked[0].pr !== 5004) reason = 'must park on the PR recover-probe actually found, got ' + parked[0].pr;
else if (steps.filter(s => s === 'pr-open').length !== 1) reason = 'DOUBLE-OPEN: pr-open must run exactly once (the lost original attempt), got ' + steps.filter(s => s === 'pr-open').length;
else if (steps.filter(s => s === 'push').length !== 1) reason = 'DOUBLE-PUSH: push must run exactly once, got ' + steps.filter(s => s === 'push').length;
else if (!callLog.some(c => c.opts.label === 'recover-probe:lost-open-adopt')) reason = 'must probe via the EXISTING pr.sh recover-probe path';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1067 pr-open negative: a GENUINE pr-open failure (not a lost return) escalates immediately with NO probe call" "
$PREAMBLE
setMachinery('genuine-open-fail',
  { outcome: 'CREATED', path: '/tmp/repo.wt/genuine-open-fail' },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-go' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-go', branch: 'b/go' },
  // A REAL pr.sh die() — a genuine failure, NOT the batchStep sentinel.
  { outcome: 'ERROR', error: 'authentication required' },
);
happyWorker('genuine-open-fail');
globalThis.args = { ...baseArgs, items: [{ slug: 'genuine-open-fail', branch: 'b/go', title: 'T', kind: 'impl', acceptance: ['c'] }] };
const mod = await loadLevel();
const result = await mod.default();
const escalations = result.escalations ?? [];
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'a genuine pr-open failure must not park: ' + JSON.stringify(result.parked);
else if (escalations.length !== 1) reason = 'expected exactly 1 escalation, got ' + JSON.stringify(escalations);
else if (escalations[0].kind !== 'pr-open-failed') reason = 'wrong escalation kind: ' + escalations[0].kind;
else if (callLog.some(c => c.opts.label === 'recover-probe:genuine-open-fail')) reason = 'a GENUINE failure must NEVER be routed through recover-probe — this would silently convert it into a possible adoption';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1067 static lockstep guards -----------------------------------------
grep -q 'lost pr-batch return' "$MJS" \
  || fail "#1067: build-level.mjs must carry the literal phrase 'lost pr-batch return' so the intent is greppable"
grep -q 'async function recoverLostReturn(' "$MJS" \
  || fail "#1067: recoverLostReturn() missing — the push-error/pr-open-failed sites have no lost-return disposal"
grep -q 'function isLostReturn(' "$MJS" \
  || fail "#1067: isLostReturn() missing — the sentinel-vs-genuine-failure distinction must be a named, testable predicate"
[ "$(grep -c 'await probeSideEffects(item, wt)' "$MJS")" -ge 3 ] \
  || fail "#1067: recoverLostReturn must reuse the EXISTING probeSideEffects, not invent a second probe"
echo "PASS: #1067 lost-return guard — recoverLostReturn/isLostReturn present, reusing the existing probe, greppable by name"

# ===========================================================================
# temperloop#1294 — one phase() PER STAGE, each still carrying #903's context
# ===========================================================================
# The /workflows collapsed row identified nothing about a running level: it sat
# on one static heading for the whole run. The kernel-side mitigation is a
# phase() per stage (claim → build → gate → PR → CI) whose title still names the
# repo, the item count and each item's <slug> (#<issue>) — #903's contract — so a
# collapsed view that renders the ACTIVE phase advances instead of freezing, and
# the expanded tree groups agents by stage instead of by 'machinery'/'worker'.

run_node_case "K1294 stages: a level emits one phase() per stage, in order, and EVERY stage title still carries #903's repo/count/item context" "
$PREAMBLE
const phases = [];
globalThis.phase = (t) => phases.push(String(t));
happyMachinery('alpha', 201, 'sha-a');
happyMachinery('beta', 202, 'sha-b');
happyMachinery('gamma', 203, 'sha-c');
happyWorker('alpha'); happyWorker('beta'); happyWorker('gamma');
globalThis.args = { ...baseArgs, items: [
  { slug: 'alpha', branch: 'b/alpha', title: 'A', kind: 'impl', ghIssue: 11, acceptance: ['c'] },
  { slug: 'beta',  branch: 'b/beta',  title: 'B', kind: 'impl', ghIssue: 12, acceptance: ['c'] },
  { slug: 'gamma', branch: 'b/gamma', title: 'C', kind: 'impl', ghIssue: 13, acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const CTX = 'owner/repo · 3 items · alpha (#11), beta (#12), gamma (#13)';
const EXPECTED = ['claim','build','review','gate','PR','CI'].map(s => 'build level · ' + s + ' — ' + CTX);
let reason = null;
if ((result.parked ?? []).length !== 3) reason = 'expected 3 parked, got ' + JSON.stringify(result);
// One phase() per stage, in pipeline order, no repeats and no regressions.
else if (JSON.stringify(phases) !== JSON.stringify(EXPECTED))
  reason = 'phase() sequence must be exactly the six stages in order, each carrying the #903 context.\n  got:      ' + JSON.stringify(phases) + '\n  expected: ' + JSON.stringify(EXPECTED);
// #903 non-regression, restated positively: EVERY stage title names repo, count and items.
else if (!phases.every(p => p.includes('owner/repo') && p.includes('3 items') && p.includes('alpha (#11)')))
  reason = 'a stage phase dropped the #903 run context: ' + JSON.stringify(phases);
// Every agent is assigned to its OWN stage's group via opts.phase — never left
// on the global cursor (which races under parallel()) and never on the old flat
// 'machinery'/'worker' constant.
else {
  const STAGE_OF_LABEL = [
    [/^prelude:/,      'claim'],
    [/^worker:/,       'build'],
    [/^review-diff:/,  'review'],
    [/^gate:/,         'gate'],
    [/^pr-batch:/,     'PR'],
    [/^ci-batch:/,     'CI'],
    [/^worker-cifix:/, 'CI'],
  ];
  for (const c of callLog) {
    const label = String(c.opts.label || '');
    const hit = STAGE_OF_LABEL.find(([re]) => re.test(label));
    if (!hit) { reason = 'unclassified agent label (a new spawn site needs a stage): ' + label; break; }
    const want = 'build level · ' + hit[1] + ' — ' + CTX;
    if (c.opts.phase !== want) { reason = label + ' assigned to the wrong progress group: ' + JSON.stringify(c.opts.phase) + ', expected ' + JSON.stringify(want); break; }
  }
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1294 bounding: a level wider than PHASE_TITLE_MAX_ITEMS collapses the tail to '+K more' on EVERY stage title, not just the first" "
$PREAMBLE
const phases = [];
globalThis.phase = (t) => phases.push(String(t));
const slugs = ['i1','i2','i3','i4','i5'];
slugs.forEach((s, n) => { happyMachinery(s, 300 + n, 'sha-' + s); happyWorker(s); });
globalThis.args = { ...baseArgs, items: slugs.map((s, n) => (
  { slug: s, branch: 'b/' + s, title: s, kind: 'impl', ghIssue: 400 + n, acceptance: ['c'] }
))};
const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 5) reason = 'expected 5 parked, got ' + JSON.stringify(result);
else if (phases.length !== 6) reason = 'expected 6 stage phases, got ' + JSON.stringify(phases);
else if (!phases.every(p => p.includes('5 items') && p.includes('i1 (#400), i2 (#401), i3 (#402) +2 more')))
  reason = 'every stage title must name at most PHASE_TITLE_MAX_ITEMS items and collapse the rest: ' + JSON.stringify(phases);
else if (phases.some(p => p.includes('i4') || p.includes('i5')))
  reason = 'the bound leaked — a 20-item level would swamp the progress row: ' + JSON.stringify(phases);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1294 monotonic: an off-path recovery probe gets its OWN group and never drags the collapsed row backwards" "
$PREAMBLE
const phases = [];
globalThis.phase = (t) => phases.push(String(t));
// A worker whose return channel is lost at the build stage: the recover-probe
// fires while the level is mid-flight. It must NOT re-fire phase().
setMachinery('rec1',
  { outcome: 'CREATED', path: '/tmp/repo.wt/rec1' },
  { outcome: 'RECOVER_PR_OPEN', sha: 'sha-r', commits_ahead: 1, pushed: true, remote_sha: 'sha-r', pr_number: 4242, verification_surface_present: true },
  { outcome: 'REVIEW_DIFF' },
  { outcome: 'GATE_PASS' },
  // No REBASED entry — an already-pushed recovery skips 3f-0a.
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-r', branch: 'b/rec1' },
  { outcome: 'EXISTS', pr_number: 4242 },
  { outcome: 'CI_GREEN' },
);
setWorker('rec1', throwingWorker());
globalThis.args = { ...baseArgs, items: [
  { slug: 'rec1', branch: 'b/rec1', title: 'R', kind: 'impl', ghIssue: 77, acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const probe = callLog.find(c => c.opts.label === 'recover-probe:rec1');
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected the recovered item to park: ' + JSON.stringify(result);
else if (!probe) reason = 'expected a recover-probe spawn';
else if (probe.opts.phase !== 'build level · recover — owner/repo · 1 item · rec1 (#77)')
  reason = 'the recovery probe must get its own named group: ' + JSON.stringify(probe.opts.phase);
else if (phases.some(p => p.includes('· recover —')))
  reason = 'an off-path recovery must NEVER move the global phase cursor: ' + JSON.stringify(phases);
// Cursor advanced monotonically over the stages it did reach.
else if (JSON.stringify(phases) !== JSON.stringify(['claim','build','review','gate','PR','CI'].map(s => 'build level · ' + s + ' — owner/repo · 1 item · rec1 (#77)')))
  reason = 'stage cursor must advance monotonically over the stages actually reached: ' + JSON.stringify(phases);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1294 static lockstep guards ------------------------------------------
# meta stays a PURE LITERAL and deliberately declares NO phases: meta.phases
# entries are matched against phase() titles EXACTLY, and every title this
# workflow emits is dynamic (#903 requires the repo/count/items in it), so a
# static entry could only ever render an empty duplicate group.
node -e "
  const fs = require('fs');
  const src = fs.readFileSync(process.env.MJS_PATH, 'utf8');
  const m = src.match(/export const meta = \{[\s\S]*?\n\};/);
  if (!m) { console.error('meta literal not found'); process.exit(1); }
  if (/phases\s*:/.test(m[0])) { console.error('meta declares phases: — every phase() title here is dynamic, so a static entry can only render an empty duplicate group'); process.exit(1); }
  if (/\\\$\{|\.\.\.|\(\)/.test(m[0])) { console.error('meta is no longer a pure literal'); process.exit(1); }
" || fail "#1294: meta must stay a pure literal with no phases: key"
grep -q 'function levelPhaseTitle(list, stage)' "$MJS" \
  || fail "#1294: levelPhaseTitle() must take the stage — a second title-formatting path would re-fork #903"
grep -q 'function enterStage(stage)' "$MJS" \
  || fail "#1294: enterStage() missing — the stage cursor must be one named, monotonic helper"
[ "$(grep -c '^[^/]*`build level' "$MJS")" -eq 1 ] \
  || fail "#1294: exactly one non-comment 'build level' title literal expected — a second one means the heading was hand-rolled somewhere instead of going through levelPhaseTitle()"
# Every agent spawn names its stage explicitly; the two flat constants survive
# ONLY as the `??` fallbacks inside the transport helpers.
[ "$(grep -c "phase: phaseName ?? 'machinery'" "$MJS")" -eq 2 ] \
  || fail "#1294: runMachinery/runMachineryBatch must take an explicit phase with a flat fallback"
grep -q "phase: phaseName ?? 'worker'" "$MJS" \
  || fail "#1294: callWorker must take an explicit phase with a flat fallback"
[ "$(grep -c "phase: enterStage(STAGE_" "$MJS")" -ge 7 ] \
  || fail "#1294: every stage-owning spawn site must pass opts.phase via enterStage() (global phase() state races inside parallel())"
[ "$(grep -c "phase: stagePhase(STAGE_RECOVER)" "$MJS")" -eq 2 ] \
  || fail "#1294: the off-path recovery spawns must use stagePhase(), which never moves the cursor"
echo "PASS: #1294 stage-phase guard — one monotonic enterStage() cursor, explicit opts.phase at every spawn, meta.phases deliberately absent"

# ============================================================================
# TEST (K1432): §3c "effective engineering principles" — the orchestrator-
#   resolved (kernel ∪ project) set rides input.principlesSummaries /
#   input.principlesDefaultRepo into workerPrompt(), keyed per (repo, project)
#   pair. Four sub-cases in one node case (mirrors K1080's shape): the default
#   pair, a cross-repo item's OWN pair, an item whose repo has no resolved
#   pair (falls back to default, NOT degraded), and principlesSummaries
#   omitted entirely (falls back to the static kernel-only snapshot, WITH an
#   explicit degradation notice — never a silent empty set).
# ============================================================================
run_node_case "K1432: effective engineering principles ride input.principlesSummaries into the worker prompt, keyed by (repo, project) pair" "
$PREAMBLE

// Pass 1: default pair resolved and supplied — embedded verbatim, no DEGRADED notice.
happyMachinery('pr-item', 910, 'shaPr');
happyWorker('pr-item');
globalThis.args = { ...baseArgs, principlesSummaries: {
  'owner/repo': '1. Test Kernel Principle — do the thing [kernel]\\n2. Test Project Principle — do the other thing [project]\\n\\n(kernel (7) ∪ project (Projects/repo/Priorities.md: 1))',
}, principlesDefaultRepo: 'owner/repo', items: [
  { slug: 'pr-item', branch: 'build/pr-item', title: 'PR item', kind: 'impl', acceptance: ['c'] },
]};
let mod = await loadLevel();
await mod.default();
let w = callLog.find(c => (c.opts.label||'') === 'worker:pr-item');
let reason = null;
if (!w) reason = 'no worker call logged (default pair)';
else if (!w.promptFull.includes('## Effective engineering principles')) reason = 'worker prompt missing the principles section (default pair)';
else if (!w.promptFull.includes('Test Kernel Principle')) reason = 'worker prompt missing the resolved kernel entry (default pair)';
else if (!w.promptFull.includes('Test Project Principle')) reason = 'worker prompt missing the resolved project entry (default pair)';
else if (w.promptFull.includes('DEGRADED')) reason = 'default-pair prompt must NOT carry the degradation notice';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 2: a cross-repo item (its own repo: differs from ownerRepo) picks ITS
// pair's summary, not the default's.
callLog.length = 0;
happyMachinery('xr-item', 911, 'shaXr');
happyWorker('xr-item');
globalThis.args = { ...baseArgs, principlesSummaries: {
  'owner/repo': '1. Home Principle [kernel]',
  'other/repo': '1. Foreign Kernel Principle [kernel]\\n\\n(kernel (7) only — no project § Principles declared)',
}, principlesDefaultRepo: 'owner/repo', items: [
  { slug: 'xr-item', branch: 'build/xr-item', title: 'XR item', kind: 'impl', acceptance: ['c'], repo: 'other/repo' },
]};
mod = await loadLevel();
await mod.default();
w = callLog.find(c => (c.opts.label||'') === 'worker:xr-item');
if (!w) reason = 'no worker call logged (cross-repo pair)';
else if (!w.promptFull.includes('Foreign Kernel Principle')) reason = 'cross-repo item must embed ITS OWN pair\\'s summary';
else if (w.promptFull.includes('Home Principle')) reason = 'cross-repo item must NOT fall back to the default pair when its own pair is resolved';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 3: an item whose OWN repo: has no resolved pair falls back to the
// default pair's summary (never the static fallback, never DEGRADED — a
// resolved principlesSummaries map WAS supplied this run).
callLog.length = 0;
happyMachinery('unk-item', 912, 'shaUnk');
happyWorker('unk-item');
globalThis.args = { ...baseArgs, principlesSummaries: {
  'owner/repo': '1. Home Principle [kernel]',
}, principlesDefaultRepo: 'owner/repo', items: [
  { slug: 'unk-item', branch: 'build/unk-item', title: 'Unknown-repo item', kind: 'impl', acceptance: ['c'], repo: 'unresolved/repo' },
]};
mod = await loadLevel();
await mod.default();
w = callLog.find(c => (c.opts.label||'') === 'worker:unk-item');
if (!w) reason = 'no worker call logged (unresolved-repo fallback)';
else if (!w.promptFull.includes('Home Principle')) reason = 'an item whose own repo pair was not resolved must fall back to the DEFAULT pair\\'s summary';
else if (w.promptFull.includes('DEGRADED')) reason = 'falling back to the default pair is NOT the degraded path — principlesSummaries WAS supplied this run';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 4: principlesSummaries entirely OMITTED (an older orchestrator or a
// consuming-repo caller — all three first-party callers pass it, temperloop#1460) —
// worker still gets a bounded, legible list: the static kernel-only fallback
// PLUS an explicit DEGRADED notice, never a silent empty set.
callLog.length = 0;
happyMachinery('deg-item', 913, 'shaDeg');
happyWorker('deg-item');
globalThis.args = { ...baseArgs, items: [
  { slug: 'deg-item', branch: 'build/deg-item', title: 'Degraded item', kind: 'impl', acceptance: ['c'] },
]};
mod = await loadLevel();
await mod.default();
w = callLog.find(c => (c.opts.label||'') === 'worker:deg-item');
if (!w) reason = 'no worker call logged (degraded fallback)';
else if (!w.promptFull.includes('## Effective engineering principles')) reason = 'omitted principlesSummaries must still carry the principles section (never silently drop it)';
else if (!w.promptFull.includes('Every meaningful behavior tested for every state')) reason = 'omitted principlesSummaries must fall back to the static kernel-only snapshot';
else if (!w.promptFull.includes('DEGRADED')) reason = 'omitted principlesSummaries must carry an explicit DEGRADED notice — never a silent kernel-only set';
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1432 static lockstep guards: §3c \"effective engineering principles\" ---
# build.md's Step 1.8 resolves the merged set once per run; §3c/build-level.mjs
# embed it; a future edit that drops either surface leaves the other rotting.
grep -q 'function principlesSection' "$MJS" \
  || fail "#1432: principlesSection() missing — workerPrompt must embed the resolved principle set as its own self-contained section"
grep -q '## Effective engineering principles — weigh your choices against these' "$MJS" \
  || fail "#1432: workerPrompt() must embed the '## Effective engineering principles' section"
grep -q 'input.principlesSummaries' "$MJS" \
  || fail "#1432: PRINCIPLES_SUMMARIES must read the orchestrator-supplied input.principlesSummaries (Step-0/Step-1.8 hand-off seam)"
grep -q 'input.principlesDefaultRepo' "$MJS" \
  || fail "#1432: PRINCIPLES_DEFAULT_REPO must read the orchestrator-supplied input.principlesDefaultRepo"
grep -q 'PRINCIPLES_KERNEL_FALLBACK' "$MJS" \
  || fail "#1432: a static kernel-only fallback must exist for when principlesSummaries is entirely absent (never a silent empty set)"
grep -q "'DEGRADED —" "$MJS" \
  || fail "#1432: the fallback path must emit a legible DEGRADED notice, not a silent kernel-only list"
K1432_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
# An absent build.md is a HARD FAIL, never a skip (temperloop#1409's own
# failure class: a check that cannot run must not report PASS). The .mjs
# side above is already guaranteed present by this file's top-of-file `[ -f
# "$MJS" ]` guard; build.md carries no such guard, so this line is what
# keeps a deleted/renamed prose file from silently dropping its half of the
# lockstep pair instead of going red.
[ -f "$K1432_BUILD_MD" ] \
  || fail "#1432: claude/commands/build.md is missing — the prose half of this contract pair cannot be verified"
grep -q 'principlesSummaries' "$K1432_BUILD_MD" \
  || fail "#1432: build.md must name principlesSummaries in its Step 3 args hand-off (lockstep with build-level.mjs)"
grep -q 'principlesDefaultRepo' "$K1432_BUILD_MD" \
  || fail "#1432: build.md must name principlesDefaultRepo in its Step 3 args hand-off (lockstep with build-level.mjs)"
grep -q 'Step 1.8' "$K1432_BUILD_MD" \
  || fail "#1432: build.md must define Step 1.8 — the once-per-run orchestrator resolution §3c/§3e both reuse"
echo "PASS: #1432 principles guard — workerPrompt embeds the resolved (or legibly degraded) effective principle set; build.md Step 1.8/§3c/§3e in lockstep"

# ============================================================================
# TEST (K1319): test-discrimination evidence — a worker must report, per
#   acceptance criterion, proof its own check can actually FAIL (which
#   mechanism it removed, that the suite went RED without it, that restoring
#   it went GREEN) — and that evidence must reach a human via the PR body,
#   not stop at the schema. Gated on input.requireDiscriminationEvidence so
#   it reaches /build's real per-criterion bullets but does NOT leak to
#   /sweep's / /fix's bare-string acceptance placeholder (mirrors K1432's
#   shape: an armed pass, a leak-check pass, then static lockstep guards).
# ============================================================================
run_node_case "K1319: requireDiscriminationEvidence arms the Discrimination-evidence section; omitted/false leaves it OFF (no leak to /sweep, /fix)" "
$PREAMBLE

// Pass 1: armed (/build's own hand-off) — section present, names the
// mechanism/RED/GREEN requirement, and bounds the field from the SAME named
// setting as .evidence (WORKER_EVIDENCE_MAX_WORDS), not a hardcoded literal.
happyMachinery('discrim-on', 920, 'shaDiscrimOn');
happyWorker('discrim-on');
globalThis.args = { ...baseArgs, requireDiscriminationEvidence: true, workerEvidenceMaxWords: 23, items: [
  { slug: 'discrim-on', branch: 'build/discrim-on', title: 'Discrim on', kind: 'impl', acceptance: ['c'] },
]};
let mod = await loadLevel();
await mod.default();
let w = callLog.find(c => (c.opts.label||'') === 'worker:discrim-on');
let reason = null;
if (!w) reason = 'no worker call logged (armed pass)';
else if (!w.promptFull.includes('## Discrimination evidence')) reason = 'armed run missing the Discrimination evidence section';
else if (!w.promptFull.includes('discrimination_evidence')) reason = 'armed run does not name the discrimination_evidence field';
else if (!/went RED without it/.test(w.promptFull)) reason = 'armed run missing the RED-without-it requirement';
else if (!/went GREEN/.test(w.promptFull)) reason = 'armed run missing the restored-GREEN requirement';
else if (!/[Ww]hich mechanism you removed/.test(w.promptFull)) reason = 'armed run missing the removed-mechanism requirement';
else if (!w.promptFull.includes('at most 23 words')) reason = 'discrimination_evidence bound did not come from input.workerEvidenceMaxWords (same seam as .evidence)';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 2: omitted entirely — the /sweep, /fix inheritance path. Section must
// be ABSENT, not degraded-and-present — an unrequired discipline must stay
// silent, unlike principlesSummaries' always-present-with-notice shape.
callLog.length = 0;
happyMachinery('discrim-off', 921, 'shaDiscrimOff');
happyWorker('discrim-off');
globalThis.args = { ...baseArgs, items: [
  { slug: 'discrim-off', branch: 'build/discrim-off', title: 'Discrim off', kind: 'impl', acceptance: ['(self-verify the issue is resolved)'] },
]};
mod = await loadLevel();
await mod.default();
w = callLog.find(c => (c.opts.label||'') === 'worker:discrim-off');
if (!w) reason = 'no worker call logged (omitted pass)';
else if (w.promptFull.includes('## Discrimination evidence')) reason = 'omitted requireDiscriminationEvidence must NOT arm the Discrimination evidence section (the /sweep, /fix leak this item forbids)';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 3: explicitly false — same OFF outcome as omitted (=== true, not a
// truthy check), proving the gate is strict equality.
callLog.length = 0;
happyMachinery('discrim-false', 922, 'shaDiscrimFalse');
happyWorker('discrim-false');
globalThis.args = { ...baseArgs, requireDiscriminationEvidence: false, items: [
  { slug: 'discrim-false', branch: 'build/discrim-false', title: 'Discrim false', kind: 'impl', acceptance: ['c'] },
]};
mod = await loadLevel();
await mod.default();
w = callLog.find(c => (c.opts.label||'') === 'worker:discrim-false');
if (!w) reason = 'no worker call logged (false pass)';
else if (w.promptFull.includes('## Discrimination evidence')) reason = 'requireDiscriminationEvidence: false must leave the section OFF (=== true gate, not truthy)';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 4 (the [HIGH] gap): armed run, a done verdict with ONE criterion that
// reported discrimination_evidence and ONE that claimed passed:true with the
// field empty. The gap must NOT block the item (advisory, kernel principle
// 7 — the item still parks, no escalation) but MUST be named on the parked
// record so the orchestrator can surface + tally it — never silently
// dropped, which is exactly the failure criterion 2 exists to close.
callLog.length = 0;
happyMachinery('discrim-gap', 923, 'shaDiscrimGap');
setWorker('discrim-gap', { status: 'done', summary: 'gap item done', commits: [], acceptance_results: [
  { criterion: 'proven criterion', passed: true, evidence: 'e1', discrimination_evidence: 'removed X -> RED; restored -> GREEN' },
  { criterion: 'unproven criterion', passed: true, evidence: 'e2' },
  { criterion: 'blank-string criterion', passed: true, evidence: 'e3', discrimination_evidence: '   ' },
]});
globalThis.args = { ...baseArgs, requireDiscriminationEvidence: true, items: [
  { slug: 'discrim-gap', branch: 'build/discrim-gap', title: 'Discrim gap', kind: 'impl', acceptance: ['proven criterion', 'unproven criterion', 'blank-string criterion'] },
]};
mod = await loadLevel();
let result = await mod.default();
let p = (result.parked ?? []).find(x => x.slug === 'discrim-gap');
if (!p) reason = 'gap item did not park (a degraded discrimination_evidence must be advisory, never a hard failure)';
else if ((result.escalations ?? []).length !== 0) reason = 'gap item must not escalate — advisory only (kernel principle 7)';
else if (!Array.isArray(p.discrimination_gaps)) reason = 'parked record missing discrimination_gaps array for an armed run with a real gap';
else if (p.discrimination_gaps.length !== 2) reason = 'expected exactly 2 gap criteria (empty + whitespace-only), got ' + JSON.stringify(p.discrimination_gaps);
else if (!p.discrimination_gaps.includes('unproven criterion')) reason = 'discrimination_gaps missing the criterion with an absent discrimination_evidence';
else if (!p.discrimination_gaps.includes('blank-string criterion')) reason = 'discrimination_gaps must treat a whitespace-only discrimination_evidence as empty';
else if (p.discrimination_gaps.includes('proven criterion')) reason = 'discrimination_gaps wrongly included a criterion that DID report discrimination_evidence';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 5: armed run, EVERY criterion carries discrimination_evidence — no
// spurious tally when nothing is actually missing.
callLog.length = 0;
happyMachinery('discrim-clean', 924, 'shaDiscrimClean');
setWorker('discrim-clean', { status: 'done', summary: 'clean item done', commits: [], acceptance_results: [
  { criterion: 'c', passed: true, evidence: 'e', discrimination_evidence: 'removed X -> RED; restored -> GREEN' },
]});
globalThis.args = { ...baseArgs, requireDiscriminationEvidence: true, items: [
  { slug: 'discrim-clean', branch: 'build/discrim-clean', title: 'Discrim clean', kind: 'impl', acceptance: ['c'] },
]};
mod = await loadLevel();
result = await mod.default();
p = (result.parked ?? []).find(x => x.slug === 'discrim-clean');
if (!p) reason = 'clean item did not park';
else if ('discrimination_gaps' in p) reason = 'clean item (no gaps) must not carry a discrimination_gaps field at all — expected 0, got ' + JSON.stringify(p.discrimination_gaps);

// Pass 6: UNARMED run (requireDiscriminationEvidence omitted) with a
// passed:true criterion carrying no discrimination_evidence — must NOT tally
// a gap, since the requirement was never in force for this run (mirrors
// Pass 2's 'no leak' shape, at the park-record layer instead of the prompt).
if (!reason) {
  callLog.length = 0;
  happyMachinery('discrim-unarmed', 925, 'shaDiscrimUnarmed');
  setWorker('discrim-unarmed', { status: 'done', summary: 'unarmed item done', commits: [], acceptance_results: [
    { criterion: '(self-verify the issue is resolved)', passed: true, evidence: 'e' },
  ]});
  globalThis.args = { ...baseArgs, items: [
    { slug: 'discrim-unarmed', branch: 'build/discrim-unarmed', title: 'Discrim unarmed', kind: 'impl', acceptance: ['(self-verify the issue is resolved)'] },
  ]};
  mod = await loadLevel();
  result = await mod.default();
  p = (result.parked ?? []).find(x => x.slug === 'discrim-unarmed');
  if (!p) reason = 'unarmed item did not park';
  else if ('discrimination_gaps' in p) reason = 'unarmed run (requireDiscriminationEvidence omitted) must never tally discrimination_gaps — the requirement was never in force';
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1319 static lockstep guards: test-discrimination evidence --------------
# Three surfaces must move together: the .mjs schema + prompt section, build.md's
# §3c prose + Step 3 args hand-off, and pr.sh's recap consumer (the load-bearing
# half — this is the item whose whole point is that the evidence reaches a human
# instead of being silently dropped by a jq filter that reads only the three
# original fields). Every check below HARD FAILS on an absent file — no
# `if [ -f ... ]` skip-and-PASS (the K1080 anti-pattern, temperloop#1438).
grep -q 'function discriminationEvidenceSection' "$MJS" \
  || fail "#1319: discriminationEvidenceSection() missing — workerPrompt must embed the discrimination-evidence requirement as its own self-contained, gated section"
grep -q '## Discrimination evidence — prove each check can actually FAIL' "$MJS" \
  || fail "#1319: workerPrompt() must embed the '## Discrimination evidence' section when armed"
grep -q 'input.requireDiscriminationEvidence' "$MJS" \
  || fail "#1319: REQUIRE_DISCRIMINATION_EVIDENCE must read the orchestrator-supplied input.requireDiscriminationEvidence (Step-0/Step-3 hand-off seam)"
grep -q 'REQUIRE_DISCRIMINATION_EVIDENCE = input.requireDiscriminationEvidence === true' "$MJS" \
  || fail "#1319: the gate must be strict === true, never a truthy/|| check — a non-boolean must not accidentally arm it"
grep -q 'discrimination_evidence' "$MJS" \
  || fail "#1319: WORKER_VERDICT_SCHEMA's acceptance_results items must declare a discrimination_evidence property"
K1319_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$K1319_BUILD_MD" ] \
  || fail "#1319: claude/commands/build.md is missing — the prose half of this contract pair cannot be verified"
grep -q 'discrimination_evidence' "$K1319_BUILD_MD" \
  || fail "#1319: build.md §3c must name discrimination_evidence in its return-contract prose (lockstep with build-level.mjs)"
grep -q 'requireDiscriminationEvidence' "$K1319_BUILD_MD" \
  || fail "#1319: build.md must name requireDiscriminationEvidence in its Step 3 args hand-off (lockstep with build-level.mjs)"
grep -q 'does NOT widen to' "$K1319_BUILD_MD" \
  || fail "#1319: build.md must state the /sweep, /fix scoping explicitly — this is the leak this item forbids"
K1319_PR_SH="$REPO_ROOT/workflows/scripts/build/pr.sh"
[ -f "$K1319_PR_SH" ] \
  || fail "#1319: workflows/scripts/build/pr.sh is missing — the PR-body consumer half of this contract cannot be verified"
grep -q 'discrimination_evidence' "$K1319_PR_SH" \
  || fail "#1319: pr.sh's assemble_body recap must read .discrimination_evidence — the whole point of this item is that it reaches the PR body a human reviews, not just the schema"

# --- K1319b: the [HIGH] §3e finding — a missing field must be a NAMED,
# VISIBLE degradation (a warning + a Step-6 tally), never silent, since
# neither WORKER_VERDICT_SCHEMA nor §3d/§3e.5 enforce the field's presence
# (advisory, kernel principle 7 — never a new blocking gate). Covers the
# implementation (discriminationGaps()/park()'s discrimination_gaps field,
# runtime-proven above by the K1319 case's passes 4-6) AND the prose (the
# 3f-step-2 degraded-case clause + the Step 6 summary tally line).
grep -q 'function discriminationGaps' "$MJS" \
  || fail "#1319b: discriminationGaps() missing — the degraded-case detector (a passed:true entry with an empty/absent discrimination_evidence)"
grep -q 'discrimination_gaps' "$MJS" \
  || fail "#1319b: park()'s returned record must carry discrimination_gaps — the durable marker the orchestrator tallies (mirrors the no_ci pattern)"
grep -q 'discrimination_gaps' "$K1319_BUILD_MD" \
  || fail "#1319b: build.md must name discrimination_gaps (Step 6 summary tally / the 3f-step-2 degraded-case clause) — lockstep with build-level.mjs"
grep -q 'Surface the degraded case here too' "$K1319_BUILD_MD" \
  || fail "#1319b: build.md §3f step 2 must carry the discrimination-evidence degraded-case clause, mirroring the sibling verification_surface clause"
grep -q 'Discrimination-evidence gaps (temperloop#1319' "$K1319_BUILD_MD" \
  || fail "#1319b: build.md Step 6 summary template must carry a discrimination-evidence-gaps tally line"

# --- K1319c: the [MEDIUM] rationale-correctness finding — the /sweep, /fix
# exclusion must be stated as an OPERATIONAL SCOPE decision, never as a
# structural impossibility (sweep.md/fix.md's acceptance: CAN be a real
# per-criterion array — acceptanceList() already handles it). Guard against
# the corrected claim regressing back to the false one.
grep -q 'operational scope decision' "$K1319_BUILD_MD" \
  || fail "#1319c: build.md must state the /sweep, /fix exclusion is an operational scope decision, not a structural one (the corrected rationale)"
grep -qi 'OPERATIONAL SCOPE DECISION' "$MJS" \
  || fail "#1319c: build-level.mjs's REQUIRE_DISCRIMINATION_EVIDENCE comment must state the /sweep, /fix exclusion is an operational scope decision, not a structural one"

# --- K1319d: the [MEDIUM] deferred-bare-gate ambiguity finding — a criterion
# naming the bare repo-wide suite (deferred to §3e.5 per #997) never ran
# red/green at all, which is a DIFFERENT exemption than "too coarse to
# discriminate" and must say so in exactly this wording, both in the prose
# contract and in the actual worker prompt.
grep -q 'deferred to §3e.5; discrimination not established worker-side' "$K1319_BUILD_MD" \
  || fail "#1319d: build.md must reconcile the deferred-bare-gate carve-out with discrimination_evidence — state the exact exempt-field wording"
grep -q 'deferred to §3e.5; discrimination not established worker-side' "$MJS" \
  || fail "#1319d: workerPrompt()'s Discrimination evidence section must tell the worker the exact wording for a deferred-bare-gate criterion (lockstep with build.md)"

echo "PASS: #1319 discrimination-evidence guard — workerPrompt gates the requirement on requireDiscriminationEvidence (no /sweep, /fix leak); build.md §3c/Step-3 args and pr.sh's recap consumer in lockstep; the degraded-case warning+tally, the corrected /sweep,/fix rationale, and the deferred-bare-gate reconciliation are all in lockstep too (§3e spec-review follow-up)"

# ============================================================================
# TEST (K1182): host-config / secret acceptance criteria are DEFERRED by the
#   worker and verified PARENT-SIDE by the orchestrator. A worktree is
#   populated from the git INDEX, so a gitignored host-local file is never
#   carried in: the worker's reading is absent/false in every worktree on
#   every host regardless of the truth (foundation#1556 — `credential_present:
#   false` in the worktree, `true` in BOTH real checkouts moments later). The
#   deferral is the PAIR `passed: false` + a non-empty `deferred_host_config`:
#   neither half alone changes anything, so this can never swallow a real
#   failure, and it never manufactures a pass.
# ============================================================================
run_node_case "K1182: a host-config deferral parks with a host_config_deferrals tally; a bare passed:false still escalates" "
$PREAMBLE

// Pass 1: the instruction reaches the worker prompt, UNGATED (no
// requireDiscriminationEvidence-style arming — the worktree-vs-index fact
// holds on /build, /sweep and /fix alike), and carries both load-bearing
// halves: the no-carry prohibition and the passed:false + marker pair.
happyMachinery('hostcfg-prompt', 940, 'shaHostPrompt');
happyWorker('hostcfg-prompt');
globalThis.args = { ...baseArgs, items: [
  { slug: 'hostcfg-prompt', branch: 'build/hostcfg-prompt', title: 'Host cfg prompt', kind: 'impl', acceptance: ['c'] },
]};
let mod = await loadLevel();
await mod.default();
let w = callLog.find(c => (c.opts.label||'') === 'worker:hostcfg-prompt');
let reason = null;
if (!w) reason = 'no worker call logged (prompt pass)';
else if (!w.promptFull.includes('## Host-config / gitignored-file criteria')) reason = 'worker prompt missing the host-config deferral section (must be UNGATED — every worker gets it)';
else if (!w.promptFull.includes('deferred_host_config')) reason = 'worker prompt does not name the deferred_host_config marker field';
else if (!/Do NOT carry, copy, recreate/.test(w.promptFull)) reason = 'worker prompt missing the no-carry prohibition (the secret-in-worktree exposure A.8 prevents)';
else if (!/DEFERRED, never as passed/.test(w.promptFull)) reason = 'worker prompt must say the criterion is reported DEFERRED, never as passed';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 2 (the load-bearing case): a done verdict whose host-config criterion
// is DEFERRED. It must NOT escalate acceptance-incomplete (that is the
// foundation#1556 stall over a reading nobody could take), must park, and the
// parked record must carry the criterion AND the file the parent needs to run
// the check — never a silent pass.
callLog.length = 0;
happyMachinery('hostcfg-defer', 941, 'shaHostDefer');
setWorker('hostcfg-defer', { status: 'done', summary: 'deferred item done', commits: [], acceptance_results: [
  { criterion: 'spawn --dry-run reports credential_present', passed: false, evidence: 'not observable from a worktree', deferred_host_config: 'workflows/scripts/build/build.config.local.sh (SENTRY_AUTH_TOKEN)' },
  { criterion: 'the spawn reads the credential from config', passed: true, evidence: 'unit test green' },
]});
globalThis.args = { ...baseArgs, items: [
  { slug: 'hostcfg-defer', branch: 'build/hostcfg-defer', title: 'Host cfg defer', kind: 'impl', acceptance: ['spawn --dry-run reports credential_present', 'the spawn reads the credential from config'] },
]};
mod = await loadLevel();
let result = await mod.default();
let p = (result.parked ?? []).find(x => x.slug === 'hostcfg-defer');
if ((result.escalations ?? []).length !== 0) reason = 'a marked host-config deferral must NOT escalate acceptance-incomplete — got ' + JSON.stringify(result.escalations);
else if (!p) reason = 'deferred item did not park';
else if (!Array.isArray(p.host_config_deferrals)) reason = 'parked record missing the host_config_deferrals array';
else if (p.host_config_deferrals.length !== 1) reason = 'expected exactly 1 deferral (the passed:true sibling must not be tallied), got ' + JSON.stringify(p.host_config_deferrals);
else if (p.host_config_deferrals[0].criterion !== 'spawn --dry-run reports credential_present') reason = 'deferral entry lost its criterion';
else if (!/build\\.config\\.local\\.sh/.test(p.host_config_deferrals[0].host_config)) reason = 'deferral entry must carry the host_config file/env the orchestrator needs to run the parent-side check';
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 3: a BARE passed:false with no marker escalates exactly as before. The
// exclusion is the PAIR, never the boolean — otherwise this item would have
// quietly turned every failed criterion into a park.
callLog.length = 0;
happyMachinery('hostcfg-bare', 942, 'shaHostBare');
setWorker('hostcfg-bare', { status: 'done', summary: 'bare fail', commits: [], acceptance_results: [
  { criterion: 'a genuinely failed criterion', passed: false, evidence: 'test RED' },
]});
globalThis.args = { ...baseArgs, items: [
  { slug: 'hostcfg-bare', branch: 'build/hostcfg-bare', title: 'Host cfg bare', kind: 'impl', acceptance: ['a genuinely failed criterion'] },
]};
mod = await loadLevel();
result = await mod.default();
let esc = (result.escalations ?? []).find(x => x.slug === 'hostcfg-bare');
if (!esc) reason = 'a bare passed:false (no deferred_host_config) must STILL escalate — the deferral exclusion must not swallow real failures';
else if (esc.kind !== 'acceptance-incomplete') reason = 'expected acceptance-incomplete for a bare passed:false, got ' + esc.kind;
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 4: a whitespace-only marker is NOT a marker (same trim rule as
// discrimination_evidence) — it escalates like any bare failure.
callLog.length = 0;
happyMachinery('hostcfg-blank', 943, 'shaHostBlank');
setWorker('hostcfg-blank', { status: 'done', summary: 'blank marker', commits: [], acceptance_results: [
  { criterion: 'blank-marker criterion', passed: false, evidence: 'e', deferred_host_config: '   ' },
]});
globalThis.args = { ...baseArgs, items: [
  { slug: 'hostcfg-blank', branch: 'build/hostcfg-blank', title: 'Host cfg blank', kind: 'impl', acceptance: ['blank-marker criterion'] },
]};
mod = await loadLevel();
result = await mod.default();
esc = (result.escalations ?? []).find(x => x.slug === 'hostcfg-blank');
if (!esc || esc.kind !== 'acceptance-incomplete') reason = 'a whitespace-only deferred_host_config must not count as a marker — expected acceptance-incomplete, got ' + JSON.stringify(result.escalations);
if (reason) { console.log(JSON.stringify({ ok: false, reason })); process.exit(0); }

// Pass 5: an item with no host-config criterion carries no field at all —
// byte-identical parked records to before this item.
callLog.length = 0;
happyMachinery('hostcfg-clean', 944, 'shaHostClean');
happyWorker('hostcfg-clean');
globalThis.args = { ...baseArgs, items: [
  { slug: 'hostcfg-clean', branch: 'build/hostcfg-clean', title: 'Host cfg clean', kind: 'impl', acceptance: ['c'] },
]};
mod = await loadLevel();
result = await mod.default();
p = (result.parked ?? []).find(x => x.slug === 'hostcfg-clean');
if (!p) reason = 'clean item did not park';
else if ('host_config_deferrals' in p) reason = 'an item with no deferral must not carry a host_config_deferrals field at all — got ' + JSON.stringify(p.host_config_deferrals);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1182 static lockstep guards: host-config deferral ----------------------
# Five surfaces move together: the .mjs (schema field + prompt section +
# detector + park tally + anyFailed exclusion), build.md's §3c/§3d/§4a/Step-6
# prose, assess.md's A.8 (the bar this must NOT relax), pr.sh's PR-body
# consumer, and worktree.sh's standing no-carry prohibition. Every check HARD
# FAILS on an absent file — no skip-and-PASS.
grep -q 'function hostConfigDeferralSection' "$MJS" \
  || fail "#1182: hostConfigDeferralSection() missing — workerPrompt must embed the deferral contract as its own self-contained section"
grep -q '## Host-config / gitignored-file criteria — DEFER, never confirm' "$MJS" \
  || fail "#1182: workerPrompt() must embed the '## Host-config / gitignored-file criteria' section"
grep -q 'function isHostConfigDeferral' "$MJS" \
  || fail "#1182: isHostConfigDeferral() missing — the pair detector §3d's anyFailed exclusion and the park tally both read"
grep -q 'r.passed === false && !isHostConfigDeferral(r)' "$MJS" \
  || fail "#1182: §3d's anyFailed must exclude a MARKED deferral only — the pair, never the boolean alone (a bare passed:false must still escalate)"
grep -q 'host_config_deferrals' "$MJS" \
  || fail "#1182: park()'s returned record must carry host_config_deferrals — the durable marker the orchestrator verifies parent-side"
grep -q 'deferred_host_config' "$MJS" \
  || fail "#1182: WORKER_VERDICT_SCHEMA's acceptance_results items must declare a deferred_host_config property"
K1182_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$K1182_BUILD_MD" ] \
  || fail "#1182: claude/commands/build.md is missing — the prose half of this contract pair cannot be verified"
grep -q 'deferred_host_config' "$K1182_BUILD_MD" \
  || fail "#1182: build.md §3c must name the deferred_host_config marker (lockstep with build-level.mjs)"
grep -q 'host_config_deferrals' "$K1182_BUILD_MD" \
  || fail "#1182: build.md §4a must name host_config_deferrals — the parked field the parent-side verification reads"
grep -q 'verified PARENT-SIDE by the orchestrator' "$K1182_BUILD_MD" \
  || fail "#1182: build.md §3c must state that the orchestrator verifies a host-config criterion parent-side, after the worker hands back"
grep -q 'Verify every host-config deferral HERE, parent-side' "$K1182_BUILD_MD" \
  || fail "#1182: build.md §4a must carry the parent-side verification step itself — naming the field is not the same as disposing it before merge"
grep -q 'Host-config deferrals (temperloop#1182' "$K1182_BUILD_MD" \
  || fail "#1182: build.md Step 6 summary template must carry a host-config-deferral tally line (V + U + E == D)"
# §3h.5's as-you-go fast path BYPASSES §4a by construction ("its own green" is
# long past by the level boundary), so an item carrying host_config_deferrals
# must be INELIGIBLE for it. Gate 3 is the eligibility slot that already
# excludes the sibling `acceptance_unverified: true` field; this asserts the
# SAME LINE also names host_config_deferrals — a different, non-overlapping
# field, so excluding one does not exclude the other. Scoped to gate 3's own
# line so a stray mention elsewhere in the file cannot satisfy it.
K1182_GATE3_LN="$(grep -n '^3\. \*\*No unverified acceptance' "$K1182_BUILD_MD" | head -1 | cut -d: -f1)"
[ -n "$K1182_GATE3_LN" ] \
  || fail "#1182: build.md §3h.5 eligibility gate 3 ('No unverified acceptance') not found — the as-you-go exclusion cannot be verified"
sed -n "${K1182_GATE3_LN}p" "$K1182_BUILD_MD" | grep 'host_config_deferrals' >/dev/null \
  || fail "#1182: build.md §3h.5 eligibility gate 3 must exclude an item carrying host_config_deferrals — the as-you-go path never reaches §4a, so a deferral riding it merges with NOBODY having verified it"
sed -n "${K1182_GATE3_LN}p" "$K1182_BUILD_MD" | grep 'acceptance_unverified' >/dev/null \
  || fail "#1182: build.md §3h.5 eligibility gate 3 must still exclude acceptance_unverified — the #939 exclusion is not replaced by the #1182 one"
# The worker-prompt section is UNGATED across /build, /sweep and /fix, so each
# of those specs owes its own parent-side verification seat. build.md's is §4a
# (checked above); these are the other two. Without them an ungated deferral
# instruction auto-merges unverified on those paths.
K1182_SWEEP_MD="$REPO_ROOT/claude/commands/sweep.md"
[ -f "$K1182_SWEEP_MD" ] \
  || fail "#1182: claude/commands/sweep.md is missing — /sweep's parent-side verification seat cannot be verified"
grep -q 'settle every host-config deferral parent-side' "$K1182_SWEEP_MD" \
  || fail "#1182: sweep.md's per-chunk merge pass must settle host-config deferrals parent-side BEFORE 'gh pr merge --auto' — /sweep has no §4a, so this is its only seat"
grep -q 'host_config_deferrals' "$K1182_SWEEP_MD" \
  || fail "#1182: sweep.md must name host_config_deferrals — the parked field its merge pass reads to find the deferrals it owes verification"
K1182_FIX_MD="$REPO_ROOT/claude/commands/fix.md"
[ -f "$K1182_FIX_MD" ] \
  || fail "#1182: claude/commands/fix.md is missing — /fix's parent-side verification seat cannot be verified"
grep -q 'Settle every host-config deferral parent-side BEFORE this ask' "$K1182_FIX_MD" \
  || fail "#1182: fix.md Step 5's modal merge gate must settle host-config deferrals parent-side before the ask — /fix has no §4a, so its one human-gated moment is the seat"
grep -q 'host_config_deferrals' "$K1182_FIX_MD" \
  || fail "#1182: fix.md must name host_config_deferrals — Step 4a carries it forward to the Step 5 gate"
# The .mjs's own ungated rationale must name the seats it depends on, so a
# future path added to the driver cannot inherit the instruction with no seat.
grep -q 'UNGATED IS ONLY SOUND BECAUSE ALL THREE PATHS HAVE A SEAT' "$MJS" \
  || fail "#1182: build-level.mjs's hostConfigDeferralSection() rationale must name the three consumer seats — an ungated instruction on a seatless path is how a deferral auto-merges unverified"
K1182_ASSESS_MD="$REPO_ROOT/claude/commands/assess.md"
[ -f "$K1182_ASSESS_MD" ] \
  || fail "#1182: claude/commands/assess.md is missing — the A.8 half of this contract cannot be verified"
grep -q 'confirmed set,\" not merely \"location named' "$K1182_ASSESS_MD" \
  || fail "#1182: assess.md A.8's confirmed-set bar must stay INTACT — this item moves WHO confirms, never WHETHER"
grep -q 'Who verifies such a criterion — the orchestrator, parent-side' "$K1182_ASSESS_MD" \
  || fail "#1182: assess.md A.8 must route host-config verification to the orchestrator parent-side (so an author stops writing worker-unverifiable criteria)"
K1182_PR_SH="$REPO_ROOT/workflows/scripts/build/pr.sh"
[ -f "$K1182_PR_SH" ] \
  || fail "#1182: workflows/scripts/build/pr.sh is missing — the PR-body consumer half of this contract cannot be verified"
grep -q 'deferred_host_config' "$K1182_PR_SH" \
  || fail "#1182: pr.sh's assemble_body recap must read .deferred_host_config — otherwise a deferral renders as a bare unchecked box, indistinguishable from a worker FAILURE"
K1182_WORKTREE_SH="$REPO_ROOT/workflows/scripts/build/worktree.sh"
[ -f "$K1182_WORKTREE_SH" ] \
  || fail "#1182: workflows/scripts/build/worktree.sh is missing — the no-carry half of this contract cannot be verified"
grep -q 'DO NOT GENERALIZE THIS INTO A HOST-CONFIG CARRY' "$K1182_WORKTREE_SH" \
  || fail "#1182: worktree.sh must carry the standing no-carry prohibition beside materialize_agents — the rejected 'allowlisted host-config carry' proposal must not be silently re-opened"
# The load-bearing half of the prohibition: no ACTIVE (non-comment) line in
# worktree.sh may copy a host-local config/secret file into the worktree.
# Comments naming build.config.local.sh are the documentation above; a real
# `cp`/`install` of one would be the exposure itself.
if grep -nE '^[[:space:]]*[^#[:space:]].*(\.env|\.local\.sh)' "$K1182_WORKTREE_SH" | grep -E '\b(cp|install|rsync|cat)\b' >/dev/null; then
  fail "#1182: worktree.sh has an ACTIVE line copying a host-local config/secret file into the worktree — that is the secret-in-worktree exposure /assess A.8 exists to prevent"
fi
echo "PASS: #1182 host-config deferral guard — the worker DEFERS (passed:false + deferred_host_config, never a claimed pass), a bare passed:false still escalates, park() tallies host_config_deferrals, EVERY consumer path has a parent-side seat (build.md §4a + §3h.5 exclusion, sweep.md per-chunk merge pass, fix.md Step 5), and assess.md A.8 / pr.sh / worktree.sh are in lockstep"

# ============================================================================
# TEST (K1430): §3e mandatory/routed pre-push review runs INSIDE driveItem —
#   the review is spawned by driveItem itself via agent({agentType}), never
#   delegated to the 3c worker (which cannot spawn a nested subagent at all).
#   Before this item the mandatory claude/commands/*.md -> workflow-reviewer
#   rule (foundation#1007) was worker-discretion prose with no code path to
#   discharge it — every command-doc PR reported a STRUCTURALLY GUARANTEED
#   "skipped — unavailable". These four cases exercise the real thing: a
#   mandatory run, a genuine unavailability degrade, a BLOCKING escalation,
#   and tsv-driven routing for a non-command-doc file.
# ============================================================================
run_node_case "K1430 mandatory: a claude/commands/*.md diff spawns workflow-reviewer directly (never via the worker), and a clean pass carries into the PR body" "
$PREAMBLE

setMachinery('cmd-md-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/cmd-md-item' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'] },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-cmd' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-cmd', branch: 'build/cmd-md-item' },
  { outcome: 'PR_OPENED', pr_number: 999 },
  { outcome: 'CI_GREEN' },
);
happyWorker('cmd-md-item');
setReview('cmd-md-item', '## Summary\\nAll good, no invariant violations.\\n\\n## Findings\\n(none)\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'cmd-md-item', branch: 'build/cmd-md-item', title: 'Touch build.md', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 0) reason = 'expected 0 escalations: ' + JSON.stringify(result.escalations);
const reviewCall = callLog.find(c => isReviewCall(c.opts));
if (!reason && !reviewCall) reason = 'no review agent() call spawned for a claude/commands/*.md diff — the mandatory rule never fired';
else if (!reason && reviewCall.opts.label !== 'review:cmd-md-item#workflow-reviewer')
  reason = 'unexpected review label: ' + reviewCall.opts.label;
else if (!reason && reviewCall.opts.agentType !== 'workflow-reviewer')
  reason = 'review agent() spawned with the wrong agentType: ' + reviewCall.opts.agentType;
if (!reason) {
  const prBatch = callLog.find(c => (c.opts.label||'').startsWith('pr-batch:cmd-md-item'));
  if (!prBatch) reason = 'no pr-batch call logged';
  else if (!prBatch.promptFull.includes('workflow-reviewer'))
    reason = 'the PR body-assembling command must carry evidence the review actually RAN (never a guaranteed default skip): ' + prBatch.promptFull.slice(0, 400);
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1430 unavailable: reviewer resolution failure degrades legibly (never a hard fail, never silently invisible)" "
$PREAMBLE
const logged = [];
globalThis.log = (m) => logged.push(String(m));

setMachinery('unavail-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/unavail-item' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'] },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-un' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-un', branch: 'build/unavail-item' },
  { outcome: 'PR_OPENED', pr_number: 1000 },
  { outcome: 'CI_GREEN' },
);
happyWorker('unavail-item');
setReview('unavail-item', reviewUnavailable('workflow-reviewer'));

globalThis.args = { ...baseArgs, items: [
  { slug: 'unavail-item', branch: 'build/unavail-item', title: 'Touch build.md', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'a genuinely unavailable reviewer must not block the item: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 0) reason = 'unavailability must degrade, never escalate: ' + JSON.stringify(result.escalations);
else if (!logged.some(m => m.includes('workflow-reviewer available as source; run workflows/scripts/install/project-agents.sh to enable')))
  reason = 'missing the remedy-bearing degradation notice (message-schema.md § Degradation notice): ' + JSON.stringify(logged);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1430 blocking: a HIGH finding escalates review-blocking BEFORE 3f push, never silently proceeds" "
$PREAMBLE

setMachinery('blocking-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/blocking-item' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'] },
);
happyWorker('blocking-item');
setReview('blocking-item', '## Summary\\n1 finding.\\n\\n## Findings\\n### [HIGH] Silent failure mode in claude/commands/build.md Step 3\\n**Where:** claude/commands/build.md — Step 3\\n**Issue:** x\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'blocking-item', branch: 'build/blocking-item', title: 'Touch build.md', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'a BLOCKING review finding must never park the item: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 1) reason = 'expected exactly 1 escalation: ' + JSON.stringify(result.escalations);
else if (result.escalations[0].kind !== 'review-blocking') reason = 'wrong escalation kind: ' + result.escalations[0].kind;
else {
  const prBatch = callLog.find(c => (c.opts.label||'').startsWith('pr-batch:blocking-item'));
  if (prBatch) reason = 'a blocking review must stop BEFORE 3f (push/PR) — pr-batch must never spawn: ' + JSON.stringify(prBatch.opts.label);
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1430 routing: a tsv-matched extension routes to ITS reviewer (not workflow-reviewer, not docs-reviewer)" "
$PREAMBLE
const TAB = String.fromCharCode(9);
const tsv = '.py' + TAB + 'python-reviewer' + TAB + 'claude/agents/reviewers/python-reviewer.md\\n';

setMachinery('routed-item',
  { outcome: 'CREATED', path: '/tmp/repo.wt/routed-item' },
  { outcome: 'REVIEW_DIFF', files: ['workflows/scripts/foo.py'], tsv },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-rt' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-rt', branch: 'build/routed-item' },
  { outcome: 'PR_OPENED', pr_number: 1001 },
  { outcome: 'CI_GREEN' },
);
happyWorker('routed-item');
setReview('routed-item', '## Summary\\nclean\\n\\n## Findings\\n(none)\\n');

globalThis.args = { ...baseArgs, items: [
  { slug: 'routed-item', branch: 'build/routed-item', title: 'Touch a .py file', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
const reviewCall = callLog.find(c => isReviewCall(c.opts));
if (!reason && (!reviewCall || reviewCall.opts.agentType !== 'python-reviewer'))
  reason = 'a .py-only diff must route via the tsv to python-reviewer, got: ' + JSON.stringify(reviewCall && reviewCall.opts.agentType);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# ============================================================================
# TEST (K1450): the CI-fix re-spawn does NOT bypass §3e. A CI-fix commit can
#   touch anything — including the very command doc whose edit tripped the
#   original lint failure — and ciPollLoop's CI_FAILED arm plain-pushes it
#   straight to the open PR. Neither of these live cases is exercised by the
#   four K1430 tests (all pre-CI) nor by the pre-existing CI-fail tests (which
#   predate §3e's existence and never touch review at all).
# ============================================================================
run_node_case "K1450 ci-fix clean: a CLEAN CI-fix commit still gets re-reviewed (two review rounds), and both land in the Step 6 tally" "
$PREAMBLE

setMachinery('cifix-clean',
  { outcome: 'CREATED', path: '/tmp/repo.wt/cifix-clean' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'] },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-v1' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-v1', branch: 'build/cifix-clean' },
  { outcome: 'PR_OPENED', pr_number: 700 },
  { outcome: 'CI_FAILED', failed_run_ids: [1] },
  // The re-review's OWN diff fetch — a SEPARATE machinery call from the first.
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'] },
  { outcome: 'PUSHED', sha: 'sha-v2', branch: 'build/cifix-clean' },
  { outcome: 'CI_GREEN' },
);
setWorker('cifix-clean',
  { status: 'done', summary: 'initial', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  { status: 'done', summary: 'ci fixed', acceptance_results: [], commits: [] },
);
setReview('cifix-clean',
  '## Summary\\nclean on the original push.\\n\\n## Findings\\n(none)\\n',
  '## Summary\\nclean on the CI-fix commit too.\\n\\n## Findings\\n(none)\\n',
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'cifix-clean', branch: 'build/cifix-clean', title: 'CI-fix clean', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 1) reason = 'expected 1 parked: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 0) reason = 'expected 0 escalations: ' + JSON.stringify(result.escalations);
const reviewCalls = callLog.filter(c => isReviewCall(c.opts));
if (!reason && reviewCalls.length !== 2)
  reason = 'expected TWO review agent() calls (original push + CI-fix commit), got ' + reviewCalls.length + ': ' + JSON.stringify(reviewCalls.map(c => c.opts.label));
const rec = (result.parked ?? [])[0];
if (!reason && (!rec || !rec.review || rec.review.ran.length !== 2))
  reason = 'park() must carry BOTH review rounds in its review.ran tally (temperloop#1450): ' + JSON.stringify(rec && rec.review);
if (!reason && rec.review.mandatory_ok !== true)
  reason = 'a fully-run mandatory review must report mandatory_ok:true: ' + JSON.stringify(rec.review);
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

run_node_case "K1450 ci-fix blocking: a HIGH finding on the CI-fix commit escalates review-blocking, never force-pushes the fix" "
$PREAMBLE

setMachinery('cifix-block',
  { outcome: 'CREATED', path: '/tmp/repo.wt/cifix-block' },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'] },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-v1' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-v1', branch: 'build/cifix-block' },
  { outcome: 'PR_OPENED', pr_number: 701 },
  { outcome: 'CI_FAILED', failed_run_ids: [1] },
  { outcome: 'REVIEW_DIFF', files: ['claude/commands/build.md'] },
  // Deliberately NO 'PUSHED' entry after this: if the code wrongly proceeds
  // past a blocking CI-fix review to push, the mock's queue is exhausted and
  // throws 'No mock entry' — a LOUD failure, never a silent pass-through.
);
setWorker('cifix-block',
  { status: 'done', summary: 'initial', acceptance_results: [{ criterion: 'c', passed: true, evidence: 'e' }], commits: [] },
  { status: 'done', summary: 'ci fixed', acceptance_results: [], commits: [] },
);
setReview('cifix-block',
  '## Summary\\nclean on the original push.\\n\\n## Findings\\n(none)\\n',
  '## Summary\\n1 finding.\\n\\n## Findings\\n### [HIGH] Silent failure mode introduced by the fix in claude/commands/build.md\\n',
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'cifix-block', branch: 'build/cifix-block', title: 'CI-fix blocking', kind: 'impl', acceptance: ['c'] },
]};

const mod = await loadLevel();
const result = await mod.default();
let reason = null;
if ((result.parked ?? []).length !== 0) reason = 'a BLOCKING CI-fix review must never park the item: ' + JSON.stringify(result);
else if ((result.escalations ?? []).length !== 1) reason = 'expected exactly 1 escalation: ' + JSON.stringify(result.escalations);
else if (result.escalations[0].kind !== 'review-blocking') reason = 'wrong escalation kind: ' + result.escalations[0].kind;
else if (result.escalations[0].payload.stage !== 'ci-fix') reason = 'the escalation must name its stage as ci-fix: ' + JSON.stringify(result.escalations[0].payload);
if (!reason) {
  const retryPush = callLog.find(c => (c.opts.label||'').startsWith('push-retry:cifix-block'));
  if (retryPush) reason = 'a blocking CI-fix review must stop BEFORE the retry push — push-retry must never spawn: ' + JSON.stringify(retryPush.opts.label);
}
console.log(JSON.stringify(reason ? { ok: false, reason } : { ok: true }));
"

# --- K1450 static lockstep guard: the CI-fix path re-runs §3e ---------------
grep -q 'const fixReview = await runReviewers(item, wt);' "$MJS" \
  || fail "#1450: ciPollLoop's CI_FAILED arm must re-run runReviewers() against the CI-fix diff before the retry push"
grep -q "escalation: 'review-blocking', payload: { findings: fixReview.blocking" "$MJS" \
  || fail "#1450: a blocking CI-fix review must escalate review-blocking before the retry push, exactly like the original 3e pass"
echo "PASS: #1450 ci-fix re-review guard — the CI_FAILED arm re-runs §3e against the fix commit before pushing it"

# --- K1430 static lockstep guards: §3e mandatory/routed pre-push review ------
# build.md §3e is the SPEC; build-level.mjs's driveItem is the as-built
# encoding (the same lockstep discipline as every other *_BUILD_MD guard in
# this file). This asserts the CLASSIFICATION — the review is declared and
# ordered between 3d and 3e.5, spawning the reviewer directly — never the
# implementation details. An absent build.md is a HARD FAIL (temperloop#1438's
# own anti-pattern: a check that cannot run must never report PASS), never a
# skip-if-absent.
grep -q 'async function runReviewers' "$MJS" \
  || fail "#1430: build-level.mjs must define runReviewers() — the §3e driver that spawns the routed reviewer(s) itself"
grep -q 'function determineReviewers' "$MJS" \
  || fail "#1430: build-level.mjs must define determineReviewers() — the routing DECISION (kept in legible .mjs, DESIGN NOTE 1), never buried in an opaque agent prompt"
grep -q 'agentType: route.reviewer' "$MJS" \
  || fail "#1430: the reviewer must be spawned via agent({agentType}) directly — never delegated to the 3c worker"
grep -q 'foundation#1007' "$MJS" \
  || fail "#1430: the mandatory claude/commands/*.md -> workflow-reviewer rule (foundation#1007) must be named in build-level.mjs, not left to worker discretion"
grep -q 'MACHINERY_RESOLUTION_ERR.test(msg)' "$MJS" \
  || fail "#1430: reviewer-unavailability detection must reuse machineryAgent's own MACHINERY_RESOLUTION_ERR precedent (temperloop#1014), not a new ad hoc check"

# Ordering — §3e runs BETWEEN 3d (the anyFailed check) and 3e.5 (the gate), and
# 3e.5 still precedes 3f. A future edit that reorders these blocks — moving
# rather than removing the exact defect this item fixes — must fail here,
# unconditionally.
ANYFAILED_LINE="$(grep -n 'const anyFailed = ' "$MJS" | head -1 | cut -d: -f1)"
REVIEW_CALL_LINE="$(grep -n 'const review = await runReviewers(item, wt);' "$MJS" | head -1 | cut -d: -f1)"
GATE_MARKER_LINE="$(grep -n -- '--- 3e.5. Parent-side acceptance gate' "$MJS" | head -1 | cut -d: -f1)"
PR_MARKER_LINE="$(grep -n -- '--- 3f. Push and open the PR' "$MJS" | head -1 | cut -d: -f1)"
[ -n "$ANYFAILED_LINE" ] || fail "#1430: could not locate 3d's anyFailed check in build-level.mjs"
[ -n "$REVIEW_CALL_LINE" ] || fail "#1430: could not locate the runReviewers() call site in build-level.mjs"
[ -n "$GATE_MARKER_LINE" ] || fail "#1430: could not locate the 3e.5 acceptance-gate marker in build-level.mjs"
[ -n "$PR_MARKER_LINE" ] || fail "#1430: could not locate the 3f push/PR marker in build-level.mjs"
[ "$ANYFAILED_LINE" -lt "$REVIEW_CALL_LINE" ] \
  || fail "#1430: the §3e review must run AFTER 3d's anyFailed check, not before"
[ "$REVIEW_CALL_LINE" -lt "$GATE_MARKER_LINE" ] \
  || fail "#1430: the §3e review must run BEFORE 3e.5's acceptance gate — this is the ordering the whole item exists to fix"
[ "$GATE_MARKER_LINE" -lt "$PR_MARKER_LINE" ] \
  || fail "#1430: 3e.5 must still precede 3f — the review must not reorder the rest of the pipeline"
echo "PASS: #1430 review-ordering guard — determineReviewers/runReviewers spawn agent({agentType}) directly, reusing MACHINERY_RESOLUTION_ERR, strictly between 3d and 3e.5"

K1430_BUILD_MD="$REPO_ROOT/claude/commands/build.md"
[ -f "$K1430_BUILD_MD" ] \
  || fail "#1430: claude/commands/build.md is missing — the prose half of this contract pair cannot be verified"
grep -q 'foundation#1007' "$K1430_BUILD_MD" \
  || fail "#1430: build.md §3e must still name the mandatory command-doc rule (foundation#1007)"
grep -q 'workflow-reviewer' "$K1430_BUILD_MD" \
  || fail "#1430: build.md §3e must name workflow-reviewer"
grep -q 'orchestrator↔workflow boundary is irreversible-action plus single-writer' "$K1430_BUILD_MD" \
  || fail "#1430: build.md §3e must record WHY the review runs inside the workflow rather than the orchestrator (temperloop#1430's own rationale)"
echo "PASS: #1430 build.md rationale guard — §3e records why the review runs inside build-level.mjs, not the orchestrator"

echo ""
echo "All test_workflow.sh cases passed."
