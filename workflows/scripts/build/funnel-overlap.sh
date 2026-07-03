#!/usr/bin/env bash
#
# funnel-overlap.sh — /build's run-start funnel-interference predicate
# (foundation #864, from the Epic B retro #847). A standalone, testable
# predicate: does this plan's aggregate file set intersect the funnel's
# operational surface while the funnel is enabled for this repo's board?
# When it does, /build Step 1.7 surfaces a freeze offer AT RUN START —
# before the run and the funnel spend hours rebasing over each other
# (the Epic B cascade: repeated re-gate cycles over moved main + a stale
# kernel seed → design fork → ~2.5h of rework).
#
#   funnel-overlap.sh [--board N] <file...>     # plan items' files: entries
#
# Verdict JSON (stdout, one line) + EXIT CODE (the contract Step 1.7 reads):
#   {"action":"overlap","matched":[…],"boards":"…"}   exit 10 → surface the offer
#   {"action":"no-overlap","reason":"…"}              exit 0  → proceed silently
#
# OVERLAP iff ALL of: the schedule note says `enabled: yes`, `--board N` is in
# the funnel's effective board set (schedule `boards:` falling back to
# FUNNEL_ENABLED_BOARDS), and ≥1 given file starts with a FUNNEL_DRIVEN_PATHS
# prefix. Everything else is a no-overlap.
#
# FAIL-OPEN is the load-bearing invariant — the deliberate INVERSE of
# funnel-schedule-gate.sh's fail-closed. That gate guards spend, so it defaults
# to *don't spend*; this predicate guards an ADVISORY OFFER, so it defaults to
# *don't block the run*: a missing/unreadable/malformed schedule file, a missing
# jq, an absent --board (repo not board-wired → not funnel-driven), or an empty
# file list all emit `no-overlap` (exit 0) with the reason recorded — a parse
# hiccup must never stall a build run on a freeze prompt it can't justify.
#
# Path match is textual prefix — compat symlink paths (workflows/scripts/…)
# match their own prefix directly; no symlink resolution is attempted.
#
# Config (env overrides win; defaults centralized in build.config.sh):
#   FUNNEL_SCHEDULE_FILE   the vault schedule note (same resolution as
#                          funnel-schedule-gate.sh — ks_root + the Context/
#                          default seeded in build.config.sh)
#   FUNNEL_ENABLED_BOARDS  default board set when the schedule's `boards:` is
#                          empty (same fallback funnel-cron.sh uses)
#   FUNNEL_DRIVEN_PATHS    space-separated path prefixes = the funnel's
#                          operational surface (see build.config.sh)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workflows/scripts/build/build.config.sh
[ -f "$HERE/build.config.sh" ] && . "$HERE/build.config.sh"
# shellcheck source=workflows/scripts/lib/knowledge_store.sh
[ -f "$HERE/../lib/knowledge_store.sh" ] && . "$HERE/../lib/knowledge_store.sh"

# Same schedule-note resolution as funnel-schedule-gate.sh (ks_root seam).
: "${FUNNEL_SCHEDULE_FILE:=$(ks_root 2>/dev/null || true)/Context/foundation - funnel schedule.md}"
# Same non-vendoring fallbacks the other funnel consumers keep.
: "${FUNNEL_ENABLED_BOARDS:=3}"
: "${FUNNEL_DRIVEN_PATHS:=kernel/ workflows/scripts/ claude/commands/ claude/workflows/ claude/hooks/ scripts/quality-gates Makefile}"

# Emit a no-overlap verdict (fail-open) and exit 0. Reasons are kept free of
# double quotes so the printf fallback (no jq) still emits valid JSON.
no_overlap() {
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$1" '{action:"no-overlap",reason:$r}'
  else
    printf '{"action":"no-overlap","reason":"%s"}\n' "$1"
  fi
  exit 0
}

board=""
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --board) board="${2:-}"; shift 2 ;;
    --board=*) board="${1#--board=}"; shift ;;
    -h|--help)
      sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) files+=("$1"); shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || no_overlap "jq not found (fail-open)"
[ "${#files[@]}" -gt 0 ] || no_overlap "no files given -- plan carries no files: fields (inconclusive)"
[ -n "$board" ] || no_overlap "no --board -- repo is not board-wired, so not funnel-driven"
[ -r "$FUNNEL_SCHEDULE_FILE" ] || no_overlap "schedule file missing/unreadable (funnel fail-closed quiet): $FUNNEL_SCHEDULE_FILE"

# Extract the fenced ```funnel-schedule … ``` block body — same awk idiom as
# funnel-schedule-gate.sh; only the FIRST block is read.
block="$(awk '/^```funnel-schedule[[:space:]]*$/{f=1;next} f&&/^```/{exit} f' "$FUNNEL_SCHEDULE_FILE" 2>/dev/null || true)"
[ -n "$block" ] || no_overlap "no funnel-schedule block found (funnel fail-closed quiet)"

# Pull one `key:` value out of the block — verbatim funnel-schedule-gate.sh
# helper (first match; strips trailing # comment, CR, whitespace).
field() {
  local line
  line="$(printf '%s\n' "$block" | grep -iE "^[[:space:]]*$1:" | head -1)" || line=""
  [ -n "$line" ] || return 0
  printf '%s' "$line" | sed -E "s@^[[:space:]]*$1:[[:space:]]*@@" | tr -d '\r' \
    | sed -E 's@[[:space:]]+#.*$@@; s@[[:space:]]+$@@'
}

enabled="$(field enabled)"
case "$enabled" in
  [Yy]|[Yy][Ee][Ss]) : ;;                       # enabled — proceed to the board check
  *) no_overlap "funnel disabled/frozen (enabled: '${enabled:-absent}')" ;;
esac

# Effective board set: schedule `boards:` override, else the code default —
# the same precedence funnel-cron.sh applies.
sched_boards="$(field boards)"
eff_boards="${sched_boards:-$FUNNEL_ENABLED_BOARDS}"
in_boards=0
for b in $eff_boards; do
  [ "$b" = "$board" ] && in_boards=1
done
[ "$in_boards" -eq 1 ] || no_overlap "board $board not in funnel boards ($eff_boards)"

# Prefix-intersect the plan's file set against the funnel's operational surface.
matched=()
for f in "${files[@]}"; do
  for p in $FUNNEL_DRIVEN_PATHS; do
    case "$f" in
      "$p"*) matched+=("$f"); break ;;
    esac
  done
done
[ "${#matched[@]}" -gt 0 ] || no_overlap "no plan file under FUNNEL_DRIVEN_PATHS"

printf '%s\n' "${matched[@]}" \
  | jq -Rnc --arg b "$eff_boards" '{action:"overlap",matched:[inputs],boards:$b}'
exit 10
