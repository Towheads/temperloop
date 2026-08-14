#!/usr/bin/env bash
#
# test_provider_equivalence.sh — the epic's central structural claim, made
# mechanical (temperloop#1232, epic #1117): both testbed source providers
# drive ONE identical call sequence through bin/subcommands/testbed.sh's
# DRIVER, downstream of the source-provider seam. This is the guard that
# stops the prepared-source option (`materialize-from-seed`) from drifting
# into a second orchestration path — precisely how `try --demo` became a
# dead end.
#
# ── WHAT THIS PROVES, AND WHAT IT DOES NOT (load-bearing) ──────────────────
# This test proves the two providers are driven through IDENTICAL MECHANISM
# — the same seam calls, in the same order, wrapped in the same driver-owned
# pre-flight/consent/flush/handoff steps. It explicitly does NOT prove
# identical EVALUATION VALUE: mirror-from-repo and materialize-from-seed
# differ in content, promotability, and privacy exposure BY DESIGN
# (workflows/scripts/testbed/source.sh's own header; ADR 0025) — nothing
# here speaks to whether the two sources make an equally good testbed to
# evaluate against, only that the command drives both the same way.
# Content-quality and evaluation-value questions about the seed fixture
# belong to the testbed-seed-source item's own gate (`make test-demo`), not
# this one — see docs/features/testbed.md's "Provider equivalence" section
# for the same disclaimer stated for a human reader.
#
# ── WHY TEST DOUBLES, NOT THE TWO REAL PROVIDERS ────────────────────────────
# The real mirror-from-repo and materialize-from-seed both do genuine,
# provider-SPECIFIC work inside produce_git/produce_issues (a real git
# mirror push vs. a from-seed rebuild; a `gh issue list` read vs. reading
# local *.md files) — exactly the content difference this test deliberately
# does NOT assert over (that is test_testbed_source.sh's job, Parts D-F,
# plus Part G's seam-local single-path guarantee). Two DOUBLE providers
# registered here stand in for that internal work with a one-line log-write
# each, so what remains observable is exactly the DRIVER's own
# orchestration — the thing a provider-agnostic-orchestration bug would
# corrupt. Driving the driver (not source.sh directly) is what makes a bug
# in testbed.sh itself (as opposed to in a provider) fail HERE. Doubles also
# make the assertion resilient to `--teardown` (#1231, landing at the same
# level): this test exercises the CREATE path only, never asserts an exact
# flag count or total output size, and never inspects the command for the
# presence or absence of a `--teardown` mode.
#
# ── TWO ASSERTIONS ──────────────────────────────────────────────────────────
#   Part A — the SEAM CALL sequence: each double logs the bare fact "I was
#     called" (op name + the dest/src the DRIVER passed it, no provider
#     identity) to its own log; the two logs are asserted byte-identical to
#     each other AND to the one expected sequence.
#   Part B — the DRIVER's OWN observable step/pre-flight/flush/handoff
#     sequence, extracted from stdout and asserted identical between the two
#     runs after normalizing only the record's opaque timestamp id. The
#     lines that legitimately carry source identity (the describe() JSON
#     dump, the "source : ... via provider ..." consent line, and the
#     provenance_capable/promotable line) are excluded from the comparison
#     BY NAME, and a separate sanity assertion proves those lines DO differ
#     between the two runs — so the exclusion is a deliberate "modulo source
#     identity", not an accidental blind spot.
#
# Deterministic and network-free: a fake `gh` on PATH answers every
# DRIVER-owned pre-flight/create call from fixed data — no real GitHub call
# anywhere, and the doubles' own produce_git/produce_issues are log-writes,
# not `git`/`gh` invocations at all. The one real `git` usage is a throwaway
# local fixture repo the driver's own `--dir` resolution and `origin`-remote
# read touch (zero network, zero mutation, real binary).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
TESTBED_SH="$REPO_ROOT/bin/subcommands/testbed.sh"
RECORD_LIB="$REPO_ROOT/workflows/scripts/testbed/record.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
[ -f "$TESTBED_SH" ] || fail "bin/subcommands/testbed.sh not found at $TESTBED_SH"
[ -f "$RECORD_LIB" ] || fail "workflows/scripts/testbed/record.sh not found at $RECORD_LIB"

# shellcheck source=../record.sh
. "$RECORD_LIB"

