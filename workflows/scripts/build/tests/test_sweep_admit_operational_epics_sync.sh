#!/usr/bin/env bash
#
# test_sweep_admit_operational_epics_sync.sh — sync-survival proof for
# SWEEP_ADMIT_OPERATIONAL_EPICS (epic #1847 Produces #1, item
# pool-admission-setting), the #711 build.config.local.sh pattern applied to
# this specific setting.
#
# WHAT THIS PROVES. build.config.sh's own header states the precedence
# ladder: build.config.local.sh (layer 4, untracked/gitignored) is sourced
# BEFORE this file's own `:=` defaults (layer 5), so a value the local file
# sets already wins by the time the tracked line's `:=` runs. This test
# exercises that ladder for SWEEP_ADMIT_OPERATIONAL_EPICS specifically: a
# routine vendored sync that overwrites build.config.sh back to its tracked
# `:=0` default must NEVER silently flip an operator's local opt-in back
# off. (test_build_config_local.sh already proves the general ladder with
# BUILD_QUOTA_PAUSE_PCT/BUILD_MERGE_BACKEND; this is the same proof, run
# against the setting this item actually ships, per the acceptance
# criterion's own naming.)
#
# The BUILD_CONFIG_LOCAL test seam points the hook at a temp file so this
# test never depends on (or is polluted by) a real build.config.local.sh on
# the host running the suite.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/../build.config.sh"
[ -f "$CONFIG" ] || { echo "FAIL: build.config.sh not found at $CONFIG" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# ── Case 1: with NO local override, sourcing the tracked file alone reads
#    the tracked default (0) — the "sync just landed, operator never
#    opted in" baseline every other case is measured against.
out="$(BUILD_CONFIG_LOCAL="$tmp/does-not-exist.sh" BUILD_CONFIG_MACHINE="$tmp/does-not-exist-machine.sh" CONFIG="$CONFIG" bash -c '
  set -euo pipefail
  unset SWEEP_ADMIT_OPERATIONAL_EPICS
  . "$CONFIG"
  printf "%s" "$SWEEP_ADMIT_OPERATIONAL_EPICS"
')" || fail "sourcing config with no local override aborted"
[ "$out" = "0" ] || fail "tracked default is not 0: got '$out' (rollback-identity default drifted)"

# ── Case 2: the operator's local opt-in (build.config.local.sh) is honored
#    when no env var is set.
cat >"$tmp/local-on.sh" <<'EOF'
: "${SWEEP_ADMIT_OPERATIONAL_EPICS:=1}"
export SWEEP_ADMIT_OPERATIONAL_EPICS
EOF
out="$(BUILD_CONFIG_LOCAL="$tmp/local-on.sh" BUILD_CONFIG_MACHINE="$tmp/does-not-exist-machine.sh" CONFIG="$CONFIG" bash -c '
  set -euo pipefail
  unset SWEEP_ADMIT_OPERATIONAL_EPICS
  . "$CONFIG"
  printf "%s" "$SWEEP_ADMIT_OPERATIONAL_EPICS"
')" || fail "sourcing config with a local opt-in aborted"
[ "$out" = "1" ] || fail "local opt-in not honored: got '$out' (want 1)"

# ── Case 3 (THE SYNC-SURVIVAL PROOF): simulate a routine vendored sync by
#    overwriting build.config.sh's own tracked default line to a byte-
#    identical fresh copy of itself (the sync operation is "the tracked
#    file's content is replaced with the upstream tracked content" — since
#    this checkout IS upstream, the faithful simulation is re-sourcing the
#    SAME tracked file, which is exactly what a sync leaves on disk). What
#    must survive is the local override, sourced BEFORE the tracked file's
#    own `:=` line ever runs — never re-derive the tracked file to prove
#    this, since a sync never touches build.config.local.sh at all (it is
#    gitignored, per §709 in that file's own header).
out="$(BUILD_CONFIG_LOCAL="$tmp/local-on.sh" BUILD_CONFIG_MACHINE="$tmp/does-not-exist-machine.sh" CONFIG="$CONFIG" bash -c '
  set -euo pipefail
  unset SWEEP_ADMIT_OPERATIONAL_EPICS
  . "$CONFIG"
  . "$CONFIG"
  printf "%s" "$SWEEP_ADMIT_OPERATIONAL_EPICS"
')" || fail "re-sourcing config (simulated sync) aborted"
[ "$out" = "1" ] || fail "sync-survival FAILED: local opt-in did not survive a re-source of the tracked file: got '$out' (want 1 — the effective value must not silently revert to the tracked default)"

# ── Case 4: an exported env var still beats the local override (the same
#    six-layer ladder every other setting honors — this setting gets no
#    special-case exemption from it).
out="$(SWEEP_ADMIT_OPERATIONAL_EPICS=0 BUILD_CONFIG_LOCAL="$tmp/local-on.sh" BUILD_CONFIG_MACHINE="$tmp/does-not-exist-machine.sh" CONFIG="$CONFIG" bash -c '
  set -euo pipefail
  . "$CONFIG"
  printf "%s" "$SWEEP_ADMIT_OPERATIONAL_EPICS"
')" || fail "sourcing config with env + local override aborted"
[ "$out" = "0" ] || fail "env var did not beat build.config.local.sh: got '$out' (want 0)"

echo "PASS: SWEEP_ADMIT_OPERATIONAL_EPICS sync survival (tracked default 0, local opt-in honored, survives a tracked-file re-source, env still outranks it)"
