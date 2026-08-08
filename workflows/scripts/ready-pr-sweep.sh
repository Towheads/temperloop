#!/usr/bin/env bash
#
# ready-pr-sweep.sh — READ-ONLY sweep for complete-but-unmerged PRs (#721),
# the backstop half of the orphaned-PR net.
#
# Canonical caller/contract: claude/commands/tidy.md Step 3 § "Ready-but-unmerged
# PRs" — this script is that step's detection substrate, the same relationship
# env-reconcile.sh has to tidy's § Environment hygiene step. It COMPOSES two
# existing surfaces and owns no registry of its own:
#   - the board registry seam (workflows/scripts/board/lib/board.sh:
#     board_registered_boards + board_repo) for WHICH repos to sweep — never a
#     hardcoded repo list (stranger test: a fork's boards.conf drives it);
#   - plain `gh pr list` (REST-backed PR listing + statusCheckRollup) for the
#     per-PR state — deliberately NOT the Projects-v2 board adapter's resolve
#     path: PRs are not board items, so this never touches the shared GraphQL
#     Projects budget beyond an ordinary gh call.
#
# WHY: nothing else detects a complete (checks green, mergeable, non-draft) PR
# that simply never merged. /fix guards only its own producer; tidy's
# § Unlinked fix PRs sweep keys on linkage + idleness, not readiness; and the
# merge queue makes enqueue != merged — a PR enqueued and then dropped by the
# queue is exactly the orphan this sweep resurfaces (classified like any other
# open PR below; no special casing).
#
# CLASSES (one per open PR, first match wins):
#   stale-draft      draft AND untouched for $READY_PR_SWEEP_STALE_DRAFT_DAYS
#                    or more (temperloop#1180) — a NAMED drift class, not a
#                    skip. A draft can never enqueue (GitHub refuses
#                    enablePullRequestAutoMerge on one, and gate.sh queue now
#                    names that state), so a draft nobody flips ready is work
#                    that is structurally unable to land. Folding it into
#                    `skip` is what hid three such PRs for 1-3 weeks —
#                    including a live correctness fix — because skip-class PRs
#                    are invisible to --format entry's nothing-when-clean
#                    contract. A RECENT draft stays `skip`: an in-flight draft
#                    is a legitimate, deliberate state.
#   skip             draft (recent), or a DO-NOT-MERGE marker in the title
#   needs-rebase     mergeStateStatus BEHIND or DIRTY
#   needs-attention  failing checks; also the inclusion-biased catch-all for
#                    checks-pending / BLOCKED / any other not-ready, not-rebase
#                    state (reason string names the actual state)
#   not-yet-computed mergeStateStatus read UNKNOWN and STAYED UNKNOWN through a
#                    bounded retry (temperloop#1504) — GitHub computes
#                    mergeStateStatus asynchronously, so UNKNOWN means "not
#                    computed yet", not "computed, and problematic". A single
#                    read that lands mid-computation used to fall into
#                    needs-attention, and the SAME PR would read CLEAN (→
#                    ready) moments later — the remedy flipped between
#                    back-to-back sweeps. Distinct bucket, deliberately no
#                    prescribed action: it resolves on its own on a later
#                    sweep, so it is NOT a --format entry candidate (nothing to
#                    decide). See $READY_PR_SWEEP_UNKNOWN_RETRY_MAX /
#                    $READY_PR_SWEEP_UNKNOWN_RETRY_DELAY below.
#   ready            required checks green + mergeStateStatus CLEAN — an
#                    enqueue candidate (auto-enqueue is deliberately OUT of
#                    scope — a later autonomy layer; this script only reports)
#
# READ-ONLY / FAIL-OPEN contract (mirrors env-reconcile.sh): it NEVER mutates a
# PR — no merge, enqueue, close, rebase, comment, or label — and one repo
# erroring (gh failure, network, auth) never aborts the sweep: the error is
# counted + reported and the remaining repos are still swept. Exit 0 always,
# except exit 2 on a usage error (unknown flag/format).
#
# Usage:
#   ready-pr-sweep.sh [--format report|entry] [--limit N] [--repos "owner/a owner/b"]
#
#   --format report   (default) human-readable per-PR classification + summary
#   --format entry    a ready-to-append pending-decisions `### … Status: open`
#                     block (the ask-at-checkin entry tidy appends verbatim)
#                     IFF at least one ready/needs-rebase/needs-attention/
#                     stale-draft candidate surfaced; NOTHING when clean
#                     (skip-only or zero open PRs) — same nothing-when-clean
#                     contract as env-hygiene-report.sh --format entry
#   --limit N         per-repo open-PR page size passed to gh pr list
#   --repos "…"       space-separated owner/repo override — bypasses the board
#                     registry (test seam + boardless-consumer escape hatch)
#
# Env overrides:
#   READY_PR_SWEEP_BOARD_LIB   path to board.sh (default: <this dir>/board/lib/board.sh)
#   READY_PR_SWEEP_REPOS       same as --repos
#   READY_PR_SWEEP_LIMIT       same as --limit
#   READY_PR_SWEEP_STALE_DRAFT_DAYS
#                              idle-days threshold above which an open DRAFT PR
#                              is classified stale-draft rather than skip
#   READY_PR_SWEEP_UNKNOWN_RETRY_MAX
#                              max re-fetch attempts for a PR whose
#                              mergeStateStatus reads UNKNOWN, before it is
#                              classified not-yet-computed (default 3)
#   READY_PR_SWEEP_UNKNOWN_RETRY_DELAY
#                              seconds to wait before each UNKNOWN re-fetch
#                              attempt (default 2). Only PRs reading UNKNOWN
#                              pay this cost — a PR that resolves on the first
#                              fetch triggers zero extra `gh` calls.
#
# Kept POSIX-bash-3.2 compatible, mirroring its sibling probe scripts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_LIB="${READY_PR_SWEEP_BOARD_LIB:-$SCRIPT_DIR/board/lib/board.sh}"

