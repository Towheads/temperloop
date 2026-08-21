- **A `/build` acceptance-gate escalation can no longer contradict its own
  payload** (#1587). `build-level.mjs` §3e.5 maintained **two** independent
  failure counters — an accumulated `failedGates` and the terminal slice's own
  `gateOut.failed` — and shipped both in one escalation:
  `{gateOut:{outcome:"GATE_PASS",failed:0,…}, failedGates:1}` under
  `kind=acceptance-gate-failed`. A consumer that trusted either field acted on a
  fiction, and the operator who read the gate log's closing
  `OK — gates 96..162 of 163 passed in 241s (final slice)` line reasonably
  concluded the escalation was a false positive. It was not — an earlier slice
  really had failed, and that green line covers only the gates the *last* slice
  ran — but nothing in the payload said so.

  There is now exactly one record of what a gate run found: a per-slice
  `sliceLedger` the loop appends to. Every figure reported anywhere derives from
  it — `verdict` (`RED` / `UNKNOWN` / `GREEN`, the one field a consumer may
  trust), `failedGates` (the ledger's sum), `slices` (its length), the escalation
  kind, and the reason prose, all computed in a single `gateVerdict()`
  reconciliation point. The raw terminal `gateOut` — whose `failed` was the
  contradicting field — is no longer embedded; its content survives as the
  ledger's last entry, which cannot disagree with the sum of the ledger it is
  part of. `slices` also stops over-reporting by one on slice-cap exhaustion,
  where it was read off the loop index rather than the ledger.

  Three behavior changes fall out, each closing a verdict/payload disagreement
  rather than widening the gate:

  - A `GATE_FAIL` whose failure count could not be parsed from the log (a stale
    or absent `QUALITY_GATES_FAILED=` trailer) now reports **at least one**
    failure. "Failed, 0 failures" was the mirror image of the same defect.
  - An **observed failure dominates an unfinished remainder**: a run that failed
    in slice 1 and was then killed by the executor's Bash ceiling escalates
    `acceptance-gate-failed`, with a reason naming both halves, instead of
    laundering a known-red branch into `acceptance-gate-timeout`. temperloop#1021
    is preserved exactly — and sharpened: the timeout kind is now reserved for
    runs where *nothing* failed in the slices that did run, which is the case
    this repo hits today (temperloop#1663).
  - A gate outcome outside the closed set no longer falls through to the
    pass arm and pushes a branch whose gate never returned a verdict. It
    escalates as `UNKNOWN`, with a reason naming the outcome verbatim.

  Covered by three new fixture cases in
  `workflows/scripts/build/tests/test_workflow.sh` (`1587 agreement` /
  `1587 observed` / `1587 honesty`) that construct all four gate outcomes
  against the .mjs's own offline harness — no live gate run — and assert the
  structural invariants on every escalation: no embedded `gateOut`, no second
  counter, `failedGates` equal to its own ledger's sum, `slices` equal to the
  ledger's length, the kind equal to the verdict in both directions, and a
  reason that agrees with the verdict it accompanies. All three fail against the
  pre-fix file.
