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
#  10. Repeat-mistake detector (temperloop#234) → a NEW friction-ledger row
#      that shares enough vocabulary with an existing Mistakes/ note's title
#      + trigger: frontmatter fires as a retrieval failure; an unrelated row
#      stays quiet; a matching row outside the recency window is skipped; no
#      ledger / no Mistakes/ is a quiet no-op (stranger test).
#  11. Read-log telemetry surfacing (temperloop#238) → a fixture read log
#      mixing script-plane AND agent-plane lines tallies reads/session,
#      most-read note, never-read notes, and search→read conversion
#      correctly regardless of which plane emitted a line; a missing/empty
#      read log is a quiet no-op (stranger test) that skips the never-read
#      walk entirely; the check never sets an ALARM.
#  12. Read-path lints (temperloop#239): orphan-pattern (no inbound T0 link
#      and not retrieval: search-only) and missing-trigger (a new Patterns/
#      note with no trigger: frontmatter, scoped to a recency window) fire
#      on their seeded fixtures and stay quiet on a T0-linked / search-only /
#      trigger-carrying / recency-exempt note; an absent T0 inventory
#      degrades orphan-pattern gracefully (skipped, never a false alarm).
#  13. Telemetry-coverage lint (temperloop#239, the mcp_obsidian EOL cutover
#      gate) → an Obsidian-backed vault whose KNOWLEDGE_READ_LOG_AGENT_MATCHERS
#      drops a known transport's pattern fires; the real default matcher list
#      covers both known transports and stays quiet; a non-Obsidian-backed
#      root is a quiet no-op regardless of the matcher list.
#  14. Controls lint (temperloop#239, ADR §2.3a/§2.4/§2.8) → against a
#      fixture knob-registry.tsv (KNOB_REGISTRY_FILE override): a dead dial
#      (matched row's owning-script missing), an orphaned control (no row
#      names the file), and a machine-read file living outside Controls/ all
#      fire; a healthy registry-matched control never fires; no Controls/
#      folder is a quiet no-op.
#  15. Heat score + review queue (temperloop#240, ADR §2.6-2.7) → a fixture
#      with distinct reads/links/last_verified combos computes the
#      documented weighted heat score and ranks the top-5 review queue by
#      heat × staleness correctly; a no-read-log invocation degrades to a
#      links+recency-only ranking with no error; a 7-candidate fixture
#      proves the queue caps at exactly 5 entries by construction; the
#      orphan-pattern/stale-plan/repeat-mistake flags already raised by
#      checks 9/11/13 fold into the queue line as a `[tag]` annotation; an
#      empty store reports 0 candidates with no queue and no error; and the
#      check never contributes an ALARM on its own.
#
# Usage: bash workflows/scripts/drain/tests/test_vault_hygiene_report.sh
# Exit 0 = all pass, exit 1 = one or more failures.

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/drain/vault_hygiene_report.sh"

# Isolate every invocation below from the REAL machine's knowledge-store read
# log: check_read_stats (temperloop#238) runs on every $SCRIPT invocation and
# resolves KNOWLEDGE_READ_LOG via knowledge_store.sh's own default
# (${XDG_STATE_HOME:-$HOME/.local/state}/foundation/knowledge-reads.log) when
# unset — a real, populated file on any machine with normal daily usage.
# Without this override, tests 1-10 (which assert nothing about read-stats
# and never set this var themselves) would silently tally that real log
# instead of staying hermetic. Point it at a guaranteed-nonexistent path by
# default; Test 11's fixtures override it per-invocation for their own
# throwaway logs.
_TEST_ISOLATION_DIR="$(mktemp -d)"
export KNOWLEDGE_READ_LOG="$_TEST_ISOLATION_DIR/no-such-read-log.log"

