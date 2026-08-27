- **`build-level.mjs` reports a session-quota death as its own `quota-exhausted`
  escalation kind** (#1819), never collapsing it into `machinery-denied`/
  `SPINE_DENIED` (whose cure is rewriting the command) or a bare `worker-error`
  "agent returned null" (whose cure is re-driving from scratch — destructive,
  since a quota death usually leaves finished work intact in the worktree). The
  thrown-error-text shape is matched directly and carries the harness's reset
  time in the payload's `reset_time`; the bare-null shape — which carries no
  text at all — is classified by an agent-liveness canary (a classifier denial
  is per-command, a quota death kills every spawn), which re-probes on every
  bare-null and memoizes only a DEAD verdict — an alive reading is never
  cached, so a quota that dies late in a level cannot be misrouted through a
  stale early "alive". The payload states
  `worktree_left_intact: true`, and `claude/commands/build.md` documents the
  kind's wait-for-reset-then-resume disposition in the 3d-esc escalation-kind
  list plus an orchestrator-side `<failures>`-block cross-check.
