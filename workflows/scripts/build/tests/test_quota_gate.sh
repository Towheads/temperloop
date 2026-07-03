#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/quota-gate.sh — the build /
# sweep 5-hour-quota decision script (foundation #447).
#
# The gate is a pure function of (cache file, config, "now"): each case writes a
# fixture cache to a tmpdir, points BUILD_QUOTA_CACHE at it, pins "now" via
# the BUILD_QUOTA_NOW test seam, runs the script, and asserts on the verdict
# JSON. Zero network, zero dependency on the real ~/.claude/rate-limits.json.
#
# Covers: pause (below threshold, correct wait_secs) · proceed (above) ·
# fail-open unavailable (missing / unparseable / no-5h-window / stale cache) ·
# env override of the threshold beating the config default · the config-file
# default applying when unset · the low-but-no-reset_ts edge.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../quota-gate.sh"
NOW=1718000000

pass=0
fail=0
ok()   { echo "  ok    $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# run <cache-file> [env assignments…] → prints verdict JSON
run() {
  local cache="$1"; shift
  env "$@" BUILD_QUOTA_CACHE="$cache" BUILD_QUOTA_NOW="$NOW" bash "$GATE"
}

# Write a fixture cache. write_cache <file> <used_pct> <reset_ts> <captured_at>
write_cache() {
  printf '{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":50},"captured_at":%s}\n' \
    "$2" "$3" "$4" > "$1"
}

field() { printf '%s' "$1" | jq -r "$2"; }

# ── 1: pause — remaining 7% (used 93), reset 1h out ──────────────────────────
echo "--- test 1: below threshold → pause ---"
write_cache "$TMP/low.json" 93 "$((NOW + 3600))" "$NOW"
v=$(run "$TMP/low.json")
[ "$(field "$v" .action)" = "pause" ] && ok "action=pause" || bad "pause.action" "got $(field "$v" .action)"
[ "$(field "$v" .remaining_pct)" = "7" ] && ok "remaining_pct=7" || bad "pause.remaining" "got $(field "$v" .remaining_pct)"
# wait_secs = (reset - now) + buffer(60) = 3600 + 60
[ "$(field "$v" .wait_secs)" = "3660" ] && ok "wait_secs=3660 (reset-gap + buffer)" || bad "pause.wait_secs" "got $(field "$v" .wait_secs)"
[ "$(field "$v" .reset_ts)" = "$((NOW + 3600))" ] && ok "reset_ts echoed" || bad "pause.reset_ts" "got $(field "$v" .reset_ts)"

# ── 2: proceed — remaining 40% (used 60) ─────────────────────────────────────
echo "--- test 2: above threshold → proceed ---"
write_cache "$TMP/ok.json" 60 "$((NOW + 3600))" "$NOW"
v=$(run "$TMP/ok.json")
[ "$(field "$v" .action)" = "proceed" ] && ok "action=proceed" || bad "proceed.action" "got $(field "$v" .action)"
[ "$(field "$v" .remaining_pct)" = "40" ] && ok "remaining_pct=40" || bad "proceed.remaining" "got $(field "$v" .remaining_pct)"

# ── 3: boundary — exactly at threshold (remaining == 10) proceeds ────────────
echo "--- test 3: remaining == threshold → proceed (strict <) ---"
write_cache "$TMP/edge.json" 90 "$((NOW + 3600))" "$NOW"
v=$(run "$TMP/edge.json")
[ "$(field "$v" .action)" = "proceed" ] && ok "remaining==10 → proceed" || bad "edge.action" "got $(field "$v" .action)"

# ── 4: fail-open — missing cache ─────────────────────────────────────────────
echo "--- test 4: missing cache → unavailable (fail open) ---"
v=$(run "$TMP/does-not-exist.json")
[ "$(field "$v" .action)" = "unavailable" ] && ok "missing cache → unavailable" || bad "missing.action" "got $(field "$v" .action)"

# ── 5: fail-open — unparseable / no five_hour window ─────────────────────────
echo "--- test 5: malformed + no-5h-window → unavailable ---"
printf 'not json at all\n' > "$TMP/bad.json"
v=$(run "$TMP/bad.json")
[ "$(field "$v" .action)" = "unavailable" ] && ok "garbage cache → unavailable" || bad "garbage.action" "got $(field "$v" .action)"
printf '{"seven_day":{"used_percentage":20},"captured_at":%s}\n' "$NOW" > "$TMP/no5h.json"
v=$(run "$TMP/no5h.json")
[ "$(field "$v" .action)" = "unavailable" ] && ok "no five_hour key → unavailable" || bad "no5h.action" "got $(field "$v" .action)"

# ── 6: fail-open — stale snapshot (low, but captured 2h ago) ─────────────────
echo "--- test 6: stale snapshot → unavailable (never act on ancient low) ---"
write_cache "$TMP/stale.json" 95 "$((NOW + 3600))" "$((NOW - 7200))"
v=$(run "$TMP/stale.json")
[ "$(field "$v" .action)" = "unavailable" ] && ok "2h-old snapshot → unavailable" || bad "stale.action" "got $(field "$v" .action)"
# …but a fresh equally-low snapshot DOES pause (proves the guard is age, not value)
write_cache "$TMP/freshlow.json" 95 "$((NOW + 3600))" "$((NOW - 60))"
v=$(run "$TMP/freshlow.json")
[ "$(field "$v" .action)" = "pause" ] && ok "fresh equally-low snapshot → pause (guard is age)" || bad "freshlow.action" "got $(field "$v" .action)"

# ── 7: env override of threshold beats config default ────────────────────────
echo "--- test 7: BUILD_QUOTA_PAUSE_PCT override beats config default ---"
write_cache "$TMP/twenty.json" 80 "$((NOW + 1800))" "$NOW"   # remaining 20%
v=$(run "$TMP/twenty.json")
[ "$(field "$v" .action)" = "proceed" ] && ok "default 10 → 20% remaining proceeds" || bad "default.action" "got $(field "$v" .action)"
v=$(run "$TMP/twenty.json" BUILD_QUOTA_PAUSE_PCT=25)
[ "$(field "$v" .action)" = "pause" ] && ok "override 25 → 20% remaining pauses (env wins)" || bad "override.action" "got $(field "$v" .action)"

# ── 8: low but no reset_ts → pause with buffer-only wait (re-check loop) ──────
echo "--- test 8: low quota, missing reset_ts → pause with buffer wait ---"
printf '{"five_hour":{"used_percentage":95},"captured_at":%s}\n' "$NOW" > "$TMP/noreset.json"
v=$(run "$TMP/noreset.json")
[ "$(field "$v" .action)" = "pause" ] && ok "no reset_ts but low → pause" || bad "noreset.action" "got $(field "$v" .action)"
[ "$(field "$v" .wait_secs)" = "60" ] && ok "wait_secs falls back to buffer (60)" || bad "noreset.wait" "got $(field "$v" .wait_secs)"

# ── 9: wait_secs floors at 0 when reset already passed ───────────────────────
echo "--- test 9: reset already passed → wait_secs >= 0 (no negative) ---"
write_cache "$TMP/past.json" 95 "$((NOW - 100))" "$NOW"
v=$(run "$TMP/past.json")
ws=$(field "$v" .wait_secs)
[ "$(field "$v" .action)" = "pause" ] && [ "$ws" -ge 0 ] && ok "past-reset → pause, wait_secs=$ws (≥0)" || bad "past.action" "action=$(field "$v" .action) wait_secs=$ws"

echo "---"
echo "test_quota_gate: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || { echo "test_quota_gate: FAIL"; exit 1; }
echo "test_quota_gate: OK"
