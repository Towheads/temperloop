- **The model-comparison replay module gains corpus selection and an
  isolated replay worktree** (#1254, epic #1225 "model comparison harness").
  `workflows/scripts/model-comparison/replay.sh` adds `resolve-base`
  (fork-point base resolution — `git merge-base <merge>^1 <merge>^2`, never
  `<merge>^1` or the moving `baseRefOid`), `diff-scope` (the N/T/X/R
  solution-surface/test/policy-churn/residue partition, rejecting unnamed
  code residue and flagging an md-only residue rather than silently
  accepting or dropping it), `corpus` (real `gh` reads selecting eligible
  closed-issue + merged-PR pairs from a repo's own history, applying every
  contamination-trap disposition from the ground-truth spike and ranking
  eligible PRs by scored footprint — smaller/single-purpose first), and
  `worktree-prepare`/`worktree-teardown`/`verify-clean-parent` (an isolated
  replay worktree built on `workflows/scripts/build/worktree.sh`'s existing,
  unmodified lifecycle: a worktree-scoped push-remote disable so no
  `git push` from inside it can reach a real remote, the same per-worktree
  write-jail guard marker every `/build` worker worktree gets, and a
  deterministic per-repo scratch path — each asserted structurally and
  independently, with `verify-clean-parent` as a documented backstop, never
  the primary control). `schema` prints the versioned scored-record shape
  (`replay-record-v1`) downstream consumers can build against before replay
  execution/scoring lands. Four new registered settings
  (`REPLAY_CORPUS_LIMIT`, `REPLAY_CORPUS_SAMPLE_MULTIPLIER`,
  `REPLAY_NAMED_PATH_EXTENSIONS`, `REPLAY_PUSH_DISABLE_SENTINEL`) and a new
  `scripts/quality-gates.sh` entry
  (`workflows/scripts/model-comparison/tests/test_replay_isolation.sh`).

