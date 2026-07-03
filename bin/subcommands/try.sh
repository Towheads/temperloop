#!/usr/bin/env bash
# description: probe + shadow triage of open issues + directional cost estimate (zero writes)
#
# try.sh — `foundation try`: the zero-config, zero-write taste (foundation
# #765 Epic D "newcomer experience", item foundation-try / #852).
#
# On a repo the CLI has never seen, in order:
#   1. Run the read-only conventions probe (kernel/workflows/scripts/probe/
#      conventions-probe.sh) in its normal stdout mode and print the result.
#   2. List OPEN issues (read-only `gh issue list`) and print a DIRECTIONAL
#      cost estimate for classifying them — hardcoded constants from
#      kernel/bin/lib/cost-estimates.conf × open-issue count. Printed
#      BEFORE step 3 runs, so "zero writes" (this script never mutates
#      anything) is never misread as "zero cost" (step 3 is a real, billed
#      LLM call).
#   3. Drive a REAL, read-only/dry-run `claude -p` shadow-triage
#      classification of those issues on the user's OWN Claude Code auth —
#      the actual triage judgment (cull / collapse / group / prioritize),
#      not a parallel shell-heuristic reimplementation of it. The call is
#      invoked with --tools "" (every built-in tool disabled), which is a
#      STRUCTURAL guarantee of zero writes/mutations independent of
#      anything the prompt says or the model decides — see
#      "ZERO WRITES" below.
#
# ZERO WRITES, ALWAYS:
#   - No `gh` mutation is ever issued (no issue/label/comment/PR create,
#     edit, or close) — only `gh issue list` / `gh repo view`-shaped reads.
#   - The shadow-triage `claude -p` call runs with --tools "" (no Bash, no
#     Edit/Write, no MCP tools — nothing that could touch a filesystem or
#     an API) and --no-session-persistence (no session transcript written).
#   - This script itself never creates, moves, or deletes a file anywhere —
#     not even a self-cleaning scratch temp file; every intermediate value
#     lives in a shell variable via command substitution.
#   - See kernel/bin/subcommands/tests/test_try.sh for the write-
#     intercepting-wrapper proof (a fake `gh`/`claude` on PATH that logs
#     every call it sees, plus a before/after file-tree diff of the target
#     repo).
#
# Usage:
#   try.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network]
#          [--timeout SECS] [--max-issues N]
#
#   --dir DIR            Git checkout to try. Default: current directory.
#   --gh-repo OWNER/REPO GitHub slug. Default: inferred by the probe from
#                        the DIR's origin remote.
#   --no-network         Offline mode: forwarded to the probe (its two
#                        network-gated sections report unavailable) AND
#                        skips the open-issue listing + shadow triage
#                        entirely (both are network/cost operations) —
#                        prints a skip reason for each instead.
#   --timeout SECS       Per-network-call watchdog, forwarded to the probe
#                        and reused for this script's own `gh issue list`
#                        call. Default: 10. (The shadow-triage LLM call
#                        gets its own, much longer, non-flag-configurable
#                        watchdog — see TRY_CLAUDE_TIMEOUT_SECS below; an
#                        LLM turn routinely takes far longer than a REST
#                        call and conflating the two watchdogs would make
#                        one of them wrong.)
#   --max-issues N       Cap on how many open issues are fed into the
#                        shadow-triage prompt (the cost ESTIMATE always
#                        covers the full open-issue count regardless of
#                        this cap — see step 2). Default: 20.
#
# Exit codes:
#   0   ran to completion (even if the shadow triage or issue listing was
#       gracefully skipped — a legible skip reason is not a failure).
#   1   fatal usage/environment error (propagated from the probe, or this
#       repo's own lib files are missing) — mirrors conventions-probe.sh.
#   2   invalid CLI usage.
#
# Dependencies: bash (3.2+), git, jq (both required by the probe this
# script always invokes). `gh` and `claude` are each independently
# optional — their absence degrades only the sections that need them (see
# the skip-reason messages below), never the whole run.
#
# shellcheck shell=bash

