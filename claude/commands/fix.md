---
description: Drive a single, named target — an issue number OR a free-text description — from wherever it is now to **merged + closed**, by composing the existing build machinery (state probe → claim → isolated worker → PR → CI → **modal** merge). The targeted single-item peer to `/build` (epic'd work) and `/sweep` (a board's whole Ready-singleton pool): `/fix` is "just make *this one* go."
argument-hint: "<issue# | description> [--repo <owner/repo>] [--dry-run]"
---

You are running the **fix** command. Goal: take **one** named target and drive it to a **terminal disposition** — merged + issue closed + worktree reclaimed for real code, or a verdict-close for a spike — reusing the machinery that `/build` and `/sweep` already own. `/fix` is a **thin driver that COMPOSES existing components**; it does **not** reimplement claim / worktree / PR / CI / merge mechanics.

```
/build   ── an epic's plan note (a whole dependency level at once)
/sweep   ── a board's Ready singletons (the whole ungrouped pool, sequentially)
/fix     ── ONE named target (an issue#, or a description you name right now)   ◄── you are here
```

The seam between the three is **scope of intake**: `/build` drains the epic'd work, `/sweep` drains the singleton *pool*, `/fix` drains exactly the **one thing you point at** — the "I know precisely what I want fixed, do just that" front door. It reuses `/sweep`'s per-issue mechanic wholesale (a 1-item `build-level.mjs` level) and adds only two things `/sweep` doesn't need: **(a)** a from-a-description entry (mint the issue first, safely), and **(b)** an **adopt** path for a target that already has an open PR (revalidate + merge it, never open a duplicate).

## Inputs

- `<target>` (required, positional) — **either** an issue number (`123`, `#123`, or a full `owner/repo#123`) **or** a free-text description of the fix ("the board adapter mis-resolves board 7 when boards.conf is absent"). `/fix` decides which by shape: a bare/`#`-prefixed integer (optionally repo-qualified) is an **issue number**; anything else is a **description** (Step 1).
- `--repo <owner/repo>` (optional) — the target repo. For an issue number it defaults to the **local checkout's** repo (`gh repo view --json nameWithOwner -q .nameWithOwner`); a full `owner/repo#123` target overrides it. For a **description** it likewise defaults to the local checkout — but because the description path *creates* an issue, the resolved `owner/repo` is **echoed and explicitly confirmed** before any write (Step 1). An explicit `--repo` always wins over inference.
- `--dry-run` (optional) — rehearsal: run Step 0 + the Step 2 `resolve` probe (for an issue target) or the Step 1 duplicate probe (for a description), then **print** the route verdict and the plan of record — **zero mutation** (no issue created, no claim, no worker, no PR, no merge, no label/comment writes). End with "Re-run without `--dry-run` to execute."

## Operating principles

