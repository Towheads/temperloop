#!/usr/bin/env bash
#
# build.config.sh — central defaults for the build / sweep
# tunables (foundation #447). This is the ONE place a batch-pipeline setting's
# default lives; `source` it (the machinery scripts and the command Step 0 do) to
# pull every tunable into scope.
#
# Idiom: `: "${VAR:=default}"` assigns the default ONLY when VAR is unset, so a
# pre-existing environment value (a shell export, a `.env`, an inline
# `VAR=… cmd`) always WINS over the default here. To change a default globally,
# edit the line below.
#
# This file is sourced, never executed — it has no CLI and writes nothing.
#
# ── The six-layer config PRECEDENCE ladder (temperloop#164/#169) ────────────
# NOTE: "precedence layer" here is unrelated to the pipeline autonomy
# "level-5b" / "level-5c" driver-tier terminology used later in this file
# (§ Pipeline level-5b driver / § Pipeline level-5c merge tier below) — two
# different ladders; "layer" is always precedence, "level" always autonomy.
#
# Every setting this file governs resolves through the same precedence ladder,
# highest to lowest:
#
#   1. CLI flag           — a caller's explicit `--flag value` (handled by the
#                            consuming script before/after sourcing this file;
#                            out of scope here)
#   2. env var             — an exported shell value already in the process
#                            environment when this file is sourced
#   3. machine conf        — $XDG_CONFIG_HOME/temperloop/build.config.sh (this
#                            HOST's override, e.g. a mini's LaunchAgent env)
#   4. untracked repo-local conf — build.config.local.sh, this file's
#                            gitignored sibling (this CHECKOUT's override,
#                            e.g. secrets)
#   5. tracked repo conf   — this file's own `:=` defaults, AS COMMITTED in a
#                            consuming repo that vendors/edits its own copy
#   6. kernel built-in default — a matching `:=` fallback hardcoded directly
#                            into an individual consumer script, for a
#                            non-vendoring caller that never sources this file
#                            at all (see e.g. PIPELINE_OPERATOR /
#                            PIPELINE_MERGE_PENDING_LABEL below — several
#                            machinery scripts already keep one of these)
#
# Precedence layers 5 and 6 are BOTH implemented by `:=` assignments, just in
# two different places (this file vs. an individual script) — a consuming
# repo that vendors this file gets layer 5; a script invoked standalone
# without it falls through to layer 6. Layers 3 and 4 are sourced BELOW, before
# layer 5's defaults, so that (per the `:=` idiom) a value they set is already
# bound by the time layer 5 runs and its own `:=` becomes a no-op for that var
# — this is what makes source order double as precedence order. Full ladder
# writeup, and how `boards.conf`'s XDG-then-repo-local discovery is an
# INSTANCE of this same order: ../../../docs/config-precedence.md.
#
# ── v0.17.0 terminology-rename legacy window: CLOSED in v0.19.0 ─────────────
# The window's env shim (which forwarded the pre-rename FUNNEL_*/KNOB_* env
# prefixes onto the renamed PIPELINE_*/SETTING_* settings, NEW > OLD > default)
# was deleted with the rest of the window in v0.19.0 (temperloop#767, ADR
# 0017). A pre-rename env name is now simply UNREAD — it binds nothing and
# emits nothing. The v0.17.0 CHANGELOG BREAKING entry carries the full rename
# map; persisted external state (labels, issue markers, state paths, the lock
# dir) was deliberately never remapped and is unaffected.

# ── Precedence layer 3: machine conf ─────────────────────────────────────────
# Sourced FIRST (before repo-local and before this file's own defaults) so it
# outranks both, per the ladder above. Absent file is a silent no-op. The
# path is overridable via BUILD_CONFIG_MACHINE (a test seam / explicit
# host override). MUST itself use the `:=` idiom for every var it sets —
# a plain assignment here would beat an exported env var, the exact bug
# this ladder fixes for build.config.local.sh below. Template:
# build.config.machine.sh.example (copy to the path below on the host).
: "${BUILD_CONFIG_MACHINE:=${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/build.config.sh}"
if [ -f "$BUILD_CONFIG_MACHINE" ]; then
  # shellcheck source=/dev/null
  . "$BUILD_CONFIG_MACHINE"
fi

# ── Precedence layer 4: untracked repo-local conf (secrets / per-checkout override; #709) ──
# Source an OPTIONAL, gitignored sibling `build.config.local.sh` for
# checkout-local secrets and overrides that must NOT be committed — e.g. the
# pipeline's Sentry poll credentials (SENTRY_AUTH_TOKEN / SENTRY_ORG /
# SENTRY_PROJECT) that /signal-intake reads via pipeline-tick.sh Phase 0.
# Sourced here, BEFORE this file's own `:=` defaults below, so it outranks
# them — but AFTER precedence layer 3 (machine conf) above, so machine conf
# still wins. An absent file is a silent no-op (never fatal), and being untracked it
# survives the pipeline cron's self-update `git reset --hard`. The path is
# overridable via BUILD_CONFIG_LOCAL (a test seam that also lets a host point
# elsewhere). MUST itself use the `:=` idiom for every var it sets — a plain
# assignment here would unconditionally win over an exported env var, which
# is precisely the ladder-order violation this file used to have (it sourced
# this file LAST, with plain assignments, so a local.sh value could beat an
# env export). Template + mini install: build.config.local.sh.example.
: "${BUILD_CONFIG_LOCAL:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build.config.local.sh}"
if [ -f "$BUILD_CONFIG_LOCAL" ]; then
  # shellcheck source=/dev/null
  . "$BUILD_CONFIG_LOCAL"
fi

# (The legacy window's SECOND shim pass stood here — it re-forwarded
# pre-rename names that a layer-3/4 conf had set ITSELF, after those confs
# were sourced. It closed with the window in v0.19.0, temperloop#767: a
# machine conf or repo-local conf written before the v0.17.0 rename must now
# set the renamed names directly, or its values are ignored.)

# ── Precedence layer 5 / 6: tracked repo conf / kernel built-in defaults ─────
# Everything below is this file's own `:=` default set. It runs LAST, after
# precedence layers 3 and 4 above, so any var they already bound is left
# untouched (its `:=` here is a no-op) — only a var still unset at this point
# takes the value below.

# ── 5-hour quota gate (#447) ────────────────────────────────────────────────
# After each level (build) / each fix (sweep), the run checks the
# remaining 5-hour usage quota and pauses-then-auto-resumes if it is too low.

# Pause when the REMAINING 5h quota is below this percent (i.e. used > 100-this).
: "${BUILD_QUOTA_PAUSE_PCT:=10}"

# Where status-line.sh persists the live rate-limit snapshot the gate reads.
: "${BUILD_QUOTA_CACHE:=$HOME/.claude/rate-limits.json}"

# Seconds to wait PAST the window's reset before resuming (lets the window roll).
: "${BUILD_QUOTA_WAIT_BUFFER:=60}"

# Ignore the cache (→ fail open, proceed) if its snapshot is older than this many
# seconds — never act on a stale low reading from a long-dead session.
: "${BUILD_QUOTA_MAX_AGE:=1800}"

# ── Existing build settings, centralized here (#447) ───────────────────────
# These predate this file; their defaults now live here. build.md prose
# keeps its inline `${VAR:-default}` as a belt-and-suspenders fallback for callers
# that did not source this file.
: "${BUILD_MERGE_GATE_WINDOW:=300}"   # timed merge-gate window (s); 0 = always modal
: "${BUILD_QUEUE_TIMEOUT:=1800}"      # per-PR native-merge-queue timeout (s)

# Queue-stall threshold (temperloop#1178): how long a PR may sit IN the native
# merge queue with ZERO merge_group runs ever dispatched for it before
# `gate.sh diagnose-queue` calls it QUEUE_STALLED rather than merely slow. A
# healthy entry gets its gh-readonly-queue/<base>/pr-<N>-<sha> run within about
# a minute, so this sits far above the ~2.5 min a queue's own checks
# legitimately take — and far below BUILD_QUEUE_TIMEOUT, so a genuine stall is
# NAMED well before the ceiling instead of guessed at after it. gate.sh keeps a
# byte-identical layer-6 fallback for a caller that did not source this file.
: "${BUILD_QUEUE_STALL_AFTER:=600}"   # queue-stall threshold (s), zero merge_group runs

