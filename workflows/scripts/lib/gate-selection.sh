#!/usr/bin/env bash
#
# gate-selection.sh — DIFF-SCOPED gate selection for scripts/quality-gates.sh
# (temperloop#1024).
#
# Sourced, never executed — the same seam as its siblings gate-retry.sh and
# checkout-freshness.sh, and for the same reason: quality-gates.sh's gate LIST
# is ~110 hardcoded `make`/`bash` targets, so a selection policy embedded in
# that file could not be exercised by a test without running the whole suite.
# Here it takes a synthetic map + a synthetic changed-path list and is testable
# in milliseconds (workflows/scripts/lib/tests/test_gate_selection.sh).
#
# ── The problem ──────────────────────────────────────────────────────────
# The `checks` job runs the whole gate set sequentially (~5.5 min measured
# 2026-08-02, flat across the last 20 runs) on EVERY pull_request, and again on
# merge_group — so every merged PR pays ≥11 min of CI even when the diff is a
# single docs file. Almost none of those suites can be affected by a docs edit.
#
# ── The shape of the fix ─────────────────────────────────────────────────
# A registry (workflows/scripts/config/gate-paths.tsv) maps each gate to the
# path globs that can affect it. On a `pull_request` event with a resolvable
# base SHA, only the gates reachable from the changed paths run. Everywhere
# else — merge_group, push:main, nightly, a local or worker run, an
# unresolvable base, a missing/unparseable map — the FULL set runs exactly as
# before. Full-set coverage of `main` is therefore never weakened: the merge
# queue's own `checks` run is unscoped.
#
# ── The failure class this must not reintroduce ──────────────────────────
# A path→gate map that misses a dependency silently runs a NARROWER set and
# reports green — the silent-green class. Four structural defenses:
#
#   1. DEFAULT TO FULL on an unrecognised path. A changed path that matches no
#      glob in ANY row escalates the whole run to the full set. Narrowing is
#      opt-in per path, never the fallback.
#   2. DEFAULT TO FULL on any resolution failure — no base, a base git cannot
#      resolve, an empty/failed diff, a missing or malformed map file. Every
#      degradation is announced on stderr, never silent.
#   3. AN EXPLICIT ESCALATION ROW (`ALL`). Paths whose blast radius is the gate
#      machinery itself (quality-gates.sh, this lib, the map, the Makefile, the
#      CI workflows, the kernel manifest) force the full set outright.
#   KNOWN, BOUNDED GAP (temperloop#1695): git reports a RENAME as a single line
#      carrying the DESTINATION path, so moving a file OUT of a gated tree does
#      not put the source tree in the changed set and that tree's gates are not
#      selected. Equally true of the `pull_request` path since #1024; the
#      unscoped merge_group run still catches it before the default branch. It is
#      a latency gap, not a hole in what gates `main` — tracked, not silently
#      inherited. `--no-renames` would list both paths and is the likely fix.
#
#   4. AN UNMAPPED GATE ALWAYS RUNS. A gate with no row in the map is selected
#      unconditionally rather than skipped, so a map that has fallen behind the
#      gate list over-runs instead of under-running. The companion validator
#      (workflows/scripts/config/check-gate-paths.sh, itself a gate) turns that
#      soft over-run into a hard build failure in the kernel's own checkout,
#      and additionally proves every row's globs match at least one tracked
#      path — a gate orphaned behind a glob that can never match fails the
#      build rather than being silently skipped forever.
#
# ── Map format (workflows/scripts/config/gate-paths.tsv) ─────────────────
#   <key><TAB><glob>[ <glob> ...]
#   * `#` comments and blank lines ignored.
#   * <key> is a gate command EXACTLY as it appears in quality-gates.sh's
#     GATES array, or one of two reserved pseudo-keys:
#       ALL   — the globs listed escalate the run to the FULL set.
#       none  — the globs listed are RECOGNISED but affect no gate.
#   * The single token `ALWAYS` in place of a glob list marks a gate that runs
#     on every scoped run (a whole-tree scanner). An `ALWAYS` row contributes
#     NOTHING to path recognition — otherwise a whole-tree gate's `**` would
#     match every path and defense (1) above could never fire.
#   * `**` inside a glob means "any characters, including `/`"; so does `*`
#     (bash `[[ ]]` pattern matching is not path-component aware). Both forms
#     are accepted so a glob reads the way an author expects.
#
# Public entry point:
#   gate_selection_resolve   — reads the GATE_SELECTION_* inputs below and sets
#                              the GATE_SELECTION_MODE / _SELECTED / _REASON
#                              outputs. Never fails the caller: on any problem
#                              it degrades to mode=full with a stated reason.
#
# Inputs (globals, set by the caller before the call):
#   GATE_SELECTION_ROOT        repo root (git operations run with -C here)
#   GATE_SELECTION_MAP_FILE    path to gate-paths.tsv
#   GATE_SELECTION_ALL_GATES   newline-delimited full gate list, in run order
#   GATE_SELECTION_BASE        base ref/sha to diff against (caller passes
#                              $LEAK_GUARD_BASE — ci.yml already supplies it,
#                              so no second base-derivation path exists)
#   GATE_SELECTION_CHANGED     OPTIONAL caller-supplied changed-path set:
#                              newline-delimited paths used verbatim instead of
#                              running git. Two real callers: this suite's own
#                              fixture tests, and quality-gates.sh's `--scoped`
#                              mode, which hands in the LOCAL working-tree set
#                              gate_selection_local_changed() computes below.
#
# Outputs (globals):
#   GATE_SELECTION_MODE        full | diff
#   GATE_SELECTION_REASON      one human-readable line explaining the mode
#   GATE_SELECTION_SELECTED    newline-delimited selected gates, in the input
#                              order (mode=diff only; empty when mode=full)
#   GATE_SELECTION_SKIPPED     newline-delimited gates the selection LEFT OUT,
#                              in the input order (mode=diff only). The
#                              complement of _SELECTED, computed here rather
#                              than re-derived by each caller, so a scoped run
#                              can NAME what it did not run — a green scoped
#                              run that cannot say what it skipped is
#                              indistinguishable from a green full one
#                              (temperloop#957).
#   GATE_SELECTION_MATCHED     newline-delimited changed paths that were
#                              recognised (diagnostics)
#   GATE_SELECTION_LOCAL_BASE  set by gate_selection_local_changed(): the base
#                              commit that resolution settled on (diagnostics)
#
# Second entry point:
#   gate_selection_local_changed <root>
#                              print the LOCAL working-tree changed set (see
#                              its own comment block). Non-zero, with a stderr
#                              line, when no base resolves — the caller must
#                              then degrade to the full set.
#   gate_selection_local_changed_to_file <root> <outfile>
#                              the same resolution, paths written to <outfile>,
#                              run in the CALLER'S shell so the
#                              GATE_SELECTION_LOCAL_BASE out-param survives
#                              (temperloop#1663 — a command substitution is a
#                              subshell and silently swallowed it).
#
# Settings:
#   QUALITY_GATES_SCOPE  auto (default) | full | diff.  `auto` scopes only on a
#     GitHub `pull_request` event; `full` disables scoping outright; `diff`
#     forces an attempt regardless of event (the local/CI test seam, and what
#     quality-gates.sh's `--scoped` flag sets).
#
# Kept bash-3.2-portable (macOS default shell): no associative arrays, no
# mapfile, no `${v,,}`.

