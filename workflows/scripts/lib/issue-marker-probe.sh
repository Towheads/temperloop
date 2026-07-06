#!/usr/bin/env bash
#
# issue-marker-probe.sh — a corpus-first, gh-search-fallback implementation of
# the "does an issue already carrying this exact machine-readable marker
# string already exist" probe that /triage and /build repeat at several
# idempotency checkpoints (the doc-sourced back-link probe, the "Triage
# epic:" marker, /build's "Tracked in plan:" back-link, and the
# "Retro-for-epic:" marker). Plan item "cache-search-routing" (F#988 epic,
# sibling of "cache-search-corpus" — issue-corpus.sh, same directory).
#
# WHY CORPUS-FIRST: every one of those call sites today pays one live
# `gh issue list --search "<marker> in:body" --state all` REST search call.
# Once the issue corpus exists (issue-corpus.sh renders the cache-store into
# $(ks_root)/issues/<owner>-<repo>/*.md), the same literal-text answer is
# already sitting on local disk — a live call is redundant IF that render is
# fresh. This file makes that substitution: search the rendered corpus first
# (zero `gh` calls, zero network), and fall back to the exact same live
# `gh issue list --search ... in:body` call every caller used before this
# item, whenever the corpus is absent or stale-beyond-limit. The fallback
# path is not a degraded mode — it is bit-for-bit what every call site did
# prior to this item, so a cold/never-rendered repo behaves exactly as
# before.
#
# BOUNDARY: lives BESIDE issue-corpus.sh and cache.sh, never sources
# board.sh, and (mirroring both siblings) takes an EXPLICIT "owner/repo"
# string only — never a bare board number. Depends on cache.sh (cache_stale/
# cache_meta_file/cache_snapshot_file — the staleness + snapshot-lookup
# layer) and knowledge_store.sh + issue-corpus.sh (ks_list/ks_read,
# issue_corpus_doc_prefix — the rendered-corpus layer). None of those three
# are re-implemented here; this file only READS what they already produce.
#
# Sourced, not executed — same convention as its dependencies:
#   source ".../board/lib/cache.sh"
#   source ".../lib/knowledge_store.sh"
#   source ".../lib/issue-corpus.sh"
#   source ".../lib/issue-marker-probe.sh"
#
# ── "corpus usable" criterion (the absent/stale-beyond-limit gate) ────────
# The corpus itself carries no independent freshness marker of its own — it
# is a pure render of the cache-store snapshot (issue-corpus.sh), so its
# staleness bound is deliberately the SAME one cache.sh already owns
# (`cache_stale`, governed by `CACHE_STORE_TTL`) rather than a second,
# competing TTL knob (subtraction over mechanism — see foundation
# CLAUDE.md's "Design discipline"). The corpus is treated as usable for a
# probe iff ALL of:
#   1. a cache-store meta.json exists for the repo (cache_meta_file),
#   2. it is not stale (`! cache_stale`), and
#   3. at least one document has actually been rendered under this repo's
#      corpus prefix (`ks_list <prefix>` is non-empty — a meta.json can
#      exist with zero renders yet, e.g. issue_corpus_render was never run
#      after cache_refresh).
# Any of the three failing routes straight to the live gh-search fallback —
# never a partial/best-effort corpus answer.
#
# ── body-only matching (the in:title trap, avoided BY CONSTRUCTION) ───────
# GitHub's `in:body` qualifier is a literal-text search restricted to the
# issue description, deliberately excluding both the title and comments. A
# `#<N>`-shaped token inside an `in:title` search is instead parsed by
# GitHub as an issue-reference token, not literal text — the documented trap
# build.md's 4d-retro step already calls out ("a `#<epic>` token inside an
# `in:title` search ... can silently return empty even when the issue
# exists"). This file never searches title OR comments at all: the corpus
# path extracts and grep -F's ONLY the rendered body region of each document
# (see _issue_marker_probe_extract_body below), and the gh-fallback path
# passes the exact same "<marker> in:body" qualifier every caller used
# before this item. A marker that happens to also appear in some issue's
# TITLE (the reference-parsing trap fixture) or in a COMMENT is therefore
# structurally invisible to both paths — there is no code path that could
# match on either, so the trap cannot resurface by accident.
#
# ── output contract ────────────────────────────────────────────────────────
# issue_marker_probe <owner/repo> <marker-string> -> a JSON array on stdout,
# one {"number":N,"title":"...","body":"..."} object per matching issue —
# the same shape build.md's Step 2.5 and 4d-retro already request via
# `gh issue list --search ... --json number,title,body`. A caller that only
# needs presence/number (triage.md's doc-back-link and epic-marker probes,
# 4d-retro's `--json number` probe) reads `jq -r '.[0].number // empty'` off
# the same array.
#   rc 0 — ran to completion; this INCLUDES a legitimate zero-match result
#          (empty `[]` on stdout) — never confused with "probe failed".
#   rc 1 — the live gh fallback itself failed (rate limit / auth / network)
#          — nothing to serve, one stderr notice, empty stdout. The corpus
#          path never returns this rc: a local grep over already-rendered
#          disk files has no live-failure mode analogous to cache.sh's.
#   rc 2 — invalid usage (empty repo or marker argument).
#
# This file sets no shell options of its own (the caller owns set -euo).
# Depends on: cache.sh, knowledge_store.sh, issue-corpus.sh, jq, gh (fallback
# path only — never invoked when the corpus path answers the probe).

