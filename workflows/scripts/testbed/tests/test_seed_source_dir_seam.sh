#!/usr/bin/env bash
#
# test_seed_source_dir_seam.sh — regression guard for temperloop#1356 (epic
# #1411): one positional argument meant "source repo directory" to
# mirror-from-repo and "seed directory" to materialize-from-seed, so the
# DRIVER's `--dir` default (`.`) silently overrode materialize-from-seed's
# already-correct in-tree default (source.sh's `_TESTBED_SEED_DIR_DEFAULT`)
# and produced the repo name `.-testbed` instead of a name derived from the
# seed's own `seed.json` (`name: "linkrot"`).
#
# WHY THIS DRIVES THE REAL DRIVER, NOT source.sh DIRECTLY. The bug lived at
# the CALL SITE in bin/subcommands/testbed.sh (which argument the driver
# hands each provider's seam functions), not inside source.sh — source.sh's
# `_testbed_seed_dir` already did the right thing with whatever it was
# given. A test that calls `testbed_source_describe` by hand with a
# hand-picked argument would only prove source.sh is correct (already
# covered by test_testbed_source.sh) and would never exercise the driver's
# own argument-resolution bug at all. So this test sources
# bin/subcommands/testbed.sh itself — via `--dry-run`, so it makes zero
# mutating calls — through the REAL provider implementations (not the
# test_provider_equivalence.sh doubles, which stand in for produce_git/
# produce_issues but still drive the REAL describe() for each kind). A fake
# `gh` on PATH (same technique as test_provider_equivalence.sh) answers the
# driver's own pre-flight/destination-resolution reads so the whole run
# stays deterministic and network-free — describe() itself needs no `gh` at
# all for either provider, so this fake exists only to satisfy pre-flight,
# not to fake the assertion under test.
#
# TWO DIFFERENT CWDS (acceptance bullet 1: "from any cwd"): Part A runs from
# a plain, non-git scratch directory; Part B runs from INSIDE an unrelated
# git checkout (the mirror-from-repo fixture repo used in Part C) whose own
# directory name is deliberately NOT "linkrot" — so a base_name that leaked
# from cwd (the pre-fix defect) would show up as something other than
# "linkrot" and fail the assertion, rather than accidentally matching by
# coincidence.
#
# THE "valid repository name" CONSTRAINT (acceptance bullet 2) IS DEFINED
# HERE, not read from production code — no repo-name validator exists
# anywhere in this tree today. Matches GitHub's own allowed charset
# (letters, digits, `_`, `.`, `-`), refuses the two dot-only pathological
# values, and caps length at 100. This is exactly the shape that flags the
# pre-fix defect: pre-fix, `base_name` for materialize-from-seed literally
# equals `.` (the driver's `--dir` default, passed through raw as the
# seed-dir argument) — a value that DOES satisfy the charset regex alone,
# which is precisely why the constraint also states the value must not be
# `.` or `..`, not just charset-match.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
TESTBED_SH="$REPO_ROOT/bin/subcommands/testbed.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
[ -f "$TESTBED_SH" ] || fail "bin/subcommands/testbed.sh not found at $TESTBED_SH"

# ---------------------------------------------------------------------------
# The "valid repository name" constraint (acceptance bullet 2). Stated once,
# asserted against every resolved name below.
# ---------------------------------------------------------------------------
REPO_NAME_RE='^[A-Za-z0-9_.-]+$'
assert_valid_repo_name() {
  local name="$1" label="$2"
  [ -n "$name" ] || fail "$label: repo name is empty"
  case "$name" in
    "." | "..") fail "$label: repo name '$name' is exactly '.' or '..' — not a valid repository name" ;;
  esac
  if ! printf '%s' "$name" | grep -E "$REPO_NAME_RE" >/dev/null; then
    fail "$label: repo name '$name' does not match $REPO_NAME_RE"
  fi
  if [ "${#name}" -gt 100 ]; then
    fail "$label: repo name '$name' is ${#name} chars, over the 100-char cap"
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/testbed-seed-seam-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- fake gh: answers every DRIVER-owned pre-flight/destination-resolution
# read. Zero network, zero mutation — --dry-run never reaches a mutating
# call anyway, but pre-flight itself (gh auth status / gh api user /
# gh repo view) runs before --dry-run's own early exit. ---------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
case "${1:-}" in
  auth) exit 0 ;;
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
esac
exit 0
FAKE_GH_EOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# --- machine-scoped state root the record library writes under (never
# actually written on --dry-run, but XDG_STATE_HOME is isolated regardless
# so a run can never touch the real machine record). -----------------------
STATE="$WORK/state"
mkdir -p "$STATE"
export XDG_STATE_HOME="$STATE"

