# Engineering principles

Cross-language engineering review and authoring **criteria** — the kernel's
answer to "what should a review agent (or a human) flag in this diff, no
matter what language it's written in." This file states **what** the bar is;
it says nothing about **how** a reviewer applies it in any particular
language — that procedural half lives in the per-language reviewer catalog
(`claude/agents/reviewers/*`, see below). A stranger's fresh install gets
this set with zero configuration; a project may extend or override it.

## How this file relates to the other principles surfaces

Four surfaces exist in this repo, each with a distinct job, and none of them
redefines another:

- **`docs/principles.md`** — the toolkit's own design charter: why the
  pipeline itself (issue tracking, review gates, protected branches, merge
  queues) is built the way it is. It is about the tool, not about the code
  the tool helps ship.
- **`claude/engineering-principles.md`** (this file) — cross-language
  engineering review/authoring **criteria**: what a reviewer judges the
  *adopter's own code* against, independent of what language it's written
  in.
- **A project's `§ Principles` section** (in its priorities note —
  `Projects/<project>/Priorities.md`, falling back to the legacy
  `Priorities/<project>.md`) — per-project extensions or overrides of the
  kernel set above: additional standing rules specific to that codebase, or
  a deliberate departure from a kernel default.
- **`claude/agents/reviewers/*`** (the per-language reviewer catalog) —
  per-language review **procedure**: *how* a reviewer checks a language's
  own idioms and pitfalls. The catalog *consumes* the criteria named here
  (and in a project's `§ Principles`); it never states its own competing
  set of cross-language principles.

**Both-active rule.** The kernel set (this file) and a project's own
`§ Principles` set are **both** in force at once — the effective criteria a
reviewer judges against is their **union**, resolved fresh at the point of
use (an `/assess` decomposition pass, a `/build` pre-push review, a worker's
generation-time prompt), never precomputed or cached across runs.

## Merge semantics (single statement site)

This is the **one place** this repo states how a project's own principles
combine with the kernel set below. Any other spec that resolves this merge
(`claude/commands/assess.md`, `claude/commands/build.md`, or a future call
site) implements this rule — it does not restate or re-derive it:

- **Default: extend.** A project's `§ Principles` section **adds to** the
  kernel set. Nothing here is dropped unless the project says so explicitly
  (below).
- **`mode: replace`.** A project's `§ Principles` section may declare
  `mode: replace` to swap its own set in wholesale, discarding the kernel
  set entirely for that project. This is a deliberate, visible departure —
  not a default — and should be rare.
- **Named exclusions.** A project's `§ Principles` section may name
  specific kernel principles (by heading) to exclude, keeping the rest of
  the kernel set plus its own additions. Use this to drop exactly one
  principle that genuinely doesn't apply, without discarding the whole set
  the way `mode: replace` does.
- **`none`.** A project may declare `none` to opt out of engineering
  principles entirely — no kernel set, no project set. This is distinct
  from an *absent* `§ Principles` section (which falls back to the kernel
  set with an empty project slot) — `none` is an explicit, recorded
  decision to run with no declared criteria at all.

A merge is never silent: whatever call site performs it names, in its own
output, which kernel principles applied, which project principles applied,
and whether any exclusion or `mode: replace` was in effect — so a reader can
tell the difference between "the kernel default applied" and "a project
choice suppressed it."

## Advisory posture

Every principle below is a **flaggable review criterion**, not a mechanical
gate. A review agent (or a human reviewer) cites a principle when a diff
appears to violate it; that citation **advises** — it never blocks a merge
by construction, and no principle in this file is wired into
`scripts/quality-gates.sh` or any other required `checks` entry on its own
account. Turning a principle's spirit into an actual mechanical gate (a
linter rule, a CI check, a pre-commit hook) is the **adopter's own decision
and burden** — this file states the bar; enforcing it automatically, if
wanted, is built and owned downstream, not by the kernel.

---

## The seven principles

### 1. Every meaningful behavior tested for every state — no coverage-percentage gate

**Criterion:** flag a meaningful public behavior that has no test covering
each state it can be in (each input class, branch, or edge case it
distinguishes) — regardless of what the project's aggregate coverage
percentage reads. No numeric coverage threshold is itself a gating
criterion.

