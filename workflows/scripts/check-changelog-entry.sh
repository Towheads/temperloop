#!/usr/bin/env bash
#
# check-changelog-entry.sh — fail a PR that changes CONTRACT SURFACE but adds
# no `## [Unreleased]` entry to CHANGELOG.md (temperloop#960).
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
if ! git -C "$ROOT" show "$HEAD:$VERSIONING_REL" >/dev/null 2>&1; then
  say "skipped — no $VERSIONING_REL at $HEAD; nothing defines this tree's contract surface"
  exit 0
fi
if ! git -C "$ROOT" show "$HEAD:$CHANGELOG_REL" >/dev/null 2>&1; then
  say "skipped — no $CHANGELOG_REL at $HEAD; this tree keeps no changelog"
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
# One grammar: `Changelog: none — <reason>` (or `skip`), anchored at line start,
# reason required. Separator may be an em dash, one or two hyphens, or a colon.
MARKER_RE='^[[:space:]]*[Cc]hangelog:[[:space:]]*([Nn]one|[Ss]kip|NONE|SKIP)[[:space:]]*(—|--|-|:)[[:space:]]*[^[:space:]][^[:space:]][^[:space:]]'

marker_line() {
  # Echo the first matching marker line from stdin, if any.
  grep -E -m1 "$MARKER_RE" 2>/dev/null || true
}

OPT_OUT=""
OPT_OUT_VIA=""

# (a) PR label
if [[ -n "$PR_LABELS" ]]; then
  old_ifs="$IFS"
  IFS=','
  for label in $PR_LABELS; do
    # trim surrounding whitespace
    label="${label#"${label%%[![:space:]]*}"}"
    label="${label%"${label##*[![:space:]]}"}"
    if [[ "$label" == "$CHANGELOG_GATE_SKIP_LABEL" ]]; then
      OPT_OUT="label '$CHANGELOG_GATE_SKIP_LABEL'"
      OPT_OUT_VIA="PR label"
    fi
  done
  IFS="$old_ifs"
fi

# (b) PR body marker
if [[ -z "$OPT_OUT" && -n "$PR_BODY" ]]; then
  hit="$(printf '%s\n' "$PR_BODY" | marker_line)"
  if [[ -n "$hit" ]]; then
    OPT_OUT="$hit"
    OPT_OUT_VIA="PR body"
  fi
fi

# (c) commit-message trailer — the pre-PR / merge_group-visible channel
if [[ -z "$OPT_OUT" ]]; then
  hit="$(git -C "$ROOT" log --format=%B "$MERGE_BASE..$HEAD" 2>/dev/null | marker_line)"
  if [[ -n "$hit" ]]; then
    OPT_OUT="$hit"
    OPT_OUT_VIA="commit message"
  fi
fi

if [[ -n "$OPT_OUT" ]]; then
  say "OK — contract surface changed, but the author explicitly opted out via the $OPT_OUT_VIA: $OPT_OUT"
  exit 0
fi

# --- did this change add an [Unreleased] entry? -----------------------------
# shellcheck source=lib/changelog.sh
source "$SCRIPT_DIR/lib/changelog.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

git -C "$ROOT" show "$MERGE_BASE:$CHANGELOG_REL" > "$tmpdir/base.md" 2>/dev/null || : > "$tmpdir/base.md"
git -C "$ROOT" show "$HEAD:$CHANGELOG_REL"       > "$tmpdir/head.md" 2>/dev/null || : > "$tmpdir/head.md"

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