# --- glob matching -----------------------------------------------------------
# `**` and `*` both mean "any characters including /": bash's `[[ str == pat ]]`
# is not path-component aware, so `docs/*` already matches `docs/a/b.md`. `**`
# is normalised to `*` purely so an author can write the intuitive form.
_gs_path_matches_glob() {
  # `cand_path`, not `path`: under zsh a `local path=` rebinds $PATH for the
  # scope (temperloop#40, enforced by scripts/lint-zsh-param-tie.sh).
  local cand_path="$1" glob="$2" star='*' pat
  pat="${glob//\*\*/$star}"
  # shellcheck disable=SC2053  # RHS is a glob on purpose
  [[ "$cand_path" == $pat ]]
}

# --- map loading -------------------------------------------------------------
# Fills the parallel arrays _GS_KEYS / _GS_GLOBS. Returns non-zero (with a
# stderr line) on a malformed row so the caller can degrade to the full set.
_gs_load_map() {
  local file="$1" line key globs
  _GS_KEYS=()
  _GS_GLOBS=()
  if [[ ! -f "$file" ]]; then
    printf 'gate-selection: map file not found: %s\n' "$file" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip a trailing CR so a CRLF-checked-out map still parses.
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *$'\t'*) : ;;
      *)
        printf 'gate-selection: malformed row (no TAB): %s\n' "$line" >&2
        return 1
        ;;
    esac
    key="${line%%$'\t'*}"
    globs="${line#*$'\t'}"
    if [[ -z "$key" || -z "$globs" ]]; then
      printf 'gate-selection: malformed row (empty key or glob list): %s\n' "$line" >&2
      return 1
    fi
    _GS_KEYS+=("$key")
    _GS_GLOBS+=("$globs")
  done <"$file"
  if [[ ${#_GS_KEYS[@]} -eq 0 ]]; then
    printf 'gate-selection: map file has no rows: %s\n' "$file" >&2
    return 1
  fi
  return 0
}

# --- changed-path resolution -------------------------------------------------
# `git diff --name-only <base>...HEAD` — the same three-dot form the PR leak
# guard uses, so both diff-scoped consumers see the same file set.
_gs_changed_paths() {
  local root="$1" base="$2"
  [[ -n "$base" ]] || return 1
  git -C "$root" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || return 1
  git -C "$root" diff --name-only "${base}...HEAD" 2>/dev/null || return 1
}

# --- LOCAL working-tree changed set (temperloop#957) --------------------------
# The CI path above diffs a PUSHED head against a supplied base. A /build item
# worker asking for a mid-work gate run has neither: its work is a mix of
# committed, staged, unstaged and brand-new files in a throwaway worktree, and
# nothing exports a base for it. So this helper resolves the base itself and
# unions the four sources — anything less would UNDER-run:
#
#   1. <merge-base(origin/<default>, HEAD)>...HEAD   the worker's commits
#   2. `git diff --name-only HEAD`                   staged + unstaged edits
#   3. `git ls-files --others --exclude-standard`    new, not-yet-added files
#
# (2) and (3) are what make this usable MID-work rather than only after a
# commit, and (3) is why a brand-new source file cannot hide from the selector.
# Ignored files are deliberately excluded via --exclude-standard: the build
# harness drops its own scratch (`.build-guard`, `.build-verification.md`) into
# the worktree root, and those are not changes to the tree under test.
#
# BASE RESOLUTION IS MANDATORY. If no base resolves, this returns non-zero and
# the caller degrades to the full set — it does NOT fall back to "the
# working-tree changes alone", which would silently hide every committed change
# and is exactly the silent-green class defense (2) in the header exists for.
# GATE_SELECTION_LOCAL_BASE is an OUT-PARAM read by the sourcing caller (the
# base this resolution settled on, reported in the run's own scope line), so
# the static linter's "appears unused" is a false positive — same blanket
# disable as gate_selection_resolve below.
# shellcheck disable=SC2034
gate_selection_local_changed() {
  local root="${1:-.}" default_ref="" base=""
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || {
    printf 'gate-selection: %s is not a git checkout — cannot resolve a local changed set\n' "$root" >&2
    return 1
  }
  # origin/HEAD when the remote advertises one, else the conventional names.
  default_ref="$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  local cand
  for cand in "$default_ref" origin/main origin/master main master; do
    [[ -n "$cand" ]] || continue
    if base="$(git -C "$root" merge-base "$cand" HEAD 2>/dev/null)" && [[ -n "$base" ]]; then
      break
    fi
    base=""
  done
  if [[ -z "$base" ]]; then
    printf 'gate-selection: no default-branch merge-base resolvable in %s\n' "$root" >&2
    return 1
  fi
  GATE_SELECTION_LOCAL_BASE="$base"
  {
    git -C "$root" diff --name-only "${base}...HEAD" 2>/dev/null
    git -C "$root" diff --name-only HEAD 2>/dev/null
    git -C "$root" ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | grep -v '^$'
  return 0
}

# --- gate_selection_local_changed_to_file <root> <outfile> --------------------
# The same resolution as above, but the PATHS go to <outfile> and the function
# runs in the CALLER'S shell, so GATE_SELECTION_LOCAL_BASE actually survives.
#
# WHY THIS EXISTS (temperloop#1663). The out-param above is real but was
# unreachable: quality-gates.sh's only caller invoked it as
# `x="$(gate_selection_local_changed …)"`, and a command substitution is a
# SUBSHELL — the assignment died with it, so the base-disclosure line guarded by
# `[[ -n "$GATE_SELECTION_LOCAL_BASE" ]]` could never print. That line is the
# only place a scoped run names the tree state it scoped against, which is
# exactly what an operator needs when a run narrows more than they expected.
# Latent since #957; it became load-bearing when #1663 put scoping on the
# acceptance path.
#
# Returns non-zero (leaving <outfile> untouched) on the same no-base condition
# the sibling reports, so the caller degrades to the full set identically.
# GATE_SELECTION_LOCAL_BASE is an OUT-PARAM read by the sourcing caller — the
# same false positive the sibling above carries, and the same blanket disable.
# shellcheck disable=SC2034
gate_selection_local_changed_to_file() {
  local root="${1:-.}" out="$2" paths
  # The inner call still runs in a substitution, so re-do the base resolution
  # here rather than reading the sibling's out-param through the same trap this
  # function exists to avoid.
  paths="$(gate_selection_local_changed "$root")" || return 1
  # ...and recompute the base in THIS shell so the global lands where the caller
  # can see it. Cheap (one merge-base), and it cannot disagree with the sibling:
  # both walk the identical candidate list against the identical HEAD.
  local default_ref cand base=""
  default_ref="$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  for cand in "$default_ref" origin/main origin/master main master; do
    [[ -n "$cand" ]] || continue
    if base="$(git -C "$root" merge-base "$cand" HEAD 2>/dev/null)" && [[ -n "$base" ]]; then
      break
    fi
    base=""
  done
  GATE_SELECTION_LOCAL_BASE="$base"
  printf '%s\n' "$paths" >"$out" || return 1
  return 0
}

# --- membership over a newline-delimited set ---------------------------------
_gs_in_list() {
  local needle="$1" list="$2" item
  while IFS= read -r item; do
    [[ "$item" == "$needle" ]] && return 0
  done <<<"$list"
  return 1
}

# --- the selection itself ----------------------------------------------------
# GATE_SELECTION_MODE / _REASON / _SELECTED / _MATCHED are OUT-PARAMS: written
# here, read by the sourcing caller (this is a sourced lib, not a program), so
# the static linter's "appears unused" is a false positive for the whole
# function — same blanket disable as gate-retry.sh's gate_run_with_retry.
# shellcheck disable=SC2034
gate_selection_resolve() {
  GATE_SELECTION_MODE="full"
  GATE_SELECTION_REASON=""
  GATE_SELECTION_SELECTED=""
  GATE_SELECTION_SKIPPED=""
  GATE_SELECTION_MATCHED=""

  local scope="${QUALITY_GATES_SCOPE:-auto}"
  local event="${GITHUB_EVENT_NAME:-}"  # setting:exempt — GitHub Actions' own ambient event name, not an operator default this repo defines
  case "$scope" in
    full)
      GATE_SELECTION_REASON="full set — QUALITY_GATES_SCOPE=full"
      return 0
      ;;
    diff) : ;;
    auto)
      if [[ "$event" != "pull_request" ]]; then
        GATE_SELECTION_REASON="full set — event '${event:-<none>}' is not pull_request (scoping applies to pull_request only)"
        return 0
      fi
      ;;
    *)
      GATE_SELECTION_REASON="full set — unrecognised QUALITY_GATES_SCOPE='$scope' (expected auto|full|diff)"
      return 0
      ;;
  esac

  # The GATE_SELECTION_* globals below are this lib's CALL INTERFACE — set by
  # the caller immediately before the call, never operator-tunable settings —
  # so they are read once into locals here and marked exempt from the
  # setting-registry sweep (check-setting-registry.sh's own
  # "internal/derived/computed values" category).
  local root="${GATE_SELECTION_ROOT:-.}"     # setting:exempt — internal call-interface global, set by the caller
  local map="${GATE_SELECTION_MAP_FILE:-}"   # setting:exempt — internal call-interface global, set by the caller
  local all="${GATE_SELECTION_ALL_GATES:-}"  # setting:exempt — internal call-interface global, set by the caller
  local base="${GATE_SELECTION_BASE:-}"      # setting:exempt — internal call-interface global, set by the caller
  if [[ -z "$all" ]]; then
    GATE_SELECTION_REASON="full set — no gate list supplied to the selector"
    return 0
  fi

  local changed
  if [[ -n "${GATE_SELECTION_CHANGED+x}" ]]; then
    changed="$GATE_SELECTION_CHANGED"
  else
    if ! changed="$(_gs_changed_paths "$root" "$base")"; then
      GATE_SELECTION_REASON="full set — no resolvable diff base (base='$base')"
      return 0
    fi
  fi
  if [[ -z "$changed" ]]; then
    GATE_SELECTION_REASON="full set — the diff against '$base' resolved zero changed paths"
    return 0
  fi

  if ! _gs_load_map "$map"; then
    GATE_SELECTION_REASON="full set — gate-path map unusable (see the line above)"
    return 0
  fi

  local selected="" matched="" chg_path i key globs glob hit any_recognised
  local _gs_glob_list=()
  while IFS= read -r chg_path; do
    [[ -n "$chg_path" ]] || continue
    any_recognised=0
    i=0
    while [[ $i -lt ${#_GS_KEYS[@]} ]]; do
      key="${_GS_KEYS[$i]}"
      globs="${_GS_GLOBS[$i]}"
      i=$((i + 1))
      # An ALWAYS row is not a recogniser — see the header. Its gate is added
      # unconditionally further down.
      [[ "$globs" == "ALWAYS" ]] && continue
      hit=0
      # `read -r -a` splits on IFS WITHOUT pathname expansion. A bare
      # `for glob in $globs` would let the shell expand `docs/**` against the
      # working directory before the matcher ever saw it — silently replacing
      # the author's glob with whatever happens to exist on disk.
      read -r -a _gs_glob_list <<<"$globs"
      for glob in "${_gs_glob_list[@]}"; do
        if _gs_path_matches_glob "$chg_path" "$glob"; then hit=1; break; fi
      done
      [[ $hit -eq 1 ]] || continue
      any_recognised=1
      case "$key" in
        ALL)
          GATE_SELECTION_REASON="full set — changed path '$chg_path' matches an ALL escalation glob ('$glob')"
          return 0
          ;;
        none) : ;;  # recognised, affects no gate
        *)
          _gs_in_list "$key" "$selected" || selected="${selected:+$selected$'\n'}$key"
          ;;
      esac
    done
    if [[ $any_recognised -eq 0 ]]; then
      GATE_SELECTION_REASON="full set — changed path '$chg_path' matches no glob in the gate-path map (default-to-full on an unmapped path)"
      return 0
    fi
    matched="${matched:+$matched$'\n'}$chg_path"
  done <<<"$changed"

  # Emit in the caller's run order, and keep any gate the map does not mention
  # (defense 4 in the header: an unmapped gate over-runs, never under-runs).
  local gate ordered="" left_out="" mapped always keep
  while IFS= read -r gate; do
    [[ -n "$gate" ]] || continue
    mapped=0
    always=0
    i=0
    while [[ $i -lt ${#_GS_KEYS[@]} ]]; do
      if [[ "${_GS_KEYS[$i]}" == "$gate" ]]; then
        mapped=1
        [[ "${_GS_GLOBS[$i]}" == "ALWAYS" ]] && always=1
        break
      fi
      i=$((i + 1))
    done
    keep=0
    if [[ $mapped -eq 0 ]]; then
      keep=1                       # unmapped gate — over-run, never under-run
    elif [[ $always -eq 1 ]]; then
      keep=1                       # whole-tree scanner — runs every scoped run
    elif _gs_in_list "$gate" "$selected"; then
      keep=1                       # selected by a changed path
    fi
    if [[ $keep -eq 1 ]]; then
      ordered="${ordered:+$ordered$'\n'}$gate"
    else
      left_out="${left_out:+$left_out$'\n'}$gate"
    fi
  done <<<"$all"

  GATE_SELECTION_MODE="diff"
  GATE_SELECTION_SELECTED="$ordered"
  GATE_SELECTION_SKIPPED="$left_out"
  GATE_SELECTION_MATCHED="$matched"
  local n_changed n_sel n_all
  n_changed="$(printf '%s\n' "$changed" | grep -c . || true)"
  n_sel="$(printf '%s\n' "$ordered" | grep -c . || true)"
  n_all="$(printf '%s\n' "$all" | grep -c . || true)"
  GATE_SELECTION_REASON="diff-scoped — ${n_changed} changed path(s) vs '${base:-<seeded>}' select ${n_sel}/${n_all} gate(s)"
  return 0
}
