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

One workflow, `.github/workflows/install-tier2.yml`, triggered by a release
**tag push** matching `v*.*.0` (minor and major cuts; a patch tag
deliberately does not fire it) and by `workflow_dispatch` (manual — an
ad-hoc drift probe during a release gap, or a pre-tag dry run against
`main`). Never `pull_request`/`merge_group`/push-to-a-branch — a PR
touching this workflow cannot demonstrate a green run; verification is a
manual `workflow_dispatch` after merge, with `DEMO_REPO_TOKEN` in place.

The tag is the trigger because it always was, implicitly:
`bin/bootstrap.sh` pins a fresh install to the newest `v*` tag it can see
(`git tag -l 'v*' --sort=-v:refname`), **not** to the ref this workflow
checked out — so the retired weekly cron was already testing the last
release tag rather than `main`, at an arbitrary moment. Triggering on the
tag makes the timing match semantics that were already there
(temperloop#1425). It also means the `fetch-depth: 0` checkout is
load-bearing: it is what puts the tags in the tree bootstrap sorts over.

Because the tag is pushed by hand (VERSIONING.md § Cutting a release step
3), the run necessarily starts *after* the tag exists. It therefore gates
**propagation, not tagging**: step 4 of that procedure blocks `make
update-kernel KERNEL_TAG=v<new>` on a green run here.

**What moving off the weekly cron cost.** The cron was the only thing
catching drift *external* to this repo — a GitHub API shape change, a `gh`
CLI update, a runner-image change, the demo repo rotting — none of which
involve a commit here, and none of which any per-PR gate can see. That
drift now surfaces at cut time instead of within a week. At this repo's
release cadence (8 minors in the 12 days to v0.29.0) the gap is days, not
months; during a long release gap, fire a `workflow_dispatch` by hand
rather than reading silence as health.

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
   ref actually being release-gated. The **version leg** then asserts the
   installed CLI reports the version embedded in its shipped files (never
   `dev`), and — on a tag-triggered run only — that the tag bootstrap
   pinned to *is the tag that triggered the run*. That second assertion is
   what makes this a release gate rather than a run that merely happens
   near a release: bootstrap picks the newest tag by version sort, not by
   `$GITHUB_REF`, so without it a run triggered by `v0.30.0` could
   silently have exercised something else. It also absorbs the one glob
   wart worth knowing about — GitHub tag filters let `*` match dots, so
   `v*.*.0` would additionally match a hypothetical `v0.29.10`.
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
   naming exactly which leg(s) (`init`/`eject`) failed, so a failed run is
   legible at a glance instead of requiring a log dig. Failure reaches a
   human two ways: the run is triggered by the operator's own `git push
   origin v<new>`, so GitHub's Actions failure notification goes to the
   person who just cut the release; and VERSIONING.md step 4 makes reading
   this run an explicit precondition of propagating, rather than a passive
   notification someone might not be watching for. (The retired `schedule`
   trigger leaned on GitHub's built-in *scheduled*-workflow-failure
   notification, which stopped applying when the cron went.)

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
not billed). One run per minor/major release tag, plus the occasional
manual `workflow_dispatch`. Stated plainly: at this repo's release cadence
that is **more** runs than the weekly cron it replaced, not fewer — the
change buys relevance (the run tests the artifact actually shipping), not
CI minutes. The absolute cost stays negligible either way: a single
~10-minute ubuntu job with no billed LLM call. `concurrency: { group:
install-tier2, cancel-in-progress: false }` serializes runs so two
in-flight round trips never race the same remote demo-repo state — still
correct at release cadence, and the reason a per-PR trigger would not be.

Known limitation: if a run's `init` leg succeeds (opening a proposal
branch/PR) but its `eject` leg then fails to revert it (e.g. a transient
`gh` API error), the demo repo is left with an orphaned branch/PR until a
human investigates — the job's own verdict step fails loudly in exactly
this case (`eject` outcome != success), so this is a visible, not a
silent, failure mode.

**Accepted coverage gap (ADR 0025, amended by temperloop#1234).** This
workflow never creates or deletes a repository — the demo-repo token is
scoped to one pre-existing repository and structurally cannot do either.
Consequently `temperloop testbed` and its teardown leg have NO automated
coverage here: they are exercised only by their own unit tests (a
faked `gh`) and by temperloop#1240's one-time executed run. See
`Decisions/temperloop - CI round trip keeps a persistent demo repo, not
per-run create-delete` and the amended ADR 0025 consequence for the full
rationale.

## Telemetry

None.
