#!/usr/bin/env bash
#
# issue-state.sh — single-issue state probe + (later) resume driver
# (temperloop #635/#636, epic #627 `/fix` targeted single-item fix driver).
#
# Two subcommands, one CLI dispatch skeleton (spike verdict
# [[Decisions/temperloop - fix-driver state-resolution seams (spike verdict)]]):
#
#   resolve <repo> <issue>    — reads ground-truth GitHub state for ONE issue
#     and prints a single JSON "route verdict" object to stdout: is it
#     closed, does it carry an open question, is it claimed by someone else,
#     does it already have an open linked PR, or is it fresh work. #635
#     (THIS item) implements this arm.
#
#   reattach ...               — resumes a driver against a pre-opened PR by
#     routing through claude/workflows/build-level.mjs's `mode:"reattach"`
#     (reuses its ciPollLoop + the #254 SHA-pin guard + the inline rebase —
#     see the spike verdict § (c)). #636 (a LATER item, depends-on this one)
#     implements this arm; until then it is a placeholder that refuses.
#
# This file is the CREATION of the shared skeleton — #636 adds a case arm,
# it does not restructure this dispatch.
#
# `resolve`'s ground truth: `gh issue view` for issue state/labels, and the
# shared `open_pr_for_issue` (workflows/scripts/build/lib/pr-linkage.sh) for
# any open PR that closes the issue. Labels are read against the SAME
# literal label vocabulary funnel-tick.sh classifies with — sourced from
# build.config.sh's FUNNEL_* knobs, never a re-declared parallel taxonomy
# (see `resolve`'s own label-constant set below, and
# tests/test_issue_state_label_subset.sh, the mechanical subset-lint against
# funnel-tick.sh's label set).
#
# DRY_RUN / $FIXTURE (offline test harness, mirrors funnel-tick.sh's own
# convention — read that file's header for the general shape):
#   $FIXTURE/issue-<issue>.json    — the `gh issue view --json
#                                     state,labels,assignees` shape:
#                                     {"state":"OPEN","labels":[{"name":"x"}],
#                                      "assignees":[{"login":"y"}]}
#   $FIXTURE/open-pr-<issue>.txt   — consumed by pr-linkage.sh's
#                                     open_pr_for_issue (one PR number per line)
#   $FIXTURE/pr-<n>.json           — the `gh pr view --json
#                                     number,draft,author,updatedAt` shape:
#                                     {"number":N,"draft":false,
#                                      "author":{"login":"x"},
#                                      "updatedAt":"2026-07-01T00:00:00Z"}
#   $FIXTURE/worktree-<issue>.txt  — optional; a single local worktree path
#                                     (best-effort field, see find_worktree
#                                     below)
#
# This file is EXECUTED (not sourced) — `set -euo pipefail` applies to the
# whole script.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null 2>&1 || { echo '{"error":"jq not found"}' >&2; exit 1; }

# Attribution for the gh call-logger shim (F#988) — same convention every
# build-spine entry point uses (funnel-tick.sh, funnel-drive.sh). See
# workflows/scripts/gh-call-logger.sh.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-issue-state}"

# ── Config (env overrides win; defaults centralized in build.config.sh) ─────
# shellcheck source=workflows/scripts/build/build.config.sh
[ -f "$HERE/build.config.sh" ] && . "$HERE/build.config.sh"
# Belt-and-suspenders fallback for a non-vendoring consuming checkout that
# doesn't carry build.config.sh at all (precedence rung 6, per CLAUDE.md's
# Prose-resident knob convention) — matches the literal defaults
# build.config.sh itself ships.
: "${FUNNEL_ESCALATED_LABEL:=funnel-escalated}"
: "${FUNNEL_MERGE_PENDING_LABEL:=funnel-merge-pending}"

# shellcheck source=workflows/scripts/build/lib/pr-linkage.sh
. "$HERE/lib/pr-linkage.sh"

