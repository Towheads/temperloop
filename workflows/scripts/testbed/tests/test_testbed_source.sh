#!/usr/bin/env bash
#
# Tests for workflows/scripts/testbed/source.sh — the testbed source-provider
# seam (temperloop#1228, epic #1117 Produces 2). Zero network throughout: git
# fixtures are real local repos (including a real bare repo as a produce_git
# destination — a genuine mirror-push proof with no network at all), and
# every `gh` touch point is either a would-explode trap (proving describe()
# never calls it) or a fake `gh` on PATH answering from fixture JSON.
#
# Part A drives the SEAM itself with a double (a fake provider), asserting
# the four-function contract independently of any real provider or command.
# Parts B-E drive mirror-from-repo directly: describe() (zero-network,
# base_name derivation + fallback), preflight_checks() (all-reads degrade
# paths), produce_git(dest) (real local mirror push), and produce_issues(dest)
# (fake gh — provenance-line stamping, and that it happens inside
# produce_issues itself, not shared code).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$HERE/.." && pwd)/source.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/testbed-source-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# <dir> [remote-url] -> a real one-commit git repo at <dir>, on branch
# "main", with `origin` set to remote-url when given.
make_source_repo() {
  local dir="$1" remote="${2:-}"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" checkout -q -b main
  echo hello > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" -c user.name=test -c user.email=test@example.com commit -q -m init >/dev/null
  if [ -n "$remote" ]; then
    git -C "$dir" remote add origin "$remote"
  fi
}

# =============================================================================
# Part A -- the generic seam, driven with a DOUBLE, independent of any real
# provider or command.
# =============================================================================
(
  # shellcheck source=/dev/null
  source "$LIB"

  # The double: a minimal provider named "fake-provider" (kebab-case, so the
  # '-' -> '_' function-name mapping is exercised the same as a real kind).
  _testbed_provider_fake_provider_describe() {
    jq -cn '{kind: "fake-provider", base_name: "widget", provenance_capable: false, promotable: false}'
  }
  _fake_check_always_ok() { return 0; }
  _testbed_provider_fake_provider_preflight_checks() {
    printf '%s\n' _fake_check_always_ok
  }
  _testbed_provider_fake_provider_produce_git() {
    echo "produce_git called with dest=$1" > "$1/git-marker"
  }
  _testbed_provider_fake_provider_produce_issues() {
    echo "produce_issues called with dest=$1" > "$1/issues-marker"
  }

  got="$(testbed_source_describe fake-provider)"
  [ "$(printf '%s' "$got" | jq -r .kind)" = "fake-provider" ] || fail "A1: describe dispatch did not reach the double (got: $got)"
  [ "$(printf '%s' "$got" | jq -r .base_name)" = "widget" ] || fail "A1: describe base_name mismatch"
  [ "$(printf '%s' "$got" | jq -r .provenance_capable)" = "false" ] || fail "A1: describe provenance_capable mismatch"
  [ "$(printf '%s' "$got" | jq -r .promotable)" = "false" ] || fail "A1: describe promotable mismatch"
  echo "PASS: A1 testbed_source_describe dispatches to the double's describe()"

  checks="$(testbed_source_preflight_checks fake-provider)"
  [ "$checks" = "_fake_check_always_ok" ] || fail "A2: preflight_checks dispatch mismatch (got: $checks)"
  "$checks" || fail "A2: the yielded check function should be directly callable and pass"
  echo "PASS: A2 testbed_source_preflight_checks yields callable check function names"

  destdir="$TMP/a-dest"
  mkdir -p "$destdir"
  testbed_source_produce_git fake-provider "$destdir"
  [ -f "$destdir/git-marker" ] || fail "A3: produce_git dispatch did not reach the double"
  echo "PASS: A3 testbed_source_produce_git dispatches to the double's produce_git(dest)"

  testbed_source_produce_issues fake-provider "$destdir"
  [ -f "$destdir/issues-marker" ] || fail "A4: produce_issues dispatch did not reach the double"
  echo "PASS: A4 testbed_source_produce_issues dispatches to the double's produce_issues(dest)"

  # Unknown provider kind -> exit 2, legible message naming it, no crash --
  # for all four seam members.
  for op_call in \
    "testbed_source_describe nonexistent-kind" \
    "testbed_source_preflight_checks nonexistent-kind" \
    "testbed_source_produce_git nonexistent-kind $destdir" \
    "testbed_source_produce_issues nonexistent-kind $destdir"; do
    rc=0
    out="$($op_call 2>&1)" || rc=$?
    [ "$rc" -eq 2 ] || fail "A5: [$op_call] expected exit 2 for an unknown provider kind, got $rc (out: $out)"
    case "$out" in
      *"nonexistent-kind"*) ;;
      *) fail "A5: [$op_call] error message should name the unknown kind (got: $out)" ;;
    esac
  done
  echo "PASS: A5 every seam member fails legibly (exit 2) on an unknown provider kind"

  [ "$(testbed_source__fn "mirror-from-repo" describe)" = "_testbed_provider_mirror_from_repo_describe" ] \
    || fail "A6: kind-to-function-name mapping is wrong for a multi-hyphen kind"
  echo "PASS: A6 multi-hyphen provider kind maps to the expected function name"
)

