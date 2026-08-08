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

## [Unreleased]

### Changed

- **`/triage`'s cull, decision-route, and funnel-escalation close arms now
  route their Done writes through `board_close_done`** (#1217), guarded
  `if declare -F board_close_done` with a resolve-based fallback for a
  vendored `board.sh` that predates the helper. Each arm posts its reason
  comment first, then lands Done unconditionally — no more an `or`-branch a
  reader could take as optional, and no more a bare `gh issue close` in the
  funnel-escalation arm that left the board unstamped. Also deletes the
  false claim that a built-in close→Done automation reflects a close on the
  board (no such mechanism exists on this issues-only backend — see
  `workflows/scripts/board/ISSUES-ONLY-BACKEND.md` § Close→Done cascade) and
  corrects the Step 4.6 cache-bust note: the real hazard is that shell state
  does not persist between separate Bash tool calls, not a
  `board_set_milestone` cache-bust (it never dirties the cache).
- **`install-tier2.yml` is re-scoped off the retired `try` path onto the
  `init` -> `eject` adopt-path round trip against the persistent
  `Towheads/temperloop-demo` repo** (#1234). Drops the `temperloop try` step
  and `ANTHROPIC_API_KEY` entirely (no leg makes a model call), and no longer
  invokes the deleted `seed-demo-repo.sh`. The workflow never creates or
  deletes a repository — `DEMO_REPO_TOKEN` is a fine-grained PAT scoped to
  that one repo — and `eject`'s manifest-driven revert is what returns the
  repo to a reusable baseline each run. ADR 0025's "CI inherits the rule"
  consequence is amended to record the resulting accepted gap: no weekly
  automated coverage of `temperloop testbed` or its teardown.
- **The three `claude -p` seats in `bin/` now capture the `--output-format
  json` envelope instead of raw text** (#1264). `try.sh`'s shadow-triage call
  (C1) and `--demo` fix call (C2), and `configure.sh`'s AI-suggestions call
  (C3), all switch `--output-format text` → `json` and unwrap `.result` at the
  call site, so each call's own `usage` / `modelUsage` / `total_cost_usd` /
  `duration_ms` block is captured in a named variable for a future attribution
  emit. These seats pass `--no-session-persistence` and so write no transcript,
  which made them invisible to the tokens producer; the envelope is what makes
  them measurable without a one-off replay. `--tools ""`,
  `--no-session-persistence` and `--max-budget-usd` are unchanged at all three
  seats, and the model's own output is still printed/applied verbatim.

  **User-visible degradation lines** are the behavior change: a response the
  wrapper cannot read now says so specifically rather than failing opaquely,
  and each distinct cause gets its own message so a format change costs a
  *missing* number, never a wrong one — `returned an unparseable envelope`
  (the envelope itself did not parse), `returned an empty report` (C1: the
  envelope parsed and the model simply reported nothing), and `jq not on PATH`
  (C3: jq is an optional dependency of the wizard, and its absence is no
  longer misreported as a bad envelope). On every one of these the command
  degrades exactly as it did before — `try` skips the triage section and exits
  0, `configure` falls back to plain prompts and still writes. C2's
  parse-failure debug line now echoes the model's own `.result` when it is
  readable, falling back to the whole envelope only when it is not, so a
  first-run failure no longer prints `session_id` / `uuid` / cost internals.

  Not breaking: no overlay, config, or caller has to adapt.

- **`pipeline-retro-health.sh` resolves its lake roots logically and pins the
  PIPELINE stream to the writer's own default** (#1185). Two independent
  defects made the probe report `no-lake` from the checkout the pipeline
  actually runs in. First, `$here`/`raw_root` were resolved with `cd -P`
  (physical), which walks THROUGH a vendored checkout's `workflows/scripts/
  build -> kernel/workflows/scripts/build` directory symlink and lands three
  levels up inside `kernel/` — verified live:
  `cd -P .../foundation.cron/workflows/scripts/build && cd -P ../../..`
  yields `.../foundation.cron/kernel`, whose `meta/data/raw` holds only a
  stub README — instead of the checkout that owns the real lake. Both roots
  now resolve with a logical `cd`/`pwd` (no `-P`), which collapses `..`
  textually against `$PWD` rather than following symlinks. Second, the
  PIPELINE stream's default stopped being re-derived from that
  checkout-relative root at all: `pipeline-cron.sh:299` pins its own
  `PIPELINE_RAW_DIR` default to the intentionally **absolute**,
  checkout-independent `$HOME/dev/foundation/meta/data/raw` (foundation#725's
  "canonical absolute sink" — the cron sandbox checkout must still write into
  the main checkout's lake), so a script-relative guess here would read a
  *different* lake than the one the writer filled whenever the probe runs
  from that sandbox. `pipeline-retro-health.sh` now duplicates that literal
  verbatim (setting-registry.tsv's existing `PIPELINE_RAW_DIR` row already
  covers it — a byte-identical, non-vendoring-checkout-fallback duplicate,
  same convention as `PIPELINE_OPERATOR`'s duplicate in `pipeline-drive.sh`),
  falling through to it only when neither `PIPELINE_RAW_DIR` nor an
  operator-set `TELEMETRY_RAW_DIR` override is present — both overrides still
  win exactly as before. The RETRO-RUNS stream deliberately stays
  checkout-relative (unpinned from the writer's absolute root): its writer,
  the overlay `/retro` judge, sets no override and inherits whichever
  checkout invoked it, so converging the two streams onto one root would make
  the probe miss rows the judge wrote under a different checkout.
  `workflows/scripts/config/setting-registry.tsv` needed no new row — the
  duplicate literal is already registered under `pipeline-cron.sh` and the
  registry's name-only unregistered-setting sweep passes unchanged. Not
  breaking — read-only, still fails open (`no-lake`/`unknown`, exit 0) when
  the resolved lake genuinely holds no month-files.
- **`build-level.mjs` now emits a `phase()` per STAGE of a level instead of one
  static heading for the whole run** (#1294). The level's progress heading
  advances `claim → build → gate → PR → CI` as items move, so a collapsed
  `/workflows` view that renders the ACTIVE phase tracks the run rather than
  freezing on one line, and the expanded tree groups agents by stage instead of
  dumping every executor into one `machinery` box. Every stage title still
  carries temperloop#903's run context — `build level · gate — owner/repo · 3
  items · slug (#N), … +K more` — bounded by the existing
  `PHASE_TITLE_MAX_ITEMS`; `levelPhaseTitle()` was extended with an optional
  `stage` argument rather than forked into a second title format. Each agent is
  assigned to its stage's group through the documented `opts.phase` argument
  (the global `phase()` cursor races inside `parallel()`), and the cursor itself
  advances monotonically, so an off-path recovery probe gets its own group
  without dragging the collapsed row backwards. `meta` stays a pure literal and
  deliberately declares no `phases:` key — entries there are matched against
  phase titles exactly, and every title here is dynamic by #903's requirement.
  No change to claim/worktree/gate/PR/CI mechanics; this is a progress-surface
  change only. This is the kernel-side half of #1294 — the collapsed row still
  renders from `meta.description` until the Claude Code Workflow progress UI
  draws from the active phase, which this repo does not control.
- **`gate.sh diagnose-queue` now persists every verdict to its own telemetry
  stream** (#1192). The subcommand decides whether a merge queue is stalled,
  dequeued, or hit a GitHub Actions infra failure — and until now wrote that
  verdict **nowhere a consumer could read**, so the per-run stall tally the
  overlay wants could not be built at all. Verdicts are emitted by a new
  `workflows/scripts/emit-diagnose-queue.sh`, a **sibling** of the existing
  `emit-*.sh` scripts rather than code inlined into `gate.sh`: telemetry is
  contractually *warn, don't drop*, while `gate.sh` is a closed outcome set
  that fails loud via `die()` and whose exit codes `/build` and `/fix` branch
  merge decisions on — so an emit bug must never be able to reach that
  contract. The emit fires from inside `cmd_diagnose_queue`, so it covers the
  internal call on `cmd_poll`'s TIMEOUT path as well as a direct invocation,
  and it records on **both** attended and unattended runs (the two rejected
  alternatives each covered only one arm). Coverage is the full current
  verdict set, including `QUEUE_STALLED` and `MERGE_GROUP_INFRA`, which landed
  earlier in this same release. A dedicated `validate-diagnose-queue-emit.sh`
  joins the three existing per-stream validators, since these verdicts feed
  merge decisions. **Contract surface:** `scripts/quality-gates.sh` gains the
  validator gate. Not breaking — the emit is purely additive and cannot alter
  `diagnose-queue`'s exit-code contract. The consumer half (the tally itself)
  is overlay-owned and stays open at foundation#1281.

- **`report` now renders a directional dollar line from a kernel-shipped,
  dated default price table when the target repo carries no
  `.temperloop/pricing.json`, replacing the previous "add
  `.temperloop/pricing.json`" nudge for that case (#1251).** The new table
  lives at `workflows/scripts/config/default-pricing.json` — a tracked,
  hand-dated `{as_of, prices}` snapshot, never a live pricing-API read and
  never recalculated at runtime, refreshed only by hand-editing the file in
  an upstream PR (same discipline as the existing user-supplied table and as
  `bin/lib/cost-estimates.conf`). Every dollar line the default table drives
  carries its own `as_of` date and an explicit, unmissable staleness label
  alongside the existing DIRECTIONAL marker, so nobody mistakes the figure
  for a real invoice or for their own configured prices. A user-supplied
  `.temperloop/pricing.json`, when present, is used **exclusively** — it
  overrides the default table outright rather than supplementing it, exactly
  as before; the malformed-pricing-file and no-model-matched degradation
  paths are unchanged. A missing/malformed default table (a broken kernel
  checkout) degrades to the old nudge line rather than crashing.
  **Classified ADDITIVE (minor), not BREAKING — grounded in VERSIONING.md's
  contract-surface table, not merely asserted.** Two of that table's rows
  are in play. **CLI surface** (`bin/subcommands/*`) is what an adopter
  actually calls, and none of it moves: exit code 0, every flag, every
  section heading, and the user-`.temperloop/pricing.json` override path
  (including its **per-key**, never-blended override behavior) are all
  unchanged — pinned by `bin/subcommands/tests/test_report.sh`'s
  6c-iii-b/6c-iii-b2 fixtures. An adopter who already wrote a pricing table
  sees byte-identical behavior; one who never wrote one merely starts
  seeing a new, clearly-labeled directional dollar line where a nudge used
  to render — an addition, not a removal or a reshaping of anything a
  caller depends on. **Published schemas/contracts** (`*.contract.md`) is
  the row that *does* move: `workflows/scripts/lib/report.contract.md`'s
  "Pricing table & dollar framing" section is updated in this same change
  to document the new default-table tier, its override order, and its
  degradation paths — a documentation update describing new capability, not
  a behavior change a caller must adapt to, so it stays additive rather
  than tipping this release into BREAKING. No `BREAKING` marker, no
  migration note owed.

- **The generated `/build` worker prompt now carries a structural
  no-context-inheriting-research-fork guardrail** (#1072). Both execution
  paths — `workerPrompt()` in `claude/workflows/build-level.mjs` (a new
  `## No context-inheriting research forks` section) and
  `claude/commands/build.md`'s conversational-path worker-prompt
  instructions — ban spawning a context-inheriting `fork` for a narrow
  read-only sub-task (it inherits the parent's drive-to-done-and-commit
  mission and may fabricate a completion report or commit to the shared
  worktree, as observed in temperloop#635), while sanctioning a fresh
  explicitly-scoped read-only subagent or a fork whose prompt explicitly
  overrides the inherited mission — and cross-references build.md's
  existing "Seat scoping — nested review delegation" clause by name so the
  two are not misread as conflicting. Previously this guardrail lived only
  in a vault note a session had to remember to re-paste.

- **`init`'s fresh-install board-1 default is now documented as intended
  standalone-kernel numbering, not fleet-collision drift** (foundation#1339).
  `docs/features/install-cli.md` § "Board number" states plainly that a
  repo with no prior `.temperloop/config` and no `--board` flag mints board
  1, names the two existing escapes (`--board <n>`, or a carried-forward
  `tracker.board` from a prior config), and records why detecting a fleet
  operator's own numbering was rejected — that convention is overlay
  knowledge about one operator's repos, and baking it into the kernel
  installer would violate the stranger test. `bin/subcommands/init.sh`'s
  `board_num=1` fallback now carries a one-line pointer to that section.
  Documentation only; no behavior change.

### Added

- **`board`: `board_close_done <board#> <issue#>` — a Done write that
  survives an already-closed issue** (temperloop#1217). One call lands a
  board item Done from ANY state — open, already closed (the case a
  whole-board `board_item_id`/`board_set_status` composition silently
  no-ops on, since that list is `--state open` only), or already Done
  (no-op, exit 0) — and needs no prior `board_resolve_item`/`BOARD_ITEMS_JSON`
  carried over from an earlier call, since shell state does not persist
  between separate Bash tool calls. It saves and restores `BOARD_CURRENT`,
  leaving no adapter global modified. A thin, guarded composition over the
  existing `board_set_status … Done` write path (`ISSUES-ONLY-BACKEND.md`
  § Close→Done cascade already documents that path as the primary
  mechanism on this backend) — no new write logic.

- **`/promote`'s issue correspondence is now resolved by a real script,
  never a prose lookup** (#1235). `workflows/scripts/promote/resolve-correspondence.sh`
  resolves a copied testbed issue back to its original by **exact lookup**
  on the `copied from <owner>/<repo>#<N>` line `mirror-from-repo` stamps at
  copy time — never by title matching, ordering, or any other inference —
  and refuses rather than guesses, with a distinct outcome for each of
  three bad states: the line is absent, malformed, or the body was edited
  after copying (no longer the fixed trailing shape the writer produces).
  Its `report` mode gives `/promote` one row per testbed issue to use
  verbatim. The mechanical half exists as a script rather than a markdown
  step because an LLM-executed prose lookup gets paraphrased away, and the
  failure mode of a paraphrased lookup is a silently absent or silently
  wrong record, not a caught error.
- **`/promote`'s API-state story is now diff, record, and handoff — never
  apply** (#1236). Branch protection, required checks, labels, and board
  configuration are GitHub API state, not tree state, so they cannot ride a
  pull request; `workflows/scripts/promote/api-state-diff.sh` shows a
  read-only current-versus-proposed settings diff before the operator is
  asked to run the adopt path (`temperloop init`) themselves, then — once
  that separately-consented step has run — leaves a durable, team-visible
  record as a comment or issue in the real repository, naming the source
  testbed as a temperloop evaluation. Its report is structurally three parts
  (migrated / re-applied / left-to-you), each required, with a uniform
  "migration complete"-shaped claim refused in any of the three rather than
  left to prose discipline — re-applying the state itself stays the adopt
  path's job, never this script's, so ADR 0023's biconditional (docs/adr/0023)
  holds.

- **A committed provider allowlist and a paired disclosure log gate what may
  be sent to a third-party vendor** (#1250, epic #1225, ADR 0028 decisions 1
  and 2). `workflows/scripts/model-comparison/provider-allowlist.txt` is the
  ceiling — git-tracked, repo-scoped, Anthropic-only by default, and changed
  only through a reviewed commit: never an env var, never a `$HOME` config,
  never anything under the gitignored `.temperloop/` runtime dir. A personal
  `.temperloop/model-comparison/allowlist.local.txt` may NARROW that set for
  one checkout and can never widen it; a widen attempt fails closed (nothing
  is allowed) rather than being silently dropped. Every send to a non-default
  provider writes exactly one append-only, hash-chained JSONL entry carrying
  provider, item reference and timestamp — never content — through
  `allowlist.sh`'s `pa_disclose`, the only writer the library exposes, which
  refuses to log a provider the allowlist does not currently allow and
  serializes concurrent writers behind a lock so a provider fan-out cannot
  interleave two appends into a broken chain. A new `checks` gate,
  `workflows/scripts/validate-provider-disclosure.sh` (plus its fixture suite
  `workflows/scripts/model-comparison/tests/test_allowlist.sh`), enforces all
  of it on every PR, and four new settings — `PROVIDER_ALLOWLIST_TEST_SEAM`,
  `PROVIDER_ALLOWLIST_COMMITTED_FILE`, `PROVIDER_ALLOWLIST_LOCAL_FILE`,
  `PROVIDER_DISCLOSURE_LOG_FILE` — are registered in `setting-registry.tsv`;
  the three path seams are honoured only alongside
  `PROVIDER_ALLOWLIST_TEST_SEAM=1`, so the ceiling cannot be repointed from
  the environment. **What the chain proves, stated precisely:** it makes an
  entry rewritten in place, or deleted from the interior of an intact file,
  mechanically detectable. It does not, on its own, detect truncation of the
  log's tail, deletion of the whole log, or a full re-forge — an unanchored
  chain records nothing about its own length, and an unkeyed one can be
  rebuilt end to end by anyone who can write it. A sibling
  `disclosure-log.watermark` anchor closes the first two and makes the third
  loud, but the anchor is itself an untracked local file: it raises the cost
  of casual tampering and does not defeat an attacker who can write both
  files. Anchoring it beyond local write reach is tracked separately. The
  send-vs-log coverage cross-check (proving every actual send produced an
  entry) is owned by a later item in the same epic.

- **A comparison-statistics library, so a model comparison reports what the
  numbers can actually support** (#1249, epic #1225 "model comparison
  harness"). `workflows/scripts/model-comparison/stats.sh` (a thin CLI over
  the `stats.py` numeric core, python3 stdlib only — no network call, no model
  call, every subcommand a pure function of the numbers it is given) answers
  the four questions a cost comparison has to answer honestly. `bootstrap-ci`
  puts a percentile bootstrap confidence interval around a cost-per-merged-
  outcome delta array. `verdict` adds the winner call and, above all, the
  **inconclusive floor**: below `MODEL_COMPARISON_MIN_SAMPLE_N` outcomes the
  answer is always `inconclusive` with no winner-shaped field populated, so a
  CI that happens to exclude zero on four data points can never be read as a
  result — and `bootstrap-ci` enforces the same floor, because the guarantee
  has to be a property of the module rather than of the one subcommand that
  spells the word "verdict". `mde` reports two deliberately distinct effect
  sizes, since conflating them is how a comparison gets under-powered: the CI
  half-width as `margin_of_error`, and the genuine minimum detectable effect
  as `mde` — `(z + z_power) · σ/√n` at a `--power` that defaults to the
  conventional 0.80, roughly 43% larger than the half-width. Sizing N against
  the half-width instead is how a team spends the whole budget and lands on
  `inconclusive`. `coverage` reports emit-coverage against the structural
  denominator the L0 usage-capture spike (#1246) defined — the emit-FEASIBLE
  seat subset, never the full seat inventory — and refuses an observed count
  above that denominator, because passing the inventory as the numerator is
  the most likely form of exactly the confusion the subcommand exists to
  prevent.

  Five operator tunables are registered in `setting-registry.tsv` with their
  defaults in `build.config.sh`, which `stats.sh` sources rather than
  duplicating: `MODEL_COMPARISON_MIN_SAMPLE_N`,
  `MODEL_COMPARISON_BOOTSTRAP_ITERATIONS`, `MODEL_COMPARISON_BOOTSTRAP_SEED`,
  `MODEL_COMPARISON_CI_WIDTH_PCT` and `MODEL_COMPARISON_EMIT_FEASIBLE_SEATS`.

  Two properties are load-bearing enough to name. **Input is finite or it is
  rejected**: `json.loads` accepts bare `NaN`/`Infinity` and overflows `1e400`
  to infinity, and `json.dumps` re-emits those as tokens RFC 8259 does not
  permit — which `jq` silently coerces to `null`, where `null < 0` makes a
  corrupted record read to a downstream `select(.upper < 0)` as "the candidate
  is significantly cheaper". Non-finite input therefore exits 2 with empty
  stdout. **Results reproduce across CPython versions**: resampling draws
  indices from `Random.random()` (the only method CPython documents as
  sequence-stable) and accumulates with `math.fsum` (builtin `sum()` changed
  strategy in 3.12, gh-100425, and does not agree across versions), and
  `stats.sh` enforces a python3 >= 3.8 floor rather than assuming it. The
  fixture suite (`make test-model-comparison-stats`, wired into the kernel
  gate set) was run green on CPython 3.9.6 and 3.14.6 with byte-identical
  output, and its five settings assertions were verified by mutation —
  deleting each setting's forwarding in turn fails the suite.

- **`/promote` carries work back out of a testbed and into your real
  repository, as your pipeline's actual commits** (#1233). Building the
  evaluation in a disposable duplicate is only half the story; the other half
  is getting the good parts out without hand-copying files. `/promote` is the
  judgment half (which work is worth promoting, and the honest three-way
  report — commits carried, issue correspondence resolved by lookup, API state
  explicitly not migrated), and `workflows/scripts/promote/push-testbed-branch.sh`
  is the mechanical half: it adds the testbed as a remote in a throwaway
  workspace, fetches, and pushes a branch carrying the testbed's real commits
  and authorship — deliberately not the proposal-PR generator, which rebuilds a
  branch off the base tip and would squash that away. Its own suite asserts the
  guarantee that matters: exactly one push, always to `refs/heads/<branch>`,
  never the target's default branch. Pre-flight checks the branch-create
  precondition (with the fork fallback named in the refusal) instead of
  discovering it at failure time, and refuses a `materialize-from-seed` testbed
  by reading `source_kind` from the artifact record — a seed testbed has no
  original to promote to. Every pull request it opens carries a one-line
  provenance note so a reviewer with no context can tell where the change came
  from.
- **`reported_no_op` — a fourth disposition count on the `command-run`
  telemetry stream, closing a `/fix` no-op run's guaranteed reconcile failure
  (#1103).** `workflows/scripts/emit-command-run.sh` could express `merged`,
  `resolved (verdict)`, and `parked`, but `/fix`'s two reported-no-op routes —
  `already-done` (4e) and `claimed-elsewhere` (4d) — had no disposition to
  claim: emitting `items_processed:1` with all three at `0` would trip the
  emitter's own accounting assertion (temperloop#1084), so `claude/commands/fix.md`
  Step 6 instead skipped the emit entirely on both routes, leaving a real
  `/fix 1100` `already-done` run with **no telemetry record at all** — the
  exact absent-signal failure this stream exists to prevent. New
  `--reported-no-op <N>` → a `reported_no_op` field, and the emitter now
  asserts **`merged + resolved + parked + reported_no_op == items_processed`**
  (still exiting **2** with the arithmetic named on a mismatch, after
  appending the record — never a dropped record). A caller that omits the
  flag (sweep/triage, and any pre-#1103 `/fix` call site) still gets an
  explicit `0` and still reconciles. `fix.md` 4d/4e now call the emit
  directly — the two routes that previously "went straight to the report" —
  and Step 6 §4's prose no longer denies a fourth field is needed.
  `workflows/scripts/validate-command-run-emit.sh` gains the analogous
  content-derived check for the `reported-no-op` disposition (mirroring its
  existing `resolved (verdict)` check), so a future doc that grows this
  disposition without wiring the flag is caught without editing the linter.
  Purely additive (no `schema_version` bump); ⚠ absent on a pre-#1103 record
  means UNKNOWN, never `0`, same convention as `resolved`. New tests in
  `workflows/scripts/tests/test_command_run_emit.sh`.

- **`temperloop testbed` builds a private, disposable evaluation copy of a
  repo in one command, then hands off to `temperloop init` inside it**
  (#1229). The repo worth evaluating temperloop on is the one you care about
  — which is exactly the repo you do not want an unfamiliar tool creating
  branches and pull requests in. This builds a throwaway instead (create the
  repository, mirror-push the history, carry the open issues across) and ends
  in an unmissable final block carrying the testbed URL in full plus the
  literal `git clone` / `cd` / `temperloop init` commands. It registers by
  file presence and its `# description:` line alone — no dispatch-table edit
  — and is the first consumer of both Level 0 seams (the machine-scoped
  artifact record and the four-function source provider): the driver is fixed
  and contains no `case` on provider kind, so the second provider will land
  without touching it. Pre-flight unions the driver's own all-reads checks
  with the provider's and refuses with a `cannot proceed —` / `skipped —`
  line naming the fix, having written nothing anywhere; consent refuses
  outright on a non-tty stdin with no `--yes` — the guard `try --demo`
  established, carried to a command that now creates real remote repositories
  — and `--dry-run` is proven zero-write structurally, by a fake `gh` and
  `git` on PATH logging every call plus a before/after file-tree diff. Each
  artifact is flushed to the record the instant its step completes, so a run
  killed partway stays enumerable by teardown instead of becoming an orphaned
  private repository.
- **The build write-jail guard now binds a worktree to the AGENT writing in
  it, and refuses an uncoordinated second writer** (#1187). Containment
  answered "does this write stay inside the worktree?" but never "is THIS
  agent the one supposed to be writing here?" — a sibling `/build` worker that
  `cd`s into a peer's worktree passed every existing check. The guard now
  records the `agent_id` of the FIRST qualifying in-tree write as that
  worktree's owner (binding at first write, not at worktree creation — the
  `.build-guard` marker is dropped at build step 3b, before any worker exists,
  and deliberately stays `{slug, branch, created}`) and denies a write from an
  agent that already owns a *different* armed worktree. An **absent**
  `agent_id` is a third, always-allowed state, never folded into "non-owning":
  the orchestrator's own post-spawn push/rebase/prune run main-thread and
  carry none, and rejecting them would deadlock every level's merge path. A
  nested read-only review subagent (the sanctioned nested-delegation pattern)
  is untouched, because only writes bind. The `agent_id` discriminator was
  confirmed live against real PreToolUse payloads before being built on.

- **A machine-scoped testbed artifact record tracks every artifact a
  `temperloop testbed` run creates** (#1227). The record is an append-only
  list resident in XDG state
  (`${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/...`, not `.temperloop/`,
  so it survives `eject`), keyed by `owner/name` so a consumer resolves its
  own entry from `git remote get-url origin` with no filesystem scan. It owns
  the full schema up front — the artifact list (repo created, mirror pushed,
  issues copied) plus the source-provenance fields `source_kind`,
  `source_repo`, and `promotable` that promote-spec-and-tree-push reads two
  levels later — and carries a `schema_version`, refusing on an unknown
  version, following `workflows/scripts/install/manifest.sh`. Ships
  library-only with its own tests and no CLI caller yet, exactly as
  `manifest.sh` did when it landed.

- **A source-provider seam sits upstream of `temperloop testbed` pre-flight,
  plus its first implementation `mirror-from-repo`** (#1228). The seam is
  four functions, not one tuple — `describe()` (kind, base name, provenance
  capability, promotability), `preflight_checks()` (the provider's own
  all-reads checks), `produce_git(dest)`, and `produce_issues(dest)` — so the
  command never branches on provider kind to decide which checks to run, and
  `describe()` resolves with zero network writes so pre-flight still runs
  before anything is produced. `mirror-from-repo` stamps a machine-readable
  `copied from <owner>/<repo>#<N>` line into every issue it creates, inside
  its own `produce_issues` rather than in shared downstream code. Ships
  library-only with its own tests.

- **`/check-in` now reads and disposes the environment-hygiene surface**
  (#596). `/tidy`'s § Environment hygiene step already ran `env-reconcile.sh`
  and appended each drift finding to the environment hygiene report, and
  `CLAUDE.kernel.md` § Environment hygiene already promised that drift was
  appended "for `/check-in` to review and dispose" — but `check-in.md` carried
  no section that read the surface, so the propose half of the loop had no
  disposer and every finding sat unread. The motivating incident: a
  telemetry-regeneration LaunchAgent sat **unloaded for four days**;
  `env-reconcile.sh` detected it correctly and `/tidy` recorded it, and it
  still never reached the operator. Part 2 gains an
  `### Environment hygiene review` section, mirroring the existing
  `### Vault hygiene review`: for each `open` entry it presents the
  launchd/checkout/worktree drift, lets the operator act or dismiss, and
  patches the entry's `Status`. It **never** mechanically reloads an agent or
  resets a foreign checkout — per § Environment hygiene's aggressive-in-lane /
  report-cross-lane split, disposition of a foreign checkout stays the
  operator's call.

- **A second testbed source provider, `materialize-from-seed`, plus the in-tree
  seed it materializes** (#1230). It implements the same four seam functions as
  `mirror-from-repo` — no new dispatch, no `case` on provider kind, no second
  path downstream, so teardown reclaims a seed testbed by exactly the route it
  reclaims any other. `describe()` reports `provenance_capable: false` and
  `promotable: false`: there is no upstream issue to cite and no original to
  promote back to, and `produce_issues` correspondingly stamps no provenance
  line. Per ADR 0025 the seed is content **tracked in this repository** —
  `workflows/scripts/demo/seed/`, a fixture project plus one Markdown file per
  issue — built into a fresh repository locally and pushed into the operator's
  **own** account; no repository owned by this project exists at any point. The
  fixture replaces the retired `demo-seed` one-file synthetic defects with a
  small, coherent Markdown link checker: six issues that group into a real
  first epic for `/triage` and `/build`, a suite that ships green, and its own
  gate (`make test-demo`) asserting every defect the issues claim is still
  present and the seed still passes.

- **`temperloop testbed --teardown` deletes a testbed created by a prior run**
  (#1231). Teardown is a MODE on the existing command, not a second
  subcommand — it branches early and never touches the create-path driver's
  fixed step order or its four seam calls. The target resolves from
  `--repo OWNER/NAME`, or from `--dir`'s (default: cwd) `origin` remote read
  with `git -C` (never a `cd`), so it works from any cwd — inside the
  testbed's own clone, not only the checkout that created it — by keying
  straight into the machine-scoped artifact record (`record.sh`) rather than
  any tree-relative path. Every recorded entry has `repo_created=true` by
  construction, so a single `gh repo delete` removes whatever the record
  enumerates, complete or partial. `gh auth login`'s default scope set omits
  `delete_repo`; teardown checks for it first via a new reusable helper
  (`workflows/scripts/testbed/scope.sh`) and, when absent, degrades legibly —
  prints the one-line `gh auth refresh -s delete_repo` remedy and exits 0 —
  rather than failing on a `gh repo delete` call it can never make.
- **A provider-equivalence guard makes the epic's central structural claim
  mechanical: both testbed source providers drive one identical call
  sequence downstream of the seam** (#1232). Two test doubles — never the
  real `mirror-from-repo`/`materialize-from-seed` (their content differences
  are `test-testbed-source`'s job) — are driven through
  `bin/subcommands/testbed.sh`'s own driver, and the test asserts an
  identical seam-call sequence plus an identical driver
  step/pre-flight/flush/handoff trace between them, modulo the
  source-identity fields (kind, `provenance_capable`, `promotable`) that
  legitimately differ — excluded from the comparison by name, with a sanity
  check proving the exclusion is real rather than accidental. Asserting over
  the driver's own sequence, not either provider's internals, is what makes
  a provider-agnostic-orchestration bug fail here instead of surfacing as a
  seed-provider failure; this is the guard that stops the prepared-source
  option from drifting into a second path — precisely how `try --demo`
  became a dead end. States plainly, in its own header and in
  `docs/features/testbed.md`, what it does **not** prove: identical
  evaluation value — the two sources differ in content, promotability, and
  privacy exposure by design, and no test speaks to that. Zero network, its
  own `make test-testbed-equivalence` gate.

### Changed

- **`write-lane-guard.sh` no longer prompts on the one cross-repo direction
  the architecture prescribes: a kernel checkout mutating its own declared
  allied overlay checkout** (#1028). The guard's verdict is unchanged
  everywhere else (still `ask`, never deny, on every other foreign canonical
  checkout — the epic #86 peer-session protection) — this only exempts an
  explicitly DECLARED pair from firing at all. The pairing is read from an
  optional, gitignored, repo-local config file,
  `claude/hooks/write-lane-allies.conf` (tracked `.example` at
  `claude/hooks/write-lane-allies.conf.example`, same
  tracked-example/gitignored-real-file shape as
  `workflows/scripts/board/boards.conf.example`) — a config file rather than
  an env var, since `KERNEL_EDIT_ACK`/`EVAL_RUN` are session-scoped
  acknowledgements and this is a durable, repo-level fact. Never a hardcoded
  org/repo string: this kernel ships to strangers whose overlay checkout is
  not necessarily named `foundation`. **Not breaking** — absent config is
  today's behavior exactly, byte-for-byte.

- **A queue-time `CONFLICTING` now takes a shared `rebase-and-retry`
  disposition instead of an unconditional park** (#1093). GitHub reports
  `CONFLICTING`/`DIRTY` both for a branch whose base merely *moved* while the
  PR sat in the merge gate and for a branch with a genuine content conflict —
  and `/build` Step 4c and `/fix` Step 5 parked on the label either way,
  spending an operator's merge approval on a base that had simply advanced.
  `/build` § 4c gains **`4c-retry`**, one implementation composed entirely from
  existing machinery (`pr.sh rebase` → `pr.sh push --force` → a `--sha`-pinned
  `ci-poll.sh` → the caller's already-probed `gate.sh queue` /
  `gate.sh managed-merge`), and `/fix` Step 5 references that section by name
  rather than carrying a second copy. A cleanly-rebasable PR is re-pushed,
  re-verified on the new head, and re-enqueued **within the same run with no
  second merge approval** — sound because the merge decision is unchanged (a
  clean rebase replays the approved commits without touching a hunk) and the
  one thing that moved, the base, is re-verified mechanically by the
  SHA-pinned poll before anything is enqueued. A **genuine content conflict
  still parks**, now naming the conflicting files, and is never auto-resolved;
  a `CI_FAILED` on the new base takes the existing `EJECTED` disposition set;
  a second `CONFLICTING` stops the retry rather than looping. `pr.sh rebase`'s
  own `REBASED`/`REBASE_CONFLICT` outcomes are the branch point, and its
  abort-and-restore on conflict is relied on, not reimplemented. Contract
  surface via `claude/commands/*.md`; **not** breaking — the park path and the
  `#130` confirmed-`MERGED` guard are unchanged, the retry only runs ahead of
  them. `/sweep` is deliberately **not** wired in: it fires
  `gh pr merge --auto` and immediately records the item fixed, with no
  merge-confirmation call site to hang a disposition on — that plumbing is
  tracked separately (#1268).

### Removed — BREAKING

- **The try-era demo-repo generator `workflows/scripts/demo/seed-demo-repo.sh`
  and its `SEED_DEMO_REPO` setting** (#1230). The generator seeded a scratch
  repository **this project owned**, which ADR 0025 retires: evaluation
  artifacts are now materialized into the operator's own account from the
  in-tree seed above. `workflows/scripts/demo/` is retained as the seed-content
  home. **Migration:** if you set `SEED_DEMO_REPO` in a host-local config or
  CI secret, drop it — it is no longer read by anything, and the testbed's
  target repository is resolved from the source provider's `base_name` in the
  operator's own account instead. The `try`-side settings and the CI
  round-trip's own use of the generator are retired with `try` itself
  (#1237/#1234).

- **`temperloop try` and `temperloop try --demo` are removed, and the CLI's
  front door is now `temperloop testbed`** (#1117). The old two-rung on-ramp
  (`try` -> `try --demo` -> `init`) was retired in favour of the sandbox walk
  (#1115): `try`'s shadow-triage ran with almost no context, so its output
  undersold the pipeline, and `--demo` ticked a canned repo of synthetic
  defects rather than the reader's own code. Deleted outright:
  `bin/subcommands/try.sh`, its two suites (`test_try.sh`,
  `test_try_demo.sh`), and `bin/lib/cost-estimates.conf` (every constant in
  it was a `TRY_*` band). `bin/temperloop`'s `Start here:` line and
  `temperloop help` now name `temperloop testbed`. `try`'s documentation goes
  with it, in the same change rather than a follow-up — `bin/README.md`'s
  legacy-commands section and `docs/features/install-cli.md`'s legacy rungs.

  **Migration — CLI surface.** `temperloop try` and `temperloop try --demo`
  no longer exist and exit as unknown subcommands; there is no compat shim
  and no drop-in replacement with the same shape. Evaluate on your own code
  with **`temperloop testbed`** instead (`docs/features/testbed.md`), which
  builds a private, disposable duplicate of a real repository of yours and
  hands off to `init` -> `/assess` -> `/build`. Note the deliberate trade:
  `try`/`try --demo` carried hard, tool-enforced USD caps ($1.00/run and
  $2.00/tick) and the testbed path does **not** — it runs the real pipeline
  and carries no dollar ceiling (temperloop#1130 tracks closing that gap).
  `VERSIONING.md`'s CLI-surface row no longer enumerates `try`.

  **Migration — setting registry.** Five `TRY_*` rows are gone from
  `workflows/scripts/config/setting-registry.tsv`, and they are **not** the
  same kind of removal — read which class yours is before pulling. Three are
  `kernel`-scoped test seams that only ever existed to let `try.sh`'s own
  suites inject doubles — `TRY_GH_BIN`, `TRY_DEMO_CLONE_URL`,
  `TRY_DEMO_BOARD_NUM`; a consumer setting them is a no-op today and their
  removal is harmless. The other two are `tracked-repo`-scoped model
  settings — `TRY_TRIAGE_MODEL` (defaulted `claude-haiku-4-5`) and
  `TRY_DEMO_FIX_MODEL` (inherit sentinel) — and this is the materially
  different case: a downstream overlay may carry a **live override** for
  either in its own `build.config.sh`, and that override now names a setting
  nothing reads. It will not error; it will silently do nothing. **Delete
  those two overrides from your overlay** rather than leave them as dead
  config. Their definitions and their entry in the export list are removed
  from `workflows/scripts/build/build.config.sh` in the same change, so the
  registry-to-source correspondence stays clean.

- **The `make test-try` gate is renamed `make test-cli-subcommands`, not
  deleted** (#1117). The target only ever carried `try`'s name incidentally:
  it globs the whole `bin/subcommands/tests/` directory and is the sole
  runner for 13 suites that have nothing to do with `try` (init, eject,
  config, configure, report, feedback, uninstall, update, baseline-snapshot,
  dispatch-rename, prereq-scoping, report-offer, tokens-producer). Deleting
  it would have silently dropped all of their coverage. The glob, and
  therefore the covered set, is unchanged; only the name moved, along with
  its `.PHONY` entry, its help line, its `gate-paths.tsv` row and its
  `scripts/quality-gates.sh` registration. A downstream repo invoking
  `make test-try` directly must call `make test-cli-subcommands` instead.


### Fixed

- **Board claim-stamp host labels no longer diverge by call site** (#1455).
  `claim.sh`, `release.sh`, `capture.sh`, and reconcile.sh's three read sites
  each inlined their own `${SUBSET_HOST_LABEL:-$(hostname -s)}` fallback,
  `board-mirror.sh` independently inlined a three-way variant that also
  nested the legacy `STAGEFIND_HOST_LABEL` override, and one reconcile.sh
  site added a fourth `|| echo unknown` variant on top — five inlined copies,
  three different shapes. `build.md`'s prose spec documented the three-way
  chain as canonical, but no script actually matched it. One real machine hit
  the resulting divergence live: some issues got claim-stamped `mini`, others
  `Mac-mini`, and `reconcile --status` then misclassified a same-host claim
  as foreign. Added `board_host_label()` to
  `workflows/scripts/board/lib/board.sh` as the one resolution chain every
  site now calls (`$SUBSET_HOST_LABEL` → legacy `$STAGEFIND_HOST_LABEL` →
  `hostname -s` → a literal `unknown`, never empty); the `build.md` and
  `decision-queue-contract.md` prose specs now name the helper instead of
  restating a chain, so they can't drift from the scripts again.
  `workflows/scripts/build/issue-state.sh` and `env-reconcile.sh` still
  inline a variant of this chain — left alone deliberately (issue-state.sh
  doesn't source board.sh today; env-reconcile.sh's host check answers a
  different question, launchd/cron role ownership, not claim stamps) — and
  is a follow-up, not part of this fix.
- **`ready-pr-sweep.sh` no longer misclassifies a PR whose `mergeStateStatus`
  simply hasn't been computed yet as `needs-attention`** (foundation#1504).
  GitHub computes `mergeStateStatus` asynchronously — right after a push, an
  enqueue, or any base-branch movement it reads `UNKNOWN`, meaning "not
  computed yet", not "computed, and problematic". Reading it exactly once
  meant the SAME PR could read `UNKNOWN` (→ `needs-attention`) on one sweep
  and `CLEAN` (→ `ready`) moments later on the next — the remedy flipped
  between back-to-back runs. The sweep now re-fetches ONLY a PR that reads
  `UNKNOWN` on the initial `gh pr list`, with a bounded retry
  (`READY_PR_SWEEP_UNKNOWN_RETRY_MAX`, default 3) and a short delay between
  attempts (`READY_PR_SWEEP_UNKNOWN_RETRY_DELAY`, default 2s) — a PR that
  reads a resolved status on the first fetch costs zero extra `gh` calls. A
  PR resolved on retry (e.g. UNKNOWN → CLEAN) now classifies normally; a PR
  still `UNKNOWN` after the bound gets its own `not-yet-computed` bucket,
  distinct from `needs-attention`, whose reason names the real cause and
  prescribes no operator action — it is deliberately excluded from
  `--format entry` since there is nothing to decide (it resolves on its own
  on a later sweep). Fail-open throughout: an errored or exhausted retry
  never aborts the run or drops the other PRs from the report.

- **The kernel/overlay classifier is shell-portable and fails closed — it no
  longer answers "not kernel" when it cannot evaluate at all** (#1177).
  `workflows/scripts/kernel/lib.sh` is *sourced*, so its `#!/usr/bin/env bash`
  shebang is inert and it runs under whatever shell the caller is. On macOS
  that is routinely zsh, and two bash-isms broke there **silently**:
  `${!ARRAY[@]}` (rejected with `bad substitution`) and — the nastier half —
  zsh's refusal to glob-match a pattern arriving via parameter expansion
  without `GLOB_SUBST`, which makes `case "$f" in $pat)` and
  `[[ "$f" == $pat ]]` evaluate to *no match* with no error whatsoever. The
  result was `kernel_lib_classify claude/commands/build.md` returning empty +
  rc 1 under zsh (`kernel` under bash) — bit-identical to the legitimate
  "no pattern matched" answer, so **every agent invocation** of `/assess`'s
  seam-straddling check and `/build` Step 3b's kernel backstop (the #1050
  guard) took the failing branch and passed everything it exists to stop. The
  lib now holds the manifest in one newline-delimited scalar instead of
  parallel arrays, sets `localoptions globsubst` under zsh, and keeps every
  construct POSIX-shaped (bash 3.2 / bash 5 / zsh). Fail-closed is now a
  *signal*, not better error handling: `kernel_lib_load_manifest` runs a
  known-answer `kernel_lib_selftest` before parsing and verifies its entry
  store populated, and `kernel_lib_classify` distinguishes **rc 1** ("no
  pattern matched") from **rc 2** (`CANNOT EVALUATE`). Every consumer treats
  rc 2 as a hard error rather than swallowing it: `check-kernel-manifest.sh`
  and `list-kernel-set.sh` abort instead of reporting a path unclassified or
  emitting a silently-truncated kernel set, `validate-feature-docs.sh` gains
  the same rc contract plus its own matcher selftest, and the two **prose**
  consumers (`claude/commands/assess.md`, `claude/commands/build.md`) carry
  identical fail-loud wording so the agent-executed surface behaves the same
  way. A new dual-shell regression gate,
  `workflows/scripts/kernel/tests/test_kernel_lib_portability.sh`, runs
  byte-identical asserts under bash, zsh, and macOS bash 3.2 against a
  **known-kernel control** (`claude/commands/build.md`) — the control being
  the point, since a run that checks only the files it just touched is exactly
  how this stayed invisible. Contract surface via `claude/commands/*.md`; not
  breaking.

- **The board issue cache no longer serves a merged item as still open/In
  Progress until its TTL expires** (#1164). The write-through invalidation
  hook `_board_cache_dirty_after_write` (`board.sh`, called from every
  `board_set_status`/`board_stamp` write) already existed and was already
  tested — it was a *designed* no-op whenever the calling bash block hadn't
  sourced `lib/cache.sh`, which none of the merge-confirmed Done-write sites
  did. `claude/commands/build.md` (4d's per-item Done write and 4d-epic's
  epic-close Done write), `claude/commands/fix.md` (Step 6's Board
  close→Done), and `claude/commands/sweep.md` (Phase 2's merge and spike-close
  arms, which bypass the adapter entirely and so take an explicit
  `cache_dirty` call) now guarded-source `lib/cache.sh` alongside
  `lib/board.sh` — the same `if [ -f … ]; then . …; fi` form
  `worklist.sh:50-53` already used, never `[ -f … ] && .` under `set -e`
  (temperloop#1118) — activating cache invalidation on the merge-confirmed
  Done write. `test_cache_command_wiring.sh`'s warm-cache/zero-`gh`-call
  assertion for `worklist.sh` is unchanged: this only makes the *next* read
  after a merge legitimately stale, so it refetches once, not on every warm
  no-change read. Contract surface via `claude/commands/*.md`; **not**
  breaking.

- **A transient GitHub Actions infra outage no longer permanently ejects a
  healthy PR onto the do-not-retry path** (#1175). `gate.sh diagnose-queue`
  splits its `MERGE_GROUP_FAILED` verdict on **per-job step data**
  (`repos/<owner>/<repo>/actions/runs/<run_id>/jobs`, never log text): a
  workflow-defined step — any step after the runner-provided "Set up job"
  step — itself concluding `failure` stays `MERGE_GROUP_FAILED` (exit 7, a
  real gate failure); the run concluding `failure` before ever reaching a
  workflow-defined step now reads a new `MERGE_GROUP_INFRA` verdict (exit 11,
  payload `{"pr":N,"run_id":N}`) instead. The motivating incident: foundation
  PR #1563's `merge_group` run logged `Set up job -> Failed to resolve action
  download info -> Service Unavailable` and was reported as a gate failure,
  routing a healthy PR to conflict-resolution with no conflict to resolve.
  Classification is purely structural — the step's position, never its name
  or any log string — so a CI step rename can never silently reclassify a
  result, and anything unclassifiable (the jobs lookup erroring, an
  empty/missing jobs array, missing step data) stays the conservative
  `MERGE_GROUP_FAILED` default: this split never widens what gets retried.
  `build.md` Step 4b routes `MERGE_GROUP_INFRA` to a **re-enqueue** (the same
  re-arm-once pattern `DEQUEUED` uses) rather than ejecting to 4c, and names
  it alongside `MERGE_GROUP_FAILED` in the unattended pending-decisions
  record. Contract surface via `claude/commands/build.md`; **not** breaking —
  `MERGE_GROUP_FAILED`'s existing exit code, payload shape, and 4c routing
  are unchanged for a real gate failure.

- **A stalled merge queue is now distinguishable from a merely slow one**
  (#1178). `gate.sh diagnose-queue` gains a `QUEUE_STALLED` verdict (exit 10,
  payload `{"pr":N,"enqueued_secs":S,"merge_group_runs":0}`): a PR that is
  *still* enqueued past the new `BUILD_QUEUE_STALL_AFTER` setting with **zero**
  `merge_group` runs ever dispatched for it is stuck, not slow — so a caller
  stops waiting instead of re-polling to the `BUILD_QUEUE_TIMEOUT` ceiling and
  then guessing. This is the probe that was hand-run during the incident
  (`gh run list --event merge_group` against the entry's `enqueuedAt`), now in
  the machinery. A healthy entry is untouched: under the threshold, or with any
  referencing run, it still reads `QUEUED`, so the ~2.5 min a queue's own
  checks legitimately take can never trip it. `gate.sh poll`'s `TIMEOUT` now
  runs the same probe and carries its verdict as `reason`/`diagnosis` rather
  than a bare `waited` count — the difference between "try again later" and
  "stop waiting, this needs a human" — falling back to the previous bare shape
  when the probe itself errors. `build.md` Step 4b routes the new verdict
  (dequeue + `managed-merge --strict` fallback) and names it in the unattended
  pending-decisions record.

- **The board scripts' remaining live Projects-v2 framing is corrected to the
  issues-only backend ADR 0004 shipped** (Towheads/foundation#1339). Two
  runtime-facing sites still described the removed backend: `capture.sh`'s
  not-landed error told the operator to wait out "a Projects-v2 index race"
  when the issues-only backend writes status synchronously — the real failure
  mode is a failing/transient `fnd:status:*` label write, which the message
  now names, along with a working remedy; and `release.sh`'s parking guidance
  named `gh project item-edit`, a Projects-v2-only command that cannot work on
  any registered board, replaced with the currently-valid options
  (`unclaim.sh`, `board_set_status`, or hand-editing the `fnd:status:*`
  label). Not breaking: comment/message wording only, no behavior or contract
  change.
- **`/build` Step 0a drains an answered plan-approval on attended ticks too, so
  an operator's `approve` no longer strands** (Towheads/foundation#1496). The
  step was gated on the operator-absent flag, so on a board no funnel ticks the
  answer was read by nobody: the decision issue went unassigned (= answered),
  the plan note stayed `status: draft`, and `/build` refused to pick it up —
  observed inert for six days with no surface anywhere showing it was stuck.
  Step 0a now runs on every work-selecting tick, in two arms. The
  operator-absent arm is unchanged (set `status: approved`, then invoke
  `/build --unattended`). The new **attended-tick drain** applies the same
  answer, stops at `status: approved`, reports the plan in one line, and is
  explicitly forbidden from invoking `/build` — widening *when* the step fires
  is already a fleet-wide change, and letting an attended tick auto-start a
  build would widen what that firing can *do* (`docs/principles.md` § 7 Bound
  the blast radius). Not breaking: no overlay must adapt, and the only
  behavioral delta for an attended argless `/build` is one extra `gh issue
  list` read plus the `status:` flip the operator already asked for.
  `/check-in` Part 1 gains a read-only § Stranded plan approvals probe as the
  backstop for a repo neither arm ticks.
- **Every piped `grep -q` is gone from the tracked shell set, and a new lint
  keeps the shape out** (#1050). `grep -q` exits zero at its *first* match
  without draining the pipe, so the writer upstream takes SIGPIPE (141) and,
  under `set -o pipefail`, the pipeline reports **141 — a failure — even though
  grep matched**. It is a race on whether the writer had already finished, which
  is why such a line passes for months and then fails once under a longer input.
  Every site is converted to the one sanctioned form — drop `q` from the flag
  cluster however it is clustered (`-Fxq`→`-Fx`, `-qF`→`-F`, `-Eiq`→`-Ei`, bare
  `-q`→ no flag) and append `>/dev/null`, which drains to EOF with bit-for-bit
  identical exit status. A `<<<` herestring and an intermediate variable were
  both rejected: each changes trailing-newline or word-splitting behaviour per
  site. **Contract surface:** `scripts/quality-gates.sh` gains a `KERNEL_GATES`
  pair, `bin/subcommands/{init,eject}.sh` change behaviourally under pipefail,
  and an overlay carrying its own shell scripts will see the new lint run
  against them. Not breaking — the new gate rejects a shape that was already
  wrong, and the fix is mechanical.
- **New `scripts/lint-pipe-grep-q.sh` gate** (#1050). Anchored, quote-aware, and
  self-exempt: it fires on `<writer> | grep -<cluster containing q>` (including
  `egrep`/`fgrep`/`zgrep` and `command grep`), and stays silent on an *unpiped*
  `grep -q file` — correct, and a pure win — and on a comment that merely names
  the shape. It reads every tracked `*.sh` **plus every tracked file with a
  sh/bash shebang**, with **no pipefail predicate**: a sourced lib sets no `set`
  line and inherits pipefail from its caller, which is exactly how
  `workflows/scripts/lib/issue-marker-probe.sh` hid a live site. Paired
  `scripts/tests/test_lint_pipe_grep_q.sh` demonstrates the lint firing on the
  real pre-sweep `bin/subcommands/init.sh` line and staying silent on prose.
  The sweep's completeness criterion is that lint exiting 0 over the tree — a
  predicate, deliberately not a site count.
- **`/sweep` now treats an issue with a later `Clarified (…)` answer comment
  as answered, not underspecified** (#1193). Phase 1's per-item fetch pulled
  only `title,body,labels`, so an issue whose question had already been
  answered in a comment — by triage, by a prior `/sweep` answer, or by the
  Phase-2 escalation-park path — carried no signal the detection fanout could
  see; a stale surviving `needs-clarification` label, or the self-judged-
  underspecified arm re-reading the same ambiguous body, could re-raise a
  question the operator already answered. The fetch now also pulls
  `comments`, and Step 2 states the exclusion explicitly: an issue carrying a
  `Clarified (…)` comment (`Clarified (sweep): …`, `Clarified (triage): …`,
  etc.) newer than its most recent flagging-type comment — either
  `needs-clarification: <question>` or the escalation-park path's
  `Parked by sweep — <question>` — is **answered, not underspecified**, and is
  excluded from the question batch. The rule applies to both detection arms
  (self-judged and already-labelled), so a stale label alone cannot re-raise
  an answered question. The comment-timestamp comparison itself is mechanical,
  not judgment, so it also ships as a standalone, independently testable
  script (`workflows/scripts/build/sweep-answered-exclusion.sh`, covered by
  `workflows/scripts/build/tests/test_sweep_answered_exclusion.sh`) rather
  than living only as prose.
- **The drain no longer lexicon-greps the expanded command spec as operator
  signal** (#1199). Claude Code writes a slash-command invocation as TWO user
  turns: the `<command-name>` tag block (~115 chars), then the **expanded
  command spec prose** (~133k chars in the cited stub) — which carries no
  `<command-*>` tag at all. `scan_stub.py`'s purely tag-based
  `_CMD_EXPANSION_PATTERNS` matched only the first, so the entire spec body was
  scanned as though the operator had typed it: the stub
  `2026-07-29-0254-foundation.cron-e5e70c47.md` yielded 38 lexicon matches, all
  from turn 1, all the tidy spec quoting its own tells. Every
  `claude -p "/<cmd>"` cron run (tidy, build, sweep, triage, check-in) hit this
  on every run, making it the drain's highest-volume false-positive source.
  `extract_user_turns` now also excludes the **single** user turn immediately
  adjacent to a `<command-name>` invocation. The rule is deliberately narrow:
  one turn of adjacency (a genuine operator turn later in the session is
  untouched), user-role only (an adjacent assistant turn means the command
  produced no expansion turn), and **no size threshold** — a bare length cutoff
  would silently drop long genuine operator turns. F#1137's
  `spec_authoring_context` damping does not cover this case: it keys on an
  Edit/Write to a tell-defining file, and here the session never *edited* a
  spec, it merely *received* one as its prompt.
- **The merge gate's hunk-overlap probe now trial-merges the pushed PR heads,
  not stale local refs** (#1198). `/build` Step 4a's condition-(a) probe decides
  whether a selected set is `risky` (modal hard-block) or
  `clean-disjoint-independent` (timed auto-merge), and it did so by running
  `git merge-tree --write-tree <branchA> <branchB>` on **bare** branch names.
  Git resolves a bare name against whatever the local clone last saw — a
  leftover from a removed worktree, or a ref diverged from what was actually
  force-pushed — so the probe could trial-merge the wrong trees and report a
  **spurious** conflict, converting an unattended timed merge into an operator
  interrupt. Both documented forms (the primary and the older-git
  `merge-base` fallback) are now `origin/`-qualified and preceded by an
  explicit `git fetch origin <branchA> <branchB>`, so the probe tests the
  pushed head the queue would actually integrate — the same reasoning § 4a.5
  already states for `combined-tree-precheck.sh`. Prose-only; the two-tier
  probe structure (cheap file-overlap advisory, then hunk-overlap on same-file
  pairs) is unchanged. Not a duplicate of #998, which concerns `--write-tree`
  *output* reuse rather than *input* ref resolution.

- **A draft PR is now a named state in the merge path, not GitHub's raw
  enqueue error** (#1180). `gate.sh queue` enqueued blind, so a draft PR — which
  GitHub refuses to auto-merge — failed with the raw string
  `GraphQL: Pull request is a draft (enablePullRequestAutoMerge)`: true, but
  naming neither the state nor the fix, and leaving behind a PR no re-run could
  ever land. The investigation this fix turned on: **draft-open is not a
  pipeline flow.** `pr.sh open` calls bare `gh pr create --head --title --body`
  with no `--draft` on any path, `build-level.mjs` adds none, `pr-enqueue.sh`
  drafts only on an explicit `--draft` opt-in (and already refused to enqueue
  one), and **no script in this repo runs `gh pr ready`** — so a draft reaching
  the merge gate is always a human decision. The disposition is therefore to
  **fail loudly, never to auto-flip**: `queue` reads `isDraft` before the
  enqueue and returns a distinct `DRAFT` outcome (exit code 9) whose message
  names the draft state and the remedy (`gh pr ready <n> -R <owner>/<repo>`);
  silently un-drafting would override the one party who chose it. The pre-flight
  probe **fails open** — an unreadable `isDraft` proceeds to the enqueue, never
  worse than before — and a second classifier, anchored on the draft phrase
  alone so an unrelated auto-merge rejection is not mis-named, returns the same
  `DRAFT` outcome when `gh` itself rejects the PR. Neither path can surface the
  raw GraphQL text.
- **`ready-pr-sweep.sh` gained a `stale-draft` drift class** (#1180). The sweep
  classified every draft as `skip`, and `--format entry`'s nothing-when-clean
  contract suppresses a skip-only repo entirely — so a draft nobody ever flipped
  ready was structurally invisible to the one surface that reports stuck work.
  That is how three drafts sat 1-3 weeks with real fixes in them, one a live
  correctness bug. A draft idle for `READY_PR_SWEEP_STALE_DRAFT_DAYS` or more is
  now its own named class and a genuine candidate, so it reaches `/check-in`
  through the pending-decisions entry; a *recent* draft stays `skip`, since an
  in-flight draft is a deliberate state and not drift. The sweep remains
  read-only and fail-open — it names the stale draft, it never flips or closes
  one.
- **The `pipefail` + `grep -q` SIGPIPE race is gone from the kernel test
  suite** (#1173). Under `set -o pipefail`, `echo "$var" | grep -q PATTERN` is
  a race, not a stable idiom: `grep -q` exits on its **first** match and closes
  the pipe while the producer may still be writing, the producer takes
  `SIGPIPE`, and `pipefail` promotes that non-zero status to the whole
  pipeline — so a **passing** assertion intermittently reports failure. Because
  it is a race it reproduces only sometimes, which is why a single green run
  was never evidence a site was safe. The confirmed instance reds CI:
  `test_issue_corpus.sh` line 211 printed `echo: write error: Broken pipe` and
  then `FAIL: 3: doc2 missing/wrong state field (closed issue)` in foundation CI
  run 31101856658. All **618** `<producer> | grep -q` constructs across **59**
  kernel test scripts — every `tests/` directory under `workflows/scripts/`,
  `claude/hooks/`, `bin/subcommands/` and `scripts/` — are rewritten to the
  race-free here-string form `grep -q PATTERN <<<"$var"`, which has no writer
  process to signal and no pipeline for `pipefail` to judge. Three multi-stage
  variants (`echo … | awk … | grep -q`, `printf … | jq … | grep -qv`) are
  de-piped the same way. The rewrite is deliberately a here-string rather than
  a `case` arm: a here-string preserves each assertion's **exact** semantics —
  every flag (`-F`, `-E`, `-i`, `-v`, `-x`, `--`), every anchor, and every
  negated `&& fail` — whereas a `case` glob would silently turn an anchored
  assertion like `^state: "closed"$` into a permissive substring test, weakening
  the suite in the name of fixing it. `bin/subcommands/tests/test_tokens_producer.sh`
  is deliberately untouched: #1168 / PR #1172 own that file.

- **`test_tokens_producer.sh` check 16 no longer fails at random on a
  consumer's Linux CI** (#1168). The check built its haystack twice with
  `grep -vE '^[[:space:]]*#' "$IMPL" | grep -q <pattern>`, under the file's own
  `set -uo pipefail`. `grep -q` exits on first match — for the
  `SPEND_TRANSCRIPT_ROOT` pattern that lands within the first few hundred bytes
  of a ~37KB producer — closing the pipe while the upstream `grep -vE` is still
  writing. GNU grep (every Linux CI runner) then reports `write error: Broken
  pipe` and exits 2, `pipefail` promotes that to the pipeline's status, `!`
  inverts it, and the check fails **a green tree**. BSD grep on macOS usually
  wins the race, which is why it reproduced only downstream and read as a flake
  locally. The comment-filtered source is now captured once into a variable and
  matched with `case` — no pipe, no race — matching the convention check 12
  already used. The assertions are otherwise untouched (same two patterns, same
  two failure messages), so this cannot mask a real disclosure regression. Found
  downstream while building foundation#1552, where a worker had fixed it inside
  foundation's *vendored* `kernel/` subtree; that commit was dropped and
  transplanted here, upstream-first. A sibling instance of the same
  `pipefail` + `grep -q` shape in `workflows/scripts/lib/tests/test_issue_corpus.sh`
  — which, not this one, is what had actually been reddening consumer CI — is
  fixed by #1173 above, in this same release.

- **A token carrying only the default `repo` scope is no longer refused by five
  command specs for a capability none of them uses** (#1159). `/fix`, `/sweep`,
  `/next`, `/assess` and `/triage` hard-stopped at Step 0 unless `gh auth
  status` listed the **`project`** scope, and offered `gh auth refresh -s
  project` as the remedy. That scope authorized the Projects-v2/GraphQL board
  arm, which ADR 0004 / epic #524 removed outright: every registered board now
  runs the issues-only backend, where Status, the claim stamp, Done and the
  epic mirror are plain-REST label writes, issue-closes and sub-issues calls —
  all covered by `repo`. The `gh auth status` check itself is unchanged in every
  spec that had one; only the scope *requirement* is gone, replaced by an
  explicit "never check for or require a `project` scope" statement matching the
  one `/triage` Step 0.2 and `/build` Step 0.5 already carried. `/build`'s two
  claim-failure notes drop the `-s project` remedy, and its Step 0.5 bullet is
  collapsed to state the single remaining backend rather than argue against a
  branch that no longer exists. The same dead framing is cleared from the
  `claim.sh`, `worklist.sh` and `unclaim.sh` headers (which all still advertised
  the `project` scope as a prerequisite) and from the `capture.sh` and
  `milestone.sh` headers (which described `--board` as selecting a "Projects-v2
  board"). Third instance of #524's decomposition gap, where a leg's enumerated
  `files:` list was treated as an inventory: `grep -rn 'auth refresh -s project'
  claude/ workflows/` now returns nothing.
- **`/sweep`'s Step 1 singleton fix pool no longer admits decomposed epic
  parents** (#1038). The pool was defined as Ready items with `board_parent_issue`
  empty, which correctly excludes epic *children* but not epic *parents* — a
  Ready item that is itself an epic head with native sub-issues passed the
  filter untouched and would be driven through a single fix worker instead of
  the `/assess` + `/build` path its decomposition calls for. Measured impact:
  11 of 46 pooled items were epic parents on board 7 and 13 of 31 on board 4
  (2026-08-02). The pool now also excludes any Ready item for which
  `board_sub_issues <board> <issue#>` returns non-empty, gated on the same
  Ready-slice-only scope the existing `board_parent_issue` check already used
  (no whole-board REST fan-out added), and the seam prose at every site that
  described the filter — the frontmatter `description:`, the header
  paragraph, and Step 1 itself — now reads "neither a sub-issue of an epic nor
  an epic parent" instead of "not a sub-issue of an epic".
- **`pipeline-tick.sh`'s Phase R retro-judge urgency bypass now fires against
  the real `gh` label shape, and a parked-but-not-due tracker set is no
  longer silent** (#1184). `read_retro_trackers`'s LIVE arm (`gh issue list
  --json …labels`) hands back `labels` as OBJECTS
  (`{id,name,description,color}`), never bare strings, while
  `retro_judge_due_reason`'s urgency check was `(.labels // []) |
  index("retro-urgent")` — always `null` against an object array, so the
  urgency bypass decided at mint (#533) never fired live even though the
  DRY_RUN fixture arm (already string-shaped) always passed. The LIVE arm now
  normalizes `labels` to a bare name array so both arms agree. Separately,
  Phase R's "not due yet" case (trackers parked, none urgent, the oldest
  hasn't crossed `RETRO_MIN_INTERVAL`) used to return silently — indistinguishable
  from a healthy no-op tick — and now emits a `skip-retro-judge` action with
  `reason: "not-due"` carrying the tracker count and the computed `due_at`, so
  a steady-state debounce wait reads distinctly from the two broken-judge
  skips (`not-declared`, `headless-unsupported`) instead of going quiet.

### Added

- **A restricted candidate-session overlay + provider-key health check**
  for the model-comparison harness epic (#1225). New
  `workflows/scripts/model-comparison/candidate-session.sh` is a reusable
  preflight/resolve/spawn CLI: `preflight` fails loudly at pre-flight
  (never a silent no-op) when a non-default provider's API key is unset,
  naming the exact env var and the concrete host-supply file
  (`build.config.local.sh`); `spawn` hands the child an EXPLICITLY
  CONSTRUCTED environment — `env -i` plus a named allowlist plus exactly one
  provider key, the selected provider's — so no other provider key and no
  other host secret the config ladder exports reaches a candidate session.
  (`env VAR=value cmd` ADDS to the inherited environment rather than
  replacing it, so an allowlist is what actually isolates; the forwarded key
  is chosen from the one provider table, so registering a provider later
  cannot silently start leaking.) `candidate.settings.json` is a
  deny-over-allow containment overlay removing every knowledge-store/vault
  MCP tool and every path/command reaching `build.config.local.sh`, its
  `build.config.machine.sh` sibling and its `.env`-shaped siblings, while
  keeping the ordinary replay/worker surface reachable. Its deny patterns are
  plain `*<needle>*` substring globs, never `**/`-anchored: the matcher is a
  shell `case`, which has no globstar, so a `**/` pattern requires a literal
  `/` in the subject and silently fails to deny a bare filename.

  `spawn` also REFUSES a permission-overriding passthrough argument (a second
  `--settings`, an allow/deny-tools override, a permission-mode or
  skip-permissions switch, an extra `--add-dir`, an alternate MCP/setting-source
  config) rather than forwarding it into the child, where it would override
  the very overlay being installed.

  Both `resolve` and `spawn` fail CLOSED on an overlay they cannot read:
  distinct exits `3` (absent), `4` (unreadable) and `5` (malformed), never
  `unspecified` at exit `0` — "I could not determine the restriction" is never
  reported as "no restriction applies". A flag given with no value (a trailing
  `--provider`) is exit `2`, not a silent fallback to the default provider.
  Registers the `make test-candidate-session` gate
  (`scripts/quality-gates.sh`, `Makefile`,
  `workflows/scripts/config/gate-paths.tsv`) and the `CANDIDATE_SETTINGS` and
  `CANDIDATE_ENV_PASSTHROUGH_EXTRA` setting-registry rows, and adds the
  missing kernel classification for `workflows/scripts/model-comparison/*` in
  `kernel-manifest.txt`. Not breaking — a new opt-in module with no
  default-path behavior change (the module has no caller yet).

## [0.28.0] - 2026-08-05 — BREAKING

### Migration — read this first

Two migrations, and one of them will break a consuming profile on the next
command if it is skipped.

**1. Delete any `board-adapter-guard.sh` registration from your
`settings.json`.** The hook is removed with the Projects-v2 arm it guarded. A
`PreToolUse` entry pointing at a missing script is a **per-command error**, so
this is not optional cleanup — grep your installed profile for
`board-adapter-guard` and remove the block. Nothing replaces it: with no
Projects arm there is no `gh project` call to intercept and no shared GraphQL
budget to protect.

**2. Stop calling the removed Projects-v2 adapter functions.** `lib/board.sh`
now speaks exactly one backend — issues-only, over REST — and
`board_project_number`, `board_field_id`, `board_option_id`, the
`_board_cached_read` family and the budget guard are gone. If your overlay
calls any of them directly, it must adapt. Every registered board has run
issues-only since 2026-07-18, so no tracking behaviour changes; only the
adapter's surface shrinks.

**Who does NOT have to act:** a consumer that only ever went through the public
`board_resolve_item` / `board_item_list` / `board_set_*` / board-command surface
and does not register the hook. That path is unchanged.

**Also in this release, and worth pulling for on its own:** a correctness fix to
the cached relationship reads (#1163). If you run with `board.<N>.cache=on`,
the pre-0.28.0 cached arm returned "no children" for **every** issue, which
`board-mirror.sh` reads as "epic fully drained" — it was armed to close epics
that still had open children. See the `### Fixed` entry below.

### Fixed

- **Relationship reads are live-only again; the cached arm was silently
  returning "no children" for every issue** (#1163). `board_sub_issues` /
  `board_parent_issue` gained a cached arm in #1030 on the premise — asserted in
  board.sh's own comment and in #1023's acceptance as "verified live" — that the
  bulk issues-list payload carries the parent link as a nested `.parent.number`.
  **It does not.** The bulk list carries `sub_issues_summary` (counts only);
  `parent_issue_url` comes from the *single-issue* endpoint. Measured against
  real stores: **0 of 911** rows in one repo's snapshot and **0 of 611** in
  another's carry any `parent` key. The arm read a field that was never there
  and returned empty, silently.

  **Why this mattered:** `build/board-mirror.sh` counts
  `board_sub_issues <b> <epic> open | wc -l` and treats **0 as "epic fully
  drained"**, closing the epic. Once board-mirror.sh began sourcing `cache.sh`
  (#1118) and the enable axis was switched on, that path was armed to close
  epics with open children — verified on a real open epic (live = 1 open child,
  cached = 0). Both accessors now always take the live path, like
  `board_blocked_by_open`.

  Its suite is why this survived: the fixture hand-wrote `"parent":{"number":300}`
  into snapshot rows, so it was strictly more capable than reality and green-lit
  a path production could never take. `test_relationship_cache.sh` is rebuilt
  around the **real** payload shape and carries a regression guard that fails
  against the old arm and passes against the fix.

  This is recoverable at zero API cost — `cache_refresh_details` already fetches
  the payload carrying `parent_issue_url` and discards it (#1165).

### Changed

- **A cached read no longer parses the whole snapshot just to validate it**
  (#1163). `cache_read`'s freshness guard ran `jq . "$snapshot"` — a full parse
  of a 3.7–5.1MB file whose result was **discarded** — on every read, before
  `cat` read the file again and the caller parsed it a third time. It now checks
  only the last line, which is the guard that matches the real failure mode
  (`_cache_persist_snapshot` writes to a temp file and `mv`s it into place, so
  partial content can only appear at the end). Measured on `board_item_list`
  p50: **452ms → 313ms** and **336ms → 214ms** on two real boards, ~1.5x.

### Removed — BREAKING

- **BREAKING — the Projects-v2/GraphQL arm is removed from the board adapter**
  (ADR 0004, epic #524). `lib/board.sh` now speaks exactly one tracking
  backend: issues-only, over REST. The tracking flow issues **no GraphQL call**
  and depends on no paid or org-level GitHub feature — a free account and a
  repo are sufficient.

  Gone from the adapter: every `gh project` argv and the single-item
  `gh api graphql` resolve; the 5,000-pt/hr GraphQL budget guard
  (`_board_budget_guard`); the whole cross-process structure/state read cache
  (`_board_cached_read`, `_board_cache_file`, `_board_cache_bust`,
  `_board_cache_patch_*`, `_board_file_age`, `_board_item_list_argv`,
  `_board_item_list_fresh`, `_board_drop_pr_cards`); and the public functions
  `board_project_number`, `board_field_id`, `board_option_id`,
  `board_add_to_board`, `board_bust_structure`. Settings `BOARD_CACHE_TTL`,
  `BOARD_STRUCTURE_TTL`, `BOARD_CACHE_DIR`, `BOARD_ITEM_QUERY`,
  `BOARD_BUDGET_GUARD`, `BOARD_BUDGET_GUARD_THRESHOLD`,
  `BOARD_CREATE_BUDGET_GUARD`, and `BOARD_CREATE_INDEX_RETRIES` left the
  setting registry with them.

  **Every surviving public accessor keeps its issues-only behavior
  byte-identical** — each function's Projects half sat behind an
  `_board_is_issues_only` early return, so this deletes tails rather than
  restructuring the live path. `BOARD_PROJECT_ID` and `BOARD_FIELDS_JSON` are
  now vestigial but are still set to their documented empty values (`""` and
  `{"fields":[]}`), so a caller reading them under `set -u` is unaffected.
  Item ids are `ISSUE_<n>`; a `PVTI_*` id is now rejected loud.

  **Soak evidence.** ADR 0004 required "at least one release of soak" between
  deprecating the Projects-v2 arm and removing it
  (`docs/adr/0004-issues-only-default-backend.md` § Decision). The arm was
  deprecated in **v0.15.0** (2026-07-23); all five registered boards — the
  four fleet repos (ssmobile, stageFind, subsetwiki, foundation) plus the
  kernel's own tracker (board 7) — have run issues-only since **2026-07-18**.
  **Ten releases** (v0.16.0 through v0.25.0) shipped between the deprecation
  and the v0.26.0 removal that actually deleted the Projects-v2 code path —
  ten times the one-release bar, with zero live Projects users observed
  during that window.

  **Migration — read this before pulling.** There is **no configuration path
  back** to Projects-v2; an adopter who wants it forks `board.sh`. A
  `boards.conf` line reading `board.<N>.backend=projects` **hard-fails** with a
  one-line error citing ADR 0004 — deliberately, rather than silently resolving
  to `issues`: a backend that changes under you with nothing telling you is the
  exact failure temperloop#908 recorded. If any board is still on the
  Projects arm, **check out v0.25.0 and run its
  `workflows/scripts/board/migrate-board-to-issues.sh` first** — v0.25.0 is the
  last release carrying that script, which was deleted in v0.26.0 per ADR
  0004's ordering pin — then delete the `backend=projects` line and pull. The `backend` axis otherwise remains
  accepted and inert; a stale `project=` axis is simply no longer read.

  This also lands the supersession ADR 0005 § Decision and § Consequences
  documented in advance: the built-in map's **additive-only** rule, and the
  "board 7 is the sole in-code issues-only exception" language, are retired
  here explicitly. Board 7 is no longer an exception to anything.

### Fixed

- **The nested retro-judge spawn carries its own credential instead of
  inheriting one it never gets** (temperloop#1148). Phase R's judge was spawned
  two levels deep — `pipeline-cron.sh` → the headless 5b driver → `claude -p
  "/retro --pending"` — and a Claude Code session does not forward credential
  environment to a child it launches from its Bash tool. On a headless host with
  an expired interactive OAuth session, hop one authenticated and did real work
  while hop two died before turn 1, visible only as a `safe_failed` counter.
  The 5b driver no longer types that command: each `retro-judge` action now
  carries an absolute `spawn_cmd` naming the new
  `workflows/scripts/build/pipeline-retro-judge-spawn.sh`, which sources the
  checkout's own config ladder (`build.config.sh` → the gitignored, mode-600
  `build.config.local.sh`) to **re-derive** the credential at the process that
  actually invokes `claude -p` — the same move `tidy-nightly.sh` already makes
  before its own nested invocation. A `claude -p` typed by hand in that session
  is now a hard-rule violation in the payload and in `pipeline-drive.md`.

  An auth failure there is **loud**, not a counter: classified by *shape* rather
  than exit code (a failed nested session can still exit `0`), pushed through the
  `PIPELINE_NOTIFY_CMD`/`osascript` channel `pipeline-cron.sh` already uses,
  echoed to stderr for the cron log, and returned as a distinct exit code (`3`
  auth-failed, `4` spawn-failed). The credential's **value** is never placed on an
  argv, printed, or logged — only presence and a source label are reported, and
  the wrapper redacts any credential value out of its child's pass-through
  output.

- **The retro-judge seam refuses legibly instead of exiting success having
  judged nothing** (temperloop#1150). The funnel tick's Phase R gated its nested
  `claude -p "/retro --pending"` spawn on command *presence* alone, so a host
  with `/retro` installed but no working headless mode spawned a judge that could
  not run: the nested session ended its turn and exited `subtype: success` /
  `is_error: false` having produced zero judgments and zero run-stream rows.
  Phase R now also requires the judge to **declare** the capability it is being
  driven under, and emits a reason-bearing `skip-retro-judge`
  (`reason: "headless-unsupported"`, remedy on the line) instead of spawning when
  it has not. Never silence: either the judge runs, or the tick says why it
  didn't. See the amendment in
  `docs/adr/0007-retrospection-mint-then-judge.md`.

### Added

- `command_declared_capability <name> <capability>` in
  `workflows/scripts/lib/command_declared.sh` — the capability companion to the
  ADR 0008 presence probe. Answers from a `capability:` marker line, alone on its
  line, in the first-resolved command file; fail-closed everywhere (no marker, no
  file, no answer ⇒ false), with a `COMMAND_CAPABILITY_OVERRIDE` fixture seam.
  Presence is discovered; capability is declared.
- `workflows/scripts/build/pipeline-retro-health.sh` — a read-only,
  always-exit-0 detector that separates the readings a zero-row `retro-runs`
  stream used to collapse into one: `no-signal` (nothing was due — the genuine
  steady state), `refused` (the tick declined, and why), `healthy`, and `defect`
  (a trigger fired and produced nothing, sub-typed `never-had-a-row` vs
  `stalled`), plus `no-lake` when the trigger history is unreadable. `/tidy`'s
  Retro mint backstop gains a fourth probe that runs it and files a `defect`
  verdict as a board defect.

### Changed

- `pipeline-retro-health.sh` gains an `auth_failures` count and a
  `defect_kind: "auth"` verdict that outranks `never-had-a-row`/`stalled`
  (temperloop#1148) — read from the stable `retro-judge-auth-failed` token the
  spawn wrapper emits into the drive record, so a credential problem is the
  durable, `/tidy`-visible half of the loud signal and is never re-diagnosed as
  a broken judge. The detail line names the remedy.

- `skip-retro-judge` tick actions now carry a machine-readable `reason` field
  (`not-declared` | `headless-unsupported`). A reader matching on the action name
  alone is unaffected.

- **The CHANGELOG gate now enforces SECTION SCOPE, not just completeness**
  (temperloop#1151). `workflows/scripts/check-changelog-entry.sh` fails a change
  that adds lines to — or removes lines from — a CHANGELOG section that was
  **already released at its merge base**, in both directions: an unmerged PR's
  entry drifting *into* a released section when a release is cut underneath it
  (temperloop#1138), and a released section *losing* an entry that legitimately
  shipped in it (the temperloop#1125 over-correction, the same class as
  temperloop#1143's four unrecorded PRs). The discriminator is the **base ref**:
  a version heading that did not exist at the merge base is one this change is
  *creating*, so a release cut — which looks identical at head — passes
  unmodified. The check runs whenever CHANGELOG.md is in the diff, independent
  of whether contract surface was touched. Deliberate amendment of a shipped
  release stays possible through a **sibling verb in the existing marker
  grammar** — `Changelog: amend — <reason>`, honored in the same three channels
  (the new `changelog-amend` PR label, a PR-body line, or a commit trailer) with
  the same reason requirement. The `none`/`skip` verb is unchanged and does not
  waive section scope. New setting: `CHANGELOG_GATE_AMEND_LABEL`.

- **BREAKING — `claude/hooks/board-adapter-guard.sh` is removed**, together with
  every kernel-plane rule that taught the two-backend model (epic #524). The
  hook existed to prompt on a direct `gh project` / Projects GraphQL call and
  protect the shared 5,000-pt/hr budget; with the Projects arm gone there is no
  such call to intercept and no such budget to protect. An installed profile
  that registers this hook by path in its `settings.json` must **delete that
  registration** — a `PreToolUse` entry pointing at a missing script is a
  per-command error. `EVAL_DENIAL_LOG` (its eval-mode denial log) leaves the
  setting registry; `EVAL_RUN` survives, now owned by
  `claude/hooks/eval-guard.sh`, and still self-suppresses every side-channel
  hook.

  **The adapter discipline itself is unchanged and still load-bearing.**
  `claude/CLAUDE.kernel.md` § "GitHub Projects boards — always via the board.sh
  adapter" is renamed to § "**Board reads and writes — always via the board.sh
  adapter**" and rewritten for one backend, keeping the rule and restating its
  rationale: the adapter owns the `fnd:` label encoding (a hand-rolled
  `gh issue close` leaves a stale `fnd:status:*` label and claim stamp behind)
  and the cross-process item cache. What went with the arm: the GraphQL-budget
  clause, the `board_bust_structure`-after-a-structural-edit rule, the
  structure/state cache-split paragraph, the guard-hook sentence, and the board
  glossary's org-project-URL column plus its "board ids and URL numbers are
  swapped for 3 and 4" warning.

  **Two corrected instructions, not just prose tidying.** § "Board hygiene is
  part of the gate" and `/build` 4d/4e + `/fix` no longer describe a
  backend-conditional Done write: **nothing moves an item to Done on its own**,
  so the explicit `board_set_status … Done` is the primary mechanism on every
  board. `/build`'s epic-close step previously said to *skip* that write and
  rely on the close→Done cascade — on the surviving backend that left the epic
  wearing its status label, so it now issues the write. Likewise the
  `project` gh scope is **never** checked (`/build` Step 0, `/triage` Step 0.2):
  the default `repo` scope runs everything, and requiring `project` would halt
  an otherwise-valid run. `Seq` writes are unconditionally skipped rather than
  guarded on a backend probe that can now only answer one way (ADR 0006).
  `board_set_status` takes an `ISSUE_*` item id, not `PVTI_*`.

### Changed

- **The stranger-facing docs plane now teaches one backend** (epic #524).
  `README.md`, `AGENTS.md`, `docs/architecture.md`, and the affected feature
  docs no longer present Projects-v2 as an available backend or the
  5,000-pt/hr GraphQL budget as a constraint a reader plans around.
  `docs/features/board-adapter.md` is rewritten for a single backend — its
  GraphQL-budget, structure/state cache-split, and dual-arm sections are
  removed rather than hedged — and now states plainly that board reads are
  live REST calls sharing one budget with CI polling and issue/PR porcelain.
  `docs/features/gh-perf.md`, `build-machinery.md`, `merge-gate.md`,
  `branch-hygiene.md`, `managed-merge-queue.md`, and `docs/principles.md`
  are retargeted onto that merged-budget framing, whose consequence — no
  second bucket left to route a noisy caller onto — is the subject of
  `docs/failure-modes/02-rest-budget-exhaustion.md`.

### Removed

- **`docs/features/install-cli.md` § "Manual Projects-v2 recipe" is deleted.**
  It walked an adopter through `gh project create` plus a hand-written
  `boards.conf` entry — a path that now reaches no code, since the adapter has
  no Projects arm to read it. The surrounding § Tracker mode states plainly
  that after this release there is **no configuration path back to
  Projects-v2** and that an adopter who wants it forks `board.sh`, and carries
  the v0.25.0 migration pointer. `bin/subcommands/init.sh`'s `--tracker-mode`
  and `--provision-*` rejection messages (and `bin/README.md`'s compat note)
  are repointed at that statement rather than the deleted recipe, so no
  user-visible error text names a section that no longer exists.

## [0.27.0] - 2026-08-05 — BREAKING

### Migration — read this first

One migration, and it is narrow: **`temperloop init` no longer accepts the
`--provision-*` flag family or `--tracker-mode`** — passing either now exits 2
instead of being silently ignored. This finishes the epic #524 arc v0.26.0
opened (ADR 0004, `docs/adr/0004-issues-only-default-backend.md`); the backend
itself did not move again in this release.

**Who has to act.** Only an adopter whose wrapper script, Makefile, or CI job
still passes `--provision-board`, `--provision-labels`, any other
`--provision-*`, or `--tracker-mode` to `temperloop init`. On v0.26.0 those
flags parsed and were discarded, so such a caller is green today and will exit
2 after pulling. **The fix is deletion — drop the flag from the invocation.**
There is no replacement flag and no behavior to preserve: every registered board
has run issues-only since 2026-07-18, so there has been nothing to select or
provision for some time. `grep -rn -- '--provision\|--tracker-mode'` over your
own scripts is the whole audit.

Nothing else in this release moves an adopter-facing contract. The rest is two
gate fixes that make a **vendoring consumer's** `make quality-gates` pass where
it previously could not — strictly a loosening, and the kernel's own checkout is
byte-for-byte unchanged by both.

### Fixed

- **`check-gate-paths.sh` no longer fails a vendoring consumer for being one**
  (#1144). The gate already detected a composed tree (repo-root `.kernel-pin`)
  and its checks 2/3 reported a legible `[skip]` for rows naming gates such a
  tree legitimately lacks — but **check 4 (reachability) honored neither the
  exemption nor the vendored layout**, so it hard-failed the very rows check 3
  had just skipped, and judged every kernel-authored path missing because in a
  consumer it is tracked under the subtree prefix. In foundation's tree that was
  **108 failures** (`VERSION`, `VERSIONING.md`, `AGENTS.md`, `make test-try`, …),
  and the remediation line told the consumer to edit a `gate-paths.tsv` that is a
  symlink to the kernel's own. Check 4 now (a) skips a row whose gate is absent
  from the composed tree, using the same predicate check 3 uses, and (b) resolves
  a row against `<prefix><path>` as well as `<path>`, where the prefix is the new
  `GATE_PATHS_KERNEL_PREFIX` seam (default `kernel/`). **Not a blanket consumer
  bypass:** a row whose gate *is* present in the tree keeps full literal-path and
  reachability checking, and the kernel's own checkout is byte-for-byte
  unchanged — both pinned by fixture cases.

- **`test_quality_gates_parallel.sh` no longer asserts the kernel's CI shape
  against a consumer's** (#1144). Its required-status-context check encoded the
  kernel's own single-entry matrix (`checks (ubuntu-latest)`); a consumer whose
  contract is a single non-matrix job named `checks` could never satisfy it. The
  assertion is now scoped to the kernel's own checkout and reports a `SKIP:` line
  in a consumer. Every other check in that section is a shared invariant and
  still runs everywhere.

### Removed — BREAKING

- **`init.sh --provision-*` (the whole board-provisioning flag family) and
  `--tracker-mode` are gone; both now exit non-zero** (ADR 0004, epic #524
  "retire the Projects-v2/GraphQL arm"). Every registered board has run
  issues-only since 2026-07-18, so there is nothing left to select or
  provision — a caller passing either flag now hits a dedicated case arm
  that names the removal release and exits 2, rather than the flag being
  silently accepted and ignored. No replacement flag: an adopter's script
  simply drops `--provision-*`/`--tracker-mode` from its `init` invocation.

## [0.26.0] - 2026-08-05 — BREAKING

### Migration — read this first

This release removes the Projects-v2/GraphQL board-adapter arm (epic #524,
"Remove the Projects-v2/GraphQL arm (BREAKING) — post-soak follow-on to epic
#460"; ADR 0004, `docs/adr/0004-issues-only-default-backend.md`). **Migration
to the issues-only backend must be completed on v0.25.0 or earlier.**
`migrate-board-to-issues.sh`, the dry-run-first Projects→issues migration
script, is deleted in this release (see `### Removed — BREAKING` below) —
past this point there is no script left in the tree to run it with. If you
have not already migrated a `backend=projects` board, check out v0.25.0 (or
earlier), run the script from there, then upgrade.

**Who has to act.** Only an adopter still running `backend=projects` on any
board. Nobody this repo's own maintainers govern is affected: all five
registered boards have run issues-only since 2026-07-18, the soak window ADR
0004 required before this removal. For an issues-only adopter this release
changes nothing observable — `lib/board.sh`, the board adapter interface,
hook names and signatures, and the `checks` gate contract are all untouched.
The one other adopter-facing consequence is `### Changed — BREAKING` below:
every backend-conditional branch in the board/build caller scripts is gone,
so a `backend=projects` board is no longer served the code path it used to
take through `claim.sh`, `reconcile.sh`, or `release.sh`.

### Added

- **`board_sub_issues` takes an optional state filter (temperloop#1119).**
  `board_sub_issues <board> <issue#> [all|open|closed]` — the third arg is new
  and **defaults to `all`, so every existing two-arg call is byte-identical**.
  Not breaking; no overlay has to adapt. It exists because the epic-close
  "how many children are still open?" count is a relationship read like any
  other, and without a state filter its only options were the raw REST
  endpoint — which bypasses the cached arm entirely — or one state lookup per
  child, which is N extra calls to answer what a single snapshot pass already
  knows. Both the cached and live arms apply the filter, so they stay
  byte-parity under every state value; a warm-only filter would have
  miscounted whenever the store was cold, and an epic-close miscount either
  strands an epic open forever or closes it with children still open.

- **`ks_search` can be scoped to a project partition, and the single-tenancy
  limitation is now documented for the stranger (temperloop#418).** The
  knowledge store is one flat corpus per `$HOME`; its only separation between
  projects is the `<project> - <title>.md` **filename convention**, and search
  did not respect it. For an operator running one machine account across
  several engagements that was a structural confidentiality hole: a query
  typed during client B's session could rank and return client A's
  confidential notes. Two halves land together.
  **(1) The capability.** `ks_search <query> [--limit N] [--partition <name>]`,
  plus a standing `KNOWLEDGE_SEARCH_PARTITION` setting (empty by default) for
  the route a multi-engagement operator actually uses — export once per
  engagement and every call in that session is scoped. A result is returned
  only if its `doc_id` **proves** membership: its basename starts with
  `<name> - `, or the `doc_id` starts with `<name>/`. Matching is exact and
  case-sensitive, and a document matching neither form is **excluded** — a
  confidentiality filter must not return what it cannot attribute.
  **(2) The documentation.** `docs/features/knowledge-store.md` gains a
  stranger-facing **§ Limitations — read this if you work across more than one
  client** naming the exposure in plain terms and both ways to handle it
  (separate `$HOME`s = the only hard boundary; partition-scoped search = the
  convenient one), and `docs/who-its-for.md` points the consultant persona it
  already names at that section.
  **Fail-closed is the load-bearing property**, and it is why this is not
  simply a new flag. The pre-existing argument loops ended in `*) shift ;;` —
  they silently discarded what they did not recognise. Under a *scope* flag
  that is not a degraded result but the exact bleed this closes, delivered
  under a flag that looked like it worked: the full unfiltered corpus, at exit
  0, to a caller that believes it asked for a scoped search. So: `ks_search`
  now parses its **own** arguments against an allowlist and rejects anything
  else with **exit 2** before any backend call (the same shape
  `ks_search_reindex` adopted in temperloop#888); an **empty** `--partition`
  value is rejected rather than read as "no partition"; the scope is
  **consumed at the `ks_search` seam and never forwarded**, so enforcement
  cannot depend on a backend honouring it (both shipped backends now *reject*
  the flag rather than ignore it); the degraded **ripgrep lexical fallback**
  runs through the same single filter point; a filter that cannot run returns
  nothing and **exit 4**, never the unfiltered stream; and
  `ks_search_partition_supported` exists purely so a caller can
  `declare -F`-probe a pre-#418 library — the one skew this file cannot close
  from the inside.
  **Scope, stated plainly rather than half-built:** this is a **search-layer
  filter, not a store-layer partition**. `ks_read` / `ks_write` / `ks_list` /
  `ks_sync` remain unpartitioned — a true multi-tenant store would have to
  reach the doc-id normalizer, every backend in the matrix, and the sync
  capability. It reduces *accidental* exposure through search, the dominant
  and hard-to-avoid failure; it is **not** at-rest isolation, and both the
  contract and the feature doc say so.
  **Classified ADDITIVE (minor), not BREAKING — the argument, explicitly.**
  The documented signature grows an optional flag; every call conforming to
  the previous documented surface (`ks_search <query> [--limit N]`) is
  byte-identical, and with no partition configured — the dominant
  single-tenant case — the whole pipeline including the fallback's trigger
  condition is unchanged (pinned by a no-regression case in the suite). The
  new `KNOWLEDGE_SEARCH_PARTITION` row is a **new setting name no reader
  already depended on**, which `VERSIONING.md` § Setting registry classifies
  as additive. The one genuine behaviour change is that an argument
  `ks_search` never documented now errors instead of being silently dropped —
  the identical judgement temperloop#888 made for `ks_search_reindex` and
  shipped the same way: no overlay using the documented surface must adapt,
  and the prior behaviour on that input was not a contract but an unsafe
  silent discard. No `BREAKING` marker, no migration note owed. Documented in
  `workflows/scripts/lib/knowledge_store.contract.md` § Project partition —
  scoped search; covered by ten new cases in
  `workflows/scripts/lib/tests/test_knowledge_search.sh`, led by a positive
  behavioural sentinel that seeds two partitions and asserts the other
  partition's note is **absent** (a no-op filter fails it).
- **Knowledge-store maintenance scans in the vault-hygiene probe, and a
  grounding-citation backstop anchor in `/tidy` Step 3 (foundation#1479,
  foundation#1478).** `vault_hygiene_report.sh` gains two propose-only
  checks. **`duplicate-overlap`** flags pairs of notes across
  `Decisions/`/`Patterns/`/`Mistakes/`/`Context/` whose titles share
  `DUP_OVERLAP_MIN`+ distinct terms — two pages on one concept that should
  merge or cross-link. It reuses the tokenizer and distinct-token counter
  `check_repeat_mistake` already ships rather than adding a similarity
  engine, and builds an inverted token→notes index instead of comparing note
  pairs, so it does not reintroduce the O(n²) whole-vault cost removed in
  foundation#1202; non-discriminative terms are skipped and the listed pairs
  are capped with an explicit "N not shown" line. **`orphan-note`** reports
  notes with no inbound wikilink anywhere in the store and no `Index.md`
  entry — **informational, never an alarm**, which is a measured choice: 560
  of 744 notes (75%) on the reference vault have no inbound link, so a
  per-note alarm would flag three quarters of the corpus nightly and bury the
  checks that do alarm, making the rate rather than the list the signal. The
  whole-vault walk and backlink index are now **memoized** (`_hyg_all_files`
  / `_hyg_link_index`) and shared by the heat score, orphan scan, and
  duplicate scan, so the two new checks cost no material runtime (measured
  119s vs 121s). `/tidy` Step 3 documents both under § Vault hygiene — and
  records that the third drift class, cross-note contradictions, is
  deliberately **not** rebuilt because § Contradiction detection already
  covers it — and gains a § Missing grounding citations section, the backstop
  anchor an overlay's response-level citation rule registers against. **Not
  breaking:** both checks are additive and propose-only, no existing finding
  changes shape, and a checkout with no vault still no-ops.

- **`ks_search_reindex` forwards `--search` / `--embeddings` to the backend,
  and rejects an unrecognised flag instead of swallowing it
  (temperloop#888).** The reindex seam parsed only `--full` and *silently
  shifted every other argument away*, so the one shape a drift-healing
  scheduled reindex actually wants — `basic-memory reindex --full --search`,
  a full filesystem rescan plus FTS rebuild that reconciles the entity table
  (re-paths moves, drops deletions) **without** the forced full re-embed —
  was unreachable through the public seam. Measured on a 977-note live store
  (foundation#1425, 2026-07-28): `--full --search` = **61s**, bare `--full` =
  **587s**. A caller needing the cheap shape had to reach into the
  library-**private** `_ks_bm_run` behind a `declare -F` probe; it can now
  drop the probe and call `ks_search_reindex --full --search`. Two more
  consequences: the flags are an explicit **allowlist** forwarded by name (not
  a blanket `"$@"`), emitted in a normalized order so the command line is the
  same whichever order the caller passed them; and an **unrecognised**
  argument is now an error — exit 2, the contract's invalid-usage code, with
  the offending argument named on stderr and no backend call made at all —
  where before a mistyped `--full --serch` silently degraded to bare `--full`,
  the 587s forced re-embed instead of the 61s shape the caller asked for, with
  no warning. **No behavior change for existing callers:** a bare
  `ks_search_reindex` and a bare `ks_search_reindex --full` emit exactly the
  command lines they did before. Documented in
  `workflows/scripts/lib/knowledge_store.contract.md` § `ks_search_reindex`
  flags; covered by four new cases in
  `workflows/scripts/lib/tests/test_knowledge_search.sh`.

### Changed — BREAKING

<!-- The `BREAKING` token appears on the `## [0.26.0]` heading above AND on
     this `### Changed` sub-heading, matching the belt-and-suspenders
     convention every other BREAKING release in this file follows.
     `changelog_breaking_sections()` (workflows/scripts/lib/changelog.sh)
     sets its `brk` flag ONLY from a heading line: `$0 ~ /BREAKING/` on the
     `## [x.y.z]` line, or `/^#+ .*BREAKING/` on a sub-heading. BODY TEXT
     NEVER SETS IT. Do not strip either marker when editing history. -->

- **BREAKING — every backend-conditional branch in the board/build caller
  scripts collapses to the issues-only path, and the budget-instrumentation
  probe retargets from GraphQL to REST (temperloop#1121, temperloop#1122;
  epic #524, ADR 0004).** `claim.sh`'s field-resolution pre-check,
  `reconcile.sh`'s conditional field-list widening, closed-issue tail scan,
  and label-hygiene early return, and `release.sh`'s claim-stamp clear guard
  no longer branch on the board's configured backend — each now takes the
  issues-only path unconditionally. The other eight in-scope callers
  (`capture.sh`, `milestone.sh`, `pr-enqueue.sh`, `worklist.sh`,
  `board-mirror.sh`, `ci-poll.sh`, `gate.sh`, `unclaim.sh`) already carried no
  such branch. `gh-bench.sh` and `gh-call-logger.sh`'s header/output framing
  moves from GraphQL-budget to REST/core-budget (the GraphQL figure is kept,
  now informational only), and
  `docs/failure-modes/02-graphql-budget-exhaustion.md` is rewritten and
  renamed to `02-rest-budget-exhaustion.md`. **No observable change on an
  issues-only board** — the collapsed branch was reachable only under
  `backend=projects`, and no registered board runs that: all five have run
  issues-only since 2026-07-18, the soak window ADR 0004 required before this
  removal. **BREAKING for a `backend=projects` adopter:** the code path these
  callers used to take for that backend is gone outright, not merely
  deprioritized. `lib/board.sh` itself is untouched — its Projects-only
  functions (`board_field_id`, `board_option_id`, `board_project_number`,
  `board_add_to_board`) still exist, they are simply no longer reached from
  any of these callers.

### Changed

- **Sub-issue reads in `board-mirror.sh` route through the board adapter
  instead of the raw REST endpoint (temperloop#1119).** temperloop#1030 gave
  `board_sub_issues` / `board_parent_issue` a cached arm, justified by the
  F#988 baseline's heaviest measured read class (the per-issue relationship
  fan-out: 4.1s p50, 12.6s total, against ~500ms for `resolve_item`). Nothing
  in production called them — `board-mirror.sh` read `repos/…/issues/N/sub_issues`
  directly, so the cached arm was exercised only by `gh-bench.sh`, the tool that
  measures it. The epic's largest justified win was unreachable in the running
  system. `_subissue_children` / `_subissue_open_children` now delegate to
  `board_sub_issues` and take a board id rather than a repo (both call sites
  already had one in scope). **The POST link path is deliberately untouched** —
  it is a mutation, not a read, and the adapter exposes no cached arm for it.
  `board-mirror.sh` also gains the `lib/cache.sh` source line: temperloop#1118
  excluded it on the reasoning that it called only the always-live
  `board_resolve_item`, which this change invalidates. Not breaking.

- **The README and the remaining docs surfaces carry the sandbox on-ramp
  (temperloop#1115, temperloop#1133).** `README.md`'s `try` / `--demo` on-ramp
  is replaced by a sandbox + first-epic walk, and that framing is propagated
  across `AGENTS.md`, `bin/README.md`, `docs/pitch.md`,
  `docs/cost-and-autonomy.md`, `docs/features/install-cli.md`, and
  `docs/features/ci-install-tier2.md` so a stranger meets one on-ramp rather
  than two competing ones. Docs only; no contract surface.

### Removed — BREAKING

<!-- The `BREAKING` token appears on the `## [0.26.0]` heading above AND on
     this `### Removed` sub-heading — see the comment on `### Changed —
     BREAKING` above for why both are load-bearing for
     `changelog_breaking_sections()`. Do not strip either one when editing
     history. -->

- **BREAKING — `migrate-board-to-issues.sh` and its fixture-replay test are
  deleted (temperloop#1123; epic #524, ADR 0004).** The dry-run-first
  Projects→issues migration script introduced in v0.14.0 (see that section's
  `### Added`) is gone, along with
  `workflows/scripts/board/tests/test_migrate_board_to_issues.sh`. ADR 0004
  required at least one release of soak between deprecating the Projects-v2
  arm and deleting the tooling that migrates off it; that window closed with
  ten releases behind it and zero live Projects users — every registered
  board has run issues-only since 2026-07-18. **Migration:** complete any
  outstanding Projects→issues migration on **v0.25.0 or earlier** — check out
  that tag (or an earlier one) and run the script from there. Past this
  release there is no script left in the tree to run it with; see
  `### Migration — read this first` above.

### Fixed

- **The issue read cache was unreachable from every board command
  (temperloop#1118).** `board.sh`'s cached read arms gate on
  `declare -F cache_read`, and `board.sh` never sources `cache.sh` itself — a
  deliberate one-way layering that is what keeps `reconcile.sh` permanently on
  the live arm. The consequence went unnoticed for weeks: **no production
  command sourced it**, so `board.<N>.cache=on` was inert everywhere. The axis
  could be turned on and every read would still take the live path, emitting
  one "cache.sh is not sourced" notice per call. `worklist.sh` and
  `pipeline-tick.sh` — the only two real callers of a cache-aware whole-board
  read arm — now source it, guarded on file existence so a consuming repo that
  vendors a subset still runs unchanged. `reconcile.sh` is deliberately still
  **not** wired (a drift detector fed cached data is self-defeating), asserted
  by a negative test. No behavior change with the axis off.
  The accompanying test is the point: the gap survived because the existing
  suite sourced `cache.sh` in its own process, proving the *mechanism* while
  structurally unable to observe whether any command was *wired*. The new
  `test_cache_command_wiring.sh` never sources it, and runs the real command
  against a booby-trapped `gh` that fails if called.

## [0.25.0] - 2026-08-03

### Fixed

- **`doctor.sh` parses again on macOS — and the class that broke it is now
  gated (temperloop#1098).** bash 3.2 (every macOS `/bin/bash`) does not treat
  `#` as starting a comment while it scans for the `)` that closes a
  `$( … )` command substitution, so an apostrophe inside such a comment reads as
  an *opening* quote and swallows the closing paren. A comment added in
  `workflows/scripts/install/doctor.sh` tripped exactly that, and the file was
  **completely unparseable — and therefore the install-verification step
  `temperloop install` itself prints on success
  (`bash <dir>/workflows/scripts/install/doctor.sh`) completely non-functional —
  for every macOS user on `main`**:
  `line 251: unexpected EOF while looking for matching ')'`, plus a bogus
  `line 611: syntax error` that names nothing useful. Reworded to drop the
  apostrophes. A tree-wide sweep found one sibling with the same break
  (`workflows/scripts/board/tests/test_boards_conf.sh`, failing at line 283) and
  one latent near-miss (`scripts/tests/test_stranger_config.sh`, saved only by an
  accidental even apostrophe count); both are fixed too, and **all 330 tracked
  shell scripts now parse clean under bash 3.2.57**.

### Added

- **First-epic Phase-A opt-in for the `tokens` producer — the adopter half of
  the consent answer (temperloop#1088).** `temperloop init` proposes the
  `.temperloop/report.d/tokens` producer in its tree-only proposal PR
  unconditionally and discloses it only afterwards, via the producer's own
  first-run notice (temperloop#986). That notice was built where an
  *interview question* had been asked for: the ratified design brief read the
  operator's phrase "the first epic" as "this epic", and a notice **discloses**
  where a question **consents**. `claude/templates/first-epic-setup.md` now
  carries **§ A4 — Token metering**, authored in the same shape as the existing
  A1/A2/A3 questions: an A0 read-only placement probe prices it three ways
  (place it / keep the one `init` proposed / leave one you wrote alone), the
  question names what is read (your own machine's Claude Code transcript files)
  and that no network call is made, and the answer composes into the Phase B
  change-set — so the producer is **placed on opt-in** rather than placed and
  disclosed. Declining is first-class: nothing is placed, an `init`-placed copy
  of the kernel's shim is *removed* by the same set wherever it sits (an
  unmerged proposal PR **or** the default branch — covering only the first
  would let a PR merged afterwards silently override the decline), an
  adopter-authored producer is left byte-for-byte alone on either answer, and
  nothing else in the epic consumes the producer, so no dangling reference
  survives a decline. Phase C gains a co-level L0 `tokens-producer-disposition` item
  (`kind: spike`, mirroring `ci-disposition`'s reasoning — the file lands as a
  consented change-set write, so a code worker would have nothing to commit and
  would open an empty PR on the decline branch), with its own § Consumes and
  § Acceptance entries. **Two things deliberately unchanged:** `init` stays
  non-interactive (no new prompt on any `init` code path — the interview belongs
  to the first epic and is driven by `/build`), and the producer's first-run
  notice stays unconditional. An interview question, exactly like a prompt,
  reaches only whoever runs the flow; the notice is what reaches the teammate
  who inherits the committed producer by a plain `git pull`. The two are
  complementary halves of one consent answer — adopter half and inheritor half
  — and the template, `docs/features/telemetry.md`, and ADR 0010 each now say so
  explicitly, so a later edit cannot mistake one for a replacement of the other.

- **`scripts/lint-bash32-cmdsubst-comment.sh` — a static lint for the
  hidden-apostrophe class above, plus its regression suite
  (temperloop#1098).** Registered in `scripts/quality-gates.sh` and
  `gate-paths.tsv`. It is deliberately a **textual** lint and not a parser
  invocation, because all three obvious detectors are blind here: `shellcheck`
  exits 0 on the pattern, `bash -n` under bash 5.x exits 0 (the bug was fixed in
  bash 4.0), and although `bash -n` under bash 3.2 *does* catch it, the
  pre-merge leg is ubuntu-only (temperloop#963) where bash 5.2 ships and bash
  3.2 is not installable — so a `bash -n` gate would pass unconditionally and
  read as coverage while never firing. Instead a small shell lexer tracks `$(`
  nesting through quotes, escapes, nested substitutions and here-docs. Two rules,
  for a reason spelled out in the script header: a `#` comment inside `$( … )`
  is **strict** (any apostrophe fails — comments are trivially rewordable, and
  an even-parity pair is only accidentally valid), while a here-doc body is
  **parity**-checked (odd count per region fails), so the LLM-prompt prose in
  `bin/subcommands/try.sh` / `bin/subcommands/configure.sh` is not mangled to
  satisfy a lint. The suite's load-bearing test feeds the lint the real pre-fix
  `doctor.sh` region and requires a non-zero exit — a lint asserted but never
  shown to fire on its known-bad input is the same failure over again — and,
  where a bash 3.x is present, re-measures every fixture against the real parser
  so the recorded BREAKS/PARSES expectations cannot silently rot.

## [0.24.0] - 2026-08-03

### Added

- **`clarification-rework` — a seventh friction-ledger category, so
  communication quality is visible to the self-learning loop
  (temperloop#1089).** The friction ledger's six categories were all
  *mechanical* (re-checked state, acted-before-ground-truth, wrong tool
  contract); the one failure the operator experiences most directly — having to
  stop and ask what the assistant's last message *meant* — was captured by
  `workflows/scripts/drain/lexicon.tsv` (as `trust-rupture`) and then dropped,
  because no consumer adjudicated that subset. `/tidy` § Tooling friction
  (fewer-steps) now takes `trust-rupture` **on user turns** as a third lexicon
  anchor and appends one `clarification-rework` row per genuine re-explanation,
  each carrying the verbatim operator line; the rows participate in the existing
  ≥5-in-14d frequent-stumble tally like any other category, so a recurring
  explanatory habit becomes tracked work. Two discriminations are spec'd
  explicitly: the **correctness-challenge** and **repeat-offence** subsets of
  `trust-rupture` stay with § Feedback memories (temperloop#1090's routing,
  whose "deferred to temperloop#1089 / skip these matches" placeholder is now
  replaced by a live pointer), and a **false-positive floor** bars ordinary
  domain questions — a row is logged only when the confusion is about what the
  assistant itself just said. **Contract-surface note for overlays:** the
  category set is enumerated in the `friction-slug` block of
  `workflows/scripts/drain/lexicon.tsv` (now seven rows) and in
  `claude/measurement-proxies.md` Proxy 2; an overlay carrying its own
  § Tooling friction capture live rule should add the seventh slug there too so
  the live rule and the `/tidy` backstop name the same set. The lexicon
  deliberately does **not** gain a new category — `trust-rupture` stays one
  category discriminated at consumption time, because the tells overlap and only
  the surrounding turn separates them.

- **Machinery-step wall-clock liveness bound — a stalled `/build` machinery
  step is now bounded and disposed, not waited on (temperloop#1071).** A
  `pr-batch` machinery agent was observed running 35,362,333ms — **9h49m** — on
  two tool calls: one Bash invocation blocked and then completed successfully
  (all four steps green, the PR opened). The Bash tool's own `timeout` parameter
  is capped at 600,000ms and `build-level.mjs` asks for less, so that call was
  structurally unreachable — the tool timeout simply did not fire, and nothing
  else bounded it. The root cause is **not** established, so the fix is
  deliberately root-cause-agnostic: a bound that holds regardless of which
  hypothesis is true. `claude/workflows/build-level.mjs` now compiles a per-step
  wall-clock **ceiling into the machinery command text itself** — a `sleep`/`kill`
  watchdog running *inside* the invoked shell (the dependency-free fallback tier
  of `workflows/scripts/lib/portable-timeout.sh`, pipe-leak redirect included),
  independent of and additional to the harness layer that failed. It applies to
  every machinery executor: the `prelude` / `pr-batch` / `ci-batch` batches and
  the solo `gate` / `recover-probe` / `push-retry` calls. A step that outlives the
  ceiling is killed, reports its own `STEP_TIMEOUT` line, and is treated as
  **LOST — never failed and never re-issued**: the driver runs the *existing*
  `pr.sh recover-probe` side-effect ladder (temperloop#939, the same disposal
  seam temperloop#1067 covers for the adjacent lost-return case), **adopts** a PR
  the timed-out step already opened rather than re-opening it, and otherwise
  escalates a legible `machinery-step-timeout` carrying the probe's verdict — so
  no bounded step can double-push or double-open. The observability half: a step
  slower than a second threshold emits a `STEP_SLOW` advisory that the driver
  partitions out of the results array and turns into a `log()` line, so a long
  stall becomes **visible** long before it reaches the ceiling instead of being
  the silent 9h49m the incident was. Both budgets are named settings —
  `BUILD_MACHINERY_STEP_CEILING_SECS` / `BUILD_MACHINERY_STEP_SLOW_SECS` in
  `workflows/scripts/build/build.config.sh` — resolved at `build.md` / `sweep.md`
  / `fix.md` Step 0 and handed in as `input.machineryStepCeilingSecs` /
  `input.machineryStepSlowSecs` on the same orchestrator→workflow seam
  `gateSliceSecs` uses (the Workflow runtime has no shell to source config, and
  no `Date.now()` to measure with — which is exactly why the bound lives in the
  emitted shell). The `.mjs` floors the ceiling at no less than one CI-poll/gate
  slice, so no operator value can manufacture a false timeout on healthy work.

- **`resolved` — a verdict-resolved disposition count on the `command-run`
  telemetry stream, plus the accounting assertion it makes possible
  (temperloop#1084).** `workflows/scripts/emit-command-run.sh` accepted only
  `--merged` and `--parked`, but `/sweep` and `/fix` both define a *third*
  terminal disposition — `resolved (verdict)`, a `kind: spike` closed on its
  verdict — which the record could not express. A 30-item sweep therefore
  emitted `{items_processed:30, merged:27, parked:1}`: two items simply
  unaccounted for, and no way for a reader to tell "resolved by verdict" from
  "silently dropped" or "lost to a crash" — the exact distinction the
  pre-report terminal-state assertion exists to make. New `--resolved <N>` →
  a `resolved` field, and the emitter now asserts
  **`merged + resolved + parked == items_processed`**, exiting **2** with the
  arithmetic named when it doesn't hold — *after* appending the record anyway,
  so an inconsistent record is preserved in the stream rather than dropped (a
  dropped record reopens the absent-stream ambiguity this emitter exists to
  close). Infrastructure failure (no `jq`, an unwritable sink, a malformed
  count) still warns and exits 0, so the emit never blocks its caller. All
  three callers updated: `claude/commands/sweep.md` Step 3.6 stops folding
  verdict resolutions into `--merged`; `claude/commands/fix.md` Step 6.4 gains
  the spike arm; and `claude/commands/triage.md` Step 4.9 gains `--resolved
  <C+D>` for its culled + decision-routed candidates, which had no field at
  all and so under-reported every run that culled anything by exactly the cull
  count. `workflows/scripts/validate-command-run-emit.sh` is extended with a
  **content-derived** check — any command doc whose prose declares the
  `resolved (verdict)` disposition must pass `--resolved`, so a doc that
  *gains* that disposition later is caught without editing the linter — plus
  assertions that the emitter still parses `--resolved` and still carries the
  sum check. New behaviour test at
  `workflows/scripts/tests/test_command_run_emit.sh` (registered in
  `scripts/quality-gates.sh`'s `KERNEL_GATES`), and
  `workflows/scripts/telemetry-brief.sh` Q5 renders the new count.

  **Consumer note — purely additive, so no `schema_version` bump** (per
  `meta/data/raw/README.md`'s convention: a new optional field is not a
  breaking change). But the stream is append-only and is **never backfilled**,
  so ⚠ **an ABSENT `resolved` field on a pre-#1084 record means UNKNOWN, never
  `0`** — that record's `merged` count may silently include verdict-resolved
  items, and the partition invariant does not hold for it. Every record
  written from now on carries the field explicitly, so its absence is a
  reliable pre-#1084 marker; read it with `has("resolved")`, not
  `(.resolved // 0)`, before asserting the invariant or reporting a rate. The
  brief's Q5 row does exactly that, printing "resolved unknown for N pre-#1084
  run(s)" rather than implying those runs resolved nothing.

- **Legacy host-config preflight — a registry-driven gate that asserts a
  removed legacy consumable ON THE HOST, not the repo artifact that merely
  describes it (temperloop#908).** New
  `workflows/scripts/install/legacy-host-preflight.sh`: a small registry of
  `id -> checker-function` rows, one per removed legacy host-config path,
  each checker inspecting host state directly and reporting `ABSENT`
  (never installed on this host — never a failure), `MIGRATED` (present but
  superseded), or `LIVE-UNMIGRATED` (present with no successor — the
  failure case). Wired into `workflows/scripts/install/doctor.sh`'s new
  `check_legacy_host_config()`, so it rides both `make doctor` and
  `temperloop update`'s post-checkout doctor run
  (`bin/subcommands/update.sh`) — the two points a release actually lands
  on an operator's host — and fails the overall exit code on any
  `LIVE-UNMIGRATED` entry. The registry ships two rows covering the two
  instances that motivated it: an installed
  `~/Library/LaunchAgents/com.foundation.funnel-cron.plist` still invoking
  the deleted `funnel-cron.sh` stub (foundation#1419 — the repo plist was
  repointed at `pipeline-cron.sh`, but the gate that would have caught the
  installed copy tested the repo file, not the host); and a legacy
  `$XDG_CONFIG_HOME/foundation/boards.conf` with no
  `$XDG_CONFIG_HOME/temperloop/boards.conf` successor in place
  (temperloop#165, v0.19.0 — the failure mode both instances share: a
  pre-removal advisory (`board.sh`'s "NOTE — legacy machine conf … is no
  longer read", `pipeline-cron.sh`'s "NOTE: … is deprecated") only fires
  from the deprecated-but-still-working state and disappears once the
  removal actually lands, flipping the failure from noisy-and-working to
  silent-and-wrong at exactly the moment nobody is warned anymore). A
  future removal extends coverage by adding one registry row plus its own
  `legacy_check_<id>` predicate — no other file changes. Demonstrated
  against reconstructed unmigrated fixtures for both instances (not merely
  asserted), plus a regression fixture proving a plist header comment that
  merely *names* the installer script `infra/launchd/install-funnel-cron.sh`
  does not false-positive a migrated plist — see
  `workflows/scripts/tests/test_legacy_host_preflight.sh`, registered in
  `scripts/quality-gates.sh`'s `KERNEL_GATES`.

- **Multiline-safe absence proofs plus red-at-merge-base validation
  (temperloop#944).** A `class: A` absence-asserting `proof:` predicate
  (`! grep -q '<phrase>' <file>`) silently passes on an untouched tree the
  moment the target phrase line-wraps — grep is strictly line-oriented, so a
  wrapped phrase can never match and the negated grep reads Pass whether or
  not the removal happened (demonstrated live: `! grep -q 'batched draft is
  still fine' claude/commands/workshop.md`, temperloop#930, passed on
  `main@f41a93a` before any work, because the phrase wrapped across lines
  386/387). Two fixes, both landed: (1) `plan-schema.md` § activation now
  documents the verified-portable, wrap-immune idiom — `! tr '\n' ' ' <
  <file> | tr -s ' ' | grep -q '<phrase>'` — for authoring an absence proof;
  (2) `build.md` § 3e.6 now runs any absence-asserting `proof:` against the
  item's merge-base first and fails the item
  (`absence-proof-vacuous-at-merge-base`) if it already passes there — a
  proof green before the work happened is by definition not proving the
  work. No code/schema changes; both fixes are prose-contract updates to
  `claude/commands/build.md` and `claude/plan-schema.md`.

- **`scripts/quality-gates.sh` gains an opt-in full per-gate wall-clock
  publication (temperloop#968, first deliverable only — a measurement, not a
  matrix/branch-protection change): `QUALITY_GATES_STEP_SUMMARY=1` appends
  every gate's own measured seconds (already tracked internally by the
  bounded-concurrency pool, temperloop#1025) as a Markdown table to
  `$GITHUB_STEP_SUMMARY`. Off by default and never set by `ci.yml`'s
  merge-gating `checks` job, so the leg that gates `main` is byte-identical.
  `.github/workflows/nightly-macos.yml` sets it on both its existing macOS
  job and a new, non-gating `ubuntu-timing` job (same script, `ubuntu-latest`
  — the runner `checks` already uses) so a night's macOS and ubuntu per-gate
  breakdowns land in the same workflow run's summary page, directly
  comparable, letting a future slowdown be localised to specific gates
  instead of attributed to "macOS is slow". `ubuntu-timing` produces no
  `checks (...)`-shaped status context and is not required by branch
  protection.

- **`scan_stub.py` emits `stub.model` in the scan report (temperloop#761),**
  satisfying two downstream contracts that already documented it:
  `findings-schema.md`'s `subject_model` ("taken from the stub's `model:`
  field (`report.stub.model`)") and `tidy.md`'s vault-provenance
  `source_model` stamp. Read from the stub frontmatter's `model:` line
  (written by the SessionEnd hook). The `model` key is now **always present**
  on `report.stub` — present-case: the frontmatter value; absent-case: an
  explicit `null`, never an omitted key or empty string — so a genuinely-
  absent model and a never-emitted field can no longer look identical
  downstream. `scan-report-schema.md` documents the new field; both the
  present and absent cases are covered by
  `workflows/scripts/drain/tests/test_scan_stub.sh`.

- **`scan_stub.py` gains two soft-error signatures (temperloop#770), promoted
  from the candidate-tells surface: `Unknown JSON field` (a `gh --json` query
  naming a field the installed `gh` rejects — the query "succeeds" at the
  shell level while the wrong branch is silently taken; recurred twice on
  2026-07-25, temperloop#762) is a straight addition to `_ERROR_SIGNATURES`.
  `has been denied` (a Bash permission-policy denial of a command a command
  SPEC requires — two consecutive drains hit this on `/tidy`'s `gh pr list`
  archive-PR check, temperloop#763) is a new structural detector instead: an
  isolated denial is noise, so it is gated by a cross-run same-command dedup
  guard — a small on-disk JSON state file (default under
  `${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/`, overridable via
  `$SCAN_STUB_DENIED_STATE_PATH` or `--denied-state`) — and only promotes a
  command to a finding once the same command text has been denied across two
  or more distinct sessions. The scan report schema gains a new
  `tool_events.repeated_denials[]` bucket
  (`workflows/scripts/drain/scan-report-schema.md`) for these findings; both
  signatures are covered by `workflows/scripts/drain/tests/test_scan_stub.sh`.

- **`make doctor` gains a CROSS-checkout install-source split check
  (temperloop#777), the counterpart to temperloop#774's within-checkout
  plane-A/plane-B knowledge-root comparison.** #774's check is correct and
  stays, but it is scoped to the checkout doctor runs from (it sources
  `build.config.sh` / `knowledge_store.sh` straight out of `$FOUNDATION`) —
  it cannot see `~/.claude` itself resolving into a *different* checkout
  entirely. Live evidence (2026-07-26): after vendoring v0.18.0 into
  `~/dev/foundation`, `readlink -f ~/.claude/hooks/session-start-drain.sh`
  resolved into an unrelated, clean-on-main checkout still pinned to
  v0.17.0 — 25 drain skips in one day, with doctor reporting OK from
  *both* checkouts the entire time (neither was wrong about what it
  measured). The new `check_cross_checkout_split()` resolves the
  representative installed surface
  (`~/.claude/hooks/session-start-drain.sh`) to its real, symlink-resolved
  path, asks git which checkout owns it (`git -C <dir> rev-parse
  --show-toplevel`), and compares that against the checkout doctor is
  running in. A mismatch is reported as `MISMATCH`, naming both real paths
  and both `.kernel-pin` tags (reusing `env-reconcile.sh`'s
  `kernel_pin_tag_of()`, sourced in a subshell so its globals/arg-parse
  never leak into doctor's own). Degrades to `SKIPPED` — never a hard
  failure — when the installed surface doesn't exist yet (a fresh clone
  that hasn't run `make install-claude`) or doesn't resolve into any git
  checkout at all. New regression test
  `workflows/scripts/tests/test_doctor_cross_checkout_split.sh`, covering
  the mismatch-detected, no-mismatch, and absent-surface paths; registered
  in `scripts/quality-gates.sh` and `workflows/scripts/config/gate-paths.tsv`.

- **A consumer-parity shellcheck gate for the synced board file set
  (temperloop#915), closing the SYSTEMIC half of temperloop#905 left open
  after that fix addressed only one file.** `make shellcheck` (the kernel's
  own whole-tree lint) excludes `*/tests/*` and passes `-e SC1091`
  repo-wide — exactly the blind spot stageFind/ssmobile/subsetwiki fall
  into: they vendor `workflows/scripts/board/` verbatim (`make
  sync-*-board`) and lint their whole tree at plain shellcheck defaults, no
  exclusions. On 2026-07-29 the identical SC1091 at
  `test_board_cache.sh:66` was live simultaneously in all three consumers'
  required `checks` while the kernel's own gate stayed green throughout —
  it structurally could not see it. The new gate,
  `workflows/scripts/board-consumer-shellcheck.sh`, reproduces the
  consumer's own command (default severity, no `*/tests/*` exclusion, no
  `-e SC1091`) against the exact synced file set —
  `workflows/scripts/board/**` (top-level scripts, `lib/`, `tests/`, and
  `tests/fixtures/`) — so a finding that would red every vendored
  consumer's `checks` now fails at the source instead. Scoped, not
  whole-tree, so it stays low-noise and never fights `make shellcheck`'s
  existing repo-wide posture (unchanged). Registered in
  `scripts/quality-gates.sh` (`KERNEL_GATES`, sharing `make shellcheck`'s
  serial lane over the pinned-shellcheck cache) and
  `workflows/scripts/config/gate-paths.tsv`. Closing the gap required
  fixing the ~20 files it newly exposed (mostly targeted
  `# shellcheck disable=SC1091` directives above unresolvable `source`
  lines, plus a few pre-existing prose comments that happened to start
  with the literal `# shellcheck ` and were themselves being misparsed as
  directive attempts) — the tree is clean at consumer parity as of this
  change.

- **`scripts/quality-gates.sh --scoped` — a changed-file-scoped run for a
  `/build` item worker's iterative mid-work verification (temperloop#957).**
  Verification was measured at **79% of all item-worker shell wall-clock**
  (10.4h of 13.2h across 141 workers) with gates 85% of that — p90 **122s**,
  max **600s** — because a worker checking a three-file change had no way to
  ask for less than the whole suite. `--scoped` applies temperloop#1024's
  existing selector and `gate-paths.tsv` map to the **local working tree**
  (committed ∪ staged ∪ unstaged ∪ untracked, ignored files excluded) instead
  of a pull-request diff. **Wall-clock only — it saves approximately zero
  tokens**; the API call still happens, it just returns sooner. Nothing about
  the runs that gate `main` changes: the bare, repo-wide invocation — CI's
  `checks` job and `/build` §3e.5's parent-side acceptance gate — is
  byte-identical, and only the flag opts in. Every resolution failure (no base,
  not a checkout, an unmapped path, an `ALL` path, a malformed map) widens to
  the **full** set. A scoped run **names every gate it skipped and why**, twice
  (before the run and beside the verdict), and stamps its verdict line
  `[SCOPED SUBSET — NOT a full-suite pass]` so a one-line grep of a worker's
  log cannot read as a full-suite pass. `gate-paths.tsv` gains an enumerated,
  individually-justified **global-by-nature floor** — capture/backstop pairing,
  cross-file template-reference integrity, prose-budget totals, and
  manifest/registry completeness (contributor manifest, setting registry,
  activation registry, and the gate-path map's own lint) — which now `ALWAYS`
  runs on *every* scoped run, PR-scoped and worker-scoped alike; reports that
  cannot fail on their own findings are deliberately excluded, and the
  exclusion is justified in the map. New gate:
  `scripts/tests/test_quality_gates_scoped.sh`.

- **Two draft ADRs recording the toolkit-provenance design's architectural
  calls (temperloop#1047).** `docs/adr/0021-toolkit-provenance-is-derived-not-declared.md`
  records that whether the running toolkit code matches its release is
  **derived** from git at read time rather than declared as stored state — no
  marker file, no mode flag, no added pin field — so nothing can go stale and
  removal is a pure deletion. `docs/adr/0022-provenance-baseline-is-the-subtree-split.md`
  records that the baseline for a vendoring consumer is the **recorded-versus-
  recomputed subtree split sha**, and that the seemingly-obvious alternative
  (diffing from the commit that last touched `.kernel-pin`) is rejected: the
  update tool writes the pin in a *separate, later* commit and skips it
  entirely on an idempotent re-run, which was shown in a sandbox to report a
  hand-edited tree as unmodified. Both are `Proposed`; accepting them is a
  separate human act. Documents only — no behaviour change, and `docs/adr/*`
  was already claimed in both governance manifests, so no registry edit was
  needed.

- **`temperloop report` now says so when a `tokens` producer's stdout fails
  the headline parse, instead of degrading silently (temperloop#988).** A
  `tokens` drop-in that is present, executable, and exits 0 but whose stdout
  is not exactly one JSON object with a numeric `tokens_spent` field used to
  fall through to the kernel-tier headline with **no line explaining why** —
  the asymmetry temperloop#981 left behind when it added a `notice` channel
  for messages "that must not be silently dropped" while enlarging this mute
  population (checking `jq`'s exit status pulled JSON-plus-trailing-text
  stdout, which previously kept its headline by accident, into the
  falling-back set). `report.sh` now renders one line in the **existing
  per-producer skipped-line channel**, inside that producer's own `--
  report.d/tokens --` block: `skipped -- tokens: stdout did not parse as a
  single JSON object with a numeric tokens_spent field (headline fell back to
  the kernel tier -- not an error; see report.contract.md)`. **Not a
  tightening:** the kernel-tier fallback is byte-identical to before, the run
  still exits 0, and a non-conforming producer is still a legible degradation
  rather than an error. One suppression keeps the common path quiet — stdout
  whose first line already opens with `skipped -- ` (the shape the kernel's
  own shim prints when unresolvable or locally disabled) self-declared
  already, so it gets one skip line, not two. `report.contract.md` §
  "Overlay drop-in contract" / "Headline selection" state the new line and
  its exception.

- **Git stale-branch-guard hook test coverage expanded (temperloop#776,
  refiled from foundation#1138): regression test for the exact shape of
  a subsetwiki incident (18-commit stale branch, silent bypass of the
  guard) and install-verification fixtures.** Investigation of a 2026-07-10
  incident found that subsetwiki's project-level `.claude/settings.json` (a
  valid, intentional declaration skipping global hook re-declaration per
  Claude Code's documented hook-merge semantics) could not shadow the guard's
  global registration. The real root cause was prior to commit fe86e11
  (2026-07-25): the guard's awk parser had no case for `git worktree add -b`
  and silently skipped that branch-creation verb, even though subsetwiki's
  `/build` workflow uses worktree-based branching. The parser gap is already
  closed by an earlier commit in this tree, so this ticket closes the
  remaining **test coverage gap** rather than a logic gap: a fixture
  reproducing the subsetwiki shape (project-level `~/.claude/settings.json`
  declaring only `Edit|Write|MultiEdit` hooks) proves the guard still fires
  there (install-verification leg), and a behind-by-18 fixture reproduces the
  incident's exact behind-count rather than an arbitrary N (explicit regression
  naming the reason string's behind-by-N count, not just ask vs silent). New
  `check_reason()` helper in the test asserts both decision *and* the
  behind-count textually. Upstream: this test surface is outside the kernel
  proper (kernel #49, write-lane guard hook test file — part of the
  test-surface system Travis added, not part of the generic kernel shipped to
  strangers).

- **One-time first-run disclosure and a per-person local disable for the
  `tokens` report producer (temperloop#986).** The producer at
  `.temperloop/report.d/tokens` is a *committed* artifact, so a teammate who
  inherited it by a plain `git pull` never saw an `init` prompt and had no way
  to learn that `temperloop report` reads their own Claude Code transcripts.
  On that person's first run the producer now emits a one-time disclosure
  naming what it reads, that it makes **no network call**, and the exact
  command to switch it off. The disclosure rides the existing `notice` field
  (`report.contract.md`, temperloop#981) rather than a second stdout line, so
  it cannot defeat the `tokens_spent` parse — the headline still renders on
  the run where the notice fires. The disable is a marker file under
  `${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/tokens-producer/`,
  **never a committed file**: a committed dismissal would silently disable the
  producer for every collaborator who clones the repo, and a bare env var
  would vanish between shells, so a cron tick or a second terminal would
  re-read transcripts anyway. Note the marker carries **no repo component** —
  it is global to you on this machine, so disabling it in one repo disables it
  in every adopted repo on that machine. A disabled run degrades through the
  ordinary `skip()` path, so only the *headline* matches an absent producer;
  the `-- report.d/tokens --` block itself still appears, carrying the skip
  line. See `docs/features/telemetry.md` § First-run notice and local disable.

- **`/build` merges each clean-disjoint PR as it goes green, instead of parking
  every item until the level boundary (temperloop#1026).** New Step 3h.5 in
  `claude/commands/build.md`, governed by the new `BUILD_MERGE_AS_YOU_GO`
  setting (`build.config.sh`, default on; `0` restores pure level batching).
  Measured motivation: three PRs opened together took 68/69/145 min
  open-to-merge against 10–33 min for solo PRs — level batching converted
  within-level parallelism into a merge-queue pileup. **Scoped, not a
  loosening:** eligibility reuses the *existing* Step-4a regime partition and
  is strictly narrower than it — the item's own `gate.sh risk` verdict must be
  clean, and it must be path-disjoint from every non-terminal sibling in its
  level, where a sibling that has not pushed yet counts as UNKNOWN and
  therefore *not* disjoint. Anything else parks `[m]` for the unchanged
  level-boundary gate, and a risky / structurally-overlapping set still
  hard-blocks modally there byte-identically to before. Consent does not move:
  an eligible item is a clean-disjoint set of one and takes the existing 4b
  timed/headless consent path, recording the same `## Merge gate log` line. The
  level boundary remains a dependency barrier for *starting* the next level.
  Because each as-you-go merge is its own invocation of `gate.sh queue`/`gate.sh
  managed-merge`, the stale-base re-validation now runs **per merge** rather
  than once per level — which is what an early merge moving the base under its
  still-open siblings requires. **New plan-note sentinel `[>]`** (merging
  as-you-go: consent recorded, merge issued, awaiting confirmed `MERGED`) —
  additive, deliberately *not* a repurposing of `[m]`, which keeps its
  "parked, awaiting consent" meaning. `plan.sh writeback` accepts it in
  bracketed and bare-char form; `plan-schema.md`, `presentation-plane.md`,
  `docs/architecture.md`, `docs/features/build-machinery.md`, and
  `docs/features/merge-gate.md` are reconciled. No existing sentinel's bytes,
  meaning, or parse changes, so an in-flight plan note written by an older
  kernel resumes unaffected.

- **Diff-scoped CI gate selection — a `pull_request` run of
  `scripts/quality-gates.sh` now executes only the suites its changed paths can
  affect (temperloop#1024).** The `checks` job ran the whole ~110-gate set on
  every `pull_request` and again on `merge_group` — ~5.5 min flat (measured
  2026-08-02 across the last 20 runs), so every merged PR paid >=11 min of CI
  even for a one-file docs change. A new registry,
  `workflows/scripts/config/gate-paths.tsv`, maps each gate to the path globs
  that reach it; `workflows/scripts/lib/gate-selection.sh` (sourced by
  `quality-gates.sh`, the same seam as `gate-retry.sh` /
  `checkout-freshness.sh`) narrows the run accordingly. A docs-only diff now
  selects 12 of 112 gates.
  **Nothing about what gates `main` changes:** scoping applies to the
  `pull_request` event ONLY, so `merge_group` — the run a PR must clear to
  merge — `push: main`, the nightly macOS leg, and `/build`'s 3e.5 acceptance
  gate all still run the full set. The required status-check context
  `checks (ubuntu-latest)` is unchanged (same job, same single-entry matrix,
  same one `run:` step); `.github/workflows/ci.yml`'s header now documents the
  by-event arrangement. The base SHA is REUSED from the existing
  `LEAK_GUARD_BASE` export rather than derived a second way.
  Against the silent-green class the map could otherwise reopen, every
  degradation resolves toward MORE coverage: an unrecognised changed path, an
  unresolvable base, an empty diff, or a missing/malformed map all fall back to
  the full set (announced, never silent); an explicit `ALL` row escalates
  outright for paths whose blast radius is the gate machinery itself; and a
  gate with no row runs unconditionally. The map ships its own gate,
  `workflows/scripts/config/check-gate-paths.sh`, which fails the build on a
  gate with no row, a row naming a gate that no longer exists, a literal path
  not in the tree, or — the load-bearing one — a row whose globs match no
  tracked path, i.e. a gate orphaned behind an unmatchable glob that would
  otherwise be skipped on every scoped run forever. Validator and selector
  share ONE glob matcher, so what is validated is byte-for-byte what is
  consumed. New settings: `QUALITY_GATES_SCOPE` (`auto`|`full`|`diff`) plus the
  `GATE_PATHS_*` fixture seams; new `--list-selected` flag prints the set an
  invocation would run, with its reason, without running it.
- **`scripts/quality-gates.sh` now runs its gate set through a bounded worker
  pool instead of one gate at a time (temperloop#1025).** The set is ~109
  *independent* suites and the `checks` job's ~5.5 min wall time was almost
  entirely that serialization — the measured baseline has no dominant gate
  (`test-try` 56s, `test-build` 55s, the whole-tree shell lint 29s,
  `test-board` 21s, prose budget ~20s, then a long tail of 1–5s suites), so
  only concurrency could recover it. New sourced lib
  `workflows/scripts/lib/gate-pool.sh` owns the scheduling; the new
  `QUALITY_GATES_JOBS` setting sets the width (`auto` = detected cores,
  clamped; `1` restores the exact pre-parallel serial loop for bisecting a
  gate or hunting an order-dependent flake). Unchanged by design: the gate
  **list**, the pass/fail **semantics** (every gate runs, every failure is
  collected, the run exits non-zero iff one failed), the **log shape** (each
  gate's output replayed whole, in list order, under the same
  `=== <gate> ===` header), and the **CI job** — this is a within-job pool,
  *not* a build matrix, because a matrix would rename and multiply the
  required `checks (ubuntu-latest)` status context and silently un-gate the
  branch. Exit-code integrity is fail-closed throughout: each child reports
  its verdict over two independent channels that must agree, a missing or
  disagreeing verdict is recorded as a **failure**, the parent asserts it
  recorded one verdict per gate handed in, completion markers are published
  from the child's `EXIT` trap so an abruptly-dying worker cannot wedge the
  run, and a scheduler that cannot allocate its scratch falls back — out loud
  — to the always-correct serial loop. Three gates that contend over one
  shared mutable resource (`make shellcheck` /
  `scripts/tests/test_ensure_shellcheck.sh` over the pinned-shellcheck cache,
  and `make docs` over the tree it rebuilds) are pinned to a dedicated serial
  lane that keeps them mutually exclusive with each other while still
  overlapping the pool; the shared-state audit behind that list is recorded in
  `docs/features/quality-gates.md` § Parallel execution. The auto-width cap is
  set at a **measured** knee rather than a guessed one: on a 10-core machine
  width 8 was both slower (176s vs 162s) *and* flakier (three gates failed
  their first attempt and only passed on retry, versus none at width 4), so
  oversubscription costs speed and correctness signal together. That audit also
  surfaced a pre-existing latent defect in the test suites themselves — the
  `echo "$x" | grep -q P` shape under `set -o pipefail` returns 141 when the
  writer loses a `SIGPIPE` race, which is invisible on an idle machine and
  ~5% likely at width 8 — documented but deliberately **not** papered over by
  the retry machinery; it is widespread (596 sites across 77 files) and is its
  own item. The pool forks each gate **under job control** (`set -m`), which is
  load-bearing rather than cosmetic: with job control off, bash sets `SIGINT`
  and `SIGQUIT` to `SIG_IGN` in an asynchronous child and hard-ignores them, so
  the disposition is inherited through `fork` *and* `exec` by the gate's whole
  process tree and cannot be reset from inside it. That silently turned
  `workflows/scripts/probe/tests/test_gh_call_logger.sh`'s `kill -INT $$`
  fixture into a no-op and failed `make test-conventions-probe` on a suite that
  is green serially — the one *observable* instance of the broader invariant a
  parallel run must hold, that a gate sees the same process environment it did
  in the foreground. Two deliberate consequences: each child now leads its own
  process group, so the cleanup trap kills the child's **group** and reaps the
  `make` subtree an interrupted run used to orphan; and a child's stdin is
  pinned to `/dev/null`, since a background process group that read the
  terminal would be stopped by `SIGTTIN` and wedge the poll.
- `scripts/tests/test_quality_gates_parallel.sh`, registered in the kernel gate
  set: covers exit-code integrity (a failing gate still returns non-zero and is
  attributed correctly; a verdict-less or abruptly-dying worker is recorded as
  a failure, never a pass, and never hangs the run), list-order replay, the
  serial lane's mutual exclusion, the slow-dispatch hint, real concurrency, the
  jobs-resolution degradations, the unchanged execution environment (a gate
  still observes the default `SIGINT` disposition, and the pool leaves the
  caller's own `set -m` state alone), and the wiring — including that CI is
  still a single non-matrix job.
- The pool **composes with the sliced execution seam** (temperloop#1021) by
  selection: the slice window picks the run set and the pool is handed exactly
  that array, with the soft budget checked between **chunks** of
  `QUALITY_GATES_JOBS` rather than between individual gates. A partial run
  therefore still stops on a gate boundary and still resumes at a whole number
  of gates in, while an unbudgeted run (CI, `make quality-gates`, a human run)
  stays a single full-overlap chunk. Chunking was chosen over giving the pool
  its own deadline specifically to avoid relaxing its fail-closed *one verdict
  per gate handed in* assertion to *per gate dispatched* — the check standing
  between a silently-dropped gate and a green CI run. Landing this also closed
  a latent hole in `scripts/tests/test_quality_gates_slice.sh`: its fixture
  never copied `gate-pool.sh` into the fake repo, so the `source` failed, every
  `gate_pool_*` call was a `command not found`, and the suite passed while
  exercising **none** of the parallel path it shares a run loop with. The
  fixture now copies the lib, the script announces that degradation instead of
  falling through silently, and two new cases cover the chunked partial and a
  full pooled slice loop.
- **`VERSIONING.md` § Cutting a release — the ordered release procedure
  (temperloop#1015).** The kernel had version *policy* (this file's bump rules)
  and tag *conventions* (`kernel-repo-layout.md` § Release-tag convention) but
  no ordered **procedure**, so the steps were reconstructed from memory each
  cut and some were skipped or deferred to the next one. The new section owns
  the steps and their order, referencing the conventions rather than restating
  them: the CHANGELOG-completeness check against merged PRs since the last tag,
  the **one-PR rule** (`main` is protected, so each cut costs a ~11-minute
  merge-queue round-trip — the v0.23.0 cut split a backfill from the version
  bump and paid an extra cycle for it), the heading rewrite plus `VERSION` bump
  in one commit, tagging the merge commit, and downstream propagation via
  `make update-kernel`. Two hazards are called out explicitly because both are
  silent: `changelog_breaking_sections()` sets its flag **only from a heading
  line**, so rewriting `## [Unreleased] — BREAKING` into a bare
  `## [x.y.z] - <date>` drops the release's breaking signal and makes both
  `update-kernel`'s acknowledgment gate and `temperloop update`'s warning no-op;
  and `## [Unreleased] — BREAKING` occurs more than once in this file (the live
  heading plus historical body prose), so a `replace_all` edit rewrites history.
  `kernel-repo-layout.md` § Release-tag convention gains a pointer to the new
  section. Documentation only — no behavior, no gate, no contract surface moves.
- `GATE_RETRY_BACKOFF`, `GATE_DETERMINISTIC_PATTERN` and
  `CI_POLL_API_DETERMINISTIC_PATTERN` settings, plus
  `workflows/scripts/build/build.config.sh` declarations for the existing
  `GATE_MAX_ATTEMPTS` / `CI_POLL_API_MAX_ATTEMPTS` /
  `CI_POLL_API_RETRY_BACKOFF` caps, so every retry bound in the gate and
  CI-poll machinery has one operator-facing home (temperloop#976). The
  consuming scripts keep byte-identical layer-6 fallbacks, so a repo that never
  sources `build.config.sh` behaves exactly as before.
- `scripts/tests/test_quality_gates_retry.sh`, registered in the kernel gate
  set: covers the cap, both classifiers, the backoff actually spacing attempts,
  and the wiring between `quality-gates.sh` and the new lib.
- **`docs/model-fanout-inventory.md` — every model-spawning site in the repo,
  each classified as explicit setting / justified inherit / silent inherit
  (temperloop#978).** The complement to temperloop#972, which wired levers at
  four *known* sites: this enumerates the seats nobody had listed. The find was
  three headless `claude -p` seats under `bin/subcommands/` that spawned with
  **no `--model` flag at all**, so each ran on whatever tier the invoking
  operator's CLI defaults to — the top tier, on a stranger's very first
  command. Each now names a setting whose default lives only in
  `build.config.sh` and is registered in `setting-registry.tsv`:
  `TRY_TRIAGE_MODEL` (`try.sh` Step 3 shadow triage), `TRY_DEMO_FIX_MODEL`
  (`try.sh --demo`'s live fix call) and `CONFIGURE_AI_MODEL` (`configure.sh`'s
  AI-guided suggestions). The doc also adopts **whole-job accounting** as the
  standing decision rule for any re-tier — a cheaper tier stays only if
  job-*including-repairs* beats the strong tier — and records the measurement
  gap rather than working around it: all three seats pass
  `--no-session-persistence`, so they write no transcript and the
  `.temperloop/report.d/tokens` producer structurally cannot see them.

### Changed

- **`/build`'s worker return value is now SIZE-bounded, not just
  shape-validated (temperloop#1080).** The worker verdict's shape has always
  been machine-enforced (`WORKER_VERDICT_SCHEMA`), but a JSON schema cannot
  bound a string's length, so its two free-prose slots were bounded by nothing.
  Measured across **83 real worker verdicts** recovered from subagent
  transcripts, `summary` ran to a median 119 words (max 557) against a spec
  asking for "1-3 sentences", and each `acceptance_results[].evidence` to a
  median 33 words (max 244) against a spec asking for "`file:line` or test
  name" — every word an output token (the weight-5 class) that the orchestrator
  then ingests. `claude/workflows/build-level.mjs`'s shared `workerPrompt()`
  now carries an `## Output shape` section stating both bounds and banning
  process narration outright, and the verdict schema's free-prose fields carry
  `description`s fixing what each slot is *for* (`evidence` is a **pointer**,
  not the argument). The bounds are the new named settings
  **`BUILD_WORKER_SUMMARY_MAX_WORDS`** / **`BUILD_WORKER_EVIDENCE_MAX_WORDS`**
  in `workflows/scripts/build/build.config.sh` (registered in
  `setting-registry.tsv`), resolved at `build.md` Step 0 item 6 and handed in
  as `input.workerSummaryMaxWords` / `input.workerEvidenceMaxWords` on the same
  seam `gateSliceSecs` uses — with in-file `.mjs` defaults, so `/sweep` and
  `/fix`, which do not resolve the settings, still inherit the bounded prompt.
  **Not information loss:** the worker already writes its full argument to
  `.build-verification.md`, which `pr.sh` splices into the PR body's
  `## Verification` section *by path*, so bounding the verdict moves prose off
  the expensive path rather than deleting it. A projected shrink of ~42% on the
  median verdict and ~75% on the largest observed one, with every reviewer-
  facing fact preserved. New static lockstep guards in
  `workflows/scripts/build/tests/test_workflow.sh` pin the prompt section, the
  narration ban, the interpolated (never hardcoded) bounds, and `build.md`
  §3c's matching prose.

- **`claude/commands/workshop.md` trimmed by a subtraction pass, and
  `PROSE_BUDGET_TIER2_FILE_CAP` lowered 1186 → 1100 (temperloop#956).**
  `workshop.md` had become the largest tracked kernel doc and had funded
  **three** raises of the uniform tier-2 cap in a single day (temperloop#925,
  #947, #954) — and because the cap is one value across all 42 tracked docs,
  each raise loosened the budget for every other doc purely to fund one file.
  This reverses that erosion: 1181 → 1041 lines (−11.9%) by consolidation and
  removal of restatement, never by deleting specified behavior — every step,
  sub-step, gate, disposition, and named rule the file specified before is
  still specified, and all 18 citation markers (`W.1`–`W.18`) survive
  unchanged. The repeated `vault_patch` frontmatter-scalar warning is now
  stated once and cross-referenced; the Failure-modes section is a one-line
  index back into each step rather than a second full restatement. The
  load-bearing `§ Step 2 — Coverage walk` heading — cited **by name** from
  `tidy.md`'s capture/backstop registry row (temperloop#933) — survives
  verbatim. The cap is reseeded to `build.md`'s current 1100 lines, the same
  zero-headroom convention it was originally seeded with, so the ratchet has
  now moved **down** for the first time.

- **The basic-memory config written by `ks_search` now carries
  `semantic_embedding_dimensions` alongside `semantic_embedding_model`, as one
  coupled setting (temperloop#907).** `_ks_bm_ensure_config` pinned the
  embedding model but left its vector width to basic-memory's default, so a
  future model flip would have written a model/width mismatch — which does not
  error: the index builds, every vector is zero, and every semantic search
  quietly returns nothing. The pair now has a single definition site: the model
  is authored once (`_ks_bm_embedding_model`) and the width is *derived* from
  it through a model→width table (`_ks_bm_embedding_dimensions`, `384` for the
  pinned `bge-small-en-v1.5`), which fails loudly rather than guessing for a
  model it has no width for. Setting one without the other is therefore
  unrepresentable, not merely discouraged. The write-once early return on an
  existing `config.json` is unchanged — an already-written config is still
  never touched, so this affects only freshly-created state dirs.
  `knowledge_store.contract.md` posture point 7 documents the coupling.

- **The `tokens` report producer now RESOLVES checkouts whose encoded path
  exceeds Claude Code's 200-character project-name cap, instead of degrading
  to machine-wide (temperloop#995).** Claude Code stores such a project under
  its first 200 encoded characters plus a `-<hash>` suffix that shell cannot
  reproduce, so since temperloop#983 those checkouts fell back to the
  machine-wide corpus under an honestly-labeled notice — correct, but never
  scoped. The producer now takes the same route Claude Code's own reverse
  lookup takes: it globs
  `$HOME/.claude/projects/<first-200-chars-of-encoded>-*` and scopes to the
  match. This is **not** the ambiguous reverse-decode the producer still
  refuses — the prefix is forward-encoded from a path it already knows (git's
  own toplevel); only the hash tail is unknown, and the tail is never guessed.
  **Exactly one match is scoped**; zero matches, or more than one (two
  checkouts identical across their first 200 encoded characters), still
  degrade to machine-wide rather than picking one — under a notice that now
  names the prefix **glob** it searched and says which of the two happened, so
  the operator can paste it straight into an `ls`. A successful prefix
  resolution says so in its own notice too, so a surprising number is
  attributable to the route that produced it. Five notice variants now, not
  four; see `workflows/scripts/lib/report.contract.md` § Kernel-shipped
  `tokens` producer's transcript scope.

- **`temperloop try`'s shadow-triage pass now runs on an explicitly cheaper
  tier by default (temperloop#978).** `TRY_TRIAGE_MODEL` defaults to a cheap
  tier rather than inheriting the operator's CLI default. This is the one seat
  of the three that is re-tiered, and the choice is measured rather than
  assumed: the pass emits free-form text the script prints verbatim, so there
  is no JSON contract to violate and no downstream parse a weaker model can
  fail; it is a zero-write dry run; and it is a stranger's *first* command,
  billed to the stranger's own account. Whole-job measurement: a valid,
  correctly-prefixed report 2/2 with no repair path invoked, ~5.5x cheaper per
  call in dollars. Stated honestly — the cost-*weighted*-unit delta is within
  noise on n=2, because the cheap tier is chattier and output carries the
  heavier weight, so the win is claimed on the dollar axis only. Set
  `TRY_TRIAGE_MODEL` to empty to restore the previous inherit behavior. The
  other two seats (`TRY_DEMO_FIX_MODEL`, `CONFIGURE_AI_MODEL`) keep inheriting
  and now carry a written justification instead of an accident —
  `configure.sh` in particular was measured and **refused**: the cheap tier is
  ~2.4x cheaper per seat but fenced its JSON on 4 of 4 runs, which makes `jq`
  exit 5 and silently drops every setting to the plain-prompt fallback. 2.4x
  cheaper, 0% of the job — the exact inversion whole-job accounting exists to
  catch, and one per-seat accounting would have scored a win.
- **Retry loops in `/build`'s gate and CI-poll machinery now classify before
  they retry, and back off between the retries that remain** (temperloop#976,
  with `Towheads/foundation#1297`). Re-running a *deterministically* failing
  operation cannot change its outcome; the live case was `/build`'s acceptance
  gate re-running a failing `shellcheck` three times before an operator
  intervened. Two loops changed:
  - `scripts/quality-gates.sh` — the per-gate retry policy moved into a new
    sourced lib, `workflows/scripts/lib/gate-retry.sh`, which now (a) fails a
    gate fast, with **no** retry, when its output matches
    `GATE_DETERMINISTIC_PATTERN` (a static-lint finding signature); (b)
    short-circuits any gate whose failure output is **byte-identical** to its
    previous failed attempt, capping every deterministic gate at two attempts
    regardless of what it prints; and (c) spaces the retries that *do* fire by
    a graduated `GATE_RETRY_BACKOFF`-per-attempt sleep, instead of firing the
    whole budget back-to-back too fast to outlast any real transient. Every
    short-circuit is logged per-attempt and summarised beside the verdict.
  - `workflows/scripts/build/ci-poll.sh` — `gh_retry()` now inspects a failure
    before spending an attempt on it. One matching
    `CI_POLL_API_DETERMINISTIC_PATTERN` (a permanent HTTP 4xx / auth / argument
    error; HTTP 429 is deliberately excluded, being transient) dies immediately
    with a new `deterministic_failure: true` field rather than retrying. The
    closed `.outcome` set is unchanged.

  No default's value changed, and `GATE_MAX_ATTEMPTS=1` still disables gate
  retries entirely. `claude/workflows/build-level.mjs` gained a documented
  retry-loop inventory beside its budgets — each loop's cap plus either its
  classification step or a stated reason none applies — and
  `workflows/scripts/build/gate.sh` records the same for its single
  mergeability re-poll.

- **A `checks` gate now requires a `## [Unreleased]` entry from any change
  that touches contract surface (temperloop#960).**
  `workflows/scripts/check-changelog-entry.sh`, registered in
  `scripts/quality-gates.sh`'s `KERNEL_GATES`, fails a change that edits a
  contract-surface path but adds nothing under `## [Unreleased]`. This closes
  a hole in the pre-1.0 breaking signal rather than a tidiness gap: the
  downstream acknowledgment gate in `scripts/update-kernel.sh` /
  `bin/subcommands/update.sh` decides whether a pull needs an explicit
  `KERNEL_ALLOW_BREAKING=1` by scanning the CHANGELOG range for a `BREAKING`
  marker, and an entry that was never written cannot carry one — so a breaking
  change merged without a CHANGELOG entry shipped with that gate silently
  passing. At the v0.22.0 cut, 1 of 14 merged PRs had touched `CHANGELOG.md`.
  - **"Contract surface" is not defined twice.** The gate parses the
    backticked paths out of `VERSIONING.md` § The contract surface's own
    "Where it lives" column at run time, so adding a row there extends the
    gate for free; a table it cannot parse fails the run loudly rather than
    silently enforcing nothing. `VERSIONING.md` now says so beside the table.
  - **Opting out is explicit and reason-bearing, never inferred.** A
    genuinely non-shipping change opts out with the `no-changelog` PR label,
    a `Changelog: none - <reason>` line in the PR body, or that same line as
    a commit-message trailer (the channel that works before a PR exists and
    inside a merge queue). The reason is required — the point is that a skip
    is a recorded choice.
  - **Where it runs.** Inside the existing required `checks` job, never a
    second required status. In CI it enforces on the `pull_request` event
    only and prints a legible skip on `merge_group`/`push`, because the
    opt-out channels are absent from those payloads. With no resolvable diff
    base, or in a tree carrying no `VERSIONING.md`/`CHANGELOG.md`, it skips
    cleanly with a notice.
- **`workflows/scripts/lib/changelog.sh` gains `changelog_unreleased_body()`
  and `changelog_version_headings()`** — the Unreleased-section body
  extractor and the version-heading lister the gate above diffs across a
  change's merge-base and head (the latter is what lets a release cut, which
  legitimately empties `## [Unreleased]`, pass without an opt-out). Additive:
  the three existing helpers are untouched.
- **Six `CHANGELOG_GATE_*` rows in
  `workflows/scripts/config/setting-registry.tsv`** for the new gate's
  seams (`CHANGELOG_GATE_ROOT`, `_HEAD`, `_BASE`, `_PR_BODY`, `_PR_LABELS`,
  `_SKIP_LABEL`). New rows only — no column change, no existing default
  moved.

### Changed

<!-- Non-breaking changes only. The `### Changed — BREAKING` section below is
     the one `changelog_breaking_sections()` keys on; do NOT merge these two
     sections, and do NOT add ` — BREAKING` to this heading for a change that
     is not breaking. -->

- **`/build`'s machinery executors now run as a Bash-only `machinery-executor`
  agent instead of `general-purpose` (temperloop#1014).** temperloop#997 removed
  the prompt-cache TTL misses from the *worker*; the waste relocated to the
  mechanical agents that exceed the ~300s TTL **by construction** — the CI poll
  (waiting is its whole job) and the minutes-scale 3e.5 gate. Their post-wait
  call re-*writes* the whole context at weight 1.25 instead of re-*reading* it at
  0.1, so the excess is proportional to **context size**, not to the length of
  the wait. The new `claude/agents/machinery-executor.md` carries a Bash-only
  tool surface and the standing "run it verbatim, return each step's JSON line"
  contract the per-call prompt used to restate. Measured first-call
  `cache_creation`, same prompts and machine: **37,428 → 30,856** tokens for a
  CI-poll batch and **37,201 → 30,734** for the 3e.5 gate (−17.5%; −56% of the
  context that is not the installed CLAUDE.md, which the harness injects into
  every non-built-in agent and no agent definition can decline). Behavior is
  unchanged — same commands, same JSON, same Bash-tool timeout, same escalation
  branches — and a checkout that has not run
  `workflows/scripts/install/project-agents.sh` falls back automatically, once
  per run, to the previous `general-purpose` executor with its full prompt.

### Fixed

- **The `trust-rupture` lexicon category now has a named `/tidy` consumer
  (temperloop#1090).** `workflows/scripts/drain/lexicon.tsv`'s largest
  user-turn category — 19 patterns for user pushback and expressed doubt — was
  fully wired on the *extraction* side (declared in the header, allowlisted in
  `validate-lexicon.sh`, emitted into `report.lexicon_matches[]` every run) and
  consumed by nothing: zero hits in `claude/commands/`, and none of its tells
  appeared even implicitly in `tidy.md`'s illustrative lists, so the matches
  were computed and dropped on every drain. `claude/commands/tidy.md`
  § Feedback memories — semantically the right home, but four lines of prose
  with no lexicon anchor at all — now carries the same
  `report.lexicon_matches[]` adjudication instruction its sibling extractors
  have (§ Tooling friction's `friction-slug`/`state-collision`, § Unfiled
  defects' `worked-around-defect`, § Self-correction moments'
  `self-correction`), and routes the category's **three distinct failure
  modes** to distinct destinations: a *correctness challenge* to a
  `feedback_<topic>.md` memory; a *repeat-offence* to that memory **plus** a
  rule-promotion candidate via the existing `feedback` findings record that
  § Recurrence → promotion already tallies; and a *communication failure* —
  the "I don't understand" / "is jargon" subset — explicitly **out of scope
  and deferred to temperloop#1089**, so the two issues never claim the same
  tells. Default-to-silence is preserved (a stub with no pushback produces no
  artifact) and every artifact must carry the verbatim transcript line as
  evidence. Prose-only change to one command spec: no lexicon pattern was
  edited, no new friction-ledger category added, and no capture/backstop
  registry row is needed (the routing targets are all existing artifacts).

- **`build.md`'s five misattributed issue citations now name the right tracker
  (temperloop#733).** Five incident references in `claude/commands/build.md`
  carried a `temperloop#` prefix for issues that live on the **foundation**
  tracker — `#865` (combined-tree pre-check), `#1007` (workflow-reviewer as a
  required gate for `claude/commands/*.md` diffs), `#1150` (merge-queue silent
  dequeues / `diagnose-queue`), `#1241` (non-hermetic §3e.5 gate) and `#1055`
  (machine-local config leak). None of those numbers exist on the kernel
  tracker, so each pointed either nowhere or — as kernel numbering catches up —
  at an unrelated issue, which is the worse failure. Each is now `foundation#N`,
  verified against the live issue's own title rather than assumed; the
  surrounding citation markers already recorded them as `incident:F#…`, so the
  prose and the citation registry now agree. Prose only — no behavior change.

- **`build.md` §3e.5/§3e.6's acceptance-gate exit capture is now dialect-safe
  (temperloop#801).** The prior prose named only `${PIPESTATUS[0]}` — a BASH
  array — as the fallback when the gate is piped, but this harness's Bash
  tool executes through **zsh** on macOS, where the equivalent variable is
  `$pipestatus`, lowercase AND 1-indexed; under zsh `${PIPESTATUS[0]}`
  silently expands to the **empty string**, not the gate's exit code. A
  caller following the old prose literally reads that empty value as
  "not a failure" and passes a red gate through — the exact silent-red class
  (temperloop#68 / PR #309) the rule exists to prevent, reintroduced on this
  platform. Both sites now **prefer the un-piped form** (branch on the gate's
  direct exit — dialect-agnostic) and, where piping is unavoidable, name
  **both** `${PIPESTATUS[0]}` (bash) and `${pipestatus[1]}` (zsh) together
  with the platform caveat, rather than one bash-only variable. Cites the
  kernel's existing § Tool invocation discipline rule ("check the platform's
  dialect before leaning on a flag or regex feature"), which already covers
  this class. `claude/workflows/build-level.mjs`'s own §3e.5 invocation was
  checked and needs no change: it captures the gate's exit via a redirect
  (`>gateLog 2>&1`), not a pipe, so its `$?` reaches the gate's own exit
  cleanly on any shell. No other kernel prose site names `${PIPESTATUS[0]}`.

- **`/check-in`'s in-place `Status`-line rewrite now preserves (or restores)
  a pipeline surface's trailing newline (temperloop#853), the agent-plane
  half of foundation#1308 — the store-seam half (`ks_append`'s own
  fresh-line-on-append guarantee in `workflows/scripts/lib/knowledge_store.sh`)
  was already fixed there and stays separate, as recommended during
  `/assess --epic 1324`.** A plain substring `Edit` only touches the bytes
  it matches, so patching a `Status:` line that happened to sit at the
  literal end of the file — routinely true, since the entry being resolved
  is usually the newest, i.e. last, thing appended — left the file exactly
  as unterminated as it started. The next appender then glued its
  `### heading` onto the end of that same line instead of starting a fresh
  one, silently arming an entry no `^### `-anchored scan would ever match
  (observed at `Context/pipeline - pending decisions.md` line 344, written
  by check-in's own rewrite). `claude/commands/check-in.md`'s Part 2
  preamble now requires one cheap, idempotent check after **every**
  `Status`-line `Edit` in the command — `[ -z "$(tail -c1 "<file>")" ] ||
  printf '\n' >> "<file>"` — the same conditional idiom the store seam
  already relies on for the identical byte. Pinned by the new
  `workflows/scripts/tests/test_checkin_status_trailing_newline.sh`
  (registered in `scripts/quality-gates.sh` / `gate-paths.tsv`), which
  reproduces the exact corruption unguarded and proves the guard prevents
  it: restores a missing trailing newline, is a true no-op on an
  already-terminated file, and — composed with a subsequent append — keeps
  the new heading on its own `^### `-matchable line.

- **`temperloop init --no-network` no longer attempts a `git push`
  (temperloop#969).** The flag gated Step 2's first-epic offer and nothing
  else, so a run in a repo with no reachable remote still invoked
  `proposal-pr.sh` at Step 3: it force-created and switched to
  `foundation-init/config`, committed onto it, and only then died on the push
  with a raw `fatal: 'origin' does not appear to be a git repository` — exiting
  non-zero and never reaching the Step 4/5 summary + handoff. A stranger was
  left parked on an unfamiliar branch, with a git error and no recovery
  guidance, by a flag whose name promises the opposite. Step 3 now carries the
  **same `no_network` gate, in the same shape, as the Step 2 offer already
  did**: one `skipped — network disabled (--no-network): no proposal branch, no
  commit, no push, no PR …` line in the kernel degradation-notice form (wording
  aligned with `conventions-probe.sh`'s own network-gated skips), then the run
  continues and prints its summary and handoff normally. The skip is the
  **whole step**, not just the push — `proposal-pr.sh` has no commit-locally-
  but-don't-push mode other than its own `--dry-run`, which still performs a
  real local checkout + commit, so suppressing only the push would have fixed
  the error message while leaving the stranded-branch half of the report
  standing. The run's other network reach, the best-effort base-tip
  `git fetch`, is gated on the same flag for the same reason. **Behaviour
  change to note:** `--no-network` now means what it says end to end, so a
  caller that passed it merely to keep the first-epic offer quiet no longer
  gets a proposal PR — closed stdin (or `--no-first-epic`) is the way to
  suppress the offer alone. `test_init.sh` gains the reproduction as coverage
  (exit 0, neither raw git-push string, the notice, the summary + `next step:`
  marker, original branch and HEAD untouched, no `foundation-init/*` branch,
  zero `pr create` calls) plus two controls: the same skip fires in a repo that
  *does* have a remote, and dropping the flag still opens the PR.

- **`temperloop eject` now also cleans up a stray `foundation-init/*` branch
  on the REMOTE, not only locally (temperloop#967).** `proposal-pr.sh` commits
  and pushes the proposal branch *before* it ever opens the PR, so a run that
  dies at or after the push — a failed `gh pr create`, a killed process —
  could leave the branch sitting on the remote with no PR ever opened to
  record it in `.temperloop/config`'s `installs[]` (that entry is only folded
  in once the PR outcome is known). The `.temperloop/.recovery.json` marker
  `temperloop#414` added already restored the original branch and deleted the
  stray *local* copy on `eject`, but never touched the remote — so a run that
  died after a successful push left a genuinely orphaned branch on the
  adopter's own GitHub repo that no `eject` run would ever remove.
  `restore_original_branch()` now also makes a best-effort `gh api --method
  DELETE .../git/refs/heads/<branch>` attempt against the remote, gated by the
  same `--no-network`/resolved-`gh_repo`/`gh`-availability checks every other
  API-state revert in this script already uses, and never treated as fatal on
  its own (a "nothing there" skip is the common, harmless case — the push
  itself failing, not landing at all). Both `eject.sh`'s own uninstall bullet
  (scope (c)) and `bin/README.md`'s Uninstall table now name this branch
  scope explicitly, local and remote, instead of leaving it implied by "a
  proposal PR." `test_eject.sh` gains an end-to-end repro: a real `init` run
  against a real bare-upstream fixture whose push genuinely lands but whose
  (stubbed) `gh pr create` fails, asserting the branch really is on the
  upstream beforehand and that `eject` reports and calls the remote deletion,
  in addition to the existing local-only recovery coverage.

- **A parked item's claim stamp no longer strands on an open issue —
  `release.sh` clears its own, and `reconcile.sh --labels` sweeps the rest
  (temperloop#979).** On the issues-only backend, parking a claimed item back to
  Ready left a live `fnd:host/session:<host>:<sess8>` label on the open issue,
  and NOTHING swept it: `release.sh` was local-only (no `host/session` or
  backend awareness at all) and `reconcile.sh --labels` classes (g)/(h)/(j) are
  scoped to closed issues or to label objects with zero open-issue attachments —
  so the item read as claimed by a session that is gone while both the release
  path and the reconcile sweep reported success (reproduced on foundation#1483).
  Both halves of the issue's fix landed. **`release.sh`**, when passed BOTH an
  `<issue#>` and `--board <N>`, now also clears that stamp via
  `board_stamp <item> Host/Session ""` — the adapter's one existing clearing
  implementation, never a second label-strip path — behind four deliberate
  guards: issues-only backend, item **not In Progress** (an In-Progress stamp is
  a live claim HELD until Done, K#275 — left in place with a notice), **this
  session's own** stamp only (a foreign stamp is reported and routed to
  `reconcile.sh`, so a peer's in-flight claim — the owner is stamped *before*
  the status flips — can never be erased), and never changing `release.sh`'s
  exit status (a park must never fail on a release; every board-side failure
  degrades to a stderr notice). The board half runs **before** the marker half,
  so neither the expected K#275 non-latest refusal nor an absent marker on a
  headless run can suppress it. Without `--board`, behaviour is byte-identical
  to before — zero `gh` calls — so `/build` 3h's `release.sh <n>` is untouched.
  **`reconcile.sh --labels`** gains class **(m)**: a `fnd:host/session:*` label
  on an OPEN issue whose `fnd:status:*` is not in-progress — reported by
  default, stripped by `--apply`, with the same immediate per-issue re-check
  every other class uses (still open, still labeled, still not In Progress, so a
  re-claim or close landing in the scan→apply gap is never undone). It reuses
  the existing open-issue bulk read (zero extra `gh` calls) and the now-shared
  `_label_reconcile_strip_rows` helper, never deletes the label OBJECT (still
  class (g)'s job), and records its count in the `--unattended`
  pending-decisions entry. This is the more robust half by construction: it
  catches the drift whether or not anyone ran `release.sh`.

- **`/build` now detects the backgrounded-quality-gate stall mechanically and
  auto-resumes the worker on its own worktree (temperloop#993).** A worker that
  ran `scripts/quality-gates.sh` in the background and yielded its turn was
  reaped before the gate finished: it returned real work on disk, ZERO commits
  and no verdict block (observed twice in one run — #982 with 8 modified files,
  #983 with 3). The `#1219` prose clause in the worker prompt is prevention only,
  and prose rots, so it is now paired with a machine check that needs no worker
  cooperation. `pr.sh recover-probe` splits its stage-0 bucket: **`RECOVER_DIRTY`**
  (no verdict, worktree dirty, zero commits, no PR) is now distinguished from
  `RECOVER_NONE` (nothing anywhere), and `dirty` / `dirty_files` ride every probe
  outcome. On `RECOVER_DIRTY`, `build-level.mjs` auto-resumes the item on the
  **same worktree** — the only inheritable context, since the harness has no
  resume-this-agent seam — with the foreground cure plus a dirty-resume note
  naming the uncommitted file count and telling the worker to read
  `git status`/`git diff` and continue from that work rather than rebuild it.
  If the resume still returns no verdict with the tree still dirty, the
  `worker-error` escalation payload carries `shape: "foreground-stall"`,
  `dirty_files` and `worktree`, so the escalation's **skip** option (which prunes
  the worktree) can no longer destroy uncommitted work unseen. `RECOVER_NONE`
  keeps its unchanged one-retry-then-escalate handling.

- **A `/build` acceptance-gate TIMEOUT is no longer reported as a gate FAILURE,
  and the gate's budget is now a named setting rather than a hardcoded literal
  (temperloop#1021).** `claude/workflows/build-level.mjs`'s §3e.5 gate carried a
  single flat `480_000ms` Bash-tool timeout for the whole `scripts/quality-gates.sh`
  suite. Once the gate list outgrew it, every drive on this repo SIGTERM'd the
  suite mid-run and escalated `acceptance-gate-failed` — on a tree whose suite,
  re-run uncapped, was green. Two defects in one: the wasted round-trip, and
  (the dangerous half) an escalation payload that could not be told apart from
  real breakage. **This was a recurrence:** temperloop#115 already raised the
  same number once, `2min → 8min`, for the same failure, and it decayed again —
  so a third raise is the patch already known to fail, and it is not even
  available, since the executor agent's ~10-minute Bash ceiling cannot be
  raised. Three changes. **(1)** A budget-exhausted run gets its own outcomes
  (`GATE_TIMEOUT` / `GATE_SLICE`) and its own escalation kind,
  `acceptance-gate-timeout`, whose payload states that the suite's verdict is
  UNKNOWN; the `runMachinery` executor prompt now names `GATE_TIMEOUT`
  explicitly, so a killed run stops being narrated as the nearest
  failure-shaped outcome. A genuinely red suite still escalates
  `acceptance-gate-failed`, unchanged. **(2)** `scripts/quality-gates.sh` gains
  a SLICED mode (`QUALITY_GATES_START_AT` / `QUALITY_GATES_BUDGET_SECS`, an
  exit-75 partial protocol and `QUALITY_GATES_RESUME_AT=` /
  `QUALITY_GATES_FAILED=` markers): it runs gates until its budget is spent,
  stops cleanly *between* gates, and reports where to resume, so the driver
  loops slices and total suite runtime is no longer bounded by any one Bash
  invocation. Growth therefore can no longer manufacture a false failure — the
  decay path is closed structurally, not deferred to the next raise. **(3)** The
  budget becomes the named setting `BUILD_GATE_SLICE_SECS`, registered in
  `setting-registry.tsv` and handed to the Workflow runtime by `build.md` /
  `fix.md` / `sweep.md` Step 0 as `input.gateSliceSecs` (the same hand-off
  `machinerySoloModel` uses, for the same reason: the Workflow runtime has no
  shell to source `build.config.sh`), clamped so no value can push the derived
  Bash timeout past the agent cap. Green runs now report elapsed time and slice
  count — the decay signal the bare number never had. Backward compatible in
  both directions: the two `quality-gates.sh` knobs are ENV VARS, so a consuming
  repo vendoring an older copy ignores them and runs the whole suite exactly as
  before, and a caller that omits `gateSliceSecs` lands on the `.mjs`'s in-file
  default.
- **`temperloop eject` no longer deletes a hand-authored
  `.temperloop/pricing.json` (temperloop#985).** Previously `eject` removed
  the whole `.temperloop/` directory unconditionally at all three of its
  removal sites (partial-init residue, an empty install manifest, and a
  fully resolved revert) — including a `pricing.json` price table an
  operator maintains by hand for `temperloop report`'s directional dollar
  line, even though nothing in `eject`'s install-manifest model ever
  produced that file. `pricing.json` is now preserved, byte-identical,
  across every one of those three removal paths, and `eject` prints one
  line naming the file it kept; with no `pricing.json` present, behavior is
  unchanged. `temperloop uninstall`'s eject reminder is updated to match —
  it now also names the `report.d/tokens` producer shim (removed by
  `eject`, same as before) and states explicitly that `pricing.json` is not
  among what `eject` removes. See `docs/features/telemetry.md` § Removal
  for the full disposition, including the honest scoping of "no residue" to
  an unmerged proposal PR.

- **`--remote` is validated before it reaches `git` in `temperloop init` and
  the proposal-PR generator (temperloop#996).** `--remote` parsed unvalidated
  in both `bin/subcommands/init.sh` and
  `workflows/scripts/proposal/proposal-pr.sh` and was then spliced into
  `git fetch "$remote" "$base"` as that call's **first positional** — the
  position git parses as an *option* whenever the word begins with `-`. A
  value like `--upload-pack=touch /tmp/PWNED; git-upload-pack` therefore
  EXECUTED at the fetch: the same injection the earlier `--base` guard
  (temperloop#413-era) closed on the *other* argument of the very same
  command, left open on this one. `--remote` is documented CLI surface
  (VERSIONING.md's CLI-surface row) that adopter wrapper scripts and CI jobs
  pass, so the value is not always a human's own keystroke, and downstream
  refusal was not a guard — `proposal-pr.sh` did reject the name, but only
  *after* `init`'s own fetch had already run it. Both scripts now refuse an
  option-shaped or otherwise malformed `--remote` **at parse time**, strictly
  before the first git invocation that consumes it (`init` exits 2;
  `proposal-pr.sh` emits its usual structured `ERROR`). A valid `--remote` is
  unaffected. Tests in both suites assert the *ordering*, not merely the
  refusal: the payload's marker file must never appear and no proposal branch
  may be cut.

- **`proposal-pr.sh` now lands every file it proposes newline-terminated
  (temperloop#992).** Both manifest readers are `$(…)` captures, and command
  substitution strips *every* trailing newline — so a bare `printf '%s'` at
  the single write site wrote each file with **no** final newline, whatever
  the manifest said. An adopter's very first `temperloop init` PR therefore
  showed `\ No newline at end of file` on every file in the diff
  (`.temperloop/config`, `boards.conf`, and — since temperloop#984 —
  `.temperloop/report.d/tokens`): harmless to execution, but the first
  impression the install path makes. The write is now **normalized to exactly
  one** trailing newline, so a `content` of `"a"`, `"a\n"`, or `"a\n\n\n"` all
  land identically and callers neither need nor should hand-append one. Two
  deliberate edges: **empty content still lands as a 0-byte file** rather than
  a lone newline (git reports no missing-newline marker for an empty blob), and
  a source ending in several blank lines has them collapsed to one — which is
  why `init`'s carry-forward line still claims "content and mode preserved"
  rather than "bytes". `NO_CHANGES` is unaffected in mechanism (still
  `git diff --cached --quiet` against the base tree) and strictly better in
  outcome: a base already carrying the correctly-terminated file now compares
  equal instead of manufacturing a one-byte diff on every re-run — asserted
  both ways in `workflows/scripts/proposal/tests/test_proposal_pr.sh`, and
  `test_init.sh`'s landed-shim check is tightened from a newline-stripping
  `$(…)` comparison to a byte-exact `cmp`. **One-time adopter effect:** a repo
  whose files were placed by an earlier `init` sees a one-byte diff per file on
  the next run, adding the newline that should always have been there.

- **`/build` and `plan-schema.md` now state the `<repo-root>` default the SAME
  way — the plan's home repo, never assumed to be the launch checkout
  (temperloop#835).** `build.md` 3b claimed the default was "the plan's own
  checkout (the orchestrator's parent tree)" while `plan-schema.md`'s `repo:`
  field (twice) already read "absent = the plan's home repo" — a genuine
  disagreement, not a wording nit: the parenthetical is only true when
  `/build` happens to run *from* the plan's home checkout, and the live
  incident this fixes (building `Plans/2026-07-27 temperloop - session-start
  context measurement`, epic #810, from a **foundation** session) had to be
  resolved by hand on 2026-07-27 because nothing in the doc said the home
  repo could differ from cwd. `build.md` 3b now drops the parenthetical and
  points at a new Step 0 resolution (folded into the existing board-probe
  item 5, no new numbered step): when the plan frontmatter carries `epic:`,
  `/build` resolves the epic's actual home repo by probing each registered
  board (`board_resolve_item` per board, then `board_repo`), and if it
  differs from the launch checkout's own repo, prints one `NOTE:` at run
  start — the same legibility bar Step 0's build-machinery-staleness check
  already sets. **Not a hard block:** cross-checkout invocation is legitimate
  (a plan can be built from any session) and the existing per-item `repo:`
  honor point (3b) already handles routing an item to a different checkout
  when set.

- **`/build`'s default Workflow path now qualifies a cross-repo item's
  `Closes` line, matching the conversational path (temperloop#852).**
  `claude/workflows/build-level.mjs`'s 3f pr-open call passed an item's
  `gh_issue:`/`also_closes:` numbers to `pr.sh --gh-issue`/`--also-closes`
  **verbatim**, always as bare digits — so an item whose `repo:` field routed
  its PR to a *different* repo than the plan's home (the kernel-classified-item
  case: a foundation-triaged issue, work landing in `Towheads/temperloop`)
  emitted a bare `Closes #N` into that PR. GitHub's `Closes #N` is same-repo
  only, so the home-repo issue never closed — silently, since the PR still
  merged clean. build.md 3f's own "Cross-repo `repo:` honor point" already
  documented the fix (pass the fully-qualified `owner/repo#N` form) for the
  conversational path; the Workflow path just never implemented it. Fixed at
  the one call site that knows both repos: when `item.repo` is set and differs
  from the level's `ownerRepo` (the plan's home repo — where the issue is
  tracked, since `gh_issue:` normally lives wherever the item was triaged),
  both flags now qualify each number as `<ownerRepo>#<N>` instead of bare;
  `pr.sh` itself needed no change — its `closes_line()`/`validate_issue()`
  already accept either shape. A same-repo item (no `repo:`, or `repo:` equal
  to `ownerRepo`) is unaffected — bare `Closes #N` exactly as before. Covered
  by a new `workflows/scripts/build/tests/test_workflow.sh` case pinning both
  the bare and qualified forms in one level.

- **`board_owner()` now fails legibly, instead of silently borrowing this
  kernel checkout's own org, for a `boards.conf` board that sets `repo=` or
  `project=` but omits `owner=` (temperloop#798).** Any board id outside the
  built-in 3-6 case map (an adopter's own board) fell through `board_owner()`'s
  `*)` branch to `$BOARD_OWNER` — this repo's own `"Towheads"` — whenever the
  adopter's `boards.conf` entry forgot the `owner=` line, so `gh project …
  --owner Towheads` silently targeted a **foreign org's project** instead of
  erroring: a cross-tenant misdirection with no diagnostic. `board_owner()` now
  checks whether the board actually has a `repo=`/`project=` entry in
  `boards.conf` before falling back; if it does and `owner=` is still missing,
  it prints `board.sh: board N sets repo=/project= in boards.conf but no
  resolvable owner= …` to stderr and returns non-zero instead of guessing. A
  board with **no** `boards.conf` entry at all (repo, project, and owner all
  absent — e.g. board 7, the temperloop tracker itself, whose repo/backend
  come from the built-in maps per #808) is unaffected and still resolves
  `$BOARD_OWNER` exactly as before. `board_project_number()`'s sibling
  `*) echo "$1"` identity fallback is deliberately left ungated — its own
  updated comment names why (a same-tenant wrong-project-number risk, not the
  cross-tenant misdirection `board_owner()` guards against) and its failure
  mode. Pinned by two new cases in `test_boards_conf.sh`. Not breaking: no
  correctly-configured `boards.conf` entry changes behavior — only a board
  that was already misconfigured (repo=/project= with no owner=) now fails
  instead of silently doing the wrong thing.

### Fixed

- **`install-claude-md.sh`'s `INSTALL_CLAUDE_MD_KERNEL_ONLY=1` render arm no
  longer leaks a `t0` tmpfile per invocation (temperloop#742).** That arm
  moves `$tmp` to `$target` but never consumes `$t0_tmp` (T0 is deliberately
  not written on a kernel-only render — its scope is the fully composed doc),
  and the script's final `trap - EXIT` clears the cleanup trap before exit
  without removing it, so every kernel-only render — the seam
  `count-prose.sh` calls for its tier-1 count — left one empty
  `install-claude-md-t0.XXXXXX` in `TMPDIR`. Verified at filing time: 6
  leaked files across one `test_validate_prose_budget.sh` run. Fixed with an
  explicit `rm -f "$t0_tmp"` on that arm, right after the `$target` move —
  same shape as the arm's existing explicit `rm -f "$target"` before its own
  move, not the temperloop#753 subshell-defeated-trap fix (that one restored
  a lost `EXIT`-trap visibility across a command substitution; here the trap
  fires correctly, it is just cleared before it can act on a file this arm
  never claims). The composed (non-kernel-only) arm is untouched. Verified
  with 5 consecutive kernel-only renders leaking 0 files (was 1 each), and
  `test_install_claude_md_t0_inventory.sh` / `test_validate_prose_budget.sh`
  staying green.

## [0.23.0] - 2026-08-02 — BREAKING

### Migration — read this first

One migration, and it is narrow: **`/build`'s Step 3 within-level loop now runs
the per-level Workflow path by default.** If you drive `/build`, or your overlay
documents its conversational two-sweep orchestration, read
`### Changed — BREAKING` below before pulling. Pass **`--no-workflow`** to keep
the previous behavior. Everything else in this release is additive or a fix.

**Who has to act.** Only an operator, wrapper, or overlay that depends on
`/build`'s Step 3 running conversationally — most concretely anyone relying on
**speculative next-level execution**, which is a conversational-path-only
NON-GOAL under the Workflow path and is therefore now off by default. Nothing
else moves: `--workflow` is still accepted (it now selects the default and is a
no-op), the board adapter interface, hook names and signatures, the `checks`
gate contract, `bin/temperloop`'s subcommand set, the `.kernel-pin`/compose
seam, and the setting-registry row shape are all untouched — and no setting
default changed, because the flip lives in the command spec, not in
`build.config.sh`.

### Release classification for the remaining epic-#923 items — MINOR

The `workshop collaborative decision walk` epic (temperloop#923) shipped its
first nine items in **0.22.0, marked BREAKING** — `/workshop`'s coverage walk
lost its minimal-interaction path under a hard cutover. Its **two trailing
items classify MINOR**, and the aggregate call for the epic therefore stands at
BREAKING on the strength of 0.22.0 alone; nothing below adds to *that epic's*
call. (The release-level `BREAKING` on the `## [Unreleased]` heading above comes
from a different change — the `/build` workflow-path default flip, temperloop#998
— not from these two items.)

Why these two are MINOR: the new ratify gate is satisfiable by every brief that
walks normally (the seeded-dimension rule gives dimensions 0, 1 and 3 their
`walk` verdict from Step 1's own confirms), and the migration carve-out exempts
every brief authored before the record existed. **No adopter config changes and
no existing brief is invalidated** — which is the test `VERSIONING.md` applies.

### Added

- **`report.d` producers gain a `notice` string-field channel, and
  `report.sh`'s stderr-discard behavior is now documented
  (temperloop#981).** Any `.temperloop/report.d/` producer's stdout may
  optionally parse as a JSON object carrying a string `notice` field; when
  present, `report.sh` renders it as its own line under that producer's `--
  report.d/<name> --` heading, alongside its normal verbatim stdout. This is
  the first documented way for a drop-in — the `tokens` producer's planned
  first-run disclosure (epic #972) being the motivating case — to address a
  human without colliding with the `tokens` name's stricter
  `tokens_spent`-only JSON rule; it is a contract-level field, not a
  `tokens` special case, so any current or future producer can carry one.
  `report.contract.md`'s "Overlay drop-in contract" section also now states
  explicitly that `report.sh` discards every producer's stderr and never
  inspects it — always true, previously undocumented, and exactly the trap a
  producer writing to stderr for a human's benefit fell into. Additive, for
  the `notice` half of this change specifically: existing producers with no
  `notice` field render exactly as before. (The companion `jq`-exit-status
  fix below is a separate change with its own, narrower behavior delta — see
  that entry.)
- **`/workshop` Step 4 gains check 4.1c — challenge-record completeness at
  ratify (temperloop#934).** Runs after 1b and gates the ratify ask, so ratify
  becomes the terminal act of the walkthrough. It enforces exactly the two
  rules in `claude/design-schema.md` § Record completeness **by reference, never
  by restatement**, so the in-session gate and `validate-design-brief.sh`'s
  check (C) cannot drift: every kernel dimension 0..16 carries at least one
  `walk` stop line, and every `operator-edited` stop line carries its verbatim
  `response:` field. The migration carve-out is semantically identical to the
  validator's — a `ratified` brief with no `### Challenge record` at all is
  exempt and never flagged, keyed on a per-brief `status:` signal rather than a
  global version flip; a draft or dropped brief is never held to either rule.
  The record-start-marker-present-but-empty defect is independent of status and
  applies regardless, which is the loophole that stops a crashed walk from
  masquerading as a migration case.
- **Pipeline spend profiler + the `.temperloop/report.d/tokens` drop-in
  producer (temperloop#958).** New `workflows/scripts/pipeline-spend-report.sh`
  — a cost-weighted spend profiler over Claude Code workflow-agent transcripts,
  with `--since` / `--until` / `--run` / `--root` / `--format json` / `--top` —
  plus the `tokens` producer that gives `temperloop report` a live
  `tokens_spent` headline. Validated byte-exactly against the #953 reference
  corpus: over the same 1,622 agents it reports 180,608,852 weighted units
  (the 180.6M baseline exactly) and 2.16x undeduped inflation (390,212,000 →
  180,608,852, matching #953's figure to the digit), splitting machinery 31.8%
  / item workers 68.2%. Note **two** call-count thresholds, not one:
  `SPEND_MACHINERY_MAX_CALLS` (6) drives the machinery-vs-worker attribution
  split, and `SPEND_WORKER_PROFILE_MIN_CALLS` (40) is a separate, higher floor
  for the typical-worker profile — a single threshold provably cannot produce
  both stated baselines.
- **Four plan-less model-tier literals are now named settings
  (temperloop#982).** `SWEEP_WORKER_MODEL` and `FIX_WORKER_MODEL` join the
  Named-setting shell seam in `build.config.sh` (read symbolically by
  `sweep.md` and `fix.md` Step 0.4); `BUILD_MACHINERY_SOLO_MODEL` and
  `BUILD_MACHINERY_BATCH_MODEL` ride the **orchestrator→workflow input** seam
  instead — resolved at `build.md` Step 0 and passed as
  `machinerySoloModel` / `machineryBatchModel`, because a config-file read is
  structurally impossible inside the Workflow runtime (no filesystem, Node, or
  shell — DESIGN NOTE 1). **No default moves:** the `'haiku'` literal remains
  at both `build-level.mjs` sites as the absent-input default, and the fallback
  uses `||` rather than `??` so an empty-string input collapses to the default
  too. Model selection is byte-identical when nothing is set, which is what the
  MINOR classification rests on.

- **`temperloop init` now proposes the `tokens` `report.d` producer shim
  (temperloop#984).** A fresh `init` run's existing proposal PR now also
  adds `.temperloop/report.d/tokens` (mode `755`) alongside its other tree
  changes, so a newly adopted repo gets `temperloop report`'s
  `tokens_spent` headline without a manual step; a repo that already has a
  producer at that path is left alone. See `docs/features/telemetry.md` §
  "Token spend" for what the shim does once in place.


### Changed — BREAKING

<!-- The `BREAKING` token appears TWICE for this release on purpose — on the
     `## [Unreleased]` heading above AND on this `### Changed` sub-heading.
     `changelog_breaking_sections()` (workflows/scripts/lib/changelog.sh) sets
     its `brk` flag ONLY from a heading line: `$0 ~ /BREAKING/` on the
     `## [x.y.z]` line, or `/^#+ .*BREAKING/` on a sub-heading. BODY TEXT
     NEVER SETS IT. The sub-heading marker is the belt-and-suspenders half: it
     survives a release cut that rewrites `## [Unreleased]` into
     `## [0.23.0] - <date>` without carrying the ` — BREAKING` suffix across.
     Without at least one of these, scripts/update-kernel.sh's acknowledgment
     gate and bin/subcommands/update.sh's BREAKING warning both silently no-op.
     Do not strip either one when editing history. -->

- **BREAKING — `/build`'s per-level Workflow path is now the DEFAULT for Step 3;
  `--no-workflow` is the opt-out (temperloop#998).** `claude/commands/build.md`
  previously documented `--workflow` as **Default OFF**, so Step 3's
  within-level loop ran the conversational two-sweep orchestration unless the
  operator opted in. That is inverted: with no flag, Step 3 now runs the
  per-level Workflow (`claude/workflows/build-level.mjs`), and the new
  **`--no-workflow`** flag selects the conversational two-sweep loop.
  `--workflow` itself is **retained and still accepted as a no-op** — it now
  asks for what `/build` already does — so an existing invocation, wrapper, or
  muscle-memory command line that passes it explicitly does not break. The
  mechanics of the two paths are unchanged (`build-level.mjs` was not touched);
  both still call the same deterministic machinery scripts, and the orchestrator
  still owns Step 4, all plan-note writeback, and escalation resolution on both.
  **Why:** the Workflow path's batched machinery executors (temperloop#942) cut
  mechanical weighted token spend **32.8%** (468,283 → 314,801 units) and raw
  tokens **56.9%** on a 1-item level — worth **-6.6% per build level** — but
  because the path was Default OFF that saving reached only opt-in runs, so
  #942's shipped benefit was ~0% corpus-wide. Duration impact is ~1%: this is a
  token change, not a speed change. **Classified BREAKING** per `VERSIONING.md`
  — `claude/commands/*.md` is the "Pipeline command contracts" published
  surface, and a *default*-behavior change is breaking by that document's own
  test ("a downstream overlay or a stranger's config must change to keep
  working"): an adopter who changes nothing gets different orchestration, and
  must add a flag to keep the old one. **Migration:** append **`--no-workflow`**
  to your `/build` invocation (or your wrapper's) to keep the conversational
  two-sweep loop. Do this in particular if you use **speculative next-level
  execution** — cross-level speculative overlap is a documented
  conversational-path-only NON-GOAL under the Workflow path in v1, so flipping
  the default **disables speculative overlap by default**, and `--no-workflow`
  is the only way to get it back. Lifting that NON-GOAL is separate work and is
  still deferred past v1.

### Changed

<!-- Non-breaking changes only. The `### Changed — BREAKING` section above is
     the one `changelog_breaking_sections()` keys on; do NOT merge these two
     sections, and do NOT add ` — BREAKING` to this heading for a change that
     is not breaking. -->

- **Build workers no longer run the bare, repo-wide quality gate in their own
  context (temperloop#997).** The minutes-long blocking turn exceeded the
  ~5-min prompt-cache TTL and forced a full-context cache re-write — a 12.5x
  penalty measured at **4.84% of all workflow-agent spend**. The worker now
  runs a **path-scoped subset** via `quality-gates.sh --list`, for fast local
  feedback only and **explicitly labelled NOT the acceptance authority**;
  `/build` 3e.5's own bare, repo-wide gate run is untouched and remains the
  sole authority. Both worker surfaces moved in lockstep per `build.md`'s
  schema↔prose mandate (`build.md` 3c and `build-level.mjs`'s
  `workerPrompt()`), and new static guards in `test_workflow.sh` bind both
  directions — the ban must appear in *both* worker surfaces, and 3e.5 must
  still invoke the gate bare. Trade accepted: the alternative (re-spawning the
  worker on a parent-side red) pays its cost on every red, commonly a
  seconds-to-catch lint slip, whereas the cache miss was paid on every item.
- **The `/build` spine's progress row now names its run (temperloop#903).**
  `build-level.mjs`'s `phase()` title carried an item *count* and nothing else,
  so concurrent spine runs rendered identical rows in the progress UI — a
  single `/fix` session drove three indistinguishable `build-level`
  invocations. It now emits repo, count, and per-item slug + issue:
  `build level — Towheads/foundation · 1 item · migrate-off-legacy-funnel-names-1419 (#1419)`.
  Bounded to 3 named slugs with `+K more`; every segment optional-safe (a
  missing `ownerRepo`/`ghIssue` drops its own segment rather than rendering
  `undefined`); and set **after** the `onlySlugs` filter, so a continuation
  names the slugs actually being re-driven. `meta.description` — a
  runtime-enforced pure literal that can never carry run context — was
  rewritten operator-facing, dropping return-shape detail that already lives
  in the file's I/O CONTRACT header. The `{parked, escalations}` return
  contract and every per-agent label (`worker:<slug>`, `gate:<slug>`,
  `ci-poll:<slug>#<slice>`, …) are untouched.
- **Pre-merge CI gates on ubuntu only; macOS coverage moved to a nightly run
  (temperloop#963).** `ci.yml`'s `checks` job keeps its `strategy.matrix` — a
  single entry `os: [ubuntu-latest]` — so **the required status context stays
  exactly `checks (ubuntu-latest)`** and no branch-protection change is needed.
  New `.github/workflows/nightly-macos.yml` runs the same gate script on
  `macos-latest` (`schedule: "17 9 * * *"` — 09:17 UTC, ~02:17
  America/Los_Angeles under PDT — plus `workflow_dispatch`); its job context is
  `nightly-macos`, non-matrix, so branch protection cannot latch onto it, and a
  Verdict step writes a `$GITHUB_STEP_SUMMARY` block plus an `::error::`
  annotation on failure. **Trade stated honestly:** ubuntu gates merges, so a
  **BSD-dialect regression can now reach `main`** and is caught within a day
  rather than at the gate.

### Fixed

- **`report.sh` now checks `jq`'s exit status when parsing the `tokens`
  producer's `tokens_spent` field (temperloop#981).** Previously the parse
  only tested `[ -n "$parsed" ]`; on stdout that mixed a valid JSON document
  with extra non-JSON text, `jq` could emit output for the first valid
  document and still exit non-zero once it hit the invalid remainder — so
  trailing garbage after a clean JSON object "accidentally" still drove the
  tokens headline, while the same shape with the garbage leading instead
  produced no output at all and silently fell back to the kernel-tier
  headline. Both now require `jq`'s exit status to be `0`, so leading and
  trailing malformed stdout degrade the same, deterministic way — the
  kernel-tier headline, never a partial or inconsistent read. **Migration:**
  if your `tokens` producer emitted text alongside its JSON object, its
  headline will now fall back to the kernel tier — emit exactly one JSON
  object and move the text into `notice` (see the `notice` field entry
  above).
- **`walk`-only, not both verdicts — a superseded premise purged from the
  0.22.0 entry above (temperloop#934, temperloop#935).** The 0.22.0 entry for
  check (C) described it as requiring "**both** a `walk` and a `walkthrough`
  verdict" for every dimension. **That was never what shipped, and it is not
  satisfiable:** a dimension no review lens reached cannot acquire a
  `walkthrough` verdict, so the stated rule would deadlock every brief. The
  shipped validator emits `MISSING-WALK-VERDICT` and checks `walk` lines only,
  exactly as `design-schema.md` § Record completeness specifies
  (`walkthrough` coverage "stays opportunistic … and is never required for
  every dimension"). The 0.22.0 line is corrected in place with its prior
  wording quoted, rather than silently rewritten.

## [0.22.0] - 2026-08-01 — BREAKING

### Migration — read this first

One migration, and it is narrow: **`/workshop`'s coverage walk no longer has a
minimal-interaction path.** Two documented behaviors were deleted under a hard
cutover — the ad-hoc batch-approval grouping license, and Step 4's exemption
from persist-then-ask — so if you drive `/workshop`, or your overlay documents
a lighter-touch design walk on top of it, read `### Removed — BREAKING` below
before pulling. Everything else in this release is additive.

**Who has to act.** Only an operator or overlay that relied on `/workshop`
Step 2's "draft several dimensions, then ask once over the batch" shortcut, or
on the ratify ask skipping the persist-and-re-present step. Nothing else moves:
the board adapter interface, hook names and signatures, the `checks` gate
contract, `bin/temperloop`'s subcommand set, the `.kernel-pin`/compose seam, and
the setting-registry **row shape** are all untouched. Two setting *defaults*
changed (both prose-budget caps — see `### Changed`); no row was added, renamed,
or removed, so nothing that parses the registry needs to adapt.

### Added

- **`/workshop` gains `## Step 3.5 — Congruence pass + walkthrough`
  (temperloop#932).** A third pass between the review panel and ratify, in
  three parts: (1) a facilitator-run, **agentless and unconditional**
  congruence seam checklist applied by reference from `claude/design-schema.md`
  § Congruence seams — it runs even when every agent is unavailable, so a
  probe-less checkout still gets the cross-dimension consistency check; (2) a
  capability-probed `congruence-lens` spawn against exactly one document, whose
  skip takes the **remedy-bearing** degradation form (`skipped — <agent>
  available as source; run workflows/scripts/install/project-agents.sh to
  enable`) rather than a bare dead-end; and (3) a tier-mirrored walkthrough
  whose step count **derives from the schema's current dimension list**, never
  a hardcoded count, where every dimension — clustered or not — is individually
  listed, delta-flagged and individually verdicted (N verdicts per cluster
  line), with the `deferred → <ref>` time-boxing valve open to every
  non-premise dimension and closed to dimension 0. Step 3.5's findings dispose
  under Step 4.1b's **existing** folded / `deferred → <ref>` / declined
  vocabulary — one record, one vocabulary, one check, no second ledger. Step
  3.1.4 now also registers the cold-read lens in the same per-lens coverage
  record the 3.3 panel uses, so a skip is stamped into the artifact instead of
  only narrated. **For an adopter:** a `/workshop` run costs one more pass, and
  a checkout that has not run `project-agents.sh` is told how to fix that on
  the live line. New standing rules `W.17` (parallel-finding-ledger) and `W.18`
  (cluster-collapsed-verdicts) ship with matching citation-registry rows.

- **`congruence-lens` — a fifth read-only advisory review agent
  (temperloop#927).** `claude/agents/congruence-lens.md` reads **exactly one**
  target document per invocation and reports internal contradictions between
  its parts, quoting both passages verbatim and naming the seam they cross. Its
  charter frames it honestly as a **fresh-context textual-consistency check,
  not an independent-priors reviewer** — the operator remains the only
  independent reviewer, stated in the agent's own text so a reader cannot
  mistake its verdict for independent judgment. Registered in
  `docs/features/review-agents.md`, `docs/features/feature-manifest.txt` and
  `workflows/scripts/config/contributor-manifest.tsv`, and exercised against a
  new planted-contradiction fixture brief
  (`workflows/scripts/tests/fixtures/congruence-lens/`) by the real deployed
  agent, not a simulation. **For an adopter:** like every other kernel review
  agent it ships as *source* — it is available to `/workshop` Step 3.5 only
  after `workflows/scripts/install/project-agents.sh` installs it; until then
  the step degrades legibly rather than silently.

- **`claude/design-schema.md` gains two contract grammars — § Congruence seams
  and § Challenge record (temperloop#926).** § Congruence seams is a five-row
  **named-minimum** table of cross-dimension consistency pairs
  (`contract↔mechanism-shape`, `adoption↔problem-statement`,
  `acceptance↔testability`, `deferred-refs-resolve`, `cost↔scope`), explicitly
  a floor and not a ceiling, add-only in the same sense § Overlay extensibility
  already is. § Challenge record pins the verdict vocabulary (`accepted` /
  `challenged → revised ×N` / `operator-edited`), the per-stop line grammar,
  the `walk` vs `walkthrough` kind discriminator, the verbatim `response:`
  field, the `challenge-record-start: <date>` marker with **both** readings of
  its absence (no section at all = nothing recorded yet; marker present with
  zero stop lines = a defect), and its home section `## Working notes`. It also
  resolves a gate-satisfiability deadlock outright: a Step-1-seeded dimension's
  (0, 1, 3) Step-1 confirm **counts as** that dimension's `walk` verdict
  (`source: step-1-seed`) — without which every brief would fail the completeness
  check below. Six stale "temperloop#216, forthcoming" sites were corrected to
  the shipped `validate-design-brief.sh`, being precise about what it does and
  does not yet check rather than overclaiming, and § Overlay extensibility's
  class-level override claim was narrowed so it no longer reads as an
  invocation of `message-schema.md`'s named-template carve-out. **For an
  adopter:** an `design-schema.overlay.md` dimension list is unaffected (the
  add-only rule is unchanged); briefs written before this release carry no
  challenge record and stay exempt — see check (C) below.

- **`claude/message-schema.md` gains `### Decision presentation`, and a
  **non-overridable** template set that CI enforces (temperloop#928).** The new
  mode-6 template pins the five required parts of any decision put to the
  operator — the decision in plain terms, the proposed answer, the reasoning,
  the alternatives and why they lost (with "none considered" named as a
  legitimate value), and what accepting it constrains downstream — under a
  governing plain-language rule. Because those parts *are* a challenge gate, a
  redeclaration could hollow the gate out, so the template is excluded from the
  overlay-override surface — and the exclusion is **mechanical, not prose**:
  `workflows/scripts/validate-template-refs.sh` now carries
  `NON_OVERRIDABLE_TEMPLATES`, tests it **before** the canonical-name check
  (the order is load-bearing — reversed, an excluded name reports `ok`), and
  self-checks that every excluded name is still a template `§ Templates`
  defines, so a rename in the doc reds CI instead of silently disarming the
  exclusion. `CLAUDE.kernel.md`'s § Kernel vs overlay routing rule carve-out is
  qualified to match ("most of them, not all"), and a 219-line test suite plus
  a `quality-gates.sh` entry ship with it. **For an adopter:** an overlay that
  redeclares `### Decision presentation` in its own message-schema overlay now
  fails the `checks` job. **Deliberately not tagged `BREAKING`** — the
  exclusion set currently holds exactly one name, and that name is the template
  introduced in this same release, so no existing overlay can already have
  redeclared it; the contract-surface shrink is vacuous in practice. Adding a
  *pre-existing* template name to that set later would be breaking and must be
  marked as such.

- **`validate-design-brief.sh` check (C) — challenge-record completeness, in CI
  (temperloop#929).** The record is now enforced by the validator, not only by
  `/workshop` at ratify time: every dimension must carry a `walk` verdict
  (`walkthrough` coverage stays opportunistic and is **not** required per
  dimension — corrected below under Unreleased; this line originally read
  "both a `walk` and a `walkthrough` verdict", which never shipped),
  verdict lines must match the § Challenge record
  grammar, and an `operator-edited` verdict must carry its verbatim `response:`
  field. The grammar is **read from** `design-schema.md` § Challenge record,
  never re-encoded locally — the same discipline checks (A) and (B) already
  apply to the dimension list and the disposition grammar, so the schema stays
  the single source of truth. **Migration carve-out for existing briefs:** a
  brief with no `### Challenge record` subheading is **exempt at any status**,
  implemented as a per-brief signal rather than a global flag — so every brief
  authored before this release passes untouched, and only briefs that already
  have a record are held to it. Seven fixtures (complete / empty / bad-grammar
  / missing-response / draft-partial / migration-exempt / walk-missing) lock
  both verdicts, including the negative state that closes the loophole the
  record-start marker exists for.

- **`/tidy` Step 3 gains the `### All-accepted-untouched briefs` sweep
  (temperloop#933).** The drain now reads each ratified brief's challenge
  record and flags any brief whose coverage-walk stops are **all** bare
  `accepted` — zero `challenged → revised`, zero `operator-edited` — to the
  pending-decisions surface for `/check-in` to dispose. The tell it is after:
  a walk that never actually engaged the operator looks identical to a walk
  that converged, except in the record. Registered as a Capture/Backstop pair
  in `tidy.md`'s own kernel registry table (capture anchor: `workshop.md`
  § `Step 2 — Coverage walk`), so `validate-capture-backstop.sh` fails the
  build if either half is ever removed alone. **For an adopter:** one new
  `### open` entry class appears on the pending-decisions surface; nothing
  else changes.

- **`pr.sh recover-probe <worktree> <branch>` — a read-only staged
  side-effect probe (temperloop#939).** A new subcommand on the shipped
  `workflows/scripts/build/pr.sh`, additive to its CLI surface: it walks a
  three-stage ladder — commits ahead of base (`git rev-list --count`), branch
  present on origin (`git ls-remote --heads`), open PR for the branch
  (`gh pr list --head`) — and reports the furthest stage reached as a closed
  `RECOVER_*` outcome. It writes nothing. Its consumer is the recovery path in
  `### Fixed` below, but it stands on its own as the deterministic answer to
  "did this worktree's work actually land?" Five new `test_pr.sh` cases cover
  every rung.

### Changed

- **`build-level.mjs` batches its mechanical machinery calls instead of
  spawning one agent per shell command (temperloop#942).** The `--workflow`
  path wrapped EVERY mechanical step in its own `agent({schema})` executor: a
  measured L0 level of 3 items spawned **40 agents** (3 real workers + 37 haiku
  micro-agents), each paying ~160K cache-read tokens and 4 API round-trips to
  run one shell one-liner — including 7 separate `ci-poll.sh` spawns and 8
  separate `gh pr view` merge-state spawns at one level. Mechanically-adjacent
  steps now ride ONE executor each via the new `runMachineryBatch()`:
  `prelude:<slug>` (claim + deps-merged + worktree create), `pr-batch:<slug>`
  (rebase + scan + push + pr-open), and `ci-batch:<slug>#n` (the interleaved
  merge-state probe + CI poll slices). The same L0 shape now costs **15 agent
  spawns** (3 workers + 4 machinery executors per item). The 3e.5 quality gate
  deliberately stays a solo call — its own runtime is minutes-scale (measured
  6:05 for this repo's suite), so batching it would put a single Bash
  invocation within reach of the executor's ~10-minute cap.
  **No behavior change:** the batched executor returns `{results:[…]}` — one
  closed-outcome JSON object per step that ran — and every branching decision
  (`SCAN_BLOCKED`, `PUSH_REJECTED`, `REBASE_CONFLICT`, `CI_GREEN`/`CI_FAILED`/
  `NO_CI`/`TIMEOUT`, `DEPS_MERGED`, `CLAIM_CONFLICT`, `GATE_FAIL`, `EXISTS`,
  the `RECOVER_*` ladder) still lives in legible `.mjs`, never in an agent
  prompt; the bash short-circuit is only a stop-early mirror of those branches.
  DESIGN NOTE 1's bridge contract and DESIGN NOTE 2's CI-poll cap are updated in
  the file header, and the cap is now enforced **arithmetically**:
  `CI_POLL_SLICES_PER_BATCH` is derived from `CI_POLL_MAX_BATCH_WALL_MS`, so no
  retuning of the slice length can produce a batch that outlives the Bash cap.
  Six new `test_workflow.sh` cases lock the reduced spawn count, the prelude
  batching, the CI-poll reuse, the cap invariant, the `sq()` quoting of every
  batched argument, and the in-`.mjs` legibility of every branch.

- **`/workshop` Step 2 is now a collaborative, challenge-driven coverage walk
  (temperloop#930, temperloop#931).** The walk is collaborative *by
  construction*: every decision that reaches the brief is presented with its
  reasoning and can be contested before it is recorded, and the operator's
  speed lever is how fast they accept at each stop — never whether content is
  shown. Four structural changes. **(1) A tier-split proposal is the walk's
  first stop and its first challengeable decision**: it names which dimensions
  are load-bearing (own stop) and which are mechanical (clustered 2–4 to a
  stop, every dimension's full content still shown — a cluster compresses the
  *asking*, never the *showing*), states the **total stop count** it commits
  the session to so the operator can time-box against it, and assigns **every**
  dimension a tier including the Step-1-seeded 0, 1 and 3, whose
  confirm-or-challenge stop records a real `walk` verdict with `source:
  step-1-seed`. Leave those out and the problem statement and the routing call
  are the only calls in the brief the operator never formally accepted.
  **(2) Every stop is presented by reference to `message-schema.md`'s
  **Decision presentation** template**, never a restated local copy — and
  Step 1.3b(iii)'s premise-gate ask is re-pointed at the same template
  (temperloop#931), so the two gates cannot drift apart. **(3) A bounded
  challenge loop**: rounds one through three fold in and re-present freely; a
  fourth does not loop, it escalates to an explicit operator fork — accept
  as-is, `deferred → <tracking ref>` (never available for dimension 0), or park
  the walk with the brief left `status: draft` and a later run resuming from
  the persisted record. A non-converging stop is a visible operator choice, not
  an invisible grind. **(4) Per-stop challenge-record appends** applied by
  reference to `design-schema.md` § Challenge record, with one verdict **per
  dimension** on a clustered stop and the record-start marker written in the
  same write as the first stop line. The hardcoded 17-dimension count is gone —
  the walk's size is the schema's list as it stands. **For an adopter:** the
  interaction shape changes and two documented shortcuts are removed; see
  `### Removed — BREAKING` below, which is the half that requires action.

- **Both prose-budget caps raised: `PROSE_BUDGET_TIER1_CAP` 335 → 347 and
  `PROSE_BUDGET_TIER2_FILE_CAP` 1057 → 1186 (temperloop#925, temperloop#947,
  temperloop#954).** Three sequential raises across the release, each sized
  from measurement rather than re-guessed — the third one re-derived from the
  whole landed level after the first two had sized off one- and zero-item
  samples (blended observed overrun 1.53×, driven by the congruence-walkthrough
  item at 1.76×). These are **default-value changes on two existing
  setting-registry rows** — no row added, renamed, removed, and no column
  change — which `VERSIONING.md` § Setting registry classes as **minor, never a
  bare patch**: an adopter who dot-sources the previous default should re-check
  it. **The consequence worth stating plainly:** `PROSE_BUDGET_TIER2_FILE_CAP`
  is ONE uniform cap over every tracked `claude/**/*.md` file — there is no
  per-file exemption table — so raising it to fund `claude/commands/workshop.md`
  relaxes the per-file budget for **every** kernel doc, not that one file.
  Recorded as debt rather than glossed: three raises inside a single epic is
  itself the signal, `workshop.md` at 1144 lines is now the largest tracked
  kernel doc, and the subtraction pass those raises deferred is owed before a
  fourth.

### Removed — BREAKING

<!-- The `BREAKING` token appears TWICE for this release on purpose — on the
     `## [0.22.0]` heading above AND on this `### Removed` sub-heading. See the
     long comment on v0.19.0's own `### Removed — BREAKING` section below for
     why both are required: `changelog_breaking_sections()`
     (workflows/scripts/lib/changelog.sh) sets its `brk` flag ONLY from a
     heading line, never from body text, and the sub-heading marker is the half
     that survives a release cut rewriting `## [Unreleased]`. Do not strip
     either one when editing history. -->

- **BREAKING — `/workshop` Step 2's ad-hoc batch-approval license is removed.**
  The old Step 2.7 explicitly permitted it: "A batched draft is still fine: you
  may walk and disposition several dimensions, then persist and echo the batch,
  then ask once over it." That sentence is gone, and the new Step 2.7 closes
  the door by name — "Nor is there an ad-hoc grouping license." **Migration:**
  the only sanctioned way to ask once over several dimensions is now a
  **mechanical cluster the operator accepted at the tier-split stop** (Step 2
  item 2) — every dimension still shown, every dimension separately verdicted.
  If you drive `/workshop` by hand, or your overlay documents a
  batch-then-ask-once shortcut, move it onto the accepted-cluster path; an
  unaccepted grouping is no longer a legal way to reach the operator.

- **BREAKING — Step 4's ratify ask is no longer exempt from persist-then-ask.**
  The old Step 2.7 carried a Scope carve-out: "Step 4.3's ratify ask is
  **exempt** — its precondition, Step 4.1's dimension-completeness check,
  already guarantees the note is current, so no re-echo is required there."
  That exemption is deleted. Persist-then-ask now governs **every** gate over
  brief content — the walk's own stops, the findings fold-back, and the ratify
  ask alike — with no exemptions, and both surfaces (the persisted note,
  read-back-confirmed; and the in-chat decision presentation over that same
  content) must be current before the question is posed. **Migration:** a
  ratify ask must re-persist and re-present the content it gates rather than
  relying on the completeness check having left the note current. An overlay
  that restated the exemption must drop it — it now contradicts a kernel
  contract.

### Fixed

- **A completed worker whose return channel failed no longer produces a
  spurious `worker-error` escalation — or risks a duplicate PR
  (temperloop#939).** `build-level.mjs`'s 3c worker spawn is now wrapped in
  `callWorker()`, because the real failure mode is an **exception, not a
  null**: `agent({schema})` *throws* on a StructuredOutput-absent subagent, so
  the pre-existing null-guard never saw it and the run fell through to the
  catch-all escalation even when the work had fully landed. On any absent
  verdict the driver now runs `pr.sh recover-probe` (see `### Added`)
  **before** anything else. If the work landed, the `{slug, pr, pushed_sha}`
  parked record is reconstructed from that ground truth and the machinery
  finishes from whatever stage the worker actually reached — adopting the
  existing PR via `pr.sh`'s `EXISTS` outcome (**never** a second PR) and never
  re-spawning the worker onto a worktree that already holds the finished
  commit. If nothing landed (`RECOVER_NONE`), or the probe is denied or errors,
  the pre-existing worker-error path is untouched: it **fails closed**.
  **The recovery stays honest, which is the part an adopter must not miss.** A
  recovered verdict carries **no `passed` key at all**, marks every acceptance
  criterion `UNVERIFIED`, synthesizes a PR verification surface that says so,
  and the parked record carries `acceptance_unverified: true` and
  `recovered_from: <stage>`; `build.md` 3h/4a require the orchestrator to stamp
  it, render it distinctly from a self-reported verdict, and **re-verify before
  the merge gate**. A recovered item is a rescued record, never a passed one.
  Two non-obvious traps are handled: an already-pushed recovery skips the 3f-0a
  rebase (whose rewrite would make the following push a non-fast-forward and
  manufacture a *fresh* spurious escalation), and `--verification-surface-file`
  is dropped when the probe saw no `.build-verification.md` (a given-but-missing
  file is a hard `pr.sh` ERROR). The pre-existing but undeclared `DEPS_MERGED` /
  `DEPS_UNMERGED` outcomes are named in the same enum.

## [0.21.0] - 2026-07-29

### Added

- **Per-query OUTCOME fields on the knowledge-search read-log (foundation#1449,
  foundation epic #1443). Additive; existing consumers unaffected.** `ks_search`
  (the one entrypoint shared by both the cold `basic-memory` backend and the
  warm `basic-memory-mcp` daemon backend) now appends six fields after its
  existing `" · "`-joined 5-field read-log line: `result_count`, `top_score`,
  `abstained`, `rg_fallback`, `mode`, and `wall_ms`. `mode` names the retrieval
  path actually taken — `hybrid` or `hybrid+rerank` (reflecting whether the
  temperloop#1446 post-fetch re-rank ran for that query), `rg-fallback` when
  the score-0 ripgrep lexical fallback (foundation#950) answered instead, or
  `error:<rc>` on a backend dispatch error. `abstained` was always `0` at the
  time this landed — no abstention mechanism shipped yet, the field was
  emitted so the record shape would be stable before one did (see the
  foundation#1450 entry below, in this same release, for the mechanism that
  now sets it). Every other read-log
  call site (`ks_read`/`ks_write`/`ks_append`/`ks_list`, every backend, and the
  agent-plane hook) is unchanged — only `ks_search`'s line grows, and only at
  the end, so any consumer keyed on field position (the SessionEnd one-liner,
  `/tidy`'s tally, `telemetry-brief.sh`) reads exactly as before.
  `workflows/scripts/validate-knowledge-search-emit.sh` is the new presence
  lint guarding this wiring (the `validate-issue-touch-emit.sh` mold applied
  to a pure-library emit with no markdown orchestration step).

- **Abstention floor below a measured per-mode score/lexical-coverage floor
  (foundation#1450, foundation epic #1443). Opt-in, both backends, off by
  default.** `ks_search` can now decline to answer a query at all: below a
  measured floor on the shipped hybrid+rerank surface (temperloop#1446), it
  returns the existing genuine-zero-result shape instead of confident-looking
  low-relevance hits. Set `KNOWLEDGE_SEARCH_ABSTAIN=1` to enable it (default
  `0` — see rationale below); `KNOWLEDGE_SEARCH_ABSTAIN_SCORE_FLOOR` (default
  `0.72`) and `KNOWLEDGE_SEARCH_ABSTAIN_LEX_FLOOR` (default `0.10`) tune the
  two floors. The gate looks only at the top-ranked, post-re-rank candidate
  and requires **both** floors to fail — a conjunction, not either surface
  alone.

  **Why a conjunction, not a single floor.** Measured on the 213-query
  engine-neutral golden-query bench (foundation's
  `workflows/scripts/evals/golden-queries/`; 204 labeled + 9
  correct-abstention queries), two single-surface floors were rejected first:
  raw `.score` is query-relative (the re-rank's own trap 1) and the 9
  correct-abstention queries' top score (0.65–0.76) sits *inside* genuine
  hits' own range (0.58–1.28, median 0.79) — a floor tight enough to catch
  most abstention cases costs 30%+ of genuine top-5 hits. The re-rank's own
  RRF fusion score is rank-dominated (its leading term is a near-constant
  `1/(rrfk+0)` for every query's top-ranked candidate, answerable or not) and
  carries almost no separating signal alone either. What separates, measured
  on that corpus, is the **conjunction** of the top-ranked candidate's raw
  score AND its lexical-coverage feature `L` (the re-rank's own title/path
  term-agreement score, already computed for the fusion) — because in this
  corpus a genuine hit is almost always a strong semantic match, a strong
  lexical match, or both, so requiring BOTH to be simultaneously weak is what
  isolates the unanswerable queries.

  **Measured result, two independent runs (byte-identical — the fused
  candidate order is deterministic; only *tie-breaking* among near-equal
  ranks jitters per trap 3):** at the shipped defaults, correct-abstention
  moved from the pre-existing 0/9 baseline to **4/9**, with **0/186** labeled
  top-5 hits lost (aggregate hit@5 unchanged — well inside the ~3% jitter
  budget). Ships opt-in rather than default-on because this is judged
  BREAKING-adjacent: it changes the result set an existing caller receives on
  any live query that happens to land in the low-score/low-lexical-coverage
  region, and the calibration set is small (all 9 correct-abstention examples
  that exist in the corpus — there is no held-out set to validate recall
  against). The zero-measured-cost property is the load-bearing safety claim
  here; the 4/9 recall figure is directional, not a guarantee against novel
  unanswerable queries.

  **The rg-fallback interaction (ratified L1 mode-sweep semantics, consumed
  here, not re-decided).** An abstention is a **post-re-rank empty**, never a
  **backend-empty** — the backend returned real candidates; the floor
  discarded them. The score-0 ripgrep lexical fallback (foundation#950) fires
  only on a genuine backend-empty, so it stays **suppressed** on a
  floor-triggered abstention even when a literal corpus match exists on disk
  (`abstained=1`, `rg_fallback=0` — both verified by test). Wires the
  previously-hardcoded `abstained` outcome field (foundation#1449) from `0`
  to `1` when this fires — its live misfire monitor.

  Implementation is a single shared point: `_ks_bm_rerank` (one
  implementation reused by both the cold `basic-memory` backend and the warm
  `basic-memory-mcp` daemon backend) signals an abstention with one sentinel
  line in place of its normal JSONL stream; `ks_search` is the one place that
  consumes it, converts it to the real empty-result shape, and suppresses the
  rg fallback — the sentinel never reaches a caller. The `ks_search` JSONL
  output shape and exit-code contract are byte-unchanged for every
  non-abstaining query, and off by default (`KNOWLEDGE_SEARCH_ABSTAIN=0`) is
  a true no-op, identical to pre-#1450 behavior.

## [0.20.0] - 2026-07-29

### Added

- **Post-fetch re-rank on both knowledge-search backends (temperloop#1446,
  foundation epic #1443's ranking lever). Additive; off-switch provided.**
  `ks_search` now asks the backend for a deeper candidate set than the caller
  requested (`KNOWLEDGE_SEARCH_RERANK_DEPTH`, default 20), re-orders those
  candidates with a thin deterministic re-ranker, and returns exactly `--limit`
  of them — the extra depth is internal, so a caller asking for 5 still gets 5.
  This is the lever the foundation#1445 mode-sweep verdict selected over every
  retrieval-mode alternative (a different default mode, intent routing, and
  multi-mode fusion were each measured and rejected): on that corpus the right
  document sat inside the backend's top-20 for 94.6% of queries but inside its
  top-5 for only 86.8%, so depth was buying coverage the returned window threw
  away. The re-ranker is jq-only — no cross-encoder, no model download, no new
  dependency — and scores each candidate on query-term agreement with its own
  title and path, weighted by how RARE each term is among that query's own
  candidates, with a bonus for a verbatim query match. A minimal suffix stemmer
  unifies inflections ("editor"/"Editing", "plan"/"Plans-archive") that an exact
  matcher could not see. Measured on the 214-query engine-neutral bench corpus
  against a same-index control: known-item hit@5 0.8056 -> 0.8611 and known-item
  MRR 0.5833 -> 0.7972, with no category regressing. **The published
  `{doc_id,title,score,snippet}` JSONL shape and the exit-code contract are
  unchanged** — the re-rank alters only the ORDER and therefore which `--limit`
  candidates survive; each surviving record is passed through byte-for-byte.
  Three invariants are test-pinned: it never reads `score` as evidence (hybrid
  scores are normalised within each query's own result set, so they are
  query-relative and no fixed threshold is well-founded — the fusion is over
  RANK lists instead); the `score: 0` rg-fallback sentinel is provenance, not
  relevance, and a candidate set carrying one is never reordered; and the cold
  CLI path and warm bm-mcp daemon path share ONE implementation so they cannot
  drift apart in ranking. Set `KNOWLEDGE_SEARCH_RERANK=0` to restore the
  backend's own ordering — the fetch depth then collapses back to `--limit`,
  making the off-switch a true no-op.

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

## [0.19.0] - 2026-07-29 — BREAKING

### Migration — read this first

This release **closes both open compatibility windows at once** — the
`foundation` → `temperloop` rename window (opened v0.15.0, temperloop#165 /
temperloop#764) and the v0.17.0 terminology-consolidation window (opened
v0.17.0, epic temperloop#719 / temperloop#767). Both stated a v0.19.0 removal;
this is that removal. One adopter migration, not two.

**Who has to act.** Anyone whose machine, overlay, or scripts still name a
pre-rename identifier. If you installed or configured this kernel at v0.14.x or
earlier you almost certainly do. **The `boards.conf` item below has been
observed silently breaking a live host — do that one even if you believe you
are already migrated.**

The two lists below are **derived, one line per entry**, from the two
machine-readable window tables this release deletes:
`workflows/scripts/kernel/prerename-leak-verdicts.tsv`'s eight `windowed` rows
(plus the two legacy FORMS that file's own header records as always-sanctioned
by pattern rather than enumerated as rows), and
`workflows/scripts/kernel/terminology-leak-exempt-files.txt`'s thirteen-file
`window` class. Nothing here is hand-picked: if an entry was in a table, it has
a line.

#### A. `foundation` → `temperloop` names — 10 entries

Derived from `prerename-leak-verdicts.tsv`, verdict `windowed`. Every one of
these was a **read-old** fallback; each has been replaced by a legible refusal
or a named diagnostic, so nothing in this group degrades silently — **except
A7**, which has its own call-out below.

| # | Deleted window entry | What to do |
|---|---|---|
| A1 | env `FOUNDATION_HOME` | Rename the export to `TEMPERLOOP_HOME`. Setting only the legacy name now **exits non-zero** naming the replacement. |
| A2 | env `FOUNDATION_BIN_DIR` | Rename the export to `TEMPERLOOP_BIN_DIR`. Same refusal. |
| A3 | env `FOUNDATION_KERNEL_REPO` | Rename the export to `TEMPERLOOP_KERNEL_REPO`. Same refusal. |
| A4 | env `FOUNDATION_VERSION` | Rename the export to `TEMPERLOOP_VERSION`. Same refusal. |
| A5 | `bin/lib/common.sh`'s internal install-path *home* constant (legacy-prefixed spelling) | Now `TEMPERLOOP_CLI_HOME_DEFAULT`. Nothing to do unless you patch or source `bin/lib/common.sh` and reference the constant by name — then rename your reference. |
| A6 | `bin/lib/common.sh`'s internal install-path *bin* constant (legacy-prefixed spelling) | Now `TEMPERLOOP_CLI_BIN_DEFAULT`. Same. |
| A7 | machine conf leaf `boards.conf` — the legacy `~/.config/foundation/boards.conf` read | `mkdir -p ~/.config/temperloop && mv ~/.config/foundation/boards.conf ~/.config/temperloop/` — **read the call-out below before skipping this.** |
| A8 | knowledge-store root leaf `knowledge` — the legacy `~/.local/share/foundation/knowledge` store | `mkdir -p ~/.local/share/temperloop && mv ~/.local/share/foundation/knowledge ~/.local/share/temperloop/`, or point `KNOWLEDGE_STORE_ROOT` at the existing store. `knowledge_store.sh` **names** a stranded legacy store on stderr instead of reporting "no notes found" against an empty new root. |
| A9 | the committed per-repo `.foundation/` dir (`.foundation/config`, `.foundation/baseline.jsonl`, …) — sanctioned by pattern in the verdict table's header, never a row | Run `git mv .foundation .temperloop` in each repo. `temperloop init` **refuses** while a legacy `.foundation/config` is present and no `.temperloop/config` exists; `baseline-snapshot` **refuses** while a legacy `.foundation/baseline.jsonl` exists, rather than splitting one append-only history across two directories. |
| A10 | `bin/foundation`, the CLI compat shim — sanctioned by pattern in the verdict table's header, never a row | Invoke `temperloop <sub>`. **Forwarding is removed; the file is retained as a refusing tombstone** (see below), so the old name still *answers* — it just refuses and names the replacement. To retire the old name from your `PATH`, run `rm -f ~/.local/bin/foundation` **yourself**. |

**A10, precisely: `bin/foundation` is NOT deleted.** Its forwarding is removed
and the file is retained as a **refusing tombstone**. A pre-v0.19.0 install left
a `~/.local/bin/foundation` symlink pointing at that file, and `temperloop
update` moves the checkout underneath that symlink — so deleting the file would
turn the symlink into a dangling "no such file or directory" at exactly the
moment the operator needs to be *told* the name changed. A fresh `bootstrap.sh`
install no longer creates the symlink at all.

**Removing the stale symlink is MANUAL.** `temperloop uninstall` **prints** the
`rm -f ~/.local/bin/foundation` for you to run; it cannot remove it itself. The
symlink belongs to the bootstrap footprint (scope (a) of `bin/README.md`
§ Uninstall), written before any install manifest existed, so uninstall has no
record of it and deliberately will not infer one (`uninstall.sh:22-31`). Run the
`rm -f` by hand.

#### A7 in full — the machine `boards.conf`. Do this one first.

This is the **one migration in this release that fails silently**, and it has
already bitten a live host.

- **Exact old path (no longer read):** `~/.config/foundation/boards.conf`
  (`$XDG_CONFIG_HOME/foundation/boards.conf`)
- **Exact new path (the only one read):** `~/.config/temperloop/boards.conf`
  (`$XDG_CONFIG_HOME/temperloop/boards.conf`)
- **Fix:**
  `mkdir -p ~/.config/temperloop && mv ~/.config/foundation/boards.conf ~/.config/temperloop/`

**The failure is SILENT — no error, no log line, no non-zero exit.** Every
`--board N` simply resolves against the built-in maps instead of your conf, so
the boards quietly come up on the **wrong backend**. Nothing tells you. Measured
on the driver host during this very release cut (temperloop#908): that legacy
file was the *only* record of a four-board backend cutover
(`board.{3,4,5,6}.backend=issues`, temperloop#470–473), and a v0.19.0-era
checkout beside a v0.18.0 one read boards 3/4/5/6 as `projects` where the older
checkout read `issues` — a **silently reverted** cutover that would have put
every fleet board read and write back onto the Projects-v2 GraphQL path and back
into contention for the shared 5,000-pt/hr budget. It was found by hand, not by
any gate.

Do not rely on `board.sh`'s stderr `NOTE` to catch this for you. That note fires
only in the narrow case where **no** `~/.config/temperloop/boards.conf` exists at
all — a partially-migrated host with both files gets nothing — and library
stderr is routinely swallowed by the sourcing caller and by unattended runs.

#### B. v0.17.0 terminology names — 13 entries

Derived from `terminology-leak-exempt-files.txt`'s deleted `window` class, one
line per file. Unlike group A these arms **fail open by construction** — a
forwarding stub is invoked *by path* and the env shim was sourced under
`[ -f ]` — so there is no refusal to leave behind: a caller still on a legacy
name now gets "no such file or directory" from its own shell, or simply no
binding at all. The v0.17.0 `BREAKING` entry carries the full rename map.

| # | Deleted window file | What to do |
|---|---|---|
| B1 | `workflows/scripts/lib/rename-compat-0170.sh` (the env shim, plus **both** of its `[ -f ]`-guarded source blocks in `build.config.sh` and `setting-registry-lib.sh`) | Rename every variable you set: `FUNNEL_<NAME>` → `PIPELINE_<NAME>`, `KNOB_<NAME>` → `SETTING_<NAME>`. A pre-rename name now binds nothing and prints nothing — including one set from a layer-3 machine conf or a layer-4 repo-local conf. |
| B2 | `workflows/scripts/build/funnel-cron.sh` | Invoke `workflows/scripts/build/pipeline-cron.sh`. **Also repoint any installed launchd plist / cron entry** — the *installed* copy is what runs, not the repo file. |
| B3 | `workflows/scripts/build/funnel-drive.sh` | Invoke `workflows/scripts/build/pipeline-drive.sh`. |
| B4 | `workflows/scripts/build/funnel-tick.sh` | Invoke `workflows/scripts/build/pipeline-tick.sh`. |
| B5 | `workflows/scripts/build/funnel-overlap.sh` | Invoke `workflows/scripts/build/pipeline-overlap.sh`. |
| B6 | `workflows/scripts/build/funnel-schedule-gate.sh` | Invoke `workflows/scripts/build/pipeline-schedule-gate.sh`. |
| B7 | `workflows/scripts/build/build-config-knobs.sh` | Invoke `workflows/scripts/build/build-config-settings.sh`. |
| B8 | `workflows/scripts/config/check-knob-registry.sh` | Invoke `workflows/scripts/config/check-setting-registry.sh`. Update any overlay gate list naming the old path. |
| B9 | `workflows/scripts/config/check-knob-prose.sh` | Invoke `workflows/scripts/config/check-setting-prose.sh`. Update any overlay gate list naming the old path. |
| B10 | `workflows/scripts/config/knob-registry-lib.sh` (the source-forwarder, which also re-exposed the `knob_registry_*` function names) | Source `workflows/scripts/config/setting-registry-lib.sh` and call the `setting_registry_*` names. |
| B11 | `workflows/scripts/validate-live-drain.sh` | Invoke `workflows/scripts/validate-capture-backstop.sh` (or `make validate-capture-backstop`). |
| B12 | `workflows/scripts/validate-capture-backstop.sh`'s legacy **registry-filename** resolution and table spellings | Rename the overlay registry file `claude/live-drain-registry.overlay.md` → `claude/capture-backstop-registry.overlay.md`, its heading `## Live/Drain pairings` → `## Capture/Backstop pairings`, and its table's first column header `Live rule` → `Capture rule`. **This is the one arm in group B that degrades quietly:** an overlay still shipping the old filename now reads as "no overlay extension present", so its pairs are simply **not validated** and the gate stays green. |
| B13 | `workflows/scripts/tests/test_terminology_rename_compat.sh` | Nothing to do. The file is not deleted — it is inverted in place from a read-old-write-new proof into a window-**stays-shut** regression test. |

#### Contract surfaces this release touches

Five of the surfaces `VERSIONING.md` § The contract surface enumerates change
here. **Hook names and signatures are untouched** — the hook changes in this
release are behavior-only, inside the same I/O contract.

1. **CLI surface** — `bin/foundation`'s forwarding is removed and the file is
   retained as a refusing tombstone (A10); the four legacy `FOUNDATION_*` env
   vars now make `bin/temperloop` refuse rather than silently install at a path
   you did not ask for (A1–A4); `init` and `baseline-snapshot` refuse on legacy
   `.foundation/` state (A9).
2. **Board adapter interface** — the machine-level `boards.conf` layer reads one
   path only (A7). No `board_*` function name, argument, or `--board N` value
   changes; only where the layer-3 conf is read from.
3. **Setting registry** — **four rows are removed** (the four DEPRECATED
   legacy-prefixed env rows superseded by their `TEMPERLOOP_*` twins in
   v0.15.0), and the four surviving twins' `default` fields no longer transcribe
   a `${…:-…}` fallback to the legacy name. Row removal is now classified
   explicitly in `VERSIONING.md`'s setting-registry paragraph — it is
   **breaking**. No column changes, so the row *shape* readers parse is
   unchanged.
4. **Published schemas/contracts** — the capture/backstop overlay registry's
   filename, heading, and column header are now single-spelled (B12);
   `knowledge_store.contract.md`'s default store root no longer has a legacy
   fallback (A8); `docs/config-precedence.md` records the single `boards.conf`
   machine path.
5. **Quality-gate contract** — `KERNEL_GATES` **shrinks by 2**: the two gate
   entries that were still invocable at their pre-rename script paths
   (`check-knob-registry.sh`, `check-knob-prose.sh`) now exist only under their
   renamed spellings (B8, B9), so an overlay gate list naming either old path
   fails with "no such file or directory". Alongside them,
   `make validate-capture-backstop`'s script no longer answers to
   `validate-live-drain.sh` (B11), and the terminology-leak gate's exempt list
   drops two whole classes (`window`, `registry`) — so `make
   test-kernel-terminology` now guards surfaces the window used to be allowed to
   carry.

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

- **`env-reconcile` reports a consumer carrying an out-of-date vendored guard
  (foundation#1353). Additive.** `workflows/scripts/build/env-reconcile.sh`
  gains a `STALE_VENDORED_HOOK:<hook>` drift class on its operator/consumer
  checkout role: a consumer repo whose vendored
  `.claude/hooks/build-worktree-guard.sh` differs from this kernel's canonical
  `claude/hooks/build-worktree-guard.sh` is now **reported**, with the exact
  command that re-syncs it. This closes a real blind spot rather than a
  hypothetical one — when the kernel's write-jail grew its Bash arm, the three
  consumers kept the pre-Bash-arm copy and *nothing* said so, which is how a
  worker's `rm -rf "$(dirname "$(pwd)")"` reached outside its worktree
  (foundation#932). Design choices that keep it from going stale itself: it
  compares **content**, not a version stamp, so it needs no kernel-side
  coordination; the sync's provenance banner lines are excluded from the
  comparison (counting them would mark every correctly-synced consumer
  permanently drifted); and the remedy string is read from the vendored copy's
  own banner, which already names the target that produced it, so there is no
  repo→target mapping table to drift. Emitted in **both** probe formats, so
  `/tidy` routes it to the environment-hygiene report for `/check-in` like any
  other cross-lane drift. Deliberately **not** a `make doctor` check: doctor's
  pinned contract is "non-zero → run `make install` to heal", and a stale hook
  in a *foreign* checkout is not healable by `make install`, so a class there
  would pin doctor non-zero forever and bury its real MISSING/DANGLING signal.
  Read-only and fail-open — an absent or unreadable checkout, a consumer that
  vendors no copy, or an unresolvable canonical reference is skipped silently,
  never an error. Detection half only; auto-sync on kernel merge
  (foundation#694) remains the durable fix and is referenced, not duplicated.
  Both new seams are registered in `setting-registry.tsv`
  (`ENV_RECONCILE_CANONICAL_HOOK_DIR`, `ENV_RECONCILE_VENDORED_HOOKS`) — new
  rows only, so nothing existing changes shape.

### Changed

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

- **The build-worktree write-jail now contains output redirects, not just
  destructive verbs (foundation#1355).** An output redirect is a write the
  *shell* performs before the verb ever runs — `> <path>` truncates that file
  whatever command follows — so the Bash arm's verb-only inspection left a
  whole write vector uninspected beside the inspected delete vector. Redirect
  targets (`>`, `>>`, `2>`, `2>>`, `&>`, `>|`, and the word-glued spellings) are
  now judged on the same terms as a destructive verb's path operand: a
  non-literal target is unprovable and denied, a target resolving outside the
  worktree root is an escape and denied, and the existing
  `/tmp`/`$TMPDIR`/gitignored allow-list applies unchanged — so the cd-context
  check covers redirects for free. Three shape rules carry the behavior: a
  **bare** operator still ends the preceding verb's operand run while a
  **glued** one does not (it does not end the argument list in a real shell
  either, and `rm -rf 2>/dev/null <outside>` really does delete `<outside>`);
  `>&WORD` names no file only when WORD is an fd number or `-`, so `2>&$FD`
  stays contained and `>(cmd)` is correctly read as process substitution; and
  character-device sinks (`/dev/null`, `/dev/stderr`, `/dev/fd/N`, …) are
  allow-listed **for redirects only**, because `2>/dev/null` is the most
  routine idiom on a worker command line and denying it is how a guard gets
  disarmed — `rm -rf /dev/null` is still judged normally. Hook **name and I/O
  signature are unchanged**; this is a widening of what the same hook denies.
  Verified against the differential harness (working copy vs. `origin/main`,
  failing on any `old=DENY new=allow`): 62 same, 12 tightened, 0 regressions.
  One incidental tightening falls out — `rsync`'s last-selector used to pick a
  trailing `2>/dev/null` as the destination and miss the real one. The harness
  itself is now a `KERNEL_GATES` entry
  (`claude/hooks/tests/differential-guard-vs-ref.sh`, foundation#1367), so a
  refactor that loses coverage can no longer arrive with a corpus that ratifies
  the loss.

- **The write-jail's operand walker is now a verb-to-operand-model table
  (foundation#1354).** The Bash arm modelled every destructive verb with one
  grammar — "every non-flag token is a path operand", plus a hand-branch for
  `dd`'s `of=` — which does not generalize past the flat
  `rm`/`rmdir`/`mv`/`shred`/`truncate` list, leaving three common
  worker-destructive shapes entirely unmodelled. The flat verb list is replaced
  by a MODEL table keyed by verb, each row carrying four data fields: which
  operands are targets, the predicate deciding whether the invocation is
  destructive at all, whether the cd-context directory is itself an implicit
  target, and the verb's token count. The walker dispatches on that data — no
  verb name appears in control flow — so a new shape reusing an existing
  select/arm pair is a table row and nothing else. Three rows added, each a
  different grammar: **`rsync`** is destructive only under `--delete*` and only
  its last operand (the destination) is checked; **`find`** is destructive only
  when its predicate run carries `-delete` or `-exec rm`/`rmdir`, and only the
  pre-predicate path operands are checked (`-delete` was previously swallowed
  by the leading-`-` flag skip); **`git clean`** has no target operand at all
  and is judged against the cd-context base. `rm`/`rmdir`/`mv`/`shred`/
  `truncate`/`dd` behavior is unchanged and the hook's I/O signature is
  untouched; deny reasons now name the offending verb instead of a hardcoded
  verb list. Corpus grew by 15 DENY cases and 10 ALLOW cases — the ALLOW side
  pinning that `git clean -xfd` and `find . -name '*.pyc' -delete` *inside* the
  worktree stay silent, since they are routine worker commands. A follow-on fix
  in the same window (`0077a46`) extends the walker to nested and following
  verbs so the table cannot lose coverage at a shell-operator boundary.

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
     The v0.19.0 cut kept BOTH markers, and this section is what
     `changelog_breaking_sections v0.18.0 v0.19.0 CHANGELOG.md` prints — do
     not strip either one when editing history. -->

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

