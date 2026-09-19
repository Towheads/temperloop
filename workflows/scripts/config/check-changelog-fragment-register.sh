#!/usr/bin/env bash
#
# check-changelog-fragment-register.sh — mechanical register lint for
# changelog.d/ fragments (temperloop#2136).
#
# WHY. changelog.d/README.md § "Who reads a fragment, and the register that
# follows" already SPECIFIES the register a fragment must ship in — its
# reader is a cold adopter with CHANGELOG.md open and nothing else, who has
# not read the diff, the issue, or the plan note, and cannot ask — but
# nothing CHECKED it. The rule landed as prose in one PR (temperloop#2011)
# and its own violations kept surfacing a review round late, as a
# `docs-reviewer` finding on the very fragment that introduces them
# (README's own recorded baseline: 4 findings across 3 items in one day,
# temperloop#2007). This gate closes the mechanical slice of that gap.
#
# SCOPE — DELIBERATELY NARROW. `claude/agents/docs-reviewer.md`'s own
# severity ceiling (added alongside this gate, temperloop#2136) caps a
# register/shorthand finding at MEDIUM, never HIGH, precisely because
# grading prose register is a judgment call — and a judgment call is not
# something a mechanical lint should attempt either (kernel principle
# "Advisory over enforced discipline": an ENFORCED rule earns its place only
# when what it enforces is a mechanical fact, not taste). So this script
# checks exactly three MECHANICAL facts about a fragment's text — never
# whether the prose reads well:
#
#   1. TITLE HOOK — the fragment's FIRST issue mention (`#<digits>`, in any
#      form: bare `#N`, `temperloop#N`, `owner/repo#N`) is preceded, earlier
#      in the same fragment, by a closed `**bold**` span — the lead-in every
#      fragment in this directory already opens with. This mirrors
#      `claude/message-schema.md` § The reference-token rule's
#      "self-sufficient at its point of use" for a reference token, adapted
#      to this directory's own convention (the hook precedes the ref here,
#      rather than the reference-token rule's own `#94 (title hook)` shape,
#      because that is what every existing fragment already does).
#   2. BARE CROSS-REPO SHORTHAND — no `K<N>`/`S<N>`/`F<N>`/`M<N>`/`W<N>`-style
#      token (this repo's own cross-repo reference shorthand,
#      `claude/CLAUDE.kernel.md` § Communication conventions) appears
#      un-expanded. A fragment always spells the full form (`temperloop#N`)
#      — this directory's whole corpus already does, by construction (see
#      the NOT CHECKED note below for why this is a safe, zero-baseline
#      ban).
#   3. NAMED JARGON TOKENS — none of `docs-reviewer.md`'s own named
#      unexplained-shorthand examples (`WIP cap`, `checks gate`) appear
#      verbatim. Those two are unambiguous, zero-judgment vocabulary this
#      directory's fragments have never legitimately needed.
#
# NOT CHECKED, ON PURPOSE: README's own step-letter/section-index examples
# (`Step 4a`, `§3e`, `round 1`, `dimension 4`) and its source-file-field-name
# / invented-mechanism-name rules. Two reasons, not one:
#   * CORPUS-INCOMPATIBLE — this directory already carries reviewed,
#     pre-existing `§3e` references (e.g.
#     changelog.d/2049-reviewer-latency-in-workflow.fixed.md,
#     changelog.d/2064-review-wait-blocked-sleep.fixed.md) naming a real,
#     stable, documented gate (`/build` §3e) — unlike a bare, unexplained
#     `3e` those are not obviously wrong in context, so a mechanical ban
#     here would either fail the current tree or need a burn-down baseline
#     for a pattern that genuinely needs a reader's judgment to call;
#   * FALSE-POSITIVE MAGNET — a generic digit+letter pattern collides with
#     ordinary units throughout this very corpus (`120s`, `24GB`, `2x`), so
#     it is exactly the "likely low-precision" lever
#     changelog.d/README.md § Baseline records temperloop#2007 declining to
#     reach for first. That judgment call stays with the `docs-reviewer`
#     advisory pass — capped at MEDIUM, never HIGH, per that agent's own
#     § Severity criteria — rather than a mechanical lint that cannot tell a
#     stable named gate from genuine unexplained jargon.
#
# KNOWN LIMITATION: the title-hook check's issue-mention pattern (`#[0-9]+`)
# also matches a hex color or any other `#<digits>` token that is not an
# issue reference. No fragment in this corpus contains one; a future
# fragment that legitimately does can route around a false positive the same
# way any other mechanical lint's false positive is routed around — fix the
# fragment's wording (a hex color has no reason to be a fragment's FIRST
# `#<digits>` token) rather than the lint.
#
# Usage:
#   workflows/scripts/config/check-changelog-fragment-register.sh
#
# Env overrides (fixture-driven tests):
#   CHANGELOG_FRAGMENT_DIR   the changelog.d/-shaped directory to scan
#                            (default: <repo-root>/changelog.d)
#
# Kept bash-3.2-portable (no associative arrays, no mapfile) and awk-based
# for the multi-line text scan, matching every sibling
# workflows/scripts/config/*.sh checker (e.g. check-setting-prose.sh).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

