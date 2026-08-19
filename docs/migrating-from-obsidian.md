---
title: Migrating from Obsidian — swapping the access paths, not the store
---

# Migrating from Obsidian

The write-up of a real migration: replacing Obsidian's REST plugin and MCP
servers — how an agent read, searched, and wrote a markdown knowledge store —
with a `basic-memory` index and direct file I/O over the **same folder**. It
ran as epic
[Towheads/foundation#951](https://github.com/Towheads/foundation/issues/951)
(Obsidian → knowledge_store parallel-run migration) and finished its read
cutover on 2026-08-14.

Every `Towheads/foundation#N` reference below points at the **maintainer's own
private operations repo**, not at this one — that is where the migration was
tracked and where the harnesses it produced still live (§ What this repo
ships). Those issues are cited for provenance and may not be visible to you;
every measurement, file path, and posture key quoted from them is reproduced
here so this page stands on its own.

This is a method, not a script to run. Four things are worth copying — the
**golden-query set**, the **mutation tripwire**, the **parity ledger**, and
the **staggered writer order** — and where one of them misled us, the section
says so rather than leaving the reader to rediscover it.

## One store, two access paths

**There was never a data migration.** `basic-memory` is markdown-native and
indexes the folder Obsidian already opens, so the store stays exactly one
canonical directory of plain files throughout. No second store, no sync step,
no window in which two copies could disagree.

What migrates is the **access paths** — search, then writes, then reads — one
at a time, each independently revertible. Obsidian stays installed throughout
and afterward, in a viewer role: its GUI, plugins, and own search keep working
on the same files. That framing is what makes the exercise safe to do
incrementally, and if your notes do not already live as files you could `cat`,
the rest of this page does not apply to you (§ When not to do this).

## What the measurements actually said

The honest summary: **the new engine won on retrieval quality and lost on
per-call latency.** The second half is the part a migration write-up usually
omits.

### Quality

40 frozen queries (38 with hand-adjudicated ground truth), scored at k=5 on
2026-08-14 against the live store:

| Metric @ k=5 | `basic-memory` | Obsidian Smart Connections |
|---|---|---|
| hit@5 (≥1 relevant doc in top 5) | **0.974** (37/38) | 0.842 (32/38) |
| recall@5 | **0.947** | 0.790 |
| MRR (rank of first relevant doc) | 0.767 | **0.829** |
| zero-result rate | 0/40 | — |

Read the MRR row: **the incumbent ranked its first relevant hit higher on
average.** The challenger found the right note more often; the incumbent put
it first more often. One headline metric would have hidden that, which is the
argument for reporting hit, recall, and MRR together.

Two caveats the harness prints on its own verdict line, kept rather than
smoothed away:

- The incumbent's column is **pre-captured, not re-run** — Smart Connections
  is agent-plane only with no CLI, so its 2026-07-04 results are the only ones
  that will ever exist. The challenger's leg ran six weeks later against a
  store that had grown. The comparison is *indicative, not controlled*.
- At Phase 0, hand-adjudicating the same 40 queries scored **tie 28,
  incumbent-win 9, both-miss 2, challenger-win 1**. The challenger won
  outright exactly once out of forty. The gap above came later, from adapter
  work (hybrid retrieval plus a post-fetch re-rank) and a ground-truth
  refresh — not from the backend changing.

### Latency — not a win

Per-query wall time, same 40 queries. Both figures include process startup,
deliberately: startup is the real per-call cost of a subprocess search path.

| Path | p50 | p90 |
|---|---|---|
| Cold — one fresh `uvx`-resolved process per query (Phase 0 baseline) | **4.497s** | 4.772s |
| Warm — a long-lived local `basic-memory` daemon (cutover-gate run) | **0.493s** | 0.577s |

A spot-check of three identical queries on both paths the same afternoon:
warm 0.19 / 0.19 / 0.25s versus cold 2.28 / 2.32 / 2.61s.

**A ~4.5s median per concept search is not a usable interactive path**, and
that is the entire reason a warm-daemon supervisor unit exists
(`workflows/scripts/lib/knowledge_search_mcp.sh`) rather than the adapter
shelling out per call. Budget for the daemon from the start, and never quote a
latency number without naming which path produced it.

Not hypothetical: every latency sample in the parity ledger for the first
three weeks was taken on the cold path while a warm daemon sat idle, because
the measurement recipe set two environment variables and omitted the one that
selects the backend — a ~12× understatement, fixed as
[Towheads/foundation#1364](https://github.com/Towheads/foundation/issues/1364)
(activate the warm knowledge-search path).

## Phase 0 — prove the no-mutation posture on a copy

The one irreversible risk is the new engine *writing* to the store.
`basic-memory` can normalize frontmatter, rewrite permalinks, kebab-case
filenames, and run a filesystem watcher — all off by default here, none off by
default upstream.

So Phase 0
([`Towheads/foundation#945`](https://github.com/Towheads/foundation/issues/945),
prove read-only posture on a vault copy) ran everything against an `rsync`'d
**copy** that had been `git init`'d, using `git status` as the oracle: index
the corpus fully, then demand a clean tree. Zero mutations, or the migration
does not proceed.

The posture that survived into the shipped adapter is ten pinned keys, from
`_ks_bm_ensure_config` in
[`workflows/scripts/lib/knowledge_search.sh`](../workflows/scripts/lib/knowledge_search.sh):

```json
{
  "disable_permalinks": true,
  "ensure_frontmatter_on_sync": false,
  "format_on_save": false,
  "update_permalinks_on_move": false,
  "kebab_filenames": false,
  "sync_changes": false,
  "auto_update": false,
  "semantic_embedding_model": "bge-small-en-v1.5",
  "semantic_embedding_dimensions": 384,
  "semantic_embedding_cache_dir": "<isolated home>/embedding-cache"
}
```

Three containment choices matter as much as the keys: an **isolated `HOME`**
for the subprocess, so its config, database, and installed tool are
adapter-owned state; the **embedding cache and ignore file pinned inside that
home**, so the corpus never needs to be writable at all; and a **version pin
with `auto_update: false`**, installed once as a `uv` tool and invoked **by
absolute path** — never a bare command name `PATH` could resolve to a system
install with different defaults.

### What went wrong: a config file is not a posture

The adapter originally wrote `config.json` **only if absent**, then trusted
it. Months later a live host was found carrying the tool's *own* defaults
there — `sync_changes: true`, `ensure_frontmatter_on_sync: true`,
`auto_update: true` — precisely the mutation class the posture prevents,
silently re-enabled. The cause is mundane: `basic-memory` rewrites that file
itself when its CLI registers a project, so "adapter-owned state directory"
was a claim about intent, never a guarantee about bytes.

The fix
([`Towheads/foundation#1211`](https://github.com/Towheads/foundation/issues/1211),
config lost the no-mutation posture) is to **verify and repair on every call**
rather than trust presence:

- **Merge, never regenerate** — the tool's CLI owns the project registry in
  that same file, so rewriting from a template would deregister every live
  project. The repair sets the posture keys onto the parsed document and
  passes every other key through.
- **Idempotent by comparison** — an already-correct file is left
  byte-identical, same mtime.
- **Fail visibly** — a missing `jq` or an unparseable config warns that the
  posture is *unverified* rather than passing quietly.

The generalizable rule: a guard that checks a file *exists* is not checking
the property you care about.

## Phase 0 — constructing the golden-query set

A golden-query set is a fixed list of real queries plus hand-adjudicated
ground truth for each. It is the only instrument here that measures search
*quality* rather than the operator's diligence, and it ended up replacing the
parity ledger as the cutover gate.

**Harvest real queries; never invent them.** The frozen set is 40 queries
pulled verbatim from raw Claude Code transcripts — 101 recorded search calls,
99 unique strings. Invented queries test the phrasings you already know work.

**Make the harvest a committed script, because counting is where people slip.**
A later, larger harvest was miscounted twice in *opposite* directions by two
throwaway scripts: `~222` from a naive string-occurrence count (transcripts
replay context every turn, so the real occurrence count was 6501 — not a query
count at all), then `77` from an audit that globbed only top-level transcripts
and missed every subagent transcript one directory deeper. The measured figure
was **206 unique strings**. A committed harvester makes the arithmetic
falsifiable; a throwaway one makes it folklore.

**Freeze the set once the incumbent's column exists.** Smart Connections has
no CLI, so its results could be captured exactly once, keyed by query string,
while it was still live. Changing the query list afterward would not make the
head-to-head *stale* — it would make it **permanently unrecoverable**.

**Split retrieval from scoring, and put only scoring in CI.**

| Leg | Needs | In CI? |
|---|---|---|
| Retrieval (`run.sh`) | live store + live daemon | **No** — environment-dependent by construction |
| Scoring (`score.sh`) | committed files only | **Yes** — offline, deterministic, model-free |

Gating a required check on a live store and a live daemon buys nothing and
costs a flaky check.

**Label from note content, not from engine output.** The Phase-0 labels were
*engine-derived* — adjudicated from what the two engines returned — which
bakes the incumbent's blind spots into the ground truth. The replacement
corpus was labeled by reading notes with no ranked output consulted. Both were
kept, under different filenames, because the engine-derived set is the only
one the frozen head-to-head can be scored against.

**Report hit@k, recall@k, MRR, and the zero-result rate together** — they
disagree, and the disagreement is the finding.

### What went wrong: comparing against a corpus you never ran

The weekly regression tick scored a 40-query run against a baseline built from
a *different* 214-query corpus. Measured overlap between the two query sets:
**zero**. Every weekly delta was `aggregate(40 queries) − aggregate(214
different queries)` — a fixed offset, not a measurement.

The tell was in plain sight: two runs twelve days apart produced
**byte-identical deltas on all four metrics**, across a ~100-file corpus
growth and an adapter change. Four numbers matching to four decimal places
through all of that is a constant, not a result. Nothing caught it: the only
mismatch guard compared `k` — both sides were k=5 — and the report's
corpus-identity field was `null` on every run
([`Towheads/foundation#1688`](https://github.com/Towheads/foundation/issues/1688),
bench compares disjoint query corpora).

So: **stamp corpus identity into the report and assert it**, and treat a
suspiciously stable delta as an instrument defect until proven otherwise.

## Phase 1 — the mutation tripwire

Phase 0 proves the posture on a copy. The tripwire keeps proving it on the
live store, and is deliberately **engine-agnostic**: it detects change without
caring what caused it, so it still works if the guarantee it is checking turns
out to be wrong.

The live store was not in git, so a nightly content-hash manifest stood in for
`git status`
([`Towheads/foundation#946`](https://github.com/Towheads/foundation/issues/946),
Phase 1 shadow-read infra):

1. Walk the corpus, excluding the app's own high-churn internals, computing
   one `sha256` per file.
2. Write the sorted `<hash>  <relpath>` manifest atomically to a dated file.
3. Diff it against the most recent prior manifest.
4. On **any** added / removed / changed path: exit non-zero, append one
   incident line to a log, and write a sidecar naming exactly which paths
   moved — so a reviewer never re-derives it from stderr.

### What went wrong: three ways, all inheritable

**Detection is not attribution, and a live store changes daily.** The exit
criterion was originally "zero tripwire incidents in a two-week window." The
window 2026-07-13 → 2026-07-27 held **15 incidents in 15 days**, every one
ordinary human editing. That criterion is unsatisfiable while the store is in
use — it blocks the gate independent of anything the new engine does. Gate on
**un-cleared** incidents a human has reviewed, not on raw count
([`Towheads/foundation#1299`](https://github.com/Towheads/foundation/issues/1299),
tripwire attribution for phase-1 exit).

**The tripwire can alarm on itself.** The step that surfaced each incident
wrote its report *into the store* — inside the next run's hashed scope — so it
re-triggered its own incident forever: alarm → write → alarm. The fix is a
narrow, data-only registry of expected-writer paths excluded by **exact
relative-path match, never a directory prune**. A directory prune silences
real drift, which defeats the instrument.

**A permanently-red gate arm invites you to hollow it out.** Because the arm
only clears through a manual review ritual, it sits red between rituals, and
the tempting move is to bulk-clear the backlog so the gate passes — converting
a real check into a formality. This migration parked instead.

## Phase 1 — the parity-ledger method

While both engines are live, every concept search runs through **both**,
whichever answer is useful is used, and **one line** is appended to a ledger
([`Towheads/foundation#947`](https://github.com/Towheads/foundation/issues/947),
Phase 1 parity comparison surface):

```
- <YYYY-MM-DD> · <query> · smart|bm|tie|bm-only|smart-only · bm=<N.NN>s · <gap note>
```

The load-bearing detail is **two distinct token families**, which the first
version conflated:

- **Merit tokens** — both engines ran: `smart` / `bm` / `tie`.
- **Availability tokens** — one engine errored or was absent, so the other
  "won" by default: `bm-only` / `smart-only`. Excluded from both the pass
  tally and the latency baseline.

Folding "unavailable" into a merit token silently recorded structurally-absent
comparisons as wins, polluting both numbers
([`Towheads/foundation#1290`](https://github.com/Towheads/foundation/issues/1290),
unavailable and won-on-merit collapse).

Three real entries, abridged only for length — one win each way and one tie:

```
- 2026-08-04 · ship loop versus observe loop — kernel fast lane · bm · bm=1.67s ·
  bm's top hit WAS the governing artifact (Designs/temperloop - kernel fast lane)
  plus four on-topic kernel decisions; smart returned Observability and merge-queue
  notes that matched on the word "merge"/"observ" but not the concept.

- 2026-07-27 · durable crawl_runs RunStore adapter heartbeat interrupted sweep
  run-record store unification · smart · bm=0.45s · smart found Decisions/stageFind -
  Scheduler RunStore port (run-record seam) — near word-for-word match on the query
  terms; bm's top-5 returned adjacent crawl-status notes but MISSED it entirely.
  Genuine bm miss, content-verified.

- 2026-07-27 · kernel prose plane budget gate line count measurement · tie · bm=4.43s ·
  both surfaced the same design brief + plan as top hits; smart returned finer-grained
  section chunks, bm returned whole-doc snippets — smart better for pinpointing a
  dimension, bm better for "which docs matter". Neither missed a relevant doc.
```

**The gap note is the whole value.** A metric gives you a pass rate; the gap
note names *which query class* fails. The recurring one here: abstract or
behavioral queries where the semantic backend returned zero results. That
observation is what motivated the lexical fallback in § Phase 3.

### What went wrong: the ledger could not carry a gate

The ledger accumulated **75 entries**. The raw tally is not flattering to the
challenger, and is printed rather than summarized:

| Verdict | All 75 entries | Excluding backfills (n=43) |
|---|---|---|
| incumbent (`smart`) | 46 | 15 |
| tie | 16 | 15 |
| challenger (`bm`) | 12 | 12 |
| `smart-only` (availability) | 1 | 1 |

**32 of the 75 rows are backfills** — rows a nightly drain reconstructed after
the fact, marked `comparison missing from live capture`, where the challenger
never ran. They predate the merit/availability split, so they score as
incumbent wins for sessions that held no comparison. That distortion points at
the real problem.

The exit criterion — ≥90% challenger-as-good-or-better across two consecutive
clean weeks — was measured live and found blocked three independent ways, none
of which was evidence about the search backend:

1. **The tripwire arm was unsatisfiable** (above).
2. **The sample was 2–4 entries per week**, where one row swings the rate
   25–33 points. The "log every comparison" rule was prose-only and
   mechanically unenforced, so most sessions skipped the paired call and the
   drain backfilled the row. **The tally was substantially measuring rule
   compliance, not search parity.**
3. **Every latency sample was taken on the wrong path** — the cold one.

The cutover was therefore **re-gated on the golden-query eval**, and the
ledger demoted to a reported signal. The reasoning transfers: the eval
measures search quality rather than session discipline; 40 held-fixed queries
in one sitting beat 4 per week and are comparable run-to-run; and it is the
post-cutover regression check anyway, so the gate and the ongoing monitor are
one artifact instead of two. The trade-off accepted is that the eval is a
**point-in-time** verdict where the ledger was continuous, and a single
sitting can miss a query class that only appears in live use — which is what
the fallback chain below is for.

**Keep a parity ledger. Do not hang a gate on one** unless the paired call is
mechanically enforced rather than requested in prose.

## Phase 2 — the staggered writer migration order

Every writer moves through **one interface**, never to ad-hoc file calls, so
each writer migrates exactly once
([`Towheads/foundation#948`](https://github.com/Towheads/foundation/issues/948),
migrate the writers through the interface). Here that interface is
[`workflows/scripts/lib/knowledge_store.sh`](../workflows/scripts/lib/knowledge_store.sh):
`ks_write` (whole-document replace, staged through a sibling temp file and
renamed into place, so a killed write never leaves a half-written document),
`ks_append` (plain append-mode open, non-atomic **by design** — its use case
is incremental logs), plus `ks_read` / `ks_list`, all resolving through the
single `ks_root` seam.

The order is **lowest stakes first**, where stakes means how much damage a
malformed write does and how many things parse the result:

| # | Writer | Why here |
|---|---|---|
| 1 | Session-stub upload (a hook copying a local file into an inbox folder) | Pure local copy — the old REST call added nothing |
| 2 | Append-only ledger writes (friction ledger, toolkit notes) | Append semantics, no structure to corrupt |
| 3 | Live decision / context / pattern / mistake note creation | New files only; nothing overwritten |
| 4 | Nightly drain's learning writes | Automated, but reviewable next morning |
| 5 | Deferred-decision surface appends (five call sites) | Several sites, one shape — migrate together |
| 6 | Plan-note creation | Structured document a later step parses |
| 7 | **Plan-note run-status stamping** | **Highest stakes:** a machine parser depends on that footer |
| 8 | Personal daily-ritual writers | Last, because nothing else waits on them |

**Per writer, four steps:** switch it → run it for real once → verify the
artifact against its expected shape → leave the old path one revert away. The
existing test suites, re-pointed at the file backend, are the regression net.

The order is not arbitrary. By the time #7 moves, the interface has been
exercised by six lower-stakes writers against real data, so a bug in
`ks_write` surfaces on a friction-ledger line rather than on the document a
build parser reads. And moving #7 **eliminates a failure class rather than
porting it**: the old path patched a section by heading name, and that API
silently synthesized a duplicate heading at end-of-file when target resolution
missed — while returning success. A whole-file read-modify-write has no such
failure mode
([`docs/failure-modes/04-patch-api-silent-corruption.md`](failure-modes/04-patch-api-silent-corruption.md)).

Exit criterion: one full pipeline cycle completes with **zero** writes through
the old stack.

## Phase 3 — read cutover and retirement

The last phase is short, and mostly about not retiring things too early
([`Towheads/foundation#949`](https://github.com/Towheads/foundation/issues/949),
read cutover and retirement).

**Build the fallback chain before you uninstall anything.** A semantic miss
now falls back to a literal `rg` over the corpus, emitted in the *identical*
result contract with `score: 0` marking a lexical rather than semantic hit,
plus a one-line notice on stderr — so a query class the index ranks to nothing
degrades to answered-lexically instead of silently empty (`ks_search__rg_fallback`,
[`Towheads/foundation#950`](https://github.com/Towheads/foundation/issues/950),
post-cutover search resilience). This is only trivially available *because*
the agent is now on direct file access — a benefit of the migration that also
protects it.

**Then flip the reads and the rules together.** Remaining agent reads become
`Read`/`Glob`/`rg` over the files; search goes solely through the adapter; the
standing instruction "always use the app's tools" becomes "files are canonical,
search via the adapter, the GUI is a viewer." **Delete** the safe-targeting
contract for the retired patch API rather than leaving it standing — a stale
rule for a removed mechanism is how a rejected direction quietly comes back.

**Then uninstall the retirement set:** the local REST plugin, its certificate
and keychain trust, the MCP server registrations, the installer, the health
preflight, the failure tripwire. Keep the configs archived ~30 days; rollback
is reinstall + re-register + revert one commit. **The exit criterion is not
the cutover** — it is one week of ordinary operation afterward with no
reach-back to the retired stack.

## When not to do this

Self-select out if any of these describe you.

- **Your store is not markdown on disk.** The premise is one corpus, two
  access paths. If your notes live in a proprietary database or are reachable
  only through the app's API, there is no shared corpus, and what you are
  contemplating is a *data* migration with a real data-loss window — a
  different and much riskier exercise.
- **Your automation depends on plugins, not just your authoring.** Obsidian's
  GUI plugins keep working here because the files never move, but swapping the
  search engine carries over no plugin semantic index, Dataview query, or
  templating engine. Anything scripted against those has to be rewritten, and
  none of that work is described above.
- **You cannot hand-adjudicate ~40 queries.** Ground truth is the expensive
  part and there is no shortcut. Without labels, "parity" is an impression.
- **You have already retired the incumbent, or it has no capturable output.**
  The head-to-head existed only because the incumbent's answers were captured
  once while it was still live. Without that column you can never answer "did
  this get worse" — only "does this seem fine."
- **You are doing it for speed.** See § What the measurements actually said.
  Nothing here is a latency improvement by default, and the warm daemon that
  makes the path usable is more machinery to install, supervise, and monitor.
- **You need multi-tenant isolation.** The search layer's partition scope is a
  filter over a filename convention applied at one seam. It closes
  cross-project bleed in *search results*; it is not a confidentiality
  boundary in the store itself.

## What this repo ships, and what you write yourself

**Shipped here, reusable as-is:**
[`knowledge_store.sh`](../workflows/scripts/lib/knowledge_store.sh) (the
writer interface, root resolution, backend seam),
[`knowledge_search.sh`](../workflows/scripts/lib/knowledge_search.sh) (the
pinned `basic-memory` adapter: no-mutation posture and its verify-and-repair,
isolated home, partition filter, `rg` fallback),
`knowledge_search_mcp.sh` (the warm-daemon backend), and
[`knowledge_store.contract.md`](../workflows/scripts/lib/knowledge_store.contract.md)
as the interface spec.

**Not shipped — you build these against your own corpus:** the golden-query
harness (harvest / run / score), the parity ledger and its weekly rollup, the
hash-manifest tripwire with its clear and surface steps, and the scheduled
reindex. Each binds to one operator's corpus, query history, and scheduler, so
all four stayed in the private overlay that ran this migration rather than
shipping as kernel machinery. This page is the specification for rebuilding
them; every one is ordinary shell over `sha256`, `jq`, and the adapter above.

## Related

- [`docs/features/knowledge-store.md`](features/knowledge-store.md) — the
  shipped seam's reference page: backends, corpus pinning, resource impact.
- [`docs/failure-modes/04-patch-api-silent-corruption.md`](failure-modes/04-patch-api-silent-corruption.md)
  — the heading-targeted patch API whose failure class the writer migration
  removed outright.
- [`docs/config-precedence.md`](config-precedence.md) — how the
  `KNOWLEDGE_STORE_*` and `KNOWLEDGE_SEARCH_*` settings resolve.
- [`docs/principles.md`](principles.md) — #5, climb the maturity ladder on
  evidence: what the posture's move from written-once to verified-every-call
  instantiates.

---

*Written by claude-opus-5 on 2026-08-19.*
