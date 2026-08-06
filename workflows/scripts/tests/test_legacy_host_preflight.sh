#!/usr/bin/env bash
#
# Tests for workflows/scripts/install/legacy-host-preflight.sh (temperloop#908)
# and its wiring into workflows/scripts/install/doctor.sh's
# check_legacy_host_config().
#
# Covers, for BOTH registry entries (the two real instances that motivated
# this mechanism):
#   1. ABSENT — the legacy consumable never existed on this host -> exit 0,
#      never a failure (the "fails open on a host where a path was never
#      present" acceptance bar).
#   2. LIVE-UNMIGRATED — a RECONSTRUCTED unmigrated case, demonstrated
#      rather than only asserted:
#        a. foundation#1419 — an installed ~/Library/LaunchAgents plist
#           still referencing the deleted funnel-cron.sh stub.
#        b. temperloop#165 — a legacy $XDG_CONFIG_HOME/foundation/boards.conf
#           present with no $XDG_CONFIG_HOME/temperloop/boards.conf
#           successor.
#   3. MIGRATED — the legacy consumable is present but the host has already
#      moved to its replacement -> exit 0.
#   4. doctor.sh wiring: check_legacy_host_config() surfaces the same
#      verdicts and fails `make doctor`'s overall exit code exactly when a
#      LIVE-UNMIGRATED entry is present; SKIPPED (never a hard failure) when
#      legacy-host-preflight.sh itself is absent from the target tree.
#
# Hermetic: every case runs under an isolated HOME / XDG_CONFIG_HOME under a
# throwaway tmpdir fixture (via `env -i`), never the real operator's
# environment — same idiom as test_doctor_knowledge_root.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PREFLIGHT_SH="${REPO_ROOT}/workflows/scripts/install/legacy-host-preflight.sh"
DOCTOR_SH="${REPO_ROOT}/workflows/scripts/install/doctor.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-legacy-host-preflight-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$PREFLIGHT_SH" ] || fail "0: legacy-host-preflight.sh not found at $PREFLIGHT_SH"
[ -f "$DOCTOR_SH" ] || fail "0: doctor.sh not found at $DOCTOR_SH"

_run_preflight() {
  # Fully isolated subprocess env (env -i) — never the real operator's HOME
  # or XDG_CONFIG_HOME. Caller appends extra VAR=value pairs before "$@".
  env -i HOME="$HOME_FIX" XDG_CONFIG_HOME="$XDG_CONFIG_FIX" PATH="$PATH" "$@" \
    bash "$PREFLIGHT_SH" 2>&1
}

# ---------------------------------------------------------------------------
# Test 1: both registry entries ABSENT on a bare fixture host -> exit 0,
# both lines report ABSENT. This is the "never installed / not applicable"
# graceful-degradation case.
# ---------------------------------------------------------------------------
HOME_FIX="${TMP}/home1"
XDG_CONFIG_FIX="${TMP}/xdg1"
mkdir -p "$HOME_FIX" "$XDG_CONFIG_FIX"

set +e
out1="$(_run_preflight)"
exit1=$?
set -e

grep -q '^  ABSENT.*funnel-cron-plist' <<<"$out1" \
  || fail "1: expected ABSENT for funnel-cron-plist on a bare host — got: $out1"
grep -q '^  ABSENT.*foundation-boards-conf' <<<"$out1" \
  || fail "1: expected ABSENT for foundation-boards-conf on a bare host — got: $out1"
[ "$exit1" -eq 0 ] || fail "1: expected exit 0 when every entry is ABSENT — got $exit1"
pass "1: both registry entries ABSENT on a never-installed host -> exit 0"

# ---------------------------------------------------------------------------
# Test 2a (RECONSTRUCTED foundation#1419): an installed launchd agent plist
# still names the deleted funnel-cron.sh stub -> LIVE-UNMIGRATED, exit 1.
# ---------------------------------------------------------------------------
HOME_FIX="${TMP}/home2a"
XDG_CONFIG_FIX="${TMP}/xdg2a"
mkdir -p "${HOME_FIX}/Library/LaunchAgents" "$XDG_CONFIG_FIX"
cat >"${HOME_FIX}/Library/LaunchAgents/com.foundation.funnel-cron.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key><string>com.foundation.funnel-cron</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/operator/dev/foundation/workflows/scripts/build/funnel-cron.sh</string>
  </array>
</dict>
</plist>
PLIST

set +e
out2a="$(_run_preflight)"
exit2a=$?
set -e

