#!/usr/bin/env bash
#
# test-ci-poll-retry — regression tests for ci-poll.sh's gh_retry() transient-
# API-hiccup absorption (temperloop#386). Sibling of test_ci_poll.sh (which
# covers the script's steady-state outcome contract); this file is scoped
# narrowly to the retry seam itself: a transient non-JSON `gh` response (an
# HTML/503 error page, e.g. `invalid character '<' looking for beginning of
# value`) must be retried, bounded, before the poll would otherwise die() —
# so a transient GitHub API blip stops false-escalating as an immediate
# ERROR (which the orchestrator treats the same as a genuine CI failure).
#
# Same PATH-shim `gh` stub as test_ci_poll.sh: a real fake `gh` on PATH that
# dispatches on invocation shape, logs every call, and pipes the matching
# fixture through the CALLER's real --jq program (so gh_retry sees exactly
# the failure a real non-JSON body would produce: jq fails to parse it and
# the stub — running under `set -euo pipefail` — exits non-zero).
#
# Covers:
#   - transient garbage (2 bad check-runs polls) then valid JSON on the 3rd
#     (== CI_POLL_API_MAX_ATTEMPTS) attempt → retried internally, CI_GREEN,
#     exactly 3 check-runs calls made (bounded, not retried forever)
#   - persistent garbage on every check-runs poll → all CI_POLL_API_MAX_
#     ATTEMPTS attempts fail → legible ERROR with transient_retries_
#     exhausted:true, exactly CI_POLL_API_MAX_ATTEMPTS calls made (not an
#     infinite spin), exit 1
#   - persistent garbage on the head-SHA (pulls) resolve → same legible
#     ERROR/exhausted contract, and the check-runs endpoint is never reached
#   - CLASSIFY-BEFORE-RETRY (temperloop#976): a DETERMINISTIC gh failure (a
#     permanent HTTP 4xx / auth / argument error, which re-issuing cannot
#     change) is classified and NOT retried — exactly one attempt, an ERROR
#     carrying `deterministic_failure:true` and NOT the exhausted-transient
#     field, and no retry notices logged
#   - the classifier is a real seam: an EMPTY CI_POLL_API_DETERMINISTIC_PATTERN
#     restores the pre-#976 "retry everything" behavior on that same failure
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ci-poll.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Keep the test fast + deterministic: 3 total attempts, zero backoff sleep.
export CI_POLL_API_MAX_ATTEMPTS=3
export CI_POLL_API_RETRY_BACKOFF=0

# --- PATH-shim gh stub (mirrors test_ci_poll.sh) ------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
STATE="${GH_STUB_STATE:?gh stub needs GH_STUB_STATE}"
echo "$*" >> "$STATE/calls.log"

# Deterministic-failure mode (temperloop#976): emit a PERMANENT gh error
# (an HTTP 4xx / auth / argument failure) on stderr and exit non-zero, exactly
# as real `gh` does — bypassing the jq path entirely, because a deterministic
# error's TEXT is the whole point of the case (it is what gh_retry classifies
# on) and a jq parse error would replace it with jq's own message.
if [ -f "$STATE/deterministic" ]; then
  cat "$STATE/deterministic" >&2
  exit 1
fi

jq_expr=""
rest=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jq_expr="$2"; shift ;;
    *) rest+=("$1") ;;
  esac
  shift
done

emit() { # $1 = fixture file — `gh --jq` emits strings RAW (jq -r semantics);
         # an INVALID-JSON fixture makes this `jq -r` fail, so the stub exits
         # non-zero — exactly what a real HTML/503 body does through `gh`.
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

reset_state() {
  rm -rf "$TMP/state"; mkdir -p "$TMP/state"
  export GH_STUB_STATE="$TMP/state"
  printf '{"head":{"sha":"%s"}}\n' "$HEAD_SHA" > "$TMP/state/pull.json"
}
HEAD_SHA="abc1234def5678abc1234def5678abc1234def56"

# --- transient garbage (2 bad polls) then valid JSON on the 3rd --------------
reset_state
echo '<html><body>503 Service Unavailable</body></html>' > "$TMP/state/checkruns.1.json"
echo '<html><body>503 Service Unavailable</body></html>' > "$TMP/state/checkruns.2.json"
cat > "$TMP/state/checkruns.json" <<'EOF'
{"check_runs":[{"status":"completed","conclusion":"success"}]}
EOF
out="$(bash "$SCRIPT" example-org/example-repo 42 2>"$TMP/stderr.1.log")"
[ "$(jq -r .outcome <<<"$out")" = "CI_GREEN" ] \
  || fail "transient-then-green must still resolve CI_GREEN (got: $out)"
[ "$(jq -r .sha <<<"$out")" = "$HEAD_SHA" ] || fail "transient-then-green sha (got: $out)"
[ "$(cat "$TMP/state/checkruns.count")" -eq 3 ] \
  || fail "expected exactly 3 check-runs attempts (2 transient + 1 green), got $(cat "$TMP/state/checkruns.count")"
[ "$(grep -c 'retrying (transient gh/API hiccup, temperloop#386)' "$TMP/stderr.1.log")" -eq 2 ] \
  || fail "expected exactly 2 logged retry notices on stderr"
echo "PASS: 2 transient non-JSON check-runs polls retried, 3rd (== CI_POLL_API_MAX_ATTEMPTS) resolves CI_GREEN"

# --- persistent garbage on check-runs → legible ERROR, bounded, exhausted ----
reset_state
echo '<html><body>503 Service Unavailable</body></html>' > "$TMP/state/checkruns.json"
rc=0; out="$(bash "$SCRIPT" example-org/example-repo 42 2>"$TMP/stderr.2.log")" || rc=$?
[ "$rc" -eq 1 ] || fail "persistent check-runs garbage must exit 1 like any other ERROR (got rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] || fail "persistent check-runs garbage not ERROR (got: $out)"
[ "$(jq -r .transient_retries_exhausted <<<"$out")" = "true" ] \
  || fail "expected transient_retries_exhausted:true (got: $out)"
case "$(jq -r .error <<<"$out")" in
  *"check-runs query"*) ;;
  *) fail "error message should name the check-runs query (got: $out)" ;;
