# TemperLoop

**A dev-process kernel for Claude Code–driven development.** TemperLoop turns
a GitHub issue tracker into a work queue that Claude Code sessions drive from
raw issue to merged, CI-green pull request. It is a toolkit, not an app —
everything here is a script, a slash command, or a contract file you read,
not a service you depend on.

---

## 1. What TemperLoop is

Engineering orgs scale with process — issue tracking, contract-scoped work,
code review, protected branches, merge queues, WIP caps. TemperLoop applies
that same machinery to agent-driven work, instead of assuming a human
supplies the discipline by hand. It is three pieces, adoptable independently
or together:

1. **The board adapter** (`workflows/scripts/board/`) — turns your GitHub
   issue tracker into a cross-session lock and work queue (`claim` /
   `worklist` / `capture` / …), so multiple sessions — or a human and an
   agent — never silently duplicate the same issue. **Issues-only is the
   default**: plain GitHub Issues on a free account — a repo and
   `gh auth login`, no org, no Projects board, no paid plan. A Projects-v2
   board is fully supported for a repo that already has one; see
   [`workflows/scripts/board/ISSUES-ONLY-BACKEND.md`](workflows/scripts/board/ISSUES-ONLY-BACKEND.md)
   for both backends.
2. **The build/sweep pipeline** (`claude/commands/`) — Claude Code slash
   commands that carry an issue from backlog to merged PR: `/triage` groups
   the backlog into epics, `/assess` decomposes an epic into a
   dependency-ordered plan, `/build` executes the plan (worktree-isolated
   workers, PRs, CI, a batched merge gate). `/sweep` drains ungrouped
   singleton issues, `/fix` drives one named target end to end, and
   `/workshop` designs invented work into the same pipeline. Full command
   map in § 5.
3. **Install and quality-gate tooling** — the `temperloop` CLI (§ 3) for the
   pre-checkout adoption path (try it, demo it, opt in), plus
   `scripts/quality-gates.sh`, the one static gate set a repo's CI and its
   contributors both run, so "green CI" and "green locally" mean the same
   thing.

To go deeper: [Guiding principles](docs/principles.md) is the thesis this
rests on, [Architecture overview](docs/architecture.md) is how the pieces
fit together end to end, [Who this is for](docs/who-its-for.md) is the
reader every doc and gate here is written against, and
[the one-page pitch](docs/pitch.md) is the whole story on a single page.
Every failure that shaped one of these pieces is written up as a
failure-mode chapter in the docs site — see § 6.

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

**Before step 1: what this costs, and what it will do on its own.**
[`docs/cost-and-autonomy.md`](docs/cost-and-autonomy.md) covers real spend
figures per tier (including whether a budget cap is on by default), and
exactly what an unattended run may do without asking versus what always
blocks for you — worth two minutes before you run anything below.

```sh
# 1. Install — inspect first (recommended), then run
curl -fsSL https://raw.githubusercontent.com/Towheads/temperloop/main/bin/bootstrap.sh -o temperloop-bootstrap.sh
less temperloop-bootstrap.sh
sh temperloop-bootstrap.sh
# (or the one-liner once you trust the source:
#  curl -fsSL https://raw.githubusercontent.com/Towheads/temperloop/main/bin/bootstrap.sh | sh)
# Clones the latest release tag into ~/.local/share/temperloop and symlinks
# ~/.local/bin/temperloop — no shell-rc edits, no sudo. Re-running never
# silently pulls: it delegates to `temperloop update`, which shows the
# CHANGELOG delta (including BREAKING sections) and asks before moving.

# 2. Try it — zero-config, zero-write: a read-only repo-conventions probe
#    plus a real (but structurally zero-write) shadow-triage pass over your
#    repo's own open issues, with a cost estimate printed before anything
#    runs.
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

The ladder is the on-ramp; the CLI carries the rest of the adoption
lifecycle too: `temperloop install` wires the machine-wide surface (and
prints the `doctor.sh` command that verifies exactly what landed),
`update` moves an existing install forward with consent, `eject` undoes
`init` in a target repo, `uninstall` removes the machine-surface install
from its manifest, and `feedback` / `report` send a message to the
maintainers / render your own local baseline metrics. Subcommands are
discovered files — run `temperloop help` for the live list.

`foundation <subcommand>` still works everywhere above — the CLI was renamed
from `foundation` to `temperloop` at public launch (v0.15.0, see § 8), and
`bin/foundation` is a thin compat shim that execs `temperloop`. The shim and
the other legacy `foundation` names are scheduled for removal in v0.17.0.

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
                the review-agent definitions (claude/agents/), the kernel half of
                CLAUDE.md (claude/CLAUDE.kernel.md), the plan-note contract
                (claude/plan-schema.md)
docs/           hand-maintained docs (§ 6): architecture, principles, feature docs
                (docs/features/), ADRs (docs/adr/), failure-mode chapters
workflows/scripts/
  board/        board adapter (worklist/claim/release/capture/reconcile/milestone
                + lib/board.sh) — issues-only or Projects-v2, see
                board/ISSUES-ONLY-BACKEND.md
  build/        build deterministic-spine toolkit (worktree, ci-poll, pr, gate, …)
  install/      install surface — doctor.sh (machine-link verify),
                project-agents.sh (review-agent deploy), install-claude-md.sh
  demo/         the disposable demo-repo seeder `temperloop try --demo` ticks
  proposal/     the tree-only proposal-PR generator `temperloop init` rides
  probe/        the read-only repo-conventions probe both of the above share
  docs/         the docs-site generator (`make docs`) — renders § 6 below from
                the source files themselves, never hand-maintained
  lib/          shared script libraries + adapter contracts (*.contract.md)
scripts/quality-gates.sh   the ONE static gate set — CI and local dev both run it
Makefile        the in-checkout command surface (test/gate/docs targets)
AGENTS.md       cross-agent operating instructions for any coding agent in this repo
CHANGELOG.md    Keep-a-Changelog history — BREAKING entries drive `temperloop update`
VERSIONING.md   version-bump policy: version by contract surface, not by code
llms.txt        machine-readable project index (llmstxt.org convention)
```

