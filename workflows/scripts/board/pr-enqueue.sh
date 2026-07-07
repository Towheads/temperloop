#!/usr/bin/env bash
#
# pr-enqueue — create a PR and enqueue it into the merge queue in ONE
# invocation, then CONFIRM the queued state. A dev-process helper co-deployed
# with the board toolkit (PATH symlink via `make install-board`; real-file
# vendor copy into consuming repos via `make sync-*-board`) so a single command
# run from ANY repo checkout produces a created-and-queued PR with no
# per-session rediscovery. Motivated by foundation #534 (the sf-audio session
# postmortem stumble #5).
#
# It kills two recurring frictions:
#
#   (a) origin casing/host mismatch — a local `origin` remote whose owner/repo
#       casing (or a since-renamed owner) differs from the canonical repo makes
#       `gh pr create` fail with "No commits between …" / "Head repository
#       can't be blank" until a `gh repo set-default` is run by hand. This
#       helper RESOLVES the canonical `owner/repo` from origin via the
#       case-insensitive, redirect-following `gh api repos/<owner>/<repo>`
#       (its `.full_name`) and sets the gh default before creating the PR.
#
#   (b) merge-queue enqueue ambiguity — `gh pr merge --merge` is REJECTED on a
#       queue-required main ("merge strategy for main is set by the merge
#       queue"), while a BARE `gh pr merge` silently enqueues with no output,
#       leaving it unclear whether it worked. This helper enqueues with the
#       bare form (the queue owns the strategy — NO method-flag guesswork) and
#       then CONFIRMS the PR is in the queue (or already merged) via the
#       `isInMergeQueue` / `mergeQueueEntry` GraphQL fields, exiting non-zero
#       with a clear message if the enqueue cannot be confirmed.
#
# Usage:
#   pr-enqueue [--title <t>] [--body <b>] [--base <branch>] [--head <branch>]
#              [--repo <owner/repo>] [--draft] [--fill] [--json]
#
#   --title/-t    PR title. If omitted (and --fill not given), --fill is used.
#   --body/-b     PR body. Defaults to "" when --title is given without a body.
#   --base/-B     Base branch (default: the repo's default branch, via the
#                 resolved gh default repo).
#   --head/-H     Head branch (default: the current branch).
#   --repo/-R     Override origin resolution with an explicit owner/repo.
#   --draft/-d    Open the PR as a draft (a draft cannot enqueue — this errors
#                 unless combined with a later manual ready+enqueue; documented).
#   --fill        Fill title/body from the branch's commits.
#   --json        Emit one machine-readable JSON line instead of prose.
#
# Test seams (mirroring the board toolkit's _board_gh seam):
#   PR_ENQUEUE_GH   gh binary override            (default: gh)
#   PR_ENQUEUE_GIT  git binary override           (default: git)
#   PR_ENQUEUE_CONFIRM_RETRIES   queued-state confirm attempts (default: 5)
#   PR_ENQUEUE_CONFIRM_INTERVAL  seconds between attempts       (default: 2)
#
# Exit status: 0 iff the PR was created (or adopted) AND confirmed queued (or
# already merged); non-zero with a clear stderr message on any failure.
set -euo pipefail

PROG="pr-enqueue"
GH="${PR_ENQUEUE_GH:-gh}"
GIT="${PR_ENQUEUE_GIT:-git}"
CONFIRM_RETRIES="${PR_ENQUEUE_CONFIRM_RETRIES:-5}"
CONFIRM_INTERVAL="${PR_ENQUEUE_CONFIRM_INTERVAL:-2}"

JSON=""

