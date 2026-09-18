- **`model-comparison/dual-build-ledger.sh` — an append-only ledger and
  per-arm patch archive for the dual-build harness** (#2072, epic #2065). The
  harness runs the same work item under two models and needs a durable
  record of what happened to each arm; this is that record. `append` writes
  one JSON row per item per arm (model, base/head commit, gate result, cost,
  judge verdict, the level pick, and a monotonic `seq`) to
  `.temperloop/model-comparison/dual-build/rows.jsonl`, rejecting a row
  missing a required field or carrying an unrecognised `arm`/`gate`/
  `guard_armed`/`loss_reason` value rather than writing something a later
  reader can't trust; `seq` and `schema_version` are always assigned by the
  script itself, never taken from the caller. `read` reports "records
  missing" and exits non-zero on a truncated or gapped ledger instead of
  silently returning a partial result, and also accepts `--expect N` for a
  caller's own count check. `archive` saves a `git format-patch` per
  (item, arm) under `archives/<slug>@<arm>.patch`; `archive-check` proves a
  saved patch would still apply — via a real `git am` against a disposable
  clone of the repo, never the repo working copy itself — before anything
  relying on it deletes the losing arm's branch. `purge` removes the whole
  ledger folder (dry-run unless `--yes`); `prune` removes only archives
  older than the configured retention window (dry-run unless `--apply`).
  Both the ledger folder and the archives already live under the
  git-ignored `.temperloop/model-comparison/` tree, so nothing here is
  ever committed.
