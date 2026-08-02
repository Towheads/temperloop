#!/usr/bin/env bash
#
# check-gate-paths.sh — completeness + reachability lint for the diff-scoped
# gate-selection map (temperloop#1024).
#
# This is the validation half of the path->gate map. Diff-scoped CI selection
# is only safe if the map cannot silently fall behind the gate list, so the map
# ships with its own gate — the same live-check-then-fixture-tests shape as
# check-setting-registry.sh and check-reviewer-routing.sh, and the same
# validate-capture-backstop.sh mold ("a registry that is not mechanically
# reconciled against the tree is a registry that drifts").
#
# FOUR CHECKS, all against the CURRENT tree (no baseline — the map was authored
# complete, so a red run is real drift, never debt to grandfather in):
#
#   1. WELL-FORMED   every non-comment row is TAB-separated with a non-empty
#      key and a non-empty glob list; no key appears twice.
#   2. COMPLETE      every gate scripts/quality-gates.sh reports on its
#      `[kernel]` layer has a row. A gate with no row still RUNS at selection
#      time (gate-selection.sh over-runs rather than under-runs), but leaving
#      it unmapped is drift, so it fails here rather than quietly widening
#      every PR's run forever.
#   3. NO STALE ROWS  every row key is either a reserved pseudo-key (`ALL`,
#      `none`) or a gate that currently exists. A row naming a deleted gate is
#      dead weight that hides a rename.
#   4. REACHABLE     every glob-bearing row has at least one glob that matches
#      at least one git-tracked path. THIS is the check the issue's second
#      constraint asks for: a gate whose globs can never match is a gate that
#      is silently skipped on every scoped run — exactly the silent-green class
#      the map must not reopen. `ALWAYS` rows are exempt by construction (they
#      carry no globs and run every scoped run). Additionally, any LITERAL
#      (wildcard-free) glob must exist in the tree — a literal that matches
#      nothing is a typo or a stale path, never a deliberate forward
#      reference. A WILDCARD that matches nothing is tolerated as long as its
#      row is otherwise reachable, because a wildcard may legitimately name an
#      optional surface (`scripts/quality-gates.d/**` exists only in a tree
#      that carries overlay drop-ins).
#
# Glob semantics are NOT reimplemented here: this script sources
# workflows/scripts/lib/gate-selection.sh and calls its `_gs_path_matches_glob`,
# so the matcher that validates the map is byte-for-byte the matcher that
# consumes it. A divergence between the two would be precisely the kind of
# false-green this gate exists to prevent.
#
# VENDORING CONSUMERS: in a composed tree (repo-root `.kernel-pin` present) the
# surface-conditional gates quality-gates.sh class-gates away are legitimately
# absent, so checks 2 and 3 report a legible SKIP line for the affected rows
# instead of failing — mirroring quality-gates.sh's own SKIPPED_KERNEL_GATES
# convention. In the kernel's own checkout (no `.kernel-pin`) both are hard.
#
# Usage:
#   check-gate-paths.sh
#
# Env overrides (the fixture seams, mirroring workflows/scripts/config/*'s
# SETTING_REGISTRY_* convention):
#   GATE_PATHS_FILE            map to validate (default: sibling gate-paths.tsv)
#   GATE_PATHS_ROOT            repo root (default: this script's repo)
#   GATE_PATHS_GATE_LIST_FILE  file of `[layer]  <gate>` lines to use instead of
#                              invoking scripts/quality-gates.sh --list
#   GATE_PATHS_TRACKED_FILE    file of tracked paths (one per line) to use
#                              instead of `git ls-files`
#   GATE_PATHS_ASSUME_CONSUMER 1 forces the vendoring-consumer arm (test seam)
#
# Kept bash-3.2-portable (macOS default shell): no associative arrays, no
# mapfile.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ROOT="${GATE_PATHS_ROOT:-$REPO_ROOT_DEFAULT}"
MAP_FILE="${GATE_PATHS_FILE:-$SCRIPT_DIR/gate-paths.tsv}"

# The shared matcher — never a second copy (see the header).
# shellcheck source=../lib/gate-selection.sh
if ! source "$REPO_ROOT_DEFAULT/workflows/scripts/lib/gate-selection.sh"; then
  echo "check-gate-paths: cannot source gate-selection.sh" >&2
  exit 1
