- **`/build` no longer drops a CI-fix round's §3e review findings from the PR
  body** (#1846). The body suffix was rendered once at 3f from the original
  review round while the Step-6 tally merged every round — so a reviewer that
  ran only against the CI-fix diff (e.g. shell-reviewer on PR #1845, three real
  findings) was affirmatively omitted from the body's `ran:` line and
  `## Review notes`. `build-level.mjs` now renders both surfaces through one
  `reviewBodySuffix()` (the `ran:` line is the round-union of reviewers, every
  round's findings section is spliced — a repeat reviewer keeps both blocks,
  relabeled `(ci-fix round N)`), and a new 3g.5 step re-renders the open PR's
  body after CI resolves via `pr.sh open --update-pr <n>` — the same
  `assemble_body` path as create, backed by `gh pr edit`.
