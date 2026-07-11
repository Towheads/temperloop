# AGENTS.md

Instructions for any AI coding agent (Claude Code, or another agent that
reads this file per the [AGENTS.md](https://agents.md) convention) working
in this repository. If you are a Claude Code session specifically, also read
`CLAUDE.md` (repo root) and `claude/CLAUDE.kernel.md`, which this file
defers to for the full process contracts — this file is the cross-agent
orientation layer, not a replacement for either.

## What this repo is

TemperLoop is a dev-process kernel for Claude Code–driven development: a
board adapter that turns a GitHub Projects board (or a plain issues-only
tracker) into a cross-session work queue, a build/sweep pipeline of Claude
Code slash commands that drive an issue from triage to a reviewed PR, and
the install/quality-gate tooling that gets both running in a repo you
already have. It is a toolkit — scripts, slash commands, and contract files
you read — not a service you depend on. Full description: [`README.md`](README.md).

This repo builds and ships that kernel; it also *uses* its own pipeline on
itself (an agent working here is both developing and dogfooding the tools
described below).

## How an agent administers this repo

### The CLI vs. `make` — two different surfaces, don't confuse them

`bin/temperloop` (subcommands in `bin/subcommands/`) is the **pre-checkout
newcomer surface** — `try` (zero-write probe + shadow triage), `try --demo`
(one real tick against a disposable demo repo), `init` (propose adopting
this repo's conventions in another repo via a reviewable PR),
`baseline-snapshot` / `report` (before/after value tracking), `eject`
(manifest-driven clean removal). It is not a second front door onto *this*
checkout's day-to-day work — don't add a Makefile-target wrapper here.

**In-checkout operations stay on `make`.** Run `make help` for the full
target list with descriptions. The ones an agent needs most:

- `make quality-gates` — the full static gate set, identical to what CI's
  `checks` job runs (`scripts/quality-gates.sh`). Run this before opening a
  PR.
- `make test-board` / `make test-build` — the board adapter / build-spine
  toolkit test suites (zero network).
- `make docs` — renders the generated docs site to
  `workflows/scripts/docs/_site/` (gitignored; a build artifact).
- `make prune-branches` — sweep merged local branches (dry-run by default;
  `--apply` to delete).

### Board-adapter rules

Every GitHub Projects-v2 (or issues-only) board read or write goes through
the adapter — **never** an ad-hoc `gh project …` call or raw Projects
GraphQL. Source `workflows/scripts/board/lib/board.sh`, or use the bare
commands: `worklist` / `claim` / `release` / `reconcile` / `capture` /
`milestone` (all in `workflows/scripts/board/`), each taking `--board N`.

This matters mechanically, not just stylistically: every board read against
GitHub's Projects-v2 API draws on a shared **5,000-points/hr GraphQL
budget**. The adapter caches board reads across processes and keeps
single-item operations (`board_resolve_item`) off the expensive whole-board
page fetch (`board_resolve`) — a raw query bypasses both protections and can
drain the budget mid-session. Raw `gh project` / `updateProjectV2Field` is
reserved for structural operations the adapter doesn't cover (creating a
field, adding/replacing single-select options); after any such structural
edit, bust the adapter's structure cache before relying on the new schema
again. See `workflows/scripts/board/lib/board.sh`'s own header and
`docs/failure-modes/02-graphql-budget-exhaustion.md` for a worked example of
what happens when a different API's polling loop is mistakenly routed onto
this same budget.

This repo's own tracker is an **issues-only** backend (no Projects-v2 board
provisioned) — see `workflows/scripts/board/ISSUES-ONLY-BACKEND.md` for the
label/status/claim-lock/close→Done-cascade contract that backend
implements. The adapter functions above work the same way against either
backend; which one a given board uses is a `boards.conf` detail, not
something calling code branches on.

### Quality gates

`scripts/quality-gates.sh` is the single source of truth for this repo's
static gate set — the board / build / install / hooks test suites, the
Live/Drain and PR-body-lint registries, the kernel-manifest / personal-token
/ gitleaks scrub checks, and a whole-tree shellcheck. CI's one required job
(`checks`, `.github/workflows/ci.yml`) runs exactly this script, so "green
locally" and "green in CI" mean the same thing. Run `scripts/quality-gates.sh
--list` to see every gate as a `[kernel] <command>` line, or `make
quality-gates` to run them all.

### Where the contract docs live

- `claude/CLAUDE.kernel.md` — the full process-contract doc: branch/PR
  policy, working-tree ownership, board-adapter usage, task workflow, plan-
  first default, PR verification surface, and more. The canonical reference
  for *how* work happens in this repo and its sibling build repos.
- `claude/plan-schema.md` — the plan-note contract `/assess` writes and
  `/build` consumes.
- `workflows/scripts/lib/knowledge_store.contract.md` — the knowledge
  (document-I/O) adapter interface, for anyone wiring in a new notes
  backend.
- `workflows/scripts/board/ISSUES-ONLY-BACKEND.md` — the tracker adapter
  interface, documented alongside its reference `issues-only` backend.
- `docs/managed-merge-queue.md` — the merge-backend seam (native vs.
  managed queue) that lets the build/sweep ladder run end-to-end even on a
  repo with no native merge queue available.
- `docs/config-precedence.md` — the six-rung config precedence ladder
  (CLI flag > env var > machine conf > untracked repo-local conf > tracked
  repo conf > kernel built-in default) every tunable in this repo resolves
  through.
- `docs/CONTRIBUTING.md` — how to contribute a failure-mode chapter or a new
  knowledge/tracker adapter.
- `bin/README.md` — the CLI's own front page: install, prerequisites, the
  `try` → `try --demo` → `init` quickstart ladder in full.

Once `make docs` has been run, all of the above (plus the command reference
and quality-gate list) are also browsable as a generated static site at
`workflows/scripts/docs/_site/`.

## Safety rails

- **Adapter-only board access.** See § Board-adapter rules above — never a
  raw `gh project` call or hand-rolled Projects GraphQL query for anything
  the adapter already covers.
- **`main` is protected.** Never push to it directly. Branch
  `<type>/<slug>` (`type` ∈ `feat|fix|chore|refactor|docs|test`), commit,
  push, open a PR. Wait for the required `checks` status to go green before
  merging.
- **Merge-queue flow, not a direct merge.** `gh pr merge --merge` enqueues
  the PR in the repo's merge queue rather than merging immediately — it
  lands only after a second `checks` run against the queue's rebased head.
  Never pass `--delete-branch` (the queue rejects it; head branches
  auto-delete via the repo's own setting instead). On a repo with no native
  merge queue provisioned (a free personal/non-org repo), `gate.sh
  managed-merge` replicates the same re-validate-then-merge sequencing by
  hand — see `docs/managed-merge-queue.md`. Either path only closes tracking
  state once the merge is *confirmed landed* (`state=="MERGED"`), never at
  the moment the merge call returns.
- **Worktree lanes.** A session mutates only the working tree it was
  launched in, plus any linked git worktree it created — never another
  checkout's `HEAD` directly. Cross-repo or isolated work happens in its own
  `git worktree add <path> -b <branch>`, worked under `<path>`, never in a
  foreign repo's canonical checkout. This is mechanically backstopped for
  Claude Code sessions by the `write-lane-guard.sh` PreToolUse hook
  (`claude/hooks/`), which intercepts a state-mutating call into a foreign
  checkout and asks before proceeding.
