#!/usr/bin/env bash
#
# replay.sh — replay corpus selection + the isolated replay worktree
# (temperloop#1254, epic #1225 "model comparison harness"). This is the
# FIRST kernel component of the replay half of the model-comparison module
# (ADR 0027: "a new kernel component taking lineage from foundation's
# workflow-eval.sh/judge.py, not a flag bolted onto them" — those files are
# overlay assets absent from a kernel-only install, and their shim-based
# isolation regime is deliberately incompatible with replay's real-remote
# reads).
#
# ── GATE SCOPE — read this before touching anything downstream ─────────────
# This file owns CORPUS SELECTION, ISOLATION, the SCORED-RECORD SCHEMA, and —
# as of temperloop#1258 — replay EXECUTION (`execute` below). SCORING itself
# lives next door in workflows/scripts/model-comparison/score.sh, which
# `execute` invokes as a subprocess; the `candidate`/`score` sub-objects the
# `schema` command prints are no longer placeholders, they are the shape
# `execute` populates. The schema version is UNCHANGED (`replay-record-v1`):
# #1254 shipped those two sub-objects as documented placeholders explicitly
# for #1258 to fill in, so defining their interior is completing v1, not
# minting a v2.
#
# ── THE ONE THING THAT MUST STAY TRUE OF THIS FILE'S TESTS ─────────────────
# `execute` is the only command in this module that can reach a model, and
# it CANNOT reach one by accident. There is no implicit candidate binary:
# the caller must pass EITHER `--candidate-runner <cmd>` (a recorded/stubbed
# runner — how every fixture drives it) OR the explicit `--live` flag (the
# real candidate-session.sh spawn). With neither, `execute` prints
# CANNOT EVALUATE and exits non-zero; it never falls back to a `claude` on
# PATH. That refusal is what makes "the fixture suite issues no live model
# call, ever" a structural property rather than a promise, and it is
# asserted directly (a canary `claude` on PATH that the whole suite proves
# was never invoked).
#
# ── Spike facts this file takes as GIVEN (temperloop#1247, the keystone
#    spike) — see Context/temperloop - replay ground-truth seam.md for the
#    full evidence; every disposition below cites that note, nothing here is
#    re-derived ─────────────────────────────────────────────────────────────
#
#   1. BASE RESOLUTION. The tree a PR's original worker actually saw is the
#      FORK POINT — `git merge-base <merge>^1 <merge>^2` — not
#      `gh pr view --json baseRefOid` (moves when main advances under an
#      open PR) nor `<merge>^1` (a merge-queue-batched sibling's tip). 21 of
#      60 merged PRs measured disagree across the three candidates. A merge
#      commit with anything other than exactly 2 parents (a squash/rebase
#      merge) has no fork point to resolve and is rejected outright.
#      → `resolve-base` below.
#
#   2. DIFF-SCOPE RULE. Partition every changed path between $BASE and $HEAD
#      into N (solution surface — named in the pre-cut issue text, scored),
#      T (test surface — `*/tests/*` or `test_*`, scored on presence+pass
#      never bytes), X (policy churn — CHANGELOG.md/VERSION/Makefile/
#      Plans-archive/*/the config-registry TSVs/kernel-manifest.txt/
#      feature-manifest.txt — neutral, a KERNEL GATE demanded it, not the
#      issue), or R (residue — anything else). Non-empty R containing
#      unnamed CODE is an item-level REJECTION (tier C, "scoring it measures
#      clairvoyance"); R that is unnamed `.md` propagation ONLY (tier B) is
#      scored neutral like X but stays FLAGGED so a downstream reader knows.
#      Measured corpus yield: 24/46 = 52% survive scope closure on this
#      repo's own single-issue merged PRs — "budget ~2x its target size".
#      → `diff-scope` below; `corpus` applies it per PR.
#
#   3. CONTAMINATION TRAPS, with dispositions (spike Acceptance 3):
#        A. squash merges bundling unrelated refactors — mechanically
#           guarded by the parents==2 check (trap 1) AND
#           closingIssuesReferences==1 (trap 2, the guard that actually
#           fires on this repo's own corpus — a PR closing >1 issue bundles
#           >1 contract by construction).
#        B. formatting-only churn — this repo runs shellcheck only, no
#           formatter; mitigated by scoring diffs with
#           `--ignore-all-space --ignore-blank-lines` downstream (a
#           replay-execute-and-score concern; noted here as the record's
#           `template_sha` exists precisely so a later reader can tell).
#        C. gate-version drift AND prompt-template drift — real, and the one
#           that bites: "never mix trees". `corpus` reads the acceptance
#           recap and the prompt template from the item's OWN base commit,
#           never from today's tree, and records `template_sha` on every
#           record.
#        D. post-hoc issue mutation — the original run writes BACK to its
#           own issue (`Clarified (sweep): …`, `Parked by sweep — …`, cull
#           notes). `T_cut = min(first branch commit author date, PR
#           createdAt)`; any issue comment at/after T_cut carrying an
#           escalation-resume marker is a corpus REJECTION (extraSection —
#           a materially larger prompt than a fresh item gets); a post-cut
#           BODY edit (GraphQL `lastEditedAt >= T_cut`) is likewise a
#           REJECTION, "not a shrug" — with NO retrievable prior revision
#           there is nothing honest to replay against. When the GraphQL
#           check itself cannot be verified (no network in a fixture, an API
#           hiccup), the record is FLAGGED `post-cut-edit-unverified`
#           instead of silently accepted or silently dropped.
#
#   4. THE PR BODY IS THE ONLY DURABLE VERBATIM RECORD of the acceptance
#      list the original worker was actually handed — `pr.sh` splices
#      `acceptance_results[].criterion` back into the PR's `## Acceptance`
#      section verbatim (build.md §3c), which the issue body alone does not
#      carry (demo: issue #1199 had 3 bullets, the worker got 5). Extraction
#      splits each bullet at the LAST ` — ` (an evidence tail may itself
#      contain an em-dash — first-occurrence splitting silently truncates a
#      real criterion). temperloop#1267 tracks that this delimiter is
#      unescaped upstream in pr.sh; `corpus` applies the same last-occurrence
#      heuristic pr.sh's own format guarantees the shape of, and FLAGS
#      (never silently accepts) a bullet with more than one embedded em-dash
#      as `criterion-embedded-em-dash` — the exact ambiguous shape that bit
#      the spike's own demo item.
#
# ── The isolation machinery this file REUSES, not reinvents ────────────────
# `worktree-prepare` below calls `workflows/scripts/build/worktree.sh create`
# UNMODIFIED — no new flag was added there (a flag on always-active shared
# build machinery is a permanent seam `rm -rf` of this module cannot remove,
# contradicting ADR 0027's file-shaped uninstallability) — and then REWINDS
# the freshly created worktree to the item's own $BASE with `git reset
# --hard`. This is safe because every artifact `create` drops is untracked
# (`.build-guard` — the PreToolUse write-jail hook's per-worktree arming
# marker; the `.claude/agents/*` review-lens symlinks) and `reset --hard`
# never touches untracked files, so the worktree the worker's Bash/Edit/Write
# calls run inside stays jailed exactly as it is for a live `/build` item.
# Cleanup (`worktree-teardown`) is `worktree.sh remove`, likewise unmodified.
# NOTHING in worktree.sh or the guard hooks is edited by this file.
#
# ── Usage ────────────────────────────────────────────────────────────────
#   replay.sh resolve-base <repo-root> <merge-commit-sha>
#       Fork-point base resolution (spike fact 1). Pure git, no network.
#
#   replay.sh diff-scope <repo-root> <base-sha> <head-sha> [--issue-text-file <path>]
#       The N/T/X/R partition (spike fact 2). Pure git + text, no network.
#
#   replay.sh corpus --repo <owner/repo> [--repo-root <path>] \
#       [--limit N] [--target N] [--out <file>]
#       Real `gh` reads: selects eligible closed-issue + merged-PR pairs
#       from <repo-root>'s (default: cwd) own history, applying spike facts
#       1-4 above, and prints one schema-shaped JSON record per PR (JSON
#       lines) to stdout or --out. `--target N` sizes the default --limit to
#       N * REPLAY_CORPUS_SAMPLE_MULTIPLIER (the spike's own "budget ~2x"
#       yield guidance) when --limit is not given explicitly. Output is
#       ordered eligible-then-flagged-then-rejected, each tier ascending by
#       scored file count — the smaller/tighter (more single-purpose) an
#       eligible PR's N+T footprint, the earlier it sorts, operationalizing
#       "prefer single-purpose PRs" as a concrete ranking signal on top of
#       the closingIssuesReferences==1 / R-residue gates that already reject
#       the broad, multi-concern PRs structurally (spike: "Tier C is
#       dominated by broad refactor/propagation epics").
#
#   replay.sh preflight --corpus-file <path>
#       THE SPEND GATE (temperloop#1256). Reads an already-computed `corpus`
#       JSONL file (never re-invokes `gh` itself — corpus selection and
#       preflight estimation are separate concerns, and this keeps preflight
#       network-free and deterministically testable) and, before any token is
#       spent, prints eligible-N (CORPUS RECORDS with status eligible or
#       flagged-eligible), the batch-cap-bounded planned-N for THIS
#       invocation, the estimated token cost of that batch, and — genuinely
#       CONSUMING workflows/scripts/model-comparison/stats.sh's `mde`
#       primitive, never a second hand-rolled computation of it — whether
#       this batch's PLANNED PAIRED OUTCOMES can reach
#       MODEL_COMPARISON_MIN_SAMPLE_N (the inconclusive
#       floor `verdict`/`bootstrap-ci` already enforce) at all.
#
#       THE THREE UNITS, AND WHY THEY ARE NOT INTERCHANGEABLE
#       (temperloop#1379 — before it, two of the three were conflated):
#         * CORPUS RECORDS   one merged outcome selected by `corpus`;
#                            eligible_n / planned_records_n count these.
#         * EXECUTED REPLAYS one per record PER ARM. The design is two-arm
#                            (REPLAY_ARMS_N — baseline + candidate), so
#                            planned_replays_n = planned_records_n * 2, and
#                            THAT is what the token estimate (and therefore
#                            REPLAY_PREFLIGHT_CEILING_TOKENS) is budgeted
#                            over. Budgeting one arm under-projects every
#                            batch by exactly 2x.
#         * PAIRED OUTCOMES  one per record present in BOTH arms, i.e. one
#                            delta. planned_pairs_n = planned_records_n.
#                            MODEL_COMPARISON_MIN_SAMPLE_N is a floor on
#                            THIS unit and no other: the report producer
#                            (workflows/scripts/report-producers/
#                            model-comparison, its `pairing` block) feeds
#                            stats.sh exactly this array of paired deltas,
#                            so a reachability verdict computed against any
#                            other unit is answering a different question
#                            than the one the report will ask.
#       Every emitted field names its own unit (the `units` sub-object), so
#       no reader has to infer which of the three a bare number is in.
#
#       THE COST UNIT — ONE UNIT, SHARED WITH THE REPORT (temperloop#1380)
#       This module states no dollar figure (docs/features/model-comparison.md's
#       "stated cost basis" concept, and pipeline-spend-report.sh's own "no
#       dollar constant exists in this loop" convention): the cost basis
#       reported here is REPLAY_COST_BASIS_UNIT — COST-WEIGHTED token units,
#       the SPEND_WEIGHT_* multiply-add over the raw input/cache_read/
#       cache_creation/output classes — which is BYTE-IDENTICAL to the string
#       workflows/scripts/report-producers/model-comparison publishes as its
#       own `cost_basis.unit`. That identity is the point: before #1380 this
#       command said "token_count" (a RAW sum) while the report said
#       cost-weighted, two non-comparable units sharing the word "token", so
#       an operator could not reconcile the batch they authorized here
#       against the figure the report handed back — they differed by ~5.4x at
#       the observed token mix. REPLAY_PREFLIGHT_TOKENS_PER_REPLAY,
#       REPLAY_PREFLIGHT_CEILING_TOKENS and REPLAY_PREFLIGHT_ASSUMED_STDDEV_
#       TOKENS are therefore ALL denominated in that one weighted unit, and
#       the emitted `cost_weights` names the SPEND_WEIGHT_* values the figure
#       was computed under (weighted units are comparable only within one
#       weight-retune epoch).
#
#       THE PER-REPLAY FIGURE: DERIVED WHEN IT CAN BE (temperloop#1555)
#       The estimate is what the ceiling check and the operator confirmation
#       are computed FROM, so where it comes from is a spend-gate correctness
#       property. Until #1555 it was ALWAYS the configured literal — an n=1
#       order-of-magnitude estimate that the first live batch (14 real
#       replays) showed to be 1.49x LOW, so a batch's shown margin against
#       the ceiling was about twice as generous as the truth while the
#       records that said so sat unread in the attribution lake. Now:
#         * With >= REPLAY_PREFLIGHT_DERIVE_MIN_N observed replay-candidate
#           records on this host (emit-model-usage.sh's ADR 0026 lake, seat
#           replay-candidate, usage_source cli-envelope), the figure is their
#           MEAN — each record RE-WEIGHTED from its raw token block with the
#           SPEND_WEIGHT_* values in force NOW, so the derivation survives a
#           weight retune that the records' own stored `weighted_units` would
#           not — and `tokens_per_replay_basis` names the derivation and its n.
#         * With fewer (usually none), behaviour is UNCHANGED: the configured
#           REPLAY_PREFLIGHT_TOKENS_PER_REPLAY literal, with the basis string
#           saying the figure is UNMEASURED on this host. It NEVER presents
#           the literal as measured — a fabricated measurement would be worse
#           than an honest estimate.
#       Because the observed spread is wide (4.8x on the first live batch),
#       a bare point estimate is not the only thing published:
#       `estimated_total_tokens_range` projects the SAME batch at the observed
#       p90 and at the observed maximum and says whether either would breach
#       the ceiling the point estimate cleared. The STOP decision stays the
#       point estimate's — a worst-case budget is a different claim from an
#       expected one, and enforcing the former would refuse batches that are
#       in expectation affordable. `observed_replay_cost` publishes the whole
#       distribution (n, min/p50/p90/max, stddev, spread) on every run,
#       including the "n=0, nothing to derive from" case, so an absence is a
#       positive statement rather than something a reader must infer.
#
#       A projected batch whose estimated cost exceeds
#       REPLAY_PREFLIGHT_CEILING_TOKENS, or that lands while
#       workflows/scripts/build/quota-gate.sh reports "pause" (THIS is the
#       explicit-scope quota-gate consult the item requires — never assumed),
#       STOPS here (`stop:true`, non-zero exit) rather than partway through a
#       later execution step. FAILS CLOSED (`CANNOT_EVALUATE`, non-zero) on
#       an absent/unreadable/empty/malformed corpus file, on a non-integer
#       value for any setting the arithmetic below multiplies or compares
#       (an indeterminate estimate must read as "could not evaluate", never
#       as "evaluated, and fine" — temperloop#1365), on SPEND_WEIGHT_* being
#       missing or malformed (the weights DEFINE the unit the estimate and
#       the ceiling are denominated in — the same refusal the report producer
#       makes, for the same reason), or if the
#       stats.sh mde primitive itself cannot be reached — it never reports a
#       cheap/reachable estimate it did not actually compute. This command
#       does not execute a replay, spawn a candidate model, or score
#       anything — that is replay-execute-and-score (temperloop#1258); it is
#       also never invoked from a scheduled/cron/autonomous entry point
#       (docs/features/model-comparison.md "Inert by design" — ADR 0027):
#       replay batches are operator-initiated only.
#
#   replay.sh worktree-prepare <repo-root> <slug> <base-sha>
#       Create + isolate + rewind the replay worktree (see above). On ANY
#       failure after create, the partially-prepared worktree is torn down
#       before returning non-zero — never left as residue. On success the
#       worktree is left in place (for a later replay-execute-and-score run
#       to use) and printed as {"outcome":"PREPARED",...,"isolation":{...}}.
#
#   replay.sh worktree-teardown <repo-root> <slug>
#       Explicit teardown of a successfully prepared worktree (worktree.sh
#       remove, unmodified).
#
#   replay.sh execute --record <corpus-record-file> --repo-root <path> \
#       --worktree <path> [--provider <name>] [--model <id>] [--repo <o/r>] \
#       ( --candidate-runner <cmd> | --live ) [--out <file>] \
#       [--prompt-out <file>] [--gate-relpath <rel>]
#       THE EXECUTION STEP (temperloop#1258). Runs the candidate headlessly
#       inside an already-prepared replay worktree and emits ONE
#       schema-complete `replay-record-v1` record with `candidate` (provider,
#       model, diff ref, TOKENS, DURATION, outcome) and `score` (the diff
#       partition's outcome, the GATE result, acceptance carry-through,
#       contamination flags) populated.
#
#       WHAT IT REUSES RATHER THAN REIMPLEMENTS:
#         * candidate-session.sh — BOTH halves. Its overlay validator is
#           consulted (`resolve`, whose exit codes 3/4/5 mean absent /
#           unreadable / malformed overlay) and its provider-key health
#           check is run (`preflight`) on EVERY path, stubbed or live, so a
#           broken containment overlay or an unset non-default provider key
#           stops the replay before a token is spent. On `--live` the spawn
#           itself is `candidate-session.sh spawn`, so `env -i` key
#           isolation and the deny-over-allow overlay apply verbatim.
#         * allowlist.sh's `pa_disclose` — a NON-DEFAULT-provider send writes
#           its disclosure-log entry BEFORE the send, and a disclosure that
#           fails REFUSES the send. That ordering is what makes the send-vs-
#           log cross-check in workflows/scripts/validate-provider-disclosure.sh
#           a real invariant rather than a hope: the log can legitimately run
#           AHEAD of the sends, never behind them.
#         * emit-model-usage.sh — the attribution record. No second stream.
#         * score.sh — all scoring, including running the CANDIDATE
#           WORKTREE'S OWN scripts/quality-gates.sh (never today's tree's).
#
#       THREE TERMINAL STATES, deliberately distinguishable (the #1365
#       fail-closed class applied to a scorer: "reporting a score it did not
#       compute" is the failure mode here):
#         exit 0  SCORED — a record whose score.verdict is "pass" OR "fail".
#                 Both are scores. "Scored, and it failed" is exit 0.
#         exit 4  INTEGRATION_ERROR — a record was produced, but the vendor
#                 integration failed (spawn non-zero, timeout, unparseable
#                 envelope, vendor error flag, or an envelope carrying no
#                 usable token block). `candidate.outcome` is
#                 "integration-error", `score.scored` is false and every
#                 score figure is null. score.sh's `aggregate` excludes it
#                 from every quality figure and counts it under
#                 compatibility instead.
#         exit 1  CANNOT_EVALUATE — could not read the record, resolve the
#                 base, reach the worktree, validate the overlay, disclose,
#                 or run the gate. NO record is emitted. This is "couldn't
#                 score", and it is never confused with "scored and failed".
#
#       THE CANDIDATE-RUNNER CONTRACT (the test seam). `--candidate-runner`
#       takes a command string, invoked as `<cmd> <prompt-file>
#       <worktree-path>`; it is expected to do its work inside the worktree
#       and print a `claude -p --output-format json`-shaped envelope on
#       stdout. This is the same test-double convention `CLAUDE_BIN` gives
#       every other spawn site in this repo, hoisted one level so a fixture
#       drives the WHOLE execute path — disclosure, attribution, scoring —
#       against a RECORDED response, with no network and no spend.
#
#   replay.sh verify-clean-parent <repo-root>
#       BACKSTOP post-run probe, NOT the primary isolation control — see its
#       own header comment below. Confirms the PARENT checkout carries no
#       uncommitted residue after replay worktree operations.
#
#   replay.sh schema
#       Prints the canonical, versioned, empty-shaped scored-record —
#       REPLAY_RECORD_SCHEMA_VERSION below — so a downstream consumer
#       (replay-execute-and-score, the comparison report) can build against
#       a fixed shape before execution lands.
#
# Every tunable below is a registered setting (workflows/scripts/config/
# setting-registry.tsv), defaulted in workflows/scripts/build/build.config.sh
# — named symbolically here, never re-valued in prose (§ Named-setting
# convention). The `:=` fallbacks immediately below are this file's own
# non-vendoring-caller layer-6 default, matching that registry exactly.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}' >&2; exit 1; }

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SH="$HERE/../build/worktree.sh"
STATS_SH="$HERE/stats.sh"
QUOTA_GATE_SH="$HERE/../build/quota-gate.sh"
SCORE_SH="$HERE/score.sh"
CANDIDATE_SESSION_SH="$HERE/candidate-session.sh"
ALLOWLIST_LIB="$HERE/allowlist.sh"
EMIT_MODEL_USAGE_SH="$HERE/../emit-model-usage.sh"
# The repo root this file sits under, used ONLY to resolve the default
# attribution raw-lake directory the preflight DERIVATION reads
# (temperloop#1555) when MODEL_USAGE_RAW_DIR is unset — byte-identically the
# `${MODEL_USAGE_RAW_DIR:-<repo>/meta/data/raw}` seam emit-model-usage.sh
# WRITES through and tagging.sh already READS through. Empty when the root
# cannot be resolved (a relocated/symlinked entry point), which the
# derivation treats as "no observed records" and falls back on, never as an
# error: an unresolvable telemetry path must not stop a spend gate.
REPLAY_LAKE_REPO_ROOT="$(cd -P "$HERE/../../.." 2>/dev/null && pwd)" || REPLAY_LAKE_REPO_ROOT=""

