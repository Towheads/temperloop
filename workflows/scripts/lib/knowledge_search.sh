#!/usr/bin/env bash
#
# knowledge_search.sh — SOURCED library defining foundation's knowledge_search
# surface: concept-level (semantic/hybrid) retrieval over the knowledge_store's
# corpus (F#776, Epic A #762 "kernel split: seams in place — ZERO behavior
# change").
#
# Companion to knowledge_store.sh (same directory, document I/O). This file
# adds a SEARCH surface bound to the SAME corpus: ks_search's target is
# always ks_root (knowledge_store.sh) — there is NO independent search-corpus
# path setting. A search index that could point somewhere other than the
# document store would silently drift from it (split-brain guard).
#
# Backend selected by the Phase-0 spike verdict (foundation #776, completed
# 2026-07-02): basic-memory v0.22.1
# (https://github.com/basicmachines-co/basic-memory), run STRICTLY as an
# external CLI subprocess over argv/stdout — never imported or vendored,
# because basic-memory is AGPL-3.0 and this repo is not. See the "AGPL
# boundary" note below and workflows/scripts/lib/tests/test_knowledge_search_agpl_boundary.sh.
#
# See knowledge_store.contract.md's "## knowledge_search" section (appended
# after the existing document-I/O sections, which are owned by a sibling
# item — this file does not touch backend dispatch for ks_read/ks_write/
# ks_append/ks_list) for the full interface spec and the spike verdict's
# required adapter posture (numbered points 1-9), reproduced as inline
# comments next to the code that implements each one below.
#
# This file is SOURCED — it sets no shell options (the caller owns
# set -euo). Depends on: knowledge_store.sh (ks_root — source it first),
# jq (reshaping basic-memory's JSON into this file's JSONL output).
#
# ── Config settings ─────────────────────────────────────────────────────────
#   KNOWLEDGE_SEARCH_BACKEND     backend name, kebab-case. Default:
#                                basic-memory (the only backend this file
#                                implements; the plain-files knowledge_store
#                                backend has no search backend of its own —
#                                see "Obsidian-mode note" in the contract for
#                                how an obsidian-backend store still reaches
#                                this same basic-memory search backend, or
#                                stays on Obsidian's own search_vault_smart
#                                at the agent plane).
#   KNOWLEDGE_SEARCH_BM_HOME     isolated $HOME for the basic-memory
#                                subprocess (point 6: its own
#                                ~/.basic-memory/{config.json,memory.db}
#                                lives here — adapter-owned state, never
#                                Travis's real $HOME). Default:
#                                ${XDG_STATE_HOME:-$HOME/.local/state}/foundation/basic-memory-home
#   KNOWLEDGE_SEARCH_BM_PROJECT  the basic-memory project name bound to
#                                ks_root. Default: foundation-knowledge
#   KNOWLEDGE_SEARCH_BM_VERSION  pinned basic-memory version (point 5) passed
#                                to `uvx --from basic-memory==<version>`.
#                                Default: 0.22.1 (the spike-verdict pin —
#                                upgrades are a deliberate adapter change to
#                                this default, not silent drift).
#   KNOWLEDGE_SEARCH_RERANK      1 = re-rank the backend's candidate set
#                                before returning (default); 0 = return the
#                                backend's own order untouched. See
#                                "## Post-fetch re-rank" below.
#   KNOWLEDGE_SEARCH_RERANK_DEPTH
#                                how many candidates to FETCH from the backend
#                                per query before re-ranking down to the
#                                caller's --limit. Default 20. Internal: the
#                                caller still receives exactly --limit results.
#   KNOWLEDGE_SEARCH_RERANK_LEX_WEIGHT
#                                relative weight of the lexical rank list
#                                against the backend's own rank list in the
#                                rank fusion. Default 1.0 (equal). 0 disables
#                                the lexical contribution without disabling
#                                the deeper fetch.
#   KNOWLEDGE_SEARCH_ABSTAIN     1 = abstain (return the same genuine
#                                zero-result shape a backend-empty query
#                                gets) when the FINAL, post-re-rank result set
#                                would otherwise be answered by a candidate
#                                that clears neither measured floor below; 0
#                                = never abstain via this lever (DEFAULT --
#                                opt-in; see CHANGELOG [Unreleased] and
#                                foundation#1450 for the measured floor this
#                                gates, and why it ships off by default).
#   KNOWLEDGE_SEARCH_ABSTAIN_SCORE_FLOOR
#                                floor on the TOP-RANKED (post-re-rank)
#                                candidate's own backend `.score`. Default
#                                0.72 -- measured on the 213-query
#                                engine-neutral golden-query bench against
#                                the SHIPPED hybrid+rerank surface (see "##
#                                Abstention floor" below).
#   KNOWLEDGE_SEARCH_ABSTAIN_LEX_FLOOR
#                                floor on that same top-ranked candidate's
#                                lexical-coverage feature (the re-rank's own
#                                title/path term-agreement score, `L` below).
#                                Default 0.10. BOTH floors must fail (AND, not
#                                OR) for the candidate to abstain -- neither
#                                alone measurably separates.
#   KNOWLEDGE_SEARCH_BM_PYTHON   pinned CPython version passed to
#                                `uvx --python <version>` (point 5's
#                                companion pin). The bm version pin alone
#                                still let uv resolve whatever interpreter
#                                the host offered; a host that resolved
#                                3.14 hit a from-source maturin/PyO3 build
#                                of litellm (a bm dep with no cp314 wheel)
#                                that fails, surfacing as an opaque
#                                registration failure (temperloop#368,
#                                foundation#1176). Default: 3.13 (newest
#                                CPython with prebuilt wheels for the full
#                                0.22.1 dependency closure — bump together
#                                with KNOWLEDGE_SEARCH_BM_VERSION, never
#                                silently).
#
# NOT a corpus-root setting: ks_search always targets ks_root (knowledge_store.sh)
# — there is no KNOWLEDGE_SEARCH_ROOT or equivalent.

