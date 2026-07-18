#!/usr/bin/env bash
#
# proposal-pr.sh — tree-diff -> reviewable PR, minimally (foundation #765
# Epic D "newcomer experience", item proposal-pr-generator / #853).
#
# Interface is pinned to the minimal tuple (branch, files, PR body): given a
# target git checkout, a branch name, a manifest of files to write/delete,
# and a PR title + body, this script creates the branch, commits the file
# changes, pushes it, and opens a PR — NEVER a direct push to the target
# repo's default branch. There is no code path in this script that writes
# to the default branch or to any ref other than `refs/heads/<branch>`.
#
# SCOPE — TREE PROPOSALS ONLY (load-bearing, read before extending): this
# script proposes changes to a repo's file TREE. Label creation, required-
# check/branch-protection settings, and Projects-v2 board provisioning are
# GitHub API STATE, not tree state — they cannot ride a PR and are
# explicitly out of scope here. That is the later `foundation init` item's
# consented-apply step, not this generator's job. There is no hidden
# API-write path in this script beyond the PR-open call itself (`gh pr
# create`, plus the plain `git push` that PR rides on).
#
# NAMESPACING is a CALL-SITE responsibility, not a generator mechanic: post
# design-review, the "generic policy enforced by the generator" framing was
# retired — the caller who builds the files manifest owns what paths/content
# it contains (e.g. everything under `.temperloop/`, or an `fnd:`-prefixed
# file). This script does not inspect or gate manifest paths against a
# namespace convention; it only guards against path TRAVERSAL (an entry
# that would write outside the target repo — see validate_manifest_path).
# Every fixture in this script's own test suite happens to write under
# `.temperloop/` to demonstrate the intended calling convention, but that is
# a test-authoring choice, not an enforced contract.
#
# Usage:
#   proposal-pr.sh open --repo-dir DIR --branch NAME --title TITLE
#                        (--body TEXT | --body-file FILE|-)
#                        --files-manifest FILE|-
#                        [--base BRANCH] [--remote NAME]
#                        [--commit-message MSG] [--draft] [--force] [--dry-run]
#
#   --repo-dir DIR       Target git checkout to propose into. Must be a git
#                        working-tree toplevel.
#   --branch NAME        Proposal branch name. MUST differ from the
#                        resolved base branch — refused otherwise (this is
#                        the never-direct-push guard).
#   --title TITLE        PR title (also the fallback commit message).
#   --body TEXT          PR body (caller-owned content — narrative,
#                        rationale, its own verification notes). Mutually
#                        exclusive with --body-file.
#   --body-file FILE|-   Read the PR body from a file, or stdin ("-").
#   --files-manifest FILE|-
#                        JSON array of file operations, read from a file or
#                        stdin ("-"). Each entry:
#                          {"path": "relative/path", "content": "text"}
#                          {"path": "relative/path", "content_file": "/abs/or/rel/path"}
#                          {"path": "relative/path", "delete": true}
#                        Optional per-entry "mode": "644" (default) or
#                        "755" (executable). `path` MUST be relative and
#                        MUST NOT escape the repo (no leading "/", no ".."
#                        segment, not under ".git/") — validated before any
#                        write.
#   --base BRANCH        Base branch to propose against. Default: the
#                        target repo's own default branch (origin/HEAD,
#                        falling back to main/master).
#   --remote NAME        Git remote to fetch/push against. Default: origin.
#   --commit-message MSG Commit message. Default: --title's value.
#   --draft              Open the PR as a draft.
#   --force              Force-push the proposal branch (re-proposing after
#                         local content changed non-fast-forward-ly).
#   --dry-run             Create the local branch + commit but skip push and
#                        PR-open — a preview outcome (DRY_RUN) for a caller
#                        that wants to show a diff before proposing it for
#                        real. Still a real local git checkout + commit in
#                        --repo-dir (nothing remote, nothing on GitHub).
#
# Exit codes / output — CLOSED outcome set, one structured JSON line on
# stdout per outcome (exception: none — even errors are structured, see
# `error` below):
#   {"outcome":"NO_CHANGES","branch":...}                       — manifest
#     produced no diff against the base tip; nothing committed, nothing
#     pushed (idempotent re-run of an already-applied proposal).
#   {"outcome":"DRY_RUN","branch":...,"base":...,"sha":...,"files":[...]}
#   {"outcome":"PR_OPENED","pr_number":...,"url":...,"branch":...}
#   {"outcome":"EXISTS","pr_number":...,"url":...,"branch":...}  — gh
#     reports a PR already exists for this branch; adopted, not an error.
#   {"outcome":"ERROR","error":"..."} + non-zero exit
#
# Dependencies: bash (3.2+), git, jq, gh (only for the non-dry-run push+open
# path — never invoked in --dry-run mode).
#
# shellcheck shell=bash