set -uo pipefail

# ---------------------------------------------------------------------------
# _try_run_with_timeout SECS cmd... — portable bash-3.2-safe watchdog (no
# `timeout` binary assumed present). Mirrors conventions-probe.sh's helper
# of the same shape (itself mirroring scripts/kernel-drift-check.sh).
# ---------------------------------------------------------------------------
#
# NOTE (fixes a latent pipe-leak this helper's upstream sibling carries —
# conventions-probe.sh's _probe_run_with_timeout, foundation #765): the
# watchdog subshell below is explicitly redirected to /dev/null at the
# subshell boundary (`) </dev/null >/dev/null 2>&1 &`), NOT left to inherit
# this function's stdout. Without that redirect, when this whole call sits
# inside a command substitution (`out="$(_try_run_with_timeout ...)"`), the
# watchdog's `sleep $secs` child inherits the substitution's pipe write-end
# too — and even after the fast path kills the watchdog PROCESS below, that
# orphaned `sleep` grandchild keeps running and keeps the pipe open, so the
# command substitution can't see EOF until the full $secs elapses regardless
# of how fast the real command finished. That turns every fast, successful
# call into a full-timeout-length stall — silent and easy to miss because
# small `--timeout` values in tests hide it as "a bit slow", not "hung".
# See kernel/bin/subcommands/tests/test_try.sh's fast-path timing assertion.
_try_run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs" 2>/dev/null; kill -9 "$cmd_pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  local watchdog_pid=$!
  local status
  wait "$cmd_pid" 2>/dev/null
  status=$?
  kill "$watchdog_pid" 2>/dev/null
  wait "$watchdog_pid" 2>/dev/null
  return "$status"
}

# ---------------------------------------------------------------------------
# Locate sibling kernel content. try.sh lives at kernel/bin/subcommands/ —
# the probe and the cost-estimate constants are pinned, stable sibling
# paths under the same kernel/ physical tree (see the epic plan note's
# "## Repo targeting": "New CLI paths are pinned so items don't collide").
# ---------------------------------------------------------------------------
SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
KERNEL_ROOT="$(cd "$BIN_DIR/.." && pwd)"
PROBE="$KERNEL_ROOT/workflows/scripts/probe/conventions-probe.sh"
COST_CONF="$BIN_DIR/lib/cost-estimates.conf"

if [ ! -f "$PROBE" ]; then
  echo "try.sh: conventions-probe.sh not found at $PROBE (broken kernel checkout)" >&2
  exit 1
fi
if [ ! -f "$COST_CONF" ]; then
  echo "try.sh: cost-estimates.conf not found at $COST_CONF (broken kernel checkout)" >&2
  exit 1
fi
# shellcheck source=../lib/cost-estimates.conf
. "$COST_CONF"
: "${TRY_COST_PER_ISSUE_LOW_USD:?cost-estimates.conf did not set TRY_COST_PER_ISSUE_LOW_USD}"
: "${TRY_COST_PER_ISSUE_HIGH_USD:?cost-estimates.conf did not set TRY_COST_PER_ISSUE_HIGH_USD}"
: "${TRY_CLAUDE_MAX_BUDGET_USD:?cost-estimates.conf did not set TRY_CLAUDE_MAX_BUDGET_USD}"

# Non-flag-configurable — an LLM turn's natural latency is a different order
# of magnitude from a REST call's; see the --timeout doc comment above.
TRY_CLAUDE_TIMEOUT_SECS=180

# Test-double seams (mirror funnel-drive.sh's CLAUDE_BIN / FUNNEL_GH_BIN
# convention) — never overridden in production use.
: "${CLAUDE_BIN:=claude}"
: "${TRY_GH_BIN:=gh}"

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
usage: try.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network]
              [--timeout SECS] [--max-issues N]
