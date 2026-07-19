---
tags: [plan, project/temperloop]
date: 2026-07-19
source_kind: claude-stamped
source_session: 09f01684
source_model: claude-opus-4-8
last_verified: 2026-07-19
epic: 565
sources: ["#565", "#560", "#563", "#497"]
status: executing
---

# temperloop - adopter git-safety install surface

## Run status

run started 2026-07-19 · session 09f01684 · level 0/1 active · items: 0 done / 0 parked / 0 in-flight / 0 skipped

## Problem

The kernel's agent/reviewer install & activation surface unsafely mutates a downstream consumer/adopter repo's **tracked** git. ADR 0007 declares reviewer/agent activation is per-checkout and "never imposed on teammates" (`.claude/agents/` gitignored per-checkout) — but that precondition is **unverified and false in the real fleet**, so activating a reviewer in an adopter repo can commit one teammate's personal opt-in state to `main`, corrupt a teammate's existing `.gitignore`, and leak the operator's absolute home path into tracked history. Three concrete failures cause it: the newline-unsafe gitignore-append helper (`reviewer-activate.sh`, on `main` today) glues its entry onto a no-trailing-newline `.gitignore` and destroys the last existing rule; the bulk `project-agents.sh` deploy still writes **absolute** symlinks into an out-of-tree adopter's `.claude/`; and no install path actually **propagates** the `.claude/agents/` + `.claude/reviewer-state/` gitignore entries an adopter needs — the whole per-checkout convention rides on a precondition nothing verifies. It surfaced now because #549 shipped `reviewer-activate.sh` into the fleet (a team-member-persona first-run gate caught it), turning a latent design assumption into a live, teammate-facing corruption.

## Summary

