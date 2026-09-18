- **New `PreToolUse` guard `claude/hooks/arm-read-guard.sh` enforces dual-build
  arm read isolation** (#2077). When a worktree carries a `.dual-build-arm`
  marker — written only while the dual-build harness is building one item under
  two models — a `Read`, `Glob`, `Grep` or `Bash` call that reaches the sibling
  arm's worktree path or branch is **denied**, and the attempt is recorded in
  `.dual-build-cross-read-attempts.jsonl` beside the marker, so a blocked
  attempt leaves a trace instead of looking like a clean run. (The harness that
  writes the marker and reads that trace lands with epic #2065; until then the
  file beside the marker is the whole record.) Without that marker the hook has
  no effect at all, and any internal error fails open, so a session that is not
  an arm of a dual build is never affected. Registering it is opt-in: add it to
  your own Claude Code settings under the `Read|Glob|Grep|Bash` matcher. This is
  the one hook the model-comparison module ships — see the amendment to
  `docs/adr/0027-model-comparison-ships-as-an-inert-opt-in-module.md`.
