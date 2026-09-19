- **`/assess` Step 3's review-subagent pass is now bounded by a wall clock**
  (#866). The pass spawned `requirements-auditor` and the conditional
  `architecture-reviewer` with no time or cost bound: its graceful skip covered
  an *unavailable* agent but never a *non-terminating* one, so a reviewer that
  was probed `installed`, spawned, and kept working was invisible by
  construction. Observed on `/assess --epic 856`, `architecture-reviewer`
  returned in 336s while `requirements-auditor` ran past three hours before the
  operator killed it by hand — and on an unattended run nobody is there to do
  that, so `/assess` never reached Step 4 to write the plan note at all.
  Reviewers now spawn concurrently in the background and the whole fanout waits
  under one ceiling, `ASSESS_REVIEW_AGENT_CEILING_SECS`, with a progress notice
  first at `ASSESS_REVIEW_AGENT_SLOW_SECS`. A reviewer still unreturned at the
  ceiling is abandoned, the pass continues to Step 3.5 with whatever did return,
  and each abandoned reviewer emits the kernel's ceiling-timeout degradation
  notice (`skipped — <agent> timed out after <actual>s`) into the run and the
  Step 5 summary — so an incomplete review can never read as a clean one. Both
  settings are new, defaulted in `workflows/scripts/build/build.config.sh` and
  registered in `workflows/scripts/config/setting-registry.tsv`; they are
  deliberately separate from `/build` §3e's `BUILD_REVIEW_AGENT_*` pair, which
  rides a `build-level.mjs` input seam `/assess` never touches and carries a
  mandatory-reviewer escalation arm Step 3 has no analogue for.
