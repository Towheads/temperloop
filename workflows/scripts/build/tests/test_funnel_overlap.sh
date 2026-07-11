#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/funnel-overlap.sh — /build's run-start
# funnel-interference predicate (foundation #864).
#
# The predicate is a pure function of (schedule file, config, --board, file
# list): each case writes a fixture schedule note to a tmpdir, points
# FUNNEL_SCHEDULE_FILE at it, pins the board set / driven-paths via env, runs
# the script, and asserts on the verdict JSON + exit code. Zero network, zero
# dependency on the real vault note.
#
# Covers: overlap (enabled + board match + file match → exit 10, matched list)
# · board ∉ boards → no-overlap · enabled:no / missing file / no block →
# no-overlap (fail-open) · empty boards: falls back to FUNNEL_ENABLED_BOARDS
# · no files → inconclusive no-overlap · no --board → no-overlap ·
# FUNNEL_DRIVEN_PATHS override honored · malformed enabled token fails open ·
# (temperloop#226/#232) FUNNEL_SCHEDULE_FILE's UNSET-default resolution —
# Controls/ then legacy Context/ fallback, same probe as funnel-schedule-gate.sh.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRED="$HERE/../funnel-overlap.sh"

pass=0
fail=0
ok()   { echo "  ok    $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Write a fixture schedule note. write_sched <file> <block-lines...>
write_sched() {
  local f="$1"; shift
  { echo "operator prose above the block"
    echo '```funnel-schedule'
    printf '%s\n' "$@"
    echo '```'
    echo "operator prose below the block"
  } > "$f"
}

# run <sched-file> <extra-env...> -- <args...> → verdict on stdout; exits with
# the predicate's exit code. Call as `rc=0; v=$(run …) || rc=$?` — rc must be
# captured OUTSIDE the command substitution (a subshell can't set the parent's).
run() {
  local sched="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env "${envs[@]}" FUNNEL_SCHEDULE_FILE="$sched" bash "$PRED" "$@"
}

field() { printf '%s' "$1" | jq -r "$2"; }

# ── 1: overlap — enabled, board in boards:, file under a driven prefix ───────
echo "--- test 1: enabled + board match + file match → overlap (exit 10) ---"
write_sched "$TMP/on.md" "enabled: yes" "hours: 9 12" "boards: 3 4"
rc=0; v=$(run "$TMP/on.md" FUNNEL_DRIVEN_PATHS="workflows/scripts/ Makefile" -- \
      --board 4 workflows/scripts/board/lib/board.sh dashboard/index.html) || rc=$?
[ "$rc" = "10" ] && ok "exit 10" || bad "overlap.rc" "got $rc"
[ "$(field "$v" .action)" = "overlap" ] && ok "action=overlap" || bad "overlap.action" "got $v"
[ "$(field "$v" '.matched | length')" = "1" ] && ok "1 matched path" || bad "overlap.matched" "got $v"
[ "$(field "$v" .matched[0])" = "workflows/scripts/board/lib/board.sh" ] && ok "matched path right" || bad "overlap.matched0" "got $v"
[ "$(field "$v" .boards)" = "3 4" ] && ok "boards echoed" || bad "overlap.boards" "got $v"

# ── 2: board not in the funnel's board set → no-overlap ──────────────────────
echo "--- test 2: board ∉ boards → no-overlap ---"
write_sched "$TMP/b3.md" "enabled: yes" "hours: 9" "boards: 3"
rc=0; v=$(run "$TMP/b3.md" FUNNEL_DRIVEN_PATHS="workflows/scripts/" -- \
      --board 4 workflows/scripts/board/lib/board.sh) || rc=$?
[ "$rc" = "0" ] && ok "exit 0" || bad "board-out.rc" "got $rc"
[ "$(field "$v" .action)" = "no-overlap" ] && ok "action=no-overlap" || bad "board-out.action" "got $v"

# ── 3: enabled: no (frozen) → no-overlap, whatever the files ─────────────────
echo "--- test 3: enabled: no → no-overlap ---"
write_sched "$TMP/off.md" "enabled: no" "hours: 9" "boards: 4"
rc=0; v=$(run "$TMP/off.md" FUNNEL_DRIVEN_PATHS="workflows/scripts/" -- \
      --board 4 workflows/scripts/board/lib/board.sh) || rc=$?
[ "$rc" = "0" ] && ok "exit 0" || bad "frozen.rc" "got $rc"
case "$(field "$v" .reason)" in *disabled/frozen*) ok "reason names frozen" ;; *) bad "frozen.reason" "got $v" ;; esac

