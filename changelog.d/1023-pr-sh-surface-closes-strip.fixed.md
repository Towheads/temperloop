- **`pr.sh open` no longer emits the issue-linkage block twice when a worker's
  verification surface carries its own copy** (temperloop#1023). Linkage lives
  in `pr.sh` alone, but the `## Verification` section is worker-authored content
  spliced in verbatim — so a worker that copied the block into its
  `.build-verification.md` produced a PR body declaring linkage twice (observed
  on PR #1019). `open` now strips from the spliced surface exactly the lines
  GitHub itself would honor *and* that can only duplicate its own emission: a
  whole line that is nothing but `<keyword> #N` / `<keyword> owner/repo#N`.
  Mid-sentence mentions, backticked and indented lines, and anything inside a
  fenced code block are left byte-for-byte intact, and the removal count rides
  the `PR_OPENED`/`EXISTS` outcome as `surface_closes_stripped` so the strip is
  observable rather than silent.
