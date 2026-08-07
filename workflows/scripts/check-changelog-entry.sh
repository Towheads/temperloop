#!/usr/bin/env bash
#
# check-changelog-entry.sh — the CHANGELOG.md merge gate. Two properties:
#
#   (1) COMPLETENESS (temperloop#960) — a PR that changes CONTRACT SURFACE
#       must add an entry under `## [Unreleased]`.
#   (2) SECTION SCOPE (temperloop#1151) — a PR must not add lines to, nor take
#       lines from, a section that was ALREADY RELEASED at its merge base.
#
# WHY THIS IS NOT TIDINESS. VERSIONING.md's pre-1.0 scheme carries the breaking
# signal in the CHANGELOG, not the version number: "a breaking release MUST mark
# its section `BREAKING`". `scripts/update-kernel.sh` and `bin/subcommands/
# update.sh` compute the downstream acknowledgment gate by scanning the
# CHANGELOG range through changelog_breaking_sections() (workflows/scripts/lib/
# changelog.sh). An ABSENT entry cannot carry a `BREAKING` marker — so a
# breaking change merged in a PR that skipped the CHANGELOG ships to every
# downstream overlay with the acknowledgment gate silently passing. That gate is
# only as good as the CHANGELOG's completeness, and before this script nothing
# enforced completeness (at the v0.22.0 cut, 1 of 14 merged PRs had touched
# CHANGELOG.md).
#
# THE PROPERTY IT HOLDS: at any commit on main, `## [Unreleased]` describes
# everything on main that is not yet released.
#
# ── What counts as "contract surface" ──────────────────────────────────────
# NOT a second definition. The pattern set is PARSED, at run time, out of
# VERSIONING.md § The contract surface's own table — the backticked paths in
# its "Where it lives" column. Edit that table and this gate follows; there is
# no parallel list to keep in sync. If the table cannot be found, or yields
# implausibly few paths, this script FAILS LOUDLY rather than silently
# enforcing nothing (a gate that quietly narrows to zero is worse than no gate).
#
# ── The escape hatch is EXPLICIT, never inferred ───────────────────────────
# Forcing an entry on every commit trains people to write noise, so a genuinely
# non-shipping change (a prose-budget chore, a comment rewording, a test-only
# edit that happens to touch a contract-surface path) can opt out — but only by
# RECORDING the choice. One marker grammar, three places it can be recorded:
#
#   1. a PR label — `no-changelog` ($CHANGELOG_GATE_SKIP_LABEL), passed in from
#      the workflow as $CHANGELOG_GATE_PR_LABELS;
#   2. a PR-body line — `Changelog: none — <reason>`, passed in as
#      $CHANGELOG_GATE_PR_BODY;
#   3. a commit-message trailer — the same `Changelog: none — <reason>` line in
#      any commit in the range. This is the channel that works BEFORE a PR
#      exists (a /build worker's parent-side gate run) and in a merge_group,
#      where no PR body or label is in the event payload.
#
# The marker requires a REASON (>= 3 chars after the separator): the point is a
# recorded choice, and "none" with no rationale records nothing. `skip` is
# accepted as a synonym for `none`. Matching is anchored at line start, so a
# backticked/inline mention of the marker in prose (as in this header) is never
# read as an opt-out.
#
# ONE grammar, TWO sibling verbs. `none`/`skip` waives property (1); `amend`
# waives property (2). Same anchored matcher, same three channels, same
# >= 3-char reason requirement — the amendment escape hatch is a VERB in the
# existing grammar, deliberately not a second parallel mechanism:
#
#   Changelog: none  — <reason>   waives the [Unreleased]-entry requirement
#   Changelog: amend — <reason>   waives the released-section-scope check
#
# (the amendment label is `changelog-amend`, $CHANGELOG_GATE_AMEND_LABEL, the
# sibling of $CHANGELOG_GATE_SKIP_LABEL). The two are NOT interchangeable: a
# recorded "this change ships nothing" says nothing about whether editing a
# shipped release's record was intended, so `none` never waives section scope
# and `amend` never waives completeness.
#
# ── Section scope: the release-cut vs. theft discriminator (#1151) ──────────
# At HEAD a legitimate release cut and a stolen entry look IDENTICAL: a cut
# creates `## [x.y.z]` directly beneath `## [Unreleased]` and moves the
# accumulated entries down into it, so "lines were added inside a released
# section" and "a released section was modified" are both true of a perfectly
# correct cut.
#
# THE DISCRIMINATOR IS THE BASE REF, NOT THE HEAD. Section membership is
# resolved against the MERGE BASE's section boundaries:
#
#   * the version heading did NOT exist at the merge base  => this PR is
#     CREATING that section. It is the release cut. Its contents are not
#     checked — moving the Unreleased body down is the whole point.
#   * the version heading DID exist at the merge base       => that release
#     shipped BEFORE this PR. Adding lines to it is drift-in (the PR's work is
#     not in that release); removing lines from it is history loss (an entry
#     that legitimately shipped in that release is being erased).
#
# Both directions were live incidents. Drift-in (temperloop#1138): a PR adds
# its entry under Unreleased, main concurrently cuts a release beneath
# Unreleased, and on rebase the PR's added lines resolve into the TOP of a
# release that does not contain its work. History loss (the temperloop#1125
# over-correction): a worker correctly moving its OWN entry back out of a
# released section also pulled ANOTHER PR's block out with it — the more
# damaging direction, and invisible to review because the diff reads as a
# legitimate move. Same class as temperloop#1143, where a release shipped four
# PRs with no record at all.
#
# The check runs whenever CHANGELOG.md itself is in the diff — INDEPENDENT of
# whether contract surface was touched, since a CHANGELOG-only PR can steal
# from a released section just as easily. Only NON-BLANK line differences
# count; a `###` sub-heading DOES count (losing a `### Removed — BREAKING`
# heading is exactly the temperloop#1125 damage).
#
# ── Where it runs ──────────────────────────────────────────────────────────
# Registered in scripts/quality-gates.sh's KERNEL_GATES, so it rides the
# already-required `checks` status and needs no second required job and no
# branch-protection change — the same wiring as `make test-pr-leak-guard`, the
# other diff-scoped gate in that set.
#
# Inside GitHub Actions it ENFORCES ON `pull_request` ONLY. On `merge_group` and
# `push` the PR body and labels are absent from the event payload, so an
# author's recorded opt-out would be invisible and a legitimately-exempt PR
# would fail in the merge queue after passing on the PR. Those events print a
# legible skip instead (never a silent no-op). Outside CI — a local run, a
# /build worker's parent-side gate — there is no event name, so it enforces
# against origin/main with the commit-trailer channel available.
#
# ── Base-ref resolution (mirrors check-pr-leak-guard.sh) ───────────────────
#   1. --base / $CHANGELOG_GATE_BASE if non-empty
#   2. else origin/main if it resolves
#   3. else main if it resolves
#   4. else no base -> skip with a notice, exit 0
# The diff is taken from `git merge-base <base> <head>`, so a base branch that
# advanced under the PR never makes unrelated files look touched.
#
# Usage:
#   check-changelog-entry.sh [--base REF] [--head REF]
#
# Exit codes: 0 = clean (or legibly skipped), 1 = violation, 2 = usage error.
#
# Kept bash-3.2 friendly (macOS default shell) — no mapfile, no associative
# arrays, no GNU-only awk intervals.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${CHANGELOG_GATE_ROOT:=$REPO_ROOT_DEFAULT}"
: "${CHANGELOG_GATE_HEAD:=HEAD}"
: "${CHANGELOG_GATE_SKIP_LABEL:=no-changelog}"
: "${CHANGELOG_GATE_AMEND_LABEL:=changelog-amend}"

