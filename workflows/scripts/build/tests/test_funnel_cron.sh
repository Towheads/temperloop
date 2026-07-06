#!/usr/bin/env bash
#
# Tests for the autonomous funnel driver's CRON layer (foundation #596):
#   funnel-schedule-gate.sh — the operator-editable, fail-closed schedule gate.
#   funnel-cron.sh          — the gate → tick(emit) → log/notify wrapper.
#
# Like test_funnel_tick.sh, these run entirely OFFLINE: the gate's hour and
# schedule-file are injected (FUNNEL_NOW_HOUR / FUNNEL_SCHEDULE_FILE) so there is
# no clock dependency, and the wrapper drives the tick via its --dry-run
# --fixture pass-through so no `gh`/board/network call is ever made. Notification
# is stubbed (FUNNEL_NOTIFY_CMD) so nothing is actually displayed.
#
# Covers the #596 acceptance bullets:
#   GATE: hour in/out of list · enabled:no kill switch · missing-file fail-closed
#         · malformed fail-closed (no block / bad token) · boards: override
#         · injected-hour determinism.
#   WRAPPER: skip → exit 0, zero tick, skip log line · run → tick emits, day-jsonl
#            + latest.json written · notify ONLY on a non-no-op run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../funnel-schedule-gate.sh"
CRON="$HERE/../funnel-cron.sh"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Redirect the L0 raw lake (#639) to a temp dir for EVERY cron invocation below, so
# tests never append to the real meta/data/raw/ in the repo. Exported (not -i'd in the
# env … bash calls), so it is inherited by all of them.
export FUNNEL_RAW_DIR="$TMP/raw"

# write_sched <path> <body…> — write a fenced funnel-schedule block to a file.
sched_file() { local f="$1"; shift; printf '%s\n' "$@" > "$f"; }

# Run the gate; capture verdict JSON + exit code into globals VOUT / VRC.
run_gate() { VOUT="$("$@" 2>/dev/null)" && VRC=0 || VRC=$?; }

# ── GATE 1: enabled + current hour in the list → run (exit 0) ────────────────
echo "--- gate 1: enabled + hour in list → run ---"
F="$TMP/sched1.md"
printf '%s\n' '# funnel schedule' '' '```funnel-schedule' 'enabled: yes' 'hours: 9 14 20' '```' > "$F"
run_gate env FUNNEL_NOW_HOUR=14 FUNNEL_SCHEDULE_FILE="$F" bash "$GATE"
[ "$VRC" -eq 0 ] && ok "exit 0 on a scheduled hour" || bad "g1.rc" "exit=$VRC ($VOUT)"
[ "$(jq -r '.action' <<<"$VOUT")" = "run" ] && ok "verdict action=run" || bad "g1.action" "got $(jq -r '.action' <<<"$VOUT")"
[ "$(jq -r '.hour' <<<"$VOUT")" = "14" ] && ok "verdict carries the injected hour" || bad "g1.hour" "got $(jq -r '.hour' <<<"$VOUT")"

# ── GATE 2: enabled but current hour NOT in the list → skip (exit 1) ─────────
echo "--- gate 2: enabled but hour out of list → skip ---"
run_gate env FUNNEL_NOW_HOUR=15 FUNNEL_SCHEDULE_FILE="$F" bash "$GATE"
[ "$VRC" -eq 1 ] && ok "exit 1 on an unscheduled hour" || bad "g2.rc" "exit=$VRC ($VOUT)"
[ "$(jq -r '.action' <<<"$VOUT")" = "skip" ] && ok "verdict action=skip" || bad "g2.action" "got $(jq -r '.action' <<<"$VOUT")"

# ── GATE 3: injected-hour determinism — every listed hour runs, all others skip ─
echo "--- gate 3: injected-hour determinism across 0–23 ---"
det_ok=1
for h in $(seq 0 23); do
  run_gate env FUNNEL_NOW_HOUR="$h" FUNNEL_SCHEDULE_FILE="$F" bash "$GATE"
  case " 9 14 20 " in
    *" $h "*) [ "$VRC" -eq 0 ] || { det_ok=0; echo "    hour $h expected run, got exit $VRC"; } ;;
    *)        [ "$VRC" -eq 1 ] || { det_ok=0; echo "    hour $h expected skip, got exit $VRC"; } ;;
  esac
done
[ "$det_ok" -eq 1 ] && ok "all 24 hours map deterministically to run/skip" || bad "g3.det" "a mismatch above"

# ── GATE 4: enabled: no → skip (the kill switch) ────────────────────────────
echo "--- gate 4: enabled: no → skip (kill switch) ---"
F2="$TMP/sched_off.md"
printf '%s\n' '```funnel-schedule' 'enabled: no' 'hours: 9 14 20' '```' > "$F2"
run_gate env FUNNEL_NOW_HOUR=14 FUNNEL_SCHEDULE_FILE="$F2" bash "$GATE"
[ "$VRC" -eq 1 ] && ok "enabled:no skips even on a listed hour" || bad "g4.rc" "exit=$VRC ($VOUT)"
jq -e '.reason | test("kill switch")' <<<"$VOUT" >/dev/null && ok "skip reason names the kill switch" || bad "g4.reason" "$(jq -r '.reason' <<<"$VOUT")"

# ── GATE 5: missing file → fail-closed skip ─────────────────────────────────
echo "--- gate 5: missing file → fail-closed skip ---"
run_gate env FUNNEL_NOW_HOUR=14 FUNNEL_SCHEDULE_FILE="$TMP/does-not-exist.md" bash "$GATE"
[ "$VRC" -eq 1 ] && ok "missing file → exit 1 (fail-closed, never runs)" || bad "g5.rc" "exit=$VRC ($VOUT)"
[ "$(jq -r '.action' <<<"$VOUT")" = "skip" ] && ok "missing file → action=skip" || bad "g5.action" "got $(jq -r '.action' <<<"$VOUT")"

# ── GATE 6: malformed — no fenced block → fail-closed skip ──────────────────
echo "--- gate 6: no funnel-schedule block → fail-closed skip ---"
F3="$TMP/no_block.md"
printf '%s\n' '# just prose, no machine block' 'enabled: yes' 'hours: 14' > "$F3"
run_gate env FUNNEL_NOW_HOUR=14 FUNNEL_SCHEDULE_FILE="$F3" bash "$GATE"
[ "$VRC" -eq 1 ] && ok "no block → exit 1 (bare key: lines outside a fence don't count)" || bad "g6.rc" "exit=$VRC ($VOUT)"

# ── GATE 7: malformed — bad hours token → fail-closed skip ──────────────────
echo "--- gate 7: non-integer hours token → fail-closed skip ---"
F4="$TMP/bad_hours.md"
printf '%s\n' '```funnel-schedule' 'enabled: yes' 'hours: 9 noon 20' '```' > "$F4"
run_gate env FUNNEL_NOW_HOUR=9 FUNNEL_SCHEDULE_FILE="$F4" bash "$GATE"
[ "$VRC" -eq 1 ] && ok "a bad token poisons the list → skip (strict, fail-closed)" || bad "g7.rc" "exit=$VRC ($VOUT)"
# Out-of-range too.
F5="$TMP/oor_hours.md"
printf '%s\n' '```funnel-schedule' 'enabled: yes' 'hours: 9 26' '```' > "$F5"
run_gate env FUNNEL_NOW_HOUR=9 FUNNEL_SCHEDULE_FILE="$F5" bash "$GATE"
[ "$VRC" -eq 1 ] && ok "out-of-range hour (26) → skip" || bad "g7.oor" "exit=$VRC ($VOUT)"

