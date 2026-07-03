#!/usr/bin/env bash
#
# funnel-schedule-gate.sh — the autonomous funnel driver's OPERATOR-EDITABLE
# schedule gate (foundation #596). A standalone, testable predicate: it reads an
# operator-owned vault file and decides whether THIS hour's cron wake may spend
# tokens. The OS cron is dumb and constant (a fixed hourly launchd wake); ALL
# timing intelligence lives in the file, so the operator dials *when* the funnel
# runs by editing a note — no crontab edit, no redeploy. See
# `Decisions/foundation - Funnel cron hourly-wake + vault schedule-file gate`.
#
#   funnel-schedule-gate.sh            # read the schedule file, print one verdict
#
# Verdict JSON (stdout, one line) + EXIT CODE (the contract the wrapper composes):
#   {"action":"run","hour":H,"boards":"<list-or-empty>"}   exit 0  → run this hour
#   {"action":"skip","reason":"…","hour":H}                exit 1  → skip this hour
#
# RUNS IFF `enabled: yes` AND the current hour ∈ the `hours:` list. Everything
# else is a skip.
#
# FAIL-CLOSED is the load-bearing invariant — the inverse of quota-gate.sh's
# fail-open. A spending gate must default to *don't spend*: a missing / unreadable
# / malformed file, an absent-or-non-`yes` `enabled:`, an empty/bad `hours:` list,
# or any non-integer / out-of-range token → **skip** (exit 1), never run. The
# file's existence + `enabled: yes` is the explicit opt-in; deleting it or setting
# `enabled: no` is the kill switch. A sync hiccup or a typo therefore quiets the
# funnel rather than silently re-enabling autonomous hourly spend.
#
# Schedule file = a normal Obsidian note carrying ONE machine-readable fenced
# block the gate greps (everything outside it is free prose for the operator):
#   ```funnel-schedule
#   enabled: yes
#   hours: 9 12 15 18      # local host time, 0–23 — THE token dial
#   boards: 3              # optional; default = the wrapper's FUNNEL_ENABLED_BOARDS
#   note: free-text why
#   ```
# The `hours:` list IS the token-allocation lever: more hours = more autonomous
# runs = more spend; fewer / `enabled: no` = quiet.
#
# Config (env overrides win; defaults centralized in build.config.sh):
#   FUNNEL_SCHEDULE_FILE  the vault schedule note (default: <ks_root>/Context/foundation
#                         - funnel schedule.md — ks_root's default is seeded in
#                         build.config.sh, see knowledge_store.contract.md)
#   FUNNEL_NOW_HOUR       test seam: override "now" hour 0–23 (default: date +%H)

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"action":"skip","reason":"jq not found"}'; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workflows/scripts/build/build.config.sh
[ -f "$HERE/build.config.sh" ] && . "$HERE/build.config.sh"
# shellcheck source=workflows/scripts/lib/knowledge_store.sh
[ -f "$HERE/../lib/knowledge_store.sh" ] && . "$HERE/../lib/knowledge_store.sh"

# Root resolution routes through the knowledge_store seam's ks_root (foundation
# #777, Epic A #762 "kernel split") rather than a literal — build.config.sh
# (sourced above) seeds KNOWLEDGE_STORE_ROOT's foundation-specific default, so
# an unconfigured environment resolves to the SAME schedule-file path this gate
# has always used. The vault-relative "Context/foundation - funnel schedule.md"
# knob (the operator-editable part) is unchanged.
: "${FUNNEL_SCHEDULE_FILE:=$(ks_root 2>/dev/null || true)/Context/foundation - funnel schedule.md}"

# Emit a skip verdict (fail-closed) and exit 1. Defined as a function so every
# bail-out path is one call; `now_hour` may be unset on the earliest failures, so
# it is resolved lazily with a `-` default. Defined BEFORE the now_hour check so
# that check can use it.
skip() { jq -nc --arg r "$1" --argjson h "${now_hour:-0}" '{action:"skip",reason:$r,hour:$h}'; exit 1; }

# Current hour 0–23. FUNNEL_NOW_HOUR is the offline test seam (so the gate
# unit-tests deterministically with no real clock, exactly like funnel-tick.sh's
# fixtures). `10#` forces base-10 so a leading-zero `date +%H` (e.g. "09") is not
# read as octal.
now_hour="${FUNNEL_NOW_HOUR:-$(date +%H)}"
case "$now_hour" in
  ''|*[!0-9]*) skip "current hour not numeric: '$now_hour'" ;;
