#!/usr/bin/env bash
#
# validate-feature-docs.sh — documentation-coverage gate (temperloop#132).
#
# Three registries, one validator:
#   docs/features/feature-manifest.txt — full-coverage path-claims registry:
#     `<slug> <glob>` lines, every git-tracked path must be claimed by some
#     feature slug (or the reserved pseudo-slug `none` for repo meta). A
#     tracked path may match more than one glob; the LONGEST matching pattern
#     wins ("most specific wins" — same walk as
#     workflows/scripts/kernel/check-kernel-manifest.sh), so override entries
#     can narrow a broader glob with no ordering fragility. A claim whose glob
#     matches no tracked path is LEGAL AND INERT — that is what lets sibling
#     PRs pre-claim paths they will create later without a manifest edit here.
#   docs/features/<slug>.md — one feature doc per manifest slug, with the five
#     required sections (## Problem, ## How it works, ## Integration,
#     ## Resource impact, ## Telemetry) each present and NON-EMPTY — "None."
#     must be stated, never implied.
#   docs/features/backfill-exempt.txt — the shrink-only ratchet: slugs whose
#     doc has not been backfilled yet. An exempt slug is excused ONLY from the
#     doc-presence check; path claims are never exempted, so the
#     new-unclaimed-code guarantee is live from day one. When a slug's doc
#     lands, its exemption line MUST be deleted (exempt-but-documented fails);
#     an exemption for a slug the manifest no longer names is stale (fails).
#     A missing/empty exempt file is the fully-burned-down end state, not an
#     error.
#
# What fails CI (collect-all-failures, one run surfaces everything —
# message/summary style modeled on workflows/scripts/validate-live-drain.sh):
#   UNCLAIMED              tracked path no manifest glob claims
#   MISSING-DOC            non-exempt slug with no docs/features/<slug>.md
#   MISSING-SECTION        required section heading absent from a doc
#   EMPTY-SECTION          required section present but has no content
#   ORPHAN-DOC             docs/features/*.md whose stem is no manifest slug
#   SLUG-MISMATCH          frontmatter `slug:` != filename stem (or absent)
#   STALE-EXEMPT           exemption for a slug the manifest doesn't name
#   EXEMPT-BUT-DOCUMENTED  exemption line kept after the doc landed
#
# Usage:
#   workflows/scripts/validate-feature-docs.sh
#   (a direct-`bash` KERNEL_GATES entry in scripts/quality-gates.sh)
#
# Env overrides (used by the fixture test suite to point at a synthetic repo
# instead of the real tree — same seam shape as KERNEL_MANIFEST_ROOT/_FILE):
#   FEATURE_DOCS_ROOT      repo root to walk (default: this repo)
#   FEATURE_MANIFEST_FILE  path-claims registry (default:
#                          $FEATURE_DOCS_ROOT/docs/features/feature-manifest.txt)
#   FEATURE_EXEMPT_FILE    backfill ratchet (default:
#                          $FEATURE_DOCS_ROOT/docs/features/backfill-exempt.txt)
#   FEATURE_DOCS_DIR       feature-doc directory (default:
#                          $FEATURE_DOCS_ROOT/docs/features)
#
# Kept POSIX-bash-3.2 friendly (no mapfile/associative arrays) so it runs on
# the macOS dev shell as well as Linux CI.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${FEATURE_DOCS_ROOT:=$REPO_ROOT}"
: "${FEATURE_MANIFEST_FILE:=$FEATURE_DOCS_ROOT/docs/features/feature-manifest.txt}"
: "${FEATURE_EXEMPT_FILE:=$FEATURE_DOCS_ROOT/docs/features/backfill-exempt.txt}"
: "${FEATURE_DOCS_DIR:=$FEATURE_DOCS_ROOT/docs/features}"

REQUIRED_SECTIONS='## Problem
## How it works
## Integration
## Resource impact
## Telemetry'

if [[ ! -f "$FEATURE_MANIFEST_FILE" ]]; then
  echo "validate-feature-docs: manifest not found at $FEATURE_MANIFEST_FILE" >&2
  exit 1
