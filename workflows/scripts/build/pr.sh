#!/usr/bin/env bash
#
# build push + PR-open mechanics — the deterministic-spine script that owns
# the 3f steps of /build (epic #253, spike #245): the closing-keyword
# pre-push scan, the speculative base-currency check, push-by-SHA, and PR-body
# assembly from the worker verdict JSON + plan fields. A step moved here iff
# its behavior is a pure function of observable machine state with a closed
# outcome set; the judgment-shaped halves (rewording an offending commit, the
# BASE_STALE rebase/conflict handling, branch-collision triage) stay
# orchestrator-driven in build.md and branch on these outcomes.
#
#   pr.sh scan <worktreePath>                  # closing-keyword pre-push scan
#   pr.sh base-check <worktreePath>            # speculative base-currency check
#   pr.sh rebase <worktreePath>                # rebase onto fresh origin/<default>
#   pr.sh push <worktreePath> <branch> [--force]   # push HEAD by SHA
#   pr.sh open --verdict <file|-> [--gh-issue N] [--also-closes N,N,...]
#         [--plan-link <target>] [--source <ref>] [--verification-surface-file <path>] \
#         ( --body-only | --repo <repo-root> --branch <b> --title <t> )
#
# `open` assembles the PR body from the worker's verdict JSON (summary,
# acceptance_results — the 3d return contract) plus the plan fields, then runs
# `gh pr create`. The ## Verification section's body is resolved by precedence
# (the #418 inflow-cut): --verification-surface-file <path> if given, else the
# verdict's `.verification_surface_path` (a file the worker wrote in its
# worktree and returned only the path to), else the inline `.verification_surface`
# field (back-compat), else the acceptance recap. Reading the surface from a
# file keeps that large block OUT of the orchestrator's context — it never
# round-trips through the verdict JSON. Issue linkage lives HERE and only
# here: one bare `Closes #N` line per gh_issue/also_closes entry, each on its
# own line, never combined, never backticked (GitHub silently ignores
# backticked keywords, and `Closes #1 and #2` closes only #1). `--body-only`
# prints the assembled body verbatim and exits — the dry mode tests assert on.
#
# Output contract — CLOSED outcome set, one structured JSON line per outcome
# (exception: `open --body-only` prints the raw body, no JSON wrapper):
#   scan       → {"outcome":"SCAN_CLEAN"} |
#                {"outcome":"SCAN_BLOCKED","matches":[…]} + non-zero exit
#   base-check → {"outcome":"BASE_CURRENT"|"BASE_STALE","merge_base":…,"tip":…}
#   rebase     → {"outcome":"REBASED","base":…,"tip":…,"sha":…} |
#                {"outcome":"REBASE_CONFLICT","base":…,"tip":…} + non-zero exit
#   push       → {"outcome":"PUSHED","sha":…,"branch":…} |
#                {"outcome":"PUSH_REJECTED","sha":…,"branch":…,"error":…} + non-zero exit
#   open       → {"outcome":"PR_OPENED","pr_number":…,"url":…} |
#                {"outcome":"EXISTS","pr_number":…,"url":…}
#                (EXISTS when gh reports a PR for that branch already exists — adopt it)
#   error      → {"outcome":"ERROR","error":…} + non-zero exit
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

# The 3f step-0 closing-keyword pattern (the ec8d5fd class): any GitHub
# closing keyword followed by an issue reference, case-insensitive.
CLOSING_RE='\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b[[:space:]]*#[0-9]+'

# fd 3 = the script's real stdout. Helpers run inside command substitutions,
# where a die()'s ERROR line would be captured by the caller instead of
# reaching the orchestrator — emitting via fd 3 keeps the structured error on
# the real stdout regardless of call context.
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: pr.sh scan <worktreePath> | base-check <worktreePath> | rebase <worktreePath> | push <worktreePath> <branch> [--force] | open --verdict <file|-> [--gh-issue N] [--also-closes N,N,...] [--plan-link <target>] [--source <ref>] [--verification-surface-file <path>] (--body-only | --repo <repo-root> --branch <branch> --title <title>)"
}

