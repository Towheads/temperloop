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
#      un-expanded at a boundary that is NOT a backtick or a `/` (a
#      backtick-fenced or slash-joined token, e.g. `` `K1451` `` or
#      `S3/S4`, reads as a code span or a compound identifier, not a
#      prose cross-repo reference — see KNOWN LIMITATION below; this is
#      NOT a zero-baseline ban).
#   3. NAMED JARGON TOKENS — none of `docs-reviewer.md`'s own named
#      unexplained-shorthand examples (`WIP cap`, `checks gate`) appear
#      verbatim. Those two are unambiguous, zero-judgment vocabulary a
#      fragment never needs to name verbatim — the underlying mechanism
#      (the `checks` CI status check) can always be named instead. (This
#      change's own fragment (changelog.d/2136-docs-severity-and-fragment-
#      lint.added.md) needed a reword to clear this check on its first
#      pass — see its shipped text for the resolved phrasing, and
#      changelog.d/README.md § Mechanical check for why "never needed" is
#      stated this way rather than as a zero-baseline claim.)
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
# KNOWN LIMITATIONS:
#   * the title-hook check's issue-mention pattern (`#[0-9]+`) also matches
#     a hex color or any other `#<digits>` token that is not an issue
#     reference. No fragment in this corpus contains one; a future fragment
#     that legitimately does can route around a false positive the same way
#     any other mechanical lint's false positive is routed around — fix the
#     fragment's wording (a hex color has no reason to be a fragment's
#     FIRST `#<digits>` token) rather than the lint.
#   * the bare-cross-repo-shorthand check (#2 above) still collides with a
#     plain-prose, non-backticked, non-slash-joined `K<N>`/`S<N>`-shaped
#     token that is not a cross-repo reference — a test-case id ("the K1071
#     step-ceiling case") or a hardware/service name ("an M1 host with an
#     S3 bucket"), both real strings found in this repo's own CHANGELOG.md
#     history. The backtick/`/` exclusion above closes the two collision
#     shapes that are mechanically detectable (a code span, a slash-joined
#     pair); a bare mid-sentence collision has no mechanical tell and is
#     NOT zero-baseline. Route around it the same way as the hex-color
#     case: backtick the non-reference token (`` `S3` ``) or otherwise
#     reword so it does not read as bare `[KSFMW]<digits>`, rather than
#     changing the lint. If this residual collision rate becomes a real
#     authoring cost, the honest next step is dropping check #2 entirely
#     (as README's own step-letter/section-index rule already was, for the
#     same false-positive-magnet reason) and leaving the call to
#     `docs-reviewer`, capped at MEDIUM — not tightening the pattern
#     further, which cannot close a collision with no mechanical tell.
#
# Usage:
#   workflows/scripts/config/check-changelog-fragment-register.sh
#
# Env overrides (fixture-driven tests):
#   CHANGELOG_FRAGMENT_DIR   the changelog.d/-shaped directory to scan
#                            (default: <repo-root>/changelog.d). NOT an
#                            operator-tunable setting and deliberately NOT
#                            a setting-registry.tsv row: its only setters
#                            are this gate's own two test suites, pointing
#                            it at scratch fixture dirs. Same
#                            "setting:exempt" class as
#                            check-terminology-leak-guard.sh's
#                            TERMINOLOGY_LEAK_SCAN_ROOT and
#                            check-contributor-manifest.sh's
#                            CONTRIBUTOR_MANIFEST_REPO_ROOT; see
#                            setting-registry.tsv's own "Inclusion rule"
#                            section, which excludes a test-only seam
#                            documented as such in its own script.
#
# Kept bash-3.2-portable (no associative arrays, no mapfile) and awk-based
# for the multi-line text scan, matching every sibling
# workflows/scripts/config/*.sh checker (e.g. check-setting-prose.sh).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# `-` (not `:=`) on purpose (LOW: an explicitly-empty CHANGELOG_FRAGMENT_DIR
# must not be silently redirected at the real tree — see the degenerate-input
# guards below, which fail loudly on an empty path via the `-e` test).
CHANGELOG_FRAGMENT_DIR="${CHANGELOG_FRAGMENT_DIR-$REPO_ROOT/changelog.d}"  # setting:exempt — test/fixture directory override, set only by this gate's own test suites; not an operator-facing config-precedence default (same class as check-terminology-leak-guard.sh's TERMINOLOGY_LEAK_SCAN_ROOT)

# shellcheck source=workflows/scripts/lib/changelog.sh
if ! source "$SCRIPT_DIR/../lib/changelog.sh"; then
  echo "check-changelog-fragment-register: cannot load $SCRIPT_DIR/../lib/changelog.sh — refusing to report a false OK" >&2
  exit 1
