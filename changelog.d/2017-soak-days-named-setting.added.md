- **The state-graph soak's required day count is now a named setting**
  (#2017). `STATE_GRAPH_SOAK_DAYS` in
  `workflows/scripts/build/build.config.sh` is the one place the soak length
  is stated: how many distinct recorded days `state-graph.sh soak --count`
  must reach before the cross-check against the independent
  `reconcile.sh --status` read is treated as trustworthy. The length was
  previously spelled out as a bare word across several comments, with no
  single place to change it and no recorded reason for the number. The
  default is unchanged, and its rationale now sits beside it — a judgment
  call about how many varied board situations a soak gets to observe (parks,
  merges, claims going stale, worktrees appearing and vanishing), not a
  derived sample size. Nothing in the tree reads the setting yet: the soak's
  own commands report the recorded day count and leave the sufficiency call
  to whoever is watching.