# Hermetic guard: point every invocation below at a guaranteed-absent
# T0_INVENTORY_FILE by default, so this suite's result never depends on
# whatever the machine running it happens to have at the real
# $HOME/.claude/t0-inventory.txt (the orphan-pattern lint, check 13,
# degrades gracefully — and DETERMINISTICALLY skips — when the artifact is
# absent; without this export, a dev machine with a real composed CLAUDE.md
# would make every fixture below spuriously subject to orphan-pattern
# findings against ITS real T0 inventory instead of this suite's fixtures).
# Tests that specifically exercise T0 coverage override this per-invocation.
export T0_INVENTORY_FILE
T0_INVENTORY_FILE="$(mktemp -u "${TMPDIR:-/tmp}/vault-hygiene-test-no-t0-XXXXXX")"

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
  # A well-formed Pattern (no date prefix, no verdict/decision keyword, and
  # carries trigger: frontmatter so the missing-trigger lint, check 14,
  # stays quiet too).
  printf -- '---\ntrigger: retry backoff, flaky network call\n---\nreusable approach\n' \
    > "$v/Patterns/temperloop - reusable retry approach.md"
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
assert_has "$creport" "ok repeat-mistake:"                                   "repeat-mistake quiet on clean (no ledger/Mistakes)"
assert_has "$creport" "ok orphan-pattern: 0"                                 "orphan-pattern quiet on clean (no T0 inventory)"
assert_has "$creport" "ok missing-trigger: 0"                                "missing-trigger quiet on clean"
assert_has "$creport" "ok telemetry-coverage: 0"                             "telemetry-coverage quiet on clean (not Obsidian-backed)"
assert_has "$creport" "ok controls: 0"                                       "controls quiet on clean (no Controls/ folder)"
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

# ── Test 10: repeat-mistake detector (temperloop#234) ──────────────────────
echo "--- test 10: repeat-mistake detector ---"

# A Mistakes/ note whose title + trigger: frontmatter carry the vocabulary
# the fixtures below match (or deliberately don't match) against.
make_mistake_note() {
  local v="$1"
  mkdir -p "$v/Mistakes"
  printf -- '---\ntags: [mistake, project/temperloop]\ntrigger: BSD stat -f flags, non-portable date parsing\n---\nUse the portable file_mtime() helper instead.\n' \
    > "$v/Mistakes/temperloop - BSD stat flags break Linux CI.md"
}

# 10a: seeded recurrence — a NEW friction row whose evidence shares enough
# vocabulary with an existing Mistakes/ note fires the flag (a retrieval
# failure: the note existed but didn't prevent the recurrence).
RM="$(mktemp -d)"; mkdir -p "$RM/Context"; make_mistake_note "$RM"
today="$(date +%Y-%m-%d)"
echo "- ${today} · temperloop · tool-misuse · vault_hygiene_report.sh used BSD stat -f flags on Linux CI and broke the build" \
  > "$RM/Context/Session friction ledger.md"
rmreport="$(bash "$SCRIPT" --root "$RM")"
assert_has "$rmreport" "repeat-mistake:"                                                  "seeded recurrence fires the flag"
assert_has "$rmreport" "retrieval failure"                                                "flag names it a retrieval failure"
assert_has "$rmreport" "Mistakes/temperloop - BSD stat flags break Linux CI.md"           "flag names the matching Mistakes/ note"
assert_has "$rmreport" "ALARM:"                                                           "seeded recurrence trips an alarm"
rm -rf "$RM"

# 10b: a clean ledger row with no meaningful vocabulary overlap (sharing only
# the project token, "temperloop", is NOT enough to match) stays quiet.
RM2="$(mktemp -d)"; mkdir -p "$RM2/Context"; make_mistake_note "$RM2"
today2="$(date +%Y-%m-%d)"
echo "- ${today2} · temperloop · redundant-status-check · confirmed board cache already fresh before re-polling structure" \
  > "$RM2/Context/Session friction ledger.md"
cleanreport="$(bash "$SCRIPT" --root "$RM2")"
assert_missing "$cleanreport" "repeat-mistake: ${today2}" "unrelated row does not fire the flag"
assert_has     "$cleanreport" "ok repeat-mistake:"         "clean ledger reports ok"
assert_missing "$cleanreport" "ALARM:"                     "clean ledger trips no alarm"
rm -rf "$RM2"

