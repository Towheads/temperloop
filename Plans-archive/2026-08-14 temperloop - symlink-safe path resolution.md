---
tags: [plan, project/temperloop]
date: 2026-08-14
source_kind: claude-stamped
source_session: 7369a4fe
source_model: "claude-opus-5[1m]"
last_verified: 2026-08-15
epic: 1414
sources:
  - "#1414"
  - "#1324"
  - "#1333"
status: done
---

# temperloop - symlink-safe path resolution

## Run status
run started 2026-08-14 · session 7369a4fe · level 0/2 active · items: 0 done / 0 parked / 0 in-flight / 0 skipped

## Problem

`cd -P` resolves a path *physically*, walking through symlinks. A script that uses it to climb to a repo root or a lake root lands somewhere it did not expect whenever a path component is a symlink — which is exactly the two layouts this pipeline actually runs in: a linked worktree (macOS `$TMPDIR` sits under `/var -> private/var`) and a vendoring checkout (`workflows/scripts/build -> kernel/workflows/scripts/build`). Today that costs two concrete things: `/build`'s combined-tree pre-check false-fails **every** multi-PR level, forcing merge gates modal for PRs that never collide; and a family of telemetry readers may be reading a different lake than their writers filled. The class has now been under-counted four separate times, which is the real reason it keeps coming back.

## Summary

- **A live bug is false-failing the merge gate right now**
  - **L0** — resolve `validate-provider-disclosure.sh`'s repo root logically so its git-tracked check runs under a symlinked path, and add the symlink regression fixture (#1333)
