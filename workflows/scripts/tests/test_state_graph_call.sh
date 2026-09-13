#!/usr/bin/env bash
#
# test_state_graph_call.sh — tests for
# workflows/scripts/validate-state-graph-call.sh (temperloop#1910 L6): the
# presence-lint for /build Step 0.5's state-graph cross-check call. Mirrors
# test_resume_recovery_emit.sh § 10's fixture shape (a disposable copy of the
# real tree, tampered one way at a time) applied to this validator's own
# three degenerate-input cases (check-surface-registry.tsv: absent /
# unreadable / empty) — never tampering the live tree directly.
#
# Zero network; writes only under a throwaway tmpdir.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../../.." && pwd)"
LINT="$REPO/workflows/scripts/validate-state-graph-call.sh"
STATE_GRAPH="$REPO/workflows/scripts/build/state-graph.sh"
BUILD_MD="$REPO/claude/commands/build.md"

[ -f "$LINT" ] || { echo "FATAL: validate-state-graph-call.sh not found at $LINT" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/state-graph-call-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
check() { # <desc> <cmd...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d" "command failed: $*"; fi
}

echo "── 1. the presence-lint passes on the real tree ──"
check "validate-state-graph-call.sh passes on the real tree" bash "$LINT"

echo "── 2. build a disposable fixture copy, green before tampering ──"
FIXR="$TMP/fixture"
mkdir -p "$FIXR/workflows/scripts/build" "$FIXR/claude/commands"
cp "$STATE_GRAPH" "$FIXR/workflows/scripts/build/state-graph.sh"
cp "$LINT" "$FIXR/workflows/scripts/validate-state-graph-call.sh"
chmod +x "$FIXR/workflows/scripts/"*.sh "$FIXR/workflows/scripts/build/"*.sh
cp "$BUILD_MD" "$FIXR/claude/commands/build.md"
check "the fixture copy is green before tampering" bash "$FIXR/workflows/scripts/validate-state-graph-call.sh"

echo "── 3. CASE=empty: build.md drops the 'state-graph.sh build' call ──"
grep -v 'state-graph.sh build' "$BUILD_MD" > "$FIXR/claude/commands/build.md.tmp" \
  && mv "$FIXR/claude/commands/build.md.tmp" "$FIXR/claude/commands/build.md"
if bash "$FIXR/workflows/scripts/validate-state-graph-call.sh" >"$TMP/lint1.out" 2>&1; then
  bad "lint fails when build.md drops the 'state-graph.sh build' call" "lint passed on a tampered doc"
else
  ok "lint fails when build.md drops the 'state-graph.sh build' call"
fi
check "...and names the removed build wiring" grep -Fq "no longer invokes 'state-graph.sh build'" "$TMP/lint1.out"

echo "── 4. CASE=empty: build.md drops the 'state-graph.sh query resume' call ──"
cp "$BUILD_MD" "$FIXR/claude/commands/build.md"
grep -v 'state-graph.sh query resume' "$BUILD_MD" > "$FIXR/claude/commands/build.md.tmp" \
  && mv "$FIXR/claude/commands/build.md.tmp" "$FIXR/claude/commands/build.md"
if bash "$FIXR/workflows/scripts/validate-state-graph-call.sh" >"$TMP/lint2.out" 2>&1; then
  bad "lint fails when build.md drops the 'state-graph.sh query resume' call" "lint passed on a tampered doc"
else
  ok "lint fails when build.md drops the 'state-graph.sh query resume' call"
fi
check "...and names the removed query wiring" grep -Fq "no longer invokes 'state-graph.sh query resume'" "$TMP/lint2.out"

echo "── 5. CASE=absent: state-graph.sh itself is missing ──"
cp "$BUILD_MD" "$FIXR/claude/commands/build.md"
rm -f "$FIXR/workflows/scripts/build/state-graph.sh"
if bash "$FIXR/workflows/scripts/validate-state-graph-call.sh" >"$TMP/lint3.out" 2>&1; then
  bad "lint fails when state-graph.sh is missing" "lint passed"
else
  ok "lint fails when state-graph.sh is missing"
fi
check "...and names the missing script" grep -Fq 'is missing' "$TMP/lint3.out"

echo "── 6. CASE=unreadable: state-graph.sh lost its executable bit ──"
cp "$STATE_GRAPH" "$FIXR/workflows/scripts/build/state-graph.sh"
chmod -x "$FIXR/workflows/scripts/build/state-graph.sh"
if bash "$FIXR/workflows/scripts/validate-state-graph-call.sh" >"$TMP/lint4.out" 2>&1; then
  bad "lint fails when state-graph.sh lost its executable bit" "lint passed"
else
  ok "lint fails when state-graph.sh lost its executable bit"
fi
check "...and names the non-executable script" grep -Fq 'not executable' "$TMP/lint4.out"

echo
echo "state-graph-call: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
