#!/usr/bin/env bash
#
# test_check_terminology_leak_guard.sh — fixture-replay for the v0.17.0
# terminology-rename leak gate (temperloop#729). Hermetic: builds a scratch
# git repo under $TMPDIR and points TERMINOLOGY_LEAK_SCAN_ROOT at it.
#
#   1. clean fixture -> green
#   2. a NEW FUNNEL_* env identifier -> red, names the file + token
#   3. an old renamed-script path reference (validate-live-drain.sh) -> red
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
printf '%s' "$out" | grep -q '^OK' || fail "clean fixture: no OK line: $out"
pass "1 clean fixture is green"

# 2 new FUNNEL_ identifier
printf ': "${FUNNEL_NEW_THING:=1}"\n' > "$FIX/bad-env.sh"
git -C "$FIX" add -A
out="$(run_gate)" && fail "FUNNEL_NEW_THING not caught"
printf '%s' "$out" | grep -q 'bad-env.sh' || fail "red output does not name the file: $out"
printf '%s' "$out" | grep -q 'FUNNEL_NEW_THING' || fail "red output does not show the token: $out"
pass "2 a new FUNNEL_* identifier trips the gate, naming file + token"
rm "$FIX/bad-env.sh"

# 3 old script path
printf 'bash workflows/scripts/validate-live-drain.sh\n' > "$FIX/bad-path.sh"
git -C "$FIX" add -A
out="$(run_gate)" && fail "old validate-live-drain.sh path not caught"
pass "3 an old renamed-script path reference trips the gate"
rm "$FIX/bad-path.sh"

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

# 7 real tree
out="$(bash "$GATE" 2>&1)" || fail "REAL tree is red: $out"
pass "7 the real tree is green (seeded state)"

echo "test_check_terminology_leak_guard: OK"
