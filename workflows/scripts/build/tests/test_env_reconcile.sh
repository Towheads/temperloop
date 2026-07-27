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
  ENV_RECONCILE_AGENT_INSTALL_DIR="$TMP/launchd" \
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
  ENV_RECONCILE_AGENT_INSTALL_DIR="$TMP/launchd" \
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
  ENV_RECONCILE_AGENT_INSTALL_DIR="$TMP/launchd" \
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
  ENV_RECONCILE_AGENT_INSTALL_DIR="$TMP/launchd-fresh" \
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

# --- #531 host-role awareness: a NON-owning host (laptop) emits no false drift ---
# A laptop declares the same plists (its checkouts carry infra/launchd/) but never
# INSTALLED them (~/Library/LaunchAgents / AGENT_INSTALL_DIR has none) and does not
# hold the cron checkouts. It must NOT flag the agent host's agents AGENT_UNLOADED nor the
# mini's cron checkouts as ABSENT. Auto-detect path (no ENV_RECONCILE_AGENT_HOSTS).
mkdir -p "$TMP/install-empty"   # an install dir with none of the declared agents
rc=0
lout="$(
  PATH="$TMP/bin:$PATH" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-A $TMP/no-such-cron-B" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$TMP/no-such-operator-checkout" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/launchd" \
  ENV_RECONCILE_AGENT_INSTALL_DIR="$TMP/install-empty" \
  bash "$SCRIPT" --format report
)" || rc=$?
[ "$rc" -eq 0 ] || fail "#531 non-owning host: expected exit 0 (got $rc); output:
$lout"
if echo "$lout" | grep -q "AGENT_UNLOADED:com.test.envreconcile"; then
  fail "#531 non-owning host FALSE-flagged AGENT_UNLOADED for an agent it does not own; output:
$lout"
fi
echo "$lout" | grep -q "EXPECTED_ELSEWHERE:com.test.envreconcile" \
  || fail "#531 non-owning host: agent it does not own should be EXPECTED_ELSEWHERE; output:
$lout"
echo "$lout" | grep -q "EXPECTED     $TMP/no-such-cron-A  \[EXPECTED_ELSEWHERE\]" \
  || fail "#531 non-owning host: unowned cron checkout should be EXPECTED_ELSEWHERE, not ABSENT; output:
$lout"
if echo "$lout" | grep -qE "ABSENT +$TMP/no-such-cron-A"; then
  fail "#531 non-owning host STILL emits ABSENT for a cron checkout it does not own; output:
$lout"
fi
# The unowned agent must NOT appear on a DRIFT line (it is EXPECTED, not drift).
if echo "$lout" | grep -q "DRIFT.*com.test.envreconcile"; then
  fail "#531 non-owning host counted an unowned agent as drift; output:
$lout"
fi
echo "PASS: #531 non-owning host — no false AGENT_UNLOADED / ABSENT; unowned resources -> EXPECTED_ELSEWHERE (not drift)"

# --- #531: the OWNING host still catches a genuinely-unloaded agent as drift ----
# Same declared plist, but installed here (AGENT_INSTALL_DIR contains it) and NOT
# in `launchctl list` -> a real AGENT_UNLOADED that must still surface as drift.
rc=0
oout="$(
  PATH="$TMP/bin:$PATH" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$TMP/no-such-operator-checkout" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/launchd" \
  ENV_RECONCILE_AGENT_INSTALL_DIR="$TMP/launchd" \
  bash "$SCRIPT" --format report
)" || rc=$?
[ "$rc" -eq 0 ] || fail "#531 owning host: expected exit 0 (got $rc); output:
$oout"
echo "$oout" | grep -q "DRIFT.*AGENT_UNLOADED:com.test.envreconcile" \
  || fail "#531 REGRESSION: owning host failed to flag a genuinely-unloaded installed agent as DRIFT; output:
$oout"
echo "$oout" | grep -qE "^DRIFT: [0-9]" \
  || fail "#531 owning host: a real unloaded agent should register drift; output:
