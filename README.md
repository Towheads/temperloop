# TemperLoop

TemperLoop makes Claude Code work the way a good engineering team works:
agents pull tracked issues, build in isolated branches, and land every change
as a reviewed, CI-gated pull request — safe to run in parallel, even
unattended.

AI coding agents are fast but unreliable teammates. Left alone they drift,
duplicate each other's work, and produce changes nobody reviewed — and the
usual defense, babysitting every diff, doesn't scale past one session.
Engineering orgs solved this class of problem long ago with process: issue
tracking, code review, protected branches, merge queues. TemperLoop is that
process, packaged as scripts and Claude Code slash commands, for a developer
or small team who doesn't have a platform team to build it.

**What you get:**

1. **Every agent change lands as a reviewed pull request** against a
   protected `main` — no direct pushes, no unauditable diffs. "Reviewed"
   means the gates you wire in: required CI checks, the repo's read-only
   review agents, and your own read (solo, you are the human reviewer).
   Either way an agent's work leaves the same trail a careful human's
   would.
2. **Parallel agents that can't collide.** Each worker runs in an isolated
   git worktree; the issue tracker doubles as a cross-session lock so two
   sessions never silently pull the same work; and guard hooks mechanically
   block the classic agent mistakes — writing outside its own worktree,
   branching off a stale base — instead of relying on vigilance.
3. **The backlog runs itself.** Slash commands carry an issue from triage
   through a dependency-ordered plan to a merged PR — one issue at a time,
   a whole dependency level in parallel, or unattended on a timer, with a
   hard line between what runs on its own and what always waits for you.
4. **It works on a free personal repo.** Tracking runs on plain GitHub
   Issues (no Projects board, no org), and a managed merge queue replicates
   GitHub's paid-tier native queue where it isn't available. The full
   ladder, zero paid GitHub features.
5. **You can read everything it does.** Plain shell, Python, and markdown
   contract files, run locally or in your own CI — no hosted service, no
   dashboard, no account beyond GitHub. Runs spend your own Claude budget;
   [`docs/cost-and-autonomy.md`](docs/cost-and-autonomy.md) states the real
   figures before you run anything.

TemperLoop is not itself an AI model — it orchestrates Claude Code, which
you bring and pay for. And it's deliberately not for everyone. Not a fit: a
chat-first, no-process workflow (prompt in, diff out — there is no mode
that skips branches, PRs, and review; the process is the product); a team
that wants a hosted service rather than readable scripts; a non-GitHub
tracker (Jira, Linear, GitLab); or anyone unwilling to adopt branch/PR
discipline — protected `main` is load-bearing here, not optional. Fit
check in [`docs/who-its-for.md`](docs/who-its-for.md); the shareable
one-page version of this whole story is [`docs/pitch.md`](docs/pitch.md).

---

## 1. Prerequisites

The `temperloop` CLI shells out to two tools it doesn't vendor:

- **[Claude Code](https://docs.claude.com/en/docs/claude-code/quickstart)**
  (`claude` on `PATH`) — drives the actual triage/build/sweep work.
- **[GitHub CLI](https://cli.github.com)** (`gh`), authenticated
  (`gh auth login`) — every subcommand that talks to GitHub needs it.

If either is missing, `temperloop` prints exactly what's missing and how to
fix it — never a bare stack trace. `git` and a POSIX `sh` (for the
installer) are assumed present.

**Before you run anything:**
[`docs/cost-and-autonomy.md`](docs/cost-and-autonomy.md) covers what each
step spends of your own Claude budget and exactly what an unattended run
may do without asking. Worth two minutes first.

## 2. Quickstart: testbed → first epic → promote → adopt

You evaluate TemperLoop on a throwaway copy of your own repo. The on-ramp
is `temperloop testbed`: it duplicates a real repo of yours
into a detached private copy, you run the full pipeline there, keep the
work worth keeping via `/promote`, and delete the copy afterwards. Nothing
in the testbed can reach your real repo by accident — it's a separate
repository with no fork relationship, no shared issues, and no upstream to
open a PR against. (Deliberately a duplicate, not a fork: a fork of a
public repo is forcibly public, and it carries an upstream that PR tooling
will offer as a base.)

```sh
# 1. Install — inspect first (recommended), then run
curl -fsSL https://raw.githubusercontent.com/Towheads/temperloop/main/bin/bootstrap.sh -o temperloop-bootstrap.sh
less temperloop-bootstrap.sh
sh temperloop-bootstrap.sh
# Clones the latest release tag into ~/.local/share/temperloop and symlinks
# ~/.local/bin/temperloop — no shell-rc edits, no sudo. Re-running never
# silently pulls: it delegates to `temperloop update`, which shows the
# CHANGELOG delta (including BREAKING sections) and asks before moving.
# (Running this across several unrelated codebases — e.g. one consultant,
# many client repos — and want isolated installs instead of one shared
# machine install? Set TEMPERLOOP_HOME/TEMPERLOOP_BIN_DIR before
# bootstrapping; see bin/README.md § Install.)

# 2. Build the testbed — from a checkout of the repo you want to evaluate
#    on. Creates the private duplicate, mirror-pushes the full history, and
#    carries your open issues across (GitHub itself never copies issues),
#    so the pipeline has something real to work on.
temperloop testbed --dry-run   # preview: zero writes of any kind
temperloop testbed             # for real, once you like the preview

# 3. Adopt, inside the testbed clone (the run's handoff text walks you
#    through this). Bootstraps `.temperloop/config` via a reviewable,
#    tree-only PR, then offers the pre-designed FIRST EPIC.
git clone https://github.com/you/your-repo-testbed.git
cd your-repo-testbed
temperloop init

# 4. Run the first epic through the real pipeline — this is the demo.
#    ⚠️ The billable surface starts HERE: this step runs in your own Claude
#    session with no tool-enforced cost cap — see docs/cost-and-autonomy.md.
claude
> /assess --epic <N>
> /build
```

Nothing is created before you consent: every pre-flight check is a read,
and each mutating step names exactly what it's about to do first.

**Why the first epic is the demo.** It isn't a scripted walkthrough — it's
the pipeline doing real work on your code. The first epic
([ADR 0010](docs/adr/0010-onboarding-as-first-executed-epic.md)) sets up
the three guardrails that make agent work safe to merge — review criteria
defining "good" in this repo, a protected `main`, and CI that has to
pass — and that's genuine work with real dependency levels. Watching it run
shows you the whole machine (claim → worktree → PR → CI → merge gate) on a
change you wanted anyway. Once it merges, point `/triage` at the issues the
testbed carried across and watch it group a real backlog.

**Keep the work, then tear the testbed down:**

```sh
# In the testbed clone: land the testbed's commits in your real repo as a
# branch + reviewable PR. The destination is always named, never inferred.
claude
> /promote --to you/your-repo --dry-run
> /promote --to you/your-repo

# Then reclaim the testbed (deletion needs a one-time scope grant):
gh auth refresh -s delete_repo
temperloop testbed --teardown
```

**To adopt for real**, run `temperloop init` in your actual repo — it
behaves identically, and this time the PRs are ones you keep. (Starting a
brand-new project with no code yet? Skip the testbed and run `init`
directly — the testbed exists to evaluate against code you already care
about.) `temperloop eject` undoes `init`'s repo-tree changes if you change
your mind — but a branch-protection setting the first epic enabled is a
GitHub repo setting, not a tree change, and stays until you turn it off
yourself; [`bin/README.md`](bin/README.md) § Uninstall maps every removal
scope.

The CLI carries the rest of the lifecycle: `install` (machine-wide
surface, verified by `doctor.sh` — note it includes a machine-wide `gh`
logging wrapper, disclosed in [`bin/README.md`](bin/README.md) § the
call-logger shim), `update` (consent-gated), `uninstall`,
`configure` / `config` (settings), `report` (local metrics), and `feedback`
(message the maintainers). Run `temperloop help` for the live list; full
flag reference and the safety contract behind each step (what "zero-write"
and "tree-only" actually guarantee) are in [`bin/README.md`](bin/README.md).

## 3. Day-to-day commands

Once adopted, day-to-day work happens in Claude Code slash commands
(deployed from `claude/commands/`) plus a few `make` targets.
[`docs/using-the-pipeline.md`](docs/using-the-pipeline.md) is the operating
guide; the map:

| Command | What it does |
| --- | --- |
| `/next` | Advisory "what do I do now" — reads the board and plan notes, recommends the next command. Never mutates anything. |
| `/triage` | Front door for **discovered** work: sweeps the backlog, culls, groups, and materialises survivors as epics. |
| `/workshop` | Front door for **invented** work (an idea born in conversation): a structured design conversation, ratified into an epic. |
| `/assess --epic N` | Decomposes an epic into a dependency-ordered plan for your approval. |
| `/build` | Executes an approved plan: a worktree-isolated worker, PR, and CI per item; clean disjoint PRs merge as they go green, everything else batches into one merge gate per dependency level. |
| `/sweep` | Drains ungrouped single issues: asks all clarifying questions up front, then fixes each through the same per-item machinery. |
| `/fix` | Drives ONE named target — an issue number or a free-text description — to merged and closed. Can adopt an existing open PR. |
| `/promote` | Carries work out of a testbed into the real repo it was built from, as a branch plus a PR. |
| `/tidy` | Nightly, unattended: drains session learnings into durable notes and parks anything needing human judgment. |
| `/check-in` | Daily review: renders the telemetry brief, disposes what `/tidy` parked, sets priorities. |
| `/pipeline-drive`, `/pipeline-drive-merge` | Headless executors for the unattended scheduler ([`docs/features/pipeline-driver.md`](docs/features/pipeline-driver.md)): the first is structurally unable to merge; the second is a separate opt-in that merges only through `/build`'s own gated path. |

Board commands (`worklist`, `claim <n>`, `capture "<title>"`, `release`,
`reconcile` — source in `workflows/scripts/board/`) are how anything, human
or agent, reads and writes the issue tracker; the tracker is the
cross-session lock. `make quality-gates` runs the exact static gate set
CI's required `checks` job runs; `make help` lists the rest.

A set of read-only review agents (`docs-reviewer`,
`architecture-reviewer`, persona lenses, and more, in `claude/agents/`)
review work at the pipeline's gates. A fresh clone ships them as source;
deploy them with `bash workflows/scripts/install/project-agents.sh`
(idempotent, `--dry-run` to preview) — until then, gated steps print
`skipped — <agent> unavailable` rather than silently passing.

## 4. Repo layout

```
bin/            temperloop CLI — entrypoint, subcommands/, bootstrap installer (§ 2)
claude/         Claude Code config: slash commands (claude/commands/), review
                agents (claude/agents/), guard hooks (claude/hooks/), the
                plan-note contract (claude/plan-schema.md)
docs/           hand-maintained docs (§ 5): pitch, principles, architecture,
                feature pages (docs/features/), ADRs (docs/adr/), failure modes
workflows/scripts/
  board/        board adapter (worklist/claim/capture/reconcile/… + lib/board.sh)
                — plain GitHub Issues, see board/ISSUES-ONLY-BACKEND.md
  build/        deterministic build machinery (worktree, ci-poll, pr, gate, …)
  install/      install surface — doctor.sh, project-agents.sh, manifest tooling
  proposal/     the tree-only proposal-PR generator `temperloop init` rides
  probe/        the read-only repo-conventions probe
  docs/         the docs-site generator (`make docs`)
  lib/          shared libraries + adapter contracts (*.contract.md)
scripts/quality-gates.sh   the ONE static gate set — CI and local dev both run it
Makefile        the in-checkout command surface (test/gate/docs targets)
AGENTS.md       operating instructions for any coding agent working in this repo
CHANGELOG.md    Keep-a-Changelog history — BREAKING entries drive `temperloop update`
llms.txt        machine-readable project index (llmstxt.org convention)
```

## 5. The docs

Start with the four orientation pages, then go as deep as you need:

- [`docs/pitch.md`](docs/pitch.md) — the whole story on one page; the page
  to share.
- [`docs/who-its-for.md`](docs/who-its-for.md) — the fit check: who this is
  designed for, and who it deliberately isn't.
- [`docs/principles.md`](docs/principles.md) — the thesis and the fifteen
  principles, each pinned to the in-repo mechanism that embodies it.
- [`docs/architecture.md`](docs/architecture.md) — how the pieces fit: one
  issue's trip from backlog to merged PR, the guard map, the telemetry.

Operating and reference pages:

- [`docs/using-the-pipeline.md`](docs/using-the-pipeline.md) — the
  day-to-day operating guide.
- [`docs/cost-and-autonomy.md`](docs/cost-and-autonomy.md) — what it costs
  and what it does on its own. Read before running anything.
- [`docs/token-spend.md`](docs/token-spend.md) — how it keeps model spend
  down, and how to see where tokens went.
- [`docs/cognitive-load.md`](docs/cognitive-load.md) — what it keeps out of
  your head.
- [`docs/self-learning-loop.md`](docs/self-learning-loop.md) — how it
  learns from its own operation.
- [`docs/managed-merge-queue.md`](docs/managed-merge-queue.md) — the free-repo
  merge queue in full (§ 6 below is the summary).
- [`docs/config-precedence.md`](docs/config-precedence.md) — how every
  setting resolves (CLI flag → env → machine → repo-local → repo → default).
- [`docs/features/`](docs/features/) — one reference page per shipped
  feature (problem, how it works, integration, resource impact, telemetry).
- [`docs/adr/`](docs/adr/) — the architecture decision records, starting at
  [ADR-0000](docs/adr/0000-adr-process.md).
- [`docs/failure-modes/`](docs/failure-modes/) — real engineering failures
  this project hit, each ending in the mechanical guard it produced:
  [worktree write-isolation leak](docs/failure-modes/01-worktree-write-isolation-leak.md),
  [REST budget exhaustion](docs/failure-modes/02-rest-budget-exhaustion.md),
  [premature status-close on async merge](docs/failure-modes/03-premature-status-close-on-async-merge.md),
  [patch-API silent corruption](docs/failure-modes/04-patch-api-silent-corruption.md).

`make docs` additionally renders a self-contained static site (command
reference, quality-gate list, plan-note contract) straight from the source
files, so it can't drift from what the code does. The site is a local build
artifact — generate it with `make docs` and open
`workflows/scripts/docs/_site/`.

## 6. Merge queue on a free repo

GitHub's native merge queue is only provisionable on an org-owned repo on a
paid plan. TemperLoop doesn't require it: `workflows/scripts/build/gate.sh`
probes whether a native queue is armed and otherwise falls back to a
**managed merge queue** that replicates the same semantics serially, per
PR — update the branch, re-poll CI against the new head, merge, then
confirm the merge actually landed before anything downstream treats it as
done. A PR that goes red after the update is ejected and parked without
stopping the rest of the queue.

The managed queue runs only while a gate is executing — it's not a standing
server — so plain GitHub branch protection (require PRs, require the same
status checks; free on personal repos) is the only-path enforcement that
makes "merge around the queue" impossible rather than merely unlikely. If
you adopted through the first epic (§ 2), that epic already set branch
protection up; this section is the manual path and the mechanics behind
it.
Full mechanics: [`docs/managed-merge-queue.md`](docs/managed-merge-queue.md).

## 7. About

TemperLoop grew out of one developer's attempt to stop babysitting AI
agents — the origin story, the thesis behind it, and the kinds of
collaborators the project is looking for are in
[`docs/about.md`](docs/about.md). The CLI and repo were called `foundation`
during early development; the old name still surfaces in older issues and
URLs, and invoking `foundation` now fails loudly with a pointer to
`temperloop` (renamed at v0.15.0, compat shim removed at v0.19.0).

## License

Apache License 2.0 — see [`LICENSE`](LICENSE). See
[`SECURITY.md`](SECURITY.md) for the vulnerability-reporting policy and
[`NOTICE`](NOTICE) for attribution.

---

*Written by claude-fable-5 on 2026-08-13.*
