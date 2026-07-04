#!/usr/bin/env bash
#
# funnel-cron.sh — the autonomous funnel driver's CRON WRAPPER (foundation #596).
# Composes the three steps a scheduled wake performs, in order:
#
#   gate → tick (EMIT) → log/notify
#
# The OS cron (a fixed hourly launchd/cron wake on the deploy host) calls THIS; it is dumb
# and constant. funnel-schedule-gate.sh decides whether this hour may spend; the
# gate runs FIRST, so a skipped hour costs one file read + an exit with ZERO `gh`
# calls. Only on a "run" verdict does the wrapper touch the board (via
# funnel-tick.sh). See
# `Decisions/foundation - Funnel cron hourly-wake + vault schedule-file gate`.
#
#   funnel-cron.sh                              # live: gate, then tick the boards
#   funnel-cron.sh --dry-run --fixture <dir>    # offline: gate, then tick the stub
#   funnel-cron.sh --backfill [--from <dir>] [--to <dir>]
#                                                # one-time: merge foundation.cron's
#                                                # raw lake into the canonical main-
#                                                # checkout lake (#725, see below)
#
# RUNG 5a — EMIT-ONLY by default. The wrapper runs funnel-tick.sh (which EMITS a
# tick plan) and logs it. RUNG 5b (#604) adds an OPT-IN drive step: when
# FUNNEL_DRIVE=1 (default OFF — the deploy host's plist sets it when the 5b soak begins)
# and the tick decided real work, Step 4 hands the plan to funnel-drive.sh, which
# auto-executes only the SAFE, no-merge tier (route-*/drain-*/kind:spike drives)
# via a headless `claude -p "/funnel-drive"`. Merging drives (drive-ready
# kind:code) stay emit-only for the operator to run by hand (rung 5c). With
# FUNNEL_DRIVE unset the wrapper is byte-for-byte the 5a emit-only behavior.
#
# Every wake appends one record to FUNNEL_LOG_DIR/<date>.jsonl and overwrites
# FUNNEL_LOG_DIR/latest.json, whether it ran or skipped — the log is the soak
# evidence (#596 acceptance). A skip writes {"event":"skipped","reason":…}; a run
# writes {"event":"ran","boards":[…],"plans":[…]}.
#
# It ALSO dual-writes into the canonical raw lake (RAW_DIR below, resolved from
# FUNNEL_RAW_DIR) as funnel-<YYYY-MM>.jsonl. canonical sink spec:
# meta/data/raw/README.md (lake path + schema-version convention; this
# stream's own field-by-event schema lives there too).
#
# NOTIFY on a non-no-op run (a tick plan that decided real work) via the
# injectable FUNNEL_NOTIFY_CMD, so a soak surfaces activity without the operator
# tailing the log. Injectable ⇒ tests fire nothing.
#
# Config (env overrides win):
#   REWORK_SNAPSHOT_BIN   test seam: override the rework-events snapshot binary
#                         invoked at Step 2.5 (default: ../rework-snapshot.sh,
#                         foundation #731)
#   FUNNEL_SCHEDULE_FILE  the gate's vault schedule note (see funnel-schedule-gate.sh)
#   FUNNEL_NOW_HOUR       test seam: override "now" hour, passed to the gate
#   FUNNEL_ENABLED_BOARDS default board set when the schedule's `boards:` is empty
#   FUNNEL_LOG_DIR        where the wake log lives (default ~/.claude/funnel/log)
#   FUNNEL_RAW_DIR        override for the canonical raw lake (default: an ABSOLUTE
#                         $HOME/dev/foundation/meta/data/raw — see #725 below, NOT
#                         derived from $FOUNDATION)
#   FUNNEL_NOTIFY_CMD     notify command on a non-no-op run (default: osascript banner
#                         if present, else a logged line). Receives the summary as $1.
#   FUNNEL_NOW_DATE       test seam: override the log's date stamp (default: date +%F)
#   FUNNEL_NOW_TS         test seam: override every record's ts stamp (default: UTC ISO-8601, literal Z)
#
# SELF-UPDATE (foundation #598). The cron runs from a DEDICATED checkout pinned to
# origin/main; on its own it would run code frozen at clone time. Opt-in env gate:
#   FUNNEL_CRON_SELF_UPDATE   set =1 (the plist sets it) to fetch + hard-reset the
#                             $FOUNDATION checkout to origin/main and re-exec ONCE
#                             before the gate, so THIS tick runs the freshly-pulled
#                             code. Default OFF — a bare dev/test/CI run never
#                             self-mutates a checkout.
#   FUNNEL_CRON_SELF_UPDATED  internal re-exec guard (set by the re-exec) — prevents
#                             an infinite update→re-exec loop. Do not set by hand.