$oout"
echo "PASS: #531 owning host — a genuinely-unloaded INSTALLED agent still flags AGENT_UNLOADED (drift)"

# --- #531 explicit ENV_RECONCILE_AGENT_HOSTS seam (a hosts map) -----------------
# When the owning host is named explicitly, host membership decides ownership
# regardless of the install dir. This host in the list -> owned -> real drift.
rc=0
hin="$(
  PATH="$TMP/bin:$PATH" \
  SUBSET_HOST_LABEL="thehost" \
  ENV_RECONCILE_AGENT_HOSTS="otherhost thehost" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$TMP/no-such-operator-checkout" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/launchd" \
  ENV_RECONCILE_AGENT_INSTALL_DIR="$TMP/install-empty" \
  bash "$SCRIPT" --format report
)" || rc=$?
[ "$rc" -eq 0 ] || fail "#531 hosts-map (owning): expected exit 0 (got $rc)"
echo "$hin" | grep -q "AGENT_UNLOADED:com.test.envreconcile" \
  || fail "#531 hosts-map: this host IS the owner (in AGENT_HOSTS) so an unloaded agent must flag AGENT_UNLOADED even with an empty install dir; output:
$hin"
echo "PASS: #531 ENV_RECONCILE_AGENT_HOSTS names this host -> owns role -> real drift caught"

# This host NOT in the list -> not owned -> EXPECTED_ELSEWHERE even though the
# plist happens to be present in AGENT_INSTALL_DIR (the host list wins).
rc=0
hout="$(
  PATH="$TMP/bin:$PATH" \
  SUBSET_HOST_LABEL="thehost" \
  ENV_RECONCILE_AGENT_HOSTS="mini-only" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$TMP/no-such-operator-checkout" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/launchd" \
  ENV_RECONCILE_AGENT_INSTALL_DIR="$TMP/launchd" \
  bash "$SCRIPT" --format report
)" || rc=$?
[ "$rc" -eq 0 ] || fail "#531 hosts-map (non-owning): expected exit 0 (got $rc)"
if echo "$hout" | grep -q "AGENT_UNLOADED:com.test.envreconcile"; then
  fail "#531 hosts-map: this host is NOT the named owner, so the agent must be EXPECTED_ELSEWHERE not AGENT_UNLOADED; output:
$hout"
fi
echo "$hout" | grep -q "EXPECTED_ELSEWHERE:com.test.envreconcile" \
  || fail "#531 hosts-map: non-owning host should report EXPECTED_ELSEWHERE; output:
$hout"
echo "PASS: #531 ENV_RECONCILE_AGENT_HOSTS excludes this host -> EXPECTED_ELSEWHERE (host list wins over install dir)"

# --- #531 read-only preserved on the new host-role paths ------------------------
[ -z "$(git -C "$OP1" status --porcelain)" ] || fail "operator1 mutated by host-role runs"
echo "PASS: #531 host-role classification stays read-only"

# --- STALE_VENDORED_HOOK (foundation#1353 / F#932) ---------------------------
# A guard hook is canonical in the kernel's claude/hooks/ and push-synced into
# each consumer at .claude/hooks/<hook>, where the sync stamps a provenance
# banner. Drift = the copy's body differs from canonical; the BANNER must not
# itself read as drift (it is absent from canonical by construction, so counting
# it would mark every synced consumer permanently stale).
#
# Fixtures, never the live checkouts on this host: the real consumers are being
# re-synced by sibling work, so a test asserting on them would flip from pass to
# fail the moment they are fixed. The states are modelled here instead.
mkdir -p "$TMP/canonical-hooks"
cat > "$TMP/canonical-hooks/build-worktree-guard.sh" <<'CANON'
#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash|Edit|Write|MultiEdit) — build worker write jail.
isDestructive() { case "$1" in rm|rmdir|mv|shred|truncate) return 0 ;; esac; return 1; }
CANON

