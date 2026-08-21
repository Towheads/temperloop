#!/usr/bin/env bash
#
# test_check_surface_degenerate_backfill.sh — the degenerate-input fixture
# suite for the check surfaces registered in bulk by temperloop#1491 ("close
# the degenerate-input registry class").
#
# WHY A SHARED FILE RATHER THAN 17 DEDICATED ONES. epic #1409's seed
# (temperloop#1476) gave each of its three motivating surfaces a dedicated
# `test_validate_<name>.sh`, because each needed a hand-built artifact
# (a real pa_disclose call, a throwaway git repo) to reach its degenerate
# state. The surfaces registered here need nothing of the kind: every one of
# them takes its input through a single documented fixture seam — an env var
# naming a root directory or a config file, or (lint-pr-body.sh) a positional
# FILE argument — so the whole absent/unreadable/empty triple is reachable by
# pointing that ONE seam at a scratch path. One suite that drives the seam
# uniformly is the honest shape for that; seventeen near-identical files would
# be sixteen copies of the same six lines.
#
# WHAT EACH ASSERTION PROVES. The registered contract is the one epic #1409
# names and nothing more: a check handed degenerate input EXITS NON-ZERO
# rather than reporting success. It is deliberately NOT "emits a particular
# diagnostic" — several of these surfaces reach non-zero by their own
# zero-rows-parsed / nothing-in-scope guard rather than by a dedicated
# unreadable-input branch, and pinning each one's exact message here would
# make this suite a change-detector for wording it does not own.
#
# ANCHOR DISCIPLINE (temperloop#1476 review round 2, HIGH 2). Each row's
# check-surface-registry.tsv anchor is the LABEL ARGUMENT OF THE ASSERTION
# CALL ITSELF — the `degenerate ...` line below IS the whole verification for
# that (surface, case), so deleting the line removes the assertion and the
# anchor together and the registry gate goes red naming exactly that pair.
# There is no separate trailing `ok(...)` line that could survive the
# assertion being deleted.
#
# THE DISCRIMINATION CONTROL. A shared helper is one gutting away from
# passing everything, so the suite ends with a NEGATIVE control that drives
# the same runner at a NON-degenerate input and requires exit 0. If the
# runner ever degrades to "always report non-zero", the control fails.
#
# Hermetic: every fixture path is a fresh subdirectory of one throwaway
# mktemp dir OUTSIDE this repo. Only the ONE named seam of each surface is
# made degenerate — every other input the surface reads stays real, which is
# the point (the surface must fail on the degenerate seam even when the rest
# of its world is intact). No network.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays), matching
# every sibling workflows/scripts/tests/ suite.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-check-surface-degenerate-backfill-XXXXXX")" || exit 1
# chmod back up before rm: a fixture that deliberately chmod 000s a path must
# never leave an unreadable path behind, even when this suite exits early
# (same convention as test_validate_provider_disclosure.sh).
cleanup() {
  chmod -R u+rwX "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0
total=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s: %s\n' "$1" "$2"; }

# _mk_target <dir|file> <absent|unreadable|empty> — materialise one degenerate
# input under a fresh scratch subdir and print its path.
#   absent      the path is never created
#   unreadable  the path exists with real content but is chmod 000
#   empty       the path exists and is empty (a zero-byte file / childless dir)
# A FRESH mktemp subdir per call, never a shared counter: this helper runs
# inside a `$(...)` command substitution, so any counter it incremented would
# be incremented in a SUBSHELL and lost — every fixture would collide on the
# same path and the `dir:*` cases would leave a directory where the `file:*`
# cases expect a file.
_mk_target() {
  local kind="$1" case_="$2" dir target
  dir="$(mktemp -d "$WORK/fXXXXXX")" || return 1
  target="$dir/target"
  case "$kind:$case_" in
    file:absent | dir:absent) : ;; # deliberately not created
    file:unreadable)
      printf 'x\n' >"$target" || return 1
      chmod 000 "$target" || return 1
      ;;
    file:empty) : >"$target" || return 1 ;;
    dir:unreadable)
      mkdir -p "$target/child" || return 1
      chmod 000 "$target" || return 1
      ;;
    dir:empty) mkdir -p "$target" || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$target"
}

