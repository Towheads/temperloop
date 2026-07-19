#!/usr/bin/env bash
#
# Regression test for temperloop#497 — project-agents.sh: default bulk
# out-of-tree deploys to detached copies, not absolute symlinks.
#
# THE DEFECT THIS GUARDS. The bulk deploy_one() used to compute, for an
# out-of-tree adopter (--project-dir elsewhere), an ABSOLUTE symlink target
# ($src, an absolute path back into the operator's kernel checkout) — leaking
# the operator's username/dir layout into the adopting project, and risking
# that leaked path landing in the adopter's own tracked history if its
# .claude/ isn't gitignored. The fix mirrors deploy_only()'s existing
# in-tree/out-of-tree mode decision into the bulk path: out-of-tree (without
# explicit --copy) now defaults to a detached real-file COPY instead.
#
# Covers:
#   1. Out-of-tree bulk deploy, no --copy -> every deployed agent/command
#      entry is a REGULAR FILE (not a symlink), readlink is empty, content
#      matches source, and no deployed artifact contains an operator absolute
#      path (/Users/... or $HOME).
#   2. In-tree deploy (project dir == kernel checkout) -> unchanged: targets
#      are symlinks whose readlink is the relative ../../claude/... form.
#   3. Explicit --copy out-of-tree -> still copies (unchanged).
#   4. --dry-run -> writes nothing, prints the plan (and the plan reflects
#      the actual out-of-tree default: "would copy", not "would link").
#
# No network, no HOME mutation — every case uses a throwaway tmpdir project.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DEPLOY_SH="${REPO_ROOT}/workflows/scripts/install/project-agents.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-poo-tree-copy-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$DEPLOY_SH" ] || fail "0: deploy script not found at $DEPLOY_SH"

# -L (follow symlinks) is load-bearing: in an overlay checkout claude/agents
# may be a compat symlink to a kernel dir — see test_install_project_agents.sh
# (#364) for the same rationale.
agents_n="$(find -L "${REPO_ROOT}/claude/agents" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
cmds_n="$(find -L "${REPO_ROOT}/claude/commands" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
[ "$agents_n" -ge 1 ] || fail "0: expected at least one source agent .md"
[ "$cmds_n" -ge 1 ] || fail "0: expected at least one source command .md"

# ---------------------------------------------------------------------------
# Test 1: out-of-tree bulk deploy, no --copy.
# ---------------------------------------------------------------------------
P1="${TMP}/proj-out-of-tree"
mkdir -p "$P1"
out1="$(bash "$DEPLOY_SH" --project-dir "$P1" 2>&1)" || fail "1: deploy exited non-zero"

