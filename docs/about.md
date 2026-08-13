---
title: About TemperLoop — where it came from and who's behind it
---

# About TemperLoop

This page is the origin story, the thesis behind TemperLoop, and the kinds
of collaborators the project is looking to work with next. For what the
product *does*, start at the [README](../README.md) or
[`docs/pitch.md`](pitch.md) instead.

## The origin story

TemperLoop's author set out to build an N-tier music event discovery app in
his spare time and ended up compulsively building this instead.

The reason: AI-assisted development kept demanding the same mind-numbing
supervision — constant code reviews, constant clarifications. Without
hyper-vigilance, the agents drifted, producing misaligned and poor-quality
work. Twenty-plus years of SDLC experience said this was a solved problem:
engineering organizations keep large numbers of fast, fallible contributors
coherent with process — issue tracking, contract-scoped work, review gates,
protected branches — not with vigilance.

**The thesis:** embed that experience into tools, and agent-driven
development can meet or exceed the standards a careful human holds by hand.
The standards TemperLoop is built to enforce:

- **Respect the operator's time** — identify, cluster, and surface critical
  decisions early; answer operational questions from memory, specs, and the
  tracker, escalating only the foundational ones.
- **Keep blast radius low** — conservatively size every task, isolate every
  worker, test every change.
- **Enforce governance** — every change traceable, gated, and reviewed.
- **Stay aligned** — every change measured against the existing vision,
  design, and contracts, not just against "does it compile."
- **Spend efficiently** — invest tokens up front in planning and review to
  avoid the expensive rework later, and route each piece of work to the
  cheapest model that fits it.

[`docs/principles.md`](principles.md) is the full statement of the thesis,
with each principle pinned to the mechanism in this repo that embodies it.

## Looking for collaborators

This project is being refined in the open, and the author is looking for
people to test-drive it and report back — if you have a new or existing
project and want to see what it's like to have a virtual engineering
process managing your agent-driven work, reach out (the
`temperloop feedback` command sends a message straight to the maintainers).

The larger vision reaches beyond software: the same
issue-tracked, gated, reviewable pipeline shape applies to any domain that
turns a backlog into reviewed work products. The author would especially
like to compare notes with:

- **Leaders** implementing AI workflows in non-software domains.
- **Consultants** who want to give clients clear visibility into work
  completed and its cost. (An aspiration this project is building toward,
  not a shipped capability — today's honest state of cost tracking is in
  [`docs/cost-and-autonomy.md`](cost-and-autonomy.md).)
- **Scientists** managing research, data synthesis, or report generation.
- **Civic and non-profit organizations** handling data analysis, reporting,
  and operations.
- **Government agencies** working through municipal backlogs.
- **Finance leaders** pipelining financial reports.
- **Members of technical standards consortiums.**

The working arrangement on offer: help solving concrete problems in your
space, in exchange for visibility into the constraints and processes your
domain brings.

---

*Written by claude-fable-5 on 2026-08-13.*
