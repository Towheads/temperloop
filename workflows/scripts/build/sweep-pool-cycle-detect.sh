#!/usr/bin/env bash
#
# sweep-pool-cycle-detect.sh — the deterministic pool-level edge-graph walk
# for /sweep's blocked_by-aware chunk formation (temperloop#1835, epic #1847
# Produces #2: "The pool build walks the pooled items' edge graph; a cycle
# is surfaced (none of its members driven)").
#
# A single item's own un-defer predicate (sweep-blocked-undefer.sh, its
# sibling) only ever asks "is THIS blocker done yet" — it has no way to
# notice that A is blocked_by B, B is blocked_by C, and C is blocked_by A.
# Left to the per-item predicate alone, every item in a cycle would simply
# defer FOREVER, silently, every run, with nothing ever explaining why. This
# script is the pool-level check that catches that case: given the
# blocked_by EDGES restricted to items that are THEMSELVES in this run's
# pool (a cross-pool edge — the blocker isn't a pool member this run — is
# not this script's concern; the per-item predicate already handles it),
# it reports which items can NEVER be topologically resolved from the
# edges given, i.e. belong to (or are irrecoverably blocked behind) a cycle.
#
# ALGORITHM: standard Kahn's-algorithm topological sort. Repeatedly remove
# pool items with no remaining pooled blocker; whatever is left when no more
# removals are possible is the cyclic frontier. A note on precision: the
# leftover set can include an item that is not ITSELF part of a loop but
# depends (directly or transitively) on one — e.g. D -> blocked_by -> A
# where A/B/C form a genuine 3-cycle. Such an item can equally never be
# driven from this pool's edges alone, so folding it into the same reported
# set (rather than computing a stricter strongly-connected-components split)
# is a deliberate simplification: the report's job is "which items will
# never un-defer from this edge set", not a graph-theory decomposition.
#
# THIN WRAPPER (L0-a, epic #1910): the walk itself is
# workflows/scripts/lib/graph.sh's `levels` subcommand (the same Kahn's-
# algorithm level partition plan.sh's toposort now shares). This script's
# own job is translating {"item","blocked_by"} pairs into the shared
# edge-list shape (from=blocked_by, to=item — the blocker must precede the
# item it blocks) and flattening graph.sh's level-partitioned answer back
# into this command's own flat `order`/`cyclic` grammar: graph.sh's partial
# `levels` (whatever resolved before a cycle stalled the walk, in the CYCLE
# case) concatenate into `order` in the same level-by-level sequence Kahn's
# algorithm produced them, and its `cycle` remainder becomes `cyclic`
# unchanged.
#
# No live reads at all — pure graph combinatorics over the edges the caller
# supplies (already filtered to intra-pool blocker relationships via
# board_blocked_by_open). Independently testable with synthetic fixtures.
# See workflows/scripts/build/tests/test_sweep_pool_cycle_detect.sh.
#
# Usage:
#   sweep-pool-cycle-detect.sh <edges-json-file>
#   cat edges.json | sweep-pool-cycle-detect.sh -
#
# Input JSON shape:
#   {
#     "edges": [
#       {"item": 10, "blocked_by": 20},   # issue #10 is blocked_by #20,
#       ...                                # AND #20 is itself a pool member
#     ]
#   }
#
# Output JSON on stdout:
#   {
#     "order": [<issue#>, ...],    # pool items resolvable in topological
#                                   # order (their blockers all clear first)
#     "cyclic": [<issue#>, ...]    # pool items that can never be removed —
#                                   # a genuine cycle, or downstream of one
#   }

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sweep-pool-cycle-detect.sh <edges-json-file>
       cat edges.json | sweep-pool-cycle-detect.sh -

Walks the pooled items' blocked_by edge graph (intra-pool edges only) and
reports which items resolve in topological order vs. which can never be
removed (a cycle, or transitively blocked behind one). Prints a verdict
JSON object to stdout. See this script's own header for the input/output
shape and the algorithm.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ $# -eq 0 ]; then
  usage
  exit 0
fi

INPUT="$1"
if [ "$INPUT" = "-" ]; then
  EDGES_JSON="$(cat)"
else
  [ -f "$INPUT" ] || { echo "sweep-pool-cycle-detect.sh: no such file: $INPUT" >&2; exit 1; }
  EDGES_JSON="$(cat "$INPUT")"
fi

command -v jq >/dev/null 2>&1 || { echo "sweep-pool-cycle-detect.sh: jq required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_SH="$SCRIPT_DIR/../lib/graph.sh"

# {"item":X,"blocked_by":Y} -> the shared edge-list shape's {"from":Y,"to":X}
# (Y, the blocker, must precede X, the item it blocks) — graph.sh's `levels`
# in-degree-0 convention.
EDGES_INPUT="$(printf '%s' "$EDGES_JSON" | jq -c '
  { edges: [ (.edges // [])[] | {from: (.blocked_by|tostring), to: (.item|tostring), type: "blocked_by"} ] }
')"

GRAPH_OUT="$(printf '%s' "$EDGES_INPUT" | bash "$GRAPH_SH" levels - || true)"

printf '%s' "$GRAPH_OUT" | jq -c '
  # Flatten graph.sh'"'"'s level partition (success: .levels; a stalled walk:
  # .levels holds whatever resolved before the CYCLE) into one flat `order`,
  # each level already sorted by graph.sh, concatenated in level sequence —
  # the exact `order` this command has always produced. The item/blocked_by
  # ids were stringified to build the edge list; cast back to numbers here
  # since every fixture and caller of this script deals in issue numbers.
  (.levels // []) as $levels
  | { order: ($levels | flatten | map(tonumber)),
      cyclic: ((.cycle // []) | map(tonumber) | sort) }
'