# testbed_record_add's REAL validation (record.sh's own, correctly) refuses
# any source_kind outside the literal {mirror-from-repo, materialize-from-seed}
# enum — a double's kind name must NOT collide with either real provider (see
# the double definitions below: colliding would let testbed.sh's own,
# non-idempotent `. "$SOURCE_LIB"` silently overwrite the double with the
# REAL provider implementation, defeating the whole point of a double). So
# this override relaxes ONLY the kind check, reusing record.sh's own already-
# sourced helpers (testbed_record_load/_testbed_record_write/
# _testbed_record_new_id) for everything else — record.sh's OWN validation
# behavior is record's to test (test_testbed_record.sh), not this file's.
#
# This override SURVIVES testbed.sh's internal `. "$RECORD_LIB"` re-source
# only because record.sh guards itself against double-sourcing
# (`_TEMPERLOOP_TESTBED_RECORD_SH_LOADED`): having already sourced it once,
# right here, that guard variable is inherited by every `run_double` subshell
# below, so testbed.sh's own re-source is a no-op and this definition stands.
testbed_record_add() {
  local key="$1" source_kind="$2" source_repo="$3" promotable="$4"
  local id created_at json new_json
  id="$(_testbed_record_new_id)"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  json="$(testbed_record_load)" || return 1
  new_json="$(jq \
    --arg k "$key" --arg id "$id" --arg created_at "$created_at" \
    --arg source_kind "$source_kind" --arg source_repo "$source_repo" \
    --argjson promotable "$promotable" \
    '.testbeds[$k] = ((.testbeds[$k] // []) + [{
        id: $id, created_at: $created_at, testbed_repo: $k,
        source_kind: $source_kind,
        source_repo: (if $source_repo == "" then null else $source_repo end),
        promotable: $promotable,
        artifacts: { repo_created: true, mirror_pushed: false, issues_copied: false }
      }])' <<<"$json")" || return 1
  _testbed_record_write "$new_json" || return 1
  printf '%s\n' "$id"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/testbed-equiv-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- fixture git repo (real git, read-only from the driver's point of view:
# `git remote get-url origin` / `git rev-parse --show-toplevel`) -----------
REPO="$WORK/fixture-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "https://github.com/test-owner/test-repo.git"
echo one > "$REPO/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "chore: seed fixture"

# --- machine-scoped state root the record library writes under ------------
STATE="$WORK/state"
mkdir -p "$STATE"
export XDG_STATE_HOME="$STATE"
RECORD_FILE="$STATE/temperloop/testbed-record.json"

# --- fake gh: answers every DRIVER-owned pre-flight/create call. Neither
# double calls gh at all (their produce_issues is a log-write), so this
# fake never needs an `issue list`/`issue create` branch. -------------------
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

# =============================================================================
# The two DOUBLES. Same shape, same arity as the seam's real five-function
# contract (workflows/scripts/testbed/source.sh's own header — `dir_arg()`
# plus the original four); the ONLY things that differ between them are their
# kind name and their describe() capability flags — exactly the "source
# identity" this test excludes from the sequence comparison and separately
# asserts DOES differ (Part B below). Both share ONE preflight-check function
# name, `_double_check_ok`, so the driver's pre-flight UNION (its own checks
# + the provider's) prints the identical ordered list for both runs.
#
# `dir_arg()` is deliberately NOT logged to CALL_LOG: it is a pure,
# zero-read string-selection step the driver runs once, before Step 1, to
# resolve which of its own --dir/--seed-dir values this provider means (see
# testbed.sh's "PROVIDER-SCOPED SOURCE ARGUMENT RESOLUTION") — not one of
# the four content-producing seam calls Part A's sequence assertion is
# about. Both doubles return their first argument verbatim (mirroring the
# real mirror-from-repo provider's own dir_arg()), so `produce_git`/
# `produce_issues` below still see `src=.` exactly as before.
# =============================================================================
_double_check_ok() { return 0; }

_testbed_provider_double_a_dir_arg() {
  printf '%s' "${1:-}"
}
_testbed_provider_double_a_describe() {
  printf 'describe\n' >> "$CALL_LOG"
  jq -cn '{kind:"double-a", base_name:"double-fixture-a", provenance_capable:true, promotable:true}'
}
_testbed_provider_double_a_preflight_checks() {
  printf 'preflight_checks\n' >> "$CALL_LOG"
  printf '%s\n' _double_check_ok
}
_testbed_provider_double_a_produce_git() {
  printf 'produce_git dest=%s src=%s\n' "$1" "$2" >> "$CALL_LOG"
}
_testbed_provider_double_a_produce_issues() {
  printf 'produce_issues dest=%s src=%s\n' "$1" "$2" >> "$CALL_LOG"
}

_testbed_provider_double_b_dir_arg() {
  printf '%s' "${1:-}"
}
_testbed_provider_double_b_describe() {
  printf 'describe\n' >> "$CALL_LOG"
  jq -cn '{kind:"double-b", base_name:"double-fixture-b", provenance_capable:false, promotable:false}'
}
_testbed_provider_double_b_preflight_checks() {
  printf 'preflight_checks\n' >> "$CALL_LOG"
  printf '%s\n' _double_check_ok
}
_testbed_provider_double_b_produce_git() {
  printf 'produce_git dest=%s src=%s\n' "$1" "$2" >> "$CALL_LOG"
}
_testbed_provider_double_b_produce_issues() {
  printf 'produce_issues dest=%s src=%s\n' "$1" "$2" >> "$CALL_LOG"
}

# <kind> <call-log-path> -> sources testbed.sh (NOT execs it — a subprocess
# would not see the double functions defined above, since testbed.sh sources
# the real source.sh via a fixed physical path with no override seam) inside
# a command substitution, which forks a subshell for free: the driver's own
# global-variable mutations (testbed_owner, preflight_fns, ...) and its
# terminal `exit` never escape past this function. --owner/--name are PINNED
# identically across both calls so the created testbed_slug (and therefore
# testbed_url, and every line derived from it) is byte-identical between the
# two runs — the only remaining axis of difference is the double's own
# describe() payload and the seam-call log this double writes.
LAST_OUT=""
LAST_RC=0
run_double() {
  local kind="$1" log="$2"
  : > "$log"
  rm -f "$RECORD_FILE"
  set +e
  LAST_OUT="$(
    export CALL_LOG="$log"
    source "$TESTBED_SH" --dir "$REPO" --source-kind "$kind" \
      --owner test-owner --name equiv-testbed --yes 2>&1 < /dev/null
  )"
  LAST_RC=$?
  set -e
}

