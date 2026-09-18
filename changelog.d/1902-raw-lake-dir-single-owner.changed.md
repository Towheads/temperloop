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
