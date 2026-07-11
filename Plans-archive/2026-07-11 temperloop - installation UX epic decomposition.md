---
tags: [plan, project/temperloop]
date: 2026-07-11
source_kind: claude-stamped
source_session: "67008437"
last_verified: 2026-07-11
epic: 170
sources:
  - "#170"
status: done
---

# temperloop — installation UX epic decomposition (#170)

## Run status

RUN COMPLETE 2026-07-11 · session 67008437 · 8/8 items merged (temperloop PRs 269/270/271/293/294/295/297/301) · epic temperloop#170 CLOSED (Done) · residuals: temperloop#255 (gate propagation), temperloop#296 (vault-hygiene flake), foundation#1141 (plan.sh ladder) · tier-2 workflow awaits secrets provisioning + first manual dispatch

## Problem

The kernel has no blessed install entry point and no uninstall: `bootstrap.sh` plus `make install` stand up the `~/.claude` + `~/.local/bin` machine surface, but nothing records what was created versus replaced, so the surface is irreversible and unverifiable — a stranger who tries the kernel cannot cleanly leave. Configuration has the same gap at the front door: Epic 1 (#169) built the six-rung precedence ladder and the knob registry, but there is no guided way to write a machine conf and no way to see which layer supplied a resolved value. And nothing in CI proves any of the install lifecycle works on a machine that isn't Travis's — a hardcoded-path regression would ship silently. ADR K164 (D6/D7, approved + architecture-reviewed 2026-07-10) fixed the design; this plan decomposes it into buildable seams.

## Summary

- **The machine surface becomes installable and reversible** (D7)
  - **L0** — Machine-surface manifest library: versioned schema in XDG state, created-vs-preexisting per path, lib-owned backup/restore + marker-stamp helpers — the install↔uninstall seam (#170)
  - **L1** — `temperloop install`: installs from `links_enumerate` desired state, records everything via the lib, dry-run + consent, idempotent re-install; carries the VERSIONING.md vendored-vs-installed stance amendment (#170)
  - **L1** — `temperloop uninstall`: reads only the manifest, restores backups, never touches unrecorded paths; delineates the three removal scopes in docs (#170)
- **Configuration gets a front door** (D7)
  - **L0** — `temperloop configure` (AI-guided wizard, degrades to plain prompts, writes only the machine conf) + `temperloop config list` (resolved value + winning ladder rung per registry knob) (#170)
- **CI proves the install lifecycle hermetically** (D6)
  - **L0** — Hermetic sandbox core: throwaway `$HOME` + XDG re-point, stubbed `gh`, `file://` bootstrap; proven by init/eject dry-run legs in quality-gates (#170)
  - **L1** — Sandbox integrity layer: write preflight, post-run drift tripwire, symlink-aware tree-manifest diff helper (#170)
  - **L2** — Tier-1 per-PR install-lifecycle suite: bootstrap → install → doctor → re-install → uninstall → no unexplained residue; local = CI = one script (#170)
  - **L3** — Tier-2 scheduled/release-gate: real try/init/eject round-trip vs the demo repo (#170)

Build order: L0 first → L3 last; items in the same level ship together.

## Sequencing notes

- **The Epic-1 `Consumes` gate is already satisfied** — verified 2026-07-11 on kernel main (v0.11.0): the D5 denylist burn-down baseline has zero data rows (gate strictly green), and the D2 registry + equality/prose lints (`workflows/scripts/config/`) are on main. No item carries an external `gate_check:`.
- **Parallel subcommand PRs are conflict-free by construction** — `bin/temperloop` dispatches discovered files (`bin/subcommands/<name>.sh` IS the subcommand); no shared dispatcher edits.
- **VERSIONING.md CLI-surface rows land per-PR** (the table follows the surface, never leads it — arch-review 2026-07-11): configure-config-cli adds its own rows at L0; install-cli adds the install row + the stance amendment; uninstall-cli adds the uninstall row. The two L1 siblings may textually collide appending adjacent table rows — a trivial conflict the standard `pr.sh rebase` + re-gate handles (Epic-1 precedent with TSV appends). Chosen over a separate docs item to honor the ADR's rows-land-with-the-subcommands amendment; objection welcome at approval.
- **Feature-docs registry appends**: each item claims its new paths in `docs/features/feature-manifest.txt` + per-slug feature doc (kernel `validate-feature-docs` gate); within-level parallel appends may textually conflict — same trivial-rebase handling.
- **New machine-surface namespaces use `temperloop` naming from day one** (D1). The legacy XDG `foundation/` state namespace used by the report-offer machinery is #165's rename problem, not this epic's.
- Cheap wins first within L0: all three items are independent; any order.

## Re-triage signals

- *Ephemeral (resolve at approval):* the per-PR VERSIONING.md row placement above is a judgment call between two reviewer recommendations (per-PR rows vs a dedicated L2 docs item `depends-on` both CLIs). Per-PR was chosen for ADR fidelity; flip to a docs item at approval if the L1 append-conflict risk bothers you.
- *Persistent (routed):* downstream propagation of the tier-1 lifecycle gate (run it in overlay repos' CI, keep it kernel-only, or a scheduled downstream leg) is genuinely new work the epic doesn't cover — captured as **temperloop#255** (Backlog) with the arch-review rationale; decide after the gate is green in kernel CI.

## Items

- [x] **Machine-surface install manifest library** `slug: install-manifest-lib` — Versioned manifest schema + write/read/backup/restore/marker-stamp helpers in XDG state; the install↔uninstall seam
  - branch: `feat/install-manifest-lib`
  - repo: Towheads/temperloop
  - size: M
  - model: sonnet
  - source: #170
  - gh_issue: 261
  - files: `workflows/scripts/install/manifest.sh` (new — domain layer beside `links.sh`/`doctor.sh`, NOT `bin/lib/`), `workflows/scripts/tests/`, `VERSIONING.md`
  - acceptance:
    - Manifest lib with a documented schema stored under `$XDG_STATE_HOME/temperloop/`: a `schema_version` field plus a per-path record of created-vs-preexisting and an **explicit backup-path field** (recorded, never derived)
    - `backup-and-record` and `restore-from-record` are lib helpers (install calls one, uninstall the other); re-install entry-merge/dedupe semantics are a lib invariant — all with tests
    - Read-compat stance explicit and tested: a reader handles all prior schema versions, or refuses legibly naming the version it found (the manifest outlives the code that wrote it)
    - Marker-stamp helper for generated real files (secondary ownership check) + test; paths absent from the manifest are invisible to readers (test)
    - VERSIONING.md's contract-surface table gains a machine-surface-manifest row (schema-change classes; additive under bump rules)
    - The manifest is a separate file from `.foundation/config` (its sole-writer, repo-tree scope preserved)
  - notes: ADR D7 install-manifest amendment — [[Decisions/temperloop - Configuration & installation architecture (K164)]]. Arch-review 2026-07-11: `schema_version` + lib-owned backup mechanics are what make the L1 siblings safely parallel.

- [x] **Configure wizard + config list CLI** `slug: configure-config-cli` — `temperloop configure` (AI-guided, degrades to plain prompts, writes only the machine conf) + `temperloop config list` (resolved value + winning ladder rung)
  - branch: `feat/configure-config-cli`
  - repo: Towheads/temperloop
  - size: M
  - model: sonnet
  - source: #170
  - gh_issue: 262
  - files: `bin/subcommands/configure.sh` (new), `bin/subcommands/config.sh` (new), `VERSIONING.md` (own CLI rows), tests
  - acceptance:
    - `temperloop configure` is AI-guided when the claude CLI is present and degrades to plain prompts without it (tested with claude absent); it writes ONLY the `$XDG_CONFIG_HOME/temperloop/` machine conf (creating the dir itself), never prose or doc files
    - `temperloop config list` prints, for every registry row, the resolved value and the winning ladder rung — resolved by **clean-subshell rung probes** (env-set sentinel → machine conf → repo-local conf → tracked repo conf → registry default), relying on the D2 equality lint's guarantee that a registry default equals its shell literal, so no owning-script sourcing is needed; the CLI-flag rung is reported n/a at list time
    - The overlay registry extension TSV is unioned when present (`knob-registry-lib.sh`)
    - VERSIONING.md's CLI-surface table gains the `configure` + `config list` rows in this same PR (rows land with the surface)
    - Tests run under stubbed claude + throwaway XDG dirs, reusing the existing `bin/subcommands/tests` fake-binary/scratch-tree idiom
  - notes: requirements-audit 2026-07-11 flagged "winning layer" as an assumed-unverified mechanism (the ladder deliberately tracks no winner; `knob_registry_get` returns only the static default) — the probe mechanism above is the pinned answer, made possible by Epic 1's equality lint. ADR D7.

- [x] **Hermetic sandbox core for install-surface tests** `slug: sandbox-core` — Throwaway `$HOME` + four XDG vars, stubbed `gh`, `file://` local-checkout bootstrap; proven by init/eject dry-run legs
  - branch: `test/sandbox-core`
  - repo: Towheads/temperloop
  - size: M
  - model: sonnet
  - source: #170
  - gh_issue: 263
  - files: harness lib (new, under `workflows/scripts/tests/`), `scripts/quality-gates.sh`
  - acceptance:
    - A reusable env-sandbox harness: `HOME=$(mktemp -d)` + all four XDG vars re-pointed inside it, `gh` stubbed, bootstrap-from-local-checkout over a `file://` remote — scoped to the test's subprocesses only
    - Extends/reuses the existing `bin/subcommands/tests` fake-`gh` + throwaway-tree idiom rather than introducing a second stub convention ([[Patterns/Subtraction over mechanism]])
    - `init --dry-run` and `eject --dry-run` legs run green under the harness and are wired into `scripts/quality-gates.sh` (the harness ships with real consumers, preventing speculative-API drift)
    - Sandbox teardown leaves no residue outside the throwaway root (test)
  - notes: ADR D6 isolation model — no container; ephemeral CI VM + local env sandbox. Precedent: `make test-update-kernel` hermetic fixture.

- [x] **Install subcommand + vendored/installed stance amendment** `slug: install-cli` — `temperloop install`: machine surface from `links_enumerate` desired state, all writes recorded via the manifest lib; dry-run + consent
  - branch: `feat/install-cli`
  - repo: Towheads/temperloop
  - size: M
  - model: sonnet
  - depends-on: install-manifest-lib
  - source: #170
  - gh_issue: 264
  - files: `bin/subcommands/install.sh` (new), `VERSIONING.md`, tests
  - acceptance:
    - `temperloop install` installs the machine surface (`links_enumerate` desired state + the composers), recording every touched path via the manifest lib — created vs preexisting, replaced files backed up through the lib helper (test)
    - Idempotent: a second run converges with no duplicate manifest entries and no spurious backups — the lib's merge/dedupe invariant exercised end-to-end (test)
    - `--dry-run` performs zero writes (test); consent mirrors `eject.sh`'s `--yes`/interactive-confirm pattern
    - Generated real files are marker-stamped via the lib helper (test)
    - `doctor.sh` is green after a sandboxed install (test)
    - VERSIONING.md gains the `install` CLI-surface row plus the stance amendment — **vendored = repo integration** (unchanged), **installed = machine surface** (new), superseding kernel-repo-layout.md's no-install-entry-point stance — riding this PR per the ADR (install is what makes "installed" true)
  - notes: a trivial VERSIONING.md table-append collision with `uninstall-cli` is possible at rebase — see Sequencing notes. ADR D7.

- [x] **Uninstall subcommand (manifest-scoped, reversible)** `slug: uninstall-cli` — `temperloop uninstall`: reads only the manifest, restores backups, never touches unrecorded paths; three removal scopes delineated in docs
  - branch: `feat/uninstall-cli`
  - repo: Towheads/temperloop
  - size: M
  - model: sonnet
  - depends-on: install-manifest-lib
  - source: #170
  - gh_issue: 265
  - files: `bin/subcommands/uninstall.sh` (new), `bin/README.md`, `bin/subcommands/eject.sh` (`print_uninstall_bullet`), `VERSIONING.md`, tests
  - acceptance:
    - `temperloop uninstall` reads ONLY the manifest: removes created paths, restores preexisting files from their recorded backups, and never touches a path absent from the manifest (tests)
    - Test fixtures seed manifests via the lib's write helper — never a live `install.sh` run (keeps the L1 siblings decoupled; audit-pinned fixture strategy)
    - The wizard-written machine conf (absent from the manifest) is user data and survives uninstall (test); an unreadable/newer manifest `schema_version` produces a legible refusal, not partial deletion
    - `--dry-run` performs zero writes (test); consent mirrors eject
    - `bin/README.md`'s Uninstall section + `eject.sh`'s `print_uninstall_bullet` are updated to delineate the three removal scopes — bootstrap footprint (`~/.local/bin` + `~/.local/share/temperloop`, written before any manifest existed) / `temperloop uninstall` (manifest-scoped machine surface) / `eject` (target-repo side effects) — with an explicit stance on whether uninstall touches the bootstrap footprint
    - VERSIONING.md gains its `uninstall` CLI-surface row
  - notes: ADR D7. The preserve-user-config call and the bootstrap-footprint stance were the arch review's unowned seams — both assigned here.

- [x] **Sandbox integrity layer: preflight, tripwire, tree-diff** `slug: sandbox-integrity` — Write preflight + post-run drift tripwire + symlink-aware tree-manifest diff helper on top of the sandbox core
  - branch: `test/sandbox-integrity`
  - repo: Towheads/temperloop
  - size: M
  - model: sonnet
  - depends-on: sandbox-core
  - source: #170
  - gh_issue: 266
  - files: harness lib (extends sandbox-core's), tests
  - acceptance:
    - Write preflight: every `links_enumerate` target is asserted to resolve under the sandbox root before the first write; negative test — a hardcoded absolute path fails the preflight
    - Post-run tripwire: the real `~/.claude` + `~/.local/bin/temperloop` are hashed before/after the sandboxed run and any drift fails the suite; negative test
    - Symlink-aware tree-manifest diff helper (paths + hashes) against a **caller-supplied** exclusion set — no hardcoded set; each consumer owns its own
    - All three are standalone harness-lib helpers (no consumer needs to reach into harness internals)
  - notes: ADR D6 belt-and-suspenders for the local (non-VM) leg. `depends-on` is merge-safety: extends the same harness lib file sandbox-core creates.

- [x] **Tier-1 hermetic install-lifecycle CI suite** `slug: ci-install-lifecycle` — Per-PR: bootstrap → install → doctor → idempotent re-install → uninstall → no unexplained residue; one script local = CI
  - branch: `test/ci-install-lifecycle`
  - repo: Towheads/temperloop
  - size: M
  - model: sonnet
  - depends-on: sandbox-integrity, install-cli, uninstall-cli
  - source: #170
  - gh_issue: 267
  - files: lifecycle suite (new, under `workflows/scripts/tests/`), `scripts/quality-gates.sh`
  - acceptance:
    - The tier-1 suite runs under the sandbox harness: bootstrap (`file://`) → `temperloop install` → `doctor` green → idempotent re-install → `temperloop uninstall` → tree-manifest diff shows **no unexplained residue** against the suite's declared exclusion set (which includes the XDG-config path wizard-written conf would occupy)
    - Wired into `scripts/quality-gates.sh` so local gate = CI gate = `/build` acceptance gate (one script)
    - Green on Linux CI (mini-gated hooks no-op cleanly; the suite validates install *machinery*, macOS runtime stays operator-verified per the ADR trade-off)
    - The gate **self-scopes to the kernel repo**: in a composed overlay tree it no-ops with a legible skip notice — downstream propagation is temperloop#255's deliberate decision, not an accident of KERNEL_GATES flow
  - notes: `depends-on` all three is merge-safety in effect — merged any earlier, the suite turns main's `checks` red (subcommands/harness absent). ADR D6.

- [x] **Tier-2 scheduled real-round-trip release gate** `slug: ci-install-tier2` — Scheduled/release-gate workflow: real try/init/eject round-trip against the demo repo; never per-PR
  - branch: `test/ci-install-tier2`
  - repo: Towheads/temperloop
  - size: M
  - model: sonnet
  - after: ci-install-lifecycle
  - source: #170
  - gh_issue: 268
  - files: `.github/workflows/` (new scheduled workflow)
  - acceptance:
    - A scheduled + manually-triggerable workflow (never per-PR) runs the real `try` → `init` → `eject` round-trip against the demo repo
    - Green on a manual dispatch run (evidence linked in the PR body)
    - The cost posture is documented in the workflow header: API + token cost is why this is tier-2; cadence and its release-gate role stated
    - A failing scheduled run surfaces legibly (workflow failure visible on the repo, not silently swallowed)
  - notes: `after:` is logical-order only — a separate scheduled workflow file, no shared edits with tier-1 (audit-confirmed). ADR D6 tier-2.

## Merge gate log

- level 0 · 2026-07-11T17:58Z · modal-approved (risky pair #269×#271 on VERSIONING.md/feature-manifest.txt; operator chose serial) · consented set: temperloop#269, temperloop#270 enqueue now; temperloop#271 rebase-resolve → re-gate → re-CI → enqueue after they land
- level 1 · 2026-07-11T20:55Z · modal-approval-extended (same risky shape as L0: hub PR #295 conflicts with #293 on VERSIONING.md and #294 on quality-gates.sh; operator's L0 serial choice + standing approval-scope grant applied) · consented set: temperloop#293, temperloop#294 enqueue now; temperloop#295 rebase-resolve → re-gate → re-CI → enqueue after
- level 2 · 2026-07-11T22:32Z · timed-elapsed (single clean PR, 300s window announced in-session, no objection; re-validated OPEN+CLEAN at wake) · consented set: temperloop#297
- level 3 · 2026-07-11T23:59Z · timed-elapsed (single clean PR, 300s window announced in-session, no objection; re-validated OPEN+CLEAN at wake) · consented set: temperloop#301
