- **Raw-lake writers and the telemetry-brief reader now resolve the same
  directory by default** (#1822). `claim.sh`'s `CLAIMS_RAW_DIR_DEFAULT` and
  `capture.sh`'s `ISSUE_TOUCHES_RAW_DIR_DEFAULT` no longer pin the absolute
  `$HOME/dev/foundation/meta/data/raw` path — they resolve checkout-relative
  (git toplevel of the script's own resolved dir, then `meta/data/raw`), the
  same lake `telemetry-brief.sh` and `emit-issue-touch.sh` already resolve. A
  non-foundation checkout previously reported 0 claims and a fraction of its
  issue-touches (its own capture records all landed in the foreign pinned
  lake), and a bare kernel checkout silently grew a phantom
  `~/dev/foundation/` tree. Per-stream env overrides (`CLAIMS_RAW_DIR`,
  `ISSUE_TOUCHES_RAW_DIR`) still win when set; the deeper single-owner-of-
  resolution question for the issue-touches stream's two writers stays split
  to its follow-up, #1902.
