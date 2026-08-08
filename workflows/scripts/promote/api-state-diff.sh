#!/usr/bin/env bash
#
# api-state-diff.sh — the DIFF + RECORD + HANDOFF half of /promote's API-state
# story (temperloop#1236, epic #1117 Produces 6b).
#
# ── Scope, and the line it deliberately does not cross ─────────────────────
# Branch protection, required status checks, labels, and board configuration
# are GitHub API STATE, not tree state: they cannot ride a pull request the
# way commits do (push-testbed-branch.sh's job), so "promoting" them means
# something different — re-applying them by RUNNING the adopt path
# (`temperloop init`) in the real repository, as its OWN separately consented
# step. This script never runs that step. It has exactly three jobs, named in
# its three subcommands, and none of them is "apply":
#
#   diff    — READ-ONLY. Show the target's CURRENT settings next to the
#             testbed's settings, before the operator decides whether to run
#             the adopt path at all. Zero writes, always.
#   record  — the ONLY subcommand that writes anything, and it writes to
#             exactly one place: a durable, team-visible GitHub issue or pull
#             request COMMENT in the target repository (never a branch
#             protection call, never a label call — those belong to
#             `temperloop init`, not to this script).
#   report  — pure formatting. Renders the three-part migrated /
#             re-applied / left-to-you breakdown record uses, and refuses a
#             uniform "migration complete"-shaped claim structurally (see
#             render_report below) rather than leaving that to prose
#             discipline.
#
# Owning the apply here would bend ADR 0023's biconditional (docs/adr/0023)
# the first time it happened — apply is pre-checkout-shaped judgment-free
# mechanism ONLY when it is the CLI's `temperloop init`; done again here it
# would be a second, undisciplined path to the same state change.
#
# ── Why the diff step exists at all ─────────────────────────────────────────
# `temperloop init` in the real repository does not know it is being run
# after a promotion — to it, this is just another init. If the operator has a
# deliberate branch-protection or label setup already, running init blind
# overwrites a choice they made on purpose. Showing current-vs-proposed FIRST
# is what turns "adopt path overwrote my settings" into an informed decision.
#
# ── The three-part report, and why it is structural, not a style rule ──────
# /promote's own "Report the three operations as three different things"
# section forbids a uniform "migration complete" claim. `render_report` takes
# three REQUIRED, separately-labeled arguments (migrated / re-applied / left
# to you) — there is no code path that produces output without all three
# headers present, and each of the three inputs is checked for the forbidden
# phrase itself sneaking in disguised as one of the parts (see
# FORBIDDEN_PHRASE below). A test cannot assert against prose in a slash
# command; it CAN assert against this script's shape, which is the entire
# reason this lives in a script at all (ADR 0023's own rationale for the
# mechanical half of /promote).
#
# Usage:
#   api-state-diff.sh diff --to OWNER/NAME --from OWNER/NAME
#
#   api-state-diff.sh record --to OWNER/NAME --testbed-repo OWNER/NAME \
#       --migrated TEXT --reapplied TEXT --left TEXT \
#       (--issue N | --pr N | --create-issue) [--title TEXT]
#
#   api-state-diff.sh report --migrated TEXT --reapplied TEXT --left TEXT
#
#   diff subcommand:
#     --to OWNER/NAME        REQUIRED. The real repository whose CURRENT
#                            settings are being read. Never inferred.
#     --from OWNER/NAME      REQUIRED. The testbed (or any other repository)
#                            whose settings are the PROPOSED side of the
#                            diff. Never inferred.
#
#   record subcommand:
#     --to OWNER/NAME        REQUIRED. The real repository the durable record
#                            is left IN. Never inferred.
#     --testbed-repo OWNER/NAME
#                            REQUIRED. Named explicitly in the record so a
#                            reader with no context can tell this came from a
#                            temperloop evaluation testbed, and which one.
#     --migrated TEXT        REQUIRED. What actually rode the pull request as
#                            tree state (or "(none)" if nothing did).
#     --reapplied TEXT       REQUIRED. What was re-applied by running the
#                            adopt path (or "(none)" / "not yet run").
#     --left TEXT            REQUIRED. What still needs a human decision (or
#                            "(none)").
#     --issue N              Comment on existing issue N in --to.
#     --pr N                 Comment on existing pull request N in --to.
#     --create-issue         Create a new issue in --to instead (needs
#                            --title).
#     --title TEXT           Title for --create-issue.
#
#   report subcommand:
#     --migrated / --reapplied / --left as above. Prints the three-part block
#     to stdout; writes nothing.
#
# Dependencies: bash 3.2+, gh, jq. Zero network required to TEST it (the test
# suite puts a fake `gh` on PATH).

set -euo pipefail

