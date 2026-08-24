- **The provider disclosure log's watermark anchor is now committed to git**
  (#1316). The two-value anchor (`<max_seq> <last_hash>`) moved out of the
  gitignored `.temperloop/model-comparison/` runtime dir to a tracked file at
  `workflows/scripts/model-comparison/disclosure-log.watermark`, beside the
  committed provider allowlist. The **log itself stays gitignored**, so no
  provider history and no content enters the repo, and the anchor carries
  neither. `validate-provider-disclosure.sh` now also checks the live log
  against the anchor *as committed in git*
  (`WATERMARK-LOCATION` / `WATERMARK-NOT-TRACKED` / `WATERMARK-GIT-MALFORMED` /
  `WATERMARK-GIT-DIVERGED` / `REFORGED-VS-GIT`), so a full re-forge — which
  previously verified clean once the log and its on-disk anchor were rewritten
  together — must now rewrite git history too, which leaves its own trace.
  Commit the anchor when a run changes it; `pa_disclose` says so on stderr.
  New setting `PROVIDER_DISCLOSURE_WATERMARK_FILE` (fixture-test seam only).
