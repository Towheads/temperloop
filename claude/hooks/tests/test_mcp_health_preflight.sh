#!/usr/bin/env bash
# Tests for mcp-health-preflight.sh's body-aware /search/smart probe
# (foundation#1224). The status-only probe treated any HTTP 200 as healthy, so a
# Smart-Connections embedding-layer failure (a binary-level EACCES that returns a
# passing status with a degraded body) slipped through and the fail-loud halt
# never fired. These cases drive the REAL hook end-to-end through a `curl`
# PATH-shim that returns a canned (status, body) for the two probes, and assert
# whether the DEGRADED banner is emitted.
#
# The shim distinguishes the two calls by URL: the REST probe hits `$BASE/`
# (returns MOCK_REST_CODE, default 200, healthy), the semantic probe hits
# `$BASE/search/smart` (returns MOCK_SMART_CODE + writes MOCK_SMART_BODY to the
# `-o` file the hook now captures).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$HERE/.." && pwd)/mcp-health-preflight.sh"
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-mcp-preflight-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- curl PATH-shim ----------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'SHIM'
#!/usr/bin/env bash
ofile=""; is_smart=0; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && ofile="$a"
  case "$a" in *"/search/smart"*) is_smart=1 ;; esac
  prev="$a"
done
if [ "$is_smart" = "1" ]; then
  # Simulate a curl transport failure (Obsidian hung/down) when asked.
  [ -n "${MOCK_SMART_CURL_FAIL:-}" ] && exit "$MOCK_SMART_CURL_FAIL"
  [ -n "$ofile" ] && printf '%s' "${MOCK_SMART_BODY-[]}" > "$ofile"
  printf '%s' "${MOCK_SMART_CODE:-200}"
else
  [ -n "$ofile" ] && [ "$ofile" != /dev/null ] && : > "$ofile"
  printf '%s' "${MOCK_REST_CODE:-200}"
fi
exit 0
SHIM
chmod +x "$TMP/bin/curl"

# --- fixture API key ---------------------------------------------------------
KEYFILE="$TMP/key.json"
printf '{"apiKey":"testkey"}' > "$KEYFILE"

pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "PASS: $1"; pass=$((pass + 1)); }

# run_hook — runs the real hook with the shim + canned mocks, echoes its stdout.
run_hook() {
  PATH="$TMP/bin:$PATH" \
  EVAL_RUN='' \
  KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE="$KEYFILE" \
  MCP_HEALTH_API_BASE="https://mock.invalid" \
  MOCK_REST_CODE="${MOCK_REST_CODE:-200}" \
  MOCK_SMART_CODE="${MOCK_SMART_CODE:-200}" \
  MOCK_SMART_BODY="${MOCK_SMART_BODY-[]}" \
  MOCK_SMART_CURL_FAIL="${MOCK_SMART_CURL_FAIL:-}" \
  TMPDIR="${HOOK_TMPDIR:-${TMPDIR:-/tmp}}" \
    bash "$HOOK" </dev/null 2>/dev/null
}

degraded() { case "$1" in *"OBSIDIAN MCP DEGRADED"*) return 0 ;; *) return 1 ;; esac; }

# --- 1: healthy — 200 + a results array → NO banner --------------------------
out="$(MOCK_SMART_CODE=200 MOCK_SMART_BODY='[{"path":"a.md","score":0.9}]' run_hook)"
degraded "$out" && fail "1: a healthy results array must NOT be flagged degraded"
ok "healthy 200 + results array → no halt banner"

# --- 2: healthy — 200 + EMPTY array (no-match query) → NO banner -------------
out="$(MOCK_SMART_CODE=200 MOCK_SMART_BODY='[]' run_hook)"
degraded "$out" && fail "2: an empty result set (valid JSON array) must stay healthy"
ok "healthy 200 + empty array → no halt banner (no-match query not a false positive)"

# --- 3: healthy — 200 + results-wrapping object → NO banner ------------------
out="$(MOCK_SMART_CODE=200 MOCK_SMART_BODY='{"results":[{"path":"a.md"}]}' run_hook)"
degraded "$out" && fail "3: a results-wrapping object must stay healthy"
ok "healthy 200 + {results:[...]} object → no halt banner"

# --- 4: THE #1224 BUG — 200 + error payload → banner ------------------------
out="$(MOCK_SMART_CODE=200 MOCK_SMART_BODY='{"errorCode":40149,"message":"EACCES: permission denied"}' run_hook)"
degraded "$out" || fail "4: a 200 with an error payload (the EACCES class) MUST fire the halt banner"
ok "200 + error payload (EACCES class) → halt banner (the #1224 regression)"

# --- 5: 200 + empty/non-JSON body → banner -----------------------------------
out="$(MOCK_SMART_CODE=200 MOCK_SMART_BODY='' run_hook)"
degraded "$out" || fail "5: a 200 with an empty/non-JSON body must fire the halt banner"
ok "200 + empty/non-JSON body → halt banner"

# --- 6: 503 → banner (existing status path, unchanged) -----------------------
out="$(MOCK_SMART_CODE=503 MOCK_SMART_BODY='' run_hook)"
degraded "$out" || fail "6: a 503 must still fire the halt banner"
ok "503 → halt banner (existing status path intact)"

# --- 7: REST server down (non-200) → banner (existing) -----------------------
out="$(MOCK_REST_CODE=500 MOCK_SMART_CODE=200 MOCK_SMART_BODY='[]' run_hook)"
degraded "$out" || fail "7: a non-200 REST status must still fire the halt banner"
ok "REST 500 → halt banner (existing status path intact)"

# --- 8: smart curl transport failure (Obsidian hung/down) → banner -----------
out="$(MOCK_SMART_CURL_FAIL=7 run_hook)"
degraded "$out" || fail "8: a curl transport failure on /search/smart must fire the halt banner"
ok "smart curl failure (Obsidian hung/down) → halt banner (unreachable path)"

# --- 8b: 200 + a bare-string (non-array/object) body → banner ----------------
# A valid-JSON but wrong-shape body (e.g. an error surfaced as a bare string)
# is not a results array/object, so the type-based check flags it rather than
# slipping it through as healthy.
out="$(MOCK_SMART_CODE=200 MOCK_SMART_BODY='"EACCES: permission denied"' run_hook)"
degraded "$out" || fail "8b: a bare-string 200 body must fire the halt banner (not a results shape)"
ok "200 + bare-string body → halt banner (wrong-shape, caught)"

# --- 9: mktemp failure → fall back to status-only (NO spurious halt) ---------
# With the body file unavailable (mktemp can't write TMPDIR), a healthy 200 must
# NOT be manufactured into a degraded verdict — even with an empty body that
# WOULD flag degraded if it were inspected. Guards the fail-open contract.
out="$(HOOK_TMPDIR=/nonexistent-dir-for-mktemp-fail MOCK_SMART_CODE=200 MOCK_SMART_BODY='' run_hook)"
degraded "$out" && fail "9: an mktemp failure must fall back to 200=healthy, not fabricate a halt"
ok "mktemp failure → status-only fallback, no spurious halt (fail-open intent)"

echo "ALL PASS: test_mcp_health_preflight.sh ($pass cases)"
