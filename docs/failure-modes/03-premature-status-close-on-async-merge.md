---
title: Marking work "done" at queue time instead of confirmed completion
---

## The failure

A build pipeline's final step, after a pull request's checks pass, was to
move its tracking issue to "Done" on a project board — which in turn
triggered board automation that closed the issue. On a repository configured
with a strict merge policy (required checks must be re-verified against the
latest default branch before merge), a pull request can't always be merged
synchronously the moment its own checks go green: it has to be *queued*, and
the platform lands it — re-testing against the current branch tip — some
time later, asynchronously.

The pipeline's "merge gate" step treated "the merge command was issued and
accepted" as equivalent to "the code is merged," and moved straight on to
marking the board Done. In practice this meant: a queued pull request whose
merge hadn't actually landed yet already had its tracking issue closed. In
one observed run, the board was marked Done and the issue closed at one
timestamp, while the actual merge didn't land until 46 minutes later — a
window where the tracking issue was closed against code that, at that
moment, was not yet in the default branch. Had the queued merge been
cancelled or failed in that window (a real possibility — later commits can
knock a queued merge out, or a conflicting merge can land first) the issue
would have stayed wrongly closed with no code change to show for it.

## The mechanism

The bug is a classic confusion between **initiating an asynchronous
operation** and **that operation having completed**. The pipeline's own
local reasoning ("I called merge, and the call succeeded") was accurate —
the merge *was* successfully queued — but the state that actually matters
downstream (is the code in the default branch) is a different, later fact
that the queuing call doesn't observe. Nothing checked for it before the
side effect (closing the issue) fired.

This is compounded by the two things happening on different systems: the
merge queue is a property of the git host's branch-protection settings, and
the "mark Done" step is a local pipeline decision reading its own view of
"the gate completed." "The gate completed" was true in the sense of "every
command I issued returned success" and false in the sense of "the outcome
those commands were working toward has actually happened yet."

## The guard

The fix was to make the completion check explicit and to gate the
side-effecting step on it directly: before moving a tracking issue to
Done, read the pull request's actual merge state from the source of truth
(merged vs. merely queued) rather than inferring it from "the merge command
didn't error." An item whose merge is still queued but not confirmed landed
stays in its in-progress state; the Done-move (and whatever it triggers)
only fires once the merge is confirmed. On a strict branch-protection setup
this means the pipeline's final step may need to wait — poll the actual
merge state — rather than assuming "queued" and "merged" are interchangeable.

The general lesson: any step that triggers an irreversible or hard-to-undo
side effect (closing a ticket, notifying someone, deleting a resource)
based on the *success of an asynchronous operation's kickoff* rather than
its *confirmed completion* has a race window baked in. The fix is never to
make the kickoff synchronous when the platform doesn't support that — it's
to add an explicit confirmation read of the actual downstream state before
the side effect fires, and to treat "still pending" as a distinct state from
both "done" and "failed," with its own place to sit while it resolves.
