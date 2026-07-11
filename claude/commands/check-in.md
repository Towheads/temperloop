---
description: Daily human check-in — review the overnight machine output and set direction. Render the telemetry brief (status readout), dispose the pipeline surfaces `/tidy` and the funnel parked overnight (pending-decisions, proposed-supersessions, retro-findings, candidate-tells, vault-hygiene, sensitivity-flags), then review/set the `/next` priorities for every project.
---

You are running the **check-in** command — the daily human driver's-seat review. Overnight, unattended machinery (`/tidy`, the funnel cron, `/build --unattended`, `/retro`) did work and **parked everything needing human judgment** on durable surfaces. `/check-in` is where a person clears those queues and sets direction. Three parts: **① a status readout** (telemetry brief), **② dispose the overnight queues**, **③ review/set the `/next` priorities per project**. Be concise.

This is the **operator-disposes** half of the drain-proposes / operator-disposes split: the pipeline surfaces are **append-only**, written by the unattended machinery, and `/check-in` is their **sole `Status` mutator**. (The personal daily plan — calendar, inbox-zero, slots, Today — is a *separate* activity: `/standup`, an overlay command. `/check-in` reviews the machine; `/standup` plans the day.)

Throughout, surface files (`Context/pipeline - *.md`, `Priorities/<project>.md`) are relative to **the knowledge store root**, resolved per `workflows/scripts/lib/knowledge_store.contract.md`. **Path fallback convention** (stated once here — canonical for all six command surfaces, referenced by name as "path fallback convention" from `next.md`, `assess.md`, `build.md`, `tidy.md`, `sweep.md`): the overlay reorg (epic #226) is moving these to `Projects/<project>/Priorities.md` and `Pipeline/<surface>.md`, but the kernel must not assume that move has landed yet (#226's consumes-clause). Every read of one of these paths tries the **new** path first (`Projects/<project>/Priorities.md`, `Pipeline/<surface>.md`); if that read/list comes back absent, try the **legacy** path (`Priorities/<project>.md`, `Context/pipeline - <surface>.md`); if **both** are absent, fall back to that site's own existing missing-file behavior (scaffold-offer, "say and move on", etc.), unchanged. A write (`Edit`/`vault_append`) that follows a resolving read always targets whichever path that read just resolved — never write a fresh copy at the other location. **Append-target resolution rule** (for the `vault_append` writer sites in `build.md`, `tidy.md`, and `sweep.md`, which have **no** preceding resolving read and may auto-create their target — referenced per-site as "append-target resolution"): before appending, do an explicit both-paths existence check and pin the append to the file that **already exists** — the legacy file when only it exists, the new-path file when only it exists; if both somehow exist, append to the new path (the same file the read above resolves — never fork the two entry streams). When **neither** exists, create at the **legacy** path; the new path becomes the creation target only once the overlay reorg has landed — i.e. its parent folder (`Pipeline/`, or `Projects/<project>/` for a priorities note) already exists in the knowledge store. **Invariant: an append must never create a new-path file while a legacy-path sibling exists** — that would silently orphan the legacy file's open entries, because every reader stops at the new path once it exists. Read via `mcp__obsidian-builtin__vault_read`; mutate a `Status` line via a direct `Edit` on the store file (the store is a local folder under the `plain-files` backend). `/check-in` is the **only** mutator of these `Status` lines — the append-only discipline the surfaces depend on.

## Part 1 — Telemetry brief (status readout)

Lead with the push-surface telemetry digest — "what needs me" should open the review. This uses the **overlay** telemetry renderer, so render it **only if present** (a composed install has it; a kernel-only checkout does not):

```sh
if [ -f workflows/scripts/build_telemetry_brief.py ]; then
  python3 workflows/scripts/build_telemetry_brief.py
fi
```

If the script exists, show its output **verbatim** as the first thing in the session — it leads with **data age** and alarms loudly if the rollups are stale (past 24h). If it prints `DATA STALE` or `DATA AGE: UNKNOWN`, call that out as your opening line before anything else, since it means the rest of the brief (and other telemetry-backed surfaces) can't be trusted right now. Do not summarize or drop the data-age line — paste the markdown as-is. If the script is **absent** (kernel-only checkout, no telemetry rollups), skip Part 1 with a one-line note (`telemetry brief unavailable — no renderer in this checkout`) and continue.

## Part 2 — Dispose the overnight queues

**Source the batch-pipeline config (best-effort), once, before this part.** `source workflows/scripts/build/build.config.sh` (bare repo-relative, the kernel's Step-0 config-sourcing convention — `~/.claude/CLAUDE.md` § Prose-resident knob convention). This pulls the prune-window knob (`CHECKIN_PRUNE_DAYS`, referenced below) into scope, with any pre-set env value still overriding. If the file isn't found, the sections below fall back to the `${CHECKIN_PRUNE_DAYS:-30}` inline default.

Each subsection reads one append-only surface and disposes its `### … - **Status:** open` entries. For every surface: if the file doesn't exist, say so in one line and move on. Resolved entries older than `CHECKIN_PRUNE_DAYS` days may be pruned. `/check-in` is the **sole mutator** of every `Status` line below.

### Pending decisions review

Read the **unattended pending-decisions surface** — `Pipeline/pending decisions.md`, falling back to the legacy `Context/pipeline - pending decisions.md` (path fallback convention above) — via `mcp__obsidian-builtin__vault_read`. This is the cross-run inbox where `batch-at-ritual` questions land when a batch-pipeline command (`build` Step 1.5/1.7/4b/4d, `assess` Step 6, `tidy`'s stale-claim sweep, `sweep` Step 2) ran **unattended / mini / cron** with no live operator and took its safe default to keep moving (see `claude/CLAUDE.md` § Unattended pending-decisions surface).

For each `### … - **Status:** open` entry, present it in one compact list: the decision, the **default that was auto-taken** on the operator's behalf, and when/which run took it. For each, the operator either:
- **confirms** the default was right → patch that entry's `Status` line to `resolved — confirmed` with a direct `Edit`; or
- **overrides** it → patch the `Status` line to `resolved — overridden: <action>` and carry out (or queue as a Things task) the override action they named.

If there are no `open` entries, say "no pending decisions" in one line and move on. This is what stops an unattended run's defaulted decision from silently standing.

### Proposed-supersessions review

Read the **proposed-supersessions surface** — `Pipeline/proposed supersessions.md`, falling back to the legacy `Context/pipeline - proposed supersessions.md` (path fallback convention above) — via `mcp__obsidian-builtin__vault_read` (cross-session contradictions surfaced by `/tidy`'s contradiction detector). If the file doesn't exist yet, say "no proposed supersessions" and move on. A supersession proposal has **no "default taken"** — it is flagged for judgment, not an auto-disposition.

For each `### … - **Status:** open` entry, present it: the two notes (`D_new` / `D_prior`), the proposed **direction**, and the one-line contradiction. For each, the operator either:
- **confirms** the supersession → hand-add the `[[wikilink]]` to the superseded note + a one-line supersession sentence in the **winning** note (the convention stays human-owned — the detector never edits a banked note), then patch that entry's `Status` line to `resolved — linked` with a direct `Edit`; or
- **dismisses** it (a false positive — refinement, not contradiction) → patch the `Status` line to `resolved — dismissed: <reason>`.

If there are no `open` entries, say "no proposed supersessions" and move on.

### Retro findings review

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

Briefly summarize: pending decisions disposed (confirmed/overridden), supersessions linked/dismissed, retro findings accepted/dismissed, candidate tells promoted/discarded, hygiene findings acted/dismissed, sensitivity flags resolved, and which projects' priorities changed. One line each; then stop.