# 10c: recency window — a row that would otherwise match but is dated well
# outside FRICTION_RECENT_DAYS is skipped (this check is scoped to NEW rows).
RM3="$(mktemp -d)"; mkdir -p "$RM3/Context"; make_mistake_note "$RM3"
echo "- 2020-01-01 · temperloop · tool-misuse · vault_hygiene_report.sh used BSD stat -f flags on Linux CI and broke the build" \
  > "$RM3/Context/Session friction ledger.md"
oldreport="$(bash "$SCRIPT" --root "$RM3")"
assert_missing "$oldreport" "repeat-mistake: 2020-01-01" "row outside the recency window is not flagged"
rm -rf "$RM3"

# 10d: stranger test — no friction ledger and/or no Mistakes/ folder is a
# quiet no-op (no alarm, no error) — a bare kernel checkout has neither.
RM4="$(mktemp -d)"
strangerreport="$(bash "$SCRIPT" --root "$RM4")"
assert_has     "$strangerreport" "ok repeat-mistake:"    "no ledger / no Mistakes/ -> quiet no-op"
assert_missing "$strangerreport" "repeat-mistake: 20"    "no ledger / no Mistakes/ -> never flags"
rm -rf "$RM4"

# ── Test 11: read-log telemetry surfacing (temperloop#238) ─────────────────
echo "--- test 11: read-log telemetry surfacing ---"

# 11a: seeded fixture — a read log mixing SCRIPT-plane and AGENT-plane lines
# across two sessions, plus a vault with one never-read note. Hand-crafted
# lines (not routed through the real ks_* dispatch/hook) so the fixture can
# freely control plane/op/session/ordering: s1 searches then reads
# Decisions/a.md twice (once per plane) — a converted search; s2 reads
# Decisions/b.md (agent-plane) then searches with NO subsequent read — an
# unconverted search. Decisions/c.md is never logged at all.
RS="$(mktemp -d)"; mkdir -p "$RS/vault/Decisions"
echo "a" > "$RS/vault/Decisions/a.md"
echo "b" > "$RS/vault/Decisions/b.md"
echo "c" > "$RS/vault/Decisions/c.md"
RSLOG="$RS/knowledge-reads.log"
{
  printf '2026-07-01T00:00:00Z · s1 · script · search · foo query\n'
  printf '2026-07-01T00:00:01Z · s1 · script · read · Decisions/a.md\n'
  printf '2026-07-01T00:00:02Z · s1 · agent · read · Decisions/a\n'
  printf '2026-07-01T00:00:03Z · s2 · agent · read · Decisions/b.md\n'
  printf '2026-07-01T00:00:04Z · s2 · script · search · bar query\n'
} > "$RSLOG"
rsreport="$(KNOWLEDGE_READ_LOG="$RSLOG" bash "$SCRIPT" --root "$RS/vault")"
assert_has "$rsreport" "info read-stats: 3 read(s), 2 search(es), 2 session(s) (1.5 reads/session)" "reads/session tally (both planes counted alike)"
assert_has "$rsreport" "info read-stats most-read: Decisions/a.md (2x)"                            "most-read note (script + agent lines both count toward the same doc)"
assert_has "$rsreport" "info read-stats search→read conversion: 1/2 (50%)"                          "search→read conversion (one converted, one not)"
assert_has "$rsreport" "info read-stats never-read: 1/3 note(s) never read"                         "never-read tally names Decisions/c.md via its count"
rm -rf "$RS"

# 11b: agent-plane-only reads still tally identically to script-plane —
# isolates the "plane-agnostic" claim from 11a's mixed fixture.
RS2="$(mktemp -d)"; mkdir -p "$RS2/vault/Decisions"
echo "a" > "$RS2/vault/Decisions/a.md"
RSLOG2="$RS2/knowledge-reads.log"
printf '2026-07-01T00:00:00Z · s1 · agent · read · Decisions/a.md\n' > "$RSLOG2"
rsreport2="$(KNOWLEDGE_READ_LOG="$RSLOG2" bash "$SCRIPT" --root "$RS2/vault")"
assert_has "$rsreport2" "info read-stats: 1 read(s), 0 search(es), 1 session(s) (1.0 reads/session)" "agent-plane-only line is tallied as a read"
assert_has "$rsreport2" "info read-stats never-read: 0/1 note(s) never read"                          "agent-plane read satisfies never-read for its note"
rm -rf "$RS2"

