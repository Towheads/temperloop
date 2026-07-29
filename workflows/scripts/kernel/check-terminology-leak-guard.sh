#!/usr/bin/env bash
#
# check-terminology-leak-guard.sh — v0.17.0 terminology-rename identifier
# leak gate (temperloop#729, ADR 0017; sibling of
# check-prerename-leak-guard.sh, which owns the foundation->temperloop
# rename's identifier shapes).
#
# The one-shot terminology consolidation renamed every coined identifier
# surface (FUNNEL_*->PIPELINE_*, KNOB_*->SETTING_*, the funnel-*/knob-*
# script family, the pre-rename capture/backstop validator path, the
# batch-at-*/blocking-now severity tokens, the pre-rename pairing tokens,
# build-spine.md / funnel-driver.md). THIS gate keeps the pre-rename
# identifiers a closed, reviewed set: it scans every git-tracked file for the
# old identifier SHAPES (the `SHAPES` alternation below is the ONE place they
# are still written out) and fails on any occurrence outside:
#
#   a) the ALLOWED persisted-state literals — external state the rename
#      deliberately kept stable (the K165 `.foundation/` precedent):
#      the `funnel-merge-pending` / `funnel-escalated` GitHub labels, the
#      `funnel:clarification-drained` / `funnel:decision-applied` issue
#      markers, the `~/.claude/funnel` state paths, and the
#      `/tmp/funnel-tick` lock dir. These literals are stripped from a line
#      before the shape scan, so the VALUES stay legal while a new
#      FUNNEL_*-named identifier on the same line still trips the gate.
#
#   b) the WHOLESALE-EXEMPT files (terminology-leak-exempt-files.txt,
#      sibling) — the records that legitimately keep old terms
#      (CHANGELOG.md, docs/adr/, Plans-archive/, meta/) and this gate's own
#      family. The compat window's own surfaces used to be exempt here too;
#      the window CLOSED in v0.19.0 (temperloop#767) and that whole class was
#      deleted, so the exempt set is now records + self alone.
#
# A brand-new FUNNEL_/KNOB_ env var, a reference to a renamed script's old
# path, or a coined severity/pairing token therefore can't silently
# re-enter a stranger surface: it is either added to the exempt list (a
# reviewed decision) or trips this gate red.
#
# Portable bash 3.2 + POSIX grep -E; zero network. Scan root overridable
# for fixture tests via TERMINOLOGY_LEAK_SCAN_ROOT.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../../.." && pwd)"
SCAN_ROOT="${TERMINOLOGY_LEAK_SCAN_ROOT:-$REPO_ROOT}"   # setting:exempt — fixture seam
EXEMPT_FILE="${TERMINOLOGY_LEAK_EXEMPT_FILE:-$HERE/terminology-leak-exempt-files.txt}"   # setting:exempt — fixture seam

# Pre-rename identifier shapes (ERE). Kept as ONE alternation so a single
# grep pass covers the whole map.
SHAPES='FUNNEL_[A-Z0-9_]+|KNOB_[A-Z0-9_]+|funnel-(cron|drive|tick|overlap|schedule-gate|driver|drive-merge)\.(sh|md)|funnel-drive(-merge)?\.settings\.json|build-config-knobs\.sh|knob-registry(-lib\.sh|-exempt-files\.txt|\.tsv)|knob-prose-baseline\.tsv|check-knob-(registry|prose)\.sh|validate-live-drain\.sh|live-drain-registry\.overlay\.md|build-spine\.md|batch-at-ritual|batch-at-gate|blocking-now|[Ll]ive[-/][Dd]rain'

# Allowed persisted-state literals, stripped from each line before the scan.
strip_allowed() {
  sed -e 's/funnel-merge-pending//g' \
      -e 's/funnel-escalated//g' \
      -e 's/funnel:clarification-drained//g' \
      -e 's/funnel:decision-applied//g' \
      -e 's|\.claude/funnel||g' \
      -e 's|/tmp/funnel-tick||g'
}

is_exempt() {
  # $1 = repo-relative path; exempt list carries exact paths or dir/ prefixes.
  local p="$1" line
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    case "$p" in
      "$line") return 0 ;;
      "${line%/}"/*) [ "${line%/}" != "$line" ] && return 0 ;;
    esac
  done < "$EXEMPT_FILE"
  return 1
}

fail=0
scanned=0
while IFS= read -r f; do
  [ -f "$SCAN_ROOT/$f" ] || continue
  is_exempt "$f" && continue
  scanned=$((scanned + 1))
  hits="$(strip_allowed < "$SCAN_ROOT/$f" | grep -nE "$SHAPES" | head -5 || true)"
  if [ -n "$hits" ]; then
    fail=1
    echo "FAIL: pre-rename identifier in $f (renamed in v0.17.0, temperloop#729 — use the new name, or add a reviewed exempt line):"
    printf '%s\n' "$hits" | sed 's/^/    /'
  fi
done < <(git -C "$SCAN_ROOT" ls-files)

# Fail LOUD on an empty scan: a failed/misdirected `git ls-files` (not a git
# repo, bad SCAN_ROOT) would otherwise false-green this gate as "0 scanned".
if [ "$scanned" -eq 0 ]; then
  echo "check-terminology-leak-guard: FAIL — scanned 0 file(s) (git ls-files failed, or SCAN_ROOT '$SCAN_ROOT' is not a git checkout)"
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "check-terminology-leak-guard: FAIL"
  exit 1
fi
echo "OK — no pre-rename terminology identifiers outside the reviewed exempt set ($scanned file(s) scanned)"