for cat in agents commands; do
  for src in "${REPO_ROOT}/claude/${cat}"/*.md; do
    [ -e "$src" ] || continue  # -L already-resolved by REPO_ROOT tree; nullglob not set here
    name="$(basename "$src")"
    target="$P1/.claude/${cat}/${name}"

    [ -e "$target" ] || fail "1: ${cat}/${name} not deployed"
    [ -f "$target" ] || fail "1: ${cat}/${name} is not a regular file"
    [ ! -L "$target" ] || fail "1: ${cat}/${name} is a symlink, expected a detached copy"
    [ -z "$(readlink "$target" || true)" ] || fail "1: ${cat}/${name} readlink is non-empty"
    cmp -s "$src" "$target" || fail "1: ${cat}/${name} content does not match source"
  done
done

pass "1: out-of-tree bulk deploy (no --copy) deploys real-file copies for every agent/command"

# No deployed artifact anywhere under P1/.claude leaks the operator's kernel
# checkout absolute path — the specific leak this item closes (the OLD bulk
# deploy_one() computed link_target="$src", an absolute path under
# REPO_ROOT, and ln -s'd it). Grep for REPO_ROOT itself rather than a bare
# "/Users/" substring: some source *.md prose (e.g. claude/commands/init.md)
# legitimately contains an illustrative "/Users/alice/..." example path, which
# a bare substring match would false-positive on — REPO_ROOT is the actual,
# specific value that would leak.
if grep -rlF "$REPO_ROOT" "${P1}/.claude" >/dev/null 2>&1; then
  fail "1: a deployed artifact contains the kernel checkout's absolute path ($REPO_ROOT)"
fi
# Belt-and-suspenders: no plain, non-recursive symlink anywhere under the
# deployed tree either (grep above only checks file CONTENT).
if find "${P1}/.claude" -type l | grep -q .; then
  fail "1: a symlink was found under the deployed out-of-tree .claude/ tree"
fi

pass "1: no operator absolute path or symlink present anywhere in the out-of-tree deploy"

echo "$out1" | grep -q "mode          : copy" || fail "1: summary header should report mode: copy for out-of-tree default"

pass "1: out-of-tree summary header reports the effective copy mode"

# ---------------------------------------------------------------------------
# Test 2: in-tree deploy (project dir == kernel checkout) is unchanged —
# still a relative ../../claude/... symlink. Deploy into a throwaway COPY of
# a minimal kernel tree so the real repo is never mutated by the test.
# ---------------------------------------------------------------------------
P2="${TMP}/kernel-copy"
mkdir -p "${P2}/workflows/scripts/install" "${P2}/claude/agents" "${P2}/claude/commands"
cp "$DEPLOY_SH" "${P2}/workflows/scripts/install/project-agents.sh"
sample_agent="$(basename "$(find -L "${REPO_ROOT}/claude/agents" -maxdepth 1 -name '*.md' | head -1)")"
sample_cmd="$(basename "$(find -L "${REPO_ROOT}/claude/commands" -maxdepth 1 -name '*.md' | head -1)")"
cp "${REPO_ROOT}/claude/agents/${sample_agent}" "${P2}/claude/agents/${sample_agent}"
cp "${REPO_ROOT}/claude/commands/${sample_cmd}" "${P2}/claude/commands/${sample_cmd}"

bash "${P2}/workflows/scripts/install/project-agents.sh" >/dev/null 2>&1 \
  || fail "2: in-tree deploy exited non-zero"

link_agent="${P2}/.claude/agents/${sample_agent}"
link_cmd="${P2}/.claude/commands/${sample_cmd}"
[ -L "$link_agent" ] || fail "2: in-tree agent entry should be a symlink"
[ "$(readlink "$link_agent")" = "../../claude/agents/${sample_agent}" ] \
  || fail "2: in-tree agent symlink should be relative, got '$(readlink "$link_agent")'"
[ -L "$link_cmd" ] || fail "2: in-tree command entry should be a symlink"
[ "$(readlink "$link_cmd")" = "../../claude/commands/${sample_cmd}" ] \
  || fail "2: in-tree command symlink should be relative, got '$(readlink "$link_cmd")'"
cmp -s "${P2}/claude/agents/${sample_agent}" "$link_agent" || fail "2: relative link does not resolve"

pass "2: in-tree deploy still produces relative ../../claude/... symlinks (unchanged)"

# ---------------------------------------------------------------------------
# Test 3: explicit --copy out-of-tree still copies (unchanged).
# ---------------------------------------------------------------------------
P3="${TMP}/proj-explicit-copy"
mkdir -p "$P3"
bash "$DEPLOY_SH" --project-dir "$P3" --copy >/dev/null 2>&1 || fail "3: --copy deploy exited non-zero"
t3="${P3}/.claude/agents/${sample_agent}"
[ -f "$t3" ] || fail "3: --copy deployed entry missing"
[ ! -L "$t3" ] || fail "3: --copy produced a symlink, expected a real file"
cmp -s "${REPO_ROOT}/claude/agents/${sample_agent}" "$t3" || fail "3: --copy content differs from source"

pass "3: explicit --copy out-of-tree still deploys real-file copies (unchanged)"

# ---------------------------------------------------------------------------
# Test 4: --dry-run writes nothing and prints the plan.
# ---------------------------------------------------------------------------
P4="${TMP}/proj-dry-run"
mkdir -p "$P4"
out4="$(bash "$DEPLOY_SH" --project-dir "$P4" --dry-run 2>&1)" || fail "4: dry-run exited non-zero"
[ ! -d "${P4}/.claude" ] || fail "4: dry-run created .claude/ (should write nothing)"
echo "$out4" | grep -q "would copy" || fail "4: dry-run plan should print 'would copy' for out-of-tree default"
echo "$out4" | grep -q "dry run — nothing written" || fail "4: dry-run should report nothing written"

pass "4: --dry-run writes nothing and prints the (copy) plan for the out-of-tree default"

echo
echo "PASS: all out-of-tree copy-default regression tests passed"
