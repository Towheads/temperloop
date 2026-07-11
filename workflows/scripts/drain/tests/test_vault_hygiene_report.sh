#!/usr/bin/env bash
#
# test_vault_hygiene_report.sh — CI tests for vault_hygiene_report.sh.
#
# Builds throwaway fake vaults under mktemp and asserts the probe's behavior:
#   1. Seeded-drift vault (housekeeping checks) → report ALARMs on each
#      seeded condition.
#   2. Seeded-drift vault --format entry → emits a `Status: open` block.
#   3. Clean vault → OK, no alarm (every check, housekeeping AND structural,
#      reports "ok"); --format entry emits nothing.
#   4. Absent root → exit 0 no-op (report notes it; entry emits nothing).
#   5. Quoted `status: "done"` frontmatter is still counted as a closed plan.
#   6. Structural-lint fixture (temperloop#230) → each of the 5 new lints
#      fires on its own seeded violation: folder allowlist, one-file-
#      directory, naming drift, stale plan, kind-misfile.
#   7. Personal/ exemption → a vault whose ONLY drift is inside Personal/
#      (one-file dir, zero-byte garbage, bad-naming) stays entirely clean —
#      no lint, structural or housekeeping, ever flags anything under it.
#   8. Auto-heal (--heal) → the one mechanically-safe class (folder naming-
#      case normalization + wikilink retarget) fires ONLY under --heal, and
#      only for a case-only mismatch; a judgment-shaped violation (an
#      unrecognized top-level folder with no case match) is untouched even
#      with --heal; nothing --heal touches is ever deleted.
#   9. Additive check-registration seam sanity — every check_<name> function
#      in the script has a matching `register_check check_<name>` call (a
#      mechanical proxy for the "purely additive, no shared-line edits"
#      registration contract).
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

# A vault seeded with every HOUSEKEEPING alarm condition (checks 1-5).
make_dirty_vault() {
  local v="$1" i
  mkdir -p "$v/Sessions/_inbox" "$v/Plans" "$v/Context" "$v/Decisions"
  # 25 _inbox stubs (> cap 20).
  for i in $(seq 1 25); do echo "stub $i" > "$v/Sessions/_inbox/stub-$i.md"; done
  # A closed plan (counted) + a live plan (not counted).
  printf -- '---\nstatus: done\n---\nold plan\n'      > "$v/Plans/closed-plan.md"
  printf -- '---\nstatus: executing\n---\nlive plan\n' > "$v/Plans/live-plan.md"
  # pending-decisions ledger over its 120-line cap (130 non-blank lines).
  { for i in $(seq 1 130); do echo "- entry $i"; done; } > "$v/Context/pipeline - pending decisions.md"
  # Garbage: a zero-byte note + a double-dot typo.
  : > "$v/Context/empty.md"
  echo "typo" > "$v/Context/typo..md"
  # A stale last_verified note (2020 → older than 90d).
  printf -- '---\nlast_verified: 2020-01-01\n---\nstale note\n' > "$v/Decisions/stale.md"
}

# A vault with nothing wrong — every housekeeping AND structural lint must
# report "ok"/quiet. Filenames deliberately follow the `<project> - <title>`
# convention so the naming-drift lint (check 8) stays quiet too.
make_clean_vault() {
  local v="$1"
  mkdir -p "$v/Sessions/_inbox" "$v/Plans" "$v/Decisions" "$v/Patterns"
  echo "one stub" > "$v/Sessions/_inbox/recent.md"
  printf -- '---\nstatus: executing\n---\nlive\n' > "$v/Plans/temperloop - live plan.md"
  # A fresh last_verified (today-ish) — not stale.
  printf -- '---\nlast_verified: 2099-01-01\n---\nfresh\n' > "$v/Decisions/temperloop - fresh decision.md"
  # A well-formed Pattern (no date prefix, no verdict/decision keyword).
  echo "reusable approach" > "$v/Patterns/temperloop - reusable retry approach.md"
}

# A vault seeded with every STRUCTURAL-lint alarm condition (checks 6-10,
# temperloop#230). Kept separate from make_dirty_vault so each assertion
# below is attributable to exactly one lint.
make_structural_dirty_vault() {
  local v="$1"
  mkdir -p "$v/Decisions" "$v/Patterns" "$v/Plans" "$v/Projects/lonely" "$v/RandomTop"
  # Check 6: folder allowlist — a top-level folder outside ADR §2.2.
  echo "x" > "$v/RandomTop/f.md"
  # Check 7: one-file-directory — a nested dir holding exactly one file.
  echo "one" > "$v/Projects/lonely/only.md"
  # Check 8: naming drift — no `<project> - <title>` separator.
  echo "content" > "$v/Decisions/BadFileName.md"
  # Check 9: stale plan — status draft, mtime forced far in the past.
  printf -- '---\nstatus: draft\n---\nstale draft\n' > "$v/Plans/temperloop - old draft.md"
  touch -t 202001010000 "$v/Plans/temperloop - old draft.md"
  # Check 10: kind-misfile — a dated, verdict-shaped title sitting in Patterns/.
  echo "x" > "$v/Patterns/2020-01-01 temperloop - spike verdict.md"
}

