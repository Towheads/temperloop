#!/usr/bin/env bash
#
# source.sh — the testbed SOURCE-PROVIDER seam (temperloop#1228, epic #1117
# Produces 2): the interface `temperloop testbed` resolves a source through,
# plus its first implementation, `mirror-from-repo`.
#
# WHY FOUR FUNCTIONS, NOT ONE TUPLE (temperloop#1228 notes): the epic's
# Contract described this seam as a single five-member tuple (`{git content,
# issue list, default name, provenance-capable, promotable}`), which
# conflated RESOLVE-TIME capability (what kind of source is this, and can
# pre-flight check it) with EXECUTE-TIME work products (the git content, the
# issues) and left pre-flight vestigial for the one check it exists for: a
# command must be able to describe + pre-flight a source with ZERO writes,
# before it ever creates anything. Splitting into four members fixes that:
#
#   describe()             -> {kind, base_name, provenance_capable,
#                              promotable} — resolvable with ZERO network
#                              writes and ZERO content fetching, so
#                              pre-flight can run before anything is
#                              produced.
#   preflight_checks()     -> the provider's own all-reads checks, as a
#                              list of zero-arg shell function NAMES the
#                              driver invokes in order. This is the ONE seam
#                              that eliminates the per-provider `case` this
#                              interface exists to avoid: the command's
#                              driver runs whatever this yields and NEVER
#                              branches on provider kind to decide which
#                              checks apply.
#   produce_git(dest)       -> materializes the source's git content by
#                              pushing it to `dest` (a git push target —
#                              URL or local path; the driving command
#                              resolves the newly-created destination repo
#                              into a pushable target before calling this).
#   produce_issues(dest)    -> creates the source's carried-over issues on
#                              `dest` (an `OWNER/NAME` repo slug, for
#                              `gh issue create --repo`).
#
# `describe()` yields `base_name`, NOT a final name — collision-safe
# uniquification against an existing repo is a shared DOWNSTREAM concern
# (the command driver's), not each provider's own job.
#
# PROVENANCE STAMPING (Produces 5): `mirror-from-repo`'s `produce_issues`
# stamps a machine-readable `copied from <owner>/<repo>#<N>` line into every
# issue IT creates — inside its own `produce_issues`, not in shared
# downstream code. Promotion (a later item) resolves correspondence by exact
# lookup on that line; a provider that has no upstream issue to cite
# (`materialize-from-seed`, a later item) simply never stamps one, and
# reports `provenance_capable: false` from `describe()` so callers never
# expect it to.
#
# ── Provider dispatch (mirrors workflows/scripts/lib/knowledge_store.sh's
# backend-dispatch shape: `ks__dispatch` / `_ks_backend_<name>_<op>`) ───────
# A provider is a set of four `_testbed_provider_<name>_<op>` functions,
# where <name> is the provider's kebab-case `kind` with '-' -> '_'
# (`mirror-from-repo` -> `mirror_from_repo`). Registering a new provider
# (e.g. the later `materialize-from-seed`) means defining its four
# functions and sourcing that file before use — no change to the dispatcher
# below, and no `case` on kind anywhere in this file either.
#
# This file is SOURCED — it sets no shell options (the caller owns
# `set -euo pipefail`; see knowledge_store.sh's own header for the same
# convention). Requires: bash, git, jq always; gh only for the network-
# touching ops (`preflight_checks`'s gh-auth check, and mirror-from-repo's
# `produce_issues`) — never for `describe()`.

# <kind> <op> -> the provider function name dispatch resolves to.
testbed_source__fn() {
  local kind="$1" op="$2"
  printf '_testbed_provider_%s_%s\n' "${kind//-/_}" "$op"
}

# <fn> <kind> <op> -> exit 0 if <fn> is a defined function, else exit 2 with
# a legible message naming the missing provider/op (mirrors ks__dispatch's
# unknown-backend guard).
testbed_source__require() {
  local fn="$1" kind="$2" op="$3"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    printf 'testbed-source: provider "%s" does not implement "%s" (no %s defined)\n' \
      "$kind" "$op" "$fn" >&2
    return 2
  fi
}

