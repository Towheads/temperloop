#!/usr/bin/env bash
#
# validate-lexicon.sh — assert lexicon.tsv is well-formed.
#
# Checks every data row in workflows/scripts/drain/lexicon.tsv:
#   1. Has exactly 3 tab-separated fields: pattern, category, match_type.
#   2. category is one of the known set.
#   3. match_type is "literal" or "regex".
#   4. regex rows compile under `grep -E` (case-insensitive).
#   5. pattern is non-empty.
#
# Usage: workflows/scripts/drain/validate-lexicon.sh
# Exit 0 = OK, exit 1 = one or more validation failures.
#
# Kept POSIX-bash-3.2 compatible (no mapfile/associative arrays) so it runs
# on the macOS dev shell as well as Linux CI.

set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Both tell lexicons share the same schema and are linted together: lexicon.tsv
# (user-turn tells) and lexicon-assistant.tsv (assistant-turn self-worked-around-
# defect tells, foundation #444).
LEXICON_FILES="$REPO/workflows/scripts/drain/lexicon.tsv $REPO/workflows/scripts/drain/lexicon-assistant.tsv"

VALID_CATEGORIES="friction-slug filed-at-source self-critique trust-rupture failure-report flagging state-collision filing-decision deferral worked-around-defect self-correction"
VALID_MATCH_TYPES="literal regex"

fail=0
nrows=0

for LEXICON in $LEXICON_FILES; do
echo "=== $LEXICON ==="
lineno=0
while IFS= read -r line; do
  lineno=$((lineno + 1))

  # Skip blank lines and comment lines (start with #, possibly with leading spaces).
  case "$line" in
    ''|'#'*) continue ;;
    *'	'*) ;;  # has a tab — proceed
    *)
      echo "FAIL  line $lineno: no tab separator in non-comment line: $line"
      fail=$((fail + 1))
      continue ;;
  esac

  nrows=$((nrows + 1))

  # Split on tabs.  Field 1 = pattern, field 2 = category, field 3 = match_type.
  pattern="$(printf '%s' "$line" | cut -f1)"
  category="$(printf '%s' "$line" | cut -f2)"
  match_type="$(printf '%s' "$line" | cut -f3)"
  # Detect extra fields (a 4th tab means a stray field).
  field_count="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"

  row_fail=0

  # Check field count.
  if [ "$field_count" -ne 3 ]; then
    echo "FAIL  line $lineno: expected 3 fields, got $field_count: $line"
    row_fail=$((row_fail + 1))
  fi

  # Check pattern non-empty.
  if [ -z "$pattern" ]; then
    echo "FAIL  line $lineno: empty pattern"
    row_fail=$((row_fail + 1))
  fi

  # Check category.
  cat_ok=0
  for c in $VALID_CATEGORIES; do
    if [ "$category" = "$c" ]; then cat_ok=1; break; fi
  done
  if [ "$cat_ok" -eq 0 ]; then
    echo "FAIL  line $lineno: unknown category '$category' (valid: $VALID_CATEGORIES)"
    row_fail=$((row_fail + 1))
  fi

  # Check match_type.
  mt_ok=0
  for m in $VALID_MATCH_TYPES; do
    if [ "$match_type" = "$m" ]; then mt_ok=1; break; fi
  done
  if [ "$mt_ok" -eq 0 ]; then
    echo "FAIL  line $lineno: unknown match_type '$match_type' (valid: $VALID_MATCH_TYPES)"
    row_fail=$((row_fail + 1))
  fi

  # For regex rows: verify the pattern compiles under grep -E.
  # grep exits 0 (match), 1 (no match), or 2 (error/bad regex).
  # We pipe a string that won't match and accept exit 0 or 1; only 2 is a failure.
  # The || true prevents set -e from firing on exit 1 (no-match is not an error here).
  if [ "$match_type" = "regex" ] && [ -n "$pattern" ]; then
    rc=0
    printf 'validate-lexicon-probe\n' | grep -Ei "$pattern" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "FAIL  line $lineno: regex does not compile: $pattern"
      row_fail=$((row_fail + 1))
    fi
  fi

  if [ "$row_fail" -eq 0 ]; then
    echo "ok    line $lineno: [$match_type/$category] $pattern"
  fi
  fail=$((fail + row_fail))
done < "$LEXICON"
done

echo "---"
echo "rows: $nrows | failures: $fail"
if [ "$fail" -ne 0 ]; then
  echo "validate-lexicon: FAIL"
  exit 1
fi
echo "validate-lexicon: OK"
