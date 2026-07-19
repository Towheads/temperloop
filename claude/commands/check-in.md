---
description: Daily human check-in — review the overnight machine output and set direction. Render the telemetry brief (status readout), dispose the pipeline surfaces `/tidy` and the funnel parked overnight (pending-decisions, pending-activations, proposed-supersessions, retro-findings if `/retro` is installed, candidate-tells, vault-hygiene, sensitivity-flags), then review/set the `/next` priorities for every project.
---

You are running the **check-in** command — the daily human driver's-seat review. Overnight, unattended machinery (`/tidy`, the funnel cron, `/build --unattended`, and `/retro` if installed — see the capability check in Part 2) did work and **parked everything needing human judgment** on durable surfaces. `/check-in` is where a person clears those queues and sets direction. Three parts: **① a status readout** (telemetry brief), **② dispose the overnight queues**, **③ review/set the `/next` priorities per project**. Be concise.

This is the **operator-disposes** half of the drain-proposes / operator-disposes split: the pipeline surfaces are **append-only**, written by the unattended machinery, and `/check-in` is their **sole `Status` mutator**. (The personal daily plan — calendar, inbox-zero, slots, Today — is a *separate* activity: `/standup`, an overlay command. `/check-in` reviews the machine; `/standup` plans the day.)

