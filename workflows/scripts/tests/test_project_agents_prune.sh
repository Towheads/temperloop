#!/usr/bin/env bash
#
# Tests for the project-scoped managed-link PRUNE (temperloop#1943) —
# workflows/scripts/install/project-agents.sh's prune pass, the shared
# recognizer in workflows/scripts/install/project-agents-prune.sh, and
# workflows/scripts/install/doctor.sh's advisory check_project_agents_tree().
#
# THE DEFECT THIS GUARDS. project-agents.sh deploys one symlink per source
# file into <project>/.claude/{agents,commands}/ and had no prune, no --sync
# and no uninstall path, so deleting a source file left its link behind,
# dangling — and invisible, because the installer gitignores the very tree it
# writes into. A dangling entry under .claude/agents/ is the exact surface
# Claude Code's capability probe reads, so a deleted reviewer kept reading as
# "available" forever.
#
# Covers the DISCRIMINATING set — a prune that over-reaches is worse than the
# link it cleans up, so each case below is a thing that must NOT be removed
# as much as a thing that must:
#   1. A dangling managed link (bulk form, both categories, plus the --only
#      selective form) is GONE after an ordinary deploy — no flag passed.
#   2. A managed-form link whose source still EXISTS is kept (resolves, so it
#      is never a candidate).
#   3. Unrelated entries in the managed directory survive untouched: a real
#      regular file, a dangling symlink to somewhere else entirely, a
#      managed-SHAPED link whose basename does not match what it points at, a
#      dangling non-.md link, a dangling managed-form link one directory
#      deeper, and a dangling managed-form link in an unmanaged .claude/
#      sibling directory.
#   4. --dry-run prunes NOTHING and prints the plan.
#   5. The prune also runs on the selective --only deploy path.
#   6. doctor.sh REPORTS a surviving dangling link (DANGLING line), and does
#      so strictly ADVISORY-ly — proven differentially on the SAME fixture
#      before vs. after the link appears: identical "Non-OK: N" and identical
#      exit code, only the new section differs.
#
# No network. No HOME mutation, and no write anywhere near the operator's own
# .claude/ — every case runs against a throwaway mktemp tree.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DEPLOY_SH="${REPO_ROOT}/workflows/scripts/install/project-agents.sh"
PRUNE_LIB="${REPO_ROOT}/workflows/scripts/install/project-agents-prune.sh"
DOCTOR_SH="${REPO_ROOT}/workflows/scripts/install/doctor.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-project-agents-prune-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$DEPLOY_SH" ] || fail "0: deploy script not found at $DEPLOY_SH"
[ -f "$PRUNE_LIB" ] || fail "0: prune lib not found at $PRUNE_LIB"
[ -f "$DOCTOR_SH" ] || fail "0: doctor.sh not found at $DOCTOR_SH"

# is_link PATH — true iff PATH is a symlink (dangling included). `[ -e ]`
# follows the link and is therefore useless for a dangling one.
is_link() { [ -L "$1" ]; }

# ---------------------------------------------------------------------------
# Fixture: a throwaway project tree carrying, side by side, every entry the
# prune must remove and every entry it must leave alone.
# ---------------------------------------------------------------------------
P="${TMP}/proj"
mkdir -p "${P}/.claude/agents" "${P}/.claude/commands" "${P}/.claude/skills"
mkdir -p "${P}/.claude/agents/nested"
mkdir -p "${P}/claude/agents"

# --- MUST be pruned -------------------------------------------------------
# Bulk form, agents: source claude/agents/zz-ghost-agent.md does not exist.
ln -s "../../claude/agents/zz-ghost-agent.md" "${P}/.claude/agents/zz-ghost-agent.md"
# Bulk form, commands.
ln -s "../../claude/commands/zz-ghost-command.md" "${P}/.claude/commands/zz-ghost-command.md"
# Selective --only form: reads a category subdir, writes the FLAT name.
ln -s "../../claude/agents/reviewers/zz-ghost-reviewer.md" "${P}/.claude/agents/zz-ghost-reviewer.md"

