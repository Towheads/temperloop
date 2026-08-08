- **`/sweep`'s shared-hotspot rule now records that `CHANGELOG.md` is no longer
  a universal hotspot, and why** (#1218). The rule tells the Phase-2 chunker to
  sequence singletons that touch the same file into *different* chunks. It could
  not do that for `CHANGELOG.md`, because every contract-surface kernel item
  touched it — so a multi-item kernel chunk collided by construction rather than
  by coincidence.

  That premise is now false. Under `changelog.d/` fragments (#1321) and the gate
  cutover that requires one (#1322), a contract-surface PR writes its own new
  file instead of editing `CHANGELOG.md`, so two `/sweep`-driven singletons in
  one chunk share no changelog line and cannot collide on one.

  The deliverable is therefore a **subtraction**: no CHANGELOG-specific chunker
  rule was added, and the general shared-hotspot heuristic is unchanged — it is
  still correct for composition roots and other genuinely shared files. What the
  spec gains is one paragraph marking the CHANGELOG case as *resolved at the
  source*, so a future reader sees a closed concern rather than a missing one and
  does not re-file it.
