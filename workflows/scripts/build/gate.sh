#!/usr/bin/env bash
#
# build merge-gate mechanics — the deterministic-machinery script that owns the
# 4a/4b/4c merge-gate steps of /build — and, over a one-PR set, its per-item
# 3h.5 as-you-go merge (temperloop#1026) — (epic #253, spike #245). Reading a
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
#       → queue the canonical --auto merge incantation; a DRAFT PR is named as
#         its own outcome BEFORE the enqueue is attempted (temperloop#1180)
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
#         policy into the machinery.
#   gate.sh diagnose-queue <owner>/<repo> <pr>
#       → classify a STALLED native-queue poll (temperloop#1150): reads the two
#         observability channels the bare `gh pr view` poll cannot — the GraphQL
#         `mergeQueueEntry` membership signal and the `merge_group` run history —
#         so a silent dequeue resolves to a structured QUEUED / MERGE_GROUP_FAILED
#         / DEQUEUED / MERGED verdict instead of an opaque BUILD_QUEUE_TIMEOUT.
#         A STILL-ENQUEUED entry older than BUILD_QUEUE_STALL_AFTER with zero
#         merge_group runs dispatched resolves to QUEUE_STALLED (temperloop#1178)
#         — a stalled queue, distinguishable from a merely slow one.
#
# Output contract — CLOSED outcome set, one structured JSON line per command
# (the orchestrator branches on `.outcome`, never parses prose):
#   read   → {"outcome":"READ","pr":…,"mergeable":…,"mergeStateStatus":…,
#             "state":…,"checks":…}                                   exit 0
#   strict → {"outcome":"STRICT"|"NON_STRICT"}                        exit 0
#   risk   → {"outcome":"RISKY","reasons":[…]} |
#            {"outcome":"CLEAN_DISJOINT_INDEPENDENT"}                 exit 0
#   queue  → {"outcome":"QUEUED","pr":…,"strict":…}                   exit 0
#            {"outcome":"DRAFT","pr":…,"error":…}                     exit 9
#   nudge  → {"outcome":"NUDGED","pr":…} |
#            {"outcome":"NUDGE_NOOP","pr":…,"mergeStateStatus":…}     exit 0
#   poll   → {"outcome":"MERGED","pr":…,"mergedAt":…}                 exit 0
#            {"outcome":"CONFLICTING","pr":…,"mergeStateStatus":…}    exit 3
#            {"outcome":"TIMEOUT","pr":…,"waited":…,
#             "reason":…,"diagnosis":{…}}                            exit 4
#   backend → {"outcome":"NATIVE"} | {"outcome":"MANAGED"} |
#              {"outcome":"MANAGED","probe_failed":true}              exit 0
#   managed-merge → {"outcome":"MERGED","pr":…,"mergedAt":…}                exit 0
#                    {"outcome":"EJECTED","pr":…,"failed_run_ids":[…]}      exit 5
#                    {"outcome":"MERGE_REJECTED","pr":…,"error":…}          exit 6
#                    {"outcome":"CONFLICTING","pr":…,"mergeStateStatus":…}  exit 3
#                    {"outcome":"TIMEOUT","pr":…,"waited":…}                exit 4
#   diagnose-queue → {"outcome":"QUEUED","pr":…,"queueState":…}       exit 0
#                    {"outcome":"MERGED","pr":…,"mergedAt":…}          exit 0
#                    {"outcome":"MERGE_GROUP_FAILED","pr":…,"run_id":…} exit 7
#                    {"outcome":"DEQUEUED","pr":…}                     exit 8
#                    {"outcome":"QUEUE_STALLED","pr":…,
#                     "enqueued_secs":…,"merge_group_runs":0}         exit 10
#   error  → {"outcome":"ERROR","error":…}                           exit 1
# Exit codes: 0 success; 1 ERROR (bad input / failed call); 3 CONFLICTING/DIRTY
# terminal-bad (poll, and managed-merge's post-merge confirm poll); 4 TIMEOUT/
# stall (poll, ditto); 5 EJECTED (managed-merge: CI red on the updated head —
# no merge attempted); 6 MERGE_REJECTED (managed-merge: the platform itself
# refused the `gh pr merge` call, e.g. branch protection or a queue-armed repo
# rejecting a direct merge); 7 MERGE_GROUP_FAILED (diagnose-queue: the queue's
# merge_group CI concluded failure — a real group conflict); 8 DEQUEUED
# (diagnose-queue: the PR left the queue with no failing group run — an entry
# dropped during churn); 9 DRAFT (queue: the PR is a draft, which GitHub refuses
# to auto-merge — a NAMED state with a named remedy, never a raw
# enablePullRequestAutoMerge string); 10 QUEUE_STALLED (diagnose-queue: the PR
# is STILL enqueued but has been for longer than BUILD_QUEUE_STALL_AFTER with
# ZERO merge_group runs ever dispatched for it — a stalled queue, not a slow
# one, so the caller stops waiting instead of re-polling forever). MERGED is the SOLE success check for poll and for
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

