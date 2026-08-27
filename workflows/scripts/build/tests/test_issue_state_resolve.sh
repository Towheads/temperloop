#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/issue-state.sh's `resolve` subcommand
# (temperloop #635, epic #627 `/fix` targeted single-item fix driver).
#
# Entirely OFFLINE via the --dry-run --fixture harness (mirrors
# test_pipeline_tick.sh's convention): each case seeds a fixture directory
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
# And the no-fabricated-verdict cases (temperloop#1591 / #1518, epic #1626 —
# "never let a verdict disagree with its own payload, and never let an absent
# input read as a clean one"):
#  11. a NONEXISTENT issue (no fixture = the offline 404)     -> not-found
#  12. a MERGED PR number                                      -> not-an-issue
#  13. an OPEN PR number                                        -> not-an-issue
#  14. a simulated gh FAILURE that is not a 404 (auth)           -> probe-failed
#  15. a simulated gh failure that IS GitHub's 404 signature      -> not-found
#  16. a non-open, non-PR state other than `closed`                -> already-done
#
# Every one of those, plus the open/closed baselines, additionally asserts the
# CROSS-FIELD invariant via reason_agrees(): the emitted `reason` may not
# assert a lifecycle state other than the one `issue_state` reports.
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

# reason_agrees <verdict-json> — the self-contradiction guard epic #1626 is
# named for, checked MECHANICALLY rather than by eye: scan the `reason` string
# for any lifecycle-state word and fail if it names one the `issue_state` field
# does not. This is what catches the #1518 regression shape (`issue_state:
# merged` beside `reason: "open, unclaimed, no linked PR"`) directly.
reason_agrees() {
  local out="$1" st rs w
  st="$(jq -r '.issue_state' <<<"$out")"
  rs="$(jq -r '.reason' <<<"$out")"
  for w in open closed merged absent unknown; do
    if [ "$w" != "$st" ] && grep -qiE "(^|[^a-z])$w([^a-z]|\$)" <<<"$rs"; then
      echo "reason '$rs' asserts '$w' but issue_state is '$st'" >&2
      return 1
    fi
  done
  return 0
}

# agree <label> <verdict-json> — reason_agrees as a pass/fail assertion.
agree() {
  if reason_agrees "$2" 2>/dev/null; then
    ok "$1: reason agrees with issue_state"
  else
    bad "$1.agree" "$(reason_agrees "$2" 2>&1 >/dev/null || true)"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

seed() { mkdir -p "$1"; }

# ── test 1: clean-open -> fresh ──────────────────────────────────────────
echo "--- test 1: clean-open, unclaimed, no linked PR -> fresh ---"
FX="$TMP/t1"; seed "$FX"
cat > "$FX/issue-101.json" <<'JSON'
{"state":"OPEN","labels":[],"assignees":[],"url":"https://github.com/acme/widgets/issues/101"}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 101 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "fresh" ] && ok "route=fresh" || bad "t1.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq -r '.is_pull_request' <<<"$OUT")" = "false" ] && ok "is_pull_request=false (an /issues/ url)" || bad "t1.is_pr" "got $(jq -r '.is_pull_request' <<<"$OUT")"
agree "t1" "$OUT"
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

# ── 5c: a :manual claim read back by the SAME session-id-less run -> by_me
# (temperloop#1823 regression: the hand-rolled derivation left cur_stamp empty
# with no $CLAUDE_CODE_SESSION_ID, so a manual run's own `<host>:manual` claim
# read by_me=false / claimed-elsewhere. board_own_stamp handles the :manual arm.)
echo "--- test 5c: claimed under this run's own <host>:manual stamp -> not claimed-elsewhere ---"
FX="$TMP/t5c"; seed "$FX"
cat > "$FX/issue-116.json" <<'JSON'
{"state":"OPEN","labels":[{"name":"fnd:status:in-progress"},{"name":"fnd:host/session:thishost:manual"}],"assignees":[]}
JSON
OUT="$(SUBSET_HOST_LABEL=thishost CLAUDE_CODE_SESSION_ID= \
  bash "$CLI" resolve acme/widgets 116 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" != "claimed-elsewhere" ] && ok "route != claimed-elsewhere (got $(jq -r '.route' <<<"$OUT"))" || bad "t5c.route" "wrongly claimed-elsewhere"
