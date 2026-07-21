#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/issue-state.sh's `resolve` subcommand
# (temperloop #635, epic #627 `/fix` targeted single-item fix driver).
#
# Entirely OFFLINE via the --dry-run --fixture harness (mirrors
# test_funnel_tick.sh's convention): each case seeds a fixture directory
# with $FIXTURE/issue-<n>.json (+ open-pr-<n>.txt / pr-<n>.json as needed)
# and asserts on the emitted route-verdict JSON. Zero network, zero `gh`.
#
# Covers the acceptance state shapes:
#   1. clean-open (unclaimed, no linked PR)              -> fresh
#   2. open with one linked PR                            -> adopt
#   3. open with one linked DRAFT PR                       -> adopt, draft:true
#   4. open with a linked PR by a foreign author            -> adopt, author surfaced
#   5. claimed under a DIFFERENT host/session               -> claimed-elsewhere
#   6. labeled needs-clarification                          -> question-first
#   7. labeled funnel-escalated + spike                     -> surfaced in labels[]
#   8. closed                                                -> already-done
#   9. ambiguous: two open linked PRs                        -> ambiguous
#
# Also: the --help / -h / no-args activation-proof contract, and the
# `resolve --help` exit-0 activation proof `/build`'s worker verifies.

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

# ── test 1: clean-open -> fresh ──────────────────────────────────────────
echo "--- test 1: clean-open, unclaimed, no linked PR -> fresh ---"
FX="$TMP/t1"; seed "$FX"
cat > "$FX/issue-101.json" <<'JSON'
{"state":"OPEN","labels":[],"assignees":[]}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 101 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "fresh" ] && ok "route=fresh" || bad "t1.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq -r '.issue_state' <<<"$OUT")" = "open" ] && ok "issue_state=open" || bad "t1.issue_state" "got $(jq -r '.issue_state' <<<"$OUT")"
[ "$(jq '.open_prs|length' <<<"$OUT")" = "0" ] && ok "open_prs empty" || bad "t1.open_prs" "got $(jq -c '.open_prs' <<<"$OUT")"
[ "$(jq -r '.claim.claimed' <<<"$OUT")" = "false" ] && ok "claim.claimed=false" || bad "t1.claimed" "got $(jq -r '.claim.claimed' <<<"$OUT")"
[ "$(jq -r '.repo' <<<"$OUT")" = "acme/widgets" ] && ok "repo echoed" || bad "t1.repo" "got $(jq -r '.repo' <<<"$OUT")"
[ "$(jq -r '.issue' <<<"$OUT")" = "101" ] && ok "issue echoed" || bad "t1.issue" "got $(jq -r '.issue' <<<"$OUT")"

# ── test 2: one linked open PR -> adopt ──────────────────────────────────
echo "--- test 2: one open linked PR -> adopt ---"
FX="$TMP/t2"; seed "$FX"
cat > "$FX/issue-102.json" <<'JSON'
{"state":"OPEN","labels":[],"assignees":[]}
JSON
printf '55\n' > "$FX/open-pr-102.txt"
cat > "$FX/pr-55.json" <<'JSON'
{"number":55,"draft":false,"author":{"login":"alice"},"updatedAt":"2026-07-10T00:00:00Z"}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 102 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "adopt" ] && ok "route=adopt" || bad "t2.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq '.open_prs|length' <<<"$OUT")" = "1" ] && ok "one open PR surfaced" || bad "t2.count" "got $(jq -c '.open_prs' <<<"$OUT")"
[ "$(jq -r '.open_prs[0].number' <<<"$OUT")" = "55" ] && ok "PR #55 surfaced" || bad "t2.number" "got $(jq -r '.open_prs[0].number' <<<"$OUT")"
[ "$(jq -r '.open_prs[0].linkage' <<<"$OUT")" = "closes" ] && ok "linkage=closes" || bad "t2.linkage" "got $(jq -r '.open_prs[0].linkage' <<<"$OUT")"

# ── test 3: one linked DRAFT PR -> adopt, draft:true surfaced ───────────
echo "--- test 3: one open linked DRAFT PR -> adopt, draft:true ---"
FX="$TMP/t3"; seed "$FX"
cat > "$FX/issue-103.json" <<'JSON'
{"state":"OPEN","labels":[],"assignees":[]}
JSON
printf '56\n' > "$FX/open-pr-103.txt"
cat > "$FX/pr-56.json" <<'JSON'
{"number":56,"draft":true,"author":{"login":"bob"},"updatedAt":"2026-07-11T00:00:00Z"}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 103 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "adopt" ] && ok "route=adopt" || bad "t3.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq -r '.open_prs[0].draft' <<<"$OUT")" = "true" ] && ok "draft:true surfaced" || bad "t3.draft" "got $(jq -r '.open_prs[0].draft' <<<"$OUT")"

