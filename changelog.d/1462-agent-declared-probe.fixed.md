- **The review-agent availability probe no longer reports every reviewer
  unavailable on a checkout whose agents live in `~/.claude/agents/`** (#1462).
  The canonical predicate names two surfaces — `CLAUDE.md § Subagents` or
  `.claude/agents/` — and the kernel's own dogfooding checkout has neither:
  `.claude/agents/` is gitignored (`project-agents.sh` deploys it per-checkout,
  so a fresh clone has none) and `CLAUDE.md` carries no `## Subagents` heading.
  All eleven agents are nonetheless installed and spawnable from
  `$HOME/.claude/agents/`, so read literally the predicate returned
  *unavailable* for every one of them — and `build.md` §3e's **mandatory**
  `workflow-reviewer` pass and `/workshop` §3.3's adversarial panel both gate on
  it, so both emitted all-skip lines for agents that would have spawned fine. A
  skip line that fires for an available agent is itself a mandatory step
  silently not running: the temperloop#1387 all-skip outcome by a second,
  independent route. `docs/adr/0008-command-declared-probe.md` had documented
  this exact false-negative class for slash commands and noted the subagent
  probe lacked the equivalent; `workflows/scripts/lib/agent_declared.sh` (ADR
  0029) is that equivalent, mirroring `command_declared.sh`'s three-surface
  order with `agents/` for `commands/` rather than inventing a new one, and
  keeping the canonical predicate's `CLAUDE.md § Subagents` clause as a
  declaration surface probed first. Availability is now three-valued —
  `agent_declared_state` prints `installed`, `source-only`, or `absent` — so
  the two degradation-notice forms are *selected* rather than guessed:
  `installed` is the spawn gate, `source-only` gets the remedy-bearing "run
  `project-agents.sh` to enable" line, and `absent` still gets the bare
  `skipped — <agent> unavailable`. Absence and indeterminacy stay
  distinguishable on purpose: a probe that made everything look available would
  fabricate reviews that never ran, exactly as wrong as the bug it replaces. A
  live surface also outranks a source hit, so an agent that both ships and is
  installed reads `installed` — first-resolved-wins there would have
  re-introduced the same skip one layer in. `test_agent_declared.sh` pins each
  surface independently, the genuinely-absent case, the shipped-and-installed
  case, and the `AGENT_DECLARED_OVERRIDE` fixture seam.
