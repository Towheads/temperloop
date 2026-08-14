#!/usr/bin/env bash
#
# test_source_identity_seam.sh — regression guard for temperloop#1357 (epic
# #1411): `source_slug` — the value that feeds the handoff banner, the
# consent block's `source :` line, AND `testbed_record_add`'s persisted
# `.source_repo` — was computed ONCE in the DRIVER (bin/subcommands/
# testbed.sh) as a bare `git remote get-url origin` read in the DRIVER's
# OWN cwd, identically for both providers. record.sh's own documented
# schema says `.source_repo` is "null for materialize-from-seed" — but a
# `materialize-from-seed` run started from inside ANY git checkout that
# happens to have an `origin` remote (the likely case for someone trying
# the demo from a real clone) silently captured that UNRELATED repository's
# slug instead: a schema violation, persisted, and — since `temperloop
# uninstall` (temperloop#1358) now prints teardown guidance sourced from
# this same record — not merely cosmetic.
#
# WHY THIS DOES NOT PASS VACUOUSLY. A seed run driven from a non-git cwd
# would pass under the OLD, broken code too (`git remote get-url origin`
# resolves empty there, same as the fix's `null`). So Part B below runs
# `materialize-from-seed` from INSIDE a real git checkout that has a real
# `origin` remote — exactly the setup that used to leak that checkout's
# slug into the seed testbed's record, banner, and consent line.
#
# WHY THIS DRIVES THE REAL DRIVER, NOT source.sh's describe() BY HAND. The
# bug lived at the DRIVER's call site (which value it read and threaded
# into the record/banner/consent block), not inside describe() alone — a
# test that only calls `testbed_source_describe` would prove the SEAM is
# correct (Part A below does exactly that, cheaply) but would never exercise
# whether the DRIVER actually reads the seam's `source_repo` field instead
# of re-deriving its own. Parts B/C therefore run bin/subcommands/testbed.sh
# itself, through its REAL (non---dry-run) create path, with a fake `gh` and
# a fake `git` standing in only for the mutating calls (network `gh repo
# create`/`gh issue create`/`git push`) — same technique as
# bin/subcommands/tests/test_testbed.sh's T6, extended to two providers and
# two cwds instead of one.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
TESTBED_SH="$REPO_ROOT/bin/subcommands/testbed.sh"
SOURCE_SH="$HERE/../source.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
[ -f "$TESTBED_SH" ] || fail "bin/subcommands/testbed.sh not found at $TESTBED_SH"
[ -f "$SOURCE_SH" ] || fail "workflows/scripts/testbed/source.sh not found at $SOURCE_SH"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/testbed-source-identity-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

REAL_GIT="$(command -v git)"
export REAL_GIT

# =============================================================================
# Part A — describe()'s `source_repo` field, called directly (cheap seam-
# level sanity check; NOT a substitute for B/C, which prove the driver
# actually reads it — see header).
# =============================================================================
# shellcheck disable=SC1090
source "$SOURCE_SH"

FIXTURE_A="$WORK/fixture-a"
mkdir -p "$FIXTURE_A"
git -C "$FIXTURE_A" init -q -b main
git -C "$FIXTURE_A" config user.email "test@example.com"
git -C "$FIXTURE_A" config user.name "Test"
git -C "$FIXTURE_A" remote add origin "https://github.com/test-owner/fixture-a.git"
echo one > "$FIXTURE_A/a.txt"
git -C "$FIXTURE_A" add -A
git -C "$FIXTURE_A" commit -q -m "chore: seed fixture"

mirror_desc="$(testbed_source_describe mirror-from-repo "$FIXTURE_A")"
[ "$(jq -r '.source_repo' <<<"$mirror_desc")" = "test-owner/fixture-a" ] \
  || fail "Part A: mirror-from-repo's describe() should report source_repo=test-owner/fixture-a, got: $mirror_desc"
echo "PASS: A1 mirror-from-repo describe() reports source_repo from ITS OWN resolved dir"

