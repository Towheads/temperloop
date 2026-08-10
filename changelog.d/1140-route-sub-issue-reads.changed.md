- **The four command-spec sub-issue *reads* now route through the board
  adapter's `board_sub_issues` instead of a raw `gh api .../sub_issues`
  call** (#1140): `assess.md`'s candidate-item enumeration, `build.md`'s
  epic-close open-children count, `next.md`'s epic-state rollup, and
  `fix.md`'s epic-size refusal gate. Each site sources `lib/board.sh` plus a
  guarded `lib/cache.sh` in the same Bash call it reads from (shell state
  does not persist across calls) and, at the two gate-bearing sites
  (`build.md`'s epic-close count, `fix.md`'s refusal gate), carries an
  inline note that the read must stay LIVE — `board_sub_issues` has no
  cached arm today (removed in #1163), and a future cached arm pointed at
  either gate without re-litigating that is the #1030 failure mode (a
  cached read silently reporting 0 children armed a wrongful epic-close).
  This is the prose half of the routing #1119/PR #1139 already applied on
  the script side (`build/board-mirror.sh`), which also added the
  `[all|open|closed]` state filter `build.md`'s open-count now uses. No
  write site is touched.