esac
case "$(jq -r .error <<<"$out")" in
  *"3 attempts"*) ;;
  *) fail "error message should cite the attempt bound (got: $out)" ;;
esac
[ "$(cat "$TMP/state/checkruns.count")" -eq 3 ] \
  || fail "expected exactly 3 bounded attempts (not an infinite spin), got $(cat "$TMP/state/checkruns.count")"
echo "PASS: persistent non-JSON check-runs polls exhaust CI_POLL_API_MAX_ATTEMPTS(3), legible ERROR + transient_retries_exhausted:true, exit 1"

# --- persistent garbage on the head-SHA (pulls) resolve -----------------------
reset_state
echo '<html><body>503 Service Unavailable</body></html>' > "$TMP/state/pull.json"
rc=0; out="$(bash "$SCRIPT" example-org/example-repo 42 2>/dev/null)" || rc=$?
[ "$rc" -eq 1 ] || fail "persistent pulls-resolve garbage must exit 1 (got rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] || fail "persistent pulls garbage not ERROR (got: $out)"
[ "$(jq -r .transient_retries_exhausted <<<"$out")" = "true" ] \
  || fail "expected transient_retries_exhausted:true on pulls-resolve exhaustion (got: $out)"
case "$(jq -r .error <<<"$out")" in
  *"head SHA resolve"*) ;;
  *) fail "error message should name the head SHA resolve (got: $out)" ;;
esac
[ "$(grep -c 'api repos/example-org/example-repo/pulls/42' "$TMP/state/calls.log")" -eq 3 ] \
  || fail "expected exactly 3 bounded pulls-resolve attempts, got $(grep -c 'api repos/example-org/example-repo/pulls/42' "$TMP/state/calls.log")"
grep -q 'check-runs' "$TMP/state/calls.log" \
  && fail "check-runs endpoint should never be reached when head-SHA resolve is exhausted"
echo "PASS: persistent non-JSON head-SHA (pulls) resolve exhausts CI_POLL_API_MAX_ATTEMPTS(3), legible ERROR + transient_retries_exhausted:true, check-runs never reached"

# --- DETERMINISTIC failure → classified, NOT retried (temperloop#976) --------
# A permanent gh error (HTTP 404 / auth / bad argument) cannot change on a
# re-issue, so gh_retry must spend ZERO retries and ZERO backoff seconds on it,
# dying immediately with `deterministic_failure:true` — the opposite field from
# the exhausted-transient case above, so a caller can tell the two apart.
reset_state
printf 'gh: Not Found (HTTP 404)\n' > "$TMP/state/deterministic"
rc=0; out="$(bash "$SCRIPT" example-org/example-repo 42 2>"$TMP/stderr.4.log")" || rc=$?
[ "$rc" -eq 1 ] || fail "deterministic gh failure must exit 1 like any other ERROR (got rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] || fail "deterministic gh failure not ERROR (got: $out)"
[ "$(jq -r .deterministic_failure <<<"$out")" = "true" ] \
  || fail "expected deterministic_failure:true (got: $out)"
[ "$(jq -r '.transient_retries_exhausted // "absent"' <<<"$out")" = "absent" ] \
  || fail "a deterministic failure must NOT claim exhausted transient retries (got: $out)"
[ "$(grep -c 'api repos/example-org/example-repo/pulls/42' "$TMP/state/calls.log")" -eq 1 ] \
  || fail "expected EXACTLY 1 attempt on a deterministic failure (no retries), got $(grep -c 'api repos/example-org/example-repo/pulls/42' "$TMP/state/calls.log")"
[ "$(grep -c 'retrying (transient gh/API hiccup' "$TMP/stderr.4.log")" -eq 0 ] \
  || fail "a deterministic failure must log no retry notices"
echo "PASS: deterministic gh failure (HTTP 404) classified and NOT retried — 1 attempt, deterministic_failure:true, exit 1"

# --- an EMPTY pattern restores the pre-#976 retry-everything behavior ---------
# Proves the classifier is a real, disable-able seam rather than a hardcoded
# rule: with no pattern, the same permanent 404 falls through to the bounded
# transient retry and exhausts it.
reset_state
printf 'gh: Not Found (HTTP 404)\n' > "$TMP/state/deterministic"
rc=0
out="$(CI_POLL_API_DETERMINISTIC_PATTERN= bash "$SCRIPT" example-org/example-repo 42 2>/dev/null)" || rc=$?
[ "$rc" -eq 1 ] || fail "empty-pattern run must still exit 1 (got rc=$rc)"
[ "$(jq -r .transient_retries_exhausted <<<"$out")" = "true" ] \
  || fail "with the pattern empty the 404 should exhaust the transient retries (got: $out)"
[ "$(grep -c 'api repos/example-org/example-repo/pulls/42' "$TMP/state/calls.log")" -eq 3 ] \
  || fail "empty pattern should spend all CI_POLL_API_MAX_ATTEMPTS(3), got $(grep -c 'api repos/example-org/example-repo/pulls/42' "$TMP/state/calls.log")"
echo "PASS: empty CI_POLL_API_DETERMINISTIC_PATTERN restores the pre-#976 retry-everything behavior"
