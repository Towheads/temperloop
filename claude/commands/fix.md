---
description: Drive a single, named target — an issue number OR a free-text description — from wherever it is now to **merged + closed**, by composing the existing build spine (state probe → claim → isolated worker → PR → CI → **modal** merge). The targeted single-item peer to `/build` (epic'd work) and `/sweep` (a board's whole Ready-singleton pool): `/fix` is "just make *this one* go."
argument-hint: "<issue# | description> [--repo <owner/repo>] [--dry-run]"
---

You are running the **fix** command. Goal: take **one** named target and drive it to a **terminal disposition** — merged + issue closed + worktree reclaimed for real code, or a verdict-close for a spike — reusing the spine that `/build` and `/sweep` already own. `/fix` is a **thin driver that COMPOSES existing components**; it does **not** reimplement claim / worktree / PR / CI / merge mechanics.

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

- **Compose the spine — do NOT re-orchestrate.** Every mechanic `/fix` needs already exists and is battle-tested; `/fix` is a conversational driver *over* them, not a reimplementation. It reuses, by name:
  - **`workflows/scripts/build/issue-state.sh resolve <repo> <issue>`** — the ground-truth **state probe**. `/fix` runs this **FIRST**, before any mutation, and routes on its single JSON `route` verdict (`fresh|adopt|question-first|claimed-elsewhere|already-done|ambiguous`). See Step 2 for the route→action map; read that script's header + `cmd_resolve` for the exact verdict shape.
  - **`workflows/scripts/build/issue-state.sh reattach <repo> <pr>`** — the **adoption-safety** revalidation for an already-open PR (state / mergeability / a `--sha`-pinned CI re-poll / a `BEHIND`-base rebase signal). It returns a `{ready|not-ready, reason}` verdict and **NEVER merges** (the caller owns the merge). `/fix` runs this on the `adopt` route so it **merges the existing PR instead of opening a duplicate**. See `cmd_reattach` + `reattach_usage` for the verdict shape.
  - **`claude/workflows/build-level.mjs`, invoked as a 1-item level via the Workflow tool** — the merge *drive* for **fresh** work (claim → worktree → isolated worker → acceptance gate → closing-keyword scan → push-by-SHA → PR open → CI poll → `{parked, escalations}`). `/fix` invokes it **exactly as `/sweep` Phase 2 does** — one item, `scriptPath` not `name:` (#437). **No hand-rolled fix loop.**
  - **`workflows/scripts/build/gate.sh`** — the **backend-aware merge** spine (`gate.sh backend` selects NATIVE vs MANAGED; `gate.sh queue` + `gate.sh poll` drive + confirm a native-queue merge; `gate.sh managed-merge` runs the per-PR managed mechanics with its own confirmed-`MERGED` poll). `/fix`'s merge (Step 5) composes these — it does **not** hardcode a merge incantation. It **probes the backend at run time and never assumes a fixed one**: a hardcoded `gh pr merge --auto` (the NATIVE-only arm) breaks the moment it runs on a MANAGED repo, and a hardcoded managed path breaks on a NATIVE one. (temperloop itself probes `NATIVE` today — verified via `gate.sh backend` — but a repo's backend can change; `build.md` Step 4b, `docs/managed-merge-queue.md`, temperloop#13. The probe, not any written-in assumption, is the per-run source of truth.)
  - **`workflows/scripts/build/worktree.sh`** (worktree lifecycle), the **board adapter** (`workflows/scripts/board/lib/board.sh` + `claim.sh`/`release.sh`), **`pr.sh`**, **`ci-poll.sh`** — reused verbatim, never re-encoded.
- **The state probe runs before any mutation.** `resolve` is read-only and cheap; it is the first thing `/fix` does for an issue target, and its verdict determines the whole run. `/fix` never claims, builds, or opens/merges a PR before `resolve` has classified the target. (Fetch ground truth before building.)
- **Claim-first — against a drivable target.** When the route is `fresh`, the board claim is the **first mutating action** (`build-level.mjs` 3a claims before its worker investigates — the board is a cross-session lock). `/fix` never investigates code or opens a worktree before the claim on a target it is about to drive. (**One inherited exception:** a `spike`-labeled target — `build-level.mjs` returns a verdict-only park *before* its 3a claim block runs, so a spike is not claimed-first. This is a pre-existing `build-level.mjs` / `build.md`-line-312 divergence inherited by `/build` and `/sweep` too, tracked separately — not `/fix`-specific.)
- **Never open a duplicate PR; never steal a claim.** An `adopt` route **revalidates and merges the existing PR** (never opens a second). A `claimed-elsewhere` route **reports the owning session and stops** — a live claim by another session is honored, never stolen.
- **Every run ends at a terminal disposition — never at "PR opened."** The terminal set is: **merged** (code, PR confirmed `MERGED` + issue closed), **resolved (verdict)** (a spike, verdict-closed with a comment), **parked** (an open question / not-ready adoption / a held merge, recorded for a human), or **reported-no-op** (already-done / claimed-elsewhere / epic-refused). A `/fix` run that stops at "opened a PR" is a bug — the merge gate (Step 5) is part of the same run.
- **The merge gate is MODAL** (temperloop is hand-driven). `/fix` **never** timed-auto-merges. Every merge is surfaced for **explicit operator approval** through the `decision_sink_ask(question, options, severity)` seam (severity `blocking-now`), exactly as `/build` Step 4's risky-set path does — and there is **exactly ONE** merge confirmation per run. A **draft** PR, or a PR with a **foreign author showing recent activity**, is never driven past the gate without the approval prompt **naming that state explicitly** (Step 5).
- **A spike target is verdict-closed, never `gh pr merge`d.** A target that produced no PR (`pr: null` — a `spike`-labeled item that `build-level.mjs` parked verdict-only) is **closed directly** with a comment. Never run `gh pr merge null` (a silent no-op that would falsely report "fixed").
- **Clear stale routing labels at any terminal disposition of an adopted item.** A target that had been through the autonomous funnel may carry `funnel-escalated` / `funnel-merge-pending`; these are stuck-state routing markers. On **any** terminal disposition of an adopted (or funnel-touched) item, **remove them** so the item does not re-surface to `/next` / `/sweep` / the funnel as still-stuck (a GitHub label survives the PR closing/merging — only an explicit `--remove-label` clears it).
- **Refuse epic-sized targets.** `/fix` drives **one seam-scoped fix**. If the named target is **epic-sized** — it is itself an epic (has native sub-issues, or carries the `epic` label), or the described work is `EPIC_MIN_SUBUNITS`+ parallelizable sub-units / more than one dependency level — `/fix` **refuses and redirects**: a *discovered* epic to `/triage` → `/assess`, an *invented* one to `/workshop` (§ Task workflow "Decompose epic-sized work up front"; the design-first default). Don't manufacture a one-item drive for epic-sized work.
- **Deploy caution — install before you drive.** This spec is **live only once installed** to `~/.claude/commands/fix.md` (`make install`). A change to this file is inert in the running session until re-installed — fix-and-redeploy the driver *before* driving work through it ([[Patterns/temperloop - Fix and redeploy the driver before driving work through it]]). If you just edited this spec, redeploy before invoking `/fix`.

## Step 0 — Validate + resolve the repo + deploy caution

Run in parallel:

1. `gh auth status` — must list the **`project`** scope (board claim reads/writes need it). Missing → stop with the `gh auth refresh -s project` hint.
2. **Board + spine probe.** Set `BOARD_LIB` = the first of `scripts/lib/board.sh` or `workflows/scripts/board/lib/board.sh` that exists; `source "$BOARD_LIB"`. Resolve the target repo: `--repo` if given, else `repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"` (a full `owner/repo#N` target overrides). Infer the board from that repo the way `/sweep` Step 0.2 does — iterate `board_registered_boards`, match on `board_repo`; **board 7 is temperloop's issues-only tracker** (`fnd:status:*` labels, no Projects-v2 board — `workflows/scripts/board/ISSUES-ONLY-BACKEND.md`). Print `target repo <repo> (board <N>)` before any read. An unmapped repo with a non-existing target issue → stop (nothing to drive and no board to file against); an unmapped repo is otherwise fine for a description target only if you can still create the issue there.
3. **Resolve the workflow-invocation context** (passed to the per-item `build-level.mjs` call, identical to `/sweep` Step 0.3): `repoRoot="$(git rev-parse --show-toplevel)"`, `ownerRepo="$repo"`, `claimCmd` = absolute path to `claim.sh`, and `workflowPath="$HOME/.claude/workflows/build-level.mjs"` (invoked by **`scriptPath`**, never `name:` — #437).
4. **Source the batch-pipeline config** — `source workflows/scripts/build/build.config.sh` (bare repo-relative) — pulls `EPIC_MIN_SUBUNITS` (the epic-size threshold used by the epic-refusal gate) and the merge-gate knobs into scope. Absent in a non-vendoring checkout → proceed with the belt-and-suspenders `${KNOB:-default}` forms.

**Deploy caution:** if this `/fix` invocation is the first since this spec was edited, confirm it was re-installed (`make install`) — an un-redeployed edit runs the *old* spec. If any Step-0 check fails, surface it in one line and stop.

## Step 1 — Resolve the target (issue number vs. description)

**Decide the target's shape:**

- **Issue number** (`123`, `#123`, `owner/repo#123`) → skip to **Step 2** with that `<repo> <issue>`.
- **Description** (anything else) → **mint the issue first, safely**, then fall through to Step 2 with the new issue number. Four sub-steps, in order:
  1. **Echo the resolved `owner/repo` and get explicit confirmation BEFORE any write.** Print `Target repo: <owner/repo>. Create a new issue here for: "<description>"?` and route it through `decision_sink_ask(<the repo + the described work>, [create here, pick a different repo, cancel], blocking-now)` — **no issue is created until the operator confirms the repo.** (Silence is not consent; a wrong-repo issue is exactly what this gate prevents.)
  2. **Duplicate-issue probe — ASK on ambiguity, never silently create.** Search the target repo for an existing open issue that plausibly covers this description: `gh issue list -R "$repo" --state open --search "<key terms>" --json number,title,url --limit 10`. **If a plausible match exists, do NOT create** — surface the candidate(s) via `decision_sink_ask(<the candidate issue(s) + the description>, [adopt candidate #N (drive the existing one), create a new issue anyway, cancel], blocking-now)`. "Adopt candidate" reroutes the run to that issue number (back to Step 2); "create anyway" continues to sub-step 3. Only a genuinely empty search proceeds to create without asking. **A non-zero `gh issue list` exit (auth / rate-limit / network) is NOT a genuinely-empty result** — on any error, degrade to **ask before creating** (surface the failure through the same `decision_sink_ask` and let the operator decide), never proceed as if empty; proceeding on a swallowed error creates a duplicate issue for an already-tracked description (a named-failure-path gap — `Patterns/foundation - Design for failure modes`).
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

**Epic-size refusal gate (before a *drive* — the `fresh` / `adopt` / `ambiguous` routes ONLY).** For a route that would drive the target, check whether it is **epic-sized**: `gh api repos/<owner>/<repo>/issues/<issue>/sub_issues --jq 'length'` > 0, or the issue carries the `epic` label. If so, **refuse and redirect** (Step 3) — do not drive it. **Skip this probe for the terminal routes** (`question-first` / `claimed-elsewhere` / `already-done`) — they report their own disposition and never drive, so probing sub-issues to "refuse" an already-closed or claimed-elsewhere issue would be nonsensical (and wastes a call).

**`--dry-run`:** STOP here. Print the `resolve` verdict, the chosen route, and the action `/fix` *would* take, then "Re-run without `--dry-run` to execute." Zero mutation.

## Step 3 — Refuse epic-sized targets (redirect, don't drive)

If the epic-size gate fired: `/fix` does not drive epic-sized work. Report it in one line and redirect:

- **A discovered epic** (an existing epic issue, or work that is clearly `EPIC_MIN_SUBUNITS`+ sub-units / multi-level) → `Refusing: #<N> is epic-sized. Route it through /triage → /assess → /build (decompose to the seam first).`
- **Invented epic-sized work** (from a description) → `Refusing: this is epic-sized invented work. Run /workshop to design it, then /assess → /build.`

Stop. Do not claim, do not create sub-issues, do not open a PR. (Rationale: § Task workflow "Decompose epic-sized work up front" + the design-first default — a one-item drive skips the decomposition-to-seam and coverage walk that epic-sized work needs.)

## Step 4 — Route dispatch

### 4a — `fresh`: claim-first, then drive as a 1-item level

The target is drivable. Claim is the **first mutating action** (owned by `build-level.mjs` 3a). Invoke the saved Workflow as a **1-item level**, exactly as `/sweep` Phase 2 does (invoke by `scriptPath`; `args` delivered as a JSON string the script parses):

```
Workflow({ scriptPath: workflowPath, args: {
  repoRoot, board: <BOARD>, ownerRepo, claimCmd,
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
    model: <undef>,  // no plan size → inherit the session model (top tier; safe)
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
- **`escalations: [{ slug, kind, payload }]`** (the worker hit a question / blocker — `blocked` / `design-fork` / `failed` / a spine escalation) → **park + stop** (a terminal **parked** disposition for this single-item run; `/fix` drives *one* item, so a worker escalation ends the run — resume = re-run `/fix` on the same target after answering, **never an in-place continuation**, since `/fix` always invokes `build-level.mjs` with `verdicts: {}, onlySlugs: []`, i.e. never `isContinuation`). Surface the escalation via `decision_sink_ask(<the payload's question / design_fork.decision+options / failure_reason>, <per-kind options>, blocking-now)`; if the operator answers **inline**, record the answer and **re-run the drive from Step 2** (the answer rides into 4a's item `notes:`). Otherwise **park the target so a later re-run is lossless** — mirror `/sweep`'s escalation park exactly (**never leave the claim held or the worktree as debris** — a still-held claim makes a same-session re-run route back through `fresh` and `worktree.sh create` **force-clear** the orphaned worktree, silently discarding the escalated worker's uncommitted edits; a cross-session re-run instead reads `claimed-elsewhere` and 4d stops, blaming a dead prior run):
  1. `board_set_status "$(board_item_id <issue>)" "$BOARD_OPT_READY"` — move it out of In Progress back to `Ready` (the open question, carried by the label below, is what parks it — the `Blocked` bucket was retired in #435).
  2. `gh issue comment <issue> -R "$repo" --body "Parked by fix — <the question from payload>. Where it stands: <one line>. Re-run /fix <issue> once answered."` — post the question **FIRST**, before the handled markers below (a labeled+assigned issue with no question comment is silent loss; if this comment fails, do **not** proceed to step 3 — leave it un-flagged to re-park on the next run).
  3. `gh issue edit <issue> -R "$repo" --add-label needs-clarification --add-assignee @me` — **only after step 2 succeeds.** The `needs-clarification` label is the open-question gate `/next` / `/sweep` / `/assess` honor; `@me` routes it into the operator's assigned queue at source.
  4. `"$RELEASE" <issue> --board "$BOARD"` (clear the claim marker), then `workflows/scripts/build/worktree.sh remove "$repoRoot" <slug>` — the workflow leaves an escalated worktree **intact**; `/fix` discards it (resume = re-run, not in-place continuation), so remove it now. This is what prevents the next run's `worktree.sh create` from force-clearing an orphaned worktree — the lossless-re-run guarantee.
  5. Record the target as **parked** (with the reason + the `needs-clarification` marker carrying it forward) and **stop** at Step 7.

### 4b — `adopt`: revalidate the existing PR, never open a duplicate

**First, guard the label-only adopt.** `resolve` returns `adopt` on **two** conditions: exactly one open linked PR, *or* the `funnel-merge-pending` label — and the label branch fires with `pr_count == 0`, so `resolve.open_prs` may be **empty**. Check it: **if `resolve.open_prs` is empty**, there is no PR to adopt — the `funnel-merge-pending` label is **stale** (the funnel meant to merge but the PR is gone/closed). Do **not** call `reattach` with an empty PR (it hard-errors `must be a PR number`). Instead **treat the target as `fresh`**: fall through to **Step 4a** (claim-first + drive), and clear the stale `funnel-merge-pending` label at the terminal disposition (Step 6.2). Only proceed with the revalidation below when `resolve.open_prs` has exactly one entry.

Otherwise the issue has one open linked PR (`pr = resolve.open_prs[0].number`). **Do NOT invoke `build-level.mjs`** (it would open a second PR). Instead revalidate and merge the existing one:

```bash
issue-state.sh reattach "$repo" "$pr"   # → {ready|not-ready, reason} verdict; NEVER merges
```

Read `.ready`, `.reason`, `.state`, plus the PR's **draft** flag and **author** (from `resolve.open_prs[0].draft` / `.author`). Branch:

- **`ready: true`** → proceed to **Step 5** (the modal merge gate) with this `pr`. Carry the **draft** / **foreign-author** state forward so Step 5 can name it (a foreign-author PR = `.author` is not you *and* it shows recent activity; a draft = `.draft == true`). `/fix` never drives a draft or foreign-author-active PR past the gate without the approval prompt naming that state.
- **`ready: false`** → **park + stop** with the reason (Step 6 park path): `closed-underneath` (the PR closed since — re-run to re-resolve, likely `fresh`), `conflict` / `stale-base-conflict` (needs a human rebase — report it), `ci-red` (report the failing PR), `ci-pending` (report + suggest re-run once CI settles), `ci-error` (`reattach` emitted an unrecognized `ci-poll.sh` outcome — report it), `stale-base — needs update` (**`reattach` degrades to a signal here — it does not own a checkout**; `/fix` DOES own one. **Default: park with the "needs rebase" reason** rather than force-push under the operator. Only on **explicit operator approval** of the refresh, run the rebase itself — `pr.sh rebase` + `pr.sh push --force` + a `--sha`-pinned `ci-poll.sh` — then re-invoke `reattach`). Never merge a `not-ready` PR.

### 4c — `question-first`: surface the open question, do not drive

The issue carries `needs-clarification` — it is not yet drivable. Read triage's recorded `needs-clarification: <question>` comment (or derive the specific ambiguity), **surface it to the operator** via `decision_sink_ask(<the question>, <the answerable options / freeform>, blocking-now)`, and:

- **Operator answers** → record the answer as a comment, `--remove-label needs-clarification`, and **re-run the drive from Step 2** (`resolve` now returns `fresh`, and the answer rides into 4a's item `notes:`).
- **Operator absent / defers** → leave it flagged and **park + stop** (Step 6 park path) — it stays `needs-clarification` for the next `/fix` / `/sweep` / `/assess` pass.

`/fix` never drives a `question-first` target — the open question is a hard gate, not a look-up a worker can resolve.

### 4d — `claimed-elsewhere`: honor the claim, stop

The issue is In Progress under a **different** Host/Session (`resolve.claim.host_session`). **Report it and stop** — do not claim, do not drive, do not steal: `#<issue> is claimed by <host_session> (in progress in another session). Not stealing the claim — resume that session, or re-run /fix once it's released.` This is a terminal **reported-no-op** disposition.

### 4e — `already-done`: no-op, clear stale labels

The issue is closed. There is nothing to drive. **Clear any stale routing label** still on it (`funnel-escalated` / `funnel-merge-pending` — see Step 6) so it doesn't re-surface as stuck, then report `#<issue> is already closed — nothing to fix.` Terminal **reported-no-op**.

### 4f — `ambiguous`: disambiguate, never guess

More than one open PR links to the issue (`resolve.open_prs` has ≥2). `/fix` **must not guess** which to adopt. Surface all candidates via `decision_sink_ask(<the N open PRs + their draft/author/CI state>, [adopt PR #A, adopt PR #B, …, stop and let me clean up], blocking-now)`. The chosen PR reroutes to **4b** (`reattach` + Step 5). "Stop" is a terminal **parked** disposition (the operator resolves the duplicate PRs by hand). This is a `blocking-now` decision with **no safe default** — never auto-proceed on silence.

## Step 5 — The MODAL merge gate (exactly ONE confirmation)

Reached from 4a (a fresh drive with `pr` set), 4b (an adopted `ready` PR), or 4f (a disambiguated adopt). temperloop is **hand-driven**: the merge is **always modal**, **never timed**, and there is **exactly one** merge confirmation per run.

- **Spike (`pr: null`)** → do **NOT** run `gh pr merge null`. **Close the issue directly**: `gh issue close <issue> -R "$repo" --comment "Spike verdict captured (fix)."` (the close→Done cascade / issues-only `fnd:status:done` move follows). Record **resolved (verdict)** and go to Step 6. (No merge gate — there is nothing to merge.)
- **Code (`pr` set)** → surface the merge for **explicit operator approval**, then merge **backend-aware** via `gate.sh` (never a hardcoded incantation).

  **First, probe the merge backend** (the same 4a probes `/build` runs — do this once, before the ask, so the approval prompt can state the path): `gate.sh backend "$repo"` → `NATIVE` | `MANAGED` (a `probe_failed:true` verdict fails safe to `MANAGED` — surface that caveat), and on `MANAGED`, `gate.sh strict "$repo"` → the `--strict` / `--non-strict` flag. **temperloop probes `NATIVE`** today (verified via `gate.sh backend`); do not hard-assume it — the probe is authoritative every run.

  **Then surface the ONE modal approval** through the seam, exactly as `/build` Step 4's risky-set path:

  ```
  decision_sink_ask(
    <the PR (#, title, CI state) + the fix it lands + the backend (NATIVE|MANAGED) + ANY state caveat>,
    [ Merge #<pr>, Hold (do not merge) ],
    blocking-now
  )
  ```

  **The prompt MUST name any non-clean state explicitly** (criterion 3): if the PR is a **draft**, say so and note merging it requires marking it ready; if the PR has a **foreign author showing recent activity**, name the author and that you'd be merging someone else's active work. Absent explicit approval that names the state, do **not** merge. (The seam carries only the ask — the merge mechanics stay outside it, per `/build` Step 4's load-bearing invariant.)

  - **Approved** → merge via the **backend-selected** spine path (identical mechanics to `/build` Step 4b, composed from `gate.sh` — never a hand-written `gh pr merge`):
    - **`NATIVE`** → `gate.sh queue "$repo" <pr>` (the canonical `--auto` enqueue; the queue owns strategy + branch lifecycle), then **confirm the merge lands, bounded**: `gate.sh poll "$repo" <pr> --timeout "$BUILD_QUEUE_TIMEOUT"` (the native-queue wait knob `/build` uses for the same purpose, sourced in Step 0.4; `${BUILD_QUEUE_TIMEOUT:-<default>}` in a non-vendoring checkout — never a written-in literal, per § Prose-resident knob convention). Its `MERGED` (exit 0) is the confirmed-`MERGED` guard; a `CONFLICTING`/`DIRTY` (exit 3) → park with the conflict reason; a `TIMEOUT` (exit 4) → **terminal disposition "enqueued — not yet confirmed merged"** (the PR is queued; a re-run re-adopts and re-confirms — never an unbounded wait).
    - **`MANAGED`** → `gate.sh managed-merge "$repo" <pr> --strict|--non-strict` (the flag from the `strict` probe). This runs the per-PR managed mechanics **and its own confirmed-`MERGED` poll internally** — its `MERGED` outcome *is* the confirmation. An `EJECTED` / red-after-update / `MERGE_REJECTED` outcome → **park** with the returned reason (never a silent no-op; on `MERGE_REJECTED` re-probe `gate.sh backend` in case the repo was mis-probed, per `/build` 4b).
    - On confirmed `MERGED`, record **merged (#<pr>)** and go to Step 6.
  - **Held** → do not merge. **Park + stop** (Step 6 park path) recording "held at merge gate — operator declined." The PR stays open for a later `/fix` re-run (which will re-enter via the `adopt` route).

## Step 6 — Converge to a terminal disposition (worktree + labels + report)

For a disposition on **this run's own item** — a `fresh`/`adopt`/`ambiguous` drive that reached merged / resolved / parked / held — converge the local + board state **in-lane** (this session's own `repoRoot`, never a foreign canonical checkout — the working-tree-ownership rule), then report. (The two **reported-no-op** routes are exceptions to the convergence steps below: `already-done` (4e) only clears its own stale label and reports; `claimed-elsewhere` (4d) touches **nothing** — it is not this run's item to converge — and goes straight to the report.)

1. **Reclaim the worktree (in-lane, idempotent)** — for a **merged** or **resolved (verdict)** disposition that built in a worktree (the 4a fresh drive; not the 4b adopt path, which owns no local worktree): `workflows/scripts/build/worktree.sh remove "$repoRoot" <slug>`. Idempotent by construction — `cmd_remove` returns `REMOVED` when a worktree/`build/<slug>` branch existed and `NOT_FOUND` otherwise, so a re-run (or the deploy-mini session-start sweep, F#653, the crash-path backstop) is a safe no-op.
2. **Clear stale routing labels (any terminal disposition of an adopted / funnel-touched item)** — remove `funnel-escalated` and `funnel-merge-pending` if present: `gh issue edit <issue> -R "$repo" --remove-label funnel-escalated --remove-label funnel-merge-pending` (harmless if the label is absent). A stuck-state routing marker must not survive a real terminal disposition — otherwise `/next` / `/sweep` / the funnel keep treating the item as still-stuck (criterion 5). For a **parked** disposition, the item instead carries `needs-clarification` (added by 4a/4c's park path) — that is the intended open-question marker, left in place.
3. **Board close→Done** — for a **merged** item the PR's `Closes #<issue>` closes the issue and the close→Done cascade moves the card; for a **spike** the `gh issue close` in Step 5 does the same. `/fix` issues **no** redundant explicit `board_set_status … Done` (rely on the cascade; `reconcile.sh` is the safety net) — see `/build` 4d.
4. **Emit the run telemetry record** (best-effort, `|| true`-safe, absent-checkout-safe — same convention as `/sweep` Step 3.6): append one command-run record so a `/fix` run is never an invisible no-signal event:
   ```bash
   "$(git rev-parse --show-toplevel)/workflows/scripts/emit-command-run.sh" \
     --command fix --board "$BOARD" \
     --items-processed 1 \
     --merged <1 if merged/resolved-verdict else 0> \
     --parked <1 if parked else 0> || true
   ```

## Step 7 — Report the terminal disposition

End with a re-orientation block (BLUF — the outcome first, then the Endsley perception→comprehension→projection shape). **The report MUST state exactly one terminal disposition** for the target:

- **Merged** — `#<issue>` → merged in **PR #<pr>**, issue closed, worktree reclaimed.
- **Resolved (verdict)** — a spike `#<issue>` → closed directly with the verdict comment.
- **Parked (open question / not-ready / held)** — `#<issue>` → the reason it parked (the worker's question, `reattach`'s not-ready reason, or a declined merge), and which marker carries it forward (`needs-clarification` for a question; the open PR for a held/not-ready adopt) so a re-run resumes it.
- **Reported-no-op** — `already-done` (closed already), `claimed-elsewhere` (owned by another session), or **epic-refused** (epic-sized target redirected to `/triage` → `/assess` or `/workshop`, Step 3) → what was found and why `/fix` stopped.

State what changed, what it means for the target as a whole, and the single next move if the run parked. End with a compact **refs legend** (qualified issue/PR numbers → title) per the communication conventions.