# Step-4a.5 combined-tree pre-check (temperloop#865): before enqueuing a level
# that parked >1 PR, build the UNION of the parked branches in a throwaway
# worktree and run the full gate suite against it — catching a SEMANTIC
# collision (two PRs green alone, red combined) LOCALLY instead of paying the
# native queue's ~1h eject/diagnose/rebase/requeue cycle. "on" (default) runs
# it; "off" skips the check outright, leaning on the queue's own merge_group as
# the sole backstop. Single-PR levels skip it regardless (nothing to combine).
: "${BUILD_COMBINED_TREE_PRECHECK:=on}"   # on|off — run the Step-4a.5 union pre-check

# Step-3h.5 as-you-go merging (temperloop#1026): whether an item that the
# EXISTING Step-4a regime partition already puts in the clean-disjoint tier may
# merge the moment ITS OWN PR goes green, instead of parking `[m]` until the
# level-boundary batch gate. Scoped to that tier only — a risky /
# structurally-overlapping set is untouched and still takes the modal Step-4
# gate at the level boundary. Level boundaries remain a dependency barrier for
# STARTING the next level either way.
# Measured motivation (2026-08-02): three PRs opened together took 68/69/145
# min open-to-merge against 10-33 min for solo PRs — level batching converts
# within-level parallelism into a merge-queue pileup.
# Default ON, deliberately: the issue's acceptance criterion is only observable
# while the behavior is active, and a single value here reverts the whole
# change in one flip (0 restores pure level-boundary batching).
: "${BUILD_MERGE_AS_YOU_GO:=1}"           # 1|0 — merge each clean-disjoint PR as it greens

# Operator-phone reach on an ask-now halt (foundation#863). Every
# `ask-now` gate the /build orchestrator surfaces via `decision_sink_ask`
# calls decision-notify.sh, which relays a one-line summary to the operator's
# phone through the harness PushNotification tool. This setting is an OPTIONAL
# ADDITIONAL scriptable channel — an ntfy/pushover/terminal-notifier/webhook
# command an operator wires for phone reach independent of Remote Control. It
# receives the summary as a single argument (e.g. `ntfy pub my-topic`). Empty
# (default) = rely on PushNotification alone; a batch-severity (timed / non-
# blocking) gate never enters the seam, so it never notifies through either
# channel. Also the test-injection seam decision-notify.sh's own test drives.
: "${BUILD_DECISION_NOTIFY_CMD:=}"        # optional scriptable operator-notify channel

# ── Retry caps & transient-vs-deterministic classification (temperloop#976) ──
# The operator-facing home for every RETRY bound in /build's gate + CI-poll
# machinery. Repeating a DETERMINISTICALLY failing operation cannot change its
# outcome — it is pure burn (live evidence: the 3e.5 acceptance gate re-ran a
# deterministically-failing shellcheck three times in the epic #1443 run). Each
# loop below therefore carries three knobs: a hard attempt CAP, a graduated
# inter-attempt BACKOFF (so a legitimately transient failure gets real time to
# clear — Towheads/foundation#1297: retries fired back-to-back within a fraction
# of a second defeat a slow-clearing transient), and a DETERMINISTIC-signature
# pattern that fails fast with no retry at all.
#
# DUPLICATE LAYER-6 FALLBACKS — deliberate. `scripts/quality-gates.sh` and
# `workflows/scripts/build/ci-poll.sh` each keep a BYTE-IDENTICAL `:-` fallback
# for their own settings (the six-layer ladder's layer 6, § header above), because
# both must run standalone in a consuming repo that never sources this file — and
# because /build's 3e.5 acceptance gate deliberately SCRUBS this file's settings
# (build-config-settings.sh) so the suite runs hermetically at tracked defaults,
# exactly as CI's `checks` job does. Consequence to know: a value set HERE governs
# a hand-run or CI gate invocation, while the 3e.5 gate run always uses the
# script's own identical fallback. Keep the two literals in sync — the setting
# registry pins this file's copy.

# Per-gate retry cap in quality-gates.sh (temperloop#403): absorbs transient
# CI-runner flakiness. Set to 1 to disable retries entirely (e.g. when hunting a
# real intermittent bug).
: "${GATE_MAX_ATTEMPTS:=3}"

# Graduated per-attempt sleep (backoff*attempt seconds) between quality-gates.sh
# retry attempts (Towheads/foundation#1297). 0 = retry immediately (the pre-#1297
# behavior); the default gives a slow-clearing transient real time to clear.
: "${GATE_RETRY_BACKOFF:=5}"

# ERE matched against a FAILED gate attempt's captured output. A match classifies
# the failure DETERMINISTIC — the gate is NOT retried and fails straight to
# escalation. The default matches a shellcheck finding code (the #1443 case);
# widen it for other static-lint signatures, or set it EMPTY to disable
# signature-based classification (the byte-identical-output short-circuit still
# applies, so a deterministic failure is still capped at two attempts).
: "${GATE_DETERMINISTIC_PATTERN:=SC[0-9][0-9][0-9][0-9]}"

# How many quality gates scripts/quality-gates.sh runs CONCURRENTLY
# (temperloop#1025). `auto` resolves to the detected core count, clamped to a
# ceiling the scheduler owns; an explicit integer overrides it. Set to 1 to
# restore the exact pre-parallel serial loop — the right mode for bisecting a
# gate or hunting an order-dependent flake, since it removes concurrency as a
# variable. This is a WITHIN-JOB worker pool, so changing it never affects the
# required `checks (ubuntu-latest)` status-check context.
: "${QUALITY_GATES_JOBS:=auto}"

# Bounded retry count for ONE `gh api` call in ci-poll.sh — the head-SHA resolve
# or a check-runs query (temperloop#386). Absorbs a transient non-JSON/HTTP-5xx
# hiccup instead of false-escalating it as a CI failure. Set to 1 to disable.
: "${CI_POLL_API_MAX_ATTEMPTS:=5}"

# Graduated per-attempt sleep (backoff*attempt seconds) between ci-poll.sh
# gh_retry attempts (temperloop#386).
: "${CI_POLL_API_RETRY_BACKOFF:=2}"

# ERE matched against a failed `gh` invocation's combined output in ci-poll.sh.
# A match classifies the failure DETERMINISTIC — no retry, immediate legible
# ERROR carrying `deterministic_failure:true` (temperloop#976). The default names
# permanent HTTP 4xx / auth / argument errors and deliberately EXCLUDES HTTP 429
# (rate limiting), which IS transient and must keep its backed-off retries. Set
# EMPTY to retry every failure regardless of shape (the pre-#976 behavior).
: "${CI_POLL_API_DETERMINISTIC_PATTERN:=HTTP 40[0-9]|HTTP 41[0-9]|Not Found|Could not resolve to a|Bad credentials|Resource not accessible|unknown flag}"

# Autonomous pipeline drive-concurrency governor (temperloop#162, split out from the
# retired human "WIP cap" governance rule): at most this many concurrent drives the
# autonomous pipeline lane bounds per tick. SOURCE OF TRUTH for pipeline-tick.sh's
# autonomous-lane concurrency bound (which is explicitly INHERITED from this policy,
# not re-embedded — see that file's own comment). This is the mechanical governor
# ONLY — the former human "WIP cap = 3" cross-session governance rule it used to
# double as was retired in temperloop#162 (the In-Progress gate + claim-first lock
# in claude/CLAUDE.kernel.md's Task-workflow section stay; the numeric human cap is
# gone). Change the pipeline's concurrency bound here, once.
: "${PIPELINE_DRIVE_CONCURRENCY:=3}"

# Epic-decomposition sub-unit threshold (prose-tunables-migration follow-up to
# temperloop#183): a second "CLAUDE.md-resident setting" rendered at compose time
# into claude/CLAUDE.kernel.md's Task-workflow section — "epic-sized" is
# `{{EPIC_MIN_SUBUNITS}}`+ parallelizable sub-units (OR more than one
# dependency level, which stays a structural/contract fact, not a separate
# setting — see that section's own note). Rendered into the kernel doc at compose
# time by workflows/scripts/install-claude-md.sh.
: "${EPIC_MIN_SUBUNITS:=3}"