seed_desc="$(testbed_source_describe materialize-from-seed "")"
[ "$(jq -r '.source_repo' <<<"$seed_desc")" = "null" ] \
  || fail "Part A: materialize-from-seed's describe() should report source_repo=null unconditionally, got: $seed_desc"
echo "PASS: A2 materialize-from-seed describe() reports source_repo=null unconditionally"

# =============================================================================
# fakes for the REAL (non---dry-run) driver runs in Parts B/C — same
# technique as bin/subcommands/tests/test_testbed.sh's T6.
# =============================================================================
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
case "${1:-}" in
  auth)
    exit 0
    ;;
  api)
    case "${2:-}" in
      user) printf '%s\n' "test-owner"; exit 0 ;;
    esac
    exit 0
    ;;
  repo)
    case "${2:-}" in
      view) exit 1 ;;   # rc 1 == "no such repo" == candidate name is free
      create) printf 'https://github.com/%s\n' "${3:-}"; exit 0 ;;
    esac
    exit 0
    ;;
  issue)
    case "${2:-}" in
      list) printf '%s' "${FAKE_GH_ISSUES_JSON:-[]}"; exit 0 ;;
      create) printf 'https://github.com/test-owner/fake-testbed/issues/1\n'; exit 0 ;;
    esac
    exit 0
    ;;
esac
exit 0
FAKE_GH_EOF
chmod +x "$BIN/gh"

# Delegates every git call to the REAL binary except `push` (the one call
# that would otherwise try to reach a fake https:// remote over the
# network). materialize-from-seed's produce_git legitimately needs real
# `init`/`add`/`commit` to succeed against its own local temp working
# directory — only the final mirror push is faked.
cat > "$BIN/git" <<'FAKE_GIT_EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    push) exit 0 ;;
  esac
done
exec "$REAL_GIT" "$@"
FAKE_GIT_EOF
chmod +x "$BIN/git"

export PATH="$BIN:$PATH"

# <cwd> <state-dir> <kind> [extra args...] -> runs testbed.sh --yes (real
# create path) from <cwd>, an isolated XDG_STATE_HOME per call so each
# part's record is independent, real providers, real driver.
run_real() {
  local cwd="$1" state="$2" kind="$3"; shift 3
  mkdir -p "$state"
  (
    cd "$cwd" || exit 1
    XDG_STATE_HOME="$state" bash "$TESTBED_SH" --source-kind "$kind" --owner test-owner --yes "$@" < /dev/null
  ) 2>&1
}

# =============================================================================
# Part B — THE REGRESSION CASE: materialize-from-seed, run for REAL, from
# INSIDE a git checkout that has its own real `origin` remote. Pre-fix, this
# is exactly the setup that leaked $UNRELATED_REPO's slug into the seed
# testbed's persisted record, consent line, and handoff banner.
# =============================================================================
UNRELATED_REPO="$WORK/unrelated-repo"
mkdir -p "$UNRELATED_REPO"
git -C "$UNRELATED_REPO" init -q -b main
git -C "$UNRELATED_REPO" config user.email "test@example.com"
git -C "$UNRELATED_REPO" config user.name "Test"
git -C "$UNRELATED_REPO" remote add origin "https://github.com/test-owner/unrelated-repo.git"
echo one > "$UNRELATED_REPO/a.txt"
git -C "$UNRELATED_REPO" add -A
git -C "$UNRELATED_REPO" commit -q -m "chore: unrelated fixture"

STATE_B="$WORK/state-b"
OUT_B="$(run_real "$UNRELATED_REPO" "$STATE_B" materialize-from-seed)"

case "$OUT_B" in
  *"unrelated-repo"*) fail "Part B: the seed run's output must never mention the unrelated repo it happened to run from, got:\n$OUT_B" ;;
esac
echo "PASS: B1 a materialize-from-seed run from inside test-owner/unrelated-repo never mentions that repo anywhere in its output"

