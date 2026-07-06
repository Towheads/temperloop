---
tags: [plan, project/temperloop]
date: 2026-07-05
source_kind: claude-stamped
source_session: 64bd8b7f
source_model: claude-opus-4-8
last_verified: 2026-07-05
epic: 47
sources:
  - "#47"
status: done
---

## Run status

run started 2026-07-05 · session 64bd8b7f · board OFF (temperloop=board 7, outside build's 3–6 probe) · backend NATIVE/strict · **level 0/1 COMPLETE** · items: 2 merged / 0 parked / 0 in-flight / 0 skipped · epic #47 closed

## Problem

A fresh, kernel-only adopter hits bootstrap gaps that a composed/overlay checkout masks. `capture.sh` aborts on its very first use because the work-class labels it unconditionally applies (`--label Operational`) don't exist in a fresh-history repo — `gh issue create` fails and **no issue is filed**. Separately, the kernel's raw-lake telemetry emitters stamp every record's header with `canonical sink spec: meta/data/raw/README.md` — a file that ships only in the overlay, so a stranger gets working emitters pointing at a **dangling spec** with no way to learn the record shape but to read script source. Both are stranger-test defects: an artifact the kernel scripts assume exists is absent in a bare kernel checkout.

## Summary

- **Fresh-repo capture bootstrap**
  - **L0** — `capture.sh` ensures the work-class label exists (via the already-sourced idempotent helper) before applying it, so a capture succeeds on a bare kernel repo instead of aborting (#14)
- **Kernel telemetry self-documentation**
  - **L0** — create the kernel-owned `meta/data/raw/README.md` sink-spec stub (schema-version convention + per-stream record shapes for KERNEL-emitted streams) so the 5 dangling emit-site header pointers resolve (#29)

Build order: L0 first → Ln last; items in the same level ship together.

## Sequencing notes

- Both items are **L0 and parallel-safe** — no `depends-on`, no `after`. #29 only **creates a new file** (`meta/data/raw/README.md`) and makes zero code edits (auditor-confirmed: all 5 header pointers already read the path verbatim, so nothing is repointed); #14 edits `capture.sh`'s label block (~L251). Even in the worst case they touch disjoint regions of `capture.sh` — git merges cleanly.
- **Heads-up (out of plan):** a separately-filed defect **#49** (`--label Foundational` dual-labels instead of substituting) lives at `capture.sh:251-252` — the exact block #14 edits. #49 is **not** in this plan (routed to Backlog). But if #49 is ever worked concurrently with #14 they will conflict on those identical lines, so land #14 first (it is the smaller change).

## Re-triage signals

Routed, not acted on (triage owns logical calls). Both persistent signals below were filed durably via `capture.sh --repo kernel` → **Backlog** so the next `/triage` re-intakes them (a Backlog `Status` is the only re-queue signal — a comment/label alone would not re-enter the funnel).

- **(persistent — re-queued as #49)** `capture.sh --label Foundational` produces **dual** work-class labels instead of substituting the default: `capture.sh:250`/`:133` promise an override, but `:251` unconditionally adds `Operational` and `:252` appends the passed label → an issue carrying **both** `Operational` and `Foundational`, violating `work-class-policy.md`'s mutually-exclusive one-of-two binary (which the driver's autonomy routing reads). Distinct root cause from #14 but adjacent lines. Route taken: `capture.sh` → Backlog #49.
- **(persistent — re-queued as #50)** `test_findings.py` (kernel-manifest-marked, `kernel-manifest.txt:246`) imports `validate_telemetry` (`test_findings.py:34`), which is manifest-marked **overlay** (`kernel-manifest.txt:285`) and not vendored — so a bare kernel checkout hits `ModuleNotFoundError` running a **shipped kernel test**. Squarely epic #47's subject but no member covers it; needs a logical pass (is the root cause a manifest misclassification, or a missing kernel-local stub?) before it can be folded or scoped. Route taken: `capture.sh` → Backlog #50.
- **(ephemeral)** none.

## Items

### capture-bootstrap-work-class-labels

- gh_issue: #14
- title: "capture.sh: bootstrap work-class labels on a fresh kernel repo"
- slug: capture-bootstrap-work-class-labels
- scope: On a fresh-history kernel/adopter repo the work-class labels don't exist, so `capture.sh`'s unconditional `--label "Operational"` (`capture.sh:251`) makes `gh issue create` fail and no issue is created. Ensure the applied work-class label exists before applying it, so a capture succeeds on a bare kernel checkout.
- branch: fix/capture-bootstrap-work-class-labels
- size: S
- kind: code
- model: sonnet
- source: "#14"
- pr: 52
- pushed_sha: 81c3a1ff1917255e88abc44774035ac0c31fc131
- status: "[x] merged in #52 (2026-07-05)"
- files:
  - workflows/scripts/board/capture.sh
- acceptance:
  - `capture.sh --repo kernel` on a repo lacking the `Operational`/`Foundational` labels creates the issue with the correct work-class label applied (the label is auto-created if absent) — no more "could not add label: 'Operational' not found" abort.
  - The label-ensure **reuses the existing idempotent helper `_board_issues_ensure_label()`** (`board.sh:717-724`, already sourced at `capture.sh:10`) rather than introducing a second, divergent label-create mechanism (same color/description/process-memoization).
  - Re-running on a repo that already carries the labels is a no-op — no error, no duplicate label.
  - No regression on a composed/overlay checkout where the labels already exist.
- notes: Root cause confirmed at `capture.sh:251` (unconditional `--label "Operational"`); auditor verified no other script seeds these labels, so a bootstrap here is the sole fix. Scope this item to the **label-absence** bug only — the adjacent `--label Foundational` dual-label defect in the same `251-252` block is a separate root cause tracked as **#49** (see Re-triage signals); do not fold it in, but expect a merge conflict if both are worked at once.

### kernel-telemetry-sink-spec-doc

- gh_issue: #29
- title: "Document kernel raw-lake streams so dangling sink-spec pointers resolve"
- slug: kernel-telemetry-sink-spec-doc
- scope: The kernel emits raw-lake telemetry (issue-touches, command-run, funnel) but ships no documentation of it, and 5 emit-site headers point at `meta/data/raw/README.md`, which does not exist in a bare kernel checkout. Create that kernel-owned sink-spec stub — a schema-version convention plus per-stream record shapes for the KERNEL-emitted streams — so the existing pointers resolve to a real file.
- branch: docs/kernel-telemetry-sink-spec-doc
- size: M
- kind: code
- model: sonnet
- source: "#29"
- pr: 53
- pushed_sha: 76a26a7d2d9f8702dd9680c751433056c26507ad
- status: "[x] merged in #53 (2026-07-05)"
- files:
  - meta/data/raw/README.md
  - workflows/scripts/emit-command-run.sh
  - workflows/scripts/emit-issue-touch.sh
  - workflows/scripts/board/claim.sh
  - workflows/scripts/board/capture.sh
  - workflows/scripts/build/funnel-cron.sh
- acceptance:
  - A kernel-owned `meta/data/raw/README.md` exists documenting the KERNEL-emitted raw-lake streams (at minimum issue-touches and command-run, plus the funnel-cron stream) with a schema-version convention and the per-stream record shapes.
  - The 5 emit-site headers (`emit-command-run.sh:25`, `emit-issue-touch.sh:34`, `board/capture.sh:89`, `board/claim.sh:53`, `build/funnel-cron.sh:37`) already name `meta/data/raw/README.md`; after this item that path **resolves to an existing file** in a bare kernel-only checkout — grep + file-exists confirms none dangle.
  - The stub documents **only** the KERNEL-emitted streams — not the overlay-only streams (`rework-snapshot`, `issue-meta-snapshot`, `retro-verdict-snapshot`, absent from the kernel checkout) — so the overlay's richer README can extend it additively without contradiction. (In-repo checkable: the stub lists no overlay-only stream.)
- notes: Auditor confirmed this item is doc-creation only — the 5 header pointers already read the correct path verbatim, so there are **no code edits** and no overlap with #14's `capture.sh` label block (the `capture.sh` and `claim.sh` entries in `files:` are read-to-derive-record-shapes references, not edit targets). The narrower 5-file scope correctly excludes the 3 overlay-only emit sites. Acceptance bullet 3 replaces the original cross-repo "overlay-extends" invariant, which was un-verifiable from a kernel PR (the overlay README lives in the separate foundation checkout and no CI check diffs the two) — reframed to an in-repo checkable form per the assess sanity pass.
