#!/usr/bin/env bash
#
# Tests for workflows/scripts/config/setting-registry-lib.sh (temperloop#164/#169
# D2) — the union-aware parse helper for the kernel setting registry TSV.
#
# Covers: parsing the real kernel TSV (columns, no malformed rows, non-empty),
# union with a synthetic overlay fixture (an overlay-only `add` row + a
# `redefault` row overriding a kernel default), and rejection/flagging of
# malformed rows (bad field count, unknown type, unknown op, an add/kernel
# name collision, a redefault with no matching kernel row).
#
# All fixture files live under a throwaway tmpdir; the only READ of the real
# repo TSV is the "kernel registry parses clean" case, which uses
# SETTING_REGISTRY_FILE pointed at the real file but never mutates it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$HERE/.." && pwd)/setting-registry-lib.sh"
REAL_KERNEL_TSV="$(cd "$HERE/.." && pwd)/setting-registry.tsv"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/setting-registry-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- 1. the real kernel TSV parses clean (no malformed rows) ---------------
(
  SETTING_REGISTRY_FILE="$REAL_KERNEL_TSV"
  SETTING_REGISTRY_OVERLAY_FILE="$TMP/no-such-overlay.tsv"
  export SETTING_REGISTRY_FILE SETTING_REGISTRY_OVERLAY_FILE
  # shellcheck source=/dev/null
  source "$LIB"
  [ -f "$REAL_KERNEL_TSV" ] || fail "1: real kernel TSV not found at $REAL_KERNEL_TSV"
  out="$(setting_registry_validate --kernel-only 2>&1)" || fail "1: real kernel TSV has malformed rows:
$out"
  n="$(setting_registry_rows | grep -c . || true)"
  [ "$n" -gt 0 ] || fail "1: real kernel TSV parsed to zero rows"
  echo "PASS: 1 real kernel setting-registry.tsv parses clean ($n rows)"
)

# --- shared synthetic kernel fixture for the remaining cases ----------------
KFILE="$TMP/kernel.tsv"
cat >"$KFILE" <<'EOF'
# comment line, ignored
SETTING_A	10	int	kernel	scripts/a.sh	first test setting

SETTING_B	auto	enum	tracked-repo	scripts/build.config.sh	second test setting
EOF

# --- 2. parse of the kernel TSV alone (no overlay present) -----------------
(
  export SETTING_REGISTRY_FILE="$KFILE"
  export SETTING_REGISTRY_OVERLAY_FILE="$TMP/absent-overlay.tsv"
  # shellcheck source=/dev/null
  source "$LIB"
  out="$(setting_registry_validate 2>&1)" || fail "2: synthetic kernel fixture should validate clean:
$out"
  got="$(setting_registry_get SETTING_A)" || fail "2: SETTING_A should resolve"
  [ "$got" = "10" ] || fail "2: SETTING_A default should be 10 (got $got)"
  n="$(setting_registry_rows | grep -c . || true)"
  [ "$n" = "2" ] || fail "2: expected exactly 2 rows with no overlay (got $n)"
  echo "PASS: 2 kernel-only parse (absent overlay is a silent no-op)"
)

# --- 3. union with an overlay extension: add row + redefault row -----------
OFILE="$TMP/overlay.tsv"
cat >"$OFILE" <<'EOF'
# overlay extension: one new setting, one override of a kernel default
SETTING_C	overlay-default	string	kernel	scripts/overlay.sh	overlay-only setting	add
SETTING_A	99	int	kernel	scripts/a.sh	first test setting, overlay-redefaulted	redefault
EOF
(
  export SETTING_REGISTRY_FILE="$KFILE"
  export SETTING_REGISTRY_OVERLAY_FILE="$OFILE"
  # shellcheck source=/dev/null
  source "$LIB"
  out="$(setting_registry_validate 2>&1)" || fail "3: union fixture should validate clean:
$out"
  n="$(setting_registry_rows | grep -c . || true)"
  [ "$n" = "3" ] || fail "3: expected 3 unioned rows (2 kernel w/ 1 redefaulted + 1 add, got $n)"
  a="$(setting_registry_get SETTING_A)" || fail "3: SETTING_A should still resolve after redefault"
  [ "$a" = "99" ] || fail "3: SETTING_A should be overlay-redefaulted to 99 (got $a)"
  b="$(setting_registry_get SETTING_B)" || fail "3: SETTING_B (untouched kernel row) should still resolve"
  [ "$b" = "auto" ] || fail "3: SETTING_B should be unchanged (got $b)"
  c="$(setting_registry_get SETTING_C)" || fail "3: SETTING_C (overlay add) should resolve"
  [ "$c" = "overlay-default" ] || fail "3: SETTING_C default wrong (got $c)"
  echo "PASS: 3 union: overlay add row + redefault row both apply, untouched kernel row survives"
)

