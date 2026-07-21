#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/issue-state.sh's `reattach` subcommand
# (temperloop #636, epic #627 `/fix` targeted single-item fix driver).
#
# Entirely OFFLINE via the --dry-run --fixture harness (mirrors
# test_issue_state_resolve.sh's convention): each case seeds a fixture
# directory with the reattach fixture files (reattach-pr-<pr>.json,
# ci-poll-<pr>.json, rebase-<pr>.json, ci-poll-rebased-<pr>.json) and asserts
# on the emitted ready/reason verdict JSON. Zero network, zero `gh`, zero live
# ci-poll.sh (the DRY_RUN path reads the ci-poll fixtures directly).
#
# Covers the acceptance state shapes (all 6 required, + conflict + activation):
#   1. green-ready          OPEN/MERGEABLE/CLEAN, CI green      -> ready true  "green-ready"
#   2. ci-pending           OPEN/MERGEABLE/CLEAN, CI TIMEOUT    -> ready false "ci-pending"
#   3. ci-red               OPEN/MERGEABLE/CLEAN, CI failed     -> ready false "ci-red"
#   4. stale-base-rebasable OPEN/MERGEABLE/BEHIND, rebase+green -> ready true  "rebased"
#   5. stale-base-conflict  OPEN/MERGEABLE/BEHIND, rebase clash -> ready false "stale-base-conflict"
#   6. closed-underneath    MERGED (or CLOSED)                   -> ready false "closed-underneath"
#   7. conflict             CONFLICTING (CI NOT polled)          -> ready false "conflict"
#
# Also: the reattach --help / no-args activation-proof contract.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../issue-state.sh"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

seed() { mkdir -p "$1"; }

R() { bash "$CLI" reattach acme/widgets "$1" --dry-run --fixture "$2"; }

# ── test 1: green-ready ──────────────────────────────────────────────────
echo "--- test 1: OPEN/MERGEABLE/CLEAN, CI green -> ready green-ready ---"
FX="$TMP/t1"; seed "$FX"
cat > "$FX/reattach-pr-201.json" <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"aaa111"}
JSON
cat > "$FX/ci-poll-201.json" <<'JSON'
{"outcome":"CI_GREEN","pr":201,"sha":"aaa111"}
JSON
OUT="$(R 201 "$FX")"
[ "$(jq -r '.ready' <<<"$OUT")" = "true" ] && ok "ready=true" || bad "t1.ready" "got $(jq -r '.ready' <<<"$OUT")"
[ "$(jq -r '.reason' <<<"$OUT")" = "green-ready" ] && ok "reason=green-ready" || bad "t1.reason" "got $(jq -r '.reason' <<<"$OUT")"
[ "$(jq -r '.ci' <<<"$OUT")" = "green" ] && ok "ci=green" || bad "t1.ci" "got $(jq -r '.ci' <<<"$OUT")"
[ "$(jq -r '.state' <<<"$OUT")" = "OPEN" ] && ok "state=OPEN" || bad "t1.state" "got $(jq -r '.state' <<<"$OUT")"
[ "$(jq -r '.repo' <<<"$OUT")" = "acme/widgets" ] && ok "repo echoed" || bad "t1.repo" "got $(jq -r '.repo' <<<"$OUT")"
[ "$(jq -r '.pr' <<<"$OUT")" = "201" ] && ok "pr echoed" || bad "t1.pr" "got $(jq -r '.pr' <<<"$OUT")"

# ── test 2: ci-pending (TIMEOUT) ─────────────────────────────────────────
echo "--- test 2: OPEN/MERGEABLE/CLEAN, CI TIMEOUT -> ready false ci-pending ---"
FX="$TMP/t2"; seed "$FX"
cat > "$FX/reattach-pr-202.json" <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"bbb222"}
JSON
cat > "$FX/ci-poll-202.json" <<'JSON'
{"outcome":"TIMEOUT","pr":202,"sha":"bbb222","waited":3600}
JSON
OUT="$(R 202 "$FX")"
[ "$(jq -r '.ready' <<<"$OUT")" = "false" ] && ok "ready=false" || bad "t2.ready" "got $(jq -r '.ready' <<<"$OUT")"
[ "$(jq -r '.reason' <<<"$OUT")" = "ci-pending" ] && ok "reason=ci-pending" || bad "t2.reason" "got $(jq -r '.reason' <<<"$OUT")"
[ "$(jq -r '.ci' <<<"$OUT")" = "pending" ] && ok "ci=pending" || bad "t2.ci" "got $(jq -r '.ci' <<<"$OUT")"