# ── Arg parse ─────────────────────────────────────────────────────────────────
FORMAT="report"
LIMIT="${READY_PR_SWEEP_LIMIT:-100}"
REPOS="${READY_PR_SWEEP_REPOS:-}"
STALE_DRAFT_DAYS="${READY_PR_SWEEP_STALE_DRAFT_DAYS:-7}"
UNKNOWN_RETRY_MAX="${READY_PR_SWEEP_UNKNOWN_RETRY_MAX:-3}"
UNKNOWN_RETRY_DELAY="${READY_PR_SWEEP_UNKNOWN_RETRY_DELAY:-2}"
while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT="${2:-}"; shift 2 ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
    --limit) LIMIT="${2:-}"; shift 2 ;;
    --limit=*) LIMIT="${1#--limit=}"; shift ;;
    --repos) REPOS="${2:-}"; shift 2 ;;
    --repos=*) REPOS="${1#--repos=}"; shift ;;
    -h | --help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$FORMAT" in report | entry) ;; *) echo "unknown --format: $FORMAT (report|entry)" >&2; exit 2 ;; esac
case "$LIMIT" in '' | *[!0-9]*) echo "bad --limit: '$LIMIT' (positive integer)" >&2; exit 2 ;; esac
case "$STALE_DRAFT_DAYS" in '' | *[!0-9]*) echo "bad READY_PR_SWEEP_STALE_DRAFT_DAYS: '$STALE_DRAFT_DAYS' (non-negative integer)" >&2; exit 2 ;; esac
case "$UNKNOWN_RETRY_MAX" in '' | *[!0-9]*) echo "bad READY_PR_SWEEP_UNKNOWN_RETRY_MAX: '$UNKNOWN_RETRY_MAX' (non-negative integer)" >&2; exit 2 ;; esac
case "$UNKNOWN_RETRY_DELAY" in '' | *[!0-9]*) echo "bad READY_PR_SWEEP_UNKNOWN_RETRY_DELAY: '$UNKNOWN_RETRY_DELAY' (non-negative integer seconds)" >&2; exit 2 ;; esac
# Cutoff resolved ONCE, in shell, and handed to jq as data: `date +%s` is the
# one portable epoch primitive across BSD/GNU (no `-d`/`-v` dialect split), and
# a single cutoff keeps every repo in a sweep judged against the same instant.
STALE_DRAFT_CUTOFF=$(( $(date +%s) - STALE_DRAFT_DAYS * 86400 ))

# ── Preflight (fail-open: a missing tool/registry is "nothing to report") ────
notice() { [ "$FORMAT" = "report" ] && echo "ready-pr sweep: $1"; }

if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  notice "gh and/or jq not on PATH — skipping (fail-open)"
  exit 0
fi

# ── Repo enumeration: boards.conf/board_repo registry, never a hardcoded list ─
if [ -z "$REPOS" ]; then
  if [ ! -f "$BOARD_LIB" ]; then
    notice "board lib not found ($BOARD_LIB) and no --repos given — skipping (fail-open)"
    exit 0
  fi
  # board.sh is sourced for board_registered_boards + board_repo only; it
  # defines functions/constants and performs no network or board I/O at
  # source time.
  # shellcheck source=board/lib/board.sh
  . "$BOARD_LIB"
  b=""
  for b in $(board_registered_boards); do
    r="$(board_repo "$b" 2>/dev/null)" || continue
    REPOS="$REPOS $r"
  done
