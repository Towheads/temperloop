#!/usr/bin/env bash
#
# Tests for workflows/scripts/install/reviewer-activate.sh (temperloop#549) —
# the interactive opt-in activation caller + durable-decline marker, sitting
# between #548's reviewer-activation-coverage.sh (gap-set DATA PATH) and
# #543's project-agents.sh --only (DEPLOY path).
#
# Covers:
#   1. A multi-gap repo gets ONE batched offer (one header, all gap names
#      listed together) — not one prompt per reviewer.
#   2. --accept all activates every gap reviewer via #543's --only, and the
#      post-activation gap set (via #548) is green (empty) — this test OWNS
#      that post-activation green-state assertion; #548's own test owns only
#      the PRE-activation gap surface.
#   3. Idempotent: re-running after full activation reports "no activation
#      gaps found" and makes no changes.
#   4. --decline all writes a durable per-name marker under
#      .claude/reviewer-state/declined/, the marker path is confirmed
#      git-ignored (git check-ignore), and the declined names drop out of
#      the gap set (without being activated).
#   5. A name outside the current gap set (already covered by a user-defined
#      reviewer of the same name) is ignored by --accept — never activated,
#      never clobbers the user's file.
#   6. --dry-run writes nothing (no .claude/agents/<name>.md, no decline
#      marker) even though it reports what it WOULD do.
#   7. The interactive prompt path (piped stdin, no flags): a bare "y" line
#      accepts the whole batch; a specific name accepts only that name and
#      leaves the rest as gaps; EOF (no input) makes no changes at all.
#
# No network, no HOME mutation — every case uses a throwaway tmpdir fixture,
# and no real git repo's tracked .gitignore is touched (git check-ignore is
# run against THIS repo's own tracked .gitignore, read-only).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RA_SH="${REPO_ROOT}/workflows/scripts/install/reviewer-activate.sh"
RAC_SH="${REPO_ROOT}/workflows/scripts/install/reviewer-activation-coverage.sh"
CONFIG_SH="${REPO_ROOT}/workflows/scripts/build/build.config.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-ra-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -x "$RA_SH" ] || fail "0: script not found or not executable at $RA_SH"

min_files="$(bash -c "source '$CONFIG_SH' >/dev/null 2>&1; echo \"\${REVIEWER_SCAN_MIN_FILES:-3}\"")"
case "$min_files" in
  ''|*[!0-9]*) fail "0: could not resolve a numeric REVIEWER_SCAN_MIN_FILES (got '$min_files')" ;;
esac

# make_fixture DIR — a fresh, GIT-INITIALIZED repo dir with enough .sh and
# .py files to clear the activation threshold for both shell-reviewer and
# python-reviewer. Real git init (not just a plain tmpdir) is load-bearing:
# reviewer-activate.sh's gitignore-safety guard (temperloop#560 mitigation)
# refuses to write activation/decline state outside an actual git repo, so
# every fixture that exercises accept/decline must be one.
make_fixture() {
  local dir="$1" i=1
  mkdir -p "$dir"
  git init -q "$dir" >/dev/null 2>&1
  while [ "$i" -le "$min_files" ]; do
    echo '#!/usr/bin/env bash' >"${dir}/script${i}.sh"
    echo 'print("hi")' >"${dir}/mod${i}.py"
    i=$((i + 1))
  done
}

gaps_of() {
  bash "$RAC_SH" --list-only --project-dir "$1"
}

# ---------------------------------------------------------------------------
# Test 1: a multi-gap repo gets ONE batched offer.
# ---------------------------------------------------------------------------
F1="${TMP}/f1"
make_fixture "$F1"
out1="$(printf 'none\n' | bash "$RA_SH" --project-dir "$F1")"
headers="$(grep -c "^== reviewer activation offer" <<<"$out1" || true)"
[ "$headers" = "1" ] || fail "1: expected exactly one batched offer header, got $headers"
grep -q "python-reviewer" <<<"$out1" || fail "1: offer should list python-reviewer"
grep -q "shell-reviewer" <<<"$out1" || fail "1: offer should list shell-reviewer"

pass "1: a multi-gap repo emits exactly one batched offer covering the whole gap set"

# ---------------------------------------------------------------------------
# Test 2: --accept all activates every gap reviewer; post-activation gap set
# is green (empty). This test owns the post-activation green-state check.
# ---------------------------------------------------------------------------
F2="${TMP}/f2"
make_fixture "$F2"
bash "$RA_SH" --project-dir "$F2" --accept all >/dev/null \
  || fail "2: --accept all exited non-zero"
[ -f "${F2}/.claude/agents/python-reviewer.md" ] || fail "2: python-reviewer not deployed"
[ -f "${F2}/.claude/agents/shell-reviewer.md" ] || fail "2: shell-reviewer not deployed"
post_gaps="$(gaps_of "$F2")"
[ -z "$post_gaps" ] || fail "2: expected empty (green) gap set post-activation, got: $post_gaps"

