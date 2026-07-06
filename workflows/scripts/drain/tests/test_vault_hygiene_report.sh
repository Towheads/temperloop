#!/usr/bin/env bash
#
# test_vault_hygiene_report.sh — CI tests for vault_hygiene_report.sh.
#
# Builds throwaway fake vaults under mktemp and asserts the probe's behavior:
#   1. Seeded-drift vault → report ALARMs on each seeded condition.
#   2. Seeded-drift vault --format entry → emits a `Status: open` block.
#   3. Clean vault → OK, no alarm; --format entry emits nothing.
#   4. Absent root → exit 0 no-op (report notes it; entry emits nothing).
#   5. Quoted `status: "done"` frontmatter is still counted as a closed plan.
#
# Usage: bash workflows/scripts/drain/tests/test_vault_hygiene_report.sh
# Exit 0 = all pass, exit 1 = one or more failures.

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/drain/vault_hygiene_report.sh"

pass=0
fail=0

ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

# Assert $haystack contains $needle (literal).
assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find: $needle" ;;
  esac
}
assert_missing() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) fail_test "$name" "did not expect: $needle" ;;
    *) ok "$name" ;;
  esac
}

# ── Fixture builders ──────────────────────────────────────────────────────────

# A vault seeded with every alarm condition.
make_dirty_vault() {
  local v="$1" i
  mkdir -p "$v/Sessions/_inbox" "$v/Plans" "$v/Context" "$v/Decisions"
  # 25 _inbox stubs (> cap 20).
  for i in $(seq 1 25); do echo "stub $i" > "$v/Sessions/_inbox/stub-$i.md"; done
  # A closed plan (counted) + a live plan (not counted).
  printf -- '---\nstatus: done\n---\nold plan\n'      > "$v/Plans/closed-plan.md"
  printf -- '---\nstatus: executing\n---\nlive plan\n' > "$v/Plans/live-plan.md"
  # pending-decisions ledger over its 120-line cap (130 non-blank lines).
  { for i in $(seq 1 130); do echo "- entry $i"; done; } > "$v/Context/foundation - pending decisions.md"
  # Garbage: a zero-byte note + a double-dot typo.
  : > "$v/Context/empty.md"
  echo "typo" > "$v/Context/typo..md"
  # A stale last_verified note (2020 → older than 90d).
  printf -- '---\nlast_verified: 2020-01-01\n---\nstale note\n' > "$v/Decisions/stale.md"
}

# A vault with nothing wrong.
make_clean_vault() {
  local v="$1"
  mkdir -p "$v/Sessions/_inbox" "$v/Plans" "$v/Context" "$v/Decisions"
  echo "one stub" > "$v/Sessions/_inbox/recent.md"
  printf -- '---\nstatus: executing\n---\nlive\n' > "$v/Plans/live.md"
  # A fresh last_verified (today-ish) — not stale.
  printf -- '---\nlast_verified: 2099-01-01\n---\nfresh\n' > "$v/Decisions/fresh.md"
}

# ── Test 1: seeded drift → report alarms ──────────────────────────────────────
echo "--- test 1: seeded drift → report ---"
DIRTY="$(mktemp -d)"; make_dirty_vault "$DIRTY"
report="$(bash "$SCRIPT" --root "$DIRTY")"
assert_has "$report" "ALARM:"                        "report ends with ALARM"
assert_has "$report" "_inbox: 25 stubs"              "inbox stub count reported"
assert_has "$report" "closed plans still in Plans/: 1" "closed plan counted"
assert_has "$report" "ledger over cap"               "over-cap ledger flagged"
assert_has "$report" "garbage files: 2"              "zero-byte + double-dot counted"
assert_has "$report" "stale last_verified (>90d): 1" "stale note tallied"
rm -rf "$DIRTY"

# ── Test 2: seeded drift --format entry → open block ──────────────────────────
echo "--- test 2: seeded drift → entry block ---"
DIRTY2="$(mktemp -d)"; make_dirty_vault "$DIRTY2"
entry="$(bash "$SCRIPT" --root "$DIRTY2" --format entry)"
assert_has "$entry" "· vault hygiene ·"    "entry has hygiene heading"
assert_has "$entry" "**Status:** open"     "entry carries Status: open"
assert_has "$entry" "_inbox: 25 stubs"     "entry lists inbox finding"
rm -rf "$DIRTY2"

# ── Test 3: clean vault → OK, empty entry ─────────────────────────────────────
echo "--- test 3: clean vault ---"
CLEAN="$(mktemp -d)"; make_clean_vault "$CLEAN"
creport="$(bash "$SCRIPT" --root "$CLEAN")"
assert_has     "$creport" "OK"    "clean report says OK"
assert_missing "$creport" "ALARM:" "clean report has no ALARM"
centry="$(bash "$SCRIPT" --root "$CLEAN" --format entry)"
if [ -z "$centry" ]; then ok "clean --format entry emits nothing"; else fail_test "clean entry" "expected empty, got: $centry"; fi
rm -rf "$CLEAN"

# ── Test 4: absent root → exit 0 no-op ────────────────────────────────────────
echo "--- test 4: absent root ---"
ABSENT="$(mktemp -d)"; rmdir "$ABSENT"   # a path guaranteed not to exist
areport="$(bash "$SCRIPT" --root "$ABSENT")"; arc=$?
if [ "$arc" -eq 0 ]; then ok "absent root exits 0"; else fail_test "absent root exit" "got $arc"; fi
assert_has "$areport" "root not found" "absent root notes it"
aentry="$(bash "$SCRIPT" --root "$ABSENT" --format entry)"; aerc=$?
if [ "$aerc" -eq 0 ] && [ -z "$aentry" ]; then ok "absent root --format entry: empty, exit 0"; else fail_test "absent entry" "rc=$aerc out=$aentry"; fi

# ── Test 5: quoted status: "done" still counts ────────────────────────────────
echo "--- test 5: quoted status ---"
QV="$(mktemp -d)"; mkdir -p "$QV/Plans"
printf -- '---\nstatus: "done"\n---\n' > "$QV/Plans/q.md"
qreport="$(bash "$SCRIPT" --root "$QV")"
assert_has "$qreport" "closed plans still in Plans/: 1" "quoted status counted as closed"
rm -rf "$QV"

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_vault_hygiene_report: FAIL"
  exit 1
fi
echo "test_vault_hygiene_report: OK"
