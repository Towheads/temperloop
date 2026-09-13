#!/usr/bin/env bash
#
# triples.sh — the triples extractor over the pipeline's registries and raw
# lake (epic Towheads/temperloop#1910, `Designs/temperloop - graph of
# record` (private knowledge store), item "triples-extractor" — source
# temperloop#1910).
#
# WHAT THIS IS. `build` derives `{s, p, o, provenance}` triples from sources
# this kernel checkout ALREADY carries — no new state, no network — and
# appends them to the append-only raw-lake stream `triples-<YYYY-MM>.jsonl`
# (canonical sink spec: meta/data/raw/README.md, whose own "Streams" section
# documents this stream's record shape and gives a worked example). `query`
# answers three lookups against that lake: `cites`, `touched_by`,
# `supersedes`.
#
# SOURCES `build` reads, one predicate per source, each predicate DRAWN FROM
# `workflows/scripts/config/ontology-registry.tsv`'s `edge` axis (ADR 0032)
# — an unlisted predicate is a hard error, never silently emitted:
#
#   cites        workflows/scripts/config/citation-registry.tsv's
#                `<row-id> <TAB> <file>` rows, cross-checked against the
#                `<!-- cite: <row-id> <class>:<ref> ... -->` markers
#                claude/citation-schema.md defines (the SAME grammar
#                workflows/scripts/validate-prose-budget.sh enforces) —
#                s = the row id, o = "<class>:<ref>" verbatim from the
#                marker. Only a marker whose (row-id, file) pair is
#                ACTUALLY registered becomes a triple, so `query cites`
#                answers exactly what the citation-registry validator can
#                enumerate for that row id.
#   touched_by   the `issue-touches-<YYYY-MM>.jsonl` lake stream (pr-open /
#                merge / capture touches) — s = "<repo>#<issue>", o = the
#                session normalized through join-keys-lib.sh's
#                `jk_host_session_stamp` into the SAME "<host>:<sess8>" shape
#                the board's own `fnd:host/session:*` claim stamp uses (the
#                `claimed_by` edge's own documented shape in the ontology
#                registry), so a Session node id is one shape everywhere a
#                triple points at one. A record whose session id is absent
#                or not UUID-shaped is skipped (join-keys' own three-state
#                absent/invalid contract), never coerced into a triple.
#   claimed_by   the `claims-<YYYY-MM>.jsonl` lake stream (scripts/board/
#                claim.sh's claim_log_emit) — s = "board:<board>#<issue>"
#                (the claims record carries no repo, only the board number),
#                o = the same host:sess8 stamp shape as touched_by above.
#   supersedes   docs/adr/*.md's own `## Status` section (ADR 0000's
#                MADR-lite process: an old ADR's Status is edited to
#                `Superseded by ADR-NNNN` / `Superseded by [ADR-NNNN](...)`)
#                — s = the superseding ADR (e.g. "ADR-0033"), o = the file's
#                OWN ADR id (the superseded one). This is the kernel-only
#                counterpart the item's own notes call for: the vault
#                frontmatter decision-supersession signal is an overlay
#                concern (foundation), never read here — `supersedes` in
#                this checkout is ADR-to-ADR only.
#
# `claimed_by` has no `query` verb of its own (only cites/touched_by/
# supersedes are required) but IS built into the lake — the ontology
# registry's `claimed_by` edge exists and this is the one kernel-local
# source for it, so leaving it out of `build` would silently under-populate
# the very stream this item exists to grow. (The notes' third named stream,
# "attributed_to", names no ontology `edge` row and no kernel-emitted lake
# stream — see this script's own header discussion in the item's
# verification surface; it is deliberately never emitted as a predicate,
# per the same "an unlisted predicate is an error" rule this file enforces
# on itself.)
#
# BUILD IS IDEMPOTENT PER MONTH. Every run re-derives the FULL current
# triple set from source truth and appends only lines not already present
# (byte-identical, whole-record match) in the current month's file — running
# `build` twice back to back never doubles the lake. This mirrors the
# append-only-but-safe-to-re-run shape a periodic (e.g. /tidy-driven) batch
# job needs, without inventing a new dedup key beyond the record itself.
#
# Usage:
#   triples.sh build
#   triples.sh query cites <rule-id>
#   triples.sh query touched_by <issue>          # bare "<N>" matches any
#                                                 # repo's "...#<N>"; give
#                                                 # "<owner>/<repo>#<N>" for
#                                                 # an exact match
#   triples.sh query supersedes <adr-ref>        # "0033", "33", "ADR-0033"
#                                                 # all normalize the same
#
# Env overrides (fixture/test seams — production defaults are checkout-
# relative, matching claim.sh / capture.sh's own convention):
#   TRIPLES_REPO_ROOT   root the registries / docs/adr corpus are read
#                       against. Default: this script's own git toplevel.
#   TRIPLES_RAW_DIR     sink dir for triples-<YYYY-MM>.jsonl, and the
#                       fallback read-dir for the issue-touches/claims
#                       streams when their OWN override
#                       (ISSUE_TOUCHES_RAW_DIR / CLAIMS_RAW_DIR) is unset.
#                       Default: "$TRIPLES_REPO_ROOT/meta/data/raw".
#   ISSUE_TOUCHES_RAW_DIR / CLAIMS_RAW_DIR   the SAME registered overrides
#                       capture.sh / claim.sh already own (setting-
#                       registry.tsv) — set these to point at a real,
#                       separately-located lake without moving TRIPLES_RAW_DIR.
#
# No network. Kept bash-3.2-portable (no associative arrays, no mapfile) to
# match the rest of workflows/scripts/ (macOS dev shell + Linux CI).