ROOT="$CHANGELOG_GATE_ROOT"
HEAD="$CHANGELOG_GATE_HEAD"
BASE="${CHANGELOG_GATE_BASE:-}"
PR_BODY="${CHANGELOG_GATE_PR_BODY:-}"
PR_LABELS="${CHANGELOG_GATE_PR_LABELS:-}"

# Repo-relative paths (used both on disk and as `git show <ref>:<path>`).
CHANGELOG_REL="CHANGELOG.md"
VERSIONING_REL="VERSIONING.md"

# Sanity floor on the parsed contract-surface pattern count. A lowercase local,
# deliberately not an operator setting: it exists only to distinguish "the
# table parsed" from "the table moved and we now enforce nothing", and no
# adopter has a reason to tune it.
min_patterns=8

# How many offending lines the section-scope report quotes per direction, per
# section. Also a lowercase local, deliberately not an operator setting: it
# tunes only how much evidence the failure message prints, never the verdict.
sec_report_max=6

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --head) HEAD="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "check-changelog-entry: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

say()  { printf 'check-changelog-entry: %s\n' "$1"; }
warn() { printf 'check-changelog-entry: %s\n' "$1" >&2; }

if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  warn "$ROOT is not a git checkout"
  exit 1
fi

# --- CI event gating --------------------------------------------------------
# GITHUB_EVENT_NAME is GitHub Actions' own ambient signal, not a value this
# repo defines a default for.
CI_EVENT="${GITHUB_EVENT_NAME:-}"  # setting:exempt — GitHub Actions' own ambient event name, not an operator default this repo defines
if [[ -n "$CI_EVENT" && "$CI_EVENT" != "pull_request" ]]; then
  say "skipped — enforcement runs on the pull_request event only (this run: $CI_EVENT); a PR body/label opt-out is not in that event's payload"
  exit 0
