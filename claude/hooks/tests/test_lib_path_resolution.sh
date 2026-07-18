#!/usr/bin/env bash
# Tests for the KS_LIB_DIR resolution shared by session-start-drain.sh and
# mcp-health-preflight.sh (temperloop#406 — no shipped hook may default its
# knowledge_store.sh lookup to a hardcoded personal dev-checkout path;
# resolution must land relative to the INSTALLED checkout instead, with
# KS_LIB_DIR staying the highest-precedence override).
#
# Every case builds a throwaway "fresh install" fixture tree —
#   <fixture>/claude/hooks/{session-start-drain.sh,mcp-health-preflight.sh,eval-guard.sh}
#   <fixture>/workflows/scripts/lib/{knowledge_store.sh,knowledge_store_obsidian.sh}
# — mirroring exactly the two-directories-up layout
# workflows/scripts/install/links.sh produces (the whole claude/hooks/
# directory symlinked into ~/.claude/hooks, per that script's own doc). The
# stub lib files are NOT the real knowledge_store.sh; they just append a
# marker line to a log when sourced, so this suite can prove WHICH lib dir a
# hook actually reached without needing a real Obsidian vault or network.
#
# $HOME is pointed at an empty sandbox dir for every case below — critically,
# one with NO personal dev-checkout subdirectory at all — so a hook that
# still fell back to the old hardcoded per-operator default would find
# nothing there and FAIL to source the fixture's stub lib, catching a
# regression back to the pre-#406 behavior.
#
# Covers:
#   1. session-start-drain.sh resolves KS_LIB_DIR relative to the fixture
#      checkout (BASH_SOURCE-relative), with no KS_LIB_DIR env var set and
#      no personal dev-checkout path present.
#   2. mcp-health-preflight.sh does the same.
#   3. KS_LIB_DIR env override still wins over the relative resolution, for
#      both hooks (highest-precedence contract, unchanged by #406).
#   4. fail-open / inert: a hooks-only-vendor fixture (hook + eval-guard.sh,
#      but no workflows/scripts/lib/ at all two directories up) leaves both
#      hooks exiting 0 with no marker written — never a hard failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$HERE/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-lib-path-resolution-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  \xe2\x9c\x93 %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \xe2\x9c\x97 %s\n' "$1"; }

# make_fixture <dir> — a fresh-install-shaped fixture with real hooks plus
# stub lib files that mark themselves as sourced.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir/claude/hooks" "$dir/workflows/scripts/lib"
  cp "$HOOKS_DIR/session-start-drain.sh" "$dir/claude/hooks/"
  cp "$HOOKS_DIR/mcp-health-preflight.sh" "$dir/claude/hooks/"
  cp "$HOOKS_DIR/eval-guard.sh" "$dir/claude/hooks/"
  chmod +x "$dir/claude/hooks/"*.sh
  cat > "$dir/workflows/scripts/lib/knowledge_store.sh" <<EOF
printf 'sourced:knowledge_store.sh:%s\n' "$dir" >> "\$MARKER_LOG"
EOF
  cat > "$dir/workflows/scripts/lib/knowledge_store_obsidian.sh" <<EOF
printf 'sourced:knowledge_store_obsidian.sh:%s\n' "$dir" >> "\$MARKER_LOG"
EOF
}

# run_hook <fixture-dir> <hook-file> [env NAME=VAL...] -- runs the hook with
# a fresh sandbox HOME (no personal dev-checkout dir) and minimal
# SessionStart stdin.
run_hook() {
  local dir="$1" hook="$2"; shift 2
  local fake_home="$TMP/fake-home-$$-$RANDOM"
  mkdir -p "$fake_home"
  printf '{}' | env HOME="$fake_home" XDG_STATE_HOME="$TMP/xdg-state" "$@" \
    bash "$dir/claude/hooks/$hook" >/dev/null 2>"$TMP/stderr.$$"
  return $?
}

# ---------------------------------------------------------------------------
# 1 & 2. Fresh-install fixture: script-relative resolution, no KS_LIB_DIR,
#        no personal dev-checkout dir anywhere in the fake HOME.
# ---------------------------------------------------------------------------
FIXTURE1="$TMP/fresh-install"
make_fixture "$FIXTURE1"
MARKER1="$TMP/marker1.log"
: > "$MARKER1"

run_hook "$FIXTURE1" session-start-drain.sh MARKER_LOG="$MARKER1" KS_LIB_DIR=
rc=$?
if [ "$rc" -eq 0 ] && grep -q "sourced:knowledge_store.sh:$FIXTURE1" "$MARKER1" \
    && grep -q "sourced:knowledge_store_obsidian.sh:$FIXTURE1" "$MARKER1"; then
  ok "session-start-drain.sh: KS_LIB_DIR unset -> resolves to the fixture checkout's own lib dir (no personal dev-checkout path)"
else
  bad "session-start-drain.sh: script-relative resolution failed (rc=$rc, marker=$(cat "$MARKER1" 2>/dev/null))"
