# Global guidance

## Kernel vs overlay routing rule

This file (`claude/CLAUDE.kernel.md`) is the **shippable kernel contracts doc** — the
generic process rules a stranger's fresh install of the open-source kernel repo would
need. Its sibling `claude/CLAUDE.overlay.md` carries everything personal/org/machine-
specific (Travis's Obsidian vault, session-log hooks, personal decision-capture rules,
personal paths and boards). `make install-claude` composes both (plus a rendered
knowledge-store-routing section, see below) into the single installed
`~/.claude/CLAUDE.md` — see `workflows/scripts/install-claude-md.sh`.

Routing test for **where a new rule belongs**, applied when adding or editing a rule:

- **The stranger test.** Would a stranger's install — someone who cloned only the
  kernel repo, with no org tied to this repo's history, no Obsidian vault, no personal board — need this
  rule for the kernel machinery (board adapter, build/sweep pipeline, install/doctor,
  branch/PR policy) to work correctly? If yes → **kernel repo**, and the change should
  land **upstream first** (never patch a vendored copy of the kernel in a downstream
  overlay repo silently — the kernel repo is the source of truth for kernel content,
  exactly as this repo already is for the board toolkit and build spine synced into
  stageFind/ssmobile/subsetwiki).
- If the rule is personal, org-specific, or tied to one machine's paths/credentials →
  **overlay**.

Corollaries:

- **Kernel edits land upstream first.** A kernel-repo rule is never patched only in a
  downstream overlay checkout — that silently forks the contract and the next kernel
  sync clobbers or conflicts with it. Fix it in the kernel repo, then let it flow down.
- **Ambiguous foundation-domain captures default to kernel.** When a new rule is
  genuinely unclear which side it belongs on, but it concerns foundation's own pipeline
  machinery (board adapter, build/sweep, install/doctor, quality gates) rather than
  Travis's personal environment, route it to kernel — the cost of a kernel rule that
  turns out unused by a downstream adopter is low; the cost of an overlay rule that
  silently governs shared machinery is a hidden coupling the split is meant to remove.
- **Overlay may extend, never contradict.** The overlay file may add personal rules and
  elaborate on kernel rules with machine-specific detail, but it must never state
  something that conflicts with a kernel contract (e.g. a different branch/PR flow, a
  different required CI check name). A contradiction is a kernel-repo bug to fix
  upstream, not something to route around downstream.

## Live/Drain pairing

When adding or modifying a real-time extraction rule (e.g. decision capture, config-drift detection, feedback memory, session optimization tracking), also add the corresponding backstop in `~/.claude/commands/tidy.md` Step 3 **in the same change** and register the pair in a registry table. There are two: `tidy.md`'s own top-of-file table is the **single source of truth for KERNEL pairs** (generic enough that a stranger's kernel-only checkout needs them backstopped too); a composed/overlay checkout additionally carries `claude/live-drain-registry.overlay.md`, the **overlay extension table**, for pairs whose live half is a personal/vault-backed rule with no meaning in a standalone kernel checkout. Route a new pair by that test. The two halves of a pair (live + drain) are a single feature with two surfaces — never ship only one. `foundation/workflows/scripts/validate-live-drain.sh` parses the kernel table always, and unions in the overlay extension table when present, in CI (the `checks` gate) — it **fails the build if any pair, in either table, is half-present**, so a live rule shipped without its drain backstop (or vice versa) is caught mechanically, not by review. See [[Patterns/Live-Drain pairing]] for rationale and edge cases.

## Trust confirmed state

Don't spend a round-trip re-checking state you've already confirmed:
- No `git pull`/`git status` right after your *own* push or merge — the tree is current by construction.
- Trust a green `gh pr checks`/CI result (or a `--watch`/poll that already exited 0); only re-poll on a non-zero or `UNKNOWN`.
- A confirmed diagnosis explains its downstream symptoms — don't re-probe to "confirm" what you already established.
- Don't re-read a file you just wrote to "verify" it — the write tool already errored if it failed.

## Fetch ground truth before building

