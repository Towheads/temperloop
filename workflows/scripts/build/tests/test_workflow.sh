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
# concurrently. The mock infrastructure therefore keys per-item spine/worker
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

MJS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)/claude/workflows/build-level.mjs"
[ -f "$MJS" ] || { echo "FAIL: build-level.mjs not found at $MJS" >&2; exit 1; }

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

# ---------------------------------------------------------------------------
# run_node_case <description> <node-es-module-body>
# Writes a temp .mjs, runs it with node, reads the last stdout line as a JSON
# { ok: true } / { ok: false, reason: "..." } verdict.
# ---------------------------------------------------------------------------
run_node_case() {
  local desc="$1"
  local tmpf
  tmpf="$(mktemp /tmp/wf-test-XXXXXX.mjs)"
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
#   - spineMap: Map<slug, outcome[]> — per-item ordered spine returns
#   - workerMap: Map<slug, verdict[]> — per-item ordered worker returns
#   - agent() routes by opts.schema (spine) vs no schema (worker), extracting
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

const callLog = [];

// spineMap: slug → [outcome, ...] — consumed in order per slug
const spineMap = new Map();
// workerMap: slug → [verdict, ...] — consumed in order per slug
const workerMap = new Map();
// mergeCheckMap: slug → [mergeState, ...] — consumed in order per slug.
// Default (map miss): { mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN' }
// so existing tests need no changes — only CONFLICTING tests override this.
const mergeCheckMap = new Map();

function slugFromLabel(label) {
  // Labels from runSpine: "worktree:slug", "gate:slug", "scan:slug", "push:slug",
  // "pr-open:slug", "ci-poll:slug#N", "push-force:slug", "spine:cmd ..."
  // Labels from worker: "worker:slug", "worker-cifix:slug"
  // Labels from merge-check: "merge-check:slug#N"
  // Claim: "claim:slug"
  if (!label) return null;
  const m = label.match(/^[^:]+:([^#\s]+)/);
  return m ? m[1] : null;
}

function nextFromMap(map, slug, fallback) {
  const q = map.get(slug);
  if (q && q.length > 0) return q.shift();
  if (fallback !== undefined) return fallback;
  throw new Error(`No mock entry for slug="${slug}" in map; label exhausted`);
}

globalThis.callLog = callLog;
globalThis.spineMap = spineMap;
globalThis.workerMap = workerMap;
globalThis.mergeCheckMap = mergeCheckMap;

globalThis.agent = async function agent(prompt, opts = {}) {
  callLog.push({ prompt: String(prompt).slice(0, 120), opts: { label: opts.label, phase: opts.phase, model: opts.model } });
  const slug = slugFromLabel(opts.label);
  if (opts.phase === 'spine') {
    // Spine call — one-shot executor, routed by slug
    return nextFromMap(spineMap, slug, { outcome: 'ERROR', error: 'unexpected spine call for ' + slug });
  }
  if (opts.phase === 'merge-check') {
    // Merge-state check — gh pr view mergeable/mergeStateStatus, routed by slug.
    // Default is non-conflicting so existing tests need no changes.
    return nextFromMap(mergeCheckMap, slug, { mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN' });
  }
  if (opts.phase === 'worker') {
    // Worker call — implementation agent, routed by slug
    return nextFromMap(workerMap, slug, { status: 'done', summary: 'default', acceptance_results: [], commits: [] });
  }
  // Fallback (should not happen in well-formed test cases)
  return nextFromMap(workerMap, slug, { status: 'done', summary: 'fallback', acceptance_results: [], commits: [] });
};

globalThis.log = () => {};
globalThis.phase = () => {};
globalThis.parallel = async (fns) => Promise.all(fns.map(f => f()));

// Helpers to register sequences
globalThis.setSpine = (slug, ...outcomes) => { spineMap.set(slug, outcomes); };
globalThis.setWorker = (slug, ...verdicts) => { workerMap.set(slug, verdicts); };
globalThis.setMergeCheck = (slug, ...states) => { mergeCheckMap.set(slug, states); };

// Canonical happy-path spine sequence for a green item
globalThis.happySpine = (slug, prNum, sha) => setSpine(slug,
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

# ============================================================================
# TEST 1: happy — 3 green items → 3 parked, empty escalations, no plan-note write
# ============================================================================
run_node_case "happy: 3 green items → 3 parked, empty escalations, no plan-note write" "
$PREAMBLE

happySpine('item101', 101, 'sha1');
happySpine('item102', 102, 'sha2');
happySpine('item103', 103, 'sha3');
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
  c.opts.phase !== 'spine' && c.opts.phase !== 'worker' &&
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

happySpine('item-a', 201, 'sha-a');
happySpine('item-b', 202, 'sha-b');
// item-fork: CREATED only (worker escalates immediately after worktree step)
setSpine('item-fork',
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

happySpine('item-good', 301, 'sha-good');
setSpine('item-bad', { outcome: 'CREATED', path: '/tmp/repo.wt/item-bad' });
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

setSpine('item-cifix',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-cifix' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-v1' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-v1', branch: 'build/item-cifix' },
  { outcome: 'PR_OPENED', pr_number: 401 },
  // First CI poll: CI_FAILED
  { outcome: 'CI_FAILED', failed_run_ids: [9001] },
  // Force-push after fix worker
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

setSpine('item-cibust',
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

setSpine('item-timeout',
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
# TEST 7: claim-conflict → claim-conflict escalation (board ON, ghIssue set)
# ============================================================================
run_node_case "claim-conflict: CLAIM_CONFLICT → claim-conflict escalation" "
$PREAMBLE

// Board ON + ghIssue → claim spine fires first (before worktree.sh).
// Label: 'claim:item-conflict'
setSpine('item-conflict',
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

setSpine('item-rejected',
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

setSpine('item-scan',
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

setSpine('item-rb',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-rb' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASE_CONFLICT', base: 'b', tip: 't', error: 'CONFLICT (content): shared.txt' },
  // No SCAN/PUSH entries: if the spine advanced past the conflict it would
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

// Spike path: worker is called directly (no spine calls).
// spineMap for 'spike-item' is intentionally empty — any spine call is an error.
setSpine('spike-item' /* empty — no calls expected */);
setWorker('spike-item',
  { status: 'done', summary: 'spike verdict produced', acceptance_results: [{ criterion: 'verdict-written', passed: true, evidence: 'v.md' }], verification_surface_path: '/tmp/verdict.md' }
);

globalThis.args = { ...baseArgs, items: [
  { slug: 'spike-item', branch: 'build/spike-item', title: 'Spike Item', kind: 'spike', acceptance: ['verdict-written'] },
]};

const initialSpineSize = (spineMap.get('spike-item') || []).length;

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

// Verify no spine calls were made for the spike item
const spineCallsForSpike = callLog.filter(c => c.opts.schema && (c.opts.label||'').includes('spike-item'));
if (spineCallsForSpike.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'spike made spine calls: ' + JSON.stringify(spineCallsForSpike.map(c=>c.opts.label)) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 11: gate-fail → acceptance-gate-failed escalation
# ============================================================================
run_node_case "gate-fail: GATE_FAIL → acceptance-gate-failed escalation" "
$PREAMBLE

setSpine('item-gate',
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

happySpine('item-gto', 115, 'sha-gto');
happyWorker('item-gto');

// Wrap the mock agent to capture the FULL gate prompt (the shared callLog slices
// to 120 chars, which truncates before the directive; mirror the continuation
// case's full-prompt capture). Delegate every call to the original mock so spine
// routing (GATE_PASS from happySpine) is unchanged.
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
# TEST 12: worktree-failed — worktree.sh returns non-CREATED → worktree-failed escalation
# ============================================================================
run_node_case "worktree-failed: worktree.sh non-CREATED → worktree-failed escalation" "
$PREAMBLE

setSpine('item-wt',
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
happySpine('l1a', 701, 'sha-l1a');
happySpine('l1b', 702, 'sha-l1b');
happyWorker('l1a');
happyWorker('l1b');

// Level 2: 2 green items (different slugs)
happySpine('l2a', 703, 'sha-l2a');
happySpine('l2b', 704, 'sha-l2b');
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

// The continued item resumes at 3c (worker). Its spine sequence therefore has
// NO 'CREATED' (worktree create is skipped) and NO claim — it begins at the
// gate (3e.5). If driveItem wrongly ran worktree.sh create or claim.sh, it
// would consume an extra spine entry here and the outcome would desync.
setSpine('item-cont',
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
// claim/worktree spine call to assert it was skipped.
let workerPromptSeen = '';
let sawCreateOrClaim = false;
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts={}) {
  const label = opts.label || '';
  if (opts.phase === 'worker' && label.startsWith('worker:item-cont')) {
    workerPromptSeen = String(prompt);
  }
  if (label.startsWith('worktree:item-cont') || label.startsWith('claim:item-cont')) {
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
  { console.log(JSON.stringify({ ok: false, reason: 'continuation ran worktree.sh create or claim.sh (should reuse/skip)' })); process.exit(0); }

// Belt-and-suspenders: no CREATED/CLAIMED spine outcome was consumed for the
// continued slug (the spine sequence had neither).
const createCalls = callLog.filter(c =>
  (c.opts.label||'').match(/^(worktree|claim):item-cont/));
if (createCalls.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'create/claim spine calls present: ' + JSON.stringify(createCalls.map(c=>c.opts.label)) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 16: acceptance-string — item.acceptance as a single STRING (the shape
# /sweep passes) must work, not throw on .map (#437 real-run bug).
# ============================================================================
run_node_case "acceptance-string: item.acceptance as a string → parks, no .map throw (#437)" "
$PREAMBLE
happySpine('strone', 201, 'shaS');
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
// Spine: normal happy path
happySpine('retryitem', 10, 'sha-retry');
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
# Spine must be seeded through worktree creation (3b) since that runs before 3c.
# ============================================================================
run_node_case "null-worker-persistent: agent returns null twice → worker-error escalation, no TypeError (#542)" "
$PREAMBLE
// Spine: only worktree creation is needed; worker escalates before gate/scan/push/PR/CI
setSpine('nullitem', { outcome: 'CREATED', path: '/tmp/repo.wt/nullitem' });
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
// Spike: no spine calls (spikes skip all spine steps); worker returns null
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
// Spine: normal path up to CI_FAILED, then fix-spawn (worker) returns null
happySpine('cifixnull', 20, 'sha-cifix');
// Override ci-poll in spineMap to return CI_FAILED
spineMap.set('cifixnull', [
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

// Spine through push + PR open; NO ci-poll entry (merge-check fires first, escalates)
setSpine('item-conflict543',
  { outcome: 'CREATED', path: '/tmp/repo.wt/item-conflict543' },
  { outcome: 'GATE_PASS' },
  { outcome: 'REBASED', base: 'b', tip: 't', sha: 'sha-cf' },
  { outcome: 'SCAN_CLEAN' },
  { outcome: 'PUSHED', sha: 'sha-cf', branch: 'build/item-conflict543' },
  { outcome: 'PR_OPENED', pr_number: 543 },
  // No CI_GREEN/CI_FAILED/TIMEOUT entries: if ci-poll.sh fires, it consumes
  // from an exhausted spineMap → ERROR fallback → test would see ci-failed, not
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

// Confirm ci-poll was NOT called (no entry consumed after PR_OPENED)
const ciPollCalls = callLog.filter(c => (c.opts.label||'').startsWith('ci-poll:item-conflict543'));
if (ciPollCalls.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'merge-conflict: ci-poll.sh was called (should be skipped): ' + JSON.stringify(ciPollCalls.map(c=>c.opts.label)) })); process.exit(0); }

console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 23: DIRTY merge state (MERGEABLE field absent, only mergeStateStatus=DIRTY)
# Also verifies a non-conflicting sibling parks normally (existing poll unaffected).
# ============================================================================
run_node_case "merge-conflict: mergeStateStatus=DIRTY alone escalates merge-conflict (#543)" "
$PREAMBLE

// Item that is DIRTY (mergeStateStatus only, mergeable field missing/UNKNOWN)
setSpine('item-dirty',
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
happySpine('item-clean', 545, 'sha-clean');
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

setSpine('item-exists',
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

setSpine('item-prfail',
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
# TEST 26: null spine return at the WORKTREE step (temperloop#72). When the
# auto-mode safety classifier DENIES a spine command, agent() returns null and
# runSpine normalizes it to a SPINE_DENIED sentinel. driveItem must escalate a
# clean 'spine-denied' rather than dereference wtOut.outcome and crash with
# 'null is not an object'.
# ============================================================================
run_node_case "null-spine-worktree: worktree spine returns null → spine-denied escalation, no TypeError (#72)" "
$PREAMBLE
// First spine call (worktree.sh create, board OFF) returns null (classifier denied).
setSpine('wtdenied', null);
happyWorker('wtdenied');
globalThis.args = { ...baseArgs, items: [
  { slug: 'wtdenied', branch: 'build/wtdenied', title: 'WT denied', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
const parked = result.parked ?? [];
const escalations = result.escalations ?? [];
if (parked.length !== 0)
  { console.log(JSON.stringify({ ok: false, reason: 'null-spine-worktree: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'spine-denied')
  { console.log(JSON.stringify({ ok: false, reason: 'null-spine-worktree: expected 1 spine-denied escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].payload.step !== 'worktree')
  { console.log(JSON.stringify({ ok: false, reason: 'null-spine-worktree: expected payload.step=worktree, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 27: null spine return at the PUSH step (temperloop#72). Same null-guard,
# exercised at 3f-1 push after a clean worker+gate+rebase+scan. Guards the
# second site the crash was reported at (~453/push).
# ============================================================================
run_node_case "null-spine-push: push spine returns null → spine-denied escalation, no TypeError (#72)" "
$PREAMBLE
setSpine('pushdenied',
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
  { console.log(JSON.stringify({ ok: false, reason: 'null-spine-push: expected 0 parked, got ' + JSON.stringify(parked) })); process.exit(0); }
if (escalations.length !== 1 || escalations[0].kind !== 'spine-denied')
  { console.log(JSON.stringify({ ok: false, reason: 'null-spine-push: expected 1 spine-denied escalation, got ' + JSON.stringify(escalations) })); process.exit(0); }
if (escalations[0].payload.step !== 'push')
  { console.log(JSON.stringify({ ok: false, reason: 'null-spine-push: expected payload.step=push, got ' + JSON.stringify(escalations[0].payload) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# TEST 28: spineBinDir de-obfuscation (temperloop#72, root cause 1). When the
# orchestrator passes a pre-resolved input.spineBinDir, spineBin emits a PLAIN
# absolute path — the executed worktree/push command line must carry NO nested
# \$(readlink …) command-substitution (what the classifier read as an obfuscated
# bypass). We capture the spine prompts and assert the resolved path is present
# and no readlink substitution leaks into the executed line.
# ============================================================================
run_node_case "spineBinDir: pre-resolved dir → plain paths, no readlink in executed spine command (#72)" "
$PREAMBLE
happySpine('deobf', 260, 'sha-deobf');
happyWorker('deobf');
let spinePrompts = [];
const origAgent = globalThis.agent;
globalThis.agent = async function(prompt, opts={}) {
  if (opts.phase === 'spine') spinePrompts.push(String(prompt));
  return origAgent(prompt, opts);
};
globalThis.args = { ...baseArgs, spineBinDir: '/resolved/spine/bin', items: [
  { slug: 'deobf', branch: 'build/deobf', title: 'Deobf', kind: 'impl', acceptance: ['c'] },
]};
const mod = await loadLevel();
const result = await mod.default();
if ((result.parked ?? []).length !== 1)
  { console.log(JSON.stringify({ ok: false, reason: 'spineBinDir: expected 1 parked, got ' + JSON.stringify(result) })); process.exit(0); }
// The worktree + push spine commands must use the plain resolved dir...
const wtPrompt = spinePrompts.find(p => p.includes('worktree.sh'));
const pushPrompt = spinePrompts.find(p => p.includes('pr.sh') && p.includes(' push '));
if (!wtPrompt || !wtPrompt.includes('/resolved/spine/bin/worktree.sh'))
  { console.log(JSON.stringify({ ok: false, reason: 'spineBinDir: worktree cmd missing plain resolved path: ' + (wtPrompt||'<none>').slice(0,300) })); process.exit(0); }
if (!pushPrompt || !pushPrompt.includes('/resolved/spine/bin/pr.sh'))
  { console.log(JSON.stringify({ ok: false, reason: 'spineBinDir: push cmd missing plain resolved path: ' + (pushPrompt||'<none>').slice(0,300) })); process.exit(0); }
// ...and NO nested readlink command-substitution in any spine command line.
const leaked = spinePrompts.find(p => p.includes('readlink'));
if (leaked)
  { console.log(JSON.stringify({ ok: false, reason: 'spineBinDir: readlink substitution leaked into executed spine command: ' + leaked.slice(0,300) })); process.exit(0); }
console.log(JSON.stringify({ ok: true }));
"

# ============================================================================
# Root-cause-1 static guards (temperloop#72).
# (1) spineBin must PREFER a pre-resolved input.spineBinDir (plain-path branch),
#     so the executed pr.sh/worktree.sh line need not carry nested readlink.
# (2) The runSpine / merge-check sub-agent instruction must no longer read as
#     'blindly execute an opaque command' — the 'Do NOT interpret it' phrasing
#     that (with the readlink substitution) tripped the auto-mode classifier is
#     gone.
grep -q 'input.spineBinDir' "$MJS" \
  || fail "#72: spineBin must prefer a pre-resolved input.spineBinDir (de-obfuscated plain-path branch)"
if grep -q 'Do NOT interpret it' "$MJS"; then
  fail "#72: sub-agent instruction still reads as blind-execute ('Do NOT interpret it') — soften it"
fi
# (3) The null-guard must exist: a spineDenied() detector + a spine-denied escalation.
grep -q 'function spineDenied(' "$MJS" \
  || fail "#72: spineDenied() null/denied detector missing from build-level.mjs"
grep -q "'spine-denied'" "$MJS" \
  || fail "#72: no 'spine-denied' escalation emitted — a denied spine step must park, not crash"
echo "PASS: #72 classifier-detrip + null-guard static guards — spineBinDir plain-path branch, softened instruction, spineDenied() + spine-denied escalation present"

# ============================================================================
# Spine-resolution regression guard (foundation #560).
# build-level.mjs runs in the Workflow sandbox (no fs/Node API), so the
# build-spine scripts (worktree.sh/pr.sh/ci-poll.sh) MUST be resolved via the
# bash `spineBin` fallback (repo-local → foundation), never the old hardcoded
# `${repoRoot}/workflows/scripts/build/<script>` template that broke in a
# stageFind checkout lacking the workflows→foundation symlink. Static-assert the
# fix stays in place. (The runtime behaviour of the emitted resolver is proven
# separately in the PR's executed 4-scenario matrix.)
grep -q '^function spineBin(' "$MJS" \
  || fail "#560: spineBin() resolver missing from build-level.mjs"
# The project's OWN vendored gate stays repo-local — spineBin is spine-only.
# shellcheck disable=SC2016  # grepping for the LITERAL ${repoRoot} token in source
grep -q 'const qgBin = `${repoRoot}/scripts/quality-gates.sh`' "$MJS" \
  || fail "#560: qgBin (repo-local quality-gates) must NOT route through spineBin"
# No spine call site may regress to the hardcoded `.../workflows/scripts/build/<script>` template.
if grep -nE '\}/workflows/scripts/build/(worktree|pr|ci-poll)\.sh' "$MJS"; then
  fail "#560: a spine script is still hardcoded to \${repoRoot}/workflows/scripts/build/ — route it through spineBin()"
fi
# Every spine invocation (worktree/pr×2/ci-poll) must go through spineBin — 4 call sites + the def.
sb_refs="$(grep -c 'spineBin(' "$MJS")"
[ "$sb_refs" -ge 5 ] \
  || fail "#560: expected >=5 spineBin references (1 def + 4 call sites), found $sb_refs"
echo "PASS: #560 spine-resolution guard — spineBin() resolves all spine scripts; no hardcoded paths; qgBin stays repo-local"

# --- temperloop#68: the 3e.5 gate command must carry `set -o pipefail` so a RED
# quality-gates run can never be swallowed by a downstream pipe/filter (the
# pipe-ate-exit-code defect). A future hand-edit that pipes the gate to capture
# its output would otherwise mask a non-zero gate exit behind the last stage's 0,
# degrading 3e.5 to a silent no-op. Guard the prefix statically. ------------
grep -q 'set -o pipefail; if \[ ! -x' "$MJS" \
  || fail "#68: 3e.5 gate command must prefix 'set -o pipefail' (pipe-ate-exit guard)"
echo "PASS: #68 gate-pipefail guard — 3e.5 gate invocation carries set -o pipefail"

# --- temperloop#115: the 3e.5 gate runSpine call must pass an explicit Bash-tool
# timeout. The full quality-gates.sh suite runs >2min; without a raised timeout
# the executor's Bash tool SIGTERMs it at the default 120s → a false GATE_FAIL on
# every drive. Guard both the named constant and that the gate call threads it,
# so a future edit can't silently drop the timeout and re-break every drive. ----
grep -q 'const GATE_BASH_TIMEOUT_MS' "$MJS" \
  || fail "#115: GATE_BASH_TIMEOUT_MS constant missing — 3e.5 gate would SIGTERM at 120s"
grep -q 'bashTimeoutMs: GATE_BASH_TIMEOUT_MS' "$MJS" \
  || fail "#115: 3e.5 gate runSpine call must pass bashTimeoutMs: GATE_BASH_TIMEOUT_MS"
echo "PASS: #115 gate-timeout guard — 3e.5 gate carries an explicit long Bash-tool timeout"

echo ""
echo "All test_workflow.sh cases passed."