fi

# --- resolve base -----------------------------------------------------------
resolve_base() {
  local b="$1" cand
  if [[ -n "$b" ]]; then
    if git -C "$ROOT" rev-parse --verify -q "$b^{commit}" >/dev/null 2>&1; then
      printf '%s' "$b"; return 0
    fi
    warn "base ref '$b' does not resolve"
    return 1
  fi
  for cand in origin/main main; do
    if git -C "$ROOT" rev-parse --verify -q "$cand^{commit}" >/dev/null 2>&1; then
      printf '%s' "$cand"; return 0
    fi
  done
  return 1
}

if ! BASE="$(resolve_base "$BASE")"; then
  say "skipped — no diff base resolves (not a PR context); nothing to compare"
  exit 0
fi

if ! git -C "$ROOT" rev-parse --verify -q "$HEAD^{commit}" >/dev/null 2>&1; then
  warn "head ref '$HEAD' does not resolve"
  exit 1
fi

MERGE_BASE="$(git -C "$ROOT" merge-base "$BASE" "$HEAD" 2>/dev/null)"
[[ -n "$MERGE_BASE" ]] || MERGE_BASE="$BASE"

if [[ "$(git -C "$ROOT" rev-parse "$MERGE_BASE")" == "$(git -C "$ROOT" rev-parse "$HEAD")" ]]; then
  say "skipped — head is at the merge base with $BASE (no commits to check)"
  exit 0
fi

# --- the changed set --------------------------------------------------------
CHANGED="$(git -C "$ROOT" diff --name-only "$MERGE_BASE" "$HEAD" 2>/dev/null)"
if [[ -z "$CHANGED" ]]; then
  say "OK — no files changed against $BASE"
  exit 0
fi

# --- surface-conditional degradation ----------------------------------------
# A composed consumer tree may carry neither file; enforcing against a CHANGELOG
# or a contract-surface definition that does not exist is meaningless.
if ! git -C "$ROOT" show "$HEAD:$CHANGELOG_REL" >/dev/null 2>&1; then
  say "skipped — no $CHANGELOG_REL at $HEAD; this tree keeps no changelog"
  exit 0
fi

