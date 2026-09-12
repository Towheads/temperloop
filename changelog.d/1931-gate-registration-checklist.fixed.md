- **A `/build` worker adding a new gate/validator/test script is now told,
  before running its own `--scoped` gate, which registries it must land the
  script in** (temperloop#1931). Previously nothing told the worker; three of
  five workers in one observed run shipped a new `check-*.sh`/`validate-*.sh`
  without registering it, and the gate that would have caught the omission
  (`validate-check-surface-degenerate-coverage.sh`) never ran worker-side
  because `workflows/scripts/config/gate-paths.tsv` had no row matching a
  brand-new script's path — each miss cost a full parent-side sliced
  acceptance-gate round trip. Two fixes, landed together: `gate-paths.tsv`
  now carries generic `check-*.sh` / `validate-*.sh` / `test_*.sh` globs so a
  new script is reachable by the registry gates on the worker's own scoped
  run, and `build-level.mjs`'s `workerPrompt()` gained a self-contained
  `## New gate script? Register it before running the scoped gate` section
  naming every registry (`check-surface-registry.tsv`,
  `check-surface-discovery.tsv`, the degenerate allowlist, `gate-paths.tsv`,
  `exec-bit-registry.tsv`, `kernel-manifest.txt`,
  `docs/features/feature-manifest.txt`, `setting-registry.tsv`).
