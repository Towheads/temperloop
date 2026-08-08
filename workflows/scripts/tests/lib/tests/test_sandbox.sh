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
#      and sandbox_down removes the throwaway root entirely — asserted with
#      a CONTINUOUS third-party writer active against the real cache store
#      root, so the leg cannot pass merely because nothing was writing.
#   6. Public-knob pins: inside the sandbox, CACHE_STORE_ROOT /
#      TEMPERLOOP_HOME / TEMPERLOOP_BIN_DIR each resolve under $SANDBOX_ROOT
#      even when the caller exports a real-machine value for them — plus the
#      guard-not-weakened counter-check, that a deliberate leak to a
#      still-sampled candidate is still caught with the same message.
#
# No network. The ONLY real-machine writes are test 5's interferer markers
# under the real cache store root — pid-namespaced, and removed (along with
# the root itself if this run created it) by sandbox_cache_interferer_stop,
# which is wired onto an EXIT trap. No real HOME/XDG mutations otherwise.
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
grep -q "init " <<<"$help_out" || fail "4: bootstrapped temperloop help did not list the 'init' subcommand (output: $help_out)"
grep -q "eject " <<<"$help_out" || fail "4: bootstrapped temperloop help did not list the 'eject' subcommand (output: $help_out)"

sandbox_down
pass "4: sandbox_bootstrap_checkout bare-clones this repo over file:// and produces a working temperloop binary"

# =============================================================================
# 5. No-residue: a full bootstrap+dispatch cycle never touches the real-HOME
#    paths an unsandboxed run would have written to; sandbox_down removes
#    the throwaway root entirely.
# =============================================================================
# snapshot_path and the candidate list now live in sandbox.sh
# (sandbox_snapshot_path / sandbox_real_candidates, temperloop#1154) —
# they were duplicated here and in the sibling
# workflows/scripts/tests/test_sandbox_dry_run_legs.sh, which is how #377's
# bm-prune fix had to be re-made as #382. One definition, sourced by both.
sandbox_real_candidates "$REAL_HOME_BEFORE"

# A CONTINUOUS third-party writer against the REAL cache store root, live for
# the whole of assertion 5. Without it this leg passes vacuously: the real
# cache root was dropped from the sampled candidate set precisely because a
# concurrent board-adapter process writes it, and only an actual concurrent
# writer can demonstrate that the assertion now survives one.
trap 'sandbox_cache_interferer_stop' EXIT
sandbox_cache_interferer_start || fail "5: could not start the cache-root interferer"

sandbox_snapshot_real_candidates

sandbox_up test-sandbox-5
sandbox_stub_gh
sandbox_stub_claude
sandbox_bootstrap_checkout "$REPO_ROOT" || fail "5: sandbox_bootstrap_checkout failed"
sandbox_run "$SANDBOX_TEMPERLOOP" help >/dev/null 2>&1 || fail "5: dispatch through the bootstrapped CLI failed"
sandbox_root_snapshot="$SANDBOX_ROOT"
sandbox_down

[ ! -e "$sandbox_root_snapshot" ] || fail "5: sandbox_down did not remove the throwaway root ($sandbox_root_snapshot still exists)"

drift="$(sandbox_diff_real_candidates)" || fail "5: $drift"

# Non-vacuity: prove the interferer really was writing the real cache store
# root, concurrently, for the duration of the assertion above. Asserted
# BEFORE stopping it — the stop removes its markers.
interferer_writes="$(sandbox_cache_interferer_count)"
[ "$interferer_writes" -ge 2 ] \
  || fail "5: the third-party cache-root interferer laid down only $interferer_writes marker(s) — assertion 5 did not actually run against a concurrent writer"
sandbox_cache_interferer_stop
trap - EXIT

[ "$HOME" = "$REAL_HOME_BEFORE" ] || fail "5: caller's own \$HOME changed after the sandboxed cycle (got: $HOME)"

pass "5: a full bootstrap+dispatch cycle leaves every real-HOME candidate path unchanged — even with a concurrent third-party writer ($interferer_writes writes) active against the real cache store root — and sandbox_down removes the throwaway root entirely"

# =============================================================================
# 6. Public-knob pins (temperloop#1154), two halves:
#    (a) POSITIVE — inside the sandbox, CACHE_STORE_ROOT / TEMPERLOOP_HOME /
#        TEMPERLOOP_BIN_DIR each resolve under $SANDBOX_ROOT even when the
#        caller exports a real-machine value for them. This is a test of the
#        redirect MECHANISM, not absence-sampling: it is what licenses test 5
#        to stop counting the real cache root.
#    (b) NEGATIVE — the guard is NOT weakened: a deliberate leak from a
#        sandboxed run into a still-sampled candidate is still caught, by the
#        same code path and with the same failure message. Run against a
#        SYNTHETIC candidate root (sandbox_real_candidates takes the home
#        root as an argument) so proving the guard fires costs no write to
#        the operator's actual HOME.
# =============================================================================
sandbox_up test-sandbox-6

