- **Added a triples extractor over the registries and the raw lake**
  (`workflows/scripts/knowledge/triples.sh build|query`, #1910). `build`
  derives `{s, p, o, provenance}` records from the citation registry's
  `<!-- cite: ... -->` markers, the issue-touches/claims lake streams
  (session ids normalized through `join-keys-lib.sh`), and `docs/adr/*.md`'s
  own `## Status` supersession chain, appending them to the new
  `triples-<YYYY-MM>.jsonl` raw-lake stream (documented in
  `meta/data/raw/README.md`) — idempotently, so re-running `build` never
  doubles the lake. Every predicate is drawn from
  `workflows/scripts/config/ontology-registry.tsv`'s `edge` axis; an
  unlisted predicate is a hard error. `query cites <rule-id>`, `query
  touched_by <issue>`, and `query supersedes <adr-ref>` read the derived
  graph back.