set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "triples.sh: jq required" >&2; exit 2; }

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Checkout-relative default (claim.sh / capture.sh's own CLAIMS_RAW_DIR_DEFAULT
# convention, temperloop#1822): resolves the checkout this script itself
# lives in, never a fixed personal path.
TRIPLES_REPO_ROOT_DEFAULT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$HOME/dev/foundation")"
: "${TRIPLES_REPO_ROOT:=$TRIPLES_REPO_ROOT_DEFAULT}"

TRIPLES_RAW_DIR_DEFAULT="$TRIPLES_REPO_ROOT/meta/data/raw"
: "${TRIPLES_RAW_DIR:=$TRIPLES_RAW_DIR_DEFAULT}"

# shellcheck source=workflows/scripts/config/join-keys-lib.sh
JOIN_KEYS_LIB="$TRIPLES_REPO_ROOT/workflows/scripts/config/join-keys-lib.sh"
[ -f "$JOIN_KEYS_LIB" ] || { echo "triples.sh: missing join-keys-lib.sh at $JOIN_KEYS_LIB" >&2; exit 2; }
# shellcheck disable=SC1090
source "$JOIN_KEYS_LIB"

die() { echo "triples.sh: $*" >&2; exit 1; }

usage() {
  cat <<'EOF' >&2
Usage: triples.sh build
       triples.sh query cites <rule-id>
       triples.sh query touched_by <issue>
       triples.sh query supersedes <adr-ref>

See this script's own header for the source list, the record shape, and the
env overrides (TRIPLES_REPO_ROOT, TRIPLES_RAW_DIR, ISSUE_TOUCHES_RAW_DIR,
CLAIMS_RAW_DIR).
EOF
  exit 2
}

relpath() { # $1=path, possibly under TRIPLES_REPO_ROOT -> repo-relative or verbatim
  case "$1" in
    "$TRIPLES_REPO_ROOT"/*) printf '%s' "${1#"$TRIPLES_REPO_ROOT"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

ALLOWED_PREDICATES=""
load_ontology_predicates() {
  local ont="$TRIPLES_REPO_ROOT/workflows/scripts/config/ontology-registry.tsv"
  [ -f "$ont" ] || die "missing ontology registry: $ont"
  ALLOWED_PREDICATES=" $(awk -F'\t' '$1 == "edge" { print $2 }' "$ont" | tr '\n' ' ')"
}

predicate_ok() { # $1=predicate
  case "$ALLOWED_PREDICATES" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

require_predicate() { # $1=predicate -- dies loud if the ontology registry doesn't list it
  predicate_ok "$1" || die "predicate '$1' is not a registered ontology edge type (workflows/scripts/config/ontology-registry.tsv) — refusing to emit"
}

# ── cites ────────────────────────────────────────────────────────────────
build_cites() {
  require_predicate cites
  local registry="$TRIPLES_REPO_ROOT/workflows/scripts/config/citation-registry.tsv"
  [ -f "$registry" ] || return 0
  local files
  files="$(awk -F'\t' '
    /^[[:space:]]*#/ { next }
    NF < 2 { next }
    { print $2 }
  ' "$registry" | sort -u)"
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local abs="$TRIPLES_REPO_ROOT/$f"
    [ -f "$abs" ] || continue
    local entry lineno line rowid class ref
    while IFS= read -r entry; do
      lineno="${entry%%:*}"
      line="${entry#*:}"
      if [[ "$line" =~ \<!--\ cite:\ ([A-Z]+\.[0-9]+)\ (incident|guard|class|keep):([^[:space:]]+) ]]; then
        rowid="${BASH_REMATCH[1]}"
        class="${BASH_REMATCH[2]}"
        ref="${BASH_REMATCH[3]}"
        if awk -F'\t' -v r="$rowid" -v fl="$f" '$1 == r && $2 == fl { found = 1 } END { exit !found }' "$registry"; then
          jq -nc --arg s "$rowid" --arg o "${class}:${ref}" --arg file "$f" --arg rec "L$lineno" \
            '{schema_version: "1", s: $s, p: "cites", o: $o, provenance: {file: $file, record: $rec}}'
        fi
      fi
    done < <(grep -n -- '<!-- cite:' "$abs" 2>/dev/null)
  done <<<"$files"
}

# ── touched_by ───────────────────────────────────────────────────────────
build_touched_by() {
  require_predicate touched_by
  local dir="${ISSUE_TOUCHES_RAW_DIR:-$TRIPLES_RAW_DIR}"
  [ -d "$dir" ] || return 0
  local f
  for f in "$dir"/issue-touches-*.jsonl; do
    [ -e "$f" ] || continue
    local relf; relf="$(relpath "$f")"
    local n=0 line repo issue session_id host stamp rc
    while IFS= read -r line; do
      n=$((n + 1))
      [ -n "$line" ] || continue
      jq -e . >/dev/null 2>&1 <<<"$line" || continue
      repo="$(jq -r '.repo // empty' <<<"$line")"
      issue="$(jq -r '.issue // empty' <<<"$line")"
      session_id="$(jq -r '.session_id // empty' <<<"$line")"
      host="$(jq -r '.host // empty' <<<"$line")"
      [ -n "$repo" ] && [ -n "$issue" ] || continue
      stamp="$(jk_host_session_stamp "$host" "$session_id" 2>/dev/null)"
      rc=$?
      [ "$rc" -eq 0 ] && [ -n "$stamp" ] || continue
      jq -nc --arg s "${repo}#${issue}" --arg o "$stamp" --arg file "$relf" --arg rec "L$n" \
        '{schema_version: "1", s: $s, p: "touched_by", o: $o, provenance: {file: $file, record: $rec}}'
    done <"$f"
  done
}

# ── claimed_by ───────────────────────────────────────────────────────────
build_claimed_by() {
  require_predicate claimed_by
  local dir="${CLAIMS_RAW_DIR:-$TRIPLES_RAW_DIR}"
  [ -d "$dir" ] || return 0
  local f
  for f in "$dir"/claims-*.jsonl; do
    [ -e "$f" ] || continue
    local relf; relf="$(relpath "$f")"
    local n=0 line board issue session_id host stamp rc
    while IFS= read -r line; do
      n=$((n + 1))
      [ -n "$line" ] || continue
      jq -e . >/dev/null 2>&1 <<<"$line" || continue
      board="$(jq -r '.board // empty' <<<"$line")"
      issue="$(jq -r '.issue // empty' <<<"$line")"
      session_id="$(jq -r '.session_id // empty' <<<"$line")"
      host="$(jq -r '.host // empty' <<<"$line")"
      [ -n "$board" ] && [ -n "$issue" ] || continue
      stamp="$(jk_host_session_stamp "$host" "$session_id" 2>/dev/null)"
      rc=$?
      [ "$rc" -eq 0 ] && [ -n "$stamp" ] || continue
      jq -nc --arg s "board:${board}#${issue}" --arg o "$stamp" --arg file "$relf" --arg rec "L$n" \
        '{schema_version: "1", s: $s, p: "claimed_by", o: $o, provenance: {file: $file, record: $rec}}'
    done <"$f"
  done
}

# ── supersedes ───────────────────────────────────────────────────────────
build_supersedes() {
  require_predicate supersedes
  local adr_dir="$TRIPLES_REPO_ROOT/docs/adr"
  [ -d "$adr_dir" ] || return 0
  local f
  for f in "$adr_dir"/*.md; do
    [ -e "$f" ] || continue
    local base fname_num
    base="$(basename "$f")"
    case "$base" in
      [0-9][0-9][0-9][0-9]-*.md) fname_num="${base%%-*}" ;;
      *) continue ;;
    esac
    local in_status=0 ln=0 l status_line="" status_lineno=""
    while IFS= read -r l; do
      ln=$((ln + 1))
      if [ "$in_status" -eq 0 ]; then
        if [[ "$l" =~ ^##[[:space:]]+Status[[:space:]]*$ ]]; then
          in_status=1
        fi
        continue
      fi
      if [[ "$l" =~ ^##[[:space:]] ]]; then
        break
      fi
      if [ -n "${l//[[:space:]]/}" ]; then
        status_line="$l"
        status_lineno="$ln"
        break
      fi
    done <"$f"
    [ -n "$status_line" ] || continue
    if [[ "$status_line" =~ Superseded\ by\ (\[ADR-([0-9]+)\]|ADR-([0-9]+)) ]]; then
      local new_num="${BASH_REMATCH[2]}"
      [ -n "$new_num" ] || new_num="${BASH_REMATCH[3]}"
      local old_padded new_padded relf
      old_padded="$(printf 'ADR-%04d' "$((10#$fname_num))")"
      new_padded="$(printf 'ADR-%04d' "$((10#$new_num))")"
      relf="$(relpath "$f")"
      jq -nc --arg s "$new_padded" --arg o "$old_padded" --arg file "$relf" --arg rec "L$status_lineno" \
        '{schema_version: "1", s: $s, p: "supersedes", o: $o, provenance: {file: $file, record: $rec}}'
    fi
  done
}

cmd_build() {
  load_ontology_predicates
  local cand
  cand="$(mktemp "${TMPDIR:-/tmp}/triples-build.XXXXXX")"
  # shellcheck disable=SC2129
  {
    build_cites
    build_touched_by
    build_claimed_by
    build_supersedes
  } >"$cand"

  mkdir -p "$TRIPLES_RAW_DIR" || die "cannot create raw dir: $TRIPLES_RAW_DIR"
  local out_file
  out_file="$TRIPLES_RAW_DIR/triples-$(date -u +%Y-%m).jsonl"
  touch "$out_file"

  local total=0 appended=0 skipped=0
  local c_cites=0 c_touched=0 c_claimed=0 c_super=0
  local line p
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total + 1))
    p="$(jq -r '.p' <<<"$line")"
    case "$p" in
      cites) c_cites=$((c_cites + 1)) ;;
      touched_by) c_touched=$((c_touched + 1)) ;;
      claimed_by) c_claimed=$((c_claimed + 1)) ;;
      supersedes) c_super=$((c_super + 1)) ;;
    esac
    if grep -qxF -- "$line" "$out_file" 2>/dev/null; then
      skipped=$((skipped + 1))
    else
      printf '%s\n' "$line" >>"$out_file"
      appended=$((appended + 1))
    fi
  done <"$cand"
  rm -f "$cand"

  jq -nc \
    --arg file "$(relpath "$out_file")" \
    --argjson total "$total" --argjson appended "$appended" --argjson skipped "$skipped" \
    --argjson cites "$c_cites" --argjson touched_by "$c_touched" \
    --argjson claimed_by "$c_claimed" --argjson supersedes "$c_super" \
    '{file: $file, total: $total, appended: $appended, skipped_duplicate: $skipped,
      predicates: {cites: $cites, touched_by: $touched_by, claimed_by: $claimed_by, supersedes: $supersedes}}'
}

query_stream() {
  local dir="$TRIPLES_RAW_DIR" f
  [ -d "$dir" ] || return 0
  for f in "$dir"/triples-*.jsonl; do
    [ -e "$f" ] && cat -- "$f"
  done
}

cmd_query_cites() { # $1=rule-id
  local rule="${1:?rule-id required}"
  query_stream | jq -c --arg s "$rule" 'select(.p == "cites" and .s == $s)'
}

cmd_query_touched_by() { # $1=issue ("<N>" or "<owner>/<repo>#<N>")
  local key="${1:?issue required}"
  if [[ "$key" == *"#"* ]]; then
    query_stream | jq -c --arg s "$key" 'select(.p == "touched_by" and .s == $s)'
  else
    query_stream | jq -c --arg suf "#$key" 'select(.p == "touched_by" and (.s | endswith($suf)))'
  fi
}

normalize_adr_ref() { # $1=raw -> "ADR-NNNN" when the input is/contains a plain number
  local raw="$1" num
  case "$raw" in
    ADR-* | adr-*) num="${raw#*-}" ;;
    *) num="$raw" ;;
  esac
  case "$num" in
    '' | *[!0-9]*)
      printf '%s' "$raw"
      return
      ;;
  esac
  printf 'ADR-%04d' "$((10#$num))"
}

cmd_query_supersedes() { # $1=adr-ref
  local key="${1:?adr-ref required}" normalized
  normalized="$(normalize_adr_ref "$key")"
  query_stream | jq -c --arg n "$normalized" 'select(.p == "supersedes" and (.s == $n or .o == $n))'
}

[ $# -ge 1 ] || usage
CMD="$1"; shift

case "$CMD" in
  build)
    cmd_build
    ;;
  query)
    [ $# -ge 2 ] || usage
    VERB="$1"; shift
    case "$VERB" in
      cites) cmd_query_cites "$1" ;;
      touched_by) cmd_query_touched_by "$1" ;;
      supersedes) cmd_query_supersedes "$1" ;;
      *) usage ;;
    esac
    ;;
  *)
    usage
    ;;
esac
