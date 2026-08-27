- **`work-class-policy.md` catches up to the Operational-epic sweep-admission
  machinery `/sweep`/`/triage` already ship** (epic #1847 ("epic-as-metadata
  for operational work")). The policy table's Operational autonomy path is
  now stated as `triage → sweep` (auto-merge per chunk once CI green;
  modal, never timed, for a correlated set — e.g. an
  epic-admitted member chunk `gate.sh risk` flags), not the stale
  `triage → assess → build`. The doc now also states explicitly that the
  work-class labels have widened from a driver-private setting into a
  pipeline-wide routing key (`/sweep`'s member-admission gate, `/triage`'s
  logical-order stamping both read it), and the `Foundational`-wins
  precedence rule is extended from per-item (a dual-labeled issue) to
  per-group (a mixed-class epic — one `Foundational` member refuses
  admission for the whole group).
- **`next.md` recommends `/sweep` for a triaged Operational epic** instead of
  routing every epic through `/assess`, matching the policy above.
- **`triage.md` and `sweep.md`'s pipeline diagrams now show the class-keyed
  partition** (Operational → `/sweep`, Foundational → `/assess` → `/build`).
- **`ISSUES-ONLY-BACKEND.md` documents the `edges-considered` marker, the
  `keep-open` label, and the durable-logical-vs-computed-merge-safety edge
  split** (docs/adr/0031) — vocabulary the sweep-admission and epic-closing
  gates already consume but that was previously undocumented outside the
  command specs themselves.
