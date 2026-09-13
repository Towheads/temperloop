#!/usr/bin/env bash
#
# Tests for `state-graph.sh query <name>` — the five named queries over the
# derived state graph (temperloop#1910 L6): status-drift, stale-claims,
# unlinked-prs, orphan-worktrees, resume. Sibling of test_state_graph.sh /
# test_state_graph_local.sh, which cover the seven `_sg_read_*` SOURCES this
# file's queries read FROM — this file never re-covers those sources, it
# feeds each `_sg_query_*` a synthetic, hand-written SNAPSHOT literal
# (matching `_sg_build_snapshot`'s own schema_version/board/repo/built_at/
# sources/nodes/edges shape) directly. Every `_sg_query_*` is a PURE
# function of that one JSON string — no board/gh/git access of its own — so
# these tests need none of the seam-overriding the source-level tests do.
# Fixtures are entirely synthetic: no real host names, session ids, or paths.
#
# Covers:
#   - route-alphabet contract: the shared fixture
#     tests/fixtures/state-graph-routes.json equals (set-equality, not
#     order) workflows/scripts/config/ontology-registry.tsv's `state:route`
#     axis — the ONE enum, ONE drift check the acceptance bullet asks for.
#   - one GOLDEN (exact-JSON) fixture per query: status-drift, stale-claims,
#     unlinked-prs, orphan-worktrees, resume.
#   - resume's ranked-merge authority ordering (plan > journal > git >
#     board): one fixture per tier deciding, PLUS the invariant fixture — a
#     terminal `[x]` sentinel is never reversed even when a lower tier
#     (journal AND worktree) would suggest otherwise.
#   - every resume route emitted is a member of the shared route-alphabet
#     fixture (acceptance: "emits per-item routes drawn from the registry's
#     route alphabet").
#   - "never an empty set" — each of the five queries answers the literal
#     string "unknown" (never `[]`) when a source it depends on is
#     `error`/`stale`, one case per query (resume: one case per degradable
#     tier — journal/git/board — since its "per part" is per-tier, not
#     per-query).

set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf — mirrors the sibling
# test_state_graph.sh / test_state_graph_local.sh files exactly, even though
# this file's own assertions never touch the board/gh/git seams (sourcing
# state-graph.sh transitively sources board.sh).
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=workflows/scripts/build/state-graph.sh
source "$HERE/../state-graph.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# =============================================================================
# Route-alphabet contract fixture (temperloop#1910 L6 acceptance): ONE source,
# ONE drift check. Re-derive the registry's own state:route tokens and assert
# they equal the shared fixture's `routes` array — set-equality (sorted),
# never order-sensitive.
# =============================================================================
ROUTES_FIXTURE="$HERE/fixtures/state-graph-routes.json"
[ -f "$ROUTES_FIXTURE" ] || fail "shared route fixture missing: $ROUTES_FIXTURE"

FIXTURE_ROUTES="$(jq -c '.routes | sort' "$ROUTES_FIXTURE")"
REGISTRY_ROUTES="$(awk -F'\t' '$1=="state:route" && $2!="" {print $2}' "$ONTOLOGY_REGISTRY_FILE" \
  | jq -Rsc 'split("\n") | map(select(length>0)) | sort')"
[ "$FIXTURE_ROUTES" = "$REGISTRY_ROUTES" ] \
  || fail "route fixture drifted from ontology-registry.tsv's state:route axis (fixture: $FIXTURE_ROUTES, registry: $REGISTRY_ROUTES)"
echo "PASS: shared route fixture equals ontology-registry.tsv's state:route axis"

# route_in_alphabet <route> -> 0 iff <route> is a member of the shared fixture
route_in_alphabet() {
  jq -e --arg r "$1" '.routes | index($r) != null' "$ROUTES_FIXTURE" >/dev/null
}

# =============================================================================
# status-drift — Issue nodes whose fnd:status:* and claimed_by edge disagree
# (board source only)
# =============================================================================

