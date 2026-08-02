---
title: telemetry
slug: telemetry
---

## Problem

Without a durable, structured record of what the pipeline actually did —
which commands ran, which issues got touched, which pipeline ticks fired,
which extractions a drain pass produced, how expensive each `gh` call was —
every question about pipeline health, cost, or effectiveness has to be
answered by re-reading logs by hand or trusting anecdote. A regression in
extraction quality, a spike in API spend, a daemon silently degrading every
search to its slow path — none of that is visible until someone happens to
notice the symptom, and by then the cause is long gone from any live
context. A machine-run pipeline that nobody can measure is a pipeline nobody
can safely automate further.

## How it works

Every emit site writes to a shared **raw lake**: a gitignored, per-host
directory of newline-delimited JSON files, one file per stream per calendar
month (`<stream>-<YYYY-MM>.jsonl`), strictly append-only — nothing in the
lake is ever mutated in place, only appended to and rotated. A record may
carry a `schema_version` string field, bumped only on a breaking shape
change (a field removed, retyped, or repurposed); a purely additive field
needs no bump. A record with no `schema_version` field is treated as
pre-versioning.

Every stream that logs a unit of work carries the same **join key**: the
raw, untruncated session identifier of the Claude Code session that produced
the record (`null` for a manual/non-Claude-Code run). This is what lets a
reader correlate events across streams for the same working session — e.g.
matching a `command-run` record to the `issue-touches` and `pipeline` activity
that happened in the same session — without a central event bus or a shared
database.

The streams a bare checkout of this repo emits:

- **`command-run`** (`command-runs-<YYYY-MM>.jsonl`) — one record per
  `/sweep` or `/triage` invocation (the commands with no plan-note footer of
  their own to carry this signal): timestamp, session id, which command,
  which board, how many items were processed/merged/parked, and the epic it
  ran against when applicable.
- **`issue-touches`** (`issue-touches-<YYYY-MM>.jsonl`) — one record per
  meaningful touch on a tracked issue: a PR opening that closes it, a merge
  that closes it, or a capture-at-source filing. Carries the repo, issue
  number, session id, host, and touch kind.
- **`claims`** (`claims-<YYYY-MM>.jsonl`) — a sibling stream, written
  whenever a worklist item is claimed; unioned with `issue-touches` at read
  time to give the full touch history for an issue (claims are deliberately
  kept separate from opens/merges/captures rather than folded into the same
  stream).
