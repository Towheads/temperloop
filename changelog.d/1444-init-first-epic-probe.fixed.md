- **`temperloop init`'s first-epic idempotency probe no longer turns any API
  error into "already filed"** (#1444). The probe searches the adopter's repo
  for the design-brief / decline markers before offering the pre-designed first
  epic, and it was broken two ways at once. GitHub's `search/issues` endpoint
  now **requires** an `is:issue` or `is:pull-request` qualifier and 422s without
  one — external drift, no commit here caused it — and `gh` writes its error
  **body to stdout**, so the probe's fail-open (`2>/dev/null || true`) handed
  that raw JSON blob back as the issue number. It tested non-empty, so `init`
  printed `first-epic: already filed as #{"message":"Query must include
  'is:issue' …","status":"422"}` and passed the blob into the handoff too. Any
  probe error — rate limit, network blip, auth scope, outage — silently
  disabled the first-epic offer while claiming the epic existed. Both queries
  now carry `is:issue`, and — the durable half — the captured value is
  validated digits-only before it is ever treated as an issue number, so no
  future error body can be mistaken for a hit either. The probe is now
  three-valued: already-filed, not-filed, or **UNKNOWN**. An unanswerable probe
  withholds the offer rather than risk a duplicate epic, and says so on its own
  `first-epic:` line instead of skipping silently. `install-tier2`'s `init` leg
  additionally asserts the offer was disposed through a **legitimate arm** — a
  final `first-epic:` line of a known-good form, and, on the already-filed form,
  an issue number that is actually digits — so this exact corruption now fails
  the release gate instead of reading as a clean skip. That assertion
  deliberately does not pin the *ambient-CI* arm specifically: that arm is only
  reachable while the demo repo has no first epic filed, so pinning it would
  make a release gate hostage to demo-repo issue state.