# --- golden fixture -----------------------------------------------------
SNAP_STATUS_DRIFT='{
  "sources": {"board":{"status":"ok"}},
  "nodes": [
    {"type":"Issue","id":"Issue:1","number":1,"status":"fnd:status:in-progress"},
    {"type":"Issue","id":"Issue:2","number":2,"status":"fnd:status:ready"},
    {"type":"Issue","id":"Issue:3","number":3,"status":"fnd:status:in-progress"}
  ],
  "edges": [
    {"type":"claimed_by","from":"Issue:1","to":"Session:s1"},
    {"type":"claimed_by","from":"Issue:2","to":"Session:s2"}
  ]
}'
GOLDEN_STATUS_DRIFT='{"query":"status-drift","status":"ok","findings":[{"id":"Issue:3","kind":"in_progress_no_claim"},{"id":"Issue:2","kind":"claimed_not_in_progress"}]}'
out="$(_sg_query_status_drift "$SNAP_STATUS_DRIFT")"
[ "$out" = "$GOLDEN_STATUS_DRIFT" ] || fail "status-drift golden mismatch (got: $out)"
echo "PASS: status-drift golden fixture — in-progress-no-claim + claimed-not-in-progress"

# --- degraded board source -> "unknown", never [] ------------------------
for st in error stale; do
  out="$(_sg_query_status_drift "$(jq -c --arg s "$st" '.sources.board.status=$s' <<<"$SNAP_STATUS_DRIFT")")"
  [ "$(jq -r .status <<<"$out")" = "unknown" ] || fail "status-drift board=$st did not answer status:unknown (got: $out)"
  [ "$(jq -r .findings <<<"$out")" = "unknown" ] || fail "status-drift board=$st findings was not the literal string 'unknown' (got: $out)"
done
echo "PASS: status-drift answers unknown (never []) when board is error/stale"

# --- closed-issue residue (temperloop#1978): a CLOSED Issue node still
# wearing a residual fnd:status:* label surfaces as its own finding kind,
# `closed_with_status_label` — never conflated with the two OPEN-domain
# kinds above (an open in-progress issue #1 with a live claim, and #4 a
# CLOSED node carrying "fnd:status:backlog" — the #158 shape from this
# item's own day-1 soak evidence). An ordinary OPEN issue's node never
# carries a `.state` field at all (SNAP_STATUS_DRIFT above), so this is
# purely additive: the golden fixture's findings are unaffected by nodes
# that never set `.state`.
SNAP_STATUS_DRIFT_CLOSED='{
  "sources": {"board":{"status":"ok"}},
  "nodes": [
    {"type":"Issue","id":"Issue:1","number":1,"status":"fnd:status:in-progress"},
    {"type":"Issue","id":"Issue:4","number":4,"status":"fnd:status:backlog","state":"closed"}
  ],
  "edges": [
    {"type":"claimed_by","from":"Issue:1","to":"Session:s1"}
  ]
}'
GOLDEN_STATUS_DRIFT_CLOSED='{"query":"status-drift","status":"ok","findings":[{"id":"Issue:4","kind":"closed_with_status_label"}]}'
out="$(_sg_query_status_drift "$SNAP_STATUS_DRIFT_CLOSED")"
[ "$out" = "$GOLDEN_STATUS_DRIFT_CLOSED" ] || fail "status-drift closed-residue golden mismatch (got: $out)"
echo "PASS: status-drift — a closed issue still wearing an fnd:status:* label surfaces as closed_with_status_label, not conflated with the open-domain kinds"

# =============================================================================
# stale-claims — claimed_by edges naming a Session absent from the journal
# source (board + journal)
# =============================================================================

SNAP_STALE_CLAIMS='{
  "sources": {"board":{"status":"ok"},"journal":{"status":"ok"}},
  "nodes": [
    {"type":"Session","id":"Session:live1"}
  ],
  "edges": [
    {"type":"claimed_by","from":"Issue:1","to":"Session:live1"},
    {"type":"claimed_by","from":"Issue:2","to":"Session:ghost2"}
  ]
}'
GOLDEN_STALE_CLAIMS='{"query":"stale-claims","status":"ok","findings":[{"issue":"Issue:2","session":"Session:ghost2"}]}'
out="$(_sg_query_stale_claims "$SNAP_STALE_CLAIMS")"
[ "$out" = "$GOLDEN_STALE_CLAIMS" ] || fail "stale-claims golden mismatch (got: $out)"
echo "PASS: stale-claims golden fixture — a claim naming a session absent from the journal"

