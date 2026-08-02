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
- **`item-efficiency`** (`item-efficiency-<YYYY-MM>.jsonl`) — one record per
  plan item confirmed merged: what that one shipped change cost, split by
  pipeline phase (design, build-driver prep, item worker, mechanical
  orchestration), each phase carrying both a cost-weighted total and the raw
  output / cache-creation / cache-read split, plus wall-clock per leg (worker,
  CI, merge-group, gate-wait, end-to-end) and agent counts by role. Its token
  figures are **selected out of the spend profiler below, never re-derived**,
  and any wall-clock leg nobody measured is recorded as `null` rather than
  zero — an absent measurement and a zero measurement mean opposite things to
  a reader asking whether ceremony is growing. This is the stream that turns
  "the pipeline feels like it spends more on preamble than on the change"
  into a number that can be watched and ratcheted.

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

Its other consumer is the `item-efficiency` stream above:
[`workflows/scripts/emit-item-efficiency.sh`](../../workflows/scripts/emit-item-efficiency.sh)
invokes this same profiler once per phase run-group and attributes the result
to a merged item. That is deliberate composition rather than a second reader —
phase totals computed independently would fork those four traps the first time
one of them was retuned, so the emit opens no transcript at all and degrades
its phases to `null` when the profiler is unreachable. The per-class
`raw_tokens` / `wall_ms` / `api_calls` fields the profiler's JSON carries on
its `machinery` and `item_workers` blocks exist for exactly that consumer.

#### How the producer reaches your repo

`temperloop init` places it. It rides the same
[tree-only proposal PR](install-cli.md) that carries `.temperloop/config`,
`init`'s own bootstrap file — *tree-only* meaning it changes files and nothing
else: never a label, never branch protection, never any other GitHub API
state. The shim is one more file in that PR's diff, marked executable (mode
755, because `temperloop report` runs the files in `.temperloop/report.d/`
rather than sourcing them). Nothing is applied directly: you review and merge
the PR like any other, and until you do, your repo is unchanged.

Two properties worth knowing before you merge it:

- **It is a locator, not the logic.** The file committed to your repo only
  finds an installed temperloop kernel and hands off to that kernel's copy of
  the real producer. So the transcript-reading logic keeps improving with
  `temperloop update`, without a stale copy frozen in your tree — and on a
  machine with no kernel installed the shim exits cleanly with a one-line
  `skipped` notice instead of failing your report.
- **An existing producer is never touched.** If `.temperloop/report.d/tokens`
  already exists — you wrote your own, or you edited the one an earlier `init`
  proposed — `init` leaves it byte-for-byte alone, says so, and omits it from
  the PR. It does not ask, and it does not overwrite; that file is yours.

### First-run notice and local disable (temperloop#986)

On its first run per person per machine, the `tokens` producer folds a
one-time disclosure into the same `notice` field it already emits every run
(see
[`workflows/scripts/lib/report.contract.md`](../../workflows/scripts/lib/report.contract.md)
§ `notice` field) — never a second line of output, so the `tokens_spent`
headline renders exactly as it would on any other run:

```
notice: first run of the temperloop tokens producer: it reads Claude Code
transcript files under $SPEND_TRANSCRIPT_ROOT (see scope below) and makes NO
network call; to disable it on this machine, run: mkdir -p
"${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/tokens-producer" && touch
"${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/tokens-producer/disabled"
(a per-machine marker file, never committed to this repo). <the same
repo-scoping notice this run already resolved>
```

