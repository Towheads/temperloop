#!/usr/bin/env bash
#
# test_check_terminology_leak_guard.sh — fixture-replay for the v0.17.0
# terminology-rename leak gate (temperloop#729). Hermetic: builds a scratch
# git repo under $TMPDIR and points TERMINOLOGY_LEAK_SCAN_ROOT at it.
#
#   1. clean fixture -> green
#   2. a NEW FUNNEL_* env identifier -> red, names the file + token
#   3. an old renamed-file reference (the pre-rename driver doc) -> red
#   4. a coined severity token (blocking-now) -> red
#   5. an ALLOWED persisted-state literal (funnel-merge-pending,
#      funnel:decision-applied, /tmp/funnel-tick) alone -> green
#   6. an exempt-listed file carrying any old identifier -> green
#   7. the REAL tree -> green (the seeded state this PR ships)
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../check-terminology-leak-guard.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/termleak.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
git -C "$FIX" init -q

run_gate() { TERMINOLOGY_LEAK_SCAN_ROOT="$FIX" TERMINOLOGY_LEAK_EXEMPT_FILE="$FIX/exempt.txt" bash "$GATE" 2>&1; }

printf '# nothing legacy here\nPIPELINE_DRIVE_CAP=1\nSETTING_REGISTRY_FILE=x\n' > "$FIX/clean.sh"
printf '# exempt list\nexempt-me.sh\n' > "$FIX/exempt.txt"
git -C "$FIX" add -A && git -C "$FIX" commit -qm seed

# 1 clean
out="$(run_gate)" || fail "clean fixture went red: $out"
grep -q '^OK' <<<"$out" || fail "clean fixture: no OK line: $out"
pass "1 clean fixture is green"

# 2 new FUNNEL_ identifier
printf ': "${FUNNEL_NEW_THING:=1}"\n' > "$FIX/bad-env.sh"
git -C "$FIX" add -A
out="$(run_gate)" && fail "FUNNEL_NEW_THING not caught"
grep -q 'bad-env.sh' <<<"$out" || fail "red output does not name the file: $out"
grep -q 'FUNNEL_NEW_THING' <<<"$out" || fail "red output does not show the token: $out"
pass "2 a new FUNNEL_* identifier trips the gate, naming file + token"
rm "$FIX/bad-env.sh"

# 3 old renamed-file path. Uses the pre-rename DRIVER DOC rather than one of
# the deleted stub scripts: the v0.19.0 window close (temperloop#767) made
# every stub basename grep-clean outside the historical records, and this
# fixture would otherwise reintroduce one. The shape family is the same.
printf 'see claude/commands/funnel-driver.md\n' > "$FIX/bad-path.md"
git -C "$FIX" add -A
out="$(run_gate)" && fail "old renamed-file reference not caught"
grep -q 'bad-path.md' <<<"$out" || fail "red output does not name the file: $out"
pass "3 an old renamed-file path reference trips the gate"
rm "$FIX/bad-path.md"

# 4 coined severity token
printf 'this halt is blocking-now severity\n' > "$FIX/bad-term.md"
git -C "$FIX" add -A
out="$(run_gate)" && fail "blocking-now not caught"
pass "4 a coined severity token trips the gate"
rm "$FIX/bad-term.md"

# 5 allowed persisted-state literals alone
printf 'gh label create funnel-merge-pending; marker="<!-- funnel:decision-applied -->"; lock=/tmp/funnel-tick\n' > "$FIX/values.sh"
git -C "$FIX" add -A
out="$(run_gate)" || fail "allowed persisted-state literals went red: $out"
pass "5 allowed persisted-state literal values stay green"
rm "$FIX/values.sh"

# 6 exempt file
printf 'FUNNEL_ANYTHING=1 knob-registry.tsv batch-at-gate\n' > "$FIX/exempt-me.sh"
git -C "$FIX" add -A
out="$(run_gate)" || fail "exempt-listed file went red: $out"
pass "6 an exempt-listed file carrying old identifiers stays green"

# 7b non-repo scan root fails LOUD, never false-greens as 0-scanned
out="$(TERMINOLOGY_LEAK_SCAN_ROOT="$FIX/does-not-exist" TERMINOLOGY_LEAK_EXEMPT_FILE="$FIX/exempt.txt" bash "$GATE" 2>/dev/null)" && fail "empty scan did not fail loud"
grep -q 'scanned 0 file' <<<"$out" || fail "empty-scan failure does not say why: $out"
pass "7b an empty/failed scan is a loud FAIL, not a false green"

# 7 real tree
out="$(bash "$GATE" 2>&1)" || fail "REAL tree is red: $out"
pass "7 the real tree is green (seeded state)"

echo "test_check_terminology_leak_guard: OK"