# ── GATE 8: optional boards: override surfaced in the verdict ────────────────
echo "--- gate 8: boards: override surfaced in run verdict ---"
F6="$TMP/boards.md"
printf '%s\n' '```funnel-schedule' 'enabled: yes' 'hours: 14' 'boards: 3 4' '```' > "$F6"
run_gate env FUNNEL_NOW_HOUR=14 FUNNEL_SCHEDULE_FILE="$F6" bash "$GATE"
[ "$VRC" -eq 0 ] && ok "boards override still runs on a listed hour" || bad "g8.rc" "exit=$VRC ($VOUT)"
[ "$(jq -r '.boards' <<<"$VOUT")" = "3 4" ] && ok "verdict carries boards override '3 4'" || bad "g8.boards" "got $(jq -r '.boards' <<<"$VOUT")"
# No boards: → empty string (wrapper falls back to FUNNEL_ENABLED_BOARDS).
run_gate env FUNNEL_NOW_HOUR=14 FUNNEL_SCHEDULE_FILE="$F" bash "$GATE"
[ "$(jq -r '.boards' <<<"$VOUT")" = "" ] && ok "no boards: → empty boards (wrapper default)" || bad "g8.empty" "got '$(jq -r '.boards' <<<"$VOUT")'"

# ── GATE 9: optional cap: override surfaced in the verdict (#642) ─────────────
# UNLIKE hours:/boards:, a malformed cap does NOT fail closed (it is a throughput
# knob, not a spend gate): it is dropped to empty + a stderr note, and the hour
# still RUNS. The wrapper then falls back to the FUNNEL_DRIVE_CAP code default.
echo "--- gate 9: cap: override surfaced; malformed cap runs (not fail-closed) (#642) ---"
F7="$TMP/cap.md"
printf '%s\n' '```funnel-schedule' 'enabled: yes' 'hours: 14' 'cap: 3' '```' > "$F7"
run_gate env FUNNEL_NOW_HOUR=14 FUNNEL_SCHEDULE_FILE="$F7" bash "$GATE"
[ "$VRC" -eq 0 ] && ok "cap override still runs on a listed hour" || bad "g9.rc" "exit=$VRC ($VOUT)"
[ "$(jq -r '.cap' <<<"$VOUT")" = "3" ] && ok "verdict carries cap override '3'" || bad "g9.cap" "got $(jq -r '.cap' <<<"$VOUT")"
# No cap: → empty string (wrapper falls back to FUNNEL_DRIVE_CAP).
run_gate env FUNNEL_NOW_HOUR=14 FUNNEL_SCHEDULE_FILE="$F" bash "$GATE"
[ "$(jq -r '.cap' <<<"$VOUT")" = "" ] && ok "no cap: → empty cap (wrapper default)" || bad "g9.empty" "got '$(jq -r '.cap' <<<"$VOUT")'"
# Malformed cap (non-integer) → dropped to empty, but the hour STILL RUNS.
F8="$TMP/cap-bad.md"
printf '%s\n' '```funnel-schedule' 'enabled: yes' 'hours: 14' 'cap: lots' '```' > "$F8"
run_gate env FUNNEL_NOW_HOUR=14 FUNNEL_SCHEDULE_FILE="$F8" bash "$GATE"
[ "$VRC" -eq 0 ] && ok "non-integer cap still runs (cap is not a spend gate)" || bad "g9.badrc" "exit=$VRC ($VOUT)"
[ "$(jq -r '.cap' <<<"$VOUT")" = "" ] && ok "non-integer cap dropped to empty (code default)" || bad "g9.badcap" "got $(jq -r '.cap' <<<"$VOUT")"
# cap: 0 (< 1) → dropped to empty, hour still runs.
F9="$TMP/cap-zero.md"
printf '%s\n' '```funnel-schedule' 'enabled: yes' 'hours: 14' 'cap: 0' '```' > "$F9"
run_gate env FUNNEL_NOW_HOUR=14 FUNNEL_SCHEDULE_FILE="$F9" bash "$GATE"
[ "$VRC" -eq 0 ] && [ "$(jq -r '.cap' <<<"$VOUT")" = "" ] && ok "cap: 0 (<1) dropped to empty, still runs" || bad "g9.zero" "rc=$VRC cap=$(jq -r '.cap' <<<"$VOUT")"

# ── Wrapper fixtures: a Ready item to drive + a notify stub ──────────────────
mk_fixture() { local fx="$1"; mkdir -p "$fx/board-3"
  printf '%s\n' '[{"number":101,"title":"fix venue parser","labels":["Operational"]}]' > "$fx/board-3/ready.json"; }
# notify stub: writes the summary it receives to a sentinel file.
NOTIFY="$TMP/notify.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$1" > "$NOTIFY_SENTINEL"' > "$NOTIFY"
chmod +x "$NOTIFY"

# ── WRAPPER 1: run verdict → tick emits, log + latest written, notify fires ──
echo "--- wrapper 1: run → tick emits, logs written, notify fires ---"
FX="$TMP/wfx1"; mk_fixture "$FX"
LOGD="$TMP/wlog1"; SENT="$TMP/notify1.txt"
OUT="$(env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_NOW_TS=2026-06-25T14:00:00Z FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$LOGD" FUNNEL_NOTIFY_CMD="$NOTIFY" NOTIFY_SENTINEL="$SENT" \
  bash "$CRON" --dry-run --fixture "$FX")"
RC=$?
[ "$RC" -eq 0 ] && ok "wrapper exits 0 on a run" || bad "w1.rc" "exit=$RC"
[ "$(jq -r '.event' <<<"$OUT")" = "ran" ] && ok "stdout event=ran" || bad "w1.event" "got $(jq -r '.event' <<<"$OUT")"
[ -f "$LOGD/2026-06-25.jsonl" ] && ok "day jsonl log written" || bad "w1.jsonl" "no $LOGD/2026-06-25.jsonl"
[ -f "$LOGD/latest.json" ] && ok "latest.json written" || bad "w1.latest" "no latest.json"
jq -e '.event=="ran" and (.plans[0].actions[0].action=="drive-ready")' "$LOGD/latest.json" >/dev/null \
  && ok "logged plan carries the emitted drive-ready (tick ran via the wrapper)" || bad "w1.plan" "$(cat "$LOGD/latest.json")"
[ "$(jq -r '.nonop_actions' "$LOGD/latest.json")" = "1" ] && ok "nonop_actions=1 recorded" || bad "w1.nonop" "got $(jq -r '.nonop_actions' "$LOGD/latest.json")"
# #663: every record carries the pinned per-tick ts (here on a 'ran' record).
[ "$(jq -r '.ts' "$LOGD/latest.json")" = "2026-06-25T14:00:00Z" ] && ok "ran record carries pinned ts (#663)" || bad "w1.ts" "got $(jq -r '.ts' "$LOGD/latest.json")"
[ "$(jq -r '.ts' "$LOGD/2026-06-25.jsonl")" = "2026-06-25T14:00:00Z" ] && ok "day jsonl record carries ts (#663)" || bad "w1.ts-jsonl" "got $(jq -r '.ts' "$LOGD/2026-06-25.jsonl")"
[ -f "$SENT" ] && ok "notify fired on the non-no-op run" || bad "w1.notify" "notify sentinel absent"
grep -q "funnel:" "$SENT" 2>/dev/null && ok "notify received the run summary" || bad "w1.notify-body" "$(cat "$SENT" 2>/dev/null)"

# ── WRAPPER 2: skip verdict → exit 0, ZERO tick, skip log line, no notify ────
echo "--- wrapper 2: skip → exit 0, zero tick, skip logged, no notify ---"
FX2="$TMP/wfx2"; mk_fixture "$FX2"
LOGD2="$TMP/wlog2"; SENT2="$TMP/notify2.txt"
OUT2="$(env FUNNEL_NOW_HOUR=3 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_NOW_TS=2026-06-25T03:00:00Z FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$LOGD2" FUNNEL_NOTIFY_CMD="$NOTIFY" NOTIFY_SENTINEL="$SENT2" \
  bash "$CRON" --dry-run --fixture "$FX2")"