set -euo pipefail

# Attribution for the gh call-logger shim (F#988): tag every gh call this command
# makes with its outermost context. `:-` preserves an already-set (outer) value,
# so an autonomous driver's context wins over a nested command. See
# workflows/scripts/gh-call-logger.sh.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-funnel-cron}"

command -v jq >/dev/null 2>&1 || { echo '{"event":"error","reason":"jq not found"}' >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workflows/scripts/build/build.config.sh
[ -f "$HERE/build.config.sh" ] && . "$HERE/build.config.sh"

# The four sub-scripts, each with a test-double injection seam (mirrors
# funnel-drive.sh's CLAUDE_BIN) so the error-context paths (#640: gate/tick/drive
# crash → capture stderr into the record) are unit-testable with a failing double.
GATE="${FUNNEL_GATE_BIN:-$HERE/funnel-schedule-gate.sh}"
TICK="${FUNNEL_TICK_BIN:-$HERE/funnel-tick.sh}"
DRIVE="${FUNNEL_DRIVE_BIN:-$HERE/funnel-drive.sh}"
# issue-meta-snapshot.sh lives at workflows/scripts/ (one level up from
# workflows/scripts/build/, where the other three siblings live) — see #732.
ISSUE_META="${FUNNEL_ISSUE_META_BIN:-$HERE/../issue-meta-snapshot.sh}"
REWORK_SNAPSHOT="${REWORK_SNAPSHOT_BIN:-$HERE/../rework-snapshot.sh}"

: "${FUNNEL_ENABLED_BOARDS:=3}"
: "${FUNNEL_LOG_DIR:=$HOME/.claude/funnel/log}"

# ── Step 0: opt-in self-update (foundation #598) ──────────────────────────────
# When FUNNEL_CRON_SELF_UPDATE=1 (set by the LaunchAgent plist; default OFF so
# dev/test/CI never self-mutate a checkout), fetch + hard-reset the $FOUNDATION
# checkout to origin/main and re-exec ONCE — so this very tick runs the latest
# merged funnel code rather than the code frozen at clone time. Discarding any
# drift in the dedicated checkout is intended. FUNNEL_CRON_SELF_UPDATED guards the
# single re-exec against an infinite loop.
#
# FAIL-SAFE: any git/network error is logged (to stderr) and we PROCEED with the
# current checkout — still gated, fail-closed. We do NOT skip the tick on update
# failure: the schedule gate is the spend safety, and running last-known-good code
# beats letting a transient GitHub blip wedge the cron. The pre-fetch HEAD is also
# left untouched on failure (fetch/reset are conditional), so a partial failure
# never leaves the checkout in a half-updated state.
# self_update_note carries a FAILED self-update forward into the tick's wake record
# (#640): the failure used to go to stderr only, invisible to the durable log, so a
# checkout silently frozen at clone-time drift left no trace. Empty = no failure to
# report (the OK path re-execs into a fresh process that never sees this block).
self_update_note=""
if [ "${FUNNEL_CRON_SELF_UPDATE:-0}" = "1" ] && [ "${FUNNEL_CRON_SELF_UPDATED:-0}" != "1" ]; then
  repo="${FOUNDATION:-$(cd "$HERE/../../.." && pwd)}"
  su_err="$( ( cd "$repo" \
       && git fetch --quiet origin main \
       && git reset --quiet --hard FETCH_HEAD ) 2>&1 )" && su_ok=1 || su_ok=0
  if [ "$su_ok" -eq 1 ]; then
    jq -nc --arg r "$repo" '{event:"self-update",repo:$r,status:"ok"}' >&2 || true
    export FUNNEL_CRON_SELF_UPDATED=1
    exec /bin/bash "$0" "$@"
  else
    jq -nc --arg r "$repo" --arg e "$su_err" \
      '{event:"self-update",repo:$r,status:"failed",note:"proceeding with current checkout",context:$e}' >&2 || true
    # Stash the real cause so the tick's wake record carries it (not just stderr).
    self_update_note="$(jq -nc --arg e "$su_err" '{status:"failed",context:$e}')"
  fi
fi

# ── One-time backfill (foundation #725) ───────────────────────────────────────
# Migrates funnel-*.jsonl history written into foundation.cron's raw lake (the
# WRONG sink, before the canonical-RAW_DIR fix above) into the canonical
# main-checkout lake. Idempotent + dedup-safe: an exact-line diff against the
# destination file, so re-running (or running after the two lakes have partially
# diverged) only appends lines not already present byte-for-byte — safe to run
# more than once, safe if some records already made it into both sinks via other
# means. NOT run automatically by this script or by cron; a one-time OPERATOR step
# (post-merge, on the deploy host, where foundation.cron actually exists), e.g.:
#   funnel-cron.sh --backfill
#   funnel-cron.sh --backfill --from ~/dev/foundation.cron/meta/data/raw \
#                              --to   ~/dev/foundation/meta/data/raw
# Both flags default to the WRONG (foundation.cron) and canonical (main checkout,
# honoring FUNNEL_RAW_DIR if set) lakes respectively, so a bare `--backfill` does
# the right thing on the deploy host without any flags.
_funnel_backfill() {
  local from="$1" to="$2" f base target tmp added found
  if [ ! -d "$from" ]; then
    echo "funnel-cron --backfill: source dir not found: $from (nothing to backfill)" >&2
    return 0
  fi
  mkdir -p "$to"
  found=0
  shopt -s nullglob
  for f in "$from"/funnel-*.jsonl; do
    found=1
    base="$(basename "$f")"
    target="$to/$base"
    if [ ! -f "$target" ]; then
      cp "$f" "$target"
      added="$(wc -l < "$f" | tr -d ' ')"
      printf 'funnel-backfill: %s -> %s (new file, %s line(s))\n' "$f" "$target" "$added"
      continue
    fi
    tmp="$(mktemp)"
    # Exact-line dedup: only lines from $f NOT already present (byte-identical) in
    # $target are appended — an idempotent merge, never a blind concatenation.
    awk 'NR==FNR{seen[$0]=1; next} !($0 in seen)' "$target" "$f" > "$tmp"
    added="$(wc -l < "$tmp" | tr -d ' ')"
    [ "$added" -gt 0 ] && cat "$tmp" >> "$target"
    rm -f "$tmp"
    printf 'funnel-backfill: %s -> %s (%s new line(s) appended, rest already present)\n' "$f" "$target" "$added"
  done
  shopt -u nullglob
  [ "$found" -eq 0 ] && echo "funnel-cron --backfill: no funnel-*.jsonl in $from (nothing to backfill)" >&2
  return 0
}

# ── Arg parse (--dry-run pass-through, plus the --backfill one-time subcommand) ─
DRY_RUN=0
FIXTURE=""
BACKFILL=0
BACKFILL_FROM="$HOME/dev/foundation.cron/meta/data/raw"
BACKFILL_TO="${FUNNEL_RAW_DIR:-$HOME/dev/foundation/meta/data/raw}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --fixture) FIXTURE="${2:?--fixture needs a dir}"; shift 2 ;;
    --backfill) BACKFILL=1; shift ;;
    --from) BACKFILL_FROM="${2:?--from needs a dir}"; shift 2 ;;
    --to) BACKFILL_TO="${2:?--to needs a dir}"; shift 2 ;;
    -h|--help)
      echo "usage: funnel-cron.sh [--dry-run --fixture <dir>]" >&2
      echo "       funnel-cron.sh --backfill [--from <dir>] [--to <dir>]" >&2
      exit 2 ;;
    *) echo "funnel-cron.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
