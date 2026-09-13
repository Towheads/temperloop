- **`state-graph.sh`'s `pr_list` source now routes its `gh pr list` payload
  through `_board_sanitize_control_chars` before any `jq` touches it** (#1981),
  so one stray control byte in a single PR no longer takes the whole source
  down. Operationally: the read projects `title` and `body` — user-authored
  fields — and `jq` exits 5 on a literal control byte, which the `count` guard
  converts into a source-wide `error`. That error was **sticky**: it recurred on
  every run for as long as that one PR stayed open, out of up to 100 open PRs,
  and `_sg_query_unlinked_prs` correctly refuses to answer over a degraded
  source, so `unlinked-prs` reported `unknown` for the duration. Each run stayed
  individually legible. Nobody reads every run, so the practical effect was a
  query class silently contributing nothing across the fourteen-day soak that
  ADR 0033 / #1921 depends on. This is a **degrade-instead-of-recover** bug, not
  the silent-wrong-answer class `board.sh`'s helper header records (`ccbc6868`,
  `92feec12`) — **in the PRE-FIX code** the wrong-empty answer was structurally
  unreachable, since there the fall-through past the `count` guard was a hard
  abort rather than an empty answer. That is a claim about the code being fixed,
  not about the fix: defaulting the transforms to `[]` would have traded the
  abort for exactly that wrong-empty `ok` on a non-array payload, which is why
  they report `error` instead (below). The stage is applied once, right after the read and after the
  empty-output default; that ordering is load-bearing **because** the `count`
  guard treats empty `jq` output as unparseable, so a payload of nothing but
  control bytes — which sanitizes down to nothing — reports `error`, the honest
  answer for a page that could not be read, rather than being defaulted to `[]`
  and reported `absent` (a genuinely-empty PR list downstream queries would
  take at face value). Scoped to `_sg_read_pr_list`; `board.sh` is unchanged.

  **Also closed here: the empty-`jq`-output fall-through — PRE-EXISTING, not
  introduced by this change.** `jq` exits **zero with no output** on empty or
  whitespace-only input, so the `count` guard's exit-status-only test left
  `count` empty, `[ "" -eq 0 ]` errored and evaluated false, and execution fell
  through to `_sg_source_result ok "" ""`, whose `jq --argjson ""` fails hard —
  a **non-zero return**, which `_sg_build_snapshot`'s bare `r_pr=$(...)`
  assignment turns under `set -euo pipefail` into an abort of the **whole
  snapshot build**, not one degraded source. It was already reachable before
  this change: SPACE is `0x20`, outside `tr -d '\000-\037'`, so a
  whitespace-bearing payload survives sanitizing and lands in the same hole.
  What this change did do is **widen the trigger set** — a control-byte-only
  payload went from a clean `error` to that hard abort. `_sg_read_pr_list` was
  the lone `_sg_read_*` in the file that could escape the return-0 contract;
  it now uses `_sg_read_board`'s own idiom (`state-graph.sh:515-519`) — `||
  count=""` plus a `[ -z "$count" ]` guard reporting `error` and returning 0.
  The `nodes=`/`edges=` transforms are guarded on the same two conditions
  (non-zero `jq` exit, or zero exit with empty output), but each reports
  `error` and returns 0 rather than falling back to an empty array: they are
  modelled on the closed-residue block's belt-and-suspenders shape
  (`state-graph.sh` ~`:583-593`, where it guards `extra=`), and the difference
  is deliberate — `extra` there is supplementary data, whereas `nodes` here IS
  the answer, so an empty fallback would manufacture a confident false
  negative. The guard is **arity- and type-aware**: it yields a count only for
  a single top-level JSON array, because bare `jq 'length'` emits one line per
  input document (a multi-document payload reaches the same hard abort) and is
  defined on objects, strings and numbers (a non-array payload passes a
  length-only test, then fails the `.[]` projection). One deliberate behavior
  change follows: a `null` payload now reports `error` rather than `absent` —
  `null` is not a legitimately empty PR list. Five new tests cover the routes
  — control-byte-only, whitespace-only, multi-document, non-array JSON, and an
  array whose elements are not PR objects — each asserting a zero return **and**
  valid JSON **and** status `error`, since the defects are a non-zero return
  with empty stdout and a confident `ok` over an empty node set.

  **Audit (confirmed, not assumed):** `pr_list` was the last unsanitized
  `gh → jq` seam in `state-graph.sh`, and is now covered. The other two `gh`
  reads reachable from this file were already sanitized — the closed-issue
  residue read (`state-graph.sh:583`/`:589`) and everything arriving via
  `BOARD_ITEMS_JSON`, which `board.sh`'s `_board_issues_item_list` sanitizes on
  **both** its cache-read and live-`gh` arms. The `worktrees` source parses git
  porcelain (not `gh`) and never feeds raw text to `jq`'s parser; `transcripts`
  reads local JSONL validated per line with `jq -e .`.

  **Lint decision — deliberately NOT added.** The issue asked whether a
  quality-gate check should flag any `_board_gh … | jq` with no intervening
  sanitize stage. Weighed against kernel engineering principle 7 (weigh a
  gate's own cost before making it a hard gate), the answer is no, and the
  costs weighed are: the true-positive population after this fix is **zero**
  remaining sites, so the gate would ship with nothing to catch; a grep-shaped
  check cannot tell a user-content read from a structural-field projection, so
  a `--json number` read — which has no user-controlled text to sanitize — would
  fire as a false positive, and the standing cost of a gate is the false
  positives it makes every future author argue with; and suppressing those
  would mean an allowlist, i.e. a second registry to maintain for a
  one-instance class. The invariant stays where it already is: prose in
  `_board_sanitize_control_chars`'s own header, now restated at the one
  `state-graph.sh` site that reads user-controlled `gh` content, plus a test
  that goes red if the stage is removed.
