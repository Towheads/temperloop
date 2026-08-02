#!/usr/bin/env bash
#
# test_worker_model_settings.sh — the four plan-less model-tier settings
# (temperloop#982): SWEEP_WORKER_MODEL, FIX_WORKER_MODEL,
# BUILD_MACHINERY_SOLO_MODEL, BUILD_MACHINERY_BATCH_MODEL. `/sweep` and `/fix`
# hardcoded their worker model because a singleton has no plan item to derive
# a tier from; the two claude/workflows/build-level.mjs machinery-executor
# sites had the same gap. This item names all four as settings with NO
# default change (byte-identical when unset).
#
# The two machinery-executor settings are named as a PAIR
# (BUILD_MACHINERY_SOLO_MODEL / BUILD_MACHINERY_BATCH_MODEL), not a
# general-case-plus-carve-out — runMachinery (solo) and runMachineryBatch
# (batched) each cover exactly half of build-level.mjs's four machinery call
# sites, so an unqualified "BUILD_MACHINERY_MODEL" would overclaim (setting
# it alone would leave half the machinery spawns untouched). Both settings
# are wired at ALL THREE Workflow-invoking commands — build.md, sweep.md,
# AND fix.md — since the setting governs a seat inside build-level.mjs
# itself, not any one caller of it; wiring only build.md would leave /sweep
# and /fix silently pinned at the hardcoded default no matter what the
# operator sets.
#
# Two of the four (BUILD_MACHINERY_SOLO_MODEL / BUILD_MACHINERY_BATCH_MODEL)
# get a genuine BEHAVIORAL test in test_workflow.sh (the offline
# build-level.mjs fixture harness) — that file asserts the override actually
# reaches the spawned executor agent's opts.model, INCLUDING the empty-string
# case (an empty override must still collapse to the 'haiku' default, not
# ride through as a literal "" model — the reason build-level.mjs reads
# `|| 'haiku'`, never `?? 'haiku'`). The other two (SWEEP_WORKER_MODEL /
# FIX_WORKER_MODEL) back a field inside sweep.md / fix.md / build.md PROSE,
# which is executed by an LLM, not a script — there is no offline harness for
# prose. This file covers the two mechanically-checkable halves of that prose
# wiring instead:
#   1. the CONFIG LAYER — build.config.sh's `:=` seam for each of the four
#      settings actually resolves an override (env / non-default value), and
#      defaults to the empty inherit-session sentinel when unset (matching
#      SWEEP_DETECT_MODEL's existing convention) — the same shell-level
#      assertion test_build_config_local.sh makes for other settings;
#   2. the PROSE WIRING — sweep.md / fix.md / build.md reference the new
#      setting names SYMBOLICALLY at the exact site that used to hardcode
#      `model: <undef>` (or the build-level.mjs 'haiku' literal), i.e. the old
#      hardcoded literal is gone from that construction site and the setting's
#      bare name is present nearby — proving the wiring exists in the
#      executable prose the LLM will read, per the kernel's Named-setting
#      convention (source at Step 0, reference symbolically thereafter); AND
#      that sweep.md/fix.md wire the two machinery-executor settings too, not
#      just build.md.
#
# Zero network, bash-3.2-portable (macOS + Linux CI).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
CONFIG="$HERE/../build.config.sh"
SWEEP_MD="$REPO_ROOT/claude/commands/sweep.md"
FIX_MD="$REPO_ROOT/claude/commands/fix.md"
BUILD_MD="$REPO_ROOT/claude/commands/build.md"

[ -f "$CONFIG" ] || { echo "FAIL: build.config.sh not found at $CONFIG" >&2; exit 1; }
[ -f "$SWEEP_MD" ] || { echo "FAIL: sweep.md not found at $SWEEP_MD" >&2; exit 1; }
[ -f "$FIX_MD" ] || { echo "FAIL: fix.md not found at $FIX_MD" >&2; exit 1; }
[ -f "$BUILD_MD" ] || { echo "FAIL: build.md not found at $BUILD_MD" >&2; exit 1; }

pass=0
fail_count=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail_count=$((fail_count + 1)); }

ALL_VARS="SWEEP_WORKER_MODEL FIX_WORKER_MODEL BUILD_MACHINERY_SOLO_MODEL BUILD_MACHINERY_BATCH_MODEL"

# ── 1. Config layer — all four settings default to empty (inherit-session) ──
for var in $ALL_VARS; do
  out="$(BUILD_CONFIG_MACHINE=/nonexistent-machine-conf BUILD_CONFIG_LOCAL=/nonexistent-local-conf CONFIG="$CONFIG" VAR="$var" bash -c '
    set -euo pipefail
    unset "$VAR"
    . "$CONFIG"
    eval "printf %s \"\${$VAR}\""
  ')" || { bad "$var defaults to empty (unset)" "sourcing aborted"; continue; }
  if [ -z "$out" ]; then ok "$var defaults to empty (inherit-session sentinel, unchanged)"; else
    bad "$var defaults to empty (inherit-session sentinel, unchanged)" "got '$out', expected empty"; fi
