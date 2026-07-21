#!/usr/bin/env bash
#
# pr-linkage.sh — SOURCED helper exposing the shared open-PR-by-linkage probe
# (temperloop #635, spike verdict [[Decisions/temperloop - fix-driver
# state-resolution seams (spike verdict)]]).
#
# THIS IS THE SINGLE HOME FOR NEW CALLERS of the open-PR-by-closing-linkage
# probe. `workflows/scripts/build/issue-state.sh`'s `resolve` subcommand is
# the first (and, at the time this file was added, only) caller. Two OTHER
# copies of this exact mechanism are KNOWINGLY RETAINED elsewhere and are NOT
# touched by this file's introduction:
#
#   - funnel-tick.sh:646   `open_pr_for_issue`   (3-arg: board, repo, issue;
#     carries its own DRY_RUN/$FIXTURE fixture branch)
#   - funnel-drive.sh:675  `_open_pr_for_issue`  (2-arg: repo, issue; uses the
#     $FUNNEL_GH_BIN test-double seam; declared canonical of the two funnel
#     copies)
#
# Their retirement onto this shared lib is tracked in temperloop #628 (the
# existing funnel/sweep convergence issue) — NOT re-done here. Do not edit
# funnel-tick.sh or funnel-drive.sh from this file's introduction.
#
# Mechanism (byte-identical to both existing copies): `gh pr list -R <repo>
# --state open --json number,body --limit 100` — a DIRECT listing, never
# `--search` (GitHub's search index lags a just-opened PR by
# seconds-to-minutes; a direct listing sees it immediately) — then a
# client-side jq `test()` against the case-insensitive closing-keyword regex
# `(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#<n>\b` on each PR's body.
#
# GENERALIZATION over the two existing copies: both existing copies return
# only the FIRST matching PR number (`.[0] // empty`) — silently taking the
# first when more than one open PR closes the same issue. This shared
# function instead prints EVERY matching PR number, one per line (newline-
# separated, oldest-listed-first per `gh pr list`'s own order), so a caller
# that cares about ambiguity (e.g. `issue-state.sh resolve`'s `ambiguous`
# route) can detect it — a caller that wants the old take-the-first behavior
# simply reads the first line.
#
# Parameterized for BOTH existing funnel call sites to adopt later without a
# behavior change:
#   - `${FUNNEL_GH_BIN:-gh}` — the gh-binary test-double seam funnel-drive.sh
#     already uses (FUNNEL_GH_BIN, registered in the kernel knob registry).
#   - DRY_RUN / $FIXTURE — mirrors funnel-tick.sh's own fixture branch
#     (read funnel-tick.sh:646-660). Fixture file: $FIXTURE/open-pr-<issue>.txt
#     — one PR number per line (a bare int per line; non-digit lines are
#     dropped), file absent/empty → no linked PR found. Unlike funnel-tick's
#     board-scoped fixture path, this shared probe is not board-scoped (a
#     bare issue-number probe has no board argument) — a future funnel-tick
#     adoption can still point $FIXTURE at a board-scoped subdirectory.
#
# Fail-open: any gh/jq error, or an empty/missing response, prints nothing
# and returns 0 — a transient probe failure must never look like "definitely
# no linked PR" to a caller that treats absence as license to act (it is
# the caller's job to decide what "nothing printed" means for its own route).
#
# This file is SOURCED — it sets no shell options (the caller owns
# `set -euo pipefail`); every function here is written to behave under `set -u`.

# open_pr_for_issue <repo> <issue>
#
# Prints every OPEN PR number (one per line) whose body closes <issue> via a
# bare `Closes #<issue>` / `Fixes #<issue>` / `Resolves #<issue>` (any tense,
# case-insensitive) reference. Prints nothing if none found. Always returns 0
# (fail-open; see file header).
#
# Contract (matches funnel-tick.sh's own DRY_RUN/FIXTURE convention exactly):
# the CALLER declares plain `DRY_RUN=0` / `FIXTURE=""` globals (never a
# registry-shaped `:=`/`:-` knob seam — this is deliberate, see the caller's
# own header) before sourcing this file / calling this function. This lib
# reads them bare, not with a `:-` fallback, so it never introduces its own
# knob-registry-shaped seam for a variable it does not own the default of.
open_pr_for_issue() {  # $1=repo  $2=issue
  local repo="$1" issue="$2" json
  if [ "$DRY_RUN" -eq 1 ]; then
    local f="$FIXTURE/open-pr-$issue.txt"
    if [ -f "$f" ]; then
      grep -oE '[0-9]+' "$f" || true
    fi
    return 0
  fi
  json="$("${FUNNEL_GH_BIN:-gh}" pr list -R "$repo" --state open \
            --json number,body --limit 100 2>/dev/null)" || return 0
  [ -z "$json" ] && return 0
  jq -r --arg n "$issue" '
    [ .[]? | select((.body // "")
        | test("(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#" + $n + "\\b"))
      | .number ] | .[]' <<<"$json" 2>/dev/null || return 0
}
