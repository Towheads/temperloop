- **A `^C` or `kill` on a running replay batch now STOPS it instead of
  cleaning up and continuing to spend** (#1527).
  `workflows/scripts/model-comparison/batch.sh` — the model-comparison
  module's spend-bearing entry point, and the only thing that calls
  `replay.sh execute` in a loop — registered one handler on `EXIT INT TERM`.
  A bash trap handler *returns*, which is right for EXIT and wrong for a
  signal: an interrupted batch tore its in-flight worktree down and then
  calmly started the next leg, so the operator's "stop spending" was
  acknowledged and ignored. The EXIT arm is unchanged; INT and TERM now run
  the same cleanup and then re-raise under the default disposition, so the
  process dies **of** the signal with the conventional signal-derived status
  (`130` / `143`, deliberately outside the driver's own closed exit-code set)
  and prints no summary object it never earned. Per-leg failure resilience is
  untouched — a leg that genuinely fails is still recorded and the batch still
  continues; only a real signal stops the run, and every leg already in a
  terminal state is on disk, so re-invoking resumes without re-spending it.
  `tests/test_replay_batch.sh` gains section I: a stub that TERMs the driver
  mid-leg proves exactly one of four legs ran, no arm files were assembled,
  the in-flight worktree was torn down, and the exit status was 143 — plus a
  mutation proof that restoring the single `trap … EXIT INT TERM` makes the
  same TERM clean up and run all four legs.