command -v jq >/dev/null 2>&1 || { printf '%s: error: jq not found\n' "$PROG" >&2; exit 1; }

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
note() { [ -n "$JSON" ] || printf '%s\n' "$*"; }

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- parse args ---------------------------------------------------------------
title="" body="" body_set="" base="" head="" repo="" draft="" fill=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t|--title)  [ $# -ge 2 ] || die "$1 requires a value"; title="$2"; shift 2 ;;
    -b|--body)   [ $# -ge 2 ] || die "$1 requires a value"; body="$2"; body_set=1; shift 2 ;;
    -B|--base)   [ $# -ge 2 ] || die "$1 requires a value"; base="$2"; shift 2 ;;
    -H|--head)   [ $# -ge 2 ] || die "$1 requires a value"; head="$2"; shift 2 ;;
    -R|--repo)   [ $# -ge 2 ] || die "$1 requires a value"; repo="$2"; shift 2 ;;
    -d|--draft)  draft=1; shift ;;
    --fill)      fill=1; shift ;;
    --json)      JSON=1; shift ;;
    -h|--help)   usage 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

# --- resolve canonical owner/repo + set the gh default ------------------------
# Parse `origin` into owner/repo when --repo was not given. Handles the common
# URL shapes: https://host/O/R(.git), git@host:O/R(.git), ssh://git@host/O/R.git.
parse_origin_nwo() {
  local url nwo
  url="$("$GIT" remote get-url origin 2>/dev/null)" \
    || die "no 'origin' remote in $(pwd) — pass --repo <owner/repo>"
  nwo="$(printf '%s' "$url" \
    | sed -E 's#^[A-Za-z]+://##; s#^[^@/]*@##; s#^[^/:]+[:/]##; s#\.git/?$##; s#/$##')"
  [ -n "$nwo" ] && [ "$nwo" != "$url" ] || die "could not parse owner/repo from origin URL: $url"
  case "$nwo" in
    */*) : ;;
    *) die "origin URL did not resolve to owner/repo: $url" ;;
  esac
  printf '%s' "$nwo"
}

raw_nwo="${repo:-$(parse_origin_nwo)}"
raw_owner="${raw_nwo%%/*}"
raw_repo="${raw_nwo##*/}"
[ -n "$raw_owner" ] && [ -n "$raw_repo" ] || die "invalid owner/repo '$raw_nwo'"

# Canonicalize via the REST endpoint: it is case-insensitive on both owner and
# repo AND follows owner/repo renames (301), so a mismatched-casing/renamed
# origin resolves to the true `Owner/Repo`.
canonical="$("$GH" api "repos/$raw_owner/$raw_repo" --jq '.full_name' 2>/dev/null || true)"
if [ -z "$canonical" ]; then
  # API miss (offline / private-scope): fall back to the parsed value so the
  # command still targets a concrete repo, but surface why we could not confirm.
  canonical="$raw_owner/$raw_repo"
  note "warning: could not resolve canonical repo via 'gh api repos/$raw_owner/$raw_repo'; using '$canonical'"
fi
canon_owner="${canonical%%/*}"
canon_name="${canonical##*/}"

"$GH" repo set-default "$canonical" >/dev/null 2>&1 \
  || die "gh repo set-default '$canonical' failed — is gh authenticated?"
note "repo: $canonical (gh default set)"

# --- create the PR ------------------------------------------------------------
if [ -z "$title" ] && [ -z "$fill" ]; then
  fill=1   # non-interactive default: fill title/body from the branch's commits
fi

# Build the create argv, omitting --base/--head unless given so gh applies its
# own defaults (the default branch / the current branch).
create_args=(pr create)
[ -n "$base" ] && create_args+=(--base "$base")
[ -n "$head" ] && create_args+=(--head "$head")
if [ -n "$fill" ]; then
  create_args+=(--fill)
else
  create_args+=(--title "$title")
  # A --title without a body would open an editor in non-interactive use; pass
  # an explicit (possibly empty) body so the create never blocks.
  create_args+=(--body "${body}")
  [ -n "$body_set" ] || note "note: no --body given; creating with an empty body"
fi
[ -n "$draft" ] && create_args+=(--draft)

adopted=""
if out="$("$GH" "${create_args[@]}" 2>&1)"; then
  :
else
  if grep -qiE 'a pull request for branch .* already exists' <<<"$out"; then
    adopted=1
  else
    die "gh pr create failed: $out"
  fi
fi

pr_url="$(grep -oE 'https?://[^[:space:]]+/pull/[0-9]+' <<<"$out" | tail -1 || true)"
pr_number="${pr_url##*/}"
case "$pr_number" in
  ''|*[!0-9]*) die "could not parse PR number from gh output: $out" ;;
