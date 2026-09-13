#!/usr/bin/env bash
#
# state-graph.sh — the derived state graph's CORE builder (temperloop#1910,
# epic "graph of record"; ADR 0033, docs/adr/0033-the-derived-state-graph-
# composes-one-way-and-one-independent-cross-check-survives.md).
#
# `build --board N` derives ONE typed nodes+edges snapshot per repo from
# exactly four sources — the board, its native sub-issue/blocked-by edges,
# open PRs, and linked git worktrees — and writes it through the namespaced
# board cache library (workflows/scripts/board/lib/cache.sh, kind=state-graph,
# temperloop#1929): that library's repo-keyed directory, its meta.json, its
# temp-then-rename write discipline, and its `cache_dirty`/`cache_clear`
# invalidation are INHERITED here, never reimplemented (this file's own
# `_sg_persist_snapshot` writes through cache.sh's own path accessors —
# cache_repo_dir / cache_snapshot_file / cache_meta_file — rather than a
# hand-rolled store).
#
# Every source carries a typed status — `ok`, `absent`, `error`, or `stale` —
# never collapsed into an untyped empty result (ADR 0033's whole reason to
# exist). `build` itself only ever produces `ok`/`absent`/`error`: a source
# it just live-fetched is never stale AT THE MOMENT it writes. `stale` is a
# READ-time transform — `_sg_read_snapshot` (this file's read helper, used
# internally and by the later `state-graph.sh query` item) overrides every
# source's status to `stale` when the on-disk snapshot's age is at or past
# the named setting `STATE_GRAPH_MAX_AGE_S`, so a consumer never silently
# acts on data this run has already outgrown.
#
# THE READER TABLE IS EXTENSIBLE (acceptance criterion 1): this file first
# shipped four sources — board / board_edges / pr_list / worktrees — as four
# independent `_sg_read_*` functions plus one line each in `_SG_SOURCES`
# below. `state-graph-build-local` (temperloop#1918) appended three more
# HOST-LOCAL sources the same way — plan_notes (knowledge-store `Plans/`
# notes), journal (the Workflow runtime's `agent-<id>.jsonl` transcripts),
# and tmux (the per-window `@claimed_issue` claim marker) — without touching
# the original four or the assembly loop that calls them. "Host-local" means
# exactly that: unlike the four `gh`-backed/git sources above, these three
# describe the state of the MACHINE running `build`, not the repo/board, so
# a snapshot built on two different hosts can legitimately disagree on them.
#
#   state-graph.sh build --board <N>            build + persist + print
#   state-graph.sh clean --board <N>             remove ONE repo's snapshot
#   state-graph.sh bench --scale <N> --board <N>  synthetic N-scale timing run
#
# Two overridable command seams, mirroring board.sh's own `_board_gh`
# (sourced below and reused as-is for the board/board_edges/pr_list sources —
# they are all `gh`-backed reads, so one seam covers three of the four
# sources; tests dispatch on argv the same way test_board_replay.sh does):
#   _board_gh   — every `gh` call (board.sh's own seam; this file adds no
#                 second `gh` seam so a test overriding one place covers the
#                 board, board_edges, AND pr_list sources)
#   _sg_git     — the one non-`gh` external command (`git worktree list`)
#
# No network in tests: every source above is read through one of the two
# seams, so `test_state_graph.sh` replays fixtures with zero network access
# (acceptance criterion 4).
set -euo pipefail

_SG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=workflows/scripts/board/lib/board.sh
# shellcheck disable=SC1091
source "$_SG_HERE/../board/lib/board.sh"
# shellcheck source=workflows/scripts/board/lib/cache.sh
# shellcheck disable=SC1091
source "$_SG_HERE/../board/lib/cache.sh"
# shellcheck source=workflows/scripts/config/join-keys-lib.sh
# shellcheck disable=SC1091
source "$_SG_HERE/../config/join-keys-lib.sh"
# shellcheck source=workflows/scripts/build/build.config.sh
# shellcheck disable=SC1091
source "$_SG_HERE/build.config.sh"
# shellcheck source=workflows/scripts/lib/knowledge_store.sh
# shellcheck disable=SC1091
source "$_SG_HERE/../lib/knowledge_store.sh"

# The ontology registry (ADR 0032) — the ONE source of truth for the
# `state:issue-status` alphabet a board-read Issue node's `status` must
# belong to. Overridable for tests (a throwaway fixture registry), defaults
# to the real repo-shipped one.
ONTOLOGY_REGISTRY_FILE="${ONTOLOGY_REGISTRY_FILE:-$_SG_HERE/../config/ontology-registry.tsv}"

usage() {
  echo "usage: state-graph.sh build --board <N> | clean --board <N> | bench --scale <N> --board <N>" >&2
}

# --- overridable command seams ---------------------------------------------
# `git worktree list`'s one call site. Production runs real git; tests
# override this after sourcing to replay fixtures / fail on demand.
_sg_git() { git "$@"; }

