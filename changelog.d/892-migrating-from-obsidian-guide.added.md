- **A migrating-from-Obsidian guide ships in `docs/`**
  (`Towheads/foundation#892`). The kernel documented what the knowledge-search
  adapter *is*, but not how a store gets moved onto it — that knowledge lived
  only in issue bodies, a private ledger, and committed eval JSON. The new
  `docs/migrating-from-obsidian.md` covers the four things that migration
  actually turned on: constructing a golden-query set, the parity-ledger
  method, the mutation tripwire, and the staggered writer migration order.

  **Its framing is that this is a migration of access paths, not of data** —
  the store stays canonical markdown throughout and nothing is converted,
  which is the single most common wrong expectation to arrive with.

  **The results are reported as measured, including where the incumbent won.**
  Read from the committed cutover-gate artifacts rather than recollection:
  basic-memory took hit@5 (0.974 vs 0.842) and recall (0.947 vs 0.790) but
  **lost MRR** (0.767 vs 0.829), and the guide leads with that row. Search was
  not a speed win either — cold p50 4.497s, which is why the warm-daemon
  supervisor unit exists at all.

  It also documents what went wrong, because a method section that only
  describes the happy path teaches an adopter to repeat the mistake: the
  parity ledger **failed as a gate** (its raw tally favoured the incumbent,
  three of its arms were broken instruments, and the weekly regression bench
  was later found comparing two corpora with zero overlap), and the cutover was
  re-gated on the golden-query eval instead. Each failure carries its
  transferable rule.

  A **When not to do this** section gives six self-select-out criteria, and a
  boundary section states plainly which pieces live in this kernel and which
  the adopter writes themselves — the harness, ledger, tripwire and scheduled
  reindex are *not* shipped here, so they are described as methods rather than
  linked as files a stranger's checkout does not have.

  Contract-surface note: this adds one `kernel` classification line to
  `workflows/scripts/kernel/kernel-manifest.txt` for the new page. Docs-only
  otherwise — no behavior, interface, or setting changes.
