---
title: async-workflow-health
slug: async-workflow-health
---

## Problem

Nothing in this repo surfaced a **red asynchronous workflow**, so a broken
quality gate could sit on `main` for weeks with nobody knowing.

"Asynchronous" here means *not triggered by a pull request* — a nightly
`schedule`, a release-tag `push`, a `workflow_dispatch`. A PR-gated workflow
reports to the person who opened the PR and nobody has to remember to look. An
asynchronous one reports to nobody in particular.

Both observed instances were discovered while **already red**, weeks in, never
at the moment they turned:

- **`install-tier2.yml`** ran five red weeks. It had leaned on GitHub's
  built-in *scheduled*-workflow-failure email, and that mitigation evaporated
  silently when its weekly cron was retired (`1ecb118`, 2026-08-13).
  [`ci-install-tier2.md`](ci-install-tier2.md) states the consequence outright:

  > The retired `schedule` trigger leaned on GitHub's built-in
  > *scheduled*-workflow-failure notification, which stopped applying when the
  > cron went.

- **`nightly-macos.yml`** ran seven consecutive red nights (2026-08-14 through
  2026-08-20) with no mitigation of any kind. Its own header says so in as many
  words: "There is NO paging, no Slack, no webhook." That workflow is the only
  thing standing between a macOS/BSD-dialect regression and the default branch,
  because macOS was deliberately dropped from the pre-merge gate
  (temperloop#963, macOS dropped from pre-merge gating).

Two consequences follow, and both shape the design. First, the detector must
report a **state**, not a **transition**: a transition-only detector would have
caught neither instance, since both were already red when found. Second, the
alarm cannot be wired per-workflow — a per-workflow mitigation is exactly what
rotted twice.

## How it works

`workflows/scripts/async-workflow-health.sh` renders one bullet block naming
every asynchronous workflow's current state. Its `--format brief` output is
embedded in the kernel telemetry brief's **"1. Attention — what needs you now"**
section, which `/check-in` renders every day and `/telemetry` renders on demand.
No new surface was invented for it; it wires into the one that already exists
and is already read.

**Discovery, not a list.** The detector reads every file in
`.github/workflows/` and classifies it from that file's own `on:` triggers:

| Class | Triggers | Why |
|---|---|---|
| Synchronous — out of scope | `pull_request`, `pull_request_target`, `merge_group`, a `push` restricted to `branches:`, a bare `push:` | The verdict lands in front of whoever just pushed |
| Asynchronous — in scope | `schedule`, `workflow_dispatch`, `repository_dispatch`, `workflow_run`, a `push` restricted to `tags:`, **and any trigger the classifier does not recognise** | Nobody is necessarily watching |

A workflow is in scope if it has **at least one** asynchronous trigger, and its
run history is then filtered to those asynchronous **events** only — so a hybrid
workflow's PR runs can never mask its scheduled leg. An `on:` block the
classifier cannot parse is treated as asynchronous.

**The registry records disposition, not membership.**
`workflows/scripts/config/async-workflow-registry.tsv` says, per discovered
asynchronous workflow, whether a red run raises an `alarm` or is deliberately
`exempt` (with a mandatory reason). It does **not** tell the detector which
workflows exist. That split is what makes the mechanism generic: a third
asynchronous workflow added tomorrow and forgotten in the registry is reported
as `UNREGISTERED` on the same line a red run would be reported on.

**Everything fails closed.** Each of these renders an alarm rather than a
silent pass: an asynchronous workflow with no registry row; an absent, empty, or
unreadable registry; a registry row naming a workflow file that no longer
exists (`STALE-ROW`); an unparseable `on:` block; and a run history the detector
could not read at all (`UNKNOWN` — "this workflow's state went UNCHECKED",
never a fabricated green). An empty run history is `UNKNOWN` too, for the same
reason: nothing to judge means nothing is being verified.

**Verdict.** For each registered workflow, the newest *completed* asynchronous
run decides the state, and the detector counts **consecutive** non-success runs
backwards from it — so an already-red workflow reports its true age
(`7 consecutive failed schedule run(s)`) rather than looking like a fresh
one-off.

**Degradation is legible and total.** No `gh`, no `jq`, an unreadable registry,
a failed API call — each renders a `skipped — <reason>` or `UNKNOWN` line naming
what went unchecked. Every path exits 0: a status readout must never be able to
fail the check-in that reads it.

## Integration

- **Read surface**: `workflows/scripts/telemetry-brief.sh` § 1 Attention invokes
  the detector and prints its brief output. This is the brief's **one** live
  read — a workflow's redness exists only in GitHub's run history and no
  emitter can write it into the raw lake — so the section's `source:` line marks
  it `LIVE (async-workflow-health.sh, not a raw stream)` rather than letting it
  pass for a stream. The call is `|| true`-guarded on top of the detector's own
  exit-0 contract.
- **Consumes**: `.github/workflows/*.yml`, the disposition registry, and
  `gh run list --workflow <file>`. Adds no parallel copy of anything.
- **Deliberately does not replace** `install-tier2.yml`'s two existing
  workflow-specific mitigations (the tag pusher's own Actions notification;
  `VERSIONING.md` step 4 blocking `make update-kernel` on a green run). The
  generic alarm is additive to both.
- **Tests**: `workflows/scripts/tests/test_async_workflow_health.sh`, a
  `KERNEL_GATES` entry in `scripts/quality-gates.sh`. Every case runs against
  recorded `gh run list --json` fixtures with a *poisoned* `gh` on `PATH`, so a
  test that reached the live API would be caught rather than merely be slow.

## Resource impact

One `gh run list` REST call per registered asynchronous workflow per brief
render — two calls in this repo today, at `ASYNC_WORKFLOW_RUN_LIMIT` runs each,
which is one page. That shares the 5,000-requests/hour REST bucket described in
`AGENTS.md`, and is negligible against it: `/check-in` renders the brief roughly
once a day. Under `ASYNC_WORKFLOW_RUNS_DIR` (the fixture seam) no network call
is made at all, which is how the whole test suite runs offline.

Each live call is bounded at `ASYNC_WORKFLOW_GH_TIMEOUT` seconds through the
shared `run_with_timeout` watchdog (`workflows/scripts/lib/portable-timeout.sh`,
temperloop#256, which exists because stock macOS ships no `timeout` binary). The
bound is what makes this detector safe to put on a daily read surface: the
caller's `|| true` fence catches a *failed* `gh` call but not a *hung* one, and
a bound that fires falls through to the same `UNKNOWN` branch a failure takes —
so a stalled network reports legibly unchecked rather than blocking the brief.

## Telemetry

None. The detector emits no raw-lake stream: it *reads* live state and renders
it, and the state it reads is already durable in GitHub's own run history.
