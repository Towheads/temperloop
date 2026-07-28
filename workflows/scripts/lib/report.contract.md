# report output contract

`report` (foundation #766, Epic E "before/after value proof") is the
**'AFTER' picture** of the epic's value loop -- `baseline-snapshot` is the
'BEFORE' picture (see `kernel/workflows/scripts/lib/baseline_snapshot.contract.md`).
Implementation: `kernel/bin/subcommands/report.sh` (bash, 3.2-compatible).
Reads every line of the target repo's `.temperloop/baseline.jsonl` and never
calls `gh` itself, **except** when invoked with `--refresh`, which shells out
to the sibling `baseline-snapshot.sh` first (to append one fresh record) and
then renders -- `baseline-snapshot.sh` remains the only place in the value
loop that talks to the GitHub API.

This doc covers two things: the kernel-tier metric definitions (so the
numbers `report` prints can never drift from what the raw baseline data
actually means), and the overlay drop-in seam's one-paragraph contract.

## Kernel tier -- first-record-vs-latest-record deltas

Always renders from `.temperloop/baseline.jsonl` alone, zero network. Every
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

**Legacy dir (temperloop#165):** the per-repo dir renamed `.foundation/` →
`.temperloop/` in v0.15.0. `report.sh` prefers `.temperloop/report.d/` and
falls back to an existing legacy `.foundation/report.d/` when the new dir is
absent — one dir wins, never a union, so a producer is never run twice. The
baseline read follows the same new-then-legacy probe. **These two reads
deliberately SURVIVE the v0.19.0 window close.** What the window governed is
which dir the CLI *resolves config from and writes to*, and those paths now
refuse legibly (`init`, `baseline-snapshot`). `report` is read-only and
reports on history it did not create, so refusing here would blind an
un-migrated repo to its own past for no safety gain — the same reasoning that
keeps `eject`/`uninstall` cleaning legacy residue. Migrating is still the
right move (`git mv .foundation/report.d .temperloop/report.d` — the dir is
tracked).

Every executable file found directly inside the target repo's
`.temperloop/report.d/` (a **tracked** dir -- meant to be committed to the
target repo, unlike the gitignored `.temperloop/baseline.jsonl`) is invoked
with no arguments, cwd = the target repo, under a per-run watchdog
(`--timeout`, default 15s); the contract is **exit 0 + a self-contained
block of stdout**, which `report.sh` renders verbatim under its own `--
report.d/<name> --` heading. A missing `.temperloop/report.d/` directory, a
present-but-non-executable file, a non-zero exit, or a timeout are **not**
errors -- each renders as one line, `skipped -- <name>: producer
unavailable`, and the run continues. The producer named exactly `tokens`
carries one additional, stricter rule used only for the headline below: its
stdout must **also** parse as a single JSON object with a numeric
`tokens_spent` field (directional token/dollar spend attributable to the
same lookback window) for `report.sh` to compute "tokens spent vs items
merged" as the headline -- an absent, failing, non-executable, or
non-JSON-conforming `tokens` producer simply falls back to the kernel-tier
headline, never an error. The `tokens` producer **may** additionally emit an
optional `by_model` object (`{"<model-id>": <tokens>, ...}`) — the model
attribution that feeds the directional dollar line (see "Pricing table &
dollar framing" below). `by_model` is purely optional: an absent or
non-object `by_model` just means no dollar line, never an error.

## Pricing table & dollar framing (foundation#882)

The tokens headline can render a **directional dollar estimate** when two
user-supplied pieces are both present:

1. the `tokens` producer emits a `by_model` breakdown (above), and
2. the target repo carries a **pricing table** at `.temperloop/pricing.json`
   — a single JSON object mapping each model id to its **USD-per-million-tokens
   list price**, e.g. `{"claude-opus-4-8": 18.00, "claude-sonnet-5": 5.40}`.

`report.sh` then multiplies each attributed model's tokens by its list price
(`tokens × price ÷ 1,000,000`), sums the priced models, and prints a
`~$<total> directional` line under the same **DIRECTIONAL** label as the
tokens headline, naming the count of priced models and **excluding** (by
name) any `by_model` model with no matching price. This is a **user-supplied,
hand-edited, directional** table, exactly like the sibling
`kernel/bin/lib/cost-estimates.conf`: it is never a live pricing-API read,
never recalculated at runtime, and refreshed only by hand-editing the file
(no regeneration script) — the producer-egress lint covers this seam and the
table read is a **local file read only, no network**. The pricing table is
**absent by default**: the kernel ships no prices (just as it ships no
`tokens` producer), so a stranger opts in by writing their own table.

Every degradation is one legible line, never an error: **no** `by_model` →
no dollar line; `by_model` present but **no** `pricing.json` → a one-line
"add `.temperloop/pricing.json`" nudge; a `pricing.json` that is **not a JSON
object** (malformed, or a valid array/number/string/`null`) → a "not a
`{model: $/Mtok}` object" note; a `pricing.json` object that matches **none**
of the `by_model` models → a "no model matched" note. The kernel-tier
headline and the tokens/item line are unchanged in every case.

**Egress:** this seam and its own drop-ins are covered by the mechanical
network-call lint at `kernel/workflows/scripts/kernel/check-producer-egress.sh`
(registered as the `test-producer-egress` quality gate) alongside
`baseline-snapshot.sh`, `report.sh` itself, and the CLI dispatcher's
auto-offer check -- see that script's header for the documented (today:
empty) opt-in egress surface for this whole value loop.

## Headline selection

- **If** a `tokens` drop-in is present, executable, exits 0, and its stdout
  parses as `{"tokens_spent": <number>, ...}`: the headline is `tokens_spent`
  divided by the **latest** record's `merged_count`, labeled directional
  (never a precise unit cost -- see "Non-goals" below). When that producer
  **also** emits `by_model` and the repo carries `.temperloop/pricing.json`,
  the headline additionally renders a directional `~$<total>` dollar line
  (see "Pricing table & dollar framing" above).
- **Else**: the headline is the kernel-tier numbers alone -- the
  merged-items/day delta plus the median-time-to-merge delta.

## Non-goals of this seam (deliberately out of scope)

- **No opinionated verdict**, mirroring `baseline_snapshot.contract.md` --
  `report` prints what changed, not whether that's good or bad.
- **No precise cost accounting.** The tokens-based headline — and the
  optional `~$<total>` dollar line derived from `by_model` × a user-supplied
  `.temperloop/pricing.json` — are explicitly labeled **directional**.
  `report.sh` has no opinion on how a `tokens` producer derives its own
  numbers, only that `tokens_spent` be a number and (optionally) `by_model`
  an object; the pricing table is a hand-edited, user-supplied,
  never-runtime-recalculated list-price map, exactly the directional posture
  of `kernel/bin/lib/cost-estimates.conf`. This is a real-dollar *framing*,
  not an accounting ledger.
- **No new baseline data.** `report.sh` computes nothing that isn't already
  in `.temperloop/baseline.jsonl` or a drop-in's own stdout -- it is a pure
  renderer (`--refresh` is the one exception, and even then the actual `gh`
  work is fully delegated to `baseline-snapshot.sh`).