# Physical-path resolve for an EXISTING dir (portable — no GNU readlink -f).
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# Resolve + validate a worktree path: must exist and be a git work-tree
# toplevel (a linked worktree is its own toplevel, so the orchestrator's
# deterministic `<repo>.wt/<slug>` path passes; a subdir does not).
resolve_worktree() {
  local arg="$1" wt top
  wt="$(abs_dir "$arg")" || die "worktree path '$arg' does not exist"
  top="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" || die "worktree path '$arg' is not inside a git work tree"
  top="$(abs_dir "$top")"
  [ "$wt" = "$top" ] || die "worktree path '$arg' is not a git toplevel (toplevel is '$top')"
  printf '%s\n' "$wt"
}

# The repo's default branch, from origin's HEAD (falling back to main/master).
default_branch() {
  local repo="$1" ref b
  if ref="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for b in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$b"; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  return 1
}

# Branch names feed a refspec; reject anything git itself would reject rather
# than letting the push error surface as a confusing rejection.
validate_branch() {
  local branch="$1"
  [ -n "$branch" ] || die "branch name is empty"
  git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 \
    || die "branch '$branch' is not a valid git branch name"
}

# Issue numbers feed bare `Closes #N` lines; only digits are acceptable.
validate_issue() {
  case "$1" in
    *[!0-9]*|"") die "issue number '$1' invalid — must be digits only" ;;
  esac
}

# --- scan: 3f step 0 — closing-keyword pre-push scan --------------------------
# Pure function of the worker's unpushed commit messages: grep every commit
# body in origin/<default>..HEAD for closing keywords. A match is the ec8d5fd
# failure mode (GitHub scans default-branch commit messages, not just the PR
# body, so a stray `Closes #N` auto-closes on merge); linkage belongs in the
# PR body alone, so a hit BLOCKS the push.
cmd_scan() {
  local wt default log matches
  wt="$(resolve_worktree "$1")"
  default="$(default_branch "$wt")" || die "cannot resolve origin's default branch in '$wt'"
  log="$(git -C "$wt" log "origin/$default..HEAD" --format=%B 2>&1)" \
    || die "git log origin/$default..HEAD failed in '$wt': $log"
  matches="$(grep -iE "$CLOSING_RE" <<<"$log" || true)"
  if [ -z "$matches" ]; then
    jq -cn '{outcome:"SCAN_CLEAN"}'
  else
    jq -cn --arg m "$matches" '{outcome:"SCAN_BLOCKED", matches:($m|split("\n"))}'
    exit 1
  fi
}

# --- base-check: 3f step 0.5 — speculative base-currency check ----------------
# Fetch the default branch, then compare merge-base(HEAD, origin/<default>)
# against the origin/<default> tip: equal → the worker's base is current
# (BASE_CURRENT, safe to push); behind → BASE_STALE (pushing would silently
# drop the merged level-k changes in overlapping regions — the orchestrator
# runs the rebase-then-reverify / discard-and-respawn flow, not this script).
cmd_base_check() {
  local wt default mb tip outcome out
  wt="$(resolve_worktree "$1")"
  default="$(default_branch "$wt")" || die "cannot resolve origin's default branch in '$wt'"
  out="$(git -C "$wt" fetch origin "$default" 2>&1)" \
    || die "git fetch origin $default failed in '$wt': $out"
  tip="$(git -C "$wt" rev-parse "origin/$default")" || die "cannot resolve origin/$default tip"
  mb="$(git -C "$wt" merge-base HEAD "origin/$default" 2>/dev/null)" \
    || die "no merge base between HEAD and origin/$default in '$wt'"
  if [ "$mb" = "$tip" ]; then outcome="BASE_CURRENT"; else outcome="BASE_STALE"; fi
  jq -cn --arg outcome "$outcome" --arg mb "$mb" --arg tip "$tip" \
    '{outcome:$outcome, merge_base:$mb, tip:$tip}'
}

