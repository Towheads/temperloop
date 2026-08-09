- **A comparison report producer for the model-comparison harness** (#1261).
  `workflows/scripts/report-producers/model-comparison` rolls a baseline arm
  and a candidate arm of scored replay records into one JSON report: whole-job
  cost per merged outcome, judge quality scores, gate outcomes,
  intervention/rework proxies and durations, with a bootstrap confidence
  interval and a minimum-detectable-effect disclosure ("at this N, only deltas
  of at least X are detectable") on every run. Every statistic is taken from
  `model-comparison/stats.sh` and the scored-only quality split from
  `score.sh aggregate` — neither is recomputed here, so a bound in the report
  and a bound from the library cannot drift apart.

  The report is built to be honest about what it does not know. It states its
  emit-coverage percentage against the emit-feasible seat denominator (with
  the excluded seats named), its corpus window, its quality-gate versions and
  its cost basis — cost-weighted **token counts**, explicitly neither metered
  dollars nor a subscription-usage share — on every run, not only when those
  read well. A run below the sample threshold reports `inconclusive` and emits
  no `winner` key at all; a run it cannot evaluate renders a single
  `skipped -- model-comparison: <reason>` line at exit 0 and no report object,
  so "could not evaluate", "inconclusive" and "the candidate is better" stay
  three visibly different statements. A stale or absent price table degrades
  to a dated staleness label or a stated token-counts-only basis rather than a
  silently missing line, and a row hit by a mid-batch judge outage carries its
  own named degradation notice instead of being scored as a zero.

  Additive only: new files and new keys, no change to the existing `tokens`
  producer's slot format or to the headline spend figure ADR 0020 owns. Per
  ADR 0027 the kernel ships **no** `.temperloop/report.d/` shim for it, so
  `temperloop report` never runs it until an adopter opts in with the same
  one-file locator shim `tokens` uses.
