- **A freshly installed `ks_search` backend now indexes the corpus before it
  answers, instead of returning nothing forever** (#1635). Registering a
  basic-memory project does not scan it, and nothing else on the search path
  did either — so on a genuinely clean host the chain ran to completion and
  stopped one step short: install the pin, register the project, search an
  **empty index**, return zero results with exit 0. Nothing had failed, so
  nothing was reported; a stranger got "no matches" for every query they ever
  ran until something else happened to call `ks_search_reindex`. The search
  path now indexes once, in the same project-not-found branch where it
  registers, before it retries the query. That branch fires on first use and
  on a post-`reset` DB drop and never on a warm query, so no per-query cost is
  added. The index is best-effort — a failure warns on stderr, surfaces the
  subprocess's own cause, and lets the retry proceed rather than failing the
  search — and is bounded by the new `KNOWLEDGE_SEARCH_BM_INDEX_TIMEOUT`
  setting when the caller has sourced
  `workflows/scripts/lib/portable-timeout.sh`.

- **A clean-host validation of the stranger first-run path ships as an
  opt-in `make` target** (#1635). Every test of the #1113 uv-tool install
  switch stubs `uv`, deliberately — kernel principle 3 forbids a live-network
  install inside the gated suite — so the real path (clean host, only `uv` on
  `PATH`, no `doctor` run, first `ks_search`) had never been executed. `make
  validate-clean-host-ks-search` now executes it inside a throwaway Linux
  container: a real `uv tool install`, a first search over a fixture corpus, a
  second search that must install nothing, and a third with `uv` removed from
  `PATH` entirely. It is **manually invoked only** — absent from
  `scripts/quality-gates.sh`, from `KERNEL_GATES`, and from every CI job — and
  fails loudly (exit 2) when the Docker daemon is unreachable rather than
  reporting a skip. The run that found the indexing defect above is recorded
  verbatim in `docs/validation/clean-host-ks-search.md`.
