#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/funnel-tick.sh — the autonomous funnel
# driver's per-board tick (foundation #569).
#
# funnel-tick is a THIN SCHEDULER: it CALLS /triage → /assess → /build and
# inherits their gates; it re-implements none. These tests exercise the
# deterministic spine — the --dry-run --fixture path — entirely OFFLINE: each
# case seeds a fixture tree (mock decision issues + answer comments + Ready
# items with work-class labels) and asserts on the emitted tick-plan JSON. Zero
# network, zero live board, zero `gh`.
#
# Covers the acceptance bullets of #569:
#   1. dry tick: drains a seeded answered decision, drives one Operational Ready
#      item through /assess→/build, routes one Foundational gate to the queue.
#   2. the dry tick is runnable against a locally-seeded stub (--dry-run --fixture).
#   3. single-flight: two overlapping live ticks do not double-act (lockfile).
#   4. board ON/OFF flip: a disabled board is a no-op.
#   5. typed-reply parsing (decision block + /choose + /approve) and the
#      parse-miss → re-assign-operator path (closed-enum-or-escalate, no guess).
#   6. contention pre-check: a re-assigned decision issue is skipped this tick.
#   7. default-Operational: an unlabeled Ready item classifies Operational.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICK="$HERE/../funnel-tick.sh"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# seed_board <fixture-root> <board#> — make the dir
seed_board() { mkdir -p "$1/board-$2"; }

# action_for <jq-select> (reads plan JSON from stdin) — first matching action
action_for() { jq -c "first(.actions[] | select($1)) // empty"; }

# ── 1: full dry tick — drain + drive + route (the headline acceptance) ───────
echo "--- test 1: dry tick drains a decision, drives Operational, routes Foundational ---"
FX="$TMP/t1"; seed_board "$FX" 3
cat > "$FX/board-3/decisions.json" <<'JSON'
[{"number":42,"title":"merge-gate policy","body":"Decision needed","assignees":[],
  "comments":[{"createdAt":"2026-06-24T10:00:00Z","body":"hmm"},
              {"createdAt":"2026-06-24T11:00:00Z","body":"```decision\nchosen: timed-objection\n```"}]}]
JSON
echo 0 > "$FX/board-3/assignees-42.txt"
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":101,"title":"fix venue parser bug","labels":["Operational"]},
 {"number":102,"title":"new export feature","labels":["Foundational"]}]
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"

[ "$(jq -r '.dry_run' <<<"$PLAN")" = "true" ] && ok "dry_run flag set" || bad "dry_run" "got $(jq -r '.dry_run' <<<"$PLAN")"

DRAIN="$(action_for <<<"$PLAN" '.action=="drain-answer"')"
[ -n "$DRAIN" ] && ok "decision drained" || bad "drain" "no drain-answer action"
[ "$(jq -r '.issue' <<<"$DRAIN")" = "42" ] && ok "drained issue #42" || bad "drain.issue" "got $(jq -r '.issue' <<<"$DRAIN")"
[ "$(jq -r '.chosen' <<<"$DRAIN")" = "timed-objection" ] && ok "parsed chosen=timed-objection" || bad "drain.chosen" "got $(jq -r '.chosen' <<<"$DRAIN")"

DRIVE="$(action_for <<<"$PLAN" '.action=="drive-ready"')"
[ "$(jq -r '.issue' <<<"$DRIVE")" = "101" ] && ok "drove Operational #101" || bad "drive.issue" "got $(jq -r '.issue' <<<"$DRIVE")"
[ "$(jq -r '.class' <<<"$DRIVE")" = "Operational" ] && ok "drive class=Operational" || bad "drive.class" "got $(jq -r '.class' <<<"$DRIVE")"
# It must EMIT a CALL to the existing pipeline, not re-implement it.
jq -e '.emit | test("/assess") and test("/build") and test("--unattended")' <<<"$DRIVE" >/dev/null \
  && ok "drive emits /assess→/build --unattended (calls, not re-implements)" || bad "drive.emit" "missing pipeline call: $(jq -r '.emit' <<<"$DRIVE")"

ROUTE="$(action_for <<<"$PLAN" '.action=="route-foundational"')"
[ "$(jq -r '.issue' <<<"$ROUTE")" = "102" ] && ok "routed Foundational #102" || bad "route.issue" "got $(jq -r '.issue' <<<"$ROUTE")"
[ "$(jq -r '.class' <<<"$ROUTE")" = "Foundational" ] && ok "route class=Foundational" || bad "route.class" "got $(jq -r '.class' <<<"$ROUTE")"
jq -e '.emit | test("decision queue") and test("decision-issue backend")' <<<"$ROUTE" >/dev/null \
  && ok "route emits decision-queue routing (calls backend, not re-embeds)" || bad "route.emit" "$(jq -r '.emit' <<<"$ROUTE")"

# ── 2: only ONE Operational + ONE Foundational drive per tick (WIP discipline) ─
echo "--- test 2: one Operational + one Foundational per tick (rest deferred) ---"
FX="$TMP/t2"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":201,"title":"bug a","labels":["Operational"]},
 {"number":202,"title":"bug b","labels":["Operational"]},
 {"number":203,"title":"feature a","labels":["Foundational"]},
 {"number":204,"title":"feature b","labels":["Foundational"]}]
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ "$(jq '[.actions[]|select(.action=="drive-ready")]|length' <<<"$PLAN")" = "1" ] \
  && ok "exactly one Operational drive" || bad "t2.drive-count" "got $(jq '[.actions[]|select(.action=="drive-ready")]|length' <<<"$PLAN")"
[ "$(jq '[.actions[]|select(.action=="route-foundational")]|length' <<<"$PLAN")" = "1" ] \
  && ok "exactly one Foundational route" || bad "t2.route-count" "got $(jq '[.actions[]|select(.action=="route-foundational")]|length' <<<"$PLAN")"

# ── 3: default-Operational — an unlabeled Ready item classifies Operational ──
echo "--- test 3: unlabeled Ready item defaults to Operational ---"
FX="$TMP/t3"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":301,"title":"unlabeled follow-up","labels":[]}]
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
D="$(action_for <<<"$PLAN" '.action=="drive-ready"')"
[ "$(jq -r '.class' <<<"$D")" = "Operational" ] && ok "unlabeled → Operational (default rule)" || bad "t3.class" "got $(jq -r '.class' <<<"$D")"

# ── 4: typed-reply grammar variants ──────────────────────────────────────────
echo "--- test 4: /choose and /approve shorthands parse ---"
FX="$TMP/t4"; seed_board "$FX" 3
cat > "$FX/board-3/decisions.json" <<'JSON'
[{"number":401,"title":"a","body":"x","assignees":[],
  "comments":[{"createdAt":"2026-06-24T11:00:00Z","body":"/choose explicit-approval"}]},
 {"number":402,"title":"b","body":"x","assignees":[],
  "comments":[{"createdAt":"2026-06-24T11:00:00Z","body":"sounds good\n/approve"}]}]
JSON
echo 0 > "$FX/board-3/assignees-401.txt"; echo 0 > "$FX/board-3/assignees-402.txt"
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
C1="$(jq -r 'first(.actions[]|select(.issue==401)|.chosen)' <<<"$PLAN")"
[ "$C1" = "explicit-approval" ] && ok "/choose <label> parsed" || bad "t4.choose" "got $C1"
C2="$(jq -r 'first(.actions[]|select(.issue==402)|.chosen)' <<<"$PLAN")"
[ "$C2" = "approve" ] && ok "/approve parsed" || bad "t4.approve" "got $C2"

# ── 5: parse-miss → re-assign operator (closed-enum-or-escalate, no guess) ───
echo "--- test 5: unparseable reply re-assigns operator, never guesses ---"
FX="$TMP/t5"; seed_board "$FX" 3
cat > "$FX/board-3/decisions.json" <<'JSON'
[{"number":501,"title":"a","body":"x","assignees":[],
  "comments":[{"createdAt":"2026-06-24T11:00:00Z","body":"do whichever, sounds good"}]}]
JSON
echo 0 > "$FX/board-3/assignees-501.txt"
PLAN="$(BUILD_CONFIG_LOCAL="$TMP/no-local.sh" bash "$TICK" --dry-run --fixture "$FX" --board 3)"
M="$(action_for <<<"$PLAN" '.action=="drain-parse-miss"')"
[ -n "$M" ] && ok "parse-miss produced" || bad "t5.miss" "no drain-parse-miss action"
# Bared kernel default (the leading `@` of `@REPLACE_WITH_YOUR_GH_LOGIN` is stripped, #977).
[ "$(jq -r '.reassign_to' <<<"$M")" = "REPLACE_WITH_YOUR_GH_LOGIN" ] && ok "re-assigned operator on miss (bared kernel default, no override set)" || bad "t5.reassign" "got $(jq -r '.reassign_to' <<<"$M")"
# Must NOT have emitted a drain-answer (no silent default).
[ -z "$(action_for <<<"$PLAN" '.action=="drain-answer"')" ] && ok "no drain-answer on a parse miss (no guess)" || bad "t5.no-guess" "a default was taken"

# ── 5b: FUNNEL_OPERATOR override (tracker seam v0, #772) — non-default value
# respected, proving the build.config.sh knob (not just its default) is live. The
# emitted reassign_to is a BARE login: the leading `@` is stripped (foundation #977 —
# `--add-assignee "@someoneelse"` fails GitHub's replaceActorsForAssignable). ─
echo "--- test 5b: FUNNEL_OPERATOR env override is respected + bared (#772, #977) ---"
FX="$TMP/t5b"; seed_board "$FX" 3
cat > "$FX/board-3/decisions.json" <<'JSON'
[{"number":502,"title":"a","body":"x","assignees":[],
  "comments":[{"createdAt":"2026-06-24T11:00:00Z","body":"do whichever, sounds good"}]}]
JSON
echo 0 > "$FX/board-3/assignees-502.txt"
PLAN="$(FUNNEL_OPERATOR=@someoneelse BUILD_CONFIG_LOCAL="$TMP/no-local.sh" bash "$TICK" --dry-run --fixture "$FX" --board 3)"
M="$(action_for <<<"$PLAN" '.action=="drain-parse-miss"')"
[ "$(jq -r '.reassign_to' <<<"$M")" = "someoneelse" ] && ok "FUNNEL_OPERATOR override respected + bared (#772, #977)" || bad "t5b.override" "got $(jq -r '.reassign_to' <<<"$M")"

# ── 6: contention pre-check — re-assigned issue skipped this tick ────────────
echo "--- test 6: contention pre-check skips a re-assigned decision issue ---"
FX="$TMP/t6"; seed_board "$FX" 3
cat > "$FX/board-3/decisions.json" <<'JSON'
[{"number":601,"title":"a","body":"x","assignees":[],
  "comments":[{"createdAt":"2026-06-24T11:00:00Z","body":"```decision\nchosen: go\n```"}]}]
JSON
echo 1 > "$FX/board-3/assignees-601.txt"   # assignee changed since drain-list
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
S="$(action_for <<<"$PLAN" '.action=="skip-contention"')"
[ -n "$S" ] && ok "contention → skip-contention" || bad "t6.skip" "no skip-contention action"
[ -z "$(action_for <<<"$PLAN" '.action=="drain-answer"')" ] && ok "raced issue not drained" || bad "t6.no-drain" "drained a raced issue"

