#!/usr/bin/env bash
#
# Tests for board.sh's cross-process TTL read cache (GH #396, GH #93). The cache
# spares the Projects-v2 GraphQL point budget on repeated board reads — the burst
# that re-drained the budget was an orchestrated command (/triage, /build)
# re-resolving the board in a SEPARATE bash process per step (GH #93). It must:
#   1. default ON (TTL=90) so board_resolve across processes pays one fetch, not N;
#      and honor an explicit TTL=0 opt-out for a caller that must read live;
#   2. serve a fresh-enough on-disk copy WITHOUT a gh call;
#   3. re-fetch (and refresh the store) once the entry is older than the TTL;
#   4. key per board, so board 4 never serves board 3's page;
#   5. keep board_create_many's index-wait retry live (_board_item_list_fresh);
#   6. let board_resolve reuse a warm item-list across resolves;
#   7. INVALIDATE on every write, so a read-after-write sees fresh state even in
#      a later process (the correctness guarantee that lets the cache default ON);
#   8. fail LOUD — a rate-limited/empty live read returns non-zero and caches
#      nothing, instead of poisoning the cache or leaving accessors on null.
#
# Replays the `_board_gh` seam like test_board_replay.sh — no network, no PATH
# shim. Each item-list read is counted so we can assert cache HITS issue zero calls.
#
# The `_board_gh` overrides below are invoked indirectly (the library calls
# `_board_gh`, which this test redefines) and some are redefined mid-file to mimic
# a drained budget — so shellcheck's "never invoked" / "unreachable command"
# checks are false positives for them. Disabled file-wide, like test_board_replay.sh.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"
FIX="$HERE/fixtures"

# Isolated cache dir so we never read/write a real /tmp board cache.
BOARD_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/board-cache-test-XXXXXX")"
export BOARD_CACHE_DIR

CALLS="$(mktemp "${TMPDIR:-/tmp}/board-cache-calls-XXXXXX")"
cleanup() { rm -rf "$BOARD_CACHE_DIR" "$CALLS"; }
trap cleanup EXIT

# shellcheck source=scripts/lib/board.sh
source "$LIB_DIR/board.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Count item-list calls; replay the canned pages for reads. item-edit / item-add
# (the mutators) fall through to the no-op default — board_set_status etc. only
# check the call's exit code, not its output.
_board_gh() {
  case "$1 $2" in
    "project item-list") echo "item-list" >>"$CALLS"; cat "$FIX/item_list.json" ;;
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    *) : ;;
  esac
}
# grep -c always prints the count (0 included); `|| true` only swallows its
# exit-1-on-zero-matches so `set -e` doesn't trip.
calls() { grep -c '^item-list$' "$CALLS" 2>/dev/null || true; }
# Clean slate: clear the call log and any cached pages.
reset() { : >"$CALLS"; rm -f "$BOARD_CACHE_DIR"/subset-board-*.json; }

# --- 1. default ON: unset TTL caches (the GH #93 cross-process default) ----
reset
unset BOARD_CACHE_TTL || true
board_item_list 3 >/dev/null
board_item_list 3 >/dev/null
[ "$(calls)" -eq 1 ] || fail "default (unset TTL) should cache: 2nd read a hit (got $(calls), want 1)"
[ -f "$BOARD_CACHE_DIR/subset-board-3-items.json" ] || fail "default should write a cache file"

# --- 1b. explicit TTL=0 opt-out: every call hits gh, nothing is cached -----
reset
BOARD_CACHE_TTL=0 board_item_list 3 >/dev/null
BOARD_CACHE_TTL=0 board_item_list 3 >/dev/null
[ "$(calls)" -eq 2 ] || fail "TTL=0 should disable cache (got $(calls), want 2)"
[ ! -f "$BOARD_CACHE_DIR/subset-board-3-items.json" ] || fail "TTL=0 must not write a cache file"

# --- 2. enabled: second read is a HIT (zero gh calls), same content -------
reset
export BOARD_CACHE_TTL=90
out1="$(board_item_list 3)"
out2="$(board_item_list 3)"
[ "$(calls)" -eq 1 ] || fail "fresh cache: 2nd read should be a hit (got $(calls) gh calls, want 1)"
[ "$out1" = "$out2" ] || fail "cached read returned different content than the live read"
[ -f "$BOARD_CACHE_DIR/subset-board-3-items.json" ] || fail "cache file not written"