if [ "$DRY_RUN" -eq 1 ] && [ -z "$FIXTURE" ]; then
  echo "funnel-cron.sh: --dry-run requires --fixture <dir>" >&2; exit 2
fi
if [ "$BACKFILL" -eq 1 ]; then
  _funnel_backfill "$BACKFILL_FROM" "$BACKFILL_TO"
  exit $?
fi

# ── Log helpers ───────────────────────────────────────────────────────────────
log_date="${FUNNEL_NOW_DATE:-$(date +%F)}"
# One ISO-8601 timestamp for this tick's records, computed once at start (like
# log_date). All records from one invocation share the tick's wake time; that's
# the clean clock #663 adds. FUNNEL_NOW_TS is the test seam (mirrors FUNNEL_NOW_DATE).
log_ts="${FUNNEL_NOW_TS:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# Per-action timing (#640): measure wake / tick / drive wall time so a soak review
# can see cron cadence adherence, slow drains/drives, and headless-session timeouts
# (only the BUILD_HEADLESS_POLL_TIMEOUT *limit* was ever visible, never the measured
# value). SECOND granularity: macOS /bin/bash is 3.2 (no EPOCHREALTIME) and BSD
# `date` has no %N, so sub-second ms is not portably cheap — `duration_ms` is derived
# from whole-second epoch deltas (0, 1000, 2000…), enough for drains/drives that run
# seconds-to-minutes. FUNNEL_NOW_EPOCH is the test seam (mirrors FUNNEL_NOW_TS).
_epoch_s() { echo "${FUNNEL_NOW_EPOCH:-$(date +%s)}"; }
_dur_ms() { echo $(( ( $(_epoch_s) - ${1:-0} ) * 1000 )); }   # $1 = start epoch seconds
wake_start_s="$(_epoch_s)"

