---
description: Advisory "what do I do now" conductor for a guiding principle. Reads the board, `Plans/` notes, and the project priorities note, locates where the goal's work currently sits across the bug→PR pipeline, and recommends the single next move (a concrete command) plus a preview of the path ahead to "done". Caches its read in a per-session record so repeat calls don't reassess until state changes. Never mutates the board or runs other skills — it points you at them. Board-agnostic via `--board`; works in both the foundation and stageFind checkouts.
argument-hint: "[<guiding principle>] [--board <N>] [--refresh]"
---

You are running the **next** command. Goal: given a **guiding principle** (e.g. "complete the UI design"), tell the user the **single next move** that advances that goal — and preview the **path ahead** to done. You are a conductor, not a worker: you read state and recommend; you do **not** mutate the board or run `/triage` / `/assess` / `/build` — you point at them.

The "sequence" is not something you invent by scoring issues. It already exists — it is the **pipeline** in [[Decisions/foundation - Triage stage and the logical-technical pipeline split]]:

```
pending design / spike ─► /triage ─► epic ─► /assess ─► plan approved ─► /build ─► merged
   (decide it)            (Backlog→Ready)     (Plans/ note,        (you flip          (PRs, CI,
                                                status: draft)      status: approved)   close epic)
```

Given the goal, find where its in-scope work sits along that line, and the recommended move is the **earliest forward-blocking step** — the thing that, until done, holds up everything downstream of it.

## Inputs

