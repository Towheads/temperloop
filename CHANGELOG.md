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

### Added

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