# HUMAN-FACING display timezone (temperloop — Pacific display convention). The
# IANA zone every human-facing date/time renders in: conversation reports and
# by-day breakdowns, telemetry-brief's "today" bucket, reconcile's status-line
# stamps. An IANA name (NOT a fixed "PST"/"PDT") so DST is handled automatically
# — reads PDT in summer, PST in winter, always matching the operator's wall clock.
# A third "CLAUDE.md-resident setting" rendered at compose time into
# claude/CLAUDE.kernel.md § Communication conventions as `{{DISPLAY_TZ}}` by
# workflows/scripts/install-claude-md.sh.
#
# NOT for STORED/PARSED records: the telemetry data lake (emit-*.sh), board
# claim/capture timestamps, and the plan-schema consent timestamp stay ISO-8601
# UTC (canonical, parseable, DST-free) — never localize those.
: "${DISPLAY_TZ:=America/Los_Angeles}"

# Merge-backend SELECTION (temperloop#13): a free personal repo can't always
# provision GitHub's native merge queue, so `gate.sh backend` chooses NATIVE
# vs MANAGED. "auto" probes the repo's branch ruleset for a `merge_queue` rule
# and fails safe to MANAGED on an unreadable probe (see gate.sh cmd_backend's
# header comment for the fail-safe-direction rationale); an explicit
# `native`/`managed` override here short-circuits the probe entirely. Pure
# string default — no network call happens at config-source time, only inside
# the `gate.sh backend` invocation itself.
: "${BUILD_MERGE_BACKEND:=auto}"       # auto|native|managed

# Per-Bash-call bound for the FOREGROUND CI / MERGED polls /build runs on a
# HEADLESS one-shot path (PIPELINE_OPERATOR_ABSENT=1 — the pipeline `claude -p` merge
# driver, which has no re-invoke-on-background-completion loop, so its waits must
# block the single session in the foreground rather than dispatch-and-yield, #626).
# Kept under the ~10-min Bash foreground cap; the session itself is un-timeout'd, so
# 3g/4b can chain several sequential foreground polls, and the #624 hand-off marker
# catches any tail that outlasts them. Operator-present runs ignore this (they keep
# the run_in_background + ScheduleWakeup path).
: "${BUILD_HEADLESS_POLL_TIMEOUT:=540}"  # foreground CI/MERGED poll bound (s), headless path

# ── Command-spec prose settings (prose-tunables-migration, temperloop#164/#169
#    D3 follow-up) ──────────────────────────────────────────────────────────
# These settings back a value that previously lived ONLY in a command spec's
# prose (no shell seam at all — the D3 "prose names a setting, never states its
# value" convention had nothing to point at). Each command spec now sources
# THIS file at its own Step 0 (the same worked shape as build.md Step 0 item
# 6) and references the symbolic name below instead of restating the
# literal. Centralized here rather than a per-command config file — one
# place, per § Named-setting convention (`claude/CLAUDE.kernel.md`).

# assess.md Step 6 — the approval-poll ScheduleWakeup cadence/budget.
: "${ASSESS_POLL_FIRST_WAKE:=270}"    # first wake (s) after arming the poll
: "${ASSESS_POLL_CADENCE:=1200}"      # every wake thereafter (s)
: "${ASSESS_POLL_BUDGET:=7200}"       # give up this long (s) after arming

# next.md Step 0.5 — orphan Sequencing/*.md record staleness prune.
: "${NEXT_SEQ_STALE_AFTER:=64800}"    # prune a record older than this (s)

# tidy.md Step 0 — cross-machine drain-lock election.
: "${TIDY_SYNC_WAIT:=90}"             # wait for Obsidian Sync to propagate locks (s)
: "${TIDY_LOCK_STALE_AFTER:=1800}"    # discard a `.drain.lock.*` older than this (s)

# check-in.md — resolved-entry prune window across its review sections.
: "${CHECKIN_PRUNE_DAYS:=30}"         # resolved entries older than this may be pruned

# sweep.md Phase 2 — clarification-free-issue fanout WIDTH per batch chunk:
# how many issues drive concurrently in a single Phase-2 chunk. 1 = full
# legacy sequential behavior (one issue at a time, the pre-fanout shape).
: "${SWEEP_FANOUT_WIDTH:=3}"

# sweep.md Phase 1 — model tier for the underspecification-detection subagent
# fanout. Sentinel: an EMPTY value means INHERIT THE SESSION'S OWN model (no
# override) — this is a deliberate, Contract-pinned default from a ratified
# design brief, not an oversight: detection is judgment work, and a missed
# ambiguity that silently reaches Phase 2 is the costly failure mode, so
# this setting does NOT default to a cheap tier the way PIPELINE_DRIVE_MODEL does
# for mechanical drives (§ Cost-tier routing, claude/CLAUDE.kernel.md).
: "${SWEEP_DETECT_MODEL:=}"

# sweep.md Step 3 — model tier for the Phase-2 fix-issue WORKER agent (the
# item.model field on each build-level.mjs items[] entry). Distinct from
# SWEEP_DETECT_MODEL above (Phase-1 detection): this is the implementation
# worker, not the ambiguity-detection fanout. Sentinel: an EMPTY value means
# INHERIT THE SESSION'S OWN model — today's hardcoded behavior, unchanged by
# this setting's addition (temperloop#982; the epic's own default-flip is
# tracked separately, temperloop#971 — this item ships NO default change).
# A /sweep singleton has no plan item to derive a tier from (unlike /build,
# which reads a plan-item `model:` field), which is why this lever didn't
# exist before.
: "${SWEEP_WORKER_MODEL:=}"

# fix.md Step 4 — model tier for the single-issue WORKER agent /fix spawns
# (the item.model field on its one-item build-level.mjs items[] entry). Same
# sentinel convention as SWEEP_WORKER_MODEL above and the same rationale: a
# /fix target has no plan item to derive a tier from either. Sentinel: empty
# = inherit the session's own model (today's hardcoded behavior, unchanged;
# temperloop#982).
: "${FIX_WORKER_MODEL:=}"

# claude/workflows/build-level.mjs — model tier for the TWO machinery-executor
# agent spawns that bridge the deterministic bash machinery into the Workflow
# runtime: BUILD_MACHINERY_SOLO_MODEL for runMachinery (the SOLO executor —
# the 3e.5 quality gate, recover-probe, push-retry), BUILD_MACHINERY_BATCH_MODEL
# for runMachineryBatch (the BATCHED prelude/pr-batch/ci-batch executor — see
# that file's own DESIGN NOTE 1). Named as a pair, not a general-case-plus-
# carve-out — each covers exactly half of build-level.mjs's four machinery
# call sites, so neither name is the "default" the other overrides; setting
# only one leaves the other half of the machinery spawns untouched, by design.
# UNLIKE every setting above, build-level.mjs itself never sources this file —
# the Workflow runtime has no filesystem, no Node, and no shell (DESIGN NOTE 1
# again), so there is no Step-0-source shell seam available inside the .mjs.
# Instead, EVERY command that invokes build-level.mjs (`claude/commands/
# build.md`, `sweep.md`, `fix.md` — all three source this file at their own
# Step 0 already) resolves these two and passes them as orchestrator-supplied
# WORKFLOW INPUT — `input.machinerySoloModel` / `input.machineryBatchModel` —
# alongside the existing `input.machineryBinDir` / `input.claimCmd` hand-off
# precedent (build.md Step 3's args table is the worked example; sweep.md/
# fix.md mirror it). Never a config-file read from inside the .mjs. The
# EMPTY-STRING SAFETY is owned by the CONSUMER, not the producer: the .mjs
# reads `input.machinerySoloModel || 'haiku'` / `input.machineryBatchModel ||
# 'haiku'` (`||`, not `??` — `??` only falls through on null/undefined and
# would let an orchestrator that resolves this to `""` and forgets to omit
# the key pass a literal empty-string model through; `||` collapses BOTH
# absent-input AND empty-string-input to the same fallback). Sentinel:
# empty here means every consumer either omits the key or passes it through
# unfiltered — either way the .mjs's own hardcoded 'haiku' literal wins,
# the deliberate, UNCHANGED default (the byte-identical-when-unset contract
# this item ships under; temperloop#982).
: "${BUILD_MACHINERY_SOLO_MODEL:=}"
: "${BUILD_MACHINERY_BATCH_MODEL:=}"

