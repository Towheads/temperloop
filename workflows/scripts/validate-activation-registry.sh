#!/usr/bin/env bash
#
# validate-activation-registry.sh — assert every class-A "static-second-
# surface" activation predicate still resolves to two present in-tree files.
#
# The activation-completeness contract (claude/plan-schema.md § Optional
# `activation:` block, Decisions/temperloop - Activation-completeness
# contract) requires a product-source plan item to declare HOW `/build`
# confirms the item's own output is actually wired into the running path —
# not just built. A class-A block is the synchronous / in-repo case:
#
#   - activation:
#     - class: A
#     - proof: "grep -q GeminiRunner evals/runners/__init__.py"
#
# This script is the validate-live-drain.sh MOLD applied to that registry:
# same skeleton, same banner style, same "collect every failure, then report
# once" shape, same exit-code contract (0 = pass, non-zero = at least one
# anchor missing).
#
# SCOPE — class-A "static-second-surface" ONLY. A class-A `proof:` is an
# arbitrary shell predicate (`/build` Step 3e.6 just runs it); this
# validator does NOT execute arbitrary proof commands in CI. It instead
# recognizes only the narrow, mechanically-checkable subclass whose
# reachability reduces to "two files are present in the tree":
#   - the DECLARED surface — the item's own `files:` entries (what was
#     built);
#   - the ACTIVATING surface — the file argument of `proof:`, recognized
#     only when `proof:`'s leading command is one of the static file-check
#     family (`grep`, `test`, `[`, `[[`, `stat`, `ls`, `cat`, `find`) — the
#     idiom `/build`'s own worked example uses
#     (`grep -q GeminiRunner evals/runners/__init__.py`). The activating
#     surface is the LAST non-flag argument (trailing shell punctuation
#     like a closing `]` stripped), which is where these idioms place the
#     file being checked.
# A class-A block whose `proof:` leading command isn't in that family
# (e.g. it shells out to a script, curls a port, or checks process state)
# is OUT OF SCOPE for this validator and is reported as "skip" (not a
# failure) — it is a class-A block, just not one this validator's
# static-file check can adjudicate. This is a DELIBERATE, documented
# limitation, not a silent miss: a differently-shaped class-A predicate is
# still enforced at runtime by `/build` 3e.6 itself, this script only adds
# a CI-time, no-build-required backstop for the subset that's statically
# decidable.
#
# OUT OF SCOPE — class B (propagation-gated / cross-repo) and class C
# (time-deferred / soak) activations are explicitly NOT checked here: they
# are runtime-wiring / soak-discharged against the
# `Context/pipeline - pending activations.md` ledger (temperloop#317), not
# something a static in-repo file check can adjudicate. Also out of scope:
# the OTHER class-A subclasses whose proof isn't a static second-file
# check (see above) — those stay `/build`-Step-3e.6-enforced only.
#
# DATA SOURCE — Plans-archive/*.md (git-tracked), NEVER the live vault
# Plans/. A bare kernel checkout (and CI) has no Obsidian vault — reading
# live vault content here would break the stranger test (claude/CLAUDE.md's
# "a bare kernel checkout has no vault" invariant) and simply cannot run in
# CI. Plans-archive/ is the git-tracked, read-only archive of plan notes
# that IS available in every checkout, including CI's.
#
# EXPECTED NEAR-VACUOUS PASS TODAY: Plans-archive/ currently holds only
# pre-activation plans (authored before the `activation:` field existed) —
# zero class-A blocks, so this script finds zero anchors to check and exits
# 0 on a clean "nothing to validate" pass. That is the correct behavior for
# an empty corpus, not a vacuous-pass bug: the moment a `class: A` +
# `proof:` block lands in Plans-archive/ with a broken second-file anchor,
# this script fails (proven by the bash-3.2 dry-run in .build-verification.md).
#
# Usage: workflows/scripts/validate-activation-registry.sh
# Kept POSIX-bash-3.2 friendly (no mapfile/associative arrays, no `${x,,}`,
# every array/glob expansion guarded) so it runs on the macOS dev shell as
# well as Linux CI — this validator runs on macos-latest bash 3.2 in CI,
# where an empty Plans-archive glob or an empty match array is the LIKELY
# case, not an edge case.

set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCHIVE="$REPO/Plans-archive"

fail=0
skip=0
nchecked=0

# tokens <string> -> backticked tokens, one per line, backticks stripped.
# (Same helper as validate-live-drain.sh's tokens() — files: entries are
# backtick-quoted paths, exactly like that script's anchor tokens.)
tokens() {
  # shellcheck disable=SC2016
  printf '%s' "$1" | grep -oE '`[^`]+`' | tr -d '`' || true
}

# extract_activating_surface <proof-string> -> the file argument of a
# recognized static file-check predicate (grep/test/[/[[/stat/ls/cat/find),
# i.e. the LAST non-flag token with trailing shell punctuation (`]`, `)`,
# `"`, `;`, `,`) stripped — or empty if the proof's leading command isn't
# in that family (out of scope for this validator; see header § SCOPE).
extract_activating_surface() {
  local proof="$1" tok="" cmd="" candidate="" cleaned="" first=1
  for tok in $proof; do
    if [ "$first" = "1" ]; then
      cmd="$tok"
      first=0
    fi
    cleaned="$tok"
    while :; do
      case "$cleaned" in
        *']'|*')'|*'"'|*';'|*',') cleaned="${cleaned%?}" ;;
        *) break ;;
      esac
    done
    case "$cleaned" in
      -*|'') : ;;
      *) candidate="$cleaned" ;;
    esac
  done
  case "$cmd" in
    grep|test|stat|ls|cat|find|'['|'[[') printf '%s' "$candidate" ;;
    *) printf '' ;;
  esac
}