EOF
}

try_dir="."
gh_repo_flag=""
no_network=0
try_timeout=10
max_issues=20

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) try_dir="${2:?--dir needs a value}"; shift 2 ;;
    --gh-repo) gh_repo_flag="${2:?--gh-repo needs a value}"; shift 2 ;;
    --no-network) no_network=1; shift ;;
    --timeout) try_timeout="${2:?--timeout needs a value}"; shift 2 ;;
    --max-issues) max_issues="${2:?--max-issues needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "try.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "try.sh: jq not found on PATH" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1 — the conventions probe (stdout mode). Forward every flag it
# understands; this script adds no probe behavior of its own.
# ---------------------------------------------------------------------------
probe_args=(--dir "$try_dir" --timeout "$try_timeout")
[ -n "$gh_repo_flag" ] && probe_args+=(--gh-repo "$gh_repo_flag")
[ "$no_network" -eq 1 ] && probe_args+=(--no-network)

echo "== foundation try =="
echo
echo "-- 1. Conventions probe (read-only) --"
probe_out="$(bash "$PROBE" "${probe_args[@]}")"
probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
  # Probe already printed its own error to stderr; propagate its exit code
  # verbatim (1 = env error, 2 = usage error) rather than re-wrapping it.
  exit "$probe_rc"
fi
echo "$probe_out" | jq '.'
echo

gh_repo="$(echo "$probe_out" | jq -r '.repo.gh_repo // empty')"

# ---------------------------------------------------------------------------
# Step 2 — open-issue count + directional cost estimate, printed BEFORE any
# LLM call (see this file's header). The estimate always covers the FULL
# open-issue count; --max-issues only bounds what step 3 puts in a prompt.
# ---------------------------------------------------------------------------
echo "-- 2. Open issues + cost estimate (before any LLM call) --"

issues_json="[]"
issues_reason=""
have_gh=0
command -v "$TRY_GH_BIN" >/dev/null 2>&1 && have_gh=1

# issues_reason (and, further down, triage_reason) carries the BARE reason
# text — never pre-prefixed with "skipped —" — so every print site below
# adds that prefix exactly once, regardless of which site does the printing.
if [ "$no_network" -eq 1 ]; then
  issues_reason="network disabled (--no-network)"
elif [ "$have_gh" -ne 1 ]; then
  issues_reason="gh CLI not found on PATH"
elif [ -z "$gh_repo" ]; then
  issues_reason="could not determine a GitHub owner/repo (no --gh-repo, no github.com origin remote)"
elif ! "$TRY_GH_BIN" auth status >/dev/null 2>&1; then
  issues_reason="gh is installed but not authenticated (run: gh auth login)"
fi

if [ -z "$issues_reason" ]; then
  # Hard ceiling of 1000 open issues counted — a documented, generous cap
  # (not a silent truncation a caller could mistake for the true total).
  out=""
  if out="$(_try_run_with_timeout "$try_timeout" \
      "$TRY_GH_BIN" issue list -R "$gh_repo" --state open --limit 1000 \
      --json number,title,url,labels,body 2>/dev/null)"; then
    issues_json="$out"
  else
    rc=$?
    if [ "$rc" -eq 137 ]; then
      issues_reason="gh issue list timed out after ${try_timeout}s"
    else
      issues_reason="gh issue list failed (auth, network, or permissions)"
    fi
  fi
fi

issue_count="$(echo "$issues_json" | jq 'length')"

if [ -n "$issues_reason" ]; then
  echo "Open issues: unavailable (skipped — $issues_reason)"
  echo "Cost estimate: unavailable — no open-issue count to multiply against"