# ── resolve's own label-constant set (subset-lint target) ───────────────────
# Every literal/knob this script reads to classify an issue's labels. The
# subset-lint (tests/test_issue_state_label_subset.sh) greps THIS block
# mechanically and asserts every name here is also read by funnel-tick.sh —
# i.e. resolve introduces no parallel label taxonomy. Do not add a label
# reference anywhere else in this file without adding it here too.
ISSUE_STATE_LABEL_NEEDS_CLARIFICATION="needs-clarification"
# The next three are vocabulary members funnel-tick.sh also reads but that
# resolve does not branch routing on (spike/decision are surfaced only via
# the raw labels[] pass-through below; funnel-escalated the same) — kept as
# named constants purely so the subset-lint has a mechanical grep target,
# per the spike verdict's route mapping. Not dead code: read by
# tests/test_issue_state_label_subset.sh, not by a route branch in this file.
# shellcheck disable=SC2034
ISSUE_STATE_LABEL_SPIKE="spike"
# shellcheck disable=SC2034
ISSUE_STATE_LABEL_DECISION="decision"
# shellcheck disable=SC2034
ISSUE_STATE_LABEL_FUNNEL_ESCALATED="$FUNNEL_ESCALATED_LABEL"
ISSUE_STATE_LABEL_FUNNEL_MERGE_PENDING="$FUNNEL_MERGE_PENDING_LABEL"

DRY_RUN=0
FIXTURE=""

usage() {
  cat >&2 <<'USAGE'
usage: issue-state.sh <subcommand> [args]

subcommands:
  resolve <repo> <issue> [--dry-run --fixture <dir>]
      Read ground-truth GitHub state for ONE issue and print a single JSON
      route-verdict object to stdout (route: fresh|adopt|question-first|
      claimed-elsewhere|already-done|ambiguous). See this file's header for
      the full verdict shape.

  reattach ...
      Resume a driver against a pre-opened PR. NOT YET IMPLEMENTED
      (temperloop #636) — this arm currently refuses.

  -h, --help
      Show this usage and exit 0.
USAGE
}

resolve_usage() {
  cat >&2 <<'USAGE'
usage: issue-state.sh resolve <repo> <issue> [--dry-run --fixture <dir>]

Reads ground-truth GitHub state for ONE issue (gh issue view + the shared
open-PR-by-linkage probe) and prints a single JSON route-verdict object to
stdout:

  {
    "repo": "owner/repo", "issue": 123, "issue_state": "open|closed",
    "open_prs": [{"number":N,"draft":bool,"author":"login",
                  "updated_at":"ISO8601","linkage":"closes"}],
    "claim": {"claimed":bool,"host_session":"host:sess|null","by_me":bool},
    "labels": ["<label>", ...],
    "worktree": "<path>|null",
    "route": "fresh|adopt|question-first|claimed-elsewhere|already-done|ambiguous",
    "reason": "<one-line why this route>"
  }

  --dry-run --fixture <dir>   Offline fixture mode (see this file's header
                               comment for the fixture layout).
USAGE
}

# ── gh/fixture reads ──────────────────────────────────────────────────────

# issue_state_get_issue <repo> <issue> — prints the raw `gh issue view
# --json state,labels,assignees` JSON (or its fixture equivalent).
issue_state_get_issue() {
  local repo="$1" issue="$2" f
  if [ "$DRY_RUN" -eq 1 ]; then
    f="$FIXTURE/issue-$issue.json"
    if [ -f "$f" ]; then cat "$f"; else echo '{}'; fi
    return 0
  fi
  gh issue view "$issue" -R "$repo" --json state,labels,assignees 2>/dev/null || echo '{}'
}

# issue_state_get_pr <repo> <pr-number> — prints the raw `gh pr view --json
# number,draft,author,updatedAt` JSON (or its fixture equivalent).
issue_state_get_pr() {
  local repo="$1" pr="$2" f
  if [ "$DRY_RUN" -eq 1 ]; then
    f="$FIXTURE/pr-$pr.json"
    if [ -f "$f" ]; then cat "$f"; else jq -cn --argjson n "$pr" '{number:$n}'; fi
    return 0
  fi
  gh pr view "$pr" -R "$repo" --json number,draft,author,updatedAt 2>/dev/null \
    || jq -cn --argjson n "$pr" '{number:$n}'
}

# find_worktree <repo> <issue> — BEST-EFFORT local worktree lookup. There is
# no mechanical issue-number -> worktree mapping in this repo's build spine
# (worktree.sh names a worktree `<repo-root>.wt/<slug>` off a PLAN ITEM'S
# `slug:` field — see CLAUDE.md § Branch & PR policy — with no issue number
# recorded in `.build-guard`), so this is a heuristic, not a guarantee:
# scan `git worktree list --porcelain` for a branch whose name contains the
# issue number as a standalone token (the common `<type>/<slug>-<issue>` /
# `<type>/<issue>-<slug>` naming a human or /build often uses, e.g. this
# repo's own `fix/vdb-checkb-dim0-conditional-512`). A miss is not evidence
# no worktree exists — just that this heuristic didn't find one.
find_worktree() {
  local repo="$1" issue="$2" f line path branch
  if [ "$DRY_RUN" -eq 1 ]; then
    f="$FIXTURE/worktree-$issue.txt"
    if [ -f "$f" ]; then
      head -n1 "$f"
    fi
    return 0
  fi
  path=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      branch\ *)
        branch="${line#branch }"
        branch="${branch#refs/heads/}"
        if [[ "$branch" =~ (^|[^0-9])$issue($|[^0-9]) ]]; then
          printf '%s\n' "$path"
          return 0
        fi
        path=""
        ;;
    esac
  done < <(git -C "$HERE" worktree list --porcelain 2>/dev/null; echo)
  return 0
}