# ── 7: board ON/OFF flip — a disabled board is a no-op ───────────────────────
echo "--- test 7: board ON/OFF flip ---"
FX="$TMP/t7"; seed_board "$FX" 3; seed_board "$FX" 4
cat > "$FX/board-4/ready.json" <<'JSON'
[{"number":701,"title":"foundation bug","labels":["Operational"]}]
JSON
# board 4 is NOT in the default FUNNEL_ENABLED_BOARDS (=3) → disabled
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 4)"
[ "$(jq -r 'first(.actions[].action)' <<<"$PLAN")" = "board-disabled" ] \
  && ok "off board → board-disabled (no drive)" || bad "t7.off" "got $(jq -r 'first(.actions[].action)' <<<"$PLAN")"
[ -z "$(action_for <<<"$PLAN" '.action=="drive-ready"')" ] && ok "no work on a disabled board" || bad "t7.no-work" "drove a disabled board"
# Same board, but enabled via env override → it works.
PLAN="$(FUNNEL_ENABLED_BOARDS="3 4" bash "$TICK" --dry-run --fixture "$FX" --board 4)"
[ "$(jq -r 'first(.actions[]|select(.action=="drive-ready")|.issue)' <<<"$PLAN")" = "701" ] \
  && ok "env-enabled board now drives (#701)" || bad "t7.on" "got $(jq -r 'first(.actions[]|select(.action=="drive-ready")|.issue)' <<<"$PLAN")"

# ── 8: --list-enabled prints the ON boards (the flip's read surface) ─────────
echo "--- test 8: --list-enabled surface ---"
OUT="$(bash "$TICK" --list-enabled)"
[ "$(jq -r '.enabled_boards[0]' <<<"$OUT")" = "3" ] && ok "--list-enabled shows board 3 (pilot)" || bad "t8.list" "got $OUT"
[ "$(jq -r '.drive_concurrency' <<<"$OUT")" = "3" ] && ok "drive-concurrency default = 3" || bad "t8.conc" "got $(jq -r '.drive_concurrency' <<<"$OUT")"
[ "$(jq -r '.drive_cap' <<<"$OUT")" = "1" ] && ok "drive cap default = 1 (per-tick emit cap, #642)" || bad "t8.drivecap" "got $(jq -r '.drive_cap' <<<"$OUT")"
OUT3="$(FUNNEL_DRIVE_CAP=3 bash "$TICK" --list-enabled)"
[ "$(jq -r '.drive_cap' <<<"$OUT3")" = "3" ] && ok "--list-enabled reflects FUNNEL_DRIVE_CAP=3" || bad "t8.drivecap3" "got $(jq -r '.drive_cap' <<<"$OUT3")"

# ── 9: single-flight — two overlapping LIVE ticks do not double-act ──────────
# The live path acquires a flock lockfile; a second concurrent tick gets a
# non-blocking flock failure and exits 0 as a skipped no-op. We exercise the
# real lock (not the dry path, which skips it): hold the lock in a subshell,
# then run a tick and assert it reports "skipped". No network is touched because
# the held lock short-circuits BEFORE any board read.
echo "--- test 9: single-flight lockfile (no double-act) ---"
if ! command -v flock >/dev/null 2>&1; then
  ok "flock unavailable on this host — single-flight test skipped (script fails open; CI/mini host has flock)"
else
LOCKDIR="$TMP/lock9"; LOCKFILE="$LOCKDIR/tick.lock"; mkdir -p "$LOCKDIR"
# Hold the lock in a background process for the duration of the assertion.
(
  exec 201>"$LOCKFILE"
  flock -n 201 || exit 1
  sleep 5
) &
holder=$!
sleep 0.5   # let the holder acquire
# Run a tick against the SAME lockfile; it must find the lock held → skip.
# Point at board 3 with an empty fixture-less LIVE invocation guarded to never
# reach the network: the lock check precedes every read, so a held lock returns
# "skipped" before any `gh` call. We force the same lock path via env.
SECOND="$(FUNNEL_LOCK_DIR="$LOCKDIR" FUNNEL_LOCK_FILE="$LOCKFILE" \
          FUNNEL_ENABLED_BOARDS="999" bash "$TICK" --board 999 2>/dev/null || true)"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
if jq -e '.tick=="skipped"' <<<"$SECOND" >/dev/null 2>&1; then
  ok "second overlapping tick skipped (single-flight held)"
else
  bad "t9.single-flight" "expected skipped, got: $SECOND"
fi
# And with the lock FREE, the same invocation no longer skips (board 999 is an
# unknown/disabled board, so it is a clean no-op, but NOT a lock-skip).
THIRD="$(FUNNEL_LOCK_DIR="$LOCKDIR" FUNNEL_LOCK_FILE="$LOCKFILE" \
         FUNNEL_ENABLED_BOARDS="999" bash "$TICK" --board 999 2>/dev/null || true)"
if jq -e '.tick=="skipped"' <<<"$THIRD" >/dev/null 2>&1; then
  bad "t9.lock-release" "lock not released after holder exit (still skipping)"
else
  ok "lock released after holder exit (no longer skips)"
fi
fi   # end flock-available guard

# ── 9b: flock-degradation notice squelched to once per run (#492) ─────────────
# On stock macOS `flock` is absent, so the single-flight lock degrades to the
# per-issue contention pre-check and emits a WARN. That WARN must fire AT MOST
# ONCE per funnel run — not once per board/tick — or an unattended macOS host
# accrues a line every tick, forever. We force the degraded path deterministically
# via FUNNEL_FLOCK_CMD=<nonexistent> (so this runs identically on a host that HAS
# flock), then fire TWO ticks sharing one FUNNEL_RUN_ID + lock dir (the shape of
# funnel-cron's per-board loop within one wake) and assert the notice appears
# exactly ONCE across both. Board 999 is unknown/disabled, so each tick is a clean
# no-op that touches no network — the WARN emits from the lock step, before any
# board read. The fallback locking behavior is unchanged: the tick still PROCEEDS
# (it does not skip), it merely stops repeating the notice.
echo "--- test 9b: flock-degradation notice squelched to once per run (#492) ---"
LOCKDIR9B="$TMP/lock9b"; mkdir -p "$LOCKDIR9B"
ERR9B="$TMP/t9b.err"; : > "$ERR9B"
run_deg9b() {
  FUNNEL_FLOCK_CMD="__no_such_flock_binary__" FUNNEL_RUN_ID="$1" \
  FUNNEL_LOCK_DIR="$LOCKDIR9B" FUNNEL_LOCK_FILE="$LOCKDIR9B/tick.lock" \
  FUNNEL_ENABLED_BOARDS="999" bash "$TICK" --board 999 >/dev/null 2>>"$ERR9B" || true
}
run_deg9b "run-alpha"
run_deg9b "run-alpha"
WARN9B="$(grep -c 'flock not found' "$ERR9B" || true)"
[ "$WARN9B" = "1" ] \
  && ok "flock-degradation notice emitted exactly once across two same-run ticks" \
  || bad "t9b.once-per-run" "expected 1 flock WARN across two same-run ticks, got $WARN9B"
# A DIFFERENT run id re-warns (once per run, never once-ever) — the operator still
# sees the notice on each fresh cron log.
run_deg9b "run-beta"
WARN9B2="$(grep -c 'flock not found' "$ERR9B" || true)"
[ "$WARN9B2" = "2" ] \
  && ok "a new run id re-warns once (not silenced once-ever)" \
  || bad "t9b.per-run-reset" "expected 2 total after a fresh run id, got $WARN9B2"

# ── 10: malformed board-items tail still drives Ready work (#584) ────────────
# Regression for the live-seam bug. board_resolve's BOARD_ITEMS_JSON was
# observed on the LIVE board to carry a trailing token (jq: "Unmatched '}'"),
# making jq exit non-zero AFTER it had already emitted the correct array. The
# old `jq ... || echo '[]'` then APPENDED a stray '[]', so `jq length` returned
# the two-line "1\n0" and the `[ $j -lt $n_ready ]` integer test aborted — the
# tick silently no-op'd past ALL Ready work. The board-<N>/items.json fixture
# feeds the SAME normalizer the live path uses, with a deliberately malformed
# trailing '}'. Before the fix this drove nothing; after, it drives #777.
echo "--- test 10: malformed board-items tail still drives Ready work (#584) ---"
FX="$TMP/t10"; seed_board "$FX" 3
# A valid board-items object + ONE extra trailing '}' (the malformed tail).
printf '%s' '{"items":[{"status":"Ready","content":{"number":777},"title":"flake fix","labels":["Operational"]},{"status":"Backlog","content":{"number":888},"title":"later","labels":[]}],"totalCount":2}}' > "$FX/board-3/items.json"
ERR10="$TMP/t10.err"
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3 2>"$ERR10")"
[ "$(jq -r 'first(.actions[]|select(.action=="drive-ready")|.issue)' <<<"$PLAN")" = "777" ] \
  && ok "drove Ready #777 despite malformed items tail" \
  || bad "t10.drive" "expected drive-ready #777, got plan: $PLAN"
grep -q "integer expression expected" "$ERR10" \
  && bad "t10.no-crash" "integer-expression error still present (loop aborted)" \
  || ok "no integer-expression abort (single clean Ready array)"
# And a non-malformed items.json projects the same single array (no regression).
FX2="$TMP/t10b"; seed_board "$FX2" 3
printf '%s' '{"items":[{"status":"Ready","content":{"number":779},"title":"clean","labels":["Foundational"]}],"totalCount":1}' > "$FX2/board-3/items.json"
PLAN2="$(bash "$TICK" --dry-run --fixture "$FX2" --board 3)"
[ "$(jq -r 'first(.actions[]|select(.action=="route-foundational")|.issue)' <<<"$PLAN2")" = "779" ] \
  && ok "clean items.json routes Foundational #779 (normalizer round-trips)" \
  || bad "t10.clean" "expected route-foundational #779, got plan: $PLAN2"

# ── 11: idempotency — already-applied decision skipped, not re-assigned (#587) ─
# A just-drained issue can be re-listed once before the `decision` label drop
# propagates through the search index. Its latest comment is then the applier's
# delivery artifact, not a decision reply. The tick must recognise it and emit a
# clean drain-already-applied skip — NEVER a spurious parse-miss + operator
# re-assign (the #587 dequeue race), and never a re-drain. Both detection paths
# are covered: the machine sentinel (#111) and the legacy prose prefix (#112).
echo "--- test 11: drained decision (delivery artifact latest) → drain-already-applied (#587) ---"
FX="$TMP/t11"; seed_board "$FX" 3
cat > "$FX/board-3/decisions.json" <<'JSON'
[{"number":111,"title":"already answered (sentinel)","body":"x","assignees":[],
  "comments":[{"createdAt":"2026-06-24T11:00:00Z","body":"```decision\nchosen: go\n```"},
              {"createdAt":"2026-06-24T12:00:00Z","body":"Decision applied: go. Artifact written to plan note. Resuming on next tick.\n<!-- funnel:decision-applied -->"}]},
 {"number":112,"title":"already answered (legacy prose)","body":"x","assignees":[],
  "comments":[{"createdAt":"2026-06-24T12:00:00Z","body":"Decision applied: timed-objection. Artifact written to plan note. Resuming on next tick."}]}]