CALL_LOG_A="$WORK/call-log-a.txt"
CALL_LOG_B="$WORK/call-log-b.txt"

run_double double-a "$CALL_LOG_A"
[ "$LAST_RC" -eq 0 ] || fail "double-a run should exit 0, got $LAST_RC. Output:\n$LAST_OUT"
OUT_A="$LAST_OUT"

run_double double-b "$CALL_LOG_B"
[ "$LAST_RC" -eq 0 ] || fail "double-b run should exit 0, got $LAST_RC. Output:\n$LAST_OUT"
OUT_B="$LAST_OUT"

echo "PASS: both doubles drive the command to completion (rc=0)"

# =============================================================================
# Part A — the SEAM CALL sequence: op name + the dest/src the DRIVER handed
# it, no provider identity anywhere in the log line. Both logs must be
# non-empty, byte-identical to EACH OTHER, and byte-identical to the one
# EXPECTED sequence (a non-tautological check: two empty logs would also be
# "identical to each other", so pin the exact expected content too).
# =============================================================================
EXPECTED_LOG="$WORK/expected-call-log.txt"
cat > "$EXPECTED_LOG" <<EOF
describe
preflight_checks
produce_git dest=https://github.com/test-owner/equiv-testbed.git src=.
produce_issues dest=test-owner/equiv-testbed src=.
EOF

[ -s "$CALL_LOG_A" ] || fail "double-a's seam-call log is empty — the driver never reached the double"
[ -s "$CALL_LOG_B" ] || fail "double-b's seam-call log is empty — the driver never reached the double"

if ! diff_out="$(diff "$CALL_LOG_A" "$CALL_LOG_B" 2>&1)"; then
  fail "the driver issued a DIFFERENT seam-call sequence for the two providers (must be identical, modulo source identity — which never appears in this log):\n$diff_out"
fi
echo "PASS: A1 the two providers see an IDENTICAL seam-call sequence (op + dest + src), byte-for-byte"

if ! diff_out="$(diff "$EXPECTED_LOG" "$CALL_LOG_A" 2>&1)"; then
  fail "the seam-call sequence does not match the expected describe -> preflight_checks -> produce_git -> produce_issues order/args:\n$diff_out"
fi
echo "PASS: A2 the shared sequence matches the expected describe -> preflight_checks -> produce_git(dest,src) -> produce_issues(dest,src) order"

# =============================================================================
# Part B — the DRIVER's own observable step/pre-flight/flush/handoff
# sequence, normalized and compared. Excludes exactly three lines that
# legitimately carry source identity — normalize_driver_trace names them so
# the exclusion is visible in the diff, not silent.
# =============================================================================
normalize_driver_trace() {
  # Drop the three lines that legitimately differ by provider identity:
  #   - the describe() JSON dump (`{"kind":...}`)
  #   - the consent block's "source : ... via provider "<kind>"" line
  #   - the consent block's "provenance : provenance_capable=... promotable=..." line
  # Then blank the record's opaque per-run timestamp id so an otherwise
  # identical flush line compares equal.
  grep -vE '^\{"kind":|^  source       : |^  provenance   : ' \
    | sed -E 's/\([0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]+\)/(<ID>)/g'
}

NORM_A="$(normalize_driver_trace <<<"$OUT_A")"
NORM_B="$(normalize_driver_trace <<<"$OUT_B")"

