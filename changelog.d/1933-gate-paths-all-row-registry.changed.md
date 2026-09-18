- **A gate-registration-only `scripts/quality-gates.sh` diff no longer escalates
  a scoped run to the full gate suite** (#1933). That file sits on
  `gate-paths.tsv`'s `ALL` row, so adding one gate line ran all ~110 suites.
  When the diff removes nothing and its added lines are exclusively gate
  registrations (comments and blanks may ride along), the selector now declines
  the `ALL` escalation **for that one path** and selects the registry validators
  a registration must satisfy — `check-gate-paths.sh` and its test, the
  check-surface degenerate-coverage pair, the exec-bit pair,
  `check-setting-registry.sh`, `validate-feature-docs.sh` and the kernel-manifest
  check — plus the newly registered gate **by name**, so a new gate runs on the
  PR that adds it. Both registration sites count: `<NAME>_GATES+=("<literal>")`
  and a bare `"<literal>"` element of the `KERNEL_GATES=( … )` array literal. In
  either shape the literal must name a gate the run's own list already carries,
  which is what keeps a `SKIPPED_KERNEL_GATES` skip-disclosure line from reading
  as a registration; the bare-element shape must additionally sit *positionally*
  inside a `<NAME>_GATES=( … )` literal, so an addition to the serial-lane pin
  list or the slow-dispatch hints — also bare quoted gate command lines that are
  in the run set, but concurrency decisions rather than registrations — keeps the
  full escalation and its parallel-scheduler gate. Every other edit to that
  file keeps the full escalation, as does a diff the probe cannot read; the
  run's reason line names the exception whenever it is taken. The probe
  resolves its own diff base when the caller supplies none, so the exception
  holds on every slice of a sliced `--scoped` run rather than only the first,
  and it pins its own diff format so a
  `diff.mnemonicPrefix` / `diff.noprefix` / `diff.external` / `textconv` git
  config cannot silently disable it.
