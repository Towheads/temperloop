- **One ontology registry for the tracker and plan vocabularies** —
  ADR 0032 (ontology registry is source of truth); epic #1910 (graph-of-record
  ontology work), level 0.
  `workflows/scripts/config/ontology-registry.tsv` is now the single source
  of truth for the node types, edge types, the four state
  alphabets (issue-status `fnd:status:*` labels, plan sentinels, PR merge
  state + decision baton, the `issue-state.sh resolve` route enum) and the
  `source` axis naming every store the state graph reads. A new `checks` gate,
  `check-ontology-registry.sh`, scans the tracked tree for any `fnd:` label or
  plan sentinel the registry does not list (a shrink-only
  `ontology-grandfather-allowlist.tsv` absorbs adoption-day legacy tokens; the
  `x-` personal prefix is exempt), holds the route alphabet set-equal to
  `issue-state.sh`'s published enum, and fails a contract doc that drops its
  pointer or restates a vocabulary table. `ISSUES-ONLY-BACKEND.md`,
  `plan-schema.md`, `decision-queue-contract.md` and `work-class-policy.md`
  now carry a one-line pointer where each restated its table.
