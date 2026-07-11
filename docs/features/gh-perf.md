---
title: gh call logging and performance measurement
slug: gh-perf
---

## Problem

A GitHub Projects-v2 board is read and written over GraphQL, which shares one
rate-limited budget (points per hour) across every caller on the host — a
board adapter's own calls, an ad-hoc script, and any convenience CLI helper
that happens to be GraphQL-backed under the hood, all draining the same
pool. That budget has been fully drained more than once in production, each
time with no per-call record of what actually spent the points — only the
symptom (calls starting to fail) and a guess at the cause. A first
investigation blamed the obvious suspect (the board operations being
rejected) and was wrong: the actual drain came from an unrelated, convenient
"watch until done" helper polling every few seconds for the length of a long
job. Without durable, per-call attribution, that kind of root cause is
invisible — the calls that fail are not necessarily the calls that are
expensive, and there is no way to tell them apart after the fact from the
failure alone.

## How it works

**The `gh` shim.** `workflows/scripts/gh-call-logger.sh` is installed in
place of the real `gh` binary on `PATH` (`make install-gh-logger`, symmetric
with `make uninstall-gh-logger`), so every invocation of `gh` anywhere on the
host — the board adapter, an ad-hoc script, an interactive shell — passes
through it transparently. The shim times the real call (millisecond
resolution where a system `perl` with `Time::HiRes` is available, falling
back to whole-second resolution rather than failing if it isn't), runs the
real `gh` as a child process so the timing is accurate, then exits with the
real tool's exact exit code — including a signal death (e.g. Ctrl-C → 130) —
propagated verbatim. The same script also doubles as a `git-bug` logging shim
under a different install name: it is basename-generic, so whichever binary
name it is installed as is the binary it measures and execs.

**Per-call TSV capture.** Every call appends one row to a local TSV log
(default `~/.cache/gh-calls-v2.tsv`): start time, duration, exit code, pid,
parent pid, tool name, an optional caller-supplied context and op label, the
calling directory, and the full argument list. Two optional environment
variables let a caller attribute a call to a higher-level operation —
`GH_CALL_CONTEXT` for the outermost command in progress, `GH_CALL_OP` for a
finer-grained operation label (the board adapter auto-tags its own calling
function). Classifying a call as GraphQL, REST, or porcelain happens later,
at *report* time, from the recorded argument list — the shim itself stays
dumb on purpose, so the act of measuring never distorts the timing being
measured. Logging is on by default (capture-forward: the next surprise drain
is already being recorded before anyone notices it) and can be disabled
per-call with `GH_CALL_LOG=0`, which also skips the timing subprocess
entirely for a zero-overhead direct exec. The log self-rotates to one prior
generation once it passes a size threshold, so it cannot grow unbounded.
Each row is also appended, in the same call, to a per-host monthly JSONL
lake stream — the durable, cross-session record the reporting tools below
read.

Two companion scripts turn the raw log into a decision surface:

- **`workflows/scripts/probe/gh-bench.sh`** — a synthetic anchor that times a
  fixed set of board-adapter operations (cold and warm cache, optionally
  including a no-op write) and freezes the summary to the lake, so a
  before/after comparison is measuring the same workload rather than
  whatever happened to run that week.
- **`workflows/scripts/probe/gh-perf-report.sh`** — reads the live TSV and
  the lake and renders a per-operation table (grouped by op, context, or
  class), a GraphQL/REST/porcelain rollup with time share, and a
  `--compare before after` view that joins two frozen lake summaries and
  shows the delta.

**What budget drain looks like.** Point cost on the GraphQL side is flat per
query, not proportional to how much a query fetches — so the number of calls
is what matters, not their individual size. A drain typically shows up first
as failures on whichever calls happen to run *last* in the budget window,
which is not necessarily the caller actually spending the points. With this
instrumentation, the honest signal is the per-op-class table from
`gh-perf-report.sh`: a high call-count, high total-duration entry on a class
nobody suspected (a streaming status-watch helper, a polling loop) is the
tell that root-caused the original incident, and is now visible without
needing to reconstruct it from memory after the fact.

## Integration

The shim installs as a drop-in replacement for `gh` (and optionally
`git-bug`) on `PATH`; nothing that calls `gh` needs to change, since the
shim execs the real binary and preserves its interface exactly. The board
adapter and its callers are the primary attributed traffic via
`GH_CALL_CONTEXT`/`GH_CALL_OP`, but any script or interactive use of `gh` on
a host with the shim installed is captured the same way, attributed or not.
The bench and report scripts are invoked on demand (or from a scheduled
job) and read only local files — the TSV and the JSONL lake — with no
dependency on the shim being active at report time.

## Resource impact

Per call: one extra subprocess (the shim itself, plus a `perl` invocation for
sub-second timing when available) and one small TSV/JSONL append — low
single-digit milliseconds of overhead per `gh` invocation, well under the
network round-trip the call itself makes. Storage is a local, self-rotating
TSV (bounded by a size cap) plus a monthly-rotating JSONL lake file whose
size scales with call volume, both on local disk with no external
dependency. The instrumentation adds no GraphQL or REST calls of its own —
it wraps and measures existing traffic rather than generating new traffic
against the same budget it is trying to protect.

## Telemetry

Two durable streams: the live per-call TSV (`~/.cache/gh-calls-v2.tsv` by
default, overridable via `GH_CALL_LOG_FILE`) and the monthly JSONL
performance lake (`gh-perf-YYYY-MM.jsonl` under a repo's `meta/data/raw/` by
default, overridable via `GH_PERF_RAW_DIR`), the latter holding both the
synthetic bench summaries and any frozen live-window snapshots. Both are
designed to be read by the report script rather than grepped directly, but
either is plain, greppable text if a report script is unavailable.
