- **`milestone list` now exits 0 on a successful listing when every open
  milestone is active** (#1826). The inactive-section conditional
  (`[ -n "$inactive_out" ] && printf …`) was the function's last command, so an
  all-active board made a complete, correct listing return 1 — tripping any
  `set -e` caller. Printed output is unchanged in all three truth-table cases
  (all-active, mixed, all-inactive), each now covered by a fixture-replay test
  asserting exit 0.
