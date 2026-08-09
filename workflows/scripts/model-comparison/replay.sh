#!/usr/bin/env bash
#
# replay.sh — replay corpus selection + the isolated replay worktree
# (temperloop#1254, epic #1225 "model comparison harness"). This is the
# FIRST kernel component of the replay half of the model-comparison module
# (ADR 0027: "a new kernel component taking lineage from foundation's
# workflow-eval.sh/judge.py, not a flag bolted onto them" — those files are
# overlay assets absent from a kernel-only install, and their shim-based
# isolation regime is deliberately incompatible with replay's real-remote
# reads).
#
# ── GATE SCOPE — read this before touching anything downstream ─────────────
# This file owns CORPUS SELECTION, ISOLATION, and the SCORED-RECORD SCHEMA
# only. Actual replay EXECUTION (spawning a candidate model inside a
# prepared worktree via candidate-session.sh) and SCORING land in the later
# `replay-execute-and-score` item (temperloop#1258) — the `candidate`/
# `score` sub-objects of the schema `schema` prints below are documented
# placeholders, deliberately unpopulated here.
#
# ── Spike facts this file takes as GIVEN (temperloop#1247, the keystone
#    spike) — see Context/temperloop - replay ground-truth seam.md for the
#    full evidence; every disposition below cites that note, nothing here is
#    re-derived ─────────────────────────────────────────────────────────────
#
#   1. BASE RESOLUTION. The tree a PR's original worker actually saw is the
#      FORK POINT — `git merge-base <merge>^1 <merge>^2` — not
#      `gh pr view --json baseRefOid` (moves when main advances under an
#      open PR) nor `<merge>^1` (a merge-queue-batched sibling's tip). 21 of
#      60 merged PRs measured disagree across the three candidates. A merge
#      commit with anything other than exactly 2 parents (a squash/rebase
#      merge) has no fork point to resolve and is rejected outright.
#      → `resolve-base` below.
#
#   2. DIFF-SCOPE RULE. Partition every changed path between $BASE and $HEAD
#      into N (solution surface — named in the pre-cut issue text, scored),
#      T (test surface — `*/tests/*` or `test_*`, scored on presence+pass
#      never bytes), X (policy churn — CHANGELOG.md/VERSION/Makefile/
#      Plans-archive/*/the config-registry TSVs/kernel-manifest.txt/
#      feature-manifest.txt — neutral, a KERNEL GATE demanded it, not the
#      issue), or R (residue — anything else). Non-empty R containing
#      unnamed CODE is an item-level REJECTION (tier C, "scoring it measures
#      clairvoyance"); R that is unnamed `.md` propagation ONLY (tier B) is
#      scored neutral like X but stays FLAGGED so a downstream reader knows.
#      Measured corpus yield: 24/46 = 52% survive scope closure on this
#      repo's own single-issue merged PRs — "budget ~2x its target size".
#      → `diff-scope` below; `corpus` applies it per PR.
#
#   3. CONTAMINATION TRAPS, with dispositions (spike Acceptance 3):
#        A. squash merges bundling unrelated refactors — mechanically
#           guarded by the parents==2 check (trap 1) AND
#           closingIssuesReferences==1 (trap 2, the guard that actually
#           fires on this repo's own corpus — a PR closing >1 issue bundles
#           >1 contract by construction).
#        B. formatting-only churn — this repo runs shellcheck only, no
#           formatter; mitigated by scoring diffs with
#           `--ignore-all-space --ignore-blank-lines` downstream (a
#           replay-execute-and-score concern; noted here as the record's
#           `template_sha` exists precisely so a later reader can tell).
#        C. gate-version drift AND prompt-template drift — real, and the one
#           that bites: "never mix trees". `corpus` reads the acceptance
#           recap and the prompt template from the item's OWN base commit,
#           never from today's tree, and records `template_sha` on every
#           record.
#        D. post-hoc issue mutation — the original run writes BACK to its
#           own issue (`Clarified (sweep): …`, `Parked by sweep — …`, cull
#           notes). `T_cut = min(first branch commit author date, PR
#           createdAt)`; any issue comment at/after T_cut carrying an
#           escalation-resume marker is a corpus REJECTION (extraSection —
#           a materially larger prompt than a fresh item gets); a post-cut
#           BODY edit (GraphQL `lastEditedAt >= T_cut`) is likewise a
#           REJECTION, "not a shrug" — with NO retrievable prior revision
#           there is nothing honest to replay against. When the GraphQL
#           check itself cannot be verified (no network in a fixture, an API
#           hiccup), the record is FLAGGED `post-cut-edit-unverified`
#           instead of silently accepted or silently dropped.
#
#   4. THE PR BODY IS THE ONLY DURABLE VERBATIM RECORD of the acceptance
#      list the original worker was actually handed — `pr.sh` splices
#      `acceptance_results[].criterion` back into the PR's `## Acceptance`
#      section verbatim (build.md §3c), which the issue body alone does not
#      carry (demo: issue #1199 had 3 bullets, the worker got 5). Extraction
#      splits each bullet at the LAST ` — ` (an evidence tail may itself
#      contain an em-dash — first-occurrence splitting silently truncates a
#      real criterion). temperloop#1267 tracks that this delimiter is
#      unescaped upstream in pr.sh; `corpus` applies the same last-occurrence
#      heuristic pr.sh's own format guarantees the shape of, and FLAGS
#      (never silently accepts) a bullet with more than one embedded em-dash
#      as `criterion-embedded-em-dash` — the exact ambiguous shape that bit
#      the spike's own demo item.
#
# ── The isolation machinery this file REUSES, not reinvents ────────────────
# `worktree-prepare` below calls `workflows/scripts/build/worktree.sh create`
# UNMODIFIED — no new flag was added there (a flag on always-active shared
# build machinery is a permanent seam `rm -rf` of this module cannot remove,
# contradicting ADR 0027's file-shaped uninstallability) — and then REWINDS
# the freshly created worktree to the item's own $BASE with `git reset
# --hard`. This is safe because every artifact `create` drops is untracked
# (`.build-guard` — the PreToolUse write-jail hook's per-worktree arming
# marker; the `.claude/agents/*` review-lens symlinks) and `reset --hard`
# never touches untracked files, so the worktree the worker's Bash/Edit/Write
# calls run inside stays jailed exactly as it is for a live `/build` item.
# Cleanup (`worktree-teardown`) is `worktree.sh remove`, likewise unmodified.
# NOTHING in worktree.sh or the guard hooks is edited by this file.
#
# ── Usage ────────────────────────────────────────────────────────────────
#   replay.sh resolve-base <repo-root> <merge-commit-sha>
#       Fork-point base resolution (spike fact 1). Pure git, no network.
#
#   replay.sh diff-scope <repo-root> <base-sha> <head-sha> [--issue-text-file <path>]
#       The N/T/X/R partition (spike fact 2). Pure git + text, no network.
#
#   replay.sh corpus --repo <owner/repo> [--repo-root <path>] \
#       [--limit N] [--target N] [--out <file>]
#       Real `gh` reads: selects eligible closed-issue + merged-PR pairs
#       from <repo-root>'s (default: cwd) own history, applying spike facts
#       1-4 above, and prints one schema-shaped JSON record per PR (JSON
#       lines) to stdout or --out. `--target N` sizes the default --limit to
#       N * REPLAY_CORPUS_SAMPLE_MULTIPLIER (the spike's own "budget ~2x"
#       yield guidance) when --limit is not given explicitly. Output is
#       ordered eligible-then-flagged-then-rejected, each tier ascending by
#       scored file count — the smaller/tighter (more single-purpose) an
#       eligible PR's N+T footprint, the earlier it sorts, operationalizing
#       "prefer single-purpose PRs" as a concrete ranking signal on top of
#       the closingIssuesReferences==1 / R-residue gates that already reject
#       the broad, multi-concern PRs structurally (spike: "Tier C is
#       dominated by broad refactor/propagation epics").
#
#   replay.sh preflight --corpus-file <path>
#       THE SPEND GATE (temperloop#1256). Reads an already-computed `corpus`
#       JSONL file (never re-invokes `gh` itself — corpus selection and
#       preflight estimation are separate concerns, and this keeps preflight
#       network-free and deterministically testable) and, before any token is
#       spent, prints eligible-N (records with status eligible or
#       flagged-eligible), the batch-cap-bounded planned-N for THIS
#       invocation, the estimated token cost of that batch, and — genuinely
#       CONSUMING workflows/scripts/model-comparison/stats.sh's `mde`
#       primitive, never a second hand-rolled computation of it — whether
#       eligible-N can reach MODEL_COMPARISON_MIN_SAMPLE_N (the inconclusive
#       floor `verdict`/`bootstrap-ci` already enforce) at all. This module
#       states no dollar figure (docs/features/model-comparison.md's "stated
#       cost basis" concept, and pipeline-spend-report.sh's own "no dollar
#       constant exists in this loop" convention): the cost basis reported
#       here is `token_count`, the model-independent unit, not metered
#       dollars. A projected batch whose estimated cost exceeds
#       REPLAY_PREFLIGHT_CEILING_TOKENS, or that lands while
#       workflows/scripts/build/quota-gate.sh reports "pause" (THIS is the
#       explicit-scope quota-gate consult the item requires — never assumed),
#       STOPS here (`stop:true`, non-zero exit) rather than partway through a
#       later execution step. FAILS CLOSED (`CANNOT_EVALUATE`, non-zero) on
#       an absent/unreadable/empty/malformed corpus file, or if the
#       stats.sh mde primitive itself cannot be reached — it never reports a
#       cheap/reachable estimate it did not actually compute. This command
#       does not execute a replay, spawn a candidate model, or score
#       anything — that is replay-execute-and-score (temperloop#1258); it is
#       also never invoked from a scheduled/cron/autonomous entry point
#       (docs/features/model-comparison.md "Inert by design" — ADR 0027):
#       replay batches are operator-initiated only.
#
#   replay.sh worktree-prepare <repo-root> <slug> <base-sha>
#       Create + isolate + rewind the replay worktree (see above). On ANY
#       failure after create, the partially-prepared worktree is torn down
#       before returning non-zero — never left as residue. On success the
#       worktree is left in place (for a later replay-execute-and-score run
#       to use) and printed as {"outcome":"PREPARED",...,"isolation":{...}}.
#
#   replay.sh worktree-teardown <repo-root> <slug>
#       Explicit teardown of a successfully prepared worktree (worktree.sh
#       remove, unmodified).
#
#   replay.sh verify-clean-parent <repo-root>
#       BACKSTOP post-run probe, NOT the primary isolation control — see its
#       own header comment below. Confirms the PARENT checkout carries no
#       uncommitted residue after replay worktree operations.
#
#   replay.sh schema
#       Prints the canonical, versioned, empty-shaped scored-record —
#       REPLAY_RECORD_SCHEMA_VERSION below — so a downstream consumer
#       (replay-execute-and-score, the comparison report) can build against
#       a fixed shape before execution lands.
#
# Every tunable below is a registered setting (workflows/scripts/config/
# setting-registry.tsv), defaulted in workflows/scripts/build/build.config.sh
# — named symbolically here, never re-valued in prose (§ Named-setting
# convention). The `:=` fallbacks immediately below are this file's own
# non-vendoring-caller layer-6 default, matching that registry exactly.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}' >&2; exit 1; }

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SH="$HERE/../build/worktree.sh"
STATS_SH="$HERE/stats.sh"
QUOTA_GATE_SH="$HERE/../build/quota-gate.sh"

