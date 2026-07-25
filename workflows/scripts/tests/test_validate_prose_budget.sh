#!/usr/bin/env bash
#
# test_validate_prose_budget.sh — fixture + real-tree tests for
# workflows/scripts/validate-prose-budget.sh (temperloop#719, item
# prose-budget-gate / #725).
#
# Covers: green-at-baseline on the unmodified real tree (the ratchet's own
# "merges green by construction" acceptance bullet); a demonstrated TIER-2
# overage (the largest tracked file exceeds a lowered cap); a demonstrated
# TIER-1-ONLY breach via a real compose-seam fixture (a scratch clone whose
# install-claude-md.sh is patched to inflate the composed render with ZERO
# per-file source change — proving the failure message's "every file flat"
# claim is actually true, not just asserted); the failure-message contract
# (file/count/cap/both remediation paths named, tier-1 prints the full
# tier-2 breakdown); and the input-validation error paths (missing/
# non-numeric cap knobs, missing counting script, a failing count-prose.sh
# propagated rather than swallowed).
#
# Zero network. The tier-1-only-breach fixture uses a `git clone --local
# --no-hardlinks` of THIS checkout (read-only source; the clone's checked-out
# working files are independent copies, so patching the clone's
# install-claude-md.sh cannot perturb this checkout) — mirrors this repo's
# existing sandbox_bootstrap_checkout convention of cloning the real tree for
# an end-to-end fixture, without pulling in that heavier CLI-install
# machinery this test doesn't need.
#
# Usage: bash workflows/scripts/tests/test_validate_prose_budget.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/validate-prose-budget.sh"
COUNT_PROSE="$REPO/workflows/scripts/count-prose.sh"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find: $needle" ;;
  esac
}
assert_not_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) fail_test "$name" "expected NOT to find: $needle" ;;
    *) ok "$name" ;;
  esac
}
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then ok "$name"; else fail_test "$name" "expected '$want', got '$got'"; fi
}
assert_rc() {
  local got="$1" want="$2" name="$3"
  if [ "$got" -eq "$want" ]; then ok "$name"; else fail_test "$name" "expected exit $want, got $got"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-validate-prose-budget.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── 1. real-tree happy path: green at baseline (no unrelated PR blocked) ────
echo "--- 1. real-tree happy path (green at baseline) ---"
out="$(bash "$SCRIPT" 2>&1)"; rc=$?
assert_rc "$rc" 0 "unmodified real tree exits 0 (ratchet seeded green)"
assert_has "$out" "OK — prose budget clean" "reports the OK summary line"
assert_has "$out" "tier-1" "OK summary names tier-1"
assert_has "$out" "tier-2" "OK summary names tier-2"

# cross-check against count-prose.sh's own real-tree report directly, so this
# test never hardcodes the current baseline numbers (which will legitimately
# keep moving as prose is trimmed/added under later ratchet-tightening PRs).
count_out="$(bash "$COUNT_PROSE" 2>&1)"
real_tier1="$(printf '%s\n' "$count_out" | sed -n '1p' | sed -E 's/^.*render: ([0-9]+) lines.*$/\1/')"
real_tier2_max="$(printf '%s\n' "$count_out" | awk '/^TIER-2 per-file/{p=1;next} /^$/{p=0} p{print $1}' | sort -rn | head -1)"
assert_has "$out" "tier-1 $real_tier1/" "OK summary's tier-1 count matches count-prose.sh's own report"

# ── 2. TIER-2 overage: lower the per-file cap below the largest real file ──
echo "--- 2. demonstrated red: TIER-2 overage ---"
bad_cap=$((real_tier2_max - 1))
out2="$(PROSE_BUDGET_TIER2_FILE_CAP="$bad_cap" bash "$SCRIPT" 2>&1)"; rc2=$?
assert_rc "$rc2" 1 "a per-file cap below the largest real file exits 1"
assert_has "$out2" "PROSE-BUDGET TIER-2:" "failure names the TIER-2 violation"
assert_has "$out2" "$real_tier2_max lines exceeds the per-file cap of $bad_cap lines" "failure message names the COUNT and the CAP"
assert_has "$out2" "PROSE_BUDGET_TIER2_FILE_CAP" "failure message names the cap knob"
assert_has "$out2" "Remediation: trim" "failure message offers the trim remediation path"
assert_has "$out2" "open a config PR raising PROSE_BUDGET_TIER2_FILE_CAP" "failure message offers the cap-raise-config-PR remediation path"
assert_has "$out2" "knob-registry.tsv row, in the SAME PR" "failure message names the registry-row-in-same-PR requirement"
# a TIER-2-only breach must NOT print the tier-1 seam-attribution breakdown
# (that's reserved for an actual tier-1 breach — see test 4 below).
assert_not_has "$out2" "PROSE-BUDGET TIER-1:" "a pure tier-2 breach does not also report a tier-1 violation"

# ── 3. TIER-1 overage (cap-override form): the composed render alone ───────
echo "--- 3. demonstrated red: TIER-1 overage (cap-override) ---"
bad_t1_cap=$((real_tier1 - 1))
out3="$(PROSE_BUDGET_TIER1_CAP="$bad_t1_cap" bash "$SCRIPT" 2>&1)"; rc3=$?
assert_rc "$rc3" 1 "a tier-1 cap below the real composed count exits 1"
assert_has "$out3" "PROSE-BUDGET TIER-1:" "failure names the TIER-1 violation"
assert_has "$out3" "$real_tier1 lines, exceeding the cap of $bad_t1_cap lines" "failure message names the COUNT and the CAP"
assert_has "$out3" "PROSE_BUDGET_TIER1_CAP" "failure message names the cap knob"
assert_has "$out3" "Full TIER-2 per-file breakdown" "a tier-1 failure prints the full per-file breakdown alongside the composed total"
assert_has "$out3" "claude/CLAUDE.kernel.md" "the printed breakdown includes the kernel doc's own per-file line"
assert_has "$out3" "TIER-2 total:" "the printed breakdown includes the tier-2 total line"

# ── 4. TIER-1-ONLY breach: a real compose-seam fixture, zero per-file
#      change — the case the failure message's seam-attribution claim exists
#      to make legible ─────────────────────────────────────────────────────
echo "--- 4. demonstrated red: TIER-1-only breach (compose-seam fixture) ---"
FIXTURE="$TMP/seam-fixture"
if ! git clone --local --no-hardlinks --quiet "$REPO" "$FIXTURE" 2>"$TMP/clone.err"; then
  fail_test "seam-fixture clone" "git clone --local failed: $(cat "$TMP/clone.err")"
else
  install_md="$FIXTURE/workflows/scripts/install-claude-md.sh"
  # Patch ONLY the kernel-only render's call site to append fixed padding —
  # claude/CLAUDE.kernel.md and every other claude/**/*.md file in the clone
  # are byte-identical to this checkout's, so tier-2 per-file counts cannot
  # move; only the composed render (tier-1) is inflated. python3 (not
  # perl/sed -i) for the patch — portable across the macOS/Linux CI legs and
  # avoids BSD-vs-GNU sed -i syntax divergence entirely.
  python3 - "$install_md" <<'PYEOF' 2>"$TMP/patch.err" || true
import sys
path = sys.argv[1]
anchor = 'render_kernel_doc "$kernel" >"$tmp"\n'
padding = (
    anchor
    + '  printf \'\\n<!-- FIXTURE PADDING -->\\n\' >>"$tmp"\n'
    + '  seq 1 50 | sed \'s/^/FIXTURE PADDING LINE /\' >>"$tmp"\n'
)
with open(path, encoding="utf-8") as f:
    text = f.read()
assert text.count(anchor) == 1, f"expected exactly one anchor occurrence, found {text.count(anchor)}"
text = text.replace(anchor, padding, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
  if ! grep -q "FIXTURE PADDING" "$install_md" 2>/dev/null; then
    fail_test "seam-fixture patch" "perl patch did not apply (install-claude-md.sh unchanged): $(cat "$TMP/patch.err" 2>/dev/null)"
  else
    ok "seam-fixture: patched the clone's compose seam without touching any claude/**/*.md file"

    fixture_count_out="$(COUNT_PROSE_ROOT="$FIXTURE" bash "$COUNT_PROSE" 2>&1)"
    fixture_tier1="$(printf '%s\n' "$fixture_count_out" | sed -n '1p' | sed -E 's/^.*render: ([0-9]+) lines.*$/\1/')"
    if [ -n "$fixture_tier1" ] && [ "$fixture_tier1" -gt "$real_tier1" ]; then
      ok "seam fixture actually inflates the tier-1 composed count ($real_tier1 -> $fixture_tier1)"
    else
      fail_test "seam fixture inflates tier-1" "expected > $real_tier1, got '$fixture_tier1'"
    fi
    # the per-file table itself must be BYTE-IDENTICAL between the real tree
    # and the fixture — this is the "every file flat" property the failure
    # message claims when it prints the breakdown.
    real_table="$(printf '%s\n' "$count_out" | sed -n '/^TIER-2 per-file line counts/,$p')"
    fixture_table="$(printf '%s\n' "$fixture_count_out" | sed -n '/^TIER-2 per-file line counts/,$p')"
    assert_eq "$fixture_table" "$real_table" "the TIER-2 per-file table is byte-identical between the real tree and the seam fixture"

    out4="$(COUNT_PROSE_ROOT="$FIXTURE" bash "$SCRIPT" 2>&1)"; rc4=$?
    assert_rc "$rc4" 1 "validate-prose-budget.sh is RED against the seam fixture"
    assert_has "$out4" "PROSE-BUDGET TIER-1:" "the seam fixture's failure names the TIER-1 violation"
    assert_not_has "$out4" "PROSE-BUDGET TIER-2:" "the seam fixture's failure does NOT also report a tier-2 violation (zero per-file change)"
    assert_has "$out4" "$fixture_tier1 lines, exceeding the cap" "the seam fixture's failure names the inflated composed count"
    assert_has "$out4" "TIER-2 total: $(printf '%s\n' "$count_out" | grep -oE 'TIER-2 total: [0-9]+' | sed -E 's/^TIER-2 total: //') lines across" "the seam fixture's printed breakdown shows the UNCHANGED tier-2 total — seam-attributable on sight"
  fi
fi

# ── 5. input-validation error paths ─────────────────────────────────────────
echo "--- 5. input-validation error paths ---"

# 5a. missing counting script.
out5a="$(COUNT_PROSE_BIN="$TMP/does-not-exist.sh" bash "$SCRIPT" 2>&1)"; rc5a=$?
assert_rc "$rc5a" 1 "missing count-prose.sh binary exits 1"
assert_has "$out5a" "counting script not found" "missing counting-script error is named"

# 5b. non-numeric tier-1 cap.
out5b="$(PROSE_BUDGET_TIER1_CAP=notanumber bash "$SCRIPT" 2>&1)"; rc5b=$?
assert_rc "$rc5b" 1 "non-numeric PROSE_BUDGET_TIER1_CAP exits 1"
assert_has "$out5b" "PROSE_BUDGET_TIER1_CAP is not a positive integer" "non-numeric tier-1 cap error is named"

# 5c. non-numeric tier-2 cap.
out5c="$(PROSE_BUDGET_TIER2_FILE_CAP=notanumber bash "$SCRIPT" 2>&1)"; rc5c=$?
assert_rc "$rc5c" 1 "non-numeric PROSE_BUDGET_TIER2_FILE_CAP exits 1"
assert_has "$out5c" "PROSE_BUDGET_TIER2_FILE_CAP is not a positive integer" "non-numeric tier-2 cap error is named"

# 5d. a failing count-prose.sh is propagated, never silently swallowed.
FAKE_COUNT="$TMP/fake-count-prose.sh"
cat >"$FAKE_COUNT" <<'EOF'
#!/usr/bin/env bash
echo "fake count-prose: simulated failure" >&2
exit 1
EOF
chmod +x "$FAKE_COUNT"
out5d="$(COUNT_PROSE_BIN="$FAKE_COUNT" bash "$SCRIPT" 2>&1)"; rc5d=$?
assert_rc "$rc5d" 1 "a failing count-prose.sh propagates as exit 1"
assert_has "$out5d" "count-prose.sh failed" "propagated failure is named"
assert_has "$out5d" "simulated failure" "the underlying count-prose.sh error text is surfaced, not swallowed"

# 5e. a count-prose.sh whose report can't be parsed (tier-1 line missing).
FAKE_COUNT2="$TMP/fake-count-prose-2.sh"
cat >"$FAKE_COUNT2" <<'EOF'
#!/usr/bin/env bash
echo "not a tier-1 line at all"
EOF
chmod +x "$FAKE_COUNT2"
out5e="$(COUNT_PROSE_BIN="$FAKE_COUNT2" bash "$SCRIPT" 2>&1)"; rc5e=$?
assert_rc "$rc5e" 1 "an unparseable count-prose.sh report exits 1"
assert_has "$out5e" "could not parse a TIER-1 line count" "the tier-1 parse-failure error is named"

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_validate_prose_budget: FAIL"
  exit 1
fi
echo "test_validate_prose_budget: OK"
