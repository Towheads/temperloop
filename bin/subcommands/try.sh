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
# --demo — THE ONE MUTATING EXCEPTION (foundation #765 Epic D, item
# foundation-try-demo). Passing --demo replaces everything above with a
# SEPARATE mode: the "aha moment" tick. It scratch-clones a disposable,
# already-seeded demo repo (kernel/workflows/scripts/demo/seed-demo-repo.sh
# maintains it; falsifiable one-file defects, `demo-seed`-labeled issues)
# and drives ONE real safe-tier funnel tick — issue -> PR — against it:
#   1. claims one open demo-seed issue via the issues-only tracker adapter
#      (kernel/workflows/scripts/board/lib/board.sh, board_backend=issues;
#      NO Projects-v2 board is ever provisioned — a throwaway scratch
#      boards.conf scoped to this run's own temp dir is all that exists);
#   2. gets a REAL, but still structurally zero-tool (--tools ""), live
#      `claude -p` judgment call to produce the ONE fixed file's corrected
#      content — the model never holds write access; this SCRIPT applies,
#      commits, and pushes the result;
#   3. opens the PR via kernel/workflows/scripts/proposal/proposal-pr.sh
#      (never a direct push — branch==base is structurally refused there).
# It stops at an OPENED pull request — never a merge (the safe/merging
# tier split, foundation #604's SAFE rung never merges).
# SPEND GUARD: prints a DIRECTIONAL cost estimate, requires an explicit y/N
# confirmation (or --yes — refused outright on a non-tty stdin with no
# --yes, so a curious stranger cannot silently burn spend), and enforces a
# hard cap via --demo-cap-usd (default $2.00 — DIRECTIONAL, an
# approval-time decision; tighten when real calibration exists) passed
# straight to the live call's --max-budget-usd. See run_demo()'s own
# header comment below for the full flow and the --demo-only flags.
#
# Usage:
#   try.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network]
#          [--timeout SECS] [--max-issues N]
#   try.sh --demo [--demo-repo OWNER/REPO] [--demo-cap-usd N] [--yes]
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
#   --demo               Enable --demo mode (see above); mutually exclusive
#                        in effect with every flag above (they're simply
#                        ignored once --demo is set — see run_demo()).
#   --demo-repo OWNER/REPO
#                        The scratch demo repo to clone + tick against.
#                        Default: the org's own pre-seeded scratch demo
#                        repo (see seed-demo-repo.sh's identical default).
#   --demo-cap-usd N     Hard mechanical spend cap (USD) for the demo
#                        tick's live judgment call. Default: 2.00.
#   --yes                Skip the interactive y/N confirmation (still
#                        prints the estimate + cap first). REQUIRED when
#                        stdin is not a tty.
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
# the skip-reason messages below), never the whole run. --demo mode
# REQUIRES both `gh` (authenticated) and `claude` — there is no degraded
# path for a mutating tick with a missing dependency.
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
: "${TRY_DEMO_TICK_LOW_USD:?cost-estimates.conf did not set TRY_DEMO_TICK_LOW_USD}"
: "${TRY_DEMO_TICK_HIGH_USD:?cost-estimates.conf did not set TRY_DEMO_TICK_HIGH_USD}"

# Non-flag-configurable — an LLM turn's natural latency is a different order
# of magnitude from a REST call's; see the --timeout doc comment above.
TRY_CLAUDE_TIMEOUT_SECS=180

# --demo's live judgment call gets its own, longer watchdog: it reads every
# tracked file in the (tiny) demo repo plus the issue body and emits a full
# corrected file, materially more work than the shadow-triage classification
# call above. Non-flag-configurable, same rationale as TRY_CLAUDE_TIMEOUT_SECS.
TRY_DEMO_CLAUDE_TIMEOUT_SECS=300

# Test-double seams (mirror funnel-drive.sh's CLAUDE_BIN / FUNNEL_GH_BIN
# convention) — never overridden in production use.
: "${CLAUDE_BIN:=claude}"
: "${TRY_GH_BIN:=gh}"