# --- rebase: 3f step 0.5 — rebase onto fresh origin/<default> ------------------
# The unconditional stale-base guard (#525): a worker branches off
# origin/<default> at the start of its run, but on a fast-moving default a long
# run lets the default advance mid-build — so by push/PR-open time the worker's
# base is stale and the PR's cumulative diff REVERTS whatever merged in between
# (W49 PR#82 / W52 PR#83). Fetch the default fresh, then rebase the worktree's
# HEAD onto its tip so the PR diff carries ONLY the worker's own changes:
#   - already current (merge-base == tip) → no-op rebase, REBASED
#   - behind          → replay the worker's commits onto the new tip, REBASED
#   - CONFLICT        → `git rebase --abort` (leave the worktree clean, NEVER a
#                       half-rebased tree and NEVER a silent revert) → REBASE_CONFLICT
#                       + non-zero exit. The orchestrator escalates this as a
#                       rebase conflict for a human to resolve.
cmd_rebase() {
  local wt default base tip out sha
  wt="$(resolve_worktree "$1")"
  default="$(default_branch "$wt")" || die "cannot resolve origin's default branch in '$wt'"
  out="$(git -C "$wt" fetch origin "$default" 2>&1)" \
    || die "git fetch origin $default failed in '$wt': $out"
  tip="$(git -C "$wt" rev-parse "origin/$default")" || die "cannot resolve origin/$default tip"
  base="$(git -C "$wt" merge-base HEAD "origin/$default" 2>/dev/null)" \
    || die "no merge base between HEAD and origin/$default in '$wt'"
  if out="$(git -C "$wt" rebase "origin/$default" 2>&1)"; then
    sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || die "cannot resolve HEAD after rebase in '$wt'"
    jq -cn --arg base "$base" --arg tip "$tip" --arg sha "$sha" \
      '{outcome:"REBASED", base:$base, tip:$tip, sha:$sha}'
  else
    # Conflict (or any rebase failure): abort so the worktree is left clean and
    # the worker's commits are intact — NEVER leave a half-applied rebase, and
    # NEVER silently propose a revert. Escalate as a rebase conflict.
    git -C "$wt" rebase --abort >/dev/null 2>&1 || true
    jq -cn --arg base "$base" --arg tip "$tip" --arg error "$out" \
      '{outcome:"REBASE_CONFLICT", base:$base, tip:$tip, error:$error}'
    exit 1
  fi
}

# --- push: 3f step 1 — push-by-SHA ---------------------------------------------
# Push the worktree's HEAD to the plan branch by SHA, honoring the plan's
# `branch:` name regardless of the worktree's throwaway build/<slug> local
# branch. --force serves the rebase re-push (0.5) and CI-fix re-push (3g)
# paths. A rejection is a structured outcome — stale-branch-vs-collision
# triage is the orchestrator's call.
cmd_push() {
  local wt branch force="$1" sha out
  wt="$(resolve_worktree "$2")"
  branch="$3"
  validate_branch "$branch"
  sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || die "cannot resolve HEAD in '$wt'"
  if out="$(git -C "$wt" push ${force:+--force} origin "$sha:refs/heads/$branch" 2>&1)"; then
    jq -cn --arg sha "$sha" --arg branch "$branch" '{outcome:"PUSHED", sha:$sha, branch:$branch}'
  else
    jq -cn --arg sha "$sha" --arg branch "$branch" --arg error "$out" \
      '{outcome:"PUSH_REJECTED", sha:$sha, branch:$branch, error:$error}'
    exit 1
  fi
}

# --- open: 3f step 2 — PR-body assembly + gh pr create -------------------------

# Resolve the ## Verification surface body by precedence (the #418 inflow-cut),
# so the large block need never round-trip through the orchestrator's context:
#   1. --verification-surface-file <path>      (explicit; the orchestrator
#      passes the deterministic worktree path)      → read the file
#   2. verdict's `.verification_surface_path`       (the worker wrote a file in
#      its worktree and returned only the path)      → read the file
#   3. verdict's inline `.verification_surface`      (back-compat)
#   4. empty → the caller falls back to the acceptance recap
# A path that is given but unreadable is a contract violation → die (a structured
# ERROR the orchestrator branches on, rather than silently degrading to recap).
resolve_surface() {
  local surface_file="$1" verdict="$2" spath
  if [ -n "$surface_file" ]; then
    [ -f "$surface_file" ] || die "--verification-surface-file '$surface_file' does not exist"
    cat "$surface_file"
    return 0
  fi
  spath="$(jq -r '.verification_surface_path // ""' <<<"$verdict")"
  if [ -n "$spath" ]; then
    [ -f "$spath" ] || die "verdict .verification_surface_path '$spath' does not exist"
    cat "$spath"
    return 0
  fi
  jq -r '.verification_surface // ""' <<<"$verdict"
}