RC2=$?
[ "$RC2" -eq 0 ] && ok "wrapper exits 0 on a skip" || bad "w2.rc" "exit=$RC2"
[ "$(jq -r '.event' <<<"$OUT2")" = "skipped" ] && ok "stdout event=skipped" || bad "w2.event" "got $(jq -r '.event' <<<"$OUT2")"
# Zero tick ⇒ the logged record has NO plans key with drive actions; event=skipped.
jq -e '.event=="skipped" and (has("plans")|not)' "$LOGD2/latest.json" >/dev/null \
  && ok "skip record has no plans (tick never ran — zero gh calls)" || bad "w2.noplan" "$(cat "$LOGD2/latest.json")"
jq -e '.reason | test("not in scheduled hours")' "$LOGD2/latest.json" >/dev/null \
  && ok "skip record carries the gate reason" || bad "w2.reason" "$(jq -r '.reason' "$LOGD2/latest.json")"
# #663: the 'skipped' record type also flows through emit_record → carries ts.
[ "$(jq -r '.ts' "$LOGD2/latest.json")" = "2026-06-25T03:00:00Z" ] && ok "skip record carries pinned ts (#663)" || bad "w2.ts" "got $(jq -r '.ts' "$LOGD2/latest.json")"
[ ! -f "$SENT2" ] && ok "no notify on a skip" || bad "w2.notify" "notify fired on a skip"

# ── WRAPPER 3: a no-op run (no Ready work) does NOT notify ───────────────────
echo "--- wrapper 3: no-op run does not notify ---"
FX3="$TMP/wfx3"; mkdir -p "$FX3/board-3"
printf '%s\n' '[]' > "$FX3/board-3/ready.json"   # nothing ready → tick is a no-op
LOGD3="$TMP/wlog3"; SENT3="$TMP/notify3.txt"
OUT3="$(env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$LOGD3" FUNNEL_NOTIFY_CMD="$NOTIFY" NOTIFY_SENTINEL="$SENT3" \
  bash "$CRON" --dry-run --fixture "$FX3")"
[ "$(jq -r '.event' <<<"$OUT3")" = "ran" ] && ok "no-op still logs a ran event" || bad "w3.event" "got $(jq -r '.event' <<<"$OUT3")"
[ "$(jq -r '.nonop_actions' "$LOGD3/latest.json")" = "0" ] && ok "nonop_actions=0 on a no-op tick" || bad "w3.nonop" "got $(jq -r '.nonop_actions' "$LOGD3/latest.json")"
[ ! -f "$SENT3" ] && ok "no notify on a no-op run (nothing to surface)" || bad "w3.notify" "notify fired on a no-op"

# ── WRAPPER 4: schedule boards: override scopes the tick ─────────────────────
echo "--- wrapper 4: schedule boards: override scopes the tick ---"
# Schedule names board 4; fixture provides board-4 Ready work. The wrapper must
# tick board 4 (the override), not the default FUNNEL_ENABLED_BOARDS (=3).
FX4="$TMP/wfx4"; mkdir -p "$FX4/board-4"
printf '%s\n' '[{"number":701,"title":"foundation chore","labels":["Operational"]}]' > "$FX4/board-4/ready.json"
F4b="$TMP/sched_b4.md"
printf '%s\n' '```funnel-schedule' 'enabled: yes' 'hours: 14' 'boards: 4' '```' > "$F4b"
LOGD4="$TMP/wlog4"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F4b" \
  FUNNEL_ENABLED_BOARDS="3 4" FUNNEL_LOG_DIR="$LOGD4" FUNNEL_NOTIFY_CMD="true" \
  bash "$CRON" --dry-run --fixture "$FX4" >/dev/null
[ "$(jq -r '.boards|join(" ")' "$LOGD4/latest.json")" = "4" ] \
  && ok "tick scoped to the schedule's boards override (4, not 3)" || bad "w4.boards" "got $(jq -r '.boards|join(" ")' "$LOGD4/latest.json")"
[ "$(jq -r 'first(.plans[].actions[]|select(.action=="drive-ready")|.issue)' "$LOGD4/latest.json")" = "701" ] \
  && ok "drove board-4 Ready #701 under the override" || bad "w4.drive" "$(cat "$LOGD4/latest.json")"

# ── SELF-UPDATE (#598) ────────────────────────────────────────────────────────
# These exercise Step 0 of the wrapper: the opt-in fetch+reset+re-exec preamble.
# All offline — the "remote" is a local bare repo on disk, so there is still no
# network. The wrapper's tick path stays --dry-run --fixture as above.

# mk_behind_repo <dir> — create a git repo <dir> tracking a local bare origin whose
# main is ONE commit AHEAD: marker=v2 on origin, marker=v1 checked out. A
# fetch+reset to origin/main therefore moves <dir> forward (v1→v2).
mk_behind_repo() {
  local work="$1" rem="$1.remote"
  git init --bare --quiet "$rem"
  git -c init.defaultBranch=main clone --quiet "$rem" "$work" 2>/dev/null
  git -C "$work" config user.email t@t.test; git -C "$work" config user.name tester
  git -C "$work" checkout --quiet -B main
  printf 'v1\n' > "$work/marker"; git -C "$work" add marker; git -C "$work" commit --quiet -m c1
  git -C "$work" push --quiet -u origin main
  printf 'v2\n' > "$work/marker"; git -C "$work" commit --quiet -am c2
  git -C "$work" push --quiet origin main
  git -C "$work" reset --quiet --hard HEAD~1   # back to v1 → now BEHIND origin/main
}

# A schedule that runs at hour 14 (reuse $F from the gate tests above), and a
# fixture with one Ready item so the tick is a non-no-op (proves the re-exec'd
# process reaches the gate/tick, not just that it returned).
FXS="$TMP/sufx"; mk_fixture "$FXS"

# ── SU 1: default OFF → no self-mutation of any checkout ─────────────────────
echo "--- self-update 1: default OFF → checkout untouched ---"
R1="$TMP/su_off"; mk_behind_repo "$R1"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$TMP/sulog1" FUNNEL_NOTIFY_CMD="true" FOUNDATION="$R1" \
  bash "$CRON" --dry-run --fixture "$FXS" >/dev/null 2>&1
[ "$(cat "$R1/marker")" = "v1" ] && ok "default off: marker stays v1 (no fetch/reset)" || bad "su1.marker" "got $(cat "$R1/marker")"

# ── SU 2: ON + behind → fetch+reset to origin/main, re-exec, run completes ────
echo "--- self-update 2: ON → updates checkout, re-execs, tick runs ---"
R2="$TMP/su_on"; mk_behind_repo "$R2"
SU2OUT="$(env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$TMP/sulog2" FUNNEL_NOTIFY_CMD="true" \
  FUNNEL_CRON_SELF_UPDATE=1 FOUNDATION="$R2" \
  bash "$CRON" --dry-run --fixture "$FXS" 2>/dev/null)"
[ "$(cat "$R2/marker")" = "v2" ] && ok "on: checkout hard-reset to origin/main (v1→v2)" || bad "su2.marker" "got $(cat "$R2/marker")"
[ "$(jq -r '.event' <<<"$SU2OUT")" = "ran" ] && ok "re-exec'd process completed the tick (event=ran)" || bad "su2.event" "got $(jq -r '.event' <<<"$SU2OUT")"

