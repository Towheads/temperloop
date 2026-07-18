---
title: Guiding principles
---

# Guiding principles

This page states the thesis TemperLoop is built on and the fifteen principles
that follow from it — each one pinned to the in-repo mechanism that embodies
it, so the claim is falsifiable, not aspirational. Every path below exists in
this repo today; open it and check (temperloop#135).

This page is **dual-use**, the same way `docs/who-its-for.md` is for the
persona agents: it is the stranger-facing thesis README and ADR-0001 point
to, and it is also the **charter-derivation source** a principle-referencing
lens — `/workshop`'s premise gate and its red-team lens — cites back to by
name, so a design ratified against "principle 13" or "principle 14" resolves
to an actual, checkable section here rather than a lens inventing its own
parallel list.

## The thesis

To scale AI-driven development, manage agent work with the same machinery
that already scales medium-to-large engineering organizations: issue
tracking, chunked contract-scoped work, code and architectural review,
protected branches, merge queues, WIP caps. An agent session is a fast,
tireless, occasionally-wrong contributor — the organizational structure that
keeps a large human team coherent (a backlog, a review gate, a lock on
in-flight work) is exactly what keeps a fleet of agent sessions coherent
too, for the same reason it works for humans: it doesn't depend on any one
contributor being infallible.

**Claimed axes** — what this buys, and how to tell if it's working:

- **Cheaper** — in agent tokens *and* in human cognitive load. A worker that
  self-verifies against a checklist burns fewer round-trips than one a human
  babysits line by line; a human reviewing a batched merge-gate summary
  spends less attention than one reading every commit live.
- **Aligned** — expected outcome matches delivered outcome, because the
  contract (an issue's acceptance criteria, a plan item's `acceptance:`
  block) is written and reviewed *before* the work starts, not inferred
  after.
- **Maintainable** — the result stays changeable, deployable, and scalable,
  because review and gates run on every change, not just the ones someone
  remembered to double-check.
- **Parallel throughput** — independent contract-scoped units run
  concurrently instead of serially through one attention stream.
- **Auditable / recoverable** — every claim, review, and merge leaves a
  trail (a board card, a PR, an emitted telemetry record) that survives the
  session that produced it.
- **Bounded blast radius** — a failure (a wrong edit, a runaway loop, a bad
  merge) is contained to the smallest scope that could have caused it, not
  free to spread across a shared checkout or an unreviewed `main`.

## The fifteen principles

### 1. Manage agents like an org, not like a chat

A GitHub Projects board (or an issues-only tracker, for a repo with no
Projects provisioning) is a **cross-session lock**, not a status display.
Claiming an item — marking it In Progress and stamping the owning
session — is the first action before investigation even starts, because
investigation itself is duplicate-able work the lock is meant to prevent.
On the autonomous lane, the funnel's drive-concurrency governor
(`FUNNEL_DRIVE_CONCURRENCY`) bounds how many drives a tick launches; the
human WIP-cap governance rule was retired (temperloop#162) once it proved to
double a mechanical governor as a cross-session bound the claim-first lock
already provides per item.

- Claim-first mechanics: `workflows/scripts/board/claim.sh`
- The claim-first rule, in prose: `claude/CLAUDE.kernel.md`
  §§ "The In-Progress gate" and "Claim first — before you investigate"

### 2. Decompose to the seam, not the implementation

An epic-sized unit of work is split into contract-scoped sub-issues — what
each one **produces**, what it **consumes**, and its **acceptance
check** — never into an implementation outline. A contract stays
parallelizable (no coordination needed once the seam is fixed) and
stale-resistant (an implementation learning changes the *how*, not the
contract).

- The rule verbatim, by this name: `claude/CLAUDE.kernel.md` § "Decompose to
  the seam, not the implementation"
- The schema it produces: `claude/plan-schema.md` (`acceptance:` blocks,
  `depends-on` edges)

### 3. Verify at the human-AI seam

An expert human's in-the-moment judgment doesn't scale to a fleet of
concurrent agent sessions, so verification is pushed into things that run
without a human present: automated tests and quality gates, an actual
run-the-thing check, and — for the judgment calls a static gate can't
make — a cold read from a separate reviewing agent that never saw the
worker's own reasoning.

- Repo-wide static gates: `scripts/quality-gates.sh`
- Run-the-thing verification: `claude/hooks/tests/` — fixtures that invoke
  each hook script against real (fixture) inputs and assert its actual
  decision, not just a lint pass (e.g. `test_git_stale_branch_guard.sh`
  builds a real `file://` git remote and feeds the hook crafted PreToolUse
  JSON)
- Cold pre-push review by an independent agent: `claude/commands/build.md`
  § "3e. Optional pre-push review"

### 4. Counter AI failure modes structurally

Vigilance doesn't scale across sessions — the fix for a recurring agent
mistake (writing outside the intended checkout, branching off a stale base,
querying a shared API budget directly) is a mechanical guard that blocks or
warns on the exact failure shape, not a reminder to be more careful next
time.

- Write-isolation guard: `claude/hooks/write-lane-guard.sh`
- Stale-branch guard: `claude/hooks/git-stale-branch-guard.sh`
- Shared-budget guard: `claude/hooks/board-adapter-guard.sh`

### 5. Climb the maturity ladder on evidence

A new rule starts as prose (a habit stated in `CLAUDE.md`); if it keeps
leaking in practice, it gets a mechanical backstop (a hook that warns or
asks); only a rule whose backstop keeps firing earns a hard, CI-enforced
invariant. Each step up the ladder is a response to an observed leak, not a
guess at what might leak.

- `git-stale-branch-guard.sh` backing the "fetch ground truth before
  building" habit, and `board-adapter-guard.sh` backing the
  "adapter-first" habit — both described as backstops, not replacements,
  in `claude/CLAUDE.kernel.md` §§ "Fetch ground truth before building" and
  "GitHub Projects boards"
- The hardest rung — a CI-enforced invariant that fails the build outright:
  `workflows/scripts/validate-live-drain.sh`

### 6. Automate the reversible; human-gate the irreversible

Anything a mistake can silently undo runs on its own (a worktree build, a
CI poll, a rebase-and-retest). Anything that can't be quietly undone — a
merge to the protected default branch, promoting a plan from draft to
approved, a design decision with no clear default — waits on an explicit
human answer.

- The plan-approval gate: `claude/plan-schema.md` line "`status: draft` is
  the gate between planning and execution. `/build` refuses to start on a
  `draft` plan"
- The merge-approval gate: `claude/commands/build.md` § "4b" (risky-set
  merge approval)

### 7. Bound the blast radius

Every worker operates inside a `git worktree` isolated from the parent
checkout, so a wrong or wild edit can't land outside its own branch. The
containing guard is a one-way boundary — it can block a write from
escaping, but grants no elevated reach in the other direction — and fails
open rather than wedging a session that hits an edge case it didn't
anticipate.

- Worktree lifecycle: `workflows/scripts/build/worktree.sh`
- The write-jail enforcing it, self-arming per worktree, fail-open by
  design: `claude/hooks/build-worktree-guard.sh`

### 8. Subtraction over mechanism

The default instinct is to fit the existing mechanism, or remove a
redundant one, before adding a new one. A card's board status is driven by
the same GitHub close-cascade that already fires on merge, rather than a
second write nothing else needs; a merge queue prefers GitHub's own native
queue and only falls back to hand-rolled mechanics on a repo tier where the
native feature isn't provisionable at all.

- The redundant-step rule, in prose: `claude/CLAUDE.kernel.md` §§ "Trust
  confirmed state" and "Board hygiene is part of the gate" ("a manual
  `board_set_status … Done` is a redundant backstop, not the primary
  mechanism")
- The fallback-only-when-native-is-absent seam: `docs/managed-merge-queue.md`,
  `workflows/scripts/build/gate.sh`

### 9. A toolkit you can read, not a service you trust

Every piece of this system is a script or a contract file that opens in a
text editor — no opaque hosted runtime a user has to take on faith.

- Stated verbatim: `README.md` — "It is a toolkit, not an app — everything
  here is a script, a slash command, or a contract file you read, not a
  service you depend on."
- The scripts and contracts themselves: `workflows/scripts/`, `claude/*.md`

### 10. Telemetry over anecdote

A claim about what the pipeline is doing is backed by an append-only
emitted record, not a session's memory of what happened — and the emit
sites themselves are checked for presence, so a code path that silently
stopped emitting is caught rather than assumed to still be reporting.

- Emit sites: `workflows/scripts/emit-command-run.sh`,
  `workflows/scripts/emit-issue-touch.sh`
- The presence lint over those emit sites:
  `workflows/scripts/validate-command-run-emit.sh`,
  `workflows/scripts/validate-issue-touch-emit.sh`

### 11. Budgets are first-class

API points, tokens, and a 5-hour usage quota are metered resources with
their own gates, not assumed infinite. A cache TTL protects a shared
GraphQL budget from a burst of reads; a quota gate reads the live
rate-limit snapshot and pauses a run rather than exhausting the window.

- The quota decision script (fail-open, never sleeps itself):
  `workflows/scripts/build/quota-gate.sh`
- The board's structure/state cache-TTL split protecting the shared GraphQL
  budget: `workflows/scripts/board/lib/board.sh` (see its cache-TTL
  comments), `workflows/scripts/board/lib/cache.sh`

### 12. Capture at source, drain on schedule

Something learned mid-work — a decision, a config drift, a piece of
feedback — is captured the moment it's noticed, not held for an end-of-session
summary that might never happen. Every such live capture rule ships with a
paired backstop in the nightly drain, and a registry check fails the build
if either half of a pair ships without the other.

- The live/drain pairing rule and its registry table:
  `claude/commands/tidy.md` (the "Live/Drain pairings" table)
- The CI check that fails on a half-shipped pair:
  `workflows/scripts/validate-live-drain.sh`

### 13. The stranger test

A kernel rule or mechanism earns its place only if a stranger's fresh
install — someone who cloned only the kernel repo, with no org history, no
personal vault, no personal board tied to it — would actually need it for
the kernel machinery (board adapter, build/sweep pipeline, install/doctor,
branch/PR policy) to work. A concern that's personal, org-specific, or tied
to one machine's paths or credentials routes downstream to the overlay
instead, never patched silently into the kernel.

- The rule verbatim, by this name: `claude/CLAUDE.kernel.md` § "Kernel vs
  overlay routing rule" ("The stranger test")

### 14. Minimum-viable-output

Whatever else is unavailable to a workflow — no `gh` auth, no repo, no
registered board, no reviewer agents declared — the run still produces the
one artifact that is its floor, and every dependency below that floor
degrades legibly rather than blocking the floor itself.

- The rule verbatim, by this name: `claude/commands/workshop.md` § "Minimum-
  viable-output rule" (the coverage walk's guaranteed floor: a ratified
  brief note in the knowledge store, even when every downstream integration
  is unavailable)

### 15. Legible degradation

When an agent-gated step's dependency — a reviewer agent, a capability probe
target — is unavailable, the step emits a one-line `skipped — <x>
unavailable` notice rather than silently no-opping. A silent skip is
indistinguishable from a pass that never ran, which is worse than a loud
failure because it hides the missing check instead of surfacing it.

- The rule verbatim, by this name: `claude/CLAUDE.kernel.md` § "Subagent
  usage" ("Legible agent-gate degradation")
- The presentation-plane instance of the same rule: `claude/message-schema.md`
  § "Degradation notice"
