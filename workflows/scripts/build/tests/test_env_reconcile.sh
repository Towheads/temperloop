#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/env-reconcile.sh — the READ-ONLY,
# FAIL-OPEN environment reconciler (#172). Board-toolkit fixture style:
# throwaway real-git repos in a tmpdir + stubbed gh/launchctl on PATH (via a
# prepended fixture bin dir — env-reconcile.sh is a directly-invoked script,
# so it is exercised as a real subprocess here, not sourced), zero network.
#
# Covers:
#   - LEAKED_WORKTREE: a worktree whose build/<slug> branch's PR reports
#     MERGED via the stubbed gh
#   - PARKED_ON_MERGED: an operator checkout on a branch whose PR reports
#     MERGED
#   - AGENT_UNLOADED: a declared launchd plist not present in the stubbed
#     `launchctl list`
#   - --format entry emits a `### … Status: open` block when drift is present
#   - malformed input (a Label-less plist, an absent checkout path) → exit 0,
#     never aborts
#   - READ-ONLY: none of the above mutates any checkout/worktree on disk
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env-reconcile.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- Fixture: an "upstream" with a main branch -------------------------------
git init -q --initial-branch=main "$TMP/upstream"
git -C "$TMP/upstream" commit -q --allow-empty -m init

# Operator checkout #1 — also the HOST repo for the leaked worktree below.
git clone -q "$TMP/upstream" "$TMP/operator1"
OP1="$(cd "$TMP/operator1" && pwd -P)"

# Operator checkout #2 — parked on a branch whose PR will report MERGED.
git clone -q "$TMP/upstream" "$TMP/operator2"
OP2="$(cd "$TMP/operator2" && pwd -P)"
git -C "$OP2" checkout -q -b feature-parked
printf 'parked work\n' > "$OP2/p.txt"
git -C "$OP2" add p.txt
git -C "$OP2" commit -q -m "feature-parked: work"

# A leaked worktree registered against operator1: build/leaked-slug.
git -C "$OP1" worktree add -q -b build/leaked-slug "${OP1}.wt/leaked-slug" origin/main
git -C "${OP1}.wt/leaked-slug" commit -q --allow-empty -m "leaked-slug: work"

# --- Stub gh + launchctl on PATH (prepended fixture bin dir) -----------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Fake gh for env-reconcile.sh tests: `gh pr view <branch> --json state --jq .state`.
# Echoes the bare filtered value, same shape as the real --jq output.
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  branch="$3"
  case " ${GH_MOCK_MERGED_BRANCHES:-} " in
    *" $branch "*) echo MERGED ;;
    *) echo OPEN ;;
  esac
  exit 0
fi
exit 1
FAKE_GH
chmod +x "$TMP/bin/gh"

cat > "$TMP/bin/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
# Fake launchctl for env-reconcile.sh tests: `launchctl list` prints
# PID<TAB>Status<TAB>Label lines for whatever LAUNCHCTL_MOCK_LOADED names.
if [ "$1" = "list" ]; then
  for l in ${LAUNCHCTL_MOCK_LOADED:-}; do
    printf -- '-\t0\t%s\n' "$l"
  done
  exit 0
fi
exit 0
FAKE_LAUNCHCTL
chmod +x "$TMP/bin/launchctl"

# --- A declared-but-unloaded launchd agent -----------------------------------
mkdir -p "$TMP/launchd"
cat > "$TMP/launchd/com.test.envreconcile.plist" <<'FAKE_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.test.envreconcile</string>
  <key>StartInterval</key>
  <integer>3600</integer>
</dict>
</plist>
FAKE_PLIST

# --- Run: LEAKED_WORKTREE + PARKED_ON_MERGED + AGENT_UNLOADED ----------------
rc=0
out="$(
  PATH="$TMP/bin:$PATH" \
  GH_MOCK_MERGED_BRANCHES="build/leaked-slug feature-parked" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$OP1 $OP2" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/launchd" \
  bash "$SCRIPT" --format report
)" || rc=$?
[ "$rc" -eq 0 ] || fail "expected exit 0 (got $rc); output:
$out"

echo "$out" | grep -q "LEAKED_WORKTREE:MERGED:leaked-slug" \
  || fail "LEAKED_WORKTREE not detected; output:
$out"
echo "PASS: leaked-merged worktree -> LEAKED_WORKTREE:MERGED"

echo "$out" | grep -q "PARKED_ON_MERGED:feature-parked" \
  || fail "PARKED_ON_MERGED not detected; output:
$out"
echo "PASS: operator checkout on a merged branch -> PARKED_ON_MERGED"

echo "$out" | grep -q "AGENT_UNLOADED:com.test.envreconcile" \
  || fail "AGENT_UNLOADED not detected; output:
$out"
echo "PASS: declared-but-unloaded launchd agent -> AGENT_UNLOADED"

echo "$out" | grep -q "^DRIFT: 3$" \
  || fail "expected DRIFT: 3 summary line; output:
$out"
echo "PASS: drift summary counts all 3 classes"