# _run_surface <seam> <script-relpath> <target> [extra-args...] — invoke one
# surface with its ONE fixture seam pointed at <target>, and print nothing.
# Returns the surface's own exit code.
#   seam `env:VAR`  the seam is an environment variable naming the input
#   seam `arg`      the seam is a positional FILE argument, passed LAST so a
#                   preceding flag (lint-pr-body.sh's --require-verification)
#                   still parses
_run_surface() {
  local seam="$1" script="$2" target="$3"
  shift 3
  case "$seam" in
    env:*) env "${seam#env:}=$target" bash "$REPO_ROOT/$script" "$@" >/dev/null 2>&1 ;;
    arg) bash "$REPO_ROOT/$script" "$@" "$target" >/dev/null 2>&1 ;;
    *) return 125 ;;
  esac
}

# degenerate <seam> <dir|file> <case> <script-relpath> <anchor> [extra-args...]
# — the ONE assertion behind every `covered` row this suite backs. <anchor> is
# the check-surface-registry.tsv DETAIL string for that (surface, case).
degenerate() {
  local seam="$1" kind="$2" case_="$3" script="$4" anchor="$5"
  shift 5
  local target rc=0
  total=$((total + 1))
  if [ ! -f "$REPO_ROOT/$script" ]; then
    bad "$anchor" "surface not found at $REPO_ROOT/$script"
    return
  fi
  target="$(_mk_target "$kind" "$case_")" || {
    bad "$anchor" "fixture setup failed for $kind/$case_"
    return
  }
  _run_surface "$seam" "$script" "$target" "$@" || rc=$?
  chmod -R u+rwX "$(dirname "$target")" 2>/dev/null || true
  if [ "$rc" -eq 125 ]; then
    bad "$anchor" "unrecognised seam '$seam'"
  elif [ "$rc" -ne 0 ]; then
    ok "$anchor"
  else
    bad "$anchor" "exited 0 on $case_ input ($target) — a check that could not evaluate reported success"
  fi
}

# control <seam> <script-relpath> <label> <good-input-path> [extra-args...] —
# the NEGATIVE control: the same runner, a NON-degenerate input, exit 0
# required. Proves `degenerate`'s verdict discriminates rather than reporting
# non-zero unconditionally.
control() {
  local seam="$1" script="$2" label="$3" good="$4"
  shift 4
  local rc=0
  total=$((total + 1))
  _run_surface "$seam" "$script" "$good" "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$label"
  else
    bad "$label" "expected exit 0 on a non-degenerate input, got $rc"
  fi
}

