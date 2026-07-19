---
description: Rung-5b EXECUTOR of the autonomous funnel driver. Headless (`claude -p`) layer that executes the SAFE, no-merge tier of a funnel tick plan — route-foundational, drain-answer, drain-parse-miss, drain-clarification, retro-judge, and kind:spike drives — by invoking the real pipeline commands. STRUCTURALLY cannot merge: it is handed only the pre-filtered safe actions and is forbidden to open PRs, merge, or drive a kind:code item. Spawned by funnel-drive.sh; the merging tier waits for rung 5c.
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

## Step 1.5 — Source the board adapter (before any board read/write)

Several actions below **read or write the board**: a `drive-ready` spike *claims* its
issue, does a contention/status read, moves it to *Done* on verdict-capture, and *closes*
it. Those all go through the shared board adapter's `board_*` functions
(`board_resolve_item` / `board_item_id` / `board_set_status`, the `BOARD_OPT_*` constants)
— **which do not exist until the adapter (`lib/board.sh`) is sourced.** You are a headless
`claude -p` session that never ran `/build` Step 0, so nothing has sourced it for you: an
inline `board_resolve_item …` / `board_item_status` / `$BOARD_ITEM_STATUS` in an un-sourced
bash block is `command not found` / an unbound variable, and every board read errors (the
`jq 'Cannot index'/'iterate over null'` cascade downstream). That was foundation #1084 —
recurring every headless run.

So **prefix EVERY board bash block** with the locate-and-source one-liner below. It is
load-bearing per-block, not once-per-session: a fresh `claude -p` bash call does **not**
inherit a `source` from an earlier call. It mirrors `/build` Step 0's `BOARD_LIB`
resolution, condensed because HARD RULE 5 already guarantees your cwd is the action's board
checkout:

```bash
# Prefix EVERY board bash block with this — a fresh bash call inherits no earlier `source`.
BOARD_LIB="$(ls scripts/lib/board.sh workflows/scripts/board/lib/board.sh 2>/dev/null | head -1)"
[ -n "$BOARD_LIB" ] && source "$BOARD_LIB"   # now board_resolve_item / board_set_status / BOARD_OPT_* exist
```

Use each action's own `.board` / `.repo` from the payload (HARD RULE 5) — no repo→board
reverse-lookup is needed. **Legible degradation:** if `BOARD_LIB` resolves **empty** (this
checkout has no adapter), the board is unavailable — **skip** the claim / Done / close board
moves and record the degradation in the action's `note`. Never fabricate a `board_*` call
against a missing adapter (that reproduces #1084's command-not-found).

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
  approval. **First, the already-prepped guard (F#1053):** before running `/assess`,
  check whether the epic already has a plan note whose frontmatter `status` is
  anything other than absent or `draft` (i.e. `approved` or `executing`). If it does,
  the epic was **already decomposed and approved** and is merely parked on its own
  gate — re-running `/assess` would collide on the plan-schema filename ask
  (operator-only, unresolvable headless) and mint a duplicate gate comment, which is
  the #951 every-tick spin. **Do NOT run `/assess`.** Record this action as
  `status: "refused"` with a one-line `note` naming the existing plan and its status
  (e.g. `already-prepped: Plans/… is executing — parked for operator resume`) and move
  on; `funnel-drive.sh` routes a refused route-foundational to the operator's decision
  queue so it stops re-firing. Otherwise (no plan, or a `draft`), **prep then gate**:
  run `/assess --epic <issue> --board <board> --no-poll` to
  decompose/draft the plan note (draft only — `/assess` never approves), then route
  the design + plan-approval to the decision queue via build.md's decision-issue
  backend (post the gate comment, apply the `decision` label, assign
  `.reassign_to`, park). **`--no-poll` is required:** this action runs operator-absent
  (the safe tier spawns with `FUNNEL_OPERATOR_ABSENT=1`, #329), and without it
  `/assess`'s own Step 6 poll would *also* post a decision issue on the epic —
  funnel-drive owns the *single* decision-queue routing, so `/assess` must stop after
  its Step 5 draft. You are preparing and routing for the operator — you are
  **not** approving the plan or building it.

- **`drain-answer`** — the operator answered a decision issue (`.chosen` carries
  the parsed reply). Apply it via the existing drain: **build.md Step 0a /
  `tidy` § Answered decisions** — translate the reply into its artifact, drop
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

- **`retro-judge`** — the KERNEL trigger half of the mint-then-judge design (epic
  #528, temperloop#535). `funnel-tick.sh` emitted this because at least one
  `retro-pending` tracker (build.md 4d-retro's mint, #533) is due — urgent, or past
  the `RETRO_MIN_INTERVAL` debounce. `/retro` is an **OVERLAY** command (not part
  of this kernel checkout), so this is a **direct nested spawn**, not a
  followed-in-session pipeline call like `/assess`/`/build` above: run, via Bash,
  synchronously (never backgrounded) —
  ```bash
  claude -p "/retro --pending --board <board>" --model "$RETRO_JUDGE_MODEL" --output-format json
  ```
  using the action's own `.board` (HARD RULE 5). The judge owns everything
  downstream from there — relabeling each processed tracker, closing it, and its
  own per-session batch cap — you only trigger it and report the outcome. A
  non-zero exit, or output carrying no parseable summary, is `failed` (with a
  one-line `note` naming the failure); a clean exit **whose summary reports no
  blocked or failed per-tracker write** is `executed`. **The foundation#978 rule
  below binds this action too:** if the judge's summary names a tracker whose
  relabel/close/verdict write was blocked or failed (a permission-denied MCP call,
  an unavailable backend), record this action `failed` — or, only if the loss is
  genuinely best-effort, keep `executed` but name the degraded write in `note` —
  **never** a silent `executed` over a write-failure the summary does surface.
  Absent such a signal you rely on `/retro`'s own contract to exit non-zero on a
  hard write failure; you do not re-verify the judge's per-tracker writes yourself.
  This action never opens a PR and never merges anything — that disclaimer is
  scoped to **merge/PR authority**: if the judge's output claims a PR or merge,
  that's the judge's concern, not something you act on. It does **not** license
  ignoring a write-failure the summary reports.

- **`drive-ready`** (only ever `kind:"spike"` here — see HARD RULE 3) — drive the
  spike to its verdict. A drive-ready spike is a **standalone Ready singleton, not an
  epic**, so do **NOT** run `/assess --epic` on it: `/assess` refuses a single issue
  with no sub-issues and no `## Contract` ("run `/triage`"), which is the 2026-06-29
  #449 dead-end (#635). Instead follow the action's `emit` and drive the **kind:spike
  singleton path** (the same path `/sweep` drives a singleton spike through, and
  `/build`'s kind:spike fork): **claim it**, do the read-only investigation, **write
  the verdict note** to the vault, **route any follow-up** issue, then **close the
  issue** with the note linked. The claim, the Done move, and the close are board
  reads/writes — **source the adapter first in each of those bash blocks (Step 1.5)**,
  or their `board_*` calls are command-not-found (#1084). **This opens no PR and merges
  nothing** — if anything tries to, stop and record a failure (it means the item was
  mis-stamped).

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
