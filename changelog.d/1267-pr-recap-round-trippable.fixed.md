- **A PR body's `## Acceptance` recap is now round-trippable** (#1267). `pr.sh`
  used to append each criterion's evidence inline after a bare ` — `, but that
  delimiter occurs inside real criteria *and* inside real evidence, so the only
  durable verbatim record of the acceptance contract a worker was handed had no
  unambiguous parse — a first-occurrence split silently truncated the criterion,
  a last-occurrence one ate the evidence. Evidence now rides its own nested line
  under the bullet, making the split positional, and the new
  `pr.sh acceptance-extract <bodyFile|->` reads a body back into its
  `acceptance_results` entries byte-exactly with no heuristic. GitHub renders the
  indented continuation as part of the same list item, so the body reads the same.
  `replay.sh corpus` consumes the new format through that extractor and keeps its
  last-em-dash workaround, and its `criterion-embedded-em-dash` flag, for bodies
  merged before this change.
