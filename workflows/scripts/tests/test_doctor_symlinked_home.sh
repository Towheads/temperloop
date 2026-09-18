#!/usr/bin/env bash
#
# Tests for workflows/scripts/install/doctor.sh's classify_entry() symlink
# verdict under a $HOME (or checkout root) that resolves through a symlink
# — temperloop#1909.
#
# THE BUG THIS PINS. classify_entry() decided a managed symlink's status by
# comparing the link's TARGET STRING against the expected source string. Two
# correct-but-differently-spelled paths for the SAME file then read as DRIFT.
# Live evidence (2026-09-11, kernel v0.38.0, first-run persona on macOS): a
# clean `temperloop install --yes` into an isolated `mktemp -d` home was
# immediately followed by doctor reporting ALL 24 managed symlinks as DRIFT —
# the links had been created through the resolved `/private/var/folders/...`
# spelling while doctor's own root carried the unresolved `/var/folders/...`
# one, and `readlink` on every link showed the correct target. macOS alone
# makes this the DEFAULT case for a scratch home (`/var` -> `/private/var`,
# `/tmp` -> `/private/tmp`); a bind-mounted or external-volume $HOME does the
# same on Linux. The verdict is supposed to ask "does this link point at the
# expected FILE", so it now compares identity (`test -ef`: same device +
# inode, every symlinked component followed) rather than spelling.
#
# Covers — the full discrimination set, so the naive string compare cannot be
# restored without one of these going red:
#   1. THE REGRESSION CASE — a link created through the resolved spelling of
#      a symlinked home reads OK, not DRIFT (red against the pre-fix code).
#   2. Exact-string match still reads OK (the cheap path is untouched).
#   3. GENUINE drift — a link pointing at a DIFFERENT file — is still DRIFT.
#      The discrimination half: a "fix" that returned OK unconditionally
#      would pass test 1 and fail here.
#   4. DANGLING is preserved — an exactly-matching link whose source does not
#      exist stays DANGLING, never laundered into OK by the identity fallback.
#   5. A DIFFERENTLY-spelled link whose source does not exist is DRIFT, never
#      OK — identity cannot be established, so the check does not guess.
#   6. SHADOWED — a real file where a symlink is expected — is unaffected.
#
# Hermetic and offline: every case runs under an isolated `env -i` HOME
# pointed at a throwaway tmpdir fixture, never the operator's real ~/.claude,
# and doctor itself does no network I/O. Portable: the resolution primitive
# under test is bash's own `test -ef`, so this passes on stock macOS (no GNU
# `readlink -f`, no `realpath`) exactly as it does on Linux.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DOCTOR_SH="${REPO_ROOT}/workflows/scripts/install/doctor.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-doctor-symlinked-home-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Physically resolve the fixture root FIRST (macOS: $TMPDIR is itself
# typically a symlink) so the "unresolved" and "resolved" spellings this test
# constructs below are the ones IT controls, not an accident of $TMPDIR.
TMP="$(cd "$TMP" && pwd -P)"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$DOCTOR_SH" ] || fail "0: doctor.sh not found at $DOCTOR_SH"

# ---------------------------------------------------------------------------
# Fixture layout — the shape of the reported incident.
#
#   $TMP/real/home                  the REAL home directory
#   $TMP/home -> $TMP/real/home     the symlinked spelling doctor is handed
#   $TMP/real/home/dev/kernel       a minimal kernel checkout INSIDE that home
#
# So $TMP/home/dev/kernel/claude/<f> and $TMP/real/home/dev/kernel/claude/<f>
# are the same file under two spellings — exactly the false-DRIFT setup.
# ---------------------------------------------------------------------------
REAL_HOME="${TMP}/real/home"
LINK_HOME="${TMP}/home"
REAL_KERNEL="${REAL_HOME}/dev/kernel"
LINK_KERNEL="${LINK_HOME}/dev/kernel"

mkdir -p "${REAL_HOME}/.claude" "${REAL_HOME}/.local/bin" \
         "${REAL_KERNEL}/claude" "${REAL_KERNEL}/workflows/scripts/board"
ln -s "$REAL_HOME" "$LINK_HOME"

# Managed claude/* sources. Distinct CONTENT per file so a wrong-file link is
# a real mistake rather than a coincidence of identical bytes. links_enumerate
# walks claude/*, so every file here becomes one managed ~/.claude/<name>.
for name in resolved-spelling.md exact-spelling.md wrong-file.md decoy.md shadowed.md; do
  printf 'source content for %s\n' "$name" >"${REAL_KERNEL}/claude/${name}"
done

# Case 1 (THE REGRESSION CASE) — link created through the RESOLVED home
# spelling; doctor is handed the symlinked one. Same file, different string.
ln -s "${REAL_KERNEL}/claude/resolved-spelling.md" "${REAL_HOME}/.claude/resolved-spelling.md"
# Case 2 — link created through the SAME spelling doctor is handed.
ln -s "${LINK_KERNEL}/claude/exact-spelling.md" "${REAL_HOME}/.claude/exact-spelling.md"
# Case 3 — genuine drift: points at a DIFFERENT file entirely.
ln -s "${REAL_KERNEL}/claude/decoy.md" "${REAL_HOME}/.claude/wrong-file.md"
# Case 6 — a real file where a symlink is expected.
printf 'a real file someone dropped in by hand\n' >"${REAL_HOME}/.claude/shadowed.md"