**Why:** a coverage-percentage target rewards whatever raises the number
fastest — trivial tests on easy paths — and punishes the hard-to-test
integration points that most need a test. Naming the actual unit ("every
meaningful behavior, every state") targets what should be tested directly,
instead of a proxy for it that's cheap to game.

### 2. Quality bars strict from day one

**Criterion:** flag a project's automatable quality gates (linting, type
checking, formatting, and equivalents for its language) set below their
strictest practical level, especially early in a project's life, with no
concrete plan to reach the strict setting.

**Why:** tightening a quality bar before much code exists is cheap; loosening
it now and "ramping up later" is expensive — every day at a looser setting
lets more code accumulate that will need retrofitting, and a permissive
setting adopted for expedience has a strong tendency to just stay that way.

### 3. Deterministic tests over recorded fixtures, never live-network

**Criterion:** flag a test that exercises network- or external-service-facing
behavior by making a real call to a live external system, rather than
against a recorded, deterministic fixture (or an equivalent local double).

**Why:** a test against a live external system is slow, flaky, and
non-reproducible — it can pass or fail for reasons that have nothing to do
with the code under test — and running it repeatedly against a third
party's real service is a cost imposed on someone else's infrastructure for
the test suite's convenience. A recorded fixture makes the test fast,
deterministic, and free of that externality; the accepted cost is that a
fixture can go stale and needs refreshing when the real behavior changes.

### 4. Verify at the human-AI seam

**Criterion:** flag a change whose acceptance relies solely on a human (or a
downstream agent) reading the diff and judging it correct, with no
independent, automatable check backing that judgment up.

**Why:** the moment an AI agent hands off code for someone else to accept is
the point of highest risk — fluent, confident output reads the same whether
it is right or wrong, so the recipient's own read of the diff is not a
reliable filter. Tests that fail before a human has to notice a regression,
type checks that catch a class of error without needing to be re-derived
each time, and an actual end-to-end run of the feature (not just "tests
pass") all replace a human's fallible in-the-moment judgment with something
structural and repeatable.

### 5. Counter AI failure modes structurally

**Criterion:** flag a known, recurring AI failure mode — a fabricated
API/function reference, a premature "done" declaration, silent drift from an
agreed plan, an uncritical concession when pushed back on, unrequested new
abstraction — that has no structural defense (an independent check, a
second differently-scoped reviewer, a rule enforced by tooling), only an
instruction to "be careful" or "don't do that."

**Why:** vigilance doesn't scale — not across a long session, and not across
a fleet of agent sessions running in parallel. A structural defense, once
built, catches every future occurrence of the failure mode it targets; a
reminder has to be re-noticed, by a human or an agent, every single time.

### 6. Limit blast radius through boundaries

**Criterion:** flag a change that reaches across an existing module or layer
boundary — a new import that crosses a boundary the codebase's own structure
otherwise keeps one-way, a change to shared mutable state, IO logic mixed
into what was previously pure business logic — as a design event needing
explicit attention, not a routine commit to wave through.

**Why:** changes stay local when boundaries are firm, and ripple
unpredictably when boundaries are fuzzy. An AI agent pattern-matches
"while I'm here, fix this too" more readily than a careful human does, so a
codebase with firm, legible boundaries turns that tendency into a visible
event (the new cross-boundary import itself is the alarm) instead of a
silent one.

### 7. Advisory over enforced discipline

**Criterion:** when weighing whether a discipline (this file's principles
included) should be a human/agent judgment call or a hard mechanical gate,
flag a proposal to make it a hard gate that has not weighed the gate's own
cost — maintenance burden, false positives, deadlocked legitimate work —
against what it actually prevents.

**Why:** mechanically enforcing a judgment-based discipline to the point of
catching every violation is either impossible or so costly that it isn't
worth it; an advisory signal catches the disciplined common case, and a
session (human or AI) that has already blown past several advisory signals
in a row has a bigger problem than one more mechanical gate would catch.
Enforcement, where an adopter decides they want it anyway, is that
adopter's own decision to build and their own burden to maintain — the
kernel ships the criterion, not the gate.