# ── SU 3: re-exec guard terminates (no infinite loop) ────────────────────────
# With FUNNEL_CRON_SELF_UPDATED already set, the preamble must NOT fetch/reset/
# re-exec — it falls straight through to the gate. The repo is behind, so if the
# guard were ignored it would update (marker→v2); the guard means it stays v1. And
# the run RETURNS (a loop would hang the test), proving termination.
echo "--- self-update 3: re-exec guard → no second update, terminates ---"
R3="$TMP/su_guard"; mk_behind_repo "$R3"
SU3OUT="$(env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$TMP/sulog3" FUNNEL_NOTIFY_CMD="true" \
  FUNNEL_CRON_SELF_UPDATE=1 FUNNEL_CRON_SELF_UPDATED=1 FOUNDATION="$R3" \
  bash "$CRON" --dry-run --fixture "$FXS" 2>/dev/null)"
[ "$(cat "$R3/marker")" = "v1" ] && ok "guard set: no second fetch/reset (marker stays v1)" || bad "su3.marker" "got $(cat "$R3/marker")"
[ "$(jq -r '.event' <<<"$SU3OUT")" = "ran" ] && ok "guarded run terminates and ticks (no re-exec loop)" || bad "su3.event" "got $(jq -r '.event' <<<"$SU3OUT")"

# ── SU 4: fetch failure → fail-safe, proceed on current checkout ─────────────
# origin points at a path that does not exist → `git fetch` fails. The wrapper
# must log the failure and PROCEED (not skip): the tick still runs, and the
# checkout is left at its pre-fetch commit (no half-update).
echo "--- self-update 4: fetch failure → fail-safe proceed ---"
R4="$TMP/su_fail"
git init --quiet "$R4"; git -C "$R4" symbolic-ref HEAD refs/heads/main
git -C "$R4" config user.email t@t.test; git -C "$R4" config user.name tester
printf 'v1\n' > "$R4/marker"; git -C "$R4" add marker; git -C "$R4" commit --quiet -m c1
git -C "$R4" remote add origin "$TMP/no-such-remote.git"
SU4ERR="$TMP/su4.err"
SU4OUT="$(env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$TMP/sulog4" FUNNEL_NOTIFY_CMD="true" \
  FUNNEL_CRON_SELF_UPDATE=1 FOUNDATION="$R4" \
  bash "$CRON" --dry-run --fixture "$FXS" 2>"$SU4ERR")"
[ "$(jq -r '.event' <<<"$SU4OUT")" = "ran" ] && ok "fetch failure: tick still runs (fail-safe, not skipped)" || bad "su4.event" "got $(jq -r '.event' <<<"$SU4OUT")"
[ "$(cat "$R4/marker")" = "v1" ] && ok "fetch failure: checkout left untouched (no half-update)" || bad "su4.marker" "got $(cat "$R4/marker")"
# stderr also carries git's plain-text "fatal:" lines, so filter to JSON before jq.
grep -h '"event":"self-update"' "$SU4ERR" | jq -e 'select(.status=="failed")' >/dev/null 2>&1 \
  && ok "fetch failure logged a self-update:failed record to stderr" || bad "su4.log" "$(cat "$SU4ERR")"

# ── OPERATOR SELF-PROVISION (foundation #1011) ───────────────────────────────
# On an isolated cron checkout the gitignored build.config.local.sh does not
# propagate, so FUNNEL_OPERATOR stays the placeholder and routing silently no-ops.
# The wrapper self-heals: placeholder + resolvable login → write build.config.local.sh
# (chmod 600) + export for this tick; placeholder + unresolvable → ONE loud config-gap
# escalation. All runs below use an UNSCHEDULED hour so the gate skips (exit 0) BEFORE
# any tick/gh — provisioning runs earlier (Step 0.6), so a skip still exercises it.
PSCHED="$TMP/prov-sched.md"
printf '%s\n' '# funnel schedule' '' '```funnel-schedule' 'enabled: yes' 'hours: 14' '```' > "$PSCHED"
# resolver stub: prints a fixed login (mirrors `gh api user --jq .login`).
PRESOLVE="$TMP/resolve-login.sh"
printf '#!/usr/bin/env bash\necho provisioned-login\n' > "$PRESOLVE"; chmod +x "$PRESOLVE"
# resolver stub that FAILS (empty output, non-zero) — models gh unavailable/unauthed.
PRESOLVE_FAIL="$TMP/resolve-fail.sh"
printf '#!/usr/bin/env bash\nexit 3\n' > "$PRESOLVE_FAIL"; chmod +x "$PRESOLVE_FAIL"

# PROV 1: placeholder + resolvable → provisions the file + exports + emits event.
echo "--- provision 1: placeholder + resolvable login → self-provision ---"
mkdir -p "$TMP/prov1"; P1LOCAL="$TMP/prov1/build.config.local.sh"; P1ERR="$TMP/prov1.err"
env FUNNEL_NOW_HOUR=3 FUNNEL_SCHEDULE_FILE="$PSCHED" FUNNEL_LOG_DIR="$TMP/provlog1" \
  FUNNEL_NOTIFY_CMD="true" FUNNEL_OPERATOR_RESOLVE_BIN="$PRESOLVE" BUILD_CONFIG_LOCAL="$P1LOCAL" \
  bash "$CRON" >/dev/null 2>"$P1ERR" || true
grep -h '"event":"operator-provisioned"' "$P1ERR" | jq -e '.operator=="@provisioned-login"' >/dev/null 2>&1 \
  && ok "placeholder → emits operator-provisioned with the resolved @login" || bad "prov1.event" "$(cat "$P1ERR")"
[ -f "$P1LOCAL" ] && grep -q 'export FUNNEL_OPERATOR="@provisioned-login"' "$P1LOCAL" \
  && ok "wrote build.config.local.sh with the real operator export" || bad "prov1.file" "$(cat "$P1LOCAL" 2>/dev/null || echo MISSING)"
# Portable mode read: GNU `stat -c` FIRST, BSD `stat -f` fallback (GNU's -f is a
# different flag — --file-system — that does NOT error, so BSD-first misreads on Linux).
[ "$(stat -c '%a' "$P1LOCAL" 2>/dev/null || stat -f '%Lp' "$P1LOCAL" 2>/dev/null)" = "600" ] \
  && ok "provisioned file is chmod 600" || bad "prov1.mode" "$(stat -f '%Lp' "$P1LOCAL" 2>/dev/null)"

# PROV 2: placeholder + UNRESOLVABLE → ONE loud config-gap event, NO file written.
echo "--- provision 2: placeholder + unresolvable → loud config-gap, no file ---"
mkdir -p "$TMP/prov2"; P2LOCAL="$TMP/prov2/build.config.local.sh"; P2ERR="$TMP/prov2.err"
env FUNNEL_NOW_HOUR=3 FUNNEL_SCHEDULE_FILE="$PSCHED" FUNNEL_LOG_DIR="$TMP/provlog2" \
  FUNNEL_NOTIFY_CMD="true" FUNNEL_OPERATOR_RESOLVE_BIN="$PRESOLVE_FAIL" BUILD_CONFIG_LOCAL="$P2LOCAL" \
  bash "$CRON" >/dev/null 2>"$P2ERR" || true
[ "$(grep -hc '"event":"config-gap"' "$P2ERR")" = "1" ] \
  && ok "unresolvable → exactly ONE config-gap escalation (not a silent no-op)" || bad "prov2.gap" "$(cat "$P2ERR")"
[ ! -f "$P2LOCAL" ] && ok "unresolvable → no build.config.local.sh written" || bad "prov2.file" "unexpected file $(cat "$P2LOCAL")"

# PROV 3: operator ALREADY real → no provisioning (idempotent no-op), no file, no event.
echo "--- provision 3: operator already set → no-op (idempotent) ---"
mkdir -p "$TMP/prov3"; P3LOCAL="$TMP/prov3/build.config.local.sh"; P3ERR="$TMP/prov3.err"
env FUNNEL_NOW_HOUR=3 FUNNEL_SCHEDULE_FILE="$PSCHED" FUNNEL_LOG_DIR="$TMP/provlog3" \
  FUNNEL_NOTIFY_CMD="true" FUNNEL_OPERATOR="@realops" FUNNEL_OPERATOR_RESOLVE_BIN="$PRESOLVE" \
  BUILD_CONFIG_LOCAL="$P3LOCAL" bash "$CRON" >/dev/null 2>"$P3ERR" || true
{ ! grep -q '"event":"operator-provisioned"' "$P3ERR" && ! grep -q '"event":"config-gap"' "$P3ERR"; } \
  && ok "real operator → no provisioning event" || bad "prov3.event" "$(cat "$P3ERR")"
