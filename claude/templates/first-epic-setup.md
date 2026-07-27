# first-epic-setup.md — kernel template, not a slash command

This file lives at `claude/templates/` (never `claude/commands/` — a bare <!-- cite: TPL.1 class:template-becomes-command -->
`.md` under `claude/commands/` is auto-discovered as a slash command, and
this is data, not a command) so it never gets picked up as one.

**What this is.** The kernel-shipped, pre-designed body of the adopter's
**first epic** — "Set up `<project>` with temperloop" — per
[ADR 0010](../../docs/adr/0010-onboarding-as-first-executed-epic.md). It is
static template data, not itself a GitHub issue: a future onboarding/offer
flow (a separate, independently-tracked item — ADR 0010's own
"Consequences" section) instantiates it as a real epic in the adopter's
repo, substituting `<project>` for their actual project/repo name. Once
instantiated, the epic ships intentionally with **zero sub-issues** — its
`## Contract` (below) is decomposed directly by `/assess --epic <N>`'s
epic-decomposition mode (`claude/commands/assess.md` Step 1, foundation
#526), the same pre-designed/intentionally-undecomposed pattern any other
Contract-bearing epic uses.

**Everything from the `# Set up <project> with temperloop` heading down is
the literal epic body** — copied in verbatim (after the `<project>`
substitution) by whatever future flow creates the issue, never re-derived.
Design provenance: the ratified design brief
`Designs/temperloop - kernel starter engineering principles.md` §4
(Produces item 4), companion `Designs/temperloop - language reviewer
catalog.md` (per-language review procedure — deliberately out of scope
here), and [ADR 0010](../../docs/adr/0010-onboarding-as-first-executed-epic.md)
itself.

---

# Set up `<project>` with temperloop

This is your first epic driven through the **real** temperloop pipeline
(`/assess --epic <N>` → `/build`) — not a side setup script. It configures
the three things a fresh install assumes but doesn't yet have: engineering
review criteria, a working GitHub branch/PR/merge substrate, and CI.

Shape: **interview-first → compose → disclose → apply.** Every question <!-- cite: TPL.2 guard:docs/adr/0010-onboarding-as-first-executed-epic.md -->
below is asked *before* any external write; each write's consequence is
named at the moment you're asked; your answers compose into **one**
change-set you confirm **once**, as a whole; only then do this epic's own
items apply it across real dependency levels. Your first claim → worktree →
PR → CI-or-legible-no-CI → merge-gate pass happens on the work that
configures your own system — the demo and the setup are the same work.

design-brief: docs/adr/0010-onboarding-as-first-executed-epic.md
author-provenance: [[Designs/temperloop - kernel starter engineering principles]]

## Phase A — Interview (no substrate writes)

No **consented substrate mutation** happens anywhere in this phase — nothing
in your repo's branch protection, auto-delete setting, merge queue, CI
configuration, or tracked files is touched. Every item below is either a
read-only probe or a question, and every question is priced by a probe
before it's asked.

Two writes are the **explicit exceptions**, and neither mutates the substrate
this epic exists to configure:

- **This epic's own tracking issue** — progress and verdict comments on the
  epic you are running (`#<N>`, in your own repo). Bookkeeping on the work
  item, not a change to your project.
- **The decline Backlog pointer** (§ Decline floors) — filed only if you
  decline, so the unconfigured gap stays tracked instead of vanishing.

Naming them here is what keeps the claim honest. A leg asserting *zero*
writes would be self-negating, because the interview has to be able to
record its own progress and its own decline.

### A0. Upfront probes (read-only, price every question below)

- **`gh` auth + repo resolution** — confirm `gh auth status` succeeds and
  resolve `owner/repo` from `git remote get-url origin` (github.com only).
  Failure here degrades every later GitHub/CI question straight to a skip
  notice (§ Decline floors) — the principles interview (A1) still runs
  regardless, since it touches only your own repo's files.
- **Admin-rights probe** — read the authenticated user's repo permission
  (e.g. `gh api repos/<owner>/<repo> --jq '.permissions.admin'`) against the
  resolved repo. `true` → the GitHub/CI questions in A2/A3 are askable as
  direct writes. `false` (or unreadable) → every scope-blocked write in A2
  degrades to an **admin-packet** question instead (§ Non-admin path,
  Phase C) — named up front here, never discovered mid-interview.
- **`gate.sh backend <owner>/<repo>`** (`workflows/scripts/build/gate.sh`) —
  the queue-armability verdict: `NATIVE` (a merge queue is actually
  provisionable — an org-owned repo on a paid plan) or `MANAGED` (no native
  queue available; `gate.sh`'s own managed-merge fallback,
  `docs/managed-merge-queue.md`). This prices the merge-queue question in
  A2 below — a `MANAGED` verdict never offers the native option as if it
  were free, and a probe failure resolves to `MANAGED` (gate.sh's own
  fail-safe direction), never a false `NATIVE`.

### A1. Principles — merge the kernel set with yours

*"temperloop ships seven cross-language engineering-review criteria
(`claude/engineering-principles.md`) — every meaningful behavior tested for
every state (no coverage-percentage gate), quality bars strict from day
one, deterministic tests over recorded fixtures (never live-network),
verify at the human-AI seam, counter AI failure modes structurally, limit
blast radius through boundaries, advisory over enforced discipline. Do you
have existing conventions (a CLAUDE.md, a style guide) these should merge
with?"*

- **If yes:** *"Extend — add the kernel set to yours (default) — replace —
  drop the kernel set, use only yours — or exclude specific kernel
  principles you don't want, keeping the rest?"* **Consequence:** whichever
  you pick is recorded verbatim into your project's `§ Principles` section
  and becomes what every future review agent and `/build` worker judges
  your code against, from this point on, until you change it again.
- **If no existing conventions:** *"Adopt the kernel set as-is?"*
  **Consequence:** the kernel seven become your project's review criteria
  with an empty project slot.
- **If declined outright:** nothing is written here, but the kernel default
  still applies at point of use (§ Decline floors) — declining costs you
  only the *recorded* choice, never the criteria themselves.

### A2. GitHub integration — branch protection, auto-delete, merge queue

Asked as direct-write questions only when the A0 admin-rights probe read
`true`. When it read `false`, every question below still gets an answer
from you, but the answer routes to the admin packet (Phase C's non-admin
path) instead of a direct write.

- *"Protect your default branch — require a pull request before merging,
  forbid direct pushes?"* **Consequence:** every future change, including
  your own, must go through a PR from here on — this is what makes the
  branch actually protected rather than a documented policy nobody
  enforces.
- *"Auto-delete a PR's head branch on merge?"* **Consequence:** a merged
  branch cleans itself up automatically; you never need a manual branch
  prune for anything this repo generates going forward.
- *"Enable a merge queue?"* — priced by the A0 `gate.sh backend` verdict:
  - **`NATIVE` verdict:** *"Arm GitHub's native merge queue?"*
    **Consequence:** every PR merges through the queue's own
    re-test-before-land semantics; `/build`/`/sweep` drive it via
    `gate.sh queue`.
  - **`MANAGED` verdict:** *"Your plan/ownership can't provision a native
    queue. Record the managed-merge fallback instead (`gate.sh
    managed-merge` — update-branch, re-poll, then merge, per PR)?"**
    **Consequence:** the same re-validate-then-merge safety without a paid
    queue, recorded as `BUILD_MERGE_BACKEND=managed` so `/build` never
    tries to arm a queue that isn't there.

### A3. CI integration — how builds get kicked off

- *"How do you want CI kicked off: a GitHub Actions workflow, or none for
  now?"*
  - **Actions chosen:** *"What should the required `checks` job run — your
    test suite, a lint pass, both?"* **Consequence:** this workflow becomes
    the **sole producer** of the `checks` status context that Phase B is
    ever allowed to require; the job named here is scaffolded verbatim in
    Phase C's L2, under the literal job name `checks`.
  - **No Actions** (first-class, never a lesser fallback): *"Skip CI
    configuration — rely on local gates only
    (`scripts/quality-gates.sh`) for now?"* **Consequence:** no `checks`
    status is ever required on your default branch (Phase B's congruence
    rule exists exactly to keep this choice from silently bricking every
    future merge), and this epic's own items mark themselves
    zero-CI-aware (Phase C) so the CI poll never mistakes "no CI
    configured" for "CI hung."

## Phase B — Composed change-set (confirm once, as a whole)

Every answer from Phase A composes into **one** change-set, shown back to
you in full — before anything applies. Two rules make the *composition*
itself safe, not just each answer in isolation:

- **Structural congruence, not a naming convention.** The required-`checks`
  status context enters the composed set **only when** the A3 answer
  actually configured a producer for it (the Actions path). The no-Actions
  answer produces branch protection **without** a required-status entry —
  never a required context with nothing that will ever post it. This is
  what makes the self-brick failure (a required status nothing satisfies)
  **structurally unreachable**, not merely untested.
- **No-Actions → recorded managed-merge `--non-strict` posture.** When A3
  chooses no Actions, the composed set additionally records a
  managed-merge `--non-strict` posture (`gate.sh managed-merge ...
  --non-strict`) wherever the managed backend is in play — there is no CI
  to re-poll before merging, so the strict path's CI re-poll step would
  otherwise wait on a check-run that will never appear. On the `NATIVE`
  backend, no-Actions simply means the native queue's own required-status
  list stays empty; there is no separate strict/non-strict setting to set
  there.
- **Static `checks`-name agreement.** Whatever job the Phase C scaffold
  writes, it is always literally named `checks` — the same required-status
  name every temperloop build repo already agrees on
  (`claude/CLAUDE.kernel.md` § Branch & PR policy) — never a different
  label that would need its own separate protection-rule edit later. The
  no-Actions path never invents a job name, since none is scaffolded.
- **Walk-back items ride the same set.** Any write whose later decline
  would strand earlier state carries its own undo item in this same
  change-set — e.g., choosing Actions now means the set also includes
  "un-require the `checks` context, the moment the workflow is ever
  removed" — so a future decision never leaves you holding a required
  status with no producer.

You confirm this composed set **once**, as a whole. No further
write-by-write interruptions happen during apply (Phase C).

## Phase C — Apply, as real pipeline levels

Once confirmed, the change-set applies through the actual pipeline —
`/assess --epic <N>` decomposes this epic's `## Contract` into items across
the three **apply** levels below — plus a fourth, verification-only level
that carries `zero-ci-run-check` (§ Contract) — and `/build` drives every one
of them exactly like any other work in the pipeline:

- **L0 — Principles recorded.** Your A1 answer lands in your project's
  `§ Principles` section (`Projects/<project>/Priorities.md`, or the
  legacy `Priorities/<project>.md`). No external write beyond your own
  repo's files; runs regardless of what the GitHub/CI answers were.
- **L1 — Consented GitHub writes.** Branch protection and auto-delete per
  the composed rules; the merge queue armed (`NATIVE`) or the managed
  backend recorded (`BUILD_MERGE_BACKEND=managed`) per your A2 answer.
  **Non-admin path:** if the A0 rights probe read `false`, this level's
  writes never happen directly — instead it produces an **admin packet**:
  the precise settings requests, the click-paths to make each one, and why
  each matters, for you to hand your repo admin. Nothing here is silently
  skipped and nothing is written without the rights to write it — the
  pipeline mechanics still demonstrate fully on the levels that don't need
  elevated rights (L0, and L2's local-only posture when no-Actions was
  chosen).
- **L2 — CI scaffold.** The Actions workflow from your A3 answers, with a
  job literally named `checks` matching what L1's branch protection
  requires — or, on the no-Actions answer, nothing is scaffolded and no
  requirement is armed.

**Zero-CI-aware execution.** Every pre-CI item in this epic (anything whose
own completion doesn't depend on L2 already existing) marks itself so
`/build`'s CI poll (`workflows/scripts/build/ci-poll.sh`) reads the legible
`NO_CI` verdict (temperloop#605) and skips with a "no CI configured yet"
notice — never an apparent hang waiting out a timeout window for check-runs
that will never appear.

## Decline floors

Nothing here can leave your repo worse off, or in an ambiguous <!-- cite: TPL.3 incident:K#605 -->
half-configured state:

- **Decline the whole epic** → you still get the inline principles
  interview (A1, L0 content only) **plus** a durable re-offer pointer: a
  Backlog item filed in your own repo naming exactly what remains
  unconfigured (the substrate half), so the gap stays tracked rather than
  vanishing.
- **Decline one level, keep the rest** → that level's skip is recorded on
  the epic; the other levels still apply as consented.
- **Non-interactive run** (no operator to ask) → the whole epic skips with
  a plain notice; nothing is written.
- **Take no action at all** → the kernel's point-of-use principle defaults
  and the managed-merge fallback both still work with zero configuration —
  declining strands you on the un-customized defaults, never on a broken
  pipeline.

## Contract

### Produces

- Your project's `§ Principles` section, populated per your A1 answer
  (kernel set extended, replaced, or with named exclusions per your choice;
  or the point-of-use kernel default, unrecorded, if declined).
- Default-branch protection (require-PR, no direct pushes) — consented and
  applied directly, or degraded to an admin packet when the A0 rights probe
  read `false`.
- Head-branch auto-delete on merge — consented/admin-packeted the same way.
- A merge-queue disposition: `NATIVE` armed, or `BUILD_MERGE_BACKEND=managed`
  recorded — never a `checks` requirement with no producer (Phase B's
  congruence rule).
- A CI disposition: a scaffolded Actions workflow whose job is named
  `checks` and matches the armed protection, or an explicit no-Actions
  posture — local gates only, nothing armed, no job name invented.
  **Decompose this seam as `kind: spike`, with no `model:` stamp.** Both of
  its branches settle a *disposition* rather than committing code: the
  no-Actions branch scaffolds nothing at all, and the Actions branch's
  workflow file lands as a **consented change-set write** in Phase C — part
  of the set you confirmed once as a whole, never a separate PR this item
  opens. Decomposed as `kind: code` (the default) it would put a code worker
  on a seam with nothing to commit, and open an empty PR on the no-Actions
  branch, so the kind is fixed here rather than left to default.
- A durable re-offer pointer (Backlog item) whenever any level was
  declined, naming exactly what remains unconfigured.

### Consumes

- `workflows/scripts/build/gate.sh backend` and `docs/managed-merge-queue.md`'s
  managed-merge mechanics (reused, never reimplemented).
- The `checks` required-status contract
  (`claude/CLAUDE.kernel.md` § Branch & PR policy) and
  `workflows/scripts/lib/land-on-protected-main.sh`'s ruleset-probe shape
  (the same `rules/branches/<default>` read `gate.sh backend` itself uses).
- `claude/engineering-principles.md` ([ADR-0009](../../docs/adr/0009-kernel-engineering-principles-layer.md))
  as the kernel principle set this epic's L0 records into `§ Principles`.
- `workflows/scripts/build/ci-poll.sh`'s `NO_CI` verdict (temperloop#605)
  for Phase C's zero-CI-aware execution.
- The adopter git-safety install surface (epic #565) — built on, never
  re-done.
- **Sequencing — `zero-ci-run-check` runs `after: github-substrate`.** The
  "no hang" that item asserts is *caused by* a required check with no
  producer, and whether such a check exists at all is `github-substrate`'s
  own disposition — so the verification cannot be scheduled ahead of the
  substrate it verifies. This edge is normative, not advisory: without it
  the check can run against an unconfigured substrate, where a green result
  proves nothing. It is what moves `zero-ci-run-check` into a dependency
  level of its own (§ Acceptance, Zero-CI execution).

### Acceptance

- **Interview write-scope.** Phase A completes having made **no consented
  substrate mutation** — no branch-protection, auto-delete, merge-queue, CI,
  or tracked-file change — with exactly two writes permitted as named
  exceptions: progress/verdict comments on this epic's own tracking issue
  (`#<N>`, in your own repo) and, on a decline, the Backlog re-offer pointer
  (§ Decline floors). The leg is falsified by any *substrate* write during
  Phase A, and is **not** falsified by either exception. Scope it this way
  when decomposing: a leg asserting zero writes of any kind is self-negating
  against the two writes this epic's own bookkeeping requires, and fails the
  moment it is honestly evaluated.
- **Principles-only completion.** A fresh install with no `§ Principles`
  section, offered this epic and completing L0 alone (GitHub/CI declined),
  ends with the project's `§ Principles` populated and a re-offer pointer
  filed naming the unconfigured substrate.
- **Admin fixture, consent + effect.** On a disposable **admin** fixture
  repo, every consented GitHub/CI write verifiably lands (protection,
  auto-delete, queue-or-managed, scaffolded workflow) and every declined
  write provably does not; a scope-blocked write never happens on an admin
  fixture (the probe read `true`), so this bullet's fixture is admin-only —
  the non-admin case is its own bullet below.
- **Transition-window invariant.** Walking every intermediate state the
  composed change-set creates on the admin fixture, at no point does a
  required `checks` status context exist without a configured producer —
  the no-Actions composition never arms the requirement, on any
  intermediate state, not only the final one.
- **Non-admin fixture.** On a disposable **non-admin** fixture, the rights
  probe fires, L1 composes into an admin packet instead of any write, and
  the epic still completes its non-admin levels (L0, and L2's local-only
  posture) through the real pipeline — the demo claim is honestly re-scoped,
  never faked.
- **CI-level agreement.** The scaffolded workflow's job is named `checks`
  and matches the composed protection; the no-Actions choice records the
  local-gates/`--non-strict` posture and scaffolds nothing.
- **Zero-CI execution.** *Gate scope: this clause states the required
  behavior (pre-CI items complete via the `NO_CI` skip notice, no
  poll-window hang). End-to-end verification of that behavior on a live
  fixture is owned by `zero-ci-run-check`, which runs `after:
  github-substrate` (§ Consumes) and therefore lands in a **dependency level
  of its own, below the level carrying `github-substrate` and
  `ci-disposition`** — a fourth level where the decomposition would
  otherwise have three. It is not repeated as part of every other item's own
  acceptance, and no item in an earlier level is failed by its verdict.*
- **Decomposition fidelity.** `/assess --epic <N>` decomposes this
  Contract's `Produces` into seam-scoped items with **zero reshaping** —
  if a future edit to this template needs `/assess` to reshape it before
  decomposing, that edit broke this acceptance clause.
