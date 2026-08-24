- **`Makefile` now routes to `shell-reviewer` in `/build`'s §3e pre-push
  review, and an unrouted changed path is now a reported figure** (#1705).
  `reviewer-routing.tsv` gains a third key shape alongside the extension and
  `dir/**` forms: a `**/<basename>` key matching that exact basename at any
  depth (never as a suffix, so `**/Makefile` cannot claim `NotAMakefile`).
  It is implemented in all three consumers of the table —
  `build-level.mjs`'s `reviewGlobMatch()` (the copy §3e actually routes
  through), `workflow-reviewer-coverage.sh`, and
  `reviewer-activation-coverage.sh`. `Makefile` was the 7th-highest-churn
  reviewable file in the repo (41 changes in 90 days) and had no extension
  and no directory prefix, so every one of those changes was pushed with no
  routed reviewer — on the file that decides what the gate set runs.
  `workflow-reviewer-coverage.sh` now also partitions the window's distinct
  changed paths into `routed_paths` / `prose_md_fallback_paths` /
  `unrouted_paths` (with `unrouted_path_examples`, and a matching text-mode
  line), so a path no rule matches is counted and named instead of being
  absent from the denominator entirely — the mirror of the reviewer-side gap
  #1446 closed. The next unrouted high-churn file shows up as a number
  rather than by someone reading the table by hand.
