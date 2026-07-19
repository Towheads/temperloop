#!/usr/bin/env bash
#
# build.config.sh — central defaults for the build / sweep
# tunables (foundation #447). This is the ONE place a batch-pipeline knob's
# default lives; `source` it (the spine scripts and the command Step 0 do) to
# pull every tunable into scope.
#
# Idiom: `: "${VAR:=default}"` assigns the default ONLY when VAR is unset, so a
# pre-existing environment value (a shell export, a `.env`, an inline
# `VAR=… cmd`) always WINS over the default here. To change a default globally,
# edit the line below.
#
# This file is sourced, never executed — it has no CLI and writes nothing.
#
# ── The six-rung config PRECEDENCE ladder (temperloop#164/#169) ────────────
# NOTE: "precedence rung" here is unrelated to the funnel's own "rung-5b" /
# "rung-5c" driver-tier terminology used later in this file (§ Funnel rung-5b
# driver / § Funnel rung-5c merge tier below) — same word, two different
# ladders; this section always says "precedence rung N" to keep them apart.
#
# Every knob this file governs resolves through the same precedence ladder,
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
#                            at all (see e.g. FUNNEL_OPERATOR /
#                            FUNNEL_MERGE_PENDING_LABEL below — several
#                            spine scripts already keep one of these)
#
# Precedence rungs 5 and 6 are BOTH implemented by `:=` assignments, just in
# two different places (this file vs. an individual script) — a consuming
# repo that vendors this file gets rung 5; a script invoked standalone
# without it falls through to rung 6. Rungs 3 and 4 are sourced BELOW, before
# rung 5's defaults, so that (per the `:=` idiom) a value they set is already
# bound by the time rung 5 runs and its own `:=` becomes a no-op for that var
# — this is what makes source order double as precedence order. Full ladder
# writeup, and how `boards.conf`'s XDG-then-repo-local discovery is an
# INSTANCE of this same order: ../../../docs/config-precedence.md.
#
# ── Precedence rung 3: machine conf ─────────────────────────────────────────
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

# ── Precedence rung 4: untracked repo-local conf (secrets / per-checkout override; #709) ──
# Source an OPTIONAL, gitignored sibling `build.config.local.sh` for
# checkout-local secrets and overrides that must NOT be committed — e.g. the
# funnel's Sentry poll credentials (SENTRY_AUTH_TOKEN / SENTRY_ORG /
# SENTRY_PROJECT) that /signal-intake reads via funnel-tick.sh Phase 0.
# Sourced here, BEFORE this file's own `:=` defaults below, so it outranks
# them — but AFTER precedence rung 3 (machine conf) above, so machine conf
# still wins. An absent file is a silent no-op (never fatal), and being untracked it
# survives the funnel cron's self-update `git reset --hard`. The path is
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

# ── Precedence rung 5 / 6: tracked repo conf / kernel built-in defaults ─────
# Everything below is this file's own `:=` default set. It runs LAST, after
# precedence rungs 3 and 4 above, so any var they already bound is left
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

# ── Existing build knobs, centralized here (#447) ───────────────────────
# These predate this file; their defaults now live here. build.md prose
# keeps its inline `${VAR:-default}` as a belt-and-suspenders fallback for callers
# that did not source this file.
: "${BUILD_MERGE_GATE_WINDOW:=300}"   # timed merge-gate window (s); 0 = always modal
: "${BUILD_QUEUE_TIMEOUT:=1800}"      # per-PR native-merge-queue timeout (s)

# Autonomous funnel drive-concurrency governor (temperloop#162, split out from the
# retired human "WIP cap" governance rule): at most this many concurrent drives the
# autonomous funnel lane bounds per tick. SOURCE OF TRUTH for funnel-tick.sh's
# autonomous-lane concurrency bound (which is explicitly INHERITED from this policy,
# not re-embedded — see that file's own comment). This is the mechanical governor
# ONLY — the former human "WIP cap = 3" cross-session governance rule it used to
# double as was retired in temperloop#162 (the In-Progress gate + claim-first lock
# in claude/CLAUDE.kernel.md's Task-workflow section stay; the numeric human cap is
# gone). Change the funnel's concurrency bound here, once.
: "${FUNNEL_DRIVE_CONCURRENCY:=3}"