# shellcheck source=../build/build.config.sh
[ -f "$HERE/../build/build.config.sh" ] && . "$HERE/../build/build.config.sh"
: "${REPLAY_CORPUS_LIMIT:=60}"
: "${REPLAY_CORPUS_SAMPLE_MULTIPLIER:=2}"
: "${REPLAY_NAMED_PATH_EXTENSIONS:=py sh mjs md tsv json}"
: "${REPLAY_PUSH_DISABLE_SENTINEL:=replay-worktree-push-disabled://no-remote}"
# preflight (temperloop#1256) — the per-comparison spend gate. All four
# named symbolically here, never re-valued in prose (§ Named-setting
# convention); registered in setting-registry.tsv, defaulted in
# build.config.sh.
: "${REPLAY_PREFLIGHT_BATCH_CAP:=40}"
: "${REPLAY_PREFLIGHT_TOKENS_PER_REPLAY:=150000}"
: "${REPLAY_PREFLIGHT_CEILING_TOKENS:=8000000}"
: "${REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS:=50000}"
# Non-vendoring-checkout fallback for a setting this file READS but does not
# OWN (registry row's owning-script is build.config.sh; the literal here is
# a byte-identical duplicate of stats.sh's own default — setting-registry.tsv's
# documented "byte-identical fallback duplicated in more than one consuming
# script" convention, same shape as PIPELINE_OPERATOR's duplicate sites).
: "${MODEL_COMPARISON_MIN_SAMPLE_N:=20}"

