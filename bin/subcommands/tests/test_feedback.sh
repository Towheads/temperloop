#!/usr/bin/env bash
#
# Tests for feedback.sh -- `temperloop feedback` (temperloop#428, consent-
# gated feedback submit mechanism). A stubbed `gh` on PATH that LOGS every
# call it sees (same write-intercepting-wrapper proof as test_init.sh /
# test_eject.sh: a non-transmitting run must leave ZERO gh calls in the
# log), zero network, deterministic.
#
# Covers:
#   1. leak-scan block: a message seeded with a real denylist pattern
#      (/Users/travis/...) is BLOCKED before any preview/consent/gh call --
#      exit 1, the matching pattern named, zero gh calls logged.
#   2. no-TTY refusal: a clean message with closed stdin (the default in
#      any non-interactive test harness) refuses to transmit -- exit 0, a
#      legible "no interactive operator" message, zero gh calls logged.
#   3. --dry-run: composes + leak-scans + previews, never prompts, exit 0,
#      zero gh calls logged, regardless of TTY/CI signals.
#   4. unattended-env signal: even with the TTY-assume test seam set,
#      CI=true / GITHUB_ACTIONS=true still refuses -- proves the signal
#      isn't just a TTY check.
#   5. full consented transmit (stubbed): TEMPERLOOP_FEEDBACK_ASSUME_TTY=1
#      with CI/GITHUB_ACTIONS unset, "y" piped on stdin -- gh label create
#      + gh issue create both fire with the expected args, the fake issue
#      URL is echoed, exit 0.
#   6. declined consent: same attended setup, "n" (or empty) on stdin --
#      zero gh calls, exit 0.
#   7. CLI hygiene: unknown arg -> exit 2; -h -> exit 0; invalid --type ->
#      exit 2; no message + non-interactive -> exit 2.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEEDBACK="$HERE/../feedback.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

WORK="$(mktemp -d "${TMPDIR:-/tmp}/feedback-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- fixture repo: a real git checkout with a non-denylisted origin, so the
# composed payload's "source repo" context line never itself trips the
# denylist (the target repo, Towheads/temperloop, legitimately would). -----
REPO="$WORK/repo"
mkdir -p "$REPO"
git init -q -b main "$REPO"
git -C "$REPO" remote add origin "https://github.com/example-org/example-repo.git"

# --- fake gh: logs every call --------------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
GH_LOG="$WORK/gh-calls.log"
cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1" in
  auth) exit "${FAKE_GH_AUTH_RC:-0}" ;;
  label) exit 0 ;;
  issue)
    echo "https://github.com/Towheads/temperloop/issues/9999"
    exit 0
    ;;
esac
exit 0
FAKE_GH_EOF
chmod +x "$BIN/gh"

# --- fixture denylist: self-contained, so the leak-scan-block test does not
# depend on the operator-personal rows that moved to the gitignored overlay
# (temperloop#438). Carries the one personal-path pattern this test exercises;
# feedback.sh reads it via TEMPERLOOP_FEEDBACK_DENYLIST_FILE. -----------------
FIXTURE_DENYLIST="$WORK/denylist.tsv"
printf '%s\t%s\n' '/Users/travis\b' 'personal absolute filesystem path' > "$FIXTURE_DENYLIST"

reset_log() { : > "$GH_LOG"; }
log_call_count() { grep -c . "$GH_LOG" 2>/dev/null || true; }

run_feedback() {
  # run_feedback WANT_RC [env assignments...] -- args...
  local want_rc="$1"; shift
  local rc=0
  ( cd "$REPO" && PATH="$BIN:$PATH" GH_LOG="$GH_LOG" "$@" ) > "$WORK/out.log" 2>&1 || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    fail "expected rc $want_rc, got $rc (args: $*)$(printf '\n--- output ---\n%s' "$(cat "$WORK/out.log")")"
  fi
}

# ===========================================================================
# 1. Leak-scan block
# ===========================================================================
reset_log
run_feedback 1 env TEMPERLOOP_FEEDBACK_DENYLIST_FILE="$FIXTURE_DENYLIST" bash "$FEEDBACK" --type bug \
  --message 'Repro: run it from /Users/travis/secret-notes and it fails.' \
  --dry-run < /dev/null
out="$(cat "$WORK/out.log")"
echo "$out" | grep -q "BLOCKED" || fail "leak-scan hit should say BLOCKED"
echo "$out" | grep -q '/Users/travis' || fail "leak-scan output should name the matching pattern"
echo "$out" | grep -q "personal absolute filesystem path" || fail "leak-scan output should show the pattern's description"
if echo "$out" | grep -q -- "-- Preview --"; then
  fail "a leak-scan block must never reach the preview step"
fi
[ "$(log_call_count)" = "0" ] || fail "leak-scan block must make ZERO gh calls (log: $(cat "$GH_LOG"))"
echo "PASS: leak-scan blocks a payload carrying a denylisted personal path, zero gh calls"

# ===========================================================================
# 2. No-TTY refusal (clean message, closed stdin, no --dry-run)
# ===========================================================================
reset_log
run_feedback 0 bash "$FEEDBACK" --type bug \
  --message "The report command crashes on an empty baseline file." \
  < /dev/null
out="$(cat "$WORK/out.log")"
echo "$out" | grep -q "leak-scan OK" || fail "clean message should pass the leak-scan"
echo "$out" | grep -q -- "-- Preview --" || fail "a non-blocked payload should still preview before refusing"
echo "$out" | grep -q "refusing to transmit" || fail "no-TTY run should refuse to transmit"
echo "$out" | grep -q "no interactive operator detected" || fail "refusal message should name the reason"
echo "$out" | grep -q "Nothing was sent" || fail "refusal message should confirm nothing was sent"
[ "$(log_call_count)" = "0" ] || fail "no-TTY refusal must make ZERO gh calls (log: $(cat "$GH_LOG"))"
echo "PASS: non-interactive run refuses to transmit, zero gh calls"

