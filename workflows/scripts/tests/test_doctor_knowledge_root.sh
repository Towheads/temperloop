#!/usr/bin/env bash
#
# Tests for workflows/scripts/install/doctor.sh's check_knowledge_root()
# (foundation#1332) — the plane-A / plane-B knowledge-store split-brain
# guard.
#
# Why this test exists: the ORIGINAL check compared ks_root() against a
# value ALSO derived from ks_root() (via
# KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE, whose only default in this tree is
# itself "$(ks_root)/.obsidian/.../data.json") — a comparison to itself,
# whose MISMATCH branch was dead code that could never fire. Its resolution
# subshell also sourced build.config.sh FIRST, which directly sources the
# operator's rung-3 machine conf into scope before ks_root() ever ran its
# own `:=` fallback — so the old check could only ever observe the
# already-correct script-plane root, never the bare-env plane (a hook, a
# launchd agent) it nominally guarded. Measured cost: a 218-drain,
# 16-consecutive-day split-brain outage ran with this check reporting green
# the entire time.
#
# The rewrite resolves TWO independently-derived planes and fails when they
# disagree:
#   Plane A (script-plane) — via build.config.sh, then knowledge_store.sh.
#   Plane B (bare-env)     — via knowledge_store.sh ALONE (no
#                            build.config.sh in the chain) — exactly what a
#                            bare hook or launchd agent sees, and exactly
#                            the plane temperloop#771's _ks_machine_conf_root()
#                            fixed for real consumers.
#
# Covers:
#   1. Plane A and plane B both resolving through the SAME rung-3 machine
#      conf -> OK, exit 0.
#   2. THE REGRESSION CASE: the bare-env plane's machine-conf pointer
#      (KNOWLEDGE_STORE_MACHINE_CONF) is broken/repointed while the
#      script-plane one (BUILD_CONFIG_MACHINE) still resolves correctly ->
#      MISMATCH, non-zero exit — this is the exact split-brain class the
#      OLD check could never observe; this test is the regression bar for
#      the rewrite.
#   3. SKIPPED (never a hard failure) when build.config.sh / knowledge_store.sh
#      are absent from the target tree (a stranger's fresh clone missing the
#      knowledge-store pieces entirely).
#   4. foundation#1340: with NO machine conf at all, both planes AGREE on the
#      default-fallback root — a UNIFORMLY WRONG root the equality check is
#      blind to, which used to print a bare OK over a shadow store. Must WARN
#      (naming provenance) rather than OK, while staying advisory (exit 0).
#   5. The `env` provenance arm (a preset KNOWLEDGE_STORE_ROOT) — the OTHER
#      OK-printing branch, covered so a mis-firing env test cannot print
#      "resolved from env" over a fallback root unnoticed.
#   6. A machine conf that EXISTS but sets a RELATIVE root: rejected by
#      _ks_machine_conf_root's absolute-path guard, so it falls back silently.
#      Must be diagnosed as present-but-unusable, not as an absent conf.
#
# Hermetic: every case runs under an isolated HOME / XDG_CONFIG_HOME /
# XDG_DATA_HOME under a throwaway tmpdir fixture (via `env -i`), never the
# real operator's environment or vault.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DOCTOR_SH="${REPO_ROOT}/workflows/scripts/install/doctor.sh"
BUILD_CONFIG_REAL="${REPO_ROOT}/workflows/scripts/build/build.config.sh"
KS_LIB_REAL="${REPO_ROOT}/workflows/scripts/lib/knowledge_store.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-doctor-knowledge-root-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$DOCTOR_SH" ] || fail "0: doctor.sh not found at $DOCTOR_SH"
[ -f "$BUILD_CONFIG_REAL" ] || fail "0: build.config.sh not found at $BUILD_CONFIG_REAL"
[ -f "$KS_LIB_REAL" ] || fail "0: knowledge_store.sh not found at $KS_LIB_REAL"