[ ! -f "$P3LOCAL" ] && ok "real operator → no file written (no-op)" || bad "prov3.file" "unexpected file"

# PROV 4: --dry-run NEVER provisions, even with the placeholder (live side-effect only).
echo "--- provision 4: --dry-run → never provisions (offline invariant) ---"
mkdir -p "$TMP/prov4"; P4LOCAL="$TMP/prov4/build.config.local.sh"; P4ERR="$TMP/prov4.err"
env FUNNEL_NOW_HOUR=3 FUNNEL_SCHEDULE_FILE="$PSCHED" FUNNEL_LOG_DIR="$TMP/provlog4" \
  FUNNEL_NOTIFY_CMD="true" FUNNEL_OPERATOR_RESOLVE_BIN="$PRESOLVE" BUILD_CONFIG_LOCAL="$P4LOCAL" \
  bash "$CRON" --dry-run --fixture "$FXS" >/dev/null 2>"$P4ERR" || true
{ [ ! -f "$P4LOCAL" ] && ! grep -q '"event":"operator-provisioned"' "$P4ERR"; } \
  && ok "--dry-run: no provisioning file or event" || bad "prov4" "file=$([ -f "$P4LOCAL" ] && echo yes) $(cat "$P4ERR")"

# ── RUNG-5b drive step (#604) ────────────────────────────────────────────────
# Step 4 is OPT-IN (FUNNEL_DRIVE). A cron --dry-run passes --dry-run THROUGH to
# funnel-drive.sh, so these stay offline — no claude is ever spawned. A marker
# double proves it: if Step 4 ever invoked claude, the marker file would appear.
DRIVE_DOUBLE="$TMP/claude-marker.sh"
printf '%s\n' '#!/usr/bin/env bash' 'touch "$DRIVE_MARK"' 'echo "{}"' > "$DRIVE_DOUBLE"
chmod +x "$DRIVE_DOUBLE"

# ── WRAPPER 5: FUNNEL_DRIVE unset → Step 4 skipped (byte-for-byte 5a) ─────────
echo "--- wrapper 5: FUNNEL_DRIVE off → no drive step, stdout drive=off ---"
FX5="$TMP/wfx5"; mk_fixture "$FX5"
LOGD5="$TMP/wlog5"; MARK5="$TMP/mark5"
OUT5="$(env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$LOGD5" FUNNEL_NOTIFY_CMD="true" \
  CLAUDE_BIN="$DRIVE_DOUBLE" DRIVE_MARK="$MARK5" \
  bash "$CRON" --dry-run --fixture "$FX5")"
[ "$(jq -r '.drive' <<<"$OUT5")" = "off" ] && ok "drive=off when FUNNEL_DRIVE unset" || bad "w5.drive" "got $(jq -r '.drive' <<<"$OUT5")"
[ ! -f "$MARK5" ] && ok "no claude spawned with the flag off" || bad "w5.spawn" "claude ran with FUNNEL_DRIVE off"
# No drive record in the day log — only the ran record.
if ! grep -q '"event":"drive"' "$LOGD5/2026-06-25.jsonl" 2>/dev/null; then
  ok "no drive record logged (Step 4 skipped)"
else
  bad "w5.rec" "a drive record was logged with the flag off"
fi

# ── WRAPPER 6: FUNNEL_DRIVE=1 + spike Ready → drive record, spike in safe[] ───
echo "--- wrapper 6: FUNNEL_DRIVE=1 (dry-run) → drive record, spike driven, no spawn ---"
FX6="$TMP/wfx6"; mkdir -p "$FX6/board-3"
printf '%s\n' '[{"number":102,"title":"investigate seam","labels":["spike","Operational"]}]' > "$FX6/board-3/ready.json"
LOGD6="$TMP/wlog6"; MARK6="$TMP/mark6"
OUT6="$(env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$LOGD6" FUNNEL_NOTIFY_CMD="true" \
  FUNNEL_DRIVE=1 CLAUDE_BIN="$DRIVE_DOUBLE" DRIVE_MARK="$MARK6" \
  bash "$CRON" --dry-run --fixture "$FX6")"
[ "$(jq -r '.drive' <<<"$OUT6")" = "dry-run" ] && ok "drive=dry-run (Step 4 ran, no spawn under cron --dry-run)" || bad "w6.drive" "got $(jq -r '.drive' <<<"$OUT6")"
[ ! -f "$MARK6" ] && ok "cron --dry-run passes --dry-run through → no claude spawn" || bad "w6.spawn" "claude ran under cron --dry-run"
# latest.json is the drive record (emitted after the ran record).
jq -e '.event=="drive"' "$LOGD6/latest.json" >/dev/null \
  && ok "drive record persisted (event=drive)" || bad "w6.rec" "$(cat "$LOGD6/latest.json")"
jq -e '.safe | any(.action=="drive-ready" and .issue==102 and .kind=="spike")' "$LOGD6/latest.json" >/dev/null \
  && ok "the spike (#102) is in the driven safe tier" || bad "w6.safe" "$(jq -c '.safe' "$LOGD6/latest.json")"

# ── WRAPPER 7: FUNNEL_DRIVE=1 + code Ready → code left in merge[], not driven ─
echo "--- wrapper 7: FUNNEL_DRIVE=1 + code item → left for manual (merge[], status empty) ---"
FX7="$TMP/wfx7"; mk_fixture "$FX7"   # #101 is a plain Operational (code) item
LOGD7="$TMP/wlog7"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$LOGD7" FUNNEL_NOTIFY_CMD="true" \
  FUNNEL_DRIVE=1 CLAUDE_BIN="$DRIVE_DOUBLE" DRIVE_MARK="$TMP/mark7" \
  bash "$CRON" --dry-run --fixture "$FX7" >/dev/null
jq -e '.event=="drive" and .status=="empty"' "$LOGD7/latest.json" >/dev/null \
  && ok "code item → nothing safe to drive (status=empty)" || bad "w7.status" "$(cat "$LOGD7/latest.json")"
jq -e '.merge | any(.action=="drive-ready" and .issue==101)' "$LOGD7/latest.json" >/dev/null \
  && ok "the code drive (#101) is reported in merge[] for the operator" || bad "w7.merge" "$(jq -c '.merge' "$LOGD7/latest.json")"

# ── WRAPPER 8: drive-branch empty-array is bash-3.2 safe (#612 regression) ────
# The first live rung-5b drive crashed: `funnel-cron.sh: drive_dry[@]: unbound
# variable`. Cause — the plist invokes macOS /bin/bash (3.2), where expanding an
# EMPTY array with "${drive_dry[@]}" under `set -u` is an unbound-variable error
# (fixed in bash 4.4+). drive_dry is empty on the LIVE (non-dry-run) drive path,
# so the bug only fires once FUNNEL_DRIVE=1 actually drives — never in the
# --dry-run wrappers above. The full non-dry-run path can't be exercised offline
# (the cron reads fixtures only under --dry-run), and CI runs ubuntu bash 5.x
# (which never reproduces the 3.2 error), so guard it two ways:
echo "--- wrapper 8: drive_dry expansion is bash-3.2 / set-u safe (#612) ---"
# (a) static anti-regression — runner-agnostic. The guard's "${arr[@]+...}" prefix
#     is the fix's fingerprint; replacing the guarded usage with a bare
#     "${drive_dry[@]}" removes the [@]+ guard, so its absence flags a regression.
if grep -qE '\$\{drive_dry\[@\]\+' "$CRON"; then
  ok "drive_dry uses the set-u-safe guard \${drive_dry[@]+...}"
