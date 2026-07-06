#!/usr/bin/env bash
#
# funnel-tick.sh — the autonomous funnel driver's per-board tick (foundation
# #569). A THIN SCHEDULER: it CALLS the existing `/triage → /assess → /build`
# pipeline and inherits every hardened behavior (WIP cap, quota gate,
# claim-first, timed merge gate, epic lifecycle) — it NEVER re-embeds any of it.
# Re-implementing a pipeline step is a contract violation (see
# `Decisions/foundation - Autonomous funnel driver + GitHub decision queue`
# § Scheduler-not-pipeline + the CORRECTION).
#
# Each tick, per ENABLED board, runs these phases:
#   0. intake          — invoke /signal-intake (crash-convergence, foundation
#                        #671/#637) BEFORE any spend decision below, so it runs
#                        on every tick, spend-open or spend-closed. Best-effort:
#                        a failure is caught, logged, and never blocks the tick.
#   A. drain-answered  — find decision issues the operator answered+unassigned,
#                        classify each typed reply, and EMIT the drain action
#                        (build.md Step 0a / tidy.md § Answered decisions
#                        own the apply; this script routes, it does not apply).
#   A2. drain-clarification — the clarification counterpart (foundation #657): find
#                        `needs-clarification` issues the operator answered+unassigned
#                        (same baton) and EMIT a drain that clears the label so the
#                        item becomes drivable again. No reply parse — the free-text
#                        answer already on the issue rides into the next drive.
#   B. drive-ready     — for one Operational Ready item, EMIT the
#                        `/assess`→`/build --unattended` invocation the Claude
#                        layer executes. The script never assesses/builds.
#   C. route-foundational — for one Foundational Ready item, EMIT the
#                        decision-queue routing (build.md's decision-issue
#                        backend posts the gate; this script names it).
#
# WHY "EMIT", not "do": `/triage`, `/assess`, `/build` are prose specs executed
# by Claude, not callable binaries. The deterministic half — single-flight,
# board ON/OFF, the decision-drain query, the Operational/Foundational
# classification, the routing decision — is pure machine state and lives HERE.
# The judgment/agent half (actually running a prose command) is named in the
# emitted plan and run by the Claude driver layer. This split is what keeps the
# scheduler thin: this script decides WHAT to call; it never reimplements it.
#
#   funnel-tick.sh                              # live tick over enabled boards
#   funnel-tick.sh --board 3                    # live tick, one board
#   funnel-tick.sh --dry-run --fixture <dir>    # offline tick against a stub
#   funnel-tick.sh --list-enabled               # print the ON boards, exit
#
# --dry-run --fixture <dir> is the ACCEPTANCE path (off the live board): every
# `gh`/board read is served from files under <dir> instead of the network, and
# every mutation (label drop, assign, merge) is RECORDED to the emitted plan
# rather than executed. The fixture layout is documented in
# tests/test_funnel_tick.sh (the test seeds it).
#
# A `needs-clarification` item is an OPERATOR-INPUT gate, and ASSIGNMENT is the
# baton (foundation#684/#657) — the two states are keyed on `no:assignee`:
#   • STILL ASSIGNED (awaiting the answer) → PARKED in the Ready loop as
#     `route-already-assigned`. The producer that raised the question (`/triage` or
#     `/sweep` park-on-question) already assigned the operator + posted the question
#     AT SOURCE (#684), so the item is already in the operator's assigned-to-me queue
#     and the funnel has nothing to assign — the label alone means "not autonomously
#     actionable → park". (A rung-5c CODE escalation is a SEPARATE gate since #697: it
#     carries its own `funnel-escalated` label, parked by the funnel_escalated gate,
#     and is never drained. It is NOT a `needs-clarification` producer.) (This
#     supersedes #600's `route-needs-input`, which existed only to do the assign the
#     producers
#     now own.)
#   • UNASSIGNED (operator answered in a comment + unassigned = baton returned) →
#     DRAINED in Phase A2 as `drain-clarification`: the label is cleared so the item
#     becomes drivable again on the next tick (#657, the answer-consumption gap —
#     previously NOTHING autonomous cleared the label, so an answered item parked
#     forever). Phase A2 runs first and records drained numbers so the Ready-loop
#     park gate does not also park them. `spike` is NOT matched here. NOTE:
# foundation#594 originally also lumped `spike` into this
# skip-gate — that was wrong (#600). A `spike` is automatable read-only
# investigation whose verdict feeds a decision AFTER it runs (build.md's kind:spike
# path writes the note + routes a follow-up); it is a DRIVE target, not an
# operator-input gate, so it now falls through to `drive-ready` like any Operational
# item — and is in fact the SAFEST auto-drive (no PR, no merge).
#
# Output contract — a JSON "tick plan" (one object) on stdout: the ordered list
# of actions the tick decided, each a {phase, board, action, …} record. In a
# live run the Claude driver executes the EMITted command actions; in a
# --dry-run the plan IS the verifiable artifact (no side effects). The closed
# action set: drain-answer · drain-parse-miss · drain-already-applied
# · drain-clarification · drain-clarification-already-applied
# · drive-ready · route-foundational · route-already-assigned
# · skip-contention · no-op.
#
# Single-flight: a flock lockfile (the contract's § 4 convention) so two
# overlapping ticks never double-act. The lock is released by fd-close on exit
# (clean or crash), never by rm — a crashed run's lock is reaped by the OS.
set -euo pipefail

# Attribution for the gh call-logger shim (F#988): tag every gh call this command
# makes with its outermost context. `:-` preserves an already-set (outer) value,
# so an autonomous driver's context wins over a nested command. See
# workflows/scripts/gh-call-logger.sh.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-funnel-tick}"