# ── test 3: ci-red (CI_FAILED) ───────────────────────────────────────────
echo "--- test 3: OPEN/MERGEABLE/CLEAN, CI failed -> ready false ci-red ---"
FX="$TMP/t3"; seed "$FX"
cat > "$FX/reattach-pr-203.json" <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"ccc333"}
JSON
cat > "$FX/ci-poll-203.json" <<'JSON'
{"outcome":"CI_FAILED","pr":203,"sha":"ccc333","failed_run_ids":[9]}
JSON
OUT="$(R 203 "$FX")"
[ "$(jq -r '.ready' <<<"$OUT")" = "false" ] && ok "ready=false" || bad "t3.ready" "got $(jq -r '.ready' <<<"$OUT")"
[ "$(jq -r '.reason' <<<"$OUT")" = "ci-red" ] && ok "reason=ci-red" || bad "t3.reason" "got $(jq -r '.reason' <<<"$OUT")"
[ "$(jq -r '.ci' <<<"$OUT")" = "red" ] && ok "ci=red" || bad "t3.ci" "got $(jq -r '.ci' <<<"$OUT")"

# ── test 4: stale-base-rebasable (BEHIND -> rebase -> green re-poll) ──────
echo "--- test 4: OPEN/MERGEABLE/BEHIND, rebase clean + green re-poll -> ready rebased ---"
FX="$TMP/t4"; seed "$FX"
cat > "$FX/reattach-pr-204.json" <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"BEHIND","headRefOid":"ddd444"}
JSON
# The FIRST (head-oid-pinned) CI poll must be green so the precedence continues
# past step 3 into the BEHIND/rebase branch.
cat > "$FX/ci-poll-204.json" <<'JSON'
{"outcome":"CI_GREEN","pr":204,"sha":"ddd444"}
JSON
cat > "$FX/rebase-204.json" <<'JSON'
{"outcome":"REBASED","base":"old","tip":"newtip","sha":"eee555"}
JSON
# The SECOND (rebased-sha-pinned) re-poll: green after the rebase.
cat > "$FX/ci-poll-rebased-204.json" <<'JSON'
{"outcome":"CI_GREEN","pr":204,"sha":"eee555"}
JSON
OUT="$(R 204 "$FX")"
[ "$(jq -r '.ready' <<<"$OUT")" = "true" ] && ok "ready=true" || bad "t4.ready" "got $(jq -r '.ready' <<<"$OUT")"
[ "$(jq -r '.reason' <<<"$OUT")" = "rebased" ] && ok "reason=rebased" || bad "t4.reason" "got $(jq -r '.reason' <<<"$OUT")"
[ "$(jq -r '.merge_state' <<<"$OUT")" = "BEHIND" ] && ok "merge_state=BEHIND surfaced" || bad "t4.merge_state" "got $(jq -r '.merge_state' <<<"$OUT")"

# ── test 4b: stale-base BEHIND but the rebased re-poll goes RED ───────────
echo "--- test 4b: BEHIND, rebase clean but rebased re-poll RED -> ready false ci-red ---"
FX="$TMP/t4b"; seed "$FX"
cat > "$FX/reattach-pr-214.json" <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"BEHIND","headRefOid":"a14"}
JSON
cat > "$FX/ci-poll-214.json" <<'JSON'
{"outcome":"CI_GREEN","pr":214,"sha":"a14"}
JSON
cat > "$FX/rebase-214.json" <<'JSON'
{"outcome":"REBASED","sha":"b14"}
JSON
cat > "$FX/ci-poll-rebased-214.json" <<'JSON'
{"outcome":"CI_FAILED","pr":214,"sha":"b14","failed_run_ids":[3]}
JSON
OUT="$(R 214 "$FX")"
[ "$(jq -r '.ready' <<<"$OUT")" = "false" ] && ok "ready=false" || bad "t4b.ready" "got $(jq -r '.ready' <<<"$OUT")"
[ "$(jq -r '.reason' <<<"$OUT")" = "ci-red" ] && ok "reason=ci-red (rebased re-poll red)" || bad "t4b.reason" "got $(jq -r '.reason' <<<"$OUT")"

# ── test 5: stale-base-conflict (BEHIND -> rebase conflict) ──────────────
echo "--- test 5: OPEN/MERGEABLE/BEHIND, rebase conflict -> ready false stale-base-conflict ---"
FX="$TMP/t5"; seed "$FX"
cat > "$FX/reattach-pr-205.json" <<'JSON'
{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"BEHIND","headRefOid":"fff666"}
JSON
cat > "$FX/ci-poll-205.json" <<'JSON'
{"outcome":"CI_GREEN","pr":205,"sha":"fff666"}
JSON
cat > "$FX/rebase-205.json" <<'JSON'
{"outcome":"REBASE_CONFLICT","base":"old","tip":"fff666","error":"CONFLICT (content)"}
JSON
OUT="$(R 205 "$FX")"
[ "$(jq -r '.ready' <<<"$OUT")" = "false" ] && ok "ready=false" || bad "t5.ready" "got $(jq -r '.ready' <<<"$OUT")"
[ "$(jq -r '.reason' <<<"$OUT")" = "stale-base-conflict" ] && ok "reason=stale-base-conflict" || bad "t5.reason" "got $(jq -r '.reason' <<<"$OUT")"