# Millisecond wall clock for `bench` (perl Time::HiRes, same portability
# fallback gh-call-logger.sh already uses — bash on macOS is 3.2, no
# $EPOCHREALTIME, and BSD `date` has no %N; perl ships everywhere this runs).
# Falls back to whole-second resolution (never fatal) when perl is absent.
_sg_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null ||
    printf '%s000' "$(date +%s)"
}

# --- ontology-registry lookups (ADR 0032) -----------------------------------
# Every `state:issue-status` TOKEN column (col 2), one per line.
_sg_issue_status_tokens() {
  awk -F'\t' '$1=="state:issue-status" && $2!="" {print $2}' "$ONTOLOGY_REGISTRY_FILE" 2>/dev/null
}

# A raw board `.status` value ("Ready" / "In Progress" / "Backlog" / "Done")
# -> its ontology-registry token ("fnd:status:ready" / ... / "done"). Mirrors
# board.sh's own `unslug` in reverse (lib/board.sh's `_BOARD_ISSUES_JQ_DEFS`),
# entirely in jq so this file introduces no second, bash-side slugger that
# could drift from board.sh's.
_SG_STATUS_TOKEN_JQ='
def status_token:
  if . == "Done" then "done"
  else "fnd:status:" + (. | ascii_downcase | gsub(" "; "-"))
  end;
'

# claimed_by reader: normalize the board's VERBATIM `host/Session` claim
# stamp ("<host>:<sess8>" or "<host>:manual", lib/board.sh's board_own_stamp)
# through the join-key loader, never hand-rolled parsing (acceptance
# criterion 2). The stamp is ALREADY session8-shaped by the time board.sh
# writes it (board_own_stamp truncates before storing), so `jk_session8` —
# which validates a FULL 36-char UUID — cannot re-derive it from the
# already-short form; it is called anyway so a future writer that stores the
# untruncated id is normalized for real, and the current pre-truncated form
# falls back to the loader's own OUTPUT shape (lowercase) rather than a
# second, hand-written case-fold rule.
_sg_normalize_claimed_by() {
  local stamp="$1" host part full
  host="${stamp%%:*}"
  part="${stamp#*:}"
  if [ "$part" = "manual" ]; then
    printf '%s:manual' "$host"
    return 0
  fi
  if full="$(jk_session8 "$part" 2>/dev/null)"; then
    printf '%s:%s' "$host" "$full"
  else
    printf '%s:%s' "$host" "$(printf '%s' "$part" | tr '[:upper:]' '[:lower:]')"
  fi
}

# journal reader: normalize a workflow-journal `sessionId` field through
# jk_session_full (the join-key loader) rather than hand-rolled parsing —
# the journal source's own equivalent of _sg_normalize_claimed_by above. A
# non-UUID-shaped id (never expected in a real transcript, but a journal is
# untrusted input) falls back to the loader's own lowercase OUTPUT shape,
# same fallback discipline as _sg_normalize_claimed_by.
_sg_normalize_session_id() {
  local raw="$1" full
  if full="$(jk_session_full "$raw" 2>/dev/null)"; then
    printf '%s' "$full"
  else
    printf '%s' "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  fi
}

# --- shared per-source result envelope --------------------------------------
# Every `_sg_read_*` reader prints exactly one compact JSON object:
#   {"status": ok|absent|error, "detail": "...", "nodes": [...], "edges": [...]}
_sg_source_result() {
  local status="$1" nodes="$2" edges="$3" detail="${4:-}"
  jq -cn --arg status "$status" --arg detail "$detail" \
    --argjson nodes "$nodes" --argjson edges "$edges" \
    '{status: $status, detail: $detail, nodes: $nodes, edges: $edges}'
}