# ── Public interface ────────────────────────────────────────────────────
# ks_search <query> [--limit N]   -> ranked results, JSON Lines on stdout:
#                                    one {"doc_id","title","score","snippet"}
#                                    object per line, already ranked by the
#                                    backend (highest relevance first).
# ks_search_reindex [--full] [--search] [--embeddings]
#                                 -> rebuilds the search backend's index for
#                                    ks_root's corpus. Never runs as a
#                                    background watcher (point 3) — this is
#                                    always an explicit, one-shot call (a
#                                    post-pull hook / cron entry point).
#                                    Flags are forwarded to the backend CLI by
#                                    name (temperloop#888): `--full --search`
#                                    is the full filesystem rescan + FTS
#                                    rebuild WITHOUT the forced full re-embed
#                                    (61s vs. 587s for bare `--full` on a
#                                    977-note store), so a drift-healing
#                                    caller no longer has to reach into the
#                                    private `_ks_bm_run`. An UNRECOGNISED
#                                    argument is rejected with exit 2, never
#                                    silently discarded.
# ks_search_available             -> exit 0 if the selected backend's
#                                    required tooling is present, exit 3
#                                    otherwise. Lets a caller probe before
#                                    calling ks_search if it wants to avoid
#                                    the stderr notice.
#
# Exit codes (both ks_search and ks_search_reindex):
#   0 — success. For ks_search, this includes a legitimate ZERO-result
#       match — an empty JSONL stream on stdout with exit 0 is a real "no
#       matches", never confused with "backend unavailable". On a backend
#       zero-result, ks_search first attempts a ripgrep lexical fallback over
#       the corpus (foundation#950); a fallback hit is emitted in the same
#       JSONL contract with a score of 0 (marking a lexical, not semantic,
#       match) and a one-line stderr notice. Still exit 0 when the fallback
#       also finds nothing (or rg is absent) — a genuine no-match.
#   2 — invalid usage (empty query, an unrecognised ks_search_reindex flag,
#       dispatch to an unregistered backend).
#   3 — backend unavailable ("skipped"): the backend's required subprocess
#       tooling (uvx) is not on PATH. A message beginning
#       "skipped — knowledge_search unavailable" is printed to stderr;
#       NOTHING is ever printed to stdout in this case — legible
#       degradation, never a silent empty result.
#   4 — backend error: the subprocess ran but exited non-zero, or its
#       output could not be parsed as the expected JSON shape.
# Epoch milliseconds, for the read-log OUTCOME field `wall_ms` (foundation#1449).
# Mirrors gh-call-logger.sh's `_now_ms` idiom exactly (same fallback, same
# rationale): prefer perl's Time::HiRes (ms resolution, perl ships on macOS +
# CI); degrade to whole-second precision (×1000) if perl is unavailable —
# coarse but never fatal, and never a reason a search call fails.
_ks_now_ms() {
  local ms
  if ms="$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null)" \
     && [ -n "$ms" ]; then
    printf '%s' "$ms"
  else
    printf '%s000' "$(date +%s 2>/dev/null || echo 0)"
  fi
}

ks_search() {
  local query="${1:-}"
  if [ -z "$query" ]; then
    echo "knowledge_search: usage: ks_search <query> [--limit N]" >&2
    return 2
  fi
  shift || true

  # Read-log telemetry (temperloop#229, OUTCOME fields added by
  # foundation#1449 — see knowledge_store.sh's ks__read_log_emit header for
  # the full field contract): this is "the search entrypoint" the
  # knowledge_store.sh read-log contract names. Emission is deferred to AFTER
  # the dispatch below (outcome fields — result count, top score,
  # rg-fallback, mode, wall-time — are only known once the call completes),
  # gated the same way the pre-#1449 code gated its pre-dispatch emit: on the
  # backend's availability probe (the same "available" op ks_search_available
  # exposes publicly; dispatched directly here, stdout/stderr suppressed for
  # THIS probe only so its "skipped —" notice isn't printed twice) — an
  # unavailable backend (no uvx on PATH) never really searches, so it
  # shouldn't log a search attempt either, and the probe itself is a
  # zero-subprocess `command -v` check, so this gate never depends on PATH
  # carrying anything beyond that.
  local do_log=0
  ks_search__dispatch available >/dev/null 2>/dev/null && do_log=1

  # Dispatch to the backend, capturing stdout so a legitimate ZERO-result
  # (exit 0, empty stream) can trigger a ripgrep fallback over the corpus
  # (foundation#950). A backend error (exit 4) or unavailable backend (exit 3)
  # is NOT masked — its legible-degradation contract (stderr notice, exit code)
  # is preserved: only the exit-0-empty case falls back. Result sets are bounded
  # by --limit, so buffering the happy path in a var is cheap. Timed for the
  # wall_ms outcome field — this measures the BACKEND DISPATCH only (not any
  # rg-fallback below), which is the number worth watching for regression.
  local out rc=0 t0 t1 wall_ms
  t0="$(_ks_now_ms)"
  out="$(ks_search__dispatch search "$query" "$@")" || rc=$?
  t1="$(_ks_now_ms)"
  wall_ms=$(( t1 - t0 ))
  [ "$wall_ms" -ge 0 ] 2>/dev/null || wall_ms=0   # guard against clock skew / fallback rounding

  # Abstention floor (foundation#1450): _ks_bm_rerank emits this ONE sentinel
  # line in place of the normal JSONL stream when every candidate failed the
  # measured floor (KNOWLEDGE_SEARCH_ABSTAIN=1). Detected and consumed HERE,
  # not inside the rerank, because only ks_search knows whether the rg
  # fallback below is allowed to run: the ratified L1 semantics (clause 4)
  # say the fallback stays suppressed whenever the backend returned a
  # non-empty candidate set, and a floor-triggered abstention is exactly
  # that — a POST-re-rank empty, never a backend-empty. So this is checked
  # BEFORE the backend-empty branch below, and clears $out to the genuine
  # empty-result shape without ever letting the sentinel itself leak past
  # this function.
  local abstained=0
  if [ "$rc" -eq 0 ] && [ "$out" = '{"__ks_abstain":true}' ]; then
    abstained=1
    out=""
  fi

  # Backend returned a genuine zero-result. A query class the semantic/hybrid
  # backend ranked to nothing may still have a literal match — try ripgrep so
  # the answer is degraded-but-answered rather than silently empty (foundation#950).
  # Only on a clean rc=0 empty result — a dispatch ERROR (rc 3/4) below is NOT
  # masked by a fallback attempt, exactly as the pre-#1449 code never masked it.
  # A floor-triggered abstention (abstained=1) is NOT a backend-empty (the
  # backend returned candidates; the floor discarded them) so it must NOT
  # fall into this branch either — guarded by `abstained` staying 0 here.
  local rg_fired=0
  if [ "$abstained" -eq 0 ] && [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    out="$(ks_search__rg_fallback "$query" "$@")"
    [ -n "$out" ] && rg_fired=1
  fi

  # Log the OUTCOME regardless of success/error — matching the pre-#1449
  # gate's count semantics exactly (it logged once per available-gated call,
  # independent of what the dispatch below returned): an errored dispatch is
  # itself a countable outcome (a real backend failure on a real query), not
  # something to drop from the tally just because it has no result set.
  if [ "$do_log" -eq 1 ]; then
    local result_count top_score mode
    if [ "$rc" -ne 0 ]; then
      # Dispatch errored (3=unavailable mid-flight, 4=backend error) — no
      # result set to describe; name the failure in `mode` instead of
      # guessing a result shape.
      result_count="-"
      top_score="-"
      mode="error:${rc}"
    elif [ -n "$out" ]; then
      result_count="$(printf '%s\n' "$out" | grep -c '^' 2>/dev/null)" || result_count=0
      top_score="$(printf '%s\n' "$out" | head -n1 | jq -r '.score // "-"' 2>/dev/null)" || top_score="-"
      [ -n "$top_score" ] || top_score="-"
    else
      result_count=0
      top_score="-"
    fi
    if [ "$rc" -eq 0 ]; then
      if [ "$rg_fired" -eq 1 ]; then
        # The score:0 lexical fallback answered the query — this OVERRIDES
        # the hybrid/rerank labels below: the caller received a lexical, not
        # a semantic, match (see _ks_bm_rerank's trap 2 on this sentinel).
        mode="rg-fallback"
      else
        # "hybrid" is the only retrieval mode this adapter implements (both
        # backends pin --hybrid / search_type:"hybrid"); "+rerank" reflects
        # whether the post-fetch re-rank (temperloop#1446) actually ran for
        # this query — outcome fields record the POST-re-rank result, so
        # this names what the caller actually received, not just the
        # configured default.
        mode="hybrid"
        [ "${KNOWLEDGE_SEARCH_RERANK:-1}" = "1" ] && mode="hybrid+rerank"
      fi
    fi
    # abstained: "1" when the KNOWLEDGE_SEARCH_ABSTAIN floor fired for this
    # query (foundation#1450), "0" otherwise — the live misfire monitor for
    # the feature (rationale: knowledge_store.sh's ks__read_log_emit header).
    ks__read_log_emit script search "$query" \
      "$result_count" "$top_score" "$abstained" "$rg_fired" "$mode" "$wall_ms"
  fi

  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# Ripgrep lexical fallback over the knowledge_store corpus (foundation#950).
# Fires ONLY when the selected backend returns a legitimate zero-result — a
# fixed-string, case-insensitive rg over the corpus's `*.md` files, reshaped
# into the SAME {doc_id,title,score,snippet} JSONL contract the backend emits so
# a consumer can't tell the two apart (score is a 0 sentinel marking a lexical
# fallback hit vs. the backend's real relevance float). rg's defaults already
# skip hidden dirs (the vault's `.smart-env` embedding store, `.obsidian`), so
# this never bulk-greps them. Fail-open and SILENT on the common no-match path:
# no rg on PATH, no corpus root, or no literal match leaves the empty result
# untouched (a genuine no-match is not an error); only an actual fallback hit
# prints results AND a one-line stderr notice, so ordinary no-match queries add
# no noise. Depends on: ks_root (knowledge_store.sh), rg, jq.
ks_search__rg_fallback() {
  local query="$1"; shift
  local limit=10
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) limit="${2:-10}"; shift 2 ;;
      *) shift ;;
    esac
  done
  command -v rg >/dev/null 2>&1 || return 0     # no rg → the empty result stands
  local root; root="$(ks_root 2>/dev/null)" || return 0
  [ -n "$root" ] && [ -d "$root" ] || return 0
  local hits
  hits="$( ( cd "$root" 2>/dev/null || exit 0
             rg --json -i -F -m1 -g '*.md' -e "$query" -- . 2>/dev/null ) \
    | jq -c 'select(.type=="match")
             | {doc_id: (.data.path.text | ltrimstr("./")),
                title:  (.data.path.text | split("/") | last | rtrimstr(".md")),
                score:  0,
                snippet:(.data.lines.text | rtrimstr("\n"))}' 2>/dev/null \
    | head -n "$limit" )" || true
  # `|| true`: this lib is SOURCED into scripts that own `set -euo pipefail`, and
  # the pipeline exits non-zero on the two fail-open cases — rg exits 1 on the
  # common NO-MATCH path, and `head` closing the pipe early on a many-hit result
  # SIGPIPEs jq (141) under pipefail. Neither is an error here, so the assignment
  # must not be allowed to trip the caller's set -e (foundation#950 shell-review).
  [ -n "$hits" ] || return 0                     # rg found nothing → genuine no-match
  echo "knowledge_search: backend returned no matches; surfacing ripgrep lexical fallback (score=0) over the corpus (foundation#950)" >&2
  printf '%s\n' "$hits"
}

