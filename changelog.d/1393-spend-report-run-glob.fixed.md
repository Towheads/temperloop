- **`pipeline-spend-report.sh --run` no longer glob-expands against the
  caller's working directory** (#1393). The filter value is word-split
  unquoted so `--run a,b` yields two ids, which also exposed it to pathname
  expansion: `--run 'new-*'` selected a run when invoked from a directory
  that happened to hold a file named `new-007`, and selected nothing from
  anywhere else — the same command answering differently by cwd. The split
  now runs under `set -f` (restoring the caller's own `-f` state after), so a
  run id is always taken literally. Comma-splitting is unchanged in both the
  `wf_abc-123` and bare `abc-123` forms, and `--by-agent-type`, which routes
  through the same normalization, inherits the fix.
