- **The merge-gate approval prompt now leads with the defect, not just the
  fix** (#1485). `claude/message-schema.md` § Question block gains one named
  conditionally-required slot — **Problem summary** — required whenever a
  block asks the operator to approve work that resolves a tracked item: a
  compressed one-to-two-line restatement of the linked issue's own defect
  statement (never its title, which the block already carries), ordered
  problem-first, drawn from an issue the run already holds so the slot
  licenses no new fetch, and with an explicit `no linked issue — <reason>`
  arm so an untracked refactor renders the absence rather than dropping the
  slot. `claude/commands/fix.md` Step 5 (the `decision_sink_ask` payload)
  and `claude/commands/build.md` Step 4a (the per-PR text block, where the
  4b option labels' length/4-option cap cannot reach) both defer to that
  slot by name instead of restating its shape. Previously every named
  payload slot described the *change* — PR #, title, CI state, the fix, the
  backend — so an operator approving hours or days after filing had to
  recall the defect or go read the issue, and consented to a merge without
  the one thing needed to judge whether it addressed the right problem.
