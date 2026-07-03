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

# Per-Bash-call bound for the FOREGROUND CI / MERGED polls /build runs on a
# HEADLESS one-shot path (FUNNEL_OPERATOR_ABSENT=1 — the funnel `claude -p` merge
# driver, which has no re-invoke-on-background-completion loop, so its waits must
# block the single session in the foreground rather than dispatch-and-yield, #626).
# Kept under the ~10-min Bash foreground cap; the session itself is un-timeout'd, so
# 3g/4b can chain several sequential foreground polls, and the #624 hand-off marker
# catches any tail that outlasts them. Operator-present runs ignore this (they keep
# the run_in_background + ScheduleWakeup path).
: "${BUILD_HEADLESS_POLL_TIMEOUT:=540}"  # foreground CI/MERGED poll bound (s), headless path

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
# build.config.local.sh (§ Host-local override below), never here.
: "${FUNNEL_OPERATOR:=@REPLACE_WITH_YOUR_GH_LOGIN}"

# Required CI gate name a PR must clear to merge (foundation #665). Every build
# repo names its required ci.yml job `checks` (global CLAUDE.md § Branch & PR
# policy), so one default serves all boards.
: "${FUNNEL_REQUIRED_CHECK:=checks}"

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

# ── knowledge_store root (foundation #777, Epic A #762 "kernel split") ──────
# `workflows/scripts/lib/knowledge_store.sh` (the document-I/O seam) owns
# `KNOWLEDGE_STORE_ROOT`'s KERNEL default (an XDG per-user data dir, correct
# for a stranger's fresh install with no vault) — that file is not edited by
# script-plane callers routing onto the seam. THIS repo's own environment is
# different: the operator's structured notes live in an Obsidian vault at
# $HOME/dev/mind (today's behavior, unconditionally, predating the seam), so
# this is the ONE place that foundation-specific default is seeded — every
# script-plane caller that sources this file before `ks_root` (or shells out
# through it, e.g. parse_run_status.py's find_knowledge_store_root()) resolves
# the SAME value a caller reading `~/dev/mind` directly used to hardcode,
# without any of them repeating the literal. A real environment override (a
# shell export, `.env`, or build.config.local.sh below) still wins per the
# `:=` idiom.
: "${KNOWLEDGE_STORE_ROOT:=$HOME/dev/mind}"

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
       FUNNEL_OPERATOR FUNNEL_REQUIRED_CHECK \
       FUNNEL_DRIVE FUNNEL_DRIVE_CAP FUNNEL_DRIVE_MODEL FUNNEL_DRIVE_SETTINGS \
       FUNNEL_DRIVE_MERGE FUNNEL_DRIVE_MERGE_CAP FUNNEL_DRIVE_MERGE_MODEL FUNNEL_DRIVE_MERGE_SETTINGS \
       FUNNEL_MERGE_PENDING_LABEL FUNNEL_CLARIFIED_MARKER FUNNEL_ESCALATED_LABEL \
       KNOWLEDGE_STORE_ROOT

# ── Host-local override (secrets / per-host env; #709) ───────────────────────
# Source an OPTIONAL, gitignored sibling `build.config.local.sh` for host-local
# secrets and per-host overrides that must NOT be committed — e.g. the funnel's
# Sentry poll credentials (SENTRY_AUTH_TOKEN / SENTRY_ORG / SENTRY_PROJECT) that
# /signal-intake reads via funnel-tick.sh Phase 0. Sourced LAST so it wins over
# the defaults above; an absent file is a silent no-op (never fatal), and being
# untracked it survives the funnel cron's self-update `git reset --hard`. The
# path is overridable via BUILD_CONFIG_LOCAL (a test seam that also lets a host
# point elsewhere). Template + mini install: build.config.local.sh.example.
: "${BUILD_CONFIG_LOCAL:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build.config.local.sh}"
if [ -f "$BUILD_CONFIG_LOCAL" ]; then
  # shellcheck source=/dev/null
  . "$BUILD_CONFIG_LOCAL"
fi
