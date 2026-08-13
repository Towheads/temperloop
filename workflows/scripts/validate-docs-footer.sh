#!/usr/bin/env bash
#
# validate-docs-footer.sh — AI-authorship footer gate for the product docs.
#
# Every rewritten product-docs page carries a provenance footer naming the
# exact model that wrote it and when — transparency about AI authorship is a
# stated property of this repo's docs, so it is enforced mechanically, not
# by convention. This gate checks that every in-scope page ends with a
# well-formed footer:
#
#   ---
#
#   *Written by <model-id> on <YYYY-MM-DD>.*
#   *Last updated by <model-id> on <YYYY-MM-DD>.*     (zero or more)
#
# Rules enforced:
#   - The final non-blank line is a `*Written by …*` or `*Last updated by …*`
#     line; exactly one `*Written by …*` line exists per file (original
#     authorship is appended-to, never duplicated or erased).
#   - <model-id> matches a strict pattern (claude-[a-z0-9-]+), never a vague
#     "Claude" or free text; <date> is a real-shaped ISO date (month 01-12,
#     day 01-31).
#   - A `---` rule precedes the footer block.
#
# Scope: README.md + docs/**/*.md, MINUS the exemption list below — pages
# the docs rewrite deliberately left untouched (a footer asserts authorship,
# so stamping an unrewritten page would be false). The list is expected to
# shrink as pages are rewritten: an exempt page that GAINS a footer fails
# the gate with a remove-the-exemption message, so the list can never go
# stale silently.
#
# Usage:
#   workflows/scripts/validate-docs-footer.sh
#
# Env seams (tests):
#   DOCS_FOOTER_ROOT   repo root to scan (default: this script's repo)
#
# Exit codes: 0 = all in-scope pages conform; 1 = one or more violations
# (each named with file + reason); 2 = usage/internal error.
#
# BSD/macOS-safe: bash 3.2, POSIX find/grep/awk only — no GNU extensions.
# Deliberately no `set -e`: grep's expected exit-1-on-no-match drives the
# logic, and every verdict path is explicitly checked.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
: "${DOCS_FOOTER_ROOT:=$REPO_ROOT}"
ROOT="${DOCS_FOOTER_ROOT%/}"

# ---------------------------------------------------------------------------
# Exemption list — in-scope paths deliberately left untouched by the docs
# rewrite, each with a one-line reason. Prefix entries (trailing /) exempt a
# whole family. Rewrite one of these pages? Add its footer AND remove it here.
# ---------------------------------------------------------------------------
EXEMPT_PATHS=(
  "docs/features/"                # gate-owned five-section reference pages (validate-feature-docs.sh); not part of the product-docs rewrite
  "docs/adr/"                     # historical decision records — immutable by process; stamping them would assert false authorship
  "docs/failure-modes/"           # narrative chapters already at the bar; deliberately untouched by the rewrite
  "docs/CONTRIBUTING.md"          # contributor-facing process doc, outside the product-docs scope
  "docs/model-fanout-inventory.md" # maintainer-internal inventory, outside the product-docs scope
)

MODEL_RE='claude-[a-z0-9]+([.-][a-z0-9]+)*'
DATE_RE='20[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])'
WRITTEN_RE="^\*Written by ${MODEL_RE} on ${DATE_RE}\.\*$"
UPDATED_RE="^\*Last updated by ${MODEL_RE} on ${DATE_RE}\.\*$"

is_exempt() {
  # $1 = repo-relative path
  local rel="$1" e
  for e in "${EXEMPT_PATHS[@]}"; do
    if [ "${e%/}" != "$e" ]; then
      # prefix entry (trailing /) — exempts the whole family
      case "$rel" in "$e"*) return 0 ;; esac
    else
      [ "$rel" = "$e" ] && return 0
    fi
  done
  return 1
}

has_written_line() {
  # any well-formed *Written by* line anywhere in the file
  grep -qE "$WRITTEN_RE" "$1"
}

violations=0
violate() {
  # $1 = repo-relative path, $2 = reason
  echo "FAIL  $1 — $2"
  violations=$((violations + 1))
}

