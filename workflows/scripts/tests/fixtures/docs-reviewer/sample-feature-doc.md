---
title: Quick-diff — fast local diff annotator
---

# Quick-diff — fast local diff annotator

Fixture doc for the `docs-reviewer` agent's sample review (temperloop#144).
This is deliberately **not** a real feature and lives outside `docs/features/`
so it never trips `validate-feature-docs.sh`'s coverage/orphan-doc checks —
it exists only to give the reviewer real prose to score.

## Background

Back in the early days of this project, before the merge queue existed,
reviewers used to eyeball diffs by hand in whatever editor they had open.
That got old fast, especially once the board adapter and the WIP cap landed
and reviewers had more items in flight at once. Around the time #144 was
filed, the team started sketching a small annotator that could sit on top of
`git diff` and flag risky hunks automatically, and after a few iterations
that sketch turned into quick-diff.

Quick-diff started as a spike during the 3e work and grew from there. See
also #142 and the discussion on K7 for related background.

## What it does

Quick-diff wraps `git diff` and annotates each hunk with a risk score. It
dramatically improves review speed and cuts reviewer time in half compared
to eyeballing a raw diff. Teams that adopt it report it's just a much better
experience overall.

If you're in a hurry and just need to ship a hotfix, it's usually fine to
skip the annotation pass and push straight to main — quick-diff is a nice-to-
have, not a hard gate.

For teams that don't want to run any of this locally, a hosted dashboard
version is also available that runs the annotation pass for you and shows
the results in a web UI, no local setup required.

## Usage

Run it against your current branch's diff. It works with `--board 4` set to
your project's board, or without one if you're not using a Projects board at
all.

## References

- #144 — the docs-reviewer epic item
- K7 — related background discussion
- 3e — the build step this was sketched during