fi

fail=0
issues=0

_gp_issue() {
  printf '  [FAIL] %s\n' "$1" >&2
  issues=$((issues + 1))
  fail=1
}

# --- consumer detection ------------------------------------------------------
CONSUMER=0
if [[ "${GATE_PATHS_ASSUME_CONSUMER:-0}" == "1" ]] || [[ -f "$ROOT/.kernel-pin" ]]; then
  CONSUMER=1
fi

# --- inputs ------------------------------------------------------------------
if [[ ! -f "$MAP_FILE" ]]; then
  echo "check-gate-paths: map file not found: $MAP_FILE" >&2
  exit 1
fi

GATE_LIST_RAW=""
if [[ -n "${GATE_PATHS_GATE_LIST_FILE:-}" ]]; then
  GATE_LIST_RAW="$(cat "$GATE_PATHS_GATE_LIST_FILE")"
elif [[ -x "$ROOT/scripts/quality-gates.sh" || -f "$ROOT/scripts/quality-gates.sh" ]]; then
  if ! GATE_LIST_RAW="$(bash "$ROOT/scripts/quality-gates.sh" --list 2>/dev/null)"; then
    echo "check-gate-paths: scripts/quality-gates.sh --list failed" >&2
    exit 1
  fi
else
  echo "check-gate-paths: no gate list available (no --list source)" >&2
  exit 1
fi

TRACKED=""
if [[ -n "${GATE_PATHS_TRACKED_FILE:-}" ]]; then
  TRACKED="$(cat "$GATE_PATHS_TRACKED_FILE")"
else
  TRACKED="$(git -C "$ROOT" ls-files 2>/dev/null)"
fi
if [[ -z "$TRACKED" ]]; then
  echo "check-gate-paths: no tracked paths resolved under $ROOT" >&2
  exit 1
fi

# Kernel-layer gates (completeness is enforced over these) and the union of all
# declared gates (staleness is judged against this).
KERNEL_GATE_LIST=""
ALL_GATE_LIST=""
while IFS= read -r line; do
  case "$line" in
    '[kernel]  '*)
      KERNEL_GATE_LIST="${KERNEL_GATE_LIST:+$KERNEL_GATE_LIST$'\n'}${line#'[kernel]  '}"
      ALL_GATE_LIST="${ALL_GATE_LIST:+$ALL_GATE_LIST$'\n'}${line#'[kernel]  '}"
      ;;
    '[overlay] '*)
      ALL_GATE_LIST="${ALL_GATE_LIST:+$ALL_GATE_LIST$'\n'}${line#'[overlay] '}"
      ;;
    *) : ;;  # `[skipped] …` lines carry a reason, not a gate command
  esac
done <<<"$GATE_LIST_RAW"

if [[ -z "$KERNEL_GATE_LIST" ]]; then
  echo "check-gate-paths: gate list contained no [kernel] entries" >&2
  exit 1
fi

echo "==> check-gate-paths: validating $(basename "$MAP_FILE")"

# --- 1. well-formed ----------------------------------------------------------
KEYS=""
GLOBS_BY_INDEX=()
KEY_BY_INDEX=()
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  line="${line%$'\r'}"
  case "$line" in ''|'#'*) continue ;; esac
  case "$line" in
    *$'\t'*) : ;;
    *) _gp_issue "line $lineno: no TAB separator: $line"; continue ;;
  esac
  key="${line%%$'\t'*}"
  globs="${line#*$'\t'}"
  if [[ -z "$key" ]]; then _gp_issue "line $lineno: empty key"; continue; fi
  if [[ -z "$globs" ]]; then _gp_issue "line $lineno: empty glob list for key '$key'"; continue; fi
  case "$globs" in
    *$'\t'*) _gp_issue "line $lineno: more than two TAB-separated columns for key '$key'"; continue ;;
  esac
  if grep -Fxq -- "$key" <<<"$KEYS" 2>/dev/null; then
    _gp_issue "line $lineno: duplicate key '$key'"
    continue
  fi
  KEYS="${KEYS:+$KEYS$'\n'}$key"
  KEY_BY_INDEX+=("$key")
  GLOBS_BY_INDEX+=("$globs")