# The ADR 0026 seat ROLE NAME this module's attribution records carry. A
# record-vocabulary constant, not an operator-tunable setting (same
# non-registry-row shape as REPLAY_RECORD_SCHEMA_VERSION below), and never a
# machine/operator identifier (ADR 0028).
REPLAY_CANDIDATE_SEAT="replay-candidate"
# The ADR 0028 trusted default provider — the one a send does NOT have to
# disclose. Byte-identical to validate-provider-disclosure.sh's own
# TRUSTED_DEFAULT_PROVIDER and candidate-session.sh's _CS_DEFAULT_PROVIDER;
# a vocabulary constant, not a setting (an operator who could re-point it
# could opt out of disclosure by configuration, which ADR 0028 forbids).
REPLAY_TRUSTED_DEFAULT_PROVIDER="anthropic"

# shellcheck source=../build/build.config.sh
[ -f "$HERE/../build/build.config.sh" ] && . "$HERE/../build/build.config.sh"
: "${REPLAY_CORPUS_LIMIT:=60}"
: "${REPLAY_CORPUS_SAMPLE_MULTIPLIER:=2}"
: "${REPLAY_NAMED_PATH_EXTENSIONS:=py sh mjs md tsv json}"
: "${REPLAY_PUSH_DISABLE_SENTINEL:=replay-worktree-push-disabled://no-remote}"
# preflight (temperloop#1256) — the per-comparison spend gate. All four
# named symbolically here, never re-valued in prose (§ Named-setting
# convention); registered in setting-registry.tsv, defaulted in
# build.config.sh. The three "TOKENS" ones are denominated in COST-WEIGHTED
# token units, never raw (temperloop#1380 — see REPLAY_COST_BASIS_UNIT below
# and build.config.sh's own block comment for the provenance).
: "${REPLAY_PREFLIGHT_BATCH_CAP:=40}"
: "${REPLAY_PREFLIGHT_TOKENS_PER_REPLAY:=470000}"
: "${REPLAY_PREFLIGHT_CEILING_TOKENS:=50000000}"
: "${REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS:=155000}"
# preflight DERIVATION (temperloop#1555) — the minimum number of OBSERVED
# replay-candidate records before the per-replay figure is DERIVED from them
# instead of read off the literal above. Same seam as the four settings
# above: named here, valued only in build.config.sh, registered in
# setting-registry.tsv.
: "${REPLAY_PREFLIGHT_DERIVE_MIN_N:=5}"
# execute (temperloop#1258) — the wall-clock bound on ONE candidate run.
# Named symbolically here, never re-valued in prose; registered in
# setting-registry.tsv, defaulted in build.config.sh.
: "${REPLAY_CANDIDATE_TIMEOUT_SECS:=1800}"
# Non-vendoring-checkout fallback for a setting this file READS but does not
# OWN (registry row's owning-script is build.config.sh; the literal here is
# a byte-identical duplicate of stats.sh's own default — setting-registry.tsv's
# documented "byte-identical fallback duplicated in more than one consuming
# script" convention, same shape as PIPELINE_OPERATOR's duplicate sites).
: "${MODEL_COMPARISON_MIN_SAMPLE_N:=20}"

# schema_version — a record-format constant, not an operator-tunable setting
# (same non-registry-row shape as allowlist.sh's PA_DISCLOSURE_SCHEMA_VERSION).
REPLAY_RECORD_SCHEMA_VERSION="replay-record-v1"

# REPLAY_COST_BASIS_UNIT — THE ONE COST UNIT this module and the comparison
# report both speak (temperloop#1380). A record-vocabulary constant, not an
# operator setting: an operator who could re-point it could make the spend
# gate and the report disagree again by configuration, which is the whole
# defect this closed.
#
# BYTE-IDENTICAL to workflows/scripts/report-producers/model-comparison's own
# `cost_basis.unit` value — the same "documented duplicate in more than one
# consuming script" convention REPLAY_TRUSTED_DEFAULT_PROVIDER above already
# uses, because the two files share no sourceable seam (the producer is
# invoked by the report.d contract with no arguments and sources only
# build.config.sh). The duplication is held honest MECHANICALLY, not by
# review: tests/test_replay_preflight_cost_unit.sh runs BOTH surfaces and
# fails if their emitted strings ever diverge.
#
# WHY THIS UNIT AND NOT RAW TOKENS. Before #1380, preflight emitted
# `cost_basis: "token_count"` — a RAW sum — while the report emitted
# cost-weighted token counts under the same word "token", so the figure an
# operator authorized here was not the figure the report handed back, and
# the two differed by ~5.4x at the observed token mix. Cost-weighted is the
# side to converge on because it is the unit that tracks SPEND (the dominant
# term in a real replay is cache_read, which the SPEND_WEIGHT_* defaults
# price at a tenth) and because the report is the artifact the operator
# ultimately reconciles against.
REPLAY_COST_BASIS_UNIT="cost-weighted-token-units"

# REPLAY_ARMS_N — the comparison is a TWO-ARM design by construction
# (temperloop#1379): every planned corpus record is replayed once in the
# BASELINE arm and once in the CANDIDATE arm, and the comparison report
# (workflows/scripts/report-producers/model-comparison, its `pairing` block)
# intersects the two arms' records by outcome ref to produce exactly ONE
# delta per record. That is a structural fact of the design, not an
# operator-tunable knob — a "one-arm comparison" is not a comparison — so it
# is a constant here and carries no setting-registry row, the same
# non-registry-row shape as the schema version immediately above.
REPLAY_ARMS_N=2

# shellcheck source=../lib/portable-timeout.sh
[ -f "$HERE/../lib/portable-timeout.sh" ] && . "$HERE/../lib/portable-timeout.sh"
if ! command -v run_with_timeout >/dev/null 2>&1; then
  # Defensive only — portable-timeout.sh ships alongside this file in every
  # kernel install; this fallback exists so a missing/corrupt copy degrades
  # to an unbounded call rather than a hard "command not found" abort.
  run_with_timeout() { shift; "$@"; }
fi

# shellcheck source=../lib/spawn-diagnostic.sh
[ -f "$HERE/../lib/spawn-diagnostic.sh" ] && . "$HERE/../lib/spawn-diagnostic.sh"
if ! command -v spawn_failure_detail >/dev/null 2>&1; then
  # DEGRADED, and it SAYS so. spawn-diagnostic.sh ships alongside this file
  # in every kernel install, so reaching this branch means the checkout is
  # structurally off. Re-typing the real two-stream renderer here would be
  # exactly the duplication the lib exists to remove, so this fallback does
  # not pretend to be it: it still names both streams' presence (so a reader
  # is never handed a detail that trails off after a colon — temperloop#1553)
  # while stating plainly that the diagnostic library is missing.
  spawn_failure_detail() {
    local rc="${1:-?}" errfile="${2:-}" envfile="${3:-}" subject="${4:-the runner}"
    printf '%s exited %s [DEGRADED: workflows/scripts/lib/spawn-diagnostic.sh is missing from this checkout, so only raw excerpts are available] stderr: %s | stdout: %s' \
      "$subject" "$rc" \
      "$(head -c 400 "$errfile" 2>/dev/null)" \
      "$(head -c 400 "$envfile" 2>/dev/null)"
  }
fi

# shellcheck source=../lib/cannot-evaluate.sh
[ -f "$HERE/../lib/cannot-evaluate.sh" ] && . "$HERE/../lib/cannot-evaluate.sh"
if ! command -v cannot_evaluate_emit >/dev/null 2>&1; then
  # DEGRADED, never silently duplicated (temperloop#1475 review MEDIUM-3):
  # cannot-evaluate.sh ships alongside this file in every kernel install, so
  # reaching this branch means the checkout is structurally off — e.g. this
  # file reached via a symlink ($HERE resolves the DIRECTORY via `cd -P`,
  # which does not resolve a symlinked *file*, so a symlinked entry point
  # can land here even with a normal lib/ present) — or the lib is genuinely
  # missing. Re-typing the frozen contract's human-line shape here a second
  # time would be exactly the silent duplication this hoist exists to
  # eliminate, so this fallback does NOT pretend to be the real thing: it
  # defines RC_CANNOT_EVALUATE itself (so a caller using the lib's own
  # advertised idiom never hits an unbound-variable abort under `set -u`),
  # still emits the machine JSON so a downstream `.outcome` reader sees
  # CANNOT_EVALUATE, still fails CLOSED on that reserved code, but replaces
  # the human line with an explicit degradation notice naming what's wrong.
  RC_CANNOT_EVALUATE=2
  cannot_evaluate_emit() {
    jq -cn --arg e "$2" '{outcome:"CANNOT_EVALUATE",error:$e}'
    printf '%s: CANNOT-EVALUATE-DEGRADED — workflows/scripts/lib/cannot-evaluate.sh could not be sourced (checkout is structurally off); original message: %s\n' "$1" "$2" >&2
    return "$RC_CANNOT_EVALUATE"
  }
fi