set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

# fd 3 = the script's real stdout, exactly like build/pr.sh — helpers below
# run inside command substitutions, where a die()'s output would otherwise
# be captured by the caller instead of reaching stdout.
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: proposal-pr.sh open --repo-dir DIR --branch NAME --title TITLE (--body TEXT|--body-file FILE|-) --files-manifest FILE|- [--base BRANCH] [--remote NAME] [--commit-message MSG] [--draft] [--force] [--dry-run]"
}

# Physical-path resolve for an EXISTING dir (portable — no GNU readlink -f).
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# Resolve + validate --repo-dir: must exist and be a git work-tree toplevel.
resolve_repo_dir() {
  local arg="$1" dir top
  dir="$(abs_dir "$arg")" || die "--repo-dir '$arg' does not exist"
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || die "--repo-dir '$arg' is not inside a git work tree"
  top="$(abs_dir "$top")"
  [ "$dir" = "$top" ] || die "--repo-dir '$arg' is not a git toplevel (toplevel is '$top')"
  printf '%s\n' "$dir"
}

# The repo's default branch, from <remote>'s HEAD (falling back to main/master).
default_branch() {
  local repo="$1" remote="$2" ref b
  if ref="$(git -C "$repo" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null)"; then
    printf '%s\n' "${ref#"$remote"/}"
    return 0
  fi
  for b in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/$remote/$b"; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  return 1
}

# Branch names feed a refspec; reject anything git itself would reject.
validate_branch() {
  local branch="$1" label="$2"
  [ -n "$branch" ] || die "$label is empty"
  git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 \
    || die "$label '$branch' is not a valid git branch name"
}

