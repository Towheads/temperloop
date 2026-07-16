#!/usr/bin/env bash
#
# build merge-gate mechanics — the deterministic-spine script that owns the
# 4a/4b/4c merge-gate steps of /build (epic #253, spike #245). Reading a
# PR's mergeability/liveness, detecting strict-main, computing the mechanical
# risk verdict over a selected PR set, queuing an --auto merge, nudging a
# still-BEHIND branch, and polling until MERGED are all pure functions of
# observable machine state with a closed outcome set — so they move from prose
# in build.md to code here.
#
# Merge CONSENT is NOT here. gate.sh computes the risk verdict, queues
# (`--auto`, which still requires checks + branch-protection consent to land),
# nudges update-branch, and polls — it never decides *whether* to merge. The
# go/no-go stays an LLM/harness seat. gate.sh ALSO does not write plan-note
# sentinels ([m]/[x]); it returns a structured result and the orchestrator
# drives sentinel writeback through a separate plan.sh.
#
#   gate.sh read <owner>/<repo> <pr>
#       → mergeability/liveness read (re-polls once on UNKNOWN or lone BEHIND)
#   gate.sh strict <owner>/<repo>
#       → strict-main detection (required_status_checks.strict; 404 → non-strict)
#   gate.sh risk <owner>/<repo> <pr> [<pr> ...]
#       → mechanical risk predicate over the selected PR set
#   gate.sh queue <owner>/<repo> <pr> [--strict|--non-strict]
#       → queue the canonical --auto merge incantation
#   gate.sh nudge <owner>/<repo> <pr>
#       → gh pr update-branch for a still-BEHIND PR (the #83 nudge)
#   gate.sh poll <owner>/<repo> <pr> [--interval <secs>] [--timeout <secs>]
#       → poll until MERGED (exit 0 iff state==MERGED); distinct non-zero codes
#         for CONFLICTING/DIRTY vs timeout/stall (guards the #130 premature-close)
#   gate.sh backend <owner>/<repo>
#       → merge-backend SELECTION (temperloop#13): NATIVE (GitHub merge queue)
#         vs MANAGED (no native queue available — a free personal repo can't
#         provision one). This is detection + override ONLY; the managed-merge
#         mechanics themselves are a separate later item.
#   gate.sh managed-merge <owner>/<repo> <pr> [--strict|--non-strict]
#       → per-PR MANAGED-backend merge mechanics (temperloop#13), strict by
#         default: update-branch → SHA-pinned CI re-poll on the UPDATED head →
#         merge → confirmed-MERGED poll; red-after-update ejects (no merge
#         attempted). --non-strict skips the update-branch + re-poll and
#         merges directly. PER-PR MECHANICS ONLY — the whole-set loop,
#         processing order, and stop/continue-past-an-eject policy stay in the
#         orchestrator (build.md); a set-loop here would move merge-order
#         policy into the spine.
#
# Output contract — CLOSED outcome set, one structured JSON line per command
# (the orchestrator branches on `.outcome`, never parses prose):
#   read   → {"outcome":"READ","pr":…,"mergeable":…,"mergeStateStatus":…,
#             "state":…,"checks":…}                                   exit 0
#   strict → {"outcome":"STRICT"|"NON_STRICT"}                        exit 0
#   risk   → {"outcome":"RISKY","reasons":[…]} |
#            {"outcome":"CLEAN_DISJOINT_INDEPENDENT"}                 exit 0
#   queue  → {"outcome":"QUEUED","pr":…,"strict":…}                   exit 0
#   nudge  → {"outcome":"NUDGED","pr":…} |
#            {"outcome":"NUDGE_NOOP","pr":…,"mergeStateStatus":…}     exit 0
#   poll   → {"outcome":"MERGED","pr":…,"mergedAt":…}                 exit 0
#            {"outcome":"CONFLICTING","pr":…,"mergeStateStatus":…}    exit 3
#            {"outcome":"TIMEOUT","pr":…,"waited":…}                  exit 4
#   backend → {"outcome":"NATIVE"} | {"outcome":"MANAGED"} |
#              {"outcome":"MANAGED","probe_failed":true}              exit 0
#   managed-merge → {"outcome":"MERGED","pr":…,"mergedAt":…}                exit 0
#                    {"outcome":"EJECTED","pr":…,"failed_run_ids":[…]}      exit 5
#                    {"outcome":"MERGE_REJECTED","pr":…,"error":…}          exit 6
#                    {"outcome":"CONFLICTING","pr":…,"mergeStateStatus":…}  exit 3
#                    {"outcome":"TIMEOUT","pr":…,"waited":…}                exit 4
#   error  → {"outcome":"ERROR","error":…}                           exit 1
# Exit codes: 0 success; 1 ERROR (bad input / failed call); 3 CONFLICTING/DIRTY
# terminal-bad (poll, and managed-merge's post-merge confirm poll); 4 TIMEOUT/
# stall (poll, ditto); 5 EJECTED (managed-merge: CI red on the updated head —
# no merge attempted); 6 MERGE_REJECTED (managed-merge: the platform itself
# refused the `gh pr merge` call, e.g. branch protection or a queue-armed repo
# rejecting a direct merge). MERGED is the SOLE success check for poll and for
# managed-merge's confirm step — never "closed", never "checks green" — so a
# PR closed-without-merge can never read as merged (the #130 premature-close
# class).
set -euo pipefail