# path_exists <repo-relative-path> -> 0 if it exists under $REPO.
path_exists() {
  [ -n "$1" ] && [ -e "$REPO/$1" ]
}

# extract_activations <file> -> one line per class-A+proof block found:
#   SLUG<SOH>FILES_CELL<SOH>PROOF
# where SLUG is the item's slug, FILES_CELL is the raw `- files: ...` line
# tail (still backtick-quoted, decoded by tokens() below), and PROOF is the
# decoded proof predicate string. Extraction assumes the canonical two-line
# shape from claude/plan-schema.md's worked example (`- class: A` directly
# followed by `- proof: "..."` under the item's most recent `files:`
# entry) — a class-A block using a different field order or nesting is not
# recognized (out of scope for this mechanical extractor, same documented
# limitation as the proof-shape scoping above).
extract_activations() {
  awk -v SOH="$(printf '\1')" '
    /^- \[.\] \*\*/ {
      slug = ""
      if (match($0, /`slug:[ \t]*[a-z0-9-]+`/)) {
        s = substr($0, RSTART, RLENGTH)
        gsub(/`|slug:|[ \t]/, "", s)
        slug = s
      }
      files = ""
      class_ = ""
      next
    }
    /^[ \t]*-[ \t]*files:/ {
      sub(/^[ \t]*-[ \t]*files:[ \t]*/, "")
      files = $0
      next
    }
    /^[ \t]*-[ \t]*class:/ {
      c = $0
      sub(/^[ \t]*-[ \t]*class:[ \t]*/, "", c)
      gsub(/[ \t]/, "", c)
      class_ = c
      next
    }
    /^[ \t]*-[ \t]*proof:/ {
      if (class_ == "A" && slug != "") {
        p = $0
        sub(/^[ \t]*-[ \t]*proof:[ \t]*"/, "", p)
        sub(/"[ \t]*$/, "", p)
        print slug SOH files SOH p
      }
      class_ = ""
      next
    }
  ' "$1" 2>/dev/null || true
}

echo "source: $ARCHIVE (git-tracked; NEVER the live vault Plans/)"

if [ ! -d "$ARCHIVE" ]; then
  echo "no Plans-archive/ directory found — nothing to validate"
  echo "---"
  echo "checked: 0 | failures: 0 | skipped: 0"
  echo "validate-activation-registry: OK"
  exit 0
fi

# Enumerate Plans-archive/*.md via find, not a glob — bash-3.2-safe on an
# empty directory (no unbound-array / literal-glob-pattern risk).
plan_files="$(find "$ARCHIVE" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort || true)"

if [ -z "$plan_files" ]; then
  echo "no *.md files in $ARCHIVE — nothing to validate"
  echo "---"
  echo "checked: 0 | failures: 0 | skipped: 0"
  echo "validate-activation-registry: OK"
  exit 0
fi

while IFS= read -r pf; do
  [ -n "$pf" ] || continue

  rows="$(extract_activations "$pf")"
  [ -n "$rows" ] || continue

  while IFS= read -r row; do
    [ -n "$row" ] || continue

    slug="$(printf '%s' "$row" | awk -F'\1' '{print $1}')"
    files_cell="$(printf '%s' "$row" | awk -F'\1' '{print $2}')"
    proof="$(printf '%s' "$row" | awk -F'\1' '{print $3}')"

    label="$(basename "$pf")::$slug"

    declared="$(tokens "$files_cell" | sed -n '1p')"
    activating="$(extract_activating_surface "$proof")"

    if [ -z "$declared" ]; then
      echo "skip  $label (no files: entry — not the static-second-surface subclass)"
      skip=$((skip + 1))
      continue
    fi
    if [ -z "$activating" ]; then
      echo "skip  $label (proof not reducible to a second-file check — out of scope: $proof)"
      skip=$((skip + 1))
      continue
    fi

    nchecked=$((nchecked + 1))

    declared_ok=1
    path_exists "$declared" || declared_ok=0
    activating_ok=1
    path_exists "$activating" || activating_ok=0

    if [ "$declared_ok" = "1" ] && [ "$activating_ok" = "1" ]; then
      echo "ok    $label (declared: $declared | activating: $activating)"
    elif [ "$declared_ok" = "0" ] && [ "$activating_ok" = "0" ]; then
      echo "FAIL  $label (BOTH anchors missing: declared=$declared activating=$activating)"
      fail=$((fail + 1))
    elif [ "$declared_ok" = "0" ]; then
      echo "FAIL  $label (declared surface missing: $declared)"
      fail=$((fail + 1))
    else
      echo "FAIL  $label (activating surface missing: $activating)"
      fail=$((fail + 1))
    fi
  done <<EOF
$rows
EOF
done <<EOF
$plan_files
EOF

echo "---"
echo "checked: $nchecked | failures: $fail | skipped: $skip"
if [ "$fail" -ne 0 ]; then
  echo "validate-activation-registry: FAIL"
  exit 1
fi
echo "validate-activation-registry: OK"