command -v jq >/dev/null 2>&1 || { echo '{"error":"jq not found"}' >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Config (env overrides win; defaults centralized in build.config.sh) ──────
# shellcheck source=workflows/scripts/build/build.config.sh
[ -f "$HERE/build.config.sh" ] && . "$HERE/build.config.sh"

# The set of boards the driver is ENABLED on. PILOT = stageFind (board 3) ONLY
# (the ON/OFF flip; foundation#569). To enable another board, add its logical
# number here (space-separated) — that is the entire "board ON/OFF" mechanism:
# enabled ⇒ the tick processes it, absent ⇒ the tick skips it. Operator-flippable
# via the env override without editing the file.
: "${FUNNEL_ENABLED_BOARDS:=3}"

# Cron cadence is a CONFIG variable, not hardcoded (open operator question —
# the operator finalizes it at the cron-install gate). This script does NOT
# schedule itself; it runs ONE tick and exits. The cadence is consumed by the
# (operator-installed) cron entry, surfaced here only so the default is visible.
: "${FUNNEL_TICK_CADENCE:=daily}"

# The operator handle the async decision-issue backend assigns to (the baton).
# This MUST be the operator's real GitHub collaborator LOGIN (verify with
# `gh api user -q .login` — a display/email-derived handle can differ from the
# real login, and a re-assign to the wrong one targets nobody / fails, so the
# baton never reaches the operator; foundation #588). Override per-host via the
# env var if the operator identity ever changes. SOURCE OF TRUTH is
# build.config.sh (sourced above); this `:=` is the non-vendoring-checkout
# fallback (tracker seam v0, #772) — build.config.sh's own placeholder wins
# here too since it's sourced first.
: "${FUNNEL_OPERATOR:=@REPLACE_WITH_YOUR_GH_LOGIN}"

# WIP cap for the autonomous lane. Per the pilot decision: KEEP WIP-3 (prove the
# loop safe before raising throughput). This is surfaced, not enforced here —
# the cap is INHERITED from /build's claim-first gate, not re-embedded.
: "${FUNNEL_WIP_CAP:=3}"

# Per-tick DRIVE CAP (#642): how many Operational drive-ready items this tick may
# EMIT. Was a hardcoded one-per-tick; now the canonical operator knob, fed from the
# vault `cap:` (the ```funnel-schedule block) by funnel-cron.sh and defaulted in
# build.config.sh. A bare `funnel-tick.sh` run uses the =1 fallback. This bounds the
# EMIT; real concurrency is still governed by the WIP-3 claim-first gate downstream.
: "${FUNNEL_DRIVE_CAP:=1}"

# Single-flight lockfile (contract § 4). One tick per host at a time.
: "${FUNNEL_LOCK_DIR:=/tmp/funnel-tick}"
: "${FUNNEL_LOCK_FILE:=$FUNNEL_LOCK_DIR/tick.lock}"

# Idempotency marker (foundation #587). The drain applier (tidy.md
# § Answered decisions step f) posts a confirmation comment when it applies an
# answered decision and drops the `decision` label. Search-index lag can re-list
# a just-drained issue on the NEXT tick (the label drop hasn't propagated); its
# latest comment is then this delivery artifact, NOT a decision reply. Keying off
# this sentinel lets the tick recognise an already-applied issue and skip it
# (drain-already-applied) instead of mis-parsing it as a parse-miss and spuriously
# re-assigning the operator. The `Decision applied:` prose prefix is the fallback
# for legacy confirmation comments posted before the sentinel existed.
: "${FUNNEL_DELIVERED_MARKER:=<!-- funnel:decision-applied -->}"

# Clarification-drain sentinel (foundation #657) — the SOURCE OF TRUTH is
# build.config.sh (sourced above), so the writer/reader pair never drift; this
# `:=` line is the non-vendoring-checkout fallback only, exactly as
# FUNNEL_MERGE_PENDING_LABEL does. FUNNEL_CLARIFIED_MARKER is the ack the executor
# posts on a drained item — the search index can re-list it before the label drop
# propagates, so clarification_already_applied keys off this to skip a re-drain.
: "${FUNNEL_CLARIFIED_MARKER:=<!-- funnel:clarification-drained -->}"

# Rung-5c code-escalation label (foundation #697, supersedes the #657 merge-escalation
# marker). funnel-drive.sh applies THIS label — not `needs-clarification` — to a CODE
# item it escalates to the operator (route-refused / terminally-red CI). Since those
# items no longer carry `needs-clarification`, Phase A2's answer-drain search can never
# list them (no marker scan / skip verb needed); the funnel_escalated park gate keeps
# them out of the drive pool (duplicate-PR guard). SOURCE OF TRUTH is build.config.sh.
: "${FUNNEL_ESCALATED_LABEL:=funnel-escalated}"

# Cross-tick merge hand-off marker (foundation #624). funnel-drive.sh applies this
# label to a Ready item whose headless merge drive left an OPEN, unmerged PR (the
# one-shot `claude -p` session ended before CI greened + the merge gate fired). On
# the next tick this script sees the label and emits a RESUME drive (re-attach to
# the open PR + run /build's merge gate) instead of a FRESH one — which would open a
# duplicate PR. Default centralized in build.config.sh; override via the env.
: "${FUNNEL_MERGE_PENDING_LABEL:=funnel-merge-pending}"

# Crash-signal intake orchestrator (foundation #671, epic #637). The L2
# `/signal-intake` script (crash-convergence/signal-intake.sh) — sourceable +
# execute-guarded, so invoking it here just RUNS it, mirroring how the tick
# calls the board adapter. Injectable so a test can point it at a stub instead
# of the real Sentry/board-hitting script. Default resolved once, below.
: "${FUNNEL_INTAKE_CMD:=$HERE/../crash-convergence/signal-intake.sh}"

# ── Arg parse ────────────────────────────────────────────────────────────────
DRY_RUN=0
FIXTURE=""
ONE_BOARD=""
LIST_ENABLED=0

usage() {
  echo "usage: funnel-tick.sh [--board N] [--dry-run --fixture <dir>] [--list-enabled]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --fixture)      FIXTURE="${2:?--fixture needs a dir}"; shift 2 ;;
    --board)        ONE_BOARD="${2:?--board needs a value}"; shift 2 ;;
    --list-enabled) LIST_ENABLED=1; shift ;;
    -h|--help)      usage ;;
    *) echo "funnel-tick.sh: unknown arg '$1'" >&2; usage ;;
  esac
done

if [ "$DRY_RUN" -eq 1 ] && [ -z "$FIXTURE" ]; then
  echo "funnel-tick.sh: --dry-run requires --fixture <dir>" >&2
  exit 2
fi
if [ -n "$FIXTURE" ] && [ ! -d "$FIXTURE" ]; then
  echo "funnel-tick.sh: fixture dir not found: $FIXTURE" >&2
  exit 2
fi

# ── Enabled-board set helpers (the ON/OFF flip) ──────────────────────────────
board_enabled() {
  local b="$1" e
  for e in $FUNNEL_ENABLED_BOARDS; do [ "$e" = "$b" ] && return 0; done
  return 1
}

if [ "$LIST_ENABLED" -eq 1 ]; then
  jq -cn \
    --argjson boards "$(printf '%s\n' "$FUNNEL_ENABLED_BOARDS" | jq -R 'split(" ")|map(select(length>0))')" \
    --arg cadence "$FUNNEL_TICK_CADENCE" \
    --argjson wip "$FUNNEL_WIP_CAP" \
    --argjson cap "$FUNNEL_DRIVE_CAP" \
    '{enabled_boards:$boards, cadence:$cadence, wip_cap:$wip, drive_cap:$cap}'
  exit 0
fi

# ── Single-flight lock (contract § 4 — skip in dry-run; the fixture path has no
# shared mutable state to protect, and tests must run concurrently). The live
# path acquires it; a second overlapping tick gets flock -n failure and exits 0
# (a no-op tick, not an error). ────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 0 ]; then
  if command -v flock >/dev/null 2>&1; then
    mkdir -p "$FUNNEL_LOCK_DIR"
    exec 200>"$FUNNEL_LOCK_FILE"
    if ! flock -n 200; then
      echo '{"tick":"skipped","reason":"funnel-tick already running (single-flight lock held)"}'
      exit 0
    fi
  else
    # FAIL OPEN if flock is absent (e.g. a macOS dev box; a Linux deploy host has it).
    # The contention pre-check (§ 4, per-issue assignee re-read) is the real
    # double-act guard; the lockfile is the coarse host-level single-flight on
    # top of it. Without flock we proceed and rely on the pre-check — a tick
    # must never refuse to run merely because the coarse lock primitive is
    # missing. The cron host (the always-on Linux/mini) carries flock.
    echo '{"warning":"flock not found — single-flight lock skipped; relying on the per-issue contention pre-check"}' >&2
  fi
fi

# ── Backend seam: live vs fixture reads ──────────────────────────────────────
# Every read the tick makes goes through one of these. In --dry-run they read
# fixture files; live they shell out to `gh`/the board adapter. Keeping the seam
# narrow is what makes the dry path a faithful stand-in for the live one.

# repo for a board (live: the adapter registry; here we resolve the same
# boards.conf registry directly — see workflows/scripts/board/lib/board.sh's
# board_repo() — so the dry path stays adapter-free (no gh, no board.sh
# sourcing) while still honoring an operator's boards.conf override. Discovery
# order + conf format are identical to board.sh's: machine-level conf, then
# the repo-local workflows/scripts/board/boards.conf override, then the
# built-in map below (foundation #770; byte-identical to the pre-#770 map).
_tick_conf_repo() {  # $1 = board number; rc 1 on any miss (no conf, or no key)
  local f val
  f="${BOARDS_CONF_MACHINE:-${XDG_CONFIG_HOME:-$HOME/.config}/foundation/boards.conf}"
  [ -f "$f" ] || f="${BOARDS_CONF_REPO_LOCAL:-$HERE/../board/boards.conf}"
  [ -f "$f" ] || return 1
  val="$(grep -m1 "^board\.${1}\.repo=" "$f" 2>/dev/null | cut -d= -f2-)"
  [ -n "$val" ] || return 1
  printf '%s' "$val"
}

