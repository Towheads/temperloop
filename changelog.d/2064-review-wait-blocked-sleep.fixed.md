- **A §3e review reviewer that overran its ceiling is now reported `timed out
  after <actual>s`, not `unavailable`** (#2064). `unavailable` is the kernel's
  capability-probe verdict — the agent is not declared in `CLAUDE.md §
  Subagents` or `.claude/agents/` — so using it for an agent that *was*
  spawned and simply ran long pointed every investigator at the agent roster,
  where nothing was wrong. The two senses now carry two wordings, and the
  timeout wording reports the wall clock actually waited rather than the
  ceiling budgeted; when those two numbers disagree, the gap is itself the
  defect. `claude/message-schema.md` § Degradation notice records the new
  shape as the second of the three sanctioned mode-2 skip forms.
- **A wall-clock tick the harness *refused* can no longer be read as an
  elapsed interval** (#2064). The §3e ceiling's timer reports through an
  executor that cannot tell a permission block from a Bash-tool timeout kill —
  both are "no output" — and one of those two arms was permissive. The
  refusal is now recognised from the harness's own text before any outcome
  label is trusted, and fails closed: the ceiling is simply not applied, and
  the run says so. A genuine tool timeout is unchanged and still bounds the
  fanout. Measured cost of the old behaviour: a 1200s review ceiling that
  realized in ~41s, discarding completed reviews.
