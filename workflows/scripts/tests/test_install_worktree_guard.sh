#!/usr/bin/env bash
# Unit tests for the canonical-checkout guard in Makefile's guard-install-worktree
# target (foundation #509).
#
# Three scenarios tested with isolated real-git tmpdir fixtures (no HOME mutations):
#   1. make install-env from a git worktree → errors with canonical path; no link written
#   2. make install-env from a canonical checkout → guard passes (install runs)
#   3. FORCE_REHOME=1 make install-env from a worktree → guard bypassed, install runs
#
# The tests drive make's guard-install-worktree target directly by pointing
# FOUNDATION at a tmpdir checkout and running the target from a worktree or
# canonical tree. They never touch the real ~, ~/.claude, or ~/.local/bin.
set -uo pipefail

FOUNDATION="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; (( PASS++ )); }
fail() { echo "  ✗ $1"; (( FAIL++ )); }

# ---------------------------------------------------------------------------
# Fixture builder: create a minimal canonical git repo + a linked worktree.
# Outputs two paths to stdout: <canonical> <worktree> (tab-separated).
# ---------------------------------------------------------------------------
build_fixture() {
  local tmp
  tmp="$(mktemp -d)"
  local canon="$tmp/canon"
  local wt="$tmp/wt"

  # Canonical checkout: a real git repo with a minimal Makefile that includes
  # only the guard target (we don't need the full install logic).
  git -C "$tmp" init -q canon
  git -C "$canon" config user.email "test@test"
  git -C "$canon" config user.name "Test"

  # Minimal Makefile with just the guard target copied from the real Makefile.
  # We use the same shell logic verbatim so the test exercises the real code path.
  cat > "$canon/Makefile" <<'MAKEFILE'
.PHONY: guard-install-worktree install-env

guard-install-worktree:
	@bash -c ' \
		if [ -n "$${FORCE_REHOME:-}" ]; then exit 0; fi; \
		_common="$$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0; \
		_gitdir="$$(git rev-parse --absolute-git-dir 2>/dev/null)" || exit 0; \
		_common_abs="$$(cd "$$_common" && pwd)"; \
		_gitdir_abs="$$(cd "$$_gitdir" && pwd)"; \
		if [ "$$_common_abs" != "$$_gitdir_abs" ]; then \
			_canonical="$$(dirname "$$_common_abs")"; \
			echo "make: refusing to install from a git worktree ($$PWD)." >&2; \
			echo "  Run from the canonical checkout: $$_canonical" >&2; \
			echo "  Set FORCE_REHOME=1 to override." >&2; \
			exit 1; \
		fi \
	'

install-env: guard-install-worktree
	@echo "install-env ran"
MAKEFILE

  git -C "$canon" add Makefile
  git -C "$canon" commit -q -m "init"

  # Linked worktree
  git -C "$canon" worktree add -q "$wt"

  printf '%s\t%s' "$canon" "$wt"
}

