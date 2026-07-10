# TemperLoop

**A dev-process kernel for Claude Code–driven development.** TemperLoop is the
process layer that sits between a raw GitHub issue and a merged pull request: a
board adapter that turns a GitHub Projects (or issues-only) tracker into a
cross-session work queue, a build/sweep pipeline of Claude Code slash commands
that drive an issue from triage to a reviewed PR, and the install/quality-gate
tooling that gets both running in a repo you already have. It is a toolkit, not
an app — everything here is a script, a slash command, or a contract file you
read, not a service you depend on.

---

## 1. What TemperLoop is

Three pieces, meant to be adopted independently or together:

1. **The board adapter** (`workflows/scripts/board/`) — `claim` / `release` /
   `worklist` / `reconcile` / `capture` / `milestone`, plus `lib/board.sh` for
   scripting. Turns a GitHub Projects-v2 board (or, with zero board
   provisioning at all, a plain issues-only tracker — see
   `workflows/scripts/board/ISSUES-ONLY-BACKEND.md`) into a cross-session lock
   and work queue, so multiple sessions (or a human and an agent) never
   silently duplicate the same issue.
2. **The build/sweep pipeline** (`claude/commands/`) — Claude Code slash
   commands: `/triage` sweeps a board's backlog and decomposes survivors into
   epics; `/assess` turns an epic into a dependency-ordered plan note;
   `/build` executes an approved plan (isolate a worktree, spawn an agent,
   open a PR, watch CI, batch-merge); `/sweep` drains ungrouped singleton
   issues the same way. `/next` tells you what to run; `/tidy` closes
   the loop on session learnings (nightly, unattended) and `/check-in`
   reviews what it parked.
3. **Install and quality-gate tooling** — a single `temperloop` CLI (below)
   for the pre-checkout adoption path (try it, demo it, opt in), plus
   `scripts/quality-gates.sh`, the one static gate set a repo's CI and its
   contributors both run, so "green CI" and "green locally" mean the same
   thing.

Every failure that shaped one of these pieces is written up as a chapter in
the docs site — see § 6.

---

## 2. Prerequisites

The `temperloop` CLI shells out to two tools it doesn't vendor:

- **[Claude Code](https://docs.claude.com/en/docs/claude-code/quickstart)**
  (`claude` on `PATH`) — drives the actual triage/build/sweep work.
- **[GitHub CLI](https://cli.github.com)** (`gh`), authenticated
  (`gh auth login`) — every subcommand that talks to GitHub needs it.

If either is missing, `temperloop` prints exactly what's missing and how to
fix it — never a bare stack trace. `git` and a POSIX `sh` (for the installer)
are assumed present.

---

## 3. Quickstart: try → try --demo → init

The `temperloop` CLI (`bin/`) is the on-ramp — a single POSIX entrypoint for
someone who has never touched this repo's Makefile, board, or build pipeline.
Install it, then walk the ladder: taste it read-only, see it mutate something
disposable, then opt your own repo in.

```sh
# 1. Install — inspect first (recommended), then run
curl -fsSL https://raw.githubusercontent.com/Towheads/temperloop/main/bin/bootstrap.sh -o temperloop-bootstrap.sh
less temperloop-bootstrap.sh
sh temperloop-bootstrap.sh
# (or the one-liner once you trust the source:
#  curl -fsSL https://raw.githubusercontent.com/Towheads/temperloop/main/bin/bootstrap.sh | sh)

# 2. Try it — zero-config, zero-write: a read-only repo-conventions probe
#    plus a real (but --tools "", structurally zero-write) shadow-triage
#    pass over your repo's own open issues, with a cost estimate printed
#    before anything runs.
cd your-repo
temperloop try

# 3. See it work — the ONE mutating exception: ticks a real, disposable
#    demo repo through one safe-tier issue -> PR pass (never a merge),
#    behind a spend-guard confirmation.
temperloop try --demo

# 4. Opt in — propose adopting the tracker/quality-gate conventions in
#    YOUR repo via a reviewable, tree-only PR (nothing lands without your
#    review; --dry-run previews with zero writes at all).
temperloop init
```

`foundation <subcommand>` still works everywhere above — this CLI's binary
was renamed from `foundation` to `temperloop` at public launch (see § 8), and
`bin/foundation` is a thin compat shim that execs `temperloop`, so an
existing script or alias never breaks.

Full flag reference, exit codes, and the safety contract behind each step
(what "zero-write" and "tree-only" actually guarantee) live in
[`bin/README.md`](bin/README.md) — that's the CLI's own front page.

Once you've adopted the board/build pipeline in your repo, day-to-day work
stays on `make` (`make quality-gates`, `make test-board`, …) — the CLI above
is the newcomer surface, not a second front door onto a checkout you already
have.

---

## 4. Repo layout

```
bin/            temperloop CLI — entrypoint, subcommands/, bootstrap installer (§ 3)
claude/         Claude Code config: the pipeline slash commands (claude/commands/),
                the kernel half of CLAUDE.md (claude/CLAUDE.kernel.md), the
                plan-note contract (claude/plan-schema.md)
workflows/scripts/
  board/        board adapter (claim/release/worklist/reconcile/capture/milestone
                + lib/board.sh) — Projects-v2 or issues-only, see
                board/ISSUES-ONLY-BACKEND.md
  build/        build deterministic-spine toolkit (worktree, ci-poll, pr, gate, …)
  demo/         the disposable demo-repo seeder `temperloop try --demo` ticks
  proposal/     the tree-only proposal-PR generator `temperloop init` rides
  probe/        the read-only repo-conventions probe both of the above share
  docs/         the docs-site generator (`make docs`) — renders § 6 below from
                the source files themselves, never hand-maintained
scripts/quality-gates.sh   the ONE static gate set — CI and local dev both run it
Makefile        the in-checkout command surface (test/gate/docs targets)
```

---

## 5. Command map

### Pipeline skills (slash commands, in `claude/commands/`)

| Command | What it does |
| --- | --- |
| `/triage` | Sweeps a board's Backlog, runs cull → root-cause collapse → group-by-meaning → value/priority, materialises survivors as board epics. |
| `/assess --epic N` | Decomposes a triaged epic into a dependency-ordered plan note in `Plans/`. |
| `/build` | Executes an approved plan: isolates a worktree per item, spawns an agent, opens a PR, monitors CI, batches the merge gate. |
| `/sweep` | Drains a board's Ready singletons (issues triage left ungrouped), reusing `/build`'s per-issue workflow. |
| `/next` | Advisory "what do I do now" — reads the board + plan notes, recommends the next command. Never mutates anything. |
| `/tidy` | Nightly unattended: processes the session-stub backlog (extracts learnings, archives transcripts, snapshots the vault) and parks anything needing human judgment on durable review surfaces. |
| `/check-in` | Daily human review: renders the telemetry brief, disposes the surfaces `/tidy` parked overnight, and sets the `/next` priorities per project. |
| `/init` | Bootstraps a new project's `CLAUDE.md` + context. |

### Board adapter (bare commands, source in `workflows/scripts/board/`)

All Projects-v2 reads/writes go through these — never ad-hoc `gh project …` or
raw Projects GraphQL. Each takes `--board N`.

| Command | What it does |
| --- | --- |
| `worklist --board N` | Show the board's In-Progress / Ready set. |
| `claim <issue#> --board N` | Move an issue to In Progress (the cross-session lock). |
| `release <issue#> --board N` | Park an item back out of In Progress. |
| `capture "<title>" --board N` | File a new issue + board item. |
| `reconcile --board N` | Fix board drift. |

### Make targets

| Target | What it does |
| --- | --- |
| `make quality-gates` | The full static gate set — exactly what CI's `checks` job runs. |
| `make test-board` / `make test-build` | Board / build toolkit test suites (zero network). |
| `make docs` | Render the generated docs site (§ 6) to `workflows/scripts/docs/_site/`. |
| `make help` | Every target with a one-line description. |

---

## 6. Docs site

`make docs` renders a self-contained static site straight from this repo's own
source files — the command reference is generated from `claude/commands/*.md`,
the quality-gate list from `scripts/quality-gates.sh --list`, and so on, so the
site can't drift from what the code actually does. It's gitignored (a build
artifact, not checked-in content) — run `make docs` to generate it locally,
then open (or serve, for root-relative links) `workflows/scripts/docs/_site/`:

- [CLI getting-started](workflows/scripts/docs/_site/cli/getting-started.html) — this repo's `bin/README.md`, rendered
- [Command reference](workflows/scripts/docs/_site/commands/reference.html) — every kernel slash command
- [Plan-note contract](workflows/scripts/docs/_site/plan-schema.html) — the schema `/assess` writes and `/build` consumes
- [Quality gates](workflows/scripts/docs/_site/quality-gates.html) — the full static gate list
- [Adapter contracts](workflows/scripts/docs/_site/adapter-contracts/knowledge_store.html) — the knowledge-store adapter interface
- Failure-mode chapters — real engineering failures this project hit, each ending in the mechanical guard it produced:
  [worktree write-isolation leak](workflows/scripts/docs/_site/failure-modes/01-worktree-write-isolation-leak.html),
  [GraphQL budget exhaustion](workflows/scripts/docs/_site/failure-modes/02-graphql-budget-exhaustion.html),
  [premature status-close on async merge](workflows/scripts/docs/_site/failure-modes/03-premature-status-close-on-async-merge.html),
  [patch-API silent corruption](workflows/scripts/docs/_site/failure-modes/04-patch-api-silent-corruption.html)

Publishing this site (so the links above resolve over HTTP instead of a local
build) is separate, not-yet-built launch work — until then, `make docs` then
serve `workflows/scripts/docs/_site/` locally (e.g.
`python3 -m http.server -d workflows/scripts/docs/_site`).

Two standalone docs, hand-maintained rather than generated, live directly
under `docs/`: [`docs/managed-merge-queue.md`](docs/managed-merge-queue.md)
(§ 9 below) and [`docs/config-precedence.md`](docs/config-precedence.md) —
the six-rung precedence ladder (CLI flag > env var > machine conf > untracked
repo-local conf > tracked repo conf > kernel built-in default) every config
knob in this repo resolves through, and how `build.config.sh` implements it.

---

## 7. Contributing

See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) for how to contribute a
failure-mode chapter to the docs site above. Broader contribution guidance
(adapter contributions, community surface) is on its way as part of this
project's public launch.

## 8. About the name

This CLI and its checkout were called `foundation` (and, before public
launch, `foundation-kernel`) during early development; both names still
surface in older issues, commits, and URLs. TemperLoop is the ratified public
name going forward — see `claude/CLAUDE.kernel.md`'s history for how this
repo's own kernel/overlay split works if you're extracting a similar process
layer out of your own personal automation.

## 9. Merge backend: the whole ladder on a free repo

GitHub's native merge queue — what a strict-mode `/build` or `/sweep` merge
gate would otherwise queue onto via `--auto` — is only provisionable on an
**org-owned repo on a paid plan**. That used to be a wall: on a free
personal repo (no org, no paid plan), the merge-gated ladder simply had
nowhere to land a merge. `workflows/scripts/build/gate.sh` closes the gap
with a merge-backend seam, so the full triage → assess → build/sweep →
merged-PR ladder runs end-to-end on a free personal repo too:

- **`gate.sh backend <owner>/<repo>`** selects **NATIVE** (native queue,
  preferred wherever it's actually armed) or **MANAGED** (no native queue
  available). `auto` (the default) probes the repo's branch ruleset for a
  `merge_queue` rule and fails safe to MANAGED if the probe itself fails;
  `BUILD_MERGE_BACKEND=native|managed` (`build.config.sh`) short-circuits
  the probe as an explicit override / test seam.
- **`gate.sh managed-merge <owner>/<repo> <pr> [--strict|--non-strict]`**
  replicates the native queue's semantics serially, per PR, on a repo with
  none: update the branch, re-poll CI against the *new* head SHA, merge,
  then confirm `state=="MERGED"` before anything downstream treats it as
  landed. A PR that goes red after the update is `EJECTED` — parked for
  escalation — without stopping the rest of the queue.

**This is not a standing server** — nothing enforces the managed queue
between gate runs, so between ticks a human (or another tool) can merge
straight past it. Enable plain GitHub branch protection (require PRs,
require the same status checks) on the repo as the only-path enforcement —
it's free on public and personal-account repos, no org or paid plan
required, and it's what makes "merge around the managed queue" actually
impossible rather than merely unlikely.

Both the native and managed paths confirm a *landed* merge
(`state=="MERGED"`, not just "the merge command didn't error") before the
orchestrator closes anything — see
[`docs/failure-modes/03-premature-status-close-on-async-merge.md`](docs/failure-modes/03-premature-status-close-on-async-merge.md).
Resuming a parked/ejected item across sessions rides the plan note's status
sentinels plus a fresh read of the PR's live state, never a label — the
full mechanics are in `claude/commands/build.md`.

Full backend-selection algorithm, the `managed-merge` command reference,
and the branch-protection recommendation in detail:
[`docs/managed-merge-queue.md`](docs/managed-merge-queue.md).

## License

Apache License 2.0 — see [`LICENSE`](LICENSE). See [`SECURITY.md`](SECURITY.md)
for the vulnerability-reporting policy and [`NOTICE`](NOTICE) for attribution.
