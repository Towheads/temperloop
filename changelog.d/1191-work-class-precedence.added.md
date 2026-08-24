- **Work-class precedence: `Foundational` wins over a co-present `Operational`**
  (#1191). `claude/work-class-policy.md` now defines what the driver does with an
  issue carrying **both** work-class labels — a state no current writer produces
  (`capture.sh` and `/triage` both substitute rather than append), but one that
  pre-existing dual-labeled issues are still in. Such an item resolves
  `Foundational`, so `pipeline-tick.sh` gates it to the operator's decision queue
  (`route-foundational`) instead of routing it to autonomous drive: an ambiguous
  work class gets human judgment, never an autonomous merge. This is a **router
  precedence rule only** — no backfill and no mutual-exclusivity enforcement, and
  "exactly one work-class label" stays the authoring intent. `classify_item`
  already matched `Foundational` first; the rule is now stated at the definition
  site and pinned by a test asserting both label orders.
