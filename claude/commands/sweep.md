---
description: Drain a board's Ready **singletons** — issues triage left ungrouped (not a sub-issue of any epic) — sequentially. Phase 1 surfaces every blocking clarifying question in one batch and records the answers; Phase 2 fixes each issue one at a time by invoking the existing `build-level.mjs` workflow per issue (claim → isolated worker → PR → CI → merge), parking any issue whose worker hits a question and moving on. The singleton-path peer to `/build` (which drains the epic'd work).
argument-hint: "[--board <N>] [--dry-run] [--unattended]"
---

You are running the **sweep** command. Goal: drive every **Ready singleton** on a board — an issue triage marked Ready but left **ungrouped** (it is *not* a sub-issue of any epic) — from open to merged, **one at a time**. This is the singleton-path peer to `/build`: `/build` drains the *epic'd* work (via a plan note); `sweep` drains the *lone* Ready issues. Together they clear the whole Ready pool with no overlap — the "not a sub-issue of an epic" filter is the seam between them.

```
                 ┌─ epic'd survivors ─► /assess --epic N ─► /build
/triage  Ready ──┤
                 └─ singletons       ─────────────────────────► /sweep   ◄── you are here
```

Because the singletons skip `/assess`, they have **no pre-execution contract-clarification stage**. So `sweep` adds one: **Phase 1**, an upfront question sweep (the singleton path's missing `/assess`-equivalent) that resolves ambiguity *before* any fix worker runs.

## Inputs

- `--board <N>` (optional) — which board's singletons to drain. stageFind = `3` (repo `<org>/stageFind`), foundation = `4` (`<org>/foundation`). Explicit `--board` is **preferred**; if omitted, the board is **inferred from the local repo** (see Step 0.2), consistent with `/triage` and `/assess`. Inference is bounded to the repo you're standing in — it resolves only to that repo's registered board and prints the resolution before acting, so it cannot silently pick an *unintended* board (the prior arbitrary stageFind-`3` default is gone; foundation#547 established that bounded, printed inference is not the silent-board footgun the old default was).
- `--dry-run` (optional) — rehearsal: validate + build the pool + run Phase 1's detection, then **print** the pool + which issues carry open questions, with **zero** mutation (no claim, no worker, no merge, no label/comment writes). See Step 3's dry-run note.
- `--unattended` (optional) — **default posture** (per the batch-unattended convention): after Phase 1's answers are in, Phase 2 runs without further prompts — it auto-merges each green PR and **parks** anything that escalates rather than halting. Phase 1 is the one interactive gate; on a truly operator-absent run it leaves all flagged issues parked and reports (see Step 2).

## Operating principles

- **Reuse `build-level.mjs` — do not reimplement the fix loop.** The per-issue mechanics (claim → worktree → isolated worker → acceptance gate → scan → push-by-SHA → PR open → CI poll) already live in the saved Workflow `claude/workflows/build-level.mjs` (foundation #422), which drives a *set* of items and returns a small `{parked, escalations}`. `sweep` invokes it **once per issue** — a 1-item "level" — sequentially. No new workflow file; the command is a thin conversational driver over the existing workflow + spine. See [[Decisions/foundation - build workflow-spine invocation seam]].
- **Per-issue memory isolation is structural, not aspirational.** Each per-issue workflow invocation is a **fresh process**, and the fix worker inside it is an isolated `agent({schema})` whose context is **discarded on return** — so nothing bleeds between issues, and the conversational orchestrator only ever sees the small `{parked, escalations}` object per issue (bounded context across the whole sweep).
- **Sequential — never parallel.** Issues are driven **one at a time** (each per-issue invocation has a single-item `items` array). No level fanout, no merge gate batching.
- **Shared-hotspot / composition-root awareness.** When consecutive singletons touch the same file — the canonical example is a composition root (e.g. `AppComposition.swift` / `SettingsView.swift` in a mobile app), but any file that registers/wires up components plays the same role — N's merge can land while N+1 is mid-build, leaving N+1's worktree on a stale base. The pre-PR-open rebase (the `pr.sh rebase` step at `/build`'s 3f push/PR-open boundary, #525) surfaces this conflict deterministically as a `rebase-conflict` escalation rather than a post-PR-open CONFLICTING dead-poll. When building the Phase-2 set, **sequence hotspot-touching singletons deliberately**: if two or more Ready issues are known to touch the same shared file, put the highest-priority one first and let the sequential loop handle the rest — each one rebases cleanly onto the previous one's merge.
- **Park-on-question, no modal halt.** When an issue's worker returns a question (a `blocked` / `design-fork` / `failed` escalation), `sweep` does **not** halt the run or open a conversational round-trip (the `/build` 3d-esc behavior). It **parks** the issue on the board — moves it back to `Ready` (out of In Progress), adds the `needs-clarification` label + the question as a comment, and **assigns the operator** (routing it into their assigned-to-me queue at source, foundation #684) — and **advances** to the next issue. The `needs-clarification` **label** is the open-question gate (there is no `Blocked` Status bucket — it was retired in #435; an open *question* is a label, just as a dependency block is a native `blocked_by` edge). Parked issues re-enter the **next run's Phase 1** automatically — the label, not a status, carries the question across runs, so the loop self-heals.
- **Claim-first, per issue.** The board is a cross-session lock. Each issue is **claimed In Progress as the first per-item action** (the workflow's 3a, before its worker investigates). Phase 1's read pass is shallow triage-style detection (like `/triage` reading Backlog or `/next` reading Ready) and does not claim — only Phase 2's fix loop claims, one issue at a time (so WIP stays at 1).
- **The conversational/workflow split (mirrors `/build` under `--workflow`).** The **workflow** owns one issue's 3a–3g and returns `{parked, escalations}` — it never merges, never writes outside its return. **This command (conversational)** owns: Phase 1 (`AskUserQuestion` cannot run inside a workflow), the per-issue **merge**, the **park-on-question** board writes, and the report.
- **The `needs-clarification` label is the open-question marker.** `/triage` drops it (with a `needs-clarification: <question>` comment) on underspecified survivors at source; `sweep` Phase 1 consumes and clears it; park-on-question re-adds it. It is also consumed by `/assess` on the epic path, and — on an autonomous board — **drained by the funnel** when the operator answers + unassigns (the label is cleared so the item drives again; foundation #657). A plain GitHub label (advisory, mirrors `spike`).
- **Board-native only.** This command requires the board adapter + a registered board (the Step 0 probe). With no board it stops — there is no boardless mode (the singleton pool *is* a board query).

## Step 0 — Validate + board probe

Reuse `/build` Step 0's probe verbatim. Run in parallel:

1. `gh auth status` — must list the **`project`** scope (board reads/writes need it). Missing → stop with the `gh auth refresh -s project` hint.
2. **Board probe.** Set `BOARD_LIB` = the first of `scripts/lib/board.sh` or `workflows/scripts/board/lib/board.sh` that exists; `source "$BOARD_LIB"`. Resolve the board from `--board`; **if omitted, infer it from the local repo** (the same reverse-lookup `/triage` Step 0.3 uses): `repo=$(gh repo view --json nameWithOwner -q .nameWithOwner); BOARD=""; for b in 3 4 5 6; do [ "$(board_repo "$b")" = "$repo" ] && BOARD="$b"; done`. If a match is found, print `inferred board $BOARD (repo $repo)` before any board read; if **no** candidate matches (an unmapped repo), STOP with `/sweep: cannot infer board — pass --board <N> (3=stageFind, 4=foundation, 5=ssmobile, 6=subsetwiki) or run from a board-mapped repo`. Set `CLAIM`/`RELEASE` = the `claim.sh`/`release.sh` next to `BOARD_LIB` (or the `claim`/`release` commands on `PATH`). Confirm the repo maps to the board: `repo="$(board_repo "$BOARD")"`. **No adapter or no registered board → stop** ("board integration unavailable — run from a board-enabled checkout").
3. **Resolve the workflow-invocation context** (passed to every per-issue `build-level.mjs` call): `repoRoot="$(git rev-parse --show-toplevel)"`, `ownerRepo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"` (the workflow has no shell to derive it), and `claimCmd` = the absolute path to `claim.sh` (`$(dirname "$BOARD_LIB")/../claim.sh`, or `claim.sh` on PATH). Also resolve `workflowPath` = the deployed Workflow script (`"$HOME/.claude/workflows/build-level.mjs"`) — Phase 2 invokes it by **`scriptPath`**, NOT `name:` (the Workflow tool's `name:` resolves built-ins ONLY — deep-research/code-review — never deployed user workflows; #437).
4. **Source the batch-pipeline config + resolve the quota gate (best-effort).** `source workflows/scripts/build/build.config.sh` (bare repo-relative, the same convention this command already uses for `workflows/scripts/build/worktree.sh` in the park-cleanup step) — pulls the `BUILD_QUOTA_*` knobs into scope for the Step-3 quota gate. Then resolve and **guard** the gate script: `quotaGate="workflows/scripts/build/quota-gate.sh"; [ -x "$quotaGate" ] || quotaGate=""`. If the config/script is absent (a non-vendoring checkout), proceed: an empty `$quotaGate` makes the Step-3 gate a no-op (the optional gate must never break or stall a run).

If any check fails, surface in one line and stop.

## Step 1 — Build the singleton pool

`board_resolve "$BOARD"` once (whole-board read). From `BOARD_ITEMS_JSON`:

1. **Fix pool** = items whose `.status` is `Ready` **AND** that are **not a sub-issue of any epic** — for each Ready item, `board_parent_issue "$BOARD" <issue#>` (the REST-cheap parent check, the same one `/next` uses) prints **empty**. A Ready item *with* a parent is an epic leg → it belongs to `/build`, **skip it**.
2. **Exclude `funnel-escalated` items** — a Ready singleton carrying the `funnel-escalated` label (foundation #697) is a stuck code item the autonomous funnel's rung-5c merge tier could not land (route-refused / terminally-red CI): it already has an **open or failed PR** and is assigned to the operator, awaiting a **manual merge or close**. `sweep` has no resume-mode (unlike the funnel's #624 hand-off), so driving it through Phase 2 would open a **duplicate PR**. **Drop it from the fix pool** the same way an epic leg is skipped, and **report it** in Step 4 as escalated/skipped (it clears when the operator closes the issue or removes the label — closing/merging the PR alone does not remove an issue label). This is the read-time counterpart of the `funnel_escalated` drive-park gate in `funnel-tick.sh` and the `/next` skip — every Ready-pool consumer that *drives* must honor it. (Distinct from `needs-clarification`, which is an answerable question Phase 1 consumes, not an open-PR escalation.)
3. **Parked-on-question items re-enter automatically** — a prior run's parked issue stays in `Ready` carrying the `needs-clarification` label, so it is **already in the fix pool above**; Phase 1 (Step 2) re-detects the label and re-surfaces its question. There is no separate `Blocked` re-entry pool — the retired `Blocked` bucket (#435) is gone; the label, not a status, is what carries the open question across runs.

`board_parent_issue` is a per-item REST call — gate it on the `Ready` slice only, never the whole board. Pull each pooled issue's title, body, and labels with `gh issue view <n> -R "$repo" --json title,body,labels,url`.

If the pool is empty, say so in one line and stop.

## Step 2 — Phase 1: the upfront question sweep (the one interactive gate)

A pooled issue **has an open question** iff it **carries `needs-clarification`** (triage-flagged or parked by a prior run) **OR** your own read of it judges it **underspecified** — the fix can't start because the intended behavior, the choice between two designs, or a missing decision is genuinely ambiguous (not merely a fact a worker could look up). When *you* judge an unflagged issue underspecified, **comment the question FIRST, then label+assign** (`gh issue comment <n> -R "$repo" --body "needs-clarification: <the question>"$'\n\n'"Once answered: on the autonomous funnel board, unassign yourself to release it straight back to the driver; on other boards leave it as-is — the next /sweep or /assess clears the label. Either way your answer is consumed."`, and only after it succeeds `gh issue edit <n> -R "$repo" --add-label needs-clarification --add-assignee @me`), so the question is durably captured **before** the "handled" markers land and the issue is routed to the operator's assigned-to-me queue at source like a triage flag (the funnel router then merely parks it, never re-derives/re-posts the question the way the retired `route-needs-input` did — foundation #684; if the comment call fails, do not label/assign — leave it un-flagged to re-enter the next run). **Under `--dry-run` this detection is read-only** — identify and *print* which issues carry or raise questions, but make **no** comment/`--add-label`/`--add-assignee` write and **no** `AskUserQuestion` (the dry-run's zero-mutation guarantee — see Step 3).

1. **Gather every open question across the pool**, reading triage's recorded `needs-clarification: <question>` comment when present (else derive the specific question from the issue).
2. **Surface them in ONE batch** via `AskUserQuestion` (≤4 per call — loop in groups for more; fall back to a written list the operator answers if there are many).
3. **On each answer:** record it as an issue comment (`gh issue comment <n> -R "$repo" --body "Clarified (sweep): <answer>"`) and **remove** the label (`gh issue edit <n> -R "$repo" --remove-label needs-clarification`). A parked issue already sits in `Ready` (the open question, not a status, parked it — #435), so there is no status to flip back; clearing the label is what lets Phase 2 drive it. The recorded answer rides into Phase 2 as the synthesized item's `notes`.
4. **Unanswered / deferred** (the operator skips one) → leave it flagged and **skip it this run** (it stays for the next).

**Unattended / operator-absent run:** do **not** block forever on an absent operator. Take the safe default — **leave every flagged issue parked (flagged, skipped)** — and proceed to Phase 2 with only the **un-flagged** issues. This is a **`batch-at-ritual`** deferral ([[Context/foundation - AskUserQuestion severity taxonomy]]), so it must NOT default *silently*: per `claude/CLAUDE.md § Unattended pending-decisions surface`, append one `### open` entry to `~/dev/mind/Context/pipeline - pending decisions.md` via `mcp__obsidian-builtin__vault_append` — **Decision:** *sweep left clarifying questions unanswered (issues #N, …)*; **Default taken:** *leave-all-flagged; proceed with un-flagged only*; **Disposition:** *auto-taken (operator-absent); `needs-clarification` labels retained as the operational record*; **Status:** *open* — so the next `check-in` surfaces them (the label is the operational record; this entry is the ritual-facing signal `check-in` actually reads). **This is the fifth `batch-at-ritual` writer site** (registered in `claude/CLAUDE.md § Unattended pending-decisions surface` and `tidy.md` Step 3).

After Phase 1, the **Phase-2 set** = the fix pool minus every still-flagged issue.

## Step 3 — Phase 2: the sequential fix loop

**Record the ordered Phase-2 set as an explicit tracked artifact before driving any issue.** Use `TaskCreate` to mint a checklist — one entry per issue (`[ ] #N: <title>`) in pool order. This is the worklist-lock: every entry must reach a terminal disposition before the Step-4 report runs, so skipping is structurally impossible.

For each issue in the Phase-2 set, **one at a time**, invoke the saved Workflow `build-level.mjs` as a **1-item level** via the Workflow tool:

```
// Invoke by scriptPath, NOT name: — the Workflow tool's name: resolves built-ins
// ONLY (deep-research/code-review), never deployed user workflows (#437). `args` is
// delivered to the script as a JSON STRING; build-level.mjs parses it itself.
Workflow({ scriptPath: workflowPath, args: {
  repoRoot, board: <BOARD>, ownerRepo, claimCmd,
  planLink: "",          // EMPTY — singletons have no vault plan note; pr.sh wraps planLink in [[ ]]
                         // (a wikilink), so a URL here renders a broken link. Linkage rides
                         // `Closes #N` (from ghIssue) + `source: #N` instead. pr.sh skips the block on "".
  items: [ {
    slug,            // kebab from the title, SUFFIXED with `-<N>` (the issue number), total ≤40 chars —
                     // the number guarantees a unique worktree path `<repoRoot>.wt/<slug>` by construction
    branch,          // derived <type>/<slug> per [[Decisions/foundation - Branch naming convention]]
                     //   (type from the issue's labels: bug→fix, enhancement→feat, docs→docs, else fix)
    title,           // the issue title (refine to an imperative PR title)
    kind: <'spike' if the issue carries the spike label, else 'code'>,
    ghIssue: <N>,    // → the workflow's pr.sh open emits a bare `Closes #N`
    alsoCloses: [],
    model: <undef>,  // no plan size → inherit the session model (top tier; safe)
    acceptance: <checkable bullets from the issue body; if none, the Phase-1 answer, else "(self-verify the issue is resolved)">,
    source: "#<N>",
    scope: <the issue title / first body line>,
    notes: <the Phase-1 recorded answer, if any — so the worker sees the clarification>
  } ],
  verdicts: {}, onlySlugs: []
} })
```

The workflow claims the issue (3a — claim-first), creates the deterministic worktree (3b), runs the **isolated worker** (3c), runs the acceptance gate + closing-keyword scan + push-by-SHA + PR open + CI poll (3e.5–3g), and **returns `{parked, escalations}`**. Branch on the return:

- **`parked: [{ slug, pr, pushed_sha, acceptance_results }]`** (worker done) → **land it**, branching on whether a PR exists:
  - **`pr` is set** (a `code` item, CI green) → **merge** `gh pr merge <pr> --auto` (the queue owns strategy + branch lifecycle on a protected `main`; the close→Done cascade moves the card). Record **fixed** (with PR#). **Then converge the worktree in-lane:** `build-level.mjs` leaves the merged issue's worktree intact (the workflow removes no worktrees), so — exactly as the escalation branch below already does — reclaim it now: `workflows/scripts/build/worktree.sh remove "$repoRoot" <slug>` (the `$repoRoot` resolved in Step 0 — this session's OWN checkout, never a foreign canonical checkout, per the working-tree-ownership rule). This closes the **post-merge-convergence gap** so cleanup no longer relies solely on the next session-start sweep. It is **idempotent by construction, not by a new guard** — `worktree.sh` `cmd_remove` already returns `REMOVED` when a worktree or `build/<slug>` branch existed and `NOT_FOUND` when neither did, so a re-run is a safe no-op and there is no double-remove error. *(Backstop: the **deploy-mini session-start sweep** (F#653), which prunes merged locals in every clean-on-main checkout at session start, plus `worktree.sh prune "$repoRoot"`, remain the **crash-path** net for a session that died before this step — the safety net, not the primary mechanism.)*
  - **`pr` is `null`** (a **spike** singleton — the issue carried the `spike` label, so `build-level.mjs` parks a verdict-only item with `pr: null, pushed_sha: null` and **no PR**) → do **NOT** run `gh pr merge null` (a silent no-op that would falsely report "fixed"); **close the issue directly** `gh issue close <N> -R "$repo" --comment "Spike verdict captured (sweep)."` (the close→Done cascade moves the card). Record **resolved (verdict)**. Then reclaim any worktree in-lane the same way: `workflows/scripts/build/worktree.sh remove "$repoRoot" <slug>` (idempotent `REMOVED`/`NOT_FOUND` — safe no-op if the spike path built none).
- **`escalations: [{ slug, kind, payload }]`** (the worker hit a question / blocker — `blocked` / `design-fork` / `failed` / a spine escalation) → **PARK-AND-CONTINUE** (never a modal halt):
  1. `board_set_status "$(board_item_id <N>)" "$BOARD_OPT_READY"` — move it back to `Ready` out of In Progress (the `Blocked` Status option was retired in #435; the open *question*, carried by the label added next, parks it — not a status bucket). `BOARD_OPT_READY` is one of the exported `BOARD_OPT_{BACKLOG,READY,INPROGRESS,DONE}` constants.
  2. `gh issue comment <N> -R "$repo" --body "Parked by sweep — <the question from payload: design_fork.decision/options, or questions[], or failure_reason>. Where it stands: <one line>. Once answered: on the autonomous funnel board, unassign yourself to release it straight back to the driver; on other boards leave it as-is and the next sweep run's Phase 1 clears the label. Either way your answer is consumed."` — post the question **first**, so it is durably recorded before the "handled" markers in step 3 land. The closing line is **board-safe** (foundation #657): unassigning is the operator's baton-return gesture only where a funnel consumer exists (stageFind today) — the funnel autonomously drains an *unassigned* `needs-clarification` item, clearing the label so it drives again; on a board with no funnel it tells the operator to leave the assignment (keeping #684's queue visibility) and re-enter via the next sweep.
  3. `gh issue edit <N> -R "$repo" --add-label needs-clarification --add-assignee @me` — **only after step 2's comment succeeds.** This label is the open-question gate: it re-enters the next run's Phase 1, and read-time skills (`/next`) skip a `Ready` item carrying it so it is not recommended as workable until answered. The `--add-assignee @me` routes the parked item into the operator's assigned-to-me queue **at source** (matching `/triage`), so the funnel router only parks it (`route-already-assigned`) rather than re-deriving/re-posting the question the way the retired `route-needs-input` did (foundation #684). Ordering matters: the funnel never re-posts a missing question, so a labeled+assigned item with no question comment is silent loss — if the step-2 comment failed, do not apply the label/assign; leave it un-flagged to re-park next run.
  4. `"$RELEASE" <N> --board "$BOARD"` (clear the claim marker), then `workflows/scripts/build/worktree.sh remove "$repoRoot" <slug>` — the workflow leaves an escalated worktree **intact**; `sweep` discards it (resume = re-run, not in-place continuation), so remove it.
  5. Record the issue as **parked** (with the question) and **advance to the next issue**.

After every branch above, **mark the checklist entry for this issue with its terminal disposition**: `[x] #N: <title> — <merged PR#|resolved (verdict)|parked: <reason>>`. The three terminal dispositions are `merged`, `resolved (verdict)` (spike close), and `parked` (escalation). An entry that remains unchecked at report time is a hard error (see below).

Each invocation is a fresh workflow process — the worker's context is discarded on return, so no state carries to the next issue. Do not pre-spawn or overlap issues; this loop is strictly sequential.

**5-hour quota gate — after each fix, before the next issue.** Once an issue lands (merged / closed / parked) and **before claiming the next issue in the Phase-2 set**, run the decision script resolved in Step 0. **Skip the gate when `$quotaGate` is empty** (no gate script in this checkout) or after the **last** issue — both are no-ops (proceed):
```
"$quotaGate"            # the guarded path from Step 0; skip if empty
```
Branch on the verdict (identical semantics to `/build` Step 4e-quota):
- **`proceed`** / **`unavailable`** → continue to the next issue. **`unavailable` fails open** — a missing/stale/unreadable quota snapshot never pauses the run.
- **`pause`** (remaining 5h quota < `BUILD_QUOTA_PAUSE_PCT`) → **pause and auto-resume in-session:** note the pause in the Step 4 report state (and, optionally, a one-line comment is unnecessary — singletons have no plan note), launch the wait as a **background** `sleep <wait_secs>` (`run_in_background: true`; foreground `sleep` is blocked), end the turn announcing the resume time, and on the wake re-invocation re-run `"$quotaGate"` (loop while still `pause`) then continue with the next issue. The per-issue loop is the clean, state-consistent boundary — no issue is left half-driven by a pause. Skip the gate after the **last** issue (nothing left to protect → fall through to Step 4).

**`--dry-run`:** STOP before Step 3's first invocation. Print the singleton pool, which issues carry open questions (Phase-1 detection only — no `AskUserQuestion`, no label writes), and the Phase-2 set that *would* be driven. End with "Re-run without `--dry-run` to execute." Zero mutation.

## Step 3.5 — Pre-report terminal-state assertion

Before emitting the Step-4 report, assert that **every entry in the Phase-2 TaskCreate checklist is checked** (has a recorded terminal disposition). Specifically:

1. For each checklist entry, confirm it carries one of: `merged`, `resolved (verdict)`, or `parked`.
2. **Any unchecked entry is a hard error** — do NOT emit the Step-4 report. Instead, surface loudly:

   > **SWEEP ABORT — terminal-state assertion failed.**
   > The following Phase-2 issue(s) have no recorded terminal disposition: #N `<title>`, …
   > This indicates a bug in the sweep loop (an issue was silently skipped). Investigate before re-running.

   Stop. Do not attempt partial-report output. The hard stop makes a silent skip visible immediately rather than propagating a false-complete signal downstream to the board or operator.

This assertion is the structural guarantee that makes silent skips impossible: the TaskCreate checklist is the worklist-lock; the pre-report check is the key.

## Step 3.6 — Emit the run telemetry record

`/sweep` has no plan-note footer, so without an explicit emit here a whole run — or a run that silently stopped emitting — produces **no** signal at all (the June silent-failure class: a never-written stream is indistinguishable from "nothing to do"). Once Step 3.5's assertion passes (every Phase-2 entry has a terminal disposition), append ONE command-run record from the checked-off Phase-2 checklist — this call is the executable emit point, not a prose reminder, and its presence is mechanically enforced by `workflows/scripts/validate-command-run-emit.sh` (wired into `scripts/quality-gates.sh`), which fails CI if this invocation is removed:

```bash
"$(git rev-parse --show-toplevel)/workflows/scripts/emit-command-run.sh" \
  --command sweep --board "$BOARD" \
  --items-processed <Phase-2 checklist size> \
  --merged <count of "merged" + "resolved (verdict)" terminal dispositions> \
  --parked <count of "parked" terminal dispositions>
```

Resolve the script bare repo-relative (same convention as `workflows/scripts/build/build.config.sh` in Step 0.4) — if it is absent from a non-vendoring checkout, the `"$(git rev-parse --show-toplevel)/…"` path simply fails to execute; treat that as a no-op and continue (never let a missing/failing emit block or delay the report). The script itself is `|| true`-safe: a write failure warns to stderr and exits 0, so this call never fails the run either way.

## Step 4 — Report

End with a re-orientation block. **The report must enumerate a terminal disposition for every Phase-2 pooled issue** — no issue may appear without one of `merged`, `resolved (verdict)`, or `parked`. (This is automatically satisfied when Step 3.5 passes.) For sweeps larger than five singletons, list all issues in a table (issue# | title | disposition | detail) so the operator can scan the full set at a glance rather than inferring coverage from aggregates.

- **Fixed** — each issue → its merged PR#.
- **Resolved (verdict)** — each spike issue → closed-directly note.
- **Parked (open question)** — each issue → the question / reason it parked, and that it carries `needs-clarification` for the next run's Phase 1.
- **Skipped (flagged, unanswered)** — issues left flagged in Phase 1 (deferred / operator-absent). These are NOT Phase-2 pool members (they were filtered out in Step 2) and thus not subject to the Step-3.5 assertion — but they must still appear in the report.
- **Skipped (funnel-escalated)** — Ready singletons carrying `funnel-escalated` dropped from the fix pool in Step 1 (a stuck 5c code item with an open/failed PR awaiting the operator's manual merge/close, #697). NOT Phase-2 members; report them so the operator sees they were surfaced, not silently swept.
- One line: parked + skipped issues re-enter the next `sweep` run's Phase 1 automatically (the self-healing loop).

End with a compact **refs legend** (qualified issue/PR numbers → title) per the communication conventions.