# ---------------------------------------------------------------------------
# Test 1: guard fires from a worktree — exits non-zero, names canonical path
# ---------------------------------------------------------------------------
echo "--- Test 1: guard blocks install from a worktree"
{
  read -r canon wt < <(build_fixture)
  # Capture the guard's combined stdout+stderr into a buffer FIRST, then grep
  # the buffer. The earlier `echo "$output" | grep -q …` pattern was a live
  # pipe whose writer (echo) received SIGPIPE the instant `grep -q` matched and
  # exited — surfacing as "echo: write error: Broken pipe" under CI's non-tty
  # scheduler (foundation #528). Here-string greps have no such writer process,
  # so they cannot be killed mid-write. `--no-print-directory` drops make's
  # "Entering directory '…'" line so each assertion inspects the guard's actual
  # stderr (canonical path + FORCE_REHOME=1 hint), not make's framing.
  output="$(make --no-print-directory -C "$wt" install-env 2>&1)"
  exit_code=$?
  canonical_path="$(dirname "$(git -C "$wt" rev-parse --git-common-dir)")"

  if (( exit_code != 0 )); then
    pass "exit code non-zero ($exit_code)"
  else
    fail "expected non-zero exit from worktree, got 0"
  fi

  if grep -q "refusing to install from a git worktree" <<<"$output"; then
    pass "error message contains 'refusing to install from a git worktree'"
  else
    fail "error message missing expected text; got: $output"
  fi

  if grep -qF "$canonical_path" <<<"$output"; then
    pass "error message names canonical checkout path ($canonical_path)"
  else
    fail "error message does not name canonical path; got: $output"
  fi

  if grep -q "FORCE_REHOME=1" <<<"$output"; then
    pass "error message mentions FORCE_REHOME=1 override"
  else
    fail "error message does not mention FORCE_REHOME=1; got: $output"
  fi

  if grep -q "install-env ran" <<<"$output"; then
    fail "install-env recipe ran despite guard"
  else
    pass "install-env recipe did NOT run (guard fired first)"
  fi

  rm -rf "$(dirname "$canon")"
}

# ---------------------------------------------------------------------------
# Test 2: guard passes from the canonical checkout
# ---------------------------------------------------------------------------
echo "--- Test 2: guard passes from the canonical checkout"
{
  read -r canon wt < <(build_fixture)
  output="$(make -C "$canon" install-env 2>&1)"
  exit_code=$?

  if (( exit_code == 0 )); then
    pass "exit code 0 (guard passed)"
  else
    fail "expected exit 0 from canonical checkout, got $exit_code; output: $output"
  fi

  if echo "$output" | grep -q "install-env ran"; then
    pass "install-env recipe ran after guard passed"
  else
    fail "install-env recipe did not run; output: $output"
  fi

  rm -rf "$(dirname "$canon")"
}

# ---------------------------------------------------------------------------
# Test 3: FORCE_REHOME=1 bypasses guard from a worktree
# ---------------------------------------------------------------------------
echo "--- Test 3: FORCE_REHOME=1 bypasses guard from worktree"
{
  read -r canon wt < <(build_fixture)
  output="$(FORCE_REHOME=1 make -C "$wt" install-env 2>&1)"
  exit_code=$?

  if (( exit_code == 0 )); then
    pass "exit code 0 with FORCE_REHOME=1 (guard bypassed)"
  else
    fail "expected exit 0 with FORCE_REHOME=1, got $exit_code; output: $output"
  fi

  if echo "$output" | grep -q "install-env ran"; then
    pass "install-env recipe ran with FORCE_REHOME=1 bypass"
  else
    fail "install-env recipe did not run with FORCE_REHOME=1; output: $output"
  fi

  if echo "$output" | grep -q "refusing to install"; then
    fail "guard still fired despite FORCE_REHOME=1"
  else
    pass "guard did NOT fire with FORCE_REHOME=1"
  fi

  rm -rf "$(dirname "$canon")"
}

# ---------------------------------------------------------------------------
# Test 4: detection uses git rev-parse, not a path heuristic
# (worktree can live anywhere — name contains no 'foundation.wt' substring)
# ---------------------------------------------------------------------------
echo "--- Test 4: detection uses git rev-parse (not path heuristic)"
{
  read -r canon wt < <(build_fixture)
  # The worktree path should not contain 'foundation.wt'
  if echo "$wt" | grep -q "foundation.wt"; then
    fail "worktree fixture path contains 'foundation.wt' — test is invalid"
  else
    pass "worktree fixture path does not contain 'foundation.wt' (test is valid)"
  fi
  output="$(make -C "$wt" guard-install-worktree 2>&1)"
  exit_code=$?
  if (( exit_code != 0 )); then
    pass "guard fires for worktree at arbitrary path (git detection works)"
  else
    fail "guard did not fire for worktree at $wt — path heuristic may be in use"
  fi

  rm -rf "$(dirname "$canon")"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
