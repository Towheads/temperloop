- **`/tidy` § Contradiction detection now names an invocation `ks_search` actually
  accepts** (#1170). The step told the drain to run `ks_search` "scoped to
  `Decisions/` with a small `limit` (~5)", but `ks_search` accepts only `--limit`
  and `--partition` and rejects anything else with **exit 2 before any backend
  call** — so a session reaching for the implied folder argument
  (`--folders Decisions`) got a hard usage error, and the pass's degradation
  clause ("if `ks_search` is unavailable, skip") read that error as unavailability
  and silently disabled the whole cross-session supersession proposer. Step 1 now
  gives the literal call (`ks_search "<claim text>" --limit 15`), states that
  folder scoping is a **post-filter** on each result's store-relative `doc_id`
  rather than an argument, and the degradation clause now discriminates the exit
  codes: **exit 3** (backend unavailable) skips the pass, **exit 2** means the
  call was malformed and must be corrected and re-run, never skipped. The
  originally-reported site was `mcp__obsidian__search_vault_smart` with
  `folders`/`limit` written as top-level parameters when both live under `filter`;
  #1570's knowledge-store cutover had already migrated that site off the Obsidian
  MCP, but carried the same "names a parameter the tool does not take" defect
  across to the new transport.
