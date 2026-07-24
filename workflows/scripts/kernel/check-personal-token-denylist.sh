#!/usr/bin/env bash
#
# check-personal-token-denylist.sh — scan the kernel file set (per
# list-kernel-set.sh) for personal/org tokens that must never ship in the
# public kernel repo (foundation #798, epic #762 kernel extraction).
#
# Patterns live in the single source of truth personal-token-denylist.tsv
# (sibling file) — add a token class there, not here.
#
# EXEMPTIONS: a matched line carrying a trailing `# denylist:allow — <reason>`
# comment is skipped. Used today for two documented, load-bearing cases where
# the personal-looking literal is an intentional runtime default, not an
# oversight:
#   1. workflows/scripts/board/lib/board.sh's (and funnel-tick.sh's /
#      funnel-drive.sh's) `boards.conf`-fallback case maps — kernel-manifest
#      #770 already documents these built-in values as required
#      byte-for-byte so a `boards.conf`-less CONSUMING checkout (board.sh is
#      synced, as real files, into other repos) keeps behaving exactly as it
#      did pre-#770. Changing the built-in default would be a cross-repo
#      behavior break this worktree can neither make nor verify. The REAL
#      value for THIS machine is supplied by an untracked, gitignored
#      workflows/scripts/board/boards.conf instead (discovery order #2), so
#      the built-in fallback is truly only reached by a boards.conf-less
#      checkout.
#   2. The fixture-replay tests exercising those same fallback maps
#      (workflows/scripts/board/tests/*, workflows/scripts/build/tests/*) —
#      scrubbing the literal test data would not remove anything the
#      already-exempted runtime default doesn't already disclose, so the
#      cost (large, error-prone rewrite) buys no privacy benefit. These are
#      exempted WHOLESALE, by path, in the sibling
#      personal-token-denylist-exempt-files.txt (a JSON/heredoc fixture line
#      often can't carry a trailing shell comment without corrupting the
#      payload, so the per-line marker doesn't apply there) — see that
#      file's header for the exact list + rationale.
#
# BURN-DOWN BASELINE (temperloop#164/#169): a DIFFERENT mechanism from the two
# exemptions above, for a newly-widened denylist family that already has
# pre-existing hits in the tree — a debt ledger, not a permanent exception.
# personal-token-denylist-baseline.tsv (sibling file) lists (file, pattern,
# exact line content) triples; a hit matching a baseline row is suppressed
# (once per row — a duplicated line is only forgiven as many times as it's
# listed) but does NOT need a `# denylist:allow` marker, since it isn't
# intentional/permanent — it's tracked debt a later item burns down by fixing
# the line and deleting its baseline row. See that file's own header.
#
# Usage:
#   check-personal-token-denylist.sh [--root DIR]
#   (called by `make test-kernel-denylist`)
#
# Env overrides (fixture-driven tests):
#   KERNEL_MANIFEST_ROOT, KERNEL_MANIFEST_FILE, KERNEL_DENYLIST_FILE,
#   KERNEL_DENYLIST_EXEMPT_FILE, KERNEL_DENYLIST_BASELINE_FILE

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

: "${KERNEL_MANIFEST_ROOT:=$REPO_ROOT}"
: "${KERNEL_DENYLIST_FILE:=$SCRIPT_DIR/personal-token-denylist.tsv}"
: "${KERNEL_DENYLIST_EXEMPT_FILE:=$SCRIPT_DIR/personal-token-denylist-exempt-files.txt}"
: "${KERNEL_DENYLIST_BASELINE_FILE:=$SCRIPT_DIR/personal-token-denylist-baseline.tsv}"

if [[ ! -f "$KERNEL_DENYLIST_FILE" ]]; then
  echo "check-personal-token-denylist: denylist not found at $KERNEL_DENYLIST_FILE" >&2
  exit 1
fi