# ---------------------------------------------------------------------------
# _mk_fake_found NAME — a minimal, independent fake FOUNDATION tree carrying
# REAL copies of build.config.sh and knowledge_store.sh (reused, never
# reimplemented) at their real relative paths, so check_knowledge_root's own
# "${FOUNDATION}/workflows/scripts/..." lookups resolve exactly as they
# would in a real checkout. Prints the path to stdout.
# ---------------------------------------------------------------------------
_mk_fake_found() {
  local name="$1"
  local dir="${TMP}/${name}"
  mkdir -p "${dir}/workflows/scripts/build" "${dir}/workflows/scripts/lib"
  cp "$BUILD_CONFIG_REAL" "${dir}/workflows/scripts/build/build.config.sh"
  cp "$KS_LIB_REAL" "${dir}/workflows/scripts/lib/knowledge_store.sh"
  printf '%s\n' "$dir"
}

FOUND1="$(_mk_fake_found found1)"

# Isolated env root — never the real operator's HOME/XDG dirs.
HOME_FIX="${TMP}/home"
XDG_CONFIG_FIX="${TMP}/xdgconf"
XDG_DATA_FIX="${TMP}/xdgdata"
mkdir -p "$HOME_FIX" "${XDG_CONFIG_FIX}/temperloop" "$XDG_DATA_FIX"

VAULT_A="${TMP}/vaultA"
mkdir -p "$VAULT_A"
cat >"${XDG_CONFIG_FIX}/temperloop/build.config.sh" <<CONF
: "\${KNOWLEDGE_STORE_ROOT:=${VAULT_A}}"
CONF

_run_doctor() {
  # Fully isolated subprocess env (env -i) plus whatever extra VAR=value
  # pairs the caller appends — never the live test process's real env.
  env -i HOME="$HOME_FIX" XDG_CONFIG_HOME="$XDG_CONFIG_FIX" XDG_DATA_HOME="$XDG_DATA_FIX" PATH="$PATH" \
    "$@" bash "$DOCTOR_SH" "$FOUND1" 2>&1
}

# ---------------------------------------------------------------------------
# Test 1: plane A and plane B both resolve through the SAME rung-3 machine
# conf -> OK, exit 0.
# ---------------------------------------------------------------------------
set +e
out1="$(_run_doctor)"
set -e

section1="$(printf '%s\n' "$out1" | sed -n '/Knowledge-store root check/,/^$/p')"
grep -qF "OK — script-plane and bare-env knowledge-store root agree (resolved from machine-conf)." <<<"$section1" \
  || fail "1: expected OK naming machine-conf provenance when plane A and plane B agree — got: $section1"
grep -qF "Plane A (script-plane, via build.config.sh)  = ${VAULT_A}" <<<"$section1" \
  || fail "1: plane A did not resolve to the fixture vault — got: $section1"
grep -qF "Plane B (bare-env, knowledge_store.sh alone) = ${VAULT_A}" <<<"$section1" \
  || fail "1: plane B did not resolve to the fixture vault — got: $section1"
pass "1: plane A and plane B agree -> OK"

# ---------------------------------------------------------------------------
# Test 2 (THE REGRESSION CASE): repoint ONLY the bare-env plane's
# machine-conf pointer (KNOWLEDGE_STORE_MACHINE_CONF) at a nonexistent file,
# leaving BUILD_CONFIG_MACHINE (script-plane) untouched. This is exactly the
# class of split temperloop#771 fixed for real bare-env consumers (a hook, a
# launchd agent) — the guard must report MISMATCH, not silently pass.
# ---------------------------------------------------------------------------
set +e
out2="$(_run_doctor KNOWLEDGE_STORE_MACHINE_CONF="${TMP}/does-not-exist.sh")"
exit2=$?
set -e

section2="$(printf '%s\n' "$out2" | sed -n '/Knowledge-store root check/,/^$/p')"
grep -q '^  MISMATCH' <<<"$section2" \
  || fail "2: expected MISMATCH when the bare-env plane cannot see the rung-3 machine conf — got: $section2"
grep -qF "Plane A (script-plane, via build.config.sh)  = ${VAULT_A}" <<<"$section2" \
  || fail "2: plane A should still resolve to the fixture vault (unaffected by KNOWLEDGE_STORE_MACHINE_CONF) — got: $section2"