# Epic-decomposition sub-unit threshold (prose-tunables-migration follow-up to
# temperloop#183): a second "CLAUDE.md-resident knob" rendered at compose time
# into claude/CLAUDE.kernel.md's Task-workflow section — "epic-sized" is
# `{{EPIC_MIN_SUBUNITS}}`+ parallelizable sub-units (OR more than one
# dependency level, which stays a structural/contract fact, not a separate
# knob — see that section's own note). Rendered into the kernel doc at compose
# time by workflows/scripts/install-claude-md.sh.
: "${EPIC_MIN_SUBUNITS:=3}"

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
# HEADLESS one-shot path (FUNNEL_OPERATOR_ABSENT=1 — the funnel `claude -p` merge
# driver, which has no re-invoke-on-background-completion loop, so its waits must
# block the single session in the foreground rather than dispatch-and-yield, #626).
# Kept under the ~10-min Bash foreground cap; the session itself is un-timeout'd, so
# 3g/4b can chain several sequential foreground polls, and the #624 hand-off marker
# catches any tail that outlasts them. Operator-present runs ignore this (they keep
# the run_in_background + ScheduleWakeup path).
: "${BUILD_HEADLESS_POLL_TIMEOUT:=540}"  # foreground CI/MERGED poll bound (s), headless path

# ── Command-spec prose knobs (prose-tunables-migration, temperloop#164/#169
#    D3 follow-up) ──────────────────────────────────────────────────────────
# These knobs back a value that previously lived ONLY in a command spec's
# prose (no shell seam at all — the D3 "prose names a knob, never states its
# value" convention had nothing to point at). Each command spec now sources
# THIS file at its own Step 0 (the same worked shape as build.md Step 0 item
# 6) and references the symbolic name below instead of restating the
# literal. Centralized here rather than a per-command config file — one
# place, per § Prose-resident knob convention (`claude/CLAUDE.kernel.md`).

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

# ── Funnel operator identity + required CI check (tracker seam v0, #772) ────
# The operator handle the async decision-issue backend, the merge-tier escalation
# path, and funnel-tick's assignee baton all target. MUST be the operator's real
# GitHub collaborator LOGIN (verify with `gh api user -q .login` — a display
# name or email-derived handle can differ from the real login, and a re-assign
# to the wrong one targets nobody / fails, so the baton never reaches the
# operator; foundation #588). Consuming scripts (funnel-tick.sh, funnel-drive.sh)
# keep a matching `:=` fallback for a non-vendoring checkout, exactly as
# FUNNEL_MERGE_PENDING_LABEL does; this file is the SOURCE OF TRUTH. `gh` wants
# the bare login, so the leading @ is stripped at each use site. The placeholder
# below MUST be overridden — set the real value in the gitignored
# build.config.local.sh (§ Precedence rung 4 above), never here.
: "${FUNNEL_OPERATOR:=@REPLACE_WITH_YOUR_GH_LOGIN}"

# Required CI gate name a PR must clear to merge (foundation #665). Every build
# repo names its required ci.yml job `checks` (global CLAUDE.md § Branch & PR
# policy), so one default serves all boards.
: "${FUNNEL_REQUIRED_CHECK:=checks}"

# ── Funnel-overlap predicate (#864) ─────────────────────────────────────────
# The funnel's OPERATIONAL SURFACE — space-separated path prefixes that
# funnel-overlap.sh intersects a plan's aggregate `files:` set against at
# /build run start (Step 1.7). A plan that rewrites this machinery while the
# funnel is live is the Epic B interference cascade (retro #847): the default
# names the build spine + board toolkit + pipeline commands/hooks + quality
# gates + Makefile, under both the kernel/ vendored prefix and the compat
# pre-split paths. Prefix match is textual, so both spellings must be listed.
: "${FUNNEL_DRIVEN_PATHS:=kernel/ workflows/scripts/ claude/commands/ claude/workflows/ claude/hooks/ scripts/quality-gates Makefile}"

