### Fixed

- **`test_lint_pipe_grep_q` T4-overlay used the running checkout as its negative
  control** (#1508, follow-up to #1505). The case added in #1505 asserted
  *"detection does not flag THIS checkout"* — true in the kernel repo, **false in
  every vendoring consumer**, so the suite failed for exactly the trees #1505
  set out to support. The negative control is now a synthetic **kernel-native**
  fixture (real directories, no `kernel/` subtree, no overlay marker), so both
  directions are proven by fixtures and the result no longer depends on where
  the suite is run from. The checkout's own arm is now reported as a `note:`,
  never asserted. Verified passing on both: 43/43 on a kernel-native checkout
  (T4 runs for real) and 38/38 on a composed overlay (T4's five coverage checks
  legibly skip).