ks_search_reindex() {
  ks_search__dispatch reindex "$@"
}

ks_search_available() {
  ks_search__dispatch available "$@"
}

# ── Backend dispatch (mirrors knowledge_store.sh's ks__dispatch shape) ────
: "${KNOWLEDGE_SEARCH_BACKEND:=basic-memory}"

ks_search__backend_fn() {
  local op="$1" backend="${KNOWLEDGE_SEARCH_BACKEND//-/_}"
  printf '_ks_search_backend_%s_%s\n' "$backend" "$op"
}

ks_search__dispatch() {
  local op="$1"; shift
  local fn; fn="$(ks_search__backend_fn "$op")"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    printf 'knowledge_search: backend "%s" does not implement "%s" (no %s defined)\n' \
      "$KNOWLEDGE_SEARCH_BACKEND" "$op" "$fn" >&2
    return 2
  fi
  "$fn" "$@"
}

# ── basic-memory backend ──────────────────────────────────────────────────
# Every function below either assembles the posture (config/env) or shells
# out to the pinned `uvx --from basic-memory==<version> basic-memory ...`
# CLI. Nothing here imports or vendors any basic-memory source — the ONLY
# way this file talks to basic-memory is via `uvx` as a subprocess (points
# 4 and 5). Confirmed against the real 0.22.1 CLI (network-available
# adapter-authoring session, 2026-07-02): `project add` is idempotent
# (prints "already exists" and exits 0 on a repeat call), a config.json
# holding ONLY the override keys below is merged with the tool's own
# pydantic defaults (no need to restate the full schema), and
# `tool search-notes --hybrid` prints clean JSON on stdout with all
# progress/model-download chatter on stderr.

: "${KNOWLEDGE_SEARCH_BM_PROJECT:=foundation-knowledge}"
: "${KNOWLEDGE_SEARCH_BM_VERSION:=0.22.1}"
: "${KNOWLEDGE_SEARCH_BM_PYTHON:=3.13}"
# Overlay seam (foundation#946): extra `.bmignore` patterns appended to the
# generic upstream base set that _ks_bm_ensure_ignore writes — space- or
# newline-separated BARE segment names. EMPTY by default, so a stranger's install
# excludes only basic-memory's own defaults; an overlay sets this to add
# store-specific exclusions (foundation sets `_inbox` to prune its transient
# Sessions/_inbox drain-queue stubs). Each MUST be a single bare segment (see the
# _ks_bm_ensure_ignore header for why a slash-containing pattern never matches).
: "${KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES:=}"

# point 6: dedicated HOME for the bm subprocess, under XDG_STATE_HOME.
_ks_bm_home() {
  : "${KNOWLEDGE_SEARCH_BM_HOME:=${XDG_STATE_HOME:-$HOME/.local/state}/foundation/basic-memory-home}"
  printf '%s\n' "$KNOWLEDGE_SEARCH_BM_HOME"
}

