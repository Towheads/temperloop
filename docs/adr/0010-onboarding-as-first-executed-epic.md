---
title: "0010: Onboarding delivered as the adopter's first executed epic"
---

## Status

Accepted

## Context

epic: temperloop#599 (found by the K#598 embedded-opinions audit); umbrella
temperloop#419 (beta milestone). Companion decision:
[ADR-0009](0009-kernel-engineering-principles-layer.md) (the criteria file
this epic's principles level records into a project's `§ Principles`
section).

Even with `claude/engineering-principles.md` shipped
([ADR-0009](0009-kernel-engineering-principles-layer.md)), a stranger's
fresh install still assumes a GitHub substrate — a protected default
branch, a required `checks` status, a merge queue, head-branch auto-delete,
a CI workflow posting that status — that exists only if the adopter has
hand-configured it themselves. The K#598 audit's finding was specifically
that "repo-settings opinions don't carry": the pipeline's branch/PR policy
is written as though this substrate already exists, with no path that
actually builds it for a stranger starting from an empty repo. A stranger
also has no worked example of the funnel itself before being asked to trust
it with real work.

Two alternatives were considered and rejected:

1. **Docs-only setup instructions** — write a setup guide the adopter
   follows by hand before their first real epic. Rejected for the same
   reason docs-only principles were rejected in
   [ADR-0009](0009-kernel-engineering-principles-layer.md): a doc nobody's
   workflow executes is exactly as decorative as a doc nobody reads, and a
   hand-followed setup guide has no verification that the adopter actually
   completed it correctly.
2. **A dedicated setup command or script outside the normal funnel** — a
   one-off `temperloop setup` that configures GitHub and CI directly,
   separate from `/assess`/`/build`. Rejected: this would be a second
   mechanism duplicating what the real pipeline already does (claim →
   worktree → PR → CI → merge gate), and it would deprive the adopter of
   their first real look at how the funnel actually works — the thing most
   worth demonstrating on day one.

## Decision

Ship onboarding as a **kernel-shipped, pre-designed first epic** —
"Set up `<project>` with temperloop" — that the adopter drives through the
**real** pipeline (`/assess --epic N` → `/build`), not a side mechanism.

- **Shape: interview-first → compose → disclose → apply.** Every question
  across all three concerns (engineering principles, GitHub integration,
  CI integration) is asked *before* any external write, each priced with
  probe facts (admin rights, the managed-merge backend's queue-armability
  verdict) and each write's consequence named at the moment of consent. The
  answers compose into one congruent, consequence-annotated change-set the
  adopter confirms once as a whole; only then do the epic's items apply it
  across real dependency levels.
- **Three concerns, one epic.** (1) Principles — merge the kernel set
  ([ADR-0009](0009-kernel-engineering-principles-layer.md)) with the
  adopter's existing conventions, recording the outcome into their own
  `§ Principles` section. (2) GitHub integration — branch protection,
  head-branch auto-delete, and the merge-queue enablement question (native
  where armable, a managed fallback recorded otherwise). (3) CI
  integration — scaffold the required `checks` workflow from the adopter's
  own answers, or a first-class no-Actions choice that never arms a
  requirement nothing will satisfy.
- **Structural congruence, not a naming convention.** A required `checks`
  status context enters the composed change-set **only** when a producer
  for it was actually configured (the Actions path chosen at the CI
  question); any write whose later decline would strand earlier state
  carries its own walk-back item in the same set. This makes the
  self-brick failure mode (a required status nothing ever posts) 
  structurally unreachable rather than merely untested.
- **Non-admin path, named up front.** An upfront rights probe re-scopes the
  GitHub level honestly for a non-admin adopter: scope-blocked writes
  degrade to an **admin packet** — the precise requests, click-paths, and
  rationale to hand a repo admin — never a silent skip, an unconsented
  write, or a faked demo level. The funnel mechanics still demonstrate on
  the levels that don't require elevated rights.
- **Decline floors are durable, never a vanished gap.** Declining the whole
  epic still yields a durable re-offer pointer — a tracked item in the
  adopter's own repo naming what remains unconfigured. Each level is
  independently declinable with its skip recorded. A non-interactive run
  skips with a notice.
