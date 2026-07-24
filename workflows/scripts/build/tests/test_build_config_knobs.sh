#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/build-config-knobs.sh — the SSOT-derived
# knob-name list build-level.mjs's 3e.5 gate `unset`s to run hermetically
# (temperloop#1241).
#
# Covers: helper prints names · includes known VALUE knobs · EXCLUDES the two
# config-file resolvers (BUILD_CONFIG_MACHINE/LOCAL, #1055's domain) · list ==
# build.config.sh's own decls minus those two (SSOT coverage) · the load-bearing
# behavior: after `unset $(helper)` a tracked default wins over an exported knob
# — WITH a negative control proving the assertion is real (env wins without the
# scrub). Zero network.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/../build-config-knobs.sh"
CONFIG="$HERE/../build.config.sh"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

names="$(bash "$HELPER")"

# 1. Prints a non-empty list.
if [ -n "$names" ]; then ok "helper prints knob names"; else bad "helper prints knob names" "empty output"; fi

# 2. Includes representative VALUE knobs from each family the funnel exports.
for k in BUILD_MERGE_GATE_WINDOW TIDY_SYNC_WAIT ASSESS_POLL_CADENCE FUNNEL_OPERATOR EPIC_MIN_SUBUNITS; do
  if printf '%s\n' "$names" | grep -qxF "$k"; then ok "includes $k"; else bad "includes $k" "absent from list"; fi
done

# 3. EXCLUDES the two config-file resolvers (structurally distinct; #1055).
for k in BUILD_CONFIG_MACHINE BUILD_CONFIG_LOCAL; do
  if printf '%s\n' "$names" | grep -qxF "$k"; then bad "excludes $k" "leaked into scrub list"; else ok "excludes $k"; fi
done

# 4. SSOT coverage: helper list == build.config.sh's `: "${NAME:=...}"` decls
#    minus the two exclusions. Guards against the parser drifting from the file.
decls="$(sed -nE 's/^: "\$\{([A-Z_][A-Z0-9_]*):=.*/\1/p' "$CONFIG" \
           | grep -vxE 'BUILD_CONFIG_MACHINE|BUILD_CONFIG_LOCAL' | sort -u)"
got="$(printf '%s\n' "$names" | sort -u)"
if [ "$decls" = "$got" ]; then ok "list matches build.config.sh decls (SSOT)"; else
  bad "list matches build.config.sh decls (SSOT)" "diff: $(diff <(echo "$decls") <(echo "$got") | tr '\n' ' ')"; fi

# 5. Behavior — hermeticity. Isolate from any host machine/local config file so
#    the ONLY variable under test is the env-knob scrub.
empty="$(mktemp)"; trap 'rm -f "$empty"' EXIT

# 5a. Negative control: WITHOUT the scrub, an exported knob wins the env rung.
ctrl="$(
  export BUILD_CONFIG_MACHINE="$empty" BUILD_CONFIG_LOCAL="$empty"
  export BUILD_MERGE_GATE_WINDOW=99999
  # shellcheck disable=SC1090
  source "$CONFIG"
  echo "$BUILD_MERGE_GATE_WINDOW"
)"
if [ "$ctrl" = "99999" ]; then ok "negative control: exported knob wins without scrub"; else
  bad "negative control: exported knob wins without scrub" "got '$ctrl' (expected 99999 — test would be vacuous)"; fi

# 5b. WITH the scrub, the tracked default (300) wins — the gate is hermetic.
scrubbed="$(
  export BUILD_CONFIG_MACHINE="$empty" BUILD_CONFIG_LOCAL="$empty"
  export BUILD_MERGE_GATE_WINDOW=99999
  # shellcheck disable=SC2046  # intentional word-split: unset the whole knob set
  unset $(bash "$HELPER")
  # shellcheck disable=SC1090
  source "$CONFIG"
  echo "$BUILD_MERGE_GATE_WINDOW"
)"
if [ "$scrubbed" = "300" ]; then ok "scrub yields tracked default (hermetic gate)"; else
  bad "scrub yields tracked default (hermetic gate)" "got '$scrubbed' (expected 300)"; fi

echo ""
echo "build-config-knobs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