# ── Funnel rung-5b driver (#604) ────────────────────────────────────────────
# The autonomous funnel driver's supervised auto-drive. Default OFF: the cron
# stays pure 5a (emit + notify) until the operator opts in. Set FUNNEL_DRIVE=1
# (a deploy host's LaunchAgent/cron plist sets it when the 5b soak begins) to make
# funnel-cron.sh execute the SAFE, no-merge tier of each tick plan via a headless
# funnel-drive.sh / `claude -p "/funnel-drive"` run. See funnel-drive.sh.
: "${FUNNEL_DRIVE:=0}"                 # 1 = auto-execute the safe tier; 0 = emit-only (5a)
# Per-tick DRIVE CAP — the canonical "how many items the funnel drives per tick"
# knob (#642). funnel-tick.sh caps the number of Operational drive-ready actions it
# EMITs per tick on this (was a hardcoded one-per-tick); funnel-cron.sh resolves the
# operator's vault `cap:` (the ```funnel-schedule block) into it and ALSO maps it onto
# FUNNEL_DRIVE_MERGE_CAP below, so one vault field governs both the emit cap and the
# merge blast-radius. The `:=1` here is only the fallback when the vault omits `cap:`
# (and for a bare manual `funnel-tick.sh` run); the vault is the live source of truth.
: "${FUNNEL_DRIVE_CAP:=1}"             # max Operational items driven per tick (vault `cap:` feeds this)
: "${FUNNEL_DRIVE_MODEL:=claude-sonnet-5}"  # model for the headless driver (mechanical actions)
: "${FUNNEL_DRIVE_SETTINGS:=}"         # --settings overlay for the headless driver (#606);
                                       # empty here → funnel-drive.sh defaults it to its
                                       # repo-relative funnel-drive.settings.json (deny gh pr/git
                                       # push + a broad allow for the full safe tier — #609)

# ── Funnel rung-5c merge tier (#615) ────────────────────────────────────────
# The merging tier of the autonomous driver: drive-ready WHERE kind=="code"
# (→ /build --unattended → PR → CI → merge). 5b (above) leaves this for the
# operator; 5c auto-executes it on /build's existing timed/modal merge gate.
# A SEPARATE gate from FUNNEL_DRIVE — flipping the safe tier on must NOT flip
# merging on. The merge tier RIDES ON TOP of the safe tier: it runs only when
# the cron already invokes funnel-drive.sh (FUNNEL_DRIVE=1) AND this is 1.
# Default OFF ⇒ the merge tier is surfaced-but-not-driven, exactly as in 5b.
: "${FUNNEL_DRIVE_MERGE:=0}"           # 1 = also auto-execute the kind:code merge tier; 0 = leave for operator
# Merge blast-radius bound. Since #642 this is FED from the vault `cap:` by
# funnel-cron.sh (it exports FUNNEL_DRIVE_MERGE_CAP=$cap alongside FUNNEL_DRIVE_CAP),
# so the operator sets it via the vault schedule, NOT the plist. The `:=1` here is
# only the fallback when the cron does not resolve a cap (e.g. a bare funnel-drive.sh run).
: "${FUNNEL_DRIVE_MERGE_CAP:=1}"       # max kind:code items driven to merge per tick (vault `cap:` feeds this)
: "${FUNNEL_DRIVE_MERGE_MODEL:=claude-opus-4-8}"  # model for the merge driver (code drives are high-judgment)
: "${FUNNEL_DRIVE_MERGE_SETTINGS:=}"   # --settings overlay for the merge driver; empty here →
                                       # funnel-drive.sh defaults it to funnel-drive-merge.settings.json
                                       # (the inverse of the 5b overlay: ALLOWS the scoped gh pr/merge/push
                                       # surface /build needs, still never --dangerously-skip-permissions)