# claude/workflows/build-level.mjs §3e.5 — the per-SLICE wall-clock budget, in
# seconds, for the parent-side acceptance gate's `scripts/quality-gates.sh` run.
#
# WHY A SLICE AND NOT A DEADLINE. The gate runs inside ONE executor-agent Bash
# invocation whose tool ceiling (~10 min) this repo cannot raise. Treating that
# ceiling as a deadline for the WHOLE suite decayed twice: temperloop#115 raised
# a flat timeout 2min -> 8min after a green suite was SIGTERM'd and reported as
# GATE_FAIL, and temperloop#1021 is the identical failure again once the gate
# list outgrew 8min. So this value bounds ONE slice, not the suite:
# quality-gates.sh (via QUALITY_GATES_BUDGET_SECS) runs gates until the budget is
# spent, stops CLEANLY BETWEEN GATES, and reports a resume index; build-level.mjs
# loops slices. Total suite runtime is therefore unbounded by the agent's cap, and
# gate-list growth can no longer manufacture a false failure — which is why this
# setting should almost never need raising. Raise it only to cut the NUMBER of
# slices (each costs one cheap executor spawn), never to "make the suite fit".
#
# Handed to build-level.mjs the same way the two model settings above are — as
# orchestrator-supplied WORKFLOW INPUT `input.gateSliceSecs`, resolved at
# build.md / sweep.md / fix.md Step 0 — because the Workflow runtime has no
# shell to source this file (DESIGN NOTE 1). The .mjs keeps its OWN in-file
# default and CLAMPS the value so the derived Bash-tool timeout can never exceed
# the agent's hard ~10-min cap; an un-updated caller that omits the key, or one
# that resolves it to an empty string, lands on that default unchanged.
: "${BUILD_GATE_SLICE_SECS:=300}"

# claude/workflows/build-level.mjs — the per-STEP WALL-CLOCK LIVENESS BOUND on a
# machinery-executor step (the `prelude` / `pr-batch` / `ci-batch` batches and the
# solo `gate` / `recover-probe` / `push-retry` calls), in seconds.
#
# WHY IT EXISTS (temperloop#1071). A `pr-batch` machinery agent ran 35,362,333ms
# — 9h49m — on TWO tool calls: one Bash invocation blocked, then completed
# successfully (all four steps green, the PR opened). Every bound that was
# supposed to make that unreachable failed to fire: the Bash tool's own `timeout`
# parameter is capped at 600,000ms and the emitted prompt asks for less than that,
# and NOTHING else bounded the call. The ROOT CAUSE of the stall is NOT
# established (candidate hypotheses — a network-bound `gh` call on a half-open
# socket, git lock contention across linked worktrees sharing one object store, a
# harness timeout not enforced across host suspend — are recorded as candidates,
# never acted on without a disconfirming probe). This setting is therefore the
# ROOT-CAUSE-AGNOSTIC defensive seam: a bound that holds no matter WHICH of those
# is true, because it lives INSIDE the invoked shell rather than in the harness
# layer that demonstrably did not fire.
#
# CEILING, NOT A DEADLINE — it must never fire on healthy work. Normal machinery
# steps in the observed sweep completed in seconds to a couple of minutes; the
# longest legitimate single step is a CI poll slice (CI_POLL_SLICE_SECS, 240s in
# the .mjs) or one 3e.5 gate slice ($BUILD_GATE_SLICE_SECS plus its overrun tail).
# The default sits comfortably above all of them AND above the Bash tool's own
# 600s hard cap, so this bound is a BACKSTOP behind the tool timeout, never a
# competitor to it. Raise it only if a legitimate step genuinely needs longer;
# lowering it below the gate slice budget would manufacture false timeouts.
#
# WHAT HAPPENS WHEN IT FIRES: the step is killed and reports its own
# `{"outcome":"STEP_TIMEOUT",...}` line, and build-level.mjs treats the step as
# LOST — it runs the EXISTING `pr.sh recover-probe <worktree> <branch>` side-effect
# probe (temperloop#939's ladder, the same disposal seam temperloop#1067 uses for
# the adjacent lost-return case) before deciding anything. A PR the timed-out step
# already opened is ADOPTED, never re-opened; nothing is ever blind-retried, so a
# bounded step cannot double-push or double-open a PR.
#
# Handed to build-level.mjs on the SAME orchestrator→workflow input seam as the
# two model settings and BUILD_GATE_SLICE_SECS above (`input.machineryStepCeilingSecs`,
# resolved at build.md / sweep.md / fix.md Step 0) — the Workflow runtime has no
# shell to source this file, and no `Date.now()` either, which is exactly why the
# bound is enforced in the emitted shell rather than in the .mjs's own control flow.
: "${BUILD_MACHINERY_STEP_CEILING_SECS:=900}"

# claude/workflows/build-level.mjs — the OBSERVABILITY half of the same seam: a
# batched machinery step that takes at least this many seconds emits its own
# `{"outcome":"STEP_SLOW",...}` notice line alongside its real result, which the
# driver turns into a `log()` line. A step that is merely slow is NOT lost and is
# NOT disposed — the notice exists so a long stall is VISIBLE well before it
# reaches BUILD_MACHINERY_STEP_CEILING_SECS, instead of being the silent 9.8h the
# #1071 incident was. Set to 0 to disable the notice entirely.
#
# The default sits just above the longest legitimate single batched step (the
# CI_POLL_SLICE_SECS poll slice) so a healthy ci-batch stays quiet. It is
# deliberately NOT applied to the SOLO executor calls: those return exactly ONE
# JSON object by contract, so a second notice line there would break the schema.
: "${BUILD_MACHINERY_STEP_SLOW_SECS:=300}"
# claude/workflows/build-level.mjs §3c worker return contract — WORD BOUNDS on
# the two free-prose slots of the worker's structured verdict (temperloop#1080).
#
# WHY BOUNDS AT ALL. The verdict's SHAPE is already machine-enforced
# (WORKER_VERDICT_SCHEMA), but a JSON schema cannot bound a string's LENGTH, so
# the two prose slots were unbounded in practice: measured across 83 real
# /build worker verdicts, `summary` ran to a median 119 words (max 557) and
# per-criterion `evidence` to a median 33 words (max 244) against a spec that
# asked for "1-3 sentences" and "<file:line or test name>". Every one of those
# words is an OUTPUT token (weight 5, the most expensive class) that the
# orchestrator then ingests. The bound is not information loss: the detail
# belongs in `.build-verification.md`, which the worker already writes to a
# FILE and which pr.sh splices into the PR body's `## Verification` section
# WITHOUT it ever entering orchestrator context — so a bounded verdict moves
# prose off the expensive path rather than deleting it.
#
# Handed to build-level.mjs on the SAME seam as BUILD_GATE_SLICE_SECS above —
# orchestrator-supplied WORKFLOW INPUT `input.workerSummaryMaxWords` /
# `input.workerEvidenceMaxWords`, resolved at build.md Step 0 — because the
# Workflow runtime has no shell to source this file (DESIGN NOTE 1). The .mjs
# keeps its OWN in-file defaults, so a caller that omits the keys (sweep.md /
# fix.md today) still emits a BOUNDED worker prompt: the shape is inherited by
# every caller of the shared workerPrompt(), only the tuning is build.md's.
: "${BUILD_WORKER_SUMMARY_MAX_WORDS:=60}"
: "${BUILD_WORKER_EVIDENCE_MAX_WORDS:=30}"

# sweep.md Step 3 tier-2 composition — the BOUNDED wait on background chunk 1's
# completion notification. After the Phase-1 question batch resolves, if chunk 1's
# `<task-notification>` has not arrived, the driver polls the chunk's task state
# up to ATTEMPTS times, INTERVAL seconds apart (the same background-`sleep` wake
# pattern the per-chunk quota gate uses); on exhaustion chunk 1 is treated as a
# dropped-background escalation and the run proceeds to the Step-3.5 terminal-state
# assertion, which fails loudly on its unaccounted entries. The bound is what keeps
# a dropped notification from stalling the run indefinitely.
: "${SWEEP_BG_POLL_ATTEMPTS:=6}"      # bounded poll count before declaring the chunk dropped
: "${SWEEP_BG_POLL_INTERVAL:=120}"    # seconds between polls

