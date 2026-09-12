- **`cache.sh`'s path accessors and staleness/invalidation API now take an
  optional trailing `kind` argument** (`cache_repo_dir`, `cache_snapshot_file`,
  `cache_meta_file`, `cache_stale`, `cache_dirty`, `cache_clear`), defaulting
  to `issues` (#1910). A second store `kind` (e.g. a future state-graph
  snapshot) can now share `$CACHE_STORE_ROOT` with its own top-level directory
  and its own `meta.json`, without invalidating or clearing the issue cache.
  Every existing call site passes no `kind` and is unaffected.