: "${CHANGELOG_FRAGMENT_DIR:=$REPO_ROOT/changelog.d}"

# shellcheck source=workflows/scripts/lib/changelog.sh
source "$SCRIPT_DIR/../lib/changelog.sh"

# --- degenerate-input guards (fail loudly; never a silent OK) --------------
if [[ ! -e "$CHANGELOG_FRAGMENT_DIR" ]]; then
  echo "check-changelog-fragment-register: fragment directory not found: $CHANGELOG_FRAGMENT_DIR" >&2
  exit 1
fi
if [[ ! -d "$CHANGELOG_FRAGMENT_DIR" ]]; then
  echo "check-changelog-fragment-register: not a directory: $CHANGELOG_FRAGMENT_DIR" >&2
  exit 1
fi
if [[ ! -r "$CHANGELOG_FRAGMENT_DIR" ]]; then
  echo "check-changelog-fragment-register: fragment directory unreadable: $CHANGELOG_FRAGMENT_DIR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# _ccfr_first_ref_hooked <body> -> rc 0 iff <body> carries NO issue
# reference at all, OR its FIRST `#<digits>` occurrence is preceded, earlier
# in <body>, by a closed `**...**` bold span. rc 1 otherwise (a genuine
# un-hooked first mention).
#
# Implementation note: "preceded by a closed bold span" is tested as "at
# least two `**` markers appear before the first `#<digits>`" — cheaper than
# locating the exact matching pair, and equivalent for well-formed Markdown
# (an odd `**` count before the ref would itself be a malformed-bold defect
# outside this lint's scope).
# ---------------------------------------------------------------------------
_ccfr_first_ref_hooked() {
  awk '
    { text = text $0 "\n" }
    END {
      if (!match(text, /#[0-9]+/)) {
        exit 0   # no issue reference at all -- nothing to hook
      }
      before = substr(text, 1, RSTART - 1)
      n = gsub(/\*\*/, "**", before)
      exit (n >= 2) ? 0 : 1
    }
  ' <<<"$1"
}

violations=0
checked=0

while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  checked=$((checked + 1))
  body="$(changelog_fragment_body "$CHANGELOG_FRAGMENT_DIR/$name")"

  # Check 2 -- bare cross-repo shorthand (K<N>/S<N>/F<N>/M<N>/W<N>).
  hit="$(printf '%s\n' "$body" | grep -nE '(^|[^0-9A-Za-z])[KSFMW][0-9]+([^0-9A-Za-z]|$)' || true)"
  if [[ -n "$hit" ]]; then
    # shellcheck disable=SC2016  # backticks below are literal markdown spans, not expansion
    printf 'REGISTER: %s: bare cross-repo shorthand — write the full `temperloop#N` / `<repo>#N` form instead\n' "$name"
    printf '%s\n' "$hit" | sed -e 's/^/    /'
    violations=$((violations + 1))
  fi

  # Check 3 -- named jargon tokens (docs-reviewer.md's own examples).
  hit="$(printf '%s\n' "$body" | grep -niE 'WIP cap|checks gate' || true)"
  if [[ -n "$hit" ]]; then
    printf 'REGISTER: %s: names an internal-jargon token an adopter cannot resolve (docs-reviewer.md § Unexplained shorthand)\n' "$name"
    printf '%s\n' "$hit" | sed -e 's/^/    /'
    violations=$((violations + 1))
  fi

  # Check 1 -- title hook on the first issue mention.
  if ! _ccfr_first_ref_hooked "$body"; then
    # shellcheck disable=SC2016  # backticks below are literal markdown spans, not expansion
    printf 'REGISTER: %s: first issue mention has no title hook — no `**bold**` lead-in precedes it\n' "$name"
    violations=$((violations + 1))
  fi
done < <(changelog_fragment_names "$CHANGELOG_FRAGMENT_DIR")

echo
if [[ "$violations" -gt 0 ]]; then
  echo "FAIL: $violations changelog-fragment register violation(s) across $checked fragment(s) — see changelog.d/README.md § Who reads a fragment, and the register that follows" >&2
  exit 1
fi
echo "OK — 0 changelog-fragment register violations across $checked fragment(s) checked"