# schema_version — a record-format constant, not an operator-tunable setting
# (same non-registry-row shape as allowlist.sh's PA_DISCLOSURE_SCHEMA_VERSION).
REPLAY_RECORD_SCHEMA_VERSION="replay-record-v1"

# shellcheck source=../lib/portable-timeout.sh
[ -f "$HERE/../lib/portable-timeout.sh" ] && . "$HERE/../lib/portable-timeout.sh"
if ! command -v run_with_timeout >/dev/null 2>&1; then
  # Defensive only — portable-timeout.sh ships alongside this file in every
  # kernel install; this fallback exists so a missing/corrupt copy degrades
  # to an unbounded call rather than a hard "command not found" abort.
  run_with_timeout() { shift; "$@"; }
fi

usage() {
  cat <<'EOF' >&2
usage: replay.sh resolve-base <repo-root> <merge-commit-sha>
       replay.sh diff-scope <repo-root> <base-sha> <head-sha> [--issue-text-file <path>]
       replay.sh corpus --repo <owner/repo> [--repo-root <path>] [--limit N] [--target N] [--out <file>]
       replay.sh preflight --corpus-file <path>
       replay.sh worktree-prepare <repo-root> <slug> <base-sha>
       replay.sh worktree-teardown <repo-root> <slug>
       replay.sh verify-clean-parent <repo-root>
       replay.sh schema
EOF
}

# ── small shared helpers ─────────────────────────────────────────────────

abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# resolve_repo <path> — must exist, be a git work tree, and be the TOPLEVEL
# (mirrors worktree.sh's own resolve_repo — the deterministic
# `<repo-root>.wt/<slug>` path this file's worktree-prepare also computes
# depends on repo-root being the real toplevel, not a subdir).
resolve_repo() {
  local arg="$1" repo top
  repo="$(abs_dir "$arg")" || { printf 'replay.sh: repo-root %s does not exist\n' "$arg" >&2; return 1; }
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || { printf 'replay.sh: repo-root %s is not inside a git work tree\n' "$arg" >&2; return 1; }
  top="$(abs_dir "$top")"
  [ "$repo" = "$top" ] || { printf 'replay.sh: repo-root %s is not a git toplevel (toplevel is %s)\n' "$arg" "$top" >&2; return 1; }
  printf '%s\n' "$top"
}

# validate_slug <slug> — same closed character set as worktree.sh's own
# validate_slug (plan-schema shape); it feeds an rm-rf'able path there too.
validate_slug() {
  case "$1" in
    *[!a-z0-9-]*|"") printf 'replay.sh: slug %s invalid — must match [a-z0-9-]+\n' "$1" >&2; return 1 ;;
  esac
  return 0
}

# need_operand <flag> <remaining-arg-count> — guards every `--flag value`
# parse loop below against the trailing-flag-with-no-value shift-2-silently-
# no-ops-under-no-set-e trap: the caller MUST check this before shifting.
need_operand() {
  [ "$2" -ge 2 ] && return 0
  printf 'replay.sh: %s requires a value\n' "$1" >&2
  return 2
}

# json_arr <arg>... — a bash array of strings -> a compact JSON array.
# Zero-arg call (an empty bucket) prints [] without invoking jq on empty
# stdin, matching the "${arr[@]+"${arr[@]}"}" empty-array-safe call sites
# below.
json_arr() {
  if [ "$#" -eq 0 ]; then printf '[]'; return 0; fi
  printf '%s\n' "$@" | jq -R . | jq -cs .
}

# ── diff-scope's fixed bucket definitions (spike fact 2) — structural to
#    the algorithm itself, not an operator override point, so these stay
#    code rather than a setting-registry row (mirrors the registry's own
#    "Inclusion rule" exclusion for computed/structural values). ──────────

is_test_path() {
  case "$1" in
    */tests/*|test_*|*/test_*) return 0 ;;
    *) return 1 ;;
  esac
}