# Cross-tick merge hand-off (#624), now the bounded-timeout TAIL after #626. Since
# #626, a headless `claude -p` merge drive runs /build's CI-watch + merge gate in the
# FOREGROUND and the normal outcome is merged-in-session. This label covers the tail:
# when /build's foreground CI/MERGED poll hits its BUILD_HEADLESS_POLL_TIMEOUT bound
# before the merge lands (CI/queue slower than the session can foreground-wait), the
# drive splits across ticks. funnel-drive.sh applies the label to an issue whose drive
# left an OPEN, unmerged PR (ground-truth probe, not a model self-report), and
# funnel-tick.sh, on seeing it, emits a RESUME drive (re-attach to the open PR + run
# /build's merge gate) instead of a FRESH one — which would open a duplicate PR. The
# open PR remains the artifact work resumes on; the label is the cheap board pointer.
: "${FUNNEL_MERGE_PENDING_LABEL:=funnel-merge-pending}"

# Clarification-drain sentinel (foundation #657) — centralized here so the
# writer/reader pair share ONE source of truth (the drift the reviewer flagged):
#   FUNNEL_CLARIFIED_MARKER — the ack the 5b executor posts on a drained
#     `needs-clarification` item; funnel-tick's clarification_already_applied reads
#     it for idempotency. (The prose writer /funnel-drive.md cannot source config,
#     so that one literal stays hand-synced to this value.)
: "${FUNNEL_CLARIFIED_MARKER:=<!-- funnel:clarification-drained -->}"

# Rung-5c code-escalation label (foundation #697, supersedes the #657 merge-escalation
# marker). A 5c CODE escalation (route-refused / terminally-red CI) carries THIS label
# + an assignee — NOT `needs-clarification` — so the #657 answer-drain's
# `label:needs-clarification … no:assignee` search can never match it (no marker, no
# per-item comment scan, no skip verb needed). funnel-tick's park gate keeps such an
# item out of the drive pool (duplicate-PR guard). Consuming scripts keep a matching
# `:=` fallback for a non-vendoring checkout, exactly as FUNNEL_MERGE_PENDING_LABEL does.
: "${FUNNEL_ESCALATED_LABEL:=funnel-escalated}"

# ── Unified-retrospection RETRO_* knobs (temperloop#532) ────────────────────
# These five knobs are NAMED (in prose) by other items of the
# unified-retrospection epic and VALUED only here, per § Prose-resident knob
# convention (`claude/CLAUDE.kernel.md`) — a command spec (`build.md`'s
# 4d-retro MINT step, the funnel tick's retro-judge emit, `/retro` itself)
# references `$RETRO_*` symbolically and never restates the literal.

# Master on/off for the `/build` 4d-retro MINT (files a per-epic retro
# tracker at epic close). Default ON.
: "${RETRO_MINT_ENABLED:=1}"

# Debounce: minimum age (s) of the oldest `retro-pending` tracker before the
# funnel tick emits a retro-judge action. Default a 3-day cadence.
: "${RETRO_MIN_INTERVAL:=259200}"

# CI-retry count at/above which a retro tracker is stamped `retro-urgent` at
# mint time (bypasses the debounce above).
: "${RETRO_URGENT_CI_RETRIES:=3}"

# Max number of retro trackers a single `/retro --pending` judge session
# processes (enforced judge-side).
: "${RETRO_BATCH_SESSION_CAP:=5}"

# Model the funnel runs `claude -p "/retro --pending"` under — its own named
# model knob, distinct from FUNNEL_DRIVE_MODEL (same tier: the judge is a
# safe/standard drive, not a merge-tier high-judgment one).
: "${RETRO_JUDGE_MODEL:=claude-sonnet-5}"

# ── Language-reviewer catalog coverage scan (temperloop#538, ADR 0007/0008) ──
# The catalog's install-time coverage scan (and `make doctor`'s matching
# check) count each candidate language's files in the repo and offer
# activation only for a language that clears this floor — a repo with a
# single stray `.rb` file should not be offered a Ruby reviewer it doesn't
# need. This is INSTALL/DOCTOR-TIME machinery, not a batch-build-pipeline
# knob (contrast FUNNEL_DRIVE_CONCURRENCY above). Default 3: low enough that
# a small-but-real component (a handful of shell scripts, a slim Python
# helper) still gets offered its reviewer, high enough that a single
# generated/vendored/example file doesn't trigger a false-positive offer.
: "${REVIEWER_SCAN_MIN_FILES:=3}"

