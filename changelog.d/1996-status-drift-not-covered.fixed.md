- **`state-graph.sh soak` no longer manufactures a standing false
  disagreement for a status-drift finding kind `reconcile.sh --status`
  cannot report** (#1996). `_sg_query_status_drift` emits three finding
  kinds; only two have a counterpart in the `--status` lens the soak
  compares against. The third, `claimed_not_in_progress`, has its real
  counterpart in reconcile class (m) `PARKED claim stamps on OPEN issues` —
  which lives in `label_reconcile_main`, the `--labels` lens `_sg_soak_run`
  never invokes — so every parked-but-stamped item landed in
  `only_in_drift_query` and could never agree. That is not a corner case:
  the kernel's own "Park, don't abandon" flow produces the residue every
  time (`board_set_status` moves an issue off In Progress without clearing
  its claim stamp; only `release.sh` clears it). The soak now gates the
  comparison **per finding kind** and records the excluded kinds by name in
  each class entry's new `not_covered_kinds` field — the per-kind analogue
  of the class-level `"not-covered"` literal `unlinked-prs` /
  `orphan-worktrees` already read, and never a silent narrowing.
- The other two options #1996 listed were rejected on the record:
  narrowing the **query** would delete a true drift finding that
  `query status-drift` and `_sg_query_resume` both consume, and widening
  the soak to **also invoke `reconcile.sh --labels`** would add a second
  reconcile invocation and a second report-shape parser — more divergence
  surface in the one place divergence *is* the bug, the same reasoning
  #1980 round 3 rejected its analogue for. The reasoning is recorded beside
  the code (`_SG_SOAK_STATUS_DRIFT_KIND_COUNTERPART`) together with the
  kind-by-kind audit, and a test fails if a **fourth** kind is ever added
  without being dispositioned against what `--status` can emit — this is
  the third time this mismatch shape has been rediscovered.
- Run records stay at `schema:2` deliberately: this adds a field and
  narrows what `drift_query_set` contains, but does not change the
  per-class shape `soak --count` keys on, so the fourteen-day independence
  count is **not** reset a second time.