# The leak vectors, each pointed at a real-machine path a leaked value would
# steer a sandboxed write to. Exported deliberately — this is exactly the
# shape links_provision_cache_stores' `mkdir -p "$store_root"` and
# bin/bootstrap.sh's install step would act on.
export CACHE_STORE_ROOT="$REAL_HOME_BEFORE/.cache/temperloop"
export TEMPERLOOP_HOME="$REAL_HOME_BEFORE/.local/share/temperloop"
export TEMPERLOOP_BIN_DIR="$REAL_HOME_BEFORE/.local/bin"

# shellcheck disable=SC2016  # deliberately single-quoted (see test 1's note)
pinned="$(sandbox_run bash -c 'printf "%s\n%s\n%s\n" "$CACHE_STORE_ROOT" "$TEMPERLOOP_HOME" "$TEMPERLOOP_BIN_DIR"')"
knob_i=0
while IFS= read -r seen; do
  knob_i=$((knob_i + 1))
  case "$seen" in
    "$SANDBOX_ROOT"/*) : ;;
    *) fail "6a: knob #$knob_i resolved OUTSIDE the sandbox root inside a sandboxed run (got: $seen, want a path under $SANDBOX_ROOT)" ;;
  esac
done <<<"$pinned"
[ "$knob_i" -eq 3 ] || fail "6a: expected 3 pinned knob values, got $knob_i"

# The pins are values, not just prefixes — each must be the sandbox's own
# derivation of that knob, so a sandboxed consumer lands where the sandbox
# expects rather than at some other in-sandbox path.
[ "$(sed -n 1p <<<"$pinned")" = "$SANDBOX_CACHE_STORE_ROOT" ] \
  || fail "6a: CACHE_STORE_ROOT pinned to the wrong in-sandbox path (got: $(sed -n 1p <<<"$pinned"), want: $SANDBOX_CACHE_STORE_ROOT)"
[ "$(sed -n 2p <<<"$pinned")" = "$SANDBOX_TEMPERLOOP_HOME" ] \
  || fail "6a: TEMPERLOOP_HOME pinned to the wrong in-sandbox path (got: $(sed -n 2p <<<"$pinned"), want: $SANDBOX_TEMPERLOOP_HOME)"
[ "$(sed -n 3p <<<"$pinned")" = "$SANDBOX_TEMPERLOOP_BIN_DIR" ] \
  || fail "6a: TEMPERLOOP_BIN_DIR pinned to the wrong in-sandbox path (got: $(sed -n 3p <<<"$pinned"), want: $SANDBOX_TEMPERLOOP_BIN_DIR)"

# An IN-sandbox steer must still win — the documented temporary-assignment
# seam bin/subcommands/tests/test_uninstall.sh test 7 uses. A pin that
# clobbered this would be an over-correction, not a fix.
in_sandbox_steer="$SANDBOX_ROOT/custom-cache-root"
# shellcheck disable=SC2016  # deliberately single-quoted (see test 1's note)
steered="$(CACHE_STORE_ROOT="$in_sandbox_steer" sandbox_run bash -c 'printf "%s" "$CACHE_STORE_ROOT"')"
[ "$steered" = "$in_sandbox_steer" ] \
  || fail "6a: an in-sandbox CACHE_STORE_ROOT steer was clobbered by the pin (got: $steered, want: $in_sandbox_steer)"

unset CACHE_STORE_ROOT TEMPERLOOP_HOME TEMPERLOOP_BIN_DIR
pass "6a: CACHE_STORE_ROOT / TEMPERLOOP_HOME / TEMPERLOOP_BIN_DIR are pinned inside \$SANDBOX_ROOT even when the caller exports real-machine values, while an in-sandbox steer still wins"

# --- 6b: guard-not-weakened counter-check ----------------------------------
FAKE_REAL_HOME="$SANDBOX_ROOT/fake-real-home"
mkdir -p "$FAKE_REAL_HOME"
sandbox_real_candidates "$FAKE_REAL_HOME"
sandbox_snapshot_real_candidates

# A deliberate leak: a sandboxed run writing an ABSOLUTE path that lands in a
# still-sampled candidate (.config/foundation). Nothing in the isolation
# model prevents an absolute-path write — detecting it is the guard's whole
# job, and this is the assertion that the removal of the cache-root entry
# did not quietly disarm it.
sandbox_run bash -c 'mkdir -p "$1" && : > "$1/leaked"' sandbox-leak "$FAKE_REAL_HOME/.config/foundation" \
  || fail "6b: setup — the deliberate leak write itself failed"

leak_msg="$(sandbox_diff_real_candidates)" && fail "6b: the guard did NOT catch a deliberate leak into a still-sampled candidate"
grep -F "real-HOME path changed during a sandboxed run: $FAKE_REAL_HOME/.config/foundation" <<<"$leak_msg" >/dev/null \
  || fail "6b: the guard fired but not with the expected failure message (got: $leak_msg)"
grep -E 'before: absent, after: present:[0-9]+' <<<"$leak_msg" >/dev/null \
  || fail "6b: the failure message lost its before/after fingerprint detail (got: $leak_msg)"

sandbox_down
# Restore the real candidate set — nothing runs after this today, but leaving
# a synthetic set installed would silently defang any later leg.
sandbox_real_candidates "$REAL_HOME_BEFORE"
pass "6b: a deliberate leak from a sandboxed run into a still-sampled real-HOME candidate is still caught, with the same failure message"

echo
echo "ALL PASS: test_sandbox.sh"
