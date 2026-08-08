---
tags: [plan, project/temperloop]
date: 2026-08-08
source_kind: claude-stamped
source_session: 866c2203
source_model: claude-opus-5[1m]
last_verified: 2026-08-08
sources:
  - "#1298"
epic: 1298
status: done
---

# temperloop - board Done-write survives a close

## Run status
run started 2026-08-08 · session 866c2203 · level 1/2 active · items: 0 done / 0 parked / 0 in-flight / 0 skipped

## Problem

On the issues-only backend nothing moves a board item to Done on its own — the adapter's own Done write is the only thing that strips an issue's `fnd:status:*` label and `fnd:host/session:*` claim stamp. But the adapter offers no way to make that write against an issue that is *already closed*: the whole-board item list is `--state open`, so `board_item_id` returns empty and `board_set_status "" Done` silently no-ops. `/triage`'s cull path hits this on every cull (9 of 9 in one live run), and `/sweep`'s spike-close arm never had a Done write at all — both specs instead point at a "built-in close→Done automation" that does not exist on this backend and has nowhere to be hooked. The result is a steady drip of closed issues still wearing status labels and stranded claim stamps: label-based queries go wrong, orphaned repo-level label objects accumulate, and `reconcile.sh` carries sweep load that should never have been created.

## Summary