grep -q '^  LIVE-UNMIGRATED.*funnel-cron-plist' <<<"$out2a" \
  || fail "2a: expected LIVE-UNMIGRATED for funnel-cron-plist — got: $out2a"
grep -qF 'still references the deleted funnel-cron.sh stub' <<<"$out2a" \
  || fail "2a: expected the remediation line naming funnel-cron.sh — got: $out2a"
[ "$exit2a" -ne 0 ] || fail "2a: expected non-zero exit with a LIVE-UNMIGRATED entry — got $exit2a"
pass "2a: RECONSTRUCTED foundation#1419 (installed plist still runs the deleted stub) -> LIVE-UNMIGRATED, exit 1"

# ---------------------------------------------------------------------------
# Test 2b (RECONSTRUCTED temperloop#165): a legacy machine boards.conf
# exists with no v0.15.0-successor boards.conf in place ->
# LIVE-UNMIGRATED, exit 1.
# ---------------------------------------------------------------------------
HOME_FIX="${TMP}/home2b"
XDG_CONFIG_FIX="${TMP}/xdg2b"
mkdir -p "${XDG_CONFIG_FIX}/foundation" "$HOME_FIX"
cat >"${XDG_CONFIG_FIX}/foundation/boards.conf" <<'CONF'
board.3.backend=issues
board.4.backend=issues
board.5.backend=issues
board.6.backend=issues
CONF

set +e
out2b="$(_run_preflight)"
exit2b=$?
set -e

grep -q '^  LIVE-UNMIGRATED.*foundation-boards-conf' <<<"$out2b" \
  || fail "2b: expected LIVE-UNMIGRATED for foundation-boards-conf — got: $out2b"
grep -qF 'silently invisible' <<<"$out2b" \
  || fail "2b: expected the remediation line naming the silent-invisible risk — got: $out2b"
[ "$exit2b" -ne 0 ] || fail "2b: expected non-zero exit with a LIVE-UNMIGRATED entry — got $exit2b"
pass "2b: RECONSTRUCTED temperloop#165 (legacy boards.conf with no successor) -> LIVE-UNMIGRATED, exit 1"

# ---------------------------------------------------------------------------
# Test 3: MIGRATED — both legacy consumables present, but each has its
# replacement in place too -> exit 0, both lines report MIGRATED.
# ---------------------------------------------------------------------------
HOME_FIX="${TMP}/home3"
XDG_CONFIG_FIX="${TMP}/xdg3"
mkdir -p "${HOME_FIX}/Library/LaunchAgents" "${XDG_CONFIG_FIX}/foundation" "${XDG_CONFIG_FIX}/temperloop"
cat >"${HOME_FIX}/Library/LaunchAgents/com.foundation.funnel-cron.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key><string>com.foundation.funnel-cron</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/operator/dev/foundation/workflows/scripts/build/pipeline-cron.sh</string>
  </array>
</dict>
</plist>
PLIST
: >"${XDG_CONFIG_FIX}/foundation/boards.conf"
: >"${XDG_CONFIG_FIX}/temperloop/boards.conf"

set +e
out3="$(_run_preflight)"
exit3=$?
set -e

grep -q '^  MIGRATED.*funnel-cron-plist' <<<"$out3" \
  || fail "3: expected MIGRATED for funnel-cron-plist once the plist references pipeline-cron.sh — got: $out3"
grep -q '^  MIGRATED.*foundation-boards-conf' <<<"$out3" \
  || fail "3: expected MIGRATED for foundation-boards-conf once the successor file exists — got: $out3"
[ "$exit3" -eq 0 ] || fail "3: expected exit 0 when every entry is MIGRATED — got $exit3"
pass "3: both registry entries MIGRATED -> exit 0"

# ---------------------------------------------------------------------------
# Test 3b (REGRESSION — a naive whole-file grep would false-positive this):
# a MIGRATED plist whose ProgramArguments already runs pipeline-cron.sh, but
# whose header COMMENT names the installer script
# infra/launchd/install-funnel-cron.sh — which substring-matches
# "funnel-cron.sh" — must still report MIGRATED, not LIVE-UNMIGRATED. This
# is the exact shape of the real installed plist on the host this test
# suite was authored against (temperloop#908 self-verification caught this
# live before the comment-stripping fix landed).
# ---------------------------------------------------------------------------
HOME_FIX="${TMP}/home3b"
XDG_CONFIG_FIX="${TMP}/xdg3b"
mkdir -p "${HOME_FIX}/Library/LaunchAgents" "$XDG_CONFIG_FIX"
cat >"${HOME_FIX}/Library/LaunchAgents/com.foundation.funnel-cron.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!--
  For the idempotent one-step install, run (from the foundation checkout):
    infra/launchd/install-funnel-cron.sh
