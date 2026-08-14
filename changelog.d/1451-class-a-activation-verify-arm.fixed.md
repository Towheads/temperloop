- **`/build`'s class-A activation gate no longer has a dead arm that skips
  itself.** `claude/commands/build.md` §3e.6 routed a `class: A` activation
  block carrying no `proof:` predicate to "invoke the `/verify` skill", paired
  with a legible-degradation clause authorizing `skipped — /verify unavailable`
  when that skill was absent. No `/verify` has ever existed in this repo — no
  `claude/commands/verify.md`, no other definition — so that arm of a
  *mandatory* gate could only ever resolve to its own skip notice: the
  temperloop#1387 shape, a pre-authorized degradation clause dressing a
  structurally-dead route as an accepted fallback. Both bullets are now gone.
  The no-predicate case is instead **unreachable by construction** — plan-schema
  **rule 13** already fails validation for a class-A block with no `proof:`
  (`workflows/scripts/build/plan.sh`), and `/build` Step 1's validation
  checklist now names that rule explicitly, so the front door enforces the
  invariant 3e.6 depends on. Should such an item still arrive (a plan note
  hand-edited past Step 1), 3e.6 escalates `activation-proof-missing` and loops
  back to 3c exactly like a Fail — there is no fallback actor and no skip arm.
  `claude/plan-schema.md` § activation drops its matching "`/build` falls back
  to driving `/verify`" sentence and states that `proof:` is mandatory;
  `claude/message-schema.md` § degradation notice keeps its `/verify` reference
  only as the worked example of the failure, noting that the fix was deleting
  the route rather than keeping the notice. New static lockstep guards in
  `workflows/scripts/build/tests/test_plan.sh` (search `K1451`) sit beside the
  rule-13 behavior cases and fail if any half is reverted independently: the
  escalation token must be present, no `skipped — /verify` line may reappear in
  build.md, neither build.md nor plan-schema.md may route to `/verify` while
  `claude/commands/verify.md` is absent (the clause self-silences if a real
  `/verify` ever ships), and build.md must keep naming rule 13.