Throughout, surface files (`Context/pipeline - *.md`, `Priorities/<project>.md`) are relative to **the knowledge store root**, resolved per `workflows/scripts/lib/knowledge_store.contract.md`. **Path fallback convention** (stated once here — canonical for all six command surfaces, referenced by name as "path fallback convention" from `next.md`, `assess.md`, `build.md`, `tidy.md`, `sweep.md`): the overlay reorg (epic #226) is moving these to `Projects/<project>/Priorities.md` and `Pipeline/<surface>.md`, but the kernel must not assume that move has landed yet (#226's consumes-clause). Every read of one of these paths tries the **new** path first (`Projects/<project>/Priorities.md`, `Pipeline/<surface>.md`); if that read/list comes back absent, try the **legacy** path (`Priorities/<project>.md`, `Context/pipeline - <surface>.md`); if **both** are absent, fall back to that site's own existing missing-file behavior (scaffold-offer, "say and move on", etc.), unchanged. A write (`Edit`/`vault_append`) that follows a resolving read always targets whichever path that read just resolved — never write a fresh copy at the other location. **Append-target resolution rule** (for the `vault_append` writer sites in `build.md`, `tidy.md`, and `sweep.md`, which have **no** preceding resolving read and may auto-create their target — referenced per-site as "append-target resolution"): before appending, do an explicit both-paths existence check and pin the append to the file that **already exists** — the legacy file when only it exists, the new-path file when only it exists; if both somehow exist, append to the new path (the same file the read above resolves — never fork the two entry streams). When **neither** exists, create at the **legacy** path; the new path becomes the creation target only once the overlay reorg has landed — i.e. its parent folder (`Pipeline/`, or `Projects/<project>/` for a priorities note) already exists in the knowledge store. **Invariant: an append must never create a new-path file while a legacy-path sibling exists** — that would silently orphan the legacy file's open entries, because every reader stops at the new path once it exists. Read via `mcp__obsidian-builtin__vault_read`; mutate a `Status` line via a direct `Edit` on the store file (the store is a local folder under the `plain-files` backend). `/check-in` is the **only** mutator of these `Status` lines — the append-only discipline the surfaces depend on.

## Part 1 — Telemetry brief (status readout)

Lead with the push-surface telemetry digest — "what needs me" should open the review. Render the **kernel telemetry brief** first — the kernel-side renderer ships in every checkout (kernel-only or composed), reads **only the kernel raw streams** (the `meta/data/raw/` lake streams plus the knowledge-store read log — each named explicitly in its output, per-section, so every number is reconcilable against its source file), and degrades honestly: an absent or empty stream renders a "no data yet" line, never a crash or a fabricated number:

```sh
bash workflows/scripts/telemetry-brief.sh
```

Show its output **verbatim** as the first thing in the session — it leads with **data age** across the kernel streams and alarms loudly (`DATA STALE`) if the freshest record is past 24h. If it prints `DATA STALE` or `DATA AGE: UNKNOWN`, call that out as your opening line before anything else, since it means the rest of the brief (and other telemetry-backed surfaces) can't be trusted right now. Do not summarize or drop the data-age line — paste the markdown as-is.

Then render the **overlay enrichment, only if present** (a composed install has it; a kernel-only checkout does not — the kernel brief above stands alone). The overlay renderer adds the rollup-backed digest the kernel streams can't derive: token-cost spend (cost-per-epic), rework/retro yield, and funnel escalation detail:

```sh
if [ -f workflows/scripts/build_telemetry_brief.py ]; then
  python3 workflows/scripts/build_telemetry_brief.py
fi
```

If the overlay script exists, show its output verbatim too (same data-age callout rule — it leads with the rollups' own data age). If it is absent, note in one line that the overlay enrichment is unavailable in this checkout and continue — the kernel brief has already rendered.

## Part 2 — Dispose the overnight queues

**Source the batch-pipeline config (best-effort), once, before this part.** `source workflows/scripts/build/build.config.sh` (bare repo-relative, the kernel's Step-0 config-sourcing convention — `~/.claude/CLAUDE.md` § Prose-resident knob convention). This pulls the prune-window knob (`CHECKIN_PRUNE_DAYS`, referenced below) into scope, with any pre-set env value still overriding. If the file isn't found, the sections below fall back to the `${CHECKIN_PRUNE_DAYS:-30}` inline default.

**Capability check for `/retro` (once, before the queues below), best-effort.** Source `workflows/scripts/lib/command_declared.sh` and evaluate `command_declared retro` — TRUE iff a `retro.md` command file exists at any of the three surfaces this helper checks (source-or-installed presence, not runtime-resolvability — see `command_declared.sh`'s own header): `$PWD/.claude/commands/retro.md`, this checkout's `claude/commands/retro.md`, `$HOME/.claude/commands/retro.md`. If the lib file itself can't be sourced (e.g. a checkout that predates this helper), treat `/retro` as **not installed** and take the FALSE branch below — the same best-effort fallback shape as the `build.config.sh` sourcing above. If TRUE (a composed install with `/retro` present), the **Retro findings review** subsection below runs and reports exactly as it does today. If FALSE (a bare kernel-only checkout with no `/retro` installed, or the lib couldn't be sourced — temperloop#521), skip that subsection entirely and instead emit exactly this one consolidated line here, for the whole run: `retro review skipped — /retro not installed (command_declared retro = false)`. This is the single skip notice for the entire session — nothing below repeats or elaborates on it.

Each subsection reads one append-only surface and disposes its `### … - **Status:** open` entries. For every surface: if the file doesn't exist, say so in one line and move on. Resolved entries older than `CHECKIN_PRUNE_DAYS` days may be pruned. `/check-in` is the **sole mutator** of every `Status` line below.

### Pending decisions review

Read the **unattended pending-decisions surface** — `Pipeline/pending decisions.md`, falling back to the legacy `Context/pipeline - pending decisions.md` (path fallback convention above) — via `mcp__obsidian-builtin__vault_read`. This is the cross-run inbox where `batch-at-ritual` questions land when a batch-pipeline command (`build` Step 1.5/1.7/4b/4d, `assess` Step 1's provenance default, `assess` Step 6, `tidy`'s stale-claim sweep, `tidy`'s provenance-less-epics sweep, `sweep` Step 2) ran **unattended / mini / cron** with no live operator and took its safe default to keep moving (see `claude/CLAUDE.md` § Unattended pending-decisions surface).

For each `### … - **Status:** open` entry, present it in one compact list: the decision, the **default that was auto-taken** on the operator's behalf, and when/which run took it. For each, the operator either:
- **confirms** the default was right → patch that entry's `Status` line to `resolved — confirmed` with a direct `Edit`; or
- **overrides** it → patch the `Status` line to `resolved — overridden: <action>` and carry out (or queue as a Things task) the override action they named.

If there are no `open` entries, say "no pending decisions" in one line and move on. This is what stops an unattended run's defaulted decision from silently standing.

### Pending-activations ledger

Read the **pending-activations ledger** — `Pipeline/pending activations.md`, falling back to the legacy `Context/pipeline - pending activations.md` (path fallback convention above) — via `mcp__obsidian-builtin__vault_read`. This is the cross-run home for an **activation obligation that cannot discharge at merge**. Per the activation-completeness contract (`[[Decisions/temperloop - Activation-completeness contract]]`), "done" splits into `merged` (code landed + CI green) and `activated` (the built thing is provably live), and only its two non-synchronous activation classes ever ledger here — a **class-B** obligation (propagation-gated / cross-repo: a kernel feature is live for a given consumer only once that consumer's installed kernel tag reaches the shipping tag) or a **class-C** obligation (time-deferred / soak: a LaunchAgent must actually fire on cadence, or a rollup needs a window to accumulate data, before liveness can be confirmed). A **class-A** obligation (synchronous, in-repo — flag, register, wire, render) discharges at merge and is never written here.

Each record carries:
- **class:** `B` or `C`
- **proof:** the concrete check that counts as "activated" for this obligation — what to run/read, and what a passing result looks like
- **locus:** where the proof is evaluated — the consumer checkout, machine, or agent the obligation is scoped to
- **watermark:** (class B only) the shipping tag/commit the locus's installed kernel tag must reach or exceed
- **soak-until:** (class C only) the date/time before which the proof cannot yet be evaluated — a poll before this date is a no-op, not a failure
- **soak_check:** (class C, **data-accumulation sub-case only**) a machine-checkable predicate evaluated directly — a command or count whose result decides the gate (e.g. `jq -e '.samples >= 100' <rollup.json>`), inward analog of a class-A `proof:`, never a vague "sensor". Omit this field on the **launchd sub-case**, which reuses `AGENT_STALE` instead (see the discharge gate below) rather than carrying its own predicate. A class-C record with **neither** a `soak_check:` **nor** a launchd-agent `locus` has no derivable predicate and is surfaced, never auto-discharged.
- **status:** `open` | `discharged`

For a **class-B cross-repo kernel-propagation** record specifically — the flavor this section's discharge mechanics below are written for — `locus` is either one or more explicit checkout paths (space-separated) or the literal token `all-consumers`, meaning every checkout already registered in `workflows/scripts/build/env-reconcile.sh`'s consumer registry (`DEFAULT_OPERATOR_CHECKOUTS`, override `ENV_RECONCILE_OPERATOR_CHECKOUTS`). Reusing that registry — rather than re-listing consumers in the ledger — is deliberate: it's the same enumeration `/tidy`'s env-hygiene probe already walks, so the two never drift apart.

**Only `/check-in` (and `/tidy`'s env-hygiene probe) mutate a record's `status:`** — no other command, live rule, or drain step writes it; a record parks `open` until one of those two polls it and finds the proof satisfied.

Worked example, class B:
```
### kernel-hook-live-in-foundation - **Status:** open
- **class:** B
- **proof:** foundation's installed kernel tag (composed `~/.claude/CLAUDE.md` provenance header) is >= the shipping tag
- **locus:** foundation checkout (`make update-kernel && make install` run there)
- **watermark:** v1.4.0
```

Worked example, class B, cross-repo propagation (`all-consumers` locus):
```
### semver-ledger-grammar-fleetwide - **Status:** open
- **class:** B
- **proof:** every registered consumer's `.kernel-pin` `tag` is >= the shipping tag, semver-compared
- **locus:** all-consumers
- **watermark:** v0.12.0
```
Say the registry currently resolves to two consumers, one on `v0.12.1` and one still on `v0.11.0`: `semver_ge v0.12.1 v0.12.0` is `true` (meets it) but `semver_ge v0.11.0 v0.12.0` is `false` (straggler) — the record stays `open`, reported as still pending on the second checkout. Once that straggler updates to (say) `v0.12.2`, both resolved checkouts meet the watermark and the record discharges as `discharged — v0.12.1 / v0.12.2` (the tags observed at discharge).

Worked example, class C (launchd sub-case):
```
### tidy-nightly-agent-first-fire - **Status:** open
- **class:** C
- **proof:** the `foundation.tidy-nightly` LaunchAgent (declared in `infra/launchd/tidy-nightly.plist`) has fired at least once, per its declared cadence, since this record was opened — reuses `env-reconcile.sh`'s existing `AGENT_STALE` signal, never a new sensor
- **locus:** `foundation.tidy-nightly` (the plist's `Label`)
- **soak-until:** 2026-07-18T00:00
```

Worked example, class C (data-accumulation sub-case):
```
### retro-measurement-rollup-warm - **Status:** open
- **class:** C
- **proof:** the retro-measurement rollup has accumulated at least 100 samples since this record was opened
- **locus:** `<knowledge-store-root>/Context/retro-measurement-rollup.json`
- **soak-until:** 2026-07-25T00:00
- **soak_check:** `jq -e '.samples >= 100' <knowledge-store-root>/Context/retro-measurement-rollup.json`
```

For each `open` entry, check its class-appropriate gate:

- **Class C (time-deferred / soak):** first, `soak-until` must have elapsed — a poll before it is a no-op, not a failure, and the record simply stays `open`, unreported. Once elapsed, the gate splits on which predicate the record actually carries:
  1. **Launchd sub-case** (record has no `soak_check:`; `proof`/`locus` describe a LaunchAgent). Reuse `env-reconcile.sh`'s existing `AGENT_STALE` signal as the liveness sensor — never invent a new one. Source the registry the same way class B does: `source workflows/scripts/build/env-reconcile.sh` with **no arguments** (safe — defines functions/populates `LAUNCHD_DIRS` and returns; does not run the reconciler). Then call the now-sourced `agent_status_by_label "<locus label>"`, which walks `LAUNCHD_DIRS` for the plist declaring that `Label` and returns `classify_agent`'s verdict directly — empty output means the agent fired within its declared cadence (discharge); `AGENT_STALE:<label>` means it's loaded but overdue (keep `open`, surface it); `AGENT_UNLOADED:<label>` means it isn't loaded at all (keep `open`, surface it); a non-zero exit with no output means no plist declaring that label was found among `LAUNCHD_DIRS` (unverifiable — keep `open`, surface it as unverifiable rather than guessing).
  2. **Data-accumulation sub-case** (record has `soak_check:`). Evaluate that command directly (e.g. via `Bash`) — exit `0` discharges, non-zero keeps the record `open` and reports the observed count/state if the command's output makes that available (e.g. re-run `jq '.samples' <rollup.json>` for a friendlier "at 63/100" report).
  3. **No derivable predicate** (record has neither `soak_check:` nor a launchd-agent `locus` `agent_status_by_label` can resolve). Never auto-discharge — surface the record as needing a human-supplied predicate (a missing `soak_check:` on a data-accumulation obligation, or a `locus` that doesn't name a real plist `Label`) and leave `status:` `open`.
- **Class B (cross-repo kernel propagation):** resolve `locus` to a concrete checkout list, then require **every** checkout in that list to have reached `watermark`:
  1. **Resolve the consumer list.** If `locus` names explicit checkout paths, use those. If `locus` is the literal `all-consumers`, source the registry rather than re-deriving it: `source workflows/scripts/build/env-reconcile.sh` with **no arguments** — this is safe to source (it only defines functions/populates `OPERATOR_CHECKOUTS` and returns; it does not run the reconciler or hit one of its `exit` calls, which under `source` would otherwise exit this session's shell, not just return) — then iterate `"${OPERATOR_CHECKOUTS[@]}"`.
  2. **Read each checkout's installed tag.** For each resolved checkout, call the now-sourced `kernel_pin_tag_of <checkout>` — it reads straight from that checkout's own `.kernel-pin` file's `tag` line (the same file `scripts/update-kernel.sh` already writes atomically; never a new stamp). A checkout with no `.kernel-pin`, or no `tag` line, returns nothing (exit 1) — treat it as **not yet reached**, not an error.
  3. **Compare under semver, never lexically.** For each tag that was read, call `semver_ge <tag> <watermark>` (also sourced from `env-reconcile.sh`) — a numeric `MAJOR.MINOR.PATCH` compare, e.g. `semver_ge v0.12.1 v0.9.0` prints `true` even though `v0.9.0` would sort *higher* than `v0.12.1` under plain lexical/string comparison.
  4. **All-or-nothing.** The record discharges only when **every** resolved checkout both has a readable tag and meets the watermark. One straggler (an unreadable `.kernel-pin`, or a tag still short of `watermark`) keeps the whole record `open` — report which checkout(s) are still short.

For an entry whose gate has passed, patch that entry's `Status` line to `discharged — <tag or timestamp observed>` with a direct `Edit` (for class B, the tag every consumer had reached; for class C, the observed `soak_check` count/state, or the timestamp the launchd agent's freshest run was confirmed at). An entry whose gate hasn't passed yet is left `open` and reported as still pending — naming the still-short consumer(s) for class B, or the launchd label's `AGENT_STALE`/`AGENT_UNLOADED` state or the observed `soak_check` shortfall for class C — never proactively re-checked before its watermark/soak-until, and never silently dropped. A class-C record with no derivable predicate is reported as such (needs a `soak_check:` or a resolvable launchd `locus`), also never silently dropped. If there are no `open` entries, say "no pending activations" in one line and move on.

### Proposed-supersessions review

Read the **proposed-supersessions surface** — `Pipeline/proposed supersessions.md`, falling back to the legacy `Context/pipeline - proposed supersessions.md` (path fallback convention above) — via `mcp__obsidian-builtin__vault_read` (cross-session contradictions surfaced by `/tidy`'s contradiction detector). If the file doesn't exist yet, say "no proposed supersessions" and move on. A supersession proposal has **no "default taken"** — it is flagged for judgment, not an auto-disposition.

For each `### … - **Status:** open` entry, present it: the two notes (`D_new` / `D_prior`), the proposed **direction**, and the one-line contradiction. For each, the operator either:
- **confirms** the supersession → hand-add the `[[wikilink]]` to the superseded note + a one-line supersession sentence in the **winning** note (the convention stays human-owned — the detector never edits a banked note), then patch that entry's `Status` line to `resolved — linked` with a direct `Edit`; or
- **dismisses** it (a false positive — refinement, not contradiction) → patch the `Status` line to `resolved — dismissed: <reason>`.

If there are no `open` entries, say "no proposed supersessions" and move on.

### Retro findings review

Runs only when the Part 2 capability check above found `command_declared retro` TRUE; when FALSE, this subsection is skipped in full — its coverage is already accounted for by that single consolidated skip line, so do not repeat or reference the skip here.

Read the **retro review surface** — `Pipeline/retro review surface.md`, falling back to the legacy `Context/pipeline - retro review surface.md` (path fallback convention above) — via `mcp__obsidian-builtin__vault_read` (nuanced/unmeasurable findings `/retro` could not name a measurable effect for at filing time; findings that clear `/retro`'s filing gate go straight to the board with a `## Measurement` block and never reach this surface). If the file doesn't exist yet, say "no retro findings" and move on.

For each `### … - **Status:** open` entry, present it: the Finding, the Axis, the Evidence summary, and `/retro`'s Suggested disposition. For each, the operator either:
- **accepts** it → file it as a board issue via `capture.sh` (title from the Finding, `--body` carrying the Evidence summary and Axis as measurement context, board matching the finding's repo — `--board 4` for foundation findings) despite the missing metric (a judgment call the automatic gate couldn't make), then patch that entry's `Status` line to `accepted → #N` with a direct `Edit`, where `N` is the new issue number; or
- **dismisses** it (noise, already known, not worth tracking) → patch the `Status` line to `dismissed: <one-line reason>`.

If there are no `open` entries, say "no retro findings to review" and move on. Disposed entries older than `CHECKIN_PRUNE_DAYS` days may be pruned.

### Candidate-tells review

Read `Pipeline/candidate tells.md`, falling back to the legacy `Context/pipeline - candidate tells.md` (path fallback convention above), via `mcp__obsidian-builtin__vault_read` (lexicon candidates surfaced by `/tidy`'s model-skim pass). If the file doesn't exist yet, say "no candidate tells" and move on.

Present any entries **not yet marked** `[promoted]` or `[discarded]` as a compact list. For each unresolved entry, the operator chooses:
- **Promote** — add the proposed tell to `workflows/scripts/drain/lexicon.tsv` (new row: `<tell_literal_or_regex>\t<category>\t<weight_or_blank>`), then append `[promoted]` to that entry's line with a direct `Edit`.
- **Discard** — the phrase is noise or too narrow. Append `[discarded]` the same way.
- **Defer** — leave it unmarked; it re-appears tomorrow.

Entries older than `CHECKIN_PRUNE_DAYS` days already marked `[promoted]`/`[discarded]` may be moved to a `## Archive` section at the bottom to keep the active list readable. If there are no unresolved entries, say "no candidate tells to review" and move on.

### Vault hygiene review

Read the **vault-hygiene review surface** — `Pipeline/vault hygiene report.md`, falling back to the legacy `Context/pipeline - vault hygiene report.md` (path fallback convention above) — via `mcp__obsidian-builtin__vault_read` (drift proposed by `/tidy`'s Vault-hygiene probe: over-cap ledgers, closed plans still resident, `_inbox` pile-ups, garbage files, a stale-`last_verified` tally). `/tidy` **proposes** but never bulk-deletes — disposal is this section's job (the **dispose** half of the drain-proposes / check-in-disposes split). If the file doesn't exist yet, say "no vault hygiene findings to review" and move on.

For each `### … - **Status:** open` entry, present its **Findings** list: which caps are exceeded and by how much, and the named garbage files / resident closed plans. For each finding the operator either:
- **acts** — carries out the maintenance (delete a garbage file, prune an over-cap ledger to its rolling window, archive + remove a resident closed plan, or run `/tidy` to clear an `_inbox` pile-up), then patch that entry's `Status` line to `resolved — <action taken>` with a direct `Edit`; or
- **dismisses** it (a false positive, or a cap deliberately exceeded for now) → patch the `Status` line to `dismissed: <one-line reason>`.

If there are no `open` entries, say "no vault hygiene findings to review" and move on. Disposed entries older than `CHECKIN_PRUNE_DAYS` days may be pruned.

### Review-queue dispositions (heat-score top-5)

Check 17 of `vault_hygiene_report.sh` (temperloop#240, ADR §2.6-2.7) ranks the notes in `Decisions/`, `Patterns/`, `Mistakes/`, `Context/`, and `Plans/` by heat × staleness and appends up to 5 `- info review-queue #<rank>: <path> — heat=<N> staleness=<N>d reads=<N> priority=<N>[<tag>]` lines inside the vault-hygiene entry's **Findings** block. These lines are **informational**, never an alarm on their own — the `--format entry` emitter drops the whole block (review-queue included) on a run where nothing else alarmed, so a quiet night carries no review-queue entries here at all. Reuse the vault-hygiene entry already read in the section above — don't re-read the surface.

Scan the Findings block of the most recent vault-hygiene entry — the same entry the section above just presented and disposed — for `review-queue #` lines, **regardless of what its `Status` line now says**: in the normal start-to-finish flow the section above has already flipped that entry to `resolved`/`dismissed` by the time this section runs, and that disposal covers the *alarms*, not this queue (the review-queue lines are informational riders on the entry, with no `Status` of their own — see below). Only the entry's recency matters, not its status. If the surface has no entries at all, or the most recent entry has no `review-queue #` lines (bare kernel checkout with no vault, or a run where nothing alarmed so no entry was appended), say "no review-queue entries to disburse" and move on.

For each review-queue note (rank, path, heat, staleness, reads, tag), present it, then the operator picks exactly one one-touch disposition — nothing auto-applies (propose/dispose, same as every section above):

- **re-verify** — the note is still accurate as-is. Read it (`mcp__obsidian-builtin__vault_read`), then rewrite it with its frontmatter `last_verified:` bumped to today via a full-file `mcp__obsidian-builtin__vault_write` (a frontmatter-scalar patch is unreliable on this MCP surface — it can report success while silently dropping the field — so rewrite the whole file, preserving everything else unchanged, rather than patch just the one line), and confirm the new date stuck with a follow-up `vault_read`.
- **promote** — the note deserves a standing reference from wherever its trigger actually fires, not just ambient vault presence. This is pinned to the T0-surface mechanism (temperloop#235/#240, ADR §2.7): promoting **never** edits the note itself (no frontmatter change, no content edit) — it stages a PROPOSED edit adding the note's `[[wikilink]]` or a backtick-delimited `` `<Folder>/<name>.md` `` reference to the specific rule in `claude/CLAUDE.kernel.md` (or the relevant command file, e.g. `claude/commands/<cmd>.md`, when the trigger is command-scoped rather than a standing CLAUDE.md rule) where the note's trigger fires — i.e. it edits the **composed doc's source**, never the note's frontmatter. **Check before proposing (idempotency):** a promoted note's heat is unchanged by promotion, so it can legitimately resurface in a later top-5 — before staging anything, `Grep` the target file (and `claude/CLAUDE.kernel.md` if the target is a command file) for an existing reference to the note (its `[[wikilink]]` or backticked path); if one is already present, say "already promoted — reference exists in `<file>` § `<section>`" and skip to the next disposition choice (or the next note) instead of proposing a duplicate. Otherwise, show the operator the exact rule/section and the proposed one-line addition; on confirmation, apply it with a direct `Edit`. Note for the operator: only a reference added inside `claude/CLAUDE.kernel.md` (or `claude/CLAUDE.overlay.md` on a composed install) is picked up by the T0 extractor — `workflows/scripts/install-claude-md.sh` re-derives `t0-inventory.txt` from the fully composed doc on the next compose run (`make install-claude` in the foundation fleet, i.e. a re-run of the `install-claude-md.sh` named above — a kernel checkout invokes the script directly), so a promotion landed only in a command file, with no matching kernel/overlay-rule reference, will not appear in T0 until it also gets a composed-doc anchor. Also note T0 itself only tracks `Decisions/`, `Patterns/`, `Mistakes/`, `Context/` references — a `Plans/` note surfaced by the review queue can still be promoted (its reference still lands in the rule prose) but will never appear in `t0-inventory.txt`, which is scoped to those four folders only.
- **consolidate** — the note's content belongs inside another, more canonical note. Ask the operator which note is canonical (search first via `mcp__obsidian__search_vault_smart` if not already named). Draft the merge, then **show the operator the proposed merged addition — the exact text to be added to the canonical note and where it lands — before writing anything** (the propose/dispose contract holds at content level, not just at the pick-a-disposition level; same show-then-apply shape as promote above). Only on their confirmation: write the merged content into the canonical note, then set `superseded_by: [[<canonical note>]]` in the retired note's own frontmatter via a full-file `vault_write` (same reliability reason as re-verify above) — leave the retired note in place with that pointer rather than deleting it, so any inbound link still resolves to an explanation instead of a dead reference.
- **retire** — the note is no longer worth keeping live. Move it to `_archive/<OriginFolder>/<filename>.md` (mirroring its origin folder under one top-level `_archive/`) via `mcp__obsidian-builtin__vault_move`; if that tool is unavailable, fall back to: `vault_read` the original's content, `vault_write` the copy at the new path, then **`vault_read` the new-path copy back and confirm it matches the original content before deleting anything** (same confirm-then-trust pattern as re-verify above — a silently failed or truncated write followed by a delete would destroy the only copy). Only after that confirmation, `mcp__obsidian-builtin__vault_delete` the original; if the read-back is missing or doesn't match, stop — leave the original in place, delete the bad copy if one landed, and report the failed move instead.

Record the disposition inline as you go (`re-verified`, `promoted → <rule>`, `consolidated → <canonical note>`, `retired`) so the Close summary below can report per-note actions taken. This queue carries no durable `Status` line of its own — unlike the append-only surfaces above, it is recomputed fresh from the vault's current state every run, not an accumulating queue that needs pruning.

### Environment hygiene review

Read the **environment-hygiene review surface** — `Pipeline/environment hygiene report.md`, falling back to the legacy `Context/pipeline - environment hygiene report.md` (path fallback convention above) — via `mcp__obsidian-builtin__vault_read` (drift proposed by `/tidy`'s Environment-hygiene probe: `env-reconcile.sh` classifies every local checkout, worktree, and launchd agent against its role's clean baseline). `/tidy` auto-heals only the safe in-lane classes (a leaked worktree, a cron checkout behind `main`) and **appends everything else here — report-only — mutating nothing**; disposal is this section's job (the **dispose** half of the drain-proposes / check-in-disposes split — the host-state sibling of § Vault hygiene above). If the file doesn't exist yet, say "no environment hygiene findings to review" and move on.

For each `### … - **Status:** open` entry, present its drift findings — the `⚠️` lines, each naming a drift class and its locus (a checkout path or an agent label): a **down or overdue LaunchAgent** (`AGENT_UNLOADED` — declared but not in `launchctl list`; `AGENT_STALE` — loaded but with no successful run within its cadence), a **foreign operator/consumer checkout** carrying `DIRTY` / `PARKED_ON_MERGED` / `STALE_UNTRACKED` (which may be another session's active lane), an un-auto-healed `LEAKED_WORKTREE`, or a config class (`ABSENT` / `NOT_A_REPO` / `MALFORMED_PLIST`). For each finding the operator either:
- **acts** — carries out the remedy (re-bootstrap a down agent from its own checkout, e.g. `make install-kiosk` or `launchctl bootstrap gui/$(id -u) <plist>`; hand a foreign dirty checkout back to its owning session; remove a confirmed-leaked worktree with `git -C <parent-repo> worktree remove`), then patch that entry's `Status` line to `resolved — <action taken>` with a direct `Edit`; or
- **dismisses** it (a false positive — e.g. a KeepAlive daemon with no cadence to be late against — or drift already handled elsewhere) → patch the `Status` line to `dismissed: <one-line reason>`.

**Never `launchctl load`/`unload` an agent, or `git checkout`/`reset`/`clean` a foreign checkout, mechanically from within this review** — reloading an agent out from under a possibly-running process, or resetting a checkout that may be another session's active lane, is exactly the foreign mutation `claude/CLAUDE.kernel.md` § Working-tree ownership and `/tidy`'s own report-only env-hygiene policy exist to avoid. This section *surfaces and records*; the operator acts deliberately.

If there are no `open` entries, say "no environment hygiene findings to review" and move on. Disposed entries older than `CHECKIN_PRUNE_DAYS` days may be pruned.

### Sensitivity flags review

Read the **sensitivity-flags surface** — `Pipeline/sensitivity flags.md`, falling back to the legacy `Context/pipeline - sensitivity flags.md` (path fallback convention above) — via `mcp__obsidian-builtin__vault_read`. `/tidy`'s mandatory sensitivity scan (its Step 2) parks a flag here whenever a stub appears to contain a secret (API key, token, password, PII) — the value is **never** copied, only the stub filename, the *kind* of secret, and its approximate location. On an unattended run the summary never reaches the operator, so this durable surface is how a possible leak in a session transcript reaches a human. If the file doesn't exist yet, say "no sensitivity flags" and move on.

For each `### … - **Status:** open` entry, present it: the stub, the kind of secret, and where. For each, the operator either:
- **redacts** — opens the flagged stub (archived at `~/dev/foundation/meta/sessions/archive/` once processed, or still in `Sessions/_inbox/` if not), removes/redacts the secret, and — if the secret is a live credential — **rotates it** — then patch that entry's `Status` line to `resolved — redacted[, rotated]` with a direct `Edit`; or
- **dismisses** it (a false positive — not actually a secret) → patch the `Status` line to `dismissed: <reason>`.

If there are no `open` entries, say "no sensitivity flags" and move on. This is security-relevant — do not defer an `open` credential flag casually.

## Part 3 — Priorities review (set the `/next` compass)

The durable priorities note per project — `Projects/<project>/Priorities.md`, falling back to the legacy `Priorities/<project>.md` (path fallback convention above) — carries the weighted themes, the definition of "impactful"/"done", and the avoid-now list that `/next` **reads** to recommend the next move. `/next` never writes them; **`/check-in` is where you set them.** This is the "set direction" half of the check-in.

1. **List the priorities notes.** Enumerate project names from **both** locations and take the **union**: `mcp__obsidian-builtin__vault_list "Projects"` (each `Projects/<project>/Priorities.md` contributes its `<project>`) **and** `mcp__obsidian-builtin__vault_list "Priorities"` (each `Priorities/<project>.md` contributes its `<project>`) — a list call whose folder doesn't exist contributes nothing, never fails the step. The union matters during a partial migration: a project whose note still lives only at the legacy path (or only at the new path) must still be enumerated — do **not** stop at the folder level. Then resolve each project's note individually per the path fallback convention above (new path first, then legacy). Skip `_template.md` / `_template`. Active projects: foundation, stageFind, ssmobile, subsetwiki, ….
2. **For each note**, read it and present the current standing guidance in one compact block: the weighted themes (top first), the definition of "impactful"/"done", and the avoid-now list.
3. **The operator adjusts or confirms.** For each project the operator either leaves the note as-is (confirm) or names changes (re-weight a theme, add/retire one, update the avoid-now list). Apply the named changes with a direct `Edit` on whichever path Step 1 resolved for that project (`Projects/<project>/Priorities.md` or the legacy `Priorities/<project>.md`), preserving the note's structure. Default to leaving a note untouched unless the operator asks to change it — priorities are standing weightings, not a daily rewrite.
4. **Missing note for an active project** → offer to scaffold it at `Projects/<project>/Priorities.md` from `Projects/_template/Priorities.md` (falling back to the legacy `Priorities/_template.md` if the new template path doesn't exist); fill in what the operator states; don't fail the review if they decline.
5. Keep this fast — most days most projects are confirmed unchanged. The value is the one project whose focus actually shifted.

## Close

Briefly summarize: pending decisions disposed (confirmed/overridden), pending activations discharged/still-pending, supersessions linked/dismissed, retro findings accepted/dismissed (or, if `/retro` wasn't installed, "retro review: skipped — see the Part 2 skip line above" — do not reprint the canonical skip string here; Part 2 already emitted it once for the run), candidate tells promoted/discarded, hygiene findings acted/dismissed, review-queue notes disposed (re-verified/promoted/consolidated/retired), sensitivity flags resolved, and which projects' priorities changed. One line each; then stop.