fi
if [[ ! -d "$FEATURE_DOCS_ROOT/.git" && ! -f "$FEATURE_DOCS_ROOT/.git" ]]; then
  echo "validate-feature-docs: $FEATURE_DOCS_ROOT is not a git checkout" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse the manifest into parallel arrays (bash-3.2: no associative arrays).
# Same parse shape as workflows/scripts/kernel/lib.sh, with the class column
# generalized to a feature slug.
# ---------------------------------------------------------------------------
FD_SLUGS=()
FD_PATTERNS=()
lineno=0
while IFS= read -r raw || [[ -n "$raw" ]]; do
  lineno=$((lineno + 1))
  line="${raw%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && continue

  slug="${line%% *}"
  pat="${line#* }"
  if [[ "$slug" == "$line" ]]; then
    echo "validate-feature-docs: malformed manifest line $lineno (no glob after slug): $raw" >&2
    exit 1
  fi
  case "$slug" in
    none) ;;
    *[!a-z0-9-]* | -* | *-)
      echo "validate-feature-docs: bad slug '$slug' at manifest line $lineno (want [a-z0-9-], no leading/trailing '-'): $raw" >&2
      exit 1
      ;;
  esac
  FD_SLUGS+=("$slug")
  FD_PATTERNS+=("$pat")
done < "$FEATURE_MANIFEST_FILE"