# --- 3. expiry: an old entry forces a re-fetch ----------------------------
# Backdate the cache file well past the TTL; next read must hit gh again.
touch -t 200001010000 "$BOARD_CACHE_DIR/subset-board-3-items.json"
: >"$CALLS"
board_item_list 3 >/dev/null
[ "$(calls)" -eq 1 ] || fail "expired cache should re-fetch (got $(calls) gh calls, want 1)"

# --- 4. per-board keying: board 4 does not serve board 3's page -----------
: >"$CALLS"
board_item_list 4 >/dev/null
[ "$(calls)" -eq 1 ] || fail "a different board must miss and fetch its own page"
[ -f "$BOARD_CACHE_DIR/subset-board-4-items.json" ] || fail "board 4 cache file not written"

# --- 4b. per-QUERY keying: the escape hatch keys its OWN slot (GH #168 review) -
# A non-default BOARD_ITEM_QUERY reads a DIFFERENT dataset (e.g. BOARD_ITEM_QUERY=""
# fetches ALL items incl. Done), so it must not share the default active-set slot —
# else a full-board read would be served the filtered page (or vice versa) within
# the TTL. Default warms `items`; the empty-query read must MISS and write its own.
reset
export BOARD_CACHE_TTL=90
board_item_list 3 >/dev/null                       # default query -> warms `items`
: >"$CALLS"
BOARD_ITEM_QUERY='' board_item_list 3 >/dev/null   # full-board read -> own slot, must MISS
[ "$(calls)" -eq 1 ] || fail "empty-query read must not hit the default slot (got $(calls), want 1)"
[ -f "$BOARD_CACHE_DIR/subset-board-3-items-.json" ] || fail "empty-query must write its own cache slot"
unset BOARD_ITEM_QUERY || true

# --- 5. mutating retry stays live: _board_item_list_fresh bypasses --------
# board_create_many's index-wait retry must read fresh (it calls
# _board_item_list_fresh, not board_item_list). board 3's cache is warm, so a
# cache-aware read would be a zero-call hit — prove the fresh internal hits gh.
board_item_list 3 >/dev/null          # confirm warm: this is a hit
: >"$CALLS"
[ "$(calls)" -eq 0 ] || fail "setup: board 3 cache should be warm (a hit, 0 calls)"
_board_item_list_fresh 3 >/dev/null   # must still hit gh despite warm cache
[ "$(calls)" -eq 1 ] || fail "_board_item_list_fresh must bypass the cache (got $(calls), want 1)"

# --- 6. board_resolve reuses a warm item-list across resolves (GH #93) -----
# The core fix: two board_resolve calls (each simulating a fresh command step)
# share ONE item-list fetch.
reset
board_resolve 3 >/dev/null            # cold: one item-list fetch (+ view/field-list, uncounted)
board_resolve 3 >/dev/null            # warm: item-list served from cache
[ "$(calls)" -eq 1 ] || fail "board_resolve should reuse the cached item-list (got $(calls), want 1)"

# --- 7. write-patch read-after-write: a single-item write keeps the page WARM and CORRECT (GH #157) --
# Before #157 every mutator busted the whole items page, so the next read re-paged
# the heavy item-list even for a one-field change. Now a single-item write splices
# the new value into the cached page in place: the page stays warm (file present)
# AND the next read sees the new value with ZERO item-list calls.
reset
board_resolve 3 >/dev/null            # warms cache; sets BOARD_CURRENT=3 + BOARD_FIELDS_JSON
[ -f "$BOARD_CACHE_DIR/subset-board-3-items.json" ] || fail "setup: resolve should have cached"
board_set_status PVTI_item227 Done >/dev/null   # item-id-only write PATCHES via BOARD_CURRENT
[ -f "$BOARD_CACHE_DIR/subset-board-3-items.json" ] || fail "a single-item write must keep the items page warm (patched, not busted)"
: >"$CALLS"
board_resolve 3 >/dev/null            # read-after-write: served from the patched cache
[ "$(calls)" -eq 0 ] || fail "read-after-write must be a cache HIT, zero item-list calls (got $(calls), want 0)"
[ "$(board_item_id 227)" = "PVTI_item227" ] || fail "patched item still resolvable by id (got '$(board_item_id 227)')"
# board_add_to_board (an add, not a single-item field edit) still busts the page:
board_resolve 4 >/dev/null
[ -f "$BOARD_CACHE_DIR/subset-board-4-items.json" ] || fail "setup: resolve 4 should have cached"
board_add_to_board 4 "https://example.test/issues/1" >/dev/null
[ ! -f "$BOARD_CACHE_DIR/subset-board-4-items.json" ] || fail "board_add_to_board must invalidate its board's cache"

