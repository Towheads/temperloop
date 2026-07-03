# Foundation

The operational layer for Travis's work environment — the single source of truth for
dotfiles, Claude Code configuration, the bug→PR pipeline skills, the board toolkit, and
the scripts that run things. **Foundation holds the code and config; the Obsidian vault
(`~/dev/mind`) holds the written context and decisions.** This README is the operator
getting-started guide; `CLAUDE.md` holds the deep rules Claude follows.

---

## 1. What foundation is

Foundation is a toolkit, not an app. It does three jobs:

1. **Provisions the environment** — symlinks dotfiles and Claude config (`~/.claude/`) so
   every machine (your Mac, the Mac mini) runs the same hooks, permissions, slash commands,
   and status line. `make install` is idempotent; run it anytime to re-sync.
2. **Runs the bug→PR pipeline** — a set of slash commands (`/triage`, `/assess`, `/build`,
   `/sweep`, …) that take a board of raw issues and drive them to merged PRs, plus a board
   toolkit (`claim`, `worklist`, `capture`, …) that keeps a GitHub Projects-v2 board as the
   cross-session work-tracking substrate.
3. **Is the reusable substrate for other repos** — the board toolkit and build hooks are
   authored here and **synced into consuming repos** (stageFind, ssmobile, subsetwiki) as real files, so
   each repo stands alone with its own CI while foundation stays the one place you edit.

```
env/          dotfiles — symlinked to ~ on install
claude/       Claude Code config — symlinked to ~/.claude/ on install
  CLAUDE.kernel.md   global instructions: shippable kernel contracts (generic process rules)
  CLAUDE.overlay.md  global instructions: personal/org/machine-specific rules
                     (composed together into CLAUDE.md, reconciled, not symlinked — see below)
  settings.json hooks, permissions, status line, model (reconciled, not symlinked)
  commands/     the pipeline skills (assess, build, sweep, triage, drain-mind, next,
                plan-morning, plan-evening, init) — SOURCE OF TRUTH
  workflows/    saved Workflow scripts (build-level.mjs)
  hooks/        SessionStart (drain) + SessionEnd (transcript log) + guards
  plan-schema.md  plan-note contract cited by /assess + /build
workflows/scripts/
  board/        board toolkit (claim/release/worklist/reconcile/capture/milestone + lib/board.sh)
  build/        build deterministic-spine toolkit (worktree, ci-poll, pr, gate, …)
  …             telemetry parsers, session archiver, validators
meta/           append-only telemetry (data/raw/) + session archive (sessions/archive/)
dashboard/      self-contained generated index.html
scripts/quality-gates.sh   the ONE static gate set — CI, build, and local dev all run it
Makefile        install / sync / test / telemetry targets
```

---

## 2. First-time install

From a fresh checkout at `~/dev/foundation`:

```sh
make install          # dotfiles + Claude config + board commands + gh logger (idempotent)
make install-board    # symlink claim/release/worklist/reconcile/capture/milestone onto PATH
```

`make install` runs `install-env` (dotfiles → `~`), `install-claude` (config → `~/.claude/`),
`install-board` (board commands → `~/.local/bin`), and `install-gh-logger` (a `gh` shim that
logs API calls). It is **idempotent** — safe to re-run; it skips anything already linked.

Optional, run on demand (not part of `make install` because they prompt for sudo / touch a
remote host):

```sh
make install-obsidian-mcp   # trust the Obsidian REST cert + register both MCP servers (sudo)
make install-stagefind      # iTerm "stageFind" integrated window + push bootstrap to a remote deploy host
make deploy-mini            # bring every board-toolkit checkout on THIS machine current
make help                   # full target list with one-line descriptions
```

> **Never edit `~/.claude/` directly.** Those files are symlinks back to `claude/`. Edit
> `claude/<file>` and the change propagates on the next `make install-claude` everywhere.
> The one exception is `settings.json`, which is *reconciled* (your local `model` is kept
> machine-local) — see `CLAUDE.md` for why.

