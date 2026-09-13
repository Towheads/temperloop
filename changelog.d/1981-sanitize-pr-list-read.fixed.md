- **`state-graph.sh`'s `pr_list` source now routes its `gh pr list` payload
  through `_board_sanitize_control_chars` before any `jq` touches it** (#1981),
  so one stray control byte in a single PR no longer takes the whole source
  down. The read projects `title` and `body` — user-authored fields — and `jq`
  exits 5 on a literal control byte, which the `count` guard converted into a
  source-wide `error`. That error was **sticky**: it recurred on every run for
  as long as that one PR stayed open, out of up to 100 open PRs, and
  `_sg_query_unlinked_prs` correctly refuses to answer over a degraded source,
  so `unlinked-prs` reported `unknown` for the duration. Each run stayed
  individually legible. Nobody reads every run, so the practical effect was a
  query class silently contributing nothing across the fourteen-day soak that
  ADR 0033 / #1921 depends on. The sanitize stage is applied once, right after
  the read and after the empty-output default; that ordering is load-bearing
  because the `count` guard treats empty `jq` output as unparseable, so a
  payload of nothing but control bytes reports `error` — the honest answer for
  a page that could not be read — rather than being defaulted to `[]` and
  reported `absent`. Scoped to `_sg_read_pr_list`; `board.sh` is unchanged.

  **Also closed here: `_sg_read_pr_list` could return non-zero — PRE-EXISTING,
  not introduced by this change.** It was the lone `_sg_read_*` in the file
  able to escape the return-0 contract, and `_sg_build_snapshot` reads it with
  a bare `r_pr=$(...)` assignment, so under `set -euo pipefail` that return
  aborted the **whole snapshot build** rather than degrading one source. The
  `count` guard tested only `jq`'s exit status, and `jq` exits **zero with no
  output** on empty or whitespace-only input; it is now arity- and type-aware,
  yielding a count only for a single top-level JSON array. The
  `nodes=`/`edges=` transforms report `error` and return 0 on any failure
  rather than falling back to an empty array — they are modelled on the
  closed-residue block's belt-and-suspenders shape (`state-graph.sh`
  ~`:583-593`, where it guards `extra=`), and the difference is deliberate:
  `extra` there is supplementary data, whereas `nodes` here IS the answer, so
  an empty fallback would manufacture a confident false negative. The hole was
  already reachable pre-#1981 (SPACE is `0x20`, outside `tr -d '\000-\037'`,
  so a whitespace-bearing payload survived sanitizing and landed in it); what
  this change did was widen the trigger set, which is why it is closed here.

  **Behavior change:** a `null` PR-list payload now reports `error` rather than
  `absent` — `null` is not a legitimately empty PR list. A genuine `[]` still
  reports `absent`. Six new tests cover the recovered and honest-`error`
  routes; the five `error` cases each assert a zero return **and** valid JSON
  **and** status `error`, since the defects were a non-zero return with empty
  stdout and a confident `ok` over a payload that could not be projected.

  **Audit (confirmed, not assumed):** `pr_list` was the last unsanitized
  `gh → jq` seam in `state-graph.sh`, and is now covered. The other two `gh`
  reads reachable from this file were already sanitized — the closed-issue
  residue read (`state-graph.sh:583`/`:589`) and everything arriving via
  `BOARD_ITEMS_JSON`, which `board.sh`'s `_board_issues_item_list` sanitizes on
  **both** its cache-read and live-`gh` arms. The `worktrees` source parses git
  porcelain (not `gh`) and never feeds raw text to `jq`'s parser; `transcripts`
  reads local JSONL validated per line with `jq -e .`.

  The issue also asked for a lint flagging any unsanitized `_board_gh … | jq`.
  Deliberately **not** added, on kernel engineering principle 7 — after this
  fix there are zero remaining sites to catch, and a grep-shaped check cannot
  tell a user-content read from a structural-field projection. The full cost
  analysis is in the PR body.
