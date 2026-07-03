#!/usr/bin/env bash
#
# Tests for the 14-day report auto-offer — a PASSIVE pre-dispatch check
# added to kernel/bin/foundation itself (foundation #766 Epic E, item
# report-auto-offer / #880), alongside the dispatcher's existing
# foundation_check_prereqs. Zero network — fake `claude` and `gh` binaries
# sit on PATH ahead of the real ones (mirroring the try.sh/init.sh/
# baseline-snapshot.sh test convention: see test_baseline_snapshot.sh)
# purely to satisfy the dispatcher's own prereq gate; every case here
# drives the REAL kernel/bin/foundation dispatcher end to end against a
# scratch fixture repo and a scratch XDG_STATE_HOME.
#
# Covers:
#   1. no .foundation/baseline.jsonl at all -> no offer.
#   2. baseline present, first record < 14 days old -> no offer.
#   3. baseline present, first record >= 14 days old, undismissed -> the
#      offer prints (to stderr), names both accept-action commands
#      (baseline-snapshot + report), and the subcommand still runs
#      (dispatch is never blocked by this passive check).
#   4. anchor is the FIRST record's embedded generated_at, not the file's
#      mtime and not any LATER record's generated_at: a fixture whose file
#      mtime is "now" (freshly written by the test) but whose first
#      record's generated_at is old, and whose second (latest) record's
#      generated_at is fresh, still fires — proving neither mtime nor the
#      latest record is the anchor.
#   5. fires once: a second dispatch against the same repo after case 3
#      does NOT print the offer again (dismissal state persisted).
#   6. dismissal is keyed by repo: a second, independent fixture repo
#      (also >=14 days stale) still gets its own offer even though the
#      first repo is already dismissed.
#   7. dismissal state never lands in the repo tree — only under
#      XDG_STATE_HOME.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION_BIN="$HERE/../../foundation"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/report-offer-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

# --- fake claude + gh: just enough to satisfy foundation_check_prereqs and
# let baseline-snapshot.sh (the subcommand we dispatch through in every
# case below) run without touching the network. ----------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/claude"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  pr) echo "[]"; exit 0 ;;
  issue) echo "[]"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

# --- portable "N days before now" ISO-8601 UTC, mirroring
# baseline-snapshot.sh's own _baseline_date_sub_days helper. ---------------
if date --version >/dev/null 2>&1; then
  _iso_days_ago() { date -u -d "-${1} days" +%Y-%m-%dT%H:%M:%SZ; }        # GNU
else
  _iso_days_ago() { date -u -v-"${1}"d +%Y-%m-%dT%H:%M:%SZ; }             # BSD
fi

new_fixture_repo() {
  local name="$1"
  local repo="$WORK/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" remote add origin "git@github.com:test-owner/$name.git"
  printf '%s\n' "$repo"
}

run_foundation() {
  # run_foundation <repo_dir> <state_home> -- dispatches `foundation
  # baseline-snapshot` (a real, side-effect-light subcommand) so the
  # dispatcher's full prereq + offer-check + dispatch flow executes.
  (cd "$1" && PATH="$BIN:$PATH" XDG_STATE_HOME="$2" bash "$FOUNDATION_BIN" baseline-snapshot)
}

STATE1="$WORK/state1"

# --- 1: no baseline.jsonl at all -> no offer --------------------------------
REPO1="$(new_fixture_repo repo1)"
out="$(run_foundation "$REPO1" "$STATE1" 2>&1 1>/dev/null)"
echo "$out" | grep -q "baseline snapshot is" && fail "no offer expected with no baseline.jsonl yet"

# --- 2: baseline present, first record < 14 days old -> no offer -----------
mkdir -p "$REPO1/.foundation"
fresh_ts="$(_iso_days_ago 3)"
printf '{"schema":1,"generated_at":"%s","lookback_days":90,"repo":{"gh_repo":"test-owner/repo1"},"metrics":{"available":false,"reason":"x","pr_throughput":null,"time_to_merge_hours":null,"review_latency_hours":null,"issue_backlog":null}}\n' \
  "$fresh_ts" > "$REPO1/.foundation/baseline.jsonl"