[ "$(jq -r '.claim.by_me' <<<"$OUT")" = "true" ] && ok "claim.by_me=true (manual stamp)" || bad "t5c.by_me" "got $(jq -r '.claim.by_me' <<<"$OUT")"

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
agree "t8" "$OUT"

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

# ── test 11: NONEXISTENT issue -> not-found, NEVER fresh/open ───────────
# temperloop#1591: `gh issue view` 404'd, the failure was swallowed into `{}`,
# and `.state // "OPEN"` invented an open issue -> route:fresh. A consumer
# would then claim-first and drive a target that does not exist. Offline, an
# ABSENT fixture is that same 404.
echo "--- test 11: nonexistent issue -> not-found (never a fabricated open/fresh) ---"
FX="$TMP/t11"; seed "$FX"   # deliberately EMPTY: no issue-1710.json
OUT="$(bash "$CLI" resolve acme/widgets 1710 --dry-run --fixture "$FX" 2>/dev/null)"
[ "$(jq -r '.route' <<<"$OUT")" = "not-found" ] && ok "route=not-found" || bad "t11.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq -r '.route' <<<"$OUT")" != "fresh" ] && ok "route is NOT fresh" || bad "t11.notfresh" "fabricated a drive route for a nonexistent issue"
[ "$(jq -r '.issue_state' <<<"$OUT")" = "absent" ] && ok "issue_state=absent" || bad "t11.state" "got $(jq -r '.issue_state' <<<"$OUT")"
[ "$(jq -r '.issue_state' <<<"$OUT")" != "open" ] && ok "issue_state is NOT open" || bad "t11.notopen" "fabricated issue_state=open for a nonexistent issue"
agree "t11" "$OUT"

# ── test 12: MERGED PR number -> not-an-issue, never fresh ──────────────
# temperloop#1518: `gh issue view` resolves a PR number and returns MERGED; the
# old `= "closed"` test missed it and fell through to the `fresh` default,
# emitting `issue_state: merged` beside `reason: "open, unclaimed, ..."`.
echo "--- test 12: merged PR number -> not-an-issue (terminal), reason agrees ---"
FX="$TMP/t12"; seed "$FX"
cat > "$FX/issue-1515.json" <<'JSON'
{"state":"MERGED","labels":[],"assignees":[],"url":"https://github.com/acme/widgets/pull/1515"}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 1515 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "not-an-issue" ] && ok "route=not-an-issue" || bad "t12.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq -r '.route' <<<"$OUT")" != "fresh" ] && ok "route is NOT fresh (terminal, not a drive)" || bad "t12.notfresh" "routed a merged PR as drivable work"
[ "$(jq -r '.is_pull_request' <<<"$OUT")" = "true" ] && ok "is_pull_request=true" || bad "t12.is_pr" "got $(jq -r '.is_pull_request' <<<"$OUT")"
[ "$(jq -r '.issue_state' <<<"$OUT")" = "merged" ] && ok "issue_state=merged" || bad "t12.state" "got $(jq -r '.issue_state' <<<"$OUT")"
agree "t12" "$OUT"

# ── test 12b: a MERGED payload carrying NO url still routes terminal ────
# Belt-and-suspenders: `merged` is a state only a PR can be in, so the verdict
# stays honest even for a payload (or an older fixture) with no `url` field.
echo "--- test 12b: merged state with no url -> still not-an-issue ---"
FX="$TMP/t12b"; seed "$FX"
cat > "$FX/issue-1516.json" <<'JSON'
{"state":"MERGED","labels":[],"assignees":[]}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 1516 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "not-an-issue" ] && ok "route=not-an-issue (url-less merged payload)" || bad "t12b.route" "got $(jq -r '.route' <<<"$OUT")"
agree "t12b" "$OUT"

# ── test 13: OPEN PR number -> not-an-issue, not a drive route ──────────
echo "--- test 13: open PR number -> not-an-issue (not a drive route) ---"
FX="$TMP/t13"; seed "$FX"
cat > "$FX/issue-1520.json" <<'JSON'
{"state":"OPEN","labels":[],"assignees":[],"url":"https://github.com/acme/widgets/pull/1520"}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 1520 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "not-an-issue" ] && ok "route=not-an-issue" || bad "t13.route" "got $(jq -r '.route' <<<"$OUT")"
case "$(jq -r '.route' <<<"$OUT")" in
  fresh|adopt|ambiguous) bad "t13.drive" "an open PR number returned the DRIVE route $(jq -r '.route' <<<"$OUT")" ;;
  *) ok "route is not one of the drive routes (fresh/adopt/ambiguous)" ;;
