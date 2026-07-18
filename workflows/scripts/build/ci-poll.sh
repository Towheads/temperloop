#!/usr/bin/env bash
#
# build CI poll — the deterministic-spine script that owns the 3g
# CI-monitoring step of /build (epic #253, spike #245). Watching a PR's
# check-runs to completion is a pure function of observable machine state with
# a closed outcome set, so it moves from prose in build.md to code here.
# CI-failure *diagnosis* (flake vs real, what to tell the re-spawn) stays an
# LLM seat — this script reports WHAT failed, never decides what to do about it.
#
#   ci-poll.sh <owner>/<repo> <pr> [--sha <sha>] [--interval <secs>] [--timeout <secs>]
#              [--exit-nonzero-on-failure]
#
# Polls the PR head SHA's check-runs over REST (`gh api`, core bucket) — NEVER
# `gh pr checks --watch`, which is GraphQL-backed and burns the scarce
# Projects-v2-shared GraphQL bucket (GH #53). The head SHA is resolved ONCE
# from the PR unless --sha pins it explicitly.
#
# On a re-poll right after a FORCE-PUSH, passing --sha <the just-pushed SHA> is
# REQUIRED, not optional: the `pulls/{pr}` object can lag and still report the
# stale pre-push head, whose check-runs are already green from the prior run, so
# the auto-resolve would yield a FALSE green on un-CI'd code (#254). The caller
# already knows the authoritative SHA (it just pushed it) — pin it.
#
# Defaults: --interval 30 (CI takes minutes; a tighter poll only burns rate
# budget — production callers should not go below 30; the flag exists mainly
# for tests), --timeout 3600. The timeout bounds the zero-check-runs edge: an
# unpushed or no-CI SHA never produces check-runs, and without a deadline the
# poll would spin forever (cf. build.md 3f-0.5 push-before-watch).
#
# Output contract — CLOSED outcome set, one structured JSON line, no prose
# (the orchestrator branches on `.outcome`, never parses prose):
#   {"outcome":"CI_GREEN","pr":…,"sha":…}                        exit 0
#   {"outcome":"CI_FAILED","pr":…,"sha":…,"failed_run_ids":[…]}  exit 0 (default) | exit 2 (--exit-nonzero-on-failure)
#   {"outcome":"TIMEOUT","pr":…,"sha":…,"waited":…}              exit 1
#   {"outcome":"ERROR","error":…}                                exit 1
# CI_FAILED exits 0 by DEFAULT on purpose: the poll itself succeeded — the
# verdict is data, not a script failure. Only TIMEOUT/ERROR (poll never
# completed) are non-zero by default. failed_run_ids come from `gh run list
# --commit <sha>` filtered to conclusion=="failure" (best-effort: an empty
# list, never a missing key).
#
# --exit-nonzero-on-failure (additive, opt-in): makes CI_FAILED exit 2
# instead of 0, while every other outcome/exit-code pairing above is
# unchanged. This exists so an &&-chained caller (e.g.
# `ci-poll.sh … --exit-nonzero-on-failure && gh pr merge …`) stops on a red
# PR instead of enqueueing it — without the flag, CI_FAILED's exit-0 "the
# poll succeeded" contract makes `&&` treat a red PR the same as a green one
# (#206). Exit 2 is deliberately distinct from TIMEOUT/ERROR's exit 1, so a
# caller inspecting the exit code (not just `.outcome`) can still tell
# "CI ran and failed" apart from "the poll itself never completed". Omit the
# flag and every existing caller's behavior — including the default exit
# code on CI_FAILED — is byte-for-byte unchanged.
#
# Transient-gh-hiccup retry (temperloop#386): both `gh api` calls below (the
# once-only head-SHA resolve and the per-poll check-runs query) go through
# gh_retry(), which absorbs a transient non-JSON body (an HTML/503 error
# page — the observed `invalid character '<' looking for beginning of value`
# failure during a 2026-07-16 GitHub API degradation) or any other single-call
# `gh` failure by retrying up to CI_POLL_API_MAX_ATTEMPTS times with a
# CI_POLL_API_RETRY_BACKOFF-second graduated backoff between attempts, rather
# than dying on the first hiccup. This keeps ci-poll.sh from surfacing a
# transient API blip as an immediate ERROR — which the orchestrator (build-
# level.mjs's ciPollLoop) treats the same as a genuine CI failure and
# escalates `ci-failed` on, per the caller contract documented above (any
# non-CI_GREEN/TIMEOUT/CI_FAILED outcome escalates). Only a call that fails
# CI_POLL_API_MAX_ATTEMPTS times in a row (a genuinely persistent outage, not
# a blip) still dies — legibly, with the retry count in the message and a
# `transient_retries_exhausted:true` field so a caller inspecting the ERROR
# payload (not just `.outcome`) can tell "gh/API never came back" apart from
# a hard argument/config error. The closed outcome set itself (CI_GREEN /
# CI_FAILED / TIMEOUT / ERROR) is unchanged — no new outcome was added.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