# Consumer A — STALE: carries the pre-Bash-arm body under a sync banner.
git clone -q "$TMP/upstream" "$TMP/consumer-stale"
CSTALE="$(cd "$TMP/consumer-stale" && pwd -P)"
mkdir -p "$CSTALE/.claude/hooks"
cat > "$CSTALE/.claude/hooks/build-worktree-guard.sh" <<'STALEHOOK'
#!/usr/bin/env bash
# GENERATED by foundation 'make sync-stagefind-hooks' — DO NOT EDIT HERE.
# Source of truth: foundation/claude/hooks/. Edit there, then re-sync.
#
# PreToolUse hook (matcher: Edit|Write|MultiEdit) — build worker write jail.
STALEHOOK

# Consumer B — IN SYNC: canonical body, differing ONLY by the sync banner.
git clone -q "$TMP/upstream" "$TMP/consumer-insync"
CSYNC="$(cd "$TMP/consumer-insync" && pwd -P)"
mkdir -p "$CSYNC/.claude/hooks"
{
  printf '#!/usr/bin/env bash\n'
  printf "# GENERATED by foundation 'make sync-ssmobile-hooks' — DO NOT EDIT HERE.\n"
  printf '# Source of truth: foundation/claude/hooks/. Edit there, then re-sync.\n'
  tail -n +2 "$TMP/canonical-hooks/build-worktree-guard.sh"
} > "$CSYNC/.claude/hooks/build-worktree-guard.sh"

# Consumer C — vendors NO copy of the hook at all (must be skipped SILENTLY).
git clone -q "$TMP/upstream" "$TMP/consumer-nohook"
CNOHOOK="$(cd "$TMP/consumer-nohook" && pwd -P)"

rc=0
vout="$(
  PATH="$TMP/bin:$PATH" \
  ENV_RECONCILE_CANONICAL_HOOK_DIR="$TMP/canonical-hooks" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$CSTALE $CSYNC $CNOHOOK $TMP/no-such-consumer" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/no-such-launchd-dir" \
  bash "$SCRIPT" --format report
)" || rc=$?
[ "$rc" -eq 0 ] || fail "STALE_VENDORED_HOOK run: expected exit 0 (got $rc); output:
$vout"

echo "$vout" | grep -q "DRIFT.*$CSTALE.*STALE_VENDORED_HOOK:build-worktree-guard.sh" \
  || fail "drifted vendored hook NOT flagged STALE_VENDORED_HOOK; output:
$vout"
echo "PASS: consumer with an out-of-date vendored guard -> STALE_VENDORED_HOOK:build-worktree-guard.sh"

# The banner-exclusion regression: body identical, banner present -> NOT drift.
if echo "$vout" | grep -q "$CSYNC.*STALE_VENDORED_HOOK"; then
  fail "in-sync copy FALSE-flagged as stale — the sync banner is being counted as drift; output:
$vout"
fi
echo "$vout" | grep -qE "OK +$CSYNC\$" \
  || fail "in-sync consumer should report OK; output:
$vout"
echo "PASS: in-sync copy differing only by the sync banner -> no drift (banner excluded)"

# Fail-open: a consumer vendoring no copy, and an entirely absent checkout.
if echo "$vout" | grep -q "$CNOHOOK.*STALE_VENDORED_HOOK"; then
  fail "consumer vendoring NO hook was flagged; must be skipped silently; output:
$vout"
fi
echo "$vout" | grep -qE "OK +$CNOHOOK\$" \
  || fail "consumer with no vendored hook should report OK; output:
$vout"
if echo "$vout" | grep -q "no-such-consumer.*STALE_VENDORED_HOOK"; then
  fail "absent checkout raised STALE_VENDORED_HOOK; must be skipped silently; output:
$vout"
fi
echo "$vout" | grep -q "^DRIFT: 1$" \
  || fail "expected exactly 1 alarm (the stale consumer only) — the remedy line must not count as a second; output:
$vout"
echo "PASS: no vendored copy / absent checkout -> skipped silently, exactly 1 alarm"

# The remedy names the EXACT sync command, read from the copy's own banner.
echo "$vout" | grep -q "re-sync build-worktree-guard.sh: make sync-stagefind-hooks" \
  || fail "report format missing the exact re-sync command from the copy's banner; output:
$vout"
echo "PASS: report remedy names the exact sync command from the vendored copy's banner"

# --- the class + remedy must reach --format entry too (the /tidy routing path) --
rc=0
ventry="$(
  PATH="$TMP/bin:$PATH" \
  ENV_RECONCILE_CANONICAL_HOOK_DIR="$TMP/canonical-hooks" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$CSTALE $CSYNC $CNOHOOK" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/no-such-launchd-dir" \
  bash "$SCRIPT" --format entry
)" || rc=$?
[ "$rc" -eq 0 ] || fail "STALE_VENDORED_HOOK --format entry: expected exit 0 (got $rc)"
echo "$ventry" | grep -q "STALE_VENDORED_HOOK:build-worktree-guard.sh" \
  || fail "--format entry omitted STALE_VENDORED_HOOK — /tidy would never route it to the hygiene report; got:
$ventry"
# shellcheck disable=SC2016  # the backticks are LITERAL — the entry format wraps
# the remedy in a markdown code span, so single quotes here are load-bearing.
echo "$ventry" | grep -q 'remedy — re-sync build-worktree-guard.sh into '"$CSTALE"': `make sync-stagefind-hooks`' \
  || fail "--format entry omitted the remedy command; got:
$ventry"
echo "$ventry" | grep -q 'Status:\*\* open' \
  || fail "--format entry missing Status: open; got:
$ventry"
echo "PASS: STALE_VENDORED_HOOK + remedy are emitted in BOTH probe formats"

# --- a drifted copy with NO banner -> generic sync-engine remedy fallback -----
printf '#!/usr/bin/env bash\n# a hand-placed copy with no sync provenance banner\n' \
  > "$CSTALE/.claude/hooks/build-worktree-guard.sh"
rc=0
vbare="$(
  PATH="$TMP/bin:$PATH" \
  ENV_RECONCILE_CANONICAL_HOOK_DIR="$TMP/canonical-hooks" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$CSTALE" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/no-such-launchd-dir" \
  bash "$SCRIPT" --format report
)" || rc=$?
[ "$rc" -eq 0 ] || fail "banner-less drifted copy: expected exit 0 (got $rc)"
echo "$vbare" | grep -q "re-sync build-worktree-guard.sh: make sync-hooks TARGET_REPO=$CSTALE" \
  || fail "banner-less copy should fall back to the generic sync engine remedy; output:
$vbare"
echo "PASS: banner-less drifted copy -> generic 'make sync-hooks TARGET_REPO=<repo>' remedy"

# --- fail-open: an unresolvable canonical dir disables the check entirely -----
rc=0
vnone="$(
  PATH="$TMP/bin:$PATH" \
  ENV_RECONCILE_CANONICAL_HOOK_DIR="$TMP/no-such-canonical-hooks" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$CSTALE" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/no-such-launchd-dir" \
  bash "$SCRIPT" --format report
)" || rc=$?
[ "$rc" -eq 0 ] || fail "absent canonical dir: expected exit 0 (got $rc); output:
$vnone"
if echo "$vnone" | grep -q "STALE_VENDORED_HOOK"; then
  fail "absent canonical reference must disable the check (fail-open), not flag drift; output:
$vnone"
fi
echo "$vnone" | grep -q "^OK$" \
  || fail "absent canonical dir should leave the run clean; output:
$vnone"
echo "PASS: unresolvable canonical hook dir -> check skipped silently (fail-open)"

# --- READ-ONLY on the new path: no consumer checkout was mutated --------------
for cdir in "$CSYNC" "$CNOHOOK"; do
  [ -z "$(git -C "$cdir" status --porcelain --untracked-files=no)" ] \
    || fail "vendored-hook comparison mutated tracked content in $cdir"
done
[ -f "$CSYNC/.claude/hooks/build-worktree-guard.sh" ] \
  || fail "vendored-hook comparison removed a consumer's hook (must be READ-ONLY)"
echo "PASS: STALE_VENDORED_HOOK detection stays read-only"

echo "ALL PASS: test_env_reconcile.sh"