# 11c: missing/empty read log → quiet no-op (stranger test); never-read walk
# is skipped entirely (not reported as 100%), and no ALARM is ever set by
# this check regardless of read-log state.
RS3="$(mktemp -d)"; mkdir -p "$RS3/vault/Decisions"
echo "a" > "$RS3/vault/Decisions/a.md"
rsreport3="$(KNOWLEDGE_READ_LOG="$RS3/no-such-log" bash "$SCRIPT" --root "$RS3/vault")"
assert_has     "$rsreport3" "ok read-stats: 0 (no read log)" "missing read log is a quiet no-op"
assert_missing "$rsreport3" "read-stats most-read"            "no most-read line when there is no log"
assert_missing "$rsreport3" "read-stats never-read"            "never-read walk skipped entirely when there is no log"
rm -rf "$RS3"

# 11d: search with no logged reads at all → conversion is 0/N, never n/a
# division-by-zero, and the check still never contributes an ALARM.
RS4="$(mktemp -d)"; mkdir -p "$RS4/vault"
RSLOG4="$RS4/knowledge-reads.log"
printf '2026-07-01T00:00:00Z · s1 · script · search · foo\n' > "$RSLOG4"
rsreport4="$(KNOWLEDGE_READ_LOG="$RSLOG4" bash "$SCRIPT" --root "$RS4/vault")"
assert_has     "$rsreport4" "info read-stats search→read conversion: 0/1 (0%)" "unconverted search with an empty store reports 0/1, not n/a"
assert_has     "$rsreport4" "info read-stats never-read: 0/0 note(s) never read" "empty store reports 0/0 never-read, no divide-by-zero"
assert_missing "$rsreport4" "ALARM"                                              "read-stats never contributes an ALARM on its own"
rm -rf "$RS4"

rm -rf "$_TEST_ISOLATION_DIR"
# ── Test 12: orphan-pattern + missing-trigger (temperloop#239) ────────────────
echo "--- test 12: orphan-pattern + missing-trigger ---"

# A Patterns/ fixture exercising both lints:
#   - orphan pattern.md    : has trigger:, absent from T0 -> orphan-pattern fires
#   - linked pattern.md    : has trigger:, present in T0 -> orphan-pattern quiet
#   - search only.md       : has trigger:, absent from T0 but retrieval:
#                             search-only -> orphan-pattern quiet (exempt)
#   - no trigger.md        : new (default mtime), no trigger: -> missing-trigger
#                             fires (also absent from T0, so orphan-pattern
#                             fires on it too — not asserted either way)
#   - old no trigger.md    : no trigger:, mtime forced far in the past ->
#                             missing-trigger stays quiet (outside the
#                             recency window)
RP="$(mktemp -d)"; mkdir -p "$RP/Patterns"
printf -- '---\ntrigger: some trigger\n---\norphan content\n'      > "$RP/Patterns/temperloop - orphan pattern.md"
printf -- '---\ntrigger: some trigger\n---\nlinked content\n'      > "$RP/Patterns/temperloop - linked pattern.md"
printf -- '---\nretrieval: search-only\ntrigger: t\n---\nsearch-only content\n' > "$RP/Patterns/temperloop - search only pattern.md"
printf -- '---\ntags: [pattern]\n---\nno trigger content\n'        > "$RP/Patterns/temperloop - no trigger pattern.md"
printf -- '---\ntags: [pattern]\n---\nold no trigger content\n'    > "$RP/Patterns/temperloop - old no trigger pattern.md"
touch -t 202001010000 "$RP/Patterns/temperloop - old no trigger pattern.md"

t0file="$RP/t0-inventory.txt"
printf 'Patterns/temperloop - linked pattern\n' > "$t0file"