# ── Pipeline operator identity + required CI check (tracker seam v0, #772) ────
# The operator handle the async decision-issue backend, the merge-tier escalation
# path, and pipeline-tick's assignee baton all target. MUST be the operator's real
# GitHub collaborator LOGIN (verify with `gh api user -q .login` — a display
# name or email-derived handle can differ from the real login, and a re-assign
# to the wrong one targets nobody / fails, so the baton never reaches the
# operator; foundation #588). Consuming scripts (pipeline-tick.sh, pipeline-drive.sh)
# keep a matching `:=` fallback for a non-vendoring checkout, exactly as
# PIPELINE_MERGE_PENDING_LABEL does; this file is the SOURCE OF TRUTH. `gh` wants
# the bare login, so the leading @ is stripped at each use site. The placeholder
# below MUST be overridden — set the real value in the gitignored
# build.config.local.sh (§ Precedence layer 4 above), never here.
: "${PIPELINE_OPERATOR:=@REPLACE_WITH_YOUR_GH_LOGIN}"

# Required CI gate name a PR must clear to merge (foundation #665). Every build
# repo names its required ci.yml job `checks` (global CLAUDE.md § Branch & PR
# policy), so one default serves all boards.
: "${PIPELINE_REQUIRED_CHECK:=checks}"

# ── Pipeline-overlap predicate (#864) ─────────────────────────────────────────
# The pipeline's OPERATIONAL SURFACE — space-separated path prefixes that
# pipeline-overlap.sh intersects a plan's aggregate `files:` set against at
# /build run start (Step 1.7). A plan that rewrites this machinery while the
# pipeline is live is the Epic B interference cascade (retro #847): the default
# names the build machinery + board toolkit + pipeline commands/hooks + quality
# gates + Makefile, under both the kernel/ vendored prefix and the compat
# pre-split paths. Prefix match is textual, so both spellings must be listed.
: "${PIPELINE_DRIVEN_PATHS:=kernel/ workflows/scripts/ claude/commands/ claude/workflows/ claude/hooks/ scripts/quality-gates Makefile}"

# ── Pipeline level-5b driver (#604) ────────────────────────────────────────────
# The autonomous pipeline driver's supervised auto-drive. Default OFF: the cron
# stays pure 5a (emit + notify) until the operator opts in. Set PIPELINE_DRIVE=1
# (a deploy host's LaunchAgent/cron plist sets it when the 5b soak begins) to make
# pipeline-cron.sh execute the SAFE, no-merge tier of each tick plan via a headless
# pipeline-drive.sh / `claude -p "/pipeline-drive"` run. See pipeline-drive.sh.
: "${PIPELINE_DRIVE:=0}"                 # 1 = auto-execute the safe tier; 0 = emit-only (5a)
# Per-tick DRIVE CAP — the canonical "how many items the pipeline drives per tick"
# setting (#642). pipeline-tick.sh caps the number of Operational drive-ready actions it
# EMITs per tick on this (was a hardcoded one-per-tick); pipeline-cron.sh resolves the
# operator's vault `cap:` (the ```pipeline-schedule block) into it and ALSO maps it onto
# PIPELINE_DRIVE_MERGE_CAP below, so one vault field governs both the emit cap and the
# merge blast-radius. The `:=1` here is only the fallback when the vault omits `cap:`
# (and for a bare manual `pipeline-tick.sh` run); the vault is the live source of truth.
: "${PIPELINE_DRIVE_CAP:=1}"             # max Operational items driven per tick (vault `cap:` feeds this)
: "${PIPELINE_DRIVE_MODEL:=claude-sonnet-5}"  # model for the headless driver (mechanical actions)
: "${PIPELINE_DRIVE_SETTINGS:=}"         # --settings overlay for the headless driver (#606);
                                       # empty here → pipeline-drive.sh defaults it to its
                                       # repo-relative pipeline-drive.settings.json (deny gh pr/git
                                       # push + a broad allow for the full safe tier — #609)

# ── Pipeline level-5c merge tier (#615) ────────────────────────────────────────
# The merging tier of the autonomous driver: drive-ready WHERE kind=="code"
# (→ /build --unattended → PR → CI → merge). 5b (above) leaves this for the
# operator; 5c auto-executes it on /build's existing timed/modal merge gate.
# A SEPARATE gate from PIPELINE_DRIVE — flipping the safe tier on must NOT flip
# merging on. The merge tier RIDES ON TOP of the safe tier: it runs only when
# the cron already invokes pipeline-drive.sh (PIPELINE_DRIVE=1) AND this is 1.
# Default OFF ⇒ the merge tier is surfaced-but-not-driven, exactly as in 5b.
: "${PIPELINE_DRIVE_MERGE:=0}"           # 1 = also auto-execute the kind:code merge tier; 0 = leave for operator
# Merge blast-radius bound. Since #642 this is FED from the vault `cap:` by
# pipeline-cron.sh (it exports PIPELINE_DRIVE_MERGE_CAP=$cap alongside PIPELINE_DRIVE_CAP),
# so the operator sets it via the vault schedule, NOT the plist. The `:=1` here is
# only the fallback when the cron does not resolve a cap (e.g. a bare pipeline-drive.sh run).
: "${PIPELINE_DRIVE_MERGE_CAP:=1}"       # max kind:code items driven to merge per tick (vault `cap:` feeds this)
: "${PIPELINE_DRIVE_MERGE_MODEL:=claude-opus-4-8}"  # model for the merge driver (code drives are high-judgment)
: "${PIPELINE_DRIVE_MERGE_SETTINGS:=}"   # --settings overlay for the merge driver; empty here →
                                       # pipeline-drive.sh defaults it to pipeline-drive-merge.settings.json
                                       # (the inverse of the 5b overlay: ALLOWS the scoped gh pr/merge/push
                                       # surface /build needs, still never --dangerously-skip-permissions)

# Cross-tick merge hand-off (#624), now the bounded-timeout TAIL after #626. Since
# #626, a headless `claude -p` merge drive runs /build's CI-watch + merge gate in the
# FOREGROUND and the normal outcome is merged-in-session. This label covers the tail:
# when /build's foreground CI/MERGED poll hits its BUILD_HEADLESS_POLL_TIMEOUT bound
# before the merge lands (CI/queue slower than the session can foreground-wait), the
# drive splits across ticks. pipeline-drive.sh applies the label to an issue whose drive
# left an OPEN, unmerged PR (ground-truth probe, not a model self-report), and
# pipeline-tick.sh, on seeing it, emits a RESUME drive (re-attach to the open PR + run
# /build's merge gate) instead of a FRESH one — which would open a duplicate PR. The
# open PR remains the artifact work resumes on; the label is the cheap board pointer.
: "${PIPELINE_MERGE_PENDING_LABEL:=funnel-merge-pending}"

# Clarification-drain sentinel (foundation #657) — centralized here so the
# writer/reader pair share ONE source of truth (the drift the reviewer flagged):
#   PIPELINE_CLARIFIED_MARKER — the ack the 5b executor posts on a drained
#     `needs-clarification` item; pipeline-tick's clarification_already_applied reads
#     it for idempotency. (The prose writer /pipeline-drive.md cannot source config,
#     so that one literal stays hand-synced to this value.)
: "${PIPELINE_CLARIFIED_MARKER:=<!-- funnel:clarification-drained -->}"

# Level 5c code-escalation label (foundation #697, supersedes the #657 merge-escalation
# marker). A 5c CODE escalation (route-refused / terminally-red CI) carries THIS label
# + an assignee — NOT `needs-clarification` — so the #657 answer-drain's
# `label:needs-clarification … no:assignee` search can never match it (no marker, no
# per-item comment scan, no skip verb needed). pipeline-tick's park gate keeps such an
# item out of the drive pool (duplicate-PR guard). Consuming scripts keep a matching
# `:=` fallback for a non-vendoring checkout, exactly as PIPELINE_MERGE_PENDING_LABEL does.
: "${PIPELINE_ESCALATED_LABEL:=funnel-escalated}"

# ── Unified-retrospection RETRO_* settings (temperloop#532) ────────────────────
# These five settings are NAMED (in prose) by other items of the
# unified-retrospection epic and VALUED only here, per § Named-setting convention
# convention (`claude/CLAUDE.kernel.md`) — a command spec (`build.md`'s
# 4d-retro MINT step, the pipeline tick's retro-judge emit, `/retro` itself)
# references `$RETRO_*` symbolically and never restates the literal.

# Master on/off for the `/build` 4d-retro MINT (files a per-epic retro
# tracker at epic close). Default ON.
: "${RETRO_MINT_ENABLED:=1}"

# Debounce: minimum age (s) of the oldest `retro-pending` tracker before the
# pipeline tick emits a retro-judge action. Default a 3-day cadence.
: "${RETRO_MIN_INTERVAL:=259200}"

