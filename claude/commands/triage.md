---
description: Logical-judgment front door of the bug→PR pipeline. Sweeps a board's Backlog (and optionally ingests analysis docs) and runs the logical decision tree — cull → root-cause collapse → group-by-meaning → value/priority → route decision-only items off-board — then materialises survivors as board-native epics (parent issue + native sub-issues), labels spikes, sets Seq, and flips grouped survivors Backlog→Ready (= triaged). Hands each epic to `/assess --epic N`. Optionally (`--feedback`) ends by walking the operator's pending-feedback queue — the issues parked on *them* — one at a time so they can answer in one batched sitting; `--feedback-only` runs that queue walk alone, skipping the sweep entirely. Infers the board from the local repo when `--board` is omitted; exits only if the repo is unmapped.
argument-hint: "[--board <N> | --project <name>] [<analysis-doc-paths>...] [--dry-run] [--feedback] [--feedback-only]"
---

You are running the **triage** command. Goal: take everything sitting in a board's **Backlog** (plus, optionally, analysis docs that haven't been filed yet) and make the **logical** decisions about it — *what survives* and *what belongs together* — then record those decisions as durable board state: one **epic** per logical group, survivors linked as native GitHub **sub-issues**, grouped survivors flipped **Backlog → Ready** (= triaged). This is the front door of the funnel in [[Decisions/foundation - Triage stage and the logical-technical pipeline split]]:

```
capture.sh (bugs) ┐
sweeps / audits   ┼─► /triage      cull → collapse → group → epic + sub-issues (Backlog→Ready)
loose Backlog     ┘
                                                                    │
a design conversation ──► /workshop   intake → coverage walk → review pass → ratify → materialize
                                                                    │
                                                                    ▼
                                              board epic (## Contract, design-brief: marker)
                                                                    │
                                                                    └─► /assess --epic N   (technical: seams, depends-on/after edges, levels → Plans/ note)
                                                                            └─► /build        (execution lifecycle; claims, merges, closes the epic on last child)
```

`/workshop` is the funnel's second front door — for **invented** work rather
than the discovered work triage sweeps. Both doors converge on the same
`/assess --epic N` → `/build` pipeline; see the Mirror-redirect note below
for how triage hands off invented work that lands at its door instead.

