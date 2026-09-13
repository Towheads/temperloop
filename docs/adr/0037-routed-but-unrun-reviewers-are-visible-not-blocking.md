---
title: "0037: A routed-but-unrun reviewer is made visible, not blocking"
---

## Status

Accepted

## Context

`/build` §3e's pre-push review — Step 3e of `claude/commands/build.md`, the
reviewer pass that runs before a worker's branch is pushed — is a **mandatory**
pipeline step, and the
per-item tally `review: { ran, skipped, mandatory_ok }` that `park()` returns
is its declared **execution signal** under `claude/CLAUDE.kernel.md`
§ Mandatory-step birth rule.

That signal covered one route out of twelve. `determineReviewers()` in
`claude/workflows/build-level.mjs` sets `mandatory: true` only for
`workflow-reviewer` on a `claude/commands/*.md` diff (foundation#1007 — the
command-doc mandatory route); every
reviewer routed by the extension axis of
`workflows/scripts/config/reviewer-routing.tsv` — `shell-reviewer` for `.sh`,
`typescript-reviewer` for `.mjs`, and the rest — was never flagged mandatory.
So `mandatory_ok` read `true` even when a routed reviewer resolved and then did
not run: the gate reported clean while the shell diff went unreviewed.

This was live, not theoretical. In one session the §3e shell review failed to
run six times across three items (temperloop#1982 — six unrun shell reviews),
and every instance was
caught by a human reading the reviewer roster — never by the tally. A signal
that cannot go false for eleven of the twelve routes it covers is not
discharging the birth rule; it is the narrower version of the failure the rule
exists against, something observable that proves the step ran for one reviewer
and silently vouches for the rest.

issue: Towheads/temperloop#1984 — mandatory_ok misses tsv-routed reviewers.

## Decision

`reviewTally()` gains a second, **weaker** field alongside `mandatory_ok`:

```
review: { ran, skipped, mandatory_ok, routed_not_run }
```

`routed_not_run` is the distinct set of reviewer names the routing resolved
that did not run — mandatory or not, across every round (the original 3e pass
plus any CI-fix re-review). It is a **visibility** field: nothing in the
pipeline blocks, loops back, or refuses on it. The closing invariant is that
`routed_not_run` is non-empty exactly when `skipped` is, so the tally can never
read fully clean while any routed reviewer was skipped. `/build` Step 6's
review summary line renders it beside the existing `mandatory_ok` line.

The `claude/commands/*.md` → `workflow-reviewer` mandatory rule is untouched:
`determineReviewers()` still sets `mandatory: true` for exactly that route, and
`mandatory_ok: !skipped.some((s) => s.mandatory)` is unchanged, character for
character (it is the registered ANCHOR — the literal substring the registry's
validator matches to detect a reworded declaration — of this step's row in
`workflows/scripts/config/mandatory-step-registry.tsv`).

**Rejected: marking every tsv-routed reviewer mandatory.** This is the stronger
signal, and it was rejected on kernel principle 7 (`claude/engineering-principles.md` § 7,
Advisory over enforced discipline — weigh a hard gate's own cost before making
it one). A per-language
reviewer is *routinely* absent by design: ADR 0007 ships the seven-language
roster as an **inert kernel catalog**, and a consuming checkout activates only
the reviewers it opts into. Under option 1, the very first `.py` or `.go` file
a repo that never activated `python-reviewer`/`go-reviewer` touches would
report `mandatory_ok: false` on every item forever — a gate red in the ordinary
case rather than the pathological one, which trains readers to ignore it and
takes `mandatory_ok`'s real signal down with it.

**Rejected for now: mandatory-ness as a tsv column** (option 3 in the issue).
It is the right shape for a repo that *has* activated a reviewer and wants it
enforced, but it is a wider change — a new column, three consumers of the file
to update, and a per-repo policy decision to make — with no demand behind it
yet. `routed_not_run` is a strict prerequisite for it either way: you cannot
choose which routes to enforce until you can see which ones did not run. Left
as follow-on work.

## Consequences

**Benefits.** The hole closes for all twelve routes at once, with no new
failure mode: a skipped `shell-reviewer` is named in the item's own parked
record and in the run's Step 6 summary, where the six-unrun-reviews incident
would have been visible in the machine's own output rather than depending on a
human noticing the roster. `mandatory_ok` keeps its narrow meaning and stays
credible precisely because it did not widen.

**Costs.** The cost of the advisory choice is exactly that it is advisory: a
routed reviewer can still be skipped on an unattended run, and nothing stops
that item merging. The tally now *says so*, but saying so only helps if someone
reads the Step 6 summary — this trades a false clean signal for a true signal
that can be ignored, which is a real reduction in force and is accepted
knowingly. A consuming repo that wants enforcement has no mechanism here; that
is option 3's job.

**Follow-on work.** If the advisory field proves to be ignored in practice —
measured by routed-but-unrun reviewers recurring across merged PRs — the
escalation path is option 3 (per-row mandatory-ness in
`reviewer-routing.tsv`), not a blanket option 1, so a repo enforces only the
reviewers it has actually activated.
