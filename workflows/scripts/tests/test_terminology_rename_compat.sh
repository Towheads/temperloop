#!/usr/bin/env bash
#
# test_terminology_rename_compat.sh — the v0.17.0 terminology-consolidation
# legacy window is CLOSED (temperloop#767, closing epic temperloop#719 / ADR
# 0017). This suite used to prove READ-OLD-WRITE-NEW; it now proves the
# opposite — that the window stays SHUT — hermetically (no network, no writes
# outside $TMPDIR).
#
#   1. PRE-RENAME ENV IS INERT: a pre-rename env name set alone leaves the
#      renamed setting at its kernel default, and emits no deprecation NOTE.
#   2. RENAMED NAME STILL WORKS: the renamed name binds normally (the removal
#      broke nothing on the supported path).
#   3. REGISTRY-LIB SEAM: a pre-rename env name does NOT drive the renamed
#      registry-file seam through setting-registry-lib.sh.
#   4. CONF-LAYER SEAM: a pre-rename name set by a layer-3 machine conf is
#      likewise inert — the window's SECOND shim pass is gone too.
#   5. NO SHIM FUNCTION: sourcing build.config.sh defines no forwarding
#      helper at all (the fail-open `[ -f ]` source blocks are gone, not just
#      the file they guarded).
#   6. NO WINDOW FILES: the compat lib and the forwarding stubs are absent
#      from the tree.
#
# Deliberately NOT asserted here: that no pre-rename IDENTIFIER re-enters the
# tree. That is check-terminology-leak-guard.sh's job (`make
# test-kernel-terminology`), and with the window's exempt class deleted it now
# covers the surfaces this window used to own — including the capture/backstop
# validator's pre-rename overlay-filename read.
#
# The legacy identifiers below are DERIVED from their renamed counterparts
# rather than written out, so this file stays clean under both the leak gate
# and the window-close grep sweep.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

CFG="$REPO_ROOT/workflows/scripts/build/build.config.sh"
LIB="$REPO_ROOT/workflows/scripts/config/setting-registry-lib.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/termwindow.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ERRTMP="$TMP/stderr.txt"
# A scratch HOME so the host's own machine conf (layer 3) cannot colour the
# kernel-default assertions below.
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"

# The two rename maps, expressed as (renamed name -> pre-rename name) without
# ever spelling a pre-rename name literally.
NEW_SETTING=PIPELINE_DRIVE_CAP
OLD_SETTING="FUNNEL_${NEW_SETTING#PIPELINE_}"
NEW_REGISTRY_SEAM=SETTING_REGISTRY_FILE
OLD_REGISTRY_SEAM="KNOB_${NEW_REGISTRY_SEAM#SETTING_}"
KERNEL_DEFAULT=1   # build.config.sh's committed default for $NEW_SETTING

# ── 1. a pre-rename env name is inert, and silent ───────────────────────────
out="$(env -i HOME="$FAKE_HOME" PATH="$PATH" "$OLD_SETTING=7" \
  bash -c "source '$CFG' 2>'$ERRTMP'; printf '%s' \"\${$NEW_SETTING}\"")"
err="$(cat "$ERRTMP")"
[ "$out" = "$KERNEL_DEFAULT" ] \
  || fail "pre-rename $OLD_SETTING=7 must NOT drive $NEW_SETTING — expected the kernel default $KERNEL_DEFAULT, got '$out'"
grep -q 'deprecated' <<<"$err" \
  && fail "the closed window still emits a deprecation NOTE: $err"
pass "1 a pre-rename env name is inert and silent (window closed)"

# ── 2. the renamed name still binds normally ────────────────────────────────
out="$(env -i HOME="$FAKE_HOME" PATH="$PATH" "$NEW_SETTING=9" \
  bash -c "source '$CFG' 2>/dev/null; printf '%s' \"\${$NEW_SETTING}\"")"
