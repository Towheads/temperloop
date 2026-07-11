# `meta/data/raw/` — kernel telemetry raw-lake sink spec

This directory is the append-only, JSONL, monthly-rotated **raw lake** the
kernel's telemetry emit sites write to. It is gitignored and per-host: nothing
here is committed, and (absent a cross-host ingest) each host only sees the
records it personally emitted. This file is the **canonical sink spec** every
kernel emit site's header comment points at ("canonical sink spec:
`meta/data/raw/README.md`") — it documents the lake path convention, the
schema-version convention, and the per-stream record shapes for the streams
this kernel checkout emits.

**Scope.** This stub documents only the streams a bare kernel checkout
actually emits: `command-run`, `issue-touches` (plus its `claims` sibling,
unioned at read time), `funnel`, `knowledge-search-fallback`, and `gh-calls`.
A downstream overlay checkout (e.g. the
composed foundation repo) layers additional, overlay-only telemetry streams
on top — with their own record shapes, for capabilities this bare kernel
checkout doesn't have (e.g. rework tracking, richer issue-metadata snapshots,
retrospective-verdict snapshots). Those overlay-only streams are **not**
documented here; the overlay's own README extends this stub additively
rather than replacing it.

## Lake path convention

Every stream lands in this directory (or wherever `<STREAM>_RAW_DIR` /
`FUNNEL_RAW_DIR` overrides point, tests only) as one file per calendar month:

```
meta/data/raw/<stream>-<YYYY-MM>.jsonl
```

- `command-runs-<YYYY-MM>.jsonl`
- `issue-touches-<YYYY-MM>.jsonl`
- `claims-<YYYY-MM>.jsonl`
- `funnel-<YYYY-MM>.jsonl`
- `gh-calls-<YYYY-MM>.jsonl`

Each file is newline-delimited JSON (JSONL), one record per line, strictly
append-only — a reader unions across month-files as needed and never expects
in-place mutation of a written line.

## Schema-version convention

A stream's records MAY carry a top-level `schema_version` field: a **string**
(not a number), bumped only on a breaking shape change (a field removed, a
type changed, a meaning changed) — never on a purely additive change (a new
optional field is not a breaking change and does not require a bump).

Not every stream carries the field explicitly yet. `issue-touches` is the
precedent: every record explicitly carries `schema_version: "1"`. Streams
that don't yet emit the field (`command-run`, `claims`, `funnel`) are
implicitly at their initial, unversioned shape — the convention going forward
is that the *first* breaking change to any of those streams is also the
change that introduces its `schema_version` field (starting at `"1"`), rather
than retrofitting it speculatively. A reader that cares about shape stability
should treat a record with no `schema_version` field as pre-versioning /
`"1"`-equivalent.

## Streams

### `command-run` — `command-runs-<YYYY-MM>.jsonl`