PROG="api-state-diff.sh"
FORBIDDEN_PHRASE="migration complete"

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 1; }
note() { printf '%s\n' "$1"; }

usage() {
  sed -n '/^# Usage:/,/^# Dependencies:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# <value> -> 0 when it is exactly "<owner>/<name>".
is_owner_name() {
  case "$1" in
    */*/*) return 1 ;;
    */*) [ -n "${1%%/*}" ] && [ -n "${1#*/}" ] ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Read-only GitHub API helpers. Every one of these is a GET — none ever
# passes -X/--method, which is what lets the diff subcommand's zero-write
# guarantee be a fact about this file rather than a claim about it.
# ---------------------------------------------------------------------------
fetch_default_branch() {
  gh api "repos/$1" --jq '.default_branch // ""' 2>/dev/null || true
}

fetch_labels() {
  gh api "repos/$1/labels" --paginate --jq '[.[].name] | sort' 2>/dev/null || printf '[]'
}

fetch_required_checks() {
  local repo="$1" branch="$2"
  [ -n "$branch" ] || { printf '[]'; return; }
  gh api "repos/$repo/branches/$branch/protection/required_status_checks/contexts" \
    --jq '. | sort' 2>/dev/null || printf '[]'
}

# <current-json-array> <proposed-json-array> <label> -> prints an
# added/removed/unchanged breakdown for one category. Read-only; pure text.
diff_category() {
  local cur="$1" prop="$2" label="$3" added removed unchanged
  added="$(jq -cn --argjson a "$cur" --argjson b "$prop" '($b - $a)')"
  removed="$(jq -cn --argjson a "$cur" --argjson b "$prop" '($a - $b)')"
  unchanged="$(jq -cn --argjson a "$cur" --argjson b "$prop" '($a - ($a - $b))')"
  note ""
  note "  $label"
  note "    current:   $cur"
  note "    proposed:  $prop"
  note "    + added:     $added"
  note "    - removed:   $removed"
  note "    = unchanged: $unchanged"
}

# ---------------------------------------------------------------------------
# diff — READ-ONLY. Never writes; asserted by the test suite by logging every
# gh invocation this subcommand makes and checking none carries -X/--method
# or a gh issue/pr/api-write subcommand.
# ---------------------------------------------------------------------------
cmd_diff() {
  local to="" from=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) to="${2:-}"; shift 2 ;;
      --from) from="${2:-}"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "diff: unknown argument: $1 (run --help)" ;;
    esac
  done

  [ -n "$to" ] || die "diff: --to <owner>/<name> is required — the target repository is never inferred"
  is_owner_name "$to" || die "diff: --to must be exactly \"<owner>/<name>\", got: $to"
  [ -n "$from" ] || die "diff: --from <owner>/<name> is required — the proposed side is never inferred"
  is_owner_name "$from" || die "diff: --from must be exactly \"<owner>/<name>\", got: $from"

  command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
  command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

  local to_branch from_branch cur_labels prop_labels cur_checks prop_checks
  to_branch="$(fetch_default_branch "$to")"
  from_branch="$(fetch_default_branch "$from")"
  cur_labels="$(fetch_labels "$to")"
  prop_labels="$(fetch_labels "$from")"
  cur_checks="$(fetch_required_checks "$to" "$to_branch")"
  prop_checks="$(fetch_required_checks "$from" "$from_branch")"

  note "api-state diff — DIFF ONLY, nothing has been changed"
  note "  current   (target)   $to"
  note "  proposed  (testbed)  $from"
  diff_category "$cur_labels" "$prop_labels" "labels"
  diff_category "$cur_checks" "$prop_checks" "required status checks ($to_branch)"
  note ""
  note "This is a diff, not a migration: nothing above has been applied. You are"
  note "about to potentially override a deliberate prior choice on $to, not adopt"
  note "a blank slate. Re-applying happens only by running the adopt path"
  note "(\`temperloop init\`) in $to as its own separately consented step; this"
  note "script never runs it."
}

# ---------------------------------------------------------------------------
# render_report — pure formatting, zero writes. THE structural guard against
# a uniform "migration complete" claim: all three parts are required
# arguments (no code path can omit one), and each is independently checked
# for the forbidden phrase, so a caller cannot launder a blanket claim in
# through any one of the three slots either.
# ---------------------------------------------------------------------------
render_report() {
  local migrated="$1" reapplied="$2" left="$3" f
  for f in "$migrated" "$reapplied" "$left"; do
    case "$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')" in
      *"$FORBIDDEN_PHRASE"*)
        die "report: a part of the three-way report reads as a uniform \"$FORBIDDEN_PHRASE\" claim, which is forbidden — migrated / re-applied / left-to-you must each say what is actually true, never collapse into one blanket claim"
        ;;
    esac
  done
  note "## Migrated (rode the pull request as real commits)"
  note "$migrated"
  note ""
  note "## Re-applied (by running the adopt path, \`temperloop init\`)"
  note "$reapplied"
  note ""
  note "## Left to you (needs a human decision)"
  note "$left"
}