-->
<plist version="1.0">
<dict>
  <key>Label</key><string>com.foundation.funnel-cron</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/operator/dev/foundation.cron/workflows/scripts/build/pipeline-cron.sh</string>
  </array>
</dict>
</plist>
PLIST

set +e
out3b="$(_run_preflight)"
exit3b=$?
set -e

grep -q '^  MIGRATED.*funnel-cron-plist' <<<"$out3b" \
  || fail "3b: a header comment naming install-funnel-cron.sh must NOT false-positive LIVE-UNMIGRATED when the real ProgramArguments already runs pipeline-cron.sh — got: $out3b"
[ "$exit3b" -eq 0 ] || fail "3b: expected exit 0 — got $exit3b (regression: comment text leaked into the content match)"
pass "3b: REGRESSION — a comment mentioning install-funnel-cron.sh does not false-positive a MIGRATED plist"

# ---------------------------------------------------------------------------
# Test 4: doctor.sh wiring — check_legacy_host_config() surfaces the same
# LIVE-UNMIGRATED verdict and fails `make doctor`'s overall exit code.
# Reuses the RECONSTRUCTED foundation#1419 fixture host from test 2a.
# ---------------------------------------------------------------------------
FOUND4="${TMP}/found4"
mkdir -p "$FOUND4"
# doctor.sh's own link-enumeration / other checks need a minimal tree to not
# themselves explode; an empty repo root is fine — links_enumerate,
# check_knowledge_root, check_cross_checkout_split, check_cache_state, and
# check_reviewer_coverage all degrade to SKIPPED/no-managed-links on an
# empty tree (proven by test_doctor_knowledge_root.sh's own Test 3 fixture,
# same shape). Only legacy-host-preflight.sh needs to be a REAL copy so
# check_legacy_host_config() can source it.
mkdir -p "${FOUND4}/workflows/scripts/install"
cp "$PREFLIGHT_SH" "${FOUND4}/workflows/scripts/install/legacy-host-preflight.sh"

HOME_FIX="${TMP}/home2a"       # reuse test 2a's stranded-plist fixture host
XDG_CONFIG_FIX="${TMP}/xdg2a"

set +e
out4="$(env -i HOME="$HOME_FIX" XDG_CONFIG_HOME="$XDG_CONFIG_FIX" PATH="$PATH" \
  bash "$DOCTOR_SH" "$FOUND4" 2>&1)"
exit4=$?
set -e

section4="$(printf '%s\n' "$out4" | sed -n '/Legacy host-config preflight/,/^$/p')"
grep -q 'LIVE-UNMIGRATED.*funnel-cron-plist' <<<"$section4" \
  || fail "4: expected doctor.sh to surface the LIVE-UNMIGRATED funnel-cron-plist verdict — got: $section4"
[ "$exit4" -ne 0 ] || fail "4: expected make-doctor's overall exit to be non-zero on a LIVE-UNMIGRATED legacy-host entry — got $exit4"
pass "4: doctor.sh's check_legacy_host_config() surfaces LIVE-UNMIGRATED and fails doctor's overall exit code"

# ---------------------------------------------------------------------------
# Test 5: doctor.sh degrades to SKIPPED (never a hard failure on ITS OWN)
# when legacy-host-preflight.sh is absent from the target tree — a
# stranger's fresh clone at a kernel version predating this check.
# ---------------------------------------------------------------------------
FOUND5="${TMP}/found5"
mkdir -p "$FOUND5"

set +e
out5="$(env -i HOME="${TMP}/home5" XDG_CONFIG_HOME="${TMP}/xdg5" PATH="$PATH" \
  bash "$DOCTOR_SH" "$FOUND5" 2>&1)"
set -e

section5="$(printf '%s\n' "$out5" | sed -n '/Legacy host-config preflight/,/^$/p')"
grep -q 'SKIPPED (legacy-host-preflight.sh not found' <<<"$section5" \
  || fail "5: expected SKIPPED when legacy-host-preflight.sh is absent — got: $section5"
pass "5: absent legacy-host-preflight.sh degrades doctor.sh's own check to SKIPPED"

echo "All legacy-host-preflight tests passed."