# Second injection seam: wall-clock. Only the queue-stall age computation reads
# it, and a test that could not pin "now" would have to embed a moving
# timestamp — so the clock gets the same override treatment as `gh` (mirrors
# reconcile.sh's `_reconcile_now`). Production is plain epoch seconds.
_gate_now() { date +%s; }

# Parse an ISO-8601 UTC timestamp ("2026-06-07T12:00:00Z", as the GitHub API
# emits enqueuedAt) to epoch seconds, portably: GNU `date -d` first, then BSD
# `date -j -f` (macOS ships no GNU date). Prints NOTHING on a missing or
# unparseable value so the caller fails safe — an unreadable timestamp must
# never manufacture a stall verdict. TZ=UTC is FORCED on both branches: BSD's
# `date -j -f` treats the trailing 'Z' as a literal rather than a zone, so
# without it the stamp parses in the host's local time and the resulting epoch
# is skewed by the UTC offset while `_gate_now` is true UTC.
_gate_epoch_of() {
  local iso="$1"
  [ -n "$iso" ] || return 0
  TZ=UTC date -d "$iso" +%s 2>/dev/null && return 0
  TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
  return 0
}

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

# fd 3 = the script's real stdout, so a die() inside a command substitution
# still reaches the orchestrator (same seam as ci-poll.sh / pr.sh).
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: gate.sh read <owner>/<repo> <pr> | strict <owner>/<repo> | risk <owner>/<repo> <pr> [<pr> ...] | queue <owner>/<repo> <pr> [--strict|--non-strict] | nudge <owner>/<repo> <pr> | poll <owner>/<repo> <pr> [--interval <secs>] [--timeout <secs>] | backend <owner>/<repo> | managed-merge <owner>/<repo> <pr> [--strict|--non-strict] | diagnose-queue <owner>/<repo> <pr>"
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
# yet computed) or a transient BEHIND; re-poll ONCE after $GATE_REPOLL_DELAY
# before letting the caller classify on a stale value. `gh pr view --json` is
# REST-backed, not the GraphQL Projects bucket. _gate_view emits the four scalar
# fields, tab-joined.
#
# temperloop#976 retry-loop inventory — CAP: exactly one re-poll, and no
# transient-vs-deterministic classification step applies: the ONLY states that
# re-poll (UNKNOWN, a lone BEHIND) are BY DEFINITION not-yet-computed server-side
# values, i.e. structurally transient. Every deterministic answer — CONFLICTING,
# DIRTY, a resolved MERGEABLE — is returned on the first read and never re-issued,
# and a `gh` ERROR dies immediately rather than retrying. The `poll` and
# managed-merge CI re-poll loops further down are likewise bounded WAITS on
# external state (each carries its own --interval/--timeout deadline), not
# re-attempts of a failed operation.
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
#
# DRAFT is a NAMED outcome, checked BEFORE the enqueue (temperloop#1180).
# GitHub refuses `enablePullRequestAutoMerge` on a draft PR, so an enqueue
# against one fails with the raw GraphQL string
# `GraphQL: Pull request is a draft (enablePullRequestAutoMerge)` — a true but
# unactionable message that named neither the state nor the fix, and left a
# parked run's PR behind that no re-run could ever land (three such PRs sat
# 1-3 weeks in temperloop#1179's stale-PR triage).
#
# The disposition is FAIL LOUDLY, never an auto `gh pr ready` flip, because
# draft-open is NOT a pipeline flow: `pr.sh open` calls bare
# `gh pr create --head --title --body` with no `--draft` on any path,
# build-level.mjs adds none, `pr-enqueue.sh` only drafts on an explicit opt-in
# (and already refuses to enqueue one), and no script in this repo runs
# `gh pr ready` at all — so a draft PR reaching the merge gate is ALWAYS a
# human decision, and silently un-drafting it would override the one party who
# chose it. gate.sh reports; consent stays orchestrator/operator-side, exactly
# as this file's header contract requires.
#
# TWO detection sites, because either alone leaves a hole: the pre-flight probe
# is FAIL-OPEN (an unreadable `isDraft` proceeds to the enqueue rather than
# blocking it — never worse than today's behavior), and the post-hoc classifier
# catches the draft whose probe failed, or that was flipped to draft between
# the probe and the enqueue.
_gate_draft_msg() {  # $1=owner/repo $2=pr — the operator-facing named message
  printf 'PR #%s is a DRAFT — GitHub refuses to auto-merge a draft, so it can never be enqueued. /build never opens draft PRs, so this one was marked draft by hand: mark it ready with "gh pr ready %s -R %s" (or close it), then re-run the merge gate.' \
    "$2" "$2" "$1"
}

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
  # Pre-flight draft probe (fail-open: only a literal `true` blocks — an empty
  # or errored read falls through to the enqueue, where the post-hoc classifier
  # below still names a draft rejection).
  local isdraft=""
  isdraft="$(_gate_gh pr view "$pr" -R "$owner_repo" --json isDraft --jq '.isDraft' 2>/dev/null)" || isdraft=""
  if [ "$isdraft" = "true" ]; then
    jq -cn --argjson pr "$pr" --arg error "$(_gate_draft_msg "$owner_repo" "$pr")" \
      '{outcome:"DRAFT", pr:$pr, error:$error}'
    return 9
  fi

  # Both strict and non-strict use --auto (queue, not merge-now). The strict
  # flag is recorded in the outcome for the orchestrator's audit trail; the
  # incantation is the same canonical `--auto --merge` (no --delete-branch —
  # the merge queue rejects it and deletes the head branch itself).
  if ! out="$(_gate_gh pr merge "$pr" -R "$owner_repo" --auto --merge 2>&1)"; then
    # Post-hoc classifier — the probe was unreadable, or the PR became a draft
    # between probe and enqueue. Same NAMED outcome, never the raw GraphQL text.
    # Anchored on the draft phrase ALONE, deliberately not on the mutation name:
    # `enablePullRequestAutoMerge` also tails unrelated rejections (auto-merge
    # disabled repo-wide), and mis-naming one of those "DRAFT" would trade one
    # wrong message for another.
    if grep -qi 'is a draft' <<<"$out"; then
      jq -cn --argjson pr "$pr" --arg error "$(_gate_draft_msg "$owner_repo" "$pr")" \
        '{outcome:"DRAFT", pr:$pr, error:$error}'
      return 9
    fi
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
# without intervention). Running out the deadline → TIMEOUT exit 4, carrying the
# `diagnose-queue` verdict as `reason`/`diagnosis` (temperloop#1178) so a caller
# can tell a slow queue from a stalled one. A PR that
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
      # A bare `waited` count cannot tell "try again later" from "stop waiting,
      # this needs a human" — so the deadline runs the SAME diagnose-queue probe
      # and the TIMEOUT carries its reason (temperloop#1178). Fail-open by
      # construction: diagnose's own die() writes to fd 3, which is redirected
      # away here, so an unreachable/erroring probe leaves the pre-existing bare
      # TIMEOUT shape (and exit 4) exactly as before.
      local dq dq_outcome
      dq="$( (cmd_diagnose_queue "$owner_repo" "$pr") 3>/dev/null 2>/dev/null )" || true
      dq_outcome="$(jq -r '.outcome // empty' <<<"$dq" 2>/dev/null || echo "")"
      if [ -n "$dq_outcome" ]; then
        jq -cn --argjson pr "$pr" --argjson waited "$SECONDS" \
               --arg reason "$dq_outcome" --argjson diag "$dq" \
          '{outcome:"TIMEOUT", pr:$pr, waited:$waited, reason:$reason, diagnosis:$diag}'
      else
        jq -cn --argjson pr "$pr" --argjson waited "$SECONDS" '{outcome:"TIMEOUT", pr:$pr, waited:$waited}'
      fi
      exit 4
    fi
    sleep "$interval"
  done
}