# A vault whose ONLY drift lives under Personal/ — every lint must stay
# silent (Personal/ is never flagged, per epic temperloop#226).
make_personal_only_dirty_vault() {
  local v="$1"
  mkdir -p "$v/Decisions" "$v/Personal/onefile"
  echo "content" > "$v/Decisions/temperloop - clean decision.md"
  # Shaped to trip: one-file-directory, garbage (zero-byte), naming drift —
  # all under Personal/, so none of them should fire.
  echo "one" > "$v/Personal/onefile/only.md"
  : > "$v/Personal/BadName.md"
  echo "x" > "$v/personal_typo..md"   # NOT under Personal/ — a real double-dot
}

# A vault seeded for the auto-heal path: a top-level folder whose name is a
# case-only mismatch of an ADR-allowed folder (`decisions/` vs `Decisions/`),
# plus a note elsewhere that wikilinks into it, plus a genuinely
# judgment-shaped (non-case-match) unrecognized folder that must never heal.
make_heal_vault() {
  local v="$1"
  mkdir -p "$v/decisions" "$v/Context" "$v/NotAllowedAtAll"
  echo "hi" > "$v/decisions/temperloop - foo.md"
  echo "See [[decisions/temperloop - foo]] for background." > "$v/Context/pipeline - notes.md"
  echo "x" > "$v/NotAllowedAtAll/f.md"
}

# ── Test 1: seeded drift → report alarms (housekeeping) ────────────────────────
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

# ── Test 3: clean vault → OK, empty entry (every lint quiet) ──────────────────
echo "--- test 3: clean vault ---"
CLEAN="$(mktemp -d)"; make_clean_vault "$CLEAN"
creport="$(bash "$SCRIPT" --root "$CLEAN")"
assert_has     "$creport" "OK"    "clean report says OK"
assert_missing "$creport" "ALARM:" "clean report has no ALARM"
assert_has "$creport" "ok folder allowlist: 0 violations"                    "folder allowlist quiet on clean"
assert_has "$creport" "ok one-file-directory: 0"                             "one-file-directory quiet on clean"
assert_has "$creport" "ok naming: 0 drift"                                   "naming drift quiet on clean"
assert_has "$creport" "ok stale plans (draft/approved >30d): 0"              "stale plan quiet on clean"
assert_has "$creport" "ok kind-misfile (Patterns/): 0"                       "kind-misfile quiet on clean"
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

# ── Test 6: structural lints fire on their seeded fixture (temperloop#230) ────
echo "--- test 6: structural lints → seeded fixture ---"
SDIRTY="$(mktemp -d)"; make_structural_dirty_vault "$SDIRTY"
sreport="$(bash "$SCRIPT" --root "$SDIRTY")"
assert_has "$sreport" "ALARM:"                                              "structural report ends with ALARM"
assert_has "$sreport" "allowlist: RandomTop/ — not in the ADR"              "folder-allowlist lint fires"
assert_has "$sreport" "one-file-directory: Projects/lonely/"                "one-file-directory lint fires"
assert_has "$sreport" "naming: Decisions/BadFileName.md"                    "naming-drift lint fires"
assert_has "$sreport" "stale plan: temperloop - old draft.md"               "stale-plan lint fires"
assert_has "$sreport" "kind-misfile: Patterns/2020-01-01 temperloop - spike verdict.md" "kind-misfile lint fires"
rm -rf "$SDIRTY"

# ── Test 7: Personal/ is never flagged by any lint ────────────────────────────
echo "--- test 7: Personal/ exemption ---"
PDIRTY="$(mktemp -d)"; make_personal_only_dirty_vault "$PDIRTY"
preport="$(bash "$SCRIPT" --root "$PDIRTY")"
assert_missing "$preport" "Personal"    "no finding ever names Personal/"
assert_has     "$preport" "garbage files: 1" "the real (non-Personal) double-dot file is still caught"
assert_has     "$preport" "ALARM: 1"    "exactly one alarm (the real file) — none from Personal/'s violations"
rm -rf "$PDIRTY"

# ── Test 8: auto-heal — safe class only, opt-in, never deletes ────────────────
echo "--- test 8: auto-heal ---"
HV="$(mktemp -d)"; make_heal_vault "$HV"
# 8a: without --heal, the case mismatch is propose-only; nothing renamed.
hreport_noheal="$(bash "$SCRIPT" --root "$HV")"
assert_has "$hreport_noheal" "case mismatch of ADR §2.2 folder Decisions/" "case mismatch reported propose-only without --heal"
assert_missing "$hreport_noheal" "healed:" "no heal action taken without --heal"
if [ -d "$HV/decisions" ]; then ok "folder NOT renamed without --heal"; else fail_test "no-heal rename check" "decisions/ was renamed without --heal"; fi
rm -rf "$HV"

