#!/usr/bin/env bash
#
# validate-design-brief.sh — brief-conformance lint (temperloop#216).
#
# SOURCE OF TRUTH: claude/design-schema.md. This script ENCODES that file's
# dimension list + disposition grammar; it does not invent its own rules. Any
# change to the grammar or the kernel dimension count belongs in
# claude/design-schema.md first, with this script updated to match.
#
# Two independent checks, run together (or selectably via flags):
#
#   (A) SCHEMA CITATION CHECK — claude/design-schema.md's own "Enforcing gate"
#       table column cites gates/scripts/docs by backtick-quoted path (e.g.
#       `workflows/scripts/validate-live-drain.sh`). design-schema.md § Kernel
#       dimension list says explicitly: "The 'Enforcing gate' column's own
#       citations are not themselves lint-checked today ... the forthcoming
#       brief-conformance lint (temperloop#216) is chartered to also resolve
#       this doc's gate citations, closing that gap." This check does exactly
#       that: every backtick-quoted, extension-terminated token (`*.sh`,
#       `*.md`, `*.py`, `*.txt`, `*.mjs`, `*.json`, `*.yml`, `*.yaml`, or a
#       glob ending in one of those) in the Enforcing-gate column must resolve
#       to a real tracked path (a glob must match at least one tracked file;
#       a bare filename with no `/` resolves by basename search). Non-path
#       backtick tokens (agent names, constants, error codes, command names
#       like `/design`) are not citations and are skipped — the extension
#       suffix is what marks a token as a path reference.
#
#   (B) BRIEF CONFORMANCE CHECK — a design brief (`Designs/<name>.md`, lives
#       in the knowledge store, NOT this repo — see design-schema.md
#       § File location) must carry a disposition line for every kernel
#       dimension (1..16, plus any letter-suffixed overlay addition, e.g.
#       `16a`), matching the grammar exactly (design-schema.md
#       § Disposition grammar):
#         disposition: filled
#         disposition: n/a — <reason>
#         disposition: deferred → <tracking ref>
#       No dimension may be silently absent (no heading at all), and no
#       heading may lack a disposition line (heading present, nothing or the
#       wrong shape follows). This is the "no-silent-skips rule."
#
# CI-vs-on-demand split (briefs live in the knowledge store, not this repo —
# CI has no vault to read):
#   - Bare invocation (no flags), what CI/quality-gates.sh runs: check (A)
#     only, against the real claude/design-schema.md. This is the only
#     in-repo "brief-shaped" artifact this repo tracks today (there is no
#     committed Designs/ brief in this repo to run check (B) against for
#     real) — check (B)'s failure/pass paths are proven by the dedicated
#     fixture test suite, workflows/scripts/tests/test_validate_design_brief.sh,
#     against the in-repo fixtures under
#     workflows/scripts/tests/fixtures/design-briefs/.
#   - `--brief FILE` — on-demand mode: lint an arbitrary brief file (check
#     (B) only). This is how a LIVE vault brief gets checked: read it out to
#     a file (or point at its exported path) and pass it here. Read-only —
#     this script never writes to FILE.
#   - `--schema FILE` — lint an arbitrary schema-shaped file (check (A) only)
#     instead of the real claude/design-schema.md. Used by the fixture test
#     suite to exercise the DANGLING-CITATION failure path without editing
#     the real schema doc.
#
# Usage:
#   workflows/scripts/validate-design-brief.sh                # (A) on the real schema
#   workflows/scripts/validate-design-brief.sh --brief FILE    # (B) on FILE
#   workflows/scripts/validate-design-brief.sh --schema FILE   # (A) on FILE
#
# Env overrides (used by the fixture test suite):
#   DESIGN_SCHEMA_ROOT   repo root to resolve citations against (default: this repo)
#
# Kept POSIX-bash-3.2 friendly (no mapfile/associative arrays) so it runs on
# the macOS dev shell as well as Linux CI.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${DESIGN_SCHEMA_ROOT:=$REPO_ROOT}"

KERNEL_DIM_COUNT=16
# Extension suffixes that mark a backtick token as a path citation (see (A)
# above) rather than an agent name, constant, error code, or command.
CITATION_EXT_RE='\.(sh|md|py|txt|mjs|json|yml|yaml)$'