cmd_report() {
  local migrated="" reapplied="" left=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --migrated) migrated="${2:-}"; shift 2 ;;
      --reapplied) reapplied="${2:-}"; shift 2 ;;
      --left) left="${2:-}"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "report: unknown argument: $1 (run --help)" ;;
    esac
  done
  [ -n "$migrated" ] || die "report: --migrated is required — the three-part report has no optional part"
  [ -n "$reapplied" ] || die "report: --reapplied is required — the three-part report has no optional part"
  [ -n "$left" ] || die "report: --left is required — the three-part report has no optional part"
  render_report "$migrated" "$reapplied" "$left"
}

# ---------------------------------------------------------------------------
# record — the ONLY subcommand that writes, and the only thing it writes is a
# comment or issue in the TARGET repository. It never touches branch
# protection, labels, or any other API-state endpoint.
# ---------------------------------------------------------------------------
cmd_record() {
  local to="" testbed_repo="" migrated="" reapplied="" left=""
  local issue="" pr="" create_issue=0 title=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) to="${2:-}"; shift 2 ;;
      --testbed-repo) testbed_repo="${2:-}"; shift 2 ;;
      --migrated) migrated="${2:-}"; shift 2 ;;
      --reapplied) reapplied="${2:-}"; shift 2 ;;
      --left) left="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --pr) pr="${2:-}"; shift 2 ;;
      --create-issue) create_issue=1; shift ;;
      --title) title="${2:-}"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "record: unknown argument: $1 (run --help)" ;;
    esac
  done

  [ -n "$to" ] || die "record: --to <owner>/<name> is required — the durable record's home is never inferred"
  is_owner_name "$to" || die "record: --to must be exactly \"<owner>/<name>\", got: $to"
  [ -n "$testbed_repo" ] || die "record: --testbed-repo <owner>/<name> is required — the record must name where this evaluation came from"
  [ -n "$migrated" ] || die "record: --migrated is required — the three-part report has no optional part"
  [ -n "$reapplied" ] || die "record: --reapplied is required — the three-part report has no optional part"
  [ -n "$left" ] || die "record: --left is required — the three-part report has no optional part"

  local target_count=0
  [ -n "$issue" ] && target_count=$((target_count + 1))
  [ -n "$pr" ] && target_count=$((target_count + 1))
  [ "$create_issue" -eq 1 ] && target_count=$((target_count + 1))
  [ "$target_count" -eq 1 ] \
    || die "record: exactly one of --issue N, --pr N, or --create-issue is required (got $target_count) — the durable record needs exactly one home"
  if [ "$create_issue" -eq 1 ]; then
    [ -n "$title" ] || die "record: --create-issue requires --title"
  fi

  command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"

  local provenance body report_body out
  provenance="$(printf 'This is a durable record of API-state migration following a temperloop evaluation — the source testbed was %s. Branch protection, required checks, labels, and board configuration are GitHub API state and do not ride a pull request; this record exists so that fact is legible in %s itself, not only in a terminal a promotion operator once looked at.' "$testbed_repo" "$to")"
  report_body="$(render_report "$migrated" "$reapplied" "$left")"
  body="$(printf '%s\n\n%s' "$provenance" "$report_body")"

  if [ -n "$issue" ]; then
    if ! out="$(gh issue comment "$issue" --repo "$to" --body "$body" 2>&1)"; then
      die "record: gh issue comment on $to#$issue failed: $out"
    fi
    note "  ok left a durable record as a comment on $to#$issue"
  elif [ -n "$pr" ]; then
    if ! out="$(gh pr comment "$pr" --repo "$to" --body "$body" 2>&1)"; then
      die "record: gh pr comment on $to#$pr failed: $out"
    fi
    note "  ok left a durable record as a comment on $to pull request #$pr"
  else
    if ! out="$(gh issue create --repo "$to" --title "$title" --body "$body" 2>&1)"; then
      die "record: gh issue create on $to failed: $out"
    fi
    note "  ok left a durable record as a new issue in $to: $out"
  fi
  note "  the record is IN $to — a reviewer with no context on this process can find it there later."
}

# ---------------------------------------------------------------------------
main() {
  [ $# -gt 0 ] || { usage; exit 2; }
  case "$1" in
    diff) shift; cmd_diff "$@" ;;
    record) shift; cmd_record "$@" ;;
    report) shift; cmd_report "$@" ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown subcommand: $1 (expected 'diff', 'record', or 'report')" ;;
  esac
}

main "$@"
