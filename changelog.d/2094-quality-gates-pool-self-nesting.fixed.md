- **The gate pool's own test no longer fails when the suite is launched in the
  background** (#2094). `scripts/tests/test_quality_gates_parallel.sh` asserted
  that a gate self-killing with `SIGINT` is observed as `130`. That is only true
  when the *invoker* left the signal disposition alone: start
  `scripts/quality-gates.sh` as an asynchronous child of a shell with job
  control off — `( … ) &`, `nohup`, an agent harness's background Bash, any
  `trap '' INT` ancestor — and bash hard-ignores `SIGINT` for the whole process
  tree, which nothing inside the pool can reset. The suite then went red over a
  property of its caller, turning the entire local gate run red on an otherwise
  clean tree. The assertion is now **differential**: the suite measures the
  serial-loop baseline itself and requires the pooled result to match it, so it
  still catches the pool changing what a gate observes (its original purpose)
  and no longer reports on how it was launched. The absolute `130` check still
  runs whenever the invoker's disposition makes it observable, and reports
  itself as a `SKIP` when it does not.
- **A quality-gate slice that ran out of budget with a clean result is no
  longer reported as a gate failure** (#2094). `/build`'s acceptance gate — the
  scoped quality-gate run before a push — classified a slice as `GATE_SLICE`
  only on exit code 75. `quality-gates.sh` prints its
  `QUALITY_GATES_RESUME_AT=` trailer *before* it exits, so any other status
  over the same clean partial was relabelled `GATE_FAIL` — where the failure
  floor manufactured one failure out of a slice that had just reported zero. A
  printed resume point now decides the classification on its own, the exit code
  rides along as a recorded fact, and a run that stopped part-way through the
  gate list is no longer recorded as having covered all of it. Slice trailers
  are also read from that slice's own output rather than the accumulated log,
  so a slice that reports nothing cannot inherit the previous one's resume
  point — and a non-numeric trailer is read as absent rather than interpolated
  raw into the outcome line. That per-slice file is written by `tee`, not
  copied in after the gate finishes: `/tmp/qg-<slug>.log` is truncated before
  the first slice starts and streams for the whole run, so a slice the executor
  kills on a timeout still leaves its partial output — the only diagnostic a
  timeout produces — in the log the escalation points the operator at, and a
  timed-out first slice can no longer leave the previous run's log in place to
  be read as this run's.