# --- source 1: board (Issue nodes, fnd:status:* state, claimed_by edges) ---
# One `board_resolve` (acceptance criterion 1). `absent` = the board legitimately
# has zero open issues; `error` = board_resolve itself failed, OR any item's
# derived status token is not a `state:issue-status` row in the ontology
# registry (acceptance criterion 1's "a node state not in the ontology
# registry makes that source error").
_sg_read_board() {
  local board="$1" items count bad nodes edges stamp norm
  if ! board_resolve "$board" >/dev/null 2>&1; then
    _sg_source_result error '[]' '[]' "board_resolve failed"
    return 0
  fi
  items="$(printf '%s' "$BOARD_ITEMS_JSON" | jq -c '.items')"
  count="$(printf '%s' "$items" | jq 'length' 2>/dev/null)" || count=""
  if [ -z "$count" ]; then
    _sg_source_result error '[]' '[]' "unparseable board item list"
    return 0
  fi
  if [ "$count" -eq 0 ]; then
    _sg_source_result absent '[]' '[]' ""
    return 0
  fi
  bad="$(printf '%s' "$items" | jq --argjson toks "$(_sg_issue_status_tokens | jq -Rsc 'split("\n") | map(select(length>0))')" "
    $_SG_STATUS_TOKEN_JQ
    [ .[] | (.status // \"\") as \$s
      | (if \$s == \"\" then \"\" else (\$s | status_token) end) as \$tok
      | select(\$tok == \"\" or (\$toks | index(\$tok)) == null) ] | length
  ")"
  if [ "${bad:-0}" -gt 0 ]; then
    _sg_source_result error '[]' '[]' "node status not in ontology registry"
    return 0
  fi
  nodes="$(printf '%s' "$items" | jq -c "
    $_SG_STATUS_TOKEN_JQ
    [ .[] | {
        type: \"Issue\",
        id: (\"Issue:\" + (.content.number | tostring)),
        number: .content.number,
        status: (.status | status_token)
      } ]
  ")"
  edges='[]'
  while IFS=$'\t' read -r from_n stamp; do
    [ -n "$from_n" ] || continue
    norm="$(_sg_normalize_claimed_by "$stamp")"
    edges="$(jq -c --arg f "Issue:${from_n}" --arg t "Session:${norm}" \
      '. + [{type:"claimed_by", from:$f, to:$t}]' <<<"$edges")"
  done < <(printf '%s' "$items" | jq -r '.[] | select((.["host/Session"] // "") != "") | [ (.content.number|tostring), .["host/Session"] ] | @tsv')
  _sg_source_result ok "$nodes" "$edges" ""
}

# --- source 2: board_edges (sub_issue_of, blocked_by) ----------------------
# `board_sub_issues` + native `board_blocked_by_open` (acceptance criterion
# 1), gated on the board's own open-issue set (source 1) — never the whole
# repo (board.sh's own per-issue-REST caveat on both accessors). Both
# accessors are FAIL-OPEN by design (lib/board.sh: a `_board_gh` failure and
# a legitimately-empty result are indistinguishable from the caller's side,
# by deliberate design — see board_sub_issues's own "NO CACHED ARM" comment),
# so this source's `error` status cascades from source 1's rather than
# inventing a signal board.sh does not expose.
_sg_read_board_edges() {
  local board="$1" board_json="$2" status numbers n child b edges
  status="$(jq -r '.status' <<<"$board_json")"
  case "$status" in
    error) _sg_source_result error '[]' '[]' "upstream board source errored"; return 0 ;;
    absent) _sg_source_result absent '[]' '[]' ""; return 0 ;;
  esac
  numbers="$(jq -r '.nodes[].number' <<<"$board_json")"
  edges='[]'
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    while IFS= read -r child; do
      [ -n "$child" ] || continue
      edges="$(jq -c --arg c "$child" --arg p "$n" \
        '. + [{type:"sub_issue_of", from:("Issue:"+$c), to:("Issue:"+$p)}]' <<<"$edges")"
    done < <(board_sub_issues "$board" "$n" all)
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      edges="$(jq -c --arg b "$b" --arg i "$n" \
        '. + [{type:"blocked_by", from:("Issue:"+$i), to:("Issue:"+$b)}]' <<<"$edges")"
    done < <(board_blocked_by_open "$board" "$n")
  done <<<"$numbers"
  if [ "$(jq 'length' <<<"$edges")" -eq 0 ]; then
    _sg_source_result absent '[]' '[]' ""
  else
    _sg_source_result ok '[]' "$edges" ""
  fi
}

# --- source 3: pr_list (PR nodes, closes edges) -----------------------------
# One `gh pr list --state open` (acceptance criterion 1). `closes` edges are
# parsed from a BARE `Closes #N` / `Fixes #N` / `Resolves #N` line in the PR
# body (own line, any tense, case-insensitive — claude/CLAUDE.kernel.md
# § Issue linkage), never a backticked or mid-sentence mention, and a body
# may carry more than one such line (one edge per line).
_sg_read_pr_list() {
  local board="$1" repo raw count nodes edges
  repo="$(board_repo "$board" 2>/dev/null)" || { _sg_source_result error '[]' '[]' "board_repo failed"; return 0; }
  if ! raw="$(_board_gh pr list -R "$repo" --state open --json number,title,body --limit 100 2>/dev/null)"; then
    _sg_source_result error '[]' '[]' "gh pr list failed"
    return 0
  fi
  [ -n "$raw" ] || raw="[]"
  count="$(printf '%s' "$raw" | jq 'length' 2>/dev/null)" || { _sg_source_result error '[]' '[]' "unparseable gh pr list output"; return 0; }
  if [ "$count" -eq 0 ]; then
    _sg_source_result absent '[]' '[]' ""
    return 0
  fi
  nodes="$(printf '%s' "$raw" | jq -c '[ .[] | {type:"PR", id:("PR:"+(.number|tostring)), number:.number, title:(.title // "")} ]')"
  edges="$(printf '%s' "$raw" | jq -c '
    [ .[] as $pr
      | (($pr.body // "") | split("\n")[]) as $line
      | select($line | test("^[ \t]*(close[sd]?|fix(e[sd])?|resolve[sd]?)[ \t]+#[0-9]+[ \t]*$"; "i"))
      | ($line | capture("#(?<n>[0-9]+)")) as $m
      | {type:"closes", from:("PR:"+($pr.number|tostring)), to:("Issue:"+$m.n)}
    ]')"
  _sg_source_result ok "$nodes" "$edges" ""
}

# --- source 4: worktrees (Worktree nodes) -----------------------------------
# `git worktree list` (acceptance criterion 1), filtered to LINKED worktrees
# under `<repo-basename>.wt/` (ADR 0033) — the main checkout itself is never
# emitted as a node. `absent` = a git repo with no linked worktrees right
# now (the common case); `error` = `_sg_git` itself failed (not a git repo,
# or git unavailable).
_sg_read_worktrees() {
  local board="$1" repo base raw line path nodes
  repo="$(board_repo "$board" 2>/dev/null)" || { _sg_source_result error '[]' '[]' "board_repo failed"; return 0; }
  base="$(basename "$repo")"
  if ! raw="$(_sg_git worktree list --porcelain 2>/dev/null)"; then
    _sg_source_result error '[]' '[]' "git worktree list failed"
    return 0
  fi
  nodes='[]'
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path="${line#worktree }"
        case "$path" in
          */"${base}.wt/"*)
            nodes="$(jq -c --arg p "$path" '. + [{type:"Worktree", id:("Worktree:"+$p), path:$p}]' <<<"$nodes")"
            ;;
        esac
        ;;
    esac
  done <<<"$raw"
  if [ "$(jq 'length' <<<"$nodes")" -eq 0 ]; then
    _sg_source_result absent '[]' '[]' ""
  else
    _sg_source_result ok "$nodes" '[]' ""
  fi
}

# --- source 5: plan_notes (PlanItem nodes, depends_on/after edges) ---------
# One `ks_list Plans` + `ks_read` per matching note, through the knowledge-
# store interface (lib/knowledge_store.sh, `KNOWLEDGE_STORE_ROOT`) — never a
# hand-rolled vault-path read. Only a note whose frontmatter `status:` is
# `approved` or `executing` counts (a `draft`/`done`/`abandoned` plan is not
# live work — mirrors `/build`'s own `status:` gate, claude/plan-schema.md).
# `absent` = the store (or its `Plans/` prefix) does not exist, OR no note
# matched (acceptance criterion: "an absent store or no matching note is
# absent") — `ks_list` already returns nothing (not an error) for a missing
# root/prefix, so this needs no separate existence probe. `error` = an
# item's checkbox sentinel is not a `state:plan-sentinel` row in the
# ontology registry (mirrors source 1's own unknown-token error, ADR 0032).
# `depends-on:`/`after:` are parsed by SLUG (claude/plan-schema.md § Item
# identifier, never by position) and resolved to `PlanItem:<stem>:<slug>`
# node ids, `<stem>` from `jk_plan_stem` (the join-key loader — never a
# hand-stripped `basename`/`.md` trim). `pr:`/`pushed_sha:` (orchestrator-
# written fields, same section) ride as plain node fields; the ontology
# defines no edge for them.
_sg_plan_sentinel_tokens() {
  awk -F'\t' '$1=="state:plan-sentinel" && $2!="" {print $2}' "$ONTOLOGY_REGISTRY_FILE" 2>/dev/null
}

# <content> -> the frontmatter `status:` value, or nothing if absent/no
# frontmatter block. Scoped strictly to the FIRST `---`/`---` pair so a
# `status:`-shaped line in the body (an example in `notes:`, say) is never
# mistaken for the real frontmatter field.
_sg_plan_note_status() {
  awk '
    /^---[[:space:]]*$/ { d++; next }
    d==1 && /^status:[[:space:]]*/ { sub(/^status:[[:space:]]*/,""); gsub(/[[:space:]]+$/,""); print; exit }
    d>=2 { exit }
  ' <<<"$1"
}

# <sentinel-tokens-json> <stem> <slug> <sentinel-char> <depends-csv>
# <after-csv> <pr> <pushed_sha> -> {bad, node, edges} for one plan item.
# `bad`=true when the sentinel is not a registered state:plan-sentinel
# token (the caller flips the whole source to `error`); node/edges are
# null/empty in that case. Kept as its own function (rather than inlined in
# the line-scanning loop below) purely to keep that loop a plain
# state-machine walk.
_sg_plan_item_result() {
  local toks="$1" stem="$2" slug="$3" sentinel="$4" deps="$5" afters="$6" pr="$7" sha="$8"
  jq -cn --argjson toks "$toks" --arg stem "$stem" --arg slug "$slug" --arg tok "[$sentinel]" \
    --arg pr "$pr" --arg sha "$sha" --arg deps "$deps" --arg afters "$afters" '
    ("PlanItem:" + $stem + ":" + $slug) as $id |
    if ($toks | index($tok)) == null then
      {bad: true, node: null, edges: []}
    else
      {
        bad: false,
        node: ({type:"PlanItem", id:$id, slug:$slug, state:$tok}
               + (if $pr=="" then {} else {pr:$pr} end)
               + (if $sha=="" then {} else {pushed_sha:$sha} end)),
        edges: (
          ($deps | split(",") | map(select(length>0))
            | map({type:"depends_on", from:$id, to:("PlanItem:"+$stem+":"+.)}))
          + ($afters | split(",") | map(select(length>0))
            | map({type:"after", from:$id, to:("PlanItem:"+$stem+":"+.)}))
        )
      }
    end'
}

_sg_read_plan_notes() {
  local ids id content st stem nodes edges bad=0 sentinel_toks
  local line cur_slug cur_sentinel cur_deps cur_afters cur_pr cur_sha
  local records s se de af pr sh res fs
  # Item checkbox: `- [<c>] **<title>** \`slug: <kebab>\` — <scope>`, at
  # column 0 (an indented sub-bullet, e.g. an acceptance-list line, never
  # matches). Sub-field: `  - <key>: <value>`, 2-space indented under it.
  # shellcheck disable=SC2016  # the backtick is a literal pattern character
  local item_re='^- \[([^]])\].*`slug:[[:space:]]*([a-z0-9-]+)`'
  local sub_re='^[[:space:]]+- (depends-on|after|pr|pushed_sha):[[:space:]]*(.*)$'
  # Internal-only field separator for the `records` accumulator below — the
  # ASCII Unit Separator (0x1F), never TAB. Bash's `read` treats TAB (like
  # every default-IFS whitespace char) as a COLLAPSING delimiter regardless
  # of what IFS is set to: a run of them is one delimiter and an EMPTY field
  # between two of them silently vanishes, shifting every field after it one
  # slot left (`pr:`/`pushed_sha:` landing in each other's place when
  # `depends-on:`/`after:` is absent in between). \x1f is not IFS
  # whitespace, so `read` preserves empty fields exactly where TAB would not.
  fs=$'\x1f'

  sentinel_toks="$(_sg_plan_sentinel_tokens | jq -Rsc 'split("\n") | map(select(length>0))')"
  nodes='[]'; edges='[]'
  ids="$(ks_list Plans 2>/dev/null)" || ids=""

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    content="$(ks_read "$id" 2>/dev/null)" || continue
    st="$(_sg_plan_note_status "$content")"
    case "$st" in
      approved | executing) ;;
      *) continue ;;
    esac
    stem="$(jk_plan_stem "$id" 2>/dev/null)" || stem="$id"

    records=""
    cur_slug=""; cur_sentinel=""; cur_deps=""; cur_afters=""; cur_pr=""; cur_sha=""
    while IFS= read -r line; do
      if [[ $line =~ $item_re ]]; then
        if [ -n "$cur_slug" ]; then
          records="${records}${cur_slug}${fs}${cur_sentinel}${fs}${cur_deps}${fs}${cur_afters}${fs}${cur_pr}${fs}${cur_sha}"$'\n'
        fi
        cur_sentinel="${BASH_REMATCH[1]}"
        cur_slug="${BASH_REMATCH[2]}"
        cur_deps=""; cur_afters=""; cur_pr=""; cur_sha=""
      elif [ -n "$cur_slug" ] && [[ $line =~ $sub_re ]]; then
        case "${BASH_REMATCH[1]}" in
          depends-on) cur_deps="$(printf '%s' "${BASH_REMATCH[2]}" | tr -d ' ')" ;;
          after) cur_afters="$(printf '%s' "${BASH_REMATCH[2]}" | tr -d ' ')" ;;
          pr) cur_pr="${BASH_REMATCH[2]}" ;;
          pushed_sha) cur_sha="${BASH_REMATCH[2]}" ;;
        esac
      fi
    done <<<"$content"
    if [ -n "$cur_slug" ]; then
      records="${records}${cur_slug}${fs}${cur_sentinel}${fs}${cur_deps}${fs}${cur_afters}${fs}${cur_pr}${fs}${cur_sha}"$'\n'
    fi

    while IFS="$fs" read -r s se de af pr sh; do
      [ -n "$s" ] || continue
      res="$(_sg_plan_item_result "$sentinel_toks" "$stem" "$s" "$se" "$de" "$af" "$pr" "$sh")"
      if [ "$(jq -r '.bad' <<<"$res")" = "true" ]; then
        bad=1
        continue
      fi
      nodes="$(jq -c --argjson n "$(jq -c '.node' <<<"$res")" '. + [$n]' <<<"$nodes")"
      edges="$(jq -c --argjson e "$(jq -c '.edges' <<<"$res")" '. + $e' <<<"$edges")"
    done <<<"$records"
  done <<<"$ids"

  if [ "$bad" -eq 1 ]; then
    _sg_source_result error '[]' '[]' "plan-item sentinel not in ontology registry"
    return 0
  fi
  if [ "$(jq 'length' <<<"$nodes")" -eq 0 ]; then
    _sg_source_result absent '[]' '[]' ""
  else
    _sg_source_result ok "$nodes" "$edges" ""
  fi
}