esac
[ "$(jq -r '.is_pull_request' <<<"$OUT")" = "true" ] && ok "is_pull_request=true" || bad "t13.is_pr" "got $(jq -r '.is_pull_request' <<<"$OUT")"
agree "t13" "$OUT"

# ── test 14: a gh failure that is NOT a 404 -> probe-failed ─────────────
# The second half of temperloop#1591: auth / rate-limit / network failures were
# collapsed into the SAME `{}` as a genuine 404. A transient failure must not
# read as "this issue does not exist" any more than a 404 should read as "open".
echo "--- test 14: non-404 gh failure -> probe-failed, distinguishable from a 404 ---"
FX="$TMP/t14"; seed "$FX"
printf 'error connecting to api.github.com: dial tcp: lookup api.github.com: no such host\n' > "$FX/issue-120.error"
OUT="$(bash "$CLI" resolve acme/widgets 120 --dry-run --fixture "$FX" 2>/dev/null)"
[ "$(jq -r '.route' <<<"$OUT")" = "probe-failed" ] && ok "route=probe-failed" || bad "t14.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq -r '.route' <<<"$OUT")" != "not-found" ] && ok "NOT collapsed into not-found (a transient failure is not a 404)" || bad "t14.collapse" "a network failure read as 'issue does not exist'"
[ "$(jq -r '.route' <<<"$OUT")" != "fresh" ] && ok "route is NOT fresh" || bad "t14.notfresh" "a failed probe fabricated a drive route"
[ "$(jq -r '.issue_state' <<<"$OUT")" = "unknown" ] && ok "issue_state=unknown" || bad "t14.state" "got $(jq -r '.issue_state' <<<"$OUT")"
grep -q 'no such host' <<<"$(jq -r '.reason' <<<"$OUT")" && ok "the gh diagnostic is carried in reason" || bad "t14.reason" "got $(jq -r '.reason' <<<"$OUT")"
agree "t14" "$OUT"

# 14b: the failure routes also print ONE human-readable line to stderr.
STDERR="$(bash "$CLI" resolve acme/widgets 120 --dry-run --fixture "$FX" 2>&1 >/dev/null)"
grep -q 'state probe failed' <<<"$STDERR" && ok "t14b: probe-failed prints a stderr diagnostic" || bad "t14b.stderr" "got '$STDERR'"

# 14c: an auth failure classifies the same way as the network failure.
FX="$TMP/t14c"; seed "$FX"
printf 'HTTP 401: Bad credentials (https://api.github.com/graphql)\n' > "$FX/issue-121.error"
OUT="$(bash "$CLI" resolve acme/widgets 121 --dry-run --fixture "$FX" 2>/dev/null)"
[ "$(jq -r '.route' <<<"$OUT")" = "probe-failed" ] && ok "t14c: auth failure -> probe-failed" || bad "t14c.route" "got $(jq -r '.route' <<<"$OUT")"
agree "t14c" "$OUT"

# ── test 15: GitHub's OWN 404 signature -> not-found ────────────────────
# The live stderr `gh issue view 999999` emits. Classified apart from t14's
# transient failures — that split is the whole point of the pair.
echo "--- test 15: GitHub's 'could not resolve' stderr -> not-found ---"
FX="$TMP/t15"; seed "$FX"
printf 'GraphQL: Could not resolve to an issue or pull request with the number of 999999. (repository.issue)\n' > "$FX/issue-999999.error"
OUT="$(bash "$CLI" resolve acme/widgets 999999 --dry-run --fixture "$FX" 2>/dev/null)"
[ "$(jq -r '.route' <<<"$OUT")" = "not-found" ] && ok "route=not-found" || bad "t15.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq -r '.issue_state' <<<"$OUT")" = "absent" ] && ok "issue_state=absent" || bad "t15.state" "got $(jq -r '.issue_state' <<<"$OUT")"
agree "t15" "$OUT"