# 8b: with --heal, the case mismatch IS healed + wikilinks retargeted; the
# unrelated judgment-shaped folder (NotAllowedAtAll/) is untouched.
HV2="$(mktemp -d)"; make_heal_vault "$HV2"
hreport_heal="$(bash "$SCRIPT" --root "$HV2" --heal)"
assert_has "$hreport_heal" "healed: folder case decisions/ → Decisions/" "case mismatch healed with --heal"
# NOTE: `[ -d path ]` can't distinguish case on a case-insensitive,
# case-preserving filesystem (APFS, the macOS dev shell default) — both
# "Decisions" and "decisions" resolve to the same entry once renamed. `find
# -name` (no -i) compares against the actual on-disk (preserved) name via
# readdir, so it correctly proves the LITERAL case changed on any filesystem,
# case-sensitive (Linux CI) or not (macOS).
renamed_exact="$(find "$HV2" -maxdepth 1 -name 'Decisions' 2>/dev/null)"
old_case_exact="$(find "$HV2" -maxdepth 1 -name 'decisions' 2>/dev/null)"
if [ -n "$renamed_exact" ] && [ -z "$old_case_exact" ]; then
  ok "folder renamed to canonical case with --heal"
else
  fail_test "heal rename" "expected exact-case Decisions/ present and decisions/ gone (renamed_exact=$renamed_exact old_case_exact=$old_case_exact)"
fi
wikilink_content="$(cat "$HV2/Context/pipeline - notes.md" 2>/dev/null)"
case "$wikilink_content" in
  *"[[Decisions/temperloop - foo]]"*) ok "wikilink retargeted to new case" ;;
  *) fail_test "wikilink retarget" "expected [[Decisions/... got: $wikilink_content" ;;
esac
assert_has "$hreport_heal" "allowlist: NotAllowedAtAll/ — not in the ADR" "judgment-shaped folder still reported"
if [ -d "$HV2/NotAllowedAtAll" ]; then ok "judgment-shaped folder NOT auto-renamed/moved even with --heal"; else fail_test "judgment-shaped heal" "NotAllowedAtAll/ was touched"; fi
rm -rf "$HV2"

# 8c: --heal never deletes anything, even garbage / one-file-dir / stale-plan
# / kind-misfile findings that stay propose-only.
HV3="$(mktemp -d)"
mkdir -p "$HV3/Context" "$HV3/Projects/lonely" "$HV3/Plans" "$HV3/Patterns"
: > "$HV3/Context/empty.md"
echo "one" > "$HV3/Projects/lonely/only.md"
printf -- '---\nstatus: draft\n---\nold\n' > "$HV3/Plans/temperloop - old.md"
touch -t 202001010000 "$HV3/Plans/temperloop - old.md"
echo "x" > "$HV3/Patterns/2020-01-01 temperloop - verdict.md"
bash "$SCRIPT" --root "$HV3" --heal >/dev/null
still_present=1
for f in "$HV3/Context/empty.md" "$HV3/Projects/lonely/only.md" "$HV3/Plans/temperloop - old.md" "$HV3/Patterns/2020-01-01 temperloop - verdict.md"; do
  [ -e "$f" ] || still_present=0
done
if [ "$still_present" -eq 1 ]; then ok "--heal deletes nothing (all propose-only findings' files survive)"; else fail_test "--heal deletion check" "at least one file was removed by --heal"; fi
rm -rf "$HV3"

# ── Test 9: additive check-registration seam sanity ────────────────────────────
echo "--- test 9: additive check-registration seam ---"
check_fn_count="$(grep -cE '^check_[A-Za-z0-9_]+\(\) \{' "$SCRIPT")"
register_call_count="$(grep -cE '^register_check check_[A-Za-z0-9_]+$' "$SCRIPT")"
if [ "$check_fn_count" -gt 0 ] && [ "$check_fn_count" -eq "$register_call_count" ]; then
  ok "every check_<name> function has exactly one register_check call ($check_fn_count checks)"
else
  fail_test "seam registration count" "check_fn_count=$check_fn_count register_call_count=$register_call_count"
fi
# The run loop itself must be the single generic dispatcher — exactly one
# `for ... in "${CHECKS[@]}"` loop, so a new check never needs a second one.
run_loop_count="$(grep -cE '^for .* in "\$\{CHECKS\[@\]\}"; do$' "$SCRIPT")"
if [ "$run_loop_count" -eq 1 ]; then ok "exactly one generic CHECKS[] run loop"; else fail_test "run loop count" "expected 1, got $run_loop_count"; fi

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_vault_hygiene_report: FAIL"
  exit 1
fi
echo "test_vault_hygiene_report: OK"