# --- the marker grammar (shared by both properties) -------------------------
# ONE anchored grammar, parameterized by VERB: `none`/`skip` waives the
# [Unreleased]-entry requirement, `amend` waives the released-section-scope
# check. Reason required (>= 3 chars after the separator); separator may be an
# em dash, one or two hyphens, or a colon. Anchoring at line start is what
# keeps a backticked/inline mention in prose (as in this header) from reading
# as a marker.
marker_re() {
  printf '^[[:space:]]*[Cc]hangelog:[[:space:]]*(%s)[[:space:]]*(—|--|-|:)[[:space:]]*[^[:space:]][^[:space:]][^[:space:]]' "$1"
}
SKIP_MARKER_RE="$(marker_re '[Nn]one|[Ss]kip|NONE|SKIP')"
AMEND_MARKER_RE="$(marker_re '[Aa]mend|AMEND')"

marker_line() {
  # Echo the first line of stdin matching the regex in $1, if any.
  grep -E -m1 "$1" 2>/dev/null || true
}

# find_marker <regex> <label> — look for the marker in all three channels, in
# the order label -> PR body -> commit trailer. Sets MARKER_HIT / MARKER_VIA;
# returns 0 iff found.
MARKER_HIT=""
MARKER_VIA=""
find_marker() {
  local re="$1" want_label="$2" hit label old_ifs
  MARKER_HIT=""
  MARKER_VIA=""

  # (a) PR label
  if [[ -n "$want_label" && -n "$PR_LABELS" ]]; then
    old_ifs="$IFS"
    IFS=','
    for label in $PR_LABELS; do
      # trim surrounding whitespace
      label="${label#"${label%%[![:space:]]*}"}"
      label="${label%"${label##*[![:space:]]}"}"
      if [[ "$label" == "$want_label" ]]; then
        MARKER_HIT="label '$want_label'"
        MARKER_VIA="PR label"
      fi
    done
    IFS="$old_ifs"
  fi

  # (b) PR body marker
  if [[ -z "$MARKER_HIT" && -n "$PR_BODY" ]]; then
    hit="$(printf '%s\n' "$PR_BODY" | marker_line "$re")"
    if [[ -n "$hit" ]]; then
      MARKER_HIT="$hit"
      MARKER_VIA="PR body"
    fi
  fi

  # (c) commit-message trailer — the pre-PR / merge_group-visible channel
  if [[ -z "$MARKER_HIT" ]]; then
    hit="$(git -C "$ROOT" log --format=%B "$MERGE_BASE..$HEAD" 2>/dev/null | marker_line "$re")"
    if [[ -n "$hit" ]]; then
      MARKER_HIT="$hit"
      MARKER_VIA="commit message"
    fi
  fi

  [[ -n "$MARKER_HIT" ]]
}

# --- CHANGELOG snapshots at the merge base and at head ----------------------
# shellcheck source=lib/changelog.sh
source "$SCRIPT_DIR/lib/changelog.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

git -C "$ROOT" show "$MERGE_BASE:$CHANGELOG_REL" > "$tmpdir/base.md" 2>/dev/null || : > "$tmpdir/base.md"
git -C "$ROOT" show "$HEAD:$CHANGELOG_REL"       > "$tmpdir/head.md" 2>/dev/null || : > "$tmpdir/head.md"

# section_text <file> <version-token> — the heading line plus every line after
# it, up to (not including) the next `## [` heading. The heading is INCLUDED
# because a released heading's own `— BREAKING` suffix is the downstream
# acknowledgment signal, so an edit to it is a section edit like any other.
section_text() {
  awk -v want="$2" '
    /^## \[/ {
      ver = $0; sub(/^## \[/, "", ver); sub(/\].*/, "", ver)
      insec = (ver == want) ? 1 : 0
      if (insec) print
      next
    }
    insec { print }
  ' "$1"
}

# --- property (2): released-section scope (temperloop#1151) -----------------
# Runs whenever CHANGELOG.md itself is in the diff, independent of contract
# surface. Only sections that ALREADY EXISTED at the merge base are checked —
# that is the release-cut discriminator (see the header).
CHANGELOG_TOUCHED=0
while IFS= read -r f; do
  if [[ "$f" == "$CHANGELOG_REL" ]]; then
    CHANGELOG_TOUCHED=1
  fi
done <<EOF
$CHANGED
EOF

DRIFT_SECTIONS=""
DRIFT_REPORT=""
LOSS_SECTIONS=""
LOSS_REPORT=""

if [[ "$CHANGELOG_TOUCHED" == "1" ]]; then
  while IFS= read -r ver; do
    [[ -n "$ver" ]] || continue
    section_text "$tmpdir/base.md" "$ver" > "$tmpdir/sec-base.txt"
    section_text "$tmpdir/head.md" "$ver" > "$tmpdir/sec-head.txt"
    secdiff="$(diff "$tmpdir/sec-base.txt" "$tmpdir/sec-head.txt" 2>/dev/null || true)"
    [[ -n "$secdiff" ]] || continue

    # $sec_report_max lines of evidence per direction — enough to show a whole
    # `### Heading` + bullet block (the temperloop#1125 shape spans four lines),
    # since the report is what makes a wrong verdict arguable rather than opaque.
    sec_added="$(printf '%s\n' "$secdiff" | grep -E '^> ' | sed -e 's/^> //' \
      | grep -Ev '^[[:space:]]*$' | head -"$sec_report_max" || true)"
    sec_removed="$(printf '%s\n' "$secdiff" | grep -E '^< ' | sed -e 's/^< //' \
      | grep -Ev '^[[:space:]]*$' | head -"$sec_report_max" || true)"

    if [[ -n "$sec_added" ]]; then
      DRIFT_SECTIONS="$DRIFT_SECTIONS [$ver]"
      DRIFT_REPORT="$DRIFT_REPORT$(printf '%s\n' "$sec_added" | sed -e "s|^|    [$ver]  + |")"$'\n'
    fi
    if [[ -n "$sec_removed" ]]; then
      LOSS_SECTIONS="$LOSS_SECTIONS [$ver]"
      LOSS_REPORT="$LOSS_REPORT$(printf '%s\n' "$sec_removed" | sed -e "s|^|    [$ver]  - |")"$'\n'
    fi
  done <<EOF
$(changelog_version_headings "$tmpdir/base.md")
EOF
fi

if [[ -n "$DRIFT_SECTIONS" || -n "$LOSS_SECTIONS" ]]; then
  if find_marker "$AMEND_MARKER_RE" "$CHANGELOG_GATE_AMEND_LABEL"; then
    say "OK — already-released section(s)${DRIFT_SECTIONS}${LOSS_SECTIONS} were changed, but the author explicitly recorded the amendment via the $MARKER_VIA: $MARKER_HIT"
  else
    warn "FAIL — this change edits CHANGELOG.md section(s) that were ALREADY RELEASED at the merge base ($MERGE_BASE)."
    warn ""
    if [[ -n "$DRIFT_SECTIONS" ]]; then
      warn "  Lines ADDED inside already-released section(s)${DRIFT_SECTIONS}:"
      printf '%s' "$DRIFT_REPORT" >&2
      warn "  Those lines belong under '## [Unreleased]', NOT inside${DRIFT_SECTIONS} — that release shipped"
      warn "  before this change, so its section cannot describe this change's work."
      warn "  This is the temperloop#1138 shape: a concurrent release cut created a version section"
      warn "  directly beneath '## [Unreleased]', and on rebase this PR's added lines resolved into the"
      warn "  TOP of it. Move them back under '## [Unreleased]' and re-push."
      warn ""
    fi
    if [[ -n "$LOSS_SECTIONS" ]]; then
      warn "  Lines REMOVED from already-released section(s)${LOSS_SECTIONS}:"
      printf '%s' "$LOSS_REPORT" >&2
      warn "  A released section is the record of what that release shipped. Removing a line from it"
      warn "  erases history — most often (the temperloop#1125 shape) by over-correcting a drift-in fix"
      warn "  and pulling ANOTHER PR's entry out along with your own. Restore${LOSS_SECTIONS} to its"
      warn "  merge-base content and move only your own lines."
      warn ""
    fi
    warn "  Sections CREATED by this change are never checked — that is how a release cut passes:"
    warn "  at the merge base its version heading did not exist, so moving the [Unreleased] body down"
    warn "  into it is the cut, not a theft."
    warn ""
    warn "  If the edit IS deliberate (retroactively marking a shipped release BREAKING, adding a"
    warn "  migration note it should have carried), record the choice — same grammar, sibling verb:"
    warn "    - add the '$CHANGELOG_GATE_AMEND_LABEL' label to the PR, or"
    warn "    - put a line 'Changelog: amend - <reason>' in the PR body, or"
    warn "    - put that same line in a commit message (the channel that works before the PR exists)."
    warn "  The reason is required — amending a shipped release's record is a RECORDED CHOICE."
    exit 1
  fi
fi

# --- property (1) needs the contract-surface definition ---------------------
if ! git -C "$ROOT" show "$HEAD:$VERSIONING_REL" >/dev/null 2>&1; then
  say "skipped — no $VERSIONING_REL at $HEAD; nothing defines this tree's contract surface"
  exit 0
fi

# --- parse the contract surface out of VERSIONING.md ------------------------
# The backticked tokens in the LAST cell ("Where it lives") of every row of the
# § The contract surface table. Escaped pipes (`\|`, which appear inside a cell)
# are protected before the split so a cell's own content can't shift the column
# count.
contract_patterns() {
  git -C "$ROOT" show "$HEAD:$VERSIONING_REL" | awk '
    /^### The contract surface/ { insec = 1; next }
    insec && /^#/ { insec = 0 }
    insec && /^\|/ {
      line = $0
      gsub(/\\[|]/, "\001", line)
      n = split(line, cells, "|")
      if (n < 3) next
      cell = cells[n - 1]
      while (match(cell, /`[^`]+`/)) {
        print substr(cell, RSTART + 1, RLENGTH - 2)
        cell = substr(cell, RSTART + RLENGTH)
      }
    }
  '
}

PATTERNS=()
seen_patterns=""
while IFS= read -r tok; do
  [[ -n "$tok" ]] || continue
  # A cell also backticks non-path prose (a function name, a flag). Keep a
  # token only if it LOOKS like a path (has a `/` or a `.`) or actually names a
  # tracked file at HEAD (this is what keeps the bare `VERSION` row and drops
  # `temperloop_resolve_version`).
  case "$tok" in
    *' '*) continue ;;
    */*|*.*) : ;;
    *) git -C "$ROOT" cat-file -e "$HEAD:$tok" 2>/dev/null || continue ;;
  esac
  case " $seen_patterns " in *" $tok "*) continue ;; esac
  seen_patterns="$seen_patterns $tok"
  PATTERNS+=("$tok")
done <<EOF
$(contract_patterns)
EOF

if [[ ${#PATTERNS[@]} -lt $min_patterns ]]; then
  warn "FAIL — parsed only ${#PATTERNS[@]} contract-surface path pattern(s) from $VERSIONING_REL (expected at least $min_patterns)."
  warn "  This gate derives 'contract surface' from that file's '### The contract surface' table (the backticked paths in its 'Where it lives' column) rather than keeping a second copy of the definition."
  warn "  Either the heading/table was renamed or restructured, or the table really did shrink. Fix the table, or update this script's parse — do NOT leave the gate silently enforcing nothing."
  exit 1
fi

# --- which changed files are contract surface? ------------------------------
is_contract_path() {
  local path="$1" pat base
  base="${path##*/}"
  for pat in "${PATTERNS[@]}"; do
    if [[ "$pat" == */* ]]; then
      # shellcheck disable=SC2053  # intentional unquoted glob match
      [[ "$path" == $pat ]] && return 0
    else
      # A bare token (`VERSION`, `boards.conf`, `*-schema.md`) matches by
      # basename anywhere in the tree — that is how the table writes those rows.
      # shellcheck disable=SC2053  # intentional unquoted glob match
      [[ "$base" == $pat || "$path" == $pat ]] && return 0
    fi
  done
  return 1
}

TOUCHED=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if is_contract_path "$f"; then
    TOUCHED="$TOUCHED$f"$'\n'
  fi
done <<EOF
$CHANGED
EOF

if [[ -z "$TOUCHED" ]]; then
  say "OK — no contract-surface path changed against $BASE (per $VERSIONING_REL § The contract surface); no [Unreleased] entry required"
  exit 0
fi

# --- explicit, recorded opt-out ---------------------------------------------
# The `none`/`skip` verb of the shared marker grammar (see the header): waives
# property (1) only. It never waives the released-section-scope check above —
# "this change ships nothing" says nothing about whether editing a shipped
# release's record was intended.
if find_marker "$SKIP_MARKER_RE" "$CHANGELOG_GATE_SKIP_LABEL"; then
  say "OK — contract surface changed, but the author explicitly opted out via the $MARKER_VIA: $MARKER_HIT"
  exit 0
fi

# --- did this change add an [Unreleased] entry? -----------------------------
changelog_unreleased_body "$tmpdir/base.md"  > "$tmpdir/base-unreleased.txt"
changelog_unreleased_body "$tmpdir/head.md"  > "$tmpdir/head-unreleased.txt"

# An "entry" = at least one added, non-blank line under [Unreleased] that is
# more than a bare `###` sub-heading. `diff`'s `>` side is used (rather than a
# set-membership test) so re-adding a line that also exists elsewhere in the
# section still counts.
ADDED_ENTRY="$(diff "$tmpdir/base-unreleased.txt" "$tmpdir/head-unreleased.txt" 2>/dev/null \
  | grep -E '^> ' \
  | sed -e 's/^> //' \
  | grep -Ev '^[[:space:]]*$' \
  | grep -Ev '^[[:space:]]*#+[[:space:]]' \
  | head -3 || true)"

if [[ -n "$ADDED_ENTRY" ]]; then
  say "OK — contract surface changed and CHANGELOG.md's [Unreleased] section gained an entry:"
  printf '%s\n' "$ADDED_ENTRY" | sed -e 's/^/  + /'
  exit 0
fi

# A RELEASE CUT legitimately empties [Unreleased] by moving its body into a new
# version section. Recognize that by the version-heading set growing.
BASE_VERSIONS="$(changelog_version_headings "$tmpdir/base.md" | sort)"
HEAD_VERSIONS="$(changelog_version_headings "$tmpdir/head.md" | sort)"
NEW_VERSIONS="$(comm -13 <(printf '%s\n' "$BASE_VERSIONS") <(printf '%s\n' "$HEAD_VERSIONS") 2>/dev/null | grep -Ev '^[[:space:]]*$' || true)"
if [[ -n "$NEW_VERSIONS" ]]; then
  say "OK — release cut: CHANGELOG.md gained version section(s) $(printf '%s' "$NEW_VERSIONS" | tr '\n' ' ')"
  exit 0
fi

# --- violation --------------------------------------------------------------
warn "FAIL — this change touches contract surface but adds nothing to CHANGELOG.md's '## [Unreleased]' section."
warn ""
warn "  Contract-surface paths changed (per $VERSIONING_REL § The contract surface):"
printf '%s' "$TOUCHED" | sed -e 's/^/    - /' >&2
warn ""
warn "  Why this is enforced: pre-1.0, the breaking signal rides the CHANGELOG, not the version number."
warn "  update-kernel's downstream acknowledgment gate reads BREAKING markers out of the CHANGELOG range,"
warn "  so an absent entry cannot carry one — a breaking change with no entry ships with that gate silently passing."
warn ""
warn "  To fix: add a bullet under '## [Unreleased]' in $CHANGELOG_REL, classified per $VERSIONING_REL's"
warn "  bump-rules table (### Added / ### Changed / ### Fixed / ### Removed), and mark the section BREAKING"
warn "  with a migration note if an overlay must adapt."
warn ""
warn "  To opt out (a genuinely non-shipping change — a prose chore, a comment rewording, a test-only edit):"
warn "    - add the '$CHANGELOG_GATE_SKIP_LABEL' label to the PR, or"
warn "    - put a line 'Changelog: none - <reason>' in the PR body, or"
warn "    - put that same line in a commit message (the channel that works before the PR exists)."
warn "  The reason is required — the point is that skipping is a RECORDED CHOICE, not an oversight."
exit 1