# 15b: a repo-level "could not resolve" is deliberately NOT a not-found — the
# read never reached the issue, so claiming the issue doesn't exist would be
# the same fabrication in a new costume.
FX="$TMP/t15b"; seed "$FX"
printf 'GraphQL: Could not resolve to a Repository with the name '"'"'acme/nope'"'"'. (repository)\n' > "$FX/issue-1.error"
OUT="$(bash "$CLI" resolve acme/nope 1 --dry-run --fixture "$FX" 2>/dev/null)"
[ "$(jq -r '.route' <<<"$OUT")" = "probe-failed" ] && ok "t15b: unresolvable REPO -> probe-failed, not not-found" || bad "t15b.route" "got $(jq -r '.route' <<<"$OUT")"
agree "t15b" "$OUT"

# ── test 16: any other non-open state -> already-done, never fresh ──────
# The old test was `= "closed"` — one specific terminal value. Anything else
# GitHub returns must still route terminal rather than fall through to fresh.
echo "--- test 16: an unexpected non-open state -> already-done (not fresh) ---"
FX="$TMP/t16"; seed "$FX"
cat > "$FX/issue-122.json" <<'JSON'
{"state":"LOCKED","labels":[],"assignees":[],"url":"https://github.com/acme/widgets/issues/122"}
JSON
OUT="$(bash "$CLI" resolve acme/widgets 122 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "already-done" ] && ok "route=already-done" || bad "t16.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq -r '.route' <<<"$OUT")" != "fresh" ] && ok "route is NOT fresh" || bad "t16.notfresh" "an unexpected state fell through to the fresh default"
agree "t16" "$OUT"

# ── test 17: a self-claimed fresh issue does not say "unclaimed" ────────
# Same self-contradiction class as #1518, on the payload's claim half: only a
# SELF claim can reach the `fresh` arm, so the reason must not deny it.
echo "--- test 17: fresh + self-claim -> reason does not contradict claim.claimed ---"
FX="$TMP/t17"; seed "$FX"
cat > "$FX/issue-123.json" <<'JSON'
{"state":"OPEN","labels":[{"name":"fnd:host/session:thishost:aaaaaaaa"}],"assignees":[],"url":"https://github.com/acme/widgets/issues/123"}
JSON
OUT="$(SUBSET_HOST_LABEL=thishost CLAUDE_CODE_SESSION_ID=aaaaaaaa-1111-2222-3333-444444444444 \
  bash "$CLI" resolve acme/widgets 123 --dry-run --fixture "$FX")"
[ "$(jq -r '.route' <<<"$OUT")" = "fresh" ] && ok "route=fresh (self-claim is drivable)" || bad "t17.route" "got $(jq -r '.route' <<<"$OUT")"
[ "$(jq -r '.claim.claimed' <<<"$OUT")" = "true" ] && ok "claim.claimed=true" || bad "t17.claimed" "got $(jq -r '.claim.claimed' <<<"$OUT")"
if grep -q 'unclaimed' <<<"$(jq -r '.reason' <<<"$OUT")"; then
  bad "t17.reason" "reason says 'unclaimed' while claim.claimed is true: $(jq -r '.reason' <<<"$OUT")"
else
  ok "reason does not say 'unclaimed'"
fi
agree "t17" "$OUT"

# ── activation proof: resolve --help exits 0, prints usage ──────────────
echo "--- activation proof: resolve --help ---"
if bash "$CLI" resolve --help >/dev/null 2>&1; then
  ok "resolve --help exits 0"
else
  bad "help.exit" "resolve --help exited non-zero"
fi
HELPOUT="$(bash "$CLI" resolve --help 2>&1 || true)"
grep -qi 'resolve' <<<"$HELPOUT" && ok "resolve --help prints resolve usage" || bad "help.text" "no 'resolve' in output"

# ── top-level --help / -h / no-args ──────────────────────────────────────
echo "--- top-level dispatch: --help / -h / no-args ---"
if bash "$CLI" --help >/dev/null 2>&1; then ok "--help exits 0"; else bad "top.help" "--help exited non-zero"; fi
if bash "$CLI" -h >/dev/null 2>&1; then ok "-h exits 0"; else bad "top.h" "-h exited non-zero"; fi
if bash "$CLI" >/dev/null 2>&1; then bad "top.noargs" "no-args exited 0 (expected non-zero usage error)"; else ok "no-args exits non-zero"; fi
TOPHELP="$(bash "$CLI" --help 2>&1 || true)"
grep -qi 'resolve' <<<"$TOPHELP" && grep -qi 'reattach' <<<"$TOPHELP" \
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