---

## 5. Command map

### Pipeline skills (slash commands, in `claude/commands/`)

| Command | What it does |
| --- | --- |
| `/triage` | Front door for **discovered** work: sweeps a board's Backlog, runs cull → root-cause collapse → group-by-meaning → value/priority, materialises survivors as board epics. |
| `/workshop` | Second front door, for **invented** work (an idea born in conversation): a structured design conversation against the coverage template, ratified and materialised as a board epic with a `## Contract`. Operator-present only. |
| `/assess --epic N` | Decomposes a triaged epic into a dependency-ordered plan note in `Plans/`. |
| `/build` | Executes an approved plan: isolates a worktree per item, spawns an agent, opens a PR, monitors CI, batches the merge gate per dependency level. |
| `/sweep` | Drains a board's Ready singletons (issues triage left ungrouped): batches all clarifying questions up front, then fixes each through `/build`'s per-issue workflow. |
| `/fix` | Drives ONE named target — an issue number or a free-text description — from wherever it stands to merged + closed. The single-item peer to `/build` and `/sweep`; can also adopt an existing open PR. |
| `/next` | Advisory "what do I do now" — reads the board + plan notes, recommends the next command. Never mutates anything. |
| `/tidy` | Nightly unattended: processes the session-stub backlog (extracts learnings, archives transcripts, snapshots the vault) and parks anything needing human judgment on durable review surfaces. |
| `/check-in` | Daily human review: renders the telemetry brief, disposes the surfaces `/tidy` parked overnight, and sets the `/next` priorities per project. |
| `/funnel-drive`, `/funnel-drive-merge` | Headless (`claude -p`) executors of the autonomous funnel driver — the unattended scheduler that runs the triage→build pipeline on a timer ([`docs/features/funnel-driver.md`](docs/features/funnel-driver.md)). The first runs the safe, structurally no-merge tier of a tick; the second (a separate opt-in) drives code items through `/build --unattended`, merging only via build's own gated path. |
| `/init` | Bootstraps a new project's `CLAUDE.md` + context. |

### Review agents (definitions in `claude/agents/`)

The pipeline skills above capability-probe a set of read-only review lenses
(`architecture-reviewer`, `requirements-auditor`, `workflow-reviewer`,
`docs-reviewer`, plus persona lenses) before spawning them — a lens runs only
if the project declares it in `CLAUDE.md § Subagents` or has it under a
project-scoped `.claude/agents/`, and otherwise degrades to a legible
`skipped — <agent> unavailable` line. A fresh clone ships these as source
under `claude/agents/` but has no live `.claude/`, so nothing is discoverable
until you deploy them:

```sh
bash workflows/scripts/install/project-agents.sh   # --dry-run to preview
```

This project-scoped install path wires `claude/agents/*` and
`claude/commands/*` into a live `.claude/agents/` + `.claude/commands/`
(symlinks by default, `--copy` for detached copies) so the capability probe
resolves. It is idempotent, never touches `~`, and never clobbers a
pre-existing non-managed file. See `docs/features/review-agents.md` §
Installation.