Probe current state before you mutate or build on it — stale assumptions cause the most expensive rework:
- Before branching or opening a PR: `git fetch` and check `git log origin/main..HEAD` for divergence, plus `gh pr list --head <branch>` for an existing PR — don't build on a stale checkout or re-create a PR that already exists.
- Before a file move/delete that a decision might govern, check the vault (or repo history) for why it's there.
- A board's auto-add (or any async automation) can lag — wait/poll before concluding it "didn't fire."

The branch half of this rule is now **mechanically backstopped**: the `git-stale-branch-guard.sh` PreToolUse hook (foundation #590, the hook #49 deferred) intercepts `git checkout -b` / `git switch -c` off a local default branch, fetches origin, and `ask`s — naming behind-by-N — when the local base is stale. It only fires on the genuinely-stale case (branching off `origin/<default>` or an up-to-date local base stays silent) and fails open, so it backs the habit without replacing it.

## Branch & PR policy

The build repos (foundation, stageFind, ssmobile, subsetwiki) share one branch/PR flow; this is **canonical** and their project `CLAUDE.md` files defer here rather than restate it. (A boardless/personal repo with no protected `main` is the exception — push freely there.) The kernel repo (`temperloop` — see § Kernel vs overlay routing rule) follows this same flow: it is a build repo like the others, not a special case.

`main` is **protected** — never push to it directly. Instead:

1. Branch `<type>/<slug>` — type ∈ `feat|fix|chore|refactor|docs|test`; slug kebab-case, ≤40 chars, descriptive. From a `/build` plan note the slug equals the item's `slug:` field.
2. Commit, then `git push -u origin <branch>`.
3. `gh pr create` — the body carries the verification surface (§ PR verification surface) and any `Closes #N` (§ Issue linkage).
4. Wait for the required **`checks`** status to go green. `checks` is the *contract*: every build repo names its required `.github/workflows/ci.yml` job `checks`, so "protected + green" means the same thing everywhere — but **what** `checks` runs differs per repo (see each project `CLAUDE.md`).
5. `gh pr merge --merge` — enqueues the PR in the repo's **merge queue**. It merges after clearing a *second* `checks` run, **not** immediately. **Omit `--delete-branch`** — the queue rejects it; head branches auto-delete via repo setting. The MERGE method preserves merge commits. (The `delete_branch_on_merge` repo setting is enabled and **confirmed honored by the merge queue** on all four build repos — F#551 — so this is the mechanism, not just an aspiration; the queue deletes the head branch on merge.) For the *local* side the repo setting never touches — merged local branches and a pre-setting backlog of stale remote heads — run `scripts/prune-merged-branches.sh` (dry-run by default; `--apply` to delete, `--remote` to also sweep merged remote heads) or `make prune-branches` from the foundation checkout. On the **mini this local prune is automatic** — `deploy-mini.sh` (the session-start hook) sweeps merged locals in every clean-on-main checkout each session start (F#653), so `make prune-branches` is the *off-mini* / on-demand lever, not the only trigger.

Branch-naming rationale: `[[Decisions/foundation - Branch naming convention]]`. Pre-convention branch names a repo grandfathers in are noted in that repo's own file.

## Issue linkage

Applies to **PR/issue workflows**: any time a PR resolves a GitHub issue. When it does, the PR body MUST carry a `Closes #N` (or `Fixes #N`) line so GitHub auto-links the PR and auto-closes the issue on merge. Omit it entirely for refactors, chores, or features with no pre-existing tracker — don't invent issue references.

Emit the keyword as **bare text on its own line** — `Closes #N`, never wrapped in backticks or a code span. GitHub silently ignores closing keywords inside inline code, so a backticked `` `Closes #N` `` merges the PR without closing the issue (the failure `/build` 3f guards against). The same prohibition covers commit messages merged to the default branch: a stray closing keyword in a *commit* auto-closes on merge too, so keep linkage out of commit messages and in the PR body alone (see `claude/commands/build.md` 3c/3f).

One PR can close **several** issues — but only when **each** carries its own bare keyword on its own line (`Closes #1` then `Closes #2`, never `Closes #1 and #2`, which closes only #1). This is useful for an **opportunistic same-PR fix** (a defect fixed alongside the planned work in the same PR) and a **root-cause-collapse atomic close** (a survivor's fix PR closing the survivor plus its absorbed symptoms together, so the cluster closes on one merge). In the plan pipeline this is the `also_closes:` field (`claude/plan-schema.md`): the primary issue rides `gh_issue:`, each additional one rides `also_closes:`, and `/build` (3f) emits one bare `Closes #M` line per entry.

This stays consistent with the rest of the pipeline. The plan-schema's optional `gh_issue:` field (`claude/plan-schema.md`) carries the issue number into a plan item; `/build` consumes it to inject exactly one bare `Closes #<gh_issue>` line into the PR body (3f), and items without `gh_issue:` emit no `Closes` section. Hand-authored PR bodies follow the same shape.

Bidirectional post-merge check: confirm the issue actually closed. Before merge, the PR body should show "Successfully merging this pull request may close these issues"; after merge, the issue's "Development" sidebar should show the PR and the issue should be **closed**. If an issue that should have closed is still open, the linkage was missed (usually a backticked or absent `Closes`) — fix the PR body or close the issue by hand, and treat it as a signal to check the generated-body path.

**Cross-repo closes.** A PR can auto-close an issue in **another** repo only via the explicit `owner/repo#N` form — e.g. `Closes <org>/stageFind#N` — emitted bare on its own line, never backticked, exactly like a same-repo `Closes`. A bare `Closes #N` is **same-repo only**: it never reaches across repos, so an issue tracked on the other board stays open if you use it. This is the caveat to state explicitly — a cross-repo close *requires* the fully-qualified `owner/repo#N` reference.

The motivating case is the foundation↔stageFind shared board tooling. The board scripts (`board.sh`, `claim`/`worklist`/`capture`/`reconcile`, etc.) are generated in **foundation** and deployed/synced into **stageFind**; when a foundation PR fixes shared tooling that is tracked by an issue on the *other* board, a `Closes <org>/stageFind#N` (or `Closes <org>/foundation#N`) line in that PR body auto-closes the cross-board issue on merge — removing a manual cross-board reconcile step that would otherwise be needed to mark the other board's item Done.

## Communication conventions

Guardrails so the operator never has to leave the conversation (or scroll far back) to understand what's being referred to. Born from a real board-numbering confusion (foundation#362).

- **Repo-qualify issue refs.** Whenever more than one repo is in play, write `stageFind#658` / `foundation#362` / `ssmobile#4` — never bare `#N`. Shorthand accepted in either direction: `S<N>` = stageFind#N, `F<N>` = foundation#N, `M<N>` = ssmobile#N, `W<N>` = subsetwiki#N, `K<N>` = temperloop#N. Boards are referenced by **name first**, logical number second: "the stageFind board (`--board 3`)".
- **Refs legend.** Any response that references issue/PR/epic numbers ends with a compact legend — one line per ref: qualified number → title (+ state when it matters) — so no number ever requires a GitHub lookup to decode.
- **Completion summary.** On completing a work item (fix merged, issue closed, batch level cleared), end with a short re-orientation block: what the item was, what changed, what's next. The reader may be returning cold.
- **Resume recap.** The first response after a session resume or a long gap opens with one line on the active item and where it stands, before answering the new message.
- **Capture terminology at source.** When a taxonomy/terminology confusion surfaces mid-session, fix the canonical glossary (this file, or the project `CLAUDE.md`) in that same session — a verbal clarification alone is how the same confusion recurs.

## GitHub Projects boards — always via the board.sh adapter

For ANY Projects-v2 board read or write, **reach for the adapter first** — never an ad-hoc `gh project …` or raw Projects GraphQL. The adapter caches across processes and keeps single-item ops off the expensive whole-board page, protecting the shared 5,000-pt/hr GraphQL budget; a raw query bypasses that and has drained it mid-session. (A PreToolUse guard, `board-adapter-guard.sh`, *prompts* on a direct query — but that's a backstop; defaulting to the adapter is what keeps it dormant.)

Source it — `workflows/scripts/board/lib/board.sh` in foundation, `scripts/lib/board.sh` in stageFind — then use:
- **one issue** (its item id / status / fields) → `board_resolve_item <board> <issue#>` — cheap, no whole-board scan; the default for touching a single issue.
- **whole board** → `board_resolve <board>` once, then reuse the resolved state for many items (don't re-resolve per item).
- **just the items** → `board_item_list <board>`.
- **writes** → `board_set_status` / `board_set_milestone` / `board_set_component` / `board_set_number` (resolve-by-name; they bust the cache).
- or a **board command**: `worklist` / `claim` / `release` / `reconcile` / `capture` / `milestone`.

**The board glossary** — three number spaces collide here; this table is canonical:

| Logical board (`--board N`, the only number spoken in prose) | Name | Repo | Org-project URL |
|---|---|---|---|
| **3** | stageFind build | `<org>/stageFind` | `github.com/orgs/<org>/projects/4` |
| **4** | foundation build | `<org>/foundation` | `github.com/orgs/<org>/projects/3` |
| **5** | ssmobile | `<org>/ssmobile` | `github.com/orgs/<org>/projects/5` |
| **6** | subsetwiki | `<org>/subsetwiki` | `github.com/orgs/<org>/projects/6` |
| **7** (issues-only, no Projects board) | temperloop | `<org>/temperloop` | — (issues-only backend; `fnd:`-labeled Issues, no Projects-v2 board — see `ISSUES-ONLY-BACKEND.md`) |

⚠️ The logical numbers and the org-project URL numbers are **swapped for 3 and 4** (a migration-order accident the adapter's `board_project_number()` absorbs). Always speak **logical** numbers; URL numbers appear only inside full URLs, never as standalone identifiers. Per-repo *issue* numbers are a third, unrelated space — qualify them per § Communication conventions. Board 7 registered via `boards.conf` rather than the built-in case map (foundation #808 — see `ISSUES-ONLY-BACKEND.md` § "The temperloop tracker"); an issues-only board needs no Projects board to have a logical number, it only needed the `repo` axis wired up. Still refer to it by the `K<N>` shorthand (§ Communication conventions) in prose about *issues*; `--board 7` is the adapter handle, used by scripts (e.g. `capture.sh --repo kernel`).

Raw `gh project` / `updateProjectV2Field` is only for **structural** ops the adapter doesn't cover (creating a field, adding/replacing single-select options) — and when you do edit options, pass every existing option WITH its `id` (see [[Mistakes/foundation - updateProjectV2Field replaces single-select options]]). **After any such structural edit, run `board_bust_structure [board]`** — the adapter caches board *structure* (project id, field/option schema) under a long TTL (`BOARD_STRUCTURE_TTL`, 24h, separate from the 90s item-state cache; this split is what stopped structure re-fetches from draining 56% of the GraphQL budget), so without an explicit bust the new schema may not be seen for up to a day (see [[Decisions/foundation - Board adapter structure/state cache split]]). See [[Decisions/foundation - Board adapter guard hook]].

## Task workflow (board-enabled projects)

This section governs **board-enabled projects** — those with a GitHub Projects-v2 worklist (currently stageFind = board 3, foundation = board 4). In a project with no board (personal/boardless work), none of it applies; skip it. Where these rules name a *script*, run it through the board adapter per the board.sh-adapter rule above — never a raw `gh project` call. The board itself is read/written only via that adapter; this section is about *when and why* you touch it, not *how*.

**The In-Progress gate.** On a board-enabled project, no substantive work happens in a session except under an item in **In Progress** — and "substantive" includes investigation and planning, not just code. About to do real work with no In-Progress item covering it? Stop and create or move one first. Everything that happens is tracked; nothing gets silently abandoned. (For *non-trivial* work this composes with the plan-first habit — but the gate applies to any substantive work, trivial or not, on a board-enabled project.)

**Claim first — before you investigate.** The board is a cross-session lock, so the claim is the *first* action when an item enters In Progress — the user names an item, or you pull a Ready one. Claim **before** reading the issue in depth, exploring code, or reading vault notes: investigation and planning are themselves the duplicate-able work the lock protects, so claiming after them reopens the race a second session can double-pull through. A wrongful claim is cheap to undo (park it back to Ready per "Park, don't abandon"); claim-then-verify beats verify-then-claim.

**WIP cap = 3 (per board).** At most three items In Progress at once on a given board — a deliberate bound on parallelism, not WIP-1. To take a fourth, first finish or park one.

**Session-start ritual.** On a board-enabled project, before any work, list the In-Progress set (via the adapter's `worklist`) and ask which to resume — don't pick for the user, and don't start new work until they answer.

**Park, don't abandon.** To set work aside or make room under the cap, MOVE the item out of In Progress (to Ready or Backlog) and add a one-line parking note: where it stands + the next concrete step. A tracked status change, never a silent drop. (There is no `Blocked` Status bucket — it was retired in #435; a genuine dependency block is a native `blocked_by` edge, and an open *question* is the `needs-clarification` label, not a status.)

**Capture at source + defect-vs-enhancement routing.** A thread that opens mid-work is never a bare aside. Part of the active item → add a checkbox to it. Separate → file it, then continue. Route by kind: a **defect** (something broken, a gap, a regression, untracked work that *should already exist*) → GitHub issue + board item (via the adapter's `capture`); an **enhancement or deferred design seam** (a future capability, a "consider later", a decided-but-unbuilt direction) → a vault `Decisions/` or `Context/` note (this is the live counterpart to the **Decision capture** rule above). When genuinely ambiguous, prefer the board — a Backlog item is cheap to close, a dropped defect is expensive to lose. **"Captured in a vault note" satisfies *rationale*, not *tracking*** — if the note names actionable work, it also needs a worklist item.

**Capture, don't ask.** When you notice a defect mid-work you are *not* fixing now, do **not** end the turn with "want me to file this?" and wait — that offer dies when the session ends, which is how bugs get dropped. File it immediately (adapter `capture`, with `--board 3|4` as appropriate) and mention you did. Filing is reversible; a silently dropped bug is not. (`/tidy` § Unfiled defects is the backstop.)

**Board hygiene is part of the gate.** The board is only a trustworthy parallelism substrate if it reflects reality. When an item merges or closes, the close→Done cascade (GH #340) moves its card to Done automatically — the merge's `Closes #N` (or an `gh issue close`) closes the issue, and the cascade does the board move — so a manual `board_set_status … Done` is a redundant backstop, not the primary mechanism; rely on the cascade and let `reconcile.sh` catch the rare card it misses. When you create an epic's sub-issues, add them to the board. A board that shows closed work as Ready/In-Progress can't be used to pick parallel work. If you find drift, fix it before pulling new work. (This composes with **Fetch ground truth before building** — probe the board's real state before relying on it.)

**Decompose epic-sized work up front.** For work that is epic-sized — **3+ parallelizable sub-units, OR more than one dependency level** — do a design-decomposition pass *before* building: an epic (GitHub issue + board item) plus contract-scoped sub-issues grouped into dependency levels, captured as a `Plans/` note via `/assess`. Below that threshold, a single board item is right — don't manufacture an epic for one change. The decomposition is what unlocks parallel, batch-resolvable work (`/build` runs a whole level at once).

**Decompose to the seam, not the implementation.** A sub-issue fixes its *contract* — what it **produces** (an interface, artifact, schema, or verdict), what it **consumes** (its deps), and its **acceptance check** — and says nothing about *how*. Contracts are what make issues both parallelizable (no coordination once the seam is fixed) and stale-resistant (an implementation learning changes the *how*, not the contract). A sub-issue body that starts prescribing implementation is the staleness smell — pull back to the seam.

Rationale: `[[Decisions/stageFind - Task workflow (board + WIP-3 gate)]]`, `[[Decisions/stageFind - Contract-based epic decomposition]]`, `[[Decisions/stageFind - Dropped-bug capture net]]`.

## Plan-first default

Default to **plan mode** before any non-trivial change. "Non-trivial" is broad: anything beyond a one-line fix, a typo, a comment, or a mechanical config tweak qualifies — new behavior, a multi-file edit, a new component, a schema touch, a refactor, a scorer/prompt/pipeline change. When in doubt, plan. (This is the plan-first habit the **Task workflow** section above composes with on board-enabled projects; here it applies generally, board or no board.)

This is a **strong default, not an absolute bar**: you may go straight to implementation only if you state up front — in the turn *before* editing — why the change is trivial enough to skip planning, and the user doesn't object. Silence is not consent to skip; the rebuttal has to be voiced and given a beat to land. Absent that explicit, un-objected rebuttal, enter plan mode, lay out the approach, and get approval before writing code.

**Why this exists.** The harness auto-classifier has caught implementation mistakes that planning would have surfaced first. That it caught them is the warning sign, not the safety net — it means our own controls were absent and we'd fallen back on a Claude built-in to backstop us. Built-in classifiers are opaque, can change without notice, and aren't ours to tune; leaning on them is leaning on luck. The plan-first default makes the control explicit and ours. If the auto-classifier ever fires on our work again, treat it as a process miss to investigate, not a catch to be grateful for.

Rationale: `[[Decisions/stageFind - Plan-first default for non-trivial changes]]`.

## PR verification surface

Every PR must ship its own verification surface in the PR body — a way for the reviewer to confirm correctness without grepping logs, decoding JSON, or running commands themselves. A PR that asks the reviewer to "run the script and see" or "check the output file" is incomplete. The verification surface is part of the deliverable, not an optional add-on.

What this looks like, by change type:

- **Script / behavior changes** (shell, board adapter, hooks, telemetry) — show the before/after of the observable behavior: the command's output before and after, the test that now passes, or the failure it now prevents. "Tests pass" alone is not a surface; show what the relevant test asserts.
- **Config / settings changes** (`settings.json`, permissions, dotfiles) — show the corrected value and the prior incorrect value side-by-side, plus what the change causes the harness to do differently. Don't make the reviewer diff two JSON blobs to find the one line that matters.
- **Doc / instruction changes** (`CLAUDE.md`, slash commands, skills, vault-facing rules) — quote the new or amended rule inline and name what it resolves or replaces. If it fixes a dangling reference or supersedes a prior rule, show the reference now resolving (the before/after of the pointer).
- **Refactors with no behavior change** — make an explicit "no behavior change" claim and show the diff or test that proves it (e.g. a shellcheck-clean run, a board-test pass, an idempotent `make install` re-run).

When in doubt about what counts as adequate, err toward more visibility. The cost of an extra paragraph is small; the cost of a reviewer skipping verification because friction was too high is unbounded.

## Subagent usage

Exit plan mode before spawning an execution subagent (a `Task` call with a `subagent_type` that writes code, commits, or otherwise mutates state). Subagents inherit the parent session's plan-mode system-reminder — "MUST NOT make any edits... supersedes any other instructions" — and will stop after planning rather than executing. Plan mode is fine for read-only subagents (`Explore`, `python-reviewer`, `architecture-reviewer`, `requirements-auditor`) since they don't need write access anyway.

This is documented Claude Code harness behavior, not a configurable knob. See [[Mistakes/foundation - Subagent harness stops + plan-mode re-activation]] for the root-cause analysis and the transcript evidence.

**Legible agent-gate degradation.** When an agent-gated step's reviewer is unavailable — per the capability-probe predicate ([[Decisions/foundation - Project capability probes]]: a review subagent is available iff the project declares it in `CLAUDE.md § Subagents` or `.claude/agents/`) — emit a one-line `skipped — <agent> unavailable` notice rather than silently no-opping. A silent skip is the foundation #164 failure: the gate looks like it passed when it never ran. `/triage` Step 3 and `/assess` Step 3 already do this; the PR-review / Decisions-lock advisory and `build` 3e must too.