# --- degraded (board, then journal) -> unknown ---------------------------
out="$(_sg_query_stale_claims "$(jq -c '.sources.board.status="error"' <<<"$SNAP_STALE_CLAIMS")")"
[ "$(jq -r .status <<<"$out")" = "unknown" ] || fail "stale-claims board=error did not answer unknown (got: $out)"
[ "$(jq -r .findings <<<"$out")" = "unknown" ] || fail "stale-claims board=error findings not 'unknown' (got: $out)"
out="$(_sg_query_stale_claims "$(jq -c '.sources.journal.status="stale"' <<<"$SNAP_STALE_CLAIMS")")"
[ "$(jq -r .status <<<"$out")" = "unknown" ] || fail "stale-claims journal=stale did not answer unknown (got: $out)"
[ "$(jq -r .findings <<<"$out")" = "unknown" ] || fail "stale-claims journal=stale findings not 'unknown' (got: $out)"
echo "PASS: stale-claims answers unknown (never []) when board or journal is error/stale"

# --- journal ABSENT (temperloop#1980) -------------------------------------
# The journal is stale-claims's liveness ORACLE: "no journal files" means
# liveness cannot be established, not "nothing is live" — so an `absent`
# journal source must answer `unknown`, never a concrete findings set
# computed against an effectively-empty Session-node list (which would flag
# every live claim as stale — the #1980 bug). Live evidence: soak drift_query
# over-flagged issues #1910/#1938/#1970/#1978 as stale on a journal-absent
# read; #1978 in particular carried the SAME session that ran the soak.
SNAP_STALE_CLAIMS_ABSENT="$(jq -c '.sources.journal.status="absent"' <<<"$SNAP_STALE_CLAIMS")"
out="$(_sg_query_stale_claims "$SNAP_STALE_CLAIMS_ABSENT")"
[ "$(jq -r .status <<<"$out")" = "unknown" ] || fail "stale-claims journal=absent did not answer unknown (got: $out)"
[ "$(jq -r .findings <<<"$out")" = "unknown" ] || fail "stale-claims journal=absent findings not the literal string 'unknown' (got: $out)"
case "$(jq -r .reason <<<"$out")" in
  *journal*) ;;
  *) fail "stale-claims journal=absent reason does not name the journal source (got: $out)" ;;
esac
echo "PASS: stale-claims journal=absent answers unknown with a journal-naming reason, never a set computed against an empty session list"

# The golden fixture above (Session:live1 claiming Issue:1) already proves a
# claim stamped to an establishable-live session is excluded from stale
# findings when the journal is `ok`; re-affirm it explicitly as its own
# named case (acceptance: "a claim stamped to a session that IS establishable
# as live is not reported as stale").
out="$(_sg_query_stale_claims "$SNAP_STALE_CLAIMS")"
[ "$(jq -c '[.findings[].issue]' <<<"$out")" = '["Issue:2"]' ] || fail "stale-claims live-claim regression: Issue:1 (claimed by live1) must never appear in findings (got: $out)"
echo "PASS: stale-claims — a claim stamped to a session establishable as live (Session:live1) is not reported as stale"

# --- scoping regression: status-drift's own board=absent reading is
# UNCHANGED by the local journal-absent carve-out above (temperloop#1980
# acceptance: "_sg_degraded is NOT widened ... status-drift ... keep today's
# 'absent = nothing found' semantics"). board=absent is not error/stale, so
# status-drift must still compute a normal `ok` result, never `unknown` —
# proving `_sg_degraded` itself was never touched.
out="$(_sg_query_status_drift "$(jq -c '.sources.board.status="absent"' <<<"$SNAP_STATUS_DRIFT")")"
[ "$(jq -r .status <<<"$out")" = "ok" ] || fail "status-drift board=absent must stay 'ok' (unchanged semantics) — got: $out"
[ "$out" = "$GOLDEN_STATUS_DRIFT" ] || fail "status-drift board=absent golden mismatch — the #1980 fix must not touch status-drift (got: $out)"
echo "PASS: status-drift's board=absent ('nothing found') reading is unchanged by the stale-claims-local #1980 fix"

# =============================================================================
# unlinked-prs — open PR nodes with no closes edge (pr_list only)
# =============================================================================

SNAP_UNLINKED_PRS='{
  "sources": {"pr_list":{"status":"ok"}},
  "nodes": [
    {"type":"PR","id":"PR:10","number":10,"title":"linked"},
    {"type":"PR","id":"PR:11","number":11,"title":"unlinked"}
  ],
  "edges": [
    {"type":"closes","from":"PR:10","to":"Issue:1"}
  ]
}'
GOLDEN_UNLINKED_PRS='{"query":"unlinked-prs","status":"ok","findings":[{"id":"PR:11","number":11}]}'
out="$(_sg_query_unlinked_prs "$SNAP_UNLINKED_PRS")"
[ "$out" = "$GOLDEN_UNLINKED_PRS" ] || fail "unlinked-prs golden mismatch (got: $out)"
echo "PASS: unlinked-prs golden fixture — an open PR with no closes edge"

