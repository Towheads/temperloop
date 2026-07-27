#!/usr/bin/env bash
#
# Tests for check-contributor-manifest.sh (temperloop#827, epic #810 P1): a
# synthetic git-repo fixture proves the structural checks (malformed row,
# duplicate path, unknown unit, unknown load class), the tracked-path
# invariant (this is what structurally keeps a host-state contributor out of
# the manifest — a path that is not `git ls-files`-tracked fails), the
# frontmatter field-presence check, the completeness sweep over
# claude/commands/*.md + claude/agents/**/*.md, and the CLAUDE.md
# single-row/full-unit invariant — plus the GREEN path a clean fixture
# produces.
#
# Needs a REAL git repo (the checker shells out to `git -C <root> ls-files`)
# — unlike the sibling check-reviewer-routing.sh test, which needs no repo
# at all. Each fixture is built fresh under a throwaway `git init` tree.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$HERE/.." && pwd)"
CHECKER="$CONFIG_DIR/check-contributor-manifest.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/contributor-manifest-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

REPO="$WORK/repo"

# fresh_repo — (re)creates a bare-minimum git repo with the tracked fixture
# files every test case starts from: a root CLAUDE.md, one command file, one
# agent file. Individual tests add/remove tracked files and the manifest tsv
# on top of this before committing.
fresh_repo() {
  rm -rf "$REPO"
  mkdir -p "$REPO/claude/commands" "$REPO/claude/agents"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name test

  printf 'thin pointer file\n' >"$REPO/CLAUDE.md"
  cat >"$REPO/claude/commands/build.md" <<'EOF'
---
description: Build things.
argument-hint: <x>
---

Body.
EOF
  cat >"$REPO/claude/agents/architecture-reviewer.md" <<'EOF'
---
name: architecture-reviewer
description: Reviews architecture.
tools: Read
---

Body.
EOF
}

commit_all() {
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "fixture"
}

clean_manifest() {
  cat >"$REPO/manifest.tsv" <<'EOF'
CLAUDE.md	full	kernel-pointer	harness-auto
claude/commands/build.md	frontmatter:description	command-listing	harness-auto
claude/agents/architecture-reviewer.md	frontmatter:description	agent-listing	harness-auto
EOF
}

run_checker() {
  (
    CONTRIBUTOR_MANIFEST_TSV="$REPO/manifest.tsv"
    CONTRIBUTOR_MANIFEST_REPO_ROOT="$REPO"
    export CONTRIBUTOR_MANIFEST_TSV CONTRIBUTOR_MANIFEST_REPO_ROOT
    bash "$CHECKER"
  )
}

# --- 1. GREEN: clean fixture -------------------------------------------------
fresh_repo
clean_manifest
commit_all
out="$(run_checker 2>&1)" || fail "1: clean fixture should pass:
$out"
case "$out" in
  *"OK — contributor-manifest.tsv (3 row(s))"*) ;;
  *) fail "1: expected the OK summary line, got:
$out" ;;
esac
echo "PASS: 1 clean fixture passes (GREEN)"

# --- 2. RED: malformed row (missing fields) ---------------------------------
fresh_repo
commit_all
printf 'CLAUDE.md\tfull\n' >"$REPO/manifest.tsv"
out="$(run_checker 2>&1)" && fail "2: malformed row should fail:
$out"
case "$out" in
  *"malformed row"*) ;;
  *) fail "2: expected a malformed-row error, got:
$out" ;;
esac
echo "PASS: 2 malformed row correctly flagged (RED)"

# --- 3. RED: duplicate path claimed by two rows -----------------------------
fresh_repo
commit_all
clean_manifest
printf 'CLAUDE.md\tfull\tkernel-pointer\tharness-auto\n' >>"$REPO/manifest.tsv"
out="$(run_checker 2>&1)" && fail "3: duplicate path should fail:
$out"
case "$out" in
  *"DUPLICATE: CLAUDE.md is claimed by two rows"*) ;;
  *) fail "3: expected a DUPLICATE violation, got:
$out" ;;
esac
echo "PASS: 3 duplicate path correctly flagged (RED)"

# --- 4. RED: unknown unit ----------------------------------------------------
fresh_repo
commit_all
clean_manifest
printf 'claude/commands/build.md\tweird-unit\tcommand-listing\tharness-auto\n' >"$REPO/manifest.tsv"
printf 'CLAUDE.md\tfull\tkernel-pointer\tharness-auto\n' >>"$REPO/manifest.tsv"
printf 'claude/agents/architecture-reviewer.md\tfrontmatter:description\tagent-listing\tharness-auto\n' >>"$REPO/manifest.tsv"
out="$(run_checker 2>&1)" && fail "4: unknown unit should fail:
$out"
case "$out" in
  *"UNKNOWN UNIT"*) ;;
  *) fail "4: expected an UNKNOWN UNIT violation, got:
