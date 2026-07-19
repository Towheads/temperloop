#!/usr/bin/env bash
#
# reviewer-activation-coverage.sh — reviewer activation-coverage scan
# (temperloop#548, ADR 0007/0008).
#
# WHAT THIS IS. A PURE, NON-INTERACTIVE DATA PATH over the language-reviewer
# catalog (ADR 0007: seven reviewer rubrics ship inert under
# claude/agents/reviewers/, activated opt-in per repo). This script NEVER
# prompts and has NO side effects — it only reads the target repo's files
# and the tracked reviewer-routing.tsv catalog, and reports.
#
# It has two future consumers, which is why it is kept SOURCEABLE as well as
# directly executable:
#   - temperloop#549 — an INTERACTIVE opt-in caller that offers to activate
#     each gap (deploys claude/agents/reviewers/<name>.md into a live
#     .claude/agents/<name>.md, and owns the decline-marker FORMAT this
#     script only reads).
#   - temperloop#550 — a PASSIVE `make doctor` check that sources this file
#     and calls reviewer_coverage_gaps() directly to report drift, with no
#     prompting of its own.
#
# WHAT IT COMPUTES. The gap set = catalogued reviewers (from
# workflows/scripts/config/reviewer-routing.tsv) whose language is:
#   (a) present in the scanned repo at/above the REVIEWER_SCAN_MIN_FILES
#       threshold (typescript-reviewer aggregates .ts + .js file counts
#       under ONE threshold, since both extensions route to it in the tsv);
#   (b) NOT already covered — no <project>/.claude/agents/<name>.md present
#       (a same-name catalog activation OR a user-defined reviewer both
#       count as "covered": this script only checks for the file's
#       presence, never its provenance); and
#   (c) NOT durably declined — no decline marker under
#       <project>/.claude/reviewer-state/declined/ (gitignored install
#       state; #549 owns the marker format, this script only reads it,
#       tolerating either shape: a per-name marker FILE
#       ".claude/reviewer-state/declined/<name>", or a flat LIST file
#       ".claude/reviewer-state/declined" with one name per line). Absent
#       state dir = nothing declined.
#
# The language -> extension/glob mapping is READ FROM reviewer-routing.tsv
# (the single source of truth for that axis, ADR 0008) — never hardcoded
# here as a parallel list.
#
# Usage:
#   reviewer-activation-coverage.sh [--project-dir DIR] [--list-only]
#   reviewer-activation-coverage.sh --check-integrity
#   reviewer-activation-coverage.sh -h|--help
#
#   --project-dir DIR    Repo to scan for language usage (default: DIR's
#                         git root if run inside one, else the cwd).
#   --list-only           Print the gap set, one reviewer-name per line, to
#                         stdout and exit 0. No prompting, no side effects —
#                         this is the mode #550's doctor check calls.
#   --check-integrity      Verify every catalog-agent-path column in
#                         reviewer-routing.tsv resolves to a real file on
#                         disk (relative to this kernel checkout's root).
#                         Exits non-zero if any entry is dangling. Guards the
#                         tsv<->catalog seam independent of any repo scan.
#   (no mode flag)        Human-readable report: threshold, then the gap set
#                         (or "no activation gaps found"). Still read-only.
#
# Sourceable interface (for #549/#550 — no CLI parsing runs at source time):
#   reviewer_coverage_gaps <project-dir> [<tsv-path>]
#       Prints the gap set, one reviewer-name per line, to stdout.
#   reviewer_coverage_check_integrity [<tsv-path>] [<kernel-root>]
#       Returns 0 iff every catalog-agent-path resolves; prints DANGLING
#       lines to stderr for each violation otherwise.
#
# Env overrides (fixture-driven tests, matching check-reviewer-routing.sh's
# own REVIEWER_ROUTING_TSV convention):
#   REVIEWER_ROUTING_TSV     path to the tsv (default: sibling
#                            workflows/scripts/config/reviewer-routing.tsv)
#   REVIEWER_SCAN_MIN_FILES  the activation-offer floor (sourced from
#                            workflows/scripts/build/build.config.sh when
#                            present; falls back to 3 — see that file's own
#                            knob comment, temperloop#538).
#
# Excluded from every file-count scan: .git, node_modules, .venv, venv,
# vendor, dist, build, target, .claude, __pycache__, .tox, .next — vendored/
# generated/build-output directories that would otherwise false-positive a
# language's material-usage count.
#
# shellcheck shell=bash

# `-u` and `pipefail` are safe to hand to a sourcing caller (this file's own
# sourceable-interface contract) and match this repo's other sourced-library
# convention (workflows/scripts/config/check-reviewer-routing.sh,
# workflows/scripts/install/doctor.sh both use exactly this). `-e` is added
# ONLY when this file is the top-level script being executed, below — `set
# -e` at source time would silently change a sourcing caller's own shell
# options, which workflows/scripts/lib/knowledge_store.sh and
# workflows/scripts/board/lib/board.sh both deliberately avoid.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