rpreport="$(T0_INVENTORY_FILE="$t0file" bash "$SCRIPT" --root "$RP")"
assert_has     "$rpreport" "orphan-pattern: Patterns/temperloop - orphan pattern.md" "orphan (absent from T0, no search-only) fires"
assert_missing "$rpreport" "orphan-pattern: Patterns/temperloop - linked pattern.md" "T0-linked pattern stays quiet"
assert_missing "$rpreport" "orphan-pattern: Patterns/temperloop - search only pattern.md" "retrieval: search-only pattern is exempt"
assert_has     "$rpreport" "missing-trigger: Patterns/temperloop - no trigger pattern.md" "new pattern with no trigger: fires"
assert_missing "$rpreport" "missing-trigger: Patterns/temperloop - old no trigger pattern.md" "pattern outside the recency window stays quiet"
assert_missing "$rpreport" "missing-trigger: Patterns/temperloop - orphan pattern.md" "pattern WITH trigger: never fires missing-trigger"
assert_has     "$rpreport" "ALARM:" "orphan/missing-trigger fixture trips an alarm"
rm -rf "$RP"

# 12b: T0 inventory absent -> orphan-pattern degrades gracefully (skipped,
# quiet), even though a Patterns/ note that would otherwise be an orphan
# exists.
RP2="$(mktemp -d)"; mkdir -p "$RP2/Patterns"
printf -- '---\ntrigger: t\n---\ncontent\n' > "$RP2/Patterns/temperloop - would-be orphan.md"
noT0report="$(bash "$SCRIPT" --root "$RP2")"
assert_has     "$noT0report" "ok orphan-pattern: 0 (no T0 inventory" "absent T0 inventory -> graceful skip, not an alarm"
assert_missing "$noT0report" "orphan-pattern: Patterns/temperloop - would-be orphan.md" "no false alarm when T0 inventory is absent"
rm -rf "$RP2"

# ── Test 13: telemetry-coverage (temperloop#239 — mcp_obsidian EOL gate) ──────
echo "--- test 13: telemetry-coverage ---"

# 13a: Obsidian-backed vault + a matcher list that DROPS the mcp-tools search
# server's pattern -> the uncovered transport fires.
TC="$(mktemp -d)"; mkdir -p "$TC/.obsidian"
tcreport="$(KNOWLEDGE_READ_LOG_AGENT_MATCHERS="mcp__obsidian-builtin*" bash "$SCRIPT" --root "$TC")"
assert_has "$tcreport" "telemetry-coverage: transport 'mcp__obsidian__search_vault_smart' has no matching" "uncovered transport fires"
assert_has "$tcreport" "ALARM:" "uncovered transport trips an alarm"
rm -rf "$TC"

# 13b: Obsidian-backed vault + the real default matcher list -> quiet (both
# known transports covered).
TC2="$(mktemp -d)"; mkdir -p "$TC2/.obsidian"
tc2report="$(bash "$SCRIPT" --root "$TC2")"
assert_has     "$tc2report" "ok telemetry-coverage: 0 (2 known transport(s) covered)" "default matcher list covers both known transports"
assert_missing "$tc2report" "⚠️ telemetry-coverage:" "no uncovered-transport finding with the default matchers"
rm -rf "$TC2"

# 13c: not Obsidian-backed -> nothing to check, quiet regardless of matchers.
TC3="$(mktemp -d)"
tc3report="$(KNOWLEDGE_READ_LOG_AGENT_MATCHERS="" bash "$SCRIPT" --root "$TC3")"
assert_has "$tc3report" "ok telemetry-coverage: 0 (store root is not Obsidian-backed" "non-Obsidian root -> quiet no-op"
rm -rf "$TC3"

# ── Test 14: controls (temperloop#239 — ADR §2.3a/§2.4/§2.8) ──────────────────
echo "--- test 14: controls ---"

CV="$(mktemp -d)"; mkdir -p "$CV/Controls" "$CV/Context"
# A healthy control: named by a row whose owning-script really exists.
echo "good" > "$CV/Controls/temperloop - good dial.md"
# A dead-dial control: named by a row whose owning-script does NOT exist.
echo "dead" > "$CV/Controls/temperloop - dead dial.md"
# An orphaned control: no row names it at all.
echo "orphan" > "$CV/Controls/temperloop - orphan dial.md"
# A machine-read file living OUTSIDE Controls/ (its row's Context/ fallback
# literal resolves to a file that physically exists there).
echo "outside" > "$CV/Context/temperloop - outside dial.md"