# ── 4: schedule file missing → no-overlap (fail-open) ────────────────────────
echo "--- test 4: missing schedule file → no-overlap ---"
rc=0; v=$(run "$TMP/nope.md" FUNNEL_DRIVEN_PATHS="workflows/scripts/" -- \
      --board 4 workflows/scripts/board/lib/board.sh) || rc=$?
[ "$rc" = "0" ] && ok "exit 0" || bad "missing.rc" "got $rc"
[ "$(field "$v" .action)" = "no-overlap" ] && ok "action=no-overlap" || bad "missing.action" "got $v"

# ── 5: note without a funnel-schedule block → no-overlap (fail-open) ─────────
echo "--- test 5: no fenced block → no-overlap ---"
echo "just prose, no block" > "$TMP/prose.md"
rc=0; v=$(run "$TMP/prose.md" FUNNEL_DRIVEN_PATHS="workflows/scripts/" -- \
      --board 4 workflows/scripts/board/lib/board.sh) || rc=$?
[ "$rc" = "0" ] && ok "exit 0" || bad "noblock.rc" "got $rc"

# ── 6: empty boards: falls back to FUNNEL_ENABLED_BOARDS ─────────────────────
echo "--- test 6: boards: absent → FUNNEL_ENABLED_BOARDS fallback ---"
write_sched "$TMP/nb.md" "enabled: yes" "hours: 9"
rc=0; v=$(run "$TMP/nb.md" FUNNEL_ENABLED_BOARDS="4" FUNNEL_DRIVEN_PATHS="workflows/scripts/" -- \
      --board 4 workflows/scripts/board/lib/board.sh) || rc=$?
[ "$rc" = "10" ] && ok "fallback board matches → exit 10" || bad "fallback.rc" "got $rc"
rc=0; v=$(run "$TMP/nb.md" FUNNEL_ENABLED_BOARDS="3" FUNNEL_DRIVEN_PATHS="workflows/scripts/" -- \
      --board 4 workflows/scripts/board/lib/board.sh) || rc=$?
[ "$rc" = "0" ] && ok "fallback board mismatch → exit 0" || bad "fallback-out.rc" "got $rc"

# ── 7: no files given → inconclusive no-overlap ──────────────────────────────
echo "--- test 7: no files → inconclusive ---"
write_sched "$TMP/on2.md" "enabled: yes" "hours: 9" "boards: 4"
rc=0; v=$(run "$TMP/on2.md" FUNNEL_DRIVEN_PATHS="workflows/scripts/" -- --board 4) || rc=$?
[ "$rc" = "0" ] && ok "exit 0" || bad "nofiles.rc" "got $rc"
case "$(field "$v" .reason)" in *inconclusive*) ok "reason says inconclusive" ;; *) bad "nofiles.reason" "got $v" ;; esac

# ── 8: no --board → no-overlap (repo not funnel-driven) ──────────────────────
echo "--- test 8: no --board → no-overlap ---"
rc=0; v=$(run "$TMP/on2.md" FUNNEL_DRIVEN_PATHS="workflows/scripts/" -- \
      workflows/scripts/board/lib/board.sh) || rc=$?
[ "$rc" = "0" ] && ok "exit 0" || bad "noboard.rc" "got $rc"
case "$(field "$v" .reason)" in *--board*) ok "reason names missing --board" ;; *) bad "noboard.reason" "got $v" ;; esac