_ks_bm_config_dir()  { printf '%s/.basic-memory\n' "$(_ks_bm_home)"; }
_ks_bm_config_path() { printf '%s/config.json\n' "$(_ks_bm_config_dir)"; }
# .bmignore lives at basic-memory's OWN resolve_data_dir() (== our isolated config
# dir, since HOME is pinned there — point 6), never inside ks_root / the corpus
# itself. Safe to write even when ks_root is a read-only corpus (foundation#946
# production shadow-read on a live Obsidian vault).
_ks_bm_ignore_path() { printf '%s/.bmignore\n' "$(_ks_bm_config_dir)"; }
# point 6 (cont'd): semantic_embedding_cache_dir pinned inside the isolated
# home, not the machine's shared HF/fastembed cache.
_ks_bm_cache_dir()   { printf '%s/embedding-cache\n' "$(_ks_bm_home)"; }

# point 7: THE embedding-model pin — the single site where the model name is
# authored. Nothing else in this file may spell a model name; the config
# writer and the dimensions derivation below both read it from here.
_ks_bm_embedding_model() { printf 'bge-small-en-v1.5\n'; }

# point 7 (cont'd, temperloop#907): the model's vector dimensionality is
# DERIVED from the pin above, never authored independently. basic-memory
# writes `semantic_embedding_dimensions` into the vector column definition;
# a config that names a model but leaves the dimensions at a mismatched
# value silently produces a zero-embedding index — the index builds, every
# search returns nothing, and no error is raised anywhere. Deriving the
# number from the model name is what makes that unrepresentable: a future
# model flip edits ONE literal (_ks_bm_embedding_model) and this table
# re-derives the matching width, or fails loudly if the new model is not in
# it. Adding a model here means adding its width in the same edit — that
# coupling IS the guard. Widths are the published dimensionality of each
# bge-*-en-v1.5 checkpoint.
_ks_bm_embedding_dimensions() {
  local model
  model="${1:-$(_ks_bm_embedding_model)}"
  case "$model" in
    bge-small-en-v1.5) printf '384\n' ;;
    bge-base-en-v1.5)  printf '768\n' ;;
    bge-large-en-v1.5) printf '1024\n' ;;
    *)
      printf 'ks_search: no embedding dimensions known for model "%s" — add its width to _ks_bm_embedding_dimensions (temperloop#907)\n' \
        "$model" >&2
      return 1
      ;;
  esac
}

# point 1: uvx/basic-memory presence is the sole availability gate — bm
# itself is fetched on demand by uvx, so "installed" here means "uvx is on
# PATH", not "basic-memory is pre-installed". This IS the dispatch target
# for the public "available" op (ks_search_available calls this directly,
# by the `_ks_search_backend_<name>_<op>` naming convention) — exit 0 when
# ready, exit 3 with the "skipped —" stderr notice when not, so a caller
# gets the same legible-degradation signal whether it probes explicitly via
# ks_search_available or hits it implicitly via ks_search/ks_search_reindex.
_ks_search_backend_basic_memory_available() {
  command -v uvx >/dev/null 2>&1 && return 0
  echo "skipped — knowledge_search unavailable: uvx not found on PATH" >&2
  return 3
}

# Writes .bmignore BEFORE the first index (like config.json below) and only if
# absent. Carries basic-memory's OWN upstream default ignore set (ignore_utils.py
# DEFAULT_IGNORE_PATTERNS / create_default_bmignore(), reproduced verbatim so a
# version bump can't silently change what's excluded out from under us), plus any
# store-specific patterns from KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES (the overlay seam,
# empty by default). Lives at _ks_bm_config_dir() — basic-memory's OWN
# resolve_data_dir() under our pinned HOME, never inside ks_root, so it never
# touches the corpus (safe even on a read-only corpus / production shadow-read).
#
# EXTRA-IGNORE patterns MUST each be a single BARE segment name (e.g. `_inbox`, not
# `Sessions/_inbox`): upstream's recursive scan (sync_service.py scan_directory)
# re-bases should_ignore_path on each subdirectory as it descends, so a
# slash-containing pattern never matches below the top level (verified live on
# 0.22.1 — both slash forms indexed the target; the bare-segment form prunes the
# dir the same way the `.obsidian` default does).
# NOTE: no local named `path` here — see the zsh PATH-tie note below (temperloop#40).
_ks_bm_ensure_ignore() {
  local ignore_path pat
  ignore_path="$(_ks_bm_ignore_path)"
  [ -f "$ignore_path" ] && return 0
  mkdir -p "$(_ks_bm_config_dir)" || return 1
  cat > "$ignore_path" <<'BMIGNORE'
# Basic Memory Ignore Patterns (knowledge_search adapter)
# Base set mirrors basic-memory's own upstream default (ignore_utils.py
# DEFAULT_IGNORE_PATTERNS), pinned here rather than left to fall through to
# the library default so a version bump can't silently change it.
.*
*.db
*.db-shm
*.db-wal
config.json
.git
.svn
__pycache__
*.pyc
*.pyo
*.pyd
.pytest_cache
.coverage
*.egg-info
.tox
.mypy_cache
.ruff_cache
.venv
venv
env
.env
node_modules
build
dist
.cache
.idea
.vscode
.DS_Store
Thumbs.db
desktop.ini
.obsidian
*.tmp
*.swp
*.swo
*~
BMIGNORE
  # Append overlay-supplied store-specific patterns (space/newline-separated).
  # Empty by default — a stranger's install carries only the upstream base above.
  if [ -n "${KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES:-}" ]; then
    printf '\n# Store-specific additions (KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES)\n' >> "$ignore_path"
    # Intentional word-splitting on the space/newline-separated pattern list.
    # shellcheck disable=SC2086
    for pat in $KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES; do
      printf '%s\n' "$pat" >> "$ignore_path"
    done
  fi
}

