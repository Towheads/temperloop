---
title: "0020: cost measurement reads session transcripts rather than emitting a stream"
---

## Status

Proposed

## Context

epic: Towheads/temperloop#972

The kernel's raw event lake records command runs, GitHub calls, claims, issue
touches and timings. As `docs/token-spend.md` stated plainly, **none of it
records tokens or dollars.** Meanwhile `temperloop report` shipped a defined but
empty slot for a `tokens` producer, and `/check-in` carried a guard for a
cost-per-epic digest that no kernel checkout could satisfy. Two slots shaped for
data that did not exist.

That doc proposed closing the gap by having the kernel's own `claude -p`
invocations write their `usage` totals into a new raw-lake stream. That approach
has a structural ceiling: it can only ever see calls the kernel itself makes.
The autonomous pipeline would be measurable; an operator running `/sweep` or
`/fix` interactively would not — and the interactive path is where the spend
this work targets actually happens.

The alternative rests on an existing artifact. Every Claude Code session already
writes a transcript to `~/.claude/projects/<cwd-mangled>/<session-id>.jsonl`, and
every assistant message in it carries `usage` (`input_tokens`,
`cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`)
alongside its `model` id. The data exists, on disk, for every session already
run — including interactive ones.

## Decision

**Token-spend measurement reads Claude Code's session transcripts. No new
telemetry stream is emitted, and no model call site changes.**

The producer at `.temperloop/report.d/tokens` derives its corpus from the
target repo's own working directory, sums `usage` by `model`, and emits the
`report.d` contract's `{"tokens_spent": …, "by_model": {…}}` shape. It reads
local files only — no network, no API, no `gh`.

Extraction is **allowlist-shaped**: only `.message.usage` and `.message.model`
are read, and only integers and model-id strings are emitted. Never message
text, file paths, or tool inputs. This is a structural guarantee rather than a
filtering one — the worst case under a scoping bug is a mis-attributed count,
never a content leak.

## Consequences

**What this buys.** Coverage of interactive sessions, which the emitter approach
structurally could not reach. Retroactive coverage — a baseline is computable
from transcripts already on disk the day the producer lands, with no waiting
period before a change has something to compare against. And zero change to how
any model call is made, so nothing about the calling path can regress.

**The cost, and it is real.** The kernel now depends on an **undocumented,
unversioned, external** artifact format that is free to change without notice.
The mitigation is degradation rather than a version pin: on an unrecognized
record shape the producer skips rather than sums, so a format change costs a
missing number and never a wrong one. That rule is load-bearing — a partial sum
that still looks like a clean number is the failure mode with no natural floor,
because a wrong cost figure is indistinguishable from a right one at a glance.

**The traps this format sets, discovered empirically.** The shipped
implementation encodes two that a naive reading of the format gets wrong, and
both produced wrong answers before they were found:

- **One API response spans several transcript lines, each repeating the same
  `usage` block.** Summing per line inflated a real corpus by **2.16×**.
  Deduplication by `requestId` is mandatory, not an optimization.
- **The token classes are not interchangeable.** `cache_creation` bills roughly
  12.5× `cache_read`, which is the difference between machinery agents reading
  as ~10% of spend unweighted and ~32% weighted. An unweighted sum is not a
  cheaper approximation; it is a different and wrong answer.

Both are recorded here because they are properties of the *format*, not of one
script — anything else reading these transcripts will meet them.

**Honest limits.** The number is per-developer and per-machine: it sees only
transcripts on the host it runs on, so a team sharing a repo gets a
per-person figure that is not comparable across teammates and is not a team
total. It can err in both directions — undercounting work done on another
machine, and overcounting when a workspace path is reused across projects, since
the corpus is keyed on filesystem path rather than on repo identity. It is a
directional signal for the operator's own decisions and is not cost evidence to
hand a third party.

**Privacy posture.** The producer reads from `$HOME`, outside the repo — the
first `report.d` producer to do so. That fact is disclosed in three places
because three different readers arrive by three different routes: the script's
own header (for a reviewer who opens it), the feature doc (for someone
evaluating adoption), and a one-time first-run notice (for the teammate who
inherited a committed producer via `git pull` and never chose it).
