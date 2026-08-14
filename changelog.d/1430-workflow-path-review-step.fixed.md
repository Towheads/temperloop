- **`/build`'s mandatory pre-push review now actually runs on the default
  Workflow path.** `claude/commands/build.md` §3e requires a `workflow-reviewer`
  pass on every item whose diff touches `claude/commands/*.md` (foundation#1007),
  but the 3c worker cannot spawn a nested subagent — so on the default
  (Workflow) build path the gate collapsed to a **structurally guaranteed**
  `skipped — unavailable`, indistinguishable from a genuine unavailability.
  `claude/workflows/build-level.mjs`'s `driveItem` now runs §3e itself, between
  3d and 3e.5: it fetches the item's changed-file list and the
  `reviewer-routing.tsv` off the worktree, resolves the full routing rule set
  (`determineReviewers` — the `review:` override, the `architectural` change
  kind, the tsv extension/glob axis, the prose `*.md` fallback, and the
  mandatory `claude/commands/*.md` → `workflow-reviewer` rule), and spawns each
  matching reviewer directly via `agent({agentType})`. A `HIGH`-severity finding
  escalates `review-blocking` before 3f (push); reviewer unavailability
  degrades legibly (reusing `machineryAgent`'s own resolution-failure catch),
  and a real pass's outcome now rides the PR body via the verdict `summary`, so
  `workflows/scripts/workflow-reviewer-coverage.sh` can actually observe
  coverage going forward. §3e also now records why this review runs *inside*
  the workflow rather than the conversational orchestrator: the
  orchestrator↔workflow boundary is irreversible-action-plus-single-writer, and
  by the time the workflow returns, 3h has removed the worktree and 3h.5 may
  already have merged the PR.