# --- diagnose-queue: classify a STALLED native-queue poll (temperloop#1150) --
# The NATIVE merge-queue poll — build.md 4b step 1 (LLM-driven `gh pr view`) and
# cmd_poll above — reads only state/mergedAt/mergeStateStatus. Those fields
# CANNOT tell a PR silently dequeued by the queue (its merge_group CI failed, or
# its entry dropped during queue churn) from one still legitimately queued: both
# sit OPEN + non-DIRTY, so today the only backstop is running out
# BUILD_QUEUE_TIMEOUT and then guessing. This subcommand adds the two
# observability channels the poll lacks so a stall resolves to a STRUCTURED
# verdict the orchestrator routes on:
#   (1) mergeQueueEntry{ state } via GraphQL — the ONE signal that directly says
#       "still in the queue". The gh `--json mergeQueueEntry` CLI field is absent
#       (build.md's NATIVE poll predicate), but the GraphQL field works —
#       pr-enqueue.sh already relies on it. Non-empty state ⇒ QUEUED (keep
#       waiting; NOT a dequeue) — UNLESS the entry is also stale with no
#       merge_group run ever dispatched, which is QUEUE_STALLED (see below).
#   (2) merge_group workflow runs via REST — repos/<r>/actions/runs?event=
#       merge_group. When not in the queue, the LATEST run whose trial branch
#       references this PR (gh-readonly-queue/<base>/pr-<N>-<sha>) says WHY it
#       left: conclusion==failure ⇒ MERGE_GROUP_FAILED (a real group CI failure —
#       a semantic conflict or transiently-broken main; the caller routes
#       straight to 4c rather than burning a managed-merge retry that re-fails);
#       no referencing run ⇒ DEQUEUED (entry dropped during churn — re-arm --auto
#       once). An in-progress referencing run ⇒ still QUEUED.
#
# LIMITATION (documented — a bounded improvement, never a regression): when the
# queue BATCHES several PRs into one group, the trial-branch ref names one PR, so
# a group failure attributed to a sibling's ref reads as DEQUEUED (no referencing
# run) for ours rather than MERGE_GROUP_FAILED. Recovery still fires (DEQUEUED
# re-arms), just without the failed-run id — strictly better than today's opaque
# timeout, never worse.
cmd_diagnose_queue() {
  local owner_repo="$1" pr="$2" owner name
  validate_owner_repo "$owner_repo"
  validate_pr "$pr"
  owner="${owner_repo%%/*}"; name="${owner_repo#*/}"

  # Channel 1 — GraphQL membership: is the PR still in the queue? Extract each
  # scalar with its OWN jq (never a tab-joined `read` — tab is IFS-whitespace, so
  # `read` would silently trim an empty leading field, exactly the not-in-queue
  # case). Mirrors pr-enqueue.sh's per-field jq -r style.
  local q cj merged mergedat qstate enqueued_at
  # shellcheck disable=SC2016  # $owner/$name/$number are GraphQL vars, not shell
  q='query($owner:String!,$name:String!,$number:Int!){
       repository(owner:$owner,name:$name){
         pullRequest(number:$number){
           merged mergedAt
           mergeQueueEntry{ state position enqueuedAt }
         }
       }
     }'
  cj="$(_gate_gh api graphql -f query="$q" -f owner="$owner" -f name="$name" \
        -F number="$pr" 2>&1)" || die "merge-queue membership query failed for #$pr: $cj"
  merged="$(jq -r '.data.repository.pullRequest.merged // false' <<<"$cj" 2>/dev/null)" \
    || die "unparseable merge-queue membership response for #$pr"
  mergedat="$(jq -r '.data.repository.pullRequest.mergedAt // ""' <<<"$cj" 2>/dev/null || echo "")"
  qstate="$(jq -r '.data.repository.pullRequest.mergeQueueEntry.state // ""' <<<"$cj" 2>/dev/null || echo "")"
  enqueued_at="$(jq -r '.data.repository.pullRequest.mergeQueueEntry.enqueuedAt // ""' <<<"$cj" 2>/dev/null || echo "")"

  # Already landed (a race — cmd_poll's own MERGED check normally wins first;
  # diagnose is defensive) → report MERGED so the caller goes to 4d, not recovery.
  if [ "$merged" = "true" ]; then
    jq -cn --argjson pr "$pr" --arg at "$mergedat" '{outcome:"MERGED", pr:$pr, mergedAt:$at}'
    return 0
  fi
  # Still enqueued → normally keep waiting; a slow queue is not a dequeue. But
  # "enqueued" alone cannot tell a SLOW queue from a STALLED one (temperloop#1178):
  # the incident's hand-run probe was exactly this — a healthy entry gets a
  # merge_group run on gh-readonly-queue/<base>/pr-<N>-<sha> within about a
  # minute of enqueue, while a stalled entry gets NONE however long it sits.
  # So: age the entry from mergeQueueEntry.enqueuedAt, and only once it is past
  # BUILD_QUEUE_STALL_AFTER spend the second request to count referencing
  # merge_group runs. Zero runs at that age ⇒ QUEUE_STALLED (stop waiting; this
  # needs a human). Under the threshold — or ANY referencing run, however old —
  # stays QUEUED, so the ~2.5 min a queue's own checks legitimately take can
  # never trip this (that window is the whole reason "is it enqueued?" alone is
  # useless). An unparseable/absent enqueuedAt also stays QUEUED: fail safe,
  # never manufacture a stall from a timestamp we could not read.
  if [ -n "$qstate" ]; then
    local enq_epoch enqueued_secs mg_raw mg_count
    enq_epoch="$(_gate_epoch_of "$enqueued_at")"
    if [ -n "$enq_epoch" ]; then
      enqueued_secs=$(( $(_gate_now) - enq_epoch ))
      # Clock skew between the API stamp and this host must never read negative.
      if [ "$enqueued_secs" -lt 0 ]; then enqueued_secs=0; fi
      if [ "$enqueued_secs" -ge "${BUILD_QUEUE_STALL_AFTER:-600}" ]; then
        mg_raw="$(_gate_gh api "repos/$owner_repo/actions/runs?event=merge_group&per_page=100" 2>&1)" \
          || die "merge_group run query failed for #$pr: $mg_raw"
        mg_count="$(jq --arg n "$pr" \
              '[.workflow_runs[]? | select((.head_branch // "") | test("/pr-" + $n + "-"))] | length' \
              <<<"$mg_raw" 2>/dev/null)" \
          || die "unparseable merge_group run response for #$pr"
        if [ "${mg_count:-0}" -eq 0 ]; then
          jq -cn --argjson pr "$pr" --argjson secs "$enqueued_secs" \
            '{outcome:"QUEUE_STALLED", pr:$pr, enqueued_secs:$secs, merge_group_runs:0}'
          return 10
        fi
      fi
    fi
    jq -cn --argjson pr "$pr" --arg s "$qstate" '{outcome:"QUEUED", pr:$pr, queueState:$s}'
    return 0
  fi

  # Channel 2 — REST merge_group runs: WHY did it leave the queue? The anchored
  # substring `/pr-<N>-` avoids #4 matching a #42/#420 trial branch; latest by
  # created_at.
  local raw run conclusion status run_id
  raw="$(_gate_gh api "repos/$owner_repo/actions/runs?event=merge_group&per_page=100" 2>&1)" \
    || die "merge_group run query failed for #$pr: $raw"
  run="$(jq -c --arg n "$pr" \
        '[.workflow_runs[]? | select((.head_branch // "") | test("/pr-" + $n + "-"))]
         | sort_by(.created_at) | last' <<<"$raw" 2>/dev/null)" \
    || die "unparseable merge_group run response for #$pr"

  # No merge_group run references this PR → entry dropped during queue churn.
  if [ "$run" = "null" ] || [ -z "$run" ]; then
    jq -cn --argjson pr "$pr" '{outcome:"DEQUEUED", pr:$pr}'
    return 8
  fi
  conclusion="$(jq -r '.conclusion // ""' <<<"$run" 2>/dev/null || echo "")"
  status="$(jq -r '.status // ""' <<<"$run" 2>/dev/null || echo "")"
  run_id="$(jq -r '.id // empty' <<<"$run" 2>/dev/null || echo "")"

  if [ "$conclusion" = "failure" ]; then
    jq -cn --argjson pr "$pr" --argjson rid "${run_id:-null}" \
      '{outcome:"MERGE_GROUP_FAILED", pr:$pr, run_id:$rid}'
    return 7
  fi
  # A referencing run still building (not yet concluded) → not a dequeue; wait.
  if [ -n "$status" ] && [ "$status" != "completed" ]; then
    jq -cn --argjson pr "$pr" --arg s "merge_group:$status" \
      '{outcome:"QUEUED", pr:$pr, queueState:$s}'
    return 0
  fi
  # A completed non-failure run but the PR is neither queued nor merged → the
  # entry was dropped; re-arm.
  jq -cn --argjson pr "$pr" '{outcome:"DEQUEUED", pr:$pr}'
  return 8
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
# merge-order policy into the machinery).
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
# are the zero-delay test settings for this command's two poll loops — mirrors
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
    diagnose-queue) [ $# -eq 2 ] || usage; cmd_diagnose_queue "$1" "$2" ;;
    *) usage ;;
  esac
fi