else
  bad "w8.guard" "drive_dry expanded without the bash-3.2 nounset guard (\${drive_dry[@]+...})"
fi
# (b) behavioral — run the guarded idiom under /bin/bash + set -u for both the
#     empty and populated cases (real coverage on a bash-3.2 host; passes on 5.x).
if /bin/bash -c 'set -u
    d=(); set -- ${d[@]+"${d[@]}"}; [ "$#" -eq 0 ] || exit 1
    d=(--dry-run); set -- ${d[@]+"${d[@]}"}; [ "$1" = "--dry-run" ] || exit 1' 2>/dev/null; then
  ok "guarded expansion is nounset-clean under /bin/bash (empty + populated)"
else
  bad "w8.bash32" "guarded drive_dry idiom still crashes under /bin/bash + set -u"
fi

# ── WRAPPER 9: schedule cap: threads gate→cron→tick (#642) ───────────────────
echo "--- wrapper 9: schedule cap: override raises the tick's per-tick drive count ---"
# Schedule names cap: 3; fixture provides 3 Operational Ready items. The wrapper
# must resolve the vault cap and thread it (export FUNNEL_DRIVE_CAP) to the tick,
# which then emits 3 drives instead of the default 1 — end-to-end proof the vault
# `cap:` field governs throughput through the whole gate→cron→tick path.
FX9="$TMP/wfx9"; mkdir -p "$FX9/board-3"
printf '%s\n' '[{"number":901,"title":"a","labels":["Operational"]},
 {"number":902,"title":"b","labels":["Operational"]},
 {"number":903,"title":"c","labels":["Operational"]}]' > "$FX9/board-3/ready.json"
F9c="$TMP/sched_cap3.md"
printf '%s\n' '```funnel-schedule' 'enabled: yes' 'hours: 14' 'cap: 3' '```' > "$F9c"
LOGD9="$TMP/wlog9"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F9c" \
  FUNNEL_LOG_DIR="$LOGD9" FUNNEL_NOTIFY_CMD="true" \
  bash "$CRON" --dry-run --fixture "$FX9" >/dev/null
[ "$(jq '[.plans[].actions[]|select(.action=="drive-ready")]|length' "$LOGD9/latest.json")" = "3" ] \
  && ok "cap: 3 → tick emitted 3 drives (vault cap threaded to the tick)" \
  || bad "w9.cap" "got $(jq '[.plans[].actions[]|select(.action=="drive-ready")]|length' "$LOGD9/latest.json")"
# And with NO cap: in the schedule, the wrapper falls back to the code default (1).
F9d="$TMP/sched_nocap.md"
printf '%s\n' '```funnel-schedule' 'enabled: yes' 'hours: 14' '```' > "$F9d"
LOGD9b="$TMP/wlog9b"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F9d" \
  FUNNEL_LOG_DIR="$LOGD9b" FUNNEL_NOTIFY_CMD="true" \
  bash "$CRON" --dry-run --fixture "$FX9" >/dev/null
[ "$(jq '[.plans[].actions[]|select(.action=="drive-ready")]|length' "$LOGD9b/latest.json")" = "1" ] \
  && ok "no cap: → 1 drive (code default preserved)" \
  || bad "w9.nocap" "got $(jq '[.plans[].actions[]|select(.action=="drive-ready")]|length' "$LOGD9b/latest.json")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ F#640 — record ENRICHMENT: error context was collapsed (a gate/tick/drive    │
# │ crash dropped stderr → a generic stub) and there was no per-action timing.   │
# │ Now every error record carries the real cause as `context`, and wake / tick  │
# │ / drive records carry timing (duration_ms / tick_ms).                        │
# ╰──────────────────────────────────────────────────────────────────────────╯

# ── WRAPPER 10: a run's records carry timing (wake duration_ms + per-board tick_ms) ─
echo "--- wrapper 10: ran record carries duration_ms; each plan carries tick_ms (#640) ---"
FX10="$TMP/wfx10"; mk_fixture "$FX10"; LOGD10="$TMP/wlog10"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$LOGD10" FUNNEL_NOTIFY_CMD="true" \
  bash "$CRON" --dry-run --fixture "$FX10" >/dev/null
[ "$(jq -r '.event=="ran" and (.duration_ms|type)=="number" and .duration_ms>=0' "$LOGD10/latest.json")" = "true" ] \
  && ok "ran record carries a numeric duration_ms" || bad "w10.wake" "$(cat "$LOGD10/latest.json")"
[ "$(jq -r '.plans[0] | has("tick_ms") and (.tick_ms|type)=="number"' "$LOGD10/latest.json")" = "true" ] \
  && ok "each plan carries a numeric tick_ms" || bad "w10.tick" "$(jq -c '.plans[0]' "$LOGD10/latest.json")"

# ── WRAPPER 11: a CRASHED gate (unparseable verdict) → distinct reason + context ─
echo "--- wrapper 11: gate crash → reason names it + context carries stderr (#640) ---"
GATE_CRASH="$TMP/gate-crash.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "garbage not json"' 'echo "gate blew up: config missing" >&2' 'exit 1' > "$GATE_CRASH"
chmod +x "$GATE_CRASH"
FX11="$TMP/wfx11"; mk_fixture "$FX11"; LOGD11="$TMP/wlog11"
OUT11="$(env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_GATE_BIN="$GATE_CRASH" FUNNEL_LOG_DIR="$LOGD11" FUNNEL_NOTIFY_CMD="true" \
  bash "$CRON" --dry-run --fixture "$FX11")"
[ "$(jq -r '.event' <<<"$OUT11")" = "skipped" ] && ok "a crashed gate still fail-closes to skip (exit clean)" || bad "w11.event" "got $OUT11"
[ "$(jq -r '.reason' "$LOGD11/latest.json")" = "gate produced no parseable verdict" ] \
  && ok "reason distinguishes a broken gate from a genuine not-scheduled skip" || bad "w11.reason" "got $(jq -r '.reason' "$LOGD11/latest.json")"
jq -e '.context | test("gate blew up")' "$LOGD11/latest.json" >/dev/null \
  && ok "context carries the gate's real stderr cause" || bad "w11.context" "got $(jq -r '.context // "none"' "$LOGD11/latest.json")"

# ── WRAPPER 12: a CRASHED tick → {tick:error} stub carries stderr as context ───
echo "--- wrapper 12: tick crash → plan stub carries context (real cause), not a bare error (#640) ---"
TICK_CRASH="$TMP/tick-crash.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "board_resolve failed: rate limited" >&2' 'exit 1' > "$TICK_CRASH"
chmod +x "$TICK_CRASH"
FX12="$TMP/wfx12"; mk_fixture "$FX12"; LOGD12="$TMP/wlog12"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_TICK_BIN="$TICK_CRASH" FUNNEL_LOG_DIR="$LOGD12" FUNNEL_NOTIFY_CMD="true" \
  bash "$CRON" --dry-run --fixture "$FX12" >/dev/null
[ "$(jq -r '.plans[0].tick' "$LOGD12/latest.json")" = "error" ] && ok "tick crash → plan tick:error stub" || bad "w12.stub" "$(jq -c '.plans[0]' "$LOGD12/latest.json")"
jq -e '.plans[0].context | test("board_resolve failed")' "$LOGD12/latest.json" >/dev/null \
  && ok "the stub carries the tick's real stderr cause (not dropped)" || bad "w12.context" "got $(jq -r '.plans[0].context // "none"' "$LOGD12/latest.json")"
