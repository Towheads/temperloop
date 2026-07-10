#!/usr/bin/env bash
#
# env-hygiene-report.sh — thin wrapper over env-reconcile.sh emitting a
# ready-to-append vault drift-entry for /tidy (temperloop#176, epic #168 L2).
#
# This script has NO detection logic of its own — it locates and invokes
# workflows/scripts/build/env-reconcile.sh --format entry (the read-only,
# fail-open environment reconciler, temperloop#172) and passes its output
# through verbatim. Modeled on drain/vault_hygiene_report.sh --format entry,
# the sibling detect-and-propose probe for vault (rather than environment)
# drift: same shape (`### <ts> · … · <host>` … `Status: open`), same
# nothing-when-clean contract. /tidy's forthcoming § Environment hygiene
# step (temperloop#177) is the intended caller.
#
# Usage:
#   env-hygiene-report.sh [--format report|entry]
#     --format entry    (default) print a ready-to-append `### … Status: open`
#                        vault block IFF drift is detected by env-reconcile.sh;
#                        print NOTHING when the environment is clean.
#     --format report    human-readable report (passthrough to env-reconcile.sh)
#
# Env overrides: none of its own — every ENV_RECONCILE_* override
# env-reconcile.sh accepts (checkout lists, staleness horizons, launchd
# dirs, …) passes through unchanged since this wrapper sets none itself.
#
# READ-ONLY / FAIL-OPEN contract: this wrapper mutates nothing and never
# aborts. A missing, non-executable, or erroring env-reconcile.sh is treated
# as "nothing to report" — exit 0 always, with no output in --format entry
# mode (a clean marker) and a one-line notice in --format report mode. Exit 2
# only on a usage error (unknown flag/format) — mirrors env-reconcile.sh's
# own contract.
#
# Kept POSIX-bash-3.2 compatible, mirroring its sibling probe scripts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILE="$SCRIPT_DIR/build/env-reconcile.sh"

# ── Arg parse ─────────────────────────────────────────────────────────────────
FORMAT="entry"
while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT="${2:-}"; shift 2 ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$FORMAT" in report|entry) ;; *) echo "unknown --format: $FORMAT (report|entry)" >&2; exit 2 ;; esac

# ── env-reconcile.sh absent → nothing to report (fail-open) ──────────────────
if [ ! -f "$RECONCILE" ]; then
  if [ "$FORMAT" = "entry" ]; then
    exit 0   # nothing to append
  fi
  echo "env hygiene: env-reconcile.sh not found ($RECONCILE) — skipping"
  exit 0
fi

# ── Invoke + passthrough (fail-open on any non-zero exit or crash) ───────────
# Explicit `if`, not `A && B || C` (ubuntu CI shellcheck SC2015 — a middle
# command that itself fails would silently run the `||` branch too).
out=""
if [ -x "$RECONCILE" ]; then
  if captured="$("$RECONCILE" --format "$FORMAT" 2>/dev/null)"; then
    out="$captured"
  fi
else
  # Not executable (e.g. checked out 100644) — still try via `bash` rather
  # than fail a read-only probe on a perms hiccup.
  if captured="$(bash "$RECONCILE" --format "$FORMAT" 2>/dev/null)"; then
    out="$captured"
  fi
fi

if [ "$FORMAT" = "entry" ]; then
  # env-reconcile.sh --format entry already emits nothing when clean and a
  # well-formed `### … Status: open` block when drift is found — passthrough
  # verbatim, nothing added.
  [ -n "$out" ] && printf '%s\n' "$out"
  exit 0
fi

if [ -n "$out" ]; then
  printf '%s\n' "$out"
else
  echo "env hygiene: env-reconcile.sh produced no output (see stderr above, if any)"
fi
exit 0
