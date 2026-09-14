- **A `/build` pre-push review agent that hangs can no longer stall the whole
  level** (#2003). The reviewers picked for a change now run concurrently under
  one wall-clock ceiling (`BUILD_REVIEW_AGENT_CEILING_SECS`), with a progress
  notice first at `BUILD_REVIEW_AGENT_SLOW_SECS` so a genuinely slow review is
  visible rather than indistinguishable from a stuck one. A reviewer still
  unreturned at the ceiling is abandoned: an **advisory** one degrades to the
  documented `skipped — <agent> unavailable` notice and the run carries on, and
  a **required** one escalates to the human instead of silently marking the
  review passed. Previously a single reviewer that never returned kept every
  later reviewer from launching at all — including the required review of a
  change to a command spec under `claude/commands/` — and the run went quiet
  with no review verdict ever reached, which looked exactly like a review still
  in progress.