: "${REVIEWER_ROUTING_TSV:=${KERNEL_ROOT}/workflows/scripts/config/reviewer-routing.tsv}"

# Pull REVIEWER_SCAN_MIN_FILES from the tracked knob default when this kernel
# checkout carries build.config.sh (rungs 3-5 of the precedence ladder); a
# pre-set env value always wins (rung 2), and a non-vendoring caller that
# lacks build.config.sh entirely still gets the kernel built-in fallback
# (rung 6) via the `:=` below.
if [ -f "${KERNEL_ROOT}/workflows/scripts/build/build.config.sh" ]; then
  # shellcheck source=/dev/null
  source "${KERNEL_ROOT}/workflows/scripts/build/build.config.sh"
fi
: "${REVIEWER_SCAN_MIN_FILES:=3}"

# ---------------------------------------------------------------------------
# _rac_count_extension <project-dir> <ext>  — count files ending in <ext>
# (e.g. ".py") under <project-dir>, pruning vendored/build-output dirs.
# ---------------------------------------------------------------------------
_rac_count_extension() {
  local project_dir="$1" ext="$2"
  find "$project_dir" \
    \( -name .git -o -name node_modules -o -name .venv -o -name venv \
       -o -name vendor -o -name dist -o -name build -o -name target \
       -o -name .claude -o -name __pycache__ -o -name .tox -o -name .next \) \
    -prune -o -type f -name "*${ext}" -print 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# _rac_count_pathglob <project-dir> <glob>  — count files under a tsv
# path-glob key (e.g. "docs/**" -> the docs/ directory tree), pruning the
# same vendored/build-output dirs. A glob whose target directory doesn't
# exist in the scanned repo counts as 0, not an error.
# ---------------------------------------------------------------------------
_rac_count_pathglob() {
  local project_dir="$1" glob="$2" dir target
  case "$glob" in
    */\*\*) dir="${glob%/\*\*}" ;;
    *) dir="$glob" ;;
  esac
  target="${project_dir}/${dir}"
  if [ ! -d "$target" ]; then
    printf '0\n'
    return 0
  fi
  find "$target" \
    \( -name .git -o -name node_modules -o -name .venv -o -name venv \
       -o -name vendor -o -name dist -o -name build -o -name target \
       -o -name .claude -o -name __pycache__ -o -name .tox -o -name .next \) \
    -prune -o -type f -print 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# _rac_is_covered <project-dir> <reviewer-name>  — true iff a reviewer of
# this name is already deployed (catalog-activated or user-defined; this
# check only cares that the file exists, never its provenance).
# ---------------------------------------------------------------------------
_rac_is_covered() {
  local project_dir="$1" name="$2"
  [ -e "${project_dir}/.claude/agents/${name}.md" ]
}

# ---------------------------------------------------------------------------
# _rac_is_declined <project-dir> <reviewer-name>  — true iff durably
# declined. Tolerates either of two marker shapes (format owned by #549):
#   - a per-name marker FILE: .claude/reviewer-state/declined/<name>
#   - a flat LIST file:       .claude/reviewer-state/declined  (one name/line)
# Absent state dir/file = nothing declined.
# ---------------------------------------------------------------------------
_rac_is_declined() {
  local project_dir="$1" name="$2"
  local marker_dir="${project_dir}/.claude/reviewer-state/declined"

  if [ -d "$marker_dir" ] && [ -e "${marker_dir}/${name}" ]; then
    return 0
  fi
  if [ -f "$marker_dir" ] && grep -qxF "$name" "$marker_dir" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# reviewer_coverage_gaps <project-dir> [<tsv-path>]
#
# The sourceable data-path entry point. Prints the gap set, one
# reviewer-name per line, in reviewer-routing.tsv's first-appearance order.
# No prompting, no side effects (read-only over <project-dir> and <tsv-path>).
# ---------------------------------------------------------------------------
reviewer_coverage_gaps() {
  local project_dir="$1"
  local tsv="${2:-$REVIEWER_ROUTING_TSV}"
  local min_files="${REVIEWER_SCAN_MIN_FILES:-3}"

  if [ ! -f "$tsv" ]; then
    echo "reviewer_coverage_gaps: tsv not found at $tsv" >&2
    return 1
  fi

  local keys=() reviewers=()
  local key reviewer agent_path
  while IFS=$'\t' read -r key reviewer agent_path || [ -n "${key:-}" ]; do
    [ -z "${key:-}" ] && continue
    case "$key" in \#*) continue ;; esac
    [ -z "${reviewer:-}" ] && continue
    [ -z "${agent_path:-}" ] && continue
    keys+=("$key")
    reviewers+=("$reviewer")
  done <"$tsv"

  # Aggregate per-reviewer totals across every key routed to that reviewer
  # (e.g. .ts + .js -> typescript-reviewer, under ONE threshold).
  local uniq_names=() uniq_totals=()
  local i idx count found

  for i in "${!keys[@]}"; do
    key="${keys[$i]}"
    reviewer="${reviewers[$i]}"
    case "$key" in
      .*) count="$(_rac_count_extension "$project_dir" "$key")" ;;
      *) count="$(_rac_count_pathglob "$project_dir" "$key")" ;;
    esac

    found=0
    for idx in "${!uniq_names[@]}"; do
      if [ "${uniq_names[$idx]}" = "$reviewer" ]; then
        uniq_totals[idx]=$(( uniq_totals[idx] + count ))
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      uniq_names+=("$reviewer")
      uniq_totals+=("$count")
    fi
  done

  local name total
  for idx in "${!uniq_names[@]}"; do
    name="${uniq_names[$idx]}"
    total="${uniq_totals[$idx]}"
    [ "$total" -ge "$min_files" ] || continue
    _rac_is_covered "$project_dir" "$name" && continue
    _rac_is_declined "$project_dir" "$name" && continue
    printf '%s\n' "$name"
  done

  return 0
}

