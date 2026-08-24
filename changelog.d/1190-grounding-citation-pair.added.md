- **Response-level grounding citations are now a registered kernel Capture/Backstop pair** (#1190).
  `CLAUDE.kernel.md` § Response-level grounding citations is the new capture half: an answer that
  knowledge-store content materially informed cites it inline (`[source: <note path>]`), and a
  context-dependent claim whose store query came back empty says so explicitly. `/tidy` Step 3
  § Missing grounding citations — which previously shipped as a backstop with no kernel rule to
  pair with — is now registered against it in `claude/commands/tidy.md`'s own kernel pairing table,
  so `validate-capture-backstop.sh` fails the build if either half goes missing. The scan adds no
  capture surface — no live instrumentation, no new ledger, no new lexicon tell: its input is
  confined to the one `Sessions/_inbox/` stub the drain has already opened (that stub's Step-1 scan
  report, its `## Transcript` section, and its own raw `.jsonl` via the Step-1.4 reach), and misses
  are recorded on the existing friction ledger. Because the scan report structurally carries no
  general assistant-response text, the step names candidate discovery explicitly as a routine
  assistant-turn skim of the stub body rather than a scan-report adjudication.
  `PROSE_BUDGET_TIER1_CAP` rises 347 → 351 to fund the four net-new kernel lines.
