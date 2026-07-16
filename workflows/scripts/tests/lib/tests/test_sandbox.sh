#!/usr/bin/env bash
#
# Tests for workflows/scripts/tests/lib/sandbox.sh — the reusable hermetic
# env-sandbox test harness (temperloop#263, "sandbox-core", ADR K164 D6).
#
# Covers:
#   1. sandbox_run scopes HOME/XDG_*/PATH to the invoked subprocess only —
#      the calling shell's own $HOME is provably unchanged before/after, the
#      subprocess sees the sandboxed values, and a bash temporary-assignment
#      prefix (e.g. FAKE_PR_STATE=OPEN) flows through to a grandchild
#      process without persisting in the caller.
#   2. sandbox_stub_gh: the installed fake logs every call and honors a
#      FAKE_* steering var (FAKE_AUTH_RC).
#   3. sandbox_bash runs a multi-statement inline script with the sandbox
#      env applied.
#   4. sandbox_bootstrap_checkout: bootstraps THIS repo (its own committed
#      HEAD) over a file:// remote, produces a working `temperloop` binary
#      inside the sandbox that lists its real subcommands.
#   5. No-residue: a full bootstrap+dispatch cycle never touches the paths
#      a REAL (unsandboxed) run would have written to under the real HOME,
#      and sandbox_down removes the throwaway root entirely.
#
# No network. No real HOME/XDG mutations at any point.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../../.." && pwd)"
# shellcheck source=workflows/scripts/tests/lib/sandbox.sh
source "$HERE/../sandbox.sh"

# Kernel-only: test 4 bootstraps this repo from bin/bootstrap.sh, which exists
# only when the repo root IS the kernel. Tests 1-3 would pass in a composed
# tree, but this suite tests the kernel's own lib and the kernel's CI is where
# that coverage lives — skipping whole-suite matches #267's precedent rather
# than inventing per-leg skipping. (#363)
sandbox_skip_if_composed_tree "test_sandbox.sh" "$REPO_ROOT"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

# =============================================================================
# 1. env scoping: caller shell untouched; subprocess sees sandboxed values;
#    a temporary-assignment prefix reaches a grandchild without persisting.
# =============================================================================
REAL_HOME_BEFORE="$HOME"

sandbox_up test-sandbox-1

# shellcheck disable=SC2016  # deliberately single-quoted: $HOME must expand
# INSIDE the sandboxed subprocess, not in this (unsandboxed) caller shell.
child_home="$(sandbox_run bash -c 'echo "$HOME"')"
[ "$child_home" = "$SANDBOX_HOME" ] || fail "1: subprocess did not see sandboxed HOME (got: $child_home, want: $SANDBOX_HOME)"

# shellcheck disable=SC2016  # same as above — expand inside the subprocess
child_xdg="$(sandbox_run bash -c 'printf "%s %s %s %s" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"')"
[ "$child_xdg" = "$SANDBOX_XDG_CONFIG_HOME $SANDBOX_XDG_STATE_HOME $SANDBOX_XDG_DATA_HOME $SANDBOX_XDG_CACHE_HOME" ] \
  || fail "1: subprocess did not see all four sandboxed XDG vars (got: $child_xdg)"

[ "$HOME" = "$REAL_HOME_BEFORE" ] || fail "1: calling shell's own \$HOME changed after sandbox_run (got: $HOME, want: $REAL_HOME_BEFORE)"

# a temporary-assignment prefix on the sandbox_run call reaches the
# grandchild process, and does not leak into the caller afterward
# shellcheck disable=SC2016  # deliberately single-quoted (see above)
grandchild_seen="$(MARKER_VAR=hello sandbox_run bash -c 'bash -c "echo \$MARKER_VAR"')"
[ "$grandchild_seen" = "hello" ] || fail "1: temporary-assignment prefix did not reach the grandchild process (got: $grandchild_seen)"
[ -z "${MARKER_VAR:-}" ] || fail "1: MARKER_VAR leaked into the caller's own shell (got: $MARKER_VAR)"

sandbox_down
pass "1: sandbox_run scopes HOME/XDG_*/PATH (and any temporary-assignment prefix) to the invoked subprocess tree only, never the caller's shell"

# =============================================================================
# 2. sandbox_stub_gh: logs every call, honors FAKE_AUTH_RC
# =============================================================================
sandbox_up test-sandbox-2
sandbox_stub_gh

sandbox_run gh issue list --repo acme/widget >/dev/null 2>&1 || true
grep -q "issue list --repo acme/widget" "$SANDBOX_GH_CALL_LOG" \
  || fail "2: fake gh did not log its call (log: $(cat "$SANDBOX_GH_CALL_LOG"))"

rc=0
FAKE_AUTH_RC=7 sandbox_run gh auth status >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 7 ] || fail "2: FAKE_AUTH_RC steering did not propagate (expected exit 7, got $rc)"

sandbox_down
pass "2: sandbox_stub_gh logs every call and honors FAKE_* steering vars"

# =============================================================================
# 3. sandbox_bash: inline multi-statement script under the sandbox env
# =============================================================================
sandbox_up test-sandbox-3
# shellcheck disable=SC2016  # deliberately single-quoted (see test 1's note)
out="$(sandbox_bash '[ -n "$HOME" ] && [ "$HOME" != "'"$REAL_HOME_BEFORE"'" ] && echo scoped-ok')"
[ "$out" = "scoped-ok" ] || fail "3: sandbox_bash did not run with the sandboxed HOME applied (got: $out)"
sandbox_down
pass "3: sandbox_bash runs an inline script with the sandbox env applied"