# =============================================================================
# Part B -- mirror-from-repo describe(): base_name derivation + fallback,
# ZERO network calls.
# =============================================================================
(
  # shellcheck source=/dev/null
  source "$LIB"

  SRC1="$TMP/src-ssh"
  make_source_repo "$SRC1" "git@github.com:acme/widgets.git"
  got="$(_testbed_provider_mirror_from_repo_describe "$SRC1")"
  [ "$(printf '%s' "$got" | jq -r .kind)" = "mirror-from-repo" ] || fail "B1: kind mismatch (got: $got)"
  [ "$(printf '%s' "$got" | jq -r .base_name)" = "widgets" ] || fail "B1: base_name should come from the ssh-form origin remote (got: $got)"
  [ "$(printf '%s' "$got" | jq -r .provenance_capable)" = "true" ] || fail "B1: provenance_capable must be true"
  [ "$(printf '%s' "$got" | jq -r .promotable)" = "true" ] || fail "B1: promotable must be true"
  echo "PASS: B1 describe() derives base_name from an ssh-form origin remote (mirror-from-repo is provenance-capable + promotable)"

  SRC2="$TMP/src-https"
  make_source_repo "$SRC2" "https://github.com/acme/gadgets.git"
  got="$(_testbed_provider_mirror_from_repo_describe "$SRC2")"
  [ "$(printf '%s' "$got" | jq -r .base_name)" = "gadgets" ] || fail "B2: base_name should come from the https-form origin remote (got: $got)"
  echo "PASS: B2 describe() derives base_name from an https-form origin remote"

  SRC3="$TMP/src-no-origin"
  make_source_repo "$SRC3"
  got="$(_testbed_provider_mirror_from_repo_describe "$SRC3")"
  [ "$(printf '%s' "$got" | jq -r .base_name)" = "src-no-origin" ] || fail "B3: base_name should fall back to the checkout dirname with no origin remote (got: $got)"
  echo "PASS: B3 describe() falls back to the checkout dirname when no origin remote is set"

  # ZERO network: a fake gh on PATH that fails loudly if invoked at all. If
  # describe() ever grows a gh call, this test catches it immediately.
  NOGHBIN="$TMP/no-gh-should-not-be-called"
  mkdir -p "$NOGHBIN"
  cat > "$NOGHBIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "UNEXPECTED gh CALL: $*" >&2
exit 99
EOF
  chmod +x "$NOGHBIN/gh"
  out="$(PATH="$NOGHBIN:$PATH" _testbed_provider_mirror_from_repo_describe "$SRC1" 2>&1)" \
    || fail "B4: describe() must not fail even with a would-explode gh on PATH (out: $out)"
  case "$out" in
    *"UNEXPECTED gh CALL"*) fail "B4: describe() must make ZERO gh/network calls (out: $out)" ;;
  esac
  echo "PASS: B4 describe() makes zero gh (network) calls"
)