is_policy_churn_path() {
  case "$1" in
    CHANGELOG.md|VERSION|Makefile) return 0 ;;
    Plans-archive/*) return 0 ;;
    workflows/scripts/config/*-registry.tsv) return 0 ;;
    workflows/scripts/config/gate-paths.tsv) return 0 ;;
    workflows/scripts/kernel/kernel-manifest.txt) return 0 ;;
    docs/features/feature-manifest.txt) return 0 ;;
    *) return 1 ;;
  esac
}

# ── resolve-base (spike fact 1) ──────────────────────────────────────────

cmd_resolve_base() {
  local repo="$1" mc="$2" np base head_sha
  repo="$(resolve_repo "$repo")" || return 1

  if ! git -C "$repo" cat-file -e "$mc" 2>/dev/null; then
    jq -cn --arg mc "$mc" '{outcome:"ERROR",error:("merge commit not found: " + $mc)}'
    return 1
  fi

  np="$(git -C "$repo" cat-file -p "$mc" 2>/dev/null | awk '/^parent/{c++} /^author/{exit} END{print c+0}')"
  if [ "${np:-0}" -ne 2 ]; then
    jq -cn --argjson parents "${np:-0}" \
      '{outcome:"REJECTED",reason:"squash-or-rebase-merge",parents:$parents}'
    return 0
  fi

  base="$(git -C "$repo" merge-base "${mc}^1" "${mc}^2" 2>/dev/null)"
  if [ -z "$base" ]; then
    jq -cn '{outcome:"ERROR",error:"merge-base resolution failed"}'
    return 1
  fi
  head_sha="$(git -C "$repo" rev-parse "${mc}^2" 2>/dev/null)"
  if [ -z "$head_sha" ]; then
    jq -cn '{outcome:"ERROR",error:"could not resolve second parent"}'
    return 1
  fi

  jq -cn --arg base "$base" --arg head "$head_sha" --argjson parents 2 \
    '{outcome:"BASE_RESOLVED",base:$base,head:$head,parents:$parents}'
}

# ── diff-scope (spike fact 2) ────────────────────────────────────────────

cmd_diff_scope() {
  local repo="$1" base="$2" head="$3"; shift 3
  local issue_text_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue-text-file) need_operand --issue-text-file "$#" || return 2; issue_text_file="$2"; shift 2 ;;
      *) printf 'replay.sh diff-scope: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done
  repo="$(resolve_repo "$repo")" || return 1

  # Fail CLOSED on an unresolvable base/head — without this, `git diff
  # --name-only` on a bad rev silently prints nothing (stderr suppressed
  # below), every bucket comes back empty, and the function fell through to
  # {"outcome":"SCOPED","status":"eligible",...} at exit 0: a false "clean
  # scope" verdict for input it never actually read. Same shape as the
  # sibling validator that printed OK when it could not read its input.
  if ! git -C "$repo" cat-file -e "${base}^{commit}" 2>/dev/null; then
    jq -cn --arg b "$base" '{outcome:"ERROR",error:("base commit not found: " + $b)}'
    return 1
  fi
  if ! git -C "$repo" cat-file -e "${head}^{commit}" 2>/dev/null; then
    jq -cn --arg h "$head" '{outcome:"ERROR",error:("head commit not found: " + $h)}'
    return 1
  fi

  local ext_alt named_regex
  ext_alt="$(printf '%s' "$REPLAY_NAMED_PATH_EXTENSIONS" | tr ' ' '|')"
  named_regex="[A-Za-z0-9_./-]+\\.(${ext_alt})"

  local -a named_candidates=()
  if [ -n "$issue_text_file" ] && [ -f "$issue_text_file" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if git -C "$repo" cat-file -e "${base}:${p}" 2>/dev/null; then
        named_candidates+=("$p")
      fi
    done < <(grep -oE "$named_regex" "$issue_text_file" 2>/dev/null | sort -u)
  fi

  local -a n_bucket=() t_bucket=() x_bucket=() r_bucket=() r_md=() r_code=()
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    local is_named=0 f
    for f in ${named_candidates[@]+"${named_candidates[@]}"}; do
      [ "$f" = "$p" ] && { is_named=1; break; }
    done
    if [ "$is_named" -eq 1 ]; then
      n_bucket+=("$p")
    elif is_test_path "$p"; then
      t_bucket+=("$p")
    elif is_policy_churn_path "$p"; then
      x_bucket+=("$p")
    else
      r_bucket+=("$p")
      case "$p" in
        *.md) r_md+=("$p") ;;
        *) r_code+=("$p") ;;
      esac
    fi
  done < <(git -C "$repo" diff --name-only "$base" "$head" 2>/dev/null)

  local status="eligible" reason="" flags_json="[]"
  if [ "${#r_code[@]}" -gt 0 ]; then
    status="rejected"; reason="unnamed-code-residue"
  elif [ "${#r_md[@]}" -gt 0 ]; then
    status="flagged-eligible"; flags_json='["residue-md-only"]'
  fi

  jq -cn \
    --arg status "$status" --arg reason "$reason" --argjson flags "$flags_json" \
    --argjson N "$(json_arr "${n_bucket[@]+"${n_bucket[@]}"}")" \
    --argjson T "$(json_arr "${t_bucket[@]+"${t_bucket[@]}"}")" \
    --argjson X "$(json_arr "${x_bucket[@]+"${x_bucket[@]}"}")" \
    --argjson R "$(json_arr "${r_bucket[@]+"${r_bucket[@]}"}")" \
    '{outcome:"SCOPED",status:$status,reason:$reason,flags:$flags,buckets:{N:$N,T:$T,X:$X,R:$R}}'
}

# ── acceptance-recap extraction (spike fact 4) ───────────────────────────

# extract_acceptance <pr-body-file> — one criterion per line, `## Acceptance`
# section only, checkbox prefix stripped.
extract_acceptance() {
  awk '/^## Acceptance$/{f=1;next} /^## /{f=0} f && /^- \[/' "$1" \
    | sed -E 's/^- \[[x ]\] //'
}

# strip_at_last_emdash <line> — the last-` — `-occurrence split
# (temperloop#1267's documented workaround: pr.sh's own recap delimiter is
# unescaped upstream). Falls back to the raw line if perl is unavailable.
strip_at_last_emdash() {
  if command -v perl >/dev/null 2>&1; then
    printf '%s' "$1" | perl -CSD -pe 's/^(.*) \x{2014} .*$/$1/' 2>/dev/null && return 0
  fi
  printf '%s' "$1"
}

# ── corpus (real `gh` reads; applies spike facts 1-4) ────────────────────

cmd_corpus() {
  local repo_root="." owner_repo="" limit="" target="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) need_operand --repo "$#" || return 2; owner_repo="$2"; shift 2 ;;
      --repo-root) need_operand --repo-root "$#" || return 2; repo_root="$2"; shift 2 ;;
      --limit) need_operand --limit "$#" || return 2; limit="$2"; shift 2 ;;
      --target) need_operand --target "$#" || return 2; target="$2"; shift 2 ;;
      --out) need_operand --out "$#" || return 2; out="$2"; shift 2 ;;
      *) printf 'replay.sh corpus: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done
  [ -n "$owner_repo" ] || { printf 'replay.sh corpus: --repo <owner/repo> is required\n' >&2; return 2; }
  repo_root="$(resolve_repo "$repo_root")" || return 1

  if [ -z "$limit" ]; then
    if [ -n "$target" ]; then
      limit=$(( target * REPLAY_CORPUS_SAMPLE_MULTIPLIER ))
    else
      limit="$REPLAY_CORPUS_LIMIT"
    fi
  fi

  local owner="${owner_repo%%/*}" name="${owner_repo#*/}"

  local pr_list
  pr_list="$(run_with_timeout 30 gh pr list -R "$owner_repo" --state merged --limit "$limit" \
    --json number,mergeCommit,closingIssuesReferences,title,url,createdAt 2>/dev/null)"
  if [ -z "$pr_list" ]; then
    jq -cn '{outcome:"ERROR",error:"gh pr list returned no data"}' >&2
    return 1
  fi

  # empty_record <pr#> <issue-or-empty> <status> <reason> — one shared
  # constructor so every emission path (rejected at any gate, eligible,
  # flagged-eligible) produces the SAME schema shape.
  emit_record() {
    local pr="$1" issue="$2" status="$3" reason="$4" flags="$5" buckets="$6" \
          merge_commit="$7" base="$8" head="$9" title="${10}" scope="${11}" \
          acceptance="${12}" template_sha="${13}" file_count="${14}"
    jq -cn \
      --arg sv "$REPLAY_RECORD_SCHEMA_VERSION" --argjson pr "$pr" --arg issue "$issue" \
      --arg status "$status" --arg reason "$reason" --argjson flags "$flags" \
      --argjson buckets "$buckets" --arg merge_commit "$merge_commit" \
      --arg base "$base" --arg head "$head" --arg title "$title" --arg scope "$scope" \
      --argjson acceptance "$acceptance" --arg template_sha "$template_sha" \
      --argjson file_count "$file_count" \
      '{schema_version:$sv, pr:$pr, issue:(if $issue=="" then null else $issue end),
        merge_commit:(if $merge_commit=="" then null else $merge_commit end),
        base:(if $base=="" then null else $base end), head:(if $head=="" then null else $head end),
        title:$title, scope:$scope, acceptance:$acceptance, notes:"",
        status:$status, reject_reason:$reason, flags:$flags, buckets:$buckets,
        template_sha:(if $template_sha=="" then null else $template_sha end),
        file_count:$file_count,
        worktree:{path:null,branch:null,prepared_at:null},
        candidate:{provider:null,model:null,diff_ref:null},
        score:{verdict:null,acceptance_results:null,gate_result:null}}'
  }
  empty_buckets='{"N":[],"T":[],"X":[],"R":[]}'

  local records_tmp; records_tmp="$(mktemp "${TMPDIR:-/tmp}/replay-corpus.XXXXXX")"

  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    local num mc_oid cir_len title issue_num
    num="$(jq -r '.number // empty' <<<"$pr")"
    [ -n "$num" ] || continue
    mc_oid="$(jq -r '.mergeCommit.oid // empty' <<<"$pr")"
    cir_len="$(jq -r '(.closingIssuesReferences // []) | length' <<<"$pr")"
    title="$(jq -r '.title // empty' <<<"$pr")"

    if [ -z "$mc_oid" ]; then
      emit_record "$num" "" rejected no-merge-commit '[]' "$empty_buckets" "" "" "" "$title" "" '[]' "" null >>"$records_tmp"
      continue
    fi
    if [ "$cir_len" -ne 1 ]; then
      emit_record "$num" "" rejected multi-or-zero-issue-pr '[]' "$empty_buckets" "$mc_oid" "" "" "$title" "" '[]' "" null >>"$records_tmp"
      continue
    fi
    issue_num="$(jq -r '.closingIssuesReferences[0].number' <<<"$pr")"

    local base_out base_outcome
    base_out="$(cmd_resolve_base "$repo_root" "$mc_oid")"
    base_outcome="$(jq -r '.outcome' <<<"$base_out" 2>/dev/null)"
    if [ "$base_outcome" != "BASE_RESOLVED" ]; then
      local br; br="$(jq -r '.reason // "base-resolution-failed"' <<<"$base_out" 2>/dev/null)"
      emit_record "$num" "#$issue_num" rejected "$br" '[]' "$empty_buckets" "$mc_oid" "" "" "$title" "" '[]' "" null >>"$records_tmp"
      continue
    fi
    local base_sha head_sha
    base_sha="$(jq -r .base <<<"$base_out")"
    head_sha="$(jq -r .head <<<"$base_out")"

    local pr_view issue_view
    pr_view="$(run_with_timeout 30 gh pr view "$num" -R "$owner_repo" --json body,title,baseRefName,createdAt 2>/dev/null)"
    issue_view="$(run_with_timeout 30 gh issue view "$issue_num" -R "$owner_repo" --json body,comments,createdAt,title 2>/dev/null)"

    local issue_body_file pr_body_file
    issue_body_file="$(mktemp "${TMPDIR:-/tmp}/replay-issue.XXXXXX")"
    pr_body_file="$(mktemp "${TMPDIR:-/tmp}/replay-pr.XXXXXX")"
    jq -r '.body // empty' <<<"$issue_view" >"$issue_body_file" 2>/dev/null
    jq -r '.body // empty' <<<"$pr_view" >"$pr_body_file" 2>/dev/null

    local scope_out scope_status
    scope_out="$(cmd_diff_scope "$repo_root" "$base_sha" "$head_sha" --issue-text-file "$issue_body_file")"
    scope_status="$(jq -r .status <<<"$scope_out" 2>/dev/null)"
    if [ "$scope_status" = "rejected" ]; then
      local sr; sr="$(jq -r .reason <<<"$scope_out")"
      emit_record "$num" "#$issue_num" rejected "$sr" '[]' "$(jq -c .buckets <<<"$scope_out")" \
        "$mc_oid" "$base_sha" "$head_sha" "$title" "" '[]' "" null >>"$records_tmp"
      rm -f "$issue_body_file" "$pr_body_file"
      continue
    fi
    local flags; flags="$(jq -c .flags <<<"$scope_out")"

    # Trap D — post-hoc issue mutation. T_cut = min(first branch commit
    # author date, PR createdAt).
    local fbc pr_created t_cut
    fbc="$(git -C "$repo_root" log --reverse --format=%aI "${base_sha}..${head_sha}" 2>/dev/null | head -1)"
    pr_created="$(jq -r '.createdAt // empty' <<<"$pr_view")"
    t_cut="$fbc"
    if [ -n "$pr_created" ] && { [ -z "$t_cut" ] || [ "$pr_created" \< "$t_cut" ]; }; then
      t_cut="$pr_created"
    fi

    local escalated=0
    if [ -n "$t_cut" ]; then
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        local c_created c_body
        c_created="$(jq -r '.createdAt // empty' <<<"$c")"
        c_body="$(jq -r '.body // empty' <<<"$c")"
        if [ -n "$c_created" ] && [ "$c_created" \< "$t_cut" ]; then
          continue  # strictly pre-cut — not the resume signal
        fi
        if printf '%s' "$c_body" | grep -E 'Parked by (/?sweep|/?fix|/?triage)|design-fork' >/dev/null; then
          escalated=1
        fi
      done < <(jq -c '(.comments // [])[]' <<<"$issue_view" 2>/dev/null)
    fi
    if [ "$escalated" -eq 1 ]; then
      emit_record "$num" "#$issue_num" rejected escalation-resume-at-or-after-cut '[]' \
        "$(jq -c .buckets <<<"$scope_out")" "$mc_oid" "$base_sha" "$head_sha" "$title" "" '[]' "" null >>"$records_tmp"
      rm -f "$issue_body_file" "$pr_body_file"
      continue
    fi

    # Trap D, second half — a post-cut BODY edit. Best-effort GraphQL probe;
    # an unverifiable result FLAGS rather than silently accepting or
    # silently dropping the item (never a shrug either direction).
    local gql last_edited
    # shellcheck disable=SC2016  # the $owner/$name/$number are GraphQL query
    # variables (literal text gh substitutes via -F), not shell expansions.
    gql="$(run_with_timeout 15 gh api graphql \
      -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){lastEditedAt}}}' \
      -F owner="$owner" -F name="$name" -F number="$issue_num" 2>/dev/null)"
    if [ -n "$gql" ]; then
      last_edited="$(jq -r '.data.repository.issue.lastEditedAt // empty' <<<"$gql" 2>/dev/null)"
      if [ -n "$last_edited" ] && [ -n "$t_cut" ] && ! [ "$last_edited" \< "$t_cut" ]; then
        emit_record "$num" "#$issue_num" rejected post-cut-issue-body-edit '[]' \
          "$(jq -c .buckets <<<"$scope_out")" "$mc_oid" "$base_sha" "$head_sha" "$title" "" '[]' "" null >>"$records_tmp"
        rm -f "$issue_body_file" "$pr_body_file"
        continue
      fi
    else
      flags="$(jq -c '. + ["post-cut-edit-unverified"]' <<<"$flags")"
    fi

    # Acceptance recap (spike fact 4) — last-em-dash split, and a
    # multi-em-dash bullet is FLAGGED (the exact ambiguous shape the spike's
    # own demo item hit), never silently trusted.
    local acc_lines em_dash_risk=0 acceptance_json='[]'
    acc_lines="$(extract_acceptance "$pr_body_file")"
    if [ -n "$acc_lines" ]; then
      local -a acc_arr=()
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        local cnt; cnt="$(printf '%s' "$line" | grep -o ' — ' | wc -l | tr -d ' ')"
        [ "${cnt:-0}" -gt 1 ] && em_dash_risk=1
        acc_arr+=("$(strip_at_last_emdash "$line")")
      done <<<"$acc_lines"
      acceptance_json="$(json_arr "${acc_arr[@]+"${acc_arr[@]}"}")"
    fi
    [ "$em_dash_risk" -eq 1 ] && flags="$(jq -c '. + ["criterion-embedded-em-dash"]' <<<"$flags")"

    local template_sha file_count issue_title
    template_sha="$(git -C "$repo_root" rev-parse "${base_sha}:claude/workflows/build-level.mjs" 2>/dev/null)"
    file_count=$(( $(jq '.buckets.N | length' <<<"$scope_out") + $(jq '.buckets.T | length' <<<"$scope_out") ))
    issue_title="$(jq -r '.title // empty' <<<"$issue_view")"

    emit_record "$num" "#$issue_num" "$scope_status" "" "$flags" "$(jq -c .buckets <<<"$scope_out")" \
      "$mc_oid" "$base_sha" "$head_sha" "$title" "$issue_title" "$acceptance_json" "$template_sha" "$file_count" >>"$records_tmp"

    rm -f "$issue_body_file" "$pr_body_file"
  done < <(jq -c '.[]' <<<"$pr_list")

  # Ranking: eligible, then flagged-eligible, then rejected — each tier
  # ascending by scored file count (null/absent sorts last within its tier),
  # operationalizing "prefer single-purpose PRs" (see the header comment).
  local sort_filter='
    sort_by(
      (if .status=="eligible" then 0 elif .status=="flagged-eligible" then 1 else 2 end),
      (.file_count // 999999)
    ) | .[]'
  if [ -n "$out" ]; then
    jq -c "$sort_filter" -s <"$records_tmp" >"$out" 2>/dev/null
  else
    jq -c "$sort_filter" -s <"$records_tmp" 2>/dev/null
  fi
  rm -f "$records_tmp"
}