for st in error stale; do
  out="$(_sg_query_unlinked_prs "$(jq -c --arg s "$st" '.sources.pr_list.status=$s' <<<"$SNAP_UNLINKED_PRS")")"
  [ "$(jq -r .status <<<"$out")" = "unknown" ] || fail "unlinked-prs pr_list=$st did not answer unknown (got: $out)"
  [ "$(jq -r .findings <<<"$out")" = "unknown" ] || fail "unlinked-prs pr_list=$st findings not 'unknown' (got: $out)"
done
echo "PASS: unlinked-prs answers unknown (never []) when pr_list is error/stale"

# =============================================================================
# orphan-worktrees — Worktree nodes with no live ([~]/[m]/[>]) PlanItem of the
# same slug (worktrees + plan_notes)
# =============================================================================

SNAP_ORPHAN_WT='{
  "sources": {"worktrees":{"status":"ok"},"plan_notes":{"status":"ok"}},
  "nodes": [
    {"type":"Worktree","id":"Worktree:/x/repo.wt/live","path":"/x/repo.wt/live"},
    {"type":"Worktree","id":"Worktree:/x/repo.wt/leaked","path":"/x/repo.wt/leaked"},
    {"type":"PlanItem","id":"PlanItem:p:live","slug":"live","state":"[~]"},
    {"type":"PlanItem","id":"PlanItem:p:done","slug":"done","state":"[x]"}
  ],
  "edges": []
}'
GOLDEN_ORPHAN_WT='{"query":"orphan-worktrees","status":"ok","findings":[{"id":"Worktree:/x/repo.wt/leaked","path":"/x/repo.wt/leaked","slug":"leaked"}]}'
out="$(_sg_query_orphan_worktrees "$SNAP_ORPHAN_WT")"
[ "$out" = "$GOLDEN_ORPHAN_WT" ] || fail "orphan-worktrees golden mismatch (got: $out)"
echo "PASS: orphan-worktrees golden fixture — a worktree with no live PlanItem of its slug"

out="$(_sg_query_orphan_worktrees "$(jq -c '.sources.worktrees.status="error"' <<<"$SNAP_ORPHAN_WT")")"
[ "$(jq -r .status <<<"$out")" = "unknown" ] || fail "orphan-worktrees worktrees=error did not answer unknown (got: $out)"
[ "$(jq -r .findings <<<"$out")" = "unknown" ] || fail "orphan-worktrees worktrees=error findings not 'unknown' (got: $out)"
out="$(_sg_query_orphan_worktrees "$(jq -c '.sources.plan_notes.status="stale"' <<<"$SNAP_ORPHAN_WT")")"
[ "$(jq -r .status <<<"$out")" = "unknown" ] || fail "orphan-worktrees plan_notes=stale did not answer unknown (got: $out)"
[ "$(jq -r .findings <<<"$out")" = "unknown" ] || fail "orphan-worktrees plan_notes=stale findings not 'unknown' (got: $out)"
echo "PASS: orphan-worktrees answers unknown (never []) when worktrees or plan_notes is error/stale"

# =============================================================================
# resume — the ranked-merge authority ordering (plan > journal > git > board),
# claude/commands/build.md § Step 0.5 item 4's own table. One fixture per
# tier deciding, plus the load-bearing invariant.
# =============================================================================

_sg_route_of() { # <resume-json> <planitem-id> -> its .route
  jq -r --arg id "$2" '.items[] | select(.id==$id) | .route' <<<"$1"
}
_sg_authority_of() {
  jq -r --arg id "$2" '.items[] | select(.id==$id) | .authority' <<<"$1"
}

# --- tier 1 (plan): a terminal sentinel decides, never overridden --------
SNAP_TIER1_TERMINAL='{
  "sources": {"board":{"status":"ok"},"journal":{"status":"ok"},"worktrees":{"status":"ok"}},
  "nodes": [ {"type":"PlanItem","id":"PlanItem:p:done","slug":"done","state":"[x]"} ],
  "edges": []
}'
out="$(_sg_query_resume "$SNAP_TIER1_TERMINAL")"
[ "$(_sg_route_of "$out" PlanItem:p:done)" = "already-done" ] || fail "tier1 terminal sentinel did not decide already-done (got: $out)"
[ "$(_sg_authority_of "$out" PlanItem:p:done)" = "plan" ] || fail "tier1 terminal authority was not 'plan' (got: $out)"
echo "PASS: resume tier 1 (plan) — a terminal sentinel decides already-done"