---

## 3. Command map

### Pipeline skills (slash commands, in `claude/commands/`)

The bug→PR pipeline. Each is a slash command you invoke in a Claude Code session.

| Command | What it does |
| --- | --- |
| `/triage` | Front door. Sweeps a board's **Backlog**, runs the decision tree (cull → root-cause collapse → group-by-meaning → value/priority), materialises survivors as board epics (parent issue + native sub-issues), and flips grouped survivors Backlog→Ready. |
| `/assess --epic N` | Decomposes a triaged epic's sub-issues into a structured **plan note** in `Plans/` (one sub-issue → one plan item, with dependency levels). Writes `status: draft` for human review. |
| `/build` | Executes an **approved** plan note: per item, isolates a git worktree, spawns an agent, pushes, opens a PR, monitors CI, and parks until a batched merge gate at the end of each dependency level. Mirrors each item onto the board (claim → In Progress → Done on merge). |
| `/sweep` | Drains a board's **Ready singletons** (issues triage left ungrouped) sequentially, reusing `build`'s per-issue workflow. The singleton peer to `/build`. |
| `/next` | Advisory "what do I do now" — reads the board + `Plans/` notes and recommends the single next command. Never mutates anything. |
| `/drain-mind` | Processes session stubs in `Sessions/_inbox/`: extracts learnings to the vault + memory, generates Things tasks, archives transcripts to `meta/sessions/archive/`. |
| `/plan-morning`, `/plan-evening` | Daily planning + shutdown rituals. |
| `/init` | Initialise a `CLAUDE.md` + a vault context placeholder for a new project. |

**The pipeline flow:**

```
Backlog issues ──/triage──▶ Ready epics ──/assess──▶ Plans/ note (draft)
                       │                                    │
                       └──▶ Ready singletons ──/sweep──▶    │ (human flips status: approved)
                                                            ▼
                                                         /build ──▶ PRs ──▶ merged
```

### Board toolkit (bare commands on PATH after `make install-board`)

All Projects-v2 reads/writes go through these — **never** ad-hoc `gh project …` or raw
Projects GraphQL (that bypasses the shared GraphQL-budget cache; a PreToolUse guard prompts
if you try). Each takes `--board N` (default 3 = stageFind; 4 = foundation; 5 = ssmobile; 6 = subsetwiki).

| Command | What it does |
| --- | --- |
| `worklist --board N` | Show the board's In-Progress / Ready set. The session-start ritual. |
| `claim <issue#> --board N` | Move an issue to In Progress (the cross-session lock). Claim *first*, before investigating. |
| `release <issue#> --board N` | Park an item back out of In Progress. |
| `capture "<title>" --board N` | File a new issue + board item (Backlog) — the dropped-bug net. |
| `reconcile --board N` | Fix board drift (close→Done cascade misses). |
| `milestone activate "<phase>" --board N` | Flip the active-milestone intake marker. |

For scripting, source the adapter and call its functions directly:
`workflows/scripts/board/lib/board.sh` → `board_resolve_item <board> <issue#>` (one issue,
cheap), `board_resolve <board>` (whole board, cached), `board_set_status` / `board_set_milestone`.

### Make targets (the ones you'll reach for)

| Target | What it does |
| --- | --- |
| `make install` | Re-sync the whole environment (idempotent). |
| `make quality-gates` | Run the full static gate set — **exactly what CI runs**. Run before pushing. |
| `make test-board` / `make test-build` | Board / build toolkit test suites (zero network). |
| `make sync-stagefind-board` / `make sync-ssmobile-board` / `make sync-subsetwiki-board` | Push the board toolkit into a consuming repo as real files. |
| `make telemetry-all` | Refresh telemetry data + rebuild `dashboard/index.html`. |
| `make deploy-mini` | Bring every board-toolkit checkout on this machine current. |
| `make help` | Everything else. |

---

## 4. Linking foundation to a NEW repo

