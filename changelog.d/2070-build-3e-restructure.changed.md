- **`/build`'s pre-push review rules are now readable** (#2070). The pre-push
  review step in `claude/commands/build.md` was a single 1,256-word paragraph on
  one source line. It is now split into named sub-sections — which reviewers a
  change routes to, how an unavailable reviewer is probed and reported, what a
  finding has to be before it blocks the push, and where the step runs plus the
  wall-clock ceiling it runs under — with the incident history behind those rules
  collected into a section of its own, so the rule reads without the archaeology.
  No rule changed: the behaviour the spec describes is identical.
