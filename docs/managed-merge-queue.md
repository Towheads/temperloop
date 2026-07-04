# The managed merge queue — running the whole ladder on a free repo

temperloop#13. GitHub's **native merge queue** (the platform feature
`gate.sh queue`'s `--auto` incantation relies on) is only provisionable on an
**organization-owned repo on a paid plan** — a personal account, or a free
org, can enable branch protection and required checks, but cannot arm a
merge queue. Until this contract existed, that was a hard wall: the
merge-gated build/sweep ladder (`/build`, `/sweep`, the funnel merge tier)
assumed a native queue was always available, so the whole pipeline simply
didn't work on a free personal repo.

`workflows/scripts/build/gate.sh` closes that gap with a **merge-backend
seam**: two subcommands, `backend` (selection) and `managed-merge`
(mechanics), that let the ladder run end-to-end — triage through a merged
PR — on a repo with no native queue at all. Native is still preferred
wherever it's actually available; this is a fallback that makes the ladder
work everywhere, not a replacement for the platform feature.

## Backend selection — `gate.sh backend <owner>/<repo>`

Emits `{"outcome":"NATIVE"}` or `{"outcome":"MANAGED"[, "probe_failed":true]}`.

- **`BUILD_MERGE_BACKEND`** (`workflows/scripts/build/build.config.sh`,
  default `auto`) short-circuits the probe entirely when set to `native` or
  `managed` — the config value wins outright, no network call. This is the
  explicit override / test seam: force a backend without touching the
  repo's actual branch ruleset.
- **`auto`** (or any other value) probes the repo's branch ruleset for a
  `merge_queue` rule on `main` (`gh api repos/<nwo>/rules/branches/main
  --jq 'any(.[]; .type=="merge_queue")'`) — the same shape
  `land__requires_pr()` already uses in
  `workflows/scripts/lib/land-on-protected-main.sh`. `true` → `NATIVE`,
  `false` → `MANAGED`.
- **A probe failure (gh error, 404, empty body) resolves to `MANAGED`, never
  `NATIVE`.** This is a deliberate fail-safe direction: defaulting to
  `NATIVE` on an unreadable probe risks queuing a native `--auto` merge on a
  repo that turns out to have no queue armed (branch protection just
  rejects it, loudly); defaulting to `MANAGED` on a repo whose queue the
  probe merely failed to *see* is safe because `MANAGED` never silently
  arms an auto-merge nobody chose — it just does slightly more manual work
  than strictly necessary. The `probe_failed:true` flag on that outcome
  lets the orchestrator tell "confirmed no queue" apart from "couldn't
  tell," for its own audit trail.

## Managed-merge mechanics — `gate.sh managed-merge <owner>/<repo> <pr> [--strict|--non-strict]`

Replicates the native queue's semantics with existing primitives, for one PR
at a time. This is **per-PR mechanics only** — processing order across a
set of PRs, and whether to keep going past an ejected one, is orchestrator
policy (`claude/commands/build.md`), not gate.sh's concern.

**`--strict`** (default):

1. `gh pr update-branch` — fold latest `main` into the PR's head, the same
   as a native queue re-testing against current tip before landing.
2. Resolve the **updated** head SHA (never poll a stale one — mirrors
   `ci-poll.sh`'s own guard against exactly that bug).
3. SHA-pinned CI re-poll (`repos/<nwo>/commits/<sha>/check-runs` — REST,
   deliberately not `gh pr checks --watch`, which is GraphQL and a shared-
   budget concern) until every check-run completes or the deadline passes.
4. **Green** → merge (`gh pr merge --merge --delete-branch` — a direct
   merge, not `--auto`; mergeability was already established by the
   re-poll, so there's nothing left to queue). **Red** → the PR is
   `EJECTED` (exit 5): parked for escalation, no merge attempted, no
   plan-note sentinel or label written — consent and writeback stay
   orchestrator-side. The queue then continues to the next PR; an ejected
   PR does not stop the set.

**`--non-strict`** skips the update-branch + re-poll entirely and merges
directly — preserving a non-strict repo's immediate-merge cost profile
(no second CI run per PR).

Either path's successful merge call is confirmed the same way `gate.sh
poll` already confirms a queued native merge: poll until `state=="MERGED"`
with a non-null `mergedAt`. A merge the platform itself rejects (branch
protection, a queue-armed repo refusing a direct merge, etc.) surfaces as
`MERGE_REJECTED` (exit 6) rather than dying silently.

Poll tunables (all in `build.config.sh`, mirroring `ci-poll.sh` /
`gate.sh poll`'s own defaults): `GATE_CI_POLL_INTERVAL` / `GATE_CI_POLL_TIMEOUT`
(30s / 3600s, the CI re-poll) and `GATE_MERGE_POLL_INTERVAL` /
`GATE_MERGE_POLL_TIMEOUT` (15s / 600s, the merge-confirmation poll).

## Queued ≠ merged, still

`managed-merge`'s poll-to-`MERGED` step exists for exactly the reason
[`docs/failure-modes/03-premature-status-close-on-async-merge.md`](failure-modes/03-premature-status-close-on-async-merge.md)
documents: a merge call returning success only means the merge was
*initiated*, not that the code has landed. Both the native path
(`gate.sh queue` + `gate.sh poll`) and the managed path
(`gate.sh managed-merge`) confirm `state=="MERGED"` before the orchestrator
closes anything — a queued-but-not-yet-landed PR, ejected or not, never
gets its tracking issue closed against code that isn't in `main` yet.

Resume across sessions rides the plan note's in-band status sentinels plus
a re-read of the PR's live state — never a label — with the full mechanics
in `claude/commands/build.md`.

## The between-ticks caveat: this is not a server

`managed-merge` only runs *while a gate tick is executing* — there is no
long-running process holding the merge lane open between runs, unlike a
native merge queue, which is a standing platform feature. Between two gate
runs (or while a run is paused, or on a repo nobody is actively driving
through `/build`), **nothing stops a human — or another tool — from merging
straight past it**: pushing directly, or merging a PR by hand, bypasses the
managed queue entirely because there is no managed queue process to bypass.

The fix is **not** something in `gate.sh` — you cannot build a lock for a
gap the tool isn't running to enforce. It's **plain GitHub branch
protection** on the repo (require a pull request before merging, require
the same status checks `gate.sh` itself waits on) — free on both public
repos and personal-account private repos, no paid plan needed, no org
needed. That protection is the only-path enforcement: it doesn't replace
`managed-merge`'s re-validate-then-merge sequencing (which is what makes a
gated merge safe to *automate*), but it's what makes "merge around the
managed queue" actually impossible rather than merely unlikely, closing the
same gap a native merge queue's underlying branch protection closes for the
`NATIVE` backend.