[ "$(jq -r '.plans[0] | has("tick_ms")' "$LOGD12/latest.json")" = "true" ] && ok "even a crashed tick's plan carries tick_ms" || bad "w12.tickms" "$(jq -c '.plans[0]' "$LOGD12/latest.json")"

# ── WRAPPER 13: a CRASHED driver → drive record status:error + context + duration ─
echo "--- wrapper 13: drive crash → status:error record carries context + duration_ms (#640) ---"
DRIVE_CRASH="$TMP/drive-crash.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'echo "claude spawn failed: settings overlay missing" >&2' 'exit 1' > "$DRIVE_CRASH"
chmod +x "$DRIVE_CRASH"
FX13="$TMP/wfx13"; mk_fixture "$FX13"; LOGD13="$TMP/wlog13"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_DRIVE=1 FUNNEL_DRIVE_BIN="$DRIVE_CRASH" FUNNEL_LOG_DIR="$LOGD13" FUNNEL_NOTIFY_CMD="true" \
  bash "$CRON" --dry-run --fixture "$FX13" >/dev/null
[ "$(jq -r 'select(.event=="drive") | .status' "$LOGD13/2026-06-25.jsonl")" = "error" ] \
  && ok "drive crash → a drive record with status:error" || bad "w13.status" "$(cat "$LOGD13/latest.json")"
jq -e 'select(.event=="drive") | .context | test("claude spawn failed")' "$LOGD13/2026-06-25.jsonl" >/dev/null \
  && ok "the drive error record carries the driver's real stderr cause" || bad "w13.context" "got $(jq -rc 'select(.event=="drive").context // "none"' "$LOGD13/2026-06-25.jsonl")"
jq -e 'select(.event=="drive") | (.duration_ms|type)=="number"' "$LOGD13/2026-06-25.jsonl" >/dev/null \
  && ok "the drive record carries a numeric duration_ms" || bad "w13.dur" "$(jq -rc 'select(.event=="drive").duration_ms' "$LOGD13/2026-06-25.jsonl")"

# ── WRAPPER 14: a FAILED self-update is carried into the wake record (#640) ────
echo "--- wrapper 14: self-update failure → wake record carries self_update.failed + context (#640) ---"
NOTAREPO="$TMP/not-a-git-repo"; mkdir -p "$NOTAREPO"
FX14="$TMP/wfx14"; mk_fixture "$FX14"; LOGD14="$TMP/wlog14"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_CRON_SELF_UPDATE=1 FOUNDATION="$NOTAREPO" \
  FUNNEL_LOG_DIR="$LOGD14" FUNNEL_NOTIFY_CMD="true" \
  bash "$CRON" --dry-run --fixture "$FX14" >/dev/null 2>&1
[ "$(jq -r '.self_update.status' "$LOGD14/latest.json")" = "failed" ] \
  && ok "the wake record carries the failed self-update (no longer stderr-only)" || bad "w14.status" "$(cat "$LOGD14/latest.json")"
[ "$(jq -r '.self_update | has("context")' "$LOGD14/latest.json")" = "true" ] \
  && ok "self_update carries the git failure context" || bad "w14.context" "$(jq -c '.self_update' "$LOGD14/latest.json")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ F#639 L0 — funnel records are DUAL-WRITTEN to the git-archivable raw lake    │
# │ (meta/data/raw/funnel-<YYYY-MM>.jsonl) alongside the home-dir log, so the    │
# │ rollup/dashboard substrate can aggregate them. A write failure warns, never  │
# │ silently drops.                                                              │
# ╰──────────────────────────────────────────────────────────────────────────╯

# ── WRAPPER 15: a run's record lands in BOTH the home log AND the raw lake ─────
echo "--- wrapper 15: emit_record dual-writes to the raw lake (#639 L0) ---"
FX15="$TMP/wfx15"; mk_fixture "$FX15"; LOGD15="$TMP/wlog15"; RAW15="$TMP/raw15"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_NOW_TS=2026-06-25T14:00:00Z FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$LOGD15" FUNNEL_RAW_DIR="$RAW15" FUNNEL_NOTIFY_CMD="true" \
  bash "$CRON" --dry-run --fixture "$FX15" >/dev/null
[ -f "$RAW15/funnel-2026-06.jsonl" ] && ok "raw lake funnel-2026-06.jsonl written (monthly rotation)" || bad "w15.file" "no $RAW15/funnel-2026-06.jsonl ($(ls "$RAW15" 2>/dev/null))"
[ "$(jq -r '.event' "$RAW15/funnel-2026-06.jsonl" | tail -1)" = "ran" ] && ok "the ran record is in the raw lake" || bad "w15.event" "got $(tail -1 "$RAW15/funnel-2026-06.jsonl" 2>/dev/null)"
# The SAME record set is in both sinks (home-dir day log AND the raw lake).
[ "$(jq -c . "$LOGD15/2026-06-25.jsonl")" = "$(jq -c . "$RAW15/funnel-2026-06.jsonl")" ] \
  && ok "home-dir log and raw lake carry the identical record set" || bad "w15.parity" "home=$(cat "$LOGD15/2026-06-25.jsonl") raw=$(cat "$RAW15/funnel-2026-06.jsonl")"
[ "$(jq -r '.ts' "$RAW15/funnel-2026-06.jsonl" | tail -1)" = "2026-06-25T14:00:00Z" ] && ok "raw record carries the pinned ts (#663 stamp preserved)" || bad "w15.ts" "got $(jq -r '.ts' "$RAW15/funnel-2026-06.jsonl" | tail -1)"

# ── WRAPPER 16: a raw-lake write failure WARNS, does not drop the home record ──
echo "--- wrapper 16: raw-lake write failure warns, home record survives (#639 L0) ---"
FX16="$TMP/wfx16"; mk_fixture "$FX16"; LOGD16="$TMP/wlog16"
# Point the raw dir at a path that cannot be created (a file where a dir is needed).
BADRAW="$TMP/badraw-file"; : > "$BADRAW"
ERR16="$TMP/w16.err"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$LOGD16" FUNNEL_RAW_DIR="$BADRAW/sub" FUNNEL_NOTIFY_CMD="true" \
  bash "$CRON" --dry-run --fixture "$FX16" >/dev/null 2>"$ERR16"
[ -f "$LOGD16/2026-06-25.jsonl" ] && ok "the home-dir record survived a raw-lake failure (not dropped)" || bad "w16.home" "home log missing"
grep -q "WARN failed to write record" "$ERR16" && ok "the raw-lake write failure WARNED to stderr (not silent)" || bad "w16.warn" "no warning: $(cat "$ERR16")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ F#732 — Step 5: issue-meta snapshot. Invoked once per non-skipped wake,     │
# │ via the FUNNEL_ISSUE_META_BIN test-double seam (mirrors GATE/TICK/DRIVE),   │
# │ --dry-run passed through so the offline fixture path never calls a real     │
# │ `gh`, and `|| true`-isolated so a crashing double never breaks the wake.     │
# ╰──────────────────────────────────────────────────────────────────────────╯

# ── WRAPPER 17: issue-meta snapshot invoked on a run, --dry-run passed through ─
echo "--- wrapper 17: issue-meta snapshot invoked once per run, --dry-run threaded ---"
FX17="$TMP/wfx17"; mk_fixture "$FX17"; LOGD17="$TMP/wlog17"
IM_MARK="$TMP/im-mark17"
IM_DOUBLE="$TMP/im-double17.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  "printf '%s\\n' \"\$*\" >> \"$IM_MARK\"" \
  'exit 0' > "$IM_DOUBLE"
chmod +x "$IM_DOUBLE"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$LOGD17" FUNNEL_NOTIFY_CMD="true" FUNNEL_ISSUE_META_BIN="$IM_DOUBLE" \
  bash "$CRON" --dry-run --fixture "$FX17" >/dev/null
