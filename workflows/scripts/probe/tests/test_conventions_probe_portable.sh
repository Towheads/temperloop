#!/usr/bin/env bash
#
# test-conventions-probe-portable (temperloop#416) — regression test for the
# portable-config fix: conventions-probe.sh's emitted `repo.dir` field must
# never carry an absolute local filesystem path. That field's ONLY consumer
# is `foundation init` (bin/subcommands/init.sh), which folds the probe's
# stdout VERBATIM into a target repo's COMMITTED `.foundation/config`,
# proposed via a real reviewable PR — an absolute path there is exactly the
# machine-private leak temperloop#416 reported (a consultant's local
# checkout path landing in someone else's repo history). This test asserts
# the emitted document (the same JSON `foundation init` embeds under its
# `probe` key) carries no such path, by probing a fixture repo deliberately
# rooted UNDER $HOME so a leak has something concrete to be caught leaking.
#
# Zero network (--no-network), scratch fixture repo, no real GitHub API call
# — same shape as the sibling test_conventions_probe.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$HERE/../conventions-probe.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

# Root the fixture under $HOME (not $TMPDIR, which on macOS lives under
# /var/folders and would never exercise a $HOME-prefixed leak) so the probed
# path is guaranteed to be a real, machine-specific absolute path — the
# exact shape temperloop#416 reported (a consultant's checkout under their
# home directory). Falls back to a plain mktemp dir (still an absolute path,
# just not necessarily $HOME-prefixed) if $HOME isn't writable in this
# sandbox — the "no absolute path at all" assertion below still holds either
# way.
if [ -n "${HOME:-}" ] && [ -w "$HOME" ]; then
  WORK="$(mktemp -d "$HOME/.conventions-probe-portable-test-XXXXXX")"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/conventions-probe-portable-test-XXXXXX")"
fi
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

REPO="$WORK/client-acme-checkout"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" commit -q --allow-empty -m "chore: seed fixture"

out="$(bash "$PROBE" --dir "$REPO" --no-network)"
echo "$out" | jq empty || fail "output is not valid JSON"

# 1. The field itself: always null, never a string.
[ "$(echo "$out" | jq -r '.repo.dir')" = "null" ] || fail "repo.dir should be null, not an absolute path"

# 2. Belt-and-suspenders — the WHOLE emitted document (this is what
#    `foundation init` embeds verbatim into the committed .foundation/config)
#    must not contain the fixture's own absolute path, a literal /Users/
#    prefix, or the real $HOME value, under any key.
if printf '%s' "$out" | grep -qF "$REPO"; then
  fail "emitted config contains the fixture's absolute local path: $REPO"
fi
if printf '%s' "$out" | grep -q '/Users/'; then
  fail "emitted config contains a /Users/-prefixed absolute path"
fi
if [ -n "${HOME:-}" ] && printf '%s' "$out" | grep -qF "$HOME"; then
  fail "emitted config contains the literal \$HOME value"
fi

# 3. Every other field the probe emits still resolves normally — the fix
#    must not have broken anything else in `repo`.
[ "$(echo "$out" | jq -r '.repo.default_branch')" = "main" ] || fail "default_branch should still resolve to main"
[ "$(echo "$out" | jq -r '.schema')" = "1" ] || fail "schema should still be 1"

echo "OK: test_conventions_probe_portable.sh"