# ── knowledge_store root (foundation #777, Epic A #762 "kernel split";
#    kernel-literal-scrub, temperloop#189) ──────────────────────────────────
# `workflows/scripts/lib/knowledge_store.sh` (the document-I/O seam) owns
# `KNOWLEDGE_STORE_ROOT`'s KERNEL default (an XDG per-user data dir, correct
# for a stranger's fresh install with no vault). THIS file — the kernel's own
# tracked rung-5 default set — deliberately does NOT re-seed a different
# default here: a personal vault path is exactly the kind of operator-
# specific value the six-rung ladder's rungs 3/4 (machine conf /
# build.config.local.sh, both sourced ABOVE this point) exist for, or —
# for a downstream repo that vendors this file — its own edited copy of
# this line (rung 5's own "consuming repo that vendors/edits its own copy"
# case, per the ladder writeup above). An operator whose structured notes
# live in a real vault sets `KNOWLEDGE_STORE_ROOT` at one of those rungs;
# this kernel file simply leaves the var unset here and lets
# `knowledge_store.sh`'s own generic default apply when nothing upstream
# has claimed it. (Formerly this file hardcoded a personal vault path here
# as a rung-5 default — removed as scrub debt; see git history on this
# line for the prior literal.)

# ── Funnel label provisioning (a repo-onboarding prerequisite) ───────────────
# BOTH funnel labels above (`funnel-merge-pending`, `funnel-escalated`) must EXIST in
# every repo the funnel drives. funnel-drive.sh applies them via `gh issue edit
# --add-label` wrapped in the fail-open `_gh_sideeffect` recorder — so on a repo MISSING
# the label the add is swallowed, the item never parks, and it re-refuses/re-routes every
# tick (a silent thrash; the operator never gets the hand-off). Currently provisioned on
# the two driven repos. To onboard a THIRD repo,
# create both first (idempotent — the `|| true` absorbs "already exists"):
#   gh label create funnel-merge-pending -R <owner/repo> --color fbca04 --description "Funnel 5c: PR open, session ended pre-merge — resume next tick" || true
#   gh label create funnel-escalated     -R <owner/repo> --color fbca04 --description "Funnel 5c: stuck code item (route-refused / red CI) — needs your manual merge or close" || true

export BUILD_QUOTA_PAUSE_PCT BUILD_QUOTA_CACHE BUILD_QUOTA_WAIT_BUFFER \
       BUILD_QUOTA_MAX_AGE BUILD_MERGE_GATE_WINDOW BUILD_QUEUE_TIMEOUT BUILD_HEADLESS_POLL_TIMEOUT \
       BUILD_MERGE_BACKEND FUNNEL_DRIVE_CONCURRENCY EPIC_MIN_SUBUNITS \
       ASSESS_POLL_FIRST_WAKE ASSESS_POLL_CADENCE ASSESS_POLL_BUDGET \
       NEXT_SEQ_STALE_AFTER TIDY_SYNC_WAIT TIDY_LOCK_STALE_AFTER CHECKIN_PRUNE_DAYS \
       FUNNEL_OPERATOR FUNNEL_REQUIRED_CHECK \
       FUNNEL_DRIVE FUNNEL_DRIVE_CAP FUNNEL_DRIVE_MODEL FUNNEL_DRIVE_SETTINGS \
       FUNNEL_DRIVE_MERGE FUNNEL_DRIVE_MERGE_CAP FUNNEL_DRIVE_MERGE_MODEL FUNNEL_DRIVE_MERGE_SETTINGS \
       FUNNEL_MERGE_PENDING_LABEL FUNNEL_CLARIFIED_MARKER FUNNEL_ESCALATED_LABEL \
       RETRO_MINT_ENABLED RETRO_MIN_INTERVAL RETRO_URGENT_CI_RETRIES \
       RETRO_BATCH_SESSION_CAP RETRO_JUDGE_MODEL \
       REVIEWER_SCAN_MIN_FILES \
       KNOWLEDGE_STORE_ROOT