# --- source 6: journal (Session nodes, step outcomes) -----------------------
# Reads every `agent-*.jsonl` workflow-runtime transcript found at any depth
# under `$SPEND_TRANSCRIPT_ROOT` (build.config.sh) — the SAME transcript
# root pipeline-spend-report.sh already reads (temperloop#958); no second
# setting for the same directory. Each line is a JSON object; a line
# carrying BOTH a `sessionId` and a `step`+`outcome` pair is a step-outcome
# record (build.md's own pr-batch-executor `{outcome:"PR_OPENED", ...}`
# shape, generalized to a named `step` so more than that one executor's
# outcomes can be recorded) and is folded into that session's `steps` array
# — every other line (an ordinary transcript message) carries neither field
# and is skipped; not every journal line is a step-outcome record.
# `sessionId` is normalized through `_sg_normalize_session_id` (the
# join-key loader), never hand-rolled. `absent` = no transcript root, no
# matching files, or no step-outcome lines in any of them found (nothing to
# report — the same "legitimately empty" convention as pr_list/worktrees;
# covers the acceptance criterion's "a missing transcript directory is
# absent" as the degenerate case of "nothing found"). `error` = a journal
# line that is not valid JSON at all (a corrupted/truncated transcript).
_sg_read_journal() {
  local root files f line sid outcome nodes malformed=0 by_sid='{}'
  root="${SPEND_TRANSCRIPT_ROOT:-}"
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    _sg_source_result absent '[]' '[]' "no transcript root"
    return 0
  fi
  files="$(find "$root" -type f -name 'agent-*.jsonl' 2>/dev/null | sort)"
  if [ -z "$files" ]; then
    _sg_source_result absent '[]' '[]' "no journal files"
    return 0
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if ! jq -e . >/dev/null 2>&1 <<<"$line"; then
        malformed=1
        break
      fi
      sid="$(jq -r '.sessionId // empty' <<<"$line")"
      [ -n "$sid" ] || continue
      if ! jq -e '((.step // "") != "") and ((.outcome // "") != "")' >/dev/null 2>&1 <<<"$line"; then
        continue
      fi
      sid="$(_sg_normalize_session_id "$sid")"
      outcome="$(jq -c '{step:.step, outcome:.outcome}' <<<"$line")"
      by_sid="$(jq -c --arg sid "$sid" --argjson step "$outcome" \
        '.[$sid] = ((.[$sid] // []) + [$step])' <<<"$by_sid")"
    done < "$f"
    [ "$malformed" -eq 0 ] || break
  done <<<"$files"

  if [ "$malformed" -eq 1 ]; then
    _sg_source_result error '[]' '[]' "malformed journal line"
    return 0
  fi

  nodes="$(jq -c '[ to_entries[] | {type:"Session", id:("Session:"+.key), steps:.value} ]' <<<"$by_sid")"
  if [ "$(jq 'length' <<<"$nodes")" -eq 0 ]; then
    _sg_source_result absent '[]' '[]' ""
  else
    _sg_source_result ok "$nodes" '[]' ""
  fi
}

