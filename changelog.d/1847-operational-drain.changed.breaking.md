- **The Operational/Foundational work-class labels widen from
  pipeline-driver autonomy policy to a pipeline-wide routing key** (epic
  #1847 (epic-as-metadata for operational work), docs/adr/0030). The
  sweep/assess partition now keys on the work-class label, not on epic
  membership: an `Operational` epic's members drain through `/sweep`
  (admission gated by `SWEEP_ADMIT_OPERATIONAL_EPICS`, default off), and a
  `Foundational` label anywhere in the group — parent or any member,
  evaluated live at every pool build — keeps the whole epic on the
  assess → plan → build ceremony path. Any consumer that read the labels
  as driver-private autonomy policy (the previous scope of
  `claude/work-class-policy.md`'s table) must now treat them as routing
  contract: mislabeling no longer only changes autonomy tier, it changes
  which pipeline drains the work. See
  `docs/features/operational-drain.md`.
- **Triage's edges-never-live-on-the-board charter is formally
  superseded** (docs/adr/0031, same epic). The old invariant — `/triage`
  forbidden to compute or store dependency edges, `/assess` recomputing
  everything fresh per plan note — is replaced by a narrower one: durable
  meaning-level order may live on the board as native `blocked_by` edges
  (stamped by `/triage` at materialization, Operational groups only, with
  a script-backed cycle check and an `edges-considered` marker sweep
  admission requires), while computed merge-safety edges and levels stay
  plan-resident and are still never stored. Tooling or prose that relied
  on the old charter's blanket prohibition must follow the amended
  invariant's single statement site (`claude/commands/triage.md`
  § Operating principles).