$out" ;;
esac
echo "PASS: 4 unknown unit correctly flagged (RED)"

# --- 5. RED: unknown load class ----------------------------------------------
fresh_repo
commit_all
clean_manifest
sed -i.bak 's/harness-auto$/some-other-load/' "$REPO/manifest.tsv" && rm -f "$REPO/manifest.tsv.bak"
out="$(run_checker 2>&1)" && fail "5: unknown load class should fail:
$out"
case "$out" in
  *"UNKNOWN LOAD CLASS"*) ;;
  *) fail "5: expected an UNKNOWN LOAD CLASS violation, got:
$out" ;;
esac
echo "PASS: 5 unknown load class correctly flagged (RED)"

# --- 6. RED: path not tracked (host-state / typo simulation) ----------------
fresh_repo
commit_all
clean_manifest
printf 'some/untracked/path.md\tfull\tkernel-pointer\tharness-auto\n' >>"$REPO/manifest.tsv"
out="$(run_checker 2>&1)" && fail "6: untracked path should fail:
$out"
case "$out" in
  *"NOT TRACKED: some/untracked/path.md"*) ;;
  *) fail "6: expected a NOT TRACKED violation, got:
$out" ;;
esac
echo "PASS: 6 untracked path correctly flagged (RED) — this is the structural guard that keeps a host-state contributor (e.g. ~/.claude/agents) out of the manifest"

# --- 7. RED: frontmatter:description row whose file has no description: ----
fresh_repo
printf -- '---\nname: no-desc\n---\n\nBody.\n' >"$REPO/claude/agents/architecture-reviewer.md"
commit_all
clean_manifest
out="$(run_checker 2>&1)" && fail "7: missing description field should fail:
$out"
case "$out" in
  *"NO DESCRIPTION FIELD: claude/agents/architecture-reviewer.md"*) ;;
  *) fail "7: expected a NO DESCRIPTION FIELD violation, got:
$out" ;;
esac
echo "PASS: 7 missing frontmatter description field correctly flagged (RED)"

# --- 8. RED: completeness — a tracked command file has no manifest row -----
fresh_repo
cat >"$REPO/claude/commands/extra.md" <<'EOF'
---
description: Extra command with no row.
---

Body.
EOF
commit_all
clean_manifest
out="$(run_checker 2>&1)" && fail "8: uncovered command file should fail:
$out"
case "$out" in
  *"MISSING ROW: claude/commands/extra.md"*) ;;
  *) fail "8: expected a MISSING ROW violation for extra.md, got:
$out" ;;
esac
echo "PASS: 8 uncovered command file correctly flagged (RED)"

# --- 9. RED: completeness — a tracked agent file has no manifest row -------
fresh_repo
cat >"$REPO/claude/agents/extra-reviewer.md" <<'EOF'
---
name: extra-reviewer
description: Extra agent with no row.
---

Body.
EOF
commit_all
clean_manifest
out="$(run_checker 2>&1)" && fail "9: uncovered agent file should fail:
$out"
case "$out" in
  *"MISSING ROW: claude/agents/extra-reviewer.md"*) ;;
  *) fail "9: expected a MISSING ROW violation for extra-reviewer.md, got:
$out" ;;
esac
echo "PASS: 9 uncovered agent file correctly flagged (RED)"

# --- 10. RED: CLAUDE.md has no row -------------------------------------------
fresh_repo
commit_all
cat >"$REPO/manifest.tsv" <<'EOF'
claude/commands/build.md	frontmatter:description	command-listing	harness-auto
claude/agents/architecture-reviewer.md	frontmatter:description	agent-listing	harness-auto
EOF
out="$(run_checker 2>&1)" && fail "10: missing CLAUDE.md row should fail:
$out"
case "$out" in
  *"MISSING ROW: the root CLAUDE.md pointer has no contributor-manifest row"*) ;;
  *) fail "10: expected a MISSING ROW violation for CLAUDE.md, got:
$out" ;;
esac
echo "PASS: 10 missing CLAUDE.md row correctly flagged (RED)"

# --- 11. RED: CLAUDE.md claimed with the wrong unit -------------------------
fresh_repo
commit_all
cat >"$REPO/manifest.tsv" <<'EOF'
CLAUDE.md	frontmatter:description	kernel-pointer	harness-auto
claude/commands/build.md	frontmatter:description	command-listing	harness-auto
claude/agents/architecture-reviewer.md	frontmatter:description	agent-listing	harness-auto
EOF
out="$(run_checker 2>&1)" && fail "11: CLAUDE.md with wrong unit should fail:
$out"
case "$out" in
  *'WRONG UNIT: CLAUDE.md row must use unit "full"'*) ;;
  *) fail "11: expected a WRONG UNIT violation for CLAUDE.md, got:
$out" ;;
esac
echo "PASS: 11 CLAUDE.md wrong-unit row correctly flagged (RED)"

echo "test_check_contributor_manifest: OK"