JSON
echo 0 > "$FX/board-3/assignees-111.txt"; echo 0 > "$FX/board-3/assignees-112.txt"
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
A1="$(action_for <<<"$PLAN" '.issue==111 and .action=="drain-already-applied"')"
[ -n "$A1" ] && ok "sentinel artifact → drain-already-applied (#111)" || bad "t11.sentinel" "no drain-already-applied for #111"
A2="$(action_for <<<"$PLAN" '.issue==112 and .action=="drain-already-applied"')"
[ -n "$A2" ] && ok "legacy prose artifact → drain-already-applied (#112)" || bad "t11.prose" "no drain-already-applied for #112"
[ -z "$(action_for <<<"$PLAN" '.action=="drain-parse-miss"')" ] && ok "no spurious parse-miss on a drained issue" || bad "t11.no-miss" "parse-miss emitted on an applied issue"
[ -z "$(action_for <<<"$PLAN" '.action=="drain-answer"')" ] && ok "no re-drain of an applied issue" || bad "t11.no-redrain" "drain-answer emitted on an applied issue"

# ── 12: needs-clarification parks; spike drives (#594→#600, simplified #684) ─────
# A Ready item carrying `needs-clarification` is blocked on the OPERATOR's answer
# (it parks in Ready, #435). The funnel must NOT auto-drive it — and it PARKS it
# unconditionally (route-already-assigned), regardless of assignment: the producer
# that raised the question (/triage, /sweep, the 5c escalation) already assigned the
# operator AT SOURCE (#684), so the funnel has nothing to assign — route-needs-input
# is retired. A `spike`, by contrast, is NOT an operator-input gate (#594 wrongly
# lumped it here): it is automatable read-only investigation whose verdict feeds a
# decision AFTER it runs, so it DRIVES like any Operational item (#600).
echo "--- test 12: needs-clarification parks; spike drives (#594→#600→#684) ---"
FX="$TMP/t12"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1201,"title":"ambiguous fix","labels":["Operational","needs-clarification"]},
 {"number":1202,"title":"investigate approach","labels":["spike"]},
 {"number":1203,"title":"clean follow-up","labels":["Operational"]},
 {"number":1204,"title":"gated feature","labels":["Foundational","needs-clarification"]}]
JSON
# Assignee fixtures deliberately 0 (unassigned): the gate no longer reads them —
# an UNASSIGNED needs-clarification item still parks (route-already-assigned), #684.
echo 0 > "$FX/board-3/assignees-1201.txt"; echo 0 > "$FX/board-3/assignees-1204.txt"
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
# Invariant 1: unassigned needs-clarification #1201 is NOT driven, and PARKS.
[ -z "$(action_for <<<"$PLAN" '.issue==1201 and .action=="drive-ready"')" ] \
  && ok "needs-clarification #1201 NOT driven (the #594 invariant)" || bad "t12.nc-drive" "drove a needs-clarification item"
NC="$(action_for <<<"$PLAN" '.issue==1201 and .action=="route-already-assigned"')"
[ -n "$NC" ] && ok "unassigned needs-clarification #1201 → route-already-assigned (park, #684)" || bad "t12.nc-park" "no route-already-assigned for #1201"
[ "$(jq -r '.label' <<<"$NC")" = "needs-clarification" ] && ok "park records the triggering label" || bad "t12.nc-label" "got $(jq -r '.label' <<<"$NC")"
# Invariant 2 (the #684 change): route-needs-input is emitted NOWHERE in the plan.
[ -z "$(action_for <<<"$PLAN" '.action=="route-needs-input"')" ] \
  && ok "route-needs-input is retired (emitted nowhere, #684)" || bad "t12.no-needsinput" "route-needs-input still emitted"
# Invariant 3 (the #600 correction): spike #1202 DRIVES — it is not an input gate.
[ -n "$(action_for <<<"$PLAN" '.issue==1202 and .action=="drive-ready"')" ] \
  && ok "spike #1202 → drive-ready (the #600 correction)" || bad "t12.spike-drive" "spike not driven"
[ "$(jq -r 'first(.actions[]|select(.action=="drive-ready")|.issue)' <<<"$PLAN")" = "1202" ] \
  && ok "spike #1202 is the driven item this tick (one drive/tick)" || bad "t12.spike-first" "got $(jq -r 'first(.actions[]|select(.action=="drive-ready")|.issue)' <<<"$PLAN")"
# Invariant 4: the retired skip-needs-input action appears NOWHERE in the plan.
[ -z "$(action_for <<<"$PLAN" '.action=="skip-needs-input"')" ] \
  && ok "skip-needs-input is retired (emitted nowhere)" || bad "t12.no-skip" "skip-needs-input still emitted"
# Invariant 5: needs-clarification beats class — #1204 parks, not Foundational.
[ -z "$(action_for <<<"$PLAN" '.issue==1204 and .action=="route-foundational"')" ] \
  && ok "Foundational+needs-clarification #1204 NOT route-foundational (gate precedes class)" || bad "t12.found-route" "routed a needs-clarification item as Foundational"
[ -n "$(action_for <<<"$PLAN" '.issue==1204 and .action=="route-already-assigned"')" ] \
  && ok "Foundational+needs-clarification #1204 → route-already-assigned (park)" || bad "t12.found-park" "no route-already-assigned for #1204"

# ── 12b: an already-assigned needs-clarification also parks (unchanged by #684) ──
# The funnel fires hourly; a needs-clarification item — assigned or not — is in the
# operator's court and must never be re-grabbed. Post-#684 the gate is unconditional:
# assigned → route-already-assigned, exactly as unassigned does; never route-needs-input.
echo "--- test 12b: already-assigned needs-clarification → route-already-assigned (#684) ---"
FX="$TMP/t12b"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1301,"title":"already in operator court","labels":["needs-clarification"]}]
JSON
echo 1 > "$FX/board-3/assignees-1301.txt"
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ -n "$(action_for <<<"$PLAN" '.issue==1301 and .action=="route-already-assigned"')" ] \
  && ok "assigned #1301 → route-already-assigned (idempotent)" || bad "t12b.already" "no route-already-assigned for assigned #1301"
[ -z "$(action_for <<<"$PLAN" '.issue==1301 and .action=="route-needs-input"')" ] \
  && ok "assigned #1301 NOT re-routed (no hourly re-grab)" || bad "t12b.regrab" "re-routed an already-assigned item"

# ── 12c: Phase-A2 drains ANSWERED needs-clarification items (foundation #657) ────
# When the operator answers a `needs-clarification` item and UNASSIGNS themselves
# (baton returned), it appears in the `no:assignee` clarification drain-list. The
# tick DRAINS it — emits drain-clarification to clear the label so it becomes
# drivable again — with these guards, mirroring the decision drain:
#   #2001 genuine answer, unassigned  → drain-clarification (label cleared)
#   #2003 already-drained (marker ack) → drain-clarification-already-applied (idempotent)
#   #2004 re-assigned since list-read  → skip-contention
# #2001 also sits in the Ready pool (an unassigned labeled item is in BOTH the drain
# search and the Ready search); the tick must emit ONLY the drain for it, never ALSO
# a route-already-assigned park (the double-emit guard).
# (#697: a rung-5c CODE escalation now carries its OWN `funnel-escalated` label — never
# `needs-clarification` — so it can NEVER appear in this drain-list; #2005 below is the
# Ready-loop park test that replaces the retired skip-merge-escalation case.)
echo "--- test 12c: Phase-A2 drains answered needs-clarification (#657) ---"
FX="$TMP/t12c"; seed_board "$FX" 3
cat > "$FX/board-3/clarifications.json" <<'JSON'
[{"number":2001,"title":"ambiguous fix","body":"needs a topology choice","assignees":[],
  "comments":[{"createdAt":"2026-06-30T10:00:00Z","body":"needs-clarification: split A or B?"},
              {"createdAt":"2026-06-30T12:00:00Z","body":"Let's do B"}]},
 {"number":2003,"title":"already drained","body":"x","assignees":[],
  "comments":[{"createdAt":"2026-06-30T11:00:00Z","body":"Let's do A"},
              {"createdAt":"2026-06-30T11:05:00Z","body":"<!-- funnel:clarification-drained --> Clarified (funnel): operator answer consumed — released to drive."}]},
 {"number":2004,"title":"raced re-assign","body":"y","assignees":[],
  "comments":[{"createdAt":"2026-06-30T11:00:00Z","body":"go with X"}]}]
JSON
echo 0 > "$FX/board-3/assignees-2001.txt"
echo 0 > "$FX/board-3/assignees-2003.txt"
echo 1 > "$FX/board-3/assignees-2004.txt"   # re-grabbed after the drain-list read
# #2001 is also a Ready item (unassigned + labeled) — exercises the double-emit guard.
# #2005 carries `funnel-escalated` (a parked rung-5c code item) — the #697 park gate.
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":2001,"title":"ambiguous fix","labels":["Operational","needs-clarification"]},
 {"number":2005,"title":"stuck 5c code item","labels":["Operational","funnel-escalated"]}]
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
# #2001 → drain-clarification (the F#657 headline: answer consumed, label cleared).
DC="$(action_for <<<"$PLAN" '.issue==2001 and .action=="drain-clarification"')"
[ -n "$DC" ] && ok "answered #2001 → drain-clarification (label cleared)" || bad "t12c.drain" "no drain-clarification for #2001"
jq -e '.emit | test("needs-clarification")' <<<"$DC" >/dev/null \
  && ok "drain-clarification emits the label-clear" || bad "t12c.emit" "emit missing label-clear: $(jq -r '.emit' <<<"$DC")"
# Double-emit guard: #2001 must NOT also park (it is unassigned, in both lists).
[ -z "$(action_for <<<"$PLAN" '.issue==2001 and .action=="route-already-assigned"')" ] \
  && ok "#2001 not ALSO parked (drain is authoritative, double-emit guard)" || bad "t12c.double" "#2001 both drained and parked"
[ -z "$(action_for <<<"$PLAN" '.issue==2001 and .action=="drive-ready"')" ] \
  && ok "#2001 not driven this tick (label still present until the drain applies)" || bad "t12c.drive" "drove #2001 pre-drain"
# #2005 (funnel-escalated) → route-already-assigned park, NEVER drive-ready (#697 dup-PR guard).
PK="$(action_for <<<"$PLAN" '.issue==2005 and .action=="route-already-assigned"')"
[ -n "$PK" ] && ok "5c-escalated #2005 → route-already-assigned (parked, #697)" || bad "t12c.esc-park" "no park for #2005"
jq -e '.label=="funnel-escalated"' <<<"$PK" >/dev/null \
  && ok "#2005 park carries label funnel-escalated" || bad "t12c.esc-label" "park label not funnel-escalated: $(jq -r '.label' <<<"$PK")"
[ -z "$(action_for <<<"$PLAN" '.issue==2005 and .action=="drive-ready"')" ] \
  && ok "5c-escalated #2005 NOT driven (would open a duplicate PR)" || bad "t12c.esc-drive" "drove a funnel-escalated item"
[ -z "$(action_for <<<"$PLAN" '.issue==2005 and (.action|test("drain"))')" ] \
  && ok "5c-escalated #2005 NOT drained (its own label, never in the clarification list)" || bad "t12c.esc-drain" "drained a funnel-escalated item"
# #2003 → drain-clarification-already-applied (idempotent; label drop not yet propagated).
[ -n "$(action_for <<<"$PLAN" '.issue==2003 and .action=="drain-clarification-already-applied"')" ] \
  && ok "already-acked #2003 → drain-clarification-already-applied (idempotent)" || bad "t12c.applied" "no already-applied skip for #2003"
[ -z "$(action_for <<<"$PLAN" '.issue==2003 and .action=="drain-clarification"')" ] \
  && ok "already-acked #2003 NOT re-drained" || bad "t12c.applied-redrain" "re-drained an already-applied item"
