- **`pr.sh push` now reports a push that lands on a ref no open PR watches**
  (#1688). A new `PUSHED_UNWATCHED` outcome (non-zero exit) fires when the
  pushed ref has no open PR while an open PR for the same slug sits on a
  different head ref — the `build/<slug>` vs `fix/<slug>` split a worktree
  re-push falls into. It names both refs and classifies the cause
  (`stale_head_cause: "branch-mismatch"`), so the resulting "stale PR head" is
  distinguishable from GitHub's benign post-force-push head lag, which keeps
  the *same* ref. `build-level.mjs` escalates it as its own
  `push-unwatched-branch` kind rather than opening a PR or polling CI past it —
  the route by which a stale head's green checks become a false `CI_GREEN`. The
  ordinary push-then-open-PR path is unchanged (`PUSHED`, now carrying
  `pr_lookup`/`pr_number`), and an unavailable `gh` degrades fail-soft.