Emitted by `workflows/scripts/emit-command-run.sh` (foundation #729), one
record per `/sweep` or `/triage` command run — these commands have no
plan-note footer of their own (unlike `/build`), so this is their only
telemetry signal.

Record shape: `{ts, session_id, command, board, items_processed, merged, parked, epic?}`

| field | type | notes |
|---|---|---|
| `ts` | string | ISO-8601 UTC, `Z` suffix |
| `session_id` | string \| null | raw, untruncated `$CLAUDE_CODE_SESSION_ID` — the join key other raw/ streams key on; `null` for a non-Claude-Code/manual run |
| `command` | string | `"sweep"` \| `"triage"`, verbatim from `--command` |
| `board` | number \| string \| null | the logical board number (`--board`), or `null` if omitted |
| `items_processed` | integer | how many items the run drove/considered |
| `merged` | integer | how many reached a successful terminal outcome |
| `parked` | integer | how many were parked/deferred/escalated |
| `epic` | number \| string, OPTIONAL | the epic issue number the run drove against (e.g. `/assess --epic N`, or `/build` on a plan note with an `epic:` frontmatter field), from `--epic`. ABSENT from the record entirely (not `null`) when the caller doesn't pass `--epic` — purely additive, no `schema_version` bump |

Example record:

```json
{"ts":"2026-07-05T14:03:11Z","session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","command":"sweep","board":3,"items_processed":4,"merged":3,"parked":1}
```

Example record, run against an epic (`--epic` passed):

```json
{"ts":"2026-07-05T14:03:11Z","session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","command":"sweep","board":3,"items_processed":4,"merged":3,"parked":1,"epic":42}
```

### `issue-touches` — `issue-touches-<YYYY-MM>.jsonl`

Emitted by two sites that both write the same record shape into the same
stream (foundation #916/#919):

- `workflows/scripts/emit-issue-touch.sh` — emits `kind:"pr-open"` (build.md
  Step 3f) and `kind:"merge"` (build.md Step 4d).
- `workflows/scripts/board/capture.sh`'s own `issue_touch_log_emit` — emits
  `kind:"capture"` at the moment a noticed-but-not-now item is captured.

Record shape: `{schema_version, ts, repo, issue, session_id, host, kind}`

| field | type | notes |
|---|---|---|
| `schema_version` | string | `"1"` — bump on a breaking shape change |
| `ts` | string | ISO-8601 UTC, `Z` suffix |
| `repo` | string | `"owner/repo"` the issue lives in |
| `issue` | integer | issue number |
| `session_id` | string \| null | raw, untruncated `$CLAUDE_CODE_SESSION_ID` — same join-key convention as `command-run`; deliberately NOT the truncated `host:sess8` board stamp |
| `host` | string | `$SUBSET_HOST_LABEL` if set, else `hostname -s` |
| `kind` | string | `"pr-open"` \| `"merge"` \| `"capture"` |

Example record:

```json
{"schema_version":"1","ts":"2026-07-05T14:07:22Z","repo":"acme/widgets","issue":42,"session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","host":"mini","kind":"pr-open"}
```

**Sibling: `claims` — `claims-<YYYY-MM>.jsonl`.** `workflows/scripts/board/claim.sh`'s
`claim_log_emit` writes claim touches (deliberately *not* emitted by
`emit-issue-touch.sh`, which only ever emits `pr-open`/`merge`) into their own
`claims-<YYYY-MM>.jsonl` file, unioned at read time with `issue-touches` to
give the full touch history for an issue. Its record shape (documented in
full at `claim_log_emit`'s own header comment):
`{ts, host, session_id, board, issue, item_id}` — no `schema_version` field
yet (see the schema-version convention above for what that implies).

### `funnel` — `funnel-<YYYY-MM>.jsonl`

Emitted by `workflows/scripts/build/funnel-cron.sh` (foundation #596), one
record per cron wake — every wake writes exactly one record via the script's
`emit_record` chokepoint, which stamps a shared `ts` onto whatever event
record Steps 1–4 built. Records are heterogeneous by `event`; the fields
below `event`/`ts` vary by event type.

Base shape: `{event, ts, ...event-specific fields}`

| `event` | when | notable fields |
|---|---|---|
| `skipped` | the schedule gate declined this wake | `date`, `reason`, optional `context` (gate error) |
| `ran` | the gate allowed the wake and a tick ran | `date`, `boards` (array), `nonop_actions` (integer), `duration_ms`, `plans` (array of per-board tick plans) |
| `drive` | rung 5b/5c auto-drive executed (only when `FUNNEL_DRIVE=1` and the tick found non-no-op work) | `status`, `date`, `duration_ms`, and on error: `reason`, `context` (captured driver stderr) |

Any record may also carry a `self_update` object (foundation #598's
self-update sandbox outcome) when a self-update was attempted that wake.

Example record (`ran`):

```json
{"event":"ran","date":"2026-07-05","boards":["3","4"],"nonop_actions":2,"duration_ms":8421,"plans":[{"board":"3","actions":[{"action":"route-foundational"}]}],"ts":"2026-07-05T15:00:03Z"}
```

Example record (`skipped`):

```json
{"event":"skipped","date":"2026-07-05","reason":"not-scheduled","ts":"2026-07-05T15:00:00Z"}
```

### `knowledge-search-fallback` — `knowledge-search-fallback-<YYYY-MM>.jsonl`

Emitted by the WARM search backend
`workflows/scripts/lib/knowledge_search_mcp.sh` (`_ks_bm_mcp_fallback_signal`,
temperloop#54), one record each time a `KNOWLEDGE_SEARCH_BACKEND=basic-memory-mcp`
search falls back from the warm `basic-memory mcp` daemon to the cold `uvx`
CLI path — because the daemon was unreachable, or reachable but returned no
usable result. This is the durable, alertable signal that a down daemon is
degrading every `ks_search` to the slow path; without it the only trace was a
per-query stderr line the caller usually swallows.

**De-dup:** emitted at most ONCE per session (keyed by
`$CLAUDE_CODE_SESSION_ID`, else the process id), the same gate that de-dupes
the one-time-per-session stderr notice — so a caller looping many queries
against a down daemon produces ONE record, not per-query spam. Fail-open: the
emit never blocks or fails the search (still returns cold-path results, exit
0).

Record shape: `{schema_version, ts, session_id, host, backend, reason, detail, url, project}`

| field | type | notes |
|---|---|---|
| `schema_version` | string | `"1"` — bump on a breaking shape change |
| `ts` | string | ISO-8601 UTC, `Z` suffix |
| `session_id` | string \| null | raw, untruncated `$CLAUDE_CODE_SESSION_ID` — same join-key convention as the other streams; `null` on a non-Claude-Code/manual run |
| `host` | string | `$SUBSET_HOST_LABEL` if set, else `hostname -s` |
| `backend` | string | `"basic-memory-mcp"` (the warm backend that fell back) |
| `reason` | string | `"unreachable"` (daemon not answering) \| `"degraded-result"` (reached, but no usable result — usually a `--project` mismatch) |
| `detail` | string | human-readable one-line cause (same text as the stderr notice) |
| `url` | string | the daemon endpoint (`KNOWLEDGE_SEARCH_BM_MCP_URL`) |
| `project` | string | `KNOWLEDGE_SEARCH_BM_PROJECT` the client asked for |

Example record:

```json
{"schema_version":"1","ts":"2026-07-05T15:11:04Z","session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","host":"mini","backend":"basic-memory-mcp","reason":"unreachable","detail":"bm mcp daemon unreachable at http://127.0.0.1:8766/mcp","url":"http://127.0.0.1:8766/mcp","project":"foundation-knowledge"}
```

### `gh-calls` — `gh-calls-<YYYY-MM>.jsonl`

Emitted by `workflows/scripts/gh-call-logger.sh` (the `gh`/`git-bug` TIMED
call-logger shim, F#988; lake promotion: temperloop `gh-logger-lake-stream`),
one record per wrapped `gh`/`git-bug` invocation. Unlike the other streams on
this page, the emit site is an **installed** shim (`make install-gh-logger`
copies it to `~/.local/bin/gh`, decoupled from any repo checkout on disk), so
its raw-dir resolution is override-then-**fixed-fallback**
(`${GH_CALLS_RAW_DIR:-$HOME/dev/foundation/meta/data/raw}`) rather than the
BASH_SOURCE-relative trick the in-repo emit sites use.

**Dual-write, not a replacement (yet).** This stream is written *alongside*
the shim's pre-existing self-truncating live TSV
(`${GH_CALL_LOG_FILE:-$HOME/.cache/gh-calls-v2.tsv}`), not instead of it —
`workflows/scripts/probe/gh-perf-report.sh` still reads that TSV directly for
the F#988 git-bug-tracker before/after evaluation's live-window tables, a
real current consumer. The TSV write retires once `gh-perf-report.sh` is
migrated to read this lake stream instead (or the F#988 evaluation
concludes), whichever comes first.

Record shape: `{schema_version, ts, host, start_ms, dur_ms, exit_code, pid, ppid, tool, context, op, cwd, args, session_id}`

| field | type | notes |
|---|---|---|
| `schema_version` | string | `"1"` — bump on a breaking shape change |
| `ts` | string | ISO-8601 UTC, `Z` suffix (wall-clock time the row was logged, i.e. after the wrapped call returned) |
| `host` | string | `$SUBSET_HOST_LABEL` if set, else `$HOSTNAME` (bash's own, domain-stripped) or `hostname -s` — same derivation as `claim.sh` / `emit-issue-touch.sh`, per-host as this whole directory is |
| `start_ms` | integer | epoch milliseconds the wrapped call started (ms-resolution via perl `Time::HiRes` when available, else whole-second) |
| `dur_ms` | integer | wall-clock duration of the wrapped call, in ms |
| `exit_code` | integer | the wrapped call's verbatim exit code, including 128+N signal deaths (e.g. Ctrl-C → 130) |
| `pid` / `ppid` | integer | the shim process's own pid / parent pid |
| `tool` | string | `"gh"` or `"git-bug"` — this shim's own install basename (basename-generic: the same script installed as either name logs+dispatches that same name) |
| `context` | string \| null | `$GH_CALL_CONTEXT` — the outermost command (`worklist` / `reconcile` / `funnel-tick` / …), `null` when unset |
| `op` | string \| null | `$GH_CALL_OP` — fine-grained per-call attribution tag (e.g. the board adapter's calling function), `null` when unset |
| `cwd` | string | `$PWD` at call time |
| `args` | string | the wrapped call's arguments, space-joined, with embedded tabs/newlines flattened to spaces (same sanitization as the TSV's `args` column, so a GraphQL query arg can never split or corrupt the record) |
| `session_id` | string \| null | raw, untruncated `$CLAUDE_CODE_SESSION_ID` — same join-key convention as the other streams; `null` on a non-Claude-Code/manual run |

Example record:

```json
{"schema_version":"1","ts":"2026-07-10T18:22:47Z","host":"mini","start_ms":1783455767210,"dur_ms":143,"exit_code":0,"pid":41213,"ppid":41190,"tool":"gh","context":"worklist","op":"board:_board_item_list_fresh","cwd":"/home/dev/checkout","args":"issue list --repo o/r","session_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890"}
```
