- **A lone discovered epic-sized issue now has a pipeline door** (#1524, #1510):
  `/assess`'s two no-Contract stop sites branch three ways instead of
  unconditionally redirecting to `/triage` — an epic-shaped issue with missing
  members still routes to `/triage`; a plain small issue routes to `/fix <n>`
  (the #1510 misroute); and an epic-sized, Contract-less issue enters a new
  lone-issue decomposition arm that derives the contract from the issue's own
  body sections, reusing the existing hand-authored-Contract provenance ask and
  the `/build` sub-issue mint path. `/fix`'s discovered-epic redirect now names
  `/assess --epic <N>` rather than the circular `/triage`-first path, closing
  the redirect cycle in which every command pointed at another refuser.
