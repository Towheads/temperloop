#!/usr/bin/env bash
#
# Fixture tests for check-gate-paths.sh — the completeness + reachability lint
# over the diff-scoped gate-selection map (temperloop#1024).
#
# The live gate (`bash workflows/scripts/config/check-gate-paths.sh`, registered
# in scripts/quality-gates.sh) only ever exercises the GREEN arm against this
# repo's own tree. Detection has to be proven deterministically here, or the
# guarantee the map's safety story rests on ships unproven — the same
# live-check-then-fixture-tests shape as check-setting-registry.sh and
# check-personal-token-denylist.sh.
#
# Coverage — each case drives the script through its two fixture seams
# (GATE_PATHS_GATE_LIST_FILE, GATE_PATHS_TRACKED_FILE) so no case depends on
# the real tree:
#   1. GREEN on a well-formed, complete, reachable map.
#   2. RED   on a kernel gate with no row (completeness).
#   3. RED   on a row naming a gate that does not exist (stale row).
#   4. RED   on a row whose globs match nothing (UNREACHABLE — the
#            anti-silent-green check the issue's constraint names).
#   5. RED   on a duplicate key.
#   6. RED   on a row with no TAB.
#   7. RED   on a literal (wildcard-free) path that does not exist.
#   8. GREEN when a WILDCARD matches nothing but the row is otherwise
#            reachable (an optional surface like scripts/quality-gates.d/**).
#   9. GREEN for an ALWAYS row (no globs to reach).
#  10. GREEN for `ALL` / `none` pseudo-keys, which are never required to name
#            a gate.
#  11. Vendoring-consumer arm: a stale row SKIPS instead of failing.
#  12. GREEN against the REAL tree — the live gate's own invocation.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$HERE/.." && pwd)"
SCRIPT="$CONFIG_DIR/check-gate-paths.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/gates.txt" <<'EOF'
[kernel]  make test-alpha
[kernel]  make test-beta
[kernel]  bash tools/gamma.sh
[overlay] make test-overlay-only
[skipped] test_something.sh — surface absent
EOF

cat >"$TMP/tracked.txt" <<'EOF'
Makefile
LICENSE
docs/intro.md
docs/adr/0001.md
src/alpha.sh
src/beta/thing.sh
tools/gamma.sh
EOF

run_check() {  # run_check <map-file> [extra env assignments...]
  env GATE_PATHS_FILE="$1" \
      GATE_PATHS_GATE_LIST_FILE="$TMP/gates.txt" \
      GATE_PATHS_TRACKED_FILE="$TMP/tracked.txt" \
      GATE_PATHS_ROOT="$TMP" \
      "${@:2}" \
      bash "$SCRIPT" 2>&1
}

# --- 1. green ----------------------------------------------------------------
cat >"$TMP/good.tsv" <<'EOF'
# a good map
ALL	Makefile
none	LICENSE
make test-alpha	src/alpha.sh
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
out="$(run_check "$TMP/good.tsv")" || fail "1: a well-formed map should pass, got:
$out"
case "$out" in *'[ok]'*) : ;; *) fail "1: expected an [ok] line, got: $out" ;; esac
echo "PASS: 1 a well-formed, complete, reachable map passes"

# --- 2. missing row (completeness) -------------------------------------------
cat >"$TMP/incomplete.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh
bash tools/gamma.sh	ALWAYS
EOF
if out="$(run_check "$TMP/incomplete.tsv")"; then
  fail "2: a gate with no row must FAIL, got:
$out"
fi
case "$out" in *'make test-beta'*) : ;; *) fail "2: the failure must name the unmapped gate, got: $out" ;; esac
echo "PASS: 2 a kernel gate with no row fails, naming the gate"