[ -f "$IM_MARK" ] && ok "issue-meta double was invoked on a run" || bad "w17.invoked" "double never ran"
[ "$(wc -l < "$IM_MARK" | tr -d ' ')" = "1" ] && ok "issue-meta double invoked exactly once per wake" || bad "w17.count" "got $(cat "$IM_MARK" 2>/dev/null)"
grep -qF -- '--dry-run' "$IM_MARK" && ok "cron --dry-run threads --dry-run through to the issue-meta step (offline seam)" || bad "w17.dryrun" "double did not receive --dry-run: $(cat "$IM_MARK")"

# ── WRAPPER 18: a CRASHING issue-meta double never breaks the wake (|| true) ──
echo "--- wrapper 18: a crashing issue-meta double is isolated (|| true), wake still succeeds ---"
FX18="$TMP/wfx18"; mk_fixture "$FX18"; LOGD18="$TMP/wlog18"
IM_CRASH="$TMP/im-crash18.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "boom: gh rate limited" >&2' 'exit 1' > "$IM_CRASH"
chmod +x "$IM_CRASH"
OUT18="$(env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$LOGD18" FUNNEL_NOTIFY_CMD="true" FUNNEL_ISSUE_META_BIN="$IM_CRASH" \
  bash "$CRON" --dry-run --fixture "$FX18")"
RC18=$?
[ "$RC18" -eq 0 ] && ok "wrapper still exits 0 despite a crashing issue-meta step" || bad "w18.rc" "exit=$RC18"
[ "$(jq -r '.event' <<<"$OUT18")" = "ran" ] && ok "wake still reports event=ran (the crash never propagated)" || bad "w18.event" "got $(jq -r '.event' <<<"$OUT18")"
[ -f "$LOGD18/2026-06-25.jsonl" ] && ok "the wake's own log record was still written" || bad "w18.log" "no day log despite || true isolation"

# ── WRAPPER 19: a MISSING issue-meta script (unset bin resolves nowhere) ─────
# never breaks the wake either — the || true covers "command not found" (127)
# the same as a non-zero exit from a real double.
echo "--- wrapper 19: a missing issue-meta script is isolated too (no crash) ---"
FX19="$TMP/wfx19"; mk_fixture "$FX19"; LOGD19="$TMP/wlog19"
OUT19="$(env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$LOGD19" FUNNEL_NOTIFY_CMD="true" FUNNEL_ISSUE_META_BIN="$TMP/does-not-exist-im.sh" \
  bash "$CRON" --dry-run --fixture "$FX19")"
RC19=$?
[ "$RC19" -eq 0 ] && ok "wrapper exits 0 even when the issue-meta binary is missing" || bad "w19.rc" "exit=$RC19"
[ "$(jq -r '.event' <<<"$OUT19")" = "ran" ] && ok "wake still reports event=ran on a missing issue-meta binary" || bad "w19.event" "got $(jq -r '.event' <<<"$OUT19")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ F#731 — rework-events snapshot: invoked from the wake at Step 2.5, ONE     │
# │ call per ticked board, isolated with `|| true` so a snapshot failure       │
# │ never breaks the wake. Skipped entirely on --dry-run (a fixture-replay     │
# │ tick has no real repo to snapshot).                                        │
# ╰──────────────────────────────────────────────────────────────────────────╯

# rework-snapshot stub: records every invocation's argv to a sentinel file, no
# network. REWORK_STUB_EXIT lets a test make it fail on demand.
REWORK_STUB="$TMP/rework-stub.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$REWORK_SENTINEL"' 'exit "${REWORK_STUB_EXIT:-0}"' > "$REWORK_STUB"
chmod +x "$REWORK_STUB"

# tick stub for the non-dry-run wrapper tests below: funnel-tick.sh normally
# touches the board/network, so it must be stubbed too (mirrors TICK_CRASH in
# wrapper 12) — a plain no-op plan is enough since these tests only assert on
# the rework-snapshot wiring, not tick behavior.
TICK_NOOP="$TMP/tick-noop.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "{\"actions\":[]}"' > "$TICK_NOOP"
chmod +x "$TICK_NOOP"

# ── WRAPPER 20: --dry-run → rework-snapshot is NEVER invoked ─────────────────
echo "--- wrapper 20: --dry-run run never invokes rework-snapshot.sh ---"
FX20="$TMP/wfx17"; mk_fixture "$FX20"; LOGD20="$TMP/wlog17"
SENT20="$TMP/rework20.txt"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_LOG_DIR="$LOGD20" FUNNEL_NOTIFY_CMD="true" \
  REWORK_SNAPSHOT_BIN="$REWORK_STUB" REWORK_SENTINEL="$SENT20" \
  bash "$CRON" --dry-run --fixture "$FX20" >/dev/null
[ ! -f "$SENT20" ] && ok "rework-snapshot.sh not invoked on a --dry-run run" || bad "w20.dryrun" "unexpected invocation(s): $(cat "$SENT20")"

# ── WRAPPER 21: a real (non-dry-run) run invokes rework-snapshot once per board ─
echo "--- wrapper 21: a live run invokes rework-snapshot.sh once per ticked board (#731) ---"
LOGD21="$TMP/wlog18"
SENT21="$TMP/rework21.txt"
env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F6" \
  FUNNEL_TICK_BIN="$TICK_NOOP" FUNNEL_LOG_DIR="$LOGD21" FUNNEL_NOTIFY_CMD="true" \
  FUNNEL_OPERATOR="@testops" \
  REWORK_SNAPSHOT_BIN="$REWORK_STUB" REWORK_SENTINEL="$SENT21" \
  bash "$CRON" >/dev/null
[ -f "$SENT21" ] && ok "rework-snapshot.sh invoked on a live (non-dry-run) run" || bad "w21.invoked" "no invocation recorded"
[ "$(wc -l < "$SENT21" | tr -d ' ')" = "2" ] && ok "invoked exactly once per ticked board (F6's 'boards: 3 4' -> 2 calls)" || bad "w21.count" "$(cat "$SENT21" 2>/dev/null)"
grep -q "snapshot --board 3" "$SENT21" && ok "invocation carries --board 3" || bad "w21.board3" "$(cat "$SENT21")"
grep -q "snapshot --board 4" "$SENT21" && ok "invocation carries --board 4" || bad "w21.board4" "$(cat "$SENT21")"

# ── WRAPPER 22: a rework-snapshot FAILURE never breaks the wake (|| true) ────
echo "--- wrapper 22: rework-snapshot.sh failure is isolated, wake still succeeds (#731) ---"
LOGD22="$TMP/wlog19"
SENT22="$TMP/rework22.txt"
OUT22="$(env FUNNEL_NOW_HOUR=14 FUNNEL_NOW_DATE=2026-06-25 FUNNEL_SCHEDULE_FILE="$F" \
  FUNNEL_TICK_BIN="$TICK_NOOP" FUNNEL_LOG_DIR="$LOGD22" FUNNEL_NOTIFY_CMD="true" \
  FUNNEL_OPERATOR="@testops" \
  REWORK_SNAPSHOT_BIN="$REWORK_STUB" REWORK_SENTINEL="$SENT22" REWORK_STUB_EXIT=1 \
  bash "$CRON")"
RC22=$?
[ "$RC22" -eq 0 ] && ok "wrapper still exits 0 despite a failing rework-snapshot.sh" || bad "w22.rc" "exit=$RC22"
[ "$(jq -r '.event' <<<"$OUT22")" = "ran" ] && ok "wake record still event=ran (snapshot failure did not abort the wake)" || bad "w22.event" "got $OUT22"
[ -f "$SENT22" ] && ok "the failing rework-snapshot.sh was still invoked (its own failure is what's isolated)" || bad "w22.invoked" "no invocation recorded"

# ── summary ──────────────────────────────────────────────────────────────────
echo
echo "funnel-cron tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