# --- INVARIANT: a human [x]/[-] is never reversed by a lower tier --------
# Both journal (PR_OPENED for this slug) and worktrees (a matching worktree)
# would suggest live/adopt work if consulted — the terminal plan sentinel
# must win regardless.
SNAP_INVARIANT='{
  "sources": {"board":{"status":"ok"},"journal":{"status":"ok"},"worktrees":{"status":"ok"}},
  "nodes": [
    {"type":"PlanItem","id":"PlanItem:p:zeta","slug":"zeta","state":"[x]"},
    {"type":"PlanItem","id":"PlanItem:p:omega","slug":"omega","state":"[-]"},
    {"type":"Worktree","id":"Worktree:/x/repo.wt/zeta","path":"/x/repo.wt/zeta"},
    {"type":"Worktree","id":"Worktree:/x/repo.wt/omega","path":"/x/repo.wt/omega"},
    {"type":"Session","id":"Session:s1","steps":[
      {"step":"pr-open","outcome":"PR_OPENED","slug":"zeta"},
      {"step":"pr-open","outcome":"PR_OPENED","slug":"omega"}
    ]}
  ],
  "edges": []
}'
out="$(_sg_query_resume "$SNAP_INVARIANT")"
[ "$(_sg_route_of "$out" PlanItem:p:zeta)" = "already-done" ] \
  || fail "INVARIANT VIOLATED: a merged [x] item was reversed by journal/worktree evidence (got: $out)"
[ "$(_sg_authority_of "$out" PlanItem:p:zeta)" = "plan" ] || fail "invariant: authority for [x] was not 'plan' (got: $out)"
[ "$(_sg_route_of "$out" PlanItem:p:omega)" = "already-done" ] \
  || fail "INVARIANT VIOLATED: a skipped [-] item was reversed by journal/worktree evidence (got: $out)"
echo "PASS: resume invariant — a human [x]/[-] sentinel is never reversed by journal or git evidence"

# --- tier 1 (plan): a non-terminal sentinel with pr: decides adopt -------
SNAP_TIER1_PR='{
  "sources": {"board":{"status":"ok"},"journal":{"status":"ok"},"worktrees":{"status":"ok"}},
  "nodes": [ {"type":"PlanItem","id":"PlanItem:p:gamma","slug":"gamma","state":"[m]","pr":"42"} ],
  "edges": []
}'
out="$(_sg_query_resume "$SNAP_TIER1_PR")"
[ "$(_sg_route_of "$out" PlanItem:p:gamma)" = "adopt" ] || fail "tier1 pr: field did not decide adopt (got: $out)"
[ "$(_sg_authority_of "$out" PlanItem:p:gamma)" = "plan" ] || fail "tier1 pr: authority was not 'plan' (got: $out)"
echo "PASS: resume tier 1 (plan) — a recorded pr: field decides adopt"

# --- tier 1 (plan): pushed_sha: with no pr: decides fresh, before tier 2 -
# Journal is deliberately error here — if pushed_sha were NOT consulted at
# tier 1, this would fall through to the degraded-journal probe-failed path
# (tier 2) instead of the correct tier-1 fresh/plan verdict.
SNAP_TIER1_SHA='{
  "sources": {"board":{"status":"ok"},"journal":{"status":"error"},"worktrees":{"status":"ok"}},
  "nodes": [ {"type":"PlanItem","id":"PlanItem:p:theta","slug":"theta","state":"[~]","pushed_sha":"abc123"} ],
  "edges": []
}'
out="$(_sg_query_resume "$SNAP_TIER1_SHA")"
[ "$(_sg_route_of "$out" PlanItem:p:theta)" = "fresh" ] || fail "tier1 pushed_sha: (no pr:) did not decide fresh (got: $out)"
[ "$(_sg_authority_of "$out" PlanItem:p:theta)" = "plan" ] || fail "tier1 pushed_sha: authority was not 'plan' (got: $out)"
echo "PASS: resume tier 1 (plan) — a recorded pushed_sha: (no pr:) decides fresh, even with journal degraded"