- **The shared gitignore-append helper corrupts a teammate's `.gitignore` and is duplicated across two callers**
  - **L0** — Source-guard `reviewer-activate.sh`, extract a newline-safe shared gitignore helper into one sourceable lib, and fix the unguarded-append bug (`#563`, split)
  - **L1** — De-duplicate: wire `doctor.sh` to the shared lib and delete its private copy (`#563`, split — gated on #564/#550 landing)
- **The deploy path leaks the operator's absolute home path into an adopter's tracked history**
  - **L0** — Make the bulk `project-agents.sh` deploy default to detached copies (not absolute symlinks) for out-of-tree adopters (#497)
- **No install path propagates the gitignore precondition ADR 0007 assumes**
  - **L1** — Propagate/verify the `.claude/agents/` + `.claude/reviewer-state/` gitignore entries at deploy time, reusing the shared helper (#560)

Build order: L0 first → Ln last; items in the same level ship together.

## Sequencing notes

- **L0 fans out cleanly** — `gitignore-safety-lib-and-fix` (touches `reviewer-activate.sh` + a new lib + a test) and `project-agents-out-of-tree-copy-default` (touches `project-agents.sh`) share no files.
- **Land #564/#550 before this epic's L1.** PR #564 (issue #550, *"advisory doctor reviewer-coverage check"*) is OPEN and MERGEABLE and **adds** `_doctor_ensure_reviewer_state_gitignored` to `doctor.sh`. `dedup-doctor-gitignore-helper` de-duplicates *that* copy — it does not exist on `main` yet — so its `gate_check:` blocks until #564 merges. If #564 merges before this plan is built (likely, it's an active sibling PR), the gate lifts immediately and nothing stalls. The live-bug half (`gitignore-safety-lib-and-fix`) is deliberately **ungated** so the teammate-facing `.gitignore` corruption on `main` is fixed without waiting on #564.
- **`propagate-gitignore-precondition-fleet` (#560) and `project-agents-out-of-tree-copy-default` (#497) both edit `project-agents.sh`** — #560 carries a `depends-on: #497` merge edge for that reason, so #497 merges first and #560 rebases onto it. This is honest even though the L0→L1 ordering already sequences them.
- **Install-surface persona validation at build time.** All three install-surface changes should be validated by an executed first-run/uninstall persona run at `/build` verify time (per the parent plan's install-surface mandate), especially the repo-tracked-diff check — `git status` clean on the target adopter checkout after deploy, not just `$HOME` residue. Recorded at build, noted here.

## Re-triage signals

- **(ephemeral — confirm at the approval gate) #497 and #560 are kept as separate items, deliberately — not a missed collapse.** Epic #565's `/assess hints` flagged a possible collapse of #497 into #560. Decomposition call: **keep separate**, because they defend two *distinct* leak vectors. #497 (copy-mode default) removes the operator's absolute path from the deployed artifact *itself* — so nothing leaks even if the target isn't gitignored, or a symlink is force-`git add`-ed, or the operator merely inspects their exposed home layout. #560 (gitignore propagation) makes the `.claude/` *state* untracked-and-unstageable. Collapsing them would leave the artifact-content leak unaddressed whenever propagation hasn't run. Defense-in-depth. **Resolved at approval: split confirmed (operator approved 2026-07-19).**
- **(ephemeral — operator awareness) Funnel overlap with in-flight #550/#564.** Beyond the `doctor.sh` copy that `dedup-doctor-gitignore-helper` collapses, #560's fix direction named a `make doctor` WARN as a candidate home — which is substantially what #550/#564 already ships (the advisory doctor reviewer-coverage check). #560's scope is therefore **pinned to deploy-time propagation** and its doctor-WARN option is **deferred** as covered by #550/#564, to avoid a second doctor surface and a `doctor.sh` merge conflict with `dedup-doctor-gitignore-helper`. No action needed — recorded so the overlap is visible.

## Items

- [x] **Source-guard reviewer-activate.sh, extract a newline-safe shared gitignore helper, fix the append bug** `slug: gitignore-safety-lib-and-fix`
  - branch: `fix/gitignore-safety-lib-and-fix`
  - gh_issue: #569
  - size: M
  - kind: code
  - model: sonnet
  - source: #563
  - files: `workflows/scripts/install/reviewer-activate.sh`, `workflows/scripts/install/gitignore-safety.sh`, `workflows/scripts/tests/test_reviewer_activate.sh`
  - scope: Add a source-guard to `reviewer-activate.sh` so its helpers are safely sourceable; extract the gitignore-append helper into one shared, sourceable lib (`workflows/scripts/install/gitignore-safety.sh`) with a **newline-guarded** append, the existing console-notice-on-write, and the post-write `git check-ignore` re-verification; wire `reviewer-activate.sh` to the shared lib; add a regression test for a no-trailing-newline target `.gitignore`.
  - acceptance:
    - Sourcing `reviewer-activate.sh` defines its helpers **without** running its interactive CLI (a test that sources it produces no activation offer/prompt and no side effects).
    - The gitignore-append helper lives in exactly one shared, sourceable lib under `workflows/scripts/install/`; `reviewer-activate.sh` sources it and no longer defines its own copy (`grep` shows a single definition).
    - Newline-guarded append: a target `.gitignore` that ends **without** a trailing newline keeps its last existing rule intact after the helper appends — regression test uses the #563 repro (`printf 'node_modules/\n*.pyc' > .gitignore`; helper appends `.claude/reviewer-state/`; `git check-ignore x.pyc` still succeeds and the intended entry also matches).
    - The helper prints a console notice on an actual write and re-verifies with `git check-ignore` after appending (behavior preserved through the extraction).
    - `quality-gates.sh` / KERNEL_GATES stays green — shellcheck-clean, the reviewer-activate test suite passes.
  - activation:
    - class: A
    - proof: "test -f workflows/scripts/install/gitignore-safety.sh && grep -q gitignore-safety workflows/scripts/install/reviewer-activate.sh"
  - notes: split_from #563 — the **live-bug** half, deliberately **ungated**: `_ra_ensure_gitignore_entry` on `main` has the unguarded `printf '%s\n' "$entry" >>"$gi"` today and corrupts a teammate's tracked `.gitignore`. The sibling item `dedup-doctor-gitignore-helper` wires `doctor.sh` to this same lib and is gated on #564. Context: [[Plans/2026-07-18 temperloop - language reviewer catalog]] (where #549 shipped `_ra_ensure_gitignore_entry`), ADR 0007 (`docs/adr/0007-language-reviewer-catalog-kernel-placement.md`).
  - pr: 572

- [x] **De-duplicate: wire doctor.sh to the shared gitignore helper, delete its private copy** `slug: dedup-doctor-gitignore-helper`
  - branch: `refactor/dedup-doctor-gitignore-helper`
  - gh_issue: #570
  - size: S
  - kind: code
  - model: sonnet
  - depends-on: gitignore-safety-lib-and-fix
  - source: #563
  - files: `workflows/scripts/install/doctor.sh`
  - gate_check: "grep -q _doctor_ensure_reviewer_state_gitignored workflows/scripts/install/doctor.sh"
  - scope: Wire `doctor.sh` to the shared gitignore-safety lib (from `gitignore-safety-lib-and-fix`) and delete its private `_doctor_ensure_reviewer_state_gitignored` helper, so the fleet holds one newline-safe implementation. No behavior change — pure de-duplication.
  - acceptance:
    - `doctor.sh` sources the shared lib and no longer defines `_doctor_ensure_reviewer_state_gitignored` (`grep` shows zero private copies fleet-wide; one shared definition).
    - `doctor.sh`'s reviewer-state gitignore behavior is unchanged post-dedup (`test_doctor_reviewer_coverage.sh` still passes).
    - `quality-gates.sh` / KERNEL_GATES stays green.
  - activation:
    - class: A
    - proof: "grep -q gitignore-safety workflows/scripts/install/doctor.sh"
  - notes: split_from #563 — the **dedup** half. **External gate:** do not start until PR #564 (issue #550) lands — `doctor.sh`'s `_doctor_ensure_reviewer_state_gitignored` copy exists only in that unmerged PR, so there is nothing to de-duplicate until it merges (the `gate_check:` predicate above checks the consumable, not #550's closed-state). type `refactor` because #564's copy is already newline-guarded — this item only collapses two impls into one. Context: [[Plans/2026-07-18 temperloop - language reviewer catalog]].
  - pr: 575

- [x] **project-agents.sh: default bulk out-of-tree deploys to detached copies, not absolute symlinks** `slug: project-agents-out-of-tree-copy-default`
  - branch: `fix/project-agents-out-of-tree-copy-default`
  - gh_issue: #497
  - size: S
  - kind: code
  - model: sonnet
  - source: #497
  - files: `workflows/scripts/install/project-agents.sh`, `workflows/scripts/tests/test_project_agents_out_of_tree_copy.sh`
  - scope: Make the **bulk-category** `deploy_one()` default to a detached real-file copy for out-of-tree adopters instead of an absolute symlink back into the operator's kernel checkout — mirroring the `--only` path (`deploy_only()`) already shipped. In-tree (the project **is** the kernel checkout) keeps the relative `../../claude/...` symlink; explicit `--copy` and `--dry-run` are unchanged.
  - acceptance:
    - An out-of-tree bulk deploy (`--project-dir <other-repo>`, no `--copy`) produces **real-file copies**, never an absolute symlink into the operator's kernel checkout (verify: deployed agent is a regular file; `readlink` is empty).
    - An in-tree deploy (project **is** the kernel checkout) still produces the relative `../../claude/...` symlink — unchanged.
    - Explicit `--copy` and `--dry-run` behavior is unchanged.
    - No operator absolute path (`/Users/...` / `$HOME`) appears in any deployed artifact for an out-of-tree target.
  - activation:
    - class: A
    - proof: "bash workflows/scripts/tests/test_project_agents_out_of_tree_copy.sh"
  - notes: Kept **separate** from #560 as defense-in-depth — this removes the operator's absolute path from the deployed artifact *itself* (protects even a non-gitignored or force-added target), whereas #560 makes the `.claude/` state untracked; two distinct leak vectors (see Re-triage signals). Mirrors the already-shipped `--only` out-of-tree copy default in `deploy_only()`. Context: [[Designs/temperloop - language reviewer catalog]] § 11 (the out-of-tree `--copy`, "no local-path residue" promise the bulk path does not yet keep).
  - pr: 573

- [x] **Propagate/verify the gitignore precondition at deploy time, fleet-wide** `slug: propagate-gitignore-precondition-fleet`
  - branch: `fix/propagate-gitignore-precondition-fleet`
  - gh_issue: #560
  - size: M
  - kind: code
  - model: sonnet
  - depends-on: gitignore-safety-lib-and-fix, project-agents-out-of-tree-copy-default
  - source: #560
  - files: `workflows/scripts/install/project-agents.sh`, `workflows/scripts/install/gitignore-safety.sh`
  - scope: Generalize the gitignore-precondition guarantee beyond `reviewer-activate.sh`: make the `project-agents.sh` deploy path (any category) **ensure** `.claude/agents/` + `.claude/reviewer-state/` are gitignored in a downstream adopter **before** writing state, reusing the shared helper from `gitignore-safety-lib-and-fix` — so ADR 0007's "never imposed on teammates" invariant is propagated/verified by the install path, not merely trusted. Scope **pinned to deploy-time propagation**; the `make doctor` WARN surface is deferred (covered by #550/#564).
  - acceptance:
    - After a `project-agents.sh` deploy into an adopter whose `.gitignore` lacks the entries, both `.claude/agents/` and `.claude/reviewer-state/` resolve ignored (`git check-ignore` passes) — the precondition is **propagated**, not assumed.
    - The propagation calls the shared helper from `gitignore-safety-lib-and-fix` — no third copy of the append logic anywhere in the fleet.
    - A deploy that adds an entry prints an explicit stdout line **naming the path it added** to the target `.gitignore` (pinned mechanism: a deploy-time notice, not a silent write).
    - Fixture: a deploy into a fresh adopter repo with **no** prior `.claude/` gitignore entries ends with `git status` clean — no untracked-but-stageable `.claude/` state (the executed-persona repo-tracked-diff check).
  - activation:
    - class: A
    - proof: "grep -q gitignore-safety workflows/scripts/install/project-agents.sh"
  - notes: `depends-on` `gitignore-safety-lib-and-fix` (imports the shared helper) **and** `project-agents-out-of-tree-copy-default` (both edit `project-agents.sh` — merge-safety). Kept separate from #497 as defense-in-depth (see Re-triage signals). doctor-WARN option deferred as covered by #550/#564. Context: [[Plans/2026-07-18 temperloop - language reviewer catalog]] (#560 filed there as the fleet root-cause), ADR 0007, [[Designs/temperloop - beta milestone]] § 4 (the repo-tracked-diff persona gate).
  - pr: 577