# --- the ONE live-gh test-injection seam (mirrors cache.sh's `_cache_gh`) --
# Production runs real `gh`; tests override this after sourcing to replay
# fixtures / fail on demand, with zero network.
_issue_marker_probe_gh_cmd() { gh "$@"; }

# <owner/repo> -> rc 0 valid, rc 2 invalid (message on stderr). Mirrors
# issue-corpus.sh's `_issue_corpus_require_repo`, computed independently here
# (this file does not call another file's private `_issue_corpus_*` /
# `_cache_*` helpers — only their public, documented surface) so it never
# depends on a sibling file's internal naming.
_issue_marker_probe_require_repo() {
  case "$1" in
    */*) return 0 ;;
    *)
      printf 'issue-marker-probe: expected an explicit "owner/repo" (got: %s) -- this file never sources board.sh, so a bare board number cannot be resolved here\n' "$1" >&2
      return 2
      ;;
  esac
}

# stdin: one rendered issue-corpus document (issue-corpus.sh's
# _issue_corpus_render_doc shape: frontmatter, then "# <title>", a blank
# line, the body, then an optional "## Comments" section) -> stdout: the
# BODY region only — frontmatter, the title heading, and any "## Comments"
# section (and everything after it) are all excluded. A defensive fallback
# (a document with no recognizable "# " title line, which should never
# happen against issue-corpus.sh's own renderer) starts the body at the
# first line after the closing frontmatter fence, so a malformed document
# degrades to "search everything past the frontmatter" rather than matching
# nothing at all.
_issue_marker_probe_extract_body() {
  awk '
    BEGIN { fmcount = 0; phase = "frontmatter" }
    phase == "frontmatter" {
      if ($0 == "---") {
        fmcount++
        if (fmcount == 2) { phase = "after_fm" }
      }
      next
    }
    phase == "after_fm" {
      if ($0 == "") { next }
      phase = "body"
      if ($0 ~ /^# /) { next }
      # no title heading found (malformed doc) -- this line is already body
    }
    phase == "body" {
      if ($0 == "## Comments") { exit }
      print
    }
  '
}

# <owner/repo> -> rc 0 if the rendered corpus is usable for a probe (see the
# header's "corpus usable" criterion), rc 1 otherwise (absent or
# stale-beyond-limit -- caller should fall back to live gh search).
_issue_marker_probe_corpus_usable() {
  local repo="$1" meta prefix
  meta="$(cache_meta_file "$repo" 2>/dev/null)" || return 1
  [ -f "$meta" ] || return 1
  cache_stale "$repo" && return 1
  prefix="$(issue_corpus_doc_prefix "$repo" 2>/dev/null)" || return 1
  [ -n "$(ks_list "$prefix" 2>/dev/null)" ] || return 1
  return 0
}

# <owner/repo> <marker> -> JSON array on stdout (see output contract above).
# Assumes _issue_marker_probe_corpus_usable already returned 0 for this repo.
_issue_marker_probe_corpus() {
  local repo="$1" marker="$2" prefix snap doc_id content body n
  prefix="$(issue_corpus_doc_prefix "$repo")" || return 1
  snap="$(cache_snapshot_file "$repo")" || return 1

  local numbers=()
  while IFS= read -r doc_id; do
    [ -n "$doc_id" ] || continue
    content="$(ks_read "$doc_id" 2>/dev/null)" || continue
    body="$(printf '%s\n' "$content" | _issue_marker_probe_extract_body)"
    if printf '%s' "$body" | grep -qF -- "$marker"; then
      n="$(printf '%s\n' "$content" | sed -n 's/^number: *//p' | head -n1)"
      [ -n "$n" ] && numbers+=("$n")
    fi
  done < <(ks_list "$prefix" 2>/dev/null)

  if [ "${#numbers[@]}" -eq 0 ]; then
    printf '[]'
    return 0
  fi

  # Pull {number,title,body} straight from the cache-store snapshot (the raw
  # REST issue rows issue-corpus.sh itself rendered from) rather than
  # reconstructing them from the rendered markdown -- this guarantees the
  # exact same field values a live `gh issue list --json number,title,body`
  # would have returned, byte for byte.
  local nums_json
  nums_json="$(printf '%s\n' "${numbers[@]}" | jq -R 'select(length > 0) | tonumber' | jq -sc '.')"
  jq -c --argjson nums "$nums_json" '
    select(.number as $n | $nums | index($n))
    | {number, title, body}
  ' "$snap" | jq -sc '.'
}

# <owner/repo> <marker> -> JSON array on stdout, via the live gh fallback —
# bit-for-bit the same call every caller made before this item existed.
_issue_marker_probe_gh() {
  local repo="$1" marker="$2" raw rc=0
  raw="$(_issue_marker_probe_gh_cmd issue list -R "$repo" --search "$marker in:body" --state all --json number,title,body 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'issue-marker-probe: gh search failed for %s (rate limit, auth, or network?)\n' "$repo" >&2
    return 1
  fi
  printf '%s' "${raw:-[]}"
}

# <owner/repo> <marker-string> -> JSON array on stdout (see the output
# contract in the header comment above for the full shape/exit-code
# contract).
issue_marker_probe() {
  local repo="$1" marker="${2:-}"
  if [ -z "$repo" ] || [ -z "$marker" ]; then
    echo "issue-marker-probe: usage: issue_marker_probe <owner/repo> <marker-string>" >&2
    return 2
  fi
  _issue_marker_probe_require_repo "$repo" || return $?

  if _issue_marker_probe_corpus_usable "$repo"; then
    _issue_marker_probe_corpus "$repo" "$marker"
    return $?
  fi
  _issue_marker_probe_gh "$repo" "$marker"
}