esac
if [ -n "$adopted" ]; then note "adopted existing PR #$pr_number"; else note "created PR #$pr_number"; fi

# --- enqueue into the merge queue (BARE `gh pr merge` — queue owns strategy) ---
if [ -n "$draft" ]; then
  die "PR #$pr_number is a draft — a draft cannot enqueue; mark it ready then re-run pr-enqueue (or drop --draft)"
fi

if merge_out="$("$GH" pr merge "$pr_number" 2>&1)"; then
  :
else
  # A re-run (adopted / already-queued PR) reports a benign "already queued";
  # anything else — notably a non-queue main demanding a method flag — is fatal.
  if grep -qiE 'already queued|in a merge queue|already in the merge queue' <<<"$merge_out"; then
    :
  elif grep -qiE 'required when not running interactively|--merge, --rebase, or --squash' <<<"$merge_out"; then
    die "gh pr merge #$pr_number wants a method flag — this repo's main is NOT queue-required; pr-enqueue targets queue-required mains: $merge_out"
  else
    die "gh pr merge #$pr_number failed to enqueue: $merge_out"
  fi
fi

# --- confirm the queued (or already-merged) state -----------------------------
# The $owner/$name/$number tokens are GraphQL variables, not shell expansions.
# shellcheck disable=SC2016
CONFIRM_QUERY='query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      state merged isInMergeQueue
      mergeQueueEntry{ state position }
    }
  }
}'

confirmed="" pr_state="" q_state="" q_position="" merged=""
i=0
while [ "$i" -lt "$CONFIRM_RETRIES" ]; do
  i=$((i + 1))
  cj="$("$GH" api graphql -f query="$CONFIRM_QUERY" \
        -f owner="$canon_owner" -f name="$canon_name" -F number="$pr_number" \
        2>/dev/null || true)"
  if [ -n "$cj" ]; then
    pr_state="$(jq -r '.data.repository.pullRequest.state // ""' <<<"$cj" 2>/dev/null || echo "")"
    merged="$(jq -r '.data.repository.pullRequest.merged // false' <<<"$cj" 2>/dev/null || echo false)"
    inqueue="$(jq -r '.data.repository.pullRequest.isInMergeQueue // false' <<<"$cj" 2>/dev/null || echo false)"
    q_state="$(jq -r '.data.repository.pullRequest.mergeQueueEntry.state // ""' <<<"$cj" 2>/dev/null || echo "")"
    q_position="$(jq -r '.data.repository.pullRequest.mergeQueueEntry.position // ""' <<<"$cj" 2>/dev/null || echo "")"
    if [ "$merged" = "true" ] || [ "$inqueue" = "true" ]; then
      confirmed=1
      break
    fi
  fi
  [ "$i" -lt "$CONFIRM_RETRIES" ] && sleep "$CONFIRM_INTERVAL"
done

if [ -z "$confirmed" ]; then
  die "PR #$pr_number was created but could NOT be confirmed in the merge queue after $CONFIRM_RETRIES attempt(s) (state=${pr_state:-?}) — check 'gh pr view $pr_number' manually"
fi

# --- report -------------------------------------------------------------------
if [ -n "$JSON" ]; then
  jq -cn \
    --arg repo "$canonical" \
    --argjson number "$pr_number" \
    --arg url "$pr_url" \
    --arg state "$pr_state" \
    --argjson merged "${merged:-false}" \
    --arg queue_state "$q_state" \
    --arg position "$q_position" \
    '{outcome:(if $merged then "MERGED" else "QUEUED" end),
      repo:$repo, pr_number:$number, url:$url, pr_state:$state,
      merged:$merged, queue_state:$queue_state,
      position:(if $position=="" then null else ($position|tonumber) end)}'
else
  if [ "${merged:-false}" = "true" ]; then
    note "✓ PR #$pr_number already merged: $pr_url"
  else
    posn=""
    [ -n "$q_position" ] && posn=" (position $q_position)"
    note "✓ PR #$pr_number enqueued in the merge queue${posn}: $pr_url"
  fi
fi
