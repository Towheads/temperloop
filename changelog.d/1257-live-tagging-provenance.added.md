- **Live candidate tagging gains its provenance layer** (#1257, epic #1225
  "model comparison harness"). New
  `workflows/scripts/model-comparison/tagging.sh` adds no new model-selection
  mechanism — an operator still points the existing `SWEEP_WORKER_MODEL`
  setting at the candidate — and instead provides the provenance half: `tag`
  writes a bounded window record (provider/model/run id, keyed and
  timestamped per run) to a repo-local, gitignored ledger, emits a matching
  attribution-only telemetry tag through the existing
  `workflows/scripts/emit-model-usage.sh` raw lake (`seat sweep-live-tag`,
  `usage_source unavailable` — a `/sweep` fix-worker seat isn't
  token-capture-feasible per the L0 spike), and prints a PR provenance stamp
  naming model and provider only (never a key, never content). `crosscheck`
  mechanically cross-references a PR body/trailer's stamp against the
  recorded window and telemetry-lake records by run id and FAILS on any
  disagreement — a doctored stamp, a stamp with no matching record, or a
  live-tagged run with no stamp are all caught, fail-closed (a distinct
  `CANNOT EVALUATE` on any absent/unreadable/malformed/ambiguous input,
  never a silent pass). Designation is governed by the same committed
  provider allowlist (`workflows/scripts/model-comparison/allowlist.sh`)
  every other provider check in this module reads. One new registered
  setting (`LIVE_TAG_WINDOW_LOG`) and a new `scripts/quality-gates.sh` entry
  (`workflows/scripts/model-comparison/tests/test_live_tagging.sh`).
