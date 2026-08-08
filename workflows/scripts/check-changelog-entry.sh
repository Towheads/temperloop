#!/usr/bin/env bash
#
# check-changelog-entry.sh — the changelog merge gate. Two properties:
#
#   (1) COMPLETENESS (temperloop#960; cut over to FRAGMENTS in temperloop#1322)
#       — a PR that changes CONTRACT SURFACE must add a `changelog.d/`
#       fragment. A direct line under `## [Unreleased]` no longer satisfies it.
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
# THE PROPERTY IT HOLDS: at any commit on main, `## [Unreleased]` TOGETHER WITH
# the pending `changelog.d/` fragments describes everything on main that is not
# yet released.
#
# ── Why property (1) asks for a FRAGMENT (temperloop#1322) ─────────────────
# Requiring an `## [Unreleased]` line made every contract-surface PR edit the
# SAME file at the SAME anchor: 25 of the last 25 commits touching CHANGELOG.md,
# so any two concurrent PRs collided by construction. Under fragments each PR
# writes its own new file under `changelog.d/`, two concurrent PRs share no
# line, and the collision is structurally impossible rather than merely
# unlikely. `scripts/assemble-changelog.sh` folds the accumulated fragments
# into `## [Unreleased]` at the release cut. Direction ratified by the keystone
# spike (temperloop#1311); the filename grammar
# (`<slug>.<category>[.breaking].md`) and its parser live in lib/changelog.sh.
#
# THIS IS A BREAKING CHANGE FOR A VENDORING OVERLAY, and it degrades in two
# deliberately different directions (see the `changelog.d/` probe below):
#
#   * a tree carrying `.kernel-pin` (a VENDORING CONSUMER) with no
#     `changelog.d/` gets a legible, ACTIONABLE skip of property (1) — it keeps
#     building green and is told, on every run, exactly what to create;
#   * a tree with NEITHER `changelog.d/` NOR `.kernel-pin` is not a vendoring
#     consumer — it is a kernel checkout that LOST its fragment directory, and
#     it FAILS LOUDLY. A bare "no directory -> skip" would let the kernel's own
#     tree silently disable this gate, which is the very "quietly narrows to
#     zero" failure the contract-surface parse below refuses to commit.
#
# THE SAME DISCRIMINATOR GOVERNS THE `CHANGELOG.md` PROBE, which runs first. It
# once exited 0 unconditionally, which made the fail-loud arm above UNREACHABLE
# for a tree that had lost CHANGELOG.md too — probe ORDER was the only thing
# standing between this gate and the invariant stated right here. So: no
# `CHANGELOG.md` and no `.kernel-pin` FAILS LOUDLY; no `CHANGELOG.md` WITH a pin
# is the consumer that genuinely keeps no changelog, and gets the legible skip.
#
# The `.kernel-pin` probe goes through `git show "$HEAD:.kernel-pin"` and never
# a filesystem `[[ -f "$ROOT/.kernel-pin" ]]`: a `<rev>:<path>` not starting
# with `./` resolves against the TOP LEVEL of the tree, so if $ROOT lands on
# the kernel subtree root inside an overlay a filesystem test would look in
# `kernel/` and miss the overlay-root pin.
#
# Property (2) is UNCHANGED and its merge-base discriminator is untouched — but
# its reason to exist now narrows to the RELEASE-CUT PR, since that is the only
# PR that still edits CHANGELOG.md at all. It stays because the cut is exactly
# where a released section can be stolen from.
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
FRAGMENT_DIR_REL="changelog.d"
KERNEL_PIN_REL=".kernel-pin"

# Sanity floor on the parsed contract-surface pattern count. A lowercase local,
# deliberately not an operator setting: it exists only to distinguish "the
# table parsed" from "the table moved and we now enforce nothing", and no
# adopter has a reason to tune it.
min_patterns=8

# How many offending lines the section-scope report quotes per direction, per
# section. Also a lowercase local, deliberately not an operator setting: it
# tunes only how much evidence the failure message prints, never the verdict.
sec_report_max=6

