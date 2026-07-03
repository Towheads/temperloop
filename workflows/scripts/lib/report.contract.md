# report output contract

`report` (foundation #766, Epic E "before/after value proof") is the
**'AFTER' picture** of the epic's value loop -- `baseline-snapshot` is the
'BEFORE' picture (see `kernel/workflows/scripts/lib/baseline_snapshot.contract.md`).
Implementation: `kernel/bin/subcommands/report.sh` (bash, 3.2-compatible).
Reads every line of the target repo's `.foundation/baseline.jsonl` and never
calls `gh` itself, **except** when invoked with `--refresh`, which shells out
to the sibling `baseline-snapshot.sh` first (to append one fresh record) and
then renders -- `baseline-snapshot.sh` remains the only place in the value
loop that talks to the GitHub API.

This doc covers two things: the kernel-tier metric definitions (so the
numbers `report` prints can never drift from what the raw baseline data
actually means), and the overlay drop-in seam's one-paragraph contract.

## Kernel tier -- first-record-vs-latest-record deltas

Always renders from `.foundation/baseline.jsonl` alone, zero network. Every
run reads the **first** line and the **last** line of the file and reports
the delta between them across four metrics:

| Metric | Source field(s) | Derivation |
|---|---|---|
| Merged items/day | `metrics.pr_throughput.merged_count`, `lookback_days` | `merged_count / lookback_days`, computed independently per record (each record may in principle carry a different `lookback_days`, though production always uses 90) |
| Median time-to-merge | `metrics.time_to_merge_hours.median` | printed as-is, first vs latest |
| Review latency | `metrics.review_latency_hours.median` | printed as-is, first vs latest |
| Issue backlog age | `metrics.issue_backlog.median_age_days` | printed as-is, first vs latest |

**Population definition** (identical across every metric above, restated
here verbatim from `baseline_snapshot.contract.md`'s "Re-appendable by
design" section -- this is the ONE source both documents describe, so the
wording is kept in sync by hand, not duplicated independently): each
baseline record's metrics were computed over **merged pull requests** whose
`mergedAt` falls in `[generated_at - lookback_days, generated_at]`, and
**currently open issues**, unfiltered by age, both read fresh at that
record's own generation time. Because that query shape never changes
run-to-run, records accumulated over time are directly comparable -- this is
exactly what makes a first-vs-latest delta meaningful.

If either the first or the latest record has `metrics.available: false`
(see `baseline_snapshot.contract.md`'s `reason` enum), the affected side of
each delta degrades to that record's `reason` string rather than a
computed number -- never a crash, never a silently wrong number.

## Overlay drop-in contract

Every executable file found directly inside the target repo's
`.foundation/report.d/` (a **tracked** dir -- meant to be committed to the
target repo, unlike the gitignored `.foundation/baseline.jsonl`) is invoked
with no arguments, cwd = the target repo, under a per-run watchdog
(`--timeout`, default 15s); the contract is **exit 0 + a self-contained
block of stdout**, which `report.sh` renders verbatim under its own `--
report.d/<name> --` heading. A missing `.foundation/report.d/` directory, a
present-but-non-executable file, a non-zero exit, or a timeout are **not**
errors -- each renders as one line, `skipped -- <name>: producer
unavailable`, and the run continues. The producer named exactly `tokens`
carries one additional, stricter rule used only for the headline below: its
stdout must **also** parse as a single JSON object with a numeric
`tokens_spent` field (directional token/dollar spend attributable to the
same lookback window) for `report.sh` to compute "tokens spent vs items
merged" as the headline -- an absent, failing, non-executable, or
non-JSON-conforming `tokens` producer simply falls back to the kernel-tier
headline, never an error.

## Headline selection

- **If** a `tokens` drop-in is present, executable, exits 0, and its stdout
  parses as `{"tokens_spent": <number>, ...}`: the headline is `tokens_spent`
  divided by the **latest** record's `merged_count`, labeled directional
  (never a precise unit cost -- see "Non-goals" below).
- **Else**: the headline is the kernel-tier numbers alone -- the
  merged-items/day delta plus the median-time-to-merge delta.

## Non-goals of this seam (deliberately out of scope)

- **No opinionated verdict**, mirroring `baseline_snapshot.contract.md` --
  `report` prints what changed, not whether that's good or bad.
- **No precise cost accounting.** The tokens-based headline is explicitly
  labeled directional; `report.sh` has no opinion on how a `tokens` producer
  derives its own number, only that it be a JSON object with that one field.
- **No new baseline data.** `report.sh` computes nothing that isn't already
  in `.foundation/baseline.jsonl` or a drop-in's own stdout -- it is a pure
  renderer (`--refresh` is the one exception, and even then the actual `gh`
  work is fully delegated to `baseline-snapshot.sh`).