[ "$out" = "9" ] || fail "$NEW_SETTING=9 did not bind (got '$out') — the removal broke the supported path"
pass "2 the renamed env name still binds normally"

# ── 3. the registry-lib seam no longer forwards ─────────────────────────────
out="$(env -i HOME="$FAKE_HOME" PATH="$PATH" "$OLD_REGISTRY_SEAM=/tmp/some-registry.tsv" \
  bash -c "source '$LIB' 2>/dev/null; printf '%s' \"\${$NEW_REGISTRY_SEAM:-}\"")"
[ -z "$out" ] \
  || fail "pre-rename $OLD_REGISTRY_SEAM must NOT drive $NEW_REGISTRY_SEAM (got '$out')"
out="$(env -i HOME="$FAKE_HOME" PATH="$PATH" \
  bash -c "source '$LIB' 2>/dev/null; setting_registry_kernel_file")"
# Compare PHYSICALLY resolved paths on both sides (temperloop#887): on macOS
# $TMPDIR lives under the /var -> /private/var symlink, so a checkout made
# there (combined-tree-precheck.sh's throwaway worktree) can hand the two
# sides logically-different spellings of the same file. The `cd -P` that
# actually introduced the mismatch went away with the source-forwarder this
# suite used to exercise; normalizing here keeps the leg immune regardless.
phys() { printf '%s/%s' "$(cd -P "$(dirname "$1")" && pwd)" "$(basename "$1")"; }
[ "$(phys "$out")" = "$(phys "$REPO_ROOT/workflows/scripts/config/setting-registry.tsv")" ] \
  || fail "setting_registry_kernel_file broken after the window close (got '$out')"
pass "3 the registry-lib seam ignores the pre-rename name and still resolves its own default"

# ── 4. a conf-layer pre-rename name is inert too (second shim pass gone) ────
mc="$TMP/machine.conf.sh"
printf ': "${%s:=5}"\n' "$OLD_SETTING" > "$mc"
out="$(env -i HOME="$FAKE_HOME" PATH="$PATH" BUILD_CONFIG_MACHINE="$mc" \
  bash -c "source '$CFG' 2>/dev/null; printf '%s' \"\${$NEW_SETTING}\"")"
[ "$out" = "$KERNEL_DEFAULT" ] \
  || fail "a machine-conf pre-rename name must NOT drive $NEW_SETTING — expected $KERNEL_DEFAULT, got '$out'"
pass "4 a layer-3 conf's pre-rename name is inert (the second shim pass is gone)"

# ── 5. no forwarding helper is defined at all ───────────────────────────────
out="$(env -i HOME="$FAKE_HOME" PATH="$PATH" \
  bash -c "source '$CFG' >/dev/null 2>&1; declare -F | grep -c rename_compat" || true)"
[ "$out" = "0" ] \
  || fail "sourcing build.config.sh still defines $out forwarding helper(s) — a source block outlived the shim"
pass "5 sourcing build.config.sh defines no rename-forwarding helper"

# ── 6. the window's own files are gone ──────────────────────────────────────
# Globbed, never named: the compat lib, the pre-rename pipeline scripts, the
# pre-rename setting-registry scripts, and the pre-rename validator path.
leftovers=""
for f in "$REPO_ROOT"/workflows/scripts/lib/rename-compat-*.sh \
         "$REPO_ROOT"/workflows/scripts/build/funnel-* \
         "$REPO_ROOT"/workflows/scripts/build/build-config-kno*.sh \
         "$REPO_ROOT"/workflows/scripts/config/*kno*.sh \
         "$REPO_ROOT"/workflows/scripts/validate-live-*.sh; do
  [ -e "$f" ] && leftovers="$leftovers $f"
done
[ -z "$leftovers" ] || fail "legacy-window file(s) still present:$leftovers"
pass "6 the compat lib and every forwarding stub are gone from the tree"

echo "test_terminology_rename_compat: OK"