fixture_registry="$CV/knob-registry.tsv"
cat > "$fixture_registry" <<EOF
CTRL_GOOD	Controls/temperloop - good dial.md	path	kernel	workflows/scripts/drain/vault_hygiene_report.sh	Points at \`Controls/temperloop - good dial.md\` — a healthy, reachable control (fixture).
CTRL_DEAD	Controls/temperloop - dead dial.md	path	kernel	workflows/scripts/does/not/exist.sh	Points at \`Controls/temperloop - dead dial.md\` but its consumer script is missing (fixture dead-dial case).
CTRL_OUTSIDE	Context/temperloop - outside dial.md	path	kernel	workflows/scripts/drain/vault_hygiene_report.sh	Legacy path: defaults to \`Controls/temperloop - outside dial.md\`, falling back to \`Context/temperloop - outside dial.md\` during the overlay move window (fixture).
EOF

cvreport="$(KNOB_REGISTRY_FILE="$fixture_registry" bash "$SCRIPT" --root "$CV")"
assert_missing "$cvreport" "controls: Controls/temperloop - good dial.md" "healthy, registry-matched control with a real consumer script is never flagged"
assert_has     "$cvreport" "controls: Controls/temperloop - dead dial.md — named consumer script missing" "dead dial (missing consumer script) fires"
assert_has     "$cvreport" "controls: Controls/temperloop - orphan dial.md — no knob-registry.tsv path row points at it" "orphaned control (no row names it) fires"
assert_has     "$cvreport" "controls: Context/temperloop - outside dial.md — machine-read store file outside Controls/" "machine-read file outside Controls/ fires"
assert_has     "$cvreport" "ALARM:" "controls fixture trips an alarm"
rm -rf "$CV"

# 14b: no Controls/ folder -> quiet no-op regardless of the registry.
CV2="$(mktemp -d)"
cv2report="$(bash "$SCRIPT" --root "$CV2")"
assert_has "$cv2report" "ok controls: 0 (no Controls/ folder)" "no Controls/ folder -> quiet no-op"
rm -rf "$CV2"

# ── Test 15: heat score + review queue (temperloop#240 — ADR §2.6-2.7) ────────
echo "--- test 15: heat score + review queue ---"

# Portable "N days ago" as YYYY-MM-DD (GNU `date -d` vs BSD `date -v`) — the
# same dialect split every date helper in the script under test uses.
days_ago() { date -d "-$1 days" +%Y-%m-%d 2>/dev/null || date -v-"$1"d +%Y-%m-%d; }

# 15a: weighted ranking, by hand, against the script's own documented
# defaults (HEAT_W_READS=3, HEAT_W_LINKS=2, HEAT_W_RECENCY=1,
# HEAT_RECENCY_HORIZON_DAYS=180):
#   A "very hot decision"   — reads=5, links=3, last_verified 60d ago
#                              recency=(180-60)*10/180=6; heat=3*5+2*3+1*6=27
#                              priority=27*60=1620
#   B "moderately cold ptn" — reads=1, links=1, last_verified 300d ago
#                              (beyond the 180d horizon -> recency floors 0)
#                              heat=3*1+2*1+1*0=5; priority=5*300=1500
# A's higher heat (despite less staleness) out-ranks B's higher staleness —
# proof the score is a genuine weighted combination, not staleness alone.
HS="$(mktemp -d)"; mkdir -p "$HS/Decisions" "$HS/Patterns" "$HS/Context"
printf -- '---\nlast_verified: %s\n---\nhot\n' "$(days_ago 60)" > "$HS/Decisions/temperloop - very hot decision.md"
printf -- '---\ntrigger: t\nlast_verified: %s\n---\ncold\n' "$(days_ago 300)" > "$HS/Patterns/temperloop - moderately cold pattern.md"
echo "See [[temperloop - very hot decision]] for context."   > "$HS/Context/link-hot-1.md"
echo "See [[temperloop - very hot decision]] for context."   > "$HS/Context/link-hot-2.md"
echo "See [[temperloop - very hot decision]] for context."   > "$HS/Context/link-hot-3.md"
echo "See [[temperloop - moderately cold pattern]] instead." > "$HS/Context/link-cold-1.md"
HSLOG="$HS/reads.log"
{
  for i in 1 2 3 4 5; do printf '2026-01-01T00:00:0%dZ · s1 · script · read · Decisions/temperloop - very hot decision.md\n' "$i"; done
  printf '2026-01-01T00:00:06Z · s1 · script · read · Patterns/temperloop - moderately cold pattern.md\n'
} > "$HSLOG"
hsreport="$(KNOWLEDGE_READ_LOG="$HSLOG" T0_INVENTORY_FILE="$T0_INVENTORY_FILE" bash "$SCRIPT" --root "$HS")"
assert_has "$hsreport" "info heat-score: 6 candidate note(s) scored (weights: reads=3 links=2 recency=1/10 decayed over 180d" "heat-score summary line reports weights + candidate count"
assert_has "$hsreport" "review-queue #1: Decisions/temperloop - very hot decision.md — heat=27 staleness=60d reads=5 priority=1620" "rank #1 is the higher-heat note with its exact computed score"
assert_has "$hsreport" "review-queue #2: Patterns/temperloop - moderately cold pattern.md — heat=5 staleness=300d reads=1 priority=1500" "rank #2 is the lower-heat, more-stale note with its exact computed score"
assert_missing "$hsreport" "ALARM:" "heat-score/review-queue never contributes an ALARM"
rm -rf "$HS"

# 15b: no-telemetry degrade — an absent read log makes every note's reads
# component 0, so the ranking becomes pure links+recency with no error (the
# reads=3 weight simply contributes nothing). The more-linked note still
# ranks first, proving the degrade path is a real ranking, not a crash.
HS2="$(mktemp -d)"; mkdir -p "$HS2/Decisions" "$HS2/Context"
printf -- '---\nlast_verified: %s\n---\nlinked\n' "$(days_ago 90)" > "$HS2/Decisions/temperloop - well linked.md"
echo "[[temperloop - well linked]]" > "$HS2/Context/link-a.md"
echo "[[temperloop - well linked]]" > "$HS2/Context/link-b.md"
noTelReport="$(KNOWLEDGE_READ_LOG="$HS2/no-such-log" T0_INVENTORY_FILE="$T0_INVENTORY_FILE" bash "$SCRIPT" --root "$HS2")"
# recency=(180-90)*10/180=5; heat=3*0+2*2+1*5=9; priority=9*90=810
assert_has "$noTelReport" "review-queue #1: Decisions/temperloop - well linked.md — heat=9 staleness=90d reads=0 priority=810" "no read log -> reads=0, links+recency ranking still computed correctly"
assert_missing "$noTelReport" "ALARM:" "no-telemetry heat-score fixture stays alarm-free"
rm -rf "$HS2"

# 15c: cap-at-5 — 7 candidate notes with distinct nonzero priorities (via
# distinct link counts, all last_verified the same 10d-ago so only heat
# varies) -> the queue never emits a 6th or 7th rank, by construction.
HS3="$(mktemp -d)"; mkdir -p "$HS3/Decisions"
i=1
while [ "$i" -le 7 ]; do
  printf -- '---\nlast_verified: %s\n---\nnote %d\n' "$(days_ago 10)" "$i" > "$HS3/Decisions/temperloop - candidate $i.md"
  i=$((i + 1))
done
capReport="$(KNOWLEDGE_READ_LOG="$HS3/no-such-log" T0_INVENTORY_FILE="$T0_INVENTORY_FILE" bash "$SCRIPT" --root "$HS3")"
assert_has     "$capReport" "info heat-score: 7 candidate note(s) scored" "all 7 candidates scored"
assert_has     "$capReport" "review-queue #5:" "rank #5 is present"
assert_missing "$capReport" "review-queue #6:" "rank #6 never appears — capped at 5 by construction"
assert_missing "$capReport" "review-queue #7:" "rank #7 never appears — capped at 5 by construction"
rm -rf "$HS3"

# 15d: flag-folding — a stale-plan (check 9), an orphan-pattern (check 13),
# and a repeat-mistake (check 11) finding each fold into the review-queue
# line for the SAME note as a `[tag]` annotation.
HS4="$(mktemp -d)"; mkdir -p "$HS4/Plans" "$HS4/Patterns" "$HS4/Mistakes" "$HS4/Context"
# stale-plan: status draft, mtime forced far in the past (check 9's own
# recognition shape), plus one inbound link so its heat is nonzero.
printf -- '---\nstatus: draft\n---\nold draft\n' > "$HS4/Plans/temperloop - flagged stale plan.md"
touch -t 202001010000 "$HS4/Plans/temperloop - flagged stale plan.md"
echo "[[temperloop - flagged stale plan]]" > "$HS4/Context/link-plan.md"
# orphan-pattern: has trigger:, old last_verified, absent from the (empty)
# T0 inventory fixture below -> orphan-pattern fires.
printf -- '---\ntrigger: t\nlast_verified: 2020-01-01\n---\norphan content\n' > "$HS4/Patterns/temperloop - flagged pattern.md"
echo "[[temperloop - flagged pattern]]" > "$HS4/Context/link-pattern.md"
# repeat-mistake: a Mistakes/ note + a NEW matching friction-ledger row
# (same fixture shape as test 10a).
printf -- '---\ntags: [mistake]\ntrigger: BSD stat -f flags, non-portable date parsing\nlast_verified: 2020-01-01\n---\nUse file_mtime().\n' \
  > "$HS4/Mistakes/temperloop - BSD stat flags break Linux CI.md"
echo "[[temperloop - BSD stat flags break Linux CI]]" > "$HS4/Context/link-mistake.md"
today15="$(date +%Y-%m-%d)"
echo "- ${today15} · temperloop · tool-misuse · vault_hygiene_report.sh used BSD stat -f flags on Linux CI and broke the build" \
  > "$HS4/Context/Session friction ledger.md"
emptyT0="$HS4/t0-empty.txt"; : > "$emptyT0"
foldReport="$(T0_INVENTORY_FILE="$emptyT0" KNOWLEDGE_READ_LOG="$HS4/no-such-log" bash "$SCRIPT" --root "$HS4")"
assert_has "$foldReport" "Plans/temperloop - flagged stale plan.md — heat="                      "stale-plan-flagged note reaches the review queue"
assert_has "$foldReport" "[stale-plan]"                                                          "stale-plan flag folds into its review-queue line"
assert_has "$foldReport" "Patterns/temperloop - flagged pattern.md — heat="                       "orphan-pattern-flagged note reaches the review queue"
assert_has "$foldReport" "[orphan-pattern]"                                                       "orphan-pattern flag folds into its review-queue line"
assert_has "$foldReport" "Mistakes/temperloop - BSD stat flags break Linux CI.md — heat="          "repeat-mistake-flagged note reaches the review queue"
assert_has "$foldReport" "[repeat-mistake]"                                                       "repeat-mistake flag folds into its review-queue line"
rm -rf "$HS4"

# 15e: empty store — no HEAT_SCAN_FOLDERS present at all -> 0 candidates, no
# queue, no error (the stranger test: a bare kernel checkout has no vault
# content of this shape yet).
HS5="$(mktemp -d)"
emptyReport="$(KNOWLEDGE_READ_LOG="$HS5/no-such-log" T0_INVENTORY_FILE="$T0_INVENTORY_FILE" bash "$SCRIPT" --root "$HS5")"
assert_has     "$emptyReport" "info heat-score: 0 candidate note(s) scored"   "empty store -> 0 candidates, no error"
assert_has     "$emptyReport" "info review-queue: empty (0 candidate notes)" "empty store -> empty queue, not an alarm"
assert_missing "$emptyReport" "ALARM:"                                       "empty store trips no alarm from heat-score"
rm -rf "$HS5"

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_vault_hygiene_report: FAIL"
  exit 1
fi
echo "test_vault_hygiene_report: OK"
