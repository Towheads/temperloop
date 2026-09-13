- **`/fix` no longer discards a finished build when the pre-push reviewer
  blocks it** (#1988). Step 4a's no-in-place-continuation rule was blanket, so
  a `review-blocking` escalation — raised *after* the acceptance gate passed,
  with the whole fix already committed in the worktree — parked the target,
  released the claim and removed the worktree, forcing the entire build to be
  re-earned for what is often a few lines. The rule is now scoped to the
  **pre-acceptance** kinds (`blocked` / `design-fork` / `failed` / machinery /
  `acceptance-incomplete`), where little or no accepted work exists and the
  lossless-re-run guarantee still applies. A **post-acceptance** escalation
  instead takes the continuation path `build-level.mjs` already supports
  natively — `onlySlugs: [<slug>]` plus `verdicts[<slug>].verdict_section` —
  resuming at 3c against the intact worktree, keeping both the worktree and
  the claim, and skipping the 3a re-claim and the 3b `worktree.sh create`
  whose force-recreate was what destroyed the build.