done <"$MAP_FILE"

if [[ ${#KEY_BY_INDEX[@]} -eq 0 ]]; then
  _gp_issue "map has no usable rows"
fi

# --- 2. completeness ---------------------------------------------------------
while IFS= read -r gate; do
  [[ -n "$gate" ]] || continue
  if ! grep -Fxq -- "$gate" <<<"$KEYS"; then
    _gp_issue "gate has no row in the map (add one, or the gate widens every scoped run): $gate"
  fi
done <<<"$KERNEL_GATE_LIST"

# --- 3. no stale rows --------------------------------------------------------
i=0
while [[ $i -lt ${#KEY_BY_INDEX[@]} ]]; do
  key="${KEY_BY_INDEX[$i]}"
  i=$((i + 1))
  case "$key" in ALL|none) continue ;; esac
  if ! grep -Fxq -- "$key" <<<"$ALL_GATE_LIST"; then
    if [[ $CONSUMER -eq 1 ]]; then
      printf '  [skip] row names a gate absent from this composed tree (vendoring consumer): %s\n' "$key"
    else
      _gp_issue "row names a gate that does not exist (stale row — was it renamed or deleted?): $key"
    fi
  fi
done

# --- 4. reachability ---------------------------------------------------------
# Every glob-bearing row must have at least one glob that matches at least one
# git-tracked path. An unmatched glob means the gate can never be selected.
i=0
while [[ $i -lt ${#KEY_BY_INDEX[@]} ]]; do
  key="${KEY_BY_INDEX[$i]}"
  globs="${GLOBS_BY_INDEX[$i]}"
  i=$((i + 1))
  [[ "$globs" == "ALWAYS" ]] && continue
  # `read -r -a`, never a bare `for glob in $globs` — the latter pathname-expands
  # the author's globs against the working directory before they are ever tested.
  read -r -a GLOB_LIST <<<"$globs"
  row_hit=0
  for glob in "${GLOB_LIST[@]}"; do
    hit=0
    # Fast path: a glob with no wildcard is an exact path — a single grep beats
    # a bash loop over ~700 tracked paths, and most rows name exact files.
    case "$glob" in
      *'*'*|*'?'*|*'['*)
        while IFS= read -r p; do
          [[ -n "$p" ]] || continue
          if _gs_path_matches_glob "$p" "$glob"; then hit=1; break; fi
        done <<<"$TRACKED"
        ;;
      *)
        if grep -Fxq -- "$glob" <<<"$TRACKED"; then hit=1; fi
        # A LITERAL path (no wildcard) that matches nothing is a typo or a
        # stale reference — always a failure. A WILDCARD may legitimately
        # point at an optional/absent surface (scripts/quality-gates.d/** in
        # the kernel's own checkout, an overlay-only tree), so it is judged
        # only through the row-level check below.
        if [[ $hit -eq 0 ]]; then
          _gp_issue "literal path '$glob' does not exist in the tree (typo or stale reference) on row: $key"
        fi
        ;;
    esac
    [[ $hit -eq 1 ]] && row_hit=1
  done
  # THE anti-silent-green check: a row whose globs can NEVER match is a gate
  # that is silently skipped on every scoped run, forever.
  if [[ $row_hit -eq 0 ]]; then
    _gp_issue "unreachable row — no glob matches any tracked path, so this gate can never be selected: $key"
  fi
done

# --- verdict -----------------------------------------------------------------
n_rows=${#KEY_BY_INDEX[@]}
n_gates="$(grep -c . <<<"$KERNEL_GATE_LIST" || true)"
if [[ $fail -ne 0 ]]; then
  printf '\ncheck-gate-paths: FAILED — %d issue(s) across %d row(s) / %d kernel gate(s).\n' \
    "$issues" "$n_rows" "$n_gates" >&2
  printf 'Fix by editing %s: every kernel gate needs exactly one row, every row a\n' "$MAP_FILE" >&2
  printf 'glob that matches at least one tracked path (or the literal ALWAYS).\n' >&2
  exit 1
fi
printf '  [ok] %d row(s) cover %d kernel gate(s); every glob reaches the tree\n' "$n_rows" "$n_gates"
exit 0
