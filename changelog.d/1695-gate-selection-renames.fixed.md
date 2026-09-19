- **Diff-scoped gate selection now sees both sides of a rename** (#1695).
  `workflows/scripts/lib/gate-selection.sh` resolves every changed-set diff
  with `--no-renames`, so a file moved *out* of a gated tree lists its source
  path as well as its destination and that tree's gates are pulled back into
  the run. Previously git's default rename detection reported only the
  destination, and a scoped `pull_request` (or local `--scoped`) run was
  narrower than its own diff — a latency gap rather than a hole in what gates
  `main`, since the unscoped merge_group run still caught it.