fi
# Belt 2 covers EVERY lib function this checker's main loop depends on, not
# just the listing one (round-3 HIGH 2): `body="$(changelog_fragment_body …)"`
# is a command substitution, so a lib that defines `changelog_fragment_names`
# but not `changelog_fragment_body` yields an empty `$body` with a DISCARDED
# exit status — every check below then passes vacuously and the run reports a
# green "0 violations". Same silent-green shape as a failed `source`.
for _ccfr_fn in changelog_fragment_names changelog_fragment_body; do
  if ! command -v "$_ccfr_fn" >/dev/null 2>&1; then
    echo "check-changelog-fragment-register: changelog.sh loaded but did not define $_ccfr_fn — refusing to report a false OK" >&2
    exit 1
  fi
done
unset _ccfr_fn

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
# _ccfr_first_ref_hooked <body> -> rc 0 iff EVERY top-level bullet (a line
# starting `- `, plus its indented continuation lines) in <body> is
# individually hooked: either it carries no issue reference at all, or its
# FIRST `#<digits>` occurrence is preceded, earlier in THAT SAME bullet, by
# a closed `**...**` bold span. rc 1 if any bullet's first mention is
# un-hooked (a genuine un-hooked first mention).
#
# SCOPED PER BULLET, not whole-fragment (MEDIUM 2 fix, temperloop#2136 round
# 2 review): a multi-bullet fragment is the norm, not the exception, and a
# whole-fragment scan lets a bold lead-in on bullet 1 satisfy the hook for
# an un-hooked `#N` first appearing in bullet 2+ — the exact false-pass this
# scoping closes. A fragment with no `- `-prefixed line at all (a bare
# paragraph) is treated as a single bullet spanning the whole body, matching
# prior behavior for that shape.
#
# Implementation note: within one bullet, "preceded by a closed bold span"
# is tested as "at least two `**` markers appear before the first
# `#<digits>`" — cheaper than locating the exact matching pair, and
# equivalent for well-formed Markdown (an odd `**` count before the ref
# would itself be a malformed-bold defect outside this lint's scope).
# ---------------------------------------------------------------------------
_ccfr_first_ref_hooked() {
  awk '
    /^- / {
      nblk++
      blk[nblk] = $0 "\n"
      next
    }
    {
      if (nblk == 0) { nblk = 1; blk[nblk] = "" }
      blk[nblk] = blk[nblk] $0 "\n"
    }
    END {
      for (i = 1; i <= nblk; i++) {
        text = blk[i]
        if (!match(text, /#[0-9]+/)) continue   # nothing to hook in this bullet
        before = substr(text, 1, RSTART - 1)
        n = gsub(/\*\*/, "**", before)
        if (n < 2) exit 1
      }
      exit 0
    }
  ' <<<"$1"
}

violations=0
checked=0

while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  checked=$((checked + 1))

  # PER-FILE readability guard (round-3 HIGH 2) — the file-granularity twin of
  # the directory-granularity `-r` guard above. `changelog_fragment_body`
  # shells out to awk and its exit status is DISCARDED by the command
  # substitution below, so an unreadable fragment yields an awk error on
  # stderr and an EMPTY `$body`: both greps find nothing and
  # `_ccfr_first_ref_hooked` exits 0 on an empty body, so the fragment passes
  # all three checks VACUOUSLY and the run prints a green "0 violations".
  # Belt 3 cannot see it either — the file IS on disk, so the raw glob count
  # and $checked agree. This is the third arm of the same reads-green-while-
  # inert class belts 1/2/3 close; the check-surface registry's `unreadable`
  # row for this script covers both granularities because of this guard.
  if [[ ! -r "$CHANGELOG_FRAGMENT_DIR/$name" ]]; then
    echo "check-changelog-fragment-register: fragment unreadable, refusing to report a false OK: $name" >&2
    exit 1
  fi

  body="$(changelog_fragment_body "$CHANGELOG_FRAGMENT_DIR/$name")"

  # Check 2 -- bare cross-repo shorthand (K<N>/S<N>/F<N>/M<N>/W<N>). Boundary
  # excludes a backtick or `/` on either side (HIGH 2 fix) -- a backtick-
  # fenced token (`` `K1451` ``) is a code span, and a `/`-joined token
  # (`S3/S4`) is a compound test-id, neither a bare prose cross-repo ref. A
  # plain mid-sentence collision (a test-case id, a hardware name) has no
  # mechanical tell and stays a known limitation -- see the script header.
  # shellcheck disable=SC2016  # backticks below are a literal regex char class member, not expansion
  hit="$(printf '%s\n' "$body" | grep -nE '(^|[^0-9A-Za-z/`])[KSFMW][0-9]+([^0-9A-Za-z/`]|$)' || true)"
  if [[ -n "$hit" ]]; then
    # shellcheck disable=SC2016  # backticks below are literal markdown spans, not expansion
    printf 'REGISTER: %s: possible bare cross-repo shorthand -- if this is a cross-repo issue reference, write the full `temperloop#N` / `<repo>#N` form; if it is a test-case id, hardware name, or other non-reference token, reword or backtick it instead\n' "$name"
    printf '%s\n' "$hit" | sed -E 's/^([0-9]+):/    body line \1: /'
    violations=$((violations + 1))
  fi

  # Check 3 -- named jargon tokens (docs-reviewer.md's own examples). Allows
  # an optional backtick around `checks` and a `-` or space before `gate`
  # (MEDIUM 1 fix) -- this corpus universally writes `` `checks` gate ``,
  # which the original bare `checks gate` literal never matched.
  #
  # RIGHT-ANCHORED (round-3 LOW 3): widening the separator to `[ -]+` also
  # made a bare `checks gate-paths.tsv` match -- a phrase with real occasion
  # to appear in this repo's fragments, since that file is a live artifact
  # fragments discuss. `gates?([^-A-Za-z]|$)` requires the word to END at
  # `gate`/`gates`, so `gate-paths.tsv` (and any other `gate-`-prefixed
  # filename) no longer trips it while the genuine jargon token still does.
  # shellcheck disable=SC2016  # backticks below are a literal regex alternative, not expansion
  hit="$(printf '%s\n' "$body" | grep -niE 'WIP cap|`?checks`?[ -]+gates?([^-A-Za-z]|$)' || true)"
  if [[ -n "$hit" ]]; then
    printf 'REGISTER: %s: names an internal-jargon token an adopter cannot resolve (docs-reviewer.md § Unexplained shorthand)\n' "$name"
    printf '%s\n' "$hit" | sed -E 's/^([0-9]+):/    body line \1: /'
    violations=$((violations + 1))
  fi

  # Check 1 -- title hook on the first issue mention.
  if ! _ccfr_first_ref_hooked "$body"; then
    # shellcheck disable=SC2016  # backticks below are literal markdown spans, not expansion
    printf 'REGISTER: %s: first issue mention has no title hook — no `**bold**` lead-in precedes it\n' "$name"
    violations=$((violations + 1))
  fi
done < <(changelog_fragment_names "$CHANGELOG_FRAGMENT_DIR")

# ---------------------------------------------------------------------------
# HIGH 1 fix, belt 3 -- a sanity cross-check computed INDEPENDENTLY of
# changelog.sh: count `*.md` files directly in $CHANGELOG_FRAGMENT_DIR
# (excluding README.md) via bash's own glob (readdir + name matching only,
# no stat -- so it still enumerates names even when the directory is
# readable but not searchable, e.g. `chmod 444`, the exact second arm of
# the reported bug: `changelog_fragment_names` silently drops every entry
# in that case because its own `-e`/`-L` tests DO stat and fail closed).
# A mismatch means the main loop above processed a different set of
# fragments than what is actually on disk -- exactly the "green while
# inert" shape (a failed `source`, an undefined function silently no-op'd
# by the process-substitution loop, or this permission case) -- so it fails
# loudly rather than trusting $checked on its own.
# ---------------------------------------------------------------------------
_ccfr_raw_md_count() {
  local dir="$1" count=0 f was_nullglob=0
  shopt -q nullglob && was_nullglob=1
  shopt -s nullglob
  for f in "$dir"/*.md; do
    [[ "${f##*/}" == "README.md" ]] && continue
    count=$((count + 1))
  done
  [[ "$was_nullglob" -eq 0 ]] && shopt -u nullglob
  printf '%s\n' "$count"
}

raw_md_count="$(_ccfr_raw_md_count "$CHANGELOG_FRAGMENT_DIR")"
if [[ "$raw_md_count" -ne "$checked" ]]; then
  echo "check-changelog-fragment-register: sanity mismatch -- processed $checked fragment(s) via changelog.sh but found $raw_md_count *.md file(s) (excluding README.md) directly in $CHANGELOG_FRAGMENT_DIR. Two causes produce this, neither ranked above the other: (a) the fragment loop processed the wrong set (a load or permission failure -- the reads-green-while-inert shape this belt exists to catch), or (b) the directory holds an entry the two counts legitimately disagree about -- a non-conforming *.md name, a directory or dangling symlink named *.md, or any other non-regular entry, since the raw glob counts every *.md name while changelog_fragment_names returns only conforming REGULAR files. Run changelog_fragment_invalid / changelog_fragment_nonregular on this directory to tell (b) from (a); investigate before trusting any result above." >&2
  exit 1
fi

echo
if [[ "$violations" -gt 0 ]]; then
  echo "FAIL: $violations changelog-fragment register violation(s) across $checked fragment(s) — see changelog.d/README.md § Who reads a fragment, and the register that follows" >&2
  exit 1
fi
echo "OK — 0 changelog-fragment register violations across $checked fragment(s) checked"