# =============================================================================
# Part C -- mirror-from-repo preflight_checks(): all-reads, both checks pass
# on a healthy setup, and each degrades legibly (skipped —) on its own.
# =============================================================================
(
  # shellcheck source=/dev/null
  source "$LIB"

  SRC="$TMP/src-preflight"
  make_source_repo "$SRC" "git@github.com:acme/widgets.git"

  # C1: real git repo + authenticated gh -> every yielded check passes.
  FAKEBIN_OK="$TMP/fake-gh-ok"
  mkdir -p "$FAKEBIN_OK"
  cat > "$FAKEBIN_OK/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit "${FAKE_GH_AUTH_RC:-0}" ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN_OK/gh"
  checks="$(_testbed_provider_mirror_from_repo_preflight_checks "$SRC")"
  [ -n "$checks" ] || fail "C1: preflight_checks should yield at least one check function name"
  rc=0
  for c in $checks; do
    PATH="$FAKEBIN_OK:$PATH" "$c" || rc=1
  done
  [ "$rc" -eq 0 ] || fail "C1: every yielded check should pass for a real git repo + authenticated gh"
  echo "PASS: C1 preflight_checks yields checks that all pass for a real git repo + authenticated gh"

  # C2: not a git repo -> check_git_repo fails, legible "skipped —" message
  # naming the fix.
  NOTGIT="$TMP/not-a-repo"
  mkdir -p "$NOTGIT"
  _testbed_provider_mirror_from_repo_preflight_checks "$NOTGIT" >/dev/null
  rc=0
  out="$(_testbed_provider_mirror_from_repo_check_git_repo 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "C2: check_git_repo should fail on a non-git directory"
  case "$out" in
    "skipped — "*"not a git working tree"*) ;;
    *) fail "C2: expected a 'skipped — ... not a git working tree' message (got: $out)" ;;
  esac
  echo "PASS: C2 check_git_repo fails legibly (skipped —) on a non-git directory"

  # C3: gh absent from PATH entirely -> check_gh_auth fails legibly.
  NOGH="$TMP/no-gh-bin"
  mkdir -p "$NOGH"
  for tool in bash git jq sed grep sort mktemp cut printf cat dirname basename env; do
    b="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$b" ] && ln -sf "$b" "$NOGH/$tool"
  done
  _testbed_provider_mirror_from_repo_preflight_checks "$SRC" >/dev/null
  rc=0
  out="$(PATH="$NOGH" _testbed_provider_mirror_from_repo_check_gh_auth 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "C3: check_gh_auth should fail with gh absent from PATH"
  case "$out" in
    "skipped — gh CLI not found on PATH"*) ;;
    *) fail "C3: expected 'skipped — gh CLI not found on PATH' (got: $out)" ;;
  esac
  echo "PASS: C3 check_gh_auth fails legibly (skipped —) with gh absent from PATH"

  # C4: gh present but not authenticated -> check_gh_auth fails legibly.
  FAKEBIN_UNAUTH="$TMP/fake-gh-unauth"
  mkdir -p "$FAKEBIN_UNAUTH"
  cat > "$FAKEBIN_UNAUTH/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 1 ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN_UNAUTH/gh"
  rc=0
  out="$(PATH="$FAKEBIN_UNAUTH:$PATH" _testbed_provider_mirror_from_repo_check_gh_auth 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "C4: check_gh_auth should fail when gh is not authenticated"
  case "$out" in
    "skipped — gh is not authenticated"*) ;;
    *) fail "C4: expected 'skipped — gh is not authenticated' (got: $out)" ;;
  esac
  echo "PASS: C4 check_gh_auth fails legibly (skipped —) when gh is not authenticated"
)

# =============================================================================
# Part D -- mirror-from-repo produce_git(dest): a real mirror push between
# two real local git repos. Zero network.
# =============================================================================
(
  # shellcheck source=/dev/null
  source "$LIB"

  SRC="$TMP/src-git"
  make_source_repo "$SRC"
  sha="$(git -C "$SRC" rev-parse HEAD)"

  DEST="$TMP/dest.git"
  git init -q --bare "$DEST"

  _testbed_provider_mirror_from_repo_produce_git "$DEST" "$SRC"

  dest_sha="$(git -C "$DEST" rev-parse refs/heads/main 2>/dev/null)" \
    || fail "D1: dest bare repo should carry a refs/heads/main after produce_git"
  [ "$dest_sha" = "$sha" ] || fail "D1: dest's main should equal source's HEAD commit (want $sha got $dest_sha)"
  echo "PASS: D1 produce_git mirror-pushes the source's git history to dest (real local repos, zero network)"

  # D2: failure path -- an unreachable destination -> non-zero, legible message.
  rc=0
  out="$(_testbed_provider_mirror_from_repo_produce_git "$TMP/does-not-exist/dest.git" "$SRC" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "D2: produce_git should fail for an unreachable destination"
  case "$out" in
    *"git push --mirror"*) ;;
    *) fail "D2: expected a message naming the failed git push --mirror (got: $out)" ;;
  esac
  echo "PASS: D2 produce_git fails legibly when the destination is unreachable"
)

