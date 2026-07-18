---
title: "0008: reviewer-routing.tsv is the single source for the extension axis only"
---

## Status

Proposed

## Context

epic: temperloop#538

The language-reviewer catalog (ADR 0007) introduces a coverage scan that must
know which reviewer covers which file type, and `build.md`'s change-kind routing
already encodes an extension → reviewer map inline in prose (at ~line 534). With
two consumers of the same mapping, a single source of truth is needed so they
cannot drift.

The tempting framing is "extract the whole routing map into one table." But the
routing at `build.md:534` is not a pure extension → reviewer lookup. It also
branches on: a change *kind* that has no file extension (`architectural` →
`architecture-reviewer`); a path glob *with an exception* (`docs/**` →
`docs-reviewer`, except `claude/commands/*.md` → `workflow-reviewer`); a
*multi-match* case ("a change touching both classes runs both"); a per-item
`review:` override; and a mandatory-not-advisory distinction for
`claude/commands/*.md` (temperloop#1007). A flat extension-keyed table can
represent none of the kind/exception/override/cardinality axes.

Claiming the tsv is the single source of truth for *all* routing would therefore
be an overclaim: the drift guard would silently cover only the extension subset
while the rest stayed prose, and the "no duplicated map" test would have an
ambiguous scope (the `architectural` route has no extension to compare).

## Decision

`workflows/scripts/config/reviewer-routing.tsv` is the single source of truth for
the **extension/path-glob → reviewer axis only** — explicitly and by design, not
by omission.

- The tsv holds extension and glob routes (`.py` → python-reviewer, `docs/**` →
  docs-reviewer) and the catalog-agent path for each reviewer. It carries no
  per-checkout activation state — activation lives solely as symlink/copy
  presence in the gitignored `.claude/agents/`.
- The non-extension routing logic — the `architectural` kind route, the
  `docs/**`-vs-`claude/commands/*.md` exception, the `review:` override, the
  run-both multi-match, and the temperloop#1007 mandatory-workflow-reviewer
  contract — stays prose-resident in `build.md`.
- `build.md`'s routing text cites the tsv for the extension axis; the mechanical
  check is a prose-reference lint (the `check-knob-prose.sh` shape — the text
  points at the tsv and the old inline extension list is gone), NOT a runtime
  behavioral-equality test. The architectural branch is explicitly out of the
  lint's scope.

## Consequences

- The drift guarantee is honest and bounded: the tsv + coverage scan + `build.md`
  cannot drift on the *extension* axis; the other axes remain prose and are not
  claimed to be drift-guarded.
- A future contributor tempted to push kind/override/exception rules into the tsv
  has a recorded reason not to (the schema deliberately does not model them);
  widening the tsv's scope is a conscious later decision, not an incremental
  drift.
- Adding a language later is one tsv row + one catalog rubric; changing the
  non-extension routing stays a `build.md` prose edit reviewed by
  `workflow-reviewer`.
