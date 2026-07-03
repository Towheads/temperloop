---
title: A worker's absolute path silently escapes its worktree
---

## The failure

A build pipeline that runs multiple isolated workers in parallel — one
`git worktree` per unit of work, each on its own branch — depends on every
worker's file writes staying inside its own checkout. The orchestrator that
coordinates the workers stays in the shared parent checkout the whole time,
reading each worker's committed diff and pushing it by commit SHA once it's
done.

One worker, mid-run, was handed (or constructed) a **bare absolute path**
into the parent checkout rather than a path relative to its own worktree —
for example the parent repo root instead of the worktree root. Its edit
tool resolved that path literally and wrote there. The write landed
**uncommitted, in the shared parent tree**, invisible to the worker's own
`git status` (which only sees its own worktree) and invisible to the
orchestrator until something else touched the parent tree and tripped over
unexpected local changes.

In the observed case the leaked write was a strict subset of what the
worker had *also* correctly committed on its own branch — so no work was
lost — but the leak sat in the parent checkout undetected until a later
`git checkout -b` for an unrelated branch surfaced it via `git status`. Left
uncaught, a leak like that contaminates whichever branch is created next in
the parent checkout, with no connection to the worker that caused it.

## The mechanism

The isolation boundary here was a **process convention** (a worktree per
worker) layered under a **prompt convention** ("always use paths relative to
your own worktree, never the parent checkout"). The prompt convention was
the *only* thing preventing a leak — everything else in the pipeline only
*detects* one after the fact:

- A prompt telling the worker how to construct paths is advisory. It's
  effective on the well-behaved path and silently absent on the
  malformed one — an absolute path handed to a file-write tool resolves
  against the real filesystem regardless of what directory the worker's
  shell commands are running in. Working directory and absolute-path
  resolution are two different things, and a worker (or the code
  constructing its instructions) can easily conflate them.
- The compensating controls that existed — a cleanliness check on the
  parent checkout between units of work, and a dirty-tree guard at the
  start of a run — are **detective, not preventive**. They catch a leak
  that already happened, and only at specific checkpoints; a leak between
  checkpoints, or on the very last unit of work in a run, can slip through
  entirely.

The general shape: an isolation boundary that is enforced only by telling
the isolated process what to do, rather than by making the disallowed
action structurally impossible, degrades to "usually fine, occasionally
silently wrong" — and the failure mode is exactly the case you can't
recover from by re-running, because the corruption is already committed to
shared state by the time anything downstream would notice.

## The guard

The fix was to turn the one preventive control from a prompt into an
enforced boundary: a pre-write hook that inspects the resolved absolute
path of every file write a worker attempts and **rejects** any write whose
path falls outside that worker's own worktree root (with a narrow allowlist
for legitimate exceptions like scratch or temp directories). The check runs
before the write lands, not after — so the leak is refused at the source
instead of being detected downstream.

Two follow-on lessons came out of hardening this:

- **A structural guard only works if it's actually installed everywhere the
  pipeline runs.** The first version of the hook was registered on one
  machine's global configuration; a run on a second machine, using a
  different checkout of the same tooling, had no guard registered at all,
  and briefly ran un-armed. The fix was to make the guard part of what gets
  deployed with the pipeline itself — vendored as a real file into every
  consuming checkout and registered at the project level, not left to a
  single global, machine-specific configuration to carry it everywhere.
- **A marker file naming the guard's own presence is cheap insurance.** A
  worktree that's supposed to be jailed can carry a small marker the guard
  itself asserts for, so a session running in an unguarded worktree fails
  loudly ("no isolation boundary found") instead of writing freely and
  finding out later.

The underlying principle: when an automated worker's blast radius includes
a shared checkout other work depends on, the isolation boundary belongs in
a mechanism that runs *before* the write, not in instructions the worker is
merely asked to follow.
