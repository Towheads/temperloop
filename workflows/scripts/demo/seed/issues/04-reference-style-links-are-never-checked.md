# Reference-style links are never checked

`find_links()` only matches the inline form `[label](target)`. Markdown's
reference form is invisible to it:

```
See [the guide][guide] for details.

[guide]: guide.md
```

`guide.md` can be deleted and `linkrot` will not notice. `docs/getting-started.md`
in this repository already uses the reference form for its CommonMark link,
which makes the blind spot easy to reproduce.

Expected: reference-style links are collected too — the definition lines
(`[label]: target`) supply the targets, and a reference whose definition is
missing entirely is itself a finding worth reporting.

Acceptance (falsifiable):

- a document using `[x][ref]` plus `[ref]: missing.md` produces a finding for
  `missing.md`
- a document using `[x][ref]` with **no** `[ref]:` definition anywhere
  produces a finding naming the undefined reference
- a definition line that is never referenced does not crash the scan
- the suite gains cases for all three and stays green

Depends on: the link-classification work (anchors and external URLs) landing
first — reference targets go through the same classifier, and doing this
before that is settled means writing the filter twice.
