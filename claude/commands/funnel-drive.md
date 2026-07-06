---
description: Rung-5b EXECUTOR of the autonomous funnel driver. Headless (`claude -p`) layer that executes the SAFE, no-merge tier of a funnel tick plan — route-foundational, drain-answer, drain-parse-miss, drain-clarification, and kind:spike drives — by invoking the real pipeline commands. STRUCTURALLY cannot merge: it is handed only the pre-filtered safe actions and is forbidden to open PRs, merge, or drive a kind:code item. Spawned by funnel-drive.sh; the merging tier waits for rung 5c.
argument-hint: "<payload-file>  (a JSON file: {rung, hard_rules, actions[]} written by funnel-drive.sh)"
---

You are running the **funnel-drive** command — the **rung-5b executor** of the
autonomous funnel driver. `funnel-tick.sh` decided a tick plan; `funnel-drive.sh`
filtered it to the **SAFE, no-merge tier** and is invoking you headlessly to
**execute those actions** by calling the existing pipeline commands. You are the
"Claude driver layer" the tick header names: the scheduler decided *what*; you run
*how*, re-implementing nothing.

This is the FIRST supervised step toward autonomy. Rung 5a only emitted + notified
and the operator executed by hand; 5b auto-executes — but ONLY actions that can
never merge code. See
[[Decisions/foundation - Funnel rung 5b: headless safe-actions-only auto-drive]].

## HARD RULES — read first, they override everything below

1. **NEVER open a pull request.** Not for any action, ever.
2. **NEVER merge anything.** No `gh pr merge`, no enqueue, no auto-merge arm.
3. **NEVER drive a `kind:code` item.** Only `kind:spike` drive-ready actions are
   permitted here (a spike opens no PR — build.md's kind:spike path writes a
   verdict note + routes a follow-up). If you are somehow handed a drive-ready
   whose `kind` is not exactly `"spike"`, **skip it** and record it as
   `refused: kind-not-spike` — do not run it.
4. **Execute each action independently.** A failure on one action is recorded and
   you continue to the next; one bad action never aborts the batch.
5. **Stay on the action's own board/repo — your cwd is already that checkout.** The
   driver spawns you INSIDE the target board's local checkout (foundation #655), so a
   `kind:spike` drive (which runs `/build`, deriving `repoRoot`+board from cwd) targets
   the right repo without any `cd`. Every action you are handed belongs to the board
   whose checkout you are in (the driver groups by board, one session per checkout).
   Still pass `--board <board>` to pipeline commands and `--repo <repo>`/`-R <repo>` to
   `gh` calls for the action's own `board`/`repo`; never act on another board.

The payload `funnel-drive.sh` hands you has already filtered out the merging tier
and every no-op-ish record; these rules are the second, independent guard. If
anything in the payload contradicts them, the rules win — skip and record it.

## Step 1 — Read the payload

Your argument (`$ARGUMENTS`) is a path to a JSON file. Read it. Shape:

```json
{ "rung": "5b",
  "hard_rules": [ … ],          // the in-band restatement of the rules above
  "actions": [ { "action": "...", "board": "...", "repo": "...", "issue": N, … }, … ] }
```

If the file is missing/unparseable or `actions` is empty, emit the Step 3 summary
with an empty `results` array and stop — nothing to drive.

## Step 2 — Execute each action by its kind

Process `actions` in order. For each, dispatch on `.action`. Every backend below is
an EXISTING command/surface — call it; do not re-implement its logic. (The one
exception is `drain-clarification`, whose apply is a bare label-clear + ack with
nothing to parse or synthesize — it is a direct deterministic mutation, called out
as such in its bullet below.)

- (`route-needs-input` was retired in #684 — `needs-clarification` producers
  (`/triage`, `/sweep` park-on-question, the 5c refusal escalation) now assign the
  operator + surface the question AT SOURCE, so the funnel-tick router only PARKS
  such items as `route-already-assigned` (a no-op the executor drops). The executor
  therefore never receives a `route-needs-input` action; there is nothing to handle.)

- **`route-foundational`** — a Foundational Ready item needs design + plan
  approval. **Prep then gate**: run `/assess --epic <issue> --board <board>` to
  decompose/draft the plan note (draft only — `/assess` never approves), then route
  the design + plan-approval to the decision queue via build.md's decision-issue
  backend (post the gate comment, apply the `decision` label, assign
  `.reassign_to`, park). You are preparing and routing for the operator — you are
  **not** approving the plan or building it.

