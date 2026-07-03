#!/usr/bin/env bash
#
# quota-gate.sh — the build / sweep 5-hour-quota DECISION script
# (foundation #447). Called at a level boundary (build) or after each fix
# (sweep): it reads the live rate-limit snapshot that status-line.sh
# persists and decides whether the run may proceed or should pause until the
# 5-hour window resets.
#
#   quota-gate.sh            # reads $BUILD_QUOTA_CACHE, prints one verdict JSON
#
# Verdict JSON (stdout, one line):
#   {"action":"proceed","remaining_pct":N}
#   {"action":"pause","remaining_pct":N,"reset_ts":T,"wait_secs":S}
#   {"action":"unavailable","reason":"…"}      ← FAIL OPEN: caller proceeds
#
# This script DECIDES; it never sleeps. The caller (the conversational command)
# owns the wait — foreground `sleep` is blocked in the harness, so on a "pause"
# the command backgrounds a `sleep <wait_secs>` and re-invokes this gate on wake.
# Resume is keyed on the window having rolled (now ≥ reset_ts), not on a fresh
# cache read.
#
# FAIL OPEN is the load-bearing invariant: a missing / stale / unparseable cache,
# or an account with no 5h window in the snapshot, yields "unavailable" and the
# caller PROCEEDS. A run must never stall because the quota signal is absent.
#
# Config (defaults in build.config.sh; env overrides win):
#   BUILD_QUOTA_PAUSE_PCT   pause when remaining 5h quota < this %  (default 10)
#   BUILD_QUOTA_CACHE       snapshot path        (default ~/.claude/rate-limits.json)
#   BUILD_QUOTA_WAIT_BUFFER seconds past reset before resume        (default 60)
#   BUILD_QUOTA_MAX_AGE     ignore snapshot older than this many s  (default 1800)
#   BUILD_QUOTA_NOW         test seam: override "now" (epoch s)      (default: date +%s)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workflows/scripts/build/build.config.sh
source "$HERE/build.config.sh"

now="${BUILD_QUOTA_NOW:-$(date +%s)}"
cache="$BUILD_QUOTA_CACHE"

# Emit an "unavailable" verdict (fail open) and exit 0.
unavailable() {
  jq -nc --arg r "$1" '{action:"unavailable", reason:$r}'
  exit 0
}

command -v jq >/dev/null 2>&1 || { printf '{"action":"unavailable","reason":"jq not found"}\n'; exit 0; }
[ -f "$cache" ] || unavailable "cache not found: $cache"

# Pull the fields with one jq call each. (A single `@tsv` + `read` collapses
# leading empty fields because TAB is IFS-whitespace, mis-assigning the vars —
# separate reads keep each field unambiguous, missing → empty via `// empty`.)
# The first jq doubles as the parse check: garbage JSON fails it → unavailable.
used="$(jq -r '.five_hour.used_percentage // empty' "$cache" 2>/dev/null)" \
  || unavailable "cache unparseable: $cache"
reset_ts="$(jq -r '.five_hour.resets_at // empty' "$cache" 2>/dev/null)"
captured_at="$(jq -r '.captured_at // empty' "$cache" 2>/dev/null)"

# used_percentage must be numeric (int or float).
case "$used" in
  ''|*[!0-9.]*) unavailable "no/non-numeric used_percentage" ;;
esac

# Staleness guard: never act on an ancient snapshot (a long-dead session).
case "$captured_at" in
  ''|*[!0-9]*) : ;;  # no/non-numeric captured_at → skip the age check
  *)
    age=$(( now - captured_at ))
    if [ "$age" -gt "$BUILD_QUOTA_MAX_AGE" ]; then
      unavailable "snapshot stale (${age}s > ${BUILD_QUOTA_MAX_AGE}s)"
    fi
    ;;
esac

remaining=$(awk -v u="$used" 'BEGIN { printf "%.0f", 100 - u }')

if [ "$remaining" -lt "$BUILD_QUOTA_PAUSE_PCT" ]; then
  # Low quota → pause. Compute how long to wait for the window to reset.
  case "$reset_ts" in
    ''|*[!0-9]*)
      # Low but no usable reset time: wait one buffer and let the caller re-check
      # (the cache refreshes when the session next renders the statusline).
      jq -nc --argjson rp "$remaining" --argjson ws "$BUILD_QUOTA_WAIT_BUFFER" \
        '{action:"pause", remaining_pct:$rp, reset_ts:0, wait_secs:$ws}'
      ;;
    *)
      wait_secs=$(( reset_ts - now + BUILD_QUOTA_WAIT_BUFFER ))
      [ "$wait_secs" -lt 0 ] && wait_secs=0
      jq -nc --argjson rp "$remaining" --argjson rt "$reset_ts" --argjson ws "$wait_secs" \
        '{action:"pause", remaining_pct:$rp, reset_ts:$rt, wait_secs:$ws}'
      ;;
  esac
  exit 0
fi

jq -nc --argjson rp "$remaining" '{action:"proceed", remaining_pct:$rp}'
