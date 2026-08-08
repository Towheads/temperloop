---
tags: [plan, project/temperloop]
date: 2026-08-08
source_kind: claude-stamped
source_session: eee66e6f
last_verified: 2026-08-08
sources:
  - "#1299"
epic: 1299
status: done
---

# temperloop - changelog merge-conflict hotspot

## Run status
RUN 2 finished 2026-08-08 · session eee66e6f · **COMPLETE** · items: 3 merged / 1 verdict-captured / 0 parked / 0 skipped
L0 `changelog-direction-ratify` `[v]` (#1311) · L1 `changelog-fragment-format` `[x]` PR #1339 (#1321) · L2 `changelog-gate-cutover` `[x]` PR #1354 (#1322, BREAKING) · L3 `sweep-chunker-changelog-hotspot` `[x]` PR #1359 (#1218)
Epic #1299 CLOSED → Done (all 5 children closed). Coarse #1287 closed as split.
Follow-up filed: #1353 — the contract-surface table omits the changelog gate itself.


## L0 verdict — scoping changes (APPLIED 2026-08-08, operator-approved)

The keystone verdict ratified the `changelog.d/` direction **conditionally**. All of the following were folded into the items below on operator instruction; this section is the audit trail of what changed and why.

1. **L1 — two binding constraints added** (conditions of the ratification, not suggestions): the fragment format is **index-free**, and every registry line is a **directory glob, never a per-fragment entry** (per-file lines are a shrink-only ratchet, the class `.gitattributes:20-22` excludes from `merge=union`). Also added: the `gate-paths.tsv` work is a **recogniser row on the `none` row** (an `ALWAYS` row does not satisfy it), and `setting-registry.tsv` coverage if the assembler introduces an env seam.
2. **L2 — three acceptance criteria added**: the assembler must be **additive over a non-empty `[Unreleased]`** (the highest-value one — otherwise the cutover silently drops everything since the last tag); the **cut-vs-sibling omission race** must be closed by asserting `changelog.d/` is empty at the tagged commit (a *new* failure class this plan did not previously name — a silent omission that merges clean, the mirror image of the union-driver failure); and the **fail-loud `.kernel-pin` guard** must ship with the degradation skip in the same PR.
3. **L3 — branch resolved to "removed"** and resized `M` → `S`. The hotspot is a genuine subtraction; #1218's untestable acceptance is formally retired rather than replaced.

**Neither L1 nor L2 needed re-splitting** — both keep `size: L`; the verdict ratified the plan's own rationale for keeping each whole (splitting L1 leaves a half-built `changelog.d/` with no consumer and costs an extra ~11-minute merge-queue round-trip; splitting L2 leaves a window where the gate demands fragments while the documented cut process still describes the manual `[Unreleased]` rewrite).

Verdict note: [[Decisions/temperloop - changelog fragment direction (keystone spike verdict)]]

## Problem

`VERSIONING.md` requires a `## [Unreleased]` entry on every contract-surface change and `check-changelog-entry.sh` enforces it, so **25 of the last 25** commits touch `CHANGELOG.md`. Every merged PR edits the same few lines of the same file, which makes a conflict between any two concurrent PRs structural rather than occasional — and the pipeline is built to run PRs concurrently, so it scales the wrong way. The observed cost is a clean, fully-green PR being ejected from the merge queue and needing a rebase plus a full gate re-run (temperloop#1269: 5/5 green at queue position 2, ejected `CONFLICTING` on two adjacent bullets under one `### Fixed` heading). The same fact defeats `/sweep`'s shared-hotspot heuristic, which cannot know that *every* contract-surface kernel item touches this one file, so a multi-item kernel chunk collides by construction.

## Summary

- **Remove the collision at its source, rather than routing around it.**
  - **L0** — Ratify the fragment-directory direction and pin its migration contract; the two rejected alternatives are already settled on evidence (#1287)
  - **L1** — Add the `changelog.d/` per-entry fragment format, its parser, a release-time assembler, and the registry coverage a new top-level directory requires (#1287)
  - **L2** — Cut the gate over to requiring a fragment, rewrite the release process, and ship the BREAKING entry plus the overlay migration note (#1287)
- **Retire the workaround the collision forced on the sweep chunker.**
  - **L3** — Subtract `/sweep`'s CHANGELOG hotspot rule once the hotspot is gone, and formally retire #1218's untestable acceptance (#1218)

Build order: L0 first → L3 last; items in the same level ship together.

## Sequencing notes

**The direction is already settled on evidence; L0 ratifies rather than investigates.** This plan's assess pass ran the failing merges directly against `origin/main` rather than reasoning from prose, and two of the three options #1287 named are closed:

- **Union merge driver (`.gitattributes`) — disqualified, and it fails *worse* than the status quo.** GitHub genuinely honors `merge=union` server-side (verified: merge commit `9150644` carries a `--cc` keep-both resolution of two parents' adjacent appends to `docs/features/feature-manifest.txt`), so the mechanism works. That is the problem. On the release-cut race — a cut PR moving the `[Unreleased]` body down into a new `## [x.y.z]` while a sibling PR inserts a new `### Fixed` block at the same anchor — the default driver **conflicts loudly** (`merge-tree` exit 1) and union **auto-merges clean** (exit 0), landing the sibling's entry *inside the shipped release section* and leaving `## [Unreleased]` empty. Nothing catches it: `git merge-tree` honors the attribute, so `/build` 4a's hunk-overlap probe flips that pair from *risky → modal* to *disjoint → timed-eligible*; and `check-changelog-entry.sh`'s section-scope property exits early on every non-`pull_request` event, so the `merge_group` run — the only one that sees the post-cut merge result — never evaluates it. Union would trade a bounded, visible cost (one queue ejection) for an unbounded invisible one: a wrong entry or `BREAKING` attribution inside a released section, which is exactly the signal every downstream overlay's acknowledgment gate reads. `.gitattributes`'s own header already excludes this class — union is scoped to files whose only mutation is *append*, and a release cut is a *move*.
- **Relaxing the gate to release time — self-refuting from the gate's own header.** "An ABSENT entry cannot carry a `BREAKING` marker," which is precisely the state that motivated the gate (at the v0.22.0 cut, 1 of 14 merged PRs had touched `CHANGELOG.md`).

So `changelog.d/` fragments is the surviving direction. **L0 stays anyway, as a `keystone: true` spike, for one reason: it is a BREAKING change for every vendoring overlay and this epic is classified Foundational (operator judgment required).** `check-changelog-entry.sh` is a `KERNEL_GATES` member whose paths are repo-root-relative, not subtree-relative — so in a vendored overlay it evaluates *that overlay's own* root `CHANGELOG.md`. After the cutover it would demand a `changelog.d/` fragment in a tree that has neither the directory nor an assembler. The keystone halt puts that verdict in front of the operator before L1/L2 build. L0's job is to ratify and pin the migration contract, **not** to re-derive the two determinations above — they are inputs, recorded here.

**Why the registry lines ride L1 rather than a later item.** A new top-level directory is never one directory in this repo: `changelog.d/` needs a `kernel-manifest.txt` line (100%-coverage gate), a `feature-manifest.txt` claim (full-coverage gate), `gate-paths.tsv` trigger rows, and a terminology-leak exemption twin to `CHANGELOG.md`'s. The two coverage gates would fail L1's own PR if its lines were deferred.

**Premise corrected by the L0 verdict (2026-08-08).** This plan originally claimed the `gate-paths.tsv` omission "fails silently — the changelog tests simply stop triggering." **That is false**, and the L0 spike refuted it with a direct probe (independently re-verified): `workflows/scripts/lib/gate-selection.sh` defaults to the **full** gate set on a path matching no glob in the map (`GATE_SELECTION_REASON="full set — … default-to-full on an unmapped path"`). So correctness is **fail-safe**, not fail-silent — the changelog tests still run. The real cost of omitting the rows is losing **diff-scoping**: every fragment-touching PR escalates to the full ~110-gate run. Still worth doing in L1, for a different and lesser reason than originally stated.

**Lib placement is pre-decided, not open.** ADR-0002's layering rule is stated in `changelog.sh`'s own header: `bin/` is the pre-checkout CLI surface, `scripts/` is an in-checkout dev tool, neither is the other's library. Fragment parsing therefore **extends `workflows/scripts/lib/changelog.sh`**; a fragment parser placed in `scripts/` and sourced from `workflows/scripts/` would violate that rule.

**What this change does *not* touch.** The downstream `BREAKING` acknowledgment contract survives intact in every direction — `changelog_breaking_sections()`, `changelog_sections_in_range()` and `changelog_version_headings()` all key on released `## [x.y.z]` headings read at a tag, and both consumers (`scripts/update-kernel.sh`, `bin/subcommands/update.sh`) read an already-assembled `CHANGELOG.md`. That was the plausible worst case and it is not real; only the gate's completeness property is rewritten.

**Minor caveat, deliberately not filed as work.** `ci.yml` passes `github.event.merge_group.base_sha` into `CHANGELOG_GATE_BASE`, but the gate exits on non-`pull_request` events, so that half of the expression never influences anything. It is harmless and defensive, and its only real hazard — someone assuming the `merge_group` seam is live while building a "union + guard" variant — dies with the union direction. Noted here rather than filed, per the rule against Backlog items that only look tracked.

**If L0's verdict rejects the fragment direction, L1–L2 are void.** That is what the keystone halt is for: the operator edits or abandons this plan rather than letting dependents build on a rejected premise.

## Re-triage signals

- **#1287's body cites a disconfirmed causal link — ephemeral, correction already routed.** It states `Towheads/foundation#1495` "was filed on that misreading and stood for a week," attributing that issue to a CHANGELOG-collision misread. Verified false: foundation#1495 was filed 2026-08-01 about two PRs reading 16d/6d stale, its own closing comment establishes those were `updatedAt` ages rather than queue-wait times, and the CHANGELOG collision (temperloop#1269) appears there only as a separately observed event on 2026-08-08, the day it closed — coincident, not causal. The member stays valid (the 25-of-25 rate and the #1269 ejection are directly measured and independent of this claim). **Route taken:** a correcting comment was posted on #1287; no status flip, since nothing about the member is invalid. Resolve at the approval gate by deciding whether to also edit the body text.
- **The epic body and #1287 both present the union merge driver as the "cheapest, well-trodden" option — that premise is now disqualified (see Sequencing notes) and should not survive into the issue bodies.** Ephemeral: a stale premise left standing in a live artifact is how a rejected direction quietly comes back. Recommend correcting both bodies at the approval gate, or letting L0's verdict note supersede them explicitly.
- **#1218 is *not* a subsumption candidate and should not be closed as obsolete pending L0.** Its problem is real today, and item L3 correctly branches on L0's verdict rather than pre-closing it. Recorded here only because the epic's own "Note for /assess" raised consolidation as a possibility — the answer is no; the two members stay distinct items.

## Items

- [v] **Ratify the changelog fragment direction and pin its migration contract** — verdict-captured 2026-08-08 (kind: spike — note written + issue routed; no PR) `slug: changelog-direction-ratify` — confirm `changelog.d/` as the direction and fix the BREAKING/migration contract before any code lands
  - branch: `chore/changelog-direction-ratify`
  - size: S
  - kind: spike
  - keystone: true
  - gh_issue: 1311
  - source: #1287
  - acceptance:
    - A `Decisions/` note records the ruled direction and the trade-off accepted, and **explicitly rules out** both rejected alternatives with their evidence: the union merge driver (the release-cut race auto-merges silently, `merge-tree` honors the attribute so `/build` 4a's probe is defeated, and the section-scope property never runs on `merge_group`) and the release-time gate relaxation (an absent entry cannot carry a `BREAKING` marker). **Do not re-derive these — they are settled inputs; the note records them.**
    - The note states the **BREAKING classification** for a vendoring overlay and names the concrete overlay-side migration step, given that `check-changelog-entry.sh` is a `KERNEL_GATES` member whose paths are repo-root-relative and therefore evaluate the overlay's own root `CHANGELOG.md`.
    - The note specifies how a `changelog.d/`-absent tree must **degrade legibly** rather than hard-fail — the shape the existing `no CHANGELOG.md at HEAD` skip already sets.
    - The note enumerates the full registry-coverage tail a new top-level directory requires (`kernel-manifest.txt`, `feature-manifest.txt`, `gate-paths.tsv` trigger rows, terminology-leak exemption), naming which omissions fail loudly and which fail silently.
    - The note confirms the lib-placement constraint (fragment parsing extends `workflows/scripts/lib/changelog.sh`; ADR-0002 forbids a `scripts/` lib sourced from `workflows/scripts/`) and states whether L1/L2 as scoped below are correct or need re-splitting.
    - The note states whether the direction removes the CHANGELOG hotspot **entirely** (so L3 is a subtraction) or only reduces it (so L3 must teach the chunker) — this is the explicit input L3 branches on.
  - notes: This is a **ratification** spike, not an investigation — the assess pass already ran the disqualifying merges against `origin/main` and its findings are recorded in the plan's `## Sequencing notes`. `keystone: true` because the verdict commits the kernel to a BREAKING change for every vendoring overlay and this epic is classified Foundational; `/build` halts here for operator review before L1 builds. If the verdict **rejects** the fragment direction, L1–L2 are void — edit or abandon the plan rather than re-running `/build`. Prior art worth reading: [[Patterns/Merge-queue and mergeability gotchas (fresh-SHA recompute, --auto not fire-and-forget)]] item 2 (the queue rejects the rest of a set that shares a hotspot file, even for trivial keep-both conflicts) and [[Patterns/Batch-PR for parallel workers that bump shared counters]] (the batching mitigation this direction makes unnecessary).

- [x] **Add the `changelog.d/` fragment format, parser, and release-time assembler** `slug: changelog-fragment-format` — per-entry fragment files with a cut-time assembler, plus the registry coverage a new top-level directory requires
  - branch: `feat/changelog-fragment-format`
  - size: L
  - kind: code
  - after: changelog-direction-ratify
  - gh_issue: 1321
  - source: #1287
  - files: `workflows/scripts/lib/changelog.sh`, `workflows/scripts/kernel/kernel-manifest.txt`, `docs/features/feature-manifest.txt`, `workflows/scripts/config/gate-paths.tsv`, `workflows/scripts/kernel/terminology-leak-exempt-files.txt`, `workflows/scripts/lib/tests/test_changelog.sh`
  - acceptance:
    - A per-entry fragment convention under `changelog.d/` is defined and documented, such that two concurrent PRs each adding an entry write **disjoint files** and share no lines.
    - **BINDING CONSTRAINT 1 (L0 verdict) — the fragment format is index-free.** No shared ordering file or manifest inside `changelog.d/`. Category and ordering derive from the fragment's own filename or body. Without this the hotspot **moves rather than disappears**, and this ratification's condition fails.
    - **BINDING CONSTRAINT 2 (L0 verdict) — every registry line is a directory glob, never a per-fragment entry.** Per-file lines are a **shrink-only ratchet** (entries deleted as the cut drains fragments) — precisely the class `.gitattributes:20-22` excludes from `merge=union`, because union's keep-both would resurrect a deleted line. Note `kernel-manifest.txt` and `feature-manifest.txt` already carry `merge=union` (`.gitattributes:23-24`), so a one-time directory-glob append is safe; only the per-file variant breaks, and it breaks in the resurrection direction union cannot cover.
    - Fragment parsing extends `workflows/scripts/lib/changelog.sh` (**not** a new lib under `scripts/` — ADR-0002's layering rule, stated in that file's own header, forbids `workflows/scripts/` sourcing a `scripts/` lib).
    - A release-time assembler collects fragments into an `## [Unreleased]` section byte-equivalent in structure to what the gate and `changelog_unreleased_body()` read today, and is reachable from the cut path under `scripts/`.
    - **This change is additive and non-breaking on its own** — nothing yet *requires* a fragment, so `check-changelog-entry.sh` still passes unchanged and the existing `[Unreleased]` flow keeps working. The breaking cutover is L2's.
    - Registry coverage lands **in this PR**, not deferred: `kernel-manifest.txt` and `feature-manifest.txt` entries (both are 100%-coverage gates that would fail this PR otherwise), a `gate-paths.tsv` **recogniser row on the `none` row** (`gate-paths.tsv:64`) so a fragment-only diff is **diff-scoped** to the changelog tests — **an `ALWAYS` row does not satisfy this** — and a terminology-leak exemption twin to `CHANGELOG.md`'s. State the rationale in the PR body as the **escalation cost** (omitting the row is fail-safe, not fail-silent: `gate-selection.sh` defaults to the full set on an unmapped path, so every fragment PR escalates to the full ~110-gate run), never as the plan's original "tests stop triggering", which the L0 verdict refuted.
    - `setting-registry.tsv` coverage **if** the assembler introduces any env seam (L0 verdict).
    - `changelog_breaking_sections()`, `changelog_sections_in_range()` and `changelog_version_headings()` return identical results for the current `CHANGELOG.md` before and after; `workflows/scripts/lib/tests/test_changelog.sh`, `scripts/tests/test_update_kernel.sh` and `bin/subcommands/tests/test_update.sh` pass.
    - Full `KERNEL_GATES` run green (`scripts/quality-gates.sh`).
  - activation:
    - class: A
    - proof: "grep -q 'changelog.d' workflows/scripts/kernel/kernel-manifest.txt && grep -rq 'changelog.d' scripts/"
  - notes: `size: L` is honest — parser + assembler + four registry surfaces + tests. L0's verdict is expected to enumerate the split; **re-split this item before working it if the verdict says so.** `model:` deliberately unstamped (size L → inherit the session model).
  - pr: 1339
  - pushed_sha: 18689d380006a4f09630aa6ff94d2ab0299a957c

- [x] **Cut the gate over to fragments and ship the BREAKING migration** `slug: changelog-gate-cutover` — require a fragment instead of an `[Unreleased]` line, rewrite the release process, degrade legibly for overlays
  - branch: `feat/changelog-gate-cutover`
  - size: L
  - kind: code
  - depends-on: changelog-fragment-format
  - gh_issue: 1322
  - source: #1287
  - files: `workflows/scripts/check-changelog-entry.sh`, `workflows/scripts/tests/test_check_changelog_entry.sh`, `VERSIONING.md`, `CHANGELOG.md`
  - acceptance:
    - The gate's **completeness property (1)** requires a `changelog.d/` fragment on a contract-surface PR instead of a line under `## [Unreleased]`. The existing escape-hatch grammar (`Changelog: none|amend — <reason>`, its three channels, and the `>= 3-char` reason requirement) is preserved unchanged.
    - The gate's **section-scope property (2)** still holds and its merge-base discriminator is unchanged; its reason to exist now narrows to the release-cut PR. `workflows/scripts/tests/test_check_changelog_entry.sh` passes, and every modified assertion ships the assertion it replaces.
    - **Two concurrent contract-surface PRs no longer collide:** a local reproduction that conflicts on `origin/main` today merges clean after this change, *and* the release-cut-vs-sibling race verified during assessment does not silently misplace an entry into a released section.
    - **ADDED BY L0 VERDICT (1/3) — the assembler is additive over a NON-EMPTY `[Unreleased]` body.** `origin/main`'s `## [Unreleased]` is currently substantial (multiple multi-paragraph `### Changed` entries from `CHANGELOG.md:15`). An assembler that assumes an empty section and **replaces** rather than **merges** silently drops everything accumulated since the last tag. Being additive also removes the need for a cutover drain step **and** makes any in-flight PR still adding a direct `[Unreleased]` line harmless rather than lost. The verdict calls this the single highest-value addition.
    - **ADDED BY L0 VERDICT (2/3) — close the cut-vs-sibling OMISSION race.** A *new* failure class this plan did not name, and the mirror image of the union-driver failure: a cut PR edits `CHANGELOG.md` and deletes fragments A and B while a sibling adds fragment C; the files are disjoint so git merges **clean with no conflict**, yet C lands before the tag with its entry absent from the assembled release section. Fix: replace `VERSIONING.md` § Cutting a release step 1's merge-walking backfill loop (its `^CHANGELOG.md$` grep over merge commits) with a deterministic assertion that **`changelog.d/` is empty at the tagged commit** — strictly cheaper and more reliable than the loop it replaces.
    - **ADDED BY L0 VERDICT (3/3) — the fail-loud non-vendoring guard ships in THIS PR, with the skip.** A bare "no `changelog.d/` → skip" would let the kernel's *own* tree silently disable the gate the moment the directory went missing — `check-changelog-entry.sh:31`'s "quietly narrows to zero" failure. Use the discriminator the repo already has: a repo-root `.kernel-pin` marks a vendoring consumer; a kernel checkout has none (`scripts/quality-gates.sh:1005`, `:1014`). Absent `changelog.d/` **and** absent `.kernel-pin` ⇒ **FAIL loudly, exit 1**. Probe it via `git show "$HEAD:.kernel-pin"` (root-relative), **never** a filesystem `[[ -f "$ROOT/.kernel-pin" ]]` — if `$ROOT` resolves to the kernel subtree root inside an overlay, a filesystem test looks in `kernel/` and misses the overlay-root pin.
    - **Overlay degradation is legible, not a hard fail.** A *vendoring* tree (one carrying `.kernel-pin`) with no `changelog.d/` produces a clear, **actionable** skip mirroring the existing `no CHANGELOG.md at HEAD` skip (`check-changelog-entry.sh:232-238`) — naming the kernel version, the BREAKING classification, and the concrete enabling step — never an unexplained gate failure. The probe generalizes to a directory unchanged: `git show <rev>:<dir>` exits 0 when present, non-zero when absent (verified).
    - `VERSIONING.md` § Cutting a release is rewritten to the assembler-based flow (the backfill loop's `^CHANGELOG.md$` grep and the manual heading rewrite both change), and the contract-surface table's machine-read shape is preserved so the gate still parses it.
    - The `CHANGELOG.md` entry for this change carries the **`BREAKING`** marker and a migration line naming the overlay-side step, per `VERSIONING.md`'s rule that a change is breaking exactly when a downstream overlay must change to keep working.
    - Full `KERNEL_GATES` run green.
  - activation:
    - class: A
    - proof: "grep -q 'changelog.d' workflows/scripts/check-changelog-entry.sh"
  - notes: `depends-on:` (not `after:`) because this rewrites the gate against the parser L1 adds and both touch the changelog machinery — out-of-order merging would break. The gate rewrite, the release-process rewrite and the BREAKING entry ship **in one PR deliberately**: splitting them leaves a window where the gate demands fragments while the documented cut process still describes the manual `[Unreleased]` rewrite. `size: L`; `model:` unstamped (inherit).
  - pr: 1354
  - pushed_sha: 766052578f32024d730d11aa67c19cf96744f7ca

- [x] **Dispose `/sweep`'s CHANGELOG hotspot handling** `slug: sweep-chunker-changelog-hotspot` — remove or re-target the chunker workaround once the hotspot is gone, with an acceptance a test can actually assert
  - branch: `fix/sweep-chunker-changelog-hotspot`
  - size: S
  - kind: code
  - after: changelog-gate-cutover
  - gh_issue: 1218
  - source: #1218
  - files: `claude/commands/sweep.md`
  - acceptance:
    - **BRANCH RESOLVED BY L0 VERDICT: removed.** The hotspot is a genuine **subtraction**, not a reduction — under fragments each `/sweep`-driven Ready singleton writes `changelog.d/<its-own-file>`, a distinct new path, so two singletons in one chunk share no file and no line and the collision temperloop#1218 describes as happening "by construction" becomes **impossible** by construction. This item is therefore a pure prose subtraction in `claude/commands/sweep.md`; do **not** build a chunker-teaching change.
    - `claude/commands/sweep.md`'s shared-hotspot rule explicitly records that `CHANGELOG.md` is **no longer** a universal hotspot and why, citing the fragment change — so a future reader sees a resolved concern rather than a missing one.
    - **#1218's own stated acceptance is not shippable and is formally retired, not satisfied.** It asks for "a chunk-partition test over a synthetic pool," but Step 3 partitioning is model-executed prose in `sweep.md` with no backing helper anywhere under `workflows/scripts/` — there is no function to test, and under the removed branch there is no partition rule left to assert. Say so explicitly in the PR body rather than shipping the untestable form or inventing a helper the direction just made unnecessary.
    - The PR body records the three residual seams the L0 verdict identified as **out of scope for the chunker**, so a later reader doesn't mistake them for a missed case: (1) the release-cut PR still rewrites `CHANGELOG.md`, but `VERSIONING.md` mandates the cut is ONE deliberate maintainer PR and `/sweep` never drives one; (2) the cut-vs-sibling omission race is a different class, owned by the L2 item; (3) a shared index or per-file registry line would recreate the hotspot exactly — which is why L1's two binding constraints are conditions of this ratification.
    - Full `KERNEL_GATES` run green.
  - activation:
    - class: A
    - proof: "grep -qi changelog claude/commands/sweep.md"
  - notes: `after:` rather than `depends-on:` — this shares no lines with the changelog machinery. **Resized `M` → `S` by the L0 verdict**: the branch resolved to **removed**, so this is a prose subtraction, not the larger helper-extraction the `persists` branch would have required. `model:` deliberately unstamped despite `size: S` + `kind: code`: this item's files are exclusively `claude/commands/*.md` spec-prose, whose semantics are verified by advisory review only and not by any mechanical gate — the plan-schema's `model:` Carve-out (a) applies, so it inherits the session model.
  - pr: 1359
  - pushed_sha: 426fdd4476aa66289e9626b5922dec837e3f9cd5

## Run scope

- RUN 1 (spike) · 2026-08-08T15:53:00Z · keystone spike `changelog-direction-ratify` (level 0) `[v]` — HALTED before levels 1–3; verdict: [[Decisions/temperloop - changelog fragment direction (keystone spike verdict)]] · review then re-run /build to proceed
- RUN 2 (build) · 2026-08-08T16:20:00Z · resumed after operator review — scoping changes applied; building levels 1–3

## Merge gate log

- consent: level 1 · 2026-08-08T18:05:00Z · mode: timed-elapsed · PRs: #1339
- consent: level 1 · 2026-08-08T18:55:00Z · mode: timed-elapsed · PRs: #1339 (re-consent after force-push to 18689d3; prior consent voided by the merge_group ejection + re-push)
- consent: level 2 · 2026-08-08T20:05:00Z · mode: modal-approved · PRs: #1354 (BREAKING cutover; operator gave explicit approval rather than letting the timed window elapse)
- consent: level 3 · 2026-08-08T20:45:00Z · mode: timed-elapsed · PRs: #1359