# --- MUST be kept ---------------------------------------------------------
# (a) Managed-form link whose source EXISTS — resolves, so never a candidate.
echo '# kept fixture source' >"${P}/claude/agents/zz-kept-agent.md"
ln -s "../../claude/agents/zz-kept-agent.md" "${P}/.claude/agents/zz-kept-agent.md"
# (b) A real regular file the operator put there themselves.
echo '# my own agent' >"${P}/.claude/agents/zz-mine.md"
# (c) A dangling symlink pointing somewhere else entirely.
ln -s "/nonexistent/zz-foreign.md" "${P}/.claude/agents/zz-foreign.md"
# (d) Managed-SHAPED but the basename does not match what it points at.
ln -s "../../claude/agents/zz-other-name.md" "${P}/.claude/agents/zz-mismatch.md"
# (e) Dangling managed-form link that is not a .md entry.
ln -s "../../claude/agents/zz-ghost-notes.txt" "${P}/.claude/agents/zz-ghost-notes.txt"
# (f) One directory deeper — the scan is one level, never recursive.
ln -s "../../claude/agents/zz-ghost-nested.md" "${P}/.claude/agents/nested/zz-ghost-nested.md"
# (g) An unmanaged .claude/ sibling directory is out of scope entirely.
ln -s "../../claude/skills/zz-ghost-skill.md" "${P}/.claude/skills/zz-ghost-skill.md"

KEEPERS=(
  ".claude/agents/zz-kept-agent.md"
  ".claude/agents/zz-mine.md"
  ".claude/agents/zz-foreign.md"
  ".claude/agents/zz-mismatch.md"
  ".claude/agents/zz-ghost-notes.txt"
  ".claude/agents/nested/zz-ghost-nested.md"
  ".claude/skills/zz-ghost-skill.md"
)

