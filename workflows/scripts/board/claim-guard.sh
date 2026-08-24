#!/usr/bin/env bash
#
# claim-guard.sh — partition a set of candidate issues into SAFE-TO-CLOSE vs
# HELD-BY-ANOTHER-SESSION, so a close/cull path can refuse the second set and
# name it in its own run report (temperloop#1220).
#
#   claim-guard.sh --board 7 1199 1613 42
#   claim-guard.sh --board temperloop '#1199' 42        # leading # is fine
#
# ── The defect this exists to close ──────────────────────────────────────────
# The board claim is a CROSS-SESSION LOCK (`claude/CLAUDE.kernel.md` § Task
# workflow, "Claim first — before you investigate"): a session stamps
# `fnd:host/session:<host>:<sess8>` on an issue it is building. `/triage`'s cull
# path did not read that stamp. On 2026-08-08 a concurrent `/triage` closed
# K#1199 — claimed 30 minutes earlier, with a green PR already open carrying
# `Closes #1199` — and stripped the foreign session's claim stamp as part of its
# own Done bookkeeping. The PR merged pointing at an already-closed duplicate,
# and the issue that merge actually fixed stayed open forever. Generalised: a
# cull that lands on a claimed issue SILENTLY ORPHANS the in-flight PR's issue
# linkage, and nothing reports the mismatch.
#
# This script is the executable half of the fix. A prose rule ("don't cull a
# claimed issue") is exactly what the pre-fix spec already implied and the run
# read past; the guard makes the check a command whose output the cull consumes.
#
# ── The contract: REFUSE AND REPORT, never block ─────────────────────────────
# Every foreign-stamped issue is SKIPPED and NAMED. It is never closed, and its
# claim stamp is never touched — this script issues NO writes of any kind, on
# any path. It also never waits, polls, or asks: a STALE claim (an abandoned
# session's stamp, e.g. a Ready item still wearing `mini:6700a71d`) must not
# deadlock the cull, so it reports-and-skips exactly like a live one. Disposal
# of a stale stamp stays owned by `/tidy`'s stale-claim sweep and
# `reconcile.sh --labels --apply` (classes (g)/(j)/(m)) — once they clear it,
# the next run culls the issue normally. That division is deliberate: this
# script decides "is it MINE to close?", never "is that claim still alive?".
#
# ── Output grammar (stdout, one line per issue, input order preserved) ────────
#   CULL <n> claim=none            no claim stamp — safe to close
#   CULL <n> claim=self            stamped by THIS session — our own claim
#   SKIP <n> claim=<stamp> class=live      foreign stamp, item In Progress
#   SKIP <n> claim=<stamp> class=parked    foreign stamp, item not In Progress
#   SKIP <n> claim=unknown class=unreadable   claim state could not be read
#   SUMMARY cullable=<k> skipped=<m>
#
# `claim=none` means a MATCHED pool item carrying no stamp — never "the lookup
# came back empty". An issue ABSENT from the resolved pool (past the
# `BOARD_ITEM_LIMIT` truncation, on another board, already closed) reports
# `class=unreadable`, because its claim state was never read at all.
#
# `class=` is REPORTING DETAIL ONLY — both live and parked are skipped, and a
# caller must key on the CULL/SKIP verb, never on the class. The class exists so
# the run report can point the operator at the right disposal path (a live claim:
# leave it to the session that holds it; a parked one: `/tidy`'s stale-claim
# sweep).
#
# ── Fail SAFE, not open ──────────────────────────────────────────────────────
# If the board cannot be resolved (offline, auth failure, an unregistered board),
# EVERY candidate comes back `SKIP … class=unreadable` and the exit status is
# still 0. Culling blind is the incident this script exists to prevent, and a
# deferred cull costs nothing but one more run: the issues simply stay open. A
# guard that fails open would reproduce the bug precisely when the board is
# least readable.
#
# The same rule holds PER CANDIDATE, not just for a whole-board resolve failure:
# an issue missing from the resolved pool, and a pool that will not parse, both
# report `class=unreadable` rather than `claim=none`. Every path out of this
# script that is not a positively-read claim state resolves toward SKIP.
#
# ── Exit status ──────────────────────────────────────────────────────────────
#   0  a partition was emitted (WHETHER OR NOT anything was skipped — the SKIP
#      lines are the signal; a non-zero "something was claimed" code would abort
#      a `set -e` caller mid-cull, which is the deadlock this must not create)
#   2  usage error (no issues, unknown flag, non-numeric issue)
#
# Needs only the DEFAULT `repo` gh scope: the claim stamp is a `fnd:` label read
# through the board adapter (see ISSUES-ONLY-BACKEND.md § Claim lock).
set -euo pipefail