# --- tier 2 (journal): a slug-tagged PR_OPENED/PUSHED step decides -------
SNAP_TIER2='{
  "sources": {"board":{"status":"ok"},"journal":{"status":"ok"},"worktrees":{"status":"ok"}},
  "nodes": [
    {"type":"PlanItem","id":"PlanItem:p:delta","slug":"delta","state":"[~]"},
    {"type":"PlanItem","id":"PlanItem:p:epsilon","slug":"epsilon","state":"[~]"},
    {"type":"Session","id":"Session:s1","steps":[
      {"step":"pr-open","outcome":"PR_OPENED","slug":"delta"},
      {"step":"push","outcome":"PUSHED","slug":"epsilon"}
    ]}
  ],
  "edges": []
}'
out="$(_sg_query_resume "$SNAP_TIER2")"
[ "$(_sg_route_of "$out" PlanItem:p:delta)" = "adopt" ] || fail "tier2 PR_OPENED did not decide adopt (got: $out)"
[ "$(_sg_authority_of "$out" PlanItem:p:delta)" = "journal" ] || fail "tier2 PR_OPENED authority was not 'journal' (got: $out)"
[ "$(_sg_route_of "$out" PlanItem:p:epsilon)" = "fresh" ] || fail "tier2 PUSHED-only did not decide fresh (got: $out)"
[ "$(_sg_authority_of "$out" PlanItem:p:epsilon)" = "journal" ] || fail "tier2 PUSHED-only authority was not 'journal' (got: $out)"
echo "PASS: resume tier 2 (journal) — a slug-tagged step outcome decides adopt/fresh"

# --- tier 3 (git): a matching linked worktree decides fresh --------------
SNAP_TIER3='{
  "sources": {"board":{"status":"ok"},"journal":{"status":"ok"},"worktrees":{"status":"ok"}},
  "nodes": [
    {"type":"PlanItem","id":"PlanItem:p:alpha","slug":"alpha","state":"[~]"},
    {"type":"Worktree","id":"Worktree:/x/repo.wt/alpha","path":"/x/repo.wt/alpha"}
  ],
  "edges": []
}'
out="$(_sg_query_resume "$SNAP_TIER3")"
[ "$(_sg_route_of "$out" PlanItem:p:alpha)" = "fresh" ] || fail "tier3 worktree match did not decide fresh (got: $out)"
[ "$(_sg_authority_of "$out" PlanItem:p:alpha)" = "git" ] || fail "tier3 authority was not 'git' (got: $out)"
echo "PASS: resume tier 3 (git) — a linked worktree of the item's slug decides fresh"

# --- tier 4 (board): the gated fallback default --------------------------
SNAP_TIER4='{
  "sources": {"board":{"status":"ok"},"journal":{"status":"ok"},"worktrees":{"status":"ok"}},
  "nodes": [ {"type":"PlanItem","id":"PlanItem:p:untouched","slug":"untouched","state":"[ ]"} ],
  "edges": []
}'
out="$(_sg_query_resume "$SNAP_TIER4")"
[ "$(_sg_route_of "$out" PlanItem:p:untouched)" = "fresh" ] || fail "tier4 fallback did not decide fresh (got: $out)"
[ "$(_sg_authority_of "$out" PlanItem:p:untouched)" = "board" ] || fail "tier4 authority was not 'board' (got: $out)"
echo "PASS: resume tier 4 (board) — an untouched item falls back to fresh, gated on board"

# --- degraded per tier: journal/git/board each answer probe-failed -------
SNAP_UNTOUCHED='{
  "sources": {"board":{"status":"ok"},"journal":{"status":"ok"},"worktrees":{"status":"ok"}},
  "nodes": [ {"type":"PlanItem","id":"PlanItem:p:u","slug":"u","state":"[ ]"} ],
  "edges": []
}'
out="$(_sg_query_resume "$(jq -c '.sources.journal.status="error"' <<<"$SNAP_UNTOUCHED")")"
[ "$(_sg_route_of "$out" PlanItem:p:u)" = "probe-failed" ] || fail "journal=error did not answer probe-failed (got: $out)"
[ "$(_sg_authority_of "$out" PlanItem:p:u)" = "journal" ] || fail "journal=error authority was not 'journal' (got: $out)"
out="$(_sg_query_resume "$(jq -c '.sources.worktrees.status="stale"' <<<"$SNAP_UNTOUCHED")")"
[ "$(_sg_route_of "$out" PlanItem:p:u)" = "probe-failed" ] || fail "worktrees=stale did not answer probe-failed (got: $out)"
[ "$(_sg_authority_of "$out" PlanItem:p:u)" = "git" ] || fail "worktrees=stale authority was not 'git' (got: $out)"
out="$(_sg_query_resume "$(jq -c '.sources.board.status="error"' <<<"$SNAP_UNTOUCHED")")"
[ "$(_sg_route_of "$out" PlanItem:p:u)" = "probe-failed" ] || fail "board=error did not answer probe-failed (got: $out)"
[ "$(_sg_authority_of "$out" PlanItem:p:u)" = "board" ] || fail "board=error authority was not 'board' (got: $out)"
echo "PASS: resume answers probe-failed (the route alphabet's alphabet-compliant 'unknown', never a bare empty result) per degraded tier — journal, git, board"