# ANCHORED range, never a fixed line count. A fixed `2,20p` printed whatever
# happened to sit in the first 20 lines, so the header growing pushed `Usage:`
# and the exit-code table out of `--help` entirely — 19 lines of rationale and
# no usage, while the kernel's own § Tool invocation discipline tells a caller
# to read exactly that block before invoking. The fallback matters for the same
# reason the anchors do: if the start anchor is ever renamed, print the whole
# header rather than an empty --help.
usage() {
  local text
  text="$(sed -n '/^# Usage:/,/^[[:space:]]*$/p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//')"
  if [[ -z "${text//[[:space:]]/}" ]]; then
    text="$(sed -n '2,/^set -uo pipefail/p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//')"
  fi
  printf '%s\n' "$text"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --head) HEAD="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "check-changelog-entry: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

say()  { printf 'check-changelog-entry: %s\n' "$1"; }
warn() { printf 'check-changelog-entry: %s\n' "$1" >&2; }

# The pinned kernel release named by `.kernel-pin`, or a legible placeholder.
# Read through `git show` for the same top-level-resolution reason the probes
# are (see the header): a filesystem test would look in `kernel/` when $ROOT
# lands on the kernel subtree root inside an overlay.
pinned_kernel_tag() {
  local t
  t="$(git -C "$ROOT" show "$HEAD:$KERNEL_PIN_REL" 2>/dev/null \
    | awk '$1 == "tag" { print $2; exit }')"
  [[ -n "$t" ]] || t="unknown (unparseable $KERNEL_PIN_REL)"
  printf '%s' "$t"
}

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
#
# SAME `.kernel-pin` DISCRIMINATOR AS THE changelog.d/ PROBE BELOW, for the same
# reason. This probe runs FIRST, and when it exited 0 unconditionally the
# fail-loud arm below was UNREACHABLE for a tree that had also lost
# CHANGELOG.md: probe ORDER was the only thing standing between this gate and
# the invariant its own header states. A kernel checkout that lost CHANGELOG.md
# is at least as broken as one that lost changelog.d/, and a gate that quietly
# narrows to zero is worse than no gate.
if ! git -C "$ROOT" show "$HEAD:$CHANGELOG_REL" >/dev/null 2>&1; then
  if ! git -C "$ROOT" show "$HEAD:$KERNEL_PIN_REL" >/dev/null 2>&1; then
    warn "FAIL — no $CHANGELOG_REL at $HEAD, and no $KERNEL_PIN_REL either."
    warn ""
    warn "  $KERNEL_PIN_REL is what marks a tree as a VENDORING CONSUMER of this kernel. Without it,"
    warn "  this is the kernel's own checkout — and a kernel checkout with no $CHANGELOG_REL has"
    warn "  silently disabled BOTH of this gate's properties: completeness has nothing to be complete"
    warn "  about, and the released-section-scope check has no sections to scope. A gate that quietly"
    warn "  narrows to zero is worse than no gate, so this fails rather than skipping."
    warn ""
    warn "  If this IS the kernel (or a fork of it): restore $CHANGELOG_REL — it is the record"
    warn "  update-kernel's downstream acknowledgment gate reads BREAKING markers out of."
    warn "  If this is a vendoring overlay that genuinely keeps no changelog: its repo root is missing"
    warn "  $KERNEL_PIN_REL. Restore the pin (it is written by 'make update-kernel')."
    exit 1
  fi
  say "skipped — no $CHANGELOG_REL at $HEAD; this tree keeps no changelog (vendored kernel $(pinned_kernel_tag)). Neither property is enforced here."
  exit 0
fi