# denylist:allow — this built-in map is this repo's OWN real values,
# byte-identical to board.sh's board_repo() built-in map for the same
# boards.conf-less-consumer backward-compat reason (#770) — see that
# function's comment in workflows/scripts/board/lib/board.sh.
tick_board_repo() {
  local v
  v="$(_tick_conf_repo "$1")" && { printf '%s\n' "$v"; return 0; }
  case "$1" in
    3) echo "Towheads/stageFind" ;;    # denylist:allow — see comment above tick_board_repo()
    4) echo "Towheads/foundation" ;;   # denylist:allow — see comment above tick_board_repo()
    5) echo "Towheads/ssmobile" ;;     # denylist:allow — see comment above tick_board_repo()
    6) echo "Towheads/subsetwiki" ;;   # denylist:allow — see comment above tick_board_repo()
    *) return 1 ;;
  esac
}

# List answered decision issues (unassigned + label:decision + open).
# Live: `gh issue list`. Fixture: $FIXTURE/board-<N>/decisions.json (the same
# JSON shape `gh issue list --json number,title,body,comments,assignees` returns).
#
# Scoping is enforced via a SEARCH qualifier, not the `--assignee ""` flag
# (foundation #587): `--assignee ""` is a NO-OP — it does not restrict to
# unassigned, so the old query over-pulled every decision issue (incl. ones the
# operator still holds) and leaned entirely on the per-issue contention pre-check
# to skip them. `--search '… no:assignee'` actually filters to unassigned, so the
# list is genuinely "answered (operator unassigned)" — which is what also makes
# the contention pre-check's "assignee changed since list" reason accurate.
read_answered_decisions() {
  local board="$1" repo="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    local f="$FIXTURE/board-$board/decisions.json"
    [ -f "$f" ] && cat "$f" || echo '[]'
  else
    gh issue list -R "$repo" --search 'label:decision state:open no:assignee' \
      --json number,title,body,comments,assignees 2>/dev/null || echo '[]'
  fi
}

# Idempotency guard (foundation #587): is this decision issue ALREADY drained?
# True when its most-recent comment is the applier's delivery artifact — matched
# by the machine sentinel (preferred) or the legacy `Decision applied:` prose
# prefix (fallback). A just-drained issue can be re-listed once before the label
# drop propagates through the search index; recognising it here turns that into a
# clean drain-already-applied skip instead of a spurious parse-miss + re-assign.
decision_already_applied() {
  local body="$1"
  [ -z "$body" ] && return 1
  case "$body" in
    *"$FUNNEL_DELIVERED_MARKER"*) return 0 ;;
  esac
  printf '%s\n' "$body" | grep -qiE '^[[:space:]]*Decision applied:'
}

# Phase-A2 reader (foundation #657): the ANSWERED `needs-clarification` items —
# the clarification counterpart to read_answered_decisions. Same baton as the
# decision queue: since #684 a `needs-clarification` item is ASSIGNED to the
# operator at source, so `no:assignee` means the operator has answered (in a
# comment) AND unassigned themselves to hand it back. Scoping the search to
# `no:assignee` is what makes "on this list ⇒ answered" true; a still-assigned
# item is awaiting the answer and is PARKED by the Ready-loop gate instead.
read_answered_clarifications() {
  local board="$1" repo="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    local f="$FIXTURE/board-$board/clarifications.json"
    [ -f "$f" ] && cat "$f" || echo '[]'
  else
    gh issue list -R "$repo" --search 'label:needs-clarification state:open no:assignee' \
      --json number,title,body,comments,assignees 2>/dev/null || echo '[]'
  fi
}

# Idempotency guard (foundation #657): is this clarification item ALREADY drained?
# True when its most-recent comment carries the executor's clarification sentinel.
# Same lag window as decision_already_applied: a just-drained item can be re-listed
# once before the `needs-clarification` label drop propagates through the search
# index; recognising it here turns that into a clean
# drain-clarification-already-applied skip instead of a redundant re-drain.
clarification_already_applied() {
  local body="$1"
  [ -z "$body" ] && return 1
  case "$body" in
    *"$FUNNEL_CLARIFIED_MARKER"*) return 0 ;;
  esac
  return 1
}

# Re-read one issue's current assignee COUNT (the contention pre-check, § 4).
# Fixture: $FIXTURE/board-<N>/assignees-<issue>.txt holds a single integer.
read_assignee_count() {
  local board="$1" repo="$2" issue="$3"
  if [ "$DRY_RUN" -eq 1 ]; then
    local f="$FIXTURE/board-$board/assignees-$issue.txt"
    [ -f "$f" ] && tr -dc '0-9' < "$f" || echo 0
  else
    gh issue view "$issue" -R "$repo" --json assignees --jq '.assignees | length' 2>/dev/null || echo 0
  fi
}