# ===========================================================================
# 3. --dry-run never prompts or transmits, even with TTY-assume set
# ===========================================================================
reset_log
run_feedback 0 env TEMPERLOOP_FEEDBACK_ASSUME_TTY=1 \
  bash "$FEEDBACK" --type idea --message "A dry-run idea." --dry-run \
  < /dev/null
out="$(cat "$WORK/out.log")"
echo "$out" | grep -q "dry run -- nothing transmitted" || fail "--dry-run should announce it sent nothing"
if echo "$out" | grep -q "Send this feedback to"; then
  fail "--dry-run must never reach the consent prompt"
fi
[ "$(log_call_count)" = "0" ] || fail "--dry-run must make ZERO gh calls (log: $(cat "$GH_LOG"))"
echo "PASS: --dry-run composes/scans/previews only, zero gh calls"

# ===========================================================================
# 4. Unattended-env signal overrides the TTY-assume test seam
# ===========================================================================
reset_log
run_feedback 0 env TEMPERLOOP_FEEDBACK_ASSUME_TTY=1 CI=true \
  bash "$FEEDBACK" --type bug --message "Clean message under CI=true." \
  < /dev/null
out="$(cat "$WORK/out.log")"
echo "$out" | grep -q "refusing to transmit" || fail "CI=true should refuse even with the TTY-assume seam set"
[ "$(log_call_count)" = "0" ] || fail "CI=true run must make ZERO gh calls (log: $(cat "$GH_LOG"))"
echo "PASS: CI=true refuses to transmit regardless of the TTY-assume test seam"

# ===========================================================================
# 5. Full consented transmit (stubbed gh) -- the attended + explicit-yes path
# ===========================================================================
reset_log
rc=0
( cd "$REPO" && env -u CI -u GITHUB_ACTIONS PATH="$BIN:$PATH" GH_LOG="$GH_LOG" \
    TEMPERLOOP_FEEDBACK_ASSUME_TTY=1 \
    bash "$FEEDBACK" --type bug --message "Stubbed transmit demo message." \
    <<<"y" ) > "$WORK/out.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "consented transmit should exit 0 (rc=$rc)$(printf '\n--- output ---\n%s' "$(cat "$WORK/out.log")")"
out="$(cat "$WORK/out.log")"
echo "$out" | grep -q "feedback.sh: sent -- https://github.com/Towheads/temperloop/issues/9999" \
  || fail "consented transmit should echo the fake issue URL"
grep -q "^auth status" "$GH_LOG" || fail "consented transmit should check gh auth status"
grep -q "^label create feedback -R Towheads/temperloop" "$GH_LOG" \
  || fail "consented transmit should ensure the feedback label (log: $(cat "$GH_LOG"))"
issue_line="$(grep "^issue create" "$GH_LOG" || true)"
[ -n "$issue_line" ] || fail "consented transmit should call gh issue create (log: $(cat "$GH_LOG"))"
echo "$issue_line" | grep -q -- "-R Towheads/temperloop" || fail "issue create should target Towheads/temperloop"
echo "$issue_line" | grep -q -- "--label feedback" || fail "issue create should carry the feedback label"
echo "$issue_line" | grep -q -- "--body-file" || fail "issue create should send the composed payload via --body-file"
echo "PASS: attended + explicit yes drives label-ensure + issue-create with the composed payload"

# ===========================================================================
# 6. Declined consent -- attended, but the operator types something other
#    than y/yes -- zero gh calls beyond the auth check.
# ===========================================================================
reset_log
rc=0
( cd "$REPO" && env -u CI -u GITHUB_ACTIONS PATH="$BIN:$PATH" GH_LOG="$GH_LOG" \
    TEMPERLOOP_FEEDBACK_ASSUME_TTY=1 \
    bash "$FEEDBACK" --type bug --message "Would send this, but declining." \
    <<<"n" ) > "$WORK/out.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "declined consent should exit 0 (rc=$rc)"
out="$(cat "$WORK/out.log")"
echo "$out" | grep -q "declined -- nothing sent" || fail "declined run should say so"
grep -q "^label create" "$GH_LOG" && fail "declined consent must never ensure the label (log: $(cat "$GH_LOG"))"
grep -q "^issue create" "$GH_LOG" && fail "declined consent must never call gh issue create (log: $(cat "$GH_LOG"))"
echo "PASS: declined consent makes no label/issue-create gh calls"

# ===========================================================================
# 7. CLI hygiene
# ===========================================================================
reset_log
run_feedback 2 bash "$FEEDBACK" --nope < /dev/null
echo "PASS: unknown argument -> exit 2"

run_feedback 0 bash "$FEEDBACK" -h < /dev/null
grep -q "usage:" "$WORK/out.log" || fail "-h should print usage"
echo "PASS: -h -> exit 0 with usage"

run_feedback 2 bash "$FEEDBACK" --type nonsense --message "x" < /dev/null
echo "PASS: invalid --type -> exit 2"

run_feedback 2 bash "$FEEDBACK" < /dev/null
grep -q "no feedback message provided" "$WORK/out.log" || fail "no-message non-interactive run should explain why"
echo "PASS: no message + non-interactive -> exit 2 with an actionable message"

echo "ALL PASS: test_feedback.sh"