# --- the changelog.d/ probe: legible skip, or a LOUD failure ----------------
# `git show <rev>:<dir>` exits 0 for a present tree and non-zero for an absent
# one, so the same probe shape as the CHANGELOG check above generalizes to a
# directory unchanged.
#
# This runs HERE — before property (2), not inside property (1) — on purpose.
# The fail-loud arm is a statement about the TREE, not about one PR's diff, so
# a kernel checkout that lost `changelog.d/` must fail on EVERY PR, including
# one that touches no contract surface at all. The skip arm sets a flag instead
# of exiting, so an un-migrated overlay still gets property (2) enforced: the
# released-section-scope check is about CHANGELOG.md and stays valid whether or
# not the tree has migrated.
FRAGMENTS_ENFORCEABLE=1
if ! git -C "$ROOT" show "$HEAD:$FRAGMENT_DIR_REL" >/dev/null 2>&1; then
  if ! git -C "$ROOT" show "$HEAD:$KERNEL_PIN_REL" >/dev/null 2>&1; then
    warn "FAIL — no $FRAGMENT_DIR_REL/ at $HEAD, and no $KERNEL_PIN_REL either."
    warn ""
    warn "  $KERNEL_PIN_REL is what marks a tree as a VENDORING CONSUMER of this kernel. Without it,"
    warn "  this is the kernel's own checkout — and a kernel checkout that has lost its fragment"
    warn "  directory has silently disabled this gate's completeness property. A gate that quietly"
    warn "  narrows to zero is worse than no gate, so this fails rather than skipping."
    warn ""
    warn "  If this IS the kernel (or a fork of it): restore the directory —"
    warn "    mkdir -p $FRAGMENT_DIR_REL && touch $FRAGMENT_DIR_REL/.gitkeep && git add $FRAGMENT_DIR_REL/.gitkeep"
    warn "  If this is a vendoring overlay: its repo root is missing $KERNEL_PIN_REL. Restore the pin"
    warn "  (it is written by 'make update-kernel'), or create $FRAGMENT_DIR_REL/ and adopt fragments."
    exit 1
  fi
  FRAGMENTS_ENFORCEABLE=0
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
  say "OK — no contract-surface path changed against $BASE (per $VERSIONING_REL § The contract surface); no $FRAGMENT_DIR_REL/ fragment required"
  exit 0
fi

# --- legible degradation for an un-migrated vendoring consumer --------------
# Reached only when the tree carries `.kernel-pin` (the fail-loud arm above
# already handled the other case) AND contract surface actually changed — i.e.
# exactly where this gate would otherwise have enforced. The notice is
# ACTIONABLE rather than bare: it names the kernel release whose gate is
# running, the BREAKING classification, and the one command that enables it.
if [[ "$FRAGMENTS_ENFORCEABLE" == "0" ]]; then
  pinned_tag="$(pinned_kernel_tag)"
  say "skipped — $CHANGELOG_REL exists but there is no $FRAGMENT_DIR_REL/ at $HEAD; this tree has not migrated to changelog fragments (vendored kernel $pinned_tag; the fragment requirement shipped as a BREAKING change, temperloop#1322). Completeness is NOT enforced here until it does."
  say "  To enable: mkdir -p $FRAGMENT_DIR_REL && touch $FRAGMENT_DIR_REL/.gitkeep && git add $FRAGMENT_DIR_REL/.gitkeep — then author one fragment per contract-surface PR, named <slug>.<category>[.breaking].md."
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

# --- did this change add a changelog.d/ fragment? ---------------------------
# An "entry" is now a CONFORMING FRAGMENT PRESENT AT HEAD. Three filters, each
# closing a way an apparent entry could still be a lost one:
#
#   * the basename must parse under the lib's filename grammar — an
#     unrecognised name is never assembled, so it is not an entry;
#   * a path one level down (`changelog.d/sub/x.added.md`) is rejected — the
#     assembler only reads regular files DIRECTLY in the directory, so a
#     nested file would sit there looking pending while the release shipped
#     without it;
#   * the file must EXIST at HEAD with at least one non-blank line. Existence
#     at HEAD is what stops a release cut's fragment DELETIONS from reading as
#     entries; the non-blank test is the fragment-era analogue of the old
#     "a bare `###` sub-heading is not an entry" rule (an empty fragment is a
#     lost entry, and the assembler refuses to cut on one).
ADDED_FRAGMENTS=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  case "$f" in
    "$FRAGMENT_DIR_REL"/*) frag_name="${f#"$FRAGMENT_DIR_REL"/}" ;;
    *) continue ;;
  esac
  case "$frag_name" in */*) continue ;; esac
  changelog_fragment_parse "$frag_name" >/dev/null 2>&1 || continue
  git -C "$ROOT" show "$HEAD:$f" 2>/dev/null | grep -E '[^[:space:]]' >/dev/null || continue
  ADDED_FRAGMENTS="$ADDED_FRAGMENTS$f"$'\n'
