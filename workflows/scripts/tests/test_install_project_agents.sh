#!/usr/bin/env bash
#
# Tests for workflows/scripts/install/project-agents.sh (temperloop#290) — the
# kernel-safe, project-scoped install path that deploys claude/agents/* and
# claude/commands/* into a live .claude/ so the capability probe resolves them.
#
# Covers:
#   1. A fresh --project-dir (out-of-tree tmpdir, so this exercises the
#      temperloop#497 default-to-copy path) gets one .claude/<cat>/<name>
#      entry per source *.md, and the deployed entry RESOLVES to the source
#      content (the capability-probe-satisfying invariant).
#   2. Idempotent re-run: every entry reports "already up to date" (the
#      out-of-tree default is now a copy, not a symlink — temperloop#497),
#      nothing new deployed.
#   3. A pre-existing NON-managed file at a target is never clobbered — it is
#      reported skipped and its content is preserved.
#   4. --copy mode deploys real files (not symlinks) that match the source.
#   5. In-tree deploy (project == kernel checkout) uses a RELATIVE symlink
#      that survives a repo move, and still resolves.
#   6. --dry-run writes nothing.
#
# Out-of-tree default-to-symlink regression coverage (the specific defect
# this default-to-copy behavior fixes) lives in the dedicated
# test_project_agents_out_of_tree_copy.sh (temperloop#497), which additionally
# asserts no operator absolute path leaks into a deployed artifact.
#
# No network, no HOME mutation — every case uses a throwaway tmpdir project.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DEPLOY_SH="${REPO_ROOT}/workflows/scripts/install/project-agents.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-project-agents-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$DEPLOY_SH" ] || fail "0: deploy script not found at $DEPLOY_SH"

# Expected source inventory (real tree — the script deploys from REPO_ROOT).
#
# -L (follow symlinks) is load-bearing, not cosmetic. In a kernel-only checkout
# claude/agents is a real directory and bare `find` works. In an overlay that
# vendors the kernel, claude/agents is a compat SYMLINK to
# kernel/claude/agents — bare `find` stats the symlink, refuses to descend, and
# returns 0, failing the assert below on a tree that is perfectly well-formed.
# The script under test enumerates with a glob ("$src_dir"/*.md), which
# traverses a symlinked dir happily, so without -L this inventory disagrees
# with the very deploy it is meant to predict. (#364)
agents_n="$(find -L "${REPO_ROOT}/claude/agents" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
cmds_n="$(find -L "${REPO_ROOT}/claude/commands" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
[ "$agents_n" -ge 1 ] || fail "0: expected at least one source agent .md"
[ "$cmds_n" -ge 1 ] || fail "0: expected at least one source command .md"

# ---------------------------------------------------------------------------
# Test 1: fresh deploy — one entry per source, each resolves to source content.
# ---------------------------------------------------------------------------
P1="${TMP}/proj1"
mkdir -p "$P1"
bash "$DEPLOY_SH" --project-dir "$P1" >/dev/null 2>&1 || fail "1: deploy exited non-zero"

got_agents="$(find "${P1}/.claude/agents" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
got_cmds="$(find "${P1}/.claude/commands" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
[ "$got_agents" = "$agents_n" ] || fail "1: agents deployed=${got_agents} expected=${agents_n}"
[ "$got_cmds" = "$cmds_n" ] || fail "1: commands deployed=${got_cmds} expected=${cmds_n}"

# The capability-probe-satisfying invariant: a file is PRESENT under
# .claude/agents/ and reads back the source content.
sample_agent="$(basename "$(find -L "${REPO_ROOT}/claude/agents" -maxdepth 1 -name '*.md' | head -1)")"
[ -e "${P1}/.claude/agents/${sample_agent}" ] || fail "1: deployed agent not present at target"
cmp -s "${REPO_ROOT}/claude/agents/${sample_agent}" "${P1}/.claude/agents/${sample_agent}" \
  || fail "1: deployed agent does not resolve to source content"

pass "1: fresh deploy produces one resolving entry per source agent/command"

# Also assert the out-of-tree default is a real-file COPY, never a symlink
# (the temperloop#497 defect: an absolute symlink into the kernel checkout).
[ ! -L "${P1}/.claude/agents/${sample_agent}" ] \
  || fail "1: out-of-tree deploy produced a symlink, expected a detached copy"

pass "1b: out-of-tree default deploy produces a detached copy, not a symlink"

# ---------------------------------------------------------------------------
# Test 2: idempotent re-run.
# ---------------------------------------------------------------------------
rerun_out="$(bash "$DEPLOY_SH" --project-dir "$P1" 2>&1)" || fail "2: re-run exited non-zero"
already="$(grep -c "already up to date" <<<"$rerun_out" || true)"
total=$((agents_n + cmds_n))
[ "$already" = "$total" ] || fail "2: expected ${total} 'already up to date', got ${already}"
grep -q "deployed: 0" <<<"$rerun_out" || fail "2: re-run should deploy 0 new entries"