# CI-retry count at/above which a retro tracker is stamped `retro-urgent` at
# mint time (bypasses the debounce above).
: "${RETRO_URGENT_CI_RETRIES:=3}"

# Max number of retro trackers a single `/retro --pending` judge session
# processes (enforced judge-side).
: "${RETRO_BATCH_SESSION_CAP:=5}"

# Model the pipeline runs `claude -p "/retro --pending"` under — its own named
# model setting, distinct from PIPELINE_DRIVE_MODEL (same tier: the judge is a
# safe/standard drive, not a merge-tier high-judgment one).
: "${RETRO_JUDGE_MODEL:=claude-sonnet-5}"

# ── `temperloop configure` headless seat (temperloop#978) ─────────────────────
# A `claude -p` seat lives OUTSIDE the batch pipeline, under bin/subcommands/.
# The model-fan-out inventory (docs/model-fanout-inventory.md) found it as a
# SILENT INHERIT: it spawned a headless session with no --model flag at all,
# so it ran on whatever tier the invoking operator's CLI defaults to — the top
# tier, on a stranger's very first command. This setting is its lever.
#
# The inventory's other two seats were `try.sh`'s shadow-triage pass and
# `try.sh --demo`'s fix call, levered by TRY_TRIAGE_MODEL / TRY_DEMO_FIX_MODEL.
# Both settings were removed when `try` was retired — see the CHANGELOG's
# BREAKING entry for the migration.
#
# The seat runs `--tools ""` (structurally zero tool access), so it cannot
# write, and it is already dollar-capped. It is ALSO invisible to the
# `.temperloop/report.d/tokens` producer: it passes --no-session-persistence,
# so no transcript is written and no spend from this seat appears in the
# corpus that backs the pre-registered token-spend baseline note. See the
# inventory doc's § Measurement for why that gap forced a direct per-call
# measurement rather than a producer read.

# configure.sh — the AI-guided starting-value suggestion pass. Deliberately NOT
# re-tiered, and this one is a MEASURED refusal rather than a cautious one: the
# seat's whole job is to emit a single bare JSON object that the script parses
# with `jq`, and at the cheap tier the model wrapped that object in a fenced
# markdown code block on 4 of 4 runs, which makes `jq` exit 5 and drops EVERY
# setting through to the plain-prompt fallback. The cheap tier is ~2.4x cheaper
# per seat and delivers 0% of the job — the exact whole-job-accounting inversion
# the inventory doc's decision rule exists to catch. Sentinel: empty = inherit.
: "${CONFIGURE_AI_MODEL:=}"

# ── Language-reviewer catalog coverage scan (temperloop#538, ADR 0007/0008) ──
# The catalog's install-time coverage scan (and `make doctor`'s matching
# check) count each candidate language's files in the repo and offer
# activation only for a language that clears this floor — a repo with a
# single stray `.rb` file should not be offered a Ruby reviewer it doesn't
# need. This is INSTALL/DOCTOR-TIME machinery, not a batch-build-pipeline
# setting (contrast PIPELINE_DRIVE_CONCURRENCY above). Default 3: low enough that
# a small-but-real component (a handful of shell scripts, a slim Python
# helper) still gets offered its reviewer, high enough that a single
# generated/vendored/example file doesn't trigger a false-positive offer.
: "${REVIEWER_SCAN_MIN_FILES:=3}"

# ── Prose-plane budget gate (temperloop#719/#725, item prose-budget-gate;
#    ADR 0015) ──────────────────────────────────────────────────────────────
# Two-tier CI cap consumed by workflows/scripts/validate-prose-budget.sh,
# which measures both counts via workflows/scripts/count-prose.sh (never a
# second counting implementation — one compose seam). RATCHET: both caps are
# seeded at the FRESH baseline measured against the tree this item actually
# merges against — never a number recorded earlier and trusted stale. This
# item was seeded three times for exactly that reason: once at initial
# landing (338/1057, already past the epic's own earlier-recorded artifact
# by a few lines), again (340/1057) after a rebase onto a newer main picked
# up an unrelated ~2-line growth in claude/CLAUDE.kernel.md, and again
# (335/1057) by the epic's tighten-caps item (temperloop#730) after a
# subtraction pass (pointer-collapse + apply-approved-deletions) actually
# shrank the tier-1 render — re-measuring and re-seeding at merge-time
# state, rather than patching the gate to tolerate the old number, is the
# ratchet's own "green by construction" rule applied literally: whatever the
# tree looks like right before this PR merges IS the baseline, full stop.
# The tier-2 per-file figure held constant across all three seedings —
# claude/commands/build.md sits exactly at 1057 lines again at this
# tightening, so there is zero headroom to remove and the cap stays put
# rather than manufacturing a reduction. A cap is lowered again only by a
# later config PR, after a subtraction pass actually shrinks the prose
# (never raised/lowered by hand-editing prose to dodge the gate — see the
# setting-registry.tsv row for the same two settings, which must stay
# verbatim-equal to these two literals).
#
# TIER-1: caps the composed KERNEL-AUTHORED render only (claude/
# CLAUDE.kernel.md rendered via install-claude-md.sh's
# INSTALL_CLAUDE_MD_KERNEL_ONLY seam — never the kernel+overlay total).
#
# RAISED 2026-08-01 (item prose-budget-headroom, temperloop#925, epic #923
# "workshop collaborative decision walk") from 335 → 347. The prior seeding
# left ZERO headroom (335/335); this epic's `decision-presentation-template`
# item (#928) is the only item in the epic that touches CLAUDE.kernel.md —
# it qualifies the § Kernel vs overlay routing rule's "named message
# templates" carve-out (kernel.md:45–56) so it no longer reads as a blanket
# license once `### Decision presentation` is carved OUT of overlay-
# redeclaration by message-schema.md's own § Overrides. That qualifier was
# drafted against the live file to measure it, not estimated: 10 net-new
# lines. +20% estimation contingency (drafts precede the actual authored
# PR and typically grow under review) = 2 lines, ceiling. 335 + 10 + 2 =
# 347. See the sibling TIER-2 comment below for why this item bundles both
# caps in one config PR instead of four items each fighting their own gate.
: "${PROSE_BUDGET_TIER1_CAP:=347}"
# TIER-2: ONE uniform per-file cap over every tracked claude/**/*.md file
# (agent charters included) — deliberately a single setting, not a per-file
# table (a per-file value would just be a relocated exemption mechanism,
# which this item has none of). Seeded to clear the largest tracked file at
# landing time (claude/commands/build.md, 1057 lines, unchanged across all
# three seedings) — every other file already sits well under this cap, by
# construction of "uniform".
#
# RAISED 2026-08-01 (item prose-budget-headroom, temperloop#925, epic #923
# "workshop collaborative decision walk") from 1057 → 1128. `build.md`
# stays the largest file at 1057 and is untouched by this epic — the new
# binding file is `claude/commands/workshop.md` (938/1057 at measurement
# time, 119 lines of headroom), which FOUR items in this epic all grow:
# `premise-gate-presentation` (#931), `workshop-coverage-walk` (#930),
# `workshop-congruence-walkthrough` (#932), and `workshop-ratify-gate`
# (#934). Each region was drafted against the live file to get a real
# line count rather than an estimate pulled from the epic's own ~6–8-stop
# guess:
#   - Step 1.3b(iii) presentation re-point (premise-gate-presentation):  +7
#   - Step 2 full rewrite, old 93 lines → new 143 (workshop-coverage-walk): +50
#   - new Step 3.5 block (workshop-congruence-walkthrough):               +70
#   - Step 3.1.4 coverage-record tie-in (workshop-congruence-walkthrough): +4
#   - Step 4.1b finding-disposal tie-in (workshop-congruence-walkthrough): +4
#   - new Step 4.1c gate + migration carve-out (workshop-ratify-gate):    +23
#                                                                  subtotal: 158
# 938 + 158 = 1096. +20% estimation contingency on the 158 (drafts precede
# the actual authored PRs, which typically grow under review) = 32,
# ceiling. 1096 + 32 = 1128. This is a GLOBAL consequence, stated plainly
# per the operator's 2026-08-01 decision: TIER-2 is one uniform cap over
# every tracked claude/**/*.md file, so raising it to fund workshop.md
# relaxes the budget for every other kernel doc too — the alternative
# (a subtraction pass shrinking workshop.md first) was considered and not
# taken; see the epic's plan note § Re-triage signal 3 and this item's own
# Decisions-note record for the full rationale.
#
# SECOND RAISE, 1128 → 1154 (2026-08-01, temperloop#947, same epic). The
# first of the four items above has now landed and the estimate ran hot:
# `workshop-coverage-walk` (#930, PR #946) came in at +60 against its
# drafted +50 — 938 → 998, a 1.20 overrun factor. Re-projecting the three
# remaining items at that observed factor:
#   - premise-gate-presentation (#931):        +7  → 9
#   - workshop-congruence-walkthrough (#932): +78  → 94
#   - workshop-ratify-gate (#934):            +23  → 28
#                                        subtotal: 130
# 998 + 130 = 1128 — EXACTLY the cap set above, i.e. zero slack. That is
# the number worth acting on: three items grow this one file, so whichever
# merges last absorbs every earlier item's overrun and reds on someone
# else's estimate. +20% contingency on the 130 (same convention as the
# first raise) = 26, ceiling. 1128 + 26 = 1154.
# The global consequence stated above is UNCHANGED and applies again: this
# is one uniform cap, so a second relaxation loosens every tracked kernel
# doc a second time. That the cap needed raising twice inside one epic is
# itself signal that `workshop.md` carries real growth pressure a
# subtraction pass will eventually have to address; the operator decided
# 2026-08-01 to raise rather than run that pass on a file three in-flight
# items are concurrently editing.
#
# THIRD RAISE, 1154 → 1186 (2026-08-01, temperloop#954, same epic). The
# second raise undershot because it sized off a ONE-ITEM sample. With the
# whole L3 level landed, all four items are measured, and the drafted
# estimates ran hot by far more than the 1.20 the second raise assumed:
#   - workshop-coverage-walk (#930, PR #946):        +50 drafted →  +60  (1.20)
#   - premise-gate-presentation (#931, PR #950):      +7 drafted →   +9  (1.29)
#   - workshop-congruence-walkthrough (#932, PR #952):
#                                                    +78 drafted → +137  (1.76)
#                                        blended: 135 drafted → 206 (1.53)
# The congruence item is the outlier that broke the second estimate: its
# drafted +78 only ever priced the NEW Step 3.5, never the two other
# regions it also had to touch (Step 3.1.4, Step 4.1b) nor the
# docs/features/workshop.md update. Post-L3 merged `main` measures 1144 —
# ground truth read off the combined-tree pre-check worktree, not computed
# — leaving 10 lines under the 1154 cap. The one remaining item cannot fit:
#   - workshop-ratify-gate (#934): +23 drafted → +35 at the blended 1.53
# 1144 + 35 = 1179. +20% contingency on the 35 (same convention as both
# earlier raises) = 7, ceiling. 1144 + 42 = 1186.
# The global consequence stated above is UNCHANGED and applies a THIRD
# time. Two alternatives were considered and declined by the operator
# 2026-08-01: (a) a subtraction pass on workshop.md first — declined as an
# unplanned item on the critical path that would edit the very file
# workshop-ratify-gate then rewrites; (b) a per-file cap for workshop.md —
# declined because validate-prose-budget.sh's own header pins "ONE uniform
# per-file cap, never a per-file table (a per-file value would just be a
# relocated exemption mechanism; this gate has none)", so it is a contract
# change, not a tuning. workshop.md at 1144 became the LARGEST tracked
# kernel doc (past build.md at 1061), and this cap was raised three times
# in one day to fund it — the subtraction pass deferred above was filed as
# its own follow-up (temperloop#956).
#
# LOWERED, 1186 → 1100 (2026-08-02, temperloop#956, the deferred subtraction
# pass). Ran the subtraction on workshop.md itself: removals and
# consolidations only (never a behavior deletion — every step, gate, and
# named rule stayed specified, restated by reference instead of copied
# where it duplicated `claude/design-schema.md`/`claude/message-schema.md`
# content already covered elsewhere in the file) took it from 1181 lines to
# 1041. `claude/commands/build.md` is now the largest tracked file again, at
# 1100 lines — untouched by this item. Same "zero headroom, seeded to the
# largest tracked file" convention as the very first seeding of this cap:
# 1100. The ratchet moves both ways — a future raise still needs its own
# measured justification, never a restored high-water mark.
: "${PROSE_BUDGET_TIER2_FILE_CAP:=1100}"

