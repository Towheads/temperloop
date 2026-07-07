#!/usr/bin/env bash
#
# Tests for check-pr-leak-guard.sh (temperloop #74): the diff-scoped
# public-repo leak guard. A synthetic git fixture repo proves:
#   1. GREEN — clean added lines pass.
#   2. RED  — a seeded personal path + email in ADDED lines fails, and the
#             failure output names the offending file + token.
#   3. added-ONLY scope — a token that appears only on REMOVED lines (a file
#             deletion) is NOT flagged (the whole point of diff-scoping).
#   4. the inline `denylist:allow` marker suppresses an added-line match.
#   5. the file-level exempt list suppresses a whole added file.
#   6. secrets-half wiring — a gitleaks that reports a finding fails the guard;
#             LEAK_GUARD_SKIP_SECRETS=1 and a clean gitleaks both pass.
#   7. no-base — an unresolvable base with no origin/main|main skips the live
#             scan and exits 0 (keeps a clean tree green in every run context).
#
# The seeded leak literals are constructed at RUNTIME via string splitting
# (e.g. "/Users/tra""vis") so this test's own SOURCE carries no contiguous
# scannable token — the guard scanning its OWN PR diff, and the whole-tree
# denylist/gitleaks checks scanning this file, all stay green without an
# exempt-list entry. Mirrors test_check_personal_token_denylist.sh's plain
# mktemp-fixture style: no framework, just fail() + sequential asserts.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$(cd "$HERE/.." && pwd)"
GUARD="$KERNEL_DIR/check-pr-leak-guard.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/leak-guard-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- runtime-built seeded leak literals (split so the SOURCE has no match) ---
LEAK_PATH="/Users/tra""vis/app/config.txt"      # matches /Users/travis\b
LEAK_EMAIL="trav""new@yahoo.com"                 # matches travnew@yahoo\.com
LEAK_ORG="Tow""heads"                            # matches Towheads

# --- empty exempt file (default; overridden per-case) -----------------------
EMPTY_EXEMPT="$WORK/empty-exempt.txt"
: > "$EMPTY_EXEMPT"

# --- fake gitleaks stubs ----------------------------------------------------
GL_FOUND="$WORK/gitleaks_found.sh"
cat > "$GL_FOUND" <<'EOF'
#!/usr/bin/env bash
echo "fake-gitleaks: pretending to find a secret"
exit 1
EOF
GL_CLEAN="$WORK/gitleaks_clean.sh"
cat > "$GL_CLEAN" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$GL_FOUND" "$GL_CLEAN"

# --- build a fixture git repo with a clean base commit ----------------------
REPO="$WORK/repo"
mkdir -p "$REPO/src"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
echo "clean baseline content" > "$REPO/src/base.txt"
git -C "$REPO" -c core.hooksPath=/dev/null add -A
git -C "$REPO" -c core.hooksPath=/dev/null commit -q -m base
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

# run_guard : invoke the guard against the fixture repo, base=BASE_SHA, with the
# empty exempt list and secrets skipped. Cases needing other env call the guard
# via an explicit `env ...` instead.
run_guard() {
  env KERNEL_MANIFEST_ROOT="$REPO" \
      KERNEL_DENYLIST_EXEMPT_FILE="$EMPTY_EXEMPT" \
      LEAK_GUARD_BASE="$BASE_SHA" \
      LEAK_GUARD_SKIP_SECRETS=1 \
      bash "$GUARD"
}

commit() { git -C "$REPO" -c core.hooksPath=/dev/null add -A && git -C "$REPO" -c core.hooksPath=/dev/null commit -q -m "$1"; }

# --- 1: GREEN — clean added lines pass --------------------------------------
echo "a perfectly ordinary added line" >> "$REPO/src/base.txt"
echo "another clean line" > "$REPO/src/new_clean.sh"
commit "clean additions"
if ! run_guard >/dev/null 2>&1; then
  fail "1: clean added lines should pass"
fi
echo "PASS: 1 clean added lines pass"

# --- 2: RED — seeded personal path + email + org ref in added lines fails ----
{
  echo "home = $LEAK_PATH"
  echo "contact: $LEAK_EMAIL"
  echo "org: $LEAK_ORG"
} > "$REPO/src/leak.env"
commit "seed a leak"
if run_guard >/dev/null 2>&1; then
  fail "2: an added personal path + email should FAIL the guard, but it passed"
fi
out="$(run_guard 2>&1 || true)"
case "$out" in
  *"src/leak.env"*) ;;
  *) fail "2: failure output should name the offending file; got: $out" ;;
esac
case "$out" in
  *"/Users/travis"*) ;;
  *) fail "2: failure output should surface the offending path token; got: $out" ;;
esac
# org-private reference is detected too
case "$out" in
  *"Towheads"*) ;;
  *) fail "2: failure output should surface the org-private token; got: $out" ;;
esac
echo "PASS: 2 seeded personal path + email + org ref is caught"

# reset to clean base for subsequent cases
git -C "$REPO" -c core.hooksPath=/dev/null reset -q --hard "$BASE_SHA"

