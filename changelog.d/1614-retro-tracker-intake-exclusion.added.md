- **`/triage` Step 1 Adapter A gained a third naturally-excluded intake
  bucket: the process-record label filter** (#1614). A `Backlog` item carrying
  one of `TRIAGE_INTAKE_EXCLUDE_LABELS` (new setting, default: the
  `retro-pending` / `retro-info` process-retro tracker state labels `/build`
  4d-retro mints at epic close) is skipped from intake and reported on its own
  mandatory Step-5 summary line, alongside the existing inactive-milestone
  `deferred[]` and open-`blocked_by` `blocked[]` lines. These trackers are
  durable build-health *records* with no correct triage outcome — promoting
  one to `Ready` hands a build-health record to a `/sweep` fix worker, culling
  one closes a record its consumer still reads by label — so an exclusion, not
  a routing rule, is the right shape. The mechanical half is
  `workflows/scripts/build/triage-intake-exclusion.sh`, a side-effect-free
  classifier over the already-resolved board item list (zero extra REST calls,
  which is why it runs before its two per-candidate-REST siblings), covered by
  offline fixtures in
  `workflows/scripts/build/tests/test_triage_intake_exclusion.sh`.
  The invocation carries a **named failure path**: the classifier path is
  resolved dual-path and `-x`-tested (the shape Step 4.8a's `claim-guard.sh`
  already uses) with the run itself inside the guard, so a classifier that is
  absent **or** exits non-zero takes one explicit degraded arm — a `SKIPPED
  … intaken UNFILTERED` Step-5 line, `excluded[] = []`, and a refusal to cull
  or promote any candidate carrying an exclusion label. A missing script can
  never quietly degrade to unfiltered intake.
