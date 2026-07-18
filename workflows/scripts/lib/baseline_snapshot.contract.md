# baseline-snapshot output contract

`baseline-snapshot` (foundation #766, Epic E "before/after value proof") is
the **'BEFORE' picture** of the epic's value loop: a discovered `foundation`
subcommand (`kernel/bin/subcommands/baseline-snapshot.sh`) that, on every
run, appends exactly **one** aggregate-only JSON record to
`.temperloop/baseline.jsonl` **in the target repo (the current working
directory)**, derived from a 90-day `gh`-history lookback. A later item's
"report" reads every line of that file and never calls `gh` itself — this
script is the only place in the value loop that talks to the GitHub API for
the baseline signal.

Implementation: `kernel/bin/subcommands/baseline-snapshot.sh` (bash,
3.2-compatible). Depends on `git` and `jq` (hard requirement — exit 1 if
either is missing); `gh` is optional and its absence, an unauthenticated
`gh`, or a network failure only degrades the emitted record to
`metrics.available: false` — it never fails the run. No egress beyond `gh`
itself.

## The soft-seam invocation contract

Invoked with **no arguments**, operating on the current working directory
(the target repo). This is the exact contract
`kernel/bin/subcommands/init.sh` Step 0 relies on: it shells out to this
script (`bash "$BASELINE_SNAPSHOT"`, cwd already set to the target repo)
**iff the sibling file exists** — the dispatcher's own file-discovery *is*
the capability probe, so no second "is it there" check is hand-maintained
anywhere. Absent, init.sh prints `skipped — baseline-snapshot unavailable`
and continues either way; present, a non-zero exit from this script is
still non-fatal to init.sh (it only prints a continuation notice) — this
script is a **soft seam that never blocks a caller**.

This script is *also* independently reachable as `foundation
baseline-snapshot` (any `kernel/bin/subcommands/<name>.sh` file is
automatically `foundation <name>`, per the dispatcher's discovery model —
see `kernel/bin/foundation`'s header comment). Both call sites use the
identical contract below.

**Exit codes**: `0` — a record was appended (even one with
`metrics.available: false` — that is a legible, successful run, not a
failure). `1` — the record could not be written to disk (a `mkdir`/append
failure — the one case where "a record was appended" is actually false).
`2` — invalid CLI usage (this subcommand takes no positional arguments).

## Effects

1. **`.temperloop/baseline.jsonl`** (repo-root-relative, appended to — never
   rewritten) gains exactly one line: a compact single-line JSON record,
   schema below.
2. **`.temperloop/.gitignore`** is created (or, if present, appended to) so
   it contains a `baseline.jsonl` line — idempotent, checked before every
   write so a repeat run never duplicates the entry. This script writes
   that file **directly to disk**, not via a reviewable proposal PR: unlike
   `init.sh` (which has `proposal-pr.sh` available for every tree change it
   makes), this script must also work when invoked completely standalone
   (`foundation baseline-snapshot`, no `init.sh` in the loop at all), so it
   owns its own idempotent gitignore-management step rather than leaning on
   a PR-generation seam it can't assume is being driven.
3. Both are runtime, per-checkout, generated data — never meant to be
   committed, which is exactly what the self-managed `.gitignore` entry
   ensures on a cold repo with no prior `.temperloop/` directory at all
   (the first run creates both the directory and the ignore entry).

**Legacy-dir window (v0.15.0 → removed in v0.17.0).** The per-repo dir
renamed `.foundation/` → `.temperloop/` in v0.15.0 (temperloop#165). An
**existing** legacy `.foundation/baseline.jsonl` keeps accreting **in
place** through the window (the baseline is one append-only before/after
history; splitting it across two dirs would truncate every later report's
"before" anchor), with a one-line `NOTE` per run; a repo with no legacy
baseline writes under `.temperloop/` from the first run. `report` reads
whichever single file exists (new preferred). The legacy arm is removed in
v0.17.0 — migrate with `mkdir -p .temperloop && mv
.foundation/baseline.jsonl .temperloop/` (the file is gitignored, never
tracked).

## Re-appendable by design

Every run reads a **fresh** 90-day lookback as of that run's own `gh` read
— there is no cross-run state read back in, and no per-run configuration
that could drift the population definition between runs. Concretely, each
run independently queries:

- **merged pull requests** whose `mergedAt` falls in `[now - 90d, now]`
  (via `gh pr list --state merged --search "merged:>=<date>"`)
- **currently open issues**, unfiltered by age (via `gh issue list --state
  open`)

Because the population definition (the two `gh` queries above) never
changes run-to-run, records accumulated across many runs are directly
comparable — a later report can read every line in
`.temperloop/baseline.jsonl` and trend the metrics over time without
re-deriving what each run actually measured.

## Consent posture: aggregate-only, by construction

Every metric below is a population statistic (a count or a median) over
the lookback window. `gh pr list --json reviews` necessarily returns each
review's author alongside its timestamp (`gh`'s `--json` flag has no
sub-field selector) — so that identifying data transiently exists in this
script's process memory for the duration of one run, but **only
`.reviews[].submittedAt` is ever read out of it**: no name, login, or
per-person breakdown is computed, held past the in-memory median
calculation, or written to the record. There is no per-author or
per-reviewer field anywhere in the schema below, by construction — not a
redaction step applied after the fact.

## Output schema

```json
{
  "schema": 1,
  "generated_at": "2026-07-03T15:13:43Z",
  "lookback_days": 90,
  "repo": { "gh_repo": "owner/repo" },
  "metrics": {
    "available": true,
    "reason": null,
    "pr_throughput": { "merged_count": 42 },
    "time_to_merge_hours": { "median": 18.5, "sample_size": 42 },
    "review_latency_hours": { "median": 3.25, "sample_size": 30 },
    "issue_backlog": { "open_count": 57, "median_age_days": 91.0 }
  }
}
```

| Field | Type | Meaning |
|---|---|---|
| `schema` | int | Record schema version, currently `1`. A future breaking change bumps this; a consumer should check it before trusting field shapes below. |
| `generated_at` | string | UTC ISO-8601 timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`) stamped **at the time this specific record was generated** — this is the durable anchor a later auto-offer feature reads to decide "how long since the last baseline", deliberately **never** the file's OS mtime (which a copy, restore, or `git checkout` can silently reset with no relationship to when the data was actually captured). |
| `lookback_days` | int | The window size this record's metrics were computed over. Always `90` in production; a test-only env var can override it (see the script's header) so fixtures don't need to fabricate 90 days of history. |
| `repo.gh_repo` | string \| null | `OWNER/REPO`, inferred from the target repo's `origin` remote (github.com URLs only — same inference shape as `conventions-probe.sh`'s `slug_from_remote`, duplicated rather than shared so this soft-seam script has no runtime dependency on a sibling script's CLI). `null` if no such remote resolves. |

### `metrics`

| Field | Type | Meaning |
|---|---|---|
| `available` | bool | `true` iff every field below it reflects a real `gh` read. `false` means "could not determine" — see `reason`. |
| `reason` | string \| null | Non-null iff `available` is `false`. One of: `"skipped — could not determine a GitHub owner/repo (no github.com origin remote)"`, `"skipped — gh CLI not found on PATH"`, `"skipped — could not compute the lookback window start date"`, `"skipped — gh not authenticated (or the auth check timed out)"`, `"skipped — gh pr/issue list call failed or timed out after Ns"`, `"skipped — metrics computation failed (unexpected gh output shape)"`. |
| `pr_throughput.merged_count` | int \| null | Count of pull requests merged in the lookback window. `null` when `available` is `false`. |
| `time_to_merge_hours.median` | number \| null | Median, across those same merged PRs, of `mergedAt - createdAt` in hours (2 decimal places). `null` if the window has zero merged PRs, or `available` is `false`. |
| `time_to_merge_hours.sample_size` | int \| null | How many PRs the median above was computed over. |
| `review_latency_hours.median` | number \| null | Median, across merged PRs that received **at least one review**, of `first_review.submittedAt - createdAt` in hours. A PR with zero reviews is excluded from this specific median (its `sample_size` is therefore `<=` `pr_throughput.merged_count`), not counted as a zero. |
| `review_latency_hours.sample_size` | int \| null | How many PRs had at least one review and contributed to the median above. |
| `issue_backlog.open_count` | int \| null | Count of currently open issues (no age filter — the entire open backlog, not just issues opened in the lookback window). |
| `issue_backlog.median_age_days` | number \| null | Median, across every currently open issue, of `generated_at - createdAt` in days (2 decimal places). |

## Non-goals of this seam (deliberately out of scope)

- **No per-reviewer or per-author breakdown, ever.** See "Consent posture"
  above — this is the load-bearing constraint on the whole schema, not a
  field that happens to be absent.
- **No cross-run aggregation.** This script only ever computes and appends
  ONE record from a fresh `gh` read; trending/comparing across the
  accumulated `.temperloop/baseline.jsonl` lines is a later report's job,
  which this script has no opinion on.
- **No opinionated verdict.** Like `conventions-probe.sh`, this script
  reports what it *measured*, not what a repo *should* do about it — no
  "your review latency is too high" field.
- **No proposal-PR machinery.** Unlike `init.sh`'s tree changes, this
  script's two on-disk effects (`.temperloop/baseline.jsonl`,
  `.temperloop/.gitignore`) are written straight to disk, not proposed —
  see "Effects" above for why.