# ── test 4: linked PR by a foreign author -> adopt, author surfaced ─────
echo "--- test 4: linked PR by a foreign author -> adopt, author surfaced ---"
FX="$TMP/t4"; seed "$FX"
cat > "$FX/issue-104.json" <<'JSON'
{"state":"OPEN","labels":[],"assignees":[]}
JSON
printf '57\n' > "$FX/open-pr-104.txt"
cat > "$FX/pr-57.json" <<'JSON'
{"number":57,"draft":false,"author":{"login":"carol"},"updatedAt":"2026-07-12T00:00:00Z"}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 104 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "adopt" ] && ok "route=adopt" || bad "t4.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq -r '.open_prs[0].author' <<<"$OUT")" = "carol" ] && ok "author=carol surfaced" || bad "t4.author" "got $(jq -r '.open_prs[0].author' <<<"$OUT")"

# ── test 5: claimed under a DIFFERENT host/session -> claimed-elsewhere ─
echo "--- test 5: claimed under a different host/session -> claimed-elsewhere ---"
FX="$TMP/t5"; seed "$FX"
cat > "$FX/issue-105.json" <<'JSON'
{"state":"OPEN","labels":[{"name":"fnd:status:in-progress"},{"name":"fnd:host/session:otherhost:zzzzzzzz"}],"assignees":[]}
JSON
OUT="$(SUBSET_HOST_LABEL=thishost CLAUDE_CODE_SESSION_ID=aaaaaaaa-1111-2222-3333-444444444444 \
  bash "$CLI" resolve acme/widgets 105 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "claimed-elsewhere" ] && ok "route=claimed-elsewhere" || bad "t5.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq -r '.claim.claimed' <<<"$OUT")" = "true" ] && ok "claim.claimed=true" || bad "t5.claimed" "got $(jq -r '.claim.claimed' <<<"$OUT")"
[ "$(jq -r '.claim.by_me' <<<"$OUT")" = "false" ] && ok "claim.by_me=false" || bad "t5.by_me" "got $(jq -r '.claim.by_me' <<<"$OUT")"
[ "$(jq -r '.claim.host_session' <<<"$OUT")" = "otherhost:zzzzzzzz" ] && ok "host_session surfaced" || bad "t5.host_session" "got $(jq -r '.claim.host_session' <<<"$OUT")"

# ── 5b: same host/session (self-claim, e.g. a re-resolve) -> NOT claimed-elsewhere
echo "--- test 5b: claimed under THIS run's own host/session -> not claimed-elsewhere ---"
FX="$TMP/t5b"; seed "$FX"
cat > "$FX/issue-106.json" <<'JSON'
{"state":"OPEN","labels":[{"name":"fnd:status:in-progress"},{"name":"fnd:host/session:thishost:aaaaaaaa"}],"assignees":[]}
JSON
OUT="$(SUBSET_HOST_LABEL=thishost CLAUDE_CODE_SESSION_ID=aaaaaaaa-1111-2222-3333-444444444444 \
  bash "$CLI" resolve acme/widgets 106 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" != "claimed-elsewhere" ] && ok "route != claimed-elsewhere (got $(jq -r '.route' <<<"$OUT"))" || bad "t5b.route" "wrongly claimed-elsewhere"
[ "$(jq -r '.claim.by_me' <<<"$OUT")" = "true" ] && ok "claim.by_me=true" || bad "t5b.by_me" "got $(jq -r '.claim.by_me' <<<"$OUT")"

# ── test 6: labeled needs-clarification -> question-first ───────────────
echo "--- test 6: labeled needs-clarification -> question-first ---"
FX="$TMP/t6"; seed "$FX"
cat > "$FX/issue-107.json" <<'JSON'
{"state":"OPEN","labels":[{"name":"needs-clarification"}],"assignees":[]}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 107 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "question-first" ] && ok "route=question-first" || bad "t6.route" "got $(jq -r '.route' <<<"$OUT")"

# ── test 7: labeled funnel-escalated + spike -> surfaced in labels[] ────
echo "--- test 7: labeled funnel-escalated + spike -> surfaced in labels[] ---"
FX="$TMP/t7"; seed "$FX"
cat > "$FX/issue-108.json" <<'JSON'
{"state":"OPEN","labels":[{"name":"funnel-escalated"},{"name":"spike"}],"assignees":[]}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 108 --dry-run --fixture "$FX")"
jq -e '.labels | index("funnel-escalated") != null' <<<"$OUT" >/dev/null \
  && ok "funnel-escalated surfaced in labels[]" || bad "t7.escalated" "got $(jq -c '.labels' <<<"$OUT")"