assert_keepers_intact() {
  local ctx="$1" rel
  for rel in "${KEEPERS[@]}"; do
    if [ ! -e "${P}/${rel}" ] && ! is_link "${P}/${rel}"; then
      fail "${ctx}: prune removed an entry it does not manage: ${rel}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Test 4 (run first, on the untouched fixture): --dry-run prunes nothing.
# ---------------------------------------------------------------------------
out_dry="$(bash "$DEPLOY_SH" --project-dir "$P" --dry-run 2>&1)" || fail "4: dry-run exited non-zero"

grep -q "would prune" <<<"$out_dry" || fail "4: dry-run did not print a prune plan — got: $out_dry"
grep -q "zz-ghost-agent.md" <<<"$out_dry" || fail "4: dry-run prune plan omits zz-ghost-agent.md — got: $out_dry"
is_link "${P}/.claude/agents/zz-ghost-agent.md" || fail "4: dry-run actually removed zz-ghost-agent.md"
is_link "${P}/.claude/commands/zz-ghost-command.md" || fail "4: dry-run actually removed zz-ghost-command.md"
is_link "${P}/.claude/agents/zz-ghost-reviewer.md" || fail "4: dry-run actually removed zz-ghost-reviewer.md"
assert_keepers_intact "4"

pass "4: --dry-run prints the prune plan and removes nothing"

# ---------------------------------------------------------------------------
# Tests 1 + 2 + 3: an ORDINARY deploy (no flag) prunes exactly the dangling
# managed links and nothing else.
# ---------------------------------------------------------------------------
out_deploy="$(bash "$DEPLOY_SH" --project-dir "$P" 2>&1)" || fail "1: deploy exited non-zero — got: $out_deploy"

if is_link "${P}/.claude/agents/zz-ghost-agent.md"; then
  fail "1: dangling managed agents link survived an ordinary deploy — got: $out_deploy"
fi
if is_link "${P}/.claude/commands/zz-ghost-command.md"; then
  fail "1: dangling managed commands link survived an ordinary deploy — got: $out_deploy"
fi
if is_link "${P}/.claude/agents/zz-ghost-reviewer.md"; then
  fail "1: dangling --only-form managed link survived an ordinary deploy — got: $out_deploy"
fi
grep -q "pruned agents/zz-ghost-agent.md" <<<"$out_deploy" \
  || fail "1: deploy did not report pruning zz-ghost-agent.md — got: $out_deploy"

pass "1: a removed source file leaves no dangling managed link after an ordinary deploy"

is_link "${P}/.claude/agents/zz-kept-agent.md" \
  || fail "2: a managed-form link whose source still exists was removed"
[ -e "${P}/.claude/agents/zz-kept-agent.md" ] \
  || fail "2: the kept link no longer resolves"

pass "2: a source file that is still present keeps its link"

assert_keepers_intact "3"
[ -f "${P}/.claude/agents/zz-mine.md" ] || fail "3: the operator's own regular file was removed"
[ ! -L "${P}/.claude/agents/zz-mine.md" ] || fail "3: the operator's own regular file was replaced by a link"

pass "3: unrelated entries in the managed directory are not removed (real file, foreign link, basename mismatch, non-.md, nested, unmanaged category)"

# Idempotence: a second deploy has nothing left to prune and still exits 0.
out_second="$(bash "$DEPLOY_SH" --project-dir "$P" 2>&1)" || fail "3b: second deploy exited non-zero"
grep -q "= none" <<<"$out_second" || fail "3b: second deploy should report nothing to prune — got: $out_second"
assert_keepers_intact "3b"

pass "3b: a second deploy finds nothing to prune and leaves every keeper intact"

# ---------------------------------------------------------------------------
# Test 5: the prune also runs on the selective --only deploy path.
# ---------------------------------------------------------------------------
ONLY_P="${TMP}/proj-only"
mkdir -p "${ONLY_P}/.claude/agents"
ln -s "../../claude/agents/zz-ghost-only.md" "${ONLY_P}/.claude/agents/zz-ghost-only.md"
echo '# untouchable' >"${ONLY_P}/.claude/agents/zz-untouchable.md"

# Pick a real catalogued reviewer so --only has something valid to deploy.
only_src="$(find -L "${REPO_ROOT}/claude/agents/reviewers" -maxdepth 1 -name '*.md' | head -1)"
[ -n "$only_src" ] || fail "5: no reviewer agent found under claude/agents/reviewers"
only_name="$(basename "$only_src" .md)"

out_only="$(bash "$DEPLOY_SH" --project-dir "$ONLY_P" --only "$only_name" --category reviewers 2>&1)" \
  || fail "5: --only deploy exited non-zero — got: $out_only"

if is_link "${ONLY_P}/.claude/agents/zz-ghost-only.md"; then
  fail "5: the --only path did not prune a dangling managed link — got: $out_only"
fi
[ -f "${ONLY_P}/.claude/agents/zz-untouchable.md" ] \
  || fail "5: the --only path removed an unrelated regular file"

pass "5: the prune runs on the selective --only deploy path too"

# ---------------------------------------------------------------------------
# Test 6: doctor.sh reports a surviving dangling link, and stays advisory.
#
# Differential proof (the same shape test_doctor_reviewer_coverage.sh uses):
# the fixture FOUNDATION is run twice, before and after the dangling link is
# planted. Only the new section may differ — "Non-OK: N" and the exit code
# must be byte-identical, which is what "never becomes a gate" means in
# observable terms.
# ---------------------------------------------------------------------------
FOUND="${TMP}/fake-foundation"
mkdir -p "${FOUND}/workflows/scripts/install" "${FOUND}/.claude/agents"
cp "$PRUNE_LIB" "${FOUND}/workflows/scripts/install/project-agents-prune.sh"

set +e
out_before="$(bash "$DOCTOR_SH" "$FOUND" 2>&1)"
exit_before=$?
set -e

grep -q "Project-scoped agent/command tree" <<<"$out_before" \
  || fail "6: doctor output is missing the project-scoped tree section — got: $out_before"
grep -q "no dangling managed links" <<<"$out_before" \
  || fail "6: a clean fixture tree should report no dangling links — got: $out_before"

nonok_before="$(printf '%s\n' "$out_before" | grep -oE 'Non-OK: [0-9]+')"
[ -n "$nonok_before" ] || fail "6: could not parse a 'Non-OK: N' line — got: $out_before"

ln -s "../../claude/agents/zz-ghost-doctor.md" "${FOUND}/.claude/agents/zz-ghost-doctor.md"

set +e
out_after="$(bash "$DOCTOR_SH" "$FOUND" 2>&1)"
exit_after=$?
set -e

grep -q "DANGLING  .claude/agents/zz-ghost-doctor.md" <<<"$out_after" \
  || fail "6: doctor did not report the dangling project-scoped link — got: $out_after"

pass "6a: doctor reports a dangling link under the project-scoped tree"

nonok_after="$(printf '%s\n' "$out_after" | grep -oE 'Non-OK: [0-9]+')"
[ "$nonok_before" = "$nonok_after" ] \
  || fail "6b: Non-OK tally changed from '$nonok_before' to '$nonok_after' just by adding a dangling project-scoped link — the check must touch no tally"
[ "$exit_before" -eq "$exit_after" ] \
  || fail "6b: doctor's exit code changed from $exit_before to $exit_after just by adding a dangling project-scoped link — the check must stay advisory"

# The report is read-only: doctor must not have pruned it itself.
is_link "${FOUND}/.claude/agents/zz-ghost-doctor.md" \
  || fail "6b: doctor removed the dangling link — the check must be read-only"

pass "6b: the check stays advisory (no tally, unchanged exit code) and read-only"

echo
echo "PASS: all project-agents prune tests passed"