mkdir -p "$FUNNEL_LOG_DIR"
LOG_FILE="$FUNNEL_LOG_DIR/$log_date.jsonl"
LATEST="$FUNNEL_LOG_DIR/latest.json"

# ── Raw telemetry lake (L0, #639) ─────────────────────────────────────────────
# The home-dir log above is LOCAL, non-git-archived, and lost to disk pressure, so
# it cannot surface multi-week/-month funnel-health trends. Dual-write every record
# to foundation's git-tracked, archivable raw lake (meta/data/raw/) — the same
# substrate the session/token/eval streams feed → rollups → dashboard. MONTHLY
# rotation (`funnel-<YYYY-MM>.jsonl`) matches the existing `2026-06.jsonl` siblings
# and keeps the dir from proliferating.
#
# CANONICAL ABSOLUTE SINK (foundation #725). The default is an ABSOLUTE path into
# the MAIN checkout's lake — deliberately NOT derived from $FOUNDATION. The
# installed cron plist points FOUNDATION at a DEDICATED checkout
# ($HOME/dev/foundation.cron, the #598 self-update sandbox), so a
# $FOUNDATION-relative default silently wrote the live stream into that throwaway
# checkout's meta/data/raw/ instead of the main checkout's — invisible to the main
# dashboard, whose funnel panel then rendered empty. Decoupling RAW_DIR from
# $FOUNDATION fixes the sink regardless of which checkout the cron runs from.
# FUNNEL_RAW_DIR remains the explicit override / test seam and always wins.
RAW_DIR="${FUNNEL_RAW_DIR:-$HOME/dev/foundation/meta/data/raw}"
RAW_FILE="$RAW_DIR/funnel-${log_date%-*}.jsonl"   # ${log_date%-*} = YYYY-MM
mkdir -p "$RAW_DIR" 2>/dev/null || true

# Append one record to a sink, warning (never silently dropping) on failure. A raw
# lake or a full disk must be a VISIBLE error, not a lost record (#639 acceptance).
_write_sink() {  # $1=record  $2=path  $3=mode(append|overwrite)
  if [ "$3" = "overwrite" ]; then printf '%s\n' "$1" > "$2" 2>/dev/null
  else printf '%s\n' "$1" >> "$2" 2>/dev/null; fi \
    || printf 'funnel-cron: WARN failed to write record to %s (record not dropped from other sinks)\n' "$2" >&2
}

# Stamp + persist one wake record: home-dir day log + latest.json + the raw lake.
emit_record() {
  local rec="$1"
  # Stamp the per-tick ts at this single write chokepoint so every record type
  # (skipped / ran / drive / self-update) carries a clock without each call site
  # changing (#663). The chokepoint owns the field, so any inbound ts is replaced.
  rec="$(jq -c --arg ts "$log_ts" '. + {ts:$ts}' <<<"$rec")"
  _write_sink "$rec" "$LOG_FILE" append
  _write_sink "$rec" "$LATEST" overwrite
  _write_sink "$rec" "$RAW_FILE" append   # L0 (#639): the git-archivable copy
  printf '%s\n' "$rec"   # also to stdout so a manual run / cron log shows it
}

