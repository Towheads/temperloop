---
title: Read-only advisory review agents
slug: review-agents
---

## Problem

A pipeline that lets one agent plan, decompose, and implement work with no
second opinion is a pipeline where a structural mistake — a decomposition
that hides a dependency, a design that puts a responsibility in the wrong
place, a workflow spec with an invariant that fails silently — ships exactly
as fast as everything else, with nothing catching it before it is committed.
A human reviewer catches this by asking "wait, why is this here" mid-review;
an agent under time and token pressure to finish its own task is structurally
worse at asking that question about its own work than a second, differently-
scoped agent is at asking it from outside. Without a dedicated, independent
review pass, that class of mistake is caught only by luck or by a human
happening to notice later, once it is more expensive to unwind.

The same gap exists one level down, in language-specific correctness. A
generic second opinion catches a structural mistake, but not a
language-specific idiom bug — a Python mutable default argument, a shell
quoting trap under `set -e`, a Rust borrow-checker smell — the kind of
finding that needs per-language knowledge, not just a second pair of eyes.
Without that, the only way to get language-aware review is to hand-author a
reviewer per project, which is exactly the friction most adopters hit at the
moment the tool should be delivering value.

## How it works

**The advisory family.** A small set of subagents, defined as Markdown files
under `claude/agents/`, exist purely to give a second opinion before
something durable gets committed. Each one:

- loads **cold** for every invocation — no memory of prior reviews, so its
  judgment is not anchored by what it said last time;
- is **read-only** — its tool access is limited to `Read`, `Grep`, `Glob`,
  and `Bash`, with no ability to edit code, write to a board, or modify a
  note; and
- is **advisory, not authoritative** — it surfaces findings for the calling
  workflow (and ultimately a human) to act on; it never mutates state
  itself, and authority runs one direction only.

Three agents currently make up the family:

- **architecture-reviewer** — an independent check on boundary, layering,
  and contract decisions before they are locked in: a new component, a
  change that crosses a module boundary, a shift in a public contract. Used
  before finalizing a design decision and during planning for any work that
  touches an architectural boundary.
- **requirements-auditor** — a sanity check on the *logical* groupings and
  *technical* decompositions a planning workflow produces, before that
  output becomes durable (a set of tracked work items, or a written plan).
  Checks that groupings make sense and that a decomposition's items, edges,
  and acceptance criteria hold together.
- **workflow-reviewer** — a review of the prose specifications that an agent
  itself executes as a procedure (the equivalent of a runbook or playbook a
  human would otherwise follow by hand). These specs typically have no
  automated tests and fail silently when an invariant is violated, so this
  agent's job is to catch an invariant violation the author, mid-edit,
  would not see.

Each agent's own spec states which model tier it should run on and why: an
agent whose findings gate something downstream (nothing else double-checks
its call) stays on the calling session's own model; an agent whose findings
are filtered by a human or another process before they take effect can
safely run on a smaller, cheaper tier.

**The capability probe.** Not every project that could use one of these
agents has it available — a project may not declare the agent, or the agent
definition may not be installed in that checkout. Rather than assume
availability and fail confusingly partway through a review step, the calling
workflow probes first: an agent is treated as available if and only if the
project's own configuration declares it (either named explicitly in a
project-level configuration section, or present as a file under
`.claude/agents/`). This is a single, reusable predicate — every call site
that wants a review pass runs the same check rather than each reinventing
its own availability logic.

**Legible degradation.** When the probe says an agent isn't available, the
calling workflow does not silently skip the review step and proceed as if
nothing happened — that would make a skipped gate look identical to a passed
one, which is worse than not having the gate at all. Instead it emits an
explicit, uniform notice — `skipped — <agent> unavailable` — into whatever
summary or log the workflow already produces, so a reader can tell the
difference between "reviewed and clean" and "never reviewed." The same
phrasing is used everywhere the pattern applies, so it is grep-able across a
whole pipeline run.

**The language-reviewer catalog.** Seven per-language rubrics — Python,
Shell, TypeScript/JavaScript, Go, Rust, Java, Swift — ship as a second
review-agent family under `claude/agents/reviewers/` (ADR 0007,
`docs/adr/0007-language-reviewer-catalog-kernel-placement.md`). This is a
deliberately different deployment shape from the three process-review agents
above. Living one directory below the flat `claude/agents/*.md` glob that
`project-agents.sh`'s bulk deploy walks, the catalog is **inert by
default**: present in the repo as source, but never bulk-deployed and never
live in a fresh checkout's `.claude/agents/` until a project opts in. That
neutralizes the "dead weight" objection ADR 0007 records against shipping a
reviewer roster at all — a `.py`-routed reviewer forced on a Go shop is
uninstallable cost for a stack that never uses it — because the objection
is specifically about unconditional activation, not about shipping the
rubrics. Each rubric follows the same read-only/cold-load/advisory
shape as the process-review family, scoped to one language's idioms and
pitfalls — e.g. `python-reviewer` flags mutable default arguments, swallowed
exceptions, and resource-cleanup gaps; the other six apply the equivalent
per-language checklist.

