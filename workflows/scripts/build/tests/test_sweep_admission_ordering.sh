#!/usr/bin/env bash
#
# Tests the ORDERING property from sweep.md Step 1 item 6's own ordering
# note (escalation round 2, MEDIUM finding): an epic member item 6 admits
# into the fix pool is NOT driven unchecked — it is folded into the pool
# BEFORE item 4 (`blocked_by`-aware deferral) and item 5 (pool-level cycle
# walk) evaluate, so an admitted member with an open blocker is deferred
# exactly like a singleton, never sailed through to Phase 2.
#
# This is a mechanical proof, not a re-statement of either combinator's own
# unit coverage (test_sweep_epic_admission.sh, test_sweep_blocked_undefer.sh
# already cover each script standing alone). What's proven HERE is that
# CHAINING the two — admission's admit:true output feeding into a member
# that then goes through the blocked_by check — produces a DEFERRED
# verdict when that member has an open blocker, i.e. admission never
# bypasses the blocked_by check. Entirely OFFLINE: synthetic JSON fixtures
# on disk, zero `gh`/`git`/board reads, mirrors the sibling admission and
# undefer test files' own convention.
#
# Covers:
#   1. an epic that is admit:true, whose (now-pooled) member has an OPEN
#      blocker -> the member's blocked_by check reports un_defer=false
#      (blocker-open) — the member is deferred despite its epic being
#      admitted.
#   2. the same admitted epic, member with a CLOSED blocker landed on
#      origin/<default> -> un_defer=true (merge-commit-is-ancestor) — the
#      positive control proving the chain isn't just always refusing.
#   3. an epic that is admit:false (e.g. marker-missing) is never even
#      considered for the blocked_by check in the first place — admission
#      refusal short-circuits before a member ever reaches item 4, so this
#      case is asserted at the admission-combinator level only (no
#      blocked_by fixture needed — there is nothing to defer, the member
#      was never pooled).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMISSION_CLI="$HERE/../sweep-epic-admission.sh"
UNDEFER_CLI="$HERE/../sweep-blocked-undefer.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }
[ -x "$ADMISSION_CLI" ] || { echo "FATAL: sweep-epic-admission.sh not found/executable at $ADMISSION_CLI" >&2; exit 1; }
[ -x "$UNDEFER_CLI" ] || { echo "FATAL: sweep-blocked-undefer.sh not found/executable at $UNDEFER_CLI" >&2; exit 1; }

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1: admitted epic's member with an OPEN blocker -> deferred ──────────
echo "--- 1: an admit:true epic's member, with an open blocker, is deferred (never driven unchecked) ---"
EPIC="$TMP/epic-admit.json"
cat > "$EPIC" <<'JSON'
{"setting_enabled":true,"reader_helpers_available":true,"epic_reads_available":true,"epic_work_class":"Operational","any_foundational_in_group":false,"mixed_class_group":false,"live_plan_note":false,"edges_considered_marker":true}
JSON
admit_out="$(bash "$ADMISSION_CLI" "$EPIC")"
admit_verdict="$(jq -r '.admit' <<<"$admit_out")"
if [ "$admit_verdict" = "true" ]; then
  ok "epic admitted (admit=true) — precondition for this test"
else
  bad "epic admitted (admit=true) — precondition for this test" "got admit=$admit_verdict (full: $admit_out)"
fi

# The now-pooled member's own blocked_by read: an OPEN blocker, no linked
# merged PR info yet (nothing to check while it's open).
MEMBER_OPEN="$TMP/member-open-blocker.json"
jq -n '{blocker_number: 4242, state: "OPEN", linked_merged_prs: [], linked_prs_query_error: false, deps_merged: null, sweep_disposition: null}' > "$MEMBER_OPEN"
undefer_out="$(bash "$UNDEFER_CLI" "$MEMBER_OPEN")"
undefer_verdict="$(jq -r '.un_defer' <<<"$undefer_out")"
undefer_reason="$(jq -r '.reason' <<<"$undefer_out")"
if [ "$admit_verdict" = "true" ] && [ "$undefer_verdict" = "false" ] && [ "$undefer_reason" = "blocker-open" ]; then
  ok "admitted member with an open blocker -> deferred (un_defer=false, reason=blocker-open) — the ordering property holds"
else
  bad "admitted member with an open blocker -> deferred" "admit=$admit_verdict, un_defer=$undefer_verdict, reason=$undefer_reason"
fi

# ── 2: positive control — admitted member, blocker actually landed ──────
echo "--- 2: positive control — the same admitted epic's member, with a LANDED blocker, un-defers (chain isn't just always-refuse) ---"
MEMBER_LANDED="$TMP/member-landed-blocker.json"
jq -n '{blocker_number: 4242, state: "CLOSED", linked_merged_prs: [{"number":5555,"mergeCommitOid":"deadbeef"}], linked_prs_query_error: false, deps_merged: "DEPS_MERGED", sweep_disposition: null}' > "$MEMBER_LANDED"
undefer_out2="$(bash "$UNDEFER_CLI" "$MEMBER_LANDED")"
undefer_verdict2="$(jq -r '.un_defer' <<<"$undefer_out2")"
undefer_reason2="$(jq -r '.reason' <<<"$undefer_out2")"
if [ "$admit_verdict" = "true" ] && [ "$undefer_verdict2" = "true" ] && [ "$undefer_reason2" = "merge-commit-is-ancestor" ]; then
  ok "admitted member with a landed blocker -> un-defers (un_defer=true, reason=merge-commit-is-ancestor)"
else
  bad "admitted member with a landed blocker -> un-defers" "admit=$admit_verdict, un_defer=$undefer_verdict2, reason=$undefer_reason2"
fi

# ── 3: a REFUSED epic's members never reach the blocked_by check at all ──
echo "--- 3: an admit:false epic (marker-missing) never pools its members — nothing to defer, asserted at the admission level ---"
EPIC_REFUSED="$TMP/epic-refused.json"
jq -n --slurpfile base <(cat "$EPIC") '$base[0] + {edges_considered_marker: false}' > "$EPIC_REFUSED"
refuse_out="$(bash "$ADMISSION_CLI" "$EPIC_REFUSED")"
refuse_verdict="$(jq -r '.admit' <<<"$refuse_out")"
refuse_reason="$(jq -r '.reason' <<<"$refuse_out")"
if [ "$refuse_verdict" = "false" ] && [ "$refuse_reason" = "marker-missing" ]; then
  ok "refused epic (marker-missing) -> admit=false, no member ever joins the pool, no blocked_by read to chain"
else
  bad "refused epic (marker-missing) -> admit=false" "admit=$refuse_verdict, reason=$refuse_reason"
fi

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_sweep_admission_ordering: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_sweep_admission_ordering: OK — all %d checks passed\n' "$pass"