RECORD_FILE_B="$STATE_B/temperloop/testbed-record.json"
[ -f "$RECORD_FILE_B" ] || fail "Part B: expected a record file at $RECORD_FILE_B, output:\n$OUT_B"
entry_b="$(jq -c '.testbeds["test-owner/linkrot-testbed"][0]' "$RECORD_FILE_B")"
[ "$entry_b" != "null" ] || fail "Part B: expected a record entry keyed test-owner/linkrot-testbed, got: $(cat "$RECORD_FILE_B")"
[ "$(jq -r '.source_repo' <<<"$entry_b")" = "null" ] \
  || fail "Part B: the PERSISTED record's .source_repo must be JSON null for a seed run (record.sh's own documented schema), got: $entry_b"
echo "PASS: B2 the persisted record's .source_repo is JSON null — not the unrelated repo's slug"

case "$OUT_B" in
  *"source       : (no source repository) via provider \"materialize-from-seed\""*) ;;
  *) fail "Part B: expected the consent block's source line to read '(no source repository)', not name a repo. Full output:\n$OUT_B" ;;
esac
echo "PASS: B3 the consent block's source line is correct for a seed run, not naming the unrelated repository"

case "$OUT_B" in
  *"real repository of yours in the loop"*) ;;
  *) fail "Part B: expected the handoff to make NO 'your real repo is untouched' claim on a seed run (there is none to reassure about). Full output:\n$OUT_B" ;;
esac
case "$OUT_B" in
  *"is never touched."*) fail "Part B: the handoff must not print the 'your real repo (...) is never touched' reassurance on a seed run — there is no real repo in the loop. Full output:\n$OUT_B" ;;
esac
echo "PASS: B4 the handoff makes no false 'real repo untouched' claim on a seed run"

# =============================================================================
# Part C — mirror-from-repo UNAFFECTED: run for real, from its OWN fixture
# checkout. The persisted record carries the source's own slug, and the
# handoff's reassurance still names it correctly.
# =============================================================================
MIRROR_REPO="$WORK/mirror-repo"
mkdir -p "$MIRROR_REPO"
git -C "$MIRROR_REPO" init -q -b main
git -C "$MIRROR_REPO" config user.email "test@example.com"
git -C "$MIRROR_REPO" config user.name "Test"
git -C "$MIRROR_REPO" remote add origin "https://github.com/test-owner/mirror-repo.git"
echo one > "$MIRROR_REPO/a.txt"
git -C "$MIRROR_REPO" add -A
git -C "$MIRROR_REPO" commit -q -m "chore: mirror fixture"

STATE_C="$WORK/state-c"
OUT_C="$(run_real "$MIRROR_REPO" "$STATE_C" mirror-from-repo)"

RECORD_FILE_C="$STATE_C/temperloop/testbed-record.json"
[ -f "$RECORD_FILE_C" ] || fail "Part C: expected a record file at $RECORD_FILE_C, output:\n$OUT_C"
entry_c="$(jq -c '.testbeds["test-owner/mirror-repo-testbed"][0]' "$RECORD_FILE_C")"
[ "$entry_c" != "null" ] || fail "Part C: expected a record entry keyed test-owner/mirror-repo-testbed, got: $(cat "$RECORD_FILE_C")"
[ "$(jq -r '.source_repo' <<<"$entry_c")" = "test-owner/mirror-repo" ] \
  || fail "Part C: mirror-from-repo's persisted .source_repo must be the source's own slug, got: $entry_c"
echo "PASS: C1 mirror-from-repo's persisted record still carries the source's own slug — unaffected by the fix"

case "$OUT_C" in
  *"your real repo"*"(test-owner/mirror-repo) is never touched."*) ;;
  *) fail "Part C: expected the handoff to still reassure about the real repo by name for mirror-from-repo. Full output:\n$OUT_C" ;;
esac
echo "PASS: C2 mirror-from-repo's handoff still names and reassures about the real source repo"

echo "OK: test_source_identity_seam.sh"