# #2004 → skip-contention (re-assigned after the drain-list read).
[ -n "$(action_for <<<"$PLAN" '.issue==2004 and .action=="skip-contention"')" ] \
  && ok "re-assigned #2004 → skip-contention" || bad "t12c.cont" "no skip-contention for #2004"
[ -z "$(action_for <<<"$PLAN" '.issue==2004 and .action=="drain-clarification"')" ] \
  && ok "re-assigned #2004 NOT drained (baton re-grabbed)" || bad "t12c.cont-drain" "drained a re-grabbed item"

# ── 13: drive-ready carries kind (spike vs code) — the rung-5b filter key (#604) ─
# funnel-drive.sh auto-executes only kind:spike drives (no PR); kind:code drives
# stay emit-only for the operator. The scheduler classifies; the driver filters on
# this field. A `spike`-labeled Operational item → kind:spike; otherwise kind:code.
echo "--- test 13: drive-ready stamps kind=spike for a spike item (#604) ---"
FX="$TMP/t13a"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1401,"title":"investigate seam","labels":["spike","Operational"]}]
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
DRIVE="$(action_for <<<"$PLAN" '.issue==1401 and .action=="drive-ready"')"
[ "$(jq -r '.kind' <<<"$DRIVE")" = "spike" ] \
  && ok "spike item → drive-ready kind=spike" || bad "t13a.kind" "got $(jq -r '.kind' <<<"$DRIVE")"

echo "--- test 13b: drive-ready stamps kind=code for a non-spike Operational item (#604) ---"
FX="$TMP/t13b"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1402,"title":"fix the thing","labels":["Operational"]}]
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
DRIVE="$(action_for <<<"$PLAN" '.issue==1402 and .action=="drive-ready"')"
[ "$(jq -r '.kind' <<<"$DRIVE")" = "code" ] \
  && ok "Operational item → drive-ready kind=code" || bad "t13b.kind" "got $(jq -r '.kind' <<<"$DRIVE")"

echo "--- test 13c: an unlabeled (default-Operational) item also stamps kind=code (#604) ---"
FX="$TMP/t13c"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1403,"title":"no labels here","labels":[]}]
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
DRIVE="$(action_for <<<"$PLAN" '.issue==1403 and .action=="drive-ready"')"
[ "$(jq -r '.kind' <<<"$DRIVE")" = "code" ] \
  && ok "unlabeled item → drive-ready kind=code" || bad "t13c.kind" "got $(jq -r '.kind' <<<"$DRIVE")"

# ── 14: a hand-off-labeled item drives in RESUME mode, not fresh (#624) ───────
# funnel-drive.sh labels an issue funnel-merge-pending when its drive opened a PR
# but the one-shot session ended before merge. The next tick must RESUME that PR
# (re-attach + merge gate), not re-drive it (which opens a duplicate PR). The
# scheduler signals this by stamping mode:resume on the drive-ready.
echo "--- test 14: funnel-merge-pending → drive-ready mode=resume (#624) ---"
FX="$TMP/t14"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1501,"title":"in-flight PR drive","labels":["Operational","funnel-merge-pending"]}]
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
DRIVE="$(action_for <<<"$PLAN" '.issue==1501 and .action=="drive-ready"')"
[ "$(jq -r '.mode' <<<"$DRIVE")" = "resume" ] \
  && ok "hand-off-labeled item → mode=resume" || bad "t14.mode" "got $(jq -r '.mode' <<<"$DRIVE")"
[ "$(jq -r '.kind' <<<"$DRIVE")" = "code" ] \
  && ok "resume drive is still kind=code (the merge tier)" || bad "t14.kind" "got $(jq -r '.kind' <<<"$DRIVE")"
jq -e '.emit | test("RESUME") and (test("/assess")|not)' <<<"$DRIVE" >/dev/null \
  && ok "resume emit says RESUME and does NOT re-/assess (no duplicate PR)" || bad "t14.emit" "got $(jq -r '.emit' <<<"$DRIVE")"

echo "--- test 14b: a plain Operational item → drive-ready mode=fresh (#624) ---"
FX="$TMP/t14b"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1502,"title":"first-time drive","labels":["Operational"]}]
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
DRIVE="$(action_for <<<"$PLAN" '.issue==1502 and .action=="drive-ready"')"
[ "$(jq -r '.mode' <<<"$DRIVE")" = "fresh" ] \
  && ok "unmarked item → mode=fresh" || bad "t14b.mode" "got $(jq -r '.mode' <<<"$DRIVE")"

echo "--- test 14c: needs-clarification OUTRANKS a resume marker (operator question first) ---"
# An item carrying BOTH funnel-merge-pending AND needs-clarification is blocked on an
# operator answer — it must park, never resume (#624 defers to the #600/#684 gate).
FX="$TMP/t14c"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1503,"title":"pending + question","labels":["Operational","funnel-merge-pending","needs-clarification"]}]
JSON
echo 0 > "$FX/board-3/assignees-1503.txt"
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ -n "$(action_for <<<"$PLAN" '.issue==1503 and .action=="route-already-assigned"')" ] \
  && ok "both labels → route-already-assigned (clarification gate precedes resume, #684)" || bad "t14c.park" "no route-already-assigned for #1503"
[ -z "$(action_for <<<"$PLAN" '.issue==1503 and .action=="drive-ready"')" ] \
  && ok "both labels → NOT driven/resumed (operator answer owed first)" || bad "t14c.drive" "resumed a needs-clarification item"

# ── 14d: a handed-off item is IN PROGRESS (claimed), not Ready — still resumed ─
# The real post-hand-off board state: the fresh drive CLAIMED the item (→ In Progress)
# and the card never left In Progress when the session died. The classifier must
# enumerate In-Progress cards carrying the marker (via the raw items.json normalizer
# path, as live) and resume them — a Ready-only scan would strand the open PR (the
# BLOCKER the reviewer caught). A normal In-Progress card (unlabeled) stays invisible.
echo "--- test 14d: In-Progress + funnel-merge-pending → resumed; unlabeled In-Progress invisible (#624) ---"
FX="$TMP/t14d"; seed_board "$FX" 3
printf '%s' '{"items":[
  {"status":"In Progress","content":{"number":1601},"title":"handed-off PR","labels":["Operational","funnel-merge-pending"]},
  {"status":"In Progress","content":{"number":1602},"title":"someone else'"'"'s active work","labels":["Operational"]}
],"totalCount":2}' > "$FX/board-3/items.json"
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
DRIVE="$(action_for <<<"$PLAN" '.issue==1601 and .action=="drive-ready"')"
[ -n "$DRIVE" ] && [ "$(jq -r '.mode' <<<"$DRIVE")" = "resume" ] \
  && ok "In-Progress + marker → drive-ready mode=resume (not stranded)" || bad "t14d.resume" "got $(jq -r '.mode // "none"' <<<"$DRIVE")"
[ -z "$(action_for <<<"$PLAN" '.issue==1602')" ] \
  && ok "unlabeled In-Progress #1602 not enumerated (another session's work)" || bad "t14d.invisible" "drove an unlabeled In-Progress item"

# ── 14e: a resume item is preferred over a fresh drive for the one-per-tick slot ─
# Finish-before-start: with both a pending (In-Progress+marker) and a fresh Ready item
# competing for the single Operational slot, the resume wins (sorted first), so an
# in-flight PR drains before a new one is opened (the MINOR priority finding).
echo "--- test 14e: resume preferred over fresh for the single drive slot (#624) ---"
FX="$TMP/t14e"; seed_board "$FX" 3
printf '%s' '{"items":[
  {"status":"Ready","content":{"number":1701},"title":"fresh work","labels":["Operational"]},
  {"status":"In Progress","content":{"number":1702},"title":"in-flight PR","labels":["Operational","funnel-merge-pending"]}
],"totalCount":2}' > "$FX/board-3/items.json"
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ "$(jq -r 'first(.actions[]|select(.action=="drive-ready")|.issue)' <<<"$PLAN")" = "1702" ] \
  && ok "the resume item (#1702) takes the slot before the fresh item" || bad "t14e.priority" "got $(jq -r 'first(.actions[]|select(.action=="drive-ready")|.issue)' <<<"$PLAN")"
[ -z "$(action_for <<<"$PLAN" '.issue==1701 and .action=="drive-ready"')" ] \
  && ok "the fresh item (#1701) waits a tick (one drive/tick)" || bad "t14e.fresh-deferred" "fresh item driven alongside the resume"

# ── 15: a standalone spike drives the SINGLETON path, never /assess --epic (#635) ─
# The 2026-06-29 #449 dead-end: a kind:spike drive-ready emitted /assess --epic, which
# refuses a single issue with no sub-issues/Contract. A spike is a Ready singleton, so
# it must route to the verdict path (build.md kind:spike / sweep singleton), not the
# epic path. A kind:code drive still emits the epic sequence (regression guard).
echo "--- test 15: a spike drive-ready routes to the singleton verdict path, not /assess --epic (#635) ---"
FX="$TMP/t15"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1801,"title":"verify Gemini Batch API pricing","labels":["Operational","spike"]}]
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
SPK="$(action_for <<<"$PLAN" '.action=="drive-ready" and .issue==1801')"
[ -n "$SPK" ] && ok "the spike is driven (drive-ready)" || bad "t15.driven" "no drive-ready for the spike"
[ "$(jq -r '.kind' <<<"$SPK")" = "spike" ] && ok "kind=spike (spike label → kind:spike)" || bad "t15.kind" "got $(jq -r '.kind' <<<"$SPK")"
# The epic path's signature is the positive `/triage --board … → /assess --epic`
# sequence; the spike emit must not carry it (it instead explicitly forbids it).
jq -e '.emit | test("/triage --board") | not' <<<"$SPK" >/dev/null \
  && ok "spike emit does NOT carry the epic /triage→/assess --epic sequence (the #635 fix)" || bad "t15.no-epic" "spike still routed through the epic path: $(jq -r '.emit' <<<"$SPK")"
jq -e '.emit | test("Do NOT run /assess")' <<<"$SPK" >/dev/null \
  && ok "spike emit explicitly forbids /assess --epic (a standalone spike is not an epic)" || bad "t15.forbid" "got $(jq -r '.emit' <<<"$SPK")"
jq -e '.emit | test("verdict")' <<<"$SPK" >/dev/null \
  && ok "spike emit names the verdict (singleton kind:spike path)" || bad "t15.verdict" "got $(jq -r '.emit' <<<"$SPK")"

# Regression guard: a kind:code drive STILL emits the epic /assess→/build sequence.
echo "--- test 15b: a kind:code drive still emits /assess --epic (unchanged) (#635) ---"
FX="$TMP/t15b"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1802,"title":"fix a parser bug","labels":["Operational"]}]
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
COD="$(action_for <<<"$PLAN" '.action=="drive-ready" and .issue==1802')"
[ "$(jq -r '.kind' <<<"$COD")" = "code" ] && ok "kind=code (no spike label)" || bad "t15b.kind" "got $(jq -r '.kind' <<<"$COD")"
jq -e '.emit | test("/assess --epic") and test("/build") and test("--unattended")' <<<"$COD" >/dev/null \
  && ok "code emit still drives the epic sequence (/assess --epic → /build --unattended)" || bad "t15b.epic" "got $(jq -r '.emit' <<<"$COD")"

