#!/usr/bin/env bash
#
# check-contributor-manifest.sh — structural + completeness lint for
# workflows/scripts/config/contributor-manifest.tsv (temperloop#827, epic
# #810 P1).
#
# contributor-manifest.tsv is the single source of truth for WHICH tracked
# files (or file frontmatter fields) count-prose.sh's "SESSION-START
# CONTRIBUTORS" report measures. This lint keeps the tsv honest against the
# real tree:
#
#   1. Structural: every row has exactly 4 tab-separated fields; no path is
#      claimed by two rows; `unit` is one of the closed set (`full`,
#      `frontmatter:description`); `load` is one of the closed set
#      (`harness-auto`, `pointer-turn1`, `none`, `n/a` — temperloop#826's
#      coverage spike: AGENTS.md is turn-1, not harness-auto, so this axis
#      keeps a future turn-1 row from being silently summed into the same
#      bucket as an unconditional one).
#   2. Tracked-path: every row's path is a real `git ls-files` entry in the
#      repo. This is what structurally keeps a HOST-STATE contributor (e.g.
#      the machine-global ~/.claude/agents surface) out of the manifest — a
#      path outside this repo's own tracked tree can never satisfy it.
#   3. Field-presence: a `frontmatter:description` row's file actually
#      carries a `description:` line inside its YAML frontmatter block.
#   4. Completeness: every tracked claude/commands/*.md file, and every
#      tracked claude/agents/**/*.md file (recursive, including
#      claude/agents/reviewers/*), has a row — so a new command/agent file
#      added later without a manifest row fails this gate instead of
#      silently going unmeasured. The root CLAUDE.md pointer must also have
#      exactly one `full` row.
#
# Usage:
#   check-contributor-manifest.sh
#
# Env overrides (fixture-driven tests):
#   CONTRIBUTOR_MANIFEST_TSV    path to the tsv (default: sibling
#                               contributor-manifest.tsv)
#   CONTRIBUTOR_MANIFEST_REPO_ROOT   repo root the tsv's paths resolve
#                               against, and the `git ls-files` root
#                               (default: this repo's own root)
#
# Kept bash-3.2-portable (no associative arrays, no mapfile) — same
# discipline as every other workflows/scripts/config/*.sh checker
# (check-setting-registry.sh, check-reviewer-routing.sh).

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

: "${CONTRIBUTOR_MANIFEST_TSV:=$SCRIPT_DIR/contributor-manifest.tsv}"
: "${CONTRIBUTOR_MANIFEST_REPO_ROOT:=$REPO_ROOT_DEFAULT}"

if [ ! -f "$CONTRIBUTOR_MANIFEST_TSV" ]; then
  echo "check-contributor-manifest: tsv not found at $CONTRIBUTOR_MANIFEST_TSV" >&2
  exit 1
fi
if [ ! -d "$CONTRIBUTOR_MANIFEST_REPO_ROOT/.git" ] && [ ! -f "$CONTRIBUTOR_MANIFEST_REPO_ROOT/.git" ]; then
  echo "check-contributor-manifest: $CONTRIBUTOR_MANIFEST_REPO_ROOT is not a git checkout" >&2
  exit 1
fi

violations=0

# --- load tsv rows: path, unit, label, load — comments/blank lines out ----
paths=()
units=()
labels=()
loads=()
while IFS=$'\t' read -r c_path c_unit c_label c_load || [ -n "${c_path:-}" ]; do
  [ -z "${c_path:-}" ] && continue
  case "$c_path" in \#*) continue ;; esac
  if [ -z "${c_unit:-}" ] || [ -z "${c_label:-}" ] || [ -z "${c_load:-}" ]; then
    echo "check-contributor-manifest: malformed row (need 4 tab-separated fields): $c_path" >&2
    exit 1
  fi
  paths+=("$c_path")
  units+=("$c_unit")
  labels+=("$c_label")
  loads+=("$c_load")
done <"$CONTRIBUTOR_MANIFEST_TSV"

if [ "${#paths[@]}" -eq 0 ]; then
  echo "check-contributor-manifest: zero contributor rows parsed from $CONTRIBUTOR_MANIFEST_TSV" >&2
  exit 1
fi

# --- 1a. structural: no path claimed by two rows --------------------------
for i in "${!paths[@]}"; do
  for j in "${!paths[@]}"; do
    [ "$j" -le "$i" ] && continue
    if [ "${paths[$i]}" = "${paths[$j]}" ]; then
      printf 'DUPLICATE: %s is claimed by two rows\n' "${paths[$i]}"
      violations=$((violations + 1))
    fi
  done
done

# --- 1b. structural: unit is one of the closed set ------------------------
for i in "${!paths[@]}"; do
  case "${units[$i]}" in
    full | frontmatter:description) ;;
    *)
      printf 'UNKNOWN UNIT: %s has unrecognized unit "%s" (must be "full" or "frontmatter:description")\n' \
        "${paths[$i]}" "${units[$i]}"
      violations=$((violations + 1))
      ;;
  esac