# ── preflight (temperloop#1256) — the per-comparison spend gate ─────────

# preflight_cannot_evaluate <error-message> — the ONE emission path for every
# fail-closed case (absent/unreadable/empty/malformed corpus file, or the
# stats.sh mde primitive unreachable). Every caller MUST follow this with
# `return 1` — this helper only prints, it never returns non-zero itself,
# so a caller that forgets the `return 1` would silently fall through to a
# false "eligible" verdict for input it never actually read (the exact
# fail-open shape diff-scope's own header warns about).
preflight_cannot_evaluate() {
  jq -cn --arg e "$1" '{outcome:"CANNOT_EVALUATE",error:$e}'
}

cmd_preflight() {
  local corpus_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --corpus-file) need_operand --corpus-file "$#" || return 2; corpus_file="$2"; shift 2 ;;
      *) printf 'replay.sh preflight: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done

  if [ -z "$corpus_file" ]; then
    preflight_cannot_evaluate "no --corpus-file given"
    return 1
  fi
  # `-f` rejects a missing path AND a directory/non-regular-file (the
  # portable stand-in for "unreadable" that doesn't depend on OS permission
  # bits, which don't reliably deny access to a root-run test process).
  if [ ! -f "$corpus_file" ] || [ ! -r "$corpus_file" ]; then
    preflight_cannot_evaluate "corpus file not found or not a readable regular file: $corpus_file"
    return 1
  fi

  local n_lines
  n_lines="$(grep -c . "$corpus_file" 2>/dev/null || true)"
  case "$n_lines" in ''|*[!0-9]*) n_lines=0 ;; esac
  if [ "$n_lines" -eq 0 ]; then
    preflight_cannot_evaluate "corpus file has no records: $corpus_file"
    return 1
  fi

  # Every line must parse as a JSON object carrying a `status` — a single
  # unparseable/malformed line CANNOT-EVALUATEs the whole file rather than
  # being silently skipped, which would under-report eligible-N off input
  # this command never actually finished reading (same fail-closed shape as
  # diff-scope's own base/head existence check).
  local eligible_n=0 line status
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! jq -e 'type=="object" and has("status")' >/dev/null 2>&1 <<<"$line"; then
      preflight_cannot_evaluate "malformed corpus record (not a JSON object with a status field): $line"
      return 1
    fi
    status="$(jq -r .status <<<"$line" 2>/dev/null)"
    case "$status" in
      eligible|flagged-eligible) eligible_n=$((eligible_n + 1)) ;;
    esac
  done <"$corpus_file"

  # Batch cap: bounds replays for THIS invocation only — eligible_n (the
  # corpus's real pool) stays the basis for the significance-reachability
  # check below, since a corpus larger than one invocation's cap could still
  # be spent across more than one invocation.
  local planned_n="$eligible_n" batch_cap_applied=false
  if [ "$planned_n" -gt "$REPLAY_PREFLIGHT_BATCH_CAP" ]; then
    planned_n="$REPLAY_PREFLIGHT_BATCH_CAP"
    batch_cap_applied=true
  fi

  local est_tokens=$(( planned_n * REPLAY_PREFLIGHT_TOKENS_PER_REPLAY ))
  local ceiling_exceeded=false
  [ "$est_tokens" -gt "$REPLAY_PREFLIGHT_CEILING_TOKENS" ] && ceiling_exceeded=true

  local reachable=false reachable_reason=""
  if [ "$eligible_n" -ge "$MODEL_COMPARISON_MIN_SAMPLE_N" ]; then
    reachable=true
  else
    reachable_reason="eligible-N ($eligible_n) is below MODEL_COMPARISON_MIN_SAMPLE_N ($MODEL_COMPARISON_MIN_SAMPLE_N) — the verdict would always be inconclusive at this N"
  fi

  # The MDE disclosure — genuinely CONSUMES stats.sh's own `mde` primitive
  # (never a second, hand-rolled computation of it). No real per-replay cost
  # variance exists yet (replay execution is #1258's job), so
  # REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS stands in as a config-named,
  # operator-tunable placeholder pending real historical variance.
  local mde_json="null"
  if [ "$eligible_n" -ge 1 ]; then
    local mde_out mde_rc=0
    mde_out="$(bash "$STATS_SH" mde --n "$eligible_n" --stddev "$REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS" 2>&1)" || mde_rc=$?
    if [ "$mde_rc" -ne 0 ] || ! jq -e . >/dev/null 2>&1 <<<"$mde_out"; then
      preflight_cannot_evaluate "could not reach the stats.sh mde primitive: $mde_out"
      return 1
    fi
    mde_json="$mde_out"
  else
    reachable_reason="eligible-N is 0 — no usable replay candidates in this corpus"
  fi

  # THE QUOTA-GATE CONSULT — explicit scope (temperloop#1256), not assumed.
  # quota-gate.sh is FAIL OPEN by contract (its own header): an "unavailable"
  # verdict here must NOT stop this batch — only an explicit "pause" does.
  local quota_json quota_action
  quota_json="$(bash "$QUOTA_GATE_SH" 2>/dev/null)"
  [ -n "$quota_json" ] && jq -e . >/dev/null 2>&1 <<<"$quota_json" \
    || quota_json='{"action":"unavailable","reason":"quota-gate.sh produced no parseable output"}'
  quota_action="$(jq -r '.action // "unavailable"' <<<"$quota_json" 2>/dev/null)"
  [ -n "$quota_action" ] || quota_action="unavailable"

  local stop=false stop_reason=""
  if [ "$ceiling_exceeded" = "true" ]; then
    stop=true; stop_reason="ceiling_exceeded"
  elif [ "$quota_action" = "pause" ]; then
    stop=true; stop_reason="quota_paused"
  fi

  jq -cn \
    --argjson eligible_n "$eligible_n" --argjson planned_n "$planned_n" \
    --argjson batch_cap "$REPLAY_PREFLIGHT_BATCH_CAP" --argjson batch_cap_applied "$batch_cap_applied" \
    --arg cost_basis "token_count" \
    --argjson tokens_per_replay "$REPLAY_PREFLIGHT_TOKENS_PER_REPLAY" \
    --argjson estimated_total_tokens "$est_tokens" \
    --argjson ceiling_tokens "$REPLAY_PREFLIGHT_CEILING_TOKENS" --argjson ceiling_exceeded "$ceiling_exceeded" \
    --argjson min_sample_n "$MODEL_COMPARISON_MIN_SAMPLE_N" --argjson significance_reachable "$reachable" \
    --arg reachable_reason "$reachable_reason" --argjson mde "$mde_json" \
    --argjson assumed_stddev_tokens "$REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS" \
    --argjson quota "$quota_json" --argjson stop "$stop" --arg stop_reason "$stop_reason" \
    '{outcome:"PREFLIGHT",
      eligible_n:$eligible_n, planned_n:$planned_n,
      batch_cap:$batch_cap, batch_cap_applied:$batch_cap_applied,
      cost_basis:$cost_basis, tokens_per_replay_estimate:$tokens_per_replay,
      estimated_total_tokens:$estimated_total_tokens, estimated_cost:$estimated_total_tokens,
      ceiling_tokens:$ceiling_tokens, ceiling_exceeded:$ceiling_exceeded,
      min_sample_n:$min_sample_n, significance_reachable:$significance_reachable,
      reachable_reason:$reachable_reason, assumed_stddev_tokens:$assumed_stddev_tokens, mde:$mde,
      quota:$quota, stop:$stop, stop_reason:$stop_reason,
      confirmation_required:true}'

  [ "$stop" = "false" ] || return 3
  return 0
}