# --- 3. stale row ------------------------------------------------------------
cat >"$TMP/stale.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
make test-deleted	docs/**
EOF
if out="$(run_check "$TMP/stale.tsv")"; then
  fail "3: a row naming a non-existent gate must FAIL, got:
$out"
fi
case "$out" in *'stale row'*) : ;; *) fail "3: the failure should say stale row, got: $out" ;; esac
echo "PASS: 3 a row naming a gate that no longer exists fails"

# --- 4. unreachable row ------------------------------------------------------
cat >"$TMP/unreachable.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh
make test-beta	nowhere/at/all/**
bash tools/gamma.sh	ALWAYS
EOF
if out="$(run_check "$TMP/unreachable.tsv")"; then
  fail "4: a row whose globs match no tracked path must FAIL, got:
$out"
fi
case "$out" in *'unreachable row'*) : ;; *) fail "4: the failure should say unreachable row, got: $out" ;; esac
case "$out" in *'make test-beta'*) : ;; *) fail "4: the failure must name the orphaned gate, got: $out" ;; esac
echo "PASS: 4 a gate orphaned behind an unmatchable glob fails the build"

# --- 5. duplicate key --------------------------------------------------------
cat >"$TMP/dup.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh
make test-alpha	src/beta/**
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
if out="$(run_check "$TMP/dup.tsv")"; then
  fail "5: a duplicate key must FAIL, got:
$out"
fi
case "$out" in *'duplicate key'*) : ;; *) fail "5: the failure should say duplicate key, got: $out" ;; esac
echo "PASS: 5 a duplicate key fails"

# --- 6. no TAB ---------------------------------------------------------------
cat >"$TMP/notab.tsv" <<'EOF'
ALL	Makefile
make test-alpha src/alpha.sh
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
if out="$(run_check "$TMP/notab.tsv")"; then
  fail "6: a row with no TAB must FAIL, got:
$out"
fi
case "$out" in *'no TAB'*) : ;; *) fail "6: the failure should say no TAB, got: $out" ;; esac
echo "PASS: 6 a row with no TAB separator fails"

# --- 7. literal path that does not exist -------------------------------------
cat >"$TMP/typo.tsv" <<'EOF'
ALL	Makefile
make test-alpha	src/alpha.sh src/alhpa-typo.sh
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
if out="$(run_check "$TMP/typo.tsv")"; then
  fail "7: a literal path that does not exist must FAIL, got:
$out"
fi
case "$out" in *'src/alhpa-typo.sh'*) : ;; *) fail "7: the failure must name the typo'd path, got: $out" ;; esac
echo "PASS: 7 a literal (wildcard-free) path that does not exist fails as a typo"

# --- 8. an unmatched WILDCARD is tolerated when the row is otherwise reachable
cat >"$TMP/optional.tsv" <<'EOF'
ALL	Makefile scripts/quality-gates.d/**
make test-alpha	src/alpha.sh
make test-beta	src/beta/**
bash tools/gamma.sh	ALWAYS
EOF
out="$(run_check "$TMP/optional.tsv")" || fail "8: an optional-surface wildcard on an otherwise-reachable row should pass, got:
$out"
echo "PASS: 8 a wildcard naming an absent optional surface passes when its row is otherwise reachable"

# --- 9/10. ALWAYS + pseudo-keys ---------------------------------------------
# Covered by case 1 (which carries an ALWAYS row and both pseudo-keys and is
# green) — asserted explicitly here so a regression names the right thing.
case "$(run_check "$TMP/good.tsv")" in
  *'[FAIL]'*) fail "9/10: ALWAYS and the ALL/none pseudo-keys must not be treated as gates" ;;
esac
echo "PASS: 9/10 ALWAYS rows and the ALL/none pseudo-keys are exempt from the gate-existence checks"

# --- 11. vendoring-consumer arm ---------------------------------------------
out="$(run_check "$TMP/stale.tsv" GATE_PATHS_ASSUME_CONSUMER=1)" \
  || fail "11: in a vendoring consumer a stale row should SKIP, not fail, got:
$out"
case "$out" in *'[skip]'*) : ;; *) fail "11: expected a legible [skip] line, got: $out" ;; esac
echo "PASS: 11 a vendoring consumer skips (never fails) a row whose gate its composed tree lacks"

# --- 12. green against the real tree, DETERMINISTICALLY ----------------------
# Repeated deliberately. The first cut of this lint matched a literal path with
# `printf '%s\n' "$TRACKED" | grep -Fxq …`; under `pipefail`, grep -q's early
# exit SIGPIPEs the printf and the PIPELINE reports 141 even though the match
# succeeded — so a row passed or failed depending on where in the file its
# match happened to land. That reads as a flaky gate, which is exactly the
# thing this repo refuses to write off. Five runs must agree.
REPO_ROOT="$(cd "$CONFIG_DIR/../../.." && pwd)"
for run in 1 2 3 4 5; do
  if ! out="$(cd "$REPO_ROOT" && bash "$SCRIPT" 2>&1)"; then
    fail "12: the real gate-paths.tsv must be green (run $run of 5):
$out"
  fi
done
echo "PASS: 12 the real tree's gate-paths.tsv is complete and reachable, deterministically (5 runs)"

echo "OK — check-gate-paths.sh: all cases passed"