jq -e '.labels | index("spike") != null' <<<"$OUT" >/dev/null \
  && ok "spike surfaced in labels[]" || bad "t7.spike" "got $(jq -c '.labels' <<<"$OUT")"

# ── test 8: closed -> already-done ───────────────────────────────────────
echo "--- test 8: closed -> already-done ---"
FX="$TMP/t8"; seed "$FX"
cat > "$FX/issue-109.json" <<'JSON'
{"state":"CLOSED","labels":[],"assignees":[]}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 109 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "already-done" ] && ok "route=already-done" || bad "t8.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq -r '.issue_state' <<<"$OUT")" = "closed" ] && ok "issue_state=closed" || bad "t8.issue_state" "got $(jq -r '.issue_state' <<<"$OUT")"

# ── test 9: ambiguous -- two open linked PRs -> ambiguous ───────────────
echo "--- test 9: two open linked PRs -> ambiguous (never silently take the first) ---"
FX="$TMP/t9"; seed "$FX"
cat > "$FX/issue-110.json" <<'JSON'
{"state":"OPEN","labels":[],"assignees":[]}
JSON
printf '61\n62\n' > "$FX/open-pr-110.txt"
cat > "$FX/pr-61.json" <<'JSON'
{"number":61,"draft":false,"author":{"login":"dave"},"updatedAt":"2026-07-13T00:00:00Z"}
JSON
cat > "$FX/pr-62.json" <<'JSON'
{"number":62,"draft":false,"author":{"login":"erin"},"updatedAt":"2026-07-14T00:00:00Z"}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 110 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "ambiguous" ] && ok "route=ambiguous" || bad "t9.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq '.open_prs|length' <<<"$OUT")" = "2" ] && ok "both PRs surfaced" || bad "t9.count" "got $(jq -c '.open_prs' <<<"$OUT")"

# ── test 10: funnel-merge-pending label, no PR found -> adopt ───────────
echo "--- test 10: funnel-merge-pending label (no PR found by the probe) -> adopt ---"
FX="$TMP/t10"; seed "$FX"
cat > "$FX/issue-111.json" <<'JSON'
{"state":"OPEN","labels":[{"name":"funnel-merge-pending"}],"assignees":[]}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 111 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "adopt" ] && ok "route=adopt (funnel-merge-pending)" || bad "t10.route" "got $(jq -r '.route' <<<"$OUT")"

# ── activation proof: resolve --help exits 0, prints usage ──────────────
echo "--- activation proof: resolve --help ---"
if bash "$CLI" resolve --help >/dev/null 2>&1; then
  ok "resolve --help exits 0"
else
  bad "help.exit" "resolve --help exited non-zero"
fi
HELPOUT="$(bash "$CLI" resolve --help 2>&1 || true)"
printf '%s' "$HELPOUT" | grep -qi 'resolve' && ok "resolve --help prints resolve usage" || bad "help.text" "no 'resolve' in output"

# ── top-level --help / -h / no-args ──────────────────────────────────────
echo "--- top-level dispatch: --help / -h / no-args ---"
if bash "$CLI" --help >/dev/null 2>&1; then ok "--help exits 0"; else bad "top.help" "--help exited non-zero"; fi
if bash "$CLI" -h >/dev/null 2>&1; then ok "-h exits 0"; else bad "top.h" "-h exited non-zero"; fi
if bash "$CLI" >/dev/null 2>&1; then bad "top.noargs" "no-args exited 0 (expected non-zero usage error)"; else ok "no-args exits non-zero"; fi
TOPHELP="$(bash "$CLI" --help 2>&1 || true)"
printf '%s' "$TOPHELP" | grep -qi 'resolve' && printf '%s' "$TOPHELP" | grep -qi 'reattach' \
  && ok "top-level usage lists both subcommands" || bad "top.text" "missing resolve/reattach in usage"

# ── reattach activation proof ────────────────────────────────────────────
# reattach is now IMPLEMENTED (temperloop #636) — its behavior is covered in
# depth by tests/test_issue_state_reattach.sh. Here we only assert the shared
# dispatch still routes `reattach --help` to an exit-0 usage (activation proof)
# and rejects missing args, so the resolve suite stays green after the shared
# file gained the real arm. (Offline: no live `reattach acme/widgets N`, which
# would reach ci-poll.sh over the network.)
echo "--- reattach activation proof (implemented, #636) ---"
if bash "$CLI" reattach --help >/dev/null 2>&1; then
  ok "reattach --help exits 0"
else
  bad "reattach.help" "reattach --help exited non-zero"
fi
if bash "$CLI" reattach >/dev/null 2>&1; then
  bad "reattach.noargs" "reattach with no args exited 0 (expected non-zero usage error)"
else
  ok "reattach with missing args exits non-zero"
fi

# ── summary ────────────────────────────────────────────────────────────────
echo
echo "issue-state resolve tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