mode="ci"
target_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --brief)
      [[ $# -ge 2 ]] || { echo "validate-design-brief: --brief requires a path" >&2; exit 2; }
      mode="brief"; target_file="$2"; shift 2 ;;
    --schema)
      [[ $# -ge 2 ]] || { echo "validate-design-brief: --schema requires a path" >&2; exit 2; }
      mode="schema"; target_file="$2"; shift 2 ;;
    -h|--help)
      echo "usage: $(basename "$0") [--brief FILE | --schema FILE]"
      exit 0 ;;
    *)
      echo "usage: $(basename "$0") [--brief FILE | --schema FILE]" >&2
      exit 2 ;;
  esac
done

failures=()

# ---------------------------------------------------------------------------
# (A) Schema citation check.
# ---------------------------------------------------------------------------
check_schema_citations() {
  local file="$1" root="$2"
  if [[ ! -f "$file" ]]; then
    failures+=("SCHEMA-NOT-FOUND  $file")
    return
  fi

  local rows nrows=0 ncites=0
  rows="$(awk '
    /^## Kernel dimension list/ { insec = 1; next }
    insec && /^## / { insec = 0 }
    insec && /^\|/ { print }
  ' "$file")"

  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    local dimnum cell
    dimnum="$(printf '%s' "$row" | awk -F'|' '{print $2}' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    # Only a real data row's # column is a bare dimension number (optionally
    # letter-suffixed) — this is what distinguishes a data row from the
    # header ("#") and separator ("---") rows without depending on exact
    # header text or column count.
    case "$dimnum" in
      [0-9]*)
        case "$dimnum" in
          *[!0-9a-z]*) continue ;;
        esac
        ;;
      *) continue ;;
    esac
    nrows=$((nrows + 1))
    cell="$(printf '%s' "$row" | awk -F'|' '{print $(NF-1)}')"

    local tok
    # shellcheck disable=SC2016  # backticks in the heredoc body below are literal (match `...` spans), not command substitution
    while IFS= read -r tok; do
      [[ -n "$tok" ]] || continue
      # Only extension-terminated tokens are treated as path citations —
      # this excludes agent names, constants (KERNEL_GATES), error codes
      # (STALE-EXEMPT), and command names (/design, /tidy).
      if ! printf '%s' "$tok" | grep -Eq "$CITATION_EXT_RE"; then
        continue
      fi
      ncites=$((ncites + 1))
      if ! resolve_citation "$tok" "$root"; then
        failures+=("DANGLING-CITATION  dimension $dimnum — '$tok' does not resolve to a tracked path under $root")
      fi
    done <<EOF
$(printf '%s' "$cell" | grep -oE '`[^`]+`' | tr -d '`')
EOF
  done <<EOF
$rows
EOF

  echo "schema citation check: $file — $nrows dimension row(s), $ncites citation(s) checked"
}

# resolve_citation <token> <root> -> rc 0 if it resolves to a tracked path.
resolve_citation() {
  local tok="$1" root="$2"
  case "$tok" in
    *'*'*)
      # Glob citation (e.g. claude/commands/*.md) — must match at least one
      # tracked file under root.
      ( cd "$root" 2>/dev/null && compgen -G "$tok" >/dev/null 2>&1 )
      return $? ;;
    */*)
      [[ -e "$root/$tok" ]]
      return $? ;;
    *)
      # Bare filename, no directory component — resolve by basename search
      # over the tracked tree.
      ( cd "$root" 2>/dev/null && git ls-files 2>/dev/null | grep -qE "(^|/)$(printf '%s' "$tok" | sed 's/[].[^$*\/]/\\&/g')\$" )
      return $? ;;
  esac
}

# ---------------------------------------------------------------------------
# (B) Brief conformance check.
# ---------------------------------------------------------------------------
check_brief_conformance() {
  local file="$1" label="$2"
  if [[ ! -f "$file" ]]; then
    failures+=("BRIEF-NOT-FOUND  $label ($file)")
    return
  fi

  local headings
  headings="$(grep -nE '^## [0-9]+[a-z]?\. ' "$file" || true)"

  local n
  for (( n = 1; n <= KERNEL_DIM_COUNT; n++ )); do
    if ! printf '%s\n' "$headings" | grep -qE "^[0-9]+:## ${n}\. "; then
      failures+=("MISSING-DIMENSION  $label — kernel dimension $n has no '## $n. <title>' heading")
    fi
  done

  local hline
  while IFS= read -r hline; do
    [[ -n "$hline" ]] || continue
    local lineno dimnum disp
    lineno="${hline%%:*}"
    dimnum="$(printf '%s' "$hline" | sed -E 's/^[0-9]+:## ([0-9]+[a-z]?)\..*/\1/')"
    disp="$(awk -v start="$lineno" '
      NR > start {
        if ($0 ~ /^## /) exit
        if ($0 ~ /^[[:space:]]*$/) next
        sub(/[[:space:]]+$/, "")
        print
        exit
      }
    ' "$file")"

    case "$disp" in
      "disposition: filled")
        : ;;
      "disposition: n/a — "*)
        [[ -n "${disp#disposition: n/a — }" ]] || \
          failures+=("BAD-DISPOSITION  $label dimension $dimnum — n/a with an empty reason")
        ;;
      "disposition: deferred → "*)
        [[ -n "${disp#disposition: deferred → }" ]] || \
          failures+=("BAD-DISPOSITION  $label dimension $dimnum — deferred with an empty tracking ref")
        ;;
      "")
        failures+=("MISSING-DISPOSITION  $label dimension $dimnum — no disposition line found before the next heading")
        ;;
      *)
        failures+=("BAD-DISPOSITION  $label dimension $dimnum — '$disp' matches none of filled | n/a — <reason> | deferred → <ref>")
        ;;
    esac
  done <<EOF
$headings
EOF

  echo "brief conformance check: $label — $(printf '%s\n' "$headings" | grep -c . || true) dimension heading(s) found"
}

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------
case "$mode" in
  ci)
    check_schema_citations "$DESIGN_SCHEMA_ROOT/claude/design-schema.md" "$DESIGN_SCHEMA_ROOT"
    ;;
  brief)
    check_brief_conformance "$target_file" "$(basename "$target_file")"
    ;;
  schema)
    check_schema_citations "$target_file" "$DESIGN_SCHEMA_ROOT"
    ;;
esac

echo "---"
if (( ${#failures[@]} > 0 )); then
  printf '%s\n' "${failures[@]}"
  echo "failures: ${#failures[@]}"
  echo "validate-design-brief: FAIL"
  exit 1
fi
echo "validate-design-brief: OK"
