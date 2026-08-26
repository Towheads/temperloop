#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/sweep-pool-cycle-detect.sh — the
# deterministic pool-level blocked_by edge-graph walk for /sweep's
# blocked_by-aware chunk formation (temperloop#1835, epic #1847 Produces
# #2: "The pool build walks the pooled items' edge graph; a cycle is
# surfaced (none of its members driven)").
#
# Entirely OFFLINE: synthetic edge-set JSON fixtures, zero `gh`/board reads.
#
# Covers:
#   1. no edges at all -> empty order, empty cyclic (a pool with no
#      blocked_by relationships is fully resolvable, trivially).
#   2. a linear chain (no cycle) -> every item lands in `order`, none in
#      `cyclic`, and the topological order actually respects the edges
#      (a blocker is removed before its dependent).
#   3. a genuine 3-cycle (A blocked_by B blocked_by C blocked_by A) -> ALL
#      THREE land in `cyclic`, none in `order` — none of the cycle's
#      members are ever driven.
#   4. a cycle plus a downstream item that depends on a cycle member (but
#      does not itself loop) -> the downstream item also lands in `cyclic`
#      (it can never resolve either), and a SEPARATE, unrelated item with
#      no edge to the cycle still resolves normally into `order`.
#   5. --help / -h / no-args activation proof.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../sweep-pool-cycle-detect.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }
[ -x "$CLI" ] || { echo "FATAL: sweep-pool-cycle-detect.sh not found/executable at $CLI" >&2; exit 1; }

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check_field() { # <desc> <fixture-json> <jq-field> <want>
  local desc="$1" file="$2" field="$3" want="$4"
  local out got
  out="$(bash "$CLI" "$file")"
  got="$(jq -c "$field" <<<"$out")"
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc" "want [$want], got [$got] (full: $out)"
  fi
}

# ── 1: no edges ────────────────────────────────────────────────────────
echo "--- 1: no edges at all -> empty order, empty cyclic ---"
EMPTY="$TMP/empty.json"
echo '{"edges": []}' > "$EMPTY"
check_field "no edges -> order=[]" "$EMPTY" '.order' "[]"
check_field "no edges -> cyclic=[]" "$EMPTY" '.cyclic' "[]"

# ── 2: a linear chain, no cycle ──────────────────────────────────────────
echo "--- 2: a linear chain (1 blocked_by 2 blocked_by 3) -> fully resolvable ---"
CHAIN="$TMP/chain.json"
echo '{"edges": [{"item":1,"blocked_by":2},{"item":2,"blocked_by":3}]}' > "$CHAIN"
check_field "chain -> cyclic=[]" "$CHAIN" '.cyclic' "[]"
out="$(bash "$CLI" "$CHAIN")"
order="$(jq -c '.order' <<<"$out")"
if [ "$order" = "[3,2,1]" ]; then
  ok "chain -> order=[3,2,1] (blocker removed before its dependent)"
else
  bad "chain -> topological order respects the edges" "want [3,2,1], got $order"
fi

# ── 3: a genuine 3-cycle ──────────────────────────────────────────────────
echo "--- 3: a genuine 3-cycle (10<-20<-30<-10) -> none of its members driven ---"
CYCLE="$TMP/cycle.json"
echo '{"edges": [{"item":10,"blocked_by":20},{"item":20,"blocked_by":30},{"item":30,"blocked_by":10}]}' > "$CYCLE"
check_field "3-cycle -> order=[]" "$CYCLE" '.order' "[]"
check_field "3-cycle -> cyclic=[10,20,30]" "$CYCLE" '.cyclic' "[10,20,30]"

# ── 4: a cycle plus a downstream dependent, plus an unrelated resolvable item ──
echo "--- 4: a cycle's downstream dependent also never resolves; an unrelated item still does ---"
MIXED="$TMP/mixed.json"
cat > "$MIXED" <<'JSON'
{"edges": [
  {"item":10,"blocked_by":20},
  {"item":20,"blocked_by":30},
  {"item":30,"blocked_by":10},
  {"item":40,"blocked_by":20},
  {"item":50,"blocked_by":99}
]}
JSON
check_field "mixed -> cyclic includes the cycle AND its downstream dependent (40)" "$MIXED" '.cyclic' "[10,20,30,40]"
check_field "mixed -> order includes the unrelated pair (50 resolves once its blocker 99 clears)" "$MIXED" '.order' "[99,50]"

echo "--- --help / -h / no-args activation proof ---"
bash "$CLI" --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help exits 0" "non-zero exit"
bash "$CLI" -h >/dev/null 2>&1 && ok "-h exits 0" || bad "-h exits 0" "non-zero exit"
bash "$CLI" >/dev/null 2>&1 && ok "no-args exits 0 (prints usage)" || bad "no-args exits 0" "non-zero exit"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_sweep_pool_cycle_detect: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_sweep_pool_cycle_detect: OK — all %d checks passed\n' "$pass"