# ── Pipeline spend profiler (temperloop#958) ───────────────────────────────
# Settings for `workflows/scripts/pipeline-spend-report.sh` and its
# `.temperloop/report.d/tokens` drop-in producer. That script resolves each
# of these with a `:?` (never a duplicated `:=` literal), so THIS FILE is the
# only place any of these values exists — which is what makes "no weight
# literal in the script" a structural fact rather than a review promise
# (kernel CLAUDE.md § Named-setting convention).
#
# COST WEIGHTS. A raw token count ranks spend WRONGLY, because the four token
# classes do not bill alike. These are relative multipliers normalized on
# ordinary input tokens (input = 1), not prices — no dollar constant lives
# anywhere in this loop (workflows/scripts/lib/report.contract.md § Non-goals,
# "no precise cost accounting"). The ratio that matters most is
# cache_create : cache_read, ~12.5:1 — during temperloop#953 ranking by RAW
# cache-read said the machinery agents were ~10% of spend; cost-weighted they
# are 31.8%. Re-derive these from the model's published per-class rates if
# they ever move; do not tune them to make a number look better.
: "${SPEND_WEIGHT_INPUT:=1}"
: "${SPEND_WEIGHT_CACHE_READ:=0.1}"
: "${SPEND_WEIGHT_CACHE_CREATE:=1.25}"
: "${SPEND_WEIGHT_OUTPUT:=5}"
#
# CLASSIFICATION THRESHOLDS, in deduped API calls per agent. Two of them, on
# purpose — see pipeline-spend-report.sh's header for why one cannot serve
# both jobs. SPEND_MACHINERY_MAX_CALLS is the spend-ATTRIBUTION split: at or
# below it an agent is /build machinery (a prelude / pr-batch / ci-batch
# executor that runs shell commands and reasons about nothing); above it, an
# item worker. SPEND_WORKER_PROFILE_MIN_CALLS is the floor for the "typical
# item worker" PROFILE, set higher so the long tail of short-lived helper
# agents on the item-worker side of the attribution split doesn't drag the
# median away from the thing an operator means by "an item worker".
# Both are seeded at the values that reproduce the temperloop#953 baselines
# over that investigation's 1,622-agent corpus (machinery 31.8% / item
# workers 68.2%; median profiled worker 61 calls, ~161K peak context).
: "${SPEND_MACHINERY_MAX_CALLS:=6}"
: "${SPEND_WORKER_PROFILE_MIN_CALLS:=40}"
#
# Transcript root. Claude Code's own per-project state dir; the profiler walks
# `$SPEND_TRANSCRIPT_ROOT/**/subagents/workflows/wf_*/agent-*.jsonl` under it
# and reads nothing else. Point it at a fixture tree to test, or at a synced
# copy of another host's transcripts to profile that host.
: "${SPEND_TRANSCRIPT_ROOT:=$HOME/.claude/projects}"

# ── knowledge_store root (foundation #777, Epic A #762 "kernel split";
#    kernel-literal-scrub, temperloop#189) ──────────────────────────────────
# `workflows/scripts/lib/knowledge_store.sh` (the document-I/O seam) owns
# `KNOWLEDGE_STORE_ROOT`'s KERNEL default (an XDG per-user data dir, correct
# for a stranger's fresh install with no vault). THIS file — the kernel's own
# tracked layer-5 default set — deliberately does NOT re-seed a different
# default here: a personal vault path is exactly the kind of operator-
# specific value the six-layer ladder's layers 3/4 (machine conf /
# build.config.local.sh, both sourced ABOVE this point) exist for, or —
# for a downstream repo that vendors this file — its own edited copy of
# this line (layer 5's own "consuming repo that vendors/edits its own copy"
# case, per the ladder writeup above). An operator whose structured notes
# live in a real vault sets `KNOWLEDGE_STORE_ROOT` at one of those layers;
# this kernel file simply leaves the var unset here and lets
# `knowledge_store.sh`'s own generic default apply when nothing upstream
# has claimed it. (Formerly this file hardcoded a personal vault path here
# as a layer-5 default — removed as scrub debt; see git history on this
# line for the prior literal.)

