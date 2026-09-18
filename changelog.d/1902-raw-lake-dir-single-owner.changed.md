- **The issue-touches raw-lake directory now has a single owner** (#1902). Both
  writers of that stream — `workflows/scripts/board/capture.sh` and
  `workflows/scripts/emit-issue-touch.sh` — used to derive
  `<checkout>/meta/data/raw` independently (a git-toplevel resolution in one, a
  fixed `../..` hop in the other), so a fix to one silently left the other
  behind. Both now consume `raw_lake_dir()` from the new
  `workflows/scripts/board/lib/raw_lake.sh`, which resolves the git toplevel of
  its own resolved location; `claim.sh`'s `CLAIMS_RAW_DIR_DEFAULT` consumes it
  too. The `ISSUE_TOUCHES_RAW_DIR` / `CLAIMS_RAW_DIR` override env vars and the
  resolved default path are unchanged.
- **`ISSUE_TOUCHES_RAW_DIR` is honored even where the shared resolver is
  absent** (#1902). `emit-issue-touch.sh` now consults the override *before* it
  looks for `board/lib/raw_lake.sh`, so a caller that names the sink outright no
  longer needs the `board/lib/` subtree present; only the default path reaches
  for the shared owner. Both symlink-resolution loops (the writer's and
  `raw_lake_dir()`'s own) are bounded, so a symlink cycle cannot spin them.
- **`raw_lake_dir()` now resolves its own symlink and reads no bare `$HOME`**
  (#1902). A copy reached through a symlink reports its SOURCE checkout's lake
  rather than the link's, and the outside-any-git-checkout fallback yields the
  whole `${HOME:-}/dev/foundation/meta/data/raw` under a `set -euo pipefail`
  caller with `HOME` unset, instead of a truncated `/meta/data/raw`.