# --- source 7: tmux (Marker nodes, marked_by edges) -------------------------
# `tmux list-windows -a` for every window's `@claimed_issue` option — the
# SAME per-window marker claim.sh/release.sh write via
# workflows/scripts/board/lib/claim_marker.sh — never a hand-rolled tmux
# query. New seam `_sg_tmux` (mirrors `_sg_git`). Its failure covers BOTH
# "no tmux binary on this host" and "tmux binary present but no server
# running": both read the same way from the caller's side (the command
# simply fails), and the acceptance criterion treats them identically —
# `absent`, never "no claims held". A host that DOES have a reachable
# server but holds zero claims right now is `ok` with an empty node/edge
# list — that zero-claims state must NEVER be reported as `absent`
# (acceptance criterion). `error` = the server answered `list-sessions` but
# a SECOND, independent call (`list-windows`) then failed unexpectedly — a
# genuine tmux-side fault, not an absence. A window's `@claimed_issue`
# value not shaped like `#<N> ...` (claim.sh's own display-string
# convention, claim_marker.sh) carries no issue to attach a `marked_by`
# edge to and is skipped — it is not ours to graph.
_sg_tmux() { tmux "$@"; }

_sg_read_tmux() {
  local raw nodes edges wid disp issue
  if ! _sg_tmux list-sessions >/dev/null 2>&1; then
    _sg_source_result absent '[]' '[]' "no tmux binary or no server"
    return 0
  fi
  if ! raw="$(_sg_tmux list-windows -a -F $'#{window_id}\t#{@claimed_issue}' 2>/dev/null)"; then
    _sg_source_result error '[]' '[]' "tmux list-windows failed"
    return 0
  fi
  nodes='[]'; edges='[]'
  while IFS=$'\t' read -r wid disp; do
    [ -n "$wid" ] || continue
    [ -n "$disp" ] || continue
    case "$disp" in
      "#"[0-9]*) issue="${disp#"#"}"; issue="${issue%%[!0-9]*}" ;;
      *) continue ;;
    esac
    nodes="$(jq -c --arg w "$wid" --arg d "$disp" \
      '. + [{type:"Marker", id:("Marker:"+$w), window:$w, display:$d}]' <<<"$nodes")"
    edges="$(jq -c --arg i "$issue" --arg w "$wid" \
      '. + [{type:"marked_by", from:("Issue:"+$i), to:("Marker:"+$w)}]' <<<"$edges")"
  done <<<"$raw"
  _sg_source_result ok "$nodes" "$edges" ""
}