check_file() {
  # $1 = absolute path, $2 = repo-relative path
  local abs="$1" rel="$2"

  if [ ! -r "$abs" ]; then
    echo "validate-docs-footer: unreadable in-scope file: $rel" >&2
    exit 2
  fi

  # The final non-blank line must be a footer line.
  local last
  last="$(awk 'NF { l = $0 } END { print l }' "$abs")"
  if ! printf '%s\n' "$last" | grep -E "$WRITTEN_RE|$UPDATED_RE" >/dev/null; then
    if has_written_line "$abs"; then
      violate "$rel" "footer exists but is not the last non-blank content — the authorship footer must end the file"
    elif grep -qE '^\*(Written|Last updated) by ' "$abs"; then
      violate "$rel" "malformed footer — expected '*Written by <model-id> on <YYYY-MM-DD>.*' with a strict model id (e.g. claude-fable-5) and a real ISO date"
    else
      violate "$rel" "missing authorship footer — every rewritten page ends with '---' then '*Written by <model-id> on <YYYY-MM-DD>.*'"
    fi
    return
  fi

  # Exactly one *Written by* line (appends use *Last updated by*, never a
  # second *Written by*; original authorship is never erased or duplicated).
  local written_count
  written_count="$(grep -cE "$WRITTEN_RE" "$abs")"
  if [ "$written_count" -eq 0 ]; then
    violate "$rel" "has a '*Last updated by …*' line but no well-formed '*Written by …*' line — the original authorship line is required"
    return
  fi
  if [ "$written_count" -gt 1 ]; then
    violate "$rel" "carries $written_count '*Written by …*' lines — later revisions append '*Last updated by …*' instead"
    return
  fi

  # Every non-blank line AFTER the *Written by* line must itself be a
  # well-formed *Last updated by* line — no prose, and no malformed append,
  # may hide inside the footer block.
  local wline tail_bad
  wline="$(grep -nE "$WRITTEN_RE" "$abs" | head -1 | cut -d: -f1)"
  tail_bad="$(awk -v n="$wline" 'NR > n && NF' "$abs" | grep -cvE "$UPDATED_RE")"
  if [ "$tail_bad" -gt 0 ]; then
    violate "$rel" "footer block contains $tail_bad non-footer or malformed line(s) after '*Written by …*' — only well-formed '*Last updated by <model-id> on <YYYY-MM-DD>.*' lines may follow"
    return
  fi

  # A --- rule must immediately precede the footer block: the nearest
  # non-blank line above the *Written by* line is the rule itself (a
  # frontmatter '---' at the top of a page with body content never
  # satisfies this; a degenerate body-less page is out of scope).
  local prev=""
  if [ "$wline" -gt 1 ]; then
    prev="$(head -n $((wline - 1)) "$abs" | awk 'NF { l = $0 } END { print l }')"
  fi
  if ! printf '%s\n' "$prev" | grep -E '^---[[:space:]]*$' >/dev/null; then
    violate "$rel" "footer lacks the preceding '---' rule — the footer block is '---', blank line, then the authorship line(s)"
  fi
}

main() {
  [ -d "$ROOT" ] || { echo "validate-docs-footer: root not found: $ROOT" >&2; exit 2; }

  local files=()
  [ -f "$ROOT/README.md" ] && files+=("README.md")
  while IFS= read -r f; do
    files+=("${f#"$ROOT"/}")
  done < <(find "$ROOT/docs" -name '*.md' -type f 2>/dev/null | LC_ALL=C sort)

  if [ "${#files[@]}" -eq 0 ]; then
    echo "validate-docs-footer: nothing in scope under $ROOT" >&2
    exit 2
  fi

  local rel checked=0 exempted=0
  for rel in "${files[@]}"; do
    if is_exempt "$rel"; then
      exempted=$((exempted + 1))
      # A stale exemption is itself a failure: an exempt page that gained a
      # footer has been rewritten and must leave the list.
      if has_written_line "$ROOT/$rel"; then
        violate "$rel" "is on the exemption list but carries an authorship footer — remove it from EXEMPT_PATHS in $(basename "$0")"
      fi
      continue
    fi
    checked=$((checked + 1))
    check_file "$ROOT/$rel" "$rel"
  done

  if [ "$violations" -gt 0 ]; then
    echo ""
    echo "validate-docs-footer: $violations violation(s) across $checked checked page(s) ($exempted exempt)."
    echo "Footer contract: the file ends with '---', a blank line, then"
    echo "'*Written by <model-id> on <YYYY-MM-DD>.*' (+ optional '*Last updated by …*' lines)."
    exit 1
  fi

  echo "validate-docs-footer: OK — $checked page(s) conform, $exempted exempt."
}

main "$@"
