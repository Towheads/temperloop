#!/usr/bin/env bash
#
# build-config-knobs.sh — print the names of the VALUE knobs build.config.sh
# defines, one per line (temperloop#1241).
#
# SSOT-derived: the list is parsed from build.config.sh's own
# `: "${NAME:=default}"` declarations, so a newly-added knob is covered here
# with NO edit to this script — there is exactly one place knob names live.
#
# CONSUMER: build-level.mjs's 3e.5 acceptance gate. The gate runs
# `quality-gates.sh` against the worker's worktree, but under the funnel-drive
# session it inherits that session's ~40 EXPORTED build.config.sh knobs. The
# config-precedence tests the gate runs (test_config.sh / test_stranger_config.sh
# / test_funnel_cron.sh) assert rung precedence (env > machine-conf > repo-local
# > tracked-default); with the knobs exported the ENV rung wins and those
# assertions false-fail — GATE_FAIL on a change CI's `checks` passes green.
# The gate `unset`s the names this script prints before running the suite, so it
# runs hermetically at tracked defaults, exactly as CI does.
#
# EXCLUDES the two config-FILE resolvers BUILD_CONFIG_MACHINE / BUILD_CONFIG_LOCAL:
# they govern WHERE config is sourced from (a structurally distinct concern from
# a tunable value), and the machine-local FILE leak they relate to is tracked
# separately as temperloop#1055 — an env scrub cannot fix a file that is read
# regardless of the environment, so #1241 deliberately does not reach into that
# mechanism.
#
# No args. Reads only the sibling build.config.sh. Writes nothing.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="$here/build.config.sh"

[ -r "$config" ] || { echo "build-config-knobs.sh: cannot read $config" >&2; exit 1; }

# Match the documented knob idiom `: "${NAME:=...}"` (§ build.config.sh header),
# then drop the two config-file resolvers (see EXCLUDES above).
sed -nE 's/^: "\$\{([A-Z_][A-Z0-9_]*):=.*/\1/p' "$config" \
  | grep -vxE 'BUILD_CONFIG_MACHINE|BUILD_CONFIG_LOCAL'