# --- 8. fail-loud: a rate-limited / empty read returns non-zero, no cache --
# Override the seam to mimic a drained budget (non-zero) and an empty page.
reset
_board_gh() { return 1; }                              # every call fails
if board_item_list 3 >/dev/null 2>&1; then fail "a failed live read must return non-zero"; fi
[ ! -f "$BOARD_CACHE_DIR/subset-board-3-items.json" ] || fail "a failed read must not write a cache file"
_board_gh() { return 0; }                              # exit 0 but empty stdout
if board_item_list 3 >/dev/null 2>&1; then fail "an empty live read must return non-zero"; fi
[ ! -f "$BOARD_CACHE_DIR/subset-board-3-items.json" ] || fail "an empty read must not be cached"

# --- 9. board_resolve_item serves project view + field-list from cache (GH #141) --
# The "cheap" single-item path (claim / status-move) used to re-fetch project-view
# AND field-list LIVE on every call — the dominant drain in the #141 attribution log
# for a long-lived session firing many single-item ops. They are board STRUCTURE
# (invariant under item edits), so they now come from the shared cache; only the
# one-issue query stays live. Count each subcommand separately to prove it.
_board_gh() {
  case "$1 $2" in
    "project item-list")  echo "item-list" >>"$CALLS"; cat "$FIX/item_list.json" ;;
    "project view")       echo "view"      >>"$CALLS"; cat "$FIX/project_view.json" ;;
    "project field-list") echo "fieldlist" >>"$CALLS"; cat "$FIX/field_list.json" ;;
    "api graphql")        echo "graphql"   >>"$CALLS"; cat "$FIX/issue_project_item.json" ;;
    *) : ;;
  esac
}
cnt() { grep -c "^$1\$" "$CALLS" 2>/dev/null || true; }
reset
export BOARD_CACHE_TTL=90
board_resolve_item 3 227 >/dev/null   # cold: view + field-list fetched, one-issue query live
board_resolve_item 3 227 >/dev/null   # warm: view + field-list from cache, query still live
[ "$(cnt view)" -eq 1 ]      || fail "board_resolve_item must cache project-view (got $(cnt view) fetches across 2 calls, want 1)"
[ "$(cnt fieldlist)" -eq 1 ] || fail "board_resolve_item must cache field-list (got $(cnt fieldlist), want 1)"
[ "$(cnt graphql)" -eq 2 ]   || fail "the single-issue query must stay LIVE every call (got $(cnt graphql), want 2)"
[ "$(board_item_id 227)" = "PVTI_item227" ] || fail "resolved item still usable by accessors (got '$(board_item_id 227)')"

# --- 10. structure/state TTL split: each class honors its OWN ttl --------------
# The drain fix: project-view + field-list (board STRUCTURE — invariant, never
# mutator-busted) cache under BOARD_STRUCTURE_TTL, independent of the short item
# ttl. Caching structure on the 90s item clock re-paid view+field-list every step
# of a long session (56% of board GraphQL). Reuses test #9's counting _board_gh + cnt.
# 10a — items aged past their ttl, structure still fresh: items re-fetch, structure holds.
# Backdate ONLY the items page (the real-world case: a session step >90s after the
# last resolve); structure files stay fresh, well within BOARD_STRUCTURE_TTL.
reset
export BOARD_CACHE_TTL=90 BOARD_STRUCTURE_TTL=86400
board_resolve 3 >/dev/null                  # warm all three classes
touch -t 200001010000 "$BOARD_CACHE_DIR/subset-board-3-items.json"   # expire ONLY items
: >"$CALLS"
board_resolve 3 >/dev/null
[ "$(cnt item-list)" -eq 1 ] || fail "split: stale items must re-fetch while structure holds (got $(cnt item-list), want 1)"
[ "$(cnt view)" -eq 0 ]      || fail "split: fresh structure must stay cached past the item ttl (view $(cnt view), want 0)"
[ "$(cnt fieldlist)" -eq 0 ] || fail "split: fresh structure must stay cached past the item ttl (fieldlist $(cnt fieldlist), want 0)"