# <cwd> <source-kind> [extra args...] -> runs testbed.sh --dry-run --yes
# from <cwd>, real providers, real driver, on stdout+stderr combined.
# Sourced (not exec'd) inside a `(...)` subshell so the driver's own `cd`
# and terminal `exit` never escape past this function — a subshell is a new
# process, so its `cd` cannot perturb this test's own cwd either.
run_dry_run() {
  local cwd="$1" kind="$2"; shift 2
  (
    cd "$cwd" || exit 1
    # shellcheck disable=SC1090
    source "$TESTBED_SH" --source-kind "$kind" --owner test-owner --yes --dry-run "$@" < /dev/null
  ) 2>&1
}

# <driver-output> -> the base_name field from the describe() JSON dump
# (Step 1's `printf '%s\n' "$source_desc" | jq -c '.'` line).
extract_base_name() {
  grep -m1 '^{"kind":' <<<"$1" | jq -r '.base_name'
}

# =============================================================================
# Part A — materialize-from-seed, from a plain non-git scratch directory.
# =============================================================================
CWD_A="$WORK/plain-scratch-dir"
mkdir -p "$CWD_A"

OUT_A="$(run_dry_run "$CWD_A" materialize-from-seed)"
BASE_A="$(extract_base_name "$OUT_A")"

[ "$BASE_A" = "linkrot" ] || fail "Part A: base_name should be 'linkrot' (the seed's own seed.json .name), got '$BASE_A'. Full output:\n$OUT_A"
assert_valid_repo_name "$BASE_A" "Part A base_name"
echo "PASS: A1 materialize-from-seed's real describe(), driven through the real driver from a plain non-git cwd, reports base_name=linkrot"

case "$OUT_A" in
  *"would run: gh repo create test-owner/linkrot-testbed --private"*) ;;
  *) fail "Part A: expected a testbed repo name derived from base_name ('test-owner/linkrot-testbed') in the dry-run plan. Full output:\n$OUT_A" ;;
esac
echo "PASS: A2 the derived testbed repo name (test-owner/linkrot-testbed) is what the dry-run reports it would create"

# =============================================================================
# Part B — materialize-from-seed again, from a SECOND, DIFFERENT cwd: inside
# an unrelated git checkout (built for Part C below) whose own directory
# name is NOT "linkrot". Proves base_name=linkrot is not an artifact of
# Part A's particular cwd, and that a cwd-leaked name (the pre-fix defect)
# would show up as something other than "linkrot" here.
# =============================================================================
FIXTURE_REPO="$WORK/fixture-repo-not-linkrot"
mkdir -p "$FIXTURE_REPO"
git -C "$FIXTURE_REPO" init -q -b main
git -C "$FIXTURE_REPO" config user.email "test@example.com"
git -C "$FIXTURE_REPO" config user.name "Test"
git -C "$FIXTURE_REPO" remote add origin "https://github.com/test-owner/fixture-repo-not-linkrot.git"
echo one > "$FIXTURE_REPO/a.txt"
git -C "$FIXTURE_REPO" add -A
git -C "$FIXTURE_REPO" commit -q -m "chore: seed fixture"

OUT_B="$(run_dry_run "$FIXTURE_REPO" materialize-from-seed)"
BASE_B="$(extract_base_name "$OUT_B")"

[ "$BASE_B" = "linkrot" ] || fail "Part B: base_name should still be 'linkrot' from inside an unrelated git checkout (dir 'fixture-repo-not-linkrot'), got '$BASE_B' — a cwd/git-derived name leaking through is exactly the regression this guards against. Full output:\n$OUT_B"
assert_valid_repo_name "$BASE_B" "Part B base_name"
echo "PASS: B1 materialize-from-seed reports base_name=linkrot from a SECOND, different cwd (inside an unrelated git checkout named 'fixture-repo-not-linkrot') — not derived from that cwd"

# =============================================================================
# Part C — mirror-from-repo unaffected (acceptance bullet 3): --dir still
# selects the source repository directory, using the SAME fixture repo Part
# B just built. Real provider, real driver, same fake gh.
# =============================================================================
OUT_C="$(run_dry_run "$WORK" mirror-from-repo --dir "$FIXTURE_REPO")"
BASE_C="$(extract_base_name "$OUT_C")"

[ "$BASE_C" = "fixture-repo-not-linkrot" ] || fail "Part C: mirror-from-repo's base_name should be the --dir repo's own name ('fixture-repo-not-linkrot'), got '$BASE_C'. Full output:\n$OUT_C"
assert_valid_repo_name "$BASE_C" "Part C base_name"
echo "PASS: C1 mirror-from-repo's real describe(), driven through the real driver, still resolves base_name from --dir's repository — unchanged by the provider-scoped argument fix"

case "$OUT_C" in
  *"would run: gh repo create test-owner/fixture-repo-not-linkrot-testbed --private"*) ;;
  *) fail "Part C: expected the mirror-from-repo testbed name derived from --dir's repo in the dry-run plan. Full output:\n$OUT_C" ;;
esac
echo "PASS: C2 mirror-from-repo's derived testbed repo name is still --dir-based"

echo "OK: test_seed_source_dir_seam.sh"
