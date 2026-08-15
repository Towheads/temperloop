- **`score.sh` now persists the candidate's real diff text and gives the X
  and R buckets the same per-path candidate-vs-truth attribution the N
  bucket already carried** (#1579). A scored replay record's
  `score.diff.text_excerpt` field captures the candidate's actual patch
  text — including untracked new files — while the leg's worktree is still
  live (`batch.sh` tears it down immediately after replay), truncated at
  `REPLAY_SCORE_DIFF_EXCERPT_MAX_BYTES` with an explicit marker when
  oversized. **BREAKING:** `score.diff.x.paths` and `score.diff.r.paths`
  changed shape from bare path-string arrays to the same per-path
  attribution objects `score.diff.n.files` already carries (`path`,
  `changed`, `matches_truth`, `truth_added`/`truth_removed`,
  `candidate_added`/`candidate_removed`, `formatting_only_truth_churn`) — a
  downstream reader of a pre-#1579 record's X/R paths as plain strings must
  update to read `.path` off each element instead.