It names three things: **what is read** (transcripts under
`$SPEND_TRANSCRIPT_ROOT`, at whichever true scope that run actually resolved
— the same scope-detection this producer already performs, see "Token
spend" above), that it makes **no network call**, and the exact command to
**disable it locally**. The disable command is printed **unexpanded** —
literally `${XDG_STATE_HOME:-$HOME/.local/state}/...`, not the
already-resolved path — because this text is meant for a human to select
and paste into their own shell, a second quoting boundary distinct from
anything inside the script itself: interpolating the resolved path would
break (silently, exit 0, with the disable never actually taking) the moment
that path contained a shell-special character such as an apostrophe.

**Why this fires producer-side rather than at `init`.** `init`'s own
proposal-PR flow (see "How the producer reaches your repo" above) only ever
reaches whoever ran `init`. A teammate
who inherits the `.temperloop/report.d/tokens` shim by a plain `git pull` —
never having run `init` themselves — has no other way to learn that a
`temperloop report` run in this repo reads their own Claude Code
transcripts, so the disclosure has to fire on that teammate's own first
invocation instead.

**The disable is per-person, per-machine, never a commit — and never a bare
env var either.** Both the "already shown" and "disabled" states live under
`${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/tokens-producer/` — the
same XDG-state *convention* the CLI dispatcher's own 14-day report offer
(`_foundation_check_report_offer` in
[`bin/temperloop`](../../bin/temperloop)) uses for its dismiss marker, never
inside the git tree, so nothing here can silently disable the producer for
every collaborator who clones the repo. The two markers are **not**
analogous in *scope*, though: `bin/temperloop`'s dismiss marker is keyed by
repo path (`dismiss_key="${repo_root//\//_}"`) — dismissing the report offer
in one repo doesn't dismiss it in another. The `tokens` producer's disable
marker carries **no repo component** — disabling it in one adopted repo
disables it in **every** repo this same producer runs in on this machine,
matching the item's "per user/machine" scope. An env var was considered and
rejected for the *durable* half of this: `export`ing something in one shell
vanishes the moment that shell closes, so a cron tick or a second terminal
would silently go back to reading transcripts with no further signal — the
opposite of a disable that's supposed to stay off until someone turns it
back on. The XDG marker is what makes the disable last past the shell that
set it; disabling is one command a person runs for themselves:

```sh
mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/tokens-producer" \
  && touch "${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/tokens-producer/disabled"
```

Once that marker exists, the producer stops reading transcripts entirely and
degrades via the same path an unavailable producer already uses — but this
is **not** identical to the producer being genuinely absent. `report.sh`
still finds the `.temperloop/report.d/tokens` shim, still runs it, still
gets a clean exit 0, and so still renders its own
`-- report.d/tokens --` heading followed by the shim's
`skipped -- tokens: producer unavailable` line — a block that never appears
at all when no `tokens` producer is installed in the first place. What
disabling actually guarantees is narrower and headline-only: because that
skip line isn't JSON, it doesn't parse as `{tokens_spent: <number>, ...}`,
so `report.sh`'s **headline** falls back to the kernel-tier numbers
(merged-items/day and time-to-merge deltas only, no `tokens_spent` line) —
exactly the headline a genuinely absent producer would also produce, even
though the rendered report body is not byte-identical. A second,
un-disabled run after the first simply omits the disclosure prefix; the
repo-scoping notice keeps rendering every run as before.

### Removal — `temperloop eject` owns the `tokens` shim; never `pricing.json`

`temperloop eject` (`bin/subcommands/eject.sh`) is the sole remover of a
target repo's `.temperloop/report.d/tokens` locator shim: the shim carries
no entry of its own in the per-repo **install manifest** (`.temperloop/config`
— the record `temperloop init` writes of everything it set up, and the one
thing `eject` reads to know what to revert), so it comes out the same way
everything else under `.temperloop/` does, as a side effect of `eject`
removing that whole directory. No separate revert logic exists or is needed
for it.

**`.temperloop/pricing.json`, if present, is the one thing `eject` does NOT
remove (temperloop#985).** It is a hand-authored `{model: $/Mtok}` price
table an operator maintains themselves for `temperloop report`'s directional
dollar line (see "Token spend" above and `docs/token-spend.md`) — operator
data, not a `temperloop`-managed artifact, so **`eject`** (removing
temperloop from a repo) must not delete it. `eject` preserves it
byte-identical across every removal path and prints one line naming the
file it left behind; with no `pricing.json` present, removal is unchanged
from before this carve-out existed.

**This is not a claim of a clean sweep.** `eject` only ever touches the
*local checkout* it's run in — it never rewrites another branch or another
teammate's clone. `temperloop init` proposes its tree changes as a
reviewable [proposal PR](install-cli.md#how-it-works) rather than pushing
directly; if the `report.d/tokens` shim (or any other change that same PR
carried) reached the default branch by being **merged**, undoing that merge
is explicitly out of `eject`'s scope (see eject.sh's own handling of a
merged proposal PR), so the shim stays on the default branch for every
teammate after the merge — a local `eject` run removes it only from the one
checkout it ran in, and leaves that checkout's own now-untracked deletion
uncommitted. "No residue" therefore holds for an **unmerged** proposal PR
(declined or abandoned, `eject` cleans it up completely) but not for a
merged one, where the shim's removal is itself a tree change that has to be
proposed and merged like any other, not something `eject` can retroactively
erase from history.

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
