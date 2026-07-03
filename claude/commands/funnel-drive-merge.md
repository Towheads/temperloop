---
description: Rung-5c EXECUTOR of the autonomous funnel driver — the MERGING tier. Headless (`claude -p`) layer that auto-executes the kind:code drives 5b deliberately leaves for the operator, by driving each through `/build --unattended` and letting /build's OWN timed/modal merge gate decide the merge. Spawned by funnel-drive.sh under a merge-allowing containment overlay, gated by FUNNEL_DRIVE_MERGE=1 and a per-tick cap. It merges ONLY via /build's gated path — never by hand.
argument-hint: "<payload-file>  (a JSON file: {rung, cap, hard_rules, actions[]} written by funnel-drive.sh)"
---

You are running the **funnel-drive-merge** command — the **rung-5c executor** of the
autonomous funnel driver, the **merging tier**. `funnel-tick.sh` decided a tick plan;
`funnel-drive.sh` filtered it to the **kind:code drives** (the ones 5b leaves for the
operator), capped it, and is invoking you headlessly to **drive each to a merged PR**
through the existing pipeline. You re-implement nothing: the merge safety lives in
`/build --unattended`, not here. See
[[Decisions/foundation - Funnel rung 5c supervised auto-merge tier]] and the parent
[[Decisions/foundation - Funnel rung 5b: headless safe-actions-only auto-drive]].

This is the autonomy step 5b deferred: 5b auto-executed only actions that can never
merge code; 5c drives `kind:code` items — but **only by handing them to `/build`,
whose timed/modal merge gate is the human-supervised checkpoint**.

## HARD RULES — read first, they override everything below

1. **Merge ONLY through `/build --unattended`.** Never run `gh pr merge`, `gh pr
   create`, `git push`, or any merge/enqueue yourself. `/build` owns the branch →
   PR → CI → merge lifecycle; you only *invoke* it. If you find yourself about to
   type a `gh pr` or `git push` command directly, STOP — that is `/build`'s job.
2. **Honor `/build`'s merge gate — never force a risky set.** `/build --unattended`
   auto-merges only a clean, disjoint, independent set after its timed window; a
   **structurally-risky** set hard-blocks for explicit approval (and, operator-absent,
   routes to the decision queue). Do **not** override, shorten, or bypass that gate.
   If `/build` parks an item for a decision, leave it parked — record it and move on.
3. **One item at a time, within the cap.** Process the `actions` you were handed in
   order (already sliced to `cap`). Drive one code item fully before the next.
4. **Execute each action independently.** A failure on one action is recorded and you
   continue to the next; one bad drive never aborts the batch.
5. **Stay on the action's own board/repo — your cwd is already that checkout.** The
   driver spawns you INSIDE the target board's local checkout (foundation #655), and
   `/build` derives its `repoRoot` and board from that cwd — so you do **not** need to
   (and must not) `cd` elsewhere or hunt for the repo. Every action you are handed
   belongs to the board whose checkout you are in (the driver groups by board and
   runs one session per checkout). Still pass `--board <board>` to pipeline commands
   and `-R <repo>`/`--repo <repo>` to `gh` calls for the action's own `board`/`repo`,
   and never touch another board. (If a `/build` invocation reports it cannot find the
   target repo from here, do **not** `cd` to fix it — record the action as failed and
   continue; a cwd/checkout mismatch is the driver's bug to fix, not yours to route
   around.)

`funnel-drive.sh` already pre-filtered to the merge tier and capped it; these rules are
the second, independent guard on top of the structural pre-filter and the
merge-allowing containment overlay (which scopes you to `/build`'s surface, not raw
merges of arbitrary PRs).

## Step 1 — Read the payload

Your argument (`$ARGUMENTS`) is a path to a JSON file. Read it. Shape:

```json
{ "rung": "5c",
  "cap": N,                       // the per-tick merge cap (actions already sliced to it)
  "hard_rules": [ … ],            // the in-band restatement of the rules above
  "actions": [ { "action": "drive-ready", "kind": "code", "mode": "fresh|resume",
                 "board": "...", "repo": "...", "issue": N, "emit": "...", … }, … ] }
```

Each action carries a **`mode`** (foundation #624):

- **`fresh`** (or absent) — a first-time drive: claim → `/assess` → `/build` → open a PR.
- **`resume`** — a prior tick already opened a PR for this issue, but the one-shot
  headless session ended before CI greened and `/build`'s merge gate fired. **Re-attach
  to that OPEN PR and run only the merge phase** — do NOT re-assess or open a second PR
  (that is the duplicate-PR bug #624 exists to prevent). See Step 2's resume path.

If the file is missing/unparseable or `actions` is empty, emit the Step 3 summary with
an empty `results` array and stop — nothing to drive.

## Step 2 — Drive each code item to a merged PR

Process `actions` in order. Each is a `drive-ready` with `kind == "code"`. Branch on its
**`mode`**.

### `mode: "fresh"` (or absent) — a first-time drive

- **Claim** the item on its board (the board adapter's `claim … --board <board>`), then
  run the pipeline its `emit` names — the same path the operator runs by hand. **The
  emit is authoritative — follow it verbatim; the `route` field tells you which shape:**
  - **`route: "epic"`** (has sub-issues, or a `## Contract` for `/assess` to decompose) —
    `/triage` → `/assess --epic <issue> --board <board>` → `/build <plan> --unattended`.
  - **`route: "singleton-code"`** (a bare Ready singleton — 0 sub-issues AND no
    `## Contract`) — do **NOT** run `/assess --epic`: it refuses a single issue with no
    sub-issues/Contract ("run `/triage`"), the guaranteed-refusal dead-end #717 fixes
    (the kind:code sibling of #635). Instead drive it via **`/sweep`'s per-issue build
    path SCOPED to this one issue** (`build-level.mjs`: worktree → isolated worker → PR →
    CI → `/build`'s merge gate — the same per-issue mechanics `/sweep` Phase 2 runs).
    **Never** run whole-pool `/sweep` (it would over-reach the entire Ready pool and blow
    the per-tick cap) — drive only this issue. The merge still happens **only** through
    that gated path, never by hand.
- `/build --unattended` carries the run from worktree → agent → push → PR → CI-watch →
  **its merge gate**. It runs operator-absent (the cron sets `FUNNEL_OPERATOR_ABSENT=1`),
  so a `blocking-now` decision is posted to the decision queue and the item parks —
  it does **not** hang. Let `/build` reach its own terminal state; do not intervene in
  its gate.
- **Let `/build` block synchronously through CI-watch and the merge gate — do NOT
  dispatch a background poll and yield (#626).** This headless run has no
  re-invoke-on-background-completion loop, so a backgrounded CI watch or a
  `ScheduleWakeup` merge window would simply end the session before the merge fires —
  the bug that left every funnel PR green-but-unmerged. `/build`'s headless branch
  (selected by the `FUNNEL_OPERATOR_ABSENT=1` this driver runs under) already handles
  this correctly: it runs `ci-poll.sh` in the **foreground** (bounded, blocking) and,
  on a clean green set, **merges immediately with no objection window**, then polls for
  `MERGED` in the foreground. Let it run to a merged PR **in this one session** — the
  expected outcome of a fresh drive is now `merged in #<pr>`, not a hand-off.
- **`handed-off` is the bounded-timeout TAIL, not the default.** Report `handed-off`
  with the PR number **only** when `/build`'s foreground CI or MERGED poll hits its
  `BUILD_HEADLESS_POLL_TIMEOUT` bound (CI or the merge queue genuinely slower than the
  session can foreground-wait) and parks the item `[m]` with an open PR. A later tick
  re-selects the issue as a `resume` action (the executor labels it off a ground-truth
  open-PR probe) and finishes the merge when CI/queue is long-clear (#624). Do **not**
  manufacture a hand-off by backgrounding a wait you could have blocked on.

### `mode: "resume"` — finish an in-flight PR

- The prior tick's drive already opened the PR; CI is now (a tick later) long-green.
  **Find the open PR that closes this issue** (`gh pr list --search "<issue> in:body"`
  / the issue's linked PRs) and re-enter `/build`'s resume path on its existing plan
  note (`/build <plan> --unattended` resumes via the plan note's `[~]` + `pr:` sentinels
  — it re-attaches to the open PR, re-checks CI, and runs the merge gate). Do **not**
  run `/assess`, do **not** open a new PR, do **not** claim a fresh worktree.
- **If the plan note's `[~]` item is missing its `pr:` sentinel** — the prior session
  died in the window between opening the PR and writing `pr:` back — the resume's
  re-attach has nothing to bind to and `/build` could re-spawn into a duplicate PR.
  Guard against it: take the open PR number you just located (ground truth) and stamp
  it onto the plan item's `pr:` sentinel **before** invoking `/build`, so the re-attach
  binds to the real in-flight PR rather than re-deriving one.
- If you find **no open PR** for the issue (the marker was stale — the PR was closed or
  superseded), fall back to a **fresh** drive instead (the marker is self-healing).
- Let `/build`'s gate decide the merge exactly as in the fresh path.

### Record the outcome (both modes)

- Record the outcome: `merged in #<pr>` (the PR merged in-session via `/build`'s gate —
  the expected result of a clean drive now), `handed-off` (a PR is open but `/build`'s
  foreground CI/MERGED poll hit its `BUILD_HEADLESS_POLL_TIMEOUT` bound before the merge
  landed — the slow-CI/slow-queue tail; record the PR number so the next tick resumes it),
  `parked` (a decision/risky gate left it for the operator — note where), `failed`
  (with a one-line reason), or
  `refused` (you judged the item not autonomously driveable to a merged PR — e.g. a
  manual-ops task with no committable code artifact).

**Do not edit the issue yourself on `refused` or `failed`** (no `gh issue edit`, no
assign, no label, no comment). Just report the status and a one-line `note` with the
reason. `funnel-drive.sh` deterministically ROUTES every refused/failed item to the
operator — assigns the operator (`$FUNNEL_OPERATOR`), adds `funnel-escalated` (its own gate since #697 — not
`needs-clarification`, which is for open *questions*; a 5c escalation is a stuck code
item awaiting a manual merge/close, and the label removes it from the next tick's
drive-ready pool), and posts your `note` as the comment. If you also
commented, the operator would get a duplicate; leave the GitHub side-effects to the
executor. (This does not apply to the merge *itself* — that still happens only inside
`/build`'s gate, never by your hand.)

After each action, record `{action, issue, board, status: "merged"|"handed-off"|"parked"|"failed"|"refused", pr, note}`.
On `handed-off`, ALWAYS set `pr` to the open PR's number — that is the token the next
tick's resume re-attaches to. (`funnel-drive.sh` independently confirms the open PR via
a ground-truth probe and applies the hand-off label, so the resume fires even if this
session died before emitting this summary — but report it when you can.)

## Step 3 — Emit the summary

Print exactly one JSON object on stdout (this is your return value — `funnel-drive.sh`
folds it into the wake record; it is not a human-facing message):

```json
{ "driver": "funnel-drive-merge", "rung": "5c",
  "merged": <count>, "handed_off": <count>, "parked": <count>,
  "failed": <count>, "refused": <count>,
  "results": [ { "action": "drive-ready", "issue": N, "board": "...",
                 "status": "merged|handed-off|parked|failed|refused", "pr": <n|null>,
                 "note": "<one line>" }, … ] }
```

`handed_off` counts the drives that opened a PR but did not merge this session (resumed
next tick). Keep `note` to one line per action. Do not narrate outside the JSON.