done

# ── 2. Config layer — an override on each of the four settings resolves and
#      propagates to a child process (the same shape a command-spec Step 0
#      `source build.config.sh` relies on). ─────────────────────────────────
for var in $ALL_VARS; do
  out="$(BUILD_CONFIG_MACHINE=/nonexistent-machine-conf BUILD_CONFIG_LOCAL=/nonexistent-local-conf CONFIG="$CONFIG" VAR="$var" VAL="opus-test-tier" bash -c '
    set -euo pipefail
    export "$VAR=$VAL"
    . "$CONFIG"
    eval "printf %s \"\${$VAR}\""
  ')" || { bad "$var override propagates" "sourcing aborted"; continue; }
  if [ "$out" = "opus-test-tier" ]; then ok "$var override propagates through build.config.sh's :=  seam"; else
    bad "$var override propagates through build.config.sh's :=  seam" "got '$out', expected 'opus-test-tier'"; fi
done

# ── 3. setting-registry.tsv — a row exists for each of the four (name in
#      column 1, tab-delimited so a substring match on another setting's doc
#      text can't false-positive). check-setting-registry.sh is the
#      authoritative equality/unregistered-setting gate; this is a narrower,
#      fast sanity check that the specific rows this item adds are present.
# ────────────────────────────────────────────────────────────────────────────
REGISTRY="$REPO_ROOT/workflows/scripts/config/setting-registry.tsv"
for var in $ALL_VARS; do
  if grep -qE "^${var}	" "$REGISTRY"; then ok "$var has a setting-registry.tsv row"; else
    bad "$var has a setting-registry.tsv row" "no row found in $REGISTRY"; fi
done

# ── 4. Prose wiring — sweep.md Step 3's item construction references
#      $SWEEP_WORKER_MODEL at the model: field (old `model: <undef>` literal
#      gone from that specific construction site), AND its Workflow args
#      block wires the two machinery-executor settings too (fix A — the
#      setting is a seat inside build-level.mjs, not build.md-only). ────────
sweepModelLine="$(grep -n '^\s*model: ' "$SWEEP_MD" | head -1)"
if [ -z "$sweepModelLine" ]; then bad "sweep.md model: field present" "no 'model:' line found"; else
  if printf '%s' "$sweepModelLine" | grep -q 'SWEEP_WORKER_MODEL'; then
    ok "sweep.md Step 3 item construction references \$SWEEP_WORKER_MODEL"
  else
    bad "sweep.md Step 3 item construction references \$SWEEP_WORKER_MODEL" "line: $sweepModelLine"
  fi
fi
grep -q 'SWEEP_WORKER_MODEL' "$SWEEP_MD" && grep -qE 'source workflows/scripts/build/build\.config\.sh' "$SWEEP_MD" \
  && ok "sweep.md sources build.config.sh (Step 0) and names SWEEP_WORKER_MODEL" \
  || bad "sweep.md sources build.config.sh (Step 0) and names SWEEP_WORKER_MODEL" "one or both missing"
if grep -q 'BUILD_MACHINERY_SOLO_MODEL' "$SWEEP_MD" && grep -q 'BUILD_MACHINERY_BATCH_MODEL' "$SWEEP_MD" \
   && grep -q 'machinerySoloModel' "$SWEEP_MD" && grep -q 'machineryBatchModel' "$SWEEP_MD"; then
  ok "sweep.md names + wires BUILD_MACHINERY_SOLO_MODEL / BUILD_MACHINERY_BATCH_MODEL (not build.md-only)"
else
  bad "sweep.md names + wires BUILD_MACHINERY_SOLO_MODEL / BUILD_MACHINERY_BATCH_MODEL (not build.md-only)" "one or more of the four expected tokens missing"
fi

# ── 5. Prose wiring — fix.md Step 4's item construction references
#      $FIX_WORKER_MODEL at the model: field, AND its Workflow args block
#      wires the two machinery-executor settings too. ───────────────────────
fixModelLine="$(grep -n '^\s*model: ' "$FIX_MD" | head -1)"
if [ -z "$fixModelLine" ]; then bad "fix.md model: field present" "no 'model:' line found"; else
  if printf '%s' "$fixModelLine" | grep -q 'FIX_WORKER_MODEL'; then
    ok "fix.md Step 4 item construction references \$FIX_WORKER_MODEL"
  else
    bad "fix.md Step 4 item construction references \$FIX_WORKER_MODEL" "line: $fixModelLine"
  fi
fi
grep -q 'FIX_WORKER_MODEL' "$FIX_MD" && grep -qE 'source workflows/scripts/build/build\.config\.sh' "$FIX_MD" \
  && ok "fix.md sources build.config.sh (Step 0) and names FIX_WORKER_MODEL" \
  || bad "fix.md sources build.config.sh (Step 0) and names FIX_WORKER_MODEL" "one or both missing"
