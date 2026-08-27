- **`/sweep` can now optionally drain Operational-epic members, not just
  ungrouped singletons** (`SWEEP_ADMIT_OPERATIONAL_EPICS`, off by default;
  epic #1847). With the setting on, a Ready sub-issue whose parent epic is
  labeled `Operational` and carries no `Foundational` label anywhere in the
  group joins sweep's fix pool alongside singletons — gated live on every
  pool build by a Foundational-wins re-check, a live-plan-note race guard
  (an epic already under `/assess` is left alone), and triage's
  `<!-- triage:edges-considered -->` marker (a marker-less epic is refused
  rather than admitted on an unconsidered edge read). A genuinely mixed-class
  group is reported, never silently resolved either way. The setting is
  off by default and its effective value survives a routine vendored config
  sync — the operator's opt-in belongs in the gitignored
  `build.config.local.sh`. See `docs/features/sweep.md`.
