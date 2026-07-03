#!/usr/bin/env bash
#
# Tests for seed-demo-repo.sh (foundation #851). Zero network: the script is
# driven as a SUBPROCESS with a fake `gh` on PATH (mirroring the board
# toolkit's test convention, e.g. board/tests/test_capture.sh) that answers
# every `gh` read call from env-var fixtures and logs every call it sees.
# All scenarios run under --dry-run, so every WRITE gh call is intercepted
# and printed by the script itself (never reaches the fake gh at all) —
# assertions read those "[dry-run] gh ..." lines, not the fake gh's log.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED="$HERE/../seed-demo-repo.sh"
TEST_REPO="test-owner/test-demo"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

BIN="$(mktemp -d "${TMPDIR:-/tmp}/seed-demo-bin-XXXXXX")"
CALL_LOG="$BIN/calls.log"
cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"

case "$1" in
  repo)
    case "$2" in
      view) exit "${FAKE_REPO_VIEW_RC:-0}" ;;
      create) exit 0 ;;
    esac
    exit 0
    ;;
  api)
    path="$2"
    is_put=0
    for a in "$@"; do
      [ "$a" = "-X" ] && is_put=1
    done
    case "$path" in
      */contents/*)
        if [ "$is_put" -eq 1 ]; then
          exit 0
        fi
        file="${path##*/contents/}"
        for f in $FAKE_EXISTING_FILES; do
          if [ "$f" = "$file" ]; then
            echo "deadbeef"
            exit 0
          fi
        done
        # Real gh prints the raw error JSON to stdout on a 404 even with
        # -q set — reproduce that so the test proves the script's guard is
        # on exit status, not stdout content.
        echo '{"message":"Not Found","status":"404"}'
        exit 1
        ;;
    esac
    exit 0
    ;;
  label)
    case "$2" in
      list)
        for l in $FAKE_LABELS; do
          echo "$l"
        done
        exit 0
        ;;
      create) exit 0 ;;
    esac
    ;;
  issue)
    case "$2" in
      list)
        state=""
        prev=""
        for a in "$@"; do
          [ "$prev" = "--state" ] && state="$a"
          prev="$a"
        done
        if [ "$state" = "all" ]; then
          printf '%s\n' "$FAKE_EXISTING_TITLES"
        elif [ "$state" = "open" ]; then
          printf '%s\n' "$FAKE_OPEN_NUMBERS"
        fi
        exit 0
        ;;
      create) exit 0 ;;
      close) exit 0 ;;
    esac
    ;;
esac
exit 0
FAKE_GH_EOF
chmod +x "$BIN/gh"

cat > "$BIN/base64" <<'FAKE_B64_EOF'
#!/usr/bin/env bash
exec /usr/bin/base64 "$@"
FAKE_B64_EOF
chmod +x "$BIN/base64"

trap 'rm -rf "$BIN"' EXIT

# run WANT_RC ARGS... — invoke seed-demo-repo.sh with the fake gh on PATH;
# sets $out to combined stdout+stderr, asserts exit code.
run() {
  local want="$1"
  shift
  : > "$CALL_LOG"
  local rc=0
  out="$(PATH="$BIN:$PATH" \
    FAKE_REPO_VIEW_RC="${FAKE_REPO_VIEW_RC:-0}" \
    FAKE_EXISTING_FILES="${FAKE_EXISTING_FILES:-}" \
    FAKE_LABELS="${FAKE_LABELS:-}" \
    FAKE_EXISTING_TITLES="${FAKE_EXISTING_TITLES:-}" \
    FAKE_OPEN_NUMBERS="${FAKE_OPEN_NUMBERS:-}" \
    CALL_LOG="$CALL_LOG" \
    bash "$SEED" "$@" 2>&1)" || rc=$?
  [ "$rc" -eq "$want" ] || fail "expected exit $want for [$*], got $rc (out: $out)"
}

assert_contains() {
  case "$out" in
    *"$1"*) ;;
    *) fail "expected output to contain: $1 (got: $out)" ;;
  esac
}

assert_not_contains() {
  case "$out" in
    *"$1"*) fail "expected output to NOT contain: $1 (got: $out)" ;;
    *) ;;
  esac
}

count_matches() {
  # count_matches PATTERN — count non-overlapping literal-line matches of
  # PATTERN in $out.
  printf '%s\n' "$out" | grep -Fc "$1" || true
}

# ---------------------------------------------------------------------------
# T1 -- --help / -h: usage on exit 0, no gh calls at all.
# ---------------------------------------------------------------------------
run 0 --help
assert_contains "usage: seed-demo-repo.sh"
[ ! -s "$CALL_LOG" ] || fail "--help reached gh (log: $(cat "$CALL_LOG"))"
echo "PASS: --help prints usage, exit 0, no gh calls"

run 0 -h
assert_contains "usage: seed-demo-repo.sh"
[ ! -s "$CALL_LOG" ] || fail "-h reached gh"
echo "PASS: -h prints usage, exit 0, no gh calls"

# ---------------------------------------------------------------------------
# T2 -- unknown flag: exit 2, no gh calls.
# ---------------------------------------------------------------------------
run 2 --bogus
[ ! -s "$CALL_LOG" ] || fail "unknown flag reached gh"
echo "PASS: unknown flag exits 2 without touching gh"

