#!/usr/bin/env bash
#
# test_reviewer_seat_tiers.sh — the model-tier invariant for the review seats
# /build §3e spawns (temperloop#1456, epic #1616).
#
# WHY THIS EXISTS. `runReviewers()` in claude/workflows/build-level.mjs spawns
# each routed reviewer with NO `model` override, on the stated reasoning that
# "the reviewer's OWN agent definition sets its tier". That reasoning is only
# sound while every one of those definitions actually DECLARES a tier: a
# charter declaring `model: inherit` takes whichever model the CALLING context
# runs under, and an autonomous drive runs cheap by design
# ($PIPELINE_DRIVE_MODEL). `architecture-reviewer` declared exactly that while
# its own prose promised the seat is "never down-tiered" — two statements
# standing in disagreement, with nothing mechanical between them. Nothing
# errored; the review would simply have run weaker than designed, invisibly, on
# precisely the `kind: architectural` items the seat exists to protect.
#
# The gap this closes is a MEASUREMENT gap, which is epic #1616's whole theme:
# the tier a seat resolves to is not observable from any artifact the pipeline
# produces, so a silent down-tier leaves no trace to notice later. The
# declaration is the only place it can be checked, so it is checked here.
#
# WHAT IT ASSERTS (each case is one property, not one file):
#   1. architecture-reviewer declares an explicit tier — never `inherit`.
#   2. Its charter prose names the tier its frontmatter actually declares, and
#      no longer claims the session model (the doc-vs-mechanism disagreement,
#      restated as the property rather than as a banned string).
#   3. The three sibling §3e reviewers still declare `sonnet` — the no-op
#      assertion: whatever fixes case 1 must not move them.
#   4. runReviewers() passes no `model` override anywhere in its body, so
#      frontmatter remains the single tier authority for all four seats.
#
# WHY CASE 4 ANCHORS ON THE FUNCTION, NOT ON ONE SPAWN SITE INSIDE IT. It
# originally located the spawn by its `for (const route of routes)` loop header.
# That spawn shape has now moved TWICE — most recently the loop became
# `routes.map(...)` feeding a bounded fanout wait (temperloop#2003) — and the
# move silently disarmed the locator: the invariant still held, but the guard
# could no longer find the thing it guards. The property was never about one
# loop. It is about the WHOLE of runReviewers(): no `model` override may be
# passed from anywhere in it, however the spawn is arranged internally. So the
# locator is the function's own declaration line and its closing brace, which no
# internal restructure changes.
#
# Scope: the four seats /build §3e routes. The `claude/agents/reviewers/**`
# language catalog is deliberately NOT covered — those seats are inert,
# opted-in per adopter repo, and their tiers were dispositioned separately
# (docs/model-fanout-inventory.md § B3).
#
# No network, no HOME mutation, no tmpdir: every assertion reads a tracked file.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
AGENTS_DIR="${REPO_ROOT}/claude/agents"
BUILD_LEVEL="${REPO_ROOT}/claude/workflows/build-level.mjs"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# Read the `model:` value out of a charter's YAML frontmatter — the FIRST
# `---`-delimited block only, so a `model:` mentioned in the body prose can
# never be mistaken for the declaration.
frontmatter_model() {
  awk '
    /^---[[:space:]]*$/ { n++; if (n >= 2) exit; next }
    n == 1 && /^model:[[:space:]]/ { sub(/^model:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }
  ' "$1"
}

# ---------------------------------------------------------------------------
# Test 1: architecture-reviewer declares an explicit tier, never `inherit`.
#
# The seat's output IS the gate (nothing downstream mechanically checks a
# boundary call), so under the tier-by-verification policy no cheaper tier is
# admissible — and `inherit` is not a tier at all, it is a deferral to whoever
# spawned the seat.
# ---------------------------------------------------------------------------
ARCH="${AGENTS_DIR}/architecture-reviewer.md"
[ -f "$ARCH" ] || fail "1: charter not found at $ARCH"

arch_model="$(frontmatter_model "$ARCH")"
[ -n "$arch_model" ] || fail "1: architecture-reviewer.md declares no frontmatter 'model:' at all"
if [ "$arch_model" = "inherit" ]; then
  fail "1: architecture-reviewer declares 'model: inherit' — the seat its own charter calls 'never down-tiered' would take the CALLING context's tier, so an autonomous drive on \$PIPELINE_DRIVE_MODEL silently down-tiers it (temperloop#1456). Declare an explicit tier."
fi
pass "1: architecture-reviewer declares an explicit tier (model: ${arch_model}), not inherit"

# ---------------------------------------------------------------------------
# Test 2: the charter prose agrees with the frontmatter.
#
# The original defect was not the value alone — it was the DISAGREEMENT
# between a charter promising "never down-tiered" and a frontmatter deferring
# the tier to the caller. Fixing one and leaving the other standing would
# re-create it in mirror image.
# ---------------------------------------------------------------------------
#
# Stated as two positive properties rather than "the string `model: inherit`
# never appears": the charter SHOULD be free to record what it used to declare
# and why that was wrong — that history is the reason the next reader does not
# re-derive it. What it must not do is describe its CURRENT tier as anything
# other than what the frontmatter says.
if ! grep -qF "\`model: ${arch_model}\`" "$ARCH"; then
  fail "2: architecture-reviewer.md's frontmatter declares '${arch_model}' but its prose never states that tier — the charter must name the tier it actually runs on (temperloop#1456)"
fi
if grep -q 'runs on the \*\*session model\*\*' "$ARCH"; then
  fail "2: architecture-reviewer.md's prose still claims the seat runs on the session model while its frontmatter declares '${arch_model}' — the doc and the mechanism disagree (temperloop#1456)"
fi
pass "2: architecture-reviewer's prose states its declared tier and no longer claims the session model"

# ---------------------------------------------------------------------------
# Test 3: the three sibling §3e reviewers are untouched — still `sonnet`.
#
# Their findings are advisory inputs the orchestrator and a human filter, so a
# mechanical gate stands behind them and a cheaper tier is correct. This is the
# no-op assertion: it fails if fixing case 1 moved a seat it had no business
# moving.
# ---------------------------------------------------------------------------
for seat in workflow-reviewer docs-reviewer requirements-auditor; do
  charter="${AGENTS_DIR}/${seat}.md"
  [ -f "$charter" ] || fail "3: charter not found at $charter"
  got="$(frontmatter_model "$charter")"
  [ "$got" = "sonnet" ] || fail "3: ${seat} declares 'model: ${got:-<none>}', expected 'sonnet' — the temperloop#1456 tier fix must be a no-op for this seat"
done
pass "3: workflow-reviewer, docs-reviewer and requirements-auditor still declare model: sonnet"

# ---------------------------------------------------------------------------
# Test 4: runReviewers() passes no `model` override.
#
# Cases 1 and 3 only mean anything while the frontmatter is what the spawn
# actually honours. A caller-side override would quietly become a second,
# competing tier authority — and would have to be re-applied at every one of
# this seat's call sites (/build §3e, /assess Step 3, /workshop Step 3.3/3.5),
# which is the reason the fix went into the frontmatter instead.
#
# The extraction is anchored on the FUNCTION (declaration line -> first
# column-0 `}`), never on the spawn's current internal arrangement — see the
# header's "WHY CASE 4 ANCHORS ON THE FUNCTION". Every nested construct in this
# function (the arrow helpers, the `.then` recorder, the `routes.map`) closes at
# an indented brace, so the first column-0 `}` is the function's own end.
# ---------------------------------------------------------------------------
[ -f "$BUILD_LEVEL" ] || fail "4: build-level.mjs not found at $BUILD_LEVEL"

spawn_block="$(awk '
  /^async function runReviewers/ { inblock = 1 }
  inblock { print }
  inblock && /^}/ { exit }
' "$BUILD_LEVEL")"
[ -n "$spawn_block" ] || fail "4: could not locate the runReviewers() function in build-level.mjs (expected a line starting \`async function runReviewers\`) — the locator, not the invariant, is what broke; re-anchor it rather than relaxing the assertion"

if printf '%s\n' "$spawn_block" | grep -vE '^[[:space:]]*(//|\*|/\*)' | grep -E '\bmodel[[:space:]]*:' >/dev/null; then
  fail "4: runReviewers() passes a 'model' override — the reviewer frontmatter is no longer the single tier authority (temperloop#1456)"
fi
pass "4: runReviewers() passes no model override; frontmatter remains the single tier authority"

echo "All reviewer seat-tier tests passed."