- **A sibling class was never adjudicated**
  - **L0** — audit the lake-root climb sites: per site, live bug or by-design per-checkout (from #1324)
  - **L1** — fix the sites the verdict names, with a symlink regression test per fixed site (from #1324)

Build order: L0 first → Ln last; items in the same level ship together.

## Sequencing notes

- **The two L0 items are fully independent** — disjoint files, no shared lines, and no logical coupling. `validate-provider-disclosure.sh` is a *git-tracked-file prefix check*; the #1324 sites are *lake-root reads*. The "by-design per-checkout" ambiguity the spike investigates does not apply to the validator at all.
- **Deliberate, documented deviation: a spike shares L0 with a build item.** `/assess`'s standing rule is to isolate a spike into its own earlier level, because a verdict can reshape downstream scope. That rationale does not reach `provider-disclosure-symlink-prefix` (see above), and an earlier draft of this plan created an `after:` edge purely to satisfy the rule — the requirements-auditor correctly called that rule-compliance theater. Rather than fabricate a dependency, the deviation is taken openly: **the spike's verdict cannot reshape the validator fix, so they run together.** The spike still gates `fix-lake-root-climb-sites`, which it genuinely does reshape. Ratified by the operator at the 2026-08-14 approval gate.
- **`fix-lake-root-climb-sites` is `after:` BOTH L0 items**, for two different reasons. After the spike: the verdict decides which sites are live bugs. After the validator fix: the lake-root fix's own gate runs happen in a worktree, where `test_allowlist.sh` case 19 fails until #1333 lands — so running it first would spuriously fail the item against a defect it does not own (the #491/#512 shared-gate attribution trap). Sequencing avoids it outright rather than papering over it with an exclusion bullet.
- **Every level here holds at most two items, and the two L0 items touch disjoint files.** Worth noting because the combined-tree pre-check that #1333 breaks is the very machinery this epic's own merge gates would use — a happy accident of the shape, not a design.

## Re-triage signals

- **Persistent — new work the epic is missing: no gate guards against an 11th site.** Routed via `capture.sh` → **#1561** (Backlog, board 7). Nothing in `quality-gates.sh` / `quality-gates.d/` flags physical-climb `cd -P`. Filed rather than added here as a fourth item, because "work the epic is missing" is a logical call triage owns, not a technical one `/assess` may act on — **recommend triage fold #1561 into epic #1414**, since a fix shipped without its guard is the same class that produced this epic. The requirements-auditor's recommendation was to materialize it as an item directly; routing it preserves the one-directional authority while making sure it is not lost.
- **Ephemeral — #1552 is a duplicate of #1333.** `#1552` ("`test_allowlist.sh` case 19 fails in a detached worktree, so combined-tree-precheck reports GATE_FAILED for every multi-PR level") was filed by this session on 2026-08-14 during epic #1418's merge gate, describing the identical root cause, symptom, and blast radius #1333 already documents. **Not acted on**: it carries a live `fnd:host/session:mini:66988394` claim stamp from another session, and dupe-culling is triage's call. Recommend closing #1552 as a duplicate of #1333 at the approval gate, or letting triage dispose of it.
- **Note on the filing itself:** #1552 was filed without first checking the board for an existing issue. It is a real process miss (the board is the cross-session lock and a pre-file probe is cheap), recorded here rather than quietly closed.

## Items

- [x] **Resolve `validate-provider-disclosure.sh`'s repo root logically so the git-tracked check runs under symlinked paths** `slug: provider-disclosure-symlink-prefix` — the physical repo-root resolve makes the prefix match fail under a symlinked ancestor, silently skipping the git-tracked branch, so `test_allowlist.sh` case 19 fails in every linked worktree and false-fails `/build`'s combined-tree pre-check.
  - branch: `fix/provider-disclosure-symlink-prefix`
  - size: M
  - model: sonnet
  - gh_issue: 1333
  - source: #1333
  - files: workflows/scripts/validate-provider-disclosure.sh, workflows/scripts/model-comparison/tests/test_allowlist.sh
  - acceptance:
    - `test_allowlist.sh` case 19 passes in a linked worktree created under a symlinked ancestor (`git worktree add --detach "$(mktemp -d)" origin/main` on macOS, where `/var -> private/var`), where it currently fails deterministically.
    - **Both** `cd -P` sites are handled — `:119` (`SCRIPT_DIR`) and `:157` (`repo_root_for_git`, which derives from it) — or both sides of the prefix comparison are normalized before the `case` match. Fixing `:157` alone leaves the root physical, because `SCRIPT_DIR` already resolved physically at `:119`.
    - A regression test fabricates a symlinked repo root and asserts the git-tracked check actually runs, so the dialect cannot silently regress. Model it on `test_pipeline_retro_health.sh` test 14 ("SYMLINK CLIMB"), the fixture #1185 established for this class.
    - `bash scripts/quality-gates.sh` passes in a **linked worktree**, not only in a normal checkout — the normal checkout already passes today and so proves nothing about this fix.
    - Gate scope: this leg is accountable for `test_allowlist.sh` case 19. Measured at assess time, it is the **only** worktree-only gate failure — a full suite run in a detached worktree failed 1 of 162 — so no other gate's failure belongs to this leg.
  - activation:
    - class: A
    - proof: "grep -qi 'symlink' workflows/scripts/model-comparison/tests/test_allowlist.sh"
  - notes: The issue body cites `:153` and describes a single site; on `origin/main` the real lines are `:119` and `:157`. Work from a fresh grep, not the issue text. **Verified at assess time:** a full gate-suite run in a detached worktree under `$TMPDIR` reports `FAILED 1/162` — only case 19 — so this fix alone is sufficient to stop the combined-tree pre-check from false-failing, and no sibling validator needs to move with it. `/build` deliberately runs gates in a worktree, which is why CI on GitHub's Linux runners has stayed green throughout: those runners have no `/tmp -> private/tmp` symlink.
  - pr: 1569

- [v] **Audit the lake-root climb sites: live bug or by-design per-checkout** `slug: audit-lake-root-climb-sites` — the physical lake-root climb is shared across a family of telemetry readers, and whether each is a defect depends on its writer counterpart, so the class needs a per-site verdict before any of it is touched.
  - branch: `chore/audit-lake-root-climb-sites`
  - size: M
  - kind: spike
  - gh_issue: 1563
  - source: #1324
  - acceptance:
    - The site list is **re-derived mechanically, not taken from the issue body** — `git grep 'raw_root="$(cd -P' -- workflows/scripts/` is the authoritative query. At assess time it returns **10 files**: `emit-command-run.sh`, `emit-diagnose-queue.sh`, `emit-gh-perf.sh`, `emit-issue-touch.sh`, `emit-item-efficiency.sh`, `emit-model-usage.sh`, `emit-session-context.sh`, `probe/gh-perf-report.sh`, `telemetry-brief.sh`, `validate-model-usage-emit.sh`. #1324's body names 7 (+1 added later); `emit-model-usage.sh` and `validate-model-usage-emit.sh` appear in neither. Re-run the query at build time — the count may have moved again.
    - A verdict note classifies **each** site on two independent axes, because #1185 showed they are separable: (a) does it resolve **physically** where it should resolve logically — the `cd -P` climb itself, wrong at every site; and (b) should it use a **checkout-relative root at all**, or a pinned absolute one — which depends on whether its writer pins an absolute root (`PIPELINE_RAW_DIR`-style) or is itself checkout-scoped. Axis (b) is the genuinely undecidable part and is why this spike exists.
    - Each verdict cites the **writer counterpart actually read**, by path — not an inference from the reader alone.
    - The `retro-runs` stream is explicitly re-confirmed as by-design on axis (b): its writer sets no raw-dir override and `com.foundation.retro.plist` pins `WorkingDirectory`. #1324 and #1185 both warn by name against converging it; the verdict must make converging it impossible for the downstream fix to do by accident.
    - The verdict **recommends whether `fix-lake-root-climb-sites` should be split, and how** — it is provisionally sized `L`, and the site count plus the number of scripts needing a brand-new test file is exactly what decides that.
  - notes: Deliberately scoped to the **lake-root** sub-class only. A broader measurement at assess time found **58** climbing `cd -P` sites across 56 files tree-wide (of 158 `cd -P` occurrences across 89 files — the other 109 are plain `dirname` resolution with no climb and are not this class). Most are **not** live bugs: a full gate-suite run in a detached worktree failed 1 of 162. So the wider population is a latent-risk question for the guard filed as #1561, **not** scope for this epic — do not widen the sweep. `#1185`'s header in `workflows/scripts/build/pipeline-retro-health.sh` is the reference implementation and the clearest statement of the two-axis split; read it first.

- [x] **Pin telemetry-brief.sh's pipeline-stream root to the writer's absolute literal** `slug: fix-lake-root-climb-sites` — the reader resolves the pipeline stream checkout-relative while its writer pins it absolute, so the two diverge from any checkout but the main one and the reader silently reports an empty stream.
  - branch: `fix/lake-root-climb-sites`
  - size: S
  - model: sonnet
  - gh_issue: 1564
  - source: #1324
  - after: audit-lake-root-climb-sites, provider-disclosure-symlink-prefix
  - files: workflows/scripts/telemetry-brief.sh
  - acceptance:
    - `telemetry-brief.sh:92`'s pipeline-stream fallback is the writer's absolute literal (`${PIPELINE_RAW_DIR:-$HOME/dev/foundation/meta/data/raw}`, duplicated verbatim from `pipeline-cron.sh:299`), not `$TELEMETRY_RAW_DIR`. Duplicating the literal is deliberate — the same "non-vendoring-checkout fallback" convention `pipeline-retro-health.sh` already uses — never a re-derivation.
    - The other three per-stream dirs in that same block (`cmd_run_dir`, `issue_touch_dir`, `claims_dir`) are **unchanged**. Their writers are checkout-relative too, so converging them would be the exact class of harm the L0 spike proved a blanket fix causes.
    - A regression test asserts reader and writer resolve to the **same** directory with `PIPELINE_RAW_DIR` unset and the script invoked from a checkout that is not `$HOME/dev/foundation` — the condition under which they currently diverge. It must FAIL against the unfixed script; prove both directions.
    - `bash scripts/quality-gates.sh` passes.
  - activation:
    - class: A
    - proof: "! grep -qF 'pipeline_dir=\"${PIPELINE_RAW_DIR:-$TELEMETRY_RAW_DIR}\"' workflows/scripts/telemetry-brief.sh"
  - notes: **Scope narrowed mid-build after the L0 spike falsified this item's original premise** (operator decision, 2026-08-14). It was an L-sized sweep over ~10 lake-root climb sites; the spike proved 0 of 10 are broken (they are file symlinks in a real directory, where `cd -P` is inert) and that a blanket conversion would regress stageFind/ssmobile/subsetwiki, which symlink `workflows/` wholesale and own no lake. Split out: **#1567** (`probe/gh-perf-report.sh:35` — not broken until `probe/` is vendored as a directory symlink) and **#1565** (the stray stub-lake write, caller-side, unreachable from any site fix). **The `-F` in the activation proof is load-bearing** — the `$` in `${PIPELINE_RAW_DIR:-$TELEMETRY_RAW_DIR}` is a regex anchor, so a plain `grep -q` never matches and the proof would read "activated" from day one without anything being fixed; verified reading FALSE on `origin/main` with `-F` before this item was approved. Reference: `pipeline-retro-health.sh`'s header (temperloop#1185) states the rule this fixes — the pipeline stream must not use a checkout-relative root at all.
  - pr: 1574

## Merge gate log

- L0 · 2026-08-15T13:52Z · modal-approved · PR #1569 — operator approved after all gate predicates read clean (OPEN/MERGEABLE/CLEAN/SUCCESS, no risk labels, single-PR set so pairwise and union checks vacuous). Backend NATIVE + STRICT. Autonomy NOT extended to L1 — that gate re-asks.
- L1 · 2026-08-15T14:35Z · operator-granted (merge without approval, scoped to epic #1414) · PR #1574 — predicates verified clean before merging (OPEN/MERGEABLE/CLEAN/SUCCESS, no risk labels, single-PR set). Grant held back once earlier this level when the shell review found a live regression; merged only after that was fixed and independently re-verified.