esac
now_hour=$(( 10#$now_hour ))

[ -r "$FUNNEL_SCHEDULE_FILE" ] || skip "schedule file missing/unreadable: $FUNNEL_SCHEDULE_FILE"

# Extract the fenced ```funnel-schedule … ``` block body (same awk idiom as
# funnel-tick.sh parse_reply's decision-block extraction). Only the FIRST block
# is read; lines outside it are ignored prose.
block="$(awk '/^```funnel-schedule[[:space:]]*$/{f=1;next} f&&/^```/{exit} f' "$FUNNEL_SCHEDULE_FILE" 2>/dev/null || true)"
[ -n "$block" ] || skip "no \`\`\`funnel-schedule block found in $FUNNEL_SCHEDULE_FILE"

# Pull one `key:` value out of the block (first match; strips a trailing `#`
# comment, CR, and surrounding whitespace). The grep is isolated in its own
# `… || line=""` so a no-match under `set -o pipefail` is an empty value, not a
# pipeline failure that would abort the gate.
field() {
  local line
  line="$(printf '%s\n' "$block" | grep -iE "^[[:space:]]*$1:" | head -1)" || line=""
  [ -n "$line" ] || return 0
  printf '%s' "$line" | sed -E "s@^[[:space:]]*$1:[[:space:]]*@@" | tr -d '\r' \
    | sed -E 's@[[:space:]]+#.*$@@; s@[[:space:]]+$@@'
}

enabled="$(field enabled)"
case "$enabled" in
  [Yy]|[Yy][Ee][Ss]) : ;;                       # enabled — proceed to the hour check
  [Nn]|[Nn][Oo]) skip "enabled: no (kill switch)" ;;
  '') skip "no \`enabled:\` field (fail-closed)" ;;
  *)  skip "enabled: '$enabled' is not yes/no (fail-closed)" ;;
esac

hours="$(field hours)"
[ -n "$hours" ] || skip "enabled but \`hours:\` is empty/missing (fail-closed)"

# Strict validation: EVERY hours token must be an integer 0–23, else fail-closed
# (a typo quiets the funnel rather than running at an unintended hour).
in_list=0
for h in $hours; do
  case "$h" in
    ''|*[!0-9]*) skip "non-integer hour token '$h' in hours list (fail-closed)" ;;
  esac
  h=$(( 10#$h ))
  if [ "$h" -lt 0 ] || [ "$h" -gt 23 ]; then
    skip "hour '$h' out of range 0–23 (fail-closed)"
  fi
  [ "$h" -eq "$now_hour" ] && in_list=1
done

# Optional boards override — same strict integer validation; surfaced in the
# verdict so the wrapper can scope the tick (empty → wrapper uses its default).
boards="$(field boards)"
if [ -n "$boards" ]; then
  for b in $boards; do
    case "$b" in
      ''|*[!0-9]*) skip "non-integer board token '$b' in boards list (fail-closed)" ;;
    esac
  done
fi

[ "$in_list" -eq 1 ] || skip "hour $now_hour not in scheduled hours ($hours)"

# Optional per-tick DRIVE CAP override (#642) — how many items the funnel drives
# per tick. UNLIKE hours:/boards:, a bad cap does NOT fail closed: the cap is a
# throughput knob, not a spend gate (the spend safety is the hours: list + the
# quota gate), so a missing/malformed cap must not quiet the whole hour. Absent →
# emit empty (the wrapper falls back to its FUNNEL_DRIVE_CAP code default). A
# present-but-malformed cap (non-integer or < 1) → emit empty + a one-line stderr
# note, so we don't silently run at an unintended cap but still run the hour.
cap="$(field cap)"
if [ -n "$cap" ]; then
  case "$cap" in
    *[!0-9]*) echo "funnel-schedule-gate: ignoring non-integer cap '$cap' (falling back to code default)" >&2; cap="" ;;
    *) if [ "$(( 10#$cap ))" -lt 1 ]; then
         echo "funnel-schedule-gate: ignoring cap '$cap' < 1 (falling back to code default)" >&2; cap=""
       else cap="$(( 10#$cap ))"; fi ;;
  esac
fi

jq -nc --argjson h "$now_hour" --arg b "$boards" --arg c "$cap" \
  '{action:"run",hour:$h,boards:$b,cap:$c}'
exit 0