done

# --- 1c. structural: load is one of the closed set (temperloop#826) -------
for i in "${!paths[@]}"; do
  case "${loads[$i]}" in
    harness-auto | pointer-turn1 | none | n/a) ;;
    *)
      printf 'UNKNOWN LOAD CLASS: %s has unrecognized load "%s" (must be one of harness-auto, pointer-turn1, none, n/a)\n' \
        "${paths[$i]}" "${loads[$i]}"
      violations=$((violations + 1))
      ;;
  esac
done

# --- 2. tracked-path: every row's path is a real git ls-files entry -------
tracked_raw="$(git -C "$CONTRIBUTOR_MANIFEST_REPO_ROOT" ls-files)"
_cm_is_tracked() {
  # $1 = path to test
  case $'\n'"$tracked_raw"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}
for i in "${!paths[@]}"; do
  if ! _cm_is_tracked "${paths[$i]}"; then
    printf 'NOT TRACKED: %s is not a git-tracked path under %s\n' "${paths[$i]}" "$CONTRIBUTOR_MANIFEST_REPO_ROOT"
    violations=$((violations + 1))
  fi
done

# --- 3. field-presence: a frontmatter:description row's file has the field
_cm_has_description() {
  # $1 = absolute file path -> exit 0 iff a `description:` line exists
  # inside the file's YAML frontmatter block (between the first two `---`
  # lines). Same extraction shape as count-prose.sh's own
  # frontmatter_description() — kept independent (never sourced from one
  # another) since a lint and the thing it reconciles against must not
  # share a single point of failure.
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && /^description:/ { found=1; exit }
    END { exit !found }
  ' "$1"
}
for i in "${!paths[@]}"; do
  [ "${units[$i]}" = "frontmatter:description" ] || continue
  fpath="$CONTRIBUTOR_MANIFEST_REPO_ROOT/${paths[$i]}"
  if [ ! -f "$fpath" ]; then
    printf 'MISSING FILE: %s (row unit frontmatter:description) does not exist under %s\n' \
      "${paths[$i]}" "$CONTRIBUTOR_MANIFEST_REPO_ROOT"
    violations=$((violations + 1))
    continue
  fi
  if ! _cm_has_description "$fpath"; then
    printf 'NO DESCRIPTION FIELD: %s (row unit frontmatter:description) has no description: line in its frontmatter\n' \
      "${paths[$i]}"
    violations=$((violations + 1))
  fi
done

# --- 4. completeness: every claude/commands/*.md + claude/agents/**/*.md.md
#        file has a row; CLAUDE.md has exactly one `full` row -------------
_cm_has_row() {
  # $1 = path to test against the parsed manifest rows
  for p in "${paths[@]}"; do
    [ "$p" = "$1" ] && return 0
  done
  return 1
}

if ! commands_raw="$(git -C "$CONTRIBUTOR_MANIFEST_REPO_ROOT" ls-files -- claude/commands | { grep '\.md$' || true; })"; then
  echo "check-contributor-manifest: failed to enumerate claude/commands/*.md" >&2
  exit 1
fi
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if ! _cm_has_row "$f"; then
    printf 'MISSING ROW: %s is a tracked command file with no contributor-manifest row\n' "$f"
    violations=$((violations + 1))
  fi
done <<<"$commands_raw"

if ! agents_raw="$(git -C "$CONTRIBUTOR_MANIFEST_REPO_ROOT" ls-files -- claude/agents | { grep '\.md$' || true; })"; then
  echo "check-contributor-manifest: failed to enumerate claude/agents/**/*.md" >&2
  exit 1
fi
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if ! _cm_has_row "$f"; then
    printf 'MISSING ROW: %s is a tracked agent file with no contributor-manifest row\n' "$f"
    violations=$((violations + 1))
  fi
done <<<"$agents_raw"

claude_md_rows=0
for i in "${!paths[@]}"; do
  if [ "${paths[$i]}" = "CLAUDE.md" ]; then
    claude_md_rows=$((claude_md_rows + 1))
    if [ "${units[$i]}" != "full" ]; then
      printf 'WRONG UNIT: CLAUDE.md row must use unit "full", found "%s"\n' "${units[$i]}"
      violations=$((violations + 1))
    fi
  fi
done
if [ "$claude_md_rows" -eq 0 ]; then
  echo "MISSING ROW: the root CLAUDE.md pointer has no contributor-manifest row"
  violations=$((violations + 1))
elif [ "$claude_md_rows" -gt 1 ]; then
  echo "DUPLICATE: CLAUDE.md is claimed by more than one row"
  violations=$((violations + 1))
fi

echo
if [ "$violations" -gt 0 ]; then
  echo "FAIL: $violations contributor-manifest violation(s)" >&2
  exit 1
fi
echo "OK — contributor-manifest.tsv (${#paths[@]} row(s)): no duplicates, every path tracked, every frontmatter:description field present, every claude/commands + claude/agents file and CLAUDE.md claimed"
