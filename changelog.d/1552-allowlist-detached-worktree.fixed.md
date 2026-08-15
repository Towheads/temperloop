- **`test_allowlist.sh` case 19 now passes in a detached `$TMPDIR` worktree**
  (#1552), so `combined-tree-precheck.sh` no longer reports `GATE_FAILED` for
  every multi-PR level. Two environment assumptions fixed in the test, not the
  validator: case 19's untracked-ceiling fixture moves outside `.temperloop/`
  (its old path tripped `COMMITTED-LOCATION`, shadowing the
  `COMMITTED-NOT-TRACKED` assertion the case exists to pin — case 20 now
  carries its own `.temperloop/` fixture), and the in-repo fixture paths
  resolve through the physical repo root (`cd -P`), matching the validator's
  own resolution — under macOS's symlinked `$TMPDIR` (`/var` →
  `/private/var`) a logically-resolved fixture path never prefix-matched the
  validator's repo root, silently skipping the git-tracked check.