# --- every emitted route is drawn from the shared route alphabet --------
# Captured into a variable FIRST (not read straight out of a process
# substitution) so a producer failure propagates under `set -e`/pipefail
# instead of the loop silently seeing fewer (or zero) lines and passing
# vacuously.
routes="$(
  _sg_query_resume "$SNAP_INVARIANT" | jq -r '.items[].route'
  _sg_query_resume "$SNAP_TIER1_PR" | jq -r '.items[].route'
  _sg_query_resume "$SNAP_TIER1_SHA" | jq -r '.items[].route'
  _sg_query_resume "$SNAP_TIER2" | jq -r '.items[].route'
  _sg_query_resume "$SNAP_TIER3" | jq -r '.items[].route'
  _sg_query_resume "$SNAP_TIER4" | jq -r '.items[].route'
  _sg_query_resume "$(jq -c '.sources.journal.status="error"' <<<"$SNAP_UNTOUCHED")" | jq -r '.items[].route'
)"
[ -n "$routes" ] || fail "route-alphabet sweep produced no routes at all — a producer above likely failed"
while IFS= read -r r; do
  [ -n "$r" ] || continue
  route_in_alphabet "$r" || fail "resume emitted route '$r' not in the shared route-alphabet fixture"
done <<<"$routes"
echo "PASS: every route resume emits (decided and degraded alike) is a member of the shared route-alphabet fixture"

# =============================================================================
# cmd_query CLI dispatch — invoked as a real subprocess (`bash state-graph.sh
# query …`), not the sourced `_sg_query_*`/`cmd_query` functions the tests
# above call in-process. Covers: unknown query name, missing --board, and a
# persisted snapshot being read by the CLI.
#
# Zero network, verified rather than assumed: an `export -f` mock does NOT
# survive into this child — the child re-sources board.sh/state-graph.sh,
# which redefine `_board_gh`/`_sg_git`/`_sg_tmux` themselves, clobbering
# whatever the parent exported — so no case below relies on one. The two
# argument-validation cases exit before any source is touched; the
# persisted-snapshot case seeds the on-disk snapshot itself, in-process, via
# `_sg_persist_snapshot` before invoking the subprocess, so the subprocess
# only ever READS a file it never builds. This is enforced, not just
# reasoned about: every subprocess below runs with a logging-and-failing
# `gh`/`git`/`tmux` shim prepended to PATH, and the suite asserts the shim's
# canary log stays empty — a regression to a live build in any of these
# cases fails loudly instead of silently passing against real network/host
# state. (The separate in-process fallback-build test further below DOES
# need working `_board_gh`/`_sg_git`/`_sg_tmux` mocks, and gets them
# correctly because it never re-sources — it calls `cmd_query` directly in
# this already-sourced shell.)
# =============================================================================
STATE_GRAPH_BIN="$HERE/../state-graph.sh"
CLI_TMP="$(mktemp -d)"
trap 'rm -rf "$CLI_TMP"' EXIT

NETWORK_CANARY="$CLI_TMP/network-canary.log"
SHIM_BIN="$CLI_TMP/shim-bin"
mkdir -p "$SHIM_BIN"
for _shim_cmd in gh git tmux; do
  cat >"$SHIM_BIN/$_shim_cmd" <<SHIMEOF
#!/usr/bin/env bash
echo "CANARY: $_shim_cmd \$*" >>"$NETWORK_CANARY"
exit 1
SHIMEOF
  chmod +x "$SHIM_BIN/$_shim_cmd"
done
SHIM_PATH="$SHIM_BIN:$PATH"

echo "── cmd_query CLI: unknown query name exits 2 ──"
rc=0; out="$(PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" query bogus-query --board 4 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "unknown query name did not exit 2 (got rc=$rc, out: $out)"
printf '%s' "$out" | grep -F "unknown query" >/dev/null || fail "unknown query name error did not name the bad query (got: $out)"
echo "PASS: cmd_query CLI — unknown query name exits 2"

