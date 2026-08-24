- **A denied action must now report every unblock path, grant first** (#1478).
  When a permission control refuses an action — the auto-mode safety
  classifier, a PreToolUse hook, a missing scope — `claude/CLAUDE.kernel.md`
  § Communication conventions now requires the operator-facing message to name
  all three paths in order: **grant the capability**, **run it yourself**,
  **drop or reroute it**. Previously the recurring shape was "here are the
  commands to run yourself", which silently picked the slowest option and
  quietly took a reversible policy choice — whether the session should hold the
  capability — away from the operator whose call it was. The message shape ships
  as the **denied-capability variant** of `claude/message-schema.md`
  § Degradation notice, extending that template's remedy-pointer slot rather
  than paralleling it; the same section records the deliberate call that this
  rule takes **no `/tidy` backstop**, since a denial leaves no durable artifact
  a drain could inspect. Reporting a denial honestly is explicitly not licence
  to re-attempt it in a different shape.
