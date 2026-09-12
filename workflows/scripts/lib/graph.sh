#!/usr/bin/env bash
#
# graph.sh — the shared graph-traversal library (L0-a, epic Towheads/temperloop#1910,
# `Designs/temperloop - graph of record` (private knowledge store), ADR 0032/0033
# context). One implementation of the three graph walks the pipeline needed —
# levels (Kahn's algorithm), cycle (targeted BFS reachability), reachable (plain
# BFS) — over ONE edge-list JSON shape, so the walk stops being written three
# times over three input formats (an awk Kahn in plan.sh, a bash BFS in
# cycle-check.sh, a jq Kahn in sweep-pool-cycle-detect.sh).
#
# Portable: bash 3.2 (macOS's shipped /bin/bash) plus jq, no new dependency.
# No associative arrays, no `${a[@]:off}` slice expansion — every traversal's
# real work runs inside a single jq program; bash here only dispatches the
# subcommand and reads the input.
#
# ── Edge-list JSON shape ──────────────────────────────────────────────────
#   {
#     "nodes": ["a", "b", ...],                       # optional
#     "edges": [{"from": "a", "to": "b", "type": "..."}, ...]
#   }
# `nodes` is optional — when absent, the node set is derived from every
# edge's `from`/`to`. Pass it explicitly to include a node with NO edges at
# all (an isolated node), which no edge could otherwise reveal. `type` is
# carried by callers for their own bookkeeping; graph.sh itself never reads
# it — the three walks below are direction-generic.
#
# Each subcommand gives `from`/`to` a DIFFERENT walk-appropriate meaning, and
# it is the CALLER's job to encode its edges accordingly (see each wrapper):
#   levels     — "from must precede to" (from is a prerequisite of to). Level
#                0 = nodes with no incoming edge (no prerequisite).
#   cycle      — "from points to to" (walk outward from --from, following
#                each node's own out-edges, looking for --to).
#   reachable  — same outward-walk direction as `cycle`, no specific target.
# A caller wanting the mirror direction simply swaps from/to when it builds
# the edge list — graph.sh has no opinion beyond "walk the arrows forward".
#
# ── Commands ──────────────────────────────────────────────────────────────
#   graph.sh levels <edges.json>
#     Kahn's-algorithm level partition. Success:
#       {"levels": [["a"], ["b","c"], ...]}
#     A cycle (some nodes never reach in-degree 0): the levels that DID
#     resolve before the walk got stuck, plus the stuck remainder — never
#     collapsed to a bare failure, since a caller may need to know how much
#     of the graph resolved (sweep-pool-cycle-detect.sh's `order`/`cyclic`
#     split is exactly this):
#       {"outcome": "CYCLE", "levels": [...], "cycle": ["d","e",...]}
#     Exit 0 on success, 1 on CYCLE.
#
#   graph.sh cycle <edges.json> --from <node> --to <node>
#     BFS from --from, outward along edges, looking for --to. ALWAYS prints
#     the offending path, never a boolean — an empty path means "not found":
#       {"path": []}                        # --to not reachable from --from
#       {"path": ["<from>", ..., "<to>"]}   # the walked path, if found
#     Exit 0 either way (the empty-path case is a normal, expected answer,
#     not an error) — a caller distinguishes on `path`'s length, exactly as
#     `reachable` below.
#
#   graph.sh reachable <edges.json> --from <node>
#     BFS from --from, outward along edges, no target. Prints every node
#     reachable from --from (--from itself excluded), sorted:
#       {"reachable": ["b", "c", ...]}
#
# <edges.json> may be a file path or `-` for stdin.
#
# Exit codes: 0 on any well-formed answer (including "no cycle" / "empty
# reachable set" — those are answers, not failures); 1 on `levels`' CYCLE
# outcome; 2 on a usage error (bad args, missing/unreadable input, jq
# absent) — a usage error prints its message to stderr and NO JSON to
# stdout, so a caller can never mistake a usage failure for a graph answer.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: graph.sh levels <edges.json|->
       graph.sh cycle <edges.json|-> --from <node> --to <node>
       graph.sh reachable <edges.json|-> --from <node>

See this script's own header for the edge-list JSON shape and each
subcommand's output grammar.
EOF
  exit "${1:-2}"
}

