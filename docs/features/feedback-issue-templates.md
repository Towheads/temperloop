---
title: feedback-issue-templates
slug: feedback-issue-templates
---

## Problem

Before this feature, a stranger who hit a bug, a papercut, or a question
against this repo had no structured way to file it: a bare "New issue"
button with no guidance meant no reliable label, no privacy warning, and no
stated expectation for what happens after they hit submit. Concretely that
meant three failures at once — the issue could easily land with no
`fnd:status:backlog` label and sit invisible to `/triage`'s Backlog sweep
(`workflows/scripts/board/ISSUES-ONLY-BACKEND.md`); nothing warned a
reporter against pasting private repository content (tokens, hostnames,
private issue/PR text) into a form that's public once this repo is; and the
reporter had no way to know whether their issue would ever be looked at.

## How it works

Three GitHub issue-forms templates under `.github/ISSUE_TEMPLATE/` — `bug
report`, `friction / rough edge`, and `question` — each stamp two labels at
filing time: a category label (`bug` / `friction` / `question`) and
`fnd:status:backlog`, the label this repo's issues-only tracker backend
(board 7) uses to mean "in Backlog" (see `ISSUES-ONLY-BACKEND.md`'s `fnd:`
label vocabulary). Stamping `fnd:status:backlog` directly at filing time is
what makes bullet 1 of temperloop#427 true without depending on a human or
script to label the issue after the fact: `/triage`'s Step 1 "Adapter A"
Backlog read (`claude/commands/triage.md`) keeps any board-7 item whose
`.status` resolves to `Backlog` via that label, so a freshly-filed template
issue is swept the very next time `/triage` runs against board 7 — no
separate capture step needed.

Each template's markdown preamble carries two things verbatim, visible
before any input field: an explicit warning against pasting private
repository content (tokens, credentials, hostnames, private issue/PR text,
logs from a non-public checkout), and a stated acknowledgment of what
happens next — the issue lands in Backlog under `fnd:status:backlog` and is
swept the next time `/triage` runs, with a pointer to
`docs/features/funnel-driver.md` for the optional scheduled-tick machinery
some checkouts run this under. This is the documented-cadence route rather
than a promised SLA or an auto-ack bot, because this repo makes no promise
of a fixed response time — only that nothing filed through the form is
silently dropped from the sweep.

`.github/ISSUE_TEMPLATE/config.yml` sets `blank_issues_enabled: false`
deliberately: a blank issue skips the template entirely and would carry
neither the category label nor `fnd:status:backlog`, defeating bullet 1 for
exactly the issues that took the blank path. Forcing every filer through one
of the three forms is what makes the routing guarantee total rather than
best-effort.

## Integration

Consumes: the `fnd:status:backlog` label already defined by the
issues-only tracker backend (`ISSUES-ONLY-BACKEND.md`) and the `bug`/
`question` labels already present on the repo (`friction` was added
alongside this feature, same color-scheme family as the existing category
labels).

Produces: GitHub issues carrying labels `/triage`'s Step 1 Backlog read
already consumes — no new adapter code, no new label vocabulary beyond the
one `friction` addition. Downstream, `/triage` treats a template-filed
issue exactly like any other Backlog survivor (cull / collapse / group /
route), so this feature's entire footprint is at the filing boundary.

## Resource impact

None. Issue-forms YAML is rendered client-side by GitHub's own issue
picker; there is no workflow, no webhook, no network call, and no CI job
added by this feature. The one one-time side effect was creating the
`friction` label on the live repo (`gh label create`), a static label
definition, not a running process.

## Telemetry

None. A filed issue is observed the same way any other Backlog issue is —
via `/triage`'s own sweep output and the existing `command-run`/
`issue-touches` telemetry streams (`docs/features/telemetry.md`) once it's
processed. This feature adds no new emit site of its own.