usage() {
  cat <<'EOF' >&2
usage: replay.sh resolve-base <repo-root> <merge-commit-sha>
       replay.sh diff-scope <repo-root> <base-sha> <head-sha> [--issue-text-file <path>]
       replay.sh corpus --repo <owner/repo> [--repo-root <path>] [--limit N] [--target N] [--out <file>]
       replay.sh preflight --corpus-file <path>
       replay.sh worktree-prepare <repo-root> <slug> <base-sha>
       replay.sh worktree-teardown <repo-root> <slug>
       replay.sh execute --record <file> --repo-root <path> --worktree <path>
                         (--candidate-runner <cmd> | --live)
                         [--provider <name>] [--model <id>] [--repo <owner/repo>]
                         [--out <file>] [--prompt-out <file>] [--gate-relpath <rel>]
       replay.sh verify-clean-parent <repo-root>
       replay.sh schema
EOF
}

# ── small shared helpers ─────────────────────────────────────────────────

abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# resolve_repo <path> — must exist, be a git work tree, and be the TOPLEVEL
# (mirrors worktree.sh's own resolve_repo — the deterministic
# `<repo-root>.wt/<slug>` path this file's worktree-prepare also computes
# depends on repo-root being the real toplevel, not a subdir).
resolve_repo() {
  local arg="$1" repo top
  repo="$(abs_dir "$arg")" || { printf 'replay.sh: repo-root %s does not exist\n' "$arg" >&2; return 1; }
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || { printf 'replay.sh: repo-root %s is not inside a git work tree\n' "$arg" >&2; return 1; }
  top="$(abs_dir "$top")"
  [ "$repo" = "$top" ] || { printf 'replay.sh: repo-root %s is not a git toplevel (toplevel is %s)\n' "$arg" "$top" >&2; return 1; }
  printf '%s\n' "$top"
}

# validate_slug <slug> — same closed character set as worktree.sh's own
# validate_slug (plan-schema shape); it feeds an rm-rf'able path there too.
validate_slug() {
  case "$1" in
    *[!a-z0-9-]*|"") printf 'replay.sh: slug %s invalid — must match [a-z0-9-]+\n' "$1" >&2; return 1 ;;
  esac
  return 0
}

# need_operand <flag> <remaining-arg-count> [<next-arg>] — guards every
# `--flag value` parse loop below against the trailing-flag-with-no-value
# shift-2-silently-no-ops-under-no-set-e trap: the caller MUST check this
# before shifting. The OPTIONAL third argument additionally rejects a value
# that is itself flag-like (`--provider --live` must not silently consume
# `--live` as the provider name — temperloop#1342); passing it is
# backward-compatible, an omitted third arg keeps the arity-only check the
# pre-existing call sites were written against.
need_operand() {
  if [ "$2" -lt 2 ]; then
    printf 'replay.sh: %s requires a value\n' "$1" >&2
    return 2
  fi
  if [ "$#" -ge 3 ]; then
    case "$3" in
      --*)
        printf 'replay.sh: %s requires a value, got flag-like %s\n' "$1" "$3" >&2
        return 2
        ;;
    esac
  fi
  return 0
}

# json_arr <arg>... — a bash array of strings -> a compact JSON array.
# Zero-arg call (an empty bucket) prints [] without invoking jq on empty
# stdin, matching the "${arr[@]+"${arr[@]}"}" empty-array-safe call sites
# below.
json_arr() {
  if [ "$#" -eq 0 ]; then printf '[]'; return 0; fi
  printf '%s\n' "$@" | jq -R . | jq -cs .
}

# ── diff-scope's fixed bucket definitions (spike fact 2) — structural to
#    the algorithm itself, not an operator override point, so these stay
#    code rather than a setting-registry row (mirrors the registry's own
#    "Inclusion rule" exclusion for computed/structural values). ──────────

is_test_path() {
  case "$1" in
    */tests/*|test_*|*/test_*) return 0 ;;
    *) return 1 ;;
  esac
}

is_policy_churn_path() {
  case "$1" in
    CHANGELOG.md|VERSION|Makefile) return 0 ;;
    Plans-archive/*) return 0 ;;
    workflows/scripts/config/*-registry.tsv) return 0 ;;
    workflows/scripts/config/gate-paths.tsv) return 0 ;;
    workflows/scripts/kernel/kernel-manifest.txt) return 0 ;;
    docs/features/feature-manifest.txt) return 0 ;;
    *) return 1 ;;
  esac
}

# ── resolve-base (spike fact 1) ──────────────────────────────────────────

cmd_resolve_base() {
  local repo="$1" mc="$2" np base head_sha
  repo="$(resolve_repo "$repo")" || return 1

  if ! git -C "$repo" cat-file -e "$mc" 2>/dev/null; then
    jq -cn --arg mc "$mc" '{outcome:"ERROR",error:("merge commit not found: " + $mc)}'
    return 1
  fi

  np="$(git -C "$repo" cat-file -p "$mc" 2>/dev/null | awk '/^parent/{c++} /^author/{exit} END{print c+0}')"
  if [ "${np:-0}" -ne 2 ]; then
    jq -cn --argjson parents "${np:-0}" \
      '{outcome:"REJECTED",reason:"squash-or-rebase-merge",parents:$parents}'
    return 0
  fi

  base="$(git -C "$repo" merge-base "${mc}^1" "${mc}^2" 2>/dev/null)"
  if [ -z "$base" ]; then
    jq -cn '{outcome:"ERROR",error:"merge-base resolution failed"}'
    return 1
  fi
  head_sha="$(git -C "$repo" rev-parse "${mc}^2" 2>/dev/null)"
  if [ -z "$head_sha" ]; then
    jq -cn '{outcome:"ERROR",error:"could not resolve second parent"}'
    return 1
  fi

  jq -cn --arg base "$base" --arg head "$head_sha" --argjson parents 2 \
    '{outcome:"BASE_RESOLVED",base:$base,head:$head,parents:$parents}'
}

# ── diff-scope (spike fact 2) ────────────────────────────────────────────

cmd_diff_scope() {
  local repo="$1" base="$2" head="$3"; shift 3
  local issue_text_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue-text-file) need_operand --issue-text-file "$#" || return 2; issue_text_file="$2"; shift 2 ;;
      *) printf 'replay.sh diff-scope: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done
  repo="$(resolve_repo "$repo")" || return 1

  # Fail CLOSED on an unresolvable base/head — without this, `git diff
  # --name-only` on a bad rev silently prints nothing (stderr suppressed
  # below), every bucket comes back empty, and the function fell through to
  # {"outcome":"SCOPED","status":"eligible",...} at exit 0: a false "clean
  # scope" verdict for input it never actually read. Same shape as the
  # sibling validator that printed OK when it could not read its input.
  if ! git -C "$repo" cat-file -e "${base}^{commit}" 2>/dev/null; then
    jq -cn --arg b "$base" '{outcome:"ERROR",error:("base commit not found: " + $b)}'
    return 1
  fi
  if ! git -C "$repo" cat-file -e "${head}^{commit}" 2>/dev/null; then
    jq -cn --arg h "$head" '{outcome:"ERROR",error:("head commit not found: " + $h)}'
    return 1
  fi

  local ext_alt named_regex
  ext_alt="$(printf '%s' "$REPLAY_NAMED_PATH_EXTENSIONS" | tr ' ' '|')"
  named_regex="[A-Za-z0-9_./-]+\\.(${ext_alt})"

  local -a named_candidates=()
  if [ -n "$issue_text_file" ] && [ -f "$issue_text_file" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if git -C "$repo" cat-file -e "${base}:${p}" 2>/dev/null; then
        named_candidates+=("$p")
      fi
    done < <(grep -oE "$named_regex" "$issue_text_file" 2>/dev/null | sort -u)
  fi

  local -a n_bucket=() t_bucket=() x_bucket=() r_bucket=() r_md=() r_code=()
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    local is_named=0 f
    for f in ${named_candidates[@]+"${named_candidates[@]}"}; do
      [ "$f" = "$p" ] && { is_named=1; break; }
    done
    if [ "$is_named" -eq 1 ]; then
      n_bucket+=("$p")
    elif is_test_path "$p"; then
      t_bucket+=("$p")
    elif is_policy_churn_path "$p"; then
      x_bucket+=("$p")
    else
      r_bucket+=("$p")
      case "$p" in
        *.md) r_md+=("$p") ;;
        *) r_code+=("$p") ;;
      esac
    fi
  done < <(git -C "$repo" diff --name-only "$base" "$head" 2>/dev/null)

  local status="eligible" reason="" flags_json="[]"
  if [ "${#r_code[@]}" -gt 0 ]; then
    status="rejected"; reason="unnamed-code-residue"
  elif [ "${#r_md[@]}" -gt 0 ]; then
    status="flagged-eligible"; flags_json='["residue-md-only"]'
  fi

  jq -cn \
    --arg status "$status" --arg reason "$reason" --argjson flags "$flags_json" \
    --argjson N "$(json_arr "${n_bucket[@]+"${n_bucket[@]}"}")" \
    --argjson T "$(json_arr "${t_bucket[@]+"${t_bucket[@]}"}")" \
    --argjson X "$(json_arr "${x_bucket[@]+"${x_bucket[@]}"}")" \
    --argjson R "$(json_arr "${r_bucket[@]+"${r_bucket[@]}"}")" \
    '{outcome:"SCOPED",status:$status,reason:$reason,flags:$flags,buckets:{N:$N,T:$T,X:$X,R:$R}}'
}

# ── acceptance-recap extraction (spike fact 4) ───────────────────────────

# extract_acceptance <pr-body-file> — one criterion per line, `## Acceptance`
# section only, checkbox prefix stripped.
extract_acceptance() {
  awk '/^## Acceptance$/{f=1;next} /^## /{f=0} f && /^- \[/' "$1" \
    | sed -E 's/^- \[[x ]\] //'
}

# strip_at_last_emdash <line> — the last-` — `-occurrence split
# (temperloop#1267's documented workaround: pr.sh's own recap delimiter is
# unescaped upstream). Falls back to the raw line if perl is unavailable.
strip_at_last_emdash() {
  if command -v perl >/dev/null 2>&1; then
    printf '%s' "$1" | perl -CSD -pe 's/^(.*) \x{2014} .*$/$1/' 2>/dev/null && return 0
  fi
  printf '%s' "$1"
}

# ── corpus (real `gh` reads; applies spike facts 1-4) ────────────────────

cmd_corpus() {
  local repo_root="." owner_repo="" limit="" target="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) need_operand --repo "$#" || return 2; owner_repo="$2"; shift 2 ;;
      --repo-root) need_operand --repo-root "$#" || return 2; repo_root="$2"; shift 2 ;;
      --limit) need_operand --limit "$#" || return 2; limit="$2"; shift 2 ;;
      --target) need_operand --target "$#" || return 2; target="$2"; shift 2 ;;
      --out) need_operand --out "$#" || return 2; out="$2"; shift 2 ;;
      *) printf 'replay.sh corpus: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done
  [ -n "$owner_repo" ] || { printf 'replay.sh corpus: --repo <owner/repo> is required\n' >&2; return 2; }
  repo_root="$(resolve_repo "$repo_root")" || return 1

  if [ -z "$limit" ]; then
    if [ -n "$target" ]; then
      limit=$(( target * REPLAY_CORPUS_SAMPLE_MULTIPLIER ))
    else
      limit="$REPLAY_CORPUS_LIMIT"
    fi
  fi

  local owner="${owner_repo%%/*}" name="${owner_repo#*/}"

  local pr_list
  pr_list="$(run_with_timeout 30 gh pr list -R "$owner_repo" --state merged --limit "$limit" \
    --json number,mergeCommit,closingIssuesReferences,title,url,createdAt 2>/dev/null)"
  if [ -z "$pr_list" ]; then
    jq -cn '{outcome:"ERROR",error:"gh pr list returned no data"}' >&2
    return 1
  fi

  # empty_record <pr#> <issue-or-empty> <status> <reason> — one shared
  # constructor so every emission path (rejected at any gate, eligible,
  # flagged-eligible) produces the SAME schema shape.
  emit_record() {
    local pr="$1" issue="$2" status="$3" reason="$4" flags="$5" buckets="$6" \
          merge_commit="$7" base="$8" head="$9" title="${10}" scope="${11}" \
          acceptance="${12}" template_sha="${13}" file_count="${14}"
    jq -cn \
      --arg sv "$REPLAY_RECORD_SCHEMA_VERSION" --argjson pr "$pr" --arg issue "$issue" \
      --arg status "$status" --arg reason "$reason" --argjson flags "$flags" \
      --argjson buckets "$buckets" --arg merge_commit "$merge_commit" \
      --arg base "$base" --arg head "$head" --arg title "$title" --arg scope "$scope" \
      --argjson acceptance "$acceptance" --arg template_sha "$template_sha" \
      --argjson file_count "$file_count" \
      '{schema_version:$sv, pr:$pr, issue:(if $issue=="" then null else $issue end),
        merge_commit:(if $merge_commit=="" then null else $merge_commit end),
        base:(if $base=="" then null else $base end), head:(if $head=="" then null else $head end),
        title:$title, scope:$scope, acceptance:$acceptance, notes:"",
        status:$status, reject_reason:$reason, flags:$flags, buckets:$buckets,
        template_sha:(if $template_sha=="" then null else $template_sha end),
        file_count:$file_count,
        worktree:{path:null,branch:null,prepared_at:null},
        candidate:{provider:null,model:null,diff_ref:null},
        score:{verdict:null,acceptance_results:null,gate_result:null}}'
  }
  empty_buckets='{"N":[],"T":[],"X":[],"R":[]}'

  local records_tmp; records_tmp="$(mktemp "${TMPDIR:-/tmp}/replay-corpus.XXXXXX")"

  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    local num mc_oid cir_len title issue_num
    num="$(jq -r '.number // empty' <<<"$pr")"
    [ -n "$num" ] || continue
    mc_oid="$(jq -r '.mergeCommit.oid // empty' <<<"$pr")"
    cir_len="$(jq -r '(.closingIssuesReferences // []) | length' <<<"$pr")"
    title="$(jq -r '.title // empty' <<<"$pr")"

    if [ -z "$mc_oid" ]; then
      emit_record "$num" "" rejected no-merge-commit '[]' "$empty_buckets" "" "" "" "$title" "" '[]' "" null >>"$records_tmp"
      continue
    fi
    if [ "$cir_len" -ne 1 ]; then
      emit_record "$num" "" rejected multi-or-zero-issue-pr '[]' "$empty_buckets" "$mc_oid" "" "" "$title" "" '[]' "" null >>"$records_tmp"
      continue
    fi
    issue_num="$(jq -r '.closingIssuesReferences[0].number' <<<"$pr")"

    local base_out base_outcome
    base_out="$(cmd_resolve_base "$repo_root" "$mc_oid")"
    base_outcome="$(jq -r '.outcome' <<<"$base_out" 2>/dev/null)"
    if [ "$base_outcome" != "BASE_RESOLVED" ]; then
      local br; br="$(jq -r '.reason // "base-resolution-failed"' <<<"$base_out" 2>/dev/null)"
      emit_record "$num" "#$issue_num" rejected "$br" '[]' "$empty_buckets" "$mc_oid" "" "" "$title" "" '[]' "" null >>"$records_tmp"
      continue
    fi
    local base_sha head_sha
    base_sha="$(jq -r .base <<<"$base_out")"
    head_sha="$(jq -r .head <<<"$base_out")"

    local pr_view issue_view
    pr_view="$(run_with_timeout 30 gh pr view "$num" -R "$owner_repo" --json body,title,baseRefName,createdAt 2>/dev/null)"
    issue_view="$(run_with_timeout 30 gh issue view "$issue_num" -R "$owner_repo" --json body,comments,createdAt,title 2>/dev/null)"

    local issue_body_file pr_body_file
    issue_body_file="$(mktemp "${TMPDIR:-/tmp}/replay-issue.XXXXXX")"
    pr_body_file="$(mktemp "${TMPDIR:-/tmp}/replay-pr.XXXXXX")"
    jq -r '.body // empty' <<<"$issue_view" >"$issue_body_file" 2>/dev/null
    jq -r '.body // empty' <<<"$pr_view" >"$pr_body_file" 2>/dev/null

    local scope_out scope_status
    scope_out="$(cmd_diff_scope "$repo_root" "$base_sha" "$head_sha" --issue-text-file "$issue_body_file")"
    scope_status="$(jq -r .status <<<"$scope_out" 2>/dev/null)"
    if [ "$scope_status" = "rejected" ]; then
      local sr; sr="$(jq -r .reason <<<"$scope_out")"
      emit_record "$num" "#$issue_num" rejected "$sr" '[]' "$(jq -c .buckets <<<"$scope_out")" \
        "$mc_oid" "$base_sha" "$head_sha" "$title" "" '[]' "" null >>"$records_tmp"
      rm -f "$issue_body_file" "$pr_body_file"
      continue
    fi
    local flags; flags="$(jq -c .flags <<<"$scope_out")"

    # Trap D — post-hoc issue mutation. T_cut = min(first branch commit
    # author date, PR createdAt).
    local fbc pr_created t_cut
    fbc="$(git -C "$repo_root" log --reverse --format=%aI "${base_sha}..${head_sha}" 2>/dev/null | head -1)"
    pr_created="$(jq -r '.createdAt // empty' <<<"$pr_view")"
    t_cut="$fbc"
    if [ -n "$pr_created" ] && { [ -z "$t_cut" ] || [ "$pr_created" \< "$t_cut" ]; }; then
      t_cut="$pr_created"
    fi

    local escalated=0
    if [ -n "$t_cut" ]; then
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        local c_created c_body
        c_created="$(jq -r '.createdAt // empty' <<<"$c")"
        c_body="$(jq -r '.body // empty' <<<"$c")"
        if [ -n "$c_created" ] && [ "$c_created" \< "$t_cut" ]; then
          continue  # strictly pre-cut — not the resume signal
        fi
        if printf '%s' "$c_body" | grep -E 'Parked by (/?sweep|/?fix|/?triage)|design-fork' >/dev/null; then
          escalated=1
        fi
      done < <(jq -c '(.comments // [])[]' <<<"$issue_view" 2>/dev/null)
    fi
    if [ "$escalated" -eq 1 ]; then
      emit_record "$num" "#$issue_num" rejected escalation-resume-at-or-after-cut '[]' \
        "$(jq -c .buckets <<<"$scope_out")" "$mc_oid" "$base_sha" "$head_sha" "$title" "" '[]' "" null >>"$records_tmp"
      rm -f "$issue_body_file" "$pr_body_file"
      continue
    fi

    # Trap D, second half — a post-cut BODY edit. Best-effort GraphQL probe;
    # an unverifiable result FLAGS rather than silently accepting or
    # silently dropping the item (never a shrug either direction).
    local gql last_edited
    # shellcheck disable=SC2016  # the $owner/$name/$number are GraphQL query
    # variables (literal text gh substitutes via -F), not shell expansions.
    gql="$(run_with_timeout 15 gh api graphql \
      -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){lastEditedAt}}}' \
      -F owner="$owner" -F name="$name" -F number="$issue_num" 2>/dev/null)"
    if [ -n "$gql" ]; then
      last_edited="$(jq -r '.data.repository.issue.lastEditedAt // empty' <<<"$gql" 2>/dev/null)"
      if [ -n "$last_edited" ] && [ -n "$t_cut" ] && ! [ "$last_edited" \< "$t_cut" ]; then
        emit_record "$num" "#$issue_num" rejected post-cut-issue-body-edit '[]' \
          "$(jq -c .buckets <<<"$scope_out")" "$mc_oid" "$base_sha" "$head_sha" "$title" "" '[]' "" null >>"$records_tmp"
        rm -f "$issue_body_file" "$pr_body_file"
        continue
      fi
    else
      flags="$(jq -c '. + ["post-cut-edit-unverified"]' <<<"$flags")"
    fi

    # Acceptance recap (spike fact 4) — last-em-dash split, and a
    # multi-em-dash bullet is FLAGGED (the exact ambiguous shape the spike's
    # own demo item hit), never silently trusted.
    local acc_lines em_dash_risk=0 acceptance_json='[]'
    acc_lines="$(extract_acceptance "$pr_body_file")"
    if [ -n "$acc_lines" ]; then
      local -a acc_arr=()
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        local cnt; cnt="$(printf '%s' "$line" | grep -o ' — ' | wc -l | tr -d ' ')"
        [ "${cnt:-0}" -gt 1 ] && em_dash_risk=1
        acc_arr+=("$(strip_at_last_emdash "$line")")
      done <<<"$acc_lines"
      acceptance_json="$(json_arr "${acc_arr[@]+"${acc_arr[@]}"}")"
    fi
    [ "$em_dash_risk" -eq 1 ] && flags="$(jq -c '. + ["criterion-embedded-em-dash"]' <<<"$flags")"

    local template_sha file_count issue_title
    template_sha="$(git -C "$repo_root" rev-parse "${base_sha}:claude/workflows/build-level.mjs" 2>/dev/null)"
    file_count=$(( $(jq '.buckets.N | length' <<<"$scope_out") + $(jq '.buckets.T | length' <<<"$scope_out") ))
    issue_title="$(jq -r '.title // empty' <<<"$issue_view")"

    emit_record "$num" "#$issue_num" "$scope_status" "" "$flags" "$(jq -c .buckets <<<"$scope_out")" \
      "$mc_oid" "$base_sha" "$head_sha" "$title" "$issue_title" "$acceptance_json" "$template_sha" "$file_count" >>"$records_tmp"

    rm -f "$issue_body_file" "$pr_body_file"
  done < <(jq -c '.[]' <<<"$pr_list")

  # Ranking: eligible, then flagged-eligible, then rejected — each tier
  # ascending by scored file count (null/absent sorts last within its tier),
  # operationalizing "prefer single-purpose PRs" (see the header comment).
  local sort_filter='
    sort_by(
      (if .status=="eligible" then 0 elif .status=="flagged-eligible" then 1 else 2 end),
      (.file_count // 999999)
    ) | .[]'
  if [ -n "$out" ]; then
    jq -c "$sort_filter" -s <"$records_tmp" >"$out" 2>/dev/null
  else
    jq -c "$sort_filter" -s <"$records_tmp" 2>/dev/null
  fi
  rm -f "$records_tmp"
}