# ── Pipeline label provisioning (temperloop#795) ───────────────────────────────
# BOTH pipeline labels above (`funnel-merge-pending`, `funnel-escalated`) must EXIST in
# every repo the pipeline drives, or a silent-thrash failure results (see
# pipeline-drive.sh's own "Pipeline label self-provisioning" comment for the failure
# mode). This used to be a manual, onboarding-time `gh label create` step documented
# here — now SELF-HEALING: pipeline-drive.sh ensures each label at its point of use
# via the board adapter's memoized `_board_issues_ensure_label` (lib/board.sh:1149),
# the same idiom capture.sh's self-healing `fnd:` labels use, so no third repo needs a
# manual onboarding step here at all.

# ── Comparison-statistics library (temperloop#1249, epic #1225 "model
#    comparison harness") ───────────────────────────────────────────────────
# workflows/scripts/model-comparison/stats.sh: bootstrap confidence intervals,
# the minimum-detectable-effect disclosure, the inconclusive floor, and
# emit-coverage %. Every one of these five is a real operator-facing tunable
# (named symbolically in stats.sh's own header, never re-valued in prose —
# see § Named-setting convention).
#
# Sample-size floor: below this many outcomes, `verdict` is ALWAYS
# "inconclusive" and never returns a winner, whatever the bootstrap CI shows.
: "${MODEL_COMPARISON_MIN_SAMPLE_N:=20}"
# Percentile-bootstrap resample count.
: "${MODEL_COMPARISON_BOOTSTRAP_ITERATIONS:=2000}"
# Resampling RNG seed — fixed (not time-varying) so the SAME deltas always
# reproduce the SAME confidence interval; a real report needs a reproducible
# number, and the library's own known-answer fixture test depends on this.
: "${MODEL_COMPARISON_BOOTSTRAP_SEED:=1729}"
# Confidence-interval width (pct), e.g. 95 = a 95% CI. Also the width the
# minimum-detectable-effect figure is computed at, so the MDE and the CI it
# bounds are always stated at the same confidence.
: "${MODEL_COMPARISON_CI_WIDTH_PCT:=95}"
# `coverage`'s denominator: the emit-FEASIBLE seat subset the L0
# usage-capture-feasibility spike (temperloop#1246) measured — "only 3 of the
# pipeline's 12 spawn seats can emit a token-bearing attribution record
# today" — deliberately NOT the full 12-seat inventory. A coverage figure
# below 100% is expected and structural, not a defect to chase to zero.
: "${MODEL_COMPARISON_EMIT_FEASIBLE_SEATS:=3}"

# ── Replay corpus selection + isolation (temperloop#1254, epic #1225 "model
#    comparison harness") ───────────────────────────────────────────────────
# workflows/scripts/model-comparison/replay.sh: `corpus` (real `gh` reads,
# selects eligible closed-issue + merged-PR pairs from this repo's own
# history) and `worktree-prepare`/`worktree-teardown` (the isolated replay
# worktree, built on workflows/scripts/build/worktree.sh's existing lifecycle
# — see that file's header and Context/temperloop - replay ground-truth seam.md
# for why replay.sh adds no flag there and instead rewinds an unmodified
# `create`). Four operator-facing tunables, named symbolically in replay.sh's
# own header, never re-valued in prose (§ Named-setting convention).
#
# Default number of merged PRs `corpus` asks `gh pr list` for when no
# explicit `--limit`/`--target` is given. The ground-truth spike measured a
# ~52% survival rate applying the scope-closure rule to 46 single-issue
# merged PRs (temperloop#1247) — this default is sized to that same
# ballpark scan.
: "${REPLAY_CORPUS_LIMIT:=60}"
# Multiplier `corpus --target N` applies to compute its default `--limit`
# (limit = target * multiplier) when `--limit` is not given explicitly. 2x
# is the spike's own measured corpus-yield guidance: "budget ~2x its target
# size" (24/46 = 52% usable survival after scope closure).
: "${REPLAY_CORPUS_SAMPLE_MULTIPLIER:=2}"
# Space-separated file-extension list `diff-scope`'s N-bucket (solution-
# surface) path extraction matches against the pre-cut issue text — mirrors
# the spike's own demonstrated named-path regex
# (`[A-Za-z0-9_./-]+\.(py|sh|mjs|md|tsv|json)`).
: "${REPLAY_NAMED_PATH_EXTENSIONS:=py sh mjs md tsv json}"
# The sentinel `remote.origin.pushurl` value `worktree-prepare` writes,
# scoped ONLY to the replay worktree via git's per-worktree config extension
# (`extensions.worktreeConfig`), so a `git push` issued from inside an
# isolated replay worktree cannot resolve a real transport — structural,
# not a post-hoc probe. Deliberately not a real-looking URL, so a stray push
# attempt fails fast on an unresolvable scheme rather than hanging on DNS.
: "${REPLAY_PUSH_DISABLE_SENTINEL:=replay-worktree-push-disabled://no-remote}"

export BUILD_QUOTA_PAUSE_PCT BUILD_QUOTA_CACHE BUILD_QUOTA_WAIT_BUFFER \
       BUILD_QUOTA_MAX_AGE BUILD_MERGE_GATE_WINDOW BUILD_QUEUE_TIMEOUT BUILD_QUEUE_STALL_AFTER \
       BUILD_HEADLESS_POLL_TIMEOUT \
       BUILD_MERGE_BACKEND BUILD_COMBINED_TREE_PRECHECK BUILD_MERGE_AS_YOU_GO \
       PIPELINE_DRIVE_CONCURRENCY EPIC_MIN_SUBUNITS DISPLAY_TZ \
       ASSESS_POLL_FIRST_WAKE ASSESS_POLL_CADENCE ASSESS_POLL_BUDGET \
       NEXT_SEQ_STALE_AFTER TIDY_SYNC_WAIT TIDY_LOCK_STALE_AFTER CHECKIN_PRUNE_DAYS \
       SWEEP_FANOUT_WIDTH SWEEP_DETECT_MODEL SWEEP_WORKER_MODEL SWEEP_BG_POLL_ATTEMPTS SWEEP_BG_POLL_INTERVAL \
       FIX_WORKER_MODEL BUILD_MACHINERY_SOLO_MODEL BUILD_MACHINERY_BATCH_MODEL BUILD_GATE_SLICE_SECS \
       BUILD_MACHINERY_STEP_CEILING_SECS BUILD_MACHINERY_STEP_SLOW_SECS \
       PIPELINE_OPERATOR PIPELINE_REQUIRED_CHECK \
       PIPELINE_DRIVE PIPELINE_DRIVE_CAP PIPELINE_DRIVE_MODEL PIPELINE_DRIVE_SETTINGS \
       PIPELINE_DRIVE_MERGE PIPELINE_DRIVE_MERGE_CAP PIPELINE_DRIVE_MERGE_MODEL PIPELINE_DRIVE_MERGE_SETTINGS \
       PIPELINE_MERGE_PENDING_LABEL PIPELINE_CLARIFIED_MARKER PIPELINE_ESCALATED_LABEL \
       RETRO_MINT_ENABLED RETRO_MIN_INTERVAL RETRO_URGENT_CI_RETRIES \
       RETRO_BATCH_SESSION_CAP RETRO_JUDGE_MODEL \
       CONFIGURE_AI_MODEL \
       REVIEWER_SCAN_MIN_FILES \
       PROSE_BUDGET_TIER1_CAP PROSE_BUDGET_TIER2_FILE_CAP \
       SPEND_WEIGHT_INPUT SPEND_WEIGHT_CACHE_READ SPEND_WEIGHT_CACHE_CREATE SPEND_WEIGHT_OUTPUT \
       SPEND_MACHINERY_MAX_CALLS SPEND_WORKER_PROFILE_MIN_CALLS SPEND_TRANSCRIPT_ROOT \
       KNOWLEDGE_STORE_ROOT \
       MODEL_COMPARISON_MIN_SAMPLE_N MODEL_COMPARISON_BOOTSTRAP_ITERATIONS MODEL_COMPARISON_BOOTSTRAP_SEED \
       MODEL_COMPARISON_CI_WIDTH_PCT MODEL_COMPARISON_EMIT_FEASIBLE_SEATS \
       REPLAY_CORPUS_LIMIT REPLAY_CORPUS_SAMPLE_MULTIPLIER REPLAY_NAMED_PATH_EXTENSIONS \
       REPLAY_PUSH_DISABLE_SENTINEL