# validate_manifest_path <path> — refuse anything that could write outside
# the target repo: empty, absolute (leading "/"), a ".." path segment, or
# under ".git/". This is a safety guard, NOT a namespace-convention check
# (see the header comment) — a caller may propose any relative path that
# passes this guard.
validate_manifest_path() {
  local p="$1"
  [ -n "$p" ] || die "manifest entry has an empty path"
  case "$p" in
    /*) die "manifest path '$p' must be relative (no leading '/')" ;;
  esac
  case "/$p/" in
    */../*) die "manifest path '$p' must not contain a '..' segment" ;;
  esac
  case "$p" in
    .git | .git/*) die "manifest path '$p' must not target .git/" ;;
  esac
}

# ---------------------------------------------------------------------------
# cmd_open — the only subcommand.
# ---------------------------------------------------------------------------
cmd_open() {
  local repo_dir="" branch="" title="" body="" body_file="" \
        manifest_src="" base="" remote="origin" commit_message="" \
        draft="" force="" dry_run=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-dir)        [ $# -ge 2 ] || usage; repo_dir="$2"; shift ;;
      --branch)          [ $# -ge 2 ] || usage; branch="$2"; shift ;;
      --title)           [ $# -ge 2 ] || usage; title="$2"; shift ;;
      --body)            [ $# -ge 2 ] || usage; body="$2"; shift ;;
      --body-file)       [ $# -ge 2 ] || usage; body_file="$2"; shift ;;
      --files-manifest)  [ $# -ge 2 ] || usage; manifest_src="$2"; shift ;;
      --base)            [ $# -ge 2 ] || usage; base="$2"; shift ;;
      --remote)          [ $# -ge 2 ] || usage; remote="$2"; shift ;;
      --commit-message)  [ $# -ge 2 ] || usage; commit_message="$2"; shift ;;
      --draft)           draft=1 ;;
      --force)           force=1 ;;
      --dry-run)         dry_run=1 ;;
      *) usage ;;
    esac
    shift
  done

  [ -n "$repo_dir" ] || die "open requires --repo-dir"
  [ -n "$branch" ]   || die "open requires --branch"
  [ -n "$title" ]    || die "open requires --title"
  [ -n "$manifest_src" ] || die "open requires --files-manifest <file|->"
  if [ -n "$body" ] && [ -n "$body_file" ]; then
    die "--body and --body-file are mutually exclusive"
  fi
  [ -n "$body" ] || [ -n "$body_file" ] || die "open requires --body or --body-file"

  if [ -n "$body_file" ]; then
    if [ "$body_file" = "-" ]; then
      body="$(cat)"
    else
      [ -f "$body_file" ] || die "--body-file '$body_file' does not exist"
      body="$(cat "$body_file")"
    fi
  fi

  local manifest
  if [ "$manifest_src" = "-" ]; then
    manifest="$(cat)"
  else
    [ -f "$manifest_src" ] || die "--files-manifest '$manifest_src' does not exist"
    manifest="$(cat "$manifest_src")"
  fi
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$manifest" \
    || die "--files-manifest must be a JSON array"
  [ "$(jq 'length' <<<"$manifest")" -gt 0 ] || die "--files-manifest is empty — nothing to propose"

  local repo
  repo="$(resolve_repo_dir "$repo_dir")" || exit 1
  validate_branch "$branch" "--branch"

  if [ -z "$base" ]; then
    base="$(default_branch "$repo" "$remote")" \
      || die "cannot resolve default branch on remote '$remote' in '$repo' — pass --base explicitly"
  fi
  validate_branch "$base" "--base"
  [ "$branch" != "$base" ] \
    || die "--branch '$branch' must differ from the base branch '$base' (never direct-propose onto the base)"

  # Best-effort fetch — offline/local-only fixtures (no real network) still
  # work as long as a local ref for $base already exists.
  git -C "$repo" fetch "$remote" "$base" >/dev/null 2>&1 || true

  local base_ref
  if git -C "$repo" show-ref --verify --quiet "refs/remotes/$remote/$base"; then
    base_ref="refs/remotes/$remote/$base"
  elif git -C "$repo" show-ref --verify --quiet "refs/heads/$base"; then
    base_ref="refs/heads/$base"
  else
    die "cannot resolve base branch '$base' (no $remote/$base or local $base) in '$repo'"
  fi

  # Always (re)create the proposal branch fresh off the current base tip —
  # deterministic starting point, no stale-branch drift across re-runs.
  local out
  out="$(git -C "$repo" checkout -q -B "$branch" "$base_ref" 2>&1)" \
    || die "cannot checkout branch '$branch' from '$base_ref' in '$repo': $out"

  # --- apply the files manifest --------------------------------------------
  local n entry path content content_file mode is_delete abs touched=()
  n="$(jq 'length' <<<"$manifest")"
  local i=0
  while [ "$i" -lt "$n" ]; do
    entry="$(jq -c ".[$i]" <<<"$manifest")"
    path="$(jq -r '.path // ""' <<<"$entry")"
    validate_manifest_path "$path"
    is_delete="$(jq -r '.delete // false' <<<"$entry")"
    content_file="$(jq -r '.content_file // ""' <<<"$entry")"
    mode="$(jq -r '.mode // "644"' <<<"$entry")"
    case "$mode" in 644 | 755) ;; *) die "manifest entry '$path' has invalid mode '$mode' (must be 644 or 755)" ;; esac
    abs="$repo/$path"

    if [ "$is_delete" = "true" ]; then
      jq -e 'has("content") or has("content_file")' <<<"$entry" >/dev/null 2>&1 \
        && die "manifest entry '$path' sets delete=true but also carries content — pick one"
      rm -f -- "$abs"
    else
      jq -e 'has("content")' <<<"$entry" >/dev/null 2>&1 && content="$(jq -r '.content' <<<"$entry")" || content=""
      if [ -n "$content_file" ]; then
        jq -e 'has("content")' <<<"$entry" >/dev/null 2>&1 \
          && die "manifest entry '$path' sets both content and content_file — pick one"
        [ -f "$content_file" ] || die "manifest entry '$path' content_file '$content_file' does not exist"
        content="$(cat "$content_file")"
      elif ! jq -e 'has("content")' <<<"$entry" >/dev/null 2>&1; then
        die "manifest entry '$path' has neither content, content_file, nor delete=true"
      fi
      mkdir -p "$(dirname "$abs")" || die "cannot create directory for '$path'"
      printf '%s' "$content" > "$abs" || die "cannot write '$path'"
      if [ "$mode" = "755" ]; then chmod 755 "$abs"; else chmod 644 "$abs"; fi
    fi
    touched+=("$path")
    i=$((i + 1))
  done

  git -C "$repo" add -A -- "${touched[@]}" \
    || die "git add failed for manifest paths in '$repo'"

  if git -C "$repo" diff --cached --quiet; then
    jq -cn --arg branch "$branch" '{outcome:"NO_CHANGES", branch:$branch}'
    return 0
  fi

  [ -n "$commit_message" ] || commit_message="$title"
  out="$(git -C "$repo" commit -q -m "$commit_message" 2>&1)" \
    || die "git commit failed in '$repo': $out"

  local sha
  sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || die "cannot resolve HEAD after commit in '$repo'"

  if [ -n "$dry_run" ]; then
    jq -cn --arg branch "$branch" --arg base "$base" --arg sha "$sha" \
      --argjson files "$(printf '%s\n' "${touched[@]}" | jq -R . | jq -sc .)" \
      '{outcome:"DRY_RUN", branch:$branch, base:$base, sha:$sha, files:$files}'
    return 0
  fi

  # --- push -------------------------------------------------------------
  if ! out="$(git -C "$repo" push ${force:+--force} "$remote" "$sha:refs/heads/$branch" 2>&1)"; then
    die "git push failed for branch '$branch' in '$repo': $out"
  fi

  # --- assemble the PR body: caller content + generator-owned mechanics --
  local files_summary full_body
  files_summary="$(printf -- '- %s\n' "${touched[@]}")"
  full_body="$body"$'\n\n''## Files changed'$'\n'"$files_summary"$'\n'
  full_body="$full_body"'---'$'\n''🤖 Generated by the temperloop kernel'\''s proposal-PR generator (tree-only; no API-state changes).'

  # --- gh pr create -------------------------------------------------------
  local gh_args=(pr create --base "$base" --head "$branch" --title "$title" --body "$full_body")
  [ -n "$draft" ] && gh_args+=(--draft)
  if ! out="$(cd "$repo" && gh "${gh_args[@]}" 2>&1)"; then
    if printf '%s\n' "$out" | grep -qiE 'a pull request for branch .* already exists'; then
      local url raw pr_number
      url="$(grep -oE 'https?://[^[:space:]]+/pull/[0-9]+' <<<"$out" | tail -1 || true)"
      raw="$(grep -oE '/pull/[0-9]+' <<<"$out" | tail -1 || true)"
      pr_number="${raw#/pull/}"
      [ -n "$pr_number" ] || die "could not parse PR number from existing-PR error: $out"
      jq -cn --arg n "$pr_number" --arg url "$url" --arg branch "$branch" \
        '{outcome:"EXISTS", pr_number:($n|tonumber), url:$url, branch:$branch}'
      return 0
    fi
    die "gh pr create failed: $out"
  fi
  local raw pr_number url
  raw="$(grep -oE '/pull/[0-9]+' <<<"$out" | tail -1 || true)"
  pr_number="${raw#/pull/}"
  [ -n "$pr_number" ] || die "could not parse PR number from gh output: $out"
  url="$(grep -oE 'https?://[^[:space:]]+/pull/[0-9]+' <<<"$out" | tail -1 || true)"
  jq -cn --arg n "$pr_number" --arg url "$url" --arg branch "$branch" \
    '{outcome:"PR_OPENED", pr_number:($n|tonumber), url:$url, branch:$branch}'
}

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  open) cmd_open "$@" ;;
  *) usage ;;
esac