# --- the extensible reader table (acceptance criterion 1) -------------------
_SG_SOURCES="board board_edges pr_list worktrees plan_notes journal tmux"

# --- assemble one full snapshot (live, always fresh) ------------------------
_sg_build_snapshot() {
  local board="$1" repo built_at r_board r_board_edges r_pr r_wt r_plan r_journal r_tmux
  repo="$(board_repo "$board" 2>/dev/null)" || repo=""
  r_board="$(_sg_read_board "$board")"
  r_board_edges="$(_sg_read_board_edges "$board" "$r_board")"
  r_pr="$(_sg_read_pr_list "$board")"
  r_wt="$(_sg_read_worktrees "$board")"
  r_plan="$(_sg_read_plan_notes "$board")"
  r_journal="$(_sg_read_journal "$board")"
  r_tmux="$(_sg_read_tmux "$board")"
  built_at="$(date +%s)"

  jq -cn \
    --arg board "$board" --arg repo "$repo" --argjson built_at "$built_at" --argjson sv 1 \
    --argjson board_r "$r_board" --argjson board_edges_r "$r_board_edges" \
    --argjson pr_r "$r_pr" --argjson wt_r "$r_wt" \
    --argjson plan_r "$r_plan" --argjson journal_r "$r_journal" --argjson tmux_r "$r_tmux" '
    def src($r): {status: $r.status, detail: $r.detail, n_nodes: ($r.nodes|length), n_edges: ($r.edges|length)};
    {
      schema_version: $sv,
      board: $board,
      repo: $repo,
      built_at: $built_at,
      sources: {
        board: src($board_r),
        board_edges: src($board_edges_r),
        pr_list: src($pr_r),
        worktrees: src($wt_r),
        plan_notes: src($plan_r),
        journal: src($journal_r),
        tmux: src($tmux_r)
      },
      nodes: ($board_r.nodes + $board_edges_r.nodes + $pr_r.nodes + $wt_r.nodes
              + $plan_r.nodes + $journal_r.nodes + $tmux_r.nodes),
      edges: ($board_r.edges + $board_edges_r.edges + $pr_r.edges + $wt_r.edges
              + $plan_r.edges + $journal_r.edges + $tmux_r.edges)
    }'
}

