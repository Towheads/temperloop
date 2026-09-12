- **The three separately-written graph traversals now share one library**
  (epic #1910, L0-a). `workflows/scripts/lib/graph.sh` (bash 3.2 + jq) answers
  `levels` (Kahn's-algorithm level partition), `cycle` (targeted BFS
  reachability, path-returning), and `reachable` (plain BFS) over one shared
  edge-list JSON shape. `plan.sh`'s toposort (previously an awk Kahn),
  `cycle-check.sh` (previously a hand-rolled bash BFS), and
  `sweep-pool-cycle-detect.sh` (previously a bespoke jq Kahn) are now thin
  wrappers over it — every caller's command line and output grammar is
  unchanged.
