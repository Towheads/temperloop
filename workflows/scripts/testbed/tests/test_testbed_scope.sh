#!/usr/bin/env bash
#
# Tests for workflows/scripts/testbed/scope.sh — the delete_repo OAuth-scope
# check `temperloop testbed --teardown` gates on (temperloop#1117, item
# testbed-teardown / #1231).
#
# Covers:
#   1. testbed_teardown_has_delete_repo_scope returns SUCCESS when the
#      active gh account's `gh auth status --json hosts` scopes string
#      carries delete_repo (JSON path — the primary one)
#   2. returns FAILURE when it does not
#   3. an EXACT-scope match: `delete_repository_hook`-shaped noise near the
#      word must never partial-match `delete_repo`
#   4. the plain-text `gh auth status` fallback (JSON path yields nothing)
#      is used, and reads the "Token scopes: '...'" line correctly
#   5. `gh` missing on PATH -> failure, not a crash
#   6. bin/subcommands/testbed.sh's --teardown mode is the documented
#      caller: it actually calls this function (not a parallel copy)
#
# No network — a fake `gh` on PATH answers every call from an env var.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
SCOPE_SH="${REPO_ROOT}/workflows/scripts/testbed/scope.sh"
TESTBED_SH="${REPO_ROOT}/bin/subcommands/testbed.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-testbed-scope-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
mkdir -p "$BIN"

# --- fake gh: --json path answers from FAKE_SCOPES_JSON; plain-text path
# (no --json) answers from FAKE_SCOPES_TEXT. Absent/empty means "print
# nothing", so a test can exercise the JSON-yields-nothing fallback. -------
cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
case "${1:-}" in
  auth)
    case "${2:-}" in
      status)
        if printf '%s\n' "$*" | grep -- '--json' >/dev/null; then
          [ -n "${FAKE_SCOPES_JSON:-}" ] && printf '%s\n' "$FAKE_SCOPES_JSON"
          exit 0
        fi
        [ -n "${FAKE_SCOPES_TEXT:-}" ] && printf '%s\n' "$FAKE_SCOPES_TEXT"
        exit "${FAKE_AUTH_RC:-0}"
        ;;
    esac
    ;;
esac
exit 1
FAKE_GH_EOF
chmod +x "$BIN/gh"

run_with_fake_gh() {
  ( export PATH="$BIN:$PATH"; source "$SCOPE_SH"; testbed_teardown_has_delete_repo_scope )
}

# ---------------------------------------------------------------------------
# 1: JSON path, scope present -> success
# ---------------------------------------------------------------------------
export FAKE_SCOPES_JSON='{"hosts":{"github.com":[{"active":true,"scopes":"gist, delete_repo, repo"}]}}'
unset FAKE_SCOPES_TEXT
run_with_fake_gh && pass "1: JSON path — delete_repo present -> success" \
  || fail "1: expected success when the JSON scopes string carries delete_repo"

# ---------------------------------------------------------------------------
# 2: JSON path, scope absent -> failure
# ---------------------------------------------------------------------------
export FAKE_SCOPES_JSON='{"hosts":{"github.com":[{"active":true,"scopes":"gist, repo, workflow"}]}}'
if run_with_fake_gh; then
  fail "2: expected failure when the JSON scopes string has no delete_repo"
fi
pass "2: JSON path — delete_repo absent -> failure"

# ---------------------------------------------------------------------------
# 3: exact match only — a scope that merely CONTAINS "delete_repo" as a
# substring must never count.
# ---------------------------------------------------------------------------
export FAKE_SCOPES_JSON='{"hosts":{"github.com":[{"active":true,"scopes":"gist, delete_repository_hook, repo"}]}}'
if run_with_fake_gh; then
  fail "3: 'delete_repository_hook' must not partial-match 'delete_repo'"
fi
pass "3: exact per-scope match — no partial-match false positive"

# ---------------------------------------------------------------------------
# 4: JSON path yields nothing -> plain-text `gh auth status` fallback
# ---------------------------------------------------------------------------
unset FAKE_SCOPES_JSON
export FAKE_SCOPES_TEXT="  - Token scopes: 'gist', 'delete_repo', 'repo'"
run_with_fake_gh && pass "4: plain-text fallback — 'Token scopes' line with delete_repo -> success" \
  || fail "4: expected success via the plain-text fallback"

export FAKE_SCOPES_TEXT="  - Token scopes: 'gist', 'repo'"
if run_with_fake_gh; then
  fail "4b: plain-text fallback without delete_repo must fail"
fi
pass "4b: plain-text fallback — no delete_repo -> failure"
unset FAKE_SCOPES_TEXT

# ---------------------------------------------------------------------------
# 5: gh missing on PATH -> failure, not a crash
# ---------------------------------------------------------------------------
EMPTYBIN="$TMP/emptybin"
mkdir -p "$EMPTYBIN"
if ( export PATH="$EMPTYBIN"; source "$SCOPE_SH"; testbed_teardown_has_delete_repo_scope ); then
  fail "5: expected failure when gh is not on PATH"
fi
pass "5: gh missing on PATH -> failure, not a crash"

# ---------------------------------------------------------------------------
# 6: testbed.sh's --teardown mode calls this function — not a reimplemented
# parallel copy of the scope check.
# ---------------------------------------------------------------------------
grep -q "testbed_teardown_has_delete_repo_scope" "$TESTBED_SH" \
  || fail "6: bin/subcommands/testbed.sh must call testbed_teardown_has_delete_repo_scope, not reimplement it"
pass "6: bin/subcommands/testbed.sh's --teardown mode consumes the shared helper"

echo "OK: test_testbed_scope.sh"
