- **`pipeline-spend-report.sh` gains an opt-in `--by-agent-type` flag** (#1314), a
  per-seat attribution side channel over Claude Code's own agent-frontmatter
  sidecars (`agent-<id>.meta.json`). Requires `--root` to name a single Claude
  Code project directory (one whose session subdirectories hold at least one
  `subagents/agent-*.jsonl` journal) and refuses with exit 2 otherwise, rather
  than ever walking machine-wide. The emitted `by_agent_type` JSON key is
  self-contained — its `agents`/`api_calls`/`units` totals are NEVER a
  decomposition of the existing `units_total` headline, which this flag leaves
  completely untouched (`schema_version` stays `1`). A sidecar's `agentType` is
  reported as a seat only when it matches a deployed `claude/agents/**/*.md`
  basename (an allowlist, not a passthrough — `general-purpose` and friends
  bucket to `unattributed`, with the raw value kept visible for distribution
  rather than asserted as a seat). See ADR 0026's temperloop#1314 corrections
  for the rationale.
