---
description: Nightly unattended tidy pass — drain the session-stub backlog in Sessions/_inbox/ (extract learnings to vault + auto-memory, generate tasks in Things inbox, archive processed stubs to foundation/meta/sessions/archive/), snapshot the vault, and park anything needing human judgment to the pipeline surfaces /check-in disposes.
---

You are running the **tidy** command. Goal: turn raw session transcripts in `Sessions/_inbox/` into durable artifacts (decisions, memories, patterns, tasks), archive the stub, and snapshot the vault.

**This command runs nightly, unattended** (a launchd/cron `claude -p "/tidy"` invocation, or on demand). It has **no live operator**, so it **never** blocks on an `AskUserQuestion` and never asks a clarifying question: it extracts liberally and **parks anything needing human judgment on a durable surface** that `/check-in` disposes at the next daily review. Those are the pipeline surfaces under `Context/pipeline - *` (pending-decisions, proposed-supersessions, candidate-tells, vault-hygiene) plus the **sensitivity flags** surface (Step 2). `/tidy` is the **drain-proposes** half; `/check-in` is the **operator-disposes** half — this command writes surfaces, never mutates their `Status`.

**Operating principles** (honor the knowledge store's `Projects/foundation/workflows/daily-planning/README.md` note — document paths throughout this file, e.g. `Sessions/_inbox/`, `Decisions/`, `Context/pipeline - pending decisions.md`, are relative to **the knowledge store root**, resolved per `workflows/scripts/lib/knowledge_store.contract.md`):
- Write small, write in parallel — batch independent vault writes and Things writes.
- Use the Obsidian MCP for vault reads/writes (the agent-plane transport stays on Obsidian per the contract's Obsidian-mode note — `search_vault_smart` below is that same path); use the Things MCP for task creation.
- Never duplicate work the live session already captured — check existence before writing.

## Live/Drain pairings

Every step in this command has a real-time counterpart that runs during the live session — the drain is the backstop, not the primary defense. **This table is the single source of truth for KERNEL live/drain pairings** — pairs generic enough that a stranger's kernel-only checkout needs them backstopped too. A composed (overlay) checkout carries a second table, the **overlay extension**, at `claude/live-drain-registry.overlay.md`, for pairs that reference Travis-personal (vault-backed) rules and have no meaning in a standalone kernel checkout; `workflows/scripts/validate-live-drain.sh` unions the two when the overlay file is present, and validates this kernel table alone otherwise. `[[Patterns/Live-Drain pairing]]` and `claude/CLAUDE.md` § Live/Drain pairing point here. The validator parses both tables in CI (the `checks` gate) — it fails the build if any pair, in either table, is **half-present** (a live anchor present without its drain anchor, or vice versa). When you add a pair: kernel machinery (board/build/funnel/harness-generic) → a row here, in the same change as the rule; a personal/vault-backed rule → a row in the overlay extension table instead.

**Cell grammar** (so the validator can parse it): every checkable token is `backticked`. The **Live location** cell is `` `<source>` § `<anchor>`… `` where `<source>` is a file (`claude/CLAUDE.md` = global config, `foundation/CLAUDE.md` = this repo's root CLAUDE.md, `stageFind/CLAUDE.md` = the consuming repo) or the literal `` `system-prompt` `` (unverifiable — the validator checks only the drain half); each `` `<anchor>` `` is the exact heading or bold-label text to find in that source. The **Drain backstop** cell lists the exact `### <heading>` anchors in this file's Step 3. Same grammar in the overlay extension table.

| Live rule | Live location | Drain backstop |
|---|---|---|
| Feedback / project / user memory | `system-prompt` § auto memory | `Feedback memories`, `Project memories`, `User memories` |
| Defect capture-at-source | `claude/CLAUDE.md` § `Capture at source` | `Unfiled defects` |
| Stale board-claim sweep | `claude/CLAUDE.md` § `Board hygiene is part of the gate` | `Stale board claims` |
| Answered decision issues | `system-prompt` § `decision_sink_ask` | `Answered decisions` |
| Kernel-vs-overlay classification | `claude/CLAUDE.md` § `Kernel vs overlay routing rule` | `Kernel-candidate learnings` |

## Step 0 — Verify environment and acquire the drain lock

1. Confirm `mcp__obsidian__*` is loaded — it is **required** (the vault is the whole point); if missing, surface that and stop. Confirm `mcp__things__*` is loaded too, but treat it as **optional under unattended operation**: on a headless nightly host the Things app may not be running, and its absence must **not** abort the vault extraction + archive + snapshot. If Things is missing, **degrade** — skip Step 4 (task generation) and any Things dedup/search, note `Things unavailable — task generation skipped` in the Step 6 summary, and continue.
2. List `Sessions/_inbox/` via `mcp__obsidian__list_vault_files`. **Only `*.md` files are stubs** — ignore any `.drain.lock.*` entries here and everywhere below. If there are no `*.md` stubs, say so in one line and exit (don't acquire the lock — there's nothing to race over).
3. **Source the batch-pipeline config (best-effort).** `source workflows/scripts/build/build.config.sh` (bare repo-relative, the kernel's Step-0 config-sourcing convention — `~/.claude/CLAUDE.md` § Prose-resident knob convention). This pulls the drain-lock timing knobs (`TIDY_SYNC_WAIT`, `TIDY_LOCK_STALE_AFTER`) into scope, with any pre-set env value still overriding, before step 4 below uses them. If the file isn't found, proceed — 4c/4d keep their inline `${VAR:-default}` fallbacks.
4. **Acquire the cross-machine drain lock.** Multiple machines share `Sessions/_inbox/` via Obsidian Sync, so two `/tidy` runs (e.g. evening rituals on two machines within a minute of each other) can process the same backlog at once and double-create Things tasks (the Step 4 dedup is search-then-add, not atomic across concurrent runs). Sync is eventually-consistent (~seconds to a minute), so a plain lockfile is racy — the protocol is **acquire → wait for Sync → elect**, earliest timestamp wins:
   a. Get identity (Bash): `EPOCH=$(date +%s)`, `HOST=$(hostname -s)`.
   b. Write `Sessions/_inbox/.drain.lock.<HOST>` containing one line `<EPOCH> <HOST> <this session-id>` (via `mcp__obsidian-builtin__vault_write`). **One file per host** — never a single shared lock file (concurrent writers would clobber it).
   c. Wait `TIDY_SYNC_WAIT` to let Sync propagate every host's lock in both directions. **Do not run a foreground `sleep "$TIDY_SYNC_WAIT"` (Bash) — the harness blocks foreground sleeps.** Instead wait via a backgrounded sleep: run `sleep "$TIDY_SYNC_WAIT"` with `run_in_background: true` and let it re-invoke you on exit (or, equivalently, poll with `Monitor` on an until-loop with a `TIDY_SYNC_WAIT` deadline). *(Override: if the user passed `--force-now`, skip the wait + election and proceed — a single-machine escape hatch for when you know no other host is draining.)*
   d. Re-list `_inbox/` and read every `.drain.lock.*` file. **Discard and delete any lock whose `<EPOCH>` is older than `TIDY_LOCK_STALE_AFTER`** (a crashed prior run — never let it block forever). Among the rest, the winner is the **lowest `<EPOCH>`**; tie-break on the lexicographically smallest `<HOST>`.
   e. If **my** lock is the winner → proceed to Step 1. Otherwise → delete my own `.drain.lock.<HOST>` and exit with one line: "another host (`<winner>`) is draining — yielding."

## Step 1 — Scan each stub (consume the scan report)

**Do not load the full transcript.** The scanner pre-processes each stub into a compact JSON report (~2-3k tokens vs. ~18k for the raw transcript). Run it first; the report is your primary input. For each file in `_inbox/`:

1. Derive the stub's local filesystem path — a **raw on-disk path outside the knowledge_store seam**: `scan_stub.py` reads the file directly from disk rather than through `ks_read`/MCP, because the obsidian backend's REST API has no filesystem-root semantics to route a disk read through (per `workflows/scripts/lib/knowledge_store.contract.md` § the obsidian backend's root-mapping note). Resolves under the knowledge store root, e.g. `$KNOWLEDGE_STORE_ROOT/Sessions/_inbox/<filename>.md`.
2. Run the scanner, capturing its JSON output:
   ```
   python3 ~/dev/foundation/workflows/scripts/drain/scan_stub.py \
     $KNOWLEDGE_STORE_ROOT/Sessions/_inbox/<filename>.md
   ```
   The scanner emits a single JSON object to stdout (schema: `workflows/scripts/drain/scan-report-schema.md`). Parse it and hold it in memory — this is the **scan report** for this stub.
3. **Read the scan report, not the transcript.** Your extraction input is:
   - `report.stub` — session id, project, date for provenance attribution.
   - `report.lexicon_matches[]` — pre-matched extraction tells with category, matched line, and ±1 context. Step 3 adjudicates these — they are candidates, not confirmed extractions.
   - `report.user_turns[]` — digest of non-excluded user turns (truncated at 500 chars each). Skim for novel signal the lexicon can't catch (new phrasing, implicit commitments, preference shifts).
   - `report.tool_events` — structured AskUserQuestion Q/A pairs, tool errors, user interrupts, and `capture.sh` calls. Step 3 uses these as supporting evidence.
4. **Wider transcript access is the exception, not the rule.** Only fetch a wider window from the raw `.jsonl` (via `Read` on the path in the stub frontmatter's `transcript:` field) or from the stub itself (via `mcp__obsidian__get_vault_file`) when a specific `lexicon_match` or `user_turns` entry is **genuinely ambiguous** — i.e., you can't tell from the match + ±1 context whether it's a real extraction candidate. When you do, read only the surrounding turns, not the full file.

## Step 2 — Sensitivity scan (mandatory)

Before extracting anything, scan each stub for:
- API keys, bearer tokens, OAuth secrets (e.g. long hex strings, `Bearer <hex>`, `sk-...`, `ghp_...`)
- Plaintext passwords
- Personal info that doesn't belong in a vault (SSN, full credit card numbers)

If found: **do not** copy the secret into any extracted artifact. Because this run is unattended, the Step 6 summary alone would never reach the operator — so **append one `### open` entry to the sensitivity-flags surface** (`Context/pipeline - sensitivity flags.md` in the knowledge store) via `mcp__obsidian-builtin__vault_append`, recording the stub filename, the *kind* of secret (never the secret value itself), and its approximate location, with `Status: open`. Create the note with a one-line header if it doesn't exist. Also note the count in the Step 6 summary. `/check-in`'s `## Sensitivity flags review` section disposes it (redact the source stub, or dismiss as a false positive). Continue processing the rest.

## Step 3 — Extract learnings

**Input: the scan report from Step 1.** Adjudicate `report.lexicon_matches[]` (decide which flagged tells are real extractions vs. noise or already-captured live) and skim `report.user_turns[]` for novel signal the lexicon couldn't catch. Run the **Tool-event structural passes** below first — they reach the insight class no text phrase can surface — then run the tell-based extractors that follow.

**Adjudication rule for `lexicon_matches`.** Each match is a candidate. For each:
- Read the `match.line` and `match.context` (±1 lines). If clearly a real signal (an unfiled defect, a decision, friction, etc.) → extract. If clearly noise (incidental phrase, confirmed-already-live) → skip. If ambiguous → fetch the wider transcript window (Step 1.4) and then decide. Track your adjudication in the summary so the step count reflects actual extractions, not raw match count.

> **Canonical tell source.** The phrases and patterns used to identify insight-bearing moments in transcripts (friction slugs, defect language, deferral markers, self-critique, user pushback, etc.) are maintained as a structured data file: `workflows/scripts/drain/lexicon.tsv` in the foundation repo. That file is the **single source of truth** for extraction tells; `report.lexicon_matches[]` is its pre-applied output — the inline examples in the extractor steps below are illustrative, not exhaustive.

### Provenance tagging

**Every extraction produced in Step 3 is tagged with its provenance** — how it was found. This tag is carried on every findings record (see § Findings records below) and drives the candidate-tells accumulation.

Two provenance values:

- **`lexicon-hit`** — the extraction was triggered by a tell in `report.lexicon_matches[]`. Record the specific tell in `sub_method` (the `match.tell` field that fired).
- **`model-skim`** — the extraction was found by the model reading `report.user_turns[]` with no matching lexicon tell. `sub_method` is `null`.

**How to assign provenance.** For each extraction you decide to accept:
1. Check whether the extraction source appears in `report.lexicon_matches[]` — specifically, does any entry's `match.line` or `match.context` overlap with the user turn or phrase you are extracting from?
2. If yes → `lexicon-hit`; set `sub_method` to that entry's `tell` field.
3. If no → `model-skim`; the model caught it from `user_turns[]` alone.

Model-skim extractions ARE the lexicon's measured misses. Tag them carefully — they are what drives the lexicon's growth.

### Tool-event structural passes

`report.tool_events` carries the insight class no text phrase can reach — the densest signal the lexicon never sees. Walk each sub-array before the tell-based extractors below; each class routes into an existing extractor rather than a new one.

#### AskUserQuestion answers → Feedback memories / Decisions

Walk `report.tool_events.ask_user_questions[]`. For each entry:

- **Skip unanswered** (`answer: null`) — no signal to extract (though an unanswered question on an unattended run is a pending-decisions candidate; see § Pending decisions surface below).
- **Read the answer.** A Q/A pair captures the user's live judgment — the answer carries the strongest feedback and decision signal in the whole transcript, and it never appears in `user_turns[]` (tool results are outside the stub body).
- **Route by content:**
  - An answer that expresses a **preference, correction, or behavioral rule** (e.g. "file a bug to track it", "don't do that again", "yes that's the right approach") → **Feedback memories** extractor. Treat it exactly as a user correction or confirmation: save to auto-memory under `feedback_<topic>.md`.
  - An answer that makes a **project or architectural commitment** (e.g. "go with option B", "we'll use X for this") → **Decisions** extractor. Treat it as a decision datum with provenance from the Q/A pair.
  - An answer that reveals a **user preference or context** (role, workflow, tool habits) → **User memories** extractor.
  - Ambiguous — apply the same heuristic as `lexicon_matches` adjudication; fetch wider context from the stub if needed.
- Skip entries where the live session already captured the answer (check Decisions/memories for the same content before writing).

#### tool errors (hard + soft) → Tooling friction / Mistakes / Unfiled defects

Walk `report.tool_events.errors[]`. Each entry carries `kind`: **`hard`** (the tool result was flagged `is_error: true`) or **`soft`** (foundation #444 — `is_error` false/absent, but the content carried an error signature like `jq: error`, `Traceback`, `command not found`, `fatal:`; the class where a Bash command emits a downstream tool's error to stdout yet exits 0, so the harness never flagged it). For each entry:

- A **hard** error is a tool failure: MCP param misuse, a missing file path, an unexpected API response, a permission denial, or an auto-classifier rejection.
- A **soft** error is the higher-signal class for **undetected defects** — a tool that *silently* failed. Treat a recurring soft failure (the same signature firing more than once in the session) as an **Unfiled-defect candidate** (route to § Unfiled defects, cross-referencing `capture_calls[]` first): it is exactly the worked-around-but-never-filed pattern #444 exists to catch (the BOARD_ITEMS_JSON `jq` parse error of #443 was three soft failures). A one-off soft failure that the session clearly handled is friction, not a defect.
- **Route to § Tooling friction** when the error reflects an avoidable step — a wrong tool contract, a malformed input, a retry loop the session could have avoided. Category hint: `tool-misuse` or `probe-after-not-before`.
- **Route to § Mistakes** (vault `Mistakes/`) when the error reflects a real pitfall worth recording — a pattern that failed, an MCP tool that misfires on certain inputs, a harness behavior that is non-obvious. Applies the vault provenance schema.
- An error that is clearly environmental (network timeout, a transient file-not-found on a race) is not a pitfall or friction event — skip it.
- Default to silence: most errors are transient; only extract errors that are actionable or recurrence candidates.

#### `[Request interrupted by user for tool use]` → Feedback memories

Walk `report.tool_events.interrupts[]`. Each interrupt is the single most reliable user-rejection signal in the transcript — the user stopped Claude mid-tool, which is always an implicit "not that" feedback moment.

- Route every interrupt to the **Feedback memories** extractor as a user correction.
- To reconstruct what was being rejected, find the surrounding tool_use in the raw `.jsonl` near `location` (or skim `report.user_turns[]` and `report.lexicon_matches[]` for context from the same turn range).
- Save to auto-memory under `feedback_<topic>.md` (type: feedback). Body: what Claude was doing, what the interrupt says about the user's preference.
- If the surrounding context is genuinely ambiguous (no nearby tool call visible from the scan report), skip rather than guess.

#### `capture_calls` → Unfiled defects dedup

Walk `report.tool_events.capture_calls[]`. Each entry means `capture.sh` was invoked during the session — the defect WAS filed at source.

- **These are dedup signals for § Unfiled defects**, not new extractions. When the Unfiled defects pass below identifies a candidate defect, cross-reference `capture_calls[]` first: if the defect's keywords appear in any `capture_calls[].command`, the live "Capture at source" rule fired and the defect is already on the board — skip it, do not re-file.
- Do not route `capture_calls` to Decisions, Feedback, or Mistakes — they are evidence of completed live filing, not a new insight.
- Surface the count in the Step 6 summary (`capture_calls seen: N`) so the operator can confirm live capture is firing as expected.

For each stub, identify the following **only when present and not already captured live**:

> **Vault provenance schema (note-level).** All vault writes for `Decisions/`, `Patterns/`, `Mistakes/`, and `Context/` use this frontmatter + footer:
>
> ```yaml
> ---
> tags: [<kind>, project/<name>, ...]   # kind = decision | pattern | mistake | context
> date: <YYYY-MM-DD from stub frontmatter>
> source_kind: claude-stamped
> source_session: <stub filename without `.md`>
> source_model: <stub `model:` field — the analyzed session's model; omit if stub has none>
> extracted_by_model: <your current model ID — the model running this drain>
> last_verified: <same as date>
> ---
> ```
>
> ```markdown
> ## Source
> [[Sessions/<stub filename without `.md`>]] — <one-line context on which session moment produced this>.
> ```
>
> Reference: the knowledge store's `Decisions/foundation - Vault provenance schema (note-level).md` note. Apply on every newly-created note in this step. (Auto-memory under `~/.claude/projects/.../memory/` keeps its own format and is not affected.)
>
> **Model provenance — subject vs. analyst.** `source_model` is the **subject**: the model whose behavior/work the note is *about*. In a drain it is **not** you — it is the analyzed session's model, read from the stub's `model:` frontmatter field (written by the SessionEnd hook from the transcript's distinct `.message.model` set). `extracted_by_model` is the **analyst**: your own current model ID, the model running this drain. So a Mistake is attributed to the model that *made* it and a Pattern to the model that *did* it, while the extraction itself is credited to the drain runner. **If the stub carries no `model:` field** (older stub, pre-dating this hook change), **omit `source_model`** — never substitute your own drain model for it; absence reads as "subject model unknown," not "drained by X."

### Decisions
Architectural, product, or process choices with rationale.
- Check `Decisions/` for an existing note covering the same decision (filename pattern: `<project> - <short title>.md`). If present, skip the *creation* path — live capture worked — but still run the **provenance audit** below.
- If missing, write `Decisions/<project> - <short title>.md` with the vault provenance schema frontmatter (`tags: [decision, project/<name>]`) and body covering: **what** was decided, **why**, **alternatives considered**, **trade-off accepted**. Cross-link to superseded decisions via `[[wikilinks]]`. End with the `## Source` footer.

#### Provenance audit (existing decisions)

For every `Decisions/<project> - *.md` mentioned by name in the stub, fetch its frontmatter via `mcp__obsidian__get_vault_file`. If any of `date`, `source_kind`, `source_session`, or `last_verified` is missing, OR the `## Source` footer is absent, the file was captured live without the provenance schema and needs backfilling.

`source_model` is **conditionally** part of this audit: only backfill it when the stub carries a `model:` field to source it from. A claude-stamped note missing `source_model` whose stub *also* has no `model:` is **not** a gap — treat it as "predates model provenance" (forward-only, exactly like notes that predate the whole schema). Never invent a `source_model`, and never substitute the drain runner's model for the missing subject.

Decide authorship from the stub:

- **Clear authorship** — the stub contains assistant-turn phrases like "wrote `Decisions/X.md`", "captured to vault", "writing the Decision now", "I'll create the decision file", or a tool-call result showing the file was created. Backfill in place via `mcp__obsidian__patch_vault_file`:
  - Frontmatter: set `date` and `last_verified` to the stub's date, `source_kind: claude-stamped`, `source_session: <stub filename without .md>`, and — only if the stub has a `model:` field — `source_model: <stub model>`. Preserve existing `tags` and any other fields.
  - Footer: append `## Source\n[[Sessions/<stub filename without .md>]] — <one-line context from the stub on which moment produced this decision>.`
- **Ambiguous authorship** — the decision is referenced but the stub doesn't claim it (e.g., it just links `[[stageFind - X]]` while discussing something else). Do **not** backfill. List the file in the summary block under `Provenance gaps` so the user can attribute it manually.

Track each backfilled file and each gap separately for the summary.

#### Contradiction detection (cross-session supersession proposer)

**A drain-internal detector**, not a live/drain pair. The live rule in `claude/CLAUDE.md` § Decision capture asks an author to link a supersession *they already recognized* at bank time ("If a decision overturns or supersedes a prior one, link the prior note via `[[wikilink]]` and note the supersession"). This pass finds the *unrecognized* ones — a drain (or live `Decisions/` bank) lands a new/amended decision that contradicts an earlier note **without anyone noticing**, the "stale-assumption" error class no grep tell can surface, because the earlier claim only becomes wrong in light of the later one (governing spike: `Decisions/foundation - Cross-session contradiction detection (spike verdict)`). It is therefore **drain-internal** like the § Recurrence → promotion pass below — it has **no live anchor it backstops, no Live/Drain registry row, and needs no `validate-live-drain.sh` change** (rationale + the superseded "registry row mandatory" cost line: the linked spike note). It **proposes** supersessions; it never edits a banked note.

**Run this for each `Decisions/<project> - *.md` note that this drain run banked new OR amended** (the creation path above, and any note the provenance audit touched). Skip notes only re-read but not changed.

For each such note `D_new` (project `P`):

1. **Retrieve the near-neighbours — do not scan the corpus.** Run `mcp__obsidian__search_vault_smart` on `D_new`'s claim text (its `what was decided` / `## Source` body, not the frontmatter), with `folders: ["Decisions"]` and a small `limit` (~5). This returns the semantically-nearest prior decisions — the only set a contradiction could plausibly live in. (`Decisions/` is curated vault content, which Smart Connections **does** embed — the "no semantic search" rule is scoped to raw transcripts in `meta/sessions/archive/`, so no new index is needed.)
2. **Constrain scope to the same project.** Drop any neighbour not tagged `project/<P>` — cross-project neighbours are noise. Also drop `D_new` itself and any note `D_new` already `[[wikilinks]]` as superseded (it was handled live).
3. **One bounded judgment per surviving neighbour `D_prior`** (≤5 total). Ask yourself a single yes/no: *does `D_new` assert something that **empirically contradicts or supersedes** `D_prior`?* Demand a genuine X-vs-not-X about the **same referent** (one note says the cascade handles it, the other empirically disproves that). **Reject mere refinement/elaboration** — most new decisions narrow or extend a prior one without contradicting it; those are not supersessions. Apply a similarity floor: if a neighbour is only loosely related (different referent), skip the judgment entirely.
4. **Surface a "yes" — never auto-edit.** For each judged contradiction, append one `### open` entry to the proposed-supersessions surface (`Context/pipeline - proposed supersessions.md` in the knowledge store) via `mcp__obsidian-builtin__vault_append` (entry format defined in that note's header). Record: `D_new`, `D_prior`, the supersession **direction** (which note wins), and a one-line statement of the empirical contradiction. This is a **companion** to the unattended pending-decisions surface — a separate file so its append stream never interleaves with that file's five `batch-at-ritual` EOF writers — read by the same `check-in` ritual (no new review ritual). `check-in` reads these and, on the operator's confirm, hand-adds the `[[wikilink]]` + supersession line to the notes — the convention stays human-owned.

**Default to silence + liberal judge.** Most drains bank no decision, and most banked decisions contradict nothing — surface nothing in that case. Because the output is **proposal-only** (a false positive costs the operator one glance at `check-in` and a dismiss; it never mutates a note), bias the judge toward flagging when genuinely uncertain — the asymmetry (cheap FP, expensive missed contradiction) is the same logic as the dropped-bug capture net. If `search_vault_smart` is unavailable, skip this pass with a one-line note in the summary (do not fall back to a corpus scan).

### Feedback memories
User corrections OR user confirmations of non-obvious approaches. (Both directions matter — see auto-memory rules.)
- Save to the project's auto-memory directory under `feedback_<topic>.md` with `type: feedback`. Body: rule, then `**Why:**` line, then `**How to apply:**` line.
- Add an index entry in `MEMORY.md`.
- Skip if a duplicate exists.

### Project memories
Who is doing what, why, by when. Convert relative dates to absolute.
- Save to auto-memory under `project_<topic>.md`, type `project`.

### User memories
Role, preferences, knowledge revealed. Save to auto-memory under `user_<topic>.md`, type `user`. Skip if redundant with existing.

### Patterns
Reusable approaches that worked. Save to vault `Patterns/<title>.md` with the vault provenance schema frontmatter (`tags: [pattern, project/<name>, ...]`) and the `## Source` footer. Skip if a pattern with the same title already exists.

### Mistakes
Pitfalls, failure modes, things that broke. Save to vault `Mistakes/<title>.md` with the vault provenance schema frontmatter (`tags: [mistake, project/<name>]`) and the `## Source` footer. Skip duplicates.

### Kernel-candidate learnings

**Backstop for `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule** (only when this checkout carries that file — skip this pass entirely otherwise, no note, no tag). The live rule asks whoever routes a new rule/decision to apply the **stranger test** at capture time; this pass catches a `Decisions/` / `Patterns/` / `Mistakes/` note this run **banked or amended** (the creation and provenance-audit paths above) that the live session captured without running that test.

For each such note, apply the stranger test: would a stranger's kernel-only install need this for the kernel machinery (board adapter, build/sweep pipeline, install/doctor, branch/PR policy) to work correctly? If yes and the note isn't already tagged `kernel-candidate`, add that tag to its frontmatter `tags:` list via `mcp__obsidian__patch_vault_file` (a targeted `tags:` field patch, not a rewrite) — this flags it for eventual upstream contribution once the kernel repo exists as a live checkout. Never remove an existing `kernel-candidate` tag, and never tag a note the stranger test doesn't clearly pass — **default to `overlay`** (no tag), matching `/triage`'s Step 2.8 default (a missed kernel tag costs nothing; a wrongly-added one misroutes a personal/org-specific note).

**Default to silence.** Skip entirely on a checkout with no `claude/CLAUDE.kernel.md`. Most notes stay untagged.

### Self-correction moments → Mistakes / Patterns + recurring-tell promotion

**A drain-internal detector** (like § Contradiction detection and § Recurrence → promotion below) — it surfaces a class the live rules don't capture and has **no live anchor it backstops, no Live/Drain registry row, and needs no `validate-live-drain.sh` change**. The signal is a **mid-session self-correction**: the assistant catching itself going the wrong way — a "that didn't go right" or "I'm thinking about this wrong" / "wrong approach" / "let me reconsider" / "I had this backwards" realization narrated mid-task. This is the moment *before* a Mistake fully crystallises — the model noticed its own error in flight — and it is almost always **assistant-narrated**, so the user-only lexicon never saw it. The `self-correction` tells in `workflows/scripts/drain/lexicon-assistant.tsv` (foundation #501) are scanned against **assistant** turns and pre-matched into `report.lexicon_matches[]` with `category: "self-correction"` and `role: "assistant"`.

**Adjudicate `report.lexicon_matches[]` for `category: "self-correction"` matches.** For each:

1. **Read the match + ±1 context.** A genuine self-correction is a real reasoning reversal — the model recognised a wrong assumption, layer, or approach and changed course. Skip an incidental phrase (quoting the rule, a hypothetical) — apply the same liberal-but-not-noisy judgment as the `lexicon_matches` adjudication rule. Also skim `report.user_turns[]` for self-correction language the lexicon missed (a user-flagged "you're thinking about this wrong" is a **Feedback memory**, not this pass — route it there).
2. **Route the accepted realization:**
   - If the self-correction names a **reusable recovery** (how the model got *unstuck* — "stepped back and re-read the contract first", "checked ground truth before re-deriving") → **Patterns** (vault `Patterns/`, provenance schema). This is the positive learning: the correction worked.
   - If it names a **pitfall worth recording** (the wrong assumption itself — "assumed the cascade fires on PR-merge; it fires on issue-close") → **Mistakes** (vault `Mistakes/`, provenance schema), deduping against existing notes exactly as the § Mistakes step does.
   - If the realization is too thin to warrant a note on its own (a one-off course-correction with no general lesson) → record it only as a findings record (below) so it still counts toward recurrence.
3. **Emit a findings record** (§ Findings records) for each adjudicated self-correction with `finding_type: mistake` (the routing target) or `finding_type: pattern` as routed above. If the match came from a `self-correction` tell, provenance is `lexicon-hit` with `sub_method` = the tell; if the model caught it from `user_turns[]` with no tell, it is `model-skim` → it also feeds **§ Candidate-tells accumulation**, the mechanism that grows the lexicon.

**Feeding recurring ones into the lexicon — the promotion path.** This pass deliberately reuses the existing growth machinery rather than adding a new one (subtraction over mechanism):

- **Model-skim self-corrections** (the lexicon missed them) append to `Context/pipeline - candidate tells.md` via § Candidate-tells accumulation — each proposes a concrete new `self-correction` tell for `lexicon-assistant.tsv`, reviewed and promoted at `check-in`. This is how a **recurring** self-correction phrasing the lexicon doesn't yet catch becomes a permanent tell so future sessions detect it.
- **Recurring self-corrections as a class** are picked up by § Recurrence → promotion: because each accepted self-correction is a `mistake`/`pattern` findings record, the trailing-14-day tally already counts them, and crossing the ≥5 threshold raises a promotion task (tighten a guard rule or elevate a pattern). No new tally is needed.

**Default to silence.** Most stubs surface no genuine self-correction. Do not manufacture one from routine "let me check X" narration — only a real reasoning reversal qualifies.

### Unfiled defects

Backstop for the live "Capture at source / Capture, don't ask" rule in `stageFind/CLAUDE.md` § Task workflow. The live rule says: when a defect is noticed mid-work and not fixed now, file it immediately via `scripts/capture.sh` rather than offering and waiting. This step catches the ones that slipped — typically an end-of-session "want me to file this?" that the user never answered, or a "side observation" that was only ever spoken.

Distinct from **Mistakes** (which captures the *lesson* in the vault): this captures the *unfixed defect itself* on the **worklist** (board / GitHub issue), because a vault note records rationale but is not a tracker — see the `stageFind/CLAUDE.md` "Defect vs enhancement routing" convention.

**Adjudicate `report.lexicon_matches[]` for defect-category tells** (categories: `defect-language`, `capture-miss`, or similar — check `report.lexicon_matches[].category`). **Include the `worked-around-defect` category** — these are the assistant-turn tells (`role: "assistant"`, from `lexicon-assistant.tsv`, foundation #444): a defect the *assistant itself* narrated routing around mid-task ("this is broken, let me work around it", "fall back to X because Y fails") and may never have filed. They are the highest-signal Unfiled-defect candidates precisely because the workaround makes the bug invisible — the #443 pattern (worked around twice, never filed). **Also fold in any recurring `soft` error from `report.tool_events.errors[]`** (per the tool-errors pass above) — a silently-failed tool is the same blind spot from the other direction. **Before filing, consult the `capture_calls` structural pass output above** — any defect whose keywords appear in a `capture_calls[].command` entry was already filed at source by the live "Capture at source" rule; cross-reference to avoid duplicates. Finally, skim `report.user_turns[]` for defect-shaped language the lexicon may have missed (novel phrasing, implicit observations). The canonical tell phrases are maintained in `workflows/scripts/drain/lexicon.tsv` (user turns) and `workflows/scripts/drain/lexicon-assistant.tsv` (assistant turns); the inline list below is illustrative only:

> "side observation", "out of scope (for my PR)", "worth flagging", "worth a follow-up", "candidate for a follow-up issue", "follow-up issue/item", "I'll just note it", "leave it (alone/here)", "not acted on", "gap in #N", "untracked", "not registered / not wired / not threaded / not consumed", "stale reference/comment", "doesn't fire / doesn't persist / never registered", "that's a bug", "want me to file …?" (especially if the *next* user turn changed topic or ended the session).

For each candidate:

1. **Classify by the routing predicate.** Apply the **defect-vs-enhancement routing predicate** — canonical statement: stageFind project `CLAUDE.md` § Task workflow → "Defect vs enhancement routing". Route per that predicate; do not restate it here. A **defect** → worklist (continue below); an **enhancement / deferred design seam** → not a defect, so capture it as a `Decisions/`/`Context/` note per the Decisions step instead, and move on.
2. **Dedup against the worklist, not Things.** Check for an existing GitHub issue (`gh issue list --state all --search "<keywords>"`) **and** a board item (project 3 stageFind, project 4 foundation). If either covers it, skip — live capture worked.
3. **Verify it's still live.** If the defect was since fixed (grep the repo / `git log`), do not file; note it as "self-resolved" in the summary.
4. **File it** via `scripts/capture.sh "<title>" --body "<one-line context + Sessions/<stub> provenance>" --label bug [--board 3|4]` (board 4 for foundation-tooling defects). Capture the issue number for the summary.
   - If the defect is **rework** — redoing or correcting prior work — add `--rework <regression|spec-miss|flake>` to the same `capture.sh` call so the cause is captured at filing time (F#730). This is a human-filing convention applied by whoever runs this step, not an automated real-time extraction rule, so it deliberately has no Live/Drain registry-table pair.

**Default to silence.** If a stub's defects were all filed live (the common case once "Capture, don't ask" is in force), surface nothing. Do **not** route a real defect to the Things inbox — Things is for personal/triage tasks, the board is the canonical worklist for defects.

### Stale board claims

Backstop for the live "Board hygiene is part of the gate" / "Park, don't abandon" rules in `claude/CLAUDE.md` § Task workflow, and for build's per-run Step 0.5 self-claim recovery. Those catch the *single-run* case; nothing periodically sweeps the board **across sessions** for claims a dead run stranded In Progress (bugs **and** epics — both carry a real `Host/Session` stamp; the epic stamp lands at `build.md` Step 3a). A 2026-06-04/05 session found two epics stranded In-Progress for days under dead sessions (GH #85). This sweep is the periodic net.

**Run the status reconcile for each governed board** (via the board adapter's `reconcile`, on PATH from `make install-board`; if `reconcile` isn't on PATH, fall back to `workflows/scripts/board/reconcile.sh` in a foundation checkout, else skip this step with a one-line note):

```
reconcile --status --board 3
reconcile --status --board 4
```

Each run is read-only (one cached-bypassed board resolve + two flat-cost REST list reads — no per-item GraphQL burst). Collect the lines under three sections of its output:

- **`stale claims`** — In Progress, stamped to a **dead same-host session** (its Claude transcript is absent or untouched beyond `reconcile.sh`'s own `RECONCILE_STALE_AFTER_SECS` cutoff). The drain machine *can* verify these — they are the release candidates.
- **`orphaned In-Progress`** — In Progress with an **empty** owner stamp (a half-landed claim, GH #103). Also release candidates.
- **`foreign claims`** — In Progress on **another host**, whose liveness can't be checked from here. **Report-only, never released from this machine** — the owning host catches them on its own next drain.

**Report-only, never auto-release.** This command is unattended — there is no operator to confirm a release — so it mirrors `reconcile`'s own report-only stance (surface stale/orphan/foreign claims; move none). **Report only** — list every candidate in the Step 6 summary and park nothing (default = **leave all**). A claim left In Progress is a harmless lock; a wrongly-released active claim is not. **This is a `batch-at-ritual` deferral** ([[Context/foundation - AskUserQuestion severity taxonomy]]) — no live operator, a safe default — so don't *silently* default: when any same-host stale/orphan candidate exists, record the auto-taken default to the **pending-decisions surface** (`claude/CLAUDE.md` § Unattended pending-decisions surface) so the next `check-in` reviews it. Append one `### open` entry to the pending-decisions surface (`Context/pipeline - pending decisions.md` in the knowledge store) via `mcp__obsidian-builtin__vault_append`:
  ```markdown
  ### <YYYY-MM-DD HH:MM> · tidy stale-claim sweep · <host>:<sess8>
  - **Decision:** return same-host stale/orphan claims to Ready (board <N>: #<n>, …)
  - **Default taken:** leave all (report-only; parked nothing)
  - **Disposition:** auto-taken (unattended/--force-now; no live operator)
  - **Status:** open
  ```
- **Foreign claims** are *always* report-only — list them in the summary as "verify on `<host>`".

The current draining session's own claims self-exclude (their transcript mtime is current), so this never releases live work — including any item this very session is holding.

### Vault hygiene

A periodic **detect-and-propose** probe for the knowledge-store vault. Nothing else alarms on hygiene drift — `/tidy` curates *on touch* (provenance audit, contradiction detection) but never *sweeps* the vault, so a silent pile-up (162 `Sessions/_inbox` stubs / 18 MB before anyone noticed — foundation #958/#959) goes unseen until it is large. This step runs a standalone probe each drain and records any drift to a review surface for `check-in` to dispose of.

**A drain-internal detector**, not a live/drain pair (like § Contradiction detection, § Self-correction detector, and § Recurrence → promotion): it backstops **no live extraction rule** — hygiene drift is a *state* the vault accumulates over time, not an author action a live rule captures — so it has **no live anchor it backstops, no Live/Drain registry row, and needs no `validate-live-drain.sh` change**. It **proposes**; `check-in`'s `## Vault hygiene review` section is the **sole mutator** that disposes (the same drain-proposes / check-in-disposes split as § Pending decisions surface). Drain **never** bulk-deletes vault content.

**Run the probe** (a kernel script that reads the store via the script-plane `plain-files` backend — `KNOWLEDGE_STORE_ROOT` (see `workflows/scripts/lib/knowledge_store.contract.md` for the default); a checkout with no vault prints one line and no-ops, so this is safe to run unconditionally):

```
workflows/scripts/drain/vault_hygiene_report.sh --format entry
```

It checks: `Sessions/_inbox` stub count + oldest age (alarm above `INBOX_MAX_STUBS` stubs or `INBOX_MAX_AGE_H` hours); closed plans (`status: done|complete|abandoned`) still resident in `Plans/` (should be archived + removed); named ledgers over their line cap; zero-byte / double-dot / stray-absolute-path garbage files; and a stale-`last_verified` tally (informational). With `--format entry` it prints a ready-to-append `### <ts> · vault hygiene · <host>` block carrying **Status: open** **iff** something alarmed, and prints **nothing** when the vault is clean.

**Record the finding.** If the command printed a block (alarms present), append it verbatim to the vault-hygiene review surface `Context/pipeline - vault hygiene report.md` (in the knowledge store) via `mcp__obsidian-builtin__vault_append` — it creates the note if absent. If the command printed nothing, the vault is clean: **surface nothing** and move on (default to silence).

**This step does NOT** delete or move any vault file, does NOT mutate an entry's `Status` (check-in is the sole mutator, per its review section), and does NOT prune ledgers or archive plans. It only *reports* the drift; every disposal — deleting garbage, pruning a ledger, archiving a closed plan — happens at `check-in` on operator confirmation.

### Environment hygiene

A periodic **detect-and-propose** probe for the local filesystem environment — checkouts, worktrees, and launchd agents — the sibling of § Vault hygiene above for the *host* rather than the *vault* (temperloop#168/#176/#177). Nothing else periodically sweeps this state across sessions: `build`'s own Step 0.5 recovers only the current run's stranded claims, and a leaked worktree or a cron checkout that silently drifted behind `main` otherwise goes unseen until someone trips over it.

**A drain-internal detector**, not a live/drain pair: like § Vault hygiene, it backstops no live extraction rule — environment drift is a *state* the host accumulates over time (a leaked worktree, a checkout that fell behind), not an author action a live rule captures — so it has **no live anchor it backstops, no Live/Drain registry row, and needs no `validate-live-drain.sh` change**.

**Policy: aggressive in-lane, report cross-lane.** This step may auto-fix drift only in checkouts that are structurally nobody's interactive home — a disposable worktree, or a **cron/kernel checkout** (role-defined as always clean-on-main; `foundation.cron`, the kernel checkout, `foundation-kernel`). It never mutates a **foreign** checkout's `HEAD` — an **operator/consumer checkout** (`foundation`, `stageFind`, `ssmobile`, `subsetwiki`) may legitimately be another session's active lane, and per `claude/CLAUDE.md` § Working-tree ownership only the session that owns a checkout may move its `HEAD`. This mirrors that rule exactly: report, never switch.

**Run the probe**, both formats — `report` to get the full per-checkout classification this step reasons over, `entry` for the ready-to-append block:

```
workflows/scripts/build/env-reconcile.sh --format report
workflows/scripts/env-hygiene-report.sh --format entry
```

(`env-hygiene-report.sh` is a thin passthrough wrapper over `env-reconcile.sh --format entry` — either invocation is equivalent for the `entry` form; a checkout with neither script present no-ops, so this is safe to run unconditionally.) Both are **read-only and fail-open**: they never `git fetch`, `launchctl load/unload`, or write a file themselves — this step's own subsequent auto-heal actions (below) are what mutate.

For each drift class the `report` output surfaces, dispose as follows:

- **Auto-heal (safe, in-lane):**
  - **`LEAKED_WORKTREE`** (any of `ORPHANED`/`BRANCH_GONE`/`MERGED`/`CLOSED`) — under *either* a cron or an operator parent repo's `<repo>.wt/`: `git -C <parent-repo> worktree remove --force <wt-path>` then `git worktree prune`. Safe under any parent, because a worktree is never a session's launch dir (`claude/CLAUDE.md` § Working-tree ownership) — removing it touches no peer session's `HEAD`. If its `build/<slug>` branch still exists and is independently confirmed merged, delete it too (`git -C <parent-repo> branch -D build/<slug>`) — mirrors `worktree.sh`'s own cleanup.
  - **`BEHIND_MAIN`** on a cron/kernel checkout — fast-forward it: `git -C <repo> pull --ff-only`. Only when that same checkout classified *clean* (no `DIRTY`/`ON_BRANCH` alongside it) — `env-reconcile.sh` only ever emits `BEHIND_MAIN` for a checkout already confirmed on-default-branch, so this is the normal case. `--ff-only` refuses if the local ref isn't a strict ancestor, so this can never discard work.
  - **Merged local branches in a cron/kernel checkout** — run `scripts/prune-merged-branches.sh --apply` from that checkout. Safe: it only ever deletes a branch `git branch -d` itself confirms fully merged, and a cron/kernel checkout is never expected to carry extra local branches.
- **Report-only (cross-lane / risky) — append to the review surface, touch nothing:**
  - **`PARKED_ON_MERGED`**, **`DIRTY`**, **`STALE_UNTRACKED`** on an **operator/consumer checkout** — this is exactly the working-tree-ownership foreign-lane case; never `git checkout`/`reset`/`clean` there.
  - **`DIRTY`** or **`ON_BRANCH`** on a cron/kernel checkout — surprising for a role defined as always clean-on-main (a live run may be mid-flight there); report, don't touch.
  - **`AGENT_UNLOADED`** / **`AGENT_STALE`** — never `launchctl load`/`unload` from this step; restarting or reloading an agent out from under a possibly-still-running process is exactly the kind of foreign mutation this policy exists to avoid.
  - **`ABSENT`** / **`NOT_A_REPO`** / **`MALFORMED_PLIST`** — configuration problems with nothing safe to mechanically fix; report.

**Record the finding.** If the `entry`-format command printed a block, append it verbatim to `Context/pipeline - environment hygiene report.md` (in the knowledge store) via `mcp__obsidian-builtin__vault_append` — it creates the note if absent; this is a new pipeline surface parallel to the pending-decisions and sensitivity-flags surfaces, consumed by `/check-in`. Prepend one line per auto-heal action actually taken (`- auto-healed: <action> — <path>`) so the surface shows what was fixed alongside what's being reported. If the probe printed nothing (clean) and no auto-heal ran, **surface nothing** and move on (default to silence).

**File a board defect for a real misconfig** — a `BEHIND_MAIN` that `--ff-only` refused (true divergence, not a simple fast-forward), a `MALFORMED_PLIST`, an `AGENT_UNLOADED`/`AGENT_STALE` that recurs across drain runs, or an `ABSENT`/`NOT_A_REPO` checkout that should exist — via `workflows/scripts/board/capture.sh "<title>" --body "<one-line context>" --label bug [--board 3|4|--repo kernel]` (kernel-domain machinery routes `--repo kernel` per the kernel-vs-overlay routing rule; dedup against an existing issue first, same as § Unfiled defects). A drift class with a safe auto-heal (worktree prune, ff-pull, merged-branch delete) is not a "real misconfig" on its own — only file when the auto-heal itself failed or the drift is a class this step never auto-fixes.

**This step never mutates a foreign checkout's `HEAD`** — verified against a fixture with a foreign parked-on-merged operator checkout: reported to the surface above, never `git checkout`ed or reset. It also never `launchctl load/unload`s an agent and never deletes anything outside a confirmed-merged branch or a confirmed-leaked worktree.

### Pending decisions surface

Backstop for the live rule in `claude/CLAUDE.md` § Unattended pending-decisions surface. The live rule says: when a `batch-at-ritual` question (`build` Step 1.5, `build` Step 4b queue-stall, `assess` Step 6, this command's stale-claim sweep, `sweep` Step 2 leave-all-flagged) is deferred on an **unattended / mini / cron** run, the run takes its safe default AND appends an `### open` entry to the pending-decisions surface (`Context/pipeline - pending decisions.md` in the knowledge store) so the next `check-in` reviews it. This step catches the ones that slipped — an unattended run that defaulted a deferrable decision but never wrote the entry (so `check-in` would never surface it).

Check `report.lexicon_matches[]` for pending-decision tells (categories such as `batch-at-ritual`, `deferral`, or similar) and skim `report.user_turns[]` for an **unattended/`--force-now`/cron** batch-pipeline run that hit one of the five `batch-at-ritual` sites and took its default. Also check `report.tool_events.ask_user_questions[]` — unanswered questions (`answer: null`) in a run that was unattended are the clearest signal. High-signal tells: an assistant turn running `build … --unattended` (skipped the Step 1.5 prompt, "work all"), a `build` native-merge-queue stall that dequeued-and-fell-back without surfacing (Step 4b, unattended), `assess` arming or declining the approval poll under `--unattended`, a `sweep` unattended run that left clarifying questions flagged-and-skipped (Step 2), or this command's own `--force-now` stale-claim sweep reporting candidates without parking.

For each such defaulted decision:

1. **Check the surface.** Read `Context/pipeline - pending decisions.md` via `mcp__obsidian-builtin__vault_read`. If an entry already covers this run's decision (match on site + run-id / date), skip — live capture worked.
2. **Backfill the missing entry.** If absent, append one `### open` entry in the note's format (Decision + Default taken + Disposition + Status: open) via `mcp__obsidian-builtin__vault_append`, with Disposition noting it was backfilled by `/tidy` from `Sessions/<stub>`. This re-arms the `check-in` review the live write would have triggered.
3. **Default to silence.** If every unattended run's deferrals were recorded live (the common case), surface nothing.

Distinct from **Stale board claims** above (which reconciles board *state*): this reconciles the *decision audit trail* — that a defaulted batch-at-ritual choice is visible to the operator at the next ritual rather than silently standing.

### Session optimization tools

Skim `report.user_turns[]` and `report.lexicon_matches[]` (categories: `optimization`, `session-tool`, or similar) for assistant or user turns where a new optimization tool, command, flag, or technique was introduced — slash commands the user hadn't used before, MCP tool patterns, hook tricks, telemetry queries, configuration moves that materially reduce friction. For each candidate:

- Fetch `Patterns/Session optimization toolkit.md` via `mcp__obsidian__get_vault_file`. If a section with the same name already exists, skip — live capture worked, or this drain run already covered it.
- If novel, append a new `## <name>` section via `mcp__obsidian__append_to_vault_file` with `**What:**`, `**When to use:**`, and `**Source:**` lines. Source: `[[Sessions/<stub filename without .md>]] — <one-line context>`.
- Default to silence — most stubs surface nothing new.

This is a backstop for the live `Session optimization tracking` rule in `claude/CLAUDE.md`. If the file doesn't exist yet (no live captures have happened), create it via `mcp__obsidian__create_vault_file` with the heading + first entry.

### Tooling friction (fewer-steps)

Backstop for the live rule in `claude/CLAUDE.md` § Tooling friction capture. The signal is narrow on purpose: the session reached its outcome in **more steps than it needed**. **Adjudicate `report.lexicon_matches[]` for friction-category tells** — the relevant lexicon categories are **`friction-slug`** (the exact ledger-slug names, near-zero false-positive but they only fire when the friction was *already* named live) and **`state-collision`** (stale/dirty/conflicting state — `DIRTY`, `commits behind`, `stale local main`, `No commits between`, `now-stale`: the high-recall tells for unrecognized rework, fired on **user *and* assistant** turns). Then skim `report.user_turns[]` for friction-shaped narration the lexicon may have missed. Append every genuine instance **not already in the ledger** to the friction ledger (`Context/Session friction ledger.md` in the knowledge store) via `mcp__obsidian-builtin__vault_append`, one row each: `- <YYYY-MM-DD> · <project> · <category> · <one-line evidence>`.

- **Re-checked confirmed state** — `redundant-status-check` / `reverification-backtrack`: `git pull`/`status` right after the session's own push/merge → "already up to date"; re-polling CI/mergeability after `gh pr checks --watch` already exited 0; re-querying state to "confirm" a bug it had already diagnosed; re-reading or re-deriving a file/note it just produced. Verbatim tells: *"already up to date"*, *"wait… contradicts my earlier read"*.
- **Acted before ground truth** — `probe-after-not-before` / `stale-context-rework`: created a PR/branch/file or filed a defect, then found it already existed / the remote had moved / a decision governed it. Tells: *"a PR already exists"*, divergence discovered at `git push`, *"auto-add didn't fire"* before its lag elapsed. **A `state-collision` match is the canonical route here** — most often **branched off a stale local main** (the live *Fetch ground truth before building* rule was skipped): the PR comes back `DIRTY`/conflicted or is **redundant** (`built on stale local main`), and recovery costs a `reset --hard origin/main` + re-branch. This realization is almost always **assistant-narrated** ("local main was 100 commits behind", "I branched stale and created conflicts"), so it lives in the assistant-turn `state-collision` matches, not `report.user_turns[]` — adjudicate those matches, don't wait for a user turn to name it. Log as `stale-context-rework` (or `probe-after-not-before` if the divergence was found *at push* after the branch was already built).
- **Wrong tool contract** — `tool-misuse` (secondary): a vault patch retried on a heading path; an MCP lister that skipped dotfiles; `Edit` on a symlinked file; `search_vault_simple` where `_smart` was meant.

A **needed** verification is not friction — a status check that found real changes, a first diagnosis, a required merge gate. Append only genuinely avoidable steps; default to silence on a clean stub.

**Surface frequent stumbles.** After appending, tally the ledger over the trailing **14 days**. If any `category` has **≥5 rows**, surface it in the Step 6 summary as `Friction candidate: <category> (<count> in 14d)` and generate a Step 4 Things task — *Review friction ledger — <category> recurring; file a foundation issue*. This is how the most-frequent stumbles become tracked work rather than repeating silently.

**Default to silence.** If a stub yielded no novel learnings (because they were captured live), that is the correct outcome — do not invent extractions to feel productive.

### Knowledge-search parity misses

Backstop for the live **Phase 1 parity comparison rule** in `claude/CLAUDE.overlay.md` —
temporary, removed at Phase 3 (F#956) alongside that rule (F#946/F#947, `Plans/2026-07-04
foundation - obsidian knowledge-store migration`). The live rule says: while Phase 1 is in
force, every concept-level search (`mcp__obsidian__search_vault_smart`) should also run
`ks_search` (Bash) over the same query and get one comparison line appended to
`Context/foundation - knowledge-search parity ledger.md`. This step catches the ones that
slipped — a `search_vault_smart` call with no corresponding ledger line for that query and day.

**Skip entirely if this checkout has no `claude/CLAUDE.overlay.md`, or that file carries no
"Phase 1 parity comparison rule" section** — a standalone kernel checkout has no such rule to
backstop, and once Phase 3 deletes the rule this step should stop firing too (retire it in the
same change that removes the live rule).

For each stub in this drain run:

1. **Find candidate concept searches.** Read the stub's raw `.jsonl` transcript (the path in the
   stub frontmatter's `transcript:` field — the same "wider transcript access" reach as Step
   1.4, justified here because no `report.tool_events` sub-array captures generic MCP tool
   invocations) and grep it for `search_vault_smart` tool_use invocations; extract each call's
   `query` argument.
2. **Check the ledger.** Read `Context/foundation - knowledge-search parity ledger.md` via
   `mcp__obsidian-builtin__vault_read`. For each candidate query, look under `## Entries` for a
   line dated the same day as the stub whose query matches (exact string or an obvious
   paraphrase). If found, the live rule fired — skip this query.
3. **Backfill the miss.** For each query with no matching entry, append one line directly (a
   Bash `>>` append) in the ledger's `- <date> · <query> · smart|bm|tie · <gap note>` format:
   ```
   - <YYYY-MM-DD> · <query> · smart · backfilled by /tidy — ks_search comparison missing from live capture (Sessions/<stub filename without .md>)
   ```
   Default the verdict to `smart` (the only side known to have run) unless the same transcript
   window also shows a `ks_search` Bash invocation for the same query — in that case read both
   results from the transcript context and judge `smart`/`bm`/`tie` honestly instead of
   defaulting.
4. **Tally.** Surface `Knowledge-search parity misses backfilled: N (queries)` in the Step 6
   summary.

**Default to silence.** Most stubs show every concept search already ledgered live (the common
case once the live rule is in force). Do not manufacture a miss from an ambiguous transcript
read — skip rather than guess.

### Answered decisions

Delivery channel for the `decision_sink_ask` async backend — the read-back half of the decision queue sink. The async backend (in `/build`'s `decision_sink_ask` seam, operator-absent path) parks a plan item by posting a question comment, applying the `decision` label, and assigning the operator. When the operator replies and unassigns themselves, this step translates the parsed reply into **exactly one artifact** the existing 3d-esc / 4f resume machinery already reads — then stops. It does **not** transition sentinels (`[~]`/`[m]`/`[x]`), does **not** resume the item (no `build-level.mjs` invocation), and does **not** close the issue. The next `/build` tick's existing 3d-esc (`escalated: true` re-enter) or 4f (deferred `## Questions` drain) path performs resumption; this step only delivers the artifact.

**This step runs only during drain sessions that include a board-resident plan note in flight** — it is not a stub-based extraction. Run it as a standalone probe during any drain where a funnel run may have been active, regardless of whether the stubs contain decision-queue signals. Skipping it silently on a session without stubs is correct (Step 0 exits early when there are no stubs, but this probe is independent — run it when the environment supports it).

**Scope: one REPO per call.** The drain operator may be on either the foundation or ssmobile board. Run this probe once per configured `FUNNEL_REPO` (default: the two governed boards, foundation = `<org>/foundation`, ssmobile = `<org>/ssmobile`). All gh commands below pass `-R "$REPO"`.

**Algorithm (per repo):**

1. **List candidate issues.** Query unassigned open decision issues. Use a
   **search qualifier** for the unassigned scope — `--assignee ""` is a no-op
   that does NOT restrict to unassigned (foundation #587), so it over-pulls
   operator-held issues; `no:assignee` actually filters:
   ```sh
   gh issue list -R "$REPO" \
     --search 'label:decision state:open no:assignee' \
     --json number,title,body,comments
   ```
   If the list is empty, skip this repo — nothing to drain.

2. **For each candidate issue `#N`:**

   a. **Contention pre-check.** Re-read the issue's current assignee count before acting:
      ```sh
      CURRENT=$(gh issue view "$N" -R "$REPO" --json assignees --jq '.assignees | length')
      ```
      If `CURRENT` > 0, the operator or another tick has re-assigned since the list was fetched — **skip this issue for this tick** (log: `issue #N assignee changed since list read — skipping`). Never act on an issue whose assignee changed under you.

   b. **Read the most recent comment.** Extract the last comment body from the `comments` array returned in step 1 (index `-1`). If there are no comments at all, treat as a parse-miss.

   c. **Parse the reply** per the typed reply grammar in `~/.claude/decision-queue-contract.md` § 3. Apply in order:
      - **Fenced `decision` block** — match a ` ```decision … ``` ` block anywhere in the comment; extract `chosen:` (required) and `reason:` (optional). Trim whitespace; match case-insensitively.
      - **`/choose <label>`** — a line starting `^/choose ` at the start of a line (no leading whitespace); extract the remainder as the label. Trim.
      - **`/approve`** — a line `^/approve` at the start of a line; treat as `chosen: approve` (valid only when `approve` / `accept` is an offered option — validate below).
      - **`/hold #N`** — not yet implemented; treat as a parse-miss with note `"/hold not yet supported"`.

   d. **Identify the item kind and slug.** Read the issue body for a `Tracked in plan:` back-link (format: `Tracked in plan: [[Plans/<date> <project> - <title>#<slug>]]`). The slug is the fragment after `#`. Also look for a `kind:` line (format: `kind: design-fork` or `kind: blocked`) that the `decision_sink_ask` async backend posts in the question comment. The question comment is the **first** comment (or the comment that contains the `kind:` line — search backwards from the most recent). If the kind cannot be determined from the comment, infer from context: a question listing design options with a `decision` fenced block structure → `design-fork`; a question listing clarifying questions → `blocked`.

   e. **Validate `chosen` against the offered option set.** The question comment (the one posted by the driver) lists the offered options. Extract the option labels from that comment (look for a block like `- \`<label>\` — ` lines, or an `Options:` / `**Options:**` section). Check that the parsed `chosen` value matches one of those labels (case-insensitive, whitespace-trimmed). If it does not match (or the option set cannot be parsed from the question comment), treat as a parse-miss.

   f. **On a successful parse and valid `chosen`:**
      - **Determine which artifact to write** based on `kind`:
        - **`design-fork`** → write a `## Design verdict — <slug>` block to the plan note:
          ```markdown
          ## Design verdict — <slug>
          Decision: <issue title or the design_fork.decision text from the question comment>
          Chosen: <the matched option label>
          Rationale: <the operator's `reason:` value, or "operator chose via decision queue" if absent>
          ```
          **Use `mcp__obsidian-builtin__vault_append`** on the plan note path (resolved from the `Tracked in plan:` wikilink). Do **not** use `mcp__obsidian__patch_vault_file` — the em-dash heading causes that tool to misfire. Then stamp `  - escalated: true` on the plan item via `mcp__obsidian-builtin__vault_patch`. This is the durable sentinel that the next `/build` tick's Step 1.4 resume path keys off to route the `[~]` item to 3d-esc continuation.
        - **`blocked`** → write a `## User answers — <slug>` block to the plan note:
          ```markdown
          ## User answers — <slug>
          <the operator's reply text (the chosen label plus reason if present), one line>
          ```
          **Use `mcp__obsidian-builtin__vault_append`** on the plan note. Then stamp `  - escalated: true` on the plan item via `mcp__obsidian-builtin__vault_patch`.
        - **Other kinds** (risky-set merge gate, `kind: merge-gate`) → write a `## Escalation resolution — <slug>` block via `mcp__obsidian-builtin__vault_append`:
          ```markdown
          ## Escalation resolution — <slug>
          Kind: <kind>
          Chosen: <the matched option label>
          Reason: <operator's reason if present>
          ```
          Then stamp `  - escalated: true` on the plan item (same as above).
      - **Drop the `decision` label** (baton handback):
        ```sh
        gh issue edit "$N" -R "$REPO" --remove-label decision
        ```
      - **Post a confirmation comment** (the delivery artifact). It MUST carry
        the machine sentinel `<!-- funnel:decision-applied -->` on its own line —
        `funnel-tick.sh`'s idempotency guard (foundation #587) keys off it to
        recognise an already-drained issue that search-index lag re-lists, and
        skip it (`drain-already-applied`) instead of mis-firing a parse-miss +
        operator re-assign:
        ```sh
        gh issue comment "$N" -R "$REPO" --body \
          "Decision applied: $(chosen_value). Artifact written to plan note. Resuming on next tick.
        <!-- funnel:decision-applied -->"
        ```
      - **Stop.** Do NOT call `build-level.mjs`, do NOT flip `[~]`→`[m]`/`[x]`, do NOT merge. The existing 3d-esc / 4f path on the next tick performs resumption.

   g. **On a parse-miss** (unrecognizable comment, chosen not in offered set, `/hold`, or no comments):
      - **Re-assign to operator** with a "couldn't parse" comment per `~/.claude/decision-queue-contract.md` § 3 parse-miss rule:
        ```sh
        gh issue comment "$N" -R "$REPO" --body \
          "Couldn't parse your reply as a decision. Expected one of:
          - A \`\`\`decision\`\`\` block with \`chosen: <option>\` where <option> is one of: <offered-labels>
          - \`/choose <option>\` with one of the above labels
          - \`/approve\` (if \"approve\" is an offered option)
          Please re-reply and unassign yourself when done."
        # Strip a leading `@` from a real login (GitHub's replaceActorsForAssignable
        # rejects `@example-operator`; #977) but preserve the special `@me` token gh resolves.
        ASSIGNEE="$OPERATOR"; [ "$ASSIGNEE" = "@me" ] || ASSIGNEE="${ASSIGNEE#@}"
        gh issue edit "$N" -R "$REPO" --add-assignee "$ASSIGNEE"
        ```
        `OPERATOR` = `FUNNEL_OPERATOR` env var, default `@me` (operator's own handle — `gh`'s `@me` resolves to the authenticated user's real collaborator LOGIN, which can differ from the display/email-derived name shown elsewhere; verify with `gh api user -q .login` rather than assuming the two match; foundation #588). `--add-assignee` must receive a **bare** login (`example-operator`) or the literal `@me` — an `@`-prefixed real login (`@example-operator`) fails to resolve (foundation #977), hence the `ASSIGNEE` strip above.
      - **Leave** the `decision` label in place. The item remains in the queue for the next tick. Do NOT write any artifact block.

3. **Record in Step 6 summary:**
   - `Answered decisions drained: M (issue #s, repos, kinds, artifact types)`
   - `Parse-misses re-queued: M (issue #s, repos, reason)`
   - `Skipped (contention): M (issue #s)`

**What this step does NOT do (the delivery-channel invariant):**
- It does NOT make `[~]`→`[m]`/`[x]`/`[-]` sentinel transitions.
- It does NOT invoke `build-level.mjs` or any workflow continuation.
- It does NOT close the decision issue (the issue stays open; the `decision` label drop is the only label mutation on success).
- It does NOT open PRs, push branches, or interact with the merge gate.
- It does NOT re-derive or resume the plan independently — it writes one artifact block and stops.

The step is verified correct if, after it runs, the plan note contains the verdict block and `escalated: true`, the `decision` label is gone, and the next `/build` tick's 3d-esc / 4f path picks it up without any additional intervention from this step.

### Findings records

**After each extraction decision** (accept or skip), emit one findings record to `meta/data/raw/findings-<YYYY-MM>.jsonl` (one JSON object per line, newline-delimited). The schema is `workflows/scripts/drain/findings-schema.md` — that file is the SSOT; the required fields are summarised here for inline reference:

| Field            | Value |
|------------------|-------|
| `schema_version` | `"2"` |
| `ts`             | ISO-8601 timestamp of this drain run. |
| `session_id`     | `report.stub.session_id` |
| `project`        | `report.stub.project` |
| `method`         | `"drain-lexicon"` or `"drain-model-skim"` (from provenance tag above) |
| `sub_method`     | The specific `match.tell` for `drain-lexicon`; `null` for `drain-model-skim`. |
| `finding_type`   | `decision` / `defect` / `pattern` / `mistake` / `feedback` / `friction` / `optimization` / `deferral` |
| `finding_ref`    | Durable artifact reference (vault note path, `#N`, `feedback_topic.md`, `things:<title>`). |
| `accepted`       | `true` if the extraction became a real artifact; `false` if skipped (noise, duplicate, already-captured-live). |
| `subject_model`  | The **analyzed-session** model — `report.stub.model` (the same value you stamp as a note's `source_model`); `null` if the stub had no `model:` line. |
| `analyst_model`  | The **drain-runner** model — your own current exact model ID (the note `extracted_by_model`); equals `subject_model` only when the drain runs under the same model as the analyzed session. |

Append the record via Bash: `printf '%s\n' '<json>' >> ~/dev/foundation/meta/data/raw/findings-$(date +%Y-%m).jsonl`. Batch all records for a stub in one append call when possible. The file is created on first write; no pre-creation needed.

Emit records for every adjudicated candidate — both accepted and rejected — so the false-positive rate is also measurable.

### Candidate-tells accumulation

**For every accepted extraction with `method: "drain-model-skim"`** (the model caught it, the lexicon didn't), append one entry to the candidate-tells file at `Context/pipeline - candidate tells.md` in the vault via `mcp__obsidian-builtin__vault_append`.

Entry format (one line per extraction):

```
- <YYYY-MM-DD> · <project> · <finding_type> · `<missed phrase>` — <proposed tell>
```

- `<missed phrase>`: a short (≤10 words), greppable verbatim or near-verbatim phrase from the user turn the model used to identify the extraction.
- `<proposed tell>`: a one-line description — what it signals and how a lexicon pattern would match it (e.g. `literal: "going with option" → decision commit`).

Full format and review protocol: `workflows/scripts/drain/candidate-tells-format.md`.

If the vault file does not yet exist, create it first via `mcp__obsidian-builtin__vault_write` with this header:

```markdown
# Candidate Tells

Accumulated model-skim misses — phrases the model caught that the lexicon did not.
Review at check-in; promote promising ones into lexicon.tsv or discard.

```

Default to silence when no model-skim extractions were accepted — do not append placeholder entries.

### Recurrence → promotion

**Backstop that turns a repeating pattern of similar learnings into a proposal to amend the operating instructions.** The friction tally (`≥5/14d → Things task`) handles one category; this pass generalises the same shape to `feedback`, `pattern`, and `mistake` categories, where N similar extractions over a trailing window signal that a CLAUDE.md or skill *rule* should change — not merely that another note should be filed.

**How it works.** After all per-stub extractions above are complete (and findings records have been emitted), query the findings stream to count accepted extractions per `finding_type` over the trailing **14 days**:

```bash
# Tally accepted findings by type over the trailing 14 days (globs every
# findings-*.jsonl, so the window spans month boundaries). Prints `<type>\t<n>`.
python3 workflows/scripts/drain/tally_recent_findings.py "$(git rev-parse --show-toplevel)"
```

**Threshold rule.** For each of the following types, if the tally meets or exceeds the threshold, it is a **recurrence candidate**:

| `finding_type` | Threshold | Promotion signal |
|---|---|---|
| `feedback`  | ≥5 in 14d | Similar feedback keeps appearing → promote to a CLAUDE.md rule |
| `pattern`   | ≥5 in 14d | Pattern keeps being re-extracted → elevate to a canonical CLAUDE.md pattern anchor |
| `mistake`   | ≥5 in 14d | Same mistake recurs → tighten the guard rule in CLAUDE.md or a skill |
| `friction`  | ≥5 in 14d | (Handled by the Tooling friction section above — do not double-count here) |

**Default to silence.** Most runs surface nothing. Only proceed when at least one type crosses its threshold AND the type is in the covered set above (`feedback`, `pattern`, `mistake`). If the findings files are absent or unreadable, skip silently and note in the summary.

**For each recurrence candidate** (one type-category at a time):

1. **Check for an existing promotion task** — use `mcp__things__search_todos` with the title fragment `"Promote recurring <type>"` (Inbox + Anytime + Someday). If a task with that fragment already exists and is open, skip — a prior drain run already surfaced it.
2. **Generate a promotion task** via `mcp__things__add_todo`:
   - `title`: `"Promote recurring <type> extractions into a CLAUDE.md/skill rule"` — e.g. `"Promote recurring feedback extractions into a CLAUDE.md/skill rule"`
   - `notes`:
     ```
     <count> accepted <type> extractions in the last 14 days (threshold: 5).
     Recurring signal suggests a standing rule or guard should be added or tightened.
     Review the relevant notes/memories and draft a concrete amendment.

     ---
     Generated by /tidy recurrence→promotion pass on <YYYY-MM-DD>.
     Source: meta/data/raw/findings-<YYYY-MM>.jsonl
     ```
   - `tags`: `["drain", "Foundation", "est:30m"]`
   - `when`: omit (lands in Inbox)

**Surface in Step 6 summary** — see the `Recurrence candidates (≥5/14d)` line in the summary template below.

**Note on the live/drain split.** This pass is **drain-internal** — it tallies the findings stream that drain itself produces rather than backstopping a live extraction rule. No new live anchor exists in CLAUDE.md and no new registry row is needed. The validate-live-drain script does not need updating.

## Step 4 — Generate tasks (liberal, deduped)

Identify candidate tasks from the **scan report** (`report.lexicon_matches[]` for deferral-category tells + `report.user_turns[]` for explicit or implicit commitments):
- Explicit deferrals — "queue this," "let's pick this up later," "table this," "next session," "tomorrow."
- Open questions left dangling that the user implicitly committed to resolving.
- Action items the user agreed to but did not complete in-session.
- Follow-ups Claude proposed that the user did not reject.

**Exclude defects already handled in Step 3 § Unfiled defects** — a defect routed to the board/GitHub there must **not** also become a Things task here. Things is for personal/triage follow-ups; the board is the worklist for defects.

For each candidate:

1. **Dedup pass.** Use `mcp__things__search_todos` (or `mcp__things__get_tagged_items` with tag `drain`) to find existing tasks with similar titles or tagged `drain` referencing the same source. Search Inbox + Anytime + Today + Someday. If a match exists, skip.

2. **Cross-stub dedup.** Within this drain run, track titles you've already added so two stubs about the same topic don't both create the task.

3. **Create task** via `mcp__things__add_todo` with:
   - `title`: short imperative ("Decide deployment target," "Review burrito-task triage")
   - `notes`: `<one-line context from the stub>\n\n---\nGenerated by /tidy from Sessions/<filename>.md on <YYYY-MM-DD>.\nSource: <project> session <date> <time>.`
   - `tags`: `["drain"]` plus the relevant theme tag (`Foundation` / `Community` / `Business`) when obvious from the stub, plus an `est:<duration>` tag using standard buckets (`est:5m`, `est:15m`, `est:30m`, `est:1h`, `est:2h`, `est:4h`, `est:8h`). Determine from stub context when scope is clear; if ambiguous, tag `est:?` and surface in Step 6 as `Tasks needing estimate refinement: M (titles)`.
   - `when`: omit (lands in Inbox by default)

4. Batch parallel `add_todo` calls when adding multiple tasks.

**Tag pre-existence note:** Things 3's URL scheme silently drops tags that don't already exist in the user's tag library. The theme tags (`Foundation`, `Community`, `Business`) exist; `drain` exists; `est:*` tags need to be created in the Things UI before they'll attach. If an `est:*` tag is missing, the task still creates but the estimate lives only in the notes line. Mention this in the summary if any drained task was missing its est-tag attachment.

## Step 5 — Archive the stub to the git store

The raw transcript's terminal home is the **git-tracked archive at `~/dev/foundation/meta/sessions/archive/`**, *not* the vault — moving it out of the embedded tree is what stops Smart Connections from re-embedding raw transcripts (epic #252; the 81%/258 MB cache bloat). The curated extractions from Steps 3–4 stay in the vault, where semantic search still finds them; only the raw transcript leaves the semantic layer. See `Decisions/foundation - Session-log long-term storage`.

Move the processed stubs from `Sessions/_inbox/<filename>.md` into the git store. **Archive the whole run's stubs in ONE batched archiver call** — `archive-session.sh` accepts multiple stub paths and lands them as a **single commit / single PR** (the retention sweep + `INDEX.md` regen + landing attempt run once for the batch). This is the #487 fix: a per-stub call would open one PR per stub, each re-regenerating `INDEX.md` on adjacent same-date lines and conflicting in the merge queue. **All vault access stays on MCP; the filesystem copy is done by the archiver script (no model Write-tool involvement):**

1. **Collect the cleanly-processed stubs.** For **each** stub that completed Steps 1–4 without unhandled errors, derive its local filesystem path — like Step 1's scanner call, a **raw on-disk path outside the knowledge_store seam**: the archiver reads vault files directly from disk (the MCP-only rule binds Claude, not shell scripts, and the obsidian backend's REST API has no filesystem-root semantics to route through). Resolves under the knowledge store root, e.g. `$KNOWLEDGE_STORE_ROOT/Sessions/_inbox/<filename>.md`. **Exclude** any stub that failed mid-process — leave it in `_inbox/` for the next run; it is not part of this batch.
2. Run the archiver **once, passing every collected stub path as a separate argument**. It copies each into `meta/sessions/archive/<basename>` via `cp` (printing `archived: <basename>` per stub), then runs the retention sweep (gzip cold logs), regenerates `INDEX.md` **once**, and makes a **single** landing attempt for the whole batch:
   ```
   bash ~/dev/foundation/workflows/scripts/sessions/archive-session.sh \
     $KNOWLEDGE_STORE_ROOT/Sessions/_inbox/<stub-1>.md \
     $KNOWLEDGE_STORE_ROOT/Sessions/_inbox/<stub-2>.md \
     …                                            # every cleanly-processed stub
   ```
   It is idempotent, touches **only the `meta/sessions/archive/` path, and only on the default branch (`main`)**. Because `main` is protected (the #330 merge-queue ruleset rejects a direct push — #404), on a protected `main` the archiver **lands the batch on a branch + PR + queue** rather than a bare local commit (which would be stranded local-only). Its **final** stdout line is a single durability verdict **for the whole batch** (the per-stub `archived:` lines above it are progress, not the verdict):
   - `archive-committed: <rev>` — the batch is **durable** (pushed to `origin/main`, already on `origin`, or committed locally where no remote exists); every stub in the batch is safe to remove.
   - `archive-pr-queued: <pr>` — the batch was landed on **one** PR that is **enqueued but not yet merged** (protected `main`). It is **not yet durable on `origin`** — the queue merges it asynchronously, minutes later.
   - `archive-uncommitted: <reason>` — the stubs were placed on disk but **not** landed at all (a feature branch is checked out, `~/dev/foundation` isn't a git repo on this host, a direct push was rejected, etc.). They persist and a later default-branch run lands them.
3. **The single terminal line governs the WHOLE batch.** Delete the `_inbox/` stubs (via `mcp__obsidian__delete_vault_file`, one call per stub) **ONLY if the archiver printed `archive-committed`** — then delete every stub in the batch. For the other two outcomes the transcripts are not yet durable on `origin`, so **keep all the batched `_inbox/` stubs** — deleting one before its transcript lands would lose it:
   - `archive-pr-queued: <pr>` — list it in the Step 6 summary as `archive PR #<pr> queued — N stubs retained until merge`. This is **expected, not stuck**: the queue lands the PR async, and the **next** drain run re-archives the retained stubs — once the PR has merged, the archiver finds them already on `origin` and prints `archive-committed: <rev> (already on origin)`, at which point that run deletes them. The flow self-heals across runs.
   - `archive-uncommitted: <reason>` — list under *Skipped/failed* as `archive deferred — not committed: <reason>` so a later default-branch run re-archives and lands the batch.

Archive only stubs whose Steps 1–4 completed without unhandled errors (step 1 above); a stub that failed mid-process stays in `_inbox/` and is noted in the summary so the next run picks it up. (Retrieval of archived transcripts is `git log -S` / `rg -z`, not semantic search — documented in `claude/CLAUDE.md` § Session logs for cold-session discoverability, #273.)

## Step 6 — Emit a summary

One-block summary:

```
/tidy — N stubs processed
- Decisions captured: M (titles)
- Provenance backfilled: M (titles)
- Provenance gaps (ambiguous authorship): M (titles)
- Proposed supersessions: M (D_new → D_prior; surfaced to proposed-supersessions surface for check-in)
- Memories saved: M (types)
- Patterns/Mistakes: M
- Optimization tools captured: M (titles)
- Tool-event structural passes: AskUserQuestion answered: M → feedback/decisions: K; errors: M → friction: J / mistakes: K; interrupts: M → feedback: K; capture_calls seen: M (dedup'd against Unfiled defects)
- Unfiled defects filed: M (issue #s); self-resolved: M (titles)
- Stale/orphaned board claims: M (#s → board:host:sess; parked: K, report-only foreign: J)
- Answered decisions drained: M (issue #s, repos, kinds, artifact types); parse-misses re-queued: M; skipped (contention): M
- Tooling friction logged: M (categories); friction candidates (≥5/14d): M (categories)
- Recurrence candidates (≥5/14d): M (types — feedback/pattern/mistake); promotion tasks added: M (titles)
- Tasks added to Things inbox: M (titles)
- Tasks needing estimate refinement: M (titles tagged `est:?`)
- Sensitivity flags: M (with file references, no secrets in output)
- Skipped/failed: M (with reasons)
```

Always output only the summary block — this run is unattended (see the intro). The summary is written to the run log, not shown to a live operator; anything needing a human decision has already been parked to a `Context/pipeline - *` surface (or the sensitivity-flags surface) for `/check-in` to dispose. **Never** ask a clarifying question — extract liberally and let `/check-in` and morning planning triage.

## Step 7 — Release the drain lock

Delete your own `Sessions/_inbox/.drain.lock.<HOST>` via `mcp__obsidian__delete_vault_file`. Do this **unconditionally** at the end of the run — even if some stubs were left in `_inbox/` for the next run — so the lock never blocks a later drain. (A crash that skips this is backstopped by Step 0 item 4d's `TIDY_LOCK_STALE_AFTER` staleness cutoff.) Skip if you took the `--force-now` path and never wrote a lock.

## Step 8 — Snapshot the vault (silent)

Run `~/dev/foundation/workflows/scripts/mind_snapshot.sh` (no flags) to capture the vault's final state into the nested git history at `foundation/mind_snapshot/`. This runs **last** — after every extraction, surface append, archive, and lock release — so the whole run's writes land in one snapshot. The script is idempotent: if nothing changed since the last snapshot, no commit is created. Log any error in one line and continue — **never fail the run over the snapshot**. This absorbs what the retired evening ritual's snapshot step used to do (`/tidy` is now the sole `mind_snapshot.sh` runner; K86). If `~/dev/foundation` is absent on this host, skip with a one-line note.
