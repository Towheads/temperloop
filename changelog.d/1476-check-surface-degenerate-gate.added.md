- **A new CI gate now requires every registered check surface to prove it can
  fail — ship a fixture asserting a non-zero exit on absent, unreadable, and
  empty input — closing the class behind epic #1409's three motivating
  defects** (a validator that read `OK` / exit 0 off input it never actually
  read). `workflows/scripts/validate-check-surface-degenerate-coverage.sh`
  enforces a REGISTRY (`workflows/scripts/config/check-surface-registry.tsv`),
  not a `validate-*.sh` filename glob — a registry row names either a bare
  script or a `<script>:<subcommand>` pair, so `replay.sh diff-scope` (a
  subcommand of a general orchestration script, unreachable by any filename
  glob) is registerable. Surfaces not yet compliant ride an explicit,
  shrink-only ratchet (`workflows/scripts/config/check-surface-degenerate-allowlist.tsv`)
  — the gate FAILS if the allowlist grows, diffed against the committed copy
  at `origin/main`, with an explicit bootstrap exemption for the commit that
  introduces the file itself. Seeded with the epic's three motivating
  surfaces: `validate-provider-disclosure.sh` gets brand-new dedicated
  degenerate-input fixtures (`workflows/scripts/tests/test_validate_provider_disclosure.sh`
  — absent committed allowlist, unreadable disclosure log, and an
  emptied-in-place log whose watermark anchor still records entries);
  `validate-model-usage-emit.sh` and `replay.sh diff-scope` are registered
  as already-compliant against their existing fixtures (`test_model_usage_emit.sh`,
  `test_replay_isolation.sh`), unmodified. `tagging.sh` (#1480) and
  `batch.sh`'s line-141 bootstrap check (#1487) are named on the allowlist,
  explicitly out of this item's scope. The gate is itself fail-closed —
  routed through the shared `cannot_evaluate_emit` idiom
  (`workflows/scripts/lib/cannot-evaluate.sh`) on an unreadable registry/
  allowlist/registered test file or an unresolvable ratchet base ref — and
  every ordinary failure names the exact surface and case (`MISSING-FIXTURE`,
  `TEST-FILE-NOT-GATED`, `REGISTRY-INCOMPLETE`, `ALLOWLIST-GREW`, ...),
  never a bare non-zero exit. Its own fixture suite
  (`workflows/scripts/tests/test_check_surface_degenerate_coverage.sh`)
  proves the gate discriminates by mutation — delete a registered fixture's
  anchor, confirm RED naming the surface+case, restore, confirm GREEN — plus
  the allowlist-growth ratchet against a throwaway git fixture and every
  CANNOT-EVALUATE fail-closed path.
