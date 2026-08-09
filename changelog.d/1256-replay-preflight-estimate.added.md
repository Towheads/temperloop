- **The model-comparison replay module gains a pre-flight spend gate** (#1256,
  epic #1225 "model comparison harness"). `workflows/scripts/model-comparison/
  replay.sh` adds a `preflight` subcommand that reads an already-computed
  `corpus` JSONL file and, before any replay token is spent, prints
  eligible-N, a batch-cap-bounded token/cost estimate (`cost_basis:
  "token_count"` — this module states no dollar figure), and whether that
  eligible-N can reach the module's significance threshold at all — by
  genuinely consuming `stats.sh`'s own `mde` primitive rather than a second,
  hand-rolled computation of it. A projected batch whose estimated cost
  exceeds the new `REPLAY_PREFLIGHT_CEILING_TOKENS`, or that lands while
  `workflows/scripts/build/quota-gate.sh` reports "pause" (the run now
  explicitly routes through that gate), **stops at pre-flight** rather than
  partway through a later execution step. Fails closed
  (`outcome:"CANNOT_EVALUATE"`, non-zero exit) on an absent, unreadable,
  empty, or malformed corpus file, or an unreachable `stats.sh` primitive —
  it never reports a cheap/reachable estimate it did not actually compute.
  Replay batches remain operator-initiated only: no autonomous or cron arm
  was added, proven by a fixture that scans every scheduled pipeline entry
  point for a reference to `replay.sh`. Four new registered settings
  (`REPLAY_PREFLIGHT_BATCH_CAP`, `REPLAY_PREFLIGHT_TOKENS_PER_REPLAY`,
  `REPLAY_PREFLIGHT_CEILING_TOKENS`, `REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS`)
  and a new `scripts/quality-gates.sh` entry
  (`workflows/scripts/model-comparison/tests/test_replay_preflight.sh`).
