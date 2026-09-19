#!/usr/bin/env bash
#
# sandbox-sweep.sh — reclaim LEAKED test sandbox roots (temperloop#1723).
#
# WHY THIS EXISTS. workflows/scripts/tests/lib/sandbox.sh now installs
# EXIT/HUP/INT/TERM traps inside sandbox_up itself, so a suite that dies on a
# failed assertion, a timeout or a CI cancellation no longer strands its
# ~1GB throwaway root. Two populations that guard cannot reach:
#
#   1. SIGKILL. `kill -9`, an OOM kill, and the SIGKILL leg of a candidate
#      timeout are untrappable by construction — no handler runs, so no
#      in-process guard can ever cover them. This sweeper is the ONLY remedy
#      for that path; the trap guard is deliberately not claimed as full
#      coverage.
#   2. ROOTS ALREADY LEAKED. Every root stranded before the guard existed is
#      still on disk (the incident that motivated all of this: 215 roots,
#      ~180GB, a filled 460GB disk). Those carry no marker file.
#
# WHAT IT RECOGNISES, and why not a prefix glob. Each root's `mktemp` prefix
# is chosen by its caller ("test-install-cli-a", "uninstall-test1",
# "test-sandbox-6", ...), so a prefix glob would be a list somebody has to
# remember to extend — and a wrong entry would `rm -rf` an unrelated tmpdir.
# Two positive, structural signals instead:
#
#   MARKER    the root contains `.sandbox-root`, written by sandbox_up.
#   LEGACY    the root has sandbox_up's exact directory signature —
#             home/, bin/, and all four of xdg/{config,state,data,cache}.
#             This is what reaches the pre-guard leaks, which have no marker.
#
# TWO SAFETY VALVES so a sweep can never delete a root a live suite is using:
#
#   AGE       a root whose mtime is newer than --older-than (default 60
#             minutes) is skipped.
#   LIVE PID  a marker-bearing root whose recorded pid is still alive is
#             skipped regardless of age. (A recycled pid only ever causes an
#             over-cautious SKIP, never a wrongful delete.)
#
# DRY RUN BY DEFAULT: it lists and totals, and removes nothing until --apply.
#
# SCOPES — WHAT THIS REAPER COVERS, AND WHAT IT DOES NOT (temperloop#1667).
# Named explicitly, so a producer that starts leaking roots in a THIRD
# location is a KNOWN gap rather than a silent one:
#
#   COVERED      $TMPDIR (else /tmp), or whatever single directory --dir
#                names. That is the ONLY place sandbox_up writes a root —
#                `mktemp -d "${TMPDIR:-/tmp}/<prefix>-XXXXXX"` — so it is the
#                scope holding the leaked test_install_lifecycle.sh /
#                test_install_cli.sh sandboxes, each a full file:// clone plus
#                a complete install tree.
#   COVERED      that directory ONE level deep: the scan is `$SCAN_DIR/*`,
#                never a recursive descent. A sandbox root nested deeper is
#                not found, by design — a recursive `rm -rf` hunt over an
#                arbitrary tmp tree is the blast radius this tool exists to
#                avoid.
#   NOT COVERED  `~/.claude/jobs/*/tmp/`. A DIFFERENT location with a
#                DIFFERENT producer (Claude Code's own Bash-tool scratch),
#                tracked separately by temperloop#1111. Nothing here looks
#                there, and this sweeper must not be described as fixing it.
#   NOT COVERED  any future producer of sandbox-shaped roots elsewhere. Wiring
#                one in means adding its directory to the AUTO-REAP scope in
#                workflows/scripts/tests/lib/sandbox.sh (sandbox_reap_orphans)
#                and naming it in this list in the same change.
#
# WHO RUNS IT. An operator by hand, and — since temperloop#1667 — `sandbox_up`
# itself, once per shell, before it creates its own root. A reclaim path that
# fires only when somebody remembers to run it is how 97 orphans and 84GB
# accumulated in $TMPDIR over a single week. See sandbox.sh's ORPHAN REAP
# block for the automatic half.
#
# Usage:
#   bash workflows/scripts/tests/lib/sandbox-sweep.sh [options]
#
#   --apply                 actually remove the stale roots (default: list only)
#   --older-than <minutes>  minimum age to consider a root stale (default: 60)
#   --dir <path>            directory to scan (default: $TMPDIR, else /tmp)
#   --quiet                 suppress the banner, the per-root lines and the
#                           `du` size accounting; print ONE summary line, on
#                           stderr, and only when something was removed. For
#                           the automatic sandbox_up reap, where a clean sweep
#                           must add no noise to a suite's output and sizing a
#                           multi-GB orphan tree is wasted work.
#   -h, --help              this message
#
# Exit status: 0 on a successful scan (whether or not anything was found or
# removed); 2 on a usage error. Deliberately NOT "non-zero when leaks exist" —
# it is a reclamation tool an operator runs, not a gate.

set -uo pipefail

usage() {
  sed -n '/^# Usage:/,/^# Exit status:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

APPLY=0
QUIET=0
OLDER_THAN_MIN=60
SCAN_DIR="${TMPDIR:-/tmp}"

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=1
      shift
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --older-than)
      [ $# -ge 2 ] || {
        echo "sandbox-sweep: --older-than needs a value (minutes)" >&2
        exit 2
      }
      OLDER_THAN_MIN="$2"
      shift 2
      ;;
    --dir)
      [ $# -ge 2 ] || {
        echo "sandbox-sweep: --dir needs a value (a directory path)" >&2
        exit 2
      }
      SCAN_DIR="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "sandbox-sweep: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$OLDER_THAN_MIN" in
  '' | *[!0-9]*)
    echo "sandbox-sweep: --older-than must be a whole number of minutes (got: $OLDER_THAN_MIN)" >&2
    exit 2
    ;;
