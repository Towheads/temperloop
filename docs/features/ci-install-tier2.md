---
title: ci-install-tier2
slug: ci-install-tier2
---

## Problem

Tier-1 (`docs/features/ci-install-lifecycle.md`) proves the install/uninstall
machine-surface lifecycle hermetically — a `file://` bare clone, a sandboxed
`HOME`/XDG tree, zero real network — which is exactly right for a per-PR
gate (fast, free, deterministic). What it can't prove is that the CLI's
INSTALL and ADOPT-PATH round trip (`temperloop init` -> `temperloop eject`)
still works against a real target repo: a real `gh` hitting a real GitHub
API, a real proposal PR opened and then reverted. That's a materially
different failure surface (auth scoping, API shape drift, rate limits) that
a hermetic sandbox structurally cannot exercise. ADR K164 D6 calls this the
tier-2 leg — required before a release ships, deliberately never per-PR
(shared remote state + flakiness surface; see the workflow file's own header
for the full rationale).

This workflow was re-scoped by temperloop#1234 (epic #1117) off the retired
`try` path and off a per-run disposable evaluation repo (`temperloop
testbed`), onto `init` -> `eject` against one persistent, narrowly-scoped
demo repo. `temperloop testbed` and its teardown leg are consequently NOT
covered here — see "Resource impact" for the accepted gap and ADR 0025 for
the full rationale.

## How it works

One workflow, `.github/workflows/install-tier2.yml`, triggered only by
`schedule` (weekly, Monday 05:00 UTC) and `workflow_dispatch` (manual —
run this by hand before cutting a kernel release tag; that's its
release-gate role). Never `pull_request`/`push`/`merge_group` — this item's
own PR cannot demonstrate a green run; verification is a manual
`workflow_dispatch` after merge, with `DEMO_REPO_TOKEN` in place.

1. **Preflight** — checks out this repo, then hard-fails if `DEMO_REPO_TOKEN`
   (a fine-grained PAT scoped to exactly one repository,
   `Towheads/temperloop-demo`, permissions Contents + Issues +
   Administration) is absent, and additionally probes it against the demo
   repo (`gh api repos/<demo repo>`) to catch an expired/revoked/mis-scoped
   token before the round trip depends on it. The default per-repo
   `GITHUB_TOKEN` can't reach a different repo, so a dedicated PAT is
   required. `ANTHROPIC_API_KEY` is not used anywhere in this workflow — it
   was consumed only by the now-removed `temperloop try` step, and neither
   `init` nor `eject` makes a model call.
2. **Bootstrap** the `temperloop` CLI from THIS checkout (`bin/bootstrap.sh`
   pointed at a `file://` URL of the just-checked-out tree) — the same
   bootstrap code path a curl-pipe-sh newcomer runs, exercised against the
   ref actually being release-gated.
3. **Clone** the persistent demo repo locally — the newcomer's own first
   `git clone`. There is no separate "reset the repo" step: `init`'s own
   idempotency probes and `eject`'s manifest-driven revert (next point) are
   what keep the repo at a reusable baseline run over run, so nothing here
   pre-mutates its content.
4. **The round trip** — `temperloop init` (with neither `--yes-first-epic`
   nor `--no-first-epic`, so its optional first-epic offer legibly skips
   under CI's ambient `GITHUB_ACTIONS` ; see the workflow file's own header
   for why this workflow deliberately leaves that offer un-requested rather
   than filing-then-closing an issue), then `temperloop eject --yes`, each
   run as its own step with output captured to a log. Both are deliberately
   fail-open at the shell-exit-code layer in their own design (a real `gh`
   failure prints `skipped — <reason>` or `FAILED — <reason>` and still
   exits 0 — see those scripts' own headers, this is the right default for
   an interactive stranger on a flaky connection). This workflow can't rely
   on exit codes alone, so each step content-scans its own captured log for
   a `FAILED` marker and turns that into a hard step failure — the whole
   point of tier-2 is proving the LIVE path ran to completion, not that it
   degraded gracefully. Unlike a `FAILED` marker, a `skipped —` line is NOT
   treated as fatal any more: this workflow's own choice not to request the
   first-epic offer makes one appear on every successful run, so scanning
   for it broadly would fail every green run. The `init` step instead
   asserts its **handoff marker** (`next step: …`) is present, proving the
   run reached the end of `init`'s contract rather than stopping short —
   the same stable marker `init.sh`'s own header and test suite pin, now
   asserted content-agnostically (it no longer requires the epic-specific
   `/assess --epic <N>` suffix, since the epic offer is intentionally never
   requested here). `continue-on-error: true` on the `init` step means
   `eject` always runs afterward and attempts to revert whatever `init` did
   manage to record, even if that leg failed partway (never leaving an
   orphaned proposal-PR branch on the shared demo repo).
5. **Verdict** — a final always-run step writes a leg-by-leg outcome table
   to the job summary and fails the job with an explicit `::error::` line
   naming exactly which leg(s) (`init`/`eject`) failed. `on: schedule`
   failures already trigger GitHub's built-in scheduled-workflow-failure
   notification; this step is what makes a *look* at that failed run
   immediately legible instead of requiring a log dig.

## Integration

A standalone workflow file, deliberately never added as a step to
`ci.yml`'s `checks` job (see that file's own comment: "your workflow is a
SEPARATE file, never added to this one") or to `scripts/quality-gates.sh`
(which is the per-PR, zero-network gate set — this is the opposite of
that). Consumes, and adds no parallel copy of: `bin/bootstrap.sh` and the
`temperloop init`/`eject` subcommands. Mirrors `docs-pages.yml`'s
structural precedent for a non-PR workflow (explicit minimal
`permissions:`, its own `concurrency` group, a header comment stating why
it's excluded from the PR gate).

## Resource impact

Real network, no billed LLM call (that surface was retired with the `try`
step). `init`/`eject` make only plain `gh` API calls (free, rate-limited but
not billed). One run/week (plus occasional manual `workflow_dispatch`
before a release) keeps this negligible. `concurrency: { group:
install-tier2, cancel-in-progress: false }` serializes runs so two
in-flight round trips never race the same remote demo-repo state.

Known limitation: if a run's `init` leg succeeds (opening a proposal
branch/PR) but its `eject` leg then fails to revert it (e.g. a transient
`gh` API error), the demo repo is left with an orphaned branch/PR until a
human investigates — the job's own verdict step fails loudly in exactly
this case (`eject` outcome != success), so this is a visible, not a
silent, failure mode.

**Accepted coverage gap (ADR 0025, amended by temperloop#1234).** This
workflow never creates or deletes a repository — the demo-repo token is
scoped to one pre-existing repository and structurally cannot do either.
Consequently `temperloop testbed` and its teardown leg have NO weekly
automated coverage: they are exercised only by their own unit tests (a
faked `gh`) and by temperloop#1240's one-time executed run. See
`Decisions/temperloop - CI round trip keeps a persistent demo repo, not
per-run create-delete` and the amended ADR 0025 consequence for the full
rationale.

## Telemetry

None.