This is the onboarding runbook: make a new repo (`<org>/<repo>`) a first-class consumer of
foundation's board toolkit and build pipeline. The board is **logical board N** in all prose
and `--board N` flags; the GitHub org-project URL number is separate (and, for boards 3/4,
swapped — the adapter absorbs it).

### Step 1 — Create and link the GitHub Projects-v2 board

Create (or reuse) a Projects-v2 board owned by your `<org>` and link it to the repo so
native reverse-lookup and auto-add work:

- **Status** single-select with options `Backlog`, `Ready`, `In Progress`, `Done` (the built-in
  close→Done / reopen→In-Progress automations key on Status; there is no `Blocked` option — it
  was retired in #435, a dependency block is a native `blocked_by` edge).
- A **Component** single-select for the subsystem axis (optional but recommended).
- A **`Host/Session`** TEXT field — the claim toolkit (`claim.sh` →
  `board_stamp BOARD_FIELD_HOSTSESSION='Host/Session'`) hard-fails with *"could not resolve board
  fields (Status / Host/Session)"* without it. Every board (3/4/5) carries it; a board provisioned
  without it breaks `/build`'s claim step (subsetwiki#29). Create with
  `gh project field-create <org-project-num> --owner <org> --name 'Host/Session' --data-type TEXT`,
  then `board_bust_structure <N>`.
- Link the project to the repo (`linkProjectV2ToRepository`).
- Set the repo's **"Auto-add to project" workflow filter to `is:issue`** — PR cards are noise
  and orphan at Status `(none)` otherwise.
- **Enable the built-in Projects-v2 workflows** (Project → ⋯ → Workflows): set **"Item closed"**
  *and* **"Pull request merged"** → *Set Status to Done*, and **"Item reopened"** → *Set Status to
  In Progress*, then toggle each **On**. These are **not** enabled by default on a fresh board, and
  there is no API/GraphQL to set them — it is a one-time web-UI step. Skip it and closed issues
  strand In Progress, forcing a manual `board_set_status … Done` on every close (subsetwiki#37; the
  board-6 analogue of foundation #281/#259).

> Board structure is the sanctioned raw-GraphQL exception (the adapter doesn't wrap
> `field-create` / `updateProjectV2Field`). When editing single-select options, **pass every
> existing option WITH its `id`** or you orphan every item's value. (If you're moving an
> existing user-owned board into an org rather than creating a fresh one, `copyProjectV2` +
> `linkProjectV2ToRepository` is the same raw-GraphQL exception path — see the source repo's
> own migration tooling for a worked example, not shipped here since it's a one-time,
> already-run operation.)

### Step 2 — Register the board in the adapter

Add **one line each** to the three per-board registries in
`workflows/scripts/board/lib/board.sh`:

```sh
board_repo()            # N) echo "<org>/<repo>" ;;
board_owner()           # N) echo "<org>" ;;
board_project_number()  # N) echo <org-project-number> ;;   # default: identity (echo "$1")
```

That's the entire "what board N is" surface — every `--board N` caller resolves through it.

### Step 3 — Add the Makefile sync wrappers

In the `Makefile`, set the repo path var and add per-repo wrappers (mirroring stageFind):

```make
<REPO>_REPO ?= $(HOME)/dev/<repo>

sync-<repo>-board:
	@$(MAKE) --no-print-directory sync-board TARGET_REPO="$(<REPO>_REPO)" SYNC_LABEL="make sync-<repo>-board"
sync-<repo>-hooks:
	@$(MAKE) --no-print-directory sync-hooks TARGET_REPO="$(<REPO>_REPO)" SYNC_LABEL="make sync-<repo>-hooks"
```

Onboarding a new repo is one wrapper, not a copy of the generic `sync-board` / `sync-hooks`
recipe.

### Step 4 — Sync the toolkit and the build guard hook into the repo

```sh
make sync-<repo>-board    # copies board scripts → <repo>/scripts/ as real, banner-stamped files
make sync-<repo>-hooks    # copies the build write-jail guard → <repo>/.claude/hooks/
```

These are **real files**, not symlinks — a standalone repo's CI checks out only itself and
can't follow a cross-repo symlink into foundation. A `scripts/board-sync-manifest` pins the
foundation commit SHA so the consumer can drift-check.

### Step 5 — Register the guard hook in the repo's settings

In `<repo>/.claude/settings.json`, register the synced hook as a **PreToolUse** entry on
`Edit|Write|MultiEdit` → `.claude/hooks/build-worktree-guard.sh`. (The sync copies the file;
the one-time JSON merge is left to the repo.) The hook is inert until `BUILD_WORKTREE_GUARD`
is set, so it changes nothing for ordinary sessions.

### Step 6 — Add CI and protect main

Add `<repo>/.github/workflows/ci.yml` with a single job **named `checks`** (the protection
contract foundation and stageFind both honour — "protected + green" means the same in every
repo). Protect `main` requiring `checks`. Grow the job's contents to fit the repo (shellcheck
for shell repos, pytest/mypy/playwright for app repos).

