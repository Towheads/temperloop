- **`/build` Step 0.5 (resume reconcile) now records what it recovers** (#1908). A new
  `resume-recovery` raw-lake stream (`workflows/scripts/emit-resume-recovery.sh`,
  `meta/data/raw/resume-recovery-<YYYY-MM>.jsonl`) appends one record per
  `/build` resume that recovers or flags a Step 0.5 divergence — an orphaned
  worktree, a PR/sentinel mismatch, a self-claim reclaim, a workflow-journal
  `pr:`/`pushed_sha:` recovery, or a board/sentinel drift. This is a baseline
  instrument for the graph-of-record work; a `/build` resume is not a drive
  and never writes a `command-run`, so it gets its own stream rather than a
  new `command-runs` field. Presence-lint
  `workflows/scripts/validate-resume-recovery-emit.sh` (wired into
  `scripts/quality-gates.sh`) fails CI if the emitter disappears or its
  Step 0.5 call is removed from `claude/commands/build.md`.