# =============================================================================
# Part E -- mirror-from-repo produce_issues(dest): the provenance stamp, and
# that it is stamped HERE (not shared downstream code). Fake gh, zero network.
# =============================================================================
(
  # shellcheck source=/dev/null
  source "$LIB"

  SRC="$TMP/src-issues"
  make_source_repo "$SRC" "git@github.com:acme/widgets.git"

  BIN="$TMP/fake-gh-issues"
  mkdir -p "$BIN"
  export CALL_LOG="$TMP/issues-call.log"
  : > "$CALL_LOG"
  cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    rc="${FAKE_ISSUE_LIST_RC:-0}"
    if [ "$rc" -ne 0 ]; then
      echo "${FAKE_ISSUE_LIST_ERR:-boom}" >&2
      exit "$rc"
    fi
    printf '%s' "$FAKE_ISSUE_LIST_JSON"
    exit 0
    ;;
  "issue create")
    {
      echo "--CALL--"
      printf '%s\n' "$@"
    } >> "$CALL_LOG"
    exit "${FAKE_ISSUE_CREATE_RC:-0}"
    ;;
esac
exit 0
FAKE_GH_EOF
  chmod +x "$BIN/gh"

  export FAKE_ISSUE_LIST_JSON='[{"number":101,"title":"Bug one","body":"desc one"},{"number":102,"title":"Bug two","body":"desc two"}]'

  # E1: happy path -- both source issues copied, each carrying the
  # provenance line, stamped by produce_issues itself.
  out="$(PATH="$BIN:$PATH" _testbed_provider_mirror_from_repo_produce_issues acme/widgets-testbed "$SRC" 2>&1)" \
    || fail "E1: produce_issues should succeed with a well-formed fake gh (out: $out)"
  case "$out" in
    *"copied 2 issue(s)"*) ;;
    *) fail "E1: expected a summary naming 2 copied issues (got: $out)" ;;
  esac
  grep -q "copied from acme/widgets#101" "$CALL_LOG" || fail "E1: issue #101's created body must carry the provenance line (log: $(cat "$CALL_LOG"))"
  grep -q "copied from acme/widgets#102" "$CALL_LOG" || fail "E1: issue #102's created body must carry the provenance line (log: $(cat "$CALL_LOG"))"
  grep -q "Bug one" "$CALL_LOG" || fail "E1: issue #101's title should be carried over"
  grep -q "acme/widgets-testbed" "$CALL_LOG" || fail "E1: gh issue create should target the destination repo"
  echo "PASS: E1 produce_issues copies each source issue to dest, stamping the provenance line inside its own call"

  # E2: no origin remote on source -> unresolvable, fails BEFORE ever calling
  # gh issue list/create.
  NOORIGIN="$TMP/src-no-origin-issues"
  make_source_repo "$NOORIGIN"
  : > "$CALL_LOG"
  rc=0
  out="$(PATH="$BIN:$PATH" _testbed_provider_mirror_from_repo_produce_issues acme/widgets-testbed "$NOORIGIN" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "E2: produce_issues should fail with no resolvable source owner/repo"
  [ ! -s "$CALL_LOG" ] || fail "E2: no gh issue create call should happen when the source can't be resolved (log: $(cat "$CALL_LOG"))"
  case "$out" in
    *"cannot resolve source owner/repo"*) ;;
    *) fail "E2: expected a message naming the unresolved source (got: $out)" ;;
  esac
  echo "PASS: E2 produce_issues fails legibly (and never calls gh) when the source owner/repo can't be resolved"

  # E3: gh issue create failure mid-loop -> non-zero, names the failing
  # source issue.
  : > "$CALL_LOG"
  export FAKE_ISSUE_CREATE_RC=1
  rc=0
  out="$(PATH="$BIN:$PATH" _testbed_provider_mirror_from_repo_produce_issues acme/widgets-testbed "$SRC" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "E3: produce_issues should fail when gh issue create fails"
  case "$out" in
    *"#101"*) ;;
    *) fail "E3: expected the failure message to name the source issue number (got: $out)" ;;
  esac
  echo "PASS: E3 produce_issues fails legibly and names the source issue when gh issue create fails"
)

echo "All testbed source-provider tests passed."