esac

if [ ! -d "$SCAN_DIR" ]; then
  echo "sandbox-sweep: not a directory: $SCAN_DIR" >&2
  exit 2
fi

MARKER=".sandbox-root"

# is_sandbox_root <dir> — marker-bearing, or carrying sandbox_up's exact
# directory signature (the pre-guard leaks, which have no marker).
is_sandbox_root() {
  local d="$1"
  [ -f "$d/$MARKER" ] && return 0
  [ -d "$d/home" ] || return 1
  [ -d "$d/bin" ] || return 1
  [ -d "$d/xdg/config" ] || return 1
  [ -d "$d/xdg/state" ] || return 1
  [ -d "$d/xdg/data" ] || return 1
  [ -d "$d/xdg/cache" ] || return 1
  return 0
}

# root_is_live <dir> — a marker-bearing root whose recorded pid still exists.
root_is_live() {
  local d="$1" pid
  [ -f "$d/$MARKER" ] || return 1
  pid="$(sed -n 's/^pid=//p' "$d/$MARKER" 2>/dev/null | head -1)"
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# older_than <dir> — mtime strictly older than $OLDER_THAN_MIN minutes.
# `find -mmin` is used rather than `stat`, whose format flags differ between
# BSD (macOS) and GNU (`-f %m` vs `-c %Y`).
older_than() {
  local d="$1" hit
  hit="$(find "$d" -maxdepth 0 -mmin "+$OLDER_THAN_MIN" 2>/dev/null)"
  [ -n "$hit" ]
}

kb_of() {
  du -sk "$1" 2>/dev/null | awk 'NR==1 {print $1; exit}'
}

human_kb() {
  awk -v kb="${1:-0}" 'BEGIN {
    if (kb >= 1048576) { printf "%.1f GB", kb / 1048576 }
    else if (kb >= 1024) { printf "%.1f MB", kb / 1024 }
    else { printf "%d KB", kb }
  }'
}

if [ "$APPLY" -eq 1 ]; then
  mode="APPLY (roots will be removed)"
else
  mode="DRY RUN (nothing will be removed)"
fi
if [ "$QUIET" -eq 0 ]; then
  printf 'sandbox-sweep: scanning %s for sandbox roots older than %s minute(s) — %s\n' \
    "$SCAN_DIR" "$OLDER_THAN_MIN" "$mode"
fi

stale_count=0
skipped_count=0
total_kb=0
removed_count=0

for entry in "$SCAN_DIR"/*; do
  [ -d "$entry" ] || continue
  [ -L "$entry" ] && continue
  is_sandbox_root "$entry" || continue

  if root_is_live "$entry"; then
    skipped_count=$((skipped_count + 1))
    [ "$QUIET" -eq 1 ] \
      || printf '  SKIP  %s  (marker pid is still running)\n' "$entry"
    continue
  fi
  if ! older_than "$entry"; then
    skipped_count=$((skipped_count + 1))
    [ "$QUIET" -eq 1 ] \
      || printf '  SKIP  %s  (newer than %s minute(s))\n' "$entry" "$OLDER_THAN_MIN"
    continue
  fi

  if [ -f "$entry/$MARKER" ]; then
    kind="marker"
  else
    kind="legacy-layout"
  fi
  # `du` on a multi-GB orphan tree is the expensive part of a sweep and its
  # only product is a human-facing size. --quiet skips it entirely.
  if [ "$QUIET" -eq 1 ]; then
    kb=0
  else
    kb="$(kb_of "$entry")"
  fi
  case "$kb" in
    '' | *[!0-9]*) kb=0 ;;
  esac
  stale_count=$((stale_count + 1))
  total_kb=$((total_kb + kb))
  [ "$QUIET" -eq 1 ] \
    || printf '  STALE %s  (%s, %s)\n' "$entry" "$kind" "$(human_kb "$kb")"

  if [ "$APPLY" -eq 1 ]; then
    if rm -rf "$entry"; then
      removed_count=$((removed_count + 1))
    else
      printf '  ERROR could not remove %s\n' "$entry" >&2
    fi
  fi
done

if [ "$QUIET" -eq 1 ]; then
  # One line, on stderr, and only when a root was actually reclaimed — an
  # automatic reap that found nothing must be indistinguishable from not
  # having run, or every suite's output grows a line of noise. A reap that DID
  # delete something is never silent: it is a `rm -rf` the operator is entitled
  # to see attributed.
  if [ "$removed_count" -gt 0 ]; then
    printf 'sandbox-sweep: reclaimed %d orphaned sandbox root(s) from %s (older than %s minute(s), no live pid).\n' \
      "$removed_count" "$SCAN_DIR" "$OLDER_THAN_MIN" >&2
  fi
elif [ "$APPLY" -eq 1 ]; then
  printf 'sandbox-sweep: removed %d of %d stale root(s), %s reclaimed (%d skipped as live/recent).\n' \
    "$removed_count" "$stale_count" "$(human_kb "$total_kb")" "$skipped_count"
else
  printf 'sandbox-sweep: %d stale root(s), %s reclaimable (%d skipped as live/recent). Re-run with --apply to remove.\n' \
    "$stale_count" "$(human_kb "$total_kb")" "$skipped_count"
fi
exit 0