# ── Public interface — the four seam members, kind-dispatched ──────────────
# testbed_source_describe <kind> [args...]              -> JSON on stdout
# testbed_source_preflight_checks <kind> [args...]      -> fn names on stdout
# testbed_source_produce_git <kind> <dest> [args...]    <- pushes git content
# testbed_source_produce_issues <kind> <dest> [args...] <- creates issues
# Every call dispatches on <kind> alone; no caller of this seam may branch
# on provider kind itself — that is exactly the per-provider `case` this
# interface exists to eliminate downstream.
testbed_source_describe() {
  local kind="$1"; shift
  local fn; fn="$(testbed_source__fn "$kind" describe)"
  testbed_source__require "$fn" "$kind" describe || return $?
  "$fn" "$@"
}

testbed_source_preflight_checks() {
  local kind="$1"; shift
  local fn; fn="$(testbed_source__fn "$kind" preflight_checks)"
  testbed_source__require "$fn" "$kind" preflight_checks || return $?
  "$fn" "$@"
}

testbed_source_produce_git() {
  local kind="$1"; shift
  local fn; fn="$(testbed_source__fn "$kind" produce_git)"
  testbed_source__require "$fn" "$kind" produce_git || return $?
  "$fn" "$@"
}

testbed_source_produce_issues() {
  local kind="$1"; shift
  local fn; fn="$(testbed_source__fn "$kind" produce_issues)"
  testbed_source__require "$fn" "$kind" produce_issues || return $?
  "$fn" "$@"
}

# ── shared helper (used by mirror-from-repo; kept file-private with a
# leading underscore since it is not part of the seam) ─────────────────────
# <remote-url> -> best-effort github.com "owner/repo" extraction. Same shape
# as conventions-probe.sh's slug_from_remote / baseline-snapshot.sh's
# sibling — deliberately re-derived here rather than sourced from either
# (both are standalone `set -euo pipefail` scripts, not sourceable libs).
# Prints empty on no match; never fails.
_testbed_slug_from_remote() {
  local url="$1" slug=""
  case "$url" in
    git@github.com:*) slug="${url#git@github.com:}" ;;
    ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
    https://github.com/*) slug="${url#https://github.com/}" ;;
    http://github.com/*) slug="${url#http://github.com/}" ;;
    *) slug="" ;;
  esac
  slug="${slug%.git}"
  slug="${slug%/}"
  printf '%s' "$slug"
}

# ═══════════════════════════════════════════════════════════════════════════
# Provider: mirror-from-repo — the reader's own repository. Provenance-
# capable, promotable. The source is a LOCAL git checkout (default: `.`,
# the caller's cwd) — every function below takes that checkout's path as an
# optional trailing/second argument, defaulting to `.`.
# ═══════════════════════════════════════════════════════════════════════════

# [source-dir] -> JSON {kind, base_name, provenance_capable, promotable} on
# stdout. ZERO network calls: `git remote get-url` is a local config read,
# never a network round-trip, so this is safe to call before pre-flight has
# run or anything has been created. base_name falls back to the checkout's
# directory basename when no `origin` remote is configured (or it isn't a
# recognized github.com form) — still zero-network either way.
_testbed_provider_mirror_from_repo_describe() {
  local source_dir="${1:-.}" url slug base_name
  url="$(git -C "$source_dir" remote get-url origin 2>/dev/null || true)"
  slug="$(_testbed_slug_from_remote "$url")"
  if [ -n "$slug" ]; then
    base_name="${slug##*/}"
  else
    base_name="$(basename "$(git -C "$source_dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$source_dir")")"
  fi
  jq -cn --arg kind "mirror-from-repo" --arg base_name "$base_name" \
    '{kind: $kind, base_name: $base_name, provenance_capable: true, promotable: true}'
}

# [source-dir] -> newline-separated preflight check function NAMES (zero
# args each) on stdout. Stashes source-dir in a provider-scoped global so
# the printed check functions stay parameterless — the driver invokes
# whatever this yields with no further context, per the seam contract.
_TESTBED_MIRROR_SOURCE_DIR="."
_testbed_provider_mirror_from_repo_preflight_checks() {
  _TESTBED_MIRROR_SOURCE_DIR="${1:-.}"
  printf '%s\n' \
    _testbed_provider_mirror_from_repo_check_git_repo \
    _testbed_provider_mirror_from_repo_check_gh_auth
}