command -v jq >/dev/null 2>&1 || { echo "graph.sh: jq required" >&2; exit 2; }

[ $# -ge 1 ] || usage
CMD="$1"; shift

read_input() {
  local src="$1"
  [ -n "$src" ] || { echo "graph.sh: missing <edges.json> argument" >&2; exit 2; }
  if [ "$src" = "-" ]; then
    cat
  else
    [ -f "$src" ] || { echo "graph.sh: no such file: $src" >&2; exit 2; }
    cat "$src"
  fi
}

case "$CMD" in
  levels)
    [ $# -ge 1 ] || usage
    INPUT_SRC="$1"; shift
    EDGES_JSON="$(read_input "$INPUT_SRC")"
    OUT="$(printf '%s' "$EDGES_JSON" | jq -c '
      (.nodes // []) as $decl_nodes
      | (.edges // []) as $edges
      | ( $decl_nodes + [$edges[].from] + [$edges[].to] | unique ) as $nodes
      | { remaining: $nodes, edges: $edges, levels: [] }
      | until(
          ( .remaining | length ) == 0
          or
          ( [ .remaining[] as $n
              | select( ([ .edges[] | select(.to == $n) ] | length) == 0 )
              | $n
            ] | length ) == 0
          ;
          ( [ .remaining[] as $n
              | select( ([ .edges[] | select(.to == $n) ] | length) == 0 )
              | $n
            ] | sort ) as $removable
          | .levels += [ $removable ]
          | .remaining -= $removable
          | .edges |= map(select( (.from as $f | ($removable | index($f))) == null ))
        )
      | if (.remaining | length) == 0
        then { levels: .levels }
        else { outcome: "CYCLE", levels: .levels, cycle: (.remaining | sort) }
        end
    ')"
    printf '%s\n' "$OUT"
    [ "$(jq -r '.outcome // empty' <<<"$OUT")" != "CYCLE" ]
    ;;

  cycle)
    [ $# -ge 1 ] || usage
    INPUT_SRC="$1"; shift
    FROM=""; TO=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --from) [ $# -ge 2 ] || usage; FROM="$2"; shift 2 ;;
        --to)   [ $# -ge 2 ] || usage; TO="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$FROM" ] && [ -n "$TO" ] || usage
    EDGES_JSON="$(read_input "$INPUT_SRC")"
    printf '%s' "$EDGES_JSON" | jq -c --arg from "$FROM" --arg to "$TO" '
      (.edges // []) as $edges
      | { queue: [{node: $from, path: [$from]}], visited: [$from], found: null }
      | until(
          (.found != null) or ((.queue | length) == 0);
          (.queue[0]) as $cur
          | (.queue[1:]) as $rest
          | ( $edges | map(select(.from == $cur.node)) | map(.to) ) as $nexts
          | if ($nexts | index($to)) != null
            then { queue: [], visited: .visited, found: ($cur.path + [$to]) }
            else
              ( $nexts - .visited ) as $new
              | { queue: ($rest + ( $new | map({node: ., path: ($cur.path + [.]) }) )),
                  visited: (.visited + $new),
                  found: null }
            end
        )
      | { path: (.found // []) }
    '
    ;;

  reachable)
    [ $# -ge 1 ] || usage
    INPUT_SRC="$1"; shift
    FROM=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --from) [ $# -ge 2 ] || usage; FROM="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$FROM" ] || usage
    EDGES_JSON="$(read_input "$INPUT_SRC")"
    printf '%s' "$EDGES_JSON" | jq -c --arg from "$FROM" '
      (.edges // []) as $edges
      | { queue: [$from], visited: [$from] }
      | until(
          (.queue | length) == 0;
          (.queue[0]) as $cur
          | (.queue[1:]) as $rest
          | ( $edges | map(select(.from == $cur)) | map(.to) ) as $nexts
          | ( $nexts - .visited ) as $new
          | { queue: ($rest + $new), visited: (.visited + $new) }
        )
      | { reachable: ( (.visited - [$from]) | unique | sort ) }
    '
    ;;

  --help|-h)
    usage 0
    ;;
  *)
    echo "graph.sh: unknown subcommand '$CMD'" >&2
    usage
    ;;
esac
