---
title: "0032: The ontology registry is the source of truth for tracker and plan vocabularies"
---

## Status

Proposed

## Context

The pipeline's node and edge vocabulary — issue status labels, plan-note
sentinels, PR merge state, the decision baton, and the route enum
`issue-state.sh resolve` returns — is not written down in one place. It is
restated across four contract docs (`ISSUES-ONLY-BACKEND.md`,
`plan-schema.md`, `decision-queue-contract.md`, `work-class-policy.md`) and
spelled out by hand in roughly three dozen scripts that each know their own
slice of `fnd:status:*` labels or plan sentinels. Nothing enumerates the
full state alphabets or the stores that participate in them, so a document
can drift from the code it describes, and a new label or sentinel can be
introduced anywhere in the tree with nothing to notice.

This gap blocks the derived state graph the sibling ADR (0033) introduces:
a graph builder needs one typed vocabulary to build against, not four
restatements to reconcile by eye.

epic: Towheads/temperloop#1910 — ratified brief
`Designs/temperloop - graph of record` (private knowledge store)

## Decision

One TSV, `workflows/scripts/config/ontology-registry.tsv`, is the single
source of truth for the pipeline's ontology. It lists the node types
(Epic, Issue, PlanItem, PR, Worktree, Session, Marker, Decision,
RetroTracker), the edge types (`sub_issue_of`, `blocked_by`, `depends_on`,
`after`, `closes`, `claimed_by`, `marked_by`, `gated_on`, `touched_by`,
`supersedes`, `cites`), and four state alphabets: issue-status labels
(`fnd:status:*`), plan sentinels (`[ ] [~] [m] [>] [x] [v] [-]`), PR merge
state plus the decision baton, and the route enum shared by
`issue-state.sh resolve` and the state graph's `resume` query. A fifth
axis, `source`, names every store the state graph reads (board, PR list,
worktrees, plan notes, the workflow journal, tmux markers), so a store
that later gets wired in without a registry row is visible as a gap in
the registry rather than invisible.

A CI checker, `workflows/scripts/config/check-ontology-registry.sh`,
collects every `fnd:` label token and plan sentinel token in the tracked
tree and fails on any the registry does not list. Legacy tokens already in
the tree at adoption time are absorbed by a shrink-only grandfather
allowlist — the same shape `exec-bit-grandfather-allowlist.tsv` already
uses — so it can never grow, only shrink as old fixtures are cleaned up. A
label under a personal prefix (`x-`, registered once) is permanently
exempt, so one teammate's own-branch experiment never forces a
shared-registry PR. The four contract docs that today restate the
vocabularies are each edited to carry a one-line pointer at the vocabulary
table's former location instead of restating it.

## Consequences

**Benefits.** A new label or sentinel is added to the registry first, or
CI goes red — the coupling that today is implicit (restated prose that can
silently drift) becomes a single edited file the checker enforces. The
four contract docs shrink to pointers and stop being four independent
places a vocabulary change can partially land. The registry's `source`
axis is the one place a newly-introduced state store becomes visible as a
declared gap instead of a blind spot no consumer of the derived graph
would otherwise notice.

**Costs.** The grandfather allowlist is a second file to consult when the
checker fails on old content, and it must be hand-curated down over time
rather than assumed to disappear on its own. The personal-prefix exemption
means the registry is not a complete inventory of every label ever created
by hand on the live tracker — only of every label the tracked tree uses. A
downstream doc that quoted one of the four contract docs' vocabulary
tables by section name still resolves (the section stays, its content
becomes a pointer), but no mechanical check confirms every such external
reference still reads correctly.

**Follow-on work.** The registry is a dependency of the state-graph
builder (ADR 0033): every node state the builder emits must be a registry
row, checked by a fixture that forces an unregistered state to error
rather than collapse into an untyped one. The checker is wired into
`scripts/quality-gates.sh` in the same change that introduces it, and any
later store added to the `source` axis with no registry row is a design
defect, not a silent extension.