# ---------------------------------------------------------------------------
# T3 -- empty --repo value: exit 2, no gh calls.
# ---------------------------------------------------------------------------
run 2 --repo ""
[ ! -s "$CALL_LOG" ] || fail "empty --repo reached gh"
echo "PASS: empty --repo exits 2 without touching gh"

# ---------------------------------------------------------------------------
# T4 -- fresh repo (repo view fails, nothing exists yet): --dry-run creates
# everything exactly once.
# ---------------------------------------------------------------------------
FAKE_REPO_VIEW_RC=1
FAKE_EXISTING_FILES=""
FAKE_LABELS=""
FAKE_EXISTING_TITLES=""
run 0 --repo "$TEST_REPO" --dry-run
assert_contains "Creating $TEST_REPO"
for f in greet.sh add_one.sh CONTRIBUTING.md README.md; do
  assert_contains "-> creating $f"
done
[ "$(count_matches "contents/greet.sh")" -eq 1 ] || fail "expected exactly one greet.sh content PUT, got: $out"
assert_contains "Creating 'demo-seed' label"
for t in \
  "greet.sh misspells its own greeting" \
  "add_one.sh adds 2 instead of 1" \
  "CONTRIBUTING.md has the typo" \
  "README.md links to a nonexistent CONTRIBUTE.md"; do
  assert_contains "-> creating issue: $t"
done
echo "PASS: fresh repo dry-run creates repo + 4 files + label + 4 issues"

# ---------------------------------------------------------------------------
# T5 -- everything already exists: --dry-run is a pure no-op (no
# "[dry-run] gh" write lines at all), proving idempotence AND proving the
# remote_file_sha 404-body guard doesn't false-positive on the real repo
# (FAKE_EXISTING_FILES here covers every starter file, each answered with a
# genuine sha, not the fake 404 body).
# ---------------------------------------------------------------------------
FAKE_REPO_VIEW_RC=0
FAKE_EXISTING_FILES="greet.sh add_one.sh CONTRIBUTING.md README.md"
FAKE_LABELS="demo-seed"
FAKE_EXISTING_TITLES="greet.sh misspells its own greeting ('Helllo' instead of 'Hello')
add_one.sh adds 2 instead of 1
CONTRIBUTING.md has the typo 'recieve' (should be 'receive')
README.md links to a nonexistent CONTRIBUTE.md (should be CONTRIBUTING.md)"
run 0 --repo "$TEST_REPO" --dry-run
assert_contains "$TEST_REPO already exists"
for f in greet.sh add_one.sh CONTRIBUTING.md README.md; do
  assert_contains "-> $f already present, leaving as-is"
done
for t in \
  "greet.sh misspells its own greeting" \
  "add_one.sh adds 2 instead of 1" \
  "CONTRIBUTING.md has the typo" \
  "README.md links to a nonexistent CONTRIBUTE.md"; do
  assert_contains "-> issue already exists: $t"
done
assert_not_contains "[dry-run] gh"
echo "PASS: fully-seeded repo dry-run is a no-op (idempotent, no write calls)"

# ---------------------------------------------------------------------------
# T6 -- the 404-body guard specifically: a file that does NOT exist gets a
# fake 404 whose stdout body is real gh's actual (buggy) shape -- a JSON
# error blob -- and the script must still treat it as "missing", not
# "present with sha=<json blob>".
# ---------------------------------------------------------------------------
FAKE_REPO_VIEW_RC=0
FAKE_EXISTING_FILES="greet.sh"
FAKE_LABELS="demo-seed"
FAKE_EXISTING_TITLES=""
run 0 --repo "$TEST_REPO" --dry-run
assert_contains "-> greet.sh already present, leaving as-is"
assert_contains "-> creating add_one.sh"
assert_contains "-> creating CONTRIBUTING.md"
assert_contains "-> creating README.md"
echo "PASS: a missing file (404 JSON body on stdout) is correctly treated as absent"

# ---------------------------------------------------------------------------
# T7 -- --reset: closes every open demo-seed issue, resets every starter
# file to baseline (even ones that already exist), and recreates the full
# fixed issue set.
# ---------------------------------------------------------------------------
FAKE_REPO_VIEW_RC=0
FAKE_EXISTING_FILES="greet.sh add_one.sh CONTRIBUTING.md README.md"
FAKE_LABELS="demo-seed"
FAKE_OPEN_NUMBERS="10 11"
run 0 --repo "$TEST_REPO" --reset --dry-run
for f in greet.sh add_one.sh CONTRIBUTING.md README.md; do
  assert_contains "-> resetting $f to baseline"
done
assert_contains "closing stale demo-seed issues"
assert_contains "-> closing #10"
assert_contains "-> closing #11"
assert_contains "recreating the fixed issue set"
for t in \
  "greet.sh misspells its own greeting" \
  "add_one.sh adds 2 instead of 1" \
  "CONTRIBUTING.md has the typo" \
  "README.md links to a nonexistent CONTRIBUTE.md"; do
  assert_contains "-> creating issue: $t"
done
echo "PASS: --reset closes stale issues, resets files, recreates the fixed set"

# ---------------------------------------------------------------------------
# T8 -- --reset with nothing open: "none open", still recreates.
# ---------------------------------------------------------------------------
FAKE_OPEN_NUMBERS=""
run 0 --repo "$TEST_REPO" --reset --dry-run
assert_contains "-> none open"
echo "PASS: --reset with no open issues reports none-open and still recreates"

echo "ALL PASS: test_seed_demo_repo.sh"