if [[ ${#FD_SLUGS[@]} -eq 0 ]]; then
  echo "validate-feature-docs: manifest has zero entries — nothing to check" >&2
  exit 1
fi

# fd_classify <path> — echo the slug of the longest matching pattern, rc 1 if
# no pattern matches ("longest pattern wins", kernel_lib_classify's rule).
fd_classify() {
  local f="$1" i pat plen best_len=-1 best_slug=""
  for i in "${!FD_PATTERNS[@]}"; do
    pat="${FD_PATTERNS[$i]}"
    # shellcheck disable=SC2053  # intentional unquoted glob match
    if [[ "$f" == $pat ]]; then
      plen=${#pat}
      if (( plen > best_len )); then
        best_len=$plen
        best_slug="${FD_SLUGS[$i]}"
      fi
    fi
  done
  [[ -n "$best_slug" ]] || return 1
  printf '%s' "$best_slug"
}

# fd_in_list <needle> <newline-list> — rc 0 if <needle> is a line of the list.
fd_in_list() {
  local needle="$1" list="$2" x
  while IFS= read -r x; do
    [[ "$x" == "$needle" ]] && return 0
  done <<EOF
$list
EOF
  return 1
}

failures=()

# ---------------------------------------------------------------------------
# 1. Coverage walk: every git-tracked path must be claimed by some glob.
#    Never exempted — the new-unclaimed-code guarantee is live from day one.
# ---------------------------------------------------------------------------
cd "$FEATURE_DOCS_ROOT" || exit 1
total=0
claimed=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  total=$((total + 1))
  if fd_classify "$f" >/dev/null; then
    claimed=$((claimed + 1))
  else
    failures+=("UNCLAIMED  $f — no feature-manifest glob claims this tracked path (add a '<slug> <glob>' line, or 'none <glob>' for repo meta)")
  fi
done < <(git ls-files)

# The unique real (non-`none`) slug set, one per line.
slug_set="$(printf '%s\n' "${FD_SLUGS[@]}" | grep -v '^none$' | sort -u)"
nslugs="$(printf '%s\n' "$slug_set" | grep -c . || true)"

# ---------------------------------------------------------------------------
# 2. The ratchet: parse backfill-exempt.txt (missing file == empty == fully
#    burned down). Stale and exempt-but-documented lines fail — the list only
#    shrinks.
# ---------------------------------------------------------------------------
exempt_list=""
nexempt=0
if [[ -f "$FEATURE_EXEMPT_FILE" ]]; then
  lineno=0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    case "$line" in
      *[!a-z0-9-]* | -* | *-)
        echo "validate-feature-docs: bad exempt slug '$line' at $FEATURE_EXEMPT_FILE line $lineno" >&2
        exit 1
        ;;
    esac
    nexempt=$((nexempt + 1))
    exempt_list="${exempt_list}${line}
"
    if ! fd_in_list "$line" "$slug_set"; then
      failures+=("STALE-EXEMPT  $line — exempted but not a feature-manifest slug (delete the line, or restore the manifest entry)")
    fi
    if [[ -f "$FEATURE_DOCS_DIR/$line.md" ]]; then
      failures+=("EXEMPT-BUT-DOCUMENTED  $line — docs/features/$line.md exists; delete its backfill-exempt.txt line (the ratchet only shrinks)")
    fi
  done < "$FEATURE_EXEMPT_FILE"
fi

# ---------------------------------------------------------------------------
# 3. Doc presence: every non-exempt slug needs docs/features/<slug>.md.
# ---------------------------------------------------------------------------
while IFS= read -r s; do
  [[ -z "$s" ]] && continue
  if [[ ! -f "$FEATURE_DOCS_DIR/$s.md" ]]; then
    if ! fd_in_list "$s" "$exempt_list"; then
      failures+=("MISSING-DOC  $s — no $FEATURE_DOCS_DIR/$s.md and '$s' is not in backfill-exempt.txt")
    fi
  fi
done <<EOF
$slug_set
EOF

# ---------------------------------------------------------------------------
# 4. Per-doc checks: orphan stem, frontmatter slug, required sections.
# ---------------------------------------------------------------------------
ndocs=0
for doc in "$FEATURE_DOCS_DIR"/*.md; do
  [[ -e "$doc" ]] || continue   # unmatched glob (no docs yet)
  ndocs=$((ndocs + 1))
  base="$(basename "$doc")"
  stem="${base%.md}"

  if ! fd_in_list "$stem" "$slug_set"; then
    failures+=("ORPHAN-DOC  $base — filename stem '$stem' is not a feature-manifest slug")
  fi

  # Frontmatter `slug:` (single-line, markdown_lite constraint) must equal the
  # filename stem.
  fm_slug="$(awk '
    NR == 1 && $0 != "---" { exit }
    $0 == "---" { fence++; next }
    fence == 1 && /^slug:/ { sub(/^slug:[[:space:]]*/, ""); print; exit }
    fence >= 2 { exit }
  ' "$doc")"
  if [[ -z "$fm_slug" ]]; then
    failures+=("SLUG-MISMATCH  $base — no single-line 'slug:' in frontmatter (want: slug: $stem)")
  elif [[ "$fm_slug" != "$stem" ]]; then
    failures+=("SLUG-MISMATCH  $base — frontmatter 'slug: $fm_slug' != filename stem '$stem'")
  fi

  # Required sections: present, and non-empty ("None." must be stated, never
  # implied — any non-blank line before the next heading counts).
  while IFS= read -r sec; do
    [[ -z "$sec" ]] && continue
    state="$(awk -v sec="$sec" '
      { sub(/[[:space:]]+$/, "") }
      $0 == sec { insec = 1; found = 1; next }
      insec && /^#/ { insec = 0 }
      insec && NF > 0 { content = 1 }
      END {
        if (!found) print "missing"
        else if (!content) print "empty"
        else print "ok"
      }
    ' "$doc")"
    case "$state" in
      missing) failures+=("MISSING-SECTION  $base — required section '$sec' absent") ;;
      empty) failures+=("EMPTY-SECTION  $base — required section '$sec' has no content (state \"None.\" explicitly, never imply it)") ;;
    esac
  done <<EOF
$REQUIRED_SECTIONS
EOF
done

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
echo "Checked $total tracked path(s) ($claimed claimed), $nslugs feature slug(s), $ndocs doc(s), $nexempt exemption(s)"
if (( ${#failures[@]} > 0 )); then
  printf '%s\n' "${failures[@]}"
  echo "---"
  echo "failures: ${#failures[@]}"
  echo "validate-feature-docs: FAIL"
  exit 1
fi
echo "validate-feature-docs: OK"