**Triage is logical judgment only.** It decides survival and meaning-grouping. It does **not** decide *how* anything builds — contract/seam scoping, `depends-on` (merge-safety) and `after:` (logical-order) edges, dependency levels, and spike-wiring all belong to `/assess` (companion **#22** adds its `--epic N` source mode). Epic *death* belongs to `/build` (companion **#23** adds epic auto-close). Triage owns epic **birth** and membership; that's the whole job.

**Triage births epics from loose findings — it does NOT decompose a pre-designed epic (foundation #526).** Triage materialises sub-issues only when it culls/groups **loose findings** (Backlog items, sweep docs) into a *new* epic. It has **no** path to take an *already-existing*, fully-specified epic and expand it into sub-issues — so running `/triage` on a tier-N>1 epic that was authored with a rich `## Contract` body but **zero sub-issues by design** (the per-tier *"sub-issues authored when the tier approaches"* pattern) does nothing useful. **That decomposition is `/assess`'s job** — its **epic-decomposition mode** reads the epic's `## Contract` and authors the seam-scoped items (`/build` then mints the sub-issues under the existing epic). If you land here trying to decompose a designed epic, run `/assess --epic N`, not `/triage`. See [[Decisions/foundation - Assess epic-decomposition mode (who authors sub-issues for a designed epic)]].

**Mirror redirect: invented work arriving at triage's door (temperloop#218).** Triage's Backlog is for *discovered* work; a candidate that instead reads as **invented** — a new capability, a "we should build X" idea, filed straight to Backlog rather than walked through `/workshop` — is `/workshop`'s material, not triage's, whenever it is epic-sized (`claude/CLAUDE.kernel.md` § Design-first default for invented work — the same threshold as § Task workflow's "Decompose epic-sized work up front"). Don't cull or triage it as a defect: flag it in the Step 3.5 preview / Step 5 summary — `candidate #<n> reads as invented, epic-sized work — recommend /workshop instead of triaging it here` — and let the operator decide at the Step 4 write gate whether to run `/workshop` on it first. A small invented idea below the epic threshold needs no redirect; triage it as a normal singleton.

## Inputs

- `--board <N>` / `--project <name>` (**optional — at most one**) — which board's Backlog to sweep (`3` = stageFind, `4` = foundation, `5` = ssmobile, `6` = subsetwiki, `7` = temperloop kernel; every Projects-v2-backed board is migrated onto GitHub's built-in `Status` field per [[Decisions/foundation - Migrate board #4 onto Status field|GH #340]] — board 7 is an issues-only backend with no Projects-v2 `Status` field, emulating Status via `fnd:status:*` labels, see `workflows/scripts/board/ISSUES-ONLY-BACKEND.md`). Explicit `--board`/`--project` is **preferred**; if omitted, the board is **inferred from the local repo** (see Step 0.3). Inference is bounded to the repo you're standing in — it can only resolve to that repo's registered board, so it cannot silently act on an *unintended* board. The prior stageFind-`3` arbitrary default is still gone; this is context-derived inference, a different thing. (See [[Decisions/foundation - Triage requires an explicit board (no default)]] — superseded by foundation#547's inference rule.)
- `$1...$N` (optional) — vault paths to analysis docs (`Sweeps/…`, `Issues/…`, audits) to ingest as a **second intake adapter** alongside the board Backlog. Findings from a doc that survive triage get a GitHub issue created (front-loading the creation `/build` would otherwise do late).
- `--dry-run` (optional) — rehearsal: validate + intake + run the decision tree, then **print** the planned board mutations with **zero** writes. See Step 3.5.
- `--feedback` (optional, **off by default**) — after the sweep, run **Step 6**: walk the **pending-feedback queue** — every open issue on this board's repo *assigned to you* and carrying `needs-clarification`, `decision`, or `funnel-escalated` — one at a time, with context, so you can answer them in one sitting instead of each in isolation. Interactive by nature; composes with `--dry-run` (prints the queue, answers nothing).
- `--feedback-only` (optional) — run **Step 6 alone**: skip Step 0.4's board resolve, Step 0.6's intake, and Steps 1–5 entirely. Implies `--feedback` (passing both is redundant, not an error). Use it to clear your queue **without** running a board-mutating sweep just to answer a few questions. **This is the cheap path, not merely the non-mutating one:** Step 6 needs only `board_repo` (a static map lookup, zero API cost) and per-item `board_parent_issue` (REST, no prior resolve), and never reads `BOARD_ITEMS_JSON` — so skipping `board_resolve` turns a whole-board `project view` + `field-list` + `item-list --limit 200` into **zero** board reads, off the shared 5,000-pt/hr Projects-v2 GraphQL budget (GH #396/#40). Composes with `--dry-run`. **Passing analysis-doc paths alongside it is a usage error** — the docs would be silently ignored (see Failure modes).

## Operating principles

- **Logical, not technical.** Group by **meaning / shared root cause**, never by "these touch the same file" — that is a *physical* fact and a `/assess` merge edge, explicitly **not** a triage grouping reason. Never compute or store edges/levels here; they churn every assess run and live in the plan note, not on the board.
- **Membership is durable board state.** The epic↔child link is a native GitHub **sub-issue** relationship — status-orthogonal, GitHub-maintained, and surviving renames/board-moves. It is the one durable record triage produces. Reuse the REST sub-issues API exactly as `/build` Step 2.6 does (see [[Decisions/foundation - build board integration]]).
- **One epic = one logical group.** A lone survivor gets **no** epic — it is routed at Step 4 per its phase (active phase → Backlog→Ready; inactive phase → stays Backlog and defers), exactly as a grouped survivor is (see Step 2.7 / Step 4.7). Only ≥2 grouped survivors warrant a parent.
- **Default to culling.** Better five sharp survivors than twelve mushy ones. A Backlog item that is a dupe, won't-fix, stale, or already-fixed should leave the Backlog, not get grouped.
- **Stay in the orchestrator for judgment.** The decision tree is the cognitive core — keep it in the parent context. Subagents are read-only and only for the Step 3 sanity pass.
- **Capture-don't-ask board governance, but gate outward writes once.** Per [[Decisions/stageFind - Task workflow (board + WIP-3 gate)]], don't pepper the user with per-item questions. But issue/epic *creation* and culls that *close* issues are real outward writes — surface the full set once, in batch, at Step 4's gate before they fire.
- **The board carries all state — no sentinel file.** Triage reads only `Backlog` items, so already-triaged items (`Ready`+) are naturally excluded on re-run. **Deferral to a future release phase is now an intake *filter*, not a `Parked` Status bucket** ([[Decisions/foundation - Active-milestone intake filter (supersedes Parked-status parking)]], foundation #208, superseding the `Parked`-status parking of foundation #97): a milestone carries one bit — active vs inactive (default **inactive**), stored as a machine-owned `<!-- triage:active -->` marker in its GitHub description and read via `board_active_milestones <board>`. A Backlog item whose milestone is **inactive** is invisible to intake (Step 1, Adapter A) and defers implicitly — it stays in `Backlog` and re-enters the next sweep automatically when its phase is activated (`milestone activate "<phase>"` stamps the marker active), with **no `Parked` move, label, comment, or status dance**. There is no `Parked` Status bucket any more. **A second naturally-excluded bucket: a Backlog item with an open GitHub native `blocked_by` dependency** (Step 1, Adapter A) — it stays in Backlog but is skipped from intake until its blocker closes, at which point it re-enters the next sweep automatically (the dependency graph is the gate; foundation #137). Epic and doc-issue creation are **probe-before-create**, so a re-run adopts existing artifacts rather than duplicating. Triage is idempotent without an in-band ledger. The flip side of Backlog-only intake: **the one way to re-queue a `Ready`+ item for re-triage is to flip its `Status` back to `Backlog`** — a label or comment does not re-enter the funnel. That is the contract `/assess` routes persistent re-triage signals through (#44).
- **Post-triage, every survivor belongs to a release phase (milestone).** Triage *assigns* a phase to any **unmilestoned** survivor (per-item judgment, surfaced at the Step-4 write gate, written via `board_set_milestone`). The phase is a free, **concurrent** grouping label — there is no single designated "current/default" phase; pick the right phase for each survivor on its merits. Whether a survivor then *proceeds now* or *defers* turns on whether its phase is active (Step 4 routing), not on a separate status.

## Step 0 — Validate

**`--feedback-only` takes a reduced path through this step.** Do these two things, in order, then jump straight to Step 6:

- **0a. Reject contradictory doc paths — check this FIRST, before anything else.** If `$1..$N` is non-empty, STOP with: `/triage: --feedback-only runs the pending-feedback queue alone — it does not ingest analysis docs. Drop the doc paths, or drop --feedback-only to sweep them.` Doc intake is Step 1, which this flag skips, so honouring half the invocation would let the operator believe a sweep ingested them. This check lives **here**, at the point it fires — the Failure-modes entry below is its recap, not its trigger.
- **0b. Run items 2 and 3 ONLY** (with item 2's scope rule relaxed per its own bullet).

Items 1, 4 and 5 are skipped: item 1 (Obsidian tools) serves doc intake and decision-route notes, item 4 (`board_resolve`) is the whole-board read the sweep needs, item 5 validates doc paths — Step 6 uses none of them. Skipping item 4 in particular is the flag's whole point: it is the expensive Projects-v2 read, and Step 6 needs only `board_repo` (a static map lookup) plus per-item `board_parent_issue` (REST, no prior resolve).

Run in parallel:

1. Confirm `mcp__obsidian__*` tools are loaded (needed for doc intake and decision-route notes). If no docs are passed and no routes are written, this is non-fatal — but warn.
2. `gh auth status` — must list the **`project`** scope (board edits need it). If missing, stop with: "run `gh auth refresh -s project`" — **except under `--feedback-only`, where a missing `project` scope is a warn-and-continue, not a stop.** That path performs no board writes at all: Step 6's entire surface is `gh api user` + `gh issue *` + `gh pr *` (repo-scoped Issues/PRs), plus `board_repo` (a static map lookup) and `board_parent_issue` (a REST `repos/<repo>/issues/<n>` read) — no `gh project` call anywhere, so the scope it would stop for is one the run never uses.
3. **Locate the board adapter, resolve the board.** All board reads/writes route through the shared adapter `lib/board.sh` — never a raw `gh project` call or a hand-resolved field/option id, the same contract `/build` follows ([[Decisions/foundation - build board integration]]). Set `BOARD_LIB` = the first of `scripts/lib/board.sh` (a consuming repo like stageFind, which vendors the toolkit) or `workflows/scripts/board/lib/board.sh` (foundation, the toolkit's home) that exists; if neither exists, stop with "board adapter not found — run /triage from the foundation or a board-consuming checkout". Resolve the board number from `--board`/`--project`. **If neither was given, infer the board from the local repo:** run `source "$BOARD_LIB"; repo=$(gh repo view --json nameWithOwner -q .nameWithOwner); BOARD=""; for b in $(board_registered_boards); do [ "$(board_repo "$b")" = "$repo" ] && BOARD="$b"; done` — the same reverse-lookup pattern `/build` Step 0 uses, iterating the adapter's own `board_registered_boards` (the single source of truth for the registered set, so onboarding a board needs no probe edit; board **7** is the temperloop kernel tracker, an issues-only backend — see `workflows/scripts/board/ISSUES-ONLY-BACKEND.md` — and resolves through the same `board_repo` reverse-lookup as any other board). If a match is found, print `inferred board $BOARD (repo $repo)` before any board read and continue; the existing Step-4 write gate (`Apply all / subset / Cancel`) is what guards silent mutation, so no additional confirm is needed here. If **no** candidate board matches (an unmapped repo), STOP with: `/triage: cannot infer board — pass --board <N> (3=stageFind, 4=foundation, 5=ssmobile, 6=subsetwiki, 7=temperloop kernel) or --project <name>, or run from a board-mapped repo`. **`source "$BOARD_LIB"` at the top of every board bash block** to get the accessors (`board_resolve` / `board_item_id` / `board_item_title` / `board_set_status` / `board_set_number` / `board_create_many` / `board_create_on_board` / `board_stamp`), the option constants (`BOARD_OPT_BACKLOG` / `BOARD_OPT_READY` / `BOARD_OPT_DONE`), and `board_repo "$BOARD"` → the `owner/repo` for `gh issue create -R` / `gh api` (don't hardcode `<org>/<repo>`).
4. **Resolve board state once via the adapter.** `source "$BOARD_LIB"; board_resolve "$BOARD"` issues a SINGLE `project view` + `field-list` + `item-list --limit 200` and caches them in the shell (`BOARD_PROJECT_ID`, `BOARD_FIELDS_JSON`, `BOARD_ITEMS_JSON`) — so nothing re-lists per item, and the `--limit 200` footgun + Projects-v2 GraphQL-budget pressure (GH #396) live in one place. The governance field is the built-in **`Status`** field (`BOARD_FIELD_STATUS`); every governed board keys on it since foundation #4's migration ([[Decisions/foundation - Migrate board #4 onto Status field]]), so the adapter owns the field choice — no per-board special-casing here. `board_set_status`/`board_option_id` resolve `Backlog`/`Ready`/`Done` by name from the cache; `board_field_id "Seq"` resolves the Seq number field for `board_set_number`.
5. For each analysis-doc path in `$1..$N`: `mcp__obsidian__get_vault_file` to confirm it exists; note word count (≥10k → chunked reads in Step 1).

If any check fails, surface in one line and stop.

## Step 0.6 — AskUserQuestion recurring-class intake (attention → candidate defaults)

**Every `AskUserQuestion` is an attention datum** — an interruption that signals a *missing default or contract* (see `Context/foundation - AskUserQuestion severity taxonomy.md` in the knowledge store). They are logged by the PostToolUse hook `claude/hooks/log-askuserquestion.sh` to the append-only stream `meta/data/raw/askuserquestion-events.jsonl` (schema: `meta/data/raw/README.md`). This step turns a **recurring** high-interrupt class into a triage **candidate** — a candidate for a *new default/contract* that would stop the interruption.

This is a real intake step, not aspirational: run the weekly tally and ingest its recurring classes as Step-1 candidates alongside the board Backlog.

1. **Run the tally** over the last week, recurring classes only:
   ```bash
   python3 "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo .)/workflows/scripts/askuserquestion_tally.py" --days 7 --min-count 3 --json
   ```
   (From a board-consuming checkout that vendors foundation, resolve the foundation checkout's path to the script instead; if the script or stream is absent — e.g. on a board without the hook installed — note `AskUserQuestion intake skipped — no event stream` and continue. Never fail triage over a missing telemetry stream.)
2. **Each recurring class becomes a candidate** with `provenance: askuserquestion`, `title = "Add a default/contract for repeated interruption: <class>"`, body = the class `site_hint`/`header`, its 7-day `count`, and the per-project breakdown, plus a one-line scope: *"This AskUserQuestion site interrupted N times this week — decide whether it warrants a new default (a `batch-at-gate`/`batch-at-ritual` default per the severity taxonomy) so it stops asking."* `source_ref = meta/data/raw/askuserquestion-events.jsonl#<class>`.
3. **These candidates run the normal Step-2 decision tree** like any other:
   - Most will **route off-board as a *decision*** (Step 2.5) — "decide whether site X gets a default" is a decision, not build work — written to a `Decisions/` stub. If the decision *does* spawn build work (wire the default into the command), that build re-enters the pipeline as its own item.
   - A class that is already a known design seam may **collapse** (Step 2.2) into an existing survivor.
   - **Cull** a class whose interruptions are all legitimately `blocking-now` (no safe default exists — see the taxonomy): a `blocking-now` site has no default *by design*, so a recurring count there is not a defect and gets no candidate.
   The `--min-count 3` threshold is the recurrence gate — a one-off interruption is noise, not a missing contract.

## Step 1 — Intake (the one fork)

This is the only place the funnel forks, and it is cheap and mechanical. Normalise both sources into a single list of **candidates**, each `{ provenance, issue#?, title, body, labels, source_ref }`:

- **Adapter A — board Backlog.** From the resolved state (Step 0.4), read `BOARD_ITEMS_JSON` — keep items whose `.status` is `Backlog` (`BOARD_OPT_BACKLOG`). These already have issue numbers (`provenance: board`). **Then apply the active-milestone intake filter** (foundation #208, [[Decisions/foundation - Active-milestone intake filter (supersedes Parked-status parking)]]): resolve the active set once, branching on the accessor's **exit code** to distinguish a genuine fetch failure from a genuinely-empty active set (temperloop#152): `if ! active=$(board_active_milestones "$BOARD"); then` → the milestone REST fetch itself failed, so **warn and STOP** (don't silently treat every milestoned item as inactive and defer them all, which would print a plausible deferred count masking the failure); re-run once REST is healthy. Otherwise the call **succeeded** and `$active` is authoritative **even when empty**: an empty active set is the normal default state (milestones default inactive), NOT a failure — proceed. `board_active_milestones` returns non-zero **only** on an actual fetch failure; a successful fetch that finds zero `<!-- triage:active -->` markers is exit 0 + empty output. **Do not** add a separate "do open milestones exist?" probe — milestone *existence* is the wrong proxy for fetch *success* (it false-STOPs a board whose milestones are all legitimately inactive, e.g. the issues-only kernel tracker board 7). This `$active` snapshot is the one carried forward to Step 2's `phase_active` derivation and Step 4 — do not re-call it later. Then, for the survivors, for each Backlog candidate read its milestone via `board_item_milestone <n>` and **intake it IFF it is unmilestoned OR its milestone is in `$active`**. A Backlog item whose milestone is **inactive** (set, but not in `$active`) is **excluded from intake** — set it aside into a `deferred[]` list (`{issue#, milestone}`) and leave it untouched in `Backlog`; it re-enters the next sweep automatically once `milestone activate "<phase>"` marks its phase active. (There is no `Parked` move — the filter *is* the deferral.) **Then drop any survivor with an open GitHub native dependency:** for each still-intook Backlog candidate, if `board_blocked_by_open "$BOARD" <n>` prints anything, it is genuinely `blocked_by` an open issue — set it aside into a `blocked[]` skip list (`{issue#, open-blocker numbers}`) instead of intaking it (don't re-triage work that can't start). Gate on the Backlog slice only — `board_item_milestone`/`board_blocked_by_open` are live REST calls per Backlog item, never the whole board. Pull title, body, and labels for the survivors with `gh issue view <n> -R "$(board_repo "$BOARD")" --json …`.
- **Adapter B — analysis docs** (only if `$1..$N` given). Read each doc (small <10k words: whole; large: headings outline then targeted section reads, never >50% of context — same as `/assess` Step 1). Extract actionable findings — skip methodology/preamble. Each finding is a candidate with `provenance: doc`, no issue yet, carrying `source_ref = [[<path>#<heading>]]`. Dedupe findings that overlap across docs (cite each source).

## Step 2 — The logical decision tree

Work the full candidate set in the orchestrator. Apply, in order:

1. **Cull.** Drop candidates that are **dupe / won't-fix / stale / already-fixed**.
   - **Re-verify "already-fixed" against current `origin/main`** before culling — a dated Backlog item is often already resolved (don't act on stale findings).
   - *Board-sourced* cull → mark for **close with a one-line reason comment** + move off Backlog → `Done` (or close the issue, which the board reflects). *Doc-sourced* cull → simply drop (no issue was ever created).
   - **Semantic-dedup advisory (ks_search).** The body-marker probes at Step 4 catch *exact* re-runs (the same source re-triaged) — they don't catch a candidate that is *meaningfully* the same bug as an existing issue filed from an unrelated source, with no shared marker to match on. Where the issue corpus + search stack is available (`source workflows/scripts/lib/knowledge_store.sh; source workflows/scripts/lib/knowledge_search.sh; ks_search_available`), query `ks_search "<candidate title + one-line scope>" --limit 5` per candidate and surface any high-scoring hit against an existing issue as a **dupe hint** for this cull judgment — advisory only, never an automatic cull; the orchestrator still decides. **Graceful skip:** if `ks_search_available` fails (exit 3) or the libs aren't present in this checkout, note "semantic-dedup advisory skipped — knowledge_search unavailable" and continue culling on exact-match/manual judgment alone, exactly as before this item.
2. **Root-cause collapse.** N symptoms tracing to **one** fix → collapse into a single survivor (note the absorbed symptoms in its body). This is a *logical* merge (same underlying cause), distinct from a *physical* merge edge.
   - If the collapsed survivor is itself **rework** of prior completed work, file/re-file it with `scripts/capture.sh ... --rework <regression|spec-miss|flake>` so the cause is captured at filing time (F#730) — a human-filing convention for whoever runs triage, not an automated real-time rule, so it deliberately carries no Live/Drain registry-table pair.
3. **Group-by-meaning.** Cluster the survivors by **theme / shared root cause**. Each cluster of ≥2 is a candidate epic. Resist grouping by "same file/module" — that is a `/assess` edge, not a group.
4. **Value / priority.** Order survivors and groups by value; assign integer `Seq` values (lower = sooner). This is the *logical* ordering; *dependency* ordering (levels) is `/assess`'s job. **Seq is unsupported on an issues-only backend** (`board_backend "$BOARD"` = `issues`, e.g. board 7) — `board_set_number` fails loud there by design (no Projects-v2 field schema; see `ISSUES-ONLY-BACKEND.md`). On such a board, still order survivors logically for the run's own reasoning, but skip the `Seq` *write* at Step 4.5.
5. **Route decision-only items off-board.** A candidate that is "**decide** X" rather than "**build** X" is not epic material. Write a short vault stub — `Decisions/` if it needs a rationale capture, else `Context/` — link it, and close/move its board issue off Backlog (doc-sourced: just record the route). It re-enters the build pipeline later only if the decision spawns build work.
6. **Assign a release phase to every unmilestoned survivor** (foundation #208). A survivor that arrived **unmilestoned** must leave triage with a phase — pick the right milestone for it on its merits (per-item judgment; phases are free, concurrent grouping labels, so there is **no single default phase** to fall back on). A survivor that already carried a milestone keeps it (don't reassign). Record the chosen `<phase>` per unmilestoned survivor; the actual write (`board_set_milestone`) is surfaced at and fires from the Step-4 batched write gate. **Invariant: post-triage every survivor carries a phase.**
7. **Singleton vs grouped.** A survivor in no cluster is a **singleton**: no epic, route it at Step 4 per its phase (see Step 4.6). A cluster of ≥2 becomes an **epic** with those survivors as members.
8. **Kernel-vs-overlay routing** (only when this checkout carries `claude/CLAUDE.kernel.md` — skip this item entirely otherwise, no flag set). Apply the **stranger test** from `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule to each survivor: would a stranger's kernel-only install need this fix for the kernel machinery (board adapter, build/sweep pipeline, install/doctor, branch/PR policy) to work correctly? If yes, the survivor is a **kernel candidate** — its fix belongs upstream, not in this plan's own repo. This is a *routing* classification, not a cull or a regroup — a kernel candidate still survives triage and gets grouped/phased/Seq'd normally; the flag only tells `/assess` to carry it forward as a cross-repo item. **In-kernel-checkout no-op (temperloop#58):** when this checkout **IS the kernel repo itself** — detected by `claude/CLAUDE.kernel.md` present **AND** `claude/CLAUDE.overlay.md` **absent** (the kernel repo's own shape; the same detection `validate-live-drain.sh` uses) — the upstream route target *is* the current repo, so a `kernel_class: kernel` flag would be a vacuous self-route that over-labels the whole board and mints an otherwise-unused repo label. In that case still apply the stranger test and **note** the classification in prose, but set every survivor's `kernel_class: overlay` (no side-effect): the Step-4 stamp and the `/assess` `repo:` prefill both no-op. Only the label/route side-effect is suppressed — the classification reasoning survives in the run's prose.

Carry forward, per group: a short **group summary** (the shared meaning), its members, and any member flagged `kind: spike` (a verdict-only item — a note + routed issue, not a PR; gets a `spike` label so `/assess --epic` can prefill `kind`). Carry forward, per survivor: its **phase** (existing or newly assigned) and a per-survivor **`phase_active`** flag — set it once here by testing the survivor's phase against the **Step-1 `$active` snapshot** (`board_active_milestones "$BOARD"` captured at Step 1, *not* a fresh call). An unmilestoned survivor's `phase_active` follows the phase you assign it at Step 2.6 (test that phase against the same `$active` snapshot). This `phase_active` flag is what drives the Step-4 Backlog→Ready-vs-defer routing — Step 4.7 reads the flag, it does **not** re-call `board_active_milestones`, so what the Step-3.5 preview gates is exactly what executes (no preview/execute TOCTOU on the active set).

Also carry forward, per survivor, a **`needs_clarification`** flag — set true when the survivor is **underspecified**: the fix's intended behavior, a choice between two designs, or a missing decision is genuinely ambiguous (*not* merely a fact a worker could look up) — plus the one-line **clarifying question** it raises. This is a **logical readiness** judgment (is this survivor well-enough specified to be worked?), distinct from the technical/how calls `/assess` owns. Triage only **flags** it (Step 4's `needs-clarification` sub-step drops a `needs-clarification` label + records the question at source); it does **not answer** it — answering belongs to the downstream consumer (`/sweep` Phase 1 for a singleton, `/assess` for an epic'd member), per [[Decisions/foundation - Triage stage and the logical-technical pipeline split]].

Also carry forward, per survivor, a **`work_class`** — either `Operational` or `Foundational` — per `claude/work-class-policy.md`. The deciding question: **does this work follow an established pattern, or does it establish a new one?**

- **Operational (default):** bug fixes, follow-ups, issue splits, defects found mid-work, established-axis expansion. Follows a known, fully-specified pattern — the driver is fully autonomous (triage → assess → build → auto-merge once CI green).
- **Foundational:** new features, new kinds of task, architectural decisions, highly disruptive or environment-altering changes. Establishes a new pattern — the driver routes design decisions + plan approval to the operator's decision queue before building.

**Default rule: if in doubt, classify `Operational`.** The misclassification safety net is `/build`'s design-fork halt — an Operational item that turns out to require architectural judgment halts there regardless of its label. That net makes the binary safe to apply early. `Foundational` is the deliberate exception: mark it only when the work clearly changes the system's shape or requires operator judgment up front to determine *what* and *how*.

Also carry forward, per survivor, a **`kernel_class`** — `kernel` or `overlay` (default `overlay`) — set by Step 2.8's stranger-test application. **Default rule: if in doubt, classify `overlay`.** A misclassified overlay item costs nothing extra (it just builds in this repo as normal); a misclassified kernel item would wrongly route a personal/org-specific fix upstream. `/assess` reads this flag off the sub-issue's `kernel-candidate` label (Step 4 stamps it) and carries it into the item's `repo:` field (`~/.claude/plan-schema.md` § Optional `repo:` field).

## Step 3 — Sanity-check pass (read-only, advisory)

Spawn `Agent { subagent_type: "requirements-auditor" }` with the proposed groups (group summaries + member titles + cull list + decision-routes). Prompt it to surface:

- Survivors that are secretly the **same** item (missed dupe / collapse).
- Groupings that are actually a **physical** edge masquerading as a logical group (should be one epic's `/assess` edge, or separate epics — not one group).
- Candidates that are really **decisions** (should route off-board) or are **invalid / out of scope** (should cull).
- A group with only one real survivor (should be a singleton, no epic).

Read-only and advisory. Apply clear wins; surface contested suggestions via `AskUserQuestion` before Step 4. **Graceful skip:** if the agent isn't available, note "sanity pass skipped — agent unavailable" in the Step 5 summary and continue.

## Step 3.5 — Preview before mutation

Print the planned board mutations so a bad grouping is caught before any write:

- **Epics to create** → each with its member slugs/issue#s and one-line summary.
- **Singletons** → list (no epic).
- **Phase assignments** → each unmilestoned survivor → its newly-assigned `<phase>` (the `board_set_milestone` writes that fire at the gate).
- **Routing** → per survivor/epic, **active phase → Backlog→Ready** vs **inactive phase → stays Backlog (defers)**.
- **Deferred at intake** → the `deferred[]` items skipped in Step 1 (issue# → inactive milestone), summarised as the one-line deferred notice (see Step 5).
- **Culls** → list with reasons (and which close issues).
- **Decision-routes** → list with target note paths.
- **Spikes** → which members get the `spike` label.
- **Needs-clarification flags** → which survivors get the `needs-clarification` label + their recorded question (Step 4's sub-step).
- **Work-class labels** → each survivor's `Operational` or `Foundational` assignment (default `Operational`); note any survivors classified `Foundational` and the reason.
- **Kernel candidates** → survivors classified `kernel` at Step 2.8 (n/a if this checkout has no `claude/CLAUDE.kernel.md`, or if this **is** the kernel repo itself — `CLAUDE.overlay.md` absent — where the stamp no-ops per Step 2.8's in-kernel-checkout no-op).
- **Seq** assignments.

If `--dry-run`, **STOP here** — zero mutation, no issue/epic creation, no field flips. End with: "Re-run without `--dry-run` to execute." This is the authoring-time mirror of `/build --dry-run`.

**Exception — `--dry-run --feedback`:** skip straight to **Step 6** and stop after it. Step 6's own dry-run arm is read-only (it prints the pending-feedback queue and answers nothing), so running it preserves this step's zero-mutation guarantee while still letting a rehearsal show *both* halves of what the run would touch. Do **not** run Steps 4–5. (Under `--feedback-only` this step never runs at all — the run went straight from Step 0 to Step 6 — so the exception is moot there.)

## Step 4 — Materialise on the board

Gate the outward writes once: print the Step 3.5 preview and ask via `AskUserQuestion` — **Apply all** (default) / **Pick a subset of groups** / **Cancel**. Then, for the approved set (idempotent throughout — the board is the state):

All board bash blocks below `source "$BOARD_LIB"` first (Step 0.3); let `repo="$(board_repo "$BOARD")"`. Issue *creation* is repo-level (`gh issue create -R "$repo"` / `gh api repos/$repo/...`), not board state, so it stays direct; every *board* read/write goes through the adapter.

**Resolve the marker-probe helper once, corpus-first.** Every body-marker "probe-before-create" below (1 and 2) is an exact-text idempotency check — did a prior run already file the issue carrying this marker? — and is answered by `issue_marker_probe` (`workflows/scripts/lib/issue-marker-probe.sh`), which searches the rendered issue corpus first (zero `gh` calls when it's fresh) and falls back to the identical live `gh issue list --search "<marker> in:body" --state all` this step always used, whenever the corpus is absent or stale-beyond-limit — never a partial/local answer in that case. Resolve and source it once: `PROBE_LIB="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo .)/workflows/scripts/lib/issue-marker-probe.sh"`; if it exists, `source "$(dirname "$PROBE_LIB")/../board/lib/cache.sh"; source "$(dirname "$PROBE_LIB")/knowledge_store.sh"; source "$(dirname "$PROBE_LIB")/issue-corpus.sh"; source "$PROBE_LIB"` and call `issue_marker_probe "$repo" "<marker>"` (JSON array of `{number,title,body}`; adopt via `jq -r '.[0].number // empty'`). **Graceful degrade:** on a checkout that doesn't vendor this toolkit (`PROBE_LIB` doesn't exist), fall back to the direct `gh issue list -R "$repo" --search "<marker> in:body" --state all` call exactly as before this item — never fail the step over a missing corpus toolkit.

1. **Ensure each survivor has an issue.** *Board-sourced* already do (and are already on the board). *Doc-sourced* survivors → **probe-before-create**: `issue_marker_probe "$repo" "Triaged from: <source_ref>"` for an issue a prior run created (match the exact `Triaged from: <source_ref>` back-link, not the title); adopt if found, else `gh issue create -R "$repo"` with a body = the finding's one-line scope + `Triaged from: <source_ref>`. **Collect** each newly-created issue's `<url> <n>` for the single batch board-add in step 5 — do **not** add them one at a time (`board_create_on_board` per item re-resolves the whole board each call, draining the Projects-v2 GraphQL budget; GH #40).
2. **Create the epic per group** — **probe-before-create** first: `issue_marker_probe "$repo" "<epic marker>"` for a stable marker string this command writes into every epic body (e.g. `Triage epic: <kebab-group-key>`); adopt if found. Else `gh issue create -R "$repo" --title "Epic: <group title>" --body "<body>"`, where `<body>` = the group summary, a member task-list (`- [ ] <title> (#<n>)`), and the `Triage epic: <key>` marker. Apply an `epic` label if the repo defines one. **Collect** the epic's `<epic-url> <epic#>` for the batch board-add in step 5; its Ready flip + Seq follow in 5–6.
3. **Link members as native sub-issues** — for each member issue not already a child: resolve its db id (`gh api repos/$repo/issues/<n> --jq '.id'`) → `gh api -X POST repos/$repo/issues/<epic>/sub_issues -F sub_issue_id=<db-id>`. **Linkage failure warns-and-continues** (the typed link is cosmetic relative to membership intent). **Fallback** if the API is unavailable: append `- [ ] #<child>` to the epic body and prepend `Part of #<epic>` to each child body — GitHub renders that as a tracked relationship.
4. **Label spikes** — add the `spike` label to each member flagged `kind: spike` (`gh issue edit <n> -R "$repo" --add-label spike`). **Then, the `needs-clarification` sub-step:** for each survivor (singleton *or* member) carried forward with `needs_clarification` (Step 2), flag the open question **at source** — **comment FIRST, then label+assign**: `gh issue comment <n> -R "$repo" --body "needs-clarification: <the question>"$'\n\n'"Once answered: on the autonomous funnel board, unassign yourself to release it straight back to the driver; on other boards leave it as-is — the next /sweep or /assess clears the label. Either way your answer is consumed."` **and only after it succeeds** `gh issue edit <n> -R "$repo" --add-label needs-clarification --add-assignee @me`. The closing line is **board-safe**: on a funnel-enabled board (stageFind today) unassigning is the operator's baton-return gesture — the funnel autonomously drains an *unassigned* `needs-clarification` item, clearing the label so it drives again (foundation #657). On a board with **no** funnel consumer (e.g. foundation), it deliberately tells the operator to **leave the assignment** (so the item stays in their assigned-to-me queue per #684) and relies on the label carrying it into the next `/sweep`//`/assess` — never instructing an unassign that would strand it with nothing to drain it. This ordering is deliberate (foundation #684): the label+assign are the "handled" markers, and the funnel router treats an assigned `needs-clarification` item as fully parked (`route-already-assigned`) — never re-deriving or re-posting the question the way the retired `route-needs-input` did each tick. So the question text MUST be durably recorded *before* the markers land; if the comment call fails, do **not** apply the label/assign — leave the survivor un-flagged so it re-enters the next sweep (a missing marker self-heals; a missing *question* under a "handled"-looking marker would be silently lost). With the comment in place, the `--add-label --add-assignee` **assigns the operator at source** (`@me` = the gh-authenticated operator), landing the survivor directly in the operator's assigned-to-me queue for its downstream consumer (`/sweep` Phase 1 for singletons, `/assess` for epic'd members) to *answer* — without triage answering (the logical/technical split). The funnel then merely **parks** it, never re-assigns — the assignment is owned here at source (foundation #684). Re-run safe: `--add-label`/`--add-assignee` are idempotent (skip the label add if already present per `gh issue view <n> -R "$repo" --json labels`). **Then, the work-class stamp:** for every survivor (singleton *or* epic member) and each epic issue itself, stamp exactly one work-class label (`Operational` or `Foundational`) from its carried-forward `work_class` value. Use `gh issue edit <n> -R "$repo" --add-label <work_class>`. **Idempotent:** before adding, check `gh issue view <n> -R "$repo" --json labels --jq '.labels[].name'`; if the issue already carries `Operational` or `Foundational`, skip the add (re-run safe). An unmarked issue always receives `Operational` by default — the only way a survivor leaves triage without a work-class label is a bug in this step. **Then, the kernel-candidate stamp** (only when Step 2.8 ran — this checkout carries `claude/CLAUDE.kernel.md` — **and this is not an in-kernel checkout**: skip the stamp entirely when `claude/CLAUDE.overlay.md` is absent, per Step 2.8's in-kernel-checkout no-op — every survivor is `overlay` there, so there is nothing to stamp): for every survivor carried forward with `kernel_class: kernel`, add the `kernel-candidate` label (`gh issue edit <n> -R "$repo" --add-label kernel-candidate`), same idempotent check-before-add as work-class. `overlay`-classified survivors get no label (the default, unmarked state). `/assess` reads this label off each sub-issue (Step 1) to prefill the item's `repo:` field.
5. **Batch-land on the board, then set `Seq`.** Land every newly-created issue + epic from steps 1–2 in ONE call: `board_create_many "$BOARD" <url1> <n1> <url2> <n2> …>` — a single board resolve for the whole burst (not one per item; GH #40), each landing in Backlog. (If nothing new was created — all survivors board-sourced — `board_resolve "$BOARD"` once instead.) Either way `BOARD_ITEMS_JSON` is now fresh, so set Seq straight from it: **guard the Seq write on the backend** — `if [ "$(board_backend "$BOARD")" != issues ]; then` for each survivor and epic `board_set_number "$(board_item_id <n>)" "Seq" <value>` per Step 2.4; `else` skip it (Seq is documented-unsupported on an issues-only backend — `board_set_number` fails loud there by design — so skipping is correct, not a workaround; note the skip in the Step-5 summary). Do **not** call `board_set_number` on an issues-only board: it would hard-fail the run.
6. **Assign milestones to unmilestoned survivors** (foundation #208) — for each survivor that arrived unmilestoned, write its Step-2.6 phase: `board_set_milestone "$BOARD" <n> "<phase>"`. Skip survivors that already carried a milestone. After this step every survivor carries a phase (the post-triage invariant).
7. **Flip Backlog → Ready *for active-phase survivors only*; leave inactive-phase survivors in Backlog** (foundation #208 routing).

   **Two ordering hazards this step must avoid — read first:**
   - **Cache-bust hazard (BLOCKER).** Step 4.6's `board_set_milestone` busts the on-disk items cache. So after 4.6, do **NOT** call `board_resolve_item`/`board_resolve` to look up an item id — they would read the busted cache and `board_item_id` would return **empty**, making `board_set_status "" …` a silent no-op (the survivor stays Backlog and re-enters next sweep with no error). Instead, for every `board_item_id <n>` lookup in this step use the **in-shell `BOARD_ITEMS_JSON` captured at Step 4.5** (it is fresh as of 4.5 and still in-shell — `board_set_milestone` busts the *on-disk* cache, not the shell variable). Do not re-resolve between 4.6 and 4.7.
   - **Active-set TOCTOU hazard.** Do **NOT** re-call `board_active_milestones` here. Branch on each survivor's carried-forward **`phase_active`** flag (derived at Step 2 from the Step-1 `$active` snapshot), so what executes matches the Step-3.5 preview the user gated.

   For every grouped survivor, surviving singleton, **and** each epic, branch on its carried `phase_active`:
   - **active phase (`phase_active` true)** → `board_set_status "$(board_item_id <n>)" "$BOARD_OPT_READY"` — it proceeds now; this is the durable "triaged" mark that excludes it from the next sweep.
   - **inactive phase (`phase_active` false)** → **leave it in `Backlog`** (no status write). It defers, and re-enters the next sweep automatically once the phase is activated (`milestone activate "<phase>"` stamps the `<!-- triage:active -->` marker). There is no `Parked` move.

   An **epic's** Ready flip follows its members: if **any** member's `phase_active` is true the epic flips Ready; if the whole group is on inactive phases the epic stays Backlog with them. The epic's Ready flip signals only that the *group is scoped* — member readiness follows each member's **own** `phase_active`: an **inactive-phase member of an active-phase epic is NOT dragged to Ready** — it stays in `Backlog` individually (per the rule above) and is counted in the Step-5 "Left in Backlog (inactive phase)" line.
8. **Apply culls and decision-routes** — close culled board issues with their reason comment (`gh issue close <n> -R "$repo" --comment "…"` — the built-in close→Done automation reflects it on the board; or set it explicitly with `board_set_status "$(board_item_id <n>)" "$BOARD_OPT_DONE"`). Write the decision-route vault stubs and close/move their issues off Backlog the same way.

## Step 4.9 — Emit the run telemetry record

`/triage` has no plan-note footer, so without an explicit emit here a whole run — or a run that silently stopped emitting — produces **no** signal at all (the June silent-failure class: a never-written stream is indistinguishable from "nothing to do"). Once Step 4's board mutations are applied, append ONE command-run record from this run's own counters (the same ones Step 5 prints) — this call is the executable emit point, not a prose reminder, and its presence is mechanically enforced by `workflows/scripts/validate-command-run-emit.sh` (wired into `scripts/quality-gates.sh`), which fails CI if this invocation is removed:

```bash
"$(git rev-parse --show-toplevel)/workflows/scripts/emit-command-run.sh" \
  --command triage --board "$BOARD" \
  --items-processed <K+M+Q — total candidates intook, Step 0.6/Step 1> \
  --merged <S — survivors promoted to Ready (active phase), Step 4.7> \
  --parked <I+N+B — left in Backlog on an inactive phase (Step 4.7) + deferred at intake (Step 1) + blocked on an open blocked_by (Step 1)>
```

`merged`/`parked` are triage's closest analogues to /build's "landed" vs. "held back": a promoted survivor is triage's terminal-success outcome (it reaches `Ready`, the next stage's intake), while everything left in `Backlog` for any reason (inactive phase, intake deferral, an open blocker) is held back exactly like a `sweep` park. Resolve the script bare repo-relative — if absent from a non-vendoring checkout, treat the failed path resolution as a no-op and continue (never let a missing/failing emit block or delay Step 5). The script itself is `|| true`-safe: a write failure warns to stderr and exits 0.

## Step 5 — Summarise

```
/triage — board <N> (owner <org>)
- Candidates intook: K board + M doc-findings + Q AskUserQuestion recurring-classes (Step 0.6)
- Epics created/adopted: E  (#s → member count each)
- Promoted to Ready (active phase): S  (#s)
- Left in Backlog (inactive phase, routed at Step 4): I  (#s → phase)   ← survivors that ran the tree but defer on routing
- Phases assigned to unmilestoned survivors: A  (#s → phase)
- Deferred at intake (Step 1 — inactive-milestone filter): N in inactive milestones (<phase> ×k, <phase2> ×j …). Mark active to include.   ← MANDATORY #164 line (see below)
- Blocked (skipped — open blocked_by): B  (#s → blocked_by #m)
- Culled: C  (#s → reasons; X issues closed)
- Decisions routed off-board: D  (→ note links)
- Spikes labelled: P  (#s)
- Work-class: O Operational, F Foundational  (#s each; all survivors labelled)
- Kernel candidates: K  (#s → kernel-candidate label; "n/a — no kernel/overlay split" if Step 2.8 didn't run; "n/a — in-kernel checkout" if this IS the kernel repo, `CLAUDE.overlay.md` absent, where the stamp no-ops)
- Seq assigned across N survivors  (or "Seq: n/a — unsupported on issues-only backend" when `board_backend` = `issues`)
- Sanity pass: applied K notes  (or "skipped — agent unavailable")
```

Two distinct lines report deferral — don't conflate them:
- **"Left in Backlog (inactive phase, routed at Step 4)"** counts survivors that *passed* the Step-1 intake filter, ran the full decision tree, and then deferred at Step-4 routing because the phase they hold/were-assigned is inactive (`phase_active` false).
- **"Deferred at intake (Step 1 — inactive-milestone filter)"** counts the Step-1 `deferred[]` items — Backlog items whose milestone was inactive, so they were *never intook* and never ran the tree.

The **Step-1 intake-deferred line is the mandatory one every run** (foundation #208 / #164 silent-skip mitigation): always print `Deferred at intake (Step 1 — inactive-milestone filter): N in inactive milestones (<phase> ×k …). Mark active to include.` — `N` = the count of the Step-1 `deferred[]` items, grouped by inactive milestone with per-phase counts. If nothing was intake-deferred, print `Deferred at intake (Step 1): 0 — no inactive-milestone Backlog items`. Intake deferral is always reported, never silent. (The Step-4 "Left in Backlog" line is informational, not the #164-mandatory line.)

Close with the next actions:
1. For each new epic: **`/assess --epic <N>`** to decompose it to seams and produce a `Plans/` note (companion **#22**).
2. Note that `/build` (companion **#23**) owns the epic's runtime + close downstream — triage does not.
3. If `--feedback` was passed, Step 6 follows. If it was **not**, and the operator's pending-feedback queue is non-empty, it costs one cheap search to say so — see Step 6's tail note.

## Step 6 — Pending-feedback review (optional, `--feedback` / `--feedback-only`)

**Skip this step entirely unless `--feedback` or `--feedback-only` was passed.** Everything above is triage's own job — deciding what survives and what belongs together. This step does something different: it drains the queue of questions the pipeline has parked **on the operator**.

**Under `--feedback-only` this is the *whole* run** — Step 0 ran its reduced arm (0a–0b) and Steps 0.6–5 never executed. Two consequences to hold onto: there is no Step-5 summary to attach to, so 6.4's summary **is** the run's output; and because Step 4.9 never ran, this path emits its **own** telemetry record at **6.5** — a `--feedback-only` run mutates GitHub and would otherwise leave no signal that it happened.

**Why this lives here.** The pipeline has **producers** that park work on the operator (Step 4.4 above, `/sweep`'s park-on-question, `/build`'s async decision-issue backend, the funnel's 5c merge tier) and **drains** that consume the operator's reply (`tidy` § Answered decisions, the funnel's `drain-answer` / `drain-clarification`) — but no surface where the operator actually **answers**. The standing expectation is that they work a saved GitHub view by hand (`claude/decision-queue-contract.md` § 2 — `is:open assignee:@me label:decision`), each issue in isolation. Triage is the right home for the missing half: it is already the **batch-judgment** surface, where the operator is in a batch-decision headspace rather than paging one issue's context in at a time, and it already resolved the board.

**The seam that makes it cheap.** The pending-feedback queue is the exact **complement of the funnel's drain lists**. The funnel drains `no:assignee` (the operator answered and handed the baton back — `funnel-tick.sh`'s `read_answered_decisions` / `read_answered_clarifications`); `assignee:@me` is the half still sitting on the operator. Every producer **assigns the operator at source** (foundation #684), so the assignee bit is already a reliable, board-wide "this is yours" marker. There is no new state to invent — this step reads a marker the pipeline already maintains.

### 6.1 — Build the queue

**First resolve *whose* queue this is — the producers do not all assign the same identity.** Step 4.4 assigns `@me` (the `gh`-authenticated operator), but the funnel assigns the **configured** `$FUNNEL_OPERATOR` login (`workflows/scripts/build/build.config.sh`; `funnel-tick.sh` carries a matching `:=` fallback). Those coincide on a single-operator host and **diverge** whenever they are configured apart — a second operator, a different machine's `gh auth`, a shared account. A bare `assignee:@me` search would then silently return a partial queue and print "no pending feedback" over real work. Resolve both, and search their **union**:

```bash
source workflows/scripts/build/build.config.sh 2>/dev/null || true   # best-effort; a non-vendoring checkout just gets @me
op="${FUNNEL_OPERATOR:-}"
case "$op" in ''|'@REPLACE_WITH_YOUR_GH_LOGIN') op='' ;; esac        # unconfigured placeholder → not a real login
op="${op#@}"                                                          # gh wants the bare login
me="$(gh api user --jq .login 2>/dev/null)"
[ "$op" = "$me" ] && op=''                                            # same identity → one search is enough
```

Then, per assignee (`@me`, plus `$op` when non-empty), one repo-level search (`repo="$(board_repo "$BOARD")"` from Step 0.3), using GitHub search's **comma-OR** on `label:`:

```bash
gh issue list -R "$repo" --state open \
  --search 'assignee:@me label:needs-clarification,decision,funnel-escalated' \
  --json number,title,body,labels,comments,url
```

Union the results and **dedupe by issue number** (an issue can only carry one assignee set, but a divergent-operator repo returns two disjoint lists that must be walked as one queue). Carry each item's resolved assignee forward — 6.3's `--remove-assignee` must drop the identity that is actually on the issue, not assume `@me`. If `$op` is non-empty, **say which identities were searched** in the 6.4 summary; a queue scoped to an identity the operator didn't expect is the same silent-under-report in a different disguise.

This is deliberately **repo-level, not board-level** — `gh issue list` + `gh issue edit`, no Projects-v2 field reads — so the step works identically on every backend, including the **issues-only** kernel tracker (board 7), with no `Status`-field dependency and none of Step 4.5's `board_set_number` hazard.

Three classes, each with a different disposition. **Dispatch most-specific-first** when an issue carries several: `funnel-escalated` → `decision` → `needs-clarification`.

| Label | Parked by | Class | The operator owes |
|---|---|---|---|
| `needs-clarification` | Step 4.4, `/sweep` park-on-question, the 5c refusal escalation | **Answerable** — free text | an answer |
| `decision` | `/build`'s async decision-issue backend; the funnel's `route-foundational` | **Answerable** — *typed grammar* | a choice from a closed set |
| `funnel-escalated` | the funnel's 5c merge tier (foundation #697) | **Actionable** — *not a question* | a merge or a close |

**Do NOT include `funnel-merge-pending`.** It looks adjacent and is not: it means *PR open, session ended pre-merge, the funnel resumes it next tick* — the funnel's own resume pointer, not an ask of the operator. Surfacing it would put work in the operator's queue that is not theirs to act on.

If the queue is empty, say `no pending feedback on this board` in one line and stop.

**Under `--dry-run`, STOP after printing the queue** — each item's number, title, and class, with **zero** writes and **no** `AskUserQuestion`. Same zero-mutation guarantee Step 3.5 gives the sweep half.

### 6.2 — Walk it one issue at a time

**Sequential, one issue per round — deliberately *not* `/sweep` Phase 1's ≤4 batch.** The batch is right for Phase 1, whose questions are homogeneous and pre-written. Here each item carries its own context and the operator is choosing a *direction*, so the value is in seeing one issue's full picture at a time. Render, ask, apply, advance.

Per item, render before asking: the issue **number + title**, **which producer parked it** (read from the flagging comment), the **question or decision text** verbatim, its **parent epic** if `board_parent_issue "$BOARD" <n>` prints one, and — for `funnel-escalated` — the PR and its CI verdict (6.3c).

### 6.3 — Apply the answer

**The ordering below is load-bearing, not stylistic: comment FIRST, release the baton SECOND.** Both drains read the **most recent comment at drain time** and only act on `no:assignee`.

- **Unassign-first** opens a window where a tick lists the item and parses the *question* comment as the reply → parse-miss → re-assign + "couldn't parse" noise.
- **Comment-first** means a failed comment write leaves the item flagged *and* assigned, so it re-enters the next run untouched. A missing marker self-heals; a missing **answer** under a "handled"-looking marker is silently lost.

This is the same asymmetry Step 4.4 already encodes for the flagging direction (foundation #684) — record the durable text before the markers move.

**(a) `needs-clarification` — answer, then clear.** Follows `/sweep` Phase 1's answer handling, **plus one deliberate addition — read the divergence, don't assume parity**:

1. `gh issue comment <n> -R "$repo" --body "Clarified (triage): <answer>"`
2. **Only if 1 succeeded:** `gh issue edit <n> -R "$repo" --remove-label needs-clarification --remove-assignee <operator>` (`<operator>` = the identity resolved in 6.1)

Clear the label **here** rather than leaving it for the funnel's `drain-clarification`. Clearing the label + releasing the item *is* that drain's entire job, so doing it inline saves a tick of latency and — more importantly — is correct on **both** funnel-enabled and funnel-less boards, with no need to probe which kind you are on. Do **not** write the `<!-- funnel:clarification-drained -->` sentinel: that marker is the funnel executor's, and a cleared label means the item never lists for a drain anyway.

**The `--remove-assignee` is the divergence.** `/sweep` Phase 1 and `/assess` both clear *only* the label and leave the assignee alone — so this step does strictly more than either, and the difference is intentional rather than an oversight. The reason it is safe here and not there: the assignment means *"this is in your queue awaiting your answer"* (foundation #684), so once the answer is recorded it must leave that queue or the operator's assigned-to-me view grows monotonically with items they have already handled. Unassigning is also the operator's own sanctioned baton-return gesture on a funnel board (foundation #657) — Step 6 simply performs it on their behalf. This does **not** contradict Step 4.4's "on a board with no funnel consumer, leave the assignment": that instruction protects an item whose *label is still set* and which therefore depends on a later `/sweep`//`/assess` to drain it. Here the label is cleared in the same breath, so the item is fully released and nothing is stranded.

**(b) `decision` — answer, then hand the baton to the drain.** The `decision` reply is **machine-parsed** under a closed-enum-or-escalate rule (`claude/decision-queue-contract.md` § 3): `chosen:` must name one of the options the question comment offered, or the drain re-assigns the operator with a "couldn't parse" comment and the item spins.

1. **Parse the offered option labels out of the question comment, and render them *as* the `AskUserQuestion` options** — the contract's closed enum and `AskUserQuestion`'s closed enum are the same shape, so the operator can only pick a label the question actually offered. Two things break that equivalence if you let them, and **both must be handled or the "closed enum" is a property of the prompt rather than of the bytes that reach the parser**:
   - **The ≤4-option cap.** `AskUserQuestion` takes **2–4 options**. With **≤4** offered labels, render them one-to-one. With **>4** you cannot — so print the full offered set as a numbered text list first, then ask a single-select over a bounded slice plus an explicit *"I'll name another"* escape (the tool's own free-text `Other` serves this) and take the label from the typed reply. `/build`'s risky-set gate documents the same cap and the same text-list-plus-bounded-ask escape (`claude/commands/build.md`, Approval — risky set) — reuse that shape, don't invent one.
   - **The verbatim requirement.** `chosen:` must name an offered label; the real parser is `funnel-tick.sh`'s, and it reads the **original question comment**, not your re-rendering. A label you round-tripped through a prompt can pick up a stray backtick from the comment's markdown, a trailing space, or case drift.

   **So validate before posting, on every path:** the string about to be written into `chosen:` MUST appear **byte-for-byte** in the question comment's offered set (strip the markdown the comment renders it in). On a mismatch, re-ask — never post a `chosen:` you did not round-trip. If the offered set genuinely cannot be parsed at all, fall back to free-text and **say so**; never guess a label.

   With the cap handled and the round-trip check in place, a parse-miss is closed off by construction. Without them it is not — and a `decision` that *looks* answered here still spins on the drain's closed-enum-or-escalate re-assign next tick, invisibly to the operator who believed it resolved.
2. `gh issue comment <n> -R "$repo"` with the reply in the **typed-reply grammar** — the fenced ` ```decision ` block with its `chosen:` key (the selected option label verbatim), or the `/choose <label>` shorthand. **Read the exact shape from `claude/decision-queue-contract.md` § 3 and emit it byte-for-byte; do not reproduce it from this spec.** That grammar is a **frozen surface** (`claude/presentation-plane.md` § Kernel table) whose sole owner is the contract — restating it here would be a second copy free to drift out of sync with the parser, exactly as `/build`'s decision-issue backend points at the contract rather than pasting it.
3. **Only if 2 succeeded:** `gh issue edit <n> -R "$repo" --remove-assignee @me`
4. **Keep the `decision` label.** ← the asymmetry against (a), and the easiest thing to get wrong. A *clarification* answer needs no application (it is free text the next drive reads), so triage can finish the job. A *decision* answer must still be **translated into an artifact** — that is what `tidy` § Answered decisions / the funnel's `drain-answer` do, and dropping the label *then* is the last step of that translation. Clearing it here would strand the answer with nothing to apply it.

**(c) `funnel-escalated` — not a question; a stuck code item.** The 5c merge tier could not land it (route-refused / terminally-red CI), so it has an **open or failed PR** and awaits a manual disposition. Resolve the PR and its CI verdict for context:

```bash
gh pr list -R "$repo" --search "Closes #<n>" --state all \
  --json number,url,state,statusCheckRollup
```

Offer, per item:
- **Merge it** → a **bare** `gh pr merge <pr> -R "$repo"` (enqueues; the merge queue owns the strategy — never guess a method flag, per `claude/CLAUDE.kernel.md` § Branch & PR policy's enqueue-method caveat). The close→Done cascade then closes the issue and moves the card. This is the one **outward** action in this step, and it fires only on an explicit per-item choice.
- **Close it** → the escalation is obsolete/abandoned. **Close the PR too, not just the issue:** `gh pr close <pr> -R "$repo" --comment "<reason>"` *then* `gh issue close <n> -R "$repo" --comment "<reason>"`. A `funnel-escalated` item has an open or failed PR **by definition** (that is what the 5c tier escalated), so closing the issue alone strands a live PR with no owner, no tracking issue, and no path back to attention — an artifact whose failure mode is to sit open forever. If the PR is already merged or closed, skip that call and close the issue alone.
- **Re-drive it** → `gh issue edit <n> -R "$repo" --remove-label funnel-escalated --remove-assignee <operator>`, returning it to the funnel's drive pool. ⚠ **Guard: offer this only once the stale PR is merged or closed.** Re-driving with a PR still open makes the next drive open a **duplicate PR** — precisely the hazard `/sweep` Step 1 drops these items to avoid. If the PR is open, say so and offer merge/close instead.
- **Leave it** → no writes; it stays in the queue for next time.

**Deferred / skipped items** (the operator passes on one) keep their labels and assignment untouched and re-enter the next run — same self-healing posture as `/sweep` Phase 1's unanswered arm.

### 6.4 — Summarise the queue

```
/triage --feedback — pending-feedback queue (repo <owner/repo>)
- Searched as: @me (<login>)  [+ <FUNNEL_OPERATOR login> — print this second identity ONLY when it diverged, per 6.1]
- Queue: Q open, assigned to you  (C needs-clarification, D decision, E funnel-escalated)
- Clarifications answered: A  (#s → label + assignee cleared, released to drive)
- Decisions answered: B  (#s → chosen: <label>; `decision` label retained for the drain to apply)
- Escalations disposed: F  (#s → merged / closed / re-driven)
- Deferred (left in the queue): G  (#s)
```

### 6.5 — Emit the run telemetry record (`--feedback-only` runs only)

**Do NOT reuse Step 4.9's record, and do NOT skip telemetry entirely — both are wrong here.** Step 4.9's counters describe the **sweep** (candidates intook, survivors promoted to Ready, items held back in Backlog); on a `--feedback-only` run all three are zero because the sweep never ran, so emitting `--command triage` would assert *"the sweep ran and found nothing"* — the exact state that stream exists to distinguish from *"the sweep didn't run"*. But omitting the emit is no better: a `--feedback-only` run **mutates GitHub** (comments, labels, assignees, PR merges and closes) and, per `validate-command-run-emit.sh`'s own rationale, `/triage` has no plan-note footer — so with no record a fully-mutating run produces **no signal that it happened at all**.

So a `--feedback-only` run emits its own record under a **distinct `command` value**, with 6.4's counters mapped onto the stream's generic field meanings (`items_processed` = "how many items the run drove/considered", `merged` = "how many reached a successful terminal outcome", `parked` = "how many were parked/deferred/escalated" — `meta/data/raw/README.md`, which owns this shape):

```bash
"$(git rev-parse --show-toplevel)/workflows/scripts/emit-command-run.sh" \
  --command triage-feedback --board "$BOARD" \
  --items-processed <Q — queue size, 6.4> \
  --merged <A+B+F — clarifications answered + decisions answered + escalations disposed> \
  --parked <G — deferred, left in the queue>
```

Same resolution and failure posture as Step 4.9: resolve the script bare repo-relative, treat a failed path resolution in a non-vendoring checkout as a no-op, and never let a missing or failing emit block the 6.4 summary (the script is `|| true`-safe — a write failure warns to stderr and exits 0).

**This step does NOT run on a `--feedback` run** — that run swept, so Step 4.9 already emitted its `triage` record and the run is not silent. Giving the queue walk counters of its own *on that path too* would mean two records for one run, which the stream's "one record per command run" invariant does not allow; that is the follow-on, not something to bolt on here.

**Tail note when neither `--feedback` nor `--feedback-only` was passed.** The queue search in 6.1 is one cheap call, so the Step-5 summary should close with a one-line pointer whenever it is non-empty — `N issues are pending your feedback on this board — re-run with --feedback (or --feedback-only to skip the sweep) to review them` — and print nothing when it is empty. A queue the operator has to remember to go look at is a queue that silently grows; this is the same reasoning as the mandatory Step-1 intake-deferred line (foundation #164 — deferral is always reported, never silent).

## Failure modes

- **Unmapped repo (inference fails).** If neither `--board` nor `--project` is passed and `gh repo view` + `board_repo` reverse-lookup finds no match for the current repo, stop at Step 0.3 with `/triage: cannot infer board — pass --board <N> (3=stageFind, 4=foundation, 5=ssmobile, 6=subsetwiki, 7=temperloop kernel) or --project <name>, or run from a board-mapped repo` before any board read or write. The arbitrary stageFind-`3` default is still gone; inference is context-derived (bounded to the local repo) and only fails when the repo genuinely isn't registered.
- **`project` scope missing.** Stop at Step 0 with the `gh auth refresh -s project` hint — never half-write the board.
- **Board adapter not found / board not registered.** If `BOARD_LIB` resolves to neither `scripts/lib/board.sh` nor `workflows/scripts/board/lib/board.sh`, or `board_repo "$BOARD"` is empty (the board number isn't in the adapter's registry), stop — run /triage from a foundation or board-consuming checkout and confirm the board is registered in `board.sh`'s `board_repo()`. If `board_resolve` finds no `Status` field carrying `Backlog`/`Ready`/`Done`, the board isn't set up for this pipeline (for a not-yet-migrated board, [[Decisions/foundation - Migrate board #4 onto Status field]] is the fix).
- **Sub-issues API unavailable.** Fall back to the task-list/`Part of #` convention (Step 4.3); note it in the summary. Don't fail the run over cosmetic linkage.
- **`board_active_milestones` fails vs. returns empty (Step 1).** Branch on the accessor's **exit code**, not on whether milestones exist (temperloop#152): a **non-zero** return means the milestone REST fetch itself failed — **warn and STOP**, don't silently defer every milestoned Backlog item (a silent mass-defer prints a plausible count that masks the failure); re-run once REST is healthy. A **zero** return with empty output is a genuinely-empty active set — the normal default (milestones default inactive) — so **proceed**: unmilestoned Backlog items intake, milestoned ones defer. Do not use milestone *existence* as a proxy for fetch *success*; it false-STOPs a board whose milestones are all legitimately inactive (e.g. the issues-only kernel tracker board 7, whose `post-fable`/`pending` milestones carry no active marker).
- **No survivors after cull.** Report "Backlog/doc-set culled to zero — nothing to group" and stop. Don't manufacture an epic.
- **Candidate is both a decision and build work.** Surface via `AskUserQuestion` (route the decision off-board *and* keep a build survivor, or treat as one) — don't guess.
- **Doc has no actionable findings.** Report "no candidates derivable from <doc>" and continue with the board-only set.
- **Re-run after a partial pass.** Idempotent: already-`Ready` items aren't re-intook; epics/issues are probe-before-create. Safe to re-run.
- **Pending-feedback queue search fails (Step 6.1).** Report it in one line and stop the step — never half-walk a queue you couldn't fully read (a partial queue silently under-reports what is pending on the operator, the same class of masking failure the Step-1 `board_active_milestones` exit-code branch guards against). On a `--feedback` run the sweep half (Steps 1–5) has already completed and stands; only Step 6 stops. On a `--feedback-only` run the search **is** the run, so it stops having done nothing — say so plainly rather than printing an empty-queue summary that reads like success.
- **Analysis-doc paths passed with `--feedback-only`.** Stop with a usage error: `/triage: --feedback-only runs the pending-feedback queue alone — it does not ingest analysis docs. Drop the doc paths, or drop --feedback-only to sweep them.` The two are contradictory (doc intake is Step 1, which this flag skips), and silently ignoring the docs would let an operator believe a sweep ingested them. Fail loud on the contradiction rather than honouring half the invocation.
- **Answer comment fails to post (Step 6.3).** Do **not** apply the label/assignee change — leave the issue flagged and assigned so it re-enters the next run. The comment is the durable record; the markers are recoverable state. Never invert this order (foundation #684).
- **`decision` offered options unparseable (Step 6.3b).** Fall back to free-text and **say so** — never guess a label into `chosen:`. A guessed label that isn't in the offered set is a parse-miss at drain time, which re-assigns the operator and spins the item; an honest free-text reply at least reaches a human. Closed-enum-or-escalate, exactly as `claude/decision-queue-contract.md` § 3 requires of the driver.
- **`decision` offers more than 4 options (Step 6.3b).** `AskUserQuestion` renders 2–4, so a one-to-one mapping is impossible — do **not** silently drop the tail (that would present a *partial* enum as if it were the whole one, and the dropped options become unpickable without any error). Print the full offered set as text and ask over a bounded slice plus an "I'll name another" escape, then round-trip the answer as below.
- **`chosen:` fails the verbatim round-trip (Step 6.3b).** The label about to be posted does not appear byte-for-byte in the question comment's offered set — re-ask rather than posting it. The drain parses the *original* comment, so a near-miss (stray backtick, trailing space, case drift) reads as a parse-miss there and spins the item while looking answered here.
- **Operator identity diverges from `@me` (Step 6.1).** `$FUNNEL_OPERATOR` and the `gh`-authenticated login can be configured apart, and the two producers assign differently (Step 4.4 → `@me`; the funnel → `$FUNNEL_OPERATOR`). Search the union and name the identities searched. A `@me`-only search on a divergent host prints "no pending feedback" over a real queue — a wrong answer with no error, the same silent-under-report class as a masked intake failure.
- **`funnel-escalated` closed without its PR (Step 6.3c).** Closing the issue alone strands the open/failed PR the escalation exists because of. Close the PR in the same disposition, or state explicitly that it is being left for manual cleanup — never leave it unmentioned.
- **`funnel-escalated` re-drive with an open PR (Step 6.3c).** Refuse it and offer merge/close instead — re-driving an item whose PR is still open makes the next drive open a **duplicate PR** (foundation #697 / the `/sweep` Step 1 duplicate-PR guard).