# ── Step 1: gate ──────────────────────────────────────────────────────────────
# The gate is a pure predicate (exit 0 = run / 1 = skip). It makes ZERO network
# calls, so this is the cheap fail-closed front door before any board read. The
# gate reads FUNNEL_SCHEDULE_FILE / FUNNEL_NOW_HOUR from the inherited env.
# Capture the gate's stderr (#640): a genuine not-scheduled skip and a gate that
# CRASHED both used to collapse to reason:"skipped", indistinguishable. Keep stdout
# (the verdict JSON) and stderr separate so a crash surfaces its real cause.
gate_err_file="$FUNNEL_LOG_DIR/.gate-err.$$"
verdict="$("$GATE" 2>"$gate_err_file")" && gate_run=1 || gate_run=0
gate_err="$(cat "$gate_err_file" 2>/dev/null || true)"; rm -f "$gate_err_file"

if [ "$gate_run" -eq 0 ]; then
  # If the verdict parses, reason is the gate's own (e.g. "outside scheduled hours").
  # If it does NOT parse (empty/garbage on a crash), say so and carry the real cause
  # in `context` — never a bare "skipped" that hides a broken gate.
  if reason="$(jq -re '.reason' <<<"$verdict" 2>/dev/null)"; then
    skip_rec="$(jq -nc --arg r "$reason" --arg d "$log_date" '{event:"skipped",date:$d,reason:$r}')"
  else
    reason="gate produced no parseable verdict"
    skip_rec="$(jq -nc --arg r "$reason" --arg d "$log_date" --arg c "${gate_err:-$verdict}" \
      '{event:"skipped",date:$d,reason:$r,context:$c}')"
  fi
  [ -n "$self_update_note" ] && skip_rec="$(jq -c --argjson su "$self_update_note" '. + {self_update:$su}' <<<"$skip_rec")"
  emit_record "$skip_rec" >/dev/null
  # Surface the skip on stdout for a manual run / the cron log, then exit clean.
  jq -nc --arg r "$reason" '{event:"skipped",reason:$r}'
  exit 0
fi

# ── Step 2: tick (EMIT) ───────────────────────────────────────────────────────
# Resolve the board set: the schedule's `boards:` override wins; else the
# code-level FUNNEL_ENABLED_BOARDS. (The gate already validated the override's
# tokens are integers.)
sched_boards="$(jq -r '.boards // ""' <<<"$verdict" 2>/dev/null || echo "")"
boards="${sched_boards:-$FUNNEL_ENABLED_BOARDS}"
[ -n "$boards" ] || boards="$FUNNEL_ENABLED_BOARDS"

# Resolve the per-tick DRIVE CAP (#642): the schedule's `cap:` override wins; else
# the code-level FUNNEL_DRIVE_CAP default (build.config.sh, =1). One vault field
# governs BOTH enforcement points, so export it as FUNNEL_DRIVE_CAP (the tick's
# emit cap) AND FUNNEL_DRIVE_MERGE_CAP (the 5c merge blast-radius). The explicit
# export makes the vault the single source of truth — it overrides any value the
# installed plist inherited into this process, and it is inherited by the tick
# subprocess and the piped funnel-drive.sh child. (The gate already validated the
# override is an integer ≥ 1; an absent/bad cap arrives empty → the code default.)
sched_cap="$(jq -r '.cap // ""' <<<"$verdict" 2>/dev/null || echo "")"
cap="${sched_cap:-$FUNNEL_DRIVE_CAP}"
[ -n "$cap" ] || cap="$FUNNEL_DRIVE_CAP"
export FUNNEL_DRIVE_CAP="$cap"
export FUNNEL_DRIVE_MERGE_CAP="$cap"