fi
# Dedup (several boards may map onto one repo) while preserving no particular
# order beyond sort's — bash-3.2 safe (no associative arrays).
REPOS="$(printf '%s\n' "$REPOS" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
REPOS="${REPOS% }"
if [ -z "$REPOS" ]; then
  notice "no repos registered — nothing to sweep"
  exit 0
fi

# ── Sweep ─────────────────────────────────────────────────────────────────────
# One `gh pr list` call per repo; classification is pure jq over its JSON so
# the whole per-repo pass is a single network round-trip. Rows are TSV:
#   class \t repo#number \t reason \t title
ROWS=""
ERRORS=0
ERR_REPOS=""
for repo in $REPOS; do
  if ! raw="$(gh pr list -R "$repo" --state open --limit "$LIMIT" \
    --json number,title,isDraft,mergeStateStatus,statusCheckRollup,updatedAt 2>/dev/null)"; then
    ERRORS=$((ERRORS + 1))
    ERR_REPOS="$ERR_REPOS $repo"
    notice "ERROR listing PRs for $repo — continuing (fail-open)"
    continue
  fi

  # ── UNKNOWN mergeStateStatus resolution (temperloop#1504) ──────────────────
  # mergeStateStatus is computed asynchronously by GitHub; UNKNOWN means "not
  # computed yet", not "computed, and problematic". Re-fetch ONLY the PRs that
  # actually read UNKNOWN on the list call above — a PR that already reads a
  # resolved status costs zero extra `gh` calls. Bounded retry, short delay
  # between attempts; a PR still UNKNOWN after the bound is left as-is and
  # picked up by the not-yet-computed branch below (fail-open: a `gh pr view`
  # error during retry is treated as "still unresolved this attempt" and never
  # aborts the repo).
  unknown_nums="$(printf '%s' "$raw" | jq -r '.[] | select((.mergeStateStatus // "") == "UNKNOWN") | .number' 2>/dev/null)"
  if [ -n "$unknown_nums" ]; then
    overrides="{}"
    for num in $unknown_nums; do
      resolved=""
      attempt=1
      while [ "$attempt" -le "$UNKNOWN_RETRY_MAX" ]; do
        sleep "$UNKNOWN_RETRY_DELAY"
        view_json="$(gh pr view "$num" -R "$repo" --json mergeStateStatus 2>/dev/null)"
        status="$(printf '%s' "$view_json" | jq -r '.mergeStateStatus // empty' 2>/dev/null)"
        if [ -n "$status" ] && [ "$status" != "UNKNOWN" ]; then
          resolved="$status"
          break
        fi
        attempt=$((attempt + 1))
      done
      if [ -n "$resolved" ]; then
        overrides="$(printf '%s' "$overrides" | jq --arg n "$num" --arg s "$resolved" '. + {($n): $s}' 2>/dev/null)"
        [ -n "$overrides" ] || overrides="{}"
      fi
    done
    if [ "$overrides" != "{}" ]; then
      patched="$(printf '%s' "$raw" | jq --argjson ov "$overrides" '
        [ .[] | . as $pr | (($ov[($pr.number | tostring)]) // $pr.mergeStateStatus) as $ms
          | $pr | .mergeStateStatus = $ms ]
      ' 2>/dev/null)"
      [ -n "$patched" ] && raw="$patched"
    fi
  fi

  rows="$(printf '%s' "$raw" | jq -r --arg repo "$repo" \
    --argjson cutoff "$STALE_DRAFT_CUTOFF" --argjson staledays "$STALE_DRAFT_DAYS" '
    def rank: {"ready": 0, "needs-rebase": 1, "needs-attention": 2, "not-yet-computed": 3, "stale-draft": 4, "skip": 5};
    [ .[]
      | ( [ .statusCheckRollup[]?
            | select(
                ((.conclusion // "") | IN("FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"))
                or ((.state // "") | IN("FAILURE","ERROR")) ) ]
          | length ) as $failing
      | ( [ .statusCheckRollup[]?
            | select(
                (((.status // "") != "") and ((.status // "") != "COMPLETED"))
                or ((.state // "") | IN("PENDING","EXPECTED")) ) ]
          | length ) as $pending
      | ( ((.updatedAt // "") | (fromdateiso8601? // 9999999999)) ) as $upd
      | ( if (.isDraft and ($upd < $cutoff))
            then ["stale-draft",
                  "draft, idle \($staledays)+ days — a draft can never enqueue; flip it ready or close it"]
          elif .isDraft then ["skip", "draft"]
          elif (.title | test("do[ _-]?not[ _-]?merge"; "i")) then ["skip", "DO-NOT-MERGE marker in title"]
          elif .mergeStateStatus == "BEHIND" then ["needs-rebase", "BEHIND the base branch"]
          elif .mergeStateStatus == "DIRTY" then ["needs-rebase", "DIRTY (merge conflicts)"]
          elif $failing > 0 then ["needs-attention", "failing checks (\($failing))"]
          elif $pending > 0 then ["needs-attention", "checks still pending (\($pending))"]
          elif .mergeStateStatus == "CLEAN" then ["ready", "checks green + mergeStateStatus CLEAN — enqueue candidate"]
          elif .mergeStateStatus == "UNKNOWN" then ["not-yet-computed", "mergeStateStatus still UNKNOWN after retry — not yet computed by GitHub, resolves on a later sweep (no action needed)"]
          else ["needs-attention", "checks green but mergeStateStatus \(.mergeStateStatus)"]
          end ) as $cls
      | { cls: $cls[0], reason: $cls[1], n: .number, title: .title } ]
    | sort_by([(.cls | rank[.]), .n])
    | .[]
    | [ .cls, "\($repo)#\(.n)", .reason, .title ] | @tsv
  ' 2>/dev/null)" || {
    ERRORS=$((ERRORS + 1))
    ERR_REPOS="$ERR_REPOS $repo"
    notice "ERROR classifying PRs for $repo — continuing (fail-open)"
    continue
  }
  if [ -n "$rows" ]; then
    if [ -n "$ROWS" ]; then ROWS="$ROWS
$rows"; else ROWS="$rows"; fi
  fi
done

count_class() { [ -n "$ROWS" ] || { echo 0; return; }; printf '%s\n' "$ROWS" | grep -c "^$1	" || true; }
refs_class() { [ -n "$ROWS" ] || return 0; printf '%s\n' "$ROWS" | awk -F '\t' -v c="$1" '$1 == c { printf "%s%s", (n++ ? ", " : ""), $2 }'; }

N_READY="$(count_class ready)"
N_REBASE="$(count_class needs-rebase)"
N_ATTN="$(count_class needs-attention)"
N_UNKNOWN="$(count_class not-yet-computed)"
N_STALE_DRAFT="$(count_class stale-draft)"
N_SKIP="$(count_class skip)"
# not-yet-computed is deliberately EXCLUDED from N_CANDIDATES: it resolves on
# its own on a later sweep and carries no prescribed operator action, so it is
# never a --format entry candidate (nothing to decide) — see the class doc
# comment above.
N_CANDIDATES=$((N_READY + N_REBASE + N_ATTN + N_STALE_DRAFT))

# ── Output ────────────────────────────────────────────────────────────────────
if [ "$FORMAT" = "entry" ]; then
  # Nothing-when-clean: zero ready/needs-rebase/needs-attention candidates
  # (skip-only PRs and per-repo errors included) → no entry, exit 0.
  [ "$N_CANDIDATES" -gt 0 ] || exit 0
  host="$(hostname -s 2>/dev/null || hostname)"
  ts="$(date '+%Y-%m-%d %H:%M')"
  refs=""
  [ "$N_READY" -gt 0 ] && refs="ready: $(refs_class ready)"
  if [ "$N_REBASE" -gt 0 ]; then
    [ -n "$refs" ] && refs="$refs; "
    refs="${refs}needs-rebase: $(refs_class needs-rebase)"
  fi
  if [ "$N_ATTN" -gt 0 ]; then
    [ -n "$refs" ] && refs="$refs; "
    refs="${refs}needs-attention: $(refs_class needs-attention)"
  fi
  if [ "$N_STALE_DRAFT" -gt 0 ]; then
    [ -n "$refs" ] && refs="$refs; "
    refs="${refs}stale-draft: $(refs_class stale-draft)"
  fi
  printf '### %s · tidy ready-PR sweep · %s\n' "$ts" "$host"
  printf -- '- **Decision:** review complete-but-unmerged open PR(s) — %s\n' "$refs"
  printf -- '- **Default taken:** leave all (report-only; no PR merged, enqueued, rebased, closed, or commented)\n'
  printf -- '- **Disposition:** auto-taken (unattended tidy sweep; no live operator)\n'
  printf -- '- **Status:** open\n'
  exit 0
fi

echo "ready-pr sweep — repos: $REPOS"
if [ -n "$ROWS" ]; then
  printf '%s\n' "$ROWS" | awk -F '\t' '{ printf "  %-16s %-28s %s — %s\n", $1, $2, $3, $4 }'
else
  echo "  (no open PRs)"
fi
echo "summary: ready=$N_READY needs-rebase=$N_REBASE needs-attention=$N_ATTN not-yet-computed=$N_UNKNOWN stale-draft=$N_STALE_DRAFT skip=$N_SKIP errors=$ERRORS${ERR_REPOS:+ (errored:$ERR_REPOS)}"
exit 0
