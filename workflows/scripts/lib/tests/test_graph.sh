#!/usr/bin/env bash
#
# test_graph.sh — fixture tests for workflows/scripts/lib/graph.sh, the
# shared graph-traversal library (L0-a, epic Towheads/temperloop#1910):
# `levels` (Kahn's-algorithm level partition), `cycle` (targeted BFS
# reachability, path-returning), `reachable` (plain BFS). Entirely offline —
# synthetic edge-list JSON fixtures, zero network, zero `gh`/board reads.
#
# Covers (the five fixtures the item names, each against `levels`, plus the
# `cycle`/`reachable` subcommands and CLI usage-error activation):
#   1. a diamond (no cycle) — every node lands in `levels`, in the right
#      partition, none in `cycle`.
#   2. a genuine cycle — no nodes resolve; `cycle` names every stuck node,
#      non-zero exit.
#   3. a self-loop — a lone node blocked by itself never reaches in-degree
#      0; reported exactly like any other cycle.
#   4. isolated nodes — nodes with NO edges at all resolve trivially into
#      level 0 (this is `nodes` declared but never appearing in an edge —
#      the one case an edge-only node set could never reveal).
#   5. an empty graph — no nodes, no edges: `{"levels":[]}`, zero exit.
#   6. `cycle`: a direct hit, a transitive hit, no path, and a diamond that
#      must terminate (visited-dedup) rather than loop forever.
#   7. `reachable`: the full downstream set from a node, and an isolated
#      node's empty reachable set.
#   8. CLI usage-error activation: no args, an unknown subcommand, a missing
#      --from/--to, a missing input file — all a non-zero usage exit (2),
#      never a graph answer.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH="$HERE/../graph.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }
[ -f "$GRAPH" ] || { echo "FATAL: graph.sh not found at $GRAPH" >&2; exit 1; }

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

run_levels() { # <json> -> sets OUT, RC
  set +e
  OUT="$(printf '%s' "$1" | bash "$GRAPH" levels - 2>/dev/null)"
  RC=$?
  set -e
}

run_cycle() { # <json> <from> <to> -> sets OUT, RC
  set +e
  OUT="$(printf '%s' "$1" | bash "$GRAPH" cycle - --from "$2" --to "$3" 2>/dev/null)"
  RC=$?
  set -e
}

run_reachable() { # <json> <from> -> sets OUT, RC
  set +e
  OUT="$(printf '%s' "$1" | bash "$GRAPH" reachable - --from "$2" 2>/dev/null)"
  RC=$?
  set -e
}

# ── 1: a diamond — a -> {b,c} -> d ────────────────────────────────────────
echo "--- 1: a diamond (a precedes b and c, both precede d) -> 3 levels, no cycle ---"
DIAMOND='{"nodes":["a","b","c","d"],"edges":[{"from":"a","to":"b"},{"from":"a","to":"c"},{"from":"b","to":"d"},{"from":"c","to":"d"}]}'
run_levels "$DIAMOND"
[ "$RC" -eq 0 ] && ok "diamond -> exit 0" || bad "diamond -> exit 0" "got rc=$RC (out: $OUT)"
[ "$(jq -c '.levels' <<<"$OUT")" = '[["a"],["b","c"],["d"]]' ] \
  && ok "diamond -> levels=[[a],[b,c],[d]]" \
  || bad "diamond -> levels partition" "got: $OUT"
[ "$(jq -r '.outcome // "none"' <<<"$OUT")" = "none" ] && ok "diamond -> no outcome/cycle field" \
  || bad "diamond -> no outcome field" "got: $OUT"

# ── 2: a genuine cycle — x -> y -> x ──────────────────────────────────────
echo "--- 2: a genuine 2-node cycle (x -> y -> x) -> nothing resolves ---"
CYCLE='{"edges":[{"from":"x","to":"y"},{"from":"y","to":"x"}]}'
run_levels "$CYCLE"
[ "$RC" -ne 0 ] && ok "cycle -> non-zero exit" || bad "cycle -> non-zero exit" "got rc=0 (out: $OUT)"
[ "$(jq -r '.outcome' <<<"$OUT")" = "CYCLE" ] && ok "cycle -> outcome=CYCLE" || bad "cycle -> outcome" "got: $OUT"
[ "$(jq -c '.levels' <<<"$OUT")" = '[]' ] && ok "cycle -> no level resolved" || bad "cycle -> levels=[]" "got: $OUT"
[ "$(jq -c '.cycle' <<<"$OUT")" = '["x","y"]' ] && ok "cycle -> cycle=[x,y]" || bad "cycle -> cycle field" "got: $OUT"

# ── 3: a self-loop — a lone node blocked by itself ────────────────────────
echo "--- 3: a self-loop (s -> s) -> s never reaches in-degree 0 ---"
SELFLOOP='{"nodes":["s"],"edges":[{"from":"s","to":"s"}]}'
run_levels "$SELFLOOP"
[ "$RC" -ne 0 ] && ok "self-loop -> non-zero exit" || bad "self-loop -> non-zero exit" "got rc=0 (out: $OUT)"
[ "$(jq -r '.outcome' <<<"$OUT")" = "CYCLE" ] && [ "$(jq -c '.cycle' <<<"$OUT")" = '["s"]' ] \
  && ok "self-loop -> CYCLE naming the lone stuck node" \
  || bad "self-loop -> CYCLE {cycle:[s]}" "got: $OUT"