# fd 3 = the script's real stdout, so a die() inside a command substitution
# still reaches the orchestrator (same seam as worktree.sh).
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

# die_transient_exhausted() — same ERROR shape as die(), plus a
# transient_retries_exhausted:true field (temperloop#386) so a caller
# inspecting the payload can tell "gh/API stayed broken across every retry"
# apart from a hard/config ERROR that never got a retry at all. The closed
# `.outcome` enum itself is unchanged.
die_transient_exhausted() {
  jq -cn --arg error "$1" \
    '{outcome:"ERROR", error:$error, transient_retries_exhausted:true}' >&3
  exit 1
}

# gh_retry <description> <gh-argv...> — runs the given `gh` invocation,
# capturing combined stdout+stderr. On success, prints the captured output
# (via stdout) and returns 0 — the normal, silent, common-case path. On
# failure, retries the SAME invocation up to CI_POLL_API_MAX_ATTEMPTS times
# total, with a graduated CI_POLL_API_RETRY_BACKOFF*attempt-second sleep
# between attempts (mirrors board.sh's BOARD_CREATE_INDEX_RETRIES graduated-
# backoff shape), logging each retry to stderr so a flake stays visible
# rather than silently masked (same visibility stance as quality-gates.sh's
# GATE_MAX_ATTEMPTS). Exhausting every attempt calls die_transient_exhausted
# (never returns). This is what absorbs a transient non-JSON/HTTP-5xx `gh`
# hiccup (temperloop#386) instead of the caller escalating on the first one.
CI_POLL_API_MAX_ATTEMPTS="${CI_POLL_API_MAX_ATTEMPTS:-5}"
CI_POLL_API_RETRY_BACKOFF="${CI_POLL_API_RETRY_BACKOFF:-2}"
gh_retry() {
  local desc="$1"; shift
  local attempt=1 out
  while :; do
    if out="$("$@" 2>&1)"; then
      printf '%s' "$out"
      return 0
    fi
    if [ "$attempt" -ge "$CI_POLL_API_MAX_ATTEMPTS" ]; then
      die_transient_exhausted "$desc failed after $CI_POLL_API_MAX_ATTEMPTS attempts (temperloop#386): $out"
    fi
    printf '::: %s failed on attempt %d/%d — retrying (transient gh/API hiccup, temperloop#386): %s\n' \
      "$desc" "$attempt" "$CI_POLL_API_MAX_ATTEMPTS" "$out" >&2
    sleep "$(awk -v b="$CI_POLL_API_RETRY_BACKOFF" -v a="$attempt" 'BEGIN{print b*a}')"
    attempt=$((attempt + 1))
  done
}

usage() {
  die "usage: ci-poll.sh <owner>/<repo> <pr> [--sha <sha>] [--interval <secs>] [--timeout <secs>] [--exit-nonzero-on-failure]"
}

