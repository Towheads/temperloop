- **A `/build` §3e review agent that hangs can no longer stall the whole level**
  (#2003). The routed reviewers now run concurrently under one wall-clock
  ceiling (`BUILD_REVIEW_AGENT_CEILING_SECS`, with a progress notice first at
  `BUILD_REVIEW_AGENT_SLOW_SECS`); a reviewer still unreturned at the ceiling is
  abandoned, with an **advisory** one degrading to the documented
  `skipped — <agent> unavailable` notice and a **mandatory** one escalating
  `review-agent-timeout` carrying a computed `mandatory_ok`. Previously one
  reviewer that never returned kept every later reviewer — including the
  mandatory `workflow-reviewer` for a `claude/commands/*.md` diff — from
  launching at all, and the run went silent with its tally never evaluated.