exempt_files=()
if [[ -f "$KERNEL_DENYLIST_EXEMPT_FILE" ]]; then
  while IFS= read -r ex || [[ -n "$ex" ]]; do
    ex="${ex%%#*}"
    ex="${ex#"${ex%%[![:space:]]*}"}"
    ex="${ex%"${ex##*[![:space:]]}"}"
    [[ -z "$ex" ]] && continue
    exempt_files+=("$ex")
  done < "$KERNEL_DENYLIST_EXEMPT_FILE"
fi

_kernel_denylist_is_exempt() {
  local target="$1" ex
  for ex in "${exempt_files[@]+"${exempt_files[@]}"}"; do
    [[ "$target" == "$ex" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Load the burn-down baseline (file, pattern, line) triples. Bash-3.2-
# compatible plain indexed arrays (no `declare -A` — kernel scripts must run
# unmodified on macOS's system bash 3.2), same linear-
# scan idiom as _kernel_denylist_is_exempt above. Blank lines and
# #-prefixed comment lines are skipped, same convention as the other two
# data files. A parallel `baseline_used` flag array tracks per-row
# consumption so each row forgives exactly one occurrence — a duplicated
# line is only baselined as many times as it's listed.
# ---------------------------------------------------------------------------
baseline_files=()
baseline_pats=()
baseline_lines=()
baseline_used=()
if [[ -f "$KERNEL_DENYLIST_BASELINE_FILE" ]]; then
  while IFS=$'\t' read -r bfile bpat bline || [[ -n "${bfile:-}" ]]; do
    [[ -z "${bfile:-}" ]] && continue
    case "$bfile" in \#*) continue ;; esac
    [[ -z "${bpat:-}" ]] && continue
    baseline_files+=("$bfile")
    baseline_pats+=("$bpat")
    baseline_lines+=("$bline")
    baseline_used+=(0)
  done < "$KERNEL_DENYLIST_BASELINE_FILE"
fi

_kernel_denylist_take_baseline() {
  # Consumes the first not-yet-used baseline row matching (file, pattern,
  # line), if any. Returns 0 (consumed) or 1 (no baseline credit — a
  # real/new violation).
  local target_f="$1" target_pat="$2" target_line="$3" j
  for j in "${!baseline_files[@]}"; do
    [[ "${baseline_used[$j]}" == 0 ]] || continue
    [[ "${baseline_files[$j]}" == "$target_f" ]] || continue
    [[ "${baseline_pats[$j]}" == "$target_pat" ]] || continue
    [[ "${baseline_lines[$j]}" == "$target_line" ]] || continue
    baseline_used[j]=1
    return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Load denylist entries (pattern TAB description). Blank lines and
# #-prefixed comment lines are skipped.
# ---------------------------------------------------------------------------
patterns=()
descriptions=()
while IFS=$'\t' read -r pat desc; do
  [[ -z "${pat:-}" ]] && continue
  case "$pat" in \#*) continue ;; esac
  patterns+=("$pat")
  descriptions+=("$desc")
done < "$KERNEL_DENYLIST_FILE"

# ---------------------------------------------------------------------------
# Overlay: the operator-personal rows (name, personal emails, machine names,
# Sentry slug, vault path, private org/handle) do NOT ship in the tracked,
# public denylist (temperloop#438) — they live in a sibling, gitignored
# personal-token-denylist.local.tsv. UNION it in when present; DEGRADE LEGIBLY
# (a one-line NOTE, never a silent skip) when absent, so a stranger's
# kernel-only clone still runs — enforcing the tracked structural/example rows
# only — and the coverage gap is visible rather than silent. Path defaults to
# the sibling of KERNEL_DENYLIST_FILE (overridable via KERNEL_DENYLIST_LOCAL_FILE,
# a test seam).
# ---------------------------------------------------------------------------
: "${KERNEL_DENYLIST_LOCAL_FILE:=${KERNEL_DENYLIST_FILE%.tsv}.local.tsv}"
if [[ -f "$KERNEL_DENYLIST_LOCAL_FILE" ]]; then
  _local_rows=0
  while IFS=$'\t' read -r pat desc; do
    [[ -z "${pat:-}" ]] && continue
    case "$pat" in \#*) continue ;; esac
    patterns+=("$pat")
    descriptions+=("$desc")
    _local_rows=$((_local_rows + 1))
  done < "$KERNEL_DENYLIST_LOCAL_FILE"
  echo "check-personal-token-denylist: loaded $_local_rows operator-personal overlay row(s) from ${KERNEL_DENYLIST_LOCAL_FILE##*/}" >&2
else
  echo "check-personal-token-denylist: NOTE — no personal-token-denylist.local.tsv overlay present; enforcing the tracked structural/example rows only (operator-personal tokens are enforced only where the gitignored overlay exists)." >&2
fi

if [[ ${#patterns[@]} -eq 0 ]]; then
  echo "check-personal-token-denylist: denylist has zero entries — nothing to check" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Scan every kernel-set file against every pattern. One `grep -nE` per
# pattern per file (not per line) — the file set is small (~140 files) but
# some files are long, and a per-line subprocess loop is prohibitively slow.
# ---------------------------------------------------------------------------
violations=0
baselined=0
files_checked=0

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if _kernel_denylist_is_exempt "$f"; then
    continue
  fi
  files_checked=$((files_checked + 1))
  path="$KERNEL_MANIFEST_ROOT/$f"
  [[ -f "$path" ]] || continue

  for i in "${!patterns[@]}"; do
    pat="${patterns[$i]}"
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      lineno="${hit%%:*}"
      line="${hit#*:}"
      case "$line" in
        *denylist:allow*) continue ;;
      esac
      if _kernel_denylist_take_baseline "$f" "$pat" "$line"; then
        baselined=$((baselined + 1))
        continue
      fi
      printf '%s:%s: [%s] %s\n    %s\n' \
        "$f" "$lineno" "$pat" "${descriptions[$i]}" "$line"
      violations=$((violations + 1))
    done < <(grep -nE -- "$pat" "$path" 2>/dev/null || true)
  done
done < <("$SCRIPT_DIR/list-kernel-set.sh" --root "$KERNEL_MANIFEST_ROOT")

if (( violations > 0 )); then
  echo "---"
  echo "FAIL: $violations personal-token denylist violation(s) across $files_checked kernel file(s) ($baselined pre-existing hit(s) suppressed via burn-down baseline)" >&2
  exit 1
fi

echo "OK — 0 new personal-token denylist violations across $files_checked kernel file(s) ($baselined pre-existing hit(s) suppressed via burn-down baseline; see personal-token-denylist-baseline.tsv)"
