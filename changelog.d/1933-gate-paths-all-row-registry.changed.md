- **A gate-registration-only `scripts/quality-gates.sh` diff no longer escalates
  a scoped run to the full gate suite** (#1933). That file sits on
  `gate-paths.tsv`'s `ALL` row, so adding one `KERNEL_GATES+=("…")` line ran all
  ~110 suites. When the diff removes nothing and its added lines are exclusively
  gate-registration lines (comments and blanks may ride along), the selector now
  declines the `ALL` escalation **for that one path** and selects the registry
  validators a registration must satisfy — `check-gate-paths.sh` and its test,
  the check-surface degenerate-coverage pair, the exec-bit pair,
  `check-setting-registry.sh`, `validate-feature-docs.sh` and the kernel-manifest
  check — plus the newly registered gate **by name**, so a new gate runs on the
  PR that adds it. Every other edit to that file keeps the full escalation, as
  does a diff the probe cannot read; the run's reason line names the exception
  whenever it is taken.