# =============================================================================
# 4. sandbox_bootstrap_checkout: bootstraps THIS repo over file://, produces
#    a working temperloop binary that lists real subcommands
# =============================================================================
sandbox_up test-sandbox-4
sandbox_stub_gh
sandbox_stub_claude

sandbox_bootstrap_checkout "$REPO_ROOT" \
  || fail "4: sandbox_bootstrap_checkout failed"
[ -n "${SANDBOX_TEMPERLOOP:-}" ] || fail "4: SANDBOX_TEMPERLOOP was not set"
[ -x "$SANDBOX_TEMPERLOOP" ] || fail "4: SANDBOX_TEMPERLOOP ($SANDBOX_TEMPERLOOP) is not executable"

help_out="$(sandbox_run "$SANDBOX_TEMPERLOOP" help 2>&1)" || fail "4: bootstrapped temperloop help exited non-zero (output: $help_out)"
echo "$help_out" | grep -q "init " || fail "4: bootstrapped temperloop help did not list the 'init' subcommand (output: $help_out)"
echo "$help_out" | grep -q "eject " || fail "4: bootstrapped temperloop help did not list the 'eject' subcommand (output: $help_out)"

sandbox_down
pass "4: sandbox_bootstrap_checkout bare-clones this repo over file:// and produces a working temperloop binary"

# =============================================================================
# 5. No-residue: a full bootstrap+dispatch cycle never touches the real-HOME
#    paths an unsandboxed run would have written to; sandbox_down removes
#    the throwaway root entirely.
# =============================================================================
snapshot_path() {
  # snapshot_path PATH — "absent" if it doesn't exist, else "present:<n>"
  # where <n> is a portable file-count fingerprint (no stat flags, works on
  # both BSD/macOS and GNU find).
  #
  # The basic-memory knowledge store (F#946) lives under
  # ~/.local/state/foundation/{basic-memory-home,bm-*} and is LIVE, concurrently
  # written runtime state — churned on-demand by ks_search / the
  # CLAUDE.kernel.md § Phase-1 parity `bm` leg from any other session or hook,
  # with hundreds of files created inside a single test window. It is NOT the
  # bootstrap residue this guard looks for, so counting it makes test 5 flake on
  # unrelated concurrent bm activity (temperloop#377). Prune the bm subtrees:
  #   - by directory NAME — the bm dirs only ever appear under
  #     .local/state/foundation, so a global name-prune cannot hide bootstrap
  #     residue leaked into any other REAL_CANDIDATE path;
  #   - via -prune, so the 400k+-file store is never descended (fast, and the
  #     count stays a leak-detector, not a store-size measurement).
  local p="$1"
  if [ -e "$p" ]; then
    printf 'present:%s' "$(find "$p" \( -name basic-memory-home -o -name 'bm-*' \) -prune -o -print 2>/dev/null | wc -l | tr -d ' ')"
  else
    printf 'absent'
  fi
}

# The exact real-HOME paths bin/bootstrap.sh / init.sh / eject.sh would
# write to if HOME/XDG_* were NOT re-pointed (bin/bootstrap.sh's own
# FOUNDATION_HOME/FOUNDATION_BIN_DIR defaults + the CLI's own
# XDG_CONFIG_HOME/XDG_STATE_HOME dismiss-state paths).
REAL_CANDIDATES=(
  "$REAL_HOME_BEFORE/.local/share/temperloop"
  "$REAL_HOME_BEFORE/.local/bin/temperloop"
  "$REAL_HOME_BEFORE/.local/bin/foundation"
  "$REAL_HOME_BEFORE/.config/foundation"
  "$REAL_HOME_BEFORE/.cache/temperloop"
  "$REAL_HOME_BEFORE/.local/state/foundation"
)
snaps_before=()
for p in "${REAL_CANDIDATES[@]}"; do
  snaps_before+=("$(snapshot_path "$p")")
done

sandbox_up test-sandbox-5
sandbox_stub_gh
sandbox_stub_claude
sandbox_bootstrap_checkout "$REPO_ROOT" || fail "5: sandbox_bootstrap_checkout failed"
sandbox_run "$SANDBOX_TEMPERLOOP" help >/dev/null 2>&1 || fail "5: dispatch through the bootstrapped CLI failed"
sandbox_root_snapshot="$SANDBOX_ROOT"
sandbox_down

[ ! -e "$sandbox_root_snapshot" ] || fail "5: sandbox_down did not remove the throwaway root ($sandbox_root_snapshot still exists)"

i=0
for p in "${REAL_CANDIDATES[@]}"; do
  after="$(snapshot_path "$p")"
  [ "$after" = "${snaps_before[$i]}" ] \
    || fail "5: real-HOME path changed during a sandboxed run: $p (before: ${snaps_before[$i]}, after: $after)"
  i=$((i + 1))
done

[ "$HOME" = "$REAL_HOME_BEFORE" ] || fail "5: caller's own \$HOME changed after the sandboxed cycle (got: $HOME)"

pass "5: a full bootstrap+dispatch cycle leaves every real-HOME candidate path unchanged, and sandbox_down removes the throwaway root entirely"

echo
echo "ALL PASS: test_sandbox.sh"
