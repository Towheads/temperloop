#!/usr/bin/env bash
#
# test_cache_command_wiring.sh — asserts the F#988 issue cache is reachable
# FROM THE COMMANDS, not merely from a test that sources cache.sh itself.
#
# WHY THIS EXISTS (temperloop#1118). test_cache_read_dispatch.sh proves the
# MECHANISM: with cache.sh sourced in its own process, board.sh's cached arms
# serve reads with zero gh calls. It sources cache.sh at its top (see its
# `source "$LIB_DIR/cache.sh"`), so it cannot observe whether any real command
# does. For ~4 weeks none did — the axis could be flipped on and every command
# still took the live arm, emitting one "cache.sh is not sourced" notice per
# read. The mechanism was green the whole time. That is the gap this file
# closes: it exercises the command's OWN sourcing prologue and never sources
# cache.sh itself.
#
# THE ASSERTION. A booby-trapped `gh` is placed first on PATH: any invocation
# logs its argv and exits non-zero. With `board.<N>.cache=on` and a warm store,
# a correctly-wired worklist.sh must complete WITHOUT calling it. So a single
# run proves both acceptance bullets at once — the wiring (no fallback notice)
# and the payoff (zero gh calls). If the source line is ever removed, the
# command falls to the live arm, hits the trap, and this test fails loudly.
#
# The negative control (a board with the axis absent) proves the trap actually
# fires — without it, a test that never reaches gh for an unrelated reason
# would pass vacuously.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_DIR="$(cd -P "$HERE/.." && pwd)"
# Deliberately NO LIB_DIR / no `source lib/cache.sh` here — see the note below.
REPO="test-owner/test-repo"
REPO_SLUG="test-owner-test-repo"

# NOTE: this file deliberately does NOT source lib/cache.sh. Sourcing it here
# would reintroduce exactly the blind spot described above.

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cache-cmd-wiring-XXXXXX")"
CACHE_STORE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cache-cmd-wiring-store-XXXXXX")"
GH_CALLS="$WORK/gh-calls.log"
export CACHE_STORE_ROOT
cleanup() { rm -rf "$WORK" "$CACHE_STORE_ROOT"; }
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- boards.conf: 42 = cache on, 43 = axis absent (the live-arm control) -----
cat > "$WORK/boards.conf" <<EOF
board.42.repo=$REPO
board.42.backend=issues
board.42.cache=on
board.43.repo=$REPO
board.43.backend=issues
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/boards.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf"

# --- warm store: snapshot + fresh meta --------------------------------------
STORE_DIR="$CACHE_STORE_ROOT/issues/$REPO_SLUG"
mkdir -p "$STORE_DIR"
# JSON *Lines* — one object per line. board.sh's cached arm slurps this with
# `jq -s`, so a single top-level array would slurp to [[...]] and fail
# "Cannot index array with string".
cat > "$STORE_DIR/snapshot.jsonl" <<'EOF'
{"number":301,"title":"Ready item","state":"open","updated_at":"2026-08-04T00:00:00Z","labels":[{"name":"fnd:status:ready"}]}
{"number":302,"title":"Closed item","state":"closed","updated_at":"2026-08-04T00:00:00Z","labels":[]}
EOF
printf '{"last_refresh":%s,"schema_version":1}\n' "$(date +%s)" > "$STORE_DIR/meta.json"

# --- booby-trapped gh: first on PATH, logs argv, always fails ---------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALLS"
echo "test: gh was invoked — the cached arm was NOT taken" >&2
exit 1
EOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
: > "$GH_CALLS"

gh_call_count() { grep -c . "$GH_CALLS" 2>/dev/null || true; }

# === 1. cache=on + warm store: zero gh calls, no fallback notice =============
: > "$GH_CALLS"
STDERR_LOG="$WORK/stderr-42.log"
set +e
"$BOARD_DIR/worklist.sh" --board 42 >"$WORK/stdout-42.log" 2>"$STDERR_LOG"
rc=$?
set -e

if grep -q "cache.sh is not sourced" "$STDERR_LOG"; then
  fail "worklist.sh emitted the 'cache.sh is not sourced' notice — the command does not source lib/cache.sh (this is temperloop#1118 regressing). stderr: $(cat "$STDERR_LOG")"
fi