# ── 4: isolated nodes — declared, zero edges ──────────────────────────────
echo "--- 4: isolated nodes (no edges at all) -> all resolve into level 0 ---"
ISOLATED='{"nodes":["p","q","r"],"edges":[]}'
run_levels "$ISOLATED"
[ "$RC" -eq 0 ] && ok "isolated nodes -> exit 0" || bad "isolated nodes -> exit 0" "got rc=$RC (out: $OUT)"
[ "$(jq -c '.levels' <<<"$OUT")" = '[["p","q","r"]]' ] \
  && ok "isolated nodes -> one level holding all three" \
  || bad "isolated nodes -> levels=[[p,q,r]]" "got: $OUT"

# ── 5: an empty graph — no nodes, no edges ────────────────────────────────
echo "--- 5: an empty graph -> levels=[], zero exit ---"
run_levels '{}'
[ "$RC" -eq 0 ] && ok "empty graph -> exit 0" || bad "empty graph -> exit 0" "got rc=$RC (out: $OUT)"
[ "$(jq -c '.levels' <<<"$OUT")" = '[]' ] && ok "empty graph -> levels=[]" || bad "empty graph -> levels=[]" "got: $OUT"
run_levels '{"nodes":[],"edges":[]}'
[ "$RC" -eq 0 ] && [ "$(jq -c '.levels' <<<"$OUT")" = '[]' ] \
  && ok "empty graph (explicit empty nodes/edges) -> levels=[]" \
  || bad "empty graph (explicit) -> levels=[]" "got: $OUT"

# ── 6: `cycle` — targeted BFS reachability, path-returning ───────────────
echo "--- 6: cycle subcommand — direct hit, transitive hit, no path, diamond termination ---"
run_cycle '{"edges":[{"from":"5","to":"10"}]}' 5 10
[ "$RC" -eq 0 ] && [ "$(jq -c '.path' <<<"$OUT")" = '["5","10"]' ] \
  && ok "cycle: a direct edge -> path=[5,10]" \
  || bad "cycle: direct hit" "got rc=$RC out=$OUT"

run_cycle '{"edges":[{"from":"5","to":"7"},{"from":"7","to":"10"}]}' 5 10
[ "$RC" -eq 0 ] && [ "$(jq -c '.path' <<<"$OUT")" = '["5","7","10"]' ] \
  && ok "cycle: a transitive chain -> full path" \
  || bad "cycle: transitive hit" "got rc=$RC out=$OUT"

run_cycle '{"edges":[{"from":"5","to":"3"}]}' 5 10
[ "$RC" -eq 0 ] && [ "$(jq -c '.path' <<<"$OUT")" = '[]' ] \
  && ok "cycle: no path -> empty path, still exit 0 (an answer, not an error)" \
  || bad "cycle: no path" "got rc=$RC out=$OUT"

run_cycle '{"edges":[{"from":"5","to":"7"},{"from":"5","to":"8"},{"from":"7","to":"3"},{"from":"8","to":"3"}]}' 5 10
[ "$RC" -eq 0 ] && [ "$(jq -c '.path' <<<"$OUT")" = '[]' ] \
  && ok "cycle: a diamond terminates (visited-dedup) and reports no path" \
  || bad "cycle: diamond termination" "got rc=$RC out=$OUT"

# ── 7: `reachable` — plain BFS, no target ─────────────────────────────────
echo "--- 7: reachable subcommand ---"
run_reachable '{"edges":[{"from":"5","to":"7"},{"from":"5","to":"8"},{"from":"7","to":"3"},{"from":"8","to":"3"}]}' 5
[ "$RC" -eq 0 ] && [ "$(jq -c '.reachable' <<<"$OUT")" = '["3","7","8"]' ] \
  && ok "reachable: the full downstream set from 5" \
  || bad "reachable: downstream set" "got rc=$RC out=$OUT"

run_reachable '{"nodes":["z"],"edges":[]}' z
[ "$RC" -eq 0 ] && [ "$(jq -c '.reachable' <<<"$OUT")" = '[]' ] \
  && ok "reachable: an isolated node reaches nothing" \
  || bad "reachable: isolated node" "got rc=$RC out=$OUT"

# ── 8: CLI usage-error activation — never a graph answer on bad input ────
echo "--- 8: usage errors (rc 2, no JSON on stdout) ---"
cli() { set +e; CLI_OUT="$(bash "$GRAPH" "$@" 2>/tmp/graph_test_stderr.$$)"; CLI_RC=$?; CLI_ERR="$(cat /tmp/graph_test_stderr.$$)"; rm -f /tmp/graph_test_stderr.$$; set -e; }

cli
[ "$CLI_RC" -eq 2 ] && [ -z "$CLI_OUT" ] && ok "no args -> usage (rc 2), no stdout JSON" \
  || bad "no args" "rc=$CLI_RC out=[$CLI_OUT]"

cli bogus -
[ "$CLI_RC" -eq 2 ] && ok "unknown subcommand -> usage (rc 2)" || bad "unknown subcommand" "rc=$CLI_RC err=$CLI_ERR"

cli cycle - --from 1
[ "$CLI_RC" -eq 2 ] && ok "cycle missing --to -> usage (rc 2)" || bad "cycle missing --to" "rc=$CLI_RC"

cli reachable -
[ "$CLI_RC" -eq 2 ] && ok "reachable missing --from -> usage (rc 2)" || bad "reachable missing --from" "rc=$CLI_RC"

cli levels /no/such/file.json
[ "$CLI_RC" -eq 2 ] && ok "levels on a missing file -> usage/error exit (rc 2)" || bad "levels missing file" "rc=$CLI_RC"

cli --help
[ "$CLI_RC" -eq 0 ] && ok "--help -> exit 0" || bad "--help" "rc=$CLI_RC"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_graph: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_graph: OK — all %d checks passed\n' "$pass"