# 10b — structure ttl=0 opt-out: structure re-fetches every resolve, items stay warm.
reset
export BOARD_CACHE_TTL=90
BOARD_STRUCTURE_TTL=0 board_resolve 3 >/dev/null
: >"$CALLS"
BOARD_STRUCTURE_TTL=0 board_resolve 3 >/dev/null
[ "$(cnt view)" -eq 1 ]      || fail "structure ttl=0 must re-fetch project-view each resolve (got $(cnt view), want 1)"
[ "$(cnt fieldlist)" -eq 1 ] || fail "structure ttl=0 must re-fetch field-list each resolve (got $(cnt fieldlist), want 1)"
[ "$(cnt item-list)" -eq 0 ] || fail "structure ttl=0 must not disturb the warm item cache (got $(cnt item-list), want 0)"

# 10c — master off-switch: BOARD_CACHE_TTL=0 forces structure live too (back-compat).
# Callers that set BOARD_CACHE_TTL=0 to force fully-live reads (e.g. test_board_replay)
# must still get live structure — the long structure ttl never overrides the kill switch.
reset
BOARD_CACHE_TTL=0 board_resolve 3 >/dev/null
: >"$CALLS"
BOARD_CACHE_TTL=0 board_resolve 3 >/dev/null
[ "$(cnt view)" -eq 1 ]      || fail "BOARD_CACHE_TTL=0 must force project-view live too (got $(cnt view), want 1)"
[ "$(cnt fieldlist)" -eq 1 ] || fail "BOARD_CACHE_TTL=0 must force field-list live too (got $(cnt fieldlist), want 1)"

# --- 11. board_bust_structure drops ONLY structure, not the items page ---------
reset
export BOARD_CACHE_TTL=90 BOARD_STRUCTURE_TTL=86400
board_resolve 3 >/dev/null                 # warms structure + items
board_bust_structure 3
: >"$CALLS"
board_resolve 3 >/dev/null
[ "$(cnt view)" -eq 1 ]      || fail "board_bust_structure must force a project-view re-fetch (got $(cnt view), want 1)"
[ "$(cnt fieldlist)" -eq 1 ] || fail "board_bust_structure must force a field-list re-fetch (got $(cnt fieldlist), want 1)"
[ "$(cnt item-list)" -eq 0 ] || fail "board_bust_structure must NOT bust the items page (got $(cnt item-list), want 0)"

# --- 12. SAFETY: a stale structure cache missing an option fails LOUD, never mis-writes --
# This is the property that makes the long structure ttl safe: writes resolve the
# field/option id by NAME from the cached schema, so a stale cache can only be
# MISSING a newly-added option — never hold a WRONG id for an existing one. A write
# to an absent option must fail (non-zero) WITHOUT issuing an item-edit, which the
# unbusted items cache proves (board_set_status busts only on a successful edit).
reset
export BOARD_CACHE_TTL=90 BOARD_STRUCTURE_TTL=86400
board_resolve 3 >/dev/null                  # warms structure (schema) + items
[ -f "$BOARD_CACHE_DIR/subset-board-3-items.json" ] || fail "setup: resolve should cache items"
if board_set_status PVTI_item227 NoSuchStatus >/dev/null 2>&1; then
  fail "safety: a status absent from the (stale) structure cache must fail, not edit"
fi
[ -f "$BOARD_CACHE_DIR/subset-board-3-items.json" ] || fail "safety: a refused write must NOT bust the items cache (no edit ran)"

