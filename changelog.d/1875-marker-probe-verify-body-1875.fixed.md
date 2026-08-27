- **`issue_marker_probe`'s live gh fallback now verifies each search hit's
  body against the literal marker before returning it** (#1875). GitHub's
  `--search "<marker> in:body"` is tokenized, so a query for one marker could
  return an issue carrying a different marker sharing tokens (the
  #1849-vs-#1847 shape); an unverified hit made idempotency-guarded callers
  silently skip creations. The fallback now applies the same `grep -F`
  literal-body check the corpus path already used, so both paths agree on
  precision.
