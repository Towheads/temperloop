#!/usr/bin/env bash
#
# test_terminology_rename_compat.sh — the v0.17.0 terminology-consolidation
# legacy window (temperloop#729, ADR 0017): proves READ-OLD-WRITE-NEW for the
# renamed env prefixes and the forwarding stubs, hermetically (no network,
# no writes outside $TMPDIR).
#
#   1. LEGACY ENV HONORED: FUNNEL_<X> set, PIPELINE_<X> unset -> the value
#      drives the renamed setting, with ONE deprecation NOTE naming the
#      replacement + the v0.19.0 removal.
#   2. NEW WINS OVER OLD: both set -> the PIPELINE_* value wins, no NOTE.
#   3. NEW-ONLY IS SILENT: PIPELINE_* alone -> zero deprecation noise.
#   4. KNOB_ LEG: KNOB_REGISTRY_FILE drives SETTING_REGISTRY_FILE through
#      setting-registry-lib.sh's own shim sourcing.
#   5. FORWARDING STUB: the old validate-live-drain.sh path still runs the
#      renamed gate (NOTE on stderr, gate exit code preserved).
#   6. SOURCE-FORWARDER: sourcing the old knob-registry-lib.sh path exposes
#      the old public function names, delegating to the renamed lib.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

CFG="$REPO_ROOT/workflows/scripts/build/build.config.sh"
LIB="$REPO_ROOT/workflows/scripts/config/setting-registry-lib.sh"
OLD_LIB="$REPO_ROOT/workflows/scripts/config/knob-registry-lib.sh"

# ── 1. legacy env honored + NOTE ────────────────────────────────────────────
out="$(env -i HOME="$HOME" PATH="$PATH" FUNNEL_DRIVE_CAP=7 \
  bash -c "source '$CFG' 2>/tmp/rc0170.$$; printf '%s' \"\$PIPELINE_DRIVE_CAP\"")"
err="$(cat /tmp/rc0170.$$; rm -f /tmp/rc0170.$$)"
[ "$out" = "7" ] || fail "legacy FUNNEL_DRIVE_CAP=7 did not drive PIPELINE_DRIVE_CAP (got '$out')"
printf '%s' "$err" | grep -q 'FUNNEL_DRIVE_CAP is deprecated — renamed PIPELINE_DRIVE_CAP in v0.17.0' \
  || fail "no deprecation NOTE for FUNNEL_DRIVE_CAP (stderr: $err)"
pass "1 legacy FUNNEL_* env drives the renamed setting, with a deprecation NOTE"

# ── 2. new > old, no NOTE ───────────────────────────────────────────────────
out="$(env -i HOME="$HOME" PATH="$PATH" FUNNEL_DRIVE_CAP=7 PIPELINE_DRIVE_CAP=9 \
  bash -c "source '$CFG' 2>/tmp/rc0170.$$; printf '%s' \"\$PIPELINE_DRIVE_CAP\"")"
err="$(cat /tmp/rc0170.$$; rm -f /tmp/rc0170.$$)"
[ "$out" = "9" ] || fail "PIPELINE_DRIVE_CAP=9 should outrank legacy FUNNEL_DRIVE_CAP=7 (got '$out')"
printf '%s' "$err" | grep -q 'FUNNEL_DRIVE_CAP' \
  && fail "NOTE emitted for an IGNORED legacy var (new name set): $err"
pass "2 new name outranks the legacy var, with zero noise"

# ── 3. new-only is silent ───────────────────────────────────────────────────
err="$(env -i HOME="$HOME" PATH="$PATH" PIPELINE_DRIVE_CAP=9 \
  bash -c "source '$CFG' >/dev/null" 2>&1 | grep 'deprecated — renamed' || true)"
[ -z "$err" ] || fail "new-env-only run surfaced deprecation noise: $err"
pass "3 new-env-only run is deprecation-silent"

# ── 4. KNOB_ leg via setting-registry-lib.sh ────────────────────────────────
out="$(env -i HOME="$HOME" PATH="$PATH" KNOB_REGISTRY_FILE=/tmp/some-registry.tsv \
  bash -c "source '$LIB' 2>/dev/null; printf '%s' \"\$SETTING_REGISTRY_FILE\"")"
[ "$out" = "/tmp/some-registry.tsv" ] \
  || fail "legacy KNOB_REGISTRY_FILE did not drive SETTING_REGISTRY_FILE (got '$out')"
pass "4 legacy KNOB_* env drives the renamed SETTING_* seam through the lib"

# ── 5. forwarding stub ──────────────────────────────────────────────────────
stub_err="$(bash "$REPO_ROOT/workflows/scripts/validate-live-drain.sh" 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || fail "validate-live-drain.sh stub exited $rc (expected the renamed gate's 0)"
printf '%s' "$stub_err" | grep -q 'renamed validate-capture-backstop.sh in v0.17.0' \
  || fail "stub emitted no rename NOTE (stderr: $stub_err)"
pass "5 old validate-live-drain.sh path forwards to the renamed gate with a NOTE"

# ── 6. source-forwarder old function names ──────────────────────────────────
out="$(bash -c "source '$OLD_LIB' 2>/dev/null; knob_registry_kernel_file")"
[ "$out" = "$REPO_ROOT/workflows/scripts/config/setting-registry.tsv" ] \
  || fail "knob_registry_kernel_file wrapper broken (got '$out')"
pass "6 old knob-registry-lib.sh source path exposes old-named wrappers"

echo "test_terminology_rename_compat: OK"
