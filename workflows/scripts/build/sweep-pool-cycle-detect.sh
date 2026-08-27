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

printf '%s' "$EDGES_JSON" | jq -c '
  (.edges // []) as $edges
  | ( [$edges[].item] + [$edges[].blocked_by] | unique) as $nodes
  | { remaining: $nodes, edges: $edges, order: [] }
  | until(
      ( .remaining | length ) == 0
      or
      ( [ .remaining[] as $n
          | select( ([ .edges[] | select(.item == $n) ] | length) == 0 )
          | $n
        ] | length ) == 0
      ;
      ( [ .remaining[] as $n
          | select( ([ .edges[] | select(.item == $n) ] | length) == 0 )
          | $n
        ] ) as $removable
      | .order += ($removable | sort)
      | .remaining -= $removable
      | .edges |= map(select( (.blocked_by as $b | ($removable | index($b))) == null ))
    )
  | { order, cyclic: (.remaining | sort) }
'