# --- 3: added-ONLY scope — a token only on REMOVED lines is not flagged -----
# Put the token in the BASE, then delete it in HEAD -> it appears on '-' lines.
git -C "$REPO" -c core.hooksPath=/dev/null checkout -q -b scope-base "$BASE_SHA"
echo "legacy = $LEAK_PATH" > "$REPO/src/legacy.env"
commit "base carries a token (pre-existing)"
SCOPE_BASE="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" -c core.hooksPath=/dev/null rm -q "$REPO/src/legacy.env"
commit "remove the pre-existing token"
if ! env KERNEL_MANIFEST_ROOT="$REPO" KERNEL_DENYLIST_EXEMPT_FILE="$EMPTY_EXEMPT" \
        LEAK_GUARD_BASE="$SCOPE_BASE" LEAK_GUARD_SKIP_SECRETS=1 \
        bash "$GUARD" >/dev/null 2>&1; then
  fail "3: a token present only on REMOVED lines must NOT fail the guard (added-only scope)"
fi
echo "PASS: 3 removed-line token is not flagged (added-only scope)"
git -C "$REPO" -c core.hooksPath=/dev/null checkout -q -
git -C "$REPO" -c core.hooksPath=/dev/null reset -q --hard "$BASE_SHA"

# --- 4: inline denylist:allow marker suppresses an added-line match ---------
echo "home = $LEAK_PATH  # denylist:allow — fixture, intentional" > "$REPO/src/marked.env"
commit "add an allow-marked line"
if ! run_guard >/dev/null 2>&1; then
  fail "4: an added line carrying the denylist:allow marker should be suppressed"
fi
echo "PASS: 4 denylist:allow marker suppresses an added-line match"
git -C "$REPO" -c core.hooksPath=/dev/null reset -q --hard "$BASE_SHA"

# --- 5: file-level exempt list suppresses a whole added file ----------------
echo "home = $LEAK_PATH" > "$REPO/src/exempt_me.env"
commit "add an unmarked leak in a to-be-exempted file"
if run_guard >/dev/null 2>&1; then
  fail "5 setup: unmarked leak should fail before the file is exempted"
fi
POP_EXEMPT="$WORK/populated-exempt.txt"
echo "src/exempt_me.env" > "$POP_EXEMPT"
if ! env KERNEL_MANIFEST_ROOT="$REPO" KERNEL_DENYLIST_EXEMPT_FILE="$POP_EXEMPT" \
        LEAK_GUARD_BASE="$BASE_SHA" LEAK_GUARD_SKIP_SECRETS=1 \
        bash "$GUARD" >/dev/null 2>&1; then
  fail "5: a file in the exempt list should be suppressed wholesale"
fi
echo "PASS: 5 file-level exempt list suppresses a whole added file"
git -C "$REPO" -c core.hooksPath=/dev/null reset -q --hard "$BASE_SHA"

# --- 6: secrets-half wiring -------------------------------------------------
echo "just some new code, no personal token" > "$REPO/src/secretish.sh"
commit "add a plain file for the secrets scan"
# 6a: a gitleaks that reports a finding fails the guard.
if env KERNEL_MANIFEST_ROOT="$REPO" KERNEL_DENYLIST_EXEMPT_FILE="$EMPTY_EXEMPT" \
       LEAK_GUARD_BASE="$BASE_SHA" GITLEAKS_BIN="$GL_FOUND" \
       bash "$GUARD" >/dev/null 2>&1; then
  fail "6a: a gitleaks finding in added lines should FAIL the guard"
fi
# 6b: LEAK_GUARD_SKIP_SECRETS=1 bypasses the secrets half (personal-clean -> pass).
if ! env KERNEL_MANIFEST_ROOT="$REPO" KERNEL_DENYLIST_EXEMPT_FILE="$EMPTY_EXEMPT" \
        LEAK_GUARD_BASE="$BASE_SHA" LEAK_GUARD_SKIP_SECRETS=1 GITLEAKS_BIN="$GL_FOUND" \
        bash "$GUARD" >/dev/null 2>&1; then
  fail "6b: LEAK_GUARD_SKIP_SECRETS=1 should bypass the secrets half"
fi
# 6c: a clean gitleaks passes.
if ! env KERNEL_MANIFEST_ROOT="$REPO" KERNEL_DENYLIST_EXEMPT_FILE="$EMPTY_EXEMPT" \
        LEAK_GUARD_BASE="$BASE_SHA" GITLEAKS_BIN="$GL_CLEAN" \
        bash "$GUARD" >/dev/null 2>&1; then
  fail "6c: a clean gitleaks should pass"
fi
echo "PASS: 6 secrets-half wiring (found fails, skip bypasses, clean passes)"
git -C "$REPO" -c core.hooksPath=/dev/null reset -q --hard "$BASE_SHA"

# --- 7: no-base — unresolvable base, no origin/main|main -> skip, exit 0 -----
NOBASE="$WORK/nobase"
mkdir -p "$NOBASE"
git -C "$NOBASE" init -q
git -C "$NOBASE" config user.email test@example.com
git -C "$NOBASE" config user.name test
echo "hi" > "$NOBASE/f.txt"
git -C "$NOBASE" -c core.hooksPath=/dev/null add -A
git -C "$NOBASE" -c core.hooksPath=/dev/null commit -q -m init
# rename away from any main/master default so no base ref resolves
git -C "$NOBASE" branch -m no-default-branch-xyz
if ! env KERNEL_MANIFEST_ROOT="$NOBASE" KERNEL_DENYLIST_EXEMPT_FILE="$EMPTY_EXEMPT" \
        LEAK_GUARD_BASE="" LEAK_GUARD_SKIP_SECRETS=1 \
        bash "$GUARD" >/dev/null 2>&1; then
  fail "7: an unresolvable base should skip the live scan and exit 0"
fi
echo "PASS: 7 no-base run skips the live scan and exits 0"

echo "PASS: all check-pr-leak-guard.sh fixture tests"
