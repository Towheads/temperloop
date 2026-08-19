- **The knowledge_search backend installs its pinned `basic-memory` as a uv
  tool instead of resolving it via `uvx` on every call** (#1113). `_ks_bm_run`
  used to invoke `uvx --from basic-memory==<pin> basic-memory …`, which has no
  permanent install location: uv resolves the package, unpacks a ready-to-run
  environment into its own cache, and executes out of that cache. Every
  distinct resolution adds another environment and nothing expires them —
  observed at 30 GB against a 273 MB knowledge store, with the root volume at
  0 bytes free, and unprunable (`Cache is currently in-use`) for as long as
  the warm `basic-memory-mcp` daemon held the cache lock. The adapter now
  installs the pin once (`uv tool install --python <pin> basic-memory==<pin>`)
  into its own isolated home — `UV_TOOL_DIR`, `UV_TOOL_BIN_DIR` and `HOME` all
  pinned there, so nothing reaches the operator's `~/.local/{share,bin}` — and
  invokes the installed entry point by absolute path. uv's cache then holds no
  live environment, holds no lock, and stays prunable while the daemon serves.

  **Upgrades still follow the pin.** Under `uvx` the pin was re-asserted on
  every invocation; an installed tool would otherwise keep serving the old
  build forever. The installed version *and* interpreter are stamped beside
  the entry point and re-checked on every call, so changing
  `KNOWLEDGE_SEARCH_BM_VERSION` or `KNOWLEDGE_SEARCH_BM_PYTHON` re-installs
  rather than silently continuing to run what is on disk.

  **Installing is hybrid, both halves shipped together.**
  `workflows/scripts/install/doctor.sh` gained a `knowledge_search
  basic-memory tool` section that installs the pin and reports its state
  (`INSTALLED` / `PIN DRIFT` / `ABSENT` / `UNAVAILABLE` / `INSTALL FAILED`) —
  advisory, never affecting doctor's own exit code. And the availability gate
  installs the pin lazily on first use when it is absent, so a stranger with
  only `uv` on `PATH` and no `doctor` run still gets a working first
  `ks_search` — the zero-setup property that made `uvx` the original default.
  `ks_search_available` is therefore no longer a pure predicate **by
  default** — pass the new `--probe` flag for a zero-side-effect check that
  never installs (a hermetic test, a graceful-skip capability probe). It
  accepts a
  new `--quiet` flag that suppresses only the `skipped —` notice (never
  install progress), which `ks_search`'s internal read-log probe now passes.

  Degradation is unchanged in shape: `uv` missing, or the install failing,
  still returns exit 3 with a `skipped — knowledge_search unavailable: …`
  line on stderr, nothing on stdout, and uv's own failure output surfaced
  rather than swallowed. The one-time install is bounded by the new
  `KNOWLEDGE_SEARCH_BM_INSTALL_TIMEOUT` setting when the caller has sourced
  `workflows/scripts/lib/portable-timeout.sh`.
