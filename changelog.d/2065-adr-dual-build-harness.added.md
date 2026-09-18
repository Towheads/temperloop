- **Four Proposed ADRs for the new-work dual-build harness** (#2065). The
  harness scores a candidate model on work it has not seen, by building each
  in-scope plan item twice and picking a winner — and four of its calls are
  load-bearing enough to record before any of it is built. ADR 0038 fixes the
  unit of judgement and the unit of choice at different levels: the judge runs
  per item, but the pick is made per level behind a barrier, so a level never
  ships a mixed-model set whose parts were never built against each other. ADR
  0039 gives the ledger its own folder under
  `.temperloop/model-comparison/dual-build/` with a versioned row schema and a
  patch archive, rather than piggybacking the resume ledger, so a comparison's
  records outlive the run that wrote them and stay joinable later. ADR 0040
  adds `Model-comparison-arms:` as a **second** trailer line beside an
  unchanged `Model-provenance:`, never a widened one, so the existing anchored
  disclosure check keeps matching byte-for-byte. ADR 0041 admits only blind
  pairs into judge calibration — an operator override is excluded from the
  sample precisely because it is not blind — and holds the verdict at NEVER
  CALIBRATED until the bar is met, rather than reporting a number the sample
  cannot support. All four ship Proposed; the feature-doc item flips them to
  Accepted when the harness lands.
