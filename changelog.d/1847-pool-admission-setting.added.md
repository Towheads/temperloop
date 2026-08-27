- **`/sweep` can now optionally drain Operational-epic members, not just
  ungrouped singletons** (`SWEEP_ADMIT_OPERATIONAL_EPICS`, off by default;
  epic #1847 (epic-as-metadata for operational work)). With the setting on,
  a Ready sub-issue whose parent epic is labeled `Operational` — the
  established-pattern half of the Operational/Foundational work-class split —
  and carries no `Foundational` label anywhere in the group joins sweep's
  fix pool alongside singletons. Admission is re-checked live on every pool
  build: a single Foundational label anywhere in the group always wins, an
  epic with a plan note in ANY non-superseded status — under active
  `/assess` review, or already mid-`/build` or finished — is left alone
  (with a distinct reason for each case), and an epic whose member ordering
  triage never finished recording is refused rather than admitted on an
  unconsidered read. A genuinely mixed-class group is
  reported, never silently resolved either way. The setting is off by
  default, and a routine vendored config sync leaves the effective value
  unchanged. See `docs/features/sweep.md`.
