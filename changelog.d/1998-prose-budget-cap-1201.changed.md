- **`PROSE_BUDGET_TIER2_FILE_CAP` raised 1186 → 1201**, reseeded with zero
  headroom to `claude/commands/workshop.md`, which the `/workshop` two-phase
  rewrite (#1958) takes to 1201 lines — passing `claude/commands/build.md` at
  1186 as the largest tracked `claude/**/*.md` file (#1998). The cap is
  **uniform by design** ("never a per-file table"), so this relaxes the
  tier-2 budget for every tracked kernel doc by 15 lines, not `workshop.md`
  alone — an adopter vendoring `build.config.sh` picks up the looser cap for
  their whole kernel doc set. Epic #1938's plan projected the rewrite as net
  *negative* on line count (it removes the coverage walk); measured, it came
  in at **+136** (1065 → 1201), so the plan's own contingency fired — the
  raise ships as its own PR ahead of the item rather than as a mid-build
  config change. **No subtraction pass ran**, deliberately: trimming would
  not have avoided the raise (a ~1195 floor after re-wrapping the touched
  sections is still over 1186), and the spec had just been reviewed clean by
  `docs-reviewer` and `workflow-reviewer` with no redundancy finding, so
  cutting reviewed contract surface on the critical path would delete more
  contract than the ratchet step costs. A genuine subtraction pass over the
  rewritten `workshop.md` is filed as #1999, off the critical path — the same
  two-step #954 took when it filed #956, which then cut that file 1181 →
  1041. Worth stating plainly, since the ratchet is documented as moving both
  ways: since #956 lowered the cap to 1100 it has moved **up eight times** to
  1201 with no subtraction pass in between.