plans='[]'
tick_err_file="$FUNNEL_LOG_DIR/.tick-err.$$"
for b in $boards; do
  # Capture the tick's stderr + wall time per board (#640). A tick crash used to
  # collapse to a bare {"tick":"error"} stub with stderr dropped — the real cause
  # (a board-resolve failure, a jq parse error) was lost. Now the stub carries the
  # captured stderr as `context`, and every plan carries `tick_ms`.
  tick_start_s="$(_epoch_s)"
  if [ "$DRY_RUN" -eq 1 ]; then
    plan="$("$TICK" --dry-run --fixture "$FIXTURE" --board "$b" 2>"$tick_err_file")" \
      || plan="$(jq -nc --arg b "$b" --arg e "$(cat "$tick_err_file" 2>/dev/null || true)" \
           '{tick:"error",board:$b,reason:"funnel-tick.sh failed",context:$e}')"
  else
    plan="$("$TICK" --board "$b" 2>"$tick_err_file")" \
      || plan="$(jq -nc --arg b "$b" --arg e "$(cat "$tick_err_file" 2>/dev/null || true)" \
           '{tick:"error",board:$b,reason:"funnel-tick.sh failed",context:$e}')"
  fi
  plan="$(jq -c --argjson ms "$(_dur_ms "$tick_start_s")" '. + {tick_ms:$ms}' <<<"$plan" 2>/dev/null || printf '%s' "$plan")"
  plans="$(jq -c --argjson p "$plan" '. + [$p]' <<<"$plans")"
done
rm -f "$tick_err_file"

# ── Step 2.5: rework-events snapshot (foundation #731, epic #724 Contract) ────
# Appends a rework-events raw-lake record (reverts / reopens / CI-fails-per-PR /
# fix-of-recent-merge heuristic) for each board just ticked, via
# workflows/scripts/rework-snapshot.sh. This is a SIDE emit, not part of the
# tick's decision-making — isolated with `|| true` at the call site (mirrors
# claim.sh's `claim_log_emit "$item_id" || true`), so a snapshot failure NEVER
# breaks the wake. Skipped entirely on --dry-run: a fixture-replay tick has no
# real repo to snapshot, and rework-snapshot.sh (unlike TICK/DRIVE) has no
# --dry-run mode of its own — it only ever performs live `gh` reads. A live
# hourly wake (the launchd plist invocation) never passes --dry-run, so this is
# still exercised on every real run. REWORK_SNAPSHOT_BIN is the test seam
# (mirrors FUNNEL_GATE_BIN/FUNNEL_TICK_BIN/FUNNEL_DRIVE_BIN) for a zero-network
# non-dry-run test to inject a stub in place of the real script.
if [ "$DRY_RUN" -eq 0 ]; then
  for b in $boards; do
    "$REWORK_SNAPSHOT" snapshot --board "$b" >/dev/null 2>&1 || true
  done
fi

# A run is "non-no-op" iff some tick decided an action that is NOT purely no-op /
# board-disabled / steady-state — i.e. real work or a NEW operator hand-off was
# named (drain / drive / route-foundational all count). A bare no-op, a
# board-disabled record, and `route-already-assigned` do NOT: the last is an item
# already in the operator's court (a `needs-clarification` question assigned at source
# by its producer — #684 — or a `funnel-escalated` stuck 5c code item — #697), so
# re-surfacing it every hourly tick would be notification spam (foundation #600).
nonop="$(jq '[.[].actions[]? | select(.action != null and .action != "no-op"
            and .action != "board-disabled" and .action != "route-already-assigned")] | length' <<<"$plans" 2>/dev/null || echo 0)"

record="$(jq -nc --arg d "$log_date" --argjson boards \
  "$(printf '%s' "$boards" | jq -R 'split(" ")|map(select(length>0))')" \
  --argjson plans "$plans" --argjson nonop "${nonop:-0}" --argjson ms "$(_dur_ms "$wake_start_s")" \
  '{event:"ran",date:$d,boards:$boards,nonop_actions:$nonop,duration_ms:$ms,plans:$plans}')"
# Carry a FAILED self-update forward into the durable wake record (#640).
[ -n "$self_update_note" ] && record="$(jq -c --argjson su "$self_update_note" '. + {self_update:$su}' <<<"$record")"
emit_record "$record" >/dev/null

# ── Step 3: notify (only on a non-no-op run) ─────────────────────────────────
if [ "${nonop:-0}" -gt 0 ]; then
  summary="funnel: $nonop action(s) across board(s) $boards ($log_date)"
  if [ -n "${FUNNEL_NOTIFY_CMD:-}" ]; then
    "$FUNNEL_NOTIFY_CMD" "$summary" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$summary\" with title \"funnel-cron\"" >/dev/null 2>&1 || true
  else
    printf 'NOTIFY: %s\n' "$summary" >&2
  fi
fi

