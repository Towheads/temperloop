# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/). See
[`VERSIONING.md`](VERSIONING.md) for the canonical bump rules and what each
tier signals.

Pre-1.0, the breaking signal rides the CHANGELOG, not the version number: a
release that changes the contract surface in a way an overlay must adapt to
**tags its section `BREAKING`** and includes a migration note. `update-kernel`
reads that marker; a stranger greps for it before pulling.

## [Unreleased] — BREAKING

**`BREAKING`** — ships as a **minor-breaking 0.x bump (v0.15.0)** per
VERSIONING.md's pre-1.0 rules: the foundation→temperloop identity rename
(temperloop#165), **read-old-write-new**. Every legacy `foundation` name
keeps working through the migration window with a one-line deprecation
notice, and the legacy reads are **removed in v0.17.0** — touch your
overlay/config/env before that release, not necessarily before this pull.

### Changed

- **BREAKING — the stranger-facing `foundation` names are renamed
  `temperloop` (temperloop#165), read-old-write-new; legacy names are
  removed in v0.17.0.** The surfaces, each with new-name canonical + a
  windowed legacy read:
  - **Env-var prefix**: `TEMPERLOOP_HOME` / `TEMPERLOOP_BIN_DIR` /
    `TEMPERLOOP_KERNEL_REPO` / `TEMPERLOOP_VERSION` are the canonical env
    knobs (bootstrap, dispatcher, feedback, CI, sandbox). A set legacy
    `FOUNDATION_*` var still works while its twin is unset (precedence:
    new > old > default) and prints a one-line deprecation notice. Knob
    registry: four new `TEMPERLOOP_*` rows; the `FOUNDATION_*` rows are
    marked `DEPRECATED` in their doc column and are deleted in v0.17.0 — a
    removed row-name, i.e. BREAKING per the registry's own rule, which is
    exactly what this marked section signals.
  - **CLI compat shim**: `foundation <sub>` still dispatches (now printing
    one deprecation NOTE per invocation); the shim is removed in v0.17.0 —
    invoke `temperloop`.
  - **Committed per-repo config**: `temperloop init` writes
    `.temperloop/config` (recovery marker + self-managed `.gitignore`
    included); a legacy `.foundation/config` is still read on re-run, and
    `temperloop eject` cleans either dir (legacy cleanup deliberately
    survives the window). `baseline-snapshot` continues an existing legacy
    baseline in place; `report` and the 14-day offer probe new-then-legacy
    for `baseline.jsonl` and `report.d/`.
  - **Legacy `$XDG_CONFIG_HOME/foundation/` subdir**: the machine
    boards.conf default is now `$XDG_CONFIG_HOME/temperloop/boards.conf`;
    an existing legacy `foundation/boards.conf` is read as fallback at all
    seven reader sites (board.sh, funnel-drive/tick, deploy-mini, doctor,
    links).
  - **Knowledge-store default namespace** (published-contract change,
    `knowledge_store.contract.md`): the default root is now
    `${XDG_DATA_HOME:-$HOME/.local/share}/temperloop/knowledge`; an
    existing store at the legacy `foundation/knowledge` default is still
    found (one NOTE per process). Fresh installs create under
    `temperloop/`.
  - **Grandfathered machine-state paths deliberately NOT migrated here**
    (allowlisted-as-legacy; the gate-sweep item formalizes):
    `ENV_RECONCILE_AGENT_HEARTBEAT_DIR` and the
    `${XDG_STATE_HOME}/foundation/` machine-state family (hook state dirs,
    `KNOWLEDGE_READ_LOG`, `KNOWLEDGE_SEARCH_BM_HOME`, report-offer
    dismissals) — cross-host writers/readers (launchd agents,
    env-reconcile freshness oracles) update on their own cadence, and a
    split-state window is worse than a delayed coordinated move. `KS_LIB_DIR`
    needs no action (name-neutral, no foundation-named default).

  **Migration** (any time before v0.17.0): rename `FOUNDATION_*` env vars
  to `TEMPERLOOP_*` in your shell profile/CI/overlay config; switch
  `foundation <sub>` invocations to `temperloop <sub>`; `git mv .foundation
  .temperloop` in any repo you ran `init` in (or run `temperloop eject` /
  re-`init`); `mkdir -p ~/.config/temperloop && mv
  ~/.config/foundation/boards.conf ~/.config/temperloop/`; and `mv
  "${XDG_DATA_HOME:-$HOME/.local/share}/foundation/knowledge"
  "${XDG_DATA_HOME:-$HOME/.local/share}/temperloop/knowledge"` (or set
  `KNOWLEDGE_STORE_ROOT`). Until you migrate, everything keeps working —
  each legacy use tells you so on stderr. New hermetic gate:
  `test_rename_compat.sh` (legacy-env install, shim dispatch,
  adjacent-tag update through the shim, legacy on-disk artifact reads, and
  the window-closed legible-degradation simulation).

### Added

- **`claude/design-schema.md` § Kernel dimension list gains dimension `0`
  — Premise & null hypothesis (temperloop#508, epic temperloop#498).**
  Additive, not breaking: no existing dimension is removed, reordered, or
  has its enforcing-gate binding changed — dimensions 1–16 keep their
  numbers and meaning unchanged. The new row records the do-nothing cost,
  the strongest subtraction/existing-surface alternative, and the
  operator's justification for proceeding (or the kill rationale), enforced
  by the forthcoming `/workshop` Step 1.3b premise gate (temperloop#509).
  **Dimension 0 spends the schema's only prepend slot**: numbering it `0`
  (rather than appending `17`) is what lets it sort and be walked *first*,
  ahead of every other dimension, without renumbering 1–16 — but that slot
  is a one-time move. A future *intake-time* dimension (one that must also
  walk before dimension 1) cannot reuse this trick a second time; it forces
  a real renumbering of the kernel list. Never reach for a negative number
  (`-1`) to dodge that — see § Overlay extensibility's numbering-namespace
  note in the schema doc for why the namespace is reserved the way it is.
  Dimension 0 is also the schema's first **`filled`-only** dimension: `n/a`
  and `deferred` are invalid dispositions for it (§ Disposition grammar) —
  a deferred premise is exactly the unexamined-idea gap the gate exists to
  close. The worked-example skeleton gains a matching `## 0.` section.
  **Migration note for in-flight `draft` briefs:** an existing `Designs/*.md`
  brief written before this change has no dimension-0 section; it needs a
  **one-touch migration** — add `## 0. Premise & null hypothesis` with a
  `filled` disposition — before it can pass a ratify-time coverage check
  that includes dimension 0. A brief already `status: ratified` is
  unaffected (ratified briefs are immutable per § Frontmatter; the gap is
  grandfathered, not retroactively invalid). Same-PR opportunistic cleanup:
  every stale `/design` command reference in `claude/design-schema.md` is
  updated to `/workshop` (the command was renamed in temperloop#354; this
  schema doc had not yet been swept), and the doc's dimension-count prose
  (`claude/design-schema.md`, `claude/commands/workshop.md`,
  `docs/features/workshop.md`) is updated from sixteen/16 to
  seventeen/17 throughout.

- **`claude/design-schema.md` § Frontmatter `status` enum gains `dropped`
  (temperloop#509, epic temperloop#498).** Additive, not breaking: `draft`
  and `ratified` keep their meaning and the `draft → ratified` ratify path is
  unchanged. `dropped` is a third **terminal** value a brief reaches only via
  the new `/workshop` Step 1.3b premise-gate **drop action** — a killed idea
  whose dimension 0 carries the kill rationale (disposition `filled`), neither
  ratified nor materialized. **A consumer or overlay that pattern-matches the
  `status` field on `draft|ratified` must be told about `dropped`** (a lint,
  dashboard, or reader enumerating brief states) — hence this additive marker,
  parallel to the dimension-0 additive note above. Reopening a `dropped` brief
  requires an explicit operator confirmation (`/workshop` Step 1.4 stops on a
  dropped brief rather than silently re-adopting it as a draft). The paired
  `/workshop` prose change — the Step 1.3b premise gate (composes the case
  *against* citing `docs/principles.md` by name, records the operator's
  justification into dimension 0, offers proceed/reshape/drop) plus the Step
  1.4 dropped-branch stop-and-reopen-confirm — ships in the same PR.

### Deprecated

- **The Projects-v2/GraphQL board adapter arm is deprecated (epic
  temperloop#460), removed by the follow-on BREAKING removal epic
  temperloop#524 "Remove the Projects-v2/GraphQL arm (BREAKING) —
  post-soak follow-on to epic #460".** Classified **non-breaking/minor**
  for *this* bullet: marking an arm deprecated changes no behavior — the
  GraphQL arm remains fully functional through the soak window this entry
  opens, and `changelog_breaking_sections()` (`workflows/scripts/lib/
  changelog.sh`) can't parse this untagged `## [Unreleased] — BREAKING`
  section's per-bullet classification (its `BREAKING`-marker scan is
  section-level, keyed off `VERSIONING.md`'s bump-rules table), so the
  classification is stated here in prose instead — precedent: the
  worklist-Seq-retire bullet above does the same. All four fleet boards
  (ssmobile, stageFind, subsetwiki, foundation) plus the kernel's own
  tracker now run issues-only per ADR 0004; the GraphQL arm (the budget
  guard, the structure/state cache split, `migrate-board-to-issues.sh`,
  and the rest of the Projects-v2 branchwork) stays live and supported for
  any adopter still migrating, and is removed outright — a real BREAKING
  cut — once the removal epic ships, per its own migration-ordering
  contract.

### Removed

- **`workflows/scripts/board/worklist.sh`: the Seq display column and its
  `.seq // 9999` sort key are retired (temperloop#474, epic
  temperloop#460) — the read-side completion of ADR 0006's Seq
  retirement.** Classified **non-breaking/minor** against VERSIONING.md's
  Board adapter interface contract-surface row: `worklist.sh`'s
  human-readable text output is not one of that row's coupling points
  (`board_resolve_item` / `board_resolve` / `board_item_list` /
  `board_set_*` function signatures and JSON shapes are all untouched), and
  by this level every registered board (all four fleet boards plus the
  temperloop issues-only tracker) is issues-backed per ADR 0006 — no board
  has carried a live Seq value since the write side (`board_set_number`)
  was already changed to fail loud at epic temperloop#460's L0, so the
  column has been permanently empty everywhere it could still render.
  Output is otherwise unchanged: the `--all` and default (In-Progress)
  views keep the same remaining columns, and sort order now falls back to
  ascending issue number (`sort_by(.content.number)`, replacing
  `sort_by(.seq // 9999)`) for deterministic ordering. The two header
  comments mentioning Seq are updated to match.

### Fixed

- `reconcile.sh`: shellcheck directive on the label-lens optional
  knowledge-store source is now `disable=SC1090,SC1091` (was `source=<path>`)
  — the sync deliberately omits that lib from consumer repos and the runtime
  already skips fail-open behind an `-f` guard, so a consumer's bare-shellcheck
  CI no longer fails on the synced copy (#495).

## [0.14.1] - 2026-07-18

Patch. Safe pull, no migration — no `BREAKING` marker. CI-portability fix
for composed consumer trees (temperloop#488): the two v0.14.0 gate
registrations that test kernel-context surfaces — the `bin/subcommands/
update.sh` managed-clone CLI gate and the `scripts/update-kernel.sh`
breaking-delta gate — are now **surface-conditional**. Each registers only
when its surface is actually present (a `bin/subcommands/update.sh` file;
the seam-bearing `update-kernel.sh`, detected by its `KERNEL_UPDATE_ROOT`
test seam) and otherwise prints a legible `skipped gate — <reason>` line,
in both the run output and `--list` (`[skipped]` rows). In the kernel's own
checkout both surfaces exist, so both gates always run — behavior there is
unchanged. A consuming repo whose composed tree legitimately lacks the
surface (no `bin/` adoption; a bespoke overlay vendoring flow) no longer
fails CI on tests for code it doesn't ship.

### Fixed
- `scripts/quality-gates.sh`: `test_update_subcommand.sh` and
  `test_update_kernel.sh` registrations guard on their surface, with
  legible skip lines — never a silent no-op (#488).

## [0.14.0] - 2026-07-18

Additive minor. Safe pull, no migration — no `BREAKING` marker. The headline
is the **issues-only tracking changes** (epic #460's first dependency
level): the `boards.conf`
backend axis now resolves per-key so a machine conf silent on a board no
longer shadows a committed repo-local `backend=issues` flip,
`board_set_number` fails loud on the issues-only backend (Seq retired by
design, ADR 0006), a dry-run-first Projects→issues migration script ships,
and `/tidy` gains a board label-hygiene sweep. Draft ADRs 0004–0006 (all
`Status: Proposed`) land alongside, recording the issues-only-default
decision, the repo-local conf-cutover mechanism, and the Seq retirement.
**Soak-window note:** the issues-only path is deliberately uncached and
always-live, and migrating the four maintainer boards onto it (this epic's
follow-on cutover work) is the first real volume test of that posture — REST
consumption is monitored during the soak window that follows this release,
with the existing per-board `cache=on` axis (`boards.conf`) as the ready
mitigation (ADR 0004 § Consequences).

The release also carries the `/check-in` pipeline-command contract
**growing** (its Part 1 telemetry brief now renders kernel-side on every
checkout; nothing existing changes shape — the overlay renderer keeps its
exact guarded invocation as an enrichment) plus the additions below.

### Fixed

- **`board_backend()` resolves the `boards.conf` backend axis per-key, not
  whole-file (#478, closes #465).** A machine-level conf that is silent on a
  given board's backend no longer shadows a committed repo-local
  `backend=issues` flip: a new `_board_conf_get_layered()` helper walks every
  existing conf file (machine, then repo-local) and returns the first
  per-key match, for the `backend` axis only — every other axis
  (`repo`/`owner`/`project`) keeps the original whole-file "first hit wins"
  behavior (`test_boards_conf.sh` section 3 pins it unchanged). An explicit
  machine-level `backend=` line still wins outright.
- **`board_set_number` fails loud on the issues-only backend — Seq retired
  by design, not emulated (#480, closes #464, ADR 0006).** A new `ISSUE_*`
  case branch replaces a silent `return 1` with a documented stderr message
  naming the retirement (ordering now lives in epic dependency levels and
  milestones); its test asserts on the message with stderr unsuppressed.
  `claude/commands/triage.md`'s three Seq special-case sites and
  `ISSUES-ONLY-BACKEND.md`'s two Seq rows are reworded from "deferred" to
  "retired by design"; `worklist.sh`'s Seq column/sort key is intentionally
  untouched (read-side retirement is a follow-on item).

### Added

- **`migrate-board-to-issues.sh` — dry-run-first Projects→issues migration
  script (#481, closes #466).** Reads a board's Status/Component via the
  Projects arm and writes `fnd:` labels via the existing issues-arm write
  path (`board_set_status`/`board_set_component`), with schema-level
  validation that refuses an unrecognized single-select field or Status
  option before any write. Dry-run is the default (prints the full
  field-to-label mapping table, zero writes); `--apply` writes and then
  verifies every open item reads identically through `backend=issues`;
  idempotent (a second `--apply` reports zero changes); emits a per-repo
  report. Covered by a fixture-replay test suite, zero network.
- **`reconcile.sh --labels` — board label-hygiene sweep (#482, closes
  #463).** A third `reconcile.sh` lens that reports and, on
  `--apply`/`--unattended`, deletes orphaned `fnd:host/session:*` repo
  labels (zero open-issue attachments, re-checked immediately before each
  delete) and strips stale `fnd:status:*` labels from closed issues (the
  bare-`Closes #N` adapter-bypass leak) — strictly `fnd:`-namespaced, never
  touching a non-`fnd:` label. Dry-run is the interactive default; unattended
  default is apply, with a `### open` pending-decisions append per the
  batch-at-ritual rule (never a silent auto-take). Wired into `tidy.md`'s
  "Stale board claims" step, invoked per governed board, plus the kernel
  tracker itself (board 7); a live dry-run against the real kernel tracker
  found 19 orphaned host/session labels and 155 stale status labels, confirming the
  gap was genuine.
- **Zero-GraphQL CLI-entrypoint test (#479, closes #467).**
  `test_cli_entrypoint_no_graphql.sh` runs
  `worklist.sh`/`claim.sh`/`capture.sh`/`reconcile.sh` as real subprocesses
  against a `backend=issues` board through a PATH-shadowed `gh` logging
  shim, asserting zero `gh project` and zero `gh api graphql` calls at the
  process level — complementing the existing function-level coverage in
  `test_issues_backend.sh` / `test_issues_claim_edges.sh` / `test_capture.sh`.
  Verified to actually catch a regression before landing (forced
  `board_backend` to answer `projects`, confirmed 7/9 checks failed, then
  reverted).
- **Draft ADRs 0004–0006 for issues-only-everywhere (epic #460, PR #461).**
  `docs/adr/0004-issues-only-default-backend.md`,
  `0005-repo-local-conf-cutover.md`, and `0006-seq-retired-on-issues-only.md`
  — all `Status: Proposed` — record the issues-only-default decision
  (Projects-v2 deprecated this release, removed in a follow-on breaking
  release after a soak), the repo-local `boards.conf`-entry cutover
  mechanism (per-repo commit, not the kernel's built-in map), and the
  Seq-retirement rationale this release's `board_set_number` fix
  implements.

- **Knowledge-store sync — optional backend capability (temperloop#430, ADR
  0003).** `ks_sync` (`init <remote-url>` / `push [-m <msg>]` / `pull` /
  `status`) plus the `ks_sync_available` probe: git-backed, **manual-only**
  replication of the `plain-files` store (the store directory becomes a git
  repo with one `origin` remote, private by default), so a second
  environment can `init` against the operator's remote and `pull` the real
  store. Sync is a *capability*, not a universal op: a backend that cannot
  implement it (`obsidian` never consults `KNOWLEDGE_STORE_ROOT`) degrades
  to exit 3 with `skipped — sync unavailable for backend <name>` — the
  `ks_search` availability-probe pattern, never a silent no-op or a hard
  failure. All sync ops route through the `ks_` dispatch; the store —
  including its `.git` and remote config — is user data `temperloop
  uninstall` keeps intact (`test_install_lifecycle.sh`'s residue diff now
  proves no sync-specific state survives outside the explicitly-kept store
  dir). EXPERIMENTAL: single-tenant per `$HOME` (per-project partition
  deferred — temperloop#418), single-writer (`pull` is `--ff-only`); the
  thin entry `workflows/scripts/lib/knowledge_sync.sh` is deliberately kept
  out of the stranger-facing CLI reference so the `temperloop sync`
  promotion decision stays open. New hermetic gate:
  `test_knowledge_store_sync.sh` (two-environment bootstrap against a local
  bare remote, zero network).

  *Published-contracts mark (`VERSIONING.md` § Published schemas/contracts):
  additive change to `workflows/scripts/lib/knowledge_store.contract.md` —
  new § Sync (optional backend capability), a backend-matrix Sync row, and
  the read-log `op` set gaining `sync`. Minor, not `BREAKING`: no existing
  backend, caller, or overlay must change (no backend inherits a new
  required op; the read-log line shape — field order/count/separator — is
  untouched).*

- **Kernel-side telemetry-brief renderer (temperloop#431).**
  `workflows/scripts/telemetry-brief.sh` renders the five-question telemetry
  brief (attention, funnel health & trust, spend, improvement, command
  effectiveness) from **kernel-only raw streams** — the `meta/data/raw/` lake
  (`command-runs`, `issue-touches` ∪ `claims`, `funnel`, `gh-calls`,
  `knowledge-search-fallback`) plus the knowledge-store read log
  (`ks__read_log_emit`) — so the brief and `/check-in`'s daily render work on
  a bare kernel checkout with no overlay, vault, or rollup pipeline. Every
  section names its source stream verbatim (numbers are reconcilable by
  reading the named file); an absent or empty stream degrades to an honest
  "no data yet — <stream> is empty" line, never a crash or a fabricated
  number; records with no in-window hits report the freshest record found
  instead of rendering zeros as current. Leads with cross-stream `DATA AGE`
  (alarming `DATA STALE` past 24h), matching the overlay renderer's contract.
  Reader follows the emitters' own `*_RAW_DIR` overrides first, falling back
  to the new `TELEMETRY_RAW_DIR` knob; window set by `TELEMETRY_LOOKBACK_DAYS`
  / `--lookback-days` (both registered in `knob-registry.tsv`). Covered by a
  new `KERNEL_GATES` test (`workflows/scripts/tests/test_telemetry_brief.sh`:
  fixture-lake reconciliation, empty-stream degradation, stale-window honesty,
  torn-line resilience, check-in wiring presence).
- **`/check-in` Part 1 renders kernel-first (contract change, additive).**
  `claude/commands/check-in.md` Part 1 previously skipped the telemetry brief
  entirely on a kernel-only checkout (`telemetry brief unavailable — no
  renderer in this checkout`); it now always renders the kernel brief via
  `workflows/scripts/telemetry-brief.sh`, then renders the overlay
  `build_telemetry_brief.py` digest as a guarded enrichment when present —
  same one-directional kernel→overlay reference rule as before (the overlay
  call stays behind its `[ -f … ]` existence guard).

- **`temperloop update` — the sole post-install HEAD mover of the managed
  clone (temperloop#429, ADR 0002 "Managed-clone state ownership").**
  `bin/subcommands/update.sh` fetches tags (auto-converting a `--depth 1`
  tagless clone — `bin/bootstrap.sh`'s current shape — via
  `git fetch --unshallow`), surfaces the full CHANGELOG delta with any
  `BREAKING` section called out BEFORE a consent-gated checkout (`--yes`, an
  interactive y/N, or a legible refusal on a non-interactive run — no
  timeout-as-consent), re-runs the manifest-backed `temperloop install`, and
  finishes with `doctor`. Before touching HEAD it also checks the on-disk
  install manifest's `schema_version` against the target tag's own
  `manifest.sh` — an incompatible schema halts with instructions rather than
  guessing. Never writes a repo-tracked path in any other repo (no `--dir`
  argument; its entire write surface is the managed clone's own git state
  plus the machine surface `install.sh` already owns).
- **`workflows/scripts/lib/changelog.sh` — shared CHANGELOG-range parsing.**
  `semver_major()`/`breaking_sections()` lifted out of
  `scripts/update-kernel.sh`'s own private helpers into a sourceable lib
  (`changelog_semver_major`/`changelog_sections_in_range`/
  `changelog_breaking_sections`) so both `update-kernel.sh` and the new
  `update` subcommand share one implementation instead of `bin/`
  back-channeling into `scripts/`. `update-kernel.sh` resolves it
  script-relative; behavior is unchanged (see its own regression suite,
  `scripts/tests/test_update_kernel.sh`).

- **`temperloop feedback` — consent-gated feedback submit mechanism (#428).**
  A new CLI subcommand (`bin/subcommands/feedback.sh`) that sends feedback to
  the kernel maintainers via a GitHub issue on the kernel's own upstream
  tracker — deliberately distinct from `temperloop report` (which only ever
  renders a stranger's own local before/after metrics and never transmits
  anything).
  Nothing repo-derived leaves the machine without: (1) composing the payload
  to a single artifact file, (2) running the same
  `personal-token-denylist.tsv` RULESET that guards the kernel file set
  against that composed payload itself — a hit blocks transmission and names
  the matching pattern, (3) previewing the exact payload bytes, and (4) an
  explicit, interactively-typed "yes" at a real prompt — there is no `--yes`
  bypass for this step. A closed/non-TTY stdin, or a `CI`/`GITHUB_ACTIONS`
  unattended-environment signal, always refuses to transmit with a legible
  message: a timeout or a flag is never consent for an external write. See
  `bin/subcommands/feedback.sh`'s own header for the full contract.

## [0.13.1] - 2026-07-17

Patch. Safe pull, no migration — no `BREAKING` marker. CI-resilience fix only:
the composed quality-gate run now absorbs transient macOS-runner flakiness
without letting a real breakage through.

### Fixed

- **Bounded per-gate retry in the composed gate run (#404, temperloop#403).**
  `scripts/quality-gates.sh` ran each gate exactly once, so a transient
  `macos-latest` runner failure (fork/exec/IO under load) in *any* hermetic
  gate failed the whole `checks` job and stalled the merge queue — observed
  across unrelated gates that share no code and pass locally and on Ubuntu.
  The serial gate loop is now wrapped in a bounded retry (`GATE_MAX_ATTEMPTS`,
  default `3`): a real breakage fails every attempt and still gates, while a
  flake clears on a retry. Retries are logged per-attempt and summarized at
  end-of-run so a flake stays visible rather than silently masked; set
  `GATE_MAX_ATTEMPTS=1` to disable when hunting a genuine intermittent bug.
  Green runs retry nothing, so there is no added CI time in the common case.
- **`GATE_MAX_ATTEMPTS` registered in the knob registry (#404).** The new
  `${VAR:-default}` retry seam carries its `knob-registry.tsv` row (kernel
  layer, int, default `3`, owning `scripts/quality-gates.sh`), so the
  unregistered-knob sweep passes and the registry↔shell equality lint's
  default matches the shell default.

## [0.13.0] - 2026-07-17

Additive minor. Safe pull, no migration — no `BREAKING` marker. The headline
is the **activation-completeness contract** (epic #317): a new capability an
overlay opts into, not a change to anything existing. Its one new hard-fail
(plan-schema rule 14) ships with a **grandfather cutover** deliberately
engineered to keep the release non-breaking — every plan authored before
`2026-07-17` is exempt, so no already-approved in-flight plan breaks on pull
(see `VERSIONING.md` and `plan-schema.md` § Rule 14).

### Added

- **Activation-completeness contract (epic #317).** Splits "done" into
  **merged** (code + CI) vs **activated** (the built thing provably live), so a
  correct-but-never-wired-in change can no longer read as complete. Three
  activation classes, each with its own discharge path:
  - **Class A — synchronous / in-repo.** `/build` gains a Step 3e.6 activation
    gate that runs an item's `activation: class: A` `proof:` predicate against
    its own reachability surface (the `__init__.py` entry, the flipped flag, the
    rendered panel) before the item counts as done. (#319)
  - **Pending-activations ledger.** New grammar in `/check-in`
    (`class` / `proof` / `locus` / `watermark` / `soak-until` / `soak_check` /
    `status`); only `/check-in` and `/tidy` mutate a record's `status`. (#392)
  - **plan-schema rule 14 — require `activation:` on product-source items.** A
    `kind: code` item whose `files:` touch `scripts/`, `workflows/`, or
    `claude/` must declare an `activation:` block. Shipped with a grandfather
    cutover (`RULE_14_CUTOVER_DATE`, `2026-07-17`) so pre-cutover plans stay
    exempt — the mechanism that keeps this release non-breaking. (#393)
  - **Epic-close activation accounting.** `/build`'s 4d-epic step refuses to
    close an epic while any `<epic>-*` record on the ledger is still `open`, and
    emits class-B/C records at child-close. (#394)
  - **Class-B discharge — cross-repo propagation.** `/check-in` reads each
    consumer's `.kernel-pin` tag and discharges a class-B record once every
    consumer's pin is at or past the shipping watermark. (#395)
  - **Class-A activation-registry CI validator.** `validate-activation-registry.sh`
    (a new quality gate, `validate-live-drain.sh`'s mold applied to
    `Plans-archive/*.md`'s `activation:` blocks) — reads archived plans only,
    never the live vault. (#396)
  - **Class-C discharge — time-deferred / soak.** `/tidy` + `/check-in`
    discharge a class-C record by concrete predicate: `AGENT_STALE` launchd
    liveness, or a `soak_check:` data predicate, after the soak-until window.
    (#397)
- **`/triage --feedback-only`.** Walk the decision queue without the full
  Backlog sweep; emits its own telemetry and closes its own review findings.
  (#371)

### Changed

- **Funnel board probes derive from `board_registered_boards`.** `/build` Step 0
  and the funnel-tick board reverse-lookup now iterate the adapter's own
  registered-board set instead of a hardcoded `3 4 5 6` literal, so the
  temperloop kernel tracker (board 7, issues-only) is no longer silently
  dropped — the drift that left `/build` board-OFF on the kernel's own tracker.
  (#381)
- **`env-reconcile` registers the temperloop operator checkout** in its
  default operator-checkout set, so kernel-repo drift is classified against the
  right baseline. (#374)

### Fixed

- **`/build` no longer requires `project` gh-scope for an issues-only board.**
  Step 0's board-integration probe gated the whole run on the `project` scope
  and stopped if missing — but an issues-only board (board 7) drives Status /
  claim / Done / mirror entirely through plain-REST label writes, issue-close,
  and the sub-issues API, none of which need it. The check is now
  backend-conditional on `board_backend`, so a board-7 run whose token carries
  only `repo` is no longer wrongly halted. (#398, closes #391)
- **`plan.sh` writeback resolves its REST config from the knowledge-store
  root** and fails soft when absent, and a personal-vault path literal was
  scrubbed from a `plan.sh` comment (stranger-test cleanliness). (#342)
- **`plan.sh` `_files_touch_shipped` is bash-3.2-safe** — an empty `files:`
  value no longer expands an empty array under `set -u` (which aborts on macOS
  system bash), the guard rule 14's product-source predicate needs. (#393)
- **`/tidy` Step 5 deletes per stub, not per batch — `Sessions/_inbox` can
  actually drain.** The archiver folds a whole run into one commit/PR and
  reports one durability verdict for the batch; Step 5 deleted stubs only on
  `archive-committed`, so any batch holding a genuinely-new stub retained
  **every** stub in it (109 of 123 stranded over 11 days behind two
  already-merged archive PRs). Step 5 now consumes the archiver's per-stub
  `archive-stub-durable:` / `archive-stub-pending:` lines and deletes the durable
  ones whatever the batch verdict says — falling back to the batch line for an
  older archiver, so no migration. (#372; the archiver half lives in the
  foundation overlay's #1161.)
- **`pr-enqueue` confirms the queued state via `autoMergeRequest`**, not the
  gh-rejected `isInMergeQueue` field. (#357)
- **`gate.sh` drops `--delete-branch` from both merge-queue paths** — the queue
  rejects the flag; head branches auto-delete via the repo setting. (#353)
- **`drain` normalizes naive-timezone timestamps** in `tally_recent_findings`
  so the recurring-issue tally doesn't skew on a naive-tz row. (#341)
- **Sandbox test suites prune the live basic-memory store** from their
  no-residue snapshots, so a populated local store no longer fails
  `test_sandbox.sh` / `test_sandbox_dry_run_legs.sh`. (#377, #382)
- **Test runners surface failed-test output; `test_eject.sh` is
  config-hermetic with git auto-maintenance off.** The 7 `test-*` Makefile
  runner loops ran each script with `>/dev/null 2>&1`, so a CI failure named
  only the script, never the assertion — which is why a `test_eject.sh` flake
  on the macos-latest runner couldn't be root-caused. The loops now dump the
  captured output (indented) on `[FAIL]`, pass path unchanged. `test_eject.sh`
  is additionally pinned to an isolated global / empty system git config with
  `gc` and `maintenance` auto **off** (the suspected flake: git's background
  maintenance racing fixture index/ref locks under macOS-runner I/O
  contention). (#401, closes #400)

## [0.12.1] - 2026-07-15

### Fixed

- **The composed gate set is now overlay-safe.** Vendoring v0.12.0 into a
  downstream overlay failed **6 of 74** gates, none of which this repo's own CI
  could see: every one assumed a **kernel-only layout** and broke on a composed
  tree. Not a contract change — an overlay pulling this needs no migration, it
  just stops being wrong. (foundation#1169 found all three.)
  - `validate-design-brief.sh` reported *resolved* citations as
    `DANGLING-CITATION`. `resolve_citation` piped `git ls-files` into
    `grep -q`; grep exits on first match, the producer takes SIGPIPE (141), and
    `set -o pipefail` promotes that 141 to the pipeline's status. It needs both
    a listing over the pipe buffer (~64KiB) **and** an early match — this repo's
    tree is ~15KiB, so it cannot reproduce here at all, while foundation's
    composed tree is ~74KiB. Now captured and matched with a here-string; the
    regression test builds an ~87KiB synthetic tree with a first-sorting
    sentinel, and asserts both conditions so it can't silently go vacuous. (#358)
  - Three suites calling `sandbox_bootstrap_checkout` (`test_install_cli.sh`,
    `test_sandbox_dry_run_legs.sh`, `lib/tests/test_sandbox.sh`) bootstrap this
    repo from `bin/bootstrap.sh` — a path that exists only when the repo root IS
    the kernel. `test_install_lifecycle.sh` already skipped for this reason
    (#267); its siblings never inherited the guard. The detection is now
    `sandbox_skip_if_composed_tree()` in `sandbox.sh`, shared by all four rather
    than pasted into three more files. (#363)
  - `test_install_project_agents.sh` inventoried kernel sources with bare
    `find`, which won't descend a symlink — so an overlay's compat-symlinked
    `claude/agents` counted 0 and failed the suite's first precondition. Four
    sites, now `find -L`; the two subtler ones handed `cmp` a *directory*
    instead of a file. (#364)

## [0.12.0] - 2026-07-14 — BREAKING

### Changed

- **BREAKING — the `/design` command is renamed `/workshop`** (temperloop#354,
  PR #355). The old name collides with Claude Code's builtin `/design` (the
  claude.ai design-system sync consent flow), which answers instead of the
  kernel command on any fresh install — a stranger-test failure. The rename is
  command-name only: `claude/commands/design.md` → `workshop.md`,
  `docs/features/design.md` → `workshop.md` (slug `workshop`), every `/design`
  invocation reference, and the feature/kernel manifests. The artifact
  vocabulary is unchanged — "design brief", `design-schema.md`,
  `design-measurement-proxies.md`, the `design-brief:` epic marker, and
  `validate-design-brief.sh` + fixtures all keep their names. **Migration:**
  rename any overlay/docs references to the `/design` command to `/workshop`,
  and re-run `workflows/scripts/install/project-agents.sh` in each live
  checkout — the deployed `.claude/commands/design.md` symlink dangles after
  the pull and must be removed/replaced by `workshop.md`.
- **BREAKING — funnel governor knob renamed `FUNNEL_WIP_CAP` →
  `FUNNEL_DRIVE_CONCURRENCY`**, and the human WIP-cap-3 standing rule is
  retired from the kernel prose (PR #334). The old rule conflated a
  human/cross-session governance bound with the autonomous funnel's mechanical
  drive-concurrency governor; only the latter was real, and it keeps the same
  default (3). **Migration:** grep your overlay config/env for
  `FUNNEL_WIP_CAP` and rename it, then re-run `make install-claude` — the
  composed `~/.claude/CLAUDE.md` otherwise keeps rendering the retired rule
  from the old placeholder.
- Standing-rule promotions from the drain lexicon (PRs #337–#342): recurring
  pattern/mistake/feedback extractions promoted into kernel standing rules
  (merge-autonomy & consent, cost-tier routing, guard rules) plus two new
  error signatures. Claim-until-Done blessed; the required release-at-park of
  a non-latest claim is dropped (temperloop#275, PR #333). The design-schema
  disposition grammar block is now prefixed `disposition:` (PR #350), and the
  provenance-net Contract-shaped scope is ratified as an accepted-gap decision
  (temperloop#349, PR #351).

### Added

- Funnel rung-5c gains a `_reclaim_abandoned` backstop (foundation#1157): when a
  one-shot `/funnel-drive-merge` session disobeys the synchronous-block guardrail —
  backgrounds a wait and dies before opening a PR — it leaves its board item
  stranded In Progress with no PR, and enough of those exceed the WIP cap and jam
  the funnel. The driver now releases such a claim back to Ready (driven this tick,
  no open PR, issue still open, no terminal status reported), so it re-enters the
  drive pool next tick. Adds `board/unclaim.sh` — the board-status half of undoing
  `claim.sh` (In Progress → Ready), the autonomous release-to-Ready primitive
  `release.sh` deliberately is not (release.sh clears only the local claim marker).
  The reclaim shells out to that CLI (new `FUNNEL_UNCLAIM_BIN` test-double seam),
  keeping `funnel-drive.sh` adapter-free. New wake-record fields `reclaimed` /
  `reclaimed_issues`. Additive — the synchronous-block guardrail stays the primary
  fix; this only makes its failure self-healing instead of a jam.
- `docs-reviewer` advisory agent (`claude/agents/docs-reviewer.md`) and its
  `/build` Step 3e wiring (temperloop#282, PR 261c22f): a read-only,
  `sonnet`-tier documentation reviewer — the fourth member of the advisory
  review family alongside `architecture-reviewer`, `requirements-auditor`, and
  `workflow-reviewer`. It scores stranger-facing prose (`docs/**`, READMEs,
  and other `*.md`) against named rules in `claude/message-schema.md`,
  `claude/measurement-proxies.md`, and the `docs/who-its-for.md` reader
  persona — never taste. `/build` 3e routes a PR touching `docs/**` or a prose
  `*.md` (except a `claude/commands/*.md` workflow spec, which routes to
  `workflow-reviewer`) to it. Advisory only — never a `checks` gate entry.
  Landed on `main` after the v0.11.0 tag, so this entry is the release-surface
  record that lets the next kernel tag ship it and `update-kernel` / a stranger
  grepping the CHANGELOG see it. Not `BREAKING` — the agent is additive and the
  3e routing degrades legibly (`skipped — docs-reviewer unavailable`) where the
  capability probe resolves false. Per-consumer activation (vendor the tag, then
  `make install`) is tracked as class-B propagation work under temperloop#318.
- The funnel tick's Phase-0 intake pre-gate warns once (instead of silently
  no-opping, observed ~19h unnoticed) when the signal-intake backend script is
  missing or present-but-unconfigured (temperloop#330, PR #345); the two knob
  seams the WARN added are registered/exempted in the knob registry.
- Collision-free parallel-append registries and check slots (temperloop#321,
  PR #346): append-only, order-independent registries (feature-manifest,
  kernel-manifest, the exempt-file lists) get a `merge=union` `.gitattributes`
  driver so two same-level sibling PRs appending at one insertion point
  auto-merge instead of textually colliding and costing a rebase-respawn.

### Fixed

- `/build`'s CI-retry push is a plain fast-forward instead of an unconditional
  `--force` (temperloop#335, PR #343): the retry commit is a fast-forward
  descendant by construction, and the needless force-push non-deterministically
  tripped the git-destructive safety classifier in auto mode, silently parking
  autonomous `/sweep` / `/build --unattended` / funnel-drive-merge runs.

## [0.11.0] - 2026-07-10

Minor — the registry-driven config lints land as quality gates, the ~10
remaining prose-only tunables migrate onto env seams + registry rows, and the
personal-token denylist's vault-path burn-down baseline (`\bdev/mind\b`,
temperloop#164/#169) is now empty: every pre-existing hit was routed through
the `knowledge_store` seam or genericized in prose (kernel-literal-scrub,
temperloop#189). Completes the D1–D5 config-architecture epic (temperloop#169)
kernel-side. Not tagged `BREAKING` — new gates are additive, new knobs default
to their prior prose values, and the one default-value change already had a
documented override path (machine conf / `build.config.local.sh` / a
downstream repo's own tracked-repo copy); only the *default value* moved.

### Added

- Registry-driven config lints (temperloop#186, ADR D2/D3), wired into
  `scripts/quality-gates.sh` (38 → 42 gates):
  `workflows/scripts/config/check-knob-registry.sh` — layer-aware
  registry↔shell equality + unregistered-knob sweep, strictly green with no
  baseline — and `workflows/scripts/config/check-knob-prose.sh` — fails a NEW
  literal restatement adjacent to a registered knob name in
  `claude/commands/*.md` / `claude/CLAUDE.kernel.md`, honors a
  `<!-- knob-prose:allow -->` marker — plus fixture test suites for both.
- The ~10 prose-only Bucket A tunables migrated onto env seams + registry rows
  at unchanged defaults (temperloop#187): assess/next/tidy/check-in cadences,
  inbox alarms, and `CLAUDE.kernel.md`'s epic-decomposition threshold via a
  new `{{EPIC_MIN_SUBUNITS}}` compose-time render token. The
  `knob-prose-baseline.tsv` burn-down baseline is now empty; the prose lint is
  strictly enforcing.
- Pre-claimed kernel-manifest globs for the docs-site epic's paths
  (`docs/adr/*`, `docs/architecture.md`, …) so the parallel doc items never
  collide editing the manifest (PR #204); inert until those files land.

### Changed

- `build.config.sh` no longer re-seeds `KNOWLEDGE_STORE_ROOT` to a personal
  vault path — the kernel's own tracked default now defers entirely to
  `knowledge_store.sh`'s generic `${XDG_DATA_HOME:-$HOME/.local/share}/foundation/knowledge`
  default. **A default-value change on an existing knob-registry row is
  `minor` per `VERSIONING.md`.** An operator who relied on the old bare
  default (no machine conf / `build.config.local.sh` / downstream tracked-repo
  override already set) must now set `KNOWLEDGE_STORE_ROOT` explicitly at one
  of those rungs to keep pointing at a real vault. The
  `workflows/scripts/config/knob-registry.tsv` row for this default was
  removed accordingly (the knob's remaining registry row is the kernel-layer
  one owned by `knowledge_store.sh`).
- `knowledge_store_obsidian.sh`'s `KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE`
  default is now *derived* from `ks_root` (`$(ks_root)/.obsidian/plugins/obsidian-local-rest-api/data.json`)
  instead of an independently-hardcoded vault-path literal — so it can never
  silently drift from `KNOWLEDGE_STORE_ROOT`. `doctor.sh`'s knowledge-root
  split-brain check was updated to resolve its "expected" side the same way.
- `vault_hygiene_report.sh`'s `--root` default now resolves via the
  `knowledge_store` seam's `ks_root` instead of a duplicated
  `${KNOWLEDGE_STORE_ROOT:-<personal path>}` fallback.
- Command-spec prose (`claude/commands/*.md`), the `workflow-reviewer` agent
  spec, three hook header comments, and `claude/measurement-proxies.md` no
  longer name the operator's personal vault path as a literal — they refer
  to "the knowledge store root" (`workflows/scripts/lib/knowledge_store.contract.md`)
  or a store-relative doc-id instead. No behavior change (prose only).

## [0.10.0] - 2026-07-10

Additive — a config-precedence ladder, env/prose-knob seams, an env-hygiene
probe, and the overlay integration for the public-repo leak guard. **Contract
surface grows; nothing existing changes shape — safe pull, no overlay action.**
Deliberately **not** tagged `BREAKING`.

### Added

- A new **machine conf** rung in `build.config.sh`'s config precedence
  ladder: an optional `$XDG_CONFIG_HOME/temperloop/build.config.sh`, sourced
  before any checkout-local override, for a host-wide knob override that
  applies across every checkout on that host. Template:
  `workflows/scripts/build/build.config.machine.sh.example`. The full
  six-rung ladder (CLI flag > env var > machine conf > untracked repo-local
  conf > tracked repo conf > kernel built-in default) is documented in the
  new [`docs/config-precedence.md`](docs/config-precedence.md). (#192)
- An **env-hygiene-report** probe that emits a vault drift-entry. (#196)
- Runtime + compose-time **seams for prose-resident knobs**. (#193)

### Changed

- Generalized the stranger-cleanliness denylist and retired the `CANONICAL_USER`
  seam. (#195)

- The **kernel knob registry** (temperloop#164/#169, design decision D2): a
  new grep/cut-parseable `workflows/scripts/config/knob-registry.tsv`
  cataloging every existing tunable knob (162 rows) with its current shell
  default, plus `workflows/scripts/config/knob-registry-lib.sh`, a
  union-aware parse helper that reads the kernel table and unions an
  optional overlay extension TSV when present (mirroring
  `validate-live-drain.sh`'s kernel-table + overlay-extension pattern). A
  reserved `TEMPERLOOP_PROFILE` row (not yet read anywhere) holds the name
  for a later profile mechanism. This is populate-only: no caller routes
  through the registry yet, and no equality lint exists yet (a later item,
  registry-config-lints).

### Fixed

- `build.config.local.sh` (and its `.example` template) now use the `:=`
  set-only-if-unset idiom instead of plain assignments. Previously, because
  `build.config.sh` sourced it LAST with plain assignments, a value set in
  `build.config.local.sh` could silently beat an exported environment
  variable — inverting the intended precedence. Fixed together with
  reordering `build.config.sh` to source its conf-file rungs before applying
  its own built-in defaults, so source order now matches precedence order
  end to end. (#192)
- `check-pr-leak-guard.sh` gains a `--relative` / `LEAK_GUARD_RELATIVE` mode: a
  private overlay vendoring the guard scans only its `kernel/` subtree **and**
  emits kernel-root-relative paths, so the shared exempt list matches and the
  guard no longer false-positives on the kernel's own denylist tsv / test
  fixtures (which legitimately carry the token literals). Whole-tree behavior at
  the kernel repo root is unchanged (`--relative` is a no-op there). Completes
  the overlay integration begun with the `--path` scope in 0.9.2. (#74)
- Sweep merged/orphaned worktrees at session start. (#197)