# Writes config.json BEFORE the first index (point 2), and only if absent —
# this state dir is adapter-owned (point 6), so an existing file is trusted
# to already carry our posture; we never clobber a config a prior run wrote.
# Maps every spike-verdict posture point:
#   point 1 — disable_permalinks: true            (+ env var, see _ks_bm_run)
#   point 2 — ensure_frontmatter_on_sync: false, format_on_save: false,
#             update_permalinks_on_move: false, kebab_filenames: false
#   point 3 — sync_changes: false (the watcher is never enabled)
#   point 5 — auto_update: false (upgrades are a deliberate version-pin bump)
#   point 6 — semantic_embedding_cache_dir pinned inside the isolated home
#   point 7 — semantic_embedding_model: bge-small-en-v1.5 (the default —
#             pinned explicitly here so it can never drift to a non-bge
#             model and reintroduce upstream #1023's normalization bug),
#             PLUS the semantic_embedding_dimensions that model requires.
#             Both come from _ks_bm_embedding_model / _ks_bm_embedding_
#             dimensions — one pin, one derivation — so the pair can never
#             be written half-updated (temperloop#907; a mismatched width
#             yields a silent zero-embedding index).
# NOTE: no local here (or anywhere in this file) may be named `path`, `cdpath`,
# `fpath`, or `mailpath`. Under zsh those identifiers are tied to the colon-array
# side of the corresponding uppercase env var (`path` <-> `PATH`), so a
# `local path=…` in a *sourced* function silently rebinds `PATH` for that scope —
# and since these libs are sourced (not executed) and then call `uvx` via
# `_ks_bm_run`, a clobbered `PATH` makes `uvx` unresolvable (exit 127 -> ks exit
# 4). bash treats `path` as an ordinary variable, so this is invisible under
# bash and under CI. Use `cfg_path`/`proj_path`/`doc_path` instead. (temperloop#40)
_ks_bm_ensure_config() {
  local dir cfg_path cache model dims
  dir="$(_ks_bm_config_dir)"
  cfg_path="$(_ks_bm_config_path)"
  cache="$(_ks_bm_cache_dir)"
  # Ensure .bmignore first — BEFORE the config-exists early return, so a store
  # whose config.json already exists (from a prior run) still gets its ignore
  # file written (foundation#946). Both are "write only if absent", so this is
  # idempotent and independent of config.json's presence.
  _ks_bm_ensure_ignore || return 1
  [ -f "$cfg_path" ] && return 0
  # point 7: model and dimensions resolved as a PAIR from the single pin —
  # AFTER the early return, so an existing config still short-circuits
  # untouched. A model with no known width fails here rather than writing a
  # config that would index every note to a zero vector.
  model="$(_ks_bm_embedding_model)"
  dims="$(_ks_bm_embedding_dimensions "$model")" || return 1
  mkdir -p "$dir" "$cache" || return 1
  cat > "$cfg_path" <<JSON
{
  "disable_permalinks": true,
  "ensure_frontmatter_on_sync": false,
  "format_on_save": false,
  "update_permalinks_on_move": false,
  "kebab_filenames": false,
  "sync_changes": false,
  "auto_update": false,
  "semantic_embedding_model": "$model",
  "semantic_embedding_dimensions": $dims,
  "semantic_embedding_cache_dir": "$cache"
}
JSON
}

# Runs the pinned basic-memory CLI as a subprocess (points 4 and 5): isolated
# HOME (point 6) + the belt-and-suspenders env var (point 1, on top of the
# config.json key of the same name) + the version pin (point 5) + the
# interpreter pin (KNOWLEDGE_SEARCH_BM_PYTHON — without it uv resolves the
# host's newest CPython, and a resolution onto a version some bm dependency
# ships no wheel for triggers a from-source native build that can fail; the
# temperloop#368 / foundation#1176 failure mode). This is the
# ONLY place in this file that invokes the `basic-memory` binary, and it is
# always via `uvx --from basic-memory==<pin>` — never a bare `basic-memory`
# that could silently pick up an unpinned/system install, and NEVER the
# `mcp` subcommand (point 4 — sidesteps upstream #1017).
_ks_bm_run() {
  HOME="$(_ks_bm_home)" \
  BASIC_MEMORY_DISABLE_PERMALINKS=true \
  uvx --python "$KNOWLEDGE_SEARCH_BM_PYTHON" --from "basic-memory==${KNOWLEDGE_SEARCH_BM_VERSION}" basic-memory "$@"
}

# point 9: project registration via the CLI only — config-only edits to the
# `projects` map are not honored in 0.22.1. `project add` is idempotent
# (confirmed against the real CLI), so it is safe to call whenever registration
# is needed without a separate "is it already registered" check. Since #996 the
# SEARCH path no longer calls this per query — it registers LAZILY only on a
# project-not-found miss (the ~1.9s re-register was ~45% of search latency,
# F#992); reindex still calls it up front. Idempotency is what makes the
# lazy-on-miss retry safe (first use AND the post-`reset` DB-dropped path).
# On failure the subprocess's own output is surfaced (bounded to its tail)
# instead of swallowed: an opaque "registration failed" with no cause left
# three separate field failures undiagnosable until someone re-ran the
# subprocess by hand (temperloop#368 / foundation#1176 — the actual cause
# was a uvx dependency build, invisible from the adapter's message alone).
_ks_bm_project_add() {
  local name="$1" proj_path="$2" out rc=0   # NOT `path` — see the zsh PATH-tie note above (temperloop#40)
  out="$(_ks_bm_run project add "$name" "$proj_path" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | tail -n 15 >&2
    return "$rc"
  fi
  return 0
}

# ── Post-fetch re-rank (temperloop#1446, epic foundation#1443) ────────────
# THE ranking lever, per the keystone mode-sweep verdict ([[Decisions/foundation
# - mode-sweep verdict (retrieval-mode architecture)]], foundation#1445). That
# sweep measured, on a 768d substrate over 204 labeled queries, that hybrid's
# hit@20 is 0.9461 against a hit@5 of 0.8676 while MRR stays flat across the
# same 4x depth increase: the right document is almost always ALREADY in the
# candidate set the backend returns, just not in the top 5. Depth buys
# coverage, not ranking. So the lever is not a different retrieval mode (every
# alternative — a better single default, intent routing, multi-mode fusion —
# was measured and rejected there); it is to FETCH DEEPER and re-order.
#
# Deliberately THIN: no cross-encoder, no model download, no new dependency —
# jq only, the idiom this file already speaks. Features are computed from the
# candidate's own {doc_id,title} against the query.
#
# ── The three traps this implementation is built around ───────────────────
#  1. SCORES ARE QUERY-RELATIVE, NEVER CORPUS-ABSOLUTE. basic-memory's hybrid
#     fuses as max(v,f) + 0.3*min(v,f) AFTER normalising the lexical half by the
#     maximum within that query's OWN result set (observed range 0.5702-1.2845,
#     exceeding 1.0). A global score threshold is therefore not well-founded and
#     cross-candidate score arithmetic is invalid. So this re-ranker NEVER reads
#     .score: it fuses two RANK lists (reciprocal-rank fusion), which is
#     scale-free by construction.
#  2. THE score:0 rg-FALLBACK SENTINEL MUST NEVER BE REORDERED. score 0 is a
#     PROVENANCE MARKER (a ripgrep lexical hit surfaced when the backend found
#     nothing), not a relevance value — and because lexical modes emit NEGATIVE
#     scores while hybrid emits ~[0.57,1.28], a raw 0 sorts above everything in
#     one context and below everything in another. Structurally, fallback hits
#     can never reach this function (ks_search runs the fallback only AFTER the
#     backend returned an empty set, downstream of every call site here); the
#     explicit sentinel guard below is belt-and-suspenders on top of that
#     separation, and it degrades to identity rather than guessing.
#  3. THE CANDIDATE SET INHERITS HYBRID'S TIE-JITTER (~3.7% of top-5 lists
#     reorder between identical runs). Every ordering step below breaks ties on
#     the backend's own rank, so the re-rank adds no instability of its own.
#
# Contract: this changes the ORDER of results and which k survive. It NEVER
# changes the record shape — each surviving candidate object is passed through
# byte-for-byte as the reshape stage emitted it (the {doc_id,title,score,snippet}
# JSONL contract and the exit-code contract are frozen surfaces).
#
# <query> <k> : reads reshaped JSONL candidates (backend rank order) on stdin,
#               writes the re-ranked top-<k> as JSONL on stdout.
: "${KNOWLEDGE_SEARCH_RERANK:=1}"
: "${KNOWLEDGE_SEARCH_RERANK_DEPTH:=20}"
: "${KNOWLEDGE_SEARCH_RERANK_LEX_WEIGHT:=1.0}"