- **No adapter call can land Done on an already-closed issue**
  - **L0** — Add `board_close_done <board#> <issue#>`: one adapter call that lands an item Done from any state, depending on no cross-call shell state and leaving no adapter global modified. (#1217)
- **Two command specs act on a close→Done automation that does not exist**
  - **L1** — `/triage`: route the cull, decision-route, and funnel-escalation closes through the helper; delete the false "built-in close→Done automation" clause and correct the stale Step 4.6 cache-bust note. (#1217)
  - **L1** — `/sweep`: give the spike-close arm a real Done write, drop its now-redundant manual cache bust, and purge both arms' "close→Done cascade" claim — while deliberately leaving the `--auto` merge arm write-free. (#1280)

Build order: L0 first → Ln last; items in the same level ship together.

## Sequencing notes

- **L1's two items are genuinely parallel.** They touch disjoint files (`claude/commands/triage.md` vs `claude/commands/sweep.md`) and neither depends on the other — only on L0's helper. The edges are `after:`, not `depends-on`: the dependency is "call a function that must already exist", not a shared line or schema, so out-of-order *merging* is not the hazard; out-of-order *building* is.
- **Both L1 items must guard their call site.** Command specs install as one machine-global symlink (`workflows/scripts/install/links.sh`), but `BOARD_LIB` resolves per-repo at run time to a possibly-stale *vendored* `board.sh`. An unguarded forward call to `board_close_done` would `command not found` on every stageFind/ssmobile/subsetwiki checkout that has not yet synced — mid-cull, i.e. exactly the silent-failure path #1217 is about. Hence the `declare -F` fallback in both items' acceptance, following the graceful-degrade precedent already in `/triage` Step 4. Remove the guards once the consumer syncs land.
- **The `/sweep` merge arm is deliberately out of scope for a Done write.** `gh pr merge --auto` only *enqueues*; the issue is still open at that instant and its `Closes #N` fires server-side minutes later. A Done write there would close the issue **before** the merge lands, breaking the linkage and the merge-queue accounting. Its Done write belongs at a confirmed-`MERGED` point, which that arm does not yet have — owned by temperloop#1268, the same deferral `sweep.md` already records for its cache bust. This is a **scope narrowing of #1280** (whose body asks for both arms), not a new dependency on #1268: item C completes without it.
- **Not gated on anything external.** No `gate_check:` is required — nothing here waits on work outside this plan.
- **Reviewer disagreement worth knowing at build time.** The two review passes split on whether `/triage` line ~175's cache-bust note is still accurate. A direct grep settles it: `_board_cache_dirty_after_write` is called only from `_board_issues_set_field` and `_board_issues_stamp_field` (`board.sh:849`/`:923`) — **not** from `board_set_milestone` — and `_board_issues_resolve_item` is an always-live `gh api` read that consults no cache. So the note's stated premise does not hold as written; item B's acceptance requires it be re-verified and corrected rather than assumed either way.

## Re-triage signals

- **(persistent — re-queued as #1306)** `claude/CLAUDE.kernel.md` § "Board reads and writes" (~line 241) asserts a bare `gh issue close` leaves labels behind "so the board still reads In Progress". That is **false** on this backend: `issue_item`'s jq checks `state == "closed"` *first* and returns Done regardless of labels. Both review passes independently confirmed it. This is a standing-rules doc other agents read as ground truth, and it plausibly seeded this epic's overstated severity. Filed to Backlog via `capture.sh` — a doc defect in a file none of this plan's items touch.
- **(persistent — re-queued as #1307)** Four further sites hand-roll the same close+Done idiom the helper replaces (`fix.md:193`/`:224`, `build.md:281`, `build.md:891`). They are **not broken** — they already carry correct explicit Done writes — so converting them is a refactor, not a fix, and stays out of this epic. But until they converge, the helper is not yet *the* idiom. Filed to Backlog.
- **(ephemeral — resolve at the approval gate)** The epic body and **both** sub-issue bodies overstate the defect: #1217 says the board "was left showing every culled issue as not Done", and the epic says "the board still reads In Progress". Verified false — a closed issue always reads Done. The real cost is label/claim-stamp residue, orphaned label objects, and reconcile sweep load. Recommend correcting the issue bodies so the severity framing does not propagate into the PRs.
- **(ephemeral — resolve at the approval gate)** #1280's body asks for a Done write on *both* of sweep's merge-confirmed arms. Only the spike-close arm should get one; see § Sequencing notes. Confirm the narrowing before approving.

## Items

- [x] **Add `board_close_done` — a Done write that survives an already-closed issue** `slug: board-close-done-helper` — one adapter call that lands an item Done from any state, with no dependency on cross-call shell state and no adapter global left modified
  - branch: `feat/board-close-done-helper`
  - size: M
  - kind: code
  - model: sonnet
  - source: #1217
  - gh_issue: 1312
  - files: `workflows/scripts/board/lib/board.sh`, `workflows/scripts/board/tests/test_issues_backend.sh`, `workflows/scripts/board/ISSUES-ONLY-BACKEND.md`, `CHANGELOG.md`
  - acceptance:
    - `board_close_done <board#> <issue#>` lands an item Done from **any** state — strips every `fnd:status:*` label, clears the `fnd:host/session:*` claim stamp, and closes the issue if still open — and works on an **already-closed** issue (the #1217 case). It takes **no `--comment` parameter**: a reason comment is repo-level content, not board state, and bundling a non-idempotent `gh issue comment` into an otherwise read-before-write-idempotent mutator would repost it on retry. Callers keep their own `gh issue comment` immediately before the call, matching the comment-first ordering `/triage` 4.4 and `/sweep`'s park path already use.
    - It depends on **no cross-Bash-call shell state** — neither the open-only whole-board `BOARD_ITEMS_JSON` (whose loss between tool calls is #1217's actual mechanism) nor a prior `board_resolve_item` — and it **saves and restores `BOARD_CURRENT`**, so it leaves no adapter global modified. The function header states that property as the reason the helper exists.
    - Arg guards follow `board_blocked_by_add`'s precedent rather than `board_set_milestone`'s: explicit arg-count check, per-arg numeric guard, loud stderr plus non-zero return, and the `_board_is_issues_only` refusal that propagates a stale `backend=projects` conf line (ADR 0004) instead of resolving it silently.
    - The header documents two things explicitly: the deliberate departure from the kernel doc's "resolve first with `board_item_id`" model (naming *why* resolve-first is wrong here), and the misuse warning — **never call this on an item whose close is owed to a merged PR's `Closes #N`**, which would close early and break both the linkage and the merge-queue accounting.
    - A deterministic fixture test (extending `test_issues_backend.sh`'s in-process-sourced pattern against `fake_gh.sh` — no live network) covers four states: an already-closed issue, a still-open issue, a re-run on an already-Done issue (no-op, exit 0), and `BOARD_CURRENT` unchanged after the call.
    - `ISSUES-ONLY-BACKEND.md` § Function-level interface parity gains a `board_close_done` row adjacent to the `board_set_status` row it composes; `CHANGELOG.md` gains a non-BREAKING `## [Unreleased]` entry (`check-changelog-entry.sh` is an ALWAYS-run `checks` gate for this contract surface).
  - activation:
    - class: A
    - proof: "grep -q '^board_close_done()' workflows/scripts/board/lib/board.sh"
  - notes: The mechanism is already 90% present and must not be rebuilt — `_board_issues_set_field`'s `$BOARD_OPT_DONE` arm ALREADY strips the status label, clears the claim stamp, **and** closes the issue if still open (`board.sh` ~826-848). It needs only `BOARD_CURRENT` plus the deterministic `ISSUE_<n>` item-id, so this helper is a thin, guarded composition over `board_set_status`, not new write logic. Do **not** "fix" this by making `board_item_id` fall back to a per-issue read: it is a pure jq accessor with a documented zero-`gh`-call contract, called in loops by `/triage` 4.7 and `board_capture_item`'s retry, and a hidden network fallback would make a free read cost N REST calls. Additive and non-BREAKING per `VERSIONING.md` (breaking = renaming/removing); the `changelog_breaking_sections()` detector is marker-driven, so no `BREAKING` marker means `make update-kernel` pulls it unattended, which is correct. See [[Mistakes/foundation - issues-only backend closing an issue IS Done (label residue is not a failed cascade)]] for why the *read* half of Done needs nothing from this change.
  - pr: 1337
  - pushed_sha: 5fcf5f99f3b39c75abb4cb2cd5cce3577de22fcb

- [x] **Route `/triage`'s closes through `board_close_done` and purge its false-automation prose** `slug: triage-cull-adapter-done-write` — cull, decision-route, and funnel-escalation arms all get a real Done write; three stale prose claims corrected
  - branch: `fix/triage-cull-adapter-done-write`
  - size: S
  - kind: code
  - model: sonnet
  - source: #1217
  - gh_issue: 1313
  - after: board-close-done-helper
  - files: `claude/commands/triage.md`, `CHANGELOG.md`
  - acceptance:
    - Step 4.8's **cull** and **decision-route** arms, and the **funnel-escalation close** arm (~line 330), each post their reason comment and then call `board_close_done`, replacing the `gh issue close` + `board_set_status "$(board_item_id <n>)"` pair. The Done write is **unconditional** — not an `or`-branch a reader can take as optional.
    - The clause "the built-in close→Done automation reflects it on the board" is **deleted**: it names a Projects-v2 feature that does not exist on this backend and has nowhere to be hooked (`ISSUES-ONLY-BACKEND.md` § Close→Done cascade). No remaining `triage.md` text asserts such an automation exists.
    - The Step 4.6 cache-bust note (~line 175) is **re-verified against `board.sh` and corrected or removed**: `_board_cache_dirty_after_write` fires only from `_board_issues_set_field`/`_board_issues_stamp_field` (`board.sh:849`/`:923`), not from `board_set_milestone`, and `_board_issues_resolve_item` is an always-live `gh api` read consulting no cache — so the note's stated premise does not hold as written. State the actual reason not to lean on a prior resolve: shell state does not persist between Bash tool calls, so a `BOARD_ITEMS_JSON` captured at Step 4.5 is gone by Step 4.8.
    - Every new call site is guarded `if declare -F board_close_done >/dev/null 2>&1; then … else <the existing resolve + set_status form> fi`, per § Sequencing notes' vendored-adapter-skew constraint and the graceful-degrade precedent already in Step 4.
    - `CHANGELOG.md` gains an `## [Unreleased]` entry (contract surface: pipeline command contracts).
  - activation:
    - class: A
    - proof: "grep -q 'board_close_done' claude/commands/triage.md"
  - notes: Three prose sites in one file, so keep the edits together — leaving one arm on the old idiom is how the class returns. Per the kernel's "purge the superseded premise from every live artifact" rule, deleting the false automation clause is as load-bearing as adding the call. `/fix` and `/build` were already corrected to state the no-cascade reality; `/triage` and `/sweep` are the two laggards, which is why they are this epic's members.
  - pr: 1340
  - pushed_sha: 2ba5dc06f72219fc0505eeaedd77d41e70500555

- [x] **Give `/sweep`'s spike-close arm a real Done write and purge both arms' cascade claim** `slug: sweep-close-arms-done-write` — the spike arm gets the adapter write it never had; the `--auto` merge arm deliberately stays write-free
  - branch: `fix/sweep-close-arms-done-write`
  - size: S
  - kind: code
  - model: sonnet
  - source: #1280
  - gh_issue: 1280
  - after: board-close-done-helper
  - files: `claude/commands/sweep.md`, `CHANGELOG.md`
  - acceptance:
    - The **spike-close arm** (`pr` is `null`) posts its verdict comment and then calls `board_close_done`, replacing the bare `gh issue close`. This is a synchronous close, so it is the correct place for the write; today that arm strands a `fnd:status:*` label and a `fnd:host/session:*` stamp on **every** spike close.
    - That arm's now-redundant manual `cache_dirty "$repo"` call and its guarded `lib/cache.sh` source are removed: routing through the adapter fires `_board_cache_dirty_after_write` internally (`board.sh:849`), so the hand-rolled bypass note no longer describes anything real.
    - Both arms' "the close→Done cascade moves the card" claim is deleted and replaced with what actually happens: the close makes the item **read** Done immediately (`issue_item` returns `status: "Done"` for any closed issue, checked before any label), but the `fnd:status:*` label and `fnd:host/session:*` stamp stay standing unless the adapter Done write runs. No remaining `sweep.md` text asserts a cascade exists.
    - The **merge arm** (`pr` set) deliberately gains **no** Done write, and carries an explicit in-text marker saying so and why: `gh pr merge --auto` only enqueues, the issue is still open at that instant, and a Done write there would close it before the merge lands — breaking the `Closes #N` linkage and the merge-queue accounting. Its Done write belongs at a confirmed-`MERGED` point owned by temperloop#1268, matching the deferral `sweep.md` already records for the cache bust on the same arm.
    - The new call site carries the same `declare -F board_close_done` fallback guard as the `/triage` item, for the same vendored-adapter-skew reason.
    - `CHANGELOG.md` gains an `## [Unreleased]` entry (contract surface: pipeline command contracts).
  - activation:
    - class: A
    - proof: "grep -q 'board_close_done' claude/commands/sweep.md"
  - notes: This item **narrows** #1280, which asks for a Done write on both merge-confirmed arms — see § Sequencing notes for why the merge arm must not get one. The narrowing is a technical finding from reading `sweep.md`'s own text (which already defers its cache bust on that arm to #1268), not a manufactured dependency: the item completes without #1268, so no `gate_check:` is needed. The epic's "do not manufacture coupling to #1268" instruction is respected — this records an existing, self-documented deferral rather than creating an edge.
  - pr: 1341
  - pushed_sha: 44f81a3491d1ce241f378b3b10f19bd8877ff6d4

## Merge gate log

- level 0 · 2026-08-08T17:31:00Z · timed-elapsed · consented PRs: #1337 (board-close-done-helper) — clean/disjoint/independent set of one; 300s window elapsed with no objection; re-validated OPEN+MERGEABLE+CLEAN, checks SUCCESS at wake.
- level 1 (serialized, 1 of 2) · 2026-08-08T18:26:00Z · timed-elapsed · consented PRs: #1340 (triage-cull-adapter-done-write) — set of one; the level's two PRs collide additively on CHANGELOG.md (`merge-tree` conflict), so the pair is risky as a batch and is merged SERIALLY instead, each as its own clean-disjoint set. 300s window elapsed with no objection; re-validated OPEN+MERGEABLE+CLEAN, checks SUCCESS at wake.
- level 1 (serialized, 2 of 2) · 2026-08-08T18:47:00Z · timed-elapsed · consented PRs: #1341 (sweep-close-arms-done-write) — set of one after the CHANGELOG collision was resolved by rebasing onto the post-#1340 main. 300s window elapsed with no objection; wake-time re-validation initially read UNKNOWN/UNKNOWN (the documented post-CI lag) and re-polled to OPEN+MERGEABLE+CLEAN before merging, per 4a's single-re-poll rule — never merged on the stale read.