# --- 13. write-patch SHAPE: the spliced value matches gh item-list's flattened form (GH #157) --
# A zero-call test alone can't catch a wrong key (e.g. `Status` instead of the
# lowercased `status`) — that would silently leave the OLD value under the real key
# and break board_item_id-adjacent reads. So inspect the patched items JSON on disk
# directly: each single-item mutator must write the value under the SAME flattened
# key board_resolve_item produces (single-select->lowercased `status`/`component`,
# text->`host/Session`, number->`seq`), value = the option NAME / text / number.
# Reuses the fixture-replaying _board_gh from #9 (warms the cache from item_list.json).
ITEMS="$BOARD_CACHE_DIR/subset-board-3-items.json"
item_val() { jq -r --arg k "$1" '.items[] | select(.id=="PVTI_item227") | .[$k]' "$ITEMS"; }

# 13a — board_set_status: single-select -> lowercased `status`, value = option NAME.
reset
export BOARD_CACHE_TTL=90 BOARD_STRUCTURE_TTL=86400
board_resolve 3 >/dev/null
board_set_status PVTI_item227 Done >/dev/null
[ -f "$ITEMS" ]                  || fail "13a: status write must keep the patched page warm"
[ "$(item_val status)" = "Done" ] || fail "13a: status must be patched under lowercased 'status' = option name (got '$(item_val status)')"
[ "$(jq -r '.items[]|select(.id=="PVTI_item227")|has("Status")' "$ITEMS")" = "false" ] \
  || fail "13a: must NOT write the wrong capitalized key 'Status' (would break board_item_id-adjacent reads)"

# 13b — board_set_component: single-select -> lowercased `component`, value = option NAME.
reset
board_resolve 3 >/dev/null
board_set_component PVTI_item227 Ingest >/dev/null
[ "$(item_val component)" = "Ingest" ] || fail "13b: component must be patched under lowercased 'component' (got '$(item_val component)')"

# 13c — board_stamp: text -> flattened key keeps verbatim case after first letter (host/Session).
reset
board_resolve 3 >/dev/null
board_stamp PVTI_item227 "Host/Session" "hostZ:deadbeef" >/dev/null
[ "$(item_val "host/Session")" = "hostZ:deadbeef" ] || fail "13c: text must be patched under 'host/Session' (got '$(item_val "host/Session")')"

# 13d — board_set_number: number -> lowercased `seq`, value stored as a JSON NUMBER.
reset
board_resolve 3 >/dev/null
board_set_number PVTI_item227 Seq 42 >/dev/null
[ "$(item_val seq)" = "42" ] || fail "13d: seq must be patched under lowercased 'seq' (got '$(item_val seq)')"
[ "$(jq -r '.items[]|select(.id=="PVTI_item227")|.seq|type' "$ITEMS")" = "number" ] \
  || fail "13d: seq must be a JSON number, not a string (matching gh item-list)"

# 13e — fallback: a write whose item is ABSENT from the cached page busts (no silent miss).
reset
board_resolve 3 >/dev/null
[ -f "$ITEMS" ] || fail "13e: setup should cache"
board_set_status PVTI_notInCache Done >/dev/null   # id not present in item_list.json
[ ! -f "$ITEMS" ] || fail "13e: a write to an item absent from the cache must fall back to a whole-page bust"

# 13f — fallback: a stale cached page is busted, not patched (avoids serving stale siblings).
reset
board_resolve 3 >/dev/null
touch -t 200001010000 "$ITEMS"        # backdate past the item ttl
board_set_status PVTI_item227 Done >/dev/null
[ ! -f "$ITEMS" ] || fail "13f: a stale items page must be busted on write, not patched in place"

