---
tags: [plan, project/temperloop]
date: 2026-08-15
source_kind: claude-stamped
source_session: "66988394"
source_model: claude-fable-5
last_verified: 2026-08-15
sources:
  - "#1412"
epic: 1412
status: done
---

# Model-comparison measurement integrity (epic #1412)

## Run status
run started 2026-08-15 · session 66988394 · level 0/2 active · items: 0 done / 0 parked / 0 in-flight / 0 skipped

## Problem

The model-comparison harness's own measurements are wrong or misleading: a timed-out candidate's real spend vanishes from every cost figure, the judge scores four code-level rubric dimensions without ever seeing the diff (and misattributes truth-partition paths to the candidate), default-model integration errors are attributed to model "unknown", and an unpriced run renders a headline cost of $0 rather than "could not price". Until these land, any figure the harness publishes — including the upcoming A/A validation run (#1262) — cannot be trusted to make the model-routing decisions it exists to inform.

## Summary

- **Spend that vanishes instead of being withheld-with-reason**
  - **L0** — count integration-errored/timed-out candidate records as unmeasured spend with a stated reason in the report's cost section (#1381)
  - **L0** — render `estimate_usd` as null with a stated reason when no model in the run is priced, never 0 (#1384)
- **The judge's input is structurally insufficient for its rubric**
  - **L0** — capture real diff text into the score record while the worktree is live, and give X/R buckets the candidate-vs-truth attribution N already has (split from #1382)
  - **L1** — feed the persisted diff text to the judge in a bounded prompt section with truncation disclosure (split from #1382)
- **Attribution and operator guidance that mislead**
  - **L0** — resolve the effective model pre-flight and thread it to the integration-error attribution record, replacing the `${model:-unknown}` flag fallback (#1383)
  - **L0** — re-state the replay-yield figure from the measured 33%/25% window data and re-derive the run-sizing guidance (#1400)

Build order: L0 first → L1 last; items in the same level ship together.

## Sequencing notes

- All five L0 items are semantically independent and parallel-safe. #1381 and #1384 edit the same producer file (`workflows/scripts/report-producers/model-comparison`) and the same test file, but in disjoint regions (`armblock` cost section ~349–373 vs `pricing_inputs` ~511–528); #1381's scope is deliberately confined to the per-arm cost block so the two cannot collide — `pricing_inputs`/`estimate_usd` is #1384's exclusive territory.
- L1 (`judge-diff-prompt-consume`) consumes the record-schema field L0's `score-diff-capture-xr-attrib` introduces — a genuine merge-safety edge (`depends-on`), not just logical order.
- #1400 is docs-only and can merge any time within L0.

## Re-triage signals

- none

## Items

- [x] **Count integration-errored spend as unmeasured, with a reason** `slug: report-uncosted-timeout-spend` — a candidate record with an integration error (e.g. stage 'candidate-timeout') and tokens=null is counted in the per-arm cost block with a stated reason, never silently absent; scope is the armblock cost section ONLY (`pricing_inputs`/`estimate_usd` belongs to #1384)
  - branch: `fix/report-uncosted-timeout-spend`
  - size: M
  - kind: code
  - model: sonnet
  - gh_issue: 1381
  - source: "#1381"
  - files: `workflows/scripts/report-producers/model-comparison`, `workflows/scripts/model-comparison/tests/test_comparison_report.sh`
  - acceptance:
    - A run fixture containing a candidate record with `integration_error` (stage `candidate-timeout`) and `tokens: null` renders that record counted in `cost.uncosted_n` or a named sibling counter (e.g. `errored_uncosted_n`), with a stated reason string in the cost block — never absent from the cost section.
    - The honest limit is stated, not papered over: a SIGKILLed (timeout) spawn has no envelope and therefore no partial-usage data — the disclosure says the spend is unmeasured and why; no fabricated token counts.
    - test_comparison_report.sh gains a timeout-path disclosure case; the full model-comparison test suite is green.
  - activation:
    - class: A
    - proof: "grep -q 'integration_error' workflows/scripts/report-producers/model-comparison"
  - notes: Auditor-verified — today's `uncosted_n` (producer:373) counts only SCORED records missing tokens, so an integration-errored record is invisible even as "unmeasured". `_exec_integration_error` (replay.sh:1813-1832) unconditionally emits tokens:null/usage_source:unavailable, and candidate-timeout is a SIGKILL (rc 137) with no envelope — partial-usage capture is structurally impossible on this path, hence the honest-limit bullet. Validation-run evidence: [[Context/temperloop - model comparison harness first validation run]].
  - pr: 1584

- [x] **Persist real diff text + X/R candidate attribution at score time** `slug: score-diff-capture-xr-attrib` — while the leg's worktree is still live (score time — batch.sh tears it down right after replay), capture the actual candidate diff text (field `text_excerpt`) into the score record, and give the X and R buckets the per-path candidate-vs-truth attribution the N bucket already carries
  - branch: `fix/score-diff-capture-xr-attrib`
  - size: M
  - kind: code
  - model: sonnet
  - gh_issue: 1579
  - source: "#1382"
  - files: `workflows/scripts/model-comparison/score.sh`
  - acceptance:
    - The persisted score record carries a diff-text field (`text_excerpt` or equivalent) containing real patch text captured while the worktree exists; a fixture asserts its presence and non-emptiness for a candidate that made edits.
    - X and R buckets carry candidate-touched attribution equivalent to N's (score.sh:422-477's per-path logic extended), so a truth-partition path is mechanically distinguishable from a candidate edit in the record.
    - A zero-change-candidate fixture yields a record in which no path in any bucket reads as candidate-modified; a test asserts this.
    - Oversized diffs are excerpted/truncated at capture time with an explicit marker in the field; a test covers the truncation path.
  - activation:
    - class: A
    - proof: "grep -q 'text_excerpt' workflows/scripts/model-comparison/score.sh"
  - notes: Split from #1382 (its Defect B + the capture half of Defect A). The bucket-shape change (X/R from bare path arrays to attributed objects) may need a `— BREAKING` changelog fragment per `changelog_breaking_sections()` — worker must check at build time (project non-BREAKING release discipline). Validation-run evidence: [[Context/temperloop - model comparison harness first validation run]].
  - pr: 1586

- [x] **Pre-flight model resolution for integration-error attribution** `slug: error-attribution-real-model` — resolve the effective candidate model BEFORE spawn (from the candidate session's resolved config/CLI default when --model was omitted) and thread it to the integration-error emit path, so a default-model error record is attributed to the real model instead of 'unknown'
  - branch: `fix/error-attribution-real-model`
  - size: M
  - kind: code
  - model: sonnet
  - gh_issue: 1383
  - source: "#1383"
  - files: `workflows/scripts/model-comparison/replay.sh`
  - acceptance:
    - Mechanism is pinned pre-flight: the effective model is resolved before the candidate spawn (explicit `--model` value when given; otherwise the candidate session's resolved default, queried before spawn) — NOT from the result envelope, which does not exist on the timeout/SIGKILL path.
    - A default-model (no `--model`) integration error emits the attribution record carrying the resolved effective model id, not 'unknown'; a test asserts it.
    - 'unknown' remains only where pre-flight resolution is genuinely impossible, and then with the existing `usage_source: unavailable` disclosure unchanged.
  - activation:
    - class: A
    - proof: "! tr '\n' ' ' < workflows/scripts/model-comparison/replay.sh | tr -s ' ' | grep -q 'model:-unknown'"
  - notes: Auditor finding 3 — the envelope-derived route the issue's FIX paragraph implies cannot work (vendor-error returns before extraction; timeout has no envelope), so this contract pins pre-flight resolution instead. The judge.sh:775/899 `${model:-unknown}` sites named in the issue are likely MOOT (judge model defaults to `$MODEL_COMPARISON_JUDGE_MODEL`, always concrete — judge.sh:256); worker should confirm with a quick check and leave them untouched if never-empty, noting so in the PR body. Validation-run evidence: [[Context/temperloop - model comparison harness first validation run]].
  - pr: 1588

- [x] **Withhold the headline cost figure when nothing was priced** `slug: estimate-usd-null-unpriced` — when `priced_models` is empty and `excluded_models` is non-empty, render `estimate_usd` as null with a stated reason naming the excluded models, matching the producer's withhold-don't-fabricate convention — never 0 reading as 'free'
  - branch: `fix/estimate-usd-null-unpriced`
  - size: S
  - kind: code
  - model: sonnet
  - gh_issue: 1384
  - source: "#1384"
  - files: `workflows/scripts/report-producers/model-comparison`, `workflows/scripts/model-comparison/tests/test_comparison_report.sh`
  - acceptance:
    - With a price table that excludes every model in the run, `estimate_usd` renders null and a stated reason field (`estimate_usd_unavailable_reason`) names the excluded models — never 0 (today's `add // 0` at producer:524-528).
    - Behavior is unchanged when at least one model is priced; existing tests (incl. the H3 malformed-table case) still pass.
    - A new test covers the all-excluded case end-to-end.
  - activation:
    - class: A
    - proof: "grep -q 'estimate_usd_unavailable_reason' workflows/scripts/report-producers/model-comparison"
  - notes: The exclusion itself is already handled correctly (#1251 discipline) — only the rendered figure lies. Whether the shipped default-pricing.json should carry the current default model, or its absence be surfaced as a staleness signal, is a consider-in-PR note, not an acceptance bar.
  - pr: 1589

- [x] **Re-state the replay-yield figure from measured data** `slug: replay-yield-doc-remeasure` — replace the stale ~52% replay-yield figure (doc lines 107/133/138) with the measured, window-named figures (33% over 220 PRs deep; 25% over the recent-80 window) and re-derive the run-sizing guidance from them
  - branch: `docs/replay-yield-doc-remeasure`
  - size: S
  - kind: code
  - model: sonnet
  - gh_issue: 1400
  - source: "#1400"
  - files: `docs/features/model-comparison.md`
  - acceptance:
    - The doc states a yield figure that matches a measurement whose window is named, or a range with the trend (older history replays better than recent).
    - The "budget ~2x its target size" guidance is re-derived from whatever figure the doc lands on (~3-4x at the measured yields).
    - Whether the recent-window degradation is corpus drift or Tier-C over-rejection is stated explicitly; if drift, said plainly as a property of the repo, not a bug.
  - notes: Docs-only (rule-14 exempt). The 33%/25% figures are already measured and tabled in #1400's body — no new measurement needed; cite the window in the doc.

- [x] **Show the judge the diff it is scoring** `slug: judge-diff-prompt-consume` — the judge prompt includes the persisted diff text (from the record field score-diff-capture-xr-attrib introduces) in a bounded '## Diff text' section with explicit truncation disclosure, so the four code-level rubric dimensions are answerable from the supplied input
  - branch: `fix/judge-diff-prompt-consume`
  - size: M
  - kind: code
  - model: sonnet
  - gh_issue: 1580
  - source: "#1382"
  - depends-on: score-diff-capture-xr-attrib
  - files: `workflows/scripts/model-comparison/judge.sh`
  - acceptance:
    - The judge prompt captured via `judge.sh --prompt-out` contains a `## Diff text` section carrying the record's actual diff text (or its disclosed excerpt); a fixture asserts its presence.
    - When the record's diff text was truncated at capture, the prompt section carries an explicit truncation disclosure line; a test covers it.
    - With the X/R attribution from the L0 item present, a zero-change-candidate record produces a judge input in which no path can be read as candidate-modified; a test asserts the prompt's attribution rendering.
    - The prompt stays bounded: the section respects a size cap; the full model-comparison suite is green.
  - activation:
    - class: A
    - proof: "grep -q '## Diff text' workflows/scripts/model-comparison/judge.sh"
  - notes: Split from #1382 (the consume half of Defect A). Depends on the L0 record field — a genuine schema `depends-on`, not just ordering. Today `_je_build_prompt` (judge.sh:393-415) emits only the bucket JSON as 'Diff summary'; by judge time the worktree is gone (batch.sh:841 teardown), which is why capture had to move to score time.
  - pr: 1593

## Escalation resolution — estimate-usd-null-unpriced
Retry with rebase context (orchestrator disposition, 2026-08-15). The 3f unconditional rebase hit REBASE_CONFLICT in `workflows/scripts/report-producers/model-comparison`: origin/main advanced mid-level (4b2253e batch.sh arm counterbalance; 4267357 pwd -P test paths). pr.sh already aborted the rebase — the worktree is clean at commit 94e0fd5 with the worker's commit intact. Continuation instruction to the worker: run `git fetch origin && git rebase origin/main` in your worktree, resolve the conflict in the producer file by preserving BOTH main's changes and your estimate_usd/estimate_usd_unavailable_reason change (and re-check the test file merges cleanly), re-run your scoped checks, commit the resolution (no push), and return done with your original acceptance results re-verified.

## Merge gate log
- L0 · 2026-08-15T16:55Z · modal-approved · PRs #1583 #1584 #1586 #1589 (consented set; #1588 HELD at gate — combined-tree J2 offender, fix+re-drive)
- L0 re-drive · 2026-08-15T17:20Z · modal-approved · PR #1588 (hermeticity fix c27a7b6, rebased sha 2554d54; CI green, J2 54/54 on union, gate 163/163) — enqueued
- L1 · 2026-08-15T18:15Z · modal-approved · PR #1593 (judge-diff-prompt-consume; CI green, activation proof green, 58/58 judge tests) — enqueued