# ── worktree-prepare / worktree-teardown ─────────────────────────────────

cmd_worktree_prepare() {
  local repo_root="$1" slug="$2" base_sha="$3"
  repo_root="$(resolve_repo "$repo_root")" || return 1
  validate_slug "$slug" || return 1

  local wt_path="${repo_root}.wt/${slug}"
  local branch="build/${slug}"

  # NOTE: stderr is deliberately NOT merged into this capture — worktree.sh
  # create() writes its structured JSON to real stdout (fd 3, see that
  # file's own header) but a diagnostic guard banner to stderr; merging the
  # two here would corrupt the JSON parse below on every run where the
  # banner fires, exactly the failure this comment prevents from recurring.
  local create_out create_outcome
  create_out="$(bash "$WORKTREE_SH" create "$repo_root" "$slug")"
  create_outcome="$(jq -r '.outcome // empty' <<<"$create_out" 2>/dev/null)"
  if [ "$create_outcome" != "CREATED" ]; then
    printf '%s\n' "$create_out"
    # Best-effort cleanup even here: an unparseable create_out is not proof
    # nothing was created (create's own JSON write could itself have failed
    # after the worktree was already added) — never leave possible residue
    # on an early return.
    bash "$WORKTREE_SH" remove "$repo_root" "$slug" >/dev/null 2>&1 || true
    return 1
  fi

  # From here on, ANY failure must tear the worktree back down before this
  # function returns — the mid-run-failure guarantee. `failed`/`fail_reason`
  # accumulate; a single cleanup-then-report exit point at the bottom is
  # what makes "cleaned up on the failure path" true regardless of WHICH
  # step below fails.
  local failed=0 fail_reason=""

  # Property 1 — structurally disable push, scoped to THIS worktree ONLY
  # via git's per-worktree config extension (`extensions.worktreeConfig`).
  # Remotes are ordinarily repo-wide (shared .git/config across every linked
  # worktree); this writes into the worktree-private config.worktree layer
  # instead, which is read-merged on top of the shared config for THIS
  # worktree's git invocations only — the parent checkout's and every OTHER
  # worktree's `origin` push URL is untouched. A `git push` issued from
  # inside this worktree therefore targets an unresolvable sentinel
  # transport rather than the real remote.
  if [ "$failed" -eq 0 ] && ! git -C "$repo_root" config extensions.worktreeConfig true 2>/dev/null; then
    failed=1; fail_reason="could not enable extensions.worktreeConfig"
  fi
  if [ "$failed" -eq 0 ] && ! git -C "$wt_path" config --worktree remote.origin.pushurl "$REPLAY_PUSH_DISABLE_SENTINEL" 2>/dev/null; then
    failed=1; fail_reason="could not set worktree-scoped remote.origin.pushurl"
  fi

  # Property 3 (per-repo-derived scratch path) is structural by
  # construction: $wt_path IS worktree.sh's own deterministic
  # "<repo-root>.wt/<slug>" layout, reused verbatim — nothing here computes
  # a second path.

  # Rewind to the item's OWN base (the fork point — spike fact 1), never
  # origin/<default>. An invalid/unreachable base is the mid-run failure
  # this function's cleanup path exists for.
  if [ "$failed" -eq 0 ] && ! git -C "$wt_path" cat-file -e "$base_sha" 2>/dev/null; then
    failed=1; fail_reason="base sha not found in worktree: $base_sha"
  fi
  if [ "$failed" -eq 0 ] && ! git -C "$wt_path" reset --hard "$base_sha" >/dev/null 2>&1; then
    failed=1; fail_reason="git reset --hard $base_sha failed"
  fi

  if [ "$failed" -eq 1 ]; then
    bash "$WORKTREE_SH" remove "$repo_root" "$slug" >/dev/null 2>&1 || true
    jq -cn --arg e "$fail_reason" '{outcome:"ERROR",error:$e}'
    return 1
  fi

  local pushurl guard
  pushurl="$(git -C "$wt_path" config --worktree --get remote.origin.pushurl 2>/dev/null)"
  guard="$(jq -r '.guard // "UNKNOWN"' <<<"$create_out" 2>/dev/null)"

  jq -cn \
    --arg path "$wt_path" --arg branch "$branch" --arg base "$base_sha" \
    --arg pushurl "$pushurl" --arg sentinel "$REPLAY_PUSH_DISABLE_SENTINEL" --arg guard "$guard" \
    --arg scratch_root "${repo_root}.wt" \
    '{outcome:"PREPARED", path:$path, branch:$branch, base:$base,
      isolation:{no_push_remote:($pushurl==$sentinel), pushurl:$pushurl, guard:$guard, scratch_root:$scratch_root}}'
}