done <<EOF
$CHANGED
EOF

if [[ -n "$ADDED_FRAGMENTS" ]]; then
  say "OK — contract surface changed and this change carries a $FRAGMENT_DIR_REL/ fragment:"
  printf '%s' "$ADDED_FRAGMENTS" | sed -e 's/^/  + /'
  exit 0
fi

# A RELEASE CUT legitimately carries no NEW fragment: it runs the assembler,
# which folds the pending fragments into [Unreleased] and DELETES them, then
# moves that body into a new version section. Recognize it the same way as
# before — by the version-heading set growing — which is unaffected by the
# fragment cutover.
BASE_VERSIONS="$(changelog_version_headings "$tmpdir/base.md" | sort)"
HEAD_VERSIONS="$(changelog_version_headings "$tmpdir/head.md" | sort)"
NEW_VERSIONS="$(comm -13 <(printf '%s\n' "$BASE_VERSIONS") <(printf '%s\n' "$HEAD_VERSIONS") 2>/dev/null | grep -Ev '^[[:space:]]*$' || true)"
if [[ -n "$NEW_VERSIONS" ]]; then
  say "OK — release cut: CHANGELOG.md gained version section(s) $(printf '%s' "$NEW_VERSIONS" | tr '\n' ' ')"
  exit 0
fi

# --- violation --------------------------------------------------------------
warn "FAIL — this change touches contract surface but adds no $FRAGMENT_DIR_REL/ fragment."
warn ""
warn "  Contract-surface paths changed (per $VERSIONING_REL § The contract surface):"
printf '%s' "$TOUCHED" | sed -e 's/^/    - /' >&2
warn ""
warn "  Why this is enforced: pre-1.0, the breaking signal rides the CHANGELOG, not the version number."
warn "  update-kernel's downstream acknowledgment gate reads BREAKING markers out of the CHANGELOG range,"
warn "  so an absent entry cannot carry one — a breaking change with no entry ships with that gate silently passing."
warn ""
warn "  To fix: add ONE new file under $FRAGMENT_DIR_REL/ — not a line in $CHANGELOG_REL. Editing"
warn "  $CHANGELOG_REL directly is what made every concurrent PR collide on one anchor; a fragment is a"
warn "  new path nobody else writes, so two PRs cannot conflict. The release cut assembles them"
warn "  (scripts/assemble-changelog.sh) into '## [Unreleased]' and deletes them."
warn ""
warn "    $FRAGMENT_DIR_REL/<slug>.<category>[.breaking].md"
warn ""
warn "      <slug>      [A-Za-z0-9][A-Za-z0-9_-]* — no dots. Convention: <issue#>-<branch-slug>."
warn "      <category>  added | changed | deprecated | removed | fixed | security"
warn "      .breaking   add it when an overlay must change to keep working; it becomes the"
warn "                  '— BREAKING' heading suffix update-kernel's acknowledgment gate reads."
warn ""
warn "  The body is the markdown bullet that would have gone under '### <Category>' — no h1/h2/h3"
warn "  heading of its own (the assembler owns those), and never empty. See $FRAGMENT_DIR_REL/README.md."
warn ""
warn "  To opt out (a genuinely non-shipping change — a prose chore, a comment rewording, a test-only edit):"
warn "    - add the '$CHANGELOG_GATE_SKIP_LABEL' label to the PR, or"
warn "    - put a line 'Changelog: none - <reason>' in the PR body, or"
warn "    - put that same line in a commit message (the channel that works before the PR exists)."
warn "  The reason is required — the point is that skipping is a RECORDED CHOICE, not an oversight."
exit 1