- `<guiding principle>` (optional) — a natural-language focus, e.g. `complete the UI design`. **Narrows and overrides** the durable priorities note. If omitted, fall back to the top theme of `Projects/<project>/Priorities.md`, falling back in turn to the legacy `Priorities/<project>.md` (path fallback convention, `claude/commands/check-in.md`); if neither note exists, ask the user for a focus (one `AskUserQuestion`) rather than guessing.
- `--board <N>` (optional) — which board to read. **Default: detect from the current repo** — `<org>/foundation` → `4`, `<org>/stageFind` → `3` — via `git remote get-url origin` (fall back to the repo basename). **If detection doesn't resolve to a known board** (an unrecognized repo, or run outside a checkout) and no `--board` was given, **stop and tell the user to pass `--board <N>`** (`3`=stageFind, `4`=foundation, `5`=ssmobile, `6`=subsetwiki) — **never default to stageFind-`3`** (removed). Detecting the board from a *recognized* current repo is fine — that reads the checkout you're in, not a blind default; only the silent stageFind fallback is gone. Pass `--board` to override detection. (Mirrors `/triage`'s no-default rule; see [[Decisions/foundation - Triage requires an explicit board (no default)]].)
- `--refresh` (optional) — force a full reassessment even if a cached session record exists and state looks unchanged.

## Operating principles

- **Advisory only — never mutate.** You read the board (and `Plans/`, and the priorities note) and you recommend. You never flip a status, create an issue, write a plan note, or invoke another skill. Every board call you make is a *read* (`board_resolve` and the accessors, `gh issue view`, `gh api ... --jq`). The user stays in the loop at every pipeline hop — several of those hops (approving a plan, calling a design decision) are deliberately theirs.
- **One goal, one next move, plus the path ahead.** Output exactly one recommended action as a **concrete command** the user can run (`/assess --epic 24`, `/triage --board 3`, or "claim & work #220"), then the ordered **several hops** that follow to reach done. Don't hand back a ranked backlog — hand back the next step and the road.
- **Earliest forward-blocking step wins.** Walk the in-scope work in pipeline order; recommend the leftmost stage that is blocking. An unresolved design decision (`spike`) blocks everything specced after it; untriaged Backlog blocks assessment; an unassessed epic blocks `/build`; an unapproved plan blocks execution. Don't recommend a later-stage move while an earlier-stage blocker for the same goal is open. **An open GitHub native `blocked_by` dependency is itself an explicit blocker** — an item carrying one is never the recommended move regardless of its status; surface it as blocked and recommend the next non-blocked move around it (foundation #137).
- **Cache the read; don't reassess every call.** The first call for a session does the full read and writes a session record (`Sequencing/<id8>.md`). Repeat calls **reuse** it — re-present the same move — until the recorded state fingerprint no longer matches, the recommended move is done, or `--refresh` is passed. This is the whole point of the command: cheap, consistent answers within a session.
- **Sessions are lanes; don't double-book.** Read other **active** session records before recommending. If another session already owns the lane your move would touch (same epic / same plan / same issue), say so and recommend the next non-overlapping move instead — parallel sessions with different principles should not both drive the same work.
- **The board (and `Plans/`) carry the truth — the record is just a cache.** Never treat the session record as authoritative state. It is a memo of "what I told you last and the state I saw"; on reuse you re-check the live fingerprint, and on any mismatch you reassess from the board.
- **Records are ephemeral.** A session record exists only while its session is alive. The `session-end-seq-cleanup.sh` SessionEnd hook deletes it deterministically when the session ends; Step 0.5 here is the crash-safety backstop for a missed fire. Never leave a record for a session that is gone.

## Step 0 — Validate & orient

Run in parallel where possible:

1. Confirm `mcp__obsidian-builtin__*` (read/write/delete) and `mcp__obsidian__*` (smart search) tools are loaded — needed to read the priorities note, read/write the session record, and coordinate across sessions. If Obsidian is unreachable, you can still give a **one-shot advisory** from the board alone — warn that you cannot cache or coordinate across sessions (see Failure modes). (The priorities note — `Projects/<project>/Priorities.md`, falling back to the legacy `Priorities/<project>.md` (path fallback convention, `claude/commands/check-in.md`) — plus `Plans/`, `Sequencing/<id8>.md` and other document paths below are relative to **the knowledge store root**, resolved per `workflows/scripts/lib/knowledge_store.contract.md`. The agent-plane transport stays on Obsidian MCP tools — including `search_vault_smart` for fuzzy matching, Step 3 below — per that contract's Obsidian-mode note.)
2. `gh auth status` — must list the **`project`** scope (board reads need it). If missing, stop with: "run `gh auth refresh -s project`".
3. **Locate the board adapter, resolve the board.** Set `BOARD_LIB` = the first of `scripts/lib/board.sh` (a board-consuming repo like stageFind) or `workflows/scripts/board/lib/board.sh` (foundation) that exists — the same probe `/triage` Step 0 uses. If neither exists, degrade to a **plans + priorities only** advisory (no board) and say so. Resolve the board number from `--board`, else detect from `git remote get-url origin` (`foundation`→4, `stageFind`→3). **If neither resolves a known board** (no `--board` and an unrecognized/absent remote), **STOP** with `/next: cannot determine the board — pass --board <N> (3=stageFind, 4=foundation, 5=ssmobile, 6=subsetwiki)`; do **not** default to stageFind-`3` (removed). Detecting from a recognized current repo reads the checkout you're in, not a blind default — only the silent stageFind fallback is gone. Let `repo="$(board_repo "$BOARD")"` and `project` = its basename (`stageFind` / `foundation`) — this is the `<project>` for the priorities note (`Projects/<project>/Priorities.md`, falling back to the legacy `Priorities/<project>.md`) and the record tag. **`source "$BOARD_LIB"`** at the top of every board bash block.
4. **Capture this session's id.** Read the 8-char id from the `<session-id>…</session-id>` tag injected into your initial context by the SessionStart hook. This is the record filename (`Sequencing/<id8>.md`) and the lane identity. If the tag is absent (older session / hook miss), generate a stable label from `hostname -s` + start time and note that cross-session coordination is degraded.
5. **Source the batch-pipeline config (best-effort).** `source workflows/scripts/build/build.config.sh` (bare repo-relative, the kernel's Step-0 config-sourcing convention — `~/.claude/CLAUDE.md` § Prose-resident knob convention). This pulls the Step 0.5 orphan-record staleness knob (`NEXT_SEQ_STALE_AFTER`) into scope, with any pre-set env value still overriding. If the file isn't found, proceed — Step 0.5 keeps its inline `${VAR:-default}` fallback.

If a hard check fails (`project` scope), surface in one line and stop. Soft degradations (no Obsidian, no board) continue with reduced scope.

## Step 0.5 — Prune orphan records (best-effort backstop)

List `Sequencing/*.md` (`mcp__obsidian-builtin__vault_list`). The SessionEnd hook is the deterministic deleter; this is only the crash-safety net. Delete any record whose `date`/last-touched frontmatter is older than the staleness threshold `${NEXT_SEQ_STALE_AFTER:-64800}` — a session that old is not still running. Do **not** delete other sessions' *recent* records; those are presumed active and are read in Step 2 for lane coordination. Best-effort: a delete failure is logged in the summary, never fatal.

## Step 1 — Reuse-or-reassess gate

Load this session's `Sequencing/<id8>.md` (`mcp__obsidian-builtin__vault_read`) if it exists.

**Reuse** (re-present the cached move and **stop**) when **all** hold: the record exists, `--refresh` was not passed, no new `<guiding principle>` was given that differs from the recorded one, the recommended move is **not yet done**, and the recorded **state fingerprint still matches** current state. To check the fingerprint cheaply: `board_resolve "$BOARD"` once and re-read just the in-scope items the record names — confirm their statuses are unchanged and the recommended move's target is still where it was (epic still unassessed, plan still unapproved, issue still Ready, etc.). On a match, jump to Step 6 and re-present.

**Reassess** (continue to Step 2) otherwise: no record, `--refresh`, a new/changed principle, the move's target advanced (e.g. the epic got assessed, the plan got approved or merged, the issue got claimed by another session), or any in-scope status drifted. Reassessment overwrites the record in Step 5.

## Step 2 — Gather guidance & lanes

1. **Durable priorities.** Read `Projects/<project>/Priorities.md` via `mcp__obsidian-builtin__vault_read`; if that read fails (file absent), fall back to the legacy `Priorities/<project>.md` (path fallback convention, `claude/commands/check-in.md`) — its weighted themes, definition of "impactful"/"done", and avoid-now list. If **both** are missing, offer to scaffold it from the template (`Projects/_template/Priorities.md`, falling back to `Priorities/_template.md`) and proceed using the passed-in principle alone.
2. **The guiding principle.** The `<guiding principle>` arg, if given, narrows/overrides the priorities note (the note is the standing weighting; the arg is this session's focus).
3. **Active lanes.** Read the *other* recent `Sequencing/*.md` records (from Step 0.5's list, minus this session's, minus pruned). Note each one's principle and the work it owns (its recommended-move target + path-ahead items) so Step 4 can avoid double-booking.

## Step 3 — Read pipeline state for the goal (read-only)

`board_resolve "$BOARD"` once (one `project view` + `field-list` + `item-list` — don't re-list per item; honor the GraphQL-budget discipline `/triage` follows). From `BOARD_ITEMS_JSON` and targeted reads, gather the goal's work at each pipeline stage:

- **Ready singletons** — items with `.status == Ready` (`BOARD_OPT_READY`) and **no parent epic**. Check parentage via `board_parent_issue "$BOARD" <n>` (prints the parent epic's number for a sub-issue, empty for a singleton); empty = a directly-workable singleton. **Do not** read a bare `.parent` field off the REST issue object — there is none; the parent link is `.parent_issue_url` and `.parent` resolves empty for *every* issue, silently mis-classifying every epic child as a singleton (foundation #159). The adapter owns the field name. **Then check it is not blocked:** if `board_blocked_by_open "$BOARD" <n>` prints anything, the item has an open GitHub native `blocked_by` dependency — mark it *blocked* (record its blocker numbers) and drop it from the actionable set; it is not a recommendable move until its blocker closes. **And check it is not awaiting a clarification:** if the issue carries the `needs-clarification` label, a `/sweep` Phase-1 question is open on it — it is parked (left in `Ready`, #435) until answered, so drop it from the actionable set the same way (it re-enters `/sweep` Phase 1; its answer clears the label). The label, not a status bucket, is the open-question gate — the retired `Blocked` Status (#435) is gone. **And check it is not a funnel escalation:** if the issue carries the `funnel-escalated` label (foundation #697), the autonomous funnel's rung-5c merge tier could not land it (route-refused / terminally-red CI) — it has an open/failed PR and awaits your **manual merge or close**, so drop it from the actionable set the same way (surface it as escalated; the label clears when **you** close the issue or remove the label — closing/merging the PR alone does not remove an issue label). It is a distinct gate from `needs-clarification`: a funnel escalation is not a question to answer.
- **Epics & their state** — parent issues with native sub-issues (`gh api repos/$repo/issues/<n>/sub_issues`). For each in-scope epic, determine whether it has been assessed yet (is there a matching `Plans/` note? — Step below) and the open/closed count of its children. When picking an epic's next workable leg, **skip children with an open `board_blocked_by_open`** — a blocked child is not the next move.
- **Blocked items (any stage)** — gate every in-scope candidate (singleton or epic leg) on `board_blocked_by_open`; this is one live REST call per candidate (REST's budget, not the GraphQL board budget), so run it on the in-scope set only, never the whole board. A non-empty result means the dependency graph — not a parking status — is what holds the item; recommend *around* it (foundation #137).
- **Pending design / spikes** — `spike`-labelled issues (`gh issue list -R "$repo" --label spike`) and any items the priorities/principle frame as "decide X". These block specccing of work downstream of them.
- **Backlog needing triage** — in-scope items still in `Backlog` (`BOARD_OPT_BACKLOG`): they must go through `/triage` before they can become epics/Ready.
- **`Plans/` notes** — `mcp__obsidian-builtin__vault_list "Plans/"`, read the `status:` of in-scope ones (`draft` / `approved` / `executing` / `done`) and which epic each decomposes. A `draft` plan waits on the user's approval; an `approved` plan is ready for `/build`; an `executing` plan is already in flight.

**Scope to the goal semantically** — match titles, bodies, labels, and area against the guiding principle (use `mcp__obsidian__search_vault_smart` for fuzzy matching against plan/decision notes where useful). When unsure whether an item is in scope, lean toward including it and note the uncertainty.

## Step 4 — Locate the next move + path ahead

Order the in-scope work by pipeline stage (leftmost = earliest). The **recommended move** is the earliest stage with open work for this goal, expressed as a concrete command:

| Earliest open stage for the goal | Recommended move |
|---|---|
| Unresolved design decision / `spike` | Present the decision for the user's verdict (it's theirs — don't call it). It blocks everything specced after it. |
| In-scope items still in Backlog | `/triage --board <N>` — turn them into epics / Ready singletons. |
| Triaged epic with no plan note | `/assess --epic <N> [--board <N>]` — decompose to a `Plans/` note. |
| `Plans/` note `status: draft` | **You** review and flip it to `status: approved` (the gate is yours). |
| `Plans/` note `status: approved` | `/build <plan-note-path>` — execute it. |
| `Plans/` note `status: executing` | In flight — recommend monitoring / resuming `/build`, not a new move. |
| Ready singleton, no plan needed | Claim & work `#<n>` directly (`claim.sh <n> --board <N>`, then do the work). |
| Ready item / epic leg with an open `blocked_by` | **Not actionable** — show it as blocked (`blocked_by #M`) and recommend the next non-blocked move *around* it. It becomes eligible automatically when #M closes. |
| Ready item carrying `needs-clarification` | **Not actionable** — an open clarification parks it (it stays in `Ready`, #435); surface it as awaiting-clarification and recommend around it. It becomes workable when the label is cleared (answered in `/sweep` Phase 1 or `/assess`). |
| Ready item carrying `funnel-escalated` | **Not actionable** — the autonomous funnel's 5c merge tier could not land it (route-refused / terminally-red CI); it has an open/failed PR and awaits your manual merge or close (#697). Surface it as escalated and recommend around it. It clears when you close the issue or remove the label (closing/merging the PR alone does not remove an issue label). |

If another **active lane** (Step 2) already owns that move's target, skip to the next non-overlapping in-scope move and note the collision. Likewise, never recommend an item with an open `blocked_by`, a `needs-clarification` label, **or a `funnel-escalated` label** — surface it (blocked / awaiting-clarification / escalated) and recommend around it (same "recommend around it" handling as a lane collision).

**Path ahead** = the ordered hops that follow the recommended move to reach "done" for this goal (e.g. *assess epic #24 → approve its plan → `/build` → 3 PRs merge → epic closes*). Keep it to the handful of real next steps, not an exhaustive tree.

## Step 5 — Write the session record

Create/update `Sequencing/<id8>.md` via `mcp__obsidian-builtin__vault_write` (skip silently if Obsidian was unreachable — Step 0.1):

```markdown
---
tags: [sequencing, project/<project>]
session: <id8>
board: <N>
date: <YYYY-MM-DD today>
principle: "<guiding principle>"
status: active
---

# /next — <project> · <guiding principle>

## Recommended next move
`<concrete command>` — <one-line rationale: which stage, why it's the blocker>.

## Path ahead
1. <hop> 2. <hop> 3. <hop> …  → done

## State fingerprint
<!-- the in-scope items + their statuses this read was based on; Step 1 re-checks these -->
- #<n> <title> — <stage/status>
- plan "<note>" — <status>
- …

## Active-lane notes
<any overlap with other sessions, or "none">
```

The fingerprint section is load-bearing: Step 1's reuse gate re-reads exactly these items to decide reuse vs reassess. Keep it to the items the recommendation actually depends on.

## Step 6 — Present (advisory)

Output, concisely:

```
/next — <project> (board <N>) · "<guiding principle>"

▶ Next: <concrete command>
  <one-line rationale — which pipeline stage, why it's the blocker>

  Path ahead: <hop> → <hop> → <hop> → done

  [if applicable] ⚠ Lane note: session <other-id8> is already on <target> — recommending around it.
  [if applicable] ⚠ Blocked: #<n> is blocked_by #<m> (open) — skipped; eligible when #<m> closes.
  [if applicable] ⚠ Awaiting clarification: #<n> carries needs-clarification — parked on an open question; skipped until answered (in /sweep Phase 1 or /assess).
  [if applicable] ⚠ Escalated: #<n> carries funnel-escalated — the funnel's 5c merge tier couldn't land it (open/failed PR); skipped until you manually merge or close it.
  [if reused] (cached read from <time>; run /next --refresh to reassess)
```

Then **stop**. Do not run the recommended command — that is the user's call. If they want it run, they invoke it themselves (or ask).

## Failure modes

- **`project` scope missing.** Stop at Step 0 with the `gh auth refresh -s project` hint.
- **Obsidian unreachable.** You can't read the priorities note, cache a record, or coordinate lanes. Give a **one-shot board-only advisory** (Steps 3–4, 6) and warn: "Obsidian unreachable — advisory only, not cached; parallel-session coordination is off." Never fail the whole command over it.
- **Board can't be determined.** If no `--board` is passed and `git remote get-url origin` doesn't resolve to a known board repo (`foundation`/`stageFind`), stop with `/next: cannot determine the board — pass --board <N> (3=stageFind, 4=foundation, 5=ssmobile, 6=subsetwiki)`. Never default to stageFind-`3` (removed). Detecting the board from a *recognized* current repo is fine; only the blind fallback is gone. (Distinct from **No board adapter** below, which degrades to a plans+priorities advisory rather than stopping.)
- **No board adapter (`BOARD_LIB` not found).** Degrade to a **plans + priorities only** advisory — read `Plans/` statuses and the priorities note, recommend the earliest plan-stage move, and say board-derived stages (triage/epic/singleton) were skipped.
- **No in-scope work found.** Say so plainly and suggest broadening the principle, checking a different board, or that the goal may already be done. Don't manufacture a move.
- **Priorities note missing (both new and legacy paths).** Proceed with the passed-in principle; offer to scaffold `Projects/<project>/Priorities.md` from the template (falling back to the legacy `Priorities/<project>.md` location if `Projects/` doesn't exist yet). If neither a principle nor a note exists, ask for a focus (one `AskUserQuestion`).
- **No `<session-id>` tag.** Coordination degrades (can't key the record to a real session). Use a hostname+time label, note the degradation, and rely on Step 0.5's staleness prune for cleanup.
- **Stale/duplicate records.** Step 0.5 prunes orphans older than `NEXT_SEQ_STALE_AFTER`; the SessionEnd hook is the primary deleter. If you spot a record for a session you know ended, prune it and note it — don't read stale lanes as active.
