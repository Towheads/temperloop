---
title: The self-learning loop — how temperloop learns from its own operation
---

# The self-learning loop — how temperloop learns from its own operation

An agent that makes the same mistake twice is expensive, and a pipeline
that only improves when a human remembers every lesson doesn't scale.
temperloop closes that gap with a **self-learning loop**: each session's
learnings are captured the moment they happen, drained nightly into durable
knowledge, and — when a mistake *recurs* — hardened into a mechanical
control that makes it structurally hard to repeat. The system's own
operation is what makes it better.

The loop is a cycle: **capture → log → drain → detect recurrence → harden →
enforce → dispose**. Each stage is a real script, command, or rule in this
repo — except two stages a full install supplies from a private overlay and
personal knowledge store, noted where they appear. In short: **this repo
ships the drain, enforcement, and plumbing; a full install adds the
live-capture rules and the store that holds what they capture.**

## The loop, stage by stage

### 1. Capture at source — the moment it's learned

A learning held for an end-of-session summary is a learning often lost —
the summary may never happen. So the governing rule is to capture the
instant something is noticed ([`principles.md`](principles.md) #12).

- **This repo's own live-capture rule is defect routing.** A defect noticed
  mid-work is filed to the tracker *immediately* — "capture, don't ask"
  forbids ending a turn with "want me to file this?", because that offer
  dies with the session. Filing is reversible; a dropped bug is not.
- **Epic completion files its own retrospective.** When `/build` drives an
  epic to completion, it synchronously files a process-retro issue — the
  standing questions about how the work was structured (was the
  decomposition right, did the contract seams hold, where did the cadence
  add friction) — at the instant the epic closes, so the lessons of *how
  the work was shaped* can't be lost if the session ends first. Every
  completed epic teaches the next decomposition.
- **The other capture rules come from the overlay** — decision capture,
  feedback memory, friction tracking. This repo doesn't ship those rules,
  but it ships their nightly backstops (stage 3) and the CI check that
  keeps each pair whole (stage 6).

### 2. Log the session — the plumbing that feeds the drain

- A **session-end hook** writes a transcript stub when a session ends with
  real activity, recording the session's model for later provenance
  ([`claude/hooks/session-end-log.sh`](../claude/hooks/session-end-log.sh)).
- A **session-start hook** drains those stubs into the knowledge store's
  inbox and hands the session id back to the model so live captures carry
  their provenance
  ([`claude/hooks/session-start-drain.sh`](../claude/hooks/session-start-drain.sh)).
- Raw transcripts get a terminal home in a git-tracked archive —
  retrievable with `git log -S` / `rg`, not by recall.

### 3. Drain on schedule — `/tidy`, nightly and unattended

The drain is where raw sessions become durable knowledge
([`claude/commands/tidy.md`](../claude/commands/tidy.md)). It runs nightly,
never blocks on a question, and parks anything needing human judgment to
surfaces the operator disposes later (stage 7). Each run:

- **scans** each stub into a compact ~2–3K-token report rather than loading
  the raw transcript;
- **extracts learnings** into the knowledge store — decisions, patterns,
  mistakes, feedback — adjudicated against a structured tell file
  ([`workflows/scripts/drain/lexicon.tsv`](../workflows/scripts/drain/lexicon.tsv))
  plus structural passes over tool events (a tool error → a mistake or an
  unfiled defect; a correction → a self-correction finding);
- runs a **mandatory sensitivity scan** (a possible secret is flagged by
  location and kind, never copied) and hygiene probes (store drift,
  environment drift, stale board claims);
- **archives** processed stubs and emits a summary.

Every adjudication — accepted or rejected — is written as a findings record
([`workflows/scripts/drain/findings-schema.md`](../workflows/scripts/drain/findings-schema.md)),
which is what makes the next stage possible. (A full install adds a second
reader, an overlay `/retro` command that *grades* archived sessions — did
the system itself perform well? — where `/tidy` *extracts* from them.)

### 4. Detect recurrence — one-off vs. pattern

A single stumble is just a note; a *repeated* one is tracked work. The
drain tallies recurrence and escalates:

- **Friction that recurs** past a threshold is surfaced as a candidate and
  filed as an issue — the most frequent stumbles become tracked work rather
  than repeating silently.
- **Findings that recur** are counted over a trailing window
  ([`workflows/scripts/drain/tally_recent_findings.py`](../workflows/scripts/drain/tally_recent_findings.py));
  past threshold, the drain proposes a rule change. A recurring *mistake*
  specifically proposes tightening a guard — the on-ramp to the next stage.

This is the loop's decisive move: it doesn't just record mistakes, it
notices when one is *systemic* and routes it toward a control.

### 5. Climb the maturity ladder — learning hardens into enforcement

The escalation has a fixed shape ([`principles.md`](principles.md) #5): a
rule starts as prose; if it keeps leaking, it earns a mechanical backstop
(a hook that warns or asks); only a backstop that keeps firing earns a
hard, CI-enforced invariant. Each layer is a response to an observed leak.

The worked examples all began as repeated frictions and climbed to hooks:

- [`claude/hooks/git-stale-branch-guard.sh`](../claude/hooks/git-stale-branch-guard.sh)
  — born because branching off a stale local `main` was the single most
  frequent friction class on record.
- [`claude/hooks/write-lane-guard.sh`](../claude/hooks/write-lane-guard.sh)
  — born from a real session stepping on a peer session's checkout.
- [`claude/hooks/subtree-edit-guard.sh`](../claude/hooks/subtree-edit-guard.sh)
  — born from a downstream checkout silently forking a vendored kernel
  file.

Each is a backstop, not a replacement for the habit — it fails open and
only nudges. The top of the ladder is stage 6.

### 6. Enforce that the loop stays whole

The loop only works if a capture rule can't silently lose its backstop. So
every live-capture rule must ship **paired** with a nightly drain rule,
registered in a table — and
[`workflows/scripts/validate-capture-backstop.sh`](../workflows/scripts/validate-capture-backstop.sh)
**fails the build** (part of the required `checks` gate) if any pair is
half-present. That's the CI-enforced invariant at the top of the maturity
ladder, guarding the loop against its own silent-loss failure mode.

### 7. Operator disposes — `/check-in`

The daily `/check-in` is the human half of the drain-proposes /
operator-disposes split. It's the sole mutator of the surfaces `/tidy`
wrote, and disposing them feeds the loop forward:

- **accepting a finding** files a tracked issue;
- **promoting a candidate tell** grows the drain's own lexicon — the drain
  sharpening its detectors from the misses it measured;
- **promoting a note** stages an edit into the standing operating rules — a
  learning literally re-entering the instructions.

Whether all of this *actually* reduces repeated mistakes is checked, not
assumed: [`claude/measurement-proxies.md`](../claude/measurement-proxies.md)
names the proxies (friction volume over a fixed window is one) and is
careful to call them proxies, not proofs — the same honesty as the cost and
token-spend pages.

## Related

- [`principles.md`](principles.md) — the loop rests on #12 (capture at
  source, drain on schedule) and #5 (climb the maturity ladder on
  evidence).
- [`token-spend.md`](token-spend.md) — the durable-capture lever there is
  this loop's output; [`cognitive-load.md`](cognitive-load.md) covers the
  review-ergonomics side.

---

*Written by claude-fable-5 on 2026-08-13.*