if grep -q 'BUILD_MACHINERY_SOLO_MODEL' "$FIX_MD" && grep -q 'BUILD_MACHINERY_BATCH_MODEL' "$FIX_MD" \
   && grep -q 'machinerySoloModel' "$FIX_MD" && grep -q 'machineryBatchModel' "$FIX_MD"; then
  ok "fix.md names + wires BUILD_MACHINERY_SOLO_MODEL / BUILD_MACHINERY_BATCH_MODEL (not build.md-only)"
else
  bad "fix.md names + wires BUILD_MACHINERY_SOLO_MODEL / BUILD_MACHINERY_BATCH_MODEL (not build.md-only)" "one or more of the four expected tokens missing"
fi

# ── 6. Prose wiring — build.md Step 0/Step 3 resolve + hand off
#      machinerySoloModel/machineryBatchModel as workflow inputs, and the args
#      table carries both keys alongside the existing machineryBinDir/claimCmd
#      precedent. ────────────────────────────────────────────────────────────
if grep -q 'BUILD_MACHINERY_SOLO_MODEL' "$BUILD_MD" && grep -q 'BUILD_MACHINERY_BATCH_MODEL' "$BUILD_MD"; then
  ok "build.md Step 0 names BUILD_MACHINERY_SOLO_MODEL / BUILD_MACHINERY_BATCH_MODEL"
else
  bad "build.md Step 0 names BUILD_MACHINERY_SOLO_MODEL / BUILD_MACHINERY_BATCH_MODEL" "one or both absent"
fi
if grep -qE 'args = \{.*machinerySoloModel.*machineryBatchModel.*\}' "$BUILD_MD"; then
  ok "build.md Step 3 args table carries machinerySoloModel + machineryBatchModel"
else
  bad "build.md Step 3 args table carries machinerySoloModel + machineryBatchModel" "args = {...} line missing both keys"
fi
# No stale unqualified name should remain anywhere in build.md's prose (the
# rename must be complete, not partial — a lingering bare "machineryModel"
# or "BUILD_MACHINERY_MODEL" is exactly the kind of half-renamed reference
# that reads as a typo or a second, undocumented setting).
if grep -qE '(^|[^A-Za-z_])BUILD_MACHINERY_MODEL([^A-Za-z_]|$)' "$BUILD_MD"; then
  bad "build.md has no stale BUILD_MACHINERY_MODEL (unqualified) reference" "found a match — rename is incomplete"
else
  ok "build.md has no stale BUILD_MACHINERY_MODEL (unqualified) reference"
fi
if grep -qE '(^|[^A-Za-z_])machineryModel([^A-Za-z_]|$)' "$BUILD_MD"; then
  bad "build.md has no stale machineryModel (unqualified) input-key reference" "found a match — rename is incomplete"
else
  ok "build.md has no stale machineryModel (unqualified) input-key reference"
fi

# ── 7. build-level.mjs — the 'haiku' literal REMAINS at both machinery-
#      executor sites, wired via `|| 'haiku'` (NOT `?? 'haiku'` — the
#      BLOCKING empty-string-safety fix, temperloop#982 review). See
#      test_workflow.sh's behavioral + static guards for the fuller
#      (including empty-string-input) check — this is a fast, narrow
#      duplicate at the settings-test layer. ────────────────────────────────
MJS="$REPO_ROOT/claude/workflows/build-level.mjs"
[ -f "$MJS" ] || { echo "FAIL: build-level.mjs not found at $MJS" >&2; exit 1; }
if grep -qF "input.machinerySoloModel || 'haiku'" "$MJS" && grep -qF "input.machineryBatchModel || 'haiku'" "$MJS"; then
  ok "build-level.mjs both machinery-executor sites read input.<name> || 'haiku' (haiku literal retained, empty-string-safe)"
else
  bad "build-level.mjs both machinery-executor sites read input.<name> || 'haiku' (haiku literal retained, empty-string-safe)" "one or both patterns missing"
fi
if grep -qF "?? 'haiku'" "$MJS"; then
  bad "build-level.mjs has no lingering '?? '\''haiku'\''' (the pre-fix, empty-string-unsafe form)" "found a match"
else
  ok "build-level.mjs has no lingering '?? '\''haiku'\''' (the pre-fix, empty-string-unsafe form)"
fi
# The worker seat (item.model) must also collapse an empty string to the
# inherit-session sentinel — `item.model || undefined`, not bare `item.model`.
itemModelHits="$(grep -c 'model: item\.model || undefined' "$MJS" || true)"
if [ "$itemModelHits" -ge 2 ]; then
  ok "build-level.mjs's two worker-seat sites read item.model || undefined ($itemModelHits site(s), empty-string-safe)"
else
  bad "build-level.mjs's two worker-seat sites read item.model || undefined" "found $itemModelHits site(s), want >=2"
fi
if grep -qE 'model: item\.model,' "$MJS"; then
  bad "build-level.mjs has no lingering bare 'model: item.model,' (the pre-fix, empty-string-unsafe form)" "found a match"
else
  ok "build-level.mjs has no lingering bare 'model: item.model,' (the pre-fix, empty-string-unsafe form)"
fi

echo ""
echo "worker-model-settings: $pass passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
