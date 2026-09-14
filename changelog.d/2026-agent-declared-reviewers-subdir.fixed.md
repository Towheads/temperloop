- **`agent_declared_state` now resolves the `reviewers/` catalog subdir at
  every agent directory it probes, not just the checkout's source tree**
  (#2026). A per-language reviewer installed at
  `~/.claude/agents/reviewers/<name>.md` — the shape on a host whose
  machine-global agent dir points at a kernel checkout's `claude/agents` —
  missed the machine surface's flat-only check and was reported
  `source-only`. Because `installed` is the documented spawn gate, a caller
  obeying the contract silently skipped a review seat that was live and
  spawnable. The project-scoped `.claude/agents/` surface gains the same arm,
  so the same layout resolves identically wherever it appears. Surface
  precedence is unchanged: a live install still outranks a shipped-only hit,
  and nothing moves out of `absent`.
