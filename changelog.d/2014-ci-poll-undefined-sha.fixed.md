- **A build item whose push succeeded but reported no head SHA is no longer
  reported as a failed CI run** (#2014). `/build` pins its CI poll to the
  commit SHA the push reported; when that value never arrived, the poll was
  handed the literal string `undefined`,
  `workflows/scripts/build/ci-poll.sh` refused to run on it, and the refusal
  came back as the `ci-failed` escalation — parking or re-driving a pull
  request that was open with its checks still running. The driver now checks
  the SHA before spawning a poll, on every path that can produce one, and an
  argument refusal escalates as `ci-poll-bad-argument`, whose disposition (in
  `claude/commands/build.md`) is to inspect the pull request rather than treat
  it as red. `ci-poll.sh` now marks every argument refusal with a
  `usage_error: true` field in its JSON output, so any caller can tell "the
  poll never ran" from "the poll ran and CI is red".