if [ "$(gh_call_count)" != "0" ]; then
  fail "worklist.sh made $(gh_call_count) gh call(s) with the cache warm and board.42.cache=on — expected zero. Calls: $(cat "$GH_CALLS")"
fi

[ "$rc" -eq 0 ] || fail "worklist.sh exited $rc on the cached arm (stderr: $(cat "$STDERR_LOG"))"

echo "PASS: worklist.sh serves a warm cached read with ZERO gh calls and no fallback notice"

# === 2. negative control: axis absent ⇒ the live arm ⇒ the trap fires ========
# Proves the trap is real. Without this, test 1 could pass vacuously if
# worklist.sh returned early for some unrelated reason.
: > "$GH_CALLS"
set +e
"$BOARD_DIR/worklist.sh" --board 43 >/dev/null 2>"$WORK/stderr-43.log"
set -e

if [ "$(gh_call_count)" = "0" ]; then
  fail "control board 43 (cache axis absent) made zero gh calls — the booby-trapped gh never fired, so test 1's zero-call assertion proves nothing. Check the harness."
fi

echo "PASS: control (axis absent) takes the live arm and trips the gh trap — test 1's assertion is meaningful"

# === 3. reconcile.sh stays OFF the cached arm (#1024 acceptance) =============
# A drift detector fed cached data is self-defeating. Static assertion: the
# regression to catch is someone "helpfully" adding the source line here too.
#
# temperloop#1152: the match is anchored to a real sourcing line, not any
# occurrence of the path — a bare `grep -q "lib/cache\.sh"` also matched
# reconcile.sh's OWN governing comment (which names lib/cache.sh plainly to
# document this very contract), so merely documenting the contract tripped
# the gate that enforces it. The regex below requires a `source` or `.`
# keyword at the start of the (whitespace-trimmed) line, so a comment
# mentioning the path no longer counts.
CACHE_SOURCE_RE='^[[:space:]]*(source|\.)[[:space:]]+.*lib/cache\.sh'

if grep -Eq "$CACHE_SOURCE_RE" "$BOARD_DIR/reconcile.sh"; then
  fail "reconcile.sh sources lib/cache.sh — it MUST stay on the live arm (temperloop#1024: a drift detector must not read cached data)"
fi

echo "PASS: reconcile.sh does not source lib/cache.sh (stays on the live read arm)"

# --- 3a. anchoring cases (temperloop#1152) -----------------------------------
# Pin both directions of the anchored match with synthetic fixtures, so the
# loosened match cannot silently stop detecting the real thing:
#   - a COMMENT naming lib/cache.sh must PASS (no false positive)
#   - a genuine SOURCE of it must still FAIL, in all four forms it can take
FIXTURE="$WORK/reconcile-fixture.sh"

cat > "$FIXTURE" <<'EOF'
#!/usr/bin/env bash
# This script deliberately does not source lib/cache.sh — see the contract
# above naming lib/cache.sh plainly.
EOF
if grep -Eq "$CACHE_SOURCE_RE" "$FIXTURE"; then
  fail "the anchored check flagged a COMMENT naming lib/cache.sh as if it were a sourcing line — the match is not anchored to a real sourcing line"
fi
echo "PASS: a comment naming lib/cache.sh does not trip the anchored check"

# Single-quoted on purpose: DIR_FORM is literal fixture TEXT written to a
# file, not a shell expansion in this script.
# shellcheck disable=SC2016
DIR_FORM='source "$SCRIPT_DIR/lib/cache.sh"'   # $DIR-prefixed
declare -a SOURCING_FORMS=(
  'source lib/cache.sh'                        # bare: source X
  '. lib/cache.sh'                              # bare: . X
  'source "lib/cache.sh"'                       # quoted
  "$DIR_FORM"
)
for line in "${SOURCING_FORMS[@]}"; do
  printf '#!/usr/bin/env bash\n%s\n' "$line" > "$FIXTURE"
  if ! grep -Eq "$CACHE_SOURCE_RE" "$FIXTURE"; then
    fail "reconcile.sh sources lib/cache.sh — it MUST stay on the live arm (temperloop#1024: a drift detector must not read cached data) [form: $line]"
  fi
done
echo "PASS: the anchored check still catches a real sourcing line in all four forms (source X, . X, quoted, \$DIR-prefixed)"

echo "ALL PASS: test_cache_command_wiring.sh"