### Board adapter (bare commands, source in `workflows/scripts/board/`)

All board reads/writes go through these — never ad-hoc `gh project …` or raw
Projects GraphQL. Each takes `--board N`.

| Command | What it does |
| --- | --- |
| `worklist --board N` | Show the board's In-Progress set, with its host/session claim stamps. |
| `claim <issue#> --board N` | Move an issue to In Progress (the cross-session lock). |
| `release <issue#> --board N` | Park an item back out of In Progress. |
| `capture "<title>" --board N` | File a new issue + board item. |
| `reconcile --board N` | Fix board drift. |
| `milestone <verb> …` | Flip a release phase's machine-owned active bit, so every Backlog item deferred to that phase re-enters `/triage`'s next sweep at once. |
| `pr-enqueue --title … --body …` | Create a PR and enqueue it into the merge queue in one invocation, confirming the queued state. |

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
- [Feature docs](docs/features/) — one page per shipped feature (problem,
  how it works, integration, resource impact, telemetry), enforced
  complete by `workflows/scripts/validate-feature-docs.sh`; also rendered
  onto the generated site under `features/`. `docs/features/telemetry.md`
  is a good worked example of the five-section shape.
- [ADRs](docs/adr/) — the architecture decision record corpus, starting
  with [ADR-0000](docs/adr/0000-adr-process.md) (the MADR-lite process the
  rest of the corpus follows); also rendered onto the generated site under
  `adr/`.
- Failure-mode chapters — real engineering failures this project hit, each ending in the mechanical guard it produced:
  [worktree write-isolation leak](workflows/scripts/docs/_site/failure-modes/01-worktree-write-isolation-leak.html),
  [GraphQL budget exhaustion](workflows/scripts/docs/_site/failure-modes/02-graphql-budget-exhaustion.html),
  [premature status-close on async merge](workflows/scripts/docs/_site/failure-modes/03-premature-status-close-on-async-merge.html),
  [patch-API silent corruption](workflows/scripts/docs/_site/failure-modes/04-patch-api-silent-corruption.html)

The publish path exists but is parked: `.github/workflows/docs-pages.yml`
deploys the generated site to GitHub Pages on every push to `main`, gated
off behind the `DOCS_PAGES_ENABLED` repo variable until the repo is public
and Pages is enabled. Until then, `make docs` and serve
`workflows/scripts/docs/_site/` locally (e.g.
`python3 -m http.server -d workflows/scripts/docs/_site`).

The rest of `docs/` is hand-maintained rather than generated. Beyond the
orientation docs § 1 links (principles, architecture, who-it's-for, pitch)
and [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) (§ 7):

- [`docs/managed-merge-queue.md`](docs/managed-merge-queue.md) — the
  merge-backend seam § 9 summarises.
- [`docs/config-precedence.md`](docs/config-precedence.md) — the six-rung
  precedence ladder (CLI flag > env var > machine conf > untracked
  repo-local conf > tracked repo conf > kernel built-in default) every
  config knob in this repo resolves through, and how `build.config.sh`
  implements it.
- [`docs/cost-and-autonomy.md`](docs/cost-and-autonomy.md) — what running
  it costs and what it does on its own (the pre-quickstart read, § 3).
- [`docs/token-spend.md`](docs/token-spend.md) — how TemperLoop tracks
  and manages token spend.
- [`docs/cognitive-load.md`](docs/cognitive-load.md) — what TemperLoop
  keeps out of the operator's head.
- [`docs/self-learning-loop.md`](docs/self-learning-loop.md) — how
  TemperLoop learns from its own operation.

---

## 7. Contributing

See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) for how to ship a new
feature's doc (the manifest-claim → five-section-doc flow the quality
gates enforce), contribute a failure-mode chapter, or add a
knowledge-store/tracker adapter. Broader contribution guidance (community
surface) is on its way as part of this project's public launch.

## 8. About the name

This CLI and its checkout were called `foundation` (and, before public
launch, `foundation-kernel`) during early development; both names still
surface in older issues, commits, and URLs. TemperLoop is the ratified
public name going forward — the CLI renamed at v0.15.0, with the legacy
`foundation` names (including the `bin/foundation` compat shim) scheduled
for removal in v0.17.0; see the v0.15.0 CHANGELOG `BREAKING` entry for the
migration note. See `claude/CLAUDE.kernel.md`'s history for how this repo's
own kernel/overlay split works if you're extracting a similar process layer
out of your own personal automation.

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