# --- fixture seam -------------------------------------------------------------
# One test-injection seam per external dependency, mirroring board.sh's single
# `_board_gh` indirection. Production runs real gh (gate.sh has no local-git
# dependency — every read, including the risk predicate's changed-file diff,
# goes through the GitHub API so a PR's head ref never needs to be reachable
# locally; temperloop#242). Tests source this file (sourced-guard below stops
# the dispatch) and override `_gate_gh` to replay fixtures with zero network.
# We also source board.sh so the suite shares ONE fixture system — the board
# harness overrides `_board_gh`, we override `_gate_gh` the same way.
_GATE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workflows/scripts/board/lib/board.sh
# shellcheck disable=SC1091
[ -f "$_GATE_HERE/../board/lib/board.sh" ] && source "$_GATE_HERE/../board/lib/board.sh"

_gate_gh() { gh "$@"; }

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

# fd 3 = the script's real stdout, so a die() inside a command substitution
# still reaches the orchestrator (same seam as ci-poll.sh / pr.sh).
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: gate.sh read <owner>/<repo> <pr> | strict <owner>/<repo> | risk <owner>/<repo> <pr> [<pr> ...] | queue <owner>/<repo> <pr> [--strict|--non-strict] | nudge <owner>/<repo> <pr> | poll <owner>/<repo> <pr> [--interval <secs>] [--timeout <secs>] | backend <owner>/<repo> | managed-merge <owner>/<repo> <pr> [--strict|--non-strict]"
}

# Closed-set validation shared by every command (these feed gh paths / jq).
validate_owner_repo() {
  case "$1" in
    */*/*|*/|/*|"") die "owner/repo '$1' invalid — must be <owner>/<repo>" ;;
    */*) ;;
    *) die "owner/repo '$1' invalid — must be <owner>/<repo>" ;;
  esac
  case "$1" in
    *[!A-Za-z0-9_./-]*) die "owner/repo '$1' invalid — must be <owner>/<repo>" ;;
  esac
}
validate_pr() {
  case "$1" in
    ""|*[!0-9]*) die "pr '$1' invalid — must be a PR number" ;;
  esac
}

