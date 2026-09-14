- **`/build`, `/sweep` and `/fix` now tell you when the installed build engine
  is too old to understand a setting they are passing it** (#2018). Those three
  commands hand their work to a single installed script,
  `~/.claude/workflows/build-level.mjs`, along with a bag of settings. The
  hand-off has always been forgiving on purpose: a setting the installed script
  does not recognise is ignored and a built-in default takes over, so an older
  copy keeps working rather than crashing. The cost was that the same silence
  covered a copy that was simply **stale** — or, in a repo that vendors this
  kernel, an older **vendored** copy — which quietly ignored a setting the
  command believed it had applied, with nothing said on either side. Observed
  live: an installed copy 18 days behind ignored the setting that routes code
  reviewers, and the run fell back to the exact path it was in the middle of
  replacing.

  `claude/workflows/build-level.mjs` now publishes the list of settings that
  copy understands, and a new probe,
  `workflows/scripts/build/handoff-capability.sh`, compares that list against
  what a command is about to pass. All three commands run it immediately before
  handing off. Nothing is blocked — the fallback behaviour is unchanged — but
  you now get a one-line notice **naming each setting that will be ignored**,
  rather than a generic "your copy is old". The probe compares against whatever
  copy you point it at, so it works for a vendored copy in your own repo, not
  only for an overdue `make install`.

  If the probe cannot determine the answer at all — the file is missing or
  unreadable, or it is an older copy that publishes no list — it reports that
  as its own third result and says why. It never reports an undetermined check
  as a clean one.
