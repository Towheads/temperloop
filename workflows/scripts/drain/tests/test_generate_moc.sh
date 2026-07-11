#!/usr/bin/env bash
#
# test_generate_moc.sh — CI tests for generate_moc.sh (temperloop#231, epic
# #226 "generated navigation").
#
# Builds throwaway fake vaults under mktemp and asserts the generator's
# behavior:
#   1. Seeded vault → Index.md + a project's Home.md are generated, carrying
#      the do-not-hand-edit banner, correctly picking up BOTH detection
#      signals (filename prefix and project/<name> tag).
#   2. Idempotent: a second run against an unchanged store produces
#      byte-identical Index.md and Home.md.
#   3. Absent root → graceful no-op (exit 0, nothing written; --format entry
#      prints nothing).
#   4. Empty store (root exists, zero notes) → graceful no-op, same as an
#      absent Projects/ convention — nothing written.
#   5. A pre-existing hand-authored Index.md (no banner) is never
#      overwritten; the run reports a conflict instead, and --format entry
#      emits a `Status: open` proposal block.
#   6. Regeneration reflects a real store change (not just a no-change
#      replay) — adding a new project's note updates Index.md on the next
#      run.
#
# Usage: bash workflows/scripts/drain/tests/test_generate_moc.sh
# Exit 0 = all pass, exit 1 = one or more failures.

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/drain/generate_moc.sh"

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

# ── Fixture builder: a vault with two projects, one via filename prefix,
#    one via a project/<name> tag only. ─────────────────────────────────────
make_seeded_vault() {
  local v="$1"
  mkdir -p "$v/Decisions" "$v/Patterns" "$v/Context"
  # Project "temperloop" via filename prefix.
  printf -- '---\ntags: [decision]\n---\nbody\n' > "$v/Decisions/temperloop - Branch naming convention.md"
  # Project "stageFind" via a project/<name> tag ONLY (no matching prefix).
  printf -- '---\ntags: [pattern, project/stageFind]\n---\nbody\n' > "$v/Patterns/Some reusable approach.md"
  # A note with no frontmatter and no prefix — must never surface as a project.
  printf 'plain note, no frontmatter\n' > "$v/Context/Unrelated note.md"
  # A Plans/-style `<date> <project> - <title>.md` name must NOT be detected
  # as a filename-prefix project (its leading token has a space in it).
  mkdir -p "$v/Plans"
  printf 'plan body\n' > "$v/Plans/2026-07-04 temperloop - some plan.md"
}

# ── Test 1: seeded vault → generated Index.md + Home.md, both signals ─────────
echo "--- test 1: seeded vault → generated MOCs ---"
V1="$(mktemp -d)"; make_seeded_vault "$V1"
report1="$(bash "$SCRIPT" --root "$V1")"
assert_has "$report1" "generated: Index.md"                     "Index.md generated"
assert_has "$report1" "generated: Projects/temperloop/Home.md"  "temperloop Home.md generated (filename-prefix signal)"
assert_has "$report1" "generated: Projects/stageFind/Home.md"   "stageFind Home.md generated (tag-only signal)"

idx1="$(cat "$V1/Index.md" 2>/dev/null || echo MISSING)"
assert_has "$idx1" "GENERATED FILE — DO NOT EDIT BY HAND"       "Index.md carries the do-not-hand-edit banner"
assert_has "$idx1" "[[Projects/temperloop/Home]]"                "Index.md links temperloop"
assert_has "$idx1" "[[Projects/stageFind/Home]]"                 "Index.md links stageFind"

home_tl="$(cat "$V1/Projects/temperloop/Home.md" 2>/dev/null || echo MISSING)"
assert_has "$home_tl" "GENERATED FILE — DO NOT EDIT BY HAND"     "temperloop Home.md carries the banner"
assert_has "$home_tl" "[[Decisions/temperloop - Branch naming convention]]" "temperloop Home.md lists its note"

home_sf="$(cat "$V1/Projects/stageFind/Home.md" 2>/dev/null || echo MISSING)"
assert_has "$home_sf" "[[Patterns/Some reusable approach]]"      "stageFind Home.md lists its tag-only note"

# The unrelated note and the Plans/-style dated file must not have spawned a
# bogus project.
if [ -d "$V1/Projects" ]; then
  proj_count="$(find "$V1/Projects" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
  if [ "$proj_count" = "2" ]; then ok "exactly two projects detected (no false positives)"; else fail_test "project count" "expected 2, got $proj_count"; fi
fi