# --- 14. pre-flight GraphQL budget guard before the heavy whole-board read (GH #156) --
# board_resolve pre-checks `gh api rate_limit` (a REST call, separate bucket) BEFORE
# the heavy item-list LIVE fetch and, on a near-empty GraphQL budget, emits a legible
# stderr warning naming remaining budget + reset time — turning a silent drain into an
# early signal instead of a downstream empty-JSON failure. Opt-in hard-abort behind
# BOARD_BUDGET_GUARD=1; warn-only by default; threshold 0 disables it; the single-item
# path never calls it; and any rate_limit read failure degrades gracefully (proceeds).
#
# Stub `gh api rate_limit` through the SAME `_board_gh` seam, alongside the fixture
# replays the rest of board_resolve needs. RL_REMAINING / RL_RESET drive the stub.
RL_REMAINING=5000
RL_RESET="$(( $(date +%s) + 720 ))"   # ~12m out, so the "resets in Nm" hint renders
_board_gh() {
  case "$1 $2" in
    "api rate_limit")
      # Mimic `gh api rate_limit --jq '.resources.graphql.remaining, .resources.graphql.reset'`
      printf '%s\n%s\n' "$RL_REMAINING" "$RL_RESET" ;;
    "project item-list")  echo "item-list" >>"$CALLS"; cat "$FIX/item_list.json" ;;
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    "api graphql")        cat "$FIX/issue_project_item.json" ;;
    *) : ;;
  esac
}

# 14a — warn path: low budget on a cache MISS warns to stderr and STILL proceeds
# (default is warn-only; the resolve completes and the items page resolves).
reset
export BOARD_CACHE_TTL=90
unset BOARD_BUDGET_GUARD || true
RL_REMAINING=40
warn_err="$(board_resolve 3 2>&1 >/dev/null)" || fail "14a: warn path must NOT abort (default warn-only)"
case "$warn_err" in
  *"graphql 40/5000"*"resets in"*"may fail"*) : ;;
  *) fail "14a: low budget must warn naming remaining + reset (got: '$warn_err')" ;;
esac
[ "$(board_item_id 227)" = "PVTI_item227" ] || fail "14a: resolve must still complete after a warn"

# 14b — abort path: BOARD_BUDGET_GUARD=1 + low budget returns NON-ZERO before the read.
reset
RL_REMAINING=40
: >"$CALLS"
if BOARD_BUDGET_GUARD=1 board_resolve 3 >/dev/null 2>&1; then
  fail "14b: BOARD_BUDGET_GUARD=1 on a near-empty budget must hard-abort (non-zero)"
fi
[ "$(calls)" -eq 0 ] || fail "14b: abort must happen BEFORE the heavy item-list read (got $(calls) item-list calls, want 0)"

# 14c — healthy budget: no warning, no abort, resolve proceeds silently.
reset
RL_REMAINING=5000
healthy_err="$(BOARD_BUDGET_GUARD=1 board_resolve 3 2>&1 >/dev/null)" || fail "14c: healthy budget must not abort"
[ -z "$healthy_err" ] || fail "14c: a healthy budget must emit no warning (got: '$healthy_err')"

# 14d — warm-cache HIT skips the guard entirely (no GraphQL read is about to happen).
# Warm the cache with a healthy budget, then drop to a low budget + abort flag: a
# subsequent resolve served from cache must NOT abort, because no heavy read occurs.
reset
RL_REMAINING=5000
board_resolve 3 >/dev/null            # warm the items cache
RL_REMAINING=40
BOARD_BUDGET_GUARD=1 board_resolve 3 >/dev/null 2>&1 || fail "14d: a warm-cache hit must skip the guard (no heavy read), even at BOARD_BUDGET_GUARD=1"

# 14e — opt-out: BOARD_BUDGET_GUARD_THRESHOLD=0 disables the guard (no warn, no abort).
reset
RL_REMAINING=40
optout_err="$(BOARD_BUDGET_GUARD=1 BOARD_BUDGET_GUARD_THRESHOLD=0 board_resolve 3 2>&1 >/dev/null)" \
  || fail "14e: threshold=0 must disable the guard (no abort even with BOARD_BUDGET_GUARD=1)"
[ -z "$optout_err" ] || fail "14e: threshold=0 must emit no warning (got: '$optout_err')"

# 14f — the single-item path NEVER calls the guard: board_resolve_item must not abort
# even with a near-empty budget + the abort flag set (a claim never pays the guard).
reset
RL_REMAINING=40
BOARD_BUDGET_GUARD=1 board_resolve_item 3 227 >/dev/null 2>&1 \
  || fail "14f: board_resolve_item must NOT trigger the budget guard (claim path stays guard-free)"