echo "── cmd_query CLI: missing --board exits 2 ──"
rc=0; out="$(PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" query resume 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "missing --board did not exit 2 (got rc=$rc, out: $out)"
echo "PASS: cmd_query CLI — missing --board exits 2"

echo "── cmd_query CLI: a persisted snapshot is read by the CLI (no live build) ──"
export CACHE_STORE_ROOT="$CLI_TMP/cache-persisted"
_sg_persist_snapshot 4 "$SNAP_TIER2" state-graph || fail "seeding the persisted snapshot for the CLI-read test failed"
rc=0; out="$(PATH="$SHIM_PATH" bash "$STATE_GRAPH_BIN" query resume --board 4)" || rc=$?
[ "$rc" -eq 0 ] || fail "CLI persisted-snapshot read did not exit 0 (got rc=$rc, out: $out)"
[ "$(jq -r '.query' <<<"$out")" = "resume" ] || fail "CLI persisted-snapshot resume payload missing query field (got: $out)"
[ "$(jq -r '.status' <<<"$out")" = "ok" ] || fail "CLI persisted-snapshot resume payload status was not ok (got: $out)"
[ "$(_sg_route_of "$out" PlanItem:p:delta)" = "adopt" ] || fail "CLI persisted-snapshot did not read the seeded fixture (route mismatch, got: $out)"
[ "$(_sg_authority_of "$out" PlanItem:p:delta)" = "journal" ] || fail "CLI persisted-snapshot did not read the seeded fixture (authority mismatch, got: $out)"
echo "PASS: cmd_query CLI — a persisted snapshot is read by the CLI and never rebuilt live"

if [ -s "$NETWORK_CANARY" ]; then
  fail "a CLI subprocess reached a real gh/git/tmux binary instead of reading the persisted snapshot or exiting on validation (canary: $(cat "$NETWORK_CANARY"))"
fi
echo "PASS: cmd_query CLI — zero network reached across all three subprocess cases (shim canary empty)"

# =============================================================================
# cmd_query's fallback live build (no persisted snapshot yet) must itself
# PERSIST, so a second `query` call on the same fresh host reads it back
# instead of paying a second live build. Run IN-PROCESS (not as a
# subprocess) so the overridable `_board_gh`/`_sg_git`/`_sg_tmux` seams stay
# in effect across two calls without a re-source clobbering them, and count
# `_board_gh` invocations to prove the SECOND call never reaches it. The
# count is a FILE, not a plain variable: `first="$(cmd_query …)"` runs
# `cmd_query` in a command-substitution SUBSHELL, so a counter incremented
# inside it never propagates back to this shell — an append-to-file survives
# the subshell boundary the same way a plain variable would not.
# =============================================================================
echo "── cmd_query in-process: a fallback live build is persisted so a second call doesn't rebuild ──"
export CACHE_STORE_ROOT="$CLI_TMP/cache-fallback"
export KNOWLEDGE_STORE_ROOT="$CLI_TMP/no-such-ks"   # plan_notes -> absent
export SPEND_TRANSCRIPT_ROOT="$CLI_TMP/no-such-tr"  # journal -> absent
GH_CALL_LOG="$CLI_TMP/gh-call.log"
: >"$GH_CALL_LOG"
_board_gh() {
  echo call >>"$GH_CALL_LOG"
  case "$1 $2" in
    "issue list") echo '[]' ;;
    "pr list") echo '[]' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_sg_git() { return 1; }
_sg_tmux() { return 1; }
first="$(cmd_query resume --board 4)"
[ "$(jq -r '.status' <<<"$first")" = "ok" ] || fail "in-process fallback build did not return an ok resume payload (got: $first)"
first_calls="$(wc -l <"$GH_CALL_LOG" | tr -d ' ')"
[ "$first_calls" -gt 0 ] || fail "in-process fallback build never called the live board source — test setup is broken"
second="$(cmd_query resume --board 4)"
second_calls="$(wc -l <"$GH_CALL_LOG" | tr -d ' ')"
[ "$second_calls" -eq "$first_calls" ] \
  || fail "second cmd_query call re-invoked the live board source instead of reading the persisted fallback snapshot (calls: $second_calls vs $first_calls)"
[ "$(jq -r '.status' <<<"$second")" = "ok" ] || fail "second cmd_query call did not return an ok resume payload (got: $second)"
unset -f _board_gh _sg_git _sg_tmux
echo "PASS: cmd_query in-process — a fallback live build is persisted, so a second call reads it instead of rebuilding"

echo "ALL PASS: test_state_graph_queries.sh"