# All-reads check: the source dir is a real git working tree (mirroring
# needs real history to push). `skipped —` on failure, naming the fix,
# consistent with this repo's established degradation wording (e.g.
# bin/subcommands/try.sh, baseline-snapshot.sh).
_testbed_provider_mirror_from_repo_check_git_repo() {
  local dir="${_TESTBED_MIRROR_SOURCE_DIR:-.}"
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "skipped — $dir is not a git working tree (mirror-from-repo mirrors a real git checkout)" >&2
    return 1
  fi
}

# All-reads check: gh is present and authenticated (produce_issues needs it
# to read the source's issues and create them on the destination).
_testbed_provider_mirror_from_repo_check_gh_auth() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "skipped — gh CLI not found on PATH" >&2
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "skipped — gh is not authenticated (run: gh auth login)" >&2
    return 1
  fi
}

# <dest> [source-dir] -> mirror-pushes every ref (branches + tags) from
# source-dir's local git history to <dest>, a git push target (URL or local
# path — the driving command resolves the newly-created destination repo
# into one before calling this; this function is agnostic to what kind of
# target it is, which is what makes it testable against a plain local bare
# repo with zero network).
_testbed_provider_mirror_from_repo_produce_git() {
  local dest="${1:?testbed-source(mirror-from-repo): produce_git requires a destination git push target}"
  local source_dir="${2:-.}"
  local out
  if ! out="$(git -C "$source_dir" push --mirror "$dest" 2>&1)"; then
    printf 'testbed-source(mirror-from-repo): git push --mirror to %s failed: %s\n' "$dest" "$out" >&2
    return 1
  fi
}

# <dest> [source-dir] -> reads source-dir's open issues (via gh, from the
# repo its `origin` remote names) and creates one issue per source issue on
# <dest> (an OWNER/NAME repo slug), each body carrying a machine-readable
# `copied from <owner>/<repo>#<N>` line — stamped HERE, inside this
# provider's own produce_issues, never in shared downstream code (Produces
# 5). Prints the count copied on success.
_testbed_provider_mirror_from_repo_produce_issues() {
  local dest="${1:?testbed-source(mirror-from-repo): produce_issues requires a destination owner/repo}"
  local source_dir="${2:-.}"
  local source_url source_slug issues_json n i count=0

  command -v gh >/dev/null 2>&1 \
    || { echo "testbed-source(mirror-from-repo): gh CLI not found on PATH" >&2; return 1; }
  command -v jq >/dev/null 2>&1 \
    || { echo "testbed-source(mirror-from-repo): jq not found on PATH" >&2; return 1; }

  source_url="$(git -C "$source_dir" remote get-url origin 2>/dev/null || true)"
  source_slug="$(_testbed_slug_from_remote "$source_url")"
  if [ -z "$source_slug" ]; then
    printf 'testbed-source(mirror-from-repo): cannot resolve source owner/repo from %s'"'"'s origin remote (%s)\n' \
      "$source_dir" "$source_url" >&2
    return 1
  fi

  if ! issues_json="$(gh issue list --repo "$source_slug" --state open --json number,title,body 2>&1)"; then
    printf 'testbed-source(mirror-from-repo): gh issue list on %s failed: %s\n' "$source_slug" "$issues_json" >&2
    return 1
  fi

  n="$(printf '%s' "$issues_json" | jq 'length')"
  i=0
  while [ "$i" -lt "$n" ]; do
    local entry num title body provenance full_body create_out
    entry="$(printf '%s' "$issues_json" | jq -c ".[$i]")"
    num="$(printf '%s' "$entry" | jq -r '.number')"
    title="$(printf '%s' "$entry" | jq -r '.title')"
    body="$(printf '%s' "$entry" | jq -r '.body // ""')"
    provenance="copied from ${source_slug}#${num}"
    full_body="$(printf '%s\n\n---\n%s\n' "$body" "$provenance")"
    if ! create_out="$(gh issue create --repo "$dest" --title "$title" --body "$full_body" 2>&1)"; then
      printf 'testbed-source(mirror-from-repo): gh issue create on %s failed for source #%s: %s\n' \
        "$dest" "$num" "$create_out" >&2
      return 1
    fi
    count=$((count + 1))
    i=$((i + 1))
  done
  printf 'testbed-source(mirror-from-repo): copied %s issue(s) from %s to %s\n' "$count" "$source_slug" "$dest"
}
