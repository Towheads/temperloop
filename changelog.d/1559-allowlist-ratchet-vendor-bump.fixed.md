- **`validate-check-surface-degenerate-coverage.sh` no longer false-fails a
  composed overlay's vendor bump with `ALLOWLIST-GREW` on upstream-grown
  allowlist rows** (#1559). The ratchet now resolves the allowlist/registry
  paths to their physical form first (a base-ref `git show` on the overlay's
  symlink path was comparing the link's target text as if it were TSV), and
  when the repo root carries `.kernel-pin` and the allowlist resolves into
  the vendored `kernel/` subtree, subtree-sourced rows are additionally
  ratcheted against the kernel's own pulled content (the subtree squash
  commit identified by its `git-subtree-dir: kernel` trailer) rather than
  only the overlay's `origin/main` — so an allowlist-growing kernel bump
  merges without a manual `CHECK_SURFACE_ALLOWLIST_BASE_REF` override, while
  an overlay-authored row (present in neither comparison point) still fails,
  and a kernel checkout's own shrink-only ratchet is unchanged. With no
  reachable squash commit the arm degrades fail-closed to the plain
  base-ref ratchet and the verdict line says so.
