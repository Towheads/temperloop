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

// machineryMap: slug → [outcome, ...] — consumed in order per slug
const machineryMap = new Map();
// workerMap: slug → [verdict, ...] — consumed in order per slug
const workerMap = new Map();
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

globalThis.agent = async function agent(prompt, opts = {}) {
  callLog.push({ prompt: String(prompt).slice(0, 120), promptFull: String(prompt), opts: { label: opts.label, phase: opts.phase, model: opts.model, agentType: opts.agentType } });
  const slug = slugFromLabel(opts.label);
  if (opts.phase === 'machinery') {
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
  if (opts.phase === 'worker') {
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
// temperloop#939 mock shorthands.
// throwingWorker(msg) — the #939 return-channel failure (agent() throws).
globalThis.throwingWorker = (msg) => ({ __throw: msg || 'agent({schema}): subagent completed without calling StructuredOutput (after in-conversation nudge)' });
// noSideEffects — the recover-probe answer for a genuinely-failed worker.
globalThis.noSideEffects = () => ({ outcome: 'RECOVER_NONE', commits_ahead: 0, pushed: false, dirty: false, dirty_files: 0, verification_surface_present: false });
// temperloop#993 shorthand — dirtyStall(n): the recover-probe answer for a worker
// reaped mid-flight by a backgrounded gate: n uncommitted paths, ZERO commits.
globalThis.dirtyStall = (n) => ({ outcome: 'RECOVER_DIRTY', commits_ahead: 0, pushed: false, dirty: true, dirty_files: n ?? 8, verification_surface_present: false });

// Canonical happy-path machinery sequence for a green item
globalThis.happyMachinery = (slug, prNum, sha) => setMachinery(slug,
  { outcome: 'CREATED', path: '/tmp/repo.wt/' + slug },
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
  c.opts.phase !== 'machinery' && c.opts.phase !== 'worker' &&
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
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-v1' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-v1', branch: 'build/item-cifix' },
  { outcome: 'PR_OPENED', pr_number: 401 },
  // First CI poll: CI_FAILED
  { outcome: 'CI_FAILED', failed_run_ids: [9001] },
  // Retry push after fix worker (plain push — ff descendant, no --force)
  { outcome: 'PUSHED', sha: 'sha-v2', branch: 'build/item-cifix' },
  // Re-poll pinned to sha-v2: CI_GREEN
  { outcome: 'CI_GREEN' },
);

let ciFixWorkerModel = undefined;
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts={}) {
  // Track model on the CI-fix worker call
  if (opts.phase === 'worker' && String(prompt).includes('CI failed')) {
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
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-v1' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-v1', branch: 'build/item-cibust' },
  { outcome: 'PR_OPENED', pr_number: 501 },
  { outcome: 'CI_FAILED', failed_run_ids: [9002] },
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
if (!gatePromptSeen)
  { console.log(JSON.stringify({ ok: false, reason: 'gate agent call never observed' })); process.exit(0); }
if (!gatePromptSeen.includes('480000'))
  { console.log(JSON.stringify({ ok: false, reason: 'gate prompt missing 480000 Bash timeout: ' + gatePromptSeen })); process.exit(0); }
if (!/timeout/i.test(gatePromptSeen))
  { console.log(JSON.stringify({ ok: false, reason: 'gate prompt missing timeout directive: ' + gatePromptSeen })); process.exit(0); }

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
  if (opts.phase === 'worker' && label.startsWith('worker:item-cont')) {
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
  if (opts.phase === 'machinery') machineryPrompts.push(String(prompt));
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
# The #997 narrowing applies to the WORKER only — 3e.5's parent-side gate stays
# bare and repo-wide (the PR #309 silent-red lesson). Guard that the gate command
# still invokes the script with no path arguments appended.
# shellcheck disable=SC2016  # grepping for the LITERAL ${sq(qgBin)} token in source
grep -q '&& ${sq(qgBin)} ) >/tmp/qg-' "$MJS" \
  || fail "#997/#309: the 3e.5 parent-side gate must still invoke quality-gates.sh BARE (no path scoping) — it is the acceptance authority"
echo "PASS: #997 worker-gate-scope guard — worker prompt + cure ban the bare repo-wide run; 3e.5 stays bare and repo-wide"

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
else if (callLog.filter(c => c.opts.phase === 'worker').length !== 1) reason = 'worker was re-spawned after a recovered return (must not be)';
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

const machineryCalls = callLog.filter(c => c.opts.phase === 'machinery');
const workerCalls = callLog.filter(c => c.opts.phase === 'worker');

// The number of agent spawns the OLD one-agent-per-command bridge would have
// paid for exactly this run: one per batched step actually executed, plus one
// per solo (unbatched) machinery call. Derived from the run, not hardcoded.
const soloCalls = machineryCalls.filter(c => !/^Steps: /m.test(c.promptFull)).length;
const unbatched = machineryStepLog.length + soloCalls;

if (!reason && workerCalls.length !== 3) reason = 'expected 3 worker spawns, got ' + workerCalls.length;
// 4 machinery executors per item: prelude, gate, pr-batch, ci-batch.
if (!reason && machineryCalls.length !== 12) reason = 'expected 12 machinery executors (4/item), got ' + machineryCalls.length + ': ' + JSON.stringify(machineryCalls.map(c => c.opts.label));
if (!reason && callLog.length !== 15) reason = 'expected 15 total agent spawns for the level, got ' + callLog.length;
// …and that is a real reduction against the un-batched equivalent of this run.
if (!reason && unbatched !== 33) reason = 'expected the un-batched equivalent to be 33 spawns, got ' + unbatched;
if (!reason && !(machineryCalls.length < unbatched)) reason = 'batching did not reduce machinery spawns: ' + machineryCalls.length + ' vs ' + unbatched;

// Per item, the executors are exactly these four, in this order.
for (const slug of ['a1', 'a2', 'a3']) {
  const labels = machineryCalls.filter(c => (c.opts.label||'').includes(slug)).map(c => c.opts.label);
  const want = ['prelude:' + slug, 'gate:' + slug, 'pr-batch:' + slug, 'ci-batch:' + slug + '#0'];
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
const workerCall = callLog.find(c => c.opts.phase === 'worker' && c.opts.label === 'worker:mtier');
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
const workerCall = callLog.find(c => c.opts.phase === 'worker' && c.opts.label === 'worker:mtierdef');
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
const workerCall = callLog.find(c => c.opts.phase === 'worker' && c.opts.label === 'worker:mtierempty');
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
const mach = callLog.filter(c => c.opts.phase === 'machinery');
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
const served = callLog.filter(c => c.opts.phase === 'machinery' && !c.opts.rejected);
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
  if (opts.phase === 'machinery') {
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
const mach = callLog.filter(c => c.opts.phase === 'machinery');
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

echo ""
echo "All test_workflow.sh cases passed."