# Project the Ready items {number,title,labels} out of a board items-JSON blob.
# ROBUST to a malformed trailing token (#584): emits EXACTLY ONE JSON array.
# board_resolve's BOARD_ITEMS_JSON was observed on the LIVE board to carry a
# trailing token (jq: "Unmatched '}'") that makes jq exit non-zero AFTER it has
# already streamed the correct array. The previous `jq ... || echo '[]'` then
# APPENDED a stray '[]', so `$ready` held two JSON values, `jq length` returned
# the two-line string "1\n0", and the `[ $j -lt $n_ready ]` integer test in the
# drive/route loop aborted with "integer expression expected" — the tick
# silently no-op'd past ALL Ready work (drove/routed nothing on the live board).
# Fix: capture jq's stdout, IGNORE its exit (the emitted array is correct), then
# collapse to the first array value — never append a fallback after partial
# output. `.items[]?` also tolerates a missing / non-array `.items`.
#
# Resume inclusion (foundation #624): a handed-off merge drive is still CLAIMED —
# `claim.sh` flipped its card to **In Progress** before /build ran, and the card
# never left In Progress when the one-shot session died after opening the PR (board
# → Done fires only on merge). A Ready-only scan would therefore never see it, and
# the funnel-merge-pending marker would be written but never read. So this also
# enumerates **In-Progress items carrying FUNNEL_MERGE_PENDING_LABEL** — the only
# In-Progress cards the funnel re-touches — so the resume gate downstream can fire.
# (A normal In-Progress card, unlabeled, is another session's active work and stays
# invisible here.) Resume items are sorted FIRST so an in-flight PR finishes before
# a fresh drive is started, within the one-drive-per-tick slot (finish-before-start).
ready_items_from_json() {
  local json="$1" out
  out="$(jq -c --arg lbl "$FUNNEL_MERGE_PENDING_LABEL" '[.items[]?
                 | select(.status == "Ready"
                          or (.status == "In Progress"
                              and ((.labels // []) | index($lbl)) != null))
                 | {number:(.content.number // .number), title:(.title // ""),
                    labels:[(.labels // [])[]]}]
                 | sort_by(if ((.labels // []) | index($lbl)) then 0 else 1 end)' <<<"$json" 2>/dev/null)" || true
  out="$(printf '%s' "$out" | jq -c -s '(map(select(type == "array")) | .[0]) // []' 2>/dev/null)" || out='[]'
  printf '%s\n' "$out"
}

# List Ready items with their work-class label.
# Live: the board adapter (board_resolve → BOARD_ITEMS_JSON → ready_items_from_json).
# Fixture (--dry-run): prefer a RAW board-items blob ($FIXTURE/board-<N>/items.json)
# so the dry path exercises the SAME normalizer as live (offline regression
# coverage for #584); else fall back to the pre-projected
# $FIXTURE/board-<N>/ready.json — array of {number,title,labels:[...]}.
read_ready_items() {
  local board="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    local raw="$FIXTURE/board-$board/items.json"
    if [ -f "$raw" ]; then
      ready_items_from_json "$(cat "$raw")"; return
    fi
    local f="$FIXTURE/board-$board/ready.json"
    [ -f "$f" ] && cat "$f" || echo '[]'
  else
    # Live path: resolve the board, then project via the shared normalizer.
    # Delegated to the adapter — NOT re-implemented here. The adapter call is
    # the live seam; tests exercise the same normalizer via the items.json fixture.
    local lib="$HERE/../board/lib/board.sh"
    if [ -f "$lib" ]; then
      # shellcheck source=/dev/null
      . "$lib"
      board_resolve "$board" >/dev/null 2>&1 || { echo '[]'; return; }
      ready_items_from_json "${BOARD_ITEMS_JSON:-{\"items\":[]}}"
    else
      echo '[]'
    fi
  fi
}

# ── Typed-reply parser (contract § 3) ────────────────────────────────────────
# Reads the MOST RECENT comment body and returns the chosen option, or "" on a
# parse miss. Accepts: a fenced ```decision``` block with `chosen: <x>`, or the
# `/choose <x>` / `/approve` shorthands (start-of-line). Closed-enum-or-escalate:
# a miss returns empty → the caller routes to drain-parse-miss (re-assign op),
# NEVER a silent default.
parse_reply() {
  local body="$1" chosen=""
  # /approve shorthand (start of a line)
  if printf '%s\n' "$body" | grep -qiE '^/approve([[:space:]]|$)'; then
    echo "approve"; return 0
  fi
  # /choose <label> shorthand (start of a line) — take the rest of the line
  local choose_line
  choose_line="$(printf '%s\n' "$body" | grep -iE '^/choose[[:space:]]+' | head -1 || true)"
  if [ -n "$choose_line" ]; then
    chosen="$(printf '%s' "$choose_line" | sed -E 's@^/choose[[:space:]]+@@' | tr -d '\r' | awk '{$1=$1;print}')"
    [ -n "$chosen" ] && { echo "$chosen"; return 0; }
  fi
  # Fenced ```decision``` block with `chosen: <x>`
  chosen="$(printf '%s\n' "$body" \
    | awk '/^```decision/{f=1;next} /^```/{f=0} f' \
    | grep -iE '^[[:space:]]*chosen:' | head -1 \
    | sed -E 's@^[[:space:]]*chosen:[[:space:]]*@@' | tr -d '\r' | awk '{$1=$1;print}')"
  if [ -n "$chosen" ]; then echo "$chosen"; return 0; fi
  echo ""   # parse miss
  return 0
}

# Most-recent comment body from a decision-issue JSON object.
latest_comment_body() {
  jq -r '(.comments // []) | if length>0 then (sort_by(.createdAt)|last|.body) else "" end' 2>/dev/null
}

# ── Work-class classifier ────────────────────────────────────────────────────
# Reads an item's labels → "Operational" | "Foundational". Default-Operational
# (work-class-policy.md): an item with NEITHER label defaults to Operational.
classify_item() {
  local labels_json="$1"
  if jq -e 'any(.[]; . == "Foundational")' <<<"$labels_json" >/dev/null 2>&1; then
    echo "Foundational"
  else
    echo "Operational"   # default-Operational covers the explicit Operational label too
  fi
}

# ── Operator-clarification gate (foundation #594, corrected #600) ─────────────
# A Ready item carrying `needs-clarification` is blocked on an OPERATOR ANSWER
# (an open question parks it in Ready, #435 — answered downstream by `/sweep`
# Phase 1 / `/assess`, which clears the label). It is NOT auto-driven; the drive
# loop ROUTES it to the operator (assign + surface the question) instead. #594
# originally lumped `spike` into this gate too and skipped both — that was wrong
# (#600): a `spike` is automatable read-only investigation whose verdict feeds a
# decision AFTER it runs, so it is a DRIVE target, not an operator-input gate, and
# is no longer matched here (it falls through to classify_item → Operational →
# drive-ready). classify_item alone can't catch needs-clarification — it checks
# only `Foundational`, so the label would otherwise default to Operational and be
# driven. Returns rc 0 (prints the label) on a hit, rc 1 on a miss; rc is the gate.
needs_clarification() {
  local labels_json="$1"
  jq -e 'any(.[]; . == "needs-clarification")' <<<"$labels_json" >/dev/null 2>&1 || return 1
  printf 'needs-clarification\n'
}

# ── Rung-5c code-escalation gate (foundation #697) ────────────────────────────
# A Ready item carrying `funnel-escalated` is a CODE item the merge tier could not
# land (route-refused / terminally-red CI); funnel-drive.sh assigned the operator +
# applied this OWN label (not `needs-clarification` — #697's split). It has an open or
# failed PR and awaits a MANUAL merge/close, so it must NEVER be auto-driven: a fresh
# drive would open a DUPLICATE PR. This gate is the duplicate-PR guard the shared
# `needs-clarification` label was silently providing before the split — it keeps the
# item OUT of the drive pool (the Ready loop PARKS it as route-already-assigned). Same
# rc contract as needs_clarification: rc 0 (prints the label) on a hit, rc 1 on a miss.
funnel_escalated() {
  local labels_json="$1"
  jq -e --arg l "$FUNNEL_ESCALATED_LABEL" 'any(.[]; . == $l)' <<<"$labels_json" >/dev/null 2>&1 || return 1
  printf '%s\n' "$FUNNEL_ESCALATED_LABEL"
}

# ── Cross-tick merge hand-off gate (foundation #624) ──────────────────────────
# True when a Ready item carries FUNNEL_MERGE_PENDING_LABEL — its prior headless
# merge drive opened a PR but the one-shot session ended before the merge gate
# fired (funnel-drive.sh applied the marker off a ground-truth open-PR probe). Such
# an item must be RESUMED (re-attach to the open PR + run /build's merge gate), not
# re-driven from scratch (a fresh drive opens a duplicate PR). Returns rc 0 on a hit,
# rc 1 on a miss; rc is the gate. Checked AFTER needs_clarification (an open operator
# question outranks a resume) and only matters for an Operational drive-ready item.
pending_merge() {
  local labels_json="$1"
  jq -e --arg l "$FUNNEL_MERGE_PENDING_LABEL" 'any(.[]; . == $l)' <<<"$labels_json" >/dev/null 2>&1
}

# Ground-truth open-PR probe (foundation #641) — the belt-and-suspenders behind
# pending_merge. The hand-off MARKER is trustworthy ONLY when funnel-drive.sh's
# `gh issue edit --add-label` actually succeeded; if that gh call FAILED (auth /
# rate-limit / repo mismatch) the label is silently absent, pending_merge returns
# false, and a kind:code item would be re-driven FRESH → a DUPLICATE PR. So before
# emitting a fresh code drive we ask GitHub directly: is there an OPEN PR whose body
# closes this issue? Echoes the PR number if so (→ recover to resume), nothing
# otherwise (→ genuinely fresh). Mirrors funnel-drive.sh's `_open_pr_for_issue`
# (canonical there) but adapted to funnel-tick's DRY_RUN/fixture harness. Same-repo
# bare `Closes #N` form (the funnel drives same-repo). Fail-open: any gh/jq error →
# nothing → fresh drive (never wedges the tick; the marker path already handled the
# common resume, this only covers the lost-label edge).
open_pr_for_issue() {  # $1=board  $2=repo  $3=issue
  local board="$1" repo="$2" issue="$3" json
  if [ "$DRY_RUN" -eq 1 ]; then
    local f="$FIXTURE/board-$board/open-pr-$issue.txt"
    if [ -f "$f" ]; then tr -dc '0-9' < "$f"; fi
    return 0
  fi
  json="$(gh pr list -R "$repo" --state open --json number,body --limit 100 2>/dev/null)" || return 0
  [ -z "$json" ] && return 0
  jq -r --arg n "$issue" '
    [ .[]? | select((.body // "")
        | test("(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#" + $n + "\\b"))
      | .number ] | (.[0] // empty)' <<<"$json" 2>/dev/null || return 0
}

# ── Bare-singleton gate for a fresh kind:code drive (foundation #717) ──────────
# #635 split the fresh emit by kind: a kind:spike drive-ready routes to the singleton
# verdict path, a kind:code keeps the epic /triage→/assess --epic→/build sequence. But
# a kind:code Ready item can ALSO be a bare singleton (0 sub-issues AND no `## Contract`
# body) — and /assess --epic REFUSES it ("no sub-issues and no Contract → run /triage"),
# so /build gets no plan note and the scarce 5c merge cap burns on a guaranteed no-op
# every tick (the 2026-07-01 F499/F533/F534/F538/F659 dead-end). This is the kind:code
# sibling of #635. Detect the bare singleton so the emit can route it through /sweep's
# per-issue build path (scoped to the one issue) instead of /assess --epic.
#
# Signal — one REST read (mirrors board_parent_issue's `repos/…/issues/N` endpoint,
# which reads `.parent_issue_url` off the same object): a bare singleton iff
# `.sub_issues_summary.total == 0` (no children → not an epic parent) AND the body
# carries no `## Contract` heading (no pre-designed undecomposed Contract for /assess
# to decompose — the #526 seam). Cap-bounded: fires only for a fresh kind:code
# candidate, so at most FUNNEL_DRIVE_CAP times per tick (like open_pr_for_issue).
#
# FAIL-OPEN to the EPIC route (rc 1) on ANY gh/jq error, empty data, or missing
# fixture — a genuine epic mis-routed to the singleton path would be silently skipped
# by /sweep (worse than the status quo), so ambiguity KEEPS the current epic behavior.
# Dry-run purity: reads a `board-$board/singleton-$issue.json` fixture (the raw issue
# object); no fixture → rc 1 (epic route), so every pre-#717 test that omits the
# fixture keeps its epic-path expectation unchanged.
#
# Returns rc 0 (IS a bare singleton → /sweep per-issue route) / rc 1 (epic or unknown).
bare_ready_singleton() {  # $1=board  $2=repo  $3=issue
  local board="$1" repo="$2" issue="$3" json total body
  if [ "$DRY_RUN" -eq 1 ]; then
    local f="$FIXTURE/board-$board/singleton-$issue.json"
    [ -f "$f" ] || return 1
    json="$(cat "$f")"
  else
    json="$(gh api "repos/$repo/issues/$issue" 2>/dev/null)" || return 1
  fi
  [ -n "$json" ] || return 1
  total="$(jq -r '.sub_issues_summary.total // 0' <<<"$json" 2>/dev/null)" || return 1
  # Any sub-issue → a genuine epic parent → keep the epic route.
  case "$total" in ''|*[!0-9]*) return 1 ;; esac
  [ "$total" -eq 0 ] || return 1
  # A `## Contract` body → a pre-designed undecomposed epic /assess decomposes → epic route.
  body="$(jq -r '.body // ""' <<<"$json" 2>/dev/null)" || return 1
  printf '%s\n' "$body" | grep -qiE '^[[:space:]]*##[[:space:]]+Contract\b' && return 1
  return 0
}

# ── Phase 0 — crash-signal intake (foundation #671, epic #637) ───────────────
# Runs /signal-intake (the L2 crash-convergence orchestrator) ONCE per board,
# BEFORE any of the tick's spend decisions — Phase A's drain loop and Phase
# B/C's FUNNEL_DRIVE_CAP-gated drive/route loop below (the closest thing this
# scheduler has to a "spend gate": the counter that decides how much of this
# tick's Ready work gets driven). Placing intake ahead of that gate is what
# makes intake run on EVERY tick, including a tick that ends up driving/
# routing nothing (a "spend-closed" tick) — not just ticks with drivable work.
#
# BEST-EFFORT AND NON-BLOCKING (the hard requirement): the funnel's core job
# is driving the board, and that must never fail because crash intake had a
# problem — a missing SENTRY_AUTH_TOKEN, a Sentry API error, a board-adapter
# hiccup. A non-zero exit from the orchestrator is caught, logged to stderr,
# and swallowed; `set -e` never sees it (the `||` below absorbs the exit code
# before it can propagate), so the tick always continues to Phase A.
#
# Dry-run purity (mirrors funnel-drive.sh's --dry-run guarantee, foundation
# #604/#615): a --dry-run tick must stay side-effect-free — no network, no
# `gh`. So when DRY_RUN=1 AND FUNNEL_INTAKE_CMD is still its default (the real
# script), skip the call outright rather than actually invoking Sentry/board
# calls. A test that wants to exercise the failure-handling path sets
# FUNNEL_INTAKE_CMD to a stub — an explicit override runs even under --dry-run,
# since a stub has no side effects of its own.
run_intake_phase() {
  local board="$1"
  if [ "$DRY_RUN" -eq 1 ] && [ "$FUNNEL_INTAKE_CMD" = "$HERE/../crash-convergence/signal-intake.sh" ]; then
    return 0
  fi
  local err rc=0
  err="$("$FUNNEL_INTAKE_CMD" run --board "$board" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'funnel-tick: signal-intake failed for board %s (non-blocking, rc=%s): %s\n' \
      "$board" "$rc" "$err" >&2
  fi
  return 0
}

# ── The tick ─────────────────────────────────────────────────────────────────
ACTIONS='[]'   # accumulated tick-plan action records
add_action() { ACTIONS="$(jq -c --argjson a "$1" '. + [$a]' <<<"$ACTIONS")"; }

tick_board() {
  local board="$1" repo
  repo="$(tick_board_repo "$board")" || { echo "funnel-tick.sh: unknown board $board" >&2; return 1; }

  # Phase 0 — crash-signal intake, BEFORE Phase A/B/C's spend decisions (see
  # run_intake_phase's header comment). Runs every tick regardless of what (if
  # anything) this tick ends up draining/driving/routing.
  run_intake_phase "$board"

  # ── Phase A — drain answered decisions FIRST (contract + build.md 0a) ──────
  local decisions reply chosen issue
  decisions="$(read_answered_decisions "$board" "$repo")"
  local n_dec; n_dec="$(jq 'length' <<<"$decisions")"
  local i=0
  while [ "$i" -lt "$n_dec" ]; do
    local d; d="$(jq -c ".[$i]" <<<"$decisions")"
    issue="$(jq -r '.number' <<<"$d")"
    reply="$(latest_comment_body <<<"$d")"

    # Idempotency guard (§ #587): a just-drained issue can be re-listed once
    # before the label drop propagates through the search index. If its latest
    # comment is the applier's delivery artifact, it is already applied — skip it
    # cleanly (NOT a parse-miss; do not re-assign the operator). Cheap (no API
    # call), so it runs before the contention pre-check's fresh assignee read.
    if decision_already_applied "$reply"; then
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$issue" \
        '{phase:"drain",board:$b,repo:$r,issue:$n,action:"drain-already-applied",
          detail:"latest comment is the delivery artifact (decision already applied; label drop not yet propagated) — idempotent skip"}')"
      i=$((i+1)); continue
    fi

    # Contention pre-check (§ 4): re-read current assignees; non-zero = raced.
    # With the unassigned-scoped drain list (#587), a non-zero count here is a
    # GENUINE mid-tick re-assign (the operator or another tick grabbed the baton
    # after the list read) — not an always-assigned issue the old over-pull mixed
    # in — so the "assignee changed since drain-list" reason is now accurate.
    local cur; cur="$(read_assignee_count "$board" "$repo" "$issue")"
    if [ "${cur:-0}" -gt 0 ]; then
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$issue" \
        '{phase:"drain",board:$b,repo:$r,issue:$n,action:"skip-contention",
          detail:"assignee changed since drain-list — skip this tick"}')"
      i=$((i+1)); continue
    fi

    chosen="$(parse_reply "$reply")"
    if [ -z "$chosen" ]; then
      # Parse miss → re-assign operator with a couldn't-parse note (no guess).
      # reassign_to is emitted as a BARE login (strip the leading `@`) — it feeds an
      # `--add-assignee` call (funnel-drive.md) and GitHub's replaceActorsForAssignable
      # cannot resolve an `@`-prefixed login (foundation #977; mirrors funnel-drive.sh's
      # `${FUNNEL_OPERATOR#@}` strip at 555/633). The `@` stays in FUNNEL_OPERATOR for
      # mention text; only the assignee target is bared. The literal `@me` token is
      # PRESERVED — gh special-cases it to the authenticated user, so stripping it to
      # `me` (a non-user) would re-break the very assign this fixes.
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$issue" --arg op "$FUNNEL_OPERATOR" \
        '{phase:"drain",board:$b,repo:$r,issue:$n,action:"drain-parse-miss",
          reassign_to:(if $op == "@me" then $op else ($op | ltrimstr("@")) end),
          detail:"could not parse reply as a decision block or /command — re-assigned operator (closed-enum-or-escalate)"}')"
    else
      # Parsed → EMIT the drain-apply (build.md 0a / tidy owns the apply:
      # translate reply → artifact, drop the decision label, hand baton back).
      # The scheduler ROUTES; it does not perform the sentinel/worktree work.
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$issue" --arg c "$chosen" \
        '{phase:"drain",board:$b,repo:$r,issue:$n,action:"drain-answer",chosen:$c,
          emit:("apply answered decision #"+($n|tostring)+" (chosen="+$c+") → drop `decision` label, hand baton back; resume via build.md Step 0a / tidy § Answered decisions"),
          detail:"parsed typed reply; routed to the existing drain (no re-implementation)"}')"
    fi
    i=$((i+1))
  done

  # ── Phase A2 — drain ANSWERED needs-clarification items (foundation #657) ───
  # The clarification counterpart to the decision drain above, on the SAME baton:
  # since #684 a `needs-clarification` item is assigned to the operator at source,
  # so an UNASSIGNED one (this list) is answered + handed back. Clearing the label
  # is all that is needed to make it drivable again — the free-text answer already
  # lives on the issue, read downstream by /assess//build (no reply to parse). The
  # apply (remove label + post the sentinel ack) is a no-PR/no-merge safe mutation
  # the 5b executor performs; this script only ROUTES. Numbers drained here are
  # recorded in `drained_clar` so the Ready-loop park gate below does not ALSO park
  # the same item (it is unassigned, so it appears in both this list and Ready).
  local drained_clar=" "
  local clarifs; clarifs="$(read_answered_clarifications "$board" "$repo")"
  local n_clar; n_clar="$(jq 'length' <<<"$clarifs")"
  local k=0
  while [ "$k" -lt "$n_clar" ]; do
    local c cnum creply
    c="$(jq -c ".[$k]" <<<"$clarifs")"
    cnum="$(jq -r '.number' <<<"$c")"
    creply="$(latest_comment_body <<<"$c")"

    # (#697 retired the merge-escalation guard that lived here: rung-5c CODE
    # escalations now carry their OWN `funnel-escalated` label — never
    # `needs-clarification` — so read_answered_clarifications' search can no longer
    # list one. The exclusion is now the absence of the label at SEARCH time, not a
    # per-item comment-history scan. The funnel_escalated park gate in the Ready loop
    # keeps such an item out of the drive pool.)

    # Idempotency: latest comment is the executor's clarified-marker ack → the
    # label drop just hasn't propagated. Skip (do NOT re-drain).
    if clarification_already_applied "$creply"; then
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$cnum" \
        '{phase:"drain",board:$b,repo:$r,issue:$n,action:"drain-clarification-already-applied",
          detail:"latest comment is the clarified-marker ack (label drop not yet propagated) — idempotent skip"}')"
      drained_clar="$drained_clar$cnum "
      k=$((k+1)); continue
    fi

    # Contention pre-check: a fresh re-assign since the drain-list read means the
    # operator (or another tick) re-grabbed the baton — skip this tick.
    local ccur; ccur="$(read_assignee_count "$board" "$repo" "$cnum")"
    if [ "${ccur:-0}" -gt 0 ]; then
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$cnum" \
        '{phase:"drain",board:$b,repo:$r,issue:$n,action:"skip-contention",
          detail:"assignee changed since clarification drain-list — skip this tick"}')"
      # Now re-assigned, so it is in the Ready pool AND awaiting — record it so the
      # park gate does not ALSO emit route-already-assigned this tick (it parks next
      # tick once stable). skip-contention is this tick's single visible record.
      drained_clar="$drained_clar$cnum "
      k=$((k+1)); continue
    fi

    # EMIT the clarification drain: clear the label + post the sentinel ack. No
    # parse — the answer is free-text context read downstream when the item drives.
    add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$cnum" --arg t "$(jq -r '.title // ""' <<<"$c")" \
      '{phase:"drain",board:$b,repo:$r,issue:$n,title:$t,action:"drain-clarification",
        emit:("clear `needs-clarification` on #"+($n|tostring)+" + post the clarified-marker ack; the answer already on the issue rides into the next drive"),
        detail:"operator answered + unassigned (baton returned) — clearing the open-question gate (foundation #657)"}')"
    drained_clar="$drained_clar$cnum "
    k=$((k+1))
  done

  # ── Phases B & C — drive Ready work by work-class ─────────────────────────
  local ready; ready="$(read_ready_items "$board")"
  local n_ready; n_ready="$(jq 'length' <<<"$ready")"

  # Up to FUNNEL_DRIVE_CAP Operational drives + one Foundational route per tick
  # (#642). did_op is now a COUNTER, not a boolean: it gates how many Operational
  # drive-ready items this tick emits (vault `cap:` feeds the cap). The WIP-3 cap
  # still governs real concurrency once items are claimed (INHERITED from /build,
  # not enforced here). Foundational items are ROUTED, not driven, so did_found
  # stays one-per-tick — the drive cap does not apply to routing.
  local did_op=0 did_found=0 did_route=0 j=0
  while [ "$j" -lt "$n_ready" ]; do
    local it num title labels cls
    it="$(jq -c ".[$j]" <<<"$ready")"
    num="$(jq -r '.number' <<<"$it")"
    title="$(jq -r '.title // ""' <<<"$it")"
    labels="$(jq -c '.labels // []' <<<"$it")"

    # Operator-clarification gate (#594, corrected #600, simplified #684): a Ready
    # item carrying `needs-clarification` is blocked on the operator's answer —
    # never auto-drive it. PARK it (`route-already-assigned`) unconditionally, gated
    # BEFORE classifying (classify_item would default it Operational and drive it).
    # The producer that raised the question (`/triage`, `/sweep` park-on-question)
    # already assigned the operator AT SOURCE, so the item is already in the
    # operator's assigned-to-me queue and the funnel has nothing to assign — no
    # assignee re-read, no `route-needs-input` (that step existed only to do the
    # assign the producers now own — #684). `spike` is NOT matched here (it drives —
    # #600). The loop continues, so a clean Operational item after a parked one is
    # still driven this tick.
    #
    # EXCEPTION (#657): if Phase A2 already drained this item this tick (operator
    # answered + unassigned), it is in `drained_clar`. Such an item is unassigned,
    # so it appears in BOTH the drain-list and the Ready pool — parking it here too
    # would emit a contradictory route-already-assigned alongside the drain. Skip
    # it: the drain is authoritative (the label is being cleared, not parked).
    if needs_clarification "$labels" >/dev/null; then
      case "$drained_clar" in
        *" $num "*) j=$((j+1)); continue ;;
      esac
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" \
        '{phase:"route",board:$b,repo:$r,issue:$n,title:$t,action:"route-already-assigned",label:"needs-clarification",
          detail:"Ready item carries `needs-clarification` — parked awaiting the operator answer; assignment + question owned at source by /triage//sweep, so the funnel does not re-assign (re-enters drive once /sweep Phase 1 / /assess clears the label) (foundation #684)"}')"
      did_route=1
      j=$((j+1)); continue
    fi

    # Rung-5c code-escalation gate (#697): a Ready item carrying `funnel-escalated`
    # is a code item the merge tier could not land (route-refused / terminally-red
    # CI) — funnel-drive.sh assigned the operator + applied this OWN label. It has an
    # open/failed PR and awaits a MANUAL merge/close; auto-driving it fresh would open
    # a DUPLICATE PR. PARK it (`route-already-assigned`), gated BEFORE classify_item
    # exactly like needs_clarification — this is the duplicate-PR guard the shared
    # label used to provide before #697's split. The operator resolves it by merging/
    # closing the PR (which clears the label), not by answering a question — so unlike
    # needs-clarification it is NOT drained by Phase A2 (nothing lists it there).
    if funnel_escalated "$labels" >/dev/null; then
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" --arg l "$FUNNEL_ESCALATED_LABEL" \
        '{phase:"route",board:$b,repo:$r,issue:$n,title:$t,action:"route-already-assigned",label:$l,
          detail:"Ready item carries `funnel-escalated` — a rung-5c code item the merge tier could not land (has an open/failed PR); parked awaiting the operator manual merge/close, assigned at source by the 5c escalation, so the funnel does not re-drive (would duplicate the PR) (foundation #697)"}')"
      did_route=1
      j=$((j+1)); continue
    fi

    # Decision-queue re-route guard (foundation #834/#1002/#1009, epic #970): a Ready
    # item already routed to the async decision queue carries the `decision` label AND
    # an operator assignee (the baton a prior route-foundational set). Re-emitting
    # route-foundational re-runs /assess and mints a DUPLICATE plan note + gate comment
    # every tick (8+ near-duplicates on stageFind#770 across 2026-07-01/02). PARK it
    # (`route-already-assigned`), gated BEFORE classify_item exactly like the
    # needs-clarification / funnel-escalated gates above. The `decision` label ALONE is
    # not enough: an UNASSIGNED `decision` item is an ANSWERED one Phase A drains
    # (read_answered_decisions is `no:assignee`), so require assignees>0 — an assigned
    # `decision` item is still parked awaiting the operator's reply and must not re-route.
    # The assignee read is cap-bounded (only `decision`-labeled Ready items reach it) and
    # dry-run-safe (read_assignee_count reads the `assignees-<n>.txt` fixture). Mirrors
    # drain-clarification's idempotency sentinel (#657) for the route-foundational path.
    if jq -e 'any(.[]; . == "decision")' <<<"$labels" >/dev/null 2>&1; then
      local dcur; dcur="$(read_assignee_count "$board" "$repo" "$num")"
      if [ "${dcur:-0}" -gt 0 ]; then
        add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" \
          '{phase:"route",board:$b,repo:$r,issue:$n,title:$t,action:"route-already-assigned",label:"decision",
            detail:"Ready item carries `decision` + an operator assignee — already routed to the async decision queue by a prior route-foundational; parked awaiting the operator reply. Re-routing would re-run /assess and mint a duplicate plan note + gate comment (foundation #834/#1002/#1009, epic #970). Phase A drains it once the operator answers + unassigns (which drops the label)."}')"
        did_route=1
        j=$((j+1)); continue
      fi
    fi

    cls="$(classify_item "$labels")"

    if [ "$cls" = "Operational" ] && [ "$did_op" -lt "$FUNNEL_DRIVE_CAP" ]; then
      # Phase B — EMIT the pipeline invocation. The driver CALLS /assess→/build;
      # it never assesses or builds. --unattended selects the async backend +
      # auto-merge-on-green (Operational does NOT ride the timed objection gate).
      #
      # Stamp the work `kind` (foundation #604): a `spike`-labeled item is
      # automatable read-only investigation whose drive opens NO PR (build.md's
      # kind:spike path writes a verdict note + routes a follow-up — #600); a
      # plain Operational item is `code` (its drive ends in a PR + merge). The
      # 5b headless driver (funnel-drive.sh) filters on this: it auto-executes
      # only `kind:spike` drives (no-merge), leaving `kind:code` drives emit-only
      # for the operator to run manually (the merging tier waits for rung 5c). The
      # scheduler classifies; the driver stays dumb.
      local kind="code"
      if jq -e 'any(.[]; . == "spike")' <<<"$labels" >/dev/null 2>&1; then kind="spike"; fi
      # Resume vs fresh (foundation #624): a kind:code item carrying the merge
      # hand-off marker already has an OPEN PR from a prior tick's drive — RESUME
      # the merge (re-attach + run /build's gate) rather than re-drive (a fresh
      # drive opens a duplicate PR). The marker is set only by funnel-drive.sh off a
      # ground-truth open-PR probe, so it is trustworthy. A spike never opens a PR,
      # so it is never pending; resume applies to the merge tier only.
      # Recover a LOST hand-off marker from ground truth (#641): a kind:code item
      # WITHOUT the pending-merge label but WITH an open PR that closes it means the
      # prior tick's `--add-label` gh call failed — the item is really mid-merge, not
      # fresh. Probe only when the label is absent (the marker path already caught the
      # common resume) and only for kind:code (a spike never opens a PR), so the extra
      # `gh pr list` fires at most once per fresh-code candidate (cap-bounded).
      local recovered_pr=""
      if [ "$kind" = "code" ] && ! pending_merge "$labels"; then
        recovered_pr="$(open_pr_for_issue "$board" "$repo" "$num")"
      fi
      if [ "$kind" = "code" ] && pending_merge "$labels"; then
        add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" --arg k "$kind" --arg l "$FUNNEL_MERGE_PENDING_LABEL" \
          '{phase:"drive",board:$b,repo:$r,issue:$n,title:$t,action:"drive-ready",class:"Operational",kind:$k,mode:"resume",label:$l,
            emit:("RESUME the in-flight merge for #"+($n|tostring)+": re-attach to its OPEN PR and run /build --unattended on the existing plan note (re-check the now-green CI + run /build'"'"'s merge gate). Do NOT re-assess or open a new PR. If no open PR is found, fall back to a fresh drive."),
            detail:"carries the merge hand-off marker — a prior tick opened a PR but the one-shot session ended before the merge gate; resume it via /build (foundation #624)"}')"
      elif [ -n "$recovered_pr" ]; then
        add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" --arg k "$kind" --argjson pr "$recovered_pr" \
          '{phase:"drive",board:$b,repo:$r,issue:$n,title:$t,action:"drive-ready",class:"Operational",kind:$k,mode:"resume",recovered_pr:$pr,
            emit:("RESUME the in-flight merge for #"+($n|tostring)+": an OPEN PR (#"+($pr|tostring)+") already closes it. Re-attach to that PR and run /build --unattended on the existing plan note (re-check CI + run /build'"'"'s merge gate). Do NOT re-assess or open a new PR."),
            detail:("NO hand-off marker but a ground-truth open-PR probe found #"+($pr|tostring)+" closing this issue — the prior tick'"'"'s hand-off label add failed (funnel-drive.sh #641); resuming (not re-driving) prevents a duplicate PR")}')"
      else
        # Split the fresh emit by ROUTE (#635 + #717). Three shapes:
        #  - spike          → singleton verdict path (opens NO PR); the 5b safe tier
        #                     drives it. A standalone spike is a Ready SINGLETON, not an
        #                     epic, so /assess --epic refuses it. [#635]
        #  - singleton-code → a bare Ready singleton (0 sub-issues AND no `## Contract`):
        #                     /assess --epic ALSO refuses it ("no sub-issues and no
        #                     Contract → run /triage"), so drive it via /sweep's per-issue
        #                     build path SCOPED to this one issue (worktree → worker → PR →
        #                     CI → /build's merge gate — the same per-issue mechanics /sweep
        #                     Phase 2 runs). NEVER /assess --epic; NEVER whole-pool /sweep.
        #                     [#717 — the kind:code sibling of #635]
        #  - epic           → a genuine epic (has sub-issues, or a `## Contract` body for
        #                     /assess to decompose): the /triage→/assess --epic→/build
        #                     sequence. [unchanged]
        # bare_ready_singleton fails OPEN to the epic route on any probe error, so an
        # ambiguous item keeps the current behavior (never mis-routes an epic to /sweep).
        local route="epic"
        if [ "$kind" = "spike" ]; then
          route="spike"
        elif bare_ready_singleton "$board" "$repo" "$num"; then
          route="singleton-code"
        fi
        add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" --arg k "$kind" --arg route "$route" \
          '{phase:"drive",board:$b,repo:$r,issue:$n,title:$t,action:"drive-ready",class:"Operational",kind:$k,mode:"fresh",route:$route,
            emit:(if $route=="spike"
                  then "claim #"+($n|tostring)+" then drive this standalone spike to its verdict directly (build.md kind:spike path for a Ready singleton — the same path /sweep uses): investigate, write the verdict note to the vault, route any follow-up issue, then close #"+($n|tostring)+" with the note linked. Do NOT run /assess --epic — a standalone spike is a singleton, not an epic, so /assess refuses it."
                  elif $route=="singleton-code"
                  then "claim #"+($n|tostring)+" then drive this bare code singleton via the /sweep per-issue build path SCOPED to #"+($n|tostring)+" ALONE (build-level.mjs: worktree → isolated worker → PR → CI → the /build merge gate — the same per-issue mechanics /sweep Phase 2 runs). It is a Ready singleton (0 sub-issues, no ## Contract), NOT an epic, so /assess --epic would refuse it. Do NOT run /assess --epic; do NOT /sweep the whole Ready pool — drive only #"+($n|tostring)+"."
                  else "claim #"+($n|tostring)+" then run: /triage --board "+$b+" → /assess --epic "+($n|tostring)+" → /build <plan> --unattended (auto-merge on green)"
                  end),
            detail:(if $route=="spike"
                    then "standalone spike = Ready singleton, not an epic; drive to a verdict note + routed follow-up via the kind:spike singleton path, never /assess --epic (#635)"
                    elif $route=="singleton-code"
                    then "bare Ready singleton (0 sub-issues, no ## Contract) — driven via the /sweep per-issue build path scoped to this issue, never /assess --epic (which refuses it) nor the whole-pool /sweep (#717, the kind:code sibling of #635)"
                    else "inherits WIP cap + quota + claim-first + epic lifecycle from the called commands (re-embeds none)"
                    end)}')"
      fi
      did_op=$((did_op+1))
    elif [ "$cls" = "Foundational" ] && [ "$did_found" -eq 0 ]; then
      # Phase C — route the Foundational design/approval gate to the queue.
      # build.md's decision-issue backend posts the gate; the scheduler names it.
      #
      # #720: a bare Foundational item (0 sub-issues AND no `## Contract`) has nothing
      # for /assess to decompose — the prep step ("epic has no sub-issues and no
      # ## Contract → run /triage") FAILS every tick and the item never reaches the
      # decision queue. Reuse the #717 bare_ready_singleton probe: a bare decision
      # routes STRAIGHT to the queue (mode:direct, skip the /assess prep); a genuine epic
      # (sub-issues or a `## Contract` body) keeps the prep-then-gate path. The probe
      # fails OPEN to the epic route on any error, so an ambiguous item keeps today's
      # prep behavior (never mis-routes an epic to the direct path).
      #
      # #977: emit `reassign_to` as a BARE login (strip the leading `@`) — it feeds an
      # `--add-assignee` call (funnel-drive.md) and GitHub's replaceActorsForAssignable
      # cannot resolve an `@`-prefixed login (`@example-operator`). Mirrors funnel-drive.sh's
      # `${FUNNEL_OPERATOR#@}` strip (555/633); the `@` stays in FUNNEL_OPERATOR for
      # mention text, only the assignee target is bared. The literal `@me` token is
      # PRESERVED (gh resolves it to the authenticated user; `me` alone is a non-user).
      local froute="prep"
      if bare_ready_singleton "$board" "$repo" "$num"; then froute="direct"; fi
      add_action "$(jq -cn --arg b "$board" --arg r "$repo" --argjson n "$num" --arg t "$title" --arg op "$FUNNEL_OPERATOR" --arg mode "$froute" \
        '{phase:"route",board:$b,repo:$r,issue:$n,title:$t,action:"route-foundational",class:"Foundational",mode:$mode,
          reassign_to:(if $op == "@me" then $op else ($op | ltrimstr("@")) end),
          emit:(if $mode=="direct"
                then "route #"+($n|tostring)+" STRAIGHT to the decision queue (NO /assess prep — 0 sub-issues, no ## Contract, nothing to decompose): post the design + plan-approval gate comment, apply `decision` label, assign operator, park — via build.md decision-issue backend"
                else "prep #"+($n|tostring)+" (decompose/draft via /assess) then route design + plan-approval to the decision queue: post gate comment, apply `decision` label, assign operator, park — via build.md decision-issue backend"
                end),
          detail:(if $mode=="direct"
                  then "bare Foundational decision (0 sub-issues, no ## Contract) — nothing for /assess to decompose (the prep step would fail every tick, #720); routed straight to the async decision backend"
                  else "prep-then-gate: operator-led, routed to the async decision backend (re-embeds no gate logic)"
                  end)}')"
      did_found=1
    fi
    j=$((j+1))
  done

  # A tick is a no-op only when NO phase produced an action — Phase A2 (n_clar>0
  # ⇒ a drain / already-applied / contention was emitted) counts too, mirroring how
  # n_dec gates the decision drain. Without the n_clar term, a drain-only tick would
  # append a contradicting "no drivable work" record.
  if [ "$did_op" -eq 0 ] && [ "$did_found" -eq 0 ] && [ "$did_route" -eq 0 ] && [ "$n_dec" -eq 0 ] && [ "$n_clar" -eq 0 ]; then
    add_action "$(jq -cn --arg b "$board" --arg r "$repo" \
      '{phase:"tick",board:$b,repo:$r,action:"no-op",detail:"no answered decisions/clarifications and no drivable Ready work this tick"}')"
  fi
}

# ── Main loop: enabled boards (or the one --board, if it is enabled) ─────────
BOARDS_TO_RUN=""
if [ -n "$ONE_BOARD" ]; then
  if board_enabled "$ONE_BOARD"; then
    BOARDS_TO_RUN="$ONE_BOARD"
  else
    # An explicit --board that is OFF: emit a disabled record, do nothing.
    jq -cn --arg b "$ONE_BOARD" \
      '{tick:"done",actions:[{phase:"tick",board:$b,action:"board-disabled",
        detail:"board not in FUNNEL_ENABLED_BOARDS — driver OFF for it (pilot = stageFind only)"}]}'
    exit 0
  fi
else
  BOARDS_TO_RUN="$FUNNEL_ENABLED_BOARDS"
fi

for b in $BOARDS_TO_RUN; do
  tick_board "$b"
done

jq -cn --argjson actions "$ACTIONS" --argjson dry "$DRY_RUN" \
  '{tick:"done", dry_run:($dry==1), actions:$actions}'