# ── Test 2: idempotency — byte-identical second run ────────────────────────────
echo "--- test 2: idempotency ---"
IDX_COPY="$(mktemp)"; cp "$V1/Index.md" "$IDX_COPY"
HOME_COPY="$(mktemp)"; cp "$V1/Projects/temperloop/Home.md" "$HOME_COPY"
bash "$SCRIPT" --root "$V1" >/dev/null
if diff -q "$IDX_COPY" "$V1/Index.md" >/dev/null 2>&1; then ok "Index.md byte-identical across two runs"; else fail_test "Index.md idempotency" "diff found"; fi
if diff -q "$HOME_COPY" "$V1/Projects/temperloop/Home.md" >/dev/null 2>&1; then ok "Home.md byte-identical across two runs"; else fail_test "Home.md idempotency" "diff found"; fi
rm -f "$IDX_COPY" "$HOME_COPY"

# ── Test 6 (grouped here — reuses V1): regeneration reflects a real change ────
echo "--- test 6: regeneration reflects a new project ---"
printf -- '---\ntags: [decision, project/ssmobile]\n---\nbody\n' > "$V1/Decisions/ssmobile - New thing.md"
bash "$SCRIPT" --root "$V1" >/dev/null
idx2="$(cat "$V1/Index.md")"
assert_has "$idx2" "[[Projects/ssmobile/Home]]" "Index.md picks up a newly-added project on regeneration"
rm -rf "$V1"

# ── Test 3: absent root → graceful no-op ───────────────────────────────────────
echo "--- test 3: absent root ---"
ABSENT="$(mktemp -d)"; rmdir "$ABSENT"
areport="$(bash "$SCRIPT" --root "$ABSENT")"; arc=$?
if [ "$arc" -eq 0 ]; then ok "absent root exits 0"; else fail_test "absent root exit" "got $arc"; fi
assert_has "$areport" "root not found" "absent root notes it"
if [ -e "$ABSENT" ]; then fail_test "absent root no-write" "root was created"; else ok "absent root: nothing created"; fi
aentry="$(bash "$SCRIPT" --root "$ABSENT" --format entry)"; aerc=$?
if [ "$aerc" -eq 0 ] && [ -z "$aentry" ]; then ok "absent root --format entry: empty, exit 0"; else fail_test "absent entry" "rc=$aerc out=$aentry"; fi

# ── Test 4: empty store (root exists, zero notes) → graceful no-op ────────────
echo "--- test 4: empty store ---"
EMPTY="$(mktemp -d)"
ereport="$(bash "$SCRIPT" --root "$EMPTY")"; erc=$?
if [ "$erc" -eq 0 ]; then ok "empty store exits 0"; else fail_test "empty store exit" "got $erc"; fi
assert_has "$ereport" "no projects detected" "empty store notes nothing to generate"
if [ -e "$EMPTY/Index.md" ] || [ -d "$EMPTY/Projects" ]; then
  fail_test "empty store no-write" "Index.md or Projects/ was created"
else
  ok "empty store: no Index.md, no Projects/ created"
fi
rm -rf "$EMPTY"

# ── Test 5: hand-authored Index.md is never overwritten — conflict reported ───
echo "--- test 5: hand-authored content preserved (refuse + propose) ---"
V5="$(mktemp -d)"; mkdir -p "$V5/Decisions"
printf -- '---\ntags: [decision]\n---\nbody\n' > "$V5/Decisions/foo - thing.md"
printf 'hand-written index, please keep me\n' > "$V5/Index.md"
c5report="$(bash "$SCRIPT" --root "$V5")"; c5rc=$?
if [ "$c5rc" -eq 0 ]; then ok "conflict run still exits 0 (report-only, not a hard failure)"; else fail_test "conflict exit" "got $c5rc"; fi
assert_has "$c5report" "skipped (hand-authored, not overwritten): Index.md" "conflict reported for Index.md"
idx5="$(cat "$V5/Index.md")"
if [ "$idx5" = "hand-written index, please keep me" ]; then ok "hand-authored Index.md content untouched"; else fail_test "hand-authored preserved" "content changed: $idx5"; fi
# The project Home.md (no pre-existing conflict) still generates normally.
if [ -f "$V5/Projects/foo/Home.md" ]; then ok "non-conflicting Home.md still generated"; else fail_test "Home.md generated" "missing"; fi
c5entry="$(bash "$SCRIPT" --root "$V5" --format entry)"
assert_has "$c5entry" "· moc generation conflict ·" "entry format has conflict heading"
assert_has "$c5entry" "**Status:** open"            "entry format carries Status: open"
assert_has "$c5entry" "Index.md"                    "entry format names the conflicting file"
rm -rf "$V5"

# ── Test: usage error ───────────────────────────────────────────────────────
echo "--- test: bad --format ---"
bash "$SCRIPT" --format bogus >/dev/null 2>&1; badrc=$?
if [ "$badrc" -eq 2 ]; then ok "unknown --format exits 2"; else fail_test "bad format exit" "got $badrc"; fi

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_generate_moc: FAIL"
  exit 1
fi
echo "test_generate_moc: OK"