# ── Abstention floor (foundation#1450, epic foundation#1443) ──────────────
# Below a MEASURED floor on the shipped hybrid+rerank surface, return the
# adapter's existing genuine-zero-result shape instead of confident-looking
# hits on a query the store cannot actually answer.
#
# ── WHY NOT RAW `.score` ALONE, AND WHY NOT THE FUSION SCORE ALONE ────────
# The two obvious single-surface floors were measured and REJECTED:
#  * Raw backend `.score` is query-relative (trap 1 above) -- on the 213-query
#    engine-neutral bench, the 9 correct-abstention queries' top-ranked
#    candidate scored 0.65-0.76, which sits INSIDE genuine hits' own range
#    (0.58-1.28, median 0.79). A floor tight enough to catch most abstention
#    cases drops 30%+ of genuine top-5 hits.
#  * The fusion score `.f` this file computes is RRF-based and dominated by
#    RANK, not relevance: the top-ranked candidate's semantic term alone is a
#    near-constant 1/(rrfk+0) on EVERY query, answerable or not, so `.f`
#    alone carries almost no separating signal (measured: overlaps entirely).
# What DOES separate, measured on that same corpus (two independent runs,
# byte-identical results -- the fused candidate order is deterministic, only
# TIE-BREAKING among near-equal ranks jitters): the CONJUNCTION of the
# top-ranked candidate's raw score AND its own lexical-coverage feature `L`
# (query-term agreement with that candidate's title/path, already computed
# below for the fusion). Neither alone separates; requiring BOTH to be low
# does, because a genuine hit is either a strong semantic match (high score)
# or a strong lexical match (high L) almost without exception in this corpus.
# Measured result at the shipped defaults (0.72 / 0.10): 4/9 correct
# abstentions gained, 0/186 labeled top-5 hits lost -- see CHANGELOG.
#
# ── SMALL-n CAVEAT ─────────────────────────────────────────────────────────
# The corpus carries exactly 9 correct-abstention examples -- the only ones
# that exist -- so these floors are CALIBRATED to, not validated against a
# held-out set of, unanswerable queries. The zero-measured-cost claim (186/186
# preserved, confirmed on two independent runs) is the load-bearing safety
# property; the 4/9 recall figure is a directional floor, not a guarantee for
# novel unanswerable queries. Ships opt-in (KNOWLEDGE_SEARCH_ABSTAIN=0 default)
# pending broader live validation.
#
# ── SCOPE: the main fusion branch only ────────────────────────────────────
# The floor applies ONLY where this function actually computes `L`/`.f` --
# the real-query fusion branch below. It does NOT reach the score-0 sentinel
# bypass (trap 2 -- a fallback set is never a candidate for abstention
# scoring, it already IS the degraded-answer path), the empty-candidate-set
# bypass, or the no-usable-query-terms bypass (no lexical feature exists to
# gate on there); those three edge paths are unchanged.
#
# Signaling: when every candidate fails the gate, this function emits ONE
# sentinel line, `{"__ks_abstain":true}`, in place of the normal JSONL
# stream. ks_search (knowledge_search.sh) is the ONE place that consumes it --
# it converts the sentinel to the genuine empty-result shape, sets the
# `abstained` outcome field, and (per the ratified L1 mode-sweep semantics,
# clause 4) suppresses the score-0 rg lexical fallback, because the backend
# itself returned a non-empty candidate set: an abstention here is a
# POST-re-rank empty, never a backend-empty, and the fallback fires only on
# the latter. The sentinel never reaches a real caller.
: "${KNOWLEDGE_SEARCH_ABSTAIN:=0}"
: "${KNOWLEDGE_SEARCH_ABSTAIN_SCORE_FLOOR:=0.72}"
: "${KNOWLEDGE_SEARCH_ABSTAIN_LEX_FLOOR:=0.10}"

