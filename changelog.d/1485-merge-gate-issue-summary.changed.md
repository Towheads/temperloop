- **The merge-gate approval prompt now leads with the defect, not just the
  fix** (#1485). `claude/message-schema.md` § Question block gains one named
  conditionally-required slot — **Problem summary** — required whenever a
  block asks the operator to approve work that resolves a tracked item: a
  compressed one-to-two-line restatement of the linked issue's own defect
  statement (never its title, which the block already carries), ordered
  problem-first. The slot names a **real, reachable source** — one
  `gh issue view <n> -R <owner>/<repo> --json body` taken at ask time —
  because nothing earlier in a run holds the defect prose:
  `workflows/scripts/build/issue-state.sh resolve` fetches
  `state,labels,assignees` only, so a resolved issue *number* is not its
  defect statement. The read is negligible where the slot applies (the gate
  fires once per run, at a point already issuing `gh` calls for the
  `gate.sh backend` probe). The slot defines **three arms**, all reachable
  and all implemented at both consumer sites: the summary rendered;
  `no linked issue — <reason>` when there is no tracked item; and
  `summary unavailable — <reason>` when the read fails or returns an empty
  body — with an explicit **never-fabricate** rule, since a restatement
  inferred from a title or a diff is strictly worse than a stated absence in
  the one artifact meant to strengthen merge consent.
  `claude/commands/fix.md` Step 5 (the `decision_sink_ask` payload) and
  `claude/commands/build.md` 4a (the per-PR text block, where the 4b option
  labels' length/4-option cap cannot reach; 4b defers to 4a's rendering)
  both defer to that slot **by name** rather than restating its shape, and
  4a's `↳ defect #<n>: …` line is qualified `owner/repo#N` when the item's
  `repo:` differs from the plan's home repo, mirroring the rule 3f already
  applies to `Closes`. Previously every named payload slot described the
  *change* — PR #, title, CI state, the fix, the backend — so an operator
  approving hours or days after filing had to recall the defect or go read
  the issue, and consented to a merge without the one thing needed to judge
  whether it addressed the right problem.