- **`pipeline`** (`pipeline-<YYYY-MM>.jsonl`) — one record per autonomous-pipeline
  cron wake, heterogeneous by event type: a `skipped` wake (the schedule
  gate declined it), a `ran` wake (a tick actually executed, with per-board
  plans and a wall-time duration), or a `drive` wake (the auto-drive layer
  executed a tick's actions, with its own duration and outcome).
- **`findings`** (`findings-<YYYY-MM>.jsonl`) — one record per extraction the
  drain pass produces: how it was found (a lexicon tell vs. a model-skim
  catch), what kind of artifact it produced, a reference to that artifact,
  whether it was actually accepted, and both the analyzed session's model
  and the drain-runner's model (the two differ whenever a drain runs under a
  different model than the session it's analyzing). This is the stream that
  makes the extraction-tell lexicon's measured miss rate queryable rather
  than anecdotal.
- **`gh-perf`** (`gh-perf-<YYYY-MM>.jsonl`) — one record per (run, operation
  class) performance summary for wrapped `gh`/worklist-backend calls: phase
  (before/after a change under evaluation), op class, call count, and
  latency percentiles. This is the rolled-up artifact a before/after
  performance comparison reads; the raw per-call durations live in a
  separate live cache the rollup is computed from.
- **`knowledge-search-fallback`** (`knowledge-search-fallback-<YYYY-MM>.jsonl`)
  — one record, at most once per session, each time a warm search backend
  falls back to its slower cold path because a daemon was unreachable or
  returned no usable result. This is the durable, alertable signal that a
  degraded search daemon is silently slowing every search in a session,
  which would otherwise only ever surface as a per-query stderr line a
  caller typically swallows.

A downstream, composed checkout of this repo may layer additional
overlay-only streams on top (e.g. richer issue-metadata snapshots,
retrospective-verdict snapshots) with their own record shapes — those are
outside a bare checkout's scope and are not part of this inventory.

Every emit script follows the same **warn-don't-drop contract**: a bad
argument, a missing dependency, or an unwritable sink warns to standard
error and exits successfully. A telemetry emit must never fail the caller
it's instrumenting — losing one record is always cheaper than breaking the
operation being measured.

### Token spend, read from the harness instead of emitted

None of the streams above records tokens or dollars. That gap is filled
without adding a stream at all: Claude Code already persists a per-agent
`usage` block for every workflow subagent it runs, so
[`workflows/scripts/pipeline-spend-report.sh`](../../workflows/scripts/pipeline-spend-report.sh)
reads those transcripts **retroactively** and reports cost-weighted spend —
over history, with no emitter needing to have been installed beforehand.

```sh
workflows/scripts/pipeline-spend-report.sh                       # whole corpus
workflows/scripts/pipeline-spend-report.sh --since 2026-07-20    # a window
workflows/scripts/pipeline-spend-report.sh --run wf_423b8a39-a02 # one run
workflows/scripts/pipeline-spend-report.sh --format json         # machine-readable
```

It splits spend into **machinery** agents (the cheap executors that just run
shell commands) and **item workers**, by deduped API-call count, which is
what makes a before/after comparison of a machinery-batching change one
command. Its consumer inside this repo is
[`workflows/scripts/report-producers/tokens`](../../workflows/scripts/report-producers/tokens)
— the kernel-side `tokens` `report.d` producer implementation
(temperloop#980 "producer-kernel-side-relocation"), reached via the thin
locator + `exec` shim committed to an adopter's own
[`.temperloop/report.d/tokens`](../../.temperloop/report.d/tokens) — that
gives `temperloop report` its `tokens_spent` headline. See
[`docs/token-spend.md`](../token-spend.md) for the fuller picture, and that
script's own header for the four correctness traps it encodes — chief among
them deduping by `requestId`, without which the totals inflate ~2x.

### Removal — `temperloop eject` owns the `tokens` shim; never `pricing.json`

`temperloop eject` (`bin/subcommands/eject.sh`) is the sole remover of a
target repo's `.temperloop/report.d/tokens` locator shim: it carries no
manifest entry of its own (it isn't an `installs[]` side effect — see
eject.sh's own header), so it comes out the same way everything else under
`.temperloop/` does, as a side effect of removing that whole directory. No
separate revert logic exists or is needed for it.

**`.temperloop/pricing.json`, if present, is the one thing eject does NOT
remove (temperloop#985).** It is a hand-authored `{model: $/Mtok}` price
table an operator maintains themselves for `temperloop report`'s directional
dollar line (see "Token spend" above and `docs/token-spend.md`) — operator
data, not a `temperloop`-managed artifact, so uninstalling temperloop must
not delete it. `eject` preserves it byte-identical across every removal path
and prints one line naming the file it left behind; with no `pricing.json`
present, removal is unchanged from before this carve-out existed.

**This is not a claim of a clean sweep.** `eject` only ever touches the
*local checkout* it's run in — it never rewrites another branch or another
teammate's clone. If the `report.d/tokens` shim (or any other
`.temperloop/config`-recorded proposal PR) reached the default branch by
being **merged**, that merge is explicitly out of eject's revert scope (see
eject.sh's own `proposal_pr` handling), so the shim stays on the default
branch for every teammate after the merge — a local `eject` run removes it
only from the one checkout it ran in, and leaves that checkout's own
now-untracked deletion uncommitted. "No residue" therefore holds for an
**unmerged** proposal PR (declined or abandoned, eject cleans it up
completely) but not for a merged one, where the shim's removal is itself a
tree change that has to be proposed and merged like any other, not something
`eject` can retroactively erase from history.

## Integration

Consumes: nothing external — each stream's emit site is called inline from
the pipeline command or script whose activity it's recording (a build step,
a drain pass, a pipeline tick, a search-backend fallback path).

Produces: the raw lake, which several downstream readers consume without
any of them owning the schema — the kernel telemetry-brief renderer
(`workflows/scripts/telemetry-brief.sh`, the five-question status readout
`check-in` leads with on every checkout; it reads only these kernel streams
plus the knowledge-store read log, names each source stream in its output,
and degrades to an honest "no data yet" line per empty stream), a
vault-hygiene probe's read-log tally, a `gh`-performance before/after
report, and any ad hoc analysis over the raw files. `findings` in particular feeds the candidate-tells surface that
`check-in`'s review disposes. Emit-site correctness for the two oldest
streams is itself covered by dedicated validator scripts; the findings
stream has its own schema document that downstream consumers are expected
to reference rather than re-deriving the shape themselves.

## Resource impact

Each emit call is a single local file append — no network call, no
external service. Disk usage grows by one JSONL line per event, rotated
monthly per stream, and the whole directory is gitignored and per-host (a
host only ever sees the records it personally produced, absent a separate
cross-host ingest step). There is no read-time cost until a consumer
actually queries the lake — the write path imposes no aggregation or
indexing overhead of its own.

## Telemetry

This feature *is* the telemetry substrate — there is no separate meta-layer
instrumenting it. Its own health is instead covered by correctness checks:
schema-validating unit tests per stream (record shape, required fields,
enum values), and dedicated emit-validator scripts for the streams old
enough to have one. A stream that stops receiving records is directly
observable by an empty or missing month-file where one was expected.