fi

MARKER2="$TMP/marker2.log"
: > "$MARKER2"
run_hook "$FIXTURE1" mcp-health-preflight.sh MARKER_LOG="$MARKER2" KS_LIB_DIR=
rc=$?
if [ "$rc" -eq 0 ] && grep -q "sourced:knowledge_store.sh:$FIXTURE1" "$MARKER2" \
    && grep -q "sourced:knowledge_store_obsidian.sh:$FIXTURE1" "$MARKER2"; then
  ok "mcp-health-preflight.sh: KS_LIB_DIR unset -> resolves to the fixture checkout's own lib dir (no personal dev-checkout path)"
else
  bad "mcp-health-preflight.sh: script-relative resolution failed (rc=$rc, marker=$(cat "$MARKER2" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
# 3. KS_LIB_DIR env override still wins over the relative resolution.
# ---------------------------------------------------------------------------
FIXTURE_OVERRIDE="$TMP/override-lib"
mkdir -p "$FIXTURE_OVERRIDE"
MARKER3="$TMP/marker3.log"
: > "$MARKER3"
cat > "$FIXTURE_OVERRIDE/knowledge_store.sh" <<EOF
printf 'sourced:knowledge_store.sh:%s\n' "$FIXTURE_OVERRIDE" >> "\$MARKER_LOG"
EOF
cat > "$FIXTURE_OVERRIDE/knowledge_store_obsidian.sh" <<EOF
printf 'sourced:knowledge_store_obsidian.sh:%s\n' "$FIXTURE_OVERRIDE" >> "\$MARKER_LOG"
EOF

run_hook "$FIXTURE1" session-start-drain.sh MARKER_LOG="$MARKER3" KS_LIB_DIR="$FIXTURE_OVERRIDE"
rc=$?
if [ "$rc" -eq 0 ] && grep -q "sourced:knowledge_store.sh:$FIXTURE_OVERRIDE" "$MARKER3" \
    && ! grep -q "$FIXTURE1" "$MARKER3"; then
  ok "session-start-drain.sh: KS_LIB_DIR env override still takes precedence over the fixture-relative lib dir"
else
  bad "session-start-drain.sh: KS_LIB_DIR override was not honored (rc=$rc, marker=$(cat "$MARKER3" 2>/dev/null))"
fi

MARKER4="$TMP/marker4.log"
: > "$MARKER4"
run_hook "$FIXTURE1" mcp-health-preflight.sh MARKER_LOG="$MARKER4" KS_LIB_DIR="$FIXTURE_OVERRIDE"
rc=$?
if [ "$rc" -eq 0 ] && grep -q "sourced:knowledge_store.sh:$FIXTURE_OVERRIDE" "$MARKER4" \
    && ! grep -q "$FIXTURE1" "$MARKER4"; then
  ok "mcp-health-preflight.sh: KS_LIB_DIR env override still takes precedence over the fixture-relative lib dir"
else
  bad "mcp-health-preflight.sh: KS_LIB_DIR override was not honored (rc=$rc, marker=$(cat "$MARKER4" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
# 4. fail-open / inert: hooks-only-vendor fixture, no workflows/scripts/lib/
#    at all. Both hooks must exit 0 and write no marker.
# ---------------------------------------------------------------------------
FIXTURE_BARE="$TMP/hooks-only-vendor"
mkdir -p "$FIXTURE_BARE/claude/hooks"
cp "$HOOKS_DIR/session-start-drain.sh" "$FIXTURE_BARE/claude/hooks/"
cp "$HOOKS_DIR/mcp-health-preflight.sh" "$FIXTURE_BARE/claude/hooks/"
cp "$HOOKS_DIR/eval-guard.sh" "$FIXTURE_BARE/claude/hooks/"
chmod +x "$FIXTURE_BARE/claude/hooks/"*.sh

MARKER5="$TMP/marker5.log"
run_hook "$FIXTURE_BARE" session-start-drain.sh MARKER_LOG="$MARKER5" KS_LIB_DIR=
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$MARKER5" ]; then
  ok "session-start-drain.sh: no workflows/scripts/lib/ reachable -> inert (fail-open), exit 0, no marker"
else
  bad "session-start-drain.sh: hooks-only-vendor fixture: rc=$rc marker-exists=$([ -s "$MARKER5" ] && echo yes || echo no)"
fi

MARKER6="$TMP/marker6.log"
run_hook "$FIXTURE_BARE" mcp-health-preflight.sh MARKER_LOG="$MARKER6" KS_LIB_DIR=
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$MARKER6" ]; then
  ok "mcp-health-preflight.sh: no workflows/scripts/lib/ reachable -> inert (fail-open), exit 0, no marker"
else
  bad "mcp-health-preflight.sh: hooks-only-vendor fixture: rc=$rc marker-exists=$([ -s "$MARKER6" ] && echo yes || echo no)"
fi

echo
echo "test_lib_path_resolution.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