# --- persist through cache.sh (repo-keyed dir, meta.json, temp-then-rename) -
# Reuses cache.sh's own PATH accessors (cache_repo_dir / cache_snapshot_file /
# cache_meta_file) so the on-disk layout is byte-identical in shape to the
# issue-cache store's (repo-keyed directory under $CACHE_STORE_ROOT, a
# meta.json carrying schema_version/repo/last_refresh) — kind=state-graph
# keeps this fully namespace-isolated from the issue-cache kind
# (cache_dirty/cache_clear/cache_stale on one kind never touch the other,
# temperloop#1929). The write itself is NOT `_cache_persist_snapshot` (that
# function is hardwired to the raw-GitHub-issue-list jq transform and to
# kind="issues") — this is our own temp-then-rename writer, mirroring its
# exact discipline: write to a `.tmp.$$` file in the same directory, `mv`
# into place, only then write meta.json.
_sg_persist_snapshot() {
  local board="$1" json="$2" kind="${3:-state-graph}" dir snap meta tmp repo
  dir="$(cache_repo_dir "$board" "$kind")" || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  snap="$(cache_snapshot_file "$board" "$kind")" || return 1
  meta="$(cache_meta_file "$board" "$kind")" || return 1
  tmp="$dir/.snapshot.tmp.$$"
  printf '%s\n' "$json" >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv "$tmp" "$snap" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  repo="$(board_repo "$board" 2>/dev/null)" || repo=""
  jq -nc --arg repo "$repo" --argjson ts "$(date +%s)" --argjson sv 1 \
    '{schema_version:$sv, repo:$repo, last_refresh:$ts}' >"$meta" 2>/dev/null || return 1
}

# --- the read helper: stale-at-read-time transform --------------------------
# `_sg_read_snapshot <board> [kind]`: reads the on-disk snapshot (rc 1, no
# stdout, if none exists yet) and, when its meta.json age is at or past
# `STATE_GRAPH_MAX_AGE_S`, overrides EVERY source's status to "stale" before
# printing (ADR 0033 / acceptance criterion 2) — the recorded ok/absent/error
# status from build time is preserved verbatim when the snapshot is still
# fresh. Used internally by `build` for nothing (build always just wrote a
# fresh-by-definition snapshot) and exists as the seam `state-graph.sh query`
# (temperloop#1919) will call; test_state_graph.sh exercises it directly by
# sourcing this file and seeding a snapshot+meta pair at a controlled age.
_sg_read_snapshot() {
  local board="$1" kind="${2:-state-graph}" snap meta last age now
  snap="$(cache_snapshot_file "$board" "$kind")" || return 1
  meta="$(cache_meta_file "$board" "$kind")" || return 1
  [ -s "$snap" ] || return 1
  last="$(jq -r '.last_refresh // 0' "$meta" 2>/dev/null)"
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  now="$(date +%s)"
  age=$(( now - last ))
  if [ "$age" -ge "${STATE_GRAPH_MAX_AGE_S:-300}" ]; then
    jq -c '.sources |= with_entries(.value.status = "stale")' "$snap"
  else
    cat "$snap"
  fi
}

