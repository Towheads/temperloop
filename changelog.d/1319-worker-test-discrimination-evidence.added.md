- **A `/build` worker's acceptance self-report now requires — and surfaces —
  proof each check can actually FAIL, not just that it passed.** A
  `passed: true` self-report was indistinguishable, from the returned verdict
  alone, between a genuine test and a vacuously-passing one (a mistargeted
  assertion, a fixture that never exercises the changed path). Every
  `acceptance_results[]` entry now carries an optional
  `discrimination_evidence` field — which mechanism was removed/broken, that
  the suite went RED without it, that restoring it went GREEN
  (`claude/workflows/build-level.mjs` `WORKER_VERDICT_SCHEMA`). On `/build`
  only, `workerPrompt()` requires it via a new, gated
  `## Discrimination evidence` section — armed by a new
  `requireDiscriminationEvidence` `args` key on the same Step-0/Step-3
  hand-off seam as `principlesSummaries`/`gateSliceSecs`; `sweep.md`/`fix.md`
  deliberately omit the key (their shared `workerPrompt()` caller passes a
  bare-string acceptance placeholder with no per-criterion shape for the
  field to attach to), so the requirement does not leak to them. The
  load-bearing other half: `workflows/scripts/build/pr.sh`'s PR-body recap
  (`assemble_body`) now reads `.discrimination_evidence` alongside
  `.criterion`/`.passed`/`.evidence`, so the evidence reaches the human
  reviewing the PR instead of being silently dropped by a jq filter that
  read only the original three fields. `claude/presentation-plane.md` gains
  a kernel-table row registering the worker verdict JSON as a machine-parsed
  surface (schema in `build-level.mjs`, prose contract in
  `claude/commands/build.md` §3c/§3d, kept in lockstep by a new static guard
  in `workflows/scripts/build/tests/test_workflow.sh`).
