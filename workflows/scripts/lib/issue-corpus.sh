#!/usr/bin/env bash
#
# issue-corpus.sh — renders the on-disk issue-cache store (cache.sh,
# workflows/scripts/board/lib/cache.sh) into markdown documents inside the
# knowledge store (knowledge_store.sh's ks_root), then chains a
# ks_search_reindex so the rendered corpus becomes queryable. First
# production caller of the dormant ks_search seam (knowledge_search.sh's
# "No caller routing" non-goal — this is that later, sibling-level work).
#
# BOUNDARY (architecture-review call, plan item "cache-search-corpus"): this
# file lives BESIDE knowledge_search.sh/knowledge_store.sh, deliberately
# OUTSIDE workflows/scripts/board/ and the board-toolkit sync set. board.sh
# is never sourced here and cache.sh is only ever driven with an EXPLICIT
# "owner/repo" string (never a bare board number) — this file has zero
# dependency on board.sh being sourced anywhere in the caller's shell, so
# the board sync set stays completely free of knowledge-stack coupling.
# Same reasoning as cache.sh's own standalone-repo seam (see cache.sh's
# header + CACHE-STORE.md "Design seam: board number OR explicit repo").
#
# Consumes ONLY the documented cache-store on-disk contract (CACHE-STORE.md,
# sibling of cache.sh): snapshot.jsonl rows, details/<n>.json, meta.json's
# schema_version. It never sources board.sh, and never invokes the
# `basic-memory` CLI itself (the only sanctioned call site for that is
# knowledge_search.sh's `_ks_bm_run` — this file only ever calls the public
# ks_search_reindex wrapper, keeping the AGPL boundary lint's "one call
# site" invariant intact).
#
# Sourced, not executed — same convention as its dependencies:
#   source ".../board/lib/cache.sh"
#   source ".../lib/knowledge_store.sh"
#   source ".../lib/knowledge_search.sh"
#   source ".../lib/issue-corpus.sh"
#
# Split-brain guard: every rendered file is written via ks_write, whose only
# target is ks_root (knowledge_store.sh) — there is no independent corpus-
# path knob here, mirroring ks_search's own "always ks_root" contract.
#
# ── On-disk shape rendered ───────────────────────────────────────────────
#   $(ks_root)/issues/<owner>-<repo>/<number>-<slug>.md
# `<owner>-<repo>` mirrors cache.sh's own per-repo slug convention
# (_cache_repo_slug: "/" -> "-"), computed independently here (this file
# does not call cache.sh's internal `_cache_*` helpers — only its public
# path accessors and refresh/read functions) so a consumer never depends on
# cache.sh's private surface.
#
# Each rendered document carries a small YAML frontmatter block
# (number/title/state/labels/updated_at/source) followed by the issue body
# and a "## Comments" section. `updated_at` in the frontmatter is the
# re-render staleness marker: issue_corpus_render re-renders a document only
# when the cache snapshot's `updated_at` for that issue differs from what
# is already stamped in the on-disk document — an unchanged issue costs
# zero writes (and its file's mtime is left untouched).
#
# Known limitation (out of scope for this item): if an issue's TITLE
# changes, its filename's <slug> segment changes too, and the prior file
# under the old slug is left in place rather than deleted/renamed —
# knowledge_store.sh's public interface has no delete op (read/write/
# append/list only), and adding one is an interface change outside this
# item's contract. A future cleanup pass (or a knowledge_store.sh delete
# op) can close this gap; it does not affect the render/staleness/reindex
# contract this item is responsible for.
#
# Depends on: cache.sh (board/lib), knowledge_store.sh, knowledge_search.sh,
# jq. This file sets no shell options of its own (the caller owns set -euo).

# On-disk schema version this renderer understands, per CACHE-STORE.md
# ("### schema_version"). Deliberately its OWN constant rather than reading
# cache.sh's CACHE_STORE_SCHEMA_VERSION variable — this file is a consumer
# of the documented on-disk CONTRACT, not of cache.sh's internal state, so
# it declares independently which schema shape it knows how to render.
# Bump this — and update the render logic below — when CACHE-STORE.md's
# schema_version changes in a way the current render logic doesn't already
# handle.
ISSUE_CORPUS_CACHE_SCHEMA_VERSION=1

# --- repo-slug + doc-id helpers --------------------------------------------
# "owner/repo" -> "owner-repo". Mirrors cache.sh's _cache_repo_slug, computed
# independently (see header note above) rather than calling cache.sh's
# private helper.
_issue_corpus_repo_slug() {
  printf '%s' "$1" | tr '/' '-'
}

