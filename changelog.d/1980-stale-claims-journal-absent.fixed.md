- **`state-graph.sh`'s `stale-claims` query now decides liveness from the
  tmux `@claimed_issue` marker source — the same one `reconcile.sh` itself
  checks — instead of the journal's step-outcome ledger** (#1980). The
  journal records *work done*, not *a session existing*: a genuinely live
  session that had not yet written a step-outcome line produced no journal
  node at all, so a claim it held was still read as a **confident false
  positive** (`status:"ok"`, the claim reported stale) even after this
  query's first fix stopped flagging *every* claim when the journal was
  wholly absent. That false positive matters because the claim stamp is the
  cross-session work lock — reporting a live claim as stale invites a second
  session to pick up work already in flight. The query now reports
  `status:"unknown"` only when the tmux source itself cannot be read (no
  binary, no reachable server), never a confident stale set computed against
  an incomplete or unrelated liveness signal. Scoped to
  `_sg_query_stale_claims`; `_sg_degraded`, `status-drift`, and `resume` are
  unchanged.