if grep -qF "Plane B (bare-env, knowledge_store.sh alone) = ${VAULT_A}" <<<"$section2"; then
  fail "2: plane B should NOT resolve to the fixture vault once its machine-conf pointer is broken — got: $section2"
fi
[ "$exit2" -ne 0 ] || fail "2: doctor's exit code should be non-zero when the knowledge-root check MISMATCHes"
pass "2: a broken bare-env machine-conf pointer is caught as MISMATCH (the original split-brain class the old check could never observe)"

# ---------------------------------------------------------------------------
# Test 3: SKIPPED (not a hard failure) when the config files are absent —
# a stranger's fresh clone with no knowledge-store pieces wired up yet.
# ---------------------------------------------------------------------------
FOUND_EMPTY="${TMP}/empty"
mkdir -p "$FOUND_EMPTY"
set +e
out3="$(env -i HOME="$HOME_FIX" XDG_CONFIG_HOME="$XDG_CONFIG_FIX" XDG_DATA_HOME="$XDG_DATA_FIX" PATH="$PATH" \
  bash "$DOCTOR_SH" "$FOUND_EMPTY" 2>&1)"
set -e
grep -q 'SKIPPED (config files not found' <<<"$out3" \
  || fail "3: expected SKIPPED when build.config.sh/knowledge_store.sh are absent — got: $out3"
pass "3: absent config files degrade to SKIPPED, never a hard failure"

# ---------------------------------------------------------------------------
# Test 4 (foundation#1340 — THE UNIFORM-WRONGNESS CASE): with NO rung-3
# machine conf anywhere, BOTH planes fall through to _ks_default_root() and
# AGREE — on a root that is not the store at all. The equality check alone
# cannot see this: it detects a SPLIT root, not a uniformly wrong one, so it
# printed a bare OK over a shadow store. Nothing in this tree installs or
# verifies that conf, and the plain-files backend's `mkdir -p` on append
# CREATES the wrong root rather than erroring, so the failure is silent and
# looks green — the same shape as the 16-day outage test 2 guards against.
# The check must now WARN (naming default-fallback provenance) instead of OK,
# while staying advisory (exit 0): a fresh install with no store configured
# yet legitimately lands here, and the defect was a false OK, not a missing FAIL.
# ---------------------------------------------------------------------------
XDG_CONFIG_BARE="${TMP}/xdgconf-bare"   # deliberately contains NO temperloop/build.config.sh
mkdir -p "$XDG_CONFIG_BARE"
# `|| true` rather than capturing $? behind a set +e/-e fence: the fixture tree
# has no installed surface, so unrelated MISSING checks drive doctor's process
# exit non-zero no matter what this check does — see the assertion note below.
out4="$(env -i HOME="$HOME_FIX" XDG_CONFIG_HOME="$XDG_CONFIG_BARE" XDG_DATA_HOME="$XDG_DATA_FIX" PATH="$PATH" \
  bash "$DOCTOR_SH" "$FOUND1" 2>&1)" || true

section4="$(printf '%s\n' "$out4" | sed -n '/Knowledge-store root check/,/^$/p')"
grep -q '^  WARN — both planes agree, but NOTHING CONFIGURED this root' <<<"$section4" \
  || fail "4: expected a WARN when both planes agree only because nothing configured the root — got: $section4"
if grep -q '^  OK — script-plane and bare-env knowledge-store root agree' <<<"$section4"; then
  fail "4: the check must NOT report OK when the root came from the default fallback (this is the #1340 false-OK) — got: $section4"
fi
grep -q 'KNOWLEDGE_STORE_ROOT in the rung-3 machine conf' <<<"$section4" \
  || fail "4: the WARN must name the remedy, not just the symptom — got: $section4"
# Pin WHICH root the fallback resolved to. Without this the test would still
# pass if _ks_default_root regressed to the legacy `foundation/knowledge` path
# its own v0.19.0 removal note exists to warn about.
grep -qF "Resolved root: ${XDG_DATA_FIX}/temperloop/knowledge" <<<"$section4" \
  || fail "4: the default fallback must resolve to the XDG temperloop root — got: $section4"