# Validates the first argument is an explicit "owner/repo" (contains a "/")
# — this file NEVER resolves a bare board number (that would require
# sourcing board.sh, which this file must stay independent of). Prints
# nothing; rc 0 valid, rc 2 invalid (message on stderr).
_issue_corpus_require_repo() {
  case "$1" in
    */*) return 0 ;;
    *)
      printf 'issue-corpus: expected an explicit "owner/repo" (got: %s) -- this file never sources board.sh, so a bare board number cannot be resolved here\n' "$1" >&2
      return 2
      ;;
  esac
}

# <owner/repo> -> the doc-id PREFIX (relative to ks_root) all of this repo's
# rendered issue documents live under: "issues/<owner>-<repo>".
issue_corpus_doc_prefix() {
  _issue_corpus_require_repo "$1" || return $?
  printf 'issues/%s' "$(_issue_corpus_repo_slug "$1")"
}

# <title> <number> -> a filesystem/URL-safe slug: lowercased, non-alnum runs
# collapsed to single hyphens, leading/trailing hyphens trimmed, capped at
# 60 chars. Falls back to "issue-<number>" for an empty/all-punctuation
# title so a doc-id is never empty.
_issue_corpus_slugify() {
  local title="$1" number="$2" s
  s="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  s="${s:0:60}"
  s="${s%-}"
  [ -n "$s" ] || s="issue-${number}"
  printf '%s' "$s"
}

# <owner/repo> <number> <title> -> the full doc-id for that issue's current
# title ("issues/<owner>-<repo>/<number>-<slug>.md").
issue_corpus_doc_id() {
  local repo="$1" number="$2" title="$3" prefix slug
  prefix="$(issue_corpus_doc_prefix "$repo")" || return $?
  slug="$(_issue_corpus_slugify "$title" "$number")"
  printf '%s/%s-%s.md' "$prefix" "$number" "$slug"
}

# --- document rendering -----------------------------------------------------
# <repo> <number> <title> <state> <updated_at> <labels_json> <body> <comments_md>
# -> full markdown document content on stdout (frontmatter + body + comments).
# Every scalar frontmatter value is JSON-escaped via `jq -Rn` before being
# embedded — a JSON string is a valid YAML flow scalar, so this is safe
# against titles/bodies containing colons, quotes, or newlines without
# hand-rolling YAML escaping.
_issue_corpus_render_doc() {
  local repo="$1" number="$2" title="$3" state="$4" updated_at="$5" labels_json="$6" body="$7" comments_md="$8"
  local title_y state_y updated_y source_y
  title_y="$(jq -Rn --arg v "$title" '$v')"
  state_y="$(jq -Rn --arg v "$state" '$v')"
  updated_y="$(jq -Rn --arg v "$updated_at" '$v')"
  source_y="$(jq -Rn --arg v "${repo}#${number}" '$v')"
  printf -- '---\n'
  printf 'number: %s\n' "$number"
  printf 'title: %s\n' "$title_y"
  printf 'state: %s\n' "$state_y"
  printf 'labels: %s\n' "${labels_json:-[]}"
  printf 'updated_at: %s\n' "$updated_y"
  printf 'source: %s\n' "$source_y"
  printf -- '---\n\n'
  printf '# %s\n\n' "$title"
  printf '%s\n' "$body"
  if [ -n "$comments_md" ]; then
    printf '\n## Comments\n\n%s\n' "$comments_md"
  fi
}

# --- the render entrypoint --------------------------------------------------
# <owner/repo> -> walks the CURRENT on-disk cache-store snapshot (does NOT
# trigger a live refresh itself -- that is cache_refresh's job, see
# issue_corpus_sync below) and re-renders exactly the documents whose
# snapshot `updated_at` has advanced past what is already on disk.
#
#   rc 0 = ran to completion (possibly rendering zero documents -- an
#          absent/empty cache store is "nothing to render yet", not an
#          error)
#   rc 1 = an I/O failure (ks_write failed)
#   rc 2 = invalid repo argument, OR the on-disk schema_version does not
#          match ISSUE_CORPUS_CACHE_SCHEMA_VERSION (refuses to guess at an
#          unrecognized on-disk shape)
issue_corpus_render() {
  local repo="$1" meta schema_actual snap prefix
  _issue_corpus_require_repo "$repo" || return $?

  meta="$(cache_meta_file "$repo")" || return 1
  if [ ! -f "$meta" ]; then
    echo "issue-corpus: no cache store yet for $repo (run cache_refresh first) -- nothing to render" >&2
    return 0
  fi
  schema_actual="$(jq -r '.schema_version // empty' "$meta" 2>/dev/null)"
  if [ "$schema_actual" != "$ISSUE_CORPUS_CACHE_SCHEMA_VERSION" ]; then
    printf 'issue-corpus: cache store schema_version mismatch for %s (store=%s, expected=%s per CACHE-STORE.md) -- refusing to guess at shape\n' \
      "$repo" "$schema_actual" "$ISSUE_CORPUS_CACHE_SCHEMA_VERSION" >&2
    return 2
  fi

  snap="$(cache_snapshot_file "$repo")" || return 1
  if [ ! -f "$snap" ]; then
    echo "issue-corpus: no snapshot for $repo yet -- nothing to render" >&2
    return 0
  fi
  prefix="$(issue_corpus_doc_prefix "$repo")" || return $?

  local line number title state updated_at labels_json slug doc_id
  local existing existing_updated details detail_schema body comments_md content
  local n_rendered=0 n_skipped=0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    number="$(printf '%s' "$line" | jq -r '.number // empty')"
    [ -n "$number" ] || continue
    title="$(printf '%s' "$line" | jq -r '.title // ""')"
    state="$(printf '%s' "$line" | jq -r '.state // ""')"
    updated_at="$(printf '%s' "$line" | jq -r '.updated_at // ""')"
    labels_json="$(printf '%s' "$line" | jq -c '[(.labels // [])[] | if type == "object" then .name else . end]')"

    slug="$(_issue_corpus_slugify "$title" "$number")"
    doc_id="${prefix}/${number}-${slug}.md"

    existing="$(ks_read "$doc_id" 2>/dev/null || true)"
    if [ -n "$existing" ]; then
      existing_updated="$(printf '%s\n' "$existing" | sed -n 's/^updated_at: *"\{0,1\}\(.*[^"]\)"\{0,1\} *$/\1/p' | head -n1)"
      if [ "$existing_updated" = "$updated_at" ]; then
        n_skipped=$((n_skipped + 1))
        continue
      fi
    fi

    body=""
    comments_md=""
    details="$(cache_read_details "$repo" "$number" 2>/dev/null || true)"
    if [ -n "$details" ]; then
      detail_schema="$(printf '%s' "$details" | jq -r '.schema_version // empty' 2>/dev/null)"
      if [ -n "$detail_schema" ] && [ "$detail_schema" != "$ISSUE_CORPUS_CACHE_SCHEMA_VERSION" ]; then
        printf 'issue-corpus: details schema_version mismatch for %s#%s (got %s) -- rendering without body/comments\n' \
          "$repo" "$number" "$detail_schema" >&2
      else
        body="$(printf '%s' "$details" | jq -r '.body // ""')"
        comments_md="$(printf '%s' "$details" | jq -r '
          [(.comments // [])[] | "- **" + (.user.login // "unknown") + "** (" + (.created_at // "") + "):\n\n" + (.body // "") + "\n"] | join("\n")
        ')"
      fi
    fi

    content="$(_issue_corpus_render_doc "$repo" "$number" "$title" "$state" "$updated_at" "$labels_json" "$body" "$comments_md")"
    if ! printf '%s\n' "$content" | ks_write "$doc_id"; then
      echo "issue-corpus: ks_write failed for $doc_id" >&2
      return 1
    fi
    n_rendered=$((n_rendered + 1))
  done <"$snap"

  printf 'issue-corpus: rendered %s, skipped %s (unchanged) for %s\n' "$n_rendered" "$n_skipped" "$repo" >&2
  return 0
}

# --- the full chain: cache refresh -> render -> ks_search reindex ----------
# <owner/repo> [--full] -> cache_refresh (cache.sh, live gh calls) then
# issue_corpus_render (this file) then ks_search_reindex (knowledge_search.sh
# -- the ONLY basic-memory call site; this file never invokes uvx/
# basic-memory directly). `--full` is forwarded to ks_search_reindex only
# (cache_refresh has no incremental/full distinction of its own).
#
# Propagates whichever step's failure rc first: cache_refresh's (1/2),
# issue_corpus_render's (1/2), or ks_search_reindex's (2/3/4 -- see
# knowledge_search.sh's exit-code contract, including the legible-
# degradation exit 3 when uvx is unavailable).
issue_corpus_sync() {
  local repo="$1" full=0
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --full) full=1; shift ;;
      *) shift ;;
    esac
  done

  local rc
  cache_refresh "$repo"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "issue-corpus: cache_refresh failed for $repo" >&2
    return "$rc"
  fi
  issue_corpus_render "$repo" || return $?

  if [ "$full" -eq 1 ]; then
    ks_search_reindex --full
  else
    ks_search_reindex
  fi
}
