- **`pipeline-tick.sh`'s two optional-source guards are fail-open again** (#1132).
  The script is `set -euo pipefail` and sources `build.config.sh` and
  `../lib/command_declared.sh` behind `[ -f x ] && . x` guards so a checkout that
  vendors only a subset still runs. That form leaves the whole statement at exit
  status 1 when the file is absent — the guard whose job is to make the file
  optional is the thing that publishes a failure. Mid-file that status is
  survivable (bash suppresses errexit for a non-final `&&` operand, verified
  against the real script), but it is fatal the moment such a guard lands last in
  a file or a function, or an errexit caller sources the file, so the shape is a
  latent trap rather than a live one. Both sites now use the house `if [ -f x ];
  then . x; fi` form already used at `worklist.sh:50-53`, `gh-bench.sh:141` and in
  this file's own `read_ready_items()`. A regression test (`test_pipeline_tick.sh`
  test 33) pins the shape, demonstrates the terminal-position status difference
  between the two forms, and runs a lone copy of the script with neither optional
  file beside it through a full dry tick.
