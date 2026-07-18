---
title: "0007: Language reviewers ship as a kernel catalog, activated opt-in per repo"
---

## Status

Proposed

## Context

epic: temperloop#538

temperloop ships process discipline but no language-aware code review out of
the box. `build.md`'s change-kind routing already names per-language reviewers
(`.py` → `python-reviewer`, `.sh` → `shell-reviewer`), but no such reviewer
ships in this repo — the routing is a dangling reference, and any adopter who
wants review on their own code must hand-author the reviewer first. That
friction lands at exactly the moment the tool should be delivering value, and
it erodes the "org-grade process without an org" promise `docs/who-its-for.md`
is built around.

Two placements were weighed against the kernel/overlay routing rule
(`claude/CLAUDE.kernel.md`). A prior convention put `python-reviewer` downstream
in a consuming repo (foundation), on the reasoning that application-code
reviewers are adopter-specific content. The competing subtraction alternative
was to ship a single generic, language-agnostic `code-reviewer` — one artifact,
no scan — rather than a per-language set.

The historical objection to a shipped roster was "dead weight": a `.py`-routed
reviewer forced onto a Go shop is uninstallable cost for a stack that never
uses it. That objection is specifically about *unconditional activation*, not
about *shipping*.

## Decision

Language reviewers ship as an **inert kernel catalog**, activated **opt-in per
repo**, not always-on and not downstream-only.

- The reviewers live in the kernel (`claude/agents/reviewers/`) because the
  catalog reviews languages the kernel itself is written in (shell, python) and
  the activation/scan/doctor machinery is install-time kernel machinery a
  stranger's kernel-only checkout needs. Canonical reviewers belong upstream and
  flow down; the downstream-placement convention is superseded (this is its
  first formal record — no prior `Decisions/` note existed to link).
- "Inert" means the catalog reviewers are NOT deployed into a live
  `.claude/agents/` until activated: an un-activated reviewer is never
  registered, never probed, and costs nothing — which neutralizes the dead-weight
  objection without giving up on shipping.
- Activation is opt-in at install: a coverage scan detects the repo's material
  languages and offers only the matching reviewers, deferring to any reviewer the
  user already defined. Adoption is advisory and per-checkout, never a hard gate
  and never imposed on teammates (`.claude/agents/` is gitignored/per-checkout).
- v1 covers seven languages (Python, TS/JS, Shell, Go, Rust, Java, Swift); the
  accepted standing cost is maintaining seven real reviewer rubrics. Uncovered
  languages route to the existing capability-probe "bring your own" seam.

The single-generic-reviewer alternative was rejected: a language-agnostic
reviewer cannot apply the idioms, pitfalls, and tooling conventions (a Rust
borrow-checker smell, a shell quoting/`set -e` trap) that make a review useful.

## Consequences

- Seven reviewer rubrics become maintained kernel artifacts with an ongoing
  upkeep cost — accepted deliberately, not incidental.
- The kernel now carries application-code-review content, not only process
  machinery; the stranger-test justification is strongest for the machinery and
  kernel-own languages and leans on "any stranger might use" for the other four
  — an accepted, documented stretch.
- Adopters get language-aware review out of the box with a one-keystroke opt-in;
  the long-tail of uncovered languages is served by documenting the existing
  bring-your-own seam rather than by widening the catalog.
- Additive contract-surface change (CHANGELOG additive, minor version bump).