[ $# -ge 2 ] || usage
owner_repo="$1"
pr="$2"
shift 2

sha=""
interval=30
timeout=3600
exit_nonzero_on_failure=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sha)      [ $# -ge 2 ] || usage; sha="$2"; shift ;;
    --interval) [ $# -ge 2 ] || usage; interval="$2"; shift ;;
    --timeout)  [ $# -ge 2 ] || usage; timeout="$2"; shift ;;
    --exit-nonzero-on-failure) exit_nonzero_on_failure=1 ;;
    *) usage ;;
  esac
  shift
done

# Closed-set validation: these feed gh api paths and jq --argjson.
case "$owner_repo" in
  */*/*|*/|/*|"") die "owner/repo '$owner_repo' invalid — must be <owner>/<repo>" ;;
  */*) ;;
  *) die "owner/repo '$owner_repo' invalid — must be <owner>/<repo>" ;;
esac
case "$owner_repo" in
  *[!A-Za-z0-9_./-]*) die "owner/repo '$owner_repo' invalid — must be <owner>/<repo>" ;;
esac
case "$pr" in
  ""|*[!0-9]*) die "pr '$pr' invalid — must be a PR number" ;;
esac
case "$interval" in
  ""|.|*[!0-9.]*|*.*.*) die "interval '$interval' invalid — must be seconds (decimals ok)" ;;
esac
case "$timeout" in
  ""|*[!0-9]*) die "timeout '$timeout' invalid — must be whole seconds" ;;
esac
if [ -n "$sha" ]; then
  case "$sha" in
    *[!0-9a-fA-F]*) die "sha '$sha' invalid — must be a hex commit SHA" ;;
  esac
fi

# Resolve the head SHA once (REST). --sha skips this entirely. A transient
# gh/API hiccup here is absorbed by gh_retry (temperloop#386); only a
# persistent failure reaches die_transient_exhausted.
if [ -z "$sha" ]; then
  sha="$(gh_retry "head SHA resolve for PR #$pr" \
    gh api "repos/$owner_repo/pulls/$pr" --jq .head.sha)"
  [ -n "$sha" ] || die "PR #$pr resolved to an empty head SHA"
fi

deadline=$((SECONDS + timeout))
while :; do
  # A transient gh/API hiccup (non-JSON/HTTP-5xx body) here is absorbed by
  # gh_retry (temperloop#386) rather than dying on the first bad poll; only a
  # persistent failure reaches die_transient_exhausted.
  runs="$(gh_retry "check-runs query for $sha" \
    gh api "repos/$owner_repo/commits/$sha/check-runs" \
    --jq '[.check_runs[]|{status,conclusion}]')"
  n="$(jq length <<<"$runs")"
  pending="$(jq '[.[]|select(.status!="completed")]|length' <<<"$runs")"

  if [ "$n" -gt 0 ] && [ "$pending" -eq 0 ]; then
    if jq -e 'all(.[]; .conclusion|IN("success","neutral","skipped"))' <<<"$runs" >/dev/null; then
      jq -cn --argjson pr "$pr" --arg sha "$sha" '{outcome:"CI_GREEN", pr:$pr, sha:$sha}'
      exit 0
    fi
    # Resolve failed run ids over REST. Best-effort: a resolve hiccup yields
    # [], never blocks the CI_FAILED verdict itself.
    failed_ids="$(gh run list -R "$owner_repo" --commit "$sha" --json databaseId,conclusion \
        --jq '[.[]|select(.conclusion=="failure")|.databaseId]' 2>/dev/null)" || failed_ids="[]"
    jq -e . >/dev/null 2>&1 <<<"$failed_ids" || failed_ids="[]"
    jq -cn --argjson pr "$pr" --arg sha "$sha" --argjson ids "$failed_ids" \
      '{outcome:"CI_FAILED", pr:$pr, sha:$sha, failed_run_ids:$ids}'
    [ "$exit_nonzero_on_failure" -eq 1 ] && exit 2
    exit 0
  fi

  if [ "$SECONDS" -ge "$deadline" ]; then
    jq -cn --argjson pr "$pr" --arg sha "$sha" --argjson waited "$SECONDS" \
      '{outcome:"TIMEOUT", pr:$pr, sha:$sha, waited:$waited}'
    exit 1
  fi
  sleep "$interval"
done
