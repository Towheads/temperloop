- **The `/build` worker hand-off no longer fails silently toward a plausible
  value** (#1805, #865, #1806, #1698, #1700). Five defects in
  `claude/workflows/build-level.mjs`, all one class — a seam that degrades to a
  believable answer instead of erroring:
  - `pr.sh open` rejecting an unparseable worker verdict aborted the whole item,
    so a clean commit with a full `.build-verification.md` was reported as a
    failed build. It now re-opens the PR from the commit's own title and the
    verification surface, and when even that cannot land it escalates under a new
    `verdict-unparseable` kind carrying `committed_sha` / `dirty` /
    `verification_present` — so a reader can tell "no work" from "work done,
    reporting broke".
  - Workers are now **handed** a scoped-gate invocation that always writes a
    result sentinel (`/tmp/qg-<slug>.worker-gate.json`) and are told to poll that
    artifact rather than a PID; a sentinel still reading `running` at §3e.5
    produces a named notice, so a worker stalled on a backgrounded gate is
    distinguishable from a slow one.
  - `sq()` emits a value containing a single quote **double-quoted** instead of
    via the `'\''` idiom, whose nesting the executor's own shell parser refused
    at parse time on any item whose payload carried escaped quotes.
  - Machinery duration keys are canonicalized once at the transport boundary, so
    a `GATE_PASS` reporting `elapsed_secs` no longer reads as `0s` and disables
    the gate decay signal; an elapsed figure that is genuinely unknown renders
    `?` and says so, never `0`.
  - Items are accepted under the **documented** `plan-schema.md` spellings
    (`gh_issue:`, `also_closes:`, `depends-on:`), and any item key the workflow
    does not read is named in the log. Previously a caller using the documented
    key had its issue linkage dropped in silence: no `--gh-issue`, no
    `Closes #N`, and a PR that merged green leaving its issue open.
