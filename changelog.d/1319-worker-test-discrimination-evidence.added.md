- **A `/build` worker's acceptance self-report now requires — and surfaces —
  proof each check can actually FAIL, not just that it passed, and a missing
  proof is a visible degradation rather than a silent one.** A `passed: true`
  self-report was indistinguishable, from the returned verdict alone, between
  a genuine test and a vacuously-passing one (a mistargeted assertion, a
  fixture that never exercises the changed path). Every `acceptance_results[]`
  entry now carries an optional `discrimination_evidence` field — which
  mechanism was removed/broken, that the suite went RED without it, that
  restoring it went GREEN (`claude/workflows/build-level.mjs`
  `WORKER_VERDICT_SCHEMA`). On `/build` only, `workerPrompt()` requires it via
  a new, gated `## Discrimination evidence` section — armed by a new
  `requireDiscriminationEvidence` `args` key on the same Step-0/Step-3
  hand-off seam as `principlesSummaries`/`gateSliceSecs`; `sweep.md`/`fix.md`
  deliberately omit the key today (an operational scope decision — their own
  `acceptance:` field CAN carry a real per-criterion bullet array, same as
  `/build`'s, so this is not a structural exclusion), so the requirement does
  not leak to them. The load-bearing other half:
  `workflows/scripts/build/pr.sh`'s PR-body recap (`assemble_body`) now reads
  `.discrimination_evidence` alongside `.criterion`/`.passed`/`.evidence`, so
  the evidence reaches the human reviewing the PR instead of being silently
  dropped by a jq filter that read only the original three fields.
  **The field itself is schema-optional and unenforced by §3d/§3e.5 by
  design** (kernel principle 7, advisory over enforced discipline) — so a
  worker that simply omits it degrades LEGIBLY instead of silently: a new
  `discriminationGaps()` in `build-level.mjs` detects any `passed: true` entry
  with an empty/absent `discrimination_evidence` once `requireDiscriminationEvidence`
  is armed, logs a named warning at 3h once the PR number is known, and
  carries the gap list on the parked record's new `discrimination_gaps` field
  for the orchestrator to roll into the Step 6 summary — mirroring the
  existing `verification_surface` degraded-case pattern (build.md §3f step 2)
  exactly. A criterion deferred to the parent-side §3e.5 acceptance gate
  (build.md's pre-existing #997 carve-out) is a distinct, explicit exemption
  — its `discrimination_evidence` reads `deferred to §3e.5; discrimination not
  established worker-side` rather than being left empty or fabricated.
  `claude/presentation-plane.md` gains a kernel-table row registering the
  worker verdict JSON as a machine-parsed surface (schema in
  `build-level.mjs`, prose contract in `claude/commands/build.md` §3c/§3d,
  kept in lockstep by a new static guard in
  `workflows/scripts/build/tests/test_workflow.sh`). `PROSE_BUDGET_TIER2_FILE_CAP`
  (`workflows/scripts/build/build.config.sh`) is raised 1111 → 1130 to fund
  this item's degraded-case prose plus headroom for the concurrently-building
  sibling item #1430.