# --- 4. malformed: wrong field count ----------------------------------------
BADFILE="$TMP/bad-fieldcount.tsv"
printf 'SETTING_BAD\tonly-two-fields\n' >"$BADFILE"
(
  export SETTING_REGISTRY_FILE="$BADFILE"
  export SETTING_REGISTRY_OVERLAY_FILE="$TMP/absent-overlay.tsv"
  # shellcheck source=/dev/null
  source "$LIB"
  if setting_registry_validate --kernel-only >/tmp/setting-reg-out-$$.txt 2>&1; then
    fail "4: a 2-field kernel row should be rejected as malformed"
  fi
  grep -q 'MALFORMED' /tmp/setting-reg-out-$$.txt || fail "4: expected a MALFORMED diagnostic"
  rm -f /tmp/setting-reg-out-$$.txt
  echo "PASS: 4 malformed row (wrong field count) is rejected"
)

# --- 5. malformed: unknown type ---------------------------------------------
BADTYPE="$TMP/bad-type.tsv"
printf 'SETTING_BAD\t1\tnot-a-real-type\tkernel\tscripts/a.sh\tbad type\n' >"$BADTYPE"
(
  export SETTING_REGISTRY_FILE="$BADTYPE"
  export SETTING_REGISTRY_OVERLAY_FILE="$TMP/absent-overlay.tsv"
  # shellcheck source=/dev/null
  source "$LIB"
  if setting_registry_validate --kernel-only >/dev/null 2>&1; then
    fail "5: an unknown type should be rejected as malformed"
  fi
  echo "PASS: 5 malformed row (unknown type) is rejected"
)

# --- 6. malformed: overlay add row collides with an existing kernel name ---
COLLIDE="$TMP/collide-overlay.tsv"
printf 'SETTING_A\t1\tint\tkernel\tscripts/a.sh\tcollides with kernel\tadd\n' >"$COLLIDE"
(
  export SETTING_REGISTRY_FILE="$KFILE"
  export SETTING_REGISTRY_OVERLAY_FILE="$COLLIDE"
  # shellcheck source=/dev/null
  source "$LIB"
  if setting_registry_validate >/dev/null 2>&1; then
    fail "6: an 'add' row colliding with a kernel name should be rejected"
  fi
  echo "PASS: 6 malformed overlay row ('add' collides with kernel name) is rejected"
)

# --- 7. malformed: overlay redefault row has no matching kernel name -------
ORPHAN="$TMP/orphan-redefault.tsv"
printf 'SETTING_NOPE\t1\tint\tkernel\tscripts/a.sh\tno such kernel row\tredefault\n' >"$ORPHAN"
(
  export SETTING_REGISTRY_FILE="$KFILE"
  export SETTING_REGISTRY_OVERLAY_FILE="$ORPHAN"
  # shellcheck source=/dev/null
  source "$LIB"
  if setting_registry_validate >/dev/null 2>&1; then
    fail "7: a 'redefault' row with no matching kernel name should be rejected"
  fi
  echo "PASS: 7 malformed overlay row ('redefault' has no kernel row to override) is rejected"
)

echo "---"
echo "test_setting_registry: OK"