else
  low="$(awk -v n="$issue_count" -v c="$TRY_COST_PER_ISSUE_LOW_USD" 'BEGIN { printf "%.2f", n * c }')"
  high="$(awk -v n="$issue_count" -v c="$TRY_COST_PER_ISSUE_HIGH_USD" 'BEGIN { printf "%.2f", n * c }')"
  echo "Open issues: $issue_count"
  echo "Cost estimate (DIRECTIONAL — hardcoded constants, not a live pricing lookup;"
  echo "  see kernel/bin/lib/cost-estimates.conf): \$$low - \$$high for a shadow-triage"
  echo "  classification pass over all $issue_count open issue(s)."
fi
echo

# ---------------------------------------------------------------------------
# Step 3 — shadow triage: a REAL claude -p call, --tools "" (structurally
# zero tool access -> zero writes/mutations regardless of prompt or model
# behavior), read-only judgment only. Skipped gracefully with the same
# issues_reason if step 2 couldn't produce an issue list, or if `claude`
# itself is missing.
# ---------------------------------------------------------------------------
echo "-- 3. Shadow triage (live LLM call, read-only dry run, zero writes) --"

triage_reason="$issues_reason"
if [ -z "$triage_reason" ] && [ "$issue_count" -eq 0 ]; then
  triage_reason="no open issues to triage"
fi
if [ -z "$triage_reason" ] && ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  triage_reason="claude CLI not found on PATH"
fi

if [ -n "$triage_reason" ]; then
  echo "skipped — $triage_reason"
  echo
  echo "foundation try: done (zero writes)"
  exit 0
fi

sample_json="$(echo "$issues_json" | jq --argjson n "$max_issues" '.[0:$n]')"
sample_count="$(echo "$sample_json" | jq 'length')"

prompt_issues="$(echo "$sample_json" | jq -r '
  .[] | "#\(.number) \(.title)\n" +
        (if (.body // "") == "" then "  (no body)\n" else "  " + ((.body // "") | .[0:300] | gsub("\n"; " ")) + "\n" end)
')"

prompt="$(cat <<PROMPT_EOF
You are running a SHADOW / DRY-RUN triage pass for the repo $gh_repo. This
is read-only: you have NO tools available (--tools ""). Do not attempt to
create, edit, comment on, close, or otherwise mutate anything — you
structurally cannot, and you must not narrate as if you did. Your ONLY job
is to produce a text report of what a real /triage run would decide.

Apply this decision tree to each issue below, in order:
1. Cull — flag issues that read as dupe / won't-fix / stale / already-fixed.
2. Root-cause collapse — group issues whose titles/bodies suggest they trace
   to one shared underlying cause.
3. Group-by-meaning — cluster the survivors by theme/shared root cause
   (never by "touches the same file").
4. Priority — order the surviving groups/singletons by apparent value.
5. Work-class — for each survivor, guess Operational (bug fix, follow-up,
   established pattern) or Foundational (new capability, architectural
   change) per the default-to-Operational rule.

Showing $sample_count of $issue_count open issue(s):

$prompt_issues

Output a concise "here is what I would do" report: cull list (+ reason),
proposed groups (+ one-line shared meaning), priority order, and each
survivor's Operational/Foundational guess. Prefix the report with one line
noting this is a SHADOW/DRY-RUN result with zero writes performed.
PROMPT_EOF
)"

set +e
triage_out="$(_try_run_with_timeout "$TRY_CLAUDE_TIMEOUT_SECS" \
  "$CLAUDE_BIN" -p "$prompt" \
  --tools "" \
  --output-format text \
  --no-session-persistence \
  --max-budget-usd "$TRY_CLAUDE_MAX_BUDGET_USD" \
  2>/dev/null)"
triage_rc=$?
set -e

if [ "$triage_rc" -ne 0 ]; then
  if [ "$triage_rc" -eq 137 ]; then
    echo "skipped — claude shadow-triage call timed out after ${TRY_CLAUDE_TIMEOUT_SECS}s"
  else
    echo "skipped — claude shadow-triage call failed (exit $triage_rc)"
  fi
else
  echo "$triage_out"
fi

echo
echo "foundation try: done (zero writes)"
exit 0