- **Amendment (temperloop#796, the `init` scope-down).** Two clauses above
  are narrowed, and the reason is the same in both cases: `temperloop init`
  is a *bootstrap*, and every setup action it performed itself was a second
  implementation of something this epic already owns.
  - **The decline floor is the pointer alone.** The clause above originally
    read "still yields the inline principles interview … plus a durable
    re-offer pointer". The interview half is withdrawn. `init` used to run
    an inline copy of the principles interview on the decline path,
    extracting the A1 text from the epic template and writing the answer
    into the adopter's priorities note. That was a parallel interview asked
    by a different actor, through a different write seam, on the one path
    where the adopter had just said "no". It is now this epic's own L0 item
    (`record-principles`): declining the epic **defers** the interview
    rather than running a shadow of it. Nothing is lost, because the kernel
    principle set ([ADR-0009](0009-kernel-engineering-principles-layer.md))
    already applies at every review call site's point of use with zero
    configuration — declining costs the adopter only the *recorded* choice,
    never the criteria themselves. The durable re-offer pointer is the whole
    floor, and it is unchanged.
  - **`init` applies no API state at all.** It bootstraps
    `.temperloop/config` and its proposal PR, offers this epic, prints the
    handoff, and stops. Its own required-check apply is retired specifically
    because it violated the **Structural congruence** clause above: it armed
    a required `checks` context unconditionally, with no regard for whether
    any producer would post it — exactly the self-brick this epic makes
    unreachable. Its label pre-creation is retired as redundant (the
    issues-only tracker backend already creates those labels lazily at point
    of use), and its board provisioning is dropped outright (temperloop#793;
    issues-only is the sole init-time tracker mode). The flags that gated
    those applies are retained as deprecated no-ops rather than removed, so
    no consumer breaks and the release stays non-breaking.
- **Amendment (temperloop#1088, the token-metering opt-in).** "Three
  concerns, one epic" gains a fourth *question* — not a fourth guardrail.
  The `tokens` `report.d` producer reads the operator's own Claude Code
  transcript files, and `temperloop init` proposes it in its tree-only
  proposal PR unconditionally, disclosing it only afterwards (via the
  producer's own first-run notice, temperloop#986). Placement is therefore
  moved behind consent: a Phase A question (§ A4 in the template) whose
  answer composes into the same Phase B change-set, so the producer is
  **placed on opt-in** rather than placed and disclosed. It rides the
  existing shape rather than adding a mechanism — the same
  interview → compose → confirm-once → apply path, and the same congruence
  logic ("nothing enters the set that the answers did not ask for") applied
  to a tracked file instead of a required status. Two clauses of this ADR
  are deliberately **not** disturbed: `init` stays non-interactive (the
  interview is the first epic's, driven by `/assess`→`/build`), and the
  producer's first-run notice stays unconditional — an interview question,
  like a prompt, reaches only whoever runs the flow, so it structurally
  cannot reach a teammate who inherits the committed producer by `git pull`.
  The two are complementary halves of one consent answer (adopter half here,
  inheritor half in the notice), never substitutes.
- **Zero-CI awareness.** Until the pipeline's CI-poll defect is fixed
  (tracked separately), the epic's pre-CI items mark themselves so the CI
  poll is skipped with a legible "no CI configured yet" notice, never an
  apparent hang.
- **Provenance, stranger-resolvable.** The epic template's own
  `design-brief:` marker points at this ADR — a repo-resident, public
  record any adopter can open — rather than only at a private design note;
  the private note remains linked as author provenance.
- **Reuse, not reimplementation.** The epic's GitHub/CI levels consume
  existing kernel seams (the managed-merge backend probe, the `checks`
  contract, the install-hygiene libraries) rather than reimplementing any
  of them — the epic is a delivery vehicle for existing kernel opinions,
  not a second mechanism.

## Consequences

- The adopter's first substantive interaction with the pipeline is also the
  interaction that makes the pipeline's own assumptions (protected branch,
  required status, merge queue) actually true for their repo — the demo and
  the setup are the same work.
- Every external write this epic makes is individually consented, with its
  consequence disclosed at the moment of asking, composed and confirmed
  once as a whole — never a timeout-consent, since none of these writes has
  a safe default to fall back on silently.
- The epic template, the engineering-principles file
  ([ADR-0009](0009-kernel-engineering-principles-layer.md)), and the spec
  edits that feed the epic's principles level into `/assess`/`/build` are
  separate, independently-tracked plan items; this ADR records the design
  decision and its shape, not the implementation of every consuming call
  site.
- A stranger who declines every level of the epic is left exactly where
  they started, minus one durable, tracked re-offer pointer naming what's
  still unconfigured — the decision never leaves an adopter's repo worse off
  or in an ambiguous half-configured state.
- This is an additive change (CHANGELOG additive, no BREAKING): existing
  operator repos are unaffected outside the epic they explicitly consent to
  run.
- **Accepted gap: this epic's API-state writes are not revertible by a PR
  revert, and `eject` does not cover them** (recorded with the
  temperloop#796 amendment above). Everything this epic applies to GitHub —
  default-branch protection, head-branch auto-delete on merge, and arming a
  merge queue — is **API state on the remote repository**, not a tracked
  file. Reverting the PRs `/build` opened for this epic restores the repo's
  *files* and changes none of it: a protected branch stays protected, an
  armed queue stays armed. Nor does `temperloop eject` revert it. `eject` is
  manifest-driven — it reverts what is recorded in `.temperloop/config`'s
  `installs` array, and `temperloop init` is that file's sole writer. This
  epic's items run under `/build`, which deliberately has **no** write
  channel into `.temperloop/config` (adding one would break its sole-writer
  contract and open a back-channel from the build machinery into the
  bootstrap layer), so nothing this epic applies is ever recorded there for
  `eject` to find. State it plainly rather than implying otherwise:
  **undoing this epic's GitHub writes is a manual operation** — turn off
  branch protection, auto-delete, and the merge queue in the repository's
  own settings. The mitigation is at consent time, not revert time: every
  one of these writes is individually consented with its consequence
  disclosed at the moment of asking, and composed into one change-set the
  adopter confirms once as a whole (the two bullets above).

  **That mitigation is implemented in the artifacts the adopter actually
  reads, not merely asserted here** — an accepted gap disclosed only in a
  maintainer-facing ADR is papering over it, not disclosing it. Three
  surfaces carry it: each A2 question and the A3 Actions branch in
  `claude/templates/first-epic-setup.md` carries an explicit **`Undo:`**
  clause naming the repo-settings path and stating that `temperloop eject`
  does not revert it; that template's § Decline floors scopes its "nothing
  can leave your repo worse off" claim to match; and this state is
  enumerated as its own **scope (e)** both in `bin/README.md` § Uninstall
  and in `eject.sh`'s `print_uninstall_bullet`, which prints on *every*
  successful eject — so a clean `all N install(s) reverted` can never be
  read as "back to how you found it".

  `eject` remains complete for the surface it *does* own — a pre-scope-down
  `init`'s recorded labels, required checks, board, and proposal PRs, whose
  entries stay in `.temperloop/config` at schema 1 and stay revertible.
