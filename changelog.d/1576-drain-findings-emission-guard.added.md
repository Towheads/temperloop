- **`/tidy`'s drain findings emission is now mechanically corroborated, not
  self-reported** (#1576). A drain run's Step 6 summary once asserted
  "Findings records: 16 emitted (8 accepted, 8 rejected)" while **zero** rows
  actually existed in `meta/data/raw/findings-<YYYY-MM>.jsonl` that day — an
  unverified positive-work claim the run had no way to catch on its own. The
  new `workflows/scripts/drain/findings_integrity.py` checker (the single
  findings-integrity checker; a follow-up item extends this same file rather
  than adding a sibling script) compares a drain run's per-session
  self-reported accept/reject tally against the rows that actually landed in
  the append-only findings stream, printing the literal token
  `FINDINGS_EMITTED_MISMATCH` on any divergence — including the case where a
  processed transcript found candidates to adjudicate but landed zero rows
  (distinguished from a transcript with genuinely nothing to extract, which
  legitimately self-reports and lands zero). `claude/commands/tidy.md`'s
  Findings records step now runs this check before writing the summary line,
  and treats a mismatch as a run failure to surface, not a log line.