# ---------------------------------------------------------------------------
# reviewer_coverage_check_integrity [<tsv-path>] [<kernel-root>]
#
# Referential-integrity check: every catalog-agent-path column in the tsv
# must resolve to a real file relative to <kernel-root>. Prints one DANGLING
# line per violation to stderr; returns 0 iff none found.
# ---------------------------------------------------------------------------
reviewer_coverage_check_integrity() {
  local tsv="${1:-$REVIEWER_ROUTING_TSV}"
  local kernel_root="${2:-$KERNEL_ROOT}"

  if [ ! -f "$tsv" ]; then
    echo "reviewer_coverage_check_integrity: tsv not found at $tsv" >&2
    return 1
  fi

  local key reviewer agent_path violations=0
  while IFS=$'\t' read -r key reviewer agent_path || [ -n "${key:-}" ]; do
    [ -z "${key:-}" ] && continue
    case "$key" in \#*) continue ;; esac
    [ -z "${reviewer:-}" ] && continue
    [ -z "${agent_path:-}" ] && continue
    if [ ! -f "${kernel_root}/${agent_path}" ]; then
      printf 'DANGLING: %s -> %s (catalog-agent-path not found: %s)\n' \
        "$key" "$reviewer" "${kernel_root}/${agent_path}" >&2
      violations=$((violations + 1))
    fi
  done <"$tsv"

  [ "$violations" -eq 0 ]
}

# ---------------------------------------------------------------------------
# CLI — only runs when this file is the top-level executed script, never on
# `source`.
# ---------------------------------------------------------------------------
_rac_usage() {
  sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

_rac_default_project_dir() {
  local d
  if d="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$d"
  else
    pwd
  fi
}

main() {
  local project_dir="" mode="report"

  while [ $# -gt 0 ]; do
    case "$1" in
      --project-dir)
        [ $# -ge 2 ] || { echo "reviewer-activation-coverage: --project-dir needs a value" >&2; exit 2; }
        project_dir="$2"; shift 2 ;;
      --project-dir=*)
        project_dir="${1#*=}"; shift ;;
      --list-only) mode="list"; shift ;;
      --check-integrity) mode="integrity"; shift ;;
      -h|--help) _rac_usage; exit 0 ;;
      *) echo "reviewer-activation-coverage: unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  if [ "$mode" = "integrity" ]; then
    if reviewer_coverage_check_integrity "$REVIEWER_ROUTING_TSV" "$KERNEL_ROOT"; then
      echo "OK — every catalog-agent-path in $(basename "$REVIEWER_ROUTING_TSV") resolves to a real file"
      exit 0
    fi
    echo "FAIL — one or more catalog-agent-path entries are dangling (see above)" >&2
    exit 1
  fi

  if [ -z "$project_dir" ]; then
    project_dir="$(_rac_default_project_dir)"
  fi
  if [ ! -d "$project_dir" ]; then
    echo "reviewer-activation-coverage: --project-dir does not exist: $project_dir" >&2
    exit 1
  fi
  project_dir="$(cd "$project_dir" && pwd)"

  if [ "$mode" = "list" ]; then
    reviewer_coverage_gaps "$project_dir" "$REVIEWER_ROUTING_TSV"
    exit 0
  fi

  # Default: human-readable, still read-only, report.
  echo "Reviewer activation-coverage scan — $project_dir"
  echo "  threshold (REVIEWER_SCAN_MIN_FILES) = ${REVIEWER_SCAN_MIN_FILES:-3}"
  echo
  local gaps
  gaps="$(reviewer_coverage_gaps "$project_dir" "$REVIEWER_ROUTING_TSV")"
  if [ -z "$gaps" ]; then
    echo "  no activation gaps found"
  else
    echo "  activation gap(s):"
    while IFS= read -r g; do
      [ -n "$g" ] && echo "    - $g"
    done <<<"$gaps"
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -e
  main "$@"
fi
