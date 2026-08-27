- **Every claim-stamp derivation now routes through `board_own_stamp` /
  `board_host_label`** (#1823, completing #1220's centralization at 6/6 call
  sites). `issue-state.sh resolve` hand-rolled the stamp with no `:manual`
  arm, so a claim made by a session-id-less (manual) run read back as
  `by_me: false` / `claimed-elsewhere`; it, `release.sh`'s duplicate
  `release_own_stamp`, and `board-mirror.sh`'s two inline derivations now all
  call the single `lib/board.sh` owner, and a regression test covers the
  `<host>:manual` self-claim case.
