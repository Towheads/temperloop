#!/usr/bin/env bash
#
# Tests for conventions-probe.sh (foundation #765). Zero network — every case
# here runs with --no-network (or against a PATH with no `gh`) and a scratch
# fixture git repo, never a real GitHub API call. Asserts:
#   1. happy path: a crafted fixture repo yields the expected values across
#      every detected section (branch naming, CI, commands, commit style,
#      docs, and the two network-gated sections correctly reporting
#      unavailable with a reason).
#   2. output is always valid JSON with schema == 1.
#   3. zero writes — the fixture tree's file list is byte-identical before
#      and after a probe run.
#   4. error paths: a non-git --dir fails loud (exit 1, nothing on stdout);
#      an unknown flag fails usage (exit 2).
#   5. --gh-repo overrides remote-inferred slug even with no origin remote.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$HERE/../conventions-probe.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/conventions-probe-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

REPO="$WORK/fixture-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

mkdir -p "$REPO/.github/workflows"
cat > "$REPO/.github/workflows/ci.yml" <<'EOF'
name: CI
on: [push, pull_request]
jobs:
  checks:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF

cat > "$REPO/Makefile" <<'EOF'
.PHONY: test lint
test:
	@echo testing
lint:
	@echo linting
EOF

cat > "$REPO/CLAUDE.md" <<'EOF'
# fixture
EOF

mkdir -p "$REPO/.github"
cat > "$REPO/.github/PULL_REQUEST_TEMPLATE.md" <<'EOF'
## Summary
EOF

echo one > "$REPO/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "chore: seed fixture"
git -C "$REPO" commit -q --allow-empty -m "feat: add a thing"
git -C "$REPO" commit -q --allow-empty -m "fix: fix a thing"
git -C "$REPO" commit -q --allow-empty -m "random commit message"
git -C "$REPO" commit -q --allow-empty -m "another random one"

git -C "$REPO" branch feat/x
git -C "$REPO" branch fix/y
git -C "$REPO" branch random-branch

# --- 1/2: happy path, offline ----------------------------------------------
out="$(bash "$PROBE" --dir "$REPO" --no-network)"
echo "$out" | jq empty || fail "output is not valid JSON"

[ "$(echo "$out" | jq -r '.schema')" = "1" ] || fail "schema should be 1"
[ "$(echo "$out" | jq -r '.probe')" = "conventions-probe" ] || fail "probe name wrong"

[ "$(echo "$out" | jq -r '.repo.default_branch')" = "main" ] || fail "default_branch should be main"

[ "$(echo "$out" | jq -r '.branch_naming.detected')" = "true" ] || fail "branch_naming.detected should be true"
[ "$(echo "$out" | jq -r '.branch_naming.pattern')" = "type/slug" ] || fail "branch_naming.pattern should be type/slug (2/3 branches slash-shaped)"
[ "$(echo "$out" | jq -r '.branch_naming.sample_size')" = "3" ] || fail "branch_naming.sample_size should be 3 (main excluded)"

[ "$(echo "$out" | jq -r '.branch_protection.available')" = "false" ] || fail "branch_protection should be unavailable with --no-network"
echo "$out" | jq -e '.branch_protection.reason | test("no-network")' >/dev/null || fail "branch_protection.reason should mention --no-network"

[ "$(echo "$out" | jq -r '.ci.providers | index("github-actions") != null')" = "true" ] || fail "ci.providers should include github-actions"
[ "$(echo "$out" | jq -r '.ci.workflows[0].jobs | sort | join(",")')" = "build,checks" ] || fail "ci job names wrong"

[ "$(echo "$out" | jq -r '.commands.test | index("make test") != null')" = "true" ] || fail "commands.test should include make test"
[ "$(echo "$out" | jq -r '.commands.lint | index("make lint") != null')" = "true" ] || fail "commands.lint should include make lint"

[ "$(echo "$out" | jq -r '.commit_style.convention')" = "conventional-commits" ] || fail "commit_style.convention should be conventional-commits (3/5 = 60%)"
[ "$(echo "$out" | jq -r '.commit_style.pr_template')" = ".github/PULL_REQUEST_TEMPLATE.md" ] || fail "pr_template should be detected"

[ "$(echo "$out" | jq -r '.docs.claude_md')" = "true" ] || fail "docs.claude_md should be true"
[ "$(echo "$out" | jq -r '.docs.agents_md')" = "false" ] || fail "docs.agents_md should be false"

[ "$(echo "$out" | jq -r '.labels.available')" = "false" ] || fail "labels should be unavailable with --no-network"

# --- 3: zero writes ----------------------------------------------------------
before="$(cd "$REPO" && find . -type f | sort)"
bash "$PROBE" --dir "$REPO" --no-network >/dev/null
after="$(cd "$REPO" && find . -type f | sort)"
[ "$before" = "$after" ] || fail "probe run must never write to the target tree"
[ ! -e "$REPO/.foundation" ] || fail "probe must never create .foundation/ (persistence is a later item's job)"

# --- 4: error paths ----------------------------------------------------------
NOTGIT="$WORK/not-a-repo"
mkdir -p "$NOTGIT"
if out2="$(bash "$PROBE" --dir "$NOTGIT" --no-network 2>/tmp/conventions-probe-test-err.$$)"; then
  fail "probing a non-git dir should fail"
fi
[ -z "$out2" ] || fail "a failed probe must print nothing to stdout"
rm -f "/tmp/conventions-probe-test-err.$$"

if bash "$PROBE" --dir "$REPO" --bogus-flag >/dev/null 2>&1; then
  fail "an unknown flag should be a usage error (exit 2)"
fi

# --- 5: --gh-repo override with no origin remote ----------------------------
out3="$(bash "$PROBE" --dir "$REPO" --gh-repo "someorg/somerepo" --no-network)"
[ "$(echo "$out3" | jq -r '.repo.gh_repo')" = "someorg/somerepo" ] || fail "--gh-repo should override slug inference"
[ "$(echo "$out3" | jq -r '.repo.remote_url')" = "null" ] || fail "remote_url should be null with no origin remote"

# --- 6: gh CLI absent (not just --no-network) --------------------------------
NOGHBIN="$WORK/no-gh-path"
mkdir -p "$NOGHBIN"
for tool in git jq sed awk grep sort mktemp date find cut printf cat sleep; do
  bin="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$bin" ] && ln -sf "$bin" "$NOGHBIN/$tool"
done
BASH_BIN="$(command -v bash)"
# Invoke bash by absolute path (so the interpreter itself doesn't need to be
# on the trimmed PATH) with a PATH that has every dependency EXCEPT `gh` —
# proves the script's own `command -v gh` degrade path, not just --no-network.
out4="$(PATH="$NOGHBIN" "$BASH_BIN" "$PROBE" --dir "$REPO" --gh-repo "someorg/somerepo")"
[ "$(echo "$out4" | jq -r '.branch_protection.available')" = "false" ] || fail "branch_protection should be unavailable with gh absent"
echo "$out4" | jq -e '.branch_protection.reason | test("gh CLI not found")' >/dev/null || fail "reason should name gh CLI absence"
[ "$(echo "$out4" | jq -r '.labels.available')" = "false" ] || fail "labels should be unavailable with gh absent"

echo "OK: test_conventions_probe.sh"