# Assemble the PR body per the 3f contract, from the verdict JSON + plan
# fields. Section order: summary; bare Closes lines (one per entry, own line,
# no backticks — combining or code-spanning them breaks GitHub's auto-close);
# acceptance recap; ## Verification (the resolved surface, see resolve_surface,
# falling back to the recap ONLY if no surface was produced); backlinks;
# Claude Code footer.
assemble_body() {
  local verdict="$1" gh_issue="$2" also_closes="$3" plan_link="$4" source_ref="$5" surface="$6"
  local summary recap body n
  summary="$(jq -er '.summary' <<<"$verdict" 2>/dev/null)" \
    || die "verdict JSON missing .summary"
  recap="$(jq -r '(.acceptance_results // [])[]
            | "- [" + (if .passed then "x" else " " end) + "] "
              + .criterion
              + ((.evidence // "") | if . == "" then "" else " — " + . end)' \
          <<<"$verdict")" || die "verdict JSON has malformed .acceptance_results"
  # surface is resolved by the caller (cmd_open → resolve_surface) so a missing
  # surface file dies at the top level, not inside this nested command sub.

  body="$summary"$'\n'
  if [ -n "$gh_issue" ] || [ -n "$also_closes" ]; then
    body="$body"$'\n'
    [ -n "$gh_issue" ] && body="${body}Closes #${gh_issue}"$'\n'
    for n in $also_closes; do
      body="${body}Closes #${n}"$'\n'
    done
  fi
  if [ -n "$recap" ]; then
    body="$body"$'\n''## Acceptance'$'\n'"$recap"$'\n'
  fi
  body="$body"$'\n''## Verification'$'\n'
  if [ -n "$surface" ]; then
    body="$body$surface"$'\n'
  else
    # Fallback only when the worker produced no verification_surface — the
    # bare recap alone does not satisfy the PR-verification-surface rule, so
    # the orchestrator should treat this as degraded, not normal.
    body="$body$recap"$'\n'
  fi
  if [ -n "$plan_link" ] || [ -n "$source_ref" ]; then
    body="$body"$'\n'
    [ -n "$plan_link" ] && body="${body}Tracked in: [[${plan_link}]]"$'\n'
    [ -n "$source_ref" ] && body="${body}Derived from: ${source_ref}"$'\n'
  fi
  body="$body"$'\n''🤖 Generated with [Claude Code](https://claude.com/claude-code)'
  printf '%s\n' "$body"
}

cmd_open() {
  local verdict_src="" repo="" branch="" title="" gh_issue="" also_closes="" \
        plan_link="" source_ref="" surface_file="" surface="" body_only="" verdict body out url pr_number n raw
  while [ $# -gt 0 ]; do
    case "$1" in
      --verdict)     [ $# -ge 2 ] || usage; verdict_src="$2"; shift ;;
      --repo)        [ $# -ge 2 ] || usage; repo="$2"; shift ;;
      --branch)      [ $# -ge 2 ] || usage; branch="$2"; shift ;;
      --title)       [ $# -ge 2 ] || usage; title="$2"; shift ;;
      --gh-issue)    [ $# -ge 2 ] || usage; gh_issue="$2"; shift ;;
      --also-closes) [ $# -ge 2 ] || usage; also_closes="$2"; shift ;;
      --plan-link)   [ $# -ge 2 ] || usage; plan_link="$2"; shift ;;
      --source)      [ $# -ge 2 ] || usage; source_ref="$2"; shift ;;
      --verification-surface-file) [ $# -ge 2 ] || usage; surface_file="$2"; shift ;;
      --body-only)   body_only=1 ;;
      *) usage ;;
    esac
    shift
  done

  [ -n "$verdict_src" ] || die "open requires --verdict <file|->"
  if [ "$verdict_src" = "-" ]; then
    verdict="$(cat)"
  else
    [ -f "$verdict_src" ] || die "verdict file '$verdict_src' does not exist"
    verdict="$(cat "$verdict_src")"
  fi
  jq -e . >/dev/null 2>&1 <<<"$verdict" || die "verdict is not valid JSON"

  [ -z "$gh_issue" ] || validate_issue "$gh_issue"
  # --also-closes accepts comma- or space-separated numbers; normalize to
  # space-separated so each emits its own bare `Closes #N` line.
  also_closes="$(printf '%s' "$also_closes" | tr ',' ' ')"
  for n in $also_closes; do validate_issue "$n"; done

  # Resolve the verification surface at the TOP level (not inside assemble_body's
  # nested command sub) so a missing surface file dies cleanly with a structured
  # ERROR. `|| exit 1` propagates resolve_surface's die (it already wrote the
  # ERROR to fd3) without emitting a second one.
  surface="$(resolve_surface "$surface_file" "$verdict")" || exit 1
  body="$(assemble_body "$verdict" "$gh_issue" "$also_closes" "$plan_link" "$source_ref" "$surface")"

  if [ -n "$body_only" ]; then
    printf '%s\n' "$body"
    return 0
  fi

  [ -n "$repo" ]   || die "open requires --repo <repo-root> (unless --body-only)"
  [ -n "$branch" ] || die "open requires --branch (unless --body-only)"
  [ -n "$title" ]  || die "open requires --title (unless --body-only)"
  repo="$(abs_dir "$repo")" || die "repo-root does not exist"
  validate_branch "$branch"

  if ! out="$(cd "$repo" && gh pr create --head "$branch" --title "$title" --body "$body" 2>&1)"; then
    # gh pr create fails with "a pull request for branch ... already exists: <url>"
    # when the branch already has an open PR (e.g. a create retry after the first
    # create actually succeeded). Adopt the existing PR — parse its number and URL
    # from the error message and return a structured EXISTS outcome (success) so
    # the caller routes it to the normal CI-poll/park-with-pr path.
    if printf '%s\n' "$out" | grep -qiE 'a pull request for branch .* already exists'; then
      url="$(grep -oE 'https?://[^[:space:]]+/pull/[0-9]+' <<<"$out" | tail -1 || true)"
      raw="$(grep -oE '/pull/[0-9]+' <<<"$out" | tail -1 || true)"
      pr_number="${raw#/pull/}"
      [ -n "$pr_number" ] || die "could not parse PR number from existing-PR error: $out"
      jq -cn --arg n "$pr_number" --arg url "$url" \
        '{outcome:"EXISTS", pr_number:($n|tonumber), url:$url}'
      return 0
    fi
    die "gh pr create failed: $out"
  fi
  # gh prints the new PR URL; take the last `/pull/<n>` reference in the output.
  raw="$(grep -oE '/pull/[0-9]+' <<<"$out" | tail -1 || true)"
  pr_number="${raw#/pull/}"
  [ -n "$pr_number" ] || die "could not parse PR number from gh output: $out"
  url="$(grep -oE 'https?://[^[:space:]]+/pull/[0-9]+' <<<"$out" | tail -1 || true)"
  jq -cn --arg n "$pr_number" --arg url "$url" \
    '{outcome:"PR_OPENED", pr_number:($n|tonumber), url:$url}'
}

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  scan)
    [ $# -eq 1 ] || usage
    cmd_scan "$1"
    ;;
  base-check)
    [ $# -eq 1 ] || usage
    cmd_base_check "$1"
    ;;
  rebase)
    [ $# -eq 1 ] || usage
    cmd_rebase "$1"
    ;;
  push)
    [ $# -ge 2 ] || usage
    wt_arg="$1"; branch_arg="$2"; shift 2
    force=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) force=1 ;;
        *) usage ;;
      esac
      shift
    done
    cmd_push "$force" "$wt_arg" "$branch_arg"
    ;;
  open)
    cmd_open "$@"
    ;;
  *) usage ;;
esac
