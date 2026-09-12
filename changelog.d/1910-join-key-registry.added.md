- **Added the join-key registry** (`workflows/scripts/config/join-keys.tsv`),
  declaring every cross-stream join key the lake consumers use (session id
  forms, GitHub Actions run id, PR number, message id, plan-note stem) with
  its exact normalization rule and absent-versus-zero semantics, backed by
  one shell loader (`join-keys-lib.sh`) and one Python loader
  (`join_keys.py`) — the only two places a session id or other join key is
  normalized. `pr-linkage.sh`'s `Closes #N` probe now reads its
  closing-keyword pattern through the shared loader instead of restating the
  regex inline. A new config checker (`check-join-keys.sh`, wired into
  `scripts/quality-gates.sh`) lints the registry's structure and confirms
  both loaders agree on every fixture (#1910).