**Selective activation.** `project-agents.sh --only <name> --category
reviewers` (temperloop#543, single-reviewer deploy flag) deploys exactly one catalog reviewer — reading
from `claude/agents/reviewers/<name>.md` but writing to the flat
`.claude/agents/<name>.md`, the same path the capability probe resolves
against — without touching the rest of the catalog. This is the mechanical
deploy primitive; what to offer and the accept/decline decision live in the
two scripts below.

**The routing axis.** `workflows/scripts/config/reviewer-routing.tsv` is the
single source of truth for the extension/path-glob → reviewer axis (ADR
0008, `docs/adr/0008-reviewer-routing-tsv-extension-axis-scope.md`): `.py` →
python-reviewer, `.sh` → shell-reviewer, `.ts`/`.js` → typescript-reviewer,
`.go` → go-reviewer, `.rs` → rust-reviewer, `.java` → java-reviewer, `.swift`
→ swift-reviewer, and `docs/**` → docs-reviewer. `/build`'s 3e pre-push
review step (`claude/commands/build.md`) consults this tsv for the
extension/glob axis, and the coverage scan below reads the same file —
never a parallel hardcoded list — so the two can't drift on that axis.
Everything the tsv does not model — a change *kind* with no extension
(`architectural` → architecture-reviewer), the broader stranger-facing-prose
`*.md` fallback, the `claude/commands/*.md` → workflow-reviewer exception, a
per-item `review:` override, and the run-both multi-match rule — stays
prose-resident in `build.md` by design; the tsv's scope is deliberately
narrower than "all routing."

**The coverage scan.** `workflows/scripts/install/reviewer-activation-coverage.sh`
(temperloop#548, gap-set scan) is a pure, non-interactive, read-only data path. Its
`reviewer_coverage_gaps <project-dir>` function computes the *gap set* —
catalogued reviewers whose language has material usage in the target repo
but isn't yet active. A language counts as material once its file count —
summed across every routing-tsv key that maps to the same reviewer, so
`.ts` and `.js` both count toward `typescript-reviewer`'s one total — reaches
`REVIEWER_SCAN_MIN_FILES` (default 3, `workflows/scripts/build/build.config.sh`),
high enough that a single generated/vendored/example file doesn't trigger a
false-positive offer. The scan prunes vendored/build-output directories
(`node_modules`, `.venv`, `vendor`, `dist`, `build`, `target`, `.git`, and
similar) from every count. A reviewer drops out of the gap set once it's
**covered** — any file present at `.claude/agents/<name>.md`, whether
catalog-activated or user-authored; the scan only checks presence, never
provenance — or **durably declined** (see below). `--list-only` prints the
gap set for a scripted caller; `--check-integrity` separately verifies every
tsv row's `catalog-agent-path` column resolves to a real file on disk,
catching a routing entry with no backing rubric (the "uncatalogued" case the
doctor check below surfaces).

**Opt-in activation.** `workflows/scripts/install/reviewer-activate.sh`
(temperloop#549, opt-in activation caller) is the interactive layer: it sources the coverage scan's
gap-set function directly rather than re-implementing it, emits **one
batched offer** covering the whole gap set (never one prompt per reviewer),
and on accept invokes `project-agents.sh --only` per chosen name. A decline
is durable: it writes a marker file at
`.claude/reviewer-state/declined/<name>` (presence is the entire signal;
content is a human-readable declined-on date, never parsed) so that
language is never re-offered or re-warned about. Both accept and decline are
also drivable non-interactively (`--accept <list|all>`, `--decline
<list|all>`), and a headless invocation given neither flag with no stdin
available makes no changes rather than guessing a default. Before either
write path, the script verifies — and if missing, appends — two entries in
the *target* project's own `.gitignore`: `.claude/agents/` and
`.claude/reviewer-state/`. It refuses to write activation/decline state
anywhere it can't confirm stays untracked, so one teammate's opt-in is never
a `git add -A` away from being imposed on the rest of the repo (ADR 0007's
"never imposed on teammates" invariant).

**The advisory doctor check.** `make doctor`'s `check_reviewer_coverage()`
(`workflows/scripts/install/doctor.sh`, temperloop#550, advisory doctor check) sources the coverage
scan's data functions directly — never the interactive
`reviewer-activate.sh`, which has no source-guard and would run its whole
prompt body if sourced here. It reports three outcomes: a **resolvable
gap** — WARN, every run, until activated or declined, pointing at
`reviewer-activate.sh`; a **durably declined** reviewer — silent, since the
scan's gap-set computation already excludes it; and an **uncatalogued** tsv
row — a routing entry whose `catalog-agent-path` doesn't resolve — reported
as a **one-time INFO**, tracked by its own gitignored marker under
`.claude/reviewer-state/`, that points back at this doc's bring-your-own
section below. The check is strictly advisory: a WARN increments a local
tally only, never the doctor's exit code — a fresh checkout with zero
activated reviewers is the *designed* default (ADR 0007's opt-in stance), so
`make doctor` exits 0 with every language reviewer inactive.

**Bring your own.** The coverage scan's "covered" test above is also the
official extension seam for a language the catalog doesn't cover (Ruby,
C#, Kotlin, Terraform, and so on) or for tuning a covered one per repo:
place any reviewer definition at `.claude/agents/<name>.md` and it counts
as covered — the scan never distinguishes a catalog activation from a
hand-authored file, so a user-defined reviewer is never offered the
catalog's version and is never touched or overwritten by any script in this
family. This is the same capability-probe seam the process-review family
(above) already relies on: a project declares what it has under
`.claude/agents/`, and every review step across the pipeline — `/build`'s
3e, `/workshop` (the design-first command), `/assess` (epic decomposition),
and `/triage` (intake/grouping) — resolves against that declaration
rather than assuming a fixed roster.

## Integration

These agents are invoked by the higher-level workflows that produce durable
state — a planning step before it writes a plan note, a build step before it
finalizes a change, a decision-capture step before a design choice is
locked. A calling workflow is responsible for running the capability probe,
invoking the agent with enough context to judge (the diff or plan under
review, plus any project-specific evaluation criteria it should also apply),
and folding the agent's findings — or its `skipped — <agent> unavailable`
notice — into its own step summary. The agents themselves have no
integration surface beyond being invoked with a prompt and returning text;
they hold no state between invocations.

The language-reviewer catalog integrates through the same capability-probe
seam plus one more resolution step: `/build`'s 3e pre-push review
(`claude/commands/build.md`) resolves a changed file's reviewer from
`reviewer-routing.tsv`'s extension/glob axis (falling back to the
prose-resident non-extension routing described above), then runs the same
capability probe and `skipped — <agent> unavailable` degradation as
`architecture-reviewer`/`workflow-reviewer`/`docs-reviewer`. Getting a
catalog reviewer into that resolvable state runs through the opt-in
activation flow (`reviewer-activate.sh`), not the bulk `project-agents.sh`
deploy the process-review family uses. `make doctor` is a standing
integration point on top of that: it resurfaces an unresolved activation gap
on every run without gating on it, so drift between "what languages this
repo is written in" and "which reviewers are active" stays visible instead
of silently persisting.

## Installation — making the agents discoverable in a fresh clone

The agent (and command) definitions ship as **source** under `claude/agents/`
and `claude/commands/`, but Claude Code discovers project agents and commands
from a **project-scoped `.claude/agents/` and `.claude/commands/`** — not from
`claude/*`. On a fresh standalone-kernel clone nothing wires the source into a
live `.claude/`, so the capability probe evaluates FALSE for every lens and
every review degrades to all-skipped (temperloop#290, fresh-clone capability-probe gap).

The install path that closes that gap:

```sh
bash workflows/scripts/install/project-agents.sh
```

Run once from a fresh clone, it deploys one entry per source file into the
repo's own project-scoped `.claude/agents/` and `.claude/commands/` — by
default as symlinks back to the tracked source (so a later `git pull` needs no
re-run), or as detached real-file copies with `--copy`. It is **project-scoped**
(never writes under `~`, so it can't collide with a machine-surface
`temperloop install`), **idempotent** (an already-correct entry is left alone),
and **non-destructive** (a pre-existing non-managed file at a target is
reported and skipped, never clobbered). Deploy the agents into a *different*
working repo (adopting the kernel's review lenses there) with
`--project-dir DIR`; preview with `--dry-run`. Once it has run, the capability
probe resolves and the review lenses execute instead of skipping.

## Resource impact

Each invocation is a single subagent call scoped to read-only tools, priced
like any other model call at whichever tier that agent's definition
specifies (session-tier for a gating review, a cheaper fixed tier for a
purely advisory one). There is no added storage or background process — the
cost is bounded to the review pass itself, and skipped (unavailable) reviews
cost nothing beyond the one-line notice.

The coverage scan's cost is one `find` walk per routing-tsv key (an
extension count or a path-glob count) over the target repo, pruning
vendored/build-output directories — bounded by repo size, not by the number
of catalogued languages beyond that constant factor. It re-runs on every
`make doctor` invocation and by hand via `reviewer-activate.sh`; both are
local filesystem work with no network or model call. Each decline marker is
a few bytes; the one-time uncatalogued-notice marker is likewise negligible.
As with the process-review family, an un-activated catalog reviewer costs
nothing at review time — it isn't deployed, so the capability probe simply
doesn't find it and no review-agent invocation is ever charged for it.

## Telemetry

None. A review agent's output lands directly in the calling workflow's own
step summary or PR/plan-note narrative rather than a separate structured
stream — there is no dedicated metrics or event log for review-agent
invocations today. The observable surface is the `skipped — <agent>
unavailable` notice pattern itself: its presence (or absence) in a workflow's
summary is how a reader notices a review pass that didn't run.

The coverage scan and doctor check likewise emit no dedicated telemetry
stream. Their output is the `make doctor` WARN/INFO lines plus the gap-set,
decline-marker, and one-time notice-marker files on disk under
`.claude/reviewer-state/` — all directly inspectable, never routed through a
separate log or metrics stream.
