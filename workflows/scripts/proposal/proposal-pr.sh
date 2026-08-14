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
#                        TRAILING-NEWLINE NORMALIZATION (temperloop#992):
#                        whatever trailing newlines a `content`/
#                        `content_file` value carries — none, one, or
#                        several — the file that LANDS ends in EXACTLY ONE
#                        "\n". Callers therefore need not (and must not)
#                        hand-append one; an adopter's first proposal diff
#                        never shows "\ No newline at end of file". The one
#                        carve-out is EMPTY content, which lands as a
#                        0-byte file rather than a lone newline (git
#                        reports no missing-newline marker for an empty
#                        blob, so there is nothing to normalize).
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
# GIT IDENTITY (temperloop#1443): this script COMMITS, so whatever runs it
# needs an author/committer identity. A fresh CI runner — and a brand-new
# laptop — has none, and git then dies mid-run with "Author identity unknown
# / fatal: empty ident name" AFTER the proposal branch was cut and the
# manifest written. cmd_open therefore PREFLIGHTS the identity before it
# touches the checkout (git_identity_preflight below) and refuses with a
# remedy naming the exact two `git config --global` commands to run — the
# ERROR outcome above, plus the same remedy in full on stderr so it is
# readable without decoding JSON. It never invents one (no `git -c
# user.name=…`): authoring an adopter's first commit as an identity they
# never chose is worse than a clear refusal.
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

# Remote names are the FIRST POSITIONAL of `git fetch`/`git push` — the
# position git parses as an OPTION whenever the word begins with `-`. A value
# like `--upload-pack=touch /tmp/PWNED; git-upload-pack` therefore EXECUTES at
# the fetch. `--remote` is documented CLI surface that adopter wrappers and
# init.sh pass through, so it is not always a human's own keystroke. Same
# validate-before-act ordering as validate_branch above: refuse at parse time,
# before the first git invocation that consumes it — which here is
# default_branch()'s own symbolic-ref/show-ref probes, not just the fetch.
validate_remote() {
  local remote="$1" label="$2"
  [ -n "$remote" ] || die "$label is empty"
  case "$remote" in
    -*) die "$label '$remote' must not begin with '-' (git would read it as an option, not a remote)" ;;
  esac
  git check-ref-format "refs/remotes/$remote/HEAD" >/dev/null 2>&1 \
    || die "$label '$remote' is not a valid git remote name"
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

# git_identity_preflight <repo> — refuse, with a remedy, when no git identity
# resolves. Same validate-before-act ordering as validate_remote/
# validate_branch: this runs BEFORE the `checkout -B` that cuts the proposal
# branch, so a repo with no identity is left untouched rather than sitting on
# a fresh branch with a written-but-uncommittable tree.
#
# The probe is the pair `git config user.name`/`user.email` FIRST — the two
# settings the remedy tells you to set, so a run that passes is a run whose
# identity the operator actually chose. When either is unset it falls through
# to `git var GIT_{AUTHOR,COMMITTER}_IDENT`, which is precisely the
# resolution `git commit` itself performs: config PLUS the
# GIT_AUTHOR_NAME/GIT_COMMITTER_EMAIL environment overrides a caller may
# legitimately supply instead (this script's own test fixtures do). A
# config-only read would refuse runs git would have committed fine.
#
# NEVER invents an identity (no `git -c user.name=…`) — see the header.
git_identity_preflight() {
  local repo="$1" name email
  name="$(git -C "$repo" config user.name 2>/dev/null || true)"
  email="$(git -C "$repo" config user.email 2>/dev/null || true)"
  [ -n "$name" ] && [ -n "$email" ] && return 0
  if git -C "$repo" var GIT_AUTHOR_IDENT >/dev/null 2>&1 \
     && git -C "$repo" var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
    return 0
  fi
  # The remedy in full, on stderr — a caller that only pretty-prints the JSON
  # (init.sh does) still shows this verbatim in its log.
  {
    echo "proposal-pr.sh: no git identity is configured, so the proposal commit cannot be authored."
    echo "Run these two commands, then re-run:"
    echo "    git config --global user.name 'Your Name'"
    echo "    git config --global user.email 'you@example.com'"
    echo "(This script will not invent an identity for you — a commit authored as someone you never chose is worse than this refusal.)"
  } >&2
  die "no git identity configured in '$repo' — run: git config --global user.name 'Your Name' && git config --global user.email 'you@example.com', then re-run (proposal-pr.sh will not invent one)"
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

  # Parse-time, before ANY git subprocess in this run — see validate_remote's
  # own comment. `--remote` always holds its final value here (it defaults to
  # "origin"), unlike `--base`, which may still need default_branch() to
  # resolve it and so is validated a few lines further down.
  validate_remote "$remote" "--remote"

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

  # Before the first mutation (and before the network fetch below) — see
  # git_identity_preflight's own comment.
  git_identity_preflight "$repo"

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
      # NEWLINE-TERMINATE (temperloop#992). Both readers above are `$(…)`
      # captures, and command substitution strips EVERY trailing newline —
      # so `$content` is already normalized to "no trailing newline at all",
      # whether the manifest said "a", "a\n", or "a\n\n\n". A bare
      # `printf '%s'` therefore wrote a file with NO final newline, every
      # time, for every entry: an adopter's very first temperloop PR showed
      # "\ No newline at end of file" on every file in the diff. Adding the
      # "\n" here — at the single write site, not at each call site — is
      # what makes "exactly one trailing newline" a property of the
      # generator rather than something every caller must remember.
      #
      # EMPTY CONTENT is the deliberate carve-out: `printf '%s\n' ""` would
      # turn a requested zero-byte file into a 1-byte one, and git reports
      # no missing-newline marker for an empty blob — there is nothing to
      # fix, so leave it 0 bytes.
      #
      # NO_CHANGES is unaffected in mechanism and strictly better in
      # outcome: the idempotence check below is `git diff --cached --quiet`
      # against the base tree, so a base already carrying the
      # newline-terminated file now compares EQUAL (before this fix the
      # stripped write manufactured a one-byte diff on every re-run).
      if [ -n "$content" ]; then
        printf '%s\n' "$content" > "$abs" || die "cannot write '$path'"
      else
        : > "$abs" || die "cannot write '$path'"
      fi
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
    if printf '%s\n' "$out" | grep -iE 'a pull request for branch .* already exists' >/dev/null; then
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
