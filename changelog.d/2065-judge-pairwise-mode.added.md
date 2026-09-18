- **`model-comparison/judge.sh` gains a `pairwise` mode — a head-to-head
  preference between two candidate diffs for the same item, instead of two
  separate absolute scores** (#2065, epic #2065 "dual-build"). Given two
  already-executed records for the same item, it sends ONE prompt — the
  item's title, scope, acceptance criteria, and both diffs — to the judge
  model TWICE, once with each candidate shown first, and reports
  `{preference, margin, order_agreement}`: a preference the two orders agree
  on (regardless of which candidate was shown first) is reported honestly,
  including a genuine tie; a preference that only tracks which candidate was
  shown FIRST resolves to a tie with `order_agreement:false` and `margin:0`,
  rather than a confident-looking number driven by screen position. The
  existing judge-equals-candidate guard now checks BOTH candidates — an exact
  provider+model match with either one refuses the whole comparison before
  any call is made. Inert per ADR 0027: nothing calls this mode for you yet.