# ---------------------------------------------------------------------------
# run_demo — the --demo mode implementation (see the header comment above
# for the full flow/rationale). Defined here, ahead of CLI parsing, purely
# so the dispatch call right after argument parsing (below) can reach it —
# every variable it reads (demo_repo_flag / demo_cap_usd / demo_yes) is
# resolved at CALL time, once CLI parsing has actually run.
#
# Test-double seams (never overridden in production use):
#   TRY_DEMO_CLONE_URL   — the scratch clone's source URL. Default:
#                          https://github.com/<--demo-repo>.git (a plain
#                          HTTPS URL, not `gh repo clone` — this script runs
#                          `gh auth setup-git` first so gh's own credential
#                          helper backs a plain `git clone` regardless of
#                          the caller's global git_protocol setting; a
#                          curious stranger who authenticated `gh` but has
#                          no SSH key configured must not be stuck here).
#   TRY_DEMO_BOARD_NUM   — the throwaway internal board NUMBER used only as
#                          a scratch boards.conf key for this run's own temp
#                          dir. Default: 900. No real board of this (or any)
#                          number is ever read or written — see
#                          ISSUES-ONLY-BACKEND.md for the backend=issues axis.
#
# Return code is the function's own exit status (never `exit` inside this
# function — every path uses `return`, which is what lets the `trap ...
# RETURN` scratch-dir cleanup below fire on every path, success or failure).
run_demo() {
  local demo_repo board_lib proposal_pr scratch clone_dir conf issue_num item_id \
        title body host sess stamp foreign fix_json fix_path fix_content \
        manifest_file body_file branch pr_out outcome low high demo_reply \
        clone_out files_json prompt fix_rc BOARDS_CONF_REPO_LOCAL BOARDS_CONF_MACHINE

  demo_repo="${demo_repo_flag:-Towheads/foundation-kernel-demo}"  # denylist:allow — this repo's own scratch demo-repo default (mirrors seed-demo-repo.sh's identical default); a stranger overrides via --demo-repo
  : "${TRY_DEMO_CLONE_URL:=https://github.com/$demo_repo.git}"
  : "${TRY_DEMO_BOARD_NUM:=900}"

  case "$demo_cap_usd" in
    '' | *[!0-9.]*)
      echo "try --demo: --demo-cap-usd '$demo_cap_usd' is not a plain number" >&2
      return 1
      ;;
  esac

  board_lib="$KERNEL_ROOT/workflows/scripts/board/lib/board.sh"
  proposal_pr="$KERNEL_ROOT/workflows/scripts/proposal/proposal-pr.sh"
  if [ ! -f "$board_lib" ]; then
    echo "try --demo: board.sh not found at $board_lib (broken kernel checkout)" >&2
    return 1
  fi
  if [ ! -f "$proposal_pr" ]; then
    echo "try --demo: proposal-pr.sh not found at $proposal_pr (broken kernel checkout)" >&2
    return 1
  fi

  for bin in git "$TRY_GH_BIN" "$CLAUDE_BIN"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "try --demo: required tool '$bin' not found on PATH" >&2
      return 1
    fi
  done
  if ! "$TRY_GH_BIN" auth status >/dev/null 2>&1; then
    echo "try --demo: gh is installed but not authenticated (run: gh auth login)" >&2
    return 1
  fi

  echo "== foundation try --demo =="
  echo
  echo "!! MUTATING MODE: unlike the default zero-write taste above, --demo"
  echo "   clones $demo_repo to a scratch dir and opens a REAL pull request"
  echo "   against it (never a merge — see this file's --demo header comment)."
  echo

  echo "-- Spend guard --"
  low="$TRY_DEMO_TICK_LOW_USD"
  high="$TRY_DEMO_TICK_HIGH_USD"
  echo "Cost estimate (DIRECTIONAL — hardcoded constants, not a live pricing lookup;"
  echo "  see kernel/bin/lib/cost-estimates.conf): \$$low - \$$high for ONE real"
  echo "  safe-tier funnel tick (issue -> PR) against $demo_repo."
  echo "Hard spend cap for this run: \$$demo_cap_usd (--demo-cap-usd; enforced on the"
  echo "  live judgment call via --max-budget-usd — DIRECTIONAL, an approval-time"
  echo "  decision; tighten when real calibration exists)."
  echo

  if [ "$demo_yes" -ne 1 ]; then
    if [ ! -t 0 ]; then
      echo "try --demo: refusing to run non-interactively without --yes — a curious" >&2
      echo "  stranger must not silently burn API spend. Re-run with --yes to confirm." >&2
      return 1
    fi
    printf 'Proceed and spend up to $%s? [y/N] ' "$demo_cap_usd"
    read -r demo_reply
    case "$demo_reply" in
      y | Y | yes | YES) ;;
      *)
        echo "try --demo: aborted (no confirmation given)"
        return 0
        ;;
    esac
    echo
  fi

  scratch="$(mktemp -d "${TMPDIR:-/tmp}/foundation-try-demo.XXXXXX")" || {
    echo "try --demo: could not create a scratch dir" >&2
    return 1
  }
  # EXIT, not RETURN: sourcing board.sh below (`. "$board_lib"`) is ITSELF a
  # RETURN event in bash (a `source`/`.` completing fires RETURN exactly
  # like a function returning) — a RETURN trap here would fire the instant
  # board.sh finishes loading and delete the scratch dir (boards.conf and
  # all) before it's ever read. run_demo is always immediately followed by
  # `exit $?` at its one call site, so EXIT fires at the same real moment
  # RETURN was meant to, without the false-positive on sourcing.
  # shellcheck disable=SC2064  # $scratch is this run's own value; must expand now, not at trap-fire time
  trap "rm -rf '$scratch'" EXIT
  clone_dir="$scratch/repo"
  conf="$scratch/boards.conf"

  echo "-- 1. Scratch clone --"
  echo "Cloning $demo_repo -> $clone_dir"
  "$TRY_GH_BIN" auth setup-git >/dev/null 2>&1 || true
  if ! clone_out="$(git clone -q "$TRY_DEMO_CLONE_URL" "$clone_dir" 2>&1)"; then
    echo "try --demo: could not clone $demo_repo: $clone_out" >&2
    return 1
  fi
  echo

  cat > "$conf" <<EOF