pass "2: --accept all activates the whole gap set via #543's --only; post-activation gap set is green"

# ---------------------------------------------------------------------------
# Test 3: idempotent re-run after full activation — "no activation gaps
# found", no further changes.
# ---------------------------------------------------------------------------
rerun_out="$(bash "$RA_SH" --project-dir "$F2")" || fail "3: re-run exited non-zero"
grep -q "no activation gaps found" <<<"$rerun_out" \
  || fail "3: idempotent re-run should report no activation gaps — got: $rerun_out"

pass "3: a re-run after full activation offers nothing (idempotent)"

# ---------------------------------------------------------------------------
# Test 4: --decline all writes a durable, git-ignored marker per name, and
# the declined names drop out of the gap set without being activated.
# ---------------------------------------------------------------------------
F4="${TMP}/f4"
make_fixture "$F4"
bash "$RA_SH" --project-dir "$F4" --decline all >/dev/null \
  || fail "4: --decline all exited non-zero"
[ -f "${F4}/.claude/reviewer-state/declined/python-reviewer" ] \
  || fail "4: python-reviewer decline marker missing"
[ -f "${F4}/.claude/reviewer-state/declined/shell-reviewer" ] \
  || fail "4: shell-reviewer decline marker missing"
[ ! -e "${F4}/.claude/agents/python-reviewer.md" ] \
  || fail "4: declining should not activate python-reviewer"

# Marker path git-ignored — checked against THIS repo's own tracked
# .gitignore (read-only; the fixture path is irrelevant to the pattern,
# which matches on the .claude/reviewer-state/ segment).
(cd "$REPO_ROOT" && git check-ignore -q ".claude/reviewer-state/declined/python-reviewer") \
  || fail "4: .claude/reviewer-state/declined/<name> is not git-ignored"

post_gaps4="$(gaps_of "$F4")"
[ -z "$post_gaps4" ] || fail "4: expected empty gap set after declining all, got: $post_gaps4"

pass "4: --decline all writes a durable, git-ignored per-name marker and removes those names from the gap set"

# ---------------------------------------------------------------------------
# Test 5: a name outside the current gap set (user-defined reviewer of the
# same name already covers it) is ignored by --accept — never activated,
# never clobbers the user's file.
# ---------------------------------------------------------------------------
F5="${TMP}/f5"
make_fixture "$F5"
mkdir -p "${F5}/.claude/agents"
printf 'USER OWNED\n' >"${F5}/.claude/agents/shell-reviewer.md"

out5="$(bash "$RA_SH" --project-dir "$F5" --accept "shell-reviewer,python-reviewer" 2>&1)" \
  || fail "5: accept exited non-zero"
grep -q "'shell-reviewer' is not in the current gap set" <<<"$out5" \
  || fail "5: expected a warning that shell-reviewer is outside the gap set — got: $out5"
[ "$(cat "${F5}/.claude/agents/shell-reviewer.md")" = "USER OWNED" ] \
  || fail "5: user-defined shell-reviewer was clobbered"
[ -f "${F5}/.claude/agents/python-reviewer.md" ] \
  || fail "5: python-reviewer (a real gap) should still have been activated"

pass "5: a name outside the current gap set is ignored — never activated, never clobbers a user-defined reviewer"

# ---------------------------------------------------------------------------
# Test 6: --dry-run writes nothing.
# ---------------------------------------------------------------------------
F6="${TMP}/f6"
make_fixture "$F6"
bash "$RA_SH" --project-dir "$F6" --accept all --dry-run >/dev/null \
  || fail "6: dry-run accept exited non-zero"
[ ! -d "${F6}/.claude" ] || fail "6: dry-run accept created .claude/ (should write nothing)"

F6b="${TMP}/f6b"
make_fixture "$F6b"
bash "$RA_SH" --project-dir "$F6b" --decline all --dry-run >/dev/null \
  || fail "6: dry-run decline exited non-zero"
[ ! -d "${F6b}/.claude" ] || fail "6: dry-run decline created .claude/ (should write nothing)"

pass "6: --dry-run writes nothing for either accept or decline"

# ---------------------------------------------------------------------------
# Test 7: interactive prompt path (piped stdin, no flags).
# ---------------------------------------------------------------------------
F7="${TMP}/f7"
make_fixture "$F7"
printf 'y\n' | bash "$RA_SH" --project-dir "$F7" >/dev/null \
  || fail "7a: piped 'y' exited non-zero"
post7a="$(gaps_of "$F7")"
[ -z "$post7a" ] || fail "7a: bare 'y' should accept the whole batch, got remaining gaps: $post7a"

F7b="${TMP}/f7b"
make_fixture "$F7b"
printf 'python-reviewer\n' | bash "$RA_SH" --project-dir "$F7b" >/dev/null \
  || fail "7b: piped subset name exited non-zero"
