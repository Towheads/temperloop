- **`/build` workers are now told the engineering principles they're expected
  to weigh against.** `claude/commands/build.md` §3c required embedding the
  effective (kernel ∪ project) engineering principle set in every worker
  prompt, but nothing implemented it. A new **§ Step 1.8** resolves the
  merged set once per run, per distinct `(repo, project)` pair — the kernel
  set from `claude/engineering-principles.md` merged with the project's own
  `## Principles` extension, per that file's § Merge semantics — and hands
  the rendered result to `claude/workflows/build-level.mjs` as two new
  `args` keys on the same Step-0 hand-off seam as `machinerySoloModel`/
  `gateSliceSecs`: `principlesSummaries` and `principlesDefaultRepo`.
  `workerPrompt()` embeds the resolved set as a tagged `[kernel]`/`[project]`
  numbered list in a new `## Effective engineering principles` section,
  reused (not re-resolved) by §3e's pre-push reviewer. A caller that omits
  the new args keys — `sweep.md`/`fix.md` today — still gets a bounded,
  legible prompt: `workerPrompt()` falls back to a static kernel-only
  snapshot plus an explicit `DEGRADED` notice, never a silent empty set.
