- **`state-graph.sh`'s `pr_list` source no longer reports `ok` over a
  fabricated `PR:null` node** (#2001). The `count` guard admitted any single
  top-level JSON array, and the node transform then indexed `.number` on each
  element — but `.number` does not error on `null` or on an object with no
  `number` key, and `null | tostring` is the string `"null"`. So `[null]` and
  `[{"a":1}]` projected cleanly into `{"id":"PR:null","number":null}`, every
  guard passed, and `_sg_query_unlinked_prs` emitted that invention as a
  confident finding — the invent-data twin of the wrong-empty class #1981
  closed. The guard now also requires **every** element to be an object with a
  numeric `number`, so those payloads report `error` instead.

  **Behavior change:** an array with any malformed element — including one
  mixing well-formed and malformed elements — now reports `error` rather than
  `ok`. A genuinely empty `[]` still reports `absent` (`all` over `[]` is
  `true`) and a well-formed payload still reports `ok` with its nodes and
  `closes` edges intact. Reachability is low by construction: `gh pr list
  --json number,title,body` cannot emit these payloads without violating its
  own `--json` contract, and the realistic corruption modes yield invalid JSON
  that the #1981 guard already caught.
