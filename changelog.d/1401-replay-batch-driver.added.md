- **The replay BATCH DRIVER — the thing that connects the model-comparison
  harness end to end** (#1401): `workflows/scripts/model-comparison/batch.sh`,
  operator-invoked, turns a `replay.sh corpus` file into the `baseline.jsonl`
  and `candidate.jsonl` arm files `workflows/scripts/report-producers/model-comparison`
  reads. Epic #1225 shipped sixteen components and nothing between the corpus
  at one end and the report at the other; this is that connection, and it
  ORCHESTRATES only — it derives no statistic and re-implements no scoring,
  judging, corpus selection or isolation.
  - **The spend gate runs FIRST, and consent is explicit.** `replay.sh
    preflight` is consulted before the first worktree is prepared: a `stop`
    verdict, or a missing `--confirm`, exits 3 having spent nothing. The batch
    cap, the planned-record/replay/pair counts and the cost basis are read
    verbatim off that gate rather than re-derived, so the batch executed and
    the batch authorized cannot drift apart — a selection that disagrees with
    the authorization is refused before any spend.
  - **The temperloop#1379 two-arm unit contract holds in EXECUTION, not just
    in the estimate.** The cap binds CORPUS RECORDS; every selected record is
    replayed in BOTH arms; the driver refuses outright if pre-flight budgeted a
    different `arms_n`.
  - **Fail-soft per record, fail-closed per run.** One record's failure is
    recorded with its reason and the batch continues (exit 4 `BATCH_DEGRADED`,
    with every failure named); an unreadable input, a missing sibling script or
    an unparseable gate verdict is `CANNOT EVALUATE` and non-zero. The replay
    completion rate falls out of the driver's own output, with its unit named.
  - **Resumable, by leg.** Re-invoking after an interruption re-spends no
    replay and no judge call that already completed; a state directory bound to
    a different corpus is refused rather than silently merged into one arm file.
  - **Isolation end to end.** Every worktree is torn down on the success path,
    the failure path, and (via an EXIT trap plus an end-of-batch sweep) the
    interrupted path; `replay.sh verify-clean-parent` runs after the batch and a
    dirty parent is a named degradation.
  - **No implicit model call, ever.** Each arm requires an explicit
    `--baseline-runner`/`--candidate-runner` seam or the single explicit
    `--live` flag; with neither, the driver refuses before it even reads the
    gate. `workflows/scripts/model-comparison/tests/test_replay_batch.sh`
    (registered in `scripts/quality-gates.sh` and `gate-paths.tsv`) drives every
    arm through recorded runners, runs the REAL report producer on the driver's
    own output, and carries eight mutation proofs plus a canary `claude` that
    the whole suite proves was never invoked.