# ── preflight (temperloop#1256) — the per-comparison spend gate ─────────

# preflight_cannot_evaluate <error-message> — the ONE emission path for every
# fail-closed case (absent/unreadable/empty/malformed corpus file, or the
# stats.sh mde primitive unreachable), delegating to the shared idiom in
# workflows/scripts/lib/cannot-evaluate.sh (temperloop#1475). Restores the
# distinct human `CANNOT EVALUATE` stderr line this function alone among its
# five siblings had never printed (finding 3: `preflight` emitted the JSON
# verdict but no visible diagnostic) and now returns RC_CANNOT_EVALUATE (2)
# as ITS OWN status — a caller that forgets to branch fails closed rather
# than silently falling through to a false "eligible" verdict for input it
# never actually read (the exact fail-open shape diff-scope's own header
# warns about). Every existing caller already follows it with an explicit
# `return 1`, so this changes no observed behavior.
preflight_cannot_evaluate() {
  cannot_evaluate_emit "replay.sh preflight" "$1"
}

# preflight_observed_cost <weights-json> — THE DERIVATION (temperloop#1555).
#
# Prints ONE JSON object describing the per-EXECUTED-REPLAY cost distribution
# this host has actually OBSERVED, or an object whose `records_n` is 0 when it
# has observed none. NEVER fails, never returns non-zero, and never stops a
# batch: an unreadable/absent/garbled telemetry lake is "no observations",
# which the caller falls back on explicitly and says so — the opposite of the
# temperloop#1365 class, because here the SAFE reading is the conservative
# one (use the configured literal and label it unmeasured), not a fabricated
# measurement.
#
# THE SOURCE. workflows/scripts/emit-model-usage.sh's ADR 0026 attribution
# raw lake — `${MODEL_USAGE_RAW_DIR:-<repo>/meta/data/raw}/model-usage-*.jsonl`
# — filtered to records this module itself wrote: seat REPLAY_CANDIDATE_SEAT,
# usage_source "cli-envelope" (an "unavailable" record is an attribution-only
# row with NO token block: a missing measurement, never a measurement of
# zero), carrying a `tokens` object. That is exactly one record per EXECUTED
# REPLAY, which is the unit the estimate is denominated in.
#
# WHY IT RE-WEIGHTS RATHER THAN READING `weighted_units`. Each lake record
# carries a `weighted_units` convenience field computed under whatever
# SPEND_WEIGHT_* values were in force AT EMIT TIME, and carries no weight
# vector to detect that with (emit-model-usage.sh's own documented caveat).
# Summing those would silently mix retune epochs. The raw `tokens` block is
# the durable, retune-independent figure, so this recomputes every record
# with the weights in force NOW — the same multiply-add, byte-for-byte, that
# the report producer and emit-model-usage.sh use — and the resulting
# distribution is by construction in the one unit REPLAY_COST_BASIS_UNIT
# names.
#
# A line that does not parse is SKIPPED and counted (`unparseable_lines_n`),
# not fatal: the lake is an append-only telemetry stream several unrelated
# writers touch, and a torn line there is no reason to refuse to price a
# batch. The count is published so a reader can see the derivation's own
# input was imperfect.
preflight_observed_cost() {
  local weights_json="$1"
  local lake_dir
  lake_dir="${MODEL_USAGE_RAW_DIR:-$REPLAY_LAKE_REPO_ROOT/meta/data/raw}"

  local empty_out
  empty_out="$(jq -cn --arg dir "$lake_dir" \
    '{lake_dir:$dir, records_n:0, unparseable_lines_n:0,
      mean:null, min:null, p50:null, p90:null, max:null, stddev:null, spread_ratio:null}')"

  if [ -z "$lake_dir" ] || [ ! -d "$lake_dir" ]; then
    printf '%s\n' "$empty_out"
    return 0
  fi

  # bash 3.2: no `shopt -s nullglob` reliance and no mapfile — an unmatched
  # glob expands to itself, which `[ -f ]` then rejects.
  local f found=0
  local cat_tmp; cat_tmp="$(mktemp "${TMPDIR:-/tmp}/replay-lake-XXXXXX")" || { printf '%s\n' "$empty_out"; return 0; }
  for f in "$lake_dir"/model-usage-*.jsonl; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    found=1
    cat "$f" >>"$cat_tmp" 2>/dev/null || true
  done
  if [ "$found" -eq 0 ]; then
    rm -f "$cat_tmp"
    printf '%s\n' "$empty_out"
    return 0
  fi

  local out
  out="$(jq -sR --arg dir "$lake_dir" --arg seat "$REPLAY_CANDIDATE_SEAT" \
    --argjson w "$weights_json" '
    # The SPEND_WEIGHT_* multiply-add, byte-for-byte emit-model-usage.sh'"'"'s
    # and report-producers/model-comparison'"'"'s own expression.
    def wu:
      if (.tokens | type) != "object" then null
      else ((((.tokens.input // 0) * $w.input)
           + ((.tokens.cache_read // 0) * $w.cache_read)
           + ((.tokens.cache_creation // 0) * $w.cache_creation)
           + ((.tokens.output // 0) * $w.output)) | floor)
      end;
    def pctile($p): . as $s | ($s | length) as $n
      | if $n == 0 then null
        else $s[ ([(($p * $n) | ceil) - 1, 0] | max) ] end;
    split("\n") | map(select(length > 0))                                   as $lines
    | ($lines | map(fromjson? // empty))                                    as $parsed
    | (($lines | length) - ($parsed | length))                              as $unparseable
    | ($parsed | map(select(type == "object"
                            and .seat == $seat
                            and .usage_source == "cli-envelope"
                            and ((.tokens | type) == "object"))))           as $recs
    | ($recs | map(wu) | map(select(. != null and . >= 0)) | sort)          as $u
    | ($u | length)                                                         as $n
    | (if $n == 0 then null else (($u | add) / $n) end)                     as $mean
    | (if $n == 0 then null
       else (((($u | map(. - $mean) | map(. * .) | add) / $n) | sqrt)) end)  as $sd
    | {lake_dir: $dir,
       records_n: $n,
       unparseable_lines_n: $unparseable,
       mean: (if $mean == null then null else ($mean | floor) end),
       min:  (if $n == 0 then null else $u[0] end),
       p50:  ($u | pctile(0.5)),
       p90:  ($u | pctile(0.9)),
       max:  (if $n == 0 then null else $u[$n - 1] end),
       stddev: (if $sd == null then null else (($sd * 10 | round) / 10) end),
       spread_ratio: (if $n == 0 or $u[0] <= 0 then null
                      else ((($u[$n - 1] / $u[0]) * 100 | round) / 100) end)}
    ' <"$cat_tmp" 2>/dev/null)"
  rm -f "$cat_tmp"

  if [ -z "$out" ] || ! jq -e 'type=="object" and has("records_n")' >/dev/null 2>&1 <<<"$out"; then
    printf '%s\n' "$empty_out"
    return 0
  fi
  printf '%s\n' "$out"
  return 0
}

cmd_preflight() {
  local corpus_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --corpus-file) need_operand --corpus-file "$#" || return 2; corpus_file="$2"; shift 2 ;;
      *) printf 'replay.sh preflight: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done

  if [ -z "$corpus_file" ]; then
    preflight_cannot_evaluate "no --corpus-file given"
    return 1
  fi
  # `-f` rejects a missing path AND a directory/non-regular-file (the
  # portable stand-in for "unreadable" that doesn't depend on OS permission
  # bits, which don't reliably deny access to a root-run test process).
  if [ ! -f "$corpus_file" ] || [ ! -r "$corpus_file" ]; then
    preflight_cannot_evaluate "corpus file not found or not a readable regular file: $corpus_file"
    return 1
  fi

  local n_lines
  n_lines="$(grep -c . "$corpus_file" 2>/dev/null || true)"
  case "$n_lines" in ''|*[!0-9]*) n_lines=0 ;; esac
  if [ "$n_lines" -eq 0 ]; then
    preflight_cannot_evaluate "corpus file has no records: $corpus_file"
    return 1
  fi

  # Every line must parse as a JSON object carrying a `status` — a single
  # unparseable/malformed line CANNOT-EVALUATEs the whole file rather than
  # being silently skipped, which would under-report eligible-N off input
  # this command never actually finished reading (same fail-closed shape as
  # diff-scope's own base/head existence check).
  local eligible_n=0 line status
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! jq -e 'type=="object" and has("status")' >/dev/null 2>&1 <<<"$line"; then
      preflight_cannot_evaluate "malformed corpus record (not a JSON object with a status field): $line"
      return 1
    fi
    status="$(jq -r .status <<<"$line" 2>/dev/null)"
    case "$status" in
      eligible|flagged-eligible) eligible_n=$((eligible_n + 1)) ;;
    esac
  done <"$corpus_file"

  # FAIL CLOSED on a setting this arithmetic cannot evaluate (temperloop#1379,
  # guarding the temperloop#1365 class). Everything below multiplies and
  # compares these four; a non-integer value (a typo, a "150k", an
  # accidentally-exported empty string) would either silently evaluate to 0 —
  # producing a zero-cost estimate that sails under the ceiling — or make
  # `[ -gt ]` compare garbage. An estimate that could not be EVALUATED must
  # never render as "evaluated, and fine".
  local _s _v
  for _s in REPLAY_PREFLIGHT_BATCH_CAP REPLAY_PREFLIGHT_TOKENS_PER_REPLAY \
            REPLAY_PREFLIGHT_CEILING_TOKENS MODEL_COMPARISON_MIN_SAMPLE_N \
            REPLAY_PREFLIGHT_DERIVE_MIN_N; do
    _v="${!_s-}"
    case "$_v" in
      ''|*[!0-9]*)
        preflight_cannot_evaluate "$_s is not a non-negative integer (\"$_v\") — the batch estimate and the significance floor cannot be evaluated against it"
        return 1 ;;
    esac
  done

  # FAIL CLOSED on the WEIGHTS that DEFINE the unit (temperloop#1380, same
  # temperloop#1365 class as the loop above). REPLAY_PREFLIGHT_TOKENS_PER_
  # REPLAY and REPLAY_PREFLIGHT_CEILING_TOKENS are denominated in
  # REPLAY_COST_BASIS_UNIT — cost-weighted token units under SPEND_WEIGHT_* —
  # so if those weights cannot be resolved, the numbers below have no defined
  # unit and neither the estimate nor the operator's reconciliation against
  # the report means anything. Refuse rather than emit a figure in an
  # undefined unit. Byte-identical predicate to
  # report-producers/model-comparison's own weights check, which refuses for
  # exactly this reason ("a cost figure computed with weights it could not
  # resolve") — the two surfaces must fail on the same input, or one of them
  # would report a unit the other could not.
  local _w
  for _w in "${SPEND_WEIGHT_INPUT-}" "${SPEND_WEIGHT_CACHE_READ-}" \
            "${SPEND_WEIGHT_CACHE_CREATE-}" "${SPEND_WEIGHT_OUTPUT-}"; do
    case "$_w" in
      ''|*[!0-9.]*|*.*.*)
        preflight_cannot_evaluate "the SPEND_WEIGHT_* settings are missing or malformed (\"$_w\") — this estimate is denominated in cost-weighted token units, so a batch cost cannot be evaluated, nor reconciled against the comparison report, in a unit whose weights could not be resolved"
        return 1 ;;
    esac
  done
  local cost_weights_json
  cost_weights_json="$(jq -cn \
    --argjson i "$SPEND_WEIGHT_INPUT" --argjson cr "$SPEND_WEIGHT_CACHE_READ" \
    --argjson cc "$SPEND_WEIGHT_CACHE_CREATE" --argjson o "$SPEND_WEIGHT_OUTPUT" \
    '{input:$i, cache_read:$cr, cache_creation:$cc, output:$o}' 2>/dev/null)" || cost_weights_json=""
  if [ -z "$cost_weights_json" ]; then
    preflight_cannot_evaluate "the SPEND_WEIGHT_* settings did not resolve to four JSON numbers — refusing to state a cost basis whose weights could not be published"
    return 1
  fi

  # ── THE THREE UNITS (temperloop#1379) ──────────────────────────────────
  #   planned_records  CORPUS RECORDS this invocation plans to replay.
  #   planned_replays  EXECUTED REPLAYS = planned_records * REPLAY_ARMS_N.
  #                    Every record is replayed in BOTH arms, so this — not
  #                    the record count — is what the token budget is over.
  #   planned_pairs    PAIRED OUTCOMES = planned_records (one delta per
  #                    record present in both arms). This is the unit
  #                    MODEL_COMPARISON_MIN_SAMPLE_N is a floor on, matching
  #                    the report producer's own `pairing.paired_outcomes_n`
  #                    → stats.sh `verdict --deltas` path exactly.
  #
  # Batch cap: bounds this invocation's planned RECORDS. A corpus larger than
  # the cap is spent across more than one invocation — which is why
  # eligible_pairs (the whole pool's pairs) is reported alongside
  # planned_pairs, and why the unreachable reason distinguishes "this batch
  # can't reach the floor" from "the corpus can't, ever".
  local planned_records="$eligible_n" batch_cap_applied=false
  if [ "$planned_records" -gt "$REPLAY_PREFLIGHT_BATCH_CAP" ]; then
    planned_records="$REPLAY_PREFLIGHT_BATCH_CAP"
    batch_cap_applied=true
  fi
  local planned_replays=$(( planned_records * REPLAY_ARMS_N ))
  local planned_pairs="$planned_records"
  local eligible_pairs="$eligible_n"

  # ── THE PER-REPLAY FIGURE: DERIVED WHEN IT CAN BE, LITERAL WHEN IT CANNOT
  #    (temperloop#1555) ───────────────────────────────────────────────────
  # This number is what the ceiling check below and the operator confirmation
  # downstream are computed FROM, so its provenance is a spend-gate
  # correctness property, not a disclosure nicety. Until #1555 it was always
  # the configured literal — an n=1 order-of-magnitude estimate that the first
  # live batch (14 real replays) showed to be 1.49x LOW, so a batch's shown
  # margin against the ceiling was ~2x more generous than the truth while
  # nothing consumed the records that said so.
  #
  # TWO MODES, AND THE BASIS STRING ALWAYS NAMES WHICH IS IN FORCE:
  #   derived-from-observed-records  >= REPLAY_PREFLIGHT_DERIVE_MIN_N observed
  #                                  replay-candidate records exist on this
  #                                  host: the figure is their MEAN, and the
  #                                  basis names n.
  #   configured-literal             fewer than that (usually none): the
  #                                  REPLAY_PREFLIGHT_TOKENS_PER_REPLAY
  #                                  literal, with the basis saying the figure
  #                                  is UNMEASURED on this host. It never
  #                                  presents the literal as measured — that
  #                                  is the one thing this must not do, since
  #                                  a fabricated "measurement" is worse than
  #                                  an honest estimate.
  local observed_json
  observed_json="$(preflight_observed_cost "$cost_weights_json")"
  jq -e 'type=="object" and has("records_n")' >/dev/null 2>&1 <<<"$observed_json" \
    || observed_json='{"lake_dir":null,"records_n":0,"unparseable_lines_n":0,"mean":null,"min":null,"p50":null,"p90":null,"max":null,"stddev":null,"spread_ratio":null}'
  local observed_n observed_mean
  observed_n="$(jq -r '.records_n // 0' <<<"$observed_json" 2>/dev/null)"
  case "$observed_n" in ''|*[!0-9]*) observed_n=0 ;; esac
  observed_mean="$(jq -r '.mean // ""' <<<"$observed_json" 2>/dev/null)"
  case "$observed_mean" in ''|*[!0-9]*) observed_mean="" ;; esac

  local tokens_per_replay="$REPLAY_PREFLIGHT_TOKENS_PER_REPLAY"
  local tokens_per_replay_mode="configured-literal"
  local derive_sufficient=false
  if [ "$REPLAY_PREFLIGHT_DERIVE_MIN_N" -gt 0 ] \
     && [ "$observed_n" -ge "$REPLAY_PREFLIGHT_DERIVE_MIN_N" ] \
     && [ -n "$observed_mean" ] && [ "$observed_mean" -gt 0 ]; then
    tokens_per_replay="$observed_mean"
    tokens_per_replay_mode="derived-from-observed-records"
    derive_sufficient=true
  fi

  local est_tokens=$(( planned_replays * tokens_per_replay ))
  local ceiling_exceeded=false
  [ "$est_tokens" -gt "$REPLAY_PREFLIGHT_CEILING_TOKENS" ] && ceiling_exceeded=true

  # Significance reachability is asked in PAIRS — the same unit the report
  # producer applies MODEL_COMPARISON_MIN_SAMPLE_N to. Asking it in records
  # or in one arm's replay count answers a different question than the one
  # the report will ask.
  local reachable=false reachable_reason=""
  if [ "$eligible_n" -eq 0 ]; then
    reachable_reason="eligible-N is 0 corpus records — no usable replay candidates in this corpus, so no paired outcome can be produced at all"
  elif [ "$planned_pairs" -ge "$MODEL_COMPARISON_MIN_SAMPLE_N" ]; then
    reachable=true
  elif [ "$eligible_pairs" -ge "$MODEL_COMPARISON_MIN_SAMPLE_N" ]; then
    reachable_reason="this batch plans $planned_pairs paired outcomes ($planned_records corpus records x $REPLAY_ARMS_N arms = $planned_replays executed replays), below MODEL_COMPARISON_MIN_SAMPLE_N ($MODEL_COMPARISON_MIN_SAMPLE_N) — the corpus's $eligible_pairs eligible pairs could reach the floor only across more than one invocation (REPLAY_PREFLIGHT_BATCH_CAP=$REPLAY_PREFLIGHT_BATCH_CAP binds here), never from this batch alone"
  else
    reachable_reason="this batch plans $planned_pairs paired outcomes ($planned_records corpus records x $REPLAY_ARMS_N arms = $planned_replays executed replays), below MODEL_COMPARISON_MIN_SAMPLE_N ($MODEL_COMPARISON_MIN_SAMPLE_N), and the whole corpus offers only $eligible_pairs eligible pairs — the verdict would always be inconclusive at this N"
  fi

  # The MDE disclosure — genuinely CONSUMES stats.sh's own `mde` primitive
  # (never a second, hand-rolled computation of it). Its n is this batch's
  # PLANNED PAIRS, the same n stats.sh will see downstream: feeding it the
  # larger record/pool count would disclose a smaller (more flattering)
  # detectable effect than the run can actually deliver. No real per-replay
  # cost variance exists yet (replay execution is #1258's job), so
  # REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS stands in as a config-named,
  # operator-tunable placeholder pending real historical variance.
  local mde_json="null" mde_n_json="null"
  if [ "$planned_pairs" -ge 1 ]; then
    local mde_out mde_rc=0
    mde_out="$(bash "$STATS_SH" mde --n "$planned_pairs" --stddev "$REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS" 2>&1)" || mde_rc=$?
    if [ "$mde_rc" -ne 0 ] || ! jq -e . >/dev/null 2>&1 <<<"$mde_out"; then
      preflight_cannot_evaluate "could not reach the stats.sh mde primitive: $mde_out"
      return 1
    fi
    mde_json="$mde_out"
    mde_n_json="$planned_pairs"
  fi

  # THE QUOTA-GATE CONSULT — explicit scope (temperloop#1256), not assumed.
  # quota-gate.sh is FAIL OPEN by contract (its own header): an "unavailable"
  # verdict here must NOT stop this batch — only an explicit "pause" does.
  local quota_json quota_action
  quota_json="$(bash "$QUOTA_GATE_SH" 2>/dev/null)"
  [ -n "$quota_json" ] && jq -e . >/dev/null 2>&1 <<<"$quota_json" \
    || quota_json='{"action":"unavailable","reason":"quota-gate.sh produced no parseable output"}'
  quota_action="$(jq -r '.action // "unavailable"' <<<"$quota_json" 2>/dev/null)"
  [ -n "$quota_action" ] || quota_action="unavailable"

  local stop=false stop_reason=""
  if [ "$ceiling_exceeded" = "true" ]; then
    stop=true; stop_reason="ceiling_exceeded"
  elif [ "$quota_action" = "pause" ]; then
    stop=true; stop_reason="quota_paused"
  fi

  # ── THE DISPERSION SIGNAL (temperloop#1555) ───────────────────────────
  # The observed per-replay cost spans 4.8x (309,700..1,476,744 over the
  # first live batch's 14 replays), so a bare point estimate — mean or
  # literal — is a materially misleading thing to authorize spend against:
  # a corpus that happens to hold the large records can cost far more than
  # the projection while every number on screen still says "fine". This
  # block projects the SAME batch at the observed p90 and at the observed
  # MAXIMUM alongside the point estimate, and states plainly whether either
  # of those would breach the ceiling the point estimate cleared.
  #
  # THE STOP DECISION IS DELIBERATELY STILL THE POINT ESTIMATE'S. Stopping
  # on a max-case projection would refuse batches that are, in expectation,
  # affordable — a worst-case budget is not the same claim as an expected
  # one, and conflating them is the mirror image of the defect this closed.
  # The high projections are DISCLOSED, never enforced; an operator who
  # wants worst-case enforcement lowers REPLAY_PREFLIGHT_CEILING_TOKENS
  # with these figures in view.
  local range_json
  range_json="$(jq -cn \
    --argjson obs "$observed_json" --argjson replays "$planned_replays" \
    --argjson point "$est_tokens" --argjson per_replay "$tokens_per_replay" \
    --argjson ceiling "$REPLAY_PREFLIGHT_CEILING_TOKENS" \
    --argjson derived "$derive_sufficient" \
    --arg unit "$REPLAY_COST_BASIS_UNIT" '
    (if $derived and ($obs.p90 != null) then ($obs.p90 * $replays) else null end) as $hi90
    | (if $derived and ($obs.max != null) then ($obs.max * $replays) else null end) as $himax
    | (if $derived and ($obs.min != null) then ($obs.min * $replays) else null end) as $lo
    | {basis: ("a single point estimate is not the only thing shown, deliberately: the observed per-executed-replay cost spans a wide range, so this projects the SAME planned batch at the observed p90 and maximum as well as at the point estimate. All figures are in " + $unit + " over " + ($replays|tostring) + " executed replays. The ceiling check and the operator confirmation are computed from the POINT figure only — the high figures are a disclosure, never an enforcement"),
       available: $derived,
       unavailable_reason: (if $derived then null
                            else "no observed per-replay distribution exists on this host, so no dispersion can be stated — the point figure is the configured literal and carries no variance at all (one hand-transcribed constant cannot express a range). See observed_replay_cost.insufficient_reason" end),
       point_total: $point, point_per_replay: $per_replay,
       low_total_at_observed_min: $lo, low_per_replay: (if $derived then $obs.min else null end),
       high_total_at_observed_p90: $hi90, high_per_replay_p90: (if $derived then $obs.p90 else null end),
       high_total_at_observed_max: $himax, high_per_replay_max: (if $derived then $obs.max else null end),
       observed_spread_ratio: (if $derived then $obs.spread_ratio else null end),
       ceiling_tokens: $ceiling,
       exceeds_ceiling_at_point: ($point > $ceiling),
       exceeds_ceiling_at_p90: (if $hi90 == null then null else ($hi90 > $ceiling) end),
       exceeds_ceiling_at_max: (if $himax == null then null else ($himax > $ceiling) end),
       statement:
         (if ($derived | not) then "no dispersion available — see unavailable_reason"
          elif ($hi90 != null and $hi90 > $ceiling and $point <= $ceiling)
            then ("HEADROOM IS THINNER THAN THE POINT ESTIMATE SUGGESTS: this batch clears the ceiling at the projected mean (" + ($point|tostring) + " of " + ($ceiling|tostring) + ") but would BREACH it at the observed p90 per-replay cost (" + ($hi90|tostring) + "). A corpus weighted toward large records can cost well above the projection")
          elif ($himax != null and $himax > $ceiling and $point <= $ceiling)
            then ("this batch clears the ceiling at the projected mean and at the observed p90, but a worst case at the observed MAXIMUM per-replay cost (" + ($himax|tostring) + ") would exceed it (" + ($ceiling|tostring) + ")")
          else ("the projection clears the ceiling across the whole observed range: worst case at the observed maximum per-replay cost is " + ($himax|tostring) + " against a ceiling of " + ($ceiling|tostring)) end)}
    ' 2>/dev/null)"
  [ -n "$range_json" ] || range_json='null'

  # THE OBSERVED-DISTRIBUTION DISCLOSURE — published on EVERY run, whether it
  # was sufficient to derive from or not, so "no observations" is a positive
  # statement in the output rather than an absence a reader has to infer.
  local observed_block_json
  observed_block_json="$(jq -cn \
    --argjson obs "$observed_json" --argjson min_n "$REPLAY_PREFLIGHT_DERIVE_MIN_N" \
    --argjson derived "$derive_sufficient" --arg seat "$REPLAY_CANDIDATE_SEAT" \
    --arg unit "$REPLAY_COST_BASIS_UNIT" --argjson literal "$REPLAY_PREFLIGHT_TOKENS_PER_REPLAY" '
    $obs + {
      basis: ("the per-EXECUTED-REPLAY cost this host has actually observed: every record in the emit-model-usage.sh attribution raw lake with seat \"" + $seat + "\" and usage_source \"cli-envelope\", RE-WEIGHTED from its own raw token block with the SPEND_WEIGHT_* values in force now (never the stored weighted_units field, which was computed under whatever weights were in force at emit time and carries no weight vector to detect a retune with). One such record is one executed replay, which is exactly the unit the estimate is denominated in: " + $unit),
      seat: $seat,
      usage_source: "cli-envelope",
      min_n_to_derive: $min_n,
      min_n_setting: "REPLAY_PREFLIGHT_DERIVE_MIN_N",
      sufficient_to_derive: $derived,
      configured_literal: $literal,
      insufficient_reason:
        (if $derived then null
         elif $min_n == 0 then "REPLAY_PREFLIGHT_DERIVE_MIN_N is 0, which forces the configured literal regardless of how many records exist"
         elif $obs.records_n == 0 then ("no observed replay-candidate records were found under " + ($obs.lake_dir // "the attribution raw lake") + " — this host has never executed a replay whose token usage was captured, so there is nothing to derive from")
         else (($obs.records_n|tostring) + " observed record(s) is below REPLAY_PREFLIGHT_DERIVE_MIN_N (" + ($min_n|tostring) + ") — too few for a mean worth authorizing spend against, given the width of the observed spread") end)}
    ' 2>/dev/null)"
  [ -n "$observed_block_json" ] || observed_block_json="$observed_json"

  # THE BASIS STRING — the one field that must never lie about where the
  # number in force came from.
  local basis_str
  if [ "$derive_sufficient" = "true" ]; then
    basis_str="$(jq -rn --argjson obs "$observed_json" --argjson per "$tokens_per_replay" \
      --argjson literal "$REPLAY_PREFLIGHT_TOKENS_PER_REPLAY" --arg unit "$REPLAY_COST_BASIS_UNIT" '
      "DERIVED from this host'"'"'s own observed records (n=" + ($obs.records_n|tostring) + "), NOT the configured literal. "
      + "The figure in force, " + ($per|tostring) + " " + $unit + " per executed replay, is the MEAN over those "
      + ($obs.records_n|tostring) + " replay-candidate model-usage records, each re-weighted from its raw token block "
      + "with the SPEND_WEIGHT_* values in force now (so the derivation is retune-independent). "
      + "It is a MEAN, not a bound: the observed range is " + ($obs.min|tostring) + ".." + ($obs.max|tostring)
      + " (" + (($obs.spread_ratio // 0)|tostring) + "x spread, p90 " + ($obs.p90|tostring) + ", stddev "
      + (($obs.stddev // 0)|tostring) + "), so a corpus weighted toward large records can cost well above this "
      + "projection — estimated_total_tokens_range projects the same batch at the observed p90 and maximum for exactly that reason. "
      + "The configured REPLAY_PREFLIGHT_TOKENS_PER_REPLAY literal (" + ($literal|tostring) + ") was NOT used."' 2>/dev/null)"
  fi
  if [ -z "${basis_str:-}" ]; then
    basis_str="UNMEASURED ON THIS HOST — $(jq -r '.insufficient_reason // "no observed records"' <<<"$observed_block_json" 2>/dev/null). Falling back to the configured REPLAY_PREFLIGHT_TOKENS_PER_REPLAY literal, an ESTIMATE grounded in a SINGLE observed live replay (n=1, temperloop#1380: raw 2,506,371 / cost-weighted 466,530 under the default weights, rounded up), NOT derived from this corpus, NOT derived from any record on this machine, and NOT a fitted average — one sample carries no variance, so treat it as order-of-magnitude, and note that the one live batch since (14 replays) came in ~1.49x ABOVE it. This field states the mode in force on every run: it is saying the number is UNMEASURED here, never presenting the literal as though it were measured."
  fi

  jq -cn \
    --argjson eligible_n "$eligible_n" --argjson planned_n "$planned_records" \
    --argjson planned_records_n "$planned_records" --argjson planned_replays_n "$planned_replays" \
    --argjson planned_pairs_n "$planned_pairs" --argjson eligible_pairs_n "$eligible_pairs" \
    --argjson arms_n "$REPLAY_ARMS_N" \
    --argjson batch_cap "$REPLAY_PREFLIGHT_BATCH_CAP" --argjson batch_cap_applied "$batch_cap_applied" \
    --arg cost_basis "$REPLAY_COST_BASIS_UNIT" \
    --argjson cost_weights "$cost_weights_json" \
    --argjson tokens_per_replay "$tokens_per_replay" \
    --arg tokens_per_replay_mode "$tokens_per_replay_mode" \
    --arg tokens_per_replay_basis "$basis_str" \
    --argjson configured_tokens_per_replay "$REPLAY_PREFLIGHT_TOKENS_PER_REPLAY" \
    --argjson observed_replay_cost "$observed_block_json" \
    --argjson estimated_range "$range_json" \
    --argjson estimated_total_tokens "$est_tokens" \
    --argjson ceiling_tokens "$REPLAY_PREFLIGHT_CEILING_TOKENS" --argjson ceiling_exceeded "$ceiling_exceeded" \
    --argjson min_sample_n "$MODEL_COMPARISON_MIN_SAMPLE_N" --argjson significance_reachable "$reachable" \
    --arg reachable_reason "$reachable_reason" --argjson mde "$mde_json" --argjson mde_n "$mde_n_json" \
    --argjson assumed_stddev_tokens "$REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS" \
    --argjson quota "$quota_json" --argjson stop "$stop" --arg stop_reason "$stop_reason" \
    '{outcome:"PREFLIGHT",
      units:{
        basis: "THREE non-interchangeable COUNT units (temperloop#1379) plus ONE cost unit (temperloop#1380). One CORPUS RECORD is one merged outcome; it is replayed in BOTH arms, so 1 planned record = arms_n executed replays = 1 paired outcome. The cost estimate is budgeted over EXECUTED REPLAYS (both arms) and is denominated in cost_basis below — the SAME unit report-producers/model-comparison publishes, never a raw token sum; MODEL_COMPARISON_MIN_SAMPLE_N is a floor on PAIRED OUTCOMES, the same unit the comparison report feeds stats.sh (report-producers/model-comparison, its pairing block)",
        eligible_n: "corpus_records", planned_n: "corpus_records",
        planned_records_n: "corpus_records", planned_replays_n: "executed_replays",
        planned_pairs_n: "paired_outcomes", eligible_pairs_n: "paired_outcomes",
        batch_cap: "corpus_records",
        estimated_total_tokens: $cost_basis,
        tokens_per_replay_estimate: ($cost_basis + " per executed_replay"),
        observed_replay_cost: ($cost_basis + " per executed_replay (records_n is a COUNT of observed executed replays, not a cost)"),
        estimated_total_tokens_range: $cost_basis,
        ceiling_tokens: $cost_basis,
        assumed_stddev_tokens: $cost_basis,
        min_sample_n: "paired_outcomes", mde_n: "paired_outcomes"},
      arms_n:$arms_n,
      eligible_n:$eligible_n, planned_n:$planned_n,
      planned_records_n:$planned_records_n, planned_replays_n:$planned_replays_n,
      planned_pairs_n:$planned_pairs_n, eligible_pairs_n:$eligible_pairs_n,
      batch_cap:$batch_cap, batch_cap_applied:$batch_cap_applied,
      cost_basis:$cost_basis,
      cost_weights:$cost_weights,
      cost_basis_statement: ("This batch estimate is denominated in " + $cost_basis + " — the SPEND_WEIGHT_* multiply-add over the raw input/cache_read/cache_creation/output classes, NOT a raw token sum, and NOT metered dollars (no vendor cost figure exists at pre-flight) and NOT a subscription-usage share. It is BYTE-IDENTICALLY the unit workflows/scripts/report-producers/model-comparison publishes as its own cost_basis.unit, so the batch an operator authorizes here and the figure that report hands back are the same unit and can be reconciled directly (temperloop#1380 — before it, this side reported a RAW sum under the same word \"token\", ~5.4x apart at the observed mix). Cost-weighted figures are comparable only WITHIN one SPEND_WEIGHT_* retune epoch; cost_weights above names the values in force for this run."),
      tokens_per_replay_estimate:$tokens_per_replay,
      tokens_per_replay_mode:$tokens_per_replay_mode,
      tokens_per_replay_basis:$tokens_per_replay_basis,
      configured_tokens_per_replay:$configured_tokens_per_replay,
      observed_replay_cost:$observed_replay_cost,
      estimated_total_tokens_range:$estimated_range,
      estimated_total_tokens:$estimated_total_tokens, estimated_cost:$estimated_total_tokens,
      ceiling_tokens:$ceiling_tokens, ceiling_exceeded:$ceiling_exceeded,
      min_sample_n:$min_sample_n, significance_reachable:$significance_reachable,
      reachable_reason:$reachable_reason, assumed_stddev_tokens:$assumed_stddev_tokens,
      mde:$mde, mde_n:$mde_n,
      quota:$quota, stop:$stop, stop_reason:$stop_reason,
      confirmation_required:true}'

  [ "$stop" = "false" ] || return 3
  return 0
}

# ── worktree-prepare / worktree-teardown ─────────────────────────────────

cmd_worktree_prepare() {
  local repo_root="$1" slug="$2" base_sha="$3"
  repo_root="$(resolve_repo "$repo_root")" || return 1
  validate_slug "$slug" || return 1

  local wt_path="${repo_root}.wt/${slug}"
  local branch="build/${slug}"

  # NOTE: stderr is deliberately NOT merged into this capture — worktree.sh
  # create() writes its structured JSON to real stdout (fd 3, see that
  # file's own header) but a diagnostic guard banner to stderr; merging the
  # two here would corrupt the JSON parse below on every run where the
  # banner fires, exactly the failure this comment prevents from recurring.
  local create_out create_outcome
  create_out="$(bash "$WORKTREE_SH" create "$repo_root" "$slug")"
  create_outcome="$(jq -r '.outcome // empty' <<<"$create_out" 2>/dev/null)"
  if [ "$create_outcome" != "CREATED" ]; then
    printf '%s\n' "$create_out"
    # Best-effort cleanup even here: an unparseable create_out is not proof
    # nothing was created (create's own JSON write could itself have failed
    # after the worktree was already added) — never leave possible residue
    # on an early return.
    bash "$WORKTREE_SH" remove "$repo_root" "$slug" >/dev/null 2>&1 || true
    return 1
  fi

  # From here on, ANY failure must tear the worktree back down before this
  # function returns — the mid-run-failure guarantee. `failed`/`fail_reason`
  # accumulate; a single cleanup-then-report exit point at the bottom is
  # what makes "cleaned up on the failure path" true regardless of WHICH
  # step below fails.
  local failed=0 fail_reason=""

  # Property 1 — structurally disable push, scoped to THIS worktree ONLY
  # via git's per-worktree config extension (`extensions.worktreeConfig`).
  # Remotes are ordinarily repo-wide (shared .git/config across every linked
  # worktree); this writes into the worktree-private config.worktree layer
  # instead, which is read-merged on top of the shared config for THIS
  # worktree's git invocations only — the parent checkout's and every OTHER
  # worktree's `origin` push URL is untouched. A `git push` issued from
  # inside this worktree therefore targets an unresolvable sentinel
  # transport rather than the real remote.
  if [ "$failed" -eq 0 ] && ! git -C "$repo_root" config extensions.worktreeConfig true 2>/dev/null; then
    failed=1; fail_reason="could not enable extensions.worktreeConfig"
  fi
  if [ "$failed" -eq 0 ] && ! git -C "$wt_path" config --worktree remote.origin.pushurl "$REPLAY_PUSH_DISABLE_SENTINEL" 2>/dev/null; then
    failed=1; fail_reason="could not set worktree-scoped remote.origin.pushurl"
  fi

  # Property 3 (per-repo-derived scratch path) is structural by
  # construction: $wt_path IS worktree.sh's own deterministic
  # "<repo-root>.wt/<slug>" layout, reused verbatim — nothing here computes
  # a second path.

  # Rewind to the item's OWN base (the fork point — spike fact 1), never
  # origin/<default>. An invalid/unreachable base is the mid-run failure
  # this function's cleanup path exists for.
  if [ "$failed" -eq 0 ] && ! git -C "$wt_path" cat-file -e "$base_sha" 2>/dev/null; then
    failed=1; fail_reason="base sha not found in worktree: $base_sha"
  fi
  if [ "$failed" -eq 0 ] && ! git -C "$wt_path" reset --hard "$base_sha" >/dev/null 2>&1; then
    failed=1; fail_reason="git reset --hard $base_sha failed"
  fi

  if [ "$failed" -eq 1 ]; then
    bash "$WORKTREE_SH" remove "$repo_root" "$slug" >/dev/null 2>&1 || true
    jq -cn --arg e "$fail_reason" '{outcome:"ERROR",error:$e}'
    return 1
  fi

  local pushurl guard
  pushurl="$(git -C "$wt_path" config --worktree --get remote.origin.pushurl 2>/dev/null)"
  guard="$(jq -r '.guard // "UNKNOWN"' <<<"$create_out" 2>/dev/null)"

  jq -cn \
    --arg path "$wt_path" --arg branch "$branch" --arg base "$base_sha" \
    --arg pushurl "$pushurl" --arg sentinel "$REPLAY_PUSH_DISABLE_SENTINEL" --arg guard "$guard" \
    --arg scratch_root "${repo_root}.wt" \
    '{outcome:"PREPARED", path:$path, branch:$branch, base:$base,
      isolation:{no_push_remote:($pushurl==$sentinel), pushurl:$pushurl, guard:$guard, scratch_root:$scratch_root}}'
}

cmd_worktree_teardown() {
  local repo_root="$1" slug="$2"
  repo_root="$(resolve_repo "$repo_root")" || return 1
  bash "$WORKTREE_SH" remove "$repo_root" "$slug"
}

# ── execute (temperloop#1258) — the replay run itself ────────────────────

# execute_cannot_evaluate <msg> — the ONE fail-closed emission path for
# `execute`, delegating to the shared idiom in
# workflows/scripts/lib/cannot-evaluate.sh (temperloop#1475): the machine
# verdict on stdout, the distinct human `CANNOT EVALUATE` line on stderr,
# and now RC_CANNOT_EVALUATE (2) as ITS OWN return status — a caller that
# forgets to branch on it fails closed rather than falling through. Every
# existing caller already follows it with an explicit `return 1`, so this
# changes no observed behavior.
execute_cannot_evaluate() {
  cannot_evaluate_emit "replay.sh execute" "$1"
}

# _exec_epoch_ms — millisecond wall clock (perl when present, else whole
# seconds; honest low resolution rather than fabricated precision).
_exec_epoch_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%d", time * 1000' 2>/dev/null && return 0
  fi
  printf '%d' "$(( $(date +%s) * 1000 ))"
}

# _exec_emit_record <record-file> <candidate-json> <score-json> <wt> <branch> <out>
# Merges the corpus record with the populated candidate/score sub-objects.
# ONE constructor, so a scored record and an integration-error record are
# byte-for-byte the same SHAPE and only their contents differ (an aggregator
# must never have to guess which fields a given outcome carries).
_exec_emit_record() {
  local record_file="$1" candidate="$2" score="$3" wt="$4" branch="$5" out="$6" merged
  merged="$(jq -c \
    --argjson candidate "$candidate" --argjson score "$score" \
    --arg wt "$wt" --arg branch "$branch" \
    --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {worktree:{path:$wt, branch:$branch, prepared_at:$prepared_at},
          candidate:$candidate, score:$score}' "$record_file" 2>/dev/null)"
  [ -n "$merged" ] || return 1
  if [ -n "$out" ]; then printf '%s\n' "$merged" >"$out" || return 1; fi
  printf '%s\n' "$merged"
}

# _exec_empty_score <reason> — the score sub-object for a record that was
# never scored. Every figure is null and `scored` is false: an
# integration-error record must be structurally incapable of contributing a
# pass or a fail to a quality tally.
_exec_empty_score() {
  jq -cn --arg r "$1" \
    '{outcome:"NOT_SCORED", scored:false, verdict:null, not_scored_reason:$r,
      base:null, truth_head:null, diff:null, gate_result:null,
      acceptance_results:null, components:null, contamination_flags:[]}'
}

cmd_execute() {
  local record_file="" repo_root="" wt="" provider="$REPLAY_TRUSTED_DEFAULT_PROVIDER"
  local model="" owner_repo="" runner="" live=0 out="" prompt_out="" gate_relpath=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --record) need_operand --record "$#" "${2:-}" || return 2; record_file="$2"; shift 2 ;;
      --repo-root) need_operand --repo-root "$#" "${2:-}" || return 2; repo_root="$2"; shift 2 ;;
      --worktree) need_operand --worktree "$#" "${2:-}" || return 2; wt="$2"; shift 2 ;;
      --provider) need_operand --provider "$#" "${2:-}" || return 2; provider="$2"; shift 2 ;;
      --model) need_operand --model "$#" "${2:-}" || return 2; model="$2"; shift 2 ;;
      --repo) need_operand --repo "$#" "${2:-}" || return 2; owner_repo="$2"; shift 2 ;;
      --candidate-runner) need_operand --candidate-runner "$#" "${2:-}" || return 2; runner="$2"; shift 2 ;;
      --out) need_operand --out "$#" "${2:-}" || return 2; out="$2"; shift 2 ;;
      --prompt-out) need_operand --prompt-out "$#" "${2:-}" || return 2; prompt_out="$2"; shift 2 ;;
      --gate-relpath) need_operand --gate-relpath "$#" "${2:-}" || return 2; gate_relpath="$2"; shift 2 ;;
      --live) live=1; shift ;;
      *) printf 'replay.sh execute: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done

  # ── input validation, all fail-closed ────────────────────────────────
  [ -n "$record_file" ] || { execute_cannot_evaluate "no --record given"; return 1; }
  [ -n "$repo_root" ] || { execute_cannot_evaluate "no --repo-root given"; return 1; }
  [ -n "$wt" ] || { execute_cannot_evaluate "no --worktree given"; return 1; }

  if [ ! -f "$record_file" ] || [ ! -r "$record_file" ]; then
    execute_cannot_evaluate "corpus record not found or not a readable regular file: $record_file"
    return 1
  fi
  if [ ! -s "$record_file" ]; then
    execute_cannot_evaluate "corpus record file is empty: $record_file"
    return 1
  fi
  if ! jq -e 'type=="object" and has("base") and has("head") and has("status") and has("buckets")' "$record_file" >/dev/null 2>&1; then
    execute_cannot_evaluate "corpus record is malformed (want a JSON object carrying base, head, status and buckets): $record_file"
    return 1
  fi

  local rec_status rec_base rec_issue rec_pr item_ref
  rec_status="$(jq -r '.status // empty' "$record_file")"
  case "$rec_status" in
    eligible|flagged-eligible) ;;
    *)
      execute_cannot_evaluate "corpus record status is '$rec_status' — only an eligible or flagged-eligible item is replayable; refusing to produce a score for an item corpus selection already rejected"
      return 1
      ;;
  esac
  rec_base="$(jq -r '.base // empty' "$record_file")"
  [ -n "$rec_base" ] || { execute_cannot_evaluate "corpus record carries a null base"; return 1; }

  rec_issue="$(jq -r '.issue // empty' "$record_file")"
  rec_pr="$(jq -r '.pr // empty' "$record_file")"
  if [ -n "$rec_issue" ]; then
    item_ref="issue:${rec_issue#\#}"
  elif [ -n "$rec_pr" ]; then
    item_ref="pr:$rec_pr"
  else
    execute_cannot_evaluate "corpus record identifies neither an issue nor a PR — no item_ref to disclose or attribute against"
    return 1
  fi

  repo_root="$(resolve_repo "$repo_root")" || { execute_cannot_evaluate "--repo-root is not a git toplevel: $repo_root"; return 1; }
  if [ ! -d "$wt" ]; then
    execute_cannot_evaluate "replay worktree does not exist or is not a directory: $wt (run 'replay.sh worktree-prepare' first)"
    return 1
  fi
  wt="$(abs_dir "$wt")" || { execute_cannot_evaluate "replay worktree is not enterable: $wt"; return 1; }
  if ! git -C "$wt" rev-parse --show-toplevel >/dev/null 2>&1; then
    execute_cannot_evaluate "replay worktree is not inside a git work tree: $wt"
    return 1
  fi
  if ! git -C "$wt" cat-file -e "${rec_base}^{commit}" 2>/dev/null; then
    execute_cannot_evaluate "the record's base commit is not resolvable inside the replay worktree ($wt): $rec_base"
    return 1
  fi

  # ── THE CANDIDATE-RUNNER SEAM. No implicit binary, ever. ─────────────
  # This is the structural half of "a fixture suite can never issue a live
  # model call": with neither seam given there is nothing to fall back TO.
  # A `claude` sitting on PATH is not reachable from here.
  if [ -n "$runner" ] && [ "$live" -eq 1 ]; then
    execute_cannot_evaluate "--candidate-runner and --live are mutually exclusive — pick the recorded runner or the real spawn, never both"
    return 1
  fi
  if [ -z "$runner" ] && [ "$live" -eq 0 ]; then
    execute_cannot_evaluate "no candidate runner configured: pass --candidate-runner <cmd> (a recorded/stubbed runner) or the explicit --live flag. There is deliberately NO implicit fallback to a 'claude' binary on PATH — an unset seam refuses rather than silently spending"
    return 1
  fi

  # ── candidate-session.sh: BOTH halves, on BOTH paths ─────────────────
  # (a) the containment overlay must be present, readable and well-formed —
  #     resolve's own exit codes 3/4/5 are the fail-closed contract, and we
  #     honour them rather than re-deriving the check here.
  if [ ! -f "$CANDIDATE_SESSION_SH" ]; then
    execute_cannot_evaluate "candidate-session.sh not found at $CANDIDATE_SESSION_SH — the candidate spawn seam is unavailable"
    return 1
  fi
  local cs_out cs_rc=0
  cs_out="$(bash "$CANDIDATE_SESSION_SH" resolve "Read" 2>&1)" || cs_rc=$?
  if [ "$cs_rc" -ne 0 ]; then
    execute_cannot_evaluate "candidate-session.sh reports its containment overlay is unusable (exit $cs_rc — 3=absent, 4=unreadable, 5=malformed): $cs_out"
    return 1
  fi
  # (b) the provider-key health check — a runtime gate, never a silent no-op.
  local pf_out pf_rc=0
  pf_out="$(bash "$CANDIDATE_SESSION_SH" preflight --provider "$provider" 2>&1)" || pf_rc=$?
  if [ "$pf_rc" -ne 0 ]; then
    execute_cannot_evaluate "candidate-session.sh preflight refused provider '$provider': $pf_out"
    return 1
  fi

  # ── PRE-FLIGHT MODEL RESOLUTION (temperloop#1383) ────────────────────
  # An explicit --model is already pinned. When it was OMITTED — the
  # legitimate "run whatever this candidate session's own config selects"
  # arm — the effective model must still be known BEFORE the spawn, because
  # the envelope-derived route (`resolved_model` below, from the returned
  # `modelUsage` block) does not exist on the failure paths this pins for:
  # a vendor-error envelope returns before token extraction, and a
  # candidate-timeout (SIGKILL) never produces an envelope at all. So a
  # default-model spawn that fails either way had NO other route to a real
  # model id — it fell back to the literal string 'unknown'.
  #
  # This mirrors, read-only, the CANDIDATE-SCOPED settings the spawned
  # child actually runs under — and ONLY those. HERMETIC-SAFE by
  # construction: it never reads the invoking host's user-global config
  # (~/.claude/settings.json), because a test/fixture run must never have
  # its records shaped by whoever happens to be running it (the
  # environment-dependent-verdict class, cf. temperloop#1552 — an earlier
  # HOME fallback here flipped test_replay_batch.sh's J2 mutation proof on
  # any host whose personal config names a default model, while CI's clean
  # runner passed). The sources, in the child's own precedence order:
  #   1. the containment overlay candidate-session.sh spawns the child
  #      under (`--settings` = ${CANDIDATE_SETTINGS:-candidate.settings.json},
  #      same env seam, same default — a CLI-arg settings file outranks
  #      project settings, and fixtures can pin it);
  #   2. worktree-local, then worktree-project settings (files the
  #      candidate worktree itself ships — part of the tree under test,
  #      never host-personal state).
  # A model the child would resolve ONLY from the host's user settings is
  # deliberately left unresolved: 'unknown' stands, with the existing
  # usage_source:unavailable disclosure, exactly like the other genuinely-
  # unresolvable shapes. Scoped to the DEFAULT provider only: a
  # non-default provider's model vocabulary belongs to that vendor, not
  # this repo's claude settings, so it is left alone.
  if [ -z "$model" ] && [ "$provider" = "$REPLAY_TRUSTED_DEFAULT_PROVIDER" ]; then
    local _mr_src _mr_val
    for _mr_src in "${CANDIDATE_SETTINGS:-$HERE/candidate.settings.json}" \
                   "$wt/.claude/settings.local.json" "$wt/.claude/settings.json"; do
      [ -n "$_mr_src" ] && [ -f "$_mr_src" ] || continue
      _mr_val="$(jq -r '.model // empty' "$_mr_src" 2>/dev/null)"
      if [ -n "$_mr_val" ]; then model="$_mr_val"; break; fi
    done
  fi

  # ── DISCLOSE BEFORE SENDING (ADR 0028 pairing) ───────────────────────
  # A non-default-provider send writes its disclosure-log entry FIRST, and a
  # failed disclosure refuses the send. The log may legitimately run ahead
  # of the sends (a disclosed send that then failed to happen); it may never
  # run behind them — which is exactly the direction the send-vs-log
  # cross-check in validate-provider-disclosure.sh checks.
  local disclosed=false
  if [ "$provider" != "$REPLAY_TRUSTED_DEFAULT_PROVIDER" ]; then
    if [ ! -f "$ALLOWLIST_LIB" ]; then
      execute_cannot_evaluate "allowlist.sh not found at $ALLOWLIST_LIB — cannot disclose a non-default-provider send, so refusing to make one"
      return 1
    fi
    # shellcheck source=./allowlist.sh
    . "$ALLOWLIST_LIB"
    if ! pa_disclose "$provider" "$item_ref"; then
      execute_cannot_evaluate "pa_disclose refused to record a send to non-default provider '$provider' for $item_ref — refusing to send undisclosed"
      return 1
    fi
    disclosed=true
  fi

  # ── the prompt ────────────────────────────────────────────────────────
  local scratch_dir prompt_file envelope_file
  scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/replay-exec.XXXXXX")" || {
    execute_cannot_evaluate "could not create a scratch dir under ${TMPDIR:-/tmp}"; return 1; }
  prompt_file="$scratch_dir/prompt.txt"
  envelope_file="$scratch_dir/envelope.json"

  # The item fields the keystone spike identified as the recoverable prompt
  # inputs (title / scope / source / acceptance), rendered into a stable,
  # hashed prompt. This is DELIBERATELY not a re-execution of the base
  # tree's build-level.mjs `workerPrompt` — that function is not exported
  # and extracting it by line range is exactly the brittle coupling the
  # spike warned about. Comparability BETWEEN replay runs rides
  # `prompt_sha256`; comparability against the ORIGINAL run is not claimed,
  # and `template_sha` (recorded at the item's own base) is what lets a
  # later reader see whether the two trees' templates even agreed.
  {
    printf 'You are a /build implementation worker for a replayed item.\n\n'
    printf '## Workspace — STRICT isolation\n'
    printf -- '- Your Bash cwd and ALL edits MUST be under: %s\n' "$wt"
    printf -- '- Commit on the current branch. Do NOT push. Do NOT open a PR.\n\n'
    printf '## Item\n'
    printf -- '- title: %s\n' "$(jq -r '.title // ""' "$record_file")"
    printf -- '- scope: %s\n' "$(jq -r '.scope // ""' "$record_file")"
    printf -- '- source: %s\n\n' "$(jq -r '.issue // .pr // ""' "$record_file")"
    printf '## Acceptance (self-verify each before returning done)\n'
    jq -r '(.acceptance // [])[] | "  - " + .' "$record_file"
  } >"$prompt_file"
  if [ -n "$prompt_out" ]; then cp "$prompt_file" "$prompt_out" 2>/dev/null || true; fi

  local prompt_sha
  if command -v sha256sum >/dev/null 2>&1; then
    prompt_sha="$(sha256sum <"$prompt_file" | awk '{print $1}')"
  else
    prompt_sha="$(shasum -a 256 <"$prompt_file" | awk '{print $1}')"
  fi

  # ── run the candidate ─────────────────────────────────────────────────
  local started ended run_rc=0 measured_ms
  started="$(_exec_epoch_ms)"
  if [ "$live" -eq 1 ]; then
    local -a claude_args=(-p --output-format json)
    [ -n "$model" ] && claude_args+=(--model "$model")
    # ── THE WORKING-DIRECTORY HANDOFF (temperloop#1376) ────────────────
    # A live candidate is a REAL headless session, and a headless session
    # works in the directory it is SPAWNED in. The prompt above names $wt
    # as the workspace, but prompt prose is a request, not a mechanism —
    # before this subshell existed the live arm spawned in whatever cwd the
    # caller happened to have, so every live replay measured the wrong
    # tree. Both halves were observed: on a host with the build-worktree
    # guard armed the candidate was denied every write and returned
    # "Blocked"; on a host WITHOUT that guard armed the same spawn would
    # have committed into the operator's own checkout. The `cd` is what
    # makes a candidate's cwd-relative `git` resolve INSIDE $wt, so
    # correctness here does not depend on any PreToolUse hook being armed.
    #
    # It is a SUBSHELL so `execute`'s own later steps (score.sh, the record
    # emit, the scratch cleanup) still run from the caller's cwd. Every
    # path crossing this boundary is already absolute — $CANDIDATE_SESSION_SH
    # is $HERE-derived, the prompt/envelope/stderr files come from
    # `mktemp -d` — so nothing re-resolves against the new cwd. $wt was
    # already validated enterable (abs_dir) and a git work tree above; the
    # `|| exit 125` is a belt-and-braces refusal that surfaces as a
    # candidate-spawn integration error rather than a silent wrong-cwd run.
    (
      cd "$wt" || { printf 'replay.sh execute: could not cd into the replay worktree: %s\n' "$wt" >&2; exit 125; }
      run_with_timeout "$REPLAY_CANDIDATE_TIMEOUT_SECS" \
        bash "$CANDIDATE_SESSION_SH" spawn --provider "$provider" -- "${claude_args[@]}"
    ) <"$prompt_file" >"$envelope_file" 2>"$scratch_dir/stderr.txt" || run_rc=$?
  else
    # Deliberately unquoted: a runner is a command STRING (e.g.
    # "bash /path/stub.sh"), split on whitespace, exactly like every other
    # command-string seam in this repo's machinery.
    # shellcheck disable=SC2086
    run_with_timeout "$REPLAY_CANDIDATE_TIMEOUT_SECS" \
      $runner "$prompt_file" "$wt" >"$envelope_file" 2>"$scratch_dir/stderr.txt" || run_rc=$?
  fi
  ended="$(_exec_epoch_ms)"
  measured_ms=$(( ended - started ))
  [ "$measured_ms" -lt 0 ] && measured_ms=0

  local branch; branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"

  # integration_error <stage> <detail> — emit the record and return 4.
  # Local to this function so no other path can accidentally produce an
  # integration-error record without the empty score object.
  _exec_integration_error() {
    local stage="$1" detail="$2" cand
    cand="$(jq -cn --arg p "$provider" --arg m "$model" --arg s "$stage" --arg d "$detail" \
      --argjson dur "$measured_ms" --argjson disclosed "$disclosed" --arg prompt "$prompt_sha" \
      '{provider:$p, model:(if $m=="" then null else $m end), diff_ref:null,
        tokens:null, duration_ms:$dur, outcome:"integration-error",
        integration_error:{stage:$s, detail:$d},
        disclosed:$disclosed, prompt_sha256:$prompt}')"
    _exec_emit_record "$record_file" "$cand" "$(_exec_empty_score "$stage")" "$wt" "$branch" "$out"
    # The attribution record still gets written — the spawn HAPPENED, and
    # dropping it would understate the compatibility denominator. It is
    # attribution-only (usage_source unavailable): there are no tokens to
    # report, and emit-model-usage.sh forbids a provider value in that shape.
    #
    # $model is the PRE-FLIGHT-resolved value by this point (temperloop#1383)
    # — an explicit --model, or the candidate session's resolved config
    # default, resolved above before the spawn ever ran. `ea_model` only
    # covers the genuinely-unresolvable remainder (a non-default provider, or
    # no settings named a model anywhere): emit-model-usage.sh requires a
    # non-empty --model, so the literal 'unknown' sentinel stands there,
    # unchanged, computed as its own explicit step rather than folded into
    # an inline default-substitution that read the same regardless of WHICH
    # case produced it.
    if [ -x "$EMIT_MODEL_USAGE_SH" ]; then
      local ea_model="$model"
      [ -n "$ea_model" ] || ea_model="unknown"
      local -a ea=(--seat "$REPLAY_CANDIDATE_SEAT" --model "$ea_model" \
                   --usage-source unavailable --outcome-ref "$item_ref" --duration-ms "$measured_ms")
      [ -n "$owner_repo" ] && ea+=(--repo "$owner_repo")
      "$EMIT_MODEL_USAGE_SH" "${ea[@]}" >/dev/null 2>&1 || true
    fi
    rm -rf "$scratch_dir"
    return 4
  }

  if [ "$run_rc" -eq 137 ]; then
    _exec_integration_error "candidate-timeout" "the candidate run exceeded REPLAY_CANDIDATE_TIMEOUT_SECS (${REPLAY_CANDIDATE_TIMEOUT_SECS}s)"
    return 4
  fi
  if [ "$run_rc" -ne 0 ]; then
    # BOTH streams, and the envelope read BEFORE _exec_integration_error's own
    # `rm -rf "$scratch_dir"` destroys it (temperloop#1553). Reading stderr
    # alone produced "the candidate runner exited 1: " on all 28 legs of the
    # first live batch: `claude -p --output-format json` reports an API-level
    # failure as a JSON object on STDOUT and writes nothing to stderr, so the
    # empty stderr was the expected shape and the envelope carrying the actual
    # reason was deleted unread.
    _exec_integration_error "candidate-spawn" \
      "$(spawn_failure_detail "$run_rc" "$scratch_dir/stderr.txt" "$envelope_file" "the candidate runner")"
    return 4
  fi
  if ! jq -e 'type=="object"' "$envelope_file" >/dev/null 2>&1; then
    _exec_integration_error "envelope-parse" "the candidate runner's stdout is not a JSON object: $(head -c 400 "$envelope_file" 2>/dev/null)"
    return 4
  fi
  if [ "$(jq -r '.is_error // false' "$envelope_file")" = "true" ]; then
    _exec_integration_error "vendor-error" "the envelope reports is_error=true: $(jq -r '.subtype // .error // "no detail"' "$envelope_file")"
    return 4
  fi

  # Token extraction — the envelope's `modelUsage` block, summed across
  # every model key (a spawn can legitimately touch more than one), exactly
  # the whole-spawn-total convention lib/model-usage-envelope.sh documents.
  local tokens_json resolved_model
  tokens_json="$(jq -c '
    (.modelUsage // {}) | to_entries
    | map(select((.value|type=="object")))
    | if length == 0 then null else
        {input:(map(.value.inputTokens // 0)|add),
         output:(map(.value.outputTokens // 0)|add),
         cache_read:(map(.value.cacheReadInputTokens // 0)|add),
         cache_creation:(map(.value.cacheCreationInputTokens // 0)|add)}
      end' "$envelope_file" 2>/dev/null)"
  if [ -z "$tokens_json" ] || [ "$tokens_json" = "null" ]; then
    # The acceptance requires a scored record to carry TOKENS. An envelope
    # with no usable usage block is a vendor integration failure, not a
    # scored record with a hole in it.
    _exec_integration_error "envelope-usage-missing" "the envelope carries no usable modelUsage block, so no token count exists for this run"
    return 4
  fi
  resolved_model="$(jq -r '
    (.modelUsage // {}) | to_entries
    | map(select((.value|type=="object")))
    | sort_by( ((.value.inputTokens // 0) + (.value.outputTokens // 0)
              + (.value.cacheReadInputTokens // 0) + (.value.cacheCreationInputTokens // 0)) )
    | if length == 0 then "" else (last | .key) end' "$envelope_file" 2>/dev/null)"
  [ -n "$resolved_model" ] || resolved_model="$model"

  local env_duration duration_ms
  env_duration="$(jq -r '.duration_ms // empty' "$envelope_file" 2>/dev/null)"
  case "$env_duration" in ''|*[!0-9]*) duration_ms="$measured_ms" ;; *) duration_ms="$env_duration" ;; esac

  # ── score it ──────────────────────────────────────────────────────────
  local -a score_args=(score --repo-root "$repo_root" --candidate-worktree "$wt" --record "$record_file")
  [ -n "$gate_relpath" ] && score_args+=(--gate-relpath "$gate_relpath")
  local score_json score_rc=0
  score_json="$(bash "$SCORE_SH" "${score_args[@]}")" || score_rc=$?
  if [ "$score_rc" -ne 0 ]; then
    # "Could not score" — NOT "scored and failed". No record is emitted.
    printf '%s\n' "$score_json"
    execute_cannot_evaluate "score.sh could not score this replay (exit $score_rc); refusing to emit a record carrying a score it did not compute"
    rm -rf "$scratch_dir"
    return 1
  fi

  local diff_ref
  diff_ref="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"

  local candidate_json
  candidate_json="$(jq -cn --arg p "$provider" --arg m "$resolved_model" --arg d "$diff_ref" \
    --argjson tokens "$tokens_json" --argjson dur "$duration_ms" \
    --argjson disclosed "$disclosed" --arg prompt "$prompt_sha" \
    '{provider:$p, model:(if $m=="" then null else $m end),
      diff_ref:(if $d=="" then null else $d end),
      tokens:$tokens, duration_ms:$dur, outcome:"scored", integration_error:null,
      disclosed:$disclosed, prompt_sha256:$prompt}')"

  if ! _exec_emit_record "$record_file" "$candidate_json" "$score_json" "$wt" "$branch" "$out"; then
    execute_cannot_evaluate "could not assemble the scored record"
    rm -rf "$scratch_dir"
    return 1
  fi

  # The attribution record — emit-model-usage.sh, reused verbatim. This is
  # the SEND half the disclosure log is cross-checked against.
  if [ -x "$EMIT_MODEL_USAGE_SH" ]; then
    local -a ea=(--seat "$REPLAY_CANDIDATE_SEAT" --model "$resolved_model" --provider "$provider"
                 --usage-source cli-envelope --outcome-ref "$item_ref" --duration-ms "$duration_ms"
                 --input-tokens "$(jq -r .input <<<"$tokens_json")"
                 --output-tokens "$(jq -r .output <<<"$tokens_json")"
                 --cache-read-tokens "$(jq -r .cache_read <<<"$tokens_json")"
                 --cache-creation-tokens "$(jq -r .cache_creation <<<"$tokens_json")")
    [ -n "$owner_repo" ] && ea+=(--repo "$owner_repo")
    "$EMIT_MODEL_USAGE_SH" "${ea[@]}" >/dev/null 2>&1 || true
  fi

  rm -rf "$scratch_dir"
  return 0
}

# ── verify-clean-parent — BACKSTOP, not the primary control ─────────────
#
# The primary isolation control is STRUCTURAL and asserted at prepare time,
# independently of any post-run probe: the worktree-scoped push-remote
# disable, the kernel write-jail guard marker worktree.sh's own create drops
# (see that file's header — this is the SAME `.build-guard` mechanism every
# `/build` worker worktree gets), and the deterministic per-repo scratch
# path. This function is a SECOND, after-the-fact line of defense — it
# confirms the parent checkout was not, in fact, dirtied by whatever ran
# inside an isolated replay worktree. It proves nothing on its own about
# WHY the parent stayed clean, and a caller must never treat a clean result
# here as a substitute for the structural checks above.
cmd_verify_clean_parent() {
  local repo_root="$1" dirty
  repo_root="$(resolve_repo "$repo_root")" || return 1
  dirty="$(git -C "$repo_root" status --porcelain 2>/dev/null)"
  if [ -n "$dirty" ]; then
    jq -cn --arg d "$dirty" '{outcome:"DIRTY",detail:$d}'
    return 1
  fi
  jq -cn '{outcome:"CLEAN"}'
}

# ── schema — the versioned scored-record shape downstream consumers build
#    against. The `candidate` and `score` sub-objects were shipped as
#    documented placeholders by temperloop#1254 and are FILLED IN here by
#    temperloop#1258's `execute`; the version string is unchanged because
#    completing a placeholder v1 left for exactly this purpose is not a v2.
cmd_schema() {
  jq -cn --arg sv "$REPLAY_RECORD_SCHEMA_VERSION" '{
    schema_version: $sv,
    pr: null, issue: null, merge_commit: null, base: null, head: null,
    title: null, scope: null, acceptance: [], notes: "",
    status: null, reject_reason: "", flags: [],
    buckets: {N: [], T: [], X: [], R: []},
    template_sha: null, file_count: null,
    worktree: {path: null, branch: null, prepared_at: null},
    candidate: {
      provider: null, model: null, diff_ref: null,
      tokens: null, duration_ms: null,
      outcome: null, integration_error: null,
      disclosed: null, prompt_sha256: null
    },
    score: {
      outcome: null, scored: null, verdict: null, not_scored_reason: null,
      base: null, truth_head: null,
      diff: null, gate_result: null, acceptance_results: null,
      components: null, contamination_flags: []
    }
  }'
}

# ── dispatch — no while-loop parses the top-level subcommand, so a missing
#    trailing operand here can never shift-2-no-op into a hang (§ testing
#    bar); each subcommand's OWN internal loop (corpus, diff-scope) is
#    itself guarded by need_operand above. ────────────────────────────────
[ $# -ge 1 ] || { usage; exit 2; }
cmd="$1"; shift
case "$cmd" in
  resolve-base)
    [ $# -eq 2 ] || { usage; exit 2; }
    cmd_resolve_base "$1" "$2"
    ;;
  diff-scope)
    [ $# -ge 3 ] || { usage; exit 2; }
    repo_arg="$1"; base_arg="$2"; head_arg="$3"; shift 3
    cmd_diff_scope "$repo_arg" "$base_arg" "$head_arg" "$@"
    ;;
  corpus)
    cmd_corpus "$@"
    ;;
  preflight)
    cmd_preflight "$@"
    ;;
  worktree-prepare)
    [ $# -eq 3 ] || { usage; exit 2; }
    cmd_worktree_prepare "$1" "$2" "$3"
    ;;
  worktree-teardown)
    [ $# -eq 2 ] || { usage; exit 2; }
    cmd_worktree_teardown "$1" "$2"
    ;;
  execute)
    cmd_execute "$@"
    ;;
  verify-clean-parent)
    [ $# -eq 1 ] || { usage; exit 2; }
    cmd_verify_clean_parent "$1"
    ;;
  schema)
    cmd_schema
    ;;
  *)
    usage; exit 2
    ;;
esac