# ---------------------------------------------------------------------------
# The registered (surface, case) assertions. Each line below is quoted
# verbatim as the DETAIL anchor of its check-surface-registry.tsv row.
# ---------------------------------------------------------------------------
degenerate env:DOCS_FOOTER_ROOT dir absent workflows/scripts/validate-docs-footer.sh "validate-docs-footer.sh [absent]: exits non-zero, never a silent OK"
degenerate env:DOCS_FOOTER_ROOT dir unreadable workflows/scripts/validate-docs-footer.sh "validate-docs-footer.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:DOCS_FOOTER_ROOT dir empty workflows/scripts/validate-docs-footer.sh "validate-docs-footer.sh [empty]: exits non-zero, never a silent OK"
degenerate env:FEATURE_DOCS_ROOT dir absent workflows/scripts/validate-feature-docs.sh "validate-feature-docs.sh [absent]: exits non-zero, never a silent OK"
degenerate env:FEATURE_DOCS_ROOT dir unreadable workflows/scripts/validate-feature-docs.sh "validate-feature-docs.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:FEATURE_DOCS_ROOT dir empty workflows/scripts/validate-feature-docs.sh "validate-feature-docs.sh [empty]: exits non-zero, never a silent OK"
degenerate env:ONRAMP_GATE_ROOT dir absent workflows/scripts/validate-onramp-anchors.sh "validate-onramp-anchors.sh [absent]: exits non-zero, never a silent OK"
degenerate env:ONRAMP_GATE_ROOT dir unreadable workflows/scripts/validate-onramp-anchors.sh "validate-onramp-anchors.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:ONRAMP_GATE_ROOT dir empty workflows/scripts/validate-onramp-anchors.sh "validate-onramp-anchors.sh [empty]: exits non-zero, never a silent OK"
degenerate env:DESIGN_SCHEMA_ROOT dir absent workflows/scripts/validate-design-brief.sh "validate-design-brief.sh [absent]: exits non-zero, never a silent OK"
degenerate env:DESIGN_SCHEMA_ROOT dir unreadable workflows/scripts/validate-design-brief.sh "validate-design-brief.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:DESIGN_SCHEMA_ROOT dir empty workflows/scripts/validate-design-brief.sh "validate-design-brief.sh [empty]: exits non-zero, never a silent OK"
degenerate env:COUNT_PROSE_ROOT dir absent workflows/scripts/validate-prose-budget.sh "validate-prose-budget.sh [absent]: exits non-zero, never a silent OK"
degenerate env:COUNT_PROSE_ROOT dir unreadable workflows/scripts/validate-prose-budget.sh "validate-prose-budget.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:COUNT_PROSE_ROOT dir empty workflows/scripts/validate-prose-budget.sh "validate-prose-budget.sh [empty]: exits non-zero, never a silent OK"
degenerate env:EXEC_BIT_REGISTRY_FILE file absent workflows/scripts/validate-exec-bit-registry.sh "validate-exec-bit-registry.sh [absent]: exits non-zero, never a silent OK"
degenerate env:EXEC_BIT_REGISTRY_FILE file unreadable workflows/scripts/validate-exec-bit-registry.sh "validate-exec-bit-registry.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:EXEC_BIT_REGISTRY_FILE file empty workflows/scripts/validate-exec-bit-registry.sh "validate-exec-bit-registry.sh [empty]: exits non-zero, never a silent OK"
degenerate env:CONTRIBUTOR_MANIFEST_TSV file absent workflows/scripts/config/check-contributor-manifest.sh "check-contributor-manifest.sh [absent]: exits non-zero, never a silent OK"
degenerate env:CONTRIBUTOR_MANIFEST_TSV file unreadable workflows/scripts/config/check-contributor-manifest.sh "check-contributor-manifest.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:CONTRIBUTOR_MANIFEST_TSV file empty workflows/scripts/config/check-contributor-manifest.sh "check-contributor-manifest.sh [empty]: exits non-zero, never a silent OK"
degenerate env:GATE_PATHS_FILE file absent workflows/scripts/config/check-gate-paths.sh "check-gate-paths.sh [absent]: exits non-zero, never a silent OK"
degenerate env:GATE_PATHS_FILE file unreadable workflows/scripts/config/check-gate-paths.sh "check-gate-paths.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:GATE_PATHS_FILE file empty workflows/scripts/config/check-gate-paths.sh "check-gate-paths.sh [empty]: exits non-zero, never a silent OK"
degenerate env:REDUNDANCY_FIXTURES_JSON file absent workflows/scripts/config/check-redundancy-fixtures.sh "check-redundancy-fixtures.sh [absent]: exits non-zero, never a silent OK"
degenerate env:REDUNDANCY_FIXTURES_JSON file unreadable workflows/scripts/config/check-redundancy-fixtures.sh "check-redundancy-fixtures.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:REDUNDANCY_FIXTURES_JSON file empty workflows/scripts/config/check-redundancy-fixtures.sh "check-redundancy-fixtures.sh [empty]: exits non-zero, never a silent OK"
degenerate env:REVIEWER_ROUTING_TSV file absent workflows/scripts/config/check-reviewer-routing.sh "check-reviewer-routing.sh [absent]: exits non-zero, never a silent OK"
degenerate env:REVIEWER_ROUTING_TSV file unreadable workflows/scripts/config/check-reviewer-routing.sh "check-reviewer-routing.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:REVIEWER_ROUTING_TSV file empty workflows/scripts/config/check-reviewer-routing.sh "check-reviewer-routing.sh [empty]: exits non-zero, never a silent OK"
degenerate env:SETTING_REGISTRY_SCAN_ROOT dir absent workflows/scripts/config/check-setting-registry.sh "check-setting-registry.sh [absent]: exits non-zero, never a silent OK"
degenerate env:SETTING_REGISTRY_SCAN_ROOT dir unreadable workflows/scripts/config/check-setting-registry.sh "check-setting-registry.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:SETTING_REGISTRY_SCAN_ROOT dir empty workflows/scripts/config/check-setting-registry.sh "check-setting-registry.sh [empty]: exits non-zero, never a silent OK"
degenerate env:KERNEL_MANIFEST_FILE file absent workflows/scripts/kernel/check-kernel-manifest.sh "check-kernel-manifest.sh [absent]: exits non-zero, never a silent OK"
degenerate env:KERNEL_MANIFEST_FILE file unreadable workflows/scripts/kernel/check-kernel-manifest.sh "check-kernel-manifest.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:KERNEL_MANIFEST_FILE file empty workflows/scripts/kernel/check-kernel-manifest.sh "check-kernel-manifest.sh [empty]: exits non-zero, never a silent OK"
degenerate env:KERNEL_DENYLIST_FILE file absent workflows/scripts/kernel/check-personal-token-denylist.sh "check-personal-token-denylist.sh [absent]: exits non-zero, never a silent OK"
degenerate env:KERNEL_DENYLIST_FILE file unreadable workflows/scripts/kernel/check-personal-token-denylist.sh "check-personal-token-denylist.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:KERNEL_DENYLIST_FILE file empty workflows/scripts/kernel/check-personal-token-denylist.sh "check-personal-token-denylist.sh [empty]: exits non-zero, never a silent OK"
degenerate env:PRERENAME_VERDICTS_FILE file absent workflows/scripts/kernel/check-prerename-leak-guard.sh "check-prerename-leak-guard.sh [absent]: exits non-zero, never a silent OK"
degenerate env:PRERENAME_VERDICTS_FILE file unreadable workflows/scripts/kernel/check-prerename-leak-guard.sh "check-prerename-leak-guard.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:PRERENAME_VERDICTS_FILE file empty workflows/scripts/kernel/check-prerename-leak-guard.sh "check-prerename-leak-guard.sh [empty]: exits non-zero, never a silent OK"
degenerate env:TERMINOLOGY_LEAK_SCAN_ROOT dir absent workflows/scripts/kernel/check-terminology-leak-guard.sh "check-terminology-leak-guard.sh [absent]: exits non-zero, never a silent OK"
degenerate env:TERMINOLOGY_LEAK_SCAN_ROOT dir unreadable workflows/scripts/kernel/check-terminology-leak-guard.sh "check-terminology-leak-guard.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:TERMINOLOGY_LEAK_SCAN_ROOT dir empty workflows/scripts/kernel/check-terminology-leak-guard.sh "check-terminology-leak-guard.sh [empty]: exits non-zero, never a silent OK"
degenerate env:KERNEL_DENYLIST_FILE file absent workflows/scripts/kernel/check-pr-leak-guard.sh "check-pr-leak-guard.sh [absent]: exits non-zero, never a silent OK"
degenerate env:KERNEL_DENYLIST_FILE file unreadable workflows/scripts/kernel/check-pr-leak-guard.sh "check-pr-leak-guard.sh [unreadable]: exits non-zero, never a silent OK"
degenerate env:KERNEL_DENYLIST_FILE file empty workflows/scripts/kernel/check-pr-leak-guard.sh "check-pr-leak-guard.sh [empty]: exits non-zero, never a silent OK"
degenerate arg file absent workflows/scripts/lint-pr-body.sh "lint-pr-body.sh [absent]: exits non-zero, never a silent OK"
degenerate arg file unreadable workflows/scripts/lint-pr-body.sh "lint-pr-body.sh [unreadable]: exits non-zero, never a silent OK"
degenerate arg file empty workflows/scripts/lint-pr-body.sh "lint-pr-body.sh [empty]: exits non-zero under --require-verification, never a silent OK" --require-verification

# ---------------------------------------------------------------------------
# Negative control (see the header): lint-pr-body.sh in its DEFAULT mode
# accepts an empty body — there is no issue-linkage error to find in one — so
# the same runner that reports non-zero for all 51 degenerate cases above
# must report 0 here. This is also the measured reason lint-pr-body.sh's own
# `empty` row is registered under --require-verification rather than in the
# default mode: only that mode makes an empty body a failure.
# ---------------------------------------------------------------------------
CONTROL_BODY="$WORK/control-body.md"
: >"$CONTROL_BODY"
control arg workflows/scripts/lint-pr-body.sh \
  "control: lint-pr-body.sh in DEFAULT mode exits 0 on an empty body (the runner discriminates)" \
  "$CONTROL_BODY"

echo
if [ "$pass" -ne "$total" ]; then
  printf 'test_check_surface_degenerate_backfill: FAILED %d of %d\n' "$((total - pass))" "$total"
  exit 1
fi
printf 'test_check_surface_degenerate_backfill: OK — all %d checks passed\n' "$pass"