- **Compose the machinery — do NOT re-orchestrate.** Every mechanic `/fix` needs already exists and is battle-tested; `/fix` is a conversational driver *over* them, not a reimplementation. It reuses, by name: <!-- cite: FX.1 incident:K#13 -->
  - **`workflows/scripts/build/issue-state.sh resolve <repo> <issue>`** — the ground-truth **state probe**. `/fix` runs this **FIRST**, before any mutation, and routes on its single JSON `route` verdict (`fresh|adopt|question-first|claimed-elsewhere|already-done|ambiguous`). See Step 2 for the route→action map; read that script's header + `cmd_resolve` for the exact verdict shape.
  - **`workflows/scripts/build/issue-state.sh reattach <repo> <pr>`** — the **adoption-safety** revalidation for an already-open PR (state / mergeability / a `--sha`-pinned CI re-poll / a `BEHIND`-base rebase signal). It returns a `{ready|not-ready, reason}` verdict and **NEVER merges** (the caller owns the merge). `/fix` runs this on the `adopt` route so it **merges the existing PR instead of opening a duplicate**. See `cmd_reattach` + `reattach_usage` for the verdict shape.
  - **`claude/workflows/build-level.mjs`, invoked as a 1-item level via the Workflow tool** — the merge *drive* for **fresh** work (claim → worktree → isolated worker → acceptance gate → closing-keyword scan → push-by-SHA → PR open → CI poll → `{parked, escalations}`). `/fix` invokes it **exactly as `/sweep` Phase 2 does** — one item, `scriptPath` not `name:` (#437). **No hand-rolled fix loop.**
  - **`workflows/scripts/build/gate.sh`** — the **backend-aware merge** machinery (`gate.sh backend` selects NATIVE vs MANAGED; `gate.sh queue` + `gate.sh poll` drive + confirm a native-queue merge; `gate.sh managed-merge` runs the per-PR managed mechanics with its own confirmed-`MERGED` poll). `/fix`'s merge (Step 5) composes these — it does **not** hardcode a merge incantation. It **probes the backend at run time and never assumes a fixed one**: a hardcoded `gh pr merge --auto` (the NATIVE-only arm) breaks the moment it runs on a MANAGED repo, and a hardcoded managed path breaks on a NATIVE one. (temperloop itself probes `NATIVE` today — verified via `gate.sh backend` — but a repo's backend can change; `build.md` Step 4b, `docs/managed-merge-queue.md`, temperloop#13. The probe, not any written-in assumption, is the per-run source of truth.)
  - **`workflows/scripts/build/worktree.sh`** (worktree lifecycle), the **board adapter** (`workflows/scripts/board/lib/board.sh` + `claim.sh`/`release.sh`), **`pr.sh`**, **`ci-poll.sh`** — reused verbatim, never re-encoded.
- **The state probe runs before any mutation.** `resolve` is read-only and cheap; it is the first thing `/fix` does for an issue target, and its verdict determines the whole run. `/fix` never claims, builds, or opens/merges a PR before `resolve` has classified the target. (Fetch ground truth before building.) <!-- cite: FX.2 guard:workflows/scripts/build/issue-state.sh -->
- **Claim-first — against a drivable target.** When the route is `fresh`, the board claim is the **first mutating action** (`build-level.mjs` 3a claims before its worker investigates — the board is a cross-session lock). `/fix` never investigates code or opens a worktree before the claim on a target it is about to drive. (**One inherited exception:** a `spike`-labeled target — `build-level.mjs` returns a verdict-only park *before* its 3a claim block runs, so a spike is not claimed-first. This is a pre-existing `build-level.mjs` / `build.md`-line-312 divergence inherited by `/build` and `/sweep` too, tracked separately — not `/fix`-specific.)
- **Never open a duplicate PR; never steal a claim.** An `adopt` route **revalidates and merges the existing PR** (never opens a second). A `claimed-elsewhere` route **reports the owning session and stops** — a live claim by another session is honored, never stolen. <!-- cite: FX.3 guard:workflows/scripts/build/issue-state.sh -->
- **Every run ends at a terminal disposition — never at "PR opened."** The terminal set is: **merged** (code, PR confirmed `MERGED` + issue closed), **resolved (verdict)** (a spike, verdict-closed with a comment), **parked** (an open question / not-ready adoption / a held merge, recorded for a human), or **reported-no-op** (already-done / claimed-elsewhere / epic-refused). A `/fix` run that stops at "opened a PR" is a bug — the merge gate (Step 5) is part of the same run. <!-- cite: FX.4 class:abandoned-ownerless-prs -->
- **The merge gate is MODAL** (temperloop is hand-driven). `/fix` **never** timed-auto-merges. Every merge is surfaced for **explicit operator approval** through the `decision_sink_ask(question, options, severity)` seam (severity `ask-now`), exactly as `/build` Step 4's risky-set path does — and there is **exactly ONE** merge confirmation per run. A **draft** PR, or a PR with a **foreign author showing recent activity**, is never driven past the gate without the approval prompt **naming that state explicitly** (Step 5). <!-- cite: FX.5 class:silent-foreign-work-merge -->
- **A spike target is verdict-closed, never `gh pr merge`d.** A target that produced no PR (`pr: null` — a `spike`-labeled item that `build-level.mjs` parked verdict-only) is **closed directly** with a comment. Never run `gh pr merge null` (a silent no-op that would falsely report "fixed").
- **Clear stale routing labels at any terminal disposition of an adopted item.** A target that had been through the autonomous pipeline may carry `funnel-escalated` / `funnel-merge-pending`; these are stuck-state routing markers. On **any** terminal disposition of an adopted (or pipeline-touched) item, **remove them** so the item does not re-surface to `/next` / `/sweep` / the pipeline as still-stuck (a GitHub label survives the PR closing/merging — only an explicit `--remove-label` clears it). <!-- cite: FX.11 class:immortal-routing-labels -->
- **Refuse epic-sized targets.** `/fix` drives **one seam-scoped fix**. If the named target is **epic-sized** — it is itself an epic (has native sub-issues, or carries the `epic` label), or the described work is `EPIC_MIN_SUBUNITS`+ parallelizable sub-units / more than one dependency level — `/fix` **refuses and redirects**: a *discovered* epic to `/assess --epic <N>` (its normal mode reads existing sub-issues; its **lone-issue decomposition arm** handles a lone Contract-less epic-sized issue, temperloop#1524 — never to `/triage`, which has no single-issue intake), an *invented* one to `/workshop` (§ Task workflow "Decompose epic-sized work up front"; the design-first default). Don't manufacture a one-item drive for epic-sized work. <!-- cite: FX.7 guard:workflows/scripts/build/build.config.sh -->
- **Deploy caution — install before you drive.** This spec is **live only once installed** to `~/.claude/commands/fix.md` (`make install`). A change to this file is inert in the running session until re-installed — fix-and-redeploy the driver *before* driving work through it ([[Patterns/temperloop - Fix and redeploy the driver before driving work through it]]). If you just edited this spec, redeploy before invoking `/fix`. <!-- cite: FX.10 class:stale-spec-execution -->

## Step 0 — Validate + resolve the repo + deploy caution

Run in parallel:

1. `gh auth status` — must succeed (the board claim, the issue writes, and the PR all need an authenticated `gh`). The default **`repo`** scope is sufficient; **never check for or require a `project` scope** — every board read/write is a plain-REST label/issue/sub-issue call (`workflows/scripts/board/ISSUES-ONLY-BACKEND.md`), so a token carrying only `repo` drives the whole command. Unauthenticated → stop with the `gh auth login` hint.
2. **Board + machinery probe.** Set `BOARD_LIB` = the first of `scripts/lib/board.sh` or `workflows/scripts/board/lib/board.sh` that exists; `source "$BOARD_LIB"`. Resolve the target repo: `--repo` if given, else `repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"` (a full `owner/repo#N` target overrides). Infer the board from that repo the way `/sweep` Step 0.2 does — iterate `board_registered_boards`, match on `board_repo`; **board 7 is temperloop's own tracker** (`fnd:status:*` labels — `workflows/scripts/board/ISSUES-ONLY-BACKEND.md`). Print `target repo <repo> (board <N>)` before any read. An unmapped repo with a non-existing target issue → stop (nothing to drive and no board to file against); an unmapped repo is otherwise fine for a description target only if you can still create the issue there.
3. **Resolve the workflow-invocation context** (passed to the per-item `build-level.mjs` call, identical to `/sweep` Step 0.3): `repoRoot="$(git rev-parse --show-toplevel)"`, `ownerRepo="$repo"`, `claimCmd` = absolute path to `claim.sh`, and `workflowPath="$HOME/.claude/workflows/build-level.mjs"` (invoked by **`scriptPath`**, never `name:` — #437). Also resolve **`machineryBinDir`** — the already-resolved absolute path to the build-machinery script directory (`worktree.sh`/`pr.sh`/`ci-poll.sh`) — with the **same plain `cd`+`pwd` form `/build` uses** (`claude/commands/build.md` Step 3's `machineryBinDir` bullet is the single statement site; this is a pointer, not a second spec): `machineryBinDir="$(cd workflows/scripts/build 2>/dev/null && pwd)"` — a plain `cd`+`pwd` that follows a `workflows/` → foundation symlink to the real path. Passing it lets `build-level.mjs` emit **plain absolute machinery paths** instead of resolving them inline with a nested `$(dirname "$(readlink -f …)")` command-substitution, which the auto-mode safety classifier read as an obfuscated-command bypass and **denied** on `--unattended`/pipeline runs (temperloop#72), blocking every push/worktree machinery step. Absent → the `.mjs` falls back to its in-bash `machineryBin` resolver, so this is a classifier de-trip, **not** a hard dependency.
4. **Source the batch-pipeline config** — `source workflows/scripts/build/build.config.sh` (bare repo-relative) — pulls `EPIC_MIN_SUBUNITS` (the epic-size threshold used by the epic-refusal gate), the merge-gate settings, **`FIX_WORKER_MODEL`** (the Step 4 single-issue WORKER model tier; empty = inherit the session model), **`BUILD_MACHINERY_SOLO_MODEL`** / **`BUILD_MACHINERY_BATCH_MODEL`** (the `build-level.mjs` machinery-executor model tiers this command's own Step 4a Workflow invocation also passes through — same paired setting `/build` uses, empty = unchanged), **`BUILD_GATE_SLICE_SECS`** (the parent-side acceptance gate's per-SLICE budget, passed through the same Step 4a hand-off as `gateSliceSecs`; belt-and-suspenders form `${BUILD_GATE_SLICE_SECS:-300}`), and **`BUILD_MACHINERY_STEP_CEILING_SECS`** / **`BUILD_MACHINERY_STEP_SLOW_SECS`** (the `build-level.mjs` machinery-step wall-clock liveness ceiling and its progress-notice threshold — temperloop#1071 — passed on the same Step 4a hand-off as `machineryStepCeilingSecs` / `machineryStepSlowSecs`; belt-and-suspenders forms `${BUILD_MACHINERY_STEP_CEILING_SECS:-900}` / `${BUILD_MACHINERY_STEP_SLOW_SECS:-300}`) into scope. Absent in a non-vendoring checkout → proceed with the belt-and-suspenders `${SETTING:-default}` forms.
5. **Resolve the effective engineering principle set (once per run) — the `principlesSummaries` / `principlesDefaultRepo` hand-off.** Runs **after** item 3 (it needs `ownerRepo`), and is **orchestrator work, not `.mjs` work**: the Workflow runtime has no filesystem or vault access to merge `claude/engineering-principles.md` with a project's own `## Principles` extension itself (`build-level.mjs`'s DESIGN NOTE 1 — the same wall `machinerySoloModel`/`gateSliceSecs` hit at item 4), so this live session is the only place the merge can happen. **Run `/build` § Step 1.8's procedure verbatim — `claude/commands/build.md` is the single implementation and this is a pointer to it, so the two can never drift.** Only its *pair enumeration* simplifies here: `/fix` drives exactly **one** target, so there is exactly **one** `(repo, project)` pair — `repo = ownerRepo`, `project = basename(ownerRepo)` — and no cross-repo plan item to add a second. Render that pair per Step 1.8 items 2–4, then set `principlesSummaries = { "<ownerRepo>": "<that pair's rendered summary>" }` and `principlesDefaultRepo = ownerRepo`, and pass **both** in the Step 4a Workflow args. Without this hand-off every `/fix` worker permanently runs the `.mjs`'s static kernel-only `DEGRADED` fallback. **Degrade, never halt** (principles are advisory — `claude/engineering-principles.md` § Advisory posture): if the kernel file or the vault read is unavailable, resolve what you can and, if nothing resolves, omit the two keys and let the `.mjs`'s own `DEGRADED` notice stand — never stall a fix over it. *(Resolve it only on a route that will actually **drive** — a `--dry-run`, or a terminal route like `already-done`/`claimed-elsewhere`, spawns no worker and needs no principle set.)*

**Deploy caution:** if this `/fix` invocation is the first since this spec was edited, confirm it was re-installed (`make install`) — an un-redeployed edit runs the *old* spec. If any Step-0 check fails, surface it in one line and stop.

## Step 1 — Resolve the target (issue number vs. description)

**Decide the target's shape:**

- **Issue number** (`123`, `#123`, `owner/repo#123`) → skip to **Step 2** with that `<repo> <issue>`.
- **Description** (anything else) → **mint the issue first, safely**, then fall through to Step 2 with the new issue number. Four sub-steps, in order: <!-- cite: FX.9 incident:K#74 -->
  1. **Echo the resolved `owner/repo` and get explicit confirmation BEFORE any write.** Print `Target repo: <owner/repo>. Create a new issue here for: "<description>"?` and route it through `decision_sink_ask(<the repo + the described work>, [create here, pick a different repo, cancel], ask-now)` — **no issue is created until the operator confirms the repo.** (Silence is not consent; a wrong-repo issue is exactly what this gate prevents.)
  2. **Duplicate-issue probe — ASK on ambiguity, never silently create.** Search the target repo for an existing open issue that plausibly covers this description: `gh issue list -R "$repo" --state open --search "<key terms>" --json number,title,url --limit 10`. **If a plausible match exists, do NOT create** — surface the candidate(s) via `decision_sink_ask(<the candidate issue(s) + the description>, [adopt candidate #N (drive the existing one), create a new issue anyway, cancel], ask-now)`. "Adopt candidate" reroutes the run to that issue number (back to Step 2); "create anyway" continues to sub-step 3. Only a genuinely empty search proceeds to create without asking. **A non-zero `gh issue list` exit (auth / rate-limit / network) is NOT a genuinely-empty result** — on any error, degrade to **ask before creating** (surface the failure through the same `decision_sink_ask` and let the operator decide), never proceed as if empty; proceeding on a swallowed error creates a duplicate issue for an already-tracked description (a named-failure-path gap — `Patterns/foundation - Design for failure modes`).
  3. **Leak-scan the composed issue body before it is written outbound.** Compose the issue title + body from the description, then scan it against this checkout's personal-token denylist — the same deny-pattern data `workflows/scripts/kernel/check-personal-token-denylist.sh` applies to the kernel file set (`workflows/scripts/kernel/personal-token-denylist.tsv`), applied here to the composed body (the outbound-content scan `/workshop` Step 5 runs on a composed epic body). A hit **blocks** creation until the offending content is edited out — the issue is outbound content in a repo that may be public. If the denylist file isn't present in this checkout, emit the `claude/message-schema.md` **Degradation notice** (what was skipped, why, and: the body was not scanned — review it yourself before it lands) — never a silent skip.
  4. **Create the issue** — `gh issue create -R "$repo" --title "<title>" --body "<scanned body>"` — capture the new number, then continue to Step 2 against it. (On board 7 / an issues-only board, `capture.sh` is the adapter path that also stamps `fnd:status:backlog`; a bare `gh issue create` is acceptable for a target you are about to claim In Progress moments later in Step 4.)

**`--dry-run`:** for a description, run sub-steps 1–2's *detection* read-only (print the resolved repo and any duplicate candidates) but make **no** `AskUserQuestion`, **no** search-write, and **no** `gh issue create`; then stop (there is no issue number to probe in Step 2 yet). State "Re-run without `--dry-run` to create the issue and drive it."

## Step 2 — State probe (`resolve`) FIRST, then route

Run the ground-truth probe **before any mutation**:

```bash
issue-state.sh resolve "$repo" "$issue"   # → one JSON route-verdict object
```

Read `.route`, `.reason`, `.open_prs`, `.claim`, `.labels`, `.worktree`. **Branch on `.route`** (this is the whole control flow; each arm is detailed in the step named):

| `route` | meaning | `/fix` action |
|---|---|---|
| `fresh` | open, unclaimed, no linked PR | **Step 4a — drive** (claim-first → `build-level.mjs` 1-item level → Step 5 merge gate) |
| `adopt` | exactly one open linked PR, **or** the `funnel-merge-pending` label (which can fire with **no** open PR — `issue-state.sh` route precedence) | **Step 4b — adopt** (`reattach` revalidate → Step 5 merge gate; never open a duplicate PR — but a label-only `adopt` with empty `open_prs` degrades to the `fresh` drive, see 4b) |
| `question-first` | carries `needs-clarification` | **Step 4c — question** (surface the open question, do not drive; park + stop) |
| `claimed-elsewhere` | In Progress under a different Host/Session | **Step 4d — honor the claim** (report the owner, stop; never steal) |
| `already-done` | issue is closed | **Step 4e — no-op** (report it's already closed; clear any stale routing label; stop) |
| `ambiguous` | >1 open PR links to the issue | **Step 4f — disambiguate** (`decision_sink_ask` which PR to adopt, or stop; never guess) |

**Epic-size refusal gate (before a *drive* — the `fresh` / `adopt` / `ambiguous` routes ONLY).** For a route that would drive the target, check whether it is **epic-sized**: route through the adapter (temperloop#1140) — in this same Bash call, `source "$BOARD_LIB"` then guarded-source `lib/cache.sh` alongside it (`if [ -f "$(dirname "$BOARD_LIB")/cache.sh" ]; then . "$(dirname "$BOARD_LIB")/cache.sh"; fi` — the `worklist.sh:50-53` guarded form, never `[ -f … ] && .` under `set -e`; shell state does not persist between Bash calls, so Step 0's sourcing can't be assumed here), then `board_sub_issues "$BOARD" <issue> | wc -l | tr -d '[:space:]'` > 0, or the issue carries the `epic` label. **This read MUST stay LIVE** — `board_sub_issues` carries no cached arm today (removed in temperloop#1163: a cached path here would silently return 0 children for a genuinely epic-sized target and let this gate wave it through as driveable, the same false-drained failure shape temperloop#1030 produced at the epic-close site) — so a future cached arm must not be pointed at this gate without re-litigating that. If so, **refuse and redirect** (Step 3) — do not drive it. **Skip this probe for the terminal routes** (`question-first` / `claimed-elsewhere` / `already-done`) — they report their own disposition and never drive, so probing sub-issues to "refuse" an already-closed or claimed-elsewhere issue would be nonsensical (and wastes a call).

**`--dry-run`:** STOP here. Print the `resolve` verdict, the chosen route, and the action `/fix` *would* take, then "Re-run without `--dry-run` to execute." Zero mutation.

## Step 3 — Refuse epic-sized targets (redirect, don't drive)

If the epic-size gate fired: `/fix` does not drive epic-sized work. Report it in one line and redirect:

- **A discovered epic** (an existing epic issue, or work that is clearly `EPIC_MIN_SUBUNITS`+ sub-units / multi-level) → `Refusing: #<N> is epic-sized. Route it through /assess --epic <N> → /build (decompose to the seam first).` This names the real door for **both** discovered shapes: an epic with existing sub-issues (`/assess`'s normal mode) and a **lone** epic-sized issue with no sub-issues and no `## Contract` (`/assess`'s lone-issue decomposition arm, temperloop#1524). Never redirect a named issue to `/triage` — it has no single-issue intake, and a lone finding gives it nothing to group, so that redirect re-enters a closed cycle (temperloop#1510).
- **Invented epic-sized work** (from a description) → `Refusing: this is epic-sized invented work. Run /workshop to design it, then /assess → /build.`

Stop. Do not claim, do not create sub-issues, do not open a PR. (Rationale: § Task workflow "Decompose epic-sized work up front" + the design-first default — a one-item drive skips the decomposition-to-seam and coverage walk that epic-sized work needs.)

## Step 4 — Route dispatch

### 4a — `fresh`: claim-first, then drive as a 1-item level

The target is drivable. Claim is the **first mutating action** (owned by `build-level.mjs` 3a). Invoke the saved Workflow as a **1-item level**, exactly as `/sweep` Phase 2 does (invoke by `scriptPath`; `args` delivered as a JSON string the script parses):

```
Workflow({ scriptPath: workflowPath, args: {
  repoRoot, board: <BOARD>, ownerRepo, claimCmd, machineryBinDir,
                         // machineryBinDir resolved in Step 0 item 3 — a PLAIN absolute machinery path, so
                         // the .mjs never emits the nested $(dirname "$(readlink -f …)") substitution the
                         // auto-mode classifier denies on --unattended/pipeline runs (temperloop#72).
                         // Absent = the .mjs's in-bash machineryBin fallback, i.e. exactly that shape.
  principlesSummaries: <the Step 0 item 5 map, { "<ownerRepo>": "<rendered summary>" }>,
  principlesDefaultRepo: <$ownerRepo>,
                         // the effective (kernel ∪ project) engineering principle set, resolved ONCE per
                         // run in Step 0 item 5 on this same Step-0 hand-off seam (the Workflow runtime has
                         // no filesystem/vault to resolve it itself). Omitted → workerPrompt() falls back
                         // to its static kernel-only snapshot plus an explicit DEGRADED notice.
  machinerySoloModel: <$BUILD_MACHINERY_SOLO_MODEL>, machineryBatchModel: <$BUILD_MACHINERY_BATCH_MODEL>,
                         // both sourced in Step 0 item 4 — pass the resolved value straight through, empty
                         // or not (the .mjs's own `|| 'haiku'` fallback is empty-string-safe; temperloop#982)
  gateSliceSecs: <$BUILD_GATE_SLICE_SECS>,
                         // §3e.5 gate per-SLICE budget, same Step-0 hand-off seam and same empty-safe
                         // fallback (the .mjs clamps it under the agent Bash cap; temperloop#1021)
  machineryStepCeilingSecs: <$BUILD_MACHINERY_STEP_CEILING_SECS>,
  machineryStepSlowSecs: <$BUILD_MACHINERY_STEP_SLOW_SECS>,
                         // per-STEP wall-clock liveness ceiling + its progress-notice threshold, same
                         // Step-0 hand-off seam. The .mjs compiles the ceiling into the machinery
                         // command text itself (a sleep/kill watchdog INSIDE the invoked shell,
                         // independent of the Bash tool's own timeout, which temperloop#1071 observed
                         // failing to fire on a 9h49m step); a bounded-out step is treated as LOST and
                         // disposed through pr.sh recover-probe, never blind-retried. The .mjs clamps
                         // both and keeps its own defaults, so empty/absent is safe.
  planLink: "",          // EMPTY — a /fix target has no vault plan note; linkage rides `Closes #N`
                         // (from ghIssue) instead. pr.sh skips the plan-link block on "".
  items: [ {
    slug,            // kebab from the issue title, SUFFIXED with `-<issue>`, total ≤40 chars
                     //   (the number guarantees a unique worktree path `<repoRoot>.wt/<slug>`)
    branch,          // <type>/<slug> per [[Decisions/foundation - Branch naming convention]]
                     //   (type from labels: bug→fix, enhancement→feat, docs→docs, else fix)
    title,           // the issue title, refined to an imperative PR title
    kind: <'spike' if the issue carries the spike label, else 'code'>,
    ghIssue: <issue>, // → the workflow's pr.sh open emits a bare `Closes #<issue>`
    alsoCloses: [],
    model: <$FIX_WORKER_MODEL, sourced in Step 0 item 4 — pass it straight through, empty or not (the
                     //   .mjs's own `item.model || undefined` is empty-string-safe; empty = inherit the
                     //   session model, top tier, safe — today's unchanged default)>,
    acceptance: <checkable bullets from the issue body; else "(self-verify the issue is resolved)">,
    source: "#<issue>",
    scope: <the issue title / first body line>,
    notes: <any operator clarification already captured this run, else "">
  } ],
  verdicts: {}, onlySlugs: []
} })
```

The workflow claims (3a), creates the worktree (3b), runs the **isolated worker** (3c), runs the acceptance gate + closing-keyword scan + push-by-SHA + PR open + CI poll (3e.5–3g), and returns **`{parked, escalations}`** — **it never merges**. Branch on the return:

- **`parked: [{ slug, pr, pushed_sha, acceptance_results }]`** (worker done) → proceed to **Step 5** with this `pr` (a `code` item has `pr` set + CI green; a **spike** has `pr: null`).
- **`escalations: [{ slug, kind, payload }]`** (the worker hit a question / blocker — `blocked` / `design-fork` / `failed` / a machinery escalation) → **park + stop** (a terminal **parked** disposition for this single-item run; `/fix` drives *one* item, so a worker escalation ends the run — resume = re-run `/fix` on the same target after answering, **never an in-place continuation**, since `/fix` always invokes `build-level.mjs` with `verdicts: {}, onlySlugs: []`, i.e. never `isContinuation`). Surface the escalation via `decision_sink_ask(<the payload's question / design_fork.decision+options / failure_reason>, <per-kind options>, ask-now)`; if the operator answers **inline**, record the answer and **re-run the drive from Step 2** (the answer rides into 4a's item `notes:`). Otherwise **park the target so a later re-run is lossless** — mirror `/sweep`'s escalation park exactly (**never leave the claim held or the worktree as debris** — a still-held claim makes a same-session re-run route back through `fresh` and `worktree.sh create` **force-clear** the orphaned worktree, silently discarding the escalated worker's uncommitted edits; a cross-session re-run instead reads `claimed-elsewhere` and 4d stops, blaming a dead prior run): <!-- cite: FX.8 class:escalated-work-destruction -->
  1. `board_set_status "$(board_item_id <issue>)" "$BOARD_OPT_READY"` — move it out of In Progress back to `Ready` (the open question, carried by the label below, is what parks it — the `Blocked` bucket was retired in #435).
  2. `gh issue comment <issue> -R "$repo" --body "Parked by fix — <the question from payload>. Where it stands: <one line>. Re-run /fix <issue> once answered."` — post the question **FIRST**, before the handled markers below (a labeled+assigned issue with no question comment is silent loss; if this comment fails, do **not** proceed to step 3 — leave it un-flagged to re-park on the next run).
  3. `gh issue edit <issue> -R "$repo" --add-label needs-clarification --add-assignee @me` — **only after step 2 succeeds.** The `needs-clarification` label is the open-question gate `/next` / `/sweep` / `/assess` honor; `@me` routes it into the operator's assigned queue at source.
  4. `"$RELEASE" <issue> --board "$BOARD"` (clear the claim marker), then `workflows/scripts/build/worktree.sh remove "$repoRoot" <slug>` — the workflow leaves an escalated worktree **intact**; `/fix` discards it (resume = re-run, not in-place continuation), so remove it now. This is what prevents the next run's `worktree.sh create` from force-clearing an orphaned worktree — the lossless-re-run guarantee.
  5. Record the target as **parked** (with the reason + the `needs-clarification` marker carrying it forward) and **stop** at Step 7.

### 4b — `adopt`: revalidate the existing PR, never open a duplicate

**First, guard the label-only adopt.** `resolve` returns `adopt` on **two** conditions: exactly one open linked PR, *or* the `funnel-merge-pending` label — and the label branch fires with `pr_count == 0`, so `resolve.open_prs` may be **empty**. Check it: **if `resolve.open_prs` is empty**, there is no PR to adopt — the `funnel-merge-pending` label is **stale** (the pipeline meant to merge but the PR is gone/closed). Do **not** call `reattach` with an empty PR (it hard-errors `must be a PR number`). Instead **treat the target as `fresh`**: fall through to **Step 4a** (claim-first + drive), and clear the stale `funnel-merge-pending` label at the terminal disposition (Step 6.2). Only proceed with the revalidation below when `resolve.open_prs` has exactly one entry. <!-- cite: FX.6 guard:workflows/scripts/build/issue-state.sh -->

Otherwise the issue has one open linked PR (`pr = resolve.open_prs[0].number`). **Do NOT invoke `build-level.mjs`** (it would open a second PR). Instead revalidate and merge the existing one:

```bash
issue-state.sh reattach "$repo" "$pr"   # → {ready|not-ready, reason} verdict; NEVER merges
```

Read `.ready`, `.reason`, `.state`, plus the PR's **draft** flag and **author** (from `resolve.open_prs[0].draft` / `.author`). Branch:

- **`ready: true`** → proceed to **Step 5** (the modal merge gate) with this `pr`. Carry the **draft** / **foreign-author** state forward so Step 5 can name it (a foreign-author PR = `.author` is not you *and* it shows recent activity; a draft = `.draft == true`). `/fix` never drives a draft or foreign-author-active PR past the gate without the approval prompt naming that state.
- **`ready: false`** → **park + stop** with the reason (Step 6 park path): `closed-underneath` (the PR closed since — re-run to re-resolve, likely `fresh`), `conflict` / `stale-base-conflict` (needs a human rebase — report it), `ci-red` (report the failing PR), `ci-pending` (report + suggest re-run once CI settles), `ci-error` (`reattach` emitted an unrecognized `ci-poll.sh` outcome — report it), `stale-base — needs update` (**`reattach` degrades to a signal here — it does not own a checkout**; `/fix` DOES own one. **Default: park with the "needs rebase" reason** rather than force-push under the operator. Only on **explicit operator approval** of the refresh, run the rebase itself — `pr.sh rebase` + `pr.sh push --force` + a `--sha`-pinned `ci-poll.sh` — then re-invoke `reattach`). Never merge a `not-ready` PR.

### 4c — `question-first`: surface the open question, do not drive

The issue carries `needs-clarification` — it is not yet drivable. Read triage's recorded `needs-clarification: <question>` comment (or derive the specific ambiguity), **surface it to the operator** via `decision_sink_ask(<the question>, <the answerable options / freeform>, ask-now)`, and:

- **Operator answers** → record the answer as a comment, `--remove-label needs-clarification`, and **re-run the drive from Step 2** (`resolve` now returns `fresh`, and the answer rides into 4a's item `notes:`).
- **Operator absent / defers** → leave it flagged and **park + stop** (Step 6 park path) — it stays `needs-clarification` for the next `/fix` / `/sweep` / `/assess` pass.

`/fix` never drives a `question-first` target — the open question is a hard gate, not a look-up a worker can resolve.

### 4d — `claimed-elsewhere`: honor the claim, stop

The issue is In Progress under a **different** Host/Session (`resolve.claim.host_session`). **Report it and stop** — do not claim, do not drive, do not steal: `#<issue> is claimed by <host_session> (in progress in another session). Not stealing the claim — resume that session, or re-run /fix once it's released.` This is a terminal **reported-no-op** disposition. Before the report, **emit the run telemetry** — Step 6 item 4, with `--reported-no-op 1` and every other count `0`; this route touches nothing else in Step 6 (skip items 1–3), but the emit still fires so the run leaves a record.

### 4e — `already-done`: no-op, clear stale labels

The issue is closed. There is nothing to drive. **Clear any stale routing label** still on it (`funnel-escalated` / `funnel-merge-pending` — see Step 6) so it doesn't re-surface as stuck. Then **emit the run telemetry** — Step 6 item 4, with `--reported-no-op 1` and every other count `0`; skip items 1–3 (the label clear above is the only convergence this route does). Then report `#<issue> is already closed — nothing to fix.` Terminal **reported-no-op**.

### 4f — `ambiguous`: disambiguate, never guess

More than one open PR links to the issue (`resolve.open_prs` has ≥2). `/fix` **must not guess** which to adopt. Surface all candidates via `decision_sink_ask(<the N open PRs + their draft/author/CI state>, [adopt PR #A, adopt PR #B, …, stop and let me clean up], ask-now)`. The chosen PR reroutes to **4b** (`reattach` + Step 5). "Stop" is a terminal **parked** disposition (the operator resolves the duplicate PRs by hand). This is an `ask-now` decision with **no safe default** — never auto-proceed on silence.

## Step 5 — The MODAL merge gate (exactly ONE confirmation)

Reached from 4a (a fresh drive with `pr` set), 4b (an adopted `ready` PR), or 4f (a disambiguated adopt). temperloop is **hand-driven**: the merge is **always modal**, **never timed**, and there is **exactly one** merge confirmation per run.

- **Spike (`pr: null`)** → do **NOT** run `gh pr merge null`. **Close the issue directly**: `gh issue close <issue> -R "$repo" --comment "Spike verdict captured (fix)."` (the board half then follows the backend-conditional rule in Step 6 item 3 — there is no `fnd:status:done` label on the issues-only backend; Done there is *closed with **no** `fnd:status:*` label*). Record **resolved (verdict)** and go to Step 6. (No merge gate — there is nothing to merge.)
- **Code (`pr` set)** → surface the merge for **explicit operator approval**, then merge **backend-aware** via `gate.sh` (never a hardcoded incantation).

  **First, probe the merge backend** (the same 4a probes `/build` runs — do this once, before the ask, so the approval prompt can state the path): `gate.sh backend "$repo"` → `NATIVE` | `MANAGED` (a `probe_failed:true` verdict fails safe to `MANAGED` — surface that caveat), and on `MANAGED`, `gate.sh strict "$repo"` → the `--strict` / `--non-strict` flag. **temperloop probes `NATIVE`** today (verified via `gate.sh backend`); do not hard-assume it — the probe is authoritative every run.

  **Then surface the ONE modal approval** through the seam, exactly as `/build` Step 4's risky-set path:

  ```
  decision_sink_ask(
    <the DEFECT this fixes (the Problem summary slot) FIRST, then the PR (#, title, CI state) + the fix it lands + the backend (NATIVE|MANAGED) + ANY state caveat>,
    [ Merge #<pr>, Hold (do not merge) ],
    ask-now
  )
  ```

  **Problem first, then the fix — the leading slot is defined elsewhere, not here.** `<the DEFECT this fixes>` is `claude/message-schema.md`'s **Question block** template § Problem summary slot; that template owns its shape (a compressed one-to-two-line restatement of the issue's own defect statement, **not** its title — the title already rides in the PR slot beside it), owns its **three arms**, and owns the **never-fabricate rule**. Do not restate any of that here — the two consumer sites would drift.

  **Fill the slot with ONE read, right here, immediately before the ask** — alongside the `gate.sh backend`/`strict` probes above, which already make this step a `gh`-calling step:

  ```bash
  gh issue view "$issue" -R "$repo" --json body -q .body
  ```

  Step 2's `issue-state.sh resolve` did **not** already fetch this — it reads `state,labels,assignees` only, so the run holds the issue *number*, never its defect prose. One extra read on the single target `/fix` drives, once per run, at a modal gate that is about to merge: negligible. Render the arm the read selects — **all three are implemented here, none is skipped**:

  - **Arm 1 — summary rendered.** Non-empty body → the compressed restatement. This is the normal path, **including for a description target**: Step 1 sub-step 4 already minted the issue from the operator's description, so its body *is* the defect statement and the run reaches Step 5 with a real `$issue`.
  - **Arm 2 — `no linked issue — <one-line reason>`.** No `$issue` to read. Step 1 mints one for every accepted target, so this arm is `/fix`'s **defensive** case rather than its common one — render it anyway (`no linked issue — target carries no issue number`) instead of dropping the slot, so a missing reference reads as a stated absence rather than as an omission.
  - **Arm 3 — `summary unavailable — <one-line reason>`.** The read exited non-zero or returned an empty body — issue deleted, `gh` auth failure, rate limit, network error, blank body. Name which. **Do not fall back to the issue title, the PR title, or the diff:** the template forbids inferring the defect, and this modal gate is exactly the artifact a fabricated restatement would corrupt.

  **The prompt MUST name any non-clean state explicitly** (criterion 3): if the PR is a **draft**, say so and note merging it requires marking it ready; if the PR has a **foreign author showing recent activity**, name the author and that you'd be merging someone else's active work. Absent explicit approval that names the state, do **not** merge. (The seam carries only the ask — the merge mechanics stay outside it, per `/build` Step 4's load-bearing invariant.)

  - **Approved** → merge via the **backend-selected** machinery path (identical mechanics to `/build` Step 4b, composed from `gate.sh` — never a hand-written `gh pr merge`):
    - **`NATIVE`** → `gate.sh queue "$repo" <pr>` (the canonical `--auto` enqueue; the queue owns strategy + branch lifecycle), then **confirm the merge lands, bounded**: `gate.sh poll "$repo" <pr> --timeout "$BUILD_QUEUE_TIMEOUT"` (the native-queue wait setting `/build` uses for the same purpose, sourced in Step 0.4; `${BUILD_QUEUE_TIMEOUT:-<default>}` in a non-vendoring checkout — never a written-in literal, per § Named-setting convention). Its `MERGED` (exit 0) is the confirmed-`MERGED` guard; a `CONFLICTING`/`DIRTY` (exit 3) → **run the shared `rebase-and-retry` disposition** (below) before parking; a `TIMEOUT` (exit 4) → **terminal disposition "enqueued — not yet confirmed merged"** (the PR is queued; a re-run re-adopts and re-confirms — never an unbounded wait).
    - **`MANAGED`** → `gate.sh managed-merge "$repo" <pr> --strict|--non-strict` (the flag from the `strict` probe). This runs the per-PR managed mechanics **and its own confirmed-`MERGED` poll internally** — its `MERGED` outcome *is* the confirmation. An `EJECTED` / red-after-update / `MERGE_REJECTED` outcome → **park** with the returned reason (never a silent no-op; on `MERGE_REJECTED` re-probe `gate.sh backend` in case the repo was mis-probed, per `/build` 4b). A `CONFLICTING` (exit 3) instead takes the shared **`rebase-and-retry`** disposition below, exactly as the NATIVE arm does.
    - **`rebase-and-retry` on a `CONFLICTING`/`DIRTY` (both backends) — the shared disposition, referenced not re-encoded.** A queue-time conflict is usually just a base that **moved** while the PR sat in the gate, not a content conflict, so do **not** park on the label. Run **`/build` § 4c's `4c-retry` — the shared `rebase-and-retry` disposition** (`claude/commands/build.md`, the numbered steps 1–4 under that bolded run-in) verbatim against this PR — that section is the single implementation and this is a pointer to it, so the two can never drift. In outline, all of it composed from machinery `/fix` already loads (Step 0.3): materialize/refresh a worktree on the PR tip → `pr.sh rebase` → on **`REBASED`**, `pr.sh push --force` → a **`--sha`-pinned** `ci-poll.sh` on the just-pushed SHA (the #254 false-green guard) → on `CI_GREEN`, **re-enqueue and re-confirm in this same run** through the backend path above. On **`REBASE_CONFLICT`** — a genuine content conflict, which `pr.sh` has already safely `git rebase --abort`ed — **park**, naming the conflicting files; a content conflict is never auto-resolved.
    - **The re-enqueue takes NO second approval — and this is not a hole in Step 5's "exactly ONE confirmation" rule.** The one modal `decision_sink_ask` this run already recorded approved merging *this PR's content*; a clean rebase replays those same commits onto a newer base and changes no hunk, so the merge decision is **unchanged** and there is nothing new to approve. The only thing that moved — the base — is re-verified **mechanically** by the SHA-pinned poll, not assumed. Every genuinely new decision still halts: a content conflict parks, a `CI_FAILED` on the new base parks, and a **second** `CONFLICTING` stops the retry rather than looping. (The full warrant, and its relation to the kernel's § Merge autonomy & consent, lives in `/build` § 4c's `4c-retry` step 4.)
    - On confirmed `MERGED`, record **merged (#<pr>)** and go to Step 6.
  - **Held** → do not merge. **Park + stop** (Step 6 park path) recording "held at merge gate — operator declined." The PR stays open for a later `/fix` re-run (which will re-enter via the `adopt` route).

## Step 6 — Converge to a terminal disposition (worktree + labels + report)

For a disposition on **this run's own item** — a `fresh`/`adopt`/`ambiguous` drive that reached merged / resolved / parked / held — converge the local + board state **in-lane** (this session's own `repoRoot`, never a foreign canonical checkout — the working-tree-ownership rule), then report. **Items 1–3 below (worktree reclaim, stale-label clear, board Done) are scoped to that convergent set only** — the two **reported-no-op** routes are exceptions to them: `already-done` (4e) only clears its own stale label; `claimed-elsewhere` (4d) touches **nothing**, since it is not this run's item to converge. **Item 4 (the telemetry emit) is different: every terminal route reaches it, reported-no-op included** — 4d and 4e each call it directly (with `--reported-no-op 1`) immediately before their own report, so a `/fix` run that found nothing to do still leaves a telemetry record rather than going straight to the report with none.

1. **Reclaim the worktree (in-lane, idempotent)** — for a **merged** or **resolved (verdict)** disposition that built in a worktree (the 4a fresh drive; not the 4b adopt path, which owns no local worktree): `workflows/scripts/build/worktree.sh remove "$repoRoot" <slug>`. Idempotent by construction — `cmd_remove` returns `REMOVED` when a worktree/`build/<slug>` branch existed and `NOT_FOUND` otherwise, so a re-run (or the deploy-mini session-start sweep, F#653, the crash-path backstop) is a safe no-op.
2. **Clear stale routing labels (any terminal disposition of an adopted / pipeline-touched item)** — remove `funnel-escalated` and `funnel-merge-pending` if present: `gh issue edit <issue> -R "$repo" --remove-label funnel-escalated --remove-label funnel-merge-pending` (harmless if the label is absent). A stuck-state routing marker must not survive a real terminal disposition — otherwise `/next` / `/sweep` / the pipeline keep treating the item as still-stuck (criterion 5). For a **parked** disposition, the item instead carries `needs-clarification` (added by 4a/4c's park path) — that is the intended open-question marker, left in place.
3. **Board close→Done — the explicit Done write is REQUIRED, same rule as `/build` 4d** (K#902). The issue itself is already closed — by the PR's `Closes #<issue>` for a **merged** item, by the `gh issue close` in Step 5 for a **spike** — but **nothing moves the board item to Done on its own; there is no cascade and nowhere to hook one**, so this write is the *primary* mechanism, not a backstop. First guarded-source `lib/cache.sh` alongside `lib/board.sh` — `if [ -f "$(dirname "$BOARD_LIB")/cache.sh" ]; then . "$(dirname "$BOARD_LIB")/cache.sh"; fi` (never `[ -f … ] && .` under this block's `set -e` — `worklist.sh:50-53` is the precedent) — so this write activates cache invalidation on the merge-confirmed Done write (the `_board_cache_dirty_after_write` hook, `board.sh:769`/`:849`/`:923`, is a designed no-op while the lib is unsourced; temperloop#1164 is a following board read otherwise serving this issue as still open/In-Progress). Then: `board_resolve_item "$BOARD" <issue>; board_set_status "$(board_item_id <issue>)" "$BOARD_OPT_DONE"` — it strips the residual `fnd:status:*` label and the `fnd:host/session:*` claim stamp (the issue being already closed, no second close fires). Non-zero return ⇒ **warn-and-continue** naming the issue; `reconcile.sh --status` / `--labels --apply` still backstops it.
4. **Emit the run telemetry record** (best-effort, `|| true`-safe, absent-checkout-safe — same convention as `/sweep` Step 3.6): append one command-run record so a `/fix` run is never an invisible no-signal event. **Every terminal route reaches this step, reported-no-op included** — see the preamble above:
   ```bash
   "$(git rev-parse --show-toplevel)/workflows/scripts/emit-command-run.sh" \
     --command fix --board "$BOARD" \
     --items-processed 1 \
     --merged <1 if merged else 0> \
     --resolved <1 if resolved (verdict) else 0> \
     --parked <1 if parked else 0> \
     --reported-no-op <1 if reported-no-op (already-done / claimed-elsewhere) else 0> || true
   ```

   Exactly ONE of the four is `1` — a `/fix` run drives exactly one item to exactly one terminal disposition, so `merged + resolved + parked + reported_no_op` always equals `--items-processed` (`1`), which is what the emitter asserts (temperloop#1084, extended #1103; it exits non-zero on a mismatch rather than writing a record whose counts don't reconcile). `--resolved` is the spike arm: a `#<issue>` closed on its verdict is a real terminal success, not a merge, and folding it into `--merged` — the pre-#1084 shape — made the two indistinguishable in the stream. `--reported-no-op` is the `already-done` (4e) / `claimed-elsewhere` (4d) arm, added by temperloop#1103: before it, those two routes skipped this emit entirely — the schema had no fourth field to express "nothing happened, on purpose" without tripping the disposition-mismatch failure above — so a no-op `/fix` run left **no telemetry record at all**, the exact absent-signal failure this stream exists to close (a real reproduction: `/fix 1100` resolved `already-done` and reported 0 dispositions against `items_processed:1`, never reconciling because the run never even reached this step). Held / not-ready-adopt / question-parked / ambiguous-stop all count as **parked**, same as before.

## Step 7 — Report the terminal disposition

End with a re-orientation block (BLUF — the outcome first, then the Endsley perception→comprehension→projection shape). **The report MUST state exactly one terminal disposition** for the target:

- **Merged** — `#<issue>` → merged in **PR #<pr>**, issue closed, worktree reclaimed.
- **Resolved (verdict)** — a spike `#<issue>` → closed directly with the verdict comment.
- **Parked (open question / not-ready / held)** — `#<issue>` → the reason it parked (the worker's question, `reattach`'s not-ready reason, or a declined merge), and which marker carries it forward (`needs-clarification` for a question; the open PR for a held/not-ready adopt) so a re-run resumes it.
- **Reported-no-op** — `already-done` (closed already), `claimed-elsewhere` (owned by another session), or **epic-refused** (epic-sized target redirected to `/assess --epic <N>` or `/workshop`, Step 3) → what was found and why `/fix` stopped.

State what changed, what it means for the target as a whole, and the single next move if the run parked. End with a compact **refs legend** (qualified issue/PR numbers → title) per the communication conventions.
