#!/usr/bin/env bash
#
# test_build_config_local.sh — build.config.sh's host-local override hook (#709).
#
# Asserts the three properties /signal-intake's funnel wiring depends on:
#   1. a PRESENT local override is sourced and its exports land in scope,
#   2. an ABSENT local override is a silent no-op (never fatal under `set -e`),
#   3. exported values PROPAGATE to a child process (signal-intake runs as a
#      subprocess funnel-tick spawns, so a plain assignment would not reach it).
#
# The BUILD_CONFIG_LOCAL seam points the hook at a temp file so this test never
# depends on (or is polluted by) a real build.config.local.sh on the host.
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

echo "PASS: build.config.sh host-local override (present / absent / child-export)"
