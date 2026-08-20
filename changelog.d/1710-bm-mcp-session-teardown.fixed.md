- **The warm `basic-memory-mcp` backend terminates its MCP sessions instead of
  leaking one per query** (`Towheads/foundation#1710`). The backend opened an
  MCP streamable-HTTP session per search via `_ks_bm_mcp_open_session` — plus a
  second, bare-`initialize` session per query from the availability probe
  `ks_search` runs for its read-log gate — and never sent the `DELETE /mcp`
  teardown. The daemon retains per-session server state until told to drop it,
  so every search cost it ~1–3.6 MB permanently: **9.2 GB after 48 h**, and
  hidden from `ps` by memory compression, which is why it went unnoticed.

  A `_ks_bm_mcp_close_session` helper now sends the teardown (`DELETE /mcp`
  carrying `Mcp-Session-Id` + `MCP-Protocol-Version`) on **every** exit path.
  In `search` the close runs immediately after the `tools/call` round-trip
  returns and *before* parsing, so the parse-success, tool-error,
  unparseable-body and degraded-result-fallback paths all run after teardown;
  `|| true` on the curl/jq assignments keeps a timeout from skipping the close
  under a `set -e` caller. The availability probe closes its own bare-initialize
  session too (~50 KB each, opened on every query). The close is **fail-open**
  and always returns 0 — a failed `DELETE` can never turn a successful search
  into an error.

  Measured against the live daemon over a 10-query set: unfixed 880→897 MB
  (+1.7 MB/search); fixed 897→906→762→767→768 MB — the daemon reclaims the
  prior sessions' state and holds flat within noise. Four hermetic cases
  (`test_knowledge_search_mcp.sh` § 5) pin the success path, the error path,
  the fail-open `DELETE`, and the probe session; disabling the teardown fails
  the first of them.

  **Provenance:** this fix was originally written inside `foundation`'s
  vendored `kernel/` copy rather than here, so it never reached any other
  adopter — every stranger vendoring the kernel carried the leak. It is ported
  upstream unchanged (bar cross-repo issue qualification) so the fix lives in
  the one place that owns this file, per the kernel-edits-land-upstream-first
  rule; the divergence surfaced as a subtree-pull conflict while vendoring
  v0.33.0.
