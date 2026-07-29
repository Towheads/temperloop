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

### Added

- **Per-contributor session-start surface measurement (temperloop#827, epic
  #810's sub-item "P1" — epic #810's OWN Produces-list numbering, a
  different axis from ADR 0018's Phase A/Phase B split of the same epic;
  P1 is Phase A work. Additive.).** `count-prose.sh` gains a third report
  section, "SESSION-START CONTRIBUTORS", driven entirely by a new tracked
  manifest, `workflows/scripts/config/contributor-manifest.tsv` (in the
  established registry mold: `setting-registry.tsv`, `reviewer-routing.tsv`,
  `citation-registry.tsv`) — every file (or file's YAML frontmatter
  `description:` field) Claude Code auto-loads into a fresh session before
  the agent reads anything, for a bare kernel-only checkout. Adding a
  contributor is a manifest row, never a script change. Reports each
  contributor in BYTES (not lines — the unit temperloop#719/#722 showed can
  move zero lines on a multi-kilobyte commit) plus a byte->token proxy ratio
  re-derived at runtime from a live byte count and a live word count (no
  tokenizer, no network — Phase A of epic #810 per its design brief). A new
  `check-contributor-manifest.sh` lint (wired into `scripts/quality-gates.sh`)
  reconciles the manifest against the tree: no duplicate/untracked/malformed
  row, every `frontmatter:description` row's field actually present and a
  single-line unquoted scalar (a YAML block/folded `|`/`>` indicator is
  rejected, not silently truncated), and every tracked
  `claude/commands/*.md` + `claude/agents/**/*.md` file (plus the root
  `CLAUDE.md` pointer) claimed by a row — this is a structural lint only,
  never a byte budget: **Phase A ships no cap, no target, and no gate that
  can fail a PR merely for growing the surface.** The manifest's `load`
  column (`harness-auto` | `pointer-turn1` | `none` | `n/a`) distinguishes
  the unconditional session-start-prefix cost from a conditional turn-1 read
  (e.g. `AGENTS.md`, out of scope here per epic #810's own "P7" sub-item,
  the AGENTS.md coverage decision) so the two are never silently summed
  together (temperloop#826). Additive: no existing row, column, gate name,
  or script behavior changes: a downstream consumer that has not yet pulled
  this kernel version has nothing that could fail the new lint.

  **Coverage caveat, stated in checkable terms (temperloop#826):** this
  manifest, together with TIER-1, covers 100% of a KERNEL-ONLY checkout's
  always-loaded surface and 0% of a CONSUMER checkout's (a downstream repo
  with an installed overlay + its own project `CLAUDE.md` — e.g.
  foundation). Do not read the "SESSION-START CONTRIBUTOR TOTAL" this
  section prints as a consumer checkout's session cost — it is off by
  roughly an order of magnitude for that case. A consumer-side measurement
  is future work, not yet built.

  **Known, disclosed contradiction with ADR 0007 (not a bug):** the manifest
  deliberately includes all seven `claude/agents/reviewers/*` inert-catalog
  files, because temperloop#825's still-open discovery-leak bug means they
  ARE, today, recursively discovered into every session's agent listing
  despite ADR 0007 specifying them as "not deployed until opted in" — this
  item measures the surface as it actually behaves, leak included; #825
  removes these rows once the leak itself is fixed, not this item.

- **Semantic-redundancy chunker + labelled fixture corpus (temperloop#854,
  half (a) of the P9 semantic-redundancy probe split from #830; epic #810
  contract amendment P9. Additive.).** A new `chunk-redundancy-surface.sh`
  splits the SAME manifest-driven always-loaded surface
  `count-prose.sh`'s SESSION-START CONTRIBUTORS section already reads
  (`workflows/scripts/config/contributor-manifest.tsv`) into rule-sized
  chunks and prints them as a JSON-Lines stream on stdout — one paragraph,
  one top-level list item (indented sub-content swept in as a continuation
  of its own item), or one opaque fenced code block per chunk; a markdown
  heading is never itself a chunk, it only updates the `section`
  breadcrumb every following chunk carries. The surface stays data, not
  code: a new manifest row needs no chunker change. This half deliberately
  does NOT score redundancy, compute similarity, or call an embedding/
  LLM-judge — that is #855's job; this script's only output is the
  segmentation itself, documented field-by-field in the companion
  `chunk-redundancy-surface.md` (the seam #855 consumes), so the scoring
  approach can change with zero changes to the chunker or its stream
  shape. Deterministic (byte-identical on macOS and Linux CI), following
  `count-prose.sh`'s own host-determinism technique (`LC_ALL=C`, tracked
  manifest order rather than a filesystem glob, BSD/GNU `wc` padding
  trimmed) — JSON construction itself goes through `jq -S -c` rather than
  a hand-rolled escaper, so backslash/quote/embedded-newline/non-ASCII
  prose bytes are never at risk of a bespoke-encoder bug.

  Ships alongside a labelled fixture corpus,
  `workflows/scripts/config/redundancy-fixtures.json`: a known-positive
  paraphrase pair (states the same rule in fully reworded language, sharing
  no 10-consecutive-word run — the exact case a verbatim-only detector
  would miss) and a known-negative deliberate-pointer pair modelled on the
  project `CLAUDE.md`'s own `## CI & branch policy` shape (names the
  canonical rule, then states only what is repo-specific), plus a second
  positive and a hard-topical-near-miss negative for a slightly richer
  seed corpus. Every entry carries a one-line rationale. A new
  `check-redundancy-fixtures.sh` lint (wired into `scripts/quality-gates.sh`)
  mechanically enforces the corpus's own acceptance property — every
  `positive`-labelled pair shares zero 10-word shingles — rather than
  leaving it a comment-only claim, plus the usual structural checks
  (required fields, closed label set, unique ids).

  **Phase A scope discipline holds throughout: no cap, no threshold, no
  redundancy verdict, nothing that can fail a contributor's build** — the
  two new gates only prove the chunker and the fixture lint themselves run
  correctly, never a judgment about any file's prose.

- **Realized-session-context probe (temperloop#828, epic #810).** A new
  opt-in (default OFF) `session-context` raw-lake stream, emitted by
  `workflows/scripts/emit-session-context.sh` from the SessionEnd hook seam
  (`claude/hooks/session-end-log.sh`), records the WHOLE session's realized
  token usage — not only the session-start prefix a prior scope measured —
  so a prose relocation's real value becomes measurable rather than
  assumed. The token-sum expression `claude/status-line.sh`'s "Tokens: NNk"
  display already computed is lifted verbatim into a new shared helper,
  `workflows/scripts/lib/token_sum.sh`, so the displayed and recorded
  figures cannot drift apart; its only jq selector is `.message.usage.*`
  (never message content), a structural privacy guarantee proven by a
  synthetic-recognizable-content fixture rather than merely asserted. The
  emit script also supports a one-off `--print-only` reading, independent of
  the passive opt-in gate, for a caller that needs a single on-demand
  measurement. New setting-registry.tsv rows: `SESSION_CONTEXT_RAW_ENABLED`
  (bool, default `0`) and `SESSION_CONTEXT_RAW_DIR` (the stream's sink-dir
  override, following the existing `<STREAM>_RAW_DIR` convention). **Not
  breaking**: the SessionEnd hook's stdin contract and output stub are
  unchanged, `status-line.sh`'s displayed figure is byte-identical to
  before under a normal full-tree sync (same expression, now shared —
  `status-line.sh` degrades to displaying `0` only under a hypothetical
  partial vendoring that ships it without `workflows/scripts/lib/`, which
  the kernel manifest already treats as one unit), and both new settings
  default to off/inert for an adopter who never opts in — Phase A is measurement only,
  with no cap, target, or CI gate on the recorded figure itself.

- **Declared-expiry check (temperloop#831, epic #810's "P10" sub-item, added
  by operator amendment at the epic's `/assess` gate).** A new report-only
  script, `workflows/scripts/declared-expiry-check.sh`, finds standing
  rules whose own stated end condition has already passed. A rule declares
  an expiry in two forms — an absolute date, or a named retirement issue —
  via a new optional `expires:<expiry>` field on its existing citation
  marker (`claude/citation-schema.md` § Declaring an expiry extends the
  marker grammar `validate-prose-budget.sh` already enforces; the field is
  additive and fully optional, never a second `class:ref` pair). The date
  form resolves with a plain lexical `YYYY-MM-DD` string comparison — 100%
  offline, no `date` arithmetic at all; the issue form resolves via `gh
  issue view` and degrades LEGIBLY when offline (an explicit UNRESOLVED
  bucket, never a silent drop or a hard failure). The check's surface is
  the intersection of `citation-registry.tsv` (the mechanical "standing
  rule" definition) and `contributor-manifest.tsv` (temperloop#827's
  always-loaded-file registry) — `claude/CLAUDE.kernel.md`'s own K.* rules
  are explicitly out of scope for this reason, and every run's report names
  the excluded file set rather than silently under-covering. **Reports
  coverage, not precision**: a date/issue either has passed or it has not,
  so resolution is exact within what the check can see, but its value is
  bounded entirely by adoption — the report gives both how many in-scope
  rules declare an expiry and how many read as temporary in prose (a
  small, fixed keyword heuristic) yet declare nothing, then compares
  measured adoption against a **pre-registered** threshold
  (`DECLARED_EXPIRY_ADOPTION_THRESHOLD_PCT`, new setting-registry.tsv row,
  default 50%, fixed before this item's own first real-tree measurement
  ran) and prints a GO/NO-GO verdict on whether a future Phase-B gate is
  warranted. States its own limit explicitly: an undeclared temporary rule
  with no recognizable temporal language is invisible to this check by
  construction. **Phase A ships no cap, no target, and no CI gate** — the
  script always exits 0 on its own findings; it fails only if its own
  required registry/manifest inputs are entirely absent, which never
  happens on a normal checkout.

### Changed

- **The close→Done cascade is stated per backend; on issues-only the adapter's
  Done write is the PRIMARY mechanism, not a backstop (temperloop#902).** The
  cascade (GH #340) is a GitHub **Projects-v2 built-in** — it has no
  implementation in this repo, and on the issues-only backend (the default,
  ADR 0004) there is no such automation and nowhere to hook one: no project
  item for an automation to move, and no native GitHub "on issue close, strip
  a label" rule for a plain Issues repo. A close therefore makes the item
  *read* Done (the reshape's closed-state precedence) while leaving the
  residual `fnd:status:*` label — and the `fnd:host/session:*` claim stamp —
  standing, which is what left 9 of 9 board-7 closures across two runs still
  labelled `fnd:status:backlog`. Rather than wire a cascade with no hook
  point, the contract is corrected where it was inverted:
  `claude/CLAUDE.kernel.md` § Board hygiene is part of the gate,
  `workflows/scripts/board/ISSUES-ONLY-BACKEND.md` § Close→Done cascade,
  `docs/principles.md` § 8, and `docs/architecture.md` now state the split
  explicitly, and `/build` 4d + `/fix` Step 6 item 3 make the
  `board_set_status … Done` write **backend-conditional** (`board_backend`):
  omitted on Projects-v2 exactly as before, issued on issues-only after a
  **confirmed `MERGED`** (REST, no GraphQL budget, warn-and-continue on a
  non-zero return, and still gated on confirmed-merged so the #130
  premature-Done surface stays closed). Detection is unchanged and already
  shipped — `reconcile.sh --status` classes (k)/(l) and `--labels` classes
  (h)/(j) — and now carries a regression case for the exact reported shape: a
  closed issue wearing ONLY `fnd:status:backlog` and no claim stamp, flagged
  by both lenses.
- **`temperloop init` is scoped down to bootstrap → offer the first epic →
  hand off (temperloop#796).** `init` no longer applies any API state of its
  own. It bootstraps `.temperloop/config` (and its reviewable proposal PR),
  offers the kernel-shipped first epic, prints a `next step:` handoff line,
  and stops. Branch protection, head-branch auto-delete, the merge-queue
  disposition, the required `checks` status context, CI, and the adopter's
  review principles are all the first epic's work, applied later with
  per-write consent via `/assess --epic N` → `/build` (ADR 0010, amended in
  this release). Two of the retired applies were actively wrong where they
  stood: `init`'s required-check apply armed a `checks` context with no
  regard for whether a producer would ever post it — the self-brick the
  epic's structural-congruence rule makes unreachable — and its `fnd:` label
  pre-creation duplicated what the issues-only tracker backend already does
  lazily at point of use.
- **Issues-only is now the sole init-time tracker mode (temperloop#793).**
  Board provisioning is dropped from `init`. The retired `projects` arm
  rendered `# board.<N>.project=<FILL IN …>` into `boards.conf` *before* the
  step that learned the project number and never reassigned it, so even a
  fully-consented, successful run shipped a placeholder — and because it was
  a comment, the adapter's `^board\.N\.axis=` lookup missed it and fell
  through to a built-in default rather than failing loudly. The rendered
  entry is now always complete, pinned by a regression test asserting
  `board.<N>.backend=issues` present and `FILL IN` absent from both
  `.temperloop/config`'s `tracker.boards_conf_entry` and the proposed
  `boards.conf`. To run a real Projects-v2 board, create it and hand-write
  its three `boards.conf` axes — see `docs/features/install-cli.md`
  § "Manual Projects-v2 recipe".
- **Declining the first epic files the durable re-offer pointer and nothing
  else.** The inline principles interview `init` used to run on the decline
  path is retired: it was a second copy of an interview the epic already
  owns as its L0 (`record-principles`), asked by a different actor through a
  different write seam. Declining now defers it. The kernel principle set
  still applies at every review call site's point of use with zero
  configuration, so declining costs only the *recorded* choice.
- **`.temperloop/config` stays at schema 1.** A repo initialised before this
  change keeps its recorded `label` / `required_check` / `board` install
  entries: they are carried forward untouched on every re-run and
  `temperloop eject` still reverts them, even though `init` no longer
  creates any.
- **The uninstall map gained a fifth scope, because a four-scope table that
  presents itself as exhaustive now has a gap.** `bin/README.md` § Uninstall
  and `eject.sh`'s on-every-run removal bullet both carry **scope (e), the
  first-epic substrate** — branch protection, head-branch auto-delete, the
  merge-queue disposition, any scaffolded CI workflow, and the recorded
  `§ Principles` disposition. That state is applied by the first epic via
  `/assess` → `/build`, never by `init`, so it is in no manifest and
  `temperloop eject` does **not** revert it — and neither does reverting the
  epic's own PRs, since API state is not a tracked file. Undo is manual, in
  repo Settings; the step-by-step list is in
  `docs/features/engineering-principles.md` § "Uninstall / removal".
  Previously an adopter could eject, read `all N install(s) reverted` against
  a complete-looking table, and walk away with a protected branch and an
  armed merge queue nobody had told them eject would leave behind.
- **The first epic's consent questions now disclose their undo path.** Each
  A2 question and the A3 Actions branch in
  `claude/templates/first-epic-setup.md` carries an explicit **`Undo:`**
  clause naming the repo-settings path and stating that `temperloop eject`
  does not revert it; § Decline floors scopes its "nothing can leave your
  repo worse off" claim to match. ADR 0010's accepted-gap record resolves
  this irreversibility by pointing at consent-time disclosure, so that
  disclosure has to exist in the artifact the adopter actually reads, not
  only in a maintainer-facing ADR.
- **`init`'s handoff names its prerequisite.** `/assess` and `/build` are
  Claude Code slash commands that reach a machine only via `temperloop
  install`, while the `try` → `try --demo` → `init` ladder otherwise needs no
  machine-wide setup — so a stranger could reach the handoff pointing at a
  command they did not have, deferring all of this epic's value to a dead
  pointer. `init` now probes for `~/.claude/commands/assess.md` and prints an
  extra `prerequisite:` line when it is missing; `bin/README.md` and
  `docs/features/install-cli.md` no longer imply step 3 is self-contained.
  The `next step:` line itself is byte-identical either way (pinned by a
  test), since it is the marker the tier-2 workflow greps on a runner that
  has no `~/.claude/`.

### Deprecated

- **`init`'s apply-gating flags are no-ops with named removal windows, not
  removals.** `--yes/--no-required-check`, `--yes/--no-labels`,
  `--yes/--no-board`, `--provision-board`, and `--tracker-mode projects` all
  still parse and still exit 0. Each now prints one line naming where its
  step went **and the release it is removed in**, then is ignored
  (`--tracker-mode projects` additionally coerces to `issues`);
  `--tracker-mode <anything-else>` is still refused with exit 2. **Nothing
  that passes them breaks** — this is deliberately not a breaking change.
  They are retained because of `VERSIONING.md`'s **CLI surface** contract
  row, which covers `bin/subcommands/*`: an *adopter's* own wrapper script,
  Makefile, or CI job may pass any of them, `init.sh` exits 2 on an unknown
  argument, and those callers cannot be enumerated from inside this repo.
  (The in-repo call sites are not the argument — this same change rewrote
  `install-tier2.yml` to stop passing them.) Two windows, because the flags
  do not share one story:
  - `--provision-board` and `--tracker-mode projects` are Projects-v2
    tracker-backend surface, and ride the **ADR-0004 Projects-arm removal
    release**.
  - The three consent pairs `--yes/--no-required-check`, `--yes/--no-labels`
    and `--yes/--no-board` gated a branch-protection PATCH and a label loop
    that existed on the issues-only path too, so ADR-0004's removal would
    never logically cover them — pinning them to it would leave them
    permanent no-ops wearing a deprecation label. They are removed at
    **v0.20.0, the pre-scope-down compat window**, together with `eject.sh`'s
    pre-scope-down `required_check`/`label`/`board` read-compat handlers:
    one window, because both halves serve exactly one cohort — a repo
    adopted before this change, whose config may still record that API state
    and whose wrapper scripts may still pass these flags.

  The affirmative forms (`--yes-*`, which *request* an action that no longer
  happens) warn and continue rather than exiting non-zero — a deliberate,
  reversible call consistent with the script's fail-open posture, revisited
  at the v0.20.0 removal.

### Removed — BREAKING

<!-- The `BREAKING` token appears TWICE for this release on purpose — on the
     `## [Unreleased]` heading above AND on this `### Removed` sub-heading.
     `changelog_breaking_sections()` (workflows/scripts/lib/changelog.sh) sets
     its `brk` flag ONLY from a heading line: `$0 ~ /BREAKING/` on the
     `## [x.y.z]` line, or `/^#+ .*BREAKING/` on a sub-heading. BODY TEXT
     NEVER SETS IT. So the sub-heading marker is the belt-and-suspenders half:
     it survives a release cut that rewrites `## [Unreleased]` into
     `## [0.19.0] - <date>` without carrying the ` — BREAKING` suffix across.
     Without at least one of these, `scripts/update-kernel.sh`'s acknowledgment
     gate (its `migration=` computation) and `bin/subcommands/update.sh`'s
     BREAKING warning both silently no-op, and a downstream overlay
     subtree-updates straight through this break with no acknowledgment.
     Keep BOTH markers when cutting v0.19.0. -->

- **BREAKING — the `foundation` → `temperloop` rename compatibility window is
  CLOSED (temperloop#165, temperloop#764).** The read-old-write-new window
  opened in
  v0.15.0 with a stated v0.19.0 removal; this is that removal. Every legacy
  read is gone. **Nothing degrades silently** — each removed read was replaced
  by the legible refusal or diagnostic its window arm had already been
  simulating, so a caller still on a legacy name is *told*, by name, what to
  change:

  - **Legacy `FOUNDATION_*` env vars are no longer read.**
    `FOUNDATION_HOME`, `FOUNDATION_BIN_DIR`, `FOUNDATION_KERNEL_REPO`, and
    `FOUNDATION_VERSION` no longer act as fallbacks for their `TEMPERLOOP_*`
    twins in `bin/bootstrap.sh`, `bin/lib/common.sh`
    (`temperloop_env_compat`, `temperloop_resolve_version`),
    `bin/subcommands/feedback.sh`, or `claude/workflows/build-level.mjs`.
    Setting one *without* its `TEMPERLOOP_*` twin now **exits non-zero**
    naming the replacement — never a silent install at a path you did not ask
    for. Precedence is otherwise unchanged: a set `TEMPERLOOP_*` primary
    still wins **silently**, so a caller who has migrated but still carries a
    stale legacy export is unaffected.
    *Migration:* rename the variable (`FOUNDATION_HOME` → `TEMPERLOOP_HOME`,
    and so on).
  - **The `foundation` CLI shim no longer dispatches.** `bin/foundation`
    stops forwarding to `temperloop` and now refuses on every invocation,
    naming the replacement binary. The file itself is **deliberately kept**
    as a tombstone: a pre-v0.19.0 install left a `~/.local/bin/foundation`
    symlink pointing at it, and deleting the file would turn that symlink into
    a dangling "no such file or directory" instead of a message. A fresh
    `bootstrap.sh` install no longer creates the symlink at all. Disposing of
    an existing stale one is **manual**: `temperloop uninstall` does *not*
    remove it — it **prints the `rm -f` to run**, because the symlink is part
    of the bootstrap footprint (scope (a) of `bin/README.md` § Uninstall),
    written before any manifest existed, so uninstall has no record of it and
    deliberately will not infer one.
    *Migration:* invoke `temperloop <sub>`; to retire the old name on PATH,
    run the `rm -f ~/.local/bin/foundation` that `temperloop uninstall`
    prints.
  - **`init` no longer reads a legacy `.foundation/config`.** It **refuses**
    when one is present and no `.temperloop/config` exists, rather than
    restarting from a fresh install manifest on top of forgotten legacy state.
    *Migration:* `git mv .foundation .temperloop`.
  - **`baseline-snapshot` no longer appends to a legacy
    `.foundation/baseline.jsonl`.** It **refuses** when one exists, rather
    than silently splitting one append-only history across two directories
    (which truncates every later report's "before" anchor).
    *Migration:* `mkdir -p .temperloop && mv .foundation/baseline.jsonl
    .temperloop/`.
  - **The legacy `$XDG_CONFIG_HOME/foundation/boards.conf` machine conf is no
    longer read.** `board.sh` and `make doctor` now **name** a stranded legacy
    file on stderr instead of using it (or instead of silently falling through
    to the built-in maps with no explanation).
    *Migration:* `mkdir -p ~/.config/temperloop && mv
    ~/.config/foundation/boards.conf ~/.config/temperloop/`.
  - **The legacy `$XDG_DATA_HOME/foundation/knowledge` store root is no longer
    resolved.** `knowledge_store.sh` uses the `temperloop/` default and
    **names** a stranded legacy store on stderr — the case that would
    otherwise report "no notes found" against an empty new root while the real
    store sits one directory over.
    *Migration:* move the store, or set `KNOWLEDGE_STORE_ROOT`.

  **Deliberately NOT removed** (migration aids for an existing install, not
  window-scoped compat): `temperloop eject` / `temperloop uninstall` still
  clean a legacy `.foundation/` per-repo dir and a stale `foundation` PATH
  symlink, and the report auto-offer's read-only age probe still reads an
  un-migrated repo's legacy baseline.

  Registry/table follow-through in the same change: the four DEPRECATED
  `FOUNDATION_*` rows in `workflows/scripts/config/setting-registry.tsv` are
  removed and their four `TEMPERLOOP_*` twins' defaults no longer transcribe a
  `${FOUNDATION_*:-…}` fallback; the 8 `windowed` rows in
  `workflows/scripts/kernel/prerename-leak-verdicts.tsv` are removed and that
  verdict is retired in favour of `refusal`, which records the identifiers
  that legitimately survive *inside* the refusals and diagnostics above; and `bin/lib/common.sh`'s two internal
  install-path constants are renamed to `TEMPERLOOP_CLI_HOME_DEFAULT` /
  `TEMPERLOOP_CLI_BIN_DEFAULT`, dropping their pre-rename prefix.

- **BREAKING — the v0.17.0 terminology-consolidation compatibility window is
  CLOSED (epic temperloop#719, temperloop#767).** The read-old-write-new
  window opened in v0.17.0 with a stated v0.19.0 removal; this is that
  removal. The env shim, every forwarding stub at an old script path, the
  source-forwarder, and the legacy registry-filename resolution are deleted.
  Unlike the `foundation` → `temperloop` window above, these arms **fail
  silently by construction** — a stub is invoked by path and an env shim is
  sourced under `[ -f ]` — so there is no refusal to leave behind: a caller
  still on a legacy name now gets "no such file or directory" from its own
  shell, or simply no binding. The v0.17.0 `BREAKING` entry carries the full
  rename map; what is gone as of this release:

  - **Legacy `FUNNEL_*` / `KNOB_*` env vars are no longer read.**
    `workflows/scripts/lib/rename-compat-0170.sh` is deleted, along with
    **both** of its `[ -f ]`-guarded source blocks — the two in
    `workflows/scripts/build/build.config.sh` (including the second,
    post-conf-layer forwarding pass) and the one in
    `workflows/scripts/config/setting-registry-lib.sh`. A pre-rename env name
    now binds nothing and prints nothing, including one set by a layer-3
    machine conf or a layer-4 repo-local conf.
    *Migration:* rename the variable (`FUNNEL_<NAME>` → `PIPELINE_<NAME>`,
    `KNOB_<NAME>` → `SETTING_<NAME>`).
  - **The ten forwarding stubs at the old script paths are deleted.**
    `workflows/scripts/build/funnel-{cron,drive,tick,overlap,schedule-gate}.sh`,
    `workflows/scripts/build/build-config-knobs.sh`,
    `workflows/scripts/config/check-knob-{registry,prose}.sh`,
    `workflows/scripts/config/knob-registry-lib.sh` (the source-forwarder,
    which also re-exposed the `knob_registry_*` function names), and
    `workflows/scripts/validate-live-drain.sh`.
    *Migration:* invoke the renamed sibling (`pipeline-*.sh`,
    `build-config-settings.sh`, `check-setting-*.sh`,
    `setting-registry-lib.sh` + the `setting_registry_*` names, and
    `validate-capture-backstop.sh`).
  - **The legacy registry FILENAME and table spellings are no longer read.**
    `validate-capture-backstop.sh` stops resolving a pre-rename
    `claude/live-drain-registry.overlay.md` when the renamed
    `claude/capture-backstop-registry.overlay.md` is absent, and its table
    parser stops accepting the pre-rename `## Live/Drain pairings` heading and
    `| Live rule` column header. **This is the one arm that can degrade
    quietly:** an overlay checkout still shipping the old filename now reads
    as "no overlay extension present", so its rows are simply not validated.
    *Migration:* rename the file and its table heading/column.

  **Deliberately NOT removed** (not window-scoped compat): the
  `funnel-<YYYY-MM>.jsonl` telemetry read-union in
  `workflows/scripts/telemetry-brief.sh` and `pipeline-cron.sh --backfill`.
  The raw lake is append-only immutable history, so a pre-rename install's
  month-files can never be rewritten under the renamed prefix — that read is
  **permanent** and self-limiting (writers emit only `pipeline-*`), and is now
  documented as such in `meta/data/raw/README.md`. Also unchanged, exactly as
  the v0.17.0 rename promised: the persisted-state literal VALUES —
  the `funnel-merge-pending` / `funnel-escalated` GitHub labels, the
  `<!-- funnel:clarification-drained -->` / `<!-- funnel:decision-applied -->`
  issue markers, the `~/.claude/funnel/*` state paths, and the
  `/tmp/funnel-tick` lock dir.

  Registry follow-through in the same change (the fail-open arms above mean a
  half-removal fails nothing, so every registry that named a deleted path is
  pruned in lockstep): the `window` and `registry` exempt classes are deleted
  from `workflows/scripts/kernel/terminology-leak-exempt-files.txt`, leaving
  `record` + `self` — so `make test-kernel-terminology` now guards the
  surfaces the window used to own; `docs/features/feature-manifest.txt` and
  `workflows/scripts/kernel/kernel-manifest.txt` drop their claims on the
  deleted paths; and `workflows/scripts/tests/test_terminology_rename_compat.sh`
  is inverted from a READ-OLD-WRITE-NEW proof into a window-STAYS-SHUT
  regression test (a pre-rename name must bind nothing and say nothing, and no
  window file may reappear).

## [0.18.0] - 2026-07-26

### Added

- **`reconcile`: `--fix` gains a marker-lens repair (temperloop#748).** The
  marker lens could name a stale local claim marker every run forever without
  ever being able to clear one — `--fix` was `--status`-only. It now also
  applies one narrowly-scoped repair on the default marker lens: it clears
  **this window's** claim marker, via the same `claim_marker_clear` primitive
  `release.sh` uses, and only when that marker is `marker-without-board` drift
  **and** its issue is provably terminal (`CLOSED`/`MERGED` on GitHub). Still
  opt-in — without `--fix` the lens only reports. Deliberately never repaired:
  a marker whose issue is still open, any window other than the caller's own
  (the GH #297 doctrine), and the entire `board-without-marker` class, which
  temperloop#719 showed produces false stranded-claim signals. `--fix` remains
  rejected with `--labels` (that lens applies via `--apply`/`--unattended`).
  K#275 is untouched: `release.sh <n>` still refuses a non-latest claim, now
  pinned by `workflows/scripts/board/tests/test_release.sh`.

### Fixed

- **`ks_root()` resolves the rung-3 machine conf in the bare-env plane
  (temperloop#771, foundation#1328).** The store root resolved *differently*
  depending on whether the caller had sourced `build.config.sh`. A process that
  sources only `knowledge_store.sh` skipped the operator's rung-3 machine conf
  entirely and fell through to the kernel XDG default
  (`~/.local/share/foundation/knowledge`), while one that sourced
  `build.config.sh` resolved the real store — a split-brain that made the same
  helper return two different roots on one host. `ks_root()` now consults
  `KNOWLEDGE_STORE_MACHINE_CONF` (an isolated-subshell read, so the tracked
  `build.config.sh` is never sourced and no ordering is disturbed) between the
  env rung and the kernel default, so both planes agree. **Live impact:** this
  is the gap `session-start-drain.sh` fell into on every interactive session
  start — its vault path derives transitively from `ks_root()` via
  `KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE` — silently failing **218 session
  drains across 16 consecutive days** on the reporting host before it was
  found. The new setting is registered in `setting-registry.tsv`;
  `knowledge_store.sh` test cases 3b–3f pin the rung (env still wins, machine
  conf beats the XDG default, and a missing/malformed/erroring conf falls
  through cleanly), and `test_stranger_config.sh` §§ G/H now pin
  `XDG_CONFIG_HOME` so their sandbox isolation is structural rather than
  accidental.

- **`doctor`'s knowledge-root check can actually see a split (temperloop#774,
  foundation#1332).** The check was degenerate: it compared `ks_root()` against
  a root *derived from* `KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE`, whose own
  default is itself `$(ks_root)/…` — so it compared a value with itself and
  could never fail, including throughout the 16-day outage above. It now
  compares the two resolution planes directly (plane A, via `build.config.sh`,
  vs plane B, bare-env) and reports a genuine divergence. Covered by
  `test_doctor_knowledge_root.sh`; `docs/features/knowledge-store.md`'s
  "Agent-plane vs. script-plane routing" prose is updated to describe the
  plane-A/plane-B comparison instead of the retired key-file derivation.

- **`pipeline-schedule-gate.sh`: an unresolvable store root no longer reads as
  the operator's kill switch (foundation#1329).** Every skip verdict was
  already fail-closed alike, but a resolution bug (a stale/renamed
  `PIPELINE_SCHEDULE_FILE` path — the concrete instance behind this fix,
  temperloop#768) and the operator's deliberate `enabled: no` produced
  `reason` text that was easy to mistake for one another at a glance, so the
  live case went unnoticed: the pipeline was off for the wrong reason and
  nothing in the log said so. The gate's skip messages now carry one of two
  mutually-exclusive tags — `"store root did not resolve / control note
  unreachable"` for a missing/unreadable file or a missing fenced block, vs.
  `"control note present, not a resolution failure"` (with the existing
  `"kill switch"` wording preserved for the explicit `enabled: no` case) — so
  a resolution failure can never be reported as the kill switch, or vice
  versa. Both branches remain fail-closed (exit 1, zero `gh` calls); only the
  `reason` text changed. New gate 11 in `tests/test_pipeline_cron.sh` asserts
  the two reasons are distinct and never cross-tagged.

- **Issues-only backend: reaching Done clears the claim stamp
  (temperloop#744).** A closed issue kept its `fnd:host/session:<host>:<sess8>`
  label, so it read as permanently claimed — `issue-state.sh resolve` returns
  `claimed-elsewhere` off exactly that label, and nothing swept it. Fixed at
  both altitudes. **Root cause:** `_board_issues_set_field`'s Done arm now
  strips every `fnd:host/session:*` label alongside the `fnd:status:*` label
  before closing (a non-Done status write still leaves the stamp alone — a park
  back to Ready may legitimately still hold the claim). **Backstop:** the
  dominant close path is a merged PR's native `Closes #N`, which runs no adapter
  code at all, so `reconcile.sh --labels` gains class **(j)** — a
  `fnd:host/session:*` label on a CLOSED issue, stripped per-issue by `--apply`,
  with the same immediate re-check (an issue reopened in the scan→apply gap is
  never stripped) and idempotence as the other classes. It is not reachable by
  the existing orphaned-label class (g), which deletes a repo label *object*
  only when it is attached to zero OPEN issues: while any open issue still wears
  the stamp, the object is correctly kept and every closed issue wearing it stays
  stranded. Sweep the accumulated backlog with one command —
  `workflows/scripts/board/reconcile.sh --board 7 --labels --apply` (or
  `--labels` alone for the zero-write report).

- **Retargeted the temperloop#165 `.foundation/` rename-window close from
  v0.17.0 to v0.19.0 (temperloop#764).** ~86 markers across the tree stated the
  legacy `foundation`-named reads (the `bin/foundation` shim, `FOUNDATION_*`
  env vars, `.foundation/config`, `.foundation/baseline.jsonl`, the legacy
  machine `boards.conf` path, the legacy `foundation/knowledge` store) were
  "removed in v0.17.0" — but v0.17.0 shipped as the #719 terminology release
  without performing that removal, so every marker was stale. They now name the
  real close version, **v0.19.0**, where #719's own legacy window also closes
  (one adopter migration, not two). temperloop#764 stays **open** to track the
  actual `.foundation/` removal at the v0.19.0 cut — this entry records only the
  marker retarget. No behavior change — the legacy reads still resolve exactly as
  before; only the documented close version moved.

## [0.17.0] - 2026-07-25 — BREAKING

One-shot pre-GA terminology consolidation (temperloop#729, epic #719
(prose-plane subtraction and budget), ADR 0017): one name per concept,
plain words over coinages, applied as a single rename so adopters relearn
once instead of per-release. **An overlay or consuming checkout must
migrate by the map below before pulling** — `update-kernel` requires the
usual breaking ack (`KERNEL_ALLOW_BREAKING=1` or the interactive confirm).
A legacy read window (env vars, old script paths, the old overlay-registry
filename, the old telemetry month-file glob) forwards with deprecation
NOTEs until **v0.19.0**.

### Changed — the full rename map

**Vocabulary (one name per concept, everywhere):**

| Old term | New term |
|---|---|
| funnel (the bug→PR flow; the autonomous driver) | pipeline |
| knob (a tunable config value) | setting |
| `blocking-now` severity | `ask-now` |
| `batch-at-gate` severity | `ask-at-gate` |
| `batch-at-ritual` severity | `ask-at-checkin` |
| ritual | contextual, not 1:1 — check-in where it names the daily `/check-in` review; otherwise routine / review / step / session as the sentence requires |
| build spine (the shared build scripts) | build machinery |
| design spine (docs/cognitive-load.md only) | design backbone |
| precedence rung (config ladder) | precedence layer |
| funnel rung 5a/5b/5c (autonomy ladder) | autonomy level 5a/5b/5c |
| Live/Drain pairing (live half / drain backstop) | Capture/Backstop pairing (capture half / backstop) |
| logical board number | board id |

**Env / setting names (prefix rule — every var, registry-listed or not):**

- `FUNNEL_<NAME>` → `PIPELINE_<NAME>` (44 registry rows, plus e.g.
  `FUNNEL_OPERATOR_ABSENT` → `PIPELINE_OPERATOR_ABSENT`)
- `KNOB_<NAME>` → `SETTING_<NAME>` (the registry/prose-lint seams:
  `KNOB_REGISTRY_*` → `SETTING_REGISTRY_*`, `KNOB_PROSE_*` → `SETTING_PROSE_*`)
- Legacy env reads keep working through v0.19.0 via
  `workflows/scripts/lib/rename-compat-0170.sh` (NEW > OLD > default; one
  NOTE per legacy var used), sourced by `build.config.sh` and
  `setting-registry-lib.sh`.

**Renamed files (forwarding stubs at every old executable/sourceable path
through v0.19.0):**

- `workflows/scripts/build/funnel-cron.sh` → `pipeline-cron.sh`
- `workflows/scripts/build/funnel-drive.sh` → `pipeline-drive.sh`
- `workflows/scripts/build/funnel-tick.sh` → `pipeline-tick.sh`
- `workflows/scripts/build/funnel-overlap.sh` → `pipeline-overlap.sh`
- `workflows/scripts/build/funnel-schedule-gate.sh` → `pipeline-schedule-gate.sh`
- `workflows/scripts/build/funnel-drive.settings.json` → `pipeline-drive.settings.json` (no stub — data)
- `workflows/scripts/build/funnel-drive-merge.settings.json` → `pipeline-drive-merge.settings.json` (no stub — data)
- `workflows/scripts/build/build-config-knobs.sh` → `build-config-settings.sh`
- `workflows/scripts/config/knob-registry.tsv` → `setting-registry.tsv` (no stub — the lib resolves it)
- `workflows/scripts/config/knob-registry-lib.sh` → `setting-registry-lib.sh` (source-forwarder keeps the old path AND the old public `knob_registry_*` function names working)
- `workflows/scripts/config/knob-registry-exempt-files.txt` → `setting-registry-exempt-files.txt`
- `workflows/scripts/config/knob-prose-baseline.tsv` → `setting-prose-baseline.tsv`
- `workflows/scripts/config/check-knob-registry.sh` → `check-setting-registry.sh`
- `workflows/scripts/config/check-knob-prose.sh` → `check-setting-prose.sh`
- `workflows/scripts/validate-live-drain.sh` → `validate-capture-backstop.sh`
- `claude/commands/funnel-drive.md` → `pipeline-drive.md`
- `claude/commands/funnel-drive-merge.md` → `pipeline-drive-merge.md`
- `docs/features/build-spine.md` → `build-machinery.md`
- `docs/features/funnel-driver.md` → `pipeline-driver.md`
- test suites renamed alongside their subjects (`test_funnel_*` →
  `test_pipeline_*`, `test_build_config_knobs.sh` →
  `test_build_config_settings.sh`, `test_knob_registry.sh` →
  `test_setting_registry.sh`, `test_check_knob_*` → `test_check_setting_*`)
- **telemetry stream**: the pipeline tick's raw-lake month-files are now
  written `pipeline-<YYYY-MM>.jsonl` (previously `funnel-<YYYY-MM>.jsonl`).
  Writers emit only the new name; readers (`telemetry-brief.sh`, and
  `pipeline-cron.sh --backfill`) union the legacy `funnel-*.jsonl`
  month-files in read-only, with a one-line NOTE, through v0.19.0 — an
  existing install's accumulated history stays visible. Legacy files are
  never renamed in place.

**Pipeline command contracts:** the slash commands `/funnel-drive` and
`/funnel-drive-merge` are now `/pipeline-drive` and `/pipeline-drive-merge`.

**Message-schema template names: NONE renamed.** All five (`PR-body
skeleton`, `Parking note`, `Digest entry`, `Question block`, `Degradation
notice`) were already plain words — an overlay's named-template overrides
need no change.

**Parsed / structural surfaces:**

- `claude/CLAUDE.kernel.md` § `Prose-resident knob convention` →
  § `Named-setting convention` (every § pointer updated).
- `claude/commands/tidy.md`'s registry table: `## Live/Drain pairings` →
  `## Capture/Backstop pairings`, columns `Live rule | Live location |
  Drain backstop` → `Capture rule | Capture location | Backstop`.
  `validate-capture-backstop.sh` parses **both** spellings through v0.19.0.
- Overlay extension registry file: `claude/live-drain-registry.overlay.md`
  → `claude/capture-backstop-registry.overlay.md` (the validator reads the
  legacy filename with a NOTE when the new one is absent, through v0.19.0).
- `temperloop config list`: TSV column 2 renamed `rung` → `layer` (text
  header `RUNG` → `LAYER`) — aligns the CLI with the registry's own
  `layer` column.
- Annotations: `# knob:exempt` → `# setting:exempt`;
  `<!-- knob-prose:allow -->` → `<!-- setting-prose:allow -->`.
- Make targets: `validate-live-drain` → `validate-capture-backstop`.

### Added

- `make test-kernel-terminology` — leak gate
  (`workflows/scripts/kernel/check-terminology-leak-guard.sh`, in
  `KERNEL_GATES`): pre-rename identifiers cannot silently re-enter a
  stranger surface; only the reviewed exempt set (the compat window's own
  files + records) may carry them.
- `workflows/scripts/tests/test_terminology_rename_compat.sh` — the legacy
  window's behavior contract (6 hermetic cases), in `KERNEL_GATES`.

### Deliberately NOT renamed (migration note)

- **Persisted external state keeps its pre-rename values** (the temperloop#165
  `.foundation/` precedent — renaming them would orphan live state): the
  `funnel-merge-pending` / `funnel-escalated` GitHub labels, the
  `<!-- funnel:clarification-drained -->` / `<!-- funnel:decision-applied -->`
  issue markers, `~/.claude/funnel/*` state paths, and the
  `/tmp/funnel-tick` lock dir. Setting *names* renamed; *values* stable.
- `workflows/scripts/drain/` and the `session-start-drain.sh` hook —
  "drain a queue" is literal English there, and hook names are a contract
  surface with no confusion evidence.
- `claim`/`release`, `worktree`, `merge queue`, `sweep`, `gate` — already
  plain or industry-standard.
- Historical records (this CHANGELOG's earlier sections, `docs/adr/`,
  archived plans, knowledge-store notes) keep old terms — they are
  records, not live contracts.

## [0.16.0] - 2026-07-25

Non-breaking minor bump: several additive capabilities across the pipeline
commands, the board adapter, the report, and the plan schema, plus a batch of
fixes. **No contract surface is removed** — the temperloop#165 rename's legacy
reads remain through their v0.17.0 window, so no overlay must change to pull
this tag.

### Added

- **`report`: directional dollar framing from a user-supplied pricing table
  (temperloop#882).** The report can translate token/latency deltas into a
  directional `$` figure when the operator supplies a pricing table — opt-in,
  no pricing assumed by default.
- **`plan`: a `cost:` block flags expensive work (temperloop#1059).** A plan
  item may carry a `cost:` block so `/build` can surface and gate expensive
  work before it runs; the pre-check reads it at the level merge gate.
- **`build`: combined-tree pre-check at the level merge gate (F#865).** Before
  a level's merge set is approved, a combined-tree pre-check runs across the
  set; its opt-out knob is named symbolically and registered in
  `knob-registry.tsv`.
- **`build`: push-notify the operator on every `blocking-now` halt
  (temperloop#695).** Every modal halt now emits an operator push notification
  so an unattended run's blocking gate is not silent.
- **`capture`: `--title` accepted as an alias for the positional title
  (temperloop#1227).** `capture.sh` now takes `--title <t>` in addition to the
  positional form, removing a recurring invocation footgun.
- **`board`: `board_blocked_by_add` / `board_blocked_by_remove` writers
  complete the adapter contract.** The native `blocked_by` dependency edge is
  now writable through the adapter, not just readable.
- **`assess`: require an owned host-config/secret seam when acceptance names a
  credential (temperloop#716).** A plan item whose acceptance references a
  credential must declare an owned host-config/secret seam.
- **`demo`: de-personalize the seed-demo-repo default target
  (temperloop#871).** The demo seeder no longer defaults to a personal target.

### Changed

- **`ks_search`: register the basic-memory project lazily, not per query
  (temperloop#996).** Project registration moved out of the per-query hot path.
- **`deploy-mini`: route §3 conf discovery through `board.sh`'s resolver
  (temperloop#616).** Conf discovery reuses the adapter resolver instead of a
  bespoke path.
- **`kernel`: retire `seed-kernel-repo.sh` and trim `kernel-repo-layout.md`
  (temperloop#681).** Removes a superseded seeding script (not a contract
  surface — no adopter couples to it).
- Documentation: authored `tracker.contract.md` (the tracker-adapter interface
  contract, temperloop#891); ADR renumbering + premise-gate/principles-charter
  ADRs; `/workshop` persist-then-ask ordering contract and reviewer-finding
  folds; a kernel rule to disconfirm a root-cause diagnosis before
  institutionalizing it (temperloop#1090).

### Fixed

- **`build`: embed the FOREGROUND-ONLY gate contract in the worker prompt
  (temperloop#712).** `/build` workers backgrounded `quality-gates.sh` and
  ended their turn awaiting a Monitor notification a subagent never receives,
  returning no verdict. `build-level.mjs`'s generated `workerPrompt()` now
  embeds the FOREGROUND-ONLY contract (prevention, both the main and spike
  prompts) and the one null-verdict re-spawn appends `FOREGROUND_CURE` so the
  retry differs from the first attempt (cure); `build.md` §3c/§3d kept in
  lockstep.
- **`drain`: damp the lexicon on spec-authoring sessions (temperloop#1137).**
- **`hooks`: make the MCP preflight `/search/smart` probe body-aware
  (temperloop#1224 Part 1).**
- **`kernel`: resolve symlinks before kernel/overlay classification
  (temperloop#1050).**
- **`degradation`: bounded remedy pointer on the live Mode-2 agent-gate skip
  line.**
- **`plan-schema`: spec-prose model-stamping carve-out (temperloop#672).**

## [0.15.1] - 2026-07-23

### Fixed

- **`quality-gates.sh`: kernel self-distribution tests are now CLASS-gated on a
  vendoring-consumer signal (temperloop#691).** v0.15.0 guarded
  `test_update_subcommand` / `test_update_kernel` surface-conditionally so a
  bespoke-subtree vendoring consumer skips them, but left `test_rename_compat`,
  `test_bootstrap_tag_pinning`, and `test_version_embedding` **unconditional** —
  they require the `bin/bootstrap.sh` + repo-root `VERSION` surface a vendoring
  consumer does not carry, so no surface choice let such a consumer's
  `make quality-gates` go green (surfacing `bin/` to satisfy them also flips on
  `test_update_subcommand`, whose managed-clone CLI cannot traverse a composed
  tree's symlinked kernel dirs via `git show <ref>:<path>`). All four
  self-distribution / self-update tests are now gated as a CLASS on one signal —
  a repo-root `.kernel-pin` marks a vendoring consumer (the kernel's own
  checkout has none), so the kernel runs all four and every consumer skips all
  four legibly. Categorical by design: a future self-distribution test joins the
  list and is excluded from consumers with no per-test guard drift. **No
  behavior change in the kernel's own CI** — all four still run there.

## [0.15.0] - 2026-07-23 — BREAKING

**`BREAKING`** — ships as a **minor-breaking 0.x bump (v0.15.0)** per
VERSIONING.md's pre-1.0 rules: the foundation→temperloop identity rename
(temperloop#165), **read-old-write-new**. Every legacy `foundation` name
keeps working through the migration window with a one-line deprecation
notice, and the legacy reads are **removed in v0.17.0** — touch your
overlay/config/env before that release, not necessarily before this pull.

> **[Later correction — 2026-07]** The removal did **not** land in v0.17.0:
> that version shipped as the epic #719 terminology release. The temperloop#165
> `.foundation/` window was **retargeted to v0.19.0** (see the `[Unreleased]`
> entry above; temperloop#764). The original v0.17.0 dates below are left intact
> as the record of what was announced at v0.15.0.

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

- **`/sweep` Phase 2 is now chunked parallel fanout (temperloop#671, the
  sweep-parallelization epic; tier 1 of ADR 0012).** The Ready-singleton fix loop no longer drives one issue at
  a time: the Phase-2 set partitions into chunks of up to
  `SWEEP_FANOUT_WIDTH` issues, each chunk one synchronous multi-item
  `build-level.mjs` invocation (the same within-level parallel path `/build`
  uses) followed by a per-chunk merge pass, with the quota gate moved from
  per-issue to per-chunk. Phase-1 underspecification detection fans out
  across parallel subagents at the `SWEEP_DETECT_MODEL` tier (empty default
  = inherit the session model). **Not BREAKING — `SWEEP_FANOUT_WIDTH=1` is
  the downstream opt-out lever**: setting it restores the prior behavior
  exactly (sequential drive, questions-first ordering), config-only, no
  spec revert. Resource-posture note for kernel-sync adopters: at the
  default width a sweep run now opens up to chunk-width **concurrent CI
  runs** (and board WIP rises to the chunk width) — a repo whose CI
  capacity can't absorb that sets the knob down (or to `1`). See
  `docs/adr/0012-sweep-two-tier-parallel-execution.md`; the background
  overlap tier (tier 2) is deliberately not included.

### Added

- **The release version is now embedded in the shipped files
  (temperloop#677).** A committed repo-root `VERSION` file (bare `x.y.z`) is
  the source of truth `temperloop version` reports, resolved by the shared
  `temperloop_resolve_version` helper in `bin/lib/common.sh` — precedence
  `TEMPERLOOP_VERSION` env > `FOUNDATION_VERSION` env (rename window) >
  `VERSION` file > `dev`. Previously a real tag-pinned install reported
  `temperloop dev` because nothing embedded the number; now the artifact
  carries its own version. A release cut **bumps `VERSION` in the tagged
  commit** (kernel-repo-layout.md § Release-tag convention), and
  `test_version_embedding.sh` (a `checks` gate) fails the build if `VERSION`
  drifts from the tag when HEAD is a release tag. The `install-tier2`
  round-trip gains a `version` leg asserting the installed CLI reports its
  embedded version, not `dev`. Additive: an explicit `TEMPERLOOP_VERSION`
  override still wins, so CI/test fixtures are unchanged.
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
- **Release version embedded in shipped files (temperloop#677).** `temperloop
  version` now reports the tagged release version from a committed repo-root
  `VERSION` file (resolution order: env override > `FOUNDATION_VERSION` rename
  window > `VERSION` file > `dev`) instead of always printing `dev`. A
  `test_version_embedding.sh` drift guard asserts `VERSION == X.Y.Z` when HEAD
  is exactly a `vX.Y.Z` tag, and install-tier2 gains a `version` leg.
- **`sweep` gains chunked, tiered fan-out.** Phase 2 is rewritten as a chunked
  synchronous fan-out (tier 1, temperloop#683), with an added attended
  question-overlap pass (tier 2, temperloop#685); new `SWEEP_FANOUT_WIDTH` and
  `SWEEP_DETECT_MODEL` knobs tune fan-out width and the detection model
  (temperloop#676).
- **`tidy` delete-on-PR-record archive semantics (temperloop#667).** The
  session-archive step records its PR and cleans up on record (Step 5 plus a
  Step 0 early-exit); `check-in` now surfaces a pending (unmerged) tidy archive
  PR.

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
- **`check-kernel-manifest.sh` runs against a vendored subtree root
  (temperloop#680).** Its `.git` hard-guard is relaxed (via `git rev-parse
  --is-inside-work-tree`) so a downstream overlay can gate kernel-manifest
  coverage against its vendored `kernel/` subtree — the enabler a downstream
  coverage gate consumes. Running against the kernel repo's own root is
  unchanged; a subtree-root regression test covers both the classified (green)
  and unclassified (red, names the path) cases.
- **`build` pipeline robustness.** The 3e.5 acceptance gate is now hermetic
  against the pipeline's own config knobs (temperloop#684) and tests the
  worktree rather than repoRoot (temperloop#663); the conversational path is
  guarded against workers backgrounding the quality gate (temperloop#678);
  epic auto-close is guarded against body-only acceptance loss (temperloop#668);
  `build-level` claims spike items before the verdict-park (claim-first,
  temperloop#664) and wires the `NO_CI` outcome into the spine schema and CI
  poll loop (temperloop#662).

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

