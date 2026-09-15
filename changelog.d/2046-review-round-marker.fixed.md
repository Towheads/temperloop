- **Running the build test suite no longer spends a checkout's code-review
  budget** (#2046). `/build`, `/fix` and `/sweep` cap how many review rounds a
  single item may take before they stop waiting for it to converge — the cap
  is `BUILD_REVIEW_BLOCKING_MAX_ROUNDS` in
  `workflows/scripts/build/build.config.sh`, and the count is kept per
  checkout in a `build-review-rounds` file inside that checkout's git
  directory. Two cases in `workflows/scripts/build/tests/test_workflow.sh` ran
  the real code-review setup against whatever checkout the suite happened to
  be running in, and that counted as two rounds every time anyone ran the
  tests. Since the suite normally runs inside the same throwaway checkout the
  fix is built in, a change whose tests were run even twice was already over
  the cap before its first real review round. The cap then fired at once and
  carried unresolved review findings into the pull request body instead of
  letting the review finish — silently, because nothing failed; the count just
  climbed. The two cases now use the read-only form of the same step, and the
  suite fails if any test writes that count again.
