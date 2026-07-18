---
title: ci-install-tier2
slug: ci-install-tier2
---

## Problem

Tier-1 (`docs/features/ci-install-lifecycle.md`) proves the install/uninstall
machine-surface lifecycle hermetically — a `file://` bare clone, a sandboxed
`HOME`/XDG tree, zero real network — which is exactly right for a per-PR
gate (fast, free, deterministic). What it can't prove is that the actual
newcomer ADOPTION path (`temperloop try` -> `temperloop init` -> `temperloop
eject`) still works against a REAL target repo: a real `gh` hitting a real
GitHub API, a real `claude -p` judgment call, real branch-protection/label
writes, a real proposal PR opened and then reverted. That's a materially
different failure surface (auth scoping, API shape drift, rate limits, a
live model call actually producing usable output) that a hermetic sandbox
structurally cannot exercise. ADR K164 D6 calls this the tier-2 leg —
required before a release ships, deliberately never per-PR (cost + shared
remote state; see the workflow file's own header for the full rationale).

## How it works

One workflow, `.github/workflows/install-tier2.yml`, triggered only by
`schedule` (weekly, Monday 05:00 UTC) and `workflow_dispatch` (manual —
run this by hand before cutting a kernel release tag; that's its
release-gate role). Never `pull_request`/`push`/`merge_group`.

1. **Preflight** — checks out this repo, then hard-fails with a named
   missing-secret list if either required secret
   (`ANTHROPIC_API_KEY` — bills the live `claude -p` shadow-triage call;
   `DEMO_REPO_TOKEN` — a `gh`-scoped PAT with write access to the shared
   demo repo, since the default per-repo `GITHUB_TOKEN` can't reach a
   different repo) is absent, rather than letting the round trip degrade
   silently later.
2. **Bootstrap** the `temperloop` CLI from THIS checkout (`bin/bootstrap.sh`
   pointed at a `file://` URL of the just-checked-out tree) — the same
   bootstrap code path a curl-pipe-sh newcomer runs, exercised against the
   ref actually being release-gated.
3. **Reset** the shared demo repo (`workflows/scripts/demo/
   seed-demo-repo.sh --reset`) to a known baseline, then clone it locally —
   the newcomer's own first `git clone`.
4. **The round trip** — `temperloop try`, `temperloop init
   --yes-required-check --yes-labels --no-board`, `temperloop eject --yes`,
   each run as its own step with output captured to a log. `try`/`init` are
   BOTH deliberately fail-open at the shell-exit-code layer in their own
   design (a real `gh`/`claude` failure prints `skipped — <reason>` or
   `FAILED — <reason>` and still exits 0 — see those scripts' own headers,
   this is the right default for an interactive stranger on a flaky
   connection). This workflow can't rely on exit codes alone, so each step
   greps its own captured log for those two markers and turns a soft
   degrade into a hard step failure — the whole point of tier-2 is proving
   the LIVE path ran to completion, not that it degraded gracefully.
   `continue-on-error: true` on the `try`/`init` steps means `eject` always
   runs afterward and attempts to revert whatever `init` did manage to
   apply, even if an earlier leg failed partway (never leaving orphaned
   labels/required-checks/proposal-PR branches on the shared demo repo).
5. **Verdict** — a final always-run step writes a leg-by-leg outcome table
   to the job summary and fails the job with an explicit `::error::` line
   naming exactly which leg(s) (`try`/`init`/`eject`) failed. `on: schedule`
   failures already trigger GitHub's built-in scheduled-workflow-failure
   notification; this step is what makes a *look* at that failed run
   immediately legible instead of requiring a log dig.

## Integration

A standalone workflow file, deliberately never added as a step to
`ci.yml`'s `checks` job (see that file's own comment: "your workflow is a
SEPARATE file, never added to this one") or to `scripts/quality-gates.sh`
(which is the per-PR, zero-network gate set — this is the opposite of
that). Consumes, and adds no parallel copy of: `bin/bootstrap.sh`, the
`temperloop try`/`init`/`eject` subcommands, and
`workflows/scripts/demo/seed-demo-repo.sh`. Mirrors `docs-pages.yml`'s
structural precedent for a non-PR workflow (explicit minimal
`permissions:`, its own `concurrency` group, a header comment stating why
it's excluded from the PR gate).

## Resource impact

Real network + a real billed LLM call, by design — this is the entire
point of the tier-2 leg (tier-1 already covers the hermetic, free case).
Bounded: `temperloop try`'s live `claude -p` shadow-triage call is capped
at `TRY_CLAUDE_MAX_BUDGET_USD` = $1.00 per run (≈330,000 tokens at Claude
Sonnet 5 list price, if the whole cap were spent — see
`docs/cost-and-autonomy.md` for the conversion basis)
(`bin/lib/cost-estimates.conf`); `init`/`eject` make only plain `gh` API
calls (free, rate-limited but not billed). One run/week (plus occasional
manual `workflow_dispatch` before a release) keeps aggregate spend
negligible. `concurrency: { group: install-tier2, cancel-in-progress:
false }` serializes runs so two in-flight round trips never race the same
remote demo-repo state.

Known limitation: if a run's `init` leg succeeds (applying real API state)
but its `eject` leg then fails to revert it (e.g. a transient `gh` API
error), the demo repo is left with orphaned state until a human
investigates — the job's own verdict step fails loudly in exactly this
case (`eject` outcome != success), so this is a visible, not a silent,
failure mode.

## Telemetry

None.