# ── Step 4: drive (RUNG 5b safe tier + 5c merge tier, opt-in — #604, #615) ────
# When FUNNEL_DRIVE=1 and the tick decided real work, hand the collected plans to
# funnel-drive.sh, which auto-executes the SAFE, no-merge tier (route-* / drain-* /
# kind:spike drives) via a headless `claude -p "/funnel-drive"`. The merging tier
# (drive-ready kind:code) is left for the operator UNLESS FUNNEL_DRIVE_MERGE=1
# (rung 5c), in which case funnel-drive.sh ALSO drives it — capped — via
# `claude -p "/funnel-drive-merge"` through /build's own gated merge. The 5c merge
# tier RIDES ON TOP of the safe tier: it runs only when this step runs at all, so
# FUNNEL_DRIVE=1 is its precondition. The drive outcome is persisted as its own
# wake record (the "ran" tick record above is the soak evidence; this is the
# execution evidence). FUNNEL_DRIVE=0 ⇒ this whole step is skipped (byte-for-byte
# 5a); FUNNEL_DRIVE=1 + FUNNEL_DRIVE_MERGE=0 (default) ⇒ pure 5b.
#
# A cron --dry-run passes --dry-run THROUGH to funnel-drive.sh, which then reports
# the SAFE/MERGING tiering WITHOUT spawning any claude — so the offline fixture
# path stays side-effect-free. Fail-open: a driver error is logged, never thrown.
drive_status="off"
if [ "${FUNNEL_DRIVE:-0}" = "1" ] && [ "${nonop:-0}" -gt 0 ]; then
  drive_dry=()
  [ "$DRY_RUN" -eq 1 ] && drive_dry=(--dry-run)
  # bash 3.2 (macOS /bin/bash, what the plist invokes) treats "${empty[@]}" under
  # `set -u` as an unbound variable — so guard the expansion (expand only if set).
  # The first live 5b drive crashed here until this was fixed (#612).
  # Capture the driver's stderr + wall time (#640). A driver crash used to drop
  # stderr and emit a bare status:"error" stub — the real cause invisible. Now the
  # stub carries the captured stderr as `context`, and the record carries drive
  # `duration_ms` (a headless `claude -p` drive is the slowest action in a tick).
  drive_start_s="$(_epoch_s)"
  drive_err_file="$FUNNEL_LOG_DIR/.drive-err.$$"
  drive_rec="$(printf '%s' "$plans" | "$DRIVE" ${drive_dry[@]+"${drive_dry[@]}"} 2>"$drive_err_file")" \
    || drive_rec="$(jq -nc --arg e "$(cat "$drive_err_file" 2>/dev/null || true)" \
         '{event:"drive",status:"error",reason:"funnel-drive.sh failed",context:$e}')"
  rm -f "$drive_err_file"
  drive_rec="$(jq -c --arg d "$log_date" --argjson ms "$(_dur_ms "$drive_start_s")" \
    '. + {date:$d, duration_ms:$ms}' <<<"$drive_rec" 2>/dev/null || printf '%s' "$drive_rec")"
  emit_record "$drive_rec" >/dev/null
  drive_status="$(jq -r '.status // "error"' <<<"$drive_rec" 2>/dev/null || echo error)"
fi

# ── Step 5: issue-meta snapshot (foundation #732, epic #724 Contract) ────────
# Batched issue -> epic/milestone snapshot for the cost rollup to enrich
# OFFLINE with (rollups must stay network-free — see the build_*.py
# rollups-pure invariant; this is the snapshot layer, NOT a rollup). Runs once
# per non-skipped wake, alongside the RAW_DIR writes above, independent of
# `nonop`/drive — the metadata snapshot is useful even on a no-op tick.
#
# `|| true`-isolated (belt + braces on top of issue-meta-snapshot.sh's own
# WARN-don't-fail contract): a failure here must NEVER break the wake. Under
# --dry-run, --dry-run is passed through so the offline fixture path
# (test_funnel_cron.sh) never makes a real `gh` call, mirroring Step 4's
# DRY_RUN pass-through to funnel-drive.sh.
if [ "$DRY_RUN" -eq 1 ]; then
  "$ISSUE_META" --dry-run >/dev/null 2>&1 || true
else
  "$ISSUE_META" >/dev/null 2>&1 || true
fi

# Surface the run summary on stdout (the full record went to the log).
jq -nc --argjson nonop "${nonop:-0}" --argjson plans "$plans" --arg drive "$drive_status" \
  '{event:"ran",nonop_actions:$nonop,plan_count:($plans|length),drive:$drive}'
exit 0