### Step 7 — Document the board and the repo's rules

- Add a row to the **board glossary** table in `claude/CLAUDE.kernel.md` § GitHub Projects boards
  (logical number, name, repo, org-project URL).
- Add a `<repo>/CLAUDE.md` carrying the **Task workflow** rules (In-Progress gate, claim-first,
  WIP-3 cap, capture-don't-ask) so work on the new board follows the same discipline.

### Step 8 — Verify

```sh
worklist --board N          # the board resolves and shows its items
make test-board             # the suite still passes
make sync-<repo>-board      # idempotent re-run is clean
claim <some-issue> --board N # the claim step resolves Host/Session (Step 1) — no hard-fail
```

Then **verify the close→Done cascade** (Step 1's workflow toggles): close a throwaway issue on the
board and confirm its card auto-moves to `Done` without a manual `board_set_status`. If it strands
In Progress, the "Item closed → Done" workflow is still off — re-do that toggle.

---

## 5. Daily rhythm and conventions

- **Board-enabled work runs under an In-Progress item.** Start a session with
  `worklist --board N`, claim before investigating, cap at 3 items In Progress, and **park
  (move out + one-line note), don't abandon**. Capture stray defects immediately
  (`capture …`) rather than asking — a dropped bug is expensive, a Backlog item is cheap.
- **Plan before non-trivial changes.** Anything beyond a one-line fix gets a plan first.
- **`main` is protected.** Branch `<type>/<slug>`, push, `gh pr create`, wait for `checks`
  green, then `gh pr merge --merge` to enqueue in the merge queue (omit `--delete-branch` — the
  queue rejects it; head branches auto-delete via repo setting). Every PR ships its own
  verification surface in the body. A PR that resolves a GitHub issue carries a bare `Closes #N` line.
- **Local gate = CI gate.** `make quality-gates` runs *exactly* what CI's `checks` job runs.
- **Knowledge lives in the vault.** Decisions, patterns, pitfalls, and context go to
  `~/dev/mind` (via the Obsidian MCP), not into this repo. Code and config go here.

---

## 6. Where to go deeper

- `CLAUDE.md` (this repo) — the full operating rules: board adapter, milestone intake,
  sync architecture, CI policy, the `claude/`-symlink discipline.
- `claude/CLAUDE.kernel.md` + `claude/CLAUDE.overlay.md` — the global instructions, split into
  shippable kernel contracts (board glossary, task workflow, communication conventions, branch/PR
  policy) and the personal overlay (Obsidian vault, session-log hooks, decision capture). Composed
  by `workflows/scripts/install-claude-md.sh` into `~/.claude/CLAUDE.md` on `make install-claude`.
- `claude/plan-schema.md` — the plan-note contract that `/assess` writes and `/build` consumes.
- `make help` — every Makefile target with a one-line description.
- `~/dev/mind/Index.md` — the index of long-lived context and decision notes.