# ── 16: per-tick DRIVE CAP — FUNNEL_DRIVE_CAP gates Operational emits (#642) ──
# The cap was a hardcoded one-per-tick (test 2). It is now the FUNNEL_DRIVE_CAP
# counter, fed from the vault `cap:` by the cron. Default (unset) stays 1; setting
# it to 3 lets a single tick emit up to 3 Operational drives. Foundational routing
# is unaffected (it is routed, not driven, so it stays one-per-tick).
echo "--- test 16: FUNNEL_DRIVE_CAP=3 emits up to 3 Operational drives ---"
FX="$TMP/t16"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1601,"title":"bug a","labels":["Operational"]},
 {"number":1602,"title":"bug b","labels":["Operational"]},
 {"number":1603,"title":"bug c","labels":["Operational"]},
 {"number":1604,"title":"bug d","labels":["Operational"]},
 {"number":1605,"title":"feature a","labels":["Foundational"]},
 {"number":1606,"title":"feature b","labels":["Foundational"]}]
JSON
PLAN="$(FUNNEL_DRIVE_CAP=3 bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ "$(jq '[.actions[]|select(.action=="drive-ready")]|length' <<<"$PLAN")" = "3" ] \
  && ok "cap=3 → exactly 3 Operational drives" || bad "t16.cap3" "got $(jq '[.actions[]|select(.action=="drive-ready")]|length' <<<"$PLAN")"
[ "$(jq '[.actions[]|select(.action=="route-foundational")]|length' <<<"$PLAN")" = "1" ] \
  && ok "cap does not affect Foundational routing (still 1)" || bad "t16.found" "got $(jq '[.actions[]|select(.action=="route-foundational")]|length' <<<"$PLAN")"
# The drives are the first three Ready Operational items, in order.
[ "$(jq -c '[.actions[]|select(.action=="drive-ready")|.issue]' <<<"$PLAN")" = "[1601,1602,1603]" ] \
  && ok "drives the first 3 Operational items in order" || bad "t16.order" "got $(jq -c '[.actions[]|select(.action=="drive-ready")|.issue]' <<<"$PLAN")"

echo "--- test 16b: cap clamps to the number of Operational items available ---"
FX="$TMP/t16b"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1611,"title":"bug a","labels":["Operational"]},
 {"number":1612,"title":"bug b","labels":["Operational"]}]
JSON
PLAN="$(FUNNEL_DRIVE_CAP=3 bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ "$(jq '[.actions[]|select(.action=="drive-ready")]|length' <<<"$PLAN")" = "2" ] \
  && ok "cap=3 with 2 items → 2 drives (clamps, no over-emit)" || bad "t16b.clamp" "got $(jq '[.actions[]|select(.action=="drive-ready")]|length' <<<"$PLAN")"

echo "--- test 16c: default cap (unset) stays one-per-tick (behavior unchanged) ---"
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ "$(jq '[.actions[]|select(.action=="drive-ready")]|length' <<<"$PLAN")" = "1" ] \
  && ok "no FUNNEL_DRIVE_CAP → 1 drive (default preserved)" || bad "t16c.default" "got $(jq '[.actions[]|select(.action=="drive-ready")]|length' <<<"$PLAN")"

echo "--- test 16d: spikes count toward the cap (mixed spike+code emits) ---"
FX="$TMP/t16d"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1621,"title":"spike a","labels":["Operational","spike"]},
 {"number":1622,"title":"code b","labels":["Operational"]},
 {"number":1623,"title":"spike c","labels":["Operational","spike"]},
 {"number":1624,"title":"code d","labels":["Operational"]}]
JSON
PLAN="$(FUNNEL_DRIVE_CAP=2 bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ "$(jq '[.actions[]|select(.action=="drive-ready")]|length' <<<"$PLAN")" = "2" ] \
  && ok "cap=2 → 2 drives regardless of kind (spike+code both count)" || bad "t16d.mixed" "got $(jq '[.actions[]|select(.action=="drive-ready")]|length' <<<"$PLAN")"
[ "$(jq -c '[.actions[]|select(.action=="drive-ready")|.issue]' <<<"$PLAN")" = "[1621,1622]" ] \
  && ok "first 2 items emitted (a spike then a code)" || bad "t16d.order" "got $(jq -c '[.actions[]|select(.action=="drive-ready")|.issue]' <<<"$PLAN")"

# ── 17: crash-signal intake phase (foundation #671, epic #637) ───────────────
# /signal-intake is wired in as a Phase 0 pre-gate: it must run BEFORE the
# tick's spend decisions (Phase A's drain loop, Phase B/C's FUNNEL_DRIVE_CAP
# gate), on EVERY tick (spend-open or spend-closed), and a failure must be
# caught + logged without ever blocking the rest of the tick.

echo "--- test 17a: intake call is code-inspectably BEFORE the spend-gate (drive-cap) block ---"
INTAKE_LINE="$(grep -n 'run_intake_phase "\$board"' "$TICK" | head -1 | cut -d: -f1)"
DRAIN_LINE="$(grep -n 'Phase A — drain answered' "$TICK" | head -1 | cut -d: -f1)"
GATE_LINE="$(grep -n 'did_op" -lt "\$FUNNEL_DRIVE_CAP"' "$TICK" | head -1 | cut -d: -f1)"
[ -n "$INTAKE_LINE" ] && ok "intake call site found (line $INTAKE_LINE)" || bad "t17a.found" "run_intake_phase call not found in $TICK"
[ "$INTAKE_LINE" -lt "$DRAIN_LINE" ] \
  && ok "intake (L$INTAKE_LINE) is before Phase A drain (L$DRAIN_LINE)" || bad "t17a.before-drain" "intake L$INTAKE_LINE not before drain L$DRAIN_LINE"
[ "$INTAKE_LINE" -lt "$GATE_LINE" ] \
  && ok "intake (L$INTAKE_LINE) is before the FUNNEL_DRIVE_CAP spend-gate block (L$GATE_LINE)" \
  || bad "t17a.before-gate" "intake L$INTAKE_LINE not before drive-cap gate L$GATE_LINE"

echo "--- test 17b: intake failure is caught + logged, tick proceeds (non-blocking) ---"
FX="$TMP/t17b"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1901,"title":"unrelated bug","labels":["Operational"]}]
JSON
FAIL_STUB="$TMP/intake-fail.sh"
cat > "$FAIL_STUB" <<'SH'
#!/usr/bin/env bash
echo "boom: simulated signal-intake failure" >&2
exit 3
SH
chmod +x "$FAIL_STUB"
ERR17B="$TMP/t17b.err"
PLAN="$(FUNNEL_INTAKE_CMD="$FAIL_STUB" bash "$TICK" --dry-run --fixture "$FX" --board 3 2>"$ERR17B")"
grep -q "signal-intake failed for board 3" "$ERR17B" \
  && ok "intake failure logged to stderr (non-blocking)" || bad "t17b.logged" "no failure message in stderr: $(cat "$ERR17B")"
grep -q "boom: simulated signal-intake failure" "$ERR17B" \
  && ok "the underlying intake error text is surfaced" || bad "t17b.errtext" "stub error text missing from log: $(cat "$ERR17B")"
[ "$(jq -r 'first(.actions[]|select(.action=="drive-ready")|.issue)' <<<"$PLAN")" = "1901" ] \
  && ok "tick still drove Ready work despite intake failure (non-blocking)" || bad "t17b.proceeded" "tick did not proceed: $PLAN"

echo "--- test 17c: intake runs on every tick — spend-open AND spend-closed ---"
MARKER="$TMP/intake-invoked.log"
: > "$MARKER"
RECORD_STUB="$TMP/intake-record.sh"
cat > "$RECORD_STUB" <<SH
#!/usr/bin/env bash
echo "invoked board=\$3" >> "$MARKER"
exit 0
SH
chmod +x "$RECORD_STUB"
# Spend-open: a Ready Operational item drives this tick.
FX="$TMP/t17c-open"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1902,"title":"driven this tick","labels":["Operational"]}]
JSON
PLAN_OPEN="$(FUNNEL_INTAKE_CMD="$RECORD_STUB" bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ -n "$(action_for <<<"$PLAN_OPEN" '.action=="drive-ready"')" ] \
  && ok "spend-open tick drove work (sanity check)" || bad "t17c.open-drove" "expected a drive-ready action"
# Spend-closed: nothing to drain/drive/route (a clean no-op tick).
FX="$TMP/t17c-closed"; seed_board "$FX" 3
PLAN_CLOSED="$(FUNNEL_INTAKE_CMD="$RECORD_STUB" bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ "$(jq -r 'first(.actions[].action)' <<<"$PLAN_CLOSED")" = "no-op" ] \
  && ok "spend-closed tick is a clean no-op (sanity check)" || bad "t17c.closed-noop" "got $PLAN_CLOSED"
[ "$(wc -l < "$MARKER" | tr -d ' ')" = "2" ] \
  && ok "intake invoked exactly once per tick, on BOTH the spend-open and spend-closed tick" \
  || bad "t17c.count" "expected 2 intake invocations, got: $(cat "$MARKER")"

echo "--- test 17d: dry-run purity — default FUNNEL_INTAKE_CMD is never spawned under --dry-run ---"
# Without an override, a --dry-run tick must never touch the real
# signal-intake.sh (which hits Sentry/gh) — it stays offline like every other
# fixture test. Proven negatively: no stderr noise and a clean plan, matching
# tests 1-16 which never set FUNNEL_INTAKE_CMD and still pass with zero network.
FX="$TMP/t17d"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1903,"title":"plain drive","labels":["Operational"]}]
JSON
ERR17D="$TMP/t17d.err"
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3 2>"$ERR17D")"
[ ! -s "$ERR17D" ] \
  && ok "no stderr noise on a default (unoverridden) dry-run tick — real intake never spawned" \
  || bad "t17d.quiet" "unexpected stderr: $(cat "$ERR17D")"
[ "$(jq -r 'first(.actions[]|select(.action=="drive-ready")|.issue)' <<<"$PLAN")" = "1903" ] \
  && ok "tick still functions normally with intake at its default" || bad "t17d.normal" "got $PLAN"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ F#641 — the hand-off MARKER (funnel-merge-pending) drives the resume-vs-    │
# │ fresh decision, but funnel-drive.sh's `--add-label` can FAIL silently. When │
# │ it does, the item looks fresh → a fresh re-drive opens a DUPLICATE PR. The  │
# │ fresh kind:code path now ALSO consults a ground-truth open-PR probe, so a   │
# │ lost marker is recovered to a resume instead of duplicating the PR.          │
# ╰──────────────────────────────────────────────────────────────────────────╯

echo "--- test 18a: kind:code, NO marker but an OPEN PR closes it → resume (recovered), not fresh (#641) ---"
FX="$TMP/t18a"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1801,"title":"mid-merge item whose hand-off label was lost","labels":["Operational"]}]
JSON
echo 857 > "$FX/board-3/open-pr-1801.txt"   # ground truth: open PR #857 closes #1801
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
D18A="$(action_for <<<"$PLAN" '.issue==1801 and .action=="drive-ready"')"
[ "$(jq -r '.mode' <<<"$D18A")" = "resume" ] && ok "mode=resume (recovered from ground truth, not re-driven fresh)" || bad "t18a.mode" "got $(jq -r '.mode' <<<"$D18A")"
[ "$(jq -r '.recovered_pr' <<<"$D18A")" = "857" ] && ok "recovered_pr=857 (the open PR the probe found)" || bad "t18a.pr" "got $(jq -r '.recovered_pr' <<<"$D18A")"
jq -e '.emit | test("Do NOT re-assess or open a new PR")' <<<"$D18A" >/dev/null \
  && ok "emit tells the driver to resume, not open a duplicate PR" || bad "t18a.emit" "got $(jq -r '.emit' <<<"$D18A")"

