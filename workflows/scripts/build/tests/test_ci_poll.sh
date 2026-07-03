#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/ci-poll.sh — the build 3g CI watch
# (epic #253, spike #245). Board-toolkit fixture style: zero network, a
# PATH-shim `gh` stub that replays canned JSON fixtures THROUGH the caller's
# real --jq program (so the script's jq filters are exercised, not bypassed),
# structured-output assertions via jq.
#
# Covers:
#   - all-green check-runs (success/neutral/skipped mix) → CI_GREEN, exit 0
#   - a failed run → CI_FAILED + failed_run_ids resolved (failure only), exit 0
#   - pending-then-complete across two polls (tiny --interval) → CI_GREEN
#   - zero check-runs → TIMEOUT outcome + non-zero exit (never spins forever)
#   - --sha pins the head: the pulls endpoint is never queried
#   - head SHA is resolved exactly ONCE; only REST endpoints are ever called
#     (no `gh pr checks` — the GH #53 GraphQL-budget rule, enforced by stub)
#   - bad args (owner/repo, pr, interval) → structured ERROR + non-zero exit
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ci-poll.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- PATH-shim gh stub --------------------------------------------------------
# Dispatches on the invocation shape, logs every call to $GH_STUB_STATE/calls.log,
# and pipes the matching fixture through the caller's --jq program with real jq.
# check-runs responses are sequenced: checkruns.<n>.json for poll n if present,
# else checkruns.json (steady state). Anything unexpected fails loudly.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
STATE="${GH_STUB_STATE:?gh stub needs GH_STUB_STATE}"
echo "$*" >> "$STATE/calls.log"

jq_expr=""
rest=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jq_expr="$2"; shift ;;
    *) rest+=("$1") ;;
  esac
  shift
done

emit() { # $1 = fixture file — `gh --jq` emits strings RAW (jq -r semantics)
  if [ -n "$jq_expr" ]; then jq -r "$jq_expr" < "$1"; else cat "$1"; fi
}

