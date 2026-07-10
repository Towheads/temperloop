#!/usr/bin/env bash
#
# test_build_config_local.sh — build.config.sh's host-local override hook (#709)
# and the six-rung config precedence ladder it's rung 4 of (temperloop#164/#169,
# see ../../../../docs/config-precedence.md).
#
# Asserts the properties /signal-intake's funnel wiring depends on, plus the
# ladder-order regression this file's Cases 4-6 exist to pin down:
#   1. a PRESENT local override is sourced and its exports land in scope,
#   2. an ABSENT local override is a silent no-op (never fatal under `set -e`),
#   3. exported values PROPAGATE to a child process (signal-intake runs as a
#      subprocess funnel-tick spawns, so a plain assignment would not reach it).
#   4. an exported ENV VAR beats a value set in build.config.local.sh (the
#      precedence-ladder fix — before it, this file was sourced LAST with
#      plain assignments, so a local.sh value could beat an exported env var).
#   5. a MACHINE conf ($XDG_CONFIG_HOME/temperloop/ rung, via the
#      BUILD_CONFIG_MACHINE test seam) is honored when neither env nor
#      repo-local conf sets the var, and loses to an exported env var.
#   6. machine conf beats repo-local conf (rung 3 > rung 4).
#
# The BUILD_CONFIG_LOCAL / BUILD_CONFIG_MACHINE seams point the hooks at temp
# files so this test never depends on (or is polluted by) a real
# build.config.local.sh or $XDG_CONFIG_HOME/temperloop/build.config.sh on the
# host running the suite.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/../build.config.sh"
[ -f "$CONFIG" ] || { echo "FAIL: build.config.sh not found at $CONFIG" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

cat >"$tmp/local.sh" <<'EOF'
export SENTRY_AUTH_TOKEN="tok-123"
export SENTRY_ORG="acme"
EOF

# Case 1 — present local file is sourced; its exports are visible.
out="$(BUILD_CONFIG_LOCAL="$tmp/local.sh" CONFIG="$CONFIG" bash -c '
  set -euo pipefail
  . "$CONFIG"
  printf "%s|%s" "${SENTRY_AUTH_TOKEN:-unset}" "${SENTRY_ORG:-unset}"
')" || fail "sourcing config with a present local override aborted"
[ "$out" = "tok-123|acme" ] || fail "local override not applied: got '$out'"

# Case 2 — absent local file is a silent no-op; sets nothing, never fatal.
out="$(BUILD_CONFIG_LOCAL="$tmp/does-not-exist.sh" CONFIG="$CONFIG" bash -c '
  set -euo pipefail
  . "$CONFIG"
  printf "%s" "${SENTRY_AUTH_TOKEN:-unset}"
')" || fail "sourcing config with an absent local override aborted (should be non-fatal)"
[ "$out" = "unset" ] || fail "absent override leaked a value: '$out'"

# Case 3 — exports propagate to a child process (the signal-intake subprocess).
out="$(BUILD_CONFIG_LOCAL="$tmp/local.sh" CONFIG="$CONFIG" bash -c '
  set -euo pipefail
  . "$CONFIG"
  env
' | grep "^SENTRY_ORG=")" || fail "child-process env did not carry the export"
[ "$out" = "SENTRY_ORG=acme" ] || fail "export did not reach child env: '$out'"

# Case 4 — an exported env var beats build.config.local.sh (the ladder fix).
# Uses BUILD_QUOTA_PAUSE_PCT, a real `:=`-defaulted knob (default 10), so a
# no-op local.sh sourcing order bug would silently let the wrong rung win.
cat >"$tmp/local-quota.sh" <<'EOF'
: "${BUILD_QUOTA_PAUSE_PCT:=55}"
export BUILD_QUOTA_PAUSE_PCT
EOF
out="$(BUILD_QUOTA_PAUSE_PCT=77 BUILD_CONFIG_LOCAL="$tmp/local-quota.sh" BUILD_CONFIG_MACHINE="$tmp/does-not-exist-machine.sh" CONFIG="$CONFIG" bash -c '
  set -euo pipefail
  . "$CONFIG"
  printf "%s" "$BUILD_QUOTA_PAUSE_PCT"
')" || fail "sourcing config with env + local override aborted"
[ "$out" = "77" ] || fail "env var did not beat build.config.local.sh: got '$out' (want 77 — a local.sh value overrode an exported env var)"

# Case 4b — sanity: with NO env override, the local.sh value still applies
# (beating the built-in default of 10), so Case 4 isn't passing by disabling
# local.sh altogether.
out="$(BUILD_CONFIG_LOCAL="$tmp/local-quota.sh" BUILD_CONFIG_MACHINE="$tmp/does-not-exist-machine.sh" CONFIG="$CONFIG" bash -c '
  set -euo pipefail
  unset BUILD_QUOTA_PAUSE_PCT
  . "$CONFIG"
  printf "%s" "$BUILD_QUOTA_PAUSE_PCT"
')" || fail "sourcing config with only a local override aborted"
[ "$out" = "55" ] || fail "local.sh override not applied with no env set: got '$out' (want 55)"

# Case 5 — machine conf (rung 3) is honored when neither env nor repo-local
# conf sets the var, and loses to an exported env var. BUILD_CONFIG_MACHINE
# stands in for $XDG_CONFIG_HOME/temperloop/build.config.sh.
cat >"$tmp/machine.sh" <<'EOF'
: "${BUILD_MERGE_BACKEND:=managed}"
export BUILD_MERGE_BACKEND
EOF
out="$(BUILD_CONFIG_MACHINE="$tmp/machine.sh" BUILD_CONFIG_LOCAL="$tmp/does-not-exist-local.sh" CONFIG="$CONFIG" bash -c '
  set -euo pipefail
  unset BUILD_MERGE_BACKEND
  . "$CONFIG"
  printf "%s" "$BUILD_MERGE_BACKEND"
')" || fail "sourcing config with only a machine conf aborted"
[ "$out" = "managed" ] || fail "machine conf not honored: got '$out' (want managed; built-in default is auto)"

out="$(BUILD_MERGE_BACKEND=native BUILD_CONFIG_MACHINE="$tmp/machine.sh" BUILD_CONFIG_LOCAL="$tmp/does-not-exist-local.sh" CONFIG="$CONFIG" bash -c '
  set -euo pipefail
  . "$CONFIG"
  printf "%s" "$BUILD_MERGE_BACKEND"
')" || fail "sourcing config with env + machine conf aborted"
[ "$out" = "native" ] || fail "env var did not beat machine conf: got '$out' (want native)"

# Case 6 — machine conf (rung 3) beats repo-local conf (rung 4).
cat >"$tmp/local-backend.sh" <<'EOF'
: "${BUILD_MERGE_BACKEND:=native}"
export BUILD_MERGE_BACKEND
EOF
out="$(BUILD_CONFIG_MACHINE="$tmp/machine.sh" BUILD_CONFIG_LOCAL="$tmp/local-backend.sh" CONFIG="$CONFIG" bash -c '
  set -euo pipefail
  unset BUILD_MERGE_BACKEND
  . "$CONFIG"
  printf "%s" "$BUILD_MERGE_BACKEND"
')" || fail "sourcing config with machine conf + local conf aborted"
[ "$out" = "managed" ] || fail "machine conf did not beat repo-local conf: got '$out' (want managed)"

echo "PASS: build.config.sh host-local override (present / absent / child-export) + precedence ladder (env > local.sh, machine conf honored/overridden, machine > local)"