# ── resolve ──────────────────────────────────────────────────────────────
cmd_resolve() {
  local repo="" issue="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --fixture) FIXTURE="${2:?--fixture needs a dir}"; shift 2 ;;
      -h|--help) resolve_usage; exit 0 ;;
      -*) echo "issue-state.sh resolve: unknown flag '$1'" >&2; resolve_usage; exit 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [ "${#args[@]}" -ne 2 ]; then
    echo "issue-state.sh resolve: expected <repo> <issue>" >&2
    resolve_usage
    exit 2
  fi
  repo="${args[0]}"; issue="${args[1]}"

  if [ "$DRY_RUN" -eq 1 ] && [ -z "$FIXTURE" ]; then
    echo "issue-state.sh resolve: --dry-run requires --fixture <dir>" >&2
    exit 2
  fi
  if [ -n "$FIXTURE" ] && [ ! -d "$FIXTURE" ]; then
    echo "issue-state.sh resolve: fixture dir not found: $FIXTURE" >&2
    exit 2
  fi

  local issue_json issue_state_raw issue_state labels_json route reason
  issue_json="$(issue_state_get_issue "$repo" "$issue")"
  issue_state_raw="$(jq -r '.state // "OPEN"' <<<"$issue_json")"
  issue_state="$(printf '%s' "$issue_state_raw" | tr '[:upper:]' '[:lower:]')"
  labels_json="$(jq -c '[(.labels // [])[]?.name]' <<<"$issue_json")"

  has_label() {
    jq -e --arg l "$1" 'any(.[]; . == $l)' <<<"$labels_json" >/dev/null 2>&1
  }

  # ── claim state (fnd:host/session:<host>:<session> label — issues-only
  # backend convention, workflows/scripts/board/ISSUES-ONLY-BACKEND.md
  # § The label vocabulary) ──────────────────────────────────────────────
  local host_session cur_host cur_stamp claimed by_me
  host_session="$(jq -r '
    [(.labels // [])[]?.name | select(startswith("fnd:host/session:"))][0] // empty
    | sub("^fnd:host/session:"; "")' <<<"$issue_json")"
  cur_host="${SUBSET_HOST_LABEL:-$(hostname -s 2>/dev/null || echo unknown)}"
  cur_stamp=""
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    cur_stamp="${cur_host}:${CLAUDE_CODE_SESSION_ID:0:8}"
  fi
  claimed=false; by_me=false
  if [ -n "$host_session" ]; then
    claimed=true
    if [ -n "$cur_stamp" ] && [ "$host_session" = "$cur_stamp" ]; then
      by_me=true
    fi
  fi

  # ── open-PR linkage (shared lib) ────────────────────────────────────────
  local pr_numbers pr_count open_prs_json="[]" num pr_json
  pr_numbers="$(open_pr_for_issue "$repo" "$issue")"
  pr_count=0
  if [ -n "$pr_numbers" ]; then
    while IFS= read -r num; do
      [ -z "$num" ] && continue
      pr_count=$((pr_count + 1))
      pr_json="$(issue_state_get_pr "$repo" "$num")"
      open_prs_json="$(jq -c --argjson d "$pr_json" --argjson n "$num" '. + [{
          number: ($d.number // $n),
          draft: ($d.draft // false),
          author: ($d.author.login // null),
          updated_at: ($d.updatedAt // null),
          linkage: "closes"
        }]' <<<"$open_prs_json")"
    done <<<"$pr_numbers"
  fi

  # ── route precedence (first match wins) ─────────────────────────────────
  if [ "$issue_state" = "closed" ]; then
    route="already-done"
    reason="issue is closed"
  elif has_label "$ISSUE_STATE_LABEL_NEEDS_CLARIFICATION"; then
    route="question-first"
    reason="labeled $ISSUE_STATE_LABEL_NEEDS_CLARIFICATION"
  elif [ "$claimed" = true ] && [ "$by_me" = false ]; then
    route="claimed-elsewhere"
    reason="in progress, claimed by $host_session"
  elif [ "$pr_count" -gt 1 ]; then
    route="ambiguous"
    reason="$pr_count open PRs link to this issue"
  elif [ "$pr_count" -eq 1 ]; then
    route="adopt"
    reason="one open PR (#$(jq -r '.[0].number' <<<"$open_prs_json")) links to this issue"
  elif has_label "$ISSUE_STATE_LABEL_FUNNEL_MERGE_PENDING"; then
    route="adopt"
    reason="labeled $ISSUE_STATE_LABEL_FUNNEL_MERGE_PENDING"
  else
    route="fresh"
    reason="open, unclaimed, no linked PR"
  fi

  local worktree_path
  worktree_path="$(find_worktree "$repo" "$issue")"

  jq -cn \
    --arg repo "$repo" \
    --argjson issue "$issue" \
    --arg issue_state "$issue_state" \
    --argjson open_prs "$open_prs_json" \
    --argjson claimed "$claimed" \
    --arg host_session "$host_session" \
    --argjson by_me "$by_me" \
    --argjson labels "$labels_json" \
    --arg worktree "$worktree_path" \
    --arg route "$route" \
    --arg reason "$reason" \
    '{
      repo: $repo,
      issue: $issue,
      issue_state: $issue_state,
      open_prs: $open_prs,
      claim: {
        claimed: $claimed,
        host_session: (if $host_session == "" then null else $host_session end),
        by_me: $by_me
      },
      labels: $labels,
      worktree: (if $worktree == "" then null else $worktree end),
      route: $route,
      reason: $reason
    }'
}

# ── reattach (placeholder — temperloop #636) ────────────────────────────
cmd_reattach() {
  echo "reattach: not yet implemented (temperloop #636)" >&2
  exit 1
}

# ── dispatch ─────────────────────────────────────────────────────────────
# No subcommand at all is a usage ERROR (exit 2) — only an EXPLICIT -h/--help
# request exits 0, per this file's activation-proof contract.
if [ $# -eq 0 ]; then
  usage
  exit 2
fi

sub="$1"; shift
case "$sub" in
  resolve) cmd_resolve "$@" ;;
  reattach) cmd_reattach "$@" ;;
  -h|--help) usage; exit 0 ;;
  *)
    echo "issue-state.sh: unknown subcommand '$sub'" >&2
    usage
    exit 2
    ;;
esac
