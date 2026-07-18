#!/usr/bin/env bash
#
# Fast, direct-invocation unit tests for update.sh — `temperloop update`
# (temperloop#429, ADR 0002 "Managed-clone state ownership"). Invokes
# bin/subcommands/update.sh DIRECTLY (bypassing the `temperloop` dispatcher's
# claude/gh prereq gate — same idiom test_uninstall.sh/test_eject.sh already
# use, since update.sh never calls either tool), covering the cheap/fast
# argument-parsing and refusal paths that don't need a full managed-clone
# fixture.
#
# The heavier end-to-end coverage (a real fixture upstream, a real shallow-
# clone-to-tag journey, install+doctor, the schema gate, the consent gate —
# acceptance criteria 1, 2, 3, 4 of temperloop#429) lives in
# workflows/scripts/tests/test_update_subcommand.sh; this suite deliberately
# does not duplicate that.
#
# SAFETY: update.sh moves the HEAD of the checkout it is invoked FROM. Every
# invocation below targets a synthetic throwaway git repo under a mktemp
# dir — never $REPO_ROOT or any real checkout.
#
# No network. No real HOME/XDG mutation.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE="$HERE/../update.sh"

fail_count=0
pass_count=0

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  ok - $desc (exit $actual)"
    pass_count=$((pass_count + 1))
  else
    echo "  NOT OK - $desc (expected exit $expected, got $actual)"
    fail_count=$((fail_count + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    echo "  ok - $desc"
    pass_count=$((pass_count + 1))
  else
    echo "  NOT OK - $desc (expected output to contain: $needle)"
    echo "    --- actual output ---"
    while IFS= read -r line; do echo "    $line"; done <<<"$haystack"
    fail_count=$((fail_count + 1))
  fi
}

[[ -x "$UPDATE" ]] || { echo "FAIL: $UPDATE is not present/executable"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# T1 — --help / -h prints usage, exit 0.
# ---------------------------------------------------------------------------
echo "T1: --help prints usage, exit 0"
out="$(bash "$UPDATE" --help 2>&1)"; rc=$?
assert_exit "T1 exits 0" 0 "$rc"
assert_contains "T1 shows usage" "usage: update.sh" "$out"

# ---------------------------------------------------------------------------
# T2 — an unknown flag is a usage error, exit 2.
# ---------------------------------------------------------------------------
echo "T2: unknown flag -> exit 2"
out="$(bash "$UPDATE" --bogus-flag 2>&1)"; rc=$?
assert_exit "T2 exits 2" 2 "$rc"
assert_contains "T2 names the bad flag" "unknown arg: --bogus-flag" "$out"

# ---------------------------------------------------------------------------
# T3 — --to with no argument is a usage error, exit 2 (never hangs reading a
#      nonexistent next arg).
# ---------------------------------------------------------------------------
echo "T3: --to with no argument -> exit 2"
out="$(bash "$UPDATE" --to 2>&1)"; rc=$?
assert_exit "T3 exits 2" 2 "$rc"
assert_contains "T3 explains the missing argument" "--to requires a tag argument" "$out"

# ---------------------------------------------------------------------------
# T4 — run from a directory tree that is not a managed clone at all (no
#      .git anywhere above it) -> refuses legibly, exit 1, no git commands
#      attempted.
# ---------------------------------------------------------------------------
echo "T4: not a git checkout -> refuses legibly, exit 1"
NOT_A_REPO="$TMP_ROOT/not-a-repo"
mkdir -p "$NOT_A_REPO/bin/subcommands" "$NOT_A_REPO/bin/lib" "$NOT_A_REPO/workflows/scripts/lib"
cp "$UPDATE" "$NOT_A_REPO/bin/subcommands/update.sh"
cp "$HERE/../../lib/common.sh" "$NOT_A_REPO/bin/lib/common.sh"
out="$(cd /tmp && GIT_CEILING_DIRECTORIES=/tmp bash "$NOT_A_REPO/bin/subcommands/update.sh" --yes 2>&1)"; rc=$?
assert_exit "T4 exits 1" 1 "$rc"
assert_contains "T4 names the refusal" "is not a git checkout" "$out"

# ---------------------------------------------------------------------------
# T5 — a real (non-shallow, already-tagged, already up to date) throwaway
#      git repo: `update.sh --to <current-tag>` reports "already at" and
#      exits 0 WITHOUT prompting (no consent gate reached — nothing to
#      confirm).
# ---------------------------------------------------------------------------
echo "T5: already at the target tag -> 'already at', exit 0, no prompt"
REPO="$TMP_ROOT/repo5"
mkdir -p "$REPO"
git init -q --initial-branch=main "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@t.com commit -q --allow-empty -m init
mkdir -p "$REPO/bin/subcommands" "$REPO/bin/lib" "$REPO/workflows/scripts/lib" "$REPO/workflows/scripts/install"
cp "$UPDATE" "$REPO/bin/subcommands/update.sh"
cp "$HERE/../../lib/common.sh" "$REPO/bin/lib/common.sh"
cp "$HERE/../../../workflows/scripts/lib/changelog.sh" "$REPO/workflows/scripts/lib/changelog.sh"
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@t.com commit -q -m "vendor minimal update.sh + libs"
# Tag AFTER the vendoring commit, so HEAD lands EXACTLY on v1.0.0 (an
# earlier tag-then-commit ordering leaves HEAD one commit ahead of the tag,
# which is a different — untagged-tip — scenario, not this test's own).
git -C "$REPO" -c user.name=t -c user.email=t@t.com tag -a v1.0.0 -m v1.0.0
# `origin` must exist (update.sh always fetches) — point it at itself
# (a no-op fetch/self-remote, harmless and network-free).
git -C "$REPO" remote add origin "$REPO"
out="$(cd /tmp && bash "$REPO/bin/subcommands/update.sh" --to v1.0.0 </dev/null 2>&1)"; rc=$?
assert_exit "T5 exits 0" 0 "$rc"
assert_contains "T5 reports already up to date" "already at v1.0.0 — nothing to do" "$out"
if grep -qF "Proceed with this update?" <<<"$out"; then
  echo "  NOT OK - T5 should never reach the consent prompt when already up to date"
  fail_count=$((fail_count + 1))
else
  echo "  ok - T5 never reaches the consent gate (nothing to confirm)"
  pass_count=$((pass_count + 1))
fi

echo
echo "test_update.sh: $pass_count passed, $fail_count failed"
if (( fail_count > 0 )); then
  exit 1
fi
exit 0