board.$TRY_DEMO_BOARD_NUM.repo=$demo_repo
board.$TRY_DEMO_BOARD_NUM.backend=issues
EOF

  # shellcheck disable=SC2034  # read across the source boundary below by board.sh's _board_conf_file
  BOARDS_CONF_REPO_LOCAL="$conf"
  # shellcheck disable=SC2034  # read across the source boundary below by board.sh's _board_conf_file
  BOARDS_CONF_MACHINE="$scratch/no-such-machine-conf.never"
  # shellcheck source=../../workflows/scripts/board/lib/board.sh
  . "$board_lib"

  echo "-- 2. Claim one demo-seed issue (issues-only tracker adapter) --"
  if ! board_resolve "$TRY_DEMO_BOARD_NUM"; then
    echo "try --demo: could not read open issues on $demo_repo" >&2
    return 1
  fi
  issue_num="$(printf '%s' "$BOARD_ITEMS_JSON" | jq -r '
    [.items[] | select(.labels != null and (.labels | index("demo-seed")) != null
                        and ((has("host/Session")) | not))]
    | sort_by(.content.number) | .[0].content.number // empty')"

  if [ -z "$issue_num" ]; then
    echo "skipped — no available demo-seed issue on $demo_repo (every seeded issue is"
    echo "  either claimed or closed). Restore the fixed set with:"
    echo "  seed-demo-repo.sh --repo $demo_repo --reset"
    echo
    echo "foundation try --demo: done (no tick run)"
    return 0
  fi

  item_id="$(board_item_id "$issue_num")"
  title="$(board_item_title "$issue_num")"
  host="$(hostname -s 2>/dev/null || echo host)"
  sess="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -n "$sess" ]; then stamp="${host}:${sess:0:8}"; else stamp="${host}:demo"; fi

  if foreign="$(board_claim_contended "$TRY_DEMO_BOARD_NUM" "$issue_num" "$stamp")"; then
    echo "try --demo: #$issue_num is already claimed by [$foreign] — try again" >&2
    return 1
  fi

  if ! board_stamp "$item_id" "$BOARD_FIELD_HOSTSESSION" "$stamp"; then
    echo "try --demo: could not stamp #$issue_num" >&2
    return 1
  fi
  if ! board_set_status "$item_id" "$BOARD_OPT_INPROGRESS"; then
    echo "try --demo: could not claim #$issue_num" >&2
    return 1
  fi
  echo "Claimed #$issue_num — $title  [$stamp]"
  echo

  body="$("$TRY_GH_BIN" issue view "$issue_num" -R "$demo_repo" --json body -q '.body' 2>/dev/null || true)"

  echo "-- 3. Live judgment call (real claude -p, --tools \"\" — zero tool access;"
  echo "      this script applies the output, the model never writes anything) --"
  files_json="$(
    cd "$clone_dir" && git ls-files | while IFS= read -r f; do
      [ -f "$f" ] || continue
      jq -n --arg p "$f" --arg c "$(cat "$f")" '{path:$p, content:$c}'
    done | jq -s '.'
  )"

  prompt="$(cat <<PROMPT_EOF
You are producing a SAFE-TIER, single-issue code fix for the scratch demo
repo $demo_repo. You have NO tools (--tools ""); you cannot write anything
yourself — your ONLY output is the corrected file content, applied by the
calling script, never by you.

Issue #$issue_num: $title

$body

Below is every tracked file in the repo (path + full current content). Fix
ONLY what the issue above describes, in the ONE file it names, with the
SMALLEST correct change — every other line (and every other file) must
stay byte-identical.

$(printf '%s' "$files_json" | jq -r '.[] | "--- path: \(.path) ---\n\(.content)\n"')