# ── test 6: closed-underneath ────────────────────────────────────────────
echo "--- test 6: MERGED underneath -> ready false closed-underneath ---"
FX="$TMP/t6"; seed "$FX"
cat > "$FX/reattach-pr-206.json" <<'JSON'
{"state":"MERGED","mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","headRefOid":"ggg777"}
JSON
# A ci-poll fixture is present but MUST NOT be consulted (state precedence wins first).
cat > "$FX/ci-poll-206.json" <<'JSON'
{"outcome":"CI_GREEN","pr":206,"sha":"ggg777"}
JSON
OUT="$(R 206 "$FX")"
[ "$(jq -r '.ready' <<<"$OUT")" = "false" ] && ok "ready=false" || bad "t6.ready" "got $(jq -r '.ready' <<<"$OUT")"
[ "$(jq -r '.reason' <<<"$OUT")" = "closed-underneath" ] && ok "reason=closed-underneath" || bad "t6.reason" "got $(jq -r '.reason' <<<"$OUT")"
[ "$(jq -r '.state' <<<"$OUT")" = "MERGED" ] && ok "state=MERGED surfaced" || bad "t6.state" "got $(jq -r '.state' <<<"$OUT")"

# ── test 6b: CLOSED underneath (same closed-underneath verdict) ──────────
echo "--- test 6b: CLOSED underneath -> ready false closed-underneath ---"
FX="$TMP/t6b"; seed "$FX"
cat > "$FX/reattach-pr-216.json" <<'JSON'
{"state":"CLOSED","mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","headRefOid":"h16"}
JSON
OUT="$(R 216 "$FX")"
[ "$(jq -r '.reason' <<<"$OUT")" = "closed-underneath" ] && ok "reason=closed-underneath (CLOSED)" || bad "t6b.reason" "got $(jq -r '.reason' <<<"$OUT")"

# ── test 7: conflict (CONFLICTING; CI must NOT be polled) ────────────────
echo "--- test 7: OPEN/CONFLICTING -> ready false conflict, no CI poll ---"
FX="$TMP/t7"; seed "$FX"
cat > "$FX/reattach-pr-207.json" <<'JSON'
{"state":"OPEN","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","headRefOid":"hhh888"}
JSON
# Deliberately DO NOT seed ci-poll-207.json — if the impl wrongly polled, the
# DRY_RUN ci-poll fallback would still yield NO_CI, so instead assert the reason
# is the conflict escalation (precedence step 2 wins before any CI poll).
OUT="$(R 207 "$FX")"
[ "$(jq -r '.ready' <<<"$OUT")" = "false" ] && ok "ready=false" || bad "t7.ready" "got $(jq -r '.ready' <<<"$OUT")"
[ "$(jq -r '.reason' <<<"$OUT")" = "conflict" ] && ok "reason=conflict" || bad "t7.reason" "got $(jq -r '.reason' <<<"$OUT")"
[ "$(jq -r '.mergeable' <<<"$OUT")" = "CONFLICTING" ] && ok "mergeable=CONFLICTING surfaced" || bad "t7.mergeable" "got $(jq -r '.mergeable' <<<"$OUT")"

# ── test 7b: DIRTY-only merge state (mergeable UNKNOWN) -> conflict ──────
echo "--- test 7b: OPEN/UNKNOWN mergeable but DIRTY merge state -> conflict ---"
FX="$TMP/t7b"; seed "$FX"
cat > "$FX/reattach-pr-217.json" <<'JSON'
{"state":"OPEN","mergeable":"UNKNOWN","mergeStateStatus":"DIRTY","headRefOid":"h17"}
JSON
OUT="$(R 217 "$FX")"
[ "$(jq -r '.reason' <<<"$OUT")" = "conflict" ] && ok "reason=conflict (DIRTY)" || bad "t7b.reason" "got $(jq -r '.reason' <<<"$OUT")"

# ── activation proof: reattach --help exits 0, prints usage ─────────────
echo "--- activation proof: reattach --help ---"
if bash "$CLI" reattach --help >/dev/null 2>&1; then
  ok "reattach --help exits 0"
else
  bad "help.exit" "reattach --help exited non-zero"
fi
HELPOUT="$(bash "$CLI" reattach --help 2>&1 || true)"
printf '%s' "$HELPOUT" | grep -qi 'reattach' && ok "reattach --help prints reattach usage" || bad "help.text" "no 'reattach' in output"

# ── missing args -> usage + non-zero ────────────────────────────────────
echo "--- reattach missing args -> non-zero usage error ---"
if bash "$CLI" reattach >/dev/null 2>&1; then
  bad "noargs.exit" "reattach with no args exited 0 (expected non-zero)"
else
  ok "reattach with no args exits non-zero"
fi
if bash "$CLI" reattach acme/widgets >/dev/null 2>&1; then
  bad "oneargs.exit" "reattach with one arg exited 0 (expected non-zero)"
else
  ok "reattach with one arg exits non-zero"
fi
# a non-numeric PR is rejected
if bash "$CLI" reattach acme/widgets notanumber --dry-run --fixture "$TMP/t1" >/dev/null 2>&1; then
  bad "badpr.exit" "reattach with non-numeric PR exited 0 (expected non-zero)"
else
  ok "reattach with non-numeric PR exits non-zero"
fi

# ── summary ────────────────────────────────────────────────────────────────
echo
echo "issue-state reattach tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