case "${rest[0]}" in
  api)
    path="${rest[1]}"
    case "$path" in
      repos/*/pulls/*)
        emit "$STATE/pull.json"
        ;;
      repos/*/commits/*/check-runs)
        n=0
        [ -f "$STATE/checkruns.count" ] && n="$(cat "$STATE/checkruns.count")"
        n=$((n + 1)); echo "$n" > "$STATE/checkruns.count"
        f="$STATE/checkruns.$n.json"
        [ -f "$f" ] || f="$STATE/checkruns.json"
        emit "$f"
        ;;
      *) echo "gh-stub: unexpected api path: $path" >&2; exit 64 ;;
    esac
    ;;
  run)
    [ "${rest[1]}" = "list" ] || { echo "gh-stub: unexpected run subcommand" >&2; exit 64; }
    emit "$STATE/runs.json"
    ;;
  *) echo "gh-stub: unexpected command: ${rest[*]}" >&2; exit 64 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# Fresh stub state per case.
reset_state() {
  rm -rf "$TMP/state"; mkdir -p "$TMP/state"
  export GH_STUB_STATE="$TMP/state"
  printf '{"head":{"sha":"%s"}}\n' "$HEAD_SHA" > "$TMP/state/pull.json"
}
HEAD_SHA="abc1234def5678abc1234def5678abc1234def56"

# --- all-green check-runs → CI_GREEN ------------------------------------------
reset_state
cat > "$TMP/state/checkruns.json" <<'EOF'
{"check_runs":[
  {"status":"completed","conclusion":"success"},
  {"status":"completed","conclusion":"neutral"},
  {"status":"completed","conclusion":"skipped"}
]}
EOF
out="$(bash "$SCRIPT" Towheads/foundation 42)"
[ "$(jq -r .outcome <<<"$out")" = "CI_GREEN" ] || fail "green outcome (got: $out)"
[ "$(jq -r .sha <<<"$out")" = "$HEAD_SHA" ] || fail "green sha (got: $out)"
[ "$(jq -r .pr <<<"$out")" = "42" ] || fail "green pr (got: $out)"
[ "$(grep -c 'api repos/Towheads/foundation/pulls/42' "$TMP/state/calls.log")" -eq 1 ] \
  || fail "head SHA not resolved exactly once"
grep -vE '^(api repos/|run list )' "$TMP/state/calls.log" \
  && fail "non-REST gh call issued (GH #53): $(cat "$TMP/state/calls.log")"
echo "PASS: all-green check-runs (success/neutral/skipped) → CI_GREEN, REST-only, SHA resolved once"

# --- a failed run → CI_FAILED + failed_run_ids --------------------------------
reset_state
cat > "$TMP/state/checkruns.json" <<'EOF'
{"check_runs":[
  {"status":"completed","conclusion":"success"},
  {"status":"completed","conclusion":"failure"}
]}
EOF
cat > "$TMP/state/runs.json" <<'EOF'
[{"databaseId":111,"conclusion":"failure"},{"databaseId":222,"conclusion":"success"}]
EOF
rc=0; out="$(bash "$SCRIPT" Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 0 ] || fail "CI_FAILED is a successful poll — must exit 0 (got rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "CI_FAILED" ] || fail "failed outcome (got: $out)"
[ "$(jq -c .failed_run_ids <<<"$out")" = "[111]" ] \
  || fail "failed_run_ids must list failure conclusions only (got: $out)"
echo "PASS: failed run → CI_FAILED with failed_run_ids=[111] (success run excluded), exit 0"

# --- pending-then-complete across two polls -----------------------------------
reset_state
cat > "$TMP/state/checkruns.1.json" <<'EOF'
{"check_runs":[
  {"status":"in_progress","conclusion":null},
  {"status":"completed","conclusion":"success"}
]}
EOF
cat > "$TMP/state/checkruns.json" <<'EOF'
{"check_runs":[
  {"status":"completed","conclusion":"success"},
  {"status":"completed","conclusion":"success"}
]}
EOF
out="$(bash "$SCRIPT" Towheads/foundation 42 --interval 0.1)"
[ "$(jq -r .outcome <<<"$out")" = "CI_GREEN" ] || fail "pending-then-green outcome (got: $out)"
[ "$(cat "$TMP/state/checkruns.count")" -eq 2 ] \
  || fail "expected exactly 2 check-runs polls (got: $(cat "$TMP/state/checkruns.count"))"
echo "PASS: pending run keeps polling; completes green on poll 2 (--interval honored)"

# --- zero check-runs → TIMEOUT + non-zero exit --------------------------------
reset_state
echo '{"check_runs":[]}' > "$TMP/state/checkruns.json"
rc=0; out="$(bash "$SCRIPT" Towheads/foundation 42 --timeout 0)" || rc=$?
[ "$rc" -ne 0 ] || fail "zero check-runs did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "TIMEOUT" ] || fail "zero check-runs not TIMEOUT (got: $out)"
[ "$(jq -r .sha <<<"$out")" = "$HEAD_SHA" ] || fail "timeout sha (got: $out)"
echo "PASS: zero check-runs (unpushed/no-CI SHA) → TIMEOUT + non-zero exit, no infinite spin"

# --- --sha pins the head: pulls endpoint never queried -------------------------
reset_state
cat > "$TMP/state/checkruns.json" <<'EOF'
{"check_runs":[{"status":"completed","conclusion":"success"}]}
EOF
pinned="feedface0000000000000000000000000000beef"
out="$(bash "$SCRIPT" Towheads/foundation 42 --sha "$pinned")"
[ "$(jq -r .outcome <<<"$out")" = "CI_GREEN" ] || fail "--sha outcome (got: $out)"
[ "$(jq -r .sha <<<"$out")" = "$pinned" ] || fail "--sha not honored (got: $out)"
grep -q 'pulls/42' "$TMP/state/calls.log" && fail "--sha given but pulls endpoint still queried"
echo "PASS: --sha pins the head SHA; the PR resolve is skipped entirely"

# --- bad args → structured ERROR + non-zero exit -------------------------------
reset_state
for args in "not-a-repo 42" "Towheads/foundation abc" "Towheads/foundation 42 --interval x" \
            "Towheads/foundation 42 --sha zzz" "Towheads/foundation"; do
  rc=0
  # shellcheck disable=SC2086  # word-splitting the case args is the point
  out="$(bash "$SCRIPT" $args 2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ] || fail "bad args '$args' did not exit non-zero"
  [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] || fail "bad args '$args' not ERROR (got: $out)"
done
echo "PASS: invalid owner/repo, pr, interval, sha, or missing args → structured ERROR + non-zero exit"
