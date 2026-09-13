- **`state-graph.sh`'s `stale-claims` query now decides liveness from a new
  `transcripts` source — Claude Code's own per-session
  `$CLAUDE_PROJECTS_DIR/*/<sess>*.jsonl` mtime, within
  `RECONCILE_STALE_AFTER_SECS` — the SAME evidence `reconcile.sh --status`
  itself checks (`_reconcile_session_live`), instead of a tmux
  `@claimed_issue` marker or the journal's step-outcome ledger** (#1980).
  ADR 0033 (`docs/adr/0033-derived-state-graph-composes-one-way-with-one-
  independent-cross-check.md`) rests on `state-graph.sh soak` diffing this
  query against reconcile.sh's own claim-liveness class; two prior fixes each
  keyed liveness off a source that comparison never actually invokes — round
  1 off the journal (records *work done*, not *a session existing*: a
  genuinely live session with no step-outcome line yet read as a confident
  false positive), round 2 off tmux markers (`reconcile.sh --status` never
  touches tmux at all — that lens lives only in its separate `markers` mode,
  whose own `board-without-marker` class the soak never diffs). Both were
  scope artifacts manufacturing exactly the standing disagreement this
  cross-check exists to catch. The query now also **gates on host**: a claim
  stamped to another host is excluded from findings entirely, never reported
  stale from local transcript evidence that cannot speak to a foreign host's
  liveness — this host's claim-liveness lens (`reconcile.sh`'s
  `status_reconcile_main`) gates the exact same way before ever checking a
  session's mtime. This matters because the claim stamp is the cross-session
  work lock: a false stale verdict on a live claim invites a second session
  to pick up work already in flight, one host across if the gate were
  missing. The soak's per-class mapping is also narrowed: reconcile's
  `stranded claim stamps on closed issues` class is no longer folded into
  `stale-claims` — the board source's closed-issue residue read never
  attaches a claim stamp to a closed Issue node, so that reconcile class
  could only ever land in `only_in_reconcile`, a class that can never agree
  is not a cross-check. `status:"unknown"` is still reported only when the
  transcripts source itself cannot be read (no transcript directory at all),
  never a confident stale set computed against an incomplete or unrelated
  liveness signal. Scoped to `_sg_query_stale_claims` and
  `_sg_reconcile_class_set`'s awk mapping; `_sg_degraded`, `status-drift`,
  and `resume` are unchanged.
- **`stale-claims` now also gates its claim set on Status: In Progress**,
  matching reconcile.sh's own producer (`reconcile.sh:876-879`), which emits
  its "stale claims" class only for an In-Progress issue. Without this, a
  claim stamp left behind on an issue moved off In Progress — the ordinary
  "Park, don't abandon" residue, since `board_set_status` never clears the
  claim stamp (only `release.sh` does) — surfaced as a confident stale
  finding reconcile.sh structurally never reports, a standing false
  disagreement the mirror image of the closed-issue exclusion above. `_sg_now`
  is a new seam (mirrors `_sg_git`/`_sg_soak_day`) so a test can pin
  `_sg_read_transcripts`'s liveness cutoff comparison exactly on its boundary.