# --- commands ----------------------------------------------------------------
cmd_build() {
  local board=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) board="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      *) echo "state-graph.sh: build: unknown arg '$1'" >&2; usage; exit 2 ;;
    esac
  done
  [ -n "$board" ] || { echo "state-graph.sh: build requires --board <N>" >&2; usage; exit 2; }

  local snapshot
  snapshot="$(_sg_build_snapshot "$board")"
  _sg_persist_snapshot "$board" "$snapshot" "state-graph" ||
    echo "state-graph.sh: warning: snapshot persist failed for board $board (disk/permission?) — printing unpersisted result" >&2
  printf '%s\n' "$snapshot"
}

cmd_clean() {
  local board=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) board="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      *) echo "state-graph.sh: clean: unknown arg '$1'" >&2; usage; exit 2 ;;
    esac
  done
  [ -n "$board" ] || { echo "state-graph.sh: clean requires --board <N>" >&2; usage; exit 2; }
  cache_clear "$board" "state-graph"
}

# `bench --scale <N> --board <N>`: builds the REAL board's snapshot once (same
# four sources, same seams — no network in tests), then synthesizes a
# snapshot at N times its node/edge count (fabricated Bench-typed nodes, no
# real host names/session ids/paths) and times the persist step, writing the
# synthetic result to its OWN cache kind (state-graph-bench) so a bench run
# never clobbers the real state-graph-kind snapshot for that board.
cmd_bench() {
  local board="" scale=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) board="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --scale) scale="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      *) echo "state-graph.sh: bench: unknown arg '$1'" >&2; usage; exit 2 ;;
    esac
  done
  [ -n "$board" ] || { echo "state-graph.sh: bench requires --board <N>" >&2; usage; exit 2; }
  case "$scale" in
    '' | *[!0-9]*) echo "state-graph.sh: bench requires --scale <N> (positive integer)" >&2; usage; exit 2 ;;
  esac

  local base n0 m0 synth start_ms end_ms elapsed_ms
  base="$(_sg_build_snapshot "$board")"
  n0="$(jq '.nodes|length' <<<"$base")"
  m0="$(jq '.edges|length' <<<"$base")"

  start_ms="$(_sg_now_ms)"
  synth="$(jq -cn --argjson n "$n0" --argjson m "$m0" --argjson scale "$scale" '
    {
      nodes: [ range(0; ($n * $scale)) | {type:"Bench", id:("Bench:"+(.|tostring))} ],
      edges: [ range(0; ($m * $scale)) | {type:"bench_edge", from:("Bench:"+(.|tostring)), to:("Bench:"+(((.+1) % ($n*$scale+1))|tostring))} ]
    }')"
  local snapshot repo built_at
  repo="$(board_repo "$board" 2>/dev/null)" || repo=""
  built_at="$(date +%s)"
  snapshot="$(jq -cn --arg board "$board" --arg repo "$repo" --argjson built_at "$built_at" \
    --argjson scale "$scale" --argjson synth "$synth" --argjson sv 1 '
    {schema_version:$sv, board:$board, repo:$repo, built_at:$built_at, bench_scale:$scale,
     sources: {bench:{status:"ok", detail:"synthetic", n_nodes:($synth.nodes|length), n_edges:($synth.edges|length)}},
     nodes: $synth.nodes, edges: $synth.edges}')"
  _sg_persist_snapshot "$board" "$snapshot" "state-graph-bench" ||
    echo "state-graph.sh: warning: bench snapshot persist failed for board $board" >&2
  end_ms="$(_sg_now_ms)"
  elapsed_ms=$(( end_ms - start_ms ))

  echo "state-graph bench: board=$board scale=$scale nodes=$(jq '.nodes|length' <<<"$synth") edges=$(jq '.edges|length' <<<"$synth") build_ms=$elapsed_ms"
}

# --- dispatch (skipped when sourced for tests) -------------------------------
# Mirrors gate.sh: a test `source`s this file to override the `_board_gh` /
# `_sg_git` seams and call `_sg_read_*` / `cmd_*` / `_sg_read_snapshot`
# directly, so the dispatch must NOT run on source. The guard compares $0 to
# BASH_SOURCE.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ $# -eq 0 ]; then
    usage
    exit 2
  fi
  cmd="$1"; shift
  case "$cmd" in
    build) cmd_build "$@" ;;
    clean) cmd_clean "$@" ;;
    bench) cmd_bench "$@" ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "state-graph.sh: unknown subcommand '$cmd'" >&2
      usage
      exit 2
      ;;
  esac
fi