Output ONLY a single JSON object on stdout, nothing else — no markdown
fences, no commentary:
{"path": "<repo-relative path of the ONE file you fixed>", "content": "<its full corrected content>"}
PROMPT_EOF
)"

  # No `set -e` toggle here (unlike step 3's shadow-triage call above): this
  # script's top-level mode is `-uo pipefail` only (`-e` was never on), and
  # turning it on here would abort the function uncontrolled the moment a
  # later command substitution (e.g. `jq` on a malformed judgment-call
  # response) returns non-zero — exactly the case the explicit `fix_rc` /
  # `fix_path` checks below exist to handle gracefully.
  fix_json="$(_try_run_with_timeout "$TRY_DEMO_CLAUDE_TIMEOUT_SECS" \
    "$CLAUDE_BIN" -p "$prompt" \
    --tools "" \
    --output-format text \
    --no-session-persistence \
    --max-budget-usd "$demo_cap_usd" \
    2>/dev/null)"
  fix_rc=$?

  if [ "$fix_rc" -ne 0 ]; then
    echo "try --demo: live judgment call failed (exit $fix_rc) — #$issue_num left claimed" >&2
    return 1
  fi

  fix_path="$(printf '%s' "$fix_json" | jq -r '.path // empty' 2>/dev/null)"
  fix_content="$(printf '%s' "$fix_json" | jq -r 'if has("content") then .content else empty end' 2>/dev/null)"
  if [ -z "$fix_path" ]; then
    echo "try --demo: could not parse a fix from the judgment call's output — #$issue_num left claimed" >&2
    echo "  raw output: $fix_json" >&2
    return 1
  fi
  echo "Fix: $fix_path"
  echo

  echo "-- 4. Open the PR (proposal-pr.sh — never a direct push) --"
  manifest_file="$scratch/manifest.json"
  jq -n --arg p "$fix_path" --arg c "$fix_content" '[{path:$p, content:$c}]' > "$manifest_file"

  body_file="$scratch/pr-body.md"
  {
    echo "Fix for \`$demo_repo\` issue #$issue_num, opened by \`foundation try --demo\`"
    echo "(foundation-kernel's newcomer demo tick — one real, safe-tier issue -> PR"
    echo "pass; the fix content came from a live \`claude -p\` call run with"
    echo "\`--tools \"\"\` — structurally zero tool access — so this script, not the"
    echo "model, applied/committed/pushed it)."
    echo
    echo "$body"
    echo
    echo "Closes #$issue_num"
  } > "$body_file"

  branch="demo/issue-$issue_num"
  if ! pr_out="$(bash "$proposal_pr" open --repo-dir "$clone_dir" --branch "$branch" \
      --title "fix: $title" --body-file "$body_file" \
      --files-manifest "$manifest_file" 2>&1)"; then
    echo "try --demo: proposal-pr.sh failed: $pr_out" >&2
    return 1
  fi

  outcome="$(printf '%s' "$pr_out" | jq -r '.outcome // "ERROR"' 2>/dev/null)"
  case "$outcome" in
    PR_OPENED | EXISTS)
      echo "PR: $(printf '%s' "$pr_out" | jq -r '.url')"
      ;;
    NO_CHANGES)
      echo "try --demo: the judgment call's fix produced no diff against $demo_repo's"
      echo "  base — nothing to propose. #$issue_num left claimed; try again."
      return 1
      ;;
    *)
      echo "try --demo: proposal-pr.sh reported $outcome: $pr_out" >&2
      return 1
      ;;
  esac

  echo
  echo "foundation try --demo: done — #$issue_num -> $outcome"
  echo "  (safe-tier boundary: PR opened, never merged. Issue left In Progress on"
  echo "  the scratch tracker — no board was provisioned. Restore the fixed seed"
  echo "  set any time with: seed-demo-repo.sh --repo $demo_repo --reset)"
  return 0
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
usage: try.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network]
              [--timeout SECS] [--max-issues N]
       try.sh --demo [--demo-repo OWNER/REPO] [--demo-cap-usd N] [--yes]
EOF
}

try_dir="."
gh_repo_flag=""
no_network=0
try_timeout=10
max_issues=20
demo_mode=0
demo_repo_flag=""
demo_cap_usd="2.00"
demo_yes=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) try_dir="${2:?--dir needs a value}"; shift 2 ;;
    --gh-repo) gh_repo_flag="${2:?--gh-repo needs a value}"; shift 2 ;;
    --no-network) no_network=1; shift ;;
    --timeout) try_timeout="${2:?--timeout needs a value}"; shift 2 ;;
    --max-issues) max_issues="${2:?--max-issues needs a value}"; shift 2 ;;
    --demo) demo_mode=1; shift ;;
    --demo-repo) demo_repo_flag="${2:?--demo-repo needs a value}"; shift 2 ;;
    --demo-cap-usd) demo_cap_usd="${2:?--demo-cap-usd needs a value}"; shift 2 ;;
    --yes) demo_yes=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "try.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "try.sh: jq not found on PATH" >&2
  exit 1
fi

if [ "$demo_mode" -eq 1 ]; then
  run_demo
  exit $?
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