# --- --format entry: a ready-to-append vault block when drift is present ----
rc=0
entry="$(
  PATH="$TMP/bin:$PATH" \
  GH_MOCK_MERGED_BRANCHES="build/leaked-slug feature-parked" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$OP1 $OP2" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/launchd" \
  bash "$SCRIPT" --format entry
)" || rc=$?
[ "$rc" -eq 0 ] || fail "--format entry: expected exit 0 (got $rc); output:
$entry"
echo "$entry" | grep -qE '^### .* · env reconcile ·' \
  || fail "--format entry missing heading; got:
$entry"
echo "$entry" | grep -q 'Status:\*\* open' \
  || fail "--format entry missing Status: open; got:
$entry"
echo "PASS: --format entry emits a ### ... Status: open block when drift is present"

# --- clean run: --format entry emits NOTHING when there is no drift ---------
rc=0
clean_entry="$(
  PATH="$TMP/bin:$PATH" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$TMP/no-such-operator-checkout" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/no-such-launchd-dir" \
  bash "$SCRIPT" --format entry
)" || rc=$?
[ "$rc" -eq 0 ] || fail "clean --format entry: expected exit 0 (got $rc)"
[ -z "$clean_entry" ] || fail "clean --format entry: expected no output, got:
$clean_entry"
echo "PASS: --format entry emits nothing when no drift is found"

# --- malformed input: a Label-less plist + an absent checkout -> exit 0 -----
printf 'not a plist at all\n' > "$TMP/launchd/garbage.plist"
rc2=0
out2="$(
  PATH="$TMP/bin:$PATH" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$TMP/no-such-operator-checkout" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/launchd" \
  bash "$SCRIPT" --format report
)" || rc2=$?
[ "$rc2" -eq 0 ] || fail "malformed input: expected exit 0 (got $rc2); output:
$out2"
echo "$out2" | grep -q "MALFORMED_PLIST:garbage.plist" \
  || fail "malformed plist not reported; output:
$out2"
echo "PASS: malformed plist + absent checkout -> exit 0, never aborts"

# --- read-only: nothing above mutated any checkout/worktree on disk ---------
[ -z "$(git -C "$OP1" status --porcelain)" ] || fail "operator1 checkout was mutated"
[ -z "$(git -C "$OP2" status --porcelain)" ] || fail "operator2 checkout was mutated"
[ -d "${OP1}.wt/leaked-slug" ] || fail "leaked worktree was removed (env-reconcile.sh must be READ-ONLY)"
echo "PASS: read-only -- no checkout/worktree was mutated by any run"

# --- AGENT_STALE freshness oracle (#1173 / #904): heartbeat marker, not mtime --
# launchd touches StandardOutPath on every wake, so freshness must be judged from
# a marker the job writes on SUCCESS. Three loaded agents in an isolated dir:
HB="$TMP/heartbeat"; mkdir -p "$HB"
mkdir -p "$TMP/launchd-fresh"
for lbl in com.test.stale com.test.fresh com.test.nomarker; do
  cat > "$TMP/launchd-fresh/$lbl.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$lbl</string>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>StandardOutPath</key>
  <string>$TMP/$lbl.out.log</string>
</dict>
</plist>
PL
  # Every agent has a FRESH, 0-byte StandardOutPath — the exact #1173 trap: launchd
  # opened the log on a wake, giving it a current mtime regardless of whether the
  # job did any work.
  : > "$TMP/$lbl.out.log"
done
# com.test.stale: last SUCCESS marker is ancient (older than the 3600s cadence) →
# STALE, even though its StandardOutPath mtime is fresh. Old (mtime) code would
# false-FRESH this; the marker oracle correctly flags it. THE #1173 regression.
touch -t 202001010000 "$HB/com.test.stale.ran"
# com.test.fresh: marker touched now (< cadence) → clean.
touch "$HB/com.test.fresh.ran"
# com.test.nomarker: no marker at all → freshness unknown (nothing emitted),
# never a false-STALE from the launchd-touched log.

rc=0
sout="$(
  PATH="$TMP/bin:$PATH" \
  LAUNCHCTL_MOCK_LOADED="com.test.stale com.test.fresh com.test.nomarker" \
  ENV_RECONCILE_AGENT_HEARTBEAT_DIR="$HB" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$TMP/no-such-operator-checkout" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/launchd-fresh" \
  bash "$SCRIPT" --format report
)" || rc=$?
[ "$rc" -eq 0 ] || fail "AGENT_STALE run: expected exit 0 (got $rc); output:
$sout"
echo "$sout" | grep -q "AGENT_STALE:com.test.stale" \
  || fail "#1173 regression: agent with an ancient success-marker but a fresh launchd-touched log was NOT flagged AGENT_STALE; output:
$sout"
echo "PASS: #1173 — freshness judged from the heartbeat marker (ancient) not StandardOutPath mtime (fresh) -> AGENT_STALE"
if echo "$sout" | grep -q "AGENT_STALE:com.test.fresh"; then
  fail "fresh heartbeat wrongly flagged AGENT_STALE; output:
$sout"
fi
echo "PASS: loaded agent with a fresh marker -> not stale"
if echo "$sout" | grep -q "AGENT_STALE:com.test.nomarker"; then
  fail "marker-less agent flagged STALE from launchd-touched log mtime (the false-STALE #1173 warns against); output:
$sout"
fi
echo "PASS: marker-less agent is freshness-unknown, never false-STALE"

echo "ALL PASS: test_env_reconcile.sh"