- **`drain-answer`** — the operator answered a decision issue (`.chosen` carries
  the parsed reply). Apply it via the existing drain: **build.md Step 0a /
  `drain-mind` § Answered decisions** — translate the reply into its artifact, drop
  the `decision` label, and hand the baton back. Route to that backend; do not
  perform the sentinel/worktree work yourself.

- **`drain-parse-miss`** — a decision reply that couldn't be parsed. Re-assign the
  operator (`.reassign_to`) with a short comment that the reply couldn't be parsed
  as a decision block or `/command` and asking them to restate it
  (closed-enum-or-escalate — never guess a choice).

- **`drain-clarification`** — the operator answered a `needs-clarification` item (in
  a comment) and unassigned themselves, so the open-question gate should be cleared
  (foundation #657). This is a **direct, deterministic mutation** — there is nothing
  to parse and no artifact to synthesize (the free-text answer already lives on the
  issue and rides into the next drive). Two steps, and the **order + conditionality
  are load-bearing**:
  1. `gh issue edit <n> -R <repo> --remove-label needs-clarification`.
  2. **Only if step 1 succeeded**, post the idempotency ack `gh issue comment <n> -R
     <repo> --body "<!-- funnel:clarification-drained --> Clarified (funnel): operator
     answer consumed — released to drive."` The `<!-- funnel:clarification-drained -->`
     sentinel is what funnel-tick's `clarification_already_applied` guard reads to skip
     a re-listed item before the label drop propagates through the search index.

  **Do NOT post the ack if the label removal failed.** If you did, the marker would
  become the item's latest comment while the label is still present — and every future
  tick would then match `clarification_already_applied`, skip the item as
  already-drained (and the Ready-loop park too, via the `drained_clar` guard), so it
  would be **silently dropped forever with the label still on it** — recreating the
  exact #657 stall, unrecoverably. Gating the ack on the label-clear is what makes the
  fail-open guarantee real: on a failed `--remove-label`, record the item under
  `failed` and continue — the label persists and no marker was posted, so the next tick
  re-lists it and retries cleanly. Count a fully-applied item (label cleared **and**
  ack posted) under Step-3 `executed`. Never re-add the label or re-assign. Open no PR,
  merge nothing.

- **`drive-ready`** (only ever `kind:"spike"` here — see HARD RULE 3) — drive the
  spike to its verdict. A drive-ready spike is a **standalone Ready singleton, not an
  epic**, so do **NOT** run `/assess --epic` on it: `/assess` refuses a single issue
  with no sub-issues and no `## Contract` ("run `/triage`"), which is the 2026-06-29
  #449 dead-end (#635). Instead follow the action's `emit` and drive the **kind:spike
  singleton path** (the same path `/sweep` drives a singleton spike through, and
  `/build`'s kind:spike fork): **claim it**, do the read-only investigation, **write
  the verdict note** to the vault, **route any follow-up** issue, then **close the
  issue** with the note linked. **This opens no PR and merges nothing** — if anything
  tries to, stop and record a failure (it means the item was mis-stamped).

After each action, record `{action, issue, board, status: "executed"|"failed"|"refused", note}`.

**A blocked or failed vault write is never `executed` (foundation#978).** Several
actions above must land a durable vault artifact — a retro/verdict note, a
pending-decisions append, an `/assess` plan-note write. If that write fails to land
for **any** reason — a permission-denied MCP tool call (`mcp__obsidian…` /
`mcp__obsidian-builtin…`), a write error, an unavailable backend — the action's
artifact silently did not persist, so record it as **`failed`** (not `executed`) with
a one-line `note` naming the blocked write, and count it under `failed` in Step 3.
Reporting `executed` for an action whose artifact never landed is the #978
silent-artifact-loss failure: a headless run whose retro append was permission-denied
still returned `{"executed":2,"failed":0}`, so the drop was invisible. The ONLY
carve-out is a write that is genuinely best-effort (its loss does not defeat the
action's purpose): you may keep `executed` but MUST record the degraded write in
`note` — never omit it.

## Step 3 — Emit the summary

Print exactly one JSON object on stdout (this is your return value — `funnel-drive.sh`
folds it into the wake record; it is not a human-facing message):

```json
{ "driver": "funnel-drive", "rung": "5b",
  "executed": <count>, "failed": <count>, "refused": <count>,
  "results": [ { "action": "...", "issue": N, "board": "...",
                 "status": "executed|failed|refused", "note": "<one line>" }, … ] }
```

Keep `note` to one line per action. Do not narrate outside the JSON.
