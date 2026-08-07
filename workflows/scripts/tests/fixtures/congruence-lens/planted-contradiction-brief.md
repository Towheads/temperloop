---
tags: [design-brief, project/fixture]
date: 2026-01-01
status: draft
source_kind: claude-stamped
source_session: fixture0
source_model: fixture-model
last_verified: 2026-01-01
---

# Design brief: fixture — stale-branch auto-prune

This is a purpose-built fixture for the `congruence-lens` agent's
acceptance run (`claude/agents/congruence-lens.md`) — it is deliberately
unrelated to any real design and exists only to exercise the lens's
cold-read cross-dimension check against a brief that is otherwise
well-formed **except for one planted contradiction**, between dimension 1
and dimension 16, on the adoption↔problem-statement seam. Every other
dimension is internally consistent by construction; the lens should not
report a second finding.

## 0. Premise & null hypothesis
disposition: filled
Do-nothing cost: stale feature branches accumulate in a repo with no
automated cleanup, and a human eventually has to hand-sweep them. The
strongest subtraction alternative is "teach people to delete their own
branches" — rejected because it has already failed to hold across three
prior audits of the fixture org's repos. The operator's justification for
proceeding: a mechanical prune is cheap and the manual alternative has a
demonstrated track record of not happening.

## 1. Problem & outcome (stranger standpoint)
disposition: filled
From a stranger's standpoint: a repo accumulates dozens of stale branches
from merged or abandoned work, cluttering the branch list and making it
hard to find active work. **This tool is entirely opt-in: a repo that
does not add the `stale-branch-prune.enable` config flag sees zero change
to its existing branch-cleanup behavior.** The customer-visible outcome is
a clean branch list for the teams that choose to turn it on, with no
effect on anyone who doesn't.

## 2. Audience & interaction modes
disposition: filled
Audience: a repo maintainer who wants branch hygiene automated. Runs
unattended, on a schedule, via the existing cron-checkout pattern.

## 3. Alignment (guiding principles / routing)
disposition: filled
Advances "automate the reversible" — branch deletion after merge is
reversible (the commit history and the PR both survive). Kernel-routed:
generic branch hygiene, no org-specific config.

## 4. Contract seams (Produces / Consumes / Acceptance)
disposition: filled
**Produces:** a nightly prune run that deletes local/remote branches whose
PR has merged or closed.
**Consumes:** the repo's `delete_branch_on_merge` setting and a merged-PR
list from the GitHub API.
**Acceptance:** a branch whose PR merged more than 24h ago is gone from
`git branch -a` after the next scheduled run.

## 5. Command/mechanism shape
disposition: filled
A single script, `prune-merged-branches.sh`, invoked by the existing
cron-checkout sweep. No new command surface; it composes into the sweep
that already runs nightly.

## 6. Scalability & resource impact
disposition: filled
Negligible: one `git for-each-ref` walk plus one `gh pr list` call per
scheduled run, bounded by repo branch count. No board or GraphQL impact.

## 7. Maintainability
disposition: filled
Couples to the GitHub API's PR-state field and to `git`'s branch-deletion
semantics; no new Capture/Backstop pair introduced.

## 8. Testability
disposition: filled
Mechanically gated: a fixture test repo with a mix of merged/open/closed
PRs exercises the prune logic in CI; the "gone after 24h" acceptance claim
is checked against the fixture repo's branch list, not just that the
script exits 0.

## 9. Telemetry & measurement proxies
disposition: deferred → temperloop#901
Cheapest-first proxy sketch: count of branches pruned per run, logged to
the existing cron-run summary. Full wiring deferred to the tracked
follow-up.

## 10. Upgrade path
disposition: filled
No contract-surface change; this is new tooling, not a modification to an
existing one.

## 11. Uninstallability / reversibility
disposition: filled
Removing the flag (or the script) stops future prunes; already-deleted
branches are not restored by uninstalling, but their commits remain
reachable via the merged PR, so nothing is lost.

## 12. First-run experience
disposition: n/a — no interactive first-run surface; this is a scheduled
background script with no CLI a stranger invokes directly

## 13. Docs & marketing surface
disposition: filled
Needs a `docs/features/branch-hygiene.md` entry describing the opt-in flag
and the prune schedule.

## 14. Security / privacy
disposition: n/a — no personal/org content surfaces; operates only on
branch names and PR merge state already visible in the repo

## 15. Failure modes, degradation & capability limits
disposition: filled
If the GitHub API call fails, the run skips pruning entirely and logs a
degradation notice rather than guessing from local git state alone (which
can't distinguish "merged" from "abandoned"). Capability limit: a branch
merged outside the tracked PR flow (a direct push) is invisible to this
tool and is never pruned.

## 16. Adoption & enforcement
disposition: filled
**Once installed, stale-branch auto-prune runs unconditionally on every
scheduled cron sweep for every repo in the org, with no config flag to
disable it per repo — this is the new mandatory default going forward,
not an opt-in a team can decline.** This displaces the prior default of
manual, ad-hoc branch cleanup entirely.