# 14g — graceful degrade: a rate_limit read FAILURE must not break board_resolve.
reset
RL_REMAINING=40
_board_gh() {
  case "$1 $2" in
    "api rate_limit")     return 1 ;;   # simulate a network/parse failure
    "project item-list")  echo "item-list" >>"$CALLS"; cat "$FIX/item_list.json" ;;
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    *) : ;;
  esac
}
BOARD_BUDGET_GUARD=1 board_resolve 3 >/dev/null 2>&1 \
  || fail "14g: a failed rate_limit read must degrade gracefully (proceed), never abort the resolve"
[ "$(board_item_id 227)" = "PVTI_item227" ] || fail "14g: resolve must complete despite a guard read failure"

# --- 15. control chars in a body don't corrupt the cache (#354) ---------------
# gh can emit a literal control byte inside an issue body, making the raw item-list
# response invalid JSON. board_item_list strips these on its read-OUTPUT, but the
# cache FILE used to keep the raw bytes — so _board_cache_patch_field's jq ran
# DIRECTLY on the invalid file, failed, and busted the page, leaving board_item_id
# silently empty for items after the offending one (#354). The fix sanitizes at
# cache-WRITE, so the file is always valid JSON for every direct consumer.
reset
export BOARD_CACHE_TTL=90
ctrl=$'\001'   # an unescaped U+0001 — the kind of byte gh leaks inside a body
_board_gh() {
  case "$1 $2" in
    "project item-list") echo "item-list" >>"$CALLS"
      printf '{"items":[{"id":"PVTI_ctrl","content":{"number":901,"title":"bad%sbody","type":"Issue"},"status":"Backlog"}],"totalCount":1}' "$ctrl" ;;
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    *) : ;;
  esac
}
board_item_list 4 >/dev/null
jq -e . "$BOARD_CACHE_DIR/subset-board-4-items.json" >/dev/null 2>&1 \
  || fail "15: cache file must be valid JSON even when the raw page carries a control char (#354)"
board_resolve 4 >/dev/null
[ "$(board_item_id 901)" = "PVTI_ctrl" ] \
  || fail "15: item with a control-char body still resolves by id (got '$(board_item_id 901)') (#354)"
# A single-item write must PATCH the page in place — not fail on jq and bust it —
# AND return exit 0 even though _board_cache_patch_field's jq runs against a
# control-char page (the symptom-#2 guard of #614: board_set_status must not
# propagate a cache-patch non-zero when the GraphQL edit itself succeeded).
if board_set_status PVTI_ctrl Done >/dev/null; then :; else
  fail "15: board_set_status must exit 0 on a control-char page (cache-patch non-fatal) (#614/#354)"
fi
[ -f "$BOARD_CACHE_DIR/subset-board-4-items.json" ] \
  || fail "15: a single-item write must keep the page warm, not bust on control chars (#354)"
: >"$CALLS"
board_resolve 4 >/dev/null
[ "$(calls)" -eq 0 ] \
  || fail "15: read-after-write must be a cache HIT, not a re-fetch (got $(calls), want 0) (#354)"

# --- 16. board_resolve_item SANITIZES its GraphQL response (#443) ----------
# board_resolve_item populates BOARD_ITEMS_JSON DIRECTLY from `gh api graphql |
# jq`, bypassing board_item_list's output sanitizer — the only unsanitized
# populate path (the #443 recurrence of #354). A raw control char in the queried
# issue title breaks that jq outright. Stub graphql to emit one; the populate
# must stay valid (not jq-fail, no raw control byte survives).
_board_gh() {
  case "$1 $2" in
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    "api graphql")        printf '{"data":{"repository":{"issue":{"title":"bad%sbody","projectItems":{"nodes":[]}}}}}' "$ctrl" ;;
    *) : ;;
  esac
}
reset
export BOARD_CACHE_TTL=0
board_resolve_item 3 999 >/dev/null 2>&1 \
  || fail "16: board_resolve_item must not fail on a control-char issue title (#443)"
printf '%s' "$BOARD_ITEMS_JSON" | jq -e . >/dev/null 2>&1 \
  || fail "16: BOARD_ITEMS_JSON must be valid JSON after a control-char title (#443)"