[ -f "${F7b}/.claude/agents/python-reviewer.md" ] || fail "7b: python-reviewer not activated"
[ ! -e "${F7b}/.claude/agents/shell-reviewer.md" ] || fail "7b: shell-reviewer should NOT have been activated"
post7b="$(gaps_of "$F7b")"
grep -qx "shell-reviewer" <<<"$post7b" || fail "7b: shell-reviewer should still be a gap — got: $post7b"

F7c="${TMP}/f7c"
make_fixture "$F7c"
bash "$RA_SH" --project-dir "$F7c" </dev/null >/dev/null \
  || fail "7c: EOF/no-stdin exited non-zero"
[ ! -d "${F7c}/.claude" ] || fail "7c: EOF/no-stdin with no flags should make no changes"

pass "7: interactive prompt — 'y' accepts the batch, a name accepts a subset, EOF makes no changes"

# ---------------------------------------------------------------------------
# Test 8: target-repo gitignore-bleed mitigation (temperloop#560 local half).
# A fresh git-initialized target with NO .gitignore at all: an activate and
# a decline must each leave the written state resolving under `git
# check-ignore` in the TARGET repo (i.e. NOT staged by a `git add -A` there)
# — never relying on the KERNEL checkout's own .gitignore. Also asserts the
# .gitignore append is idempotent (no duplicate lines across the two writes).
# ---------------------------------------------------------------------------
F8="${TMP}/f8"
mkdir -p "$F8"
git init -q "$F8" >/dev/null 2>&1
i=1
while [ "$i" -le "$min_files" ]; do
  echo '#!/usr/bin/env bash' >"${F8}/script${i}.sh"
  echo 'print("hi")' >"${F8}/mod${i}.py"
  i=$((i + 1))
done
[ ! -e "${F8}/.gitignore" ] || fail "8: fixture should start with no .gitignore"

out8a="$(bash "$RA_SH" --project-dir "$F8" --accept python-reviewer 2>&1)" \
  || fail "8a: accept exited non-zero — output: $out8a"
grep -q "added '.claude/agents/' to " <<<"$out8a" \
  || fail "8a: expected an 'added .claude/agents/ to <gitignore>' notice — got: $out8a"
git -C "$F8" check-ignore -q ".claude/agents/python-reviewer.md" \
  || fail "8a: .claude/agents/python-reviewer.md does not resolve git-ignored in the TARGET repo"

# The accept step above already ensured BOTH entries (the guard checks both
# on every write, per the header comment), so the decline step here should
# find .claude/reviewer-state/ already ignored and add nothing new — assert
# exactly that (no second "added" notice for the same entry).
out8b="$(bash "$RA_SH" --project-dir "$F8" --decline shell-reviewer 2>&1)" \
  || fail "8b: decline exited non-zero — output: $out8b"
if grep -q "added '.claude/reviewer-state/' to " <<<"$out8b"; then
  fail "8b: .claude/reviewer-state/ should already have been ignored by the prior accept step — got a duplicate 'added' notice: $out8b"
fi
git -C "$F8" check-ignore -q ".claude/reviewer-state/declined/shell-reviewer" \
  || fail "8b: .claude/reviewer-state/declined/shell-reviewer does not resolve git-ignored in the TARGET repo"

# Idempotency: exactly one occurrence of each entry line, no duplicates
# across the accept (which added both entries up front) and decline writes.
agents_lines="$(grep -cxF '.claude/agents/' "${F8}/.gitignore" || true)"
state_lines="$(grep -cxF '.claude/reviewer-state/' "${F8}/.gitignore" || true)"
[ "$agents_lines" = "1" ] || fail "8c: expected exactly one '.claude/agents/' line, got $agents_lines"
[ "$state_lines" = "1" ] || fail "8c: expected exactly one '.claude/reviewer-state/' line, got $state_lines"

pass "8: a fresh target repo with no .gitignore gets both entries appended on first write, activation/decline state resolves git-ignored, and re-writes never duplicate the lines"

# ---------------------------------------------------------------------------
# Test 9: a target that is NOT a git repo at all — refuse loudly, write
# nothing, rather than silently leaving state exposed.
# ---------------------------------------------------------------------------
F9="${TMP}/f9"
mkdir -p "$F9"
i=1
while [ "$i" -le "$min_files" ]; do
  echo '#!/usr/bin/env bash' >"${F9}/script${i}.sh"
  echo 'print("hi")' >"${F9}/mod${i}.py"
  i=$((i + 1))
done

if out9="$(bash "$RA_SH" --project-dir "$F9" --accept all 2>&1)"; then
  fail "9: expected non-zero exit when the target is not a git repo — output: $out9"
fi
grep -q "is not a git repository" <<<"$out9" \
  || fail "9: expected a loud 'is not a git repository' warning — got: $out9"
[ ! -d "${F9}/.claude" ] || fail "9: no state should have been written when the target isn't a git repo"

pass "9: a non-git target refuses loudly and writes no activation/decline state"

echo
echo "All reviewer-activate tests passed."