# ── 9: no plan file under the driven prefixes → no-overlap ───────────────────
echo "--- test 9: disjoint file set → no-overlap ---"
rc=0; v=$(run "$TMP/on2.md" FUNNEL_DRIVEN_PATHS="workflows/scripts/ Makefile" -- \
      --board 4 dashboard/index.html env/zshrc) || rc=$?
[ "$rc" = "0" ] && ok "exit 0" || bad "disjoint.rc" "got $rc"
case "$(field "$v" .reason)" in *FUNNEL_DRIVEN_PATHS*) ok "reason names the prefix set" ;; *) bad "disjoint.reason" "got $v" ;; esac

# ── 10: FUNNEL_DRIVEN_PATHS override honored ─────────────────────────────────
echo "--- test 10: driven-paths override ---"
rc=0; v=$(run "$TMP/on2.md" FUNNEL_DRIVEN_PATHS="dashboard/" -- --board 4 dashboard/index.html) || rc=$?
[ "$rc" = "10" ] && ok "override prefix matches → exit 10" || bad "override.rc" "got $rc"

# ── 11: malformed enabled token → no-overlap (fail-open) ─────────────────────
echo "--- test 11: enabled: maybe → no-overlap ---"
write_sched "$TMP/bad.md" "enabled: maybe" "hours: 9" "boards: 4"
rc=0; v=$(run "$TMP/bad.md" FUNNEL_DRIVEN_PATHS="workflows/scripts/" -- \
      --board 4 workflows/scripts/board/lib/board.sh) || rc=$?
[ "$rc" = "0" ] && ok "exit 0" || bad "malformed.rc" "got $rc"

# ── 12: FUNNEL_SCHEDULE_FILE default resolution — Controls/ then Context/
#    fallback (temperloop#226/#232). Leaves FUNNEL_SCHEDULE_FILE UNSET and
#    sandboxes KNOWLEDGE_STORE_ROOT instead, so the predicate's own `:=`
#    default-derivation logic runs for real (tests 1-11 above all inject
#    FUNNEL_SCHEDULE_FILE explicitly and never exercise it).
echo "--- test 12: FUNNEL_SCHEDULE_FILE default — Controls/ then Context/ fallback ---"
KROOT="$TMP/kstore"
mkdir -p "$KROOT/Controls" "$KROOT/Context"

# 12a: Controls/ file present (Context/ absent) → overlap fires from Controls/.
write_sched "$KROOT/Controls/foundation - funnel schedule.md" "enabled: yes" "hours: 9" "boards: 4"
rc=0; v=$(env KNOWLEDGE_STORE_ROOT="$KROOT" FUNNEL_DRIVEN_PATHS="workflows/scripts/" \
      bash "$PRED" --board 4 workflows/scripts/board/lib/board.sh) || rc=$?
[ "$rc" = "10" ] && ok "overlap fires reading the Controls/ path only" || bad "default12a.rc" "got $rc"
rm -f "$KROOT/Controls/foundation - funnel schedule.md"

# 12b: Controls/ absent, legacy Context/ present → falls back, still fires.
write_sched "$KROOT/Context/foundation - funnel schedule.md" "enabled: yes" "hours: 9" "boards: 4"
rc=0; v=$(env KNOWLEDGE_STORE_ROOT="$KROOT" FUNNEL_DRIVEN_PATHS="workflows/scripts/" \
      bash "$PRED" --board 4 workflows/scripts/board/lib/board.sh) || rc=$?
[ "$rc" = "10" ] && ok "overlap fires reading the legacy Context/ path only" || bad "default12b.rc" "got $rc"
rm -f "$KROOT/Context/foundation - funnel schedule.md"

# 12c: neither path exists → no-overlap (fail-open, same as test 4).
rc=0; v=$(env KNOWLEDGE_STORE_ROOT="$KROOT" FUNNEL_DRIVEN_PATHS="workflows/scripts/" \
      bash "$PRED" --board 4 workflows/scripts/board/lib/board.sh) || rc=$?
[ "$rc" = "0" ] && ok "neither path present → no-overlap (fail-open)" || bad "default12c.rc" "got $rc"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