# Cases 4 and 5 ride the board-toolkit arm of links_enumerate, which
# enumerates a FIXED command list (claim/release/...) whose sources need not
# exist — the only arm where a link can be present while its expected source
# is absent, which is what DANGLING means. `claim.sh` / `release.sh` are
# deliberately NOT created under workflows/scripts/board/.
#   4: exact expected spelling, absent source            -> DANGLING
#   5: resolved (different) spelling, absent source      -> DRIFT
ln -s "${LINK_KERNEL}/workflows/scripts/board/claim.sh" "${REAL_HOME}/.local/bin/claim"
ln -s "${REAL_KERNEL}/workflows/scripts/board/release.sh" "${REAL_HOME}/.local/bin/release"

_run_doctor() {
  # Fully isolated subprocess env — never this test process's real
  # HOME/~/.claude. 2>&1 keeps any stderr in the captured output.
  local home="$1" foundation="$2"
  env -i HOME="$home" PATH="$PATH" bash "$DOCTOR_SH" "$foundation" 2>&1
}

# _status <output> <full-target-path> — the managed-link TABLE verdict for one
# entry. The table prints "  <STATUS>  <TARGET>", so field 1 is the status and
# field 2 the target path. FIRST match only: doctor repeats every non-OK entry
# in its trailing "Non-OK entries:" list in the same two-field shape, so a
# match-all would emit the verdict twice. Returns non-zero when the entry is
# absent from the output entirely.
_status() {
  awk -v t="$2" '$2 == t && !found { print $1; found = 1 } END { exit !found }' <<<"$1"
}

set +e
out="$(_run_doctor "$LINK_HOME" "$LINK_KERNEL")"
set -e

# ---------------------------------------------------------------------------
# Test 1 (THE REGRESSION CASE)
# ---------------------------------------------------------------------------
st="$(_status "$out" "${LINK_HOME}/.claude/resolved-spelling.md")" \
  || fail "1: no table row for .claude/resolved-spelling.md — got:\n$out"
[ "$st" = "OK" ] \
  || fail "1: a link created through the RESOLVED spelling of a symlinked \$HOME must read OK, got ${st} — this is temperloop#1909: a naive target-string compare reports DRIFT here"
pass "1: a correct link spelled through a resolved (symlinked) \$HOME reads OK, not DRIFT"

# ---------------------------------------------------------------------------
# Test 2 — the exact-match fast path is untouched.
# ---------------------------------------------------------------------------
st="$(_status "$out" "${LINK_HOME}/.claude/exact-spelling.md")" \
  || fail "2: no table row for .claude/exact-spelling.md — got:\n$out"
[ "$st" = "OK" ] || fail "2: an exact target-string match must still read OK, got ${st}"
pass "2: an exact target-string match still reads OK"

# ---------------------------------------------------------------------------
# Test 3 — the discrimination half: real drift stays DRIFT.
# ---------------------------------------------------------------------------
st="$(_status "$out" "${LINK_HOME}/.claude/wrong-file.md")" \
  || fail "3: no table row for .claude/wrong-file.md — got:\n$out"
[ "$st" = "DRIFT" ] \
  || fail "3: a link pointing at a DIFFERENT file must still be DRIFT, got ${st} — the identity fallback must not launder real drift into OK"
pass "3: a link pointing at a different file is still DRIFT"

# ---------------------------------------------------------------------------
# Test 4 — DANGLING preserved (exact spelling, absent source).
# ---------------------------------------------------------------------------
st="$(_status "$out" "${LINK_HOME}/.local/bin/claim")" \
  || fail "4: no table row for .local/bin/claim — got:\n$out"
[ "$st" = "DANGLING" ] \
  || fail "4: an exactly-spelled link whose source is absent must stay DANGLING, got ${st} — the identity fallback must never launder a broken link into OK"
pass "4: DANGLING is preserved"

# ---------------------------------------------------------------------------
# Test 5 — a respelled link with no source on disk is DRIFT, never OK.
# ---------------------------------------------------------------------------
st="$(_status "$out" "${LINK_HOME}/.local/bin/release")" \
  || fail "5: no table row for .local/bin/release — got:\n$out"
[ "$st" = "DRIFT" ] \
  || fail "5: a differently-spelled link whose source is absent must be DRIFT (identity is unestablishable), got ${st}"
pass "5: a differently-spelled link with no source on disk is DRIFT — the check never guesses"

# ---------------------------------------------------------------------------
# Test 6 — SHADOWED is unaffected.
# ---------------------------------------------------------------------------
st="$(_status "$out" "${LINK_HOME}/.claude/shadowed.md")" \
  || fail "6: no table row for .claude/shadowed.md — got:\n$out"
[ "$st" = "SHADOWED" ] \
  || fail "6: a real file where a symlink is expected must stay SHADOWED, got ${st}"
pass "6: a real file where a symlink is expected is still SHADOWED"

echo "All doctor symlinked-\$HOME tests passed."