# Attribution for the gh call-logger shim (F#988): tag every gh call this command
# makes with its outermost context, preserving an already-set outer value so an
# autonomous driver's context wins over this nested command.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-claim-guard}"

# Resolve symlinks so the script finds its real lib/ even when invoked through a
# symlink (on PATH or from a consuming repo's scripts/ dir) — BASH_SOURCE points
# at the symlink, not the real file. Portable (no GNU readlink -f). Mirrors claim.sh.
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$src")" && pwd)"
# shellcheck source=scripts/lib/board.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/board.sh"

# Module-level state, set by the execute-guard (direct run) or by a sourcing test
# before it calls claim_guard_main. Defaults match claim.sh's historical CLI.
PROJECT_NUMBER=3
CLAIM_GUARD_ISSUES=()

# claim_guard_read_of <issue#> -> ONE tab-separated record for the issue:
#
#   present<TAB><stamp><TAB><status>   the issue IS in the resolved pool
#   absent<TAB><TAB>                   the issue is NOT in the pool at all
#
# and a NON-ZERO status with no usable output when the pool cannot be parsed.
#
# A pure jq read against the warm BOARD_ITEMS_JSON the caller already resolved —
# no extra gh call, mirroring board_claim_contended. Reads the `host/Session`
# key the issues-only reshape derives from the `fnd:host/session:*` label
# (lib/board.sh's issue_item jq def).
#
# PRESENCE IS RESOLVED BEFORE THE STAMP, in the SAME pass, because the two states
# are indistinguishable at the string level and mean OPPOSITE things: a `select`
# that matched nothing and a matched item whose stamp is empty both used to come
# back as "". Only the second is safe to cull. A candidate is absent from the pool
# for entirely ordinary reasons — `board_item_list` -> `_board_issues_item_list`
# (lib/board.sh) is `gh issue list --state open --limit "${BOARD_ITEM_LIMIT:-500}"`,
# so any board with more than BOARD_ITEM_LIMIT open issues truncates, and an issue
# on another board or already closed is absent too. Reading absence as "no claim
# stamp" would CULL an issue whose claim state was never read: fail-OPEN, which is
# what § Fail SAFE above forbids, on the most ordinary board condition there is.
#
# `--arg` (string compare via tostring), not `--argjson`: a non-numeric candidate
# reaching the SOURCED entry point then reads as absent rather than crashing jq.
claim_guard_read_of() {
  printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --arg n "$1" '
      ([ .items[]? | select((.content.number | tostring) == $n) ] | first) as $it
      | if $it == null then "absent\t\t"
        else "present\t" + (($it["host/Session"] // "") | tostring)
                   + "\t" + (($it.status // "") | tostring)
        end'
}

# The whole partition, wrapped so a test can source this file (the execute-guard
# at the bottom suppresses the auto-run when sourced), set $PROJECT_NUMBER /
# $CLAIM_GUARD_ISSUES, override the board_resolve / _board_gh seams with canned
# data, and drive it with zero network.
claim_guard_main() {
  local n cullable=0 skipped=0 mine rec rest existing status

  # An EMPTY candidate set is a normal outcome, not an error — and it must be
  # answered BEFORE the first `"${CLAIM_GUARD_ISSUES[@]}"` expansion below,
  # because under `set -u` bash 3.2 (macOS /bin/bash) treats an empty array
  # expansion as an unbound variable and aborts. The CLI path cannot reach this
  # (its usage check at the bottom precedes the call), but the documented SOURCED
  # entry point can, and an abort there is not the SUMMARY the contract promises.
  if [ "${#CLAIM_GUARD_ISSUES[@]}" -eq 0 ]; then
    printf 'SUMMARY cullable=0 skipped=0\n'
    return 0
  fi

  # ONE whole-board read for the whole candidate set. A resolve failure is NOT
  # fatal and NOT fail-open: report every candidate unreadable and let the cull
  # defer (see § Fail SAFE above).
  if ! board_resolve "$PROJECT_NUMBER" >/dev/null 2>&1; then
    echo "claim-guard: board $PROJECT_NUMBER could not be resolved — refusing to cull blind; every candidate reported unreadable" >&2
    for n in "${CLAIM_GUARD_ISSUES[@]}"; do
      printf 'SKIP %s claim=unknown class=unreadable\n' "$n"
      skipped=$((skipped + 1))
    done
    printf 'SUMMARY cullable=0 skipped=%s\n' "$skipped"
    return 0
  fi

  # This session's own stamp, computed through the adapter's single owner of the
  # format (board_own_stamp) so this guard and claim.sh can never disagree about
  # what "mine" looks like — a disagreement here would either cull a peer's
  # claimed issue or refuse to cull our own.
  # `|| mine=""` for the same set -e reason as the per-issue read below; an empty
  # $mine can only ever mismatch a non-empty foreign stamp, so it degrades toward
  # SKIP (safe), never toward CULL.
  mine="$(board_own_stamp)" || mine=""

  for n in "${CLAIM_GUARD_ISSUES[@]}"; do
    # A failed read is NON-fatal and NON-open. A bare `rec="$(...)"` assignment
    # under `set -euo pipefail` propagates the printf|jq pipeline's status, so
    # `set -e` would kill this function MID-PARTITION — emitting no verdict lines
    # and no SUMMARY, and exiting 5 (or 127 with no jq). The § Exit status
    # contract defines only 0 and 2, and /triage Step 4.8a has no branch for a
    # third outcome, so it would see an empty cull set with no diagnosis. The
    # `|| rec=""` form is what exempts the substitution from `set -e`.
    rec="$(claim_guard_read_of "$n")" || rec=""
    # rec="" (pool unparseable) and rec="absent…" (issue not in the pool) are both
    # "claim state was never read" — never cullable. See claim_guard_read_of.
    if [ "${rec%%$'\t'*}" != "present" ]; then
      printf 'SKIP %s claim=unknown class=unreadable\n' "$n"
      skipped=$((skipped + 1))
      continue
    fi
    rest="${rec#*$'\t'}"
    existing="${rest%%$'\t'*}"
    status="${rest#*$'\t'}"
    if [ -z "$existing" ]; then
      printf 'CULL %s claim=none\n' "$n"
      cullable=$((cullable + 1))
      continue
    fi
    if [ "$existing" = "$mine" ]; then
      printf 'CULL %s claim=self\n' "$n"
      cullable=$((cullable + 1))
      continue
    fi
    if [ "$status" = "$BOARD_OPT_INPROGRESS" ]; then
      printf 'SKIP %s claim=%s class=live\n' "$n" "$existing"
    else
      printf 'SKIP %s claim=%s class=parked\n' "$n" "$existing"
    fi
    skipped=$((skipped + 1))
  done

  printf 'SUMMARY cullable=%s skipped=%s\n' "$cullable" "$skipped"
  return 0
}

# Execute-guard: run only when this file is RUN, not when SOURCED (a test sets
# $PROJECT_NUMBER / $CLAIM_GUARD_ISSUES, defines its seam overrides, and calls
# claim_guard_main itself). Mirrors claim.sh / unclaim.sh's guard and CLI shape.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) PROJECT_NUMBER="$(board_resolve_name "${2:?--board needs a value}")" || exit 2; shift 2 ;;
      --) shift; break ;;
      -*) echo "unknown arg: $1" >&2; exit 2 ;;
      *) CLAIM_GUARD_ISSUES+=("$1"); shift ;;
    esac
  done
  while [ $# -gt 0 ]; do CLAIM_GUARD_ISSUES+=("$1"); shift; done
  [ "${#CLAIM_GUARD_ISSUES[@]}" -gt 0 ] ||
    { echo "usage: claim-guard.sh <issue-number> [<issue-number>...] [--board 3|4|5|6|7|<name>]" >&2; exit 2; }
  # Normalize into a fresh array rather than rewriting in place — a leading `#`
  # is stripped (so `'#1199'` works like `1199`) and a non-numeric candidate is
  # a hard usage error, never a silently-dropped issue.
  normalized=()
  for arg in "${CLAIM_GUARD_ISSUES[@]}"; do
    arg="${arg#\#}"
    [[ "$arg" =~ ^[0-9]+$ ]] || { echo "issue must be a number, got: $arg" >&2; exit 2; }
    normalized+=("$arg")
  done
  CLAIM_GUARD_ISSUES=("${normalized[@]}")
  claim_guard_main
fi