cmd_worktree_teardown() {
  local repo_root="$1" slug="$2"
  repo_root="$(resolve_repo "$repo_root")" || return 1
  bash "$WORKTREE_SH" remove "$repo_root" "$slug"
}

# ── verify-clean-parent — BACKSTOP, not the primary control ─────────────
#
# The primary isolation control is STRUCTURAL and asserted at prepare time,
# independently of any post-run probe: the worktree-scoped push-remote
# disable, the kernel write-jail guard marker worktree.sh's own create drops
# (see that file's header — this is the SAME `.build-guard` mechanism every
# `/build` worker worktree gets), and the deterministic per-repo scratch
# path. This function is a SECOND, after-the-fact line of defense — it
# confirms the parent checkout was not, in fact, dirtied by whatever ran
# inside an isolated replay worktree. It proves nothing on its own about
# WHY the parent stayed clean, and a caller must never treat a clean result
# here as a substitute for the structural checks above.
cmd_verify_clean_parent() {
  local repo_root="$1" dirty
  repo_root="$(resolve_repo "$repo_root")" || return 1
  dirty="$(git -C "$repo_root" status --porcelain 2>/dev/null)"
  if [ -n "$dirty" ]; then
    jq -cn --arg d "$dirty" '{outcome:"DIRTY",detail:$d}'
    return 1
  fi
  jq -cn '{outcome:"CLEAN"}'
}