echo "--- test 18b: kind:code, NO marker and NO open PR → genuinely fresh (no regression) ---"
FX="$TMP/t18b"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1802,"title":"a truly fresh operational item","labels":["Operational"]}]
JSON
# no open-pr fixture → probe returns empty → fresh
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
D18B="$(action_for <<<"$PLAN" '.issue==1802 and .action=="drive-ready"')"
[ "$(jq -r '.mode' <<<"$D18B")" = "fresh" ] && ok "mode=fresh (no PR exists → drive fresh, unchanged)" || bad "t18b.mode" "got $(jq -r '.mode' <<<"$D18B")"
jq -e '.emit | test("/assess") and test("/build")' <<<"$D18B" >/dev/null \
  && ok "fresh emit still runs the /assess→/build pipeline" || bad "t18b.emit" "got $(jq -r '.emit' <<<"$D18B")"

echo "--- test 18c: marker PRESENT → resume via the marker, no ground-truth probe needed (no regression) ---"
FX="$TMP/t18c"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1803,"title":"item still carrying the hand-off marker","labels":["Operational","funnel-merge-pending"]}]
JSON
# Deliberately NO open-pr fixture: if the marker path is taken, the probe is never
# consulted, so resume must still fire off the label alone.
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
D18C="$(action_for <<<"$PLAN" '.issue==1803 and .action=="drive-ready"')"
[ "$(jq -r '.mode' <<<"$D18C")" = "resume" ] && ok "mode=resume off the marker (label path unchanged)" || bad "t18c.mode" "got $(jq -r '.mode' <<<"$D18C")"
[ "$(jq -r '.label' <<<"$D18C")" = "funnel-merge-pending" ] && ok "resume carries the marker label (the #624 path, not the #641 recovery)" || bad "t18c.label" "got $(jq -r '.label' <<<"$D18C")"

# ── 19: a bare kind:code singleton drives the /sweep per-issue path, not /assess --epic (#717) ─
# The kind:code sibling of #635 (test 15). A fresh kind:code drive-ready that is a BARE
# Ready singleton — 0 sub-issues AND no `## Contract` — must NOT emit /assess --epic (it
# refuses a single issue with no sub-issues/Contract → guaranteed no-op that burns the 5c
# merge cap). It routes to /sweep's per-issue build path SCOPED to the one issue. A code
# item WITH sub-issues, or WITH a `## Contract`, is a genuine epic and still takes the
# epic sequence (regression guard). The bare-singleton probe reads a `singleton-<n>.json`
# fixture (the raw issue object); absent → fail-OPEN to the epic route.
echo "--- test 19a: a bare kind:code singleton routes to the /sweep per-issue path, not /assess --epic (#717) ---"
FX="$TMP/t19a"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1901,"title":"fix a bare singleton parser bug","labels":["Operational"]}]
JSON
cat > "$FX/board-3/singleton-1901.json" <<'JSON'
{"number":1901,"sub_issues_summary":{"total":0},"body":"Just a bug. No contract here."}
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
SNG="$(action_for <<<"$PLAN" '.action=="drive-ready" and .issue==1901')"
[ -n "$SNG" ] && ok "the bare code singleton is driven (drive-ready)" || bad "t19a.driven" "no drive-ready for #1901"
[ "$(jq -r '.kind' <<<"$SNG")" = "code" ] && ok "kind=code (no spike label)" || bad "t19a.kind" "got $(jq -r '.kind' <<<"$SNG")"
[ "$(jq -r '.route' <<<"$SNG")" = "singleton-code" ] && ok "route=singleton-code (0 sub-issues, no ## Contract)" || bad "t19a.route" "got $(jq -r '.route' <<<"$SNG")"
jq -e '.emit | test("/triage --board") | not' <<<"$SNG" >/dev/null \
  && ok "singleton emit does NOT carry the epic /triage→/assess --epic sequence (the #717 fix)" || bad "t19a.no-epic" "singleton still routed through the epic path: $(jq -r '.emit' <<<"$SNG")"
jq -e '.emit | test("Do NOT run /assess")' <<<"$SNG" >/dev/null \
  && ok "singleton emit explicitly forbids /assess --epic" || bad "t19a.forbid" "got $(jq -r '.emit' <<<"$SNG")"
jq -e '.emit | test("per-issue") and test("SCOPED")' <<<"$SNG" >/dev/null \
  && ok "singleton emit names the /sweep per-issue path SCOPED to the one issue" || bad "t19a.scoped" "got $(jq -r '.emit' <<<"$SNG")"
jq -e '.emit | test("whole"; "i")' <<<"$SNG" >/dev/null \
  && ok "singleton emit warns against a whole-pool /sweep" || bad "t19a.no-whole" "got $(jq -r '.emit' <<<"$SNG")"

echo "--- test 19b: a kind:code item WITH sub-issues is a real epic → still /assess --epic (#717 guard) ---"
FX="$TMP/t19b"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1902,"title":"an epic parent with children","labels":["Operational"]}]
JSON
cat > "$FX/board-3/singleton-1902.json" <<'JSON'
{"number":1902,"sub_issues_summary":{"total":3},"body":"Epic body, has sub-issues."}
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
EPC="$(action_for <<<"$PLAN" '.action=="drive-ready" and .issue==1902')"
[ "$(jq -r '.route' <<<"$EPC")" = "epic" ] && ok "route=epic (has 3 sub-issues → genuine epic)" || bad "t19b.route" "got $(jq -r '.route' <<<"$EPC")"
jq -e '.emit | test("/triage --board") and test("/assess --epic") and test("/build")' <<<"$EPC" >/dev/null \
  && ok "epic emit still drives the /triage→/assess --epic→/build sequence" || bad "t19b.epic" "got $(jq -r '.emit' <<<"$EPC")"

echo "--- test 19c: a kind:code item WITH a ## Contract body is a pre-designed epic → still /assess --epic (#717 guard) ---"
FX="$TMP/t19c"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1903,"title":"a pre-designed undecomposed epic","labels":["Operational"]}]
JSON
cat > "$FX/board-3/singleton-1903.json" <<'JSON'
{"number":1903,"sub_issues_summary":{"total":0},"body":"Intro.\n\n## Contract\nProduces: an adapter.\nConsumes: the schema."}
JSON
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
CON="$(action_for <<<"$PLAN" '.action=="drive-ready" and .issue==1903')"
[ "$(jq -r '.route' <<<"$CON")" = "epic" ] && ok "route=epic (0 sub-issues but a ## Contract → /assess decomposes it)" || bad "t19c.route" "got $(jq -r '.route' <<<"$CON")"
jq -e '.emit | test("/assess --epic")' <<<"$CON" >/dev/null \
  && ok "## Contract item still routes to /assess --epic (the #526 seam)" || bad "t19c.epic" "got $(jq -r '.emit' <<<"$CON")"

echo "--- test 19d: fail-OPEN — no singleton probe fixture → epic route (never mis-routes an unknown to /sweep) (#717) ---"
FX="$TMP/t19d"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":1904,"title":"a code item the probe cannot resolve","labels":["Operational"]}]
JSON
# Deliberately NO singleton-1904.json fixture: the probe fails to resolve → fail-open.
PLAN="$(bash "$TICK" --dry-run --fixture "$FX" --board 3)"
FO="$(action_for <<<"$PLAN" '.action=="drive-ready" and .issue==1904')"
[ "$(jq -r '.route' <<<"$FO")" = "epic" ] && ok "route=epic on an unresolvable probe (fail-open keeps current behavior)" || bad "t19d.route" "got $(jq -r '.route' <<<"$FO")"
jq -e '.emit | test("/assess --epic")' <<<"$FO" >/dev/null \
  && ok "fail-open emit is the epic sequence (a real epic is never silently sent to /sweep)" || bad "t19d.epic" "got $(jq -r '.emit' <<<"$FO")"

# ── 20: boards.conf registry seam (foundation #770) — tick_board_repo honors an override ──
# tick_board_repo is the dry-path mirror of board.sh's board_repo() (the
# "inline the same map so the dry path needs no adapter sourcing" seam). #770
# taught it to resolve an optional boards.conf FIRST, falling back to the
# byte-identical built-in map when no conf exists. Board 999 is otherwise
# UNMAPPED (not in the built-in case map), so a successful tick against it is
# only possible when the conf resolves its repo — a clean positive assertion
# that also surfaces the resolved repo directly in the plan JSON's `repo` field.
echo "--- test 20: tick_board_repo resolves an unmapped board's repo from a repo-local boards.conf override ---"
FX="$TMP/t20"; seed_board "$FX" 999
CONF20="$TMP/t20-boards.conf"
cat > "$CONF20" <<'EOF'
board.999.repo=Conf/tick-override
EOF
PLAN20="$(FUNNEL_ENABLED_BOARDS="999" BOARDS_CONF_REPO_LOCAL="$CONF20" \
          bash "$TICK" --board 999 --dry-run --fixture "$FX")"
[ "$(jq -r '.tick' <<<"$PLAN20")" = "done" ] && ok "tick completes for an otherwise-unmapped board once boards.conf resolves its repo" || bad "t20.tick" "got $(jq -r '.tick' <<<"$PLAN20")"
[ "$(jq -r '.actions[0].repo' <<<"$PLAN20")" = "Conf/tick-override" ] && ok "resolved repo is the boards.conf value, not a built-in guess" || bad "t20.repo" "got $(jq -r '.actions[0].repo' <<<"$PLAN20")"

echo "--- test 20b: with NO boards.conf, an unmapped board still fails exactly as before (#770 byte-identical fallback) ---"
FX="$TMP/t20b"; seed_board "$FX" 999
ERR20B="$(FUNNEL_ENABLED_BOARDS="999" \
          BOARDS_CONF_REPO_LOCAL="$TMP/no-such-boards.conf" BOARDS_CONF_MACHINE="$TMP/no-such-machine.conf" \
          bash "$TICK" --board 999 --dry-run --fixture "$FX" 2>&1 1>/dev/null || true)"
[ "$ERR20B" = "funnel-tick.sh: unknown board 999" ] && ok "no conf → unmapped board still errors byte-identically to pre-#770" || bad "t20b.err" "got: $ERR20B"

# ── 21: route-foundational guard correctness (epic #970) + bare-login strip (#977) ──
# 21a/21b: the already-decision-gated re-route guard (#834/#1002/#1009). A Ready
# Foundational item that already carries `decision` AND an operator assignee was
# routed by a prior tick and is parked awaiting the operator's reply — re-emitting
# route-foundational re-runs /assess and mints a duplicate plan note + gate comment
# every tick. Park it (route-already-assigned) instead. The `decision` label ALONE
# is not enough: an UNASSIGNED decision item is an answered one Phase A drains, so
# the guard requires assignees>0 (21b proves it does NOT swallow the unassigned case).
echo "--- test 21a: already-decision-gated Foundational (decision + assignee>0) → route-already-assigned, NOT route-foundational (#834/#1002/#1009) ---"
FX="$TMP/t21a"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":7001,"title":"already-gated epic parked in the decision queue","labels":["Foundational","decision"]}]
JSON
echo 1 > "$FX/board-3/assignees-7001.txt"
PLAN="$(BUILD_CONFIG_LOCAL="$TMP/no-local.sh" bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ -n "$(action_for <<<"$PLAN" '.issue==7001 and .action=="route-already-assigned" and .label=="decision"')" ] \
  && ok "assigned decision item #7001 → route-already-assigned (label:decision)" || bad "t21a.park" "no route-already-assigned(decision) for #7001"