if printf '%s' "$BOARD_ITEMS_JSON" | LC_ALL=C grep -q "$ctrl"; then
  fail "16: BOARD_ITEMS_JSON must not retain the raw control char (#443)"
fi

# --- 17. cache HIT read sanitizes control chars too (#443) -----------------
# The write path sanitizes before caching, but a file dirtied by a pre-fix /
# external / partial write was served RAW on a HIT (the old `cat`). Write a
# dirty page directly; the HIT read must strip it.
reset
export BOARD_CACHE_TTL=90
printf '{"items":[{"id":"PVTI_a","content":{"title":"bad%sbody"}}]}' "$ctrl" \
  > "$BOARD_CACHE_DIR/subset-board-3-items.json"
out17="$(_board_cached_read 3 items project item-list 3)"
if printf '%s' "$out17" | LC_ALL=C grep -q "$ctrl"; then
  fail "17: cache HIT read must strip control chars (#443)"
fi
printf '%s' "$out17" | jq -e . >/dev/null 2>&1 \
  || fail "17: sanitized cache HIT must be valid JSON (#443)"

# --- 18. per-issue / per-milestone REST→jq accessors sanitize control chars (#614) ---
# board_blocked_by_open / board_parent_issue / board_active_milestones (and
# milestone.sh's milestone readers) read a USER-CONTROLLED body/description over
# REST and pipe straight to jq. They were the class #354/#443 never covered (those
# hardened only the items-page paths). A gh-leaked literal control byte broke their
# `… 2>/dev/null | jq`; the 2>/dev/null swallowed the jq error, so the function
# returned a SILENT wrong-empty answer ("not blocked" / "no parent" / "no active
# milestones") — and an empty board_active_milestones with milestones present halts
# /triage Step 1. They must sanitize before jq, like the whole-board paths.
reset
export BOARD_CACHE_TTL=0
_board_gh() {
  case "$1" in
    api)
      case "$2" in
        *dependencies/blocked_by)
          printf '[{"number":42,"state":"open","body":"blocker%sbody"}]' "$ctrl" ;;
        *milestones*state=open*)
          printf '[{"title":"alpha","description":"shareable%s<!-- triage:active -->"}]' "$ctrl" ;;
        */issues/*)
          printf '{"parent_issue_url":"https://api.github.com/repos/o/r/issues/145","body":"child%sbody"}' "$ctrl" ;;
        *) : ;;
      esac ;;
    *) : ;;
  esac
}
[ "$(board_blocked_by_open 4 901)" = "42" ] \
  || fail "18: board_blocked_by_open must return the open blocker despite a control-char body (got '$(board_blocked_by_open 4 901)') (#614)"
[ "$(board_parent_issue 4 901)" = "145" ] \
  || fail "18: board_parent_issue must resolve the parent despite a control-char body (got '$(board_parent_issue 4 901)') (#614)"
[ "$(board_active_milestones 4)" = "alpha" ] \
  || fail "18: board_active_milestones must see the active marker despite a control-char description (got '$(board_active_milestones 4)') (#614)"

echo "PASS: board cache defaults ON, reuses across board_resolve, PATCHES the items page in place on a single-item write (warm + correct, zero re-fetch) under gh item-list's flattened key shape with a safe bust fallback for absent/stale pages (GH #157), expires, keys per-board, keeps the fresh retry live, caches board_resolve_item's structure reads (GH #141), splits the structure ttl from the item ttl + board_bust_structure (structure/state split), fails loud on a drained budget (GH #396, GH #93), pre-flight budget-guards the heavy whole-board read with a legible warn / opt-in abort / opt-out / single-item-skip / graceful-degrade (GH #156), and sanitizes control chars at cache-write so a control-char body never corrupts the page (#354), and additionally on cache READ + in board_resolve_item's GraphQL populate so a dirty cache file or single-item query is served clean (#443), and sanitizes the per-issue / per-milestone REST→jq accessors (board_blocked_by_open / board_parent_issue / board_active_milestones) so a control-char body/description never yields a silent wrong-empty answer that halts /triage, with board_set_status returning exit 0 on a control-char page (#614)"