# ── schema — the versioned scored-record shape downstream consumers build
#    against before replay execution/scoring land (temperloop#1258) ──────
cmd_schema() {
  jq -cn --arg sv "$REPLAY_RECORD_SCHEMA_VERSION" '{
    schema_version: $sv,
    pr: null, issue: null, merge_commit: null, base: null, head: null,
    title: null, scope: null, acceptance: [], notes: "",
    status: null, reject_reason: "", flags: [],
    buckets: {N: [], T: [], X: [], R: []},
    template_sha: null, file_count: null,
    worktree: {path: null, branch: null, prepared_at: null},
    candidate: {provider: null, model: null, diff_ref: null},
    score: {verdict: null, acceptance_results: null, gate_result: null}
  }'
}

# ── dispatch — no while-loop parses the top-level subcommand, so a missing
#    trailing operand here can never shift-2-no-op into a hang (§ testing
#    bar); each subcommand's OWN internal loop (corpus, diff-scope) is
#    itself guarded by need_operand above. ────────────────────────────────
[ $# -ge 1 ] || { usage; exit 2; }
cmd="$1"; shift
case "$cmd" in
  resolve-base)
    [ $# -eq 2 ] || { usage; exit 2; }
    cmd_resolve_base "$1" "$2"
    ;;
  diff-scope)
    [ $# -ge 3 ] || { usage; exit 2; }
    repo_arg="$1"; base_arg="$2"; head_arg="$3"; shift 3
    cmd_diff_scope "$repo_arg" "$base_arg" "$head_arg" "$@"
    ;;
  corpus)
    cmd_corpus "$@"
    ;;
  preflight)
    cmd_preflight "$@"
    ;;
  worktree-prepare)
    [ $# -eq 3 ] || { usage; exit 2; }
    cmd_worktree_prepare "$1" "$2" "$3"
    ;;
  worktree-teardown)
    [ $# -eq 2 ] || { usage; exit 2; }
    cmd_worktree_teardown "$1" "$2"
    ;;
  verify-clean-parent)
    [ $# -eq 1 ] || { usage; exit 2; }
    cmd_verify_clean_parent "$1"
    ;;
  schema)
    cmd_schema
    ;;
  *)
    usage; exit 2
    ;;
esac