# --- read: 4a — mergeability/liveness read -----------------------------------
# Read mergeable (MERGEABLE/CONFLICTING/UNKNOWN), mergeStateStatus
# (CLEAN/BEHIND/BLOCKED/DIRTY), state, and the statusCheckRollup digest for a
# PR. GitHub computes mergeable lazily, so a fresh read can return UNKNOWN (not
# yet computed) or a transient BEHIND; re-poll ONCE after ~3s before letting the
# caller classify on a stale value. `gh pr view --json` is REST-backed, not the
# GraphQL Projects bucket. _gate_view emits the four scalar fields, tab-joined.
_gate_view() {
  local owner_repo="$1" pr="$2" raw
  raw="$(_gate_gh pr view "$pr" -R "$owner_repo" \
        --json mergeable,mergeStateStatus,state,statusCheckRollup 2>&1)" \
    || { printf 'ERR\t%s\n' "$raw"; return 1; }
  # statusCheckRollup → a compact digest: PASS iff every check is SUCCESS-ish,
  # FAIL if any concluded non-success, PENDING while any is still running, NONE
  # when the PR has no checks at all. The orchestrator branches on the digest;
  # ci-poll.sh owns the detailed per-run watch.
  jq -r '
    (.statusCheckRollup // []) as $c
    | (if ($c|length)==0 then "NONE"
       elif any($c[]; (.status // "COMPLETED") != "COMPLETED") then "PENDING"
       elif all($c[]; (.conclusion // .state // "") | IN("SUCCESS","NEUTRAL","SKIPPED")) then "PASS"
       else "FAIL" end) as $checks
    | [(.mergeable // "UNKNOWN"), (.mergeStateStatus // "UNKNOWN"),
       (.state // "UNKNOWN"), $checks] | @tsv' <<<"$raw"
}

cmd_read() {
  local owner_repo="$1" pr="$2" mergeable mss state checks
  validate_owner_repo "$owner_repo"
  validate_pr "$pr"
  IFS=$'\t' read -r mergeable mss state checks < <(_gate_view "$owner_repo" "$pr") \
    || die "gh pr view failed for #$pr"
  [ "$mergeable" = "ERR" ] && die "gh pr view failed for #$pr: $mss"
  # Re-poll ONCE after ~3s on an unresolved mergeable or a lone BEHIND — GitHub
  # may still be computing; classifying on the stale value is the failure.
  if [ "$mergeable" = "UNKNOWN" ] || [ "$mss" = "BEHIND" ]; then
    sleep "${GATE_REPOLL_DELAY:-3}"
    IFS=$'\t' read -r mergeable mss state checks < <(_gate_view "$owner_repo" "$pr") \
      || die "gh pr view re-poll failed for #$pr"
    [ "$mergeable" = "ERR" ] && die "gh pr view re-poll failed for #$pr: $mss"
  fi
  jq -cn --arg m "$mergeable" --arg s "$mss" --arg st "$state" --arg c "$checks" \
    '{outcome:"READ", mergeable:$m, mergeStateStatus:$s, state:$st, checks:$c}'
}

# --- strict: 4b — strict-main detection --------------------------------------
# Read branch protection's required_status_checks.strict. A 404 (branch not
# protected, or no required checks) → non-strict: gh exits non-zero and we read
# that as NON_STRICT rather than an error. A literal `true` → STRICT.
cmd_strict() {
  local owner_repo="$1" out strict
  validate_owner_repo "$owner_repo"
  if out="$(_gate_gh api "repos/$owner_repo/branches/main/protection" \
        --jq '.required_status_checks.strict' 2>/dev/null)"; then
    strict="$out"
  else
    # Non-zero from gh here means 404 / not-protected → non-strict.
    strict="false"
  fi
  if [ "$strict" = "true" ]; then
    jq -cn '{outcome:"STRICT"}'
  else
    jq -cn '{outcome:"NON_STRICT"}'
  fi
}

# --- backend: merge-backend SELECTION (temperloop#13) ------------------------
# TemperLoop's level merge gate must also work on free personal repos that
# can't provision GitHub's native merge queue. This subcommand is the
# SELECTION half only — NATIVE (native merge queue) vs MANAGED (no native
# queue available). It does no merging itself; the managed-merge mechanics are
# a separate later item.
#
# BUILD_MERGE_BACKEND (build.config.sh, default "auto") short-circuits an
# explicit `native`/`managed` override WITHOUT probing at all — the config
# value wins outright, mirroring the `:=` "explicit env always wins" idiom.
# Under `auto` (or any other value) we probe the repo's branch ruleset for a
# `merge_queue` rule on `main`, the same shape as
# land__requires_pr() in workflows/scripts/lib/land-on-protected-main.sh
# (`repos/<nwo>/rules/branches/<default>` --jq 'any(.[]; .type=="...")').
#
# Fail-safe direction: a probe failure (gh error, 404, empty body) resolves to
# MANAGED, never NATIVE — the reverse (defaulting to NATIVE on an unreadable
# probe) risks queuing a native `--auto` merge on a repo that has no queue
# armed, which just fails loudly at branch protection; defaulting to MANAGED
# on a queue-armed repo the probe merely failed to *see* is the safe direction
# because MANAGED never silently arms an auto-merge nobody chose. The
# `probe_failed:true` flag lets the orchestrator distinguish "no queue" from
# "couldn't tell".
cmd_backend() {
  local owner_repo="$1" backend out
  validate_owner_repo "$owner_repo"
  backend="${BUILD_MERGE_BACKEND:-auto}"

  case "$backend" in
    native) jq -cn '{outcome:"NATIVE"}'; return 0 ;;
    managed) jq -cn '{outcome:"MANAGED"}'; return 0 ;;
  esac

  # auto (or any unrecognized value) → probe.
  if out="$(_gate_gh api "repos/$owner_repo/rules/branches/main" \
        --jq 'any(.[]; .type=="merge_queue")' 2>/dev/null)" && [ -n "$out" ]; then
    if [ "$out" = "true" ]; then
      jq -cn '{outcome:"NATIVE"}'
    else
      jq -cn '{outcome:"MANAGED"}'
    fi
  else
    jq -cn '{outcome:"MANAGED", probe_failed:true}'
  fi
}

# --- risk: mechanical risk predicate -----------------------------------------
# Given a set of selected PRs, RISKY iff ANY of:
#   (a) their changed-file sets are not pairwise disjoint;
#   (b) any PR carries a `hold` or `risky` label;
#   (c) any PR's mergeStateStatus is not CLEAN.
# Else CLEAN_DISJOINT_INDEPENDENT. This is the *mechanical* half of the gate —
# it is a necessary, not sufficient, condition for a batched merge; the human
# still consents. Reasons accumulate so the orchestrator can surface every
# trigger, not just the first.
_gate_pr_files() {  # changed files for a PR, one per line — via the GitHub
                     # API's own `files` field, NEVER local git. A bare
                     # `origin/main..<headRefName>` diff assumes the head ref
                     # is reachable as a local/origin branch, which a
                     # push-by-SHA branch (`git push origin <sha>:refs/heads/
                     # <branch>`, /build's own convention) is not guaranteed
                     # to be in every checkout — the API already knows the
                     # PR's changed files without any local ref at all
                     # (temperloop#242).
  local owner_repo="$1" pr="$2" raw
  raw="$(_gate_gh pr view "$pr" -R "$owner_repo" --json files --jq '.files[].path' 2>&1)" \
    || { printf 'ERR\t%s\n' "$raw"; return 1; }
  printf '%s\n' "$raw"
}
_gate_pr_labels() {  # label names for a PR, one per line
  _gate_gh pr view "$2" -R "$1" --json labels --jq '.labels[].name' 2>/dev/null || true
}

cmd_risk() {
  local owner_repo="$1"; shift
  validate_owner_repo "$owner_repo"
  [ $# -ge 1 ] || die "risk requires at least one PR number"
  local pr reasons=() i j
  local -a prs=()
  for pr in "$@"; do validate_pr "$pr"; prs+=("$pr"); done

  # (c) mergeStateStatus != CLEAN, and (b) hold/risky labels — per PR.
  local files_dir; files_dir="$(mktemp -d)"
  for pr in "${prs[@]}"; do
    local mergeable mss state checks
    IFS=$'\t' read -r mergeable mss state checks < <(_gate_view "$owner_repo" "$pr") \
      || { rm -rf "$files_dir"; die "gh pr view failed for #$pr"; }
    [ "$mergeable" = "ERR" ] && { rm -rf "$files_dir"; die "gh pr view failed for #$pr: $mss"; }
    [ "$mss" = "CLEAN" ] || reasons+=("PR #$pr mergeStateStatus=$mss (not CLEAN)")
    local labels; labels="$(_gate_pr_labels "$owner_repo" "$pr")"
    if grep -qiE '^(hold|risky)$' <<<"$labels"; then
      reasons+=("PR #$pr carries a hold/risky label")
    fi
    # changed-file set for the pairwise-disjoint test. The assignment and its
    # `||` handler MUST be one statement (never a bare `f="$(...)"` preceded
    # by a separate `local f;`) — under `set -euo pipefail` a failing command
    # substitution in a bare assignment kills the whole script BEFORE any
    # later `case`/error check ever runs, exiting empty-stdout/rc=1 with no
    # closed-JSON outcome for the orchestrator to branch on (temperloop#242).
    # Chaining `|| { ... }` directly onto the assignment keeps it inside a
    # tested command, so -e does not fire and the ERR path actually executes.
    local f
    f="$(_gate_pr_files "$owner_repo" "$pr")" \
      || { rm -rf "$files_dir"; die "gh pr view (files) failed for #$pr: ${f#ERR	}"; }
    printf '%s\n' "$f" | grep -v '^$' | sort -u > "$files_dir/$pr"
  done

  # (a) pairwise-disjoint changed-file sets — any non-empty intersection is RISKY.
  local n=${#prs[@]}
  for ((i=0; i<n; i++)); do
    for ((j=i+1; j<n; j++)); do
      local a="${prs[$i]}" b="${prs[$j]}" overlap
      overlap="$(comm -12 "$files_dir/$a" "$files_dir/$b")"
      if [ -n "$overlap" ]; then
        reasons+=("PR #$a and #$b touch overlapping files: $(tr '\n' ' ' <<<"$overlap" | sed 's/ $//')")
      fi
    done
  done
  rm -rf "$files_dir"

  if [ ${#reasons[@]} -gt 0 ]; then
    local jr; jr="$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -cs .)"
    jq -cn --argjson reasons "$jr" '{outcome:"RISKY", reasons:$reasons}'
  else
    jq -cn '{outcome:"CLEAN_DISJOINT_INDEPENDENT"}'
  fi
}

# --- queue: 4b — --auto merge queue ------------------------------------------
# Queue the canonical incantation. --strict main → `--auto --merge` (the merge
# lands only once required checks pass + branch is current). --non-strict →
# `--merge --auto` queues equivalently (auto-merge still requires consent +
# green checks to fire). This is NOT a merge: --auto enqueues; it cannot bypass
# branch protection or a missing check. No --delete-branch flag: the merge
# queue rejects it and owns head-branch deletion itself (via the repo's
# delete_branch_on_merge setting), per the Branch & PR policy.
cmd_queue() {
  local owner_repo="$1" pr="$2" strict="" out
  validate_owner_repo "$owner_repo"
  validate_pr "$pr"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --strict)     strict=1 ;;
      --non-strict) strict="" ;;
      *) usage ;;
    esac
    shift
  done
  # Both strict and non-strict use --auto (queue, not merge-now). The strict
  # flag is recorded in the outcome for the orchestrator's audit trail; the
  # incantation is the same canonical `--auto --merge` (no --delete-branch —
  # the merge queue rejects it and deletes the head branch itself).
  if ! out="$(_gate_gh pr merge "$pr" -R "$owner_repo" --auto --merge 2>&1)"; then
    die "gh pr merge --auto failed for #$pr: $out"
  fi
  jq -cn --argjson pr "$pr" --argjson strict "$([ -n "$strict" ] && echo true || echo false)" \
    '{outcome:"QUEUED", pr:$pr, strict:$strict}'
}

# --- nudge: 4c — update-branch nudge -----------------------------------------
# Auto-merge does not reliably self-update a BEHIND branch (the #83 nudge), so
# for a still-BEHIND PR run `gh pr update-branch`. NOOP when the PR is no longer
# BEHIND (re-read first so we never nudge a CLEAN branch needlessly).
cmd_nudge() {
  local owner_repo="$1" pr="$2" mergeable mss state checks out
  validate_owner_repo "$owner_repo"
  validate_pr "$pr"
  IFS=$'\t' read -r mergeable mss state checks < <(_gate_view "$owner_repo" "$pr") \
    || die "gh pr view failed for #$pr"
  [ "$mergeable" = "ERR" ] && die "gh pr view failed for #$pr: $mss"
  if [ "$mss" != "BEHIND" ]; then
    jq -cn --argjson pr "$pr" --arg s "$mss" '{outcome:"NUDGE_NOOP", pr:$pr, mergeStateStatus:$s}'
    return 0
  fi
  if ! out="$(_gate_gh pr update-branch "$pr" -R "$owner_repo" 2>&1)"; then
    die "gh pr update-branch failed for #$pr: $out"
  fi
  jq -cn --argjson pr "$pr" '{outcome:"NUDGED", pr:$pr}'
}

# --- poll: poll-until-MERGED -------------------------------------------------
# Poll state until terminal. MERGED is the SOLE success check (state=="MERGED"
# AND a non-null mergedAt) → exit 0. A CONFLICTING mergeable or a DIRTY
# mergeStateStatus is a terminal-bad outcome → exit 3 (the merge cannot land
# without intervention). Running out the deadline → TIMEOUT exit 4. A PR that
# goes CLOSED without merging never reads as MERGED — this is the #130
# premature-close guard.
cmd_poll() {
  local owner_repo="$1" pr="$2" interval=15 timeout=600
  validate_owner_repo "$owner_repo"
  validate_pr "$pr"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval) [ $# -ge 2 ] || usage; interval="$2"; shift ;;
      --timeout)  [ $# -ge 2 ] || usage; timeout="$2"; shift ;;
      *) usage ;;
    esac
    shift
  done
  case "$interval" in ""|.|*[!0-9.]*|*.*.*) die "interval '$interval' invalid" ;; esac
  case "$timeout" in ""|*[!0-9]*) die "timeout '$timeout' invalid" ;; esac

  local deadline=$((SECONDS + timeout))
  while :; do
    local raw state merged_at mergeable mss
    raw="$(_gate_gh pr view "$pr" -R "$owner_repo" \
          --json state,mergedAt,mergeable,mergeStateStatus 2>&1)" \
      || die "gh pr view failed for #$pr: $raw"
    state="$(jq -r '.state // "UNKNOWN"' <<<"$raw")"
    merged_at="$(jq -r '.mergedAt // ""' <<<"$raw")"
    mergeable="$(jq -r '.mergeable // "UNKNOWN"' <<<"$raw")"
    mss="$(jq -r '.mergeStateStatus // "UNKNOWN"' <<<"$raw")"

    # SOLE success check: MERGED with a confirmed mergedAt.
    if [ "$state" = "MERGED" ] && [ -n "$merged_at" ]; then
      jq -cn --argjson pr "$pr" --arg at "$merged_at" '{outcome:"MERGED", pr:$pr, mergedAt:$at}'
      exit 0
    fi
    # Terminal-bad: a conflict / dirty tree won't land without intervention.
    if [ "$mergeable" = "CONFLICTING" ] || [ "$mss" = "DIRTY" ]; then
      jq -cn --argjson pr "$pr" --arg s "$mss" '{outcome:"CONFLICTING", pr:$pr, mergeStateStatus:$s}'
      exit 3
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      jq -cn --argjson pr "$pr" --argjson waited "$SECONDS" '{outcome:"TIMEOUT", pr:$pr, waited:$waited}'
      exit 4
    fi
    sleep "$interval"
  done
}

# --- managed-merge: SHA-pinned CI re-poll ------------------------------------
# Implemented INLINE via _gate_gh rather than shelling out to ci-poll.sh: this
# keeps managed-merge on the SAME single _gate_gh fixture seam the rest of
# gate.sh already uses (one mock, no second network-capable subprocess to
# stand up in tests). Polls repos/<nwo>/commits/<sha>/check-runs — REST, NEVER
# `gh pr checks --watch` (GraphQL, shared-budget concern — see ci-poll.sh's own
# header) — until every check-run is completed, or the deadline passes; same
# shape as ci-poll.sh's loop. Tab-separated result (mirrors _gate_view's
# tsv-via-stdout idiom):
#   GREEN\t[]          — every check-run concluded success/neutral/skipped
#   FAILED\t<ids-json> — at least one concluded non-success; ids best-effort
#   TIMEOUT\t[]        — deadline passed with checks still pending
#   ERR\t<message>     — the check-runs query itself failed
_gate_ci_poll() {
  local owner_repo="$1" sha="$2" interval="$3" timeout="$4"
  local deadline=$((SECONDS + timeout))
  while :; do
    local runs n pending
    if ! runs="$(_gate_gh api "repos/$owner_repo/commits/$sha/check-runs" \
          --jq '[.check_runs[]|{status,conclusion}]' 2>&1)"; then
      printf 'ERR\t%s\n' "$runs"; return 0
    fi
    n="$(jq length <<<"$runs" 2>/dev/null || echo 0)"
    pending="$(jq '[.[]|select(.status!="completed")]|length' <<<"$runs" 2>/dev/null || echo 0)"
    if [ "$n" -gt 0 ] && [ "$pending" -eq 0 ]; then
      if jq -e 'all(.[]; .conclusion|IN("success","neutral","skipped"))' <<<"$runs" >/dev/null 2>&1; then
        printf 'GREEN\t[]\n'; return 0
      fi
      local failed_ids
      failed_ids="$(_gate_gh run list -R "$owner_repo" --commit "$sha" --json databaseId,conclusion \
          --jq '[.[]|select(.conclusion=="failure")|.databaseId]' 2>/dev/null)" || failed_ids="[]"
      jq -e . >/dev/null 2>&1 <<<"$failed_ids" || failed_ids="[]"
      printf 'FAILED\t%s\n' "$failed_ids"; return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      printf 'TIMEOUT\t[]\n'; return 0
    fi
    sleep "$interval"
  done
}

# --- managed-merge: per-PR MANAGED merge mechanics (temperloop#13) -----------
# Replicates GitHub's native merge-queue semantics with existing primitives,
# for a repo with no native queue (gate.sh backend → MANAGED). PER-PR
# MECHANICS ONLY: fold latest main into the head, revalidate CI on the UPDATED
# head, merge on green, confirm MERGED. The whole-SET loop — processing order,
# and whether to stop or continue past an ejected PR — is orchestrator policy
# (build.md), deliberately NOT built here (a set-loop inside gate.sh would move
# merge-order policy into the spine).
#
# strict (default): update-branch → resolve the NEW head sha (never poll a
# stale one — mirrors ci-poll.sh's own #254 guard) → SHA-pinned CI re-poll via
# _gate_ci_poll → on green, fall through to merge; on red, EJECTED (exit 5),
# NO merge attempted and NO plan-note sentinels/labels written (consent +
# writeback stay orchestrator-side, per this file's own header contract).
# --non-strict skips update-branch + the re-poll ENTIRELY (preserves a
# non-strict repo's immediate-merge cost profile) and merges directly.
#
# Either path's merge is the same `gh pr merge --merge` — NOT --auto (unlike
# cmd_queue): managed-merge has already established
# mergeability itself (strict: via the re-poll; non-strict: by definition), so
# it merges now rather than queuing. A merge the platform itself rejects (e.g.
# branch protection, or a queue-armed repo refusing a direct merge) surfaces
# as MERGE_REJECTED (exit 6) rather than dying silently. A successful merge
# call is confirmed via the SAME poll-to-MERGED cmd_poll already implements —
# the #130 guard applies here too: MERGED is the sole success check.
#
# GATE_CI_POLL_INTERVAL/GATE_CI_POLL_TIMEOUT (default 30/3600, mirroring
# ci-poll.sh's own defaults) and GATE_MERGE_POLL_INTERVAL/
# GATE_MERGE_POLL_TIMEOUT (default 15/600, mirroring cmd_poll's own defaults)
# are the zero-delay test knobs for this command's two poll loops — mirrors
# GATE_REPOLL_DELAY=0 above.
cmd_managed_merge() {
  local owner_repo="$1" pr="$2" strict=1 out
  validate_owner_repo "$owner_repo"
  validate_pr "$pr"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --strict)     strict=1 ;;
      --non-strict) strict="" ;;
      *) usage ;;
    esac
    shift
  done

  if [ -n "$strict" ]; then
    if ! out="$(_gate_gh pr update-branch "$pr" -R "$owner_repo" 2>&1)"; then
      die "gh pr update-branch failed for #$pr: $out"
    fi
    # Resolve the NEW head sha post-update — never poll a stale head (#254).
    local sha
    if ! sha="$(_gate_gh pr view "$pr" -R "$owner_repo" --json headRefOid --jq '.headRefOid' 2>&1)" \
        || [ -z "$sha" ]; then
      die "could not resolve updated head SHA for #$pr: $sha"
    fi
    local ci_status ci_ids
    IFS=$'\t' read -r ci_status ci_ids < <(_gate_ci_poll "$owner_repo" "$sha" \
        "${GATE_CI_POLL_INTERVAL:-30}" "${GATE_CI_POLL_TIMEOUT:-3600}")
    case "$ci_status" in
      GREEN) ;;
      FAILED)
        jq -cn --argjson pr "$pr" --argjson ids "$ci_ids" \
          '{outcome:"EJECTED", pr:$pr, failed_run_ids:$ids}'
        return 5
        ;;
      TIMEOUT)
        # The SHA-pinned CI re-poll ran out its deadline with checks still
        # pending. Per this file's header exit-code contract this is a TIMEOUT
        # (exit 4), NOT an ERROR — a stall is a distinct, retryable outcome the
        # orchestrator branches on, never the ERROR/exit-1 class a die() emits.
        # `waited` reports the re-poll budget we exhausted (GATE_CI_POLL_TIMEOUT).
        jq -cn --argjson pr "$pr" --argjson waited "${GATE_CI_POLL_TIMEOUT:-3600}" \
          '{outcome:"TIMEOUT", pr:$pr, waited:$waited}'
        return 4
        ;;
      *)        die "CI re-poll failed for #$pr on sha $sha: $ci_ids" ;;
    esac
  fi

  if ! out="$(_gate_gh pr merge "$pr" -R "$owner_repo" --merge 2>&1)"; then
    jq -cn --argjson pr "$pr" --arg error "$out" '{outcome:"MERGE_REJECTED", pr:$pr, error:$error}'
    return 6
  fi

  local confirm rc=0
  confirm="$(cmd_poll "$owner_repo" "$pr" \
      --interval "${GATE_MERGE_POLL_INTERVAL:-15}" --timeout "${GATE_MERGE_POLL_TIMEOUT:-600}")" || rc=$?
  echo "$confirm"
  return "$rc"
}

# --- dispatch (skipped when sourced for tests) -------------------------------
# Mirrors the board-test harness: a test `source`s this file to override the
# seams and call cmd_* directly, so the dispatch must NOT run on source. The
# guard compares $0 to BASH_SOURCE.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ $# -ge 1 ] || usage
  cmd="$1"; shift
  case "$cmd" in
    read)   [ $# -eq 2 ] || usage; cmd_read "$1" "$2" ;;
    strict) [ $# -eq 1 ] || usage; cmd_strict "$1" ;;
    risk)   [ $# -ge 2 ] || usage; cmd_risk "$@" ;;
    queue)  [ $# -ge 2 ] || usage; cmd_queue "$@" ;;
    nudge)  [ $# -eq 2 ] || usage; cmd_nudge "$1" "$2" ;;
    poll)   [ $# -ge 2 ] || usage; cmd_poll "$@" ;;
    backend) [ $# -eq 1 ] || usage; cmd_backend "$1" ;;
    managed-merge) [ $# -ge 2 ] || usage; cmd_managed_merge "$@" ;;
    *) usage ;;
  esac
fi
