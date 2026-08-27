- **`/assess` now refuses to decompose an epic that `/sweep` already owns**
  (epic #1847 (epic-as-metadata for operational work), item 5 of the
  mutual-exclusion pair). When the checkout-wide `SWEEP_ADMIT_OPERATIONAL_EPICS`
  setting is on, an Operational epic with no `Foundational` label anywhere
  in the group drains through `/sweep`, not through `/assess` → `/build` —
  running `/assess --epic <N>` on one now stops with a message naming the
  sweep path, `docs/features/operational-drain.md`, and the checkout-wide
  scope of the setting, rather than silently decomposing an epic two
  mechanisms could then double-drive. The autonomous pipeline driver's own
  `route-foundational` hand-off is exempted (it predates the sweep cutover,
  #1848 "pipeline-drive sweep-cutover rewiring"), and a new
  `--override-operational-refusal` flag lets an operator
  explicitly proceed anyway — the override is always logged, both as a
  comment on the epic and as a bullet in the written plan note.