# Advisory means THIS CHECK contributes no failure. Assert that on the check's
# own section rather than on doctor's overall exit: the bare fixture tree has no
# installed surface (no ~/.claude, no PATH symlinks), so unrelated MISSING checks
# drive the process exit non-zero regardless — exactly why test 3, which reuses
# the same fixture, also asserts on section content and never on the exit code.
if grep -qE '^  (MISMATCH|FAIL —)' <<<"$section4"; then
  fail "4: the default-fallback case must stay advisory — the knowledge-root check itself must not fail a fresh install — got: $section4"
fi
pass "4: a uniformly-wrong root (both planes agreeing on the default fallback) WARNs instead of reporting a false OK (foundation#1340)"

# ---------------------------------------------------------------------------
# Test 5: the `env` provenance arm — a preset KNOWLEDGE_STORE_ROOT. This is the
# third of the three provenance outcomes and, critically, the other branch that
# prints OK. An untested OK-printing branch is the same shape as the defect
# #1340 closed: a regression that made the env test mis-fire would print
# "resolved from env" over a default-fallback root with nothing to catch it.
# Deterministic: once KNOWLEDGE_STORE_ROOT is set, the machine conf's `:=` is a
# no-op, so BOTH planes resolve to the preset value.
# ---------------------------------------------------------------------------
out5="$(_run_doctor KNOWLEDGE_STORE_ROOT="$VAULT_A")" || true
section5="$(printf '%s\n' "$out5" | sed -n '/Knowledge-store root check/,/^$/p')"
grep -qF "OK — script-plane and bare-env knowledge-store root agree (resolved from env)." <<<"$section5" \
  || fail "5: expected OK naming env provenance when KNOWLEDGE_STORE_ROOT is preset — got: $section5"
grep -qF "Plane B (bare-env, knowledge_store.sh alone) = ${VAULT_A}" <<<"$section5" \
  || fail "5: a preset KNOWLEDGE_STORE_ROOT must win on the bare-env plane — got: $section5"
pass "5: a preset KNOWLEDGE_STORE_ROOT reports env provenance and still reports OK"

# ---------------------------------------------------------------------------
# Test 6: a machine conf that EXISTS but never sets KNOWLEDGE_STORE_ROOT.
# _ks_machine_conf_root returns 1 (nothing to read), so BOTH planes fall back
# and agree — reaching the new agreement arm. Telling this operator to "set
# KNOWLEDGE_STORE_ROOT in the rung-3 machine conf" is the right advice, but
# calling it an unconfigured FRESH INSTALL is wrong: they have a conf, it just
# doesn't set the root. The check must distinguish the two.
#
# NOTE on the sibling case: a conf that sets a RELATIVE root does NOT reach this
# arm at all. build.config.sh sources the conf directly, so plane A adopts the
# relative value while plane B's absolute-path guard rejects it — the planes
# DISAGREE and the pre-existing MISMATCH branch catches it first, which is the
# louder and more accurate outcome. Verified while writing this test.
# ---------------------------------------------------------------------------
XDG_CONFIG_REL="${TMP}/xdgconf-empty-conf"
mkdir -p "${XDG_CONFIG_REL}/temperloop"
cat >"${XDG_CONFIG_REL}/temperloop/build.config.sh" <<'CONF'
# A real conf that configures other things but never sets the store root.
: "${SOME_UNRELATED_SETTING:=1}"
CONF
out6="$(env -i HOME="$HOME_FIX" XDG_CONFIG_HOME="$XDG_CONFIG_REL" XDG_DATA_HOME="$XDG_DATA_FIX" PATH="$PATH" \
  bash "$DOCTOR_SH" "$FOUND1" 2>&1)" || true
section6="$(printf '%s\n' "$out6" | sed -n '/Knowledge-store root check/,/^$/p')"
grep -q 'EXISTS but does not set' <<<"$section6" \
  || fail "6: a conf that exists but sets no root must name THAT — got: $section6"
if grep -q 'A fresh install with no store configured yet' <<<"$section6"; then
  fail "6: a present-but-unusable conf must not be reported as an unconfigured fresh install — got: $section6"
fi
pass "6: a machine conf that exists but sets no root is diagnosed as present-but-unusable, not as absent"

echo "All doctor knowledge-root tests passed."