[ -z "$(action_for <<<"$PLAN" '.issue==7001 and .action=="route-foundational"')" ] \
  && ok "#7001 NOT re-routed as route-foundational (no duplicate /assess/plan-note)" || bad "t21a.reroute" "re-routed an already-gated decision item"

echo "--- test 21b: decision label but UNASSIGNED (assignee=0) → NOT parked by the decision guard; still routed (guard requires assignees>0) ---"
FX="$TMP/t21b"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":7002,"title":"decision-labeled but unassigned","labels":["Foundational","decision"]}]
JSON
echo 0 > "$FX/board-3/assignees-7002.txt"
PLAN="$(BUILD_CONFIG_LOCAL="$TMP/no-local.sh" bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ -z "$(action_for <<<"$PLAN" '.issue==7002 and .action=="route-already-assigned"')" ] \
  && ok "unassigned decision #7002 NOT parked by the decision guard (assignees=0)" || bad "t21b.park" "wrongly parked an unassigned decision item"
[ -n "$(action_for <<<"$PLAN" '.issue==7002 and .action=="route-foundational"')" ] \
  && ok "unassigned decision #7002 still route-foundational (Phase A owns the answered case)" || bad "t21b.route" "no route-foundational for unassigned decision #7002"

# 21c/21d: the bare-Foundational direct-route split (#720). A bare Foundational
# decision (0 sub-issues AND no `## Contract`) has nothing for /assess to decompose —
# the prep step fails every tick — so route it STRAIGHT to the decision queue
# (mode:direct). A genuine epic (sub-issues or a `## Contract`) keeps the prep path.
echo "--- test 21c: bare Foundational (0 sub-issues, no ## Contract) → route-foundational mode:direct (#720) ---"
FX="$TMP/t21c"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":7003,"title":"a bare foundational decision","labels":["Foundational"]}]
JSON
cat > "$FX/board-3/singleton-7003.json" <<'JSON'
{"number":7003,"sub_issues_summary":{"total":0},"body":"Just a decision. Nothing to decompose."}
JSON
PLAN="$(BUILD_CONFIG_LOCAL="$TMP/no-local.sh" bash "$TICK" --dry-run --fixture "$FX" --board 3)"
FND="$(action_for <<<"$PLAN" '.issue==7003 and .action=="route-foundational"')"
[ "$(jq -r '.mode' <<<"$FND")" = "direct" ] && ok "bare Foundational #7003 → mode:direct" || bad "t21c.mode" "got mode=$(jq -r '.mode' <<<"$FND")"
jq -e '.emit | test("STRAIGHT to the decision queue") and test("NO /assess prep")' <<<"$FND" >/dev/null \
  && ok "direct emit routes straight to the queue, skips /assess prep" || bad "t21c.emit" "got $(jq -r '.emit' <<<"$FND")"

echo "--- test 21d: epic Foundational (has sub-issues) → route-foundational mode:prep (unchanged) (#720 guard) ---"
FX="$TMP/t21d"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":7004,"title":"a genuine foundational epic","labels":["Foundational"]}]
JSON
cat > "$FX/board-3/singleton-7004.json" <<'JSON'
{"number":7004,"sub_issues_summary":{"total":2},"body":"Epic with children to decompose."}
JSON
PLAN="$(BUILD_CONFIG_LOCAL="$TMP/no-local.sh" bash "$TICK" --dry-run --fixture "$FX" --board 3)"
FND="$(action_for <<<"$PLAN" '.issue==7004 and .action=="route-foundational"')"
[ "$(jq -r '.mode' <<<"$FND")" = "prep" ] && ok "epic Foundational #7004 → mode:prep" || bad "t21d.mode" "got mode=$(jq -r '.mode' <<<"$FND")"
jq -e '.emit | test("prep #") and test("/assess")' <<<"$FND" >/dev/null \
  && ok "prep emit still decomposes via /assess" || bad "t21d.emit" "got $(jq -r '.emit' <<<"$FND")"

# 21e/21f: the bare-login assignee strip on route-foundational's reassign_to (#977).
# GitHub's replaceActorsForAssignable rejects an `@`-prefixed login (`@towhead`), but
# the special `@me` token must be PRESERVED (gh resolves it to the authenticated user).
echo "--- test 21e: route-foundational reassign_to is bared (@towhead → towhead) (#977) ---"
FX="$TMP/t21e"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":7005,"title":"foundational needing an operator baton","labels":["Foundational"]}]
JSON
PLAN="$(FUNNEL_OPERATOR=@towhead BUILD_CONFIG_LOCAL="$TMP/no-local.sh" bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ "$(jq -r 'first(.actions[]|select(.action=="route-foundational")|.reassign_to)' <<<"$PLAN")" = "towhead" ] \
  && ok "route-foundational reassign_to bared to 'towhead' (#977)" || bad "t21e.bare" "got $(jq -r 'first(.actions[]|select(.action=="route-foundational")|.reassign_to)' <<<"$PLAN")"

echo "--- test 21f: the literal @me token is PRESERVED, not stripped to a non-user 'me' (#977) ---"
FX="$TMP/t21f"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":7006,"title":"foundational under an @me operator","labels":["Foundational"]}]
JSON
cat > "$FX/board-3/decisions.json" <<'JSON'
[{"number":7007,"title":"unparseable","body":"x","assignees":[],
  "comments":[{"createdAt":"2026-06-24T11:00:00Z","body":"meh, whatever you think"}]}]
JSON
echo 0 > "$FX/board-3/assignees-7007.txt"
PLAN="$(FUNNEL_OPERATOR=@me BUILD_CONFIG_LOCAL="$TMP/no-local.sh" bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ "$(jq -r 'first(.actions[]|select(.action=="route-foundational")|.reassign_to)' <<<"$PLAN")" = "@me" ] \
  && ok "route-foundational reassign_to preserves @me" || bad "t21f.route" "got $(jq -r 'first(.actions[]|select(.action=="route-foundational")|.reassign_to)' <<<"$PLAN")"
[ "$(jq -r 'first(.actions[]|select(.action=="drain-parse-miss")|.reassign_to)' <<<"$PLAN")" = "@me" ] \
  && ok "drain-parse-miss reassign_to preserves @me" || bad "t21f.miss" "got $(jq -r 'first(.actions[]|select(.action=="drain-parse-miss")|.reassign_to)' <<<"$PLAN")"

# ── 22: intake config-absent WARN (temperloop#330) ───────────────────────────
# The intake pre-gate (run_intake_phase) used to invoke FUNNEL_INTAKE_CMD and
# swallow the outcome — a MISSING backend or an UNSET/placeholder Sentry
# credential made it silently no-op (observed no-op'ing ~19h unnoticed). It must
# now surface ONE operator-visible WARN naming the reason, deduped ACROSS ticks
# (each tick is a fresh process) via a per-board on-disk marker so it fires once
# per condition, not once per poll — and must never regress the config-present path.
# Isolation: a fresh FUNNEL_INTAKE_WARN_DIR per test + neutralized config-file
# rungs so a real build.config.{machine,local}.sh on the host cannot inject a token.
NOLOCAL="$TMP/no-local.sh"; NOMACHINE="$TMP/no-machine.sh"   # non-existent → sourced as no-ops
PLACEHOLDER="REPLACE_WITH_READ_SCOPED_TOKEN"                 # the example-template placeholder value

echo "--- test 22a: missing backend → one WARN naming the reason, tick still proceeds, not per-tick spam ---"
FX="$TMP/t22a"; seed_board "$FX" 3
cat > "$FX/board-3/ready.json" <<'JSON'
[{"number":2201,"title":"drivable work","labels":["Operational"]}]
JSON
WARNDIR="$TMP/warn22a"; ERR="$TMP/t22a.err"; : > "$ERR"
MISSING="$TMP/does-not-exist-intake.sh"   # never created → not executable → condition 1
for _ in 1 2; do   # two ticks, same condition — the WARN must appear EXACTLY ONCE
  FUNNEL_INTAKE_CMD="$MISSING" FUNNEL_INTAKE_WARN_DIR="$WARNDIR" \
    BUILD_CONFIG_LOCAL="$NOLOCAL" BUILD_CONFIG_MACHINE="$NOMACHINE" \
    bash "$TICK" --dry-run --fixture "$FX" --board 3 2>>"$ERR" >/dev/null
done
WC="$(grep -c 'WARN — signal-intake config absent for board 3' "$ERR" | tr -d ' ')"
[ "$WC" = "1" ] && ok "backend-missing WARN emitted exactly once across two ticks" || bad "t22a.once" "expected 1, got $WC: $(cat "$ERR")"
grep -q "backend script not found or not executable" "$ERR" \
  && ok "the WARN names the reason (backend not found/executable)" || bad "t22a.reason" "reason missing: $(cat "$ERR")"
PLAN="$(FUNNEL_INTAKE_CMD="$MISSING" FUNNEL_INTAKE_WARN_DIR="$WARNDIR" BUILD_CONFIG_LOCAL="$NOLOCAL" BUILD_CONFIG_MACHINE="$NOMACHINE" bash "$TICK" --dry-run --fixture "$FX" --board 3 2>/dev/null)"
[ "$(jq -r 'first(.actions[]|select(.action=="drive-ready")|.issue)' <<<"$PLAN")" = "2201" ] \
  && ok "tick still drives Ready work despite the missing backend (non-blocking)" || bad "t22a.proceed" "got $PLAN"

echo "--- test 22b: backend present but Sentry credential absent → WARN once, backend STILL invoked ---"
FX="$TMP/t22b"; seed_board "$FX" 3
INVLOG="$TMP/t22b-invoked.log"; : > "$INVLOG"
STUB="$TMP/t22b-intake.sh"
cat > "$STUB" <<SH
#!/usr/bin/env bash
echo invoked >> "$INVLOG"
exit 0
SH
chmod +x "$STUB"
WARNDIR="$TMP/warn22b"; ERR="$TMP/t22b.err"; : > "$ERR"
for _ in 1 2; do   # placeholder token (non-empty → survives any conf `:=`) simulates "absent"
  SENTRY_AUTH_TOKEN="$PLACEHOLDER" FUNNEL_INTAKE_CMD="$STUB" FUNNEL_INTAKE_WARN_DIR="$WARNDIR" \
    BUILD_CONFIG_LOCAL="$NOLOCAL" BUILD_CONFIG_MACHINE="$NOMACHINE" \
    bash "$TICK" --dry-run --fixture "$FX" --board 3 2>>"$ERR" >/dev/null
done
WC="$(grep -c 'WARN — signal-intake config absent for board 3' "$ERR" | tr -d ' ')"
[ "$WC" = "1" ] && ok "credential-absent WARN emitted exactly once across two ticks" || bad "t22b.once" "expected 1, got $WC: $(cat "$ERR")"
grep -q "SENTRY_AUTH_TOKEN unset or still the example placeholder" "$ERR" \
  && ok "the WARN names the reason (SENTRY_AUTH_TOKEN absent)" || bad "t22b.reason" "reason missing: $(cat "$ERR")"
[ "$(wc -l < "$INVLOG" | tr -d ' ')" = "2" ] \
  && ok "backend STILL invoked both ticks despite the WARN (best-effort, non-skipping)" || bad "t22b.invoked" "expected 2, got $(cat "$INVLOG")"

echo "--- test 22c: credential present → NO WARN (config-present path unchanged) ---"
FX="$TMP/t22c"; seed_board "$FX" 3
STUB="$TMP/t22c-intake.sh"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$STUB"
WARNDIR="$TMP/warn22c"; ERR="$TMP/t22c.err"; : > "$ERR"
SENTRY_AUTH_TOKEN="a-real-read-scoped-token" FUNNEL_INTAKE_CMD="$STUB" FUNNEL_INTAKE_WARN_DIR="$WARNDIR" \
  BUILD_CONFIG_LOCAL="$NOLOCAL" BUILD_CONFIG_MACHINE="$NOMACHINE" \
  bash "$TICK" --dry-run --fixture "$FX" --board 3 2>"$ERR" >/dev/null
[ ! -s "$ERR" ] && ok "no WARN when the credential is present (no spurious noise)" || bad "t22c.quiet" "unexpected stderr: $(cat "$ERR")"

echo "--- test 22d: recovery clears the marker → a later re-absence WARNS again (once-per-condition, not once-ever) ---"
FX="$TMP/t22d"; seed_board "$FX" 3
STUB="$TMP/t22d-intake.sh"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$STUB"
WARNDIR="$TMP/warn22d"; ERR="$TMP/t22d.err"; : > "$ERR"
run22d() { SENTRY_AUTH_TOKEN="$1" FUNNEL_INTAKE_CMD="$STUB" FUNNEL_INTAKE_WARN_DIR="$WARNDIR" \
  BUILD_CONFIG_LOCAL="$NOLOCAL" BUILD_CONFIG_MACHINE="$NOMACHINE" \
  bash "$TICK" --dry-run --fixture "$FX" --board 3 2>>"$ERR" >/dev/null; }
run22d "$PLACEHOLDER"                 # absent → WARN
run22d "$PLACEHOLDER"                 # absent → deduped (no WARN)
run22d "a-real-read-scoped-token"     # present → clears the marker, no WARN
run22d "$PLACEHOLDER"                 # absent AGAIN → WARN again
WC="$(grep -c 'WARN — signal-intake config absent for board 3' "$ERR" | tr -d ' ')"
[ "$WC" = "2" ] && ok "WARN fires again after a recovery (2 total: initial + post-recovery)" || bad "t22d.recover" "expected 2, got $WC: $(cat "$ERR")"

# ── Phase R: retro-judge trigger (epic #528, temperloop#535) ─────────────────
# THIN trigger: urgency was decided at MINT (#533), not here — the only
# threshold this phase applies is the RETRO_MIN_INTERVAL debounce on the
# oldest `retro-pending` tracker's age, unconditionally bypassed by a
# `retro-urgent` tracker. Portable epoch<->ISO helpers (mirrors funnel-tick.sh's
# own GNU-then-BSD dialect guard) so these tests are deterministic regardless
# of host and independent of any real machine build.config: every run below
# pins BUILD_CONFIG_LOCAL/BUILD_CONFIG_MACHINE at the non-existent no-op files.
_t_epoch_to_iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}
RNOW=1700000000                      # a fixed, arbitrary "now" — never wall-clock
ROLD="$(_t_epoch_to_iso $((RNOW - 1000000)))"   # ~11.5 days old — past the default 3-day debounce
RFRESH="$(_t_epoch_to_iso $((RNOW - 10)))"       # 10s old — nowhere near the debounce