_ks_bm_rerank() {
  local query="$1" k="$2"
  # Disabled -> exact pre-#1446 behavior: the backend's own order, untouched.
  # (The fetch depth also collapses to --limit at the call sites, so "off" is a
  # true no-op, not a truncated deep fetch.)
  if [ "${KNOWLEDGE_SEARCH_RERANK:-1}" != "1" ]; then
    cat
    return 0
  fi
  # Feature weights are deliberately NOT settings: they are ordering constants
  # of the lexical feature, selected on the #1443 bench corpus, and exposing
  # five knobs would be mechanism where one balance knob
  # (KNOWLEDGE_SEARCH_RERANK_LEX_WEIGHT) suffices.
  #   w_title  1.0  query-term coverage of the candidate's TITLE
  #   w_path   0.4  coverage of its full doc_id PATH (directory segments are
  #                 weaker evidence than the title — "Decisions/" matches the
  #                 word "decision" in a way that means nothing)
  #   w_phrase 1.0  bonus when the normalised query appears VERBATIM inside the
  #                 title or path — the near-verbatim recall that IS the
  #                 known-item case ("the board adapter cache split note")
  #   rrfk     10   reciprocal-rank-fusion constant. The textbook 60 is tuned
  #                 for lists of thousands; over a 20-candidate set it flattens
  #                 every rank to near-equal and the fusion stops discriminating.
  jq -cs \
    --arg q "$query" --argjson k "$k" \
    --argjson rrfk 10 --argjson w_title 1.0 --argjson w_path 0.4 \
    --argjson w_phrase 1.0 \
    --argjson w_lex "${KNOWLEDGE_SEARCH_RERANK_LEX_WEIGHT:-1.0}" \
    --argjson abstain "$([ "${KNOWLEDGE_SEARCH_ABSTAIN:-0}" = "1" ] && echo true || echo false)" \
    --argjson abstain_score_floor "${KNOWLEDGE_SEARCH_ABSTAIN_SCORE_FLOOR:-0.72}" \
    --argjson abstain_lex_floor "${KNOWLEDGE_SEARCH_ABSTAIN_LEX_FLOOR:-0.10}" '
    def norm: ascii_downcase | gsub("[^a-z0-9]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
    # Single characters are dropped: they carry no retrieval signal and match
    # far too much. Digits are KEPT (issue refs like 1443 are strong known-item
    # evidence).
    def toks: norm | split(" ") | map(select(length > 1));
    # Deliberately minimal suffix stemmer, applied to BOTH sides so a query term
    # and a title term reach the same root. It exists because the measured
    # known-item misses were dominated by inflection mismatches the exact-token
    # matcher could not see -- "editor"/"Editing", "plan"/"Plans-archive". Each
    # rule is length-guarded so it cannot chew a short word down to a stub, and
    # the plural rule skips a double-s ("process" stays "process"). It is NOT a
    # linguistic stemmer and does not try to be: over-merging costs precision,
    # so only inflections that actually appeared in the corpus are handled.
    def stem:
      (if (test("(ing|ers|ors|ed)$") and (length > 5)) then sub("(ing|ers|ors|ed)$"; "") else . end)
      | (if (test("(er|or)$") and (length > 4)) then sub("(er|or)$"; "") else . end)
      | (if (test("[^s]s$") and (length > 3)) then sub("s$"; "") else . end);
    def stems: toks | map(stem) | unique;
    def stop: ["the","a","an","of","for","in","on","to","and","or","is","are",
               "was","were","be","been","being","what","how","why","where",
               "when","which","who","whom","that","this","these","those","with",
               "do","does","did","doing","my","we","our","us","it","its","by",
               "from","at","as","not","but","if","then","than","so","about",
               "into","out","up","down","over","under","all","any","some","no",
               "can","will","would","should","could","you","your","me","there",
               "their","them","they","have","has","had","get","got","use","used",
               "using","vs","via","re"];

    . as $all
    | ($q | toks | map(stem)) as $qraw
    # A query made ENTIRELY of stopwords keeps its raw terms rather than
    # collapsing to an empty term set (which would silently disable the lever).
    | (($qraw - (stop | map(stem))) as $s
       | (if ($s | length) > 0 then $s else $qraw end) | unique) as $qt
    | ($q | norm) as $qn
    | if ($all | length) == 0 then empty
      # Trap 2: any score-0 provenance marker in the set -> pass through
      # untouched. Never reorder a fallback hit against backend results.
      elif ([ $all[] | select(.score == 0) ] | length) > 0 then $all[0:$k][]
      # No usable query terms -> nothing to re-rank on; keep backend order.
      elif ($qt | length) == 0 then $all[0:$k][]
      else
        [ $all
          | to_entries[]
          | .key as $r
          | .value as $d
          | { r: $r, d: $d,
              tt: (($d.title // "") | stems),
              pt: ((($d.doc_id // "") | sub("\\.md$"; "")) | stems),
              ph: (if ((($d.title // "") | norm) | contains($qn))
                      or ((($d.doc_id // "") | norm) | contains($qn))
                   then 1 else 0 end) }
        ] as $c
        # Per-query term rarity (IDF over THIS query candidate set, never a
        # corpus statistic). A term carried by most candidates -- "subset",
        # "epic", a project name -- discriminates nothing here, while a term in
        # one or two candidates is exactly the known-item signal. Computing it
        # over the returned set keeps it query-relative, which is what trap 1
        # requires; a corpus-wide IDF would also mean a second index to maintain.
        | ($c | length) as $n
        | ( reduce $c[] as $x ({};
              reduce (($x.tt + $x.pt) | unique)[] as $t (.; .[$t] = ((.[$t] // 0) + 1)))
          ) as $df
        | ( [ $qt[] | { key: ., value: (($n / (($df[.] // 0) + 0.5)) | log) } ]
            | from_entries ) as $idf
        # A term absent from every candidate gets the largest weight but can
        # never be matched, so it only ever sits in the denominator. Weights are
        # floored at 0 so a term present in every candidate contributes nothing
        # rather than going negative.
        | ( [ $qt[] | (if ($idf[.] // 0) > 0 then $idf[.] else 0 end) ] | add ) as $wtot
        | [ $c[]
            | . as $x
            | ( [ $qt[] | select(. as $t | $x.tt | index($t))
                        | (if ($idf[.] // 0) > 0 then $idf[.] else 0 end) ] | add // 0 ) as $twt
            | ( [ $qt[] | select(. as $t | $x.pt | index($t))
                        | (if ($idf[.] // 0) > 0 then $idf[.] else 0 end) ] | add // 0 ) as $pwt
            # Fall back to plain coverage when every query term is equally
            # common (wtot == 0), so the feature degrades instead of dividing
            # by zero.
            | (if $wtot > 0
               then { t: ($twt / $wtot), p: ($pwt / $wtot) }
               else { t: (([ $qt[] | select(. as $t | $x.tt | index($t)) ] | length) / ($qt | length)),
                      p: (([ $qt[] | select(. as $t | $x.pt | index($t)) ] | length) / ($qt | length)) }
               end) as $cv
            | { r: $x.r, d: $x.d,
                L: ($w_title * $cv.t + $w_path * $cv.p + $w_phrase * $x.ph) }
          ] as $c2
        # The lexical rank list contains ONLY candidates with real lexical
        # evidence (L > 0). A candidate with zero query-term agreement gets no
        # lexical term at all, rather than a middling rank that would inject
        # noise into the fusion. Ties break on backend rank (trap 3).
        | ([ $c2[] | select(.L > 0) ] | sort_by(-.L, .r)) as $lex
        | ($lex | to_entries
                | map({ key: (.value.r | tostring), value: .key })
                | from_entries) as $lexrank
        | [ $c2[]
            | .f = (1 / ($rrfk + .r)
                    + $w_lex * (($lexrank[(.r | tostring)]) as $lr
                                | if $lr == null then 0 else 1 / ($rrfk + $lr) end))
          ]
        | sort_by(-.f, .r)
        # Abstention floor (foundation#1450): gate on the TOP-ranked (best
        # available) candidate only -- if even the best one fails both
        # floors, none of the rest can pass either (see the comment block
        # above this function for why BOTH must fail, and the measured
        # 0/186-cost result). Off by default ($abstain false) -> untouched.
        | if ($abstain and (length > 0)
              and (.[0].d.score < $abstain_score_floor)
              and (.[0].L < $abstain_lex_floor))
          then {__ks_abstain: true}
          else (.[0:$k][] | .d)
          end
      end
  '
}

# Reshape basic-memory's SearchResponse JSON ({results:[...]}) read on stdin
# into this file's JSONL contract on stdout — one {doc_id,title,score,snippet}
# object per line. The output-shape contract has ONE owner here: the cold
# backend below AND the warm basic-memory-mcp backend (knowledge_search_mcp.sh)
# both pipe through this, so a field rename in a bm version bump can't drift the
# two backends apart (one is production, the other its fail-open fallback).
_ks_bm_reshape_results() {
  jq -c '.results[]? | {doc_id: .file_path, title: .title, score: .score, snippet: (.matched_chunk // .content // "")}'
}

# <query> [--limit N] -> JSONL results on stdout (see exit-code contract on
# ks_search above).
_ks_search_backend_basic_memory_search() {
  local query="$1"; shift
  local limit=10
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) limit="${2:?knowledge_search: --limit requires a value}"; shift 2 ;;
      *) shift ;;
    esac
  done

  _ks_search_backend_basic_memory_available || return $?
  _ks_bm_ensure_config || {
    echo "knowledge_search: could not write basic-memory config" >&2
    return 4
  }

  local root project raw rc=0
  root="$(ks_root)"
  project="$KNOWLEDGE_SEARCH_BM_PROJECT"

  # Post-fetch re-rank (#1446): ask the backend for a DEEPER candidate set than
  # the caller wants, then re-rank down to --limit. Internal by construction —
  # the caller still receives exactly `limit` records. With the re-rank off,
  # depth collapses to limit and this is a no-op.
  local depth="$limit"
  if [ "${KNOWLEDGE_SEARCH_RERANK:-1}" = "1" ] \
     && [ "${KNOWLEDGE_SEARCH_RERANK_DEPTH:-20}" -gt "$limit" ]; then
    depth="${KNOWLEDGE_SEARCH_RERANK_DEPTH:-20}"
  fi

  # foundation#996: try the search FIRST and register the project lazily only on
  # a miss. The per-query `basic-memory project add` is a ~1.9s subprocess (~45%
  # of search latency, F#992) yet a no-op on an already-registered project, so
  # the warm path — the overwhelming common case — now issues ONE subprocess
  # instead of two. `|| rc=$?` (not a bare trailing `$?` read) so a failing
  # command substitution doesn't trip the CALLER's `set -e` before rc is
  # captured — this file is sourced into scripts that own that option.
  raw="$(_ks_bm_run tool search-notes "$query" --hybrid --project "$project" --page-size "$depth" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
    # Miss: the project isn't registered yet (first use), or a `basic-memory
    # reset` dropped the DB while config still lists it (the idempotency caveat
    # the per-query call used to cover). Register (idempotent) and retry ONCE. A
    # genuinely empty result is NOT a miss — basic-memory returns a non-empty
    # `{"results":[]}` envelope for it — so this branch fires only on a real
    # project-not-found / DB-dropped failure, never on a warm no-match query.
    _ks_bm_project_add "$project" "$root" || {
      echo "knowledge_search: basic-memory project registration failed" >&2
      return 4
    }
    rc=0
    # The FIRST search's stderr is suppressed above (a miss there is expected —
    # "project not found" on a cold start). A RETRY failure, by contrast, is a
    # genuine backend error worth diagnosing, so capture its stderr and surface
    # the tail on failure — the same K#368/foundation#1176 discipline
    # `_ks_bm_project_add` applies (an opaque "failed" with no cause is
    # undiagnosable).
    local search_err; search_err="$(mktemp "${TMPDIR:-/tmp}/ks-search-err.XXXXXX" 2>/dev/null)" || search_err=/dev/null
    raw="$(_ks_bm_run tool search-notes "$query" --hybrid --project "$project" --page-size "$depth" 2>"$search_err")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
      echo "knowledge_search: basic-memory search-notes failed (exit $rc)" >&2
      [ "$search_err" != /dev/null ] && { tail -n 15 "$search_err" >&2; rm -f "$search_err"; }
      return 4
    fi
    [ "$search_err" != /dev/null ] && rm -f "$search_err"
  fi

  printf '%s' "$raw" | _ks_bm_reshape_results | _ks_bm_rerank "$query" "$limit" \
    || { echo "knowledge_search: could not parse basic-memory search output" >&2; return 4; }
}

# [--full] [--search] [--embeddings] -> rebuilds the index for ks_root's
# project. Always explicit (point 3) — no caller of this file ever starts a
# watcher. basic-memory's own reindex is resumable on timeout re-invocation
# (contract-documented CI caching guidance), so this is safe to call repeatedly.
#
# Flag passthrough (temperloop#888). Each accepted flag is forwarded to
# `basic-memory reindex` by NAME, from an explicit allowlist — deliberately
# not a blanket `"$@"` forward, because the allowlist is exactly what makes
# the unknown-flag rejection below possible. The shapes that matter, measured
# on a 977-note live store (foundation#1425, 2026-07-28):
#
#   --full --search   full filesystem rescan + FTS rebuild, reconciling the
#                     entity table (re-paths moves, drops deletions) WITHOUT
#                     the forced full re-embed — 61s
#   --full            the above plus the forced full re-embed             — 587s
#
# The first shape is what a scheduled drift-healing reindex wants, and before
# this it was unreachable through the public seam: a caller had to reach into
# the library-PRIVATE `_ks_bm_run` behind a `declare -F` probe to get it.
#
# An UNRECOGNISED argument is now an error (exit 2, the contract's
# invalid-usage code), not silently shifted away. The old loop discarded
# every non-`--full` argument, so a mistyped `ks_search_reindex --full
# --serch` silently degraded to bare `--full` — the 587s forced re-embed
# instead of the 61s shape the caller asked for — with no warning at all.
_ks_search_backend_basic_memory_reindex() {
  local full=0 rebuild_search=0 rebuild_embeddings=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --full)       full=1; shift ;;
      --search)     rebuild_search=1; shift ;;
      --embeddings) rebuild_embeddings=1; shift ;;
      *)
        printf 'knowledge_search: ks_search_reindex: unrecognised argument "%s" (accepted: --full, --search, --embeddings)\n' "$1" >&2
        return 2
        ;;
    esac
  done

  _ks_search_backend_basic_memory_available || return $?
  _ks_bm_ensure_config || {
    echo "knowledge_search: could not write basic-memory config" >&2
    return 4
  }

  local root project
  root="$(ks_root)"
  project="$KNOWLEDGE_SEARCH_BM_PROJECT"
  _ks_bm_project_add "$project" "$root" || {
    echo "knowledge_search: basic-memory project registration failed" >&2
    return 4
  }

  # Assemble the forwarded flags in a fixed order so the emitted command line
  # is deterministic regardless of the order the caller passed them. `--project`
  # is appended last and unconditionally, which also keeps the expansion below
  # safe under `set -u` on bash 3.2 (macOS), where "${empty_array[@]}" is an
  # unbound-variable error rather than an empty expansion.
  local -a bm_args
  bm_args=()
  if [ "$full" -eq 1 ]; then               bm_args+=(--full); fi
  if [ "$rebuild_search" -eq 1 ]; then     bm_args+=(--search); fi
  if [ "$rebuild_embeddings" -eq 1 ]; then bm_args+=(--embeddings); fi
  bm_args+=(--project "$project")

  _ks_bm_run reindex "${bm_args[@]}" || {
    echo "knowledge_search: basic-memory reindex failed" >&2
    return 4
  }
}

# Note: ks_search_available dispatches op "available" straight to
# _ks_search_backend_basic_memory_available (defined above) — same function
# used internally as the availability gate for search/reindex, exposed
# standalone so a caller can probe without touching stdout at all.
