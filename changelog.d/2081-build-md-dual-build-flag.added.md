- **`/build` gained a `--dual-build <tier>=<candidate>` flag** (temperloop#2081,
  epic #2065 "new-work dual-build harness"). Given the flag, every plan item
  whose declared model tier matches `<tier>` is built **twice** inside its
  dependency level — once on that tier's current baseline model, once on the
  candidate model under test — so the two can be compared on work the repo was
  going to do anyway, rather than on already-closed work. The flag is
  **per-invocation and the only thing that arms the harness**: no setting,
  environment variable, plan-note field or previous run can turn it on, so a
  `/build` without it behaves exactly as it did before. Two settings supply
  defaults only — the baseline arm's model, and the candidate's when the
  `=<candidate>` half is left off — and both are fixed literals in the repo's
  own tracked config rather than values inherited from the operator's home
  directory or from whatever model the calling session happens to be running,
  because each arm's model has to stay fixed and disclosed for a whole level.
  Before anything is built, a new **Step 1.9** projects the spend for every
  level through `dual-build-preflight.sh`, prints by name any level that
  pre-flight declines (too few in-scope items, no usable credential for the
  candidate's provider, or a projected spend over the shared ceiling) and
  builds those single-arm, then asks the operator for consent **once** for the
  whole run. That consent has no safe default and is never timed: with no
  operator present the question is posted and the run parks rather than
  doubling anyone's spend on a timeout. Step 1.9 also states the refusal for a
  half-finished comparison — a `/build` resumed **without** the flag over a
  level whose two arms were both left live stops and says so, instead of
  finishing single-arm and thereby picking a side nobody chose. This entry is
  the command specification only: the flag's consented output is handed to the
  build engine as a `dualBuild` input, and the engine that actually builds two
  arms, judges them and picks a winner lands with later items in the same epic
  — so on today's engine the hand-off is inert and reports itself as such.