if [ "$NORM_A" != "$NORM_B" ]; then
  diff_out="$(diff <(printf '%s\n' "$NORM_A") <(printf '%s\n' "$NORM_B") 2>&1 || true)"
  fail "the driver's own step/pre-flight/flush/handoff sequence differs between providers after normalizing only the identity lines + record id:\n$diff_out"
fi
echo "PASS: B1 the driver's normalized step/pre-flight/flush/handoff trace is identical between providers"

# The comparison above is only meaningful if it is actually checking
# something — assert the normalized trace still carries every fixed-driver
# marker, in the fixed order testbed.sh's own header documents:
#   describe -> union(preflight_checks) -> consent -> create+FLUSH ->
#   produce_git+FLUSH -> produce_issues+FLUSH -> handoff
markers=(
  "-- 1. Resolve the source (provider seam: describe) --"
  "-- 2. Pre-flight (all reads"
  "-- 3. Consent (this creates a REAL private GitHub repository) --"
  "-- 4. Create the testbed repository --"
  "Created https://github.com/test-owner/equiv-testbed (private)"
  "repo_created recorded"
  "-- 5. Mirror the git history (provider seam: produce_git) --"
  "Mirror pushed to https://github.com/test-owner/equiv-testbed"
  "mirror_pushed recorded"
  "-- 6. Copy the open issues (provider seam: produce_issues) --"
  "issues_copied recorded"
  "-- Handoff --"
  "YOUR EVALUATION TESTBED IS READY"
  "Testbed: https://github.com/test-owner/equiv-testbed"
  "cd equiv-testbed"
  "temperloop init"
  "next step: temperloop init"
)
prev_pos=0
for m in "${markers[@]}"; do
  rest="${NORM_A:$prev_pos}"
  case "$rest" in
    *"$m"*) ;;
    *) fail "expected driver step marker missing (or out of order) in the normalized trace: $m" ;;
  esac
  # Advance past this marker's first occurrence so the NEXT marker must
  # appear strictly AFTER it — this is what proves ORDER, not just presence.
  prefix="${rest%%"$m"*}"
  prev_pos=$((prev_pos + ${#prefix} + ${#m}))
done
echo "PASS: B2 every fixed driver step/flush/handoff marker is present, in the documented order"

# The pre-flight UNION prints in a fixed order: the driver's own
# gh-availability check, then the provider's (shared, both doubles), then
# the driver's collision-safe destination check — asserted literally so B1's
# equality is not the only thing standing between this test and a silent
# reordering.
expected_ok=$'  [ok]   _testbed_check_gh_available\n  [ok]   _double_check_ok\n  [ok]   _testbed_check_destination'
ok_lines_A="$(grep '^  \[ok\]' <<<"$OUT_A")"
ok_lines_B="$(grep '^  \[ok\]' <<<"$OUT_B")"
[ "$ok_lines_A" = "$expected_ok" ] || fail "double-a's pre-flight union order is wrong, got:\n$ok_lines_A"
[ "$ok_lines_B" = "$expected_ok" ] || fail "double-b's pre-flight union order is wrong, got:\n$ok_lines_B"
echo "PASS: B3 the pre-flight union order (driver check -> provider check -> driver check) is identical and correct for both providers"

# =============================================================================
# Sanity check on the exclusion itself: the three lines normalize_driver_trace
# drops MUST actually differ between the two runs — otherwise "modulo source
# identity" would be vacuous (nothing was ever excluded in practice) rather
# than a deliberate, exercised carve-out.
# =============================================================================
case "$OUT_A" in
  *'{"kind":"double-a"'*) ;;
  *) fail "sanity: double-a's own describe() JSON is missing from its run's output" ;;
esac
case "$OUT_B" in
  *'{"kind":"double-b"'*) ;;
  *) fail "sanity: double-b's own describe() JSON is missing from its run's output" ;;
esac
case "$OUT_A" in
  *'source       : test-owner/test-repo via provider "double-a"'*) ;;
  *) fail "sanity: double-a's 'source : ... via provider' consent line is missing or wrong" ;;
esac
case "$OUT_B" in
  *'source       : test-owner/test-repo via provider "double-b"'*) ;;
  *) fail "sanity: double-b's 'source : ... via provider' consent line is missing or wrong" ;;
esac
case "$OUT_A" in
  *'provenance   : provenance_capable=true  promotable=true'*) ;;
  *) fail "sanity: double-a's provenance line should read capable=true promotable=true" ;;
esac
case "$OUT_B" in
  *'provenance   : provenance_capable=false  promotable=false'*) ;;
  *) fail "sanity: double-b's provenance line should read capable=false promotable=false" ;;
esac
echo "PASS: C1 the three excluded identity lines genuinely differ between providers — the 'modulo source identity' carve-out is real, not vacuous"

echo "OK: test_provider_equivalence.sh"