out="$(run_foundation "$REPO1" "$STATE1" 2>&1 1>/dev/null)"
echo "$out" | grep -q "baseline snapshot is" && fail "no offer expected when first record is only 3 days old"

# --- 3/4: first record >= 14 days old (anchor test: mtime is 'now', a
# LATER record is fresh, only the FIRST record's generated_at is old) ------
STATE3="$WORK/state3"
REPO3="$(new_fixture_repo repo3)"
mkdir -p "$REPO3/.foundation"
old_ts="$(_iso_days_ago 20)"
now_ts="$(_iso_days_ago 0)"
{
  printf '{"schema":1,"generated_at":"%s","lookback_days":90,"repo":{"gh_repo":"test-owner/repo3"},"metrics":{"available":false,"reason":"x","pr_throughput":null,"time_to_merge_hours":null,"review_latency_hours":null,"issue_backlog":null}}\n' "$old_ts"
  printf '{"schema":1,"generated_at":"%s","lookback_days":90,"repo":{"gh_repo":"test-owner/repo3"},"metrics":{"available":false,"reason":"x","pr_throughput":null,"time_to_merge_hours":null,"review_latency_hours":null,"issue_backlog":null}}\n' "$now_ts"
} > "$REPO3/.foundation/baseline.jsonl"
# file mtime is "now" (just written) -- proves the anchor is NOT mtime.

out="$(run_foundation "$REPO3" "$STATE3" 2>&1 1>/dev/null)"
echo "$out" | grep -q "baseline snapshot is" || fail "offer should fire when the FIRST record is >=14 days old"
echo "$out" | grep -q "foundation baseline-snapshot && foundation report" || fail "offer should document the accept-action chain (baseline-snapshot then report)"

# subcommand dispatch must still have run (offer is advisory, never blocking)
lines_after_first_dispatch="$(wc -l < "$REPO3/.foundation/baseline.jsonl" | tr -d ' ')"
[ "$lines_after_first_dispatch" -eq 3 ] || fail "the dispatched subcommand (baseline-snapshot) should still have appended its own record"

# --- 7: dismissal state lands only under XDG_STATE_HOME, never in the repo -
find "$REPO3" -name '*dismiss*' | grep -q . && fail "dismissal state must never be written inside the repo tree"
find "$STATE3" -type f | grep -q . || fail "dismissal state should be written under XDG_STATE_HOME"

# --- 5: fires once -- a second dispatch does not repeat the offer ----------
out2="$(run_foundation "$REPO3" "$STATE3" 2>&1 1>/dev/null)"
echo "$out2" | grep -q "baseline snapshot is" && fail "the offer must not repeat once already dismissed for this repo"

# --- 6: dismissal is keyed by repo -- an independent stale repo still gets
# its own offer even though repo3's dismissal state already exists in the
# same XDG_STATE_HOME. -------------------------------------------------------
REPO6="$(new_fixture_repo repo6)"
mkdir -p "$REPO6/.foundation"
old_ts6="$(_iso_days_ago 30)"
printf '{"schema":1,"generated_at":"%s","lookback_days":90,"repo":{"gh_repo":"test-owner/repo6"},"metrics":{"available":false,"reason":"x","pr_throughput":null,"time_to_merge_hours":null,"review_latency_hours":null,"issue_backlog":null}}\n' \
  "$old_ts6" > "$REPO6/.foundation/baseline.jsonl"
out6="$(run_foundation "$REPO6" "$STATE3" 2>&1 1>/dev/null)"
echo "$out6" | grep -q "baseline snapshot is" || fail "a different, independently-stale repo should still get its own offer"

echo "OK: test_report_offer.sh"