pass "2: idempotent re-run leaves every entry already-up-to-date"

# ---------------------------------------------------------------------------
# Test 3: a pre-existing non-managed target is preserved, not clobbered.
#
# Uses a foreign SYMLINK (pointing elsewhere), not a plain regular file, as
# the pre-existing target: the bulk copy-mode branch's clobber check only
# refuses a non-regular-file target (symlink, directory, etc) — a
# content-mismatched *regular* file is a separate, pre-existing quirk of the
# copy-mode branch (see its own comment, and deploy_only()'s stricter
# equivalent) that this item does not change. A symlink target exercises the
# actual "never clobbers a non-managed target" contract under both
# symlink-mode (in-tree) and copy-mode (out-of-tree default, temperloop#497).
# ---------------------------------------------------------------------------
P3="${TMP}/proj3"
mkdir -p "${P3}/.claude/agents"
printf 'USER OWNED\n' > "${TMP}/foreign-owned-file"
ln -s "${TMP}/foreign-owned-file" "${P3}/.claude/agents/${sample_agent}"
out3="$(bash "$DEPLOY_SH" --project-dir "$P3" 2>&1)" || fail "3: deploy exited non-zero"
grep -q "${sample_agent} exists and is not a managed copy — skipping" <<<"$out3" \
  || fail "3: pre-existing foreign symlink should be reported skipped"
[ "$(readlink "${P3}/.claude/agents/${sample_agent}")" = "${TMP}/foreign-owned-file" ] \
  || fail "3: pre-existing foreign symlink target was clobbered"

pass "3: a pre-existing non-managed target is reported and preserved"

# ---------------------------------------------------------------------------
# Test 4: --copy deploys real files (not symlinks) matching the source.
# ---------------------------------------------------------------------------
P4="${TMP}/proj4"
mkdir -p "$P4"
bash "$DEPLOY_SH" --project-dir "$P4" --copy >/dev/null 2>&1 || fail "4: copy deploy exited non-zero"
t4="${P4}/.claude/agents/${sample_agent}"
[ -f "$t4" ] || fail "4: copied entry missing"
[ ! -L "$t4" ] || fail "4: --copy produced a symlink, expected a real file"
cmp -s "${REPO_ROOT}/claude/agents/${sample_agent}" "$t4" || fail "4: copied content differs from source"

pass "4: --copy deploys real (non-symlink) files matching the source"

# ---------------------------------------------------------------------------
# Test 5: in-tree deploy uses a RELATIVE symlink and still resolves. Deploy
# into a throwaway COPY of the kernel tree so the real repo's tree is never
# mutated by the test (and so the -ef same-file check fires on project==root).
# ---------------------------------------------------------------------------
P5="${TMP}/kernel-copy"
mkdir -p "${P5}/workflows/scripts/install" "${P5}/claude/agents" "${P5}/claude/commands"
cp "$DEPLOY_SH" "${P5}/workflows/scripts/install/project-agents.sh"
# project-agents.sh sources its sibling gitignore-safety.sh (temperloop#560) —
# a minimal kernel tree must carry it too or the copied script fails its own
# "missing sibling script" guard.
cp "${REPO_ROOT}/workflows/scripts/install/gitignore-safety.sh" "${P5}/workflows/scripts/install/gitignore-safety.sh"
cp "${REPO_ROOT}/claude/agents/${sample_agent}" "${P5}/claude/agents/${sample_agent}"
sample_cmd="$(basename "$(find -L "${REPO_ROOT}/claude/commands" -maxdepth 1 -name '*.md' | head -1)")"
cp "${REPO_ROOT}/claude/commands/${sample_cmd}" "${P5}/claude/commands/${sample_cmd}"

bash "${P5}/workflows/scripts/install/project-agents.sh" >/dev/null 2>&1 \
  || fail "5: in-tree deploy exited non-zero"
link5="${P5}/.claude/agents/${sample_agent}"
[ -L "$link5" ] || fail "5: in-tree entry should be a symlink"
[ "$(readlink "$link5")" = "../../claude/agents/${sample_agent}" ] \
  || fail "5: in-tree symlink should be RELATIVE (../../claude/...), got '$(readlink "$link5")'"
cmp -s "${P5}/claude/agents/${sample_agent}" "$link5" || fail "5: relative link does not resolve"

pass "5: in-tree deploy uses a resolving relative symlink"

# ---------------------------------------------------------------------------
# Test 6: --dry-run writes nothing.
# ---------------------------------------------------------------------------
P6="${TMP}/proj6"
mkdir -p "$P6"
bash "$DEPLOY_SH" --project-dir "$P6" --dry-run >/dev/null 2>&1 || fail "6: dry-run exited non-zero"
[ ! -d "${P6}/.claude" ] || fail "6: dry-run created .claude/ (should write nothing)"

pass "6: --dry-run writes nothing"

echo
echo "PASS: all project-agents install-path tests passed"
