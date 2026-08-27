- **`/sweep`'s per-chunk merge pass now regime-selects member-bearing chunks
  before merging** (#1847 follow-on). A chunk containing at least one
  Operational-epic-admitted member (`SWEEP_ADMIT_OPERATIONAL_EPICS`) runs the
  mechanical `gate.sh risk` partition over its mergeable PR set before
  landing anything; a `RISKY` verdict is offered modally (an `AskUserQuestion`
  when attended, held with no auto-merge when operator-absent) rather than
  auto-merged, preserving the kernel merge-autonomy contract that only a
  clean, disjoint set is timed. A singleton-only chunk is unaffected — it
  skips the gate entirely and merges exactly as before.