echo "--- test 23: /retro declared + a tracker past RETRO_MIN_INTERVAL -> exactly ONE retro-judge ---"
FX="$TMP/t23"; seed_board "$FX" 3
cat > "$FX/board-3/retro-trackers.json" <<JSON
[{"number":901,"title":"Process retro: epic #800","createdAt":"$ROLD","labels":["retro-pending"]}]
JSON
PLAN="$(COMMAND_DECLARED_OVERRIDE="retro" FUNNEL_NOW_EPOCH="$RNOW" \
  BUILD_CONFIG_LOCAL="$NOLOCAL" BUILD_CONFIG_MACHINE="$NOMACHINE" \
  bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ "$(jq '[.actions[]|select(.action=="retro-judge")]|length' <<<"$PLAN")" = "1" ] \
  && ok "exactly one retro-judge action" || bad "t23.count" "got $(jq -c '[.actions[]|select(.action=="retro-judge")]' <<<"$PLAN")"
RJ="$(action_for <<<"$PLAN" '.action=="retro-judge"')"
[ "$(jq -r '.reason' <<<"$RJ")" = "debounce" ] && ok "reason=debounce (age past RETRO_MIN_INTERVAL)" || bad "t23.reason" "got $(jq -r '.reason' <<<"$RJ")"
[ "$(jq -r '.count' <<<"$RJ")" = "1" ] && ok "count=1 tracker" || bad "t23.tcount" "got $(jq -r '.count' <<<"$RJ")"
jq -e '.emit | test("/retro --pending") and test("--board 3")' <<<"$RJ" >/dev/null \
  && ok "emits a call to the overlay /retro --pending judge (calls, not re-implements)" || bad "t23.emit" "$(jq -r '.emit' <<<"$RJ")"
[ -z "$(action_for <<<"$PLAN" '.action=="skip-retro-judge"')" ] && ok "no skip line when a judge is declared and due" || bad "t23.noskip" "unexpected skip-retro-judge"

echo "--- test 24: a retro-urgent tracker fires REGARDLESS of the debounce (urgency bypass) ---"
FX="$TMP/t24"; seed_board "$FX" 3
cat > "$FX/board-3/retro-trackers.json" <<JSON
[{"number":905,"title":"Process retro: epic #810","createdAt":"$RFRESH","labels":["retro-pending","retro-urgent"]}]
JSON
PLAN="$(COMMAND_DECLARED_OVERRIDE="retro" FUNNEL_NOW_EPOCH="$RNOW" \
  BUILD_CONFIG_LOCAL="$NOLOCAL" BUILD_CONFIG_MACHINE="$NOMACHINE" \
  bash "$TICK" --dry-run --fixture "$FX" --board 3)"
RJ="$(action_for <<<"$PLAN" '.action=="retro-judge"')"
[ -n "$RJ" ] && ok "retro-urgent tracker still fires despite being fresh" || bad "t24.fire" "no retro-judge action; PLAN=$PLAN"
[ "$(jq -r '.reason' <<<"$RJ")" = "urgent" ] && ok "reason=urgent (bypasses the age gate)" || bad "t24.reason" "got $(jq -r '.reason' <<<"$RJ")"

echo "--- test 25: a fresh, non-urgent tracker does NOT fire (debounce not yet met) ---"
FX="$TMP/t25"; seed_board "$FX" 3
cat > "$FX/board-3/retro-trackers.json" <<JSON
[{"number":906,"title":"Process retro: epic #820","createdAt":"$RFRESH","labels":["retro-pending"]}]
JSON
PLAN="$(COMMAND_DECLARED_OVERRIDE="retro" FUNNEL_NOW_EPOCH="$RNOW" \
  BUILD_CONFIG_LOCAL="$NOLOCAL" BUILD_CONFIG_MACHINE="$NOMACHINE" \
  bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ -z "$(action_for <<<"$PLAN" '.action=="retro-judge"')" ] && ok "no retro-judge — debounce not yet crossed" || bad "t25.nofire" "unexpectedly fired: $PLAN"
[ "$(jq -r 'first(.actions[]|select(.action=="no-op"))' <<<"$PLAN")" != "null" ] \
  && ok "tick still reports no-op (nothing else drivable this tick)" || bad "t25.noop" "got $PLAN"

echo "--- test 26: /retro NOT declared -> exactly ONE legible skip-retro-judge; NO retro-judge action ---"
FX="$TMP/t26"; seed_board "$FX" 3
cat > "$FX/board-3/retro-trackers.json" <<JSON
[{"number":907,"title":"Process retro: epic #830","createdAt":"$ROLD","labels":["retro-pending"]}]
JSON
PLAN="$(COMMAND_DECLARED_OVERRIDE="" FUNNEL_NOW_EPOCH="$RNOW" \
  BUILD_CONFIG_LOCAL="$NOLOCAL" BUILD_CONFIG_MACHINE="$NOMACHINE" \
  bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ "$(jq '[.actions[]|select(.action=="skip-retro-judge")]|length' <<<"$PLAN")" = "1" ] \
  && ok "exactly one skip-retro-judge line" || bad "t26.skipcount" "got $(jq -c '[.actions[]|select(.action=="skip-retro-judge")]' <<<"$PLAN")"
[ -z "$(action_for <<<"$PLAN" '.action=="retro-judge"')" ] && ok "no retro-judge action emitted when the judge isn't declared" || bad "t26.noaction" "a retro-judge action leaked through: $PLAN"

echo "--- test 27: a tracker pre-set to retro-judged/closed is NEVER re-emitted ---"
FX="$TMP/t27"; seed_board "$FX" 3
cat > "$FX/board-3/retro-trackers.json" <<JSON
[{"number":908,"title":"Process retro: epic #840 (already judged)","createdAt":"$ROLD","state":"closed","labels":["retro-judged"]},
 {"number":909,"title":"Process retro: epic #841 (already judged, still open)","createdAt":"$ROLD","labels":["retro-judged"]}]
JSON
PLAN="$(COMMAND_DECLARED_OVERRIDE="retro" FUNNEL_NOW_EPOCH="$RNOW" \
  BUILD_CONFIG_LOCAL="$NOLOCAL" BUILD_CONFIG_MACHINE="$NOMACHINE" \
  bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ -z "$(action_for <<<"$PLAN" '.action=="retro-judge"')" ] \
  && ok "a retro-judged tracker (closed, or open-but-relabeled) is never re-emitted" || bad "t27.rejudged" "unexpectedly fired: $PLAN"

echo "--- test 28: multiple due trackers still yield exactly ONE batched retro-judge action ---"
FX="$TMP/t28"; seed_board "$FX" 3
cat > "$FX/board-3/retro-trackers.json" <<JSON
[{"number":910,"title":"epic #850","createdAt":"$ROLD","labels":["retro-pending"]},
 {"number":911,"title":"epic #851","createdAt":"$ROLD","labels":["retro-pending"]},
 {"number":912,"title":"epic #852 (already judged)","createdAt":"$ROLD","labels":["retro-judged"]}]
JSON
PLAN="$(COMMAND_DECLARED_OVERRIDE="retro" FUNNEL_NOW_EPOCH="$RNOW" \
  BUILD_CONFIG_LOCAL="$NOLOCAL" BUILD_CONFIG_MACHINE="$NOMACHINE" \
  bash "$TICK" --dry-run --fixture "$FX" --board 3)"
[ "$(jq '[.actions[]|select(.action=="retro-judge")]|length' <<<"$PLAN")" = "1" ] \
  && ok "still exactly one retro-judge action for a multi-tracker batch" || bad "t28.count" "got $(jq -c '[.actions[]|select(.action=="retro-judge")]' <<<"$PLAN")"
RJ="$(action_for <<<"$PLAN" '.action=="retro-judge"')"
[ "$(jq -r '.count' <<<"$RJ")" = "2" ] && ok "count=2 (the already-judged tracker excluded)" || bad "t28.tcount" "got $(jq -r '.count' <<<"$RJ")"

# ── summary ──────────────────────────────────────────────────────────────────
echo
echo "funnel-tick tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
