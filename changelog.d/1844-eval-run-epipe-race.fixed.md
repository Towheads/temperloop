- **The hook test suites no longer fail spuriously under load** (#1844). The
  `claude-p-spawn-guard` suite's `EVAL_RUN` case fed the hook through a pipe.
  The hook's `EVAL_RUN` arm exits before draining stdin — deliberately, so an
  unanswerable interactive `ask` cannot hang a headless eval run — which leaves
  the upstream `jq` writing into a closed pipe. Under the suite's `pipefail`
  that writer's status became the pipeline's, so the assertion measured `jq`
  rather than the hook and reported `EVAL_RUN exits 0 (got rc=2)` (`rc=141`
  locally). Because it is a race on the 64 KiB pipe buffer it fired only on a
  busy host, i.e. in the merge queue: it ejected an unrelated PR from the queue
  on a diff that never touched the file. Every assertion that measures the
  hook's exit status is now fed from a file, in this suite and in
  `test_write_lane_guard.sh` (which carried the same latent shape at both of
  its exit-status sites), and a structural guard fails if a future exit-status
  assertion in either suite is pipe-fed again — including through an indirect
  interpreter or with the `rc=$?` on the following line.
