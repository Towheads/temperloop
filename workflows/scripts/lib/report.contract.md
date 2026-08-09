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
stdout must **also** parse as exactly one JSON object and nothing else —
leading or trailing non-JSON text disqualifies it — with a numeric
`tokens_spent` field (directional token/dollar spend attributable to the
same lookback window) for `report.sh` to compute "tokens spent vs items
merged" as the headline -- an absent, failing, non-executable, or
non-JSON-conforming `tokens` producer falls back to the kernel-tier
headline, never an error.

**That fallback is announced, not silent (temperloop#988).** When the
`tokens` producer was present, executable, and exited 0 but its stdout
failed the parse above, `report.sh` renders one line in the **same
per-producer skipped-line channel** the not-executable / non-zero-exit /
timeout cases already use, positioned inside that producer's own `--
report.d/tokens --` block (after the verbatim stdout and any `notice` line,
before the trailing blank line):

```
skipped -- tokens: stdout did not parse as a single JSON object with a numeric tokens_spent field (headline fell back to the kernel tier -- not an error; see report.contract.md)
```

Two things this does **not** change: the kernel-tier headline fallback
itself is byte-identical to before, and the run still exits 0 -- a
non-conforming `tokens` producer remains a legible degradation, never an
error. **One exception, for a producer that already self-declared:** stdout
whose first line already begins with `skipped -- ` (the shape the kernel's
own `tokens` shim prints, and exits 0 with, when it cannot resolve a kernel
or when a person has locally disabled it -- see `docs/features/telemetry.md`)
suppresses this line rather than printing a second, redundant skip under the
same heading. The `tokens` producer **may** additionally emit an
optional `by_model` object (`{"<model-id>": <tokens>, ...}`) — the model
attribution that feeds the directional dollar line (see "Pricing table &
dollar framing" below). `by_model` is purely optional: an absent or
non-object `by_model` just means no dollar line, never an error.

**Reserved top-level keys (temperloop#981).** `notice` below is the first
point in this contract where a producer's stdout is interpreted rather than
only echoed verbatim, regardless of the producer's own name — so the scoping
needs to be explicit. The kernel reserves top-level JSON keys on **any**
producer's stdout for its own use; `notice` is the first one. This is a
**global** reservation, unlike `tokens_spent`/`by_model`, which stay scoped
to the producer literally named `tokens` — a producer of any name should
treat an unrecognized top-level key it did not itself define as potentially
kernel-owned, and avoid colliding with `notice`.

**stderr is discarded (temperloop#981).** `report.sh` invokes every producer
with stderr redirected away (`2>/dev/null`) and never inspects it — any
diagnostic or informational text a producer writes to stderr is invisible to
a human reading the report. This has always been the actual behavior; it is
stated explicitly here because it is exactly the trap a producer that wants
to say something to a human falls into — **stderr is not a channel.** Use
`notice` below instead.

**`notice` field (temperloop#981) — and when it's the right channel.** For a
producer whose stdout is otherwise unconstrained plain text, plain verbatim
stdout already **is** the human channel — every character reaches the reader
unmodified, under the producer's own heading. Such a producer gains nothing
from switching to JSON just to carry a `notice`: `report.sh`'s verbatim
`echo` still dumps the raw JSON above the notice line, so the human sees the
message twice. `notice` exists for the opposite case — a producer whose
stdout is contractually constrained to exactly one JSON document, where no
unconstrained plain-text channel exists. **Today that means two producers,
not one** (temperloop#1261 added the second): `tokens`, whose single-object
rule this contract imposes so `report.sh` can read `tokens_spent` for the
headline; and the kernel-shipped `model-comparison` producer, which imposes
the same rule on **itself** — see "Kernel-shipped `model-comparison`
producer" below. The two arrive at the constraint from opposite directions
and only the first feeds a headline, but a `notice` is the right (and only)
human channel for both, and any future producer bound by the same kind of
single-JSON-object rule is likewise an intended user. Such a producer's
stdout MAY carry a
top-level string `notice` field alongside its other fields — e.g.
`{"tokens_spent": 1234, "notice": "<text>"}` — independent of, and in
addition to, the `tokens`-only `tokens_spent`/`by_model` rules above.

`report.sh` renders a present `notice` as a `notice: <text>` line — that
exact `notice: ` prefix is the published surface, not an implementation
detail — positioned immediately after the producer's verbatim stdout block
and before the trailing blank line / next producer's heading. `notice` must
be a single-line string on stdout that is exactly one JSON document; an
embedded newline in the string, or two JSON documents each carrying their
own `notice`, is **undefined** rendering (it may show as one prefixed line
followed by a bare, unprefixed continuation line) — a producer author should
avoid both. `{"notice": ""}` is a valid string and renders nothing (an empty
`notice: ` line is never printed). None of the following are errors, and
none render a notice line: an absent `notice` field, a `notice` present but
not a string (e.g. `{"notice": 42}` — `jq`'s type guard drops it exactly
like an absent field), or stdout that does not parse as a JSON object at
all.

## Kernel-shipped `tokens` producer's transcript scope (temperloop#983)

The kernel's own `tokens` producer (`workflows/scripts/report-producers/
tokens`, exec'd via the `.temperloop/report.d/tokens` locator shim — see
"Pricing table & dollar framing" below for where it's introduced) reads
Claude Code's own per-project transcript directories under
`$SPEND_TRANSCRIPT_ROOT` (default `$HOME/.claude/projects`, a layer-5
tracked-repo setting resolved from `workflows/scripts/build/
build.config.sh`). By **default** it scopes that read to the invoking
checkout's own project directory rather than every project this operator
has ever run Claude Code against on this machine — see that script's own
header for the full derivation and its degrade paths (a repo-scoped
directory that hasn't recorded anything yet, cwd not being a git working
tree). A checkout whose path exceeds Claude Code's own 200-character
project-name cap — which Claude Code stores under a truncated name plus an
unreproducible hash suffix — is resolved by matching that 200-character
prefix (temperloop#995), and degrades to machine-wide only when the prefix
matches zero directories or more than one. Whichever corpus a given run
actually walks, the `notice` field above states that scope in plain
language.

**Overriding the scope.** `SPEND_TRANSCRIPT_ROOT` is an ordinary layer-2
override (`docs/config-precedence.md`'s six-layer ladder): export it to a
different path and the producer treats that as an explicit choice and skips
repo-scoping entirely, falling back to walking whatever root you gave it.
The one documented exception is exporting it to **exactly** its own default
value (`$HOME/.claude/projects`) — that is indistinguishable from never
having touched it (every `/build` session inherits precisely that value
merely by sourcing `build.config.sh` at its own Step 0), so the producer
treats it as the un-set case and repo-scopes anyway. An operator who wants
to force the literal machine-wide default has no separate opt-out flag
today; they can still get it by pointing `SPEND_TRANSCRIPT_ROOT` at any
value that differs textually from the default but resolves to the same
directory (a trailing slash, a symlink), or by editing
`workflows/scripts/report-producers/tokens` directly.

## Kernel-shipped `model-comparison` producer (temperloop#1261)

The kernel carries a **second** producer implementation,
`workflows/scripts/report-producers/model-comparison` (epic temperloop#1225,
the model comparison harness). It rolls a baseline arm and a candidate arm of
scored replay records into the comparison a human reads to make a
model-routing decision. Four things about it are contract-relevant here,
because each is a place the generic drop-in rules above are **narrower** than
what this producer does to itself:

1. **The kernel ships NO `.temperloop/report.d/model-comparison` shim** —
   deliberately, unlike `tokens`, which does ship one. ADR 0027 ("inert by
   design") keeps the whole comparison half present-but-doing-nothing until an
   operator deliberately invokes it, and a committed shim would arm the
   producer on every `temperloop report` in every install. An adopter who
   wants it writes the same one-file locator + `exec` shim `tokens` uses, into
   their own `.temperloop/report.d/`. Until they do, `report` never runs it.
2. **It constrains its own stdout to exactly one JSON object**, and is
   therefore the second (see "`notice` field" above) legitimate user of the
   `notice` channel. That constraint is **self-imposed**: this contract does
   not read or interpret any field of it. `report.sh` echoes the object
   verbatim and renders its `notice` line, exactly as it would for any
   producer — there is no `model-comparison`-specific parsing anywhere in
   `report.sh`, and adding some is not implied by this section.
3. **It never emits `tokens_spent` or `by_model`.** Those two keys stay scoped
   to the producer literally named `tokens` (see "Reserved top-level keys"),
   and the headline spend figure remains ADR 0020's — this producer adds new
   files and new keys only, and changes nothing about the existing slot
   format. Its own cost figures are **cost-weighted token counts**, explicitly
   labelled as neither metered dollars nor a subscription-usage share.
4. **Its degradation line is the same channel, with its own name**: a single
   `skipped -- model-comparison: <reason>` line at **exit 0**, and no JSON at
   all. That asymmetry is load-bearing: a degraded run therefore cannot carry
   a `winner` or a cost figure, because there is no object for one to hide in.
   Note this producer's degradation is a *self-declared* skip line, so
   `report.sh`'s own per-producer skip channel is the same one — the
   `tokens`-only "stdout did not parse" line above does not apply to it, since
   nothing outside the producer parses its stdout at all.

It reads the two arms from `MODEL_COMPARISON_REPORT_RECORDS_DIR` (default
`.temperloop/model-comparison/`, resolved against the target repo) and reads
the pricing table on the **same two-tier override order** the next section
describes — a user `.temperloop/pricing.json` overriding the kernel-shipped
default table outright, never merged per-key. It composes
`workflows/scripts/model-comparison/stats.sh` for every statistic and
`.../score.sh aggregate` for the quality/compatibility split rather than
computing either itself. Egress: none — the same local-file-reads-plus-`jq`
posture as `tokens`, and it is covered by the same
`check-producer-egress.sh` directory scan.

## Pricing table & dollar framing (foundation#882, temperloop#1251)

The tokens headline can render a **directional dollar estimate** whenever
the `tokens` producer emits a `by_model` breakdown (above). Pricing itself
no longer requires anything user-supplied — as of temperloop#1251 the kernel
ships its own dated default price table, so the dollar figure is never
gated behind hand-authored config.

**Two consumers, one override order (temperloop#1261).** The two tiers below
were written for `report.sh`'s own tokens headline, and that remains the
headline's sole owner. They are now also read, unchanged and in the same
precedence, by the `model-comparison` producer above for its optional
directional dollar overlay. The override order, the "never merged per-key"
rule, and the dated-staleness labelling requirement are therefore a **shared
contract**, not a `report.sh` implementation detail: a change to either tier
changes both surfaces.

Two tiers feed the figure, in **override order** (highest precedence
first):

1. a user-supplied pricing table at `.temperloop/pricing.json` — a single
   JSON object mapping each model id to its **USD-per-million-tokens list
   price**, e.g. `{"claude-opus-4-8": 18.00, "claude-sonnet-5": 5.40}`. When
   this file is present it **overrides the default table outright, never
   merges with it per-key**: even if the user's table names only one of two
   `by_model` models, the other is **not** back-filled from the default
   table — it is named and excluded exactly as it would be with no default
   table in play at all (see "Every degradation" below). A partial user
   file that silently blended in kernel defaults for the keys it omitted
   would defeat the point of writing an override.
2. absent that, the kernel-shipped **default price table** at
   `workflows/scripts/config/default-pricing.json` — a
   `{as_of: "YYYY-MM-DD", prices: {model: $/Mtok}}` object, hand-
   transcribed from public list prices and refreshed only by hand-editing
   the file in an upstream PR (no regeneration script), same discipline as
   the user-supplied table above. Every dollar line this tier drives carries **both** the
   table's own `as_of` date and an explicit staleness label (`DEFAULT PRICE
   TABLE dated <as_of>` plus a `STALENESS:` line naming it as a committed
   snapshot, not the adopter's own prices) — a stranger reading the output
   is never left thinking the figure is their own configured number.

`report.sh` then multiplies each attributed model's tokens by its list price
(`tokens × price ÷ 1,000,000`), sums the priced models, and prints a
`~$<total> directional` line under the same **DIRECTIONAL** label as the
tokens headline, naming the count of priced models and **excluding** (by
name) any `by_model` model with no matching price in whichever table is in
effect. Both tables are **directional, hand-edited** tables: neither is ever
a live pricing-API read, neither is recalculated at runtime — the
producer-egress lint covers this seam and both table reads are **local file
reads only, no network**. The pricing table used to be **absent by
default** (the kernel shipped no prices, so a stranger opted in by writing
their own table); that is no longer true — the kernel now ships a default
table out of the box, and a stranger instead opts *out* of it by never
writing `.temperloop/pricing.json`, or opts into their *own* current
numbers by writing one, which always wins per the override order above.
(This section used to add "just as it ships no `tokens` producer" — no
longer true as of temperloop#958: the kernel repo now carries its own
`tokens` producer, `workflows/scripts/report-producers/tokens`, a
transcript-derived spend reader wrapping
`workflows/scripts/pipeline-spend-report.sh`; `.temperloop/report.d/tokens`
is the locator shim that finds the installed kernel and `exec`s that
producer. That changes nothing here — the producer emits `by_model` in
DIRECTIONAL cost-weighted units, and pricing remains the separate,
hand-written half, now two-tiered.)

Every degradation is one legible line, never an error: **no** `by_model` →
no dollar line; `by_model` present, **no** `.temperloop/pricing.json`, and
the default table itself missing or malformed (a broken/incomplete kernel
checkout — no `prices` object, no `as_of` string) → the pre-#1251 one-line
"add `.temperloop/pricing.json`" nudge, now naming the default table as
unavailable too; `by_model` present, **no** `.temperloop/pricing.json`, a
well-formed default table but **zero** matching models → a "no model in the
default price table (dated `<as_of>`) matched" note; a `.temperloop/
pricing.json` that is **not a JSON object** (malformed, or a valid
array/number/string/`null`) → a "not a `{model: $/Mtok}` object" note; a
`.temperloop/pricing.json` object that matches **none** of the `by_model`
models → a "no model matched" note (the user-table wording, distinct from
the default-table one above — the two never conflate which table was in
effect). The kernel-tier headline and the tokens/item line are unchanged in
every case.

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
  **also** emits `by_model`, the headline additionally renders a directional
  `~$<total>` dollar line, priced from a user `.temperloop/pricing.json`
  override when present, else the kernel-shipped default price table (see
  "Pricing table & dollar framing" above).
- **Else**: the headline is the kernel-tier numbers alone -- the
  merged-items/day delta plus the median-time-to-merge delta. When the
  `tokens` producer *ran* (exit 0) but its stdout failed that parse, the
  overlay-tier block additionally carries the explicit `skipped -- tokens:
  stdout did not parse ...` line described under "Overlay drop-in contract"
  above, so the fallback is never silent.

## Non-goals of this seam (deliberately out of scope)

- **No opinionated verdict**, mirroring `baseline_snapshot.contract.md` --
  `report` prints what changed, not whether that's good or bad.
- **No precise cost accounting.** The tokens-based headline — and the
  optional `~$<total>` dollar line derived from `by_model` × a user-supplied
  `.temperloop/pricing.json` — are explicitly labeled **directional**.
  `report.sh` has no opinion on how a `tokens` producer derives its own
  numbers, only that `tokens_spent` be a number and (optionally) `by_model`
  an object; the pricing table is a hand-edited, user-supplied,
  never-runtime-recalculated list-price map — a directional posture. This is a real-dollar *framing*,
  not an accounting ledger.
- **No new baseline data.** `report.sh` computes nothing that isn't already
  in `.temperloop/baseline.jsonl` or a drop-in's own stdout -- it is a pure
  renderer (`--refresh` is the one exception, and even then the actual `gh`
  work is fully delegated to `baseline-snapshot.sh`).
